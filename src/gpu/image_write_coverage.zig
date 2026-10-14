// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Conservative coverage proofs for straight-line compute image stores.
//! The pixel computation remains on the GPU. This only proves that every
//! texel of a rectangular output is overwritten, using affine workgroup
//! coordinates and exhaustive local invocation IDs. Unknown address maths,
//! execution masks, control flow and partial component stores opt out.
const std = @import("std");
const rdna2 = @import("rdna2");
const resources = @import("resources.zig");

pub export var rectangular_image_write_coverage: bool = true;

pub const Output = struct {
    resource_sgpr: u32,
    first_pc: u32,
    block_width: u32,
    block_height: u32,

    pub fn covers(self: Output, groups: [3]u32, width: u32, height: u32) bool {
        const x = @as(u64, groups[0]) * self.block_width;
        const y = @as(u64, groups[1]) * self.block_height;
        return groups[2] == 1 and width != 0 and height != 0 and x >= width and y >= height and
            x <= std.math.maxInt(u32) and y <= std.math.maxInt(u32);
    }
};

pub const Proof = struct {
    outputs: [4]Output = undefined,
    count: u8 = 0,
};

/// The immutable analysis identity prevents reuse after code replacement.
/// A failed proof is cached as well; animated draws must not repeat the
/// local-lane walk for a shader that cannot meet these conservative rules.
pub const Cache = struct {
    const Entry = struct {
        identity: u64,
        rectangular: bool,
        system: resources.ComputeSystemRegisters,
        local_size: [3]u32,
        proof: ?Proof,
    };
    entries: [128]?Entry = @splat(null),

    pub fn get(self: *Cache, identity: u64, instructions: []const rdna2.Instruction, system: resources.ComputeSystemRegisters, local_size: [3]u32) ?Proof {
        if (identity == 0) return null;
        const rectangular = @atomicLoad(bool, &rectangular_image_write_coverage, .monotonic);
        const slot = &self.entries[identity % self.entries.len];
        if (slot.*) |entry| if (entry.identity == identity and entry.rectangular == rectangular and std.meta.eql(entry.system, system) and
            std.meta.eql(entry.local_size, local_size)) return entry.proof;
        const proof = analyze(instructions, system, local_size);
        slot.* = .{ .identity = identity, .rectangular = rectangular, .system = system, .local_size = local_size, .proof = proof };
        return proof;
    }
};

// All arithmetic is modulo 2^32, as in the integer vector instructions.
// The final coordinates must be a small nonnegative tile plus one group
// component; covers() subsequently excludes wrap across the dispatch.
const Affine = struct {
    bias: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,

    fn constant(self: Affine) ?u32 {
        return if (self.x == 0 and self.y == 0) self.bias else null;
    }

    fn add(a: Affine, b: Affine) Affine {
        return .{ .bias = a.bias +% b.bias, .x = a.x +% b.x, .y = a.y +% b.y };
    }

    fn shift(a: Affine, amount: u32) Affine {
        const n: u5 = @truncate(amount);
        return .{ .bias = a.bias << n, .x = a.x << n, .y = a.y << n };
    }
};

fn plain(op: rdna2.Operand) bool {
    return op.sdwa_sel == 6 and op.sdwa_dst_unused == 0 and !op.explicit_sdwa_dst and
        op.omod == 0 and !op.sdwa_sext and !op.op_sel and !op.op_sel_hi and
        !op.negate and !op.negate_hi and !op.absolute and !op.clamp and !op.dpp and !op.dpp8;
}

const Registers = struct {
    vector: [256]?Affine = @splat(null),
    scalar: [128]?Affine = @splat(null),
    scalar_definitions: [128]u32 = @splat(0),

    fn get(self: *const Registers, op: rdna2.Operand) ?Affine {
        if (!plain(op)) return null;
        return switch (op.kind) {
            .vgpr => if (op.reg < self.vector.len) self.vector[op.reg] else null,
            .sgpr => if (op.reg < self.scalar.len) self.scalar[op.reg] else null,
            .integer_inline_constant, .literal_constant => .{ .bias = op.value },
            else => null,
        };
    }

    fn vectorWrite(self: *Registers, inst: rdna2.Instruction, value: ?Affine) bool {
        if (inst.dst.kind != .vgpr or inst.dst.reg >= self.vector.len) return false;
        self.vector[inst.dst.reg] = if (plain(inst.dst)) value else null;
        return true;
    }

    fn binary(self: *const Registers, inst: rdna2.Instruction) ?Affine {
        const a = self.get(inst.src0) orelse return null;
        const b = self.get(inst.src1) orelse return null;
        return switch (inst.opcode) {
            .v_add_nc_u32 => Affine.add(a, b),
            .v_lshlrev_b32 => b.shift(a.constant() orelse return null),
            .v_lshrrev_b32 => .{ .bias = (b.constant() orelse return null) >> @as(u5, @truncate(a.constant() orelse return null)) },
            .v_and_b32 => .{ .bias = (a.constant() orelse return null) & (b.constant() orelse return null) },
            .v_or_b32 => .{ .bias = (a.constant() orelse return null) | (b.constant() orelse return null) },
            .v_xor_b32 => .{ .bias = (a.constant() orelse return null) ^ (b.constant() orelse return null) },
            else => null,
        };
    }

    fn ternary(self: *const Registers, inst: rdna2.Instruction) ?Affine {
        const a = self.get(inst.src0) orelse return null;
        const b = self.get(inst.src1) orelse return null;
        const c = self.get(inst.src2) orelse return null;
        return switch (inst.opcode) {
            .v_add3_u32 => Affine.add(Affine.add(a, b), c),
            .v_lshl_add_u32 => Affine.add(a.shift(b.constant() orelse return null), c),
            .v_and_or_b32 => .{ .bias = ((a.constant() orelse return null) & (b.constant() orelse return null)) | (c.constant() orelse return null) },
            .v_bfe_u32 => blk: {
                const width = (c.constant() orelse return null) & 31;
                const mask = (@as(u32, 1) << @as(u5, @intCast(width))) - 1;
                break :blk .{ .bias = ((a.constant() orelse return null) >> @as(u5, @truncate(b.constant() orelse return null))) & mask };
            },
            else => null,
        };
    }
};

const Tile = struct {
    output: Output,
    definitions: [8]u32,
    pixels: std.StaticBitSet(4096) = .initEmpty(),
};

fn addressRegister(inst: rdna2.Instruction, component: u32) ?u32 {
    if (inst.src0.kind != .vgpr) return null;
    if (component == 0) return inst.src0.reg;
    if (inst.image_nsa_words != 0) return inst.image_nsa_address[component - 1];
    return inst.src0.reg + component;
}

/// Deliberately excludes arbitrary buffers, atomics and shared memory. The
/// caller must additionally resolve every image input and reject physical
/// overlap with the output before it may omit initialization.
pub fn analyze(instructions: []const rdna2.Instruction, system: resources.ComputeSystemRegisters, local_size: [3]u32) ?Proof {
    const rectangular = @atomicLoad(bool, &rectangular_image_write_coverage, .monotonic);
    const threads = std.math.mul(u32, local_size[0], local_size[1]) catch return null;
    if (local_size[0] == 0 or local_size[1] == 0 or threads > 256 or local_size[2] != 1 or
        (!rectangular and (local_size[1] != 1 or system.local_invocation_id_components != 1)) or
        system.local_invocation_id_components == 0 or
        (local_size[1] > 1 and system.local_invocation_id_components < 2) or system.threadgroup_size_sgpr != null or
        system.workgroup_id_sgprs[0] == null or system.workgroup_id_sgprs[1] == null or
        system.workgroup_id_sgprs[0].? >= 128 or system.workgroup_id_sgprs[1].? >= 128 or
        system.workgroup_id_sgprs[0] == system.workgroup_id_sgprs[1] or
        system.workgroup_id_sgprs[2] != null or instructions.len == 0 or
        instructions[instructions.len - 1].opcode != .s_endpgm) return null;
    var tiles: [4]Tile = undefined;
    var count: usize = 0;
    for (0..threads) |lane| {
        var registers = Registers{};
        registers.vector[0] = .{ .bias = @intCast(lane % local_size[0]) };
        if (system.local_invocation_id_components >= 2) registers.vector[1] = .{ .bias = @intCast(lane / local_size[0]) };
        if (system.local_invocation_id_components >= 3) registers.vector[2] = .{};
        registers.scalar[system.workgroup_id_sgprs[0].?] = .{ .x = 1 };
        registers.scalar[system.workgroup_id_sgprs[1].?] = .{ .y = 1 };
        for (instructions, 0..) |inst, position| {
            switch (inst.opcode) {
                .s_endpgm => if (position != instructions.len - 1) return null,
                .s_nop, .s_inst_prefetch, .s_waitcnt => {},
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
                => {
                    if (inst.dst.kind == .vcc_lo or inst.dst.kind == .vcc_hi) {
                        if (inst.data_words == 0 or inst.data_words > (if (inst.dst.kind == .vcc_lo) @as(u8, 2) else 1)) return null;
                        continue;
                    }
                    if (inst.dst.kind != .sgpr or inst.data_words == 0 or inst.dst.reg + inst.data_words > 128) return null;
                    for (inst.dst.reg..inst.dst.reg + inst.data_words) |reg| {
                        registers.scalar[reg] = null;
                        registers.scalar_definitions[reg] = @intCast(position + 1);
                    }
                },
                .v_mov_b32 => if (!registers.vectorWrite(inst, registers.get(inst.src0))) return null,
                .v_add_nc_u32, .v_lshlrev_b32, .v_lshrrev_b32, .v_and_b32, .v_or_b32, .v_xor_b32 => if (!registers.vectorWrite(inst, registers.binary(inst))) return null,
                .v_add3_u32 => {
                    if (!rectangular or !registers.vectorWrite(inst, registers.ternary(inst))) return null;
                },
                .v_lshl_add_u32, .v_and_or_b32, .v_bfe_u32 => if (!registers.vectorWrite(inst, registers.ternary(inst))) return null,
                // These write one whole VGPR and cannot alter EXEC. Their
                // numerical result is irrelevant unless it reaches an address.
                .v_cndmask_b32, .v_cvt_f32_u32 => {
                    if (!rectangular or !registers.vectorWrite(inst, null)) return null;
                },
                .v_add_f32,
                .v_sub_f32,
                .v_mul_f32,
                .v_mac_f32,
                .v_mad_f32,
                .v_madmk_f32,
                .v_madak_f32,
                .v_min_f32,
                .v_max_f32,
                .v_min3_f32,
                .v_max3_f32,
                .v_sub_nc_u32,
                => if (!registers.vectorWrite(inst, null)) return null,
                .v_cmp_eq_u32, .v_cmp_ge_u32 => {
                    // Ordinary comparisons update VCC/an SGPR pair, never
                    // EXEC. Their values cannot become proven coordinates.
                    if (!rectangular) return null;
                    switch (inst.dst.kind) {
                        .vcc_lo => {},
                        .sgpr => {
                            if (inst.dst.reg > 126) return null;
                            for (inst.dst.reg..inst.dst.reg + 2) |reg| {
                                registers.scalar[reg] = null;
                                registers.scalar_definitions[reg] = @intCast(position + 1);
                            }
                        },
                        else => return null,
                    }
                },
                .image_load, .image_sample => {
                    if (inst.opcode == .image_sample and !rectangular) return null;
                    if (inst.dst.kind != .vgpr or inst.data_words == 0 or inst.dst.reg + inst.data_words > 256 or
                        inst.image_elements != 0 or (inst.opcode == .image_load and !std.meta.eql(inst.image_sample_flags, rdna2.isa.ImageSampleFlags{}))) return null;
                    for (inst.dst.reg..inst.dst.reg + inst.data_words) |reg| registers.vector[reg] = null;
                },
                .image_store => {
                    if (inst.image_dimension != .dim_2d or inst.image_address_components != 2 or inst.data_mask != 15 or
                        inst.image_elements != 0 or inst.data_bits != 32 or inst.image_r128 or
                        !std.meta.eql(inst.image_sample_flags, rdna2.isa.ImageSampleFlags{}) or
                        inst.src1.kind != .sgpr or inst.src1.reg > 120) return null;
                    const xreg = addressRegister(inst, 0) orelse return null;
                    const yreg = addressRegister(inst, 1) orelse return null;
                    if (xreg >= 256 or yreg >= 256) return null;
                    const x = registers.vector[xreg] orelse return null;
                    const y = registers.vector[yreg] orelse return null;
                    if (x.y != 0 or y.x != 0 or x.x == 0 or y.y == 0 or x.x > 64 or y.y > 64 or x.bias >= x.x or y.bias >= y.y) return null;
                    const index = found: {
                        for (tiles[0..count], 0..) |tile, i| if (tile.output.resource_sgpr == inst.src1.reg) break :found i;
                        if (count == tiles.len) return null;
                        tiles[count] = .{
                            .output = .{ .resource_sgpr = inst.src1.reg, .first_pc = inst.pc, .block_width = x.x, .block_height = y.y },
                            .definitions = registers.scalar_definitions[inst.src1.reg..][0..8].*,
                        };
                        count += 1;
                        break :found count - 1;
                    };
                    const tile = &tiles[index];
                    if (tile.output.block_width != x.x or tile.output.block_height != y.y or
                        !std.mem.eql(u32, &tile.definitions, registers.scalar_definitions[inst.src1.reg..][0..8])) return null;
                    tile.pixels.set(y.bias * x.x + x.bias);
                },
                else => return null,
            }
        }
    }
    var result = Proof{};
    for (tiles[0..count]) |tile| {
        if (tile.pixels.count() != tile.output.block_width * tile.output.block_height) continue;
        result.outputs[result.count] = tile.output;
        result.count += 1;
    }
    return if (result.count == 0) null else result;
}

test "complete tiled stores require every lane, component and tile pixel" {
    const system = resources.ComputeSystemRegisters{ .workgroup_id_sgprs = .{ 8, 9, null } };
    var code = [_]rdna2.Instruction{
        .{ .opcode = .v_and_b32, .dst = .{ .kind = .vgpr, .reg = 1 }, .src0 = .{ .kind = .integer_inline_constant, .value = 7 }, .src1 = .{ .kind = .vgpr, .reg = 0 } },
        .{ .opcode = .v_lshrrev_b32, .dst = .{ .kind = .vgpr, .reg = 2 }, .src0 = .{ .kind = .integer_inline_constant, .value = 3 }, .src1 = .{ .kind = .vgpr, .reg = 0 } },
        .{ .opcode = .v_lshl_add_u32, .dst = .{ .kind = .vgpr, .reg = 1 }, .src0 = .{ .kind = .sgpr, .reg = 8 }, .src1 = .{ .kind = .integer_inline_constant, .value = 3 }, .src2 = .{ .kind = .vgpr, .reg = 1 } },
        .{ .opcode = .v_lshl_add_u32, .dst = .{ .kind = .vgpr, .reg = 2 }, .src0 = .{ .kind = .sgpr, .reg = 9 }, .src1 = .{ .kind = .integer_inline_constant, .value = 3 }, .src2 = .{ .kind = .vgpr, .reg = 2 } },
        .{ .opcode = .image_store, .pc = 32, .data_mask = 15, .image_address_components = 2, .src0 = .{ .kind = .vgpr, .reg = 1 }, .src1 = .{ .kind = .sgpr, .reg = 16 } },
        .{ .opcode = .s_endpgm },
    };
    const proof = analyze(&code, system, .{ 64, 1, 1 }).?;
    try std.testing.expectEqual(@as(u8, 1), proof.count);
    try std.testing.expect(proof.outputs[0].covers(.{ 3, 2, 1 }, 23, 15));
    try std.testing.expect(!proof.outputs[0].covers(.{ 2, 2, 1 }, 23, 15));
    try std.testing.expect(!proof.outputs[0].covers(.{ 3, 2, 2 }, 23, 15));
    try std.testing.expect(analyze(&code, system, .{ 32, 1, 1 }) == null);
    code[4].data_mask = 7;
    try std.testing.expect(analyze(&code, system, .{ 64, 1, 1 }) == null);
    code[4].data_mask = 15;
    code[3].src2.reg = 1;
    try std.testing.expect(analyze(&code, system, .{ 64, 1, 1 }) == null);
    code[3].src2.reg = 2;
    code[0].opcode = .unknown;
    try std.testing.expect(analyze(&code, system, .{ 64, 1, 1 }) == null);
    code[0].opcode = .s_cbranch_execz;
    try std.testing.expect(analyze(&code, system, .{ 64, 1, 1 }) == null);
    code[0].opcode = .v_and_b32;
    code[4].image_nsa_words = 1;
    code[4].image_nsa_address[0] = 2;
    try std.testing.expect(analyze(&code, system, .{ 64, 1, 1 }) != null);
    code[4].image_nsa_address[0] = 7;
    try std.testing.expect(analyze(&code, system, .{ 64, 1, 1 }) == null);
    code[4].image_nsa_address[0] = 2;
    code[4].image_sample_flags.a16 = true;
    try std.testing.expect(analyze(&code, system, .{ 64, 1, 1 }) == null);
    code[4].image_sample_flags.a16 = false;
    var cache = Cache{};
    try std.testing.expect(cache.get(1, &code, system, .{ 64, 1, 1 }) != null);
    try std.testing.expect(cache.get(1, &code, system, .{ 32, 1, 1 }) == null);
    code[0].opcode = .unknown;
    try std.testing.expect(cache.get(2, &code, system, .{ 64, 1, 1 }) == null);
}

test "rectangular groups prove sampled full stores and reject masked or incomplete coverage" {
    const saved = rectangular_image_write_coverage;
    defer rectangular_image_write_coverage = saved;
    rectangular_image_write_coverage = true;
    const system = resources.ComputeSystemRegisters{ .workgroup_id_sgprs = .{ 14, 15, null }, .local_invocation_id_components = 2 };
    var code = [_]rdna2.Instruction{
        .{ .opcode = .v_lshl_add_u32, .dst = .{ .kind = .vgpr, .reg = 2 }, .src0 = .{ .kind = .sgpr, .reg = 14 }, .src1 = .{ .kind = .integer_inline_constant, .value = 3 }, .src2 = .{ .kind = .vgpr, .reg = 0 } },
        .{ .opcode = .v_lshl_add_u32, .dst = .{ .kind = .vgpr, .reg = 3 }, .src0 = .{ .kind = .sgpr, .reg = 15 }, .src1 = .{ .kind = .integer_inline_constant, .value = 3 }, .src2 = .{ .kind = .vgpr, .reg = 1 } },
        .{ .opcode = .v_cmp_ge_u32, .dst = .{ .kind = .vcc_lo }, .src0 = .{ .kind = .integer_inline_constant, .value = 1 }, .src1 = .{ .kind = .vgpr, .reg = 0 } },
        .{ .opcode = .v_cndmask_b32, .dst = .{ .kind = .vgpr, .reg = 4 }, .src0 = .{ .kind = .vgpr, .reg = 0 }, .src1 = .{ .kind = .vgpr, .reg = 1 } },
        .{ .opcode = .image_sample, .dst = .{ .kind = .vgpr, .reg = 10 }, .src1 = .{ .kind = .sgpr, .reg = 32 }, .data_words = 4 },
        .{ .opcode = .image_store, .pc = 40, .data_mask = 15, .image_address_components = 2, .src0 = .{ .kind = .vgpr, .reg = 2 }, .src1 = .{ .kind = .sgpr, .reg = 16 } },
        .{ .opcode = .s_endpgm },
    };
    var cache = Cache{};
    const proof = cache.get(1, &code, system, .{ 8, 8, 1 }).?;
    try std.testing.expectEqual(@as(u8, 1), proof.count);
    try std.testing.expect(proof.outputs[0].covers(.{ 3, 2, 1 }, 23, 15));
    try std.testing.expect(analyze(&code, system, .{ 8, 4, 1 }) == null);
    try std.testing.expect(analyze(&code, system, .{ 8, 8, 2 }) == null);
    var missing_y = system;
    missing_y.local_invocation_id_components = 1;
    try std.testing.expect(analyze(&code, missing_y, .{ 8, 8, 1 }) == null);
    rectangular_image_write_coverage = false;
    try std.testing.expect(cache.get(1, &code, system, .{ 8, 8, 1 }) == null);
    rectangular_image_write_coverage = true;
    try std.testing.expect(cache.get(1, &code, system, .{ 8, 8, 1 }) != null);
    code[5].data_mask = 7;
    try std.testing.expect(analyze(&code, system, .{ 8, 8, 1 }) == null);
    code[5].data_mask = 15;
    code[2].opcode = .v_cmpx_ge_u32;
    try std.testing.expect(analyze(&code, system, .{ 8, 8, 1 }) == null);
    code[2].opcode = .v_cmp_ge_u32;
    code[3].dst.reg = 2;
    try std.testing.expect(analyze(&code, system, .{ 8, 8, 1 }) == null);
    code[3].dst.reg = 4;
    code[4].dst.reg = 2;
    try std.testing.expect(analyze(&code, system, .{ 8, 8, 1 }) == null);
    code[4].dst.reg = 10;
    code[0].src1.value = 4;
    code[1].src1.value = 4;
    try std.testing.expect(analyze(&code, system, .{ 16, 16, 1 }) != null);
    try std.testing.expect(analyze(&code, system, .{ 32, 32, 1 }) == null);
}
