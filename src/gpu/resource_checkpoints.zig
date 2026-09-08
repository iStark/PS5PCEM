// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Immutable checkpoint locations and bounded, operation-local scalar scratch.
const std = @import("std");
const rdna2 = @import("rdna2");
const scalar = @import("scalar_provenance.zig");
const shaders = @import("shaders.zig");

pub const Kind = enum { resource, sampled };

/// Owned by the exact immutable decoded instruction allocation. Branch-pruned
/// analyses build their own locations; guest addresses are never cache keys.
pub const Plan = struct {
    instructions: []const rdna2.Instruction,
    resource: []const u32,
    sampled: []const u32,

    pub fn init(allocator: std.mem.Allocator, instructions: []const rdna2.Instruction) !Plan {
        const resource = try collect(allocator, instructions, .resource);
        errdefer allocator.free(resource);
        return .{ .instructions = instructions, .resource = resource, .sampled = try collect(allocator, instructions, .sampled) };
    }

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.resource);
        allocator.free(self.sampled);
        self.* = undefined;
    }

    pub fn matches(self: *const Plan, instructions: []const rdna2.Instruction) bool {
        return self.instructions.ptr == instructions.ptr and self.instructions.len == instructions.len;
    }

    fn pcs(self: *const Plan, kind: Kind) []const u32 {
        return switch (kind) {
            .resource => self.resource,
            .sampled => self.sampled,
        };
    }
};

fn collect(allocator: std.mem.Allocator, instructions: []const rdna2.Instruction, kind: Kind) ![]const u32 {
    var count: usize = 0;
    for (instructions) |inst| if (needsCheckpoint(inst, kind)) {
        count += 1;
    };
    const result = try allocator.alloc(u32, count);
    var index: usize = 0;
    for (instructions) |inst| {
        if (!needsCheckpoint(inst, kind)) continue;
        result[index] = inst.pc;
        index += 1;
    }
    return result;
}

/// Leases leave the pool until release. Nested preparations cannot overwrite
/// a caller's snapshots. Use one allocator and renderer thread for this pool.
pub const Pool = struct {
    pub const maximum_entry_count = 32 * 1024 * 1024 / @sizeOf(scalar.ScalarRegisters);
    entries: [2][]scalar.ScalarRegisters = @splat(&.{}),
    /// Diagnostic control: disabled uses fresh lists and allocations.
    enabled: bool = true,

    pub const Lease = struct {
        pcs: []const u32,
        snapshots: []scalar.ScalarRegisters,
        allocation: []scalar.ScalarRegisters,
        owned_pcs: ?[]const u32,
        pool: *Pool,
        allocator: std.mem.Allocator,
        plan_reused: bool,
        scratch_reused: bool,
        cacheable: bool,

        pub fn release(self: *Lease) void {
            if (self.owned_pcs) |pcs_| self.allocator.free(pcs_);
            if (self.cacheable and self.pool.enabled) {
                var smallest: usize = 0;
                for (self.pool.entries, 0..) |entry, index|
                    if (entry.len < self.pool.entries[smallest].len) {
                        smallest = index;
                    };
                if (self.allocation.len > self.pool.entries[smallest].len) {
                    self.allocator.free(self.pool.entries[smallest]);
                    self.pool.entries[smallest] = self.allocation;
                    self.* = undefined;
                    return;
                }
            }
            self.allocator.free(self.allocation);
            self.* = undefined;
        }
    };

    pub fn prepare(
        self: *Pool,
        allocator: std.mem.Allocator,
        instructions: []const rdna2.Instruction,
        plan: ?*const Plan,
        kind: Kind,
        reader: shaders.MemoryReader,
        bindings: *const shaders.StageBindings,
    ) !Lease {
        const plan_reused = self.enabled and plan != null and plan.?.matches(instructions);
        const pcs = if (plan_reused) plan.?.pcs(kind) else try collect(allocator, instructions, kind);
        errdefer if (!plan_reused) allocator.free(pcs);
        const cacheable = self.enabled and pcs.len != 0 and pcs.len <= maximum_entry_count;
        var allocation: ?[]scalar.ScalarRegisters = null;
        if (cacheable) {
            var best: ?usize = null;
            for (self.entries, 0..) |entry, index| {
                if (entry.len >= pcs.len and (best == null or entry.len < self.entries[best.?].len)) best = index;
            }
            if (best) |index| {
                allocation = self.entries[index];
                self.entries[index] = &.{};
            }
        }
        const scratch_reused = allocation != null;
        const storage = allocation orelse try allocator.alloc(scalar.ScalarRegisters, pcs.len);
        const snapshots = storage[0..pcs.len];
        if (pcs.len != 0) {
            // The evaluator resets every snapshot, including skipped blocks,
            // before reading current USER_DATA and guest memory. No values live
            // across preparations, even after an early stop or failed read.
            _ = scalar.evaluateDecodedResourceStateAtCheckpoints(reader, bindings, instructions, pcs, snapshots);
        }
        return .{
            .pcs = pcs,
            .snapshots = snapshots,
            .allocation = storage,
            .owned_pcs = if (plan_reused) null else pcs,
            .pool = self,
            .allocator = allocator,
            .plan_reused = plan_reused,
            .scratch_reused = scratch_reused,
            .cacheable = cacheable,
        };
    }

    pub fn deinit(self: *Pool, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            allocator.free(entry.*);
            entry.* = &.{};
        }
    }
};

pub fn needsCheckpoint(inst: rdna2.Instruction, kind: Kind) bool {
    return switch (kind) {
        .resource => needsResource(inst),
        .sampled => inst.opcode == .image_load or inst.opcode == .image_load_mip or
            inst.opcode == .image_sample or inst.opcode == .image_gather4 or inst.opcode == .image_get_lod,
    };
}

fn needsResource(inst: rdna2.Instruction) bool {
    return switch (inst.opcode) {
        .s_load_dword,
        .s_load_dwordx2,
        .s_load_dwordx4,
        .s_load_dwordx8,
        .s_load_dwordx16,
        .buffer_load_ubyte,
        .buffer_load_sbyte,
        .buffer_load_ushort,
        .buffer_load_sshort,
        .buffer_load_ubyte_d16,
        .buffer_load_ubyte_d16_hi,
        .buffer_load_sbyte_d16,
        .buffer_load_sbyte_d16_hi,
        .buffer_load_short_d16,
        .buffer_load_short_d16_hi,
        .buffer_load_dword,
        .buffer_load_dwordx2,
        .buffer_load_dwordx3,
        .buffer_load_dwordx4,
        .buffer_load_format_x,
        .buffer_load_format_xy,
        .buffer_load_format_xyz,
        .buffer_load_format_xyzw,
        .buffer_load_format_d16_x,
        .buffer_load_format_d16_xy,
        .buffer_load_format_d16_xyz,
        .buffer_load_format_d16_xyzw,
        .s_buffer_load_dword,
        .s_buffer_load_dwordx2,
        .s_buffer_load_dwordx4,
        .s_buffer_load_dwordx8,
        .s_buffer_load_dwordx16,
        .buffer_store_byte,
        .buffer_store_short,
        .buffer_store_short_d16_hi,
        .buffer_store_dword,
        .buffer_store_dwordx2,
        .buffer_store_dwordx3,
        .buffer_store_dwordx4,
        .buffer_store_format_x,
        .buffer_store_format_xy,
        .buffer_store_format_xyz,
        .buffer_store_format_xyzw,
        .buffer_store_format_d16_x,
        .buffer_store_format_d16_hi_x,
        .buffer_store_format_d16_xy,
        .buffer_store_format_d16_xyz,
        .buffer_store_format_d16_xyzw,
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
        .image_load,
        .image_load_mip,
        .image_store,
        .image_store_mip,
        .image_atomic_add,
        .image_atomic_umin,
        .image_atomic_umax,
        .image_atomic_and,
        .image_atomic_or,
        .image_atomic_xor,
        .image_atomic_fmax,
        .image_sample,
        .image_gather4,
        => true,
        else => false,
    };
}

const TestMemory = struct {
    value: ?u32 = 0,
    reads: usize = 0,

    fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
        const self: *TestMemory = @ptrCast(@alignCast(context.?));
        self.reads += 1;
        if (address != 0x4000 or destination.len != 4) return false;
        std.mem.writeInt(u32, destination[0..4], self.value orelse return false, .little);
        return true;
    }

    fn reader(self: *TestMemory) shaders.MemoryReader {
        return .{ .context = self, .read_fn = read };
    }
};

test "checkpoint reuse keeps guest reads fresh and clears skipped or failed states" {
    const a = std.testing.allocator;
    const code = [_]u32{
        0xf400_1a80, 125 << 25, // s_load_dword vcc_lo, s0:s1
        0xbefe_04c1, // s_mov_b64 exec, -1
        0xbf8c_007f,
        0xbf07_6a80, // s_cmp_lg_u32 0, vcc_lo
        0xbf84_0002, // skip image_store when zero
        0xf020_0f28,
        0x0002_0400,
        0xbf81_0000,
    };
    var program = try rdna2.decodeProgram(a, &code);
    defer program.deinit(a);
    var plan = try Plan.init(a, program.instructions.items);
    defer plan.deinit(a);
    var pool = Pool{};
    defer pool.deinit(a);
    var fresh_pool = Pool{ .enabled = false };
    defer fresh_pool.deinit(a);
    var memory = TestMemory{};
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x4000;
    for ([_]?u32{ 1, 0, null, 7, 0 }, 0..) |value, iteration| {
        memory.value = value;
        memory.reads = 0;
        var fresh = try fresh_pool.prepare(a, program.instructions.items, &plan, .resource, memory.reader(), &bindings);
        defer fresh.release();
        const expected_reads = memory.reads;
        memory.reads = 0;
        var reused = try pool.prepare(a, program.instructions.items, &plan, .resource, memory.reader(), &bindings);
        defer reused.release();
        try std.testing.expect(reused.plan_reused);
        try std.testing.expectEqual(iteration != 0, reused.scratch_reused);
        try std.testing.expectEqual(expected_reads, memory.reads);
        try std.testing.expectEqualSlices(u32, fresh.pcs, reused.pcs);
        try std.testing.expectEqualDeep(fresh.snapshots, reused.snapshots);
        try std.testing.expectEqual(@as(usize, 2), reused.pcs.len);
        if (value) |word| {
            try std.testing.expectEqual(word != 0, reused.snapshots[1][106].known);
            if (word != 0) try std.testing.expectEqual(word, reused.snapshots[1][106].value);
        }
        // Poison the retained bytes: the next skipped block must not inherit
        // this value, nor anything recovered by an earlier invocation.
        for (reused.snapshots) |*snapshot| snapshot.* = @splat(.{ .known = true, .value = 0xdeadbeef });
    }
}

test "checkpoint leases isolate nested callers and reject another instruction allocation" {
    const a = std.testing.allocator;
    const instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .image_load },
        .{ .pc = 8, .opcode = .image_get_lod },
        .{ .pc = 16, .opcode = .s_endpgm, .word_count = 1 },
    };
    var plan = try Plan.init(a, &instructions);
    defer plan.deinit(a);
    try std.testing.expectEqualSlices(u32, &.{0}, plan.resource);
    try std.testing.expectEqualSlices(u32, &.{ 0, 8 }, plan.sampled);
    var pool = Pool{};
    defer pool.deinit(a);
    var memory = TestMemory{};
    const bindings = std.mem.zeroes(shaders.StageBindings);
    var first = try pool.prepare(a, &instructions, &plan, .sampled, memory.reader(), &bindings);
    first.release();
    var outer = try pool.prepare(a, &instructions, &plan, .resource, memory.reader(), &bindings);
    defer outer.release();
    try std.testing.expect(outer.scratch_reused);
    outer.snapshots[0][3] = .{ .known = true, .value = 0x5678 };
    const nested = struct {
        fn run(p: *Pool, program: []const rdna2.Instruction, cp: *const Plan, reader: shaders.MemoryReader, b: *const shaders.StageBindings, parent: []scalar.ScalarRegisters) !void {
            var lease = try p.prepare(std.testing.allocator, program, cp, .sampled, reader, b);
            defer lease.release();
            try std.testing.expect(lease.snapshots.ptr != parent.ptr);
            lease.snapshots[0][3] = .{};
            return error.SyntheticPreparationFailure;
        }
    };
    try std.testing.expectError(error.SyntheticPreparationFailure, nested.run(&pool, &instructions, &plan, memory.reader(), &bindings, outer.snapshots));
    try std.testing.expectEqual(@as(u32, 0x5678), outer.snapshots[0][3].value);
    const replacement = try a.dupe(rdna2.Instruction, &instructions);
    defer a.free(replacement);
    replacement[0].opcode = .s_nop;
    var replaced = try pool.prepare(a, replacement, &plan, .sampled, memory.reader(), &bindings);
    defer replaced.release();
    try std.testing.expect(!replaced.plan_reused);
    try std.testing.expectEqualSlices(u32, &.{8}, replaced.pcs);
    pool.enabled = false;
    var disabled = try pool.prepare(a, &instructions, &plan, .sampled, memory.reader(), &bindings);
    defer disabled.release();
    try std.testing.expect(!disabled.plan_reused and !disabled.scratch_reused);
    try std.testing.expectEqual(@as(u32, 0x5678), outer.snapshots[0][3].value);
}

fn checkAllocationFailures(allocator: std.mem.Allocator) !void {
    const instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .image_load },
        .{ .pc = 8, .opcode = .s_endpgm, .word_count = 1 },
    };
    var plan = try Plan.init(allocator, &instructions);
    defer plan.deinit(allocator);
    var pool = Pool{};
    defer pool.deinit(allocator);
    var memory = TestMemory{};
    const bindings = std.mem.zeroes(shaders.StageBindings);
    var cached = try pool.prepare(allocator, &instructions, &plan, .resource, memory.reader(), &bindings);
    defer cached.release();
    var fallback = try pool.prepare(allocator, &instructions, null, .sampled, memory.reader(), &bindings);
    defer fallback.release();
}

test "checkpoint plan and scratch allocation failures release partial ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllocationFailures, .{});
}
