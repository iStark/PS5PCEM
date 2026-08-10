// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Whole-shader parsing: family dispatch and end-of-program detection.

const std = @import("std");
const isa = @import("isa.zig");
const instruction = @import("instruction.zig");
const scalar_alu = @import("scalar_alu.zig");
const scalar_memory = @import("scalar_memory.zig");
const vector_alu = @import("vector_alu.zig");
const vector_memory = @import("vector_memory.zig");

const Instruction = instruction.Instruction;
const Program = instruction.Program;
pub const Error = instruction.Error;

/// Parsing a program also accumulates instructions and branch targets, so it can
/// additionally fail on allocation.
pub const ProgramError = Error || std.mem.Allocator.Error;

/// Decodes a single instruction from its first word.
///
/// Every GFX10 family used by PS5 shaders is dispatched with its architectural
/// minimum length. Unknown opcodes inside a known family are returned as
/// `.unsupported`, which preserves synchronization and useful diagnostics.
pub fn decodeInstruction(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    const word = code[word_index];

    // Top bit clear is the compact VOP2 space; opcodes 0x3e/0x3f select
    // compact VOPC/VOP1 respectively.
    if (word & 0x8000_0000 == 0) {
        return vector_alu.decodeVop2(pc, code, word_index);
    }

    // Leading 0b10 -> the scalar families.
    if (word & 0xc000_0000 == 0x8000_0000) {
        const opcode = (word >> 23) & 0x7f;
        return switch (opcode) {
            0x7d => scalar_alu.decodeSop1(pc, code, word_index),
            0x7e => scalar_alu.decodeSopc(pc, code, word_index),
            0x7f => scalar_alu.decodeSopp(pc, code, word_index),
            else => if (opcode >= 0x60)
                scalar_alu.decodeSopk(pc, code, word_index)
            else
                scalar_alu.decodeSop2(pc, code, word_index),
        };
    }

    return switch (word >> 26) {
        0x32 => vector_alu.decodeVintrp(pc, code, word_index),
        0x33, 0x3f => vector_alu.decodeVop3p(pc, code, word_index),
        0x34, 0x35 => vector_alu.decodeVop3(pc, code, word_index),
        0x36 => vector_memory.decodeDs(pc, code, word_index),
        0x37 => vector_memory.decodeFlat(pc, code, word_index),
        0x38 => vector_memory.decodeMubuf(pc, code, word_index),
        0x3a => vector_memory.decodeMtbuf(pc, code, word_index),
        0x3c => vector_memory.decodeMimg(pc, code, word_index),
        0x3d => scalar_memory.decodeSmem(pc, code, word_index),
        0x3e => vector_memory.decodeExp(pc, code, word_index),
        else => Error.UnknownInstructionFamily,
    };
}

/// Parses a shader up to `s_endpgm` or the GFX10 `s_code_end` marker.
///
/// The program is considered finished at an `s_endpgm` that no branch in the
/// already-parsed code targets: in shaders with control flow, `s_endpgm` can
/// appear in the middle.
///
/// The caller owns the result and must call `Program.deinit`.
pub fn decodeProgram(allocator: std.mem.Allocator, code: []const u32) ProgramError!Program {
    if (code.len == 0) return Error.EmptyProgram;

    var instructions: std.ArrayList(Instruction) = .empty;
    errdefer instructions.deinit(allocator);

    var branch_targets: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer branch_targets.deinit(allocator);

    var word_index: u32 = 0;
    while (word_index < code.len) {
        const pc = word_index * 4;
        const inst = try decodeInstruction(pc, code, word_index);

        try instructions.append(allocator, inst);
        word_index += inst.word_count;

        if (inst.opcode.isBranch()) {
            try branch_targets.put(allocator, inst.branch_target, {});
        }

        if (inst.opcode.isProgramEnd()) {
            const at_end = word_index >= code.len;
            if (at_end or !branch_targets.contains(word_index * 4)) {
                return .{ .code = code, .instructions = instructions };
            }
        }
    }

    return Error.MissingEndProgram;
}

test "a two-instruction program" {
    const code = [_]u32{
        0xbe80_0301, // s_mov_b32 s0, s1
        0xbf81_0000, // s_endpgm
    };

    var program = try decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), program.instructions.items.len);
    try std.testing.expectEqual(isa.Opcode.s_mov_b32, program.instructions.items[0].opcode);
    try std.testing.expectEqual(isa.Opcode.s_endpgm, program.instructions.items[1].opcode);
    try std.testing.expectEqual(@as(u32, 4), program.instructions.items[1].pc);
}

test "s_code_end stops before embedded shader metadata" {
    const code = [_]u32{
        0xbe80_0301, // s_mov_b32 s0, s1
        0xbf9f_0000, // s_code_end
        0x0000_00d3, // metadata, not an instruction
    };
    var program = try decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), program.instructions.items.len);
    try std.testing.expectEqual(isa.Opcode.s_code_end, program.instructions.items[1].opcode);
}

test "a literal shifts the pc of the next instruction" {
    const code = [_]u32{
        0xbe80_03ff, // s_mov_b32 s0, literal
        0x0000_002a,
        0xbf81_0000, // s_endpgm
    };

    var program = try decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), program.instructions.items.len);
    try std.testing.expectEqual(@as(u32, 42), program.instructions.items[0].src0.value);
    // The second instruction must start after the literal: word 2 -> pc 8.
    try std.testing.expectEqual(@as(u32, 8), program.instructions.items[1].pc);
}

test "empty input is rejected" {
    const code = [_]u32{};
    try std.testing.expectError(Error.EmptyProgram, decodeProgram(std.testing.allocator, &code));
}

test "code without s_endpgm is rejected" {
    const code = [_]u32{0xbe80_0301}; // s_mov_b32 and nothing after it
    try std.testing.expectError(Error.MissingEndProgram, decodeProgram(std.testing.allocator, &code));
}

test "a branched-over s_endpgm does not end the parse" {
    // s_cbranch_scc0 jumps past the s_endpgm to the instruction after it, so
    // word 2 is a branch target and parsing has to continue.
    const code = [_]u32{
        0xbf84_0001, // s_cbranch_scc0 +1 -> target pc=8
        0xbf81_0000, // s_endpgm (word 2 is a branch target)
        0xbf81_0000, // s_endpgm (the real end)
    };

    var program = try decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), program.instructions.items.len);
}

test "a program may start with scalar memory" {
    const code = [_]u32{
        0xf404_0201, // s_load_dwordx2 s8:s9, s2:s3, offset
        0x0000_0010,
        0xbf81_0000,
    };

    var program = try decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), program.instructions.items.len);
    try std.testing.expectEqual(isa.Opcode.s_load_dwordx2, program.instructions.items[0].opcode);
    try std.testing.expectEqual(@as(u32, 8), program.instructions.items[1].pc);
}

test "all GFX10 major families dispatch with architectural lengths" {
    const Fixture = struct {
        words: [5]u32,
        family: isa.Family,
        count: u32,
    };
    const fixtures = [_]Fixture{
        .{ .words = .{ 0, 0, 0, 0, 0 }, .family = .vop2, .count = 1 },
        .{ .words = .{ 0xc800_0000, 0, 0, 0, 0 }, .family = .vintrp, .count = 1 },
        .{ .words = .{ 0xcc00_0000, 0, 0, 0, 0 }, .family = .vop3p, .count = 2 },
        .{ .words = .{ 0xd000_0000, 0, 0, 0, 0 }, .family = .vop3, .count = 2 },
        .{ .words = .{ 0xd800_0000, 0, 0, 0, 0 }, .family = .ds, .count = 2 },
        .{ .words = .{ 0xdc00_0000, 0, 0, 0, 0 }, .family = .flat, .count = 2 },
        .{ .words = .{ 0xe000_0000, 0, 0, 0, 0 }, .family = .mubuf, .count = 2 },
        .{ .words = .{ 0xe800_0000, 0, 0, 0, 0 }, .family = .mtbuf, .count = 2 },
        .{ .words = .{ 0xf000_0000, 0, 0, 0, 0 }, .family = .mimg, .count = 2 },
        .{ .words = .{ 0xf400_0000, 0, 0, 0, 0 }, .family = .smem, .count = 2 },
        .{ .words = .{ 0xf800_0000, 0, 0, 0, 0 }, .family = .exp, .count = 2 },
        .{ .words = .{ 0xfc00_0000, 0, 0, 0, 0 }, .family = .vop3p, .count = 2 },
    };
    for (fixtures) |fixture| {
        const inst = try decodeInstruction(0, &fixture.words, 0);
        try std.testing.expectEqual(fixture.family, inst.family);
        try std.testing.expectEqual(fixture.count, inst.word_count);
    }
}

test "unknown major family still fails instead of guessing a length" {
    const code = [_]u32{0xe400_0000};
    try std.testing.expectError(Error.UnknownInstructionFamily, decodeInstruction(0, &code, 0));
}
