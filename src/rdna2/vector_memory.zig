// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! GFX10 vector-buffer, typed-buffer, flat, LDS and image decoding.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
const instruction = @import("instruction.zig");

const Instruction = instruction.Instruction;
pub const Error = instruction.Error;

const MemoryInfo = struct {
    opcode: isa.Opcode,
    words: u8 = 1,
    bits: u8 = 32,
    signed: bool = false,
    typed: bool = false,
    formatted: bool = false,
};

fn mubufInfo(id: u32) ?MemoryInfo {
    return switch (id) {
        0x00 => .{ .opcode = .buffer_load_format_x, .formatted = true },
        0x01 => .{ .opcode = .buffer_load_format_xy, .words = 2, .formatted = true },
        0x02 => .{ .opcode = .buffer_load_format_xyz, .words = 3, .formatted = true },
        0x03 => .{ .opcode = .buffer_load_format_xyzw, .words = 4, .formatted = true },
        0x04 => .{ .opcode = .buffer_store_format_x, .formatted = true },
        0x05 => .{ .opcode = .buffer_store_format_xy, .words = 2, .formatted = true },
        0x06 => .{ .opcode = .buffer_store_format_xyz, .words = 3, .formatted = true },
        0x07 => .{ .opcode = .buffer_store_format_xyzw, .words = 4, .formatted = true },
        0x08 => .{ .opcode = .buffer_load_ubyte, .bits = 8 },
        0x09 => .{ .opcode = .buffer_load_sbyte, .bits = 8, .signed = true },
        0x0a => .{ .opcode = .buffer_load_ushort, .bits = 16 },
        0x0b => .{ .opcode = .buffer_load_sshort, .bits = 16, .signed = true },
        0x0c => .{ .opcode = .buffer_load_dword },
        0x0d => .{ .opcode = .buffer_load_dwordx2, .words = 2 },
        0x0e => .{ .opcode = .buffer_load_dwordx4, .words = 4 },
        0x0f => .{ .opcode = .buffer_load_dwordx3, .words = 3 },
        0x18 => .{ .opcode = .buffer_store_byte, .bits = 8 },
        0x1a => .{ .opcode = .buffer_store_short, .bits = 16 },
        0x1c => .{ .opcode = .buffer_store_dword },
        0x1d => .{ .opcode = .buffer_store_dwordx2, .words = 2 },
        0x1e => .{ .opcode = .buffer_store_dwordx4, .words = 4 },
        0x1f => .{ .opcode = .buffer_store_dwordx3, .words = 3 },
        0x30 => .{ .opcode = .buffer_atomic_swap },
        0x32 => .{ .opcode = .buffer_atomic_add },
        0x33 => .{ .opcode = .buffer_atomic_sub },
        0x35 => .{ .opcode = .buffer_atomic_smin },
        0x36 => .{ .opcode = .buffer_atomic_umin },
        0x37 => .{ .opcode = .buffer_atomic_smax },
        0x38 => .{ .opcode = .buffer_atomic_umax },
        0x39 => .{ .opcode = .buffer_atomic_and },
        0x3a => .{ .opcode = .buffer_atomic_or },
        0x3b => .{ .opcode = .buffer_atomic_xor },
        else => null,
    };
}

fn applyInfo(inst: *Instruction, info: ?MemoryInfo, reason: []const u8) void {
    if (info) |value| {
        inst.opcode = value.opcode;
        inst.data_words = value.words;
        inst.data_bits = value.bits;
        inst.data_signed = value.signed;
        inst.typed = value.typed;
        inst.formatted = value.formatted;
    } else {
        inst.opcode = .unsupported;
        inst.unsupported_reason = reason;
    }
}

pub fn decodeMubuf(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    const word0 = code[word_index];
    const word1 = code[word_index + 1];
    const id = ((word0 >> 18) & 0x7f) | (((word0 >> 25) & 1) << 7);
    var inst = Instruction{ .pc = pc, .word = word0, .family = .mubuf, .opcode_id = id };
    inst.setRawWords(code, word_index, 2);
    inst.memory_offset = @intCast(word0 & 0xfff);
    inst.offset_enable = (word0 >> 12) & 1 != 0;
    inst.index_enable = (word0 >> 13) & 1 != 0;
    inst.globally_coherent = (word0 >> 14) & 1 != 0;
    inst.system_coherent = (word1 >> 22) & 1 != 0;
    applyInfo(&inst, mubufInfo(id), "MUBUF opcode is not implemented");
    inst.dst = try operand.decodeVectorGpr((word1 >> 8) & 0xff);
    inst.src0 = try operand.decodeVectorGpr(word1 & 0xff);
    inst.src1 = try operand.decodeScalarSource(((word1 >> 16) & 0x1f) * 4);
    inst.src2 = try operand.decodeScalarSource((word1 >> 24) & 0xff);
    inst.src_count = 3;
    return inst;
}

fn mtbufInfo(id: u32) ?MemoryInfo {
    return switch (id) {
        0 => .{ .opcode = .tbuffer_load_format_x, .typed = true, .formatted = true },
        1 => .{ .opcode = .tbuffer_load_format_xy, .words = 2, .typed = true, .formatted = true },
        2 => .{ .opcode = .tbuffer_load_format_xyz, .words = 3, .typed = true, .formatted = true },
        3 => .{ .opcode = .tbuffer_load_format_xyzw, .words = 4, .typed = true, .formatted = true },
        4 => .{ .opcode = .tbuffer_store_format_x, .typed = true, .formatted = true },
        5 => .{ .opcode = .tbuffer_store_format_xy, .words = 2, .typed = true, .formatted = true },
        6 => .{ .opcode = .tbuffer_store_format_xyz, .words = 3, .typed = true, .formatted = true },
        7 => .{ .opcode = .tbuffer_store_format_xyzw, .words = 4, .typed = true, .formatted = true },
        else => null,
    };
}

pub fn decodeMtbuf(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    const word0 = code[word_index];
    const word1 = code[word_index + 1];
    const id = ((word0 >> 16) & 7) | (((word1 >> 21) & 1) << 3);
    var inst = Instruction{ .pc = pc, .word = word0, .family = .mtbuf, .opcode_id = id };
    inst.setRawWords(code, word_index, 2);
    inst.memory_offset = @intCast(word0 & 0xfff);
    inst.offset_enable = (word0 >> 12) & 1 != 0;
    inst.index_enable = (word0 >> 13) & 1 != 0;
    inst.globally_coherent = (word0 >> 14) & 1 != 0;
    inst.data_format = @intCast((word0 >> 19) & 0xf);
    inst.number_format = @intCast((word0 >> 23) & 7);
    inst.system_coherent = (word1 >> 22) & 1 != 0;
    applyInfo(&inst, mtbufInfo(id), "MTBUF opcode is not implemented");
    inst.dst = try operand.decodeVectorGpr((word1 >> 8) & 0xff);
    inst.src0 = try operand.decodeVectorGpr(word1 & 0xff);
    inst.src1 = try operand.decodeScalarSource(((word1 >> 16) & 0x1f) * 4);
    inst.src2 = try operand.decodeScalarSource((word1 >> 24) & 0xff);
    inst.src_count = 3;
    return inst;
}

fn flatInfo(id: u32) ?MemoryInfo {
    return switch (id) {
        0x08 => .{ .opcode = .flat_load_ubyte, .bits = 8 },
        0x09 => .{ .opcode = .flat_load_sbyte, .bits = 8, .signed = true },
        0x0a => .{ .opcode = .flat_load_ushort, .bits = 16 },
        0x0b => .{ .opcode = .flat_load_sshort, .bits = 16, .signed = true },
        0x0c => .{ .opcode = .flat_load_dword },
        0x0d => .{ .opcode = .flat_load_dwordx2, .words = 2 },
        0x0e => .{ .opcode = .flat_load_dwordx4, .words = 4 },
        0x0f => .{ .opcode = .flat_load_dwordx3, .words = 3 },
        0x18 => .{ .opcode = .flat_store_byte, .bits = 8 },
        0x1a => .{ .opcode = .flat_store_short, .bits = 16 },
        0x1c => .{ .opcode = .flat_store_dword },
        0x1d => .{ .opcode = .flat_store_dwordx2, .words = 2 },
        0x1e => .{ .opcode = .flat_store_dwordx4, .words = 4 },
        0x1f => .{ .opcode = .flat_store_dwordx3, .words = 3 },
        else => null,
    };
}

fn signExtend12(value: u32) i32 {
    const raw: i32 = @intCast(value & 0xfff);
    return if (raw & 0x800 != 0) raw - 0x1000 else raw;
}

pub fn decodeFlat(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    const word0 = code[word_index];
    const word1 = code[word_index + 1];
    const id = (word0 >> 18) & 0x7f;
    const segment: u2 = @intCast((word0 >> 14) & 3);
    var inst = Instruction{ .pc = pc, .word = word0, .family = .flat, .opcode_id = id, .memory_segment = segment };
    inst.setRawWords(code, word_index, 2);
    inst.memory_offset = if (segment == 0) @intCast(word0 & 0x7ff) else signExtend12(word0);
    inst.globally_coherent = (word0 >> 16) & 1 != 0;
    inst.system_coherent = (word0 >> 17) & 1 != 0;
    applyInfo(&inst, flatInfo(id), "FLAT opcode is not implemented");
    const data = (word1 >> 8) & 0xff;
    const vdst = (word1 >> 24) & 0xff;
    const store = id >= 0x18 and id <= 0x1f;
    inst.dst = try operand.decodeVectorGpr(if (store) data else vdst);
    const addr = word1 & 0xff;
    inst.src0 = try operand.decodeVectorGpr(addr);
    const saddr = (word1 >> 16) & 0x7f;
    inst.src1 = if (segment == 0 or saddr == 0x7d or saddr == 0x7f)
        try operand.decodeVectorGpr(addr + 1)
    else
        try operand.decodeScalarSource(saddr);
    inst.src_count = 2;
    return inst;
}

fn dsInfo(id: u32) ?MemoryInfo {
    return switch (id) {
        0x00 => .{ .opcode = .ds_add_u32 },
        0x01 => .{ .opcode = .ds_sub_u32 },
        0x05 => .{ .opcode = .ds_min_i32 },
        0x06 => .{ .opcode = .ds_max_i32 },
        0x07 => .{ .opcode = .ds_min_u32 },
        0x08 => .{ .opcode = .ds_max_u32 },
        0x09 => .{ .opcode = .ds_and_b32 },
        0x0a => .{ .opcode = .ds_or_b32 },
        0x0b => .{ .opcode = .ds_xor_b32 },
        0x0d => .{ .opcode = .ds_write_b32 },
        0x0e, 0x0f => .{ .opcode = .ds_write2_b32, .words = 2 },
        0x36 => .{ .opcode = .ds_read_b32 },
        0x37, 0x38 => .{ .opcode = .ds_read2_b32, .words = 2 },
        0x39 => .{ .opcode = .ds_read_sbyte, .bits = 8, .signed = true },
        0x3a => .{ .opcode = .ds_read_ubyte, .bits = 8 },
        0x3b => .{ .opcode = .ds_read_sshort, .bits = 16, .signed = true },
        0x3c => .{ .opcode = .ds_read_ushort, .bits = 16 },
        0x4d => .{ .opcode = .ds_write_b64, .words = 2 },
        0x76 => .{ .opcode = .ds_read_b64, .words = 2 },
        0xde => .{ .opcode = .ds_write_b96, .words = 3 },
        0xdf => .{ .opcode = .ds_write_b128, .words = 4 },
        0xfe => .{ .opcode = .ds_read_b96, .words = 3 },
        0xff => .{ .opcode = .ds_read_b128, .words = 4 },
        else => null,
    };
}

pub fn decodeDs(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    const word0 = code[word_index];
    const word1 = code[word_index + 1];
    const id = (word0 >> 18) & 0xff;
    const offset0 = word0 & 0xff;
    const offset1 = (word0 >> 8) & 0xff;
    var inst = Instruction{ .pc = pc, .word = word0, .family = .ds, .opcode_id = id };
    inst.setRawWords(code, word_index, 2);
    inst.memory_offset = @intCast(offset0);
    inst.secondary_memory_offset = @intCast(offset1);
    inst.gds = (word0 >> 17) & 1 != 0;
    applyInfo(&inst, dsInfo(id), "DS opcode is not implemented");
    inst.dst = try operand.decodeVectorGpr((word1 >> 24) & 0xff);
    inst.src0 = try operand.decodeVectorGpr(word1 & 0xff);
    inst.src1 = try operand.decodeVectorGpr((word1 >> 8) & 0xff);
    inst.src2 = try operand.decodeVectorGpr((word1 >> 16) & 0xff);
    inst.src_count = switch (id) {
        0x0e, 0x0f => 3,
        0x0d, 0x00, 0x01, 0x05...0x0b => 2,
        else => 1,
    };
    return inst;
}

fn mimgOpcode(id: u32) isa.Opcode {
    return switch (id) {
        0x00 => .image_load,
        0x01 => .image_load_mip,
        0x08 => .image_store,
        0x09 => .image_store_mip,
        0x0e => .image_get_resinfo,
        0x11 => .image_atomic_add,
        0x15 => .image_atomic_umin,
        0x17 => .image_atomic_umax,
        0x18 => .image_atomic_and,
        0x19 => .image_atomic_or,
        0x1a => .image_atomic_xor,
        0x20...0x3f, 0x68...0x6f, 0xa0...0xbe => .image_sample,
        0x47, 0x48, 0x4f, 0x57, 0x58, 0x5f, 0x61 => .image_gather4,
        0x60 => .image_get_lod,
        else => .unsupported,
    };
}

fn bitCount4(mask: u4) u8 {
    return @intCast(@popCount(mask));
}

pub fn decodeMimg(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    const word0 = code[word_index];
    const word1 = code[word_index + 1];
    const id = ((word0 >> 18) & 0x7f) | ((word0 & 1) << 7);
    const nsa: u2 = @intCast((word0 >> 1) & 3);
    const word_count: u32 = 2 + @as(u32, nsa);
    if (word_index + word_count > code.len) return Error.TruncatedInstruction;
    const op = mimgOpcode(id);
    var inst = Instruction{
        .pc = pc,
        .word = word0,
        .family = .mimg,
        .opcode_id = id,
        .opcode = op,
        .image_nsa_words = nsa,
        .image_dimension = @enumFromInt((word0 >> 3) & 7),
    };
    inst.setRawWords(code, word_index, word_count);
    inst.data_mask = @intCast((word0 >> 8) & 0xf);
    inst.data_words = @max(1, bitCount4(inst.data_mask));
    inst.globally_coherent = (word0 >> 13) & 1 != 0;
    inst.system_coherent = (word0 >> 25) & 1 != 0;
    inst.image_sample_flags.a16 = (word1 >> 30) & 1 != 0;
    if (op == .image_sample) {
        switch (id) {
            0x20 => {},
            0x24 => inst.image_sample_flags.lod = true,
            0x25 => inst.image_sample_flags.bias = true,
            0x27 => inst.image_sample_flags.level_zero = true,
            else => {},
        }
    }
    inst.image_address_components = switch (inst.image_dimension) {
        .dim_1d => 1,
        .dim_2d => 2,
        .dim_3d, .dim_2d_array, .dim_2d_array_alt => 3,
        .dim_1d_array => 2,
        .dim_2d_msaa => 3,
        .dim_2d_msaa_array => 4,
    };
    for (0..@as(usize, nsa) * 4) |i| {
        inst.image_nsa_address[i] = @truncate(code[word_index + 2 + i / 4] >> @intCast((i % 4) * 8));
    }
    inst.dst = try operand.decodeVectorGpr((word1 >> 8) & 0xff);
    inst.src0 = try operand.decodeVectorGpr(word1 & 0xff);
    inst.src1 = try operand.decodeScalarSource(((word1 >> 16) & 0x1f) * 4);
    inst.src2 = try operand.decodeScalarSource(((word1 >> 21) & 0x1f) * 4);
    inst.src_count = 3;
    if (op == .unsupported) inst.unsupported_reason = "MIMG opcode is not implemented";
    return inst;
}

pub fn decodeExp(pc: u32, code: []const u32, word_index: u32) Error!Instruction {
    if (word_index + 1 >= code.len) return Error.TruncatedInstruction;
    const word0 = code[word_index];
    const word1 = code[word_index + 1];
    const target: u6 = @intCast((word0 >> 4) & 0x3f);
    const enable: u4 = @intCast(word0 & 0xf);
    var inst = Instruction{
        .pc = pc,
        .word = word0,
        .family = .exp,
        .opcode_id = target,
        .opcode = .exp,
        .export_target = target,
        .export_enable = enable,
        .export_compressed = (word0 >> 10) & 1 != 0,
        .export_done = (word0 >> 11) & 1 != 0,
        .export_valid_mask = (word0 >> 12) & 1 != 0,
    };
    inst.setRawWords(code, word_index, 2);
    inst.src0 = try operand.decodeVectorGpr(word1 & 0xff);
    inst.src1 = try operand.decodeVectorGpr((word1 >> 8) & 0xff);
    inst.src2 = try operand.decodeVectorGpr((word1 >> 16) & 0xff);
    inst.src3 = try operand.decodeVectorGpr((word1 >> 24) & 0xff);
    inst.src_count = if (enable == 0) 0 else if (inst.export_compressed) 2 else 4;
    return inst;
}

test "MUBUF keeps resource and address operands" {
    const code = [_]u32{ (@as(u32, 0x0c) << 18) | 0x24, (@as(u32, 7) << 24) | (@as(u32, 3) << 16) | (@as(u32, 9) << 8) | 4 };
    const inst = try decodeMubuf(0, &code, 0);
    try std.testing.expectEqual(isa.Opcode.buffer_load_dword, inst.opcode);
    try std.testing.expectEqual(@as(i32, 0x24), inst.memory_offset);
    try std.testing.expectEqual(@as(u32, 12), inst.src1.reg);
}

test "MIMG NSA words are retained in the instruction length" {
    const code = [_]u32{ (@as(u32, 0x20) << 18) | (2 << 1), 0, 0x0403_0201, 0x0807_0605 };
    const inst = try decodeMimg(0, &code, 0);
    try std.testing.expectEqual(@as(u32, 4), inst.word_count);
    try std.testing.expectEqual(@as(u8, 1), inst.image_nsa_address[0]);
    try std.testing.expectEqual(@as(u8, 8), inst.image_nsa_address[7]);
}

test "truncated EXP is rejected" {
    const code = [_]u32{0xf800_0000};
    try std.testing.expectError(Error.TruncatedInstruction, decodeExp(0, &code, 0));
}
