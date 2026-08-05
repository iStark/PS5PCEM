// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Process-wide state of the guest graphics kernel device.
//!
//! The shipped AGC driver owns its queue allocations and passes their exact
//! guest addresses to `/dev/gc`. This layer only retains that registration and
//! validates queue identity; it does not invent kernel handles or host GPU
//! addresses. Submission can therefore resolve a later queue ID back to the
//! memory the driver itself established.

const std = @import("std");

pub const aperture_address: u64 = 0x0f_e020_0000;
pub const maximum_queues: usize = 64;

pub const QueueRegistration = extern struct {
    engine: u32,
    family: u32,
    index: u32,
    identifier: u32,
    queue_address: u64,
    control_address: u64,
    aperture_address: u64,
    aperture_slots: u64,
    completion_address: u64,
    completion_size: u64,
};

pub const TfRingRequest = extern struct {
    base_address: u64,
    size: u32,
    reserved: u32,
};

pub const HsOffchipRequest = extern struct {
    value1: u16,
    value0: u16,
};

comptime {
    if (@sizeOf(QueueRegistration) != 64) @compileError("unexpected /dev/gc queue registration layout");
    if (@sizeOf(TfRingRequest) != 16) @compileError("unexpected /dev/gc TF ring layout");
    if (@sizeOf(HsOffchipRequest) != 4) @compileError("unexpected /dev/gc HS offchip layout");
}

pub const Error = error{
    InvalidEngine,
    InvalidFamily,
    InvalidIndex,
    InvalidIdentifier,
    InvalidAddress,
    InvalidAperture,
    DuplicateIdentifier,
    DuplicateQueue,
    QueueTableFull,
    InvalidTfRing,
};

pub const Status = struct {
    trap_resources_installed: bool,
    queue_count: u32,
    compute_mode: u32,
    graphics_mode: u32,
    suspend_query_count: u64,
    tf_ring_base: u64,
    tf_ring_size: u32,
    hs_offchip_value0: u16,
    hs_offchip_value1: u16,
};

const QueueSlot = struct {
    active: bool = false,
    registration: QueueRegistration = undefined,
};

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

var lock = Lock{};
var trap_resources_installed = false;
var queues: [maximum_queues]QueueSlot = [_]QueueSlot{.{}} ** maximum_queues;
var queue_count: u32 = 0;
var compute_mode: u32 = 0;
var graphics_mode: u32 = 0;
var suspend_query_count: u64 = 0;
var tf_ring_base: u64 = 0;
var tf_ring_size: u32 = 0;
var hs_offchip_value0: u16 = 0;
var hs_offchip_value1: u16 = 0;

pub fn reset() void {
    lock.lock();
    defer lock.unlock();
    trap_resources_installed = false;
    queues = [_]QueueSlot{.{}} ** maximum_queues;
    queue_count = 0;
    compute_mode = 0;
    graphics_mode = 0;
    suspend_query_count = 0;
    tf_ring_base = 0;
    tf_ring_size = 0;
    hs_offchip_value0 = 0;
    hs_offchip_value1 = 0;
}

pub fn installTrapResources() void {
    lock.lock();
    defer lock.unlock();
    trap_resources_installed = true;
}

pub fn registerQueue(registration: QueueRegistration) Error!void {
    try validateRegistration(registration);
    lock.lock();
    defer lock.unlock();

    var free_slot: ?*QueueSlot = null;
    for (&queues) |*slot| {
        if (!slot.active) {
            if (free_slot == null) free_slot = slot;
            continue;
        }
        const existing = slot.registration;
        if (existing.identifier == registration.identifier) return error.DuplicateIdentifier;
        if (existing.engine == registration.engine and
            existing.family == registration.family and
            existing.index == registration.index)
        {
            return error.DuplicateQueue;
        }
    }
    const slot = free_slot orelse return error.QueueTableFull;
    slot.* = .{ .active = true, .registration = registration };
    queue_count += 1;
}

pub fn findQueue(identifier: u32) ?QueueRegistration {
    lock.lock();
    defer lock.unlock();
    for (queues) |slot| {
        if (slot.active and slot.registration.identifier == identifier) return slot.registration;
    }
    return null;
}

pub fn setComputeMode(value: u32) void {
    lock.lock();
    defer lock.unlock();
    compute_mode = value;
}

pub fn setGraphicsMode(value: u32) void {
    lock.lock();
    defer lock.unlock();
    graphics_mode = value;
}

pub fn status() Status {
    lock.lock();
    defer lock.unlock();
    return .{
        .trap_resources_installed = trap_resources_installed,
        .queue_count = queue_count,
        .compute_mode = compute_mode,
        .graphics_mode = graphics_mode,
        .suspend_query_count = suspend_query_count,
        .tf_ring_base = tf_ring_base,
        .tf_ring_size = tf_ring_size,
        .hs_offchip_value0 = hs_offchip_value0,
        .hs_offchip_value1 = hs_offchip_value1,
    };
}

pub fn recordSuspendQuery() void {
    lock.lock();
    defer lock.unlock();
    suspend_query_count +%= 1;
}

pub fn setTfRing(request: TfRingRequest) Error!void {
    if ((request.base_address & 0xff) != 0 or (request.size & 3) != 0 or request.reserved != 0) {
        return error.InvalidTfRing;
    }
    lock.lock();
    defer lock.unlock();
    tf_ring_base = request.base_address;
    tf_ring_size = request.size;
}

pub fn setHsOffchipParam(request: HsOffchipRequest) void {
    lock.lock();
    defer lock.unlock();
    hs_offchip_value0 = request.value0;
    hs_offchip_value1 = request.value1;
}

fn validateRegistration(registration: QueueRegistration) Error!void {
    if (registration.engine != 1 and registration.engine != 2) return error.InvalidEngine;
    const family_count: u32 = if (registration.engine == 1) 4 else 3;
    if (registration.family >= family_count) return error.InvalidFamily;
    if (registration.index >= 8) return error.InvalidIndex;
    if (registration.identifier == 0 or registration.identifier > 56) return error.InvalidIdentifier;
    if (registration.queue_address == 0 or registration.queue_address & 0x3fff != 0 or
        registration.control_address == 0 or registration.control_address & 0x3fff != 0 or
        registration.completion_address == 0 or registration.completion_address & 0xfff != 0 or
        registration.completion_size != 0x1000)
    {
        return error.InvalidAddress;
    }
    if (registration.aperture_address != aperture_address or registration.aperture_slots != 12) {
        return error.InvalidAperture;
    }
}

test "the shipped queue matrix registers without invented handles" {
    reset();
    defer reset();
    var identifier: u32 = 1;
    for (1..3) |engine_value| {
        const engine: u32 = @intCast(engine_value);
        const family_count: u32 = if (engine == 1) 4 else 3;
        for (0..family_count) |family| {
            for (0..8) |index| {
                try registerQueue(.{
                    .engine = engine,
                    .family = @intCast(family),
                    .index = @intCast(index),
                    .identifier = identifier,
                    .queue_address = 0x7000_1000_0000 + @as(u64, identifier) * 0x8000,
                    .control_address = 0x7000_1000_4000 + @as(u64, identifier) * 0x8000,
                    .aperture_address = aperture_address,
                    .aperture_slots = 12,
                    .completion_address = 0x7000_2000_0000 + @as(u64, identifier) * 0x1000,
                    .completion_size = 0x1000,
                });
                identifier += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 56), status().queue_count);
    try std.testing.expectEqual(@as(u32, 56), findQueue(56).?.identifier);
}

test "invalid and duplicate queue identities are rejected" {
    reset();
    defer reset();
    const registration = QueueRegistration{
        .engine = 1,
        .family = 0,
        .index = 0,
        .identifier = 1,
        .queue_address = 0x7000_1000_8000,
        .control_address = 0x7000_1000_c000,
        .aperture_address = aperture_address,
        .aperture_slots = 12,
        .completion_address = 0x7000_2000_1000,
        .completion_size = 0x1000,
    };
    try registerQueue(registration);
    try std.testing.expectError(error.DuplicateIdentifier, registerQueue(registration));
    var invalid = registration;
    invalid.identifier = 2;
    invalid.index = 8;
    try std.testing.expectError(error.InvalidIndex, registerQueue(invalid));
}

test "tessellation ring and HS offchip parameters retain driver ordering" {
    reset();
    defer reset();
    try setTfRing(.{
        .base_address = 0x0000_0002_0312_6c00,
        .size = 0x0003_fff8,
        .reserved = 0,
    });
    setHsOffchipParam(.{ .value1 = 0x24, .value0 = 0x10 });
    const current = status();
    try std.testing.expectEqual(@as(u64, 0x0000_0002_0312_6c00), current.tf_ring_base);
    try std.testing.expectEqual(@as(u32, 0x0003_fff8), current.tf_ring_size);
    try std.testing.expectEqual(@as(u16, 0x10), current.hs_offchip_value0);
    try std.testing.expectEqual(@as(u16, 0x24), current.hs_offchip_value1);

    try std.testing.expectError(error.InvalidTfRing, setTfRing(.{
        .base_address = 0x1234,
        .size = 4,
        .reserved = 0,
    }));
}
