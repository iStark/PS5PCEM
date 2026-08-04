// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! RDNA2 operand decoding.

const std = @import("std");
const isa = @import("isa.zig");

const OperandKind = isa.OperandKind;

pub const DecodeError = error{
    UnsupportedScalarSource,
    UnsupportedScalarDestination,
    VectorGprOutOfRange,
};

/// A single instruction operand.
///
pub const Operand = struct {
    kind: OperandKind = .unknown,
    /// Bit pattern of the value, for constants and literals.
    value: u32 = 0,
    /// Signed interpretation of `value`.
    signed_val: i32 = 0,
    float_val: f32 = 0.0,
    /// Register index for `sgpr`/`vgpr`.
    reg: u32 = 0,

    // Per-operand vector modifiers. Keeping them beside the operand makes the
    // decoded instruction independent of the source encoding (VOP3/SDWA/DPP).
    sdwa_sel: u3 = 6,
    sdwa_dst_unused: u2 = 0,
    omod: u2 = 0,
    dpp_ctrl: u9 = 0,
    dpp_row_mask: u4 = 0xf,
    dpp_bank_mask: u4 = 0xf,
    sdwa_sext: bool = false,
    dpp_fetch_inactive: bool = false,
    dpp_bound_ctrl: bool = false,
    op_sel: bool = false,
    op_sel_hi: bool = false,
    negate: bool = false,
    negate_hi: bool = false,
    absolute: bool = false,
    clamp: bool = false,
    dpp: bool = false,

    /// Whether this operand refers to a literal stored in the following word.
    pub fn isLiteral(self: Operand) bool {
        return self.kind == .literal_constant;
    }
};

/// Values encoded as floating-point inline constants (codes 240..247).
const float_inline_constants = [_]f32{ 0.5, -0.5, 1.0, -1.0, 2.0, -2.0, 4.0, -4.0 };

/// 1/(2*pi) — the inline constant with code 248.
const inv_2pi: f32 = 0.15915494309189535;

/// Decodes a scalar instruction source field (9 bits: 0..511).
pub fn decodeScalarSource(code: u32) DecodeError!Operand {
    if (code <= 105) {
        return .{ .kind = .sgpr, .reg = code };
    }
    if (code >= 128 and code <= 192) {
        const signed: i32 = @intCast(code - 128);
        return .{
            .kind = .integer_inline_constant,
            .signed_val = signed,
            .value = @bitCast(signed),
        };
    }
    if (code >= 193 and code <= 208) {
        const signed: i32 = 192 - @as(i32, @intCast(code));
        return .{
            .kind = .integer_inline_constant,
            .signed_val = signed,
            .value = @bitCast(signed),
        };
    }
    if (code >= 240 and code <= 247) {
        const f = float_inline_constants[code - 240];
        return .{
            .kind = .float_inline_constant,
            .float_val = f,
            .value = @bitCast(f),
        };
    }
    if (code >= 256 and code <= 511) {
        return decodeVectorGpr(code - 256);
    }

    return switch (code) {
        106 => .{ .kind = .vcc_lo },
        107 => .{ .kind = .vcc_hi },
        124 => .{ .kind = .m0 },
        125 => .{ .kind = .null },
        126 => .{ .kind = .exec_lo },
        127 => .{ .kind = .exec_hi },
        239 => .{ .kind = .pops_exiting_wave_id },
        248 => .{
            .kind = .float_inline_constant,
            .float_val = inv_2pi,
            .value = @bitCast(inv_2pi),
        },
        251 => .{ .kind = .vcc_z },
        252 => .{ .kind = .exec_z },
        253 => .{ .kind = .scc },
        255 => .{ .kind = .literal_constant },
        else => DecodeError.UnsupportedScalarSource,
    };
}

/// Decodes a scalar instruction destination field (7 bits).
///
/// A destination cannot be a constant, so the accepted set is narrower than for
/// a source.
pub fn decodeScalarDestination(code: u32) DecodeError!Operand {
    if (code <= 105) {
        return .{ .kind = .sgpr, .reg = code };
    }
    return switch (code) {
        106 => .{ .kind = .vcc_lo },
        107 => .{ .kind = .vcc_hi },
        124 => .{ .kind = .m0 },
        125 => .{ .kind = .null },
        126 => .{ .kind = .exec_lo },
        127 => .{ .kind = .exec_hi },
        else => DecodeError.UnsupportedScalarDestination,
    };
}

pub fn decodeVectorGpr(reg: u32) DecodeError!Operand {
    if (reg > 255) return DecodeError.VectorGprOutOfRange;
    return .{ .kind = .vgpr, .reg = reg };
}

/// Substitutes a fetched literal into the operand, if it refers to one.
pub fn applyLiteral(operand: *Operand, literal: u32) void {
    if (operand.kind == .literal_constant) {
        operand.value = literal;
        operand.signed_val = @bitCast(literal);
    }
}

test "sgpr and vgpr" {
    try std.testing.expectEqual(OperandKind.sgpr, (try decodeScalarSource(0)).kind);
    try std.testing.expectEqual(@as(u32, 105), (try decodeScalarSource(105)).reg);

    const v = try decodeScalarSource(256 + 7);
    try std.testing.expectEqual(OperandKind.vgpr, v.kind);
    try std.testing.expectEqual(@as(u32, 7), v.reg);
}

test "integer inline constants" {
    // 128..192 -> 0..64
    const zero = try decodeScalarSource(128);
    try std.testing.expectEqual(@as(i32, 0), zero.signed_val);
    const sixty_four = try decodeScalarSource(192);
    try std.testing.expectEqual(@as(i32, 64), sixty_four.signed_val);

    // 193..208 -> -1..-16
    const minus_one = try decodeScalarSource(193);
    try std.testing.expectEqual(@as(i32, -1), minus_one.signed_val);
    const minus_sixteen = try decodeScalarSource(208);
    try std.testing.expectEqual(@as(i32, -16), minus_sixteen.signed_val);
    // Negative values must keep a correct bit pattern.
    try std.testing.expectEqual(@as(u32, 0xffff_fff0), minus_sixteen.value);
}

test "floating-point constants" {
    const half = try decodeScalarSource(240);
    try std.testing.expectEqual(OperandKind.float_inline_constant, half.kind);
    try std.testing.expectEqual(@as(f32, 0.5), half.float_val);

    const minus_four = try decodeScalarSource(247);
    try std.testing.expectEqual(@as(f32, -4.0), minus_four.float_val);

    const recip = try decodeScalarSource(248);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15915494), recip.float_val, 1e-7);
}

test "special registers" {
    try std.testing.expectEqual(OperandKind.vcc_lo, (try decodeScalarSource(106)).kind);
    try std.testing.expectEqual(OperandKind.exec_hi, (try decodeScalarSource(127)).kind);
    try std.testing.expectEqual(OperandKind.scc, (try decodeScalarSource(253)).kind);
    try std.testing.expectEqual(OperandKind.literal_constant, (try decodeScalarSource(255)).kind);
}

test "invalid codes are rejected" {
    try std.testing.expectError(DecodeError.UnsupportedScalarSource, decodeScalarSource(110));
    try std.testing.expectError(DecodeError.UnsupportedScalarSource, decodeScalarSource(254));
    // A destination cannot be a constant.
    try std.testing.expectError(DecodeError.UnsupportedScalarDestination, decodeScalarDestination(128));
    try std.testing.expectError(DecodeError.UnsupportedScalarDestination, decodeScalarDestination(255));
}

test "literal substitution" {
    var op = try decodeScalarSource(255);
    applyLiteral(&op, 0xdead_beef);
    try std.testing.expectEqual(@as(u32, 0xdead_beef), op.value);

    // An operand that does not refer to a literal must be left alone.
    var sgpr = try decodeScalarSource(3);
    applyLiteral(&sgpr, 0xdead_beef);
    try std.testing.expectEqual(@as(u32, 0), sgpr.value);
}
