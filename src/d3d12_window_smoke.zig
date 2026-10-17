// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const d3d12 = @import("d3d12");
const window = @import("window");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const hold = args.len == 2 and std.mem.eql(u8, args[1], "--hold");
    if (args.len > 1 and !hold) return error.InvalidArgument;
    var host_window = window.HostWindow{};
    try host_window.initWithRenderer(960, 540, "DirectX 12 diagnostic");
    defer host_window.deinit();
    var device = try d3d12.Device.init(false);
    defer device.deinit();
    const handle = host_window.nativeHandle() orelse return error.WindowUnavailable;
    try device.attachWindow(handle.window, handle.width, handle.height);
    try device.presentColor(.{ 0, 0, 1, 1 });
    for ([_][2]u32{ .{ 321, 181 }, .{ 97, 53 }, .{ 512, 288 } }) |size| {
        const pixels = try allocator.alloc(u8, try d3d12.rgbaSize(size[0], size[1]));
        defer allocator.free(pixels);
        try device.renderProbe(pixels, size[0], size[1]);
        for (0..6) |_| try device.presentRgba(pixels, size[0], size[1]);
    }
    if (device.validationErrors() != 0) return error.ValidationFailed;
    std.debug.print("PASS native D3D12 window: three swapchain extents, shader output upload, all three backbuffers presented ({s})\n", .{device.info.name()});
    for (0..if (hold) @as(usize, 30) else 2) |_| {
        if (!host_window.isOpen()) break;
        try init.io.sleep(.fromSeconds(1), .awake);
    }
}
