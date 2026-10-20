// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Compare a known repeated little-endian word without loading a second,
//! equally large staging buffer. Every destination byte is still checked.
const std = @import("std");

pub fn matches32(bytes: []const u8, value: u32) bool {
    if (bytes.len & 3 != 0) return false;
    const Words = @Vector(32, u32);
    const wanted: Words = @splat(std.mem.nativeToLittle(u32, value));
    var cursor: usize = 0;
    while (bytes.len - cursor >= 128) : (cursor += 128) {
        const actual: Words = @bitCast(bytes[cursor..][0..128].*);
        if (@reduce(.Or, actual != wanted)) return false;
    }
    while (cursor < bytes.len) : (cursor += 4) {
        if (std.mem.readInt(u32, bytes[cursor..][0..4], .little) != value) return false;
    }
    return true;
}

test "uniform word comparison checks unaligned slices vector boundaries and tails" {
    var storage: [17 + 129 * 4 + 1]u8 = undefined;
    for ([_]u32{ 0, 0xffffffff, 0x12345678, 0x000000ff }) |value| {
        for (0..17) |offset| {
            for ([_]usize{ 0, 1, 2, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65, 127, 128, 129 }) |words| {
                @memset(&storage, 0x5d);
                const bytes = storage[offset..][0 .. words * 4];
                for (0..words) |word| std.mem.writeInt(u32, bytes[word * 4 ..][0..4], value, .little);
                try std.testing.expect(matches32(bytes, value));
                // Probe each byte, not just word-aligned differences.
                for (bytes) |*byte| {
                    byte.* ^= 0x80;
                    try std.testing.expect(!matches32(bytes, value));
                    byte.* ^= 0x80;
                }
                try std.testing.expect(std.mem.allEqual(u8, storage[0..offset], 0x5d));
                try std.testing.expect(std.mem.allEqual(u8, storage[offset + bytes.len ..], 0x5d));
            }
        }
    }
    try std.testing.expect(!matches32(&.{0}, 0));
    try std.testing.expect(!matches32(&.{ 0, 0, 0 }, 0));
}
