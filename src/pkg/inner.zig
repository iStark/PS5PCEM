// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Reconstruct a data-first inner PFS from pfs_image.dat + naps_pkg_layout.dat
//! and write the uroot file tree, using the NAPS block offsets and codec flags.

const std = @import("std");
const naps = @import("naps.zig");
const kraken = @import("kraken.zig");

const pfs_magic: i64 = 20130315;

pub const Error = error{
    TruncatedPfs,
    InvalidPfs,
    NoPfsImage,
    Io,
    OutOfMemory,
    UnsupportedPfs,
    InvalidCompressedBlock,
};

const UBlock = struct {
    logical: u64,
    on_disk: u64,
    comp: u32,
    uncomp: u32,
    kraken: bool,
    even_comp: u32,
    flags: u32,
};

pub const InnerStats = struct {
    files: u32 = 0,
    eboot: bool = false,
    modules: u32 = 0,
    kraken_blocks: u32 = 0,
    stored_blocks: u32 = 0,
};

pub fn extractInnerTree(
    src: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    image_offset: u64,
    image_size: u64,
    image_limit: u64,
    naps_blob: []const u8,
    dest: std.Io.Dir,
) Error!InnerStats {
    var layout = naps.parse(allocator, naps_blob) catch return error.InvalidPfs;
    defer layout.deinit(allocator);

    const mount = layout.mountSize();
    if (mount == 0) return error.InvalidPfs;

    var blocks: std.ArrayList(UBlock) = .empty;
    defer blocks.deinit(allocator);
    try walkBlocks(allocator, layout, mount, &blocks);
    if (blocks.items.len == 0) return error.InvalidPfs;

    var stats = InnerStats{};
    for (blocks.items) |b| {
        if (b.kraken) stats.kraken_blocks += 1 else stats.stored_blocks += 1;
    }

    if (image_size > image_limit) return error.TruncatedPfs;
    for (blocks.items) |b| {
        if (b.on_disk > image_size or b.comp > image_size - b.on_disk) return error.TruncatedPfs;
    }

    const meta_base_logical = blk: {
        var best: u64 = 0;
        for (layout.file_offsets) |entry| {
            if (entry.uncompressed_offset > 0 and entry.uncompressed_offset < mount and entry.uncompressed_offset > best) {
                best = entry.uncompressed_offset;
            }
        }
        break :blk best;
    };
    const meta = try decodeTail(allocator, src, io, image_offset, image_size, blocks.items, meta_base_logical);
    defer allocator.free(meta.buf);

    const sb_off = findSuperblock(meta.buf, mount) orelse return error.InvalidPfs;
    const files = try readFileTree(
        allocator,
        src,
        io,
        image_offset,
        image_size,
        blocks.items,
        meta.buf,
        meta.logical_base,
        sb_off,
    );
    defer {
        for (files) |file| allocator.free(file.path);
        allocator.free(files);
    }

    std.debug.print(
        "inner mount 0x{x}  blocks={d} (stored {d}, kraken {d})  files={d}  superblock+0x{x}\n",
        .{ mount, blocks.items.len, stats.stored_blocks, stats.kraken_blocks, files.len, sb_off },
    );

    const ubuf: []u8 = allocator.alloc(u8, naps.ublock_size) catch return error.OutOfMemory;
    defer allocator.free(ubuf);

    for (files) |file| {
        if (file.path.len == 0) continue;
        writeFileFromBlocks(src, io, allocator, image_offset, image_size, blocks.items, ubuf, dest, file) catch |err| {
            std.debug.print("  failed extracting {s}: {s}\n", .{ file.path, @errorName(err) });
            return err;
        };
        stats.files += 1;
        if (std.mem.eql(u8, file.path, "eboot.bin")) stats.eboot = true;
        if (std.mem.endsWith(u8, file.path, ".prx") or std.mem.endsWith(u8, file.path, ".sprx")) stats.modules += 1;
        std.debug.print("  {s}  {d} bytes\n", .{ file.path, file.size });
    }
    return stats;
}

const MappedFile = struct {
    path: []const u8,
    logical: u64,
    size: u64,
};

const Tail = struct {
    buf: []u8,
    logical_base: u64,
};

fn walkBlocks(
    allocator: std.mem.Allocator,
    layout: naps.Layout,
    mount: u64,
    out: *std.ArrayList(UBlock),
) Error!void {
    var on_disk: u64 = 0;
    var uncomp: u64 = 0;
    var i: usize = 0;
    const recs = layout.cblocks;
    while (i < recs.len) : (i += 1) {
        const rec = recs[i];
        if (rec.is_run_base) {
            if (i + 1 >= recs.len or recs[i + 1].is_run_base) return error.InvalidPfs;
            on_disk = rec.runOnDisk(recs[i + 1]);
            continue;
        }
        if (i + 1 >= recs.len) break;
        const file_end = layout.nextBoundary(uncomp, mount);
        const remain = if (file_end > uncomp) file_end - uncomp else 0;
        const uncomp_len: u32 = @intCast(@min(naps.ublock_size, remain));
        if (uncomp_len == 0) break;
        const nxt = recs[i + 1];
        var diff: i32 = @as(i32, @intCast(nxt.coffset_mod)) - @as(i32, @intCast(rec.coffset_mod));
        if (diff <= 0) diff += @intCast(naps.ublock_size);
        const comp_len: u32 = @intCast(diff);
        const is_kraken = rec.kraken() or comp_len != uncomp_len;
        out.append(allocator, .{
            .logical = uncomp,
            .on_disk = on_disk,
            .comp = comp_len,
            .uncomp = uncomp_len,
            .kraken = is_kraken,
            .even_comp = rec.evenComp(),
            .flags = rec.krakenFlags(),
        }) catch return error.OutOfMemory;
        // coffset_mod tracks the on-disk cursor for both stored and Kraken blocks.
        on_disk += comp_len;
        uncomp += uncomp_len;
        if (uncomp >= mount) break;
    }
    if (uncomp != mount) return error.TruncatedPfs;
}

fn decodeTail(
    allocator: std.mem.Allocator,
    src: std.Io.File,
    io: std.Io,
    image_offset: u64,
    image_size: u64,
    blocks: []const UBlock,
    meta_base: u64,
) Error!Tail {
    var start_index: usize = 0;
    while (start_index < blocks.len and blocks[start_index].logical + blocks[start_index].uncomp <= meta_base) : (start_index += 1) {}
    if (start_index >= blocks.len) return error.InvalidPfs;
    const logical_base = blocks[start_index].logical;
    var total: usize = 0;
    for (blocks[start_index..]) |b| total += b.uncomp;
    var buf = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    var off: usize = 0;
    for (blocks[start_index..]) |b| {
        try decodeUblock(allocator, src, io, image_offset, image_size, b, buf[off .. off + b.uncomp]);
        off += b.uncomp;
    }
    std.debug.print("  decoded meta {d} bytes from {d} blocks at logical 0x{x}\n", .{
        buf.len, blocks.len - start_index, logical_base,
    });
    return .{ .buf = buf, .logical_base = logical_base };
}

fn decodeUblock(
    allocator: std.mem.Allocator,
    src: std.Io.File,
    io: std.Io,
    image_offset: u64,
    image_size: u64,
    block: UBlock,
    dst: []u8,
) Error!void {
    if (dst.len != block.uncomp) return error.InvalidPfs;
    if (block.on_disk > image_size or block.comp > image_size - block.on_disk) return error.TruncatedPfs;
    var tmp: [naps.ublock_size]u8 = undefined;
    if (block.comp > tmp.len) return error.InvalidPfs;
    const payload = tmp[0..block.comp];
    const got = src.readPositionalAll(io, payload, image_offset + block.on_disk) catch return error.Io;
    if (got != payload.len) return error.TruncatedPfs;
    if (payload.len == dst.len) {
        @memcpy(dst, payload);
        return;
    }
    // The split and literal/LZ modes are part of NAPS. Trying other modes can
    // report success while producing corrupt inodes, directory entries or assets.
    const status = kraken.decodeBlock(allocator, payload, block.flags, block.even_comp, dst);
    if (status != .success) {
        std.debug.print("  decode failed at logical 0x{x}, disk 0x{x}: {s} (flags=0x{x}, split={d})\n", .{
            block.logical, block.on_disk, @tagName(status), block.flags, block.even_comp,
        });
        return error.InvalidCompressedBlock;
    }
}

/// Require a superblock matching the NAPS logical mount size. A corrupt map
/// can otherwise mistake the outer image's superblock for the inner one.
fn findSuperblock(buf: []const u8, mount_size: u64) ?usize {
    var off: usize = 0;
    while (off + 0x40 <= buf.len) : (off += 0x10000) {
        const ver = std.mem.readInt(i64, buf[off..][0..8], .little);
        const magic = std.mem.readInt(i64, buf[off + 8 ..][0..8], .little);
        if (ver != 2 or magic != pfs_magic) continue;
        const blocksz = std.mem.readInt(u32, buf[off + 0x20 ..][0..4], .little);
        const ndinode = std.mem.readInt(i64, buf[off + 0x30 ..][0..8], .little);
        const ndblock = std.mem.readInt(i64, buf[off + 0x38 ..][0..8], .little);
        const covers: u64 = if (ndblock > 0 and blocksz != 0)
            @as(u64, @intCast(ndblock)) *% blocksz
        else
            0;
        std.debug.print("  [sb] +0x{x} blocksz=0x{x} ndinode={d} covers=0x{x}\n", .{ off, blocksz, ndinode, covers });
        if (covers == mount_size and ndinode > 0) return off;
    }
    return null;
}

const InnerInode = struct {
    mode: u16,
    size: u64,
    logical: u64,
    fn dir(self: InnerInode) bool {
        return self.mode & 0xF000 == 0x4000;
    }
};

fn readFileTree(
    allocator: std.mem.Allocator,
    src: std.Io.File,
    io: std.Io,
    image_offset: u64,
    image_size: u64,
    blocks: []const UBlock,
    mount: []const u8,
    logical_base: u64,
    meta_base: usize,
) Error![]MappedFile {
    if (meta_base + 0x40 > mount.len) return error.InvalidPfs;
    const block_size = std.mem.readInt(u32, mount[meta_base + 0x20 ..][0..4], .little);
    const inode_count_i = std.mem.readInt(i64, mount[meta_base + 0x30 ..][0..8], .little);
    if (block_size == 0 or block_size & 0xFFF != 0 or inode_count_i <= 0 or inode_count_i > 1_000_000) return error.InvalidPfs;
    const inode_count: usize = @intCast(inode_count_i);
    // Mode 0x10 uses compact flat inodes: offset 0x60 is a byte address,
    // not the signed PFS block count/hash layout used by the outer image.
    const mode = std.mem.readInt(u16, mount[meta_base + 0x1C ..][0..2], .little);
    if (mode & 0x13 != 0x10) return error.UnsupportedPfs;
    const inode_size: usize = 0xA8;
    const per_block = block_size / inode_size;
    const table_blocks = std.math.divCeil(usize, inode_count, per_block) catch return error.InvalidPfs;
    const local_table = meta_base + block_size;
    if (local_table > mount.len or table_blocks * block_size > mount.len - local_table) return error.TruncatedPfs;
    const inode_buf = mount[local_table..][0 .. table_blocks * block_size];

    var nodes = allocator.alloc(InnerInode, inode_count) catch return error.OutOfMemory;
    defer allocator.free(nodes);
    var i: usize = 0;
    while (i < inode_count) : (i += 1) {
        const e = inode_buf[(i / per_block) * block_size + (i % per_block) * inode_size ..][0..inode_size];
        nodes[i] = .{
            .mode = std.mem.readInt(u16, e[0..2], .little),
            .size = @bitCast(std.mem.readInt(i64, e[8..16], .little)),
            .logical = std.mem.readInt(u64, e[0x60..0x68], .little),
        };
    }

    var files: std.ArrayList(MappedFile) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f.path);
        files.deinit(allocator);
    }
    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();
    {
        var dirs: usize = 0;
        var regs: usize = 0;
        for (nodes) |n| {
            if (n.dir()) dirs += 1;
            if (n.mode & 0xF000 == 0x8000) regs += 1;
        }
        std.debug.print("  [tree] inodes={d} dirs={d} files={d} root(mode=0x{x} size={d} logical=0x{x})\n", .{
            nodes.len, dirs, regs, nodes[0].mode, nodes[0].size, nodes[0].logical,
        });
    }
    try walkDir(allocator, src, io, image_offset, image_size, blocks, mount, logical_base, nodes, block_size, 0, "", false, &files, &seen);
    if (files.items.len == 0) return error.InvalidPfs;
    return files.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn copyLogical(
    src: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    image_offset: u64,
    image_size: u64,
    blocks: []const UBlock,
    logical: u64,
    dst: []u8,
) Error!void {
    if (dst.len == 0) return;
    var wrote: usize = 0;
    var pos = logical;
    while (wrote < dst.len) {
        const blk = findBlock(blocks, pos) orelse break;
        const into = pos - blk.logical;
        if (into >= blk.uncomp) break;
        var ubuf: [naps.ublock_size]u8 = undefined;
        const span = ubuf[0..blk.uncomp];
        @memset(span, 0);
        try decodeUblock(allocator, src, io, image_offset, image_size, blk, span);
        const avail = blk.uncomp - @as(u32, @intCast(into));
        const n: usize = @intCast(@min(dst.len - wrote, avail));
        const from: usize = @intCast(into);
        @memcpy(dst[wrote .. wrote + n], span[from .. from + n]);
        wrote += n;
        pos += n;
    }
    if (wrote != dst.len) return error.TruncatedPfs;
}

fn walkDir(
    allocator: std.mem.Allocator,
    src: std.Io.File,
    io: std.Io,
    image_offset: u64,
    image_size: u64,
    blocks: []const UBlock,
    mount: []const u8,
    logical_base: u64,
    nodes: []const InnerInode,
    block_size: u32,
    dir_ino: u32,
    path: []const u8,
    under_uroot: bool,
    files: *std.ArrayList(MappedFile),
    seen: *std.AutoHashMap(u32, void),
) Error!void {
    if (dir_ino >= nodes.len) return error.InvalidPfs;
    if (seen.contains(dir_ino)) return;
    seen.put(dir_ino, {}) catch return error.OutOfMemory;
    const dir = nodes[dir_ino];
    if (!dir.dir() or dir.size == 0 or dir.size > 8 * 1024 * 1024) return error.InvalidPfs;

    var slice: []const u8 = &.{};
    var owned: []u8 = &.{};
    defer if (owned.len != 0) allocator.free(owned);
    if (dir.logical >= logical_base) {
        const start: usize = @intCast(dir.logical - logical_base);
        if (start <= mount.len and dir.size <= mount.len - start) {
            slice = mount[start..][0..@intCast(dir.size)];
        }
    }
    if (slice.len == 0) {
        const n: usize = @intCast(dir.size);
        owned = allocator.alloc(u8, n) catch return error.OutOfMemory;
        @memset(owned, 0);
        try copyLogical(src, io, allocator, image_offset, image_size, blocks, dir.logical, owned);
        slice = owned;
    }
    var offset: usize = 0;
    while (try nextDirent(slice, &offset, block_size)) |ent| {
        if (ent.name.len == 0 or std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
        if (ent.ino >= nodes.len) return error.InvalidPfs;
        if (std.mem.indexOfAny(u8, ent.name, "/\\:") != null) return error.InvalidPfs;
        const child_under = under_uroot or std.mem.eql(u8, ent.name, "uroot");
        var child_path: []const u8 = "";
        if (std.mem.eql(u8, ent.name, "uroot") and path.len == 0) {
            child_path = "";
        } else if (path.len == 0) {
            child_path = allocator.dupe(u8, ent.name) catch return error.OutOfMemory;
        } else {
            child_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, ent.name }) catch return error.OutOfMemory;
        }
        errdefer if (child_path.len != 0) allocator.free(child_path);
        const is_dir = ent.kind == 3;
        if (is_dir) {
            try walkDir(allocator, src, io, image_offset, image_size, blocks, mount, logical_base, nodes, block_size, ent.ino, child_path, child_under, files, seen);
            if (child_path.len != 0) allocator.free(child_path);
        } else if (ent.kind == 2 and under_uroot and child_path.len != 0) {
            files.append(allocator, .{
                .path = child_path,
                .logical = nodes[ent.ino].logical,
                .size = nodes[ent.ino].size,
            }) catch return error.OutOfMemory;
        } else if (child_path.len != 0) {
            allocator.free(child_path);
        }
    }
}

fn writeFileFromBlocks(
    src: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    image_offset: u64,
    image_size: u64,
    blocks: []const UBlock,
    ubuf: []u8,
    dest: std.Io.Dir,
    file: MappedFile,
) Error!void {
    if (std.fs.path.dirname(file.path)) |parent| {
        dest.createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.Io,
        };
    }
    var out = dest.createFile(io, file.path, .{ .truncate = true }) catch return error.Io;
    defer out.close(io);

    var remaining = file.size;
    var logical = file.logical;
    while (remaining > 0) {
        const blk = findBlock(blocks, logical) orelse return error.TruncatedPfs;
        const into = logical - blk.logical;
        if (into >= blk.uncomp) break;
        try decodeUblock(allocator, src, io, image_offset, image_size, blk, ubuf[0..blk.uncomp]);
        const avail = blk.uncomp - @as(u32, @intCast(into));
        const n: usize = @intCast(@min(remaining, avail));
        out.writeStreamingAll(io, ubuf[into .. into + n]) catch return error.Io;
        remaining -= n;
        logical += n;
    }
    if (remaining != 0) return error.TruncatedPfs;
}

fn findBlock(blocks: []const UBlock, logical: u64) ?UBlock {
    var low: usize = 0;
    var high = blocks.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const b = blocks[mid];
        if (logical < b.logical) high = mid else if (logical - b.logical >= b.uncomp) low = mid + 1 else return b;
    }
    return null;
}

const Dirent = struct {
    ino: u32,
    kind: u32,
    name: []const u8,
};

fn nextDirent(buf: []const u8, offset: *usize, block_size: usize) Error!?Dirent {
    while (offset.* < buf.len) {
        if (buf.len - offset.* < 16) return error.TruncatedPfs;
        const rec = buf[offset.*..];
        const ino = std.mem.readInt(u32, rec[0..4], .little);
        const kind = std.mem.readInt(u32, rec[4..8], .little);
        const name_len = std.mem.readInt(u32, rec[8..12], .little);
        const rec_size = std.mem.readInt(u32, rec[12..16], .little);
        if (rec_size == 0 and ino == 0 and kind == 0 and name_len == 0) {
            offset.* += @min(block_size - offset.* % block_size, buf.len - offset.*);
            continue;
        }
        if (rec_size < 16 or rec_size > 0x1000 or name_len > rec_size - 16 or rec_size > buf.len - offset.*) return error.InvalidPfs;
        const name = std.mem.sliceTo(rec[16..][0..name_len], 0);
        offset.* += rec_size;
        if (name.len == 0) return error.InvalidPfs;
        return .{ .ino = ino, .kind = kind, .name = name };
    }
    return null;
}

test "flat inner PFS uses byte addresses and preserves the uroot tree" {
    const bs = 0x1000;
    const base: u64 = 0x2_0000_0000;
    var mount: [4 * bs]u8 = @splat(0);
    std.mem.writeInt(u16, mount[0x1c..0x1e], 0x18, .little);
    std.mem.writeInt(u32, mount[0x20..0x24], bs, .little);
    std.mem.writeInt(u64, mount[0x30..0x38], 3, .little);
    for (0..3) |i| {
        const rec = mount[bs + i * 0xa8 ..][0..0xa8];
        std.mem.writeInt(u16, rec[0..2], if (i < 2) 0x416d else 0x816d, .little);
        std.mem.writeInt(u64, rec[8..16], if (i < 2) bs else 13, .little);
        std.mem.writeInt(u64, rec[0x60..0x68], if (i < 2) base + (i + 2) * bs else 0x42, .little);
    }
    const root = mount[2 * bs ..][0..24];
    std.mem.writeInt(u32, root[0..4], 1, .little);
    std.mem.writeInt(u32, root[4..8], 3, .little);
    std.mem.writeInt(u32, root[8..12], 5, .little);
    std.mem.writeInt(u32, root[12..16], 24, .little);
    @memcpy(root[16..21], "uroot");
    const entry = mount[3 * bs ..][0..24];
    std.mem.writeInt(u32, entry[0..4], 2, .little);
    std.mem.writeInt(u32, entry[4..8], 2, .little);
    std.mem.writeInt(u32, entry[8..12], 5, .little);
    std.mem.writeInt(u32, entry[12..16], 24, .little);
    @memcpy(entry[16..21], "a.pak");
    const files = try readFileTree(std.testing.allocator, undefined, std.testing.io, 0, 0, &.{}, &mount, base, 0);
    defer {
        for (files) |file| std.testing.allocator.free(file.path);
        std.testing.allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("a.pak", files[0].path);
    try std.testing.expectEqual(@as(u64, 0x42), files[0].logical);
    try std.testing.expectEqual(@as(u64, 13), files[0].size);
    // A malformed tree must fail, not produce positional files or a partial success.
    std.mem.writeInt(u32, entry[8..12], 30, .little);
    try std.testing.expectError(error.InvalidPfs, readFileTree(std.testing.allocator, undefined, std.testing.io, 0, 0, &.{}, &mount, base, 0));
}

test "directory padding does not hide entries in later blocks" {
    var buf: [128]u8 = @splat(0);
    std.mem.writeInt(u32, buf[64..68], 2, .little);
    std.mem.writeInt(u32, buf[68..72], 2, .little);
    std.mem.writeInt(u32, buf[72..76], 1, .little);
    std.mem.writeInt(u32, buf[76..80], 24, .little);
    buf[80] = 'x';
    var pos: usize = 0;
    const ent = (try nextDirent(&buf, &pos, 64)).?;
    try std.testing.expectEqualStrings("x", ent.name);
    try std.testing.expectEqual(@as(?Dirent, null), try nextDirent(&buf, &pos, 64));
}

test "a superblock from a different mount is rejected" {
    var buf: [0x40]u8 = @splat(0);
    std.mem.writeInt(u64, buf[0..8], 2, .little);
    std.mem.writeInt(i64, buf[8..16], pfs_magic, .little);
    std.mem.writeInt(u32, buf[0x20..0x24], 0x10000, .little);
    std.mem.writeInt(u64, buf[0x30..0x38], 5, .little);
    std.mem.writeInt(u64, buf[0x38..0x40], 10, .little);
    try std.testing.expectEqual(@as(?usize, null), findSuperblock(&buf, 0x200000));
    try std.testing.expectEqual(@as(?usize, 0), findSuperblock(&buf, 0xa0000));
}
