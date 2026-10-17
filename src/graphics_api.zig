// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Stable launch preference shared by the front ends and runtime.
const std = @import("std");

pub const environment_name = "PS5_GRAPHICS_API";
pub const Api = enum {
    vulkan,
    d3d12,

    pub fn value(self: Api) [:0]const u8 {
        return switch (self) {
            .vulkan => "vulkan",
            .d3d12 => "d3d12",
        };
    }

    pub fn label(self: Api) []const u8 {
        return switch (self) {
            .vulkan => "Vulkan",
            .d3d12 => "DirectX 12",
        };
    }

    pub fn supportsPlatform(self: Api, os: std.Target.Os.Tag) bool {
        return switch (self) {
            .vulkan => os == .windows or os == .linux,
            .d3d12 => os == .windows,
        };
    }

    pub fn parse(text: []const u8) ?Api {
        const value_text = std.mem.trim(u8, text, " \t\r\n");
        for (choices) |api| if (std.ascii.eqlIgnoreCase(value_text, api.value())) return api;
        if (std.ascii.eqlIgnoreCase(value_text, "dx12")) return .d3d12;
        return null;
    }
};

pub const default: Api = .vulkan;
pub const choices = [_]Api{ .vulkan, .d3d12 };

test "graphics API persistence keeps stable names and platform restrictions" {
    for (choices) |api| try std.testing.expectEqual(api, Api.parse(api.value()).?);
    try std.testing.expectEqual(Api.d3d12, Api.parse(" DX12 \n").?);
    try std.testing.expectEqual(null, Api.parse("directx11"));
    try std.testing.expectEqual(null, Api.parse(""));
    try std.testing.expect(Api.vulkan.supportsPlatform(.linux));
    try std.testing.expect(!Api.d3d12.supportsPlatform(.linux));
    try std.testing.expect(Api.d3d12.supportsPlatform(.windows));
}
