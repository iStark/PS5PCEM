// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Launch-time rendering preference shared by the launcher and game-run.
//! The guest picks its own internal resolution and detail, exactly as it
//! does on the console. These presets select host-side trade-offs instead:
//! `speed` admits emulation shortcuts whose cost is occasional fidelity,
//! `graphics` keeps the conservative paths that reproduce guest output most
//! faithfully. Individual PS5_GPU_* variables still override either preset.
const std = @import("std");

pub const environment_name = "PS5_PERFORMANCE_MODE";

pub const Mode = enum(u8) {
    speed = 0,
    graphics = 1,

    pub fn value(self: Mode) [:0]const u8 {
        return switch (self) {
            .speed => "speed",
            .graphics => "graphics",
        };
    }

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .speed => "Speed",
            .graphics => "Graphics",
        };
    }

    /// Whether the preset admits host-side shortcuts that trade a small
    /// amount of fidelity for throughput.
    pub fn favorsSpeed(self: Mode) bool {
        return self == .speed;
    }

    pub fn fromIndex(index: usize) ?Mode {
        if (index >= choices.len) return null;
        return choices[index];
    }

    pub fn parse(value_text: []const u8) ?Mode {
        const trimmed = std.mem.trim(u8, value_text, " \t\r\n");
        for (choices) |mode| {
            if (std.ascii.eqlIgnoreCase(trimmed, mode.value()) or
                std.ascii.eqlIgnoreCase(trimmed, mode.label())) return mode;
        }
        // The launcher persists the enum tag, so accept it too rather than
        // silently dropping a saved preference back to the default.
        const tag = std.fmt.parseInt(u8, trimmed, 10) catch return null;
        for (choices) |mode| {
            if (tag == @intFromEnum(mode)) return mode;
        }
        return null;
    }
};

pub const default: Mode = .speed;
pub const choices = [_]Mode{ .speed, .graphics };

test "performance presets round trip and default to speed" {
    try std.testing.expectEqual(Mode.speed, default);
    try std.testing.expect(default.favorsSpeed());
    try std.testing.expect(!Mode.graphics.favorsSpeed());
    for (choices, 0..) |mode, index| {
        try std.testing.expectEqual(mode, Mode.parse(mode.value()).?);
        try std.testing.expectEqual(mode, Mode.parse(mode.label()).?);
        try std.testing.expectEqual(mode, Mode.fromIndex(index).?);
    }
    try std.testing.expectEqual(Mode.graphics, Mode.parse(" GRAPHICS ").?);
    try std.testing.expectEqual(Mode.speed, Mode.parse("0").?);
    try std.testing.expectEqual(Mode.graphics, Mode.parse("1").?);
    try std.testing.expectEqual(null, Mode.fromIndex(2));
    try std.testing.expectEqual(null, Mode.parse("2"));
    try std.testing.expectEqual(null, Mode.parse(""));
    try std.testing.expectEqual(null, Mode.parse("balanced"));
}
