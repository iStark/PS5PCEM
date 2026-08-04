// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Deterministic SPIR-V 1.5 writer for the first executable RDNA2 ALU subset.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
const instruction = @import("instruction.zig");
const control_flow = @import("control_flow.zig");

pub const Stage = enum(u32) {
    vertex = 0,
    fragment = 4,
    compute = 5,
};

pub const Options = struct {
    stage: Stage,
    local_size: [3]u32 = .{ 1, 1, 1 },
};

pub const Error = std.mem.Allocator.Error || control_flow.Error || error{
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

const ValueType = enum { bits32, sint32, float32 };
const Value = struct { id: u32 = 0, value_type: ValueType = .bits32 };
const Constant = struct { value_type: ValueType, bits: u32, id: u32 };
const State = struct {
    registers: [384]Value = [_]Value{.{}} ** 384,
    scc: u32 = 0,
    valid: bool = false,
};

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
    signed_type: u32,
    float_type: u32,
    bool_type: u32,
    main_function: u32,
    label: u32,
    scc: u32 = 0,

    fn init(allocator: std.mem.Allocator) Error!Builder {
        var self = Builder{
            .allocator = allocator,
            .void_type = 0,
            .function_type = 0,
            .bits_type = 0,
            .signed_type = 0,
            .float_type = 0,
            .bool_type = 0,
            .main_function = 0,
            .label = 0,
        };
        errdefer self.deinit();
        self.void_type = self.id();
        self.function_type = self.id();
        self.bits_type = self.id();
        self.signed_type = self.id();
        self.float_type = self.id();
        self.bool_type = self.id();
        self.main_function = self.id();
        self.label = self.id();
        try self.emit(&self.declarations, 19, &.{self.void_type}); // OpTypeVoid
        try self.emit(&self.declarations, 33, &.{ self.function_type, self.void_type }); // OpTypeFunction
        try self.emit(&self.declarations, 21, &.{ self.bits_type, 32, 0 }); // OpTypeInt
        try self.emit(&self.declarations, 21, &.{ self.signed_type, 32, 1 }); // OpTypeInt
        try self.emit(&self.declarations, 22, &.{ self.float_type, 32 }); // OpTypeFloat
        try self.emit(&self.declarations, 20, &.{self.bool_type}); // OpTypeBool
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
            .sint32 => self.signed_type,
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

    fn convert(self: *Builder, value: Value, expected: ValueType) Error!u32 {
        if (value.value_type == expected) return value.id;
        const converted = self.id();
        try self.emit(&self.body, 124, &.{ self.typeId(expected), converted, value.id }); // OpBitcast
        return converted;
    }

    fn rawSource(self: *Builder, op: operand.Operand) Error!u32 {
        return switch (op.kind) {
            .integer_inline_constant, .literal_constant, .float_inline_constant => self.constant(.bits32, op.value),
            .null => self.constant(.bits32, 0),
            .sgpr, .vgpr => blk: {
                const index = registerIndex(op) orelse return Error.UndefinedRegister;
                const current = self.registers[index];
                if (current.id == 0) return Error.UndefinedRegister;
                break :blk try self.convert(current, .bits32);
            },
            else => Error.UndefinedRegister,
        };
    }

    fn source(self: *Builder, op: operand.Operand, expected: ValueType) Error!u32 {
        if (op.dpp) return Error.UnsupportedOpcode;
        var raw = try self.rawSource(op);
        if (op.sdwa_sel != 6) {
            const width: u32 = if (op.sdwa_sel < 4) 8 else if (op.sdwa_sel < 6) 16 else return Error.UnsupportedOpcode;
            const shift: u32 = if (op.sdwa_sel < 4)
                @as(u32, op.sdwa_sel) * 8
            else
                @as(u32, op.sdwa_sel - 4) * 16;
            if (shift != 0) {
                const shifted = self.id();
                try self.emit(&self.body, 194, &.{ self.bits_type, shifted, raw, try self.constant(.bits32, shift) });
                raw = shifted;
            }
            const masked = self.id();
            const mask = if (width == 8) @as(u32, 0xff) else 0xffff;
            try self.emit(&self.body, 199, &.{ self.bits_type, masked, raw, try self.constant(.bits32, mask) });
            raw = masked;
            if (op.sdwa_sext) {
                const left = self.id();
                const amount = 32 - width;
                try self.emit(&self.body, 196, &.{ self.bits_type, left, raw, try self.constant(.bits32, amount) });
                const signed = try self.convert(.{ .id = left, .value_type = .bits32 }, .sint32);
                const extended = self.id();
                try self.emit(&self.body, 195, &.{ self.signed_type, extended, signed, try self.constant(.sint32, amount) });
                raw = try self.convert(.{ .id = extended, .value_type = .sint32 }, .bits32);
            }
        }
        if (op.absolute or op.negate) {
            if (expected != .float32) return Error.UnsupportedOpcode;
            if (op.absolute) {
                const absolute = self.id();
                try self.emit(&self.body, 199, &.{ self.bits_type, absolute, raw, try self.constant(.bits32, 0x7fff_ffff) });
                raw = absolute;
            }
            if (op.negate) {
                const negated = self.id();
                try self.emit(&self.body, 198, &.{ self.bits_type, negated, raw, try self.constant(.bits32, 0x8000_0000) });
                raw = negated;
            }
        }
        return self.convert(.{ .id = raw, .value_type = .bits32 }, expected);
    }

    fn destination(self: *Builder, op: operand.Operand, value: Value) Error!void {
        if (op.sdwa_sel != 6 or op.sdwa_dst_unused != 0) return Error.UnsupportedDestination;
        const index = registerIndex(op) orelse return Error.UnsupportedDestination;
        self.registers[index] = .{
            .id = try self.convert(value, .bits32),
            .value_type = .bits32,
        };
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

    fn comparison(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType) Error!void {
        const a = try self.source(inst.src0, value_type);
        const b = try self.source(inst.src1, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.bool_type, result, a, b });
        self.scc = result;
    }

    fn snapshot(self: *const Builder) State {
        return .{ .registers = self.registers, .scc = self.scc, .valid = true };
    }

    fn restore(self: *Builder, state: State) void {
        self.registers = state.registers;
        self.scc = state.scc;
    }

    fn lower(self: *Builder, inst: instruction.Instruction) Error!void {
        if (inst.dst.clamp or inst.dst.omod != 0) return Error.UnsupportedOpcode;
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
            .s_cmp_eq_i32, .s_cmp_eq_u32 => try self.comparison(inst, 170, .bits32), // OpIEqual
            .s_cmp_lg_i32, .s_cmp_lg_u32 => try self.comparison(inst, 171, .bits32), // OpINotEqual
            .s_cmp_gt_i32 => try self.comparison(inst, 173, .sint32),
            .s_cmp_ge_i32 => try self.comparison(inst, 175, .sint32),
            .s_cmp_lt_i32 => try self.comparison(inst, 177, .sint32),
            .s_cmp_le_i32 => try self.comparison(inst, 179, .sint32),
            .s_cmp_gt_u32 => try self.comparison(inst, 172, .bits32),
            .s_cmp_ge_u32 => try self.comparison(inst, 174, .bits32),
            .s_cmp_lt_u32 => try self.comparison(inst, 176, .bits32),
            .s_cmp_le_u32 => try self.comparison(inst, 178, .bits32),
            else => return Error.UnsupportedOpcode,
        }
    }
};

fn appendInstruction(allocator: std.mem.Allocator, words: *std.ArrayList(u32), opcode: u16, args: []const u32) Error!void {
    try words.append(allocator, (@as(u32, @intCast(args.len + 1)) << 16) | opcode);
    try words.appendSlice(allocator, args);
}

fn emitPhi(
    builder: *Builder,
    value_type: u32,
    values: []const Value,
    parents: []const u32,
) Error!u32 {
    std.debug.assert(values.len == parents.len and values.len >= 2);
    var args: std.ArrayList(u32) = .empty;
    defer args.deinit(builder.allocator);
    const result = builder.id();
    try args.append(builder.allocator, value_type);
    try args.append(builder.allocator, result);
    for (values, parents) |value, parent| {
        try args.append(builder.allocator, value.id);
        try args.append(builder.allocator, parent);
    }
    try builder.emit(&builder.body, 245, args.items); // OpPhi
    return result;
}

fn mergeState(
    builder: *Builder,
    graph: *const control_flow.Graph,
    states: []const State,
    labels: []const u32,
    block: u32,
) Error!State {
    if (block == 0) return .{ .valid = true };
    var predecessors: std.ArrayList(u32) = .empty;
    defer predecessors.deinit(builder.allocator);
    for (graph.edges.items) |edge| {
        if (edge.to != block) continue;
        if (edge.from >= block or !states[edge.from].valid) return Error.UnsupportedControlFlow;
        try predecessors.append(builder.allocator, edge.from);
    }
    if (predecessors.items.len == 0) return Error.UnsupportedControlFlow;
    if (predecessors.items.len == 1) return states[predecessors.items[0]];

    var merged = State{ .valid = true };
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(builder.allocator);
    var parents: std.ArrayList(u32) = .empty;
    defer parents.deinit(builder.allocator);

    for (0..merged.registers.len) |reg| {
        values.clearRetainingCapacity();
        parents.clearRetainingCapacity();
        var missing = false;
        var differs = false;
        var first = Value{};
        for (predecessors.items, 0..) |pred, index| {
            const value = states[pred].registers[reg];
            if (value.id == 0) missing = true;
            if (index == 0) first = value else if (value.id != first.id) differs = true;
            try values.append(builder.allocator, value);
            try parents.append(builder.allocator, labels[pred]);
        }
        if (missing) continue;
        merged.registers[reg] = if (!differs)
            first
        else
            .{ .id = try emitPhi(builder, builder.bits_type, values.items, parents.items), .value_type = .bits32 };
    }

    values.clearRetainingCapacity();
    parents.clearRetainingCapacity();
    var missing_scc = false;
    var different_scc = false;
    var first_scc: u32 = 0;
    for (predecessors.items, 0..) |pred, index| {
        const id = states[pred].scc;
        if (id == 0) missing_scc = true;
        if (index == 0) first_scc = id else if (id != first_scc) different_scc = true;
        try values.append(builder.allocator, .{ .id = id, .value_type = .bits32 });
        try parents.append(builder.allocator, labels[pred]);
    }
    if (!missing_scc) {
        merged.scc = if (!different_scc)
            first_scc
        else
            try emitPhi(builder, builder.bool_type, values.items, parents.items);
    }
    return merged;
}

fn translateStructured(builder: *Builder, program: *const instruction.Program, graph: *const control_flow.Graph) Error!void {
    if (graph.back_edge_count != 0) return Error.UnsupportedControlFlow;
    const labels = try builder.allocator.alloc(u32, graph.blocks.items.len);
    defer builder.allocator.free(labels);
    labels[0] = builder.label;
    for (labels[1..]) |*label| label.* = builder.id();
    const states = try builder.allocator.alloc(State, graph.blocks.items.len);
    defer builder.allocator.free(states);
    @memset(states, State{});

    for (graph.blocks.items) |block| {
        try builder.emit(&builder.body, 248, &.{labels[block.index]}); // OpLabel
        const incoming = try mergeState(builder, graph, states, labels, block.index);
        builder.restore(incoming);

        const first: usize = block.first_instruction;
        const end: usize = first + block.instruction_count;
        const last = program.instructions.items[end - 1];
        for (program.instructions.items[first..end]) |inst| {
            if (inst.opcode.isBranch() or inst.opcode == .s_endpgm or inst.opcode == .s_setpc_b64) continue;
            try builder.lower(inst);
        }
        states[block.index] = builder.snapshot();

        if (last.opcode == .s_endpgm) {
            try builder.emit(&builder.body, 253, &.{}); // OpReturn
        } else if (last.opcode == .s_branch) {
            const target = graph.blockForPc(last.branch_target) orelse return Error.UnsupportedControlFlow;
            try builder.emit(&builder.body, 249, &.{labels[target]}); // OpBranch
        } else if (last.opcode.isBranch()) {
            const selection = graph.selectionForHeader(block.index) orelse return Error.UnsupportedControlFlow;
            if (selection.condition != .scc or builder.scc == 0) return Error.UnsupportedControlFlow;
            var condition = builder.scc;
            if (!selection.branch_when) {
                const inverted = builder.id();
                try builder.emit(&builder.body, 168, &.{ builder.bool_type, inverted, condition }); // OpLogicalNot
                condition = inverted;
            }
            try builder.emit(&builder.body, 247, &.{ labels[selection.merge], 0 }); // OpSelectionMerge
            try builder.emit(&builder.body, 250, &.{
                condition,
                labels[selection.branch_successor],
                labels[selection.fallthrough_successor],
            });
        } else if (block.index + 1 < graph.blocks.items.len) {
            try builder.emit(&builder.body, 249, &.{labels[block.index + 1]});
        } else {
            return Error.UnsupportedControlFlow;
        }
    }
}

fn assemble(allocator: std.mem.Allocator, builder: *Builder, options: Options) Error!Module {
    var words: std.ArrayList(u32) = .empty;
    errdefer words.deinit(allocator);
    try words.appendSlice(allocator, &.{
        0x0723_0203,
        0x0001_0500,
        0x0050_4300,
        builder.next_id,
        0,
    });
    try appendInstruction(allocator, &words, 17, &.{1});
    try appendInstruction(allocator, &words, 14, &.{ 0, 1 });
    try appendInstruction(allocator, &words, 15, &.{ @intFromEnum(options.stage), builder.main_function, 0x6e69_616d, 0 });
    switch (options.stage) {
        .fragment => try appendInstruction(allocator, &words, 16, &.{ builder.main_function, 7 }),
        .compute => try appendInstruction(allocator, &words, 16, &.{ builder.main_function, 17, options.local_size[0], options.local_size[1], options.local_size[2] }),
        .vertex => {},
    }
    try words.appendSlice(allocator, builder.declarations.items);
    try appendInstruction(allocator, &words, 54, &.{ builder.void_type, builder.main_function, 0, builder.function_type });
    try words.appendSlice(allocator, builder.body.items);
    try appendInstruction(allocator, &words, 56, &.{});
    return .{ .words = try words.toOwnedSlice(allocator) };
}

/// Translates the executable ALU/SDWA subset and forward scalar selections.
/// The writer fails explicitly for operations or control-flow shapes whose
/// semantics are not implemented; it never emits a placeholder guest shader.
pub fn translate(allocator: std.mem.Allocator, program: *const instruction.Program, options: Options) Error!Module {
    var builder = try Builder.init(allocator);
    defer builder.deinit();
    var graph = try control_flow.build(allocator, program);
    defer graph.deinit(allocator);
    if (graph.blocks.items.len == 1) {
        try builder.emit(&builder.body, 248, &.{builder.label});
        for (program.instructions.items) |inst| try builder.lower(inst);
        try builder.emit(&builder.body, 253, &.{});
    } else {
        try translateStructured(&builder, program, &graph);
    }
    return assemble(allocator, &builder, options);
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

test "forward scalar selection lowers with a structured merge and register phi" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbe80_0381, // s_mov_b32 s0, 1
        0xbe81_0381, // s_mov_b32 s1, 1
        0xbf06_0100, // s_cmp_eq_u32 s0, s1
        0xbf84_0002, // s_cbranch_scc0 -> pc 24
        0xbe82_0382, // s_mov_b32 s2, 2
        0xbf82_0001, // s_branch -> pc 28
        0xbe82_0383, // s_mov_b32 s2, 3
        0x8003_8102, // s_add_u32 s3, s2, 1
        0xbf81_0000, // s_endpgm
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 247)); // OpSelectionMerge
    try std.testing.expect(containsOpcode(module.words, 250)); // OpBranchConditional
    try std.testing.expect(containsOpcode(module.words, 245)); // OpPhi
}

test "back edges remain explicit until loop structuring is implemented" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{ 0xbf80_0000, 0xbf82_fffe, 0xbf81_0000 };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectError(
        Error.UnsupportedControlFlow,
        translate(std.testing.allocator, &program, .{ .stage = .compute }),
    );
}

test "full destination SDWA lowers source extraction before vector ALU" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
        0x3f80_0000,
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 17) | (@as(u32, 1) << 9) | 255,
        0x4000_0000,
        (@as(u32, 3) << 25) | (@as(u32, 2) << 17) | (@as(u32, 1) << 9) | 249,
        (@as(u32, 6) << 8) | (@as(u32, 4) << 16) | (@as(u32, 6) << 24),
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 199)); // OpBitwiseAnd
    try std.testing.expect(containsOpcode(module.words, 129)); // OpFAdd
}
