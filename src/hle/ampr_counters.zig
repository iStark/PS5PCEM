// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Process-local AMPR counters. The lock covers both halves of a pair and
//! every read/modify/write, so readers cannot observe a torn 64-bit value.
const std = @import("std");

pub const Access = enum(u8) {
    pair = 0,
    word = 1,
    half_low = 2,
    half_high = 3,
    byte0 = 4,
    byte1 = 5,
    byte2 = 6,
    byte3 = 7,

    pub fn bits(self: Access) u7 {
        return switch (self) {
            .pair => 64,
            .word => 32,
            .half_low, .half_high => 16,
            else => 8,
        };
    }
    fn shift(self: Access) u6 {
        return switch (self) {
            .half_high => 16,
            .byte1 => 8,
            .byte2 => 16,
            .byte3 => 24,
            else => 0,
        };
    }
    pub fn mask(self: Access) u64 {
        return @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - self.bits()));
    }
};
pub const Operation = enum(u8) { store, bit_or, and_complement, bit_xor, add };
pub const Compare = enum(u8) { equal, greater, less, not_equal, reached, signed_greater, signed_less };
pub const Write = struct { counter: u8, access: Access, value: u64, operation: Operation };
pub const Wait = struct { counter: u8, access: Access, reference: u64, compare: Compare, mask: u64 = std.math.maxInt(u64) };

pub fn valid(counter: u8, access: Access) bool {
    return counter < 128 and (access != .pair or counter & 1 == 0);
}

pub const Bank = struct {
    lock: std.atomic.Mutex = .unlocked,
    words: [128]u32 = @splat(0),

    fn acquire(self: *Bank) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn reset(self: *Bank) void {
        self.acquire();
        defer self.lock.unlock();
        self.words = @splat(0);
    }
    fn readLocked(self: *Bank, counter: u8, access: Access) u64 {
        if (access == .pair) return @as(u64, self.words[counter]) | (@as(u64, self.words[counter + 1]) << 32);
        return (@as(u64, self.words[counter]) >> access.shift()) & access.mask();
    }
    pub fn read(self: *Bank, counter: u8, access: Access) u64 {
        std.debug.assert(valid(counter, access));
        self.acquire();
        defer self.lock.unlock();
        return self.readLocked(counter, access);
    }
    pub fn write(self: *Bank, command: Write) void {
        std.debug.assert(valid(command.counter, command.access));
        self.acquire();
        defer self.lock.unlock();
        const current = self.readLocked(command.counter, command.access);
        const value = command.value;
        const next = (switch (command.operation) {
            .store => value,
            .bit_or => current | value,
            .and_complement => current & ~value,
            .bit_xor => current ^ value,
            .add => current +% value,
        }) & command.access.mask();
        if (command.access == .pair) {
            self.words[command.counter] = @truncate(next);
            self.words[command.counter + 1] = @truncate(next >> 32);
        } else {
            const mask: u32 = @truncate(command.access.mask() << command.access.shift());
            self.words[command.counter] = (self.words[command.counter] & ~mask) | @as(u32, @truncate(next << command.access.shift()));
        }
    }
    pub fn satisfied(self: *Bank, command: Wait) bool {
        return compare(command.compare, self.read(command.counter, command.access), command.reference, command.mask, command.access);
    }
};

pub fn compare(kind: Compare, value: u64, reference: u64, mask: u64, access: Access) bool {
    // Shift the selected field's sign bit to bit 63. This also makes wrapping
    // sequence comparisons work at 8, 16, 32 and 64 bits with the same rule.
    const shift: u6 = @intCast(64 - access.bits());
    const a = (value & mask) << shift;
    const b = (reference & mask) << shift;
    return switch (kind) {
        .equal => a == b,
        .greater => a > b,
        .less => a < b,
        .not_equal => a != b,
        .reached => a -% b < (@as(u64, 1) << 63),
        .signed_greater => @as(i64, @bitCast(a)) > @as(i64, @bitCast(b)),
        .signed_less => @as(i64, @bitCast(a)) < @as(i64, @bitCast(b)),
    };
}

test "AMPR counter fields preserve neighbours and wrap within their width" {
    var bank = Bank{};
    bank.write(.{ .counter = 20, .access = .word, .value = 0x11223344, .operation = .store });
    bank.write(.{ .counter = 20, .access = .byte2, .value = 0x1aa, .operation = .store });
    bank.write(.{ .counter = 20, .access = .half_low, .value = 0xffff, .operation = .add });
    try std.testing.expectEqual(@as(u64, 0x11aa3343), bank.read(20, .word));
    bank.write(.{ .counter = 126, .access = .pair, .value = 0x500000001, .operation = .store });
    bank.write(.{ .counter = 126, .access = .pair, .value = 0xffffffff, .operation = .add });
    try std.testing.expectEqual(@as(u64, 0x600000000), bank.read(126, .pair));
    inline for (std.meta.tags(Access)) |access| {
        inline for (std.meta.tags(Operation)) |operation| {
            bank.write(.{ .counter = 0, .access = .pair, .value = 0x1234567812345678, .operation = .store });
            const before = bank.read(0, access);
            const value: u64 = 0xabcdef09abcdef09;
            const expected = (switch (operation) {
                .store => value,
                .bit_or => before | value,
                .and_complement => before & ~value,
                .bit_xor => before ^ value,
                .add => before +% value,
            }) & access.mask();
            bank.write(.{ .counter = 0, .access = access, .value = value, .operation = operation });
            try std.testing.expectEqual(expected, bank.read(0, access));
            if (access != .pair) try std.testing.expectEqual(@as(u64, 0x12345678), bank.read(1, .word));
        }
    }
    bank.reset();
    try std.testing.expectEqual(@as(u64, 0), bank.read(126, .pair));
    try std.testing.expect(!valid(127, .pair));
    try std.testing.expect(!valid(128, .word));
}

test "AMPR counter comparisons include masks signed values and sequence wrap" {
    inline for (std.meta.tags(Access)) |access| {
        const top = access.mask();
        try std.testing.expect(compare(.equal, 0x35, 0xf5, 0x0f, access));
        try std.testing.expect(compare(.greater, top, 0, top, access));
        try std.testing.expect(compare(.less, 0, top, top, access));
        try std.testing.expect(compare(.not_equal, top, 0, top, access));
        try std.testing.expect(compare(.signed_less, top, 0, top, access));
        try std.testing.expect(compare(.signed_greater, 0, top, top, access));
        try std.testing.expect(compare(.reached, 0, top, top, access));
        try std.testing.expect(compare(.reached, top, top, top, access));
        try std.testing.expect(!compare(.reached, top, 0, top, access));
        try std.testing.expect(!compare(.reached, (@as(u64, 1) << @as(u6, @intCast(access.bits() - 1))), 0, top, access));
    }
}
