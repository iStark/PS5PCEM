// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Deterministic admission policy; all calls are under the CPU queue lock.
//! Limits affect new jobs only. Idle OS threads remain asleep and reusable.
const std = @import("std");

pub const Policy = struct {
    pub const interval_ns = 100 * std.time.ns_per_ms;
    pub const idle_ns = 500 * std.time.ns_per_ms;
    pub const minimum_job_ns = 25 * std.time.ns_per_us;
    enabled: bool = false,
    limit: usize = 1,
    last_change: u64 = 0,
    last_activity: u64 = 0,
    average_job_ns: u64 = 0,
    average_wait_ns: u64 = 0,
    samples: u64 = 0,
    increases: u64 = 0,
    decreases: u64 = 0,

    pub fn complete(self: *Policy, now: u64, work: u64, wait: u64) void {
        self.average_job_ns = average(self.average_job_ns, work, self.samples);
        self.average_wait_ns = average(self.average_wait_ns, wait, self.samples);
        self.samples +|= 1;
        self.last_activity = now;
    }

    pub fn update(self: *Policy, now: u64, ceiling: usize, outstanding: usize, oldest_wait: u64) usize {
        const cap = @max(ceiling, 1);
        self.limit = @min(self.limit, cap);
        if (!self.enabled) return cap;
        if (now -| self.last_change < interval_ns) return self.limit;
        const idle = outstanding == 0 and now -| self.last_activity >= idle_ns;
        const cheap = self.samples >= 16 and self.average_job_ns < minimum_job_ns;
        if (self.limit > 1 and (idle or cheap)) {
            self.limit -= 1;
            self.decreases += 1;
            self.last_change = now;
        } else if (!cheap and self.limit < cap and outstanding > self.limit and
            (oldest_wait >= 2 * std.time.ns_per_ms or
                (self.samples >= 4 and self.average_job_ns >= minimum_job_ns and
                    self.average_wait_ns >= self.average_job_ns / 4)))
        {
            self.limit += 1;
            self.increases += 1;
            self.last_change = now;
        }
        return self.limit;
    }

    fn average(previous: u64, sample: u64, count: u64) u64 {
        if (count == 0) return sample;
        return previous - previous / 8 + sample / 8;
    }
};

pub const Limits = struct { resources: usize, compilers: usize };

/// Reserve two logical CPUs for the renderer, guest and driver where possible.
/// Each pool has at most four independent jobs; manual overrides are separate.
pub fn defaults(logical_cpus: usize) Limits {
    if (logical_cpus <= 2) return .{ .resources = 0, .compilers = 1 };
    const budget = @max(logical_cpus - 2, 2);
    return .{ .resources = @min(4, (budget + 1) / 2), .compilers = @min(4, budget / 2) };
}

test "adaptive workers grow under queue pressure with hysteresis and a ceiling" {
    var policy = Policy{ .enabled = true };
    for (0..16) |_| policy.complete(1, 100_000, 100_000);
    try std.testing.expectEqual(@as(usize, 2), policy.update(Policy.interval_ns, 4, 8, 0));
    try std.testing.expectEqual(@as(usize, 2), policy.update(Policy.interval_ns + 1, 4, 8, 0));
    try std.testing.expectEqual(@as(usize, 3), policy.update(2 * Policy.interval_ns, 4, 8, 0));
    try std.testing.expectEqual(@as(usize, 4), policy.update(3 * Policy.interval_ns, 4, 8, 0));
    try std.testing.expectEqual(@as(usize, 4), policy.update(4 * Policy.interval_ns, 4, 8, 0));
    try std.testing.expectEqual(@as(usize, 2), policy.update(5 * Policy.interval_ns, 2, 8, 0));
}

test "adaptive workers shrink for cheap or idle work and fixed limits remain exact" {
    var policy = Policy{ .enabled = true, .limit = 4 };
    for (0..16) |_| policy.complete(1, 1_000, 100_000);
    try std.testing.expectEqual(@as(usize, 3), policy.update(Policy.interval_ns, 4, 8, 0));
    try std.testing.expectEqual(@as(usize, 2), policy.update(2 * Policy.interval_ns, 4, 8, 0));
    try std.testing.expectEqual(@as(usize, 1), policy.update(3 * Policy.interval_ns, 4, 8, 0));
    policy.limit = 2;
    policy.samples = 0;
    try std.testing.expectEqual(@as(usize, 1), policy.update(Policy.idle_ns + 1, 4, 0, 0));
    policy.enabled = false;
    try std.testing.expectEqual(@as(usize, 4), policy.update(Policy.idle_ns + 2, 4, 0, 0));
    try std.testing.expectEqual(Limits{ .resources = 0, .compilers = 1 }, defaults(2));
    try std.testing.expectEqual(Limits{ .resources = 1, .compilers = 1 }, defaults(4));
    try std.testing.expectEqual(Limits{ .resources = 4, .compilers = 4 }, defaults(16));
}
