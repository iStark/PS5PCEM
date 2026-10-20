// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Draw-local CPU resource preparation. Only the owner reads guest memory;
//! workers interpret immutable instructions and captured bytes. Missing or
//! changed inputs discard the speculative result and retain the serial path.
const std = @import("std");
const builtin = @import("builtin");
const rdna2 = @import("rdna2");
const scalar = @import("scalar_provenance.zig");
const checkpoints = @import("resource_checkpoints.zig");
const shaders = @import("shaders.zig");
const cpu = @import("cpu_workers.zig");

pub export var share_bounded_scalar_loops: bool = true;
pub export var exact_scalar_walk_budget: bool = true;
pub export var indexed_resource_snapshot_capture: bool = true;
pub export var collapse_contained_scalar_reads: bool = true;
pub export var resource_walk_cache_entries: u32 = 64;
pub export var resource_walk_cache_bytes: u64 = 32 * 1024 * 1024;
pub export var recycle_resource_walk_entries: bool = true;
pub export var content_aware_walk_admission: bool = true;
pub export var parameterized_resource_walks: bool = true;
pub export var hinted_resource_walks: bool = true;

fn passthroughWords(plan: *const checkpoints.Plan, bindings: *const shaders.StageBindings) u64 {
    if (!bindings.defer_vector_buffer_loads or !bindings.conservative_user_data_mask or bindings.compute_dispatch != null or
        !@atomicLoad(bool, &parameterized_resource_walks, .monotonic)) return 0;
    var mask: u64 = 0;
    for (0..@min(bindings.user_data_count, 64)) |word| {
        const reg = @as(usize, bindings.scalar_user_data_base) + word;
        if (reg < 128 and plan.passthrough_registers & (@as(u128, 1) << @intCast(reg)) != 0)
            mask |= @as(u64, 1) << @intCast(word);
    }
    return mask;
}

fn sameBindings(a: *const shaders.StageBindings, b: *const shaders.StageBindings, passthrough: u64) bool {
    if (passthrough == 0) return std.meta.eql(a.*, b.*);
    // Streaming draws usually differ in their first descriptor pointer.
    // Reject that before comparing optional metadata and dispatch layouts.
    for (a.user_data, b.user_data, 0..) |old, new, word| {
        if ((word >= 64 or passthrough & (@as(u64, 1) << @intCast(word)) == 0) and old != new) return false;
    }
    inline for (@typeInfo(shaders.StageBindings).@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "user_data"))
            if (!std.meta.eql(@field(a, field.name), @field(b, field.name))) return false;
    }
    return true;
}

fn hashBindings(hasher: *std.hash.Wyhash, bindings: *const shaders.StageBindings) void {
    inline for (@typeInfo(shaders.StageBindings).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "user_data"))
            hasher.update(std.mem.sliceAsBytes(&bindings.user_data))
        else
            std.hash.autoHash(hasher, @field(bindings, field.name));
    }
}

fn rebindRegisters(registers: *scalar.ScalarRegisters, bindings: *const shaders.StageBindings, mask: u64) void {
    var remaining = mask;
    while (remaining != 0) {
        const word = @ctz(remaining);
        remaining &= remaining - 1;
        const reg = @as(usize, bindings.scalar_user_data_base) + word;
        // Unvisited checkpoints remain unknown. The proof excludes every
        // write and host consumer of these unchanged entry registers.
        if (registers[reg].known) registers[reg].value = bindings.user_data[word];
    }
}

fn rebindCheckpoints(values: []scalar.ScalarRegisters, bindings: *const shaders.StageBindings, mask: u64) void {
    if (mask == 0) return;
    for (values) |*registers| rebindRegisters(registers, bindings, mask);
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn timestamp() u64 {
    return @intCast(@max(0, std.Io.Clock.awake.now(io()).nanoseconds));
}

const Snapshot = struct {
    const Read = struct { address: u64, size: u8, bytes: [64]u8 };
    reads: [scalar.maximum_loads]Read = undefined,
    order: [scalar.maximum_loads]u16 = undefined,
    count: usize = 0,
    indexed_count: usize = 0,
    complete: bool = true,
    missing: bool = false,
    source: shaders.MemoryReader = undefined,

    fn copyFrom(self: *Snapshot, other: *const Snapshot) void {
        self.count = other.count;
        self.complete = other.complete;
        self.missing = false;
        self.source = undefined;
        self.indexed_count = 0;
        @memcpy(self.reads[0..self.count], other.reads[0..other.count]);
        // Shared owner walks never replay through the sorted index.
    }

    fn capture(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self: *Snapshot = @ptrCast(@alignCast(context.?));
        self.source.read(address, bytes) catch {
            self.complete = false;
            return false;
        };
        if (bytes.len > 64 or address > std.math.maxInt(u64) - bytes.len) {
            self.complete = false;
            return true;
        }
        const indexed = @atomicLoad(bool, &indexed_resource_snapshot_capture, .monotonic) and bytes.len != 0;
        var insertion: usize = 0;
        if (indexed) {
            if (self.indexed_count != self.count) self.sort();
            // Reads are at most 64 bytes. Only nearby starts can overlap;
            // unrelated descriptor tables need no pairwise comparison.
            var position = self.lowerBound(address -| 63);
            while (position < self.count) : (position += 1) {
                const read = &self.reads[self.order[position]];
                if (read.address >= address + bytes.len) break;
                if (self.compareRead(read, address, bytes)) return true;
            }
            insertion = self.lowerBound(address);
        } else {
            for (self.reads[0..self.count]) |*read| {
                if (self.compareRead(read, address, bytes)) return true;
            }
        }
        if (self.count == self.reads.len) {
            self.complete = false;
            return true;
        }
        const read = &self.reads[self.count];
        read.address = address;
        read.size = @intCast(bytes.len);
        @memcpy(read.bytes[0..bytes.len], bytes);
        if (indexed) {
            std.mem.copyBackwards(u16, self.order[insertion + 1 .. self.count + 1], self.order[insertion..self.count]);
            self.order[insertion] = @intCast(self.count);
            self.indexed_count = self.count + 1;
        } else self.indexed_count = 0;
        self.count += 1;
        return true;
    }

    fn compareRead(self: *Snapshot, read: *const Read, address: u64, bytes: []const u8) bool {
        if (read.address == address and read.size == bytes.len) {
            if (!std.mem.eql(u8, read.bytes[0..read.size], bytes)) self.complete = false;
            return true;
        }
        if (@atomicLoad(bool, &collapse_contained_scalar_reads, .monotonic) and bytes.len != 0 and
            address >= read.address and address - read.address <= read.size)
        {
            const offset: usize = @intCast(address - read.address);
            if (bytes.len <= read.size - offset) {
                // The covering read already validates every byte of this
                // dependency. A changed subrange still invalidates the walk.
                if (!std.mem.eql(u8, bytes, read.bytes[offset..][0..bytes.len])) self.complete = false;
                return true;
            }
        }
        const first = @max(address, read.address);
        const end = @min(address + bytes.len, read.address + read.size);
        if (first < end and !std.mem.eql(u8, bytes[@intCast(first - address)..@intCast(end - address)], read.bytes[@intCast(first - read.address)..@intCast(end - read.address)]))
            self.complete = false;
        return false;
    }

    fn lowerBound(self: *const Snapshot, address: u64) usize {
        var low: usize = 0;
        var high = self.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.reads[self.order[middle]].address < address) low = middle + 1 else high = middle;
        }
        return low;
    }

    fn sort(self: *Snapshot) void {
        for (self.order[0..self.count], 0..) |*index, position| index.* = @intCast(position);
        std.mem.sort(u16, self.order[0..self.count], self, struct {
            fn less(snapshot: *Snapshot, a: u16, b: u16) bool {
                return snapshot.reads[a].address < snapshot.reads[b].address;
            }
        }.less);
        self.indexed_count = self.count;
    }

    fn replay(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self: *Snapshot = @ptrCast(@alignCast(context.?));
        const found = self.lookup(address, bytes);
        if (!found) self.missing = true;
        return found;
    }

    fn lookup(self: *const Snapshot, address: u64, bytes: []u8) bool {
        var low: usize = 0;
        var high = self.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.reads[self.order[middle]].address < address) low = middle + 1 else high = middle;
        }
        // A scalar load can request a subrange of a captured wider load.
        var candidate = low;
        while (candidate < self.count and self.reads[self.order[candidate]].address == address) : (candidate += 1) {
            const read = &self.reads[self.order[candidate]];
            if (bytes.len <= read.size) {
                @memcpy(bytes, read.bytes[0..bytes.len]);
                return true;
            }
        }
        // Captured loads are at most 64 bytes. Stop once earlier ranges cannot
        // contain the request, including nested/overlapping descriptor loads.
        candidate = low;
        while (candidate != 0) {
            candidate -= 1;
            const read = &self.reads[self.order[candidate]];
            const offset = address - read.address;
            if (offset > 64) break;
            if (offset <= read.size and bytes.len <= read.size - offset) {
                @memcpy(bytes, read.bytes[@intCast(offset)..][0..bytes.len]);
                return true;
            }
        }
        return false;
    }

    fn matches(self: *const Snapshot, reader: shaders.MemoryReader) bool {
        if (!self.complete) return false;
        var bytes: [64]u8 = undefined;
        for (self.reads[0..self.count]) |*read| {
            reader.read(read.address, bytes[0..read.size]) catch return false;
            if (!std.mem.eql(u8, bytes[0..read.size], read.bytes[0..read.size])) return false;
        }
        return true;
    }
};

pub const Stats = struct {
    submitted: u64 = 0,
    shared_walks: u64 = 0,
    used: u64 = 0,
    fallback: u64 = 0,
    worker_ns: u64 = 0,
    wait_ns: u64 = 0,
    cached_walks: u64 = 0,
    cache_misses: u64 = 0,
    shared_loop_walks: u64 = 0,
    shared_loop_fallbacks: u64 = 0,
};

/// Reuse the pure scalar interpretation only after re-reading every dependency.
/// This does not retain Vulkan resources or assume that a guest pointer names
/// unchanged memory. Results are copied into independent operation-local leases.
const WalkCache = struct {
    const maximum_entries = 512;
    const maximum_bytes = 128 * 1024 * 1024;
    const Entry = struct {
        plan_identity: u64,
        bindings: shaders.StageBindings,
        snapshot: Snapshot,
        evaluation: scalar.Evaluation,
        /// Owning allocation; the two views below expose only initialized
        /// checkpoints. Replacement may change either view without reallocating.
        checkpoint_storage: []scalar.ScalarRegisters,
        sampled: []scalar.ScalarRegisters,
        resource: []scalar.ScalarRegisters,
        has_sampled: bool,
        exact_loop_budget: bool,
        age: u64,

        fn bytes(self: *const Entry) usize {
            return @sizeOf(Entry) + self.checkpoint_storage.len * @sizeOf(scalar.ScalarRegisters);
        }

        fn destroy(self: *Entry) void {
            const a = std.heap.page_allocator;
            a.free(self.checkpoint_storage);
            a.destroy(self);
        }

        fn fits(self: *const Entry, sampled_count: usize, resource_count: usize) bool {
            return if (@atomicLoad(bool, &recycle_resource_walk_entries, .monotonic))
                sampled_count + resource_count <= self.checkpoint_storage.len
            else
                sampled_count == self.sampled.len and resource_count == self.resource.len;
        }

        fn replace(self: *Entry, plan: *const checkpoints.Plan, bindings: *const shaders.StageBindings, snapshot: *const Snapshot, evaluation: *const scalar.Evaluation, sampled: ?[]const scalar.ScalarRegisters, resource: []const scalar.ScalarRegisters, age: u64) void {
            const sampled_values = sampled orelse &.{};
            self.sampled = self.checkpoint_storage[0..sampled_values.len];
            self.resource = self.checkpoint_storage[sampled_values.len..][0..resource.len];
            self.plan_identity = plan.identity;
            self.bindings = bindings.*;
            self.snapshot.copyFrom(snapshot);
            self.evaluation.copyFrom(evaluation);
            @memcpy(self.sampled, sampled_values);
            @memcpy(self.resource, resource);
            self.has_sampled = sampled != null;
            self.exact_loop_budget = @atomicLoad(bool, &exact_scalar_walk_budget, .monotonic);
            self.age = age;
        }
    };
    entries: [maximum_entries]?*Entry = @splat(null),
    bytes: usize = 0,
    sequence: u64 = 0,
    enabled: bool = true,
    entry_limit: usize = 64,
    byte_limit: usize = 32 * 1024 * 1024,
    /// Admit only complete inputs seen twice, including captured bytes.
    /// Recycled addresses alone do not make streaming constants reusable.
    admission: [512]u64 = @splat(0),
    /// Indices are hints only. Replaced entries, changed bindings and changed
    /// captured memory still pass the complete lookup checks below.
    hints: [64]?u16 = @splat(null),

    fn updateLimits(self: *WalkCache) void {
        const entries = std.math.clamp(@atomicLoad(u32, &resource_walk_cache_entries, .monotonic), 1, maximum_entries);
        const bytes = std.math.clamp(@atomicLoad(u64, &resource_walk_cache_bytes, .monotonic), @sizeOf(Entry), maximum_bytes);
        if (entries == self.entry_limit and bytes == self.byte_limit) return;
        self.entry_limit = entries;
        self.byte_limit = @intCast(bytes);
        for (entries..self.entries.len) |i| self.remove(i);
        while (self.bytes > self.byte_limit) {
            const victim = self.oldest() orelse break;
            self.remove(victim);
        }
    }

    fn oldest(self: *const WalkCache) ?usize {
        var result: ?usize = null;
        for (self.entries[0..self.entry_limit], 0..) |maybe, i| if (maybe) |entry| {
            if (result == null or entry.age < self.entries[result.?].?.age) result = i;
        };
        return result;
    }

    fn lookup(self: *WalkCache, plan: *const checkpoints.Plan, bindings: *const shaders.StageBindings, reader: shaders.MemoryReader, needs_sampled: bool) ?*const Entry {
        if (!self.enabled or plan.identity == 0) return null;
        self.updateLimits();
        const passthrough = passthroughWords(plan, bindings);
        const hint = &self.hints[plan.identity % self.hints.len];
        var selected: ?usize = null;
        if (@atomicLoad(bool, &hinted_resource_walks, .monotonic)) {
            if (hint.*) |index| if (index < self.entry_limit) {
                if (self.entries[index]) |entry| if (matchesKey(entry, plan, bindings, passthrough, needs_sampled)) {
                    selected = index;
                };
            };
        }
        if (selected == null) for (self.entries[0..self.entry_limit], 0..) |maybe, index| {
            const entry = maybe orelse continue;
            if (!matchesKey(entry, plan, bindings, passthrough, needs_sampled)) continue;
            selected = index;
            break;
        };
        const index = selected orelse return null;
        const entry = self.entries[index].?;
        if (!entry.snapshot.matches(reader)) return null;
        hint.* = @intCast(index);
        self.sequence +%= 1;
        entry.age = self.sequence;
        return entry;
    }

    fn matchesKey(entry: *const Entry, plan: *const checkpoints.Plan, bindings: *const shaders.StageBindings, passthrough: u64, needs_sampled: bool) bool {
        return entry.plan_identity == plan.identity and (!needs_sampled or entry.has_sampled) and
            (plan.forward_only or entry.exact_loop_budget == @atomicLoad(bool, &exact_scalar_walk_budget, .monotonic)) and
            sameBindings(&entry.bindings, bindings, passthrough);
    }

    fn remember(self: *WalkCache, plan: *const checkpoints.Plan, bindings: *const shaders.StageBindings, snapshot: *const Snapshot, evaluation: *const scalar.Evaluation, sampled: ?[]const scalar.ScalarRegisters, resource: []const scalar.ScalarRegisters) void {
        if (!self.enabled or plan.identity == 0 or !snapshot.complete or evaluation.memory_read_failed) return;
        self.updateLimits();
        const sampled_values = sampled orelse &.{};
        const size = @sizeOf(Entry) + (sampled_values.len + resource.len) * @sizeOf(scalar.ScalarRegisters);
        if (size > self.byte_limit / 4) return;
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, plan.identity);
        const passthrough = passthroughWords(plan, bindings);
        var normalized = bindings.*;
        var remaining = passthrough;
        while (remaining != 0) {
            const word = @ctz(remaining);
            remaining &= remaining - 1;
            normalized.user_data[word] = 0;
        }
        hashBindings(&hasher, &normalized);
        if (@atomicLoad(bool, &content_aware_walk_admission, .monotonic)) {
            for (snapshot.reads[0..snapshot.count]) |*read| {
                std.hash.autoHash(&hasher, read.address);
                std.hash.autoHash(&hasher, read.size);
                hasher.update(read.bytes[0..read.size]);
            }
        }
        const key = hasher.final() | 1;
        const admission = &self.admission[key % self.admission.len];
        if (admission.* != key) {
            admission.* = key;
            return;
        }
        var slot: ?usize = null;
        for (self.entries[0..self.entry_limit], 0..) |maybe, i| {
            if (maybe) |entry| {
                if (entry.plan_identity == plan.identity and sameBindings(&entry.bindings, bindings, passthrough)) {
                    if (entry.fits(sampled_values.len, resource.len)) {
                        self.sequence +%= 1;
                        entry.replace(plan, bindings, snapshot, evaluation, sampled, resource, self.sequence);
                        return;
                    }
                    self.remove(i);
                    slot = i;
                    break;
                }
            } else slot = i;
        }
        while (slot == null or self.bytes + size > self.byte_limit) {
            const victim = self.oldest() orelse return;
            const previous = self.entries[victim].?;
            // A smaller walk can reuse the allocation too, including a
            // different sampled/resource split. Budget accounting retains the
            // full capacity; lookups see only the newly initialized views.
            if (@atomicLoad(bool, &recycle_resource_walk_entries, .monotonic) and
                previous.fits(sampled_values.len, resource.len))
            {
                self.sequence +%= 1;
                previous.replace(plan, bindings, snapshot, evaluation, sampled, resource, self.sequence);
                return;
            }
            self.remove(victim);
            slot = victim;
        }
        const a = std.heap.page_allocator;
        const entry = a.create(Entry) catch return;
        const storage = a.alloc(scalar.ScalarRegisters, sampled_values.len + resource.len) catch {
            a.destroy(entry);
            return;
        };
        self.sequence +%= 1;
        entry.* = .{ .plan_identity = 0, .bindings = undefined, .snapshot = .{}, .evaluation = undefined, .checkpoint_storage = storage, .sampled = undefined, .resource = undefined, .has_sampled = false, .exact_loop_budget = false, .age = 0 };
        entry.replace(plan, bindings, snapshot, evaluation, sampled, resource, self.sequence);
        self.entries[slot.?] = entry;
        self.bytes += size;
    }

    fn remove(self: *WalkCache, index: usize) void {
        const entry = self.entries[index] orelse return;
        self.bytes -= entry.bytes();
        entry.destroy();
        self.entries[index] = null;
    }

    fn deinit(self: *WalkCache) void {
        for (0..self.entries.len) |index| self.remove(index);
    }
};

pub const Pool = struct {
    pub const maximum_workers = cpu.Queue.maximum_workers;
    pub const minimum_scalar_steps = 256;
    worker_limit: usize = 2,
    adaptive: bool = false,
    minimum_steps: usize = minimum_scalar_steps,
    share_scalar_walks: bool = true,
    queue: cpu.Queue = .{},
    configured_limit: ?usize = null,
    configured_adaptive: bool = false,
    stages: [2]Stage = @splat(.{}),
    stats: Stats = .{},
    walk_cache: WalkCache = .{},
    /// Failed bounded-loop proofs are not useful work to repeat per draw.
    /// Opting out can only miss an optimization if later inputs shorten a loop.
    loop_declines: [256]struct { identity: u64 = 0, budget: u32 = 0, exact: bool = false } = @splat(.{}),

    // A stage snapshot is immutable until both jobs complete. Separate jobs
    // allow a long checkpoint walk to overlap the other stage's scalar walk.
    const Stage = struct {
        active: bool = false,
        inline_prepared: bool = false,
        shared_declined: bool = false,
        bindings_address: ?*const shaders.StageBindings = null,
        bindings: shaders.StageBindings = undefined,
        plan: *const checkpoints.Plan = undefined,
        snapshot: Snapshot = .{},
        scalar_job: Work = .{},
        resource_job: Work = .{},
        scalar_result: scalar.Evaluation = undefined,

        fn release(self: *Stage) void {
            if (self.resource_job.resource) |*lease| lease.release();
            self.resource_job.resource = null;
            self.bindings_address = null;
            self.active = false;
            self.inline_prepared = false;
        }
    };

    const Work = struct {
        job: cpu.Job = .{ .run = run },
        stage: *Stage = undefined,
        scalar_job: bool = false,
        started: bool = false,
        joined: bool = false,
        failed: bool = false,
        scratch: checkpoints.Pool = .{},
        resource: ?checkpoints.Pool.Lease = null,

        fn run(job: *cpu.Job) void {
            const self: *Work = @fieldParentPtr("job", job);
            const reader = shaders.MemoryReader{ .context = self, .read_fn = replay };
            const stage = self.stage;
            if (self.scalar_job) {
                scalar.evaluateDecodedResourceStateInto(&stage.scalar_result, reader, &stage.bindings, stage.plan.instructions);
            } else {
                self.resource = self.scratch.prepare(std.heap.page_allocator, stage.plan.instructions, stage.plan, .resource, reader, &stage.bindings) catch {
                    self.failed = true;
                    return;
                };
            }
        }

        fn replay(context: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self: *Work = @ptrCast(@alignCast(context.?));
            const found = self.stage.snapshot.lookup(address, bytes);
            if (!found) self.failed = true;
            return found;
        }
    };

    fn available(self: *Pool, slot: usize, instructions: []const rdna2.Instruction, plan: ?*const checkpoints.Plan) ?*Stage {
        if (builtin.single_threaded or self.worker_limit == 0 or slot >= self.stages.len or plan == null or
            !plan.?.matches(instructions) or plan.?.scalar_steps.len < self.minimum_steps or
            plan.?.resource.len + plan.?.sampled.len == 0) return null;
        const stage = &self.stages[slot];
        if (stage.active) return null;
        if (self.configured_limit != self.worker_limit or self.configured_adaptive != self.adaptive) {
            self.queue.configure(self.worker_limit, self.adaptive);
            self.configured_limit = self.worker_limit;
            self.configured_adaptive = self.adaptive;
        }
        stage.snapshot.count = 0;
        stage.snapshot.indexed_count = 0;
        stage.snapshot.complete = true;
        stage.snapshot.missing = false;
        return stage;
    }

    fn availableShared(self: *Pool, slot: usize, instructions: []const rdna2.Instruction, plan: ?*const checkpoints.Plan, bindings: *const shaders.StageBindings) ?*Stage {
        if (!self.share_scalar_walks or slot >= self.stages.len or plan == null or
            !plan.?.matches(instructions) or
            (!plan.?.forward_only and !@atomicLoad(bool, &share_bounded_scalar_loops, .monotonic)) or
            instructions.len > bindings.resource_instruction_budget or
            plan.?.resource.len + plan.?.sampled.len == 0) return null;
        if (!plan.?.forward_only and plan.?.identity != 0) {
            const declined = self.loop_declines[plan.?.identity % self.loop_declines.len];
            if (declined.identity == plan.?.identity and declined.budget == bindings.resource_instruction_budget and
                declined.exact == @atomicLoad(bool, &exact_scalar_walk_budget, .monotonic)) return null;
        }
        const stage = &self.stages[slot];
        if (stage.active or stage.shared_declined) return null;
        stage.snapshot.count = 0;
        stage.snapshot.indexed_count = 0;
        stage.snapshot.complete = true;
        stage.snapshot.missing = false;
        return stage;
    }

    fn sharedResultFits(self: *Pool, stage: *Stage, plan: *const checkpoints.Plan, bindings: *const shaders.StageBindings, evaluation: *const scalar.Evaluation) bool {
        if (plan.forward_only) return true;
        // The indexed and dense evaluators follow the same scalar/control
        // steps. Count the skipped vector visits on the executed path; the
        // former maximum-gap bound remains a fallback for incomplete/manual
        // proofs. Never lend results beyond the dense interpreter's budget.
        const exact = @atomicLoad(bool, &exact_scalar_walk_budget, .monotonic);
        const conservative_bound = (@as(u64, evaluation.instruction_count) + 1) * plan.maximum_dense_step_ratio;
        const dense_bound = if (exact and plan.identity != 0)
            evaluation.dense_instruction_count orelse conservative_bound
        else
            conservative_bound;
        if (evaluation.stop_reason == .end_program and dense_bound <= bindings.resource_instruction_budget) {
            self.stats.shared_loop_walks += 1;
            return true;
        }
        stage.shared_declined = true;
        if (plan.identity != 0) self.loop_declines[plan.identity % self.loop_declines.len] = .{
            .identity = plan.identity,
            .budget = bindings.resource_instruction_budget,
            .exact = exact,
        };
        self.stats.shared_loop_fallbacks += 1;
        return false;
    }

    fn retainShared(self: *Pool, stage: *Stage, bindings: *const shaders.StageBindings, plan: *const checkpoints.Plan, resource: checkpoints.Pool.Lease) void {
        stage.snapshot.source = undefined;
        stage.bindings_address = bindings;
        stage.plan = plan;
        stage.active = true;
        stage.inline_prepared = true;
        stage.scalar_job.started = false;
        stage.scalar_job.failed = false;
        stage.resource_job.started = false;
        stage.resource_job.failed = false;
        stage.resource_job.resource = resource;
        self.stats.shared_walks += 1;
    }

    /// Capture the original sampled walk at its original ordering point. The
    /// owner immediately consumes its result while independent scalar/storage
    /// jobs use only the captured bytes during subsequent texture staging.
    pub fn startSampled(self: *Pool, slot: usize, reader: shaders.MemoryReader, bindings: *const shaders.StageBindings, instructions: []const rdna2.Instruction, plan: ?*const checkpoints.Plan, scratch: *checkpoints.Pool, allocator: std.mem.Allocator) !?checkpoints.Pool.Lease {
        if (plan == null or plan.?.sampled.len == 0) return null;
        if (self.availableShared(slot, instructions, plan, bindings)) |stage| {
            var sampled = try scratch.acquire(allocator, instructions, plan, .sampled);
            errdefer sampled.release();
            var resource = try stage.resource_job.scratch.acquire(std.heap.page_allocator, instructions, plan, .resource);
            if (self.walk_cache.lookup(plan.?, bindings, reader, true)) |cached| {
                @memcpy(sampled.snapshots, cached.sampled);
                @memcpy(resource.snapshots, cached.resource);
                stage.scalar_result.copyFrom(&cached.evaluation);
                const passthrough = passthroughWords(plan.?, bindings);
                rebindCheckpoints(sampled.snapshots, bindings, passthrough);
                rebindCheckpoints(resource.snapshots, bindings, passthrough);
                rebindRegisters(&stage.scalar_result.registers, bindings, passthrough);
                stage.snapshot.copyFrom(&cached.snapshot);
                self.stats.cached_walks += 1;
                self.retainShared(stage, bindings, plan.?, resource);
                return sampled;
            }
            self.stats.cache_misses += 1;
            stage.snapshot.source = reader;
            // Forward walks fit statically. Completed loops additionally prove
            // their dense visit bound before lending specialization history.
            scalar.evaluateDecodedResourceStateAtTwoCheckpointsInto(&stage.scalar_result, .{ .context = &stage.snapshot, .read_fn = Snapshot.capture }, bindings, instructions, sampled.pcs, sampled.snapshots, resource.pcs, resource.snapshots, plan.?.walk());
            sampled.instructions_walked = stage.scalar_result.instruction_count;
            if (stage.snapshot.complete and self.sharedResultFits(stage, plan.?, bindings, &stage.scalar_result)) {
                self.walk_cache.remember(plan.?, bindings, &stage.snapshot, &stage.scalar_result, sampled.snapshots, resource.snapshots);
                self.retainShared(stage, bindings, plan.?, resource);
            } else {
                resource.release();
            }
            return sampled;
        }
        const stage = self.available(slot, instructions, plan) orelse return null;
        stage.snapshot.source = reader;
        const lease = try scratch.prepare(allocator, instructions, plan, .sampled, .{ .context = &stage.snapshot, .read_fn = Snapshot.capture }, bindings);
        self.launch(stage, bindings, plan.?, true);
        return lease;
    }

    pub fn startScalar(self: *Pool, slot: usize, reader: shaders.MemoryReader, bindings: *const shaders.StageBindings, instructions: []const rdna2.Instruction, plan: ?*const checkpoints.Plan, scalar_result: *scalar.Evaluation) bool {
        if (self.availableShared(slot, instructions, plan, bindings)) |stage| {
            var resource = stage.resource_job.scratch.acquire(std.heap.page_allocator, instructions, plan, .resource) catch return false;
            if (self.walk_cache.lookup(plan.?, bindings, reader, false)) |cached| {
                @memcpy(resource.snapshots, cached.resource);
                scalar_result.copyFrom(&cached.evaluation);
                const passthrough = passthroughWords(plan.?, bindings);
                rebindCheckpoints(resource.snapshots, bindings, passthrough);
                rebindRegisters(&scalar_result.registers, bindings, passthrough);
                stage.scalar_result.copyFrom(scalar_result);
                stage.snapshot.copyFrom(&cached.snapshot);
                self.stats.cached_walks += 1;
                self.retainShared(stage, bindings, plan.?, resource);
                return true;
            }
            self.stats.cache_misses += 1;
            stage.snapshot.source = reader;
            scalar.evaluateDecodedResourceStateAtCheckpointsInto(scalar_result, .{ .context = &stage.snapshot, .read_fn = Snapshot.capture }, bindings, instructions, resource.pcs, resource.snapshots, plan.?.walk());
            if (!self.sharedResultFits(stage, plan.?, bindings, scalar_result)) {
                resource.release();
                return false;
            }
            if (stage.snapshot.complete) {
                stage.scalar_result.copyFrom(scalar_result);
                self.walk_cache.remember(plan.?, bindings, &stage.snapshot, scalar_result, null, resource.snapshots);
                self.retainShared(stage, bindings, plan.?, resource);
            } else {
                resource.release();
            }
            return true;
        }
        const stage = self.available(slot, instructions, plan) orelse return false;
        stage.snapshot.source = reader;
        scalar.evaluateDecodedResourceStateInto(scalar_result, .{ .context = &stage.snapshot, .read_fn = Snapshot.capture }, bindings, instructions);
        self.launch(stage, bindings, plan.?, false);
        // An incomplete capture still leaves the original owner walk valid.
        return true;
    }

    fn launch(self: *Pool, stage: *Stage, bindings: *const shaders.StageBindings, plan: *const checkpoints.Plan, prepare_scalar: bool) void {
        stage.snapshot.source = undefined;
        if (!stage.snapshot.complete) return;
        stage.snapshot.sort();
        stage.bindings_address = bindings;
        stage.bindings = bindings.*;
        stage.plan = plan;
        stage.active = true;
        stage.scalar_job.started = false;
        // No job calls back into guest memory or mutates the shared snapshot.
        if (prepare_scalar) self.submit(&stage.scalar_job, stage, true);
        self.submit(&stage.resource_job, stage, false);
    }

    fn submit(self: *Pool, work: *Work, stage: *Stage, scalar_job: bool) void {
        work.stage = stage;
        work.scalar_job = scalar_job;
        work.started = true;
        work.joined = false;
        work.failed = false;
        self.stats.submitted += 1;
        self.queue.submit(&work.job);
    }

    fn join(self: *Pool, work: *Work) void {
        if (!work.started or work.joined) return;
        const started = timestamp();
        work.job.wait();
        self.stats.wait_ns +|= timestamp() -| started;
        self.stats.worker_ns +|= work.job.elapsed_ns;
        work.joined = true;
    }

    pub fn takeScalar(self: *Pool, slot: usize, bindings: *const shaders.StageBindings, instructions: []const rdna2.Instruction, reader: shaders.MemoryReader, result: *scalar.Evaluation) bool {
        const stage = &self.stages[slot];
        if (!stage.active or (!stage.scalar_job.started and !stage.inline_prepared) or stage.bindings_address != bindings or !stage.plan.matches(instructions)) return false;
        self.join(&stage.scalar_job);
        if (stage.scalar_job.failed or !stage.snapshot.matches(reader)) {
            self.stats.fallback += 1;
            return false;
        }
        result.copyFrom(&stage.scalar_result);
        self.stats.used += 1;
        return true;
    }

    pub fn take(self: *Pool, instructions: []const rdna2.Instruction, bindings: *const shaders.StageBindings, kind: checkpoints.Kind, reader: shaders.MemoryReader) ?checkpoints.Pool.Lease {
        if (kind != .resource) return null;
        for (&self.stages) |*stage| {
            if (!stage.active or stage.bindings_address != bindings or !stage.plan.matches(instructions)) continue;
            const work = &stage.resource_job;
            self.join(work);
            if (work.resource == null) return null;
            if (work.failed or !stage.snapshot.matches(reader)) {
                self.stats.fallback += 1;
                work.resource.?.release();
                work.resource = null;
                return null;
            }
            const lease = work.resource.?;
            work.resource = null;
            self.stats.used += 1;
            return lease;
        }
        return null;
    }

    /// Join before draw-local analyses/bindings expire, including early errors.
    /// Consumers release borrowed checkpoint leases before starting a new draw.
    pub fn finish(self: *Pool) void {
        for (&self.stages) |*stage| {
            stage.shared_declined = false;
            if (!stage.active) continue;
            self.join(&stage.scalar_job);
            self.join(&stage.resource_job);
            stage.release();
        }
    }

    pub fn deinit(self: *Pool) void {
        self.finish();
        self.queue.deinit();
        self.walk_cache.deinit();
        for (&self.stages) |*stage| {
            stage.scalar_job.scratch.deinit(std.heap.page_allocator);
            stage.resource_job.scratch.deinit(std.heap.page_allocator);
        }
        self.stages = @splat(.{});
    }
};

const TestMemory = struct {
    owner: std.Thread.Id,
    value: ?u32 = 1,
    wrong_thread: bool = false,

    fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self: *TestMemory = @ptrCast(@alignCast(context.?));
        if (std.Thread.getCurrentId() != self.owner) {
            self.wrong_thread = true;
            return false;
        }
        if (address != 0x4000 or bytes.len != 4) return false;
        std.mem.writeInt(u32, bytes[0..4], self.value orelse return false, .little);
        return true;
    }

    fn reader(self: *TestMemory) shaders.MemoryReader {
        return .{ .context = self, .read_fn = read };
    }
};

test "parameterized walks rebind GPU-only entry words and still validate host reads" {
    const a = std.testing.allocator;
    const code = [_]rdna2.Instruction{
        .{ .pc = 0, .word_count = 2, .family = .smem, .opcode = .s_buffer_load_dwordx4, .src0 = .{ .kind = .sgpr, .reg = 0 }, .src1 = .{ .kind = .null }, .dst = .{ .kind = .sgpr, .reg = 20 }, .data_words = 4 },
        .{ .pc = 8, .word_count = 2, .family = .smem, .opcode = .s_load_dword, .src0 = .{ .kind = .sgpr, .reg = 4 }, .src1 = .{ .kind = .null }, .dst = .{ .kind = .sgpr, .reg = 30 }, .data_words = 1 },
        .{ .pc = 16, .family = .mimg, .opcode = .image_sample, .src1 = .{ .kind = .sgpr, .reg = 0 }, .src2 = .{ .kind = .sgpr, .reg = 40 } },
        .{ .pc = 24, .family = .sopp, .opcode = .s_endpgm },
    };
    var plan = try checkpoints.Plan.init(a, &code);
    defer plan.deinit(a);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 6;
    bindings.user_data[4] = 0x4000;
    bindings.resource_instruction_budget = 64;
    bindings.defer_vector_buffer_loads = true;
    bindings.conservative_user_data_mask = true;
    try std.testing.expectEqual(@as(u64, 15), passthroughWords(&plan, &bindings));
    const pool = try a.create(Pool);
    defer a.destroy(pool);
    pool.* = .{ .worker_limit = 0 };
    defer pool.deinit();
    const expected = try a.create(scalar.Evaluation);
    defer a.destroy(expected);
    const actual = try a.create(scalar.Evaluation);
    defer a.destroy(actual);
    const reference_sampled = try a.alloc(scalar.ScalarRegisters, plan.sampled.len);
    defer a.free(reference_sampled);
    const reference_resource = try a.alloc(scalar.ScalarRegisters, plan.resource.len);
    defer a.free(reference_resource);
    var scratch = checkpoints.Pool{};
    defer scratch.deinit(a);
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    for (0..6) |iteration| {
        bindings.user_data[0] = @intCast(0x1000 + iteration * 0x100);
        bindings.user_data[2] = @intCast(16 + iteration * 4);
        var original_hash = std.hash.Wyhash.init(71);
        var batched_hash = std.hash.Wyhash.init(71);
        std.hash.autoHash(&original_hash, bindings);
        hashBindings(&batched_hash, &bindings);
        try std.testing.expectEqual(original_hash.final(), batched_hash.final());
        if (iteration == 3) memory.value = 7;
        scalar.evaluateDecodedResourceStateAtTwoCheckpointsInto(expected, memory.reader(), &bindings, &code, plan.sampled, reference_sampled, plan.resource, reference_resource, plan.walk());
        const hits = pool.stats.cached_walks;
        var sampled = (try pool.startSampled(0, memory.reader(), &bindings, &code, &plan, &scratch, a)).?;
        defer sampled.release();
        try std.testing.expect(pool.takeScalar(0, &bindings, &code, memory.reader(), actual));
        var resource = pool.take(&code, &bindings, .resource, memory.reader()).?;
        defer resource.release();
        try std.testing.expectEqual(hits + @as(u64, if (iteration == 2 or iteration == 5) 1 else 0), pool.stats.cached_walks);
        try std.testing.expectEqualDeep(expected.registers, actual.registers);
        try std.testing.expectEqualDeep(expected.loadSlice(), actual.loadSlice());
        try std.testing.expectEqualDeep(reference_sampled, sampled.snapshots);
        try std.testing.expectEqualDeep(reference_resource, resource.snapshots);
        pool.finish();
    }
    // A changed host pointer is never treated as a GPU-only parameter.
    const hits = pool.stats.cached_walks;
    bindings.user_data[4] = 0x5000;
    try std.testing.expect(pool.startScalar(0, memory.reader(), &bindings, &code, &plan, actual));
    try std.testing.expect(actual.memory_read_failed);
    try std.testing.expectEqual(hits, pool.stats.cached_walks);
    pool.finish();
}

test "resource workers match serial checkpoints and never access guest memory" {
    for ([_]usize{ 1, 2, 4 }) |limit| try exerciseResourcePool(limit, false, false);
    try exerciseResourcePool(4, true, false);
}

test "shared resource walks preserve scalar history, skipped sites and live-input invalidation" {
    try exerciseResourcePool(0, false, true);
    try exerciseResourcePool(4, true, true);
}

fn exerciseResourcePool(limit: usize, adaptive: bool, shared: bool) !void {
    const a = std.testing.allocator;
    const code = [_]u32{
        0xf400_1a80, 125 << 25,
        0xbefe_04c1, 0xbf8c_007f,
        0xbf07_6a80, 0xbf84_0002,
        0xf020_0f28, 0x0002_0400,
        0xbf81_0000,
    };
    var program = try rdna2.decodeProgram(a, &code);
    defer program.deinit(a);
    for (program.instructions.items) |*inst| if (inst.family == .mimg) {
        inst.opcode = .image_sample;
    };
    var plan = try checkpoints.Plan.init(a, program.instructions.items);
    defer plan.deinit(a);
    const pool = try a.create(Pool);
    defer a.destroy(pool);
    pool.* = .{ .minimum_steps = 0, .worker_limit = limit, .adaptive = adaptive, .share_scalar_walks = shared };
    defer pool.deinit();
    var serial = checkpoints.Pool{};
    defer serial.deinit(a);
    var capture_scratch = checkpoints.Pool{};
    defer capture_scratch.deinit(a);
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.resource_instruction_budget = 16 * 1024;
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x4000;
    var second = bindings;
    var scalar_result: [2]scalar.Evaluation = undefined;
    for ([_]u32{ 1, 0, 7 }) |value| {
        memory.value = value;
        var initial = [_]checkpoints.Pool.Lease{
            (try pool.startSampled(0, memory.reader(), &bindings, program.instructions.items, &plan, &capture_scratch, a)).?,
            (try pool.startSampled(1, memory.reader(), &second, program.instructions.items, &plan, &capture_scratch, a)).?,
        };
        defer for (&initial) |*lease| lease.release();
        // Reentrant draws cannot overwrite an in-flight snapshot or its plan.
        try std.testing.expect(!pool.startScalar(0, memory.reader(), &bindings, program.instructions.items, &plan, &scalar_result[0]));
        for ([_]*const shaders.StageBindings{ &bindings, &second }, 0..) |stage, slot| {
            for ([_]checkpoints.Kind{ .sampled, .resource }) |kind| {
                var expected = try serial.prepare(a, program.instructions.items, &plan, kind, memory.reader(), stage);
                defer expected.release();
                var borrowed = if (kind == .resource) pool.take(program.instructions.items, stage, kind, memory.reader()) orelse return error.MissingWorkerResult else null;
                defer if (borrowed) |*lease| lease.release();
                const actual = if (borrowed) |lease| lease else initial[slot];
                try std.testing.expectEqualSlices(u32, expected.pcs, actual.pcs);
                try std.testing.expectEqualDeep(expected.snapshots, actual.snapshots);
            }
            var expected_scalar: scalar.Evaluation = undefined;
            scalar.evaluateDecodedResourceStateInto(&expected_scalar, memory.reader(), stage, program.instructions.items);
            try std.testing.expect(pool.takeScalar(slot, stage, program.instructions.items, memory.reader(), &scalar_result[slot]));
            try std.testing.expectEqualDeep(expected_scalar.registers, scalar_result[slot].registers);
            try std.testing.expectEqual(expected_scalar.load_count, scalar_result[slot].load_count);
            for (expected_scalar.loadSlice(), scalar_result[slot].loadSlice()) |expected, actual| {
                try std.testing.expectEqual(expected.address, actual.address);
                try std.testing.expectEqualSlices(u32, expected.values[0..expected.word_count], actual.values[0..actual.word_count]);
            }
        }
        pool.finish();
    }
    try std.testing.expectEqual(@as(u64, if (shared) 0 else 12), pool.stats.submitted);
    try std.testing.expectEqual(@as(u64, if (shared) 6 else 0), pool.stats.shared_walks);
    try std.testing.expectEqual(@as(u64, 12), pool.stats.used);
    try std.testing.expectEqual(@as(u64, 0), pool.stats.fallback);
    try std.testing.expect(!memory.wrong_thread);
    for (&pool.stages) |*stage| if (!shared) {
        try std.testing.expect(stage.scalar_job.job.thread_id != 0 and stage.scalar_job.job.thread_id != memory.owner);
        try std.testing.expect(stage.resource_job.job.thread_id != 0 and stage.resource_job.job.thread_id != memory.owner);
    };

    // A CPU write after capture invalidates both checkpoints and full scalar
    // reuse. The owner will perform the original live preparation instead.
    var initial = (try pool.startSampled(0, memory.reader(), &bindings, program.instructions.items, &plan, &capture_scratch, a)).?;
    initial.release();
    memory.value = 42;
    try std.testing.expect(pool.take(program.instructions.items, &bindings, .resource, memory.reader()) == null);
    try std.testing.expect(!pool.takeScalar(0, &bindings, program.instructions.items, memory.reader(), &scalar_result[0]));
    pool.finish();
    memory.value = null;
    try std.testing.expect(pool.startScalar(0, memory.reader(), &bindings, program.instructions.items, &plan, &scalar_result[0]));
    try std.testing.expect(scalar_result[0].memory_read_failed and !pool.stages[0].active);
    memory.value = 4;
    pool.worker_limit = 0;
    if (shared) {
        const budget = bindings.resource_instruction_budget;
        bindings.resource_instruction_budget = @intCast(program.instructions.items.len - 1);
        try std.testing.expect(!pool.startScalar(0, memory.reader(), &bindings, program.instructions.items, &plan, &scalar_result[0]));
        bindings.resource_instruction_budget = budget;
        // Storage-only consumers use the same full walk and retain its lease.
        try std.testing.expect(pool.startScalar(0, memory.reader(), &bindings, program.instructions.items, &plan, &scalar_result[0]));
        var expected = try serial.prepare(a, program.instructions.items, &plan, .resource, memory.reader(), &bindings);
        defer expected.release();
        var actual = pool.take(program.instructions.items, &bindings, .resource, memory.reader()) orelse return error.MissingSharedResult;
        defer actual.release();
        try std.testing.expectEqualDeep(expected.snapshots, actual.snapshots);
        pool.finish();
        // An incomplete sampled capture remains valid at its original point,
        // but cannot supply later consumers or leave a borrowed lease behind.
        memory.value = null;
        var failed = (try pool.startSampled(0, memory.reader(), &bindings, program.instructions.items, &plan, &capture_scratch, a)).?;
        failed.release();
        try std.testing.expect(!pool.stages[0].active);
        try std.testing.expect(pool.take(program.instructions.items, &bindings, .resource, memory.reader()) == null);
        memory.value = 4;
        pool.share_scalar_walks = false;
    }
    try std.testing.expect(!pool.startScalar(0, memory.reader(), &bindings, program.instructions.items, &plan, &scalar_result[0]));
    pool.worker_limit = 2;
    pool.minimum_steps = program.instructions.items.len + 1;
    try std.testing.expect(!pool.startScalar(0, memory.reader(), &bindings, program.instructions.items, &plan, &scalar_result[0]));
    pool.minimum_steps = 0;
    // Shutdown joins and releases an unfinished job without a consumer.
    try std.testing.expect(pool.startScalar(0, memory.reader(), &bindings, program.instructions.items, &plan, &scalar_result[0]));
    pool.deinit();
}

test "resource snapshots reject missing and inconsistent reads" {
    var memory = TestMemory{ .owner = std.Thread.getCurrentId(), .value = 0x12345678 };
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{ .source = memory.reader() };
    var bytes: [4]u8 = undefined;
    try std.testing.expect(Snapshot.capture(snapshot, 0x4000, &bytes));
    snapshot.sort();
    var half: [2]u8 = undefined;
    try std.testing.expect(Snapshot.replay(snapshot, 0x4001, &half));
    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34 }, &half);
    try std.testing.expect(!Snapshot.replay(snapshot, 0x5000, &bytes));
    try std.testing.expect(snapshot.missing);
    memory.value = 7;
    try std.testing.expect(Snapshot.capture(snapshot, 0x4000, &bytes));
    try std.testing.expect(!snapshot.complete);
    try std.testing.expect(!snapshot.matches(memory.reader()));
}

test "indexed snapshot capture matches linear overlap, duplicate and capacity checks" {
    const Memory = struct {
        bytes: [32768]u8 = undefined,
        fn read(context: ?*anyopaque, address: u64, output: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address > self.bytes.len or output.len > self.bytes.len - address) return false;
            @memcpy(output, self.bytes[@intCast(address)..][0..output.len]);
            return true;
        }
    };
    var memory = Memory{};
    for (&memory.bytes, 0..) |*byte, i| byte.* = @truncate(i *% 37);
    const a = std.testing.allocator;
    const reference = try a.create(Snapshot);
    defer a.destroy(reference);
    const indexed = try a.create(Snapshot);
    defer a.destroy(indexed);
    const reader = shaders.MemoryReader{ .context = &memory, .read_fn = Memory.read };
    reference.* = .{ .source = reader };
    indexed.* = .{ .source = reader };
    const saved = indexed_resource_snapshot_capture;
    defer indexed_resource_snapshot_capture = saved;
    var before: [65]u8 = undefined;
    var after: [65]u8 = undefined;
    for (0..scalar.maximum_loads * 2 + 3) |i| {
        // Permuted starts, nested overlaps, duplicate reads, a conflicting
        // CPU write, a full table, an oversized read and a missing range.
        const slot = (i * 149) % scalar.maximum_loads;
        var address: u64 = slot * 48;
        var size: usize = if (slot % 2 == 0) 64 else 4;
        if (i == scalar.maximum_loads + 7) memory.bytes[@intCast(address)] ^= 1;
        if (i == scalar.maximum_loads * 2) address = 30000;
        if (i == scalar.maximum_loads * 2 + 1) size = 65;
        if (i == scalar.maximum_loads * 2 + 2) address = 32768;
        indexed_resource_snapshot_capture = false;
        const expected = Snapshot.capture(reference, address, before[0..size]);
        indexed_resource_snapshot_capture = true;
        try std.testing.expectEqual(expected, Snapshot.capture(indexed, address, after[0..size]));
        if (expected) try std.testing.expectEqualSlices(u8, before[0..size], after[0..size]);
        try std.testing.expectEqual(reference.count, indexed.count);
        try std.testing.expectEqual(reference.complete, indexed.complete);
    }
    reference.sort();
    indexed.sort();
    for (reference.reads[0..reference.count]) |read| {
        try std.testing.expectEqual(Snapshot.replay(reference, read.address + 1, before[0 .. read.size - 1]), Snapshot.replay(indexed, read.address + 1, after[0 .. read.size - 1]));
        try std.testing.expectEqualSlices(u8, before[0 .. read.size - 1], after[0 .. read.size - 1]);
    }
    // A copied capture and a runtime diagnostic toggle rebuild their index.
    indexed.copyFrom(reference);
    indexed.source = reader;
    indexed.complete = true;
    reference.complete = true;
    indexed_resource_snapshot_capture = false;
    _ = Snapshot.capture(reference, 1, before[0..3]);
    indexed_resource_snapshot_capture = true;
    _ = Snapshot.capture(indexed, 1, after[0..3]);
    try std.testing.expectEqual(reference.complete, indexed.complete);

    // The next capture may have the same length but a different address
    // order. A diagnostic toggle must not mistake the old index for current.
    indexed.count = 0;
    indexed.complete = true;
    indexed.indexed_count = 3;
    @memcpy(indexed.order[0..3], &[_]u16{ 2, 0, 1 });
    indexed_resource_snapshot_capture = false;
    for ([_]u64{ 8, 4, 16 }) |address| try std.testing.expect(Snapshot.capture(indexed, address, after[0..4]));
    indexed_resource_snapshot_capture = true;
    try std.testing.expect(Snapshot.capture(indexed, 8, after[0..4]));
    try std.testing.expectEqual(@as(usize, 3), indexed.count);
    try std.testing.expect(indexed.complete);
    memory.bytes[8] ^= 1;
    try std.testing.expect(Snapshot.capture(indexed, 8, after[0..4]));
    try std.testing.expect(!indexed.complete);
}

test "shared indexed resource walk preserves lane clobbers and branch checkpoints" {
    const a = std.testing.allocator;
    var instructions = [_]rdna2.Instruction{
        .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 0 } },
        .{ .family = .vop3, .opcode = .v_writelane_b32, .dst = .{ .kind = .vgpr, .reg = 18 }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .integer_inline_constant } },
        .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 18 } },
        .{ .family = .vop3, .opcode = .v_readlane_b32, .dst = .{ .kind = .sgpr, .reg = 10 }, .src0 = .{ .kind = .vgpr, .reg = 18 }, .src1 = .{ .kind = .integer_inline_constant } },
        .{ .family = .smem, .opcode = .s_load_dword, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .integer_inline_constant }, .data_words = 1 },
        .{ .family = .sop2, .opcode = .s_and_b32, .dst = .{ .kind = .sgpr, .reg = 5 }, .src0 = .{ .kind = .sgpr, .reg = 4 }, .src1 = .{ .kind = .integer_inline_constant, .value = 1 } },
        .{ .family = .sopp, .opcode = .s_cbranch_scc0, .branch_target = 36 },
        .{ .family = .mimg, .opcode = .image_sample, .dst = .{ .kind = .vgpr, .reg = 2 }, .src1 = .{ .kind = .sgpr, .reg = 4 } },
        .{ .family = .sopp, .opcode = .s_branch, .branch_target = 40 },
        .{ .family = .mimg, .opcode = .image_sample, .dst = .{ .kind = .vgpr, .reg = 3 }, .src1 = .{ .kind = .sgpr, .reg = 4 } },
        .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 0 } },
        .{ .family = .sopp, .opcode = .s_endpgm },
    };
    for (&instructions, 0..) |*inst, i| {
        inst.pc = @intCast(i * 4);
        inst.word_count = 1;
    }
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.resource_instruction_budget = instructions.len;
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x4000;
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    var plan = try checkpoints.Plan.init(a, &instructions);
    defer plan.deinit(a);
    const pool = try a.create(Pool);
    defer a.destroy(pool);
    pool.* = .{ .worker_limit = 0 };
    defer pool.deinit();
    pool.walk_cache.enabled = false;
    var scratch = checkpoints.Pool{};
    defer scratch.deinit(a);
    const reference_resource = try a.alloc(scalar.ScalarRegisters, plan.resource.len);
    defer a.free(reference_resource);
    const reference_sampled = try a.alloc(scalar.ScalarRegisters, plan.sampled.len);
    defer a.free(reference_sampled);
    for (0..2) |branch| {
        memory.value = @intCast(branch);
        var expected: scalar.Evaluation = undefined;
        scalar.evaluateDecodedResourceStateAtTwoCheckpointsInto(&expected, memory.reader(), &bindings, &instructions, plan.sampled, reference_sampled, plan.resource, reference_resource, null);
        var sampled = (try pool.startSampled(0, memory.reader(), &bindings, &instructions, &plan, &scratch, a)).?;
        defer sampled.release();
        var actual: scalar.Evaluation = undefined;
        try std.testing.expect(pool.takeScalar(0, &bindings, &instructions, memory.reader(), &actual));
        var resource = pool.take(&instructions, &bindings, .resource, memory.reader()).?;
        defer resource.release();
        try std.testing.expectEqualDeep(expected.registers, actual.registers);
        try std.testing.expect(!actual.registers[10].known);
        try std.testing.expectEqual(expected.stop_reason, actual.stop_reason);
        try std.testing.expectEqual(expected.address_user_data_mask, actual.address_user_data_mask);
        try std.testing.expectEqual(expected.load_count, actual.load_count);
        try std.testing.expectEqualDeep(reference_sampled, sampled.snapshots);
        try std.testing.expectEqualDeep(reference_resource, resource.snapshots);
        try std.testing.expect(actual.instruction_count < expected.instruction_count);
        pool.finish();
    }
}

test "shared loop resource walks preserve dense budgets and checkpoint history" {
    const a = std.testing.allocator;
    const saved_exact = exact_scalar_walk_budget;
    defer exact_scalar_walk_budget = saved_exact;
    var instructions = [_]rdna2.Instruction{
        .{ .family = .sop1, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 6 }, .src0 = .{ .kind = .integer_inline_constant, .value = 4 } },
        .{ .family = .smem, .opcode = .s_load_dword, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .integer_inline_constant }, .data_words = 1 },
        .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 0 } },
        .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 1 } },
        .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 2 } },
        .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 3 } },
        .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 4 } },
        .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 5 } },
        .{ .family = .sop2, .opcode = .s_sub_u32, .dst = .{ .kind = .sgpr, .reg = 6 }, .src0 = .{ .kind = .sgpr, .reg = 6 }, .src1 = .{ .kind = .integer_inline_constant, .value = 1 } },
        .{ .family = .sopc, .opcode = .s_cmp_eq_u32, .src0 = .{ .kind = .sgpr, .reg = 6 }, .src1 = .{ .kind = .integer_inline_constant } },
        .{ .family = .sopp, .opcode = .s_cbranch_scc0, .branch_target = 4 },
        .{ .family = .mimg, .opcode = .image_sample, .dst = .{ .kind = .vgpr, .reg = 2 }, .src1 = .{ .kind = .sgpr, .reg = 4 } },
        .{ .family = .sopp, .opcode = .s_endpgm },
    };
    for (&instructions, 0..) |*inst, i| {
        inst.pc = @intCast(i * 4);
        inst.word_count = 1;
        inst.src_count = switch (inst.family) {
            .sop1, .vop1 => 1,
            .sop2, .sopc, .smem => 2,
            else => 0,
        };
    }
    var plan = try checkpoints.Plan.init(a, &instructions);
    defer plan.deinit(a);
    try std.testing.expect(!plan.forward_only);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x4000;
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    const pool = try a.create(Pool);
    defer a.destroy(pool);
    pool.* = .{ .worker_limit = 0 };
    defer pool.deinit();
    pool.walk_cache.enabled = false;
    var scratch = checkpoints.Pool{};
    defer scratch.deinit(a);
    var serial = checkpoints.Pool{};
    defer serial.deinit(a);
    const reference_resource = try a.alloc(scalar.ScalarRegisters, plan.resource.len);
    defer a.free(reference_resource);
    const reference_sampled = try a.alloc(scalar.ScalarRegisters, plan.sampled.len);
    defer a.free(reference_sampled);
    for ([_]bool{ false, true }) |exact| {
        exact_scalar_walk_budget = exact;
        for ([_]u32{ 256, 43, 42, 30, 13 }) |budget| {
            const can_share = budget == 256 or (exact and budget == 43);
            bindings.resource_instruction_budget = budget;
            var expected: scalar.Evaluation = undefined;
            scalar.evaluateDecodedResourceStateAtTwoCheckpointsInto(&expected, memory.reader(), &bindings, &instructions, plan.sampled, reference_sampled, plan.resource, reference_resource, null);
            var sampled = (try pool.startSampled(0, memory.reader(), &bindings, &instructions, &plan, &scratch, a)).?;
            defer sampled.release();
            var sampled_oracle = try serial.prepare(a, &instructions, &plan, .sampled, memory.reader(), &bindings);
            defer sampled_oracle.release();
            try std.testing.expectEqualDeep(sampled_oracle.snapshots, sampled.snapshots);
            var actual: scalar.Evaluation = undefined;
            const shared = pool.takeScalar(0, &bindings, &instructions, memory.reader(), &actual);
            try std.testing.expectEqual(can_share, shared);
            if (shared) {
                var resource = pool.take(&instructions, &bindings, .resource, memory.reader()).?;
                defer resource.release();
                try std.testing.expectEqualDeep(reference_sampled, sampled.snapshots);
                try std.testing.expectEqualDeep(reference_resource, resource.snapshots);
                try std.testing.expectEqualDeep(expected.registers, actual.registers);
                try std.testing.expectEqual(expected.stop_reason, actual.stop_reason);
                try std.testing.expectEqual(@as(u32, 43), expected.instruction_count);
                try std.testing.expectEqual(@as(?u64, 43), actual.dense_instruction_count);
                try std.testing.expectEqual(@as(u32, 0), actual.registers[6].value);
                try std.testing.expectEqual(@as(usize, 1), actual.load_count);
                try std.testing.expectEqual(expected.load_count, actual.load_count);
                for (expected.loadSlice(), actual.loadSlice()) |want, got| {
                    try std.testing.expectEqual(want.address, got.address);
                    try std.testing.expectEqual(want.pc, got.pc);
                    try std.testing.expectEqualSlices(u32, want.values[0..want.word_count], got.values[0..got.word_count]);
                }
            } else {
                try std.testing.expectEqual(if (budget < 43) scalar.StopReason.instruction_limit else scalar.StopReason.end_program, expected.stop_reason);
                try std.testing.expect(pool.stages[0].shared_declined);
                try std.testing.expect(!pool.startScalar(0, memory.reader(), &bindings, &instructions, &plan, &actual));
            }
            pool.finish();
            try std.testing.expectEqual(can_share, pool.startScalar(0, memory.reader(), &bindings, &instructions, &plan, &actual));
            if (can_share) try std.testing.expectEqualDeep(expected.registers, actual.registers);
            pool.finish();
        }
    }
    try std.testing.expectEqual(@as(u64, 6), pool.stats.shared_loop_walks);
    try std.testing.expectEqual(@as(u64, 7), pool.stats.shared_loop_fallbacks);
}

test "indexed dense visit counts include branch gaps and reject malformed destinations" {
    const a = std.testing.allocator;
    for (0..5) |variant| {
        var instructions = [_]rdna2.Instruction{
            .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr } },
            .{ .family = .sopp, .opcode = .s_branch, .branch_target = 12 },
            .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr } },
            .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr } },
            .{ .family = .sop1, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 8 }, .src0 = .{ .kind = .integer_inline_constant, .value = 17 } },
            .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr } },
            .{ .family = .mimg, .opcode = .image_sample, .dst = .{ .kind = .vgpr, .reg = 2 }, .src1 = .{ .kind = .sgpr, .reg = 8 } },
            .{ .family = .sopp, .opcode = .s_endpgm },
        };
        if (variant == 1) instructions[1].branch_target = 16;
        if (variant == 2) instructions[1].branch_target = 14;
        if (variant == 3) instructions[1].opcode = .s_cbranch_scc0;
        if (variant == 4) instructions[7] = .{ .family = .vop1, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr } };
        for (&instructions, 0..) |*inst, i| {
            inst.pc = @intCast(i * 4);
            inst.word_count = 1;
        }
        var plan = try checkpoints.Plan.init(a, &instructions);
        defer plan.deinit(a);
        var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
        var bindings = std.mem.zeroes(shaders.StageBindings);
        bindings.resource_instruction_budget = 128;
        var dense: scalar.Evaluation = undefined;
        var indexed: scalar.Evaluation = undefined;
        scalar.evaluateDecodedResourceStateInto(&dense, memory.reader(), &bindings, &instructions);
        scalar.evaluateDecodedResourceStateAtCheckpointsInto(&indexed, memory.reader(), &bindings, &instructions, &.{}, &.{}, plan.walk());
        try std.testing.expectEqualDeep(dense.registers, indexed.registers);
        if (variant == 2) {
            try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), indexed.dense_instruction_count);
        } else if (variant == 4) {
            try std.testing.expectEqual(@as(?u64, null), indexed.dense_instruction_count);
        } else {
            try std.testing.expectEqual(@as(?u64, dense.instruction_count), indexed.dense_instruction_count);
        }
    }
}

test "resource walk cache recycling replaces identity dependencies and scalar results" {
    const old_limit = resource_walk_cache_entries;
    defer resource_walk_cache_entries = old_limit;
    resource_walk_cache_entries = 1;
    var cache = WalkCache{};
    defer cache.deinit();
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    const evaluation = try std.testing.allocator.create(scalar.Evaluation);
    defer std.testing.allocator.destroy(evaluation);
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    const instructions = [_]rdna2.Instruction{.{ .opcode = .s_endpgm }};
    var plan = try checkpoints.Plan.init(std.testing.allocator, &instructions);
    defer plan.deinit(std.testing.allocator);
    var initial: ?*const WalkCache.Entry = null;
    for (0..5) |i| {
        bindings.user_data[0] = @intCast(i);
        memory.value = @intCast(i + 1);
        snapshot.* = .{ .source = memory.reader() };
        var bytes: [4]u8 = undefined;
        try std.testing.expect(Snapshot.capture(snapshot, 0x4000, &bytes));
        evaluation.reset();
        evaluation.instruction_count = @intCast(i + 17);
        cache.remember(&plan, &bindings, snapshot, evaluation, null, &.{});
        cache.remember(&plan, &bindings, snapshot, evaluation, null, &.{});
        const found = cache.lookup(&plan, &bindings, memory.reader(), false).?;
        if (initial) |entry| try std.testing.expect(entry == found) else initial = found;
        try std.testing.expectEqual(i + 17, found.evaluation.instruction_count);
        memory.value = 99;
        try std.testing.expect(cache.lookup(&plan, &bindings, memory.reader(), false) == null);
        memory.value = @intCast(i + 1);
        bindings.user_data[0] = 100;
        try std.testing.expect(cache.lookup(&plan, &bindings, memory.reader(), false) == null);
    }
    try std.testing.expectEqual(@sizeOf(WalkCache.Entry), cache.bytes);
}

test "resource walk hints retain full identity binding and dependency validation" {
    const saved_hints = hinted_resource_walks;
    const saved_entries = resource_walk_cache_entries;
    defer {
        hinted_resource_walks = saved_hints;
        resource_walk_cache_entries = saved_entries;
    }
    resource_walk_cache_entries = 4;
    const a = std.testing.allocator;
    const snapshot = try a.create(Snapshot);
    defer a.destroy(snapshot);
    const evaluation = try a.create(scalar.Evaluation);
    defer a.destroy(evaluation);
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    const bindings = std.mem.zeroes(shaders.StageBindings);
    const instructions = [_]rdna2.Instruction{.{ .opcode = .s_endpgm }};
    var plan = try checkpoints.Plan.init(a, &instructions);
    defer plan.deinit(a);
    // Share the hint bucket, but never the exact immutable-analysis identity.
    var other = plan;
    other.identity += 64;
    for ([_]bool{ false, true }) |enabled| {
        hinted_resource_walks = enabled;
        var cache = WalkCache{};
        defer cache.deinit();
        snapshot.* = .{ .source = memory.reader() };
        var bytes: [4]u8 = undefined;
        try std.testing.expect(Snapshot.capture(snapshot, 0x4000, &bytes));
        for ([_]*const checkpoints.Plan{ &plan, &other }, 0..) |selected, i| {
            evaluation.reset();
            evaluation.instruction_count = @intCast(i + 17);
            cache.remember(selected, &bindings, snapshot, evaluation, null, &.{});
            cache.remember(selected, &bindings, snapshot, evaluation, null, &.{});
        }
        for (0..8) |i| {
            const selected = if (i % 2 == 0) &plan else &other;
            const found = cache.lookup(selected, &bindings, memory.reader(), false).?;
            try std.testing.expectEqual(@as(u32, @intCast(i % 2 + 17)), found.evaluation.instruction_count);
        }
        var changed = bindings;
        changed.user_data[0] = 99;
        try std.testing.expect(cache.lookup(&other, &changed, memory.reader(), false) == null);
        try std.testing.expect(cache.lookup(&other, &bindings, memory.reader(), true) == null);
        memory.value = null;
        try std.testing.expect(cache.lookup(&other, &bindings, memory.reader(), false) == null);
        memory.value = 1;
        // An out-of-range hint must not be dereferenced after a limit change.
        cache.hints[plan.identity % cache.hints.len] = 511;
        try std.testing.expect(cache.lookup(&plan, &bindings, memory.reader(), false) != null);
        resource_walk_cache_entries = 1;
        try std.testing.expect(cache.lookup(&other, &bindings, memory.reader(), false) == null);
        resource_walk_cache_entries = 4;
    }
}

test "resource walk admission ignores repeatedly changing contents at the same address" {
    const previous = content_aware_walk_admission;
    defer content_aware_walk_admission = previous;
    content_aware_walk_admission = true;
    var cache = WalkCache{};
    defer cache.deinit();
    const a = std.testing.allocator;
    const snapshot = try a.create(Snapshot);
    defer a.destroy(snapshot);
    const evaluation = try a.create(scalar.Evaluation);
    defer a.destroy(evaluation);
    evaluation.reset();
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    const instructions = [_]rdna2.Instruction{.{ .opcode = .s_endpgm }};
    var plan = try checkpoints.Plan.init(a, &instructions);
    defer plan.deinit(a);
    for (0..128) |value| {
        memory.value = @intCast(value);
        snapshot.* = .{ .source = memory.reader() };
        var bytes: [4]u8 = undefined;
        try std.testing.expect(Snapshot.capture(snapshot, 0x4000, &bytes));
        cache.remember(&plan, &bindings, snapshot, evaluation, null, &.{});
        try std.testing.expectEqual(@as(usize, 0), cache.bytes);
    }
    cache.remember(&plan, &bindings, snapshot, evaluation, null, &.{});
    try std.testing.expect(cache.lookup(&plan, &bindings, memory.reader(), false) != null);
    // Admission is only a cost heuristic. Hits still check the actual bytes.
    memory.value = 99;
    try std.testing.expect(cache.lookup(&plan, &bindings, memory.reader(), false) == null);
}

test "resource walk recycling changes checkpoint views without exposing stale tails" {
    const old_limit = resource_walk_cache_entries;
    const old_bytes = resource_walk_cache_bytes;
    defer {
        resource_walk_cache_entries = old_limit;
        resource_walk_cache_bytes = old_bytes;
    }
    resource_walk_cache_entries = 1;
    resource_walk_cache_bytes = 32 * 1024 * 1024;
    var cache = WalkCache{};
    defer cache.deinit();
    const a = std.testing.allocator;
    const snapshot = try a.create(Snapshot);
    defer a.destroy(snapshot);
    snapshot.* = .{};
    const evaluation = try a.create(scalar.Evaluation);
    defer a.destroy(evaluation);
    evaluation.reset();
    const states = try a.alloc(scalar.ScalarRegisters, 4);
    defer a.free(states);
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    const instructions = [_]rdna2.Instruction{.{ .opcode = .s_endpgm }};
    var plan = try checkpoints.Plan.init(a, &instructions);
    defer plan.deinit(a);
    var first: ?*const WalkCache.Entry = null;
    var storage: ?[*]scalar.ScalarRegisters = null;
    for ([_][2]usize{ .{ 3, 1 }, .{ 0, 1 }, .{ 2, 2 }, .{ 1, 0 } }, 0..) |counts, iteration| {
        for (states, 0..) |*state, index| {
            state.* = @splat(.{ .known = true, .value = @intCast(100 * iteration + index) });
        }
        // Exercise both matching identity replacement and LRU replacement.
        bindings.user_data[0] = @intCast(iteration / 2);
        const sampled = if (counts[0] == 0) null else states[0..counts[0]];
        const resource = states[counts[0]..][0..counts[1]];
        cache.remember(&plan, &bindings, snapshot, evaluation, sampled, resource);
        cache.remember(&plan, &bindings, snapshot, evaluation, sampled, resource);
        const found = cache.lookup(&plan, &bindings, memory.reader(), false).?;
        if (first) |initial| try std.testing.expect(initial == found) else first = found;
        if (storage) |initial| try std.testing.expect(initial == found.checkpoint_storage.ptr) else storage = found.checkpoint_storage.ptr;
        try std.testing.expectEqualDeep(sampled orelse &.{}, found.sampled);
        try std.testing.expectEqualDeep(resource, found.resource);
        try std.testing.expectEqual(sampled != null, found.has_sampled);
        try std.testing.expectEqual(@sizeOf(WalkCache.Entry) + 4 * @sizeOf(scalar.ScalarRegisters), cache.bytes);
    }
    // A reduced budget accounts for retained capacity, not just the short view.
    resource_walk_cache_bytes = @sizeOf(WalkCache.Entry);
    cache.updateLimits();
    try std.testing.expectEqual(@as(usize, 0), cache.bytes);
    try std.testing.expect(cache.lookup(&plan, &bindings, memory.reader(), false) == null);
}

test "resource walk cache releases retired entries when bounded limits shrink" {
    const saved_entries = resource_walk_cache_entries;
    const saved_bytes = resource_walk_cache_bytes;
    defer {
        resource_walk_cache_entries = saved_entries;
        resource_walk_cache_bytes = saved_bytes;
    }
    resource_walk_cache_entries = 3;
    resource_walk_cache_bytes = 32 * 1024 * 1024;
    var cache = WalkCache{};
    defer cache.deinit();
    const snapshot = try std.testing.allocator.create(Snapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = .{};
    const evaluation = try std.testing.allocator.create(scalar.Evaluation);
    defer std.testing.allocator.destroy(evaluation);
    evaluation.reset();
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    const instructions = [_]rdna2.Instruction{.{ .opcode = .s_endpgm }};
    var plan = try checkpoints.Plan.init(std.testing.allocator, &instructions);
    defer plan.deinit(std.testing.allocator);
    for (0..3) |i| {
        bindings.user_data[0] = @intCast(i);
        cache.remember(&plan, &bindings, snapshot, evaluation, null, &.{});
        cache.remember(&plan, &bindings, snapshot, evaluation, null, &.{});
        try std.testing.expect(cache.lookup(&plan, &bindings, memory.reader(), false) != null);
    }
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(WalkCache.Entry)), cache.bytes);
    resource_walk_cache_entries = 1;
    // The last insertion occupies slot zero; higher retired slots are freed.
    try std.testing.expect(cache.lookup(&plan, &bindings, memory.reader(), false) != null);
    try std.testing.expectEqual(@as(usize, @sizeOf(WalkCache.Entry)), cache.bytes);
    bindings.user_data[0] = 0;
    try std.testing.expect(cache.lookup(&plan, &bindings, memory.reader(), false) == null);
    resource_walk_cache_entries = std.math.maxInt(u32);
    resource_walk_cache_bytes = std.math.maxInt(u64);
    cache.updateLimits();
    try std.testing.expectEqual(@as(usize, 512), cache.entry_limit);
    try std.testing.expectEqual(@as(usize, 128 * 1024 * 1024), cache.byte_limit);
    resource_walk_cache_entries = 0;
    resource_walk_cache_bytes = 0;
    cache.updateLimits();
    try std.testing.expectEqual(@as(usize, 1), cache.entry_limit);
    try std.testing.expectEqual(@as(usize, @sizeOf(WalkCache.Entry)), cache.byte_limit);
}

test "cached resource walks validate bytes bindings and immutable plan identity" {
    const a = std.testing.allocator;
    const code = [_]u32{
        0xf400_1a80, 125 << 25,
        0xbefe_04c1, 0xbf8c_007f,
        0xbf07_6a80, 0xbf84_0002,
        0xf020_0f28, 0x0002_0400,
        0xbf81_0000,
    };
    var program = try rdna2.decodeProgram(a, &code);
    defer program.deinit(a);
    for (program.instructions.items) |*inst| if (inst.family == .mimg) {
        inst.opcode = .image_sample;
    };
    var plan = try checkpoints.Plan.init(a, program.instructions.items);
    defer plan.deinit(a);
    // Even exactly the same instruction allocation can belong to a new plan.
    var replacement = try checkpoints.Plan.init(a, program.instructions.items);
    defer replacement.deinit(a);
    const pool = try a.create(Pool);
    defer a.destroy(pool);
    pool.* = .{ .worker_limit = 0 };
    defer pool.deinit();
    var scratch = checkpoints.Pool{};
    defer scratch.deinit(a);
    var serial = checkpoints.Pool{};
    defer serial.deinit(a);
    var memory = TestMemory{ .owner = std.Thread.getCurrentId() };
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.resource_instruction_budget = 16 * 1024;
    bindings.user_data_count = 2;
    bindings.user_data[0] = 0x4000;
    for (0..7) |iteration| {
        if (iteration == 3) memory.value = 0; // Changes the branch and skipped sites.
        if (iteration == 4) bindings.user_data[1] = 0x80000000; // Masks off in the address but is still an input.
        const active_plan = if (iteration == 5) &replacement else &plan;
        if (iteration == 6) pool.walk_cache.enabled = false;
        const previous_hits = pool.stats.cached_walks;
        var sampled = (try pool.startSampled(0, memory.reader(), &bindings, program.instructions.items, active_plan, &scratch, a)).?;
        defer sampled.release();
        var resource = pool.take(program.instructions.items, &bindings, .resource, memory.reader()).?;
        defer resource.release();
        for ([_]checkpoints.Kind{ .sampled, .resource }) |kind| {
            var expected = try serial.prepare(a, program.instructions.items, active_plan, kind, memory.reader(), &bindings);
            defer expected.release();
            try std.testing.expectEqualDeep(expected.snapshots, if (kind == .sampled) sampled.snapshots else resource.snapshots);
        }
        var evaluation: scalar.Evaluation = undefined;
        try std.testing.expect(pool.takeScalar(0, &bindings, program.instructions.items, memory.reader(), &evaluation));
        var expected: scalar.Evaluation = undefined;
        scalar.evaluateDecodedResourceStateInto(&expected, memory.reader(), &bindings, program.instructions.items);
        try std.testing.expectEqualDeep(expected.registers, evaluation.registers);
        try std.testing.expectEqual(expected.load_count, evaluation.load_count);
        for (expected.loadSlice(), evaluation.loadSlice()) |want, actual| {
            try std.testing.expectEqual(want.address, actual.address);
            try std.testing.expectEqual(want.pc, actual.pc);
            try std.testing.expectEqual(want.word_count, actual.word_count);
            try std.testing.expectEqualSlices(u32, want.values[0..want.word_count], actual.values[0..actual.word_count]);
        }
        try std.testing.expectEqual(previous_hits + @as(u64, if (iteration == 2) 1 else 0), pool.stats.cached_walks);
        pool.finish();
    }
    pool.walk_cache.enabled = true;
    bindings.user_data[1] = 0;
    memory.value = null;
    var failed = (try pool.startSampled(0, memory.reader(), &bindings, program.instructions.items, &plan, &scratch, a)).?;
    failed.release();
    try std.testing.expect(!pool.stages[0].active);
    try std.testing.expectEqual(@as(u64, 1), pool.stats.cached_walks);
    pool.deinit();
    try std.testing.expectEqual(@as(usize, 0), pool.walk_cache.bytes);
}

test "contained scalar reads reuse covering observations and detect replacements" {
    const a = std.testing.allocator;
    const Memory = struct {
        bytes: [128]u8 = @splat(0x37),
        calls: usize = 0,
        fn read(raw: ?*anyopaque, address: u64, out: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (address > self.bytes.len or out.len > self.bytes.len - address) return false;
            @memcpy(out, self.bytes[@intCast(address)..][0..out.len]);
            return true;
        }
    };
    const saved = collapse_contained_scalar_reads;
    defer collapse_contained_scalar_reads = saved;
    const saved_indexed = indexed_resource_snapshot_capture;
    defer indexed_resource_snapshot_capture = saved_indexed;
    for ([_]bool{ false, true }) |indexed| for ([_]bool{ false, true }) |enabled| {
        collapse_contained_scalar_reads = enabled;
        indexed_resource_snapshot_capture = indexed;
        var memory = Memory{};
        const reader = shaders.MemoryReader{ .context = &memory, .read_fn = Memory.read };
        const snapshot = try a.create(Snapshot);
        defer a.destroy(snapshot);
        snapshot.* = .{ .source = reader };
        var bytes: [64]u8 = undefined;
        try std.testing.expect(Snapshot.capture(snapshot, 16, &bytes));
        for ([_]u64{ 16, 32, 76 }) |address| try std.testing.expect(Snapshot.capture(snapshot, address, bytes[0..4]));
        try std.testing.expectEqual(@as(usize, if (enabled) 1 else 4), snapshot.count);
        memory.calls = 0;
        try std.testing.expect(snapshot.matches(reader));
        try std.testing.expectEqual(snapshot.count, memory.calls);
        snapshot.sort();
        try std.testing.expect(Snapshot.replay(snapshot, 31, bytes[0..17]));
        try std.testing.expect(std.mem.allEqual(u8, bytes[0..17], 0x37));
        memory.bytes[35] = 0x91;
        try std.testing.expect(!snapshot.matches(reader));
        try std.testing.expect(Snapshot.capture(snapshot, 32, bytes[0..4]));
        try std.testing.expect(!snapshot.complete);
        // A read that crosses the old boundary remains a separate dependency.
        snapshot.* = .{ .source = reader };
        try std.testing.expect(Snapshot.capture(snapshot, 16, bytes[0..16]));
        try std.testing.expect(Snapshot.capture(snapshot, 28, bytes[0..16]));
        try std.testing.expectEqual(@as(usize, 2), snapshot.count);
        memory.bytes[40] ^= 1;
        try std.testing.expect(!snapshot.matches(reader));
    };
}
