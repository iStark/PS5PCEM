// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const vulkan = @import("vulkan");
const rdna2 = @import("rdna2");

fn vop(op: u32, dst: u32, src: u32) u32 {
    return 0x7e000000 | (dst << 17) | (op << 9) | src;
}
fn sop(op: u32, dst: u32, a: u32, b: u32) u32 {
    return 0x80000000 | (op << 23) | (dst << 16) | (b << 8) | a;
}

pub fn run(allocator: std.mem.Allocator, comptime Memory: type) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_validation = true });
    defer renderer.deinit();
    var guest = Memory{};
    _ = renderer.dcbBackend(guest.interface());
    var dispatches: usize = 0;
    // The control word arrives through a live SSBO, never a baked constant.
    // Modes 0/1 compare bounded and unknown source indexing; the other modes
    // cover destination indexing, both fields, overlap and implicit loop state.
    for (0..8) |mode| for ([_]bool{ false, true }) |wave32| for ([_]bool{ false, true }) |masked| {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(allocator);
        try words.appendSlice(allocator, &.{ 0x34020085, 0xe0381000, 0x80000401, 0xe0381010, 0x80000801, 0xbf8c3f70, vop(2, 8, 267) });
        if (mode == 0) {
            try words.append(allocator, sop(0x0e, 124, 8, 131)); // M0 = s8 & 3
        } else try words.append(allocator, 0xbefc0308); // M0 = s8
        if (mode >= 5) for (0..6) |i| try words.append(allocator, vop(1, @intCast(250 + i), @intCast(260 + i)));
        if (masked) try words.appendSlice(allocator, &.{ 0x361c0081, 0x7daa1c80 }); // odd EXEC
        switch (mode) {
            0, 1 => try words.append(allocator, vop(0x43, 4, 260)),
            2 => try words.append(allocator, vop(0x42, 4, 260)),
            3 => try words.append(allocator, vop(0x44, 5, 260)),
            4 => try words.append(allocator, vop(0x48, 4, 260)),
            5 => try words.append(allocator, vop(0x43, 4, 506)),
            6 => try words.append(allocator, vop(0x42, 250, 260)),
            7 => {
                try words.append(allocator, 0xbefc0380); // M0 = 0
                const header = words.items.len;
                try words.appendSlice(allocator, &.{ vop(0x42, 250, 260), sop(0, 124, 124, 129), 0xbf0a847c }); // ++M0; M0 < 4
                const displacement: i16 = @intCast(@as(isize, @intCast(header)) - @as(isize, @intCast(words.items.len + 1)));
                try words.append(allocator, 0xbf850000 | @as(u32, @as(u16, @bitCast(displacement))));
            },
            else => unreachable,
        }
        if (masked) try words.append(allocator, 0xbefe04c1); // expose inactive VGPRs
        if (mode >= 6) for (0..6) |i| try words.append(allocator, vop(1, @intCast(4 + i), @intCast(506 + i)));
        try words.appendSlice(allocator, &.{ 0xe0781000, 0x80010401, 0xe0781010, 0x80010801, 0xbf810000 });
        var program = try rdna2.decodeProgram(allocator, words.items);
        defer program.deinit(allocator);
        var module = try rdna2.translateProgramSpirv(allocator, &program, .{
            .stage = .compute,
            .local_size = .{ 128, 1, 1 },
            .wave32 = wave32,
            .allow_control_flow_fallback = false,
            .compute_inputs = .{ .local_invocation_id_components = 1 },
            .storage_buffers = &.{
                .{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = 4096 },
                .{ .resource_sgpr = 4, .descriptor_index = 1, .extent_bytes = 4096 },
            },
        });
        defer module.deinit(allocator);
        for (0..4) |offset| {
            const m0: u32 = @intCast(if (mode == 4) offset | ((3 - offset) << 16) else offset);
            for (0..128) |lane| for (0..8) |component| {
                guest.word(0x10000 + lane * 32 + component * 4, if (component == 7) m0 else @intCast(1000 + lane * 17 + component));
                guest.word(0x11000 + lane * 32 + component * 4, 0xdeadbeef);
            };
            _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 4096);
            _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, 4096);
            _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
            var output: [4096]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x11000, &output);
            for (0..128) |lane| {
                var expected: [8]u32 = undefined;
                for (&expected, 0..) |*value, component| value.* = if (component == 7) m0 else @intCast(1000 + lane * 17 + component);
                if (!masked or lane % 2 == 1) switch (mode) {
                    0, 1, 5 => expected[0] = expected[offset],
                    2, 6 => expected[offset] = expected[0],
                    3 => expected[1 + offset] = expected[offset],
                    4 => expected[3 - offset] = expected[offset],
                    7 => @memset(expected[0..4], expected[0]),
                    else => unreachable,
                };
                for (expected, 0..) |want, component| {
                    const actual = std.mem.readInt(u32, output[lane * 32 + component * 4 ..][0..4], .little);
                    if (actual != want) std.debug.print("relative move mode={d} wave32={} masked={} offset={d} lane={d} component={d}: expected={x} actual={x}\n", .{ mode, wave32, masked, offset, lane, component, want, actual });
                    try std.testing.expectEqual(want, actual);
                }
            }
            dispatches += 1;
        }
    };
    std.debug.print("relative VGPR moves passed: {d} dispatches, runtime M0, bounded/unknown indices, source/destination/both/split, overlap, high registers, loop state, wave32/wave64 and inactive lanes\n", .{dispatches});
}
