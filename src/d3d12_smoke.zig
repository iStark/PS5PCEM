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
    try state.writeRegister(.context, 0x08f, 0); // Shader mask also suppresses writes.
    _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 2 });
    if (!std.mem.eql(u8, &before, &memory.data)) return error.Pm4ShaderMaskMismatch;
    // A rejected operation poisons the queue; following guest labels must not
    // become visible as though all previous rendering had finished.
    const rejected = executor.execute(&.{ command(gpu.pm4.draw_index_2, 5), 3, 0, 0, 3, 0 });
    if (rejected) |_| return error.UnsupportedDrawWasAccepted else |err| if (err != error.BackendRejected) return err;
    const backend = renderer.dcbBackend();
    if (backend.vtable.write(backend.context, 0x1200, &.{ 1, 2, 3, 4 })) return error.FailedSubmissionPublishedLabel;
    std.debug.print("PASS PM4 compute/draw -> D3D12 -> guest memory, pitched target and shader mask; unsupported draw stops the queue\n", .{});
}

fn command(opcode: u8, body_words: u14) u32 {
    return 0xc0000000 | (@as(u32, body_words - 1) << 16) | (@as(u32, opcode) << 8);
}

fn vop1(op: u8, dst: u8, src: u16) u32 {
    return (@as(u32, 0x3f) << 25) | (@as(u32, dst) << 17) | (@as(u32, op) << 9) | src;
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
    var draw = try d3d12.Draw.fullTarget(65, 37);
    try device.drawSpirv(vertex.words, fragment.words, draw, &pixels);
    const center = (18 * 65 + 32) * 4;
    if (!std.mem.eql(u8, pixels[center..][0..4], &.{ 255, 0, 0, 255 }) or !std.mem.eql(u8, pixels[0..4], &.{ 0, 0, 0, 255 })) return error.GuestGraphicsMismatch;
    // A second draw with color writes masked must retain the existing image.
    const before = pixels;
    draw.write_mask = 0;
    try device.drawSpirv(vertex.words, fragment.words, draw, &pixels);
    if (!std.mem.eql(u8, &before, &pixels)) return error.GuestColorMaskMismatch;
    std.debug.print("PASS guest RDNA2 vertex/pixel shaders, raster output and preservation of masked target bytes\n", .{});
    try guestCommandProbe(allocator, &vertex_words, &pixel_words);
}
