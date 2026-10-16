// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const builtin = @import("builtin");

pub var guest_copy_pool = Pool{};
pub export var rep_large_copies: bool = true;
pub export var rep_copy_min_bytes: usize = 256 * 1024;

/// Keep the ordinary inline copy for short spans. Long host transfers benefit
/// from the x86 string-copy engine without requiring AVX or aligned addresses.
/// The caller must provide disjoint ranges of equal length, as for @memcpy.
fn copyBytes(destination: []u8, source: []const u8) void {
    std.debug.assert(destination.len == source.len);
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        if (destination.len >= @max(64, @atomicLoad(usize, &rep_copy_min_bytes, .monotonic)) and @atomicLoad(bool, &rep_large_copies, .monotonic)) {
            var dst = destination.ptr;
            var src = source.ptr;
            var remaining = destination.len;
            asm volatile ("rep movsb"
                : [dst] "={rdi}" (dst),
                  [src] "={rsi}" (src),
                  [remaining] "={rcx}" (remaining),
                : [destination] "0" (dst),
                  [source] "1" (src),
                  [length] "2" (remaining),
                : .{ .memory = true });
            return;
        }
    }
    @memcpy(destination, source);
}

/// Fingerprint every byte using the same partitioning regardless of the pool's
/// worker count. Embeddings use this for both guest memory and copied snapshots.
pub fn fingerprint(source: []const u8) u64 {
    return guest_copy_pool.fingerprint(source);
}

// These digests compare live guest storage with copied snapshots, not files on
// disk. Keep one immutable policy for every caller and helper: changing it while
// resources are resident would make unchanged content appear modified.
pub const vector_hash_minimum_bytes = 1024;

fn contentHash(source: []const u8) u64 {
    // XXH3's vectorized long-input path amortizes its setup on larger ranges.
    // Short descriptors retain Wyhash; both paths inspect the complete span.
    return if (source.len < vector_hash_minimum_bytes) std.hash.Wyhash.hash(0, source) else std.hash.XxHash3.hash(0, source);
}

/// Streaming digest for one contiguous span, using its complete length to choose
/// the algorithm. Matches fingerprint below Pool.minimum_bytes; larger pooled
/// fingerprints combine four independently hashed spans instead.
pub const SpanHasher = union(enum) {
    short: std.hash.Wyhash,
    long: std.hash.XxHash3,

    pub fn init(total_bytes: usize) SpanHasher {
        return if (total_bytes < vector_hash_minimum_bytes) .{ .short = .init(0) } else .{ .long = .init(0) };
    }

    pub fn update(self: *SpanHasher, bytes: []const u8) void {
        switch (self.*) {
            inline else => |*hasher| hasher.update(bytes),
        }
    }

    pub fn final(self: *SpanHasher) u64 {
        return switch (self.*) {
            inline else => |*hasher| hasher.final(),
        };
    }
};

test "streamed span hashes match complete content across chunk and algorithm boundaries" {
    var bytes: [16385]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% (i >> 4));
    for ([_]usize{ 0, 63, 1023, 1024, 1025, 4097, bytes.len }) |length| {
        for ([_]usize{ 1, 63, 256, 1023, 4096 }) |chunk| {
            var hash = SpanHasher.init(length);
            hash.update(&.{});
            var offset: usize = 0;
            while (offset < length) {
                const end = @min(length, offset + chunk);
                hash.update(bytes[offset..end]);
                offset = end;
            }
            try std.testing.expectEqual(contentHash(bytes[0..length]), hash.final());
        }
    }
}

/// Synchronous copies with a bounded set of sleeping helper threads. The caller
/// copies one partition and joins the others before returning. The pool must
/// remain at a stable address after its first large copy.
pub const Pool = struct {
    pub const minimum_bytes = 4 * 1024 * 1024;
    pub const maximum_participants = 4;

    participants: std.atomic.Value(u8) = .init(1),
    lock: std.atomic.Mutex = .unlocked,
    threaded: ?std.Io.Threaded = null,
    workers: [maximum_participants - 1]Worker = @splat(.{}),
    worker_count: usize = 0,
    start_failed: bool = false,

    pub const RangeFunction = *const fn (*anyopaque, usize, usize, usize) void;
    const RangeTask = struct {
        context: *anyopaque,
        function: RangeFunction,
        first: usize,
        end: usize,
        participant: usize,
    };

    const Worker = struct {
        thread: ?std.Thread = null,
        ready: std.Io.Event = .unset,
        complete: std.Io.Event = .unset,
        stop: bool = false,
        destination: []u8 = &.{},
        source: []const u8 = &.{},
        hashes: ?*[maximum_participants]u64 = null,
        first_hash: usize = 0,
        end_hash: usize = 0,
        range_task: ?RangeTask = null,

        fn run(self: *Worker, io: std.Io) void {
            while (true) {
                self.ready.waitUncancelable(io);
                self.ready.reset();
                if (self.stop) return;
                if (self.range_task) |task| {
                    task.function(task.context, task.first, task.end, task.participant);
                } else if (self.hashes) |hashes| {
                    hashPartitions(self.source, hashes, self.first_hash, self.end_hash);
                } else {
                    copyBytes(self.destination, self.source);
                }
                self.complete.set(io);
            }
        }
    };

    /// Same non-overlap contract as @memcpy. Busy/reentrant calls, small ranges
    /// and worker creation failures retain a synchronous inline fallback.
    pub fn copy(self: *Pool, destination: []u8, source: []const u8) void {
        std.debug.assert(destination.len == source.len);
        const participants = self.participants.load(.acquire);
        if (builtin.single_threaded or participants <= 1 or
            destination.len < minimum_bytes or !self.lock.tryLock())
        {
            copyBytes(destination, source);
            return;
        }
        defer self.lock.unlock();
        const count = self.prepareWorkers(participants);
        const io = self.threaded.?.io();
        // Align internal boundaries to destination cache lines. Arbitrarily
        // aligned callers and the final partial line remain supported.
        const stride = std.mem.alignBackward(usize, destination.len / (count + 1), 64);
        const adjustment = @intFromPtr(destination.ptr) % 64;
        var offset: usize = 0;
        for (self.workers[0..count], 0..) |*worker, index| {
            const end = stride * (index + 1) - adjustment;
            worker.destination = destination[offset..end];
            worker.source = source[offset..end];
            worker.hashes = null;
            worker.ready.set(io);
            offset = end;
        }
        copyBytes(destination[offset..], source[offset..]);
        self.joinWorkers(count);
    }

    /// Large ranges use four fixed contiguous partitions, each hashed in full.
    /// Worker count, address alignment and a busy/unavailable pool cannot change
    /// the digest. No source bytes or snapshot allocations survive the call.
    pub fn fingerprint(self: *Pool, source: []const u8) u64 {
        if (source.len < minimum_bytes) return contentHash(source);
        var hashes: [maximum_participants]u64 = undefined;
        const participants = self.participants.load(.acquire);
        if (builtin.single_threaded or participants <= 1 or !self.lock.tryLock()) {
            hashPartitions(source, &hashes, 0, maximum_participants);
        } else {
            defer self.lock.unlock();
            const count = self.prepareWorkers(participants);
            const io = self.threaded.?.io();
            var first: usize = 0;
            for (self.workers[0..count], 0..) |*worker, index| {
                const end = maximum_participants * (index + 1) / (count + 1);
                worker.source = source;
                worker.hashes = &hashes;
                worker.first_hash = first;
                worker.end_hash = end;
                worker.ready.set(io);
                first = end;
            }
            hashPartitions(source, &hashes, first, maximum_participants);
            self.joinWorkers(count);
        }
        // Include range length and partition order in a portable final digest.
        var digest: [(maximum_participants + 1) * 8]u8 = undefined;
        std.mem.writeInt(u64, digest[0..8], source.len, .little);
        for (hashes, 0..) |hash, index|
            std.mem.writeInt(u64, digest[(index + 1) * 8 ..][0..8], hash, .little);
        return std.hash.Wyhash.hash(0, &digest);
    }

    /// Synchronously partition independent work across the same copy helpers.
    /// Each callback owns [first, end) and its participant's result slot. A
    /// nested/busy call runs inline; no callback or context survives return.
    pub fn forRanges(self: *Pool, units: usize, context: *anyopaque, function: RangeFunction) void {
        if (units == 0) return;
        const participants: u8 = @intCast(@min(units, self.participants.load(.acquire)));
        if (builtin.single_threaded or participants <= 1 or !self.lock.tryLock()) {
            function(context, 0, units, 0);
            return;
        }
        defer self.lock.unlock();
        const count = self.prepareWorkers(participants);
        const io = self.threaded.?.io();
        var first: usize = 0;
        for (self.workers[0..count], 0..) |*worker, index| {
            const end = units / (count + 1) * (index + 1);
            worker.range_task = .{ .context = context, .function = function, .first = first, .end = end, .participant = index };
            worker.ready.set(io);
            first = end;
        }
        function(context, first, units, count);
        self.joinWorkers(count);
    }

    fn hashPartitions(source: []const u8, hashes: *[maximum_participants]u64, first: usize, end: usize) void {
        const stride = std.mem.alignBackward(usize, source.len / maximum_participants, 64);
        for (first..end) |index| {
            const limit = if (index + 1 == maximum_participants) source.len else stride * (index + 1);
            hashes[index] = contentHash(source[stride * index .. limit]);
        }
    }

    /// Called with the pool lock held; partial worker creation is usable too.
    fn prepareWorkers(self: *Pool, participants: u8) usize {
        const wanted = @min(participants, maximum_participants) - 1;
        if (self.threaded == null) self.threaded = .init(std.heap.page_allocator, .{});
        const io = self.threaded.?.io();
        while (self.worker_count < wanted and !self.start_failed) {
            const worker = &self.workers[self.worker_count];
            worker.thread = std.Thread.spawn(.{}, Worker.run, .{ worker, io }) catch {
                self.start_failed = true;
                break;
            };
            self.worker_count += 1;
        }
        return @min(self.worker_count, wanted);
    }

    fn joinWorkers(self: *Pool, count: usize) void {
        const io = self.threaded.?.io();
        for (self.workers[0..count]) |*worker| {
            worker.complete.waitUncancelable(io);
            worker.complete.reset();
            worker.hashes = null;
            worker.source = &.{};
            worker.destination = &.{};
            worker.range_task = null;
        }
    }

    /// The owner must stop issuing copies before destruction.
    pub fn deinit(self: *Pool) void {
        while (!self.lock.tryLock()) std.Thread.yield() catch {};
        defer self.lock.unlock();
        if (self.threaded) |*threaded| {
            const io = threaded.io();
            for (self.workers[0..self.worker_count]) |*worker| {
                worker.stop = true;
                worker.ready.set(io);
            }
            for (self.workers[0..self.worker_count]) |*worker| worker.thread.?.join();
            threaded.deinit();
        }
        self.threaded = null;
        self.workers = @splat(.{});
        self.worker_count = 0;
        self.start_failed = false;
    }
};

test "host string copies preserve unaligned short and threshold boundaries" {
    const saved = rep_copy_min_bytes;
    const enabled = rep_large_copies;
    defer {
        rep_copy_min_bytes = saved;
        rep_large_copies = enabled;
    }
    rep_large_copies = true;
    var source: [8192 + 128]u8 = undefined;
    var destination: [8192 + 128]u8 = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% (i >> 7));
    for ([_]usize{ 0, 64, 256, 4096, std.math.maxInt(usize) }) |minimum| {
        rep_copy_min_bytes = minimum;
        for ([_]usize{ 0, 1, 15, 31, 63 }) |alignment| {
            for ([_]usize{ 0, 1, 63, 64, 65, 255, 256, 257, 4095, 4096, 4097, 8192 }) |length| {
                @memset(&destination, 0x7d);
                copyBytes(destination[alignment..][0..length], source[63 - alignment ..][0..length]);
                try std.testing.expectEqualSlices(u8, source[63 - alignment ..][0..length], destination[alignment..][0..length]);
                try std.testing.expect(std.mem.allEqual(u8, destination[0..alignment], 0x7d));
                try std.testing.expect(std.mem.allEqual(u8, destination[alignment + length ..], 0x7d));
            }
        }
    }
}

test "long host copies preserve exact boundaries for each worker count" {
    const saved = rep_large_copies;
    defer rep_large_copies = saved;
    const a = std.testing.allocator;
    const maximum = 12 * 1024 * 1024 + 7;
    const source = try a.alloc(u8, maximum + 128);
    defer a.free(source);
    const destination = try a.alloc(u8, maximum + 128);
    defer a.free(destination);
    for (source, 0..) |*byte, index| byte.* = @truncate(index *% 17 +% 3);
    var pool = Pool{};
    defer pool.deinit();
    for ([_]bool{ false, true }) |enabled| {
        rep_large_copies = enabled;
        for (1..5) |participants| {
            pool.participants.store(@intCast(participants), .release);
            for ([_]usize{ 0, 1, 15, 31, 63 }) |alignment| {
                for ([_]usize{ 0, 31, 2 * 1024 * 1024 - 1, 2 * 1024 * 1024, 2 * 1024 * 1024 + 1, maximum }) |length| {
                    const source_offset = 63 - alignment;
                    @memset(destination[0 .. alignment + length + 64], 0x7d);
                    pool.copy(destination[alignment..][0..length], source[source_offset..][0..length]);
                    try std.testing.expectEqualSlices(u8, source[source_offset..][0..length], destination[alignment..][0..length]);
                    try std.testing.expect(std.mem.allEqual(u8, destination[0..alignment], 0x7d));
                    try std.testing.expect(std.mem.allEqual(u8, destination[alignment + length ..][0..64], 0x7d));
                }
            }
        }
    }
}

test "parallel copies join before return and preserve unaligned boundaries" {
    var pool = Pool{ .participants = .init(4) };
    defer pool.deinit();
    const allocator = std.testing.allocator;
    const size = Pool.minimum_bytes + 513;
    const source = try allocator.alloc(u8, size + 128);
    defer allocator.free(source);
    const destination = try allocator.alloc(u8, size + 128);
    defer allocator.free(destination);
    for (source, 0..) |*byte, index| byte.* = @truncate(index *% 17 +% (index >> 9));
    for ([_]usize{ 0, 1, 31, 63, 97 }) |offset| {
        @memset(destination, 0xc3);
        pool.copy(destination[offset..][0..size], source[3..][0..size]);
        try std.testing.expectEqualSlices(u8, source[3..][0..size], destination[offset..][0..size]);
        try std.testing.expect(std.mem.allEqual(u8, destination[0..offset], 0xc3));
        try std.testing.expect(std.mem.allEqual(u8, destination[offset + size ..], 0xc3));
    }
    // A busy pool must not wait for its caller or overwrite in-flight jobs.
    try std.testing.expect(pool.lock.tryLock());
    pool.copy(destination[0..size], source[0..size]);
    pool.lock.unlock();
    try std.testing.expectEqualSlices(u8, source[0..size], destination[0..size]);
    pool.deinit();
    pool.copy(destination[0..size], source[0..size]);
    try std.testing.expectEqualSlices(u8, source[0..size], destination[0..size]);
}

test "range transforms join disjoint partitions and allow nested pool operations" {
    const Work = struct {
        pool: *Pool,
        values: [37]u32 = @splat(0),
        calls: [Pool.maximum_participants]usize = @splat(0),
        fn run(raw: *anyopaque, first: usize, end: usize, participant: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls[participant] += 1;
            var nested: [2]u32 = @splat(0);
            self.pool.forRanges(nested.len, &nested, fillNested);
            for (first..end) |i| self.values[i] += @as(u32, @intCast(i)) + nested[0] + nested[1];
        }
        fn fillNested(raw: *anyopaque, first: usize, end: usize, _: usize) void {
            const values: *[2]u32 = @ptrCast(@alignCast(raw));
            for (first..end) |i| values[i] += 0x2d;
        }
    };
    var pool = Pool{ .participants = .init(4) };
    defer pool.deinit();
    const source = try std.testing.allocator.alloc(u8, Pool.minimum_bytes + 17);
    defer std.testing.allocator.free(source);
    const destination = try std.testing.allocator.alloc(u8, source.len);
    defer std.testing.allocator.free(destination);
    for (source, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% (i >> 9));
    var serial = Pool{};
    defer serial.deinit();
    const expected_hash = serial.fingerprint(source);
    for ([_]bool{ false, true }) |busy| {
        var work = Work{ .pool = &pool };
        if (busy) try std.testing.expect(pool.lock.tryLock());
        pool.forRanges(work.values.len, &work, Work.run);
        if (busy) pool.lock.unlock();
        for (work.values, 0..) |value, i| try std.testing.expectEqual(@as(u32, @intCast(i)) + 0x5a, value);
        try std.testing.expectEqual(@as(usize, if (busy) 1 else 4), @reduce(.Add, @as(@Vector(4, usize), work.calls)));
        // A following ordinary job must not call the retained transform again.
        pool.copy(destination, source);
        try std.testing.expectEqualSlices(u8, source, destination);
        try std.testing.expectEqual(expected_hash, pool.fingerprint(destination));
    }
}

test "parallel copy concurrent callers and unavailable workers preserve every byte" {
    var pool = Pool{ .participants = .init(4) };
    defer pool.deinit();
    const Work = struct {
        pool: *Pool,
        bytes: []u8,
        source: []const u8,
        fn run(self: @This()) void {
            for (0..12) |_| self.pool.copy(self.bytes, self.source);
        }
    };
    const size = Pool.minimum_bytes + 7;
    const source = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(source);
    const destination = try std.testing.allocator.alloc(u8, 3 * size);
    defer std.testing.allocator.free(destination);
    for (source, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% (i >> 13));
    @memset(destination, 0);
    var threads: [3]std.Thread = undefined;
    var started: usize = 0;
    {
        defer for (threads[0..started]) |thread| thread.join();
        for (&threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, Work.run, .{Work{ .pool = &pool, .bytes = destination[i * size ..][0..size], .source = source }});
            started += 1;
        }
    }
    for (0..3) |i| try std.testing.expectEqualSlices(u8, source, destination[i * size ..][0..size]);
    pool.deinit();
    pool.start_failed = true;
    @memset(destination, 0);
    pool.copy(destination[0..size], source);
    try std.testing.expectEqualSlices(u8, source, destination[0..size]);
    try std.testing.expectEqual(@as(usize, 0), pool.worker_count);
}

test "buffer fingerprints cover partitions and ignore alignment worker count and fallback" {
    var pool = Pool{};
    defer pool.deinit();
    const storage = try std.testing.allocator.alloc(u8, Pool.minimum_bytes * 2 + 2048);
    defer std.testing.allocator.free(storage);
    for (storage, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% (i >> 13));
    const lengths = [_]usize{ 0, 63, 1023, 1024, 1025, Pool.minimum_bytes - 1, Pool.minimum_bytes, Pool.minimum_bytes + 513 };
    for (lengths) |length| {
        const source = storage[3..][0..length];
        pool.participants.store(1, .release);
        const expected = pool.fingerprint(source);
        if (length < Pool.minimum_bytes) try std.testing.expectEqual(if (length < 1024) std.hash.Wyhash.hash(0, source) else std.hash.XxHash3.hash(0, source), expected);
        for ([_]u8{ 2, 4, 3, 1 }) |count| {
            pool.participants.store(count, .release);
            try std.testing.expectEqual(expected, pool.fingerprint(source));
        }
        pool.participants.store(4, .release);
        try std.testing.expect(pool.lock.tryLock());
        const busy = pool.fingerprint(source);
        pool.lock.unlock();
        try std.testing.expectEqual(expected, busy);
        // Identical bytes at a different alignment still describe one buffer.
        const relocated = storage[Pool.minimum_bytes + 1024 ..][0..length];
        @memcpy(relocated, source);
        try std.testing.expectEqual(expected, pool.fingerprint(relocated));
        if (length >= Pool.minimum_bytes) {
            const stride = std.mem.alignBackward(usize, length / 4, 64);
            for ([_]usize{ 0, stride - 1, stride, 2 * stride, 3 * stride, length - 1 }) |index| {
                source[index] ^= 0x80;
                try std.testing.expect(pool.fingerprint(source) != expected);
                source[index] ^= 0x80;
            }
        }
        pool.deinit();
        pool.start_failed = true;
        try std.testing.expectEqual(expected, pool.fingerprint(source));
        pool.deinit();
        try std.testing.expectEqual(expected, pool.fingerprint(source));
    }
}

test "content fingerprints cover every byte across the vector threshold and alignments" {
    var bytes: [4097 + 64]u8 = undefined;
    var relocated: [4097 + 64]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i *% 73 +% (i >> 3));
    for ([_]usize{ 1, 63, 1023, 1024, 1025, 4097 }) |length| {
        const source = bytes[3..][0..length];
        const expected = contentHash(source);
        for (source) |*byte| {
            byte.* ^= 0x80;
            try std.testing.expect(contentHash(source) != expected);
            byte.* ^= 0x80;
        }
        for (0..64) |alignment| {
            @memcpy(relocated[alignment..][0..length], source);
            try std.testing.expectEqual(expected, contentHash(relocated[alignment..][0..length]));
        }
    }
}

test "parallel copies and fingerprints share workers without mixing jobs" {
    var pool = Pool{ .participants = .init(4) };
    defer pool.deinit();
    const size = Pool.minimum_bytes + 37;
    const source = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(source);
    const destination = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(destination);
    for (source, 0..) |*byte, i| byte.* = @truncate(i *% 13 +% (i >> 7));
    const expected = pool.fingerprint(source);
    const Work = struct {
        fn run(shared: *Pool, output: []u8, input: []const u8) void {
            for (0..16) |_| shared.copy(output, input);
        }
    };
    {
        const thread = try std.Thread.spawn(.{}, Work.run, .{ &pool, destination, source });
        defer thread.join();
        for (0..16) |_| try std.testing.expectEqual(expected, pool.fingerprint(source));
    }
    try std.testing.expectEqualSlices(u8, source, destination);
}
