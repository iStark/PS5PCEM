// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Launch-time output preferences shared by the launcher and game-run.
//! These describe the display, not the dimensions of guest render targets.
const std = @import("std");

pub const environment_name = "PS5_OUTPUT_RESOLUTION";
pub const Mode = enum(u16) {
    full_hd = 1080,
    qhd = 1440,
    ultra_hd = 2160,
    eight_k = 4320,

    pub fn width(self: Mode) u32 {
        return self.height() * 16 / 9;
    }

    pub fn height(self: Mode) u32 {
        return @intFromEnum(self);
    }

    pub fn value(self: Mode) [:0]const u8 {
        return switch (self) {
            .full_hd => "1080",
            .qhd => "1440",
            .ultra_hd => "2160",
            .eight_k => "4320",
        };
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .full_hd => "1080p",
            .qhd => "1440p",
            .ultra_hd => "4K",
            .eight_k => "8K",
        };
    }

    pub fn fromHeight(height_value: u32) ?Mode {
        for (choices) |mode| {
            if (height_value == mode.height()) return mode;
        }
        return null;
    }

    pub fn parse(value_text: []const u8) ?Mode {
        const trimmed = std.mem.trim(u8, value_text, " \t\r\n");
        for (choices) |mode| {
            if (std.ascii.eqlIgnoreCase(trimmed, mode.value()) or
                std.ascii.eqlIgnoreCase(trimmed, mode.label())) return mode;
        }
        return null;
    }
};

pub const default: Mode = .full_hd;
pub const choices = [_]Mode{ .full_hd, .qhd, .ultra_hd, .eight_k };

test "output preferences round trip without accepting invalid saved values" {
    try std.testing.expectEqual(@as(u32, 1920), default.width());
    try std.testing.expectEqual(@as(u32, 1080), default.height());
    for (choices) |mode| {
        try std.testing.expectEqual(mode, Mode.parse(mode.value()).?);
        try std.testing.expectEqual(mode, Mode.parse(mode.label()).?);
        try std.testing.expectEqual(mode, Mode.fromHeight(mode.height()).?);
    }
    try std.testing.expectEqual(Mode.ultra_hd, Mode.parse(" 4k ").?);
    try std.testing.expectEqual(null, Mode.parse("auto"));
    try std.testing.expectEqual(null, Mode.parse(""));
    try std.testing.expectEqual(null, Mode.fromHeight(66616)); // Must not wrap to 1080.
}
