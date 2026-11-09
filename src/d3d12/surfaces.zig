// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest surface staging uses the shared GFX10 address equations. D3D12 owns
//! the native texture layout; upload/readback buffers carry tight color/depth texels.
const std = @import("std");
const gpu = @import("gpu");
const staging = @import("staging.zig");
const surface_cache = @import("surface_cache.zig");

pub fn colorLayout(target: gpu.resources.ColorTarget) !gpu.SurfaceLayout {
    _ = try colorFormat(target);
    if (target.component_swap > 1 or
        target.samples_log2 != 0 or target.fragments_log2 != 0 or target.mip_level != 0 or
        target.maximum_mip != 0 or target.resource_type == 2 or target.depth > 1 or
        target.base_array_slice != 0 or target.last_array_slice != 0 or
        (target.dcc_enabled and target.dcc_address == 0) or target.cmask_fast_clear or target.fmask_compression or
        target.force_destination_alpha_one) return error.UnsupportedRenderTargetLayout;
    const layout = try gpu.SurfaceLayout.fromColorTarget(target);
    try validate(layout, target.address);
    return layout;
}

/// Native render-target formats; staging preserves the encoded bits. Byte-per-
/// channel UNORM keeps every fast clear exact; the wider packed and half-float
/// layouts materialize only the format-independent codes during staging, so
/// they are admitted here and may still be rejected per key.
pub fn colorFormat(target: gpu.resources.ColorTarget) !u32 {
    const format: u32 = switch (target.format) {
        1 => if (target.number_type == 0 and target.component_swap == 0) 61 else return error.UnsupportedRenderTargetLayout, // R8_UNORM
        10 => switch (target.number_type) {
            0 => 28, // R8G8B8A8_UNORM
            1 => 31, // R8G8B8A8_SNORM
            else => return error.UnsupportedRenderTargetLayout,
        },
        5 => if (target.number_type == 7 and target.component_swap == 0) 34 else return error.UnsupportedRenderTargetLayout, // R16G16_FLOAT
        12 => if (target.number_type == 7 and target.component_swap == 0) 10 else return error.UnsupportedRenderTargetLayout, // R16G16B16A16_FLOAT
        9 => if (target.number_type == 0 and target.component_swap == 0) 24 else return error.UnsupportedRenderTargetLayout, // R10G10B10A2_UNORM
        6 => if (target.number_type == 7 and target.component_swap == 0) 26 else return error.UnsupportedRenderTargetLayout, // R11G11B10_FLOAT
        // DATA_FORMAT_32_32_32_32 + NUMBER_FORMAT_FLOAT. Tiny exposure and
        // luminance targets feed the final tonemap; the native RGBA32F texel
        // keeps their HDR values exact.
        14 => if (target.number_type == 7 and target.component_swap == 0) 2 else return error.UnsupportedRenderTargetLayout, // R32G32B32A32_FLOAT
        else => return error.UnsupportedRenderTargetLayout,
    };
    // SNORM has no exact fixed clear, so its metadata stays out of this path.
    return switch (format) {
        28, 61, 24, 26, 10 => format,
        else => if (target.dcc_enabled) error.UnsupportedRenderTargetLayout else format,
    };
}

/// DCC keys accompany the colour layout; null for an uncompressed target.
pub fn colorDcc(target: gpu.resources.ColorTarget) ?Dcc {
    if (!target.dcc_enabled) return null;
    // Only the formats colorFormat admits reach here; their tiled texel width
    // is what a fast-clear must repeat.
    const bytes_per_texel: u8 = switch (target.format) {
        1 => 1,
        12 => 8,
        14 => 16,
        else => 4,
    };
    return .{
        .address = target.dcc_address,
        .clear_word = target.clear_words[0],
        .format = target.format,
        .bytes_per_texel = bytes_per_texel,
        .r8 = target.format == 1,
    };
}

pub fn depthLayout(target: gpu.resources.DepthTarget, width: u32, height: u32, writable: bool) !gpu.SurfaceLayout {
    if ((target.format != 1 and target.format != 3) or target.width != width or target.height != height or
        target.samples_log2 != 0 or target.maximum_mip != 0 or target.mip_level != 0 or
        target.base_array_slice != 0 or target.last_array_slice != 0)
        return error.UnsupportedDepthLayout;
    if (target.read_address == 0 or (writable and target.write_address != target.read_address)) return error.SeparateDepthAddressesNotImplemented;
    if (target.htile_enabled) _ = try Htile.layoutFor(target);
    const layout = try gpu.SurfaceLayout.fromDepthTarget(target);
    try validate(layout, target.read_address);
    return layout;
}

pub fn stencilLayout(target: gpu.resources.DepthTarget, width: u32, height: u32, writable: bool) !gpu.SurfaceLayout {
    if (target.stencil_format != 1 or target.width != width or target.height != height or target.samples_log2 != 0 or
        target.maximum_mip != 0 or target.mip_level != 0 or target.base_array_slice != 0 or target.last_array_slice != 0)
        return error.UnsupportedStencilLayout;
    if (target.stencil_read_address == 0 or (writable and target.stencil_read_address != target.stencil_write_address))
        return error.SeparateStencilAddressesNotImplemented;
    const layout = try gpu.SurfaceLayout.init(.{
        .tile_mode = target.stencil_tile_mode,
        .width = width,
        .height = height,
        .row_pitch_elements = if (target.stencil_tile_mode.isLinear()) std.mem.alignForward(u32, width, 256) else width,
    }, 1);
    try validate(layout, target.stencil_read_address);
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
        0x8100_0000_2200_0000 => false, // RGB10A2 SDR.
        0x8100_0000_0000_0000 => true, // BGR10A2 SDR.
        else => error.UnsupportedScanoutFormat,
    };
}

pub fn convertScanout(pixels: []u8, pixel_format: u64) !void {
    const swap = try scanoutSwapsRedBlue(pixel_format);
    if (pixels.len % 4 != 0) return error.InvalidPixelSize;
    const packed_sdr = pixel_format >> 56 == 0x81;
    var offset: usize = 0;
    while (offset < pixels.len) : (offset += 4) {
        if (packed_sdr) {
            const word = std.mem.readInt(u32, pixels[offset..][0..4], .little);
            pixels[offset] = @intCast(((word & 1023) * 255 + 511) / 1023);
            pixels[offset + 1] = @intCast((((word >> 10) & 1023) * 255 + 511) / 1023);
            pixels[offset + 2] = @intCast((((word >> 20) & 1023) * 255 + 511) / 1023);
            pixels[offset + 3] = @intCast((word >> 30) * 85);
        }
        if (swap) std.mem.swap(u8, &pixels[offset], &pixels[offset + 2]);
    }
}

test "VideoOut RGBA8, BGRA8 and packed SDR select channels without accepting PQ HDR" {
    try std.testing.expect(!try scanoutSwapsRedBlue(0x8000_0000_2200_0000));
    try std.testing.expect(try scanoutSwapsRedBlue(0x8000_0000_0000_0000));
    try std.testing.expect(!try scanoutSwapsRedBlue(0));
    try std.testing.expectError(error.UnsupportedScanoutFormat, scanoutSwapsRedBlue(0x8100_0704_2200_0000));
    for (0..1024) |code| {
        const r: u32 = @intCast(code);
        const g = (r * 7) % 1024;
        const b = 1023 - r;
        const a = r % 4;
        const packed_word = r | (g << 10) | (b << 20) | (a << 30);
        for ([_]bool{ false, true }) |swap| {
            var bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, packed_word));
            try convertScanout(&bytes, if (swap) 0x8100_0000_0000_0000 else 0x8100_0000_2200_0000);
            const expected = [_]u8{
                @intFromFloat(@round(@as(f64, @floatFromInt(if (swap) b else r)) * 255.0 / 1023.0)),
                @intFromFloat(@round(@as(f64, @floatFromInt(g)) * 255.0 / 1023.0)),
                @intFromFloat(@round(@as(f64, @floatFromInt(if (swap) r else b)) * 255.0 / 1023.0)),
                @intCast(a * 85),
            };
            try std.testing.expectEqualSlices(u8, &expected, &bytes);
        }
    }
}

fn validate(layout: gpu.SurfaceLayout, address: u64) !void {
    if (layout.width == 0 or layout.height == 0 or layout.width > 16384 or layout.height > 16384 or
        layout.layers != 1 or (layout.block.bytes_per_element != 16 and layout.block.bytes_per_element != 8 and layout.block.bytes_per_element != 4 and layout.block.bytes_per_element != 2 and layout.block.bytes_per_element != 1) or
        layout.required_source_bytes > 256 * 1024 * 1024 or layout.staging_bytes > 256 * 1024 * 1024)
        return error.SurfaceBudgetExceeded;
    _ = try layout.sourceRange(address);
}

/// GFX10 DCC metadata for a colour surface: one key byte per 256-byte block of
/// the tiled base allocation. 0xFF means the block holds plain texels; a
/// fast-clear code means every texel of the block reads as one clear value
/// regardless of the bytes underneath. Other codes describe genuinely
/// compressed data, which this path does not decode.
pub const Dcc = struct {
    address: u64,
    /// Render targets carry CB_COLOR*_CLEAR_WORD0; sampled views do not, so
    /// code 0x20 cannot be resolved for them.
    clear_word: ?u32,
    /// Guest unified format. The fixed all-zeros/all-ones clears only map
    /// directly onto texel bytes for the byte-per-channel UNORM layouts.
    format: u16 = 10,
    /// Tiled texel width a fast clear repeats.
    bytes_per_texel: u8 = 4,
    r8: bool = false,

    pub const block_bytes = 256;

    /// How many key bytes cover `len` backing bytes. Division first so a
    /// guest-sized length cannot overflow the addition a naive
    /// `(len + block - 1) / block` ceiling needs.
    pub fn blockCount(len: usize) usize {
        return len / block_bytes + @intFromBool(len % block_bytes != 0);
    }

    /// Resolves a fast-clear code into the texel bytes it implies. Null means
    /// this surface layout cannot express that clear exactly, so the caller
    /// must reject the draw instead of writing wrong texels.
    fn texel(self: Dcc, code: u8) ?[8]u8 {
        var value: [8]u8 = @splat(0);
        if (self.r8 and (code == 0 or code == 0x40 or code == 0x80 or code == 0xc0)) {
            value[0] = if (code & 0x40 != 0) 255 else 0;
            return value;
        }
        return switch (code) {
            // Clearing to all zeros is exact for every layout.
            0x00 => value,
            // The fixed clears name channel all-zeros/all-ones, which only the
            // byte-per-channel UNORM layouts encode bit-exactly.
            0x40, 0x80, 0xc0 => if (self.format == 1 or self.format == 10) switch (code) {
                0x40 => .{ 0, 0, 0, 255, 0, 0, 0, 0 },
                0x80 => .{ 255, 255, 255, 0, 0, 0, 0, 0 },
                else => .{ 255, 255, 255, 255, 0, 0, 0, 0 },
            } else null,
            // CB_COLOR*_CLEAR_WORD0 holds the texel in the surface encoding,
            // but a wider-than-word texel needs clear words this path lacks.
            0x20 => if (self.bytes_per_texel == 4) blk: {
                const word = self.clear_word orelse break :blk null;
                var cleared: [8]u8 = @splat(0);
                @memcpy(cleared[0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, word)));
                break :blk cleared;
            } else null,
            else => null,
        };
    }

    /// Rewrites every fast-cleared block of `backing` with its clear value.
    /// Comp-to-single (0x10) blocks keep their representative first texel.
    pub fn expand(self: Dcc, memory: anytype, backing: []u8, keys: []u8) !void {
        if (keys.len != blockCount(backing.len)) return error.InvalidDccKeyRange;
        if (!memory.read(memory.context, self.address, keys)) return error.GuestReadFailed;
        if (self.r8 and keys.len != 0 and !std.mem.allEqual(u8, keys, keys[0])) return error.CompressedColorTargetNotImplemented;
        const texel_bytes: usize = self.bytes_per_texel;
        for (keys, 0..) |code, block| {
            if (code == 0xff) continue;
            const bytes = backing[block * block_bytes .. @min(backing.len, (block + 1) * block_bytes)];
            var value: [8]u8 = undefined;
            if (code == 0x10) {
                if (bytes.len < texel_bytes) return error.CompressedColorTargetNotImplemented;
                @memcpy(value[0..texel_bytes], bytes[0..texel_bytes]);
            } else value = self.texel(code) orelse return error.CompressedColorTargetNotImplemented;
            var offset: usize = 0;
            while (offset + texel_bytes <= bytes.len) : (offset += texel_bytes) @memcpy(bytes[offset..][0..texel_bytes], value[0..texel_bytes]);
        }
    }

    /// After plain texels are written back, every block is uncompressed.
    pub fn markUncompressed(self: Dcc, memory: anytype, keys: []u8) !void {
        @memset(keys, 0xff);
        if (!memory.write(memory.context, self.address, keys)) return error.GuestWriteFailed;
    }
};

/// Full, single-mip sampled/storage allocations with uniform DCC keys. A
/// uniform key is independent of the metadata address permutation. Mixed
/// keys need the DCC layout equation and are deliberately not interpreted.
/// A fully uncompressed surface (key 0xff) is usable for any unified format,
/// because its guest bytes already hold the texels. Compressed keys can be
/// materialized only for the formats whose cleared texel is exactly
/// representable: R8_UNORM, R32_FLOAT, RGB10A2_UNORM, RGBA8_UNORM,
/// RGBA16_UINT and RGBA16_FLOAT.
pub const TextureDcc = struct {
    address: u64,
    bytes: usize,
    format: u16,
    alpha_msb: bool,

    pub fn fromImage(image: gpu.resources.ImageDescriptor, bytes: usize) !?TextureDcc {
        const address = image.dccMetadataAddress() orelse {
            if (gpu.MetadataSurface.fromImage(image).hasAny()) return error.CompressedColorTargetNotImplemented;
            return null;
        };
        if (image.resourceMipLevels() != 1 or image.viewBaseLevel() != 0 or image.base_array != 0 or
            image.samplesLog2() != 0 or image.cmask_fast_clear or image.fmask_compression or
            bytes != (try gpu.TextureLayout.fromImage(image)).required_source_bytes) return error.CompressedColorTargetNotImplemented;
        _ = try std.math.add(u64, address, Dcc.blockCount(bytes));
        return .{ .address = address, .bytes = bytes, .format = image.unified_format, .alpha_msb = image.descriptor_flags & (1 << 22) != 0 };
    }

    pub fn expand(self: TextureDcc, memory: anytype, backing: []u8) !void {
        if (backing.len != self.bytes or self.bytes == 0) return error.InvalidDccKeyRange;
        var scratch: [256]u8 = undefined;
        var first: ?u8 = null;
        var offset: usize = 0;
        const count = Dcc.blockCount(self.bytes);
        while (offset < count) {
            const keys = scratch[0..@min(scratch.len, count - offset)];
            if (!memory.read(memory.context, self.address + offset, keys)) return error.GuestReadFailed;
            if (first == null) first = keys[0];
            if (!std.mem.allEqual(u8, keys, first.?)) return error.CompressedColorTargetNotImplemented;
            offset += keys.len;
        }
        const code = first.?;
        // 0xff marks fully uncompressed blocks, so the guest bytes are already
        // the texels and no format-specific clear encoding is needed.
        if (code == 0xff) return;
        const texel_bytes: usize = switch (self.format) {
            1 => 1,
            22, 50, 56 => 4,
            69, 71 => 8,
            else => {
                std.debug.print("[d3d12 DCC] compressed key=0x{x} for format={d} address=0x{x}\n", .{ code, self.format, self.address });
                return error.CompressedColorTargetNotImplemented;
            },
        };
        // Single-channel formats resolve their clear against the alpha lane, as
        // R8_UNORM already does, so R32_FLOAT reuses the same bit position.
        const components: usize = if (self.format == 1 or self.format == 22) 1 else 4;
        const alpha_channel: usize = if (components == 4 and self.alpha_msb) 3 else 0;
        var texel: [8]u8 = @splat(0);
        if (code != 0x10) {
            if (code != 0 and code != 0x40 and code != 0x80 and code != 0xc0) {
                std.debug.print("[d3d12 DCC] unsupported uniform key=0x{x} address=0x{x}\n", .{ code, self.address });
                return error.CompressedColorTargetNotImplemented;
            }
            for (0..components) |channel| {
                const one = code & (if (channel == alpha_channel) @as(u8, 0x40) else 0x80) != 0;
                if (self.format == 50) {
                    var bits = std.mem.readInt(u32, texel[0..4], .little);
                    if (one) bits |= @as(u32, if (channel == 3) 3 else 1023) << @as(u5, @intCast(channel * 10));
                    std.mem.writeInt(u32, texel[0..4], bits, .little);
                } else if (self.format == 22) std.mem.writeInt(u32, texel[0..4], if (one) 0x3f80_0000 else 0, .little) else if (self.format == 69) std.mem.writeInt(u16, texel[channel * 2 ..][0..2], if (one) 0xffff else 0, .little) else if (self.format == 71) std.mem.writeInt(u16, texel[channel * 2 ..][0..2], if (one) 0x3c00 else 0, .little) else texel[channel] = if (one) 255 else 0;
            }
        }
        offset = 0;
        while (offset < backing.len) {
            const block = backing[offset..@min(backing.len, offset + Dcc.block_bytes)];
            if (block.len % texel_bytes != 0) return error.InvalidDccKeyRange;
            if (code == 0x10) @memcpy(texel[0..texel_bytes], block[0..texel_bytes]);
            var pixel: usize = 0;
            while (pixel < block.len) : (pixel += texel_bytes) @memcpy(block[pixel..][0..texel_bytes], texel[0..texel_bytes]);
            offset += block.len;
        }
    }

    pub fn publish(self: TextureDcc, memory: anytype) !void {
        const keys: [256]u8 = @splat(0xff);
        const count = Dcc.blockCount(self.bytes);
        var offset: usize = 0;
        while (offset < count) {
            const part = keys[0..@min(keys.len, count - offset)];
            if (!memory.write(memory.context, self.address + offset, part)) return error.GuestWriteFailed;
            offset += part.len;
        }
    }
};

test "DCC block counts cover partial blocks without overflowing guest lengths" {
    try std.testing.expectEqual(@as(usize, 0), Dcc.blockCount(0));
    try std.testing.expectEqual(@as(usize, 1), Dcc.blockCount(1));
    try std.testing.expectEqual(@as(usize, 1), Dcc.blockCount(256));
    try std.testing.expectEqual(@as(usize, 2), Dcc.blockCount(257));
    const maximum = std.math.maxInt(usize);
    try std.testing.expectEqual(maximum / 256 + 1, Dcc.blockCount(maximum));
    try std.testing.expectEqual(maximum / 256, Dcc.blockCount(maximum - 255));
}

test "DCC fast-clear keys expand into the tiled backing and unknown codes are rejected" {
    const Memory = struct {
        keys: [3]u8,
        written: [3]u8 = @splat(0),
        fn read(context: ?*anyopaque, _: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memcpy(bytes, self.keys[0..bytes.len]);
            return true;
        }
        fn write(context: ?*anyopaque, _: u64, bytes: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memcpy(self.written[0..bytes.len], bytes);
            return true;
        }
        fn access(self: *@This()) @import("backend.zig").Memory {
            return .{ .context = self, .read = read, .write = write };
        }
    };
    var backing: [600]u8 = undefined;
    for (&backing, 0..) |*byte, i| byte.* = @truncate(i);
    var memory = Memory{ .keys = .{ 0xff, 0x20, 0x10 } };
    const dcc = Dcc{ .address = 0x1000, .clear_word = 0x44332211 };
    var keys: [3]u8 = undefined;
    try dcc.expand(memory.access(), &backing, &keys);
    for (backing[0..256], 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i)), byte);
    for (0..64) |i| try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, backing[256 + i * 4 ..][0..4]);
    // The partial last block repeats its first texel.
    for (0..22) |i| try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, backing[512 + i * 4 ..][0..4]);
    try dcc.markUncompressed(memory.access(), &keys);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff }, &memory.written);
    memory.keys = .{ 0xff, 0x55, 0xff };
    try std.testing.expectError(error.CompressedColorTargetNotImplemented, dcc.expand(memory.access(), &backing, &keys));
}

test "DCC fixed clears stay bit-exact only for byte-per-channel formats" {
    const Memory = struct {
        keys: [1]u8,
        fn read(context: ?*anyopaque, _: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memcpy(bytes, self.keys[0..bytes.len]);
            return true;
        }
        fn write(_: ?*anyopaque, _: u64, _: []const u8) bool {
            return true;
        }
        fn access(self: *@This()) @import("backend.zig").Memory {
            return .{ .context = self, .read = read, .write = write };
        }
    };
    var backing: [256]u8 = undefined;
    var keys: [1]u8 = undefined;
    var memory = Memory{ .keys = .{0x00} };
    // Clearing a block to zero is format-independent: every colour reads zero.
    for ([_]u16{ 6, 9, 10 }) |format| {
        @memset(&backing, 0xaa);
        const zero = Dcc{ .address = 0x1000, .clear_word = 0x44332211, .format = format };
        try zero.expand(memory.access(), &backing, &keys);
        try std.testing.expect(std.mem.allEqual(u8, &backing, 0));
    }
    // The fixed all-ones clears are only exact when a byte is a whole channel.
    memory.keys[0] = 0x80;
    try (Dcc{ .address = 0x1000, .clear_word = 0, .format = 10 }).expand(memory.access(), &backing, &keys);
    for (0..64) |i| try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, backing[i * 4 ..][0..4]);
    for ([_]u16{ 6, 9 }) |format| {
        const packed_dcc = Dcc{ .address = 0x1000, .clear_word = 0, .format = format };
        try std.testing.expectError(error.CompressedColorTargetNotImplemented, packed_dcc.expand(memory.access(), &backing, &keys));
    }
    // The clear word still resolves those formats through code 0x20.
    memory.keys[0] = 0x20;
    const packed_clear = Dcc{ .address = 0x1000, .clear_word = 0x3f801c00, .format = 6 };
    try packed_clear.expand(memory.access(), &backing, &keys);
    for (0..64) |i| try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x1c, 0x80, 0x3f }, backing[i * 4 ..][0..4]);
    // A wider-than-word texel repeats whole and only takes format-independent
    // clears; its fixed codes and clear word have no encoding here.
    memory.keys[0] = 0x00;
    @memset(&backing, 0x5a);
    const wide = Dcc{ .address = 0x1000, .clear_word = 0x3f801c00, .format = 12, .bytes_per_texel = 8 };
    try wide.expand(memory.access(), &backing, &keys);
    try std.testing.expect(std.mem.allEqual(u8, &backing, 0));
    for ([_]u8{ 0x20, 0x80 }) |code| {
        memory.keys[0] = code;
        try std.testing.expectError(error.CompressedColorTargetNotImplemented, wide.expand(memory.access(), &backing, &keys));
    }
    memory.keys[0] = 0x10;
    for (&backing, 0..) |*byte, i| byte.* = @truncate(i);
    try wide.expand(memory.access(), &backing, &keys);
    for (0..32) |i| try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, backing[i * 8 ..][0..8]);
}

test "RGBA16_UINT DCC clears materialize 16-bit integer texels at both alpha positions" {
    const Memory = struct {
        keys: [1]u8,
        fn read(context: ?*anyopaque, _: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memcpy(bytes, self.keys[0..bytes.len]);
            return true;
        }
        fn write(_: ?*anyopaque, _: u64, _: []const u8) bool {
            return true;
        }
        fn access(self: *@This()) @import("backend.zig").Memory {
            return .{ .context = self, .read = read, .write = write };
        }
    };
    var backing: [256]u8 = @splat(0xaa);
    var memory = Memory{ .keys = .{0x80} };
    // RGBA16_UINT is eight bytes per texel, and an integer clear uses 0xffff.
    for ([_]bool{ false, true }) |alpha_msb| for ([_]u8{ 0, 0x40, 0x80, 0xc0, 0xff, 0x10 }) |key| {
        memory.keys[0] = key;
        const dcc = TextureDcc{ .address = 0x1000, .bytes = backing.len, .format = 69, .alpha_msb = alpha_msb };
        @memset(&backing, 0xaa);
        try dcc.expand(memory.access(), &backing);
        const alpha_channel: usize = if (alpha_msb) 3 else 0;
        for (0..backing.len / 8) |texel| for (0..4) |channel| {
            const one = key != 0xff and key != 0x10 and
                key & (if (channel == alpha_channel) @as(u8, 0x40) else 0x80) != 0;
            const expected: u16 = if (key == 0xff) 0xaaaa else if (key == 0x10) 0xaaaa else if (one) 0xffff else 0;
            try std.testing.expectEqual(expected, std.mem.readInt(u16, backing[texel * 8 + channel * 2 ..][0..2], .little));
        };
    };
    // An unknown uniform key is still rejected after the format was widened.
    memory.keys[0] = 0x55;
    const dcc = TextureDcc{ .address = 0x1000, .bytes = backing.len, .format = 69, .alpha_msb = false };
    try std.testing.expectError(error.CompressedColorTargetNotImplemented, dcc.expand(memory.access(), &backing));
}

test "R32_FLOAT DCC clears use float zero and one, and unsupported formats still reject" {
    const Memory = struct {
        keys: [1]u8,
        fn read(context: ?*anyopaque, _: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memcpy(bytes, self.keys[0..bytes.len]);
            return true;
        }
        fn write(_: ?*anyopaque, _: u64, _: []const u8) bool {
            return true;
        }
        fn access(self: *@This()) @import("backend.zig").Memory {
            return .{ .context = self, .read = read, .write = write };
        }
    };
    var backing: [256]u8 = undefined;
    for (&backing, 0..) |*byte, i| byte.* = @truncate(i);
    var memory = Memory{ .keys = .{0xff} };
    const r32 = TextureDcc{ .address = 0x1000, .bytes = backing.len, .format = 22, .alpha_msb = false };
    const original = backing;
    // An uncompressed key leaves the guest texels exactly as they are.
    try r32.expand(memory.access(), &backing);
    try std.testing.expectEqualSlices(u8, &original, &backing);
    // Clear-to-zero and clear-to-one encode the float counterparts.
    for ([_]struct { key: u8, expected: u32 }{
        .{ .key = 0x00, .expected = 0 },
        .{ .key = 0x40, .expected = 0x3f80_0000 },
        .{ .key = 0x80, .expected = 0 },
        .{ .key = 0xc0, .expected = 0x3f80_0000 },
    }) |case| {
        memory.keys[0] = case.key;
        @memset(&backing, 0xaa);
        try r32.expand(memory.access(), &backing);
        for (0..backing.len / 4) |texel|
            try std.testing.expectEqual(case.expected, std.mem.readInt(u32, backing[texel * 4 ..][0..4], .little));
    }
    // A format with no clear encoding is still rejected while compressed.
    memory.keys[0] = 0x80;
    const unsupported = TextureDcc{ .address = 0x1000, .bytes = backing.len, .format = 29, .alpha_msb = false };
    try std.testing.expectError(error.CompressedColorTargetNotImplemented, unsupported.expand(memory.access(), &backing));
}

/// HTILE fast clears override the bytes in the depth/stencil allocations.
/// Keep the metadata snapshot with both planes until their completed writes
/// can be published together. The non-pipe-aligned SDK layout is accepted
/// only for a uniform key, where the address permutation cannot matter.
pub const Htile = struct {
    lease: staging.Lease,
    layout: gpu.HtileLayout,
    address: u64,
    uniform: bool,
    stencil_disabled: bool,

    fn layoutFor(target: gpu.resources.DepthTarget) !gpu.HtileLayout {
        if (target.htile_address == 0 or target.tile_mode != .depth or target.maximum_mip != 0 or target.mip_level != 0 or
            target.samples_log2 != 0 or target.base_array_slice != 0 or target.last_array_slice != 0 or
            (!target.htile_pipe_aligned and !target.tile_stencil_disabled)) return error.UnsupportedMetadataLayout;
        const layout = try gpu.HtileLayout.init(target.width, target.height, 1, 0, target.width);
        _ = try std.math.add(u64, target.htile_address, layout.required_bytes);
        return layout;
    }

    pub fn read(allocator: std.mem.Allocator, pool: ?*staging.Pool, memory: anytype, target: gpu.resources.DepthTarget) !Htile {
        const layout = try layoutFor(target);
        var lease = try staging.Lease.alloc(allocator, pool, @intCast(layout.required_bytes));
        errdefer lease.deinit();
        if (!memory.read(memory.context, target.htile_address, lease.bytes)) return error.GuestReadFailed;
        if (!target.htile_pipe_aligned) {
            var offset: usize = 4;
            while (offset < lease.bytes.len) : (offset += 4)
                if (!std.mem.eql(u8, lease.bytes[0..4], lease.bytes[offset..][0..4])) return error.UnsupportedMetadataLayout;
        }
        return .{ .lease = lease, .layout = layout, .address = target.htile_address, .uniform = !target.htile_pipe_aligned, .stencil_disabled = target.tile_stencil_disabled };
    }

    pub fn deinit(self: *Htile) void {
        self.lease.deinit();
    }

    pub fn expand(self: Htile, depth: *Staged, stencil: ?*Staged) !void {
        if (!self.stencil_disabled and stencil == null) return error.MissingStencilTarget;
        var y: u32 = 0;
        while (y < self.layout.height) : (y += 8) {
            var x: u32 = 0;
            while (x < self.layout.width) : (x += 8) {
                const word = if (self.uniform) std.mem.readInt(u32, self.lease.bytes[0..4], .little) else try self.layout.word(self.lease.bytes, x, y, 0);
                if (word == gpu.HtileLayout.expandedWord(self.stencil_disabled)) continue;
                const value = gpu.HtileLayout.fastClearDepth(word, self.stencil_disabled) orelse return error.CompressedDepthTargetNotImplemented;
                var py = y;
                while (py < @min(y + 8, self.layout.height)) : (py += 1) {
                    var px = x;
                    while (px < @min(x + 8, self.layout.width)) : (px += 1) {
                        const index = @as(usize, py) * self.layout.width + px;
                        if (depth.layout.block.bytes_per_element == 2)
                            std.mem.writeInt(u16, depth.pixels[index * 2 ..][0..2], if (value == 0) 0 else 65535, .little)
                        else
                            std.mem.writeInt(u32, depth.pixels[index * 4 ..][0..4], @bitCast(value), .little);
                        if (!self.stencil_disabled) stencil.?.pixels[index] = 0;
                    }
                }
            }
        }
    }

    /// Called only after BOTH materialized planes have reached guest memory.
    pub fn publish(self: *Htile, memory: anytype) !void {
        const expanded = gpu.HtileLayout.expandedWord(self.stencil_disabled);
        if (self.uniform) {
            var offset: usize = 0;
            while (offset < self.lease.bytes.len) : (offset += 4) std.mem.writeInt(u32, self.lease.bytes[offset..][0..4], expanded, .little);
        } else {
            // Preserve metadata outside the view, including padded regions.
            var y: u32 = 0;
            while (y < self.layout.height) : (y += 8) {
                var x: u32 = 0;
                while (x < self.layout.width) : (x += 8) try self.layout.setWord(self.lease.bytes, x, y, 0, expanded);
            }
        }
        if (!memory.write(memory.context, self.address, self.lease.bytes)) return error.GuestWriteFailed;
    }
};

pub const Staged = struct {
    backing_lease: staging.Lease,
    pixel_lease: staging.Lease,
    layout: gpu.SurfaceLayout,
    address: u64,
    backing: []u8,
    pixels: []u8,
    cache: ?*surface_cache.Cache = null,
    dcc: ?Dcc = null,
    swap_red_blue: bool = false,
    allocator: ?std.mem.Allocator = null,

    pub fn read(allocator: std.mem.Allocator, memory: anytype, address: u64, layout: gpu.SurfaceLayout) !Staged {
        return readPooled(allocator, null, memory, address, layout);
    }

    pub fn readPooled(allocator: std.mem.Allocator, pool: ?*staging.Pool, memory: anytype, address: u64, layout: gpu.SurfaceLayout) !Staged {
        return readCached(allocator, pool, null, memory, address, layout);
    }

    pub fn readCached(allocator: std.mem.Allocator, pool: ?*staging.Pool, cache: ?*surface_cache.Cache, memory: anytype, address: u64, layout: gpu.SurfaceLayout) !Staged {
        return readColor(allocator, pool, cache, memory, address, layout, null, false);
    }

    /// Reads a surface, resolving DCC fast clears first when `dcc` is set.
    pub fn readColor(allocator: std.mem.Allocator, pool: ?*staging.Pool, cache: ?*surface_cache.Cache, memory: anytype, address: u64, layout: gpu.SurfaceLayout, dcc: ?Dcc, swap_red_blue: bool) !Staged {
        try validate(layout, address);
        if (swap_red_blue and layout.block.bytes_per_element != 4) return error.UnsupportedRenderTargetLayout;
        var backing_lease = try staging.Lease.alloc(allocator, pool, @intCast(layout.required_source_bytes));
        errdefer backing_lease.deinit();
        var pixel_lease = try staging.Lease.alloc(allocator, pool, @intCast(layout.staging_bytes));
        errdefer pixel_lease.deinit();
        const backing = backing_lease.bytes;
        const pixels = pixel_lease.bytes;
        if (!memory.read(memory.context, address, backing)) return error.GuestReadFailed;
        if (dcc) |metadata| try expandDcc(allocator, metadata, memory, backing);
        if (cache) |c| try c.detile(address, layout, backing, pixels) else try layout.detile(backing, pixels);
        if (swap_red_blue) swapChannels(pixels);
        return .{ .backing_lease = backing_lease, .pixel_lease = pixel_lease, .layout = layout, .address = address, .backing = backing, .pixels = pixels, .cache = cache, .dcc = dcc, .swap_red_blue = swap_red_blue, .allocator = allocator };
    }

    fn expandDcc(allocator: std.mem.Allocator, dcc: Dcc, memory: anytype, backing: []u8) !void {
        const keys = try allocator.alloc(u8, Dcc.blockCount(backing.len));
        defer allocator.free(keys);
        try dcc.expand(memory, backing, keys);
    }

    fn publishDcc(allocator: std.mem.Allocator, dcc: Dcc, memory: anytype, bytes: usize) !void {
        const keys = try allocator.alloc(u8, Dcc.blockCount(bytes));
        defer allocator.free(keys);
        try dcc.markUncompressed(memory, keys);
    }

    pub fn write(self: *Staged, memory: anytype) !void {
        // Re-read padding immediately before writeback. Only the logical view
        // is replaced; tail tiles and row padding retain their guest contents.
        if (!memory.read(memory.context, self.address, self.backing)) return error.GuestReadFailed;
        // Materialize fast clears in the padding too, then publish every
        // block as plain texels so later readers use the bytes written here.
        if (self.dcc) |metadata| try expandDcc(self.allocator.?, metadata, memory, self.backing);
        if (self.swap_red_blue) swapChannels(self.pixels);
        defer if (self.swap_red_blue) swapChannels(self.pixels);
        if (self.cache) |c| try c.tile(self.address, self.layout, self.pixels, self.backing) else try self.layout.tile(self.pixels, self.backing);
        if (!memory.write(memory.context, self.address, self.backing)) return error.GuestWriteFailed;
        if (self.dcc) |metadata| try publishDcc(self.allocator.?, metadata, memory, self.backing.len);
    }

    pub fn deinit(self: *Staged) void {
        self.pixel_lease.deinit();
        self.backing_lease.deinit();
        self.* = undefined;
    }
};

fn swapChannels(pixels: []u8) void {
    std.debug.assert(pixels.len % 4 == 0);
    var offset: usize = 0;
    while (offset < pixels.len) : (offset += 4) std.mem.swap(u8, &pixels[offset], &pixels[offset + 2]);
}

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
    target.dcc_address = 0x900000;
    target.clear_words = .{ 0x11223344, 0 };
    _ = try colorLayout(target);
    try std.testing.expectEqual(Dcc{ .address = 0x900000, .clear_word = 0x11223344 }, colorDcc(target).?);
    target.dcc_enabled = false;
    try std.testing.expect(colorDcc(target) == null);
    target.address = std.math.maxInt(u64) - 32;
    try std.testing.expectError(error.ArithmeticOverflow, colorLayout(target));
    try std.testing.expectError(error.UnsupportedScanoutLayout, scanoutLayout(65, 37, 72, 2));
    try std.testing.expectError(error.InvalidPitch, scanoutLayout(65, 37, 64, 1));
}

test "color formats preserve signed and half-float encodings and reject their unsupported metadata" {
    var target = std.mem.zeroes(gpu.resources.ColorTarget);
    target.address = 0x10000;
    target.width = 65;
    target.height = 37;
    target.depth = 1;
    target.tile_mode = .render_target;
    target.format = 5;
    target.number_type = 7;
    try std.testing.expectEqual(@as(u32, 34), try colorFormat(target));
    try std.testing.expectEqual(@as(u32, 4), (try colorLayout(target)).block.bytes_per_element);
    target.format = 12;
    try std.testing.expectEqual(@as(u32, 10), try colorFormat(target));
    try std.testing.expectEqual(@as(u32, 8), (try colorLayout(target)).block.bytes_per_element);
    // A DCC-enabled half-float target is admitted; its clears resolve per key.
    target.dcc_enabled = true;
    target.dcc_address = 0x900000;
    _ = try colorLayout(target);
    try std.testing.expectEqual(@as(u8, 8), colorDcc(target).?.bytes_per_texel);
    target.dcc_enabled = false;
    target.component_swap = 1;
    try std.testing.expectError(error.UnsupportedRenderTargetLayout, colorLayout(target));
    target.component_swap = 0;
    target.format = 10;
    target.number_type = 1;
    try std.testing.expectEqual(@as(u32, 31), try colorFormat(target));
    _ = try colorLayout(target);
    target.dcc_enabled = true;
    target.dcc_address = 0x900000;
    try std.testing.expectError(error.UnsupportedRenderTargetLayout, colorLayout(target));
    target.dcc_enabled = false;
    target.number_type = 4;
    try std.testing.expectError(error.UnsupportedRenderTargetLayout, colorLayout(target));
    // DATA_FORMAT_32_32_32_32 keeps its full 16-byte float texel.
    target.format = 14;
    target.number_type = 7;
    try std.testing.expectEqual(@as(u32, 2), try colorFormat(target));
    try std.testing.expectEqual(@as(u32, 16), (try colorLayout(target)).block.bytes_per_element);
}

test "depth layouts validate address and subresource contracts before staging" {
    var target = std.mem.zeroes(gpu.resources.DepthTarget);
    target.read_address = 0x10000;
    target.write_address = 0x10000;
    target.width = 65;
    target.height = 37;
    target.format = 3;
    target.tile_mode = .linear;
    try std.testing.expectEqual(@as(u32, 128), (try depthLayout(target, 65, 37, true)).row_pitch_elements);
    target.write_address = 0x20000;
    try std.testing.expectError(error.SeparateDepthAddressesNotImplemented, depthLayout(target, 65, 37, true));
    _ = try depthLayout(target, 65, 37, false);
    target.write_address = target.read_address;
    target.htile_enabled = true;
    try std.testing.expectError(error.UnsupportedMetadataLayout, depthLayout(target, 65, 37, true));
    target.htile_enabled = false;
    target.samples_log2 = 1;
    try std.testing.expectError(error.UnsupportedDepthLayout, depthLayout(target, 65, 37, true));
    target.samples_log2 = 0;
    target.mip_level = 1;
    try std.testing.expectError(error.UnsupportedDepthLayout, depthLayout(target, 65, 37, true));
    target.mip_level = 0;
    target.read_address = std.math.maxInt(u64) - 32;
    try std.testing.expectError(error.ArithmeticOverflow, depthLayout(target, 65, 37, false));
}

test "HTILE clear materialization preserves both planes and publishes expanded metadata after writeback" {
    const Memory = struct {
        data: [0x40000]u8 = @splat(0xcd),
        fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address > self.data.len or bytes.len > self.data.len - address) return false;
            @memcpy(bytes, self.data[@intCast(address)..][0..bytes.len]);
            return true;
        }
        fn write(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address > self.data.len or bytes.len > self.data.len - address) return false;
            @memcpy(self.data[@intCast(address)..][0..bytes.len], bytes);
            return true;
        }
        fn access(self: *@This()) @import("backend.zig").Memory {
            return .{ .context = self, .read = read, .write = write };
        }
    };
    var memory = Memory{};
    for ([_]u8{ 1, 3 }) |format| for ([_]bool{ false, true }) |no_stencil| {
        @memset(&memory.data, 0xcd);
        var target = std.mem.zeroes(gpu.resources.DepthTarget);
        target.read_address = 0x10000;
        target.write_address = 0x10000;
        target.stencil_read_address = 0x20000;
        target.stencil_write_address = 0x20000;
        target.width = 65;
        target.height = 37;
        target.format = @intCast(format);
        target.stencil_format = 1;
        target.tile_mode = .depth;
        target.stencil_tile_mode = .depth;
        target.htile_enabled = true;
        target.htile_address = 0x30000;
        target.htile_pipe_aligned = !no_stencil;
        target.tile_stencil_disabled = no_stencil;
        const layout = try Htile.layoutFor(target);
        const keys = memory.data[0x30000..][0..@intCast(layout.required_bytes)];
        var offset: usize = 0;
        while (offset < keys.len) : (offset += 4) std.mem.writeInt(u32, keys[offset..][0..4], if (no_stencil) 0xfffffff0 else 0xfffc00f0, .little);
        var depth = try Staged.read(std.testing.allocator, memory.access(), target.read_address, try depthLayout(target, 65, 37, true));
        defer depth.deinit();
        var stencil = try Staged.read(std.testing.allocator, memory.access(), target.stencil_read_address, try stencilLayout(target, 65, 37, true));
        defer stencil.deinit();
        var htile = try Htile.read(std.testing.allocator, null, memory.access(), target);
        defer htile.deinit();
        try htile.expand(&depth, &stencil);
        for (0..65 * 37) |i| {
            if (format == 1) try std.testing.expectEqual(@as(u16, 65535), std.mem.readInt(u16, depth.pixels[i * 2 ..][0..2], .little)) else try std.testing.expectEqual(@as(u32, 0x3f800000), std.mem.readInt(u32, depth.pixels[i * 4 ..][0..4], .little));
            try std.testing.expectEqual(@as(u8, if (no_stencil) 0xcd else 0), stencil.pixels[i]);
        }
        try depth.write(memory.access());
        try stencil.write(memory.access());
        try htile.publish(memory.access());
        try std.testing.expectEqual(gpu.HtileLayout.expandedWord(no_stencil), try layout.word(keys, 0, 0, 0));
        // Subsequent reads must retain new depth/stencil writes, not replay the clear.
        @memset(depth.pixels, 0x39);
        @memset(stencil.pixels, 0x71);
        var second = try Htile.read(std.testing.allocator, null, memory.access(), target);
        defer second.deinit();
        try second.expand(&depth, &stencil);
        for (depth.pixels) |byte| try std.testing.expectEqual(@as(u8, 0x39), byte);
        for (stencil.pixels) |byte| try std.testing.expectEqual(@as(u8, 0x71), byte);
        std.mem.writeInt(u32, second.lease.bytes[0..4], 0xdeadbeef, .little);
        if (no_stencil) try std.testing.expectError(error.CompressedDepthTargetNotImplemented, second.expand(&depth, &stencil));
    };
}

test "pooled surfaces refresh guest bytes, preserve newly changed padding and release failed reads" {
    const Memory = struct {
        data: []u8,
        fail: bool = false,
        fail_write: bool = false,
        writes: usize = 0,
        fn read(context: ?*anyopaque, _: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.fail) return false;
            @memcpy(bytes, self.data[0..bytes.len]);
            return true;
        }
        fn write(context: ?*anyopaque, _: u64, bytes: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.writes += 1;
            if (self.fail_write) return false;
            @memcpy(self.data[0..bytes.len], bytes);
            return true;
        }
        fn access(self: *@This()) @import("backend.zig").Memory {
            return .{ .context = self, .read = read, .write = write };
        }
    };
    var pool = staging.Pool{ .allocator = std.testing.allocator };
    defer pool.deinit();
    var cache = surface_cache.Cache{ .allocator = std.testing.allocator };
    defer cache.deinit();
    for ([_]gpu.resources.TileMode{ .linear, .render_target }) |mode| for ([_]u8{ 2, 4 }) |bpp| {
        const layout = try gpu.SurfaceLayout.init(.{ .tile_mode = mode, .width = 65, .height = 37, .row_pitch_elements = 80 }, bpp);
        const backing = try std.testing.allocator.alloc(u8, @intCast(layout.required_source_bytes));
        defer std.testing.allocator.free(backing);
        const expected = try std.testing.allocator.alloc(u8, backing.len);
        defer std.testing.allocator.free(expected);
        const pixels = try std.testing.allocator.alloc(u8, @intCast(layout.staging_bytes));
        defer std.testing.allocator.free(pixels);
        var memory = Memory{ .data = backing };
        for (0..3) |iteration| {
            for (pixels, 0..) |*byte, i| byte.* = @truncate(i *% 197 +% iteration *% 31);
            @memset(backing, 0x36);
            try layout.tile(pixels, backing);
            var surface = try Staged.readCached(std.testing.allocator, &pool, &cache, memory.access(), 0x10000, layout);
            defer surface.deinit();
            try std.testing.expectEqualSlices(u8, pixels, surface.pixels);
            // All padding changes after the initial snapshot must survive writeback.
            @memset(backing, 0x9a);
            @memset(expected, 0x9a);
            for (surface.pixels) |*byte| byte.* ^= 0x71;
            try layout.tile(surface.pixels, expected);
            try surface.write(memory.access());
            try std.testing.expectEqualSlices(u8, expected, backing);
            const hits = cache.tile_hits;
            const writes = memory.writes;
            try surface.write(memory.access());
            try std.testing.expectEqual(hits + 1, cache.tile_hits);
            try std.testing.expectEqual(writes + 1, memory.writes);
            memory.fail_write = true;
            try std.testing.expectError(error.GuestWriteFailed, surface.write(memory.access()));
            memory.fail_write = false;
        }
        memory.fail = true;
        try std.testing.expectError(error.GuestReadFailed, Staged.readCached(std.testing.allocator, &pool, &cache, memory.access(), 0x10000, layout));
        for (pool.entries) |entry| try std.testing.expect(!entry.busy);
    };
    try std.testing.expect(pool.hits > 0);
}
