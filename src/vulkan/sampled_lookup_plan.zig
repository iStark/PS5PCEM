// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Stable groups of runtime image candidates, built in one pass. Keeping both
//! group and member order preserves descriptor-table insertion and collisions.
const std = @import("std");

pub const Key = struct {
    resource_sgpr: u32,
    sampler_sgpr: u32,
    instruction_pc: ?u32,
    dimension: u8,
};

pub const end = std.math.maxInt(usize);

pub const Group = struct {
    first: usize,
    last: usize,
    count: usize,
};

pub const Plan = struct {
    groups: std.AutoArrayHashMapUnmanaged(Key, Group) = .{},
    next: std.ArrayList(usize) = .empty,
    table: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.groups.deinit(allocator);
        self.next.deinit(allocator);
        self.table.deinit(allocator);
        self.* = .{};
    }

    pub fn reset(self: *Plan, allocator: std.mem.Allocator, mapping_count: usize) !void {
        self.groups.clearRetainingCapacity();
        try self.next.resize(allocator, mapping_count);
    }

    pub fn add(self: *Plan, allocator: std.mem.Allocator, key: Key, index: usize) !void {
        const entry = try self.groups.getOrPut(allocator, key);
        self.next.items[index] = end;
        if (entry.found_existing) {
            self.next.items[entry.value_ptr.last] = index;
            entry.value_ptr.last = index;
            entry.value_ptr.count += 1;
        } else {
            entry.value_ptr.* = .{ .first = index, .last = index, .count = 1 };
        }
    }
};

test "sampled candidate groups preserve interleaved order and complete keys" {
    var plan = Plan{};
    defer plan.deinit(std.testing.allocator);
    const base = Key{ .resource_sgpr = 4, .sampler_sgpr = 12, .instruction_pc = null, .dimension = 0 };
    var keys = [_]Key{base} ** 5;
    keys[1].instruction_pc = 0;
    keys[2].resource_sgpr = 8;
    keys[3].sampler_sgpr = 16;
    keys[4].dimension = 1;
    const order = [_]usize{ 4, 0, 2, 1, 3 };
    const rounds = 130;
    try plan.reset(std.testing.allocator, rounds * keys.len + 7);
    for (0..rounds) |round| {
        for (order, 0..) |key, column| try plan.add(std.testing.allocator, keys[key], 7 + round * keys.len + column);
    }
    try std.testing.expectEqual(keys.len, plan.groups.count());
    for (plan.groups.keys(), plan.groups.values(), 0..) |key, group, column| {
        try std.testing.expectEqual(keys[order[column]], key);
        try std.testing.expectEqual(rounds, group.count);
        var index = group.first;
        for (0..rounds) |round| {
            try std.testing.expectEqual(7 + round * keys.len + column, index);
            index = plan.next.items[index];
        }
        try std.testing.expectEqual(end, index);
    }
    const capacity = plan.next.capacity;
    try plan.reset(std.testing.allocator, 3);
    try plan.add(std.testing.allocator, base, 2);
    try std.testing.expectEqual(capacity, plan.next.capacity);
    try std.testing.expectEqual(@as(usize, 1), plan.groups.count());
    try std.testing.expectEqual(Group{ .first = 2, .last = 2, .count = 1 }, plan.groups.values()[0]);
    try std.testing.expectEqual(end, plan.next.items[2]);
    try plan.reset(std.testing.allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), plan.groups.count());
}
