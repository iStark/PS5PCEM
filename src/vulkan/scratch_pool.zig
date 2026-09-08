// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");

/// CPU-only temporary storage. Leases are removed from the pool until released,
/// so nested image preparation cannot overwrite another operation's bytes.
/// All calls on one pool must use the same allocator and renderer thread.
pub const Pool = struct {
    pub const minimum_bytes = 64 * 1024;
    pub const maximum_entry_bytes = 64 * 1024 * 1024;
    pub const maximum_retained_bytes = 2 * maximum_entry_bytes;

    entries: [2][]u8 = @splat(&.{}),
    enabled: bool = true,

    pub const Lease = struct {
        bytes: []u8,
        allocation: []u8,
        pool: *Pool,
        allocator: std.mem.Allocator,
        cacheable: bool,

        pub fn release(self: *Lease) void {
            const allocation = self.allocation;
            if (self.cacheable and self.pool.enabled) {
                var smallest: usize = 0;
                for (self.pool.entries, 0..) |entry, index| {
                    if (entry.len < self.pool.entries[smallest].len) smallest = index;
                }
                if (allocation.len > self.pool.entries[smallest].len) {
                    self.allocator.free(self.pool.entries[smallest]);
                    self.pool.entries[smallest] = allocation;
                    self.* = undefined;
                    return;
                }
            }
            self.allocator.free(allocation);
            self.* = undefined;
        }
    };

    pub fn acquire(self: *Pool, allocator: std.mem.Allocator, size: usize) !Lease {
        const cacheable = self.enabled and size >= minimum_bytes and size <= maximum_entry_bytes;
        if (cacheable) {
            var best: ?usize = null;
            for (self.entries, 0..) |entry, index| {
                if (entry.len >= size and (best == null or entry.len < self.entries[best.?].len)) best = index;
            }
            if (best) |index| {
                const allocation = self.entries[index];
                self.entries[index] = &.{};
                return .{ .bytes = allocation[0..size], .allocation = allocation, .pool = self, .allocator = allocator, .cacheable = true };
            }
        }
        // Avoid doubling commitment for a surface just above a power of two.
        const capacity = if (cacheable) std.mem.alignForward(usize, size, minimum_bytes) else size;
        const allocation = try allocator.alloc(u8, capacity);
        return .{ .bytes = allocation[0..size], .allocation = allocation, .pool = self, .allocator = allocator, .cacheable = cacheable };
    }

    pub fn deinit(self: *Pool, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            allocator.free(entry.*);
            entry.* = &.{};
        }
    }
};

test "image scratch leases remain distinct across nested acquisition and error cleanup" {
    var pool = Pool{};
    defer pool.deinit(std.testing.allocator);
    var first = try pool.acquire(std.testing.allocator, Pool.minimum_bytes + 3);
    @memset(first.bytes, 0x35);
    const capacity = first.allocation.len;
    const address = first.bytes.ptr;
    first.release();
    var reused = try pool.acquire(std.testing.allocator, Pool.minimum_bytes);
    defer reused.release();
    try std.testing.expectEqual(address, reused.bytes.ptr);
    try std.testing.expectEqual(capacity, reused.allocation.len);
    const nested = struct {
        fn run(p: *Pool) !void {
            var lease = try p.acquire(std.testing.allocator, Pool.minimum_bytes);
            defer lease.release();
            @memset(lease.bytes, 0x7a);
            return error.SyntheticReadFailure;
        }
    };
    try std.testing.expectError(error.SyntheticReadFailure, nested.run(&pool));
    try std.testing.expect(std.mem.allEqual(u8, reused.bytes, 0x35));
}

test "image scratch retention is bounded and disabling it preserves outstanding leases" {
    var pool = Pool{};
    defer pool.deinit(std.testing.allocator);
    var leases: [3]Pool.Lease = undefined;
    for (&leases, 0..) |*lease, index| lease.* = try pool.acquire(std.testing.allocator, Pool.minimum_bytes * (index + 1));
    for (&leases) |*lease| lease.release();
    const retained = pool.entries[0].len + pool.entries[1].len;
    try std.testing.expectEqual(5 * Pool.minimum_bytes, retained);
    try std.testing.expect(retained <= Pool.maximum_retained_bytes);
    var outstanding = try pool.acquire(std.testing.allocator, Pool.minimum_bytes);
    pool.enabled = false;
    var transient = try pool.acquire(std.testing.allocator, Pool.minimum_bytes);
    try std.testing.expect(!transient.cacheable);
    try std.testing.expect(outstanding.bytes.ptr != transient.bytes.ptr);
    transient.release();
    outstanding.release();
    pool.enabled = true;
    var small = try pool.acquire(std.testing.allocator, 3);
    try std.testing.expect(!small.cacheable);
    small.release();
    var oversized = try pool.acquire(std.testing.allocator, Pool.maximum_entry_bytes + 1);
    try std.testing.expect(!oversized.cacheable);
    oversized.release();
}
