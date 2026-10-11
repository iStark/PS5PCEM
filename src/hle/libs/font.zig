// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Font/FontFt outline rendering. Title fonts use owned FreeType faces;
//! system-font requests use bundled Noto Sans. Handles are checked tokens.
const std = @import("std");
const memory = @import("memory");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const kernel_memory = @import("kernel_memory.zig");
const raster = @import("../font_rasterizer.zig");
const symbols = @import("../symbols.zig");
const trace = @import("../trace.zig");

const invalid_parameter: i32 = @bitCast(@as(u32, 0x80460002));
const invalid_font: i32 = @bitCast(@as(u32, 0x80460005));
const unsupported_code: i32 = @bitCast(@as(u32, 0x80460041));
const allocator = std.heap.page_allocator;
const FontMemory = extern struct {
    type: u16,
    attr: u16,
    size: u32,
    address: usize,
    mspace: usize,
    interface: usize,
    destroy_callback: usize,
    destroy_object: usize,
    user_object: usize,
    parent_object: usize,
};
const GlyphMetrics = raster.Metrics;
const RenderSurface = extern struct {
    buffer: usize,
    width_bytes: i32,
    pixel_size_bytes: i8,
    padding0: u8 = 0,
    style_flags: u8 = 0,
    padding1: u8 = 0,
    width: i32,
    height: i32,
    scissor_x0: u32,
    scissor_y0: u32,
    scissor_x1: u32,
    scissor_y1: u32,
    reserved: [22]u32 = @splat(0),
};
const TransImage = extern struct {
    address: usize = 0,
    width_bytes: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};
const SurfaceImage = extern struct {
    address: usize = 0,
    width_bytes: u32 = 0,
    pixel_size_bytes: u8 = 0,
    pixel_format: u8 = 0,
};
const Rect = extern struct { x: u32 = 0, y: u32 = 0, width: u32 = 0, height: u32 = 0 };
const ImageMetrics = extern struct {
    bearing_x: f32 = 0,
    bearing_y: f32 = 0,
    advance: f32 = 0,
    stride: f32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};
const RenderOutput = extern struct {
    trans_image: usize = 0,
    surface_image: SurfaceImage = .{},
    update_rect: Rect = .{},
    image_metrics: ImageMetrics = .{},
};
const Kerning = extern struct { offset_x: f32 = 0, offset_y: f32 = 0, position_x: f32 = 0, position_y: f32 = 0 };
const HorizontalLayout = extern struct { baseline: f32, height: f32, effect_height: f32 };
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
const Font = struct {
    handle: usize = 0,
    library: usize = 0,
    renderer: usize = 0,
    face: ?*raster.Face = null,
    style: raster.Style = .{},
    render_style: ?raster.Style = null,
    trans_image: TransImage = .{},

    fn close(self: *Font) void {
        if (self.face) |face| {
            face.deinit();
            allocator.destroy(face);
        }
        self.* = .{};
    }
};
var lock: memory.HostMutex = .{};
var libraries: [32]usize = @splat(0);
const DeviceCache = struct {
    bytes: []u8 = &.{},
    owned: bool = false,
    cursor: usize = 0,

    fn clear(self: *DeviceCache) void {
        if (self.owned) allocator.free(self.bytes);
        self.* = .{};
    }
};
var device_caches: [32]DeviceCache = @splat(.{});
var renderers: [64]usize = @splat(0);
var fonts: [128]Font = @splat(.{});
var next_handle: usize = 0x464f0000;
var library_selection = LibrarySelection{};
var renderer_selection = RendererSelection{};

pub fn reset() void {
    lock.lock();
    defer lock.unlock();
    for (&fonts) |*font| font.close();
    for (&device_caches) |*cache| cache.clear();
    @memset(&libraries, 0);
    @memset(&renderers, 0);
    // Do not recycle stale handles when another title starts in this process.
}
fn readable(address: usize, size: usize) bool {
    return address != 0 and kernel_memory.isGuestRangeAccessible(address, size);
}
fn writable(address: usize, size: usize) bool {
    if (address == 0) return false;
    _ = std.math.add(usize, address, size) catch return false;
    if (kernel_memory.attachedAddressSpace()) |space| {
        // GPU tracking temporarily removes host write permission. Check the
        // logical guest permission before notifyGuestWrite restores it.
        if (space.isWritable(address, size)) return true;
        return memory.isHostRangeWritable(address, size);
    }
    return true; // Host-only tests, as in kernel_memory's read boundary.
}
fn notifyWrite(address: usize, size: usize) void {
    if (kernel_memory.attachedAddressSpace()) |space| space.notifyGuestWrite(address, size);
}
fn validOutput(comptime T: type, output: ?*T) bool {
    return if (output) |ptr| writable(@intFromPtr(ptr), @sizeOf(T)) else false;
}
fn writeOutput(comptime T: type, output: *T, value: T) void {
    notifyWrite(@intFromPtr(output), @sizeOf(T));
    output.* = value;
}
fn newHandle() usize {
    next_handle += 1;
    return next_handle;
}
fn hasHandle(handles: []const usize, handle: usize) bool {
    return handle != 0 and std.mem.indexOfScalar(usize, handles, handle) != null;
}
fn findFont(handle: usize) ?*Font {
    if (handle != 0) for (&fonts) |*font| {
        if (font.handle == handle) return font;
    };
    return null;
}
fn fontError(err: raster.Error) i32 {
    return switch (err) {
        error.OutOfMemory => errno.KernelError.enomem.raw(),
        error.UnsupportedCode => unsupported_code,
        else => invalid_parameter,
    };
}
fn memoryInit(output: ?*FontMemory, address: usize, size: u32, interface: usize, mspace: usize, callback: usize, object: usize) callconv(abi.guest) i32 {
    if (!validOutput(FontMemory, output)) return errno.KernelError.efault.raw();
    writeOutput(FontMemory, output.?, .{
        .type = 1,
        .attr = 0,
        .size = size,
        .address = address,
        .mspace = mspace,
        .interface = interface,
        .destroy_callback = callback,
        .destroy_object = object,
        .user_object = 0,
        .parent_object = 0,
    });
    return errno.ok;
}
fn memoryTerm(output: ?*FontMemory) callconv(abi.guest) i32 {
    if (!validOutput(FontMemory, output)) return errno.KernelError.efault.raw();
    notifyWrite(@intFromPtr(output.?), @sizeOf(FontMemory));
    output.?.type = 0;
    return errno.ok;
}
fn createHandle(handles: []usize, output: ?*usize) i32 {
    if (!validOutput(usize, output)) return errno.KernelError.efault.raw();
    for (handles) |*slot| if (slot.* == 0) {
        slot.* = newHandle();
        writeOutput(usize, output.?, slot.*);
        return errno.ok;
    };
    return errno.KernelError.enomem.raw();
}
fn createLibrary(_: ?*const FontMemory, _: usize, _: u64, output: ?*usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    return createHandle(&libraries, output);
}
fn createLibraryDefault(mem: ?*const FontMemory, selection: usize, output: ?*usize) callconv(abi.guest) i32 {
    return createLibrary(mem, selection, 0, output);
}
fn createRenderer(_: ?*const FontMemory, _: usize, _: u64, output: ?*usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    return createHandle(&renderers, output);
}
fn destroyLibrary(output: ?*usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    if (!validOutput(usize, output)) return errno.KernelError.efault.raw();
    const handle = output.?.*;
    if (!hasHandle(&libraries, handle)) return invalid_parameter;
    for (&fonts) |*font| if (font.library == handle) {
        font.close();
    };
    for (&libraries, 0..) |*slot, index| if (slot.* == handle) {
        device_caches[index].clear();
        slot.* = 0;
    };
    writeOutput(usize, output.?, 0);
    return errno.ok;
}
fn destroyRenderer(output: ?*usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    if (!validOutput(usize, output)) return errno.KernelError.efault.raw();
    const handle = output.?.*;
    if (!hasHandle(&renderers, handle)) return invalid_parameter;
    for (&fonts) |*font| if (font.renderer == handle) {
        font.renderer = 0;
    };
    for (&renderers) |*slot| if (slot.* == handle) {
        slot.* = 0;
    };
    writeOutput(usize, output.?, 0);
    return errno.ok;
}
fn openFont(library: usize, data: []const u8, output: ?*usize) i32 {
    if (!validOutput(usize, output)) return errno.KernelError.efault.raw();
    if (!hasHandle(&libraries, library)) return invalid_parameter;
    for (&fonts) |*font| if (font.handle == 0) {
        const face = allocator.create(raster.Face) catch return errno.KernelError.enomem.raw();
        face.* = raster.Face.init(allocator, data) catch |err| {
            allocator.destroy(face);
            return fontError(err);
        };
        font.* = .{ .handle = newHandle(), .library = library, .face = face };
        writeOutput(usize, output.?, font.handle);
        return errno.ok;
    };
    return errno.KernelError.enomem.raw();
}
fn openFontMemory(library: usize, address: usize, size: u32, _: usize, output: ?*usize) callconv(abi.guest) i32 {
    if (size == 0 or size > 64 * 1024 * 1024) return invalid_parameter;
    if (!readable(address, size)) return errno.KernelError.efault.raw();
    lock.lock();
    defer lock.unlock();
    return openFont(library, @as([*]const u8, @ptrFromInt(address))[0..size], output);
}
fn openFontSet(library: usize, _: u32, _: u32, _: usize, output: ?*usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    return openFont(library, raster.fallback_font, output);
}
fn openFontInstance(handle: usize, _: usize, output: ?*usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    const source = findFont(handle) orelse return invalid_font;
    const status = openFont(source.library, source.face.?.data, output);
    if (status != errno.ok) return status;
    const instance = findFont(output.?.*).?;
    instance.style = source.style;
    instance.render_style = source.render_style;
    return errno.ok;
}
fn closeFont(handle: usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    font.close();
    return errno.ok;
}
fn supportSystemFonts(library: usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    return if (hasHandle(&libraries, library)) errno.ok else invalid_parameter;
}
fn supportExternalFonts(library: usize, _: u32, _: u32) callconv(abi.guest) i32 {
    return supportSystemFonts(library);
}

/// Null storage asks the library to own the cache allocation. Caller storage
/// remains borrowed. Glyph transfer images use this buffer, with wraparound;
/// the outline cache stays in FreeType's host-side representation.
fn attachDeviceCacheBuffer(library: usize, address: usize, size: u32) callconv(abi.guest) i32 {
    if (size > 64 * 1024 * 1024 or (address != 0 and size == 0)) return invalid_parameter;
    lock.lock();
    defer lock.unlock();
    if (library == 0) return invalid_parameter;
    const index = std.mem.indexOfScalar(usize, &libraries, library) orelse return invalid_parameter;
    var replacement = DeviceCache{};
    if (size != 0) {
        if (address == 0) {
            replacement.bytes = allocator.alloc(u8, size) catch return errno.KernelError.enomem.raw();
            replacement.owned = true;
        } else {
            if (!writable(address, size)) return errno.KernelError.efault.raw();
            replacement.bytes = @as([*]u8, @ptrFromInt(address))[0..size];
        }
    }
    device_caches[index].clear();
    device_caches[index] = replacement;
    for (&fonts) |*font| if (font.library == library) {
        font.trans_image = .{};
    };
    return errno.ok;
}

fn cacheTransferImage(library: usize, pixels: []const u8) []const u8 {
    const index = std.mem.indexOfScalar(usize, &libraries, library) orelse return pixels;
    const cache = &device_caches[index];
    if (pixels.len == 0 or pixels.len > cache.bytes.len) return pixels;
    if (pixels.len > cache.bytes.len - cache.cursor) cache.cursor = 0;
    const destination = cache.bytes[cache.cursor..][0..pixels.len];
    if (!cache.owned) notifyWrite(@intFromPtr(destination.ptr), destination.len);
    @memcpy(destination, pixels);
    cache.cursor += pixels.len;
    return destination;
}
fn bindRenderer(handle: usize, renderer: usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    if (!hasHandle(&renderers, renderer)) return invalid_parameter;
    font.renderer = renderer;
    font.render_style = null;
    return errno.ok;
}
fn unbindRenderer(handle: usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    font.renderer = 0;
    return errno.ok;
}
fn rebindRenderer(handle: usize) callconv(abi.guest) i32 {
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    if (!hasHandle(&renderers, font.renderer)) return invalid_parameter;
    font.render_style = null;
    return errno.ok;
}
fn setScale(handle: usize, width: f32, height: f32, render: bool) i32 {
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    var style = if (render) font.render_style orelse font.style else font.style;
    style.width = width;
    style.height = height;
    if (!style.valid()) return invalid_parameter;
    if (render) font.render_style = style else font.style = style;
    return errno.ok;
}
fn setScalePixel(handle: usize, width: f32, height: f32) callconv(abi.guest) i32 {
    return setScale(handle, width, height, false);
}
fn setupRenderScalePixel(handle: usize, width: f32, height: f32) callconv(abi.guest) i32 {
    return setScale(handle, width, height, true);
}
fn setSlant(handle: usize, slant: f32, render: bool) i32 {
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    var style = if (render) font.render_style orelse font.style else font.style;
    style.slant = slant;
    if (!style.valid()) return invalid_parameter;
    if (render) font.render_style = style else font.style = style;
    return errno.ok;
}
fn setEffectSlant(handle: usize, slant: f32) callconv(abi.guest) i32 {
    return setSlant(handle, slant, false);
}
fn setupRenderEffectSlant(handle: usize, slant: f32) callconv(abi.guest) i32 {
    return setSlant(handle, slant, true);
}
fn metricsImpl(handle: usize, codepoint: u32, output: ?*GlyphMetrics, render: bool) i32 {
    if (!validOutput(GlyphMetrics, output)) return errno.KernelError.efault.raw();
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    const glyph = font.face.?.getGlyph(codepoint, if (render) font.render_style orelse font.style else font.style) catch |err| return fontError(err);
    writeOutput(GlyphMetrics, output.?, glyph.metrics);
    return errno.ok;
}
fn glyphMetrics(handle: usize, codepoint: u32, output: ?*GlyphMetrics) callconv(abi.guest) i32 {
    return metricsImpl(handle, codepoint, output, false);
}
fn renderGlyphMetrics(handle: usize, codepoint: u32, output: ?*GlyphMetrics) callconv(abi.guest) i32 {
    return metricsImpl(handle, codepoint, output, true);
}
fn getKerning(handle: usize, previous: u32, code: u32, output: ?*Kerning) callconv(abi.guest) i32 {
    if (!validOutput(Kerning, output)) return errno.KernelError.efault.raw();
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    const offset = font.face.?.kerning(previous, code, font.style) catch |err| return fontError(err);
    writeOutput(Kerning, output.?, .{ .offset_x = offset });
    return errno.ok;
}
fn getHorizontalLayout(handle: usize, output: ?*HorizontalLayout) callconv(abi.guest) i32 {
    if (!validOutput(HorizontalLayout, output)) return errno.KernelError.efault.raw();
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    const layout = font.face.?.horizontalLayout(font.style) catch |err| return fontError(err);
    writeOutput(HorizontalLayout, output.?, .{ .baseline = layout[0], .height = layout[1], .effect_height = layout[2] });
    return errno.ok;
}
fn renderSurfaceInit(output: ?*RenderSurface, buffer: usize, width_bytes: i32, pixel_size_bytes: i32, width: i32, height: i32) callconv(abi.guest) void {
    if (!validOutput(RenderSurface, output)) return;
    writeOutput(RenderSurface, output.?, .{
        .buffer = buffer,
        .width_bytes = width_bytes,
        .pixel_size_bytes = std.math.cast(i8, pixel_size_bytes) orelse 0,
        .width = @max(width, 0),
        .height = @max(height, 0),
        .scissor_x0 = 0,
        .scissor_y0 = 0,
        .scissor_x1 = @intCast(@max(width, 0)),
        .scissor_y1 = @intCast(@max(height, 0)),
    });
}
fn renderSurfaceSetScissor(output: ?*RenderSurface, x0: u32, y0: u32, x1: u32, y1: u32) callconv(abi.guest) void {
    if (!validOutput(RenderSurface, output)) return;
    notifyWrite(@intFromPtr(output.?), @sizeOf(RenderSurface));
    output.?.scissor_x0 = x0;
    output.?.scissor_y0 = y0;
    output.?.scissor_x1 = x1;
    output.?.scissor_y1 = y1;
}
fn paint(glyph: *const raster.Glyph, surface: *const RenderSurface, x: f32, y: f32, rect: *Rect) i32 {
    const s = surface.*;
    if (s.width < 0 or s.height < 0 or s.width_bytes < 0 or s.pixel_size_bytes < 1 or s.pixel_size_bytes > 4) return invalid_parameter;
    const stride: usize = @intCast(s.width_bytes);
    const bpp: usize = @intCast(s.pixel_size_bytes);
    if (@as(usize, @intCast(s.width)) * bpp > stride) return invalid_parameter;
    // Preserve the original origin for source indexing when clipping a glyph
    // with negative bearings. Clamping the origin would shift its pixels.
    const origin_x: i64 = @as(i64, @intFromFloat(@floor(x))) + glyph.left;
    const origin_y: i64 = @as(i64, @intFromFloat(@floor(y))) - glyph.top;
    const left = @max(origin_x, @as(i64, s.scissor_x0));
    const top = @max(origin_y, @as(i64, s.scissor_y0));
    const right = @min(origin_x + glyph.width, @min(@as(i64, s.width), s.scissor_x1));
    const bottom = @min(origin_y + glyph.height, @min(@as(i64, s.height), s.scissor_y1));
    rect.* = .{};
    if (left >= right or top >= bottom) return errno.ok;
    const start = @as(usize, @intCast(top)) * stride + @as(usize, @intCast(left)) * bpp;
    const row_bytes = @as(usize, @intCast(right - left)) * bpp;
    const span = @as(usize, @intCast(bottom - top - 1)) * stride + row_bytes;
    const address = std.math.add(usize, s.buffer, start) catch return invalid_parameter;
    if (s.buffer == 0 or !writable(address, span)) return errno.KernelError.efault.raw();
    notifyWrite(address, span);
    var row = top;
    while (row < bottom) : (row += 1) {
        const source_offset = @as(usize, @intCast(row - origin_y)) * glyph.width + @as(usize, @intCast(left - origin_x));
        const destination: [*]u8 = @ptrFromInt(address + @as(usize, @intCast(row - top)) * stride);
        for (0..@intCast(right - left)) |column| {
            const coverage = glyph.pixels[source_offset + column];
            if (coverage != 0) @memset(destination[column * bpp ..][0..bpp], coverage);
        }
    }
    rect.* = .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(right - left), .height = @intCast(bottom - top) };
    return errno.ok;
}
fn renderGlyph(handle: usize, codepoint: u32, surface: ?*RenderSurface, x: f32, y: f32, metrics: ?*GlyphMetrics, output: ?*RenderOutput) callconv(abi.guest) i32 {
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or @abs(x) > 10000000 or @abs(y) > 10000000) return invalid_parameter;
    if (metrics != null and !validOutput(GlyphMetrics, metrics)) return errno.KernelError.efault.raw();
    if (output != null and !validOutput(RenderOutput, output)) return errno.KernelError.efault.raw();
    if (surface) |ptr| if (!readable(@intFromPtr(ptr), @sizeOf(RenderSurface))) return errno.KernelError.efault.raw();
    lock.lock();
    defer lock.unlock();
    const font = findFont(handle) orelse return invalid_font;
    const glyph = font.face.?.getGlyph(codepoint, font.render_style orelse font.style) catch |err| return fontError(err);
    var result: RenderOutput = .{};
    if (surface) |s| {
        const status = paint(glyph, s, x, y, &result.update_rect);
        if (status != errno.ok) return status;
        result.surface_image = .{ .address = s.buffer, .width_bytes = @intCast(s.width_bytes), .pixel_size_bytes = @intCast(s.pixel_size_bytes) };
    }
    const transfer_pixels = cacheTransferImage(font.library, glyph.pixels);
    font.trans_image = .{ .address = if (transfer_pixels.len != 0) @intFromPtr(transfer_pixels.ptr) else 0, .width_bytes = glyph.width, .width = glyph.width, .height = glyph.height };
    result.trans_image = @intFromPtr(&font.trans_image);
    result.image_metrics = .{
        .bearing_x = @floatFromInt(glyph.left),
        .bearing_y = @floatFromInt(glyph.top),
        .advance = glyph.metrics.horizontal_advance,
        .stride = glyph.metrics.horizontal_advance,
        .width = glyph.width,
        .height = glyph.height,
    };
    if (metrics) |ptr| writeOutput(GlyphMetrics, ptr, glyph.metrics);
    if (output) |ptr| writeOutput(RenderOutput, ptr, result);
    return errno.ok;
}
fn selectLibrary(value: i32) callconv(abi.guest) ?*const LibrarySelection {
    return if (value == 0) &library_selection else null;
}
fn selectRenderer(value: i32) callconv(abi.guest) ?*const RendererSelection {
    return if (value == 0) &renderer_selection else null;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceFontCreateLibrary", .function = trace.wrap("sceFontCreateLibrary", &createLibraryDefault), .expect_id = "nWrfPI4Okmg" },
    .{ .name = "sceFontOpenFontInstance", .function = trace.wrap("sceFontOpenFontInstance", &openFontInstance), .expect_id = "JzCH3SCFnAU" },
    .{ .name = "sceFontRebindRenderer", .function = trace.wrap("sceFontRebindRenderer", &rebindRenderer), .expect_id = "Z2cdsqJH+5k" },
    .{ .name = "sceFontGetRenderCharGlyphMetrics", .function = trace.wrap("sceFontGetRenderCharGlyphMetrics", &renderGlyphMetrics), .expect_id = "IQtleGLL5pQ" },
    .{ .name = "sceFontGetKerning", .function = trace.wrap("sceFontGetKerning", &getKerning), .expect_id = "sDuhHGNhHvE" },
    .{ .name = "sceFontGetHorizontalLayout", .function = trace.wrap("sceFontGetHorizontalLayout", &getHorizontalLayout), .expect_id = "imxVx8lm+KM" },
    .{ .name = "sceFontSetupRenderScalePixel", .function = trace.wrap("sceFontSetupRenderScalePixel", &setupRenderScalePixel), .expect_id = "6vGCkkQJOcI" },
    .{ .name = "sceFontSetEffectSlant", .function = trace.wrap("sceFontSetEffectSlant", &setEffectSlant), .expect_id = "TMtqoFQjjbA" },
    .{ .name = "sceFontSetupRenderEffectSlant", .function = trace.wrap("sceFontSetupRenderEffectSlant", &setupRenderEffectSlant), .expect_id = "lz9y9UFO2UU" },
    .{ .name = "sceFontMemoryInit", .function = trace.wrap("sceFontMemoryInit", &memoryInit), .expect_id = "whrS4oksXc4" },
    .{ .name = "sceFontCreateLibraryWithEdition", .function = trace.wrap("sceFontCreateLibraryWithEdition", &createLibrary), .expect_id = "n590hj5Oe-k" },
    .{ .name = "sceFontSupportSystemFonts", .function = trace.wrap("sceFontSupportSystemFonts", &supportSystemFonts), .expect_id = "SsRbbCiWoGw" },
    .{ .name = "sceFontSupportExternalFonts", .function = trace.wrap("sceFontSupportExternalFonts", &supportExternalFonts), .expect_id = "mz2iTY0MK4A" },
    .{ .name = "sceFontAttachDeviceCacheBuffer", .function = trace.wrap("sceFontAttachDeviceCacheBuffer", &attachDeviceCacheBuffer), .expect_id = "CUKn5pX-NVY" },
    .{ .name = "sceFontCreateRendererWithEdition", .function = trace.wrap("sceFontCreateRendererWithEdition", &createRenderer), .expect_id = "WaSFJoRWXaI" },
    .{ .name = "sceFontRenderSurfaceInit", .function = trace.wrap("sceFontRenderSurfaceInit", &renderSurfaceInit), .expect_id = "gdUCnU0gHdI" },
    .{ .name = "sceFontRenderSurfaceSetScissor", .function = trace.wrap("sceFontRenderSurfaceSetScissor", &renderSurfaceSetScissor), .expect_id = "vRxf4d0ulPs" },
    .{ .name = "sceFontUnbindRenderer", .function = trace.wrap("sceFontUnbindRenderer", &unbindRenderer), .expect_id = "1QjhKxrsOB8" },
    .{ .name = "sceFontCloseFont", .function = trace.wrap("sceFontCloseFont", &closeFont), .expect_id = "vzHs3C8lWJk" },
    .{ .name = "sceFontDestroyRenderer", .function = trace.wrap("sceFontDestroyRenderer", &destroyRenderer), .expect_id = "exAxkyVLt0s" },
    .{ .name = "sceFontDestroyLibrary", .function = trace.wrap("sceFontDestroyLibrary", &destroyLibrary), .expect_id = "FXP359ygujs" },
    .{ .name = "sceFontMemoryTerm", .function = trace.wrap("sceFontMemoryTerm", &memoryTerm), .expect_id = "h6hIgxXEiEc" },
    .{ .name = "sceFontOpenFontMemory", .function = trace.wrap("sceFontOpenFontMemory", &openFontMemory), .expect_id = "KXUpebrFk1U" },
    .{ .name = "sceFontBindRenderer", .function = trace.wrap("sceFontBindRenderer", &bindRenderer), .expect_id = "3OdRkSjOcog" },
    .{ .name = "sceFontOpenFontSet", .function = trace.wrap("sceFontOpenFontSet", &openFontSet), .expect_id = "cKYtVmeSTcw" },
    .{ .name = "sceFontGetCharGlyphMetrics", .function = trace.wrap("sceFontGetCharGlyphMetrics", &glyphMetrics), .expect_id = "L97d+3OgMlE" },
    .{ .name = "sceFontRenderCharGlyphImageHorizontal", .function = trace.wrap("sceFontRenderCharGlyphImageHorizontal", &renderGlyph), .expect_id = "kAenWy1Zw5o" },
    .{ .name = "sceFontSetScalePixel", .function = trace.wrap("sceFontSetScalePixel", &setScalePixel), .expect_id = "N1EBMeGhf7E" },
};

pub const ft_exports = [_]symbols.Export{
    .{ .name = "sceFontSelectLibraryFt", .function = trace.wrap("sceFontSelectLibraryFt", &selectLibrary), .expect_id = "oM+XCzVG3oM" },
    .{ .name = "sceFontSelectRendererFt", .function = trace.wrap("sceFontSelectRendererFt", &selectRenderer), .expect_id = "Xx974EW-QFY" },
};

test "font writes invalidate GPU watches and reject read-only guest surfaces" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const bytes = 64 * 1024;
    var space = try memory.AddressSpace.initWithDirectMemory(std.testing.allocator, bytes);
    defer space.deinit();
    const address = memory.user.start;
    try space.mapFixed(address, bytes, .read_write, .direct_memory, 0);
    kernel_memory.attachAddressSpace(&space);
    defer kernel_memory.attachAddressSpace(null);
    reset();
    defer reset();
    var library: usize = 0;
    var font: usize = 0;
    try std.testing.expectEqual(errno.ok, createLibrary(null, 0, 0, &library));
    try std.testing.expectEqual(errno.ok, openFontSet(library, 0, 0, 0, &font));
    var surface: RenderSurface = undefined;
    renderSurfaceInit(&surface, address, 128, 1, 128, 64);
    space.enableGpuMemoryTracking();
    const before = try space.trackGpuRead(address, bytes);
    try std.testing.expect(before != 0);
    try std.testing.expect(!memory.isHostRangeWritable(address, bytes));
    try std.testing.expectEqual(errno.ok, renderGlyph(font, 'A', &surface, 8, 24, null, null));
    try std.testing.expect(space.gpuGeneration(address, bytes) != before);
    try std.testing.expect(std.mem.indexOfNone(u8, @as([*]const u8, @ptrFromInt(address))[0..8192], &.{0}) != null);
    try space.protect(address, bytes, .read_only);
    try std.testing.expectEqual(errno.KernelError.efault.raw(), renderGlyph(font, 'W', &surface, 8, 24, null, null));
    surface.buffer = 1;
    try std.testing.expectEqual(errno.KernelError.efault.raw(), renderGlyph(font, 'W', &surface, 8, 24, null, null));
    try std.testing.expectEqual(errno.KernelError.efault.raw(), openFontMemory(library, 1, 1024, 0, &font));
}

test "font device cache owns or borrows storage and backs rendered transfer images" {
    reset();
    defer reset();
    var library: usize = 0;
    var font: usize = 0;
    try std.testing.expectEqual(errno.ok, createLibrary(null, 0, 0, &library));
    try std.testing.expectEqual(errno.ok, openFontSet(library, 0, 0, 0, &font));
    var buffer: [4096]u8 = @splat(0xaa);
    try std.testing.expectEqual(invalid_parameter, attachDeviceCacheBuffer(0, @intFromPtr(&buffer), buffer.len));
    try std.testing.expectEqual(errno.ok, attachDeviceCacheBuffer(library, @intFromPtr(&buffer), buffer.len));
    var result = RenderOutput{};
    try std.testing.expectEqual(errno.ok, renderGlyph(font, 'W', null, 0, 0, null, &result));
    const transfer: *const TransImage = @ptrFromInt(result.trans_image);
    try std.testing.expectEqual(@intFromPtr(&buffer), transfer.address);
    try std.testing.expect(transfer.width != 0 and transfer.height != 0);
    const bytes = transfer.width * transfer.height;
    try std.testing.expect(std.mem.indexOfNone(u8, buffer[0..bytes], &.{0}) != null);
    try std.testing.expectEqual(@as(u8, 0xaa), buffer[bytes]);
    try std.testing.expectEqual(errno.ok, attachDeviceCacheBuffer(library, 0, 1024 * 1024));
    const index = std.mem.indexOfScalar(usize, &libraries, library).?;
    try std.testing.expect(device_caches[index].owned);
    try std.testing.expectEqual(errno.ok, renderGlyph(font, 'A', null, 0, 0, null, &result));
    try std.testing.expectEqual(@intFromPtr(device_caches[index].bytes.ptr), transfer.address);
    try std.testing.expectEqual(errno.ok, destroyLibrary(&library));
    try std.testing.expectEqual(@as(usize, 0), device_caches[index].bytes.len);
}

test "font ABI structures retain firmware sizes and offsets" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(FontMemory));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(GlyphMetrics));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(RenderSurface));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(RenderOutput));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(RenderOutput, "update_rect"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(RenderOutput, "image_metrics"));
    var db: symbols.Database = .{};
    defer db.deinit(std.testing.allocator);
    try db.addLibrary(std.testing.allocator, .{ .name = "libSceFont" }, .{ .name = "libSceFont" }, &exports);
}

test "font handles own independent faces, scale and lifetime" {
    reset();
    defer reset();
    var library: usize = 0;
    var renderer: usize = 0;
    var first: usize = 0;
    var second: usize = 0;
    try std.testing.expectEqual(errno.ok, createLibrary(null, 0, 0, &library));
    try std.testing.expectEqual(errno.ok, createRenderer(null, 0, 0, &renderer));
    try std.testing.expectEqual(errno.ok, openFontSet(library, 0, 0, 0, &first));
    try std.testing.expectEqual(errno.ok, bindRenderer(first, renderer));
    try std.testing.expectEqual(errno.ok, setScalePixel(first, 20, 20));
    try std.testing.expectEqual(errno.ok, openFontInstance(first, 0, &second));
    try std.testing.expect(first != second);
    try std.testing.expectEqual(errno.ok, setScalePixel(second, 40, 40));
    var small: GlyphMetrics = undefined;
    var large: GlyphMetrics = undefined;
    try std.testing.expectEqual(errno.ok, glyphMetrics(first, 'W', &small));
    try std.testing.expectEqual(errno.ok, glyphMetrics(second, 'W', &large));
    try std.testing.expect(large.horizontal_advance > small.horizontal_advance * 1.9);
    try std.testing.expectEqual(errno.ok, closeFont(first));
    try std.testing.expectEqual(invalid_font, glyphMetrics(first, 'A', &small));
    try std.testing.expectEqual(errno.ok, glyphMetrics(second, 0x416, &large));
    try std.testing.expectEqual(errno.ok, destroyRenderer(&renderer));
    try std.testing.expectEqual(errno.ok, destroyLibrary(&library));
    try std.testing.expectEqual(invalid_font, closeFont(second));
    try std.testing.expectEqual(@as(usize, 0), library);
}

test "font clipped rasterization preserves bearings, padding and output bounds" {
    var pixels = [_]u8{ 10, 20, 30, 40, 50, 60 };
    const glyph: raster.Glyph = .{ .pixels = &pixels, .metrics = .{}, .width = 3, .height = 2, .left = -1, .top = 2 };
    var dest = [_]u8{0xcc} ** 24;
    var surface: RenderSurface = undefined;
    renderSurfaceInit(&surface, @intFromPtr(&dest), 8, 1, 4, 3);
    var rect: Rect = undefined;
    try std.testing.expectEqual(errno.ok, paint(&glyph, &surface, 0, 1, &rect));
    try std.testing.expectEqualSlices(u8, &.{ 50, 60, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc }, dest[0..8]);
    try std.testing.expectEqual(@as(u32, 2), rect.width);
    try std.testing.expectEqual(@as(u32, 1), rect.height);
    for (dest[8..]) |byte| try std.testing.expectEqual(@as(u8, 0xcc), byte);
    renderSurfaceSetScissor(&surface, 1, 0, 2, 1);
    @memset(&dest, 0xcc);
    try std.testing.expectEqual(errno.ok, paint(&glyph, &surface, 0, 1, &rect));
    try std.testing.expectEqual(@as(u8, 0xcc), dest[0]);
    try std.testing.expectEqual(@as(u8, 60), dest[1]);
    try std.testing.expectEqual(@as(u32, 1), rect.width);
    surface.width_bytes = 1;
    try std.testing.expectEqual(invalid_parameter, paint(&glyph, &surface, 0, 1, &rect));
}

test "font renders from copied guest bytes with optional outputs and render scale" {
    reset();
    defer reset();
    var library: usize = 0;
    var handle: usize = 0;
    try std.testing.expectEqual(errno.ok, createLibrary(null, 0, 0, &library));
    const data = try std.testing.allocator.dupe(u8, raster.fallback_font);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(errno.ok, openFontMemory(library, @intFromPtr(data.ptr), @intCast(data.len), 0, &handle));
    @memset(data, 0);
    var pixels = [_]u8{0} ** (96 * 64 * 4);
    var surface: RenderSurface = undefined;
    renderSurfaceInit(&surface, @intFromPtr(&pixels), 96 * 4, 4, 96, 64);
    var result: RenderOutput = undefined;
    try std.testing.expectEqual(errno.ok, setupRenderScalePixel(handle, 32, 32));
    try std.testing.expectEqual(errno.ok, renderGlyph(handle, 0x416, &surface, 8, 44, null, &result));
    try std.testing.expect(result.update_rect.width > 0 and result.update_rect.height > 0);
    try std.testing.expect(result.trans_image != 0);
    try std.testing.expect(std.mem.indexOfNone(u8, &pixels, &.{0}) != null);
    for (0..pixels.len / 4) |i| {
        const expected: [4]u8 = @splat(pixels[i * 4]);
        try std.testing.expectEqualSlices(u8, &expected, pixels[i * 4 ..][0..4]);
    }
    var base: GlyphMetrics = undefined;
    var rendered: GlyphMetrics = undefined;
    try std.testing.expectEqual(errno.ok, glyphMetrics(handle, 'A', &base));
    try std.testing.expectEqual(errno.ok, renderGlyphMetrics(handle, 'A', &rendered));
    try std.testing.expect(rendered.horizontal_advance > base.horizontal_advance * 1.9);
    try std.testing.expectEqual(errno.ok, renderGlyph(handle, ' ', &surface, 0, 20, null, &result));
    try std.testing.expectEqual(@as(u32, 0), result.update_rect.width);
    try std.testing.expectEqual(errno.ok, renderGlyph(handle, 'A', null, 0, 0, null, null));
    try std.testing.expectEqual(invalid_parameter, setScalePixel(handle, -1, 20));
    try std.testing.expectEqual(invalid_parameter, renderGlyph(handle, 'A', &surface, std.math.nan(f32), 0, null, null));
    try std.testing.expectEqual(unsupported_code, renderGlyph(handle, 0x110000, &surface, 0, 20, null, null));
}

test "font atlas metrics and rendering accept the complete Latin-1 range including DEL" {
    reset();
    defer reset();
    var library: usize = 0;
    var handle: usize = 0;
    try std.testing.expectEqual(errno.ok, createLibrary(null, 0, 0, &library));
    try std.testing.expectEqual(errno.ok, openFontSet(library, 0, 0, 0, &handle));
    var pixels = [_]u8{0} ** (32 * 32);
    var surface: RenderSurface = undefined;
    renderSurfaceInit(&surface, @intFromPtr(&pixels), 32, 1, 32, 32);
    // The ImGui atlas used by Jurassic Park requests every code in this range.
    // Rejecting U+007F used to trigger CalcGlyphInfo's assertion and stop the
    // game's main thread before its first real GPU submission.
    for (0x20..0x100) |code| {
        var metrics: GlyphMetrics = undefined;
        try std.testing.expectEqual(errno.ok, glyphMetrics(handle, @intCast(code), &metrics));
        var rendered: GlyphMetrics = undefined;
        try std.testing.expectEqual(errno.ok, renderGlyphMetrics(handle, @intCast(code), &rendered));
        @memset(&pixels, 0);
        try std.testing.expectEqual(errno.ok, renderGlyph(handle, @intCast(code), &surface, 4, 24, null, null));
        if (code == 0x7f) {
            try std.testing.expect(metrics.horizontal_advance > 0);
            try std.testing.expect(std.mem.indexOfNone(u8, &pixels, &.{0}) != null);
        }
    }
}
