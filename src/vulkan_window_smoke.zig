// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Presents a host-generated frame through the Win32 Vulkan swapchain path.

const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("gpu");
const vulkan = @import("vulkan");
const window = @import("window");

const frame_width: u32 = 320;
const frame_height: u32 = 180;

const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "user32" fn SetWindowPos(*anyopaque, ?*anyopaque, i32, i32, i32, i32, u32) callconv(.winapi) i32;
extern "user32" fn GetClientRect(*anyopaque, *Rect) callconv(.winapi) i32;
extern "user32" fn ShowWindow(*anyopaque, i32) callconv(.winapi) i32;

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    const allocator = init.arena.allocator();
    var host_window = window.HostWindow{};
    try host_window.init(960, 540);
    defer host_window.deinit();

    const native = host_window.nativeHandle() orelse return error.WindowCreationFailed;
    var renderer = try vulkan.Renderer.init(allocator, .{
        .native_window = .{
            .instance = native.instance,
            .window = native.window,
            .width = native.width,
            .height = native.height,
        },
    });
    defer renderer.deinit();

    const pixel_count: usize = @as(usize, frame_width) * frame_height;
    const pixels = try allocator.alloc(u8, pixel_count * 4);
    for (0..frame_height) |y| {
        for (0..frame_width) |x| {
            const offset = (@as(usize, y) * frame_width + x) * 4;
            const checker = ((x / 20) + (y / 20)) & 1;
            pixels[offset] = @intCast(x * 255 / (frame_width - 1));
            pixels[offset + 1] = @intCast(y * 255 / (frame_height - 1));
            pixels[offset + 2] = if (checker == 0) 48 else 208;
            pixels[offset + 3] = 255;
        }
    }

    const presentation_sink = renderer.windowPresentationSink() orelse
        return error.PresentationSinkUnavailable;
    const frame = vulkan.backend.PresentedFrame{
        .pixels = pixels,
        .width = frame_width,
        .height = frame_height,
        .row_pitch_bytes = frame_width * 4,
        .guest_address = 0,
        .flip = gpu.state.Flip{
            .video_out_handle = 1,
            .display_buffer_index = 0,
            .mode = 1,
            .argument = 1,
        },
    };
    if (!presentation_sink.present(presentation_sink.context, frame)) return error.FramePresentationFailed;

    // A stale swapchain used to report success while dropping every frame
    // after resizing. Exercise both CPU upload and resident-image blits through
    // real acquire/present calls, including restore after minimization.
    for ([_]bool{ false, true }) |resident| {
        for ([_][2]i32{ .{ 720, 480 }, .{ 1100, 720 } }) |size| {
            if (SetWindowPos(native.window, null, 0, 0, size[0], size[1], 0x16) == 0)
                return error.WindowResizeFailed;
            try init.io.sleep(.fromMilliseconds(100), .awake);
            for (0..3) |_| {
                if (resident) {
                    try renderer.probeWindowBlit(pixels, frame_width, frame_height);
                } else if (!presentation_sink.present(presentation_sink.context, frame)) return error.FramePresentationFailed;
            }
            var client: Rect = undefined;
            if (GetClientRect(native.window, &client) == 0) return error.WindowResizeFailed;
            const extent = renderer.window_presentation.?.extent;
            if (extent.width != client.right or extent.height != client.bottom or renderer.window_presentation.?.needs_recreate)
                return error.StaleSwapchainAfterResize;
            const dropped = renderer.present_dropped;
            if (resident) {
                try renderer.probeWindowBlit(pixels, frame_width, frame_height);
            } else if (!presentation_sink.present(presentation_sink.context, frame)) return error.FramePresentationFailed;
            if (renderer.present_dropped != dropped) return error.FrameDroppedAfterResize;
        }
        _ = ShowWindow(native.window, 6); // SW_MINIMIZE
        try init.io.sleep(.fromMilliseconds(100), .awake);
        if (resident) {
            try renderer.probeWindowBlit(pixels, frame_width, frame_height);
        } else if (!presentation_sink.present(presentation_sink.context, frame)) return error.FramePresentationFailed;
        _ = ShowWindow(native.window, 9); // SW_RESTORE
        try init.io.sleep(.fromMilliseconds(100), .awake);
        for (0..3) |_| {
            if (resident) {
                try renderer.probeWindowBlit(pixels, frame_width, frame_height);
            } else if (!presentation_sink.present(presentation_sink.context, frame)) return error.FramePresentationFailed;
        }
        if (renderer.window_presentation.?.needs_recreate) return error.StaleSwapchainAfterRestore;
    }

    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output.interface.print(
        "Win32 Vulkan presentation passed: {s}; CPU uploads and GPU blits survive resize and minimize/restore\n",
        .{renderer.device_info.name()},
    );
    try output.interface.flush();

    // Keep the diagnostic image visible long enough for a manual smoke run;
    // this step is explicit and is never part of the automated test suite.
    try init.io.sleep(.fromSeconds(2), .awake);
}
