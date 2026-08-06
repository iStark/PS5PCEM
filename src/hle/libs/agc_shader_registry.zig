// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Process-local association between relocated AGC shader headers and the GPU
//! program addresses later published through PM4.

const std = @import("std");

const capacity: usize = 8192;

const Entry = struct {
    program_address: u64 = 0,
    header_address: u64 = 0,
};

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
var entries = [_]Entry{.{}} ** capacity;

/// Adds or replaces one address mapping. A fixed open-addressed table keeps
/// shader creation independent of host allocator state.
pub fn record(program_address: u64, header_address: u64) bool {
    if (program_address == 0 or header_address == 0) return false;
    registry_lock.lock();
    defer registry_lock.unlock();

    var index = home(program_address);
    for (0..capacity) |_| {
        const entry = &entries[index];
        if (entry.program_address == 0 or entry.program_address == program_address) {
            entry.* = .{
                .program_address = program_address,
                .header_address = header_address,
            };
            return true;
        }
        index = (index + 1) & (capacity - 1);
    }
    return false;
}

pub fn find(program_address: u64) ?u64 {
    if (program_address == 0) return null;
    registry_lock.lock();
    defer registry_lock.unlock();

    var index = home(program_address);
    for (0..capacity) |_| {
        const entry = entries[index];
        if (entry.program_address == program_address) return entry.header_address;
        if (entry.program_address == 0) break;
        index = (index + 1) & (capacity - 1);
    }

    // Fuzzy: PM4 sometimes publishes an entry point a few dwords past the
    // code address recorded at create (s_inst_prefetch / prolog). Accept a
    // registered code base that lies at or just below the program address.
    var best_header: ?u64 = null;
    var best_delta: u64 = std.math.maxInt(u64);
    for (entries) |entry| {
        if (entry.program_address == 0) continue;
        if (entry.program_address > program_address) continue;
        const delta = program_address - entry.program_address;
        // Allow a small prolog offset from the recorded code base only.
        if (delta < 0x1000 and delta < best_delta) {
            best_delta = delta;
            best_header = entry.header_address;
        }
    }
    return best_header;
}

pub fn count() usize {
    registry_lock.lock();
    defer registry_lock.unlock();
    var n: usize = 0;
    for (entries) |entry| {
        if (entry.program_address != 0) n += 1;
    }
    return n;
}

/// Debug: print a few registered program→header pairs near `program_address`.
pub fn debugNearby(program_address: u64) void {
    registry_lock.lock();
    defer registry_lock.unlock();
    var n: usize = 0;
    var shown: usize = 0;
    for (entries) |entry| {
        if (entry.program_address == 0) continue;
        n += 1;
        const delta: i64 = @as(i64, @bitCast(entry.program_address)) -% @as(i64, @bitCast(program_address));
        if (@abs(delta) < 0x100_000 and shown < 8) {
            std.debug.print(
                "[shader-registry] near prog=0x{x}: entry=0x{x} header=0x{x} delta={d}\n",
                .{ program_address, entry.program_address, entry.header_address, delta },
            );
            shown += 1;
        }
    }
    std.debug.print("[shader-registry] total entries={d} looking for 0x{x}\n", .{ n, program_address });
}

pub fn reset() void {
    registry_lock.lock();
    defer registry_lock.unlock();
    entries = [_]Entry{.{}} ** capacity;
}

fn home(address: u64) usize {
    var value = address >> 8;
    value ^= value >> 17;
    value *%= 0x9e37_79b9_7f4a_7c15;
    return @intCast(value & (capacity - 1));
}

test "shader registry replaces existing mappings and handles collisions" {
    reset();
    defer reset();
    const first: u64 = 0x1234_5000;
    const collision = first + capacity * 0x100;
    try std.testing.expect(record(first, 0x4000));
    try std.testing.expect(record(collision, 0x5000));
    try std.testing.expectEqual(@as(?u64, 0x4000), find(first));
    try std.testing.expectEqual(@as(?u64, 0x5000), find(collision));
    try std.testing.expect(record(first, 0x6000));
    try std.testing.expectEqual(@as(?u64, 0x6000), find(first));
    try std.testing.expect(find(0xdead_be00) == null);
}
