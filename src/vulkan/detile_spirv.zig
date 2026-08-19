// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Host compute SPIR-V that detiles a GFX10 surface using ComputeDetileParams.

const std = @import("std");

const storage_uniform: u32 = 2;
const storage_input: u32 = 1;
const storage_push: u32 = 8;
const storage_function: u32 = 7;
const param_members: u32 = 21;

const Builder = struct {
    gpa: std.mem.Allocator,
    words: std.ArrayList(u32) = .empty,
    next_id: u32 = 1,

    fn deinit(self: *Builder) void {
        self.words.deinit(self.gpa);
    }

    fn id(self: *Builder) u32 {
        const value = self.next_id;
        self.next_id += 1;
        return value;
    }

    fn emit(self: *Builder, opcode: u16, operands: []const u32) std.mem.Allocator.Error!void {
        const count: u16 = @intCast(1 + operands.len);
        try self.words.append(self.gpa, @as(u32, count) << 16 | opcode);
        try self.words.appendSlice(self.gpa, operands);
    }

    fn emitString(self: *Builder, opcode: u16, prefix: []const u32, text: []const u8) std.mem.Allocator.Error!void {
        const padded = text.len / 4 + 1;
        var scratch: [8]u32 = @splat(0);
        const bytes = std.mem.asBytes(&scratch);
        @memcpy(bytes[0..text.len], text);
        try self.emit(opcode, prefix);
        // emit() already wrote the opcode word with the wrong count. Patch it.
        const added: u16 = @intCast(padded);
        self.words.items[self.words.items.len - 1 - prefix.len] += @as(u32, added) << 16;
        try self.words.appendSlice(self.gpa, scratch[0..padded]);
    }

    fn tyVoid(self: *Builder) std.mem.Allocator.Error!u32 {
        const result = self.id();
        try self.emit(19, &.{result});
        return result;
    }

    fn tyBool(self: *Builder) std.mem.Allocator.Error!u32 {
        const result = self.id();
        try self.emit(20, &.{result});
        return result;
    }

    fn tyInt(self: *Builder) std.mem.Allocator.Error!u32 {
        const result = self.id();
        try self.emit(21, &.{ result, 32, 0 });
        return result;
    }

    fn constant(self: *Builder, ty: u32, value: u32) std.mem.Allocator.Error!u32 {
        const result = self.id();
        try self.emit(43, &.{ ty, result, value });
        return result;
    }

    fn bin(self: *Builder, opcode: u16, ty: u32, lhs: u32, rhs: u32) std.mem.Allocator.Error!u32 {
        const result = self.id();
        try self.emit(opcode, &.{ ty, result, lhs, rhs });
        return result;
    }

    fn sel(self: *Builder, ty: u32, cond: u32, a: u32, b: u32) std.mem.Allocator.Error!u32 {
        const result = self.id();
        try self.emit(169, &.{ ty, result, cond, a, b });
        return result;
    }
};

/// One compute module: binding 0 is tiled source, binding 1 is linear dest.
pub fn build(gpa: std.mem.Allocator) std.mem.Allocator.Error![]u32 {
    var b = Builder{ .gpa = gpa };
    errdefer b.deinit();
    try b.words.appendSlice(gpa, &.{ 0x0723_0203, 0x0001_0000, 0, 0, 0 });

    try b.emit(17, &.{1}); // Capability Shader
    try b.emit(14, &.{ 0, 1 }); // Logical GLSL450

    const void_ty = try b.tyVoid();
    const bool_ty = try b.tyBool();
    const uint_ty = try b.tyInt();
    const uvec3_ty = b.id();
    try b.emit(23, &.{ uvec3_ty, uint_ty, 3 });
    const runtime_ty = b.id();
    try b.emit(29, &.{ runtime_ty, uint_ty });
    const ssbo_ty = b.id();
    try b.emit(30, &.{ ssbo_ty, runtime_ty });
    const params_ty = b.id();
    var members: [param_members + 1]u32 = undefined;
    members[0] = params_ty;
    for (members[1..]) |*slot| slot.* = uint_ty;
    try b.emit(30, &members);
    const ptr_fn_uint = b.id();
    try b.emit(32, &.{ ptr_fn_uint, storage_function, uint_ty });
    const ptr_uni_uint = b.id();
    try b.emit(32, &.{ ptr_uni_uint, storage_uniform, uint_ty });
    const ptr_ssbo = b.id();
    try b.emit(32, &.{ ptr_ssbo, storage_uniform, ssbo_ty });
    const ptr_params = b.id();
    try b.emit(32, &.{ ptr_params, storage_push, params_ty });
    const ptr_uvec3 = b.id();
    try b.emit(32, &.{ ptr_uvec3, storage_input, uvec3_ty });
    const fn_ty = b.id();
    try b.emit(33, &.{ fn_ty, void_ty });

    const src_var = b.id();
    const dst_var = b.id();
    const params_var = b.id();
    const gid_var = b.id();
    const main_fn = b.id();

    // Names / decorations have to appear before types in a spec-perfect module,
    // but Vulkan loaders accept decorations after types as long as IDs exist.
    try b.emit(71, &.{ runtime_ty, 6, 4 }); // ArrayStride 4
    try b.emit(71, &.{ ssbo_ty, 3 }); // BufferBlock
    try b.emit(72, &.{ ssbo_ty, 0, 35, 0 }); // member Offset 0
    try b.emit(71, &.{ src_var, 34, 0 }); // DescriptorSet
    try b.emit(71, &.{ src_var, 33, 0 }); // Binding 0
    try b.emit(71, &.{ src_var, 24 }); // NonWritable
    try b.emit(71, &.{ dst_var, 34, 0 });
    try b.emit(71, &.{ dst_var, 33, 1 });
    try b.emit(71, &.{ params_ty, 2 }); // Block
    var member: u32 = 0;
    while (member < param_members) : (member += 1) {
        try b.emit(72, &.{ params_ty, member, 35, member * 4 });
    }
    try b.emit(71, &.{ gid_var, 11, 28 }); // BuiltIn GlobalInvocationId

    try b.emit(15, &.{ 5, main_fn, 0x6e69616d, 0, gid_var }); // EntryPoint "main"
    try b.emit(16, &.{ main_fn, 17, 8, 8, 1 }); // LocalSize 8 8 1

    try b.emit(59, &.{ ptr_ssbo, src_var, storage_uniform });
    try b.emit(59, &.{ ptr_ssbo, dst_var, storage_uniform });
    try b.emit(59, &.{ ptr_params, params_var, storage_push });
    try b.emit(59, &.{ ptr_uvec3, gid_var, storage_input });

    const c0 = try b.constant(uint_ty, 0);
    const c1 = try b.constant(uint_ty, 1);
    const c2 = try b.constant(uint_ty, 2);
    const c3 = try b.constant(uint_ty, 3);
    const c4 = try b.constant(uint_ty, 4);
    const c8 = try b.constant(uint_ty, 8);
    const c16 = try b.constant(uint_ty, 16);

    try b.emit(54, &.{ void_ty, main_fn, 0, fn_ty });
    const entry = b.id();
    try b.emit(248, &.{entry});

    const gid = b.id();
    try b.emit(61, &.{ uvec3_ty, gid, gid_var });
    const x = b.id();
    const y = b.id();
    const z = b.id();
    try b.emit(81, &.{ uint_ty, x, gid, 0 });
    try b.emit(81, &.{ uint_ty, y, gid, 1 });
    try b.emit(81, &.{ uint_ty, z, gid, 2 });

    const width = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 4);
    const height = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 5);
    const depth = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 6);
    const oob_x = try b.bin(177, bool_ty, x, width);
    const oob_y = try b.bin(177, bool_ty, y, height);
    const oob_z = try b.bin(177, bool_ty, z, depth);
    const oob_xy = try b.bin(166, bool_ty, oob_x, oob_y);
    const oob = try b.bin(166, bool_ty, oob_xy, oob_z);
    const merge = b.id();
    const body = b.id();
    try b.emit(247, &.{ merge, 0 });
    try b.emit(250, &.{ oob, merge, body });
    try b.emit(248, &.{body});

    const src_lo = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 0);
    const dst_lo = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 2);
    const flags = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 20);
    const bpp_log = try b.bin(199, uint_ty, try b.bin(194, uint_ty, flags, c4), try b.constant(uint_ty, 0xf));
    const bpp = try b.bin(196, uint_ty, c1, bpp_log);
    const family = try b.bin(199, uint_ty, try b.bin(194, uint_ty, flags, c8), try b.constant(uint_ty, 0xff));
    const tail_x = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 18);
    const tail_y = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 19);
    const block_w = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 10);
    const block_h = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 11);
    const block_bytes = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 13);
    const blocks_per_row = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 14);
    const source_slice = try loadParam(&b, uint_ty, ptr_fn_uint, params_var, 16);
    const sx = try b.bin(128, uint_ty, x, tail_x);
    const sy = try b.bin(128, uint_ty, y, tail_y);
    const block_x = try b.bin(134, uint_ty, sx, block_w);
    const block_y = try b.bin(134, uint_ty, sy, block_h);
    const block_index = try b.bin(128, uint_ty, try b.bin(132, uint_ty, block_y, blocks_per_row), block_x);
    const local_x = try b.bin(137, uint_ty, sx, block_w);
    const local_y = try b.bin(137, uint_ty, sy, block_h);
    const local = try xor64k4(&b, uint_ty, local_x, local_y);
    const local_4k = try xor4k4(&b, uint_ty, local_x, local_y);
    const is_4k = try b.bin(170, bool_ty, family, c2);
    const is_256 = try b.bin(170, bool_ty, family, c1);
    const masked_256 = try b.bin(199, uint_ty, local_4k, try b.constant(uint_ty, 0xff));
    const pick_256 = try b.sel(uint_ty, is_256, masked_256, local);
    const pick_local = try b.sel(uint_ty, is_4k, local_4k, pick_256);
    const slice_term = try b.bin(132, uint_ty, z, source_slice);
    const block_term = try b.bin(132, uint_ty, block_index, block_bytes);
    const tiled = try b.bin(128, uint_ty, block_term, pick_local);
    const linear_row = try b.bin(132, uint_ty, blocks_per_row, bpp);
    const linear = try b.bin(128, uint_ty, try b.bin(132, uint_ty, y, linear_row), try b.bin(132, uint_ty, x, bpp));
    const is_linear = try b.bin(170, bool_ty, family, c0);
    const rel = try b.sel(uint_ty, is_linear, linear, tiled);
    const src_byte = try b.bin(128, uint_ty, try b.bin(128, uint_ty, src_lo, slice_term), rel);
    const dest_texel = try b.bin(128, uint_ty, try b.bin(132, uint_ty, try b.bin(128, uint_ty, try b.bin(132, uint_ty, z, height), y), width), x);
    const dest_byte = try b.bin(128, uint_ty, dst_lo, try b.bin(132, uint_ty, dest_texel, bpp));
    const src_word = try b.bin(134, uint_ty, src_byte, c4);
    const dst_word = try b.bin(134, uint_ty, dest_byte, c4);

    try copyWords(&b, uint_ty, bool_ty, ptr_uni_uint, src_var, dst_var, src_word, dst_word, bpp, c0, c1, c2, c3, c8, c16);

    try b.emit(249, &.{merge});
    try b.emit(248, &.{merge});
    try b.emit(253, &.{});
    try b.emit(56, &.{});

    b.words.items[3] = b.next_id;
    return try b.words.toOwnedSlice(gpa);
}

fn loadParam(b: *Builder, uint_ty: u32, ptr_ty: u32, params: u32, index: u32) std.mem.Allocator.Error!u32 {
    const idx = try b.constant(uint_ty, index);
    const ptr = b.id();
    try b.emit(65, &.{ ptr_ty, ptr, params, idx });
    const value = b.id();
    try b.emit(61, &.{ uint_ty, value, ptr });
    return value;
}

fn copyWords(
    b: *Builder,
    uint_ty: u32,
    bool_ty: u32,
    ptr_ty: u32,
    src_var: u32,
    dst_var: u32,
    src_word: u32,
    dst_word: u32,
    bpp: u32,
    c0: u32,
    c1: u32,
    c2: u32,
    c3: u32,
    c8: u32,
    c16: u32,
) std.mem.Allocator.Error!void {
    try storeLoaded(b, uint_ty, ptr_ty, src_var, dst_var, src_word, dst_word, c0);
    const ge8 = try b.bin(177, bool_ty, bpp, c8);
    try storeIf(b, uint_ty, bool_ty, ptr_ty, src_var, dst_var, src_word, dst_word, c1, ge8, c0);
    const ge16 = try b.bin(177, bool_ty, bpp, c16);
    try storeIf(b, uint_ty, bool_ty, ptr_ty, src_var, dst_var, src_word, dst_word, c2, ge16, c0);
    try storeIf(b, uint_ty, bool_ty, ptr_ty, src_var, dst_var, src_word, dst_word, c3, ge16, c0);
}

fn storeLoaded(
    b: *Builder,
    uint_ty: u32,
    ptr_ty: u32,
    src_var: u32,
    dst_var: u32,
    src_word: u32,
    dst_word: u32,
    extra: u32,
) std.mem.Allocator.Error!void {
    const src_index = if (extra == 0) src_word else try b.bin(128, uint_ty, src_word, extra);
    const dst_index = if (extra == 0) dst_word else try b.bin(128, uint_ty, dst_word, extra);
    const zero = extra;
    _ = zero;
    const c0 = try b.constant(uint_ty, 0);
    const src_ptr = b.id();
    try b.emit(65, &.{ ptr_ty, src_ptr, src_var, c0, src_index });
    const value = b.id();
    try b.emit(61, &.{ uint_ty, value, src_ptr });
    const dst_ptr = b.id();
    try b.emit(65, &.{ ptr_ty, dst_ptr, dst_var, c0, dst_index });
    try b.emit(62, &.{ dst_ptr, value });
}

fn storeIf(
    b: *Builder,
    uint_ty: u32,
    bool_ty: u32,
    ptr_ty: u32,
    src_var: u32,
    dst_var: u32,
    src_word: u32,
    dst_word: u32,
    extra: u32,
    cond: u32,
    c0: u32,
) std.mem.Allocator.Error!void {
    _ = bool_ty;
    const src_index = try b.bin(128, uint_ty, src_word, extra);
    const dst_index = try b.bin(128, uint_ty, dst_word, extra);
    const src_ptr = b.id();
    try b.emit(65, &.{ ptr_ty, src_ptr, src_var, c0, src_index });
    const src_val = b.id();
    try b.emit(61, &.{ uint_ty, src_val, src_ptr });
    const dst_ptr = b.id();
    try b.emit(65, &.{ ptr_ty, dst_ptr, dst_var, c0, dst_index });
    const dst_val = b.id();
    try b.emit(61, &.{ uint_ty, dst_val, dst_ptr });
    const picked = try b.sel(uint_ty, cond, src_val, dst_val);
    try b.emit(62, &.{ dst_ptr, picked });
}

fn xor4k4(b: *Builder, uint_ty: u32, x: u32, y: u32) std.mem.Allocator.Error!u32 {
    var acc = try shiftAnd(b, uint_ty, y, 4, 0x070);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 5, 0x100);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 6, 0x400);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 2, 0x00c);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 5, 0x080);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 6, 0x200);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 7, 0x800);
    return acc;
}

fn xor64k4(b: *Builder, uint_ty: u32, x: u32, y: u32) std.mem.Allocator.Error!u32 {
    var acc = try shiftAnd(b, uint_ty, x, 2, 0x000c);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 5, 0x0080);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 6, 0x0200);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 7, 0x0800);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 8, 0x2000);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 9, 0x8000);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 4, 0x0070);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 5, 0x0100);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 6, 0x0400);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 7, 0x1000);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 8, 0x4000);
    return acc;
}

fn shiftAnd(b: *Builder, uint_ty: u32, value: u32, shift: u32, mask: u32) std.mem.Allocator.Error!u32 {
    const shifted = try b.bin(196, uint_ty, value, try b.constant(uint_ty, shift));
    return b.bin(199, uint_ty, shifted, try b.constant(uint_ty, mask));
}

fn xorShiftAnd(b: *Builder, uint_ty: u32, acc: u32, value: u32, shift: u32, mask: u32) std.mem.Allocator.Error!u32 {
    return b.bin(198, uint_ty, acc, try shiftAnd(b, uint_ty, value, shift, mask));
}

test "detile SPIR-V is a well-formed compute module" {
    const words = try build(std.testing.allocator);
    defer std.testing.allocator.free(words);
    try std.testing.expect(words.len > 20);
    try std.testing.expectEqual(@as(u32, 0x0723_0203), words[0]);
    try std.testing.expect(words[3] > 8);
}
