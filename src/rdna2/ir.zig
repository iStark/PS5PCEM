// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Typed, API-neutral shader IR boundary.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
const instruction = @import("instruction.zig");

pub const ValueType = enum { bits32, uint32, sint32, float32, mask64, none };

pub const PipelineStage = enum {
    decoded,
    typed,
    validated,
    optimized,
    legalized,
};

pub const Operation = enum {
    nop,
    move,
    integer_add,
    shift_left_add,
    integer_subtract,
    float_add,
    float_subtract,
    float_multiply,
    bit_and,
    bit_or,
    bit_xor,
    compare,
    branch,
    branch_conditional,
    memory,
    image,
    interpolation,
    export_value,
    synchronization,
    end,
    opaque_instruction,
};

/// Addressing information retained at the API-neutral boundary. Backends can
/// now reason about guest memory operations without reopening the encoded
/// instruction words.
pub const MemoryAccess = struct {
    byte_offset: i32,
    data_words: u8,
    data_bits: u8,
    resource: operand.Operand,
    vector_address: operand.Operand,
    scalar_offset: operand.Operand,
    index_enabled: bool,
    offset_enabled: bool,
    globally_coherent: bool,
    system_coherent: bool,
};

pub const Node = struct {
    pc: u32,
    operation: Operation,
    value_type: ValueType,
    opcode: isa.Opcode,
    dst: operand.Operand,
    dst2: operand.Operand,
    sources: instruction.Sources,
    branch_target: u32,
    memory_access: ?MemoryAccess,
    reachable: bool = false,
    side_effect: bool = false,
    /// Safe no-op removed from the program presented to a backend. Nodes stay
    /// in the module so diagnostics retain a one-to-one decoded-PC view.
    elided: bool = false,
};

pub const BasicBlock = struct {
    first_node: u32,
    node_count: u32,
    start_pc: u32,
    successors: [2]u32 = @splat(std.math.maxInt(u32)),
    successor_count: u8 = 0,
    reachable: bool = false,
};

pub const ValidationReport = struct {
    instruction_count: u32 = 0,
    block_count: u32 = 0,
    opaque_instruction_count: u32 = 0,
    duplicate_pc_count: u32 = 0,
    unordered_pc_count: u32 = 0,
    invalid_branch_target_count: u32 = 0,
    unreachable_instruction_count: u32 = 0,

    pub fn structurallyValid(self: ValidationReport) bool {
        return self.duplicate_pc_count == 0 and
            self.unordered_pc_count == 0 and
            self.invalid_branch_target_count == 0;
    }
};

pub const OptimizationReport = struct {
    elided_nops: u32 = 0,
};

pub const Module = struct {
    /// Decoded semantic payload owned by the IR. Keeping this copy makes the
    /// backend consume the pipeline product rather than reaching around it to
    /// the decoder's `Program`.
    instructions: std.ArrayList(instruction.Instruction) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    blocks: std.ArrayList(BasicBlock) = .empty,
    stage: PipelineStage = .decoded,
    validation: ValidationReport = .{},
    optimization: OptimizationReport = .{},

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
        self.nodes.deinit(allocator);
        self.blocks.deinit(allocator);
        self.* = undefined;
    }

    /// Builds the instruction stream consumed by a code-generation backend.
    /// Only proven no-ops are omitted; decoded PCs and branch targets remain
    /// unchanged, so control-flow lowering has the same address domain.
    pub fn emissionProgram(
        self: *const Module,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!instruction.Program {
        var program = instruction.Program{ .code = &.{}, .instructions = .empty };
        errdefer program.deinit(allocator);
        try program.instructions.ensureTotalCapacity(
            allocator,
            self.instructions.items.len -| self.optimization.elided_nops,
        );
        for (self.instructions.items, self.nodes.items) |inst, node| {
            if (!node.elided) program.instructions.appendAssumeCapacity(inst);
        }
        return program;
    }
};

fn classify(inst: instruction.Instruction) struct { Operation, ValueType } {
    return switch (inst.opcode) {
        .s_nop, .s_inst_prefetch, .v_nop => .{ .nop, .none },
        .s_waitcnt, .s_waitcnt_depctr, .s_barrier => .{ .synchronization, .none },
        .s_mov_b32, .v_mov_b32 => .{ .move, .bits32 },
        .s_add_u32, .s_add_i32, .v_add_nc_u32, .v_addc_u32 => .{ .integer_add, .uint32 },
        .v_lshl_add_u32 => .{ .shift_left_add, .uint32 },
        .s_sub_u32, .s_sub_i32, .v_sub_nc_u32, .v_subrev_nc_u32 => .{ .integer_subtract, .uint32 },
        .v_add_f32 => .{ .float_add, .float32 },
        .v_sub_f32, .v_subrev_f32 => .{ .float_subtract, .float32 },
        .v_mul_f32 => .{ .float_multiply, .float32 },
        .s_and_b32, .v_and_b32 => .{ .bit_and, .bits32 },
        .s_or_b32, .v_or_b32 => .{ .bit_or, .bits32 },
        .s_xor_b32, .v_xor_b32 => .{ .bit_xor, .bits32 },
        .s_cmp_eq_i32, .s_cmp_lg_i32, .s_cmp_gt_i32, .s_cmp_ge_i32, .s_cmp_lt_i32, .s_cmp_le_i32, .s_cmp_eq_u32, .s_cmp_lg_u32, .s_cmp_gt_u32, .s_cmp_ge_u32, .s_cmp_lt_u32, .s_cmp_le_u32, .v_cmp_f_f32, .v_cmp_lt_f32, .v_cmp_eq_f32, .v_cmp_le_f32, .v_cmp_gt_f32, .v_cmp_lg_f32, .v_cmp_ge_f32, .v_cmp_o_f32, .v_cmp_u_f32, .v_cmp_tru_f32, .v_cmp_lt_i32, .v_cmp_eq_i32, .v_cmp_le_i32, .v_cmp_gt_i32, .v_cmp_ne_i32, .v_cmp_ge_i32, .v_cmp_lt_u32, .v_cmp_eq_u32, .v_cmp_le_u32, .v_cmp_gt_u32, .v_cmp_ne_u32, .v_cmp_ge_u32, .v_cmpx_gt_u32 => .{ .compare, .mask64 },
        .s_branch => .{ .branch, .none },
        .s_cbranch_scc0, .s_cbranch_scc1, .s_cbranch_vccz, .s_cbranch_vccnz, .s_cbranch_execz, .s_cbranch_execnz => .{ .branch_conditional, .none },
        .buffer_load_format_x,
        .buffer_load_format_xy,
        .buffer_load_format_xyz,
        .buffer_load_format_xyzw,
        .buffer_store_format_x,
        .buffer_store_format_xy,
        .buffer_store_format_xyz,
        .buffer_store_format_xyzw,
        .buffer_load_ubyte,
        .buffer_load_sbyte,
        .buffer_load_ushort,
        .buffer_load_sshort,
        .buffer_load_dword,
        .buffer_load_dwordx2,
        .buffer_load_dwordx3,
        .buffer_load_dwordx4,
        .buffer_store_byte,
        .buffer_store_short,
        .buffer_store_dword,
        .buffer_store_dwordx2,
        .buffer_store_dwordx3,
        .buffer_store_dwordx4,
        .buffer_atomic_swap,
        .buffer_atomic_add,
        .buffer_atomic_sub,
        .buffer_atomic_smin,
        .buffer_atomic_umin,
        .buffer_atomic_smax,
        .buffer_atomic_umax,
        .buffer_atomic_and,
        .buffer_atomic_or,
        .buffer_atomic_xor,
        .tbuffer_load_format_x,
        .tbuffer_load_format_xy,
        .tbuffer_load_format_xyz,
        .tbuffer_load_format_xyzw,
        .tbuffer_store_format_x,
        .tbuffer_store_format_xy,
        .tbuffer_store_format_xyz,
        .tbuffer_store_format_xyzw,
        .flat_load_ubyte,
        .flat_load_sbyte,
        .flat_load_ushort,
        .flat_load_sshort,
        .flat_load_dword,
        .flat_load_dwordx2,
        .flat_load_dwordx3,
        .flat_load_dwordx4,
        .flat_store_byte,
        .flat_store_short,
        .flat_store_dword,
        .flat_store_dwordx2,
        .flat_store_dwordx3,
        .flat_store_dwordx4,
        .ds_add_u32,
        .ds_sub_u32,
        .ds_min_i32,
        .ds_max_i32,
        .ds_min_u32,
        .ds_max_u32,
        .ds_and_b32,
        .ds_or_b32,
        .ds_xor_b32,
        .ds_write_b32,
        .ds_write2_b32,
        .ds_read_b32,
        .ds_read2_b32,
        .ds_read_b64,
        .ds_read_b96,
        .ds_read_b128,
        .ds_write_b64,
        .ds_write_b96,
        .ds_write_b128,
        .ds_read_ubyte,
        .ds_read_sbyte,
        .ds_read_ushort,
        .ds_read_sshort,
        .ds_read_u16_d16,
        .ds_write_b8,
        .ds_write_b16,
        .ds_write2st64_b32,
        .ds_read2st64_b32,
        .ds_read2_b64,
        .ds_read2st64_b64,
        .ds_write2_b64,
        .ds_write2st64_b64,
        .ds_add_rtn_u32,
        .ds_sub_rtn_u32,
        .ds_min_rtn_i32,
        .ds_max_rtn_i32,
        .ds_min_rtn_u32,
        .ds_max_rtn_u32,
        .ds_and_rtn_b32,
        .ds_or_rtn_b32,
        .ds_xor_rtn_b32,
        .ds_wrxchg_rtn_b32,
        .ds_min_f32,
        .ds_max_f32,
        .ds_swizzle_b32,
        .ds_consume,
        .ds_append,
        .ds_write_addtid_b32,
        .ds_read_addtid_b32,
        .s_load_dword,
        .s_load_dwordx2,
        .s_load_dwordx4,
        .s_load_dwordx8,
        .s_load_dwordx16,
        .s_buffer_load_dword,
        .s_buffer_load_dwordx2,
        .s_buffer_load_dwordx4,
        .s_buffer_load_dwordx8,
        .s_buffer_load_dwordx16,
        => .{ .memory, .bits32 },
        .image_load, .image_load_mip, .image_store, .image_store_mip, .image_get_resinfo, .image_get_lod, .image_atomic_add, .image_atomic_umin, .image_atomic_umax, .image_atomic_and, .image_atomic_or, .image_atomic_xor, .image_sample, .image_gather4 => .{ .image, .bits32 },
        .v_interp_p1_f32, .v_interp_p2_f32, .v_interp_mov_f32 => .{ .interpolation, .float32 },
        .exp => .{ .export_value, .bits32 },
        .s_endpgm, .s_code_end => .{ .end, .none },
        else => .{ .opaque_instruction, .none },
    };
}

fn operationHasSideEffect(operation: Operation) bool {
    return switch (operation) {
        .branch,
        .branch_conditional,
        .memory,
        .image,
        .export_value,
        .synchronization,
        .end,
        .opaque_instruction,
        => true,
        else => false,
    };
}

fn instructionIndexAtPc(module: *const Module, pc: u32) ?usize {
    for (module.nodes.items, 0..) |node, index| {
        if (node.pc == pc) return index;
    }
    return null;
}

fn blockIndexAtPc(module: *const Module, pc: u32) ?u32 {
    for (module.blocks.items, 0..) |block, index| {
        if (block.start_pc == pc) return @intCast(index);
    }
    return null;
}

fn appendSuccessor(block: *BasicBlock, successor: ?u32) void {
    const value = successor orelse return;
    for (block.successors[0..block.successor_count]) |existing| {
        if (existing == value) return;
    }
    if (block.successor_count == block.successors.len) return;
    block.successors[block.successor_count] = value;
    block.successor_count += 1;
}

/// Validates decoded-PC topology, builds basic blocks and marks reachability.
/// Unsupported opcodes are diagnostics, not structural errors: a backend may
/// support more of the ISA than the common optimizer understands.
pub fn validate(allocator: std.mem.Allocator, module: *Module) std.mem.Allocator.Error!void {
    module.validation = .{ .instruction_count = @intCast(module.nodes.items.len) };
    module.blocks.clearRetainingCapacity();
    for (module.nodes.items) |*node| node.reachable = false;
    if (module.nodes.items.len == 0) {
        module.stage = .validated;
        return;
    }

    const leaders = try allocator.alloc(bool, module.nodes.items.len);
    defer allocator.free(leaders);
    @memset(leaders, false);
    leaders[0] = true;

    for (module.nodes.items, 0..) |node, index| {
        if (node.operation == .opaque_instruction) module.validation.opaque_instruction_count += 1;
        if (index != 0) {
            const previous_pc = module.nodes.items[index - 1].pc;
            if (node.pc == previous_pc) {
                module.validation.duplicate_pc_count += 1;
            } else if (node.pc < previous_pc) {
                module.validation.unordered_pc_count += 1;
            }
        }
        if (node.operation == .branch or node.operation == .branch_conditional) {
            if (instructionIndexAtPc(module, node.branch_target)) |target_index| {
                leaders[target_index] = true;
            } else {
                module.validation.invalid_branch_target_count += 1;
            }
            if (index + 1 < leaders.len) leaders[index + 1] = true;
        } else if (node.operation == .end and index + 1 < leaders.len) {
            leaders[index + 1] = true;
        }
    }

    var first: usize = 0;
    var index: usize = 1;
    while (index <= leaders.len) : (index += 1) {
        if (index != leaders.len and !leaders[index]) continue;
        try module.blocks.append(allocator, .{
            .first_node = @intCast(first),
            .node_count = @intCast(index - first),
            .start_pc = module.nodes.items[first].pc,
        });
        first = index;
    }

    for (module.blocks.items, 0..) |*block, block_index| {
        const last_node_index = @as(usize, block.first_node) + block.node_count - 1;
        const last = module.nodes.items[last_node_index];
        const fallthrough: ?u32 = if (block_index + 1 < module.blocks.items.len)
            @intCast(block_index + 1)
        else
            null;
        switch (last.operation) {
            .branch => appendSuccessor(block, blockIndexAtPc(module, last.branch_target)),
            .branch_conditional => {
                appendSuccessor(block, blockIndexAtPc(module, last.branch_target));
                appendSuccessor(block, fallthrough);
            },
            .end => {},
            else => appendSuccessor(block, fallthrough),
        }
    }

    var worklist: std.ArrayList(u32) = .empty;
    defer worklist.deinit(allocator);
    try worklist.append(allocator, 0);
    module.blocks.items[0].reachable = true;
    var cursor: usize = 0;
    while (cursor < worklist.items.len) : (cursor += 1) {
        const block = module.blocks.items[worklist.items[cursor]];
        for (block.successors[0..block.successor_count]) |successor| {
            if (module.blocks.items[successor].reachable) continue;
            module.blocks.items[successor].reachable = true;
            try worklist.append(allocator, successor);
        }
    }
    for (module.blocks.items) |block| {
        const first_node: usize = @intCast(block.first_node);
        const end_node = first_node + block.node_count;
        for (module.nodes.items[first_node..end_node]) |*node| node.reachable = block.reachable;
    }
    for (module.nodes.items) |node| {
        if (!node.reachable) module.validation.unreachable_instruction_count += 1;
    }
    module.validation.block_count = @intCast(module.blocks.items.len);
    module.stage = .validated;
}

fn isBlockLeader(module: *const Module, node_index: usize) bool {
    for (module.blocks.items) |block| {
        if (block.first_node == node_index) return true;
    }
    return false;
}

/// Conservative IR optimization. Only decoded no-ops which are not branch
/// destinations are elided; side effects and unreachable code are retained
/// until a later SSA-based data-flow pass can prove them dead.
pub fn optimize(module: *Module) void {
    module.optimization = .{};
    for (module.nodes.items, 0..) |*node, index| {
        node.elided = false;
        if (isBlockLeader(module, index)) continue;
        if (node.opcode != .s_nop and node.opcode != .v_nop) continue;
        node.elided = true;
        module.optimization.elided_nops += 1;
    }
    module.stage = .optimized;
}

/// Final API-neutral legalization boundary. All current values already use
/// backend-portable scalar types; keeping this as an explicit pass gives new
/// 16/64-bit operations one well-defined place to be widened or split.
pub fn legalize(module: *Module) void {
    module.stage = .legalized;
}

pub fn runPipeline(allocator: std.mem.Allocator, module: *Module) std.mem.Allocator.Error!void {
    module.stage = .typed;
    try validate(allocator, module);
    optimize(module);
    legalize(module);
}

pub fn lower(allocator: std.mem.Allocator, program: *const instruction.Program) std.mem.Allocator.Error!Module {
    var module = Module{};
    errdefer module.deinit(allocator);
    try module.instructions.appendSlice(allocator, program.instructions.items);
    try module.nodes.ensureTotalCapacity(allocator, program.instructions.items.len);
    for (program.instructions.items) |inst| {
        const kind = classify(inst);
        module.nodes.appendAssumeCapacity(.{
            .pc = inst.pc,
            .operation = kind[0],
            .value_type = kind[1],
            .opcode = inst.opcode,
            .dst = inst.dst,
            .dst2 = inst.dst2,
            .sources = inst.sources(),
            .branch_target = inst.branch_target,
            .side_effect = operationHasSideEffect(kind[0]),
            .memory_access = if (kind[0] == .memory) .{
                .byte_offset = inst.memory_offset,
                .data_words = inst.data_words,
                .data_bits = inst.data_bits,
                .resource = inst.src1,
                .vector_address = inst.src0,
                .scalar_offset = inst.src2,
                .index_enabled = inst.index_enable,
                .offset_enabled = inst.offset_enable,
                .globally_coherent = inst.globally_coherent,
                .system_coherent = inst.system_coherent,
            } else null,
        });
    }
    try runPipeline(allocator, &module);
    return module;
}

test "buffer memory nodes retain descriptor and byte addressing" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe030_5020, // buffer_load_dword offen offset=0x20
        0x8002_0103, // v1, v3, s8:s11, soffset=0
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try lower(std.testing.allocator, &program);
    defer module.deinit(std.testing.allocator);

    const access = module.nodes.items[0].memory_access.?;
    try std.testing.expectEqual(@as(i32, 0x20), access.byte_offset);
    try std.testing.expect(access.offset_enabled);
    try std.testing.expectEqual(@as(u32, 8), access.resource.reg);
    try std.testing.expectEqual(@as(u32, 3), access.vector_address.reg);
}

test "buffer atomics remain memory nodes with coherence metadata" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe0c8_4000, // buffer_atomic_add glc v0, v0, s8:s11, 0
        0x8002_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try lower(std.testing.allocator, &program);
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(Operation.memory, module.nodes.items[0].operation);
    try std.testing.expectEqual(isa.Opcode.buffer_atomic_add, module.nodes.items[0].opcode);
    try std.testing.expect(module.nodes.items[0].memory_access.?.globally_coherent);
}

test "vector arithmetic lowers to typed API-neutral nodes" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 3) << 25) | (@as(u32, 1) << 17) | 256,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try lower(std.testing.allocator, &program);
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(Operation.float_add, module.nodes.items[0].operation);
    try std.testing.expectEqual(ValueType.float32, module.nodes.items[0].value_type);
    try std.testing.expectEqual(Operation.end, module.nodes.items[1].operation);
}

test "IR pipeline builds CFG reachability and validates branch targets" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_branch,
        .branch_target = 8,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .s_mov_b32,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .opcode = .s_endpgm,
    });
    var module = try lower(std.testing.allocator, &program);
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(PipelineStage.legalized, module.stage);
    try std.testing.expect(module.validation.structurallyValid());
    try std.testing.expectEqual(@as(u32, 3), module.validation.block_count);
    try std.testing.expect(!module.nodes.items[1].reachable);
    try std.testing.expectEqual(@as(u32, 1), module.validation.unreachable_instruction_count);
}

test "IR optimization elides only non-leader no-ops for emission" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{ .pc = 0, .opcode = .s_mov_b32 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 4, .opcode = .s_nop });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_endpgm });
    var module = try lower(std.testing.allocator, &program);
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), module.optimization.elided_nops);
    var emission = try module.emissionProgram(std.testing.allocator);
    defer emission.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), emission.instructions.items.len);
    try std.testing.expectEqual(isa.Opcode.s_endpgm, emission.instructions.items[1].opcode);
}
