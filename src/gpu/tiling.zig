// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! PS5/GFX10 surface addressing and allocation-free staging copies.
//!
//! A layout maps one logical element to its byte address in guest memory. The
//! same mapping drives the CPU fallback here and can be serialized for a
//! Vulkan compute detile pass later, preventing two subtly different swizzle
//! implementations from developing. Elements are pixels for ordinary formats
//! and 4x4 blocks for BC formats.

const std = @import("std");
const resources = @import("resources.zig");
const shaders = @import("shaders.zig");

pub const Error = error{
    InvalidExtent,
    InvalidPitch,
    UnsupportedElementSize,
    UnsupportedFormat,
    UnsupportedTileMode,
    UnsupportedMultisample,
    UnsupportedVolume,
    UnsupportedMipChain,
    CoordinateOutOfRange,
    ArithmeticOverflow,
    SourceTooSmall,
    DestinationTooSmall,
};

pub const StageError = Error || shaders.Error;

pub const ByteRange = struct {
    address: u64,
    size: u64,
    end: u64,
};

pub const ElementLayout = struct {
    bytes: u8,
    texels_wide: u8 = 1,
    texels_high: u8 = 1,
};

pub const Surface = struct {
    tile_mode: resources.TileMode,
    width: u32,
    height: u32,
    layers: u32 = 1,
    first_slice: u32 = 0,
    /// Actual guest row pitch in elements. Zero selects the logical width.
    row_pitch_elements: u32 = 0,
    samples_log2: u8 = 0,
};

pub const BlockLayout = struct {
    tile_mode: resources.TileMode,
    bytes_per_element: u8,
    bytes: u32,
    width: u32,
    height: u32,

    pub fn init(tile_mode: resources.TileMode, bytes_per_element: u8) Error!BlockLayout {
        if (!isSupportedElementSize(bytes_per_element)) return Error.UnsupportedElementSize;

        const block_bytes: u32 = switch (tile_mode) {
            .linear => bytes_per_element,
            .standard_256b => 256,
            .standard_4kb => 4096,
            .standard_64kb, .partially_resident, .depth, .render_target => 65536,
            _ => return Error.UnsupportedTileMode,
        };
        if (tile_mode == .depth and bytes_per_element > 8) return Error.UnsupportedElementSize;
        if (tile_mode == .linear) return .{
            .tile_mode = tile_mode,
            .bytes_per_element = bytes_per_element,
            .bytes = block_bytes,
            .width = 1,
            .height = 1,
        };

        const element_count = block_bytes / bytes_per_element;
        const element_bits: u5 = @intCast(std.math.log2_int(u32, element_count));
        const width_bits: u5 = (element_bits + 1) / 2;
        const height_bits: u5 = element_bits / 2;
        return .{
            .tile_mode = tile_mode,
            .bytes_per_element = bytes_per_element,
            .bytes = block_bytes,
            .width = @as(u32, 1) << width_bits,
            .height = @as(u32, 1) << height_bits,
        };
    }

    pub fn byteOffset(self: BlockLayout, x: u32, y: u32) Error!u32 {
        if (x >= self.width or y >= self.height) return Error.CoordinateOutOfRange;
        const offset = switch (self.tile_mode) {
            .linear => 0,
            .standard_256b => standard4kOffset(x, y, self.bytes_per_element) & 0xff,
            .standard_4kb => standard4kOffset(x, y, self.bytes_per_element),
            .standard_64kb => standard64kOffset(x, y, self.bytes_per_element),
            .partially_resident => prt64kOffset(x, y, self.bytes_per_element),
            .depth => depth64kOffset(x, y, self.bytes_per_element),
            .render_target => render64kOffset(x, y, self.bytes_per_element),
            _ => return Error.UnsupportedTileMode,
        };
        std.debug.assert(offset < self.bytes);
        std.debug.assert(offset % self.bytes_per_element == 0);
        return offset;
    }

    /// RB+ render/depth layouts XOR macro-block coordinates and the array
    /// slice into the address inside a 64 KiB block.
    pub fn blockXor(self: BlockLayout, block_x: u32, block_y: u32, block_z: u32) Error!u32 {
        var offset: u32 = switch (self.tile_mode) {
            .render_target => render64kOffset(
                try multiplyU32(block_x, self.width),
                try multiplyU32(block_y, self.height),
                self.bytes_per_element,
            ),
            .depth => if (self.bytes_per_element == 8) depth64kOffset(
                try multiplyU32(block_x, self.width),
                try multiplyU32(block_y, self.height),
                8,
            ) else 0,
            .linear, .standard_256b, .standard_4kb, .standard_64kb, .partially_resident => 0,
            _ => return Error.UnsupportedTileMode,
        };
        if (self.tile_mode == .render_target or self.tile_mode == .depth) {
            offset ^= ((block_z & 8) << 5) ^ ((block_z & 4) << 7) ^
                ((block_z & 2) << 9) ^ ((block_z & 1) << 11);
        }
        std.debug.assert(offset < self.bytes);
        std.debug.assert(offset % self.bytes_per_element == 0);
        return offset;
    }
};

/// One tightly packed linear staging view over a guest base subresource.
pub const Layout = struct {
    block: BlockLayout,
    width: u32,
    height: u32,
    layers: u32,
    first_slice: u32,
    row_pitch_elements: u32,
    blocks_per_row: u32,
    blocks_per_column: u32,
    source_slice_bytes: u64,
    required_source_bytes: u64,
    staging_slice_bytes: u64,
    staging_bytes: u64,

    pub fn init(surface: Surface, bytes_per_element: u8) Error!Layout {
        if (surface.width == 0 or surface.height == 0 or surface.layers == 0) {
            return Error.InvalidExtent;
        }
        if (surface.samples_log2 != 0) return Error.UnsupportedMultisample;
        const block = try BlockLayout.init(surface.tile_mode, bytes_per_element);
        const requested_pitch = if (surface.row_pitch_elements == 0)
            surface.width
        else
            surface.row_pitch_elements;
        if (requested_pitch < surface.width) return Error.InvalidPitch;

        const blocks_per_row = try divideRoundUp(requested_pitch, block.width);
        const blocks_per_column = try divideRoundUp(surface.height, block.height);
        const row_pitch_elements = try multiplyU32(blocks_per_row, block.width);
        const source_slice_bytes = if (surface.tile_mode.isLinear())
            try multiply3(row_pitch_elements, surface.height, bytes_per_element)
        else
            try multiply3(blocks_per_row, blocks_per_column, block.bytes);
        const physical_slices = try addU32(surface.first_slice, surface.layers);
        const required_source_bytes = try multiply(source_slice_bytes, physical_slices);
        const staging_slice_bytes = try multiply3(surface.width, surface.height, bytes_per_element);
        const staging_bytes = try multiply(staging_slice_bytes, surface.layers);

        return .{
            .block = block,
            .width = surface.width,
            .height = surface.height,
            .layers = surface.layers,
            .first_slice = surface.first_slice,
            .row_pitch_elements = row_pitch_elements,
            .blocks_per_row = blocks_per_row,
            .blocks_per_column = blocks_per_column,
            .source_slice_bytes = source_slice_bytes,
            .required_source_bytes = required_source_bytes,
            .staging_slice_bytes = staging_slice_bytes,
            .staging_bytes = staging_bytes,
        };
    }

    pub fn fromImage(image: resources.ImageDescriptor) Error!Layout {
        if (image.image_type == .color_3d) return Error.UnsupportedVolume;
        if (image.image_type == .color_2d_msaa or image.image_type == .color_2d_msaa_array) {
            return Error.UnsupportedMultisample;
        }
        if (image.base_level != 0 or image.last_level != 0 or
            (image.extended and image.max_mip != 0)) return Error.UnsupportedMipChain;

        const element = elementLayoutForUnifiedFormat(image.unified_format) orelse
            return Error.UnsupportedFormat;
        const width = try texelsToElements(image.width, element.texels_wide);
        const height = try texelsToElements(image.height, element.texels_high);
        var pitch = try texelsToElements(@max(image.pitch, image.width), element.texels_wide);
        if (image.tile_mode.isLinear()) {
            pitch = try alignForward(pitch, @max(@as(u32, 1), 256 / @as(u32, element.bytes)));
        }
        const arrayed = image.image_type.isArray();
        const first_slice: u32 = if (arrayed) image.base_array else 0;
        const layers: u32 = if (arrayed and image.depth_or_layers > first_slice)
            image.depth_or_layers - first_slice
        else
            1;
        return init(.{
            .tile_mode = image.tile_mode,
            .width = width,
            .height = height,
            .layers = layers,
            .first_slice = first_slice,
            .row_pitch_elements = pitch,
        }, element.bytes);
    }

    pub fn fromColorTarget(target: resources.ColorTarget) Error!Layout {
        const bytes = colorBytesPerElement(target.format) orelse return Error.UnsupportedFormat;
        if (target.samples_log2 != 0 or target.fragments_log2 != 0) {
            return Error.UnsupportedMultisample;
        }
        const layers: u32 = if (target.last_array_slice >= target.base_array_slice)
            @as(u32, target.last_array_slice) - target.base_array_slice + 1
        else
            1;
        var pitch = if (target.pitch != 0) target.pitch else target.width;
        if (target.tile_mode.isLinear() and target.pitch == 0) {
            pitch = try alignForward(pitch, @max(@as(u32, 1), 256 / @as(u32, bytes)));
        }
        return init(.{
            .tile_mode = target.tile_mode,
            .width = target.width,
            .height = target.height,
            .layers = layers,
            .first_slice = target.base_array_slice,
            .row_pitch_elements = pitch,
        }, bytes);
    }

    pub fn fromDepthTarget(target: resources.DepthTarget) Error!Layout {
        const bytes: u8 = switch (target.format) {
            1 => 2,
            3 => 4,
            else => return Error.UnsupportedFormat,
        };
        if (target.samples_log2 != 0) return Error.UnsupportedMultisample;
        const layers: u32 = if (target.last_array_slice >= target.base_array_slice)
            @as(u32, target.last_array_slice) - target.base_array_slice + 1
        else
            1;
        var pitch = target.width;
        if (target.tile_mode.isLinear()) {
            pitch = try alignForward(pitch, @max(@as(u32, 1), 256 / @as(u32, bytes)));
        }
        return init(.{
            .tile_mode = target.tile_mode,
            .width = target.width,
            .height = target.height,
            .layers = layers,
            .first_slice = target.base_array_slice,
            .row_pitch_elements = pitch,
        }, bytes);
    }

    pub fn sourceByteOffset(self: Layout, x: u32, y: u32, layer: u32) Error!u64 {
        if (x >= self.width or y >= self.height or layer >= self.layers) {
            return Error.CoordinateOutOfRange;
        }
        const physical_slice = try addU32(self.first_slice, layer);
        const slice_base = try multiply(self.source_slice_bytes, physical_slice);
        if (self.block.tile_mode.isLinear()) {
            const row = try multiply3(y, self.row_pitch_elements, self.block.bytes_per_element);
            const column = try multiply(x, self.block.bytes_per_element);
            return add(try add(slice_base, row), column);
        }

        const block_x = x / self.block.width;
        const block_y = y / self.block.height;
        const block_index = try add(
            try multiply(block_y, self.blocks_per_row),
            block_x,
        );
        const block_base = try multiply(block_index, self.block.bytes);
        const local = try self.block.byteOffset(x % self.block.width, y % self.block.height);
        const block_xor = try self.block.blockXor(block_x, block_y, physical_slice);
        return add(try add(slice_base, block_base), local ^ block_xor);
    }

    pub fn stagingByteOffset(self: Layout, x: u32, y: u32, layer: u32) Error!u64 {
        if (x >= self.width or y >= self.height or layer >= self.layers) {
            return Error.CoordinateOutOfRange;
        }
        const slice = try multiply(layer, self.staging_slice_bytes);
        const row = try multiply3(y, self.width, self.block.bytes_per_element);
        const column = try multiply(x, self.block.bytes_per_element);
        return add(try add(slice, row), column);
    }

    pub fn sourceRange(self: Layout, address: u64) Error!ByteRange {
        return .{
            .address = address,
            .size = self.required_source_bytes,
            .end = try add(address, self.required_source_bytes),
        };
    }

    /// Copies guest tiled bytes into tightly packed layer-major staging bytes.
    pub fn detile(self: Layout, source: []const u8, destination: []u8) Error!void {
        try self.validateCopies(source.len, destination.len);
        const bytes = self.block.bytes_per_element;
        for (0..self.layers) |layer_index| {
            const layer: u32 = @intCast(layer_index);
            for (0..self.height) |y_index| {
                const y: u32 = @intCast(y_index);
                for (0..self.width) |x_index| {
                    const x: u32 = @intCast(x_index);
                    const src: usize = @intCast(try self.sourceByteOffset(x, y, layer));
                    const dst: usize = @intCast(try self.stagingByteOffset(x, y, layer));
                    @memcpy(destination[dst..][0..bytes], source[src..][0..bytes]);
                }
            }
        }
    }

    /// Copies tightly packed staging bytes back to guest layout. Padding and
    /// slices outside the view are intentionally left untouched.
    pub fn tile(self: Layout, source: []const u8, destination: []u8) Error!void {
        if (@as(u64, source.len) < self.staging_bytes) return Error.SourceTooSmall;
        if (@as(u64, destination.len) < self.required_source_bytes) return Error.DestinationTooSmall;
        const bytes = self.block.bytes_per_element;
        for (0..self.layers) |layer_index| {
            const layer: u32 = @intCast(layer_index);
            for (0..self.height) |y_index| {
                const y: u32 = @intCast(y_index);
                for (0..self.width) |x_index| {
                    const x: u32 = @intCast(x_index);
                    const src: usize = @intCast(try self.stagingByteOffset(x, y, layer));
                    const dst: usize = @intCast(try self.sourceByteOffset(x, y, layer));
                    @memcpy(destination[dst..][0..bytes], source[src..][0..bytes]);
                }
            }
        }
    }

    /// Reads directly from checked guest memory without allocating an
    /// intermediate copy of the tiled allocation.
    pub fn stage(self: Layout, reader: shaders.MemoryReader, address: u64, destination: []u8) StageError!void {
        if (@as(u64, destination.len) < self.staging_bytes) return Error.DestinationTooSmall;
        _ = try self.sourceRange(address);
        const bytes = self.block.bytes_per_element;
        if (self.block.tile_mode.isLinear()) {
            const row_bytes: usize = @intCast(try multiply(self.width, bytes));
            for (0..self.layers) |layer_index| {
                const layer: u32 = @intCast(layer_index);
                for (0..self.height) |y_index| {
                    const y: u32 = @intCast(y_index);
                    const src = try add(address, try self.sourceByteOffset(0, y, layer));
                    const dst: usize = @intCast(try self.stagingByteOffset(0, y, layer));
                    try reader.read(src, destination[dst..][0..row_bytes]);
                }
            }
            return;
        }
        for (0..self.layers) |layer_index| {
            const layer: u32 = @intCast(layer_index);
            for (0..self.height) |y_index| {
                const y: u32 = @intCast(y_index);
                for (0..self.width) |x_index| {
                    const x: u32 = @intCast(x_index);
                    const src = try add(address, try self.sourceByteOffset(x, y, layer));
                    const dst: usize = @intCast(try self.stagingByteOffset(x, y, layer));
                    try reader.read(src, destination[dst..][0..bytes]);
                }
            }
        }
    }

    fn validateCopies(self: Layout, source_len: usize, destination_len: usize) Error!void {
        if (@as(u64, source_len) < self.required_source_bytes) return Error.SourceTooSmall;
        if (@as(u64, destination_len) < self.staging_bytes) return Error.DestinationTooSmall;
    }
};

pub const BufferLayout = struct {
    size_bytes: u64,

    pub fn fromDescriptor(descriptor: resources.BufferDescriptor) BufferLayout {
        return .{ .size_bytes = descriptor.size_bytes };
    }

    pub fn sourceRange(self: BufferLayout, address: u64) Error!ByteRange {
        return .{ .address = address, .size = self.size_bytes, .end = try add(address, self.size_bytes) };
    }

    pub fn stage(self: BufferLayout, reader: shaders.MemoryReader, address: u64, destination: []u8) StageError!void {
        if (@as(u64, destination.len) < self.size_bytes) return Error.DestinationTooSmall;
        _ = try self.sourceRange(address);
        try reader.read(address, destination[0..@intCast(self.size_bytes)]);
    }
};

pub fn elementLayoutForUnifiedFormat(format: u16) ?ElementLayout {
    return switch (format) {
        1...6, 128, 161 => .{ .bytes = 1 },
        7...19, 129, 133, 134, 136 => .{ .bytes = 2 },
        20...61, 130, 132 => .{ .bytes = 4 },
        62...71 => .{ .bytes = 8 },
        72...74 => .{ .bytes = 12 },
        75...77 => .{ .bytes = 16 },
        169, 170 => .{ .bytes = 8, .texels_wide = 4, .texels_high = 4 },
        171...182 => .{ .bytes = 16, .texels_wide = 4, .texels_high = 4 },
        else => null,
    };
}

pub fn colorBytesPerElement(format: u8) ?u8 {
    return switch (format) {
        1 => 1,
        2, 3, 16, 17, 19 => 2,
        4, 5, 6, 9, 10 => 4,
        11, 12 => 8,
        14 => 16,
        else => null,
    };
}

fn isSupportedElementSize(bytes: u8) bool {
    return bytes == 1 or bytes == 2 or bytes == 4 or bytes == 8 or bytes == 16;
}

fn standard4kOffset(x: u32, y: u32, bytes: u8) u32 {
    return switch (bytes) {
        1 => ((y << 4) & 0x1f0) ^ ((y << 5) & 0x400) ^ (x & 0x00f) ^
            ((x << 5) & 0x200) ^ ((x << 6) & 0x800),
        2 => ((y << 4) & 0x070) ^ ((y << 5) & 0x100) ^ ((y << 6) & 0x400) ^
            ((x << 1) & 0x00e) ^ ((x << 4) & 0x080) ^ ((x << 5) & 0x200) ^
            ((x << 6) & 0x800),
        4 => ((y << 4) & 0x070) ^ ((y << 5) & 0x100) ^ ((y << 6) & 0x400) ^
            ((x << 2) & 0x00c) ^ ((x << 5) & 0x080) ^ ((x << 6) & 0x200) ^
            ((x << 7) & 0x800),
        8 => ((y << 4) & 0x030) ^ ((y << 6) & 0x100) ^ ((y << 7) & 0x400) ^
            ((x << 3) & 0x008) ^ ((x << 5) & 0x0c0) ^ ((x << 6) & 0x200) ^
            ((x << 7) & 0x800),
        16 => ((y << 4) & 0x030) ^ ((y << 6) & 0x100) ^ ((y << 7) & 0x400) ^
            ((x << 6) & 0x0c0) ^ ((x << 7) & 0x200) ^ ((x << 8) & 0x800),
        else => unreachable,
    };
}

fn standard64kOffset(x: u32, y: u32, bytes: u8) u32 {
    return switch (bytes) {
        1 => (x & 0x000f) ^ ((x << 5) & 0x0200) ^ ((x << 6) & 0x0800) ^
            ((x << 7) & 0x2000) ^ ((x << 8) & 0x8000) ^ ((y << 4) & 0x01f0) ^
            ((y << 5) & 0x0400) ^ ((y << 6) & 0x1000) ^ ((y << 7) & 0x4000),
        2 => ((x << 1) & 0x000e) ^ ((x << 4) & 0x0080) ^ ((x << 5) & 0x0200) ^
            ((x << 6) & 0x0800) ^ ((x << 7) & 0x2000) ^ ((x << 8) & 0x8000) ^
            ((y << 4) & 0x0070) ^ ((y << 5) & 0x0100) ^ ((y << 6) & 0x0400) ^
            ((y << 7) & 0x1000) ^ ((y << 8) & 0x4000),
        4 => ((x << 2) & 0x000c) ^ ((x << 5) & 0x0080) ^ ((x << 6) & 0x0200) ^
            ((x << 7) & 0x0800) ^ ((x << 8) & 0x2000) ^ ((x << 9) & 0x8000) ^
            ((y << 4) & 0x0070) ^ ((y << 5) & 0x0100) ^ ((y << 6) & 0x0400) ^
            ((y << 7) & 0x1000) ^ ((y << 8) & 0x4000),
        8 => ((x << 3) & 0x0008) ^ ((x << 5) & 0x00c0) ^ ((x << 6) & 0x0200) ^
            ((x << 7) & 0x0800) ^ ((x << 8) & 0x2000) ^ ((x << 9) & 0x8000) ^
            ((y << 4) & 0x0030) ^ ((y << 6) & 0x0100) ^ ((y << 7) & 0x0400) ^
            ((y << 8) & 0x1000) ^ ((y << 9) & 0x4000),
        16 => ((x << 6) & 0x00c0) ^ ((x << 7) & 0x0200) ^ ((x << 8) & 0x0800) ^
            ((x << 9) & 0x2000) ^ ((x << 10) & 0x8000) ^ ((y << 4) & 0x0030) ^
            ((y << 6) & 0x0100) ^ ((y << 7) & 0x0400) ^ ((y << 8) & 0x1000) ^
            ((y << 9) & 0x4000),
        else => unreachable,
    };
}

fn prt64kOffset(x: u32, y: u32, bytes: u8) u32 {
    var offset = standard64kOffset(x, y, bytes);
    const shifts: [5][4]u5 = .{
        .{ 7, 7, 6, 6 }, .{ 7, 6, 6, 5 }, .{ 6, 6, 5, 5 },
        .{ 6, 5, 5, 4 }, .{ 5, 5, 4, 4 },
    };
    const source = shifts[std.math.log2_int(u8, bytes)];
    offset ^= bit(x, source[0], 8) ^ bit(y, source[1], 9) ^
        bit(x, source[2], 10) ^ bit(y, source[3], 11);
    return offset;
}

fn render64kOffset(x: u32, y: u32, bytes: u8) u32 {
    return switch (bytes) {
        1 => ((y << 2) & 0x0008) ^ ((y << 4) & 0x0010) ^ ((y << 3) & 0x00a0) ^
            ((y << 5) & 0x0f00) ^ ((y << 6) & 0x1000) ^ ((y << 7) & 0x4000) ^
            (x & 0x0007) ^ ((x << 3) & 0x0040) ^ ((x << 5) & 0x0300) ^
            ((x << 4) & 0x0400) ^ ((x << 6) & 0x0800) ^ ((x << 7) & 0x2000) ^
            ((x << 8) & 0x8000),
        2 => ((y << 4) & 0x0070) ^ ((y << 5) & 0x0f00) ^ ((y << 8) & 0x5000) ^
            ((x << 1) & 0x000e) ^ ((x << 4) & 0x0480) ^ ((x << 5) & 0x0300) ^
            ((x << 6) & 0x0800) ^ ((x << 7) & 0x2000) ^ ((x << 8) & 0x8000),
        4 => ((y << 4) & 0x0070) ^ ((y << 5) & 0x0f00) ^ ((y << 9) & 0x1000) ^
            ((y << 8) & 0x4000) ^ ((x << 2) & 0x000c) ^ ((x << 5) & 0x0380) ^
            ((x << 4) & 0x0400) ^ ((x << 6) & 0x0800) ^ ((x << 9) & 0xa000),
        8 => ((y << 4) & 0x0010) ^ ((y << 6) & 0x0080) ^ ((y << 5) & 0x0f00) ^
            ((y << 10) & 0x5000) ^ ((x << 3) & 0x0008) ^ ((x << 4) & 0x0460) ^
            ((x << 5) & 0x0300) ^ ((x << 6) & 0x0800) ^ ((x << 10) & 0x2000) ^
            ((x << 9) & 0x8000),
        16 => ((x << 4) & 0x0410) ^ ((x << 5) & 0x0340) ^ ((x << 6) & 0x0800) ^
            ((x << 11) & 0xa000) ^ ((y << 5) & 0x0f20) ^ ((y << 6) & 0x0080) ^
            ((y << 10) & 0x1000) ^ ((y << 11) & 0x4000),
        else => unreachable,
    };
}

fn depth64kOffset(x: u32, y: u32, bytes: u8) u32 {
    return switch (bytes) {
        1 => (x & 0x0001) ^ ((x << 1) & 0x0004) ^ ((x << 2) & 0x0010) ^
            ((x << 3) & 0x0040) ^ ((x << 5) & 0x0300) ^ ((x << 4) & 0x0400) ^
            ((x << 6) & 0x0800) ^ ((x << 7) & 0x2000) ^ ((x << 8) & 0x8000) ^
            ((y << 1) & 0x0002) ^ ((y << 2) & 0x0008) ^ ((y << 3) & 0x00a0) ^
            ((y << 5) & 0x0f00) ^ ((y << 6) & 0x1000) ^ ((y << 7) & 0x4000),
        2 => ((x << 1) & 0x0002) ^ ((x << 2) & 0x0008) ^ ((x << 3) & 0x0020) ^
            ((x << 4) & 0x0480) ^ ((x << 5) & 0x0300) ^ ((x << 6) & 0x0800) ^
            ((x << 7) & 0x2000) ^ ((x << 8) & 0x8000) ^ ((y << 2) & 0x0004) ^
            ((y << 3) & 0x0010) ^ ((y << 4) & 0x0040) ^ ((y << 5) & 0x0f00) ^
            ((y << 8) & 0x5000),
        4 => ((x << 2) & 0x0004) ^ ((x << 3) & 0x0010) ^ ((x << 4) & 0x0440) ^
            ((x << 5) & 0x0300) ^ ((x << 6) & 0x0800) ^ ((x << 9) & 0xa000) ^
            ((y << 3) & 0x0008) ^ ((y << 4) & 0x0020) ^ ((y << 5) & 0x0f80) ^
            ((y << 9) & 0x1000) ^ ((y << 8) & 0x4000),
        8 => ((x << 3) & 0x0008) ^ ((x << 4) & 0x0420) ^ ((x << 5) & 0x0380) ^
            ((x << 6) & 0x0800) ^ ((x << 10) & 0x2000) ^ ((x << 9) & 0x8000) ^
            ((y << 4) & 0x0010) ^ ((y << 5) & 0x0f40) ^ ((y << 10) & 0x5000),
        else => unreachable,
    };
}

fn bit(value: u32, source: u5, destination: u5) u32 {
    return ((value >> source) & 1) << destination;
}

fn divideRoundUp(value: u32, divisor: u32) Error!u32 {
    const biased = std.math.add(u32, value, divisor - 1) catch return Error.ArithmeticOverflow;
    return biased / divisor;
}

fn alignForward(value: u32, alignment: u32) Error!u32 {
    const biased = std.math.add(u32, value, alignment - 1) catch return Error.ArithmeticOverflow;
    return biased & ~(alignment - 1);
}

fn texelsToElements(texels: u32, element_texels: u8) Error!u32 {
    return divideRoundUp(texels, element_texels);
}

fn multiply(a: anytype, b: anytype) Error!u64 {
    return std.math.mul(u64, @as(u64, a), @as(u64, b)) catch Error.ArithmeticOverflow;
}

fn multiply3(a: anytype, b: anytype, c: anytype) Error!u64 {
    return multiply(try multiply(a, b), c);
}

fn add(a: anytype, b: anytype) Error!u64 {
    return std.math.add(u64, @as(u64, a), @as(u64, b)) catch Error.ArithmeticOverflow;
}

fn addU32(a: u32, b: u32) Error!u32 {
    return std.math.add(u32, a, b) catch Error.ArithmeticOverflow;
}

fn multiplyU32(a: u32, b: u32) Error!u32 {
    return std.math.mul(u32, a, b) catch Error.ArithmeticOverflow;
}

const TestMemory = struct {
    base: u64,
    bytes: []const u8,

    fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
        const self: *const TestMemory = @ptrCast(@alignCast(context orelse return false));
        if (address < self.base) return false;
        const offset64 = address - self.base;
        if (offset64 > self.bytes.len) return false;
        const offset: usize = @intCast(offset64);
        if (destination.len > self.bytes.len - offset) return false;
        @memcpy(destination, self.bytes[offset..][0..destination.len]);
        return true;
    }

    fn reader(self: *const TestMemory) shaders.MemoryReader {
        return .{ .context = @constCast(self), .read_fn = read };
    }
};

const testing = std.testing;

test "block layouts and fixed AddrLib vectors match PS5 Gen5" {
    const standard = try BlockLayout.init(.standard_64kb, 4);
    const prt = try BlockLayout.init(.partially_resident, 4);
    const color = try BlockLayout.init(.render_target, 4);
    const depth = try BlockLayout.init(.depth, 4);
    try testing.expectEqual(@as(u32, 128), standard.width);
    try testing.expectEqual(@as(u32, 128), standard.height);
    try testing.expectEqual(@as(u32, 0x8000), try standard.byteOffset(64, 0));
    try testing.expectEqual(@as(u32, 0x8100), try prt.byteOffset(64, 0));
    try testing.expectEqual(@as(u32, 0x0800), try color.blockXor(0, 0, 1));
    try testing.expectEqual(@as(u32, 0x0f00), try depth.blockXor(0, 0, 15));
    try testing.expectEqual(@as(u32, 0x009c), try depth.byteOffset(3, 5));
    try testing.expectError(Error.UnsupportedElementSize, BlockLayout.init(.depth, 16));
    try testing.expectError(Error.UnsupportedTileMode, BlockLayout.init(@enumFromInt(2), 4));
}

test "surface layout accounts for pitch blocks slices and checked ranges" {
    const layout = try Layout.init(.{
        .tile_mode = .standard_4kb,
        .width = 70,
        .height = 35,
        .layers = 2,
        .first_slice = 1,
        .row_pitch_elements = 72,
    }, 4);
    try testing.expectEqual(@as(u32, 3), layout.blocks_per_row);
    try testing.expectEqual(@as(u32, 2), layout.blocks_per_column);
    try testing.expectEqual(@as(u64, 0x6000), layout.source_slice_bytes);
    try testing.expectEqual(@as(u64, 0x12000), layout.required_source_bytes);
    try testing.expectEqual(@as(u64, 70 * 35 * 4 * 2), layout.staging_bytes);
    try testing.expectEqual(@as(u64, 0x6000 + 0x1000), try layout.sourceByteOffset(32, 0, 0));
    try testing.expectEqual(@as(u64, 0x6000 + 3 * 0x1000), try layout.sourceByteOffset(0, 32, 0));
    const range = try layout.sourceRange(0x1000_0000);
    try testing.expectEqual(@as(u64, 0x1001_2000), range.end);
    try testing.expectError(Error.CoordinateOutOfRange, layout.sourceByteOffset(70, 0, 0));
    try testing.expectError(Error.InvalidPitch, Layout.init(.{
        .tile_mode = .linear,
        .width = 8,
        .height = 8,
        .row_pitch_elements = 7,
    }, 4));
}

test "tile and detile round trip every supported 2D swizzle family and element size" {
    const modes = [_]resources.TileMode{
        .linear,             .standard_256b, .standard_4kb,  .standard_64kb,
        .partially_resident, .depth,         .render_target,
    };
    const sizes = [_]u8{ 1, 2, 4, 8, 16 };
    for (modes) |mode| {
        for (sizes) |bytes| {
            if (mode == .depth and bytes == 16) continue;
            const block = try BlockLayout.init(mode, bytes);
            const width = if (mode.isLinear()) @as(u32, 19) else block.width;
            const height = if (mode.isLinear()) @as(u32, 11) else block.height;
            const layout = try Layout.init(.{
                .tile_mode = mode,
                .width = width,
                .height = height,
                .layers = 2,
            }, bytes);
            const linear = try testing.allocator.alloc(u8, @intCast(layout.staging_bytes));
            defer testing.allocator.free(linear);
            const tiled = try testing.allocator.alloc(u8, @intCast(layout.required_source_bytes));
            defer testing.allocator.free(tiled);
            const actual = try testing.allocator.alloc(u8, @intCast(layout.staging_bytes));
            defer testing.allocator.free(actual);
            for (linear, 0..) |*value, index| value.* = @truncate(index * 37 + bytes);
            @memset(tiled, 0xa5);
            @memset(actual, 0);
            try layout.tile(linear, tiled);
            try layout.detile(tiled, actual);
            try testing.expectEqualSlices(u8, linear, actual);
        }
    }
}

test "checked memory staging shares the CPU detile address map" {
    const layout = try Layout.init(.{
        .tile_mode = .render_target,
        .width = 37,
        .height = 29,
        .layers = 2,
        .first_slice = 1,
    }, 4);
    const linear = try testing.allocator.alloc(u8, @intCast(layout.staging_bytes));
    defer testing.allocator.free(linear);
    const tiled = try testing.allocator.alloc(u8, @intCast(layout.required_source_bytes));
    defer testing.allocator.free(tiled);
    const staged = try testing.allocator.alloc(u8, @intCast(layout.staging_bytes));
    defer testing.allocator.free(staged);
    for (linear, 0..) |*value, index| value.* = @truncate(index * 13 + 5);
    @memset(tiled, 0);
    @memset(staged, 0);
    try layout.tile(linear, tiled);
    const memory = TestMemory{ .base = 0x2000_0000, .bytes = tiled };
    try layout.stage(memory.reader(), memory.base, staged);
    try testing.expectEqualSlices(u8, linear, staged);
    try testing.expectError(
        Error.DestinationTooSmall,
        layout.stage(memory.reader(), memory.base, staged[0 .. staged.len - 1]),
    );
    try testing.expectError(Error.ArithmeticOverflow, layout.sourceRange(std.math.maxInt(u64)));
}

test "format adapters expose pixel block and attachment staging layouts" {
    try testing.expectEqual(@as(u8, 4), elementLayoutForUnifiedFormat(56).?.bytes);
    const bc = elementLayoutForUnifiedFormat(169).?;
    try testing.expectEqual(@as(u8, 8), bc.bytes);
    try testing.expectEqual(@as(u8, 4), bc.texels_wide);
    try testing.expectEqual(@as(u8, 4), colorBytesPerElement(10).?);
    try testing.expect(colorBytesPerElement(7) == null);

    const buffer_words = [_]u32{ 0x4000, 4 << 16, 1, 56 << 12 };
    const descriptor = try resources.decodeBufferDescriptor(&buffer_words);
    const buffer = BufferLayout.fromDescriptor(descriptor);
    const source = [_]u8{ 1, 2, 3, 4 };
    var destination = [_]u8{0} ** 4;
    const memory = TestMemory{ .base = 0x4000, .bytes = &source };
    try buffer.stage(memory.reader(), memory.base, &destination);
    try testing.expectEqualSlices(u8, &source, &destination);
    try testing.expectError(Error.DestinationTooSmall, buffer.stage(memory.reader(), memory.base, destination[0..3]));
}

test "resource adapters derive element grids slices and explicit limitations" {
    const encoded_address: u64 = 0x1234_5000 >> 8;
    const width: u32 = 17;
    const height: u32 = 9;
    const width_minus_one = width - 1;
    const image_words = [_]u32{
        @truncate(encoded_address),
        @as(u32, @truncate(encoded_address >> 32)) | (169 << 20) | ((width_minus_one & 3) << 30),
        ((width_minus_one >> 2) & 0x3fff) | ((height - 1) << 14),
        (5 << 20) | (9 << 28),
    };
    const image = try resources.decodeImageDescriptor(&image_words);
    const image_layout = try Layout.fromImage(image);
    try testing.expectEqual(@as(u32, 5), image_layout.width);
    try testing.expectEqual(@as(u32, 3), image_layout.height);
    try testing.expectEqual(@as(u8, 8), image_layout.block.bytes_per_element);
    try testing.expectEqual(@as(u64, 120), image_layout.staging_bytes);

    var color = std.mem.zeroes(resources.ColorTarget);
    color.width = 1920;
    color.height = 1080;
    color.pitch = 1920;
    color.format = 10;
    color.tile_mode = .render_target;
    color.base_array_slice = 2;
    color.last_array_slice = 4;
    const color_layout = try Layout.fromColorTarget(color);
    try testing.expectEqual(@as(u32, 3), color_layout.layers);
    try testing.expectEqual(@as(u32, 2), color_layout.first_slice);
    try testing.expectEqual(@as(u64, 1920 * 1080 * 4 * 3), color_layout.staging_bytes);
    color.fragments_log2 = 1;
    try testing.expectError(Error.UnsupportedMultisample, Layout.fromColorTarget(color));

    var depth = std.mem.zeroes(resources.DepthTarget);
    depth.width = 1280;
    depth.height = 720;
    depth.format = 3;
    depth.tile_mode = .depth;
    const depth_layout = try Layout.fromDepthTarget(depth);
    try testing.expectEqual(@as(u8, 4), depth_layout.block.bytes_per_element);
    depth.format = 2;
    try testing.expectError(Error.UnsupportedFormat, Layout.fromDepthTarget(depth));
}
