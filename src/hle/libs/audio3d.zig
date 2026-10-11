// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Audio3d object PCM submission and stereo rendering. This is a stereo
//! approximation of position/gain, not an HRTF or room-acoustics renderer.
//! PS5 object attributes observed in the guest ABI: PCM=1, position=3, gain=5.
//! These IDs differ from the PS4 table; unsupported attributes are rejected.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const symbols = @import("../symbols.zig");
const filesystem = @import("../filesystem.zig");
const audio_device = @import("../audio_device.zig");
const kernel_memory = @import("kernel_memory.zig");
const kernel_threading = @import("kernel_threading.zig");
const gpa = if (builtin.is_test) std.testing.allocator else std.heap.page_allocator;

fn status(code: u32) i32 {
    return @bitCast(0x80ea0000 | code);
}
const invalid_port = status(2);
const invalid_object = status(3);
const invalid_parameter = status(4);
const out_of_memory = status(5);
const out_of_resources = status(6);
const not_ready = status(7);
const not_supported = status(8);
const max_ports = 4;
const max_frames = 4096;

const OpenParameters = extern struct {
    size: u64 = 0x28,
    granularity: u32 = 256,
    rate: u32 = 0,
    max_objects: u32 = 512,
    queue_depth: u32 = 2,
    buffer_mode: u32 = 2,
    padding: u32 = 0,
    num_beds: u32 = 2,
    tail: u32 = 0,
};
const Attribute = extern struct { id: u32, padding: u32 = 0, value: u64, size: u64 };
const Pcm = extern struct { format: u32, padding: u32 = 0, samples: u64, count: u32, tail: u32 = 0 };
const Properties = struct {
    position: [3]f32 = .{ 0, 0, 0 },
    gain: f32 = 1,
};
const Object = struct {
    properties: Properties = .{},
    pcm: std.ArrayList([]f32) = .empty,
    fn deinit(self: *Object) void {
        for (self.pcm.items) |samples| gpa.free(samples);
        self.pcm.deinit(gpa);
        self.* = .{};
    }
};
const Port = struct {
    generation: u64 = 0,
    parameters: OpenParameters = .{},
    next_object: u32 = 0,
    objects: std.AutoHashMapUnmanaged(u32, Object) = .empty,
    fn deinit(self: *Port) void {
        var iterator = self.objects.valueIterator();
        while (iterator.next()) |object| object.deinit();
        self.objects.deinit(gpa);
        self.* = .{};
    }
};
const Stream = struct {
    mutex: std.Io.Mutex = .init,
    flush_mutex: std.Io.Mutex = .init,
    generation: std.atomic.Value(u64) = .init(0),
    device: audio_device.Device = .{},
};
var mutex: std.atomic.Mutex = .unlocked;
var initialized = false;
var ports: [max_ports]Port = @splat(.{});
var streams: [max_ports]Stream = @splat(.{});
var next_generation: u64 = 0;
var latency_ms: std.atomic.Value(u16) = .init(audio_device.default_target_latency_ms);
var flushes: std.atomic.Value(u64) = .init(0);
fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}
fn getPort(id: u32) ?*Port {
    return if (id < ports.len and ports[id].generation != 0) &ports[id] else null;
}
fn readable(address: u64, size: u64) bool {
    return address != 0 and kernel_memory.isGuestRangeAccessible(address, size);
}
fn read(comptime T: type, address: u64) ?T {
    if (!readable(address, @sizeOf(T))) return null;
    const source: *align(1) const T = @ptrFromInt(address);
    return source.*;
}
fn writeId(output: ?*u32, value: u32) bool {
    const pointer = output orelse return false;
    if (kernel_memory.attachedAddressSpace()) |space| {
        space.write(@intFromPtr(pointer), std.mem.asBytes(&value)) catch return false;
    } else pointer.* = value;
    return true;
}
fn closeStream(index: usize) void {
    const stream = &streams[index];
    const io = filesystem.attachedIo();
    if (io) |attached| stream.mutex.lockUncancelable(attached);
    defer if (io) |attached| stream.mutex.unlock(attached);
    stream.generation.store(0, .release);
    stream.device.close();
}
pub fn setHostTargetLatencyMilliseconds(value: u16) void {
    latency_ms.store(value, .release);
}
pub fn reset() void {
    lock();
    defer mutex.unlock();
    for (&ports, 0..) |*port, index| {
        closeStream(index);
        port.deinit();
    }
    initialized = false;
    latency_ms.store(audio_device.default_target_latency_ms, .release);
    flushes.store(0, .monotonic);
}
fn initialize(reserved: i64) callconv(abi.guest) i32 {
    if (reserved != 0) return invalid_parameter;
    lock();
    defer mutex.unlock();
    if (initialized) return not_ready;
    initialized = true;
    return 0;
}
fn terminate() callconv(abi.guest) i32 {
    lock();
    defer mutex.unlock();
    if (!initialized) return not_ready;
    for (ports) |port| if (port.generation != 0) return not_ready;
    initialized = false;
    return 0;
}
fn portOpen(user: i32, parameters: ?*const OpenParameters, output: ?*u32) callconv(abi.guest) i32 {
    lock();
    defer mutex.unlock();
    if (!initialized) return not_ready;
    if (user != 255 and user != 1) return invalid_parameter;
    const address = @intFromPtr(parameters);
    const size = read(u64, address) orelse return invalid_parameter;
    if (size != 0x20 and size != 0x28) return not_supported;
    if (!readable(address, size)) return invalid_parameter;
    var p: OpenParameters = .{};
    const bytes: [*]const u8 = @ptrFromInt(address);
    @memcpy(std.mem.asBytes(&p)[0..@intCast(size)], bytes[0..@intCast(size)]);
    if (p.rate != 0 or p.granularity < 256 or p.granularity % 256 != 0 or p.max_objects == 0 or p.queue_depth == 0) return invalid_parameter;
    if (p.buffer_mode != 2 or p.num_beds != 2) return not_supported;
    if (p.granularity > max_frames or p.max_objects > 512 or p.queue_depth > 64 or
        @as(u64, p.granularity) * p.max_objects * p.queue_depth * 4 > 64 * 1024 * 1024) return out_of_resources;
    for (&ports, 0..) |*port, index| {
        if (port.generation != 0) continue;
        if (!writeId(output, @intCast(index))) return invalid_parameter;
        next_generation +%= 1;
        if (next_generation == 0) next_generation = 1;
        port.* = .{ .parameters = p, .generation = next_generation };
        streams[index].generation.store(next_generation, .release);
        std.debug.print("[audio 3d] open port={d} frames={d} objects={d} queue={d}\n", .{ index, p.granularity, p.max_objects, p.queue_depth });
        return 0;
    }
    return out_of_resources;
}
fn portClose(id: u32) callconv(abi.guest) i32 {
    lock();
    defer mutex.unlock();
    const port = getPort(id) orelse return invalid_port;
    closeStream(id);
    port.deinit();
    return 0;
}
fn objectReserve(id: u32, output: ?*u32) callconv(abi.guest) i32 {
    lock();
    defer mutex.unlock();
    if (!writeId(output, 0xffffffff)) return invalid_parameter;
    const port = getPort(id) orelse return invalid_port;
    if (port.objects.count() >= port.parameters.max_objects) return out_of_resources;
    var next = port.next_object;
    while (true) {
        next +%= 1;
        if (next != 0 and next != 0xffffffff and !port.objects.contains(next)) break;
    }
    port.objects.put(gpa, next, .{}) catch return out_of_memory;
    if (!writeId(output, next)) {
        _ = port.objects.remove(next);
        return invalid_parameter;
    }
    port.next_object = next;
    return 0;
}

// Validate the whole attribute list and own PCM before changing the object.
// Guest stack descriptors and reusable mix buffers may disappear on return.
fn objectSetAttributes(id: u32, object_id: u32, count: u64, attributes: ?[*]const Attribute) callconv(abi.guest) i32 {
    lock();
    defer mutex.unlock();
    const port = getPort(id) orelse return invalid_port;
    const object = port.objects.getPtr(object_id) orelse return invalid_object;
    if (count == 0 or count > 64 or !readable(@intFromPtr(attributes), count * @sizeOf(Attribute))) return invalid_parameter;
    const list = attributes.?[0..@intCast(count)];
    var properties = object.properties;
    var pending: std.ArrayList([]f32) = .empty;
    defer {
        for (pending.items) |samples| gpa.free(samples);
        pending.deinit(gpa);
    }
    for (list) |attribute| {
        switch (attribute.id) {
            1 => {
                if (attribute.size != @sizeOf(Pcm)) return invalid_parameter;
                const pcm = read(Pcm, attribute.value) orelse return invalid_parameter;
                if (pcm.format > 1 or pcm.count == 0 or pcm.count > port.parameters.granularity) return invalid_parameter;
                const sample_size: u32 = if (pcm.format == 0) 2 else 4;
                if (!readable(pcm.samples, @as(u64, pcm.count) * sample_size)) return invalid_parameter;
                if (object.pcm.items.len + pending.items.len >= port.parameters.queue_depth) return not_ready;
                const samples = gpa.alloc(f32, port.parameters.granularity) catch return out_of_memory;
                pending.append(gpa, samples) catch {
                    gpa.free(samples);
                    return out_of_memory;
                };
                @memset(samples, 0);
                for (samples[0..pcm.count], 0..) |*sample, index| {
                    const address = pcm.samples + index * sample_size;
                    // The complete source range was checked above. Repeating
                    // address-space queries per sample would dominate mixing.
                    const value = if (pcm.format == 0) @as(f32, @floatFromInt(@as(*align(1) const i16, @ptrFromInt(address)).*)) / 32768.0 else @as(*align(1) const f32, @ptrFromInt(address)).*;
                    sample.* = if (std.math.isFinite(value)) std.math.clamp(value, -1, 1) else 0;
                }
            },
            3 => {
                if (attribute.size != 12) return invalid_parameter;
                properties.position = read([3]f32, attribute.value) orelse return invalid_parameter;
                for (properties.position) |value| if (!std.math.isFinite(value)) return invalid_parameter;
            },
            5 => {
                if (attribute.size != 4) return invalid_parameter;
                properties.gain = read(f32, attribute.value) orelse return invalid_parameter;
                if (!std.math.isFinite(properties.gain) or properties.gain < 0) return invalid_parameter;
            },
            else => {
                std.debug.print("[audio 3d] unsupported object attribute={d} size={d}\n", .{ attribute.id, attribute.size });
                return not_supported;
            },
        }
    }
    const retained = object.pcm.items.len;
    object.pcm.ensureTotalCapacity(gpa, retained + pending.items.len) catch return out_of_memory;
    object.properties = properties;
    object.pcm.appendSliceAssumeCapacity(pending.items);
    pending.clearRetainingCapacity();
    return 0;
}

fn mix(port: *Port, output: []f32) bool {
    @memset(output, 0);
    var any = false;
    var iterator = port.objects.valueIterator();
    while (iterator.next()) |object| {
        if (object.pcm.items.len == 0) continue;
        any = true;
        const samples = object.pcm.orderedRemove(0);
        defer gpa.free(samples);
        // Bounded stereo azimuth approximation; centre is equal-power.
        // Normalize first to avoid overflowing when guest positions are huge.
        const p = object.properties.position;
        const scale = @max(@abs(p[0]), @max(@abs(p[1]), @abs(p[2])));
        const x = if (scale > 0) p[0] / scale else 0;
        const y = if (scale > 0) p[1] / scale else 0;
        const z = if (scale > 0) p[2] / scale else 0;
        const length = @sqrt(x * x + y * y + z * z);
        const pan = if (length > 0) std.math.clamp(x / length, -1, 1) else 0;
        const left = @sqrt((1 - pan) * 0.5) * object.properties.gain;
        const right = @sqrt((1 + pan) * 0.5) * object.properties.gain;
        for (samples, 0..) |sample, frame| {
            output[frame * 2] += sample * left;
            output[frame * 2 + 1] += sample * right;
        }
    }
    for (output) |*sample| sample.* = if (std.math.isFinite(sample.*)) std.math.clamp(sample.*, -1, 1) else 0;
    return any;
}

fn portFlush(id: u32) callconv(abi.guest) i32 {
    // Copy a bounded quantum under the metadata lock. Waiting on host audio
    // happens afterwards, and never holds up unrelated ports or attributes.
    var samples: [max_frames * 2]f32 = undefined;
    if (id >= max_ports) return invalid_port;
    const io = filesystem.attachedIo();
    if (io) |attached| streams[id].flush_mutex.lockUncancelable(attached);
    defer if (io) |attached| streams[id].flush_mutex.unlock(attached);
    lock();
    const initial = getPort(id) orelse {
        mutex.unlock();
        return invalid_port;
    };
    const expected_generation = initial.generation;
    const depth = initial.parameters.queue_depth;
    mutex.unlock();
    // A concurrent producer cannot extend this call indefinitely.
    for (0..depth) |_| {
        lock();
        const port = getPort(id) orelse {
            mutex.unlock();
            return invalid_port;
        };
        if (port.generation != expected_generation) {
            mutex.unlock();
            return invalid_port;
        }
        const generation = port.generation;
        const frames = port.parameters.granularity;
        const block = samples[0 .. frames * 2];
        const any = mix(port, block);
        mutex.unlock();
        if (!any) return 0;
        const number = flushes.fetchAdd(1, .monotonic) + 1;
        if (number <= 3 or number % 2000 == 0) {
            var peak: f32 = 0;
            for (block) |sample| peak = @max(peak, @abs(sample));
            std.debug.print("[audio 3d] mix #{d} frames={d} peak={d:.3}\n", .{ number, frames, peak });
        }
        if (!play(id, generation, frames, block)) {
            _ = kernel_threading.sceKernelUsleep(@intCast(@as(u64, frames) * std.time.us_per_s / 48000));
        }
    }
    return 0;
}
fn play(id: u32, generation: u64, frames: u32, samples: []const f32) bool {
    const io = filesystem.attachedIo() orelse return false;
    const stream = &streams[id];
    stream.mutex.lockUncancelable(io);
    defer stream.mutex.unlock(io);
    if (stream.generation.load(.acquire) != generation) return false;
    if (@import("audio.zig").audioDisabled()) return false;
    if (!stream.device.isOpen()) {
        stream.device.diagnostic_id = @as(i32, @intCast(id)) + 300;
        stream.device.open(.{ .frequency = 48000, .channels = 2, .format = .float32, .frames = frames, .target_latency_ms = latency_ms.load(.acquire) }) catch return false;
    }
    stream.device.play(std.mem.sliceAsBytes(samples)) catch return false;
    return true;
}
const exports = [_]symbols.Export{
    .{ .name = "sceAudio3dInitialize", .function = trace.wrap("sceAudio3dInitialize", &initialize), .expect_id = "UmCvjSmuZIw" },
    .{ .name = "sceAudio3dTerminate", .function = trace.wrap("sceAudio3dTerminate", &terminate), .expect_id = "WW1TS2iz5yc" },
    .{ .name = "sceAudio3dPortOpen", .function = trace.wrap("sceAudio3dPortOpen", &portOpen), .expect_id = "XeDDK0xJWQA" },
    .{ .name = "sceAudio3dPortClose", .function = trace.wrap("sceAudio3dPortClose", &portClose), .expect_id = "OyVqOeVNtSk" },
    .{ .name = "sceAudio3dObjectReserve", .function = trace.wrap("sceAudio3dObjectReserve", &objectReserve), .expect_id = "jO2tec4dJ2M" },
    .{ .name = "sceAudio3dObjectSetAttributes", .function = trace.wrap("sceAudio3dObjectSetAttributes", &objectSetAttributes), .expect_id = "4uyHN9q4ZeU" },
    .{ .name = "sceAudio3dPortFlush", .function = trace.wrap("sceAudio3dPortFlush", &portFlush), .expect_id = "ZOGrxWLgQzE" },
};
pub fn register(db: *symbols.Database, allocator: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(allocator, .{ .name = "libSceAudio3d", .version = 1 }, .{ .name = "libSceAudio3d", .version_major = 1, .version_minor = 1 }, &exports);
}

test "Audio3d lifecycle enforces port and object capacity and releases queued PCM" {
    reset();
    defer reset();
    try std.testing.expectEqual(not_ready, terminate());
    try std.testing.expectEqual(invalid_parameter, initialize(1));
    try std.testing.expectEqual(@as(i32, 0), initialize(0));
    try std.testing.expectEqual(not_ready, initialize(0));
    var p: OpenParameters = .{ .max_objects = 1 };
    var id: u32 = 99;
    p.buffer_mode = 0;
    try std.testing.expectEqual(not_supported, portOpen(255, &p, &id));
    p.buffer_mode = 2;
    for (0..max_ports) |index| {
        try std.testing.expectEqual(@as(i32, 0), portOpen(255, &p, &id));
        try std.testing.expectEqual(@as(u32, @intCast(index)), id);
    }
    try std.testing.expectEqual(out_of_resources, portOpen(255, &p, &id));
    var object: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), objectReserve(0, &object));
    try std.testing.expectEqual(@as(u32, 1), object);
    try std.testing.expectEqual(out_of_resources, objectReserve(0, &object));
    try std.testing.expectEqual(@as(u32, 0xffffffff), object);
    try std.testing.expectEqual(not_ready, terminate());
    for (0..max_ports) |index| try std.testing.expectEqual(@as(i32, 0), portClose(@intCast(index)));
    try std.testing.expectEqual(invalid_port, portClose(0));
    try std.testing.expectEqual(@as(i32, 0), terminate());
}

fn testOpen() !u32 {
    try std.testing.expectEqual(@as(i32, 0), initialize(0));
    var id: u32 = 99;
    const parameters: OpenParameters = .{};
    try std.testing.expectEqual(@as(i32, 0), portOpen(255, &parameters, &id));
    return id;
}
fn testObject(port: u32) !u32 {
    var id: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), objectReserve(port, &id));
    return id;
}
fn testAttribute(id: u32, value: anytype) Attribute {
    return .{ .id = id, .value = @intFromPtr(value), .size = @sizeOf(@TypeOf(value.*)) };
}

test "Audio3d owns planar PCM and mixes objects together with position and gain" {
    reset();
    defer reset();
    const port = try testOpen();
    const left = try testObject(port);
    const right = try testObject(port);
    var pcm_left: [256]f32 = @splat(0.5);
    var pcm_right: [256]i16 = @splat(-16384);
    const lp: Pcm = .{ .format = 1, .samples = @intFromPtr(&pcm_left), .count = 256 };
    const rp: Pcm = .{ .format = 0, .samples = @intFromPtr(&pcm_right), .count = 256 };
    const left_position: [3]f32 = .{ -1, 0, 0 };
    const right_position: [3]f32 = .{ 1, 0, 0 };
    const gain: f32 = 0.5;
    const la = [_]Attribute{ testAttribute(1, &lp), testAttribute(3, &left_position), testAttribute(5, &gain) };
    const ra = [_]Attribute{ testAttribute(1, &rp), testAttribute(3, &right_position) };
    try std.testing.expectEqual(@as(i32, 0), objectSetAttributes(port, left, la.len, &la));
    try std.testing.expectEqual(@as(i32, 0), objectSetAttributes(port, right, ra.len, &ra));
    @memset(&pcm_left, 0);
    @memset(&pcm_right, 0);
    var output: [512]f32 = undefined;
    try std.testing.expect(mix(&ports[port], &output));
    for (0..256) |frame| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.25), output[frame * 2], 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, -0.5), output[frame * 2 + 1], 0.0001);
    }
    try std.testing.expect(!mix(&ports[port], &output));
    for (output) |sample| try std.testing.expectEqual(@as(f32, 0), sample);
}

test "Audio3d rejects a bad attribute batch without changing gain or enqueuing PCM" {
    reset();
    defer reset();
    const port = try testOpen();
    const object = try testObject(port);
    const samples: [256]f32 = @splat(0.5);
    const pcm: Pcm = .{ .format = 1, .samples = @intFromPtr(&samples), .count = 256 };
    const gain: f32 = 0.2;
    var list = [_]Attribute{ testAttribute(5, &gain), testAttribute(1, &pcm), .{ .id = 99, .size = 0, .value = 0 } };
    try std.testing.expectEqual(not_supported, objectSetAttributes(port, object, list.len, &list));
    try std.testing.expectEqual(@as(usize, 0), ports[port].objects.get(object).?.pcm.items.len);
    try std.testing.expectEqual(@as(f32, 1), ports[port].objects.get(object).?.properties.gain);
    list[2] = .{ .id = 3, .size = 12, .value = 0 };
    try std.testing.expectEqual(invalid_parameter, objectSetAttributes(port, object, list.len, &list));
    try std.testing.expectEqual(@as(usize, 0), ports[port].objects.get(object).?.pcm.items.len);
    try std.testing.expectEqual(invalid_object, objectSetAttributes(port, 99, 1, &list));
}

test "Audio3d queue is bounded FIFO and closing releases pending samples" {
    reset();
    defer reset();
    const port = try testOpen();
    const object = try testObject(port);
    var samples: [256]f32 = @splat(0.25);
    const pcm: Pcm = .{ .format = 1, .samples = @intFromPtr(&samples), .count = 256 };
    const position: [3]f32 = .{ 1, 0, 0 };
    const list = [_]Attribute{ testAttribute(1, &pcm), testAttribute(3, &position) };
    try std.testing.expectEqual(@as(i32, 0), objectSetAttributes(port, object, list.len, &list));
    @memset(&samples, 0.75);
    try std.testing.expectEqual(@as(i32, 0), objectSetAttributes(port, object, list.len, &list));
    try std.testing.expectEqual(not_ready, objectSetAttributes(port, object, list.len, &list));
    var output: [512]f32 = undefined;
    try std.testing.expect(mix(&ports[port], &output));
    try std.testing.expectEqual(@as(f32, 0.25), output[1]);
    try std.testing.expect(mix(&ports[port], &output));
    try std.testing.expectEqual(@as(f32, 0.75), output[1]);
    try std.testing.expectEqual(@as(i32, 0), objectSetAttributes(port, object, list.len, &list));
    try std.testing.expectEqual(@as(i32, 0), portClose(port));
    const parameters: OpenParameters = .{};
    var reopened: u32 = 99;
    try std.testing.expectEqual(@as(i32, 0), portOpen(255, &parameters, &reopened));
    try std.testing.expectEqual(port, reopened);
    try std.testing.expectEqual(@as(u32, 1), try testObject(reopened));
    try std.testing.expect(!mix(&ports[reopened], &output));
    try std.testing.expectEqual(@as(i32, 0), portFlush(reopened));
}

test "Audio3d nonfinite PCM is silent and stereo sums saturate" {
    reset();
    defer reset();
    const port = try testOpen();
    var samples: [256]f32 = @splat(1);
    samples[0] = std.math.nan(f32);
    samples[1] = std.math.inf(f32);
    const pcm: Pcm = .{ .format = 1, .samples = @intFromPtr(&samples), .count = 256 };
    const list = [_]Attribute{testAttribute(1, &pcm)};
    for (0..3) |_| {
        const object = try testObject(port);
        try std.testing.expectEqual(@as(i32, 0), objectSetAttributes(port, object, 1, &list));
    }
    var output: [512]f32 = undefined;
    try std.testing.expect(mix(&ports[port], &output));
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 1, 1 }, output[0..6]);
}

test "Audio3d registers all seven KeyWe imports with the proper library" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 7), db.count());
    for (exports) |entry| {
        const found = db.findById(entry.expect_id.?, .function) orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings("libSceAudio3d", found.key.library.name);
    }
}
