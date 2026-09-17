// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Kraken (newLZ) decoder for PS5 header-stripped PFS blocks.
//!
//! Verbatim copy when compressed length equals uncompressed length, and
//! type-0 memcpy entropy arrays. Huffman / newLZ playback is still needed
//! for typical game payloads.

const std = @import("std");

pub const Status = enum {
    success,
    malformed,
    unsupported_entropy,
};

const chunk_max: usize = 0x20000;
const chunk0_sub_lit: u32 = 0x01;
const chunk0_new_lz: u32 = 0x02;
const chunk1_sub_lit: u32 = 0x10;
const chunk1_new_lz: u32 = 0x20;
const chunk1_restart: u32 = 0x40;

pub fn decodeBlock(payload: []const u8, flags: u32, first_chunk_comp: u32, dst: []u8) Status {
    if (dst.len == 0) return if (payload.len == 0) .success else .malformed;
    const chunk0_dst: usize = @min(dst.len, chunk_max);
    const chunk1_dst: usize = dst.len - chunk0_dst;
    const chunk0_comp: usize = if (chunk1_dst == 0) payload.len else first_chunk_comp;
    if (chunk0_comp == 0 or chunk0_comp > payload.len) return .malformed;
    const chunk1_comp: usize = payload.len - chunk0_comp;
    if (chunk1_dst == 0 and chunk1_comp != 0) return .malformed;

    var st = decodeSubChunk(payload[0..chunk0_comp], dst[0..chunk0_dst], flags & chunk0_new_lz != 0, true, if (flags & chunk0_sub_lit != 0) 0 else 1);
    if (st != .success) return st;
    if (chunk1_dst > 0) {
        st = decodeSubChunk(
            payload[chunk0_comp..][0..chunk1_comp],
            dst[chunk0_dst..],
            flags & chunk1_new_lz != 0,
            flags & chunk1_restart != 0,
            if (flags & chunk1_sub_lit != 0) 0 else 1,
        );
    }
    return st;
}

fn decodeSubChunk(src: []const u8, dst: []u8, lz_enable: bool, restart: bool, literal_mode: u32) Status {
    _ = restart;
    _ = literal_mode;
    if (src.len == dst.len) {
        @memcpy(dst, src);
        return .success;
    }
    if (!lz_enable) return decodeBareEntropy(src, dst);
    return .unsupported_entropy;
}

fn decodeBareEntropy(src: []const u8, dst: []u8) Status {
    if (src.len < 2) return .malformed;
    const chunk_type: u32 = (src[0] >> 4) & 7;
    if (chunk_type != 0) return .unsupported_entropy;
    var sp: usize = 0;
    var src_size: usize = 0;
    if (src[0] >= 0x80) {
        src_size = ((@as(usize, src[0]) << 8) | src[1]) & 0xFFF;
        sp = 2;
    } else {
        if (src.len < 3) return .malformed;
        src_size = (@as(usize, src[0]) << 16) | (@as(usize, src[1]) << 8) | src[2];
        if (src_size & ~@as(usize, 0x3FFFF) != 0) return .malformed;
        sp = 3;
    }
    if (src_size != dst.len or src.len - sp < src_size) return .malformed;
    @memcpy(dst, src[sp .. sp + src_size]);
    return .success;
}

/// Tries the flag combinations LibProsperoPkg uses for header-stripped blocks.
pub fn decodeBlockAuto(payload: []const u8, first_chunk_comp: u32, dst: []u8) Status {
    const multi = dst.len > chunk_max;
    const flags: []const u32 = if (multi)
        &.{ 0x22, 0x02, 0x12, 0x32, 0x23, 0x03, 0x13, 0x33, 0x00, 0x20 }
    else
        &.{ 0x02, 0x00, 0x03, 0x01 };
    for (flags) |flag| {
        const st = decodeBlock(payload, flag, first_chunk_comp, dst);
        if (st == .success) return .success;
        if (st == .malformed) continue;
    }
    return .unsupported_entropy;
}

test "verbatim block copies when sizes match" {
    var src = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var dst: [8]u8 = undefined;
    try std.testing.expectEqual(Status.success, decodeBlock(&src, 0x02, 8, &dst));
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "type-0 entropy array expands a memcpy payload" {
    var src = [_]u8{ 0x80, 0x04, 9, 8, 7, 6 };
    var dst: [4]u8 = undefined;
    try std.testing.expectEqual(Status.success, decodeBareEntropy(&src, &dst));
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7, 6 }, &dst);
}
