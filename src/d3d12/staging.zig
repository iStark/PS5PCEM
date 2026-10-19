// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Scratch storage for synchronous graphics staging. Leases never share bytes;
//! reused storage is uninitialized and callers must overwrite every logical byte.
//! This is not a guest-content cache. The renderer serializes all accesses.
const std = @import("std");

pub const Pool = struct {
    pub const default_limit = 256 * 1024 * 1024;
    // Eight draws can retain up to 96 independent input snapshots each.
    // Object slots scale with that lifetime; the byte budget is unchanged.
    pub const slot_count = 1024;
    const Entry = struct { bytes: []u8 = &.{}, busy: bool = false, stamp: u64 = 0 };
    allocator: std.mem.Allocator,
    limit: usize = default_limit,
    entries: [slot_count]Entry = @splat(.{}),
    bytes: usize = 0,
    clock: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    bypasses: u64 = 0,

    pub fn deinit(self: *Pool) void {
        for (self.entries) |entry| {
            std.debug.assert(!entry.busy);
            self.allocator.free(entry.bytes);
        }
        self.* = undefined;
    }

    pub fn acquire(self: *Pool, size: usize) std.mem.Allocator.Error!Lease {
        const capacity = std.math.ceilPowerOfTwo(usize, @max(256, size)) catch return error.OutOfMemory;
        for (&self.entries, 0..) |*entry, i| {
            if (!entry.busy and entry.bytes.len == capacity) {
                entry.busy = true;
                self.hits += 1;
                return .{ .allocator = self.allocator, .pool = self, .slot = i, .bytes = entry.bytes[0..size] };
            }
        }
        self.misses += 1;
        if (capacity <= self.limit) {
            while (true) {
                var empty: ?usize = null;
                var oldest: ?usize = null;
                for (self.entries, 0..) |entry, i| {
                    if (entry.busy) continue;
                    if (entry.bytes.len == 0) {
                        empty = i;
                    } else if (oldest == null or entry.stamp < self.entries[oldest.?].stamp) {
                        oldest = i;
                    }
                }
                if (empty != null and self.bytes <= self.limit - capacity) {
                    const storage = try self.allocator.alloc(u8, capacity);
                    self.entries[empty.?] = .{ .bytes = storage, .busy = true };
                    self.bytes += capacity;
                    return .{ .allocator = self.allocator, .pool = self, .slot = empty.?, .bytes = storage[0..size] };
                }
                const victim = oldest orelse break; // All remaining storage is leased.
                self.bytes -= self.entries[victim].bytes.len;
                self.allocator.free(self.entries[victim].bytes);
                self.entries[victim] = .{};
                self.evictions += 1;
            }
        }
        // Active or oversized allocations must still work. They are freed at
        // lease end and do not expand the retained-memory budget.
        self.bypasses += 1;
        return Lease.alloc(self.allocator, null, size);
    }
};

pub const Lease = struct {
    allocator: std.mem.Allocator,
    pool: ?*Pool = null,
    slot: usize = 0,
    bytes: []u8,

    pub fn alloc(allocator: std.mem.Allocator, pool: ?*Pool, size: usize) std.mem.Allocator.Error!Lease {
        if (pool) |p| return p.acquire(size);
        return .{ .allocator = allocator, .bytes = try allocator.alloc(u8, size) };
    }
    pub fn deinit(self: *Lease) void {
        if (self.pool) |pool| {
            const entry = &pool.entries[self.slot];
            std.debug.assert(entry.busy and entry.bytes.ptr == self.bytes.ptr);
            pool.clock +|= 1;
            entry.stamp = pool.clock;
            entry.busy = false;
        } else self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

test "staging leases reuse storage without clearing or aliasing active bytes" {
    var pool = Pool{ .allocator = std.testing.allocator, .limit = 1024 };
    defer pool.deinit();
    var a = try pool.acquire(257);
    @memset(a.bytes, 0x91);
    const original = a.bytes.ptr;
    var b = try pool.acquire(300);
    try std.testing.expect(a.bytes.ptr != b.bytes.ptr);
    @memset(b.bytes, 0x42);
    a.deinit();
    var c = try pool.acquire(257);
    try std.testing.expectEqual(original, c.bytes.ptr);
    try std.testing.expect(std.mem.allEqual(u8, c.bytes, 0x91));
    try std.testing.expect(std.mem.allEqual(u8, b.bytes, 0x42));
    c.deinit();
    b.deinit();
    try std.testing.expectEqual(@as(u64, 1), pool.hits);
    try std.testing.expectEqual(@as(usize, 1024), pool.bytes);
}

test "staging pressure evicts only idle leases and bypasses the retained budget" {
    var pool = Pool{ .allocator = std.testing.allocator, .limit = 512 };
    defer pool.deinit();
    var a = try pool.acquire(64);
    var b = try pool.acquire(128);
    @memset(b.bytes, 0x73);
    var active_bypass = try pool.acquire(256);
    try std.testing.expect(active_bypass.pool == null);
    active_bypass.deinit();
    a.deinit();
    var pressure = try pool.acquire(300);
    try std.testing.expect(pressure.pool == null);
    try std.testing.expect(std.mem.allEqual(u8, b.bytes, 0x73));
    pressure.deinit();
    b.deinit();
    var larger = try pool.acquire(400);
    try std.testing.expect(larger.pool != null);
    try std.testing.expectEqual(@as(u64, 2), pool.evictions);
    larger.deinit();
    var oversized = try pool.acquire(513);
    try std.testing.expect(oversized.pool == null);
    oversized.deinit();
    try std.testing.expectEqual(@as(usize, 512), pool.bytes);
    try std.testing.expectEqual(@as(u64, 3), pool.bypasses);
}

test "staging slot exhaustion never evicts live leases and zero budget disables retention" {
    var pool = Pool{ .allocator = std.testing.allocator };
    defer pool.deinit();
    var leases: [Pool.slot_count]Lease = undefined;
    for (&leases) |*lease| lease.* = try pool.acquire(1);
    var extra = try pool.acquire(1);
    try std.testing.expect(extra.pool == null);
    extra.deinit();
    for (&leases) |*lease| lease.deinit();
    var disabled = Pool{ .allocator = std.testing.allocator, .limit = 0 };
    defer disabled.deinit();
    var uncached = try disabled.acquire(1024);
    uncached.deinit();
    try std.testing.expectEqual(@as(usize, 0), disabled.bytes);
}

test "failed staging allocation does not publish an occupied slot" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var pool = Pool{ .allocator = failing.allocator() };
    defer pool.deinit();
    try std.testing.expectError(error.OutOfMemory, pool.acquire(257));
    try std.testing.expectEqual(@as(usize, 0), pool.bytes);
    for (pool.entries) |entry| try std.testing.expect(!entry.busy and entry.bytes.len == 0);
}
