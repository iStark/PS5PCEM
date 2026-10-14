// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Stable merging of recovered scalar values, keyed by SGPR and producer PC.
const std = @import("std");
const scalar = @import("scalar_provenance.zig");
const Register = @import("rdna2").spirv.ScalarRegister;

pub export var indexed_scalar_merges: bool = true;
const absent = std.math.maxInt(u16);

pub const Index = struct {
    // Borrowed draw scratch: no allocation or clearing of unused list entries.
    next: [scalar.maximum_scalar_specializations]u16 = undefined,

    pub fn merge(self: *Index, destination: []Register, count: *usize, incoming: []const Register) void {
        std.debug.assert(count.* <= destination.len);
        if (!@atomicLoad(bool, &indexed_scalar_merges, .monotonic) or
            count.* < 16 or incoming.len < 16 or destination.len > self.next.len)
        {
            linear(destination, count, incoming);
            return;
        }
        var heads: [scalar.maximum_scalar_registers]u16 = @splat(absent);
        var cursor = count.*;
        // Reverse insertion preserves the first-match behavior of the old
        // linear search, even for duplicate keys already in the destination.
        while (cursor != 0) {
            cursor -= 1;
            const register = destination[cursor].register;
            if (register >= heads.len) continue;
            self.next[cursor] = heads[register];
            heads[register] = @intCast(cursor);
        }
        for (incoming) |value| {
            var match: ?usize = null;
            if (value.register < heads.len) {
                var index = heads[value.register];
                while (index != absent) : (index = self.next[index]) {
                    if (destination[index].producer_pc == value.producer_pc) {
                        match = index;
                        break;
                    }
                }
            } else {
                // Preserve the generic helper's behavior for non-SGPR inputs.
                for (destination[0..count.*], 0..) |previous, index| {
                    if (previous.register == value.register and previous.producer_pc == value.producer_pc) {
                        match = index;
                        break;
                    }
                }
            }
            if (match) |index| {
                destination[index].value = value.value;
            } else if (count.* < destination.len) {
                const index = count.*;
                destination[index] = value;
                count.* += 1;
                if (value.register < heads.len) {
                    self.next[index] = heads[value.register];
                    heads[value.register] = @intCast(index);
                }
            }
        }
    }
};

fn linear(destination: []Register, count: *usize, incoming: []const Register) void {
    for (incoming) |value| {
        var found = false;
        for (destination[0..count.*]) |*entry| {
            if (entry.register == value.register and entry.producer_pc == value.producer_pc) {
                entry.value = value.value;
                found = true;
                break;
            }
        }
        if (!found and count.* < destination.len) {
            destination[count.*] = value;
            count.* += 1;
        }
    }
}

test "indexed scalar merge preserves first matches producer identities and full capacity updates" {
    const saved = indexed_scalar_merges;
    defer indexed_scalar_merges = saved;
    indexed_scalar_merges = true;
    var scratch: Index = .{};
    var original: [512]Register = undefined;
    var incoming: [257]Register = undefined;
    for (&original, 0..) |*value, i| value.* = .{
        .register = @intCast((i * 37) % 140),
        .producer_pc = if (i % 3 == 0) null else @as(u32, @intCast((i / 140) * 16)),
        .value = @intCast(i),
    };
    // Deliberate duplicate keys: only the earliest destination is overwritten.
    original[21] = original[3];
    original[21].value = 0xdead;
    for (&incoming, 0..) |*value, i| {
        value.* = original[(i * 19) % original.len];
        value.value = @intCast(0x1000 + i);
        if (i % 7 == 0) value.producer_pc = std.math.maxInt(u32) - @as(u32, @intCast(i));
    }
    for ([_]usize{ 0, 7, 16, 128, 511, 512 }) |initial_count| {
        for ([_]usize{ 16, 129, 512 }) |capacity| {
            if (initial_count > capacity) continue;
            var expected = original;
            var actual = original;
            var expected_count = initial_count;
            var actual_count = initial_count;
            linear(expected[0..capacity], &expected_count, &incoming);
            scratch.merge(actual[0..capacity], &actual_count, &incoming);
            try std.testing.expectEqual(expected_count, actual_count);
            try std.testing.expectEqualDeep(expected[0..expected_count], actual[0..actual_count]);
            try std.testing.expectEqualDeep(original[capacity..], actual[capacity..]);
        }
    }
    var values = original;
    var count: usize = values.len;
    var replacements: [16]Register = @splat(original[3]);
    for (&replacements) |*value| value.value = 0xbeef;
    scratch.merge(&values, &count, &replacements);
    try std.testing.expectEqual(@as(u32, 0xbeef), values[3].value);
    try std.testing.expectEqual(@as(u32, 0xdead), values[21].value);
    try std.testing.expectEqual(@as(usize, values.len), count);
}
