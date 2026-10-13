// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const vulkan = @import("vulkan");
const rdna2 = @import("rdna2");

const cases = [_][4]u32{
    .{ 0, 0, 0, 0 },                                     .{ 1, 1, 0xffffffff, 0 },
    .{ 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff }, .{ 0xffffffff, 2, 2, 0xffffffff },
    .{ 0x80000000, 2, 0, 0xffffffff },                   .{ 0x92492492, 7, 0x92492492, 0 },
    .{ 13, 19, 123, 456 },
};

pub fn run(allocator: std.mem.Allocator, comptime Memory: type) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_validation = true });
    defer renderer.deinit();
    var guest = Memory{};
    _ = renderer.dcbBackend(guest.interface());
    var checked: usize = 0;
    for ([_]u9{ 262, 255, 193 }) |add_source| for ([_]bool{ false, true }) |clamp| for ([_]bool{ false, true }) |wave32| for ([_]bool{ false, true }) |masked| {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(allocator);
        // v1 = lane * 16; v[4:7] = input[lane].
        try words.appendSlice(allocator, &.{ 0x34020084, 0xe0381000, 0x80000401, 0xbf8c3f70 });
        if (masked) try words.appendSlice(allocator, &.{ 0x361c0081, 0x7daa1c80 }); // EXEC = odd lanes
        try words.appendSlice(allocator, &.{
            0xd5766a08 | (if (clamp) @as(u32, 0x8000) else 0),
            260 | (261 << 9) | (@as(u32, add_source) << 18),
        });
        if (add_source == 255) try words.append(allocator, 0x92492492);
        // Capture the carry bit using CNDMASK, then store low/high/carry/input.
        try words.appendSlice(allocator, &.{ 0x7e140281, 0x02141480, 0x7e160307, 0xe0781000, 0x80010801, 0xbf810000 });
        var program = try rdna2.decodeProgram(allocator, words.items);
        defer program.deinit(allocator);
        for (0..64) |lane| for (0..4) |component| {
            guest.word(0x10000 + lane * 16 + component * 4, cases[lane % cases.len][component]);
            guest.word(0x11000 + lane * 16 + component * 4, 0xdeadbeef);
        };
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 1024);
        _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, 1024);
        var module = try rdna2.translateSpirv(allocator, &program, .{
            .stage = .compute,
            .local_size = .{ 64, 1, 1 },
            .wave32 = wave32,
            .compute_inputs = .{ .local_invocation_id_components = 1 },
            .storage_buffers = &.{
                .{ .resource_sgpr = 0, .descriptor_index = 0, .extent_bytes = 1024 },
                .{ .resource_sgpr = 4, .descriptor_index = 1, .extent_bytes = 1024 },
            },
        });
        defer module.deinit(allocator);
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        var output: [1024]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x11000, &output);
        for (0..64) |lane| {
            const input = cases[lane % cases.len];
            const add: u64 = if (add_source == 255) 0x92492492 else if (add_source == 193) 0xffffffffffffffff else @as(u64, input[2]) | (@as(u64, input[3]) << 32);
            const wide = @as(u128, input[0]) * input[1] + add;
            const overflow = wide > std.math.maxInt(u64);
            const value: u64 = if (clamp and overflow) std.math.maxInt(u64) else @truncate(wide);
            const expected = [4]u32{ @truncate(value), @truncate(value >> 32), @intFromBool(overflow), input[3] };
            for (expected, 0..) |word, component| {
                const want = if (masked and lane % 2 == 0) 0xdeadbeef else word;
                const actual = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
                if (want != actual) {
                    std.debug.print("MAD u64 mismatch source={d} clamp={} wave32={} masked={} lane={d} word={d}: 0x{x} != 0x{x}\n", .{ add_source, clamp, wave32, masked, lane, component, actual, want });
                    return error.MadU64Mismatch;
                }
                checked += 1;
            }
        }
    };
    std.debug.print("MAD u64 passed: {d} exact output words, register/literal/negative-inline addends, overflow, saturation, carry and masked lanes\n", .{checked});
}
