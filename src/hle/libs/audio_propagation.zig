// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! A no-propagation backend. Object lifetimes, caller-owned system memory and
//! attribute storage are implemented; acoustic rays, occlusion and reflections
//! are not, so every source reports no propagated paths and only its direct
//! sound is heard. Nonempty path input is rejected. ABI descriptors were
//! cross-checked against observed calls and AnyPS5.
//!
//! This is the default. ASTRO BOT asserts during audio initialisation when the
//! module refuses to report its memory needs, and the propagated reverb and
//! occlusion are a refinement of sound it otherwise plays. Refusing outright
//! (`configureNoPropagation(false)`, `PS5_AUDIO_PROPAGATION_UNSUPPORTED=1`)
//! remains available to tell the two apart when diagnosing a title.
const std = @import("std");
const memory = @import("memory");
const abi = @import("../abi.zig");
const access = @import("font.zig");
const Error = @import("../errno.zig").KernelError;
const invalid = @intFromEnum(Error.einval);
const unsupported = @intFromEnum(Error.enosys);
const no_memory = @intFromEnum(Error.enomem);
const allocator = std.heap.page_allocator;
const magic: u64 = 0x415050524f503031;
const Header = extern struct { magic: u64 = magic, reserved: u64 = 0 };
const Descriptor = extern struct { id: u32, reserved: u32 = 0, size: usize };
const SystemMemory = extern struct {
    descriptor: Descriptor = .{ .id = 0x010107d4, .size = 0x30 },
    cpu: usize = 0,
    cpu_size: usize = 0,
    gpu: usize = 0,
    gpu_size: usize = 0,
};
const Attribute = extern struct { id: u32, reserved: u32 = 0, value: usize, size: usize, reserved2: u64 = 0 };
const Portal = extern struct { descriptor: Descriptor, rows: [16]f32, rooms: [2]usize };
const RenderInfo = extern struct { descriptor: Descriptor, source: usize, output: usize, size: usize, format: u32, reserved: u32 };
const Kind = enum { system, room, portal, source, material };
const Property = struct { id: u32, bytes: []u8 };
const Object = struct {
    id: usize,
    kind: Kind,
    system: usize,
    retired: bool = false,
    properties: std.ArrayList(Property) = .empty,
    data: [0x60]u8 = @splat(0),
    fn deinit(self: *Object) void {
        for (self.properties.items) |property| allocator.free(property.bytes);
        self.properties.deinit(allocator);
    }
};
var mutex: memory.HostMutex = .{};
var objects: std.ArrayList(Object) = .empty;
var next_id: usize = 0x41500000;
var no_propagation = true;

pub fn configureNoPropagation(enabled: bool) void {
    mutex.lock();
    defer mutex.unlock();
    no_propagation = enabled;
}
pub fn reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (objects.items) |*object| object.deinit();
    objects.deinit(allocator);
    objects = .empty;
    next_id = 0x41500000;
    no_propagation = true;
}
fn read(comptime T: type, address: usize) ?T {
    if (!access.readable(address, @sizeOf(T))) return null;
    return @as(*align(1) const T, @ptrFromInt(address)).*;
}
fn write(comptime T: type, address: usize, value: T) bool {
    if (!access.writable(address, @sizeOf(T))) return false;
    access.notifyWrite(address, @sizeOf(T));
    @as(*align(1) T, @ptrFromInt(address)).* = value;
    return true;
}
fn descriptorValid(value: Descriptor, id: u32, size: usize) bool {
    return value.id == id and value.size == size;
}
fn find(id: usize, kind: Kind) ?*Object {
    for (objects.items) |*object| if (object.id == id and object.kind == kind) return object;
    return null;
}
fn live(id: usize, kind: Kind) ?*Object {
    const object = find(id, kind) orelse return null;
    if (object.retired) return null;
    const system = find(object.system, .system) orelse return null;
    if (system.retired) return null;
    const header = read(Header, object.system) orelse return null;
    return if (header.magic == magic) object else null;
}
pub fn queryMemory(options: usize, output: usize) callconv(abi.guest) i32 {
    if (!access.readable(options, 16)) return invalid;
    var mem = read(SystemMemory, output) orelse return invalid;
    if (!descriptorValid(mem.descriptor, 0x010107d4, @sizeOf(SystemMemory))) return invalid;
    mutex.lock();
    defer mutex.unlock();
    if (!no_propagation) return unsupported;
    mem.cpu_size = @sizeOf(Header);
    mem.gpu_size = 0;
    return if (write(SystemMemory, output, mem)) 0 else invalid;
}
pub fn createSystem(options: usize, mem_address: usize, output: usize) callconv(abi.guest) i32 {
    if (!access.readable(options, 16) or !access.writable(output, @sizeOf(usize))) return invalid;
    const mem = read(SystemMemory, mem_address) orelse return invalid;
    if (!descriptorValid(mem.descriptor, 0x010107d4, @sizeOf(SystemMemory)) or
        mem.cpu % @alignOf(Header) != 0 or mem.cpu_size < @sizeOf(Header) or mem.gpu_size != 0 or
        !access.writable(mem.cpu, @sizeOf(Header))) return invalid;
    mutex.lock();
    defer mutex.unlock();
    if (!no_propagation) return unsupported;
    if (find(mem.cpu, .system) != null) return invalid;
    objects.append(allocator, .{ .id = mem.cpu, .kind = .system, .system = mem.cpu }) catch return no_memory;
    _ = write(Header, mem.cpu, .{});
    _ = write(usize, output, mem.cpu);
    std.debug.print("[audio propagation] diagnostic backend: acoustic effects disabled; no rays or reflected audio are generated\n", .{});
    return 0;
}
pub fn destroySystem(system: usize) callconv(abi.guest) i32 {
    mutex.lock();
    defer mutex.unlock();
    if (live(system, .system) == null) return invalid;
    _ = write(Header, system, .{ .magic = 0 });
    var i = objects.items.len;
    while (i > 0) {
        i -= 1;
        if (objects.items[i].system != system) continue;
        if (objects.items[i].kind == .system) {
            var item = objects.swapRemove(i);
            item.deinit();
        } else objects.items[i].retired = true;
    }
    return 0;
}
fn create(system: usize, kind: Kind, output: usize, data: []const u8) i32 {
    if (!access.writable(output, @sizeOf(usize))) return invalid;
    if (live(system, .system) == null) return invalid;
    next_id += 1;
    var object = Object{ .id = next_id, .kind = kind, .system = system };
    @memcpy(object.data[0..data.len], data);
    objects.append(allocator, object) catch return no_memory;
    _ = write(usize, output, next_id);
    return 0;
}
fn destroy(system: ?usize, id: usize, kind: Kind) i32 {
    mutex.lock();
    defer mutex.unlock();
    for (objects.items, 0..) |object, i| {
        if (object.id != id or object.kind != kind) continue;
        if (system) |owner| if (object.system != owner) return invalid;
        var item = objects.swapRemove(i);
        item.deinit();
        return 0;
    }
    return invalid;
}
pub fn createRoom(system: usize, output: usize) callconv(abi.guest) i32 {
    mutex.lock();
    defer mutex.unlock();
    return create(system, .room, output, &.{});
}
pub fn createSource(system: usize, output: usize) callconv(abi.guest) i32 {
    mutex.lock();
    defer mutex.unlock();
    return create(system, .source, output, &.{});
}
pub fn createPortal(system: usize, params: usize, output: usize) callconv(abi.guest) i32 {
    const portal = read(Portal, params) orelse return invalid;
    if (!descriptorValid(portal.descriptor, 0x010107d8, @sizeOf(Portal))) return invalid;
    mutex.lock();
    defer mutex.unlock();
    for (portal.rooms) |room| {
        const object = live(room, .room) orelse return invalid;
        if (object.system != system) return invalid;
    }
    return create(system, .portal, output, std.mem.asBytes(&portal));
}
pub fn registerMaterial(system: usize, params: usize, output: usize) callconv(abi.guest) i32 {
    const desc = read(Descriptor, params) orelse return invalid;
    if (!descriptorValid(desc, 0x010107d1, 0x40)) return invalid;
    const data = read([0x40]u8, params) orelse return invalid;
    mutex.lock();
    defer mutex.unlock();
    return create(system, .material, output, &data);
}
pub fn destroyRoom(system: usize, id: usize) callconv(abi.guest) i32 {
    return destroy(system, id, .room);
}
pub fn destroyPortal(system: usize, id: usize) callconv(abi.guest) i32 {
    return destroy(system, id, .portal);
}
pub fn destroySource(system: usize, id: usize) callconv(abi.guest) i32 {
    return destroy(system, id, .source);
}
pub fn unregisterMaterial(id: usize) callconv(abi.guest) i32 {
    return destroy(null, id, .material);
}
fn attributes(id: usize, kind: Kind, address: usize, count: u32) i32 {
    if (count > 256 or (count != 0 and !access.readable(address, @as(usize, count) * @sizeOf(Attribute)))) return invalid;
    var pending: std.ArrayList(Property) = .empty;
    defer {
        for (pending.items) |property| allocator.free(property.bytes);
        pending.deinit(allocator);
    }
    for (0..count) |i| {
        const attr = read(Attribute, address + i * @sizeOf(Attribute)) orelse return invalid;
        if (attr.size == 0 or attr.size > 65536 or !access.readable(attr.value, attr.size)) return invalid;
        const bytes = allocator.dupe(u8, @as([*]const u8, @ptrFromInt(attr.value))[0..attr.size]) catch return no_memory;
        pending.append(allocator, .{ .id = attr.id, .bytes = bytes }) catch {
            allocator.free(bytes);
            return no_memory;
        };
    }
    mutex.lock();
    defer mutex.unlock();
    const object = live(id, kind) orelse return invalid;
    object.properties.ensureUnusedCapacity(allocator, pending.items.len) catch return no_memory;
    for (pending.items) |property| {
        var replaced = false;
        for (object.properties.items) |*old| if (old.id == property.id) {
            allocator.free(old.bytes);
            old.* = property;
            replaced = true;
            break;
        };
        if (!replaced) object.properties.appendAssumeCapacity(property);
    }
    pending.clearRetainingCapacity();
    return 0;
}
pub fn systemAttributes(id: usize, addr: usize, count: u32) callconv(abi.guest) i32 {
    return attributes(id, .system, addr, count);
}
pub fn sourceAttributes(id: usize, addr: usize, count: u32) callconv(abi.guest) i32 {
    return attributes(id, .source, addr, count);
}
pub fn portalAttributes(id: usize, addr: usize, count: u32) callconv(abi.guest) i32 {
    return attributes(id, .portal, addr, count);
}
fn emptyOutput(id: usize, kind: Kind, count: usize) i32 {
    mutex.lock();
    defer mutex.unlock();
    if (live(id, kind) == null) return invalid;
    return if (write(u32, count, 0)) 0 else invalid;
}
pub fn systemGetRays(id: usize, _: usize, count: usize) callconv(abi.guest) i32 {
    return emptyOutput(id, .system, count);
}
pub fn sourceGetRays(id: usize, _: usize, count: usize) callconv(abi.guest) i32 {
    return emptyOutput(id, .source, count);
}
pub fn sourceGetPathCount(id: usize, count: usize) callconv(abi.guest) i32 {
    return emptyOutput(id, .source, count);
}
fn emptyInput(id: usize, kind: Kind, count: u32) i32 {
    mutex.lock();
    defer mutex.unlock();
    if (live(id, kind) == null) return invalid;
    return if (count == 0) 0 else unsupported;
}
pub fn systemSetRays(id: usize, _: usize, count: u32) callconv(abi.guest) i32 {
    return emptyInput(id, .system, count);
}
pub fn sourceSetPaths(id: usize, _: usize, count: u32) callconv(abi.guest) i32 {
    return emptyInput(id, .source, count);
}
pub fn sourceCalculatePaths(id: usize, _: usize, ray_count: u32, _: u32, _: usize, path_count: u32) callconv(abi.guest) i32 {
    return emptyInput(id, .source, ray_count | path_count);
}
pub fn sourceGetPath(id: usize, _: u32, output: usize) callconv(abi.guest) i32 {
    mutex.lock();
    defer mutex.unlock();
    if (live(id, .source) == null or !write(usize, output, 0)) return invalid;
    return invalid;
}
pub fn render(system: usize, address: usize, count: u32) callconv(abi.guest) i32 {
    if (count > 4096 or (count != 0 and !access.readable(address, @as(usize, count) * @sizeOf(RenderInfo)))) return invalid;
    mutex.lock();
    defer mutex.unlock();
    if (live(system, .system) == null) return invalid;
    // Validate the complete batch before touching any output. This buffer is
    // the reflected/wet contribution; the game mixes its dry signal itself.
    for (0..count) |i| {
        const info = read(RenderInfo, address + i * @sizeOf(RenderInfo)) orelse return invalid;
        if (!descriptorValid(info.descriptor, 0x010107d6, @sizeOf(RenderInfo))) return invalid;
        const source = live(info.source, .source) orelse return invalid;
        if (source.system != system or info.size == 0 or info.size > 64 << 20 or !access.writable(info.output, info.size)) return invalid;
        if (info.output < address + @as(usize, count) * @sizeOf(RenderInfo) and
            address < info.output +| info.size) return invalid;
        if (info.format != 2) return unsupported;
    }
    for (0..count) |i| {
        const info = read(RenderInfo, address + i * @sizeOf(RenderInfo)).?;
        access.notifyWrite(info.output, info.size);
        @memset(@as([*]u8, @ptrFromInt(info.output))[0..info.size], 0);
    }
    return 0;
}

test "audio propagation diagnostics preserve descriptors and invalidate children" {
    reset();
    defer reset();
    var options: [16]u8 = @splat(0);
    var header = Header{};
    var mem = SystemMemory{ .cpu = @intFromPtr(&header), .gpu = 123 };
    configureNoPropagation(false);
    try std.testing.expectEqual(unsupported, queryMemory(@intFromPtr(&options), @intFromPtr(&mem)));
    configureNoPropagation(true);
    try std.testing.expectEqual(@as(i32, 0), queryMemory(@intFromPtr(&options), @intFromPtr(&mem)));
    try std.testing.expectEqual(@as(usize, 123), mem.gpu);
    try std.testing.expectEqual(@as(usize, 16), mem.cpu_size);
    var system: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), createSystem(@intFromPtr(&options), @intFromPtr(&mem), @intFromPtr(&system)));
    var source: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), createSource(system, @intFromPtr(&source)));
    var value: u32 = 42;
    const attribute = Attribute{ .id = 7, .value = @intFromPtr(&value), .size = 4 };
    try std.testing.expectEqual(@as(i32, 0), sourceAttributes(source, @intFromPtr(&attribute), 1));
    value = 99;
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, find(source, .source).?.properties.items[0].bytes[0..4], .little));
    try std.testing.expectEqual(unsupported, sourceSetPaths(source, 0, 1));
    try std.testing.expectEqual(@as(i32, 0), destroySystem(system));
    try std.testing.expectEqual(invalid, sourceGetPathCount(source, @intFromPtr(&value)));
    try std.testing.expectEqual(@as(i32, 0), destroySource(system, source));
    try std.testing.expectEqual(@as(usize, 0), objects.items.len);
}

test "audio propagation render validates every output before writing" {
    reset();
    defer reset();
    configureNoPropagation(true);
    var options: [16]u8 = @splat(0);
    var header = Header{};
    var mem = SystemMemory{ .cpu = @intFromPtr(&header), .cpu_size = @sizeOf(Header) };
    var system: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), createSystem(@intFromPtr(&options), @intFromPtr(&mem), @intFromPtr(&system)));
    var source: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), createSource(system, @intFromPtr(&source)));
    var output: [16]u8 = @splat(0x7f);
    var infos = [_]RenderInfo{
        .{ .descriptor = .{ .id = 0x010107d6, .size = 0x30 }, .source = source, .output = @intFromPtr(&output), .size = output.len, .format = 2, .reserved = 0 },
        .{ .descriptor = .{ .id = 0x010107d6, .size = 0x30 }, .source = 0, .output = @intFromPtr(&output), .size = output.len, .format = 2, .reserved = 0 },
    };
    try std.testing.expectEqual(invalid, render(system, @intFromPtr(&infos), 2));
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0x7f)), &output);
    try std.testing.expectEqual(@as(i32, 0), render(system, @intFromPtr(&infos), 1));
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), &output);
    infos[0].output = @intFromPtr(&infos);
    try std.testing.expectEqual(invalid, render(system, @intFromPtr(&infos), 1));
}
