// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! ELF64 parsing for guest modules.
//!
//! Guest executables are ELF64 for x86-64 with vendor extensions: object types
//! and program header types outside the standard ranges, and a dedicated
//! segment holding the dynamic linking tables. Standard ELF readers reject the
//! object types outright, which is why this exists rather than reusing one.
//!
//! Parsing is non-owning and does not copy: every view borrows the caller's
//! buffer. Nothing here maps or executes anything.

const std = @import("std");
const self_container = @import("self.zig");

pub const Error = error{
    /// Too short to contain the structure being read.
    Truncated,
    /// Missing the ELF magic number.
    NotElf,
    /// Not a 64-bit little-endian object.
    UnsupportedFormat,
    /// Not an x86-64 object.
    UnsupportedMachine,
    /// Not an object type this loader handles.
    UnsupportedObjectType,
    /// A header field describes a range outside the file.
    MalformedHeader,
} || self_container.Error;

pub const magic = [4]u8{ 0x7f, 'E', 'L', 'F' };

const ei_class = 4;
const ei_data = 5;
const ei_version = 6;
const ei_osabi = 7;
const ei_nident = 16;

const elfclass64 = 2;
const elfdata2lsb = 1;
const ev_current = 1;
const em_x86_64 = 62;

/// Object types. The standard values are present for completeness; guest
/// modules use the vendor ones.
pub const ObjectType = enum(u16) {
    none = 0,
    rel = 1,
    exec = 2,
    dyn = 3,
    core = 4,
    /// A dynamically linked main executable.
    sce_dynexec = 0xfe10,
    /// A shared library.
    sce_dynamic = 0xfe18,
    _,

    /// Whether this loader can handle the object.
    pub fn isSupported(self: ObjectType) bool {
        return switch (self) {
            .sce_dynexec, .sce_dynamic => true,
            else => false,
        };
    }

    pub fn isExecutable(self: ObjectType) bool {
        return self == .sce_dynexec;
    }
};

/// Program header types.
pub const SegmentType = enum(u32) {
    null = 0,
    load = 1,
    dynamic = 2,
    interp = 3,
    note = 4,
    shlib = 5,
    phdr = 6,
    tls = 7,
    /// Holds the dynamic linking tables: string table, symbols, relocations.
    /// Unlike a normal ELF these are not addressed through the load segments,
    /// so they have to be read from here.
    sce_dynlibdata = 0x6100_0000,
    /// Process parameters the runtime hands to the guest.
    sce_procparam = 0x6100_0001,
    /// Region made read-only after relocation.
    sce_relro = 0x6100_0010,
    /// Exception-handling frame index. A C++ runtime locates this to find the
    /// unwind tables for a module, so a title that throws cannot recover
    /// without it.
    gnu_eh_frame = 0x6474_e550,
    /// Build provenance stored by newer PS5 toolchains.
    sce_comment_ps5 = 0x6fff_ff00,
    /// Dynamic linking data stored by newer PS5 toolchains.
    sce_dynlibdata_ps5 = 0x6fff_ff01,
    _,
};

pub const SegmentFlags = packed struct(u32) {
    executable: bool = false,
    writable: bool = false,
    readable: bool = false,
    _padding: u29 = 0,
};

/// The ELF64 file header, in file layout.
pub const Header = extern struct {
    ident: [ei_nident]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

/// A program header, in file layout.
pub const ProgramHeader = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    @"align": u64,

    pub fn segmentType(self: ProgramHeader) SegmentType {
        return @enumFromInt(self.type);
    }

    pub fn segmentFlags(self: ProgramHeader) SegmentFlags {
        return @bitCast(self.flags);
    }

    /// The segment's bytes within the file image.
    ///
    /// `filesz` may be smaller than `memsz`; the remainder is zero-filled at
    /// load time and has no file content.
    pub fn fileRange(self: ProgramHeader, image: []const u8) Error![]const u8 {
        const end = std.math.add(u64, self.offset, self.filesz) catch
            return Error.MalformedHeader;
        if (end > image.len) return Error.MalformedHeader;
        return image[@intCast(self.offset)..@intCast(end)];
    }
};

comptime {
    // These are read straight out of the file, so their layout is part of the
    // format rather than an implementation detail.
    std.debug.assert(@sizeOf(Header) == 64);
    std.debug.assert(@sizeOf(ProgramHeader) == 56);
}

/// A parsed module image. Borrows the buffer it was parsed from.
pub const Image = struct {
    /// Complete input file. For SELF images this includes the container header.
    bytes: []const u8,
    header: Header,
    program_headers: []align(1) const ProgramHeader,
    self_layout: ?self_container.Layout = null,

    pub fn objectType(self: Image) ObjectType {
        return @enumFromInt(self.header.type);
    }

    pub fn entryPoint(self: Image) u64 {
        return self.header.entry;
    }

    pub fn isSelf(self: Image) bool {
        return self.self_layout != null;
    }

    /// First segment of the given type, or null.
    pub fn findSegment(self: Image, segment_type: SegmentType) ?ProgramHeader {
        for (self.program_headers) |ph| {
            if (ph.segmentType() == segment_type) return ph;
        }
        return null;
    }

    /// Contents of the segment holding the dynamic linking tables.
    pub fn dynlibData(self: Image) Error!?[]const u8 {
        for (self.program_headers) |ph| {
            const segment_type = ph.segmentType();
            if (segment_type == .sce_dynlibdata or segment_type == .sce_dynlibdata_ps5) {
                return try self.fileRange(ph);
            }
        }
        return null;
    }

    /// Contents of the `PT_DYNAMIC` segment: the array of dynamic entries.
    pub fn dynamicData(self: Image) Error!?[]const u8 {
        const ph = self.findSegment(.dynamic) orelse return null;
        return try self.fileRange(ph);
    }

    /// Resolves one program header's logical file range to its stored bytes.
    ///
    /// Bare ELF images use `p_offset` directly. SELF images translate through
    /// the container segment whose program-header id covers the requested
    /// logical range.
    pub fn fileRange(self: Image, ph: ProgramHeader) Error![]const u8 {
        if (self.self_layout == null) return ph.fileRange(self.bytes);
        return self.logicalFileRange(ph.offset, ph.filesz);
    }

    /// Resolves a file-backed guest virtual-address range.
    pub fn virtualRange(self: Image, address: u64, size: u64) Error![]const u8 {
        const requested_end = std.math.add(u64, address, size) catch
            return Error.MalformedHeader;

        for (self.program_headers) |ph| {
            if (ph.segmentType() != .load) continue;
            const segment_end = std.math.add(u64, ph.vaddr, ph.filesz) catch
                return Error.MalformedHeader;
            if (address < ph.vaddr or requested_end > segment_end) continue;

            const delta = address - ph.vaddr;
            const logical_offset = std.math.add(u64, ph.offset, delta) catch
                return Error.MalformedHeader;
            return self.logicalFileRange(logical_offset, size);
        }
        return Error.MalformedHeader;
    }

    fn logicalFileRange(self: Image, offset: u64, size: u64) Error![]const u8 {
        const requested_end = std.math.add(u64, offset, size) catch
            return Error.MalformedHeader;
        if (size == 0) return self.bytes[0..0];

        const layout = self.self_layout orelse {
            if (requested_end > self.bytes.len) return Error.MalformedHeader;
            return self.bytes[@intCast(offset)..@intCast(requested_end)];
        };

        // Ordinary SELF-backed ranges, including PT_DYNAMIC and PT_TLS views
        // nested inside a mapped PT_LOAD segment.
        for (layout.segments) |segment| {
            if (!segment.isBlocked()) continue;
            const ph = self.program_headers[segment.programHeaderIndex()];
            const ph_end = std.math.add(u64, ph.offset, ph.filesz) catch
                return Error.MalformedSelf;
            if (offset < ph.offset or requested_end > ph_end) continue;

            const delta = offset - ph.offset;
            const physical = std.math.add(u64, segment.offset, delta) catch
                return Error.MalformedSelf;
            return self.physicalRange(physical, size);
        }

        // Some decrypted PS5 images append PT_SCE_DYNLIBDATA directly after
        // the last blocked payload without giving it a SELF entry. Logical
        // NOTE segments and alignment gaps between them are not stored, so the
        // ELF offset delta must deliberately not be carried into this mapping.
        var is_unlisted_dynlib = false;
        for (self.program_headers) |ph| {
            if (ph.segmentType() == .sce_dynlibdata_ps5 and
                ph.offset == offset and ph.filesz == size)
            {
                is_unlisted_dynlib = true;
                break;
            }
        }
        if (!is_unlisted_dynlib) return Error.MalformedSelf;

        var last_physical_end: u64 = 0;
        var have_tail = false;
        for (layout.segments) |segment| {
            if (!segment.isBlocked()) continue;
            const physical = std.math.add(u64, segment.offset, segment.decompressed_size) catch
                return Error.MalformedSelf;
            if (!have_tail or physical > last_physical_end) {
                last_physical_end = physical;
                have_tail = true;
            }
        }
        if (!have_tail) return Error.MalformedSelf;
        return self.physicalRange(last_physical_end, size);
    }

    fn physicalRange(self: Image, offset: u64, size: u64) Error![]const u8 {
        const end = std.math.add(u64, offset, size) catch return Error.MalformedSelf;
        if (end > self.bytes.len) return Error.TruncatedSelf;
        return self.bytes[@intCast(offset)..@intCast(end)];
    }

    /// Segments that occupy address space at load time.
    ///
    /// Returned in file order, which is not necessarily address order.
    pub fn loadSegments(self: Image, buffer: []ProgramHeader) []ProgramHeader {
        var n: usize = 0;
        for (self.program_headers) |ph| {
            if (ph.segmentType() != .load) continue;
            if (n >= buffer.len) break;
            buffer[n] = ph;
            n += 1;
        }
        return buffer[0..n];
    }
};

/// Reads a value of type `T` from `bytes` at `offset` without assuming
/// alignment, since nothing in an ELF image is guaranteed to be aligned.
fn readAt(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    const end = std.math.add(usize, offset, @sizeOf(T)) catch return Error.Truncated;
    if (end > bytes.len) return Error.Truncated;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[offset..end]);
    return value;
}

/// Parses the header and program headers of a module image.
///
/// Validation is deliberately strict. A guest module that fails these checks is
/// not something to load with best effort — proceeding would mean interpreting
/// whatever follows as code.
pub fn parse(bytes: []const u8) Error!Image {
    const self_layout = try self_container.parse(bytes);
    const elf_bytes = if (self_layout) |layout| bytes[layout.elf_offset..] else bytes;
    const header = try readAt(Header, elf_bytes, 0);

    if (!std.mem.eql(u8, header.ident[0..4], &magic)) return Error.NotElf;
    if (header.ident[ei_class] != elfclass64) return Error.UnsupportedFormat;
    if (header.ident[ei_data] != elfdata2lsb) return Error.UnsupportedFormat;
    if (header.ident[ei_version] != ev_current) return Error.UnsupportedFormat;
    if (header.machine != em_x86_64) return Error.UnsupportedMachine;

    const object_type: ObjectType = @enumFromInt(header.type);
    if (!object_type.isSupported()) return Error.UnsupportedObjectType;

    if (header.phentsize != @sizeOf(ProgramHeader)) return Error.MalformedHeader;

    const table_size = std.math.mul(u64, header.phentsize, header.phnum) catch
        return Error.MalformedHeader;
    const table_end = std.math.add(u64, header.phoff, table_size) catch
        return Error.MalformedHeader;
    if (table_end > elf_bytes.len) return Error.MalformedHeader;

    const start: usize = @intCast(header.phoff);
    const program_headers = std.mem.bytesAsSlice(
        ProgramHeader,
        elf_bytes[start..@intCast(table_end)],
    );

    if (self_layout) |layout| {
        for (layout.segments) |segment| {
            if (!segment.isBlocked()) continue;
            const index = segment.programHeaderIndex();
            if (index >= program_headers.len) return Error.MalformedSelf;
            if (segment.decompressed_size != program_headers[index].filesz) {
                return Error.MalformedSelf;
            }
        }
    }

    return .{
        .bytes = bytes,
        .header = header,
        .program_headers = program_headers,
        .self_layout = self_layout,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a minimal but well-formed image for tests.
pub const TestImage = struct {
    buffer: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *TestImage, gpa: std.mem.Allocator) void {
        self.buffer.deinit(gpa);
    }

    pub fn build(
        gpa: std.mem.Allocator,
        object_type: ObjectType,
        segments: []const ProgramHeader,
        payload: []const u8,
    ) !TestImage {
        var self = TestImage{};
        errdefer self.deinit(gpa);

        var header = std.mem.zeroes(Header);
        @memcpy(header.ident[0..4], &magic);
        header.ident[ei_class] = elfclass64;
        header.ident[ei_data] = elfdata2lsb;
        header.ident[ei_version] = ev_current;
        header.machine = em_x86_64;
        header.type = @intFromEnum(object_type);
        header.entry = 0x1000;
        header.ehsize = @sizeOf(Header);
        header.phoff = @sizeOf(Header);
        header.phentsize = @sizeOf(ProgramHeader);
        header.phnum = @intCast(segments.len);

        try self.buffer.appendSlice(gpa, std.mem.asBytes(&header));
        for (segments) |ph| {
            try self.buffer.appendSlice(gpa, std.mem.asBytes(&ph));
        }
        try self.buffer.appendSlice(gpa, payload);
        return self;
    }

    pub fn bytes(self: *const TestImage) []const u8 {
        return self.buffer.items;
    }

    /// File offset at which the payload begins, for building segment headers.
    pub fn payloadOffset(segment_count: usize) u64 {
        return @sizeOf(Header) + @sizeOf(ProgramHeader) * segment_count;
    }
};

test "a well-formed executable parses" {
    const payload = "dynamic data";
    const offset = TestImage.payloadOffset(1);
    const segments = [_]ProgramHeader{.{
        .type = @intFromEnum(SegmentType.sce_dynlibdata),
        .flags = 0,
        .offset = offset,
        .vaddr = 0,
        .paddr = 0,
        .filesz = payload.len,
        .memsz = payload.len,
        .@"align" = 1,
    }};

    var img = try TestImage.build(testing.allocator, .sce_dynexec, &segments, payload);
    defer img.deinit(testing.allocator);

    const parsed = try parse(img.bytes());
    try testing.expectEqual(ObjectType.sce_dynexec, parsed.objectType());
    try testing.expect(parsed.objectType().isExecutable());
    try testing.expectEqual(@as(u64, 0x1000), parsed.entryPoint());
    try testing.expectEqual(@as(usize, 1), parsed.program_headers.len);

    const data = (try parsed.dynlibData()) orelse return error.TestExpectedSegment;
    try testing.expectEqualStrings(payload, data);
}

test "a shared library is accepted but is not executable" {
    var img = try TestImage.build(testing.allocator, .sce_dynamic, &.{}, "");
    defer img.deinit(testing.allocator);

    const parsed = try parse(img.bytes());
    try testing.expect(parsed.objectType().isSupported());
    try testing.expect(!parsed.objectType().isExecutable());
}

test "host object types are rejected" {
    // A plain ET_DYN object is a host shared library, not a guest module.
    var img = try TestImage.build(testing.allocator, .dyn, &.{}, "");
    defer img.deinit(testing.allocator);

    try testing.expectError(Error.UnsupportedObjectType, parse(img.bytes()));
}

test "malformed images are rejected rather than parsed loosely" {
    try testing.expectError(Error.Truncated, parse("short"));
    try testing.expectError(Error.NotElf, parse(&[_]u8{0} ** 64));

    var img = try TestImage.build(testing.allocator, .sce_dynexec, &.{}, "");
    defer img.deinit(testing.allocator);

    // Wrong class.
    {
        var bad = try testing.allocator.dupe(u8, img.bytes());
        defer testing.allocator.free(bad);
        bad[ei_class] = 1; // 32-bit
        try testing.expectError(Error.UnsupportedFormat, parse(bad));
    }
    // Wrong machine.
    {
        var bad = try testing.allocator.dupe(u8, img.bytes());
        defer testing.allocator.free(bad);
        std.mem.writeInt(u16, bad[18..20], 0x28, .little); // ARM
        try testing.expectError(Error.UnsupportedMachine, parse(bad));
    }
    // A program header table that runs past the end of the file.
    {
        var bad = try testing.allocator.dupe(u8, img.bytes());
        defer testing.allocator.free(bad);
        std.mem.writeInt(u16, bad[56..58], 100, .little); // phnum
        try testing.expectError(Error.MalformedHeader, parse(bad));
    }
}

test "a segment reaching past the file is rejected when read" {
    const offset = TestImage.payloadOffset(1);
    const segments = [_]ProgramHeader{.{
        .type = @intFromEnum(SegmentType.sce_dynlibdata),
        .flags = 0,
        .offset = offset,
        .vaddr = 0,
        .paddr = 0,
        .filesz = 4096, // far beyond the payload actually written
        .memsz = 4096,
        .@"align" = 1,
    }};

    var img = try TestImage.build(testing.allocator, .sce_dynexec, &segments, "tiny");
    defer img.deinit(testing.allocator);

    const parsed = try parse(img.bytes());
    try testing.expectError(Error.MalformedHeader, parsed.dynlibData());
}

test "load segments are collected and flags decoded" {
    const offset = TestImage.payloadOffset(3);
    const segments = [_]ProgramHeader{
        .{
            .type = @intFromEnum(SegmentType.load),
            .flags = 0x4 | 0x1, // readable, executable
            .offset = offset,
            .vaddr = 0x1000,
            .paddr = 0,
            .filesz = 4,
            .memsz = 4,
            .@"align" = 0x4000,
        },
        .{
            .type = @intFromEnum(SegmentType.dynamic),
            .flags = 0x4,
            .offset = offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = 4,
            .memsz = 4,
            .@"align" = 8,
        },
        .{
            .type = @intFromEnum(SegmentType.load),
            .flags = 0x4 | 0x2, // readable, writable
            .offset = offset,
            .vaddr = 0x2000,
            .paddr = 0,
            .filesz = 4,
            .memsz = 0x100, // zero-filled tail
            .@"align" = 0x4000,
        },
    };

    var img = try TestImage.build(testing.allocator, .sce_dynexec, &segments, "code");
    defer img.deinit(testing.allocator);

    const parsed = try parse(img.bytes());

    var buf: [8]ProgramHeader = undefined;
    const loads = parsed.loadSegments(&buf);
    try testing.expectEqual(@as(usize, 2), loads.len);

    const text = loads[0].segmentFlags();
    try testing.expect(text.readable and text.executable and !text.writable);

    const data = loads[1].segmentFlags();
    try testing.expect(data.readable and data.writable and !data.executable);
    // The zero-filled tail is not backed by file content.
    try testing.expect(loads[1].memsz > loads[1].filesz);
    try testing.expectEqual(@as(usize, 4), (try parsed.fileRange(loads[1])).len);
}

test "decrypted SELF maps logical program offsets to physical segments" {
    const payload = "guest code";
    const logical_offset: u64 = 0x4000;
    const physical_offset: usize = 0x200;

    const ph = ProgramHeader{
        .type = @intFromEnum(SegmentType.load),
        .flags = 0x5,
        .offset = logical_offset,
        .vaddr = 0x1000,
        .paddr = 0,
        .filesz = payload.len,
        .memsz = payload.len,
        .@"align" = 0x4000,
    };

    var elf_header = std.mem.zeroes(Header);
    @memcpy(elf_header.ident[0..4], &magic);
    elf_header.ident[ei_class] = elfclass64;
    elf_header.ident[ei_data] = elfdata2lsb;
    elf_header.ident[ei_version] = ev_current;
    elf_header.type = @intFromEnum(ObjectType.sce_dynexec);
    elf_header.machine = em_x86_64;
    elf_header.version = ev_current;
    elf_header.entry = 0x1000;
    elf_header.ehsize = @sizeOf(Header);
    elf_header.phoff = @sizeOf(Header);
    elf_header.phentsize = @sizeOf(ProgramHeader);
    elf_header.phnum = 1;

    var self_header = std.mem.zeroes(self_container.Header);
    @memcpy(self_header.ident[0..4], &self_container.magic);
    self_header.ident[5] = 1;
    self_header.ident[6] = 1;
    self_header.ident[7] = 0x12;
    self_header.segment_count = 1;
    const self_segment = self_container.Segment{
        .type = 0x800,
        .offset = physical_offset,
        .compressed_size = payload.len,
        .decompressed_size = payload.len,
    };

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&self_header));
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&self_segment));
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&elf_header));
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&ph));
    try bytes.appendNTimes(testing.allocator, 0, physical_offset - bytes.items.len);
    try bytes.appendSlice(testing.allocator, payload);

    const image = try parse(bytes.items);
    try testing.expect(image.isSelf());
    try testing.expectEqualStrings(payload, try image.fileRange(image.program_headers[0]));
    try testing.expectEqualStrings(payload, try image.virtualRange(0x1000, payload.len));

    var bad_id = try testing.allocator.dupe(u8, bytes.items);
    defer testing.allocator.free(bad_id);
    std.mem.writeInt(u64, bad_id[32..40], 0x800 | (@as(u64, 1) << 20), .little);
    try testing.expectError(Error.MalformedSelf, parse(bad_id));
}

test "SELF resolves an unlisted dynlib-data tail after logical padding" {
    const comment = "PATH";
    const dynlib = "TABLE";
    const padding = 3;
    const physical_offset: usize = 0x200;
    const logical_offset: u64 = 0x8000;
    const segments = [_]ProgramHeader{
        .{
            .type = @intFromEnum(SegmentType.sce_comment_ps5),
            .flags = 0,
            .offset = logical_offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = comment.len,
            .memsz = 0,
            .@"align" = 1,
        },
        .{
            .type = @intFromEnum(SegmentType.sce_dynlibdata_ps5),
            .flags = 0,
            .offset = logical_offset + comment.len + padding,
            .vaddr = 0,
            .paddr = 0,
            .filesz = dynlib.len,
            .memsz = dynlib.len,
            .@"align" = 1,
        },
    };

    var elf_header = std.mem.zeroes(Header);
    @memcpy(elf_header.ident[0..4], &magic);
    elf_header.ident[ei_class] = elfclass64;
    elf_header.ident[ei_data] = elfdata2lsb;
    elf_header.ident[ei_version] = ev_current;
    elf_header.type = @intFromEnum(ObjectType.sce_dynexec);
    elf_header.machine = em_x86_64;
    elf_header.version = ev_current;
    elf_header.ehsize = @sizeOf(Header);
    elf_header.phoff = @sizeOf(Header);
    elf_header.phentsize = @sizeOf(ProgramHeader);
    elf_header.phnum = segments.len;

    var self_header = std.mem.zeroes(self_container.Header);
    @memcpy(self_header.ident[0..4], &self_container.magic);
    self_header.ident[5] = 1;
    self_header.ident[6] = 1;
    self_header.ident[7] = 0x12;
    self_header.segment_count = 1;
    const self_segment = self_container.Segment{
        .type = 0x800,
        .offset = physical_offset,
        .compressed_size = comment.len,
        .decompressed_size = comment.len,
    };

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&self_header));
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&self_segment));
    try bytes.appendSlice(testing.allocator, std.mem.asBytes(&elf_header));
    for (segments) |segment| try bytes.appendSlice(testing.allocator, std.mem.asBytes(&segment));
    try bytes.appendNTimes(testing.allocator, 0, physical_offset - bytes.items.len);
    try bytes.appendSlice(testing.allocator, comment);
    try bytes.appendSlice(testing.allocator, dynlib);

    const image = try parse(bytes.items);
    try testing.expectEqualStrings(dynlib, (try image.dynlibData()).?);
}
