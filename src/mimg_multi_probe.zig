// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! End-to-end MIMG BY/PCK loads: guest code, resource discovery, native
//! texture upload, SPIR-V execution, and guest buffer readback.
const std = @import("std");
const gpu = @import("gpu");
const vulkan = @import("vulkan");

const Kind = enum { uint, sint, unorm, snorm, float };
const Format = struct { id: u32, bits: u5, channels: u32, kind: Kind };
const formats = [_]Format{
    .{ .id = 1, .bits = 8, .channels = 1, .kind = .unorm },
    .{ .id = 2, .bits = 8, .channels = 1, .kind = .snorm },
    .{ .id = 5, .bits = 8, .channels = 1, .kind = .uint },
    .{ .id = 6, .bits = 8, .channels = 1, .kind = .sint },
    .{ .id = 7, .bits = 16, .channels = 1, .kind = .unorm },
    .{ .id = 8, .bits = 16, .channels = 1, .kind = .snorm },
    .{ .id = 11, .bits = 16, .channels = 1, .kind = .uint },
    .{ .id = 12, .bits = 16, .channels = 1, .kind = .sint },
    .{ .id = 13, .bits = 16, .channels = 1, .kind = .float },
    .{ .id = 14, .bits = 8, .channels = 2, .kind = .unorm },
    .{ .id = 15, .bits = 8, .channels = 2, .kind = .snorm },
    .{ .id = 18, .bits = 8, .channels = 2, .kind = .uint },
    .{ .id = 19, .bits = 8, .channels = 2, .kind = .sint },
};
const threads = 256;
const xs = [_]u32{ 0, 1, 2, 3, 5, 6, 7, 57, 58, 59, 60, 61, 29, 30, 0xffffffff, 0x80000000 };
const ys = [_]u32{ 0, 1, 3, 0xffffffff };
const sentinel = 0xcafe0000;

fn rawTexel(format: Format, level: u32, x: u32, y: u32, channel: u32) u32 {
    if (format.kind == .float) {
        const values = [_]f16{ 0, 1, -1, 0.5, -0.25, 65504, 0.00006103515625, 3.25 };
        return @as(u16, @bitCast(values[(level + x + y + channel) % values.len]));
    }
    const mask = (@as(u32, 1) << format.bits) - 1;
    if (x < 8 and y == 0 and level == 0) return ([_]u32{ 0, 1, mask, (mask + 1) / 2, mask / 2, 2, mask - 1, 0x55 })[(x + channel) % 8];
    return (level * 0x9e37 + y * 0x5171 + x * 0x1313 + channel * 0x2b2b + 1) & mask;
}

fn converted(format: Format, raw: u32) u32 {
    const signed: i32 = if (format.bits == 8) @as(i8, @bitCast(@as(u8, @truncate(raw)))) else @as(i16, @bitCast(@as(u16, @truncate(raw))));
    return switch (format.kind) {
        .uint => raw,
        .sint => @bitCast(signed),
        .unorm => @bitCast(@as(f32, @floatFromInt(raw)) / @as(f32, @floatFromInt((@as(u32, 1) << format.bits) - 1))),
        .snorm => @bitCast(@max(@as(f32, -1), @as(f32, @floatFromInt(signed)) / @as(f32, @floatFromInt((@as(u32, 1) << (format.bits - 1)) - 1)))),
        .float => @bitCast(@as(f32, @floatCast(@as(f16, @bitCast(@as(u16, @truncate(raw))))))),
    };
}

pub fn run(allocator: std.mem.Allocator, comptime Memory: type) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_validation = true });
    defer renderer.deinit();
    std.debug.print("MIMG multi-texel device: {s}\n", .{renderer.device_info.name()});
    var guest = Memory{};
    _ = renderer.dcbBackend(guest.interface());
    var cases: usize = 0;
    for (formats) |format| {
        const image = [_]u32{ 0x120, (format.id << 20), 15 | (2 << 14), 0xfac | (1 << 16) | (9 << 28), 0, 1 << 4, 0, 0 }; // 61x3, two mips
        const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
        for (0..2) |level| {
            const view = try layout.subresource(@intCast(level), 0, 1);
            for (0..view.height) |y| for (0..view.width) |x| {
                const offset = 0x12000 + @as(usize, @intCast(try view.sourceByteOffset(@intCast(x), @intCast(y), 0, 0)));
                for (0..format.channels) |channel| {
                    const raw = rawTexel(format, @intCast(level), @intCast(x), @intCast(y), @intCast(channel));
                    if (format.bits == 8) guest.bytes[offset + channel] = @truncate(raw) else std.mem.writeInt(u16, guest.bytes[offset + channel * 2 ..][0..2], @truncate(raw), .little);
                }
            };
        }
        for ([_]u32{ 0x42, 0x43, 0x4a, 0x4b, 0x70, 0x71, 0x73, 0x74 }) |opcode| {
            const elements: u32 = if (opcode == 0x42 or opcode == 0x4a or opcode == 0x70 or opcode == 0x73) 2 else 4;
            const packed_load = opcode >= 0x70;
            const mip = opcode == 0x4a or opcode == 0x4b or opcode == 0x73 or opcode == 0x74;
            if (elements * format.channels * format.bits > 32) continue;
            if (packed_load and (format.kind == .snorm or format.kind == .float)) continue;
            const result_words = if (packed_load) 1 else elements * format.channels;
            const mask = (@as(u32, 1) << @intCast(result_words)) - 1;
            for (0..3) |mode| {
                const alias_nsa = mode != 0;
                const masked = mode == 2;
                const destination: u32 = if (alias_nsa) 30 else 10;
                var code: std.ArrayList(u32) = .empty;
                defer code.deinit(allocator);
                // v3 = local invocation X * 16; output V#s0, image T#s4, input V#s12.
                try code.append(allocator, 0x34060084);
                for (0..4) |i| try code.appendSlice(allocator, &.{ 0x7e0002ff | ((destination + @as(u32, @intCast(i))) << 17), sentinel + @as(u32, @intCast(i)) });
                try code.appendSlice(allocator, &.{ 0xe0381000, 0x80031e03, 0xbf8c3f70 });
                if (masked) try code.appendSlice(allocator, &.{ 0x36020081, 0x7daa0280 }); // only odd lanes
                try code.appendSlice(allocator, &.{ 0xf0000008 | (opcode << 18) | (mask << 8) | @as(u32, if (alias_nsa) 2 else 0), 0x0001001e | (destination << 8) });
                if (alias_nsa) try code.append(allocator, 0x00001f20); // X=v30, Y=v32, mip=v31
                if (masked) try code.append(allocator, 0xbefe04c1); // restore EXEC before readback stores
                try code.appendSlice(allocator, &.{ 0xbf8c3f70, 0xe0781000, 0x80000003 | (destination << 8), 0xbf810000 });
                for (code.items, 0..) |word, i| guest.word(0x100 + i * 4, word);
                for (0..threads) |lane| {
                    const x = xs[lane % 16];
                    const y = ys[(lane / 16) % 4];
                    const level = ([_]u32{ 0, 1, 2, 0xffffffff })[lane / 64];
                    for ([_]u32{ x, if (alias_nsa) level else y, if (alias_nsa) y else level, sentinel + 3 }, 0..) |word, i|
                        guest.word(0x10000 + lane * 16 + i * 4, word);
                }
                var state = gpu.State{};
                const compute = gpu.resources.ShaderStage.compute;
                try state.writeRegister(.shader, compute.programRegisterBase(), 1);
                try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
                try state.writeRegister(.shader, 0x213, 16 << 1);
                var userdata: [16]u32 = undefined;
                @memcpy(userdata[0..4], &[_]u32{ 0x11000, 0, threads * 16, 0 });
                @memcpy(userdata[4..12], &image);
                @memcpy(userdata[12..16], &[_]u32{ 0x10000, 0, threads * 16, 0 });
                for (userdata, 0..) |word, i| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
                _ = try renderer.dispatchRdna2State(&state, .{ threads, 1, 1 }, .{ 1, 1, 1 });
                var output: [threads * 16]u8 = undefined;
                try renderer.readbackGuestStorageBuffer(0x11000, &output);
                for (0..threads) |lane| {
                    const x = xs[lane % 16];
                    const y = ys[(lane / 16) % 4];
                    const input_level = ([_]u32{ 0, 1, 2, 0xffffffff })[lane / 64];
                    const level = if (mip) input_level else 0;
                    const width: u32 = if (level == 0) 61 else 30;
                    const height: u32 = if (level == 0) 3 else 1;
                    const valid = level < 2 and x < width and width - x >= elements and y < height;
                    var expected: [4]u32 = if (alias_nsa) .{ x, input_level, y, sentinel + 3 } else .{ sentinel, sentinel + 1, sentinel + 2, sentinel + 3 };
                    const active = !masked or lane % 2 != 0;
                    if (active) @memset(expected[0..result_words], 0);
                    if (valid and active) {
                        const first = x - x % elements;
                        for (0..elements) |element| for (0..format.channels) |channel| {
                            const raw = rawTexel(format, level, first + @as(u32, @intCast(element)), y, @intCast(channel));
                            const index = element * format.channels + channel;
                            if (packed_load) expected[0] |= raw << @intCast(index * format.bits) else expected[index] = converted(format, raw);
                        };
                    }
                    for (expected, 0..) |wanted, i| {
                        const actual = std.mem.readInt(u32, output[lane * 16 + i * 4 ..][0..4], .little);
                        const approximate = valid and active and !packed_load and i < result_words and (format.kind == .unorm or format.kind == .snorm);
                        const match = if (approximate) @abs(@as(f32, @bitCast(actual)) - @as(f32, @bitCast(wanted))) <= 0.000002 else actual == wanted;
                        if (!match) {
                            std.debug.print("MIMG failure op=0x{x} fmt={d} mode={d} lane={d} xyz={d}/{d}/{d} result={d} expected=0x{x} actual=0x{x}\n", .{ opcode, format.id, mode, lane, x, y, level, i, wanted, actual });
                            return error.MultiTexelMismatch;
                        }
                    }
                }
                cases += 1;
            }
        }
    }
    std.debug.print("MIMG multi-texel passed: {d} dispatches, {d} checked result words; BY2/BY4/PCK2/PCK4, mip bounds, integer/normalized/float formats, NSA, aliased destinations and inactive EXEC lanes\n", .{ cases, cases * threads * 4 });
}
