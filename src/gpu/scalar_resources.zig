// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Recover uniform resource words through their actual reaching definitions.
//! A reused SGPR must never fall back to an unrelated entry USER_DATA value.
const std = @import("std");
const rdna2 = @import("rdna2");
const shaders = @import("shaders.zig");
const scalar = @import("scalar_provenance.zig");
const definitions = @import("index_bounds.zig");
const checkpoints = @import("resource_checkpoints.zig");
const bit_sets = @import("bit_sets.zig");

/// Diagnostic switch sampled once per recovery, allowing same-process timing.
pub var definition_cache_enabled = std.atomic.Value(bool).init(true);
pub var definition_cache_hits = std.atomic.Value(u64).init(0);
pub var definition_cache_misses = std.atomic.Value(u64).init(0);
pub var persistent_definition_cache_enabled = std.atomic.Value(bool).init(true);
pub var persistent_definition_cache_hits = std.atomic.Value(u64).init(0);
pub var persistent_definition_cache_misses = std.atomic.Value(u64).init(0);

// Reaching-definition recovery only reads this snapshot. Sharing the immutable
// unknown state avoids copying 128 register records for every preparation.
const unknown_registers: scalar.ScalarRegisters = @splat(.{});

/// Recover pointer loads omitted by the representative scalar walk. An empty
/// snapshot forces every address input to come from its reaching definition;
/// a value observed on another path or loop iteration is not evidence here.
/// Returns the new end of the specialization list. The appended range consists
/// only of loads whose entire address and payload were recovered together.
pub fn appendMissingPointerLoads(
    bindings: *const shaders.StageBindings,
    reader: shaders.MemoryReader,
    instructions: []const rdna2.Instruction,
    graph: *const rdna2.control_flow.Graph,
    cache: ?*definitions.ScalarDefinitionCache,
    plan: ?*const checkpoints.Plan,
    output: []rdna2.spirv.ScalarRegister,
    count: usize,
    prefix_end: u32,
) usize {
    if (prefix_end == 0) return count;
    var seen: std.StaticBitSet(64 * 1024) = undefined;
    // No instruction at or beyond prefix_end is eligible. Initialize only
    // words that can be queried, retaining the existing maximum-PC bound.
    const slots: usize = @intCast(@min(seen.capacity(), (@as(u64, prefix_end) + 3) / 4));
    const mask_bits = @bitSizeOf(@TypeOf(seen).MaskInt);
    @memset(seen.masks[0 .. (slots + mask_bits - 1) / mask_bits], 0);
    for (output[0..count]) |entry| if (entry.producer_pc) |pc| {
        if (pc / 4 < slots) seen.set(pc / 4);
    };
    var end = count;
    var resource_instructions = checkpoints.Iterator.init(instructions, plan, .resource);
    while (resource_instructions.next()) |instruction_index| {
        const candidate = &instructions[instruction_index];
        switch (candidate.opcode) {
            .s_load_dword, .s_load_dwordx2, .s_load_dwordx4, .s_load_dwordx8, .s_load_dwordx16 => {},
            else => continue,
        }
        const inst = candidate.*;
        if (inst.pc >= prefix_end or inst.pc / 4 >= slots or bit_sets.contains(&seen, inst.pc / 4)) continue;
        const destination = scalar.scalarRegisterIndex(inst.dst) orelse continue;
        const pointer_register = scalar.scalarRegisterIndex(inst.src0) orelse continue;
        if (pointer_register >= 127 or inst.data_words == 0 or
            inst.data_words > 16 or destination + inst.data_words > 128 or inst.memory_offset < 0) continue;
        if (output.len - end < inst.data_words) break;
        var resolver = Resolver{ .bindings = bindings, .reader = reader, .instructions = instructions, .graph = graph, .snapshot = &unknown_registers, .definition_cache = cache };
        var base: [2]u32 = undefined;
        if (!(resolver.words(@intCast(pointer_register), inst.pc, &base) catch false) or base[1] > 0xffff) continue;
        const pointer = @as(u64, base[0]) | (@as(u64, base[1]) << 32);
        if (pointer == 0) continue;
        var offset: [1]u32 = .{0};
        if (scalar.scalarRegisterIndex(inst.src1)) |register| {
            if (!(resolver.words(@intCast(register), inst.pc, &offset) catch false)) continue;
        } else switch (inst.src1.kind) {
            .null => {},
            .integer_inline_constant, .literal_constant => offset[0] = inst.src1.value,
            else => continue,
        }
        if (inst.src0.absolute or inst.src0.negate or inst.src0.dpp or
            inst.src1.absolute or inst.src1.negate or inst.src1.dpp) continue;
        const address = (pointer + @as(u64, offset[0]) + @as(u64, @intCast(inst.memory_offset))) & ~@as(u64, 3);
        if (address + @as(u64, inst.data_words) * 4 > 0x1_0000_0000_0000) continue;
        // MemoryReader.readWords is bounded to eight descriptor words; scalar
        // constants also use s_load_dwordx16. Keep the complete payload here.
        var bytes: [16 * @sizeOf(u32)]u8 = undefined;
        reader.read(address, bytes[0 .. @as(usize, inst.data_words) * 4]) catch continue;
        for (0..inst.data_words) |component| {
            const value = std.mem.readInt(u32, bytes[component * 4 ..][0..4], .little);
            output[end] = .{ .register = @intCast(destination + component), .value = value, .producer_pc = inst.pc };
            end += 1;
        }
    }
    return end;
}

pub const Resolver = struct {
    bindings: *const shaders.StageBindings,
    reader: shaders.MemoryReader,
    instructions: []const rdna2.Instruction,
    graph: *const rdna2.control_flow.Graph,
    /// Borrowed instruction-local registers; the caller owns their lifetime.
    snapshot: *const scalar.ScalarRegisters,
    remaining: usize = 512,
    memoize_definitions: bool = true,
    memoize_values: bool = true,
    definition_cache: ?*definitions.ScalarDefinitionCache = null,
    definition_batch: definitions.ScalarDefinitionBatch = undefined,
    batch_enabled: bool = false,
    // Values belong to one descriptor recovery. A later invocation must read
    // fresh guest memory, even when its reaching definitions are unchanged.
    values: [64]struct { before: usize, register: u32, value: u32 } = undefined,
    valid_values: u64 = 0,

    pub fn words(self: *Resolver, register: u32, before_pc: u32, output: []u32) !bool {
        self.valid_values = 0;
        self.batch_enabled = self.memoize_definitions and definition_cache_enabled.load(.monotonic);
        self.definition_batch = .{ .instructions = self.instructions, .graph = self.graph };
        if (self.batch_enabled and persistent_definition_cache_enabled.load(.monotonic)) {
            if (self.definition_cache) |cache| {
                if (cache.matches(self.instructions, self.graph)) self.definition_batch.persistent = cache;
            }
        }
        defer if (self.batch_enabled) {
            _ = definition_cache_hits.fetchAdd(self.definition_batch.hits, .monotonic);
            _ = definition_cache_misses.fetchAdd(self.definition_batch.misses, .monotonic);
            if (self.definition_batch.persistent != null) {
                _ = persistent_definition_cache_hits.fetchAdd(self.definition_batch.persistent_hits, .monotonic);
                _ = persistent_definition_cache_misses.fetchAdd(self.definition_batch.persistent_misses, .monotonic);
            }
        };
        const before = if (self.definition_batch.persistent) |cache| cache.instructionBefore(before_pc) else position: {
            var index: usize = 0;
            while (index < self.instructions.len and self.instructions[index].pc < before_pc) : (index += 1) {}
            break :position index;
        };
        if (before == self.instructions.len) return false;
        for (output, 0..) |*value, component| value.* = (try self.word(register + @as(u32, @intCast(component)), before, 0)) orelse return false;
        return true;
    }

    fn operand(self: *Resolver, op: rdna2.Operand, component: u32, before: usize, depth: u8) anyerror!?u32 {
        if (op.absolute or op.negate or op.dpp) return null;
        if (scalar.scalarRegisterIndex(op)) |register| return self.word(@as(u32, @intCast(register)) + component, before, depth);
        return switch (op.kind) {
            .null => 0,
            .integer_inline_constant => if (component == 0) op.value else if (op.value & 0x8000_0000 != 0) std.math.maxInt(u32) else 0,
            .literal_constant => if (component == 0) op.value else 0,
            else => null,
        };
    }

    fn word(self: *Resolver, requested_register: u32, before: usize, depth: u8) anyerror!?u32 {
        if (requested_register >= scalar.maximum_scalar_registers or depth >= 24 or self.remaining == 0) return null;
        const slot: u6 = @truncate((before *% 37) ^ (@as(usize, requested_register) *% 17));
        const mask = @as(u64, 1) << slot;
        if (self.memoize_values and self.valid_values & mask != 0) {
            const known = self.values[slot];
            if (known.before == before and known.register == requested_register) return known.value;
        }
        self.remaining -= 1;
        const result = try self.recoverWord(requested_register, before, depth);
        if (self.memoize_values) if (result) |value| {
            self.values[slot] = .{ .before = before, .register = requested_register, .value = value };
            self.valid_values |= mask;
        };
        return result;
    }

    fn recoverWord(self: *Resolver, requested_register: u32, before: usize, depth: u8) anyerror!?u32 {
        var register = requested_register;
        const direct_definition = if (self.batch_enabled)
            self.definition_batch.lookup(before, register)
        else
            definitions.scalarDefinition(self.instructions, self.graph, before, register);
        const needs_restore = if (direct_definition) |definition| switch (definition) {
            .entry => false,
            .instruction => |index| self.instructions[index].opcode == .v_readlane_b32,
        } else true;
        const definition = if (needs_restore) restored: {
            const origin = (if (self.batch_enabled and self.definition_batch.persistent != null)
                self.definition_batch.persistent.?.savedOrigin(before, register)
            else
                definitions.savedScalarOrigin(self.instructions, self.graph, before, register)) orelse return null;
            register = origin.register;
            break :restored origin.definition;
        } else direct_definition.?;
        const index = switch (definition) {
            .entry => {
                if (register < self.bindings.scalar_user_data_base) return null;
                const entry = register - self.bindings.scalar_user_data_base;
                return if (entry < self.bindings.user_data_count) self.bindings.user_data[entry] else null;
            },
            .instruction => |index| index,
        };
        const inst = self.instructions[index];
        const known = self.snapshot[register];
        const destination = scalar.scalarRegisterIndex(inst.dst) orelse return null;
        if (register < destination) return null;
        const component: u32 = @intCast(register - destination);
        switch (inst.opcode) {
            .s_or_b32, .s_bfe_u32, .s_bfe_u64, .s_lshl4_add_u32, .s_cselect_b32, .s_cselect_b64 => return (try self.descriptorExpression(inst, index, component, depth)) orelse
                if (known.known and known.producer_pc == inst.pc) known.value else null,
            .s_getpc_b64 => {
                if (component >= 2) return null;
                const address = self.bindings.program_address +% inst.pc +% 4;
                return @truncate(address >> @as(u6, @intCast(component * 32)));
            },
            .s_add_u32, .s_add_i32, .s_sub_u32, .s_sub_i32 => {
                if (component != 0) return null;
                const a = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
                const b = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
                return if (inst.opcode == .s_add_u32 or inst.opcode == .s_add_i32) a +% b else a -% b;
            },
            .s_addc_u32 => {
                // Recover a PC-relative descriptor even in a branch omitted
                // by the representative scalar walk. Carry must be proven:
                // accept an adjacent unsigned add in this same basic block.
                // A branch into ADDC can carry an unrelated SCC value.
                if (component != 0 or index == 0 or self.instructions[index - 1].opcode != .s_add_u32)
                    return if (known.known and known.producer_pc == inst.pc) known.value else null;
                const same_block = for (self.graph.blocks.items) |block| {
                    if (index >= block.first_instruction and index < block.first_instruction + block.instruction_count)
                        break index > block.first_instruction;
                } else false;
                if (!same_block) return null;
                const low = self.instructions[index - 1];
                const low_a = (try self.operand(low.src0, 0, index - 1, depth + 1)) orelse return null;
                const low_b = (try self.operand(low.src1, 0, index - 1, depth + 1)) orelse return null;
                const carry = @addWithOverflow(low_a, low_b)[1];
                const a = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
                const b = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
                return a +% b +% carry;
            },
            .s_mov_b32, .s_mov_b64 => return self.operand(inst.src0, component, index, depth + 1),
            .s_bitset0_b32, .s_bitset1_b32 => {
                if (component != 0) return null;
                const current = (try self.operand(inst.dst, 0, index, depth + 1)) orelse return null;
                const bit = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
                const mask = @as(u32, 1) << @as(u5, @truncate(bit));
                return if (inst.opcode == .s_bitset1_b32) current | mask else current & ~mask;
            },
            .s_and_b32 => {
                if (component != 0) return null;
                const a = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
                const b = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
                return a & b;
            },
            .s_mul_i32, .s_mulk_i32 => {
                if (component != 0) return null;
                const a = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
                const b = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
                return a *% b;
            },
            .s_movk_i32 => return @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(inst.src0.value)))))),
            .s_lshl_b32, .s_lshr_b32, .s_ashr_i32 => {
                if (component != 0) return null;
                const value = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
                const amount = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
                const shift: u5 = @truncate(amount);
                return switch (inst.opcode) {
                    .s_lshl_b32 => value << shift,
                    .s_lshr_b32 => value >> shift,
                    .s_ashr_i32 => @bitCast(@as(i32, @bitCast(value)) >> shift),
                    else => unreachable,
                };
            },
            .s_bfm_b32, .s_bfm_b64 => {
                // Sampler constants are also assembled in branches that the
                // scalar walk cannot visit. Recover both inputs at the mask
                // producer instead of borrowing its destination snapshot.
                const width = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
                const offset = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
                if (inst.opcode == .s_bfm_b32) {
                    if (component != 0) return null;
                    const mask = (@as(u32, 1) << @as(u5, @truncate(width))) - 1;
                    return mask << @as(u5, @truncate(offset));
                }
                if (component >= 2) return null;
                const mask = (@as(u64, 1) << @as(u6, @truncate(width))) - 1;
                const value = mask << @as(u6, @truncate(offset));
                return @truncate(value >> @as(u6, @intCast(component * 32)));
            },
            .s_load_dword, .s_load_dwordx2, .s_load_dwordx4, .s_load_dwordx8, .s_load_dwordx16, .s_buffer_load_dword, .s_buffer_load_dwordx2, .s_buffer_load_dwordx4, .s_buffer_load_dwordx8, .s_buffer_load_dwordx16 => {},
            else => return if (known.known and known.producer_pc == inst.pc) known.value else null,
        }
        if (component >= inst.data_words) return null;
        const is_buffer = std.mem.startsWith(u8, @tagName(inst.opcode), "s_buffer_");
        var base_words: [4]u32 = @splat(0);
        for (base_words[0..@as(usize, if (is_buffer) 4 else 2)], 0..) |*value, part| {
            value.* = (try self.operand(inst.src0, @intCast(part), index, depth + 1)) orelse return null;
        }
        // An empty V# returns zero for every offset. Requiring a uniform
        // workgroup/loop index first loses valid descriptors selected through
        // an optional empty indirection buffer.
        if (is_buffer and base_words[2] == 0) return 0;
        const offset = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
        const displacement = @as(i64, inst.memory_offset) + offset;
        if (displacement < 0) return null;
        var base: u64 = undefined;
        if (is_buffer) {
            const stride = (base_words[1] >> 16) & 0x3fff;
            const size = @as(u64, @max(stride, 1)) * base_words[2];
            const byte = (@as(u64, @intCast(displacement)) & ~@as(u64, 3)) + component * 4;
            if (byte + 4 > size) return 0;
            base = @as(u64, base_words[0]) | (@as(u64, base_words[1] & 0xffff) << 32);
        } else {
            if (base_words[1] & 0xffff_0000 != 0) return null;
            base = @as(u64, base_words[0]) | (@as(u64, base_words[1]) << 32);
            if (base == 0) return null;
        }
        const address = std.math.add(u64, base, @intCast(displacement)) catch return null;
        const byte = std.math.add(u64, address & ~@as(u64, 3), component * 4) catch return null;
        if (byte > 0xffff_ffff_fffc) return null;
        return try self.reader.readU32(byte);
    }

    /// Vertex fetch shaders assemble format fields from a packed attribute
    /// table. Recover inputs at their producers, not from a later SGPR reuse.
    fn descriptorExpression(self: *Resolver, inst: rdna2.Instruction, index: usize, component: u32, depth: u8) !?u32 {
        if (inst.opcode == .s_cselect_b32 or inst.opcode == .s_cselect_b64) {
            if (component >= @as(u32, if (inst.opcode == .s_cselect_b64) 2 else 1)) return null;
            const condition = (try self.comparisonBefore(index, depth)) orelse return null;
            return self.operand(if (condition) inst.src0 else inst.src1, component, index, depth + 1);
        }
        if (component != 0 and (inst.opcode != .s_bfe_u64 or component >= 2)) return null;
        const a = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
        const b = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
        return switch (inst.opcode) {
            .s_or_b32 => a | b,
            .s_lshl4_add_u32 => (a << 4) +% b,
            .s_bfe_u32 => extract: {
                const offset: u5 = @truncate(b);
                const width = @min((b >> 16) & 0x7f, 32 - @as(u32, offset));
                if (width == 0) break :extract 0;
                if (width == 32) break :extract a;
                break :extract (a >> offset) & ((@as(u32, 1) << @as(u5, @intCast(width))) - 1);
            },
            .s_bfe_u64 => extract: {
                const high = (try self.operand(inst.src0, 1, index, depth + 1)) orelse return null;
                const offset: u6 = @truncate(b);
                const width = @min((b >> 16) & 0x7f, 64 - @as(u32, offset));
                if (width == 0) break :extract 0;
                const shifted = (@as(u64, a) | (@as(u64, high) << 32)) >> offset;
                const value = if (width == 64) shifted else shifted & ((@as(u64, 1) << @as(u6, @intCast(width))) - 1);
                break :extract @truncate(value >> @as(u6, @intCast(component * 32)));
            },
            else => unreachable,
        };
    }

    /// Only a proven comparison in the same basic block can drive CSELECT.
    /// Stop at every instruction not known to preserve SCC; never borrow a
    /// comparison from across a branch or an intervening scalar ALU write.
    fn comparisonBefore(self: *Resolver, before: usize, depth: u8) !?bool {
        const first = for (self.graph.blocks.items) |block| {
            if (before >= block.first_instruction and before < block.first_instruction + block.instruction_count)
                break block.first_instruction;
        } else return null;
        var index = before;
        while (index > first) {
            index -= 1;
            const inst = self.instructions[index];
            switch (inst.opcode) {
                .s_nop,
                .s_waitcnt,
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
                => continue,
                .s_cmp_eq_i32,
                .s_cmp_eq_u32,
                .s_cmp_lg_i32,
                .s_cmp_lg_u32,
                .s_cmp_gt_i32,
                .s_cmp_ge_i32,
                .s_cmp_lt_i32,
                .s_cmp_le_i32,
                .s_cmp_gt_u32,
                .s_cmp_ge_u32,
                .s_cmp_lt_u32,
                .s_cmp_le_u32,
                => {},
                else => return null,
            }
            const a = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
            const b = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
            const ai: i32 = @bitCast(a);
            const bi: i32 = @bitCast(b);
            return switch (inst.opcode) {
                .s_cmp_eq_i32, .s_cmp_eq_u32 => a == b,
                .s_cmp_lg_i32, .s_cmp_lg_u32 => a != b,
                .s_cmp_gt_i32 => ai > bi,
                .s_cmp_ge_i32 => ai >= bi,
                .s_cmp_lt_i32 => ai < bi,
                .s_cmp_le_i32 => ai <= bi,
                .s_cmp_gt_u32 => a > b,
                .s_cmp_ge_u32 => a >= b,
                .s_cmp_lt_u32 => a < b,
                .s_cmp_le_u32 => a <= b,
                else => unreachable,
            };
        }
        return null;
    }
};

test "packed vertex format recovery proves CSELECT and refuses unknown or clobbered SCC" {
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
        fn reg(index: u32) rdna2.Operand {
            return .{ .kind = .sgpr, .reg = index };
        }
        fn imm(value: u32) rdna2.Operand {
            return .{ .kind = .literal_constant, .value = value };
        }
    };
    const original = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_bfe_u32, .dst = M.reg(4), .src0 = M.reg(0), .src1 = M.imm(0x70007) },
        .{ .pc = 4, .opcode = .s_lshl_b32, .dst = M.reg(5), .src0 = M.reg(4), .src1 = M.imm(12) },
        .{ .pc = 8, .opcode = .s_bfe_u32, .dst = M.reg(6), .src0 = M.reg(0), .src1 = M.imm(0x20005) },
        .{ .pc = 12, .opcode = .s_lshl4_add_u32, .dst = M.reg(6), .src0 = M.reg(6), .src1 = M.imm(0xc0000) },
        .{ .pc = 16, .opcode = .s_bfe_u64, .dst = M.reg(8), .src0 = M.reg(2), .src1 = M.reg(6) },
        .{ .pc = 20, .opcode = .s_or_b32, .dst = M.reg(10), .src0 = M.reg(5), .src1 = M.reg(8) },
        .{ .pc = 24, .opcode = .s_cmp_eq_u32, .dst = .{ .kind = .scc }, .src0 = M.reg(4), .src1 = M.imm(0) },
        .{ .pc = 28, .opcode = .s_nop },
        .{ .pc = 32, .opcode = .s_cselect_b32, .dst = M.reg(11), .src0 = M.imm(0xfac), .src1 = M.reg(10) },
        .{ .pc = 36, .opcode = .s_endpgm },
    };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 4;
    bindings.user_data[2] = 0x022c0204;
    bindings.user_data[3] = 0x0fac03ac;
    for (0..6) |variant| {
        var instructions = original;
        bindings.user_data[0] = if (variant == 0) 0 else if (variant == 2) 0xa0 else 0x80;
        if (variant == 3) instructions[7] = .{ .pc = 28, .opcode = .s_and_b32, .dst = M.reg(30), .src0 = M.imm(0), .src1 = M.imm(0) };
        if (variant == 4) instructions[7] = .{ .pc = 28, .opcode = .s_branch, .branch_target = 32 };
        if (variant == 5) instructions[6].src0 = M.reg(60);
        var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
        defer graph.deinit(std.testing.allocator);
        var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &unknown_registers };
        var words: [1]u32 = undefined;
        try std.testing.expectEqual(variant < 3, try resolver.words(11, 36, &words));
        if (variant < 3) try std.testing.expectEqual(([_]u32{ 0xfac, 0x1204, 0x122c })[variant], words[0]);
    }
}

test "descriptor BFE64 preserves cross-word fields, zero widths and literal widening" {
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x89abcdef;
    bindings.user_data[1] = 0x01234567;
    for ([_]u32{ 0, 64 << 16, (8 << 16) | 28, (127 << 16) | 60, 64 << 16 }, 0..) |control, variant| {
        const source: rdna2.Operand = if (variant == 4) .{ .kind = .literal_constant, .value = 0x80000000 } else .{ .kind = .sgpr };
        const instructions = [_]rdna2.Instruction{
            .{ .pc = 0, .opcode = .s_bfe_u64, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = source, .src1 = .{ .kind = .literal_constant, .value = control } },
            .{ .pc = 4, .opcode = .s_endpgm },
        };
        var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
        defer graph.deinit(std.testing.allocator);
        var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &unknown_registers };
        var words: [2]u32 = undefined;
        try std.testing.expect(try resolver.words(4, 4, &words));
        const expected: [2]u32 = ([_][2]u32{ .{ 0, 0 }, .{ 0x89abcdef, 0x01234567 }, .{ 0x78, 0 }, .{ 0, 0 }, .{ 0x80000000, 0 } })[variant];
        try std.testing.expectEqualSlices(u32, &expected, &words);
    }
}

test "PC-relative resource descriptors recover skipped branches with a proven carry" {
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    const original = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_cbranch_execz, .branch_target = 36, .word_count = 1 },
        .{ .pc = 4, .opcode = .s_getpc_b64, .dst = .{ .kind = .sgpr }, .word_count = 1 },
        .{ .pc = 8, .opcode = .s_add_u32, .dst = .{ .kind = .sgpr }, .src0 = .{ .kind = .literal_constant, .value = 0x10a8 }, .src1 = .{ .kind = .sgpr }, .word_count = 2 },
        .{ .pc = 16, .opcode = .s_addc_u32, .dst = .{ .kind = .sgpr, .reg = 1 }, .src0 = .{ .kind = .integer_inline_constant }, .src1 = .{ .kind = .sgpr, .reg = 1 }, .word_count = 1 },
        .{ .pc = 20, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 2 }, .src0 = .{ .kind = .integer_inline_constant, .value = 64 }, .word_count = 1 },
        .{ .pc = 24, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 3 }, .src0 = .{ .kind = .literal_constant, .value = 0x10005004 }, .word_count = 1 },
        .{ .pc = 28, .opcode = .s_buffer_load_dwordx4, .src0 = .{ .kind = .sgpr }, .dst = .{ .kind = .sgpr, .reg = 4 }, .word_count = 2 },
        .{ .pc = 36, .opcode = .s_endpgm, .word_count = 1 },
    };
    for (0..5) |variant| {
        var instructions = original;
        if (variant == 2) instructions[0].branch_target = 16;
        if (variant == 3) instructions[2].opcode = .s_and_b32;
        if (variant == 4) instructions[2].src0 = .{ .kind = .vgpr };
        var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
        defer graph.deinit(std.testing.allocator);
        var bindings = std.mem.zeroes(shaders.StageBindings);
        bindings.program_address = if (variant == 1) 0x5fffffff0 else 0x500006e00;
        var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &unknown_registers };
        var words: [4]u32 = undefined;
        try std.testing.expectEqual(variant < 2, try resolver.words(0, 28, &words));
        if (variant < 2) {
            const address = bindings.program_address + 8 + 0x10a8;
            try std.testing.expectEqualSlices(u32, &.{ @truncate(address), @truncate(address >> 32), 64, 0x10005004 }, &words);
        }
    }
}

test "BITSET descriptor recovery uses the previous destination and rejects clobbers" {
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    const original = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_nop, .word_count = 1 },
        .{ .pc = 4, .opcode = .s_bitset1_b32, .dst = .{ .kind = .sgpr, .reg = 1 }, .src0 = .{ .kind = .integer_inline_constant, .value = 50 }, .word_count = 1 },
        .{ .pc = 8, .opcode = .s_bitset0_b32, .dst = .{ .kind = .sgpr, .reg = 1 }, .src0 = .{ .kind = .integer_inline_constant, .value = 31 }, .word_count = 1 },
        .{ .pc = 12, .opcode = .s_movk_i32, .dst = .{ .kind = .sgpr, .reg = 2 }, .src0 = .{ .kind = .literal_constant, .value = 80 }, .word_count = 1 },
        .{ .pc = 16, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 3 }, .src0 = .{ .kind = .literal_constant, .value = 0x16204 }, .word_count = 2 },
        .{ .pc = 24, .opcode = .buffer_store_dword, .family = .mubuf, .src1 = .{ .kind = .sgpr }, .word_count = 2 },
        .{ .pc = 32, .opcode = .s_endpgm, .word_count = 1 },
    };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x10000;
    bindings.user_data[1] = 0x80000020;
    for (0..3) |variant| {
        var instructions = original;
        if (variant != 0) instructions[0] = .{ .pc = 0, .opcode = .v_readfirstlane_b32, .dst = .{ .kind = .sgpr, .reg = if (variant == 1) 1 else 8 }, .src0 = .{ .kind = .vgpr }, .word_count = 1 };
        if (variant == 2) instructions[1].src0 = .{ .kind = .sgpr, .reg = 8 };
        var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
        defer graph.deinit(std.testing.allocator);
        var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &unknown_registers };
        var words: [4]u32 = undefined;
        try std.testing.expectEqual(variant == 0, try resolver.words(0, 24, &words));
        if (variant == 0) try std.testing.expectEqualSlices(u32, &.{ 0x10000, 0x40020, 80, 0x16204 }, &words);
    }
}

test "missing pointer constants follow branch definitions and stay draw-local" {
    const M = struct {
        coefficient: u32 = 0x3f800000,
        fail: bool = false,
        fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.fail or address < 0x1000 or address + bytes.len > 0x1100) return false;
            for (0..bytes.len / 4) |word|
                std.mem.writeInt(u32, bytes[word * 4 ..][0..4], self.coefficient + @as(u32, @intCast(word)), .little);
            return true;
        }
    };
    const original = [_]rdna2.Instruction{
        .{ .pc = 0, .family = .sop1, .opcode = .s_mov_b64, .dst = .{ .kind = .sgpr, .reg = 94 }, .src0 = .{ .kind = .sgpr }, .word_count = 1 },
        .{ .pc = 4, .family = .sopp, .opcode = .s_cbranch_execz, .branch_target = 20, .word_count = 1 },
        .{ .pc = 8, .opcode = .s_load_dwordx2, .family = .smem, .dst = .{ .kind = .vcc_lo }, .src0 = .{ .kind = .sgpr, .reg = 94 }, .src1 = .{ .kind = .null }, .data_words = 2, .word_count = 2 },
        .{ .pc = 16, .family = .sopp, .opcode = .s_branch, .branch_target = 32, .word_count = 1 },
        .{ .pc = 20, .family = .sopp, .opcode = .s_nop, .word_count = 1 },
        .{ .pc = 24, .opcode = .s_load_dwordx2, .family = .smem, .dst = .{ .kind = .vcc_lo }, .src0 = .{ .kind = .sgpr, .reg = 94 }, .src1 = .{ .kind = .null }, .memory_offset = 4, .data_words = 2, .word_count = 2 },
        .{ .pc = 32, .family = .sopp, .opcode = .s_endpgm, .word_count = 1 },
    };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x1000;
    bindings.resource_instruction_budget = 16384;
    var memory = M{};
    const reader = shaders.MemoryReader{ .context = &memory, .read_fn = M.read };
    for (0..8) |variant| {
        var instructions = original;
        switch (variant) {
            1 => instructions[4] = .{ .pc = 20, .opcode = .v_readfirstlane_b32, .dst = .{ .kind = .sgpr, .reg = 94 }, .src0 = .{ .kind = .vgpr }, .word_count = 1 },
            2 => instructions[5].src1 = .{ .kind = .sgpr, .reg = 40 },
            3 => { // A previous iteration can change the pointer.
                instructions[4] = .{ .pc = 20, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 94 }, .src0 = .{ .kind = .integer_inline_constant, .value = 0x1080 }, .word_count = 1 };
                instructions[6] = .{ .pc = 32, .opcode = .s_cbranch_scc1, .branch_target = 4, .word_count = 1 };
            },
            7 => {
                instructions[3].branch_target = 24;
                instructions[4] = .{ .pc = 20, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 94 }, .src0 = .{ .kind = .integer_inline_constant, .value = 0x1080 }, .word_count = 1 };
            },
            else => {},
        }
        var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
        defer graph.deinit(std.testing.allocator);
        var cache = definitions.ScalarDefinitionCache.init(std.testing.allocator, &instructions, &graph);
        defer cache.deinit();
        for (0..2) |draw| {
            memory.coefficient = 0x3f800000 + @as(u32, @intCast(draw * 16));
            memory.fail = variant == 4;
            var output: [8]rdna2.spirv.ScalarRegister = undefined;
            output[0] = .{ .register = 106, .value = 123, .producer_pc = 8 };
            output[1] = .{ .register = 107, .value = 456, .producer_pc = 8 };
            var plan = try checkpoints.Plan.init(std.testing.allocator, &instructions);
            defer plan.deinit(std.testing.allocator);
            const end = appendMissingPointerLoads(&bindings, reader, &instructions, &graph, &cache, if (draw == 0) &plan else null, output[0..if (variant == 5) 3 else 8], 2, if (variant == 6) 24 else 64);
            const recoverable = variant == 0 or variant == 3;
            try std.testing.expectEqual(@as(usize, if (recoverable) 4 else 2), end);
            try std.testing.expectEqual(@as(u32, 123), output[0].value);
            if (variant == 3) {
                var loop_output: [8]rdna2.spirv.ScalarRegister = undefined;
                const loop_end = appendMissingPointerLoads(&bindings, reader, &instructions, &graph, &cache, &plan, &loop_output, 0, 64);
                try std.testing.expectEqual(@as(usize, 2), loop_end);
                try std.testing.expectEqual(@as(?u32, 24), loop_output[0].producer_pc);
            }
            if (recoverable) {
                try std.testing.expectEqual(@as(?u32, 24), output[2].producer_pc);
                try std.testing.expectEqual(@as(u32, 106), output[2].register);
                try std.testing.expectEqual(memory.coefficient, output[2].value);
                try std.testing.expectEqual(memory.coefficient + 1, output[3].value);
            }
        }
    }
    // The representative walk visits only the first arm of this diamond.
    memory.fail = false;
    const walked = scalar.evaluateDecodedResourceState(reader, &bindings, &original);
    try std.testing.expectEqual(@as(usize, 1), walked.load_count);
    try std.testing.expectEqual(@as(u32, 8), walked.loads[0].pc);
}

test "missing VCC pointer loads use both reaching halves and reject clobbers" {
    const M = struct {
        fn read(_: ?*anyopaque, address: u64, bytes: []u8) bool {
            if (address != 0x1000 or bytes.len != 8) return false;
            std.mem.writeInt(u32, bytes[0..4], 0x3f800000, .little);
            std.mem.writeInt(u32, bytes[4..8], 0x3e800000, .little);
            return true;
        }
    };
    const original = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_mov_b64, .dst = .{ .kind = .vcc_lo }, .src0 = .{ .kind = .sgpr } },
        .{ .pc = 4, .opcode = .s_cbranch_execz, .branch_target = 20 },
        .{ .pc = 8, .opcode = .s_nop },
        .{ .pc = 12, .opcode = .s_load_dwordx2, .family = .smem, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .vcc_lo }, .src1 = .{ .kind = .null }, .data_words = 2, .word_count = 2 },
        .{ .pc = 20, .opcode = .s_endpgm },
    };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x1000;
    const reader = shaders.MemoryReader{ .context = null, .read_fn = M.read };
    for (0..3) |variant| {
        var instructions = original;
        if (variant != 0) instructions[2] = .{ .pc = 8, .opcode = .v_readfirstlane_b32, .dst = if (variant == 1) .{ .kind = .vcc_lo } else .{ .kind = .vcc_hi }, .src0 = .{ .kind = .vgpr } };
        var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
        defer graph.deinit(std.testing.allocator);
        var output: [2]rdna2.spirv.ScalarRegister = undefined;
        const count = appendMissingPointerLoads(&bindings, reader, &instructions, &graph, null, null, &output, 0, 24);
        try std.testing.expectEqual(@as(usize, if (variant == 0) 2 else 0), count);
        if (variant == 0) {
            try std.testing.expectEqual(@as(u32, 0x3f800000), output[0].value);
            try std.testing.expectEqual(@as(u32, 0x3e800000), output[1].value);
            try std.testing.expectEqual(@as(?u32, 12), output[1].producer_pc);
        }
    }
}

test "missing pointer recovery preserves all sixteen words and rejects partial reads" {
    const M = struct {
        readable: usize = 64,
        fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address != 0x1000 or bytes.len > self.readable) return false;
            for (0..bytes.len / 4) |index|
                std.mem.writeInt(u32, bytes[index * 4 ..][0..4], @as(u32, 0x3f800000) + @as(u32, @intCast(index)), .little);
            return true;
        }
    };
    const instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .family = .smem, .opcode = .s_load_dwordx16, .dst = .{ .kind = .sgpr, .reg = 32 }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .null }, .data_words = 16, .word_count = 2 },
        .{ .pc = 8, .family = .sopp, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x1000;
    var memory = M{};
    var output: [16]rdna2.spirv.ScalarRegister = undefined;
    const reader = shaders.MemoryReader{ .context = &memory, .read_fn = M.read };
    const count = appendMissingPointerLoads(&bindings, reader, &instructions, &graph, null, null, &output, 0, 16);
    try std.testing.expectEqual(@as(usize, 16), count);
    for (output, 0..) |entry, index| {
        try std.testing.expectEqual(@as(u32, @intCast(32 + index)), entry.register);
        try std.testing.expectEqual(@as(u32, 0x3f800000) + @as(u32, @intCast(index)), entry.value);
        try std.testing.expectEqual(@as(?u32, 0), entry.producer_pc);
    }
    memory.readable = 60;
    try std.testing.expectEqual(@as(usize, 0), appendMissingPointerLoads(&bindings, reader, &instructions, &graph, null, null, &output, 0, 16));
}

test "pointer recovery honors prefix and bitmap boundaries without reading unused words" {
    const M = struct {
        reads: usize = 0,
        fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address != 0x1000 or bytes.len != 4) return false;
            self.reads += 1;
            std.mem.writeInt(u32, bytes[0..4], 0x12345678, .little);
            return true;
        }
    };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x1000;
    for ([_]u32{ 0, 252, 256, 260, 262140, 262144 }) |pc| {
        const instructions = [_]rdna2.Instruction{
            .{ .pc = pc, .family = .smem, .opcode = .s_load_dword, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .null }, .data_words = 1, .word_count = 2 },
            .{ .pc = pc + 8, .family = .sopp, .opcode = .s_endpgm },
        };
        var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
        defer graph.deinit(std.testing.allocator);
        for ([_]u32{ 0, pc, pc + 1, std.math.maxInt(u32) }) |prefix| {
            for ([_]bool{ false, true }) |already_seen| {
                var memory = M{};
                var output: [2]rdna2.spirv.ScalarRegister = undefined;
                output[0] = .{ .register = 4, .value = 99, .producer_pc = if (already_seen) pc else std.math.maxInt(u32) };
                const count = appendMissingPointerLoads(&bindings, .{ .context = &memory, .read_fn = M.read }, &instructions, &graph, null, null, &output, 1, prefix);
                const recovered = !already_seen and pc < prefix and pc < 262144;
                try std.testing.expectEqual(@as(usize, if (recovered) 2 else 1), count);
                try std.testing.expectEqual(@as(usize, @intFromBool(recovered)), memory.reads);
                try std.testing.expectEqual(@as(u32, 99), output[0].value);
                if (recovered) try std.testing.expectEqual(@as(u32, 0x12345678), output[1].value);
            }
        }
    }
}

test "empty scalar buffers resolve independently of dynamic offsets" {
    const M = struct {
        calls: usize = 0,
        fn read(context: ?*anyopaque, _: u64, output: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (output.len != 4) return false;
            std.mem.writeInt(u32, output[0..4], 0x12345678, .little);
            return true;
        }
    };
    var instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_buffer_load_dwordx4, .dst = .{ .kind = .sgpr, .reg = 8 }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .sgpr, .reg = 40 }, .data_words = 4 },
        .{ .pc = 8, .opcode = .s_and_b32, .dst = .{ .kind = .sgpr, .reg = 12 }, .src0 = .{ .kind = .sgpr, .reg = 8 }, .src1 = .{ .kind = .literal_constant, .value = 255 } },
        .{ .pc = 16, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 4;
    bindings.user_data[0] = 0x1000;
    bindings.user_data[1] = 16 << 16;
    const snapshot = scalar.Evaluation{};
    var memory = M{};
    for (0..4) |variant| {
        bindings.user_data[2] = if (variant == 1 or variant == 3) 1 else 0;
        instructions[0].opcode = if (variant == 2) .s_load_dwordx4 else .s_buffer_load_dwordx4;
        instructions[0].src1 = if (variant == 3) .{ .kind = .null } else .{ .kind = .sgpr, .reg = 40 };
        var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = &memory, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers };
        var words: [4]u32 = undefined;
        const success = try resolver.words(8, 8, &words);
        try std.testing.expectEqual(variant == 0 or variant == 3, success);
        if (success) try std.testing.expect(std.mem.allEqual(u32, &words, if (variant == 0) 0 else 0x12345678));
        try std.testing.expectEqual(@as(usize, if (variant == 3) 4 else 0), memory.calls);
    }
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = &memory, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers };
    var masked: [1]u32 = undefined;
    try std.testing.expect(try resolver.words(12, 16, &masked));
    try std.testing.expectEqual(@as(u32, 0x78), masked[0]);
    instructions[1].src1 = .{ .kind = .sgpr, .reg = 41 };
    try std.testing.expect(!try resolver.words(12, 16, &masked));
}

test "resource descriptors survive lane spills, SGPR reuse, loops and branch joins" {
    const M = struct {
        bias: u32 = 0xabc00000,
        fn read(context: ?*anyopaque, address: u64, output: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address < 0x1000 or address + output.len > 0x1240 or output.len != 4) return false;
            std.mem.writeInt(u32, output[0..4], self.bias + @as(u32, @intCast(address - 0x1000)), .little);
            return true;
        }
    };
    const original = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_load_dwordx8, .dst = .{ .kind = .sgpr, .reg = 68 }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .null }, .memory_offset = 352, .data_words = 8 },
        .{ .pc = 8, .opcode = .s_cbranch_execz, .branch_target = 56 },
        .{ .pc = 12, .opcode = .v_writelane_b32, .dst = .{ .kind = .vgpr, .reg = 39 }, .src0 = .{ .kind = .sgpr, .reg = 68 }, .src1 = .{ .kind = .integer_inline_constant } },
        .{ .pc = 20, .opcode = .v_writelane_b32, .dst = .{ .kind = .vgpr, .reg = 39 }, .src0 = .{ .kind = .sgpr, .reg = 69 }, .src1 = .{ .kind = .integer_inline_constant, .value = 1 } },
        .{ .pc = 28, .opcode = .s_mov_b64, .dst = .{ .kind = .sgpr, .reg = 68 }, .src0 = .{ .kind = .vgpr } },
        .{ .pc = 32, .opcode = .s_nop },
        .{ .pc = 40, .opcode = .v_readlane_b32, .dst = .{ .kind = .sgpr, .reg = 68 }, .src0 = .{ .kind = .vgpr, .reg = 39 }, .src1 = .{ .kind = .integer_inline_constant } },
        .{ .pc = 48, .opcode = .v_readlane_b32, .dst = .{ .kind = .sgpr, .reg = 69 }, .src0 = .{ .kind = .vgpr, .reg = 39 }, .src1 = .{ .kind = .integer_inline_constant, .value = 1 } },
        .{ .pc = 52, .opcode = .s_nop },
        .{ .pc = 56, .opcode = .s_endpgm },
    };
    for (0..9) |variant| {
        var instructions = original;
        switch (variant) {
            0 => {},
            1 => instructions[5] = .{ .pc = 32, .opcode = .s_cbranch_scc1, .branch_target = 28 },
            2 => instructions[5] = .{ .pc = 32, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 39 } },
            3 => instructions[3].src1 = .{ .kind = .sgpr, .reg = 4 },
            4 => instructions[6].src1.value = 1,
            5 => instructions[2] = .{ .pc = 12, .opcode = .s_cbranch_scc1, .branch_target = 20 },
            6 => instructions[5] = .{ .pc = 32, .opcode = .buffer_load_dwordx2, .dst = .{ .kind = .vgpr, .reg = 38 }, .data_words = 2 },
            7 => instructions[8] = .{ .pc = 52, .opcode = .s_cbranch_scc1, .branch_target = 12 },
            8 => instructions[8] = .{ .pc = 52, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 68 }, .src0 = .{ .kind = .integer_inline_constant, .value = 1 } },
            else => unreachable,
        }
        var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
        defer graph.deinit(std.testing.allocator);
        var cache = definitions.ScalarDefinitionCache.init(std.testing.allocator, &instructions, &graph);
        defer cache.deinit();
        var memory = M{};
        var bindings = std.mem.zeroes(shaders.StageBindings);
        bindings.user_data_count = 2;
        bindings.user_data[0] = 0x1000;
        const snapshot = scalar.Evaluation{};
        var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = &memory, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers, .definition_cache = &cache };
        for (0..2) |_| {
            resolver.remaining = 512;
            var words: [8]u32 = undefined;
            const recoverable = variant < 2 or variant == 7;
            try std.testing.expectEqual(recoverable, try resolver.words(68, 56, &words));
            if (recoverable) for (words, 0..) |value, component| {
                try std.testing.expectEqual(memory.bias + 352 + component * 4, value);
            };
            memory.bias += 0x1000; // Persistent origins must not retain guest words.
        }
    }
}

test "scalar resource recovery reconstructs bitfield sampler constants" {
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    var instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_cbranch_execz, .branch_target = 16 },
        .{ .pc = 4, .opcode = .s_bfm_b64, .dst = .{ .kind = .sgpr, .reg = 32 }, .src0 = .{ .kind = .integer_inline_constant, .value = 12 }, .src1 = .{ .kind = .integer_inline_constant, .value = 44 } },
        .{ .pc = 8, .opcode = .s_mov_b64, .dst = .{ .kind = .sgpr, .reg = 34 }, .src0 = .{ .kind = .literal_constant, .value = 0x05500000 } },
        .{ .pc = 12, .opcode = .s_nop },
        .{ .pc = 16, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    var snapshot = scalar.Evaluation{};
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers };
    var words: [4]u32 = undefined;
    try std.testing.expect(try resolver.words(32, 12, &words));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0x00fff000, 0x05500000, 0 }, &words);
    instructions[1].src0.value = 64;
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(32, 12, &words));
    try std.testing.expectEqual(@as(u32, 0), words[1]);
    instructions[1].opcode = .s_bfm_b32;
    instructions[1].src0.value = 40;
    instructions[1].src1.value = 36;
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(32, 12, words[0..1]));
    try std.testing.expectEqual(@as(u32, 0xff0), words[0]);
    instructions[1].src0 = .{ .kind = .vgpr, .reg = 0 };
    resolver.remaining = 512;
    try std.testing.expect(!try resolver.words(32, 12, words[0..1]));
}

test "sampler shifts resolve inside a branch with no scalar snapshot" {
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    var instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_cbranch_execz, .branch_target = 20 },
        .{ .pc = 4, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 19 }, .src0 = .{ .kind = .integer_inline_constant, .value = 0 } },
        .{ .pc = 8, .opcode = .s_bfm_b64, .dst = .{ .kind = .sgpr, .reg = 16 }, .src0 = .{ .kind = .integer_inline_constant, .value = 12 }, .src1 = .{ .kind = .integer_inline_constant, .value = 44 } },
        .{ .pc = 12, .opcode = .s_lshl_b32, .dst = .{ .kind = .sgpr, .reg = 18 }, .src0 = .{ .kind = .integer_inline_constant, .value = 5 }, .src1 = .{ .kind = .integer_inline_constant, .value = 24 } },
        .{ .pc = 16, .opcode = .s_nop },
        .{ .pc = 20, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    var snapshot = scalar.Evaluation{};
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers };
    var words: [4]u32 = undefined;
    try std.testing.expect(try resolver.words(16, 16, &words));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0x00fff000, 0x05000000, 0 }, &words);
    instructions[3].src1.value = 56; // shift amount wraps to five bits
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(16, 16, &words));
    try std.testing.expectEqual(@as(u32, 0x05000000), words[2]);
    instructions[3].src0 = .{ .kind = .literal_constant, .value = 0x80000000 };
    instructions[3].opcode = .s_lshr_b32;
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(16, 16, &words));
    try std.testing.expectEqual(@as(u32, 0x80), words[2]);
    instructions[3].opcode = .s_ashr_i32;
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(16, 16, &words));
    try std.testing.expectEqual(@as(u32, 0xffffff80), words[2]);
    instructions[3].src0 = .{ .kind = .sgpr, .reg = 2 };
    resolver.remaining = 512;
    try std.testing.expect(!try resolver.words(16, 16, &words));
}

test "scalar resource offsets recover wrapping multiplication before register reuse" {
    const instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_mul_i32, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .sgpr, .reg = 1 } },
        .{ .pc = 4, .opcode = .s_mulk_i32, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .sgpr, .reg = 4 }, .src1 = .{ .kind = .integer_inline_constant, .value = 3 } },
        .{ .pc = 8, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .integer_inline_constant, .value = 999 } },
        .{ .pc = 12, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x8000_0001;
    bindings.user_data[1] = 136;
    var snapshot = scalar.Evaluation{};
    snapshot.registers[4] = .{ .known = true, .value = 999, .producer_pc = 8 };
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers };
    var value: [1]u32 = undefined;
    try std.testing.expect(try resolver.words(4, 8, &value));
    try std.testing.expectEqual(@as(u32, 408), value[0]);
    bindings.user_data_count = 0;
    try std.testing.expect(!try resolver.words(4, 8, &value));
}

test "nested descriptor recovery shares pointer work and refreshes between calls" {
    const M = struct {
        data: [2048]u8 = @splat(0),
        reads: usize = 0,
        fn read(context: ?*anyopaque, address: u64, out: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address < 0x1000 or address + out.len > 0x1000 + self.data.len) return false;
            self.reads += 1;
            @memcpy(out, self.data[@intCast(address - 0x1000)..][0..out.len]);
            return true;
        }
    };
    var memory = M{};
    var instructions: [7]rdna2.Instruction = undefined;
    // Six uniform pointer levels require exponentially many reads if each
    // descriptor word independently follows both halves of every pointer.
    for (0..5) |i| {
        std.mem.writeInt(u64, memory.data[i * 128 ..][0..8], 0x1000 + (i + 1) * 128, .little);
        instructions[i] = .{ .pc = @intCast(i * 8), .opcode = .s_load_dwordx2, .dst = .{ .kind = .sgpr, .reg = @intCast(4 + i * 2) }, .src0 = .{ .kind = .sgpr, .reg = @intCast(if (i == 0) 0 else 2 + i * 2) }, .src1 = .{ .kind = .null }, .data_words = 2 };
    }
    const expected = [_]u32{ 0x321, 0x400, 0x222, 0x94000000, 0x123, 0, 0, 0 };
    for (expected, 0..) |word, i| std.mem.writeInt(u32, memory.data[640 + i * 4 ..][0..4], word, .little);
    instructions[5] = .{ .pc = 40, .opcode = .s_load_dwordx8, .dst = .{ .kind = .sgpr, .reg = 36 }, .src0 = .{ .kind = .sgpr, .reg = 12 }, .src1 = .{ .kind = .null }, .data_words = 8 };
    instructions[6] = .{ .pc = 48, .opcode = .s_endpgm };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x1000;
    const snapshot = scalar.Evaluation{};
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = &memory, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers };
    var actual: [8]u32 = undefined;
    try std.testing.expect(try resolver.words(36, 48, &actual));
    try std.testing.expectEqualSlices(u32, &expected, &actual);
    try std.testing.expect(memory.reads <= 32);
    const cached_reads = memory.reads;
    resolver.memoize_values = false;
    resolver.remaining = 4096;
    memory.reads = 0;
    try std.testing.expect(try resolver.words(36, 48, &actual));
    try std.testing.expectEqualSlices(u32, &expected, &actual);
    try std.testing.expect(memory.reads > cached_reads * 4);
    std.debug.print("nested descriptor reads: uncached={d} cached={d}\n", .{ memory.reads, cached_reads });
    resolver.memoize_values = true;
    // Change an intermediate pointer and the payload, reusing the Resolver.
    std.mem.writeInt(u64, memory.data[512..520], 0x1400, .little);
    for (expected, 0..) |word, i| std.mem.writeInt(u32, memory.data[1024 + i * 4 ..][0..4], word + 7, .little);
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(36, 48, &actual));
    for (expected, actual) |word, value| try std.testing.expectEqual(word + 7, value);
    std.mem.writeInt(u64, memory.data[512..520], 0x9000, .little);
    resolver.remaining = 512;
    try std.testing.expectError(error.MemoryReadFailed, resolver.words(36, 48, &actual));
}

test "scalar resource value reuse keeps the reaching instruction in its key" {
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    const instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .integer_inline_constant, .value = 13 } },
        .{ .pc = 4, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 16 }, .src0 = .{ .kind = .sgpr, .reg = 4 } },
        .{ .pc = 8, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .integer_inline_constant, .value = 29 } },
        .{ .pc = 12, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 17 }, .src0 = .{ .kind = .sgpr, .reg = 4 } },
        .{ .pc = 16, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    const bindings = std.mem.zeroes(shaders.StageBindings);
    const snapshot = scalar.Evaluation{};
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers };
    var words: [2]u32 = undefined;
    try std.testing.expect(try resolver.words(16, 16, &words));
    try std.testing.expectEqualSlices(u32, &.{ 13, 29 }, &words);
}

test "scalar resource recovery follows nested loads after USER_DATA reuse" {
    const Memory = struct {
        data: [256]u8 = @splat(0),
        reads: usize = 0,
        fn read(context: ?*anyopaque, address: u64, output: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.reads += 1;
            if (address < 0x1000 or address - 0x1000 > self.data.len or output.len > self.data.len - (address - 0x1000)) return false;
            @memcpy(output, self.data[@intCast(address - 0x1000)..][0..output.len]);
            return true;
        }
    };
    var memory = Memory{};
    std.mem.writeInt(u64, memory.data[0..8], 0x1080, .little);
    std.mem.writeInt(u64, memory.data[136..144], 0x10c0, .little);
    const descriptor = [_]u32{ 0x1020, 4 << 16, 4, 0x5204 };
    for (descriptor, 0..) |value, part| std.mem.writeInt(u32, memory.data[208 + part * 4 ..][0..4], value, .little);
    for (0..4) |part| std.mem.writeInt(u32, memory.data[32 + part * 4 ..][0..4], @intCast(11 + part), .little);
    const s0 = rdna2.Operand{ .kind = .sgpr, .reg = 0 };
    const s4 = rdna2.Operand{ .kind = .sgpr, .reg = 4 };
    const s16 = rdna2.Operand{ .kind = .sgpr, .reg = 16 };
    const s20 = rdna2.Operand{ .kind = .sgpr, .reg = 20 };
    const s32 = rdna2.Operand{ .kind = .sgpr, .reg = 32 };
    var instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_load_dwordx2, .dst = s32, .src0 = s0, .src1 = .{ .kind = .null }, .data_words = 2 },
        .{ .pc = 8, .opcode = .s_load_dwordx2, .dst = s4, .src0 = s32, .src1 = .{ .kind = .null }, .memory_offset = 8, .data_words = 2 },
        .{ .pc = 16, .opcode = .s_load_dwordx4, .dst = s16, .src0 = s4, .src1 = .{ .kind = .null }, .memory_offset = 16, .data_words = 4 },
        .{ .pc = 24, .opcode = .s_buffer_load_dwordx4, .dst = s20, .src0 = s16, .src1 = .{ .kind = .null }, .memory_offset = 14, .data_words = 4 },
        .{ .pc = 32, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 6;
    bindings.user_data[0] = 0x1000;
    bindings.user_data[4] = 0x20;
    bindings.user_data[5] = 0x5204;
    var snapshot = scalar.Evaluation{};
    snapshot.registers[4] = .{ .known = true, .value = 0xdead, .producer_pc = 100 };
    // Even a matching producer must not bypass the descriptor bounds check.
    snapshot.registers[21] = .{ .known = true, .value = 0x700000, .producer_pc = 24 };
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = &memory, .read_fn = Memory.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers };
    var cache = definitions.ScalarDefinitionCache.init(std.testing.allocator, &instructions, &graph);
    defer cache.deinit();
    var words: [4]u32 = undefined;
    // This comparison isolates definition lookup caching, not value reuse.
    resolver.memoize_values = false;
    var reference_reads: usize = 0;
    var reference_remaining: usize = 0;
    for (0..4) |mode| {
        resolver.memoize_definitions = mode != 0;
        resolver.definition_cache = if (mode >= 2) &cache else null;
        resolver.remaining = 512;
        memory.reads = 0;
        try std.testing.expect(try resolver.words(16, 24, &words));
        try std.testing.expectEqualSlices(u32, &descriptor, &words);
        if (mode != 0) {
            try std.testing.expect(resolver.definition_batch.hits > 0);
            try std.testing.expectEqual(reference_reads, memory.reads);
            try std.testing.expectEqual(reference_remaining, resolver.remaining);
            if (mode == 3) {
                try std.testing.expect(resolver.definition_batch.persistent_hits > 0);
                try std.testing.expectEqual(@as(u64, 0), resolver.definition_batch.persistent_misses);
            }
        } else {
            reference_reads = memory.reads;
            reference_remaining = resolver.remaining;
        }
    }
    // Runtime data is read again on the next recovery, even at the same PC.
    std.mem.writeInt(u32, memory.data[208..212], 0x1030, .little);
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(16, 24, &words));
    try std.testing.expectEqual(@as(u32, 0x1030), words[0]);
    std.mem.writeInt(u32, memory.data[208..212], descriptor[0], .little);
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(16, 24, &words));
    try std.testing.expectEqualSlices(u32, &descriptor, &words);
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(20, 32, &words));
    try std.testing.expectEqualSlices(u32, &.{ 14, 0, 0, 0 }, &words);
    // A real inaccessible producer remains a read error, unlike an unknown
    // data-dependent register for which no address can be established.
    std.mem.writeInt(u64, memory.data[136..144], 0x9000, .little);
    resolver.remaining = 512;
    try std.testing.expectError(error.MemoryReadFailed, resolver.words(16, 24, &words));
    std.mem.writeInt(u64, memory.data[136..144], 0x10c0, .little);
    // A warm cache must still respect the caller's recursion/work limit.
    resolver.remaining = 1;
    try std.testing.expect(!try resolver.words(16, 24, &words));
    try std.testing.expectEqual(@as(usize, 0), resolver.remaining);
    // Even entry register values are fresh across recoveries.
    bindings.user_data[0] = 0x1008;
    std.mem.writeInt(u64, memory.data[8..16], 0x1080, .little);
    resolver.remaining = 512;
    try std.testing.expect(try resolver.words(16, 24, &words));
    try std.testing.expectEqualSlices(u32, &descriptor, &words);
}

test "persistent recovery rejects another program or control flow at the same PCs" {
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    const original = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .sgpr, .reg = 0 } },
        .{ .pc = 4, .opcode = .s_endpgm },
    };
    var replacement = original;
    replacement[0].src0.reg = 1;
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &original);
    defer graph.deinit(std.testing.allocator);
    var other_graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &replacement);
    defer other_graph.deinit(std.testing.allocator);
    var cache = definitions.ScalarDefinitionCache.init(std.testing.allocator, &original, &graph);
    defer cache.deinit();
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 10;
    bindings.user_data[1] = 20;
    const snapshot = scalar.Evaluation{};
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &original, .graph = &graph, .snapshot = &snapshot.registers, .definition_cache = &cache };
    var words: [1]u32 = undefined;
    try std.testing.expect(try resolver.words(4, 4, &words));
    try std.testing.expectEqual(@as(u32, 10), words[0]);
    resolver.instructions = &replacement;
    try std.testing.expect(try resolver.words(4, 4, &words));
    try std.testing.expectEqual(@as(u32, 20), words[0]);
    try std.testing.expect(resolver.definition_batch.persistent == null);
    resolver.instructions = &original;
    resolver.graph = &other_graph;
    try std.testing.expect(try resolver.words(4, 4, &words));
    try std.testing.expectEqual(@as(u32, 10), words[0]);
    try std.testing.expect(resolver.definition_batch.persistent == null);
}

test "scalar resource recovery rejects skipped writers and clobbered halves" {
    const M = struct {
        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }
    };
    var instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_cbranch_execz, .branch_target = 12 },
        .{ .pc = 4, .opcode = .s_mov_b64, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .sgpr, .reg = 0 } },
        .{ .pc = 8, .opcode = .s_nop },
        .{ .pc = 12, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &instructions);
    defer graph.deinit(std.testing.allocator);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 6;
    bindings.user_data[0] = 0x1020;
    bindings.user_data[4] = 0x1000;
    const snapshot = scalar.Evaluation{};
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot.registers };
    var words: [2]u32 = undefined;
    try std.testing.expect(!try resolver.words(4, 12, &words));
    // Entry words remain available only at their actual physical SGPR base.
    try std.testing.expect(try resolver.words(0, 12, &words));
    try std.testing.expectEqual(@as(u32, 0x1020), words[0]);
    bindings.scalar_user_data_base = 8;
    try std.testing.expect(!try resolver.words(0, 12, &words));
    try std.testing.expect(try resolver.words(8, 12, &words));
    try std.testing.expectEqual(@as(u32, 0x1020), words[0]);
    bindings.scalar_user_data_base = 0;
    instructions[2] = .{ .pc = 8, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 1 }, .src0 = .{ .kind = .vgpr, .reg = 0 } };
    try std.testing.expect(!try resolver.words(0, 12, &words));
}
