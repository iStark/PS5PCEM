// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const vk = @import("api.zig");

pub export var timeline_poll_budget_ns: u64 = 50_000;

/// A short zero-timeout Vulkan wait can finish without parking the owner.
/// Every successful path still performs the real semaphore wait operation.
/// Bounds on time and call count retain a blocking fallback for long work,
/// timer regressions and timers whose resolution is coarser than the budget.
pub fn wait(context: anytype, requested_ns: u64) vk.Result {
    const budget = @min(requested_ns, 200_000);
    if (budget == 0) return context.call(std.math.maxInt(u64));
    const started = context.now();
    for (0..128) |_| {
        const current = context.now();
        if (current < started or current - started >= budget) break;
        const result = context.call(0);
        if (result != vk.timeout) return result;
        std.atomic.spinLoopHint();
    }
    return context.call(std.math.maxInt(u64));
}

test "bounded timeline polling retains real waits errors and long-work fallback" {
    const Mock = struct {
        time: u64 = 100,
        step: u64 = 2,
        polls: usize = 0,
        blocks: usize = 0,
        ready_after: usize = 0,
        answer: vk.Result = vk.success,
        regress: bool = false,
        fn now(self: *@This()) u64 {
            const result = self.time;
            if (self.regress) self.time -|= self.step else self.time +|= self.step;
            return result;
        }
        fn call(self: *@This(), timeout: u64) vk.Result {
            if (timeout != 0) {
                std.debug.assert(timeout == std.math.maxInt(u64));
                self.blocks += 1;
                return self.answer;
            }
            self.polls += 1;
            return if (self.polls > self.ready_after) self.answer else vk.timeout;
        }
    };
    var immediate = Mock{};
    try std.testing.expectEqual(vk.success, wait(&immediate, 20));
    try std.testing.expectEqual(@as(usize, 1), immediate.polls);
    try std.testing.expectEqual(@as(usize, 0), immediate.blocks);
    var soon = Mock{ .ready_after = 3 };
    try std.testing.expectEqual(vk.success, wait(&soon, 20));
    try std.testing.expectEqual(@as(usize, 4), soon.polls);
    try std.testing.expectEqual(@as(usize, 0), soon.blocks);
    var long = Mock{ .ready_after = 1000 };
    try std.testing.expectEqual(vk.success, wait(&long, 20));
    try std.testing.expectEqual(@as(usize, 9), long.polls);
    try std.testing.expectEqual(@as(usize, 1), long.blocks);
    var disabled = Mock{};
    try std.testing.expectEqual(vk.success, wait(&disabled, 0));
    try std.testing.expectEqual(@as(usize, 0), disabled.polls);
    try std.testing.expectEqual(@as(usize, 1), disabled.blocks);
    for ([_]vk.Result{ vk.error_device_lost, vk.error_out_of_host_memory }) |failure| {
        var failed = Mock{ .answer = failure };
        try std.testing.expectEqual(failure, wait(&failed, 20));
        try std.testing.expectEqual(@as(usize, 1), failed.polls);
        try std.testing.expectEqual(@as(usize, 0), failed.blocks);
    }
    var stalled = Mock{ .step = 0, .ready_after = 1000 };
    try std.testing.expectEqual(vk.success, wait(&stalled, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 128), stalled.polls);
    try std.testing.expectEqual(@as(usize, 1), stalled.blocks);
    var backwards = Mock{ .regress = true };
    try std.testing.expectEqual(vk.success, wait(&backwards, 20));
    try std.testing.expectEqual(@as(usize, 0), backwards.polls);
    try std.testing.expectEqual(@as(usize, 1), backwards.blocks);
}
