// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! C++ ABI guards used by title-local static initialization.
//!
//! The genuine libc guard waits while a guard is pending, but does not retain
//! the owner. A replacement heap can re-enter a local-static accessor on the
//! initializing thread while libc itself is still bootstrapping; waiting in
//! that case deadlocks the only thread that can release the guard.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const symbols = @import("../symbols.zig");
const kernel_memory = @import("kernel_memory.zig");

const initialized: u64 = 0x1;
const pending: u64 = 0x100;
const state_mask: u64 = 0xffff;
const maximum_pending_guards = 256;

const PendingGuard = struct {
    address: u64 = 0,
    owner: std.Thread.Id = 0,
};

var pending_lock = std.atomic.Mutex.unlocked;
var pending_guards: [maximum_pending_guards]PendingGuard =
    [_]PendingGuard{.{}} ** maximum_pending_guards;

fn lockPending() void {
    while (!pending_lock.tryLock()) std.atomic.spinLoopHint();
}

fn pendingIndex(address: u64) ?usize {
    for (pending_guards, 0..) |entry, index| {
        if (entry.address == address) return index;
    }
    return null;
}

fn emptyPendingIndex() ?usize {
    for (pending_guards, 0..) |entry, index| {
        if (entry.address == 0) return index;
    }
    return null;
}

fn guardAcquireCore(guard: *u64, owner: std.Thread.Id) i32 {
    const address = @intFromPtr(guard);
    while (true) {
        lockPending();
        const state = guard.*;
        if (state & initialized != 0) {
            pending_lock.unlock();
            return 0;
        }
        if (pendingIndex(address)) |index| {
            if (pending_guards[index].owner == owner) {
                // A recursive initializer cannot wait for itself. Returning
                // zero is worse: it tells the caller that the object is fully
                // constructed, and UE immediately dereferences its still-null
                // singleton. Let the inner invocation perform the
                // initialization; its release also completes the outer guard.
                pending_lock.unlock();
                return 1;
            }
            pending_lock.unlock();
            std.Thread.yield() catch {};
            continue;
        }

        const index = emptyPendingIndex() orelse {
            pending_lock.unlock();
            return 0;
        };
        pending_guards[index] = .{ .address = address, .owner = owner };
        guard.* = (state & ~state_mask) | pending;
        pending_lock.unlock();
        return 1;
    }
}

fn guardCompleteCore(guard: *u64, value: u64) void {
    const address = @intFromPtr(guard);
    lockPending();
    guard.* = value;
    if (pendingIndex(address)) |index| pending_guards[index] = .{};
    pending_lock.unlock();
}

fn checkedGuard(raw: ?*u64) ?*u64 {
    const guard = raw orelse return null;
    const address = @intFromPtr(guard);
    if (address & (@alignOf(u64) - 1) != 0) return null;
    if (!kernel_memory.isGuestRangeAccessible(address, @sizeOf(u64))) return null;
    return guard;
}

fn cxaGuardAcquire(raw: ?*u64) callconv(abi.guest) i32 {
    const guard = checkedGuard(raw) orelse return 0;
    return guardAcquireCore(guard, std.Thread.getCurrentId());
}

fn cxaGuardRelease(raw: ?*u64) callconv(abi.guest) void {
    const guard = checkedGuard(raw) orelse return;
    guardCompleteCore(guard, initialized);
}

fn cxaGuardAbort(raw: ?*u64) callconv(abi.guest) void {
    const guard = checkedGuard(raw) orelse return;
    guardCompleteCore(guard, 0);
}

pub const exports = [_]symbols.Export{
    .{ .name = "__cxa_guard_acquire", .function = trace.wrap("__cxa_guard_acquire", &cxaGuardAcquire), .expect_id = "3GPpjQdAMTw" },
    .{ .name = "__cxa_guard_release", .function = trace.wrap("__cxa_guard_release", &cxaGuardRelease), .expect_id = "9rAeANT2tyE" },
    .{ .name = "__cxa_guard_abort", .function = trace.wrap("__cxa_guard_abort", &cxaGuardAbort), .expect_id = "2emaaluWzUw" },
};

pub const library = symbols.Library{ .name = "libc", .version = 1 };
pub const module = symbols.Module{ .name = "libc", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

test "a recursive guard acquire lets the inner initializer finish" {
    var guard: u64 = 0;
    const owner = std.Thread.getCurrentId();

    try std.testing.expectEqual(@as(i32, 1), guardAcquireCore(&guard, owner));
    try std.testing.expectEqual(pending, guard);
    try std.testing.expectEqual(@as(i32, 1), guardAcquireCore(&guard, owner));

    guardCompleteCore(&guard, initialized);
    try std.testing.expectEqual(@as(i32, 0), guardAcquireCore(&guard, owner));
}

test "an aborted guard can be acquired again" {
    var guard: u64 = 0;
    const owner = std.Thread.getCurrentId();

    try std.testing.expectEqual(@as(i32, 1), guardAcquireCore(&guard, owner));
    guardCompleteCore(&guard, 0);
    try std.testing.expectEqual(@as(i32, 1), guardAcquireCore(&guard, owner));
    guardCompleteCore(&guard, initialized);
}
