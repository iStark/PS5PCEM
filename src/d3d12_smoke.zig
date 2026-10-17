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
        try state.writeRegister(.uconfig, 0x242, 5);
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
