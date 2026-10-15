// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const vk = @import("api.zig");

pub export var timeline_poll_budget_ns: u64 = 50_000;
pub export var counter_timeline_polling: bool = true;
pub export var counter_timeline_completions: u64 = 0;

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
        const result = if (@hasDecl(@TypeOf(context.*), "query") and
            @atomicLoad(bool, &counter_timeline_polling, .monotonic))
        queried: {
            // A counter observation is only a readiness hint. Completion still
            // requires the real Vulkan wait, including its error result.
            const ready = context.query();
            if (ready != vk.success) break :queried ready;
            const waited = context.call(0);
            if (waited == vk.success)
                _ = @atomicRmw(u64, &counter_timeline_completions, .Add, 1, .monotonic);
            break :queried waited;
        } else context.call(0);
        if (result != vk.timeout) return result;
        std.atomic.spinLoopHint();
    }
    return context.call(std.math.maxInt(u64));
}

test "timeline counter hints retain real waits and bounded fallbacks" {
    const saved = counter_timeline_polling;
    defer counter_timeline_polling = saved;
    counter_timeline_polling = true;
    const Mock = struct {
        time: u64 = 0,
        step: u64 = 2,
        queries: usize = 0,
        polls: usize = 0,
        blocks: usize = 0,
        ready_after: usize = 3,
        query_error: vk.Result = vk.success,
        wait_answer: vk.Result = vk.success,
        fn now(self: *@This()) u64 {
            self.time += self.step;
            return self.time;
        }
        fn query(self: *@This()) vk.Result {
            self.queries += 1;
            if (self.query_error != vk.success) return self.query_error;
            return if (self.queries > self.ready_after) vk.success else vk.timeout;
        }
        fn call(self: *@This(), timeout: u64) vk.Result {
            if (timeout == 0) self.polls += 1 else self.blocks += 1;
            return self.wait_answer;
        }
    };
    var soon = Mock{};
    try std.testing.expectEqual(vk.success, wait(&soon, 20));
    try std.testing.expectEqual(@as(usize, 4), soon.queries);
    try std.testing.expectEqual(@as(usize, 1), soon.polls);
    try std.testing.expectEqual(@as(usize, 0), soon.blocks);
    var long = Mock{ .ready_after = 1000 };
    try std.testing.expectEqual(vk.success, wait(&long, 20));
    try std.testing.expectEqual(@as(usize, 9), long.queries);
    try std.testing.expectEqual(@as(usize, 0), long.polls);
    try std.testing.expectEqual(@as(usize, 1), long.blocks);
    var stalled = Mock{ .ready_after = 1000, .step = 0 };
    try std.testing.expectEqual(vk.success, wait(&stalled, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 128), stalled.queries);
    try std.testing.expectEqual(@as(usize, 1), stalled.blocks);
    var disabled = Mock{};
    try std.testing.expectEqual(vk.success, wait(&disabled, 0));
    try std.testing.expectEqual(@as(usize, 0), disabled.queries);
    try std.testing.expectEqual(@as(usize, 1), disabled.blocks);
    for ([_]vk.Result{ vk.error_device_lost, vk.error_out_of_host_memory }) |failure| {
        var query_failed = Mock{ .query_error = failure };
        try std.testing.expectEqual(failure, wait(&query_failed, 20));
        try std.testing.expectEqual(@as(usize, 0), query_failed.polls + query_failed.blocks);
        var wait_failed = Mock{ .ready_after = 0, .wait_answer = failure };
        try std.testing.expectEqual(failure, wait(&wait_failed, 20));
        try std.testing.expectEqual(@as(usize, 1), wait_failed.polls);
    }
    // Even an optimistic readiness hint cannot turn a timed-out wait into success.
    var premature = Mock{ .ready_after = 0, .wait_answer = vk.timeout };
    try std.testing.expectEqual(vk.timeout, wait(&premature, 20));
    try std.testing.expectEqual(@as(usize, 9), premature.polls);
    try std.testing.expectEqual(@as(usize, 1), premature.blocks);
    counter_timeline_polling = false;
    var previous = Mock{};
    try std.testing.expectEqual(vk.success, wait(&previous, 20));
    try std.testing.expectEqual(@as(usize, 0), previous.queries);
    try std.testing.expectEqual(@as(usize, 1), previous.polls);
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
