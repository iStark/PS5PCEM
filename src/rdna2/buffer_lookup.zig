// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Exact runtime V# lookup. An entry is slot + 1 followed by four guest words.
const std = @import("std");
pub const Binding = @import("sampled_lookup.zig").Binding;
pub const entry_words = 5;

pub fn hash(words: [4]u32) u32 {
    var result: u32 = 2166136261;
    for (words) |word| result = (result ^ word) *% 16777619;
    return result ^ (result >> 16);
}

pub fn capacity(count: usize) usize {
    return std.math.ceilPowerOfTwoAssert(usize, @max(count * 2, 2));
}

pub fn insert(table: []u32, words: [4]u32, slot: u32) void {
    const mask = table.len / entry_words - 1;
    var index = hash(words) & mask;
    var probes: usize = 0;
    while (table[index * entry_words] != 0) : (probes += 1) {
        std.debug.assert(probes < mask);
        index = (index + 1) & mask;
    }
    table[index * entry_words] = slot + 1;
    @memcpy(table[index * entry_words + 1 ..][0..4], &words);
}

test "buffer lookup retains all descriptor words across collisions" {
    const count = 256;
    const table = try std.testing.allocator.alloc(u32, capacity(count) * entry_words);
    defer std.testing.allocator.free(table);
    @memset(table, 0);
    for (0..count) |i| insert(table, .{ 0x10000, @intCast(i / 64), @intCast(i % 64), 0x21000000 }, @intCast(i));
    for (0..count + 1) |i| {
        const words = [4]u32{ 0x10000, @intCast(i / 64), @intCast(i % 64), 0x21000000 };
        var index = hash(words) & (table.len / entry_words - 1);
        var found: ?u32 = null;
        for (0..capacity(count)) |_| {
            const entry = table[index * entry_words ..][0..entry_words];
            if (entry[0] == 0) break;
            if (std.mem.eql(u32, entry[1..], &words)) {
                found = entry[0] - 1;
                break;
            }
            index = (index + 1) & (table.len / entry_words - 1);
        }
        try std.testing.expectEqual(if (i < count) @as(?u32, @intCast(i)) else null, found);
    }
}
