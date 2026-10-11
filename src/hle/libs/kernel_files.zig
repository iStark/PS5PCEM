// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! File entry points backed by the title's own content.
//!
//! Two calling conventions share one implementation. Kernel-style entry points
//! return a negative status; POSIX-style ones return `-1` and leave the reason
//! in the thread's `errno`. Translating in one place keeps the two from
//! drifting apart.
//!
//! Writes use the filesystem's writable save, download and temporary mounts.
//! Installed title content remains read-only.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const filesystem = @import("../filesystem.zig");
const memory_api = @import("kernel_memory.zig");
const runtime_api = @import("kernel_runtime.zig");

const KernelError = errno.KernelError;
const Error = filesystem.Error;

/// Maps a filesystem failure to the kernel status scheme.
fn kernelStatus(err: Error) i32 {
    return switch (err) {
        Error.NotAttached => KernelError.enosys.raw(),
        Error.NotFound => KernelError.enoent.raw(),
        Error.BadDescriptor => KernelError.ebadf.raw(),
        Error.TooManyOpenFiles => KernelError.emfile.raw(),
        Error.ReadOnly => KernelError.eacces.raw(),
        Error.IsDirectory => KernelError.eacces.raw(),
        Error.InvalidArgument => KernelError.einval.raw(),
        Error.IoFailed => KernelError.eio.raw(),
        Error.NotSupported => KernelError.enodev.raw(),
        Error.Exists => KernelError.eexist.raw(),
    };
}

/// Maps a filesystem failure to a POSIX error number.
fn posixNumber(err: Error) i32 {
    return switch (err) {
        Error.NotAttached => errno.Posix.enosys,
        Error.NotFound => errno.Posix.enoent,
        Error.BadDescriptor => errno.Posix.ebadf,
        Error.TooManyOpenFiles => errno.Posix.emfile,
        Error.ReadOnly => errno.Posix.eacces,
        Error.IsDirectory => errno.Posix.eacces,
        Error.InvalidArgument => errno.Posix.einval,
        Error.IoFailed => errno.Posix.eio,
        Error.NotSupported => errno.Posix.enodev,
        Error.Exists => errno.Posix.eexist,
    };
}

/// Reports a failure the POSIX way and yields the sentinel result.
fn posixFail(err: Error) i64 {
    runtime_api.setPosixErrno(posixNumber(err));
    return -1;
}

/// Reads a NUL-terminated path the guest supplied.
///
/// Bounded by the longest path the filesystem accepts. An unbounded scan walks
/// off whatever the guest passed, and that fault lands in host code where the
/// guest fault handler declines to act, so the emulator dies with nothing to
/// explain it.
fn spanOf(path: ?[*:0]const u8) ?[]const u8 {
    const pointer = path orelse return null;
    const bytes: [*]const u8 = @ptrCast(pointer);
    const end = std.mem.indexOfScalar(u8, bytes[0 .. filesystem.maximum_path + 1], 0) orelse
        return null;
    return bytes[0..end];
}

/// Checks a buffer the guest asked firmware to fill.
///
/// The length comes from the guest and is not bounded by anything we control.
/// Writing through it unchecked turns a title's own bug into a crash of the
/// emulator, on a host thread where the guest fault handler declines to act —
/// so the failure arrives without the state that would explain it.
fn writableSlice(buffer: ?[*]u8, length: usize) ?[]u8 {
    const bytes = buffer orelse return null;
    if (length == 0) return bytes[0..0];
    if (!memory_api.isGuestRangeAccessible(@intFromPtr(bytes), length)) return null;
    return bytes[0..length];
}

/// Checks a record the guest asked firmware to fill.
fn writableRecord(comptime T: type, record: ?*T) ?*T {
    const pointer = record orelse return null;
    if (!memory_api.isGuestRangeAccessible(@intFromPtr(pointer), @sizeOf(T))) return null;
    return pointer;
}

// ---------------------------------------------------------------------------
// Kernel-style entry points
// ---------------------------------------------------------------------------

fn kernelOpen(path: ?[*:0]const u8, flags: i32, _: u16) callconv(abi.guest) i32 {
    const name = spanOf(path) orelse return KernelError.efault.raw();
    const descriptor = filesystem.open(name, flags) catch |err| {
        announceOpen(name, -1);
        return kernelStatus(err);
    };
    announceOpen(name, descriptor);
    return descriptor;
}

fn kernelClose(descriptor: i32) callconv(abi.guest) i32 {
    filesystem.close(descriptor) catch |err| return kernelStatus(err);
    return errno.ok;
}

fn kernelFsync(descriptor: i32) callconv(abi.guest) i32 {
    filesystem.fsync(descriptor) catch |err| return kernelStatus(err);
    return errno.ok;
}

fn posixFsync(descriptor: i32) callconv(abi.guest) i64 {
    filesystem.fsync(descriptor) catch |err| return posixFail(err);
    return 0;
}

fn kernelRead(descriptor: i32, buffer: ?[*]u8, length: usize) callconv(abi.guest) i64 {
    const bytes = writableSlice(buffer, length) orelse return KernelError.efault.raw();
    if (length == 0) return 0;
    const count = filesystem.read(descriptor, bytes) catch |err|
        return kernelStatus(err);
    return @intCast(count);
}

fn kernelPread(
    descriptor: i32,
    buffer: ?[*]u8,
    length: usize,
    offset: i64,
) callconv(abi.guest) i64 {
    const bytes = writableSlice(buffer, length) orelse return KernelError.efault.raw();
    if (length == 0) return 0;
    if (offset < 0) return KernelError.einval.raw();
    const count = filesystem.pread(descriptor, bytes, @intCast(offset)) catch |err|
        return kernelStatus(err);
    return @intCast(count);
}

fn kernelLseek(descriptor: i32, offset: i64, whence: i32) callconv(abi.guest) i64 {
    return filesystem.seek(descriptor, offset, whence) catch |err| kernelStatus(err);
}

fn kernelStat(path: ?[*:0]const u8, out: ?*filesystem.Stat) callconv(abi.guest) i32 {
    const name = spanOf(path) orelse return KernelError.efault.raw();
    const record = writableRecord(filesystem.Stat, out) orelse return KernelError.efault.raw();
    filesystem.stat(name, record) catch |err| {
        announceStat(name, false, err);
        return kernelStatus(err);
    };
    announceStat(name, true, null);
    return errno.ok;
}

fn kernelFstat(descriptor: i32, out: ?*filesystem.Stat) callconv(abi.guest) i32 {
    const record = writableRecord(filesystem.Stat, out) orelse return KernelError.efault.raw();
    filesystem.fstat(descriptor, record) catch |err| return kernelStatus(err);
    return errno.ok;
}

fn kernelGetdents(descriptor: i32, buffer: ?[*]u8, length: usize) callconv(abi.guest) i32 {
    const bytes = writableSlice(buffer, length) orelse return KernelError.efault.raw();
    const count = filesystem.getDents(descriptor, bytes, null) catch |err| return kernelStatus(err);
    return @intCast(count);
}

fn kernelGetdirentries(
    descriptor: i32,
    buffer: ?[*]u8,
    length: usize,
    base_position: ?*u64,
) callconv(abi.guest) i32 {
    const bytes = writableSlice(buffer, length) orelse return KernelError.efault.raw();
    if (base_position) |position| {
        if (!memory_api.isGuestRangeAccessible(@intFromPtr(position), @sizeOf(u64))) {
            return KernelError.efault.raw();
        }
    }
    const count = filesystem.getDents(descriptor, bytes, base_position) catch |err| return kernelStatus(err);
    return @intCast(count);
}

/// The filesystem enforces the descriptor's writable mount and open mode.
fn kernelWrite(descriptor: i32, buffer: ?[*]const u8, length: usize) callconv(abi.guest) i64 {
    const source = buffer orelse return KernelError.efault.raw();
    if (length != 0 and !memory_api.isGuestRangeAccessible(@intFromPtr(source), length)) {
        return KernelError.efault.raw();
    }
    const count = filesystem.write(descriptor, source[0..length]) catch |err| return kernelStatus(err);
    return @intCast(count);
}

fn kernelPwrite(descriptor: i32, buffer: ?[*]const u8, length: usize, offset: i64) callconv(abi.guest) i64 {
    if (offset < 0) return KernelError.einval.raw();
    const source = buffer orelse return KernelError.efault.raw();
    if (length != 0 and !memory_api.isGuestRangeAccessible(@intFromPtr(source), length)) return KernelError.efault.raw();
    const count = filesystem.pwrite(descriptor, source[0..length], @intCast(offset)) catch |err| return kernelStatus(err);
    return @intCast(count);
}

fn kernelFtruncate(descriptor: i32, length: i64) callconv(abi.guest) i32 {
    if (length < 0) return KernelError.einval.raw();
    filesystem.ftruncate(descriptor, @intCast(length)) catch |err| return kernelStatus(err);
    return errno.ok;
}

fn kernelMkdir(path: ?[*:0]const u8, _: u16) callconv(abi.guest) i32 {
    const name = spanOf(path) orelse return KernelError.efault.raw();
    filesystem.makeDirectory(name) catch |err| return kernelStatus(err);
    return errno.ok;
}

fn readOnlyStatus(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    return KernelError.eacces.raw();
}

// ---------------------------------------------------------------------------
// POSIX-style entry points
// ---------------------------------------------------------------------------

/// Says which file was asked for, and what became of the request.
///
/// The trace records the arguments a call was given, and for an open that is a
/// bare pointer — which names nothing. A title that cannot find its content
/// makes exactly this call and gets exactly this failure, so the one thing
/// worth seeing is the path.
fn announceOpen(name: []const u8, result: i64) void {
    if (!trace.announces("open")) return;
    if (result < 0) {
        std.debug.print("[open ] \"{s}\" refused\n", .{name});
    } else {
        std.debug.print("[open ] \"{s}\" -> {d}\n", .{ name, result });
    }
}

fn announceStat(name: []const u8, succeeded: bool, failure: ?Error) void {
    if (!trace.announces("stat")) return;
    if (succeeded) {
        std.debug.print("[stat ] \"{s}\" -> ok\n", .{name});
    } else {
        std.debug.print("[stat ] \"{s}\" -> {s}\n", .{ name, @errorName(failure.?) });
    }
}

fn posixOpen(path: ?[*:0]const u8, flags: i32, _: u16) callconv(abi.guest) i64 {
    const name = spanOf(path) orelse return posixFail(Error.InvalidArgument);
    const descriptor = filesystem.open(name, flags) catch |err| {
        announceOpen(name, -1);
        return posixFail(err);
    };
    announceOpen(name, descriptor);
    return descriptor;
}

fn posixClose(descriptor: i32) callconv(abi.guest) i64 {
    filesystem.close(descriptor) catch |err| return posixFail(err);
    return 0;
}

pub fn posixWrite(descriptor: i32, buffer: ?[*]const u8, length: usize) callconv(abi.guest) i64 {
    const source = buffer orelse return posixFail(Error.InvalidArgument);
    if (length != 0 and !memory_api.isGuestRangeAccessible(@intFromPtr(source), length)) {
        return posixFail(Error.InvalidArgument);
    }
    if (descriptor == 1 or descriptor == 2) {
        return runtime_api.guestWrite(descriptor, source, length);
    }
    const count = filesystem.write(descriptor, source[0..length]) catch |err| return posixFail(err);
    return @intCast(count);
}

fn posixMkdir(path: ?[*:0]const u8, _: u16) callconv(abi.guest) i64 {
    const name = spanOf(path) orelse return posixFail(Error.InvalidArgument);
    filesystem.makeDirectory(name) catch |err| return posixFail(err);
    return 0;
}

fn posixRead(descriptor: i32, buffer: ?[*]u8, length: usize) callconv(abi.guest) i64 {
    const bytes = writableSlice(buffer, length) orelse return posixFail(Error.InvalidArgument);
    if (length == 0) return 0;
    const count = filesystem.read(descriptor, bytes) catch |err| return posixFail(err);
    return @intCast(count);
}

fn posixLseek(descriptor: i32, offset: i64, whence: i32) callconv(abi.guest) i64 {
    return filesystem.seek(descriptor, offset, whence) catch |err| posixFail(err);
}

fn posixStat(path: ?[*:0]const u8, out: ?*filesystem.Stat) callconv(abi.guest) i64 {
    const name = spanOf(path) orelse return posixFail(Error.InvalidArgument);
    const record = writableRecord(filesystem.Stat, out) orelse return posixFail(Error.InvalidArgument);
    filesystem.stat(name, record) catch |err| {
        announceStat(name, false, err);
        return posixFail(err);
    };
    announceStat(name, true, null);
    return 0;
}

fn posixFstat(descriptor: i32, out: ?*filesystem.Stat) callconv(abi.guest) i64 {
    const record = writableRecord(filesystem.Stat, out) orelse return posixFail(Error.InvalidArgument);
    filesystem.fstat(descriptor, record) catch |err| return posixFail(err);
    return 0;
}

fn posixFtruncate(descriptor: i32, length: i64) callconv(abi.guest) i64 {
    if (length < 0) {
        runtime_api.setPosixErrno(errno.Posix.einval);
        return -1;
    }
    filesystem.ftruncate(descriptor, @intCast(length)) catch |err| return posixFail(err);
    return 0;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceKernelOpen", .function = trace.wrap("sceKernelOpen", &kernelOpen), .expect_id = "1G3lF1Gg1k8" },
    .{ .name = "sceKernelClose", .function = trace.wrap("sceKernelClose", &kernelClose), .expect_id = "UK2Tl2DWUns" },
    .{ .name = "sceKernelRead", .function = trace.wrap("sceKernelRead", &kernelRead), .expect_id = "Cg4srZ6TKbU" },
    .{ .name = "sceKernelWrite", .function = trace.wrap("sceKernelWrite", &kernelWrite), .expect_id = "4wSze92BhLI" },
    .{ .name = "sceKernelPread", .function = trace.wrap("sceKernelPread", &kernelPread), .expect_id = "+r3rMFwItV4" },
    .{ .name = "sceKernelPwrite", .function = trace.wrap("sceKernelPwrite", &kernelPwrite), .expect_id = "nKWi-N2HBV4" },
    .{ .name = "sceKernelMkdir", .function = trace.wrap("sceKernelMkdir", &kernelMkdir), .expect_id = "1-LFLmRFxxM" },
    .{ .name = "sceKernelLseek", .function = trace.wrap("sceKernelLseek", &kernelLseek), .expect_id = "oib76F-12fk" },
    .{ .name = "sceKernelStat", .function = trace.wrap("sceKernelStat", &kernelStat), .expect_id = "eV9wAD2riIA" },
    .{ .name = "sceKernelFstat", .function = trace.wrap("sceKernelFstat", &kernelFstat), .expect_id = "kBwCPsYX-m4" },
    .{ .name = "sceKernelGetdents", .function = trace.wrap("sceKernelGetdents", &kernelGetdents), .expect_id = "j2AIqSqJP0w" },
    .{ .name = "sceKernelGetdirentries", .function = trace.wrap("sceKernelGetdirentries", &kernelGetdirentries), .expect_id = "taRWhTJFTgE" },
    .{ .name = "sceKernelFsync", .function = trace.wrap("sceKernelFsync", &kernelFsync), .expect_id = "fTx66l5iWIA" },
    .{ .name = "sceKernelFchmod", .function = trace.wrap("sceKernelFchmod", &readOnlyStatus), .expect_id = "UtszJWHrDcA" },
    .{ .name = "sceKernelFtruncate", .function = trace.wrap("sceKernelFtruncate", &kernelFtruncate), .expect_id = "VW3TVZiM4-E" },
    .{ .name = "sceKernelRmdir", .function = trace.wrap("sceKernelRmdir", &readOnlyStatus), .expect_id = "naInUjYt3so" },

    .{ .name = "open", .function = trace.wrap("open", &posixOpen), .expect_id = "wuCroIGjt2g" },
    .{ .name = "_open", .function = trace.wrap("_open", &posixOpen), .expect_id = "6c3rCVE-fTU" },
    .{ .name = "close", .function = trace.wrap("close", &posixClose), .expect_id = "bY-PO6JhzhQ" },
    .{ .name = "_close", .function = trace.wrap("_close", &posixClose), .expect_id = "NNtFaKJbPt0" },
    .{ .name = "read", .function = trace.wrap("read", &posixRead), .expect_id = "AqBioC2vF3I" },
    .{ .name = "_read", .function = trace.wrap("_read", &posixRead), .expect_id = "DRuBt2pvICk" },
    .{ .name = "write", .function = trace.wrap("write", &posixWrite), .expect_id = "FN4gaPmuFV8" },
    .{ .name = "_write", .function = trace.wrap("_write", &posixWrite), .expect_id = "FxVZqBAA7ks" },
    .{ .name = "mkdir", .function = trace.wrap("mkdir", &posixMkdir), .expect_id = "JGMio+21L4c" },
    .{ .name = "lseek", .function = trace.wrap("lseek", &posixLseek), .expect_id = "Oy6IpwgtYOk" },
    .{ .name = "stat", .function = trace.wrap("stat", &posixStat), .expect_id = "E6ao34wPw+U" },
    .{ .name = "fstat", .function = trace.wrap("fstat", &posixFstat), .expect_id = "mqQMh1zPPT8" },
    .{ .name = "ftruncate", .function = trace.wrap("ftruncate", &posixFtruncate), .expect_id = "ih4CD9-gghM" },
};

const posix_exports = [_]symbols.Export{
    .{ .name = "fsync", .function = trace.wrap("fsync", &posixFsync), .expect_id = "juWbTNM+8hw" },
    .{ .name = "ftruncate", .function = trace.wrap("ftruncate", &posixFtruncate), .expect_id = "ih4CD9-gghM" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const posix_library = symbols.Library{ .name = "libScePosix", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
    try db.addLibrary(gpa, posix_library, module, &posix_exports);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.bin", .data = "0123456789" });
        filesystem.attach(testing.io, tmp.dir);
        return .{ .tmp = tmp };
    }

    fn deinit(self: *Fixture) void {
        filesystem.detach();
        self.tmp.cleanup();
    }
};

test "the kernel entry points read a file end to end" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const fd = kernelOpen("/app0/data.bin", filesystem.O.rdonly, 0);
    try testing.expect(fd >= filesystem.first_descriptor);

    var buffer: [5]u8 = undefined;
    try testing.expectEqual(@as(i64, 5), kernelRead(fd, &buffer, buffer.len));
    try testing.expectEqualStrings("01234", &buffer);

    try testing.expectEqual(@as(i64, 0), kernelLseek(fd, 0, filesystem.Seek.set));
    try testing.expectEqual(@as(i64, 3), kernelPread(fd, &buffer, 3, 7));
    try testing.expectEqualStrings("789", buffer[0..3]);

    var info = filesystem.Stat{};
    try testing.expectEqual(errno.ok, kernelFstat(fd, &info));
    try testing.expectEqual(@as(i64, 10), info.size);

    try testing.expectEqual(errno.ok, kernelClose(fd));
    try testing.expectEqual(KernelError.ebadf.raw(), kernelClose(fd));
}

test "positional save writes and truncation persist without moving the cursor" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    filesystem.attachTemporaryData(fixture.tmp.dir);
    defer filesystem.detachTemporaryData();
    const fd = kernelOpen("/temp0/slot.sav", filesystem.O.rdwr | filesystem.O.creat | filesystem.O.trunc, 0);
    try testing.expect(fd >= filesystem.first_descriptor);
    try testing.expectEqual(@as(i64, 3), kernelLseek(fd, 3, filesystem.Seek.set));
    try testing.expectEqual(errno.ok, kernelFtruncate(fd, 8));
    try testing.expectEqual(@as(i64, 4), kernelPwrite(fd, "save", 4, 1));
    try testing.expectEqual(@as(i64, 3), kernelLseek(fd, 0, filesystem.Seek.cur));
    try testing.expectEqual(@as(i64, 0), posixFtruncate(fd, 5));
    try testing.expectEqual(@as(i64, 3), kernelLseek(fd, 0, filesystem.Seek.cur));
    try testing.expectEqual(@as(i64, 5), kernelLseek(fd, 0, filesystem.Seek.end));
    try testing.expectEqual(@as(i64, 0), posixFtruncate(fd, 7));
    try testing.expectEqual(errno.ok, kernelClose(fd));
    const reopened = kernelOpen("/temp0/slot.sav", filesystem.O.rdonly, 0);
    defer _ = kernelClose(reopened);
    var data: [7]u8 = undefined;
    try testing.expectEqual(@as(i64, 7), kernelRead(reopened, &data, data.len));
    try testing.expectEqualSlices(u8, &.{ 0, 's', 'a', 'v', 'e', 0, 0 }, &data);
    try testing.expectEqual(KernelError.eacces.raw(), kernelPwrite(reopened, "x", 1, 0));
    try testing.expectEqual(KernelError.eacces.raw(), kernelFtruncate(reopened, 0));
    try testing.expectEqual(KernelError.einval.raw(), kernelPwrite(reopened, "x", 1, -1));
    try testing.expectEqual(KernelError.ebadf.raw(), kernelFtruncate(fd, 0));
    try testing.expectEqual(KernelError.efault.raw(), kernelPwrite(reopened, null, 1, 0));
    try testing.expectEqual(@as(i64, -1), posixFtruncate(reopened, -1));
    try testing.expectEqual(@as(i64, -1), posixFtruncate(reopened, 0));
    const truncated = kernelOpen("/temp0/slot.sav", filesystem.O.rdwr | filesystem.O.trunc, 0);
    defer _ = kernelClose(truncated);
    var info = filesystem.Stat{};
    try testing.expectEqual(errno.ok, kernelFstat(truncated, &info));
    try testing.expectEqual(@as(i64, 0), info.size);
}

test "fsync commits writable files and reports host flush failures" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    filesystem.attachTemporaryData(fixture.tmp.dir);
    defer filesystem.detachTemporaryData();
    const fd = kernelOpen("/temp0/sync.sav", filesystem.O.rdwr | filesystem.O.creat | filesystem.O.trunc, 0);
    try testing.expect(fd >= filesystem.first_descriptor);
    try testing.expectEqual(@as(i64, 4), kernelWrite(fd, "save", 4));
    try testing.expectEqual(errno.ok, kernelFsync(fd));
    try testing.expectEqual(@as(i64, 0), posixFsync(fd));
    try testing.expectEqual(@as(i64, 4), kernelLseek(fd, 0, filesystem.Seek.cur));
    const Fail = struct {
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
    };
    // A backend failure must not turn into a successful no-op at either ABI.
    var failing_vtable = testing.io.vtable.*;
    failing_vtable.fileSync = &Fail.sync;
    var failing_io = testing.io;
    failing_io.vtable = &failing_vtable;
    filesystem.attach(failing_io, fixture.tmp.dir);
    try testing.expectEqual(KernelError.eio.raw(), kernelFsync(fd));
    try testing.expectEqual(@as(i64, -1), posixFsync(fd));
    filesystem.attach(testing.io, fixture.tmp.dir);
    try testing.expectEqual(errno.ok, kernelClose(fd));
    try testing.expectEqual(KernelError.ebadf.raw(), kernelFsync(fd));
    try testing.expectEqual(@as(i64, -1), posixFsync(fd));
    const reopened = kernelOpen("/temp0/sync.sav", filesystem.O.rdonly, 0);
    defer _ = kernelClose(reopened);
    var bytes: [4]u8 = undefined;
    try testing.expectEqual(@as(i64, 4), kernelRead(reopened, &bytes, bytes.len));
    try testing.expectEqualStrings("save", &bytes);
}

test "the POSIX entry points report failure the POSIX way" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const fd = posixOpen("/app0/data.bin", filesystem.O.rdonly, 0);
    try testing.expect(fd >= filesystem.first_descriptor);

    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(i64, 4), posixRead(@intCast(fd), &buffer, buffer.len));
    try testing.expectEqualStrings("0123", &buffer);
    try testing.expectEqual(@as(i64, 0), posixClose(@intCast(fd)));

    // A missing file is -1 with the reason in errno, not a negative status.
    try testing.expectEqual(@as(i64, -1), posixOpen("/app0/absent.bin", filesystem.O.rdonly, 0));
    try testing.expectEqual(@as(i64, -1), posixRead(99, &buffer, buffer.len));
}

test "the two conventions report the same failure differently" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    // Kernel style: a negative status carrying the reason.
    try testing.expectEqual(
        KernelError.enoent.raw(),
        kernelOpen("/app0/absent.bin", filesystem.O.rdonly, 0),
    );
    // POSIX style: the sentinel, reason elsewhere.
    try testing.expectEqual(@as(i64, -1), posixOpen("/app0/absent.bin", filesystem.O.rdonly, 0));
}

test "writes are refused through every path" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try testing.expectEqual(
        KernelError.eacces.raw(),
        kernelOpen("/app0/data.bin", filesystem.O.wronly, 0),
    );
    const fd = kernelOpen("/app0/data.bin", filesystem.O.rdonly, 0);
    defer _ = kernelClose(fd);
    try testing.expectEqual(@as(i64, KernelError.eacces.raw()), kernelWrite(fd, "x", 1));
    try testing.expectEqual(KernelError.eacces.raw(), readOnlyStatus(0, 0, 0, 0, 0, 0));
}

test "a null path or record is rejected rather than dereferenced" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    try testing.expectEqual(KernelError.efault.raw(), kernelOpen(null, 0, 0));
    try testing.expectEqual(KernelError.efault.raw(), kernelStat(null, null));
    try testing.expectEqual(KernelError.efault.raw(), kernelFstat(3, null));
    try testing.expectEqual(@as(i64, KernelError.efault.raw()), kernelRead(3, null, 4));
}

test "file exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expect(db.findById("nKWi-N2HBV4", .function) != null);
    try testing.expect(db.findById("ih4CD9-gghM", .function) != null);
    try testing.expect(db.findByName("sceKernelOpen", .function) != null);
    try testing.expect(db.findByName("sceKernelMkdir", .function) != null);
    try testing.expect(db.findByName("write", .function) != null);
}

test "registered POSIX write persists temporary saves and preserves descriptor errors" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    filesystem.attachTemporaryData(scratch.dir);
    defer filesystem.detachTemporaryData();
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try runtime_api.register(&db, testing.allocator);
    const entry = db.find(.{
        .id = @import("../nid.zig").fromName("write"),
        .library = posix_library,
        .module = module,
        .type = .function,
    }) orelse return error.TestExpectedSymbol;
    const write_file: *const fn (i32, ?[*]const u8, usize) callconv(abi.guest) i64 = @ptrFromInt(entry.address);
    const error_entry = db.findByName("__error", .function) orelse return error.TestExpectedSymbol;
    const error_address: *const fn () callconv(abi.guest) *i32 = @ptrFromInt(error_entry.address);
    const fd = kernelOpen("/temp0/TempSave/gameinfo.json", filesystem.O.rdwr | filesystem.O.creat | filesystem.O.trunc, 0);
    try testing.expect(fd >= filesystem.first_descriptor);
    try testing.expectEqual(@as(i64, 4), write_file(fd, "save", 4));
    try testing.expectEqual(@as(i64, 1), write_file(fd, "!", 1));
    try testing.expectEqual(errno.ok, kernelClose(fd));
    try testing.expectEqual(@as(i64, -1), write_file(fd, "x", 1));
    try testing.expectEqual(errno.Posix.ebadf, error_address().*);

    const reopened = kernelOpen("/temp0/TempSave/gameinfo.json", filesystem.O.rdonly, 0);
    defer _ = kernelClose(reopened);
    var contents: [5]u8 = undefined;
    try testing.expectEqual(@as(i64, contents.len), kernelRead(reopened, &contents, contents.len));
    try testing.expectEqualStrings("save!", &contents);
    try testing.expectEqual(@as(i64, -1), write_file(reopened, "x", 1));
    try testing.expectEqual(errno.Posix.eacces, error_address().*);

    const socket = try filesystem.openVirtualSocket();
    defer filesystem.close(socket) catch {};
    try testing.expectEqual(@as(i64, 4), write_file(socket, "wake", 4));
}
