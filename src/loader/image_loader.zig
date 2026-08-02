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
const exports = @import("exports.zig");

pub const Error = error{
    NoLoadSegments,
    InvalidLoadSegment,
    AddressOverflow,
    EntryPointUnmapped,
    InvalidInitializerTable,
    InitializerUnmapped,
} || elf.Error || linker.Error || tls.Error || exports.Error || memory.Error ||
    std.mem.Allocator.Error;

pub const Options = struct {
    /// Added to every segment virtual address, relocation target, and entry
    /// point. Fixed executables normally use zero; shared modules receive a
    /// caller-selected base.
    load_bias: u64 = 0,
    /// Process-wide TLS registry. Without one, ordinary images still load, but
    /// a TLS relocation reports that no module identity is available.
    tls_registry: ?*tls.Registry = null,
    /// Process-wide exports from mapped guest PRX modules.
    guest_export_registry: ?*exports.Registry = null,
};

pub const MappedImage = struct {
    address_space: *memory.AddressSpace,
    allocator: std.mem.Allocator,
    load_bias: u64,
    entry_point: u64,
    relocation_stats: linker.Stats,
    tls_registry: ?*tls.Registry = null,
    tls_module: ?tls.Module = null,
    guest_export_registry: ?*exports.Registry = null,
    guest_export_module: ?exports.Module = null,
    ranges: std.ArrayList(memory.Range) = .empty,
    process_param_range: ?memory.Range = null,
    preinit_functions: std.ArrayList(u64) = .empty,
    init_functions: std.ArrayList(u64) = .empty,
    preinitializers_ran: bool = false,
    initializers_ran: bool = false,

    /// Releases every committed range while retaining the process-wide outer
    /// address-space reservation.
    pub fn unload(self: *MappedImage) memory.Error!void {
        self.unregisterGuestExports();
        var i = self.ranges.items.len;
        while (i > 0) {
            i -= 1;
            const range = self.ranges.items[i];
            try self.address_space.unmap(range.start, range.len());
        }
        self.ranges.deinit(self.allocator);
        self.ranges = .empty;
        self.clearStartupMetadata();
        self.unregisterTls();
    }

    /// Best-effort teardown for defer paths. Use `unload` when an error must be
    /// reported to the caller.
    pub fn deinit(self: *MappedImage) void {
        self.unregisterGuestExports();
        var i = self.ranges.items.len;
        while (i > 0) {
            i -= 1;
            const range = self.ranges.items[i];
            self.address_space.unmap(range.start, range.len()) catch {};
        }
        self.ranges.deinit(self.allocator);
        self.ranges = .empty;
        self.clearStartupMetadata();
        self.unregisterTls();
    }

    fn clearStartupMetadata(self: *MappedImage) void {
        self.preinit_functions.deinit(self.allocator);
        self.preinit_functions = .empty;
        self.init_functions.deinit(self.allocator);
        self.init_functions = .empty;
        self.process_param_range = null;
        self.preinitializers_ran = false;
        self.initializers_ran = false;
    }

    fn unregisterTls(self: *MappedImage) void {
        if (self.tls_registry) |registry| {
            if (self.tls_module) |module| registry.unregister(self.allocator, module.id);
        }
        self.tls_registry = null;
        self.tls_module = null;
    }

    fn unregisterGuestExports(self: *MappedImage) void {
        if (self.guest_export_registry) |registry| {
            if (self.guest_export_module) |module| {
                registry.unregister(self.allocator, module.id);
            }
        }
        self.guest_export_registry = null;
        self.guest_export_module = null;
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

/// A mapped image whose exports are visible but whose relocations and final
/// page protections have not yet been installed. Mapping every node in a PRX
/// graph before linking permits mutual guest-to-guest imports.
pub const PreparedImage = struct {
    mapped: MappedImage,
    final_runs: std.ArrayList(ProtectionRun),

    pub fn deinit(self: *PreparedImage) void {
        self.final_runs.deinit(self.mapped.allocator);
        self.mapped.deinit();
    }
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
    var prepared = try prepare(allocator, address_space, image, info, options);
    errdefer prepared.deinit();
    return link(&prepared, image, info, resolver);
}

/// Maps image bytes and publishes TLS plus ordinary guest exports without
/// applying any relocation that may depend on another graph node.
pub fn prepare(
    allocator: std.mem.Allocator,
    address_space: *memory.AddressSpace,
    image: elf.Image,
    info: *const dynamic.DynamicInfo,
    options: Options,
) Error!PreparedImage {
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
        _ = try image.fileRange(header);

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
    errdefer final_runs.deinit(allocator);
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

    if (image.findSegment(.sce_procparam)) |header| {
        if (header.memsz != 0) {
            const address = std.math.add(u64, options.load_bias, header.vaddr) catch
                return Error.AddressOverflow;
            const end = std.math.add(u64, address, header.memsz) catch
                return Error.AddressOverflow;
            mapped.process_param_range = .{ .start = address, .end = end };
        }
    }

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
        const file_bytes = try image.fileRange(plan.header);
        if (file_bytes.len != 0) try address_space.write(plan.address, file_bytes);
    }

    if (options.tls_registry) |registry| {
        mapped.tls_registry = registry;
        mapped.tls_module = try registry.registerImage(allocator, image, info);
    }

    if (options.guest_export_registry) |registry| {
        mapped.guest_export_registry = registry;
        mapped.guest_export_module = try registry.registerImage(
            allocator,
            image,
            info,
            options.load_bias,
        );
    }

    return .{ .mapped = mapped, .final_runs = final_runs };
}

/// Relocates and protects an image previously returned by `prepare`.
pub fn link(
    prepared: *PreparedImage,
    image: elf.Image,
    info: *const dynamic.DynamicInfo,
    resolver: ?linker.Resolver,
) Error!MappedImage {
    const mapped = &prepared.mapped;

    mapped.relocation_stats = try linker.apply(
        mapped.allocator,
        mapped.address_space,
        image,
        info,
        mapped.load_bias,
        resolver,
        mapped.tls_module,
    );

    for (prepared.final_runs.items) |run| {
        try mapped.address_space.protect(run.range.start, run.range.len(), run.protection);
        if (run.protection.execute) {
            mapped.address_space.flushInstructionCache(run.range.start, run.range.len());
        }
    }

    if (!mapped.address_space.isMapped(mapped.entry_point, 1)) return Error.EntryPointUnmapped;
    if (mapped.process_param_range) |range| {
        if (!mapped.address_space.isMapped(range.start, range.len())) {
            return Error.InvalidLoadSegment;
        }
    }
    try collectStartupFunctions(mapped, info, image.objectType());

    prepared.final_runs.deinit(mapped.allocator);
    const result = mapped.*;
    prepared.* = undefined;
    return result;
}

fn collectStartupFunctions(
    mapped: *MappedImage,
    info: *const dynamic.DynamicInfo,
    object_type: elf.ObjectType,
) Error!void {
    if (object_type.isExecutable()) {
        try appendInitializerArray(
            mapped,
            &mapped.preinit_functions,
            info.preinit_array_virtual_address,
            info.preinit_array_size,
        );
    }

    // Some current images advertise DT_INIT inside a non-executable header.
    // Treat that direct tag as absent unless it resolves to executable memory;
    // array entries remain strict because each is explicitly callable data.
    if (info.init_virtual_address) |virtual_address| {
        if (virtual_address != 0 and virtual_address != std.math.maxInt(u64)) {
            if (resolveExecutableAddress(mapped, virtual_address)) |address| {
                try mapped.init_functions.append(mapped.allocator, address);
            }
        }
    }
    try appendInitializerArray(
        mapped,
        &mapped.init_functions,
        info.init_array_virtual_address,
        info.init_array_size,
    );
}

fn appendInitializerArray(
    mapped: *MappedImage,
    destination: *std.ArrayList(u64),
    virtual_address: ?u64,
    byte_size: ?u64,
) Error!void {
    if (virtual_address == null and byte_size == null) return;
    const raw_address = virtual_address orelse return Error.InvalidInitializerTable;
    const size = byte_size orelse return Error.InvalidInitializerTable;
    if (size == 0) return;
    if (size % @sizeOf(u64) != 0 or size > std.math.maxInt(usize)) {
        return Error.InvalidInitializerTable;
    }
    const address = std.math.add(u64, mapped.load_bias, raw_address) catch
        return Error.AddressOverflow;
    const entry_count: usize = @intCast(size / @sizeOf(u64));
    var bytes: [@sizeOf(u64)]u8 = undefined;
    for (0..entry_count) |index| {
        const offset = std.math.mul(u64, @intCast(index), @sizeOf(u64)) catch
            return Error.InvalidInitializerTable;
        const entry_address = std.math.add(u64, address, offset) catch
            return Error.AddressOverflow;
        mapped.address_space.read(entry_address, &bytes) catch
            return Error.InvalidInitializerTable;
        const raw_entry = std.mem.readInt(u64, &bytes, .little);
        if (raw_entry == 0 or raw_entry == std.math.maxInt(u64)) continue;
        const function = resolveExecutableAddress(mapped, raw_entry) orelse
            return Error.InitializerUnmapped;
        try destination.append(mapped.allocator, function);
    }
}

fn resolveExecutableAddress(mapped: *MappedImage, raw_address: u64) ?u64 {
    if (isExecutable(mapped.address_space, raw_address)) return raw_address;
    const biased = std.math.add(u64, mapped.load_bias, raw_address) catch return null;
    return if (isExecutable(mapped.address_space, biased)) biased else null;
}

fn isExecutable(address_space: *memory.AddressSpace, address: u64) bool {
    const mapping = address_space.query(address, false) orelse return false;
    return mapping.kind != .reserved and mapping.protection.execute;
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

test "startup functions resolve direct and array entries in ABI order" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    const image_base = memory.system_managed.start;
    const array_address = image_base + memory.page_size;
    try address_space.mapFixed(
        image_base,
        memory.page_size,
        .read_write,
        .module,
        null,
    );
    try address_space.mapFixed(
        array_address,
        memory.page_size,
        .read_write,
        .module,
        null,
    );

    try address_space.writeInt(u64, array_address + 0x00, image_base + 0x100);
    try address_space.writeInt(u64, array_address + 0x08, std.math.maxInt(u64));
    try address_space.writeInt(u64, array_address + 0x10, 0x200);
    try address_space.writeInt(u64, array_address + 0x18, 0);
    try address_space.protect(image_base, memory.page_size, .read_execute);
    try address_space.protect(array_address, memory.page_size, .read_only);

    var mapped = MappedImage{
        .address_space = &address_space,
        .allocator = testing.allocator,
        .load_bias = image_base,
        .entry_point = image_base,
        .relocation_stats = .{},
    };
    defer mapped.deinit();
    const info = dynamic.DynamicInfo{
        .init_virtual_address = 0x180,
        .preinit_array_virtual_address = memory.page_size,
        .preinit_array_size = 16,
        .init_array_virtual_address = memory.page_size + 0x10,
        .init_array_size = 16,
    };
    try collectStartupFunctions(&mapped, &info, .sce_dynexec);

    try testing.expectEqualSlices(
        u64,
        &.{image_base + 0x100},
        mapped.preinit_functions.items,
    );
    try testing.expectEqualSlices(
        u64,
        &.{ image_base + 0x180, image_base + 0x200 },
        mapped.init_functions.items,
    );
}

test "startup metadata ignores a null direct initializer and rejects incomplete arrays" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    const image_base = memory.system_managed.start;
    try address_space.mapFixed(
        image_base,
        memory.page_size,
        .read_execute,
        .module,
        null,
    );
    var mapped = MappedImage{
        .address_space = &address_space,
        .allocator = testing.allocator,
        .load_bias = image_base,
        .entry_point = image_base,
        .relocation_stats = .{},
    };
    defer mapped.deinit();

    try collectStartupFunctions(
        &mapped,
        &.{ .init_virtual_address = 0 },
        .sce_dynexec,
    );
    try testing.expectEqual(@as(usize, 0), mapped.init_functions.items.len);
    try testing.expectError(
        error.InvalidInitializerTable,
        collectStartupFunctions(
            &mapped,
            &.{ .init_array_virtual_address = 0 },
            .sce_dynexec,
        ),
    );
    try testing.expectError(
        error.InvalidInitializerTable,
        collectStartupFunctions(
            &mapped,
            &.{ .init_array_size = @sizeOf(u64) },
            .sce_dynexec,
        ),
    );
}

test "load publishes process parameters and relocated startup functions" {
    const image_base = memory.system_managed.start;
    const payload_size: usize = @intCast(memory.page_size * 2);
    const payload = try testing.allocator.alloc(u8, payload_size);
    defer testing.allocator.free(payload);
    @memset(payload, 0);
    std.mem.writeInt(u64, payload[@intCast(memory.page_size)..][0..8], 0x200, .little);

    const offset = elf.TestImage.payloadOffset(2);
    const segments = [_]elf.ProgramHeader{
        .{
            .type = @intFromEnum(elf.SegmentType.load),
            .flags = 0x7,
            .offset = offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = payload.len,
            .memsz = payload.len,
            .@"align" = memory.page_size,
        },
        .{
            .type = @intFromEnum(elf.SegmentType.sce_procparam),
            .flags = 0x4,
            .offset = offset + 0x300,
            .vaddr = 0x300,
            .paddr = 0,
            .filesz = 0x20,
            .memsz = 0x20,
            .@"align" = 8,
        },
    };
    var fixture = try elf.TestImage.build(
        testing.allocator,
        .sce_dynexec,
        &segments,
        payload,
    );
    defer fixture.deinit(testing.allocator);
    const image = try elf.parse(fixture.bytes());
    const info = dynamic.DynamicInfo{
        .init_virtual_address = 0x100,
        .init_array_virtual_address = memory.page_size,
        .init_array_size = 8,
    };
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    var mapped = try load(
        testing.allocator,
        &address_space,
        image,
        &info,
        null,
        .{ .load_bias = image_base },
    );
    defer mapped.deinit();

    try testing.expectEqual(
        memory.Range{ .start = image_base + 0x300, .end = image_base + 0x320 },
        mapped.process_param_range.?,
    );
    try testing.expectEqualSlices(
        u64,
        &.{ image_base + 0x100, image_base + 0x200 },
        mapped.init_functions.items,
    );
}
