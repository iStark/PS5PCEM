// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest surface staging uses the shared GFX10 address equations. D3D12 owns
//! the native texture layout; upload/readback buffers carry tight RGBA texels.
const std = @import("std");
const gpu = @import("gpu");

pub fn colorLayout(target: gpu.resources.ColorTarget) !gpu.SurfaceLayout {
    if (target.format != 10 or target.number_type != 0 or target.component_swap != 0 or
        target.samples_log2 != 0 or target.fragments_log2 != 0 or target.mip_level != 0 or
        target.maximum_mip != 0 or target.resource_type == 2 or target.depth > 1 or
        target.base_array_slice != 0 or target.last_array_slice != 0 or
        target.dcc_enabled or target.cmask_fast_clear or target.fmask_compression or
        target.force_destination_alpha_one) return error.UnsupportedRenderTargetLayout;
    const layout = try gpu.SurfaceLayout.fromColorTarget(target);
    try validate(layout, target.address);
    return layout;
}

pub fn scanoutLayout(width: u32, height: u32, pitch: u32, tiling_mode: u32) !gpu.SurfaceLayout {
    const mode: gpu.resources.TileMode = switch (tiling_mode) {
        0 => .render_target,
        1 => .linear,
        else => return error.UnsupportedScanoutLayout,
    };
    if (pitch < width or pitch > 16384) return error.InvalidPitch;
    const layout = try gpu.SurfaceLayout.init(.{
        .tile_mode = mode,
        .width = width,
        .height = height,
        .row_pitch_elements = pitch,
    }, 4);
    try validate(layout, 0);
    return layout;
}

pub fn scanoutSwapsRedBlue(pixel_format: u64) !bool {
    return switch (pixel_format) {
        0, 0x8000_0000_2200_0000 => false, // RGBA8 (zero retains the legacy internal default).
        0x8000_0000_0000_0000 => true, // BGRA8.
        else => error.UnsupportedScanoutFormat,
    };
}

test "VideoOut RGBA8 and BGRA8 select the correct byte order without accepting HDR" {
    try std.testing.expect(!try scanoutSwapsRedBlue(0x8000_0000_2200_0000));
    try std.testing.expect(try scanoutSwapsRedBlue(0x8000_0000_0000_0000));
    try std.testing.expect(!try scanoutSwapsRedBlue(0));
    try std.testing.expectError(error.UnsupportedScanoutFormat, scanoutSwapsRedBlue(0x8100_0000_2200_0000));
}

fn validate(layout: gpu.SurfaceLayout, address: u64) !void {
    if (layout.width == 0 or layout.height == 0 or layout.width > 16384 or layout.height > 16384 or
        layout.layers != 1 or layout.block.bytes_per_element != 4 or
        layout.required_source_bytes > 256 * 1024 * 1024 or layout.staging_bytes > 256 * 1024 * 1024)
        return error.SurfaceBudgetExceeded;
    _ = try layout.sourceRange(address);
}

pub const Staged = struct {
    allocator: std.mem.Allocator,
    layout: gpu.SurfaceLayout,
    address: u64,
    backing: []u8,
    pixels: []u8,

    pub fn read(allocator: std.mem.Allocator, memory: anytype, address: u64, layout: gpu.SurfaceLayout) !Staged {
        try validate(layout, address);
        const backing = try allocator.alloc(u8, @intCast(layout.required_source_bytes));
        errdefer allocator.free(backing);
        const pixels = try allocator.alloc(u8, @intCast(layout.staging_bytes));
        errdefer allocator.free(pixels);
        if (!memory.read(memory.context, address, backing)) return error.GuestReadFailed;
        try layout.detile(backing, pixels);
        return .{ .allocator = allocator, .layout = layout, .address = address, .backing = backing, .pixels = pixels };
    }

    pub fn write(self: *Staged, memory: anytype) !void {
        // Re-read padding immediately before writeback. Only the logical view
        // is replaced; tail tiles and row padding retain their guest contents.
        if (!memory.read(memory.context, self.address, self.backing)) return error.GuestReadFailed;
        try self.layout.tile(self.pixels, self.backing);
        if (!memory.write(memory.context, self.address, self.backing)) return error.GuestWriteFailed;
    }

    pub fn deinit(self: *Staged) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.backing);
        self.* = undefined;
    }
};

test "color layout derives tiled and absent linear pitches without accepting compression" {
    var target = std.mem.zeroes(gpu.resources.ColorTarget);
    target.address = 0x10000;
    target.width = 1920;
    target.height = 1080;
    target.depth = 1;
    target.format = 10;
    target.tile_mode = .render_target;
    const tiled = try colorLayout(target);
    try std.testing.expectEqual(@as(u64, 15 * 9 * 65536), tiled.required_source_bytes);
    target.tile_mode = .linear;
    target.width = 65;
    try std.testing.expectEqual(@as(u32, 128), (try colorLayout(target)).row_pitch_elements);
    target.pitch = 72;
    try std.testing.expectEqual(@as(u32, 72), (try colorLayout(target)).row_pitch_elements);
    target.dcc_enabled = true;
    try std.testing.expectError(error.UnsupportedRenderTargetLayout, colorLayout(target));
    target.dcc_enabled = false;
    target.address = std.math.maxInt(u64) - 32;
    try std.testing.expectError(error.ArithmeticOverflow, colorLayout(target));
    try std.testing.expectError(error.UnsupportedScanoutLayout, scanoutLayout(65, 37, 72, 2));
    try std.testing.expectError(error.InvalidPitch, scanoutLayout(65, 37, 64, 1));
}
