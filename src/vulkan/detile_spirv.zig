// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Host compute SPIR-V that detiles a GFX10 surface using ComputeDetileParams.

const std = @import("std");

const storage_uniform: u32 = 2;
const storage_input: u32 = 1;
const storage_push: u32 = 9;
const storage_function: u32 = 7;
const param_members: u32 = 21;

const Builder = struct {
    gpa: std.mem.Allocator,
    words: std.ArrayList(u32) = .empty,
    function_words: std.ArrayList(u32) = .empty,
    emitting_function: bool = false,
    next_id: u32 = 1,

    fn deinit(self: *Builder) void {
        self.words.deinit(self.gpa);
        self.function_words.deinit(self.gpa);
    }

    fn id(self: *Builder) u32 {
        const value = self.next_id;
        self.next_id += 1;
        return value;
    }

    fn emit(self: *Builder, opcode: u16, operands: []const u32) std.mem.Allocator.Error!void {
        const count: u16 = @intCast(1 + operands.len);
        const destination = if (self.emitting_function) &self.function_words else &self.words;
        try destination.append(self.gpa, @as(u32, count) << 16 | opcode);
        try destination.appendSlice(self.gpa, operands);
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
        const was_emitting_function = self.emitting_function;
        self.emitting_function = false;
        defer self.emitting_function = was_emitting_function;
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

    // Allocate every module-scope ID up front so instructions can be emitted
    // in SPIR-V's required logical layout order.
    const void_ty = b.id();
    const bool_ty = b.id();
    const uint_ty = b.id();
    const uvec3_ty = b.id();
    const runtime_ty = b.id();
    const ssbo_ty = b.id();
    const params_ty = b.id();
    const ptr_push_uint = b.id();
    const ptr_uni_uint = b.id();
    const ptr_ssbo = b.id();
    const ptr_params = b.id();
    const ptr_uvec3 = b.id();
    const fn_ty = b.id();
    const src_var = b.id();
    const dst_var = b.id();
    const params_var = b.id();
    const gid_var = b.id();
    const main_fn = b.id();

    try b.emit(15, &.{ 5, main_fn, 0x6e69616d, 0, gid_var }); // EntryPoint "main"
    try b.emit(16, &.{ main_fn, 17, 8, 8, 1 }); // LocalSize 8 8 1

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

    try b.emit(19, &.{void_ty});
    try b.emit(20, &.{bool_ty});
    try b.emit(21, &.{ uint_ty, 32, 0 });
    try b.emit(23, &.{ uvec3_ty, uint_ty, 3 });
    try b.emit(29, &.{ runtime_ty, uint_ty });
    try b.emit(30, &.{ ssbo_ty, runtime_ty });
    var members: [param_members + 1]u32 = undefined;
    members[0] = params_ty;
    for (members[1..]) |*slot| slot.* = uint_ty;
    try b.emit(30, &members);
    try b.emit(32, &.{ ptr_push_uint, storage_push, uint_ty });
    try b.emit(32, &.{ ptr_uni_uint, storage_uniform, uint_ty });
    try b.emit(32, &.{ ptr_ssbo, storage_uniform, ssbo_ty });
    try b.emit(32, &.{ ptr_params, storage_push, params_ty });
    try b.emit(32, &.{ ptr_uvec3, storage_input, uvec3_ty });
    try b.emit(33, &.{ fn_ty, void_ty });

    try b.emit(59, &.{ ptr_ssbo, src_var, storage_uniform });
    try b.emit(59, &.{ ptr_ssbo, dst_var, storage_uniform });
    try b.emit(59, &.{ ptr_params, params_var, storage_push });
    try b.emit(59, &.{ ptr_uvec3, gid_var, storage_input });

    const c0 = try b.constant(uint_ty, 0);
    const c1 = try b.constant(uint_ty, 1);
    const c2 = try b.constant(uint_ty, 2);
    const c4 = try b.constant(uint_ty, 4);
    const c8 = try b.constant(uint_ty, 8);

    b.emitting_function = true;
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

    const width = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 4);
    const height = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 5);
    const depth = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 6);
    const oob_x = try b.bin(174, bool_ty, x, width); // UGreaterThanEqual
    const oob_y = try b.bin(174, bool_ty, y, height);
    const oob_z = try b.bin(174, bool_ty, z, depth);
    const oob_xy = try b.bin(166, bool_ty, oob_x, oob_y);
    const oob = try b.bin(166, bool_ty, oob_xy, oob_z);
    const merge = b.id();
    const body = b.id();
    try b.emit(247, &.{ merge, 0 });
    try b.emit(250, &.{ oob, merge, body });
    try b.emit(248, &.{body});

    const src_lo = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 0);
    const dst_lo = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 2);
    const flags = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 20);
    const bpp_log = try b.bin(199, uint_ty, try b.bin(194, uint_ty, flags, c4), try b.constant(uint_ty, 0xf));
    const bpp = try b.bin(196, uint_ty, c1, bpp_log);
    const family = try b.bin(199, uint_ty, try b.bin(194, uint_ty, flags, c8), try b.constant(uint_ty, 0xff));
    const kind = try b.bin(199, uint_ty, try b.bin(194, uint_ty, flags, try b.constant(uint_ty, 24)), try b.constant(uint_ty, 0xff));
    const tail_x = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 18);
    const tail_y = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 19);
    const block_w = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 10);
    const block_h = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 11);
    const block_d_raw = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 12);
    const block_bytes = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 13);
    const blocks_per_row = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 14);
    const source_slice = try loadParam(&b, uint_ty, ptr_push_uint, params_var, 16);
    const is_volume = try b.bin(170, bool_ty, kind, c1);
    const block_d = try b.sel(uint_ty, try b.bin(170, bool_ty, block_d_raw, c0), c1, block_d_raw);
    const block_z = try b.sel(uint_ty, is_volume, try b.bin(134, uint_ty, z, block_d), z);
    const swizzle_z = try b.sel(uint_ty, is_volume, try b.bin(137, uint_ty, z, block_d), c0);
    const sx = try b.bin(128, uint_ty, x, tail_x);
    const sy = try b.bin(128, uint_ty, y, tail_y);
    const safe_w = try b.sel(uint_ty, try b.bin(170, bool_ty, block_w, c0), c1, block_w);
    const safe_h = try b.sel(uint_ty, try b.bin(170, bool_ty, block_h, c0), c1, block_h);
    const block_x = try b.bin(134, uint_ty, sx, safe_w);
    const block_y = try b.bin(134, uint_ty, sy, safe_h);
    const block_index = try b.bin(128, uint_ty, try b.bin(132, uint_ty, block_y, blocks_per_row), block_x);
    const local_x = try b.bin(137, uint_ty, sx, safe_w);
    const local_y = try b.bin(137, uint_ty, sy, safe_h);
    const local_4k = try xor4k(&b, uint_ty, bool_ty, bpp_log, local_x, local_y);
    const local_64k = try xor64k(&b, uint_ty, bool_ty, bpp_log, local_x, local_y);
    const local_256 = try b.bin(199, uint_ty, local_4k, try b.constant(uint_ty, 0xff));
    const local_prt = try xorPrt2d(&b, uint_ty, bool_ty, bpp_log, local_x, local_y, local_64k);
    const local_4k_3d = try xor4k3d(&b, uint_ty, bool_ty, bpp_log, local_x, local_y, swizzle_z);
    const local_64k_3d = try xor64k3d(&b, uint_ty, bool_ty, bpp_log, local_x, local_y, swizzle_z, local_4k_3d);
    const local_prt_3d = try xorPrt3d(&b, uint_ty, bool_ty, bpp_log, local_x, local_y, swizzle_z, local_64k_3d);
    const c3 = try b.constant(uint_ty, 3);
    const c5 = try b.constant(uint_ty, 5);
    const c6 = try b.constant(uint_ty, 6);
    const c7 = try b.constant(uint_ty, 7);
    var pick_local = local_64k;
    pick_local = try b.sel(uint_ty, try b.bin(170, bool_ty, family, c1), local_256, pick_local);
    pick_local = try b.sel(uint_ty, try b.bin(170, bool_ty, family, c2), local_4k, pick_local);
    pick_local = try b.sel(uint_ty, try b.bin(170, bool_ty, family, c3), local_4k_3d, pick_local);
    pick_local = try b.sel(uint_ty, try b.bin(170, bool_ty, family, c4), local_64k, pick_local);
    pick_local = try b.sel(uint_ty, try b.bin(170, bool_ty, family, c5), local_64k_3d, pick_local);
    pick_local = try b.sel(uint_ty, try b.bin(170, bool_ty, family, c6), local_prt, pick_local);
    pick_local = try b.sel(uint_ty, try b.bin(170, bool_ty, family, c7), local_prt_3d, pick_local);
    const slice_term = try b.bin(132, uint_ty, block_z, source_slice);
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

    try storeLoaded(&b, uint_ty, ptr_uni_uint, src_var, dst_var, src_word, dst_word, c0);
    const need8 = try b.bin(174, bool_ty, bpp_log, c3); // UGreaterThanEqual 3 => 8-byte elements
    const merge8 = b.id();
    const body8 = b.id();
    try b.emit(247, &.{ merge8, 0 });
    try b.emit(250, &.{ need8, body8, merge8 });
    try b.emit(248, &.{body8});
    try storeLoaded(&b, uint_ty, ptr_uni_uint, src_var, dst_var, src_word, dst_word, c1);
    const need16 = try b.bin(174, bool_ty, bpp_log, c4); // UGreaterThanEqual 4 => 16-byte elements
    const merge16 = b.id();
    const body16 = b.id();
    try b.emit(247, &.{ merge16, 0 });
    try b.emit(250, &.{ need16, body16, merge16 });
    try b.emit(248, &.{body16});
    try storeLoaded(&b, uint_ty, ptr_uni_uint, src_var, dst_var, src_word, dst_word, c2);
    try storeLoaded(&b, uint_ty, ptr_uni_uint, src_var, dst_var, src_word, dst_word, c3);
    try b.emit(249, &.{merge16});
    try b.emit(248, &.{merge16});
    try b.emit(249, &.{merge8});
    try b.emit(248, &.{merge8});

    try b.emit(249, &.{merge});
    try b.emit(248, &.{merge});
    try b.emit(253, &.{});
    try b.emit(56, &.{});

    b.emitting_function = false;
    try b.words.appendSlice(gpa, b.function_words.items);
    b.function_words.deinit(gpa);
    b.function_words = .empty;
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

fn xor4k8(b: *Builder, uint_ty: u32, x: u32, y: u32) std.mem.Allocator.Error!u32 {
    var acc = try shiftAnd(b, uint_ty, y, 4, 0x030);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 6, 0x100);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 7, 0x400);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 3, 0x008);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 5, 0x0c0);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 6, 0x200);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 7, 0x800);
    return acc;
}

fn xor4k16(b: *Builder, uint_ty: u32, x: u32, y: u32) std.mem.Allocator.Error!u32 {
    var acc = try shiftAnd(b, uint_ty, y, 4, 0x030);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 6, 0x100);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 7, 0x400);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 6, 0x0c0);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 7, 0x200);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 8, 0x800);
    return acc;
}

fn xor4k(b: *Builder, uint_ty: u32, bool_ty: u32, bpp_log: u32, x: u32, y: u32) std.mem.Allocator.Error!u32 {
    const v4 = try xor4k4(b, uint_ty, x, y);
    const v8 = try xor4k8(b, uint_ty, x, y);
    const v16 = try xor4k16(b, uint_ty, x, y);
    return pickBpp(b, uint_ty, bool_ty, bpp_log, v4, v8, v16);
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

fn xor64k8(b: *Builder, uint_ty: u32, x: u32, y: u32) std.mem.Allocator.Error!u32 {
    var acc = try shiftAnd(b, uint_ty, x, 3, 0x0008);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 5, 0x00c0);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 6, 0x0200);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 7, 0x0800);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 8, 0x2000);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 9, 0x8000);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 4, 0x0030);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 6, 0x0100);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 7, 0x0400);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 8, 0x1000);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 9, 0x4000);
    return acc;
}

fn xor64k16(b: *Builder, uint_ty: u32, x: u32, y: u32) std.mem.Allocator.Error!u32 {
    var acc = try shiftAnd(b, uint_ty, x, 6, 0x00c0);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 7, 0x0200);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 8, 0x0800);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 9, 0x2000);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 10, 0x8000);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 4, 0x0030);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 6, 0x0100);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 7, 0x0400);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 8, 0x1000);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 9, 0x4000);
    return acc;
}

fn xor64k(b: *Builder, uint_ty: u32, bool_ty: u32, bpp_log: u32, x: u32, y: u32) std.mem.Allocator.Error!u32 {
    const v4 = try xor64k4(b, uint_ty, x, y);
    const v8 = try xor64k8(b, uint_ty, x, y);
    const v16 = try xor64k16(b, uint_ty, x, y);
    return pickBpp(b, uint_ty, bool_ty, bpp_log, v4, v8, v16);
}

fn xor4k3d4(b: *Builder, uint_ty: u32, x: u32, y: u32, z: u32) std.mem.Allocator.Error!u32 {
    var acc = try shiftAnd(b, uint_ty, x, 2, 0x004);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 5, 0x040);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 7, 0x200);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 3, 0x008);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 4, 0x020);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 6, 0x100);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 8, 0x800);
    acc = try xorShiftAnd(b, uint_ty, acc, z, 4, 0x010);
    acc = try xorShiftAnd(b, uint_ty, acc, z, 6, 0x080);
    acc = try xorShiftAnd(b, uint_ty, acc, z, 8, 0x400);
    return acc;
}

fn xor4k3d8(b: *Builder, uint_ty: u32, x: u32, y: u32, z: u32) std.mem.Allocator.Error!u32 {
    var acc = try shiftAnd(b, uint_ty, x, 3, 0x008);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 5, 0x040);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 7, 0x200);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 5, 0x020);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 7, 0x100);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 9, 0x800);
    acc = try xorShiftAnd(b, uint_ty, acc, z, 4, 0x010);
    acc = try xorShiftAnd(b, uint_ty, acc, z, 6, 0x080);
    acc = try xorShiftAnd(b, uint_ty, acc, z, 8, 0x400);
    return acc;
}

fn xor4k3d16(b: *Builder, uint_ty: u32, x: u32, y: u32, z: u32) std.mem.Allocator.Error!u32 {
    var acc = try shiftAnd(b, uint_ty, x, 6, 0x040);
    acc = try xorShiftAnd(b, uint_ty, acc, x, 8, 0x200);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 5, 0x020);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 7, 0x100);
    acc = try xorShiftAnd(b, uint_ty, acc, y, 9, 0x800);
    acc = try xorShiftAnd(b, uint_ty, acc, z, 4, 0x010);
    acc = try xorShiftAnd(b, uint_ty, acc, z, 6, 0x080);
    acc = try xorShiftAnd(b, uint_ty, acc, z, 8, 0x400);
    return acc;
}

fn xor4k3d(b: *Builder, uint_ty: u32, bool_ty: u32, bpp_log: u32, x: u32, y: u32, z: u32) std.mem.Allocator.Error!u32 {
    const v4 = try xor4k3d4(b, uint_ty, x, y, z);
    const v8 = try xor4k3d8(b, uint_ty, x, y, z);
    const v16 = try xor4k3d16(b, uint_ty, x, y, z);
    return pickBpp(b, uint_ty, bool_ty, bpp_log, v4, v8, v16);
}

fn xor64k3d(
    b: *Builder,
    uint_ty: u32,
    bool_ty: u32,
    bpp_log: u32,
    x: u32,
    y: u32,
    z: u32,
    base: u32,
) std.mem.Allocator.Error!u32 {
    // Extra bits on top of the 4 KiB 3D offset, matching standard64k3dOffset.
    const extra4 = try xorBits(b, uint_ty, &.{
        try bitTerm(b, uint_ty, x, 3, 12),
        try bitTerm(b, uint_ty, z, 3, 13),
        try bitTerm(b, uint_ty, y, 4, 14),
        try bitTerm(b, uint_ty, x, 4, 15),
    });
    const extra8 = try xorBits(b, uint_ty, &.{
        try bitTerm(b, uint_ty, x, 3, 12),
        try bitTerm(b, uint_ty, z, 3, 13),
        try bitTerm(b, uint_ty, y, 3, 14),
        try bitTerm(b, uint_ty, x, 4, 15),
    });
    const extra16 = try xorBits(b, uint_ty, &.{
        try bitTerm(b, uint_ty, x, 2, 12),
        try bitTerm(b, uint_ty, z, 3, 13),
        try bitTerm(b, uint_ty, y, 3, 14),
        try bitTerm(b, uint_ty, x, 3, 15),
    });
    const extra = try pickBpp(b, uint_ty, bool_ty, bpp_log, extra4, extra8, extra16);
    return b.bin(198, uint_ty, base, extra);
}

fn xorPrt2d(
    b: *Builder,
    uint_ty: u32,
    bool_ty: u32,
    bpp_log: u32,
    x: u32,
    y: u32,
    base: u32,
) std.mem.Allocator.Error!u32 {
    const extra4 = try xorBits(b, uint_ty, &.{
        try bitTerm(b, uint_ty, x, 6, 8),
        try bitTerm(b, uint_ty, y, 6, 9),
        try bitTerm(b, uint_ty, x, 5, 10),
        try bitTerm(b, uint_ty, y, 5, 11),
    });
    const extra8 = try xorBits(b, uint_ty, &.{
        try bitTerm(b, uint_ty, x, 6, 8),
        try bitTerm(b, uint_ty, y, 5, 9),
        try bitTerm(b, uint_ty, x, 5, 10),
        try bitTerm(b, uint_ty, y, 4, 11),
    });
    const extra16 = try xorBits(b, uint_ty, &.{
        try bitTerm(b, uint_ty, x, 5, 8),
        try bitTerm(b, uint_ty, y, 5, 9),
        try bitTerm(b, uint_ty, x, 4, 10),
        try bitTerm(b, uint_ty, y, 4, 11),
    });
    const extra = try pickBpp(b, uint_ty, bool_ty, bpp_log, extra4, extra8, extra16);
    return b.bin(198, uint_ty, base, extra);
}

fn xorPrt3d(
    b: *Builder,
    uint_ty: u32,
    bool_ty: u32,
    bpp_log: u32,
    x: u32,
    y: u32,
    z: u32,
    base: u32,
) std.mem.Allocator.Error!u32 {
    const extra4 = try xorBits(b, uint_ty, &.{
        try bitTerm(b, uint_ty, y, 4, 10),
        try bitTerm(b, uint_ty, x, 4, 10),
        try bitTerm(b, uint_ty, x, 3, 11),
        try bitTerm(b, uint_ty, z, 3, 11),
    });
    const extra8 = try xorBits(b, uint_ty, &.{
        try bitTerm(b, uint_ty, y, 3, 10),
        try bitTerm(b, uint_ty, x, 4, 10),
        try bitTerm(b, uint_ty, x, 3, 11),
        try bitTerm(b, uint_ty, z, 3, 11),
    });
    const extra16 = try xorBits(b, uint_ty, &.{
        try bitTerm(b, uint_ty, y, 3, 10),
        try bitTerm(b, uint_ty, x, 3, 10),
        try bitTerm(b, uint_ty, x, 2, 11),
        try bitTerm(b, uint_ty, z, 3, 11),
    });
    const extra = try pickBpp(b, uint_ty, bool_ty, bpp_log, extra4, extra8, extra16);
    return b.bin(198, uint_ty, base, extra);
}

fn pickBpp(b: *Builder, uint_ty: u32, bool_ty: u32, bpp_log: u32, v4: u32, v8: u32, v16: u32) std.mem.Allocator.Error!u32 {
    const c3 = try b.constant(uint_ty, 3);
    const c4 = try b.constant(uint_ty, 4);
    const is8 = try b.bin(170, bool_ty, bpp_log, c3);
    const is16 = try b.bin(170, bool_ty, bpp_log, c4);
    const pick8 = try b.sel(uint_ty, is8, v8, v4);
    return b.sel(uint_ty, is16, v16, pick8);
}

fn bitTerm(b: *Builder, uint_ty: u32, value: u32, src: u32, dst: u32) std.mem.Allocator.Error!u32 {
    const shifted = try b.bin(194, uint_ty, value, try b.constant(uint_ty, src));
    const bit = try b.bin(199, uint_ty, shifted, try b.constant(uint_ty, 1));
    return b.bin(196, uint_ty, bit, try b.constant(uint_ty, dst));
}

fn xorBits(b: *Builder, uint_ty: u32, terms: []const u32) std.mem.Allocator.Error!u32 {
    var acc = terms[0];
    for (terms[1..]) |term| acc = try b.bin(198, uint_ty, acc, term);
    return acc;
}

fn shiftAnd(b: *Builder, uint_ty: u32, value: u32, shift: u32, mask: u32) std.mem.Allocator.Error!u32 {
    const shifted = try b.bin(196, uint_ty, value, try b.constant(uint_ty, shift));
    return b.bin(199, uint_ty, shifted, try b.constant(uint_ty, mask));
}

fn xorShiftAnd(b: *Builder, uint_ty: u32, acc: u32, value: u32, shift: u32, mask: u32) std.mem.Allocator.Error!u32 {
    return b.bin(198, uint_ty, acc, try shiftAnd(b, uint_ty, value, shift, mask));
}

test "detile SPIR-V keeps Vulkan storage classes and logical layout" {
    const words = try build(std.testing.allocator);
    defer std.testing.allocator.free(words);
    try std.testing.expect(words.len > 20);
    try std.testing.expectEqual(@as(u32, 0x0723_0203), words[0]);
    try std.testing.expect(words[3] > 8);

    var offset: usize = 5;
    var in_function = false;
    var saw_entry_point = false;
    var saw_annotations = false;
    var saw_types = false;
    var saw_push_pointer = false;
    var saw_push_variable = false;
    var bounds_checks: u32 = 0;
    while (offset < words.len) {
        const instruction = words[offset];
        const word_count: usize = @intCast(instruction >> 16);
        const opcode: u16 = @truncate(instruction);
        try std.testing.expect(word_count != 0 and offset + word_count <= words.len);
        switch (opcode) {
            15 => { // OpEntryPoint
                try std.testing.expect(!saw_annotations and !saw_types);
                saw_entry_point = true;
            },
            71, 72 => { // OpDecorate / OpMemberDecorate
                try std.testing.expect(saw_entry_point and !saw_types and !in_function);
                saw_annotations = true;
            },
            19, 20, 21, 23, 29, 30, 32, 33 => { // Type declarations
                try std.testing.expect(saw_annotations and !in_function);
                saw_types = true;
                if (opcode == 32 and words[offset + 2] == storage_push) saw_push_pointer = true;
            },
            43 => try std.testing.expect(!in_function), // OpConstant
            54 => { // OpFunction
                try std.testing.expect(saw_types and !in_function);
                in_function = true;
            },
            56 => in_function = false, // OpFunctionEnd
            59 => { // OpVariable
                if (!in_function and words[offset + 3] == storage_push) saw_push_variable = true;
            },
            174 => bounds_checks += 1, // OpUGreaterThanEqual
            177 => return error.SignedBoundsCheck,
            else => {},
        }
        offset += word_count;
    }
    try std.testing.expectEqual(words.len, offset);
    try std.testing.expect(!in_function);
    try std.testing.expect(saw_push_pointer and saw_push_variable);
    try std.testing.expectEqual(@as(u32, 5), bounds_checks);
}
