// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Outer-PFS reader for debug FIH packages.
//!
//! A finalized debug image stores the application tree in a nested
//! `pfs_image.dat` inside the outer PFS. Debug packages built with the
//! public passcode keep that outer image readable: either the superblock
//! sits at the start of the PFS (classic) or near the end (data-first),
//! and `PPRPLAIN-NOAUTH!` packages leave the file data in the clear.
//!
//! This reader locates `pfs_image.dat` and copies uncompressed SELF
//! modules out of it. `ET_SCE_DYNEXEC` becomes `eboot.bin`; other SELF
//! files land under `sce_module/`. Kraken-compressed asset payloads are
//! not unpacked.

const std = @import("std");

pub const pfs_magic: i64 = 20130315;
pub const self_magic: u32 = 0xEEF51454;
pub const elf_magic = [4]u8{ 0x7f, 'E', 'L', 'F' };
pub const et_sce_dynexec: u16 = 0xFE10;
pub const et_sce_dynamic: u16 = 0xFE18;
pub const self_elf_offset: u64 = 0x1A0;
pub const default_block_size: u32 = 0x10000;
pub const dinode_s32_size: usize = 0x2C8;
pub const dinode_s64_size: usize = 0x310;
pub const plain_noauth_seed = "PPRPLAIN-NOAUTH!";

const copy_chunk: usize = 1024 * 1024;

pub const Error = error{
    TruncatedPfs,
    InvalidPfs,
    NoPfsImage,
    Io,
    OutOfMemory,
};

pub const Superblock = struct {
    version: u64,
    magic: i64,
    mode: u16,
    block_size: u32,
    dinode_count: u64,
    ndblock: u64,
    dinode_block_count: u64,
    inode_table_block: u64,
    seed: [16]u8,
    image_block: u64,

    pub fn signed(self: Superblock) bool {
        return self.mode & 1 != 0;
    }

    pub fn inode64(self: Superblock) bool {
        return self.mode & 2 != 0;
    }

    pub fn encrypted(self: Superblock) bool {
        return self.mode & 4 != 0;
    }

    pub fn plaintextNoauth(self: Superblock) bool {
        return std.mem.eql(u8, &self.seed, plain_noauth_seed);
    }
};

pub const Inode = struct {
    mode: u16,
    nlink: u16,
    flags: u32,
    size: u64,
    size_compressed: u64,
    blocks: u32,
    db: [12]i64,
    ib: [5]i64,

    pub fn directory(self: Inode) bool {
        return self.mode & 0x4000 != 0;
    }

    pub fn startBlock(self: Inode) i64 {
        return self.db[0];
    }
};

pub const Dirent = struct {
    ino: u32,
    kind: u32,
    name: []const u8,
};

pub const ExtractStats = struct {
    eboot: bool = false,
    modules: u32 = 0,
};

pub fn parseSuperblock(buf: []const u8, image_block: u64) Error!Superblock {
    if (buf.len < 0x380) return error.TruncatedPfs;
    const version = std.mem.readInt(u64, buf[0..8], .little);
    const magic = std.mem.readInt(i64, buf[8..16], .little);
    if (magic != pfs_magic or (version != 1 and version != 2)) return error.InvalidPfs;
    const block_size = std.mem.readInt(u32, buf[0x20..0x24], .little);
    if (block_size == 0 or block_size & 0xFFF != 0) return error.InvalidPfs;
    var seed: [16]u8 = undefined;
    @memcpy(&seed, buf[0x370..0x380]);
    return .{
        .version = version,
        .magic = magic,
        .mode = std.mem.readInt(u16, buf[0x1C..0x1E], .little),
        .block_size = block_size,
        .dinode_count = std.mem.readInt(u64, buf[0x30..0x38], .little),
        .ndblock = std.mem.readInt(u64, buf[0x38..0x40], .little),
        .dinode_block_count = std.mem.readInt(u64, buf[0x40..0x48], .little),
        .inode_table_block = @bitCast(std.mem.readInt(i64, buf[0xD8..0xE0], .little)),
        .seed = seed,
        .image_block = image_block,
    };
}

pub fn parseDinodeS32(buf: []const u8) Error!Inode {
    if (buf.len < dinode_s32_size) return error.TruncatedPfs;
    var inode = Inode{
        .mode = std.mem.readInt(u16, buf[0..2], .little),
        .nlink = std.mem.readInt(u16, buf[2..4], .little),
        .flags = std.mem.readInt(u32, buf[4..8], .little),
        .size = @bitCast(std.mem.readInt(i64, buf[8..16], .little)),
        .size_compressed = @bitCast(std.mem.readInt(i64, buf[16..24], .little)),
        .blocks = std.mem.readInt(u32, buf[0x60..0x64], .little),
        .db = @splat(0),
        .ib = @splat(0),
    };
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const off = 0x64 + i * 36 + 32;
        inode.db[i] = std.mem.readInt(i32, buf[off..][0..4], .little);
    }
    i = 0;
    while (i < 5) : (i += 1) {
        const off = 0x64 + 12 * 36 + i * 36 + 32;
        inode.ib[i] = std.mem.readInt(i32, buf[off..][0..4], .little);
    }
    return inode;
}

pub fn nextDirent(buf: []const u8, offset: *usize) ?Dirent {
    if (offset.* + 16 > buf.len) return null;
    const rec = buf[offset.*..];
    const ino = std.mem.readInt(u32, rec[0..4], .little);
    const kind = std.mem.readInt(u32, rec[4..8], .little);
    const name_len = std.mem.readInt(u32, rec[8..12], .little);
    const rec_size = std.mem.readInt(u32, rec[12..16], .little);
    if (rec_size < 16 or rec_size > 0x1000 or name_len > rec_size) return null;
    if (offset.* + rec_size > buf.len) return null;
    if (ino == 0 and kind == 0 and name_len == 0) return null;
    const name_end = 16 + name_len;
    const raw_name = if (name_end <= rec_size) rec[16..name_end] else rec[16..rec_size];
    const name = std.mem.sliceTo(raw_name, 0);
    offset.* += rec_size;
    if (name.len == 0) return null;
    return .{ .ino = ino, .kind = kind, .name = name };
}

pub fn parseSelfHeader(buf: []const u8) ?struct { file_size: u64, elf_type: u16 } {
    if (buf.len < self_elf_offset + 18) return null;
    if (std.mem.readInt(u32, buf[0..4], .little) != self_magic) return null;
    const file_size = std.mem.readInt(u64, buf[0x10..0x18], .little);
    if (!std.mem.eql(u8, buf[self_elf_offset..][0..4], &elf_magic)) return null;
    const elf_type = std.mem.readInt(u16, buf[self_elf_offset + 16 ..][0..2], .little);
    if (file_size < self_elf_offset + 64) return null;
    return .{ .file_size = file_size, .elf_type = elf_type };
}

fn readExact(file: std.Io.File, io: std.Io, dest: []u8, offset: u64) Error!void {
    const got = file.readPositionalAll(io, dest, offset) catch return error.Io;
    if (got != dest.len) return error.TruncatedPfs;
}

fn copyRange(
    src: std.Io.File,
    io: std.Io,
    src_offset: u64,
    size: u64,
    dest: std.Io.Dir,
    relative: []const u8,
) Error!void {
    if (std.fs.path.dirname(relative)) |parent| {
        dest.createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.Io,
        };
    }
    var out = dest.createFile(io, relative, .{ .truncate = true }) catch return error.Io;
    defer out.close(io);

    var buf: [copy_chunk]u8 = undefined;
    var copied: u64 = 0;
    while (copied < size) {
        const want: usize = @intCast(@min(buf.len, size - copied));
        const got = src.readPositionalAll(io, buf[0..want], src_offset + copied) catch return error.Io;
        if (got == 0) break;
        out.writeStreamingAll(io, buf[0..got]) catch return error.Io;
        copied += got;
    }
    if (copied != size) return error.TruncatedPfs;
}

fn loadSuperblock(file: std.Io.File, io: std.Io, pfs_offset: u64, pfs_size: u64, sb_abs: u64) Error!Superblock {
    var buf: [0x400]u8 = undefined;
    if (sb_abs >= pfs_offset and sb_abs + 0x400 <= pfs_offset + pfs_size) {
        try readExact(file, io, &buf, sb_abs);
        const block = (sb_abs - pfs_offset) / default_block_size;
        if (parseSuperblock(&buf, block)) |sb| return sb else |_| {}
    }
    try readExact(file, io, &buf, pfs_offset);
    return parseSuperblock(&buf, 0);
}

fn loadInodes(
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    pfs_offset: u64,
    sb: Superblock,
) Error![]Inode {
    if (sb.dinode_count == 0 or sb.dinode_count > 4096) return error.InvalidPfs;
    const inode_size: usize = if (sb.inode64()) dinode_s64_size else dinode_s32_size;
    const block_size: usize = sb.block_size;
    var table: std.ArrayList(Inode) = .empty;
    errdefer table.deinit(allocator);

    const block_buf = allocator.alloc(u8, block_size) catch return error.Io;
    defer allocator.free(block_buf);

    var remaining = sb.dinode_count;
    var blk = sb.inode_table_block;
    const blk_count = @max(sb.dinode_block_count, 1);
    var b: u64 = 0;
    while (b < blk_count and remaining > 0) : (b += 1) {
        try readExact(file, io, block_buf, pfs_offset + blk * sb.block_size);
        const per_block = block_size / inode_size;
        var i: usize = 0;
        while (i < per_block and remaining > 0) : (i += 1) {
            const rec = block_buf[i * inode_size ..][0..inode_size];
            const inode = if (sb.inode64())
                parseDinodeS64(rec) catch continue
            else
                parseDinodeS32(rec) catch continue;
            table.append(allocator, inode) catch return error.Io;
            remaining -= 1;
        }
        blk += 1;
    }
    return table.toOwnedSlice(allocator);
}

fn parseDinodeS64(buf: []const u8) Error!Inode {
    if (buf.len < dinode_s64_size) return error.TruncatedPfs;
    var inode = Inode{
        .mode = std.mem.readInt(u16, buf[0..2], .little),
        .nlink = std.mem.readInt(u16, buf[2..4], .little),
        .flags = std.mem.readInt(u32, buf[4..8], .little),
        .size = @bitCast(std.mem.readInt(i64, buf[8..16], .little)),
        .size_compressed = @bitCast(std.mem.readInt(i64, buf[16..24], .little)),
        .blocks = @truncate(@as(u64, @bitCast(std.mem.readInt(i64, buf[0x64..0x6C], .little)))),
        .db = @splat(0),
        .ib = @splat(0),
    };
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const off = 0x68 + i * 40 + 32;
        inode.db[i] = std.mem.readInt(i64, buf[off..][0..8], .little);
    }
    i = 0;
    while (i < 5) : (i += 1) {
        const off = 0x68 + 12 * 40 + i * 40 + 32;
        inode.ib[i] = std.mem.readInt(i64, buf[off..][0..8], .little);
    }
    return inode;
}

fn findPfsImage(inodes: []const Inode, file: std.Io.File, io: std.Io, pfs_offset: u64, sb: Superblock) Error!Inode {
    var dir_buf: [0x10000]u8 = undefined;
    // Superroot (inode 0) lists uroot; uroot lists pfs_image.dat.
    for (inodes) |inode| {
        if (!inode.directory()) continue;
        const start = inode.startBlock();
        if (start < 0) continue;
        const abs = pfs_offset + @as(u64, @intCast(start)) * sb.block_size;
        const n = @min(dir_buf.len, @as(usize, @intCast(@min(inode.size, sb.block_size))));
        readExact(file, io, dir_buf[0..n], abs) catch continue;
        var offset: usize = 0;
        while (nextDirent(dir_buf[0..n], &offset)) |ent| {
            if (std.mem.eql(u8, ent.name, "pfs_image.dat") and ent.ino < inodes.len) {
                return inodes[ent.ino];
            }
        }
    }
    // Data-first fallback: the largest file inode is the nested image.
    var best: ?Inode = null;
    for (inodes) |inode| {
        if (inode.directory() or inode.size == 0) continue;
        if (best == null or inode.size > best.?.size) best = inode;
    }
    return best orelse error.NoPfsImage;
}

fn extractSelfs(
    src: std.Io.File,
    io: std.Io,
    image_offset: u64,
    image_size: u64,
    dest: std.Io.Dir,
) Error!ExtractStats {
    var stats = ExtractStats{};
    var window: [copy_chunk]u8 = undefined;
    var pos: u64 = 0;
    var module_index: u32 = 0;
    while (pos < image_size) {
        const want: usize = @intCast(@min(window.len, image_size - pos));
        const got = src.readPositionalAll(io, window[0..want], image_offset + pos) catch return error.Io;
        if (got == 0) break;

        var off: usize = 0;
        var jumped = false;
        while (off + self_elf_offset + 18 <= got) {
            if (off % default_block_size != 0) {
                off += default_block_size - (off % default_block_size);
                continue;
            }
            if (parseSelfHeader(window[off..])) |self_hdr| {
                const abs = image_offset + pos + off;
                const max_size = image_size - (pos + off);
                const size = @min(self_hdr.file_size, max_size);
                if (size >= self_elf_offset + 64 and size <= 512 * 1024 * 1024) {
                    if (self_hdr.elf_type == et_sce_dynexec and !stats.eboot) {
                        try copyRange(src, io, abs, size, dest, "eboot.bin");
                        std.debug.print("  eboot.bin  {d} bytes\n", .{size});
                        stats.eboot = true;
                    } else {
                        var name_buf: [40]u8 = undefined;
                        const name = std.fmt.bufPrint(&name_buf, "sce_module/prx_{d:0>2}.prx", .{module_index}) catch return error.Io;
                        try copyRange(src, io, abs, size, dest, name);
                        std.debug.print("  {s}  {d} bytes\n", .{ name, size });
                        module_index += 1;
                        stats.modules += 1;
                    }
                }
                const aligned = std.mem.alignForward(u64, size, default_block_size);
                pos += off + @max(@as(u64, default_block_size), aligned);
                jumped = true;
                break;
            }
            off += default_block_size;
        }
        if (jumped) continue;
        pos += got;
    }
    return stats;
}

/// Walk the outer PFS of a debug package and copy uncompressed SELF modules
/// from the nested `pfs_image.dat` into `dest`.
pub fn extractAppFiles(
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    pfs_offset: u64,
    pfs_size: u64,
    superblock_abs: u64,
    dest: std.Io.Dir,
) Error!ExtractStats {
    if (pfs_size < default_block_size) return error.TruncatedPfs;
    const sb = try loadSuperblock(file, io, pfs_offset, pfs_size, superblock_abs);
    if (sb.encrypted() and !sb.plaintextNoauth()) return error.InvalidPfs;

    const inodes = try loadInodes(file, io, allocator, pfs_offset, sb);
    defer allocator.free(inodes);

    const image = try findPfsImage(inodes, file, io, pfs_offset, sb);
    const start = image.startBlock();
    if (start < 0) return error.NoPfsImage;
    const image_offset = pfs_offset + @as(u64, @intCast(start)) * sb.block_size;
    const image_size = image.size;
    if (image_size == 0) return error.NoPfsImage;

    std.debug.print(
        "outer PFS  block={d}  inodes={d}  pfs_image.dat {d} bytes at 0x{x}\n",
        .{ sb.image_block, inodes.len, image_size, image_offset },
    );
    return extractSelfs(file, io, image_offset, image_size, dest);
}

test "parseSuperblock reads a PS5 data-first header" {
    var buf: [0x400]u8 = @splat(0);
    std.mem.writeInt(u64, buf[0..8], 2, .little);
    std.mem.writeInt(i64, buf[8..16], pfs_magic, .little);
    std.mem.writeInt(u16, buf[0x1C..0x1E], 0x0d, .little);
    std.mem.writeInt(u32, buf[0x20..0x24], default_block_size, .little);
    std.mem.writeInt(u64, buf[0x30..0x38], 5, .little);
    std.mem.writeInt(i64, buf[0xD8..0xE0], 68523, .little);
    @memcpy(buf[0x370..0x380], plain_noauth_seed);
    const sb = try parseSuperblock(&buf, 68522);
    try std.testing.expectEqual(@as(u64, 2), sb.version);
    try std.testing.expectEqual(true, sb.encrypted());
    try std.testing.expectEqual(false, sb.inode64());
    try std.testing.expectEqual(true, sb.plaintextNoauth());
    try std.testing.expectEqual(@as(u64, 68523), sb.inode_table_block);
}

test "parseDinodeS32 reads size and direct blocks" {
    var buf: [dinode_s32_size]u8 = @splat(0);
    std.mem.writeInt(u16, buf[0..2], 0x816d, .little);
    std.mem.writeInt(u16, buf[2..4], 1, .little);
    std.mem.writeInt(u32, buf[4..8], 0xd, .little);
    std.mem.writeInt(i64, buf[8..16], 0x10b9a0000, .little);
    std.mem.writeInt(u32, buf[0x60..0x64], 68506, .little);
    std.mem.writeInt(i32, buf[0x64 + 32 ..][0..4], 0, .little);
    const inode = try parseDinodeS32(&buf);
    try std.testing.expectEqual(false, inode.directory());
    try std.testing.expectEqual(@as(u64, 0x10b9a0000), inode.size);
    try std.testing.expectEqual(@as(i64, 0), inode.startBlock());
    try std.testing.expectEqual(@as(u32, 68506), inode.blocks);
}

test "nextDirent walks a uroot block" {
    var buf: [80]u8 = @splat(0);
    // "." ino 2 type 4 rec 24
    std.mem.writeInt(u32, buf[0..4], 2, .little);
    std.mem.writeInt(u32, buf[4..8], 4, .little);
    std.mem.writeInt(u32, buf[8..12], 1, .little);
    std.mem.writeInt(u32, buf[12..16], 24, .little);
    buf[16] = '.';
    // "pfs_image.dat" ino 3 type 2 rec 32 at offset 24
    std.mem.writeInt(u32, buf[24..28], 3, .little);
    std.mem.writeInt(u32, buf[28..32], 2, .little);
    std.mem.writeInt(u32, buf[32..36], 13, .little);
    std.mem.writeInt(u32, buf[36..40], 32, .little);
    @memcpy(buf[40..53], "pfs_image.dat");
    var offset: usize = 0;
    const dot = nextDirent(&buf, &offset).?;
    try std.testing.expectEqualStrings(".", dot.name);
    const file = nextDirent(&buf, &offset).?;
    try std.testing.expectEqualStrings("pfs_image.dat", file.name);
    try std.testing.expectEqual(@as(u32, 3), file.ino);
}

test "parseSelfHeader recognises SCE_DYNEXEC" {
    var buf: [self_elf_offset + 24]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], self_magic, .little);
    std.mem.writeInt(u64, buf[0x10..0x18], 0x7e2cdb0, .little);
    @memcpy(buf[self_elf_offset..][0..4], &elf_magic);
    std.mem.writeInt(u16, buf[self_elf_offset + 16 ..][0..2], et_sce_dynexec, .little);
    const hdr = parseSelfHeader(&buf).?;
    try std.testing.expectEqual(@as(u64, 0x7e2cdb0), hdr.file_size);
    try std.testing.expectEqual(et_sce_dynexec, hdr.elf_type);
}
