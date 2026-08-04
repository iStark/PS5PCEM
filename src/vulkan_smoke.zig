// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Runs the host-only Vulkan compute/staging/readback probe.

const std = @import("std");
const vulkan = @import("vulkan");

fn rejectGuestRead(_: ?*anyopaque, _: u64, _: []u8) bool {
    return false;
}

fn rejectGuestWrite(_: ?*anyopaque, _: u64, _: []const u8) bool {
    return false;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    _ = renderer.dcbBackend(.{
        .context = null,
        .read = rejectGuestRead,
        .write = rejectGuestWrite,
    });
    const report = try renderer.smokeTest();

    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &output.interface;
    try writer.print(
        "Vulkan {d}.{d}.{d}: {s}\n" ++
            "device API {d}.{d}.{d}, queue family {d}, validation {s}\n" ++
            "headless smoke passed: {d} compute dispatch, {d} staging bytes copied and verified\n",
        .{
            vulkan.api.apiMajor(renderer.loader_api_version),
            vulkan.api.apiMinor(renderer.loader_api_version),
            vulkan.api.apiPatch(renderer.loader_api_version),
            renderer.device_info.name(),
            vulkan.api.apiMajor(renderer.device_info.api_version),
            vulkan.api.apiMinor(renderer.device_info.api_version),
            vulkan.api.apiPatch(renderer.device_info.api_version),
            report.queue_family_index,
            if (renderer.validation_enabled) "on" else "off",
            report.compute_dispatches,
            report.bytes_copied,
        },
    );
    try writer.flush();
}
