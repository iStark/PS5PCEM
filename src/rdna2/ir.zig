// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Typed, API-neutral shader IR boundary.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
const instruction = @import("instruction.zig");

pub const ValueType = enum { bits32, uint32, sint32, float32, mask64, none };

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
};

pub const Module = struct {
    nodes: std.ArrayList(Node) = .empty,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }
};

fn classify(inst: instruction.Instruction) struct { Operation, ValueType } {
    return switch (inst.opcode) {
        .s_nop, .s_waitcnt, .s_barrier, .s_inst_prefetch, .v_nop => .{ .nop, .none },
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

pub fn lower(allocator: std.mem.Allocator, program: *const instruction.Program) std.mem.Allocator.Error!Module {
    var module = Module{};
    errdefer module.deinit(allocator);
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
