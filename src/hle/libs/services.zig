// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The services a shipped title asks for that this machine does not have.
//!
//! A large title links against a great deal it will happily run without: an
//! online account system, a headset, a store, a voice channel, an accelerator.
//! None of it exists here. But a missing import stops a module from linking at
//! all, so until each one is answered the title cannot start far enough to reach
//! the parts that do work.
//!
//! What every answer here has in common is that it tells the title the facility
//! is not available, rather than that the operation succeeded. That distinction
//! is the whole point. A title told its request succeeded goes looking for a
//! result nothing produced — a session it can join, a headset pose to read, a
//! file the accelerator was to have fetched — and fails somewhere with nothing
//! pointing back here. A title told the facility is absent takes the path it
//! already has for a console with no network, no peripheral and no entitlement,
//! which is a path its own authors wrote and tested.
//!
//! The differences below are only in what "not here" looks like from the
//! caller's side.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_memory = @import("kernel_memory.zig");

/// Status a service library returns when it has not been, and cannot be,
/// brought up.
///
/// The platform gives each library its own numbering, and inventing a code
/// inside one of those spaces would be a guess a title might act on. This is
/// the kernel's own "not implemented", which is outside every library's space
/// and therefore cannot be mistaken for one of its documented outcomes: a
/// caller sees a failure it does not recognise, which is exactly what it is.
const unavailable: i32 = @intFromEnum(errno.KernelError.enosys);

/// A service that is not present on this machine.
pub fn absent(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return unavailable;
}

/// Anything that needs a network connection.
///
/// Answered the same way as an absent service rather than as a transient
/// network error, because a transient one invites a title to retry forever.
pub fn offline(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return unavailable;
}

/// Hardware that is not attached — a headset, a tracker, an extra pad.
pub fn noDevice(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return unavailable;
}

/// Boolean device probes return false without manufacturing an error path.
pub fn notAttached(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return 0;
}

/// Bookkeeping that changes nothing observable and has nothing to report back.
///
/// Kept apart from the refusals on purpose: refusing a title's attempt to, say,
/// release something it allocated would leave it believing the thing is still
/// live. Nothing here hands back a value a caller then follows.
pub fn accept(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

/// UDS is an offline telemetry sink here, but its bootstrap objects are still
/// real from the title's point of view. Initialisation validates the parameter
/// record and context creation supplies the handle later calls carry around.
pub fn udsInitialize(parameters: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (parameters == 0) return @bitCast(@as(u32, 0x8055_3102));
    if (!kernel_memory.isGuestRangeAccessible(parameters, 16)) return errno.KernelError.efault.raw();
    return errno.ok;
}

pub fn udsCreateContext(output: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (output == 0) return errno.ok;
    if (!kernel_memory.isGuestRangeAccessible(output, @sizeOf(i32))) {
        return errno.KernelError.efault.raw();
    }
    const handle: *i32 = @ptrFromInt(output);
    handle.* = 1;
    return errno.ok;
}

var uds_next_handle = std.atomic.Value(i32).init(1);

/// SDK revisions place the created UDS handle in either the first or second
/// argument. Write the first accessible output, matching the firmware's
/// compatibility behaviour without uploading any telemetry.
pub fn udsCreateHandle(first: u64, second: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    const output = if (first != 0 and kernel_memory.isGuestRangeAccessible(first, @sizeOf(i32)))
        first
    else if (second != 0 and kernel_memory.isGuestRangeAccessible(second, @sizeOf(i32)))
        second
    else
        return errno.KernelError.efault.raw();
    const handle: *i32 = @ptrFromInt(output);
    handle.* = uds_next_handle.fetchAdd(1, .acq_rel);
    return errno.ok;
}

pub fn udsCreateEvent(_: u64, _: u64, third: u64, fourth: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    const output = if (third != 0 and kernel_memory.isGuestRangeAccessible(third, @sizeOf(i32)))
        third
    else if (fourth != 0 and kernel_memory.isGuestRangeAccessible(fourth, @sizeOf(i32)))
        fourth
    else
        return errno.KernelError.efault.raw();
    const handle: *i32 = @ptrFromInt(output);
    handle.* = uds_next_handle.fetchAdd(1, .acq_rel);
    return errno.ok;
}

/// There is no host save-data dialog yet, so an opened dialog is considered
/// dismissed by the time the title polls it.  Returning FINISHED avoids the
/// Unity save plug-in waiting forever for UI that cannot be displayed.
pub fn saveDataDialogFinished(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return 3;
}

/// A headless dialog can always be serviced immediately.
pub fn saveDataDialogReady(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return 1;
}

/// Save-data event queues are empty until persistent storage is implemented.
/// This is the platform's normal NOT_FOUND/no-event result, not ENOSYS, and is
/// therefore safe for polling workers.
pub fn saveDataNoEvent(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return @bitCast(@as(u32, 0x809f0008));
}

const np_game_intent_error_invalid_argument: i32 = @bitCast(@as(u32, 0x8055_3804));
const np_game_intent_error_intent_not_found: i32 = @bitCast(@as(u32, 0x8055_3806));
const np_game_intent_error_value_not_found: i32 = @bitCast(@as(u32, 0x8055_3807));

const NpGameIntentData = extern struct {
    data: [16 * 1024 + 1]u8,
    padding: [7]u8,
};

const NpGameIntentInfo = extern struct {
    size: usize,
    user_id: i32,
    intent_type: [33]u8,
    padding: [7]u8,
    reserved: [256]u8,
    intent_data: NpGameIntentData,
};

/// Game Intent is available even when PlayStation Network is offline.  There
/// simply is no launch intent to deliver for a title started from this runner.
pub fn npGameIntentInitialize(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

pub fn npGameIntentTerminate(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

pub fn npGameIntentReceiveIntent(info_address: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (info_address == 0) return np_game_intent_error_invalid_argument;
    if (!kernel_memory.isGuestRangeAccessible(info_address, @sizeOf(NpGameIntentInfo))) {
        return errno.KernelError.efault.raw();
    }

    const info: *NpGameIntentInfo = @ptrFromInt(info_address);
    info.user_id = -1;
    @memset(&info.intent_type, 0);
    @memset(&info.intent_data.data, 0);
    @memset(&info.intent_data.padding, 0);
    return np_game_intent_error_intent_not_found;
}

pub fn npGameIntentGetPropertyValueString(
    intent_data_address: u64,
    key_address: u64,
    value_address: u64,
    value_size: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (intent_data_address == 0 or key_address == 0 or value_address == 0 or value_size == 0) {
        return np_game_intent_error_invalid_argument;
    }
    if (!kernel_memory.isGuestRangeAccessible(intent_data_address, @sizeOf(NpGameIntentData)) or
        !kernel_memory.isGuestRangeAccessible(key_address, 1) or
        !kernel_memory.isGuestRangeAccessible(value_address, 1))
    {
        return errno.KernelError.efault.raw();
    }

    const value: *u8 = @ptrFromInt(value_address);
    value.* = 0;
    return np_game_intent_error_value_not_found;
}

const table = @import("services_table.zig");

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    inline for (table.all) |entry| {
        try db.addLibrary(
            gpa,
            .{ .name = entry.library, .version = 1 },
            .{ .name = entry.module, .version_major = 1, .version_minor = 1 },
            entry.exports,
        );
    }
}

/// How many entry points this module answers, across every library.
pub fn count() usize {
    var total: usize = 0;
    inline for (table.all) |entry| total += entry.exports.len;
    return total;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "an absent service reports absence rather than success" {
    // A title told its request succeeded goes looking for a result nothing
    // produced, and fails somewhere with nothing pointing back here.
    try testing.expect(absent(0, 0, 0, 0, 0, 0) < 0);
    try testing.expect(offline(0, 0, 0, 0, 0, 0) < 0);
    try testing.expect(noDevice(0, 0, 0, 0, 0, 0) < 0);
    try testing.expectEqual(errno.ok, accept(0, 0, 0, 0, 0, 0));
}

test "the refusal sits outside every library's own numbering" {
    // Each service library numbers its errors in a space of its own. A code
    // invented inside one of those spaces could be mistaken for a documented
    // outcome and acted on; this one cannot.
    const status: u32 = @bitCast(unavailable);
    try testing.expectEqual(@as(u32, 0x8002_004e), status);
}

test "game intent ABI and offline outcomes match the platform" {
    try testing.expectEqual(@as(usize, 16_392), @sizeOf(NpGameIntentData));
    try testing.expectEqual(@as(usize, 16_704), @sizeOf(NpGameIntentInfo));
    try testing.expectEqual(errno.ok, npGameIntentInitialize(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(errno.ok, npGameIntentTerminate(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(np_game_intent_error_invalid_argument, npGameIntentReceiveIntent(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(np_game_intent_error_invalid_argument, npGameIntentGetPropertyValueString(0, 0, 0, 0, 0, 0));
}

test "every service entry point registers under its published identifier" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(count(), db.count());
    try testing.expect(count() > 300);
}
