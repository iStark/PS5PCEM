// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! libkernel AMM interface used by guest libSceAmpr implementations.
//! Writers emit native packed commands; submissions decode guest bytes and
//! apply real mappings in order. No guest command is treated as a success
//! merely because its import resolved.
//!
//! ABI/layout references: drakmor/ampr_emu, include/ampr_emu_kernel_amm.h,
//! include/ampr.h, src/ampr_emu_command_packing.cpp (GPL-3.0-or-later).
//! Submission is synchronous. Sparse PRT and non-mapper command opcodes
//! without an implementation report an error rather than being discarded.

const std = @import("std");
const host = @import("memory");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const apr = @import("../apr.zig");
const memory = @import("kernel_memory.zig");
const packets = @import("../amm_packets.zig");
const E = errno.KernelError;
const Command = packets.Command;
const OutputSize = ?*align(1) u64;

pub const Result = extern struct { result: i32 = 0, error_offset: u32 = 0 };
const Submission = struct { id: u32 = 0, result: i32 = 0 };
var lock = host.HostMutex{};
var submissions: [4096]Submission = @splat(.{});
var next_id: u32 = 1;

pub fn reset() void {
    lock.lock();
    defer lock.unlock();
    submissions = @splat(.{});
    next_id = 1;
}

fn writable(pointer: anytype, size: usize) bool {
    return host.isHostRangeWritable(@intFromPtr(pointer), size);
}

fn write(destination: u64, command: Command, out_size: OutputSize) i32 {
    const packet = packets.encode(command) catch return E.einval.raw();
    const bytes = packet.count * 4;
    if (out_size) |output| if (!writable(output, 8)) return E.efault.raw();
    if (destination != 0) {
        if (!host.isHostRangeWritable(destination, bytes)) return E.efault.raw();
        const target: [*]u8 = @ptrFromInt(destination);
        for (packet.words[0..packet.count], 0..) |word, index| {
            std.mem.writeInt(u32, target[index * 4 ..][0..4], word, .little);
        }
    }
    if (out_size) |output| output.* = bytes;
    return errno.ok;
}

fn map(destination: u64, address: u64, size: u64, memory_type: u64, protection: u64, gpu_mask: ?u64, prt: u64, out_size: OutputSize) i32 {
    if (memory_type > 31 or protection & ~packets.protection_mask != 0 or
        (gpu_mask orelse 0) > 255 or prt > 1) return E.einval.raw();
    return write(destination, .{ .kind = .map, .address = address, .size = size, .memory_type = @intCast(memory_type), .protection = @intCast(protection), .gpu_mask = if (gpu_mask) |value| @intCast(value) else null, .prt = prt != 0 }, out_size);
}

fn direct(destination: u64, address: u64, physical: u64, size: u64, memory_type: u64, protection: u64, gpu_mask: ?u64, out_size: OutputSize) i32 {
    if (memory_type > 31 or protection & ~packets.protection_mask != 0 or
        (gpu_mask orelse 0) > 255) return E.einval.raw();
    return write(destination, .{ .kind = .direct, .address = address, .source = physical, .size = size, .memory_type = @intCast(memory_type), .protection = @intCast(protection), .gpu_mask = if (gpu_mask) |value| @intCast(value) else null }, out_size);
}

fn alias(destination: u64, address: u64, source: u64, size: u64, protection: u64, gpu_mask: ?u64, move: bool, out_size: OutputSize) i32 {
    if (protection & ~packets.protection_mask != 0 or (gpu_mask orelse 0) > 255) return E.einval.raw();
    return write(destination, .{ .kind = if (move) .remap else .alias, .address = address, .source = source, .size = size, .protection = @intCast(protection), .gpu_mask = if (gpu_mask) |value| @intCast(value) else null }, out_size);
}

fn protect(destination: u64, address: u64, size: u64, memory_type: ?u64, protection: u64, mask: u64, gpu_mask: ?u64, out_size: OutputSize) i32 {
    if ((memory_type orelse 0) > 31 or protection & ~packets.protection_mask != 0 or
        mask & ~packets.protection_mask != 0 or (gpu_mask orelse 0) > 255) return E.einval.raw();
    return write(destination, .{ .kind = .protect, .address = address, .size = size, .memory_type = if (memory_type) |value| @intCast(value) else null, .protection = @intCast(protection), .mask = @intCast(mask), .gpu_mask = if (gpu_mask) |value| @intCast(value) else null }, out_size);
}

/// Shared by native AMM indirect buffers and APR map/read command streams.
pub fn execute(command: Command) i32 {
    if (command.prt) return E.enosys.raw();
    switch (command.kind) {
        .unmap => return memory.hostUnmap(command.address, command.size),
        .remap, .alias => return memory.hostAliasDirectMemory(command.address, command.source, command.size, command.protection, command.gpu_mask, command.kind == .remap),
        .protect => return memory.hostModifyProtection(command.address, command.size, command.protection, command.mask, if (command.memory_type) |value| value else null, command.gpu_mask),
        .map, .direct => {
            const status = if (command.kind == .map)
                apr.mapAutoMemory(command.address, command.size, command.memory_type orelse 0, command.protection)
            else
                memory.hostMapDirectMemoryFixed(command.address, command.size, command.protection, command.source);
            if (status != errno.ok) return status;
            return memory.hostModifyProtection(command.address, command.size, command.protection, 0x3f3, command.memory_type orelse 0, command.gpu_mask);
        },
    }
}

fn submit(priority: u32, base: u64, size: u64, result: ?*align(1) Result, out_id: ?*align(1) u32) i32 {
    if (priority > 2 or size > 64 * 1024 * 1024 or size & 3 != 0) return E.einval.raw();
    if (result) |output| if (!writable(output, @sizeOf(Result))) return E.efault.raw();
    if (out_id) |output| if (!writable(output, 4)) return E.efault.raw();
    if (size != 0 and !host.isHostRangeReadable(base, @intCast(size))) return E.efault.raw();
    // Snapshot before output writes or mappings can overlap the original
    // buffer. Invalid/truncated commands fail before any memory operation.
    const data: []const u8 = if (size == 0) &.{} else @as([*]const u8, @ptrFromInt(base))[0..@intCast(size)];
    const snapshot = std.heap.page_allocator.dupe(u8, data) catch return E.enomem.raw();
    defer std.heap.page_allocator.free(snapshot);
    var offset: usize = 0;
    while (offset < snapshot.len) {
        const decoded = packets.decode(snapshot[offset..]) catch {
            if (result) |output| output.* = .{ .result = E.einval.raw(), .error_offset = @intCast(offset) };
            return E.einval.raw();
        };
        offset += decoded.bytes;
    }
    lock.lock();
    defer lock.unlock();
    // Reserve an identifier before any side effects. No-ID submits consume no
    // completion slot; waited submissions return their slot to this table.
    const slot: ?*Submission = if (out_id != null) blk: {
        for (&submissions) |*entry| if (entry.id == 0) break :blk entry;
        return E.eagain.raw();
    } else null;
    var status: i32 = errno.ok;
    offset = 0;
    while (offset < snapshot.len) {
        const decoded = packets.decode(snapshot[offset..]) catch unreachable;
        status = execute(decoded.command);
        if (status != errno.ok) break;
        offset += decoded.bytes;
    }
    // A command may have unmapped or write-protected its own completion
    // storage. Recheck after execution before touching either guest output.
    if (result) |output| if (!writable(output, @sizeOf(Result))) return E.efault.raw();
    if (out_id) |output| if (!writable(output, 4)) return E.efault.raw();
    if (result) |output| output.* = .{ .result = status, .error_offset = if (status == 0) 0 else @intCast(offset) };
    if (slot) |entry| {
        // Completed IDs remain distinct from every outstanding ID after wrap.
        while (true) {
            const candidate = next_id;
            next_id +%= 1;
            if (next_id == 0) next_id = 1;
            var occupied = false;
            for (submissions) |existing| if (existing.id == candidate) {
                occupied = true;
                break;
            };
            if (!occupied) {
                entry.* = .{ .id = candidate, .result = status };
                out_id.?.* = candidate;
                break;
            }
        }
    }
    return status;
}

fn callIndirectBuffer(priority: u32, base: u64, size: u64) callconv(abi.guest) i32 {
    return submit(priority, base, size, null, null);
}
fn callIndirectBuffer2(priority: u32, base: u64, size: u64, result: ?*align(1) Result, out_id: ?*align(1) u32) callconv(abi.guest) i32 {
    return submit(priority, base, size, result, out_id);
}
fn callIndirectBuffer3(priority: u32, base: u64, size: u64, out_id: ?*align(1) u32) callconv(abi.guest) i32 {
    if (out_id == null) return E.efault.raw();
    return submit(priority, base, size, null, out_id);
}
fn waitCompletion(id: u32) callconv(abi.guest) i32 {
    if (id == 0) return E.esrch.raw();
    lock.lock();
    defer lock.unlock();
    for (&submissions) |*entry| {
        if (entry.id == id) {
            const status = entry.result;
            entry.* = .{};
            return status;
        }
    }
    return E.esrch.raw();
}
fn giveDirectMemory(start: i64, end: i64, size: u64, alignment: u64, usage: i32, out: ?*align(1) i64) callconv(abi.guest) i32 {
    const output = out orelse return E.efault.raw();
    if (!writable(output, 8)) return E.efault.raw();
    if (start < 0 or end < 0 or usage < 0 or usage > 1) return E.einval.raw();
    var physical: u64 = 0;
    const status = memory.hostAllocateDirectMemory(@intCast(start), @intCast(end), size, alignment, 0, &physical);
    if (status != errno.ok) return status;
    if (usage == 1) apr.giveAutoPool(physical, size) catch {
        _ = memory.hostReleaseDirectMemory(physical, size);
        return E.enomem.raw();
    };
    output.* = @intCast(physical);
    return errno.ok;
}
fn getParam(param: ?*align(1) [7]u64) callconv(abi.guest) i32 {
    const output = param orelse return E.efault.raw();
    if (!host.isHostRangeReadable(@intFromPtr(output), 8)) return E.efault.raw();
    const size = output[0];
    if (size < 8 or size > 56 or size & 7 != 0) return E.einval.raw();
    if (!writable(output, @intCast(size))) return E.efault.raw();
    // Match the virtual windows already published by our libSceAmpr HLE.
    const values = [_]u64{ size, 0x1000000000, 0x2000000000, 0x1800000000, 0x2000000000, 0, 0 };
    const bytes: [*]u8 = @ptrCast(output);
    @memcpy(bytes[0..@intCast(size)], std.mem.asBytes(&values)[0..@intCast(size)]);
    return errno.ok;
}

// Export adapters below retain the actual seventh/eighth guest
// arguments; GPU-mask writers must not accidentally read the output-size
// pointer from a different stack slot.

fn writeMapCommand2(dst: u64, va: u64, size: u64, kind: u64, prot: u64, prt: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return map(dst, va, size, kind, prot, null, prt, out_size);
}

fn writeMapCommand(dst: u64, va: u64, size: u64, kind: u64, prot: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return map(dst, va, size, kind, prot, null, 0, out_size);
}

fn writeMapWithGpuMaskIdCommand(dst: u64, va: u64, size: u64, kind: u64, prot: u64, gpu_mask: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return map(dst, va, size, kind, prot, gpu_mask, 0, out_size);
}

fn writeMapDirectCommand(dst: u64, va: u64, physical: u64, size: u64, kind: u64, prot: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return direct(dst, va, physical, size, kind, prot, null, out_size);
}

fn writeRemapCommand(dst: u64, va: u64, source: u64, size: u64, prot: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return alias(dst, va, source, size, prot, null, true, out_size);
}

fn writeMultiMapCommand(dst: u64, va: u64, source: u64, size: u64, prot: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return alias(dst, va, source, size, prot, null, false, out_size);
}

fn writeModifyProtectCommand(dst: u64, va: u64, size: u64, prot: u64, mask: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return protect(dst, va, size, null, prot, mask, null, out_size);
}

fn writeModifyMtypeProtectCommand(dst: u64, va: u64, size: u64, kind: u64, prot: u64, mask: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return protect(dst, va, size, kind, prot, mask, null, out_size);
}

fn writeMapDirectWithGpuMaskIdCommand(dst: u64, va: u64, physical: u64, size: u64, kind: u64, prot: u64, gpu_mask: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return direct(dst, va, physical, size, kind, prot, gpu_mask, out_size);
}

fn writeRemapWithGpuMaskIdCommand(dst: u64, va: u64, source: u64, size: u64, prot: u64, gpu_mask: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return alias(dst, va, source, size, prot, gpu_mask, true, out_size);
}

fn writeMultiMapWithGpuMaskIdCommand(dst: u64, va: u64, source: u64, size: u64, prot: u64, gpu_mask: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return alias(dst, va, source, size, prot, gpu_mask, false, out_size);
}

fn writeModifyProtectWithGpuMaskIdCommand(dst: u64, va: u64, size: u64, prot: u64, mask: u64, gpu_mask: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return protect(dst, va, size, null, prot, mask, gpu_mask, out_size);
}

fn writeModifyMtypeProtectWithGpuMaskIdCommand(dst: u64, va: u64, size: u64, kind: u64, prot: u64, mask: u64, gpu_mask: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return protect(dst, va, size, kind, prot, mask, gpu_mask, out_size);
}

fn writeUnmapCommand(dst: u64, va: u64, size: u64, out_size: OutputSize) callconv(abi.guest) i32 {
    return write(dst, .{ .kind = .unmap, .address = va, .size = size }, out_size);
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceKernelWriteMapCommand2", .function = trace.wrap("sceKernelWriteMapCommand2", &writeMapCommand2), .expect_id = "5b3ZqlxJ+WE" },
    .{ .name = "sceKernelWriteMapCommand", .function = trace.wrap("sceKernelWriteMapCommand", &writeMapCommand), .expect_id = "3ZOA8Pf6Jho" },
    .{ .name = "sceKernelWriteMapWithGpuMaskIdCommand", .function = trace.wrap("sceKernelWriteMapWithGpuMaskIdCommand", &writeMapWithGpuMaskIdCommand), .expect_id = "G-NhAZUNlwc" },
    .{ .name = "sceKernelWriteMapDirectCommand", .function = trace.wrap("sceKernelWriteMapDirectCommand", &writeMapDirectCommand), .expect_id = "3M8jROcYzjs" },
    .{ .name = "sceKernelWriteRemapCommand", .function = trace.wrap("sceKernelWriteRemapCommand", &writeRemapCommand), .expect_id = "VZPXaaxp9xc" },
    .{ .name = "sceKernelWriteMultiMapCommand", .function = trace.wrap("sceKernelWriteMultiMapCommand", &writeMultiMapCommand), .expect_id = "sJrF-d2uL0Y" },
    .{ .name = "sceKernelWriteModifyProtectCommand", .function = trace.wrap("sceKernelWriteModifyProtectCommand", &writeModifyProtectCommand), .expect_id = "B4xIPqeRONI" },
    .{ .name = "sceKernelWriteModifyMtypeProtectCommand", .function = trace.wrap("sceKernelWriteModifyMtypeProtectCommand", &writeModifyMtypeProtectCommand), .expect_id = "hrEIwWDKm-w" },
    .{ .name = "sceKernelWriteMapDirectWithGpuMaskIdCommand", .function = trace.wrap("sceKernelWriteMapDirectWithGpuMaskIdCommand", &writeMapDirectWithGpuMaskIdCommand), .expect_id = "tNaDjIbVOwc" },
    .{ .name = "sceKernelWriteRemapWithGpuMaskIdCommand", .function = trace.wrap("sceKernelWriteRemapWithGpuMaskIdCommand", &writeRemapWithGpuMaskIdCommand), .expect_id = "G5tFhAqrCTg" },
    .{ .name = "sceKernelWriteMultiMapWithGpuMaskIdCommand", .function = trace.wrap("sceKernelWriteMultiMapWithGpuMaskIdCommand", &writeMultiMapWithGpuMaskIdCommand), .expect_id = "HYzkJb41fcE" },
    .{ .name = "sceKernelWriteModifyProtectWithGpuMaskIdCommand", .function = trace.wrap("sceKernelWriteModifyProtectWithGpuMaskIdCommand", &writeModifyProtectWithGpuMaskIdCommand), .expect_id = "2zLw9GwrtyI" },
    .{ .name = "sceKernelWriteModifyMtypeProtectWithGpuMaskIdCommand", .function = trace.wrap("sceKernelWriteModifyMtypeProtectWithGpuMaskIdCommand", &writeModifyMtypeProtectWithGpuMaskIdCommand), .expect_id = "rm5-jOxSZzQ" },
    .{ .name = "sceKernelWriteUnmapCommand", .function = trace.wrap("sceKernelWriteUnmapCommand", &writeUnmapCommand), .expect_id = "TyzsoH-vx8o" },
    .{ .name = "sceKernelCallIndirectBuffer", .function = trace.wrap("sceKernelCallIndirectBuffer", &callIndirectBuffer), .expect_id = "ahy8NSXrSbs" },
    .{ .name = "sceKernelCallIndirectBuffer2", .function = trace.wrap("sceKernelCallIndirectBuffer2", &callIndirectBuffer2), .expect_id = "MCdZ06CSUOc" },
    .{ .name = "sceKernelCallIndirectBuffer3", .function = trace.wrap("sceKernelCallIndirectBuffer3", &callIndirectBuffer3), .expect_id = "x+JkNr3eoxs" },
    .{ .name = "sceKernelWaitCommandBufferCompletion", .function = trace.wrap("sceKernelWaitCommandBufferCompletion", &waitCompletion), .expect_id = "3GqBPApWgPY" },
    .{ .name = "sceKernelGiveDirectMemoryToMapper", .function = trace.wrap("sceKernelGiveDirectMemoryToMapper", &giveDirectMemory), .expect_id = "H59T7YvKI5M" },
    .{ .name = "sceKernelMapperGetParam", .function = trace.wrap("sceKernelMapperGetParam", &getParam), .expect_id = "1yXS+iqB3wQ" },
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libkernel", .version = 1 }, .{ .name = "libkernel", .version_major = 1, .version_minor = 1 }, &exports);
}

test "AMM issue 8 resolves every reported libkernel import with checked names" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try memory.register(&db, std.testing.allocator);
    try @import("kernel_aio.zig").register(&db, std.testing.allocator);
    const identifiers = [_][]const u8{
        "5b3ZqlxJ+WE", "G-NhAZUNlwc", "3M8jROcYzjs", "tNaDjIbVOwc",
        "VZPXaaxp9xc", "G5tFhAqrCTg", "sJrF-d2uL0Y", "HYzkJb41fcE",
        "B4xIPqeRONI", "2zLw9GwrtyI", "hrEIwWDKm-w", "rm5-jOxSZzQ",
        "TyzsoH-vx8o", "MCdZ06CSUOc", "ahy8NSXrSbs", "H59T7YvKI5M",
        "3GqBPApWgPY", "9bfdLIyuwCY", "9WK-vhNXimw", "1yXS+iqB3wQ",
        "teiItL2boFw",
    };
    for (identifiers) |id| {
        const symbol = db.findById(id, .function) orelse return error.MissingIssue8Import;
        try std.testing.expectEqualStrings("libkernel", symbol.key.library.name);
        try std.testing.expect(@import("../nid.zig").matches(symbol.name, id));
    }
}

test "AMM guest ABI writers measure without side effects and preserve stack arguments" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    const Direct = *const fn (u64, u64, u64, u64, u64, u64, u64, OutputSize) callconv(abi.guest) i32;
    const Protect = *const fn (u64, u64, u64, u64, u64, u64, u64, OutputSize) callconv(abi.guest) i32;
    const direct_fn: Direct = @ptrFromInt(db.findById("tNaDjIbVOwc", .function).?.address);
    const protect_fn: Protect = @ptrFromInt(db.findById("rm5-jOxSZzQ", .function).?.address);
    var storage: [32]u8 = @splat(0xaa);
    var bytes: u64 = 0;
    try std.testing.expectEqual(errno.ok, direct_fn(0, 0x1000000000, 0x8000, 0x4000, 3, 0x33, 7, &bytes));
    try std.testing.expectEqual(@as(u64, 20), bytes);
    try std.testing.expectEqual(errno.ok, direct_fn(@intFromPtr(&storage), 0x1000000000, 0x8000, 0x4000, 3, 0x33, 7, &bytes));
    const command = (try packets.decode(storage[0..20])).command;
    try std.testing.expectEqual(@as(?u8, 7), command.gpu_mask);
    try std.testing.expectEqual(@as(u64, 0x8000), command.source);
    try std.testing.expectEqual(@as(u8, 0xaa), storage[20]);
    try std.testing.expectEqual(errno.ok, protect_fn(@intFromPtr(&storage), 0x1000000000, 0x4000, 0, 1, 3, 9, &bytes));
    const changed = (try packets.decode(storage[0..20])).command;
    try std.testing.expectEqual(@as(?u5, 0), changed.memory_type);
    try std.testing.expectEqual(@as(?u8, 9), changed.gpu_mask);
    try std.testing.expectEqual(@as(u15, 3), changed.mask);
    bytes = 99;
    const before = storage;
    try std.testing.expectEqual(E.einval.raw(), direct_fn(@intFromPtr(&storage), 1, 0, 0x4000, 3, 3, 0, &bytes));
    try std.testing.expectEqual(@as(u64, 99), bytes);
    try std.testing.expectEqualSlices(u8, &before, &storage);
    try std.testing.expectEqual(E.efault.raw(), direct_fn(1, 0x1000000000, 0, 0x4000, 3, 3, 0, &bytes));
}

test "AMM native submissions share physical aliases move data and apply masked permissions" {
    reset();
    defer reset();
    apr.reset();
    defer apr.reset();
    var space = try host.AddressSpace.initWithDirectMemory(std.testing.allocator, 0x100000);
    defer space.deinit();
    memory.init(std.testing.allocator);
    defer memory.deinit();
    memory.attachAddressSpace(&space);
    defer memory.attachAddressSpace(null);
    const source: u64 = 0x1000000000;
    const duplicate = source + 0x40000;
    const moved = duplicate + 0x40000;
    const size: u64 = 0x10000;
    var physical: i64 = -1;
    try std.testing.expectEqual(errno.ok, giveDirectMemory(0, 0x100000, size, size, 0, &physical));
    var buffer: [64]u8 = @splat(0);
    var count: u64 = 0;
    const base = @intFromPtr(&buffer);
    try std.testing.expectEqual(errno.ok, writeMapDirectWithGpuMaskIdCommand(base, source, @intCast(physical), size, 3, 0x33, 4, &count));
    try std.testing.expect(space.query(source, false) == null);
    var result = Result{ .result = -1, .error_offset = 99 };
    var id: u32 = 0;
    try std.testing.expectEqual(errno.ok, callIndirectBuffer2(1, base, count, &result, &id));
    try std.testing.expectEqualDeep(Result{}, result);
    try std.testing.expectEqual(errno.ok, waitCompletion(id));
    try std.testing.expectEqual(E.esrch.raw(), waitCompletion(id));
    try space.write(source, "shared data");
    try std.testing.expectEqual(@as(i32, 3), space.query(source, false).?.memory_type);
    try std.testing.expectEqual(@as(u8, 4), space.query(source, false).?.gpu_mask_id);
    try std.testing.expectEqual(errno.ok, writeMultiMapWithGpuMaskIdCommand(base, duplicate, source, size, 3, 7, &count));
    try std.testing.expectEqual(errno.ok, callIndirectBuffer(0, base, count));
    var readback: [11]u8 = undefined;
    try space.read(duplicate, &readback);
    try std.testing.expectEqualStrings("shared data", &readback);
    try space.write(duplicate, "alias write");
    try space.read(source, &readback);
    try std.testing.expectEqualStrings("alias write", &readback);
    try std.testing.expectEqual(errno.ok, writeRemapCommand(base, moved, duplicate, size, 3, &count));
    try std.testing.expectEqual(errno.ok, callIndirectBuffer(0, base, count));
    try std.testing.expect(space.query(duplicate, false) == null);
    try space.read(moved, &readback);
    try std.testing.expectEqualStrings("alias write", &readback);
    try std.testing.expectEqual(errno.ok, writeModifyMtypeProtectWithGpuMaskIdCommand(base, source, 0x4000, 10, 1, 3, 8, &count));
    try std.testing.expectEqual(errno.ok, callIndirectBuffer(0, base, count));
    const first = space.query(source, false).?;
    try std.testing.expectEqual(@as(i32, 0x31), first.protection_bits);
    try std.testing.expectEqual(@as(i32, 10), first.memory_type);
    try std.testing.expectEqual(@as(u8, 8), first.gpu_mask_id);
    try std.testing.expect(!space.isWritable(source, 4));
    try std.testing.expectEqual(@as(i32, 0x33), space.query(source + 0x4000, false).?.protection_bits);
    try std.testing.expectEqual(@as(u8, 4), space.query(source + 0x4000, false).?.gpu_mask_id);
    try std.testing.expectEqual(errno.ok, writeUnmapCommand(base, moved, size, &count));
    try std.testing.expectEqual(errno.ok, callIndirectBuffer(0, base, count));
    try std.testing.expect(space.query(moved, false) == null);
    try space.read(source, &readback);
    try std.testing.expectEqualStrings("alias write", &readback);
}

test "AMM submission rejects malformed tails and reports execution error offsets" {
    reset();
    defer reset();
    apr.reset();
    defer apr.reset();
    var space = try host.AddressSpace.initWithDirectMemory(std.testing.allocator, 0x100000);
    defer space.deinit();
    memory.init(std.testing.allocator);
    defer memory.deinit();
    memory.attachAddressSpace(&space);
    defer memory.attachAddressSpace(null);
    const address: u64 = 0x1000000000;
    var donation: i64 = -1;
    try std.testing.expectEqual(errno.ok, giveDirectMemory(0, 0x100000, 0x10000, 0x10000, 1, &donation));
    var buffer: [64]u8 = @splat(0xff);
    const base = @intFromPtr(&buffer);
    var bytes: u64 = 0;
    try std.testing.expectEqual(errno.ok, writeMapCommand2(base, address, 0x10000, 0, 3, 0, &bytes));
    var result = Result{};
    var id: u32 = 12345;
    try std.testing.expectEqual(E.einval.raw(), callIndirectBuffer2(0, base, bytes + 4, &result, &id));
    try std.testing.expectEqual(@as(u32, 12), result.error_offset);
    try std.testing.expectEqual(@as(u32, 12345), id);
    try std.testing.expect(space.query(address, false) == null);
    var second: u64 = 0;
    try std.testing.expectEqual(errno.ok, writeModifyProtectCommand(base + bytes, address + 0x20000, 0x4000, 1, 3, &second));
    try std.testing.expectEqual(E.eacces.raw(), callIndirectBuffer2(0, base, bytes + second, &result, &id));
    try std.testing.expectEqual(@as(u32, 12), result.error_offset);
    try std.testing.expectEqual(E.eacces.raw(), waitCompletion(id));
    try std.testing.expectEqual(@as(?u64, @intCast(donation)), space.query(address, false).?.backing_offset);
    try std.testing.expectEqual(E.einval.raw(), callIndirectBuffer(3, 0, 0));
    try std.testing.expectEqual(E.efault.raw(), callIndirectBuffer(0, 1, 4));
    try std.testing.expectEqual(errno.ok, callIndirectBuffer3(0, 0, 0, &id));
    try std.testing.expectEqual(errno.ok, waitCompletion(id));
    var params = [_]u64{ 56, 9, 9, 9, 9, 9, 9 };
    try std.testing.expectEqual(errno.ok, getParam(&params));
    try std.testing.expectEqualSlices(u64, &.{ 56, 0x1000000000, 0x2000000000, 0x1800000000, 0x2000000000, 0, 0 }, &params);
    try std.testing.expectEqual(errno.ok, writeUnmapCommand(base, address, 0x10000, &bytes));
    try std.testing.expectEqual(E.efault.raw(), callIndirectBuffer2(0, base, bytes, @ptrFromInt(address), &id));
    try std.testing.expect(space.query(address, false) == null);
}

test "AMM aliases retain sub-page backing and reject destructive destination conflicts" {
    var space = try host.AddressSpace.initWithDirectMemory(std.testing.allocator, 0x100000);
    defer space.deinit();
    memory.init(std.testing.allocator);
    defer memory.deinit();
    memory.attachAddressSpace(&space);
    defer memory.attachAddressSpace(null);
    const source: u64 = 0x1000000000;
    const target = source + 0x40000;
    var physical: u64 = 0;
    try std.testing.expectEqual(errno.ok, memory.hostAllocateDirectMemory(0, 0x100000, 0x10000, 0x10000, 0, &physical));
    try std.testing.expectEqual(errno.ok, memory.hostMapDirectMemoryFixed(source, 0x10000, 3, physical));
    try space.write(source + 0x4000, "fragment");
    try std.testing.expectEqual(errno.ok, memory.hostAliasDirectMemory(target, source + 0x4000, 0x4000, 3, null, false));
    var data: [8]u8 = undefined;
    try space.read(target, &data);
    try std.testing.expectEqualStrings("fragment", &data);
    try space.write(target, "modified");
    try space.read(source + 0x4000, &data);
    try std.testing.expectEqualStrings("modified", &data);
    try std.testing.expectEqual(E.eexist.raw(), memory.hostAliasDirectMemory(target, source, 0x4000, 3, null, true));
    try std.testing.expect(space.isWritable(source, 0x10000));
    try std.testing.expectEqual(E.eacces.raw(), memory.hostAliasDirectMemory(target + 0x40000, source + 0xc000, 0x8000, 3, null, true));
    try std.testing.expect(space.query(target + 0x40000, false) == null);
}

test "AMM failed automatic mappings return donated slices and new physical allocations" {
    apr.reset();
    defer apr.reset();
    var space = try host.AddressSpace.initWithDirectMemory(std.testing.allocator, 0x100000);
    defer space.deinit();
    memory.init(std.testing.allocator);
    defer memory.deinit();
    memory.attachAddressSpace(&space);
    defer memory.attachAddressSpace(null);
    const address: u64 = 0x1000000000;
    try std.testing.expectEqual(E.einval.raw(), apr.mapAutoMemory(1, 0x10000, 0, 3));
    var donated: i64 = -1;
    try std.testing.expectEqual(errno.ok, giveDirectMemory(0, 0x100000, 0x10000, 0x10000, 1, &donated));
    try std.testing.expectEqual(@as(i64, 0), donated);
    try std.testing.expectEqual(E.einval.raw(), apr.mapAutoMemory(1, 0x10000, 0, 3));
    try std.testing.expectEqual(errno.ok, apr.mapAutoMemory(address, 0x10000, 0, 3));
    try std.testing.expectEqual(@as(?u64, 0), space.query(address, false).?.backing_offset);
}
