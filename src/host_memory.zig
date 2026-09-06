// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Host C runtime memory primitives for the native Windows runner.
const std = @import("std");
const builtin = @import("builtin");

pub fn exportRuntime() void {
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64)
        @export(&fill, .{ .name = "memset", .linkage = .strong });
}

/// Zig's fallback memset emits byte stores in the current Windows build.
/// Resource staging and allocator poisoning repeatedly fill multi-MiB ranges.
/// REP STOSB is available on every x86-64 CPU and does not need AVX or ERMS;
/// modern CPUs accelerate long fills. Explicit assembly also prevents LLVM
/// from lowering this implementation to a recursive call to memset.
pub fn fill(destination: ?[*]u8, value: c_int, length: usize) callconv(.c) ?[*]u8 {
    if (length == 0) return destination;
    var cursor = destination.?;
    var remaining = length;
    asm volatile ("rep stosb"
        : [cursor] "={rdi}" (cursor),
          [remaining] "={rcx}" (remaining),
        : [destination] "0" (cursor),
          [length] "1" (remaining),
          [value] "{al}" (@as(u8, @truncate(@as(u32, @bitCast(value))))),
        : .{ .memory = true });
    return destination;
}

test "host fill preserves boundaries and the C memset contract" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try std.testing.expectEqual(@as(?[*]u8, null), fill(null, -1, 0));
    var bytes: [640]u8 = undefined;
    for ([_]c_int{ 0, 0x55, 0xaa, 255, -1, 0x1234, std.math.minInt(c_int) }) |value| {
        for (0..64) |offset| {
            for (0..513) |length| {
                @memset(&bytes, 0x7d);
                const destination = bytes[offset..].ptr;
                try std.testing.expectEqual(@as(?[*]u8, destination), fill(destination, value, length));
                try std.testing.expect(std.mem.allEqual(u8, bytes[0..offset], 0x7d));
                try std.testing.expect(std.mem.allEqual(u8, bytes[offset..][0..length], @truncate(@as(u32, @bitCast(value)))));
                try std.testing.expect(std.mem.allEqual(u8, bytes[offset + length ..], 0x7d));
            }
        }
    }
    const large = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024 + 2);
    defer std.testing.allocator.free(large);
    large[0] = 0x11;
    large[large.len - 1] = 0x22;
    _ = fill(large[1..].ptr, 0x1234, large.len - 2);
    try std.testing.expectEqual(@as(u8, 0x11), large[0]);
    try std.testing.expectEqual(@as(u8, 0x22), large[large.len - 1]);
    try std.testing.expect(std.mem.allEqual(u8, large[1 .. large.len - 1], 0x34));
}
