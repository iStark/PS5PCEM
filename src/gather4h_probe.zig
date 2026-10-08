// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Horizontal gather kernels executed through the production Vulkan backend.
const std = @import("std");
const gpu = @import("gpu");
const vulkan = @import("vulkan");
const Kind = enum { uint, sint, unorm, snorm, float };
const Format = struct { id: u32, bits: u6, channels: u32, kind: Kind };
const threads = 128;
const sentinel = 0xcafe0000;
const us = [_]f32{ -3, -0.25, 0, 0.03125, 0.09375, 0.15625, 0.3125, 0.53125, 0.75, 0.96875, 1, 1.5, 0.0625, 0.125, 0.375, 0.875 };
const vs = [_]f32{ 0, 0.25, 0.5, 0.75, -0.3, 0.99, 1, 2 };

fn formats() [36]Format {
    var result: [36]Format = undefined;
    var count: usize = 0;
    for ([_]u32{ 1, 14, 56 }, [_]u32{ 1, 2, 4 }) |base, channels| {
        for ([_]u32{ 0, 1, 4, 5 }, [_]Kind{ .unorm, .snorm, .uint, .sint }) |offset, kind| {
            result[count] = .{ .id = base + offset, .bits = 8, .channels = channels, .kind = kind };
            count += 1;
        }
    }
    for ([_]u32{ 7, 23, 65 }, [_]u32{ 1, 2, 4 }) |base, channels| {
        for ([_]u32{ 0, 1, 4, 5, 6 }, [_]Kind{ .unorm, .snorm, .uint, .sint, .float }) |offset, kind| {
            result[count] = .{ .id = base + offset, .bits = 16, .channels = channels, .kind = kind };
            count += 1;
        }
    }
    for ([_]u32{ 20, 62, 75 }, [_]u32{ 1, 2, 4 }) |base, channels| {
        for ([_]Kind{ .uint, .sint, .float }, 0..) |kind, offset| {
            result[count] = .{ .id = base + @as(u32, @intCast(offset)), .bits = 32, .channels = channels, .kind = kind };
            count += 1;
        }
    }
    return result;
}

fn rawTexel(format: Format, x: u32, y: u32, component: u32) u32 {
    const n = x + 17 * y + 5 * component;
    if (format.kind == .float) {
        const values = [_]f32{ 0, 1, -1, 0.5, -0.25, 65504, 0.00006103515625, 3.25 };
        const value = values[n % values.len];
        return if (format.bits == 16) @as(u16, @bitCast(@as(f16, @floatCast(value)))) else @bitCast(value);
    }
    const mask: u32 = if (format.bits == 32) 0xffffffff else (@as(u32, 1) << @intCast(format.bits)) - 1;
    if (n < 8) return ([_]u32{ 0, 1, mask, mask / 2 + 1, mask / 2, 2, mask - 1, 0x55 })[n];
    return (n *% 0x91313713 +% 1) & mask;
}

fn converted(format: Format, raw: u32) u32 {
    const signed: i32 = switch (format.bits) {
        8 => @as(i8, @bitCast(@as(u8, @truncate(raw)))),
        16 => @as(i16, @bitCast(@as(u16, @truncate(raw)))),
        else => @bitCast(raw),
    };
    return switch (format.kind) {
        .uint => raw,
        .sint => @bitCast(signed),
        .unorm => @bitCast(@as(f32, @floatFromInt(raw)) / @as(f32, @floatFromInt((@as(u32, 1) << @intCast(format.bits)) - 1))),
        .snorm => @bitCast(@max(@as(f32, -1), @as(f32, @floatFromInt(signed)) / @as(f32, @floatFromInt((@as(u32, 1) << @intCast(format.bits - 1)) - 1)))),
        .float => if (format.bits == 32) raw else @bitCast(@as(f32, @floatCast(@as(f16, @bitCast(@as(u16, @truncate(raw))))))),
    };
}

pub fn run(allocator: std.mem.Allocator, comptime Memory: type) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_validation = true });
    defer renderer.deinit();
    std.debug.print("GATHER4H device: {s}\n", .{renderer.device_info.name()});
    var guest = Memory{};
    _ = renderer.dcbBackend(guest.interface());
    var cases: usize = 0;
    for (formats()) |format| {
        for ([_]bool{ false, true }) |packed_load| {
            if (packed_load and (format.kind == .snorm or (format.kind == .float and format.bits == 16))) continue;
            for (0..@as(usize, if (packed_load) 2 else 1)) |dimension_case| {
                const one_d = dimension_case != 0;
                const height: u32 = if (one_d) 1 else 4;
                const image = [_]u32{ 0x120, (format.id << 20) | (3 << 30), 3 | ((height - 1) << 14), 0xfac | (@as(u32, if (one_d) 8 else 9) << 28), 0, 0, 0, 0 };
                const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
                const view = try layout.subresource(0, 0, 1);
                for (0..height) |y| for (0..16) |x| {
                    const offset = 0x12000 + @as(usize, @intCast(try view.sourceByteOffset(@intCast(x), @intCast(y), 0, 0)));
                    for (0..format.channels) |component| {
                        const raw = rawTexel(format, @intCast(x), @intCast(y), @intCast(component));
                        const address = offset + component * (format.bits / 8);
                        switch (format.bits) {
                            8 => guest.bytes[address] = @truncate(raw),
                            16 => std.mem.writeInt(u16, guest.bytes[address..][0..2], @truncate(raw), .little),
                            else => guest.word(address, raw),
                        }
                    }
                };
                const masks: []const u32 = if (packed_load) &.{ 1, 5, 10, 8, 15 } else &.{ 1, 2, 4, 8 };
                for (masks) |mask| for (0..3) |mode| {
                    const alias = mode != 0;
                    const masked = mode == 2;
                    const destination: u32 = if (alias) 30 else 10;
                    var code: std.ArrayList(u32) = .empty;
                    defer code.deinit(allocator);
                    try code.append(allocator, 0x34060084); // v3 = lane * 16
                    for (0..4) |i| try code.appendSlice(allocator, &.{ 0x7e0002ff | ((destination + @as(u32, @intCast(i))) << 17), sentinel + @as(u32, @intCast(i)) });
                    try code.appendSlice(allocator, &.{ 0xe0381000, 0x80031e03, 0xbf8c3f70 });
                    if (masked) try code.appendSlice(allocator, &.{ 0x36020081, 0x7daa0280 });
                    try code.appendSlice(allocator, &.{ 0xf0000000 | (@as(u32, if (packed_load) 0x62 else 0x61) << 18) | (mask << 8) | @as(u32, if (one_d) 0 else 8) | @as(u32, if (alias and !one_d) 2 else 0), 0x0081001e | (destination << 8) });
                    if (alias and !one_d) try code.append(allocator, 32); // Y=v32, X=v30
                    if (masked) try code.append(allocator, 0xbefe04c1);
                    try code.appendSlice(allocator, &.{ 0xbf8c3f70, 0xe0781000, 0x80000003 | (destination << 8), 0xbf810000 });
                    for (code.items, 0..) |word, i| guest.word(0x100 + i * 4, word);
                    for (0..threads) |lane| {
                        var u = us[lane % us.len];
                        if (packed_load and lane % 16 == 4) u = @bitCast(@as(u32, @bitCast(u)) - 1); // just below a texel-center boundary
                        const v = vs[lane / 16];
                        for ([_]u32{ @bitCast(u), if (alias) sentinel + 1 else @bitCast(v), if (alias) @bitCast(v) else sentinel + 2, sentinel + 3 }, 0..) |word, i|
                            guest.word(0x10000 + lane * 16 + i * 4, word);
                    }
                    var state = gpu.State{};
                    const stage = gpu.resources.ShaderStage.compute;
                    try state.writeRegister(.shader, stage.programRegisterBase(), 1);
                    try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
                    try state.writeRegister(.shader, 0x213, 20 << 1);
                    var userdata: [20]u32 = @splat(0);
                    @memcpy(userdata[0..4], &[_]u32{ 0x11000, 0, threads * 16, 0 });
                    @memcpy(userdata[4..12], &image);
                    @memcpy(userdata[12..16], &[_]u32{ 0x10000, 0, threads * 16, 0 });
                    const clamp = mode != 0;
                    userdata[16] = if (clamp) 2 | (2 << 3) | (2 << 6) else 0;
                    userdata[17] = 0xfff << 12;
                    userdata[18] = (1 << 20) | (1 << 22); // linear filtering must not blend gather results
                    for (userdata, 0..) |word, i| try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(i)), word);
                    _ = try renderer.dispatchRdna2State(&state, .{ threads, 1, 1 }, .{ 1, 1, 1 });
                    var output: [threads * 16]u8 = undefined;
                    try renderer.readbackGuestStorageBuffer(0x11000, &output);
                    for (0..threads) |lane| {
                        var u = us[lane % us.len];
                        if (packed_load and lane % 16 == 4) u = @bitCast(@as(u32, @bitCast(u)) - 1);
                        const v = vs[lane / 16];
                        const active = !masked or lane % 2 != 0;
                        var expected: [4]u32 = if (alias) .{ @bitCast(u), sentinel + 1, @bitCast(v), sentinel + 3 } else .{ sentinel, sentinel + 1, sentinel + 2, sentinel + 3 };
                        const row: i32 = if (one_d) 0 else @intFromFloat(@floor(v * @as(f32, @floatFromInt(height)) - @as(f32, if (packed_load) 0 else 0.5)));
                        const anchor: i32 = @intFromFloat(@floor(u * 16 - 0.5));
                        var stream: [4]u32 = @splat(0);
                        if (active) {
                            for (0..4) |element| {
                                const column = anchor + @as(i32, @intCast(element)) - 1;
                                const cx: u32 = @intCast(if (packed_load or clamp) std.math.clamp(column, 0, 15) else @mod(column, 16));
                                const cy: u32 = @intCast(if (packed_load or clamp) std.math.clamp(row, 0, @as(i32, @intCast(height)) - 1) else @mod(row, @as(i32, @intCast(height))));
                                if (packed_load) {
                                    if (row >= height or @as(u32, format.bits) * format.channels > 32) continue;
                                    for (0..format.channels) |component| {
                                        const position = (element * format.channels + component) * format.bits;
                                        stream[position / 32] |= rawTexel(format, cx, cy, @intCast(component)) << @intCast(position % 32);
                                    }
                                } else {
                                    const channel: u32 = @ctz(mask);
                                    expected[element] = if (channel < format.channels) converted(format, rawTexel(format, cx, cy, channel)) else if (channel == 3) (if (format.kind == .uint or format.kind == .sint) 1 else 0x3f800000) else 0;
                                }
                            }
                            if (packed_load) {
                                var index: usize = 0;
                                for (stream, 0..) |word, bit| if (mask & (@as(u32, 1) << @intCast(bit)) != 0) {
                                    expected[index] = word;
                                    index += 1;
                                };
                            }
                        }
                        for (expected, 0..) |wanted, i| {
                            const actual = std.mem.readInt(u32, output[lane * 16 + i * 4 ..][0..4], .little);
                            const approximate = active and !packed_load and (format.kind == .unorm or format.kind == .snorm);
                            // Allow one SNORM16 step for native gather rounding;
                            // integer, packed and float payloads remain exact.
                            const tolerance: f32 = if (format.kind == .snorm) 1.0 / 32767.0 else 0.000002;
                            const match = if (approximate) @abs(@as(f32, @bitCast(actual)) - @as(f32, @bitCast(wanted))) <= tolerance else actual == wanted;
                            if (!match) {
                                std.debug.print("GATHER4H mismatch packed={} fmt={d} 1D={} mask=0x{x} mode={d} lane={d} xy={d}/{d} word={d} expected=0x{x} actual=0x{x}\n", .{ packed_load, format.id, one_d, mask, mode, lane, u, v, i, wanted, actual });
                                return error.HorizontalGatherMismatch;
                            }
                        }
                    }
                    cases += 1;
                };
            }
        }
        std.debug.print("GATHER4H format {d} passed ({d} dispatches)\n", .{ format.id, cases });
    }
    std.debug.print("GATHER4H passed: {d} dispatches, {d} checked words; native formats, DMASK, edges, sampler modes, NSA, aliasing and EXEC\n", .{ cases, cases * threads * 4 });
}
