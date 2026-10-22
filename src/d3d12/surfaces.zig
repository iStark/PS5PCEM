// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest surface staging uses the shared GFX10 address equations. D3D12 owns
//! the native texture layout; upload/readback buffers carry tight color/depth texels.
const std = @import("std");
const gpu = @import("gpu");
const staging = @import("staging.zig");
const surface_cache = @import("surface_cache.zig");

pub fn colorLayout(target: gpu.resources.ColorTarget) !gpu.SurfaceLayout {
    if (target.format != 10 or target.number_type != 0 or target.component_swap != 0 or
        target.samples_log2 != 0 or target.fragments_log2 != 0 or target.mip_level != 0 or
        target.maximum_mip != 0 or target.resource_type == 2 or target.depth > 1 or
        target.base_array_slice != 0 or target.last_array_slice != 0 or
        (target.dcc_enabled and target.dcc_address == 0) or target.cmask_fast_clear or target.fmask_compression or
        target.force_destination_alpha_one) return error.UnsupportedRenderTargetLayout;
    const layout = try gpu.SurfaceLayout.fromColorTarget(target);
    try validate(layout, target.address);
    return layout;
}

/// DCC keys accompany the colour layout; null for an uncompressed target.
pub fn colorDcc(target: gpu.resources.ColorTarget) ?Dcc {
    if (!target.dcc_enabled) return null;
    return .{ .address = target.dcc_address, .clear_word = target.clear_words[0] };
}

pub fn depthLayout(target: gpu.resources.DepthTarget, width: u32, height: u32, writable: bool) !gpu.SurfaceLayout {
    if ((target.format != 1 and target.format != 3) or target.width != width or target.height != height or
        target.samples_log2 != 0 or target.maximum_mip != 0 or target.mip_level != 0 or
        target.base_array_slice != 0 or target.last_array_slice != 0 or target.htile_enabled)
        return error.UnsupportedDepthLayout;
    if (target.read_address == 0 or (writable and target.write_address != target.read_address)) return error.SeparateDepthAddressesNotImplemented;
    const layout = try gpu.SurfaceLayout.fromDepthTarget(target);
    try validate(layout, target.read_address);
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
        layout.layers != 1 or (layout.block.bytes_per_element != 4 and layout.block.bytes_per_element != 2) or
        layout.required_source_bytes > 256 * 1024 * 1024 or layout.staging_bytes > 256 * 1024 * 1024)
        return error.SurfaceBudgetExceeded;
    _ = try layout.sourceRange(address);
}

/// GFX10 DCC metadata for an RGBA8 colour surface: one key byte per 256-byte
/// block of the tiled base allocation. 0xFF means the block holds plain
/// texels; the fast-clear codes mean every texel of the block reads as the
/// clear value regardless of the bytes underneath. Other codes describe
/// genuinely compressed data, which this path does not decode.
pub const Dcc = struct {
    address: u64,
    /// Render targets carry CB_COLOR*_CLEAR_WORD0; sampled views do not, so
    /// code 0x20 cannot be resolved for them.
    clear_word: ?u32,

    pub const block_bytes = 256;

    fn texel(self: Dcc, code: u8) ?[4]u8 {
        return switch (code) {
            0x00 => .{ 0, 0, 0, 0 },
            0x40 => .{ 0, 0, 0, 255 },
            0x80 => .{ 255, 255, 255, 0 },
            0xc0 => .{ 255, 255, 255, 255 },
            // CB_COLOR*_CLEAR_WORD0 holds the texel in the surface encoding.
            0x20 => std.mem.toBytes(std.mem.nativeToLittle(u32, self.clear_word orelse return null)),
            else => null,
        };
    }

    /// Rewrites every fast-cleared block of `backing` with its clear value.
    /// Comp-to-single (0x10) blocks keep their representative first texel.
    pub fn expand(self: Dcc, memory: anytype, backing: []u8, keys: []u8) !void {
        if (keys.len != std.math.divCeil(usize, backing.len, block_bytes) catch unreachable) return error.InvalidDccKeyRange;
        if (!memory.read(memory.context, self.address, keys)) return error.GuestReadFailed;
        for (keys, 0..) |code, block| {
            if (code == 0xff) continue;
            const bytes = backing[block * block_bytes .. @min(backing.len, (block + 1) * block_bytes)];
            var value: [4]u8 = undefined;
            if (code == 0x10) {
                if (bytes.len < 4) return error.CompressedColorTargetNotImplemented;
                value = bytes[0..4].*;
            } else value = self.texel(code) orelse return error.CompressedColorTargetNotImplemented;
            var offset: usize = 0;
            while (offset + 4 <= bytes.len) : (offset += 4) bytes[offset..][0..4].* = value;
        }
    }

    /// After plain texels are written back, every block is uncompressed.
    pub fn markUncompressed(self: Dcc, memory: anytype, keys: []u8) !void {
        @memset(keys, 0xff);
        if (!memory.write(memory.context, self.address, keys)) return error.GuestWriteFailed;
    }
};

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

pub const Staged = struct {
    backing_lease: staging.Lease,
    pixel_lease: staging.Lease,
    layout: gpu.SurfaceLayout,
    address: u64,
    backing: []u8,
    pixels: []u8,
    cache: ?*surface_cache.Cache = null,
    dcc: ?Dcc = null,
    allocator: ?std.mem.Allocator = null,

    pub fn read(allocator: std.mem.Allocator, memory: anytype, address: u64, layout: gpu.SurfaceLayout) !Staged {
        return readPooled(allocator, null, memory, address, layout);
    }

    pub fn readPooled(allocator: std.mem.Allocator, pool: ?*staging.Pool, memory: anytype, address: u64, layout: gpu.SurfaceLayout) !Staged {
        return readCached(allocator, pool, null, memory, address, layout);
    }

    pub fn readCached(allocator: std.mem.Allocator, pool: ?*staging.Pool, cache: ?*surface_cache.Cache, memory: anytype, address: u64, layout: gpu.SurfaceLayout) !Staged {
        return readColor(allocator, pool, cache, memory, address, layout, null);
    }

    /// Reads a surface, resolving DCC fast clears first when `dcc` is set.
    pub fn readColor(allocator: std.mem.Allocator, pool: ?*staging.Pool, cache: ?*surface_cache.Cache, memory: anytype, address: u64, layout: gpu.SurfaceLayout, dcc: ?Dcc) !Staged {
        try validate(layout, address);
        var backing_lease = try staging.Lease.alloc(allocator, pool, @intCast(layout.required_source_bytes));
        errdefer backing_lease.deinit();
        var pixel_lease = try staging.Lease.alloc(allocator, pool, @intCast(layout.staging_bytes));
        errdefer pixel_lease.deinit();
        const backing = backing_lease.bytes;
        const pixels = pixel_lease.bytes;
        if (!memory.read(memory.context, address, backing)) return error.GuestReadFailed;
        if (dcc) |metadata| try expandDcc(allocator, metadata, memory, backing);
        if (cache) |c| try c.detile(address, layout, backing, pixels) else try layout.detile(backing, pixels);
        return .{ .backing_lease = backing_lease, .pixel_lease = pixel_lease, .layout = layout, .address = address, .backing = backing, .pixels = pixels, .cache = cache, .dcc = dcc, .allocator = allocator };
    }

    fn expandDcc(allocator: std.mem.Allocator, dcc: Dcc, memory: anytype, backing: []u8) !void {
        const keys = try allocator.alloc(u8, std.math.divCeil(usize, backing.len, Dcc.block_bytes) catch unreachable);
        defer allocator.free(keys);
        try dcc.expand(memory, backing, keys);
    }

    fn publishDcc(allocator: std.mem.Allocator, dcc: Dcc, memory: anytype, bytes: usize) !void {
        const keys = try allocator.alloc(u8, std.math.divCeil(usize, bytes, Dcc.block_bytes) catch unreachable);
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
    try std.testing.expectError(error.UnsupportedDepthLayout, depthLayout(target, 65, 37, true));
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
