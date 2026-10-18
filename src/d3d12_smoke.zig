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
    }, .{ 1, 1, 1 });
    if (!std.mem.eql(u32, &source_words, &copied_words)) return error.GuestComputeMismatch;
    const compute_cache = device.cacheStats();
    for (&source_words) |*word| word.* ^= 0xabcdef12;
    @memset(&copied_words, 0xcc);
    try device.dispatchSpirv(translated.words, &.{
        d3d12.Buffer.fromSlice(std.mem.asBytes(&source_words)),
        d3d12.Buffer.fromSlice(std.mem.asBytes(&copied_words)),
    }, .{ 1, 1, 1 });
    if (!std.mem.eql(u32, &source_words, &copied_words)) return error.CachedComputeReadbackMismatch;
    if (compute_cache.enabled != 0 and (device.cacheStats().shader_hits != compute_cache.shader_hits + 1 or
        device.cacheStats().pipeline_hits != compute_cache.pipeline_hits + 1)) return error.ComputeCacheMiss;
    const preserved = source_words;
    // Same bytecode with a different binding count must still fail reflection,
    // even after the valid layout has populated the shader cache.
    if (device.dispatchSpirv(translated.words, &.{d3d12.Buffer.fromSlice(std.mem.asBytes(&source_words))}, .{ 1, 1, 1 })) |_| {
        return error.CachedInvalidLayoutAccepted;
    } else |err| if (err != error.NativeFailure) return err;
    if (!std.mem.eql(u32, &source_words, &preserved)) return error.InvalidLayoutModifiedBuffer;
    std.debug.print("PASS guest RDNA2 -> shared IR -> HLSL -> D3D12 compute, descriptor arrays and exact readback\n", .{});

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
    try guestVaryingProbe(allocator, &vertex_words);
    try guestResourcesProbe(allocator);
    try guestBlendingProbe(allocator, &vertex_words);
    try guestCacheProbe(allocator, device, vertex.words, fragment.words);
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
    std.debug.print("PASS six guest surface layouts: identical D3D12 pixels, macro-tile XOR, padding and tiled/linear scanout staging\n", .{});
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

fn guestResourcesProbe(allocator: std.mem.Allocator) !void {
    var memory = try allocator.create(GraphicsMemory);
    defer allocator.destroy(memory);
    memory.* = .{};
    const vs = [_]u32{
        0xf4080200, 0xfa000000, // s_load_dwordx4 s8, [s0:s1]
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
        // A second sampling instruction forces a two-element descriptor
        // array; the complete draw also shares three SSBO slots across VS/PS.
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
    try guestNarrowImageProbe(allocator, memory, &state, &executor, &renderer);
    try guestTexelCoordinatesProbe(allocator, memory, &state, &executor, &renderer, &vs);
    // A missing input must fail before touching the output attachment.
    const before = memory.data[0x2000..0x5000].*;
    try state.writeRegister(.shader, 0x04c, memory.data.len + 256);
    const rejected = renderer.draw(&state, .{ .kind = .command, .header = command(gpu.pm4.draw_index_auto, 2), .opcode = gpu.pm4.draw_index_auto, .body = &.{ 3, 2 } });
    if (rejected) |_| return error.InvalidGraphicsPointerAccepted else |_| {}
    if (!std.mem.eql(u8, &before, memory.data[0x2000..0x5000])) return error.RejectedDrawModifiedTarget;
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
