// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const vulkan = @import("vulkan");
const rdna2 = @import("rdna2");

fn input(lane: usize) u32 {
    const sample = lane % 66;
    return switch (sample) {
        0 => 0,
        1 => 0xffff_ffff,
        else => value: {
            const bit = @as(u32, 1) << @as(u5, @intCast((sample - 2) / 2));
            break :value if (sample % 2 == 0) bit else ~bit;
        },
    };
}

pub fn run(allocator: std.mem.Allocator, comptime Memory: type) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_validation = true });
    defer renderer.deinit();
    var guest = Memory{};
    _ = renderer.dcbBackend(guest.interface());
    for ([_]bool{ false, true }) |extended| for ([_]bool{ false, true }) |wave32| for ([_]bool{ false, true }) |masked| {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(allocator);
        // v1 = lane * 16; v[4:7] = input record.
        try words.appendSlice(allocator, &.{ 0x34020084, 0xe0381000, 0x80000401, 0xbf8c3f70 });
        if (masked) try words.appendSlice(allocator, &.{ 0x361c0081, 0x7daa1c80 });
        for ([_]u32{ 0x3b, 0x39, 0x3a }, 0..) |opcode, i| {
            const destination: u32 = @intCast(8 + i);
            if (extended) {
                try words.appendSlice(allocator, &.{ 0xd4000000 | ((0x180 + opcode) << 16) | destination, 260 });
            } else {
                try words.append(allocator, 0x7e000000 | (destination << 17) | (opcode << 9) | 260);
            }
        }
        try words.appendSlice(allocator, &.{ 0x7e160304, 0xe0781000, 0x80010801, 0xbf810000 });
        var program = try rdna2.decodeProgram(allocator, words.items);
        defer program.deinit(allocator);
        for (0..128) |lane| for (0..4) |component| {
            guest.word(0x10000 + lane * 16 + component * 4, input(lane));
            guest.word(0x11000 + lane * 16 + component * 4, 0xdead_beef);
        };
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 2048);
        _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, 2048);
        var module = try rdna2.translateSpirv(allocator, &program, .{
            .stage = .compute,
            .local_size = .{ 128, 1, 1 },
            .wave32 = wave32,
            .compute_inputs = .{ .local_invocation_id_components = 1 },
            .storage_buffers = &.{
                .{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = 2048 },
                .{ .resource_sgpr = 4, .descriptor_index = 1, .extent_bytes = 2048 },
            },
        });
        defer module.deinit(allocator);
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        var output: [2048]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x11000, &output);
        for (0..128) |lane| {
            const value = input(lane);
            const normalized = if (value & 0x8000_0000 != 0) ~value else value;
            const expected = [_]u32{
                if (normalized == 0) 0xffff_ffff else @clz(normalized),
                if (value == 0) 0xffff_ffff else @clz(value),
                if (value == 0) 0xffff_ffff else @ctz(value),
                value,
            };
            for (expected, 0..) |word, component| {
                const want = if (masked and lane % 2 == 0) 0xdead_beef else word;
                const actual = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
                try std.testing.expectEqual(want, actual);
            }
        }
    };
    std.debug.print("first-bit GPU probe passed: signed/unsigned high and low scans, VOP1/VOP3, wave32/wave64 and masked lanes\n", .{});
}
