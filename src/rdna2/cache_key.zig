// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Canonical field encoding excludes struct padding and pointer identity.
const std = @import("std");
const Program = @import("instruction.zig").Program;
const PipelineOptions = @import("ir.zig").PipelineOptions;

var next_identity = std.atomic.Value(u64).init(1);

fn allocateIdentity(counter: *std.atomic.Value(u64)) u64 {
    var value = counter.load(.monotonic);
    while (value != std.math.maxInt(u64)) {
        if (counter.cmpxchgWeak(value, value + 1, .monotonic, .monotonic)) |actual| {
            value = actual;
        } else return value;
    }
    return 0; // Saturation disables identity reuse instead of wrapping.
}

/// Owned prefix for a program that will remain immutable until destruction.
/// Reconstructed or specialized instructions require a separate prefix, even
/// when the original code words are unchanged.
pub const ProgramKey = struct {
    bytes: []u8,
    hash_state: std.hash.Wyhash,
    identity: u64,

    pub fn init(allocator: std.mem.Allocator, program: *const Program, pipeline: PipelineOptions) !ProgramKey {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        try appendValue(&bytes, allocator, program.code);
        try appendValue(&bytes, allocator, program.instructions.items);
        try appendValue(&bytes, allocator, pipeline);
        var hash_state = std.hash.Wyhash.init(0);
        hash_state.update(bytes.items);
        const owned = try bytes.toOwnedSlice(allocator);
        return .{ .bytes = owned, .hash_state = hash_state, .identity = allocateIdentity(&next_identity) };
    }

    pub fn deinit(self: ProgramKey, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

test "immutable program identities saturate instead of aliasing old owners" {
    var counter = std.atomic.Value(u64).init(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, allocateIdentity(&counter));
    try std.testing.expectEqual(@as(u64, 0), allocateIdentity(&counter));
    try std.testing.expectEqual(@as(u64, 0), allocateIdentity(&counter));
}

test "prepared hash state matches the full canonical key across chunk boundaries" {
    var code: [64]u32 = undefined;
    for (&code, 0..) |*word, i| word.* = @intCast(i * 137);
    var suffix: [97]u8 = undefined;
    for (&suffix, 0..) |*byte, i| byte.* = @truncate(i * 29);
    for (0..code.len) |length| {
        const program = Program{ .code = code[0..length], .instructions = .empty };
        const key = try ProgramKey.init(std.testing.allocator, &program, .{});
        defer key.deinit(std.testing.allocator);
        var full: std.ArrayList(u8) = .empty;
        defer full.deinit(std.testing.allocator);
        try full.appendSlice(std.testing.allocator, key.bytes);
        for (0..suffix.len) |count| {
            full.shrinkRetainingCapacity(key.bytes.len);
            try full.appendSlice(std.testing.allocator, suffix[0..count]);
            var state = key.hash_state;
            state.update(suffix[0..count]);
            try std.testing.expectEqual(std.hash.Wyhash.hash(0, full.items), state.final());
        }
    }
}

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
