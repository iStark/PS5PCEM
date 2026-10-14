// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bounded page-generation snapshots for large, clean resident buffers.
//! A generation is useful only while the pages remain write-watched. Callers
//! validate the complete source generation before and after copying bytes.
const std = @import("std");
const ranges = @import("buffer_write_ranges.zig");

pub const chunk_bytes = 256 * 1024;
pub const minimum_bytes = 4 * 1024 * 1024;
pub const maximum_chunks = 256;
pub const Key = struct {
    address: u64,
    size: usize,
    buffer: u64,
    content_epoch: u64,
    page_generation: u64,
};
pub const Snapshot = struct {
    key: Key = .{ .address = 0, .size = 0, .buffer = 0, .content_epoch = 0, .page_generation = 0 },
    generations: [maximum_chunks]u64 = @splat(0),
    pending_gpu: bool = false,
};
pub const Cache = struct {
    entries: [64]Snapshot = @splat(.{}),
    next: usize = 0,

    fn resident(self: *Cache, key: Key) ?*Snapshot {
        for (&self.entries) |*entry| {
            // Sparse publication clears the whole-buffer observation. The
            // unchanged chunks still have their own independent page proofs.
            var observed = key;
            observed.page_generation = entry.key.page_generation;
            if (std.meta.eql(entry.key, observed)) return entry;
        }
        return null;
    }

    pub fn find(self: *Cache, key: Key) ?*const Snapshot {
        const snapshot = self.resident(key) orelse return null;
        return if (snapshot.pending_gpu) null else snapshot;
    }

    pub fn beginGpuWrite(self: *Cache, before: Key, after: Key) void {
        const snapshot = self.resident(before) orelse return;
        snapshot.key = after;
        snapshot.pending_gpu = true;
    }

    pub fn publishGpuWrites(self: *Cache, key: Key, spans: []const ranges.Span, complete: bool) void {
        const snapshot = self.resident(key) orelse return;
        const chunks = count(key.size) orelse return;
        // Only the completed write footprint is authoritative. Unknown or
        // clipped bytes in every touched chunk are reloaded from guest RAM;
        // no readback scratch bytes certify the untouched parts of a chunk.
        for (spans) |span| {
            if (span.first >= span.end) continue;
            const first = @min(span.first / chunk_bytes, chunks);
            const end = @min((span.end - 1) / chunk_bytes + 1, chunks);
            @memset(snapshot.generations[first..end], 0);
        }
        snapshot.pending_gpu = !complete;
    }

    pub fn remember(self: *Cache, snapshot: *const Snapshot) void {
        for (&self.entries) |*entry| {
            if (entry.key.address == snapshot.key.address and entry.key.size == snapshot.key.size) {
                entry.* = snapshot.*;
                return;
            }
        }
        self.entries[self.next] = snapshot.*;
        self.next = (self.next + 1) % self.entries.len;
    }
};

pub fn count(size: usize) ?usize {
    if (size < minimum_bytes or size > maximum_chunks * chunk_bytes or size % 4 != 0) return null;
    return std.math.divCeil(usize, size, chunk_bytes) catch unreachable;
}

pub fn changes(before: []const u64, after: []const u64, size: usize) ?ranges.Ranges {
    if (before.len != after.len or before.len != (count(size) orelse return null)) return null;
    var changed = ranges.Ranges{};
    for (before, after, 0..) |old, new, index| {
        if (new == 0) return null;
        if (old == 0 or old != new) changed.include(.{ .first = index * chunk_bytes, .end = @min((index + 1) * chunk_bytes, size) });
    }
    return if (changed.whole) null else changed;
}

test "partial upload keeps clean gaps and includes an exact trailing chunk" {
    const size = minimum_bytes + 4;
    var before: [17]u64 = @splat(1);
    var after = before;
    after[1] = 2;
    after[2] = 3;
    after[16] = 4;
    const result = changes(&before, &after, size).?;
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(ranges.Span{ .first = chunk_bytes, .end = 3 * chunk_bytes }, result.spans[0]);
    try std.testing.expectEqual(ranges.Span{ .first = 16 * chunk_bytes, .end = size }, result.spans[1]);
    after[0] = 0;
    try std.testing.expect(changes(&before, &after, size) == null);
    after[0] = 1;
    before[3] = 0;
    try std.testing.expectEqual(@as(usize, 4 * chunk_bytes), changes(&before, &after, size).?.spans[0].end);
}

test "fragmented updates fall back and backing or content changes reject old snapshots" {
    const before: [18]u64 = @splat(1);
    var after = before;
    for (0..9) |i| after[i * 2] = 2;
    try std.testing.expect(changes(&before, &after, 18 * chunk_bytes) == null);
    var cache = Cache{};
    const key = Key{ .address = 0x10000, .size = minimum_bytes, .buffer = 7, .content_epoch = 42, .page_generation = 3 };
    cache.remember(&.{ .key = key });
    try std.testing.expect(cache.find(key) != null);
    inline for (.{ "buffer", "content_epoch", "address", "size" }) |field| {
        var changed_key = key;
        @field(changed_key, field) += 1;
        try std.testing.expect(cache.find(changed_key) == null);
    }
}

test "GPU publications retain untouched chunk proofs across sparse and overlapping writes" {
    var cache = Cache{};
    var key = Key{ .address = 0x10000, .size = minimum_bytes, .buffer = 7, .content_epoch = 42, .page_generation = 3 };
    var snapshot = Snapshot{ .key = key, .generations = @splat(3) };
    cache.remember(&snapshot);
    var next = key;
    next.content_epoch += 1;
    cache.beginGpuWrite(key, next);
    key = next;
    try std.testing.expect(cache.find(key) == null);
    cache.publishGpuWrites(key, &.{.{ .first = 12, .end = 16 }}, false);
    try std.testing.expect(cache.find(key) == null);
    next.content_epoch += 1;
    cache.beginGpuWrite(key, next);
    key = next;
    cache.publishGpuWrites(key, &.{.{ .first = 2 * chunk_bytes - 4, .end = 2 * chunk_bytes + 4 }}, true);
    key.page_generation = 0;
    const result = cache.find(key).?;
    const current: [16]u64 = @splat(3);
    const changed = changes(result.generations[0..16], &current, key.size).?;
    try std.testing.expectEqual(@as(usize, 1), changed.count);
    try std.testing.expectEqual(ranges.Span{ .first = 0, .end = 3 * chunk_bytes }, changed.spans[0]);
    // An unrelated content mutation cannot inherit the GPU-only proof.
    next.content_epoch += 1;
    cache.beginGpuWrite(next, key);
    try std.testing.expect(cache.find(next) == null);
}
