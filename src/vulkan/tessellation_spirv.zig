// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bridge guest hull-shader factor buffers to the Vulkan tessellator.
const std = @import("std");

pub const vertex = [_]u32{
    0x07230203, 0x00010500, 0,          5,          0,
    0x00020011, 1,          0x0003000e, 0,          1,
    0x0005000f, 0,          3,          0x6e69616d, 0,
    0x00020013, 1,          0x00030021, 2,          1,
    0x00050036, 1,          3,          0,          2,
    0x000200f8, 4,          0x000100fd, 0x00010038,
};

const Writer = struct {
    allocator: std.mem.Allocator,
    words: std.ArrayList(u32) = .empty,
    next_id: u32 = 40,

    fn id(self: *Writer) u32 {
        const value = self.next_id;
        self.next_id += 1;
        return value;
    }

    fn emit(self: *Writer, opcode: u16, operands: []const u32) !void {
        try self.words.append(self.allocator, (@as(u32, @intCast(operands.len + 1)) << 16) | opcode);
        try self.words.appendSlice(self.allocator, operands);
    }
};

pub const Domain = enum { triangles, quads, isolines };

pub fn control(allocator: std.mem.Allocator, descriptor_slot: u32, domain: Domain) ![]u32 {
    if (descriptor_slot >= 64) return error.InvalidStorageDescriptor;
    var w = Writer{ .allocator = allocator };
    errdefer w.words.deinit(allocator);
    try w.words.appendSlice(allocator, &.{ 0x07230203, 0x00010500, 0, 0, 0 });
    try w.emit(17, &.{1}); // Shader
    try w.emit(17, &.{3}); // Tessellation
    try w.emit(14, &.{ 0, 1 });
    try w.emit(15, &.{ 1, 30, 0x6e69616d, 0, 6, 12, 13, 19 });
    try w.emit(16, &.{ 30, 26, 1 }); // One control invocation per patch
    try w.emit(71, &.{ 6, 11, 7 }); // PrimitiveId
    try w.emit(71, &.{ 12, 11, 11 }); // TessLevelOuter
    try w.emit(71, &.{ 13, 11, 12 }); // TessLevelInner
    try w.emit(71, &.{ 12, 15 }); // Patch
    try w.emit(71, &.{ 13, 15 });
    try w.emit(71, &.{ 14, 6, 4 }); // ArrayStride
    try w.emit(72, &.{ 15, 0, 35, 0 });
    try w.emit(71, &.{ 15, 2 }); // Block
    try w.emit(71, &.{ 19, 34, 0 }); // DescriptorSet
    try w.emit(71, &.{ 19, 33, 0 }); // Storage-buffer array binding
    try w.emit(19, &.{1});
    try w.emit(33, &.{ 2, 1 });
    try w.emit(21, &.{ 3, 32, 0 });
    try w.emit(22, &.{ 4, 32 });
    try w.emit(20, &.{32});
    for (0..7) |value| try w.emit(43, &.{ 3, @intCast(20 + value), @intCast(value) });
    try w.emit(43, &.{ 3, 27, descriptor_slot });
    try w.emit(43, &.{ 3, 28, descriptor_slot + 1 });
    try w.emit(43, &.{ 4, 29, 0 });
    try w.emit(32, &.{ 5, 1, 3 });
    try w.emit(59, &.{ 5, 6, 1 });
    try w.emit(28, &.{ 8, 4, 24 });
    try w.emit(28, &.{ 9, 4, 22 });
    try w.emit(32, &.{ 10, 3, 8 });
    try w.emit(32, &.{ 11, 3, 9 });
    try w.emit(59, &.{ 10, 12, 3 });
    try w.emit(59, &.{ 11, 13, 3 });
    try w.emit(32, &.{ 33, 3, 4 });
    try w.emit(29, &.{ 14, 3 });
    try w.emit(30, &.{ 15, 14 });
    try w.emit(28, &.{ 16, 15, 28 });
    try w.emit(32, &.{ 17, 12, 16 });
    try w.emit(32, &.{ 18, 12, 3 });
    try w.emit(32, &.{ 34, 12, 15 });
    try w.emit(59, &.{ 17, 19, 12 });
    try w.emit(54, &.{ 1, 30, 0, 2 });
    try w.emit(248, &.{31});
    const patch = w.id();
    const base = w.id();
    const block = w.id();
    const length = w.id();
    const stride: u32 = switch (domain) {
        .triangles => 4,
        .quads => 6,
        .isolines => 2,
    };
    try w.emit(61, &.{ 3, patch, 6 });
    try w.emit(132, &.{ 3, base, patch, 20 + stride });
    try w.emit(65, &.{ 34, block, 19, 27 });
    try w.emit(68, &.{ 3, length, block, 0 });
    for (0..6) |component| {
        const outer_count: usize = switch (domain) {
            .triangles => 3,
            .quads => 4,
            .isolines => 2,
        };
        const inner_count: usize = switch (domain) {
            .triangles => 1,
            .quads => 2,
            .isolines => 0,
        };
        var value: u32 = 29;
        const live = if (component < 4) component < outer_count else component - 4 < inner_count;
        if (live) {
            const source_component: u32 = @intCast(if (domain == .isolines) 1 - component else if (component < 4) component else outer_count + component - 4);
            const index = w.id();
            const valid = w.id();
            const safe = w.id();
            const pointer = w.id();
            const bits = w.id();
            const loaded = w.id();
            value = w.id();
            try w.emit(128, &.{ 3, index, base, 20 + source_component });
            try w.emit(176, &.{ 32, valid, index, length });
            try w.emit(169, &.{ 3, safe, valid, index, 20 });
            try w.emit(65, &.{ 18, pointer, 19, 27, 20, safe });
            try w.emit(61, &.{ 3, bits, pointer });
            try w.emit(124, &.{ 4, loaded, bits });
            try w.emit(169, &.{ 4, value, valid, loaded, 29 });
        }
        const output = w.id();
        try w.emit(65, &.{ 33, output, if (component < 4) 12 else 13, @intCast(20 + if (component < 4) component else component - 4) });
        try w.emit(62, &.{ output, value });
    }
    try w.emit(253, &.{});
    try w.emit(56, &.{});
    w.words.items[3] = w.next_id;
    return w.words.toOwnedSlice(allocator);
}
