// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The decoded instruction and the operations that work on it.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");

const Operand = operand.Operand;

/// How many source words are retained for diagnostics.
pub const max_raw_words = 5;

pub const Error = operand.DecodeError || error{
    MissingLiteralConstant,
    UnknownInstructionFamily,
    EmptyProgram,
    MissingEndProgram,
};

/// The populated sources of an instruction.
///
/// Values are stored inline so that at most four operands never involve the
/// allocator. `slice()` stays valid for as long as the `Sources` value itself.
pub const Sources = struct {
    buf: [4]Operand,
    len: usize,

    pub fn slice(self: *const Sources) []const Operand {
        return self.buf[0..self.len];
    }
};

pub const Instruction = struct {
    /// Byte offset of the instruction from the start of the shader.
    pc: u32 = 0,
    /// First encoding word.
    word: u32 = 0,
    /// Instruction length in 32-bit words, including any literal.
    word_count: u32 = 1,
    raw: [max_raw_words]u32 = [_]u32{0} ** max_raw_words,
    raw_count: u32 = 1,

    family: isa.Family = .unknown,
    /// Opcode as encoded by the family, before mapping to `opcode`.
    opcode_id: u32 = 0,
    opcode: isa.Opcode = .unknown,

    dst: Operand = .{},
    src0: Operand = .{},
    src1: Operand = .{},
    src2: Operand = .{},
    src3: Operand = .{},
    /// How many of `src0..src3` are populated.
    src_count: u32 = 0,

    branch_offset: i32 = 0,
    branch_target: u32 = 0,

    unsupported_reason: []const u8 = "",

    /// Whether any source refers to a literal in the following word.
    pub fn hasLiteral(self: Instruction) bool {
        return self.src0.isLiteral() or self.src1.isLiteral() or
            self.src2.isLiteral() or self.src3.isLiteral();
    }

    /// Sources in encoding order — convenient for iteration in tests and printing.
    ///
    /// Values are copied: the field layout of a plain (non-`extern`) struct is
    /// unspecified in Zig, so slicing from `&self.src0` is not allowed.
    pub fn sources(self: Instruction) Sources {
        return .{
            .buf = .{ self.src0, self.src1, self.src2, self.src3 },
            .len = @min(self.src_count, 4),
        };
    }

    /// Retains the instruction's source words for diagnostic output.
    pub fn setRawWords(self: *Instruction, code: []const u32, word_index: u32, word_count: u32) void {
        self.word_count = word_count;
        self.raw_count = @min(word_count, max_raw_words);
        for (0..self.raw_count) |i| {
            self.raw[i] = code[word_index + i];
        }
    }

    /// Marks the instruction as belonging to a family but not implemented.
    /// Decoding continues: an unknown opcode must not abort the parse of the
    /// whole shader.
    pub fn setUnsupported(self: *Instruction, family: isa.Family, opcode_id: u32, reason: []const u8) void {
        self.opcode = .unsupported;
        self.family = family;
        self.opcode_id = opcode_id;
        self.unsupported_reason = reason;
    }

    /// Fetches the literal from the stream if the instruction refers to one, and
    /// grows the instruction length accordingly.
    pub fn readLiteralOperands(self: *Instruction, code: []const u32, word_index: u32) Error!void {
        if (!self.hasLiteral()) return;

        // The literal sits immediately after the instruction body.
        const literal_index = word_index + self.word_count;
        if (literal_index >= code.len) return Error.MissingLiteralConstant;

        const literal = code[literal_index];
        operand.applyLiteral(&self.src0, literal);
        operand.applyLiteral(&self.src1, literal);
        operand.applyLiteral(&self.src2, literal);
        operand.applyLiteral(&self.src3, literal);
        self.setRawWords(code, word_index, self.word_count + 1);
    }
};

/// A fully parsed shader.
pub const Program = struct {
    code: []const u32,
    instructions: std.ArrayList(Instruction),

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
    }
};

test "sources yields exactly src_count operands" {
    var inst = Instruction{};
    inst.src0 = .{ .kind = .sgpr, .reg = 1 };
    inst.src1 = .{ .kind = .sgpr, .reg = 2 };
    inst.src_count = 2;

    const srcs = inst.sources();
    try std.testing.expectEqual(@as(usize, 2), srcs.slice().len);
    try std.testing.expectEqual(@as(u32, 1), srcs.slice()[0].reg);
    try std.testing.expectEqual(@as(u32, 2), srcs.slice()[1].reg);
}

test "reading a literal grows the instruction length" {
    const code = [_]u32{ 0x0000_0000, 0xcafe_babe };
    var inst = Instruction{};
    inst.src0 = .{ .kind = .literal_constant };
    inst.src_count = 1;

    try inst.readLiteralOperands(&code, 0);
    try std.testing.expectEqual(@as(u32, 2), inst.word_count);
    try std.testing.expectEqual(@as(u32, 0xcafe_babe), inst.src0.value);
    try std.testing.expectEqual(@as(u32, 2), inst.raw_count);
}

test "a stream that ends on a literal is an error" {
    const code = [_]u32{0x0000_0000};
    var inst = Instruction{};
    inst.src0 = .{ .kind = .literal_constant };
    inst.src_count = 1;

    try std.testing.expectError(Error.MissingLiteralConstant, inst.readLiteralOperands(&code, 0));
}
