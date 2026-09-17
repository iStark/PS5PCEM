// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Reconstruct a data-first inner PFS from pfs_image.dat + naps_pkg_layout.dat
//! and write the uroot file tree. Uses the Sony debug CblockInfo packing
//! (run-base bit 2) observed on commercial PLAIN-NOAUTH FPKGs.

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
};

const UBlock = struct {
    logical: u64,
    on_disk: u64,
    comp: u32,
    uncomp: u32,
    kraken: bool,
    even_comp: u32,
};

pub const InnerStats = struct {
    files: u32 = 0,
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

    const mount = if (layout.mountSize() != 0) layout.mountSize() else @as(u64, layout.counts.num_ublocks) * naps.ublock_size;
    if (mount == 0) return error.InvalidPfs;

    var blocks: std.ArrayList(UBlock) = .empty;
    defer blocks.deinit(allocator);
    try walkBlocks(allocator, layout, mount, &blocks);
    if (blocks.items.len == 0) return error.InvalidPfs;

    var stats = InnerStats{};
    for (blocks.items) |b| {
        if (b.kraken) stats.kraken_blocks += 1 else stats.stored_blocks += 1;
    }

    // The inode's size for pfs_image.dat can stop short of the blocks its own
    // layout points at. Big Helmet Heroes keeps the inode table and every
    // directory entry in the last 1.4 MB, past that declared end; reading only
    // the declared extent leaves those blocks zero, so the file tree cannot be
    // read and every name comes out positional -- file_0001, prx_00.prx --
    // which no loader can resolve a module from. The map knows how far the
    // image reaches, and the outer PFS is what bounds it.
    var image_extent = image_size;
    for (blocks.items) |b| {
        const end = @as(u64, b.on_disk) +| @as(u64, b.comp);
        if (end > image_extent) image_extent = end;
    }
    if (image_extent > image_limit) image_extent = image_limit;
    if (image_extent != image_size) {
        std.debug.print("  image reaches 0x{x}, past the declared 0x{x}\n", .{ image_extent, image_size });
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
    const meta = try decodeTail(allocator, src, io, image_offset, image_extent, blocks.items, meta_base_logical);
    defer allocator.free(meta.buf);

    const sb_off = findSuperblock(meta.buf, mount) orelse blk: {
        tryKrakenPhysicalTail(allocator, src, io, image_offset, image_extent, meta.buf);
        if (findSuperblock(meta.buf, mount)) |off| break :blk off;
        var dump: usize = 0;
        while (dump + 16 <= meta.buf.len and dump < 0x40000) : (dump += 0x10000) {
            std.debug.print("  tail+0x{x} {x:0>2}{x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
                dump,
                meta.buf[dump],
                meta.buf[dump + 1],
                meta.buf[dump + 2],
                meta.buf[dump + 3],
                meta.buf[dump + 8],
                meta.buf[dump + 9],
                meta.buf[dump + 10],
                meta.buf[dump + 11],
            });
        }
        return error.InvalidPfs;
    };
    const files = readFileTree(
        allocator,
        src,
        io,
        image_offset,
        image_extent,
        blocks.items,
        meta.buf,
        meta.logical_base,
        sb_off,
    ) catch try filesFromLayout(allocator, layout, meta_base_logical);

    std.debug.print(
        "inner mount 0x{x}  blocks={d} (stored {d}, kraken {d})  files={d}  superblock+0x{x}\n",
        .{ mount, blocks.items.len, stats.stored_blocks, stats.kraken_blocks, files.len, sb_off },
    );

    const ubuf: []u8 = allocator.alloc(u8, naps.ublock_size) catch return error.OutOfMemory;
    defer allocator.free(ubuf);

    for (files) |file| {
        if (file.path.len == 0) continue;
        writeFileFromBlocks(src, io, allocator, image_offset, image_extent, blocks.items, ubuf, dest, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        const final_path = sniffRename(dest, io, file.path) catch file.path;
        stats.files += 1;
        std.debug.print("  {s}  {d} bytes\n", .{ final_path, file.size });
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
            const pos = rec.runOnDisk();
            if (pos < 0x400000000) on_disk = pos;
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
        }) catch return error.OutOfMemory;
        // coffset_mod tracks the on-disk cursor for both stored and Kraken blocks.
        on_disk += comp_len;
        uncomp += uncomp_len;
        if (uncomp >= mount) break;
    }
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
    if (start_index >= blocks.len) {
        const tail_n: usize = @min(blocks.len, 8);
        start_index = blocks.len - tail_n;
    }
    const logical_base = blocks[start_index].logical;
    var total: usize = 0;
    for (blocks[start_index..]) |b| total += b.uncomp;
    var buf = allocator.alloc(u8, total) catch return error.OutOfMemory;
    @memset(buf, 0);
    var off: usize = 0;
    var decoded_ok: u32 = 0;
    for (blocks[start_index..]) |b| {
        const before = buf[off];
        const in_image = b.on_disk < image_size;
        decodeUblock(allocator, src, io, image_offset, image_size, b, buf[off .. off + b.uncomp]);
        if (buf[off] != before or b.uncomp == 0) decoded_ok += 1;
        if (!in_image or b.kraken) {
            std.debug.print("  meta blk logical=0x{x} disk=0x{x} comp={d} uncomp={d} kraken={} in_image={}\n", .{
                b.logical, b.on_disk, b.comp, b.uncomp, b.kraken, in_image,
            });
        }
        off += b.uncomp;
    }
    std.debug.print("  decoded meta {d} bytes from {d} blocks (logical 0x{x} meta 0x{x}, wrote {d})\n", .{
        buf.len, blocks.len - start_index, logical_base, meta_base, decoded_ok,
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
) void {
    if (dst.len == 0) return;
    if (block.on_disk >= image_size) return;
    const max_read = @min(@as(u64, block.comp), image_size - block.on_disk);
    if (max_read == 0) return;
    const want: usize = @intCast(@min(max_read, dst.len + block.comp));
    var tmp_buf: [naps.ublock_size]u8 = undefined;
    const read_n: usize = @intCast(@min(max_read, tmp_buf.len));
    const got = src.readPositionalAll(io, tmp_buf[0..read_n], image_offset + block.on_disk) catch 0;
    if (got == 0) return;

    if (got == dst.len) {
        @memcpy(dst, tmp_buf[0..dst.len]);
        return;
    }
    var trimmed = got;
    while (trimmed > 16 and tmp_buf[trimmed - 1] == 0) trimmed -= 1;
    const payload = tmp_buf[0..trimmed];
    const guesses = [_]u32{ block.even_comp, @intCast(trimmed / 2), @intCast(trimmed) };
    for (guesses) |fc| {
        const st = kraken.decodeBlockAuto(allocator, payload, fc, dst);
        if (st == .success) return;
    }
    const flags = [_]u32{ 0x03, 0x02, 0x01, 0x00 };
    for (flags) |flag| {
        const st = kraken.decodeBlock(allocator, payload, flag, @intCast(trimmed), dst);
        if (st == .success) return;
    }
    if (!block.kraken) {
        const n = @min(got, dst.len);
        @memcpy(dst[0..n], tmp_buf[0..n]);
        return;
    }
    const n = @min(got, dst.len);
    @memcpy(dst[0..n], tmp_buf[0..n]);
    _ = want;
}

fn tryKrakenPhysicalTail(
    allocator: std.mem.Allocator,
    src: std.Io.File,
    io: std.Io,
    image_offset: u64,
    image_size: u64,
    dst: []u8,
) void {
    if (dst.len == 0 or image_size == 0) return;
    const take: usize = @intCast(@min(image_size, @as(u64, 0x10000)));
    var tmp: [naps.ublock_size]u8 = undefined;
    const got = src.readPositionalAll(io, tmp[0..take], image_offset + image_size - take) catch 0;
    if (got < 16) return;
    var trimmed = got;
    while (trimmed > 16 and tmp[trimmed - 1] == 0) trimmed -= 1;
    const flags128 = [_]u32{ 0x03, 0x02, 0x01, 0x00 };
    const out128 = @min(dst.len, 0x20000);
    for (flags128) |flag| {
        @memset(dst[0..out128], 0);
        const st = kraken.decodeBlock(allocator, tmp[0..trimmed], flag, @intCast(trimmed), dst[0..out128]);
        std.debug.print("  tail 128k flag=0x{x} {s} head {x:0>2}{x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
            flag, @tagName(st), dst[0], dst[1], dst[2], dst[3], dst[8], dst[9], dst[10], dst[11],
        });
        if (st == .success and findSuperblock(dst[0..out128], 0) != null) return;
    }
    const out256 = @min(dst.len, naps.ublock_size);
    const flags256 = [_]u32{ 0x22, 0x02, 0x12, 0x32, 0x23, 0x03 };
    var fc: u32 = @intCast(got / 4);
    const step: u32 = @intCast(@max(got / 8, 1));
    while (fc + 8 < got) : (fc += step) {
        for (flags256) |flag| {
            @memset(dst[0..out256], 0);
            const st = kraken.decodeBlock(allocator, tmp[0..got], flag, fc, dst[0..out256]);
            if (st == .success) {
                std.debug.print("  tail 256k flag=0x{x} fc={d} success head {x:0>2}{x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
                    flag, fc, dst[0], dst[1], dst[2], dst[3], dst[8], dst[9], dst[10], dst[11],
                });
                if (findSuperblock(dst[0..out256], 0) != null) return;
            }
        }
    }
}

/// The superblock this image agrees with, not merely the first one present.
/// A version-2 header appears more than once in the metadata -- a mount keeps
/// a copy of its own -- and picking the wrong one reads an inode table that
/// belongs to something else: five inodes where the image has eighty-two. The
/// one that belongs here is the one whose block count covers the image
/// exactly.
fn findSuperblock(buf: []const u8, mount_size: u64) ?usize {
    var fallback: ?usize = null;
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
        if (fallback == null) fallback = off;
    }
    return fallback;
}

const InnerInode = struct {
    mode: u16,
    size: u64,
    logical: u64,
    fn dir(self: InnerInode) bool {
        return self.mode & 0x4000 != 0;
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
    const inode_size: usize = 0xA8;
    const table_bytes = inode_count * inode_size;
    var inode_buf = allocator.alloc(u8, table_bytes) catch return error.OutOfMemory;
    defer allocator.free(inode_buf);
    @memset(inode_buf, 0);

    const local_table = meta_base + block_size;
    var filled = false;
    if (local_table + table_bytes <= mount.len) {
        @memcpy(inode_buf, mount[local_table .. local_table + table_bytes]);
        filled = inodeLooksPlausible(inode_buf);
    }
    if (!filled) {
        const inode_block = std.mem.readInt(u64, mount[meta_base + 0xD8 ..][0..8], .little);
        const candidates = [_]u64{
            logical_base + block_size,
            inode_block *% block_size,
            @as(u64, 1) * block_size,
            logical_base + @as(u64, block_size) * 2,
        };
        for (candidates) |logical| {
            if (logical == 0 or logical >= 0x400000000) continue;
            @memset(inode_buf, 0);
            if (copyLogical(src, io, allocator, image_offset, image_size, blocks, logical, inode_buf) and inodeLooksPlausible(inode_buf)) {
                filled = true;
                std.debug.print("  inodes at logical 0x{x}\n", .{logical});
                break;
            }
        }
    }
    if (!filled) {
        std.debug.print("  inode table missing (count={d} block={d})\n", .{ inode_count, block_size });
        return error.InvalidPfs;
    }

    var nodes = allocator.alloc(InnerInode, inode_count) catch return error.OutOfMemory;
    defer allocator.free(nodes);
    var i: usize = 0;
    while (i < inode_count) : (i += 1) {
        const e = inode_buf[i * inode_size ..][0..inode_size];
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
    walkDir(allocator, src, io, image_offset, image_size, blocks, mount, logical_base, nodes, 0, "", false, &files, &seen) catch |err| {
        std.debug.print("  [tree] walk stopped: {s}\n", .{@errorName(err)});
    };
    std.debug.print("  [tree] collected {d} path(s)\n", .{files.items.len});
    return files.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn sniffRename(dest: std.Io.Dir, io: std.Io, path: []const u8) ![]const u8 {
    if (path.len < 5 or !std.mem.startsWith(u8, path, "file_")) return path;
    var f = dest.openFile(io, path, .{ .mode = .read_only }) catch return path;
    defer f.close(io);
    var head: [16]u8 = undefined;
    const n = f.readPositionalAll(io, &head, 0) catch return path;
    if (n < 4) return path;
    const new_name: []const u8 = if (std.mem.eql(u8, head[0..8], "keystone"))
        "keystone"
    else if (n >= 7 and std.mem.eql(u8, head[0..7], "01.000."))
        "pfs-version.dat"
    else if (n >= 10 and std.mem.eql(u8, head[0..10], "[Manifest]"))
        "manifest.txt"
    else
        return path;
    dest.rename(path, dest, new_name, io) catch return path;
    return new_name;
}

fn filesFromLayout(allocator: std.mem.Allocator, layout: naps.Layout, meta_base: u64) Error![]MappedFile {
    var files: std.ArrayList(MappedFile) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f.path);
        files.deinit(allocator);
    }
    const offs = layout.file_offsets;
    if (offs.len < 2) return error.InvalidPfs;
    var i: usize = 0;
    while (i + 1 < offs.len) : (i += 1) {
        const start = offs[i].uncompressed_offset;
        const end = offs[i + 1].uncompressed_offset;
        if (start >= meta_base or end <= start) continue;
        if (offs[i].kind == 64 or offs[i + 1].kind == 64) continue;
        const size = end - start;
        if (size == 0 or size > 8 * 1024 * 1024 * 1024) continue;
        const path = std.fmt.allocPrint(allocator, "file_{d:0>4}", .{i}) catch return error.OutOfMemory;
        files.append(allocator, .{ .path = path, .logical = start, .size = size }) catch return error.OutOfMemory;
    }
    if (files.items.len == 0) return error.InvalidPfs;
    return files.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn inodeLooksPlausible(buf: []const u8) bool {
    if (buf.len < 0xA8) return false;
    const mode = std.mem.readInt(u16, buf[0..2], .little);
    return mode & 0xF000 == 0x4000 or mode & 0xF000 == 0x8000;
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
) bool {
    if (dst.len == 0) return true;
    var wrote: usize = 0;
    var pos = logical;
    while (wrote < dst.len) {
        const blk = findBlock(blocks, pos) orelse break;
        const into = pos - blk.logical;
        if (into >= blk.uncomp) break;
        var ubuf: [naps.ublock_size]u8 = undefined;
        const span = ubuf[0..blk.uncomp];
        @memset(span, 0);
        decodeUblock(allocator, src, io, image_offset, image_size, blk, span);
        const avail = blk.uncomp - @as(u32, @intCast(into));
        const n: usize = @intCast(@min(dst.len - wrote, avail));
        const from: usize = @intCast(into);
        @memcpy(dst[wrote .. wrote + n], span[from .. from + n]);
        wrote += n;
        pos += n;
    }
    return wrote == dst.len;
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
    dir_ino: u32,
    path: []const u8,
    under_uroot: bool,
    files: *std.ArrayList(MappedFile),
    seen: *std.AutoHashMap(u32, void),
) Error!void {
    if (dir_ino >= nodes.len) return;
    if (seen.contains(dir_ino)) return;
    seen.put(dir_ino, {}) catch return error.OutOfMemory;
    const dir = nodes[dir_ino];
    if (!dir.dir() or dir.size == 0 or dir.size > 8 * 1024 * 1024) return;

    var slice: []const u8 = &.{};
    var owned: []u8 = &.{};
    defer if (owned.len != 0) allocator.free(owned);
    if (dir.logical >= logical_base) {
        const start: usize = @intCast(dir.logical - logical_base);
        if (start < mount.len) {
            const end = @min(start + @as(usize, @intCast(@min(dir.size, mount.len - start))), mount.len);
            slice = mount[start..end];
        }
    }
    if (slice.len == 0) {
        const n: usize = @intCast(@min(dir.size, 1024 * 1024));
        owned = allocator.alloc(u8, n) catch return error.OutOfMemory;
        @memset(owned, 0);
        if (!copyLogical(src, io, allocator, image_offset, image_size, blocks, dir.logical, owned)) {
            return;
        }
        slice = owned;
    }
    var offset: usize = 0;
    while (nextDirent(slice, &offset)) |ent| {
        if (ent.name.len == 0 or std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
        if (ent.ino >= nodes.len) continue;
        const child_under = under_uroot or std.mem.eql(u8, ent.name, "uroot");
        var child_path: []const u8 = "";
        if (std.mem.eql(u8, ent.name, "uroot") and path.len == 0) {
            child_path = "";
        } else if (path.len == 0) {
            child_path = allocator.dupe(u8, ent.name) catch return error.OutOfMemory;
        } else {
            child_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, ent.name }) catch return error.OutOfMemory;
        }
        const is_dir = ent.kind == 3;
        if (is_dir) {
            try walkDir(allocator, src, io, image_offset, image_size, blocks, mount, logical_base, nodes, ent.ino, child_path, child_under, files, seen);
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
        const blk = findBlock(blocks, logical) orelse break;
        const into = logical - blk.logical;
        if (into >= blk.uncomp) break;
        decodeUblock(allocator, src, io, image_offset, image_size, blk, ubuf[0..blk.uncomp]);
        const avail = blk.uncomp - @as(u32, @intCast(into));
        const n: usize = @intCast(@min(remaining, avail));
        out.writeStreamingAll(io, ubuf[into .. into + n]) catch return error.Io;
        remaining -= n;
        logical += n;
    }
}

fn findBlock(blocks: []const UBlock, logical: u64) ?UBlock {
    for (blocks) |b| {
        if (logical >= b.logical and logical < b.logical + b.uncomp) return b;
    }
    return null;
}

const Dirent = struct {
    ino: u32,
    kind: u32,
    name: []const u8,
};

fn nextDirent(buf: []const u8, offset: *usize) ?Dirent {
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
