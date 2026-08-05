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

pub const maximum_files: usize = 256;
pub const maximum_path: usize = 1024;
pub const maximum_command_buffers: usize = 32;
pub const maximum_reads_per_buffer: usize = 32;
pub const maximum_submissions: usize = 64;
pub const maximum_read_bytes: usize = 4 * 1024 * 1024 * 1024;
pub const maximum_file_offset: u64 = 0x0000_0100_0000_0000;

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

const CommandBuffer = struct {
    active: bool = false,
    address: u64 = 0,
    storage_address: u64 = 0,
    storage_size: usize = 0,
    reads: [maximum_reads_per_buffer]ReadCommand = undefined,
    read_count: usize = 0,
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

pub fn reset() void {
    lock.lock();
    defer lock.unlock();
    files = [_]FileEntry{.{}} ** maximum_files;
    next_identifier = 1;
    command_buffers = [_]CommandBuffer{.{}} ** maximum_command_buffers;
    submissions = [_]Submission{.{}} ** maximum_submissions;
    next_submission_identifier = 1;
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
        buffer.read_count = 0;
        return;
    }
    for (&command_buffers) |*buffer| {
        if (buffer.active) continue;
        buffer.* = .{ .active = true, .address = address };
        return;
    }
    return error.CommandBufferTableFull;
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
}

pub fn appendRead(address: u64, command: ReadCommand) Error!void {
    if (command.destination == 0 or command.size == 0 or command.size > maximum_read_bytes or
        command.file_offset >= maximum_file_offset)
    {
        return error.InvalidRead;
    }
    lock.lock();
    defer lock.unlock();
    const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
    if (buffer.read_count >= buffer.reads.len) return error.TooManyCommands;
    if (findFileLocked(command.file_identifier) == null) return error.UnknownFile;
    buffer.reads[buffer.read_count] = command;
    buffer.read_count += 1;
}

pub fn submitCommandBuffer(address: u64) Error!u32 {
    var pending: [maximum_reads_per_buffer]ReadCommand = undefined;
    const pending_count = blk: {
        lock.lock();
        defer lock.unlock();
        const buffer = findCommandBufferLocked(address) orelse return error.InvalidCommandBuffer;
        @memcpy(pending[0..buffer.read_count], buffer.reads[0..buffer.read_count]);
        break :blk buffer.read_count;
    };
    for (pending[0..pending_count]) |command| {
        if (!memory.isGuestRangeAccessible(command.destination, command.size)) return error.InvalidRead;
        const destination: [*]u8 = @ptrFromInt(command.destination);
        _ = try read(command.file_identifier, command.file_offset, destination[0..command.size]);
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
