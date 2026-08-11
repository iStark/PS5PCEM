// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Software implementation of the firmware PNG decoder.
//!
//! The API receives complete PNG files in guest memory and writes unpacked
//! RGBA/BGRA scanlines back to guest memory. Keeping the decoder here avoids a
//! host graphics dependency during title bootstrap (splash screens commonly
//! arrive before the renderer has initialized).

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const kernel_memory = @import("kernel_memory.zig");
const symbols = @import("../symbols.zig");
const trace = @import("../trace.zig");

const error_invalid_addr: i32 = @bitCast(@as(u32, 0x8069_0001));
const error_invalid_size: i32 = @bitCast(@as(u32, 0x8069_0002));
const error_invalid_param: i32 = @bitCast(@as(u32, 0x8069_0003));
const error_invalid_handle: i32 = @bitCast(@as(u32, 0x8069_0004));
const error_invalid_work_memory: i32 = @bitCast(@as(u32, 0x8069_0005));
const error_invalid_data: i32 = @bitCast(@as(u32, 0x8069_0010));
const error_decode: i32 = @bitCast(@as(u32, 0x8069_0012));

const attribute_bit_depth_16: u32 = 1;
const color_grayscale: u16 = 2;
const color_rgb: u16 = 3;
const color_clut: u16 = 4;
const color_grayscale_alpha: u16 = 18;
const color_rgba: u16 = 19;
const pixel_rgba: u16 = 0;
const pixel_bgra: u16 = 1;
const image_adam7: u32 = 1;
const image_trns: u32 = 2;
const context_magic: u64 = 0x5053_3545_504e_4744; // PS5EPNGD
const maximum_decode_bytes: usize = 512 * 1024 * 1024;

pub const CreateParam = extern struct {
    this_size: u32,
    attribute: u32,
    max_image_width: u32,
};

pub const DecodeParam = extern struct {
    png_mem_addr: u64,
    image_mem_addr: u64,
    png_mem_size: u32,
    image_mem_size: u32,
    pixel_format: u16,
    alpha_value: u16,
    image_pitch: u32,
};

pub const ParseParam = extern struct {
    png_mem_addr: u64,
    png_mem_size: u32,
    reserved: u32,
};

pub const ImageInfo = extern struct {
    image_width: u32,
    image_height: u32,
    color_space: u16,
    bit_depth: u16,
    image_flag: u32,
};

const Context = extern struct {
    magic: u64,
};

const Header = struct {
    width: u32,
    height: u32,
    color_type: u8,
    color_space: u16,
    bit_depth: u8,
    image_flag: u32,
};

fn accessible(address: u64, size: u64) bool {
    return address != 0 and size != 0 and kernel_memory.isGuestRangeAccessible(address, size);
}

fn be16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}

fn be32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        bytes[3];
}

fn validDepth(color_type: u8, depth: u8) bool {
    return switch (color_type) {
        0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        2, 4, 6 => depth == 8 or depth == 16,
        3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        else => false,
    };
}

fn parseHeader(bytes: []const u8) ?Header {
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], &signature)) return null;
    if (be32(bytes[8..12]) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;

    const width = be32(bytes[16..20]);
    const height = be32(bytes[20..24]);
    const depth = bytes[24];
    const color_type = bytes[25];
    if (width == 0 or height == 0 or !validDepth(color_type, depth)) return null;
    if (bytes[26] != 0 or bytes[27] != 0 or bytes[28] > 1) return null;

    const color_space: u16 = switch (color_type) {
        0 => color_grayscale,
        2 => color_rgb,
        3 => color_clut,
        4 => color_grayscale_alpha,
        6 => color_rgba,
        else => return null,
    };
    var flags: u32 = if (bytes[28] == 1) image_adam7 else 0;
    var offset: usize = 33;
    while (offset <= bytes.len and bytes.len - offset >= 12) {
        const length: usize = be32(bytes[offset .. offset + 4]);
        const chunk_end = std.math.add(usize, offset, 12 + length) catch return null;
        if (chunk_end > bytes.len) return null;
        const kind = bytes[offset + 4 .. offset + 8];
        if (std.mem.eql(u8, kind, "tRNS")) flags |= image_trns;
        if (std.mem.eql(u8, kind, "IDAT") or std.mem.eql(u8, kind, "IEND")) break;
        offset = chunk_end;
    }
    return .{
        .width = width,
        .height = height,
        .color_type = color_type,
        .color_space = color_space,
        .bit_depth = depth,
        .image_flag = flags,
    };
}

fn fillInfo(header: Header, output: *ImageInfo) void {
    output.* = .{
        .image_width = header.width,
        .image_height = header.height,
        .color_space = header.color_space,
        .bit_depth = header.bit_depth,
        .image_flag = header.image_flag,
    };
}

fn checkedHeader(address: u64, size: u32) ?Header {
    if (!accessible(address, size)) return null;
    const bytes: [*]const u8 = @ptrFromInt(address);
    return parseHeader(bytes[0..size]);
}

pub fn queryMemorySize(param: ?*const CreateParam) callconv(abi.guest) i32 {
    const input = param orelse return error_invalid_param;
    if (!accessible(@intFromPtr(input), @sizeOf(CreateParam))) return error_invalid_param;
    if (input.attribute > attribute_bit_depth_16) return error_invalid_param;
    if (input.max_image_width == 0) return error_invalid_size;
    return @sizeOf(Context);
}

pub fn create(
    param: ?*const CreateParam,
    memory_address: u64,
    memory_size: u32,
    handle: ?*u64,
) callconv(abi.guest) i32 {
    const input = param orelse return error_invalid_param;
    const output = handle orelse return error_invalid_param;
    if (!accessible(@intFromPtr(input), @sizeOf(CreateParam)) or
        !accessible(@intFromPtr(output), @sizeOf(u64))) return error_invalid_param;
    if (input.attribute > attribute_bit_depth_16) return error_invalid_param;
    if (input.max_image_width == 0) return error_invalid_size;
    if (memory_address == 0) return error_invalid_addr;
    if (memory_size < @sizeOf(Context)) return error_invalid_work_memory;
    if (!accessible(memory_address, @sizeOf(Context))) return error_invalid_addr;
    const context: *Context = @ptrFromInt(memory_address);
    context.magic = context_magic;
    output.* = memory_address;
    return errno.ok;
}

fn validContext(address: u64) ?*Context {
    if (!accessible(address, @sizeOf(Context))) return null;
    const context: *Context = @ptrFromInt(address);
    return if (context.magic == context_magic) context else null;
}

pub fn delete(handle: u64) callconv(abi.guest) i32 {
    const context = validContext(handle) orelse return error_invalid_handle;
    context.magic = 0;
    return errno.ok;
}

pub fn parse(
    param: ?*const ParseParam,
    image_info: ?*ImageInfo,
) callconv(abi.guest) i32 {
    const input = param orelse return error_invalid_param;
    const output = image_info orelse return error_invalid_param;
    if (!accessible(@intFromPtr(input), @sizeOf(ParseParam)) or
        !accessible(@intFromPtr(output), @sizeOf(ImageInfo))) return error_invalid_param;
    if (input.png_mem_addr == 0) return error_invalid_addr;
    if (input.reserved != 0) return error_invalid_param;
    const header = checkedHeader(input.png_mem_addr, input.png_mem_size) orelse return error_invalid_data;
    fillInfo(header, output);
    return errno.ok;
}

const Chunks = struct {
    idat: std.ArrayList(u8) = .empty,
    palette: []const u8 = &.{},
    transparency: []const u8 = &.{},

    fn deinit(self: *Chunks, allocator: std.mem.Allocator) void {
        self.idat.deinit(allocator);
    }
};

fn collectChunks(allocator: std.mem.Allocator, bytes: []const u8, chunks: *Chunks) !void {
    var offset: usize = 33;
    var saw_end = false;
    while (offset <= bytes.len and bytes.len - offset >= 12) {
        const length: usize = be32(bytes[offset .. offset + 4]);
        const data_start = offset + 8;
        const data_end = std.math.add(usize, data_start, length) catch return error.InvalidData;
        const chunk_end = std.math.add(usize, data_end, 4) catch return error.InvalidData;
        if (chunk_end > bytes.len) return error.InvalidData;
        const kind = bytes[offset + 4 .. offset + 8];
        if (std.mem.eql(u8, kind, "IDAT")) {
            if (chunks.idat.items.len + length > maximum_decode_bytes) return error.InvalidData;
            try chunks.idat.appendSlice(allocator, bytes[data_start..data_end]);
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            chunks.palette = bytes[data_start..data_end];
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            chunks.transparency = bytes[data_start..data_end];
        } else if (std.mem.eql(u8, kind, "IEND")) {
            saw_end = true;
            break;
        }
        offset = chunk_end;
    }
    if (!saw_end or chunks.idat.items.len == 0) return error.InvalidData;
}

fn channels(color_type: u8) usize {
    return switch (color_type) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => 0,
    };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const ai: i32 = a;
    const bi: i32 = b;
    const ci: i32 = c;
    const prediction = ai + bi - ci;
    const pa = @abs(prediction - ai);
    const pb = @abs(prediction - bi);
    const pc = @abs(prediction - ci);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

fn unfilter(raw: []u8, row_bytes: usize, bytes_per_pixel: usize, height: usize) bool {
    const stride = row_bytes + 1;
    for (0..height) |y| {
        const filter = raw[y * stride];
        const row = raw[y * stride + 1 ..][0..row_bytes];
        const previous: ?[]const u8 = if (y == 0) null else raw[(y - 1) * stride + 1 ..][0..row_bytes];
        for (0..row_bytes) |x| {
            const left: u8 = if (x >= bytes_per_pixel) row[x - bytes_per_pixel] else 0;
            const above: u8 = if (previous) |prior| prior[x] else 0;
            const upper_left: u8 = if (previous) |prior| if (x >= bytes_per_pixel) prior[x - bytes_per_pixel] else 0 else 0;
            row[x] +%= switch (filter) {
                0 => 0,
                1 => left,
                2 => above,
                3 => @intCast((@as(u16, left) + above) / 2),
                4 => paeth(left, above, upper_left),
                else => return false,
            };
        }
    }
    return true;
}

fn packedSample(row: []const u8, index: usize, depth: u8) u8 {
    const bit_index = index * depth;
    const shift: u3 = @intCast(8 - depth - @as(u8, @intCast(bit_index & 7)));
    const mask: u8 = (@as(u8, 1) << @intCast(depth)) - 1;
    return (row[bit_index / 8] >> shift) & mask;
}

fn scaleSample(value: u8, depth: u8) u8 {
    if (depth == 8) return value;
    const maximum: u16 = (@as(u16, 1) << @intCast(depth)) - 1;
    return @intCast((@as(u16, value) * 255 + maximum / 2) / maximum);
}

fn sample8(row: []const u8, sample_index: usize, depth: u8) u8 {
    return if (depth == 16) row[sample_index * 2] else row[sample_index];
}

fn sample16(row: []const u8, sample_index: usize, depth: u8) u16 {
    return if (depth == 16)
        be16(row[sample_index * 2 .. sample_index * 2 + 2])
    else
        row[sample_index];
}

fn writePixels(
    header: Header,
    chunks: Chunks,
    raw: []const u8,
    destination: [*]u8,
    pitch: usize,
    pixel_format: u16,
    alpha_value: u16,
) bool {
    const row_bytes = (@as(usize, header.width) * channels(header.color_type) * header.bit_depth + 7) / 8;
    const stride = row_bytes + 1;
    const default_alpha: u8 = @intCast(@min(alpha_value, 255));
    const has_source_alpha = header.color_type == 4 or header.color_type == 6 or chunks.transparency.len != 0;

    for (0..header.height) |y| {
        const source = raw[y * stride + 1 ..][0..row_bytes];
        const output = destination[y * pitch ..][0 .. @as(usize, header.width) * 4];
        for (0..header.width) |x| {
            var red: u8 = 0;
            var green: u8 = 0;
            var blue: u8 = 0;
            var alpha: u8 = if (has_source_alpha) 255 else default_alpha;
            switch (header.color_type) {
                0 => {
                    const gray = if (header.bit_depth < 8)
                        scaleSample(packedSample(source, x, header.bit_depth), header.bit_depth)
                    else
                        sample8(source, x, header.bit_depth);
                    red = gray;
                    green = gray;
                    blue = gray;
                    if (chunks.transparency.len >= 2) {
                        const raw_gray: u16 = if (header.bit_depth < 8)
                            packedSample(source, x, header.bit_depth)
                        else
                            sample16(source, x, header.bit_depth);
                        if (raw_gray == be16(chunks.transparency[0..2])) alpha = 0;
                    }
                },
                2 => {
                    const base = x * 3;
                    red = sample8(source, base, header.bit_depth);
                    green = sample8(source, base + 1, header.bit_depth);
                    blue = sample8(source, base + 2, header.bit_depth);
                    if (chunks.transparency.len >= 6 and
                        sample16(source, base, header.bit_depth) == be16(chunks.transparency[0..2]) and
                        sample16(source, base + 1, header.bit_depth) == be16(chunks.transparency[2..4]) and
                        sample16(source, base + 2, header.bit_depth) == be16(chunks.transparency[4..6])) alpha = 0;
                },
                3 => {
                    const index: usize = if (header.bit_depth == 8)
                        source[x]
                    else
                        packedSample(source, x, header.bit_depth);
                    const palette_offset = index * 3;
                    if (palette_offset + 3 > chunks.palette.len) return false;
                    red = chunks.palette[palette_offset];
                    green = chunks.palette[palette_offset + 1];
                    blue = chunks.palette[palette_offset + 2];
                    if (index < chunks.transparency.len) alpha = chunks.transparency[index];
                },
                4 => {
                    const base = x * 2;
                    red = sample8(source, base, header.bit_depth);
                    green = red;
                    blue = red;
                    alpha = sample8(source, base + 1, header.bit_depth);
                },
                6 => {
                    const base = x * 4;
                    red = sample8(source, base, header.bit_depth);
                    green = sample8(source, base + 1, header.bit_depth);
                    blue = sample8(source, base + 2, header.bit_depth);
                    alpha = sample8(source, base + 3, header.bit_depth);
                },
                else => return false,
            }
            const output_offset = x * 4;
            if (pixel_format == pixel_rgba) {
                output[output_offset..][0..4].* = .{ red, green, blue, alpha };
            } else {
                output[output_offset..][0..4].* = .{ blue, green, red, alpha };
            }
        }
    }
    return true;
}

pub fn decode(
    handle: u64,
    param: ?*const DecodeParam,
    image_info: ?*ImageInfo,
) callconv(abi.guest) i32 {
    _ = validContext(handle) orelse return error_invalid_handle;
    const input = param orelse return error_invalid_param;
    if (!accessible(@intFromPtr(input), @sizeOf(DecodeParam))) return error_invalid_param;
    if (input.png_mem_addr == 0 or input.image_mem_addr == 0) return error_invalid_addr;
    if (input.pixel_format != pixel_rgba and input.pixel_format != pixel_bgra) return error_invalid_param;
    if (!accessible(input.png_mem_addr, input.png_mem_size)) return error_invalid_addr;

    const png: [*]const u8 = @ptrFromInt(input.png_mem_addr);
    const bytes = png[0..input.png_mem_size];
    const header = parseHeader(bytes) orelse return error_invalid_data;
    if ((header.image_flag & image_adam7) != 0) return error_decode;
    if (image_info) |output| {
        if (!accessible(@intFromPtr(output), @sizeOf(ImageInfo))) return error_invalid_param;
        fillInfo(header, output);
    }

    const minimum_pitch = std.math.mul(usize, header.width, 4) catch return error_invalid_size;
    const pitch: usize = if (input.image_pitch == 0) minimum_pitch else input.image_pitch;
    if (pitch < minimum_pitch) return error_invalid_size;
    const output_size = std.math.add(
        usize,
        std.math.mul(usize, pitch, header.height - 1) catch return error_invalid_size,
        minimum_pitch,
    ) catch return error_invalid_size;
    if (output_size > input.image_mem_size or !accessible(input.image_mem_addr, output_size)) return error_invalid_size;

    const channel_count = channels(header.color_type);
    const bit_count = std.math.mul(usize, header.width, channel_count * header.bit_depth) catch return error_decode;
    const row_bytes = (bit_count + 7) / 8;
    const raw_size = std.math.mul(usize, row_bytes + 1, header.height) catch return error_decode;
    if (raw_size == 0 or raw_size > maximum_decode_bytes) return error_decode;

    const allocator = std.heap.smp_allocator;
    var chunks: Chunks = .{};
    defer chunks.deinit(allocator);
    collectChunks(allocator, bytes, &chunks) catch return error_invalid_data;

    const raw = allocator.alloc(u8, raw_size) catch return error_decode;
    defer allocator.free(raw);
    var compressed_reader: std.Io.Reader = .fixed(chunks.idat.items);
    var output_writer: std.Io.Writer = .fixed(raw);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&compressed_reader, .zlib, &window);
    const written = decompress.reader.streamRemaining(&output_writer) catch return error_decode;
    if (written != raw_size) return error_decode;

    const bytes_per_pixel = @max(@as(usize, 1), (channel_count * header.bit_depth + 7) / 8);
    if (!unfilter(raw, row_bytes, bytes_per_pixel, header.height)) return error_decode;
    const destination: [*]u8 = @ptrFromInt(input.image_mem_addr);
    if (!writePixels(header, chunks, raw, destination, pitch, input.pixel_format, input.alpha_value)) return error_decode;
    return if (header.width > 32767 or header.height > 32767)
        errno.ok
    else
        @intCast((header.width << 16) | header.height);
}

pub const exports = [_]symbols.Export{
    .{ .name = "scePngDecDelete", .function = trace.wrap("scePngDecDelete", &delete), .expect_id = "QbD+eENEwo8" },
    .{ .name = "scePngDecQueryMemorySize", .function = trace.wrap("scePngDecQueryMemorySize", &queryMemorySize), .expect_id = "-6srIGbLTIU" },
    .{ .name = "scePngDecCreate", .function = trace.wrap("scePngDecCreate", &create), .expect_id = "m0uW+8pFyaw" },
    .{ .name = "scePngDecParseHeader", .function = trace.wrap("scePngDecParseHeader", &parse), .expect_id = "U6h4e5JRPaQ" },
    .{ .name = "scePngDecDecode", .function = trace.wrap("scePngDecDecode", &decode), .expect_id = "WC216DD3El4" },
};

pub fn register(db: *symbols.Database, allocator: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(
        allocator,
        .{ .name = "libScePngDec", .version = 1 },
        .{ .name = "libScePngDec", .version_major = 1, .version_minor = 1 },
        &exports,
    );
}

test "PNG header exposes dimensions and transparency" {
    const header_bytes = [_]u8{
        0x89, 'P', 'N', 'G',  0x0d, 0x0a, 0x1a, 0x0a,
        0,    0,   0,   13,   'I',  'H',  'D',  'R',
        0,    0,   7,   0x80, 0,    0,    4,    0x38,
        8,    2,   0,   0,    0,    0,    0,    0,
        0,
    };
    const header = parseHeader(&header_bytes) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u32, 1920), header.width);
    try std.testing.expectEqual(@as(u32, 1080), header.height);
    try std.testing.expectEqual(color_rgb, header.color_space);
}
