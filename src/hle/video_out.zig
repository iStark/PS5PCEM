// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Process-wide VideoOut buffer registry shared by the firmware entry points
//! and the GPU submission bridge.
//!
//! The guest registers display allocations through libSceVideoOut, then names
//! one of those slots in either a CPU flip or a PM4 `SetFlip`. Keeping the
//! registry API-neutral lets HLE validate that relationship without depending
//! on Vulkan or a host window system.

const std = @import("std");
const gpu = @import("gpu");

pub const maximum_buffers: usize = 16;
pub const maximum_attribute_groups: usize = 4;
pub const primary_handle: i32 = 1;

pub const BufferAttribute2 = extern struct {
    reserved0: u32 = 0,
    tiling_mode: u32 = 0,
    aspect_ratio: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch_in_pixels: u32 = 0,
    option: u64 = 0,
    pixel_format: u64 = 0,
    dcc_clear_color: u64 = 0,
    dcc_control: u32 = 0,
    padding: u32 = 0,
    reserved1: [3]u64 = .{ 0, 0, 0 },
};

pub const Buffer = extern struct {
    data: ?*const anyopaque,
    metadata: ?*const anyopaque,
    reserved: [2]?*const anyopaque,
};

pub const Registration = struct {
    index: i32,
    set_index: i32,
    data_address: u64,
    metadata_address: u64,
    category: i32,
    attribute: BufferAttribute2,
};

pub const FlipStatus = struct {
    count: u64 = 0,
    argument: i64 = 0,
    current_buffer: i32 = 0,
};

pub const RegisterError = error{
    InvalidValue,
    InvalidAddress,
    InvalidOption,
    InvalidCategory,
    InvalidIndex,
    SlotOccupied,
};

const AttributeGroup = struct {
    occupied: bool = false,
    category: i32 = 0,
    attribute: BufferAttribute2 = .{},
};

const BufferSlot = struct {
    occupied: bool = false,
    set_index: i32 = -1,
    data_address: u64 = 0,
    metadata_address: u64 = 0,
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
var opened = false;
var groups: [maximum_attribute_groups]AttributeGroup = [_]AttributeGroup{.{}} ** maximum_attribute_groups;
var buffers: [maximum_buffers]BufferSlot = [_]BufferSlot{.{}} ** maximum_buffers;
var buffer_labels: [maximum_buffers]u64 align(8) = [_]u64{0} ** maximum_buffers;
var flip_status = FlipStatus{};
var previous_buffer: i32 = -1;

pub fn reset() void {
    lock.lock();
    defer lock.unlock();
    opened = false;
    groups = [_]AttributeGroup{.{}} ** maximum_attribute_groups;
    buffers = [_]BufferSlot{.{}} ** maximum_buffers;
    buffer_labels = [_]u64{0} ** maximum_buffers;
    flip_status = .{};
    previous_buffer = -1;
}

pub fn open(index: i32) bool {
    if (index != 0) return false;
    lock.lock();
    defer lock.unlock();
    if (opened) return false;
    opened = true;
    return true;
}

pub fn close(handle: i32) bool {
    lock.lock();
    defer lock.unlock();
    if (handle != primary_handle or !opened) return false;
    opened = false;
    groups = [_]AttributeGroup{.{}} ** maximum_attribute_groups;
    buffers = [_]BufferSlot{.{}} ** maximum_buffers;
    buffer_labels = [_]u64{0} ** maximum_buffers;
    previous_buffer = -1;
    return true;
}

pub fn validHandle(handle: i32) bool {
    lock.lock();
    defer lock.unlock();
    return handle == primary_handle and opened;
}

pub fn registerBuffers(
    set_index: i32,
    buffer_index_start: i32,
    input: []const Buffer,
    attribute: BufferAttribute2,
    category: i32,
) RegisterError!void {
    if (set_index < 0 or set_index >= maximum_attribute_groups or
        buffer_index_start < 0 or buffer_index_start >= maximum_buffers or
        input.len == 0 or input.len > maximum_buffers or
        @as(usize, @intCast(buffer_index_start)) + input.len > maximum_buffers)
    {
        return error.InvalidValue;
    }
    if (category != 0 and category != 1) return error.InvalidCategory;
    for (input) |entry| {
        if (entry.data == null) return error.InvalidAddress;
    }

    lock.lock();
    defer lock.unlock();
    const group_index: usize = @intCast(set_index);
    if (groups[group_index].occupied) return error.InvalidIndex;
    const first: usize = @intCast(buffer_index_start);
    for (buffers[first .. first + input.len]) |slot| {
        if (slot.occupied) return error.SlotOccupied;
    }

    groups[group_index] = .{
        .occupied = true,
        .category = category,
        .attribute = attribute,
    };
    for (input, 0..) |entry, index| {
        const slot_index = first + index;
        buffers[slot_index] = .{
            .occupied = true,
            .set_index = set_index,
            .data_address = @intFromPtr(entry.data.?),
            .metadata_address = if (entry.metadata) |address| @intFromPtr(address) else 0,
        };
        buffer_labels[slot_index] = 0;
    }
}

pub fn changeAttribute(set_index: i32, attribute: BufferAttribute2) RegisterError!void {
    if (set_index < 0 or set_index >= maximum_attribute_groups) return error.InvalidValue;
    lock.lock();
    defer lock.unlock();
    const index: usize = @intCast(set_index);
    if (!groups[index].occupied) return error.InvalidIndex;
    groups[index].attribute = attribute;
}

pub fn unregisterBuffers(set_index: i32) RegisterError!void {
    if (set_index < 0 or set_index >= maximum_attribute_groups) return error.InvalidValue;
    lock.lock();
    defer lock.unlock();
    const group_index: usize = @intCast(set_index);
    if (!groups[group_index].occupied) return error.InvalidIndex;
    groups[group_index] = .{};
    for (&buffers) |*slot| {
        if (slot.occupied and slot.set_index == set_index) {
            const slot_index = (@intFromPtr(slot) - @intFromPtr(&buffers)) / @sizeOf(BufferSlot);
            slot.* = .{};
            buffer_labels[slot_index] = 0;
        }
    }
}

/// Base of the 16 contiguous 64-bit labels used by AGC flip packets.
pub fn labelAddress(handle: i32) ?u64 {
    lock.lock();
    defer lock.unlock();
    if (handle != primary_handle or !opened) return null;
    return @intFromPtr(&buffer_labels);
}

/// Gives the command processor access to labels even though they live in HLE
/// state rather than in a title-owned virtual-memory allocation.
pub fn readLabelMemory(address: u64, output: []u8) bool {
    const range = labelByteRange(address, output.len) orelse return false;
    lock.lock();
    defer lock.unlock();
    const bytes = std.mem.asBytes(&buffer_labels);
    @memcpy(output, bytes[range.start..range.end]);
    return true;
}

pub fn writeLabelMemory(address: u64, input: []const u8) bool {
    const range = labelByteRange(address, input.len) orelse return false;
    lock.lock();
    defer lock.unlock();
    const bytes = std.mem.asBytes(&buffer_labels);
    @memcpy(bytes[range.start..range.end], input);
    return true;
}

fn labelByteRange(address: u64, length: usize) ?struct { start: usize, end: usize } {
    const base = @intFromPtr(&buffer_labels);
    if (address < base) return null;
    const offset = address - base;
    const byte_length = @sizeOf(@TypeOf(buffer_labels));
    if (offset > byte_length or length > byte_length - offset) return null;
    return .{ .start = @intCast(offset), .end = @intCast(offset + length) };
}

pub fn resolve(handle: u32, buffer_index: i32) ?Registration {
    lock.lock();
    defer lock.unlock();
    if (handle != primary_handle or !opened or buffer_index < 0 or buffer_index >= maximum_buffers) {
        return null;
    }
    const slot = buffers[@intCast(buffer_index)];
    if (!slot.occupied or slot.set_index < 0 or slot.set_index >= maximum_attribute_groups) return null;
    const group = groups[@intCast(slot.set_index)];
    if (!group.occupied) return null;
    return .{
        .index = buffer_index,
        .set_index = slot.set_index,
        .data_address = slot.data_address,
        .metadata_address = slot.metadata_address,
        .category = group.category,
        .attribute = group.attribute,
    };
}

pub fn resolveFlip(flip: gpu.state.Flip) ?Registration {
    return resolve(flip.video_out_handle, flip.display_buffer_index);
}

pub fn completeFlip(flip: gpu.state.Flip) bool {
    lock.lock();
    defer lock.unlock();
    if (flip.video_out_handle != primary_handle or !opened or
        flip.display_buffer_index < -1 or flip.display_buffer_index >= maximum_buffers or
        (flip.display_buffer_index >= 0 and !buffers[@intCast(flip.display_buffer_index)].occupied))
    {
        return false;
    }
    flip_status.count += 1;
    flip_status.argument = flip.argument;
    flip_status.current_buffer = flip.display_buffer_index;
    if (previous_buffer >= 0 and previous_buffer < maximum_buffers) {
        buffer_labels[@intCast(previous_buffer)] = 0;
    }
    previous_buffer = flip.display_buffer_index;
    return true;
}

pub fn status(handle: i32) ?FlipStatus {
    lock.lock();
    defer lock.unlock();
    if (handle != primary_handle or !opened) return null;
    return flip_status;
}

test "registered buffers resolve through a completed SetFlip" {
    reset();
    defer reset();
    try std.testing.expect(open(0));
    var pixels: [64]u8 = @splat(0);
    const input = [_]Buffer{.{ .data = &pixels, .metadata = null, .reserved = .{ null, null } }};
    try registerBuffers(0, 3, &input, .{ .width = 4, .height = 4, .pitch_in_pixels = 4 }, 0);

    const flip = gpu.state.Flip{
        .video_out_handle = primary_handle,
        .display_buffer_index = 3,
        .mode = 1,
        .argument = 77,
    };
    const registration = resolveFlip(flip).?;
    try std.testing.expectEqual(@as(u64, @intFromPtr(&pixels)), registration.data_address);
    try std.testing.expectEqual(@as(u32, 4), registration.attribute.width);
    try std.testing.expect(completeFlip(flip));
    try std.testing.expectEqual(@as(u64, 1), status(primary_handle).?.count);
    try std.testing.expectEqual(@as(i64, 77), status(primary_handle).?.argument);
}

test "attribute groups and buffer slots cannot overlap" {
    reset();
    defer reset();
    try std.testing.expect(open(0));
    var first: [4]u8 = @splat(0);
    var second: [4]u8 = @splat(0);
    const a = [_]Buffer{.{ .data = &first, .metadata = null, .reserved = .{ null, null } }};
    const b = [_]Buffer{.{ .data = &second, .metadata = null, .reserved = .{ null, null } }};
    try registerBuffers(1, 2, &a, .{ .width = 1, .height = 1 }, 0);
    try std.testing.expectError(error.InvalidIndex, registerBuffers(1, 4, &b, .{}, 0));
    try std.testing.expectError(error.SlotOccupied, registerBuffers(2, 2, &b, .{}, 0));
    try unregisterBuffers(1);
    try registerBuffers(2, 2, &b, .{}, 0);
}

test "VideoOut labels are contiguous and the previous flip is released" {
    reset();
    defer reset();
    try std.testing.expect(open(0));
    const address = labelAddress(primary_handle).?;
    var one: [8]u8 = undefined;
    std.mem.writeInt(u64, &one, 1, .little);
    try std.testing.expect(writeLabelMemory(address + 3 * @sizeOf(u64), &one));

    var pixels: [8]u8 = @splat(0);
    const input = [_]Buffer{
        .{ .data = &pixels, .metadata = null, .reserved = .{ null, null } },
        .{ .data = &pixels, .metadata = null, .reserved = .{ null, null } },
    };
    try registerBuffers(0, 3, &input, .{ .width = 1, .height = 1 }, 0);
    try std.testing.expect(completeFlip(.{
        .video_out_handle = 1,
        .display_buffer_index = 3,
        .mode = 1,
        .argument = 0,
    }));
    try std.testing.expect(writeLabelMemory(address + 3 * @sizeOf(u64), &one));
    try std.testing.expect(completeFlip(.{
        .video_out_handle = 1,
        .display_buffer_index = 4,
        .mode = 1,
        .argument = 0,
    }));
    var released: [8]u8 = undefined;
    try std.testing.expect(readLabelMemory(address + 3 * @sizeOf(u64), &released));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, &released, .little));
}
