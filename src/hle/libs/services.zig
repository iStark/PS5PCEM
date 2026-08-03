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

/// Bookkeeping that changes nothing observable and has nothing to report back.
///
/// Kept apart from the refusals on purpose: refusing a title's attempt to, say,
/// release something it allocated would leave it believing the thing is still
/// live. Nothing here hands back a value a caller then follows.
pub fn accept(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
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

test "every service entry point registers under its published identifier" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(count(), db.count());
    try testing.expect(count() > 300);
}
