// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The console's settings store, as a title sees it.
//!
//! Firmware libraries read a handful of settings from here during startup —
//! display preferences, regional options, developer switches. Every read is
//! answered as "no such entry", which is a state the console itself can be in
//! and which every caller already handles: a setting that was never written has
//! no value, and the caller falls back to its own default.
//!
//! That is deliberately different from returning a made-up value. A fabricated
//! setting is indistinguishable from a real one, so a title configures itself
//! from it and behaves in ways nothing here can explain.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

/// Reported when a setting has never been written.
pub const entry_not_found: i32 = @bitCast(@as(u32, 0x8006_0002));

/// Reads an integer setting on behalf of a non-system caller.
///
/// The output is deliberately left untouched: a caller that ignores the status
/// and reads its buffer anyway sees whatever default it put there, rather than
/// a value this layer invented.
fn nonSysGetInt(_: u32, _: u64) callconv(abi.guest) i32 {
    return entry_not_found;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceRegMgrNonSysGetInt", .function = trace.wrap("sceRegMgrNonSysGetInt", &nonSysGetInt), .expect_id = "dKeshzt29G4" },
};

pub const library = symbols.Library{ .name = "libSceRegMgr", .version = 1 };
pub const module = symbols.Module{ .name = "libSceRegMgr", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

const testing = std.testing;

test "a setting that was never written has no value" {
    // The console itself reports this, and every caller already handles it.
    try testing.expectEqual(entry_not_found, nonSysGetInt(1, 0));
    try testing.expect(entry_not_found < 0);
}

test "registry exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expect(db.findByName("sceRegMgrNonSysGetInt", .function) != null);
}
