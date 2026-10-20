// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz
//
// Native AMM packet layout cross-checked against drakmor/ampr_emu,
// src/ampr_emu_command_packing.cpp (GPL-3.0-or-later). These are packed
// kernel commands, not the host-side APR command-buffer bookkeeping.

const std = @import("std");

pub const Kind = enum { map, direct, unmap, remap, alias, protect };
pub const Command = struct {
    kind: Kind,
    address: u64,
    size: u64,
    source: u64 = 0,
    memory_type: ?u5 = null,
    protection: u15 = 0,
    mask: u15 = 0,
    gpu_mask: ?u8 = null,
    prt: bool = false,
};
pub const Error = error{InvalidPacket};
pub const page_size: u64 = 0x4000;
pub const protection_mask: u64 = 0x3f3;

pub fn validRange(address: u64, size: u64) bool {
    return address != 0 and size != 0 and (address | size) & (page_size - 1) == 0 and
        address < (1 << 48) and size <= (1 << 48) - address;
}

fn valid(command: Command) bool {
    if (!validRange(command.address, command.size) or command.protection & ~protection_mask != 0 or
        command.mask & ~protection_mask != 0) return false;
    const max_size: u64 = if (command.kind == .map or command.kind == .protect) 0x1ffffffc << 12 else 0xfffffffc << 9;
    if (command.size > max_size) return false;
    switch (command.kind) {
        .direct => if (command.source >= (1 << 40) or command.source & (page_size - 1) != 0) return false,
        .remap, .alias => if (!validRange(command.source, command.size)) return false,
        else => {},
    }
    return true;
}

pub const Packet = struct {
    words: [5]u32 = @splat(0),
    count: usize,
};

pub fn encode(command: Command) Error!Packet {
    if (!valid(command)) return error.InvalidPacket;
    var packet = Packet{ .count = switch (command.kind) {
        .map, .unmap => 3,
        else => 4,
    } };
    const opcode: u32 = switch (command.kind) {
        .map => 0x221,
        .direct => 0x325,
        .unmap => 0x222,
        .remap => 0x323,
        .alias => 0x324,
        .protect => 0x326,
    };
    packet.words[0] = opcode | (@as(u32, command.protection) << 12) |
        (@as(u32, command.memory_type orelse 0) << 27);
    packet.words[1] = @truncate(command.address >> 14);
    const high: u32 = @intCast(command.address >> 46);
    switch (command.kind) {
        .map => {
            packet.words[0] |= @as(u32, @intFromBool(command.prt)) << 15;
            packet.words[2] = @as(u32, @intCast(command.size >> 12)) | high;
        },
        .direct => {
            packet.words[2] = @as(u32, @intCast(command.size >> 9)) | high;
            packet.words[3] = @intCast(command.source >> 14);
        },
        .unmap => packet.words[2] = @as(u32, @intCast(command.size >> 9)) | high,
        .remap, .alias => {
            packet.words[2] = @truncate(command.source >> 14);
            packet.words[3] = @as(u32, @intCast(command.size >> 9)) | high |
                (@as(u32, @intCast(command.source >> 46)) << 2);
        },
        .protect => {
            packet.words[2] = @as(u32, @intCast(command.size >> 12)) | high |
                (@as(u32, @intFromBool(command.memory_type != null)) << 30);
            packet.words[3] = command.mask;
        },
    }
    if (command.gpu_mask) |value| {
        if (command.kind == .unmap) return error.InvalidPacket;
        packet.words[0] += 0x100;
        packet.words[packet.count] = value;
        packet.count += 1;
    }
    return packet;
}

pub const Decoded = struct { command: Command, bytes: usize };

pub fn decode(bytes: []const u8) Error!Decoded {
    if (bytes.len < 4) return error.InvalidPacket;
    const header = std.mem.readInt(u32, bytes[0..4], .little);
    const opcode = header & 0xfff;
    const has_gpu = switch (opcode) {
        0x321, 0x425, 0x423, 0x424, 0x426 => true,
        else => false,
    };
    const kind: Kind = switch (opcode) {
        0x221, 0x321 => .map,
        0x325, 0x425 => .direct,
        0x222 => .unmap,
        0x323, 0x423 => .remap,
        0x324, 0x424 => .alias,
        0x326, 0x426 => .protect,
        else => return error.InvalidPacket,
    };
    const count: usize = @as(usize, if (kind == .map or kind == .unmap) 3 else 4) + @intFromBool(has_gpu);
    if (bytes.len < count * 4) return error.InvalidPacket;
    var words: [5]u32 = @splat(0);
    for (0..count) |index| words[index] = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    var command = Command{
        .kind = kind,
        .address = @as(u64, words[1]) << 14,
        .size = 0,
        .protection = @truncate(header >> 12),
        .gpu_mask = if (has_gpu) @intCast(words[count - 1] & 0xff) else null,
    };
    switch (kind) {
        .map, .protect => {
            command.address |= @as(u64, words[2] & 3) << 46;
            command.size = @as(u64, words[2] & 0x1ffffffc) << 12;
            if (kind == .map) {
                command.prt = header & 0x8000 != 0;
                command.protection &= ~@as(u15, 8);
                command.memory_type = @truncate(header >> 27);
            } else {
                if (words[2] & 0x40000000 != 0 or header >> 27 != 0) command.memory_type = @truncate(header >> 27);
                command.mask = @truncate(words[3]);
            }
        },
        .direct, .unmap => {
            command.address |= @as(u64, words[2] & 3) << 46;
            command.size = @as(u64, words[2] & 0xfffffffc) << 9;
            if (kind == .direct) {
                command.source = @as(u64, words[3] & 0x3ffffff) << 14;
                command.memory_type = @truncate(header >> 27);
            }
        },
        .remap, .alias => {
            command.address |= @as(u64, words[3] & 3) << 46;
            command.source = (@as(u64, words[2]) << 14) | (@as(u64, (words[3] >> 2) & 3) << 46);
            command.size = @as(u64, words[3] & 0xfffffff0) << 9;
        },
    }
    if (!valid(command)) return error.InvalidPacket;
    return .{ .command = command, .bytes = count * 4 };
}

test "AMM native packets match fixed byte layouts and retain high addresses" {
    const direct = try encode(.{ .kind = .direct, .address = 0x1000000000, .size = 0x4000, .source = 0x8000, .memory_type = 3, .protection = 0x33 });
    try std.testing.expectEqualSlices(u32, &.{ 0x18033325, 0x400000, 0x20, 2 }, direct.words[0..direct.count]);
    const protect = try encode(.{ .kind = .protect, .address = 0x1000000000, .size = 0x4000, .memory_type = 0, .protection = 1, .mask = 3, .gpu_mask = 7 });
    try std.testing.expectEqualSlices(u32, &.{ 0x1426, 0x400000, 0x40000004, 3, 7 }, protect.words[0..protect.count]);
    const commands = [_]Command{
        .{ .kind = .map, .address = 0xc00000004000, .size = 0x8000, .memory_type = 10, .protection = 0x303, .gpu_mask = 2 },
        .{ .kind = .remap, .address = 0x800000004000, .source = 0xc00000008000, .size = 0x4000, .protection = 3 },
        .{ .kind = .alias, .address = 0x1000000000, .source = 0x1000010000, .size = 0x4000, .protection = 3, .gpu_mask = 255 },
        .{ .kind = .unmap, .address = 0x1000000000, .size = 0x4000 },
    };
    for (commands) |command| {
        const packet = try encode(command);
        const bytes = std.mem.sliceAsBytes(packet.words[0..packet.count]);
        const parsed = try decode(bytes);
        try std.testing.expectEqualDeep(command, parsed.command);
        try std.testing.expectEqual(bytes.len, parsed.bytes);
        try std.testing.expectError(error.InvalidPacket, decode(bytes[0 .. bytes.len - 1]));
    }
    try std.testing.expectError(error.InvalidPacket, encode(.{ .kind = .map, .address = 1, .size = page_size }));
    try std.testing.expectError(error.InvalidPacket, decode(&.{ 0xff, 0xff, 0xff, 0xff }));
}
