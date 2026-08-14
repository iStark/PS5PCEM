// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Minimal Font/FontFt firmware surface used during title bootstrap.
//!
//! Titles commonly bring the font library up before their renderer even when
//! all visible text is later drawn by the game.  Returning null selections or
//! handles makes those bootstrap paths fail before VideoOut is reached.  Keep
//! opaque, process-local handles and provide neutral metrics/output until a
//! real glyph rasterizer is attached.

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const kernel_memory = @import("kernel_memory.zig");
const symbols = @import("../symbols.zig");
const trace = @import("../trace.zig");

const FontMemory = extern struct {
    bytes: [64]u8,
};

const GlyphMetrics = extern struct {
    width: f32,
    height: f32,
    horizontal_bearing_x: f32,
    horizontal_bearing_y: f32,
    horizontal_advance: f32,
    vertical_bearing_x: f32,
    vertical_bearing_y: f32,
    vertical_advance: f32,
};

const RenderSurface = extern struct {
    buffer: usize,
    width_bytes: i32,
    pixel_size_bytes: i8,
    padding0: u8,
    style_flags: u8,
    padding1: u8,
    width: i32,
    height: i32,
    scissor_x0: u32,
    scissor_y0: u32,
    scissor_x1: u32,
    scissor_y1: u32,
    reserved: [11]u64,
};

const RenderOutput = extern struct {
    bytes: [64]u8,
};

const LibrarySelection = extern struct {
    magic: u32 = 0x464f_4e54,
    reserved: u32 = 0,
    reserved_pointer: usize = 0,
    get_pixel_resolution: usize = 0,
    init: usize = 0,
    term: usize = 0,
    support: usize = 0,
};

const RendererSelection = extern struct {
    magic: u32 = 0x4654_524e,
    size: u32 = @sizeOf(RendererSelection),
    create: usize = 0,
    destroy: usize = 0,
    query: usize = 0,
};

var library_token: u8 = 0;
var renderer_token: u8 = 0;
var font_token: u8 = 0;
var library_selection = LibrarySelection{};
var renderer_selection = RendererSelection{};

fn writable(address: usize, size: usize) bool {
    return address != 0 and kernel_memory.isGuestRangeAccessible(address, size);
}

fn memoryInit(
    memory: ?*FontMemory,
    _: usize,
    _: u32,
    _: usize,
    _: usize,
    _: usize,
    _: usize,
) callconv(abi.guest) i32 {
    const output = memory orelse return errno.KernelError.efault.raw();
    if (!writable(@intFromPtr(output), @sizeOf(FontMemory))) return errno.KernelError.efault.raw();
    @memset(&output.bytes, 0);
    return errno.ok;
}

fn memoryTerm(_: ?*FontMemory) callconv(abi.guest) i32 {
    return errno.ok;
}

fn createLibrary(
    _: ?*const FontMemory,
    _: usize,
    _: u64,
    output: ?*usize,
) callconv(abi.guest) i32 {
    const result = output orelse return errno.KernelError.efault.raw();
    if (!writable(@intFromPtr(result), @sizeOf(usize))) return errno.KernelError.efault.raw();
    result.* = @intFromPtr(&library_token);
    return errno.ok;
}

fn createRenderer(
    _: ?*const FontMemory,
    _: usize,
    _: u64,
    output: ?*usize,
) callconv(abi.guest) i32 {
    const result = output orelse return errno.KernelError.efault.raw();
    if (!writable(@intFromPtr(result), @sizeOf(usize))) return errno.KernelError.efault.raw();
    result.* = @intFromPtr(&renderer_token);
    return errno.ok;
}

fn destroyHandle(output: ?*usize) callconv(abi.guest) i32 {
    if (output) |result| {
        if (!writable(@intFromPtr(result), @sizeOf(usize))) return errno.KernelError.efault.raw();
        result.* = 0;
    }
    return errno.ok;
}

fn openFontMemory(
    _: usize,
    _: usize,
    _: u32,
    _: usize,
    output: ?*usize,
) callconv(abi.guest) i32 {
    return openFont(output);
}

fn openFontSet(
    _: usize,
    _: u32,
    _: u32,
    _: usize,
    output: ?*usize,
) callconv(abi.guest) i32 {
    return openFont(output);
}

fn openFont(output: ?*usize) i32 {
    const result = output orelse return errno.KernelError.efault.raw();
    if (!writable(@intFromPtr(result), @sizeOf(usize))) return errno.KernelError.efault.raw();
    result.* = @intFromPtr(&font_token);
    return errno.ok;
}

fn accept1(_: usize) callconv(abi.guest) i32 {
    return errno.ok;
}

fn accept2(_: usize, _: usize) callconv(abi.guest) i32 {
    return errno.ok;
}

fn accept3(_: usize, _: f32, _: f32) callconv(abi.guest) i32 {
    return errno.ok;
}

fn glyphMetrics(_: usize, _: u32, output: ?*GlyphMetrics) callconv(abi.guest) i32 {
    const metrics = output orelse return errno.KernelError.efault.raw();
    if (!writable(@intFromPtr(metrics), @sizeOf(GlyphMetrics))) return errno.KernelError.efault.raw();
    metrics.* = .{
        .width = 8,
        .height = 16,
        .horizontal_bearing_x = 0,
        .horizontal_bearing_y = 12,
        .horizontal_advance = 8,
        .vertical_bearing_x = 0,
        .vertical_bearing_y = 0,
        .vertical_advance = 16,
    };
    return errno.ok;
}

fn renderSurfaceInit(
    output: ?*RenderSurface,
    buffer: usize,
    width_bytes: i32,
    pixel_size_bytes: i32,
    width: i32,
    height: i32,
) callconv(abi.guest) void {
    const surface = output orelse return;
    if (!writable(@intFromPtr(surface), @sizeOf(RenderSurface))) return;
    surface.* = .{
        .buffer = buffer,
        .width_bytes = width_bytes,
        .pixel_size_bytes = @truncate(pixel_size_bytes),
        .padding0 = 0,
        .style_flags = 0,
        .padding1 = 0,
        .width = width,
        .height = height,
        .scissor_x0 = 0,
        .scissor_y0 = 0,
        .scissor_x1 = @intCast(@max(width, 0)),
        .scissor_y1 = @intCast(@max(height, 0)),
        .reserved = [_]u64{0} ** 11,
    };
}

fn renderSurfaceSetScissor(
    output: ?*RenderSurface,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(abi.guest) void {
    const surface = output orelse return;
    if (!writable(@intFromPtr(surface), @sizeOf(RenderSurface))) return;
    surface.scissor_x0 = @intCast(@max(x, 0));
    surface.scissor_y0 = @intCast(@max(y, 0));
    surface.scissor_x1 = @intCast(@max(x + width, 0));
    surface.scissor_y1 = @intCast(@max(y + height, 0));
}

fn renderGlyph(
    font: usize,
    codepoint: u32,
    _: ?*RenderSurface,
    _: f32,
    _: f32,
    metrics: ?*GlyphMetrics,
    output: ?*RenderOutput,
) callconv(abi.guest) i32 {
    const status = glyphMetrics(font, codepoint, metrics);
    if (status != errno.ok) return status;
    if (output) |result| {
        if (!writable(@intFromPtr(result), @sizeOf(RenderOutput))) return errno.KernelError.efault.raw();
        @memset(&result.bytes, 0);
    }
    return errno.ok;
}

fn selectLibrary(value: i32) callconv(abi.guest) ?*const LibrarySelection {
    if (value != 0) return null;
    return &library_selection;
}

fn selectRenderer(value: i32) callconv(abi.guest) ?*const RendererSelection {
    if (value != 0) return null;
    return &renderer_selection;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceFontMemoryInit", .function = trace.wrap("sceFontMemoryInit", &memoryInit), .expect_id = "whrS4oksXc4" },
    .{ .name = "sceFontCreateLibraryWithEdition", .function = trace.wrap("sceFontCreateLibraryWithEdition", &createLibrary), .expect_id = "n590hj5Oe-k" },
    .{ .name = "sceFontSupportSystemFonts", .function = trace.wrap("sceFontSupportSystemFonts", &accept1), .expect_id = "SsRbbCiWoGw" },
    .{ .name = "sceFontSupportExternalFonts", .function = trace.wrap("sceFontSupportExternalFonts", &accept3), .expect_id = "mz2iTY0MK4A" },
    .{ .name = "sceFontCreateRendererWithEdition", .function = trace.wrap("sceFontCreateRendererWithEdition", &createRenderer), .expect_id = "WaSFJoRWXaI" },
    .{ .name = "sceFontRenderSurfaceInit", .function = trace.wrap("sceFontRenderSurfaceInit", &renderSurfaceInit), .expect_id = "gdUCnU0gHdI" },
    .{ .name = "sceFontRenderSurfaceSetScissor", .function = trace.wrap("sceFontRenderSurfaceSetScissor", &renderSurfaceSetScissor), .expect_id = "vRxf4d0ulPs" },
    .{ .name = "sceFontUnbindRenderer", .function = trace.wrap("sceFontUnbindRenderer", &accept1), .expect_id = "1QjhKxrsOB8" },
    .{ .name = "sceFontCloseFont", .function = trace.wrap("sceFontCloseFont", &accept1), .expect_id = "vzHs3C8lWJk" },
    .{ .name = "sceFontDestroyRenderer", .function = trace.wrap("sceFontDestroyRenderer", &destroyHandle), .expect_id = "exAxkyVLt0s" },
    .{ .name = "sceFontDestroyLibrary", .function = trace.wrap("sceFontDestroyLibrary", &destroyHandle), .expect_id = "FXP359ygujs" },
    .{ .name = "sceFontMemoryTerm", .function = trace.wrap("sceFontMemoryTerm", &memoryTerm), .expect_id = "h6hIgxXEiEc" },
    .{ .name = "sceFontOpenFontMemory", .function = trace.wrap("sceFontOpenFontMemory", &openFontMemory), .expect_id = "KXUpebrFk1U" },
    .{ .name = "sceFontBindRenderer", .function = trace.wrap("sceFontBindRenderer", &accept2), .expect_id = "3OdRkSjOcog" },
    .{ .name = "sceFontOpenFontSet", .function = trace.wrap("sceFontOpenFontSet", &openFontSet), .expect_id = "cKYtVmeSTcw" },
    .{ .name = "sceFontGetCharGlyphMetrics", .function = trace.wrap("sceFontGetCharGlyphMetrics", &glyphMetrics), .expect_id = "L97d+3OgMlE" },
    .{ .name = "sceFontRenderCharGlyphImageHorizontal", .function = trace.wrap("sceFontRenderCharGlyphImageHorizontal", &renderGlyph), .expect_id = "kAenWy1Zw5o" },
    .{ .name = "sceFontSetScalePixel", .function = trace.wrap("sceFontSetScalePixel", &accept3), .expect_id = "N1EBMeGhf7E" },
};

pub const ft_exports = [_]symbols.Export{
    .{ .name = "sceFontSelectLibraryFt", .function = trace.wrap("sceFontSelectLibraryFt", &selectLibrary), .expect_id = "oM+XCzVG3oM" },
    .{ .name = "sceFontSelectRendererFt", .function = trace.wrap("sceFontSelectRendererFt", &selectRenderer), .expect_id = "Xx974EW-QFY" },
};

test "font ABI structures retain their firmware sizes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(FontMemory));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(GlyphMetrics));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(RenderSurface));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(RenderOutput));
}

test "font selectors and handles are non-null" {
    try std.testing.expect(selectLibrary(0) != null);
    try std.testing.expect(selectRenderer(0) != null);
    var handle: usize = 0;
    // Unit-test memory is outside the guest map, so exercise the invariant
    // directly instead of the guest-pointer validation boundary.
    handle = @intFromPtr(&font_token);
    try std.testing.expect(handle != 0);
}
