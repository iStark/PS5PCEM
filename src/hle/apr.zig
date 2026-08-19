// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! APR file identifiers backed by the title's read-only `/app0` mount.
//!
//! The accelerator API resolves paths once and carries compact identifiers in
//! later command buffers. Identifiers are process-local; the path and file size
//! are retained here so deferred AMPR reads can reopen the same title file
//! without exposing host paths or holding descriptors indefinitely.

const std = @import("std");
const filesystem = @import("filesystem.zig");
const memory = @import("libs/kernel_memory.zig");
const errno = @import("errno.zig");

pub const maximum_files: usize = 256;
pub const maximum_path: usize = 1024;
pub const maximum_command_buffers: usize = 32;
pub const maximum_reads_per_buffer: usize = 32;
pub const maximum_writes_per_buffer: usize = 32;
pub const maximum_completions_per_buffer: usize = 32;
pub const maximum_maps_per_buffer: usize = 32;
pub const maximum_ops_per_buffer: usize = 128;
pub const maximum_auto_pool: usize = 8;
pub const maximum_submissions: usize = 64;
pub const maximum_read_bytes: usize = 4 * 1024 * 1024 * 1024;
pub const maximum_file_offset: u64 = 0x0000_0100_0000_0000;
pub const amm_page_size: u64 = 0x4000;

pub const Error = error{
    InvalidPath,
    FileTableFull,
    UnknownFile,
    FileNotFound,
    IoFailed,
    InvalidCommandBuffer,
    CommandBufferTableFull,
    TooManyCommands,
    InvalidRead,
    SubmissionTableFull,
    UnknownSubmission,
    OutOfDirectMemory,
    MappingFailed,
};

pub const ResolvedFile = struct {
    identifier: u32,
    size: u64,
};

const FileEntry = struct {
    active: bool = false,
    identifier: u32 = 0,
    size: u64 = 0,
    path_bytes: [maximum_path]u8 = undefined,
    path_length: usize = 0,

    fn path(self: *const FileEntry) []const u8 {
        return self.path_bytes[0..self.path_length];
    }
};

pub const ReadCommand = struct {
    file_identifier: u32,
    destination: u64,
    size: usize,
    file_offset: u64,
};

pub const CommandBufferInfo = struct {
    storage_address: u64,
    storage_size: usize,
    write_offset: usize,
    command_count: usize,
};

/// Next destination and file offset after a recorded read. Gather reuses the
/// destination, scatter reuses the offset, and both keep the file identifier.
pub const GatherScatterCursor = struct {
    file_identifier: u32,
    destination: u64,
    file_offset: u64,
};

pub const CompletionCommand = struct {
    queue_handle: i64,
    ident: u64,
    completion_token: u64,
    user_data: u64,
};

pub const WriteCommand = struct {
    destination: u64,
    value: u64,
};

pub const AmmKind = enum {
    map_auto,
    map_direct,
    unmap,
};

pub const AmmMapCommand = struct {
    kind: AmmKind,
    va: u64,
    dmem_offset: u64 = 0,
    size: u64,
    memory_type: i32 = 0,
    protection: i32 = 0,
};

const OpKind = enum { read, write, completion, map };

const Op = struct {
    kind: OpKind,
    index: u8,
};

const AutoPoolRange = struct {
    start: u64 = 0,
    size: u64 = 0,
    used: u64 = 0,
};

pub const CompletionSink = *const fn (CompletionCommand) bool;

const CommandBuffer = struct {
    active: bool = false,
    address: u64 = 0,
    storage_address: u64 = 0,
    storage_size: usize = 0,
    record_bytes: usize = 0,
    command_count: usize = 0,
    reads: [maximum_reads_per_buffer]ReadCommand = undefined,
    read_count: usize = 0,
    completions: [maximum_completions_per_buffer]CompletionCommand = undefined,
    completion_count: usize = 0,
    writes: [maximum_writes_per_buffer]WriteCommand = undefined,
    write_count: usize = 0,
    maps: [maximum_maps_per_buffer]AmmMapCommand = undefined,
    map_count: usize = 0,
    ops: [maximum_ops_per_buffer]Op = undefined,
    op_count: usize = 0,
    cursor: ?GatherScatterCursor = null,
    map_active: bool = false,
};

const Submission = struct {
    active: bool = false,
    identifier: u32 = 0,
    complete: bool = false,
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
var files: [maximum_files]FileEntry = [_]FileEntry{.{}} ** maximum_files;
var next_identifier: u32 = 1;
var command_buffers: [maximum_command_buffers]CommandBuffer = [_]CommandBuffer{.{}} ** maximum_command_buffers;
var submissions: [maximum_submissions]Submission = [_]Submission{.{}} ** maximum_submissions;
var next_submission_identifier: u32 = 1;
var completion_sink: ?CompletionSink = null;
var auto_pool: [maximum_auto_pool]AutoPoolRange = [_]AutoPoolRange{.{}} ** maximum_auto_pool;
var auto_pool_count: usize = 0;

pub fn attachCompletionSink(sink: ?CompletionSink) void {
    lock.lock();
    defer lock.unlock();
    completion_sink = sink;
}

pub fn reset() void {
    lock.lock();
    defer lock.unlock();
    files = [_]FileEntry{.{}} ** maximum_files;
    next_identifier = 1;
    command_buffers = [_]CommandBuffer{.{}} ** maximum_command_buffers;
    submissions = [_]Submission{.{}} ** maximum_submissions;
    next_submission_identifier = 1;
    auto_pool = [_]AutoPoolRange{.{}} ** maximum_auto_pool;
    auto_pool_count = 0;
}

pub fn resolve(path: []const u8) Error!ResolvedFile {
    if (path.len == 0 or path.len > maximum_path) return error.InvalidPath;
    var info: filesystem.Stat = undefined;
    filesystem.stat(path, &info) catch |err| return switch (err) {
        error.NotFound, error.NotAttached => error.FileNotFound,
        else => error.IoFailed,
    };
    if (info.size < 0) return error.IoFailed;

    lock.lock();
    defer lock.unlock();
    var free_slot: ?*FileEntry = null;
    for (&files) |*entry| {
        if (!entry.active) {
            if (free_slot == null) free_slot = entry;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(entry.path(), path)) {
            return .{ .identifier = entry.identifier, .size = entry.size };
        }
    }
    const entry = free_slot orelse return error.FileTableFull;
    const identifier = next_identifier;
    next_identifier +%= 1;
    if (next_identifier == 0) next_identifier = 1;
    entry.* = .{
        .active = true,
        .identifier = identifier,
        .size = @intCast(info.size),
        .path_length = path.len,
    };
    @memcpy(entry.path_bytes[0..path.len], path);
    return .{ .identifier = identifier, .size = entry.size };
}

pub fn read(identifier: u32, offset: u64, destination: []u8) Error!usize {
    var path_bytes: [maximum_path]u8 = undefined;
    const path = blk: {
        lock.lock();
        defer lock.unlock();
        for (files) |entry| {
            if (!entry.active or entry.identifier != identifier) continue;
            @memcpy(path_bytes[0..entry.path_length], entry.path());
            break :blk path_bytes[0..entry.path_length];
        }
        return error.UnknownFile;
    };
    const descriptor = filesystem.open(path, filesystem.O.rdonly) catch |err| return switch (err) {
        error.NotFound, error.NotAttached => error.FileNotFound,
        else => error.IoFailed,
    };
    defer filesystem.close(descriptor) catch {};
    return filesystem.pread(descriptor, destination, offset) catch error.IoFailed;
}

pub fn constructCommandBuffer(address: u64) Error!void {
    if (address == 0) return error.InvalidCommandBuffer;
    lock.lock();
    defer lock.unlock();
    if (findCommandBufferLocked(address)) |buffer| {
        buffer.* = .{ .active = true, .address = address };
        return;
    }
    for (&command_buffers) |*buffer| {
        if (buffer.active) continue;
        buffer.* = .{ .active = true, .address = address };
        return;
    }
    return error.CommandBufferTableFull;
}

pub fn destroyCommandBuffer(address: u64) Error!void {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    buffer.* = .{};
}

pub fn setCommandBufferStorage(address: u64, storage_address: u64, storage_size: usize) Error!void {
    if (storage_address == 0 or storage_size == 0) return error.InvalidCommandBuffer;
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    buffer.storage_address = storage_address;
    buffer.storage_size = storage_size;
}

pub fn resetCommandBuffer(address: u64) Error!void {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    buffer.read_count = 0;
    buffer.completion_count = 0;
    buffer.write_count = 0;
    buffer.map_count = 0;
    buffer.op_count = 0;
    buffer.record_bytes = 0;
    buffer.command_count = 0;
    buffer.cursor = null;
    buffer.map_active = false;
}

pub fn commandBufferInfo(address: u64) Error!CommandBufferInfo {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    return .{
        .storage_address = buffer.storage_address,
        .storage_size = buffer.storage_size,
        .write_offset = buffer.record_bytes,
        .command_count = buffer.command_count,
    };
}

pub fn gatherScatterCursor(address: u64) Error!?GatherScatterCursor {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    return buffer.cursor;
}

pub fn clearGatherScatterCursor(address: u64) Error!void {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    buffer.cursor = null;
}

pub fn appendRecordBytes(address: u64, record_bytes: usize) Error!void {
    if (record_bytes == 0) return error.InvalidCommandBuffer;
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    const next = std.math.add(usize, buffer.record_bytes, record_bytes) catch return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next > buffer.storage_size) return error.InvalidCommandBuffer;
    buffer.record_bytes = next;
    buffer.command_count += 1;
}

pub fn appendRead(address: u64, command: ReadCommand) Error!void {
    return appendReadRecord(address, command, 0x30);
}

pub fn appendReadRecord(address: u64, command: ReadCommand, record_bytes: usize) Error!void {
    if (command.destination == 0 or command.size == 0 or command.size > maximum_read_bytes or
        command.file_offset >= maximum_file_offset or record_bytes == 0)
    {
        return error.InvalidRead;
    }
    const next_destination = std.math.add(u64, command.destination, command.size) catch
        return error.InvalidRead;
    const next_offset = std.math.add(u64, command.file_offset, command.size) catch
        return error.InvalidRead;
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    if (buffer.read_count >= buffer.reads.len) return error.TooManyCommands;
    if (findFileLocked(command.file_identifier) == null) return error.UnknownFile;
    const next_bytes = std.math.add(usize, buffer.record_bytes, record_bytes) catch
        return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next_bytes > buffer.storage_size) return error.InvalidCommandBuffer;
    try pushOpLocked(buffer, .read, buffer.read_count);
    buffer.reads[buffer.read_count] = command;
    buffer.read_count += 1;
    buffer.record_bytes = next_bytes;
    buffer.command_count += 1;
    buffer.cursor = .{
        .file_identifier = command.file_identifier,
        .destination = next_destination,
        .file_offset = next_offset,
    };
}

pub fn appendCompletion(address: u64, command: CompletionCommand) Error!void {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    if (buffer.completion_count >= buffer.completions.len) return error.TooManyCommands;
    const next_bytes = std.math.add(usize, buffer.record_bytes, 0x30) catch
        return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next_bytes > buffer.storage_size) return error.InvalidCommandBuffer;
    try pushOpLocked(buffer, .completion, buffer.completion_count);
    buffer.completions[buffer.completion_count] = command;
    buffer.completion_count += 1;
    buffer.record_bytes = next_bytes;
    buffer.command_count += 1;
}

pub fn appendWrite(address: u64, command: WriteCommand, record_bytes: usize) Error!void {
    if (command.destination == 0 or record_bytes == 0) return error.InvalidCommandBuffer;
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    if (buffer.write_count >= buffer.writes.len) return error.TooManyCommands;
    const next_bytes = std.math.add(usize, buffer.record_bytes, record_bytes) catch
        return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next_bytes > buffer.storage_size) return error.InvalidCommandBuffer;
    try pushOpLocked(buffer, .write, buffer.write_count);
    buffer.writes[buffer.write_count] = command;
    buffer.write_count += 1;
    buffer.record_bytes = next_bytes;
    buffer.command_count += 1;
}

pub fn appendAmmMap(address: u64, command: AmmMapCommand, record_bytes: usize) Error!void {
    if (command.va == 0 or command.size == 0 or record_bytes == 0) return error.InvalidCommandBuffer;
    if (command.va & (amm_page_size - 1) != 0 or command.size & (amm_page_size - 1) != 0) {
        return error.InvalidCommandBuffer;
    }
    _ = std.math.add(u64, command.va, command.size) catch return error.InvalidCommandBuffer;
    if (command.kind == .map_direct and command.dmem_offset & (amm_page_size - 1) != 0) {
        return error.InvalidCommandBuffer;
    }
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    if (buffer.map_count >= buffer.maps.len) return error.TooManyCommands;
    const next_bytes = std.math.add(usize, buffer.record_bytes, record_bytes) catch
        return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next_bytes > buffer.storage_size) return error.InvalidCommandBuffer;
    try pushOpLocked(buffer, .map, buffer.map_count);
    buffer.maps[buffer.map_count] = command;
    buffer.map_count += 1;
    buffer.record_bytes = next_bytes;
    buffer.command_count += 1;
}

pub fn giveAutoPool(start: u64, size: u64) Error!void {
    if (size == 0 or size & (amm_page_size - 1) != 0) return error.InvalidCommandBuffer;
    lock.lock();
    defer lock.unlock();
    if (auto_pool_count >= auto_pool.len) return error.OutOfDirectMemory;
    auto_pool[auto_pool_count] = .{ .start = start, .size = size, .used = 0 };
    auto_pool_count += 1;
}

pub fn setMapActive(address: u64, active: bool) Error!void {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    buffer.map_active = active;
}

pub fn mapActive(address: u64) Error!bool {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    return buffer.map_active;
}

pub fn submitCommandBuffer(address: u64) Error!u32 {
    var pending: [maximum_reads_per_buffer]ReadCommand = undefined;
    var pending_writes: [maximum_writes_per_buffer]WriteCommand = undefined;
    var pending_completions: [maximum_completions_per_buffer]CompletionCommand = undefined;
    var pending_maps: [maximum_maps_per_buffer]AmmMapCommand = undefined;
    var pending_ops: [maximum_ops_per_buffer]Op = undefined;
    var sink: ?CompletionSink = null;
    const counts = blk: {
        lock.lock();
        defer lock.unlock();
        const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
        @memcpy(pending[0..buffer.read_count], buffer.reads[0..buffer.read_count]);
        @memcpy(pending_writes[0..buffer.write_count], buffer.writes[0..buffer.write_count]);
        @memcpy(pending_completions[0..buffer.completion_count], buffer.completions[0..buffer.completion_count]);
        @memcpy(pending_maps[0..buffer.map_count], buffer.maps[0..buffer.map_count]);
        @memcpy(pending_ops[0..buffer.op_count], buffer.ops[0..buffer.op_count]);
        for (pending_maps[0..buffer.map_count]) |*command| {
            if (command.kind != .map_auto) continue;
            command.dmem_offset = takeAutoLocked(command.size, command.memory_type) orelse
                return error.OutOfDirectMemory;
        }
        sink = completion_sink;
        break :blk .{
            buffer.read_count,
            buffer.write_count,
            buffer.completion_count,
            buffer.map_count,
            buffer.op_count,
        };
    };
    for (pending_ops[0..counts[4]]) |op| {
        switch (op.kind) {
            .read => try applyRead(pending[op.index]),
            .write => try applyWrite(pending_writes[op.index]),
            .completion => try applyCompletion(pending_completions[op.index], sink),
            .map => try applyAmmMap(pending_maps[op.index]),
        }
    }

    lock.lock();
    defer lock.unlock();
    for (&submissions) |*submission| {
        if (submission.active) continue;
        const identifier = next_submission_identifier;
        next_submission_identifier +%= 1;
        if (next_submission_identifier == 0) next_submission_identifier = 1;
        submission.* = .{ .active = true, .identifier = identifier, .complete = true };
        return identifier;
    }
    return error.SubmissionTableFull;
}

pub fn waitCommandBuffer(identifier: u32) Error!void {
    lock.lock();
    defer lock.unlock();
    for (&submissions) |*submission| {
        if (!submission.active or submission.identifier != identifier) continue;
        if (!submission.complete) return error.IoFailed;
        submission.* = .{};
        return;
    }
    return error.UnknownSubmission;
}

fn pushOpLocked(buffer: *CommandBuffer, kind: OpKind, index: usize) Error!void {
    if (buffer.op_count >= buffer.ops.len) return error.TooManyCommands;
    buffer.ops[buffer.op_count] = .{ .kind = kind, .index = @intCast(index) };
    buffer.op_count += 1;
}

fn takeAutoLocked(size: u64, memory_type: i32) ?u64 {
    for (auto_pool[0..auto_pool_count]) |*range| {
        const used = (range.used + (amm_page_size - 1)) & ~(amm_page_size - 1);
        if (used <= range.size and size <= range.size - used) {
            const offset = range.start + used;
            range.used = used + size;
            return offset;
        }
    }
    var allocated: u64 = 0;
    if (memory.hostAllocateDirectMemory(0, memory.direct_memory_size, size, amm_page_size, memory_type, &allocated) != errno.ok) {
        return null;
    }
    return allocated;
}

fn applyRead(command: ReadCommand) Error!void {
    if (!memory.isGuestRangeAccessible(command.destination, command.size)) return error.InvalidRead;
    const destination: [*]u8 = @ptrFromInt(command.destination);
    _ = try read(command.file_identifier, command.file_offset, destination[0..command.size]);
}

fn applyWrite(command: WriteCommand) Error!void {
    if (!memory.isGuestRangeAccessible(command.destination, 8)) return error.InvalidRead;
    const destination: *[8]u8 = @ptrFromInt(command.destination);
    std.mem.writeInt(u64, destination, command.value, .little);
}

fn applyCompletion(command: CompletionCommand, sink: ?CompletionSink) Error!void {
    const callback = sink orelse return error.IoFailed;
    if (!callback(command)) return error.IoFailed;
}

fn applyAmmMap(command: AmmMapCommand) Error!void {
    const status = switch (command.kind) {
        .unmap => memory.hostUnmap(command.va, command.size),
        .map_auto, .map_direct => memory.hostMapDirectMemoryFixed(
            command.va,
            command.size,
            command.protection,
            command.dmem_offset,
        ),
    };
    if (status == errno.ok) return;
    if (status == errno.KernelError.eagain.raw()) return error.OutOfDirectMemory;
    return error.MappingFailed;
}

fn findCommandBufferLocked(address: u64) ?*CommandBuffer {
    for (&command_buffers) |*buffer| {
        if (buffer.active and buffer.address == address) return buffer;
    }
    return null;
}

fn findFileLocked(identifier: u32) ?*FileEntry {
    for (&files) |*entry| {
        if (entry.active and entry.identifier == identifier) return entry;
    }
    return null;
}

test "resolved files keep stable process-local identifiers" {
    reset();
    defer reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const file = try temporary.dir.createFile(io, "asset.bin", .{});
    try file.writeStreamingAll(io, "asset-data");
    file.close(io);
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();

    const first = try resolve("/app0/asset.bin");
    const second = try resolve("/app0/ASSET.BIN");
    try std.testing.expectEqual(first.identifier, second.identifier);
    try std.testing.expectEqual(@as(u64, 10), first.size);
    var bytes: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try read(first.identifier, 6, &bytes));
    try std.testing.expectEqualStrings("data", bytes[0..4]);
}

test "a deferred APR read completes through its submission identifier" {
    reset();
    defer reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const file = try temporary.dir.createFile(io, "scene.dat", .{});
    try file.writeStreamingAll(io, "scene-bytes");
    file.close(io);
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();

    const resolved = try resolve("/app0/scene.dat");
    var destination: [11]u8 = undefined;
    try constructCommandBuffer(0x1000);
    try setCommandBufferStorage(0x1000, 0x2000, 0x10000);
    try appendRead(0x1000, .{
        .file_identifier = resolved.identifier,
        .destination = @intFromPtr(&destination),
        .size = destination.len,
        .file_offset = 0,
    });
    const submission = try submitCommandBuffer(0x1000);
    try std.testing.expectEqualStrings("scene-bytes", &destination);
    try waitCommandBuffer(submission);
    try std.testing.expectError(error.UnknownSubmission, waitCommandBuffer(submission));
}

test "APR reads honor file offsets and allow a short read at EOF" {
    reset();
    defer reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const file = try temporary.dir.createFile(io, "bundle.dat", .{});
    try file.writeStreamingAll(io, "header-payload");
    file.close(io);
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();

    const resolved = try resolve("/app0/bundle.dat");
    var destination = [_]u8{0xaa} ** 10;
    try constructCommandBuffer(0x3000);
    try setCommandBufferStorage(0x3000, 0x4000, 0x10000);
    try appendRead(0x3000, .{
        .file_identifier = resolved.identifier,
        .destination = @intFromPtr(&destination),
        .size = destination.len,
        .file_offset = 7,
    });
    const submission = try submitCommandBuffer(0x3000);
    try std.testing.expectEqualStrings("payload", destination[0..7]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xaa, 0xaa }, destination[7..]);
    try waitCommandBuffer(submission);
}

test "a recorded read advances the gather-scatter cursor" {
    reset();
    defer reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const file = try temporary.dir.createFile(io, "chunks.bin", .{});
    try file.writeStreamingAll(io, "abcdefghijkl");
    file.close(io);
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();

    const resolved = try resolve("/app0/chunks.bin");
    var destination: [12]u8 = undefined;
    try constructCommandBuffer(0x5000);
    try setCommandBufferStorage(0x5000, 0x6000, 0x10000);
    try appendRead(0x5000, .{
        .file_identifier = resolved.identifier,
        .destination = @intFromPtr(&destination),
        .size = 4,
        .file_offset = 0,
    });
    const after_first = (try gatherScatterCursor(0x5000)).?;
    try std.testing.expectEqual(resolved.identifier, after_first.file_identifier);
    try std.testing.expectEqual(@intFromPtr(&destination) + 4, after_first.destination);
    try std.testing.expectEqual(@as(u64, 4), after_first.file_offset);

    try appendReadRecord(0x5000, .{
        .file_identifier = after_first.file_identifier,
        .destination = after_first.destination,
        .size = 4,
        .file_offset = 4,
    }, 0x08);
    try appendReadRecord(0x5000, .{
        .file_identifier = resolved.identifier,
        .destination = @intFromPtr(&destination) + 8,
        .size = 4,
        .file_offset = 8,
    }, 0x0c);
    _ = try submitCommandBuffer(0x5000);
    try std.testing.expectEqualStrings("abcdefghijkl", &destination);

    try clearGatherScatterCursor(0x5000);
    try std.testing.expect((try gatherScatterCursor(0x5000)) == null);
    try std.testing.expectEqual(@as(usize, 0x30 + 0x08 + 0x0c), (try commandBufferInfo(0x5000)).write_offset);
}

test "a recorded AMPR write publishes its value on submit" {
    reset();
    defer reset();
    var label: u64 = 0x1111_2222_3333_4444;
    try constructCommandBuffer(0x7000);
    try setCommandBufferStorage(0x7000, 0x8000, 0x10000);
    try appendWrite(0x7000, .{ .destination = @intFromPtr(&label), .value = 0xaaaa_bbbb_cccc_dddd }, 0x20);
    _ = try submitCommandBuffer(0x7000);
    try std.testing.expectEqual(@as(u64, 0xaaaa_bbbb_cccc_dddd), label);
}
