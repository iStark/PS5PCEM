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
const builtin = @import("builtin");
const runtime = @import("libs/kernel_runtime.zig");
const memory_module = @import("memory");
const packets = @import("apr_packets.zig");
const mapper = @import("libs/kernel_mapper.zig");
pub const counters = @import("ampr_counters.zig");

pub const maximum_path: usize = 1024;
pub const maximum_auto_pool: usize = 8;
pub const maximum_submissions: usize = 64;
pub const maximum_cached_files: usize = 64;
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
    OutOfMemory,
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
    descriptor: i32 = -1,
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
    bytes_read_address: u64 = 0,
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

pub const CounterRead = struct {
    destination: u64,
    counter: u8 = 0,
    source: enum { time, word, pair },
};
pub const CounterCommand = union(enum) {
    write: counters.Write,
    wait: counters.Wait,
    read: CounterRead,
};

const Op = union(enum) {
    read: ReadCommand,
    write: WriteCommand,
    completion: CompletionCommand,
    map: AmmMapCommand,
    counter: CounterCommand,
    wait_address: packets.AddressWait,
    native_map: @import("amm_packets.zig").Command,
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
    // The guest storage capacity limits recording, not an arbitrary number of
    // reads or an 8-bit index. Keep values in order for independent submissions.
    ops: std.ArrayList(Op) = .empty,
    native_offsets: std.ArrayList(u32) = .empty,
    cursor: ?GatherScatterCursor = null,
    map_active: bool = false,

    fn deinit(self: *CommandBuffer) void {
        self.ops.deinit(file_allocator);
        self.native_offsets.deinit(file_allocator);
        self.* = .{};
    }

    fn clone(self: *const CommandBuffer) Error!CommandBuffer {
        var result = self.*;
        result.ops = .empty;
        result.native_offsets = .empty;
        errdefer result.deinit();
        try result.ops.appendSlice(file_allocator, self.ops.items);
        try result.native_offsets.appendSlice(file_allocator, self.native_offsets.items);
        return result;
    }
};

const Submission = struct {
    active: bool = false,
    identifier: u32 = 0,
    complete: bool = false,
    failure: ?Error = null,
    worker: ?std.Thread = null,
    // Plain submits publish no identifier, so no waiter can exist.
    // Only these may be reclaimed by a later submit.
    reclaimable: bool = false,
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
// Resolved IDs live for the process, independently of the bounded descriptor
// cache. A scene can reference thousands of files without opening them all.
const file_allocator = std.heap.page_allocator;
var files: std.ArrayList(FileEntry) = .empty;
var file_paths: std.StringHashMapUnmanaged(u32) = .empty;
var path_arena = std.heap.ArenaAllocator.init(file_allocator);
var cached_file_count: usize = 0;
var command_buffers: std.ArrayList(CommandBuffer) = .empty;
var submissions: [maximum_submissions]Submission = [_]Submission{.{}} ** maximum_submissions;
var next_submission_identifier: u32 = 1;
var completion_sink: ?CompletionSink = null;
var auto_pool: [maximum_auto_pool]AutoPoolRange = [_]AutoPoolRange{.{}} ** maximum_auto_pool;
var auto_pool_count: usize = 0;
var counter_bank = counters.Bank{};
var stopping = std.atomic.Value(bool).init(false);

pub fn attachCompletionSink(sink: ?CompletionSink) void {
    lock.lock();
    defer lock.unlock();
    completion_sink = sink;
}

pub fn reset() void {
    // Reset is called after guest submitters have stopped. Join before clearing
    // counters, file handles or guest mappings referenced by a deferred buffer.
    stopping.store(true, .release);
    for (&submissions) |*submission| {
        if (submission.worker) |worker| worker.join();
    }
    var descriptors: [maximum_cached_files]i32 = undefined;
    var descriptor_count: usize = 0;
    lock.lock();
    for (files.items) |entry| {
        if (entry.active and entry.descriptor >= 0 and descriptor_count < descriptors.len) {
            descriptors[descriptor_count] = entry.descriptor;
            descriptor_count += 1;
        }
    }
    file_paths.deinit(file_allocator);
    file_paths = .empty;
    path_arena.deinit();
    path_arena = std.heap.ArenaAllocator.init(file_allocator);
    files.deinit(file_allocator);
    files = .empty;
    cached_file_count = 0;
    for (command_buffers.items) |*buffer| buffer.deinit();
    command_buffers.deinit(file_allocator);
    command_buffers = .empty;
    submissions = [_]Submission{.{}} ** maximum_submissions;
    next_submission_identifier = 1;
    auto_pool = [_]AutoPoolRange{.{}} ** maximum_auto_pool;
    auto_pool_count = 0;
    counter_bank.reset();
    stopping.store(false, .release);
    lock.unlock();

    for (descriptors[0..descriptor_count]) |descriptor| {
        filesystem.close(descriptor) catch {};
    }
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
    var folded_path: [maximum_path]u8 = undefined;
    const key = std.ascii.lowerString(&folded_path, path);
    if (file_paths.get(key)) |identifier| {
        const entry = findFileLocked(identifier).?;
        return .{ .identifier = identifier, .size = entry.size };
    }
    if (files.items.len == std.math.maxInt(u32)) return error.FileTableFull;
    files.ensureUnusedCapacity(file_allocator, 1) catch return error.IoFailed;
    file_paths.ensureUnusedCapacity(file_allocator, 1) catch return error.IoFailed;
    const owned_key = path_arena.allocator().dupe(u8, key) catch return error.IoFailed;
    const identifier: u32 = @intCast(files.items.len + 1);
    const entry = files.addOneAssumeCapacity();
    entry.* = .{
        .active = true,
        .identifier = identifier,
        .size = @intCast(info.size),
        .path_length = path.len,
    };
    @memcpy(entry.path_bytes[0..path.len], path);
    file_paths.putAssumeCapacityNoClobber(owned_key, identifier);
    return .{ .identifier = identifier, .size = entry.size };
}

/// Describes a path previously resolved to an APR file identifier.
///
/// APR callers intentionally carry only the compact identifier after path
/// resolution.  Reusing the retained guest path here keeps metadata and later
/// deferred reads tied to the same mount instead of trying to interpret the
/// identifier as a normal file descriptor.
pub fn stat(identifier: u32, out: *filesystem.Stat) Error!void {
    var path_bytes: [maximum_path]u8 = undefined;
    const path_length = blk: {
        lock.lock();
        defer lock.unlock();
        const entry = findFileLocked(identifier) orelse return error.UnknownFile;
        @memcpy(path_bytes[0..entry.path_length], entry.path());
        break :blk entry.path_length;
    };

    filesystem.stat(path_bytes[0..path_length], out) catch |err| return switch (err) {
        error.NotFound, error.NotAttached => error.FileNotFound,
        else => error.IoFailed,
    };
}

/// Returns the cached size for a resolved file without opening it again.
pub fn fileSize(identifier: u32) Error!u64 {
    lock.lock();
    defer lock.unlock();
    const entry = findFileLocked(identifier) orelse return error.UnknownFile;
    return entry.size;
}

pub fn read(identifier: u32, offset: u64, destination: []u8) Error!usize {
    var path_bytes: [maximum_path]u8 = undefined;
    lock.lock();
    if (findFileLocked(identifier)) |entry| {
        if (entry.descriptor >= 0) {
            const descriptor = entry.descriptor;
            lock.unlock();
            return filesystem.pread(descriptor, destination, offset) catch error.IoFailed;
        }
        @memcpy(path_bytes[0..entry.path_length], entry.path());
        const path_length = entry.path_length;
        lock.unlock();

        const opened = filesystem.open(path_bytes[0..path_length], filesystem.O.rdonly) catch |err| return switch (err) {
            error.NotFound, error.NotAttached => error.FileNotFound,
            else => error.IoFailed,
        };

        // Several APR workers can discover the same uncached file together.
        // Keep the first descriptor and close the duplicates after publishing
        // it; positional reads make the shared descriptor safe for workers.
        var descriptor = opened;
        var transient = true;
        lock.lock();
        if (findFileLocked(identifier)) |current| {
            if (current.descriptor >= 0) {
                descriptor = current.descriptor;
            } else if (cached_file_count < maximum_cached_files) {
                current.descriptor = opened;
                cached_file_count += 1;
                transient = false;
            }
        } else {
            lock.unlock();
            filesystem.close(opened) catch {};
            return error.UnknownFile;
        }
        lock.unlock();
        if (descriptor != opened) filesystem.close(opened) catch {};
        defer if (transient and descriptor == opened) filesystem.close(opened) catch {};
        return filesystem.pread(descriptor, destination, offset) catch error.IoFailed;
    }
    lock.unlock();
    return error.UnknownFile;
}

pub fn constructCommandBuffer(address: u64) Error!void {
    if (address == 0) return error.InvalidCommandBuffer;
    lock.lock();
    defer lock.unlock();
    if (findCommandBufferLocked(address)) |buffer| {
        buffer.deinit();
        buffer.* = .{ .active = true, .address = address };
        return;
    }
    // Firmware holds dozens of file-read buffers at once (40 observed);
    // grow instead of capping at a guessed size. Reuse dead slots first so
    // tens of thousands of short-lived buffers do not grow the list forever.
    for (command_buffers.items) |*buffer| {
        if (!buffer.active) {
            buffer.* = .{ .active = true, .address = address };
            return;
        }
    }
    try command_buffers.append(file_allocator, .{ .active = true, .address = address });
}

pub fn destroyCommandBuffer(address: u64) Error!void {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    buffer.deinit();
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
    buffer.ops.clearRetainingCapacity();
    buffer.record_bytes = 0;
    buffer.command_count = 0;
    buffer.cursor = null;
    buffer.map_active = false;
}

pub fn clearCommandBuffer(address: u64) Error!void {
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    // Clear detaches storage and recorded ops but keeps the registration alive:
    // firmware reuses a buffer across files without reconstructing it.
    buffer.ops.clearRetainingCapacity();
    buffer.record_bytes = 0;
    buffer.command_count = 0;
    buffer.storage_address = 0;
    buffer.storage_size = 0;
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
    if (findFileLocked(command.file_identifier) == null) return error.UnknownFile;
    const next_bytes = std.math.add(usize, buffer.record_bytes, record_bytes) catch
        return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next_bytes > buffer.storage_size) return error.InvalidCommandBuffer;
    try buffer.ops.append(file_allocator, .{ .read = command });
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
    const next_bytes = std.math.add(usize, buffer.record_bytes, 0x30) catch
        return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next_bytes > buffer.storage_size) return error.InvalidCommandBuffer;
    try buffer.ops.append(file_allocator, .{ .completion = command });
    buffer.record_bytes = next_bytes;
    buffer.command_count += 1;
}

pub fn appendWrite(address: u64, command: WriteCommand, record_bytes: usize) Error!void {
    if (command.destination == 0 or record_bytes == 0) return error.InvalidCommandBuffer;
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    const next_bytes = std.math.add(usize, buffer.record_bytes, record_bytes) catch
        return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next_bytes > buffer.storage_size) return error.InvalidCommandBuffer;
    try buffer.ops.append(file_allocator, .{ .write = command });
    buffer.record_bytes = next_bytes;
    buffer.command_count += 1;
}

pub fn appendCounter(address: u64, command: CounterCommand, record_bytes: usize) Error!void {
    if (record_bytes == 0) return error.InvalidCommandBuffer;
    switch (command) {
        .write => |c| if (!counters.valid(c.counter, c.access)) return error.InvalidCommandBuffer,
        .wait => |c| if (!counters.valid(c.counter, c.access)) return error.InvalidCommandBuffer,
        .read => |c| {
            if (c.destination == 0 or c.destination & 7 != 0) return error.InvalidCommandBuffer;
            if (c.source != .time and !counters.valid(c.counter, if (c.source == .pair) .pair else .word)) return error.InvalidCommandBuffer;
        },
    }
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    const next_bytes = std.math.add(usize, buffer.record_bytes, record_bytes) catch return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next_bytes > buffer.storage_size) return error.InvalidCommandBuffer;
    try buffer.ops.append(file_allocator, .{ .counter = command });
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
    const next_bytes = std.math.add(usize, buffer.record_bytes, record_bytes) catch
        return error.InvalidCommandBuffer;
    if (buffer.storage_size != 0 and next_bytes > buffer.storage_size) return error.InvalidCommandBuffer;
    try buffer.ops.append(file_allocator, .{ .map = command });
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
    var error_offset: u32 = 0;
    return submitCommandBufferWithOffset(address, &error_offset);
}

/// Guest libSceAmpr can construct its own 24-byte header and packed stream.
/// Such objects never enter the HLE registry. Decode a private snapshot before
/// executing anything, so malformed tails cannot partially perform I/O.
fn snapshotNative(address: u64, error_offset: *u32) Error!CommandBuffer {
    if (!memory_module.isHostRangeReadable(address, @sizeOf(packets.Header))) return error.InvalidCommandBuffer;
    const header_ptr: *align(1) const packets.Header = @ptrFromInt(address);
    const header = header_ptr.*;
    if (header.offset == 0 or header.offset & 3 != 0 or header.offset > header.capacity or
        header.offset > 64 * 1024 * 1024 or header.count <= 0 or
        @as(u32, @intCast(header.count)) > header.offset / 4 or
        !memory_module.isHostRangeReadable(header.storage, header.offset)) return error.InvalidCommandBuffer;
    const source: [*]const u8 = @ptrFromInt(header.storage);
    const bytes = try file_allocator.dupe(u8, source[0..header.offset]);
    defer file_allocator.free(bytes);
    var pending: CommandBuffer = .{ .address = address };
    errdefer pending.deinit();
    var offset: usize = 0;
    while (offset < bytes.len) {
        error_offset.* = @intCast(offset);
        const decoded = packets.decode(bytes[offset..]) catch {
            const empty = std.mem.allEqual(u8, bytes, 0);
            reportNative(address, header, bytes, offset, if (empty)
                "zero-filled native stream (no encoded commands)"
            else
                "invalid native packet");
            if (empty) std.debug.print("[apr] refusing unwritten command storage; inspect the guest AMPR writer or compare PS5_HLE_BUNDLED_MODULES=libSceAmpr.sprx for a fakelib module\n", .{});
            return error.InvalidCommandBuffer;
        };
        const op: ?Op = switch (decoded.command) {
            .read => |command| blk: {
                const cursor = pending.cursor;
                const file = command.file orelse (cursor orelse return error.InvalidCommandBuffer).file_identifier;
                const dest = command.destination orelse (cursor orelse return error.InvalidCommandBuffer).destination;
                const file_offset = command.offset orelse (cursor orelse return error.InvalidCommandBuffer).file_offset;
                if (dest == 0 or file_offset >= maximum_file_offset or findFileLocked(file) == null) return error.InvalidRead;
                const next_dest = std.math.add(u64, dest, command.size) catch return error.InvalidRead;
                const next_offset = std.math.add(u64, file_offset, command.size) catch return error.InvalidRead;
                pending.cursor = .{ .file_identifier = file, .destination = next_dest, .file_offset = next_offset };
                break :blk .{ .read = .{ .file_identifier = file, .destination = dest, .file_offset = file_offset, .size = command.size } };
            },
            .reset => blk: {
                pending.cursor = null;
                break :blk null;
            },
            .map_begin => |command| blk: {
                if (pending.map_active) return error.InvalidCommandBuffer;
                pending.map_active = true;
                break :blk .{ .native_map = command };
            },
            .map_end => blk: {
                if (!pending.map_active) return error.InvalidCommandBuffer;
                pending.map_active = false;
                break :blk null;
            },
            .map => |command| .{ .native_map = command },
            .wait_address => |command| .{ .wait_address = command },
            .write_address => |command| switch (command.source) {
                .immediate => .{ .write = .{ .destination = command.address, .value = command.value } },
                else => .{ .counter = .{ .read = .{
                    .destination = command.address,
                    .counter = if (command.source == .time) 0 else @intCast(command.value),
                    .source = switch (command.source) {
                        .time => .time,
                        .word => .word,
                        .pair => .pair,
                        else => unreachable,
                    },
                } } },
            },
            .wait_counter => |command| .{ .counter = .{ .wait = command } },
            .write_counter => |command| .{ .counter = .{ .write = command } },
            .event => |command| .{ .completion = .{
                .queue_handle = @intCast(command.queue),
                .ident = command.ident,
                .completion_token = command.data,
                .user_data = command.data,
            } },
            .marker => null,
        };
        if (op) |value| {
            try pending.ops.append(file_allocator, value);
            try pending.native_offsets.append(file_allocator, @intCast(offset));
        }
        offset += decoded.bytes;
        pending.command_count += 1;
    }
    error_offset.* = @intCast(offset);
    if (pending.command_count != @as(u32, @intCast(header.count)) or pending.map_active) {
        reportNative(address, header, bytes, offset, if (pending.map_active) "unterminated native map" else "native command count mismatch");
        return error.InvalidCommandBuffer;
    }
    return pending;
}

/// A rejected guest stream is otherwise undiagnosable from a user log: the
/// header and leading words distinguish an unknown packet form from storage
/// the guest never filled.
fn reportNative(address: u64, header: packets.Header, bytes: []const u8, offset: usize, reason: []const u8) void {
    std.debug.print("[apr] {s} cb=0x{x} offset=0x{x} kind=0x{x} bytes=0x{x} commands={d} capacity=0x{x} storage=0x{x} words=", .{
        reason, address, offset, header.kind, header.offset, header.count, header.capacity, header.storage,
    });
    var index: usize = 0;
    while (index < 8 and (index + 1) * 4 <= bytes.len) : (index += 1) std.debug.print(" {x:0>8}", .{std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little)});
    if (offset >= 32 and offset + 4 <= bytes.len) std.debug.print(" ... at offset {x:0>8}", .{std.mem.readInt(u32, bytes[offset..][0..4], .little)});
    std.debug.print("\n", .{});
}

pub fn submitCommandBufferWithOffset(address: u64, error_offset: *u32) Error!u32 {
    return submitInner(address, error_offset, true);
}

/// Plain kernel submits publish no identifier, so no waiter can free them.
/// Untracked work still reserves a slot while a worker runs it, marked for
/// later reclaim; synchronous work takes no slot at all.
pub fn submitCommandBufferUntracked(address: u64) Error!void {
    var error_offset: u32 = 0;
    _ = try submitInner(address, &error_offset, false);
}

fn submitInner(address: u64, error_offset: *u32, tracked: bool) Error!u32 {
    error_offset.* = 0;
    var pending: CommandBuffer = .{};
    defer pending.deinit();
    var sink: ?CompletionSink = null;
    // Plain submits carry no identifier, so nothing can ever wait on them.
    // Reclaim finished slots first or fire-and-forget readers fill the table
    // with done work and later submits fail with SubmissionTableFull.
    // Workers set complete under the lock as their last touch, so clearing
    // here then joining below cannot race them. Same pattern as the waiter.
    lock.lock();
    var joined: [maximum_submissions]?std.Thread = .{null} ** maximum_submissions;
    var join_count: usize = 0;
    for (&submissions) |*submission| {
        // Only untracked plain submits: tracked ones may have a waiter
        // arriving after the sweep.
        if (submission.active and submission.complete and submission.reclaimable) {
            joined[join_count] = submission.worker;
            join_count += 1;
            submission.* = .{};
        }
    }
    lock.unlock();
    for (joined[0..join_count]) |maybe| if (maybe) |worker| worker.join();
    const slot = blk: {
        lock.lock();
        defer lock.unlock();
        if (stopping.load(.acquire)) return error.IoFailed;
        // Reserve before executing: a full submission table must not repeat
        // counter updates or publish an event for an untrackable submission.
        const index = for (&submissions, 0..) |*submission, i| {
            if (!submission.active) break i;
        } else return error.SubmissionTableFull;
        pending = if (findCommandBufferLocked(address)) |buffer|
            try buffer.clone()
        else
            try snapshotNative(address, error_offset);
        for (pending.ops.items) |*op| {
            if (op.* == .map and op.map.kind == .map_auto) {
                op.map.dmem_offset = takeAutoLocked(op.map.size, op.map.memory_type) orelse return error.OutOfDirectMemory;
            }
        }
        const identifier = next_submission_identifier;
        next_submission_identifier +%= 1;
        if (next_submission_identifier == 0) next_submission_identifier = 1;
        submissions[index] = .{ .active = true, .identifier = identifier, .reclaimable = !tracked };
        sink = completion_sink;
        break :blk index;
    };
    errdefer {
        lock.lock();
        submissions[slot] = .{};
        lock.unlock();
    }
    var cursor: usize = 0;
    const complete = executePending(&pending, &cursor, sink) catch |err| {
        if (cursor < pending.native_offsets.items.len) error_offset.* = pending.native_offsets.items[cursor];
        return err;
    };
    lock.lock();
    defer lock.unlock();
    if (complete) {
        submissions[slot].complete = true;
        // Untracked synchronous work needs no slot: no identifier was ever
        // published, so no waiter can arrive. Free it inline.
        if (!tracked) submissions[slot] = .{};
    } else {
        // Only blocked submissions launch a worker. Common APR reads retain
        // the synchronous fast path. The snapshot outlives a
        // guest resetting/reusing its command buffer immediately after submit.
        const snapshot = std.heap.page_allocator.create(CommandBuffer) catch return error.OutOfMemory;
        errdefer std.heap.page_allocator.destroy(snapshot);
        snapshot.* = pending;
        submissions[slot].worker = std.Thread.spawn(.{}, deferredMain, .{ slot, snapshot, cursor, sink }) catch return error.IoFailed;
        pending.ops = .empty; // Ownership transfers only after a successful spawn.
        pending.native_offsets = .empty;
    }
    return submissions[slot].identifier;
}

fn executePending(pending: *const CommandBuffer, cursor: *usize, sink: ?CompletionSink) Error!bool {
    while (cursor.* < pending.ops.items.len) : (cursor.* += 1) {
        if (stopping.load(.acquire) or runtime.guestStopRequested()) return error.IoFailed;
        switch (pending.ops.items[cursor.*]) {
            .read => |command| try applyRead(command),
            .write => |command| try applyWrite(command),
            .completion => |command| try applyCompletion(command, sink),
            .map => |command| try applyAmmMap(command),
            .native_map => |command| {
                const status = mapper.execute(command);
                if (status != errno.ok) return error.MappingFailed;
            },
            .wait_address => |command| {
                if (command.address & 7 != 0 or !memory_module.isHostRangeReadable(command.address, 8)) return error.InvalidRead;
                const source: *const u64 = @ptrFromInt(command.address);
                if (!counters.compare(command.compare, @atomicLoad(u64, source, .acquire), command.value, std.math.maxInt(u64), .pair)) return false;
            },
            .counter => |counter| switch (counter) {
                .write => |command| counter_bank.write(command),
                .wait => |command| if (!counter_bank.satisfied(command)) return false,
                .read => |command| try applyWrite(.{
                    .destination = command.destination,
                    .value = switch (command.source) {
                        .time => runtime.processTimeCounter(),
                        .word => counter_bank.read(command.counter, .word),
                        .pair => counter_bank.read(command.counter, .pair),
                    },
                }),
            },
        }
    }
    return true;
}

fn sleepWaiter() void {
    if (comptime builtin.os.tag == .windows) {
        var interval: i64 = -10_000;
        _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
    } else {
        std.Thread.yield() catch {};
    }
}

fn deferredMain(slot: usize, snapshot: *CommandBuffer, start: usize, sink: ?CompletionSink) void {
    var cursor = start;
    var failure: ?Error = null;
    while (true) {
        const complete = executePending(snapshot, &cursor, sink) catch |err| {
            failure = err;
            break;
        };
        if (complete) break;
        sleepWaiter();
    }
    snapshot.deinit();
    std.heap.page_allocator.destroy(snapshot);
    lock.lock();
    defer lock.unlock();
    submissions[slot].failure = failure;
    submissions[slot].complete = true;
}

pub fn waitCommandBuffer(identifier: u32) Error!void {
    while (true) {
        lock.lock();
        const submission = for (&submissions) |*entry| {
            if (entry.active and entry.identifier == identifier) break entry;
        } else {
            lock.unlock();
            return error.UnknownSubmission;
        };
        if (submission.complete) {
            const worker = submission.worker;
            const failure = submission.failure;
            submission.* = .{};
            lock.unlock();
            if (worker) |thread| thread.join();
            if (failure) |err| return err;
            return;
        }
        lock.unlock();
        sleepWaiter();
    }
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

/// Native mapper submissions share donated storage with the HLE AMPR path.
/// A failed mapping must not consume its donated slice or leak a new physical
/// reservation. Keep allocation and rollback under the same allocator lock.
pub fn mapAutoMemory(address: u64, size: u64, memory_type: i32, protection: i32) i32 {
    lock.lock();
    defer lock.unlock();
    const previous = auto_pool;
    const physical = takeAutoLocked(size, memory_type) orelse return errno.KernelError.enomem.raw();
    const status = memory.hostMapDirectMemoryFixed(address, size, protection, physical);
    if (status != errno.ok) {
        var donated = false;
        for (previous[0..auto_pool_count]) |range| {
            if (physical >= range.start and physical - range.start < range.size) donated = true;
        }
        auto_pool = previous;
        if (!donated) _ = memory.hostReleaseDirectMemory(physical, size);
    }
    return status;
}

fn applyRead(command: ReadCommand) Error!void {
    if (!writableRange(command.destination, command.size) or
        (command.bytes_read_address != 0 and !writableRange(command.bytes_read_address, 8))) return error.InvalidRead;
    const destination: [*]u8 = @ptrFromInt(command.destination);
    const bytes_read = try read(command.file_identifier, command.file_offset, destination[0..command.size]);
    if (command.bytes_read_address != 0) {
        if (memory.attachedAddressSpace()) |space| space.notifyGuestWrite(command.bytes_read_address, 8);
        const output: *[8]u8 = @ptrFromInt(command.bytes_read_address);
        std.mem.writeInt(u64, output, bytes_read, .little);
    }
}

pub fn writeDestinationValid(address: u64) bool {
    if (address == 0 or address & 7 != 0) return false;
    return writableRange(address, 8);
}

fn writableRange(address: u64, size: usize) bool {
    if (address == 0) return false;
    if (memory.attachedAddressSpace()) |space| {
        if (space.isWritable(address, size)) return true;
        // A tracked read-only mapping must not fall back to its host page's
        // possibly broader permissions.
        if (space.query(address, false) != null) return false;
    } else if (builtin.os.tag != .windows and builtin.os.tag != .linux) return true;
    return memory_module.isHostRangeWritable(address, size);
}

fn applyWrite(command: WriteCommand) Error!void {
    if (!writeDestinationValid(command.destination)) return error.InvalidRead;
    if (memory.attachedAddressSpace()) |space| space.notifyGuestWrite(command.destination, 8);
    const destination: *u64 = @ptrFromInt(command.destination);
    @atomicStore(u64, destination, command.value, .release);
}

fn applyCompletion(command: CompletionCommand, sink: ?CompletionSink) Error!void {
    // The kernel accelerator treats completion publication as best-effort:
    // command execution itself has already completed even when the target
    // event queue is unavailable or full.  Failing the submission here leaves
    // the caller without a fresh submission identifier and makes its
    // subsequent wait observe a stale/unknown identifier.
    if (sink) |callback| _ = callback(command);
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
    for (command_buffers.items) |*buffer| {
        if (buffer.active and buffer.address == address) return buffer;
    }
    return null;
}

fn findFileLocked(identifier: u32) ?*FileEntry {
    if (identifier == 0 or identifier > files.items.len) return null;
    return &files.items[identifier - 1];
}

fn expectSubmissionReady(identifier: u32) !void {
    // A deferred batch may run hundreds of per-byte file operations. Count
    // yields are not a time bound: 2000 of them elapse in well under a
    // millisecond on an idle host. Use a wall-clock budget instead.
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds + 10 * std.time.ns_per_s;
    while (std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds < deadline) {
        lock.lock();
        const ready = for (submissions) |submission| {
            if (submission.active and submission.identifier == identifier) break submission.complete;
        } else false;
        lock.unlock();
        if (ready) return;
        sleepWaiter();
    }
    return error.TestSubmissionTimedOut;
}

test "AMPR waits defer later writes and events and survive buffer reuse" {
    reset();
    defer reset();
    const Sink = struct {
        var value: u64 = 0;
        var published = std.atomic.Value(u64).init(0);
        fn publish(_: CompletionCommand) bool {
            published.store(@atomicLoad(u64, &value, .acquire), .release);
            return true;
        }
    };
    Sink.value = 0;
    Sink.published.store(0, .release);
    attachCompletionSink(Sink.publish);
    defer attachCompletionSink(null);
    try constructCommandBuffer(0x1000);
    try appendCounter(0x1000, .{ .wait = .{ .counter = 6, .access = .word, .reference = 7, .compare = .equal } }, 32);
    try appendCounter(0x1000, .{ .read = .{ .destination = @intFromPtr(&Sink.value), .counter = 6, .source = .pair } }, 32);
    try appendCompletion(0x1000, .{ .queue_handle = 1, .ident = 2, .completion_token = 3, .user_data = 4 });
    const waiting = try submitCommandBuffer(0x1000);
    try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &Sink.value, .acquire));
    try std.testing.expectEqual(@as(u64, 0), Sink.published.load(.acquire));
    try resetCommandBuffer(0x1000);
    // A producer on the SAME host thread must be able to release the wait.
    try appendCounter(0x1000, .{ .write = .{ .counter = 6, .access = .pair, .value = 0x900000007, .operation = .store } }, 32);
    const producer = try submitCommandBuffer(0x1000);
    try waitCommandBuffer(producer);
    try expectSubmissionReady(waiting);
    try waitCommandBuffer(waiting);
    try std.testing.expectEqual(@as(u64, 0x900000007), Sink.published.load(.acquire));
    try std.testing.expectError(error.UnknownSubmission, waitCommandBuffer(waiting));
}

test "AMPR cleared buffers accept new storage without reconstruction" {
    reset();
    defer reset();
    try constructCommandBuffer(0x1000);
    try setCommandBufferStorage(0x1000, 0x2000, 0x100);
    try clearCommandBuffer(0x1000);
    // Clearing detaches storage but keeps the object: reattaching works,
    // which is what file readers do on every open.
    try setCommandBufferStorage(0x1000, 0x3000, 0x100);
    const info = try commandBufferInfo(0x1000);
    try std.testing.expectEqual(@as(u64, 0x3000), info.storage_address);
    try std.testing.expectEqual(@as(usize, 0x100), info.storage_size);
}

test "AMPR pending reset cancels writes and clears process counters" {
    reset();
    defer reset();
    var label: u64 = 0;
    try constructCommandBuffer(0x1000);
    try appendCounter(0x1000, .{ .write = .{ .counter = 4, .access = .word, .value = 55, .operation = .store } }, 32);
    try appendCounter(0x1000, .{ .wait = .{ .counter = 4, .access = .word, .reference = 56, .compare = .equal } }, 32);
    try appendWrite(0x1000, .{ .destination = @intFromPtr(&label), .value = 99 }, 32);
    const identifier = try submitCommandBuffer(0x1000);
    reset();
    try std.testing.expectEqual(@as(u64, 0), label);
    try std.testing.expectEqual(@as(u64, 0), counter_bank.read(4, .word));
    try std.testing.expectError(error.UnknownSubmission, waitCommandBuffer(identifier));
}

test "AMPR large file batches honor byte capacity and own deferred commands" {
    reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();
    defer reset();
    const Sink = struct {
        var label: u64 = 0;
        var count: usize = 0;
        var ordered: bool = true;
        fn publish(_: CompletionCommand) bool {
            count += 1;
            ordered = ordered and label == count;
            return true;
        }
    };
    Sink.label = 0;
    Sink.count = 0;
    Sink.ordered = true;
    attachCompletionSink(Sink.publish);
    defer attachCompletionSink(null);
    var payload: [300]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);
    try temporary.dir.writeFile(io, .{ .sub_path = "large-batch.bin", .data = &payload });
    const file = try resolve("/app0/large-batch.bin");
    var destination = [_]u8{0xcc} ** payload.len;
    try constructCommandBuffer(0x1000);
    const capacity = 32 + payload.len * (0x30 + 32 + 0x30);
    try setCommandBufferStorage(0x1000, 0x2000, capacity);
    try appendCounter(0x1000, .{ .wait = .{ .counter = 6, .access = .word, .reference = 1, .compare = .equal } }, 32);
    for (0..payload.len) |i| {
        try appendRead(0x1000, .{ .file_identifier = file.identifier, .destination = @intFromPtr(&destination[i]), .size = 1, .file_offset = i });
        try appendWrite(0x1000, .{ .destination = @intFromPtr(&Sink.label), .value = i + 1 }, 32);
        try appendCompletion(0x1000, .{ .queue_handle = 1, .ident = i, .completion_token = 0, .user_data = 0 });
    }
    const before = try commandBufferInfo(0x1000);
    try std.testing.expectEqual(@as(usize, 901), before.command_count);
    try std.testing.expectEqual(capacity, before.write_offset);
    try std.testing.expectError(error.InvalidCommandBuffer, appendWrite(0x1000, .{ .destination = @intFromPtr(&Sink.label), .value = 999 }, 32));
    try std.testing.expectEqualDeep(before, try commandBufferInfo(0x1000));
    const waiting = try submitCommandBuffer(0x1000);
    try std.testing.expectEqual(@as(usize, 0), Sink.count);
    // The original storage can be freed and reused while the submitted batch waits.
    try destroyCommandBuffer(0x1000);
    try constructCommandBuffer(0x1000);
    try appendCounter(0x1000, .{ .write = .{ .counter = 6, .access = .word, .value = 1, .operation = .store } }, 32);
    try waitCommandBuffer(try submitCommandBuffer(0x1000));
    try expectSubmissionReady(waiting);
    try waitCommandBuffer(waiting);
    try std.testing.expectEqualSlices(u8, &payload, &destination);
    try std.testing.expectEqual(payload.len, Sink.count);
    try std.testing.expect(Sink.ordered);
}

test "AMPR completed submissions recycle without waiting" {
    reset();
    defer reset();
    try constructCommandBuffer(0x1000);
    try appendCounter(0x1000, .{ .write = .{ .counter = 0, .access = .word, .value = 1, .operation = .add } }, 32);
    // File readers fire plain submits with completion counters and never wait:
    // untracked synchronous work takes no slot, so the table cannot fill.
    for (0..maximum_submissions + 1) |_| try submitCommandBufferUntracked(0x1000);
    try std.testing.expectEqual(@as(u64, maximum_submissions + 1), counter_bank.read(0, .word));
}

test "AMPR table exhaustion has no counter side effects" {
    reset();
    defer reset();
    try constructCommandBuffer(0x1000);
    try appendCounter(0x1000, .{ .write = .{ .counter = 0, .access = .word, .value = 1, .operation = .add } }, 32);
    var ids: [maximum_submissions]u32 = undefined;
    for (&ids) |*id| id.* = try submitCommandBuffer(0x1000);
    try std.testing.expectError(error.SubmissionTableFull, submitCommandBuffer(0x1000));
    try std.testing.expectEqual(@as(u64, maximum_submissions), counter_bank.read(0, .word));
    for (ids) |id| try waitCommandBuffer(id);
}

test "AMPR concurrent additions and paired snapshots are atomic" {
    reset();
    defer reset();
    const Worker = struct {
        fn run(address: u64) void {
            for (0..1000) |_| {
                const id = submitCommandBuffer(address) catch @panic("AMPR submit failed");
                waitCommandBuffer(id) catch @panic("AMPR wait failed");
            }
        }
    };
    for (0..4) |i| {
        try constructCommandBuffer(0x1000 + i);
        try appendCounter(0x1000 + i, .{ .write = .{ .counter = 2, .access = .pair, .value = 0x100000001, .operation = .add } }, 32);
    }
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{0x1000 + i});
        started += 1;
    }
    for (0..10000) |_| {
        const pair = counter_bank.read(2, .pair);
        try std.testing.expectEqual(@as(u32, @truncate(pair)), @as(u32, @truncate(pair >> 32)));
    }
    for (threads) |thread| thread.join();
    started = 0;
    try std.testing.expectEqual(@as(u64, 0xfa000000fa0), counter_bank.read(2, .pair));
}

test "AMPR deferred failure is reported without publishing completion" {
    reset();
    defer reset();
    try constructCommandBuffer(0x1000);
    try appendCounter(0x1000, .{ .wait = .{ .counter = 0, .access = .word, .reference = 1, .compare = .equal } }, 32);
    // Validation occurs again at execution, after a preceding wait.
    try appendWrite(0x1000, .{ .destination = 1, .value = 7 }, 32);
    const id = try submitCommandBuffer(0x1000);
    counter_bank.write(.{ .counter = 0, .access = .word, .value = 1, .operation = .store });
    try expectSubmissionReady(id);
    try std.testing.expectError(error.InvalidRead, waitCommandBuffer(id));
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

    var info: filesystem.Stat = undefined;
    try stat(first.identifier, &info);
    try std.testing.expectEqual(@as(i64, 10), info.size);
    try std.testing.expectEqual(@as(u64, 10), try fileSize(first.identifier));
    try std.testing.expectError(error.UnknownFile, stat(0xffff_ffff, &info));
}

test "APR scene file IDs grow without exhausting the descriptor cache" {
    reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();
    defer reset();

    var identifiers: [600]u32 = undefined;
    for (&identifiers, 0..) |*identifier, index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "asset-{d}.bin", .{index});
        const payload = [_]u8{@truncate(index)};
        try temporary.dir.writeFile(io, .{ .sub_path = name, .data = &payload });
        identifier.* = (try resolve(name)).identifier;
        try std.testing.expectEqual(index + 1, identifier.*);
    }
    // Growth must preserve both earlier IDs and case-insensitive path keys.
    for (identifiers, 0..) |identifier, index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "ASSET-{d}.BIN", .{index});
        try std.testing.expectEqual(identifier, (try resolve(name)).identifier);
        var payload: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try read(identifier, 0, &payload));
        try std.testing.expectEqual(@as(u8, @truncate(index)), payload[0]);
    }
    try std.testing.expectEqual(maximum_cached_files, cached_file_count);
    reset();
    try std.testing.expectError(error.UnknownFile, fileSize(identifiers[0]));
    try std.testing.expectEqual(@as(u32, 1), (try resolve("asset-0.bin")).identifier);
}

test "native APR loads distinct asset names without an HLE command registry entry" {
    reset();
    defer reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const names = [_][]const u8{ "ui_wipe_transitions_1", "hero_respawn_icon_01" };
    var output: [2][32]u8 = @splat(@splat(0));
    var words: [10]u32 = undefined;
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();
    for (names, 0..) |name, index| {
        const file = try temporary.dir.createFile(io, name, .{});
        try file.writeStreamingAll(io, name);
        file.close(io);
        const resolved = try resolve(name);
        const destination = @intFromPtr(&output[index]);
        // Native five-dword ReadFile, not our private HLE recording format.
        @memcpy(words[index * 5 ..][0..5], &[_]u32{
            0x428,                  @intCast(name.len - 1),      resolved.identifier,
            @truncate(destination), @intCast(destination >> 32),
        });
    }
    const NativeHeader = extern struct {
        kind: u32 = 0,
        offset: u32,
        count: i32,
        capacity: u32,
        storage: u64,
    };
    var header = NativeHeader{
        .offset = @sizeOf(@TypeOf(words)),
        .count = 2,
        .capacity = @sizeOf(@TypeOf(words)),
        .storage = @intFromPtr(&words),
    };
    try waitCommandBuffer(try submitCommandBuffer(@intFromPtr(&header)));
    for (names, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, output[index][0..name.len]);
        try std.testing.expectEqual(@as(u8, 0), output[index][name.len]);
    }
}

fn nativeTestHeader(words: []const u32, count: i32) packets.Header {
    return .{
        .kind = 0,
        .offset = @intCast(words.len * 4),
        .count = count,
        .capacity = @intCast(words.len * 4),
        .storage = @intFromPtr(words.ptr),
    };
}

test "native APR gather scatter reads advance independent destination and file cursors" {
    reset();
    defer reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const file = try temporary.dir.createFile(io, "parts.bin", .{});
    try file.writeStreamingAll(io, "abcdefghijklmnop");
    file.close(io);
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();
    const resolved = try resolve("parts.bin");
    var output: [16]u8 = @splat(0);
    var done: u64 = 0;
    const base = @intFromPtr(&output);
    const label = @intFromPtr(&done);
    const words = [_]u32{
        0x428,            3, resolved.identifier,                            @truncate(base),      @intCast(base >> 32),
        0x8129,           3, 0x22a | (@as(u32, @intCast(base >> 32)) << 12), 3,                    @truncate(base + 8),
        0x432b,           3, @truncate(base + 12),                           @intCast(base >> 32), 0x1105 | @as(u32, @truncate((label >> 16) & 0xffff0000)),
        @truncate(label),
    };
    var header = nativeTestHeader(&words, 5);
    try waitCommandBuffer(try submitCommandBuffer(@intFromPtr(&header)));
    try std.testing.expectEqualStrings("abcdijklmnopefgh", &output);
    try std.testing.expectEqual(@as(u64, 1), done);
}

test "native APR validates whole streams before side effects" {
    reset();
    defer reset();
    var value: u64 = 0;
    const address = @intFromPtr(&value);
    var words = [_]u32{
        0x1105 | @as(u32, @truncate((address >> 16) & 0xffff0000)), @truncate(address),
        0xdeadbeef,
    };
    var header = nativeTestHeader(&words, 2);
    var offset: u32 = 0;
    try std.testing.expectError(error.InvalidCommandBuffer, submitCommandBufferWithOffset(@intFromPtr(&header), &offset));
    try std.testing.expectEqual(@as(u32, 8), offset);
    try std.testing.expectEqual(@as(u64, 0), value);
    // The same valid write must also remain unexecuted on a bad header count.
    header.offset = 8;
    try std.testing.expectError(error.InvalidCommandBuffer, submitCommandBuffer(@intFromPtr(&header)));
    try std.testing.expectEqual(@as(u64, 0), value);
    header.count = 1;
    header.capacity = 4;
    try std.testing.expectError(error.InvalidCommandBuffer, submitCommandBuffer(@intFromPtr(&header)));
    try std.testing.expectError(error.InvalidCommandBuffer, submitCommandBuffer(1));
    // A reset makes compressed reads invalid until the next full ReadFile.
    words = .{ 0x2f, 0x129, 3 };
    header = nativeTestHeader(&words, 2);
    try std.testing.expectError(error.InvalidCommandBuffer, submitCommandBuffer(@intFromPtr(&header)));
}

test "native APR rejects unwritten storage and accepts encoded NOP payloads" {
    reset();
    defer reset();
    var value: u64 = 0;
    const address = @intFromPtr(&value);
    const words = [_]u32{ 0, 0x1105 | @as(u32, @truncate((address >> 16) & 0xffff0000)), @truncate(address) };
    var header = nativeTestHeader(&words, 2);
    var offset: u32 = 0;
    try std.testing.expectError(error.InvalidCommandBuffer, submitCommandBufferWithOffset(@intFromPtr(&header), &offset));
    try std.testing.expectEqual(@as(u32, 0), offset);
    try std.testing.expectEqual(@as(u64, 0), value);
    // Issue #8: one announced command but all five dwords are zero. A forged
    // count matching the dword count must not turn that into successful I/O.
    const empty = [_]u32{0} ** 5;
    for ([_]i32{ 1, 5 }) |count| {
        header = nativeTestHeader(&empty, count);
        header.kind = 0x10000;
        header.capacity = 0x400;
        try std.testing.expectError(error.InvalidCommandBuffer, submitCommandBufferWithOffset(@intFromPtr(&header), &offset));
        try std.testing.expectEqual(@as(u32, 0), offset);
    }
    // Native NOP has a length-bearing tag. Its zero payload is not decoded
    // as separate commands, and the following real write is executed.
    const encoded = [_]u32{ 0x5452040f, 0, 0, 0, 0, words[1], words[2] };
    header = nativeTestHeader(&encoded, 2);
    try waitCommandBuffer(try submitCommandBuffer(@intFromPtr(&header)));
    try std.testing.expectEqual(@as(u64, 1), value);
}

test "native APR waiting submissions own their decoded commands" {
    reset();
    defer reset();
    var ready: u64 = 0;
    var completed: u64 = 0;
    const wait_address = @intFromPtr(&ready);
    const output = @intFromPtr(&completed);
    var words = [_]u32{
        0x201 | @as(u32, @truncate((wait_address >> 16) & 0xffff0000)), @truncate(wait_address), 1,
        0x1105 | @as(u32, @truncate((output >> 16) & 0xffff0000)),      @truncate(output),
    };
    var header = nativeTestHeader(&words, 2);
    const id = try submitCommandBuffer(@intFromPtr(&header));
    try std.testing.expectEqual(@as(u64, 0), @atomicLoad(u64, &completed, .acquire));
    @memset(&words, 0xdeadbeef);
    header = std.mem.zeroes(packets.Header);
    @atomicStore(u64, &ready, 1, .release);
    try expectSubmissionReady(id);
    try waitCommandBuffer(id);
    try std.testing.expectEqual(@as(u64, 1), @atomicLoad(u64, &completed, .acquire));
}

test "native APR maps storage before a read and publishes counters and an event after it" {
    reset();
    defer reset();
    var space = try memory_module.AddressSpace.initWithDirectMemory(std.testing.allocator, 0x100000);
    defer space.deinit();
    memory.init(std.testing.allocator);
    defer memory.deinit();
    memory.attachAddressSpace(&space);
    defer memory.attachAddressSpace(null);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "mapped.dat", .data = "mapped-payload" });
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();
    const file = try resolve("mapped.dat");
    const base: u64 = 0x1000000000;
    const Sink = struct {
        var event: ?CompletionCommand = null;
        var complete: bool = false;
        fn publish(command: CompletionCommand) bool {
            event = command;
            complete = std.mem.eql(u8, @as([*]const u8, @ptrFromInt(0x1000000000))[0..14], "mapped-payload");
            return true;
        }
    };
    Sink.event = null;
    Sink.complete = false;
    attachCompletionSink(Sink.publish);
    defer attachCompletionSink(null);
    const words = [_]u32{
        0x322d,          @truncate(base >> 14), 4, // MapBegin: 16 KiB, CPU read/write.
        0x428,           13,                    file.identifier,
        @truncate(base), @intCast(base >> 32),  0x2e,
        0x03001006, // Counter 3 = 1 on completion.
        0x03010002, // Wait for counter 3 == 1.
        0x408,
        7,
        9,
        0x12345678,
        0xabcdef01,
    };
    var header = nativeTestHeader(&words, 6);
    try std.testing.expect(space.query(base, false) == null);
    try waitCommandBuffer(try submitCommandBuffer(@intFromPtr(&header)));
    try std.testing.expect(Sink.complete);
    try std.testing.expectEqual(@as(u64, 1), counter_bank.read(3, .word));
    try std.testing.expectEqual(@as(i64, 7), Sink.event.?.queue_handle);
    try std.testing.expectEqual(@as(u64, 9), Sink.event.?.ident);
    try std.testing.expectEqual(@as(u64, 0xabcdef0112345678), Sink.event.?.completion_token);
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
    var bytes_read: u64 = 0;
    try constructCommandBuffer(0x3000);
    try setCommandBufferStorage(0x3000, 0x4000, 0x10000);
    try appendRead(0x3000, .{
        .file_identifier = resolved.identifier,
        .destination = @intFromPtr(&destination),
        .size = destination.len,
        .file_offset = 7,
        .bytes_read_address = @intFromPtr(&bytes_read),
    });
    const submission = try submitCommandBuffer(0x3000);
    try std.testing.expectEqualStrings("payload", destination[0..7]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xaa, 0xaa }, destination[7..]);
    try std.testing.expectEqual(@as(u64, 7), bytes_read);
    try std.testing.expectEqual(@as(usize, 1), cached_file_count);
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

test "APR completion delivery is best effort" {
    const RejectingSink = struct {
        fn publish(_: CompletionCommand) bool {
            return false;
        }
    };

    reset();
    defer reset();
    attachCompletionSink(RejectingSink.publish);
    defer attachCompletionSink(null);

    try constructCommandBuffer(0x9000);
    try setCommandBufferStorage(0x9000, 0xa000, 0x10000);
    try appendCompletion(0x9000, .{
        .queue_handle = 7,
        .ident = 11,
        .completion_token = 13,
        .user_data = 17,
    });
    const submission = try submitCommandBuffer(0x9000);
    try waitCommandBuffer(submission);
}

test "APR completes a read into GPU-watched pages through the attached address space" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const guest_memory = @import("memory");
    reset();
    defer reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "tracked.dat", .data = "tracked-payload" });
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();
    var space = try guest_memory.AddressSpace.init(std.testing.allocator);
    defer space.deinit();
    memory.attachAddressSpace(&space);
    defer memory.attachAddressSpace(null);
    const base = guest_memory.system_managed.start;
    try space.mapFixed(base, guest_memory.page_size, .read_write, .private, null);
    try space.write(base, "xxxxxxxxxxxxxxx");
    space.enableGpuMemoryTracking();
    const generation = try space.trackGpuRead(base, 15);
    try std.testing.expect(generation != 0);

    const resolved = try resolve("/app0/tracked.dat");
    var bytes_read: u64 = 0;
    try constructCommandBuffer(0x1000);
    try appendRead(0x1000, .{
        .file_identifier = resolved.identifier,
        .destination = base,
        .size = 15,
        .file_offset = 0,
        .bytes_read_address = @intFromPtr(&bytes_read),
    });
    const submission = try submitCommandBuffer(0x1000);
    try std.testing.expectEqual(@as(u64, 15), bytes_read);
    try std.testing.expectEqualStrings("tracked-payload", @as([*]const u8, @ptrFromInt(base))[0..15]);
    try std.testing.expectEqual(@as(u64, 0), space.gpuGeneration(base, 15));
    try waitCommandBuffer(submission);
    try std.testing.expectError(error.UnknownSubmission, waitCommandBuffer(submission));
}
