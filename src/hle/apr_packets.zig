// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz
//
// Native APR packet layout cross-checked against drakmor/ampr_emu (GPL-3.0),
// src/ampr_emu_command_packing.cpp at cfa85df379f6eeeb165d7badf9b648e266fe77b7.
// Decode bytes only: no guest pointers are dereferenced and no work is executed.
const std = @import("std");
const amm = @import("amm_packets.zig");
const counters = @import("ampr_counters.zig");

pub const Header = extern struct {
    kind: u32,
    offset: u32,
    count: i32,
    capacity: u32,
    storage: u64,
};
pub const Read = struct {
    size: usize,
    file: ?u32 = null,
    destination: ?u64 = null,
    offset: ?u64 = null,
};
pub const AddressWait = struct { address: u64, value: u64, compare: counters.Compare };
pub const AddressWrite = struct {
    address: u64,
    value: u64,
    source: enum { immediate, time, word, pair },
};
pub const Event = struct { queue: u64, ident: u32, data: u64 };
pub const Command = union(enum) {
    read: Read,
    reset,
    map_begin: amm.Command,
    map_end,
    map: amm.Command,
    wait_address: AddressWait,
    write_address: AddressWrite,
    wait_counter: counters.Wait,
    write_counter: counters.Write,
    event: Event,
    marker,
};
pub const Error = error{InvalidPacket};
pub const Decoded = struct { command: Command, bytes: usize };

fn word(bytes: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
}
fn need(bytes: []const u8, count: usize, min: usize, max: usize) Error!void {
    if (count < min or count > max or bytes.len < count * 4) return error.InvalidPacket;
}
fn address(high: u32, low: u32) u64 {
    return (@as(u64, high & 0xffff0000) << 16) | low;
}
fn comparison(value: u32) Error!counters.Compare {
    return std.enums.fromInt(counters.Compare, value) orelse error.InvalidPacket;
}

pub fn decode(bytes: []const u8) Error!Decoded {
    try need(bytes, 1, 1, 1);
    const w0 = word(bytes, 0);
    const opcode = w0 & 0xff;
    var count: usize = ((w0 >> 8) & 15) + 1;
    const command: Command = blk: {
        switch (opcode) {
            0x28, 0x29, 0x2a, 0x2b => {
                count = ((w0 >> 8) & (if (opcode == 0x29) @as(u32, 3) else 7)) + 1;
                const min: usize = switch (opcode) {
                    0x28 => 5,
                    0x29 => 2,
                    0x2a => 3,
                    else => 4,
                };
                try need(bytes, count, min, min + @intFromBool(opcode != 0x2a));
                if (opcode == 0x2a and w0 & 0xfff != 0x22a) return error.InvalidPacket;
                var read = Read{ .size = @as(usize, word(bytes, 1)) + 1 };
                switch (opcode) {
                    0x28 => {
                        const w4 = word(bytes, 4);
                        read.file = word(bytes, 2) & 0x7fffffff;
                        read.destination = word(bytes, 3) | (@as(u64, w4 & 0xffff) << 32);
                        read.offset = ((w0 >> 12) & 0x3ffff) | (w4 & 0xfffc0000);
                        if (count == 6) read.offset.? |= @as(u64, word(bytes, 5) & 0xff) << 32;
                    },
                    0x29 => {
                        read.offset = (w0 >> 12) & 0x3ffff;
                        if (count == 3) read.offset.? |= @as(u64, word(bytes, 2) & 0x3fffff) << 18;
                    },
                    0x2a => read.destination = word(bytes, 2) | (@as(u64, (w0 >> 12) & 0xffff) << 32),
                    else => {
                        const w3 = word(bytes, 3);
                        read.destination = word(bytes, 2) | (@as(u64, w3 & 0xffff) << 32);
                        read.offset = ((w0 >> 12) & 0x3ffff) | (w3 & 0xfffc0000);
                        if (count == 5) read.offset.? |= @as(u64, word(bytes, 4) & 0xff) << 32;
                    },
                }
                break :blk .{ .read = read };
            },
            0x2f, 0x2e => {
                if (w0 != opcode) return error.InvalidPacket;
                count = 1;
                break :blk if (opcode == 0x2f) .reset else .map_end;
            },
            0x2d => {
                const direct = w0 & 0xfff == 0x32d;
                if (!direct and w0 & 0xfff != 0x22d) return error.InvalidPacket;
                count = if (direct) 4 else 3;
                try need(bytes, count, count, count);
                const va = (@as(u64, word(bytes, 1)) << 14) | (@as(u64, word(bytes, 2) & 3) << 46);
                const size = @as(u64, word(bytes, 2) & 0x1ffffffc) << 12;
                const prot: u15 = @truncate(w0 >> 12);
                if (!amm.validRange(va, size) or prot & ~amm.protection_mask != 0) return error.InvalidPacket;
                break :blk .{ .map_begin = .{
                    .kind = if (direct) .direct else .map,
                    .address = va,
                    .size = size,
                    .source = if (direct) @as(u64, word(bytes, 3) & 0x03ffffff) << 14 else 0,
                    .protection = prot,
                    .memory_type = @truncate(w0 >> 27),
                } };
            },
            1 => {
                try need(bytes, count, 2, 4);
                break :blk .{ .wait_address = .{
                    .address = address(w0, word(bytes, 1)),
                    .value = (if (count >= 3) @as(u64, word(bytes, 2)) else 0) |
                        (if (count == 4) @as(u64, word(bytes, 3)) << 32 else 0),
                    .compare = try comparison((w0 >> 13) & 7),
                } };
            },
            5, 0x75 => {
                count = ((w0 >> 8) & 3) + 1;
                try need(bytes, count, 2, 4);
                const w1 = word(bytes, 1);
                const class = w1 & 7;
                if (class > 3) return error.InvalidPacket;
                const value = @as(u64, (w0 >> 12) & 3) |
                    (if (count >= 3) @as(u64, word(bytes, 2)) << 2 else 0) |
                    (if (count == 4) @as(u64, word(bytes, 3)) << 34 else 0);
                if (class >= 2 and (value > 127 or !counters.valid(@intCast(value), if (class == 2) .word else .pair)))
                    return error.InvalidPacket;
                break :blk .{ .write_address = .{
                    .address = address(w0, w1 & 0xfffffff8),
                    .value = value,
                    .source = @enumFromInt(class),
                } };
            },
            6, 0x76 => {
                try need(bytes, count, 1, 3);
                const w1 = if (count >= 2) word(bytes, 1) else 0;
                const access: counters.Access = @enumFromInt(((w1 >> 20) & 7) ^ 1);
                const index: u8 = @truncate(w0 >> 24);
                if (!counters.valid(index, access)) return error.InvalidPacket;
                break :blk .{ .write_counter = .{
                    .counter = index,
                    .access = access,
                    .value = ((w0 >> 12) & 0xfff) | (@as(u64, w1 & 0xfffff) << 12) |
                        (if (count == 3) @as(u64, word(bytes, 2)) << 32 else 0),
                    .operation = std.enums.fromInt(counters.Operation, (w1 >> 24) & 7) orelse return error.InvalidPacket,
                } };
            },
            2 => {
                try need(bytes, count, 1, 5);
                if (count == 4) return error.InvalidPacket;
                const w1 = if (count >= 2) word(bytes, 1) else 0;
                const access: counters.Access = @enumFromInt(((w1 >> 24) & 7) ^ 1);
                const index: u8 = @truncate(w0 >> 24);
                const masked = (w1 >> 28) & 3;
                if (!counters.valid(index, access) or masked > 1) return error.InvalidPacket;
                var reference: u64 = (w0 >> 16) & 0xff;
                var mask: u64 = std.math.maxInt(u64);
                if (masked != 0 and count == 2) {
                    reference |= @as(u64, w1 & 0xff) << 8;
                    mask = (w1 >> 8) & 0xffff;
                } else {
                    const compact = masked != 0 and w1 & 0x00ffff00 == 0 and (count < 5 or word(bytes, 2) == 0);
                    reference |= @as(u64, w1 & (if (compact) @as(u32, 0xff) else 0xffffff)) << 8;
                    if (count >= 3) {
                        if (masked == 0 or (count == 5 and !compact)) reference |= @as(u64, word(bytes, 2)) << 32;
                        if (masked != 0) mask = if (count == 3) word(bytes, 2) else word(bytes, 3) | (@as(u64, word(bytes, 4)) << 32);
                    }
                }
                if (count == 5 and masked == 0) return error.InvalidPacket;
                break :blk .{ .wait_counter = .{
                    .counter = index,
                    .access = access,
                    .reference = reference,
                    .mask = mask,
                    .compare = try comparison((w0 >> 13) & 7),
                } };
            },
            else => {},
        }
        if (w0 & 0xfff == 0x408 or w0 & 0xfff == 0x478) {
            count = 5;
            try need(bytes, count, count, count);
            break :blk .{ .event = .{
                .queue = address(w0, word(bytes, 1)),
                .ident = word(bytes, 2),
                .data = word(bytes, 3) | (@as(u64, word(bytes, 4)) << 32),
            } };
        }
        if (w0 & 0xffff000f == 0x5452000f) {
            try need(bytes, count, 1, 16);
            break :blk .marker; // Debug text/NOP has no execution side effects.
        }
        const decoded = amm.decode(bytes) catch return error.InvalidPacket;
        if (decoded.command.prt) return error.InvalidPacket;
        count = decoded.bytes / 4;
        break :blk .{ .map = decoded.command };
    };
    return .{ .command = command, .bytes = count * 4 };
}

test "native APR packet sizes include 4 GiB reads and 40-bit offsets" {
    const words = [_]u32{ 0x02345528, 0xffffffff, 17, 0x87654321, 0xabc81234, 0x56 };
    const read = (try decode(std.mem.asBytes(&words))).command.read;
    try std.testing.expectEqual(@as(usize, 1) << 32, read.size);
    try std.testing.expectEqual(@as(u64, 0x123487654321), read.destination.?);
    try std.testing.expectEqual(@as(u64, 0x56abc82345), read.offset.?);
    for (0..@sizeOf(@TypeOf(words))) |length|
        try std.testing.expectError(error.InvalidPacket, decode(std.mem.asBytes(&words)[0..length]));
}

test "native APR rejects unknown opcodes and invalid paired counters" {
    const unknown = [_]u32{0xdeadbeef};
    try std.testing.expectError(error.InvalidPacket, decode(std.mem.asBytes(&unknown)));
    const odd_pair = [_]u32{ 0x01000106, 1 << 20 };
    try std.testing.expectError(error.InvalidPacket, decode(std.mem.asBytes(&odd_pair)));
    const bad_compare = [_]u32{0xe002};
    try std.testing.expectError(error.InvalidPacket, decode(std.mem.asBytes(&bad_compare)));
}
