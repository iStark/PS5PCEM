// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Explicit hardware probe: read actual GPU results, rather than just checking
//! that resource creation and command recording returned success.
const std = @import("std");
const d3d12 = @import("d3d12");
const rdna2 = @import("rdna2");
const gpu = @import("gpu");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var debug = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) debug = true else return error.InvalidArgument;
    }
    var device = try d3d12.Device.init(debug);
    defer device.deinit();
    std.debug.print("D3D12 adapter: {s}, {d} MiB, validation={any}\n", .{ device.info.name(), device.info.dedicated_bytes / (1024 * 1024), device.info.debug_enabled != 0 });
    std.debug.print("Shader model=0x{x}, WaveOps={d}, native lanes={d}..{d}\n", .{ device.info.shader_model, device.info.wave_ops, device.info.wave_lane_min, device.info.wave_lane_max });

    for ([_]usize{ 1, 255, 256, 257, 65537, 1048577 }) |size| {
        const source = try allocator.alloc(u8, size);
        defer allocator.free(source);
        const result = try allocator.alloc(u8, size);
        defer allocator.free(result);
        for (source, 0..) |*byte, i| byte.* = @truncate(i *% 197 +% (i >> 9));
        @memset(result, 0xcc);
        try device.bufferRoundtrip(source, result);
        if (!std.mem.eql(u8, source, result)) return error.BufferReadbackMismatch;
    }
    std.debug.print("PASS upload -> device-local buffer -> readback (6 sizes)\n", .{});

    for ([_]usize{ 1, 63, 64, 65, 129, 8192 }) |count| {
        const result = try allocator.alloc(u32, count);
        defer allocator.free(result);
        try device.computeProbe(result, 0xfffffff1, 0xfffffff7);
        for (result, 0..) |value, i| {
            const expected = @as(u32, @intCast(i)) *% 0xfffffff1 +% 0xfffffff7;
            if (value != expected) return error.ComputeReadbackMismatch;
        }
    }
    std.debug.print("PASS native HLSL compute, UAV writes, barriers and fence completion (6 dispatch sizes)\n", .{});

    // The same RDNA2 frontend used for games, with two independently staged
    // descriptor-array elements. Every invocation copies one input word.
    const guest_kernel = [_]u32{ 0xe0302000, 0x80000100, 0xe0702000, 0x80010100, 0xbf810000 };
    var guest_program = try rdna2.decodeProgram(allocator, &guest_kernel);
    defer guest_program.deinit(allocator);
    var translated = try rdna2.translateProgramSpirv(allocator, &guest_program, .{
        .stage = .compute,
        .local_size = .{ 64, 1, 1 },
        .compute_inputs = .{ .local_invocation_id_components = 1 },
        .storage_buffers = &.{
            .{ .resource_sgpr = 0, .descriptor_index = 0, .stride = 4, .extent_bytes = 256 },
            .{ .resource_sgpr = 4, .descriptor_index = 1, .stride = 4, .extent_bytes = 256 },
        },
        .descriptor_array_length = 2,
        .allow_control_flow_fallback = false,
    });
    defer translated.deinit(allocator);
    var source_words: [64]u32 = undefined;
    var copied_words: [64]u32 = @splat(0);
    for (&source_words, 0..) |*word, i| word.* = @as(u32, @intCast(i)) *% 0x12345 +% 7;
    try device.dispatchSpirv(translated.words, &.{
        d3d12.Buffer.fromSlice(std.mem.asBytes(&source_words)),
        d3d12.Buffer.fromSlice(std.mem.asBytes(&copied_words)),
    }, .{ 1, 1, 1 }, false);
    if (!std.mem.eql(u32, &source_words, &copied_words)) return error.GuestComputeMismatch;
    const compute_cache = device.cacheStats();
    for (&source_words) |*word| word.* ^= 0xabcdef12;
    @memset(&copied_words, 0xcc);
    try device.dispatchSpirv(translated.words, &.{
        d3d12.Buffer.fromSlice(std.mem.asBytes(&source_words)),
        d3d12.Buffer.fromSlice(std.mem.asBytes(&copied_words)),
    }, .{ 1, 1, 1 }, false);
    if (!std.mem.eql(u32, &source_words, &copied_words)) return error.CachedComputeReadbackMismatch;
    if (compute_cache.enabled != 0 and (device.cacheStats().shader_hits != compute_cache.shader_hits + 1 or
        device.cacheStats().pipeline_hits != compute_cache.pipeline_hits + 1)) return error.ComputeCacheMiss;
    const preserved = source_words;
    // Same bytecode with a different binding count must still fail reflection,
    // even after the valid layout has populated the shader cache.
    if (device.dispatchSpirv(translated.words, &.{d3d12.Buffer.fromSlice(std.mem.asBytes(&source_words))}, .{ 1, 1, 1 }, false)) |_| {
        return error.CachedInvalidLayoutAccepted;
    } else |err| if (err != error.NativeFailure) return err;
    if (!std.mem.eql(u32, &source_words, &preserved)) return error.InvalidLayoutModifiedBuffer;
    std.debug.print("PASS guest RDNA2 -> shared IR -> HLSL -> D3D12 compute, descriptor arrays and exact readback\n", .{});
    try guestWaveProbe(allocator, &device);
    try guestComputeImagesProbe(allocator, &device);
    try guestComputeImageLayoutProbe(allocator);
    try guestComputeDccVolumeProbe(allocator);
    try guestPackedDccSampledProbe(allocator);
    try guestComputeForwardBranchesProbe(allocator);
    try guestComputeStatusIsolationProbe(allocator, &device);
    try guestComputeSampledProbe(allocator, &device);

    for ([_][2]u32{ .{ 1, 1 }, .{ 71, 37 }, .{ 256, 129 } }) |extent| {
        const width, const height = extent;
        const pixels = try allocator.alloc(u8, try d3d12.rgbaSize(width, height));
        defer allocator.free(pixels);
        try device.renderProbe(pixels, width, height);
        for (0..height) |y| {
            for (0..width) |x| {
                const expected: [4]u8 = if (x < width / 2) .{ 0, 255, 0, 255 } else .{ 255, 0, 0, 255 };
                const offset = (y * width + x) * 4;
                if (!std.mem.eql(u8, &expected, pixels[offset..][0..4])) {
                    std.debug.print("Pixel mismatch at {d},{d}: {any}, expected {any}\n", .{ x, y, pixels[offset..][0..4], expected });
                    return error.GraphicsReadbackMismatch;
                }
            }
        }
    }
    std.debug.print("PASS native vertex/pixel shaders, depth rejection, scissor and pitched texture readback (3 extents)\n", .{});
    try guestGraphicsProbe(allocator, &device);
    if (device.validationErrors() != 0) return error.ValidationFailed;
    std.debug.print("D3D12 hardware probes passed\n", .{});
}

fn guestComputeImagesProbe(allocator: std.mem.Allocator, device: *d3d12.Device) !void {
    const formats = [_]struct { guest: rdna2.spirv.StorageImageFormat, native: u32, bytes: u32 }{
        .{ .guest = .r32_uint, .native = 42, .bytes = 4 },
        .{ .guest = .rgba8_unorm, .native = 28, .bytes = 4 },
        .{ .guest = .rgba16_float, .native = 10, .bytes = 8 },
    };
    for (formats) |format| for (0..3) |dimension| {
        const layers: u32 = if (dimension == 0) 1 else 3;
        const width = 7;
        const height = 5;
        const dim: u32 = switch (dimension) {
            0 => 1,
            1 => 5,
            else => 2,
        };
        const kernel = [_]u32{ 0xf0000f00 | (dim << 3), 0x00000400, 0xf0200f00 | (dim << 3), 0x00020400, 0xbf810000 };
        var program = try rdna2.decodeProgram(allocator, &kernel);
        defer program.deinit(allocator);
        const shader_dimension: rdna2.spirv.StorageImageDimension = switch (dimension) {
            0 => .two_d,
            1 => .two_d_array,
            else => .three_d,
        };
        var shader = try rdna2.translateProgramSpirv(allocator, &program, .{
            .stage = .compute,
            .local_size = .{ width, height, layers },
            .compute_inputs = .{ .local_invocation_id_components = 3 },
            .storage_images = &.{
                .{ .resource_sgpr = 0, .descriptor_index = 0, .format = format.guest, .dimension = shader_dimension },
                .{ .resource_sgpr = 8, .descriptor_index = 1, .format = format.guest, .dimension = shader_dimension },
            },
            .allow_control_flow_fallback = false,
        });
        defer shader.deinit(allocator);
        const source = try allocator.alloc(u8, width * height * layers * format.bytes);
        defer allocator.free(source);
        const destination = try allocator.alloc(u8, source.len);
        defer allocator.free(destination);
        const before = device.cacheStats();
        for (0..2) |pass| {
            if (format.guest == .rgba16_float) {
                for (0..source.len / 2) |i| std.mem.writeInt(u16, source[i * 2 ..][0..2], @bitCast(@as(f16, @floatFromInt((i + pass * 13) % 255))), .little);
            } else {
                for (source, 0..) |*byte, i| byte.* = @truncate(i * 31 + pass * 17);
            }
            @memset(destination, 0xcc);
            try device.dispatchImagesSpirv(shader.words, &.{}, &.{
                .{ .pixels = source.ptr, .size = source.len, .width = width, .height = height, .layers = layers, .dimension = @intCast(dimension), .format = format.native },
                .{ .pixels = destination.ptr, .size = destination.len, .width = width, .height = height, .layers = layers, .dimension = @intCast(dimension), .format = format.native, .writable = 1 },
            }, .{ 1, 1, 1 }, false);
            if (!std.mem.eql(u8, source, destination)) {
                std.debug.print("Compute image mismatch: {s}, dimension={d}, pass={d}\n", .{ @tagName(format.guest), dimension, pass });
                return error.ComputeImageMismatch;
            }
        }
        if (before.enabled != 0 and device.cacheStats().shader_hits <= before.shader_hits) return error.ComputeImageCacheMiss;
    };
    std.debug.print("PASS compute storage images: exact uint/UNORM/HDR loads and stores, 2D/array/volume, row pitches and changed-input cache hits (18 dispatches)\n", .{});
}

fn guestComputeImageLayoutProbe(allocator: std.mem.Allocator) !void {
    const Memory = struct {
        data: []u8,
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
    };
    var memory = Memory{ .data = try allocator.alloc(u8, 2 * 1024 * 1024) };
    defer allocator.free(memory.data);
    var renderer = try d3d12.Renderer.init(allocator, .{ .context = &memory, .read = Memory.read, .write = Memory.write }, false);
    defer renderer.deinit();
    for ([_]u32{ 1, 2, 5 }) |dim| for ([_]u32{ 0, 24, 27 }) |tile| for ([_]u32{ 0, 1 }) |level| {
        if (tile == 0 and level != 0) continue; // Linear layouts have one level.
        errdefer std.debug.print("Compute image layout case dim={d} tile={d} level={d}\n", .{ dim, tile, level });
        @memset(memory.data, 0x5a);
        const code = [_]u32{
            0x7e0802ff,              0x12345678, // v_mov_b32 v4, literal
            0xf0200100 | (dim << 3), 0x00000400,
            0xbf810000,
        };
        const program_address: u32 = 0x100 + dim * 256;
        @memcpy(memory.data[program_address..][0 .. code.len * 4], std.mem.sliceAsBytes(&code));
        const descriptor = [_]u32{
            0x100, // 0x10000
            (20 << 20) | (3 << 30), // R32_UINT, width=8
            1 | (7 << 14), // height=8
            0xfac | (level << 12) | (level << 16) | (tile << 20) | ((if (dim == 2) @as(u32, 10) else if (dim == 5) @as(u32, 13) else 9) << 28),
            if (dim == 1) 0 else 3,
            if (tile == 0) 0 else 2 << 4,
            0,
            0,
        };
        const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&descriptor));
        const view = try texture.subresource(@intCast(level), 0, if (dim == 5) 4 else 1);
        const expected = try allocator.dupe(u8, memory.data);
        defer allocator.free(expected);
        const offset: usize = @intCast(0x10000 + try view.sourceByteOffset(0, 0, 0, 0));
        std.mem.writeInt(u32, expected[offset..][0..4], 0x12345678, .little);
        var state = gpu.State{};
        try state.writeRegister(.shader, 0x20c, program_address >> 8);
        try state.writeRegister(.shader, 0x20d, 0);
        try state.writeRegister(.shader, 0x213, (8 << 1) | (2 << 11));
        for (descriptor, 0..) |word, i| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
        var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
        _ = try executor.execute(&.{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 1 });
        if (renderer.failure) |err| return err;
        if (!std.mem.eql(u8, expected, memory.data)) return error.ComputeImageGuestLayoutMismatch;
    };
    std.debug.print("PASS PM4 compute image stores: 15 linear/depth/color tiled 2D/array/volume views; mip and padding preservation\n", .{});
}

fn guestComputeDccVolumeProbe(allocator: std.mem.Allocator) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    const store = [_]u32{ vop1(1, 4, 255), 0x40000000, vop1(1, 5, 255), 0x40400000, vop1(1, 6, 255), 0x40800000, vop1(1, 7, 255), 0x40a00000, 0xf0200f10, 0x00000400, 0xbf810000 };
    const sample = [_]u32{ vop1(1, 0, 255), 0x3f000000, vop1(1, 1, 256), vop1(1, 2, 256), vop1(1, 3, 128), 0xf0900f10, 0x00400400, 0xe0780000, 0x80030400, 0xbf810000 };
    @memcpy(memory.data[0x100..][0..@sizeOf(@TypeOf(store))], std.mem.asBytes(&store));
    @memcpy(memory.data[0x200..][0..@sizeOf(@TypeOf(sample))], std.mem.asBytes(&sample));
    var descriptor = [_]u32{ 0x100, (71 << 20) | (3 << 30), 1 | (7 << 14), (10 << 28) | (27 << 20) | 0xfac, 7, 0, (1 << 21), 10 }; // DCC at 0xa0000.
    const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&descriptor));
    const view = try texture.subresource(0, 0, 1);
    const backing = memory.data[0x10000..][0..@intCast(texture.required_source_bytes)];
    const keys = memory.data[0xa0000..][0..d3d12.surfaces.Dcc.blockCount(backing.len)];
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, (16 << 1) | (2 << 11));
    for ([_]u32{ 0x92, 0xfff000, 1 << 24, 0, 0x1000, 0, 16, 0 }, 0..) |word, i| try state.writeRegister(.shader, 0x248 + @as(u32, @intCast(i)), word);
    const packet = gpu.pm4.Packet{ .kind = .command, .header = command(gpu.pm4.dispatch_direct, 4), .opcode = gpu.pm4.dispatch_direct, .body = &.{ 1, 1, 1, 1 } };
    for ([_]bool{ false, true }) |alpha_msb| for ([_]u8{ 0, 0x40, 0x80, 0xc0, 0xff, 0x10 }) |key| {
        errdefer std.debug.print("DCC volume case key=0x{x} alpha_msb={} backing={d} keys={d}\n", .{ key, alpha_msb, backing.len, keys.len });
        descriptor[6] = (1 << 21) | (if (alpha_msb) @as(u32, 1 << 22) else 0);
        for (descriptor, 0..) |word, i| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
        @memset(keys, key);
        var original: [4]f16 = .{ 0.25, 0.5, 0.75, 1 };
        for (0..backing.len / 8) |i| @memcpy(backing[i * 8 ..][0..8], std.mem.asBytes(&original));
        if (key != 0xff and key != 0x10) for (&original, 0..) |*channel, i| {
            channel.* = if (key & (if (i == (if (alpha_msb) @as(usize, 3) else 0)) @as(u8, 0x40) else 0x80) != 0) 1 else 0;
        };
        // Sample before the store, so uniform compressed keys are exercised.
        try state.writeRegister(.shader, 0x20c, 2);
        const expected = try allocator.dupe(u8, &memory.data);
        defer allocator.free(expected);
        const sampled: [4]f32 = .{ original[0], original[1], original[2], original[3] };
        @memcpy(expected[0x1000..][0..16], std.mem.asBytes(&sampled));
        try renderer.dispatch(&state, packet);
        if (!std.mem.eql(u8, expected, &memory.data)) return error.ComputeDccVolumeSampleMismatch;
        // A single texel store must retain the logical clear in every other
        // texel and publish uncompressed keys only after successful completion.
        for (0..backing.len / 8) |i| @memcpy(expected[0x10000 + i * 8 ..][0..8], std.mem.asBytes(&original));
        const stored: [4]f16 = .{ 2, 3, 4, 5 };
        const offset: usize = @intCast(try view.sourceByteOffset(0, 0, 0, 0));
        @memcpy(expected[0x10000 + offset ..][0..8], std.mem.asBytes(&stored));
        @memset(expected[0xa0000..][0..keys.len], 0xff);
        try state.writeRegister(.shader, 0x20c, 1);
        try renderer.dispatch(&state, packet);
        if (!std.mem.eql(u8, expected, &memory.data)) return error.ComputeDccVolumeStoreMismatch;
    };
    for ([_]bool{ false, true }) |mixed| {
        @memset(keys, if (mixed) 0xff else 0x55);
        if (mixed) keys[keys.len - 1] = 0;
        const before = try allocator.dupe(u8, &memory.data);
        defer allocator.free(before);
        try std.testing.expectError(error.CompressedColorTargetNotImplemented, renderer.dispatch(&state, packet));
        if (!std.mem.eql(u8, before, &memory.data)) return error.ComputeDccRejectionModifiedMemory;
    }
    std.debug.print("PASS DCC RGBA16_FLOAT volume: 12 sampled clears and partial stores, both alpha positions, complete texel/key preservation, unsupported/mixed-key rejection\n", .{});
}

fn guestPackedDccSampledProbe(allocator: std.mem.Allocator) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    const code = [_]u32{ vop1(1, 0, 255), 0x3f000000, vop1(1, 1, 256), vop1(1, 2, 128), 0xf0900f08, 0x00400400, 0xe0780000, 0x80030400, 0xbf810000 };
    @memcpy(memory.data[0x100..][0..@sizeOf(@TypeOf(code))], std.mem.asBytes(&code));
    var descriptor = [_]u32{ 0x100, (50 << 20) | (3 << 30), 3 << 14, (9 << 28) | (27 << 20) | 0xfac, 0, 0, 1 << 21, 10 };
    const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&descriptor));
    const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
    const keys = memory.data[0xa0000..][0..d3d12.surfaces.Dcc.blockCount(backing.len)];
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    for ([_]u32{ 0x92, 0xfff000, 1 << 24, 0, 0x1000, 0, 16, 0 }, 0..) |word, i| try state.writeRegister(.shader, 0x248 + @as(u32, @intCast(i)), word);
    const packet = gpu.pm4.Packet{ .kind = .command, .header = command(gpu.pm4.dispatch_direct, 4), .opcode = gpu.pm4.dispatch_direct, .body = &.{ 1, 1, 1, 1 } };
    for ([_]bool{ false, true }) |alpha_msb| for ([_]u8{ 0, 0x40, 0x80, 0xc0, 0xff, 0x10 }) |key| {
        descriptor[6] = (1 << 21) | (if (alpha_msb) @as(u32, 1 << 22) else 0);
        for (descriptor, 0..) |word, i| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
        const bits: u32 = 17 | (511 << 10) | (999 << 20) | (2 << 30);
        for (0..backing.len / 4) |i| std.mem.writeInt(u32, backing[i * 4 ..][0..4], bits, .little);
        @memset(keys, key);
        const before = try allocator.dupe(u8, &memory.data);
        defer allocator.free(before);
        try renderer.dispatch(&state, packet);
        for (0..4) |channel| {
            const expected: f32 = if (key == 0xff or key == 0x10)
                @as(f32, @floatFromInt((bits >> @as(u5, @intCast(channel * 10))) & (if (channel == 3) @as(u32, 3) else 1023))) / (if (channel == 3) @as(f32, 3) else 1023)
            else if (key & (if (channel == (if (alpha_msb) @as(usize, 3) else 0)) @as(u8, 0x40) else 0x80) != 0) 1 else 0;
            const actual: f32 = @bitCast(std.mem.readInt(u32, memory.data[0x1000 + channel * 4 ..][0..4], .little));
            if (@abs(actual - expected) > 0.000001) return error.PackedDccSampleMismatch;
        }
        @memcpy(before[0x1000..][0..16], memory.data[0x1000..][0..16]);
        if (!std.mem.eql(u8, before, &memory.data)) return error.PackedDccSampleChangedSource;
    };
    std.debug.print("PASS RGB10A2 DCC sampling: 12 packed/uniform/comp-to-single cases, both alpha positions, exact source and metadata preservation\n", .{});
}

fn guestComputeForwardBranchesProbe(allocator: std.mem.Allocator) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    // Two forward selections share an exit, while the third path terminates
    // separately. This needs a dispatcher but cannot revisit a guest block.
    var code = [_]u32{
        vop1(1, 1, 129), 0xbf068008, 0xbf850007,
        vop1(1, 1, 130), 0xbf068009, 0xbf850004,
        vop1(1, 1, 131), 0xe0702000, 0x80000100,
        0xbf810000,      0xe0702000, 0x80000100,
        0xbf810000,
    };
    @memcpy(memory.data[0x100..][0..@sizeOf(@TypeOf(code))], std.mem.asBytes(&code));
    var program = try rdna2.decodeProgram(allocator, &code);
    defer program.deinit(allocator);
    var translated = try rdna2.translateProgramSpirv(allocator, &program, .{
        .stage = .compute,
        .local_size = .{ 64, 1, 1 },
        .scalar_registers = &.{ .{ .register = 8, .value = 0 }, .{ .register = 9, .value = 0 } },
        .storage_buffers = &.{.{ .resource_sgpr = 0, .descriptor_index = 0, .stride = 4, .extent_bytes = 256 }},
        .allow_control_flow_fallback = false,
    });
    defer translated.deinit(allocator);
    if (!translated.used_dispatcher) return error.ComputeForwardDispatcherNotExercised;
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x207, 64);
    try state.writeRegister(.shader, 0x213, 10 << 1);
    for ([_]u32{ 0x1000, 4 << 16, 64, 0 }, 0..) |word, i| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
    const packet = gpu.pm4.Packet{ .kind = .command, .header = command(gpu.pm4.dispatch_direct, 4), .opcode = gpu.pm4.dispatch_direct, .body = &.{ 1, 1, 1, 1 } };
    for ([_][3]u32{ .{ 0, 0, 1 }, .{ 0, 1, 1 }, .{ 1, 0, 2 }, .{ 1, 1, 3 } }) |variant| {
        try state.writeRegister(.shader, 0x248, variant[0]);
        try state.writeRegister(.shader, 0x249, variant[1]);
        @memset(memory.data[0x1000..0x1100], 0xa7);
        const expected = try allocator.dupe(u8, &memory.data);
        defer allocator.free(expected);
        for (0..64) |i| std.mem.writeInt(u32, expected[0x1000 + i * 4 ..][0..4], variant[2], .little);
        try renderer.dispatch(&state, packet);
        if (!std.mem.eql(u8, expected, &memory.data)) return error.ComputeForwardDispatcherMismatch;
    }
    // An unfinished cycle must withhold its intermediate UAV stores.
    code[9] = 0xbf82fff6; // s_branch -> word 0
    @memcpy(memory.data[0x200..][0..@sizeOf(@TypeOf(code))], std.mem.asBytes(&code));
    try state.writeRegister(.shader, 0x20c, 2);
    const before = try allocator.dupe(u8, &memory.data);
    defer allocator.free(before);
    try std.testing.expectError(error.ShaderLoopBudgetExceeded, renderer.dispatch(&state, packet));
    if (!std.mem.eql(u8, before, &memory.data)) return error.RejectedComputeDispatcherWroteMemory;
    const loops = [_]u32{
        0xbe890380,    vop1(1, 1, 128), 0xbf068008,         0xbf850008,
        0xbf090809,    0xbf850006,      sop2(0, 9, 9, 129), 0xbf068209,
        0xbf850002,    vop1(1, 1, 9),   0xbf800000,         0xbf82fff8,
        vop1(1, 1, 9), 0xe0702000,      0x80000100,         0xbf810000,
    };
    @memcpy(memory.data[0x300..][0..@sizeOf(@TypeOf(loops))], std.mem.asBytes(&loops));
    try state.writeRegister(.shader, 0x20c, 3);
    for ([_]u32{ 0, 1, 64, 129, 511, 900 }) |count| {
        try state.writeRegister(.shader, 0x248, count);
        @memset(memory.data[0x1000..0x1100], 0xa7);
        const expected = try allocator.dupe(u8, &memory.data);
        defer allocator.free(expected);
        for (0..64) |i| std.mem.writeInt(u32, expected[0x1000 + i * 4 ..][0..4], count, .little);
        try renderer.dispatch(&state, packet);
        if (!std.mem.eql(u8, expected, &memory.data)) return error.ComputeCheckedLoopMismatch;
    }
    std.debug.print("PASS compute dispatchers: four forward branch paths, six finite loops, exact 64-lane stores and withheld writes on exhaustion\n", .{});
}

fn guestComputeStatusIsolationProbe(allocator: std.mem.Allocator, device: *d3d12.Device) !void {
    const code = [_]u32{ vop1(1, 0, 128), vop1(1, 1, 128), vop1(1, 4, 255), 0x12345678, 0xe0702000, 0x80000400, 0xf0200108, 0x00020400, 0xbf810000 };
    var program = try rdna2.decodeProgram(allocator, &code);
    defer program.deinit(allocator);
    try program.instructions.insertSlice(allocator, program.instructions.items.len - 1, &.{
        .{ .opcode = .s_mov_b32, .dst = .{ .kind = .m0 }, .src0 = .{ .kind = .literal_constant, .value = 0xffff }, .src_count = 1 },
        .{ .family = .ds, .opcode = .ds_write_b32, .src0 = .{ .kind = .vgpr, .reg = 0 }, .src1 = .{ .kind = .vgpr, .reg = 4 }, .src_count = 2, .gds = true },
        .{ .opcode = .s_nop },
        .{ .opcode = .s_branch, .branch_target = 7 * 8 },
    });
    for (program.instructions.items, 0..) |*inst, i| {
        inst.pc = @intCast(i * 8);
        inst.word_count = 2;
    }
    var data: [64]u8 = undefined;
    var pixels: [64]u8 = undefined;
    var gds: [64 * 1024]u8 = undefined;
    // Revisit both cache variants after a failed dispatch: status must be reset,
    // and it must never alias guest u0, image u0/space1 or the persistent GDS.
    for ([_]bool{ false, true, false, true }) |exhausted| {
        program.instructions.items[8].opcode = if (exhausted) .s_branch else .s_nop;
        var shader = try rdna2.translateProgramSpirv(allocator, &program, .{
            .stage = .compute,
            .maximum_dispatcher_iterations = 8,
            .compute_dispatcher_status = true,
            .scalarize_ballot_first = true,
            .gds_storage = true,
            .descriptor_array_length = 1,
            .storage_buffers = &.{.{ .resource_sgpr = 0, .descriptor_index = 0, .stride = 4, .extent_bytes = data.len }},
            .storage_images = &.{.{ .resource_sgpr = 8, .descriptor_index = 0, .format = .r32_uint }},
            .allow_control_flow_fallback = false,
        });
        defer shader.deinit(allocator);
        if (exhausted and !shader.used_dispatcher) return error.ComputeIsolationDispatcherNotExercised;
        @memset(&data, 0xa7);
        @memset(&pixels, 0xa7);
        @memset(&gds, 0xa7);
        const result = device.dispatchImagesSpirvChecked(shader.words, &.{ d3d12.Buffer.fromSlice(&data), d3d12.Buffer.fromSlice(&gds) }, &.{.{ .pixels = &pixels, .size = pixels.len, .width = 4, .height = 4, .format = 42, .writable = 1 }}, .{ 1, 1, 1 }, true, true);
        if (exhausted) {
            try std.testing.expectError(error.ShaderLoopBudgetExceeded, result);
        } else try result;
        const expected: u32 = if (exhausted) 0xa7a7a7a7 else 0x12345678;
        for ([_][]const u8{ &data, &pixels, &gds }, 0..) |bytes, i| {
            if (std.mem.readInt(u32, bytes[0..4], .little) != expected or !std.mem.allEqual(u8, bytes[4..], 0xa7)) {
                std.debug.print("Compute status isolation: exhausted={} resource={d} first=0x{x} expected=0x{x} tail_preserved={}\n", .{ exhausted, i, std.mem.readInt(u32, bytes[0..4], .little), expected, std.mem.allEqual(u8, bytes[4..], 0xa7) });
                return error.ComputeStatusIsolationMismatch;
            }
        }
    }
    std.debug.print("PASS compute status isolation: buffer/image/GDS writes commit only on completion, failure preserves all bytes and cached retries reset status\n", .{});
}

fn guestComputeSampledProbe(allocator: std.mem.Allocator, device: *d3d12.Device) !void {
    const code = [_]u32{ vop1(1, 8, 255), 0x3f000000, vop1(1, 9, 255), 0x3f000000, 0xf11c0108, 0x00610008, 0xe0780000, 0x80000000, vop1(1, 10, 128), vop1(1, 11, 128), 0xf0200f08, 0x0004000a, 0xbf810000 };
    var program = try rdna2.decodeProgram(allocator, &code);
    defer program.deinit(allocator);
    var shader = try rdna2.translateProgramSpirv(allocator, &program, .{
        .stage = .compute,
        .sampled_images = &.{.{ .resource_sgpr = 4, .sampler_sgpr = 12, .descriptor_index = 0 }},
        .sampled_image_array_length = 1,
        .storage_images = &.{.{ .resource_sgpr = 16, .descriptor_index = 0, .format = .rgba32_float }},
        .storage_buffers = &.{.{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = 16 }},
        .descriptor_array_length = 1,
        .allow_control_flow_fallback = false,
    });
    defer shader.deinit(allocator);
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    @memcpy(memory.data[0x100..][0..@sizeOf(@TypeOf(code))], std.mem.asBytes(&code));
    const descriptor = [_]u32{ 0x100, (22 << 20) | (1 << 30), 1 << 14, 0x90000fac, 0, 0, 0, 0 };
    const layout = try gpu.SurfaceLayout.fromImage(try gpu.resources.decodeImageDescriptor(&descriptor));
    const destination = [_]u32{ 0x200, @as(u32, @intFromEnum(rdna2.spirv.StorageImageFormat.rgba32_float)) << 20, 0, 0x90000fac, 0, 0, 0, 0 };
    const destination_texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&destination));
    const destination_view = try destination_texture.subresource(0, 0, 1);
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x213, 24 << 1);
    for ([_]u32{ 0x1000, 0, 16, 0 }, 0..) |word, i| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(i)), word);
    for (descriptor, 0..) |word, i| try state.writeRegister(.shader, 0x244 + @as(u32, @intCast(i)), word);
    for (destination, 0..) |word, i| try state.writeRegister(.shader, 0x250 + @as(u32, @intCast(i)), word);
    for (0..4) |i| try state.writeRegister(.shader, 0x24c + @as(u32, @intCast(i)), if (i == 0) 2 | (2 << 3) | (2 << 6) else 0);
    const packet = gpu.pm4.Packet{ .kind = .command, .header = command(gpu.pm4.dispatch_direct, 4), .opcode = gpu.pm4.dispatch_direct, .body = &.{ 1, 1, 1, 1 } };
    for (0..2) |pass| {
        const base: f32 = @floatFromInt(pass * 100);
        const texels = [_]f32{ base + 10, base + 20, base + 30, base + 40 };
        const expected = [_]f32{ texels[2], texels[3], texels[1], texels[0] };
        var output: [4]f32 = @splat(-1);
        var image_output: [4]f32 = @splat(-2);
        try device.dispatchResourcesSpirv(shader.words, &.{d3d12.Buffer.fromSlice(std.mem.asBytes(&output))}, &.{.{ .pixels = std.mem.asBytes(&image_output), .size = 16, .width = 1, .height = 1, .format = 2, .writable = 1 }}, &.{.{ .pixels = std.mem.sliceAsBytes(&texels).ptr, .size = 16, .width = 2, .height = 2, .format = 41 }}, .{ 1, 1, 1 }, false, false);
        if (!std.mem.eql(f32, &expected, &output) or !std.mem.eql(f32, &expected, &image_output)) return error.ComputeGatherOrderMismatch;
        try layout.tile(std.mem.sliceAsBytes(&texels), memory.data[0x10000..][0..@intCast(layout.required_source_bytes)]);
        const expected_memory = try allocator.dupe(u8, &memory.data);
        defer allocator.free(expected_memory);
        @memcpy(expected_memory[0x1000..][0..16], std.mem.sliceAsBytes(&expected));
        try destination_view.tile(std.mem.sliceAsBytes(&expected), expected_memory[0x20000..][0..@intCast(destination_view.required_source_bytes)]);
        try renderer.dispatch(&state, packet);
        if (!std.mem.eql(u8, expected_memory, &memory.data)) return error.ComputeGatherGuestMismatch;
    }
    // Sampling an image while writing its overlapping guest buffer cannot be
    // represented by two immutable snapshots. Reject without publishing data.
    try state.writeRegister(.shader, 0x240, 0x10000);
    const before = try allocator.dupe(u8, &memory.data);
    defer allocator.free(before);
    try std.testing.expectError(error.ComputeImageAliasNotImplemented, renderer.dispatch(&state, packet));
    if (!std.mem.eql(u8, before, &memory.data)) return error.ComputeSampledAliasModifiedMemory;
    // The startup downsampler gathers from a nonzero R16_FLOAT mip and writes
    // another mip in the same tiled allocation. Preserve every other texel.
    try state.writeRegister(.shader, 0x240, 0x1000);
    const mip_descriptor = [_]u32{ 0x400, (13 << 20) | (3 << 30), 15 | (63 << 14), 0x90000fac | (3 << 12) | (3 << 16) | (27 << 20), 0, 6 << 4, 0, 0 };
    var target_descriptor = mip_descriptor;
    target_descriptor[3] = (target_descriptor[3] & ~@as(u32, 0xff000)) | (4 << 12) | (4 << 16);
    const mip_texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&mip_descriptor));
    const source_mip = try mip_texture.subresource(3, 0, 1);
    const target_mip = try mip_texture.subresource(4, 0, 1);
    const backing = memory.data[0x40000..][0..@intCast(mip_texture.required_source_bytes)];
    @memset(backing, 0xa7);
    var mip_pixels: [64]f16 = undefined;
    for (&mip_pixels, 0..) |*value, i| value.* = @floatFromInt(100 + i);
    try source_mip.tile(std.mem.asBytes(&mip_pixels), backing);
    for (mip_descriptor, 0..) |word, i| try state.writeRegister(.shader, 0x244 + @as(u32, @intCast(i)), word);
    for (target_descriptor, 0..) |word, i| try state.writeRegister(.shader, 0x250 + @as(u32, @intCast(i)), word);
    const mip_expected = [_]f32{ 135, 136, 128, 127 };
    const mip_memory = try allocator.dupe(u8, &memory.data);
    defer allocator.free(mip_memory);
    @memcpy(mip_memory[0x1000..][0..16], std.mem.asBytes(&mip_expected));
    var target_pixels: [16]f16 = undefined;
    try target_mip.detile(backing, std.mem.asBytes(&target_pixels));
    target_pixels[0] = 135;
    try target_mip.tile(std.mem.asBytes(&target_pixels), mip_memory[0x40000..][0..backing.len]);
    try renderer.dispatch(&state, packet);
    if (!std.mem.eql(u8, mip_memory, &memory.data)) return error.ComputeMipGatherMismatch;
    for (mip_descriptor, 0..) |word, i| try state.writeRegister(.shader, 0x250 + @as(u32, @intCast(i)), word);
    try std.testing.expectError(error.ComputeImageAliasNotImplemented, renderer.dispatch(&state, packet));
    if (!std.mem.eql(u8, mip_memory, &memory.data)) return error.ComputeOverlappingMipModifiedMemory;
    std.debug.print("PASS compute sampled R32_FLOAT gather: native/PM4 texel order, changed-input cache reuse, complete memory reference and writable-alias rejection\n", .{});
    std.debug.print("PASS nonzero R16_FLOAT mip gather: mip 3 -> mip 4 in one tiled allocation, full backing preservation and overlapping-view rejection\n", .{});
}

fn guestWaveProbe(allocator: std.mem.Allocator, device: *d3d12.Device) !void {
    for ([_]?u32{ null, 0xffff, 0xffe0, 0x8000, 0 }) |mask| try guestWaveMaskProbe(allocator, device, mask);
    std.debug.print("PASS guest readfirstlane -> DXC SM6 -> validated DXIL: full/partial/empty EXEC masks, exact broadcast readback and cached changed input\n", .{});
}

fn guestWaveMaskProbe(allocator: std.mem.Allocator, device: *d3d12.Device, mask: ?u32) !void {
    // A partial 16-invocation wave, all active: read FIRST's dynamically loaded
    // value, not each invocation's own value. Two inputs also exercise DXIL/PSO
    // cache hits without reusing the previous dispatch's staged buffer contents.
    const kernel = [_]u32{ 0xe0302000, 0x80000100, 0xe0702000, 0x80010100, 0xbf810000 };
    var program = try rdna2.decodeProgram(allocator, &kernel);
    defer program.deinit(allocator);
    try program.instructions.insertSlice(allocator, 1, &.{
        .{ .pc = 8, .opcode = .v_readfirstlane_b32, .dst = .{ .kind = .sgpr, .reg = 8 }, .src0 = .{ .kind = .vgpr, .reg = 1 }, .src_count = 1 },
        .{ .pc = 12, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 1 }, .src0 = .{ .kind = .sgpr, .reg = 8 }, .src_count = 1 },
    });
    if (mask) |value| {
        try program.instructions.insert(allocator, 1, .{ .pc = 0, .opcode = .s_mov_b64, .dst = .{ .kind = .exec_lo }, .src0 = .{ .kind = .literal_constant, .value = value }, .src_count = 1 });
        // READFIRSTLANE writes an SGPR even under a narrowed/empty EXEC. Restore
        // all live lanes before exporting that scalar through the output UAV.
        try program.instructions.insert(allocator, 3, .{ .pc = 0, .opcode = .s_mov_b64, .dst = .{ .kind = .exec_lo }, .src0 = .{ .kind = .literal_constant, .value = 0xffff }, .src_count = 1 });
    }
    for (program.instructions.items, 0..) |*instruction, index| instruction.pc = @intCast(index * 8);
    var shader = try rdna2.translateProgramSpirv(allocator, &program, .{
        .stage = .compute,
        .local_size = .{ 16, 1, 1 },
        .wave32 = true,
        .scalarize_ballot_first = true,
        .compute_inputs = .{ .local_invocation_id_components = 1 },
        .storage_buffers = &.{
            .{ .resource_sgpr = 0, .descriptor_index = 0, .stride = 4, .extent_bytes = 64 },
            .{ .resource_sgpr = 4, .descriptor_index = 1, .stride = 4, .extent_bytes = 64 },
        },
        .descriptor_array_length = 2,
        .allow_control_flow_fallback = false,
    });
    defer shader.deinit(allocator);
    var input: [16]u32 = undefined;
    var output: [16]u32 = @splat(0xcccccccc);
    const before = device.cacheStats();
    for (0..2) |pass| {
        for (&input, 0..) |*value, index| value.* = @intCast(1000 + index * 97 + pass * 12345);
        try device.dispatchSpirv(shader.words, &.{
            d3d12.Buffer.fromSlice(std.mem.asBytes(&input)),
            d3d12.Buffer.fromSlice(std.mem.asBytes(&output)),
        }, .{ 1, 1, 1 }, false);
        const expected: u32 = if (mask) |value| (if (value != 0) input[@intCast(@ctz(value))] else 0) else input[0];
        for (output) |value| if (value != expected) {
            std.debug.print("EXEC mask={any}: got {d}, expected {d}\n", .{ mask, value, expected });
            return error.GuestWaveBroadcastMismatch;
        };
    }
    const after = device.cacheStats();
    if (before.enabled != 0 and (after.shader_hits != before.shader_hits + 1 or after.pipeline_hits != before.pipeline_hits + 1)) return error.GuestWaveCacheMiss;
}

fn guestCommandProbe(allocator: std.mem.Allocator, vertex_words: []const u32, pixel_words: []const u32) !void {
    const Memory = struct {
        data: [32768]u8 = @splat(0),
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
    };
    var memory = Memory{};
    const kernel = [_]u32{ 0xe0302000, 0x80000100, 0xe0702000, 0x80010100, 0xbf810000 };
    @memcpy(memory.data[0x100..][0..@sizeOf(@TypeOf(kernel))], std.mem.asBytes(&kernel));
    for (memory.data[0x1000..0x1100], 0..) |*byte, i| byte.* = @truncate(i *% 13 +% 7);
    var renderer = try d3d12.Renderer.init(allocator, .{ .context = &memory, .read = Memory.read, .write = Memory.write }, false);
    defer renderer.deinit();
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x20c, 1);
    try state.writeRegister(.shader, 0x20d, 0);
    try state.writeRegister(.shader, 0x207, 64);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    for ([_]u32{ 0x1000, 4 << 16, 64, 0, 0x1100, 4 << 16, 64, 0 }, 0..) |word, index| try state.writeRegister(.shader, 0x240 + @as(u32, @intCast(index)), word);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    _ = try executor.execute(&.{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 1 });
    if (!std.mem.eql(u8, memory.data[0x1000..0x1100], memory.data[0x1100..0x1200])) return error.Pm4ComputeMismatch;
    @memcpy(memory.data[0x200..][0 .. vertex_words.len * 4], std.mem.sliceAsBytes(vertex_words));
    @memcpy(memory.data[0x400..][0 .. pixel_words.len * 4], std.mem.sliceAsBytes(pixel_words));
    try state.writeRegister(.shader, 0x048, 2);
    try state.writeRegister(.shader, 0x049, 0);
    try state.writeRegister(.shader, 0x008, 4);
    try state.writeRegister(.shader, 0x009, 0);
    try state.writeRegister(.context, 0x318, 0x20); // RGBA8 at 0x2000.
    try state.writeRegister(.context, 0x390, 0);
    try state.writeRegister(.context, 0x31c, 10 << 2);
    try state.writeRegister(.context, 0x319, 8); // Pitch 72; visible width 65.
    try state.writeRegister(.context, 0x3b0, (64 << 14) | 36);
    try state.writeRegister(.context, 0x3b8, 0);
    for (0..37) |y| {
        const row = memory.data[0x2000 + y * 72 * 4 ..][0 .. 72 * 4];
        for (0..65) |x| row[x * 4 + 3] = 255;
        @memset(row[65 * 4 ..], 0xa7);
    }
    const initial = memory.data;
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    const center = 0x2000 + (18 * 72 + 32) * 4;
    if (!std.mem.eql(u8, memory.data[center..][0..4], &.{ 255, 0, 0, 255 }) or
        !std.mem.eql(u8, memory.data[0x2000..][0..4], &.{ 0, 0, 0, 255 })) return error.Pm4GraphicsMismatch;
    for (0..37) |y| {
        for (memory.data[0x2000 + (y * 72 + 65) * 4 ..][0 .. 7 * 4]) |byte| {
            if (byte != 0xa7) return error.Pm4PitchPaddingModified;
        }
    }
    const before = memory.data;
    // Color draws may leave depth/stencil tests, clears and bounds enabled
    // while both plane formats are INVALID. The draw must still execute and
    // must not touch stale depth addresses. Compare the entire guest backing.
    for ([_]bool{ false, true }) |explicit_invalid| {
        memory.data = initial;
        var invalid_planes = state;
        try invalid_planes.writeRegister(.context, 0, 3);
        try invalid_planes.writeRegister(.context, 0x200, 0x007007ff);
        if (explicit_invalid) {
            try invalid_planes.writeRegister(.context, 0x010, 0);
            try invalid_planes.writeRegister(.context, 0x011, 0);
            try invalid_planes.writeRegister(.context, 0x012, 0x10);
            try invalid_planes.writeRegister(.context, 0x014, 0x10);
            try invalid_planes.writeRegister(.context, 0x013, 0x11);
            try invalid_planes.writeRegister(.context, 0x015, 0x11);
        }
        var plane_executor = gpu.DcbExecutor{ .state = &invalid_planes, .backend = renderer.dcbBackend(), .allocator = allocator };
        _ = try plane_executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        if (!std.mem.eql(u8, &before, &memory.data)) return error.InvalidDepthPlaneChangedColorDraw;
    }
    std.debug.print("PASS color draw with invalid/unwritten depth and stencil formats, stale tests/clears/bounds and preserved backing\n", .{});
    renderer.draw_batch_limit = 8;
    const batch_backend = renderer.dcbBackend();
    for (0..7) |boundary| {
        memory.data = initial;
        for (0..3) |_| _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        if (!std.mem.eql(u8, &memory.data, &initial)) return error.BatchPublishedBeforeBoundary;
        var observed: [4]u8 = undefined;
        if (!batch_backend.vtable.read(batch_backend.context, 0x600, &observed) or renderer.pending_draws == null) return error.UnrelatedReadFlushedBatch;
        _ = try executor.execute(&.{ command(gpu.pm4.event_write, 1), 0x2f });
        if (renderer.pending_draws == null or !std.mem.eql(u8, &memory.data, &initial)) return error.CacheEventPublishedBeforeBoundary;
        // Both packet encodings order the same pending target. An acquire
        // must not publish it early; each CPU-visible boundary below must.
        _ = try executor.execute(&.{ command(gpu.pm4.acquire_mem, 6), 0x7ffff, 0xffffffff, 0xff, 0, 0, 10 });
        _ = try executor.execute(&.{ command(gpu.pm4.nop, 7) | (@as(u32, gpu.pm4.custom.acquire_mem) << 2), 0x80000000, 1, 0, 0x20, 0, 10, 0x7ffff });
        if (renderer.pending_draws == null or !std.mem.eql(u8, &memory.data, &initial)) return error.AcquirePublishedBeforeBoundary;
        switch (boundary) {
            0 => if (!batch_backend.vtable.read(batch_backend.context, center, &observed)) return error.BatchFeedbackReadFailed,
            1 => if (!batch_backend.vtable.read_wait.?(batch_backend.context, 0x600, &observed)) return error.BatchWaitFailed,
            2 => if (!batch_backend.vtable.drain_releases.?(batch_backend.context)) return error.BatchDrainFailed,
            3 => if (!batch_backend.vtable.write(batch_backend.context, 0x600, &.{ 1, 2, 3, 4 })) return error.BatchWriteFailed,
            4 => _ = try executor.execute(&.{ command(gpu.pm4.release_mem, 7), 0, 1 << 29, 0x600, 0, 0x1234, 0, 0 }),
            5 => if (!batch_backend.vtable.read_live.?(batch_backend.context, 0x600, &observed)) return error.BatchLiveReadFailed,
            6 => _ = try executor.execute(&.{ command(gpu.pm4.event_write, 3), 0x139, 0x600, 0 }),
            else => unreachable,
        }
        if (renderer.pending_draws != null or !std.mem.eql(u8, memory.data[0x2000..], before[0x2000..])) return error.BatchBoundaryImageMismatch;
        if (boundary == 4 and std.mem.readInt(u32, memory.data[0x600..][0..4], .little) != 0x1234) return error.BatchReleaseLabelMissing;
    }
    renderer.draw_batch_limit = 1;
    // Each draw has a different constant applied to both source and
    // destination. Dropping or reordering draws changes the final result.
    // Compare the complete pitched backing with immediate execution.
    var blended_state = state;
    try blended_state.writeRegister(.context, 0x1e0, (1 << 30) | 13 | (13 << 8));
    var blend_executor = gpu.DcbExecutor{ .state = &blended_state, .backend = renderer.dcbBackend(), .allocator = allocator };
    var immediate_blended: @TypeOf(memory.data) = undefined;
    for ([_]usize{ 1, 8 }) |limit| {
        renderer.draw_batch_limit = limit;
        memory.data = initial;
        const groups_before = renderer.batch_groups;
        for (0..3) |i| {
            const factor: f32 = @as(f32, @floatFromInt(i + 1)) / 8;
            for (0..4) |channel| try blended_state.writeRegister(.context, 0x105 + @as(u32, @intCast(channel)), @bitCast(factor));
            _ = try blend_executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
            _ = try blend_executor.execute(&.{ command(gpu.pm4.acquire_mem, 6), 0x7ffff, 0xffffffff, 0xff, 0, 0, 10 });
            _ = try blend_executor.execute(&.{ command(gpu.pm4.nop, 7) | (@as(u32, gpu.pm4.custom.acquire_mem) << 2), 0, 1, 0, 0x20, 0, 10, 0x7ffff });
        }
        if (limit > 1 and !std.mem.eql(u8, &memory.data, &initial)) return error.BlendedAcquirePublishedEarly;
        try renderer.flushDraws();
        if (renderer.batch_groups - groups_before != (if (limit == 1) @as(u64, 3) else 1)) return error.AcquireSplitOrderedDraws;
        if (limit == 1) {
            immediate_blended = memory.data;
            if (memory.data[center] < 100 or memory.data[center] > 150) return error.BlendedAcquireReferenceMismatch;
        } else if (!std.mem.eql(u8, &memory.data, &immediate_blended)) return error.BlendedAcquireImageMismatch;
    }
    renderer.draw_batch_limit = 1;
    memory.data = before;
    std.debug.print("PASS queued PM4 draws: standard/custom acquires preserve ordered blending; target feedback, wait/live reads, guest writes, release labels and submission drain publish completed pixels\n", .{});
    // Use the actual Raiden routing (ES program / GS USER_DATA / NGG
    // passthrough), with a deliberately stale legacy VS bank. The shader
    // consumes USER_DATA[0] at s8 and merged wave info at s3; either wrong bank
    // or missing ABI seed changes the complete raster image.
    for ([_]bool{ false, true }) |wave32| {
        const wave_info: f32 = if (wave32) 0x2020 else 0x4040;
        var merged: std.ArrayList(u32) = .empty;
        defer merged.deinit(allocator);
        // Same merged-wave prologue shape as the failed Raiden draw: unpack
        // s3, allocate primitives, narrow EXEC for primitive/vertex exports.
        try merged.appendSlice(allocator, &.{
            sop2(0x27, 107, 3, 255),   0x80008,
            sop2(0x0e, 0, 3, 255),     0xff,
            sop2(0x1e, 106, 107, 136), sop2(0x10, 124, 0, 106),
            0xbf900009,                sop2(0x03, 106, 128, 107),
            sop2(0x21, 126, 193, 106), 0xf8000141,
            0,                         sop2(0x03, 106, 128, 0),
            sop2(0x21, 126, 193, 106),
        });
        try merged.appendSlice(allocator, &.{
            vop1(0x05, 9, 3),          vop1(0x01, 10, 255),
            @bitCast(1.0 / wave_info), vop2(0x08, 9, 9, 10),
        });
        try merged.appendSlice(allocator, vertex_words[0..4]);
        try merged.appendSlice(allocator, &.{ vop1(0x01, 4, 8), vop2(0x08, 4, 4, 9) });
        try merged.appendSlice(allocator, vertex_words[6..]);
        @memcpy(memory.data[0x800..][0 .. merged.items.len * 4], std.mem.sliceAsBytes(merged.items));
        @memcpy(memory.data[0x2000..], initial[0x2000..]);
        try state.writeRegister(.shader, 0x0c8, 8);
        try state.writeRegister(.shader, 0x0c9, 0);
        try state.writeRegister(.shader, 0x08b, 2); // One GS user SGPR.
        try state.writeRegister(.shader, 0x08c, @bitCast(@as(f32, 0.75)));
        try state.writeRegister(.shader, 0x0cb, 2);
        try state.writeRegister(.shader, 0x0cc, 0); // Wrong bank yields a degenerate triangle.
        try state.writeRegister(.shader, 0x048, 0x70); // Wrong program bank cannot decode.
        try state.writeRegister(.context, 0x2d5, 0x02002000 | @as(u32, if (wave32) 1 << 22 else 0));
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        if (!std.mem.eql(u8, memory.data[0x2000..], before[0x2000..])) return error.Pm4MergedVertexAbiMismatch;
    }
    try state.writeRegister(.context, 0x2d5, 0);
    try state.writeRegister(.shader, 0x048, 2);
    // Four-vertex guest strips (DI_PT_TRISTRIP=6) must match an explicitly
    // expanded list, including the second triangle and untouched padding.
    @memcpy(memory.data[0x2000..], initial[0x2000..]);
    try state.writeRegister(.uconfig, 0x242, 6);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 4, 2 });
    const strip_image = memory.data[0x2000..].*;
    @memcpy(memory.data[0x2000..], initial[0x2000..]);
    for ([_]u16{ 0, 1, 2, 2, 1, 3 }, 0..) |index, i| std.mem.writeInt(u16, memory.data[0x600 + i * 2 ..][0..2], index, .little);
    try state.writeRegister(.uconfig, 0x242, 4);
    _ = try executor.execute(&.{ command(gpu.pm4.index_type, 1), 0, command(gpu.pm4.draw_index_2, 5), 6, 0x600, 0, 6, 0 });
    if (!std.mem.eql(u8, memory.data[0x2000..], &strip_image) or std.mem.eql(u8, &strip_image, before[0x2000..])) return error.Pm4FourVertexStripMismatch;
    // ES remains populated: switching back to legacy VS must ignore it.
    // Each indexed path must reproduce the complete auto-index image, including
    // untouched row padding. Large 32-bit values exercise signed base-vertex
    // addition; prefix values exercise INDEX_BASE + DRAW_INDEX_OFFSET_2.
    for ([_]u2{ 0, 1, 2 }) |index_type| {
        const element_bytes: usize = switch (index_type) {
            0 => 2,
            1 => 4,
            else => 1,
        };
        const base: u32 = if (index_type == 1) 70000 else 7;
        for ([_]bool{ false, true }) |with_offset| {
            @memcpy(memory.data[0x2000..], initial[0x2000..]);
            for (0..5) |i| {
                const value: u32 = if (i < 2) 99 else base + @as(u32, @intCast(i - 2));
                switch (index_type) {
                    0 => std.mem.writeInt(u16, memory.data[0x600 + i * 2 ..][0..2], @intCast(value), .little),
                    1 => std.mem.writeInt(u32, memory.data[0x600 + i * 4 ..][0..4], value, .little),
                    else => memory.data[0x600 + i] = @intCast(value),
                }
            }
            try state.writeRegister(.uconfig, 0x24a, @bitCast(-@as(i32, @intCast(base))));
            _ = try executor.execute(&.{ command(gpu.pm4.index_type, 1), index_type, command(gpu.pm4.index_base, 2), 0x600, 0 });
            const index_before = memory.data[0x600..0x620].*;
            if (with_offset) {
                _ = try executor.execute(&.{ command(gpu.pm4.draw_index_offset_2, 4), 3, 2, 3, 0 });
            } else {
                _ = try executor.execute(&.{ command(gpu.pm4.draw_index_2, 5), 3, @intCast(0x600 + 2 * element_bytes), 0, 3, 0 });
            }
            if (!std.mem.eql(u8, memory.data[0x2000..], before[0x2000..])) {
                std.debug.print("Indexed mismatch: type={d}, offset={any}, center={any}\n", .{ index_type, with_offset, memory.data[center..][0..4] });
                return error.Pm4IndexedGraphicsMismatch;
            }
            if (!std.mem.eql(u8, memory.data[0x600..0x620], &index_before)) return error.Pm4IndexDataModified;
        }
        // Fixed cut markers split two triangle strips. An 8-bit 0xff marker
        // must widen to 0xffff instead of becoming a vertex in the second strip.
        @memcpy(memory.data[0x2000..], initial[0x2000..]);
        const marker: u32 = switch (index_type) {
            0 => 0xffff,
            1 => 0xffffffff,
            else => 0xff,
        };
        for ([_]u32{ 0, 1, 2, marker, 0, 1, 2 }, 0..) |value, i| switch (index_type) {
            0 => std.mem.writeInt(u16, memory.data[0x600 + i * 2 ..][0..2], @intCast(value), .little),
            1 => std.mem.writeInt(u32, memory.data[0x600 + i * 4 ..][0..4], value, .little),
            else => memory.data[0x600 + i] = @intCast(value),
        };
        try state.writeRegister(.uconfig, 0x24a, 0);
        try state.writeRegister(.uconfig, 0x242, 6);
        try state.writeRegister(.uconfig, 0x24b, 1);
        try state.writeRegister(.context, 0x103, marker);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_2, 5), 7, 0x600, 0, 7, 0 });
        if (!std.mem.eql(u8, memory.data[0x2000..], before[0x2000..])) return error.Pm4StripRestartMismatch;
        try state.writeRegister(.uconfig, 0x242, 4);
        try state.writeRegister(.uconfig, 0x24b, 0);
    }
    for ([_]u32{ 3, 1, 0, 17, 0, 0, 0, 0 }, 0..) |value, i|
        std.mem.writeInt(u32, memory.data[0x700 + i * 4 ..][0..4], value, .little);
    _ = try executor.execute(&.{ command(gpu.pm4.set_base, 3), 1, 0x700, 0 });
    for ([_]bool{ false, true }) |multi| {
        @memcpy(memory.data[0x2000..], initial[0x2000..]);
        if (multi) {
            _ = try executor.execute(&.{ command(gpu.pm4.draw_indirect_multi, 9), 0, 0x280, 0x280, 0, 2, 0, 0, 16, 2 });
        } else {
            _ = try executor.execute(&.{ command(gpu.pm4.draw_indirect, 4), 0, 0x280, 0x280, 2 });
        }
        if (!std.mem.eql(u8, memory.data[0x2000..], before[0x2000..])) return error.Pm4IndirectAutoMismatch;
    }
    // Indirect single/multi indexed records use their own base/instance values,
    // even with stale direct state. Compare every pixel and padding byte.
    for ([_]u2{ 0, 1, 2 }) |index_type| {
        for ([_]u32{ 99, 99, 7, 8, 9 }, 0..) |value, i| switch (index_type) {
            0 => std.mem.writeInt(u16, memory.data[0x600 + i * 2 ..][0..2], @intCast(value), .little),
            1 => std.mem.writeInt(u32, memory.data[0x600 + i * 4 ..][0..4], value, .little),
            else => memory.data[0x600 + i] = @intCast(value),
        };
        for ([_]u32{ 3, 1, 2, @bitCast(@as(i32, -7)), 0, 0xdeadbeef, 0, 0, 0, 0, 0 }, 0..) |value, i|
            std.mem.writeInt(u32, memory.data[0x708 + i * 4 ..][0..4], value, .little);
        std.mem.writeInt(u32, memory.data[0x780..][0..4], 9, .little);
        _ = try executor.execute(&.{ command(gpu.pm4.set_base, 3), 1, 0x700, 0, command(gpu.pm4.index_type, 1), index_type, command(gpu.pm4.index_base, 2), 0x600, 0, command(gpu.pm4.index_buffer_size, 1), 5 });
        try state.writeRegister(.uconfig, 0x24a, 123);
        state.instance_count = 0; // Indirect records supply their own count.
        for ([_]usize{ 1, 8 }) |batch| {
            renderer.draw_batch_limit = batch;
            for ([_]u32{ 0, 2 }) |initiator| {
                @memcpy(memory.data[0x2000..], initial[0x2000..]);
                _ = try executor.execute(&.{ command(gpu.pm4.draw_index_indirect, 4), 8, 0x280, 0x280, initiator });
                try renderer.flushDraws();
                if (!std.mem.eql(u8, memory.data[0x2000..], before[0x2000..])) return error.Pm4IndirectSingleMismatch;
                @memcpy(memory.data[0x2000..], initial[0x2000..]);
                _ = try executor.execute(&.{ command(gpu.pm4.draw_index_indirect_multi, 9), 8, 0x280, 0x280, 1 << 30, 2, 0x780, 0, 24, initiator });
                try renderer.flushDraws();
                if (!std.mem.eql(u8, memory.data[0x2000..], before[0x2000..])) return error.Pm4IndirectMultiMismatch;
            }
        }
    }
    state.instance_count = 1;
    try state.writeRegister(.uconfig, 0x24a, 0);
    renderer.draw_batch_limit = 8;
    @memcpy(memory.data[0x2000..], initial[0x2000..]);
    @memset(memory.data[center..][0..4], 0);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    if (renderer.pending_draws == null) return error.Pm4IndirectHazardSetupFailed;
    // The count aliases a pending GPU color write: its initial zero must be
    // replaced by the completed pixel before the subsequent list is decoded.
    const hazards = renderer.batch_hazards;
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_indirect_multi, 9), 8, 0x280, 0x280, 1 << 30, 1, @intCast(center), 0, 24, 2 });
    try renderer.flushDraws();
    if (renderer.batch_hazards != hazards + 1 or !std.mem.eql(u8, memory.data[0x2000..], before[0x2000..])) return error.Pm4IndirectCountCoherenceMismatch;
    renderer.draw_batch_limit = 1;
    std.debug.print("PASS indirect single/multi indexed 8/16/32-bit records, signed bases, padded stride, count clamp, empty records, immediate/grouped execution and pending count coherence\n", .{});
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_2, 5), 0, 0, 0, 0, 0 });
    @memcpy(&memory.data, &before);
    try state.writeRegister(.context, 0x08f, 0); // Shader mask also suppresses writes.
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    if (!std.mem.eql(u8, &before, &memory.data)) return error.Pm4ShaderMaskMismatch;
    // A rejected operation poisons the queue; following guest labels must not
    // become visible as though all previous rendering had finished.
    const rejected = executor.execute(&.{ command(gpu.pm4.draw_index_2, 5), 2, 0x600, 0, 3, 0 });
    if (rejected) |_| return error.InvalidDrawWasAccepted else |err| if (err != error.BackendRejected) return err;
    if ((renderer.failure orelse return error.IncorrectDrawFailure) != error.IndexCountOutOfBounds) return error.IncorrectDrawFailure;
    const backend = renderer.dcbBackend();
    if (backend.vtable.write(backend.context, 0x1200, &.{ 1, 2, 3, 4 })) return error.FailedSubmissionPublishedLabel;
    std.debug.print("PASS PM4 compute/draw -> D3D12 -> guest memory, pitched target and shader mask\nPASS indexed 8/16/32-bit draws, base vertex, index offsets, strip restart and zero count; invalid bounds stop the queue\n", .{});
    std.debug.print("PASS NGG passthrough vertex routing, GS USER_DATA, wave32/wave64 system registers and stale-bank isolation\n", .{});
    std.debug.print("PASS guest topology 6 four-vertex strip equals expanded triangle list; indexed restart uses the guest enum\n", .{});
}

fn command(opcode: u8, body_words: u14) u32 {
    return 0xc0000000 | (@as(u32, body_words - 1) << 16) | (@as(u32, opcode) << 8);
}

fn vop1(op: u8, dst: u8, src: u16) u32 {
    return (@as(u32, 0x3f) << 25) | (@as(u32, dst) << 17) | (@as(u32, op) << 9) | src;
}
fn sop2(op: u7, dst: u7, src0: u8, src1: u8) u32 {
    return 0x80000000 | (@as(u32, op) << 23) | (@as(u32, dst) << 16) | (@as(u32, src1) << 8) | src0;
}
fn vop2(op: u8, dst: u8, src0: u8, src1: u8) u32 {
    return (@as(u32, op) << 25) | (@as(u32, dst) << 17) | (@as(u32, src1) << 9) | (@as(u32, src0) + 256);
}

fn guestGraphicsProbe(allocator: std.mem.Allocator, device: *d3d12.Device) !void {
    const vertex_words = [_]u32{
        vop1(0x06, 1, 261),
        vop1(0x01, 2, 255),
        0x3f800000,
        vop2(0x04, 3, 1, 2),
        vop1(0x01, 4, 255),
        0x3f400000,
        vop2(0x08, 5, 3, 4),
        vop2(0x08, 6, 3, 3),
        vop1(0x01, 7, 255),
        0xbfc00000,
        vop2(0x08, 6, 6, 7),
        vop1(0x01, 8, 255),
        0x3f400000,
        vop2(0x03, 6, 6, 8),
        vop1(0x01, 7, 128),
        vop1(0x01, 8, 255),
        0x3f800000,
        0xf80008cf,
        0x08070605,
        0xbf810000,
    };
    const pixel_words = [_]u32{
        vop1(0x01, 0, 255), 0x3f800000,
        vop1(0x01, 1, 128), vop1(0x01, 2, 128),
        vop1(0x01, 3, 255), 0x3f800000,
        0xf800080f,         0x03020100,
        0xbf810000,
    };
    var vs = try rdna2.decodeProgram(allocator, &vertex_words);
    defer vs.deinit(allocator);
    var ps = try rdna2.decodeProgram(allocator, &pixel_words);
    defer ps.deinit(allocator);
    var vertex = try rdna2.translateProgramSpirv(allocator, &vs, .{ .stage = .vertex, .vertex_index_vgpr = 5, .allow_control_flow_fallback = false });
    defer vertex.deinit(allocator);
    var fragment = try rdna2.translateProgramSpirv(allocator, &ps, .{ .stage = .fragment, .allow_control_flow_fallback = false });
    defer fragment.deinit(allocator);
    // Volume RTVs use the guest's layer output, not repeated CPU draws into
    // slice zero. Preserve first/last slice padding and reject stale retained
    // attachments when only a nonzero slice changes on the CPU.
    {
        var volume_words: std.ArrayList(u32) = .empty;
        defer volume_words.deinit(allocator);
        try volume_words.append(allocator, vop1(1, 20, 264)); // preserve InstanceIndex in v8
        try volume_words.appendSlice(allocator, vertex_words[0 .. vertex_words.len - 1]);
        try volume_words.appendSlice(allocator, &.{ 0xf80000d4, 0x00140000, 0xbf810000 }); // POS1.z = layer
        var volume_program = try rdna2.decodeProgram(allocator, volume_words.items);
        defer volume_program.deinit(allocator);
        var volume_vertex = try rdna2.translateProgramSpirv(allocator, &volume_program, .{ .stage = .vertex, .vertex_index_vgpr = 5, .layered_rendering = true, .layer_varying_location = 32, .allow_control_flow_fallback = false });
        defer volume_vertex.deinit(allocator);
        const slices = 48;
        const slice_bytes = 65 * 37 * 8;
        const volume = try allocator.alloc(u8, slice_bytes * slices);
        defer allocator.free(volume);
        @memset(volume, 0);
        var volume_draw = try d3d12.Draw.fullTarget(65, 37);
        volume_draw.color_format = 10;
        volume_draw.color_depth = slices;
        volume_draw.instance_count = slices;
        try device.drawSpirv(volume_vertex.words, fragment.words, volume_draw, volume);
        for (0..slices) |z| {
            const center = z * slice_bytes + (18 * 65 + 32) * 8;
            if (!std.mem.eql(u8, volume[center..][0..8], &.{ 0, 0x3c, 0, 0, 0, 0, 0, 0x3c }) or
                !std.mem.allEqual(u8, volume[z * slice_bytes ..][0..8], 0))
            {
                std.debug.print("Volume mismatch slice={d} center={x} corner={x}\n", .{ z, volume[center..][0..8], volume[z * slice_bytes ..][0..8] });
                return error.VolumeRenderLayerMismatch;
            }
        }
        volume_draw.write_mask = 0;
        volume[47 * slice_bytes + 10] = 0x23;
        const expected = try allocator.dupe(u8, volume);
        defer allocator.free(expected);
        try device.drawSpirv(volume_vertex.words, fragment.words, volume_draw, volume);
        if (!std.mem.eql(u8, volume, expected)) return error.VolumeAttachmentReuseMismatch;
        try device.drawSpirv(volume_vertex.words, fragment.words, volume_draw, volume);
        if (!std.mem.eql(u8, volume, expected)) return error.VolumeAttachmentReuseMismatch;
        std.debug.print("PASS layered RGBA16_FLOAT raster: all 48 slices, row padding, masked writes and nonzero-slice cache invalidation\n", .{});
        var mrt_words: std.ArrayList(u32) = .empty;
        defer mrt_words.deinit(allocator);
        try mrt_words.appendSlice(allocator, pixel_words[0 .. pixel_words.len - 1]);
        try mrt_words.appendSlice(allocator, &.{ vop1(1, 0, 128), vop1(1, 1, 242), 0xf800081f, 0x03020100, 0xbf810000 });
        var mrt_program = try rdna2.decodeProgram(allocator, mrt_words.items);
        defer mrt_program.deinit(allocator);
        var mrt = try rdna2.translateProgramSpirv(allocator, &mrt_program, .{ .stage = .fragment, .allow_control_flow_fallback = false });
        defer mrt.deinit(allocator);
        const second = try allocator.alloc(u8, volume.len);
        defer allocator.free(second);
        @memset(volume, 0);
        @memset(second, 0);
        volume_draw.write_mask = 15;
        volume_draw.extra_color_count = 1;
        volume_draw.extra_colors[0] = .{ .pixels = second.ptr, .size = second.len, .format = 10, .write_mask = 15 };
        try device.drawSpirv(volume_vertex.words, mrt.words, volume_draw, volume);
        for (0..slices) |z| {
            const center = z * slice_bytes + (18 * 65 + 32) * 8;
            if (!std.mem.eql(u8, volume[center..][0..8], &.{ 0, 0x3c, 0, 0, 0, 0, 0, 0x3c }) or
                !std.mem.eql(u8, second[center..][0..8], &.{ 0, 0, 0, 0x3c, 0, 0, 0, 0x3c })) return error.VolumeMrtMismatch;
        }
        volume_draw.write_mask = 0;
        volume_draw.extra_colors[0].write_mask = 0;
        second[47 * slice_bytes + 10] = 0x42;
        const second_expected = try allocator.dupe(u8, second);
        defer allocator.free(second_expected);
        for (0..2) |_| {
            try device.drawSpirv(volume_vertex.words, mrt.words, volume_draw, volume);
            if (!std.mem.eql(u8, second, second_expected)) return error.VolumeMrtCacheMismatch;
        }
        std.debug.print("PASS layered MRT: two independent RGBA16_FLOAT volumes, all 48 slices, masked writes and second-target cache invalidation\n", .{});
        // GTA's volume pixel shader recovers the Z slice from SPI ancillary
        // bits 16..26. Check the VS -> rasterizer -> PS path, not only writes.
        var layer_program = rdna2.Program{ .code = &.{}, .instructions = .empty };
        defer layer_program.deinit(allocator);
        try layer_program.instructions.appendSlice(allocator, &.{
            .{ .pc = 0, .opcode = .v_bfe_u32, .dst = .{ .kind = .vgpr, .reg = 0 }, .src0 = .{ .kind = .vgpr, .reg = 0 }, .src1 = .{ .kind = .integer_inline_constant, .value = 16 }, .src2 = .{ .kind = .integer_inline_constant, .value = 11 }, .src_count = 3 },
            .{ .pc = 4, .opcode = .v_cvt_f32_u32, .dst = .{ .kind = .vgpr, .reg = 0 }, .src0 = .{ .kind = .vgpr, .reg = 0 }, .src_count = 1 },
            .{ .pc = 8, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 1 }, .src0 = .{ .kind = .integer_inline_constant, .value = 0 }, .src_count = 1 },
            .{ .pc = 12, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 2 }, .src0 = .{ .kind = .integer_inline_constant, .value = 0 }, .src_count = 1 },
            .{ .pc = 16, .opcode = .v_mov_b32, .dst = .{ .kind = .vgpr, .reg = 3 }, .src0 = .{ .kind = .float_inline_constant, .value = 0x3f800000 }, .src_count = 1 },
            .{ .pc = 20, .opcode = .exp, .export_target = 0, .export_enable = 15, .src0 = .{ .kind = .vgpr, .reg = 0 }, .src1 = .{ .kind = .vgpr, .reg = 1 }, .src2 = .{ .kind = .vgpr, .reg = 2 }, .src3 = .{ .kind = .vgpr, .reg = 3 }, .src_count = 4 },
            .{ .pc = 24, .opcode = .s_endpgm },
        });
        var layer_fragment = try rdna2.translateProgramSpirv(allocator, &layer_program, .{
            .stage = .fragment,
            .layered_rendering = true,
            .layer_varying_location = 32,
            .fragment_inputs = .{ .allocated = 1 << 13, .enabled = 1 << 13 },
            .allow_control_flow_fallback = false,
        });
        defer layer_fragment.deinit(allocator);
        volume_draw.extra_color_count = 0;
        volume_draw.write_mask = 15;
        try device.drawSpirv(volume_vertex.words, layer_fragment.words, volume_draw, volume);
        for (0..slices) |z| {
            const center = z * slice_bytes + (18 * 65 + 32) * 8;
            const red: f16 = @bitCast(std.mem.readInt(u16, volume[center..][0..2], .little));
            if (red != @as(f16, @floatFromInt(z))) return error.VolumePixelLayerMismatch;
        }
        std.debug.print("PASS volume pixel shader receives the correct SPI ancillary layer for all 48 slices\n", .{});
        // An ES saves its payload in LDS, then reuses the source VGPRs before
        // returning to the copy exporter. Exercise actual DXC/FXC compilation
        // and compare all pixels against ordinary vertex exports.
        var snapshot_program = rdna2.Program{ .code = &.{}, .instructions = .empty };
        defer snapshot_program.deinit(allocator);
        for (volume_program.instructions.items) |inst| {
            if (inst.opcode != .exp and inst.opcode != .s_endpgm)
                try snapshot_program.instructions.append(allocator, inst);
        }
        var exports = [_]rdna2.spirv.NggLdsExport{
            .{ .target = 0x0c, .enable = 15, .sources = .{ .{ .kind = .vgpr, .reg = 5 }, .{ .kind = .vgpr, .reg = 6 }, .{ .kind = .vgpr, .reg = 7 }, .{ .kind = .vgpr, .reg = 8 } } },
            .{ .target = 0x0d, .enable = 4, .sources = .{ .{}, .{}, .{ .kind = .vgpr, .reg = 20 }, .{} } },
        };
        var pc: u32 = 0x100;
        for (&exports) |*record| for (record.sources, 0..) |source, component| {
            if (record.enable & (@as(u4, 1) << @intCast(component)) == 0) continue;
            record.source_pcs[component] = pc;
            try snapshot_program.instructions.append(allocator, .{ .pc = pc, .family = .ds, .opcode = .ds_write_b32, .src0 = .{ .kind = .vgpr, .reg = 0 }, .src1 = source, .src_count = 2 });
            pc += 8;
            try snapshot_program.instructions.append(allocator, .{ .pc = pc, .opcode = .v_mov_b32, .dst = source, .src0 = .{ .kind = .integer_inline_constant, .value = 0 }, .src_count = 1 });
            pc += 4;
        };
        try snapshot_program.instructions.append(allocator, .{ .pc = pc, .opcode = .s_setpc_b64, .src0 = .{ .kind = .sgpr, .reg = 6 }, .src_count = 1 });
        var snapshot_vertex = try rdna2.translateProgramSpirv(allocator, &snapshot_program, .{
            .stage = .vertex,
            .vertex_index_vgpr = 5,
            .layered_rendering = true,
            .layer_varying_location = 32,
            .ngg_lds_exports = &exports,
            .allow_control_flow_fallback = false,
        });
        defer snapshot_vertex.deinit(allocator);
        @memset(volume, 0);
        try device.drawSpirv(volume_vertex.words, layer_fragment.words, volume_draw, volume);
        const reference = try allocator.dupe(u8, volume);
        defer allocator.free(reference);
        @memset(volume, 0);
        try device.drawSpirv(snapshot_vertex.words, layer_fragment.words, volume_draw, volume);
        if (!std.mem.eql(u8, reference, volume)) return error.NggSnapshotRasterMismatch;
        std.debug.print("PASS NGG LDS snapshots preserve position/layer after VGPR reuse: all 48 slices match direct exports\n", .{});
    }
    var pixels: [65 * 37 * 4]u8 = @splat(0);
    for (0..65 * 37) |i| pixels[i * 4 + 3] = 255;
    const initial = pixels;
    var draw = try d3d12.Draw.fullTarget(65, 37);
    try device.drawSpirv(vertex.words, fragment.words, draw, &pixels);
    const center = (18 * 65 + 32) * 4;
    if (!std.mem.eql(u8, pixels[center..][0..4], &.{ 255, 0, 0, 255 }) or !std.mem.eql(u8, pixels[0..4], &.{ 0, 0, 0, 255 })) return error.GuestGraphicsMismatch;
    // A second draw with color writes masked must retain the existing image.
    const before = pixels;
    draw.write_mask = 0;
    try device.drawSpirv(vertex.words, fragment.words, draw, &pixels);
    if (!std.mem.eql(u8, &before, &pixels)) return error.GuestColorMaskMismatch;
    // Shift the procedural shader's triangle by seven vertex IDs, then undo
    // that shift with each native draw base. This catches missing/doubled base
    // constants, independently of input-assembler vertex-buffer fetches.
    var shifted_words = vertex_words;
    shifted_words[2] = @bitCast(@as(f32, 8));
    var shifted_program = try rdna2.decodeProgram(allocator, &shifted_words);
    defer shifted_program.deinit(allocator);
    var shifted = try rdna2.translateProgramSpirv(allocator, &shifted_program, .{ .stage = .vertex, .vertex_index_vgpr = 5, .allow_control_flow_fallback = false });
    defer shifted.deinit(allocator);
    draw.write_mask = 15;
    draw.first_vertex = 7;
    pixels = initial;
    try device.drawSpirv(shifted.words, fragment.words, draw, &pixels);
    if (!std.mem.eql(u8, &before, &pixels)) return error.GuestFirstVertexMismatch;
    draw.first_vertex = 0;
    draw.index_count = 3;
    draw.index_element_bytes = 2;
    draw.base_vertex = 7;
    pixels = initial;
    try device.drawIndexedSpirv(shifted.words, fragment.words, draw, &.{ 0, 0, 1, 0, 2, 0 }, &pixels);
    if (!std.mem.eql(u8, &before, &pixels)) return error.GuestPositiveBaseVertexMismatch;
    std.debug.print("PASS guest RDNA2 vertex/pixel shaders, raster output and preservation of masked target bytes\n", .{});
    std.debug.print("PASS nonzero first vertex and positive indexed base vertex\n", .{});
    try guestCommandProbe(allocator, &vertex_words, &pixel_words);
    try guestMrtProbe(allocator, &vertex_words, &pixel_words);
    try guestR8TargetProbe(allocator, &vertex_words, &pixel_words);
    try guestFloatTargetProbe(allocator, &vertex_words);
    try guestPackedTargetProbe(allocator, &vertex_words);
    try guestSurfaceProbe(allocator, &vertex_words, &pixel_words);
    try guestSrgbTargetProbe(allocator, &vertex_words, &pixel_words);
    try guestMipTargetProbe(allocator, &vertex_words, &pixel_words);
    try guestCmaskProbe(allocator, &vertex_words, &pixel_words);
    for ([_]usize{ 0, d3d12.surface_cache.Cache.default_limit }) |limit| try guestDepthProbe(allocator, &vertex_words, &pixel_words, limit);
    try guestDepthBiasProbe(allocator, &vertex_words, &pixel_words);
    try guestViewportDepthProbe(allocator, &vertex_words, &pixel_words);
    try guestVaryingProbe(allocator, &vertex_words);
    try guestMipImageProbe(allocator, &vertex_words, &pixel_words);
    try guestBc6ImageProbe(allocator, &vertex_words, &pixel_words);
    try guestVolumeImageProbe(allocator, &vertex_words, &pixel_words);
    try guestAnisotropicProbe(allocator);
    try guestFanProbe(allocator);
    try guestRectangleProbe(allocator);
    try guestStencilProbe(device, vertex.words, fragment.words);
    try guestDepthOnlyProbe(allocator, device, vertex.words, fragment.words);
    try guestCheckedLoopsProbe(allocator, device, vertex.words, fragment.words);
    try guestStencilCommandProbe(allocator, &vertex_words, &pixel_words);
    var resource_reference: [5][0x3000]u8 = undefined;
    for ([_]usize{ 0, 128 * 1024 * 1024, 32 }) |limit|
        try guestResourcesProbe(allocator, if (limit == 0) 0 else d3d12.staging.Pool.default_limit, limit, &resource_reference);
    try guestDynamicScalarsProbe(allocator, &vertex_words);
    try guestForwardBranchesProbe(allocator, &vertex_words);
    try guestBlendingProbe(allocator, &vertex_words);
    try guestCacheProbe(allocator, device, vertex.words, fragment.words);
    try guestResourcePoolProbe(allocator, device, vertex.words, fragment.words);
    try guestUploadPressureProbe(device, vertex.words, fragment.words);
    try guestAttachmentProbe(allocator, device, vertex.words, fragment.words);
    try guestBatchProbe(device, vertex.words, fragment.words);
}

fn guestDepthOnlyProbe(allocator: std.mem.Allocator, device: *d3d12.Device, vertex: []const u32, fragment: []const u32) !void {
    const count = 65 * 37;
    var null_program = try rdna2.decodeProgram(allocator, &.{ 0xf8001890, 0, 0xbf810000 });
    defer null_program.deinit(allocator);
    var null_fragment = try rdna2.translateProgramSpirv(allocator, &null_program, .{ .stage = .fragment });
    defer null_fragment.deinit(allocator);
    var kill_program = try rdna2.decodeProgram(allocator, &.{ 0xbefe0480, 0xf8001890, 0, 0xbf810000 });
    defer kill_program.deinit(allocator);
    var kill_fragment = try rdna2.translateProgramSpirv(allocator, &kill_program, .{ .stage = .fragment });
    defer kill_fragment.deinit(allocator);
    for (0..3) |mode| {
        const format: u32 = if (mode == 0) 55 else 40;
        const size = try d3d12.depthSize(65, 37, format);
        var depth: [count * 4]u8 = @splat(0xff);
        if (format == 40) for (0..count) |i| std.mem.writeInt(u32, depth[i * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
        var stencil: [count]u8 = @splat(0x27);
        var color: [count * 4]u8 = @splat(0xa7);
        const initial_depth = depth;
        const initial_stencil = stencil;
        var draw = try d3d12.Draw.fullTarget(65, 37);
        draw.write_mask = 0;
        draw.depth_format = format;
        draw.depth_write = 1;
        draw.depth_compare = 2;
        draw.scissor = .{ 7, 3, 51, 32 };
        if (mode == 2) {
            draw.stencil_pixels = &stencil;
            draw.stencil_bytes = stencil.len;
            draw.stencil = .{ .enabled = 1, .write_mask = 0x6a, .reference = 0x53, .front = .{ 1, 1, 3, 8 }, .back = .{ 1, 1, 3, 8 } };
        }
        try device.drawDepthResourcesSpirv(vertex, fragment, draw, &.{}, &.{}, &.{}, &color, depth[0..size]);
        const expected_depth = depth;
        const expected_stencil = stencil;
        if (std.mem.eql(u8, &initial_depth, &depth)) return error.DepthOnlyReferenceDidNotWrite;
        depth = initial_depth;
        stencil = initial_stencil;
        draw.color_attachment = 0;
        try device.drawDepthResourcesSpirv(vertex, null_fragment.words, draw, &.{}, &.{}, &.{}, &.{}, depth[0..size]);
        if (!std.mem.eql(u8, &depth, &expected_depth) or !std.mem.eql(u8, &stencil, &expected_stencil)) return error.DepthOnlyOutputMismatch;
        depth = initial_depth;
        stencil = initial_stencil;
        // The fragment stage must still run: killed samples cannot write depth/stencil.
        try device.drawDepthResourcesSpirv(vertex, kill_fragment.words, draw, &.{}, &.{}, &.{}, &.{}, depth[0..size]);
        if (!std.mem.eql(u8, &depth, &initial_depth) or !std.mem.eql(u8, &stencil, &initial_stencil)) return error.DepthOnlyDiscardIgnored;
        var jobs: [3]d3d12.DrawJob = @splat(.{ .vertex = vertex, .fragment = null_fragment.words, .draw = draw });
        jobs[1].fragment = kill_fragment.words;
        jobs[2].draw.depth_compare = 8;
        jobs[2].draw.scissor[0] += 9;
        for (jobs) |job| try device.drawDepthResourcesSpirv(vertex, job.fragment, job.draw, &.{}, &.{}, &.{}, &.{}, depth[0..size]);
        const batched_depth = depth;
        const batched_stencil = stencil;
        depth = initial_depth;
        stencil = initial_stencil;
        try device.drawBatchSpirv(&jobs, &.{}, depth[0..size]);
        if (!std.mem.eql(u8, &depth, &batched_depth) or !std.mem.eql(u8, &stencil, &batched_stencil)) return error.DepthOnlyBatchMismatch;
        jobs[1].draw.color_attachment = 1;
        try std.testing.expectError(error.InvalidArgument, device.drawBatchSpirv(&jobs, &.{}, depth[0..size]));
        // Revisit the color PSO after the depth-only PSO, exercising cache separation.
        draw.color_attachment = 1;
        depth = initial_depth;
        stencil = initial_stencil;
        try device.drawDepthResourcesSpirv(vertex, fragment, draw, &.{}, &.{}, &.{}, &color, depth[0..size]);
        if (!std.mem.eql(u8, &depth, &expected_depth) or !std.mem.eql(u8, &stencil, &expected_stencil) or
            !std.mem.allEqual(u8, &color, 0xa7)) return error.DepthOnlyPipelineCacheMismatch;
    }
    std.debug.print("PASS depth-only D16/D32/DSV: full reference planes, null exports, fragment discard, scissor, ordered batches and color/depth PSO separation\n", .{});
}

fn guestCheckedLoopsProbe(allocator: std.mem.Allocator, device: *d3d12.Device, vertex: []const u32, plain_fragment: []const u32) !void {
    const op = struct {
        fn s(reg: u8) rdna2.Operand {
            return .{ .kind = .sgpr, .reg = reg };
        }
        fn v(reg: u8) rdna2.Operand {
            return .{ .kind = .vgpr, .reg = reg };
        }
        fn u(value: u32) rdna2.Operand {
            return .{ .kind = .integer_inline_constant, .value = value };
        }
        fn f(value: f32) rdna2.Operand {
            return .{ .kind = .literal_constant, .value = @bitCast(value) };
        }
    };
    var program = rdna2.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(allocator);
    try program.instructions.appendSlice(allocator, &.{
        .{ .opcode = .s_mov_b32, .dst = op.s(1), .src0 = op.u(0) },
        .{ .opcode = .v_mov_b32, .dst = op.v(0), .src0 = op.f(0) },
        .{ .opcode = .v_mov_b32, .dst = op.v(1), .src0 = op.f(0.25) },
        .{ .opcode = .s_cmp_eq_u32, .src0 = op.s(0), .src1 = op.u(0) },
        .{ .opcode = .s_cbranch_scc1, .branch_target = 13 * 8 },
        .{ .opcode = .s_cmp_ge_u32, .src0 = op.s(1), .src1 = op.s(0) },
        .{ .opcode = .s_cbranch_scc1, .branch_target = 13 * 8 },
        .{ .opcode = .v_add_f32, .dst = op.v(0), .src0 = op.v(0), .src1 = op.f(1.0 / 1024.0) },
        .{ .opcode = .s_add_u32, .dst = op.s(1), .src0 = op.s(1), .src1 = op.u(1) },
        .{ .opcode = .s_cmp_eq_u32, .src0 = op.s(1), .src1 = op.u(2) },
        .{ .opcode = .s_cbranch_scc1, .branch_target = 12 * 8 },
        .{ .opcode = .v_mov_b32, .dst = op.v(2), .src0 = op.f(0) },
        .{ .opcode = .s_branch, .branch_target = 5 * 8 },
        .{ .opcode = .exp, .src0 = op.v(0), .src1 = op.v(1), .src2 = op.v(1), .src3 = op.v(1), .export_enable = 15, .export_done = true },
        .{ .opcode = .s_endpgm },
    });
    for (program.instructions.items, 0..) |*inst, i| {
        inst.pc = @intCast(i * 8);
        inst.word_count = 2;
    }
    const scalars = [_]rdna2.spirv.ScalarRegister{.{ .register = 0, .value = 0 }};
    const options = rdna2.spirv.Options{ .stage = .fragment, .allow_control_flow_fallback = false, .graphics_dispatcher_status = true, .maximum_dispatcher_iterations = 16384, .scalar_registers = &scalars, .dynamic_scalar_binding = .{ .binding = 10 } };
    var fragment = try rdna2.translateSpirv(allocator, &program, options);
    defer fragment.deinit(allocator);
    if (!fragment.used_dispatcher or fragment.used_control_flow_fallback) return error.CheckedDispatcherNotExercised;
    var exhausted_options = options;
    exhausted_options.maximum_dispatcher_iterations = 2;
    var exhausted = try rdna2.translateSpirv(allocator, &program, exhausted_options);
    defer exhausted.deinit(allocator);
    var draw = try d3d12.Draw.fullTarget(65, 37);
    draw.dynamic_scalars = 1;
    draw.check_dispatcher = 1;
    var pixels: [65 * 37 * 4]u8 = undefined;
    var reference: @TypeOf(pixels) = undefined;
    for ([_]u32{ 0, 1, 64, 129, 511, 900 }) |count| {
        var literal = rdna2.Program{ .code = &.{}, .instructions = .empty };
        defer literal.deinit(allocator);
        try literal.instructions.appendSlice(allocator, &.{
            .{ .opcode = .v_mov_b32, .dst = op.v(0), .src0 = op.f(@as(f32, @floatFromInt(count)) / 1024) },
            .{ .opcode = .v_mov_b32, .dst = op.v(1), .src0 = op.f(0.25) },
            program.instructions.items[13],
            program.instructions.items[14],
        });
        for (literal.instructions.items, 0..) |*inst, i| {
            inst.pc = @intCast(i * 8);
            inst.word_count = 2;
        }
        var expected = try rdna2.translateSpirv(allocator, &literal, .{ .stage = .fragment });
        defer expected.deinit(allocator);
        @memset(&pixels, 0xa7);
        @memset(&reference, 0xa7);
        var ordinary = draw;
        ordinary.check_dispatcher = 0;
        try device.drawSpirv(vertex, expected.words, ordinary, &reference);
        draw.scalar_values[0] = count;
        try device.drawSpirv(vertex, fragment.words, draw, &pixels);
        if (!std.mem.eql(u8, &pixels, &reference)) return error.CheckedLoopRasterMismatch;
    }
    // A later failed draw must also withhold an earlier draw's attachment writes.
    var depth: [65 * 37 * 4]u8 = @splat(0x41);
    var stencil: [65 * 37]u8 = @splat(0x72);
    const before_depth = depth;
    const before_stencil = stencil;
    draw.depth_format = 40;
    draw.depth_write = 1;
    draw.depth_compare = 8;
    draw.stencil_pixels = &stencil;
    draw.stencil_bytes = stencil.len;
    draw.stencil = .{ .enabled = 1, .write_mask = 255, .reference = 0x38, .front = .{ 1, 1, 3, 8 }, .back = .{ 1, 1, 3, 8 } };
    var ordinary = draw;
    ordinary.check_dispatcher = 0;
    var jobs = [_]d3d12.DrawJob{
        .{ .vertex = vertex, .fragment = plain_fragment, .draw = ordinary },
        .{ .vertex = vertex, .fragment = exhausted.words, .draw = draw },
    };
    @memset(&pixels, 0xa7);
    try std.testing.expectError(error.ShaderLoopBudgetExceeded, device.drawBatchSpirv(&jobs, &pixels, &depth));
    if (!std.mem.allEqual(u8, &pixels, 0xa7) or !std.mem.eql(u8, &depth, &before_depth) or !std.mem.eql(u8, &stencil, &before_stencil)) return error.ExhaustedLoopPublishedAttachments;
    jobs[1].fragment = fragment.words;
    try device.drawBatchSpirv(&jobs, &pixels, &depth);
    if (std.mem.allEqual(u8, &pixels, 0xa7) or std.mem.eql(u8, &stencil, &before_stencil)) return error.CheckedLoopRecoveryFailed;
    for (&jobs) |*job| {
        job.draw.color_attachment = 0;
        job.draw.write_mask = 0;
    }
    depth = before_depth;
    stencil = before_stencil;
    jobs[1].fragment = exhausted.words;
    try std.testing.expectError(error.ShaderLoopBudgetExceeded, device.drawBatchSpirv(&jobs, &.{}, &depth));
    if (!std.mem.eql(u8, &depth, &before_depth) or !std.mem.eql(u8, &stencil, &before_stencil)) return error.ExhaustedDepthOnlyLoopPublishedAttachments;
    jobs[1].fragment = fragment.words;
    try device.drawBatchSpirv(&jobs, &.{}, &depth);
    if (std.mem.eql(u8, &depth, &before_depth) or std.mem.eql(u8, &stencil, &before_stencil)) return error.CheckedDepthOnlyLoopRecoveryFailed;
    std.debug.print("PASS checked fragment loops: 0..900 iterations, complete reference images, exhaustion withholds all batched color/depth/stencil writes, later submission resets status\n", .{});
}

fn guestStencilProbe(device: *d3d12.Device, vertex: []const u32, fragment: []const u32) !void {
    const count = 65 * 37;
    var coverage: [count * 4]u8 = @splat(0);
    var draw = try d3d12.Draw.fullTarget(65, 37);
    draw.scissor = .{ 9, 3, 51, 31 };
    try device.drawSpirv(vertex, fragment, draw, &coverage);
    var cases: usize = 0;
    for ([_]u32{ 55, 40 }) |format| {
        var depth: [count * 4]u8 = undefined;
        var stencil: [count]u8 = undefined;
        var color: [count * 4]u8 = undefined;
        draw.depth_format = format;
        draw.stencil_pixels = &stencil;
        draw.stencil_bytes = stencil.len;
        const size = try d3d12.depthSize(65, 37, format);
        for (1..9) |op| for (0..3) |path| for ([_]u8{ 0xff, 0x35 }) |mask| {
            @memset(&color, 0);
            for (&stencil, 0..) |*s, i| s.* = @truncate(i * 17);
            const original = stencil;
            @memset(&depth, 0xff);
            if (format == 40) for (0..count) |i| std.mem.writeInt(u32, depth[i * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
            const original_depth = depth;
            draw.depth_compare = if (path == 1) 1 else 8;
            draw.stencil = .{ .enabled = 1, .write_mask = mask, .reference = 0x6a, .front = .{ 1, 1, 1, if (path == 0) 1 else 8 } };
            draw.stencil.front[path] = @intCast(op);
            draw.stencil.back = draw.stencil.front;
            try device.drawDepthResourcesSpirv(vertex, fragment, draw, &.{}, &.{}, &.{}, &color, depth[0..size]);
            if (!std.mem.eql(u8, &original_depth, &depth)) return error.StencilChangedReadOnlyDepth;
            for (original, stencil, 0..) |old, actual, i| {
                const covered = coverage[i * 4] != 0;
                const value: u8 = switch (op) {
                    1 => old,
                    2 => 0,
                    3 => 0x6a,
                    4 => old +| 1,
                    5 => old -| 1,
                    6 => ~old,
                    7 => old +% 1,
                    8 => old -% 1,
                    else => unreachable,
                };
                const expected = if (covered) (old & ~mask) | (value & mask) else old;
                if (actual != expected) {
                    std.debug.print("stencil mismatch format={d} op={d} path={d} mask={x} pixel={d} actual={x} expected={x}\n", .{ format, op, path, mask, i, actual, expected });
                    return error.StencilReadbackMismatch;
                }
                if (color[i * 4] != @as(u8, if (covered and path == 2) 255 else 0)) return error.StencilColorMismatch;
            }
            cases += 1;
        };
        // Full clears are independent of the previous scissor and color mask.
        draw.stencil = .{};
        draw.write_mask = 0;
        draw.clear_flags = 3;
        draw.clear_depth = 0.25;
        draw.clear_stencil = 0x5a;
        @memset(&color, 0x91);
        try device.drawDepthResourcesSpirv(vertex, fragment, draw, &.{}, &.{}, &.{}, &color, depth[0..size]);
        for (color) |byte| if (byte != 0x91) return error.StencilClearChangedColor;
        for (stencil) |byte| if (byte != 0x5a) return error.StencilClearMismatch;
        for (0..count) |i| {
            if (format == 55) {
                if (std.mem.readInt(u16, depth[i * 2 ..][0..2], .little) != 16384) return error.DepthStencilClearMismatch;
            } else if (std.mem.readInt(u32, depth[i * 4 ..][0..4], .little) != @as(u32, @bitCast(@as(f32, 0.25)))) return error.DepthStencilClearMismatch;
        }
        draw.clear_flags = 0;
        draw.write_mask = 15;
        draw.depth_compare = 8;
        draw.stencil = .{ .enabled = 1, .write_mask = 255, .front = .{ 1, 1, 7, 8 }, .back = .{ 1, 1, 7, 8 } };
        var jobs: [3]d3d12.DrawJob = @splat(.{ .vertex = vertex, .fragment = fragment, .draw = draw });
        for (&jobs, 0..) |*job, i| job.draw.scissor[0] += @intCast(i * 3);
        const initial = stencil;
        for (jobs) |job| try device.drawDepthResourcesSpirv(vertex, fragment, job.draw, &.{}, &.{}, &.{}, &color, depth[0..size]);
        const expected = stencil;
        stencil = initial;
        try device.drawBatchSpirv(&jobs, &color, depth[0..size]);
        if (!std.mem.eql(u8, &expected, &stencil)) return error.BatchedStencilMismatch;
        const saved_color = color;
        const saved_depth = depth;
        const saved_stencil = stencil;
        jobs[1].fragment = &.{ 0x07230203, 0x10000, 0, 1, 0, 0 };
        if (device.drawBatchSpirv(&jobs, &color, depth[0..size])) |_| return error.InvalidStencilBatchAccepted else |_| {}
        if (!std.mem.eql(u8, &saved_color, &color) or !std.mem.eql(u8, &saved_depth, &depth) or !std.mem.eql(u8, &saved_stencil, &stencil))
            return error.FailedStencilBatchPublishedPlanes;
        if (format == 55) {
            draw.depth_compare = 2;
            if (device.drawDepthResourcesSpirv(vertex, fragment, draw, &.{}, &.{}, &.{}, &color, depth[0..size])) |_| return error.UnquantizedD16StencilAccepted else |_| {}
            if (!std.mem.eql(u8, &saved_stencil, &stencil)) return error.RejectedD16StencilPublishedPixels;
        } else {
            draw.depth_write = 1;
            draw.depth_compare = 8;
            try device.drawDepthResourcesSpirv(vertex, fragment, draw, &.{}, &.{}, &.{}, &color, depth[0..size]);
            for (0..count) |i| {
                const covered = coverage[i * 4] != 0;
                const expected_depth: u32 = if (covered) 0 else std.mem.readInt(u32, saved_depth[i * 4 ..][0..4], .little);
                if (std.mem.readInt(u32, depth[i * 4 ..][0..4], .little) != expected_depth or
                    stencil[i] != saved_stencil[i] +% @as(u8, if (covered) 1 else 0)) return error.CombinedDepthStencilWriteMismatch;
            }
            draw.depth_write = 0;
        }
    }
    std.debug.print("PASS {d} native stencil cases: all operations, stencil/depth fail paths, masks, scissor preservation, D16/D32 planes, clears and ordered batches\n", .{cases});
}

fn guestStencilCommandProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.context, 0x007, 64 | (36 << 16));
    try state.writeRegister(.context, 0x010, 3 | (24 << 4) | (1 << 29)); // GFX10 depth tile, HTILE.
    try state.writeRegister(.context, 0x011, 1 | (24 << 4));
    try state.writeRegister(.context, 0x012, 0x200);
    try state.writeRegister(.context, 0x014, 0x200);
    try state.writeRegister(.context, 0x013, 0x300);
    try state.writeRegister(.context, 0x015, 0x300);
    try state.writeRegister(.context, 0x005, 0x400);
    try state.writeRegister(.context, 0x2af, 1 << 18);
    try state.writeRegister(.context, 0x00a, 0x35);
    try state.writeRegister(.context, 0x000, 2); // Stencil clear, no depth write.
    try state.writeRegister(.context, 0x200, 1 | (7 << 8));
    try state.writeRegister(.context, 0x10c, 0x00ffff00);
    const target = gpu.resources.decodeDepthTarget(&state).?;
    const htile = try gpu.HtileLayout.fromDepthTarget(target);
    const keys = memory.data[0x40000..][0..@intCast(htile.required_bytes)];
    var offset: usize = 0;
    while (offset < keys.len) : (offset += 4) std.mem.writeInt(u32, keys[offset..][0..4], 0xfffc00f0, .little);
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    renderer.draw_batch_limit = 8;
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    try state.writeRegister(.context, 0x000, 0);
    try state.writeRegister(.context, 0x10b, 8 << 4); // Increment covered stencil pixels.
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    try renderer.flushDraws();
    var stencil = try d3d12.surfaces.Staged.read(allocator, memory.access(), 0x30000, try d3d12.surfaces.stencilLayout(target, 65, 37, true));
    defer stencil.deinit();
    var depth = try d3d12.surfaces.Staged.read(allocator, memory.access(), 0x20000, try d3d12.surfaces.depthLayout(target, 65, 37, true));
    defer depth.deinit();
    for (0..65 * 37) |i| {
        const color_offset = 0x2000 + ((i / 65) * 72 + i % 65) * 4;
        const covered = memory.data[color_offset] == 255;
        if (stencil.pixels[i] != @as(u8, if (covered) 0x36 else 0x35)) return error.GuestStencilCommandMismatch;
        if (std.mem.readInt(u32, depth.pixels[i * 4 ..][0..4], .little) != 0x3f800000) return error.GuestHtileDepthLost;
    }
    if (try htile.word(keys, 0, 0, 0) != gpu.HtileLayout.expanded_depth_stencil) return error.GuestHtileNotPublished;
    // Quake II uses compress-disable rectangles with no PS or a bound null PS.
    // With tests disabled, both still materialize HTILE into BOTH planes.
    const utility_vs = [_]u32{ vop1(1, 0, 128), vop1(1, 1, 255), 0x3f800000, 0xf80008cf, 0x01000000, 0xbf810000 };
    // Oxide Room 104's NGG utility also uses logical shift, unsigned integer
    // conversion and floating multiply-add to form rectangle coordinates.
    const oxide_utility_vs = [_]u32{
        vop1(1, 0, 128),                           vop1(1, 1, 255), 0x3f800000,
        (0x16 << 25) | (3 << 17) | (5 << 9) | 129, vop1(6, 3, 259), 0xd1410003,
        242 | (259 << 9) | (243 << 18),            0xf80008cf,      0x01000000,
        0xbf810000,
    };
    try state.writeRegister(.context, 0x318, 0);
    try state.writeRegister(.context, 0x000, 0x60);
    try state.writeRegister(.context, 0x200, 0);
    const previous_color = memory.data[0x2000..0x5000].*;
    const null_ps = [_]u32{ 0xf8001890, 0, 0xbf810000 };
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(null_ps))], std.mem.asBytes(&null_ps));
    var expansion_count: u64 = 0;
    for ([_][]const u32{ &utility_vs, &oxide_utility_vs }) |utility| {
        @memcpy(memory.data[0x200..][0 .. utility.len * 4], std.mem.sliceAsBytes(utility));
        for ([_]u32{ 0, 4 }) |pixel_address| {
            try state.writeRegister(.shader, 0x008, pixel_address);
            offset = 0;
            while (offset < keys.len) : (offset += 4) std.mem.writeInt(u32, keys[offset..][0..4], 0xf0, .little);
            @memset(memory.data[0x20000..][0..depth.backing.len], 0xcd);
            @memset(memory.data[0x30000..][0..stencil.backing.len], 0xcd);
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
            expansion_count += 1;
            if (renderer.metadata_expands != expansion_count or !std.mem.eql(u8, &previous_color, memory.data[0x2000..0x5000])) return error.DepthUtilityNotExecuted;
            try depth.layout.detile(memory.data[0x20000..][0..depth.backing.len], depth.pixels);
            try stencil.layout.detile(memory.data[0x30000..][0..stencil.backing.len], stencil.pixels);
            for (depth.pixels) |byte| if (byte != 0) return error.DepthUtilityDidNotExpandDepth;
            for (stencil.pixels) |byte| if (byte != 0) return error.DepthUtilityDidNotExpandStencil;
            if (try htile.word(keys, 0, 0, 0) != gpu.HtileLayout.expanded_depth_stencil) return error.DepthUtilityDidNotExpandMetadata;
        }
    }
    // A null export following discard must not trigger full-plane expansion.
    const discard_ps = [_]u32{ 0xbefe0480, 0xf8001890, 0, 0xbf810000 };
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(discard_ps))], std.mem.asBytes(&discard_ps));
    const before_rejection = try allocator.dupe(u8, &memory.data);
    defer allocator.free(before_rejection);
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    if (renderer.draw(&state, packet)) |_| return error.FragmentDiscardIgnored else |err| if (err != error.MissingAttachment) return err;
    if (!std.mem.eql(u8, before_rejection, &memory.data)) return error.FragmentRejectionModifiedMetadata;
    try state.writeRegister(.shader, 0x008, 0);
    // A system interrupt must never be classified as harmless vertex work.
    std.mem.writeInt(u32, memory.data[0x200..][0..4], 0xbf900001, .little);
    if (renderer.draw(&state, packet)) |_| return error.VertexSystemMessageIgnored else |err| if (err != error.MissingAttachment) return err;
    // Vertex stores must not turn into metadata-only completion either.
    const storing_vs = [_]u32{ 0xe0702000, 0x80000100, 0xbf810000 };
    @memcpy(memory.data[0x200..][0..@sizeOf(@TypeOf(storing_vs))], std.mem.asBytes(&storing_vs));
    @memcpy(before_rejection, &memory.data);
    if (renderer.draw(&state, packet)) |_| return error.VertexStoreIgnored else |err| if (err != error.MissingAttachment) return err;
    if (!std.mem.eql(u8, before_rejection, &memory.data)) return error.VertexStoreRejectionModifiedMemory;
    std.debug.print("PASS PM4 stencil clear/increment, HTILE persistence, PS-less/null-PS compression-disable materialization of both planes, discard/system-message/store rejection\n", .{});
}

fn guestRectangleProbe(allocator: std.mem.Allocator) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    const vs = [_]u32{ 0xe0382000, 0x80000005, 0xe0382010, 0x80000805, 0xf80000cf, 0x03020100, 0xf8000a0f, 0x0b0a0908, 0xbf810000 };
    const ps = [_]u32{ 0xc8000000, 0xc8010001, 0xc8040100, 0xc8050101, 0xc8080200, 0xc8090201, 0xc80c0300, 0xc80d0301, 0xf800080f, 0x03020100, 0xbf810000 };
    @memcpy(memory.data[0x200..][0..@sizeOf(@TypeOf(vs))], std.mem.asBytes(&vs));
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(ps))], std.mem.asBytes(&ps));
    const vertices = [_][8]f32{
        .{ -0.75, -0.75, 0, 1, 0, 0, 0.25, 1 },
        .{ 0.75, 0.75, 0, 1, 1, 1, 0.25, 1 },
        .{ -0.75, 0.75, 0, 1, 0, 1, 0.25, 1 },
        .{ 0.75, -0.75, 0, 1, 1, 0, 0.25, 1 },
    };
    @memcpy(memory.data[0x1000..][0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.shader, 0x04b, 4 << 1);
    for ([_]u32{ 0x1000, 32 << 16, 4, 0xfac }, 0..) |word, i| try state.writeRegister(.shader, 0x04c + @as(u32, @intCast(i)), word);
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    for ([_]u32{ 0, 1, 2, 4, 5, 6 }) |raster| {
        try state.writeRegister(.context, 0x205, raster);
        try state.writeRegister(.uconfig, 0x242, 4);
        for ([_]u16{ 0, 1, 2, 2, 1, 3 }, 0..) |index, i| std.mem.writeInt(u16, memory.data[0x600 + i * 2 ..][0..2], index, .little);
        @memset(memory.data[0x2000..0x5000], 0xa7);
        _ = try executor.execute(&.{ command(gpu.pm4.index_type, 1), 0, command(gpu.pm4.draw_index_2, 5), 6, 0x600, 0, 6, 0 });
        const expected = memory.data[0x2000..0x5000].*;
        @memset(memory.data[0x2000..0x5000], 0xa7);
        try state.writeRegister(.uconfig, 0x242, 7);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        if (!std.mem.eql(u8, &expected, memory.data[0x2000..0x5000])) return error.RectangleImageMismatch;
    }
    // NGG auto rectangles invoke a fourth guest vertex, including attributes
    // that cannot be recovered by affine completion of the first three.
    var ngg_vs = vs;
    ngg_vs[1] = 0x80020005;
    ngg_vs[3] = 0x80020805;
    @memcpy(memory.data[0x200..][0..@sizeOf(@TypeOf(ngg_vs))], std.mem.asBytes(&ngg_vs));
    var strip_vertices = [4][8]f32{ vertices[0], vertices[3], vertices[2], vertices[1] };
    strip_vertices[3][6] = 0.875;
    @memcpy(memory.data[0x1000..][0..@sizeOf(@TypeOf(strip_vertices))], std.mem.asBytes(&strip_vertices));
    try state.writeRegister(.context, 0x2d5, 0x02002000);
    try state.writeRegister(.context, 0x205, 0);
    try state.writeRegister(.shader, 0x0c8, 2);
    try state.writeRegister(.shader, 0x0c9, 0);
    try state.writeRegister(.shader, 0x08b, 4 << 1);
    for ([_]u32{ 0x1000, 32 << 16, 4, 0xfac }, 0..) |word, i| try state.writeRegister(.shader, 0x08c + @as(u32, @intCast(i)), word);
    @memset(memory.data[0x2000..0x5000], 0xa7);
    try state.writeRegister(.uconfig, 0x242, 6);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 4, 2 });
    const expected_ngg = memory.data[0x2000..0x5000].*;
    for ([_]u32{ 1, 3, 4 }) |count| {
        @memset(memory.data[0x2000..0x5000], 0xa7);
        try state.writeRegister(.uconfig, 0x242, 7);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), count, 2 });
        if (!std.mem.eql(u8, &expected_ngg, memory.data[0x2000..0x5000])) return error.NggRectangleFourthInvocationLost;
    }
    // Dreaming Sarah uses the legacy DI_PT value 17 with the same merged
    // export shader convention. A GS approximation would lose the deliberately
    // non-affine fourth vertex attribute tested above.
    try state.writeRegister(.uconfig, 0x242, 17);
    for ([_]u32{ 3, 4 }) |count| {
        @memset(memory.data[0x2000..0x5000], 0xa7);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), count, 2 });
        if (!std.mem.eql(u8, &expected_ngg, memory.data[0x2000..0x5000])) return error.LegacyNggRectangleImageMismatch;
    }
    @memset(memory.data[0x2000..0x5000], 0xa7);
    const unchanged = memory.data[0x2000..0x5000].*;
    const invalid_count: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 1, 2 } };
    if (renderer.draw(&state, invalid_count)) |_| return error.LegacyRectangleInvalidCountAccepted else |err| {
        if (err != error.UnsupportedNggRectangleCount) return err;
    }
    const indexed: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_2, 5), .opcode = gpu.pm4.draw_index_2, .body = &.{ 3, 0x600, 0, 3, 0 } };
    if (renderer.draw(&state, indexed)) |_| return error.LegacyRectangleIndexedDrawAccepted else |err| {
        if (err != error.UnsupportedLegacyRectangleDraw) return err;
    }
    if (!std.mem.eql(u8, &unchanged, memory.data[0x2000..0x5000])) return error.RejectedLegacyRectangleModifiedTarget;
    std.debug.print("PASS RECT_LIST: legacy completion matches two explicit triangles; NGG type 7 (1/3/4) and type 17 (3/4) preserve the fourth guest invocation; unsupported legacy forms leave targets unchanged\n", .{});
}

fn guestBatchProbe(device: *d3d12.Device, vertex: []const u32, fragment: []const u32) !void {
    const saved_pool = device.resourceStats().limit;
    defer device.resourcePoolLimit(saved_pool) catch {};
    for ([_]u64{ 0, 256 * 1024 * 1024, 256 * 1024 }) |budget| {
        try device.resourcePoolLimit(budget);
        for (0..6) |variant| {
            const width: u32 = if (variant % 2 == 0) 65 else 128;
            const height: u32 = 37;
            var initial_color: [128 * 37 * 4]u8 = undefined;
            for (&initial_color, 0..) |*byte, i| byte.* = @truncate(i *% 37 + variant *% 19);
            var initial_depth: [128 * 37 * 4]u8 = @splat(0xff);
            const format: u32 = ([_]u32{ 0, 55, 40 })[variant / 2];
            if (format == 40) for (0..initial_depth.len / 4) |i| std.mem.writeInt(u32, initial_depth[i * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
            const color_size = width * height * 4;
            const depth_size = try d3d12.depthSize(width, height, format);
            var jobs: [8]d3d12.DrawJob = undefined;
            for (&jobs, 0..) |*job, i| {
                var draw = try d3d12.Draw.fullTarget(width, height);
                draw.depth_format = format;
                draw.depth_write = @intFromBool(format != 0 and i % 3 == 1);
                draw.depth_compare = if (i % 2 == 0) 4 else 2;
                draw.scissor[0] = @intCast(i * 3);
                draw.scissor[2] -= @intCast(i);
                draw.write_mask = @intCast(1 + i % 7);
                draw.blend.enabled = 1;
                draw.blend.source_color = 14; // Per-draw blend factor.
                draw.blend.destination_color = 15;
                draw.blend.constants = @splat(@as(f32, @floatFromInt(i + 1)) / 9);
                job.* = .{ .vertex = vertex, .fragment = fragment, .draw = draw };
            }
            for (1..9) |count| {
                var sequential = initial_color;
                var reference_depth = initial_depth;
                for (jobs[0..count]) |job| try device.drawDepthResourcesSpirv(job.vertex, job.fragment, job.draw, &.{}, &.{}, &.{}, sequential[0..color_size], reference_depth[0..depth_size]);
                var batched = initial_color;
                var depth = initial_depth;
                try device.drawBatchSpirv(jobs[0..count], batched[0..color_size], depth[0..depth_size]);
                if (!std.mem.eql(u8, &sequential, &batched) or !std.mem.eql(u8, &reference_depth, &depth)) return error.NativeBatchImageMismatch;
            }
            var output = initial_color;
            var depth = initial_depth;
            const good = jobs[1];
            // Structurally valid SPIR-V header, malformed shader body: fail in
            // native compilation after the first draw has been recorded.
            jobs[1].fragment = &.{ 0x07230203, 0x10000, 0, 1, 0, 0 };
            if (device.drawBatchSpirv(jobs[0..2], output[0..color_size], depth[0..depth_size])) |_| return error.InvalidBatchShaderAccepted else |_| {}
            if (!std.mem.eql(u8, &initial_color, &output) or !std.mem.eql(u8, &initial_depth, &depth)) return error.FailedBatchPublishedPixels;
            jobs[1] = good;
            try device.drawBatchSpirv(jobs[0..2], output[0..color_size], depth[0..depth_size]);
            if (device.resourceStats().bytes > budget) return error.BatchPoolBudgetExceeded;
        }
    }
    // A full group may hold 1,536 small input resources concurrently. It
    // must not thrash the object slots while well below the byte budget.
    try device.resourcePoolLimit(256 * 1024 * 1024);
    const cache_enabled = device.cacheStats().enabled != 0;
    defer device.cacheLimits(if (cache_enabled) 256 else 0, if (cache_enabled) 512 else 0) catch {};
    try device.cacheLimits(2, 2); // Evict PSOs while earlier recorded draws own refs.
    var data: [8][256]u8 = undefined;
    var buffers: [8][64]d3d12.Buffer = undefined;
    var images: [8][32]d3d12.SampledImage = undefined;
    var jobs: [8]d3d12.DrawJob = undefined;
    for (&jobs, 0..) |*job, i| {
        @memset(&data[i], @intCast(i + 0x53));
        buffers[i] = @splat(d3d12.Buffer.fromSlice(&data[i]));
        images[i] = @splat(.{ .pixels = &data[i], .size = data[i].len, .width = 8, .height = 8 });
        var draw = try d3d12.Draw.fullTarget(65, 37);
        draw.write_mask = @intCast(i + 1);
        job.* = .{ .vertex = vertex, .fragment = fragment, .draw = draw, .buffers = &buffers[i], .images = &images[i] };
    }
    var color: [65 * 37 * 4]u8 = @splat(0);
    try device.drawBatchSpirv(&jobs, &color, &.{});
    const reference = color;
    const warm = device.resourceStats();
    @memset(&color, 0);
    try device.drawBatchSpirv(&jobs, &color, &.{});
    const after = device.resourceStats();
    if (!std.mem.eql(u8, &color, &reference) or warm.entries <= 256 or after.entries > 2048 or
        after.bytes > 256 * 1024 * 1024 or after.misses != warm.misses or after.bypasses != warm.bypasses) return error.BatchCapacityThrashing;
    std.debug.print("PASS full batch occupancy: {d} resources / {d} KiB, zero warm allocations/bypasses, PSO eviction preserves recorded object lifetime\n", .{ after.entries, after.bytes / 1024 });
    // Longer groups must preserve rendering and reuse immutable inputs.
    var long_jobs: [d3d12.max_draw_batch]d3d12.DrawJob = undefined;
    var sequential: [65 * 37 * 4]u8 = @splat(0);
    for (&long_jobs, 0..) |*job, i| {
        job.* = jobs[i % jobs.len];
        try device.drawDepthResourcesSpirv(job.vertex, job.fragment, job.draw, &.{}, job.buffers, job.images, &sequential, &.{});
    }
    @memset(&color, 0);
    try device.drawBatchSpirv(&long_jobs, &color, &.{});
    if (!std.mem.eql(u8, &sequential, &color)) return error.LongBatchImageMismatch;
    std.debug.print("PASS 64-draw group: repeated immutable inputs, complete output matches sequential rendering\n", .{});
    std.debug.print("PASS batched graphics: 144 full color/depth comparisons, 1..8 draws, D16/D32, read/write depth, padded/contiguous rows, blend/scissor/mask changes, pool pressure and recovery after invalid second shader\n", .{});
}

fn guestAttachmentProbe(allocator: std.mem.Allocator, device: *d3d12.Device, vertex: []const u32, fragment: []const u32) !void {
    const saved_pool = device.resourceStats().limit;
    const saved_enabled = device.attachmentStats().enabled != 0;
    defer device.resourcePoolLimit(saved_pool) catch {};
    defer device.attachmentCache(saved_enabled) catch {};
    const max_bytes = 128 * 39 * 4;
    const reference = try allocator.alloc([max_bytes * 2]u8, 6 * 8);
    defer allocator.free(reference);
    for ([_]u64{ 256 * 1024 * 1024, 256 * 1024 * 1024, 256 * 1024 }, 0..) |budget, pass| {
        try device.resourcePoolLimit(budget);
        try device.attachmentCache(pass != 0);
        const before = device.attachmentStats();
        for (0..6) |variant| {
            const width: u32 = if (variant % 2 == 0) 65 else 128;
            const height: u32 = if (variant % 2 == 0) 37 else 39;
            const bytes = width * height * 4;
            var color: [max_bytes]u8 = undefined;
            var depth: [max_bytes]u8 = @splat(0x6d);
            for (&color, 0..) |*byte, i| byte.* = @truncate(i *% 47 + variant *% 19);
            var draw = try d3d12.Draw.fullTarget(width, height);
            draw.depth_format = ([_]u32{ 0, 55, 40 })[variant / 2];
            draw.depth_compare = 4; // LESS_EQUAL: preserved results remain visible.
            const depth_bytes: usize = if (draw.depth_format == 0) 0 else if (draw.depth_format == 55) bytes / 2 else bytes;
            if (draw.depth_format == 55) @memset(depth[0..depth_bytes], 0xff);
            if (draw.depth_format == 40) for (0..depth_bytes / 4) |i| std.mem.writeInt(u32, depth[i * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
            for (0..8) |step| {
                draw.depth_write = @intFromBool(draw.depth_format != 0 and step != 5 and step != 6);
                draw.write_mask = if (step % 2 == 0) 15 else 5;
                draw.scissor[2] = @intCast(width - step % 3);
                if (step == 3) {
                    color[bytes - 1] ^= 0x7f;
                    color[(height / 2 * width + width / 2) * 4] ^= 0xc3;
                }
                if (step == 4 and depth_bytes != 0) @memset(depth[depth_bytes - (if (draw.depth_format == 55) @as(usize, 2) else 4) .. depth_bytes], 0);
                if (step == 7) {
                    // A differently shaped draw can borrow the same capacity-
                    // class readback. Its old pair must no longer prove content.
                    var scratch: [66 * 36 * 4]u8 = @splat(0x17);
                    try device.drawSpirv(vertex, fragment, try d3d12.Draw.fullTarget(66, 36), &scratch);
                }
                const depth_before = depth;
                try device.drawDepthResourcesSpirv(vertex, fragment, draw, &.{}, &.{}, &.{}, color[0..bytes], depth[0..depth_bytes]);
                if (draw.depth_write == 0 and !std.mem.eql(u8, &depth_before, &depth)) return error.RetainedReadOnlyDepthChanged;
                const record = &reference[variant * 8 + step];
                if (pass == 0) {
                    @memcpy(record[0..max_bytes], &color);
                    @memcpy(record[max_bytes..], &depth);
                } else if (!std.mem.eql(u8, record[0..max_bytes], &color) or !std.mem.eql(u8, record[max_bytes..], &depth)) return error.RetainedAttachmentImageMismatch;
                if (device.resourceStats().bytes > budget) return error.RetainedAttachmentBudgetExceeded;
            }
        }
        const after = device.attachmentStats();
        if (pass == 0 and (after.color_hits != before.color_hits or after.depth_hits != before.depth_hits)) return error.DisabledAttachmentHit;
        if (pass == 1 and (after.color_hits == before.color_hits or after.depth_hits == before.depth_hits or after.pairs == 0)) return error.AttachmentRetentionNotExercised;
        try device.resourcePoolLimit(budget);
        if (device.attachmentStats().pairs != 0) return error.StaleAttachmentPairAfterEviction;
        std.debug.print("PASS retained attachments pass={d} pool_kib={d}: color hits={d}, depth hits={d}, avoided={d} bytes; all 48 padded/contiguous color/depth results match\n", .{
            pass, budget / 1024, after.color_hits - before.color_hits, after.depth_hits - before.depth_hits, after.avoided_bytes - before.avoided_bytes,
        });
    }
}

fn guestUploadPressureProbe(device: *d3d12.Device, vertex: []const u32, fragment: []const u32) !void {
    const saved_limit = device.uploadStats().limit;
    defer device.uploadCacheLimit(saved_limit) catch {};
    var color: [65 * 37 * 4]u8 = undefined;
    var pixels: [16]u8 = @splat(0x7f);
    try device.uploadCacheLimit(128 * 1024 * 1024);
    const alternating_before = device.uploadStats();
    for (0..6) |i| {
        @memset(&pixels, @intCast(i % 3 * 83 + 5));
        @memset(&color, 0);
        const image = d3d12.SampledImage{ .pixels = &pixels, .size = pixels.len, .width = 2, .height = 2 };
        try device.drawResourcesSpirv(vertex, fragment, try d3d12.Draw.fullTarget(65, 37), &.{}, &.{}, &.{image}, &color);
    }
    const alternating_after = device.uploadStats();
    if (alternating_after.misses != alternating_before.misses + 3 or
        alternating_after.image_hits != alternating_before.image_hits + 3) return error.AlternatingUploadContentsNotRetained;
    try device.uploadCacheLimit(32);
    const before = device.uploadStats();
    const original = pixels;
    // Different descriptions retain three GPU objects but only two CPU proofs
    // fit. No busy proof is an eviction candidate; a later draw may evict idle ones.
    for ([_][2]u32{ .{ 1, 4 }, .{ 2, 2 }, .{ 4, 1 }, .{ 1, 4 } }) |extent| {
        @memset(&color, 0);
        const image = d3d12.SampledImage{ .pixels = &pixels, .size = pixels.len, .width = extent[0], .height = extent[1] };
        try device.drawResourcesSpirv(vertex, fragment, try d3d12.Draw.fullTarget(65, 37), &.{}, &.{}, &.{image}, &color);
        if (device.uploadStats().bytes > 32) return error.UploadCacheBudgetExceeded;
        if (!std.mem.eql(u8, color[(18 * 65 + 32) * 4 ..][0..4], &.{ 255, 0, 0, 255 })) return error.UploadPressureDrawMismatch;
        if (!std.mem.eql(u8, &pixels, &original)) return error.UploadPressureModifiedSource;
    }
    if (device.uploadStats().evictions == before.evictions) return error.UploadCacheEvictionNotExercised;
    try device.resourcePoolLimit(device.resourceStats().limit);
    if (device.uploadStats().bytes != 0) return error.PoolEvictionLeakedUploadSnapshots;
    std.debug.print("PASS alternating image-content retention and upload snapshot LRU pressure: same pointer/shape with three contents, distinct shapes, 32-byte budget, unchanged source and GPU-pool eviction cleanup\n", .{});
}

fn guestResourcePoolProbe(allocator: std.mem.Allocator, device: *d3d12.Device, vertex: []const u32, fragment: []const u32) !void {
    const saved_limit = device.resourceStats().limit;
    defer device.resourcePoolLimit(saved_limit) catch {};
    const max_bytes = 71 * 39 * 4;
    const cases = 24;
    const reference = try allocator.alloc([max_bytes * 2]u8, cases);
    defer allocator.free(reference);
    // Every pass starts with independently changed guest bytes. Small budgets
    // exercise both LRU eviction and a draw with more live storage than fits.
    for ([_]u64{ 0, 256 * 1024 * 1024, 256 * 1024 }, 0..) |limit, pass| {
        try device.resourcePoolLimit(limit);
        const before = device.resourceStats();
        for (0..cases) |variant| {
            const width: u32 = if (variant % 4 < 2) 65 else 71;
            const height: u32 = if (variant % 4 < 2) 37 else 39;
            const bytes = width * height * 4;
            var color: [max_bytes]u8 = undefined;
            for (&color, 0..) |*byte, i| byte.* = @truncate(i *% 37 + variant *% 17);
            var depth: [max_bytes]u8 = undefined;
            var draw = try d3d12.Draw.fullTarget(width, height);
            draw.dynamic_scalars = 1;
            draw.scalar_values = @splat(@intCast(variant));
            draw.depth_format = switch (variant % 6) {
                0, 1 => 0,
                2, 3 => 55,
                else => 40,
            };
            draw.depth_write = @intFromBool(draw.depth_format != 0 and variant % 2 != 0);
            draw.depth_compare = 2;
            const depth_bytes: usize = if (draw.depth_format == 0) 0 else if (draw.depth_format == 55) bytes / 2 else bytes;
            @memset(&depth, 0);
            if (draw.depth_format == 55) @memset(depth[0..depth_bytes], 0xff);
            if (draw.depth_format == 40) for (0..depth_bytes / 4) |i| std.mem.writeInt(u32, depth[i * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
            draw.scissor[2] -= @intCast(variant % 7);
            draw.write_mask = @intCast(1 + variant % 15);
            draw.index_count = 3;
            draw.index_element_bytes = 2;
            const indices = [3]u16{ 0, 1, 2 };
            var buffer_bytes: [3][512]u8 = undefined;
            var buffers: [3]d3d12.Buffer = undefined;
            for (&buffer_bytes, 0..) |*data, i| {
                @memset(data, @intCast(variant + i * 31));
                const size = (if (variant % 4 < 2) @as(usize, 128) else 384) + variant % 16 * 4;
                buffers[i] = d3d12.Buffer.fromSlice(data[0..size]);
            }
            const source_copy = buffer_bytes;
            var image_pixels: [2][8 * 8 * 4]u8 = undefined;
            var images: [2]d3d12.SampledImage = undefined;
            for (&image_pixels, 0..) |*data, i| {
                @memset(data, @intCast(variant + i * 83));
                images[i] = .{ .pixels = data, .size = data.len, .width = 8, .height = 8 };
            }
            const image_copy = image_pixels;
            try device.drawDepthResourcesSpirv(vertex, fragment, draw, std.mem.asBytes(&indices), &buffers, &images, color[0..bytes], depth[0..depth_bytes]);
            if (!std.mem.eql(u8, std.mem.asBytes(&source_copy), std.mem.asBytes(&buffer_bytes)) or
                !std.mem.eql(u8, std.mem.asBytes(&image_copy), std.mem.asBytes(&image_pixels))) return error.ResourcePoolModifiedSource;
            if (pass == 0) {
                @memcpy(reference[variant][0..max_bytes], &color);
                @memcpy(reference[variant][max_bytes..], &depth);
            } else if (!std.mem.eql(u8, reference[variant][0..max_bytes], &color) or
                !std.mem.eql(u8, reference[variant][max_bytes..], &depth)) return error.ResourcePoolImageMismatch;
            const stats = device.resourceStats();
            if (stats.bytes > limit or stats.entries > 2048) return error.ResourcePoolBudgetExceeded;
        }
        const after = device.resourceStats();
        if (pass == 1 and after.hits == before.hits) return error.ResourcePoolNotReused;
        if (pass == 2 and (after.evictions == before.evictions or after.bypasses == before.bypasses)) return error.ResourcePoolPressureNotExercised;
    }
    // Warm native allocation timing, not a game-FPS benchmark.
    for ([_]u64{ 0, 256 * 1024 * 1024 }) |limit| {
        try device.resourcePoolLimit(limit);
        var pixels: [65 * 37 * 4]u8 = @splat(0);
        const draw = try d3d12.Draw.fullTarget(65, 37);
        try device.drawSpirv(vertex, fragment, draw, &pixels);
        const before = device.resourceStats();
        const started = gpu.frame_timing.timestampNs();
        for (0..32) |_| {
            @memset(&pixels, 0);
            try device.drawSpirv(vertex, fragment, draw, &pixels);
            if (!std.mem.eql(u8, pixels[(18 * 65 + 32) * 4 ..][0..4], &.{ 255, 0, 0, 255 })) return error.ResourcePoolBenchmarkMismatch;
        }
        const elapsed = gpu.frame_timing.timestampNs() - started;
        const after = device.resourceStats();
        if (limit != 0 and (after.misses != before.misses or after.hits != before.hits + 32 * 3)) return error.ResourcePoolWarmAllocation;
        std.debug.print("D3D12 resource-pool probe: limit_kib={d} draws=32 total_us={d} hit={d} miss={d}\n", .{
            limit / 1024, elapsed / std.time.ns_per_us, after.hits - before.hits, after.misses - before.misses,
        });
    }
    std.debug.print("PASS resource pooling: 24 full color/depth references across disabled/normal/256KiB budgets, changed extents/formats/bytes, simultaneous equal-size leases, eviction/bypass and zero warm allocations\n", .{});
}

fn guestForwardBranchesProbe(allocator: std.mem.Allocator, vertex_words: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    @memcpy(memory.data[0x200..][0 .. vertex_words.len * 4], std.mem.sliceAsBytes(vertex_words));
    const branches = [_]u32{
        vop1(1, 0, 255), 0x3f800000, vop1(1, 1, 128), vop1(1, 2, 128), vop1(1, 3, 255), 0x3f800000,
        0xbf068000, // s_cmp_eq_u32 s0, 0
        0xbf85000c, // s_cbranch_scc1 -> shared export (word 20)
        vop1(1, 0, 128),
        vop1(1, 1, 255),
        0x3f800000,
        0xbf068001, // s_cmp_eq_u32 s1, 0
        0xbf850007, // s_cbranch_scc1 -> shared export
        vop1(1, 1, 128),
        vop1(1, 2, 255),
        0x3f800000,
        0xbefe0480, // s_mov_b64 exec, 0
        0xf8001890, // Null EXP.VM: terminal path discards its pixels.
        0,
        0xbf810000,
        0xf800180f, // EXP.VM publishes live pixels.
        0x03020100,
        0xbf810000,
    };
    var program = try rdna2.decodeProgram(allocator, &branches);
    defer program.deinit(allocator);
    const scalars = [_]rdna2.spirv.ScalarRegister{ .{ .register = 0, .value = 0 }, .{ .register = 1, .value = 0 } };
    var translated = try rdna2.translateProgramSpirv(allocator, &program, .{ .stage = .fragment, .scalar_registers = &scalars, .dynamic_scalar_binding = .{ .binding = 10 }, .allow_control_flow_fallback = false });
    defer translated.deinit(allocator);
    if (!translated.used_dispatcher) return error.ForwardDispatcherProbeNotExercised;
    try state.writeRegister(.shader, 0x00b, 4);
    const target = memory.data[0x2000..][0 .. 72 * 37 * 4];
    var references: [2][72 * 37 * 4]u8 = undefined;
    for (0..2) |component| {
        var literal = [_]u32{ vop1(1, 0, 128), vop1(1, 1, 128), vop1(1, 2, 128), vop1(1, 3, 242), 0xf800080f, 0x03020100, 0xbf810000 };
        literal[component] = vop1(1, @intCast(component), 242); // inline 1.0
        @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(literal))], std.mem.asBytes(&literal));
        @memset(target, 0xa7);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        @memcpy(&references[component], target);
    }
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(branches))], std.mem.asBytes(&branches));
    for ([_][2]u32{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 } }, 0..) |inputs, variant| {
        try state.writeRegister(.shader, 0x00c, inputs[0]);
        try state.writeRegister(.shader, 0x00d, inputs[1]);
        @memset(target, 0xa7);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        if (variant == 3) {
            if (!std.mem.allEqual(u8, target, 0xa7)) return error.TerminalDispatcherModifiedTarget;
        } else if (!std.mem.eql(u8, target, &references[if (variant == 2) 1 else 0])) return error.ForwardDispatcherRasterMismatch;
    }
    std.debug.print("PASS forward-only dispatcher: nested terminal selections, dynamic conditions and complete literal-reference images\n", .{});
}

fn guestDynamicScalarsProbe(allocator: std.mem.Allocator, vertex_words: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    var reference: [8][72 * 37 * 4]u8 = undefined;
    const target = memory.data[0x2000..][0..reference[0].len];
    const vertex = try allocator.dupe(u32, vertex_words);
    defer allocator.free(vertex);
    var dynamic_vertex: std.ArrayList(u32) = .empty;
    defer dynamic_vertex.deinit(allocator);
    try dynamic_vertex.appendSlice(allocator, vertex_words[0..1]);
    try dynamic_vertex.append(allocator, vop1(0x01, 2, 0)); // VS s0 replaces a literal position offset.
    try dynamic_vertex.appendSlice(allocator, vertex_words[3..]);
    const dynamic_pixel = [_]u32{ vop1(0x01, 0, 0), vop1(0x01, 1, 1), vop1(0x01, 2, 2), vop1(0x01, 3, 3), 0xf800080f, 0x03020100, 0xbf810000 };
    var constant_pixel = [_]u32{ vop1(0x01, 0, 255), 0, vop1(0x01, 1, 255), 0, vop1(0x01, 2, 255), 0, vop1(0x01, 3, 255), 0, 0xf800080f, 0x03020100, 0xbf810000 };
    // Independent literal shaders supply the complete coverage/color reference.
    // Then change VS/PS USER_DATA together without changing their instructions.
    for (0..2) |pass| for (0..reference.len) |variant| {
        const shift: u32 = @bitCast(@as(f32, 1) + @as(f32, @floatFromInt(variant)) / 8);
        const color = [_]f32{ @as(f32, @floatFromInt(variant)) / 8, @as(f32, @floatFromInt(8 - variant)) / 8, 0.25, 1 };
        @memset(target, 0xa7);
        if (pass == 0) {
            vertex[2] = shift;
            for (color, 0..) |value, i| constant_pixel[i * 2 + 1] = @bitCast(value);
            @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
            @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(constant_pixel))], std.mem.asBytes(&constant_pixel));
        } else {
            @memcpy(memory.data[0x200..][0 .. dynamic_vertex.items.len * 4], std.mem.sliceAsBytes(dynamic_vertex.items));
            @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(dynamic_pixel))], std.mem.asBytes(&dynamic_pixel));
            try state.writeRegister(.shader, 0x04b, 2); // VS USER_DATA count 1.
            try state.writeRegister(.shader, 0x04c, shift);
            try state.writeRegister(.shader, 0x00b, 8); // PS USER_DATA count 4.
            for (color, 0..) |value, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), @bitCast(value));
        }
        const before = renderer.device.cacheStats();
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        if (pass == 0) {
            @memcpy(&reference[variant], target);
            if (std.mem.allEqual(u8, target, 0xa7)) return error.DynamicScalarReferenceEmpty;
        } else {
            if (!std.mem.eql(u8, &reference[variant], target)) return error.DynamicScalarRasterMismatch;
            const after = renderer.device.cacheStats();
            if (variant != 0 and before.enabled != 0 and (after.shader_misses != before.shader_misses or
                after.pipeline_misses != before.pipeline_misses or after.shader_hits != before.shader_hits + 2 or
                after.pipeline_hits != before.pipeline_hits + 1)) return error.DynamicScalarCacheMiss;
        }
    };
    if (std.mem.eql(u8, &reference[0], &reference[7])) return error.DynamicScalarReferenceUnchanged;
    std.debug.print("PASS dynamic VS/PS scalar uploads: 8 complete literal-reference images, changing coverage/color, unchanged shader and PSO cache entries\n", .{});
}

fn guestCacheProbe(allocator: std.mem.Allocator, device: *d3d12.Device, vertex: []const u32, fragment: []const u32) !void {
    const enabled = device.cacheStats().enabled != 0;
    defer device.cacheLimits(if (enabled) 256 else 0, if (enabled) 512 else 0) catch {};
    const pixel_bytes = 65 * 37 * 4;
    const cases = 24;
    const baseline = try allocator.alloc([pixel_bytes]u8, cases);
    defer allocator.free(baseline);
    const mutable_fragment = try allocator.dupe(u32, fragment);
    defer allocator.free(mutable_fragment);
    var constant: ?usize = null;
    var offset: usize = 5;
    while (offset < fragment.len) {
        const count: usize = fragment[offset] >> 16;
        if (count == 0 or count > fragment.len - offset) return error.InvalidSpirvProbe;
        if (count == 4 and fragment[offset] & 0xffff == 43 and fragment[offset + 3] == 0x3f800000) {
            constant = offset + 3;
            break;
        }
        offset += count;
    }
    const constant_index = constant orelse return error.MissingSpirvConstant;
    // Compare complete GPU readbacks, including dynamic state, shader bytes
    // changed in place, immutable PSO changes and deliberate LRU eviction.
    for ([_][2]u32{ .{ 0, 0 }, .{ 256, 512 }, .{ 2, 1 } }, 0..) |limits, pass| {
        try device.cacheLimits(limits[0], limits[1]);
        const before = device.cacheStats();
        for (0..cases) |variant| {
            var pixels: [pixel_bytes]u8 = @splat(0x39);
            var draw = try d3d12.Draw.fullTarget(65, 37);
            draw.blend.enabled = 1;
            draw.blend.source_color = 14; // Dynamic blend factor, rebound on cache hits.
            draw.blend.destination_color = 15;
            draw.blend.constants = .{ @as(f32, @floatFromInt(variant % 4)) / 4, 0.5, 0.75, 1 };
            draw.scissor[2] = 40 + @as(i32, @intCast(variant % 3));
            draw.viewport[0] = @floatFromInt(variant % 2);
            if (variant >= 4) draw.write_mask = @intCast(variant % 16);
            if (variant >= 8) draw.cull_mode = 1 + @as(u32, @intCast(variant % 3));
            if (variant >= 12) draw.front_ccw = @intCast(variant % 2);
            mutable_fragment[constant_index] = if (variant % 5 == 4) 0x3f000000 else fragment[constant_index];
            try device.drawSpirv(vertex, mutable_fragment, draw, &pixels);
            if (pass == 0) baseline[variant] = pixels else if (!std.mem.eql(u8, &baseline[variant], &pixels)) return error.CachedGraphicsMismatch;
            if (pass == 1 and variant == 3) {
                const stats = device.cacheStats();
                if (stats.shader_misses != before.shader_misses + 2 or stats.pipeline_misses != before.pipeline_misses + 1 or
                    stats.shader_hits != before.shader_hits + 6 or stats.pipeline_hits != before.pipeline_hits + 3) return error.DynamicStateCacheMiss;
            }
        }
        const after = device.cacheStats();
        if (pass == 2 and (after.shader_evictions == before.shader_evictions or after.pipeline_evictions == before.pipeline_evictions or
            after.shader_entries > 2 or after.pipeline_entries > 1)) return error.CacheEvictionNotExercised;
    }
    // Repeated draw timing is a host microbenchmark, not a game FPS result.
    mutable_fragment[constant_index] = fragment[constant_index];
    for ([_]bool{ false, true }) |cache_enabled| {
        try device.cacheLimits(if (cache_enabled) 256 else 0, if (cache_enabled) 512 else 0);
        var pixels: [pixel_bytes]u8 = @splat(0);
        const draw = try d3d12.Draw.fullTarget(65, 37);
        try device.drawSpirv(vertex, fragment, draw, &pixels);
        const started = gpu.frame_timing.timestampNs();
        const before = device.cacheStats();
        for (0..32) |_| {
            @memset(&pixels, 0);
            try device.drawSpirv(vertex, fragment, draw, &pixels);
            if (!std.mem.eql(u8, pixels[(18 * 65 + 32) * 4 ..][0..4], &.{ 255, 0, 0, 255 })) return error.CachedBenchmarkMismatch;
        }
        const elapsed = gpu.frame_timing.timestampNs() - started;
        const after = device.cacheStats();
        if (cache_enabled and (after.shader_misses != before.shader_misses or after.pipeline_misses != before.pipeline_misses or
            after.shader_hits != before.shader_hits + 64 or after.pipeline_hits != before.pipeline_hits + 32)) return error.WarmCacheMiss;
        std.debug.print("D3D12 repeated-draw probe: cache={any} draws=32 total_us={d} shader_misses={d} pso_misses={d}\n", .{
            cache_enabled, elapsed / std.time.ns_per_us, after.shader_misses - before.shader_misses, after.pipeline_misses - before.pipeline_misses,
        });
    }
    std.debug.print("PASS cached/uncached full-image equivalence (24 cases), dynamic state reuse, in-place shader mutation and bounded shader/PSO eviction\n", .{});
}

fn guestBlendingProbe(allocator: std.mem.Allocator, vertex: []const u32) !void {
    const source = [4]f32{ 0.25, 0.5, 0.75, 0.5 };
    const destination = [4]u8{ 51, 102, 153, 204 };
    const fragment = [_]u32{
        vop1(1, 0, 255), @bitCast(source[0]), vop1(1, 1, 255), @bitCast(source[1]),
        vop1(1, 2, 255), @bitCast(source[2]), vop1(1, 3, 255), @bitCast(source[3]),
        0xf800080f,      0x03020100,          0xbf810000,
    };
    const Case = struct {
        blend: gpu.resources.BlendControl,
        constants: [4]f32 = .{ 0.125, 0.375, 0.625, 0.875 },
        mask: u4 = 15,
    };
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(allocator);
    // Exercise each factor on both sides, including its alpha interpretation.
    for ([_]u5{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14, 19, 20 }) |factor| {
        try cases.append(allocator, .{ .blend = .{ .enabled = true, .color_source = factor, .color_destination = 0 } });
        try cases.append(allocator, .{ .blend = .{ .enabled = true, .color_source = 0, .color_destination = factor } });
    }
    for (0..5) |color_op| for (0..5) |alpha_op| {
        try cases.append(allocator, .{ .blend = .{
            .enabled = true,
            .color_source = 4,
            .color_destination = 5,
            .color_operation = @intCast(color_op),
            .separate_alpha = true,
            .alpha_source = 1,
            .alpha_destination = 1,
            .alpha_operation = @intCast(alpha_op),
        } });
    };
    for ([_]u4{ 0, 5, 8, 15 }) |mask| try cases.append(allocator, .{
        .blend = .{ .enabled = true, .color_source = 13, .color_destination = 14, .separate_alpha = true, .alpha_source = 19, .alpha_destination = 20 },
        .constants = .{ 0.75, 0.25, 0.5, 0.125 },
        .mask = mask,
    });
    // MIN/MAX ignore factors, even if stale fields name unsupported factors.
    try cases.append(allocator, .{ .blend = .{ .enabled = true, .color_source = 31, .color_destination = 15, .color_operation = 2 } });
    try cases.append(allocator, .{ .blend = .{ .enabled = true, .color_source = 19, .color_destination = 14 } });
    try cases.append(allocator, .{ .blend = .{ .enabled = true, .color_source = 13, .color_destination = 20 } });
    try cases.append(allocator, .{ .blend = .{ .color_source = 31, .color_operation = 7 } });
    var memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(&fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    const target = gpu.resources.decodeColorTarget(&state, 0, 15).?;
    const layout = try d3d12.surfaces.colorLayout(target);
    var initial: [65 * 37 * 4]u8 = undefined;
    for (&initial, 0..) |*v, i| v.* = destination[i % 4];
    const allocation = memory.data[0x2000..][0..@intCast(layout.required_source_bytes)];
    for (cases.items, 0..) |case, case_index| {
        const b = case.blend;
        const raw = (@as(u32, @intFromBool(b.enabled)) << 30) | (@as(u32, @intFromBool(b.separate_alpha)) << 29) |
            @as(u32, b.color_source) | (@as(u32, b.color_operation) << 5) | (@as(u32, b.color_destination) << 8) |
            (@as(u32, b.alpha_source) << 16) | (@as(u32, b.alpha_operation) << 21) | (@as(u32, b.alpha_destination) << 24);
        try state.writeRegister(.context, 0x1e0, raw);
        try state.writeRegister(.context, 0x08e, case.mask);
        for (case.constants, 0..) |v, i| try state.writeRegister(.context, 0x105 + @as(u32, @intCast(i)), @bitCast(v));
        @memset(allocation, 0xa7);
        try layout.tile(&initial, allocation);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        var staged = try d3d12.surfaces.Staged.read(allocator, memory.access(), target.address, layout);
        defer staged.deinit();
        if (!std.mem.eql(u8, staged.pixels[0..4], &destination)) return error.BlendingModifiedOutsideTriangle;
        const actual = staged.pixels[(18 * 65 + 32) * 4 ..][0..4];
        for (0..4) |i| {
            var expected: f32 = source[i];
            if (b.enabled) {
                const separate = i == 3 and b.separate_alpha;
                const op = if (separate) b.alpha_operation else b.color_operation;
                const dst = @as(f32, @floatFromInt(destination[i])) / 255;
                if (op == 2 or op == 3) {
                    expected = if (op == 2) @min(source[i], dst) else @max(source[i], dst);
                } else {
                    const a = source[i] * blendReferenceFactor(if (separate) b.alpha_source else b.color_source, i, source, destination, case.constants);
                    const d = dst * blendReferenceFactor(if (separate) b.alpha_destination else b.color_destination, i, source, destination, case.constants);
                    expected = switch (op) {
                        0 => a + d,
                        1 => a - d,
                        4 => d - a,
                        else => unreachable,
                    };
                }
            }
            const byte: i32 = if (case.mask & (@as(u4, 1) << @intCast(i)) == 0) destination[i] else @intFromFloat(@round(std.math.clamp(expected, 0, 1) * 255));
            if (@abs(@as(i32, actual[i]) - byte) > 1) {
                std.debug.print("blend case={d} channel={d} expected={d} actual={d}\n", .{ case_index, i, byte, actual[i] });
                return error.GuestBlendingMismatch;
            }
        }
    }
    // Unsupported dual-source exports must reject without touching the target
    // or publishing a subsequent release label.
    const before = memory.data;
    try state.writeRegister(.context, 0x1e0, (1 << 30) | 15);
    if (executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 })) |_| return error.InvalidBlendAccepted else |err| if (err != error.BackendRejected) return err;
    if ((renderer.failure orelse return error.InvalidBlendFailure) != error.DualSourceBlendingNotImplemented or !std.mem.eql(u8, &before, &memory.data)) return error.InvalidBlendModifiedTarget;
    const backend = renderer.dcbBackend();
    if (backend.vtable.write(backend.context, 0x1200, &.{ 1, 2, 3, 4 })) return error.FailedBlendPublishedLabel;
    std.debug.print("PASS {d} guest blend cases: factors, independent RGB/alpha equations, constants, masks, disable and fail-closed dual-source\n", .{cases.items.len});
}

fn blendReferenceFactor(factor: u5, channel: usize, source: [4]f32, destination: [4]u8, constants: [4]f32) f32 {
    const dst = @as(f32, @floatFromInt(destination[channel])) / 255;
    const dst_alpha = @as(f32, @floatFromInt(destination[3])) / 255;
    return switch (factor) {
        0 => 0,
        1 => 1,
        2 => source[channel],
        3 => 1 - source[channel],
        4 => source[3],
        5 => 1 - source[3],
        6 => dst_alpha,
        7 => 1 - dst_alpha,
        8 => dst,
        9 => 1 - dst,
        10 => if (channel == 3) 1 else @min(source[3], 1 - dst_alpha),
        13 => constants[channel],
        14 => 1 - constants[channel],
        19 => constants[3],
        20 => 1 - constants[3],
        else => unreachable,
    };
}

const GraphicsMemory = struct {
    data: [1024 * 1024]u8 = @splat(0),
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
    fn access(self: *@This()) d3d12.backend.Memory {
        return .{ .context = self, .read = read, .write = write };
    }
};

fn graphicsState(width: u32, height: u32, pitch: u32) !gpu.State {
    var state = gpu.State{};
    try state.writeRegister(.shader, 0x048, 2);
    try state.writeRegister(.shader, 0x049, 0);
    try state.writeRegister(.shader, 0x008, 4);
    try state.writeRegister(.shader, 0x009, 0);
    try state.writeRegister(.context, 0x318, 0x20);
    try state.writeRegister(.context, 0x390, 0);
    try state.writeRegister(.context, 0x31c, 10 << 2);
    try state.writeRegister(.context, 0x319, pitch / 8 - 1);
    try state.writeRegister(.context, 0x3b0, ((width - 1) << 14) | (height - 1));
    try state.writeRegister(.context, 0x3b8, 0);
    return state;
}

fn guestMrtProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    const initial_state = try graphicsState(65, 37, 72);
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    try renderer.draw(&initial_state, packet);
    const coverage = memory.data[0x2000..0x5000].*;
    // Stale higher slots may have unrelated extents, formats and metadata.
    // With zero effective channel masks they cannot constrain this draw.
    for ([_]bool{ false, true }) |shader_masked| {
        var state = initial_state;
        for (1..8) |slot| {
            const reg: u32 = @intCast(slot);
            try state.writeRegister(.context, 0x318 + reg * 15, 0x600);
            try state.writeRegister(.context, 0x319 + reg * 15, 127);
            try state.writeRegister(.context, 0x31c + reg * 15, (9 << 2) | (1 << 28));
            try state.writeRegister(.context, 0x390 + reg, 27);
            try state.writeRegister(.context, 0x3b0 + reg, (1023 << 14) | 1023);
            try state.writeRegister(.context, 0x3b8 + reg, 0);
        }
        try state.writeRegister(.context, 0x08e, if (shader_masked) 0xffffffff else 15);
        try state.writeRegister(.context, 0x08f, if (shader_masked) 15 else 0xffffffff);
        const before = try allocator.dupe(u8, &memory.data);
        defer allocator.free(before);
        try renderer.draw(&state, packet);
        try renderer.flushDraws();
        if (!std.mem.eql(u8, before, &memory.data)) return error.InactiveMrtModifiedMemory;
        try state.writeRegister(.context, 0x08e, 255);
        try state.writeRegister(.context, 0x08f, 255);
        // Activate a valid-format target with wrong extents. A stale DCC bit
        // without a metadata address is a separate layout error.
        try state.writeRegister(.context, 0x32b, 9 << 2);
        try std.testing.expectError(error.MismatchedRenderTargetExtents, renderer.draw(&state, packet));
        if (!std.mem.eql(u8, before, &memory.data)) return error.InvalidActiveMrtModifiedMemory;
    }
    for ([_]u32{ 2, 5, 8 }) |count| for ([_]usize{ 1, 8 }) |batch_limit| {
        var state = initial_state;
        var program: std.ArrayList(u32) = .empty;
        defer program.deinit(allocator);
        var mask: u32 = 0;
        for (0..count) |i| {
            const slot: u32 = @intCast(i);
            const address = 0x2000 + slot * 0x4000;
            try state.writeRegister(.context, 0x318 + slot * 15, address >> 8);
            try state.writeRegister(.context, 0x319 + slot * 15, 8);
            try state.writeRegister(.context, 0x31c + slot * 15, 10 << 2);
            try state.writeRegister(.context, 0x390 + slot, 0);
            try state.writeRegister(.context, 0x3b0 + slot, (64 << 14) | 36);
            try state.writeRegister(.context, 0x3b8 + slot, 0);
            const channels: u32 = switch (slot % 3) {
                0 => 7,
                1 => 8,
                else => 15,
            };
            mask |= channels << @as(u5, @intCast(slot * 4));
            // Odd slots add source and destination; even slots replace.
            try state.writeRegister(.context, 0x1e0 + slot, if (slot % 2 != 0) (1 << 30) | 1 | (1 << 8) else 0);
            const red: f32 = @as(f32, @floatFromInt(slot + 1)) / 8;
            try program.appendSlice(allocator, &.{ vop1(1, 0, 255), @bitCast(red), vop1(1, 1, 255), 0x3e800000, vop1(1, 2, 255), 0x3f400000, vop1(1, 3, 255), 0x3f800000, 0xf800000f | (slot << 4) | (if (slot + 1 == count) @as(u32, 0x800) else 0), 0x03020100 });
            @memset(memory.data[address..][0..0x3000], @as(u8, @intCast(32 + slot)));
        }
        try program.append(allocator, 0xbf810000);
        @memcpy(memory.data[0x400..][0 .. program.items.len * 4], std.mem.sliceAsBytes(program.items));
        try state.writeRegister(.context, 0x08e, mask);
        try state.writeRegister(.context, 0x204, 1 << 19);
        try state.writeRegister(.context, 0x007, 64 | (36 << 16));
        try state.writeRegister(.context, 0x010, 3);
        try state.writeRegister(.context, 0x011, 1);
        try state.writeRegister(.context, 0x012, 0x800);
        try state.writeRegister(.context, 0x014, 0x800);
        try state.writeRegister(.context, 0x013, 0x900);
        try state.writeRegister(.context, 0x015, 0x900);
        try state.writeRegister(.context, 0x200, 1 | 2 | 4 | (7 << 4) | (7 << 8));
        try state.writeRegister(.context, 0x10b, 8 << 4); // Increment once per covered fragment.
        try state.writeRegister(.context, 0x10c, 0x00ffff00);
        @memset(memory.data[0x80000..0x90000], 0x3f);
        @memset(memory.data[0x90000..0xa0000], 0x35);
        renderer.draw_batch_limit = batch_limit;
        try renderer.draw(&state, packet);
        try renderer.draw(&state, packet);
        try renderer.flushDraws();
        const render = gpu.resources.decodeRenderState(&state);
        for (0..count) |i| {
            const target = render.color_targets[i].?;
            const layout = try d3d12.surfaces.colorLayout(target);
            const backing = memory.data[@intCast(target.address)..][0..@intCast(layout.required_source_bytes)];
            const expected = try allocator.alloc(u8, backing.len);
            defer allocator.free(expected);
            @memset(expected, @as(u8, @intCast(32 + i)));
            const src = [_]u8{ @intFromFloat(@round(@as(f32, @floatFromInt(i + 1)) / 8 * 255)), 64, 191, 255 };
            for (0..37) |y| for (0..65) |x| {
                if (coverage[(y * 72 + x) * 4] != 255) continue;
                const pos: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                for (0..4) |channel| if (target.write_mask & (@as(u4, 1) << @as(u2, @intCast(channel))) != 0) {
                    expected[pos + channel] = if (i % 2 == 0) src[channel] else @intCast(@min(255, 32 + i + 2 * @as(usize, src[channel])));
                };
            };
            if (!std.mem.eql(u8, backing, expected)) return error.MrtColorOrPaddingMismatch;
        }
        const target = render.depth_target.?;
        const depth_layout = try d3d12.surfaces.depthLayout(target, 65, 37, true);
        const stencil_layout = try d3d12.surfaces.stencilLayout(target, 65, 37, true);
        for (0..37) |y| for (0..65) |x| {
            const covered = coverage[(y * 72 + x) * 4] == 255;
            const s: usize = @intCast(try stencil_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
            const z: usize = @intCast(try depth_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
            if (memory.data[0x90000 + s] != @as(u8, if (covered) 0x37 else 0x35)) return error.MrtRepeatedStencil;
            if (std.mem.readInt(u32, memory.data[0x80000 + z ..][0..4], .little) != @as(u32, if (covered) 0 else 0x3f3f3f3f)) return error.MrtDepthMismatch;
        };
        // Reject attachment aliases before changing any guest plane.
        try state.writeRegister(.context, 0x318 + 15, 0x20);
        const previous = try allocator.dupe(u8, &memory.data);
        defer allocator.free(previous);
        if (renderer.draw(&state, packet)) |_| return error.MrtAliasAccepted else |err| if (err != error.AttachmentAliasNotImplemented) return err;
        if (!std.mem.eql(u8, previous, &memory.data)) return error.MrtAliasChangedMemory;
    };
    // Rotate native formats through slot zero and the extra attachments at the
    // same guest addresses. This also checks batching/PSO/resource cache keys.
    for (0..4) |rotation| for ([_]usize{ 1, 8 }) |batch_limit| {
        try renderer.device.attachmentCache(batch_limit == 1);
        var state = initial_state;
        var program: std.ArrayList(u32) = .empty;
        defer program.deinit(allocator);
        for (0..5) |slot| {
            const reg: u32 = @intCast(slot);
            const kind = (slot + rotation) % 4;
            const address = 0x2000 + reg * 0x8000;
            try state.writeRegister(.context, 0x318 + reg * 15, address >> 8);
            try state.writeRegister(.context, 0x319 + reg * 15, 8);
            try state.writeRegister(.context, 0x31c + reg * 15, switch (kind) {
                0 => 10 << 2,
                1 => (5 << 2) | (7 << 8),
                2 => (10 << 2) | (1 << 8),
                else => (12 << 2) | (7 << 8),
            });
            try state.writeRegister(.context, 0x390 + reg, 0);
            try state.writeRegister(.context, 0x3b0 + reg, (64 << 14) | 36);
            try state.writeRegister(.context, 0x3b8 + reg, 0);
            try state.writeRegister(.context, 0x1e0 + reg, if (kind == 1 or kind == 3) (1 << 30) | 1 | (1 << 8) else 0);
            const values: [4]f32 = switch (kind) {
                0 => .{ 0, 1, 0, 1 },
                1 => .{ -1, 2, 0, 0 },
                2 => .{ -1, 0, 1, 1 },
                else => .{ -1, 2, 0.25, 0.5 },
            };
            for (values, 0..) |value, channel| try program.appendSlice(allocator, &.{ vop1(1, @intCast(channel), 255), @bitCast(value) });
            try program.appendSlice(allocator, &.{ 0xf800000f | (reg << 4) | (if (slot == 4) @as(u32, 0x800) else 0), 0x03020100 });
            @memset(memory.data[address..][0..0x6000], 0);
        }
        try program.append(allocator, 0xbf810000);
        @memcpy(memory.data[0x400..][0 .. program.items.len * 4], std.mem.sliceAsBytes(program.items));
        try state.writeRegister(.context, 0x08e, 0xfffff);
        renderer.draw_batch_limit = batch_limit;
        try renderer.draw(&state, packet);
        try renderer.draw(&state, packet);
        try renderer.flushDraws();
        const render = gpu.resources.decodeRenderState(&state);
        for (0..5) |slot| {
            const target = render.color_targets[slot].?;
            const layout = try d3d12.surfaces.colorLayout(target);
            const backing = memory.data[@intCast(target.address)..][0..@intCast(layout.required_source_bytes)];
            const expected = try allocator.alloc(u8, backing.len);
            defer allocator.free(expected);
            @memset(expected, 0);
            const value: []const u8 = switch ((slot + rotation) % 4) {
                0 => &.{ 0, 255, 0, 255 },
                1 => &.{ 0, 0xc0, 0, 0x44 }, // half(-2), half(4), after two additive writes.
                2 => &.{ 0x81, 0, 0x7f, 0x7f },
                else => &.{ 0, 0xc0, 0, 0x44, 0, 0x38, 0, 0x3c }, // half(-2, 4, 0.5, 1)
            };
            for (0..37) |y| for (0..65) |x| {
                if (coverage[(y * 72 + x) * 4] != 255) continue;
                const pos: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                @memcpy(expected[pos..][0..value.len], value);
            };
            if (!std.mem.eql(u8, backing, expected)) return error.MrtMixedFormatMismatch;
        }
    };
    std.debug.print("PASS 2/5/8 simultaneous targets, mixed RGBA8 UNORM/SNORM and RG16/RGBA16 float, independent masks/blends, exactly-once depth/stencil, immediate/grouped writes, padding and alias rejection\n", .{});
}

fn guestR8TargetProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    const packet = gpu.pm4.Packet{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    try renderer.draw(&state, packet);
    try renderer.flushDraws();
    const coverage = memory.data[0x2000..0x5000].*;
    const quarter = [_]u32{ vop1(1, 0, 255), 0x3e800000, vop1(1, 1, 128), vop1(1, 2, 128), vop1(1, 3, 242), 0xf800080f, 0x03020100, 0xbf810000 };
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(quarter))], std.mem.asBytes(&quarter));
    try state.writeRegister(.context, 0x318, 0x100);
    try state.writeRegister(.context, 0x319, 0);
    try state.writeRegister(.context, 0x31c, (1 << 2) | (1 << 28));
    try state.writeRegister(.context, 0x3b8, 27 << 14);
    try state.writeRegister(.context, 0x325, 0xa00);
    try state.writeRegister(.context, 0x3a8, 0);
    try state.writeRegister(.context, 0x323, 123);
    const target = gpu.resources.decodeColorTarget(&state, 0, 15).?;
    const layout = try d3d12.surfaces.colorLayout(target);
    const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
    const keys = memory.data[0xa0000..][0..d3d12.surfaces.Dcc.blockCount(backing.len)];
    for ([_]u8{ 0, 0x40, 0x80, 0xc0, 0x20, 0x10, 0xff }) |key| for ([_]u32{ 15, 14 }) |mask| {
        @memset(backing, 61);
        @memset(keys, key);
        const expected = try allocator.dupe(u8, &memory.data);
        defer allocator.free(expected);
        const initial: u8 = switch (key) {
            0, 0x80 => 0,
            0x40, 0xc0 => 255,
            0x20 => 123,
            else => 61,
        };
        @memset(expected[0x10000..][0..backing.len], initial);
        @memset(expected[0xa0000..][0..keys.len], 0xff);
        if (mask & 1 != 0) for (0..37) |y| for (0..65) |x| {
            if (coverage[(y * 72 + x) * 4] != 255) continue;
            const offset: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
            expected[0x10000 + offset] = 64;
        };
        try state.writeRegister(.context, 0x08e, mask);
        try renderer.draw(&state, packet);
        try renderer.flushDraws();
        if (!std.mem.eql(u8, expected, &memory.data)) return error.R8TargetMemoryMismatch;
    };
    std.debug.print("PASS R8 render target: 14 DCC plain/fixed/register/single-clear cases, red masks, full backing/padding/key reference\n", .{});
}

fn guestFloatTargetProbe(allocator: std.mem.Allocator, vertex: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    const hdr = [_]u32{
        vop1(1, 0, 255), @bitCast(@as(f32, -1)),   vop1(1, 1, 255), @bitCast(@as(f32, 2)),
        vop1(1, 2, 255), @bitCast(@as(f32, 0.25)), vop1(1, 3, 255), @bitCast(@as(f32, 0.5)),
        0xf800080f,      0x03020100,               0xbf810000,
    };
    // Sample the rendered HDR center and transform it into UNORM range. A
    // clamp or RGBA8 conversion before sampling produces a different result.
    var sample: std.ArrayList(u32) = .empty;
    defer sample.deinit(allocator);
    try sample.appendSlice(allocator, &.{ vop1(1, 0, 255), @bitCast(@as(f32, 0.5)), vop1(1, 1, 255), @bitCast(@as(f32, 0.5)), 0xf0800f08, 0x00400400, vop1(1, 8, 255), @bitCast(@as(f32, 0.25)), vop1(1, 9, 255), @bitCast(@as(f32, 0.5)) });
    for (0..4) |i| {
        const r: u8 = @intCast(i);
        try sample.appendSlice(allocator, &.{ vop2(0x08, r, r + 4, 8), vop2(0x03, r, r, 9) });
    }
    try sample.appendSlice(allocator, &.{ 0xf800080f, 0x03020100, 0xbf810000 });
    for ([_]gpu.resources.TileMode{ .linear, .standard_256b, .standard_4kb, .standard_64kb, .partially_resident, .render_target }) |mode| {
        var state = try graphicsState(65, 37, 72);
        try state.writeRegister(.context, 0x318, 0x100);
        // Linear image views derive their pitch from the 256-byte alignment.
        try state.writeRegister(.context, 0x319, 0);
        try state.writeRegister(.context, 0x31c, (12 << 2) | (7 << 8));
        try state.writeRegister(.context, 0x3b8, @as(u32, @intFromEnum(mode)) << 14);
        @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(hdr))], std.mem.asBytes(&hdr));
        const target = gpu.resources.decodeColorTarget(&state, 0, 15).?;
        const layout = try d3d12.surfaces.colorLayout(target);
        const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
        @memset(backing, 0);
        try renderer.draw(&state, packet);
        var staged = try d3d12.surfaces.Staged.read(allocator, memory.access(), target.address, layout);
        defer staged.deinit();
        const center = (18 * 65 + 32) * 8;
        if (!std.mem.eql(u8, staged.pixels[center..][0..8], &.{ 0, 0xbc, 0, 0x40, 0, 0x34, 0, 0x38 })) return error.FloatTargetReadbackMismatch;
        const original = try allocator.dupe(u8, backing);
        defer allocator.free(original);
        @memcpy(memory.data[0x400..][0 .. sample.items.len * 4], std.mem.sliceAsBytes(sample.items));
        state = try graphicsState(65, 37, 72);
        try state.writeRegister(.shader, 0x00b, 12 << 1);
        const words = [_]u32{ 0x100, 71 << 20, 16 | (36 << 14), (9 << 28) | 0xfac | (@as(u32, @intFromEnum(mode)) << 20), 0, 0, 0, 0, 0x92, 0xfff000, 0, 0 };
        for (words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
        @memset(memory.data[0x2000..0x5000], 0);
        try renderer.draw(&state, packet);
        const result = memory.data[0x2000 + (18 * 72 + 32) * 4 ..][0..4];
        for (result, [_]u8{ 64, 255, 143, 159 }) |a, b| if (@abs(@as(i16, a) - b) > 1) return error.FloatTargetSamplingMismatch;
        if (!std.mem.eql(u8, backing, original)) return error.FloatSampleSourceModified;
    }
    std.debug.print("PASS RGBA16F render/readback/sample across six guest layouts, negative/HDR values and source preservation\n", .{});
}

fn guestPackedTargetProbe(allocator: std.mem.Allocator, vertex: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    const fragment = [_]u32{
        vop1(1, 0, 255), @bitCast(@as(f32, 1)),    vop1(1, 1, 255), @bitCast(@as(f32, 0.75)),
        vop1(1, 2, 255), @bitCast(@as(f32, 0.25)), vop1(1, 3, 255), @bitCast(@as(f32, 1)),
        0xf800080f,      0x03020100,               0xbf810000,
    };
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(fragment))], std.mem.asBytes(&fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    for ([_]gpu.resources.TileMode{ .linear, .standard_256b, .standard_4kb, .standard_64kb, .partially_resident, .render_target }) |mode| {
        var state = try graphicsState(65, 37, 72);
        try state.writeRegister(.context, 0x318, 0x100);
        try state.writeRegister(.context, 0x3b8, @as(u32, @intFromEnum(mode)) << 14);
        const layout = try d3d12.surfaces.colorLayout(gpu.resources.decodeColorTarget(&state, 0, 15).?);
        const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
        @memset(backing, 0xa7);
        try renderer.draw(&state, packet);
        // Independent RGBA8 render determines raster coverage; packed targets
        // must change those same texels and preserve every padding byte.
        const coverage = try allocator.dupe(u8, backing);
        defer allocator.free(coverage);
        for ([_]u32{ 9 << 2, (6 << 2) | (7 << 8) }, [_]u32{
            1023 | (767 << 10) | (256 << 20) | (3 << 30),
            0x3c0 | (0x3a0 << 11) | (0x1a0 << 22),
        }) |info, encoded| {
            try state.writeRegister(.context, 0x31c, info);
            @memset(backing, 0xa7);
            try renderer.draw(&state, packet);
            const expected = try allocator.alloc(u8, backing.len);
            defer allocator.free(expected);
            @memset(expected, 0xa7);
            for (0..37) |y| for (0..65) |x| {
                const offset: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                if (coverage[offset] != 255) continue;
                std.mem.writeInt(u32, expected[offset..][0..4], encoded, .little);
            };
            if (!std.mem.eql(u8, backing, expected)) {
                for (0..backing.len / 4) |i| {
                    const actual = std.mem.readInt(u32, backing[i * 4 ..][0..4], .little);
                    const wanted = std.mem.readInt(u32, expected[i * 4 ..][0..4], .little);
                    if (actual != wanted) {
                        std.debug.print("Packed target mode={s} info=0x{x} offset=0x{x}: actual=0x{x}, expected=0x{x}\n", .{ @tagName(mode), info, i * 4, actual, wanted });
                        break;
                    }
                }
                return error.PackedTargetMismatch;
            }
            if (info == 9 << 2) {
                var staged = try d3d12.surfaces.Staged.read(allocator, memory.access(), 0x10000, layout);
                defer staged.deinit();
                try d3d12.surfaces.convertScanout(staged.pixels, 0x8100_0000_2200_0000);
                if (!std.mem.eql(u8, staged.pixels[(18 * 65 + 32) * 4 ..][0..4], &.{ 255, 191, 64, 255 })) return error.PackedScanoutMismatch;
            }
        }
    }
    std.debug.print("PASS RGB10A2/R11G11B10 render and readback across six guest layouts, SDR scanout and preserved padding\n", .{});
}

fn guestDepthBiasProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.context, 0x204, 1 << 19);
    try state.writeRegister(.context, 0x205, (1 << 11) | (1 << 12));
    try state.writeRegister(.context, 0x007, 64 | (36 << 16));
    try state.writeRegister(.context, 0x012, 0x200);
    try state.writeRegister(.context, 0x014, 0x200);
    try state.writeRegister(.context, 0x200, 2 | 4 | (7 << 4));
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    const color_layout = try d3d12.surfaces.colorLayout(gpu.resources.decodeColorTarget(&state, 0, 15).?);
    const color = memory.data[0x2000..][0..@intCast(color_layout.required_source_bytes)];
    for ([_]bool{ false, true }) |sloped| {
        var program: std.ArrayList(u32) = .empty;
        defer program.deinit(allocator);
        for (vertex) |word| {
            if (word == vop1(0x01, 7, 128)) {
                if (sloped) {
                    // z = 0.5 + 0.25 * x: slope in framebuffer space is 0.5 / 65.
                    try program.appendSlice(allocator, &.{ vop1(0x01, 7, 255), 0x3e800000, vop2(0x08, 7, 5, 7), vop1(0x01, 8, 255), 0x3f000000, vop2(0x03, 7, 7, 8) });
                } else try program.appendSlice(allocator, &.{ vop1(0x01, 7, 255), 0x3f000000 });
            } else try program.append(allocator, word);
        }
        @memcpy(memory.data[0x200..][0 .. program.items.len * 4], std.mem.sliceAsBytes(program.items));
        for ([_]u8{ 1, 3 }) |format| {
            try state.writeRegister(.context, 0x010, format);
            try state.writeRegister(.context, 0x2de, if (format == 1) 0xf0 else 0x1e9);
            const layout = try d3d12.surfaces.depthLayout(gpu.resources.decodeDepthTarget(&state).?, 65, 37, true);
            const backing = memory.data[0x20000..][0..@intCast(layout.required_source_bytes)];
            const bpp: usize = if (format == 1) 2 else 4;
            const baseline = try allocator.alloc(u8, backing.len);
            defer allocator.free(baseline);
            // Repeat zero at the end: PSO keys must include every bias field.
            const cases = [_][3]f32{ .{ 0, 0, 0 }, .{ 32, 0, 0 }, .{ -32, 0, 0 }, .{ 167.77214, 0, 0 }, .{ -167.77214, 0, 0 }, .{ 0, 16, 0 }, .{ 0, -16, 0 }, .{ 0, 16, 0.002 }, .{ 0, -16, -0.002 }, .{ 0, 0, 0 } };
            for (cases, 0..) |bias, case| {
                try state.writeRegister(.context, 0x2e0, @bitCast(bias[1]));
                try state.writeRegister(.context, 0x2e2, @bitCast(bias[1]));
                try state.writeRegister(.context, 0x2e1, @bitCast(bias[0]));
                try state.writeRegister(.context, 0x2e3, @bitCast(bias[0]));
                try state.writeRegister(.context, 0x2df, @bitCast(bias[2]));
                @memset(backing, 0x5d);
                @memset(color, 0xa7);
                _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
                if (case == 0) @memcpy(baseline, backing);
                const expected = try allocator.dupe(u8, baseline);
                defer allocator.free(expected);
                const unit: f64 = if (format == 1) 1.0 / 65535.0 else 1.0 / 16777216.0;
                var delta: f64 = bias[0] * unit + (if (sloped) @as(f64, bias[1]) / 16 * 0.5 / 65 else 0);
                if (bias[2] > 0) delta = @min(delta, bias[2]);
                if (bias[2] < 0) delta = @max(delta, bias[2]);
                for (0..37) |y| for (0..65) |x| {
                    const co: usize = @intCast(try color_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                    if (color[co] == 0xa7) continue;
                    const offset: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                    const actual: f64 = if (bpp == 2) @as(f64, @floatFromInt(std.mem.readInt(u16, backing[offset..][0..2], .little))) / 65535 else @as(f32, @bitCast(std.mem.readInt(u32, backing[offset..][0..4], .little)));
                    const original: f64 = if (bpp == 2) @as(f64, @floatFromInt(std.mem.readInt(u16, baseline[offset..][0..2], .little))) / 65535 else @as(f32, @bitCast(std.mem.readInt(u32, baseline[offset..][0..4], .little)));
                    // Raster depth setup may round by one DSV unit, even for
                    // a constant-Z triangle; fractional bias stays FLOAT in
                    // the native PSO and is never truncated by our boundary.
                    const tolerance: f64 = if (format == 1) 1.1 / 65535.0 else if (sloped) 0.0000002 else 1.1 / 16777216.0;
                    if (!std.math.isFinite(actual) or @abs(actual - original - delta) > tolerance) {
                        std.debug.print("Depth bias format={d} sloped={} case={d} xy={d},{d} actual={d} baseline={d} delta={d}\n", .{ format, sloped, case, x, y, actual, original, delta });
                        return error.DepthBiasMismatch;
                    }
                    @memcpy(expected[offset..][0..bpp], backing[offset..][0..bpp]);
                };
                if (!std.mem.eql(u8, backing, expected)) return error.DepthBiasPaddingMismatch;
                if (case == cases.len - 1 and !std.mem.eql(u8, backing, baseline)) return error.DepthBiasCacheMismatch;
            }
        }
    }
    std.debug.print("PASS guest D16/D32 constant/slope depth bias, signed clamp, PSO changes and untouched padding\n", .{});
}

fn guestDepthProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32, conversion_limit: usize) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.context, 0x204, 1 << 19); // Guest 0..1 clip depth.
    renderer.conversion_cache.limit = conversion_limit;
    try state.writeRegister(.context, 0x007, 64 | (36 << 16));
    try state.writeRegister(.context, 0x012, 0x200);
    try state.writeRegister(.context, 0x014, 0x200);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    const color_layout = try d3d12.surfaces.colorLayout(gpu.resources.decodeColorTarget(&state, 0, 15).?);
    const color = memory.data[0x2000..][0..@intCast(color_layout.required_source_bytes)];
    @memset(color, 0xa7);
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    const reference = try allocator.dupe(u8, color);
    defer allocator.free(reference);
    var cases: usize = 0;
    for ([_]u8{ 1, 3 }) |format| for ([_]gpu.resources.TileMode{ .linear, .depth }) |mode| {
        try state.writeRegister(.context, 0x010, @as(u32, format) | (@as(u32, @intFromEnum(mode)) << 4));
        const descriptor = gpu.resources.decodeDepthTarget(&state).?;
        const layout = try d3d12.surfaces.depthLayout(descriptor, 65, 37, true);
        const backing = memory.data[0x20000..][0..@intCast(layout.required_source_bytes)];
        const bpp: usize = if (format == 1) 2 else 4;
        for ([_]f32{ 0, 0.25, 0.5, 0.75, 1 }) |incoming| {
            // Change the real guest VS in place; cache identity must follow it.
            var program: std.ArrayList(u32) = .empty;
            defer program.deinit(allocator);
            for (vertex) |word| {
                if (word == vop1(0x01, 7, 128)) {
                    try program.appendSlice(allocator, &.{ vop1(0x01, 7, 255), @bitCast(incoming) });
                } else try program.append(allocator, word);
            }
            @memcpy(memory.data[0x200..][0 .. program.items.len * 4], std.mem.sliceAsBytes(program.items));
            for ([_]f32{ 0, 1 }) |stored| for (0..8) |compare| for (0..3) |write_mode| {
                const passes = switch (compare) {
                    0 => false,
                    1 => incoming < stored,
                    2 => incoming == stored,
                    3 => incoming <= stored,
                    4 => incoming > stored,
                    5 => incoming != stored,
                    6 => incoming >= stored,
                    7 => true,
                    else => unreachable,
                };
                const writes = write_mode == 1;
                try state.writeRegister(.context, 0x200, 2 | (if (write_mode == 0) @as(u32, 0) else 4) | (@as(u32, @intCast(compare)) << 4));
                try state.writeRegister(.context, 0x002, if (write_mode == 2) 1 << 24 else 0);
                @memset(color, 0xa7);
                @memset(backing, 0x5d);
                // Initialize every logical depth texel; preserve row/tile tails.
                for (0..37) |y| for (0..65) |x| {
                    const offset: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                    if (bpp == 2) std.mem.writeInt(u16, backing[offset..][0..2], if (stored == 0) 0 else 65535, .little) else std.mem.writeInt(u32, backing[offset..][0..4], @bitCast(stored), .little);
                };
                const expected = try allocator.dupe(u8, backing);
                defer allocator.free(expected);
                if (writes and passes) for (0..37) |y| {
                    for (0..65) |x| {
                        const color_offset: usize = @intCast(try color_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                        if (reference[color_offset] == 0xa7) continue;
                        const offset: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                        if (bpp == 2) std.mem.writeInt(u16, expected[offset..][0..2], @intFromFloat(@round(incoming * 65535)), .little) else std.mem.writeInt(u32, expected[offset..][0..4], @bitCast(incoming), .little);
                    }
                };
                _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
                if (bpp == 2 and writes and passes) for (0..37) |y| {
                    for (0..65) |x| {
                        const color_offset: usize = @intCast(try color_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                        if (reference[color_offset] == 0xa7) continue;
                        const offset: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                        const actual = std.mem.readInt(u16, backing[offset..][0..2], .little);
                        // Interpolated 0.5 can land on either side of the D16
                        // quantization midpoint. Check numeric precision first,
                        // then retain exact checks for all untouched/padding bytes.
                        const ideal = @as(f64, incoming) * 65535;
                        if (@abs(@as(f64, @floatFromInt(actual)) - ideal) > 0.6) return error.DepthPrecisionMismatch;
                        std.mem.writeInt(u16, expected[offset..][0..2], actual, .little);
                    }
                };
                for (color, 0..) |byte, i| if (byte != (if (passes) reference[i] else @as(u8, 0xa7))) {
                    std.debug.print("Depth color format={d} compare={d} in={d} stored={d} write={d} byte={d}\n", .{ format, compare, incoming, stored, write_mode, i });
                    return error.DepthComparisonMismatch;
                };
                if (!std.mem.eql(u8, backing, expected)) {
                    for (backing, expected, 0..) |actual_byte, expected_byte, i| if (actual_byte != expected_byte) {
                        const aligned = i / bpp * bpp;
                        std.debug.print("Depth bytes format={d} tile={f} compare={d} in={d} stored={d} write={d} offset={d} actual={any} expected={any}\n", .{ format, mode, compare, incoming, stored, write_mode, i, backing[aligned..][0..bpp], expected[aligned..][0..bpp] });
                        break;
                    };
                    return error.DepthWritebackOrPaddingMismatch;
                }
                if (incoming == 0.25 and stored == 1 and compare == 1 and write_mode == 1) {
                    // Disable the real guest color descriptor, preserving the
                    // same depth rasterization and all tiled/row padding.
                    @memset(backing, 0x5d);
                    for (0..37) |y| for (0..65) |x| {
                        const offset: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                        if (bpp == 2) std.mem.writeInt(u16, backing[offset..][0..2], 65535, .little) else std.mem.writeInt(u32, backing[offset..][0..4], @bitCast(@as(f32, 1)), .little);
                    };
                    @memset(color, 0xa7);
                    try state.writeRegister(.context, 0x31c, 0);
                    if (gpu.resources.decodeRenderState(&state).color_count != 0) return error.DepthOnlyGuestProbeHasColor;
                    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
                    if (!std.mem.eql(u8, backing, expected) or !std.mem.allEqual(u8, color, 0xa7)) return error.GuestDepthOnlyWritebackMismatch;
                    try state.writeRegister(.context, 0x31c, 10 << 2);
                }
                cases += 1;
            };
        }
    };
    // A committed first draw must affect the next comparison, with no CPU
    // replacement of the depth plane between them. Then disable depth again.
    try state.writeRegister(.context, 0x002, 0);
    try state.writeRegister(.context, 0x200, 2 | 4 | (7 << 4));
    @memset(memory.data[0x20000..0x30000], 0);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    @memset(color, 0xa7);
    try state.writeRegister(.context, 0x200, 2 | (4 << 4)); // 1 > stored 1 must fail.
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    for (color) |byte| if (byte != 0xa7) return error.ConsecutiveDepthDrawMismatch;
    try state.writeRegister(.context, 0x200, 0);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    if (!std.mem.eql(u8, color, reference)) return error.DisabledDepthDrawMismatch;
    try state.writeRegister(.context, 0x200, 2 | 4);
    // A depth fast clear must retain CLEAR_DEPTH, even if the utility draw's
    // ordinary write-enable bit is set and its vertex Z is different.
    try state.writeRegister(.context, 0x000, 1);
    try state.writeRegister(.context, 0x00b, @bitCast(@as(f32, 0.75)));
    try state.writeRegister(.context, 0x200, 2 | 4 | (7 << 4));
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    const clear_target = gpu.resources.decodeDepthTarget(&state).?;
    var clear_depth = try d3d12.surfaces.Staged.read(allocator, memory.access(), clear_target.read_address, try d3d12.surfaces.depthLayout(clear_target, 65, 37, true));
    defer clear_depth.deinit();
    for (0..65 * 37) |i| if (std.mem.readInt(u32, clear_depth.pixels[i * 4 ..][0..4], .little) != 0x3f400000) return error.GuestDepthClearOverwritten;
    try state.writeRegister(.context, 0x000, 0);
    try state.writeRegister(.context, 0x200, 2 | 4);
    // Error paths must leave both attachment planes and guest labels intact.
    const before = try allocator.dupe(u8, &memory.data);
    defer allocator.free(before);
    try state.writeRegister(.context, 0x002, 0);
    try state.writeRegister(.context, 0x014, 0x300);
    if (renderer.draw(&state, packet)) |_| return error.SeparateDepthAccepted else |err| if (err != error.SeparateDepthAddressesNotImplemented) return err;
    try state.writeRegister(.context, 0x014, 0x200);
    try state.writeRegister(.context, 0x012, 0x20);
    try state.writeRegister(.context, 0x014, 0x20);
    if (renderer.draw(&state, packet)) |_| return error.DepthColorAliasAccepted else |err| if (err != error.DepthColorAliasNotImplemented) return err;
    try state.writeRegister(.context, 0x012, 0x200);
    try state.writeRegister(.context, 0x014, 0x200);
    try state.writeRegister(.context, 0x200, 3 | 4);
    // INVALID stencil is disabled. A valid stencil format with no backing
    // remains an error, even when the depth plane itself is usable.
    try state.writeRegister(.context, 0x011, 1);
    if (renderer.draw(&state, packet)) |_| return error.MissingStencilAccepted else |err| if (err != error.SeparateStencilAddressesNotImplemented) return err;
    try state.writeRegister(.context, 0x011, 0);
    try state.writeRegister(.context, 0x200, 2 | 4 | (1 << 3));
    if (renderer.draw(&state, packet)) |_| return error.DepthBoundsAccepted else |err| if (err != error.DepthBoundsNotImplemented) return err;
    try state.writeRegister(.context, 0x200, 2 | 4);
    try state.writeRegister(.context, 0x010, 3 | (24 << 4) | (1 << 29));
    if (executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 })) |_| return error.DepthMetadataAccepted else |err| if (err != error.BackendRejected) return err;
    if (!std.mem.eql(u8, before, &memory.data)) return error.RejectedDepthModifiedMemory;
    const backend = renderer.dcbBackend();
    if (backend.vtable.write(backend.context, 0x1200, &.{ 1, 2, 3, 4 })) return error.FailedDepthPublishedLabel;
    if (conversion_limit != 0 and (renderer.conversion_cache.detile_hits == 0 or renderer.conversion_cache.tile_hits == 0)) return error.SurfaceConversionCacheNotExercised;
    std.debug.print("PASS conversion budget={d} KiB: detile hits={d}, tile hits={d}\n", .{ conversion_limit / 1024, renderer.conversion_cache.detile_hits, renderer.conversion_cache.tile_hits });
    std.debug.print("PASS {d} guest depth cases: D16/D32, linear/depth-64K, all comparisons, read-only/write masks, shader mutation, consecutive draws, full color/depth and padding checks; invalid layouts stop before writes\n", .{cases});
}

fn guestViewportDepthProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.context, 0x007, 64 | (36 << 16));
    try state.writeRegister(.context, 0x012, 0x200);
    try state.writeRegister(.context, 0x014, 0x200);
    try state.writeRegister(.context, 0x010, 3); // D32, linear, including padded rows.
    try state.writeRegister(.context, 0xb4, 0);
    try state.writeRegister(.context, 0xb5, @bitCast(@as(f32, 1)));
    for ([_]f32{ 32.5, 32.5, -18.5, 18.5, 1, 0 }, 0..) |value, i|
        try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    const color_layout = try d3d12.surfaces.colorLayout(gpu.resources.decodeColorTarget(&state, 0, 15).?);
    const depth_layout = try d3d12.surfaces.depthLayout(gpu.resources.decodeDepthTarget(&state).?, 65, 37, true);
    const color = memory.data[0x2000..][0..@intCast(color_layout.required_source_bytes)];
    const depth = memory.data[0x20000..][0..@intCast(depth_layout.required_source_bytes)];
    @memset(color, 0xa7);
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    const covered = try allocator.dupe(u8, color);
    defer allocator.free(covered);
    const expected = try allocator.alloc(u8, depth.len);
    defer allocator.free(expected);
    var program: std.ArrayList(u32) = .empty;
    defer program.deinit(allocator);
    const Mapping = struct { zero_to_one: bool = false, scale: f32 = 1, offset: f32 = 0 };
    var cases: usize = 0;
    for ([_]Mapping{ .{}, .{ .scale = 2, .offset = -0.25 }, .{ .zero_to_one = true, .scale = 2, .offset = -0.25 }, .{ .scale = -1 } }) |mapping| {
        try state.writeRegister(.context, 0x204, if (mapping.zero_to_one) 1 << 19 else 0);
        try state.writeRegister(.context, 0x113, @bitCast(mapping.scale));
        try state.writeRegister(.context, 0x114, @bitCast(mapping.offset));
        // Tiny positive D32 must survive: mapping through (z + 1) / 2 loses it.
        for ([_]f32{ -2, -1, -0.5, -0x1p-25, 0, 0x1p-25, 0.25, 0.5, 1, 2 }) |z| {
            program.clearRetainingCapacity();
            for (vertex) |word| {
                if (word == vop1(0x01, 7, 128)) {
                    try program.appendSlice(allocator, &.{ vop1(0x01, 7, 255), @bitCast(z) });
                } else try program.append(allocator, word);
            }
            @memcpy(memory.data[0x200..][0 .. program.items.len * 4], std.mem.sliceAsBytes(program.items));
            const incoming = @max(@as(f32, 0), @min(@as(f32, 1), z * mapping.scale + mapping.offset));
            const clipped = z < (if (mapping.zero_to_one) @as(f32, 0) else -1) or z > 1;
            for ([_]f32{ 0, 1 }) |stored| for (0..8) |compare| for ([_]bool{ false, true }) |writes| {
                const passes = !clipped and switch (compare) {
                    0 => false,
                    1 => incoming < stored,
                    2 => incoming == stored,
                    3 => incoming <= stored,
                    4 => incoming > stored,
                    5 => incoming != stored,
                    6 => incoming >= stored,
                    7 => true,
                    else => unreachable,
                };
                try state.writeRegister(.context, 0x200, 2 | (if (writes) @as(u32, 4) else 0) | (@as(u32, @intCast(compare)) << 4));
                @memset(color, 0xa7);
                @memset(depth, 0x5d);
                for (0..37) |y| for (0..65) |x| {
                    const offset: usize = @intCast(try depth_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                    std.mem.writeInt(u32, depth[offset..][0..4], @bitCast(stored), .little);
                };
                @memcpy(expected, depth);
                if (passes and writes) for (0..37) |y| {
                    for (0..65) |x| {
                        const color_offset: usize = @intCast(try color_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                        if (covered[color_offset] == 0xa7) continue;
                        const offset: usize = @intCast(try depth_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
                        std.mem.writeInt(u32, expected[offset..][0..4], @bitCast(incoming), .little);
                    }
                };
                _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
                for (color, 0..) |byte, i| if (byte != (if (passes) covered[i] else @as(u8, 0xa7))) {
                    std.debug.print("Viewport color mapping={any} z={d} stored={d} compare={d} write={any} byte={d}\n", .{ mapping, z, stored, compare, writes, i });
                    return error.ViewportDepthCoverageMismatch;
                };
                if (!std.mem.eql(u8, expected, depth)) {
                    std.debug.print("Viewport depth mapping={any} z={d} stored={d} compare={d} write={any}\n", .{ mapping, z, stored, compare, writes });
                    return error.ViewportDepthPrecisionOrPaddingMismatch;
                }
                cases += 1;
            };
        }
    }
    // One triangle intersects both original clip planes. Compare full coverage
    // with native homogeneous clipping, then verify post-interpolation clamp.
    program.clearRetainingCapacity();
    for (vertex) |word| {
        if (word == vop1(0x01, 7, 128)) {
            try program.appendSlice(allocator, &.{ vop1(0x01, 7, 255), @bitCast(@as(f32, 2)), vop2(0x08, 7, 5, 7) });
        } else try program.append(allocator, word);
    }
    @memcpy(memory.data[0x200..][0 .. program.items.len * 4], std.mem.sliceAsBytes(program.items));
    try state.writeRegister(.context, 0x204, 0);
    try state.writeRegister(.context, 0x113, @bitCast(@as(f32, 1)));
    try state.writeRegister(.context, 0x114, 0);
    try state.writeRegister(.context, 0x200, 0);
    @memset(color, 0xa7);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    @memcpy(covered, color);
    @memset(color, 0xa7);
    @memset(depth, 0);
    try state.writeRegister(.context, 0x200, 2 | 4 | (7 << 4));
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    if (!std.mem.eql(u8, covered, color)) return error.ViewportDepthPlaneClippingMismatch;
    for (0..37) |y| for (0..65) |x| {
        const color_offset: usize = @intCast(try color_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
        if (covered[color_offset] == 0xa7) continue;
        const offset: usize = @intCast(try depth_layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
        const actual: f32 = @bitCast(std.mem.readInt(u32, depth[offset..][0..4], .little));
        const ideal = @max(@as(f32, 0), 2 * (2 * (@as(f32, @floatFromInt(x)) + 0.5) / 65 - 1));
        if (@abs(actual - ideal) > 0.000001) return error.ViewportDepthInterpolationMismatch;
    };
    // Keep identical SPIR-V while changing only native Z clipping: this state
    // must be part of the PSO identity, including when returning to a hit.
    program.clearRetainingCapacity();
    for (vertex) |word| {
        if (word == vop1(0x01, 7, 128)) {
            try program.appendSlice(allocator, &.{ vop1(0x01, 7, 255), @bitCast(@as(f32, -0.5)) });
        } else try program.append(allocator, word);
    }
    var vs = try rdna2.decodeProgram(allocator, program.items);
    defer vs.deinit(allocator);
    var ps = try rdna2.decodeProgram(allocator, fragment);
    defer ps.deinit(allocator);
    var vertex_module = try rdna2.translateProgramSpirv(allocator, &vs, .{
        .stage = .vertex,
        .vertex_index_vgpr = 5,
        .vertex_depth_transform = .{ .scale = 1, .offset = 0, .negative_one_to_one = true },
    });
    defer vertex_module.deinit(allocator);
    var pixel_module = try rdna2.translateProgramSpirv(allocator, &ps, .{ .stage = .fragment });
    defer pixel_module.deinit(allocator);
    const pixels = try allocator.alloc(u8, 65 * 37 * 4);
    defer allocator.free(pixels);
    const baseline = try allocator.alloc(u8, pixels.len);
    defer allocator.free(baseline);
    var native_draw = try d3d12.Draw.fullTarget(65, 37);
    for ([_]u32{ 0, 1, 0 }, 0..) |clip, pass| {
        native_draw.depth_clip_enabled = clip;
        @memset(pixels, 0xa7);
        try renderer.device.drawSpirv(vertex_module.words, pixel_module.words, native_draw, pixels);
        if (pass == 0) {
            if (std.mem.allEqual(u8, pixels, 0xa7)) return error.NativeDepthClampEmpty;
            @memcpy(baseline, pixels);
        } else if (clip == 1) {
            if (!std.mem.allEqual(u8, pixels, 0xa7)) return error.NativeDepthClipCacheMismatch;
        } else if (!std.mem.eql(u8, baseline, pixels)) return error.NativeDepthClampCacheMismatch;
    }
    const before = try allocator.dupe(u8, &memory.data);
    defer allocator.free(before);
    try state.writeRegister(.context, 0xb5, @bitCast(@as(f32, 0.5)));
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    if (renderer.draw(&state, packet)) |_| return error.UnsupportedDepthClampAccepted else |err| if (err != error.UnrestrictedViewportDepthNotImplemented) return err;
    if (!std.mem.eql(u8, before, &memory.data)) return error.RejectedViewportModifiedMemory;
    std.debug.print("PASS {d} unrestricted viewport cases: explicit unit clamp, GL/DX planes, reversed/offset scale, tiny positive D32, all comparisons and write masks; crossing-plane coverage, interpolated clamp, native clip PSO reuse and rejected-clamp memory preservation\n", .{cases});
}

fn guestCmaskProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    renderer.draw_batch_limit = 64;
    var state = try graphicsState(65, 37, 72);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    const packets = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 2 };
    try state.writeRegister(.context, 0x31f, 0x800); // CMASK at 0x80000.
    try state.writeRegister(.context, 0x398, 0);
    for ([_]u32{ 10, 6, 12 }) |format| for ([_]gpu.resources.TileMode{ .render_target, .depth }) |mode| {
        const info = (format << 2) | (if (format == 10) @as(u32, 0) else (7 << 8));
        try state.writeRegister(.context, 0x3b8, (@as(u32, @intFromEnum(mode)) << 14) | (24 << 19) | (1 << 26));
        try state.writeRegister(.context, 0x31c, info | (1 << 13));
        try state.writeRegister(.context, 0x323, if (format == 12) 0x34003800 else if (format == 6) 0x701c03c0 else 0xff315783);
        try state.writeRegister(.context, 0x324, 0x3c003000);
        const target = gpu.resources.decodeColorTarget(&state, 0, 15).?;
        const layout = try d3d12.surfaces.colorLayout(target);
        const cmask = (try d3d12.surfaces.Cmask.fromTarget(target, &state)).?;
        const backing = memory.data[0x2000..][0..@intCast(layout.required_source_bytes)];
        const keys = memory.data[0x80000..][0..@intCast(cmask.layout.required_bytes)];
        const reference = try allocator.alloc(u8, backing.len);
        defer allocator.free(reference);
        var expected_keys: [4096]u8 = undefined;
        for (0..2) |variant| {
            @memset(backing, 0x27);
            @memset(keys, 0xaf); // Inactive nibbles must remain untouched.
            var y: u32 = 0;
            while (y < 37) : (y += 8) {
                var x: u32 = 0;
                while (x < 65) : (x += 8) try cmask.layout.setValue(keys, x, y, 0, if ((x / 8 + y / 8) % 3 == 0) 0 else 15);
            }
            @memcpy(&expected_keys, keys);
            // Independent initial reference: write each complete 8x8 region
            // in color swizzle order; only the active view is rasterized.
            var padded = layout;
            padded.width = 72;
            padded.height = 40;
            if (variant == 0) for (0..40) |py| for (0..72) |px| {
                if ((px / 8 + py / 8) % 3 != 0) continue;
                const offset: usize = @intCast(try padded.sourceByteOffset(@intCast(px), @intCast(py), 0));
                @memcpy(backing[offset..][0..cmask.texel_bytes], cmask.texel[0..cmask.texel_bytes]);
            };
            try state.writeRegister(.context, 0x31c, info | (if (variant == 1) @as(u32, 1 << 13) else 0));
            _ = try executor.execute(&packets);
            // A metadata read must flush a queued draw before returning keys.
            var published: [4096]u8 = undefined;
            const backend = renderer.dcbBackend();
            if (variant == 1) {
                if (!backend.vtable.read(backend.context, cmask.address, &published)) return error.CmaskDependencyReadFailed;
            } else try renderer.flushDraws();
            if (variant == 0) @memcpy(reference, backing) else {
                if (!std.mem.eql(u8, reference, backing)) return error.CmaskRenderMismatch;
                y = 0;
                while (y < 37) : (y += 8) {
                    var x: u32 = 0;
                    while (x < 65) : (x += 8) try cmask.layout.setValue(&expected_keys, x, y, 0, 15);
                }
                if (!std.mem.eql(u8, &expected_keys, keys) or !std.mem.eql(u8, &published, keys)) return error.CmaskPublicationMismatch;
                // A second staging must retain the newly drawn pixels.
                _ = try executor.execute(&packets);
                try renderer.flushDraws();
                if (!std.mem.eql(u8, reference, backing)) return error.CmaskStaleClear;
            }
        }
        // Invalid compression must leave both pixels and metadata untouched.
        try cmask.layout.setValue(keys, 64, 32, 0, 7);
        @memcpy(&expected_keys, keys);
        const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
        if (renderer.draw(&state, packet)) |_| return error.CmaskCompressedStateAccepted else |err| if (err != error.CompressedColorTargetNotImplemented) return err;
        if (!std.mem.eql(u8, reference, backing) or !std.mem.eql(u8, &expected_keys, keys)) return error.RejectedCmaskModifiedMemory;
    };
    std.debug.print("PASS CMASK clear/expanded blocks: RGBA8/R11G11B10F/RGBA16F, independent R/Z color swizzles, edge padding, queued metadata reads, stale-clear prevention and invalid-state isolation\n", .{});
}

fn guestMipTargetProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    renderer.draw_batch_limit = 64;
    var device = try d3d12.Device.init(false);
    defer device.deinit();
    var vs = try rdna2.decodeProgram(allocator, vertex);
    defer vs.deinit(allocator);
    var ps = try rdna2.decodeProgram(allocator, fragment);
    defer ps.deinit(allocator);
    var native_vs = try rdna2.translateProgramSpirv(allocator, &vs, .{ .stage = .vertex, .vertex_index_vgpr = 5, .allow_control_flow_fallback = false });
    defer native_vs.deinit(allocator);
    var native_ps = try rdna2.translateProgramSpirv(allocator, &ps, .{ .stage = .fragment, .allow_control_flow_fallback = false });
    defer native_ps.deinit(allocator);
    const packet = gpu.pm4.Packet{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    var cases: usize = 0;
    for ([_][2]u32{ .{ 128, 128 }, .{ 129, 73 } }) |extent| for ([_]u32{ 10, 12 }) |format| for ([_]gpu.resources.TileMode{ .linear, .render_target, .depth }) |mode| {
        const bytes: u8 = if (format == 12) 8 else 4;
        const texture = try gpu.TextureLayout.init(.{ .tile_mode = mode, .width = extent[0], .height = extent[1], .depth_or_layers = 2, .mip_levels = 8 }, bytes);
        if (texture.required_source_bytes > memory.data.len - 0x10000) return error.MipProbeTooLarge;
        @memset(memory.data[0x10000..], 0x37);
        const expected = try allocator.dupe(u8, memory.data[0x10000..]);
        defer allocator.free(expected);
        var state = try graphicsState(extent[0], extent[1], 136);
        try state.writeRegister(.context, 0x318, 0x100);
        try state.writeRegister(.context, 0x31c, (format << 2) | (if (format == 12) @as(u32, 7 << 8) else 0));
        try state.writeRegister(.context, 0x3b0, ((extent[0] - 1) << 14) | (extent[1] - 1) | (7 << 28));
        try state.writeRegister(.context, 0x3b8, (@as(u32, @intFromEnum(mode)) << 14) | (1 << 24));
        for ([_]u32{ 0, 1 }) |slice| for ([_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 0 }) |level| {
            const view = try texture.subresource(@intCast(level), slice, 1);
            const pixels = try allocator.alloc(u8, @intCast(try view.stagingBytes()));
            defer allocator.free(pixels);
            try view.detile(expected, pixels);
            var draw = try d3d12.Draw.fullTarget(view.width, view.height);
            draw.color_format = if (format == 12) 10 else 28;
            try device.drawSpirv(native_vs.words, native_ps.words, draw, pixels);
            try view.tile(pixels, expected);
            try state.writeRegister(.context, 0x31b, slice | (slice << 13) | (level << 26));
            try renderer.draw(&state, packet);
            // Changing the selected mip/slice must publish the preceding
            // queued view before staging the next one. Compare after the
            // final return to level zero, including every neighbor/guard byte.
            cases += 1;
        };
        try renderer.flushDraws();
        if (!std.mem.eql(u8, expected, memory.data[0x10000..])) {
            std.debug.print("Mip target mismatch {d}x{d} format={d} mode={s}\n", .{ extent[0], extent[1], format, @tagName(mode) });
            return error.MipTargetNeighborMismatch;
        }
    };
    // Matching MRT views can come from different-sized base allocations.
    // Conversely, equal base extents do not imply equal selected mip extents.
    var mrt: std.ArrayList(u32) = .empty;
    defer mrt.deinit(allocator);
    try mrt.appendSlice(allocator, fragment[0 .. fragment.len - 3]);
    try mrt.appendSlice(allocator, &.{ 0xf800000f, 0x03020100, 0xf800081f, 0x03020100, 0xbf810000 });
    @memcpy(memory.data[0x400..][0 .. mrt.items.len * 4], std.mem.sliceAsBytes(mrt.items));
    var state = try graphicsState(128, 128, 128);
    try state.writeRegister(.context, 0x318, 0x100);
    try state.writeRegister(.context, 0x31b, 1 << 26);
    try state.writeRegister(.context, 0x3b0, (127 << 14) | 127 | (7 << 28));
    try state.writeRegister(.context, 0x3b8, (27 << 14) | (1 << 24));
    try state.writeRegister(.context, 0x327, 0x700);
    try state.writeRegister(.context, 0x328, 7);
    try state.writeRegister(.context, 0x32a, 0);
    try state.writeRegister(.context, 0x32b, 10 << 2);
    try state.writeRegister(.context, 0x391, 0);
    try state.writeRegister(.context, 0x3b1, (63 << 14) | 63 | (6 << 28));
    try state.writeRegister(.context, 0x3b9, (27 << 14) | (1 << 24));
    try state.writeRegister(.context, 0x08e, 255);
    try state.writeRegister(.context, 0x08f, 255);
    @memset(memory.data[0x10000..], 0);
    try renderer.draw(&state, packet);
    try renderer.flushDraws();
    for (0..2) |slot| {
        const target = gpu.resources.decodeColorTarget(&state, @intCast(slot), 255).?;
        const layout = try d3d12.surfaces.colorLayout(target);
        var result = try d3d12.surfaces.Staged.read(allocator, memory.access(), target.address, layout);
        defer result.deinit();
        if (!std.mem.eql(u8, result.pixels[(32 * 64 + 32) * 4 ..][0..4], &.{ 255, 0, 0, 255 })) return error.MipMrtOutputMismatch;
    }
    const before = try allocator.dupe(u8, &memory.data);
    defer allocator.free(before);
    try state.writeRegister(.context, 0x32a, 1 << 26); // Second view is now 32x32.
    try std.testing.expectError(error.MismatchedRenderTargetExtents, renderer.draw(&state, packet));
    if (!std.mem.eql(u8, before, &memory.data)) return error.RejectedMipMrtModifiedMemory;
    std.debug.print("PASS {d} mip/slice target draws: RGBA8/RGBA16F, linear/R/Z layouts, odd extents, all tail levels, queued view changes, untouched neighbors and effective MRT extents\n", .{cases});
}

fn guestSrgbTargetProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    const packet = gpu.pm4.Packet{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    try renderer.draw(&state, packet);
    try renderer.flushDraws();
    const coverage = memory.data[0x2000..0x5000].*;
    const source = [4]f32{ 0.002, 0.25, 0.7, 0.5 };
    const destination = [4]u8{ 64, 128, 192, 160 };
    const shader = [_]u32{
        vop1(1, 0, 255), @bitCast(source[0]), vop1(1, 1, 255), @bitCast(source[1]),
        vop1(1, 2, 255), @bitCast(source[2]), vop1(1, 3, 255), @bitCast(source[3]),
        0xf800080f,      0x03020100,          0xbf810000,
    };
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(shader))], std.mem.asBytes(&shader));
    try state.writeRegister(.context, 0x318, 0x100);
    try state.writeRegister(.context, 0x3b8, 27 << 14);
    try state.writeRegister(.context, 0x325, 0xa00);
    try state.writeRegister(.context, 0x3a8, 0);
    var cases: usize = 0;
    // Revisit UNORM after SRGB on the same backing: RTV, PSO and retained
    // attachment identities must distinguish the two encodings.
    for ([_]u32{ 6, 0, 6 }) |number_type| for ([_]bool{ false, true }) |bgra| for ([_]u8{ 0, 0x20, 0xff }) |dcc_key| for ([_]bool{ false, true }) |blend| {
        var raw = destination;
        if (bgra) std.mem.swap(u8, &raw[0], &raw[2]);
        try state.writeRegister(.context, 0x31c, (10 << 2) | (number_type << 8) | (if (bgra) @as(u32, 1 << 11) else 0) | (if (dcc_key != 0) @as(u32, 1 << 28) else 0));
        try state.writeRegister(.context, 0x323, std.mem.readInt(u32, &raw, .little));
        try state.writeRegister(.context, 0x1e0, if (blend) (1 << 30) | 8 else 0); // src * destination color/alpha.
        const target = gpu.resources.decodeColorTarget(&state, 0, 15).?;
        const layout = try d3d12.surfaces.colorLayout(target);
        const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
        const keys = memory.data[0xa0000..][0..d3d12.surfaces.Dcc.blockCount(backing.len)];
        for (0..backing.len / 4) |i| @memcpy(backing[i * 4 ..][0..4], &raw);
        if (dcc_key == 0x20) @memset(backing, 0xa7); // All bits come from the register clear.
        @memset(keys, dcc_key);
        const expected = try allocator.alloc(u8, backing.len);
        defer allocator.free(expected);
        for (0..expected.len / 4) |i| @memcpy(expected[i * 4 ..][0..4], &raw);
        var output: [4]u8 = undefined;
        for (0..4) |channel| {
            const srgb = number_type == 6 and channel != 3;
            var dst = @as(f32, @floatFromInt(destination[channel])) / 255;
            if (srgb) dst = if (dst <= 0.04045) dst / 12.92 else std.math.pow(f32, (dst + 0.055) / 1.055, 2.4);
            var value = source[channel] * (if (blend) dst else 1);
            if (srgb) value = if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
            output[channel] = @intFromFloat(@round(value * 255));
        }
        if (bgra) std.mem.swap(u8, &output[0], &output[2]);
        for (0..37) |y| for (0..65) |x| {
            if (coverage[(y * 72 + x) * 4] != 255) continue;
            const offset: usize = @intCast(try layout.sourceByteOffset(@intCast(x), @intCast(y), 0));
            @memcpy(expected[offset..][0..4], &output);
        };
        try renderer.draw(&state, packet);
        try renderer.flushDraws();
        for (backing, expected, 0..) |actual, wanted, i| if (@abs(@as(i16, actual) - wanted) > 1) {
            std.debug.print("SRGB mismatch type={d} bgra={} dcc={x} blend={} byte={d}: {d}, expected {d}\n", .{ number_type, bgra, dcc_key, blend, i, actual, wanted });
            return error.SrgbTargetMismatch;
        };
        for (keys) |key| if (key != (if (dcc_key != 0) @as(u8, 0xff) else 0)) return error.SrgbDccPublicationMismatch;
        cases += 1;
    };
    std.debug.print("PASS {d} SRGB/UNORM target cases: RGB transfer curve, linear destination blending, untransformed alpha, BGRA, DCC register clears and format cache switching\n", .{cases});
}

fn guestSurfaceProbe(allocator: std.mem.Allocator, vertex: []const u32, fragment: []const u32) !void {
    var memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. fragment.len * 4], std.mem.sliceAsBytes(fragment));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(259, 145, 280);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    const initial = try allocator.alloc(u8, 259 * 145 * 4);
    defer allocator.free(initial);
    for (initial, 0..) |*byte, i| byte.* = if (i % 4 == 3) 255 else @truncate(i *% 17 +% (i >> 8));
    var reference: ?[]u8 = null;
    defer if (reference) |bytes| allocator.free(bytes);
    for ([_]gpu.resources.TileMode{ .linear, .standard_256b, .standard_4kb, .standard_64kb, .partially_resident, .render_target }) |mode| {
        try state.writeRegister(.context, 0x3b8, @as(u32, @intFromEnum(mode)) << 14);
        const target = gpu.resources.decodeColorTarget(&state, 0, 15).?;
        const layout = try d3d12.surfaces.colorLayout(target);
        @memset(memory.data[0x2000..], 0xa7);
        const allocation = memory.data[0x2000..][0..@intCast(layout.required_source_bytes)];
        try layout.tile(initial, allocation);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        var staged = try d3d12.surfaces.Staged.read(allocator, memory.access(), target.address, layout);
        defer staged.deinit();
        if (reference) |expected| {
            if (!std.mem.eql(u8, expected, staged.pixels)) return error.TiledDrawImageMismatch;
        } else reference = try allocator.dupe(u8, staged.pixels);
        const expected_backing = try allocator.alloc(u8, allocation.len);
        defer allocator.free(expected_backing);
        @memset(expected_backing, 0xa7);
        try layout.tile(reference.?, expected_backing);
        if (!std.mem.eql(u8, allocation, expected_backing)) return error.TiledPaddingModified;
        for (memory.data[0x2000 + allocation.len ..]) |byte| if (byte != 0xa7) return error.SurfaceWriteOutOfBounds;
        if (mode == .render_target or mode == .linear) {
            const scanout = try d3d12.surfaces.scanoutLayout(259, 145, 280, if (mode == .linear) 1 else 0);
            var presented = try d3d12.surfaces.Staged.read(allocator, memory.access(), target.address, scanout);
            defer presented.deinit();
            if (!std.mem.eql(u8, reference.?, presented.pixels)) return error.ScanoutLayoutMismatch;
        }
    }
    // BGRA guest storage carries the same logical RGBA shader outputs. Test
    // destination-dependent blending too, so upload and readback must both swap.
    try state.writeRegister(.context, 0x31c, (10 << 2) | (1 << 11));
    try state.writeRegister(.context, 0x1e0, (1 << 30) | 8); // src * destination color.
    const bgra_target = gpu.resources.decodeColorTarget(&state, 0, 15).?;
    const bgra_layout = try d3d12.surfaces.colorLayout(bgra_target);
    var logical = try d3d12.surfaces.Staged.readColor(allocator, null, null, memory.access(), bgra_target.address, bgra_layout, null, true, null);
    defer logical.deinit();
    for (0..259 * 145) |i| logical.pixels[i * 4 ..][0..4].* = .{ 51, 102, 153, 255 };
    try logical.write(memory.access());
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    var bgra = try d3d12.surfaces.Staged.read(allocator, memory.access(), bgra_target.address, bgra_layout);
    defer bgra.deinit();
    const center = (72 * 259 + 129) * 4;
    if (!std.mem.eql(u8, bgra.pixels[center..][0..4], &.{ 0, 0, 51, 255 }) or
        !std.mem.eql(u8, bgra.pixels[0..4], &.{ 153, 102, 51, 255 })) return error.BgraTargetBlendMismatch;
    std.debug.print("PASS six guest surface layouts, BGRA destination blending, macro-tile XOR, padding and tiled/linear scanout staging\n", .{});
}

fn guestVaryingProbe(allocator: std.mem.Allocator, vertex: []const u32) !void {
    var memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(allocator);
    try words.appendSlice(allocator, vertex[0 .. vertex.len - 1]);
    try words.appendSlice(allocator, &.{
        vop2(0x03, 9, 5, 8),  vop2(0x03, 10, 6, 8),
        vop1(0x01, 11, 255),  0x3f000000,
        vop2(0x08, 9, 9, 11), vop2(0x08, 10, 10, 11),
        vop1(0x01, 11, 255),  0x3e800000,
        0xf8000a3f, 0x080b0a09, 0xbf810000, // PARAM3 = normalized x/y, .25, 1.
    });
    @memcpy(memory.data[0x200..][0 .. words.items.len * 4], std.mem.sliceAsBytes(words.items));
    words.clearRetainingCapacity();
    for (0..4) |component| {
        const attr: u32 = if (component % 2 == 0) 0 else 4;
        for (0..2) |phase| try words.append(allocator, 0xc8000000 | (@as(u32, @intCast(component)) << 18) |
            (@as(u32, @intCast(phase)) << 16) | (attr << 10) | (@as(u32, @intCast(component)) << 8) | @as(u32, @intCast(phase)));
    }
    try words.appendSlice(allocator, &.{ 0xf800080f, 0x03020100, 0xbf810000 });
    @memcpy(memory.data[0x400..][0 .. words.items.len * 4], std.mem.sliceAsBytes(words.items));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.context, 0x191, 3);
    try state.writeRegister(.context, 0x195, 3); // Two distinct ATTRs consume PARAM3.
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    for ([_][2]usize{ .{ 32, 18 }, .{ 28, 18 }, .{ 36, 18 }, .{ 32, 12 }, .{ 32, 23 } }) |point| {
        const x, const y = point;
        const expected = [4]f32{ (@as(f32, @floatFromInt(x)) + 0.5) / 65 * 255, (1 - (@as(f32, @floatFromInt(y)) + 0.5) / 37) * 255, 63.75, 255 };
        const actual = memory.data[0x2000 + (y * 72 + x) * 4 ..][0..4];
        for (actual, expected) |a, e| if (@abs(@as(f32, @floatFromInt(a)) - e) > 1) {
            std.debug.print("Varying mismatch at {d},{d}: {any}, expected {any}\n", .{ x, y, actual, expected });
            return error.FragmentVaryingMismatch;
        };
    }
    std.debug.print("PASS native interpolated RDNA2 PARAM values and two ATTR inputs remapped to PARAM3\n", .{});
    const smooth = memory.data[0x2000..0x5000].*;
    try state.writeRegister(.context, 0x191, 0x403); // Flat ATTR0; smooth ATTR4 still aliases PARAM3.
    for ([_]bool{ false, true }) |mov| for ([_]bool{ false, true }) |last| for ([_]u32{ 0, 1, 2, 4 }) |width| {
        words.clearRetainingCapacity();
        for (0..4) |component| {
            const attr: u32 = if (component % 2 == 0) 0 else 4;
            if (mov and attr == 0) {
                try words.append(allocator, 0xc8020002 | (@as(u32, @intCast(component)) << 18) | (@as(u32, @intCast(component)) << 8));
            } else for (0..2) |phase| try words.append(allocator, 0xc8000000 | (@as(u32, @intCast(component)) << 18) |
                (@as(u32, @intCast(phase)) << 16) | (attr << 10) | (@as(u32, @intCast(component)) << 8) | @as(u32, @intCast(phase)));
        }
        try words.appendSlice(allocator, &.{ 0xf800080f, 0x03020100, 0xbf810000 });
        @memcpy(memory.data[0x400..][0 .. words.items.len * 4], std.mem.sliceAsBytes(words.items));
        try state.writeRegister(.context, 0x205, if (last) 1 << 19 else 0);
        @memset(memory.data[0x2000..0x5000], 0);
        if (width == 0) {
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        } else {
            for (0..3) |i| switch (width) {
                1 => memory.data[0x600 + i] = @intCast(i),
                2 => std.mem.writeInt(u16, memory.data[0x600 + i * 2 ..][0..2], @intCast(i), .little),
                else => std.mem.writeInt(u32, memory.data[0x600 + i * 4 ..][0..4], @intCast(i), .little),
            };
            const source = memory.data[0x600..0x60c].*;
            _ = try executor.execute(&.{ command(gpu.pm4.index_type, 1), if (width == 1) 2 else if (width == 2) 0 else 1, command(gpu.pm4.draw_index_2, 5), 3, 0x600, 0, 3, 0 });
            if (!std.mem.eql(u8, &source, memory.data[0x600..0x60c])) return error.FlatIndicesModified;
        }
        for (memory.data[0x2000..0x5000], 0..) |actual, i| {
            const covered = i < 37 * 72 * 4 and smooth[i - i % 4 + 3] == 255;
            const expected: u8 = if (covered and i % 4 == 0) (if (last) 223 else 32) else smooth[i];
            if (@abs(@as(i16, actual) - expected) > 1) {
                std.debug.print("Flat mismatch MOV={} last={} width={d} byte={d}: {d} expected {d}\n", .{ mov, last, width, i, actual, expected });
                return error.FlatInterpolationMismatch;
            }
        }
    };
    std.debug.print("PASS 16 mixed flat/smooth full-frame comparisons: MOV P0/P1-P2, first/last provoking vertices, auto/8/16/32-bit indices, shared PARAM and untouched guest index storage\n", .{});
    // Hardware default inputs need no matching vertex export. Exercise all
    // presets and repeat one to check the translation/PSO cache identity.
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    for ([_]u32{ 0, 1, 2, 3, 0 }) |preset| for ([_]bool{ false, true }) |mov| {
        words.clearRetainingCapacity();
        for (0..4) |component| {
            const channel: u32 = @intCast(component);
            if (mov) {
                try words.append(allocator, 0xc8020002 | (channel << 18) | (channel << 8));
            } else for (0..2) |phase| try words.append(allocator, 0xc8000000 | (channel << 18) | (@as(u32, @intCast(phase)) << 16) | (channel << 8) | @as(u32, @intCast(phase)));
        }
        try words.appendSlice(allocator, &.{ 0xf800080f, 0x03020100, 0xbf810000 });
        @memcpy(memory.data[0x400..][0 .. words.items.len * 4], std.mem.sliceAsBytes(words.items));
        try state.writeRegister(.context, 0x191, 0x20 | (preset << 8));
        @memset(memory.data[0x2000..0x5000], 0xa7);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        for (memory.data[0x2000..0x5000], 0..) |actual, i| {
            const covered = i < 37 * 72 * 4 and smooth[i - i % 4 + 3] == 255;
            const one = if (i % 4 == 3) preset & 1 != 0 else preset & 2 != 0;
            const expected: u8 = if (!covered) 0xa7 else if (one) 255 else 0;
            if (actual != expected) return error.FragmentDefaultValueMismatch;
        }
    };
    std.debug.print("PASS constant fragment inputs: four DEFAULT_VAL presets, absent VS exports, P0/P1-P2, full-image/padding and cache reuse\n", .{});
}

fn mipProbeColor(layer: usize, level: usize, compressed: bool) [4]u8 {
    var color = [4]u8{ @intCast(16 + (layer % 60) * 3), @intCast(30 + level * 60), @intCast(40 + level * 40), 255 };
    if (compressed) {
        color[0] = @intCast((@as(u32, color[0] >> 3) * 255 + 15) / 31);
        color[1] = @intCast((@as(u32, color[1] >> 2) * 255 + 31) / 63);
        color[2] = @intCast((@as(u32, color[2] >> 3) * 255 + 15) / 31);
    }
    return color;
}

fn bc6ProbeEndpoints(layer: usize, level: usize, signed: bool) [3]i16 {
    const positive = [4][3]i16{ .{ 0, 495, 800 }, .{ 1023, 700, 300 }, .{ 250, 650, 900 }, .{ 990, 10, 511 } };
    const negative = [4][3]i16{ .{ -247, 248, 400 }, .{ 511, -511, 0 }, .{ 200, -100, 350 }, .{ -400, 300, 100 } };
    return (if (signed) negative else positive)[(layer + level) % 4];
}

// Independent mode-11 constant-endpoint reference, following the specified
// unquantize/finish steps (not the renderer's upload/translation code):
// https://learn.microsoft.com/en-us/windows/win32/direct3d11/bc6h-format
fn bc6ProbeHalf(value: i16, signed: bool) u16 {
    const magnitude: u32 = @intCast(@abs(value));
    const expanded: u32 = if (magnitude == 0) 0 else if (signed)
        (if (magnitude >= 511) @as(u32, 32767) else (magnitude * 32768 + 16384) / 512)
    else
        (if (magnitude == 1023) @as(u32, 65535) else (magnitude * 65536 + 32768) / 1024);
    const bits: u16 = @intCast(expanded * 31 / (if (signed) @as(u32, 32) else 64));
    return bits | (if (value < 0) @as(u16, 0x8000) else 0);
}

fn guestBc6ImageProbe(allocator: std.mem.Allocator, vertex: []const u32, solid_pixel: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. solid_pixel.len * 4], std.mem.sliceAsBytes(solid_pixel));
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var state = try graphicsState(65, 37, 72);
    const packet = gpu.pm4.Packet{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    try renderer.draw(&state, packet);
    const coverage = memory.data[0x2000..0x5000].*;
    try state.writeRegister(.context, 0x31c, (12 << 2) | (7 << 8)); // Preserve negative and HDR output as half floats.
    try state.writeRegister(.shader, 0x00b, 14 << 1);
    try state.writeRegister(.shader, 0x014, 0x92);
    try state.writeRegister(.shader, 0x015, 0xfff000);
    try state.writeRegister(.shader, 0x016, 2 << 26); // Linear LOD blend, point XY.
    var cases: usize = 0;
    for ([_]u32{ 8, 256 }) |size| for ([_]u32{ 0, 1, 2 }) |dimension| for ([_]bool{ false, true }) |signed| for ([_]gpu.resources.TileMode{ .linear, .standard_4kb }) |mode| {
        const levels: u32 = if (size == 8) 4 else 9;
        const layers: u32 = if (dimension == 0) 1 else 6;
        const image_type: u32 = if (dimension == 0) 9 else if (dimension == 1) 11 else 13;
        const format: u32 = if (signed) 180 else 179;
        const words = [_]u32{ 0x100, (format << 20) | (((size - 1) & 3) << 30), ((size - 1) >> 2) | ((size - 1) << 14), (image_type << 28) | 0xfac | ((levels - 1) << 16) | (@as(u32, @intFromEnum(mode)) << 20), layers - 1, (levels - 1) << 4, 0, 0 };
        const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&words));
        if (texture.required_source_bytes > memory.data.len - 0x10000) return error.Bc6ProbeTooLarge;
        const backing = memory.data[0x10000..][0..@intCast(texture.required_source_bytes)];
        @memset(backing, 0xab);
        for (0..layers) |layer| for (0..levels) |level| {
            const view = try texture.subresource(@intCast(level), @intCast(layer), 1);
            const blocks = try allocator.alloc(u8, @intCast(try view.stagingBytes()));
            defer allocator.free(blocks);
            var encoded: u128 = 3; // Mode 11: two independent 10-bit RGB endpoints.
            for (0..2) |endpoint| for (bc6ProbeEndpoints(layer, level, signed), 0..) |value, channel| {
                encoded |= @as(u128, @as(u16, @bitCast(value)) & 1023) << @intCast(5 + endpoint * 30 + channel * 10);
            };
            for (0..blocks.len / 16) |i| std.mem.writeInt(u128, blocks[i * 16 ..][0..16], encoded, .little);
            try view.tile(blocks, backing);
        };
        const before = try allocator.dupe(u8, backing);
        defer allocator.free(before);
        for (words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
        const sample_dim: u32 = if (dimension == 0) 1 else if (dimension == 1) 3 else 5;
        const shader = [_]u32{ vop1(1, 0, 255), @bitCast(@as(f32, if (dimension == 1) 1.5 else 0.5)), vop1(1, 1, 256), vop1(1, 2, 12), vop1(1, 3, 13), 0xf0900f00 | (sample_dim << 3), 0x00400400, 0xf800080f, 0x07060504, 0xbf810000 };
        @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(shader))], std.mem.asBytes(&shader));
        for ([_]u32{ 0, layers - 1 }) |layer| for (0..levels * 2 - 1) |step| {
            const lod: f32 = @as(f32, @floatFromInt(step)) * 0.5;
            try state.writeRegister(.shader, 0x018, @bitCast(if (dimension == 0) lod else @as(f32, @floatFromInt(layer))));
            try state.writeRegister(.shader, 0x019, @bitCast(lod));
            @memset(memory.data[0x2000..0x8000], 0x37);
            try renderer.draw(&state, packet);
            var expected = [4]u16{ 0, 0, 0, 0x3c00 };
            const low = bc6ProbeEndpoints(layer, step / 2, signed);
            const high = bc6ProbeEndpoints(layer, (step + 1) / 2, signed);
            for (0..3) |channel| {
                const a: f16 = @bitCast(bc6ProbeHalf(low[channel], signed));
                const b: f16 = @bitCast(bc6ProbeHalf(high[channel], signed));
                expected[channel] = @bitCast(@as(f16, @floatCast((@as(f32, a) + @as(f32, b)) * 0.5)));
            }
            for (0..37) |y| for (0..72) |x| for (0..4) |channel| {
                const covered = x < 65 and coverage[(y * 72 + x) * 4] == 255;
                const wanted: u16 = if (covered) expected[channel] else 0x3737;
                const actual = std.mem.readInt(u16, memory.data[0x2000 + ((y * 72 + x) * 4 + channel) * 2 ..][0..2], .little);
                if (@abs(@as(i32, actual) - wanted) > 1) {
                    std.debug.print("BC6 mismatch size={d} dim={d} signed={} mode={s} layer={d} lod={d} channel={d}: 0x{x}, expected 0x{x}\n", .{ size, dimension, signed, @tagName(mode), layer, lod, channel, actual, wanted });
                    return error.Bc6HdrSamplingMismatch;
                }
            };
            cases += 1;
        };
        if (!std.mem.eql(u8, before, backing)) return error.Bc6SourceModified;
    };
    const before = memory.data[0x2000..0x8000].*;
    try state.writeRegister(.shader, 0x014, 0x92 | (1 << 20));
    try std.testing.expectError(error.GraphicsSamplerModeNotImplemented, renderer.draw(&state, packet));
    if (!std.mem.eql(u8, &before, memory.data[0x2000..0x8000])) return error.Bc6InvalidSrgbModifiedTarget;
    std.debug.print("PASS {d} BC6H UF16/SF16 frame checks: negative/HDR half values, 2D/cube/array, 256x256 GTA layout, nine mips through 1x1, linear LOD blends, source/padding preservation and invalid sRGB rejection\n", .{cases});
}

fn guestMipImageProbe(allocator: std.mem.Allocator, vertex: []const u32, solid_pixel: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. solid_pixel.len * 4], std.mem.sliceAsBytes(solid_pixel));
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.shader, 0x00b, 14 << 1);
    try state.writeRegister(.shader, 0x014, 0x92);
    try state.writeRegister(.shader, 0x015, 0xfff000);
    try state.writeRegister(.shader, 0x016, 2 << 26); // Linear mip filtering; point within each mip.
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    @memset(memory.data[0x2000..0x5000], 0xa7);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    const coverage = memory.data[0x2000..0x5000].*;
    var cases: usize = 0;
    for ([_][2]u32{ .{ 8, 8 }, .{ 96, 32 } }) |shape| for ([_]u32{ 0, 1, 2 }) |dimension| for ([_]u16{ 56, 169 }) |format| for ([_]gpu.resources.TileMode{ .linear, .standard_4kb }) |mode| {
        if (dimension == 1 and shape[0] != shape[1]) continue;
        const layers: u32 = if (dimension == 0) 1 else if (dimension == 1) 12 else if (shape[0] == 8) 78 else 2;
        const first: u32 = if (dimension == 0) 0 else if (dimension == 1) 6 else 2;
        const image_type: u32 = if (dimension == 0) 9 else if (dimension == 1) 11 else 13;
        const words = [_]u32{ 0x100, (@as(u32, format) << 20) | (((shape[0] - 1) & 3) << 30), ((shape[0] - 1) >> 2) | ((shape[1] - 1) << 14), (image_type << 28) | 0xfac | (3 << 16) | (@as(u32, @intFromEnum(mode)) << 20), if (dimension == 0) 0 else (layers + first - 1) | (first << 16), 3 << 4, 0, 0 };
        const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&words));
        const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
        @memset(backing, 0xab);
        for (0..layers) |layer| for (0..4) |level| {
            const view = try layout.subresource(@intCast(level), @intCast(layer), 1);
            const pixels = try allocator.alloc(u8, @intCast(try view.stagingBytes()));
            defer allocator.free(pixels);
            const color = mipProbeColor(layer, level, false);
            if (format == 56) {
                for (0..pixels.len / 4) |i| @memcpy(pixels[i * 4 ..][0..4], &color);
            } else {
                const rgb565 = (@as(u16, color[0] >> 3) << 11) | (@as(u16, color[1] >> 2) << 5) | @as(u16, color[2] >> 3);
                for (0..pixels.len / 8) |i| {
                    const block = pixels[i * 8 ..][0..8];
                    @memset(block, 0);
                    std.mem.writeInt(u16, block[0..2], rgb565, .little);
                }
            }
            try view.tile(pixels, backing);
        };
        const before = try allocator.dupe(u8, backing);
        defer allocator.free(before);
        for (words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
        const sample_dim: u32 = if (dimension == 0) 1 else if (dimension == 1) 3 else 5;
        const ps = [_]u32{ vop1(0x01, 0, 255), @bitCast(@as(f32, if (dimension == 1) 1.5 else 0.5)), vop1(0x01, 1, 256), vop1(0x01, 2, 12), vop1(0x01, 3, 13), 0xf0900f00 | (sample_dim << 3), 0x00400400, 0xf800080f, 0x07060504, 0xbf810000 };
        @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(ps))], std.mem.asBytes(&ps));
        for ([_]u32{ 0, layers - 1 }) |layer| for (0..7) |step| {
            const lod: f32 = @as(f32, @floatFromInt(step)) * 0.5;
            const face: f32 = @floatFromInt(if (dimension == 1) (layer / 6) * 8 + layer % 6 else layer);
            try state.writeRegister(.shader, 0x018, @bitCast(if (dimension == 0) lod else face));
            try state.writeRegister(.shader, 0x019, @bitCast(lod));
            @memset(memory.data[0x2000..0x5000], 0xa7);
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
            const low = mipProbeColor(layer, step / 2, format != 56);
            const high = mipProbeColor(layer, @min(3, (step + 1) / 2), format != 56);
            for (memory.data[0x2000..0x5000], 0..) |actual, i| {
                const expected: u8 = if (coverage[i - i % 4 + 3] == 255) @intCast((@as(u16, low[i % 4]) + high[i % 4] + 1) / 2) else 0xa7;
                if (@abs(@as(i16, actual) - expected) > 2) {
                    std.debug.print("Mip mismatch dim={d} format={d} tile={f} layer={d} lod={d} byte={d}: {d} expected {d}\n", .{ dimension, format, mode, layer, lod, i, actual, expected });
                    return error.MipChainSamplingMismatch;
                }
            }
            cases += 1;
        };
        if (!std.mem.eql(u8, before, backing)) return error.MipChainSourceModified;
    };
    std.debug.print("PASS {d} mip-chain frame checks: 2D/cube/78-layer arrays, 96x32 partial chains, base slices, all levels and linear LOD blends, RGBA8/BC1 1x1 tails, linear/tiled memory and source preservation\n", .{cases});
}

fn volumeProbeColor(z: u32, level: u32) [4]u8 {
    return .{ @intCast(40 + level * 40), @intCast(16 + z * 24), @intCast(200 - level * 20), 255 };
}

fn volumeProbeExpected(w: f32, depth: u32, level: u32, linear: bool, repeat: bool) [4]f32 {
    const d: i32 = @intCast(@max(1, depth >> @as(u5, @intCast(level))));
    const z = w * @as(f32, @floatFromInt(d)) - (if (linear) @as(f32, 0.5) else 0);
    const low: i32 = @intFromFloat(@floor(z));
    const fraction = if (linear) z - @floor(z) else 0;
    var value: [4]f32 = @splat(0);
    for (0..2) |i| {
        const index = low + @as(i32, @intCast(i));
        const slice = if (repeat) @mod(index, d) else std.math.clamp(index, 0, d - 1);
        const color = volumeProbeColor(@intCast(slice), level);
        for (&value, color) |*v, c| v.* += @as(f32, @floatFromInt(c)) * (if (i == 0) 1 - fraction else fraction);
    }
    return value;
}

fn guestVolumeImageProbe(allocator: std.mem.Allocator, vertex: []const u32, solid: []const u32) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    @memcpy(memory.data[0x200..][0 .. vertex.len * 4], std.mem.sliceAsBytes(vertex));
    @memcpy(memory.data[0x400..][0 .. solid.len * 4], std.mem.sliceAsBytes(solid));
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.shader, 0x00b, 14 << 1);
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    @memset(memory.data[0x2000..0x5000], 0xa7);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    const coverage = memory.data[0x2000..0x5000].*;
    var cases: usize = 0;
    // Width, height, depth, mip count. Include one-texel fallback volumes,
    // odd single-level extents and a chain whose largest dimension is Z.
    for ([_][4]u32{ .{ 1, 1, 1, 1 }, .{ 5, 3, 7, 1 }, .{ 8, 8, 8, 4 }, .{ 1, 1, 8, 4 } }) |shape|
        for ([_]gpu.resources.TileMode{ .linear, .standard_4kb, .standard_64kb }) |mode|
            for ([_]u16{ 56, 71 }) |format| {
                if (mode == .linear and shape[3] > 1) continue; // Shared guest layout rejects linear volume mip chains.
                const bpp: usize = if (format == 71) 8 else 4;
                const words = [_]u32{ 0x100, (@as(u32, format) << 20) | (((shape[0] - 1) & 3) << 30), ((shape[0] - 1) >> 2) | ((shape[1] - 1) << 14), (10 << 28) | 0xfac | ((shape[3] - 1) << 16) | (@as(u32, @intFromEnum(mode)) << 20), shape[2] - 1, (shape[3] - 1) << 4, 0, 0 };
                const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&words));
                const backing = memory.data[0x10000..][0..@intCast(texture.required_source_bytes)];
                @memset(backing, 0xab);
                for (0..shape[3]) |level| {
                    const view = try texture.subresource(@intCast(level), 0, 1);
                    const pixels = try allocator.alloc(u8, @intCast(try view.stagingBytes()));
                    defer allocator.free(pixels);
                    for (0..view.depth_or_layers) |z| {
                        const color = volumeProbeColor(@intCast(z), @intCast(level));
                        for (0..view.width * view.height) |xy| {
                            const texel = pixels[(z * view.width * view.height + xy) * bpp ..][0..bpp];
                            if (format == 56) {
                                @memcpy(texel, &color);
                            } else {
                                for (color, 0..) |c, channel| {
                                    const half: f16 = @floatCast(@as(f32, @floatFromInt(c)) / 255);
                                    std.mem.writeInt(u16, texel[channel * 2 ..][0..2], @bitCast(half), .little);
                                }
                            }
                        }
                    }
                    try view.tile(pixels, backing);
                }
                const before = try allocator.dupe(u8, backing);
                defer allocator.free(before);
                for (words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
                const ps = [_]u32{ vop1(1, 0, 255), @bitCast(@as(f32, 0.5)), vop1(1, 1, 256), vop1(1, 2, 12), vop1(1, 3, 13), 0xf0900f10, 0x00400400, 0xf800080f, 0x07060504, 0xbf810000 };
                @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(ps))], std.mem.asBytes(&ps));
                for ([_]bool{ false, true }) |linear| for ([_]bool{ false, true }) |repeat| {
                    try state.writeRegister(.shader, 0x014, if (repeat) 0x12 else 0x92);
                    try state.writeRegister(.shader, 0x015, 0xfff000);
                    try state.writeRegister(.shader, 0x016, (2 << 26) | (if (linear) @as(u32, (1 << 20) | (1 << 22) | (2 << 24)) else (1 << 24)));
                    for ([_]f32{ -0.25, 0.0625, 0.5, 0.9375, 1.25 }) |w| for (0..shape[3] * 2 - 1) |step| {
                        try state.writeRegister(.shader, 0x018, @bitCast(w));
                        try state.writeRegister(.shader, 0x019, @bitCast(@as(f32, @floatFromInt(step)) * 0.5));
                        @memset(memory.data[0x2000..0x5000], 0xa7);
                        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
                        const low = volumeProbeExpected(w, shape[2], @intCast(step / 2), linear, repeat);
                        const high = volumeProbeExpected(w, shape[2], @intCast((step + 1) / 2), linear, repeat);
                        for (memory.data[0x2000..0x5000], 0..) |actual, i| {
                            const expected: f32 = if (coverage[i - i % 4 + 3] == 255) (low[i % 4] + high[i % 4]) * 0.5 else 0xa7;
                            if (@abs(@as(f32, @floatFromInt(actual)) - expected) > 2) {
                                std.debug.print("Volume mismatch shape={any} mode={f} format={d} linear={} repeat={} w={d} lodstep={d} byte={d}: {d} expected {d}\n", .{ shape, mode, format, linear, repeat, w, step, i, actual, expected });
                                return error.VolumeSamplingMismatch;
                            }
                        }
                        cases += 1;
                    };
                };
                if (!std.mem.eql(u8, before, backing)) return error.VolumeSourceModified;
            };
    // Identical bytes/extents do not make a Texture2D and Texture3D the same
    // native resource. Both directions must remain distinct within one batch.
    renderer.draw_batch_limit = 2;
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    const color = [_]u8{ 20, 60, 180, 255 };
    @memcpy(memory.data[0x10000..][0..4], &color);
    for ([_]bool{ false, true }) |reverse| {
        state = try graphicsState(65, 37, 72);
        try state.writeRegister(.shader, 0x00b, 12 << 1);
        @memset(memory.data[0x2000..0x5000], 0xa7);
        const groups = renderer.batch_groups;
        for (0..2) |i| {
            const volume = (i == 0) == reverse;
            const words = [_]u32{ 0x100, 56 << 20, 0, (@as(u32, if (volume) 10 else 9) << 28) | 0xfac, 0, 0, 0, 0, 0x92, 0xfff000, 1 << 24, 0 };
            for (words, 0..) |word, j| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(j)), word);
            const ps = [_]u32{ vop1(1, 0, 255), @bitCast(@as(f32, 0.5)), vop1(1, 1, 256), vop1(1, 2, 256), 0xf0800f00 | (@as(u32, if (volume) 2 else 1) << 3), 0x00400400, 0xf800080f, 0x07060504, 0xbf810000 };
            @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(ps))], std.mem.asBytes(&ps));
            try state.writeRegister(.context, 0x08e, if (i == 0) 3 else 12);
            try renderer.draw(&state, packet);
        }
        try renderer.flushDraws();
        if (renderer.batch_groups != groups + 1) return error.VolumeBatchNotShared;
        for (memory.data[0x2000..0x5000], 0..) |actual, i| {
            const expected: u8 = if (coverage[i - i % 4 + 3] == 255) color[i % 4] else 0xa7;
            if (actual != expected) return error.VolumeBatchDimensionMismatch;
        }
    }
    const unchanged = memory.data[0x2000..0x5000].*;
    try state.writeRegister(.shader, 0x00f, (10 << 28) | 0xfac);
    std.mem.writeInt(u32, memory.data[0x410..][0..4], 0xf0800f10, .little);
    for ([_]u32{ 0, 2 << 24, (1 << 20) | (1 << 24) }) |filter| {
        try state.writeRegister(.shader, 0x016, filter);
        if (renderer.draw(&state, packet)) |_| return error.VolumeMixedFilterAccepted else |err| if (err != error.GraphicsSamplerModeNotImplemented) return err;
    }
    if (!std.mem.eql(u8, &unchanged, memory.data[0x2000..0x5000])) return error.VolumeRejectedFilterModifiedTarget;
    std.debug.print("PASS {d} volume frame checks: RGBA8/RGBA16F, 1x1x1/odd extents/Z-major mip chains, linear/tiled layouts, Z clamp/wrap, spatial/LOD filtering, source preservation and 2D/3D batch isolation\n", .{cases});
}

fn anisoProbeTexel(x: i32, y: i32, level: u32, layer: u32) [4]f32 {
    const side: i32 = @as(i32, 64) >> @as(u5, @intCast(level));
    const ix: u32 = @intCast(std.math.clamp(x, 0, side - 1));
    const iy: u32 = @intCast(std.math.clamp(y, 0, side - 1));
    return .{ @floatFromInt(if (ix % 4 < 2) @as(u32, 32) else 224), @floatFromInt((iy * 13) % 256), @floatFromInt(level * 40 + layer * 50), 255 };
}

fn anisoProbeSample(u: f32, v: f32, level: u32, layer: u32, linear: bool) [4]f32 {
    const side: f32 = @floatFromInt(@as(u32, 64) >> @as(u5, @intCast(level)));
    if (!linear) return anisoProbeTexel(@intFromFloat(@floor(u * side)), @intFromFloat(@floor(v * side)), level, layer);
    const x = u * side - 0.5;
    const y = v * side - 0.5;
    const ix: i32 = @intFromFloat(@floor(x));
    const iy: i32 = @intFromFloat(@floor(y));
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    var color: [4]f32 = @splat(0);
    for (0..2) |dy| for (0..2) |dx| {
        const texel = anisoProbeTexel(ix + @as(i32, @intCast(dx)), iy + @as(i32, @intCast(dy)), level, layer);
        const weight = (if (dx == 0) 1 - fx else fx) * (if (dy == 0) 1 - fy else fy);
        for (&color, texel) |*c, t| c.* += weight * t;
    };
    return color;
}

fn guestAnisotropicProbe(allocator: std.mem.Allocator) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    const vs = [_]u32{ 0xe0382000, 0x80000005, 0xe0382010, 0x80000805, 0xf80000cf, 0x03020100, 0xf8000a0f, 0x0b0a0908, 0xbf810000 };
    @memcpy(memory.data[0x200..][0..@sizeOf(@TypeOf(vs))], std.mem.asBytes(&vs));
    var state = try graphicsState(16, 16, 16);
    try state.writeRegister(.shader, 0x04b, 4 << 1);
    for ([_]u32{ 0x1000, 32 << 16, 3, 0xfac }, 0..) |word, i| try state.writeRegister(.shader, 0x04c + @as(u32, @intCast(i)), word);
    try state.writeRegister(.context, 0x191, 0); // ATTR0 reads PARAM0.
    try state.writeRegister(.shader, 0x00b, 12 << 1);
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    var cases: usize = 0;
    for ([_]bool{ false, true }) |array| {
        const layer: u32 = if (array) 1 else 0;
        const words = [_]u32{ 0x100, (56 << 20) | (3 << 30), 15 | (63 << 14), (@as(u32, if (array) 13 else 9) << 28) | 0xfac | (3 << 16), layer, 3 << 4, 0, 0 };
        const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&words));
        const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
        @memset(backing, 0xab);
        for (0..layer + 1) |slice| for (0..4) |level| {
            const view = try layout.subresource(@intCast(level), @intCast(slice), 1);
            const pixels = try allocator.alloc(u8, @intCast(try view.stagingBytes()));
            defer allocator.free(pixels);
            const side = @as(usize, 64) >> @as(u6, @intCast(level));
            for (0..side) |y| for (0..side) |x| {
                const color = anisoProbeTexel(@intCast(x), @intCast(y), @intCast(level), @intCast(slice));
                for (color, 0..) |c, i| pixels[(y * side + x) * 4 + i] = @intFromFloat(c);
            };
            try view.tile(pixels, backing);
        };
        const before = try allocator.dupe(u8, backing);
        defer allocator.free(before);
        for (words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
        const ps = [_]u32{ 0xc8000000, 0xc8010001, 0xc8040100, 0xc8050101, vop1(1, 2, 255), @bitCast(@as(f32, @floatFromInt(layer))), 0xf0800f00 | (@as(u32, if (array) 5 else 1) << 3), 0x00400400, 0xf800080f, 0x07060504, 0xbf810000 };
        @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(ps))], std.mem.asBytes(&ps));
        for ([_]u32{ 1, 2, 3, 4 }) |ratio_code| for ([_]bool{ false, true }) |linear| for ([_]bool{ false, true }) |mag_aniso| for ([_]u32{ 0, 1, 2 }) |mip_filter| for ([_][2]f32{ .{ 4, 1 }, .{ 1, 8 }, .{ 0.25, 0.25 }, .{ 16, 2 } }) |scale| {
            const mip_linear = mip_filter == 2;
            const vertices = [_][8]f32{
                .{ -1, -1, 0, 1, 0.37 / 64.0, (16 * scale[1] + 0.37) / 64, 0, 1 },
                .{ 3, -1, 0, 1, (32 * scale[0] + 0.37) / 64, (16 * scale[1] + 0.37) / 64, 0, 1 },
                .{ -1, 3, 0, 1, 0.37 / 64.0, (-16 * scale[1] + 0.37) / 64, 0, 1 },
            };
            @memcpy(memory.data[0x1000..][0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
            const filter: u32 = if (linear) 3 else 2;
            try state.writeRegister(.shader, 0x014, 0x92 | (ratio_code << 9));
            try state.writeRegister(.shader, 0x015, (3 << 20) | @as(u32, if (mip_filter == 0) 512 else 0));
            try state.writeRegister(.shader, 0x016, ((if (mag_aniso) filter else filter & 1) << 20) | (filter << 22) | (mip_filter << 26) | @as(u32, if (mip_linear) 128 else 0));
            @memset(memory.data[0x2000..0x2400], 0xa7);
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
            const max_taps: f32 = @floatFromInt(@as(u32, 1) << @as(u5, @intCast(ratio_code)));
            const width = @max(1, @max(@min(scale[0], scale[1]), @max(scale[0], scale[1]) / max_taps));
            const taps: u32 = @intFromFloat(std.math.clamp(@ceil(@max(scale[0], scale[1]) / width), 1, max_taps));
            const lod = if (mip_filter == 0) 0 else std.math.clamp(@log2(width) + @as(f32, if (mip_linear) 0.5 else 0), 0, 3);
            const low: u32 = @intFromFloat(if (mip_linear) @floor(lod) else @floor(lod + 0.5));
            const high = @min(3, low + 1);
            const blend = if (mip_linear) lod - @floor(lod) else 0;
            for (0..16) |y| for (0..16) |x| {
                var expected: [4]f32 = @splat(0);
                for (0..taps) |tap| {
                    const offset = (@as(f32, @floatFromInt(tap)) + 0.5) / @as(f32, @floatFromInt(taps)) - 0.5;
                    const u = ((@as(f32, @floatFromInt(x)) + 0.5 + (if (scale[0] > scale[1]) offset else 0)) * scale[0] + 0.37) / 64;
                    const v = ((@as(f32, @floatFromInt(y)) + 0.5 + (if (scale[0] > scale[1]) 0 else offset)) * scale[1] + 0.37) / 64;
                    const a = anisoProbeSample(u, v, low, layer, linear);
                    const b = anisoProbeSample(u, v, high, layer, linear);
                    for (&expected, a, b) |*e, ca, cb| e.* += (ca * (1 - blend) + cb * blend) / @as(f32, @floatFromInt(taps));
                }
                for (expected, 0..) |e, channel| {
                    const actual = memory.data[0x2000 + (y * 16 + x) * 4 + channel];
                    if (@abs(@as(f32, @floatFromInt(actual)) - e) > 2) {
                        std.debug.print("Aniso mismatch array={} ratio={d} linear={} mip={} scale={any} pixel={d},{d} ch={d} got={d} expected={d}\n", .{ array, ratio_code, linear, mip_linear, scale, x, y, channel, actual, e });
                        return error.AnisotropicSamplingMismatch;
                    }
                }
            };
            cases += 1;
        };
        // Explicit LOD has no directional footprint even if the descriptor
        // enables anisotropic minification (Arkanoid's startup sampler).
        // Compare the entire output against scalar-LOD CPU filtering, with
        // different min/mag filters, fractional LOD and both 2D/array reads.
        const scalar_vertices = [_][8]f32{
            .{ -1, -1, 0, 1, 0.37 / 64.0, 16.37 / 64.0, 0, 1 },
            .{ 3, -1, 0, 1, 128.37 / 64.0, 16.37 / 64.0, 0, 1 },
            .{ -1, 3, 0, 1, 0.37 / 64.0, -15.63 / 64.0, 0, 1 },
        };
        @memcpy(memory.data[0x1000..][0..@sizeOf(@TypeOf(scalar_vertices))], std.mem.asBytes(&scalar_vertices));
        for ([_]bool{ false, true }) |level_zero| for ([_]u32{ 0, 2 }) |mip_filter| for ([_]f32{ -1, 0, 0.5, 1.5, 3 }) |requested_lod| for ([_][2]u32{ .{ 3, 1 }, .{ 2, 0 }, .{ 3, 0 }, .{ 2, 1 } }) |filters| {
            const scalar_ps = [_]u32{
                0xc8000000,                                                                                  0xc8010001,                                                             0xc8040100,      0xc8050101,
                vop1(1, 2, 255),                                                                             @bitCast(if (array) @as(f32, @floatFromInt(layer)) else requested_lod), vop1(1, 3, 255), @bitCast(requested_lod),
                @as(u32, if (level_zero) 0xf09c0f00 else 0xf0900f00) | (@as(u32, if (array) 5 else 1) << 3), 0x00400400,                                                             0xf800080f,      0x07060504,
                0xbf810000,
            };
            @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(scalar_ps))], std.mem.asBytes(&scalar_ps));
            try state.writeRegister(.shader, 0x014, 0x92 | (2 << 9));
            try state.writeRegister(.shader, 0x015, (3 << 20) | @as(u32, if (mip_filter == 0) 512 else 0));
            try state.writeRegister(.shader, 0x016, (filters[1] << 20) | (filters[0] << 22) | (2 << 24) | (mip_filter << 26));
            @memset(memory.data[0x2000..0x2400], 0xa7);
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
            const lod = std.math.clamp(if (level_zero or mip_filter == 0) @as(f32, 0) else requested_lod, 0, 3);
            const linear = (if (lod <= 0) filters[1] else filters[0]) & 1 != 0;
            const low: u32 = @intFromFloat(@floor(lod));
            const high = @min(3, low + 1);
            const blend = lod - @floor(lod);
            for (0..16) |y| for (0..16) |x| {
                const u = ((@as(f32, @floatFromInt(x)) + 0.5) * 4 + 0.37) / 64;
                const v = (@as(f32, @floatFromInt(y)) + 0.87) / 64;
                const a = anisoProbeSample(u, v, low, layer, linear);
                const b = anisoProbeSample(u, v, high, layer, linear);
                for (a, b, 0..) |ca, cb, channel| {
                    const actual = memory.data[0x2000 + (y * 16 + x) * 4 + channel];
                    if (@abs(@as(f32, @floatFromInt(actual)) - (ca * (1 - blend) + cb * blend)) > 2)
                        return error.ExplicitLodAnisotropyMismatch;
                }
            };
            cases += 1;
        };
        // Restore implicit sampling for the negative mixed-filter check below.
        @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(ps))], std.mem.asBytes(&ps));
        if (!std.mem.eql(u8, before, backing)) return error.AnisotropicSourceModified;
    }
    // Mixed point/linear anisotropy is deliberately outside this implementation.
    const before = memory.data[0x2000..0x2400].*;
    try state.writeRegister(.shader, 0x016, (2 << 20) | (3 << 22) | (1 << 26));
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    if (renderer.draw(&state, packet)) |_| return error.MixedAnisotropyAccepted else |err| if (err != error.GraphicsSamplerModeNotImplemented) return err;
    if (!std.mem.eql(u8, &before, memory.data[0x2000..0x2400])) return error.RejectedAnisotropyModifiedTarget;
    std.debug.print("PASS {d} sampler full-frame checks against CPU filtering: implicit anisotropy, explicit scalar LOD/LZ, mixed min/mag, 2D/array layers and source preservation\n", .{cases});
}

fn guestFanProbe(allocator: std.mem.Allocator) !void {
    const memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    const vs = [_]u32{
        0xe0382000, 0x80000005, // Position from s0 descriptor, indexed by v5.
        0xe0382010, 0x80000805, // Smooth RGBA from the same 32-byte record.
        0xf80000cf, 0x03020100,
        0xf8000a0f, 0x0b0a0908,
        0xbf810000,
    };
    const ps = [_]u32{
        0xc8000000, 0xc8010001, 0xc8040100, 0xc8050101,
        0xc8080200, 0xc8090201, 0xc80c0300, 0xc80d0301,
        0xf800080f, 0x03020100, 0xbf810000,
    };
    @memcpy(memory.data[0x200..][0..@sizeOf(@TypeOf(vs))], std.mem.asBytes(&vs));
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(ps))], std.mem.asBytes(&ps));
    const vertices = [_][8]f32{
        .{ 0, 0, 0, 1, 1, 1, 1, 1 },
        .{ -0.8, -0.8, 0, 1, 1, 0, 0, 1 },
        .{ 0.8, -0.8, 0, 1, 0, 1, 0, 1 },
        .{ 0.8, 0.8, 0, 1, 0, 0, 1, 1 },
        .{ -0.8, 0.8, 0, 1, 1, 1, 0, 1 },
        .{ -0.8, -0.8, 0, 1, 1, 0, 0, 1 },
    };
    @memcpy(memory.data[0x1000..][0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    @memcpy(memory.data[0x1000 + 7 * 32 ..][0..@sizeOf(@TypeOf(vertices))], std.mem.asBytes(&vertices));
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.shader, 0x04b, 4 << 1);
    for ([_]u32{ 0x1000, 32 << 16, 13, 0xfac }, 0..) |word, i| try state.writeRegister(.shader, 0x04c + @as(u32, @intCast(i)), word);
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    @memset(memory.data[0x2000..0x5000], 0xa7);
    const initial = memory.data[0x2000..0x5000].*;
    var cases: usize = 0;
    // Independent list reference: same coverage, winding, interpolation and
    // untouched pitch padding. Cull both orientations to expose winding errors.
    for ([_]u32{ 0, 1, 2, 4, 5, 6 }) |raster| {
        try state.writeRegister(.context, 0x205, raster);
        try state.writeRegister(.uconfig, 0x242, 4);
        try state.writeRegister(.uconfig, 0x24a, 0);
        try state.writeRegister(.uconfig, 0x24b, 0);
        for ([_]u16{ 0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5 }, 0..) |index, i| std.mem.writeInt(u16, memory.data[0x600 + i * 2 ..][0..2], index, .little);
        @memcpy(memory.data[0x2000..0x5000], &initial);
        _ = try executor.execute(&.{ command(gpu.pm4.index_type, 1), 0, command(gpu.pm4.draw_index_2, 5), 12, 0x600, 0, 12, 0 });
        const expected = memory.data[0x2000..0x5000].*;
        if (raster == 0 and std.mem.eql(u8, &initial, &expected)) return error.FanReferenceEmpty;
        for ([_]bool{ false, true }) |last| {
            try state.writeRegister(.context, 0x205, raster | @as(u32, if (last) 1 << 19 else 0));
            try state.writeRegister(.uconfig, 0x242, 5);
            for (0..7) |mode| {
                const width: u32 = switch (mode) {
                    0, 1 => 0,
                    2 => 1,
                    3, 5 => 2,
                    else => 4,
                };
                const base: i32 = switch (mode) {
                    1, 5 => 7,
                    2, 3 => -7,
                    4 => -70000,
                    else => 0,
                };
                const index_bias: u32 = if (base < 0) @intCast(-base) else 0;
                try state.writeRegister(.uconfig, 0x24a, @bitCast(base));
                for (0..3) |cut_mode| {
                    @memcpy(memory.data[0x2000..0x5000], &initial);
                    const marker: u32 = if (cut_mode == 1) 99 else switch (width) {
                        1 => 0xff,
                        2 => 0xffff,
                        else => 0xffffffff,
                    };
                    try state.writeRegister(.uconfig, 0x24b, if (cut_mode == 0) 0 else 1);
                    try state.writeRegister(.context, 0x103, marker);
                    if (width == 0) {
                        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 6, 2 });
                    } else {
                        const sequence = [_]u32{ marker, index_bias, marker, marker, index_bias, index_bias + 1, index_bias + 2, index_bias + 3, index_bias + 4, index_bias + 5, marker, index_bias + 1, index_bias + 2, marker };
                        const values = if (cut_mode == 0) sequence[4..10] else &sequence;
                        // Unused prefix tests DRAW_INDEX_OFFSET_2 as well.
                        @memset(memory.data[0x600..0x680], 0xee);
                        for (values, 0..) |value, i| switch (width) {
                            1 => memory.data[0x600 + (i + 2)] = @intCast(value),
                            2 => std.mem.writeInt(u16, memory.data[0x600 + (i + 2) * 2 ..][0..2], @intCast(value), .little),
                            else => std.mem.writeInt(u32, memory.data[0x600 + (i + 2) * 4 ..][0..4], value, .little),
                        };
                        const source_before = memory.data[0x600..0x680].*;
                        _ = try executor.execute(&.{ command(gpu.pm4.index_type, 1), if (width == 1) 2 else if (width == 2) 0 else 1, command(gpu.pm4.index_base, 2), 0x600, 0, command(gpu.pm4.draw_index_offset_2, 4), @intCast(values.len), 2, @intCast(values.len), 0 });
                        if (!std.mem.eql(u8, &source_before, memory.data[0x600..0x680])) return error.FanModifiedSource;
                    }
                    if (!std.mem.eql(u8, &expected, memory.data[0x2000..0x5000])) {
                        std.debug.print("Fan mismatch raster={d} last={any} mode={d} cut={d}\n", .{ raster, last, mode, cut_mode });
                        return error.FanRasterMismatch;
                    }
                    cases += 1;
                }
            }
        }
    }
    // Empty and incomplete fans do not fall through to a native nonindexed draw.
    try state.writeRegister(.uconfig, 0x24a, 0);
    for (0..3) |count| {
        @memcpy(memory.data[0x2000..0x5000], &initial);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), @intCast(count), 2 });
        if (!std.mem.eql(u8, &initial, memory.data[0x2000..0x5000])) return error.ShortFanModifiedTarget;
    }
    @memset(memory.data[0x600..0x606], 0xff);
    try state.writeRegister(.uconfig, 0x24b, 3);
    try state.writeRegister(.context, 0x103, 0xffff);
    _ = try executor.execute(&.{ command(gpu.pm4.index_type, 1), 0, command(gpu.pm4.draw_index_2, 5), 3, 0x600, 0, 3, 0 });
    if (!std.mem.eql(u8, &initial, memory.data[0x2000..0x5000])) return error.EmptyRestartFanModifiedTarget;
    // Invalid base vertices must be rejected before modifying the attachment.
    @memset(memory.data[0x600..0x606], 0);
    try state.writeRegister(.uconfig, 0x24a, @bitCast(@as(i32, -1)));
    const invalid: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_2, 5), .opcode = gpu.pm4.draw_index_2, .body = &.{ 3, 0x600, 0, 3, 0 } };
    if (renderer.draw(&state, invalid)) |_| return error.InvalidFanBaseAccepted else |err| if (err != error.InvalidBaseVertex) return err;
    if (!std.mem.eql(u8, &initial, memory.data[0x2000..0x5000])) return error.RejectedFanModifiedTarget;
    std.debug.print("PASS {d} fan GPU cases: auto/8/16/32-bit, first/base vertices, index offsets, custom/fixed restart, both provoking orders, culling, smooth varyings and full-image/padding checks\n", .{cases});
}

fn guestResourcesProbe(allocator: std.mem.Allocator, staging_limit: usize, upload_limit: usize, reference: *[5][0x3000]u8) !void {
    var memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    const vs = [_]u32{
        0xf4080200, 0xfa000000, // s_load_dwordx4 s8, [s0:s1]
        0xbf06830a, // s_cmp_eq_u32 s10, 3: true.
        0xbe980380, // s_mov_b32 s24, 0 preserves SCC (Quake II fetch shader scheduling).
        vop1(0x01, 30, 128), // Vector work between CMP/CSELECT preserves SCC.
        sop2(0x0a, 11, 11, 128), // Keep the descriptor's format word.
        0xbf06800a, // s_cmp_eq_u32 s10, 0: false.
        vop2(0x04, 31, 30, 30),
        sop2(0x0a, 11, 128, 11),
        0xe0382000, 0x80020005, // buffer_load_dwordx4 v0, v5, s8, 0 idxen
        0xf80000cf,          0x03020100, // POS0
        vop1(0x01, 4, 255),  0x3f000000,
        vop2(0x03, 6, 0, 3), vop2(0x03, 7, 1, 3),
        vop2(0x08, 6, 6, 4), vop2(0x08, 7, 7, 4),
        0xf8000a0f, 0x03020706, 0xbf810000, // PARAM0 normalized x/y
    };
    const ps = [_]u32{
        0xf4280406, 0xfa000000, // s_buffer_load_dwordx4 s16, s12, 0
        0xc8000000, 0xc8010001,
        0xc8040100, 0xc8050101,
        0xf0800f08,                               0x00400400, // sample T=s0 S=s8 -> v4
        // Repeated sampling must share its freshly validated identical native
        // view; the complete draw also shares SSBO slots across VS/PS.
        0xf0800f08,                               0x00400400,
        (0x08 << 25) | (0 << 17) | (4 << 9) | 16, (0x08 << 25) | (1 << 17) | (5 << 9) | 17,
        (0x08 << 25) | (2 << 17) | (6 << 9) | 18, (0x08 << 25) | (3 << 17) | (7 << 9) | 19,
        0xf800080f,                               0x03020100,
        0xbf810000,
    };
    @memcpy(memory.data[0x200..][0..@sizeOf(@TypeOf(vs))], std.mem.asBytes(&vs));
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(ps))], std.mem.asBytes(&ps));
    const positions = [_]f32{ -0.75, -0.75, 0, 1, 0, 0.75, 0, 1, 0.75, -0.75, 0, 1 };
    @memcpy(memory.data[0x1000..][0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions));
    const descriptor = [_]u32{ 0x1000, 16 << 16, 3, 0xfac };
    @memcpy(memory.data[0x1800..][0..16], std.mem.asBytes(&descriptor));
    var state = try graphicsState(65, 37, 72);
    try state.writeRegister(.shader, 0x04b, 4);
    try state.writeRegister(.shader, 0x04c, 0x1800);
    try state.writeRegister(.shader, 0x04d, 0);
    try state.writeRegister(.shader, 0x00b, 16 << 1);
    const user = [_]u32{
        0x100,                   (56 << 20) | (1 << 30), 1 << 14, 0x90000fac, 0,      0, 0,  0,
        2 | (2 << 3) | (2 << 6), 0xfff000,               0,       0,          0x1900, 0, 16, 0,
    };
    for (user, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
    var renderer = try d3d12.Renderer.init(allocator, memory.access(), false);
    defer renderer.deinit();
    renderer.staging_pool.limit = staging_limit;
    renderer.conversion_cache.limit = staging_limit;
    try renderer.device.uploadCacheLimit(upload_limit);
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(), .allocator = allocator };
    for (0..5) |variant| {
        const scale: [4]f32 = if (variant == 1) .{ 0.5, 0.25, 1, 1 } else .{ 1, 1, 1, 1 };
        @memcpy(memory.data[0x1900..][0..16], std.mem.asBytes(&scale));
        const top: [8]u8 = if (variant == 2) .{ 128, 64, 32, 255, 128, 64, 32, 255 } else .{ 255, 0, 0, 255, 0, 255, 0, 255 };
        const bottom: [8]u8 = if (variant == 2) top else .{ 0, 0, 255, 255, 255, 255, 255, 255 };
        @memcpy(memory.data[0x10000..][0..8], &top);
        @memcpy(memory.data[0x10100..][0..8], &bottom);
        try state.writeRegister(.shader, 0x014, user[8] | @as(u32, if (variant == 2) 1 << 20 else 0));
        try state.writeRegister(.shader, 0x016, if (variant == 4) (1 << 20) | (1 << 22) else 0);
        try state.writeRegister(.shader, 0x00f, if (variant == 3) 0x9000032e else user[3]); // B,G,R,1
        @memset(memory.data[0x2000..0x5000], 0);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        if (upload_limit == 0) reference[variant] = memory.data[0x2000..0x5000].*;
        if (!std.mem.eql(u8, &reference[variant], memory.data[0x2000..0x5000])) return error.CachedUploadImageMismatch;
        // Repeat the same inputs with a fresh attachment. This must exercise
        // reuse without letting one simultaneously bound slot overwrite another.
        @memset(memory.data[0x2000..0x5000], 0);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        if (!std.mem.eql(u8, &reference[variant], memory.data[0x2000..0x5000])) return error.WarmUploadImageMismatch;
        if (variant == 4) {
            const center = memory.data[0x2000 + (18 * 72 + 32) * 4 ..][0..4];
            for (center, [_]u8{ 128, 128, 128, 255 }) |a, e| if (@abs(@as(i16, a) - e) > 1) return error.LinearSamplerMismatch;
        } else for ([_][2]usize{ .{ 30, 23 }, .{ 34, 23 }, .{ 30, 15 }, .{ 34, 15 } }, 0..) |point, i| {
            var expected = ([_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 255, 255, 255, 255 } })[i];
            if (variant == 1) {
                expected[0] = if (expected[0] != 0) 128 else 0;
                expected[1] = if (expected[1] != 0) 64 else 0;
            }
            if (variant == 2) expected = .{ 55, 13, 4, 255 };
            if (variant == 3) std.mem.swap(u8, &expected[0], &expected[2]);
            const actual = memory.data[0x2000 + (point[1] * 72 + point[0]) * 4 ..][0..4];
            for (actual, expected) |a, e| if (@abs(@as(i16, a) - e) > 1) {
                std.debug.print("Resource variant {d} pixel {any}: {any}, expected {any}\n", .{ variant, point, actual, expected });
                return error.GraphicsResourceReadbackMismatch;
            };
        }
    }
    if (!std.mem.eql(u8, memory.data[0x1000..][0..@sizeOf(@TypeOf(positions))], std.mem.asBytes(&positions))) return error.ReadOnlyVertexDataModified;
    var repeated_samples: [ps.len + 78]u32 = undefined;
    @memcpy(repeated_samples[0..6], ps[0..6]);
    for (0..40) |i| @memcpy(repeated_samples[6 + i * 2 ..][0..2], ps[6..8]);
    @memcpy(repeated_samples[86..], ps[8..]);
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(repeated_samples))], std.mem.asBytes(&repeated_samples));
    @memset(memory.data[0x2000..0x5000], 0);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    if (!std.mem.eql(u8, &reference[4], memory.data[0x2000..0x5000])) return error.RepeatedSampleViewMismatch;
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(ps))], std.mem.asBytes(&ps));
    std.debug.print("PASS 41 sampling instructions reuse one proven native view without exhausting the 32-view limit\n", .{});
    const saved_state = state;
    const saved_memory = memory.*;
    var batch_reference: [0x3000]u8 = undefined;
    for ([_]usize{ 1, 8, d3d12.max_draw_batch }) |batch_limit| {
        state = saved_state;
        memory.* = saved_memory;
        @memset(memory.data[0x2000..0x5000], 0);
        renderer.draw_batch_limit = batch_limit;
        for (0..d3d12.max_draw_batch) |draw_index| {
            const i = draw_index % 7;
            // Reuse the same guest addresses with different data between draws.
            // Each queued snapshot must keep its own vertex/texture/uniform bytes.
            const scale = [_]f32{ @as(f32, @floatFromInt(i + 1)) / 8, 1, 0.5, 1 };
            @memcpy(memory.data[0x1900..][0..16], std.mem.asBytes(&scale));
            @memset(memory.data[0x10000..][0..8], @intCast(31 * i));
            try state.writeRegister(.context, 0x00c, @as(u32, @intCast(i * 5)));
            try state.writeRegister(.context, 0x00d, 65 | (37 << 16));
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        }
        try renderer.flushDraws();
        if (batch_limit == 1) batch_reference = memory.data[0x2000..0x5000].* else if (!std.mem.eql(u8, &batch_reference, memory.data[0x2000..0x5000])) return error.BatchResourceSnapshotMismatch;
    }
    renderer.draw_batch_limit = 1;
    memory.* = saved_memory;
    state = saved_state;
    std.debug.print("PASS queued resource snapshots: 64 draws with changing and repeated sampled/uniform inputs match sequential rendering at limits 1, 8 and 64\n", .{});
    const baseline = memory.data[0x2000..0x5000].*;
    for ([_]f32{ 32.5, 32.5, -18.5, 18.5, 1, 0 }, 0..) |value, i| try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
    @memset(memory.data[0x2000..0x5000], 0);
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    if (!std.mem.eql(u8, &baseline, memory.data[0x2000..0x5000])) return error.UnobservedDepthChangedColor;
    try state.writeRegister(.context, 0x1b3, 1 << 10);
    try state.writeRegister(.context, 0x1b4, 1 << 10);
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    if (renderer.draw(&state, packet)) |_| return error.ObservableDepthAccepted else |err| if (err != error.UnrestrictedViewportDepthNotImplemented) return err;
    try state.writeRegister(.context, 0x1b3, 0);
    try state.writeRegister(.context, 0x1b4, 0);
    try guestCompressedImageProbe(allocator, memory, &state, &executor);
    try guestPackedImageProbe(allocator, memory, &state, &executor, &renderer);
    try guestNarrowImageProbe(allocator, memory, &state, &executor, &renderer);
    try guestArrayImageProbe(allocator, memory, &state, &executor, &renderer);
    try guestTexelCoordinatesProbe(allocator, memory, &state, &executor, &renderer, &vs);
    try guestNormalizedAddressProbe(allocator, memory, &state, &executor, &vs);
    // A missing input must fail before touching the output attachment.
    const before = memory.data[0x2000..0x5000].*;
    try state.writeRegister(.shader, 0x04c, memory.data.len + 256);
    const rejected = renderer.draw(&state, .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } });
    if (rejected) |_| return error.InvalidGraphicsPointerAccepted else |_| {}
    if (!std.mem.eql(u8, &before, memory.data[0x2000..0x5000])) return error.RejectedDrawModifiedTarget;
    for (renderer.staging_pool.entries) |entry| if (entry.busy) return error.LeakedStagingLease;
    if (renderer.staging_pool.bytes > staging_limit or (staging_limit != 0 and renderer.staging_pool.hits == 0)) return error.StagingPoolNotExercised;
    if (staging_limit != 0 and renderer.conversion_cache.detile_hits == 0) return error.SampledConversionCacheNotExercised;
    const uploads = renderer.device.uploadStats();
    if (uploads.bytes > upload_limit) return error.UploadCacheBudgetExceeded;
    if (upload_limit == 0 and (uploads.buffer_hits != 0 or uploads.image_hits != 0)) return error.DisabledUploadCacheHit;
    // Cache-retained images are reused by snapshot ID before byte comparison.
    if (upload_limit > 32 and (uploads.buffer_hits == 0 or uploads.image_hits + uploads.content_hits == 0 or uploads.avoided_bytes == 0)) return error.UploadCacheNotExercised;
    if (upload_limit == 32 and uploads.bypasses == 0) return error.UploadCachePressureNotExercised;
    try renderer.device.uploadCacheLimit(0);
    if (renderer.device.uploadStats().bytes != 0) return error.UploadCacheNotReleased;
    std.debug.print("PASS upload cache budget={d}: buffer hits={d}, image hits={d}, snapshot ID hits={d}, avoided={d} bytes, evictions={d}, bypass={d}; full images match and teardown releases snapshots\n", .{
        upload_limit, uploads.buffer_hits, uploads.image_hits, uploads.content_hits, uploads.avoided_bytes, uploads.evictions, uploads.bypasses,
    });
    std.debug.print("PASS sampled conversion budget={d} KiB: detile hits={d}, tile hits={d}\n", .{ staging_limit / 1024, renderer.conversion_cache.detile_hits, renderer.conversion_cache.tile_hits });
    std.debug.print("PASS CPU staging budget={d} KiB: hits={d} misses={d}, no live leases after rejected draw\n", .{ staging_limit / 1024, renderer.staging_pool.hits, renderer.staging_pool.misses });
    std.debug.print("PASS guest vertex fetch, SMEM pointer and constant buffers, texture arrays, sampler filtering, sRGB, swizzles and failed-read isolation\n", .{});
    std.debug.print("PASS unobserved -1..1 viewport depth preserves the full color image; position-Z consumers remain rejected\n", .{});
}

fn guestCompressedImageProbe(allocator: std.mem.Allocator, memory: *GraphicsMemory, state: *gpu.State, executor: *gpu.DcbExecutor) !void {
    const scale: [4]f32 = @splat(1);
    @memcpy(memory.data[0x1900..][0..16], std.mem.asBytes(&scale));
    try state.writeRegister(.shader, 0x014, 2 | (2 << 3) | (2 << 6));
    try state.writeRegister(.shader, 0x016, 0);
    const colors = [_]u16{ 0xf800, 0x07e0, 0x001f, 0x8410 };
    const decoded = [_][3]u8{ .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 132, 130, 132 } };
    for ([_]u16{ 169, 170, 171, 172, 173, 174, 181, 182 }) |format| {
        for ([_]gpu.resources.TileMode{ .linear, .standard_4kb }) |mode| {
            // Linear rows are deliberately not aligned to D3D12's upload pitch;
            // the tiled case matches Raiden's actual 128x128 BC3 resource.
            const width: u32 = if (mode == .linear) 20 else 128;
            const height: u32 = if (mode == .linear) 12 else 128;
            const words = [_]u32{ 0x100, (@as(u32, format) << 20) | (((width - 1) & 3) << 30), ((width - 1) >> 2) | ((height - 1) << 14), 0x90000fac | (@as(u32, @intFromEnum(mode)) << 20), 0, 0, 0, 0 };
            for (words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
            const descriptor = try gpu.resources.decodeImageDescriptor(&words);
            const layout = try gpu.SurfaceLayout.fromImage(descriptor);
            const blocks = try allocator.alloc(u8, @intCast(layout.staging_bytes));
            defer allocator.free(blocks);
            @memset(blocks, 0);
            const bytes: usize = if (format <= 170) 8 else 16;
            for (0..height / 4) |y| for (0..width / 4) |x| {
                const block = blocks[(y * (width / 4) + x) * bytes ..][0..bytes];
                const color_index = (y % 2) * 2 + x % 2;
                if (format >= 181) {
                    // BC7 mode 6: equal RGBA endpoints, zero p-bits and indices.
                    // Even channels make the independent expected color exact.
                    const rgba = [_][4]u8{ .{ 252, 0, 0, 128 }, .{ 0, 252, 0, 128 }, .{ 0, 0, 252, 128 }, .{ 132, 130, 132, 128 } };
                    var bits: u128 = 1 << 6;
                    for (rgba[color_index], 0..) |channel, c| for (0..2) |endpoint| {
                        bits |= @as(u128, channel >> 1) << @intCast(7 + c * 14 + endpoint * 7);
                    };
                    std.mem.writeInt(u128, block[0..16], bits, .little);
                } else {
                    if (format == 171 or format == 172) @memset(block[0..8], 0x88);
                    if (format >= 173) block[0] = 128; // Alpha endpoint 0, selector 0.
                    std.mem.writeInt(u16, block[bytes - 8 ..][0..2], colors[color_index], .little);
                }
            };
            const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
            @memset(backing, 0xa7);
            try layout.tile(blocks, backing);
            const before = try allocator.dupe(u8, backing);
            defer allocator.free(before);
            @memset(memory.data[0x2000..0x5000], 0);
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
            if (!std.mem.eql(u8, before, backing)) return error.CompressedSourceModified;
            for ([_][2]usize{ .{ 30, 23 }, .{ 34, 23 }, .{ 30, 15 }, .{ 34, 15 } }) |point| {
                const tx: usize = @intFromFloat((@as(f32, @floatFromInt(point[0])) + 0.5) / 65 * @as(f32, @floatFromInt(width)));
                const ty: usize = @intFromFloat((1 - (@as(f32, @floatFromInt(point[1])) + 0.5) / 37) * @as(f32, @floatFromInt(height)));
                const rgb = decoded[((ty / 4) % 2) * 2 + (tx / 4) % 2];
                var expected: [4]u8 = .{ rgb[0], rgb[1], rgb[2], if (format <= 170) 255 else if (format <= 172) 136 else 128 };
                if (format >= 181) for (expected[0..3]) |*v| {
                    if (v.* == 255) v.* = 252;
                };
                if (format % 2 == 0) for (expected[0..3]) |*v| {
                    const c = @as(f32, @floatFromInt(v.*)) / 255;
                    const linear = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
                    v.* = @intFromFloat(@round(linear * 255));
                };
                const actual = memory.data[0x2000 + (point[1] * 72 + point[0]) * 4 ..][0..4];
                for (actual, expected) |a, e| if (@abs(@as(i16, a) - e) > 1) {
                    std.debug.print("BC format={d} tile={f} pixel={any} actual={any} expected={any}\n", .{ format, mode, point, actual, expected });
                    return error.CompressedTextureMismatch;
                };
            }
        }
    }
    std.debug.print("PASS 16 guest BC1/BC2/BC3/BC7 texture cases: tiled/linear blocks, native row pitch, alpha and sRGB decoding, source preservation\n", .{});
}

fn guestPackedImageProbe(allocator: std.mem.Allocator, memory: *GraphicsMemory, state: *gpu.State, executor: *gpu.DcbExecutor, renderer: *d3d12.Renderer) !void {
    // Compare packed GPU sampling against independently expanded RGBA8 for
    // every target byte. Include the exact 256x128 tiled Raiden descriptor
    // shape as well as odd rows that require padded D3D12 upload footprints.
    const mappings = [_][4]u8{ .{ 4, 5, 6, 7 }, .{ 6, 5, 4, 7 }, .{ 7, 4, 5, 6 }, .{ 1, 6, 0, 7 } };
    for ([_][2]u32{ .{ 13, 9 }, .{ 256, 128 } }) |extent| for ([_]gpu.resources.TileMode{ .linear, .standard_4kb }) |mode| for (mappings) |selectors| for ([_]u32{ 0, 1 }) |filter| {
        const width = extent[0];
        const height = extent[1];
        var components: u32 = 0;
        for (selectors, 0..) |select, i| components |= @as(u32, select) << @intCast(i * 3);
        var packed_target: [0x3000]u8 = undefined;
        for ([_]u16{ 136, 56 }) |format| {
            const words = [_]u32{ 0x100, (@as(u32, format) << 20) | (((width - 1) & 3) << 30), ((width - 1) >> 2) | ((height - 1) << 14), (9 << 28) | (if (format == 136) components else 0xfac) | (@as(u32, @intFromEnum(mode)) << 20), 0, 0, 0, 0 };
            for (words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
            try state.writeRegister(.shader, 0x014, 2 | (2 << 3) | (2 << 6));
            try state.writeRegister(.shader, 0x016, (filter << 20) | (filter << 22));
            const descriptor = try gpu.resources.decodeImageDescriptor(&words);
            const layout = try gpu.SurfaceLayout.fromImage(descriptor);
            const pixels = try allocator.alloc(u8, @intCast(layout.staging_bytes));
            defer allocator.free(pixels);
            for (0..height) |y| for (0..width) |x| {
                const nibbles = [_]u8{ @intCast(x % 16), @intCast((y + 3) % 16), @intCast((x + y + 7) % 16), @intCast((x * 3 + y * 5 + 1) % 16) };
                if (format == 136) {
                    const packed_value = @as(u16, nibbles[0]) | (@as(u16, nibbles[1]) << 4) | (@as(u16, nibbles[2]) << 8) | (@as(u16, nibbles[3]) << 12);
                    std.mem.writeInt(u16, pixels[(y * width + x) * 2 ..][0..2], packed_value, .little);
                } else {
                    for (selectors, 0..) |select, i| pixels[(y * width + x) * 4 + i] = switch (select) {
                        0 => 0,
                        1 => 255,
                        else => nibbles[select - 4] * 17,
                    };
                }
            };
            const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
            @memset(backing, 0xa7);
            try layout.tile(pixels, backing);
            const before = try allocator.dupe(u8, backing);
            defer allocator.free(before);
            @memset(memory.data[0x2000..0x5000], 0);
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
            if (!std.mem.eql(u8, before, backing)) return error.PackedImageSourceModified;
            if (format == 136) packed_target = memory.data[0x2000..0x5000].* else {
                for (memory.data[0x2000..0x5000], packed_target, 0..) |expected, actual, i| if (@abs(@as(i16, actual) - expected) > 1) {
                    std.debug.print("Packed image extent={any} tile={f} selectors={any} filter={d} byte={d}: {d} expected {d}\n", .{ extent, mode, selectors, filter, i, actual, expected });
                    return error.PackedImageSamplingMismatch;
                };
            }
        }
    };
    const before = memory.data[0x2000..0x5000].*;
    const word1 = state.readRegister(.shader, 0x00d).?;
    try state.writeRegister(.shader, 0x00d, (word1 & ~@as(u32, 0x1ff << 20)) | (136 << 20));
    try state.writeRegister(.shader, 0x014, 2 | (2 << 3) | (2 << 6) | (1 << 20));
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    if (renderer.draw(state, packet)) |_| return error.PackedSrgbAccepted else |err| if (err != error.GraphicsSamplerModeNotImplemented) return err;
    if (!std.mem.eql(u8, &before, memory.data[0x2000..0x5000])) return error.RejectedPackedImageModifiedTarget;
    try state.writeRegister(.shader, 0x014, 2 | (2 << 3) | (2 << 6));
    try state.writeRegister(.shader, 0x016, 0);
    std.debug.print("PASS RGBA4444: 32 packed/RGBA8 GPU comparisons, linear/tiled odd rows and Raiden extent, component selectors/constants, alpha, point/linear filtering, source preservation and sRGB rejection\n", .{});
}

fn guestNarrowImageProbe(allocator: std.mem.Allocator, memory: *GraphicsMemory, state: *gpu.State, executor: *gpu.DcbExecutor, renderer: *d3d12.Renderer) !void {
    const saved_batch_limit = renderer.draw_batch_limit;
    renderer.draw_batch_limit = 64;
    defer renderer.draw_batch_limit = saved_batch_limit;
    // Leave the RG8 fixture for the following texel-coordinate probe.
    for ([_]u16{ 1, 1, 7, 14 }, 0..) |format, view_index| for ([_]gpu.resources.TileMode{ .linear, .standard_4kb }) |mode| for ([_]u32{ 9, 13 }) |image_type| {
        const width: u32 = 13;
        const height: u32 = 9;
        const alpha_only = view_index == 0;
        const components: u32 = if (alpha_only) 4 << 9 else if (format != 14) 4 | (0 << 3) | (0 << 6) | (1 << 9) else 4 | (5 << 3) | (0 << 6) | (1 << 9);
        const words = [_]u32{ 0x100, (@as(u32, format) << 20) | (((width - 1) & 3) << 30), ((width - 1) >> 2) | ((height - 1) << 14), (image_type << 28) | components | (@as(u32, @intFromEnum(mode)) << 20), 0, 0, 0, 0 };
        for (words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
        const descriptor = try gpu.resources.decodeImageDescriptor(&words);
        if (descriptor.depth_or_layers != 1) return error.InvalidNarrowImageProbe;
        const layout = try gpu.SurfaceLayout.fromImage(descriptor);
        const pixels = try allocator.alloc(u8, @intCast(layout.staging_bytes));
        defer allocator.free(pixels);
        const bytes: usize = if (format == 1) 1 else 2;
        for (0..height) |y| for (0..width) |x| {
            pixels[(y * width + x) * bytes] = @intCast(20 + x * 11);
            if (bytes == 2) pixels[(y * width + x) * bytes + 1] = @intCast(40 + y * 19);
        };
        const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
        const upload = memory.data[0x60000..][0..backing.len];
        @memset(upload, 0xa7);
        try layout.tile(pixels, upload);
        // Exercise the real DMA callback, not a host memcpy to the atlas.
        // A missing callback left Unity's R8 coverage at its allocation fill.
        _ = try executor.execute(&.{
            command(gpu.pm4.dma_data, 6), (2 << 29) | (3 << 20), 0xcdcdcdcd, 0, 0x10000, 0, @intCast(backing.len),
            command(gpu.pm4.dma_data, 6), 3 << 29,               0x60000,    0, 0x10000, 0, @intCast(backing.len),
        });
        if (!std.mem.eql(u8, upload, backing)) return error.NarrowImageDmaUploadMismatch;
        const before = try allocator.dupe(u8, backing);
        defer allocator.free(before);
        @memset(memory.data[0x2000..0x5000], 0);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        // The draw remains queued. DMA must complete it before copying its
        // pixels, and the next upload must invalidate the earlier atlas view.
        _ = try executor.execute(&.{ command(gpu.pm4.dma_data, 6), 3 << 20, 0x2000, 0, 0x70000, 0, 0x3000 });
        if (!std.mem.eql(u8, memory.data[0x2000..0x5000], memory.data[0x70000..0x73000])) return error.NarrowImageDmaOrderingMismatch;
        if (!std.mem.eql(u8, before, backing)) return error.NarrowImageSourceModified;
        for ([_][2]usize{ .{ 30, 23 }, .{ 34, 23 }, .{ 30, 15 }, .{ 34, 15 } }) |point| {
            const tx: usize = @intFromFloat((@as(f32, @floatFromInt(point[0])) + 0.5) / 65 * @as(f32, @floatFromInt(width)));
            const ty: usize = @intFromFloat((1 - (@as(f32, @floatFromInt(point[1])) + 0.5) / 37) * @as(f32, @floatFromInt(height)));
            const red: u8 = if (format == 7) @intCast(((20 + tx * 11 + (40 + ty * 19) * 256) * 255 + 32767) / 65535) else @intCast(20 + tx * 11);
            const expected: [4]u8 = if (alpha_only) .{ 0, 0, 0, red } else .{ red, if (format == 14) @intCast(40 + ty * 19) else 0, 0, 255 };
            const actual = memory.data[0x2000 + (point[1] * 72 + point[0]) * 4 ..][0..4];
            for (actual, expected) |a, e| if (@abs(@as(i16, a) - e) > 1) return error.NarrowImageSamplingMismatch;
        }
    };
    const before = memory.data[0x2000..0x5000].*;
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    try state.writeRegister(.shader, 0x010, 1); // Two layers cannot become a 2D view.
    if (renderer.draw(state, packet)) |_| return error.MultiLayerViewAccepted else |err| if (err != error.GraphicsTextureFormatOrMipNotImplemented) return err;
    try state.writeRegister(.shader, 0x010, 0);
    try state.writeRegister(.shader, 0x014, 2 | (2 << 3) | (2 << 6) | (1 << 20));
    if (renderer.draw(state, packet)) |_| return error.NarrowSrgbAccepted else |err| if (err != error.GraphicsSamplerModeNotImplemented) return err;
    try state.writeRegister(.shader, 0x014, 2 | (2 << 3) | (2 << 6));
    if (!std.mem.eql(u8, &before, memory.data[0x2000..0x5000])) return error.RejectedViewModifiedTarget;
    std.debug.print("PASS R8/R16/RG8 textures: DMA fill/upload, linear/tiled, narrow rows, one-layer arrays, alpha-only font coverage and unchanged source bytes (16 cases); multi-layer/sRGB rejection\n", .{});
}

fn guestArrayImageProbe(allocator: std.mem.Allocator, memory: *GraphicsMemory, state: *gpu.State, executor: *gpu.DcbExecutor, renderer: *d3d12.Renderer) !void {
    const saved_memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(saved_memory);
    saved_memory.* = memory.*;
    const saved_state = state.*;
    defer {
        memory.* = saved_memory.*;
        state.* = saved_state;
    }
    try state.writeRegister(.shader, 0x00b, 28 << 1);
    try state.writeRegister(.shader, 0x014, 2 | (2 << 3) | (2 << 6));
    try state.writeRegister(.shader, 0x016, 0);
    // The same pixel shader samples a 2D image and an array/cube. Their
    // distinct HLSL register ranges must not overwrite or alias image types.
    const second = [_]u32{ 0x700, 56 << 20, 0, 0x90000fac, 0, 0, 0, 0 };
    for (second, 0..) |word, i| try state.writeRegister(.shader, 0x020 + @as(u32, @intCast(i)), word);
    @memcpy(memory.data[0x70000..][0..4], &[_]u8{ 128, 255, 64, 255 });
    var cases: usize = 0;
    for ([_]u32{ 1, 2 }) |dimension| for ([_]u16{ 56, 169 }) |format| for ([_]gpu.resources.TileMode{ .linear, .standard_4kb }) |mode| {
        const layers: u32 = if (dimension == 1) 12 else 3;
        const first: u32 = if (dimension == 1) 6 else 2;
        const image_type: u32 = if (dimension == 1) 11 else 13;
        const words = [_]u32{ 0x100, (@as(u32, format) << 20) | (3 << 30), 1 | (7 << 14), (image_type << 28) | 0xfac | (@as(u32, @intFromEnum(mode)) << 20), (first + layers - 1) | (first << 16), 0, 0, 0 };
        const layout = try gpu.SurfaceLayout.fromImage(try gpu.resources.decodeImageDescriptor(&words));
        const pixels = try allocator.alloc(u8, @intCast(layout.staging_bytes));
        defer allocator.free(pixels);
        const plane = pixels.len / layers;
        for (0..layers) |layer| {
            if (format == 56) {
                for (0..8) |y| for (0..8) |x| {
                    @memcpy(pixels[layer * plane + (y * 8 + x) * 4 ..][0..4], &[_]u8{ @intCast(15 + layer * 17), @intCast(20 + x * 29), @intCast(30 + y * 27), 255 });
                };
            } else {
                for (0..4) |block| {
                    const color: u16 = @as(u16, @intCast(layer + 2)) << 11 | @as(u16, @intCast(9 + block * 9)) << 5 | @as(u16, @intCast(5 + layer));
                    const at = pixels[layer * plane + block * 8 ..][0..8];
                    std.mem.writeInt(u16, at[0..2], color, .little);
                    std.mem.writeInt(u16, at[2..4], 0, .little);
                    @memset(at[4..], 0);
                }
            }
        }
        const backing = memory.data[0x10000..][0..@intCast(layout.required_source_bytes)];
        @memset(backing, 0xad);
        try layout.tile(pixels, backing);
        const before = try allocator.dupe(u8, backing);
        defer allocator.free(before);
        for (0..layers) |layer| {
            var actual: [0x3000]u8 = undefined;
            // Compare every byte against independently staged 2D sampling of
            // the selected face, including gradients, padding and alpha.
            for (0..2) |reference| {
                var ps: std.ArrayList(u32) = .empty;
                defer ps.deinit(allocator);
                // Avoid exact point-sampling boundaries: the cube projection
                // can legally choose either neighbor at an exact texel edge.
                try ps.appendSlice(allocator, &.{ 0xc8000000, 0xc8010001, 0xc8040100, 0xc8050101, vop1(0x01, 3, 255), @bitCast(@as(f32, 0.015625)), vop2(0x03, 0, 0, 3), vop2(0x03, 1, 1, 3), 0xf0800f08, 0x00450800 }); // T=s20 S=s8 -> v8..11 (ordinary 2D)
                if (reference == 0) {
                    for (words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
                    if (dimension == 1) try ps.appendSlice(allocator, &.{ vop1(0x01, 3, 242), vop2(0x03, 0, 0, 3), vop2(0x03, 1, 1, 3) });
                    const index: f32 = @floatFromInt(if (dimension == 1) (layer / 6) * 8 + layer % 6 else layer);
                    try ps.appendSlice(allocator, &.{ vop1(0x01, 2, 255), @bitCast(index), 0xf0800f00 | (if (dimension == 1) @as(u32, 3 << 3) else @as(u32, 5 << 3)), 0x00400400 });
                } else {
                    const reference_words = [_]u32{ 0x600, words[1], words[2], 0x90000fac, 0, 0, 0, 0 };
                    const reference_layout = try gpu.SurfaceLayout.fromImage(try gpu.resources.decodeImageDescriptor(&reference_words));
                    const reference_backing = memory.data[0x60000..][0..@intCast(reference_layout.required_source_bytes)];
                    try reference_layout.tile(pixels[layer * plane ..][0..plane], reference_backing);
                    for (reference_words, 0..) |word, i| try state.writeRegister(.shader, 0x00c + @as(u32, @intCast(i)), word);
                    try ps.appendSlice(allocator, &.{ 0xf0800f08, 0x00400400 });
                }
                try ps.appendSlice(allocator, &.{ vop2(0x08, 0, 4, 8), vop2(0x08, 1, 5, 9), vop2(0x08, 2, 6, 10), vop2(0x08, 3, 7, 11), 0xf800080f, 0x03020100, 0xbf810000 });
                @memcpy(memory.data[0x400..][0 .. ps.items.len * 4], std.mem.sliceAsBytes(ps.items));
                @memset(memory.data[0x2000..0x5000], 0);
                _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
                if (reference == 0) actual = memory.data[0x2000..0x5000].* else {
                    for (actual, memory.data[0x2000..0x5000], 0..) |a, e, i| if (@abs(@as(i16, a) - e) > 1) {
                        std.debug.print("Array image mismatch dimension={d} format={d} tile={f} layer={d} byte={d}: {d} expected {d}\n", .{ dimension, format, mode, layer, i, a, e });
                        return error.ArrayImageSamplingMismatch;
                    };
                }
            }
            cases += 1;
        }
        if (!std.mem.eql(u8, before, backing)) return error.ArrayImageSourceModified;
    };
    // Invalid cube shape must fail before publishing any output.
    try state.writeRegister(.shader, 0x00f, 0xb0000fac);
    try state.writeRegister(.shader, 0x010, 6); // Seven faces.
    const invalid_ps = [_]u32{ vop1(0x01, 0, 242), vop1(0x01, 1, 242), vop1(0x01, 2, 128), 0xf0800f18, 0x00400400, 0xf800080f, 0x07060504, 0xbf810000 };
    @memcpy(memory.data[0x400..][0..@sizeOf(@TypeOf(invalid_ps))], std.mem.asBytes(&invalid_ps));
    const before_target = memory.data[0x2000..0x5000].*;
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    if (renderer.draw(state, packet)) |_| return error.InvalidCubeAccepted else |err| if (err != error.GraphicsTextureFormatOrMipNotImplemented) return err;
    if (!std.mem.eql(u8, &before_target, memory.data[0x2000..0x5000])) return error.RejectedCubeModifiedTarget;
    std.debug.print("PASS {d} array/cube full-frame comparisons: all faces of two cubes, base slices, RGBA8/BC1, linear/tiled uploads, mixed 2D/cube banks and invalid shape isolation\n", .{cases});
}

fn guestNormalizedAddressProbe(allocator: std.mem.Allocator, memory: *GraphicsMemory, state: *gpu.State, executor: *gpu.DcbExecutor, vertex: []const u32) !void {
    // RG8 gradient from guestNarrowImageProbe; calculate point/bilinear taps
    // independently, including border contributions and negative coordinates.
    const saved_state = state.*;
    defer state.* = saved_state;
    const source = memory.data[0x10000..0x11000].*;
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(allocator);
    var cases: usize = 0;
    for ([_]u32{ 3, 6 }) |mode| for ([_]u32{ 0, 1 }) |filter| for ([_]u32{ 0, 1, 2 }) |border| {
        for ([_][2]f32{ .{ -1.4, -0.25 }, .{ -0.5, 0.5 }, .{ 0.125, 0.25 }, .{ 1, 1 }, .{ 2.25, -3 } }) |uv| {
            words.clearRetainingCapacity();
            try words.appendSlice(allocator, vertex[0 .. vertex.len - 3]);
            try words.appendSlice(allocator, &.{ vop1(0x01, 6, 255), @bitCast(uv[0]), vop1(0x01, 7, 255), @bitCast(uv[1]) });
            try words.appendSlice(allocator, vertex[vertex.len - 3 ..]);
            @memcpy(memory.data[0x200..][0 .. words.items.len * 4], std.mem.sliceAsBytes(words.items));
            try state.writeRegister(.shader, 0x014, mode | (mode << 3) | (mode << 6));
            try state.writeRegister(.shader, 0x016, (filter << 20) | (filter << 22));
            try state.writeRegister(.shader, 0x017, border << 30);
            @memset(memory.data[0x2000..0x5000], 0);
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
            const x = (if (mode == 3) @abs(uv[0]) else uv[0]) * 13 - (if (filter == 1) @as(f32, 0.5) else 0);
            const y = (if (mode == 3) @abs(uv[1]) else uv[1]) * 9 - (if (filter == 1) @as(f32, 0.5) else 0);
            const ix: i32 = @intFromFloat(@floor(x));
            const iy: i32 = @intFromFloat(@floor(y));
            const fx = x - @floor(x);
            const fy = y - @floor(y);
            var expected: [4]f32 = .{ 0, 0, 0, 255 };
            const count: usize = if (filter == 1) 2 else 1;
            for (0..count) |dy| for (0..count) |dx| {
                const tx = ix + @as(i32, @intCast(dx));
                const ty = iy + @as(i32, @intCast(dy));
                const outside = mode == 6 and (tx < 0 or tx >= 13 or ty < 0 or ty >= 9);
                const weight: f32 = if (filter == 0) 1 else (if (dx == 0) 1 - fx else fx) * (if (dy == 0) 1 - fy else fy);
                const r: f32 = if (outside) (if (border == 2) @as(f32, 255) else 0) else @floatFromInt(20 + std.math.clamp(tx, 0, 12) * 11);
                const g: f32 = if (outside) (if (border == 2) @as(f32, 255) else 0) else @floatFromInt(40 + std.math.clamp(ty, 0, 8) * 19);
                expected[0] += r * weight;
                expected[1] += g * weight;
            };
            for ([_][2]usize{ .{ 30, 23 }, .{ 34, 23 }, .{ 30, 15 }, .{ 34, 15 } }) |point| {
                const actual = memory.data[0x2000 + (point[1] * 72 + point[0]) * 4 ..][0..4];
                for (actual, expected) |a, e| if (@abs(@as(f32, @floatFromInt(a)) - e) > 1.1) {
                    std.debug.print("Normalized address mismatch mode={d} filter={d} border={d} uv={any}: {any} expected {any}\n", .{ mode, filter, border, uv, actual, expected });
                    return error.NormalizedAddressMismatch;
                };
            }
            cases += 1;
        }
    };
    if (!std.mem.eql(u8, &source, memory.data[0x10000..0x11000])) return error.AddressProbeModifiedSource;
    std.debug.print("PASS {d} normalized mirror-once/border draws: CPU point/bilinear references, all fixed border colors, negative and out-of-range coordinates\n", .{cases});
}

fn guestTexelCoordinatesProbe(allocator: std.mem.Allocator, memory: *GraphicsMemory, state: *gpu.State, executor: *gpu.DcbExecutor, renderer: *d3d12.Renderer, vertex: []const u32) !void {
    // Reuse the 13x9 tiled RG8 image, but supply pixel coordinates from the
    // vertex stage. Compare the entire target against normalized sampling,
    // then verify an exact texel center, edge clamp and explicit border.
    var pixel_vertex: std.ArrayList(u32) = .empty;
    defer pixel_vertex.deinit(allocator);
    try pixel_vertex.appendSlice(allocator, vertex[0 .. vertex.len - 3]);
    try pixel_vertex.appendSlice(allocator, &.{
        vop1(0x01, 4, 255), @bitCast(@as(f32, 13)), vop2(0x08, 6, 6, 4),
        vop1(0x01, 4, 255), @bitCast(@as(f32, 9)),  vop2(0x08, 7, 7, 4),
    });
    try pixel_vertex.appendSlice(allocator, vertex[vertex.len - 3 ..]);
    var reference: [0x3000]u8 = undefined;
    for ([_]u32{ 0, 1 }) |filter| {
        try state.writeRegister(.shader, 0x016, (filter << 20) | (filter << 22) | (1 << 24));
        for ([_]u32{ 0, 1, 2 }) |variant| {
            const words = if (variant == 0) vertex else pixel_vertex.items;
            @memcpy(memory.data[0x200..][0 .. words.len * 4], std.mem.sliceAsBytes(words));
            try state.writeRegister(.shader, 0x014, if (variant == 0) 0x92 else if (variant == 1) 0x8000 else 0x8092);
            @memset(memory.data[0x2000..0x5000], 0);
            _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
            if (variant == 0) reference = memory.data[0x2000..0x5000].* else {
                for (memory.data[0x2000..0x5000], reference) |a, e| if (@abs(@as(i16, a) - e) > 1) return error.TexelCoordinateImageMismatch;
            }
        }
    }
    for ([_][2]f32{ .{ 6.5, 4.5 }, .{ -2, -3 }, .{ 18, 12 } }, 0..) |uv, point| for ([_]u32{ 0, 2, 6 }) |clamp| {
        pixel_vertex.clearRetainingCapacity();
        try pixel_vertex.appendSlice(allocator, vertex[0 .. vertex.len - 3]);
        try pixel_vertex.appendSlice(allocator, &.{ vop1(0x01, 6, 255), @bitCast(uv[0]), vop1(0x01, 7, 255), @bitCast(uv[1]) });
        try pixel_vertex.appendSlice(allocator, vertex[vertex.len - 3 ..]);
        @memcpy(memory.data[0x200..][0 .. pixel_vertex.items.len * 4], std.mem.sliceAsBytes(pixel_vertex.items));
        try state.writeRegister(.shader, 0x014, 0x8000 | clamp | (clamp << 3));
        @memset(memory.data[0x2000..0x5000], 0);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        // This view maps B/A to constants 0/1, including border samples.
        const expected: [4]u8 = if (clamp == 6 and point != 0) .{ 0, 0, 0, 255 } else switch (point) {
            0 => .{ 86, 116, 0, 255 },
            1 => .{ 20, 40, 0, 255 },
            else => .{ 152, 192, 0, 255 },
        };
        const actual = memory.data[0x2000 + (18 * 72 + 32) * 4 ..][0..4];
        for (actual, expected) |a, e| if (@abs(@as(i16, a) - e) > 1) {
            std.debug.print("Texel coordinate point={d} clamp={d} actual={any} expected={any}\n", .{ point, clamp, actual, expected });
            return error.TexelCoordinateClampMismatch;
        };
    };
    const before = memory.data[0x2000..0x5000].*;
    try state.writeRegister(.shader, 0x016, 0x05500000); // Unsupported unnormalized mip filter.
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    if (renderer.draw(state, packet)) |_| return error.UnnormalizedMipAccepted else |err| if (err != error.GraphicsSamplerModeNotImplemented) return err;
    if (!std.mem.eql(u8, &before, memory.data[0x2000..0x5000])) return error.RejectedSamplerModifiedTarget;
    try state.writeRegister(.shader, 0x016, 0x01500000);
    std.debug.print("PASS pixel-coordinate sampling: point/linear full-image equivalence, texel centers, out-of-range edge/border clamps and unsupported mip rejection\n", .{});
}
