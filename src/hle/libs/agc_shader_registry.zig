// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Process-local association between relocated AGC shader headers and the GPU
//! program addresses later published through PM4.

const std = @import("std");

const RegistryLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *RegistryLock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *RegistryLock) void {
        self.inner.unlock();
    }
};

var registry_lock = RegistryLock{};
var entries: std.AutoHashMapUnmanaged(u64, u64) = .empty;

/// Adds or replaces one address mapping. Scene shader archives exceed 8192
/// programs before loading finishes, so grow host storage under the registry
/// lock instead of silently dropping metadata at a fixed capacity.
pub fn record(program_address: u64, header_address: u64) bool {
    if (program_address == 0 or header_address == 0) return false;
    registry_lock.lock();
    defer registry_lock.unlock();

    entries.put(std.heap.page_allocator, program_address, header_address) catch return false;
    return true;
}

pub fn find(program_address: u64) ?u64 {
    if (program_address == 0) return null;
    registry_lock.lock();
    defer registry_lock.unlock();

    if (entries.get(program_address)) |header| return header;

    // Fuzzy: PM4 sometimes publishes an entry point a few dwords past the
    // code address recorded at create (s_inst_prefetch / prolog). Accept a
    // registered code base that lies at or just below the program address.
    var best_header: ?u64 = null;
    var best_delta: u64 = std.math.maxInt(u64);
    var iterator = entries.iterator();
    while (iterator.next()) |entry| {
        if (entry.key_ptr.* > program_address) continue;
        const delta = program_address - entry.key_ptr.*;
        // Allow a small prolog offset from the recorded code base only.
        if (delta < 0x1000 and delta < best_delta) {
            best_delta = delta;
            best_header = entry.value_ptr.*;
        }
    }
    return best_header;
}

pub fn count() usize {
    registry_lock.lock();
    defer registry_lock.unlock();
    return entries.count();
}

/// Debug: print a few registered program→header pairs near `program_address`.
pub fn debugNearby(program_address: u64) void {
    registry_lock.lock();
    defer registry_lock.unlock();
    var shown: usize = 0;
    var iterator = entries.iterator();
    while (iterator.next()) |entry| {
        const delta: i64 = @as(i64, @bitCast(entry.key_ptr.*)) -% @as(i64, @bitCast(program_address));
        if (@abs(delta) < 0x100_000 and shown < 8) {
            std.debug.print(
                "[shader-registry] near prog=0x{x}: entry=0x{x} header=0x{x} delta={d}\n",
                .{ program_address, entry.key_ptr.*, entry.value_ptr.*, delta },
            );
            shown += 1;
        }
    }
    std.debug.print("[shader-registry] total entries={d} looking for 0x{x}\n", .{ entries.count(), program_address });
}

pub fn reset() void {
    registry_lock.lock();
    defer registry_lock.unlock();
    entries.deinit(std.heap.page_allocator);
    entries = .empty;
}

test "shader registry replaces existing mappings and handles collisions" {
    reset();
    defer reset();
    const first: u64 = 0x1234_5000;
    const collision = first + 8192 * 0x100;
    try std.testing.expect(record(first, 0x4000));
    try std.testing.expect(record(collision, 0x5000));
    try std.testing.expectEqual(@as(?u64, 0x4000), find(first));
    try std.testing.expectEqual(@as(?u64, 0x5000), find(collision));
    try std.testing.expect(record(first, 0x6000));
    try std.testing.expectEqual(@as(?u64, 0x6000), find(first));
    try std.testing.expect(find(0xdead_be00) == null);
}

test "shader registry retains scene headers beyond the old fixed capacity" {
    reset();
    defer reset();
    const total = 12000;
    for (0..total) |index| {
        try std.testing.expect(record(0x8000_0000_00 + index * 0x1000, 0x1000_0000 + index * 128));
    }
    try std.testing.expectEqual(@as(usize, total), count());
    for (0..total) |index| {
        try std.testing.expectEqual(@as(?u64, 0x1000_0000 + index * 128), find(0x8000_0000_00 + index * 0x1000));
    }
    try std.testing.expectEqual(@as(?u64, 0x1000_0000 + (total - 1) * 128), find(0x8000_0000_00 + (total - 1) * 0x1000 + 4));
    reset();
    try std.testing.expectEqual(@as(usize, 0), count());
}
