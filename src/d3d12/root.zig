// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Native Direct3D 12 device boundary. No Vulkan loader or translation driver
//! participates in this path. A device must only be used by one submission
//! thread at a time, and deinit must follow its last completed submission.
const std = @import("std");
const builtin = @import("builtin");
pub const backend = @import("backend.zig");
pub const Renderer = backend.Renderer;

const Handle = opaque {};
pub const Buffer = extern struct {
    bytes: [*]u8,
    size: usize,

    pub fn fromSlice(bytes: []u8) Buffer {
        return .{ .bytes = bytes.ptr, .size = bytes.len };
    }
};
pub const Draw = extern struct {
    width: u32,
    height: u32,
    vertex_count: u32 = 3,
    instance_count: u32 = 1,
    first_vertex: u32 = 0,
    first_instance: u32 = 0,
    topology: u32 = 4,
    cull_mode: u32 = 1,
    front_ccw: u32 = 0,
    write_mask: u32 = 15,
    index_count: u32 = 0,
    index_element_bytes: u32 = 0,
    primitive_restart: u32 = 0,
    base_vertex: i32 = 0,
    viewport: [6]f32,
    scissor: [4]i32,

    pub fn fullTarget(width: u32, height: u32) Error!Draw {
        _ = try rgbaSize(width, height);
        return .{ .width = width, .height = height, .viewport = .{ 0, 0, @floatFromInt(width), @floatFromInt(height), 0, 1 }, .scissor = .{ 0, 0, @intCast(width), @intCast(height) } };
    }
};
pub const DeviceInfo = extern struct {
    adapter: [128]u8,
    dedicated_bytes: u64,
    vendor_id: u32,
    device_id: u32,
    debug_enabled: u32,

    pub fn name(self: *const DeviceInfo) []const u8 {
        return std.mem.sliceTo(&self.adapter, 0);
    }
};

pub const Error = error{ UnsupportedPlatform, InvalidArgument, NativeFailure };
pub const Device = struct {
    handle: *Handle,
    info: DeviceInfo,

    pub fn init(debug: bool) Error!Device {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        var handle: ?*Handle = null;
        var info: DeviceInfo = undefined;
        var message: [1024]u8 = @splat(0);
        const hr = ps5_d3d12_create(&handle, &info, @intFromBool(debug), &message, message.len);
        if (hr < 0) {
            std.log.err("[d3d12] {s} (0x{x})", .{ std.mem.sliceTo(&message, 0), @as(u32, @bitCast(hr)) });
            return error.NativeFailure;
        }
        return .{ .handle = handle orelse return error.NativeFailure, .info = info };
    }

    pub fn deinit(self: *Device) void {
        if (builtin.os.tag == .windows) ps5_d3d12_destroy(self.handle);
        self.* = undefined;
    }

    fn check(self: *Device, hr: i32) Error!void {
        if (hr >= 0) return;
        std.log.err("[d3d12] {s} (0x{x})", .{ ps5_d3d12_error(self.handle), @as(u32, @bitCast(hr)) });
        return error.NativeFailure;
    }

    pub fn bufferRoundtrip(self: *Device, source: []const u8, destination: []u8) Error!void {
        if (source.len == 0 or source.len != destination.len) return error.InvalidArgument;
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.check(ps5_d3d12_buffer_roundtrip(self.handle, source.ptr, destination.ptr, source.len));
    }

    pub fn computeProbe(self: *Device, destination: []u32, multiplier: u32, addend: u32) Error!void {
        if (destination.len == 0 or destination.len > 65535 * 64) return error.InvalidArgument;
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.check(ps5_d3d12_compute(self.handle, destination.ptr, @intCast(destination.len), multiplier, addend));
    }

    pub fn renderProbe(self: *Device, rgba: []u8, width: u32, height: u32) Error!void {
        if (rgba.len != try rgbaSize(width, height)) return error.InvalidArgument;
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.check(ps5_d3d12_render(self.handle, rgba.ptr, width, height));
    }

    pub fn attachWindow(self: *Device, hwnd: *anyopaque, width: u32, height: u32) Error!void {
        _ = try rgbaSize(width, height);
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.check(ps5_d3d12_attach_window(self.handle, hwnd, width, height));
    }

    pub fn presentColor(self: *Device, rgba: [4]f32) Error!void {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        for (rgba) |component| if (!std.math.isFinite(component)) return error.InvalidArgument;
        try self.check(ps5_d3d12_present(self.handle, &rgba));
    }

    pub fn validationErrors(self: *Device) u64 {
        if (builtin.os.tag != .windows) return 0;
        return ps5_d3d12_validation_errors(self.handle);
    }

    pub fn dispatchSpirv(self: *Device, words: []const u32, buffers: []const Buffer, groups: [3]u32) Error!void {
        if (words.len < 5 or words[0] != 0x07230203 or buffers.len > 64) return error.InvalidArgument;
        for (groups) |size| if (size == 0 or size > 65535) return error.InvalidArgument;
        for (buffers) |buffer| if (buffer.size == 0 or buffer.size % 4 != 0 or buffer.size > 256 * 1024 * 1024) return error.InvalidArgument;
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.check(ps5_d3d12_dispatch_spirv(self.handle, words.ptr, words.len, buffers.ptr, @intCast(buffers.len), &groups));
    }

    pub fn drawSpirv(self: *Device, vertex: []const u32, fragment: []const u32, draw: Draw, rgba: []u8) Error!void {
        return self.drawIndexedSpirv(vertex, fragment, draw, &.{}, rgba);
    }

    pub fn drawIndexedSpirv(self: *Device, vertex: []const u32, fragment: []const u32, draw: Draw, indices: []const u8, rgba: []u8) Error!void {
        if (draw.index_count != 0) {
            if ((draw.index_element_bytes != 2 and draw.index_element_bytes != 4) or
                @as(u64, draw.index_count) * draw.index_element_bytes != indices.len or indices.len > 64 * 1024 * 1024) return error.InvalidArgument;
        } else if (indices.len != 0 or draw.index_element_bytes != 0 or draw.primitive_restart != 0) return error.InvalidArgument;
        if (draw.primitive_restart > 1 or (draw.primitive_restart != 0 and draw.topology != 5)) return error.InvalidArgument;
        if (rgba.len != try rgbaSize(draw.width, draw.height) or vertex.len < 5 or fragment.len < 5 or
            vertex[0] != 0x07230203 or fragment[0] != 0x07230203 or (draw.vertex_count == 0 and draw.index_count == 0) or draw.instance_count == 0 or
            (draw.topology != 4 and draw.topology != 5) or draw.cull_mode < 1 or draw.cull_mode > 3 or draw.write_mask > 15) return error.InvalidArgument;
        for (draw.viewport) |value| if (!std.math.isFinite(value)) return error.InvalidArgument;
        if (draw.viewport[2] <= 0 or draw.viewport[3] <= 0 or draw.viewport[4] < 0 or draw.viewport[5] > 1 or draw.viewport[4] > draw.viewport[5] or
            draw.scissor[0] < 0 or draw.scissor[1] < 0 or draw.scissor[2] < draw.scissor[0] or draw.scissor[3] < draw.scissor[1]) return error.InvalidArgument;
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.check(ps5_d3d12_draw_spirv(self.handle, vertex.ptr, vertex.len, fragment.ptr, fragment.len, &draw, indices.ptr, indices.len, rgba.ptr));
    }

    pub fn presentRgba(self: *Device, rgba: []const u8, width: u32, height: u32) Error!void {
        if (rgba.len != try rgbaSize(width, height)) return error.InvalidArgument;
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        try self.check(ps5_d3d12_present_rgba(self.handle, rgba.ptr, width, height));
    }
};

pub fn rgbaSize(width: u32, height: u32) Error!usize {
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidArgument;
    return @as(usize, width) * height * 4;
}

extern fn ps5_d3d12_create(*?*Handle, *DeviceInfo, c_int, [*]u8, usize) i32;
extern fn ps5_d3d12_destroy(*Handle) void;
extern fn ps5_d3d12_error(*Handle) [*:0]const u8;
extern fn ps5_d3d12_buffer_roundtrip(*Handle, [*]const u8, [*]u8, usize) i32;
extern fn ps5_d3d12_compute(*Handle, [*]u32, u32, u32, u32) i32;
extern fn ps5_d3d12_render(*Handle, [*]u8, u32, u32) i32;
extern fn ps5_d3d12_attach_window(*Handle, *anyopaque, u32, u32) i32;
extern fn ps5_d3d12_present(*Handle, *const [4]f32) i32;
extern fn ps5_d3d12_validation_errors(*Handle) u64;
extern fn ps5_d3d12_dispatch_spirv(*Handle, [*]const u32, usize, [*]const Buffer, u32, *const [3]u32) i32;
extern fn ps5_d3d12_draw_spirv(*Handle, [*]const u32, usize, [*]const u32, usize, *const Draw, [*]const u8, usize, [*]u8) i32;
extern fn ps5_d3d12_present_rgba(*Handle, [*]const u8, u32, u32) i32;

test "readback sizes reject empty and excessive textures before native allocation" {
    try std.testing.expectEqual(@as(usize, 71 * 37 * 4), try rgbaSize(71, 37));
    try std.testing.expectError(error.InvalidArgument, rgbaSize(0, 1));
    try std.testing.expectError(error.InvalidArgument, rgbaSize(1, 0));
    try std.testing.expectError(error.InvalidArgument, rgbaSize(16385, 1));
    try std.testing.expectError(error.InvalidArgument, rgbaSize(1, std.math.maxInt(u32)));
}
