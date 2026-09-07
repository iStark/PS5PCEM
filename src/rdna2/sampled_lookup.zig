// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Exact T# lookup for large indirect image tables. Each open-addressed entry
//! contains slot + 1 (zero means empty), followed by all eight guest words.
const std = @import("std");

pub const entry_words = 9;
pub const Binding = struct {
    descriptor_index: u32,
    word_offset: u32,
    mask: u32,
    probes: u32,
};

pub fn hash(words: [8]u32) u32 {
    var result: u32 = 2166136261;
    for (words) |word| result = (result ^ word) *% 16777619;
    return result ^ (result >> 16);
}

pub fn capacity(count: usize) usize {
    return std.math.ceilPowerOfTwoAssert(usize, @max(count * 2, 2));
}

pub fn insert(table: []u32, words: [8]u32, slot: u32) u32 {
    const mask = table.len / entry_words - 1;
    var index = hash(words) & mask;
    var probes: u32 = 1;
    while (table[index * entry_words] != 0) : (probes += 1) {
        std.debug.assert(probes <= mask);
        index = (index + 1) & mask;
    }
    table[index * entry_words] = slot + 1;
    @memcpy(table[index * entry_words + 1 ..][0..8], &words);
    return probes;
}

test "large sampled lookup preserves exact descriptor views and hash collisions" {
    const count = 4096;
    const table = try std.testing.allocator.alloc(u32, capacity(count) * entry_words);
    defer std.testing.allocator.free(table);
    @memset(table, 0);
    var longest: u32 = 0;
    for (0..count) |i| {
        const words = [8]u32{ 0x90000000, 0xb500000, @intCast(i / 16), 0x90500fac, 0, @intCast(i % 16), 0, 0 };
        longest = @max(longest, insert(table, words, @intCast(i)));
    }
    for (0..count + 1) |i| {
        const words = [8]u32{ 0x90000000, 0xb500000, @intCast(i / 16), 0x90500fac, 0, @intCast(i % 16), 0, 0 };
        var index = hash(words) & (table.len / entry_words - 1);
        var found: ?u32 = null;
        for (0..longest) |_| {
            const entry = table[index * entry_words ..][0..entry_words];
            if (entry[0] != 0 and std.mem.eql(u32, entry[1..], &words)) found = entry[0] - 1;
            index = (index + 1) & (table.len / entry_words - 1);
        }
        try std.testing.expectEqual(if (i < count) @as(?u32, @intCast(i)) else null, found);
    }
}
