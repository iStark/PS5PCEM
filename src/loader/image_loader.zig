// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Places an ELF image into the identity-mapped guest address space.
//!
//! All load pages are committed read/write while bytes and relocations are
//! installed. Final ELF permissions are applied only after linking, which keeps
//! relocation writes legal without leaving code pages writable at run time.

const std = @import("std");
const memory = @import("memory");
const elf = @import("elf.zig");
const dynamic = @import("dynamic.zig");
const linker = @import("linker.zig");
const tls = @import("tls.zig");

pub const Error = error{
    NoLoadSegments,
    InvalidLoadSegment,
    AddressOverflow,
    EntryPointUnmapped,
} || elf.Error || linker.Error || tls.Error || memory.Error || std.mem.Allocator.Error;

pub const Options = struct {
    /// Added to every segment virtual address, relocation target, and entry
    /// point. Fixed executables normally use zero; shared modules receive a
    /// caller-selected base.
    load_bias: u64 = 0,
    /// Process-wide TLS registry. Without one, ordinary images still load, but
    /// a TLS relocation reports that no module identity is available.
    tls_registry: ?*tls.Registry = null,
};

pub const MappedImage = struct {
    address_space: *memory.AddressSpace,
    allocator: std.mem.Allocator,
    load_bias: u64,
    entry_point: u64,
    relocation_stats: linker.Stats,
    tls_registry: ?*tls.Registry = null,
    tls_module: ?tls.Module = null,
    ranges: std.ArrayList(memory.Range) = .empty,

    /// Releases every committed range while retaining the process-wide outer
    /// address-space reservation.
    pub fn unload(self: *MappedImage) memory.Error!void {
        var i = self.ranges.items.len;
        while (i > 0) {
            i -= 1;
            const range = self.ranges.items[i];
            try self.address_space.unmap(range.start, range.len());
        }
        self.ranges.deinit(self.allocator);
        self.ranges = .empty;
        self.unregisterTls();
    }

    /// Best-effort teardown for defer paths. Use `unload` when an error must be
    /// reported to the caller.
    pub fn deinit(self: *MappedImage) void {
        var i = self.ranges.items.len;
        while (i > 0) {
            i -= 1;
            const range = self.ranges.items[i];
            self.address_space.unmap(range.start, range.len()) catch {};
        }
        self.ranges.deinit(self.allocator);
        self.ranges = .empty;
        self.unregisterTls();
    }

    fn unregisterTls(self: *MappedImage) void {
        if (self.tls_registry) |registry| {
            if (self.tls_module) |module| registry.unregister(self.allocator, module.id);
        }
        self.tls_registry = null;
        self.tls_module = null;
    }
};

const SegmentPlan = struct {
    header: elf.ProgramHeader,
    address: u64,
    page_range: memory.Range,
    protection: memory.Protection,
};

const ProtectionRun = struct {
    range: memory.Range,
    protection: memory.Protection,
};

/// Maps, copies, relocates, and protects one parsed image.
pub fn load(
    allocator: std.mem.Allocator,
    address_space: *memory.AddressSpace,
    image: elf.Image,
    info: *const dynamic.DynamicInfo,
    resolver: ?linker.Resolver,
    options: Options,
) Error!MappedImage {
    var plans: std.ArrayList(SegmentPlan) = .empty;
    defer plans.deinit(allocator);
    var boundaries: std.ArrayList(u64) = .empty;
    defer boundaries.deinit(allocator);

    for (image.program_headers) |header| {
        if (header.segmentType() != .load or header.memsz == 0) continue;
        if (header.filesz > header.memsz) return Error.InvalidLoadSegment;
        if (header.@"align" != 0 and !std.math.isPowerOfTwo(header.@"align")) {
            return Error.InvalidLoadSegment;
        }

        // Validate the file range before committing any host pages.
        _ = try header.fileRange(image.bytes);

        const address = std.math.add(u64, options.load_bias, header.vaddr) catch
            return Error.AddressOverflow;
        const end = std.math.add(u64, address, header.memsz) catch
            return Error.AddressOverflow;
        const page_start = alignDown(address, memory.page_size);
        const page_end = alignUp(end, memory.page_size) orelse return Error.AddressOverflow;

        try plans.append(allocator, .{
            .header = header,
            .address = address,
            .page_range = .{ .start = page_start, .end = page_end },
            .protection = fromSegmentFlags(header.segmentFlags()),
        });
        try boundaries.append(allocator, page_start);
        try boundaries.append(allocator, page_end);
    }
    if (plans.items.len == 0) return Error.NoLoadSegments;

    std.mem.sort(u64, boundaries.items, {}, std.sort.asc(u64));

    var final_runs: std.ArrayList(ProtectionRun) = .empty;
    defer final_runs.deinit(allocator);
    var boundary_index: usize = 0;
    while (boundary_index + 1 < boundaries.items.len) : (boundary_index += 1) {
        const start = boundaries.items[boundary_index];
        const end = boundaries.items[boundary_index + 1];
        if (start == end) continue;

        var covered = false;
        var protection = memory.Protection.none;
        for (plans.items) |plan| {
            if (plan.page_range.start < end and start < plan.page_range.end) {
                covered = true;
                protection = mergeProtection(protection, plan.protection);
            }
        }
        if (!covered) continue;

        if (final_runs.items.len != 0) {
            const previous = &final_runs.items[final_runs.items.len - 1];
            if (previous.range.end == start and protectionsEqual(previous.protection, protection)) {
                previous.range.end = end;
                continue;
            }
        }
        try final_runs.append(allocator, .{
            .range = .{ .start = start, .end = end },
            .protection = protection,
        });
    }

    const entry_point = std.math.add(u64, options.load_bias, image.entryPoint()) catch
        return Error.AddressOverflow;
    var mapped = MappedImage{
        .address_space = address_space,
        .allocator = allocator,
        .load_bias = options.load_bias,
        .entry_point = entry_point,
        .relocation_stats = .{},
    };
    errdefer mapped.deinit();

    // Adjacent protection runs are one staging allocation. This also handles
    // ELF segments that share their boundary page.
    var run_index: usize = 0;
    while (run_index < final_runs.items.len) {
        const start = final_runs.items[run_index].range.start;
        var end = final_runs.items[run_index].range.end;
        run_index += 1;
        while (run_index < final_runs.items.len and final_runs.items[run_index].range.start == end) {
            end = final_runs.items[run_index].range.end;
            run_index += 1;
        }

        try address_space.mapFixed(
            start,
            end - start,
            .read_write,
            .module,
            null,
        );
        try mapped.ranges.append(allocator, .{ .start = start, .end = end });
    }

    // Anonymous committed pages start at zero, so copying filesz bytes also
    // gives every memsz-filesz tail the ELF-required zero fill.
    for (plans.items) |plan| {
        const file_bytes = try plan.header.fileRange(image.bytes);
        if (file_bytes.len != 0) try address_space.write(plan.address, file_bytes);
    }

    if (options.tls_registry) |registry| {
        mapped.tls_registry = registry;
        mapped.tls_module = try registry.registerImage(allocator, image, info);
    }

    mapped.relocation_stats = try linker.apply(
        allocator,
        address_space,
        image,
        info,
        options.load_bias,
        resolver,
        mapped.tls_module,
    );

    for (final_runs.items) |run| {
        try address_space.protect(run.range.start, run.range.len(), run.protection);
        if (run.protection.execute) {
            address_space.flushInstructionCache(run.range.start, run.range.len());
        }
    }

    if (!address_space.isMapped(entry_point, 1)) return Error.EntryPointUnmapped;
    return mapped;
}

fn fromSegmentFlags(flags: elf.SegmentFlags) memory.Protection {
    return .{
        .read = flags.readable,
        .write = flags.writable,
        .execute = flags.executable,
    };
}

fn mergeProtection(a: memory.Protection, b: memory.Protection) memory.Protection {
    return .{
        .read = a.read or b.read,
        .write = a.write or b.write,
        .execute = a.execute or b.execute,
    };
}

fn protectionsEqual(a: memory.Protection, b: memory.Protection) bool {
    return @as(u3, @bitCast(a)) == @as(u3, @bitCast(b));
}

fn alignDown(value: u64, alignment: u64) u64 {
    return value & ~(alignment - 1);
}

fn alignUp(value: u64, alignment: u64) ?u64 {
    const added = std.math.add(u64, value, alignment - 1) catch return null;
    return alignDown(added, alignment);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a load segment is copied at its exact guest address and finalized read-only" {
    const payload = "mapped guest bytes";
    const offset = elf.TestImage.payloadOffset(1);
    const segments = [_]elf.ProgramHeader{.{
        .type = @intFromEnum(elf.SegmentType.load),
        .flags = 0x4,
        .offset = offset,
        .vaddr = 0,
        .paddr = 0,
        .filesz = payload.len,
        .memsz = memory.page_size,
        .@"align" = memory.page_size,
    }};

    var fixture = try elf.TestImage.build(testing.allocator, .sce_dynexec, &segments, payload);
    defer fixture.deinit(testing.allocator);
    const image = try elf.parse(fixture.bytes());

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var info = dynamic.DynamicInfo{};
    defer info.deinit(testing.allocator);

    var mapped = try load(
        testing.allocator,
        &address_space,
        image,
        &info,
        null,
        .{ .load_bias = memory.system_managed.start },
    );
    defer mapped.deinit();

    var output: [payload.len]u8 = undefined;
    try address_space.read(memory.system_managed.start, &output);
    try testing.expectEqualStrings(payload, &output);
    try testing.expectError(
        memory.Error.ProtectionDenied,
        address_space.write(memory.system_managed.start, "x"),
    );
}
