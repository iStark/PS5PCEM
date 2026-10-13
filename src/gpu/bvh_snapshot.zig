// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Checked PSR version-9 acceleration-structure snapshot metadata.
//! Keep guest ranges explicit; recognizing a header does not prove that its
//! referenced allocation is readable or coherent. The caller checks both.

const std = @import("std");

pub const Header = struct {
    size: u32,
    instance_offset: u32,
    instance_count: u32,
};

pub fn decode(bytes: *const [256]u8) ?Header {
    if (std.mem.readInt(u64, bytes[0..8], .little) != 0x4c48_5642_5f52_5350 or
        std.mem.readInt(u32, bytes[252..256], .little) != 9) return null;
    const size = std.mem.readInt(u64, bytes[16..24], .little);
    if (size < 256 or size > 8 * 1024 * 1024) return null;
    const table = std.mem.readInt(u64, bytes[48..56], .little);
    const count = std.mem.readInt(u32, bytes[112..116], .little);
    // Version-9 TLAS ends in 128-byte instance records. BLAS has a different
    // tail and is staged whole without interpreting it as instance pointers.
    const instances = count != 0 and table >= 256 and table & 63 == 0 and
        table <= size and @as(u64, count) * 128 == size - table;
    return .{ .size = @intCast(size), .instance_offset = if (instances) @intCast(table) else 0, .instance_count = if (instances) count else 0 };
}

pub fn instanceAddress(bytes: *const [128]u8) u64 {
    // Shader traversal strips the high flag bits and shifts the stored
    // eight-byte address units before dereferencing the BLAS header.
    return (std.mem.readInt(u64, bytes[48..56], .little) << 3) & 0x0000_ffff_ffff_ffff;
}

test "version 9 distinguishes bounded instance tables from primitive tails" {
    var bytes: [256]u8 = @splat(0);
    std.mem.writeInt(u64, bytes[0..8], 0x4c48_5642_5f52_5350, .little);
    std.mem.writeInt(u32, bytes[252..256], 9, .little);
    std.mem.writeInt(u64, bytes[16..24], 0x71c40, .little);
    std.mem.writeInt(u64, bytes[48..56], 0x1fd40, .little);
    std.mem.writeInt(u32, bytes[112..116], 2622, .little);
    try std.testing.expectEqual(Header{ .size = 0x71c40, .instance_offset = 0x1fd40, .instance_count = 2622 }, decode(&bytes).?);
    std.mem.writeInt(u64, bytes[16..24], 752, .little);
    std.mem.writeInt(u64, bytes[48..56], 736, .little);
    std.mem.writeInt(u32, bytes[112..116], 4, .little);
    try std.testing.expectEqual(Header{ .size = 752, .instance_offset = 0, .instance_count = 0 }, decode(&bytes).?);
    std.mem.writeInt(u64, bytes[48..56], std.math.maxInt(u64), .little);
    try std.testing.expectEqual(@as(u32, 0), decode(&bytes).?.instance_count);
    std.mem.writeInt(u64, bytes[16..24], 0x100000100, .little);
    try std.testing.expect(decode(&bytes) == null);
    std.mem.writeInt(u64, bytes[16..24], 128, .little);
    try std.testing.expect(decode(&bytes) == null);
    std.mem.writeInt(u64, bytes[16..24], 752, .little);
    bytes[252] = 10;
    try std.testing.expect(decode(&bytes) == null);
}

test "instance pointers discard packed flags without losing address carry" {
    var bytes: [128]u8 = @splat(0);
    std.mem.writeInt(u64, bytes[48..56], 0x1040_0000_8036_a900, .little);
    try std.testing.expectEqual(@as(u64, 0x401b54800), instanceAddress(&bytes));
    std.mem.writeInt(u64, bytes[48..56], 0x0000_0000_ffff_ffe0, .little);
    try std.testing.expectEqual(@as(u64, 0x7ffffff00), instanceAddress(&bytes));
}
