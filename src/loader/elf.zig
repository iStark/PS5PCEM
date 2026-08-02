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
};

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
    bytes: []const u8,
    header: Header,
    program_headers: []align(1) const ProgramHeader,

    pub fn objectType(self: Image) ObjectType {
        return @enumFromInt(self.header.type);
    }

    pub fn entryPoint(self: Image) u64 {
        return self.header.entry;
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
        const ph = self.findSegment(.sce_dynlibdata) orelse return null;
        return try ph.fileRange(self.bytes);
    }

    /// Contents of the `PT_DYNAMIC` segment: the array of dynamic entries.
    pub fn dynamicData(self: Image) Error!?[]const u8 {
        const ph = self.findSegment(.dynamic) orelse return null;
        return try ph.fileRange(self.bytes);
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
    const header = try readAt(Header, bytes, 0);

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
    if (table_end > bytes.len) return Error.MalformedHeader;

    const start: usize = @intCast(header.phoff);
    const program_headers = std.mem.bytesAsSlice(
        ProgramHeader,
        bytes[start..@intCast(table_end)],
    );

    return .{
        .bytes = bytes,
        .header = header,
        .program_headers = program_headers,
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
    try testing.expectEqual(@as(usize, 4), (try loads[1].fileRange(parsed.bytes)).len);
}
