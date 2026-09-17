// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! PS5 package (PKG) inspection and metadata extraction.
//!
//! Debug finalized images (`\x7FFIH`, signed byte 0x00) wrap a `\x7FCNT`
//! metadata container and an outer PFS. This module reads the FIH header,
//! parses the embedded CNT, copies unencrypted CNT entries (param.json,
//! icons, PlayGo tables, …) into an `sce_sys` tree, and unpacks uncompressed
//! SELF modules (`eboot.bin`, `sce_module/*.prx`) from the nested
//! `pfs_image.dat` of a debug / passcode image. Retail images (signed byte
//! `0x80`) are refused. Kraken-compressed inner assets are not unpacked.

const std = @import("std");

pub const pfs = @import("pfs.zig");

pub const fih_magic = [4]u8{ 0x7f, 'F', 'I', 'H' };
pub const cnt_magic = [4]u8{ 0x7f, 'C', 'N', 'T' };

pub const Kind = enum { fih_debug, fih_retail, cnt };

pub const Error = error{
    NotAPackage,
    RetailPackage,
    TruncatedPackage,
    InvalidCnt,
    EncryptedEntry,
    Io,
};

pub const FihHeader = struct {
    signed_byte: u8,
    format_version: u16,
    pfs_offset: u64,
    pfs_size: u64,
    superblock_offset: u64,
    cnt_offset: u64,
    file_size: u64,

    pub fn kind(self: FihHeader) Kind {
        return if (self.signed_byte == 0) .fih_debug else .fih_retail;
    }
};

pub const CntEntry = struct {
    id: u32,
    name_offset: u32,
    flags1: u32,
    flags2: u32,
    offset: u32,
    size: u32,

    pub fn encrypted(self: CntEntry) bool {
        return self.flags1 & 0x8000_0000 != 0;
    }
};

pub const CntInfo = struct {
    content_id: [36]u8,
    file_count: u32,
    entry_count: u32,
    table_offset: u32,
    body_offset: u64,
    body_size: u64,

    pub fn contentId(self: *const CntInfo) []const u8 {
        const slice = std.mem.sliceTo(&self.content_id, 0);
        return if (slice.len == 0) self.content_id[0..] else slice;
    }
};

pub fn detectKind(header: []const u8) ?Kind {
    if (header.len < 4) return null;
    if (std.mem.eql(u8, header[0..4], &fih_magic)) {
        const signed_byte: u8 = if (header.len > 5) header[5] else 0;
        return if (signed_byte == 0) .fih_debug else .fih_retail;
    }
    if (std.mem.eql(u8, header[0..4], &cnt_magic)) return .cnt;
    return null;
}

pub fn parseFih(header: []const u8, file_size: u64) Error!FihHeader {
    if (header.len < 0xa8) return error.TruncatedPackage;
    if (!std.mem.eql(u8, header[0..4], &fih_magic)) return error.NotAPackage;
    const parsed = FihHeader{
        .signed_byte = header[5],
        .format_version = std.mem.readInt(u16, header[6..8], .little),
        .pfs_offset = std.mem.readInt(u64, header[0x10..0x18], .little),
        .pfs_size = std.mem.readInt(u64, header[0x18..0x20], .little),
        .superblock_offset = std.mem.readInt(u64, header[0x20..0x28], .little),
        .cnt_offset = std.mem.readInt(u64, header[0x58..0x60], .little),
        .file_size = file_size,
    };
    if (parsed.cnt_offset == 0 or parsed.cnt_offset >= file_size) return error.TruncatedPackage;
    return parsed;
}

pub fn parseCnt(cnt: []const u8) Error!CntInfo {
    if (cnt.len < 0x70) return error.TruncatedPackage;
    if (!std.mem.eql(u8, cnt[0..4], &cnt_magic)) return error.InvalidCnt;
    var content_id: [36]u8 = undefined;
    @memcpy(&content_id, cnt[0x40..0x64]);
    const info = CntInfo{
        .content_id = content_id,
        .file_count = std.mem.readInt(u32, cnt[12..16], .big),
        .entry_count = std.mem.readInt(u32, cnt[16..20], .big),
        .table_offset = std.mem.readInt(u32, cnt[24..28], .big),
        .body_offset = std.mem.readInt(u64, cnt[0x20..0x28], .big),
        .body_size = std.mem.readInt(u64, cnt[0x28..0x30], .big),
    };
    const table_end = @as(u64, info.table_offset) + @as(u64, info.entry_count) * 0x20;
    if (table_end > cnt.len) return error.InvalidCnt;
    return info;
}

pub fn readEntry(cnt: []const u8, info: CntInfo, index: u32) Error!CntEntry {
    if (index >= info.entry_count) return error.InvalidCnt;
    const offset: usize = info.table_offset + index * 0x20;
    const rec = cnt[offset..][0..0x20];
    return .{
        .id = std.mem.readInt(u32, rec[0..4], .big),
        .name_offset = std.mem.readInt(u32, rec[4..8], .big),
        .flags1 = std.mem.readInt(u32, rec[8..12], .big),
        .flags2 = std.mem.readInt(u32, rec[12..16], .big),
        .offset = std.mem.readInt(u32, rec[16..20], .big),
        .size = std.mem.readInt(u32, rec[20..24], .big),
    };
}

pub fn entryName(names: []const u8, entry: CntEntry) []const u8 {
    if (entry.name_offset == 0 or entry.name_offset >= names.len) {
        return wellKnownName(entry.id);
    }
    const start = entry.name_offset;
    const slice = std.mem.sliceTo(names[start..], 0);
    return if (slice.len == 0) wellKnownName(entry.id) else slice;
}

pub fn wellKnownName(id: u32) []const u8 {
    return switch (id) {
        0x0001 => "digests.bin",
        0x0010 => "entry_keys.bin",
        0x0020 => "image_key.bin",
        0x0080 => "general_digests.bin",
        0x0100 => "metas.bin",
        0x0200 => "entry_names.bin",
        0x0400 => "license.dat",
        0x0401 => "license.info",
        0x0402 => "nptitle.dat",
        0x040a => "imagedigs.dat",
        0x1001 => "playgo-chunk.dat",
        0x1200 => "icon0.png",
        0x1220 => "pic0.png",
        0x1240 => "snd0.at9",
        0x1280 => "icon0.dds",
        0x12a0 => "pic0.dds",
        0x2000 => "param.json",
        0x2010 => "playgo-hash-table.dat",
        0x2011 => "playgo-ficm.dat",
        else => "unnamed.bin",
    };
}

pub const ExtractedFile = struct {
    relative: []const u8,
    bytes: []const u8,
};

pub fn namesTable(cnt: []const u8, info: CntInfo) []const u8 {
    var i: u32 = 0;
    while (i < info.entry_count) : (i += 1) {
        const entry = readEntry(cnt, info, i) catch continue;
        if (entry.id == 0x0200 and @as(u64, entry.offset) + entry.size <= cnt.len) {
            return cnt[entry.offset..][0..entry.size];
        }
    }
    return &.{};
}

pub fn sceSysRelative(name: []const u8) []const u8 {
    var start: usize = 0;
    while (start < name.len and (name[start] == '/' or name[start] == '\\')) : (start += 1) {}
    const trimmed = name[start..];
    if (std.mem.startsWith(u8, trimmed, "sce_sys/")) return trimmed;
    return trimmed;
}

/// Yields unencrypted CNT payloads with `sce_sys/`-relative names.
pub fn visitExtractable(
    cnt: []const u8,
    context: anytype,
    comptime visitor: fn (@TypeOf(context), relative: []const u8, bytes: []const u8) anyerror!void,
) !struct { written: u32, skipped_encrypted: u32, content_id: [36]u8 } {
    const info = try parseCnt(cnt);
    const names = namesTable(cnt, info);
    var written: u32 = 0;
    var skipped: u32 = 0;
    var i: u32 = 0;
    while (i < info.entry_count) : (i += 1) {
        const entry = try readEntry(cnt, info, i);
        if (entry.size == 0) continue;
        if (entry.encrypted()) {
            skipped += 1;
            continue;
        }
        const end = @as(u64, entry.offset) + entry.size;
        if (end > cnt.len) return error.TruncatedPackage;
        const raw_name = sceSysRelative(entryName(names, entry));
        if (raw_name.len == 0) continue;
        if (std.mem.eql(u8, raw_name, "unnamed.bin") and entry.id != 0x040a) continue;
        try visitor(context, raw_name, cnt[entry.offset..][0..entry.size]);
        written += 1;
    }
    return .{ .written = written, .skipped_encrypted = skipped, .content_id = info.content_id };
}

test "detectKind recognises FIH debug, FIH retail, and CNT" {
    try std.testing.expectEqual(Kind.fih_debug, detectKind(&.{ 0x7f, 'F', 'I', 'H', 1, 0, 3, 0 }).?);
    try std.testing.expectEqual(Kind.fih_retail, detectKind(&.{ 0x7f, 'F', 'I', 'H', 1, 0x80, 3, 0 }).?);
    try std.testing.expectEqual(Kind.cnt, detectKind(&cnt_magic).?);
    try std.testing.expectEqual(@as(?Kind, null), detectKind("XXXX"));
}

test "parseFih reads little-endian segment offsets" {
    var header: [0xa8]u8 = @splat(0);
    header[0..4].* = fih_magic;
    header[5] = 0;
    std.mem.writeInt(u16, header[6..8], 3, .little);
    std.mem.writeInt(u64, header[0x10..0x18], 0x10000, .little);
    std.mem.writeInt(u64, header[0x18..0x20], 0x20000, .little);
    std.mem.writeInt(u64, header[0x20..0x28], 0x1f000, .little);
    std.mem.writeInt(u64, header[0x58..0x60], 0x30000, .little);
    const fih = try parseFih(&header, 0x40000);
    try std.testing.expectEqual(@as(u64, 0x10000), fih.pfs_offset);
    try std.testing.expectEqual(@as(u64, 0x20000), fih.pfs_size);
    try std.testing.expectEqual(@as(u64, 0x30000), fih.cnt_offset);
    try std.testing.expectEqual(@as(u64, 0x1f000), fih.superblock_offset);
    try std.testing.expectEqual(Kind.fih_debug, fih.kind());
}

fn testCollect(list: *std.ArrayList(ExtractedFile), relative: []const u8, bytes: []const u8) anyerror!void {
    try list.append(std.testing.allocator, .{ .relative = relative, .bytes = bytes });
}

test "visitExtractable yields unencrypted param.json" {
    var cnt: [0x80 + 0x20 + 32]u8 = @splat(0);
    cnt[0..4].* = cnt_magic;
    std.mem.writeInt(u32, cnt[12..16], 1, .big);
    std.mem.writeInt(u32, cnt[16..20], 1, .big);
    std.mem.writeInt(u32, cnt[24..28], 0x80, .big);
    @memcpy(cnt[0x40..0x49], "PPSA19943");
    std.mem.writeInt(u32, cnt[0x80..][0..4], 0x2000, .big);
    std.mem.writeInt(u32, cnt[0x90..][0..4], 0xa0, .big);
    std.mem.writeInt(u32, cnt[0x94..][0..4], 15, .big);
    @memcpy(cnt[0xa0..0xaf], "{\"titleId\":\"X\"}");

    var list: std.ArrayList(ExtractedFile) = .empty;
    defer list.deinit(std.testing.allocator);
    const result = try visitExtractable(&cnt, &list, testCollect);
    try std.testing.expectEqual(@as(u32, 1), result.written);
    try std.testing.expectEqualStrings("param.json", list.items[0].relative);
    try std.testing.expectEqualStrings("{\"titleId\":\"X\"}", list.items[0].bytes);
}

test "encrypted CNT entries are skipped" {
    var cnt: [0xa0]u8 = @splat(0);
    cnt[0..4].* = cnt_magic;
    std.mem.writeInt(u32, cnt[16..20], 1, .big);
    std.mem.writeInt(u32, cnt[24..28], 0x80, .big);
    std.mem.writeInt(u32, cnt[0x80..][0..4], 0x0400, .big);
    std.mem.writeInt(u32, cnt[0x88..][0..4], 0x8000_0000, .big);
    std.mem.writeInt(u32, cnt[0x90..][0..4], 0x90, .big);
    std.mem.writeInt(u32, cnt[0x94..][0..4], 4, .big);
    var list: std.ArrayList(ExtractedFile) = .empty;
    defer list.deinit(std.testing.allocator);
    const result = try visitExtractable(&cnt, &list, testCollect);
    try std.testing.expectEqual(@as(u32, 0), result.written);
    try std.testing.expectEqual(@as(u32, 1), result.skipped_encrypted);
}
