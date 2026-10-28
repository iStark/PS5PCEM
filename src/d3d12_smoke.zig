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
    memory.data = before;
    std.debug.print("PASS queued PM4 draws: target feedback, wait/live reads, guest writes, release labels and submission drain publish completed pixels; unrelated reads preserve the group\n", .{});
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
    try guestSurfaceProbe(allocator, &vertex_words, &pixel_words);
    for ([_]usize{ 0, d3d12.surface_cache.Cache.default_limit }) |limit| try guestDepthProbe(allocator, &vertex_words, &pixel_words, limit);
    try guestViewportDepthProbe(allocator, &vertex_words, &pixel_words);
    try guestVaryingProbe(allocator, &vertex_words);
    try guestFanProbe(allocator);
    try guestRectangleProbe(allocator);
    try guestStencilProbe(device, vertex.words, fragment.words);
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
    // Quake II uses a vertex-only compress-disable rectangle with all tests
    // disabled. It still has to materialize the metadata into BOTH planes.
    const utility_vs = [_]u32{ vop1(1, 0, 128), vop1(1, 1, 255), 0x3f800000, 0xf80008cf, 0x01000000, 0xbf810000 };
    @memcpy(memory.data[0x200..][0..@sizeOf(@TypeOf(utility_vs))], std.mem.asBytes(&utility_vs));
    try state.writeRegister(.shader, 0x008, 0);
    try state.writeRegister(.context, 0x318, 0);
    try state.writeRegister(.context, 0x000, 0x60);
    try state.writeRegister(.context, 0x200, 0);
    offset = 0;
    while (offset < keys.len) : (offset += 4) std.mem.writeInt(u32, keys[offset..][0..4], 0xf0, .little);
    const previous_color = memory.data[0x2000..0x5000].*;
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    if (renderer.metadata_expands != 1 or !std.mem.eql(u8, &previous_color, memory.data[0x2000..0x5000])) return error.DepthUtilityNotExecuted;
    try depth.layout.detile(memory.data[0x20000..][0..depth.backing.len], depth.pixels);
    try stencil.layout.detile(memory.data[0x30000..][0..stencil.backing.len], stencil.pixels);
    for (depth.pixels) |byte| if (byte != 0) return error.DepthUtilityDidNotExpandDepth;
    for (stencil.pixels) |byte| if (byte != 0) return error.DepthUtilityDidNotExpandStencil;
    if (try htile.word(keys, 0, 0, 0) != gpu.HtileLayout.expanded_depth_stencil) return error.DepthUtilityDidNotExpandMetadata;
    // A system interrupt must never be classified as harmless vertex work.
    std.mem.writeInt(u32, memory.data[0x200..][0..4], 0xbf900001, .little);
    const packet: gpu.pm4.Packet = .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } };
    if (renderer.draw(&state, packet)) |_| return error.VertexSystemMessageIgnored else |err| if (err != error.MissingColorTarget) return err;
    std.debug.print("PASS PM4 stencil clear/increment, HTILE persistence, PS-less compression-disable materialization of both planes, system-message rejection\n", .{});
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
    std.debug.print("PASS RECT_LIST: legacy completion matches two explicit triangles, NGG 1/3/4 counts invoke the fourth guest vertex, full interpolation/coverage/padding comparisons\n", .{});
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
    if (renderer.draw(&state, packet)) |_| return error.MissingStencilAccepted else |err| if (err != error.UnsupportedStencilLayout) return err;
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
    var logical = try d3d12.surfaces.Staged.readColor(allocator, null, null, memory.access(), bgra_target.address, bgra_layout, null, true);
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
    try guestTexelCoordinatesProbe(allocator, memory, &state, &executor, &renderer, &vs);
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
    for ([_]u16{ 169, 170, 171, 172, 173, 174 }) |format| {
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
                const color = colors[(y % 2) * 2 + x % 2];
                if (format == 171 or format == 172) @memset(block[0..8], 0x88);
                if (format >= 173) block[0] = 128; // Alpha endpoint 0, selector 0.
                std.mem.writeInt(u16, block[bytes - 8 ..][0..2], color, .little);
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
    std.debug.print("PASS 12 guest BC1/BC2/BC3 texture cases: tiled/linear blocks, native row pitch, alpha and sRGB decoding, source preservation\n", .{});
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
    for ([_]u16{ 1, 14 }) |format| for ([_]gpu.resources.TileMode{ .linear, .standard_4kb }) |mode| for ([_]u32{ 9, 13 }) |image_type| {
        const width: u32 = 13;
        const height: u32 = 9;
        const components: u32 = if (format == 1) 4 | (0 << 3) | (0 << 6) | (1 << 9) else 4 | (5 << 3) | (0 << 6) | (1 << 9);
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
        @memset(backing, 0xa7);
        try layout.tile(pixels, backing);
        const before = try allocator.dupe(u8, backing);
        defer allocator.free(before);
        @memset(memory.data[0x2000..0x5000], 0);
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
        if (!std.mem.eql(u8, before, backing)) return error.NarrowImageSourceModified;
        for ([_][2]usize{ .{ 30, 23 }, .{ 34, 23 }, .{ 30, 15 }, .{ 34, 15 } }) |point| {
            const tx: usize = @intFromFloat((@as(f32, @floatFromInt(point[0])) + 0.5) / 65 * @as(f32, @floatFromInt(width)));
            const ty: usize = @intFromFloat((1 - (@as(f32, @floatFromInt(point[1])) + 0.5) / 37) * @as(f32, @floatFromInt(height)));
            const expected = [4]u8{ @intCast(20 + tx * 11), if (bytes == 2) @intCast(40 + ty * 19) else 0, 0, 255 };
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
    std.debug.print("PASS R8/RG8 textures: linear/tiled, narrow upload rows, one-layer array views, components and unchanged source bytes (8 cases); multi-layer/sRGB rejection\n", .{});
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
