// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Byte-validated, immutable upload slices. The owner invalidates the cache
//! before recycling its ring. Guest addresses are only
//! lookup hints; every hit compares the complete current input.
const std = @import("std");

pub fn Cache(comptime Upload: type, comptime capacity: usize) type {
    comptime std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();
        const Entry = struct {
            address: u64,
            size: usize,
            upload: Upload,
            bytes: [4096]u8,
        };
        entries: [capacity]Entry = undefined,
        epochs: [capacity]u64 = @splat(0),
        epoch: u64 = 1,
        slot_mask: usize = capacity - 1,

        fn slot(self: *const Self, address: u64, size: usize) usize {
            return std.hash.Wyhash.hash(size, std.mem.asBytes(&address)) & self.slot_mask;
        }

        /// Changing the hash table geometry cannot expose entries retained
        /// under a previous geometry, including after shrinking and growing.
        pub fn setEntryLimit(self: *Self, requested: usize) void {
            const limit = std.math.floorPowerOfTwo(usize, std.math.clamp(requested, 1, capacity));
            if (self.slot_mask == limit - 1) return;
            self.invalidate();
            self.slot_mask = limit - 1;
        }

        pub fn invalidate(self: *Self) void {
            self.epoch +%= 1;
            if (self.epoch == 0) {
                @memset(&self.epochs, 0);
                self.epoch = 1;
            }
        }

        pub fn find(self: *const Self, address: u64, bytes: []const u8) ?Upload {
            if (bytes.len == 0 or bytes.len > 4096) return null;
            const index = self.slot(address, bytes.len);
            if (self.epochs[index] != self.epoch) return null;
            const entry = &self.entries[index];
            if (entry.address != address or entry.size != bytes.len or
                !std.mem.eql(u8, entry.bytes[0..entry.size], bytes)) return null;
            return entry.upload;
        }

        pub fn remember(self: *Self, address: u64, bytes: []const u8, upload: Upload) void {
            if (bytes.len == 0 or bytes.len > 4096) return;
            const index = self.slot(address, bytes.len);
            const entry = &self.entries[index];
            entry.address = address;
            entry.size = bytes.len;
            entry.upload = upload;
            @memcpy(entry.bytes[0..bytes.len], bytes);
            self.epochs[index] = self.epoch;
        }
    };
}

test "transient snapshot capacity changes invalidate every retained upload" {
    const C = Cache(u64, 8);
    const cache = try std.testing.allocator.create(C);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    const bytes = [_]u8{ 1, 2, 3, 4 };
    cache.remember(0x1000, &bytes, 123);
    cache.setEntryLimit(8);
    try std.testing.expectEqual(@as(?u64, 123), cache.find(0x1000, &bytes));
    cache.setEntryLimit(3);
    try std.testing.expectEqual(@as(usize, 1), cache.slot_mask);
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x1000, &bytes));
    cache.remember(0x1000, &bytes, 456);
    cache.setEntryLimit(0);
    try std.testing.expectEqual(@as(usize, 0), cache.slot_mask);
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x1000, &bytes));
    cache.remember(0x2000, &bytes, 789);
    cache.setEntryLimit(99);
    try std.testing.expectEqual(@as(usize, 7), cache.slot_mask);
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x1000, &bytes));
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x2000, &bytes));
}

test "transient snapshots validate all bytes and invalidate recycled upload storage" {
    const C = Cache(u64, 2);
    const cache = try std.testing.allocator.create(C);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    var bytes: [4096]u8 = @splat(17);
    cache.remember(0x1000, &bytes, 123);
    try std.testing.expectEqual(@as(?u64, 123), cache.find(0x1000, &bytes));
    bytes[4095] = 18;
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x1000, &bytes));
    cache.remember(0x1000, &bytes, 456);
    try std.testing.expectEqual(@as(?u64, 456), cache.find(0x1000, &bytes));
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x1000, bytes[0..4095]));
    cache.invalidate();
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x1000, &bytes));
    cache.remember(0x1000, &bytes, 789);
    cache.epoch = std.math.maxInt(u64);
    cache.invalidate();
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x1000, &bytes));
}

test "transient snapshot collisions replace hints without accepting unrelated memory" {
    const C = Cache(u64, 1);
    var cache = C{};
    const bytes = [_]u8{ 1, 2, 3, 4 };
    cache.remember(0x1000, &bytes, 123);
    cache.remember(0x2000, &bytes, 456);
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x1000, &bytes));
    try std.testing.expectEqual(@as(?u64, 456), cache.find(0x2000, &bytes));
    try std.testing.expectEqual(@as(?u64, null), cache.find(0x2000, &.{}));
}
