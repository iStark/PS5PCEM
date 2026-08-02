// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Allocation-free decoding for AMD instructions which PS5 titles may execute
//! on x86-64 hosts that do not implement the corresponding extension.
//!
//! The decoder intentionally accepts only unambiguous register/immediate forms.
//! It runs inside the Windows vectored exception handler, so it must not read
//! unrelated guest memory, allocate, lock, or depend on host CPU features.

const std = @import("std");

pub const Kind = enum {
    monitorx,
    mwaitx,
    extrq,
    insertq,
};

pub const Instruction = struct {
    kind: Kind,
    length: u8,
    destination: u8 = 0,
    source: u8 = 0,
    field_length: u8 = 0,
    field_index: u8 = 0,
};

/// Decodes the fixed MONITORX/MWAITX encodings and the immediate SSE4a
/// EXTRQ/INSERTQ register forms. The caller guarantees that the bytes required
/// to decode the faulting instruction are readable.
pub fn decode(code: [*]const u8) ?Instruction {
    if (code[0] == 0x0f and code[1] == 0x01) {
        return switch (code[2]) {
            0xfa => .{ .kind = .monitorx, .length = 3 },
            0xfb => .{ .kind = .mwaitx, .length = 3 },
            else => null,
        };
    }

    const prefix = code[0];
    if (prefix != 0x66 and prefix != 0xf2) return null;

    var offset: u8 = 1;
    var rex: u8 = 0;
    if (code[offset] & 0xf0 == 0x40) {
        rex = code[offset];
        offset += 1;
    }
    if (code[offset] != 0x0f or code[offset + 1] != 0x78) return null;

    const modrm = code[offset + 2];
    if (modrm & 0xc0 != 0xc0) return null;
    const immediate_length = code[offset + 3];
    const immediate_index = code[offset + 4];
    const instruction_length = offset + 5;

    if (prefix == 0x66) {
        // Immediate EXTRQ uses /0; REX.R cannot extend an opcode field.
        if (modrm & 0x38 != 0 or rex & 0x04 != 0) return null;
        return .{
            .kind = .extrq,
            .length = instruction_length,
            .destination = (modrm & 0x07) | ((rex & 0x01) << 3),
            .field_length = immediate_length,
            .field_index = immediate_index,
        };
    }

    return .{
        .kind = .insertq,
        .length = instruction_length,
        .destination = ((modrm >> 3) & 0x07) | ((rex & 0x04) << 1),
        .source = (modrm & 0x07) | ((rex & 0x01) << 3),
        .field_length = immediate_length,
        .field_index = immediate_index,
    };
}

/// Returns the effective AMD bit-field length, or null for an architecturally
/// undefined length/index combination.
pub fn effectiveBitFieldLength(length: u8, index: u8) ?u7 {
    const field_length: u7 = @intCast(length & 0x3f);
    const field_index: u7 = @intCast(index & 0x3f);
    if (field_length == 0) return if (field_index == 0) 64 else null;
    if (field_index + field_length > 64) return null;
    return field_length;
}

pub fn extractBitField(value: u64, length: u8, index: u8) ?u64 {
    const field_length = effectiveBitFieldLength(length, index) orelse return null;
    const field_index: u6 = @intCast(index & 0x3f);
    if (field_length == 64) return value;
    const mask = (@as(u64, 1) << @intCast(field_length)) - 1;
    return (value >> field_index) & mask;
}

pub fn insertBitField(destination: u64, source: u64, length: u8, index: u8) ?u64 {
    const field_length = effectiveBitFieldLength(length, index) orelse return null;
    const field_index: u6 = @intCast(index & 0x3f);
    if (field_length == 64) return source;
    const mask = (@as(u64, 1) << @intCast(field_length)) - 1;
    const shifted_mask = mask << field_index;
    return (destination & ~shifted_mask) | ((source & mask) << field_index);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "decoder accepts fixed AMD wait instructions" {
    const monitorx = [_]u8{ 0x0f, 0x01, 0xfa };
    const mwaitx = [_]u8{ 0x0f, 0x01, 0xfb };
    try testing.expectEqual(Kind.monitorx, decode(&monitorx).?.kind);
    try testing.expectEqual(Kind.mwaitx, decode(&mwaitx).?.kind);
    try testing.expectEqual(@as(u8, 3), decode(&mwaitx).?.length);
}

test "decoder resolves SSE4a immediate registers and REX extensions" {
    const extrq = [_]u8{ 0x66, 0x41, 0x0f, 0x78, 0xc0, 8, 16 };
    const decoded_extract = decode(&extrq).?;
    try testing.expectEqual(Kind.extrq, decoded_extract.kind);
    try testing.expectEqual(@as(u8, 7), decoded_extract.length);
    try testing.expectEqual(@as(u8, 8), decoded_extract.destination);
    try testing.expectEqual(@as(u8, 8), decoded_extract.field_length);
    try testing.expectEqual(@as(u8, 16), decoded_extract.field_index);

    const insertq = [_]u8{ 0xf2, 0x45, 0x0f, 0x78, 0xc1, 12, 20 };
    const decoded_insert = decode(&insertq).?;
    try testing.expectEqual(Kind.insertq, decoded_insert.kind);
    try testing.expectEqual(@as(u8, 8), decoded_insert.destination);
    try testing.expectEqual(@as(u8, 9), decoded_insert.source);
}

test "decoder rejects ambiguous SSE4a forms" {
    const memory_source = [_]u8{ 0x66, 0x0f, 0x78, 0x01, 8, 8 };
    const extended_opcode = [_]u8{ 0x66, 0x44, 0x0f, 0x78, 0xc0, 8, 8 };
    const wrong_opcode = [_]u8{ 0x66, 0x0f, 0x79, 0xc0, 8, 8 };
    try testing.expect(decode(&memory_source) == null);
    try testing.expect(decode(&extended_opcode) == null);
    try testing.expect(decode(&wrong_opcode) == null);
}

test "SSE4a bit fields preserve defined AMD semantics" {
    try testing.expectEqual(
        @as(?u64, 0xcd),
        extractBitField(0x0123_4567_89ab_cdef, 8, 8),
    );
    try testing.expectEqual(
        @as(?u64, 0x0123_4567_89ab_cdef),
        extractBitField(0x0123_4567_89ab_cdef, 0, 0),
    );
    try testing.expectEqual(
        @as(?u64, 0xaaaa_bbbb_cc34_eeee),
        insertBitField(0xaaaa_bbbb_ccdd_eeee, 0x1234, 8, 16),
    );
    try testing.expectEqual(
        @as(?u64, 0x0123_4567_89ab_cdef),
        insertBitField(0, 0x0123_4567_89ab_cdef, 0, 0),
    );
    try testing.expect(extractBitField(1, 0, 1) == null);
    try testing.expect(insertBitField(1, 2, 16, 56) == null);
}
