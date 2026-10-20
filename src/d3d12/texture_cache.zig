// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Immutable sampled-image snapshots. A nonzero, armed page generation proves
//! an unchanged source; otherwise compare a fresh complete read. Active leases
//! survive cache eviction and source mutation until their GPU batch completes.
const std = @import("std");
const gpu = @import("gpu");

pub const Tracking = struct {
    context: ?*anyopaque = null,
    generation: ?*const fn (?*anyopaque, u64, usize) u64 = null,
    arm: ?*const fn (?*anyopaque, u64, usize) u64 = null,
    fn current(self: Tracking, address: u64, size: usize) u64 {
        return if (self.generation) |callback| callback(self.context, address, size) else 0;
    }
};

const Entry = struct {
    allocator: std.mem.Allocator,
    address: u64,
    layout: gpu.SurfaceLayout,
    backing: []u8,
    pixels: []u8,
    generation: u64,
    refs: usize = 1,
    stamp: u64 = 0,
    fn release(self: *Entry) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const allocator = self.allocator;
        allocator.free(self.backing);
        allocator.free(self.pixels);
        allocator.destroy(self);
    }
};

pub const Lease = struct {
    entry: *Entry,
    pub fn pixels(self: Lease) []const u8 {
        return self.entry.pixels;
    }
    pub fn release(self: Lease) void {
        self.entry.release();
    }
};

pub const Cache = struct {
    entries: [128]?*Entry = @splat(null),
    limit: usize = 128 * 1024 * 1024,
    bytes: usize = 0,
    clock: u64 = 0,
    page_hits: u64 = 0,
    content_hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*slot| self.remove(slot);
    }
    fn remove(self: *Cache, slot: *?*Entry) void {
        if (slot.*) |entry| {
            self.bytes -= entry.backing.len + entry.pixels.len;
            entry.release();
            slot.* = null;
        }
    }
    fn retain(self: *Cache, entry: *Entry) Lease {
        self.clock +|= 1;
        entry.stamp = self.clock;
        entry.refs += 1;
        return .{ .entry = entry };
    }

    pub fn acquire(self: *Cache, allocator: std.mem.Allocator, reader: gpu.ShaderMemoryReader, tracking: Tracking, address: u64, layout: gpu.SurfaceLayout) !Lease {
        const size: usize = @intCast(layout.required_source_bytes);
        _ = try layout.sourceRange(address);
        var matched: ?*?*Entry = null;
        if (self.limit != 0) for (&self.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (entry.address == address and std.meta.eql(entry.layout, layout)) {
                matched = slot;
                const generation = tracking.current(address, size);
                if (entry.generation != 0 and generation == entry.generation) {
                    self.page_hits += 1;
                    return self.retain(entry);
                }
                break;
            }
        };
        // Arm before reading, and only accept a stable generation afterwards.
        // Zero means unwatched/dirty/unsupported, never an unchanged-content proof.
        const before = if (tracking.arm) |arm| arm(tracking.context, address, size) else 0;
        const backing = try allocator.alloc(u8, size);
        var own_backing = true;
        defer if (own_backing) allocator.free(backing);
        try reader.read(address, backing);
        const after = tracking.current(address, size);
        const generation = if (before != 0 and before == after) after else 0;
        if (matched) |slot| {
            const entry = slot.*.?;
            if (std.mem.eql(u8, entry.backing, backing)) {
                entry.generation = generation;
                self.content_hits += 1;
                return self.retain(entry);
            }
        }
        self.misses += 1;
        const pixels = try allocator.alloc(u8, @intCast(layout.staging_bytes));
        errdefer allocator.free(pixels);
        try layout.detile(backing, pixels);
        const entry = try allocator.create(Entry);
        entry.* = .{ .allocator = allocator, .address = address, .layout = layout, .backing = backing, .pixels = pixels, .generation = generation };
        own_backing = false;
        const cost = backing.len + pixels.len;
        if (cost <= self.limit) {
            if (matched) |slot| self.remove(slot);
            while (true) {
                var empty: ?*?*Entry = null;
                var oldest: ?*?*Entry = null;
                for (&self.entries) |*slot| {
                    if (slot.*) |candidate| {
                        if (oldest == null or candidate.stamp < oldest.?.*.?.stamp) oldest = slot;
                    } else empty = slot;
                }
                if (empty != null and self.bytes <= self.limit - cost) {
                    empty.?.* = entry;
                    self.bytes += cost;
                    return self.retain(entry);
                }
                self.remove(oldest.?);
                self.evictions += 1;
            }
        }
        return .{ .entry = entry };
    }
};

test "sampled snapshots detect writes, retain pinned versions and reject unstable page proofs" {
    const Memory = struct {
        data: [16]u8 = @splat(0x31),
        generation: u64 = 1,
        reads: usize = 0,
        fail: bool = false,
        race: bool = false,
        fn read(context: ?*anyopaque, _: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.reads += 1;
            if (self.fail or bytes.len != self.data.len) return false;
            @memcpy(bytes, &self.data);
            if (self.race) self.generation += 1;
            return true;
        }
        fn stamp(context: ?*anyopaque, _: u64, _: usize) u64 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.generation;
        }
    };
    var memory = Memory{};
    const reader = gpu.ShaderMemoryReader{ .context = &memory, .read_fn = Memory.read };
    const tracking = Tracking{ .context = &memory, .generation = Memory.stamp, .arm = Memory.stamp };
    const layout = try gpu.SurfaceLayout.init(.{ .tile_mode = .linear, .width = 2, .height = 2 }, 4);
    var cache = Cache{ .limit = 32 };
    defer cache.deinit();
    const first = try cache.acquire(std.testing.allocator, reader, tracking, 0x1000, layout);
    defer first.release();
    const hit = try cache.acquire(std.testing.allocator, reader, tracking, 0x1000, layout);
    hit.release();
    try std.testing.expectEqual(@as(usize, 1), memory.reads);
    memory.generation += 1;
    memory.data[15] ^= 0xff;
    const changed = try cache.acquire(std.testing.allocator, reader, tracking, 0x1000, layout);
    defer changed.release();
    try std.testing.expectEqual(@as(u8, 0x31), first.pixels()[15]);
    try std.testing.expectEqual(memory.data[15], changed.pixels()[15]);
    memory.generation = 0; // Unwatched pages need fresh reads even on equal bytes.
    const equal = try cache.acquire(std.testing.allocator, reader, tracking, 0x1000, layout);
    try std.testing.expectEqual(changed.entry, equal.entry);
    equal.release();
    memory.fail = true;
    try std.testing.expectError(error.MemoryReadFailed, cache.acquire(std.testing.allocator, reader, tracking, 0x1000, layout));
    memory.fail = false;
    memory.generation = 7;
    memory.race = true;
    const unstable = try cache.acquire(std.testing.allocator, reader, tracking, 0x1000, layout);
    unstable.release();
    try std.testing.expectEqual(@as(u64, 0), changed.entry.generation);
    memory.race = false;
    const evict = try cache.acquire(std.testing.allocator, reader, .{}, 0x2000, layout);
    evict.release();
    try std.testing.expectEqual(@as(u64, 1), cache.evictions);
    cache.deinit();
    try std.testing.expectEqual(memory.data[15], changed.pixels()[15]);
}
