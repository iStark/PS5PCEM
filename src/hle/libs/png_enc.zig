// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Firmware PNG encoding from pitched RGBA/BGRA guest pixels. Filtering and
//! zlib compression run on the CPU without a graphics or external-codec dependency.

const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory");
const abi = @import("../abi.zig");
const kernel_memory = @import("kernel_memory.zig");
const symbols = @import("../symbols.zig");
const trace = @import("../trace.zig");

const invalid_address: i32 = @bitCast(@as(u32, 0x80690101));
const invalid_size: i32 = @bitCast(@as(u32, 0x80690102));
const invalid_param: i32 = @bitCast(@as(u32, 0x80690103));
const invalid_handle: i32 = @bitCast(@as(u32, 0x80690104));
const data_overflow: i32 = @bitCast(@as(u32, 0x80690110));
const fatal: i32 = @bitCast(@as(u32, 0x80690120));
const context_magic: u64 = 0x50533545504e4745; // PS5EPNGE
const maximum_dimension: u32 = 1_000_000;
const maximum_filtered_bytes: u64 = 512 * 1024 * 1024;

pub const CreateParam = extern struct {
    this_size: u32 = @sizeOf(CreateParam),
    attribute: u32 = 0,
    max_image_width: u32,
    max_filter_number: u32 = 4,
};
pub const EncodeParam = extern struct {
    image_mem_addr: u64,
    png_mem_addr: u64,
    image_mem_size: u32,
    png_mem_size: u32,
    image_width: u32,
    image_height: u32,
    image_pitch: u32,
    pixel_format: u16 = 0,
    color_space: u16 = 19,
    bit_depth: u16 = 8,
    clut_number: u16 = 0,
    filter_type: u16 = 15,
    compression_level: u16 = 6,
};
pub const OutputInfo = extern struct { data_size: u32 = 0, processed_height: u32 = 0 };
const Context = extern struct { magic: u64, max_width: u32, max_filters: u32 };
comptime {
    std.debug.assert(@sizeOf(CreateParam) == 16);
    std.debug.assert(@sizeOf(EncodeParam) == 48);
    std.debug.assert(@sizeOf(OutputInfo) == 8);
    std.debug.assert(@sizeOf(Context) == 16);
}

fn readable(address: u64, len: usize) bool {
    if (address == 0) return false;
    _ = std.math.add(u64, address, len) catch return false;
    if (kernel_memory.attachedAddressSpace()) |_| return kernel_memory.isGuestRangeAccessible(address, len);
    if (builtin.os.tag != .windows) return true;
    return memory.isHostRangeReadable(address, len);
}
fn writable(address: u64, len: usize) bool {
    if (address == 0) return false;
    _ = std.math.add(u64, address, len) catch return false;
    if (kernel_memory.attachedAddressSpace()) |space| {
        if (space.isWritable(address, len)) return true;
    } else if (builtin.os.tag != .windows) {
        return true;
    }
    return memory.isHostRangeWritable(address, len);
}
fn notifyWrite(address: u64, len: usize) void {
    if (kernel_memory.attachedAddressSpace()) |space| space.notifyGuestWrite(address, len);
}

fn validateCreate(param: ?*align(1) const CreateParam) i32 {
    const input = param orelse return invalid_address;
    if (!readable(@intFromPtr(input), @sizeOf(CreateParam))) return invalid_address;
    if (input.this_size != @sizeOf(CreateParam) or input.attribute != 0 or input.max_filter_number > 4) return invalid_param;
    if (input.max_image_width == 0 or input.max_image_width > maximum_dimension) return invalid_size;
    return 0;
}

pub fn queryMemorySize(param: ?*align(1) const CreateParam) callconv(abi.guest) i32 {
    const status = validateCreate(param);
    return if (status == 0) @sizeOf(Context) else status;
}

pub fn create(param: ?*align(1) const CreateParam, address: u64, size: u32, handle: ?*align(1) u64) callconv(abi.guest) i32 {
    const status = validateCreate(param);
    if (status != 0) return status;
    const output = handle orelse return invalid_address;
    if (size < @sizeOf(Context)) return invalid_size;
    if (!writable(address, @sizeOf(Context)) or !writable(@intFromPtr(output), @sizeOf(u64))) return invalid_address;
    const input = param.?.*;
    notifyWrite(address, @sizeOf(Context));
    const context: *align(1) Context = @ptrFromInt(address);
    context.* = .{ .magic = context_magic, .max_width = input.max_image_width, .max_filters = input.max_filter_number };
    notifyWrite(@intFromPtr(output), @sizeOf(u64));
    output.* = address;
    return 0;
}

fn validContext(handle: u64) ?Context {
    if (!readable(handle, @sizeOf(Context))) return null;
    const pointer: *align(1) const Context = @ptrFromInt(handle);
    const context = pointer.*;
    if (context.magic != context_magic or context.max_width == 0 or context.max_width > maximum_dimension or context.max_filters > 4) return null;
    return context;
}

pub fn delete(handle: u64) callconv(abi.guest) i32 {
    _ = validContext(handle) orelse return invalid_handle;
    if (!writable(handle, @sizeOf(Context))) return invalid_address;
    notifyWrite(handle, @sizeOf(Context));
    const context: *align(1) Context = @ptrFromInt(handle);
    context.magic = 0;
    return 0;
}

fn paeth(left: u8, up: u8, upper_left: u8) u8 {
    const p = @as(i16, left) + up - upper_left;
    const a = @abs(p - left);
    const b = @abs(p - up);
    const c = @abs(p - upper_left);
    return if (a <= b and a <= c) left else if (b <= c) up else upper_left;
}

fn filterRow(row: []const u8, previous: []const u8, components: usize, kind: u8, output: []u8) u64 {
    output[0] = kind;
    var score: u64 = 0;
    for (row, 0..) |value, index| {
        const left: u8 = if (index >= components) row[index - components] else 0;
        const upper_left: u8 = if (index >= components) previous[index - components] else 0;
        const predictor: u8 = switch (kind) {
            0 => 0,
            1 => left,
            2 => previous[index],
            3 => @intCast((@as(u16, left) + previous[index]) / 2),
            4 => paeth(left, previous[index], upper_left),
            else => unreachable,
        };
        const filtered = value -% predictor;
        output[index + 1] = filtered;
        score += if (filtered < 128) @as(u16, filtered) else 256 - @as(u16, filtered);
    }
    return score;
}

const Compressed = struct { storage: []u8, size: usize };

fn compressPixels(gpa: std.mem.Allocator, input: EncodeParam) !Compressed {
    // PNG signature + IHDR, IDAT and IEND framing consume 57 bytes.
    if (input.png_mem_size < 65) return error.WriteFailed;
    const components: usize = if (input.color_space == 19) 4 else 3;
    const row_size = @as(usize, input.image_width) * components;
    const raw_size = (row_size + 1) * input.image_height;
    const bound = raw_size + (raw_size / 16384 + input.image_height) * 5 + 1024;
    // Deflate's bit writer needs up to eight bytes of scratch at the end even
    // when its final stream exactly fits the caller's output capacity.
    const storage = try gpa.alloc(u8, @min(input.png_mem_size - 57, bound) + 8);
    errdefer gpa.free(storage);
    var output: std.Io.Writer = .fixed(storage);
    const scratch = try gpa.alloc(u8, 4 * row_size + 2);
    defer gpa.free(scratch);
    const row = scratch[0..row_size];
    const previous = scratch[row_size..][0..row_size];
    const candidate = scratch[2 * row_size ..][0 .. row_size + 1];
    const best = scratch[3 * row_size + 1 ..][0 .. row_size + 1];
    @memset(previous, 0);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    const compressor = if (input.compression_level == 0) null else try gpa.create(std.compress.flate.Compress);
    defer if (compressor) |ptr| gpa.destroy(ptr);
    var adler: std.hash.Adler32 = .{};
    if (compressor) |ptr| {
        const Options = std.compress.flate.Compress.Options;
        const levels = [_]Options{ Options.level_1, Options.level_2, Options.level_3, Options.level_4, Options.level_5, Options.level_6, Options.level_7, Options.level_8, Options.level_9 };
        ptr.* = try .init(&output, window, .zlib, levels[input.compression_level - 1]);
    } else try output.writeAll(&.{ 0x78, 0x01 });

    const pixels: [*]const u8 = @ptrFromInt(input.image_mem_addr);
    for (0..input.image_height) |y| {
        const source = pixels[y * input.image_pitch ..][0 .. input.image_width * 4];
        for (0..input.image_width) |x| {
            row[x * components] = source[x * 4 + (if (input.pixel_format == 1) @as(usize, 2) else 0)];
            row[x * components + 1] = source[x * 4 + 1];
            row[x * components + 2] = source[x * 4 + (if (input.pixel_format == 1) @as(usize, 0) else 2)];
            if (components == 4) row[x * components + 3] = source[x * 4 + 3];
        }
        var best_score: u64 = std.math.maxInt(u64);
        for (0..5) |kind| {
            if (kind == 0) {
                if (input.filter_type != 0) continue;
            } else if (input.filter_type & (@as(u16, 1) << @intCast(kind - 1)) == 0) continue;
            const score = filterRow(row, previous, components, @intCast(kind), candidate);
            if (score < best_score) {
                best_score = score;
                @memcpy(best, candidate);
            }
        }
        if (compressor) |ptr| {
            try ptr.writer.writeAll(best);
        } else {
            // Compression level zero uses stored DEFLATE blocks, still with
            // the requested PNG filters and a standard zlib checksum.
            adler.update(best);
            var remaining: []const u8 = best;
            while (remaining.len != 0) {
                const len: u16 = @intCast(@min(remaining.len, 65535));
                const final = y + 1 == input.image_height and len == remaining.len;
                try output.writeByte(@intFromBool(final));
                try output.writeInt(u16, len, .little);
                try output.writeInt(u16, ~len, .little);
                try output.writeAll(remaining[0..len]);
                remaining = remaining[len..];
            }
        }
        @memcpy(previous, row);
    }
    if (compressor) |ptr| try ptr.finish() else try output.writeInt(u32, adler.adler, .big);
    if (output.end + 57 > input.png_mem_size) return error.WriteFailed;
    return .{ .storage = storage, .size = output.end };
}

fn writeChunk(writer: *std.Io.Writer, kind: *const [4]u8, bytes: []const u8) !void {
    try writer.writeInt(u32, @intCast(bytes.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(bytes);
    var crc = std.hash.crc.Crc32IsoHdlc.init();
    crc.update(kind);
    crc.update(bytes);
    try writer.writeInt(u32, crc.final(), .big);
}

fn publishInfo(pointer: ?*align(1) OutputInfo, value: OutputInfo) void {
    if (pointer) |output| {
        notifyWrite(@intFromPtr(output), @sizeOf(OutputInfo));
        output.* = value;
    }
}

pub fn encode(handle: u64, param: ?*align(1) const EncodeParam, output_info: ?*align(1) OutputInfo) callconv(abi.guest) i32 {
    const context = validContext(handle) orelse return invalid_handle;
    const pointer = param orelse return invalid_param;
    if (!readable(@intFromPtr(pointer), @sizeOf(EncodeParam))) return invalid_address;
    const input = pointer.*;
    if (output_info) |output| if (!writable(@intFromPtr(output), @sizeOf(OutputInfo))) return invalid_address;
    if (input.image_mem_addr == 0 or input.png_mem_addr == 0 or input.image_mem_addr % 4 != 0) return invalid_address;
    if (input.pixel_format > 1 or (input.color_space != 3 and input.color_space != 19) or
        input.bit_depth != 8 or input.clut_number != 0 or input.compression_level > 9 or
        input.filter_type & ~@as(u16, 15) != 0 or @popCount(input.filter_type) > context.max_filters) return invalid_param;
    const components: u64 = if (input.color_space == 19) 4 else 3;
    if (input.image_width == 0 or input.image_width > context.max_width or input.image_height == 0 or input.image_height > maximum_dimension or
        input.image_pitch < @as(u64, input.image_width) * 4 or input.image_pitch % 4 != 0 or input.png_mem_size == 0 or
        @as(u64, input.image_pitch) * input.image_height > input.image_mem_size or
        (@as(u64, input.image_width) * components + 1) * input.image_height > maximum_filtered_bytes) return invalid_size;
    if (!readable(input.image_mem_addr, @as(usize, input.image_pitch) * input.image_height) or !writable(input.png_mem_addr, input.png_mem_size)) return invalid_address;
    const gpa = std.heap.page_allocator;
    const compressed = compressPixels(gpa, input) catch |err| {
        publishInfo(output_info, .{});
        return if (err == error.WriteFailed) data_overflow else fatal;
    };
    defer gpa.free(compressed.storage);
    const size = compressed.size + 57;
    notifyWrite(input.png_mem_addr, size);
    const target: [*]u8 = @ptrFromInt(input.png_mem_addr);
    var writer: std.Io.Writer = .fixed(target[0..size]);
    writer.writeAll("\x89PNG\r\n\x1a\n") catch unreachable;
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], input.image_width, .big);
    std.mem.writeInt(u32, header[4..8], input.image_height, .big);
    header[8] = 8;
    header[9] = if (input.color_space == 19) 6 else 2;
    writeChunk(&writer, "IHDR", &header) catch unreachable;
    writeChunk(&writer, "IDAT", compressed.storage[0..compressed.size]) catch unreachable;
    writeChunk(&writer, "IEND", &.{}) catch unreachable;
    publishInfo(output_info, .{ .data_size = @intCast(size), .processed_height = input.image_height });
    return @intCast(size);
}

pub const exports = [_]symbols.Export{
    .{ .name = "scePngEncQueryMemorySize", .function = trace.wrap("scePngEncQueryMemorySize", &queryMemorySize), .expect_id = "9030RnBDoh4" },
    .{ .name = "scePngEncCreate", .function = trace.wrap("scePngEncCreate", &create), .expect_id = "7aGTPfrqT9s" },
    .{ .name = "scePngEncEncode", .function = trace.wrap("scePngEncEncode", &encode), .expect_id = "xgDjJKpcyHo" },
    .{ .name = "scePngEncDelete", .function = trace.wrap("scePngEncDelete", &delete), .expect_id = "RUrWdwTWZy8" },
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libScePngEnc", .version = 1 }, .{ .name = "libScePngEnc", .version_major = 1, .version_minor = 1 }, &exports);
}

test "PNG encoding round trips pitched RGBA and BGRA at every level and filter" {
    const decoder = @import("png_dec.zig");
    const testing = std.testing;
    var context: Context = undefined;
    var handle: u64 = 0;
    try testing.expectEqual(@as(i32, @sizeOf(Context)), queryMemorySize(&.{ .max_image_width = 3 }));
    try testing.expectEqual(@as(i32, 0), create(&.{ .max_image_width = 3 }, @intFromPtr(&context), @sizeOf(Context), &handle));
    var decode_context: u64 = 0;
    var decode_handle: u64 = 0;
    try testing.expectEqual(@as(i32, 0), decoder.create(&.{ .this_size = @sizeOf(decoder.CreateParam), .attribute = 0, .max_image_width = 3 }, @intFromPtr(&decode_context), 8, &decode_handle));
    var source: [48]u8 align(4) = @splat(0xcd);
    var expected: [36]u8 = undefined;
    var png: [1024]u8 = undefined;
    var decoded: [36]u8 = undefined;
    for ([_]u16{ 3, 19 }) |color| for ([_]u16{ 0, 1 }) |format| {
        for (0..3) |y| for (0..3) |x| {
            const rgba = [4]u8{ @intCast(x * 80 + y * 7), @intCast(y * 60 + x), @intCast(255 - x * 30 - y * 9), @intCast(13 + x * 50 + y * 10) };
            @memcpy(source[y * 16 + x * 4 ..][0..4], &rgba);
            if (format == 1) std.mem.swap(u8, &source[y * 16 + x * 4], &source[y * 16 + x * 4 + 2]);
            @memcpy(expected[(y * 3 + x) * 4 ..][0..4], &rgba);
            if (color == 3) expected[(y * 3 + x) * 4 + 3] = 255;
        };
        for (0..10) |level| for ([_]u16{ 0, 1, 2, 4, 8, 3, 15 }) |filter| {
            var info: OutputInfo = undefined;
            const result = encode(handle, &.{ .image_mem_addr = @intFromPtr(&source), .png_mem_addr = @intFromPtr(&png), .image_mem_size = source.len, .png_mem_size = png.len, .image_width = 3, .image_height = 3, .image_pitch = 16, .pixel_format = format, .color_space = color, .filter_type = filter, .compression_level = @intCast(level) }, &info);
            try testing.expect(result > 0);
            try testing.expectEqual(@as(u32, @intCast(result)), info.data_size);
            try testing.expectEqual(@as(u32, 3), info.processed_height);
            var image_info: decoder.ImageInfo = undefined;
            const status = decoder.decode(decode_handle, &.{ .png_mem_addr = @intFromPtr(&png), .image_mem_addr = @intFromPtr(&decoded), .png_mem_size = info.data_size, .image_mem_size = decoded.len, .pixel_format = 0, .alpha_value = 255, .image_pitch = 12 }, &image_info);
            try testing.expect(status >= 0);
            try testing.expectEqualSlices(u8, &expected, &decoded);
            try testing.expectEqual(color, image_info.color_space);
        };
    };
    try testing.expectEqual(@as(i32, 0), delete(handle));
    try testing.expectEqual(invalid_handle, delete(handle));
}

test "PNG encoding overflow preserves destination and an exact output buffer succeeds" {
    const testing = std.testing;
    var context: Context = undefined;
    var handle: u64 = 0;
    try testing.expectEqual(@as(i32, 0), create(&.{ .max_image_width = 1 }, @intFromPtr(&context), @sizeOf(Context), &handle));
    const pixel: [4]u8 align(4) = .{ 20, 30, 40, 50 };
    var png: [1024]u8 = @splat(0xaa);
    var param = EncodeParam{ .image_mem_addr = @intFromPtr(&pixel), .png_mem_addr = @intFromPtr(&png), .image_mem_size = 4, .png_mem_size = png.len, .image_width = 1, .image_height = 1, .image_pitch = 4 };
    var info: OutputInfo = undefined;
    const size = encode(handle, &param, &info);
    try testing.expect(size > 0);
    param.png_mem_size = @intCast(size);
    try testing.expectEqual(size, encode(handle, &param, null));
    @memset(&png, 0xaa);
    param.png_mem_size -= 1;
    try testing.expectEqual(data_overflow, encode(handle, &param, &info));
    try testing.expectEqualDeep(OutputInfo{}, info);
    try testing.expectEqualSlices(u8, &(.{0xaa} ** 1024), &png);
    param.png_mem_size = png.len;
    param.image_pitch = 3;
    try testing.expectEqual(invalid_size, encode(handle, &param, null));
    param.image_pitch = 4;
    param.filter_type = 16;
    try testing.expectEqual(invalid_param, encode(handle, &param, null));
    param.filter_type = 15;
    param.compression_level = 10;
    try testing.expectEqual(invalid_param, encode(handle, &param, null));
    try testing.expectEqual(invalid_param, queryMemorySize(&.{ .max_image_width = 1, .this_size = 0 }));
}

test "PNG encoding rejects read-only and invalid output pointers" {
    var space = try memory.AddressSpace.initWithDirectMemory(std.testing.allocator, memory.page_size);
    defer space.deinit();
    kernel_memory.init(std.testing.allocator);
    defer kernel_memory.deinit();
    kernel_memory.attachAddressSpace(&space);
    const address = memory.user.start;
    try space.mapFixed(address, memory.page_size, .read_only, .direct_memory, 0);
    var context: Context = undefined;
    var handle: u64 = 0;
    try std.testing.expectEqual(invalid_address, create(&.{ .max_image_width = 1 }, address, 16, &handle));
    try std.testing.expectEqual(@as(i32, 0), create(&.{ .max_image_width = 1 }, @intFromPtr(&context), @sizeOf(Context), &handle));
    const pixel: [4]u8 align(4) = .{ 1, 2, 3, 4 };
    const param = EncodeParam{ .image_mem_addr = @intFromPtr(&pixel), .png_mem_addr = address, .image_mem_size = 4, .png_mem_size = 256, .image_width = 1, .image_height = 1, .image_pitch = 4 };
    try std.testing.expectEqual(invalid_address, encode(handle, &param, null));
    try std.testing.expectEqual(invalid_address, encode(handle, @ptrFromInt(8), null));
    try std.testing.expectEqual(invalid_handle, encode(8, &param, null));
}
