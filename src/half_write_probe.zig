// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const vulkan = @import("vulkan");
const rdna2 = @import("rdna2");

pub fn run(allocator: std.mem.Allocator, comptime Memory: type) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_validation = true });
    defer renderer.deinit();
    var guest = Memory{};
    _ = renderer.dcbBackend(guest.interface());
    const Case = struct { code: []const u32, expected: u32 };
    const cases = [_]Case{
        // v4 is prefilled with unrelated f32 data. ASTRO's SDWA DWORD
        // conversion must clear its upper half before packing another color.
        .{ .code = &.{ 0x7e0814f9, 0x00060605 }, .expected = 0x00003e00 },
        .{ .code = &.{0x7e081505}, .expected = 0x47293e00 }, // ordinary VOP1
        .{ .code = &.{ 0x7e0814f9, 0x00060405 }, .expected = 0x00003e00 }, // WORD0, PAD
        .{ .code = &.{ 0x7e0814f9, 0x00061405 }, .expected = 0x47293e00 }, // WORD0, PRESERVE
        .{ .code = &.{ 0x7e0814f9, 0x00060505 }, .expected = 0x3e000000 }, // WORD1, PAD
        .{ .code = &.{ 0x7e0814f9, 0x00061505 }, .expected = 0x3e001234 }, // WORD1, PRESERVE
        .{ .code = &.{ 0xd58a0004, 0x105 }, .expected = 0x47293e00 }, // VOP3 low half
        .{ .code = &.{ 0xd58a4004, 0x105 }, .expected = 0x3e001234 }, // VOP3 high half
        .{ .code = &.{ 0x6a080ef9, 0x06060606 }, .expected = 0x00004600 }, // SDWA mul_f16, DWORD
        .{ .code = &.{0x6a080f06}, .expected = 0x47294600 }, // ordinary mul_f16
    };
    for (cases, 0..) |case, case_index| for ([_]bool{ false, true }) |wave32| for ([_]bool{ false, true }) |masked| {
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(allocator);
        // v1 = lane * 16; load v4 (poison), v5 (1.5f), v6 (2h), v7 (3h).
        try words.appendSlice(allocator, &.{ 0x34020084, 0xe0381000, 0x80000401, 0xbf8c3f70 });
        if (masked) try words.appendSlice(allocator, &.{ 0x361c0081, 0x7daa1c80 });
        try words.appendSlice(allocator, case.code);
        // Restore EXEC before storing so inactive VGPR preservation is checked.
        if (masked) try words.append(allocator, 0xbefe04c1);
        try words.appendSlice(allocator, &.{ 0xe0781000, 0x80010401, 0xbf810000 });
        var program = try rdna2.decodeProgram(allocator, words.items);
        defer program.deinit(allocator);
        const inputs = [_]u32{ 0x47291234, 0x3fc00000, 0x4000, 0x4200 };
        for (0..128) |lane| for (inputs, 0..) |value, component| {
            guest.word(0x10000 + lane * 16 + component * 4, value);
            guest.word(0x11000 + lane * 16 + component * 4, 0xdeadbeef);
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
        for (0..128) |lane| for (inputs, 0..) |value, component| {
            const want = if (component == 0 and !(masked and lane % 2 == 0)) case.expected else value;
            const actual = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
            if (want != actual) std.debug.print("half write case={d} wave32={} masked={} lane={d}: expected={x} actual={x}\n", .{ case_index, wave32, masked, lane, want, actual });
            try std.testing.expectEqual(want, actual);
        };
    };
    std.debug.print("half-write GPU probe passed: explicit SDWA DWORD, PAD/PRESERVE, ordinary VOP1/VOP2, VOP3 half selection, wave32/wave64 and inactive lanes\n", .{});
}
