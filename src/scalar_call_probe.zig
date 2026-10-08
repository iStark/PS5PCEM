// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

const std = @import("std");
const gpu = @import("gpu");
const vulkan = @import("vulkan");
const rdna2 = @import("rdna2");

fn input(lane: u32, component: usize) u32 {
    return switch (component) {
        0 => ([_]u32{ 0, 1, 2, 3, 4, 7, 0x80000000, 0xffffffff })[lane % 8],
        1 => 0x9e3779b9 *% (lane + 1),
        2 => 0xffffffff - lane,
        else => 17 * lane + 1,
    };
}

pub fn run(allocator: std.mem.Allocator, comptime Memory: type) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_validation = true });
    defer renderer.deinit();
    std.debug.print("scalar calls device: {s}\n", .{renderer.device_info.name()});
    var guest = Memory{};
    _ = renderer.dcbBackend(guest.interface());
    var dispatches: usize = 0;
    var checked: usize = 0;
    for (rdna2.scalar_calls.fixtures.cases) |case| {
        for ([_]u32{ 32, 64, 128 }) |threads| {
            for ([_]bool{ false, true }) |masked| {
                var code: std.ArrayList(u32) = .empty;
                defer code.deinit(allocator);
                try code.appendSlice(allocator, case.words[0..4]);
                if (masked) try code.appendSlice(allocator, &.{ 0x361c0081, 0x7daa1c80 }); // v14=lane&1; EXEC=odd lanes
                try code.appendSlice(allocator, case.words[4..]);
                for (code.items, 0..) |word, index| guest.word(0x100 + index * 4, word);
                for (0..128) |lane| for (0..4) |component| {
                    guest.word(0x10000 + lane * 16 + component * 4, input(@intCast(lane), component));
                    guest.word(0x11000 + lane * 16 + component * 4, 0xdeadbeef);
                };
                var state = gpu.State{};
                const stage = gpu.resources.ShaderStage.compute;
                try state.writeRegister(.shader, stage.programRegisterBase(), 1);
                try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
                try state.writeRegister(.shader, 0x213, 8 << 1);
                const user = [_]u32{ 0x10000, 0, 128 * 16, 0, 0x11000, 0, 128 * 16, 0 };
                for (user, 0..) |word, index| try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(index)), word);
                _ = try renderer.dispatchRdna2State(&state, .{ threads, 1, 1 }, .{ 1, 1, 1 });
                var output: [128 * 16]u8 = undefined;
                try renderer.readbackGuestStorageBuffer(0x11000, &output);
                for (0..128) |lane| for (0..4) |component| {
                    const active = lane < threads and (!masked or lane % 2 == 1);
                    const expected: u32 = if (!active) 0xdeadbeef else switch (component) {
                        0 => input(@intCast(lane), 0) +% 0x13579bdf,
                        1 => input(@intCast(lane), 1) ^ 0xa5a5a5a5,
                        2 => input(@intCast(lane), 2) +% input(@intCast(lane), 3),
                        else => input(@intCast(lane), 3) ^ 0x5a5a5a5a,
                    };
                    const actual = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
                    if (expected != actual) {
                        std.debug.print("scalar call mismatch {s} threads={d} masked={} lane={d} word={d}: 0x{x} != 0x{x}\n", .{ case.name, threads, masked, lane, component, actual, expected });
                        return error.ScalarCallMismatch;
                    }
                    checked += 1;
                };
                dispatches += 1;
            }
        }
        std.debug.print("scalar calls passed {s}\n", .{case.name});
    }
    // Execute the same external-fetch linker used by the graphics backend.
    // Compute storage writes make every fetched lane observable to the oracle.
    var caller = try rdna2.decodeProgram(allocator, &.{ 0xbe882110, 0xe0781000, 0x80010401, 0xbf810000 });
    defer caller.deinit(allocator);
    for ([_]bool{ false, true }) |wave32| for ([_]bool{ false, true }) |masked| {
        const arithmetic = rdna2.scalar_calls.fixtures.cases[1].words;
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(allocator);
        try words.appendSlice(allocator, arithmetic[0..4]);
        if (masked) try words.appendSlice(allocator, &.{ 0x361c0081, 0x7daa1c80 });
        try words.appendSlice(allocator, arithmetic[6..14]);
        for (words.items, 0..) |word, index| guest.word(0x200 + index * 4, word);
        const reader = gpu.ShaderMemoryReader{ .context = &guest, .read_fn = guest.interface().read };
        var fetch = try gpu.shader_analysis.decodeFetchWithOptions(allocator, reader, 0x200, 64, .{});
        defer fetch.deinit(allocator);
        var linked: std.ArrayList(rdna2.Instruction) = .empty;
        defer linked.deinit(allocator);
        if (!try gpu.shader_analysis.inlineFetchShader(allocator, caller.instructions.items, fetch.program.instructions.items, 16, &linked)) return error.FetchNotLinked;
        const program = rdna2.Program{ .code = &.{}, .instructions = linked };
        for ([_]u32{ 32, 64, 128 }) |threads| {
            for (0..128) |lane| for (0..4) |component| {
                guest.word(0x10000 + lane * 16 + component * 4, input(@intCast(lane), component));
                guest.word(0x11000 + lane * 16 + component * 4, 0xdeadbeef);
            };
            _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, 2048);
            _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, 2048);
            var module = try rdna2.translateSpirv(allocator, &program, .{
                .stage = .compute,
                .program_address = 0x100,
                .local_size = .{ threads, 1, 1 },
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
            for (0..128) |lane| for (0..4) |component| {
                const active = lane < threads and (!masked or lane % 2 == 1);
                const expected: u32 = if (!active) 0xdeadbeef else switch (component) {
                    0 => input(@intCast(lane), 0) +% 0x13579bdf,
                    1 => input(@intCast(lane), 1) ^ 0xa5a5a5a5,
                    2 => input(@intCast(lane), 2) +% input(@intCast(lane), 3),
                    else => input(@intCast(lane), 3) ^ 0x5a5a5a5a,
                };
                const actual = std.mem.readInt(u32, output[lane * 16 + component * 4 ..][0..4], .little);
                if (expected != actual) {
                    std.debug.print("fetch mismatch wave32={} threads={d} masked={} lane={d} word={d}: 0x{x} != 0x{x}\n", .{ wave32, threads, masked, lane, component, actual, expected });
                    return error.ScalarFetchMismatch;
                }
                checked += 1;
            };
            dispatches += 1;
        }
    };
    std.debug.print("scalar calls passed: {d} dispatches, {d} exact output words including external fetch linking and inactive lanes\n", .{ dispatches, checked });
}
