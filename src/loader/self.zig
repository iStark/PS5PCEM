// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Read-only parsing for decrypted PlayStation SELF containers.
//!
//! A SELF keeps the ELF header and program-header table near the front of the
//! file, but stores program contents in independently addressed container
//! segments. The ELF `p_offset` values remain logical offsets and therefore
//! cannot be used directly against the SELF byte buffer.

const std = @import("std");

pub const Error = error{
    TruncatedSelf,
    MalformedSelf,
    UnsupportedSelfLayout,
    EncryptedSelfUnsupported,
    CompressedSelfUnsupported,
};

/// Raw PS5 SELF signature as it appears in the file.
pub const magic = [4]u8{ 0x54, 0x14, 0xf5, 0xee };

const segment_blocked: u64 = 0x800;
const segment_encrypted: u64 = 0x2;
const segment_compressed: u64 = 0x8;

pub const Header = extern struct {
    ident: [12]u8,
    header_size: u16,
    meta_size: u16,
    file_size: u64,
    segment_count: u16,
    flags: u16,
    padding: u32,
};

pub const Segment = extern struct {
    type: u64,
    offset: u64,
    compressed_size: u64,
    decompressed_size: u64,

    pub fn isBlocked(self: Segment) bool {
        return self.type & segment_blocked != 0;
    }

    pub fn isEncrypted(self: Segment) bool {
        return self.type & segment_encrypted != 0;
    }

    pub fn isCompressed(self: Segment) bool {
        return self.type & segment_compressed != 0 or
            self.compressed_size != self.decompressed_size;
    }

    pub fn programHeaderIndex(self: Segment) usize {
        return @intCast((self.type >> 20) & 0xfff);
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == 32);
    std.debug.assert(@sizeOf(Segment) == 32);
}

pub const Layout = struct {
    header: Header,
    segments: []align(1) const Segment,
    elf_offset: usize,
};

fn readAt(comptime T: type, bytes: []const u8, offset: usize) Error!T {
    const end = std.math.add(usize, offset, @sizeOf(T)) catch
        return Error.TruncatedSelf;
    if (end > bytes.len) return Error.TruncatedSelf;

    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[offset..end]);
    return value;
}

/// Returns null for a bare ELF and a validated layout for a PS5 SELF.
pub fn parse(bytes: []const u8) Error!?Layout {
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], &magic)) {
        return null;
    }

    const header = try readAt(Header, bytes, 0);
    // Signing fields vary, but these bytes identify the fixed SELF layout used
    // by decrypted/fake-signed PS5 executables.
    if (header.ident[5] != 1 or header.ident[6] != 1 or header.ident[7] != 0x12) {
        return Error.UnsupportedSelfLayout;
    }

    const table_size = std.math.mul(
        usize,
        header.segment_count,
        @sizeOf(Segment),
    ) catch return Error.MalformedSelf;
    const table_end = std.math.add(usize, @sizeOf(Header), table_size) catch
        return Error.MalformedSelf;
    if (table_end > bytes.len) return Error.TruncatedSelf;

    const segments = std.mem.bytesAsSlice(
        Segment,
        bytes[@sizeOf(Header)..table_end],
    );
    for (segments) |segment| {
        const stored_end = std.math.add(u64, segment.offset, segment.compressed_size) catch
            return Error.MalformedSelf;
        if (stored_end > bytes.len) return Error.TruncatedSelf;

        if (!segment.isBlocked()) continue;
        if (segment.isEncrypted()) return Error.EncryptedSelfUnsupported;
        if (segment.isCompressed()) return Error.CompressedSelfUnsupported;
    }

    return .{
        .header = header,
        .segments = segments,
        .elf_offset = table_end,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn appendValue(list: *std.ArrayList(u8), value: anytype) !void {
    try list.appendSlice(testing.allocator, std.mem.asBytes(&value));
}

test "bare input is not treated as SELF" {
    try testing.expect((try parse("not a SELF image")) == null);
}

test "decrypted PS5 SELF layout is parsed without copying" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    var header = std.mem.zeroes(Header);
    @memcpy(header.ident[0..4], &magic);
    header.ident[5] = 1;
    header.ident[6] = 1;
    header.ident[7] = 0x12;
    header.segment_count = 1;

    const segment = Segment{
        .type = segment_blocked,
        .offset = 0x80,
        .compressed_size = 4,
        .decompressed_size = 4,
    };
    try appendValue(&bytes, header);
    try appendValue(&bytes, segment);
    try bytes.appendNTimes(testing.allocator, 0, 0x80 - bytes.items.len);
    try bytes.appendSlice(testing.allocator, "SELF");

    const layout = (try parse(bytes.items)) orelse return error.TestExpectedSelf;
    try testing.expectEqual(@as(usize, 64), layout.elf_offset);
    try testing.expectEqual(@as(usize, 1), layout.segments.len);
    try testing.expect(layout.segments[0].isBlocked());
    try testing.expectEqual(@as(usize, 0), layout.segments[0].programHeaderIndex());
}

test "truncated SELF tables and payload ranges are rejected" {
    try testing.expectError(Error.TruncatedSelf, parse(&magic));

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    var header = std.mem.zeroes(Header);
    @memcpy(header.ident[0..4], &magic);
    header.ident[5] = 1;
    header.ident[6] = 1;
    header.ident[7] = 0x12;
    header.segment_count = 1;
    try appendValue(&bytes, header);
    try testing.expectError(Error.TruncatedSelf, parse(bytes.items));

    const segment = Segment{
        .type = segment_blocked,
        .offset = 0x100,
        .compressed_size = 4,
        .decompressed_size = 4,
    };
    try appendValue(&bytes, segment);
    try testing.expectError(Error.TruncatedSelf, parse(bytes.items));
}

test "encrypted and compressed SELF payloads are rejected explicitly" {
    for ([_]u64{ segment_blocked | segment_encrypted, segment_blocked | segment_compressed }) |kind| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(testing.allocator);

        var header = std.mem.zeroes(Header);
        @memcpy(header.ident[0..4], &magic);
        header.ident[5] = 1;
        header.ident[6] = 1;
        header.ident[7] = 0x12;
        header.segment_count = 1;

        const segment = Segment{
            .type = kind,
            .offset = 64,
            .compressed_size = 0,
            .decompressed_size = 0,
        };
        try appendValue(&bytes, header);
        try appendValue(&bytes, segment);

        if (kind & segment_encrypted != 0) {
            try testing.expectError(Error.EncryptedSelfUnsupported, parse(bytes.items));
        } else {
            try testing.expectError(Error.CompressedSelfUnsupported, parse(bytes.items));
        }
    }
}
