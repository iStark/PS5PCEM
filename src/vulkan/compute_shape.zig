// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Preserve the guest workgroup's linear invocation order within host limits.
const std = @import("std");

pub fn fit(guest: [3]u32, limits: [3]u32, maximum_invocations: u32) error{InvalidComputeWorkgroup}!?[3]u32 {
    var total: u32 = 1;
    var fits = true;
    for (guest, limits) |size, limit| {
        if (size == 0 or limit == 0) return error.InvalidComputeWorkgroup;
        total = std.math.mul(u32, total, size) catch return error.InvalidComputeWorkgroup;
        fits = fits and size <= limit;
    }
    if (total > maximum_invocations) return error.InvalidComputeWorkgroup;
    if (fits) return null;
    var x = @min(total, limits[0]);
    while (x != 0) : (x -= 1) {
        if (total % x != 0) continue;
        const remaining = total / x;
        var y = @min(remaining, limits[1]);
        while (y != 0) : (y -= 1) {
            if (remaining % y == 0 and remaining / y <= limits[2]) return .{ x, y, remaining / y };
        }
    }
    return error.InvalidComputeWorkgroup;
}

test "compute shape preserves valid dimensions and reshapes an oversized Z axis" {
    try std.testing.expectEqual(@as(?[3]u32, null), try fit(.{ 8, 8, 1 }, .{ 1024, 1024, 64 }, 1024));
    try std.testing.expectEqual(@as(?[3]u32, .{ 256, 1, 1 }), try fit(.{ 1, 1, 256 }, .{ 1024, 1024, 64 }, 1024));
    try std.testing.expectEqual(@as(?[3]u32, .{ 128, 2, 1 }), try fit(.{ 1, 1, 256 }, .{ 128, 128, 64 }, 256));
    try std.testing.expectEqual(@as(?[3]u32, .{ 4, 3, 2 }), try fit(.{ 1, 1, 24 }, .{ 4, 3, 2 }, 24));
    try std.testing.expectError(error.InvalidComputeWorkgroup, fit(.{ 0, 1, 1 }, .{ 1024, 1024, 64 }, 1024));
    try std.testing.expectError(error.InvalidComputeWorkgroup, fit(.{ 64, 64, 1 }, .{ 1024, 1024, 64 }, 1024));
    try std.testing.expectError(error.InvalidComputeWorkgroup, fit(.{ 1, 1, 17 }, .{ 4, 4, 4 }, 64));
    try std.testing.expectError(error.InvalidComputeWorkgroup, fit(.{ 65536, 65536, 1 }, .{ 65536, 65536, 64 }, 1024));
}
