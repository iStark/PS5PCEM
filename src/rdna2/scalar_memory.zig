// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! GFX10 scalar-memory (SMEM) decoding.

const std = @import("std");
const isa = @import("isa.zig");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");

const Instruction = instruction.Instruction;
const Error = instruction.Error;

const Info = struct {
    opcode: isa.Opcode,
    words: u8,
};

fn info(opcode_id: u32) ?Info {
    return switch (opcode_id) {
        0x00 => .{ .opcode = .s_load_dword, .words = 1 },
        0x01 => .{ .opcode = .s_load_dwordx2, .words = 2 },
        0x02 => .{ .opcode = .s_load_dwordx4, .words = 4 },
        0x03 => .{ .opcode = .s_load_dwordx8, .words = 8 },
        0x04 => .{ .opcode = .s_load_dwordx16, .words = 16 },
        0x08 => .{ .opcode = .s_buffer_load_dword, .words = 1 },
        0x09 => .{ .opcode = .s_buffer_load_dwordx2, .words = 2 },
        0x0a => .{ .opcode = .s_buffer_load_dwordx4, .words = 4 },
        0x0b => .{ .opcode = .s_buffer_load_dwordx8, .words = 8 },
        0x0c => .{ .opcode = .s_buffer_load_dwordx16, .words = 16 },
        else => null,
    };
}

pub fn decodeSmem(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    if (@as(usize, word_index) + 1 >= code.len) return Error.TruncatedInstruction;
    const word0 = code[word_index];
    const word1 = code[word_index + 1];
    const opcode_id = (word0 >> 18) & 0xff;
    const sdst = (word0 >> 6) & 0x7f;
    const sbase = (word0 & 0x3f) * 2;
    const soffset = (word1 >> 25) & 0x7f;
    const raw_offset = word1 & 0x1f_ffff;
    const signed_offset: i32 = if (raw_offset & 0x10_0000 != 0)
        @as(i32, @intCast(raw_offset)) - 0x20_0000
    else
        @intCast(raw_offset);

    var inst = Instruction{
        .pc = pc,
        .word = word0,
        .family = .smem,
        .opcode_id = opcode_id,
        .dst = try operand.decodeScalarDestination(sdst),
        .src0 = try operand.decodeScalarSource(sbase),
        .src1 = try operand.decodeScalarSource(soffset),
        .src_count = 2,
        .memory_offset = signed_offset,
        .globally_coherent = word0 & (1 << 16) != 0,
    };
    inst.setRawWords(code, word_index, 2);
    if (info(opcode_id)) |decoded| {
        inst.opcode = decoded.opcode;
        inst.data_words = decoded.words;
    } else {
        inst.setUnsupported(.smem, opcode_id, "SMEM opcode is not implemented");
    }
    return inst;
}

test "decodes GFX10 scalar loads" {
    // opcode=2, sdst=20, sbase=3 -> s6, soffset=s4, offset=-16, glc=1.
    const code = [_]u32{
        0xf400_0000 | (2 << 18) | (1 << 16) | (20 << 6) | 3,
        (4 << 25) | 0x1f_fff0,
    };
    const inst = try decodeSmem(0x40, &code, 0);
    try std.testing.expectEqual(isa.Family.smem, inst.family);
    try std.testing.expectEqual(isa.Opcode.s_load_dwordx4, inst.opcode);
    try std.testing.expectEqual(@as(u32, 20), inst.dst.reg);
    try std.testing.expectEqual(@as(u32, 6), inst.src0.reg);
    try std.testing.expectEqual(@as(u32, 4), inst.src1.reg);
    try std.testing.expectEqual(@as(i32, -16), inst.memory_offset);
    try std.testing.expectEqual(@as(u8, 4), inst.data_words);
    try std.testing.expect(inst.globally_coherent);
    try std.testing.expectEqual(@as(u32, 2), inst.word_count);
}

test "unsupported SMEM opcodes stay synchronized" {
    const code = [_]u32{ 0xf400_0000 | (0x7f << 18), 0 };
    const inst = try decodeSmem(0, &code, 0);
    try std.testing.expectEqual(isa.Opcode.unsupported, inst.opcode);
    try std.testing.expectEqual(isa.OperandKind.sgpr, inst.src1.kind);
    try std.testing.expectEqual(@as(u32, 2), inst.word_count);
}

test "truncated SMEM is rejected" {
    const code = [_]u32{0xf400_0000};
    try std.testing.expectError(Error.TruncatedInstruction, decodeSmem(0, &code, 0));
}
