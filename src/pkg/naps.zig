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
        // The count includes the terminal mount-size entry (type 0x40).
        return self.num_files;
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
    kde_predictor: u8,
    shuffle_idx: u8,
    tweak_idx_start: u32,
    key_table_idx: u8,
    coffset_start_256k: u32,

    pub fn evenComp(self: CblockInfo) u32 {
        return self.clen_even_minus1 + 1;
    }

    pub fn kraken(self: CblockInfo) bool {
        return self.kde_predictor & 2 != 0;
    }

    pub fn krakenFlags(self: CblockInfo) u32 {
        return @as(u32, self.kde_predictor) | (@as(u32, self.shuffle_idx) << 4);
    }

    /// Runs encode twice the physical 256 KiB block index. The following
    /// data record supplies the byte offset within that block.
    pub fn runOnDisk(self: CblockInfo, first: CblockInfo) u64 {
        return @as(u64, self.coffset_start_256k / 2) * ublock_size + first.coffset_mod;
    }
};

pub const Layout = struct {
    counts: Counts,
    file_offsets: []FileOffset,
    cblocks: []CblockInfo,
    /// Every file offset, ascending, for `nextBoundary`.
    boundaries: []u64,

    pub fn deinit(self: Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.file_offsets);
        allocator.free(self.cblocks);
        allocator.free(self.boundaries);
    }

    /// The terminal entry. Earlier file boundaries can carry the same kind.
    pub fn mountSize(self: Layout) u64 {
        var index = self.file_offsets.len;
        while (index > 0) {
            index -= 1;
            const entry = self.file_offsets[index];
            if (entry.kind == 0x40) return entry.uncompressed_offset;
        }
        return 0;
    }

    /// The first file offset after `cur`, or `mount` if none comes sooner.
    ///
    /// Asked once per 256 KiB block. A scan of every offset made that
    /// quadratic: a 35 GB title with tens of thousands of files spent many
    /// minutes here before writing its first byte.
    pub fn nextBoundary(self: Layout, cur: u64, mount: u64) u64 {
        var low: usize = 0;
        var high = self.boundaries.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.boundaries[mid] <= cur) low = mid + 1 else high = mid;
        }
        if (low == self.boundaries.len) return mount;
        return @min(self.boundaries[low], mount);
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
            .uoffset_start = @truncate((lo >> 20) & 0x3FFFF),
            .clen_even_minus1 = @truncate((lo >> 38) & 0x1FFFF),
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
        .kde_predictor = 0,
        .shuffle_idx = 0,
        .tweak_idx_start = @truncate((lo >> 19) & 0xFFFFFFF),
        .key_table_idx = @truncate((lo >> 47) & 3),
        .coffset_start_256k = @truncate(((lo >> 49) & 0x7FFF) | ((hi & 0x1FF) << 15)),
    };
}

pub fn parse(allocator: std.mem.Allocator, blob: []const u8) Error!Layout {
    const counts = try decodeHeader(blob);
    const fidx_n = counts.numFileOffsets();
    const map_end = sectionEnd(counts, fidx_n);
    if (blob.len < map_end) return error.TruncatedNaps;

    // Outer digests and shuffle entries are 8-byte records packed after the
    // header. The file-offset table is padded to 16 bytes; the u2c table
    // ends on an 8-byte boundary, which need not also be 16-byte aligned.
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
    pos = std.mem.alignForward(usize, pos, 16);
    pos += @as(usize, counts.numU2c()) * u2c_stride;
    pos = std.mem.alignForward(usize, pos, 8);

    const cblocks = allocator.alloc(CblockInfo, counts.num_cblock_info) catch return error.TruncatedNaps;
    errdefer allocator.free(cblocks);
    i = 0;
    while (i < counts.num_cblock_info) : (i += 1) {
        const rec_off = pos + i * cblock_stride;
        if (rec_off + cblock_stride > blob.len) return error.TruncatedNaps;
        cblocks[i] = try decodeCblock(blob[rec_off..][0..cblock_stride]);
    }

    const boundaries = allocator.alloc(u64, fidx_n) catch return error.TruncatedNaps;
    errdefer allocator.free(boundaries);
    for (file_offsets, boundaries) |entry, *boundary| boundary.* = entry.uncompressed_offset;
    std.mem.sort(u64, boundaries, {}, std.sort.asc(u64));

    return .{ .counts = counts, .file_offsets = file_offsets, .cblocks = cblocks, .boundaries = boundaries };
}

test "the next boundary is the first offset past the cursor, capped at the mount" {
    var offsets = [_]FileOffset{
        .{ .kind = 0, .uncompressed_offset = 0x80000 },
        .{ .kind = 0, .uncompressed_offset = 0 },
        .{ .kind = 0, .uncompressed_offset = 0x40000 },
        .{ .kind = 0x40, .uncompressed_offset = 0x100000 },
    };
    var boundaries = [_]u64{ 0, 0x40000, 0x80000, 0x100000 };
    const layout = Layout{
        .counts = undefined,
        .file_offsets = &offsets,
        .cblocks = &.{},
        .boundaries = &boundaries,
    };
    try std.testing.expectEqual(@as(u64, 0x40000), layout.nextBoundary(0, 0x100000));
    try std.testing.expectEqual(@as(u64, 0x80000), layout.nextBoundary(0x40000, 0x100000));
    try std.testing.expectEqual(@as(u64, 0x80000), layout.nextBoundary(0x50000, 0x100000));
    try std.testing.expectEqual(@as(u64, 0x100000), layout.nextBoundary(0x80000, 0x100000));
    try std.testing.expectEqual(@as(u64, 0xc0000), layout.nextBoundary(0x80000, 0xc0000));
    try std.testing.expectEqual(@as(u64, 0x100000), layout.nextBoundary(0x100000, 0x100000));
}

fn sectionEnd(counts: Counts, fidx_n: usize) usize {
    var pos = header_size + @as(usize, counts.num_outer_blocks) * outer_stride;
    pos += @as(usize, counts.num_shuffle) * shuffle_stride;
    pos = std.mem.alignForward(usize, pos + fidx_n * file_offset_stride, 16);
    pos = std.mem.alignForward(usize, pos + @as(usize, counts.numU2c()) * u2c_stride, 8);
    return pos + @as(usize, counts.num_cblock_info) * cblock_stride;
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
    std_rec[0] = 1;
    const std_info = try decodeCblock(&std_rec);
    try std.testing.expectEqual(false, std_info.is_run_base);
    try std.testing.expectEqual(@as(u32, 1), std_info.coffset_mod);

    var run_rec: [9]u8 = @splat(0);
    run_rec[2] = 0x14; // run bit 18, tweak 2
    const run_info = try decodeCblock(&run_rec);
    try std.testing.expectEqual(true, run_info.is_run_base);
    try std.testing.expectEqual(@as(u32, 2), run_info.tweak_idx_start);
    var first = std_info;
    first.coffset_mod = 0x10000;
    try std.testing.expectEqual(@as(u64, 0x10000), run_info.runOnDisk(first));
}

test "NAPS padding does not become file offsets or shift CblockInfo" {
    var blob: [96]u8 = @splat(0);
    // Two fidx entries, one outer block, one ublock and two CblockInfo records.
    std.mem.writeInt(u64, blob[0..8], 1 | (@as(u64, 1) << 32), .little);
    std.mem.writeInt(u64, blob[8..16], 1, .little);
    // Outer digests end at 24 and fidx follows without padding.
    blob[32] = 4; // mount size 0x40000 in the second 40-bit offset
    blob[35] = 0x40;
    // fidx ends at 36, u2c occupies 48..58, cblocks start at 64.
    blob[66] = 4; // run marker: bit 18, not bit 2
    var layout = try parse(std.testing.allocator, &blob);
    defer layout.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), layout.file_offsets.len);
    try std.testing.expectEqual(@as(u64, 0x40000), layout.mountSize());
    try std.testing.expect(layout.cblocks[0].is_run_base);
    try std.testing.expect(!layout.cblocks[1].is_run_base);
    try std.testing.expectError(error.TruncatedNaps, parse(std.testing.allocator, blob[0..81]));
}

test "NAPS preserves the high bit of the first Kraken chunk length" {
    const rec = try decodeCblock(&.{ 0x09, 0x72, 0xa1, 0x48, 0x0e, 0xe2, 0xc9, 0x12, 0x00 });
    try std.testing.expect(!rec.is_run_base);
    try std.testing.expectEqual(@as(u32, 75657), rec.evenComp());
    try std.testing.expectEqual(@as(u32, 0x22), rec.krakenFlags());
    const stored = try decodeCblock(&.{ 0x0a, 0x00, 0xa2, 0x24, 0xc3, 0xff, 0xff, 0x04, 0x00 });
    try std.testing.expectEqual(@as(u32, 0x20000), stored.evenComp());
}

test "CblockInfo starts after 8-byte u2c padding even when not 16-byte aligned" {
    var blob: [96]u8 = @splat(0);
    // Two file offsets, one outer digest, nine ublocks: two u2c entries.
    std.mem.writeInt(u64, blob[0..8], 1 | (@as(u64, 9) << 32), .little);
    std.mem.writeInt(u64, blob[8..16], 1, .little);
    blob[32] = 0x24; // terminal mount size 0x240000
    blob[35] = 0x40;
    // fidx ends at 36, u2c occupies 48..68. CblockInfo starts at 72,
    // not 80; optional padding after its two records is not another record.
    blob[74] = 4; // run-base marker
    blob[81] = 10; // first data record's compressed offset
    for ([_]usize{ 90, blob.len }) |len| {
        var layout = try parse(std.testing.allocator, blob[0..len]);
        defer layout.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u64, 0x240000), layout.mountSize());
        try std.testing.expectEqual(@as(usize, 2), layout.cblocks.len);
        try std.testing.expect(layout.cblocks[0].is_run_base);
        try std.testing.expect(!layout.cblocks[1].is_run_base);
        try std.testing.expectEqual(@as(u64, 10), layout.cblocks[0].runOnDisk(layout.cblocks[1]));
    }
    try std.testing.expectError(error.TruncatedNaps, parse(std.testing.allocator, blob[0..89]));
}
