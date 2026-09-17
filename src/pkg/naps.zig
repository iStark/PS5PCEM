// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Decoder for `naps_pkg_layout.dat` (PackageLayout_NAPS).
//!
//! Layout matches the public PS5 debug-package description: a 16-byte
//! packed header, then outer-block digests, shuffle patterns, per-file
//! uncompressed offsets, u2c entries, and 9-byte CblockInfo records.

const std = @import("std");

pub const header_size: usize = 16;
pub const outer_stride: usize = 8;
pub const shuffle_stride: usize = 8;
pub const file_offset_stride: usize = 6;
pub const u2c_stride: usize = 10;
pub const cblock_stride: usize = 9;
pub const ublock_size: u64 = 0x40000;
pub const chunk_128k: u32 = 0x20000;

pub const Error = error{
    TruncatedNaps,
    InvalidNaps,
};

pub const Counts = struct {
    num_files: u32,
    compression_type: u8,
    num_keys: u32,
    num_shuffle: u32,
    num_ublocks: u32,
    num_outer_blocks: u32,
    num_cblock_info: u32,

    pub fn numU2c(self: Counts) u32 {
        return (self.num_ublocks + 8) >> 3;
    }

    pub fn numFileOffsets(self: Counts) u32 {
        return self.num_files + 1;
    }
};

pub const FileOffset = struct {
    kind: u8,
    uncompressed_offset: u64,
};

pub const CblockInfo = struct {
    is_run_base: bool,
    coffset_mod: u32,
    uoffset_start: u32,
    clen_even_minus1: u32,
    even: u1,
    odd: u1,
    kde_predictor: u8,
    shuffle_idx: u8,
    tweak_idx_start: u32,
    key_table_idx: u8,
    coffset_start_256k: u32,

    pub fn evenComp(self: CblockInfo) u32 {
        return self.clen_even_minus1 / 2 + 1;
    }

    pub fn kraken(self: CblockInfo) bool {
        return self.kde_predictor == 2;
    }
};

pub const Layout = struct {
    counts: Counts,
    file_offsets: []FileOffset,
    cblocks: []CblockInfo,

    pub fn deinit(self: Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.file_offsets);
        allocator.free(self.cblocks);
    }

    pub fn mountSize(self: Layout) u64 {
        var best: u64 = 0;
        for (self.file_offsets) |entry| {
            if (entry.uncompressed_offset > 0 and entry.uncompressed_offset & 0xFFFF == 0) {
                best = @max(best, entry.uncompressed_offset);
            }
        }
        return best;
    }

    pub fn nextBoundary(self: Layout, cur: u64, mount: u64) u64 {
        var best: u64 = mount;
        for (self.file_offsets) |entry| {
            if (entry.uncompressed_offset > cur and entry.uncompressed_offset <= mount and entry.uncompressed_offset < best) {
                best = entry.uncompressed_offset;
            }
        }
        return best;
    }
};

pub fn decodeHeader(header: []const u8) Error!Counts {
    if (header.len < header_size) return error.TruncatedNaps;
    const word0 = std.mem.readInt(u64, header[0..8], .little);
    const word1 = std.mem.readInt(u64, header[8..16], .little);
    const num_cblock = @as(u32, @truncate(word1 >> 24)) & 0xFFFFFF;
    return .{
        .num_files = (@as(u32, @truncate(word0)) & 0xFFFFFF) + 1,
        .compression_type = @truncate((word0 >> 24) & 3),
        .num_keys = (@as(u32, @truncate(word0 >> 26)) & 3) + 1,
        .num_shuffle = @truncate((word0 >> 28) & 0xF),
        .num_ublocks = @truncate((word0 >> 32) & 0xFFFFFF),
        .num_outer_blocks = @as(u32, @truncate(word1)) & 0xFFFFFF,
        .num_cblock_info = num_cblock + 2,
    };
}

pub fn decodeCblock(raw: []const u8) Error!CblockInfo {
    if (raw.len < cblock_stride) return error.TruncatedNaps;
    var lo: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) lo |= @as(u64, raw[i]) << @intCast(8 * i);
    const hi: u64 = raw[8];
    const is_run = (lo >> 18) & 1 != 0;
    const coff: u32 = @truncate(lo & 0x3FFFF);
    if (!is_run) {
        return .{
            .is_run_base = false,
            .coffset_mod = coff,
            .uoffset_start = @truncate((lo >> 19) & 0x3FFFF),
            .clen_even_minus1 = @truncate((lo >> 37) & 0x1FFFF),
            .even = @truncate((lo >> 54) & 1),
            .odd = @truncate((lo >> 55) & 1),
            .kde_predictor = @truncate((lo >> 56) & 7),
            .shuffle_idx = @truncate((lo >> 59) & 0xF),
            .tweak_idx_start = 0,
            .key_table_idx = 0,
            .coffset_start_256k = 0,
        };
    }
    return .{
        .is_run_base = true,
        .coffset_mod = coff,
        .uoffset_start = 0,
        .clen_even_minus1 = 0,
        .even = 0,
        .odd = 0,
        .kde_predictor = 0,
        .shuffle_idx = 0,
        .tweak_idx_start = @truncate((lo >> 19) & 0xFFFFFFF),
        .key_table_idx = @truncate((lo >> 47) & 3),
        .coffset_start_256k = @truncate(((lo >> 49) & 0x7FFF) | ((hi & 0x1FF) << 15)),
    };
}

pub fn parse(allocator: std.mem.Allocator, blob: []const u8) Error!Layout {
    const counts = try decodeHeader(blob);
    const fidx_n = deriveFidxCount(counts, blob.len);
    const map_end = sectionEnd(counts, fidx_n);
    if (blob.len < map_end) return error.TruncatedNaps;

    var pos: usize = header_size;
    pos += @as(usize, counts.num_outer_blocks) * outer_stride;
    pos += @as(usize, counts.num_shuffle) * shuffle_stride;

    const file_offsets = allocator.alloc(FileOffset, fidx_n) catch return error.TruncatedNaps;
    errdefer allocator.free(file_offsets);
    var i: usize = 0;
    while (i < fidx_n) : (i += 1) {
        const rec = blob[pos + i * file_offset_stride ..][0..file_offset_stride];
        var off: u64 = 0;
        var b: usize = 0;
        while (b < 5) : (b += 1) off |= @as(u64, rec[b]) << @intCast(8 * b);
        file_offsets[i] = .{ .kind = rec[5], .uncompressed_offset = off };
    }
    pos += fidx_n * file_offset_stride;
    pos += @as(usize, counts.numU2c()) * u2c_stride;

    const cblocks = allocator.alloc(CblockInfo, counts.num_cblock_info) catch return error.TruncatedNaps;
    errdefer allocator.free(cblocks);
    i = 0;
    while (i < counts.num_cblock_info) : (i += 1) {
        const rec_off = pos + i * cblock_stride;
        if (rec_off + cblock_stride > blob.len) return error.TruncatedNaps;
        cblocks[i] = try decodeCblock(blob[rec_off..][0..cblock_stride]);
    }

    return .{ .counts = counts, .file_offsets = file_offsets, .cblocks = cblocks };
}

fn deriveFidxCount(counts: Counts, blob_len: usize) usize {
    const fixed_before = header_size
        + @as(usize, counts.num_outer_blocks) * outer_stride
        + @as(usize, counts.num_shuffle) * shuffle_stride
        + @as(usize, counts.numU2c()) * u2c_stride;
    const cblock_bytes = @as(usize, counts.num_cblock_info) * cblock_stride;
    if (blob_len >= cblock_bytes) {
        const cblock_start = blob_len - cblock_bytes;
        if (cblock_start >= fixed_before) {
            const fidx_bytes = cblock_start - fixed_before;
            if (fidx_bytes % file_offset_stride == 0) {
                const derived = fidx_bytes / file_offset_stride;
                if (derived >= 1) return derived;
            }
        }
    }
    return counts.numFileOffsets();
}

fn sectionEnd(counts: Counts, fidx_n: usize) usize {
    return header_size
        + @as(usize, counts.num_outer_blocks) * outer_stride
        + @as(usize, counts.num_shuffle) * shuffle_stride
        + fidx_n * file_offset_stride
        + @as(usize, counts.numU2c()) * u2c_stride
        + @as(usize, counts.num_cblock_info) * cblock_stride;
}

test "decodeHeader reads packed naps fields" {
    var header: [16]u8 = @splat(0);
    // numFiles-1=63, comp=2, keys-1=0, shuffle=0, ublocks=40808
    const word0: u64 = 63 | (@as(u64, 2) << 24) | (@as(u64, 40808) << 32);
    // outer=68506, cblock-2=43579
    const word1: u64 = 68506 | (@as(u64, 43579) << 24);
    std.mem.writeInt(u64, header[0..8], word0, .little);
    std.mem.writeInt(u64, header[8..16], word1, .little);
    const counts = try decodeHeader(&header);
    try std.testing.expectEqual(@as(u32, 64), counts.num_files);
    try std.testing.expectEqual(@as(u8, 2), counts.compression_type);
    try std.testing.expectEqual(@as(u32, 40808), counts.num_ublocks);
    try std.testing.expectEqual(@as(u32, 68506), counts.num_outer_blocks);
    try std.testing.expectEqual(@as(u32, 43581), counts.num_cblock_info);
}

test "decodeCblock distinguishes std and run-base" {
    var std_rec: [9]u8 = @splat(0);
    // coff=20, not run
    std_rec[0] = 20;
    const std_info = try decodeCblock(&std_rec);
    try std.testing.expectEqual(false, std_info.is_run_base);
    try std.testing.expectEqual(@as(u32, 20), std_info.coffset_mod);

    var run_rec: [9]u8 = @splat(0);
    const lo: u64 = (1 << 18) | (@as(u64, 2) << 19);
    var i: usize = 0;
    while (i < 8) : (i += 1) run_rec[i] = @truncate(lo >> @intCast(8 * i));
    const run_info = try decodeCblock(&run_rec);
    try std.testing.expectEqual(true, run_info.is_run_base);
    try std.testing.expectEqual(@as(u32, 2), run_info.tweak_idx_start);
}
