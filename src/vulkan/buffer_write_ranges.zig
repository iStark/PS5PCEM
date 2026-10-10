// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bounded, conservative byte coverage of pending GPU writes. An unknown
//! address or exhausted span budget restores whole-buffer publication.
const std = @import("std");

pub const Span = struct { first: usize, end: usize };
pub const capacity = 8;

pub const Ranges = struct {
    whole: bool = false,
    count: usize = 0,
    spans: [capacity]Span = undefined,

    pub fn include(self: *Ranges, span: Span) void {
        if (self.whole or span.first >= span.end) return;
        var merged = span;
        var first: usize = 0;
        while (first < self.count and self.spans[first].end < merged.first) : (first += 1) {}
        var last = first;
        while (last < self.count and self.spans[last].first <= merged.end) : (last += 1) {
            merged.first = @min(merged.first, self.spans[last].first);
            merged.end = @max(merged.end, self.spans[last].end);
        }
        const remaining = self.count - (last - first);
        if (remaining == capacity) {
            self.* = .{ .whole = true };
            return;
        }
        if (last > first)
            std.mem.copyForwards(Span, self.spans[first + 1 .. remaining + 1], self.spans[last..self.count])
        else
            std.mem.copyBackwards(Span, self.spans[first + 1 .. remaining + 1], self.spans[last..self.count]);
        self.spans[first] = merged;
        self.count = remaining + 1;
    }

    pub fn merge(self: *Ranges, other: *const Ranges) void {
        if (other.whole) {
            self.* = .{ .whole = true };
            return;
        }
        for (other.spans[0..other.count]) |span| self.include(span);
    }

    pub fn prefix(self: *const Ranges, size: usize, output: *[capacity]Span) []const Span {
        if (size == 0) return output[0..0];
        if (self.whole) {
            output[0] = .{ .first = 0, .end = size };
            return output[0..1];
        }
        var count: usize = 0;
        for (self.spans[0..self.count]) |span| {
            if (span.first >= size) break;
            output[count] = .{ .first = span.first, .end = @min(span.end, size) };
            count += 1;
        }
        return output[0..count];
    }

    /// Retire only bytes already published (or protected by a newer writer).
    /// Further GPU writes are merged back through include/merge as usual.
    pub fn consumePrefix(self: *Ranges, size: usize, total: usize) void {
        if (size == 0) return;
        if (self.whole) {
            self.* = .{};
            if (size < total) self.include(.{ .first = size, .end = total });
            return;
        }
        var remaining: usize = 0;
        for (self.spans[0..self.count]) |span| {
            if (span.end <= size) continue;
            self.spans[remaining] = .{ .first = @max(span.first, size), .end = span.end };
            remaining += 1;
        }
        self.count = remaining;
    }
};

test "write spans merge overlap and adjacency without publishing the gaps" {
    var ranges = Ranges{};
    ranges.include(.{ .first = 32, .end = 36 });
    ranges.include(.{ .first = 0, .end = 4 });
    ranges.include(.{ .first = 60, .end = 64 });
    ranges.include(.{ .first = 4, .end = 8 });
    ranges.include(.{ .first = 6, .end = 34 });
    try std.testing.expectEqual(@as(usize, 2), ranges.count);
    try std.testing.expectEqual(Span{ .first = 0, .end = 36 }, ranges.spans[0]);
    try std.testing.expectEqual(Span{ .first = 60, .end = 64 }, ranges.spans[1]);
    var clipped: [capacity]Span = undefined;
    const prefix = ranges.prefix(62, &clipped);
    try std.testing.expectEqual(Span{ .first = 60, .end = 62 }, prefix[1]);
    try std.testing.expectEqual(@as(usize, 0), ranges.prefix(0, &clipped).len);
}

test "write span overflow and unknown writes retain every GPU result" {
    var ranges = Ranges{};
    for (0..capacity + 1) |i| ranges.include(.{ .first = i * 8, .end = i * 8 + 4 });
    try std.testing.expect(ranges.whole);
    var clipped: [capacity]Span = undefined;
    try std.testing.expectEqual(Span{ .first = 0, .end = 128 }, ranges.prefix(128, &clipped)[0]);
    var known = Ranges{};
    known.include(.{ .first = 32, .end = 36 });
    known.merge(&ranges);
    try std.testing.expect(known.whole);
    known.include(.{ .first = 0, .end = 4 });
    try std.testing.expect(known.whole);
}

test "published prefixes stay retired until another GPU write" {
    var ranges = Ranges{ .whole = true };
    var clipped: [capacity]Span = undefined;
    ranges.consumePrefix(0, 64);
    try std.testing.expect(ranges.whole);
    ranges.consumePrefix(3, 64);
    try std.testing.expectEqual(@as(usize, 0), ranges.prefix(3, &clipped).len);
    ranges.consumePrefix(3, 64);
    try std.testing.expectEqual(Span{ .first = 3, .end = 9 }, ranges.prefix(9, &clipped)[0]);
    ranges.consumePrefix(9, 64);
    ranges.include(.{ .first = 1, .end = 5 });
    try std.testing.expectEqual(Span{ .first = 1, .end = 5 }, ranges.prefix(9, &clipped)[0]);
    ranges.consumePrefix(9, 64);
    try std.testing.expectEqual(Span{ .first = 9, .end = 64 }, ranges.prefix(64, &clipped)[0]);
    ranges.consumePrefix(64, 64);
    try std.testing.expectEqual(@as(usize, 0), ranges.count);
    try std.testing.expect(!ranges.whole);
    ranges.merge(&.{ .whole = true });
    try std.testing.expectEqual(Span{ .first = 0, .end = 64 }, ranges.prefix(64, &clipped)[0]);
    ranges.consumePrefix(128, 64);
    try std.testing.expectEqual(@as(usize, 0), ranges.count);
    try std.testing.expect(!ranges.whole);
}

test "prefix publication retires sparse writes without adding their gaps" {
    var ranges = Ranges{};
    ranges.include(.{ .first = 4, .end = 8 });
    ranges.include(.{ .first = 16, .end = 24 });
    ranges.consumePrefix(12, 64);
    try std.testing.expectEqual(@as(usize, 1), ranges.count);
    try std.testing.expectEqual(Span{ .first = 16, .end = 24 }, ranges.spans[0]);
    ranges.consumePrefix(20, 64);
    try std.testing.expectEqual(Span{ .first = 20, .end = 24 }, ranges.spans[0]);
    ranges.consumePrefix(24, 64);
    try std.testing.expectEqual(@as(usize, 0), ranges.count);
}
