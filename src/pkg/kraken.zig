// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz
//
// Kraken (newLZ) decoder for PS5 header-stripped PFS blocks.
// Logic follows the GPLv3 LibProsperoPkg managed decoder (SvenGDK / NOTICE).

const std = @import("std");

pub const Status = enum {
    success,
    malformed,
    unsupported_entropy,
};

const chunk_max: usize = 0x20000;
const seed_size: usize = 8;
const chunk0_sub_lit: u32 = 0x01;
const chunk0_new_lz: u32 = 0x02;
const chunk1_sub_lit: u32 = 0x10;
const chunk1_new_lz: u32 = 0x20;
const chunk1_restart: u32 = 0x40;

const code_prefix_org = [_]u32{ 0x0, 0x0, 0x2, 0x6, 0xE, 0x1E, 0x3E, 0x7E, 0xFE, 0x1FE, 0x2FE, 0x3FE };

pub fn decodeBlock(allocator: std.mem.Allocator, payload: []const u8, flags: u32, first_chunk_comp: u32, dst: []u8) Status {
    @setRuntimeSafety(false);
    if (dst.len == 0) return if (payload.len == 0) .success else .malformed;
    const one_chunk = first_chunk_comp == 0 or first_chunk_comp >= payload.len or dst.len <= chunk_max;
    if (one_chunk) {
        return decodeSubChunk(allocator, payload, dst, 0, dst.len, flags & chunk0_new_lz != 0, true, if (flags & chunk0_sub_lit != 0) 0 else 1);
    }
    const chunk0_dst: usize = @min(dst.len, chunk_max);
    const chunk1_dst: usize = dst.len - chunk0_dst;
    const chunk0_comp: usize = first_chunk_comp;
    if (chunk0_comp == 0 or chunk0_comp > payload.len) return .malformed;
    const chunk1_comp: usize = payload.len - chunk0_comp;
    if (chunk1_dst == 0 and chunk1_comp != 0) return .malformed;

    var st = decodeSubChunk(allocator, payload[0..chunk0_comp], dst, 0, chunk0_dst, flags & chunk0_new_lz != 0, true, if (flags & chunk0_sub_lit != 0) 0 else 1);
    if (st != .success) return st;
    if (chunk1_dst > 0) {
        st = decodeSubChunk(
            allocator,
            payload[chunk0_comp..][0..chunk1_comp],
            dst,
            chunk0_dst,
            chunk1_dst,
            flags & chunk1_new_lz != 0,
            flags & chunk1_restart != 0,
            if (flags & chunk1_sub_lit != 0) 0 else 1,
        );
    }
    return st;
}

pub fn decodeBlockAuto(allocator: std.mem.Allocator, payload: []const u8, first_chunk_comp: u32, dst: []u8) Status {
    @setRuntimeSafety(false);
    if (payload.len == dst.len) {
        @memcpy(dst, payload);
        return .success;
    }
    const multi = dst.len > chunk_max;
    const flags: []const u32 = if (multi)
        &.{ 0x03, 0x23, 0x02, 0x22, 0x13, 0x33, 0x12, 0x32, 0x00, 0x20 }
    else
        &.{ 0x03, 0x02, 0x01, 0x00 };
    const splits = [_]u32{ @intCast(payload.len), first_chunk_comp, @intCast(payload.len / 2) };
    for (flags) |flag| {
        for (splits) |fc| {
            if (fc == 0 or fc > payload.len) continue;
            const st = decodeBlock(allocator, payload, flag, fc, dst);
            if (st == .success) return .success;
        }
        if (!multi) {
            const st = decodeBlock(allocator, payload, flag, @intCast(payload.len), dst);
            if (st == .success) return .success;
        }
    }
    return .unsupported_entropy;
}

fn decodeSubChunk(
    allocator: std.mem.Allocator,
    src: []const u8,
    dst: []u8,
    dst_start: usize,
    dst_len: usize,
    lz_enable: bool,
    restart: bool,
    literal_mode: u32,
) Status {
    if (dst_start + dst_len > dst.len) return .malformed;
    const slice = dst[dst_start .. dst_start + dst_len];
    if (src.len == dst_len) {
        @memcpy(slice, src);
        return .success;
    }
    if (lz_enable) return decodeChunk(allocator, src, dst, dst_start, dst_len, restart, literal_mode);
    return decodeBareEntropy(allocator, src, slice);
}

fn decodeBareEntropy(allocator: std.mem.Allocator, src: []const u8, dst: []u8) Status {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    const used = decodeBytes(allocator, src, dst.len, &decoded) catch |err| switch (err) {
        error.UnsupportedEntropy => return .unsupported_entropy,
        else => return .malformed,
    };
    if (used != src.len or decoded.items.len != dst.len) return .malformed;
    @memcpy(dst, decoded.items);
    return .success;
}

const LzTable = struct {
    lit: []u8 = &.{},
    cmd: []u8 = &.{},
    offs: []i32 = &.{},
    lens: []i32 = &.{},

    fn deinit(self: *LzTable, allocator: std.mem.Allocator) void {
        if (self.lit.len != 0) allocator.free(self.lit);
        if (self.cmd.len != 0) allocator.free(self.cmd);
        if (self.offs.len != 0) allocator.free(self.offs);
        if (self.lens.len != 0) allocator.free(self.lens);
    }
};

fn decodeChunk(allocator: std.mem.Allocator, src: []const u8, dst: []u8, dst_start: usize, dst_len: usize, with_seed: bool, literal_mode: u32) Status {
    var sp: usize = 0;
    if (with_seed) {
        if (src.len < seed_size or dst_len < seed_size) return .malformed;
        @memcpy(dst[dst_start .. dst_start + seed_size], src[0..seed_size]);
        sp = seed_size;
    }
    var table = LzTable{};
    defer table.deinit(allocator);
    const st = readLzTable(allocator, src, &sp, dst_len, &table);
    if (st != .success) return st;
    const start: usize = dst_start + if (with_seed) seed_size else 0;
    const end: usize = dst_start + dst_len;
    const ok = switch (literal_mode) {
        1 => processType1(&table, dst, start, end),
        0 => processType0(&table, dst, start, end),
        else => false,
    };
    if (!ok) return .malformed;
    return .success;
}

fn readLzTable(allocator: std.mem.Allocator, src: []const u8, sp: *usize, dst_size: usize, table: *LzTable) Status {
    var src_end = src.len;
    var excess_flag = false;
    var excess_count: usize = 0;
    if (sp.* < src_end and src[sp.*] & 0x80 != 0) {
        const flag = src[sp.*];
        if (flag & 0xC0 == 0x80) {
            sp.* += 1;
            excess_flag = true;
            excess_count = flag & 0x3F;
            if (excess_count > 0x1F) {
                if (sp.* >= src_end) return .malformed;
                excess_count += @as(usize, src[sp.*]) * 0x20;
                sp.* += 1;
            }
            if (src_end < sp.* + excess_count) return .malformed;
            src_end -= excess_count;
        }
    }

    var lit: std.ArrayList(u8) = .empty;
    errdefer lit.deinit(allocator);
    const lit_used = decodeBytes(allocator, src[sp.*..src_end], dst_size, &lit) catch |err| switch (err) {
        error.UnsupportedEntropy => return .unsupported_entropy,
        else => return .malformed,
    };
    sp.* += lit_used;
    table.lit = lit.toOwnedSlice(allocator) catch return .malformed;

    var cmd: std.ArrayList(u8) = .empty;
    errdefer cmd.deinit(allocator);
    const cmd_used = decodeBytes(allocator, src[sp.*..src_end], dst_size, &cmd) catch |err| switch (err) {
        error.UnsupportedEntropy => return .unsupported_entropy,
        else => return .malformed,
    };
    sp.* += cmd_used;
    table.cmd = cmd.toOwnedSlice(allocator) catch return .malformed;

    if (src_end - sp.* < 3) return .malformed;

    var offs_scaling: i32 = 0;
    var packed_offs: std.ArrayList(u8) = .empty;
    defer packed_offs.deinit(allocator);
    var packed_extra: std.ArrayList(u8) = .empty;
    defer packed_extra.deinit(allocator);

    if (src[sp.*] & 0x80 != 0) {
        offs_scaling = @as(i32, src[sp.*]) - 127;
        sp.* += 1;
        const n = decodeBytes(allocator, src[sp.*..src_end], table.cmd.len, &packed_offs) catch return .malformed;
        sp.* += n;
        if (offs_scaling != 1) {
            const n2 = decodeBytes(allocator, src[sp.*..src_end], packed_offs.items.len, &packed_extra) catch return .malformed;
            if (packed_extra.items.len != packed_offs.items.len) return .malformed;
            sp.* += n2;
        }
    } else {
        const n = decodeBytes(allocator, src[sp.*..src_end], table.cmd.len, &packed_offs) catch return .malformed;
        sp.* += n;
    }

    var packed_len: std.ArrayList(u8) = .empty;
    defer packed_len.deinit(allocator);
    const nlen = decodeBytes(allocator, src[sp.*..src_end], dst_size >> 2, &packed_len) catch return .malformed;
    sp.* += nlen;

    table.offs = allocator.alloc(i32, packed_offs.items.len) catch return .malformed;
    table.lens = allocator.alloc(i32, packed_len.items.len) catch return .malformed;
    if (!unpackOffsets(src, sp.*, src_end, excess_flag, excess_count, packed_offs.items, offs_scaling, packed_extra.items, packed_len.items, table.offs, table.lens)) {
        return .malformed;
    }
    return .success;
}

fn unpackOffsets(
    src: []const u8,
    bs_begin: usize,
    bs_end: usize,
    excess_flag: bool,
    excess_count: usize,
    packed_offs: []const u8,
    offs_scaling: i32,
    packed_extra: []const u8,
    packed_len: []const u8,
    offs_out: []i32,
    len_out: []i32,
) bool {
    @setRuntimeSafety(false);
    // Sony excess chunks pad the offset bitstream with 0xFF. Those bytes are
    // not extra-distance bits; the backward reader must start before them.
    var bwd_end = bs_end;
    if (excess_flag) {
        while (bwd_end > bs_begin + 1 and src[bwd_end - 1] == 0xFF) bwd_end -= 1;
    }
    var a = BitReader.forward(src, bs_begin, bs_end);
    var b = BitReader.backward(src, bs_begin, bwd_end);
    var u32_len: usize = 0;
    if (!excess_flag) {
        if (a.bits < 0x2000 and b.bits < 0x2000) {
            // still try
        }
        if (b.bits < 0x2000) return false;
        var nn: u32 = 31 - bsr(b.bits);
        b.bit_pos += @as(i32, @intCast(nn));
        b.bits <<= @intCast(nn);
        b.refillB();
        nn += 1;
        u32_len = @intCast((b.bits >> @intCast(32 - nn)) - 1);
        b.bit_pos += @as(i32, @intCast(nn));
        b.bits <<= @intCast(nn);
        b.refillB();
    } else {
        for (packed_len) |v| {
            if (v == 255) u32_len += 1;
        }
    }
    if (u32_len > 512) return false;
    if (offs_scaling == 0) {
        var i: usize = 0;
        while (i < packed_offs.len) {
            offs_out[i] = -@as(i32, @intCast(a.readDistance(packed_offs[i])));
            i += 1;
            if (i >= packed_offs.len) break;
            offs_out[i] = -@as(i32, @intCast(b.readDistanceB(packed_offs[i])));
            i += 1;
        }
    } else {
        var i: usize = 0;
        while (i < packed_offs.len) {
            const cmd = packed_offs[i];
            if ((cmd >> 3) > 26) return false;
            var off = ((8 + @as(u32, cmd & 7)) << @intCast(cmd >> 3)) | a.readMoreThan24(cmd >> 3);
            offs_out[i] = 8 - @as(i32, @intCast(off));
            i += 1;
            if (i >= packed_offs.len) break;
            const cmd2 = packed_offs[i];
            if ((cmd2 >> 3) > 26) return false;
            off = ((8 + @as(u32, cmd2 & 7)) << @intCast(cmd2 >> 3)) | b.readMoreThan24B(cmd2 >> 3);
            offs_out[i] = 8 - @as(i32, @intCast(off));
            i += 1;
        }
        if (offs_scaling != 1) {
            if (packed_extra.len != packed_offs.len) return false;
            for (offs_out, packed_extra) |*o, e| {
                o.* = @as(i32, @as(i8, @bitCast(e))) - o.* * offs_scaling;
            }
        }
    }

    var u32s: [512]u32 = undefined;
    if (u32_len > 0) {
        if (excess_flag) {
            var ea = BitReader.forward(src, bs_end, bs_end + excess_count);
            var eb = BitReader.backward(src, bs_end, bs_end + excess_count);
            var i: usize = 0;
            while (i + 1 < u32_len) : (i += 2) {
                if (!ea.readLength(&u32s[i])) return false;
                if (!eb.readLengthB(&u32s[i + 1])) return false;
            }
            if (i < u32_len) {
                if (!ea.readLength(&u32s[i])) return false;
            }
        } else {
            var i: usize = 0;
            while (i + 1 < u32_len) : (i += 2) {
                if (!a.readLength(&u32s[i])) return false;
                if (!b.readLengthB(&u32s[i + 1])) return false;
            }
            if (i < u32_len) {
                if (!a.readLength(&u32s[i])) return false;
            }
        }
    }

    var u: usize = 0;
    for (packed_len, 0..) |v0, i| {
        var v: u32 = v0;
        if (v == 255) {
            if (u >= u32_len) return false;
            v = u32s[u] + 255;
            u += 1;
        }
        len_out[i] = @intCast(v + 3);
    }
    if (u != u32_len) return false;
    return true;
}

fn processType1(table: *LzTable, dst: []u8, start: usize, dst_end: usize) bool {
    const cmd = table.cmd;
    const lens = table.lens;
    const lit = table.lit;
    const offs = table.offs;
    var cmd_i: usize = 0;
    var len_i: usize = 0;
    var lit_i: usize = 0;
    var offs_i: usize = 0;
    var dst_pos = start;
    var recent: [7]i32 = .{ 0, 0, 0, -8, -8, -8, 0 };
    while (cmd_i < cmd.len) {
        const f = cmd[cmd_i];
        cmd_i += 1;
        var litlen: u32 = f & 3;
        const offs_index: usize = f >> 6;
        const matchlen: u32 = (f >> 2) & 0xF;
        if (litlen == 3) {
            if (len_i >= lens.len) return false;
            litlen = @intCast(lens[len_i]);
            len_i += 1;
        }
        recent[6] = if (offs_i < offs.len) offs[offs_i] else 0;
        if (litlen != 0) {
            if (lit_i + litlen > lit.len or dst_pos + litlen > dst_end) return false;
            @memcpy(dst[dst_pos .. dst_pos + litlen], lit[lit_i .. lit_i + litlen]);
            dst_pos += litlen;
            lit_i += litlen;
        }
        const offset = recent[offs_index + 3];
        recent[offs_index + 3] = recent[offs_index + 2];
        recent[offs_index + 2] = recent[offs_index + 1];
        recent[offs_index + 1] = recent[offs_index + 0];
        recent[3] = offset;
        offs_i += ((offs_index + 1) & 4) >> 2;
        const from = @as(i64, @intCast(dst_pos)) + offset;
        if (from < 0 or from > dst.len) return false;
        const actual: u32 = if (matchlen != 15) matchlen + 2 else blk: {
            if (len_i >= lens.len) return false;
            const v: u32 = @intCast(lens[len_i]);
            len_i += 1;
            break :blk 14 + v;
        };
        if (dst_pos + actual > dst_end) return false;
        var c: u32 = 0;
        const copy_from: usize = @intCast(from);
        while (c < actual) : (c += 1) dst[dst_pos + c] = dst[copy_from + c];
        dst_pos += actual;
    }
    if (offs_i != offs.len or len_i != lens.len) return false;
    const final_len = dst_end - dst_pos;
    if (final_len != lit.len - lit_i) return false;
    if (final_len != 0) @memcpy(dst[dst_pos..dst_end], lit[lit_i..]);
    return true;
}

fn processType0(table: *LzTable, dst: []u8, start: usize, dst_end: usize) bool {
    const cmd = table.cmd;
    const lens = table.lens;
    const lit = table.lit;
    const offs = table.offs;
    var cmd_i: usize = 0;
    var len_i: usize = 0;
    var lit_i: usize = 0;
    var offs_i: usize = 0;
    var dst_pos = start;
    var recent: [7]i32 = .{ 0, 0, 0, -8, -8, -8, 0 };
    var last_offset: i32 = -8;
    while (cmd_i < cmd.len) {
        const f = cmd[cmd_i];
        cmd_i += 1;
        var litlen: u32 = f & 3;
        const offs_index: usize = f >> 6;
        const matchlen: u32 = (f >> 2) & 0xF;
        if (litlen == 3) {
            if (len_i >= lens.len) return false;
            litlen = @intCast(lens[len_i]);
            len_i += 1;
        }
        recent[6] = if (offs_i < offs.len) offs[offs_i] else 0;
        if (litlen != 0) {
            if (lit_i + litlen > lit.len or dst_pos + litlen > dst_end) return false;
            var c: u32 = 0;
            while (c < litlen) : (c += 1) {
                const back = @as(i64, @intCast(dst_pos + c)) + last_offset;
                const prev: u8 = if (back >= 0 and @as(usize, @intCast(back)) < dst.len) dst[@intCast(back)] else 0;
                dst[dst_pos + c] = lit[lit_i + c] +% prev;
            }
            dst_pos += litlen;
            lit_i += litlen;
        }
        const offset = recent[offs_index + 3];
        recent[offs_index + 3] = recent[offs_index + 2];
        recent[offs_index + 2] = recent[offs_index + 1];
        recent[offs_index + 1] = recent[offs_index + 0];
        recent[3] = offset;
        last_offset = offset;
        offs_i += ((offs_index + 1) & 4) >> 2;
        const actual: u32 = if (matchlen != 15) matchlen + 2 else blk: {
            if (len_i >= lens.len) return false;
            const v: u32 = @intCast(lens[len_i]);
            len_i += 1;
            break :blk 14 + v;
        };
        if (dst_pos + actual > dst_end) return false;
        const from = @as(i64, @intCast(dst_pos)) + offset;
        if (from >= 0 and @as(usize, @intCast(from)) < dst.len) {
            var c: u32 = 0;
            const copy_from: usize = @intCast(from);
            while (c < actual) : (c += 1) dst[dst_pos + c] = dst[copy_from + c];
        }
        dst_pos += actual;
    }
    if (offs_i != offs.len or len_i != lens.len) return false;
    const rest_lit = lit.len - lit_i;
    if (dst_pos + rest_lit > dst_end) return false;
    var c: usize = 0;
    while (c < rest_lit) : (c += 1) {
        const back = @as(i64, @intCast(dst_pos + c)) + last_offset;
        const prev: u8 = if (back >= 0 and @as(usize, @intCast(back)) < dst.len) dst[@intCast(back)] else 0;
        dst[dst_pos + c] = lit[lit_i + c] +% prev;
    }
    return true;
}

fn decodeBytes(allocator: std.mem.Allocator, src: []const u8, output_cap: usize, out: *std.ArrayList(u8)) !usize {
    @setRuntimeSafety(false);
    if (src.len < 2) return error.Malformed;
    const chunk_type: u32 = (src[0] >> 4) & 7;
    if (chunk_type == 0) {
        var sp: usize = 0;
        var src_size: usize = 0;
        if (src[0] >= 0x80) {
            src_size = ((@as(usize, src[0]) << 8) | src[1]) & 0xFFF;
            sp = 2;
        } else {
            if (src.len < 3) return error.Malformed;
            src_size = (@as(usize, src[0]) << 16) | (@as(usize, src[1]) << 8) | src[2];
            if (src_size & ~@as(usize, 0x3FFFF) != 0) return error.Malformed;
            sp = 3;
        }
        if (src_size > output_cap or src.len - sp < src_size) return error.Malformed;
        try out.resize(allocator, src_size);
        @memcpy(out.items, src[sp .. sp + src_size]);
        return sp + src_size;
    }
    var sp: usize = 0;
    var src_size: usize = 0;
    var dst_size: usize = 0;
    if (src[0] >= 0x80) {
        if (src.len < 3) return error.Malformed;
        const bits: u32 = (@as(u32, src[0]) << 16) | (@as(u32, src[1]) << 8) | src[2];
        src_size = bits & 0x3FF;
        dst_size = src_size + ((bits >> 10) & 0x3FF) + 1;
        sp = 3;
    } else {
        if (src.len < 5) return error.Malformed;
        const bits: u32 = (@as(u32, src[1]) << 24) | (@as(u32, src[2]) << 16) | (@as(u32, src[3]) << 8) | src[4];
        src_size = bits & 0x3FFFF;
        dst_size = ((((bits >> 18) | (@as(u32, src[0]) << 14)) & 0x3FFFF) + 1);
        if (src_size >= dst_size) return error.Malformed;
        sp = 5;
    }
    if (src.len - sp < src_size or dst_size > output_cap) return error.Malformed;
    try out.resize(allocator, dst_size);
    switch (chunk_type) {
        2, 4 => {
            if (!decodeBytesType12(src[sp .. sp + src_size], out.items, chunk_type >> 1)) return error.Malformed;
        },
        else => return error.UnsupportedEntropy,
    }
    return sp + src_size;
}

fn decodeBytesType12(src: []const u8, output: []u8, type_div: u32) bool {
    var prefix = code_prefix_org;
    var syms: [1280]u8 = undefined;
    @memset(&syms, 0);
    var bits = BitReader.forward(src, 0, src.len);
    return decodeHuffPayload(&bits, src, output, type_div, &prefix, &syms);
}

fn decodeHuffPayload(bits_init: *BitReader, src: []const u8, output: []u8, type_div: u32, prefix: *[12]u32, syms: *[1280]u8) bool {
    @setRuntimeSafety(false);
    _ = bits_init;
    var bits = BitReader.forward(src, 0, src.len);
    const first = bits.readBitNoRefill();
    var num_syms: i32 = 0;
    if (first == 0) {
        num_syms = huffReadCodeLengthsOld(&bits, syms, prefix);
    } else if (bits.readBitNoRefill() == 0) {
        num_syms = huffReadCodeLengthsNew(&bits, syms, prefix);
    } else {
        return false;
    }
    if (num_syms < 1) return false;
    const adj = @divTrunc(24 - bits.bit_pos, 8);
    const consumed = if (adj >= 0) bits.p -% @as(usize, @intCast(adj)) else bits.p +% @as(usize, @intCast(-adj));
    var sp: usize = consumed;
    if (num_syms == 1) {
        @memset(output, syms[0]);
        return true;
    }
    var lut = HuffLut{};
    if (!huffMakeLut(&code_prefix_org, prefix, &lut, syms)) return false;
    var rev = HuffLut{};
    reverseBitsArray2048(&lut.bits2len, &rev.bits2len);
    reverseBitsArray2048(&lut.bits2sym, &rev.bits2sym);
    if (type_div == 1) {
        if (sp + 3 > src.len) return false;
        const split_mid: usize = src[sp] | (@as(usize, src[sp + 1]) << 8);
        sp += 2;
        const ok = decodeBytesCore(src, output, 0, output.len, sp, src.len, sp + split_mid, &rev);
        return ok;
    }
    if (sp + 6 > src.len) return false;
    const half = (output.len + 1) >> 1;
    const split_mid: usize = src[sp] | (@as(usize, src[sp + 1]) << 8) | (@as(usize, src[sp + 2]) << 16);
    sp += 3;
    if (split_mid > src.len - sp) return false;
    const src_mid = sp + split_mid;
    const split_left: usize = src[sp] | (@as(usize, src[sp + 1]) << 8);
    sp += 2;
    if (src_mid - sp < split_left + 2 or src.len - src_mid < 3) return false;
    const split_right: usize = src[src_mid] | (@as(usize, src[src_mid + 1]) << 8);
    if (src.len - (src_mid + 2) < split_right + 2) return false;
    if (!decodeBytesCore(src, output, 0, half, sp, src_mid, sp + split_left, &rev)) return false;
    return decodeBytesCore(src, output, half, output.len, src_mid + 2, src.len, src_mid + 2 + split_right, &rev);
}

const HuffLut = struct {
    bits2len: [2048 + 16]u8 = @splat(0),
    bits2sym: [2048 + 16]u8 = @splat(0),
};

fn huffMakeLut(prefix_org: *const [12]u32, prefix_cur: *const [12]u32, lut: *HuffLut, syms: *[1280]u8) bool {
    var currslot: u32 = 0;
    var i: u32 = 1;
    while (i < 11) : (i += 1) {
        const start = prefix_org[i];
        const count = prefix_cur[i] - start;
        if (count != 0) {
            const stepsize: u32 = @as(u32, 1) << @intCast(11 - i);
            const num_to_set = count << @intCast(11 - i);
            if (currslot + num_to_set > 2048) return false;
            @memset(lut.bits2len[currslot..][0..num_to_set], @intCast(i));
            var p = currslot;
            var j: u32 = 0;
            while (j != count) : (j += 1) {
                @memset(lut.bits2sym[p..][0..stepsize], syms[start + j]);
                p += stepsize;
            }
            currslot += num_to_set;
        }
    }
    if (prefix_cur[11] - prefix_org[11] != 0) {
        const num_to_set = prefix_cur[11] - prefix_org[11];
        if (currslot + num_to_set > 2048) return false;
        @memset(lut.bits2len[currslot..][0..num_to_set], 11);
        @memcpy(lut.bits2sym[currslot..][0..num_to_set], syms[prefix_org[11]..][0..num_to_set]);
        currslot += num_to_set;
    }
    return currslot == 2048;
}

fn reverse11(v0: u32) u32 {
    var v = v0;
    var r: u32 = 0;
    var k: u32 = 0;
    while (k < 11) : (k += 1) {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    return r;
}

fn reverseBitsArray2048(input: []const u8, output: []u8) void {
    var i: u32 = 0;
    while (i < 2048) : (i += 1) output[i] = input[reverse11(i)];
}

fn huffReadCodeLengthsOld(bits: *BitReader, syms: *[1280]u8, code_prefix: *[12]u32) i32 {
    @setRuntimeSafety(false);
    if (bits.readBitNoRefill() != 0) {
        var sym: i32 = 0;
        var num_symbols: i32 = 0;
        var avg: i32 = 32;
        const forced: i32 = @intCast(bits.readBitsNoRefill(2));
        const shift_amt: u5 = @intCast(31 - @as(u32, @intCast(@as(u32, 20) >> @intCast(forced))));
        const thres: u32 = @as(u32, 1) << shift_amt;
        var skip = bits.readBit() != 0;
        while (true) {
            if (!skip) {
                if (bits.bits & 0xFF000000 == 0) return -1;
                sym += @as(i32, @intCast(bits.readBitsNoRefill(@intCast(2 * (clz(bits.bits) + 1))))) - 2 + 1;
                if (sym >= 256) break;
            }
            skip = false;
            bits.refill();
            if (bits.bits & 0xFF000000 == 0) return -1;
            var n: i32 = @intCast(bits.readBitsNoRefill(@intCast(2 * (clz(bits.bits) + 1))));
            n = n - 2 + 1;
            if (sym + n > 256) return -1;
            bits.refill();
            num_symbols += n;
            while (n != 0) {
                n -= 1;
                if (bits.bits < thres) return -1;
                const lz = clz(bits.bits);
                const v: i32 = @intCast(bits.readBitsNoRefill(@intCast(lz + @as(u32, @intCast(forced)) + 1)));
                const vv: i32 = v + @as(i32, @intCast((lz - 1) << @intCast(forced)));
                const codelen = (-(vv & 1) ^ (vv >> 1)) + ((avg + 2) >> 2);
                if (codelen < 1 or codelen > 11) return -1;
                avg = codelen + ((3 * avg + 2) >> 2);
                bits.refill();
                const cp = code_prefix[@intCast(codelen)];
                code_prefix[@intCast(codelen)] = cp + 1;
                syms[cp] = @intCast(sym);
                sym += 1;
            }
            if (sym == 256) break;
        }
        return if (sym == 256 and num_symbols >= 2) num_symbols else -1;
    }
    const num_symbols: i32 = @intCast(bits.readBitsNoRefill(8));
    if (num_symbols == 0) return -1;
    if (num_symbols == 1) {
        syms[0] = @intCast(bits.readBitsNoRefill(8));
    } else {
        const codelen_bits: u32 = bits.readBitsNoRefill(3);
        if (codelen_bits > 4) return -1;
        var i: i32 = 0;
        while (i < num_symbols) : (i += 1) {
            bits.refill();
            const sym: u32 = bits.readBitsNoRefill(8);
            const codelen = bits.readBitsNoRefillZero(codelen_bits) + 1;
            if (codelen > 11) return -1;
            const cp = code_prefix[codelen];
            code_prefix[codelen] = cp + 1;
            syms[cp] = @intCast(sym);
        }
    }
    return num_symbols;
}

fn huffReadCodeLengthsNew(bits: *BitReader, syms: *[1280]u8, code_prefix: *[12]u32) i32 {
    @setRuntimeSafety(false);
    const forced_bits: i32 = @intCast(bits.readBitsNoRefill(2));
    const num_symbols: i32 = @intCast(bits.readBitsNoRefill(8) + 1);
    const fluff = bits.readFluff(num_symbols);
    var code_len: [512 + 16]u8 = @splat(0);
    var br2 = BitReader2{
        .b = bits.b,
        .bit_pos = (bits.bit_pos - 24) & 7,
        .p_end = bits.bound,
        .p = blk: {
            const adj = (24 - bits.bit_pos + 7) >> 3;
            break :blk if (adj >= 0)
                bits.p -% @as(usize, @intCast(adj))
            else
                bits.p +% @as(usize, @intCast(-adj));
        },
    };
    if (!decodeGolombRiceLengths(&code_len, @intCast(num_symbols + fluff), &br2)) return -1;
    if (!decodeGolombRiceBits(&code_len, @intCast(num_symbols), forced_bits, &br2)) return -1;
    bits.bit_pos = 24;
    bits.p = br2.p;
    bits.bits = 0;
    bits.refill();
    bits.bits <<= @intCast(br2.bit_pos);
    bits.bit_pos += br2.bit_pos;

    var running_sum: u32 = 0x1e;
    var i: usize = 0;
    while (i < @as(usize, @intCast(num_symbols))) : (i += 1) {
        var v: i32 = code_len[i];
        v = -(v & 1) ^ (v >> 1);
        const cl = v + @as(i32, @intCast(running_sum >> 2)) + 1;
        if (cl < 1 or cl > 11) return -1;
        code_len[i] = @intCast(cl);
        running_sum = @intCast(@as(i32, @intCast(running_sum)) + v);
    }

    var range: [128]HuffRange = undefined;
    const ranges = huffConvertToRanges(&range, num_symbols, fluff, &code_len, @intCast(num_symbols), bits);
    if (ranges <= 0) return -1;
    var cp: usize = 0;
    var r: usize = 0;
    while (r < @as(usize, @intCast(ranges))) : (r += 1) {
        var sym = range[r].symbol;
        var nn = range[r].num;
        while (nn != 0) {
            nn -= 1;
            const clen = code_len[cp];
            cp += 1;
            const slot = code_prefix[clen];
            code_prefix[clen] = slot + 1;
            syms[slot] = @intCast(sym);
            sym += 1;
        }
    }
    return num_symbols;
}

const HuffRange = struct { symbol: i32, num: i32 };

fn huffConvertToRanges(range: *[128]HuffRange, num_symbols: i32, p: i32, symlen: []const u8, start: usize, bits: *BitReader) i32 {
    const num_ranges: i32 = p >> 1;
    var v: i32 = 0;
    var sym_idx: i32 = 0;
    var off = start;
    if (p & 1 != 0) {
        bits.refill();
        v = symlen[off];
        off += 1;
        if (v >= 8) return -1;
        const n: u32 = @intCast(v + 1);
        sym_idx = @intCast(bits.readBitsNoRefill(n) + (@as(u32, 1) << @intCast(n)) - 1);
    }
    var syms_used: i32 = 0;
    var i: i32 = 0;
    while (i < num_ranges) : (i += 1) {
        bits.refill();
        v = symlen[off];
        if (v >= 9) return -1;
        const num: i32 = @intCast(bits.readBitsNoRefillZero(@intCast(v)) + (@as(u32, 1) << @intCast(v)));
        v = symlen[off + 1];
        if (v >= 8) return -1;
        const space: i32 = @intCast(bits.readBitsNoRefill(@intCast(v + 1)) + (@as(u32, 1) << @intCast(v + 1)) - 1);
        range[@intCast(i)] = .{ .symbol = sym_idx, .num = num };
        syms_used += num;
        sym_idx += num + space;
        off += 2;
    }
    if (sym_idx >= 256 or syms_used >= num_symbols or sym_idx + num_symbols - syms_used > 256) return -1;
    range[@intCast(num_ranges)] = .{ .symbol = sym_idx, .num = num_symbols - syms_used };
    return num_ranges + 1;
}

const BitReader2 = struct { b: []const u8, p: usize, p_end: usize, bit_pos: i32 };

const rice_val = [_]u32{
    0x80000000, 0x00000007, 0x10000006, 0x00000006, 0x20000005, 0x00000105, 0x10000005, 0x00000005,
    0x30000004, 0x00000204, 0x10000104, 0x00000104, 0x20000004, 0x00010004, 0x10000004, 0x00000004,
    0x40000003, 0x00000303, 0x10000203, 0x00000203, 0x20000103, 0x00010103, 0x10000103, 0x00000103,
    0x30000003, 0x00020003, 0x10010003, 0x00010003, 0x20000003, 0x01000003, 0x10000003, 0x00000003,
    0x50000002, 0x00000402, 0x10000302, 0x00000302, 0x20000202, 0x00010202, 0x10000202, 0x00000202,
    0x30000102, 0x00020102, 0x10010102, 0x00010102, 0x20000102, 0x01000102, 0x10000102, 0x00000102,
    0x40000002, 0x00030002, 0x10020002, 0x00020002, 0x20010002, 0x01010002, 0x10010002, 0x00010002,
    0x30000002, 0x02000002, 0x11000002, 0x01000002, 0x20000002, 0x00000012, 0x10000002, 0x00000002,
    0x60000001, 0x00000501, 0x10000401, 0x00000401, 0x20000301, 0x00010301, 0x10000301, 0x00000301,
    0x30000201, 0x00020201, 0x10010201, 0x00010201, 0x20000201, 0x01000201, 0x10000201, 0x00000201,
    0x40000101, 0x00030101, 0x10020101, 0x00020101, 0x20010101, 0x01010101, 0x10010101, 0x00010101,
    0x30000101, 0x02000101, 0x11000101, 0x01000101, 0x20000101, 0x00000111, 0x10000101, 0x00000101,
    0x50000001, 0x00040001, 0x10030001, 0x00030001, 0x20020001, 0x01020001, 0x10020001, 0x00020001,
    0x30010001, 0x02010001, 0x11010001, 0x01010001, 0x20010001, 0x00010011, 0x10010001, 0x00010001,
    0x40000001, 0x03000001, 0x12000001, 0x02000001, 0x21000001, 0x01000011, 0x11000001, 0x01000001,
    0x30000001, 0x00000021, 0x10000011, 0x00000011, 0x20000001, 0x00001001, 0x10000001, 0x00000001,
    0x70000000, 0x00000600, 0x10000500, 0x00000500, 0x20000400, 0x00010400, 0x10000400, 0x00000400,
    0x30000300, 0x00020300, 0x10010300, 0x00010300, 0x20000300, 0x01000300, 0x10000300, 0x00000300,
    0x40000200, 0x00030200, 0x10020200, 0x00020200, 0x20010200, 0x01010200, 0x10010200, 0x00010200,
    0x30000200, 0x02000200, 0x11000200, 0x01000200, 0x20000200, 0x00000210, 0x10000200, 0x00000200,
    0x50000100, 0x00040100, 0x10030100, 0x00030100, 0x20020100, 0x01020100, 0x10020100, 0x00020100,
    0x30010100, 0x02010100, 0x11010100, 0x01010100, 0x20010100, 0x00010110, 0x10010100, 0x00010100,
    0x40000100, 0x03000100, 0x12000100, 0x02000100, 0x21000100, 0x01000110, 0x11000100, 0x01000100,
    0x30000100, 0x00000120, 0x10000110, 0x00000110, 0x20000100, 0x00001100, 0x10000100, 0x00000100,
    0x60000000, 0x00050000, 0x10040000, 0x00040000, 0x20030000, 0x01030000, 0x10030000, 0x00030000,
    0x30020000, 0x02020000, 0x11020000, 0x01020000, 0x20020000, 0x00020010, 0x10020000, 0x00020000,
    0x40010000, 0x03010000, 0x12010000, 0x02010000, 0x21010000, 0x01010010, 0x11010000, 0x01010000,
    0x30010000, 0x00010020, 0x10010010, 0x00010010, 0x20010000, 0x00011000, 0x10010000, 0x00010000,
    0x50000000, 0x04000000, 0x13000000, 0x03000000, 0x22000000, 0x02000010, 0x12000000, 0x02000000,
    0x31000000, 0x01000020, 0x11000010, 0x01000010, 0x21000000, 0x01001000, 0x11000000, 0x01000000,
    0x40000000, 0x00000030, 0x10000020, 0x00000020, 0x20000010, 0x00001010, 0x10000010, 0x00000010,
    0x30000000, 0x00002000, 0x10001000, 0x00001000, 0x20000000, 0x00100000, 0x10000000, 0x00000000,
};

const rice_len = [_]u8{
    0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4, 1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5, 2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5, 2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6, 3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5, 2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6, 3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6, 3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7, 4, 5, 5, 6, 5, 6, 6, 7, 5, 6, 6, 7, 6, 7, 7, 8,
};

fn atByte(b: []const u8, i: usize) u8 {
    return if (i < b.len) b[i] else 0;
}

fn readLe32(b: []const u8, off: usize) u32 {
    var r: u32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (off + i < b.len) r |= @as(u32, b[off + i]) << @intCast(8 * i);
    }
    return r;
}

fn readLe64(b: []const u8, off: usize) u64 {
    var r: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (off + i < b.len) r |= @as(u64, b[off + i]) << @intCast(8 * i);
    }
    return r;
}

fn writeLe32(b: []u8, off: usize, v: u32) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (off + i < b.len) b[off + i] = @truncate(v >> @intCast(8 * i));
    }
}

fn writeLe64(b: []u8, off: usize, v: u64) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (off + i < b.len) b[off + i] = @truncate(v >> @intCast(8 * i));
    }
}

fn decodeGolombRiceLengths(dst: []u8, size: usize, br: *BitReader2) bool {
    @setRuntimeSafety(false);
    var p = br.p;
    const p_end = br.p_end;
    var dst_pos: usize = 0;
    const dst_end = size;
    if (p >= p_end) return false;
    var count: i32 = -br.bit_pos;
    var v: u32 = @as(u32, atByte(br.b, p)) & (@as(u32, 255) >> @intCast(@as(u5, @intCast(@max(br.bit_pos, 0)))));
    p += 1;
    while (true) {
        if (v == 0) {
            count += 8;
        } else {
            const x = rice_val[v];
            const lo = @as(u32, @bitCast(count)) +% (x & 0x0F0F0F0F);
            writeLe32(dst, dst_pos, lo);
            writeLe32(dst, dst_pos + 4, (x >> 4) & 0x0F0F0F0F);
            dst_pos += rice_len[v];
            if (dst_pos >= dst_end) break;
            count = @intCast(x >> 28);
        }
        if (p >= p_end) return false;
        v = atByte(br.b, p);
        p += 1;
    }
    if (dst_pos > dst_end) {
        var nn = dst_pos - dst_end;
        while (nn != 0) {
            nn -= 1;
            v &= v - 1;
        }
    }
    var bitpos: i32 = 0;
    if (v & 1 == 0) {
        p -= 1;
        bitpos = @intCast(8 - bsf(v));
    }
    br.p = p;
    br.bit_pos = bitpos;
    return true;
}

fn decodeGolombRiceBits(dst: []u8, size: usize, bitcount: i32, br: *BitReader2) bool {
    @setRuntimeSafety(false);
    if (bitcount == 0) return true;
    var dst_pos: usize = 0;
    const dst_end = size;
    var p = br.p;
    const bitpos = br.bit_pos;
    const bits_required: usize = @as(usize, @intCast(@max(bitpos, 0))) + @as(usize, @intCast(bitcount)) * size;
    const bytes_required = (bits_required + 7) >> 3;
    if (bytes_required > br.p_end - p) return false;
    br.p = p + (bits_required >> 3);
    br.bit_pos = @intCast(bits_required & 7);
    const bak = readLe64(dst, dst_end);
    if (bitcount == 1) {
        while (dst_pos < dst_end) {
            var bits: u64 = @as(u8, @truncate(@byteSwap(readLe32(br.b, p)) >> @intCast(24 - bitpos)));
            p += 1;
            bits = (bits | (bits << 28)) & 0xF0000000F;
            bits = (bits | (bits << 14)) & 0x3000300030003;
            bits = (bits | (bits << 7)) & 0x0101010101010101;
            const cur = readLe64(dst, dst_pos);
            writeLe64(dst, dst_pos, cur *% 2 +% @byteSwap(bits));
            dst_pos += 8;
        }
    } else if (bitcount == 2) {
        while (dst_pos < dst_end) {
            var bits: u64 = @as(u16, @truncate(@byteSwap(readLe32(br.b, p)) >> @intCast(16 - bitpos)));
            p += 2;
            bits = (bits | (bits << 24)) & 0xFF000000FF;
            bits = (bits | (bits << 12)) & 0xF000F000F000F;
            bits = (bits | (bits << 6)) & 0x0303030303030303;
            const cur = readLe64(dst, dst_pos);
            writeLe64(dst, dst_pos, cur *% 4 +% @byteSwap(bits));
            dst_pos += 8;
        }
    } else {
        while (dst_pos < dst_end) {
            var bits: u64 = (@as(u64, @byteSwap(readLe32(br.b, p))) >> @intCast(8 - bitpos)) & 0xFFFFFF;
            p += 3;
            bits = (bits | (bits << 20)) & 0xFFF00000FFF;
            bits = (bits | (bits << 10)) & 0x3F003F003F003F;
            bits = (bits | (bits << 5)) & 0x0707070707070707;
            const cur = readLe64(dst, dst_pos);
            writeLe64(dst, dst_pos, cur *% 8 +% @byteSwap(bits));
            dst_pos += 8;
        }
    }
    writeLe64(dst, dst_end, bak);
    return true;
}

fn decodeBytesCore(
    src: []const u8,
    out: []u8,
    out_off: usize,
    out_end: usize,
    src_off: usize,
    src_end0: usize,
    src_mid_org: usize,
    lut: *const HuffLut,
) bool {
    @setRuntimeSafety(false);
    var src_i = src_off;
    var src_bits: u32 = 0;
    var src_bitpos: i32 = 0;
    var src_mid = src_mid_org;
    var src_mid_bits: u32 = 0;
    var src_mid_bitpos: i32 = 0;
    var src_end = src_end0;
    var src_end_bits: u32 = 0;
    var src_end_bitpos: i32 = 0;
    var dst = out_off;
    if (src_i > src_mid) return false;
    while (dst < out_end) {
        const bp: u5 = @intCast(@as(u32, @bitCast(src_bitpos)) & 31);
        if (src_mid - src_i <= 1) {
            if (src_mid - src_i == 1) src_bits |= @as(u32, src[src_i]) << bp;
        } else {
            src_bits |= (@as(u32, src[src_i]) | (@as(u32, src[src_i + 1]) << 8)) << bp;
        }
        var k: u32 = src_bits & 0x7FF;
        var n: u32 = lut.bits2len[k];
        src_bitpos -= @as(i32, @intCast(n));
        src_bits >>= @intCast(n);
        out[dst] = lut.bits2sym[k];
        dst += 1;
        src_i += @as(usize, @intCast((7 - src_bitpos) >> 3));
        src_bitpos &= 7;
        if (dst < out_end) {
            if (src_end - src_mid <= 1) {
                if (src_end - src_mid == 1) {
                    const ebp: u5 = @intCast(@as(u32, @bitCast(src_end_bitpos)) & 31);
                    const mbp: u5 = @intCast(@as(u32, @bitCast(src_mid_bitpos)) & 31);
                    src_end_bits |= @as(u32, src[src_mid]) << ebp;
                    src_mid_bits |= @as(u32, src[src_mid]) << mbp;
                }
            } else {
                const vv: u32 = src[src_end - 2] | (@as(u32, src[src_end - 1]) << 8);
                const ebp: u5 = @intCast(@as(u32, @bitCast(src_end_bitpos)) & 31);
                const mbp: u5 = @intCast(@as(u32, @bitCast(src_mid_bitpos)) & 31);
                src_end_bits |= (((vv >> 8) | (vv << 8)) & 0xFFFF) << ebp;
                src_mid_bits |= (@as(u32, src[src_mid]) | (@as(u32, src[src_mid + 1]) << 8)) << mbp;
            }
            k = src_end_bits & 0x7FF;
            n = lut.bits2len[k];
            out[dst] = lut.bits2sym[k];
            dst += 1;
            src_end_bitpos -= @as(i32, @intCast(n));
            src_end_bits >>= @intCast(n);
            src_end -%= @as(usize, @intCast((7 - src_end_bitpos) >> 3));
            src_end_bitpos &= 7;
            if (dst < out_end) {
                k = src_mid_bits & 0x7FF;
                n = lut.bits2len[k];
                out[dst] = lut.bits2sym[k];
                dst += 1;
                src_mid_bitpos -= @as(i32, @intCast(n));
                src_mid_bits >>= @intCast(n);
                src_mid += @as(usize, @intCast((7 - src_mid_bitpos) >> 3));
                src_mid_bitpos &= 7;
            }
        }
        if (src_i > src_mid or src_mid > src_end) return false;
    }
    return src_i == src_mid_org and src_end == src_mid;
}

const BitReader = struct {
    b: []const u8,
    p: usize,
    bound: usize,
    bits: u32 = 0,
    bit_pos: i32 = 24,
    bwd: bool = false,

    fn forward(b: []const u8, start: usize, end: usize) BitReader {
        var r = BitReader{ .b = b, .p = start, .bound = end, .bwd = false };
        r.refillF();
        return r;
    }

    fn backward(b: []const u8, low: usize, high: usize) BitReader {
        var r = BitReader{ .b = b, .p = high, .bound = low, .bwd = true };
        r.refillB();
        return r;
    }

    fn refill(self: *BitReader) void {
        if (self.bwd) self.refillB() else self.refillF();
    }

    fn refillF(self: *BitReader) void {
        @setRuntimeSafety(false);
        while (self.bit_pos > 0) {
            const byte: u32 = if (self.p < self.bound) self.b[self.p] else 0;
            self.bits |= byte << @intCast(@as(u5, @intCast(@max(self.bit_pos, 0))));
            self.bit_pos -= 8;
            self.p += 1;
        }
    }

    fn refillB(self: *BitReader) void {
        @setRuntimeSafety(false);
        while (self.bit_pos > 0) {
            self.p -%= 1;
            const byte: u32 = if (self.p < self.b.len and self.p >= self.bound) self.b[self.p] else 0;
            self.bits |= byte << @intCast(@as(u5, @intCast(@max(self.bit_pos, 0))));
            self.bit_pos -= 8;
        }
    }

    fn readBit(self: *BitReader) u32 {
        self.refill();
        const r = self.bits >> 31;
        self.bits <<= 1;
        self.bit_pos += 1;
        return r;
    }

    fn readBitNoRefill(self: *BitReader) u32 {
        const r = self.bits >> 31;
        self.bits <<= 1;
        self.bit_pos += 1;
        return r;
    }

    fn readBitsNoRefill(self: *BitReader, n: u32) u32 {
        const r = self.bits >> @intCast(32 - n);
        self.bits <<= @intCast(n);
        self.bit_pos += @as(i32, @intCast(n));
        return r;
    }

    fn readBitsNoRefillZero(self: *BitReader, n: u32) u32 {
        const r = self.bits >> 1 >> @intCast(31 - n);
        self.bits <<= @intCast(n);
        self.bit_pos += @as(i32, @intCast(n));
        return r;
    }

    fn readFluff(self: *BitReader, num_symbols: i32) i32 {
        if (num_symbols == 256) return 0;
        var x: i32 = 257 - num_symbols;
        if (x > num_symbols) x = num_symbols;
        x *= 2;
        const y: u32 = bsr(@intCast(x - 1)) + 1;
        const v = self.bits >> @intCast(32 - y);
        const z: u32 = (@as(u32, 1) << @intCast(y)) - @as(u32, @intCast(x));
        if ((v >> 1) >= z) {
            self.bits <<= @intCast(y);
            self.bit_pos += @as(i32, @intCast(y));
            return @intCast(v - z);
        }
        self.bits <<= @intCast(y - 1);
        self.bit_pos += @as(i32, @intCast(y - 1));
        return @intCast(v >> 1);
    }

    fn readMoreThan24(self: *BitReader, n: u32) u32 {
        var rv: u32 = 0;
        if (n <= 24) {
            rv = self.readBitsNoRefillZero(n);
        } else {
            rv = self.readBitsNoRefill(24) << @intCast(n - 24);
            self.refillF();
            rv += self.readBitsNoRefill(n - 24);
        }
        self.refillF();
        return rv;
    }

    fn readMoreThan24B(self: *BitReader, n: u32) u32 {
        var rv: u32 = 0;
        if (n <= 24) {
            rv = self.readBitsNoRefillZero(n);
        } else {
            rv = self.readBitsNoRefill(24) << @intCast(n - 24);
            self.refillB();
            rv += self.readBitsNoRefill(n - 24);
        }
        self.refillB();
        return rv;
    }

    fn readDistance(self: *BitReader, v: u8) u32 {
        var n: u32 = 0;
        var rv: u32 = 0;
        if (v < 0xF0) {
            n = (v >> 4) + 4;
            const w = rotl(self.bits | 1, n);
            self.bit_pos += @as(i32, @intCast(n));
            const m = (@as(u32, 2) << @intCast(n)) - 1;
            self.bits = w & ~m;
            rv = ((w & m) << 4) + (v & 0xF) - 248;
        } else {
            n = v - 0xF0 + 4;
            const w = rotl(self.bits | 1, n);
            self.bit_pos += @as(i32, @intCast(n));
            const m = (@as(u32, 2) << @intCast(n)) - 1;
            self.bits = w & ~m;
            rv = 8322816 + ((w & m) << 12);
            self.refillF();
            rv += self.bits >> 20;
            self.bit_pos += 12;
            self.bits <<= 12;
        }
        self.refillF();
        return rv;
    }

    fn readDistanceB(self: *BitReader, v: u8) u32 {
        var n: u32 = 0;
        var rv: u32 = 0;
        if (v < 0xF0) {
            n = (v >> 4) + 4;
            const w = rotl(self.bits | 1, n);
            self.bit_pos += @as(i32, @intCast(n));
            const m = (@as(u32, 2) << @intCast(n)) - 1;
            self.bits = w & ~m;
            rv = ((w & m) << 4) + (v & 0xF) - 248;
        } else {
            n = v - 0xF0 + 4;
            const w = rotl(self.bits | 1, n);
            self.bit_pos += @as(i32, @intCast(n));
            const m = (@as(u32, 2) << @intCast(n)) - 1;
            self.bits = w & ~m;
            rv = 8322816 + ((w & m) << 12);
            self.refillB();
            rv += self.bits >> 20;
            self.bit_pos += 12;
            self.bits <<= 12;
        }
        self.refillB();
        return rv;
    }

    fn readLength(self: *BitReader, v: *u32) bool {
        var n: u32 = 31 - bsr(self.bits);
        if (n > 12) return false;
        self.bit_pos += @as(i32, @intCast(n));
        self.bits <<= @intCast(n);
        self.refillF();
        n += 7;
        self.bit_pos += @as(i32, @intCast(n));
        v.* = (self.bits >> @intCast(32 - n)) - 64;
        self.bits <<= @intCast(n);
        self.refillF();
        return true;
    }

    fn readLengthB(self: *BitReader, v: *u32) bool {
        var n: u32 = 31 - bsr(self.bits);
        if (n > 12) return false;
        self.bit_pos += @as(i32, @intCast(n));
        self.bits <<= @intCast(n);
        self.refillB();
        n += 7;
        self.bit_pos += @as(i32, @intCast(n));
        v.* = (self.bits >> @intCast(32 - n)) - 64;
        self.bits <<= @intCast(n);
        self.refillB();
        return true;
    }
};

fn rotl(v: u32, n: u32) u32 {
    return std.math.rotl(u32, v, n);
}

fn bsr(x: u32) u32 {
    if (x == 0) return 0;
    return 31 - @clz(x);
}

fn bsf(x: u32) u32 {
    if (x == 0) return 0;
    return @ctz(x);
}

fn clz(x: u32) u32 {
    if (x == 0) return 31;
    return @clz(x);
}

test "verbatim block copies when sizes match" {
    var src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dst: [8]u8 = undefined;
    try std.testing.expectEqual(Status.success, decodeBlock(std.testing.allocator, &src, 0x02, 8, &dst));
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "type-0 entropy array expands a memcpy payload" {
    var src = [_]u8{ 0x80, 0x04, 9, 8, 7, 6 };
    var dst: [4]u8 = undefined;
    try std.testing.expectEqual(Status.success, decodeBareEntropy(std.testing.allocator, &src, &dst));
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, &dst);
}
