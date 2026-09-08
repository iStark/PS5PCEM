// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Recover uniform resource words through their actual reaching definitions.
//! A reused SGPR must never fall back to an unrelated entry USER_DATA value.
const std = @import("std");
const rdna2 = @import("rdna2");
const shaders = @import("shaders.zig");
const scalar = @import("scalar_provenance.zig");
const definitions = @import("index_bounds.zig");

/// Diagnostic switch sampled once per recovery, allowing same-process timing.
pub var definition_cache_enabled = std.atomic.Value(bool).init(true);
pub var definition_cache_hits = std.atomic.Value(u64).init(0);
pub var definition_cache_misses = std.atomic.Value(u64).init(0);
pub var persistent_definition_cache_enabled = std.atomic.Value(bool).init(true);
pub var persistent_definition_cache_hits = std.atomic.Value(u64).init(0);
pub var persistent_definition_cache_misses = std.atomic.Value(u64).init(0);

pub const Resolver = struct {
    bindings: *const shaders.StageBindings,
    reader: shaders.MemoryReader,
    instructions: []const rdna2.Instruction,
    graph: *const rdna2.control_flow.Graph,
    snapshot: *const scalar.Evaluation,
    remaining: usize = 512,
    memoize_definitions: bool = true,
    definition_cache: ?*definitions.ScalarDefinitionCache = null,
    definition_batch: definitions.ScalarDefinitionBatch = undefined,
    batch_enabled: bool = false,

    pub fn words(self: *Resolver, register: u32, before_pc: u32, output: []u32) !bool {
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
        var before: usize = 0;
        while (before < self.instructions.len and self.instructions[before].pc < before_pc) : (before += 1) {}
        if (before == self.instructions.len) return false;
        for (output, 0..) |*value, component| value.* = (try self.word(register + @as(u32, @intCast(component)), before, 0)) orelse return false;
        return true;
    }

    fn operand(self: *Resolver, op: rdna2.Operand, component: u32, before: usize, depth: u8) anyerror!?u32 {
        if (op.absolute or op.negate or op.dpp) return null;
        if (scalar.scalarRegisterIndex(op)) |register| return self.word(@as(u32, @intCast(register)) + component, before, depth);
        return switch (op.kind) {
            .null => 0,
            .integer_inline_constant, .literal_constant => if (component == 0) op.value else if (op.value & 0x8000_0000 != 0) std.math.maxInt(u32) else 0,
            else => null,
        };
    }

    fn word(self: *Resolver, register: u32, before: usize, depth: u8) anyerror!?u32 {
        if (register >= scalar.maximum_scalar_registers or depth >= 24 or self.remaining == 0) return null;
        self.remaining -= 1;
        const definition = (if (self.batch_enabled)
            self.definition_batch.lookup(before, register)
        else
            definitions.scalarDefinition(self.instructions, self.graph, before, register)) orelse return null;
        const index = switch (definition) {
            .entry => {
                if (register < self.bindings.scalar_user_data_base) return null;
                const entry = register - self.bindings.scalar_user_data_base;
                return if (entry < self.bindings.user_data_count) self.bindings.user_data[entry] else null;
            },
            .instruction => |index| index,
        };
        const inst = self.instructions[index];
        const known = self.snapshot.registers[register];
        const destination = scalar.scalarRegisterIndex(inst.dst) orelse return null;
        if (register < destination) return null;
        const component: u32 = @intCast(register - destination);
        switch (inst.opcode) {
            .s_mov_b32, .s_mov_b64 => return self.operand(inst.src0, component, index, depth + 1),
            .s_mul_i32, .s_mulk_i32 => {
                if (component != 0) return null;
                const a = (try self.operand(inst.src0, 0, index, depth + 1)) orelse return null;
                const b = (try self.operand(inst.src1, 0, index, depth + 1)) orelse return null;
                return a *% b;
            },
            .s_movk_i32 => return @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(inst.src0.value)))))),
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
};

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
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot };
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
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot };
    var value: [1]u32 = undefined;
    try std.testing.expect(try resolver.words(4, 8, &value));
    try std.testing.expectEqual(@as(u32, 408), value[0]);
    bindings.user_data_count = 0;
    try std.testing.expect(!try resolver.words(4, 8, &value));
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
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = &memory, .read_fn = Memory.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot };
    var cache = definitions.ScalarDefinitionCache.init(std.testing.allocator, &instructions, &graph);
    defer cache.deinit();
    var words: [4]u32 = undefined;
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
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &original, .graph = &graph, .snapshot = &snapshot, .definition_cache = &cache };
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
    var resolver = Resolver{ .bindings = &bindings, .reader = .{ .context = null, .read_fn = M.read }, .instructions = &instructions, .graph = &graph, .snapshot = &snapshot };
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
