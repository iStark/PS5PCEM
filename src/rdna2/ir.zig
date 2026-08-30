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

pub const PipelineOptions = struct {
    /// Emits SPIR-V from the typed IR rather than the decoded instruction
    /// stream. Runtime compatibility profiles may keep building the IR for
    /// diagnostics while bypassing it for executable shader generation.
    enable_typed_ir: bool = true,
    /// SSA construction and dead-definition elimination remain experimental
    /// until every implicit RDNA2 VGPR/VCC/EXEC dependency is represented.
    enable_ssa_optimization: bool = true,
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
    constant_folds: u32 = 0,
    dead_instructions: u32 = 0,
};

pub const ValueId = u32;
pub const invalid_value = std.math.maxInt(ValueId);

pub const ValueKind = enum { initial, constant, instruction, phi };

pub const SsaValue = struct {
    kind: ValueKind,
    value_type: ValueType,
    definition: u32 = std.math.maxInt(u32),
    constant_bits: ?u32 = null,
    use_count: u32 = 0,
};

pub const SsaInstruction = struct {
    node: u32,
    inputs: [96]ValueId = @splat(invalid_value),
    input_count: u8 = 0,
    outputs: [2]ValueId = @splat(invalid_value),
    output_count: u8 = 0,
    removed: bool = false,
};

pub const Phi = struct {
    block: u32,
    register: u16,
    output: ValueId,
    first_input: u32,
    input_count: u32,
};

pub const PhiInput = struct {
    predecessor: u32,
    value: ValueId,
};

pub const Use = struct {
    value: ValueId,
    user: u32,
    operand_index: u8,
    phi: bool = false,
};

pub const BackendView = struct {
    instructions: []const instruction.Instruction,
    nodes: []const Node,
    blocks: []const BasicBlock,
    values: []const SsaValue,
    ssa_instructions: []const SsaInstruction,
    phis: []const Phi,
};

pub const Module = struct {
    /// Decoded semantic payload owned by the IR. Keeping this copy makes the
    /// backend consume the pipeline product rather than reaching around it to
    /// the decoder's `Program`.
    instructions: std.ArrayList(instruction.Instruction) = .empty,
    backend_instructions: std.ArrayList(instruction.Instruction) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    blocks: std.ArrayList(BasicBlock) = .empty,
    values: std.ArrayList(SsaValue) = .empty,
    ssa_instructions: std.ArrayList(SsaInstruction) = .empty,
    phis: std.ArrayList(Phi) = .empty,
    phi_inputs: std.ArrayList(PhiInput) = .empty,
    uses: std.ArrayList(Use) = .empty,
    stage: PipelineStage = .decoded,
    validation: ValidationReport = .{},
    optimization: OptimizationReport = .{},

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
        self.backend_instructions.deinit(allocator);
        self.nodes.deinit(allocator);
        self.blocks.deinit(allocator);
        self.values.deinit(allocator);
        self.ssa_instructions.deinit(allocator);
        self.phis.deinit(allocator);
        self.phi_inputs.deinit(allocator);
        self.uses.deinit(allocator);
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
        try program.instructions.appendSlice(allocator, self.backend_instructions.items);
        return program;
    }

    /// Stable backend contract: code generators consume the legalized module
    /// and its optimized instruction view without reconstructing a decoder
    /// `Program` or reopening encoded shader words.
    pub fn backendView(self: *const Module) BackendView {
        return .{
            .instructions = self.backend_instructions.items,
            .nodes = self.nodes.items,
            .blocks = self.blocks.items,
            .values = self.values.items,
            .ssa_instructions = self.ssa_instructions.items,
            .phis = self.phis.items,
        };
    }
};

fn classify(inst: instruction.Instruction) struct { Operation, ValueType } {
    return switch (inst.opcode) {
        .s_nop,
        .s_inst_prefetch,
        .s_cbranch_cdbgsys,
        .s_cbranch_cdbguser,
        .s_cbranch_cdbgsys_or_user,
        .s_cbranch_cdbgsys_and_user,
        .v_nop,
        => .{ .nop, .none },
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

const register_slot_count = 416;

fn registerSlot(op: operand.Operand) ?u16 {
    return switch (op.kind) {
        .sgpr => if (op.reg < 128) @intCast(op.reg) else null,
        .vgpr => if (op.reg < 256) @intCast(128 + op.reg) else null,
        .ttmp => if (op.reg < 16) @intCast(384 + op.reg) else null,
        .vcc_lo, .vcc_z => 400,
        .vcc_hi => 401,
        .exec_lo, .exec_z => 402,
        .exec_hi => 403,
        .scc => 404,
        .m0 => 405,
        .flat_scratch_base_lo => 406,
        .flat_scratch_base_hi => 407,
        .shared_base => 408,
        .shared_limit => 409,
        .private_base => 410,
        .private_limit => 411,
        .pops_exiting_wave_id => 412,
        else => null,
    };
}

fn constantOperand(op: operand.Operand) bool {
    return switch (op.kind) {
        .integer_inline_constant, .float_inline_constant, .literal_constant, .null => true,
        else => false,
    };
}

const Predecessors = std.ArrayList(u32);

const SsaBuilder = struct {
    allocator: std.mem.Allocator,
    module: *Module,
    predecessors: []Predecessors,
    entry_definitions: []ValueId,
    local_definitions: []ValueId,
    initial_values: [register_slot_count]ValueId = @splat(invalid_value),

    fn definitionIndex(block: usize, slot: u16) usize {
        return block * register_slot_count + slot;
    }

    fn appendValue(self: *SsaBuilder, value: SsaValue) std.mem.Allocator.Error!ValueId {
        const id: ValueId = @intCast(self.module.values.items.len);
        try self.module.values.append(self.allocator, value);
        return id;
    }

    fn initialValue(self: *SsaBuilder, slot: u16) std.mem.Allocator.Error!ValueId {
        if (self.initial_values[slot] != invalid_value) return self.initial_values[slot];
        const value = try self.appendValue(.{ .kind = .initial, .value_type = .bits32, .definition = slot });
        self.initial_values[slot] = value;
        return value;
    }

    fn readExit(self: *SsaBuilder, block: u32, slot: u16) std.mem.Allocator.Error!ValueId {
        const index = definitionIndex(block, slot);
        if (self.local_definitions[index] != invalid_value) return self.local_definitions[index];
        return self.readEntry(block, slot);
    }

    fn readEntry(self: *SsaBuilder, block: u32, slot: u16) std.mem.Allocator.Error!ValueId {
        const index = definitionIndex(block, slot);
        if (self.entry_definitions[index] != invalid_value) return self.entry_definitions[index];
        const incoming = self.predecessors[block].items;
        if (block == 0 or incoming.len == 0) {
            const value = try self.initialValue(slot);
            self.entry_definitions[index] = value;
            return value;
        }
        if (incoming.len == 1) {
            const value = try self.readExit(incoming[0], slot);
            self.entry_definitions[index] = value;
            return value;
        }

        // Publish the phi output before following back edges. This is the
        // sealed-block SSA construction rule which makes natural loops finite.
        const output = try self.appendValue(.{ .kind = .phi, .value_type = .bits32 });
        self.entry_definitions[index] = output;
        const values = try self.allocator.alloc(ValueId, incoming.len);
        defer self.allocator.free(values);
        for (incoming, 0..) |predecessor, input_index| {
            values[input_index] = try self.readExit(predecessor, slot);
        }
        const first_input: u32 = @intCast(self.module.phi_inputs.items.len);
        for (incoming, values) |predecessor, value| {
            try self.module.phi_inputs.append(self.allocator, .{ .predecessor = predecessor, .value = value });
        }
        const phi_index: u32 = @intCast(self.module.phis.items.len);
        try self.module.phis.append(self.allocator, .{
            .block = block,
            .register = slot,
            .output = output,
            .first_input = first_input,
            .input_count = @intCast(values.len),
        });
        self.module.values.items[output].definition = phi_index;
        return output;
    }

    fn valueForOperand(self: *SsaBuilder, block: u32, current: []ValueId, op: operand.Operand) std.mem.Allocator.Error!ValueId {
        if (constantOperand(op)) {
            return self.appendValue(.{
                .kind = .constant,
                .value_type = .bits32,
                .constant_bits = if (op.kind == .null) 0 else op.value,
            });
        }
        const slot = registerSlot(op) orelse return self.appendValue(.{ .kind = .initial, .value_type = .bits32 });
        if (current[slot] == invalid_value) current[slot] = try self.readEntry(block, slot);
        return current[slot];
    }
};

fn operandHasModifiers(op: operand.Operand) bool {
    return op.negate or op.absolute or op.clamp or op.dpp or op.op_sel or op.op_sel_hi or
        op.negate_hi or op.omod != 0 or op.sdwa_sel != 6;
}

fn foldNode(node: Node, inputs: []const u32) ?u32 {
    if (inputs.len == 0) return null;
    for (node.sources.slice()) |source| if (operandHasModifiers(source)) return null;
    return switch (node.operation) {
        .move => inputs[0],
        .integer_add => if (inputs.len >= 2) inputs[0] +% inputs[1] else null,
        .integer_subtract => if (inputs.len >= 2)
            if (node.opcode == .v_subrev_nc_u32) inputs[1] -% inputs[0] else inputs[0] -% inputs[1]
        else
            null,
        .bit_and => if (inputs.len >= 2) inputs[0] & inputs[1] else null,
        .bit_or => if (inputs.len >= 2) inputs[0] | inputs[1] else null,
        .bit_xor => if (inputs.len >= 2) inputs[0] ^ inputs[1] else null,
        .float_add => if (inputs.len >= 2) @bitCast(@as(f32, @bitCast(inputs[0])) + @as(f32, @bitCast(inputs[1]))) else null,
        .float_subtract => if (inputs.len >= 2) @bitCast(@as(f32, @bitCast(inputs[0])) - @as(f32, @bitCast(inputs[1]))) else null,
        .float_multiply => if (inputs.len >= 2) @bitCast(@as(f32, @bitCast(inputs[0])) * @as(f32, @bitCast(inputs[1]))) else null,
        else => null,
    };
}

fn buildSsa(allocator: std.mem.Allocator, module: *Module) std.mem.Allocator.Error!void {
    module.values.clearRetainingCapacity();
    module.ssa_instructions.clearRetainingCapacity();
    module.phis.clearRetainingCapacity();
    module.phi_inputs.clearRetainingCapacity();
    module.uses.clearRetainingCapacity();
    try module.ssa_instructions.ensureTotalCapacity(allocator, module.nodes.items.len);
    for (module.nodes.items, 0..) |_, node_index| {
        module.ssa_instructions.appendAssumeCapacity(.{ .node = @intCast(node_index) });
    }

    const predecessors = try allocator.alloc(Predecessors, module.blocks.items.len);
    defer {
        for (predecessors) |*list| list.deinit(allocator);
        allocator.free(predecessors);
    }
    for (predecessors) |*list| list.* = .empty;
    for (module.blocks.items, 0..) |block, block_index| {
        for (block.successors[0..block.successor_count]) |successor| {
            try predecessors[successor].append(allocator, @intCast(block_index));
        }
    }
    const definition_count = module.blocks.items.len * register_slot_count;
    const entry_definitions = try allocator.alloc(ValueId, definition_count);
    defer allocator.free(entry_definitions);
    const local_definitions = try allocator.alloc(ValueId, definition_count);
    defer allocator.free(local_definitions);
    @memset(entry_definitions, invalid_value);
    @memset(local_definitions, invalid_value);

    var builder = SsaBuilder{
        .allocator = allocator,
        .module = module,
        .predecessors = predecessors,
        .entry_definitions = entry_definitions,
        .local_definitions = local_definitions,
    };

    // Allocate every explicit definition first so loop back edges can refer to
    // the final value of a block that has not yet been visited for uses.
    for (module.blocks.items, 0..) |block, block_index| {
        const first: usize = block.first_node;
        const end = first + block.node_count;
        for (module.nodes.items[first..end], first..) |node, node_index| {
            const destinations = [_]operand.Operand{ node.dst, node.dst2 };
            for (destinations) |destination| {
                const slot = registerSlot(destination) orelse continue;
                const value = try builder.appendValue(.{
                    .kind = .instruction,
                    .value_type = if (node.value_type == .none) .bits32 else node.value_type,
                    .definition = @intCast(node_index),
                });
                const ssa = &module.ssa_instructions.items[node_index];
                if (ssa.output_count < ssa.outputs.len) {
                    ssa.outputs[ssa.output_count] = value;
                    ssa.output_count += 1;
                }
                local_definitions[SsaBuilder.definitionIndex(block_index, slot)] = value;
            }
        }
    }

    for (module.blocks.items, 0..) |block, block_index| {
        var current: [register_slot_count]ValueId = @splat(invalid_value);
        const first: usize = block.first_node;
        const end = first + block.node_count;
        for (module.nodes.items[first..end], first..) |node, node_index| {
            const sources = node.sources;
            const ssa = &module.ssa_instructions.items[node_index];
            const tuple_operation = node.operation == .memory or node.operation == .image;
            var input_operands: [5]operand.Operand = undefined;
            var input_operand_count: usize = 0;
            if (tuple_operation and registerSlot(node.dst) != null) {
                input_operands[input_operand_count] = node.dst;
                input_operand_count += 1;
            }
            for (sources.slice()) |source| {
                input_operands[input_operand_count] = source;
                input_operand_count += 1;
            }
            for (input_operands[0..input_operand_count], 0..) |source, source_index| {
                const source_slot = registerSlot(source);
                const window: u32 = if (tuple_operation and source_slot != null) 16 else 1;
                for (0..window) |offset| {
                    var expanded = source;
                    if (source_slot != null) {
                        expanded.reg +%= @intCast(offset);
                        if (registerSlot(expanded) == null) break;
                    }
                    if (ssa.input_count == ssa.inputs.len) break;
                    const value = try builder.valueForOperand(@intCast(block_index), &current, expanded);
                    ssa.inputs[ssa.input_count] = value;
                    ssa.input_count += 1;
                    try module.uses.append(allocator, .{
                        .value = value,
                        .user = @intCast(node_index),
                        .operand_index = @intCast(@min(source_index, std.math.maxInt(u8))),
                    });
                    module.values.items[value].use_count += 1;
                }
            }
            const destinations = [_]operand.Operand{ node.dst, node.dst2 };
            var output_index: usize = 0;
            for (destinations) |destination| {
                const slot = registerSlot(destination) orelse continue;
                current[slot] = ssa.outputs[output_index];
                output_index += 1;
            }
        }
    }
    for (module.phis.items, 0..) |phi, phi_index| {
        const first: usize = phi.first_input;
        const end = first + phi.input_count;
        for (module.phi_inputs.items[first..end], 0..) |input, input_index| {
            try module.uses.append(allocator, .{
                .value = input.value,
                .user = @intCast(phi_index),
                .operand_index = @intCast(@min(input_index, std.math.maxInt(u8))),
                .phi = true,
            });
            module.values.items[input.value].use_count += 1;
        }
    }
}

fn dceEligible(node: Node) bool {
    if (node.side_effect or node.dst.kind != .vgpr) return false;
    return switch (node.operation) {
        .move,
        .integer_add,
        .integer_subtract,
        .shift_left_add,
        .float_add,
        .float_subtract,
        .float_multiply,
        .bit_and,
        .bit_or,
        .bit_xor,
        => true,
        else => false,
    };
}

/// SSA constant propagation and iterative dead-definition elimination. Branch
/// leaders retain their decoded PC even when their value is dead, preserving
/// the guest address domain used by control-flow lowering.
pub fn optimize(allocator: std.mem.Allocator, module: *Module) std.mem.Allocator.Error!void {
    module.optimization = .{};
    for (module.nodes.items, 0..) |*node, index| {
        node.elided = false;
        if (isBlockLeader(module, index)) continue;
        if (node.opcode != .s_nop and node.opcode != .v_nop) continue;
        node.elided = true;
        module.optimization.elided_nops += 1;
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (module.phis.items) |phi| {
            const output = &module.values.items[phi.output];
            if (output.constant_bits != null) continue;
            const first: usize = phi.first_input;
            const end = first + phi.input_count;
            var common: ?u32 = null;
            for (module.phi_inputs.items[first..end]) |input| {
                const bits = module.values.items[input.value].constant_bits orelse {
                    common = null;
                    break;
                };
                if (common) |expected| {
                    if (expected != bits) {
                        common = null;
                        break;
                    }
                } else common = bits;
            }
            if (common) |bits| {
                output.constant_bits = bits;
                changed = true;
            }
        }
        for (module.ssa_instructions.items) |ssa| {
            if (ssa.output_count == 0) continue;
            var inputs: [96]u32 = undefined;
            var all_constant = true;
            for (ssa.inputs[0..ssa.input_count], 0..) |value, index| {
                inputs[index] = module.values.items[value].constant_bits orelse {
                    all_constant = false;
                    break;
                };
            }
            if (!all_constant) continue;
            const bits = foldNode(module.nodes.items[ssa.node], inputs[0..ssa.input_count]) orelse continue;
            var newly_folded = false;
            for (ssa.outputs[0..ssa.output_count]) |output_id| {
                const output = &module.values.items[output_id];
                if (output.constant_bits == null) {
                    output.constant_bits = bits;
                    newly_folded = true;
                }
            }
            if (newly_folded) {
                module.optimization.constant_folds += 1;
                changed = true;
            }
        }
    }

    changed = true;
    while (changed) {
        changed = false;
        for (module.ssa_instructions.items) |*ssa| {
            if (ssa.removed or ssa.output_count == 0 or isBlockLeader(module, ssa.node)) continue;
            const node = &module.nodes.items[ssa.node];
            if (node.elided or !dceEligible(node.*)) continue;
            var unused = true;
            for (ssa.outputs[0..ssa.output_count]) |output| {
                if (module.values.items[output].use_count != 0) unused = false;
            }
            if (!unused) continue;
            ssa.removed = true;
            node.elided = true;
            module.optimization.dead_instructions += 1;
            for (ssa.inputs[0..ssa.input_count]) |input| {
                module.values.items[input].use_count -|= 1;
            }
            changed = true;
        }
    }

    module.backend_instructions.clearRetainingCapacity();
    try module.backend_instructions.ensureTotalCapacity(
        allocator,
        module.instructions.items.len -| module.optimization.elided_nops -| module.optimization.dead_instructions,
    );
    for (module.instructions.items, module.nodes.items) |inst, node| {
        if (!node.elided) module.backend_instructions.appendAssumeCapacity(inst);
    }
    module.stage = .optimized;
}

/// Compatibility optimizer used by the live renderer unless SSA is opted in.
/// It preserves the pre-SSA emission contract: only non-target NOPs disappear,
/// while every value-producing instruction remains visible to the backend.
fn optimizeConservative(allocator: std.mem.Allocator, module: *Module) std.mem.Allocator.Error!void {
    module.optimization = .{};
    for (module.nodes.items, 0..) |*node, index| {
        node.elided = false;
        if (isBlockLeader(module, index)) continue;
        if (node.opcode != .s_nop and node.opcode != .v_nop) continue;
        node.elided = true;
        module.optimization.elided_nops += 1;
    }
    module.backend_instructions.clearRetainingCapacity();
    try module.backend_instructions.ensureTotalCapacity(
        allocator,
        module.instructions.items.len -| module.optimization.elided_nops,
    );
    for (module.instructions.items, module.nodes.items) |inst, node| {
        if (!node.elided) module.backend_instructions.appendAssumeCapacity(inst);
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
    return runPipelineWithOptions(allocator, module, .{});
}

pub fn runPipelineWithOptions(
    allocator: std.mem.Allocator,
    module: *Module,
    options: PipelineOptions,
) std.mem.Allocator.Error!void {
    module.stage = .typed;
    try validate(allocator, module);
    if (options.enable_ssa_optimization) {
        try buildSsa(allocator, module);
        try optimize(allocator, module);
    } else {
        try optimizeConservative(allocator, module);
    }
    legalize(module);
}

pub fn lower(allocator: std.mem.Allocator, program: *const instruction.Program) std.mem.Allocator.Error!Module {
    return lowerWithOptions(allocator, program, .{});
}

pub fn lowerWithOptions(
    allocator: std.mem.Allocator,
    program: *const instruction.Program,
    options: PipelineOptions,
) std.mem.Allocator.Error!Module {
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
    try runPipelineWithOptions(allocator, &module, options);
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

test "SSA propagates constants and removes a dead vector definition" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 4 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .v_add_nc_u32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 7 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_endpgm });
    var module = try lower(std.testing.allocator, &program);
    defer module.deinit(std.testing.allocator);

    const add = module.ssa_instructions.items[1];
    try std.testing.expectEqual(@as(?u32, 11), module.values.items[add.outputs[0]].constant_bits);
    try std.testing.expectEqual(@as(u32, 2), module.optimization.constant_folds);
    try std.testing.expectEqual(@as(u32, 1), module.optimization.dead_instructions);
    try std.testing.expect(module.nodes.items[1].elided);
}

test "conservative pipeline retains value-producing instructions" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 4 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .v_add_nc_u32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 7 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_endpgm });
    var module = try lowerWithOptions(
        std.testing.allocator,
        &program,
        .{ .enable_ssa_optimization = false },
    );
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), module.ssa_instructions.items.len);
    try std.testing.expectEqual(@as(u32, 0), module.optimization.dead_instructions);
    try std.testing.expectEqual(@as(usize, 3), module.backend_instructions.items.len);
    try std.testing.expect(!module.nodes.items[1].elided);
}

test "SSA inserts a phi at a register merge and records def-use edges" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_cbranch_scc1,
        .branch_target = 12,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .opcode = .s_branch,
        .branch_target = 16,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 12,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 2 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 16,
        .opcode = .v_add_nc_u32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 3 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 20, .opcode = .s_endpgm });
    var module = try lower(std.testing.allocator, &program);
    defer module.deinit(std.testing.allocator);

    var merged: ?Phi = null;
    for (module.phis.items) |phi| if (phi.register == 128) {
        merged = phi;
        break;
    };
    try std.testing.expect(merged != null);
    try std.testing.expectEqual(@as(u32, 2), merged.?.input_count);
    try std.testing.expect(module.values.items[merged.?.output].use_count != 0);
    try std.testing.expect(module.uses.items.len >= 4);
}
