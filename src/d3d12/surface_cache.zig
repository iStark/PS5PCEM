// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Memoized layout conversions, not guest-memory residency. Every lookup uses
//! a fresh guest snapshot and exact byte comparison. Cached bytes never escape
//! as writable views, so attachment writes cannot corrupt a retained pair.
const std = @import("std");
const gpu = @import("gpu");

pub const Cache = struct {
    pub const default_limit = 256 * 1024 * 1024;
    const Entry = struct {
        address: u64 = 0,
        layout: gpu.SurfaceLayout = undefined,
        backing: []u8 = &.{},
        pixels: []u8 = &.{},
        stamp: u64 = 0,
    };
    allocator: std.mem.Allocator,
    limit: usize = default_limit,
    entries: [64]Entry = @splat(.{}),
    bytes: usize = 0,
    clock: u64 = 0,
    detile_hits: u64 = 0,
    detile_misses: u64 = 0,
    tile_hits: u64 = 0,
    tile_misses: u64 = 0,
    evictions: u64 = 0,
    bypasses: u64 = 0,

    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*entry| self.destroy(entry);
        self.* = undefined;
    }

    pub fn detile(self: *Cache, address: u64, layout: gpu.SurfaceLayout, backing: []const u8, pixels: []u8) !void {
        if (self.find(address, layout)) |entry| {
            if (pixels.len == entry.pixels.len and std.mem.eql(u8, entry.backing, backing)) {
                @memcpy(pixels, entry.pixels);
                self.touch(entry);
                self.detile_hits += 1;
                return;
            }
        }
        self.detile_misses += 1;
        try layout.detile(backing, pixels);
        self.remember(address, layout, backing, pixels);
    }

    pub fn tile(self: *Cache, address: u64, layout: gpu.SurfaceLayout, pixels: []const u8, backing: []u8) !void {
        if (self.find(address, layout)) |entry| {
            // Both comparisons are necessary: fresh padding or logical guest
            // writes must be preserved/overwritten exactly as the uncached path.
            if (std.mem.eql(u8, entry.pixels, pixels) and std.mem.eql(u8, entry.backing, backing)) {
                self.touch(entry);
                self.tile_hits += 1;
                return;
            }
        }
        self.tile_misses += 1;
        try layout.tile(pixels, backing);
        self.remember(address, layout, backing, pixels);
    }

    fn find(self: *Cache, address: u64, layout: gpu.SurfaceLayout) ?*Entry {
        if (self.limit == 0) return null;
        for (&self.entries) |*entry| {
            if (entry.backing.len != 0 and entry.address == address and std.meta.eql(entry.layout, layout)) return entry;
        }
        return null;
    }

    fn touch(self: *Cache, entry: *Entry) void {
        self.clock +|= 1;
        entry.stamp = self.clock;
    }

    fn destroy(self: *Cache, entry: *Entry) void {
        self.bytes -= entry.backing.len + entry.pixels.len;
        self.allocator.free(entry.backing);
        self.allocator.free(entry.pixels);
        entry.* = .{};
    }

    fn remember(self: *Cache, address: u64, layout: gpu.SurfaceLayout, backing: []const u8, pixels: []const u8) void {
        const cost = std.math.add(usize, backing.len, pixels.len) catch {
            self.bypasses += 1;
            return;
        };
        if (cost > self.limit or backing.len == 0 or backing.len != layout.required_source_bytes or pixels.len != layout.staging_bytes) {
            self.bypasses += 1;
            return;
        }
        if (self.find(address, layout)) |entry| {
            @memcpy(entry.backing, backing);
            @memcpy(entry.pixels, pixels);
            self.touch(entry);
            return;
        }
        while (true) {
            var empty: ?*Entry = null;
            var oldest: ?*Entry = null;
            for (&self.entries) |*entry| {
                if (entry.backing.len == 0) {
                    empty = entry;
                } else if (oldest == null or entry.stamp < oldest.?.stamp) {
                    oldest = entry;
                }
            }
            if (empty != null and self.bytes <= self.limit - cost) {
                const retained_backing = self.allocator.dupe(u8, backing) catch {
                    self.bypasses += 1;
                    return;
                };
                const retained_pixels = self.allocator.dupe(u8, pixels) catch {
                    self.allocator.free(retained_backing);
                    self.bypasses += 1;
                    return;
                };
                empty.?.* = .{ .address = address, .layout = layout, .backing = retained_backing, .pixels = retained_pixels };
                self.bytes += cost;
                self.touch(empty.?);
                return;
            }
            const victim = oldest orelse unreachable;
            self.destroy(victim);
            self.evictions += 1;
        }
    }
};

test "conversion cache validates current contents and owns independent snapshots" {
    var cache = Cache{ .allocator = std.testing.allocator };
    defer cache.deinit();
    for ([_]gpu.resources.TileMode{ .linear, .standard_4kb, .depth, .render_target }) |mode| for ([_]u8{ 2, 4 }) |bpp| {
        const layout = try gpu.SurfaceLayout.init(.{ .tile_mode = mode, .width = 65, .height = 37, .row_pitch_elements = 80 }, bpp);
        const backing = try std.testing.allocator.alloc(u8, @intCast(layout.required_source_bytes));
        defer std.testing.allocator.free(backing);
        const reference = try std.testing.allocator.alloc(u8, @intCast(layout.staging_bytes));
        defer std.testing.allocator.free(reference);
        const actual = try std.testing.allocator.alloc(u8, reference.len);
        defer std.testing.allocator.free(actual);
        @memset(backing, 0xa7);
        for (reference, 0..) |*byte, i| byte.* = @truncate(i *% 193 +% 31);
        try layout.tile(reference, backing);
        try cache.detile(0x10000, layout, backing, actual);
        @memset(actual, 0x23); // A caller may mutate its working copy.
        const hits = cache.detile_hits;
        try cache.detile(0x10000, layout, backing, actual);
        try std.testing.expectEqual(hits + 1, cache.detile_hits);
        try std.testing.expectEqualSlices(u8, reference, actual);
        reference[reference.len / 2] ^= 1;
        try layout.tile(reference, backing);
        const misses = cache.detile_misses;
        try cache.detile(0x10000, layout, backing, actual);
        try std.testing.expectEqual(misses + 1, cache.detile_misses);
        try std.testing.expectEqualSlices(u8, reference, actual);
        const tile_hits = cache.tile_hits;
        try cache.tile(0x10000, layout, actual, backing);
        try std.testing.expectEqual(tile_hits + 1, cache.tile_hits);
        // A changed attachment result must become the next read's reference.
        actual[0] ^= 0x9a;
        try cache.tile(0x10000, layout, actual, backing);
        try layout.detile(backing, reference);
        try std.testing.expectEqualSlices(u8, actual, reference);
        try cache.detile(0x10000, layout, backing, actual);
        try std.testing.expectEqualSlices(u8, reference, actual);
    };
}

test "conversion reuse distinguishes layouts, aliases, changed padding and rejected ranges" {
    var cache = Cache{ .allocator = std.testing.allocator };
    defer cache.deinit();
    const linear = try gpu.SurfaceLayout.init(.{ .tile_mode = .linear, .width = 31, .height = 32, .row_pitch_elements = 32 }, 4);
    const tiled = try gpu.SurfaceLayout.init(.{ .tile_mode = .standard_4kb, .width = 31, .height = 32 }, 4);
    var backing: [4096]u8 = undefined;
    var pixels: [31 * 32 * 4]u8 = undefined;
    var expected = pixels;
    for (&backing, 0..) |*byte, i| byte.* = @truncate(i *% 133 +% (i >> 8));
    try cache.detile(0x1000, linear, &backing, &pixels);
    try cache.detile(0x1000, tiled, &backing, &pixels);
    try std.testing.expectEqual(@as(u64, 0), cache.detile_hits);
    try tiled.detile(&backing, &expected);
    try std.testing.expectEqualSlices(u8, &expected, &pixels);
    try cache.detile(0x1000, linear, &backing, &pixels);
    const hits = cache.detile_hits;
    try cache.detile(0x1004, linear, &backing, &pixels);
    try std.testing.expectEqual(hits, cache.detile_hits);
    backing[127] ^= 0xff; // Padding changes after the initial snapshot.
    var expected_backing = backing;
    try linear.tile(&pixels, &expected_backing);
    try cache.tile(0x1000, linear, &pixels, &backing);
    try std.testing.expectEqual(@as(u64, 0), cache.tile_hits);
    try std.testing.expectEqualSlices(u8, &expected_backing, &backing);
    // A logical write through an overlapping guest alias must invalidate reuse.
    backing[0] ^= 0x33;
    const misses = cache.detile_misses;
    try cache.detile(0x1000, linear, &backing, &pixels);
    try std.testing.expectEqual(misses + 1, cache.detile_misses);
    try linear.detile(&backing, &expected);
    try std.testing.expectEqualSlices(u8, &expected, &pixels);
    try std.testing.expectError(error.SourceTooSmall, cache.detile(0x1000, linear, backing[0..4], &pixels));
    try std.testing.expectError(error.DestinationTooSmall, cache.tile(0x1000, linear, &pixels, backing[0..4]));
}

test "conversion cache obeys budgets, evicts old views and survives allocation failure" {
    const layout = try gpu.SurfaceLayout.init(.{ .tile_mode = .linear, .width = 2, .height = 2 }, 4);
    const backing: [16]u8 = @splat(0x31);
    var pixels: [16]u8 = undefined;
    var cache = Cache{ .allocator = std.testing.allocator, .limit = 64 };
    defer cache.deinit();
    for (0..3) |i| try cache.detile(i * 256, layout, &backing, &pixels);
    try std.testing.expectEqual(@as(usize, 64), cache.bytes);
    try std.testing.expectEqual(@as(u64, 1), cache.evictions);
    try std.testing.expect(cache.find(0, layout) == null);
    cache.limit = 0;
    const hits = cache.detile_hits;
    try cache.detile(512, layout, &backing, &pixels);
    try std.testing.expectEqual(hits, cache.detile_hits);
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var failed_cache = Cache{ .allocator = failing.allocator() };
        defer failed_cache.deinit();
        try failed_cache.detile(0, layout, &backing, &pixels);
        try std.testing.expectEqualSlices(u8, &backing, &pixels);
        try std.testing.expectEqual(@as(usize, 0), failed_cache.bytes);
    }
}
