// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Deterministic SPIR-V 1.5 writer for the first executable RDNA2 ALU subset.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
const instruction = @import("instruction.zig");

pub const Stage = enum(u32) {
    vertex = 0,
    fragment = 4,
    compute = 5,
};

pub const Options = struct {
    stage: Stage,
    local_size: [3]u32 = .{ 1, 1, 1 },
};

pub const Error = std.mem.Allocator.Error || error{
    UnsupportedOpcode,
    UnsupportedControlFlow,
    UnsupportedDestination,
    UndefinedRegister,
};

pub const Module = struct {
    words: []u32,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
        self.* = undefined;
    }
};

const ValueType = enum { bits32, float32 };
const Value = struct { id: u32 = 0, value_type: ValueType = .bits32 };
const Constant = struct { value_type: ValueType, bits: u32, id: u32 };

const Builder = struct {
    allocator: std.mem.Allocator,
    declarations: std.ArrayList(u32) = .empty,
    body: std.ArrayList(u32) = .empty,
    constants: std.ArrayList(Constant) = .empty,
    registers: [384]Value = [_]Value{.{}} ** 384,
    next_id: u32 = 1,
    void_type: u32,
    function_type: u32,
    bits_type: u32,
    float_type: u32,
    main_function: u32,
    label: u32,

    fn init(allocator: std.mem.Allocator) Error!Builder {
        var self = Builder{
            .allocator = allocator,
            .void_type = 0,
            .function_type = 0,
            .bits_type = 0,
            .float_type = 0,
            .main_function = 0,
            .label = 0,
        };
        errdefer self.deinit();
        self.void_type = self.id();
        self.function_type = self.id();
        self.bits_type = self.id();
        self.float_type = self.id();
        self.main_function = self.id();
        self.label = self.id();
        try self.emit(&self.declarations, 19, &.{self.void_type}); // OpTypeVoid
        try self.emit(&self.declarations, 33, &.{ self.function_type, self.void_type }); // OpTypeFunction
        try self.emit(&self.declarations, 21, &.{ self.bits_type, 32, 0 }); // OpTypeInt
        try self.emit(&self.declarations, 22, &.{ self.float_type, 32 }); // OpTypeFloat
        return self;
    }

    fn deinit(self: *Builder) void {
        self.declarations.deinit(self.allocator);
        self.body.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }

    fn id(self: *Builder) u32 {
        const result = self.next_id;
        self.next_id += 1;
        return result;
    }

    fn emit(self: *Builder, list: *std.ArrayList(u32), opcode: u16, args: []const u32) Error!void {
        try list.append(self.allocator, (@as(u32, @intCast(args.len + 1)) << 16) | opcode);
        try list.appendSlice(self.allocator, args);
    }

    fn typeId(self: *const Builder, value_type: ValueType) u32 {
        return switch (value_type) {
            .bits32 => self.bits_type,
            .float32 => self.float_type,
        };
    }

    fn constant(self: *Builder, value_type: ValueType, bits: u32) Error!u32 {
        for (self.constants.items) |entry| {
            if (entry.value_type == value_type and entry.bits == bits) return entry.id;
        }
        const result = self.id();
        try self.emit(&self.declarations, 43, &.{ self.typeId(value_type), result, bits }); // OpConstant
        try self.constants.append(self.allocator, .{ .value_type = value_type, .bits = bits, .id = result });
        return result;
    }

    fn registerIndex(op: operand.Operand) ?usize {
        return switch (op.kind) {
            .sgpr => if (op.reg < 128) @intCast(op.reg) else null,
            .vgpr => if (op.reg < 256) @intCast(128 + op.reg) else null,
            else => null,
        };
    }

    fn source(self: *Builder, op: operand.Operand, expected: ValueType) Error!u32 {
        switch (op.kind) {
            .integer_inline_constant, .literal_constant => return self.constant(expected, op.value),
            .float_inline_constant => return self.constant(expected, op.value),
            .null => return self.constant(expected, 0),
            .sgpr, .vgpr => {
                const index = registerIndex(op) orelse return Error.UndefinedRegister;
                const current = self.registers[index];
                if (current.id == 0) return Error.UndefinedRegister;
                if (current.value_type == expected) return current.id;
                const converted = self.id();
                try self.emit(&self.body, 124, &.{ self.typeId(expected), converted, current.id }); // OpBitcast
                return converted;
            },
            else => return Error.UndefinedRegister,
        }
    }

    fn destination(self: *Builder, op: operand.Operand, value: Value) Error!void {
        const index = registerIndex(op) orelse return Error.UnsupportedDestination;
        self.registers[index] = value;
    }

    fn unary(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType) Error!void {
        const source_id = try self.source(inst.src0, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(value_type), result, source_id });
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
    }

    fn binary(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType, reverse: bool) Error!void {
        const a = try self.source(if (reverse) inst.src1 else inst.src0, value_type);
        const b = try self.source(if (reverse) inst.src0 else inst.src1, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(value_type), result, a, b });
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
    }

    fn lower(self: *Builder, inst: instruction.Instruction) Error!void {
        if (inst.dst.clamp or inst.dst.omod != 0 or inst.src0.absolute or inst.src0.negate or
            inst.src1.absolute or inst.src1.negate) return Error.UnsupportedOpcode;
        switch (inst.opcode) {
            .s_nop, .s_waitcnt, .s_barrier, .v_nop, .s_endpgm => {},
            .s_branch, .s_cbranch_scc0, .s_cbranch_scc1, .s_cbranch_vccz, .s_cbranch_vccnz, .s_cbranch_execz, .s_cbranch_execnz => return Error.UnsupportedControlFlow,
            .s_mov_b32, .v_mov_b32 => try self.unary(inst, 83, .bits32), // OpCopyObject
            .s_add_u32, .s_add_i32, .v_add_nc_u32 => try self.binary(inst, 128, .bits32, false), // OpIAdd
            .s_sub_u32, .s_sub_i32, .v_sub_nc_u32 => try self.binary(inst, 130, .bits32, false), // OpISub
            .v_subrev_nc_u32 => try self.binary(inst, 130, .bits32, true),
            .v_add_f32 => try self.binary(inst, 129, .float32, false), // OpFAdd
            .v_sub_f32 => try self.binary(inst, 131, .float32, false), // OpFSub
            .v_subrev_f32 => try self.binary(inst, 131, .float32, true),
            .v_mul_f32 => try self.binary(inst, 133, .float32, false), // OpFMul
            .s_and_b32, .v_and_b32 => try self.binary(inst, 199, .bits32, false),
            .s_or_b32, .v_or_b32 => try self.binary(inst, 197, .bits32, false),
            .s_xor_b32, .v_xor_b32 => try self.binary(inst, 198, .bits32, false),
            else => return Error.UnsupportedOpcode,
        }
    }
};

fn appendInstruction(allocator: std.mem.Allocator, words: *std.ArrayList(u32), opcode: u16, args: []const u32) Error!void {
    try words.append(allocator, (@as(u32, @intCast(args.len + 1)) << 16) | opcode);
    try words.appendSlice(allocator, args);
}

/// Translates the currently executable straight-line ALU subset. The writer
/// fails explicitly for operations whose semantics are not implemented; it
/// never emits a placeholder module for an unsupported guest shader.
pub fn translate(allocator: std.mem.Allocator, program: *const instruction.Program, options: Options) Error!Module {
    var builder = try Builder.init(allocator);
    defer builder.deinit();
    for (program.instructions.items) |inst| try builder.lower(inst);

    var words: std.ArrayList(u32) = .empty;
    errdefer words.deinit(allocator);
    try words.appendSlice(allocator, &.{
        0x0723_0203, // Magic
        0x0001_0500, // SPIR-V 1.5
        0x0050_4300, // PS5PC generator namespace
        builder.next_id,
        0,
    });
    try appendInstruction(allocator, &words, 17, &.{1}); // OpCapability Shader
    try appendInstruction(allocator, &words, 14, &.{ 0, 1 }); // Logical, GLSL450
    try appendInstruction(allocator, &words, 15, &.{ @intFromEnum(options.stage), builder.main_function, 0x6e69_616d, 0 });
    switch (options.stage) {
        .fragment => try appendInstruction(allocator, &words, 16, &.{ builder.main_function, 7 }), // OriginUpperLeft
        .compute => try appendInstruction(allocator, &words, 16, &.{ builder.main_function, 17, options.local_size[0], options.local_size[1], options.local_size[2] }),
        .vertex => {},
    }
    try words.appendSlice(allocator, builder.declarations.items);
    try appendInstruction(allocator, &words, 54, &.{ builder.void_type, builder.main_function, 0, builder.function_type });
    try appendInstruction(allocator, &words, 248, &.{builder.label});
    try words.appendSlice(allocator, builder.body.items);
    try appendInstruction(allocator, &words, 253, &.{}); // OpReturn
    try appendInstruction(allocator, &words, 56, &.{}); // OpFunctionEnd
    return .{ .words = try words.toOwnedSlice(allocator) };
}

fn containsOpcode(words: []const u32, wanted: u16) bool {
    var index: usize = 5;
    while (index < words.len) {
        const first = words[index];
        if (@as(u16, @truncate(first)) == wanted) return true;
        const count = first >> 16;
        if (count == 0) return false;
        index += count;
    }
    return false;
}

test "straight-line vector ALU translates to a SPIR-V function" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255, // v_mov_b32 v0, literal
        0x3f80_0000,
        (@as(u32, 3) << 25) | (@as(u32, 1) << 17) | 256, // v_add_f32 v1, v0, v0
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute, .local_size = .{ 8, 1, 1 } });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0x0723_0203), module.words[0]);
    try std.testing.expectEqual(@as(u32, 0x0001_0500), module.words[1]);
    try std.testing.expect(containsOpcode(module.words, 129)); // OpFAdd
    try std.testing.expect(containsOpcode(module.words, 253)); // OpReturn
}

test "unsupported shader semantics never produce placeholder SPIR-V" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{ 0xf404_0201, 0, 0xbf81_0000 };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectError(Error.UnsupportedOpcode, translate(std.testing.allocator, &program, .{ .stage = .compute }));
}
