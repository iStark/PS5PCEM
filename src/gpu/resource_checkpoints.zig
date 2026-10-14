// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Immutable checkpoint locations and bounded, operation-local scalar scratch.
const std = @import("std");
const rdna2 = @import("rdna2");
const scalar = @import("scalar_provenance.zig");
const shaders = @import("shaders.zig");

pub const Kind = enum { resource, sampled };
pub export var cached_graphics_interfaces: bool = true;

pub const GraphicsInterface = struct {
    exports: u64 = 0,
    parameters: u32 = 0,
    attributes: u32 = 0,
    components: [32]u4 = @splat(0),
    color_attachments: u32 = 0,

    fn collect(instructions: []const rdna2.Instruction) GraphicsInterface {
        var result = GraphicsInterface{};
        for (instructions) |inst| {
            if (inst.opcode == .exp) {
                result.exports |= @as(u64, 1) << inst.export_target;
                if (inst.export_target >= 0x20) result.parameters |= @as(u32, 1) << @intCast(inst.export_target - 0x20);
                if (inst.export_target < @import("resources.zig").color_target_count)
                    result.color_attachments = @max(result.color_attachments, @as(u32, inst.export_target) + 1);
            }
            switch (inst.opcode) {
                .v_interp_p1_f32, .v_interp_p2_f32, .v_interp_mov_f32 => {
                    if (inst.src1.kind == .integer_inline_constant and inst.src1.value < 32) {
                        const attribute: usize = @intCast(inst.src1.value);
                        result.attributes |= @as(u32, 1) << @intCast(attribute);
                        if (inst.src2.value < 4) result.components[attribute] |= @as(u4, 1) << @intCast(inst.src2.value);
                    }
                },
                else => {},
            }
        }
        return result;
    }
};

/// Interface declarations belong to the exact immutable decoded allocation.
/// Inlined fetch programs and uncached specializations collect their own data.
pub fn graphicsInterface(instructions: []const rdna2.Instruction, plan: ?*const Plan) GraphicsInterface {
    if (@atomicLoad(bool, &cached_graphics_interfaces, .monotonic)) {
        if (plan) |retained| if (retained.matches(instructions)) {
            if (retained.graphics_interface) |interface| return interface;
        };
    }
    return GraphicsInterface.collect(instructions);
}

var next_plan_identity: std.atomic.Value(u64) = .init(1);

/// Owned by the exact immutable decoded instruction allocation. Branch-pruned
/// analyses build their own locations; guest addresses are never cache keys.
pub const Plan = struct {
    /// Distinguishes immutable analyses even if their allocations are reused.
    /// A manually constructed plan has no cross-operation cache identity.
    identity: u64 = 0,
    instructions: []const rdna2.Instruction,
    resource: []const u32,
    sampled: []const u32,
    resource_indices: []const u32,
    sampled_indices: []const u32,
    /// Indices, not program counters: the storage-image pass needs the
    /// instruction itself, and these never reach the checkpoint evaluator.
    storage_images: []const u32,
    /// Instruction indices the scalar checkpoint walk must execute. Vector
    /// opcodes that cannot change a scalar register or a checkpoint are absent.
    scalar_steps: []const u32,
    reads_only_resources: bool,
    /// A full walk and the sparse checkpoint walks cannot exhaust different
    /// loop budgets when control flow only moves forward and there are no calls.
    forward_only: bool,
    /// Conservative ratio between dense visits and indexed visits, including
    /// a branch landing inside a skipped vector run. Manual plans opt out.
    maximum_dense_step_ratio: u32 = std.math.maxInt(u32),
    graphics_interface: ?GraphicsInterface = null,
    static_calls: ?bool = null,
    /// Only the entry block can supply unconditional, single-visit snapshots.
    /// Manual plans deliberately provide no proof.
    entry_block_end: u32 = 0,
    /// Scalar inputs consumed by uniform control-flow interpretation. Manual
    /// plans opt out; this summary belongs to the exact decoded allocation.
    uniform_scalar_reads: ?u128 = null,

    pub fn init(allocator: std.mem.Allocator, instructions: []const rdna2.Instruction) !Plan {
        const resource = try collect(allocator, instructions, .resource);
        errdefer allocator.free(resource);
        const sampled = try collect(allocator, instructions, .sampled);
        errdefer allocator.free(sampled);
        const resource_indices = try collectIndices(allocator, instructions, .resource, resource.len);
        errdefer allocator.free(resource_indices);
        const sampled_indices = try collectIndices(allocator, instructions, .sampled, sampled.len);
        errdefer allocator.free(sampled_indices);
        const storage_images = try collectStorageImages(allocator, instructions);
        errdefer allocator.free(storage_images);
        const scalar_steps = try collectScalarSteps(allocator, instructions, resource, sampled);
        return .{
            .identity = next_plan_identity.fetchAdd(1, .monotonic),
            .instructions = instructions,
            .resource = resource,
            .sampled = sampled,
            .resource_indices = resource_indices,
            .sampled_indices = sampled_indices,
            .storage_images = storage_images,
            .scalar_steps = scalar_steps,
            .reads_only_resources = readsOnlyResources(instructions),
            .forward_only = walksForward(instructions),
            .maximum_dense_step_ratio = maximumDenseStepRatio(instructions.len, scalar_steps),
            .graphics_interface = GraphicsInterface.collect(instructions),
            .static_calls = rdna2.scalar_calls.present(instructions),
            .entry_block_end = entryBlockEnd(instructions),
            .uniform_scalar_reads = scalar.uniformScalarReadMask(instructions),
        };
    }

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.resource);
        allocator.free(self.sampled);
        allocator.free(self.resource_indices);
        allocator.free(self.sampled_indices);
        allocator.free(self.storage_images);
        allocator.free(self.scalar_steps);
        self.* = undefined;
    }

    /// The storage-image instructions, in program order, when this plan was
    /// built for exactly `instructions`. Null asks the caller to walk them
    /// itself, which a branch-pruned analysis carrying its own instruction
    /// allocation must do.
    pub fn storageImageIndices(self: *const Plan, instructions: []const rdna2.Instruction) ?[]const u32 {
        return if (self.matches(instructions)) self.storage_images else null;
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

fn maximumDenseStepRatio(instruction_count: usize, steps: []const u32) u32 {
    if (steps.len == 0) return std.math.maxInt(u32);
    var maximum: usize = steps[0] + 1;
    for (steps[1..], steps[0 .. steps.len - 1]) |next, previous| maximum = @max(maximum, next - previous);
    return @intCast(@max(maximum, instruction_count - steps[steps.len - 1]));
}

test "retained graphics interfaces distinguish reconstructed programs and absent plans" {
    const a = std.testing.allocator;
    const saved = cached_graphics_interfaces;
    defer cached_graphics_interfaces = saved;
    const first = [_]rdna2.Instruction{
        .{ .pc = 0, .family = .exp, .opcode = .exp, .export_target = 0x20 },
        .{ .pc = 8, .family = .exp, .opcode = .exp, .export_target = 0x27 },
        .{ .pc = 16, .family = .exp, .opcode = .exp, .export_target = 5 },
        .{ .pc = 24, .family = .vintrp, .opcode = .v_interp_p1_f32, .src1 = .{ .kind = .integer_inline_constant, .value = 2 }, .src2 = .{ .kind = .integer_inline_constant, .value = 0 } },
        .{ .pc = 28, .family = .vintrp, .opcode = .v_interp_p2_f32, .src1 = .{ .kind = .integer_inline_constant, .value = 2 }, .src2 = .{ .kind = .integer_inline_constant, .value = 3 } },
    };
    const second = [_]rdna2.Instruction{
        .{ .pc = 0, .family = .exp, .opcode = .exp, .export_target = 0x2f },
        .{ .pc = 8, .family = .exp, .opcode = .exp, .export_target = 1 },
    };
    var retained = try Plan.init(a, &first);
    defer retained.deinit(a);
    for ([_]bool{ false, true }) |enabled| {
        cached_graphics_interfaces = enabled;
        const original = graphicsInterface(&first, &retained);
        try std.testing.expectEqual(@as(u32, 0x81), original.parameters);
        try std.testing.expectEqual(@as(u32, 4), original.attributes);
        try std.testing.expectEqual(@as(u4, 9), original.components[2]);
        try std.testing.expectEqual(@as(u32, 6), original.color_attachments);
        try std.testing.expectEqualDeep(original, graphicsInterface(&first, null));
        const replaced = graphicsInterface(&second, &retained);
        try std.testing.expectEqual(@as(u32, 1 << 15), replaced.parameters);
        try std.testing.expectEqual(@as(u32, 0), replaced.attributes);
        try std.testing.expectEqual(@as(u32, 2), replaced.color_attachments);
        try std.testing.expectEqualDeep(replaced, graphicsInterface(&second, null));
        // A manual plan has no retained interface even if its slice matches.
        const interface = retained.graphics_interface;
        retained.graphics_interface = null;
        try std.testing.expectEqualDeep(original, graphicsInterface(&first, &retained));
        retained.graphics_interface = interface;
    }
}

fn walksForward(instructions: []const rdna2.Instruction) bool {
    for (instructions) |inst| switch (inst.opcode) {
        .s_setpc_b64, .s_call_b64, .s_swappc_b64 => return false,
        .s_branch,
        .s_cbranch_scc0,
        .s_cbranch_scc1,
        .s_cbranch_vccz,
        .s_cbranch_vccnz,
        .s_cbranch_execz,
        .s_cbranch_execnz,
        => if (inst.branch_target <= inst.pc) return false,
        else => {},
    };
    return true;
}

fn entryBlockEnd(instructions: []const rdna2.Instruction) u32 {
    for (instructions) |inst| switch (inst.opcode) {
        .s_endpgm,
        .s_setpc_b64,
        .s_call_b64,
        .s_swappc_b64,
        .s_branch,
        .s_cbranch_scc0,
        .s_cbranch_scc1,
        .s_cbranch_vccz,
        .s_cbranch_vccnz,
        .s_cbranch_execz,
        .s_cbranch_execnz,
        => return inst.pc,
        else => {},
    };
    return 0;
}

test "shared scalar walk rejects loops and indirect transfers" {
    const a = std.testing.allocator;
    var instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .family = .sopp, .opcode = .s_cbranch_scc0, .branch_target = 8 },
        .{ .pc = 4, .family = .sopp, .opcode = .s_nop },
        .{ .pc = 8, .family = .sopp, .opcode = .s_endpgm },
    };
    var forward = try Plan.init(a, &instructions);
    defer forward.deinit(a);
    try std.testing.expect(forward.forward_only);
    instructions[1] = .{ .pc = 4, .family = .sopp, .opcode = .s_branch, .branch_target = 0 };
    var loop = try Plan.init(a, &instructions);
    defer loop.deinit(a);
    try std.testing.expect(!loop.forward_only);
    instructions[1] = .{ .pc = 4, .family = .sop1, .opcode = .s_setpc_b64 };
    var indirect = try Plan.init(a, &instructions);
    defer indirect.deinit(a);
    try std.testing.expect(!indirect.forward_only);
    for ([_]rdna2.Opcode{ .s_call_b64, .s_swappc_b64 }) |opcode| {
        instructions[1].opcode = opcode;
        var call = try Plan.init(a, &instructions);
        defer call.deinit(a);
        try std.testing.expect(!call.forward_only);
    }
}

/// Borrow immutable resource locations when they belong to this exact program.
/// Pruned or replaced instruction allocations use the same opcode filter directly.
pub const Iterator = struct {
    instructions: []const rdna2.Instruction,
    kind: Kind,
    indices: ?[]const u32,
    cursor: usize = 0,

    pub fn init(instructions: []const rdna2.Instruction, plan: ?*const Plan, kind: Kind) Iterator {
        return .{
            .instructions = instructions,
            .kind = kind,
            .indices = if (plan != null and plan.?.matches(instructions)) switch (kind) {
                .resource => plan.?.resource_indices,
                .sampled => plan.?.sampled_indices,
            } else null,
        };
    }

    pub fn next(self: *Iterator) ?usize {
        if (self.indices) |indices| {
            if (self.cursor == indices.len) return null;
            const index = indices[self.cursor];
            self.cursor += 1;
            return index;
        }
        while (self.cursor < self.instructions.len) {
            const index = self.cursor;
            self.cursor += 1;
            if (needsCheckpoint(self.instructions[index].opcode, self.kind)) return index;
        }
        return null;
    }
};

fn collectIndices(allocator: std.mem.Allocator, instructions: []const rdna2.Instruction, kind: Kind, count: usize) ![]const u32 {
    const indices = try allocator.alloc(u32, count);
    var destination: usize = 0;
    for (instructions, 0..) |*inst, index| {
        if (!needsCheckpoint(inst.opcode, kind)) continue;
        indices[destination] = @intCast(index);
        destination += 1;
    }
    return indices;
}

/// Static eligibility for resource reuse. Only explicitly decoded flat loads
/// prove read-only access; unknown operations, stores and atomics do not.
pub fn readsOnlyResources(instructions: []const rdna2.Instruction) bool {
    for (instructions) |inst| {
        if (inst.opcode == .unknown or inst.opcode == .unsupported) return false;
        if (inst.family == .flat) switch (inst.opcode) {
            .flat_load_ubyte,
            .flat_load_sbyte,
            .flat_load_ushort,
            .flat_load_sshort,
            .flat_load_dword,
            .flat_load_dwordx2,
            .flat_load_dwordx3,
            .flat_load_dwordx4,
            => {},
            else => return false,
        };
        const name = @tagName(inst.opcode);
        if (std.mem.startsWith(u8, name, "buffer_store") or std.mem.startsWith(u8, name, "tbuffer_store") or
            std.mem.startsWith(u8, name, "buffer_atomic") or std.mem.startsWith(u8, name, "image_store") or
            std.mem.startsWith(u8, name, "image_atomic") or std.mem.startsWith(u8, name, "s_store") or
            std.mem.startsWith(u8, name, "s_buffer_store") or std.mem.startsWith(u8, name, "s_atomic") or
            std.mem.startsWith(u8, name, "s_buffer_atomic")) return false;
    }
    return true;
}

test "read-only resource proof accepts flat loads but rejects stores and unknown memory" {
    const loads = [_]rdna2.Opcode{ .flat_load_ubyte, .flat_load_sbyte, .flat_load_ushort, .flat_load_sshort, .flat_load_dword, .flat_load_dwordx2, .flat_load_dwordx3, .flat_load_dwordx4 };
    for (loads) |opcode| {
        try std.testing.expect(readsOnlyResources(&.{.{ .family = .flat, .opcode = opcode }}));
    }
    for ([_]rdna2.Opcode{ .flat_store_byte, .flat_store_short, .flat_store_dword, .flat_store_dwordx2, .flat_store_dwordx3, .flat_store_dwordx4, .unsupported, .unknown }) |opcode| {
        try std.testing.expect(!readsOnlyResources(&.{.{ .family = .flat, .opcode = opcode }}));
    }
    try std.testing.expect(!readsOnlyResources(&.{ .{ .family = .mubuf, .opcode = .buffer_store_dword }, .{ .family = .flat, .opcode = .flat_load_dword } }));
}

fn collect(allocator: std.mem.Allocator, instructions: []const rdna2.Instruction, kind: Kind) ![]const u32 {
    var count: usize = 0;
    for (instructions) |*inst| if (needsCheckpoint(inst.opcode, kind)) {
        count += 1;
    };
    const result = try allocator.alloc(u32, count);
    var index: usize = 0;
    for (instructions) |*inst| {
        if (!needsCheckpoint(inst.opcode, kind)) continue;
        result[index] = inst.pc;
        index += 1;
    }
    return result;
}

/// Whether the storage-image pass looks at this instruction. It reads images
/// through a T# in an SGPR and writes them, or reads one it may have to bind
/// as storage because no sampled binding claimed it.
pub fn isStorageImage(inst: rdna2.Instruction) bool {
    return switch (inst.opcode) {
        .image_load,
        .image_store,
        .image_store_mip,
        .image_atomic_add,
        .image_atomic_umin,
        .image_atomic_umax,
        .image_atomic_and,
        .image_atomic_or,
        .image_atomic_xor,
        .image_atomic_fmax,
        => true,
        else => false,
    };
}

fn pcListed(pcs: []const u32, pc: u32) bool {
    var low: usize = 0;
    var high = pcs.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (pcs[middle] < pc) low = middle + 1 else if (pcs[middle] > pc) high = middle else return true;
    }
    return false;
}

fn collectScalarSteps(
    allocator: std.mem.Allocator,
    instructions: []const rdna2.Instruction,
    resource: []const u32,
    sampled: []const u32,
) ![]const u32 {
    var count: usize = 0;
    for (instructions) |inst| {
        if (scalar.scalarWalkVisits(inst) or pcListed(resource, inst.pc) or pcListed(sampled, inst.pc)) count += 1;
    }
    const result = try allocator.alloc(u32, count);
    var index: usize = 0;
    for (instructions, 0..) |inst, position| {
        if (!scalar.scalarWalkVisits(inst) and !pcListed(resource, inst.pc) and !pcListed(sampled, inst.pc)) continue;
        result[index] = @intCast(position);
        index += 1;
    }
    return result;
}

fn collectStorageImages(allocator: std.mem.Allocator, instructions: []const rdna2.Instruction) ![]const u32 {
    var count: usize = 0;
    for (instructions) |inst| count += @intFromBool(isStorageImage(inst));
    const result = try allocator.alloc(u32, count);
    var index: usize = 0;
    for (instructions, 0..) |inst, position| {
        if (!isStorageImage(inst)) continue;
        result[index] = @intCast(position);
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
    evaluation: ?*scalar.Evaluation = null,

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
        /// Instructions the scalar evaluator stepped through for this
        /// preparation. The list of checkpoints is cached; this walk is not,
        /// and it is what the preparation time is made of.
        instructions_walked: u32 = 0,

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
        var lease = try self.acquire(allocator, instructions, plan, kind);
        errdefer lease.release();
        if (lease.pcs.len != 0) {
            // The evaluator overwrites visited snapshots and clears skipped
            // blocks before returning, including early stops and failed reads.
            const steps = if (lease.plan_reused) plan.?.scalar_steps else null;
            const evaluation = self.evaluation orelse try allocator.create(scalar.Evaluation);
            self.evaluation = null;
            defer {
                if (self.evaluation) |nested| allocator.destroy(nested);
                self.evaluation = evaluation;
            }
            scalar.evaluateDecodedResourceSnapshotsInto(evaluation, reader, bindings, instructions, lease.pcs, lease.snapshots, steps);
            lease.instructions_walked = evaluation.instruction_count;
        }
        return lease;
    }

    /// Borrow storage without evaluating it, so one owner walk can populate
    /// several consumers. The caller must initialize every snapshot.
    pub fn acquire(
        self: *Pool,
        allocator: std.mem.Allocator,
        instructions: []const rdna2.Instruction,
        plan: ?*const Plan,
        kind: Kind,
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
        errdefer allocator.free(storage);
        const snapshots = storage[0..pcs.len];
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
        if (self.evaluation) |evaluation| allocator.destroy(evaluation);
        self.evaluation = null;
        for (&self.entries) |*entry| {
            allocator.free(entry.*);
            entry.* = &.{};
        }
    }
};

pub fn needsCheckpoint(opcode: rdna2.Opcode, kind: Kind) bool {
    return switch (kind) {
        .resource => needsResource(opcode),
        .sampled => opcode == .image_load or opcode == .image_load_mip or
            opcode == .image_sample or opcode == .image_gather4 or opcode == .image_get_lod,
    };
}

fn needsResource(opcode: rdna2.Opcode) bool {
    return switch (opcode) {
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
        // The typed MTBUF forms name their V# in the same operand as the
        // untyped ones and only carry the format in the instruction. The
        // buffer pass walks them, so a checkpoint has to exist at their PC.
        .tbuffer_load_format_x,
        .tbuffer_load_format_xy,
        .tbuffer_load_format_xyz,
        .tbuffer_load_format_xyzw,
        .s_buffer_load_dword,
        .s_buffer_load_dwordx2,
        .s_buffer_load_dwordx4,
        .s_buffer_load_dwordx8,
        .s_buffer_load_dwordx16,
        .buffer_store_byte,
        .buffer_store_short,
        .buffer_store_byte_d16_hi,
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
        .tbuffer_store_format_x,
        .tbuffer_store_format_xy,
        .tbuffer_store_format_xyz,
        .tbuffer_store_format_xyzw,
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
        .buffer_atomic_fmin,
        .buffer_atomic_fmax,
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

test "resource iterators preserve program order and reject a replaced allocation" {
    const a = std.testing.allocator;
    const original = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_load_dwordx4 },
        .{ .pc = 8, .opcode = .v_add_f32 },
        .{ .pc = 12, .opcode = .image_get_lod },
        .{ .pc = 20, .opcode = .buffer_store_dword },
        .{ .pc = 28, .opcode = .image_sample },
        .{ .pc = 36, .opcode = .s_endpgm },
    };
    var plan = try Plan.init(a, &original);
    defer plan.deinit(a);
    try std.testing.expect(!plan.reads_only_resources);
    const replacement = try a.dupe(rdna2.Instruction, &original);
    defer a.free(replacement);
    replacement[3].opcode = .s_nop;
    replacement[4].opcode = .v_mov_b32;
    try std.testing.expect(readsOnlyResources(replacement));
    for ([_]Kind{ .resource, .sampled }) |kind| {
        for ([_][]const rdna2.Instruction{ &original, replacement }) |instructions| {
            var cached = Iterator.init(instructions, &plan, kind);
            var full = Iterator.init(instructions, null, kind);
            try std.testing.expectEqual(instructions.ptr == original[0..].ptr, cached.indices != null);
            while (full.next()) |index| {
                try std.testing.expectEqual(@as(?usize, index), cached.next());
            }
            try std.testing.expectEqual(@as(?usize, null), cached.next());
            try std.testing.expectEqual(@as(?usize, null), cached.next());
        }
    }
}

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
    bindings.resource_instruction_budget = 16 * 1024;
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
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.resource_instruction_budget = 16 * 1024;
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
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.resource_instruction_budget = 16 * 1024;
    var cached = try pool.prepare(allocator, &instructions, &plan, .resource, memory.reader(), &bindings);
    defer cached.release();
    var fallback = try pool.prepare(allocator, &instructions, null, .sampled, memory.reader(), &bindings);
    defer fallback.release();
}

test "checkpoint plan and scratch allocation failures release partial ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAllocationFailures, .{});
}

test "the storage-image list names exactly what a full walk would visit" {
    const allocator = std.testing.allocator;
    const opcodes = [_]rdna2.Opcode{
        .s_load_dwordx4,    .image_load,      .v_mov_b32,         .image_store,
        .image_sample,      .image_store_mip, .s_nop,             .image_atomic_add,
        .buffer_load_dword, .image_gather4,   .image_atomic_fmax, .s_endpgm,
    };
    var instructions: [opcodes.len]rdna2.Instruction = undefined;
    for (opcodes, 0..) |opcode, index| {
        instructions[index] = .{ .opcode = opcode, .pc = @intCast(index * 4) };
    }
    var plan = try Plan.init(allocator, &instructions);
    defer plan.deinit(allocator);

    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(allocator);
    for (instructions, 0..) |inst, index| {
        if (isStorageImage(inst)) try expected.append(allocator, @intCast(index));
    }
    const listed = plan.storageImageIndices(&instructions).?;
    try std.testing.expectEqualSlices(u32, expected.items, listed);
    // Program order is what the pass depends on: slots are handed out as the
    // instructions are met.
    for (listed[1..], listed[0 .. listed.len - 1]) |after, before| {
        try std.testing.expect(before < after);
    }
    // A sampled-only fetch is not a storage image, and neither is a buffer
    // load that the resource list does claim.
    try std.testing.expect(!isStorageImage(instructions[4]));
    try std.testing.expect(!isStorageImage(instructions[8]));
    try std.testing.expect(std.mem.indexOfScalar(u32, listed, 4) == null);

    // Another instruction allocation with the same contents is a different
    // program as far as the plan is concerned, so it refuses to answer.
    var copy = instructions;
    try std.testing.expectEqual(@as(?[]const u32, null), plan.storageImageIndices(&copy));
}

test "typed buffer accesses get a resource checkpoint like their untyped forms" {
    // The buffer pass in the Vulkan backend walks MTBUF alongside MUBUF and
    // then reads the scalar state recorded at the instruction's PC. A typed
    // access missing from this list leaves that read without a checkpoint.
    const typed = [_]rdna2.Opcode{
        .tbuffer_load_format_x,    .tbuffer_load_format_xy,
        .tbuffer_load_format_xyz,  .tbuffer_load_format_xyzw,
        .tbuffer_store_format_x,   .tbuffer_store_format_xy,
        .tbuffer_store_format_xyz, .tbuffer_store_format_xyzw,
    };
    for (typed) |opcode| {
        try std.testing.expect(needsCheckpoint(opcode, .resource));
    }
}

test "scalar steps skip vector instructions and a repeated walk reuses the load addresses" {
    const allocator = std.testing.allocator;
    const instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .family = .sop1, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .integer_inline_constant, .value = 9 }, .src_count = 1, .word_count = 1 },
        .{ .pc = 4, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 0 }, .src0 = .{ .kind = .integer_inline_constant, .value = 1 }, .src_count = 1, .word_count = 1 },
        .{ .pc = 8, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 1 }, .src0 = .{ .kind = .integer_inline_constant, .value = 2 }, .src_count = 1, .word_count = 1 },
        .{ .pc = 12, .family = .mubuf, .opcode = .buffer_load_dword, .dst = .{ .kind = .vgpr, .reg = 2 }, .src1 = .{ .kind = .sgpr, .reg = 0 }, .src_count = 2, .word_count = 2 },
        .{ .pc = 20, .family = .sopp, .opcode = .s_endpgm, .word_count = 1 },
    };
    var plan = try Plan.init(allocator, &instructions);
    defer plan.deinit(allocator);
    // The two v_movs are not steps. The scalar move, the buffer checkpoint
    // and the program end are.
    try std.testing.expectEqual(@as(usize, 3), plan.scalar_steps.len);
    try std.testing.expect(std.mem.indexOfScalar(u32, plan.scalar_steps, 1) == null);
    try std.testing.expect(std.mem.indexOfScalar(u32, plan.scalar_steps, 2) == null);

    var pool = Pool{};
    defer pool.deinit(allocator);
    var memory = TestMemory{};
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.resource_instruction_budget = 16 * 1024;
    var first = try pool.prepare(allocator, &instructions, &plan, .resource, memory.reader(), &bindings);
    defer first.release();
    try std.testing.expect(first.instructions_walked < instructions.len);
    try std.testing.expect(first.instructions_walked != 0);
    try std.testing.expect(first.snapshots[0][4].known);
    try std.testing.expectEqual(@as(u32, 9), first.snapshots[0][4].value);
    var second = try pool.prepare(allocator, &instructions, &plan, .resource, memory.reader(), &bindings);
    defer second.release();
    try std.testing.expectEqual(first.instructions_walked, second.instructions_walked);
    try std.testing.expectEqual(@as(u32, 9), second.snapshots[0][4].value);
}

test "indexed scalar history retains dependencies of vector memory operations" {
    const a = std.testing.allocator;
    var instructions = [_]rdna2.Instruction{
        .{ .pc = 0, .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr }, .word_count = 1 },
        .{ .pc = 4, .family = .flat, .opcode = .flat_load_dword, .dst = .{ .kind = .vgpr, .reg = 1 }, .word_count = 1 },
        .{ .pc = 8, .family = .sopp, .opcode = .s_endpgm, .word_count = 1 },
    };
    var memory = TestMemory{};
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.resource_instruction_budget = instructions.len;
    for ([_]rdna2.Instruction{
        instructions[1],
        .{ .family = .ds, .opcode = .ds_read_b32, .dst = .{ .kind = .vgpr, .reg = 1 } },
        .{ .family = .vopc, .opcode = .v_cmp_eq_f32 },
        .{ .family = .vop2, .opcode = .unsupported },
    }) |operation| {
        instructions[1] = operation;
        instructions[1].pc = 4;
        instructions[1].word_count = 1;
        var plan = try Plan.init(a, &instructions);
        defer plan.deinit(a);
        var dense: scalar.Evaluation = undefined;
        var indexed: scalar.Evaluation = undefined;
        scalar.evaluateDecodedResourceStateAtTwoCheckpointsInto(&dense, memory.reader(), &bindings, &instructions, &.{}, &.{}, &.{}, &.{}, null);
        scalar.evaluateDecodedResourceStateAtTwoCheckpointsInto(&indexed, memory.reader(), &bindings, &instructions, &.{}, &.{}, &.{}, &.{}, plan.scalar_steps);
        try std.testing.expectEqualDeep(dense.registers, indexed.registers);
        try std.testing.expectEqual(std.math.maxInt(u64), indexed.address_user_data_mask);
        try std.testing.expectEqual(dense.address_user_data_mask, indexed.address_user_data_mask);
        try std.testing.expect(indexed.instruction_count < dense.instruction_count);
    }
}

/// The call-presence bit belongs to one immutable decoded allocation. Linked
/// fetch programs and manually constructed plans retain the complete scan.
pub fn hasStaticCalls(instructions: []const rdna2.Instruction, plan: ?*const Plan) bool {
    if (@atomicLoad(bool, &scalar.cached_scalar_call_analysis, .monotonic)) {
        if (plan) |retained| if (retained.matches(instructions)) {
            if (retained.static_calls) |present| return present;
        };
    }
    return rdna2.scalar_calls.present(instructions);
}

test "call presence follows the immutable program and manual plans fall back" {
    const a = std.testing.allocator;
    const saved = scalar.cached_scalar_call_analysis;
    defer scalar.cached_scalar_call_analysis = saved;
    const leaf = [_]rdna2.Instruction{.{ .pc = 0, .word_count = 1, .opcode = .s_endpgm }};
    const call = [_]rdna2.Instruction{.{ .pc = 0, .word_count = 1, .opcode = .s_call_b64 }};
    var leaf_plan = try Plan.init(a, &leaf);
    defer leaf_plan.deinit(a);
    var call_plan = try Plan.init(a, &call);
    defer call_plan.deinit(a);
    for ([_]bool{ false, true }) |enabled| {
        scalar.cached_scalar_call_analysis = enabled;
        call_plan.static_calls = true;
        try std.testing.expect(!hasStaticCalls(&leaf, &leaf_plan));
        try std.testing.expect(hasStaticCalls(&call, &call_plan));
        try std.testing.expect(hasStaticCalls(&call, &leaf_plan));
        try std.testing.expect(!hasStaticCalls(&leaf, &call_plan));
        try std.testing.expect(hasStaticCalls(&call, null));
        try std.testing.expect(!hasStaticCalls(&leaf, null));
        call_plan.static_calls = null;
        try std.testing.expect(hasStaticCalls(&call, &call_plan));
    }
}
