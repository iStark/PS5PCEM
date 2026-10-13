// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Local Share policy and lifecycle. No console capture backend is attached;
//! capture requests fail explicitly without issuing an event or request ID.
const std = @import("std");
const memory = @import("memory");
const abi = @import("../abi.zig");
const font = @import("font.zig");
const invalid: i32 = @bitCast(@as(u32, 0x81960002));
const unsupported: i32 = @bitCast(@as(u32, 0x81960007));
const busy = @intFromEnum(@import("../errno.zig").KernelError.ebusy);
const Callback = struct { function: usize, argument: usize };
var lock: memory.HostMutex = .{};
var initialized = false;
var permitted: u32 = 0xffffffff;
var callbacks: [16]?Callback = @splat(null);
var content: [4096]u8 = @splat(0);

pub fn reset() void {
    lock.lock();
    defer lock.unlock();
    initialized = false;
    permitted = 0xffffffff;
    callbacks = @splat(null);
    content = @splat(0);
}
pub fn initialize(heap_size: usize, priority: i32, affinity: u64) callconv(abi.guest) i32 {
    if (heap_size == 0 or priority < 0 or affinity == 0) return invalid;
    lock.lock();
    defer lock.unlock();
    if (initialized) return busy;
    initialized = true;
    return 0;
}
pub fn terminate() callconv(abi.guest) i32 {
    reset();
    return 0;
}
pub fn permit(flags: u32) callconv(abi.guest) i32 {
    if (flags == 0) return invalid;
    lock.lock();
    defer lock.unlock();
    permitted |= flags;
    return 0;
}
pub fn prohibit(flags: u32) callconv(abi.guest) i32 {
    if (flags == 0) return invalid;
    lock.lock();
    defer lock.unlock();
    permitted &= ~flags;
    return 0;
}
pub fn registerCallback(function: usize, argument: usize) callconv(abi.guest) i32 {
    if (function == 0) return invalid;
    lock.lock();
    defer lock.unlock();
    for (&callbacks) |*entry| if (entry.*) |c| {
        if (c.function == function) {
            entry.* = .{ .function = function, .argument = argument };
            return 0;
        }
    };
    for (&callbacks) |*entry| if (entry.* == null) {
        entry.* = .{ .function = function, .argument = argument };
        return 0;
    };
    return busy;
}
pub fn unregisterCallback(function: usize) callconv(abi.guest) i32 {
    if (function == 0) return invalid;
    lock.lock();
    defer lock.unlock();
    for (&callbacks) |*entry| if (entry.*) |c| {
        if (c.function == function) entry.* = null;
    };
    return 0;
}
pub fn setContentParam(address: usize) callconv(abi.guest) i32 {
    var copy: [4096]u8 = @splat(0);
    for (&copy, 0..) |*byte, i| {
        const current = std.math.add(usize, address, i) catch return invalid;
        if (!font.readable(current, 1)) return invalid;
        byte.* = @as(*const u8, @ptrFromInt(current)).*;
        if (byte.* == 0) {
            lock.lock();
            defer lock.unlock();
            content = copy;
            return 0;
        }
    }
    return invalid;
}
pub fn capture(_: usize, request_id: ?*i32) callconv(abi.guest) i32 {
    if (request_id) |id| {
        if (!font.writable(@intFromPtr(id), @sizeOf(i32))) return invalid;
        font.notifyWrite(@intFromPtr(id), @sizeOf(i32));
        id.* = -1;
    }
    return unsupported;
}

test "share policy lifecycle never reports a successful capture" {
    reset();
    defer reset();
    try std.testing.expectEqual(invalid, initialize(0, 700, 1));
    try std.testing.expectEqual(@as(i32, 0), initialize(0x20000, 700, 0x1fff));
    try std.testing.expectEqual(busy, initialize(0x20000, 700, 1));
    try std.testing.expectEqual(@as(i32, 0), prohibit(3));
    try std.testing.expectEqual(@as(u32, 0xfffffffc), permitted);
    try std.testing.expectEqual(@as(i32, 0), permit(1));
    try std.testing.expectEqual(@as(u32, 0xfffffffd), permitted);
    try std.testing.expectEqual(@as(i32, 0), registerCallback(123, 456));
    try std.testing.expectEqual(@as(usize, 456), callbacks[0].?.argument);
    var request: i32 = 99;
    try std.testing.expectEqual(unsupported, capture(0, &request));
    try std.testing.expectEqual(@as(i32, -1), request);
    try std.testing.expectEqual(@as(i32, 0), terminate());
    try std.testing.expect(!initialized and callbacks[0] == null);
}
