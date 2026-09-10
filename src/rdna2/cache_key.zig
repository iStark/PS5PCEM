// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Canonical field encoding excludes struct padding and pointer identity.
const std = @import("std");
const Program = @import("instruction.zig").Program;
const PipelineOptions = @import("ir.zig").PipelineOptions;

/// Owned prefix for a program that will remain immutable until destruction.
/// Reconstructed or specialized instructions require a separate prefix, even
/// when the original code words are unchanged.
pub const ProgramKey = struct {
    bytes: []u8,

    pub fn init(allocator: std.mem.Allocator, program: *const Program, pipeline: PipelineOptions) !ProgramKey {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        try appendValue(&bytes, allocator, program.code);
        try appendValue(&bytes, allocator, program.instructions.items);
        try appendValue(&bytes, allocator, pipeline);
        return .{ .bytes = try bytes.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: ProgramKey, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub fn appendValue(key: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!void {
    // Reserve once for the whole object. Growing/checking the ArrayList for
    // every field of every decoded instruction costs more than a cache hit.
    const bytes = try key.addManyAsSlice(allocator, serializedSize(value));
    var cursor: [*]u8 = bytes.ptr;
    writeValue(&cursor, value);
    std.debug.assert(cursor == bytes.ptr + bytes.len);
}

fn fixedSize(comptime T: type) ?usize {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            var size: usize = 0;
            for (info.fields) |field| size += fixedSize(field.type) orelse break :blk null;
            break :blk size;
        },
        .array => |info| if (fixedSize(info.child)) |size| size * info.len else null,
        .@"enum" => |info| fixedSize(info.tag_type),
        .bool => 1,
        .int, .float => @sizeOf(T),
        else => null,
    };
}

fn serializedSize(value: anytype) usize {
    if (comptime fixedSize(@TypeOf(value))) |size| return size;
    return switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |info| blk: {
            var size: usize = 0;
            inline for (info.fields) |field| size += serializedSize(@field(value, field.name));
            break :blk size;
        },
        .array => blk: {
            var size: usize = 0;
            for (value) |element| size += serializedSize(element);
            break :blk size;
        },
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                if (comptime fixedSize(info.child)) |size| break :blk @sizeOf(usize) + value.len * size;
                var size: usize = @sizeOf(usize);
                for (value) |element| size += serializedSize(element);
                break :blk size;
            },
            .one => serializedSize(value.*),
            else => @compileError("Unsupported shader cache pointer"),
        },
        .optional => if (value) |payload| 1 + serializedSize(payload) else 1,
        else => unreachable,
    };
}

fn writeValue(cursor: *[*]u8, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.fields) |field| {
            writeValue(cursor, @field(value, field.name));
        },
        .array => for (value) |element| writeValue(cursor, element),
        .pointer => |info| switch (info.size) {
            .slice => {
                writeValue(cursor, value.len);
                for (value) |element| writeValue(cursor, element);
            },
            .one => writeValue(cursor, value.*),
            else => @compileError("Unsupported shader cache pointer"),
        },
        .optional => {
            writeValue(cursor, value != null);
            if (value) |payload| writeValue(cursor, payload);
        },
        .@"enum" => writeValue(cursor, @intFromEnum(value)),
        .bool => {
            cursor.*[0] = @intFromBool(value);
            cursor.* += 1;
        },
        .int => |info| {
            const UInt = std.meta.Int(.unsigned, info.bits);
            const Storage = std.meta.Int(.unsigned, @sizeOf(T) * 8);
            const bits: Storage = @as(UInt, @bitCast(value));
            @memcpy(cursor.*[0..@sizeOf(Storage)], std.mem.asBytes(&bits));
            cursor.* += @sizeOf(Storage);
        },
        .float => {
            const bits: std.meta.Int(.unsigned, @bitSizeOf(T)) = @bitCast(value);
            writeValue(cursor, bits);
        },
        else => @compileError("Unsupported shader cache value: " ++ @typeName(T)),
    }
}
