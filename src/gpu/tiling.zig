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
    UnsupportedMetadataLayout,
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
            .depth => rbPlus64kOffset(.depth, x, y, 0, 0, self.bytes_per_element, 0),
            .render_target => rbPlus64kOffset(.render_target, x, y, 0, 0, self.bytes_per_element, 0),
            _ => return Error.UnsupportedTileMode,
        };
        std.debug.assert(offset < self.bytes);
        std.debug.assert(offset % self.bytes_per_element == 0);
        return offset;
    }

    /// RB+ render/depth layouts XOR macro-block coordinates and the array
    /// slice into the address inside a 64 KiB block.
    pub fn blockXor(self: BlockLayout, block_x: u32, block_y: u32, block_z: u32) Error!u32 {
        const offset: u32 = switch (self.tile_mode) {
            .render_target => rbPlus64kOffset(
                .render_target,
                try multiplyU32(block_x, self.width),
                try multiplyU32(block_y, self.height),
                block_z,
                0,
                self.bytes_per_element,
                0,
            ),
            .depth => rbPlus64kOffset(
                .depth,
                try multiplyU32(block_x, self.width),
                try multiplyU32(block_y, self.height),
                block_z,
                0,
                self.bytes_per_element,
                0,
            ),
            .linear, .standard_256b, .standard_4kb, .standard_64kb, .partially_resident => 0,
            _ => return Error.UnsupportedTileMode,
        };
        std.debug.assert(offset < self.bytes);
        std.debug.assert(offset % self.bytes_per_element == 0);
        return offset;
    }
};

pub const BlockFamily = enum(u8) {
    linear,
    standard_256b,
    standard_4kb,
    standard_4kb_3d,
    standard_64kb,
    standard_64kb_3d,
    partially_resident,
    partially_resident_3d,
    depth_64kb,
    render_target_64kb,
};

/// Complete GFX10 swizzle block description. Unlike `BlockLayout`, this also
/// carries thick-volume depth and the number of interleaved MSAA fragments.
pub const SwizzleBlock = struct {
    family: BlockFamily,
    bytes_per_element: u8,
    samples_log2: u8,
    bytes: u32,
    width: u32,
    height: u32,
    depth: u32,

    pub fn init(
        tile_mode: resources.TileMode,
        bytes_per_element: u8,
        volume: bool,
        samples_log2: u8,
    ) Error!SwizzleBlock {
        if (!isSupportedElementSize(bytes_per_element)) return Error.UnsupportedElementSize;
        if (samples_log2 > 3) return Error.UnsupportedMultisample;
        if (volume and samples_log2 != 0) return Error.UnsupportedMultisample;
        if (samples_log2 != 0 and tile_mode != .depth and tile_mode != .render_target) {
            return Error.UnsupportedMultisample;
        }
        if (tile_mode == .depth and bytes_per_element > 8) return Error.UnsupportedElementSize;

        if (volume) {
            if (tile_mode == .linear) return .{
                .family = .linear,
                .bytes_per_element = bytes_per_element,
                .samples_log2 = 0,
                .bytes = bytes_per_element,
                .width = 1,
                .height = 1,
                .depth = 1,
            };
            const family: BlockFamily = switch (tile_mode) {
                .standard_4kb => .standard_4kb_3d,
                .standard_64kb => .standard_64kb_3d,
                .partially_resident => .partially_resident_3d,
                .depth => .depth_64kb,
                .render_target => .render_target_64kb,
                else => return Error.UnsupportedTileMode,
            };
            const dimensions = try thickBlockDimensions(family, bytes_per_element);
            return .{
                .family = family,
                .bytes_per_element = bytes_per_element,
                .samples_log2 = 0,
                .bytes = if (family == .standard_4kb_3d) 4096 else 65536,
                .width = dimensions[0],
                .height = dimensions[1],
                .depth = dimensions[2],
            };
        }

        if (samples_log2 != 0) {
            const dimensions = msaa64kBlockDimensions(bytes_per_element, samples_log2);
            return .{
                .family = if (tile_mode == .depth) .depth_64kb else .render_target_64kb,
                .bytes_per_element = bytes_per_element,
                .samples_log2 = samples_log2,
                .bytes = 65536,
                .width = dimensions[0],
                .height = dimensions[1],
                .depth = 1,
            };
        }

        const thin = try BlockLayout.init(tile_mode, bytes_per_element);
        return .{
            .family = switch (tile_mode) {
                .linear => .linear,
                .standard_256b => .standard_256b,
                .standard_4kb => .standard_4kb,
                .standard_64kb => .standard_64kb,
                .partially_resident => .partially_resident,
                .depth => .depth_64kb,
                .render_target => .render_target_64kb,
                _ => return Error.UnsupportedTileMode,
            },
            .bytes_per_element = bytes_per_element,
            .samples_log2 = 0,
            .bytes = thin.bytes,
            .width = thin.width,
            .height = thin.height,
            .depth = 1,
        };
    }

    pub fn byteOffset(
        self: SwizzleBlock,
        x: u32,
        y: u32,
        z: u32,
        sample: u32,
    ) Error!u32 {
        if (sample >= (@as(u32, 1) << @intCast(self.samples_log2))) {
            return Error.CoordinateOutOfRange;
        }
        if (self.family != .depth_64kb and self.family != .render_target_64kb and
            (x >= self.width or y >= self.height or z >= self.depth))
        {
            return Error.CoordinateOutOfRange;
        }
        const offset = switch (self.family) {
            .linear => 0,
            .standard_256b => standard4kOffset(x, y, self.bytes_per_element) & 0xff,
            .standard_4kb => standard4kOffset(x, y, self.bytes_per_element),
            .standard_4kb_3d => standard4k3dOffset(x, y, z, self.bytes_per_element),
            .standard_64kb => standard64kOffset(x, y, self.bytes_per_element),
            .standard_64kb_3d => standard64k3dOffset(x, y, z, self.bytes_per_element),
            .partially_resident => prt64kOffset(x, y, self.bytes_per_element),
            .partially_resident_3d => prt64k3dOffset(x, y, z, self.bytes_per_element),
            .depth_64kb => rbPlus64kOffset(.depth, x, y, z, sample, self.bytes_per_element, self.samples_log2),
            .render_target_64kb => rbPlus64kOffset(.render_target, x, y, z, sample, self.bytes_per_element, self.samples_log2),
        };
        std.debug.assert(offset < self.bytes);
        std.debug.assert(offset % self.bytes_per_element == 0);
        return offset;
    }
};

/// One tightly packed linear staging view over a guest base subresource.
pub const MetadataSurface = struct {
    dcc_enabled: bool = false,
    cmask_fast_clear: bool = false,
    fmask_compression: bool = false,
    metadata_address: u64 = 0,
    dcc_address: u64 = 0,
    cmask_address: u64 = 0,
    fmask_address: u64 = 0,

    pub fn fromImage(image: resources.ImageDescriptor) MetadataSurface {
        const metadata = image.metadata_address;
        return .{
            .dcc_enabled = image.dcc_enabled,
            .cmask_fast_clear = image.cmask_fast_clear,
            .fmask_compression = image.fmask_compression,
            .metadata_address = metadata,
            .dcc_address = if (image.dcc_address != 0) image.dcc_address else metadata,
            .cmask_address = if (image.cmask_address != 0) image.cmask_address else metadata,
            .fmask_address = if (image.fmask_address != 0) image.fmask_address else metadata,
        };
    }

    pub fn hasAny(self: MetadataSurface) bool {
        return self.metadata_address != 0 or self.dcc_address != 0 or
            self.cmask_address != 0 or self.fmask_address != 0;
    }

    pub fn stage(self: MetadataSurface, reader: shaders.MemoryReader, destination: []u8) StageError!void {
        if (destination.len == 0) return;
        const source = if (self.dcc_address != 0)
            self.dcc_address
        else if (self.cmask_address != 0)
            self.cmask_address
        else if (self.fmask_address != 0)
            self.fmask_address
        else
            self.metadata_address;
        if (source == 0) return;

        var offset: usize = 0;
        var chunk: [256]u8 = undefined;
        while (offset < destination.len) {
            const chunk_len = @min(chunk.len, destination.len - offset);
            reader.read(source + @as(u64, @intCast(offset)), chunk[0..chunk_len]) catch break;
            @memcpy(destination[offset..][0..chunk_len], chunk[0..chunk_len]);
            offset += chunk_len;
        }
    }

    pub fn stageRgba(self: MetadataSurface, reader: shaders.MemoryReader, destination: []u8, width: u32, height: u32) StageError!void {
        _ = height;
        if (destination.len == 0) return;
        const source = if (self.dcc_address != 0)
            self.dcc_address
        else if (self.cmask_address != 0)
            self.cmask_address
        else if (self.fmask_address != 0)
            self.fmask_address
        else
            self.metadata_address;
        if (source == 0) return;

        var pixel_idx: usize = 0;
        var offset: usize = 0;
        while (offset + 3 < destination.len) {
            const x = @as(u32, @intCast(pixel_idx)) % width;
            const y = @as(u32, @intCast(pixel_idx)) / width;

            // Assume metadata is 1 byte per 8x8 block (common for DCC)
            const block_x = x / 8;
            const block_y = y / 8;
            const pitch_blocks = (width + 7) / 8;
            const meta_offset = block_y * pitch_blocks + block_x;

            var chunk: [1]u8 = undefined;
            reader.read(source + meta_offset, &chunk) catch {
                chunk[0] = 0;
            };
            const meta = chunk[0];

            if (self.dcc_enabled or self.dcc_address != 0) {
                // DCC colors: 0=uncompressed(white), 0x20=fast clear(green), other=compressed(shades)
                destination[offset] = if (meta == 0) 255 else if (meta == 0x20) 0 else meta;
                destination[offset + 1] = if (meta == 0) 255 else if (meta == 0x20) 255 else 0;
                destination[offset + 2] = if (meta == 0) 255 else if (meta == 0x20) 0 else 255 -% meta;
                destination[offset + 3] = 255;
            } else if (self.cmask_fast_clear or self.cmask_address != 0) {
                // CMASK colors
                destination[offset] = 0;
                destination[offset + 1] = meta;
                destination[offset + 2] = 255;
                destination[offset + 3] = 255;
            } else if (self.fmask_compression or self.fmask_address != 0) {
                // FMASK colors
                destination[offset] = meta;
                destination[offset + 1] = 0;
                destination[offset + 2] = meta;
                destination[offset + 3] = 255;
            } else {
                // Generic metadata
                destination[offset] = meta;
                destination[offset + 1] = meta;
                destination[offset + 2] = meta;
                destination[offset + 3] = 255;
            }

            offset += 4;
            pixel_idx += 1;
        }
    }
};

/// GFX10 CMASK allocation and nibble addressing for Oberon's RB+ topology.
///
/// CMASK stores one four-bit element per 8x8 pixel region. On a 16-pipe,
/// eight-pixel-packer RB+ device those elements are swizzled in 1024x512 pixel
/// metadata blocks; each block occupies 4 KiB. The equation below is AMD
/// AddrLib's GFX10 CMASK pattern 15, selected by PS5's supported 1x-8x
/// sample/fragment combinations.
pub const CmaskLayout = struct {
    pub const block_width: u32 = 1024;
    pub const block_height: u32 = 512;
    pub const block_bytes: u32 = 4096;

    width: u32,
    height: u32,
    layers: u32,
    first_slice: u32,
    pitch: u32,
    padded_height: u32,
    blocks_per_row: u32,
    slice_bytes: u64,
    required_bytes: u64,
    /// ADDR2's pipeBankXor. AGC colour-target state currently supplies no
    /// separate XOR value, so decoded targets use zero.
    pipe_xor: u8 = 0,

    pub const Element = struct {
        byte_offset: u64,
        shift: u3,
    };

    pub fn init(
        width: u32,
        height: u32,
        layers: u32,
        first_slice: u32,
        row_pitch_pixels: u32,
    ) Error!CmaskLayout {
        if (width == 0 or height == 0 or layers == 0) return Error.InvalidExtent;
        const requested_pitch = if (row_pitch_pixels == 0) width else row_pitch_pixels;
        if (requested_pitch < width) return Error.InvalidPitch;
        const pitch = try alignForward(requested_pitch, block_width);
        const padded_height = try alignForward(height, block_height);
        const slice_pixels = try multiply(pitch, padded_height);
        const slice_bytes = slice_pixels / 128;
        std.debug.assert(slice_pixels % 128 == 0);
        const physical_slices = try addU32(first_slice, layers);
        const required_bytes = try multiply(slice_bytes, physical_slices);
        return .{
            .width = width,
            .height = height,
            .layers = layers,
            .first_slice = first_slice,
            .pitch = pitch,
            .padded_height = padded_height,
            .blocks_per_row = pitch / block_width,
            .slice_bytes = slice_bytes,
            .required_bytes = required_bytes,
        };
    }

    pub fn fromColorTarget(target: resources.ColorTarget) Error!CmaskLayout {
        if (target.mip_level != 0) return Error.UnsupportedMipChain;
        // AddrLib exposes CMASK only for GFX10's 64KB_Z_X surface mode. The
        // resource enum calls that mode `depth`, but it is also legal for a
        // colour/MSAA allocation.
        if (target.cmask_linear or target.tile_mode != .depth) {
            return Error.UnsupportedMetadataLayout;
        }
        const layers: u32 = if (target.last_array_slice >= target.base_array_slice)
            @as(u32, target.last_array_slice) - target.base_array_slice + 1
        else
            1;
        var metadata_pitch = target.width;
        if (target.cmask_slice_bytes != 0) {
            const padded_height = try alignForward(target.height, block_height);
            const slice_pixels = try multiply(target.cmask_slice_bytes, 128);
            if (slice_pixels % padded_height != 0) return Error.UnsupportedMetadataLayout;
            metadata_pitch = try u32FromU64(slice_pixels / padded_height);
            if (metadata_pitch < target.width or metadata_pitch % block_width != 0) {
                return Error.UnsupportedMetadataLayout;
            }
        }
        const layout = try init(
            target.width,
            target.height,
            layers,
            target.base_array_slice,
            metadata_pitch,
        );
        if (target.cmask_slice_bytes != 0 and layout.slice_bytes != target.cmask_slice_bytes) {
            return Error.UnsupportedMetadataLayout;
        }
        return layout;
    }

    pub fn element(self: CmaskLayout, x: u32, y: u32, layer: u32) Error!Element {
        if (x >= self.width or y >= self.height or layer >= self.layers) {
            return Error.CoordinateOutOfRange;
        }
        const physical_slice = try addU32(self.first_slice, layer);
        const slice_base = try multiply(self.slice_bytes, physical_slice);
        const block_x = x / block_width;
        const block_y = y / block_height;
        const block_index = try add(try multiply(block_y, self.blocks_per_row), block_x);
        const block_base = try multiply(block_index, block_bytes);
        const nibble_offset = cmaskRbPlusNibbleOffset(x, y, physical_slice);
        const pipe_xor = (@as(u32, self.pipe_xor & 0x0f) << 8) & (block_bytes - 1);
        return .{
            .byte_offset = try add(try add(slice_base, block_base), (nibble_offset >> 1) ^ pipe_xor),
            .shift = @intCast((nibble_offset & 1) << 2),
        };
    }

    pub fn value(self: CmaskLayout, metadata: []const u8, x: u32, y: u32, layer: u32) Error!u4 {
        const location = try self.element(x, y, layer);
        const byte_offset = std.math.cast(usize, location.byte_offset) orelse
            return Error.ArithmeticOverflow;
        if (byte_offset >= metadata.len) return Error.SourceTooSmall;
        return @truncate(metadata[byte_offset] >> location.shift);
    }

    pub fn setValue(self: CmaskLayout, metadata: []u8, x: u32, y: u32, layer: u32, value_: u4) Error!void {
        const location = try self.element(x, y, layer);
        const byte_offset = std.math.cast(usize, location.byte_offset) orelse
            return Error.ArithmeticOverflow;
        if (byte_offset >= metadata.len) return Error.DestinationTooSmall;
        const mask: u8 = @as(u8, 0x0f) << location.shift;
        metadata[byte_offset] = (metadata[byte_offset] & ~mask) |
            (@as(u8, value_) << location.shift);
    }
};

/// GFX10 HTILE allocation and dword addressing for Oberon's RB+ topology.
///
/// One 32-bit word summarizes an 8x8 depth region. A 16-pipe, eight-pixel-
/// packer device selects AMD AddrLib's HTILE pattern 21, whose 1024x512-pixel
/// metadata blocks occupy 32 KiB. HTILE is only defined for pipe-aligned
/// 64KB_Z_X depth surfaces on this path.
pub const HtileLayout = struct {
    pub const block_width: u32 = 1024;
    pub const block_height: u32 = 512;
    pub const block_bytes: u32 = 32 * 1024;
    pub const region_width: u32 = 8;
    pub const region_height: u32 = 8;

    /// Uncompressed, full-range metadata values used after materializing a
    /// fast clear into the base depth/stencil allocations.
    pub const expanded_depth: u32 = 0xfffc_000f;
    pub const expanded_depth_stencil: u32 = 0xffff_f3ff;

    width: u32,
    height: u32,
    layers: u32,
    first_slice: u32,
    pitch: u32,
    padded_height: u32,
    blocks_per_row: u32,
    slice_bytes: u64,
    required_bytes: u64,
    /// ADDR2's pipeBankXor. AGC depth-target state currently supplies no
    /// separate XOR value, so decoded targets use zero.
    pipe_xor: u8 = 0,

    pub fn init(
        width: u32,
        height: u32,
        layers: u32,
        first_slice: u32,
        row_pitch_pixels: u32,
    ) Error!HtileLayout {
        if (width == 0 or height == 0 or layers == 0) return Error.InvalidExtent;
        const requested_pitch = if (row_pitch_pixels == 0) width else row_pitch_pixels;
        if (requested_pitch < width) return Error.InvalidPitch;
        const pitch = try alignForward(requested_pitch, block_width);
        const padded_height = try alignForward(height, block_height);
        const slice_pixels = try multiply(pitch, padded_height);
        const slice_bytes = slice_pixels / 16;
        std.debug.assert(slice_pixels % 16 == 0);
        const physical_slices = try addU32(first_slice, layers);
        return .{
            .width = width,
            .height = height,
            .layers = layers,
            .first_slice = first_slice,
            .pitch = pitch,
            .padded_height = padded_height,
            .blocks_per_row = pitch / block_width,
            .slice_bytes = slice_bytes,
            .required_bytes = try multiply(slice_bytes, physical_slices),
        };
    }

    pub fn fromDepthTarget(target: resources.DepthTarget) Error!HtileLayout {
        if (!target.htile_enabled or target.htile_address == 0 or !target.htile_pipe_aligned or
            target.tile_mode != .depth)
        {
            return Error.UnsupportedMetadataLayout;
        }
        if (target.mip_level != 0 or target.maximum_mip != 0) return Error.UnsupportedMipChain;
        if (target.samples_log2 > 3) return Error.UnsupportedMultisample;
        const layers: u32 = if (target.last_array_slice >= target.base_array_slice)
            @as(u32, target.last_array_slice) - target.base_array_slice + 1
        else
            1;
        return init(target.width, target.height, layers, target.base_array_slice, target.width);
    }

    /// Returns the byte address of the 32-bit HTILE word covering `(x, y)`.
    pub fn wordOffset(self: HtileLayout, x: u32, y: u32, layer: u32) Error!u64 {
        if (x >= self.width or y >= self.height or layer >= self.layers) {
            return Error.CoordinateOutOfRange;
        }
        const physical_slice = try addU32(self.first_slice, layer);
        const slice_base = try multiply(self.slice_bytes, physical_slice);
        const block_x = x / block_width;
        const block_y = y / block_height;
        const block_index = try add(try multiply(block_y, self.blocks_per_row), block_x);
        const block_base = try multiply(block_index, block_bytes);
        const local = htileRbPlusByteOffset(x, y, physical_slice);
        const pipe_xor = (@as(u32, self.pipe_xor & 0x0f) << 8) & (block_bytes - 1);
        return add(try add(slice_base, block_base), local ^ pipe_xor);
    }

    pub fn word(self: HtileLayout, metadata: []const u8, x: u32, y: u32, layer: u32) Error!u32 {
        const byte_offset = std.math.cast(usize, try self.wordOffset(x, y, layer)) orelse
            return Error.ArithmeticOverflow;
        if (byte_offset > metadata.len or metadata.len - byte_offset < @sizeOf(u32)) {
            return Error.SourceTooSmall;
        }
        return std.mem.readInt(u32, metadata[byte_offset..][0..4], .little);
    }

    pub fn setWord(self: HtileLayout, metadata: []u8, x: u32, y: u32, layer: u32, value: u32) Error!void {
        const byte_offset = std.math.cast(usize, try self.wordOffset(x, y, layer)) orelse
            return Error.ArithmeticOverflow;
        if (byte_offset > metadata.len or metadata.len - byte_offset < @sizeOf(u32)) {
            return Error.DestinationTooSmall;
        }
        std.mem.writeInt(u32, metadata[byte_offset..][0..4], value, .little);
    }

    pub fn fastClearDepth(word_: u32, tile_stencil_disabled: bool) ?f32 {
        if (tile_stencil_disabled) return switch (word_) {
            0x0000_0000 => 0.0,
            0xffff_fff0 => 1.0,
            else => null,
        };
        return switch (word_) {
            0x0000_00f0 => 0.0,
            0xfffc_00f0 => 1.0,
            else => null,
        };
    }

    pub fn expandedWord(tile_stencil_disabled: bool) u32 {
        return if (tile_stencil_disabled) expanded_depth else expanded_depth_stencil;
    }
};

pub const Layout = struct {
    block: BlockLayout,
    width: u32,
    height: u32,
    layers: u32,
    first_slice: u32,
    /// Extra guest bytes from the allocation origin to this view, used when
    /// staging a non-zero mip through the 2D layout.
    source_base_offset: u64 = 0,
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
        const element = elementLayoutForUnifiedFormat(image.unified_format) orelse
            return Error.UnsupportedFormat;
        if (image.viewBaseLevel() != 0) {
            const texture = try TextureLayout.fromImage(image);
            const view = try texture.subresource(image.viewBaseLevel(), 0, texture.layers);
            if (view.kind != .array_2d or view.in_tail) return Error.UnsupportedMipChain;
            var layout = try init(.{
                .tile_mode = image.tile_mode,
                .width = view.width,
                .height = view.height,
                .layers = view.depth_or_layers,
                .first_slice = view.first_slice,
                .row_pitch_elements = view.padded_width,
            }, element.bytes);
            layout.source_base_offset = view.level_offset;
            layout.source_slice_bytes = view.source_layer_bytes;
            layout.required_source_bytes = view.required_source_bytes;
            return layout;
        }

        const width = try texelsToElements(image.width, element.texels_wide);
        const height = try texelsToElements(@max(image.height, 1), element.texels_high);
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
        const slice_base = try add(try multiply(self.source_slice_bytes, physical_slice), self.source_base_offset);
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
        return switch (self.block.bytes_per_element) {
            1 => self.detileElements(1, source, destination),
            2 => self.detileElements(2, source, destination),
            4 => self.detileElements(4, source, destination),
            8 => self.detileElements(8, source, destination),
            16 => self.detileElements(16, source, destination),
            else => Error.UnsupportedElementSize,
        };
    }

    fn detileElements(
        self: Layout,
        comptime element_bytes: usize,
        source: []const u8,
        destination: []u8,
    ) Error!void {
        if (self.block.tile_mode.isLinear()) {
            const row_bytes = @as(usize, self.width) * element_bytes;
            const source_row_bytes = @as(usize, self.row_pitch_elements) * element_bytes;
            for (0..self.layers) |layer_index| {
                const physical_slice = @as(usize, self.first_slice) + layer_index;
                const source_slice: usize = @intCast(self.source_slice_bytes * physical_slice + self.source_base_offset);
                const staging_slice: usize = @intCast(self.staging_slice_bytes * layer_index);
                for (0..self.height) |y| {
                    const src = source_slice + y * source_row_bytes;
                    const dst = staging_slice + y * row_bytes;
                    @memcpy(destination[dst..][0..row_bytes], source[src..][0..row_bytes]);
                }
            }
            return;
        }

        // Addressing inside a swizzle block repeats for every macro block. The
        // former pixel-major loop recomputed divisions and checked coordinate
        // arithmetic for every texel (16.7 million times for a 4096² image).
        // Cache one local row of offsets and reuse it across all blocks in that
        // macro row while keeping source and destination accesses contiguous.
        var row_offsets: [256]u32 = undefined;
        if (self.block.width > row_offsets.len) return Error.UnsupportedTileMode;
        for (0..self.layers) |layer_index| {
            const physical_slice: u32 = try addU32(self.first_slice, @intCast(layer_index));
            const source_slice: usize = @intCast(try add(try multiply(self.source_slice_bytes, physical_slice), self.source_base_offset));
            const staging_slice: usize = @intCast(try multiply(self.staging_slice_bytes, layer_index));
            // The in-block address map is identical in every macro-block row.
            // Make local_y the outer loop so each row is evaluated once per
            // layer, rather than once per block_y. For a 3840x2160 64 KiB
            // surface this removes 17 repeats of the expensive RB+ parity map.
            for (0..self.block.height) |local_y_index| {
                const local_y: u32 = @intCast(local_y_index);
                for (0..self.block.width) |local_x_index| {
                    row_offsets[local_x_index] = try self.block.byteOffset(@intCast(local_x_index), local_y);
                }
                for (0..self.blocks_per_column) |block_y_index| {
                    const block_y: u32 = @intCast(block_y_index);
                    const y = block_y * self.block.height + local_y;
                    if (y >= self.height) continue;
                    for (0..self.blocks_per_row) |block_x_index| {
                        const block_x: u32 = @intCast(block_x_index);
                        const x_base = block_x * self.block.width;
                        if (x_base >= self.width) continue;
                        const copy_width = @min(self.block.width, self.width - x_base);
                        const block_index = @as(usize, block_y) * self.blocks_per_row + block_x;
                        const source_block = source_slice + block_index * self.block.bytes;
                        const block_xor = try self.block.blockXor(block_x, block_y, physical_slice);
                        const destination_row = staging_slice +
                            (@as(usize, y) * self.width + x_base) * element_bytes;
                        for (0..copy_width) |local_x| {
                            const src = source_block + (row_offsets[local_x] ^ block_xor);
                            const dst = destination_row + local_x * element_bytes;
                            @memcpy(destination[dst..][0..element_bytes], source[src..][0..element_bytes]);
                        }
                    }
                }
            }
        }
    }

    /// Copies tightly packed staging bytes back to guest layout. Padding and
    /// slices outside the view are intentionally left untouched.
    pub fn tile(self: Layout, source: []const u8, destination: []u8) Error!void {
        if (@as(u64, source.len) < self.staging_bytes) return Error.SourceTooSmall;
        if (@as(u64, destination.len) < self.required_source_bytes) return Error.DestinationTooSmall;
        return switch (self.block.bytes_per_element) {
            1 => self.tileElements(1, source, destination),
            2 => self.tileElements(2, source, destination),
            4 => self.tileElements(4, source, destination),
            8 => self.tileElements(8, source, destination),
            16 => self.tileElements(16, source, destination),
            else => Error.UnsupportedElementSize,
        };
    }

    fn tileElements(
        self: Layout,
        comptime element_bytes: usize,
        source: []const u8,
        destination: []u8,
    ) Error!void {
        if (self.block.tile_mode.isLinear()) {
            const row_bytes = @as(usize, self.width) * element_bytes;
            const destination_row_bytes = @as(usize, self.row_pitch_elements) * element_bytes;
            for (0..self.layers) |layer_index| {
                const physical_slice = @as(usize, self.first_slice) + layer_index;
                const destination_slice: usize = @intCast(self.source_slice_bytes * physical_slice + self.source_base_offset);
                const staging_slice: usize = @intCast(self.staging_slice_bytes * layer_index);
                for (0..self.height) |y| {
                    const src = staging_slice + y * row_bytes;
                    const dst = destination_slice + y * destination_row_bytes;
                    @memcpy(destination[dst..][0..row_bytes], source[src..][0..row_bytes]);
                }
            }
            return;
        }

        var row_offsets: [256]u32 = undefined;
        if (self.block.width > row_offsets.len) return Error.UnsupportedTileMode;
        for (0..self.layers) |layer_index| {
            const physical_slice: u32 = try addU32(self.first_slice, @intCast(layer_index));
            const destination_slice: usize = @intCast(try add(try multiply(self.source_slice_bytes, physical_slice), self.source_base_offset));
            const staging_slice: usize = @intCast(try multiply(self.staging_slice_bytes, layer_index));
            for (0..self.block.height) |local_y_index| {
                const local_y: u32 = @intCast(local_y_index);
                for (0..self.block.width) |local_x_index| {
                    row_offsets[local_x_index] = try self.block.byteOffset(@intCast(local_x_index), local_y);
                }
                for (0..self.blocks_per_column) |block_y_index| {
                    const block_y: u32 = @intCast(block_y_index);
                    const y = block_y * self.block.height + local_y;
                    if (y >= self.height) continue;
                    for (0..self.blocks_per_row) |block_x_index| {
                        const block_x: u32 = @intCast(block_x_index);
                        const x_base = block_x * self.block.width;
                        if (x_base >= self.width) continue;
                        const copy_width = @min(self.block.width, self.width - x_base);
                        const block_index = @as(usize, block_y) * self.blocks_per_row + block_x;
                        const destination_block = destination_slice + block_index * self.block.bytes;
                        const block_xor = try self.block.blockXor(block_x, block_y, physical_slice);
                        const source_row = staging_slice +
                            (@as(usize, y) * self.width + x_base) * element_bytes;
                        for (0..copy_width) |local_x| {
                            const src = source_row + local_x * element_bytes;
                            const dst = destination_block + (row_offsets[local_x] ^ block_xor);
                            @memcpy(destination[dst..][0..element_bytes], source[src..][0..element_bytes]);
                        }
                    }
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

pub const maximum_mip_levels: u8 = 16;

pub const TextureKind = enum(u8) {
    array_2d,
    volume_3d,
};

/// Allocation description in element coordinates. For BC formats one element
/// is one compressed 4x4 block, just like the legacy `Layout` contract.
pub const Texture = struct {
    tile_mode: resources.TileMode,
    kind: TextureKind = .array_2d,
    width: u32,
    height: u32,
    depth_or_layers: u32 = 1,
    first_slice: u32 = 0,
    mip_levels: u8 = 1,
    samples_log2: u8 = 0,
    /// Used only by a one-level 2D allocation. Zero selects the logical width.
    row_pitch_elements: u32 = 0,
};

pub const MipLevel = struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
    padded_width: u32 = 0,
    padded_height: u32 = 0,
    offset: u64 = 0,
    storage_bytes: u64 = 0,
    tail_x: u32 = 0,
    tail_y: u32 = 0,
    in_tail: bool = false,
};

/// Allocation-free placement for all mips and slices of one guest texture.
/// Small mips share one swizzle block at the start of each array slice (or
/// volume block-slice), matching GFX10's smallest-mip-first convention.
pub const TextureLayout = struct {
    block: SwizzleBlock,
    kind: TextureKind,
    mip_levels: u8,
    first_tail_level: u8,
    layers: u32,
    first_slice: u32,
    source_layer_bytes: u64,
    block_slice_bytes: u64,
    required_source_bytes: u64,
    levels: [maximum_mip_levels]MipLevel,

    pub fn init(texture: Texture, bytes_per_element: u8) Error!TextureLayout {
        if (texture.width == 0 or texture.height == 0 or texture.depth_or_layers == 0 or
            texture.mip_levels == 0 or texture.mip_levels > maximum_mip_levels)
        {
            return Error.InvalidExtent;
        }
        if (texture.kind == .volume_3d and texture.first_slice != 0) return Error.UnsupportedVolume;
        if (texture.samples_log2 != 0 and texture.mip_levels != 1) {
            return Error.UnsupportedMipChain;
        }
        const volume = texture.kind == .volume_3d;
        const block = try SwizzleBlock.init(
            texture.tile_mode,
            bytes_per_element,
            volume,
            texture.samples_log2,
        );
        var out = TextureLayout{
            .block = block,
            .kind = texture.kind,
            .mip_levels = texture.mip_levels,
            .first_tail_level = texture.mip_levels,
            .layers = if (volume) 1 else texture.depth_or_layers,
            .first_slice = texture.first_slice,
            .source_layer_bytes = 0,
            .block_slice_bytes = 0,
            .required_source_bytes = 0,
            .levels = [_]MipLevel{.{}} ** maximum_mip_levels,
        };
        if (volume) {
            try out.placeVolume(texture);
        } else {
            try out.placeArray(texture);
        }
        return out;
    }

    pub fn fromImage(image: resources.ImageDescriptor) Error!TextureLayout {
        const element = elementLayoutForUnifiedFormat(image.unified_format) orelse
            return Error.UnsupportedFormat;
        const width = try texelsToElements(image.width, element.texels_wide);
        const height = try texelsToElements(image.height, element.texels_high);
        const volume = image.image_type == .color_3d;
        const arrayed = image.image_type.isArray();
        const first_slice: u32 = if (arrayed) image.base_array else 0;
        const layers_or_depth: u32 = if (volume)
            image.depth_or_layers
        else if (arrayed and image.depth_or_layers > first_slice)
            image.depth_or_layers - first_slice
        else
            1;
        return init(.{
            .tile_mode = image.tile_mode,
            .kind = if (volume) .volume_3d else .array_2d,
            .width = width,
            .height = height,
            .depth_or_layers = layers_or_depth,
            .first_slice = first_slice,
            .mip_levels = image.resourceMipLevels(),
            .samples_log2 = image.samplesLog2(),
            .row_pitch_elements = if (image.resourceMipLevels() == 1)
                try texelsToElements(@max(image.pitch, image.width), element.texels_wide)
            else
                0,
        }, element.bytes);
    }

    pub fn fromColorTarget(target: resources.ColorTarget) Error!TextureLayout {
        const bytes = colorBytesPerElement(target.format) orelse return Error.UnsupportedFormat;
        if (target.samples_log2 > 3 or target.fragments_log2 > target.samples_log2) {
            return Error.UnsupportedMultisample;
        }
        const layers: u32 = if (target.last_array_slice >= target.base_array_slice)
            @as(u32, target.last_array_slice) - target.base_array_slice + 1
        else
            1;
        return init(.{
            .tile_mode = target.tile_mode,
            .width = target.width,
            .height = target.height,
            .depth_or_layers = layers,
            .first_slice = target.base_array_slice,
            .mip_levels = @max(target.maximum_mip + 1, 1),
            .samples_log2 = target.fragments_log2,
            .row_pitch_elements = if (target.maximum_mip == 0) target.pitch else 0,
        }, bytes);
    }

    pub fn fromDepthTarget(target: resources.DepthTarget) Error!TextureLayout {
        const bytes: u8 = switch (target.format) {
            1 => 2,
            3 => 4,
            else => return Error.UnsupportedFormat,
        };
        const layers: u32 = if (target.last_array_slice >= target.base_array_slice)
            @as(u32, target.last_array_slice) - target.base_array_slice + 1
        else
            1;
        return init(.{
            .tile_mode = target.tile_mode,
            .width = target.width,
            .height = target.height,
            .depth_or_layers = layers,
            .first_slice = target.base_array_slice,
            .mip_levels = @max(target.maximum_mip + 1, 1),
            .samples_log2 = target.samples_log2,
        }, bytes);
    }

    pub fn fromStencilTarget(target: resources.DepthTarget) Error!TextureLayout {
        if (target.stencil_format != 1) return Error.UnsupportedFormat;
        const layers: u32 = if (target.last_array_slice >= target.base_array_slice)
            @as(u32, target.last_array_slice) - target.base_array_slice + 1
        else
            1;
        return init(.{
            .tile_mode = target.stencil_tile_mode,
            .width = target.width,
            .height = target.height,
            .depth_or_layers = layers,
            .first_slice = target.base_array_slice,
            .mip_levels = @max(target.maximum_mip + 1, 1),
            .samples_log2 = target.samples_log2,
        }, 1);
    }

    pub fn subresource(
        self: TextureLayout,
        level: u8,
        first_layer: u32,
        layer_count: u32,
    ) Error!SubresourceLayout {
        if (level >= self.mip_levels or layer_count == 0) return Error.CoordinateOutOfRange;
        if (self.kind == .volume_3d) {
            if (first_layer != 0 or layer_count != 1) return Error.CoordinateOutOfRange;
        } else if (first_layer >= self.layers or layer_count > self.layers - first_layer) {
            return Error.CoordinateOutOfRange;
        }
        const mip = self.levels[level];
        return .{
            .block = self.block,
            .kind = self.kind,
            .width = mip.width,
            .height = mip.height,
            .depth_or_layers = if (self.kind == .volume_3d) mip.depth else layer_count,
            .first_slice = if (self.kind == .array_2d)
                try addU32(self.first_slice, first_layer)
            else
                0,
            .padded_width = mip.padded_width,
            .padded_height = mip.padded_height,
            .level_offset = mip.offset,
            .source_layer_bytes = self.source_layer_bytes,
            .block_slice_bytes = self.block_slice_bytes,
            .required_source_bytes = self.required_source_bytes,
            .tail_x = mip.tail_x,
            .tail_y = mip.tail_y,
            .in_tail = mip.in_tail,
        };
    }

    pub fn base(self: TextureLayout) Error!SubresourceLayout {
        return self.subresource(0, 0, self.layers);
    }

    fn placeArray(self: *TextureLayout, texture: Texture) Error!void {
        const levels: u8 = texture.mip_levels;
        if (self.block.family == .linear) {
            for (0..levels) |index| {
                const level: u8 = @intCast(index);
                const width = shiftCeil(texture.width, level);
                const height = shiftCeil(texture.height, level);
                var pitch = try alignForward(width, @max(@as(u32, 1), 256 / @as(u32, self.block.bytes_per_element)));
                if (level == 0 and texture.row_pitch_elements != 0) {
                    if (texture.row_pitch_elements < width) return Error.InvalidPitch;
                    pitch = try alignForward(texture.row_pitch_elements, @max(@as(u32, 1), 256 / @as(u32, self.block.bytes_per_element)));
                }
                self.levels[level] = .{
                    .width = width,
                    .height = height,
                    .depth = 1,
                    .padded_width = pitch,
                    .padded_height = height,
                    .storage_bytes = try multiply3(pitch, height, self.block.bytes_per_element),
                };
            }
            try self.placeSmallestFirst(0);
            self.source_layer_bytes = try alignForward64(self.source_layer_bytes, 256);
        } else if (self.block.family == .standard_256b or levels == 1 or self.block.samples_log2 != 0) {
            for (0..levels) |index| {
                const level: u8 = @intCast(index);
                const width = shiftCeil(texture.width, level);
                const height = shiftCeil(texture.height, level);
                var storage_width = width;
                if (level == 0 and texture.row_pitch_elements != 0) {
                    if (texture.row_pitch_elements < width) return Error.InvalidPitch;
                    storage_width = texture.row_pitch_elements;
                }
                const padded_width = try alignForward(storage_width, self.block.width);
                const padded_height = try alignForward(height, self.block.height);
                self.levels[level] = .{
                    .width = width,
                    .height = height,
                    .depth = 1,
                    .padded_width = padded_width,
                    .padded_height = padded_height,
                    .storage_bytes = try multiply3(
                        try multiply(padded_width, padded_height),
                        self.block.bytes_per_element,
                        @as(u32, 1) << @intCast(self.block.samples_log2),
                    ),
                };
            }
            try self.placeSmallestFirst(0);
        } else {
            const max_tail: u8 = if (self.block.bytes == 4096) 8 else 12;
            var tail_width = self.block.width / 2;
            var tail_height = self.block.height;
            if (self.block.family == .depth_64kb and self.block.bytes_per_element < 4) {
                tail_width = 64;
                tail_height = 128;
            }
            self.first_tail_level = findFirstTail(
                texture.width,
                texture.height,
                levels,
                tail_width,
                tail_height,
                max_tail,
            );
            for (0..levels) |index| {
                const level: u8 = @intCast(index);
                const width = shiftCeil(texture.width, level);
                const height = shiftCeil(texture.height, level);
                if (level >= self.first_tail_level) {
                    const location = tailLocation(self.block, level - self.first_tail_level);
                    self.levels[level] = .{
                        .width = width,
                        .height = height,
                        .depth = 1,
                        .padded_width = self.block.width,
                        .padded_height = self.block.height,
                        .storage_bytes = self.block.bytes,
                        .tail_x = location[0],
                        .tail_y = location[1],
                        .in_tail = true,
                    };
                } else {
                    const padded_width = try alignForward(width, self.block.width);
                    const padded_height = try alignForward(height, self.block.height);
                    self.levels[level] = .{
                        .width = width,
                        .height = height,
                        .depth = 1,
                        .padded_width = padded_width,
                        .padded_height = padded_height,
                        .storage_bytes = try multiply3(padded_width, padded_height, self.block.bytes_per_element),
                    };
                }
            }
            try self.placeSmallestFirst(if (self.first_tail_level < levels) self.block.bytes else 0);
        }
        self.block_slice_bytes = self.source_layer_bytes;
        const physical_layers = try addU32(self.first_slice, self.layers);
        self.required_source_bytes = try multiply(self.source_layer_bytes, physical_layers);
    }

    fn placeVolume(self: *TextureLayout, texture: Texture) Error!void {
        if (self.block.family == .linear) {
            if (texture.mip_levels != 1) return Error.UnsupportedMipChain;
            const requested_pitch = if (texture.row_pitch_elements == 0)
                texture.width
            else
                texture.row_pitch_elements;
            if (requested_pitch < texture.width) return Error.InvalidPitch;
            const pitch = try alignForward(
                requested_pitch,
                @max(@as(u32, 1), 256 / @as(u32, self.block.bytes_per_element)),
            );
            const slice_bytes = try multiply3(
                pitch,
                texture.height,
                self.block.bytes_per_element,
            );
            const storage_bytes = try multiply(slice_bytes, texture.depth_or_layers);
            self.levels[0] = .{
                .width = texture.width,
                .height = texture.height,
                .depth = texture.depth_or_layers,
                .padded_width = pitch,
                .padded_height = texture.height,
                .storage_bytes = storage_bytes,
            };
            self.source_layer_bytes = slice_bytes;
            self.block_slice_bytes = slice_bytes;
            self.required_source_bytes = storage_bytes;
            return;
        }
        const thick4 = self.block.family == .standard_4kb_3d;
        const thick64 = self.block.family == .standard_64kb_3d or
            self.block.family == .partially_resident_3d;
        const max_tail: u8 = if (thick4) 5 else if (thick64) 10 else 12;
        var tail_width = if (thick4) self.block.width else self.block.width / 2;
        var tail_height = if (thick4) self.block.height / 2 else self.block.height;
        if (self.block.family == .depth_64kb and self.block.bytes_per_element < 4) {
            tail_width = 64;
            tail_height = 128;
        }
        self.first_tail_level = findFirstTail(
            texture.width,
            texture.height,
            texture.mip_levels,
            tail_width,
            tail_height,
            max_tail,
        );
        var block_slice_bytes: u64 = if (self.first_tail_level < texture.mip_levels)
            self.block.bytes
        else
            0;
        for (0..texture.mip_levels) |index| {
            const level: u8 = @intCast(index);
            const width = shiftCeil(texture.width, level);
            const height = shiftCeil(texture.height, level);
            const depth = shiftCeil(texture.depth_or_layers, level);
            if (level >= self.first_tail_level) {
                const location = tailLocation(self.block, level - self.first_tail_level);
                self.levels[level] = .{
                    .width = width,
                    .height = height,
                    .depth = depth,
                    .padded_width = self.block.width,
                    .padded_height = self.block.height,
                    .storage_bytes = self.block.bytes,
                    .tail_x = location[0],
                    .tail_y = location[1],
                    .in_tail = true,
                };
            } else {
                const padded_width = try alignForward(width, self.block.width);
                const padded_height = try alignForward(height, self.block.height);
                const size = try multiply3(
                    try multiply(self.block.depth, padded_width),
                    padded_height,
                    self.block.bytes_per_element,
                );
                self.levels[level] = .{
                    .width = width,
                    .height = height,
                    .depth = depth,
                    .padded_width = padded_width,
                    .padded_height = padded_height,
                    .storage_bytes = size,
                };
                block_slice_bytes = try add(block_slice_bytes, size);
            }
        }
        self.block_slice_bytes = block_slice_bytes;
        self.source_layer_bytes = block_slice_bytes;
        var offset: u64 = if (self.first_tail_level < texture.mip_levels) self.block.bytes else 0;
        var reverse: u8 = self.first_tail_level;
        while (reverse != 0) {
            reverse -= 1;
            self.levels[reverse].offset = offset;
            offset = try add(offset, self.levels[reverse].storage_bytes);
        }
        const block_slices = try divideRoundUp(texture.depth_or_layers, self.block.depth);
        self.required_source_bytes = try multiply(block_slice_bytes, block_slices);
    }

    fn placeSmallestFirst(self: *TextureLayout, initial_offset: u64) Error!void {
        var offset = initial_offset;
        var reverse = self.first_tail_level;
        if (self.first_tail_level == self.mip_levels) reverse = self.mip_levels;
        while (reverse != 0) {
            reverse -= 1;
            self.levels[reverse].offset = offset;
            offset = try add(offset, self.levels[reverse].storage_bytes);
        }
        self.source_layer_bytes = offset;
    }
};

/// One mip/view copied to tightly packed `[slice][y][x][sample]` staging data.
pub const SubresourceLayout = struct {
    block: SwizzleBlock,
    kind: TextureKind,
    width: u32,
    height: u32,
    depth_or_layers: u32,
    first_slice: u32,
    padded_width: u32,
    padded_height: u32,
    level_offset: u64,
    source_layer_bytes: u64,
    block_slice_bytes: u64,
    required_source_bytes: u64,
    tail_x: u32,
    tail_y: u32,
    in_tail: bool,

    pub fn samples(self: SubresourceLayout) u32 {
        return @as(u32, 1) << @intCast(self.block.samples_log2);
    }

    pub fn stagingBytes(self: SubresourceLayout) Error!u64 {
        return multiply3(
            try multiply3(self.width, self.height, self.depth_or_layers),
            self.samples(),
            self.block.bytes_per_element,
        );
    }

    pub fn sourceByteOffset(
        self: SubresourceLayout,
        x: u32,
        y: u32,
        slice_or_z: u32,
        sample: u32,
    ) Error!u64 {
        if (x >= self.width or y >= self.height or slice_or_z >= self.depth_or_layers or
            sample >= self.samples()) return Error.CoordinateOutOfRange;

        if (self.block.family == .linear) {
            const slice_base = try multiply(self.source_layer_bytes, try addU32(self.first_slice, slice_or_z));
            const row = try multiply3(y, self.padded_width, self.block.bytes_per_element);
            return add(try add(try add(slice_base, self.level_offset), row), try multiply(x, self.block.bytes_per_element));
        }

        const swizzle_x = try addU32(x, self.tail_x);
        const swizzle_y = try addU32(y, self.tail_y);
        const block_x = swizzle_x / self.block.width;
        const block_y = swizzle_y / self.block.height;
        const blocks_per_row = self.padded_width / self.block.width;
        const blocks_per_slice = try multiply(
            blocks_per_row,
            self.padded_height / self.block.height,
        );
        const block_index = try add(try multiply(block_y, blocks_per_row), block_x);
        var allocation_base = self.level_offset;
        var swizzle_z: u32 = 0;
        var local_z: u32 = 0;
        if (self.kind == .array_2d) {
            const physical_slice = try addU32(self.first_slice, slice_or_z);
            allocation_base = try add(try multiply(self.source_layer_bytes, physical_slice), self.level_offset);
            if (self.block.family == .depth_64kb or self.block.family == .render_target_64kb) {
                swizzle_z = physical_slice;
            }
        } else {
            const block_z = slice_or_z / self.block.depth;
            local_z = slice_or_z % self.block.depth;
            allocation_base = try add(try multiply(self.block_slice_bytes, block_z), self.level_offset);
            if (self.block.depth == 1) swizzle_z = slice_or_z else swizzle_z = local_z;
        }
        const local = try self.block.byteOffset(
            if (self.block.family == .depth_64kb or self.block.family == .render_target_64kb)
                swizzle_x
            else
                swizzle_x % self.block.width,
            if (self.block.family == .depth_64kb or self.block.family == .render_target_64kb)
                swizzle_y
            else
                swizzle_y % self.block.height,
            swizzle_z,
            sample,
        );
        _ = blocks_per_slice;
        return add(try add(allocation_base, try multiply(block_index, self.block.bytes)), local);
    }

    pub fn stagingByteOffset(
        self: SubresourceLayout,
        x: u32,
        y: u32,
        slice_or_z: u32,
        sample: u32,
    ) Error!u64 {
        if (x >= self.width or y >= self.height or slice_or_z >= self.depth_or_layers or
            sample >= self.samples()) return Error.CoordinateOutOfRange;
        const texel = try add(
            try multiply(try add(try multiply(slice_or_z, self.height), y), self.width),
            x,
        );
        return multiply(try add(try multiply(texel, self.samples()), sample), self.block.bytes_per_element);
    }

    pub fn sourceRange(self: SubresourceLayout, address: u64) Error!ByteRange {
        return .{
            .address = address,
            .size = self.required_source_bytes,
            .end = try add(address, self.required_source_bytes),
        };
    }

    pub fn stage(
        self: SubresourceLayout,
        reader: shaders.MemoryReader,
        address: u64,
        destination: []u8,
    ) StageError!void {
        if (@as(u64, destination.len) < try self.stagingBytes()) return Error.DestinationTooSmall;
        _ = try self.sourceRange(address);
        const bytes = self.block.bytes_per_element;
        for (0..self.depth_or_layers) |slice_index| {
            const slice: u32 = @intCast(slice_index);
            for (0..self.height) |y_index| {
                const y: u32 = @intCast(y_index);
                for (0..self.width) |x_index| {
                    const x: u32 = @intCast(x_index);
                    for (0..self.samples()) |sample_index| {
                        const sample: u32 = @intCast(sample_index);
                        const src = try add(address, try self.sourceByteOffset(x, y, slice, sample));
                        const dst: usize = @intCast(try self.stagingByteOffset(x, y, slice, sample));
                        try reader.read(src, destination[dst..][0..bytes]);
                    }
                }
            }
        }
    }

    /// Ordinary 2D mips share Layout's block equation. Reuse its row copies
    /// and cached swizzle offsets instead of evaluating the general volume /
    /// MSAA address function millions of times for each full-resolution image.
    fn blockCopyLayout(self: SubresourceLayout) Error!?Layout {
        if (self.kind != .array_2d or self.in_tail or self.block.samples_log2 != 0) return null;
        const mode: resources.TileMode = switch (self.block.family) {
            .linear => .linear,
            .standard_256b => .standard_256b,
            .standard_4kb => .standard_4kb,
            .standard_64kb => .standard_64kb,
            .partially_resident => .partially_resident,
            .depth_64kb => .depth,
            .render_target_64kb => .render_target,
            else => return null,
        };
        var layout = try Layout.init(.{
            .tile_mode = mode,
            .width = self.width,
            .height = self.height,
            .layers = self.depth_or_layers,
            .first_slice = self.first_slice,
            .row_pitch_elements = self.padded_width,
        }, self.block.bytes_per_element);
        layout.source_base_offset = self.level_offset;
        layout.source_slice_bytes = self.source_layer_bytes;
        layout.required_source_bytes = self.required_source_bytes;
        return layout;
    }

    pub fn detile(self: SubresourceLayout, source: []const u8, destination: []u8) Error!void {
        if (@as(u64, source.len) < self.required_source_bytes) return Error.SourceTooSmall;
        if (@as(u64, destination.len) < try self.stagingBytes()) return Error.DestinationTooSmall;
        if (try self.blockCopyLayout()) |layout| return layout.detile(source, destination);
        const bytes = self.block.bytes_per_element;
        for (0..self.depth_or_layers) |slice_index| {
            const slice: u32 = @intCast(slice_index);
            for (0..self.height) |y_index| {
                const y: u32 = @intCast(y_index);
                for (0..self.width) |x_index| {
                    const x: u32 = @intCast(x_index);
                    for (0..self.samples()) |sample_index| {
                        const sample: u32 = @intCast(sample_index);
                        const src: usize = @intCast(try self.sourceByteOffset(x, y, slice, sample));
                        const dst: usize = @intCast(try self.stagingByteOffset(x, y, slice, sample));
                        @memcpy(destination[dst..][0..bytes], source[src..][0..bytes]);
                    }
                }
            }
        }
    }

    pub fn tile(self: SubresourceLayout, source: []const u8, destination: []u8) Error!void {
        if (@as(u64, source.len) < try self.stagingBytes()) return Error.SourceTooSmall;
        if (@as(u64, destination.len) < self.required_source_bytes) return Error.DestinationTooSmall;
        if (try self.blockCopyLayout()) |layout| return layout.tile(source, destination);
        const bytes = self.block.bytes_per_element;
        for (0..self.depth_or_layers) |slice_index| {
            const slice: u32 = @intCast(slice_index);
            for (0..self.height) |y_index| {
                const y: u32 = @intCast(y_index);
                for (0..self.width) |x_index| {
                    const x: u32 = @intCast(x_index);
                    for (0..self.samples()) |sample_index| {
                        const sample: u32 = @intCast(sample_index);
                        const src: usize = @intCast(try self.stagingByteOffset(x, y, slice, sample));
                        const dst: usize = @intCast(try self.sourceByteOffset(x, y, slice, sample));
                        @memcpy(destination[dst..][0..bytes], source[src..][0..bytes]);
                    }
                }
            }
        }
    }

    pub fn computePlan(
        self: SubresourceLayout,
        source_offset: u64,
        destination_offset: u64,
    ) Error!ComputeDetilePlan {
        const source_base = if (self.kind == .array_2d)
            try add(source_offset, try add(
                try multiply(self.source_layer_bytes, self.first_slice),
                self.level_offset,
            ))
        else
            try add(source_offset, self.level_offset);
        const blocks_per_row = self.padded_width / self.block.width;
        const blocks_per_slice = try multiply(
            blocks_per_row,
            self.padded_height / self.block.height,
        );
        return .{
            .key = .{
                .family = self.block.family,
                .bytes_per_element_log2 = std.math.log2_int(u8, self.block.bytes_per_element),
                .samples_log2 = self.block.samples_log2,
            },
            .params = .{
                .source_offset_lo = @truncate(source_base),
                .source_offset_hi = @truncate(source_base >> 32),
                .destination_offset_lo = @truncate(destination_offset),
                .destination_offset_hi = @truncate(destination_offset >> 32),
                .width = self.width,
                .height = self.height,
                .depth = self.depth_or_layers,
                .samples = self.samples(),
                .row_pitch_bytes = try u32FromU64(try multiply3(
                    self.width,
                    self.samples(),
                    self.block.bytes_per_element,
                )),
                .linear_slice_bytes = try u32FromU64(try multiply3(
                    try multiply(self.width, self.height),
                    self.samples(),
                    self.block.bytes_per_element,
                )),
                .block_width = self.block.width,
                .block_height = self.block.height,
                .block_depth = self.block.depth,
                .block_bytes = self.block.bytes,
                .blocks_per_row = blocks_per_row,
                .blocks_per_slice = try u32FromU64(blocks_per_slice),
                .source_slice_bytes = try u32FromU64(if (self.kind == .array_2d)
                    self.source_layer_bytes
                else
                    self.block_slice_bytes),
                .surface_z = self.first_slice,
                .tail_x = self.tail_x,
                .tail_y = self.tail_y,
                .flags = encodeComputeFlags(self),
            },
        };
    }
};

fn encodeComputeFlags(self: SubresourceLayout) u32 {
    const bpp_log2 = std.math.log2_int(u8, self.block.bytes_per_element);
    return (@as(u32, @intFromEnum(self.kind)) << 24) |
        (@as(u32, @intFromBool(self.in_tail)) << 16) |
        (@as(u32, @intFromEnum(self.block.family)) << 8) |
        (@as(u32, bpp_log2) << 4) |
        self.block.samples_log2;
}

pub fn computeFamily(params: ComputeDetileParams) BlockFamily {
    return @enumFromInt(@as(u8, @truncate(params.flags >> 8)));
}

pub fn computeElementBytes(params: ComputeDetileParams) u8 {
    return @as(u8, 1) << @intCast((params.flags >> 4) & 0xf);
}

/// Same byte address `sourceByteOffset` would return, expressed only with the
/// pointer-free constants a compute shader sees.
pub fn computeSourceOffset(params: ComputeDetileParams, x: u32, y: u32, z: u32, sample: u32) u64 {
    const family = computeFamily(params);
    const bpp = computeElementBytes(params);
    const samples_log2: u8 = @truncate(params.flags & 0xf);
    const kind: TextureKind = @enumFromInt(@as(u8, @truncate(params.flags >> 24)));
    const source_base = (@as(u64, params.source_offset_hi) << 32) | params.source_offset_lo;
    if (family == .linear) {
        const row = @as(u64, y) * @as(u64, params.blocks_per_row) * bpp;
        return source_base + @as(u64, z) * params.source_slice_bytes + row + @as(u64, x) * bpp;
    }

    const sx = x + params.tail_x;
    const sy = y + params.tail_y;
    const block_x = if (params.block_width == 0) 0 else sx / params.block_width;
    const block_y = if (params.block_height == 0) 0 else sy / params.block_height;
    const block_index = @as(u64, block_y) * params.blocks_per_row + block_x;
    var slice_term: u64 = 0;
    var swizzle_z: u32 = 0;
    if (kind == .array_2d) {
        slice_term = @as(u64, z) * params.source_slice_bytes;
        if (family == .depth_64kb or family == .render_target_64kb) {
            swizzle_z = params.surface_z + z;
        }
    } else {
        const block_z = if (params.block_depth == 0) 0 else z / params.block_depth;
        slice_term = @as(u64, block_z) * params.source_slice_bytes;
        swizzle_z = if (params.block_depth <= 1) z else z % params.block_depth;
    }
    const local_x = if (family == .depth_64kb or family == .render_target_64kb)
        sx
    else if (params.block_width == 0)
        0
    else
        sx % params.block_width;
    const local_y = if (family == .depth_64kb or family == .render_target_64kb)
        sy
    else if (params.block_height == 0)
        0
    else
        sy % params.block_height;
    const local = swizzleLocalOffset(family, local_x, local_y, swizzle_z, sample, bpp, samples_log2);
    return source_base + slice_term + block_index * params.block_bytes + local;
}

pub fn computeDestinationOffset(params: ComputeDetileParams, x: u32, y: u32, z: u32, sample: u32) u64 {
    const dest_base = (@as(u64, params.destination_offset_hi) << 32) | params.destination_offset_lo;
    const bpp = computeElementBytes(params);
    const texel = (@as(u64, z) * params.height + y) * params.width + x;
    return dest_base + (texel * params.samples + sample) * bpp;
}

pub fn computeDetileSupported(params: ComputeDetileParams) bool {
    if (params.samples != 1) return false;
    const bpp = computeElementBytes(params);
    if (bpp != 4 and bpp != 8 and bpp != 16) return false;
    const kind: TextureKind = @enumFromInt(@as(u8, @truncate(params.flags >> 24)));
    return switch (computeFamily(params)) {
        .linear, .standard_256b, .standard_4kb, .standard_64kb, .partially_resident => kind == .array_2d,
        .standard_4kb_3d, .standard_64kb_3d, .partially_resident_3d => kind == .volume_3d,
        else => false,
    };
}

fn swizzleLocalOffset(
    family: BlockFamily,
    x: u32,
    y: u32,
    z: u32,
    sample: u32,
    bpp: u8,
    samples_log2: u8,
) u32 {
    return switch (family) {
        .linear => 0,
        .standard_256b => standard4kOffset(x, y, bpp) & 0xff,
        .standard_4kb => standard4kOffset(x, y, bpp),
        .standard_4kb_3d => standard4k3dOffset(x, y, z, bpp),
        .standard_64kb => standard64kOffset(x, y, bpp),
        .standard_64kb_3d => standard64k3dOffset(x, y, z, bpp),
        .partially_resident => prt64kOffset(x, y, bpp),
        .partially_resident_3d => prt64k3dOffset(x, y, z, bpp),
        .depth_64kb => rbPlus64kOffset(.depth, x, y, z, sample, bpp, samples_log2),
        .render_target_64kb => rbPlus64kOffset(.render_target, x, y, z, sample, bpp, samples_log2),
    };
}

/// Shader specialization key. Runtime dimensions stay in `ComputeDetileParams`.
pub const ComputeDetileKey = extern struct {
    family: BlockFamily,
    bytes_per_element_log2: u8,
    samples_log2: u8,
    reserved: u8 = 0,
};

/// API-neutral, pointer-free constants consumed by the Vulkan compute detiler.
/// All fields are 32-bit so the struct has the same byte layout in Zig,
/// scalar-layout SPIR-V, and capture/replay diagnostics.
pub const ComputeDetileParams = extern struct {
    source_offset_lo: u32,
    source_offset_hi: u32,
    destination_offset_lo: u32,
    destination_offset_hi: u32,
    width: u32,
    height: u32,
    depth: u32,
    samples: u32,
    row_pitch_bytes: u32,
    linear_slice_bytes: u32,
    block_width: u32,
    block_height: u32,
    block_depth: u32,
    block_bytes: u32,
    blocks_per_row: u32,
    blocks_per_slice: u32,
    source_slice_bytes: u32,
    surface_z: u32,
    tail_x: u32,
    tail_y: u32,
    flags: u32,
};

pub const ComputeDetilePlan = struct {
    key: ComputeDetileKey,
    params: ComputeDetileParams,
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

fn thickBlockDimensions(family: BlockFamily, bytes: u8) Error![3]u32 {
    const index = std.math.log2_int(u8, bytes);
    return switch (family) {
        .standard_4kb_3d => ([_][3]u32{
            .{ 16, 16, 16 }, .{ 8, 16, 16 }, .{ 8, 16, 8 },
            .{ 8, 8, 8 },    .{ 4, 8, 8 },
        })[index],
        .standard_64kb_3d, .partially_resident_3d => ([_][3]u32{
            .{ 64, 32, 32 }, .{ 32, 32, 32 }, .{ 32, 32, 16 },
            .{ 32, 16, 16 }, .{ 16, 16, 16 },
        })[index],
        .depth_64kb, .render_target_64kb => blk: {
            const thin = try BlockLayout.init(
                if (family == .depth_64kb) .depth else .render_target,
                bytes,
            );
            break :blk .{ thin.width, thin.height, 1 };
        },
        else => return Error.UnsupportedVolume,
    };
}

fn msaa64kBlockDimensions(bytes: u8, samples_log2: u8) [2]u32 {
    const dimensions_log2 = [4][5][2]u5{
        .{ .{ 8, 8 }, .{ 8, 7 }, .{ 7, 7 }, .{ 7, 6 }, .{ 6, 6 } },
        .{ .{ 7, 8 }, .{ 7, 7 }, .{ 6, 7 }, .{ 6, 6 }, .{ 5, 6 } },
        .{ .{ 7, 7 }, .{ 7, 6 }, .{ 6, 6 }, .{ 6, 5 }, .{ 5, 5 } },
        .{ .{ 6, 7 }, .{ 6, 6 }, .{ 5, 6 }, .{ 5, 5 }, .{ 4, 5 } },
    };
    const value = dimensions_log2[samples_log2][std.math.log2_int(u8, bytes)];
    return .{ @as(u32, 1) << value[0], @as(u32, 1) << value[1] };
}

fn shiftCeil(value: u32, shift: u8) u32 {
    if (shift == 0) return value;
    return @max(@as(u32, 1), @as(u32, @intCast(
        (@as(u64, value) + (@as(u64, 1) << @intCast(shift)) - 1) >> @intCast(shift),
    )));
}

fn findFirstTail(
    width: u32,
    height: u32,
    levels: u8,
    tail_width: u32,
    tail_height: u32,
    maximum_tail_levels: u8,
) u8 {
    if (levels <= 1) return levels;
    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        if (shiftCeil(width, level) <= tail_width and
            shiftCeil(height, level) <= tail_height and
            levels - level <= maximum_tail_levels) return level;
    }
    return levels;
}

fn tailLocation(block: SwizzleBlock, index: u8) [2]u32 {
    const thick4 = block.family == .standard_4kb_3d;
    const thick64 = block.family == .standard_64kb_3d or
        block.family == .partially_resident_3d;
    if (thick4) {
        const tail_width = block.width;
        const tail_height = block.height / 2;
        return switch (index) {
            0 => .{ 0, tail_height },
            1 => .{ tail_width / 2, tail_height / 2 },
            2 => .{ tail_width / 2, 0 },
            3 => .{ 0, tail_height / 2 },
            4 => .{ 0, 0 },
            else => unreachable,
        };
    }
    if (thick64) {
        const tail_width = block.width / 2;
        const tail_height = block.height;
        return switch (index) {
            0 => .{ tail_width, 0 },
            1 => .{ 0, tail_height / 2 },
            2 => .{ tail_width / 2, 0 },
            3 => .{ tail_width / 4, tail_height / 4 },
            4 => .{ 0, 3 * tail_height / 8 },
            5 => .{ 0, tail_height / 4 },
            6 => .{ tail_width / 4, tail_height / 8 },
            7 => .{ tail_width / 4, 0 },
            8 => .{ 0, tail_height / 8 },
            9 => .{ 0, 0 },
            else => unreachable,
        };
    }
    const tail_width = block.width / 2;
    const tail_height = block.height;
    if (block.bytes == 4096) {
        return switch (index) {
            0 => .{ tail_width, 0 },
            1 => .{ tail_width / 2, tail_height / 2 },
            2 => .{ 0, 3 * tail_height / 4 },
            3 => .{ 0, tail_height / 2 },
            4 => .{ tail_width / 2, tail_height / 4 },
            5 => .{ tail_width / 2, 0 },
            6 => .{ 0, tail_height / 4 },
            7 => .{ 0, 0 },
            else => unreachable,
        };
    }
    return switch (index) {
        0 => .{ tail_width, 0 },
        1 => .{ 0, tail_height / 2 },
        2 => .{ tail_width / 2, 0 },
        3 => .{ 0, tail_height / 4 },
        4 => .{ tail_width / 4, 0 },
        5 => .{ tail_width / 8, tail_height / 8 },
        6 => .{ 0, 3 * tail_height / 16 },
        7 => .{ 0, tail_height / 8 },
        8 => .{ tail_width / 8, tail_height / 16 },
        9 => .{ tail_width / 8, 0 },
        10 => .{ 0, tail_height / 16 },
        11 => .{ 0, 0 },
        else => unreachable,
    };
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

fn standard4k3dOffset(x: u32, y: u32, z: u32, bytes: u8) u32 {
    return switch (bytes) {
        1 => (x & 0x003) ^ ((x << 4) & 0x040) ^ ((x << 6) & 0x200) ^
            ((y << 3) & 0x008) ^ ((y << 4) & 0x020) ^ ((y << 6) & 0x100) ^
            ((y << 8) & 0x800) ^ ((z << 2) & 0x004) ^ ((z << 3) & 0x010) ^
            ((z << 5) & 0x080) ^ ((z << 7) & 0x400),
        2 => ((x << 1) & 0x002) ^ ((x << 5) & 0x040) ^ ((x << 7) & 0x200) ^
            ((y << 3) & 0x008) ^ ((y << 4) & 0x020) ^ ((y << 6) & 0x100) ^
            ((y << 8) & 0x800) ^ ((z << 2) & 0x004) ^ ((z << 3) & 0x010) ^
            ((z << 5) & 0x080) ^ ((z << 7) & 0x400),
        4 => ((x << 2) & 0x004) ^ ((x << 5) & 0x040) ^ ((x << 7) & 0x200) ^
            ((y << 3) & 0x008) ^ ((y << 4) & 0x020) ^ ((y << 6) & 0x100) ^
            ((y << 8) & 0x800) ^ ((z << 4) & 0x010) ^ ((z << 6) & 0x080) ^
            ((z << 8) & 0x400),
        8 => ((x << 3) & 0x008) ^ ((x << 5) & 0x040) ^ ((x << 7) & 0x200) ^
            ((y << 5) & 0x020) ^ ((y << 7) & 0x100) ^ ((y << 9) & 0x800) ^
            ((z << 4) & 0x010) ^ ((z << 6) & 0x080) ^ ((z << 8) & 0x400),
        16 => ((x << 6) & 0x040) ^ ((x << 8) & 0x200) ^
            ((y << 5) & 0x020) ^ ((y << 7) & 0x100) ^ ((y << 9) & 0x800) ^
            ((z << 4) & 0x010) ^ ((z << 6) & 0x080) ^ ((z << 8) & 0x400),
        else => unreachable,
    };
}

fn standard64k3dOffset(x: u32, y: u32, z: u32, bytes: u8) u32 {
    var offset = standard4k3dOffset(x, y, z, bytes);
    const source = ([_][4]u5{
        .{ 4, 4, 4, 5 }, .{ 3, 4, 4, 4 }, .{ 3, 3, 4, 4 },
        .{ 3, 3, 3, 4 }, .{ 2, 3, 3, 3 },
    })[std.math.log2_int(u8, bytes)];
    offset ^= bit(x, source[0], 12) ^ bit(z, source[1], 13) ^
        bit(y, source[2], 14) ^ bit(x, source[3], 15);
    return offset;
}

fn prt64k3dOffset(x: u32, y: u32, z: u32, bytes: u8) u32 {
    var offset = standard64k3dOffset(x, y, z, bytes);
    const source = ([_][4]u5{
        .{ 4, 5, 4, 4 }, .{ 4, 4, 3, 4 }, .{ 4, 4, 3, 3 },
        .{ 3, 4, 3, 3 }, .{ 3, 3, 2, 3 },
    })[std.math.log2_int(u8, bytes)];
    offset ^= bit(y, source[0], 10) ^ bit(x, source[1], 10) ^
        bit(x, source[2], 11) ^ bit(z, source[3], 11);
    return offset;
}

// Decompressed from AMD AddrLib's GFX10_SW_64K_{R,Z}_X_{1,2,4,8}xaa
// RBPLUS pattern-info rows for Oberon's 16-pipe / 8-pixel-packer topology.
// Keeping the compact nibble indexes below avoids a 4 x 2 x 5 x 16 table while
// preserving the exact X/Y/Z/sample XOR equation used by CPU and compute paths.
const RbKind = enum { depth, render_target };

const AddressTerm = struct {
    x: u16 = 0,
    y: u16 = 0,
    z: u16 = 0,
    sample: u8 = 0,
};

fn addressTerm(x: u16, y: u16, z: u16, sample: u8) AddressTerm {
    return .{ .x = x, .y = y, .z = z, .sample = sample };
}

fn rbPlus64kOffset(
    kind: RbKind,
    x: u32,
    y: u32,
    z: u32,
    sample: u32,
    bytes: u8,
    samples_log2: u8,
) u32 {
    const bytes_log2 = std.math.log2_int(u8, bytes);
    var offset: u32 = if (kind == .render_target)
        renderMsaaLowOffset(x, y, bytes)
    else
        depthMsaaLowOffset(x, y, sample, bytes_log2, samples_log2);
    const indexes = rbPlusPatternIndexes(kind, samples_log2, bytes_log2);
    for (0..4) |index| {
        if (evaluateAddressTerm(nibble2Term(indexes[0], @intCast(index)), x, y, z, sample)) {
            offset |= @as(u32, 1) << @intCast(index + 8);
        }
        if (evaluateAddressTerm(nibble3Term(indexes[1], @intCast(index)), x, y, z, sample)) {
            offset |= @as(u32, 1) << @intCast(index + 12);
        }
    }
    return offset;
}

/// GFX10_CMASK_SW_PATTERN[15], expressed as the nibble rather than byte
/// offset. Coordinates are pixels, hence the first element bits are X3/Y3.
fn cmaskRbPlusNibbleOffset(x: u32, y: u32, slice: u32) u32 {
    var offset: u32 = 0;
    offset |= bit(x, 3, 0);
    offset |= bit(y, 3, 1);
    offset |= bit(x, 6, 2);
    offset |= bit(y, 6, 3);
    offset |= bit(x, 7, 4);
    offset |= bit(y, 7, 5);
    offset |= bit(x, 8, 6);
    offset |= bit(y, 8, 7);
    offset |= bit(x, 9, 8);
    if (evaluateAddressTerm(addressTerm(0x080, 0x090, 0, 0), x, y, slice, 0)) offset |= 1 << 9;
    if (evaluateAddressTerm(addressTerm(0x010, 0x010, 0x002, 0), x, y, slice, 0)) offset |= 1 << 10;
    if (evaluateAddressTerm(addressTerm(0x040, 0x020, 0x001, 0), x, y, slice, 0)) offset |= 1 << 11;
    if (evaluateAddressTerm(addressTerm(0x020, 0x040, 0, 0), x, y, slice, 0)) offset |= 1 << 12;
    std.debug.assert(offset < blockNibbles(CmaskLayout.block_bytes));
    return offset;
}

/// GFX10_HTILE_SW_PATTERN[21] after AddrLib converts its nibble address to a
/// byte address. Bits 0-1 are zero because every element is one dword.
fn htileRbPlusByteOffset(x: u32, y: u32, slice: u32) u32 {
    var offset: u32 = 0;
    offset |= bit(x, 3, 2);
    offset |= bit(y, 3, 3);
    offset |= bit(x, 6, 4);
    offset |= bit(y, 6, 5);
    offset |= bit(x, 7, 6);
    offset |= bit(y, 7, 7);
    if (evaluateAddressTerm(addressTerm(0x080, 0x090, 0, 0), x, y, slice, 0)) offset |= 1 << 8;
    if (evaluateAddressTerm(addressTerm(0x010, 0x010, 0x002, 0), x, y, slice, 0)) offset |= 1 << 9;
    if (evaluateAddressTerm(addressTerm(0x040, 0x020, 0x001, 0), x, y, slice, 0)) offset |= 1 << 10;
    if (evaluateAddressTerm(addressTerm(0x020, 0x040, 0, 0), x, y, slice, 0)) offset |= 1 << 11;
    offset |= bit(x, 8, 12);
    offset |= bit(y, 8, 13);
    offset |= bit(x, 9, 14);
    std.debug.assert(offset < HtileLayout.block_bytes);
    std.debug.assert(offset & 3 == 0);
    return offset;
}

fn blockNibbles(bytes: u32) u32 {
    return bytes * 2;
}

fn renderMsaaLowOffset(x: u32, y: u32, bytes: u8) u32 {
    return switch (bytes) {
        1 => (x & 0x0f) ^ ((y << 4) & 0xf0),
        2 => ((x << 1) & 0x0e) ^ ((y << 4) & 0x70) ^ ((x << 4) & 0x80),
        4 => ((x << 2) & 0x0c) ^ ((y << 4) & 0x30) ^
            ((x << 4) & 0x40) ^ ((y << 5) & 0x80),
        8 => ((x << 3) & 0x08) ^ ((y << 4) & 0x10) ^
            ((x << 4) & 0x60) ^ ((y << 6) & 0x80),
        16 => ((x << 4) & 0x10) ^ ((x << 5) & 0x40) ^
            ((y << 5) & 0x20) ^ ((y << 6) & 0x80),
        else => unreachable,
    };
}

fn depthMsaaLowOffset(x: u32, y: u32, sample: u32, bytes_log2: u8, samples_log2: u8) u32 {
    var offset: u32 = 0;
    var destination: u8 = bytes_log2;
    var source: u8 = 0;
    while (source < samples_log2) : (source += 1) {
        offset |= ((sample >> @intCast(source)) & 1) << @intCast(destination);
        destination += 1;
    }
    source = 0;
    while (destination < 8) : (destination += 1) {
        const coordinate = if (source & 1 == 0) x else y;
        offset |= ((coordinate >> @intCast(source / 2)) & 1) << @intCast(destination);
        source += 1;
    }
    return offset;
}

fn evaluateAddressTerm(term: AddressTerm, x: u32, y: u32, z: u32, sample: u32) bool {
    const parity = @popCount(x & term.x) + @popCount(y & term.y) +
        @popCount(z & term.z) + @popCount(sample & term.sample);
    return parity & 1 != 0;
}

fn rbPlusPatternIndexes(kind: RbKind, samples_log2: u8, bytes_log2: u8) [2]u16 {
    const b: usize = bytes_log2;
    return switch (kind) {
        .render_target => switch (samples_log2) {
            0 => .{ 307, ([_]u16{ 379, 389, 381, 382, 390 })[b] },
            1 => .{ ([_]u16{ 307, 307, 307, 307, 427 })[b], ([_]u16{ 700, 701, 702, 703, 390 })[b] },
            2 => .{ ([_]u16{ 307, 307, 307, 436, 437 })[b], ([_]u16{ 744, 751, 746, 703, 390 })[b] },
            3 => .{ ([_]u16{ 339, 339, 422, 452, 453 })[b], ([_]u16{ 781, 782, 746, 703, 390 })[b] },
            else => unreachable,
        },
        .depth => switch (samples_log2) {
            0 => .{ ([_]u16{ 306, 306, 306, 307, 307 })[b], ([_]u16{ 379, 389, 381, 382, 390 })[b] },
            1 => .{ ([_]u16{ 306, 306, 306, 307, 365 })[b], ([_]u16{ 380, 381, 434, 435, 435 })[b] },
            2 => .{ ([_]u16{ 306, 306, 306, 372, 373 })[b], ([_]u16{ 381, 462, 470, 470, 470 })[b] },
            3 => .{ ([_]u16{ 306, 306, 387, 373, 388 })[b], ([_]u16{ 434, 470, 490, 470, 470 })[b] },
            else => unreachable,
        },
    };
}

fn nibble2Term(pattern: u16, index: u2) AddressTerm {
    const terms: [4]AddressTerm = switch (pattern) {
        306 => .{
            addressTerm(0x080, 0x090, 0, 0),     addressTerm(0x010, 0x010, 0x002, 0),
            addressTerm(0x040, 0x020, 0x001, 0), addressTerm(0x020, 0x040, 0, 0),
        },
        307 => .{
            addressTerm(0x080, 0x090, 0, 0),     addressTerm(0x010, 0x010, 0x004, 0),
            addressTerm(0x040, 0x020, 0x002, 0), addressTerm(0x020, 0x040, 0x001, 0),
        },
        339 => .{
            addressTerm(0x080, 0x090, 0, 0),     addressTerm(0x010, 0x010, 0x002, 0),
            addressTerm(0x040, 0x020, 0x001, 0), addressTerm(0x020, 0x040, 0x004, 0),
        },
        365 => .{
            addressTerm(0x080, 0x090, 0, 0),     addressTerm(0x010, 0x010, 0x002, 0),
            addressTerm(0x040, 0x020, 0x001, 0), addressTerm(0x020, 0x042, 0, 0),
        },
        372 => .{
            addressTerm(0x080, 0x090, 0, 0), addressTerm(0x010, 0x010, 0x002, 0),
            addressTerm(0x040, 0x022, 0, 0), addressTerm(0x020, 0x040, 0x001, 0),
        },
        373 => .{
            addressTerm(0x080, 0x090, 0, 0), addressTerm(0x010, 0x010, 0x001, 0),
            addressTerm(0x040, 0x022, 0, 0), addressTerm(0x022, 0x040, 0, 0),
        },
        387 => .{
            addressTerm(0x080, 0x090, 0, 0),     addressTerm(0x010, 0x010, 0x002, 0),
            addressTerm(0x040, 0x020, 0x001, 0), addressTerm(0x020, 0x044, 0, 0),
        },
        388 => .{
            addressTerm(0x080, 0x090, 0, 0), addressTerm(0x010, 0x011, 0, 0),
            addressTerm(0x040, 0x022, 0, 0), addressTerm(0x022, 0x040, 0, 0),
        },
        422 => .{
            addressTerm(0x080, 0x090, 0, 0),     addressTerm(0x010, 0x010, 0x002, 0),
            addressTerm(0x040, 0x020, 0x001, 0), addressTerm(0x020, 0x040, 0, 0x04),
        },
        427 => .{
            addressTerm(0x080, 0x090, 0, 0),     addressTerm(0x010, 0x010, 0x002, 0),
            addressTerm(0x040, 0x020, 0x001, 0), addressTerm(0x020, 0x040, 0, 0x01),
        },
        436 => .{
            addressTerm(0x080, 0x090, 0, 0),    addressTerm(0x010, 0x010, 0x002, 0),
            addressTerm(0x040, 0x020, 0, 0x02), addressTerm(0x020, 0x040, 0x001, 0),
        },
        437 => .{
            addressTerm(0x080, 0x090, 0, 0),    addressTerm(0x010, 0x010, 0x001, 0),
            addressTerm(0x040, 0x020, 0, 0x02), addressTerm(0x020, 0x040, 0, 0x01),
        },
        452 => .{
            addressTerm(0x080, 0x090, 0, 0),    addressTerm(0x010, 0x010, 0x001, 0),
            addressTerm(0x040, 0x020, 0, 0x04), addressTerm(0x020, 0x040, 0, 0x02),
        },
        453 => .{
            addressTerm(0x080, 0x090, 0, 0),    addressTerm(0x010, 0x010, 0, 0x04),
            addressTerm(0x040, 0x020, 0, 0x02), addressTerm(0x020, 0x040, 0, 0x01),
        },
        else => unreachable,
    };
    return terms[index];
}

fn nibble3Term(pattern: u16, index: u2) AddressTerm {
    const terms: [4]AddressTerm = switch (pattern) {
        379 => .{ addressTerm(0x040, 0, 0, 0), addressTerm(0, 0x040, 0, 0), addressTerm(0x080, 0x100, 0, 0), addressTerm(0x100, 0x080, 0, 0) },
        380 => .{ addressTerm(0, 0x008, 0, 0), addressTerm(0x040, 0, 0, 0), addressTerm(0x100, 0x040, 0, 0), addressTerm(0x080, 0x080, 0, 0) },
        381 => .{ addressTerm(0x008, 0, 0, 0), addressTerm(0, 0x008, 0, 0), addressTerm(0x040, 0x080, 0, 0), addressTerm(0x080, 0x040, 0, 0) },
        382 => .{ addressTerm(0, 0x004, 0, 0), addressTerm(0x008, 0, 0, 0), addressTerm(0x080, 0x008, 0, 0), addressTerm(0x040, 0x040, 0, 0) },
        389 => .{ addressTerm(0, 0x008, 0, 0), addressTerm(0x040, 0, 0, 0), addressTerm(0x080, 0x080, 0, 0), addressTerm(0x100, 0x040, 0, 0) },
        390 => .{ addressTerm(0x004, 0, 0, 0), addressTerm(0, 0x004, 0, 0), addressTerm(0x040, 0x008, 0, 0), addressTerm(0x008, 0x040, 0, 0) },
        434 => .{ addressTerm(0x008, 0, 0, 0), addressTerm(0, 0x008, 0, 0), addressTerm(0x080, 0x040, 0, 0), addressTerm(0x040, 0x084, 0, 0) },
        435 => .{ addressTerm(0x004, 0, 0, 0), addressTerm(0x008, 0, 0, 0), addressTerm(0x080, 0x008, 0, 0), addressTerm(0x040, 0x044, 0, 0) },
        462 => .{ addressTerm(0x008, 0, 0, 0), addressTerm(0, 0x008, 0, 0), addressTerm(0x040, 0x080, 0, 0), addressTerm(0x080, 0x044, 0, 0) },
        470 => .{ addressTerm(0x008, 0, 0, 0), addressTerm(0, 0x008, 0, 0), addressTerm(0x084, 0x040, 0, 0), addressTerm(0x040, 0x084, 0, 0) },
        490 => .{ addressTerm(0x008, 0, 0, 0), addressTerm(0, 0x008, 0, 0), addressTerm(0x084, 0x040, 0, 0), addressTerm(0x040, 0x082, 0, 0) },
        700 => .{ addressTerm(0x040, 0, 0, 0), addressTerm(0, 0x040, 0, 0), addressTerm(0x100, 0x080, 0, 0), addressTerm(0x080, 0x100, 0, 0x01) },
        701 => .{ addressTerm(0, 0x008, 0, 0), addressTerm(0x040, 0, 0, 0), addressTerm(0x100, 0x040, 0, 0), addressTerm(0x080, 0x080, 0, 0x01) },
        702 => .{ addressTerm(0x008, 0, 0, 0), addressTerm(0, 0x008, 0, 0), addressTerm(0x080, 0x040, 0, 0), addressTerm(0x040, 0x080, 0, 0x01) },
        703 => .{ addressTerm(0, 0x004, 0, 0), addressTerm(0x008, 0, 0, 0), addressTerm(0x080, 0x008, 0, 0), addressTerm(0x040, 0x040, 0, 0x01) },
        744 => .{ addressTerm(0x040, 0, 0, 0), addressTerm(0, 0x040, 0, 0), addressTerm(0x080, 0x100, 0, 0x01), addressTerm(0x100, 0x080, 0, 0x02) },
        746 => .{ addressTerm(0x008, 0, 0, 0), addressTerm(0, 0x008, 0, 0), addressTerm(0x040, 0x080, 0, 0x01), addressTerm(0x080, 0x040, 0, 0x02) },
        751 => .{ addressTerm(0, 0x008, 0, 0), addressTerm(0x040, 0, 0, 0), addressTerm(0x080, 0x080, 0, 0x01), addressTerm(0x100, 0x040, 0, 0x02) },
        781 => .{ addressTerm(0, 0x040, 0, 0), addressTerm(0x040, 0, 0, 0x01), addressTerm(0x100, 0x080, 0, 0x02), addressTerm(0x080, 0x100, 0, 0x04) },
        782 => .{ addressTerm(0, 0x008, 0, 0), addressTerm(0x040, 0, 0, 0x01), addressTerm(0x100, 0x040, 0, 0x02), addressTerm(0x080, 0x080, 0, 0x04) },
        else => unreachable,
    };
    return terms[index];
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

fn alignForward64(value: u64, alignment: u64) Error!u64 {
    const biased = std.math.add(u64, value, alignment - 1) catch return Error.ArithmeticOverflow;
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

fn u32FromU64(value: u64) Error!u32 {
    if (value > std.math.maxInt(u32)) return Error.ArithmeticOverflow;
    return @intCast(value);
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
    const color_bytes = try BlockLayout.init(.render_target, 1);
    const depth = try BlockLayout.init(.depth, 4);
    try testing.expectEqual(@as(u32, 128), standard.width);
    try testing.expectEqual(@as(u32, 128), standard.height);
    try testing.expectEqual(@as(u32, 0x8000), try standard.byteOffset(64, 0));
    try testing.expectEqual(@as(u32, 0x8100), try prt.byteOffset(64, 0));
    try testing.expectEqual(@as(u32, 0x0800), try color.blockXor(0, 0, 1));
    try testing.expectEqual(@as(u32, 0x0008), try color_bytes.byteOffset(8, 0));
    try testing.expectEqual(@as(u32, 0x0600), try depth.blockXor(0, 0, 15));
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

test "optimized tile and detile preserve partial pitched blocks and slice offsets" {
    const layout = try Layout.init(.{
        .tile_mode = .standard_4kb,
        .width = 70,
        .height = 35,
        .layers = 2,
        .first_slice = 1,
        .row_pitch_elements = 72,
    }, 4);
    const linear = try testing.allocator.alloc(u8, @intCast(layout.staging_bytes));
    defer testing.allocator.free(linear);
    const tiled = try testing.allocator.alloc(u8, @intCast(layout.required_source_bytes));
    defer testing.allocator.free(tiled);
    const actual = try testing.allocator.alloc(u8, @intCast(layout.staging_bytes));
    defer testing.allocator.free(actual);
    for (linear, 0..) |*value, index| value.* = @truncate(index * 29 + 11);
    @memset(tiled, 0xa5);
    @memset(actual, 0);
    try layout.tile(linear, tiled);
    // The unused physical slice preceding first_slice remains untouched.
    try testing.expect(std.mem.allEqual(u8, tiled[0..@intCast(layout.source_slice_bytes)], 0xa5));
    try layout.detile(tiled, actual);
    try testing.expectEqualSlices(u8, linear, actual);
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

test "metadata surface decoding turns raw metadata bytes into RGBA pixels" {
    const metadata = MetadataSurface{ .metadata_address = 0x40, .dcc_address = 0x40, .dcc_enabled = true };
    // Place bytes at 0x40 so the memory reader succeeds.
    // metadata byte 0x20 represents fast clear (should map to green).
    const memory = TestMemory{ .base = 0x40, .bytes = &[_]u8{ 0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } };
    var dst = [_]u8{0} ** 8;
    // 2 pixels (8 bytes), will map to block_x=0, block_y=0, reading meta byte 0x20 for both pixels
    try metadata.stageRgba(memory.reader(), &dst, 2, 1);

    // Both pixels read DCC byte 0x20, which is fast clear (0, 255, 0, 255)
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 }, &dst);
}

test "Oberon CMASK layout uses AddrLib nibble swizzle and padded allocation" {
    const layout = try CmaskLayout.init(1920, 1080, 1, 0, 1920);
    try testing.expectEqual(@as(u32, 2048), layout.pitch);
    try testing.expectEqual(@as(u32, 1536), layout.padded_height);
    try testing.expectEqual(@as(u64, 24 * 1024), layout.slice_bytes);
    try testing.expectEqual(layout.slice_bytes, layout.required_bytes);

    try testing.expectEqual(CmaskLayout.Element{ .byte_offset = 0, .shift = 0 }, try layout.element(0, 0, 0));
    try testing.expectEqual(CmaskLayout.Element{ .byte_offset = 0, .shift = 4 }, try layout.element(8, 0, 0));
    try testing.expectEqual(CmaskLayout.Element{ .byte_offset = 1, .shift = 0 }, try layout.element(0, 8, 0));
    try testing.expectEqual(CmaskLayout.Element{ .byte_offset = 1026, .shift = 0 }, try layout.element(64, 0, 0));
    try testing.expectEqual(CmaskLayout.Element{ .byte_offset = 2052, .shift = 0 }, try layout.element(0, 64, 0));
    try testing.expectEqual(CmaskLayout.Element{ .byte_offset = 4096, .shift = 0 }, try layout.element(1024, 0, 0));
    try testing.expectEqual(CmaskLayout.Element{ .byte_offset = 8192, .shift = 0 }, try layout.element(0, 512, 0));
    try testing.expectError(Error.CoordinateOutOfRange, layout.element(1920, 0, 0));

    var target = std.mem.zeroes(resources.ColorTarget);
    target.width = 1920;
    target.height = 1080;
    target.pitch = 1920;
    target.tile_mode = .depth;
    target.cmask_slice_bytes = 24 * 1024;
    try testing.expectEqual(@as(u32, 2048), (try CmaskLayout.fromColorTarget(target)).pitch);
    target.samples_log2 = 3;
    target.fragments_log2 = 3;
    try testing.expectEqual(@as(u32, 2048), (try CmaskLayout.fromColorTarget(target)).pitch);
    target.samples_log2 = 0;
    target.fragments_log2 = 0;
    target.cmask_slice_bytes = 256;
    try testing.expectError(Error.UnsupportedMetadataLayout, CmaskLayout.fromColorTarget(target));
    target.cmask_slice_bytes = 24 * 1024;
    target.cmask_linear = true;
    try testing.expectError(Error.UnsupportedMetadataLayout, CmaskLayout.fromColorTarget(target));
}

test "one CMASK metadata block visits every nibble exactly once" {
    const layout = try CmaskLayout.init(CmaskLayout.block_width, CmaskLayout.block_height, 1, 0, 0);
    var occupied = [_]bool{false} ** (CmaskLayout.block_bytes * 2);
    var y: u32 = 0;
    while (y < CmaskLayout.block_height) : (y += 8) {
        var x: u32 = 0;
        while (x < CmaskLayout.block_width) : (x += 8) {
            const location = try layout.element(x, y, 0);
            const index: usize = @intCast(location.byte_offset * 2 + location.shift / 4);
            try testing.expect(!occupied[index]);
            occupied[index] = true;
        }
    }
    try testing.expect(std.mem.allEqual(bool, &occupied, true));
}

test "CMASK array slices preserve slice XOR and checked reads" {
    const layout = try CmaskLayout.init(64, 64, 2, 1, 64);
    try testing.expectEqual(@as(u64, 12 * 1024), layout.required_bytes);
    try testing.expectEqual(CmaskLayout.Element{ .byte_offset = 5 * 1024, .shift = 0 }, try layout.element(0, 0, 0));
    try testing.expectEqual(CmaskLayout.Element{ .byte_offset = 17 * 512, .shift = 0 }, try layout.element(0, 0, 1));

    var metadata = [_]u8{0xff} ** (12 * 1024);
    metadata[5 * 1024] = 0xa5;
    try testing.expectEqual(@as(u4, 5), try layout.value(&metadata, 0, 0, 0));
    try layout.setValue(&metadata, 0, 0, 0, 0xc);
    try testing.expectEqual(@as(u8, 0xac), metadata[5 * 1024]);
    try testing.expectError(Error.SourceTooSmall, layout.value(metadata[0..8], 0, 0, 0));
    try testing.expectError(Error.DestinationTooSmall, layout.setValue(metadata[0..8], 0, 0, 0, 0));
}

test "Oberon HTILE layout uses AddrLib dword swizzle and padded allocation" {
    const layout = try HtileLayout.init(1920, 1080, 1, 0, 1920);
    try testing.expectEqual(@as(u32, 2048), layout.pitch);
    try testing.expectEqual(@as(u32, 1536), layout.padded_height);
    try testing.expectEqual(@as(u64, 192 * 1024), layout.slice_bytes);
    try testing.expectEqual(layout.slice_bytes, layout.required_bytes);

    try testing.expectEqual(@as(u64, 0), try layout.wordOffset(0, 0, 0));
    try testing.expectEqual(@as(u64, 4), try layout.wordOffset(8, 0, 0));
    try testing.expectEqual(@as(u64, 8), try layout.wordOffset(0, 8, 0));
    try testing.expectEqual(@as(u64, 1040), try layout.wordOffset(64, 0, 0));
    try testing.expectEqual(@as(u64, 2080), try layout.wordOffset(0, 64, 0));
    try testing.expectEqual(@as(u64, 320), try layout.wordOffset(128, 0, 0));
    try testing.expectEqual(@as(u64, 32 * 1024), try layout.wordOffset(1024, 0, 0));
    try testing.expectEqual(@as(u64, 64 * 1024), try layout.wordOffset(0, 512, 0));
    try testing.expectError(Error.CoordinateOutOfRange, layout.wordOffset(1920, 0, 0));

    var target = std.mem.zeroes(resources.DepthTarget);
    target.width = 1920;
    target.height = 1080;
    target.format = 3;
    target.tile_mode = .depth;
    target.htile_address = 0x10000;
    target.htile_enabled = true;
    target.htile_pipe_aligned = true;
    target.samples_log2 = 3;
    try testing.expectEqual(@as(u64, 192 * 1024), (try HtileLayout.fromDepthTarget(target)).slice_bytes);
    target.htile_pipe_aligned = false;
    try testing.expectError(Error.UnsupportedMetadataLayout, HtileLayout.fromDepthTarget(target));
}

test "one HTILE metadata block visits every dword exactly once" {
    const layout = try HtileLayout.init(HtileLayout.block_width, HtileLayout.block_height, 1, 0, 0);
    var occupied = [_]bool{false} ** (HtileLayout.block_bytes / 4);
    var y: u32 = 0;
    while (y < HtileLayout.block_height) : (y += HtileLayout.region_height) {
        var x: u32 = 0;
        while (x < HtileLayout.block_width) : (x += HtileLayout.region_width) {
            const index: usize = @intCast((try layout.wordOffset(x, y, 0)) / 4);
            try testing.expect(!occupied[index]);
            occupied[index] = true;
        }
    }
    try testing.expect(std.mem.allEqual(bool, &occupied, true));
}

test "HTILE array slices preserve slice XOR and classify fast clears" {
    const layout = try HtileLayout.init(64, 64, 2, 1, 64);
    try testing.expectEqual(@as(u64, 96 * 1024), layout.required_bytes);
    try testing.expectEqual(@as(u64, 33 * 1024), try layout.wordOffset(0, 0, 0));
    try testing.expectEqual(@as(u64, 64 * 1024 + 512), try layout.wordOffset(0, 0, 1));

    var metadata = [_]u8{0xff} ** (96 * 1024);
    try layout.setWord(&metadata, 0, 0, 0, 0xffff_fff0);
    try testing.expectEqual(@as(u32, 0xffff_fff0), try layout.word(&metadata, 0, 0, 0));
    try testing.expectEqual(@as(?f32, 1.0), HtileLayout.fastClearDepth(0xffff_fff0, true));
    try testing.expectEqual(@as(?f32, 0.0), HtileLayout.fastClearDepth(0x0000_00f0, false));
    try testing.expect(HtileLayout.fastClearDepth(HtileLayout.expanded_depth, true) == null);
    try testing.expectError(Error.SourceTooSmall, layout.word(metadata[0..8], 0, 0, 0));
    try testing.expectError(Error.DestinationTooSmall, layout.setWord(metadata[0..8], 0, 0, 0, 0));
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

    var msaa_words = image_words;
    msaa_words[3] = (2 << 16) | (27 << 20) | (14 << 28);
    const msaa_image = try resources.decodeImageDescriptor(&msaa_words);
    try testing.expectEqual(@as(u8, 2), msaa_image.samplesLog2());
    try testing.expectEqual(@as(u8, 1), msaa_image.resourceMipLevels());
    const msaa_layout = try TextureLayout.fromImage(msaa_image);
    try testing.expectEqual(@as(u32, 4), (try msaa_layout.base()).samples());
    try testing.expectEqual(BlockFamily.render_target_64kb, msaa_layout.block.family);

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

test "mip chains place smallest records first and share exact tail blocks" {
    const micro = try TextureLayout.init(.{
        .tile_mode = .standard_256b,
        .width = 65,
        .height = 33,
        .mip_levels = 7,
    }, 4);
    const expected_offsets = [_]u64{ 0x1a00, 0x0b00, 0x0500, 0x0300, 0x0200, 0x0100, 0x0000 };
    const expected_sizes = [_]u64{ 0x2d00, 0x0f00, 0x0600, 0x0200, 0x0100, 0x0100, 0x0100 };
    try testing.expectEqual(@as(u64, 0x4700), micro.source_layer_bytes);
    for (expected_offsets, expected_sizes, 0..) |offset, size, level| {
        try testing.expectEqual(offset, micro.levels[level].offset);
        try testing.expectEqual(size, micro.levels[level].storage_bytes);
    }

    const macro = try TextureLayout.init(.{
        .tile_mode = .standard_64kb,
        .width = 256,
        .height = 256,
        .mip_levels = 9,
    }, 4);
    try testing.expectEqual(@as(u8, 2), macro.first_tail_level);
    try testing.expectEqual(@as(u64, 0x60000), macro.source_layer_bytes);
    try testing.expectEqual(@as(u64, 0x20000), macro.levels[0].offset);
    try testing.expectEqual(@as(u64, 0x10000), macro.levels[1].offset);
    try testing.expectEqual(@as(u64, 0), macro.levels[2].offset);
    try testing.expectEqual([2]u32{ 64, 0 }, .{ macro.levels[2].tail_x, macro.levels[2].tail_y });
    try testing.expectEqual([2]u32{ 0, 64 }, .{ macro.levels[3].tail_x, macro.levels[3].tail_y });
    try testing.expect(macro.levels[8].in_tail);

    var occupied = [_]bool{false} ** 65536;
    for (macro.first_tail_level..macro.mip_levels) |level_index| {
        const view = try macro.subresource(@intCast(level_index), 0, 1);
        for (0..view.height) |y_index| {
            for (0..view.width) |x_index| {
                const address: usize = @intCast(try view.sourceByteOffset(
                    @intCast(x_index),
                    @intCast(y_index),
                    0,
                    0,
                ));
                try testing.expect(address < occupied.len);
                try testing.expect(!occupied[address]);
                occupied[address] = true;
            }
        }
    }
}

test "linear 3D volumes use aligned rows and consecutive depth slices" {
    const volume = try TextureLayout.init(.{
        .tile_mode = .linear,
        .kind = .volume_3d,
        .width = 16,
        .height = 16,
        .depth_or_layers = 16,
        .row_pitch_elements = 16,
    }, 4);
    const base = try volume.base();
    try testing.expectEqual(BlockFamily.linear, base.block.family);
    try testing.expectEqual(@as(u32, 64), base.padded_width);
    try testing.expectEqual(@as(u64, 4096), base.source_layer_bytes);
    try testing.expectEqual(@as(u64, 65536), base.required_source_bytes);
    try testing.expectEqual(@as(u64, 0), try base.sourceByteOffset(0, 0, 0, 0));
    try testing.expectEqual(@as(u64, 4), try base.sourceByteOffset(1, 0, 0, 0));
    try testing.expectEqual(@as(u64, 256), try base.sourceByteOffset(0, 1, 0, 0));
    try testing.expectEqual(@as(u64, 4096), try base.sourceByteOffset(0, 0, 1, 0));
    try testing.expectEqual(@as(u64, 65340), try base.sourceByteOffset(15, 15, 15, 0));
}

test "thick 3D blocks and volume block slices match fixed GFX10 vectors" {
    const block4 = try SwizzleBlock.init(.standard_4kb, 4, true, 0);
    const block64 = try SwizzleBlock.init(.standard_64kb, 4, true, 0);
    const block_prt = try SwizzleBlock.init(.partially_resident, 4, true, 0);
    try testing.expectEqual([3]u32{ 8, 16, 8 }, .{ block4.width, block4.height, block4.depth });
    try testing.expectEqual(@as(u32, 0x001c), try block4.byteOffset(1, 1, 1, 0));
    try testing.expectEqual(@as(u32, 0x1000), try block64.byteOffset(8, 0, 0, 0));
    try testing.expectEqual(@as(u32, 0x1800), try block_prt.byteOffset(8, 0, 0, 0));

    const volume = try TextureLayout.init(.{
        .tile_mode = .standard_4kb,
        .kind = .volume_3d,
        .width = 32,
        .height = 32,
        .depth_or_layers = 16,
        .mip_levels = 6,
    }, 4);
    try testing.expectEqual(@as(u8, 2), volume.first_tail_level);
    try testing.expectEqual(@as(u64, 0xb000), volume.block_slice_bytes);
    try testing.expectEqual(@as(u64, 0x16000), volume.required_source_bytes);
    try testing.expectEqual(@as(u64, 0x3000), volume.levels[0].offset);
    try testing.expectEqual(@as(u64, 0x1000), volume.levels[1].offset);
    try testing.expectEqual([2]u32{ 0, 8 }, .{ volume.levels[2].tail_x, volume.levels[2].tail_y });

    const occupied = try testing.allocator.alloc(bool, @intCast(volume.required_source_bytes));
    defer testing.allocator.free(occupied);
    @memset(occupied, false);
    for (volume.first_tail_level..volume.mip_levels) |level_index| {
        const view = try volume.subresource(@intCast(level_index), 0, 1);
        for (0..view.depth_or_layers) |z_index| {
            for (0..view.height) |y_index| {
                for (0..view.width) |x_index| {
                    const address: usize = @intCast(try view.sourceByteOffset(
                        @intCast(x_index),
                        @intCast(y_index),
                        @intCast(z_index),
                        0,
                    ));
                    try testing.expect(!occupied[address]);
                    occupied[address] = true;
                }
            }
        }
    }
}

test "Oberon RB+ MSAA keeps color planes and depth samples exact" {
    const color4 = try SwizzleBlock.init(.render_target, 4, false, 2);
    const color8 = try SwizzleBlock.init(.render_target, 4, false, 3);
    const depth4 = try SwizzleBlock.init(.depth, 4, false, 2);
    try testing.expectEqual([2]u32{ 64, 64 }, .{ color4.width, color4.height });
    try testing.expectEqual(@as(u32, 0x0000), try color4.byteOffset(0, 0, 0, 0));
    try testing.expectEqual(@as(u32, 0x4000), try color4.byteOffset(0, 0, 0, 1));
    try testing.expectEqual(@as(u32, 0x8000), try color4.byteOffset(0, 0, 0, 2));
    try testing.expectEqual(@as(u32, 0xc000), try color4.byteOffset(0, 0, 0, 3));
    try testing.expectEqual(@as(u32, 0xc800), try color8.byteOffset(0, 0, 0, 7));
    try testing.expectEqual(@as(u32, 0x0004), try depth4.byteOffset(0, 0, 0, 1));
    try testing.expectEqual(@as(u32, 0x0008), try depth4.byteOffset(0, 0, 0, 2));
    try testing.expectEqual(@as(u32, 0x000c), try depth4.byteOffset(0, 0, 0, 3));

    const color_vectors = [3][5]u32{
        .{ 0x8a9d, 0x9a9a, 0xba54, 0xea58, 0xdc30 },
        .{ 0xca9d, 0xda9a, 0xfa54, 0xec58, 0xde30 },
        .{ 0xec9d, 0xfc9a, 0xfc54, 0xee58, 0xde30 },
    };
    const depth_vectors = [3][4]u32{
        .{ 0x14a7, 0x344e, 0x349c, 0x7a38 },
        .{ 0x344f, 0x349e, 0x743c, 0x7878 },
        .{ 0x349f, 0x743e, 0x747c, 0x72f8 },
    };
    const bytes_values = [_]u8{ 1, 2, 4, 8, 16 };
    for (1..4) |samples_index| {
        const samples_log2: u8 = @intCast(samples_index);
        const sample = (@as(u32, 1) << @intCast(samples_log2)) - 1;
        for (bytes_values, 0..) |bytes, bytes_index| {
            const color = try SwizzleBlock.init(.render_target, bytes, false, samples_log2);
            try testing.expectEqual(
                color_vectors[samples_index - 1][bytes_index],
                try color.byteOffset(13, 9, 5, sample),
            );
            if (bytes == 16) continue;
            const depth = try SwizzleBlock.init(.depth, bytes, false, samples_log2);
            try testing.expectEqual(
                depth_vectors[samples_index - 1][bytes_index],
                try depth.byteOffset(13, 9, 5, sample),
            );
        }
    }
}

test "RB+ single-sample pattern decoder preserves the established PS5 vectors" {
    for ([_]resources.TileMode{ .render_target, .depth }) |mode| {
        for ([_]u8{ 1, 2, 4, 8 }) |bytes| {
            const legacy = try BlockLayout.init(mode, bytes);
            const block = try SwizzleBlock.init(mode, bytes, false, 0);
            for (0..block.height) |y_index| {
                for (0..block.width) |x_index| {
                    const x: u32 = @intCast(x_index);
                    const y: u32 = @intCast(y_index);
                    try testing.expectEqual(
                        try legacy.byteOffset(x, y),
                        try block.byteOffset(x, y, 0, 0),
                    );
                }
            }
        }
    }
}

test "3D and MSAA equations visit every element in one block exactly once" {
    const bytes_values = [_]u8{ 1, 2, 4, 8, 16 };
    const thick_modes = [_]resources.TileMode{ .standard_4kb, .standard_64kb, .partially_resident };
    var visited = [_]bool{false} ** 65536;
    for (thick_modes) |mode| {
        for (bytes_values) |bytes| {
            const block = try SwizzleBlock.init(mode, bytes, true, 0);
            @memset(&visited, false);
            for (0..block.depth) |z_index| {
                for (0..block.height) |y_index| {
                    for (0..block.width) |x_index| {
                        const offset = try block.byteOffset(
                            @intCast(x_index),
                            @intCast(y_index),
                            @intCast(z_index),
                            0,
                        );
                        try testing.expect(!visited[offset]);
                        visited[offset] = true;
                    }
                }
            }
        }
    }
    for ([_]resources.TileMode{ .render_target, .depth }) |mode| {
        for ([_]u8{ 1, 2, 4, 8 }) |bytes| {
            for (1..4) |samples_index| {
                const samples_log2: u8 = @intCast(samples_index);
                const block = try SwizzleBlock.init(mode, bytes, false, samples_log2);
                @memset(&visited, false);
                for (0..block.height) |y_index| {
                    for (0..block.width) |x_index| {
                        for (0..@as(u32, 1) << @intCast(samples_log2)) |sample_index| {
                            const offset = try block.byteOffset(
                                @intCast(x_index),
                                @intCast(y_index),
                                0,
                                @intCast(sample_index),
                            );
                            try testing.expect(!visited[offset]);
                            visited[offset] = true;
                        }
                    }
                }
            }
        }
    }
}

test "a sampled mip view detiles each requested level from one allocation" {
    const layout = try TextureLayout.init(.{
        .tile_mode = .standard_64kb,
        .width = 64,
        .height = 64,
        .mip_levels = 6,
    }, 4);
    try testing.expectEqual(@as(u8, 6), layout.mip_levels);
    const base = try layout.subresource(0, 0, 1);
    const mip = try layout.subresource(2, 0, 1);
    try testing.expectEqual(@as(u32, 64), base.width);
    try testing.expectEqual(@as(u32, 16), mip.width);
    try testing.expect(base.width > mip.width);
}

test "mip tail volume and MSAA subresources share one CPU address contract" {
    const descriptions = [_]Texture{
        .{ .tile_mode = .standard_64kb, .width = 129, .height = 73, .depth_or_layers = 2, .first_slice = 1, .mip_levels = 8 },
        .{ .tile_mode = .standard_4kb, .kind = .volume_3d, .width = 17, .height = 11, .depth_or_layers = 9, .mip_levels = 5 },
        .{ .tile_mode = .render_target, .width = 37, .height = 29, .samples_log2 = 2 },
        .{ .tile_mode = .depth, .width = 31, .height = 23, .samples_log2 = 3 },
    };
    for (descriptions) |description| {
        const layout = try TextureLayout.init(description, 4);
        const tiled = try testing.allocator.alloc(u8, @intCast(layout.required_source_bytes));
        defer testing.allocator.free(tiled);
        @memset(tiled, 0xa5);
        for (0..layout.mip_levels) |level_index| {
            const view = try layout.subresource(
                @intCast(level_index),
                0,
                if (description.kind == .array_2d) layout.layers else 1,
            );
            const staging_bytes: usize = @intCast(try view.stagingBytes());
            const expected = try testing.allocator.alloc(u8, staging_bytes);
            defer testing.allocator.free(expected);
            const actual = try testing.allocator.alloc(u8, staging_bytes);
            defer testing.allocator.free(actual);
            for (expected, 0..) |*value, index| value.* = @truncate(index * 29 + level_index * 17);
            @memset(actual, 0);
            try view.tile(expected, tiled);
            try view.detile(tiled, actual);
            try testing.expectEqualSlices(u8, expected, actual);
            @memset(actual, 0);
            const memory = TestMemory{ .base = 0x4000_0000, .bytes = tiled };
            try view.stage(memory.reader(), memory.base, actual);
            try testing.expectEqualSlices(u8, expected, actual);
        }
    }
}

test "compute detile constants are compact stable POD derived from the CPU view" {
    const layout = try TextureLayout.init(.{
        .tile_mode = .standard_64kb,
        .width = 256,
        .height = 128,
        .depth_or_layers = 3,
        .first_slice = 2,
        .mip_levels = 8,
    }, 4);
    const view = try layout.subresource(3, 1, 2);
    const plan = try view.computePlan(0x1_2345_6000, 0x2_0000_1000);
    try testing.expectEqual(@as(usize, 4), @sizeOf(ComputeDetileKey));
    try testing.expectEqual(@as(usize, 84), @sizeOf(ComputeDetileParams));
    try testing.expectEqual(BlockFamily.standard_64kb, plan.key.family);
    try testing.expectEqual(@as(u8, 2), plan.key.bytes_per_element_log2);
    try testing.expectEqual(view.width, plan.params.width);
    try testing.expectEqual(view.tail_x, plan.params.tail_x);
    try testing.expectEqual(@as(u32, 3), plan.params.surface_z);
    const encoded_source = (@as(u64, plan.params.source_offset_hi) << 32) | plan.params.source_offset_lo;
    try testing.expectEqual(
        try add(@as(u64, 0x1_2345_6000), try add(try multiply(layout.source_layer_bytes, 3), view.level_offset)),
        encoded_source,
    );
    try testing.expect(computeDetileSupported(plan.params));
    const relative = try view.computePlan(0, 0);
    try testing.expectEqual(try view.sourceByteOffset(3, 5, 1, 0), computeSourceOffset(relative.params, 3, 5, 1, 0));
    try testing.expectEqual(try view.stagingByteOffset(3, 5, 1, 0), computeDestinationOffset(relative.params, 3, 5, 1, 0));
}

test "2D block copies match scalar addressing across mips slices and padding" {
    for ([_]resources.TileMode{ .linear, .standard_256b, .standard_4kb, .standard_64kb, .partially_resident, .depth, .render_target }) |mode| {
        for ([_]u8{ 1, 2, 4, 8, 16 }) |element_bytes| {
            if (mode == .depth and element_bytes > 8) continue;
            const texture = try TextureLayout.init(.{
                .tile_mode = mode,
                .width = 273,
                .height = 139,
                .depth_or_layers = 2,
                .first_slice = 1,
                .mip_levels = 3,
            }, element_bytes);
            const allocation = try testing.allocator.alloc(u8, @intCast(texture.required_source_bytes));
            defer testing.allocator.free(allocation);
            for (allocation, 0..) |*byte, index| byte.* = @truncate(index ^ (index >> 8) ^ (index >> 16));
            for (0..texture.mip_levels) |level| {
                const view = try texture.subresource(@intCast(level), 0, texture.layers);
                const linear = try testing.allocator.alloc(u8, @intCast(try view.stagingBytes()));
                defer testing.allocator.free(linear);
                const expected = try testing.allocator.alloc(u8, linear.len);
                defer testing.allocator.free(expected);
                const memory = TestMemory{ .base = 0x4000_0000, .bytes = allocation };
                // stage uses the independent per-coordinate reference path.
                try view.stage(memory.reader(), memory.base, expected);
                try view.detile(allocation, linear);
                try testing.expectEqualSlices(u8, expected, linear);
                const tiled = try testing.allocator.dupe(u8, allocation);
                defer testing.allocator.free(tiled);
                try view.tile(linear, tiled);
                // Include padding and the unselected mips / array slices.
                try testing.expectEqualSlices(u8, allocation, tiled);
            }
        }
    }
}

test "fromImage stages a non-zero 2D mip from the allocation origin" {
    const image = resources.ImageDescriptor{
        .address = 0x2000_0000,
        .width = 256,
        .height = 256,
        .depth_or_layers = 1,
        .pitch = 256,
        .unified_format = 56,
        .tile_mode = .linear,
        .image_type = .color_2d,
        .dst_select = .{ 4, 5, 6, 7 },
        .base_level = 1,
        .last_level = 1,
        .base_array = 0,
        .array_pitch = 0,
        .max_mip = 8,
        .min_lod = 0,
        .min_lod_warning = 0,
        .bc_swizzle = 0,
        .metadata_address = 0,
        .dcc_enabled = false,
        .cmask_fast_clear = false,
        .fmask_compression = false,
        .cmask_address = 0,
        .fmask_address = 0,
        .dcc_address = 0,
        .descriptor_flags = 0,
        .extended = true,
    };
    const layout = try Layout.fromImage(image);
    try testing.expectEqual(@as(u32, 128), layout.width);
    try testing.expectEqual(@as(u32, 128), layout.height);
    try testing.expect(layout.source_base_offset != 0);
    const texture = try TextureLayout.fromImage(image);
    const view = try texture.subresource(1, 0, 1);
    try testing.expectEqual(view.level_offset, layout.source_base_offset);
    try testing.expectEqual(try view.sourceByteOffset(3, 5, 0, 0), try layout.sourceByteOffset(3, 5, 0));
}

test "compute detile admits 8-byte 2D and 4-byte 3D standard families" {
    const wide = try TextureLayout.init(.{
        .tile_mode = .standard_64kb,
        .width = 64,
        .height = 64,
    }, 8);
    try testing.expect(computeDetileSupported((try (try wide.base()).computePlan(0, 0)).params));

    const volume = try TextureLayout.init(.{
        .tile_mode = .standard_64kb,
        .kind = .volume_3d,
        .width = 32,
        .height = 32,
        .depth_or_layers = 16,
    }, 4);
    const volume_plan = try (try volume.base()).computePlan(0, 0);
    try testing.expect(computeDetileSupported(volume_plan.params));
    try testing.expectEqual(
        try (try volume.base()).sourceByteOffset(3, 5, 2, 0),
        computeSourceOffset(volume_plan.params, 3, 5, 2, 0),
    );
}

test "compute source offsets match CPU detile for standard 64 KiB textures" {
    const layout = try TextureLayout.init(.{
        .tile_mode = .standard_64kb,
        .width = 64,
        .height = 64,
        .mip_levels = 4,
    }, 4);
    const view = try layout.subresource(1, 0, 1);
    const plan = try view.computePlan(0, 0);
    var y: u32 = 0;
    while (y < view.height) : (y += 5) {
        var x: u32 = 0;
        while (x < view.width) : (x += 7) {
            try testing.expectEqual(
                try view.sourceByteOffset(x, y, 0, 0),
                computeSourceOffset(plan.params, x, y, 0, 0),
            );
        }
    }
}
