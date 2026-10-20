// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Immutable decoded programs. Every hit validates the complete captured code
//! through the ordered guest reader; leases survive invalidation and eviction.
const std = @import("std");
const gpu = @import("gpu");

const Entry = struct {
    allocator: std.mem.Allocator,
    address: u64,
    analysis: gpu.ShaderAnalysis,
    refs: usize = 1,
    stamp: u64 = 0,
    fn release(self: *Entry) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const allocator = self.allocator;
        self.analysis.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Lease = struct {
    entry: *Entry,
    pub fn view(self: Lease) *const gpu.ShaderAnalysis {
        return &self.entry.analysis;
    }
    pub fn release(self: Lease) void {
        self.entry.release();
    }
};

pub const Cache = struct {
    entries: [64]?*Entry = @splat(null),
    enabled: bool = true,
    clock: u64 = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    invalidations: u64 = 0,

    pub fn deinit(self: *Cache) void {
        for (self.entries) |entry| if (entry) |value| value.release();
        self.entries = @splat(null);
    }

    pub fn acquire(self: *Cache, allocator: std.mem.Allocator, reader: gpu.ShaderMemoryReader, address: u64) !Lease {
        self.clock +|= 1;
        if (self.enabled) for (&self.entries) |*slot| {
            const entry = slot.* orelse continue;
            if (entry.address != address) continue;
            const expected = std.mem.sliceAsBytes(entry.analysis.code.items);
            var scratch: [4096]u8 = undefined;
            var offset: usize = 0;
            while (offset < expected.len) {
                const size = @min(scratch.len, expected.len - offset);
                try reader.read(address + offset, scratch[0..size]);
                if (!std.mem.eql(u8, scratch[0..size], expected[offset..][0..size])) break;
                offset += size;
            }
            if (offset == expected.len) {
                entry.stamp = self.clock;
                entry.refs += 1;
                self.hits += 1;
                return .{ .entry = entry };
            }
            slot.* = null;
            entry.release();
            self.invalidations += 1;
        };
        self.misses += 1;
        const entry = try allocator.create(Entry);
        errdefer allocator.destroy(entry);
        entry.* = .{ .allocator = allocator, .address = address, .analysis = try gpu.shader_analysis.decode(allocator, reader, address, 4096), .stamp = self.clock };
        errdefer entry.analysis.deinit(allocator);
        entry.analysis.discardDiagnosticIr(allocator);
        try entry.analysis.enableTranslationKey(allocator);
        if (self.enabled) {
            var victim: usize = 0;
            for (self.entries, 0..) |candidate, index| {
                if (candidate == null) {
                    victim = index;
                    break;
                }
                if (candidate.?.stamp < self.entries[victim].?.stamp) victim = index;
            }
            if (self.entries[victim]) |old| old.release();
            self.entries[victim] = entry;
            entry.refs += 1;
        }
        return .{ .entry = entry };
    }
};

test "decoded cache validates mutations, read failures and leased evictions" {
    const Memory = struct {
        words: [2]u32 = .{ 0xbe800081, 0xbf810000 },
        fail: bool = false,
        fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const offset = address % 16;
            if (self.fail or offset + bytes.len > 8) return false;
            @memcpy(bytes, std.mem.asBytes(&self.words)[@intCast(offset)..][0..bytes.len]);
            return true;
        }
    };
    const allocator = std.testing.allocator;
    var memory = Memory{};
    const reader = gpu.ShaderMemoryReader{ .context = &memory, .read_fn = Memory.read };
    var cache = Cache{};
    defer cache.deinit();
    const first = try cache.acquire(allocator, reader, 0x100);
    defer first.release();
    const hit = try cache.acquire(allocator, reader, 0x100);
    try std.testing.expectEqual(first.entry, hit.entry);
    hit.release();
    memory.words[0] = 0xbe800082;
    const changed = try cache.acquire(allocator, reader, 0x100);
    defer changed.release();
    try std.testing.expectEqual(@as(u32, 0xbe800081), first.view().code.items[0]);
    try std.testing.expectEqual(memory.words[0], changed.view().code.items[0]);
    try std.testing.expectEqual(@as(u64, 1), cache.invalidations);
    memory.fail = true;
    try std.testing.expectError(error.MemoryReadFailed, cache.acquire(allocator, reader, 0x100));
    memory.fail = false;
    memory.words[0] = 0xbf810000; // Shorter replacement must not reuse the old CFG.
    const short = try cache.acquire(allocator, reader, 0x100);
    defer short.release();
    try std.testing.expectEqual(@as(usize, 1), short.view().code.items.len);
    for (0..70) |i| {
        const lease = try cache.acquire(allocator, reader, 0x1000 + i * 16);
        lease.release();
    }
    cache.deinit();
    try std.testing.expectEqual(@as(u32, 0xbe800082), changed.view().code.items[0]);
}
