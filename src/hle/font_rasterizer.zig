// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Host-side outline rasterization. The caller serializes each Face. Font data
//! is owned, so closing or remapping a title's source buffer cannot invalidate
//! FreeType's lazy table reads. Glyph storage stays valid until eviction/close.
const std = @import("std");
const pair_kerning = @import("font_kerning.zig");
const ft = @cImport({
    // Zig 0.16 cannot translate MinGW's fortified wide-string inline helpers.
    // This affects declarations only; the separately compiled C library keeps
    // the build mode's normal checks.
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
});

pub const fallback_font = @embedFile("fonts/NotoSans-Regular.ttf");
pub const Error = error{ InvalidFont, InvalidScale, UnsupportedCode, RasterizationFailed, OutOfMemory };
pub const Metrics = extern struct {
    width: f32 = 0,
    height: f32 = 0,
    horizontal_bearing_x: f32 = 0,
    horizontal_bearing_y: f32 = 0,
    horizontal_advance: f32 = 0,
    vertical_bearing_x: f32 = 0,
    vertical_bearing_y: f32 = 0,
    vertical_advance: f32 = 0,
};
pub const Style = struct {
    width: f32 = 16,
    height: f32 = 16,
    slant: f32 = 0,
    weight_x: f32 = 0,
    weight_y: f32 = 0,

    pub fn valid(self: Style) bool {
        return std.math.isFinite(self.width) and std.math.isFinite(self.height) and
            std.math.isFinite(self.slant) and self.width >= 1.0 / 64.0 and self.height >= 1.0 / 64.0 and
            self.width <= 1024 and self.height <= 1024 and @abs(self.slant) <= 1 and
            std.math.isFinite(self.weight_x) and std.math.isFinite(self.weight_y) and
            @abs(self.weight_x) <= 0.04 and @abs(self.weight_y) <= 0.04;
    }
};
pub const Glyph = struct {
    metrics: Metrics,
    pixels: []u8,
    width: u32,
    height: u32,
    left: i32,
    top: i32,
};
const CacheEntry = struct {
    index: u32,
    style: Style,
    age: u64,
    glyph: Glyph,
};
const KernPair = struct { left: u32, right: u32, units: i32 };

pub const Face = struct {
    allocator: std.mem.Allocator,
    library: ft.FT_Library,
    face: ft.FT_Face,
    data: []u8,
    cache: [64]?CacheEntry = @splat(null),
    cache_bytes: usize = 0,
    clock: u64 = 0,
    rasterizations: usize = 0,
    gpos: ?[]const u8 = null,
    kern_cache: [128]?KernPair = @splat(null),
    const cache_budget = 8 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator, data: []const u8) Error!Face {
        if (data.len == 0 or data.len > 64 * 1024 * 1024) return error.InvalidFont;
        const copy = try allocator.dupe(u8, data);
        errdefer allocator.free(copy);
        var library: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&library) != 0) return error.OutOfMemory;
        errdefer _ = ft.FT_Done_FreeType(library);
        var face: ft.FT_Face = null;
        if (ft.FT_New_Memory_Face(library, copy.ptr, @intCast(copy.len), 0, &face) != 0) return error.InvalidFont;
        errdefer _ = ft.FT_Done_Face(face);
        if (face.*.face_flags & ft.FT_FACE_FLAG_SCALABLE == 0 or face.*.units_per_EM == 0) return error.InvalidFont;
        if (ft.FT_Select_Charmap(face, ft.FT_ENCODING_UNICODE) != 0) return error.InvalidFont;
        return .{ .allocator = allocator, .library = library, .face = face, .data = copy, .gpos = pair_kerning.findGpos(copy) };
    }

    pub fn deinit(self: *Face) void {
        for (&self.cache) |*entry| self.evict(entry);
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.library);
        self.allocator.free(self.data);
        self.* = undefined;
    }

    fn evict(self: *Face, entry: *?CacheEntry) void {
        if (entry.*) |value| {
            self.cache_bytes -= value.glyph.pixels.len;
            self.allocator.free(value.glyph.pixels);
            entry.* = null;
        }
    }

    fn glyphIndex(self: *Face, code: u32) Error!u32 {
        // Font HLE also accepts explicit glyph IDs in the low 16 bits.
        const index: u32 = if (code & 0x80000000 != 0)
            code & 0xffff
        else blk: {
            if (code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff)) return error.UnsupportedCode;
            break :blk ft.FT_Get_Char_Index(self.face, code);
        };
        // A missing cmap entry selects the face's .notdef glyph (index zero).
        // Atlas builders can request entire Unicode ranges, including DEL and
        // other characters absent from the face; these are still valid codes.
        if (index >= self.face.*.num_glyphs) return error.UnsupportedCode;
        return index;
    }

    fn setStyle(self: *Face, style: Style) Error!void {
        if (!style.valid()) return error.InvalidScale;
        if (ft.FT_Set_Char_Size(self.face, @intFromFloat(@round(style.width * 64)), @intFromFloat(@round(style.height * 64)), 72, 72) != 0)
            return error.InvalidScale;
        var transform: ft.FT_Matrix = .{ .xx = 65536, .xy = @intFromFloat(style.slant * 65536), .yx = 0, .yy = 65536 };
        ft.FT_Set_Transform(self.face, &transform, null);
    }

    pub fn getGlyph(self: *Face, code: u32, style: Style) Error!*const Glyph {
        if (!style.valid()) return error.InvalidScale;
        const index = try self.glyphIndex(code);
        self.clock +%= 1;
        var victim: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (&self.cache, 0..) |*entry, i| {
            if (entry.*) |*value| {
                if (value.index == index and std.meta.eql(value.style, style)) {
                    value.age = self.clock;
                    return &value.glyph;
                }
                if (value.age < oldest) {
                    oldest = value.age;
                    victim = i;
                }
            } else {
                oldest = 0;
                victim = i;
            }
        }
        try self.setStyle(style);
        if (ft.FT_Load_Glyph(self.face, index, ft.FT_LOAD_NO_HINTING | ft.FT_LOAD_NO_BITMAP) != 0)
            return error.RasterizationFailed;
        const slot = self.face.*.glyph;
        const m = slot.*.metrics;
        var metrics: Metrics = .{
            .width = fixed(m.width),
            .height = fixed(m.height),
            .horizontal_bearing_x = fixed(m.horiBearingX),
            .horizontal_bearing_y = fixed(m.horiBearingY),
            .horizontal_advance = fixed(m.horiAdvance),
            .vertical_bearing_x = fixed(m.vertBearingX),
            .vertical_bearing_y = fixed(m.vertBearingY),
            .vertical_advance = fixed(m.vertAdvance),
        };
        if (style.weight_x != 0 or style.weight_y != 0) {
            if (ft.FT_Outline_EmboldenXY(&slot.*.outline, @intFromFloat(@round(style.width * style.weight_x * 64)), @intFromFloat(@round(style.height * style.weight_y * 64))) != 0)
                return error.RasterizationFailed;
        }
        if (style.slant != 0 or style.weight_x != 0 or style.weight_y != 0) {
            var box: ft.FT_BBox = undefined;
            ft.FT_Outline_Get_CBox(&slot.*.outline, &box);
            metrics.width = fixed(box.xMax - box.xMin);
            metrics.height = fixed(box.yMax - box.yMin);
            metrics.horizontal_bearing_x = fixed(box.xMin);
            metrics.horizontal_bearing_y = fixed(box.yMax);
        }
        if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_NORMAL) != 0) return error.RasterizationFailed;
        const bitmap = slot.*.bitmap;
        if (bitmap.width > 4096 or bitmap.rows > 4096) return error.RasterizationFailed;
        const length: usize = @as(usize, bitmap.width) * bitmap.rows;
        if (length > cache_budget or (length != 0 and bitmap.pixel_mode != ft.FT_PIXEL_MODE_GRAY)) return error.RasterizationFailed;
        const pixels = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(pixels);
        for (0..bitmap.rows) |y| {
            const pitch: usize = @intCast(@abs(bitmap.pitch));
            const source_y = if (bitmap.pitch < 0) bitmap.rows - 1 - y else y;
            if (bitmap.width != 0) @memcpy(pixels[y * bitmap.width ..][0..bitmap.width], bitmap.buffer[source_y * pitch ..][0..bitmap.width]);
        }
        self.evict(&self.cache[victim]);
        if (self.cache_bytes + length > cache_budget) {
            // Large glyphs cannot let the cache grow without bound.
            for (&self.cache) |*entry| {
                if (self.cache_bytes + length <= cache_budget) break;
                self.evict(entry);
            }
        }
        self.cache_bytes += length;
        self.rasterizations += 1;
        self.cache[victim] = .{ .index = index, .style = style, .age = self.clock, .glyph = .{
            .metrics = metrics,
            .pixels = pixels,
            .width = bitmap.width,
            .height = bitmap.rows,
            .left = slot.*.bitmap_left,
            .top = slot.*.bitmap_top,
        } };
        return &self.cache[victim].?.glyph;
    }

    pub fn kerning(self: *Face, left: u32, right: u32, style: Style) Error!f32 {
        if (!style.valid()) return error.InvalidScale;
        if (left == 0) return 0;
        const first = try self.glyphIndex(left);
        const second = try self.glyphIndex(right);
        if (first == 0 or second == 0) return 0;
        const scale = style.width / @as(f32, @floatFromInt(self.face.*.units_per_EM));
        const cached = &self.kern_cache[(first *% 31 +% second) % self.kern_cache.len];
        if (cached.*) |pair| if (pair.left == first and pair.right == second) return @as(f32, @floatFromInt(pair.units)) * scale;
        var delta: ft.FT_Vector = undefined;
        if (ft.FT_Get_Kerning(self.face, first, second, ft.FT_KERNING_UNSCALED, &delta) != 0) return error.RasterizationFailed;
        var units: i32 = @intCast(delta.x);
        if (self.face.*.face_flags & ft.FT_FACE_FLAG_KERNING == 0) {
            if (self.gpos) |table| units = pair_kerning.advance(table, first, second);
        }
        cached.* = .{ .left = first, .right = second, .units = units };
        return @as(f32, @floatFromInt(units)) * scale;
    }

    pub fn horizontalLayout(self: *Face, style: Style) Error![3]f32 {
        try self.setStyle(style);
        const scale = style.height / @as(f32, @floatFromInt(self.face.*.units_per_EM));
        const height = @as(f32, @floatFromInt(self.face.*.height)) * scale;
        return .{ @as(f32, @floatFromInt(self.face.*.ascender)) * scale, height, height };
    }
};

fn fixed(value: anytype) f32 {
    return @as(f32, @floatFromInt(value)) / 64;
}

test "font rasterizer loads Latin and Cyrillic outlines and caches glyphs" {
    var face = try Face.init(std.testing.allocator, fallback_font);
    defer face.deinit();
    const narrow = (try face.getGlyph('i', .{})).metrics;
    const wide = try face.getGlyph('W', .{});
    try std.testing.expect(wide.metrics.horizontal_advance > narrow.horizontal_advance);
    const cyrillic = try face.getGlyph(0x416, .{});
    try std.testing.expect(std.mem.indexOfNone(u8, cyrillic.pixels, &.{0}) != null);
    const count = face.rasterizations;
    _ = try face.getGlyph(0x416, .{});
    try std.testing.expectEqual(count, face.rasterizations);
    const larger = try face.getGlyph('W', .{ .width = 32, .height = 32 });
    try std.testing.expect(larger.metrics.horizontal_advance > wide.metrics.horizontal_advance * 1.9);
    const space = try face.getGlyph(' ', .{});
    try std.testing.expectEqual(@as(usize, 0), space.pixels.len);
    try std.testing.expect(space.metrics.horizontal_advance > 0);
    const av_kerning = try face.kerning('A', 'V', .{});
    try std.testing.expect(av_kerning < 0);
    const layout = try face.horizontalLayout(.{});
    try std.testing.expect(layout[0] > 0 and layout[1] >= layout[0]);
}

test "font rasterizer rejects malformed data and invalid sizes or character codes" {
    try std.testing.expectError(error.InvalidFont, Face.init(std.testing.allocator, "not a font"));
    try std.testing.expectError(error.InvalidFont, Face.init(std.testing.allocator, fallback_font[0..128]));
    var face = try Face.init(std.testing.allocator, fallback_font);
    defer face.deinit();
    try std.testing.expectError(error.InvalidScale, face.getGlyph('A', .{ .width = std.math.nan(f32) }));
    try std.testing.expectError(error.InvalidScale, face.getGlyph('A', .{ .height = 100000 }));
    try std.testing.expectError(error.UnsupportedCode, face.getGlyph(0xd800, .{}));
    try std.testing.expectError(error.UnsupportedCode, face.getGlyph(0x110000, .{}));
    try std.testing.expectError(error.UnsupportedCode, face.getGlyph(0x8000ffff, .{}));
    for (33..200) |code| _ = try face.getGlyph(@intCast(code), .{});
    try std.testing.expect(face.cache_bytes <= Face.cache_budget);
}

test "font missing characters share the cached notdef outline and have no kerning" {
    var face = try Face.init(std.testing.allocator, fallback_font);
    defer face.deinit();
    const notdef = try face.getGlyph(0x80000000, .{});
    try std.testing.expect(notdef.pixels.len != 0);
    try std.testing.expect(std.mem.indexOfNone(u8, notdef.pixels, &.{0}) != null);
    const count = face.rasterizations;
    for ([_]u32{ 0x7f, 0x10ffff }) |code| {
        const missing = try face.getGlyph(code, .{});
        try std.testing.expectEqual(notdef, missing);
        try std.testing.expectEqual(count, face.rasterizations);
        try std.testing.expectEqual(@as(f32, 0), try face.kerning('A', code, .{}));
        try std.testing.expectEqual(@as(f32, 0), try face.kerning(code, 'V', .{}));
    }
}
