// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Frame-rate cap shared by the launchers and game-run.
//!
//! The cap holds every completed VideoOut flip to the chosen rate, whether the
//! title flips from the CPU or from its GPU command stream, so the game itself
//! slows down rather than only the window. `unlimited` adds nothing beyond the
//! runtime's existing pacing and is the default, which keeps direct command
//! line runs and earlier settings files behaving as before.
const std = @import("std");

pub const environment_name = "PS5_FPS_LIMIT";

pub const Limit = enum(u8) {
    fps30,
    fps60,
    fps120,
    unlimited,

    /// Frames per second, or zero for no cap.
    pub fn hz(self: Limit) u32 {
        return switch (self) {
            .fps30 => 30,
            .fps60 => 60,
            .fps120 => 120,
            .unlimited => 0,
        };
    }

    /// The value stored as fps_limit= in ps5pcem.ini and passed in
    /// PS5_FPS_LIMIT; zero means no cap.
    pub fn value(self: Limit) [:0]const u8 {
        return switch (self) {
            .fps30 => "30",
            .fps60 => "60",
            .fps120 => "120",
            .unlimited => "0",
        };
    }

    pub fn fromHz(rate: u32) ?Limit {
        for (choices) |limit| if (limit.hz() == rate) return limit;
        return null;
    }

    pub fn parse(text: []const u8) ?Limit {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "unlimited") or std.ascii.eqlIgnoreCase(trimmed, "off")) {
            return .unlimited;
        }
        const rate = std.fmt.parseInt(u32, trimmed, 10) catch return null;
        return fromHz(rate);
    }
};

pub const default: Limit = .unlimited;
/// In the launcher's button order.
pub const choices = [_]Limit{ .fps30, .fps60, .fps120, .unlimited };

test "frame limits keep stable saved values and reject other rates" {
    for (choices) |limit| {
        try std.testing.expectEqual(limit, Limit.parse(limit.value()).?);
        try std.testing.expectEqual(limit, Limit.fromHz(limit.hz()).?);
    }
    try std.testing.expectEqual(Limit.unlimited, Limit.parse(" Unlimited\n").?);
    try std.testing.expectEqual(Limit.unlimited, Limit.parse("off").?);
    try std.testing.expectEqual(Limit.fps60, Limit.parse(" 60 ").?);
    try std.testing.expectEqual(null, Limit.parse("75"));
    try std.testing.expectEqual(null, Limit.parse(""));
    try std.testing.expectEqual(null, Limit.fromHz(144));
    try std.testing.expectEqual(Limit.unlimited, default);
}
