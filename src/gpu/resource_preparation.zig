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
    complete: bool = true,
    missing: bool = false,
    source: shaders.MemoryReader = undefined,

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
        for (self.reads[0..self.count]) |*read| {
            if (read.address == address and read.size == bytes.len) {
                if (!std.mem.eql(u8, read.bytes[0..read.size], bytes)) self.complete = false;
                return true;
            }
            const first = @max(address, read.address);
            const end = @min(address + bytes.len, read.address + read.size);
            if (first < end and !std.mem.eql(u8, bytes[@intCast(first - address)..@intCast(end - address)], read.bytes[@intCast(first - read.address)..@intCast(end - read.address)]))
                self.complete = false;
        }
        if (self.count == self.reads.len) {
            self.complete = false;
            return true;
        }
        const read = &self.reads[self.count];
        read.address = address;
        read.size = @intCast(bytes.len);
        @memcpy(read.bytes[0..bytes.len], bytes);
        self.count += 1;
        return true;
    }

    fn sort(self: *Snapshot) void {
        for (self.order[0..self.count], 0..) |*index, position| index.* = @intCast(position);
        std.mem.sort(u16, self.order[0..self.count], self, struct {
            fn less(snapshot: *Snapshot, a: u16, b: u16) bool {
                return snapshot.reads[a].address < snapshot.reads[b].address;
            }
        }.less);
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
    used: u64 = 0,
    fallback: u64 = 0,
    worker_ns: u64 = 0,
    wait_ns: u64 = 0,
};

pub const Pool = struct {
    pub const maximum_workers = cpu.Queue.maximum_workers;
    pub const minimum_scalar_steps = 256;
    worker_limit: usize = 2,
    adaptive: bool = false,
    minimum_steps: usize = minimum_scalar_steps,
    queue: cpu.Queue = .{},
    configured_limit: ?usize = null,
    configured_adaptive: bool = false,
    stages: [2]Stage = @splat(.{}),
    stats: Stats = .{},

    // A stage snapshot is immutable until both jobs complete. Separate jobs
    // allow a long checkpoint walk to overlap the other stage's scalar walk.
    const Stage = struct {
        active: bool = false,
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
        stage.snapshot.complete = true;
        stage.snapshot.missing = false;
        return stage;
    }

    /// Capture the original sampled walk at its original ordering point. The
    /// owner immediately consumes its result while independent scalar/storage
    /// jobs use only the captured bytes during subsequent texture staging.
    pub fn startSampled(self: *Pool, slot: usize, reader: shaders.MemoryReader, bindings: *const shaders.StageBindings, instructions: []const rdna2.Instruction, plan: ?*const checkpoints.Plan, scratch: *checkpoints.Pool, allocator: std.mem.Allocator) !?checkpoints.Pool.Lease {
        if (plan == null or plan.?.sampled.len == 0) return null;
        const stage = self.available(slot, instructions, plan) orelse return null;
        stage.snapshot.source = reader;
        const lease = try scratch.prepare(allocator, instructions, plan, .sampled, .{ .context = &stage.snapshot, .read_fn = Snapshot.capture }, bindings);
        self.launch(stage, bindings, plan.?, true);
        return lease;
    }

    pub fn startScalar(self: *Pool, slot: usize, reader: shaders.MemoryReader, bindings: *const shaders.StageBindings, instructions: []const rdna2.Instruction, plan: ?*const checkpoints.Plan, scalar_result: *scalar.Evaluation) bool {
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
        if (!stage.active or !stage.scalar_job.started or stage.bindings_address != bindings or !stage.plan.matches(instructions)) return false;
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
            if (!stage.active) continue;
            self.join(&stage.scalar_job);
            self.join(&stage.resource_job);
            stage.release();
        }
    }

    pub fn deinit(self: *Pool) void {
        self.finish();
        self.queue.deinit();
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

test "resource workers match serial checkpoints and never access guest memory" {
    for ([_]usize{ 1, 2, 4 }) |limit| try exerciseResourcePool(limit, false);
    try exerciseResourcePool(4, true);
}

fn exerciseResourcePool(limit: usize, adaptive: bool) !void {
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
    pool.* = .{ .minimum_steps = 0, .worker_limit = limit, .adaptive = adaptive };
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
    try std.testing.expectEqual(@as(u64, 12), pool.stats.submitted);
    try std.testing.expectEqual(@as(u64, 12), pool.stats.used);
    try std.testing.expectEqual(@as(u64, 0), pool.stats.fallback);
    try std.testing.expect(!memory.wrong_thread);
    for (&pool.stages) |*stage| {
        try std.testing.expect(stage.scalar_job.job.thread_id != 0 and stage.scalar_job.job.thread_id != memory.owner);
        try std.testing.expect(stage.resource_job.job.thread_id != 0 and stage.resource_job.job.thread_id != memory.owner);
    }

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
