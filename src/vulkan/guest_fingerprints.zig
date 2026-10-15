// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Reuse a full-range digest only while the owner's write watch proves that
//! every byte still belongs to the same unchanged mapping. This cache never
//! arms protection or substitutes a digest for an untracked range.
const std = @import("std");

const Fingerprint = *const fn (?*anyopaque, u64, usize) ?u64;
const Generation = *const fn (?*anyopaque, u64, usize) u64;

pub const Cache = struct {
    const Entry = struct {
        address: u64 = 0,
        size: usize = 0,
        generation: u64 = 0,
        digest: u64 = 0,
    };
    entries: [256]Entry = @splat(.{}),
    context: ?*anyopaque = null,
    fingerprint: ?Fingerprint = null,
    generation: ?Generation = null,
    hits: u64 = 0,
    bytes_avoided: u64 = 0,

    pub fn read(self: *Cache, context: ?*anyopaque, address: u64, size: usize, fingerprint: Fingerprint, generation: ?Generation) ?u64 {
        if (size < 64 * 1024) return fingerprint(context, address, size);
        const observe = generation orelse return fingerprint(context, address, size);
        if (self.context != context or self.fingerprint != fingerprint or self.generation != generation) {
            @memset(&self.entries, .{});
            self.context = context;
            self.fingerprint = fingerprint;
            self.generation = generation;
        }
        const before = observe(context, address, size);
        if (before == 0) return fingerprint(context, address, size);
        const key = [2]u64{ address, size };
        const slot = &self.entries[std.hash.Wyhash.hash(0, std.mem.asBytes(&key)) % self.entries.len];
        if (slot.generation == before and slot.address == address and slot.size == size) {
            self.hits +|= 1;
            self.bytes_avoided +|= size;
            return slot.digest;
        }
        const digest = fingerprint(context, address, size) orelse return null;
        // A CPU write during hashing invalidates this observation even if the
        // digest callback itself succeeded. It must not become a future hit.
        if (observe(context, address, size) == before)
            slot.* = .{ .address = address, .size = size, .generation = before, .digest = digest };
        return digest;
    }
};

test "fingerprint cache guards writes ranges source changes and untracked memory" {
    const Source = struct {
        const size = 128 * 1024;
        bytes: [size]u8 = @splat(7),
        epoch: u64 = 1,
        calls: usize = 0,
        accessible: bool = true,
        race: bool = false,

        fn generation(raw: ?*anyopaque, _: u64, _: usize) u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return if (self.accessible) self.epoch else 0;
        }
        fn fingerprint(raw: ?*anyopaque, address: u64, length: usize) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (!self.accessible or address > size or length > size - address) return null;
            const digest = std.hash.Wyhash.hash(0, self.bytes[@intCast(address)..][0..length]);
            if (self.race) {
                self.race = false;
                self.epoch += 1;
                self.bytes[0] +%= 1;
            }
            return digest;
        }
    };
    const source = try std.testing.allocator.create(Source);
    defer std.testing.allocator.destroy(source);
    source.* = .{};
    var cache = Cache{};
    const full = cache.read(source, 0, Source.size, Source.fingerprint, Source.generation);
    try std.testing.expectEqual(full, cache.read(source, 0, Source.size, Source.fingerprint, Source.generation));
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(@as(u64, Source.size), cache.bytes_avoided);
    source.bytes[0] = 19;
    source.epoch += 1;
    const changed = cache.read(source, 0, Source.size, Source.fingerprint, Source.generation);
    try std.testing.expect(changed != full);
    try std.testing.expectEqual(changed, cache.read(source, 0, Source.size, Source.fingerprint, Source.generation));
    try std.testing.expectEqual(@as(usize, 2), source.calls);
    const partial = cache.read(source, 1, Source.size - 1, Source.fingerprint, Source.generation);
    try std.testing.expect(partial != changed);
    try std.testing.expectEqual(partial, cache.read(source, 1, Source.size - 1, Source.fingerprint, Source.generation));
    source.epoch = 0;
    const untracked_calls = source.calls;
    _ = cache.read(source, 0, Source.size, Source.fingerprint, Source.generation);
    source.bytes[0] = 41;
    _ = cache.read(source, 0, Source.size, Source.fingerprint, Source.generation);
    try std.testing.expectEqual(untracked_calls + 2, source.calls);
    source.epoch = 3;
    source.race = true;
    const raced = cache.read(source, 0, Source.size, Source.fingerprint, Source.generation);
    const fresh = cache.read(source, 0, Source.size, Source.fingerprint, Source.generation);
    try std.testing.expect(raced != fresh);
    source.accessible = false;
    try std.testing.expectEqual(@as(?u64, null), cache.read(source, 0, Source.size, Source.fingerprint, Source.generation));
    source.accessible = true;
    source.epoch += 1;
    source.bytes[0] = 71;
    try std.testing.expect(cache.read(source, 0, Source.size, Source.fingerprint, Source.generation) != fresh);
    const other = try std.testing.allocator.create(Source);
    defer std.testing.allocator.destroy(other);
    other.* = .{ .epoch = source.epoch };
    try std.testing.expectEqual(full, cache.read(other, 0, Source.size, Source.fingerprint, Source.generation));
    try std.testing.expectEqual(@as(usize, 1), other.calls);
    const uncached_calls = other.calls;
    _ = cache.read(other, 0, Source.size, Source.fingerprint, null);
    _ = cache.read(other, 0, 4, Source.fingerprint, Source.generation);
    _ = cache.read(other, 0, 4, Source.fingerprint, Source.generation);
    try std.testing.expectEqual(uncached_calls + 3, other.calls);
}
