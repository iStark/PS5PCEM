// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Sparse shared storage used by guest direct memory.
//!
//! A direct-memory allocation is a physical offset, not a private anonymous
//! allocation. Mapping the same offset twice must therefore expose the same
//! bytes at both guest virtual addresses. `SharedBacking` supplies that stable
//! identity without eagerly allocating the complete 12 GiB pool.

const std = @import("std");
const builtin = @import("builtin");

const NativeHandle = switch (builtin.os.tag) {
    .windows => std.os.windows.HANDLE,
    .linux, .macos => std.posix.fd_t,
    else => void,
};

pub const Error = error{
    InvalidSize,
    UnsupportedHost,
    CreateFailed,
    ResizeFailed,
    MapFailed,
};

const WindowsViews = struct {
    extern "kernel32" fn MapViewOfFile(NativeHandle, u32, u32, u32, usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(*const anyopaque) callconv(.winapi) i32;
};

/// An independent alias owns its host mapping until deinit. Closing the section
/// handle or replacing a guest VA does not invalidate this view's pages.
pub const SharedView = struct {
    bytes: []u8,
    offset: usize,

    pub fn deinit(self: SharedView) void {
        if (builtin.os.tag == .windows) _ = WindowsViews.UnmapViewOfFile(self.bytes.ptr);
    }
};

/// A host object whose pages can be mapped into more than one guest address.
///
/// Windows uses a page-file-backed section created with `SEC_RESERVE`. Linux
/// uses an anonymous memfd, and macOS uses an immediately unlinked POSIX shared
/// memory object. All three are sparse: only mapped guest pages consume commit
/// resources, and physical working-set pages are faulted on first touch.
pub const SharedBacking = struct {
    size: u64,
    handle: NativeHandle,

    /// Windows views start on allocation granularity, while the requested
    /// physical range may start on any byte. Only committed direct-memory
    /// ranges should be passed here; creating an alias does not commit pages.
    pub fn mapView(self: *const SharedBacking, offset: u64, size: usize) Error!SharedView {
        if (builtin.os.tag != .windows) return Error.UnsupportedHost;
        if (size == 0 or offset > self.size or size > self.size - offset) return Error.InvalidSize;
        const start = std.mem.alignBackward(u64, offset, 64 * 1024);
        const end = std.mem.alignForward(u64, offset + size, 4096);
        if (end > self.size) return Error.InvalidSize;
        const length: usize = @intCast(end - start);
        const pointer = WindowsViews.MapViewOfFile(self.handle, 0x0002, @intCast(start >> 32), @truncate(start), length) orelse return Error.MapFailed;
        return .{ .bytes = @as([*]u8, @ptrCast(pointer))[0..length], .offset = @intCast(offset - start) };
    }

    pub fn init(size: u64) Error!SharedBacking {
        if (size == 0 or size > std.math.maxInt(i64)) return Error.InvalidSize;

        return switch (builtin.os.tag) {
            .windows => initWindows(size),
            .linux => initLinux(size),
            .macos => initMacos(size),
            else => Error.UnsupportedHost,
        };
    }

    pub fn deinit(self: *SharedBacking) void {
        switch (builtin.os.tag) {
            .windows => std.os.windows.CloseHandle(self.handle),
            .linux, .macos => _ = std.posix.system.close(self.handle),
            else => {},
        }
        self.* = undefined;
    }

    fn initWindows(size: u64) Error!SharedBacking {
        const windows = std.os.windows;
        var handle: windows.HANDLE = undefined;
        const maximum_size: windows.LARGE_INTEGER = @intCast(size);
        const status = windows.ntdll.NtCreateSection(
            &handle,
            windows.ACCESS_MASK.Specific.Section.ALL_ACCESS,
            null,
            &maximum_size,
            .{ .EXECUTE_READWRITE = true },
            .{ .RESERVE = true },
            null,
        );
        if (status != .SUCCESS) return Error.CreateFailed;
        return .{ .size = size, .handle = handle };
    }

    fn initLinux(size: u64) Error!SharedBacking {
        const fd = std.posix.memfd_create("ps5pcem-direct-memory", 0) catch
            return Error.CreateFailed;
        errdefer _ = std.posix.system.close(fd);
        try resize(fd, size);
        return .{ .size = size, .handle = fd };
    }

    fn initMacos(size: u64) Error!SharedBacking {
        var name_buffer: [96:0]u8 = undefined;
        const name = std.fmt.bufPrintZ(
            &name_buffer,
            "/ps5pcem-direct-{d}-{x}",
            .{ std.c.getpid(), @intFromPtr(&name_buffer) },
        ) catch return Error.CreateFailed;

        // Darwin's O_RDWR, O_CREAT, and O_EXCL values. shm_open takes the
        // traditional integer mask rather than std.posix.O's packed type.
        const flags = 0x0002 | 0x0200 | 0x0800;
        const fd = std.c.shm_open(name.ptr, flags, @as(c_uint, 0o600));
        if (fd < 0) return Error.CreateFailed;
        errdefer _ = std.posix.system.close(fd);

        // The open descriptor keeps the object alive while unlinking prevents
        // stale names after a crash and permits concurrent emulator processes.
        if (std.c.shm_unlink(name.ptr) != 0) return Error.CreateFailed;
        try resize(fd, size);
        return .{ .size = size, .handle = fd };
    }

    fn resize(fd: std.posix.fd_t, size: u64) Error!void {
        const result = std.posix.system.ftruncate(fd, @intCast(size));
        if (std.posix.errno(result) != .SUCCESS) return Error.ResizeFailed;
    }
};
