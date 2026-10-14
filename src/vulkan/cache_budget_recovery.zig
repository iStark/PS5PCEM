// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! A temporary allocation failure must not permanently disable texture reuse.
//! Recover gradually; repeated pressure backs off without exceeding the user's
//! configured ceiling. This controls a soft cache limit, not physical capacity.
const std = @import("std");

pub const Recovery = struct {
    const initial_delay_ns = 5 * std.time.ns_per_s;
    const maximum_delay_ns = 60 * std.time.ns_per_s;
    const step_bytes = 256 * 1024 * 1024;

    last_pressure_ns: u64 = 0,
    next_recovery_ns: u64 = 0,
    delay_ns: u64 = initial_delay_ns,

    pub fn pressure(self: *Recovery, now: u64) void {
        self.delay_ns = if (self.last_pressure_ns != 0 and now -| self.last_pressure_ns < maximum_delay_ns)
            @min(self.delay_ns * 2, maximum_delay_ns)
        else
            initial_delay_ns;
        self.last_pressure_ns = now;
        self.next_recovery_ns = now +| self.delay_ns;
    }

    pub fn recover(self: *Recovery, now: u64, current: u64, ceiling: u64) u64 {
        if (self.next_recovery_ns == 0 or now < self.next_recovery_ns or current >= ceiling) return current;
        const next = @min(current +| step_bytes, ceiling);
        self.next_recovery_ns = if (next == ceiling) 0 else now +| self.delay_ns;
        return next;
    }
};

test "transient pressure recovers gradually to the configured ceiling" {
    var recovery = Recovery{};
    const mib = 1024 * 1024;
    const second = std.time.ns_per_s;
    try std.testing.expectEqual(@as(u64, 126 * mib), recovery.recover(100 * second, 126 * mib, 512 * mib));
    recovery.pressure(second);
    try std.testing.expectEqual(@as(u64, 126 * mib), recovery.recover(5 * second, 126 * mib, 512 * mib));
    try std.testing.expectEqual(@as(u64, 382 * mib), recovery.recover(6 * second, 126 * mib, 512 * mib));
    try std.testing.expectEqual(@as(u64, 382 * mib), recovery.recover(10 * second, 382 * mib, 512 * mib));
    try std.testing.expectEqual(@as(u64, 512 * mib), recovery.recover(11 * second, 382 * mib, 512 * mib));
    try std.testing.expectEqual(@as(u64, 512 * mib), recovery.recover(100 * second, 512 * mib, 512 * mib));
}

test "repeated allocation pressure backs off and a quiet minute resets it" {
    var recovery = Recovery{};
    const second = std.time.ns_per_s;
    recovery.pressure(second);
    recovery.pressure(2 * second);
    try std.testing.expectEqual(@as(u64, 10 * second), recovery.delay_ns);
    try std.testing.expectEqual(@as(u64, 64), recovery.recover(11 * second, 64, 512));
    for (3..10) |i| recovery.pressure(i * second);
    try std.testing.expectEqual(@as(u64, 60 * second), recovery.delay_ns);
    recovery.pressure(100 * second);
    try std.testing.expectEqual(@as(u64, 5 * second), recovery.delay_ns);
    try std.testing.expectEqual(@as(u64, 32), recovery.recover(106 * second, 32, 16));
}
