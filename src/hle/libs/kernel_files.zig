// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! File entry points backed by the title's own content.
//!
//! Two calling conventions share one implementation. Kernel-style entry points
//! return a negative status; POSIX-style ones return `-1` and leave the reason
//! in the thread's `errno`. Translating in one place keeps the two from
//! drifting apart.
//!
//! Writes are refused rather than ignored: save data has no location policy or
//! container format yet, and a title that believes its data was stored is far
//! worse off than one told the filesystem is read-only.

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
    return filesystem.open(name, flags) catch |err| kernelStatus(err);
}

fn kernelClose(descriptor: i32) callconv(abi.guest) i32 {
    filesystem.close(descriptor) catch |err| return kernelStatus(err);
    return errno.ok;
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
    filesystem.stat(name, record) catch |err| return kernelStatus(err);
    return errno.ok;
}

fn kernelFstat(descriptor: i32, out: ?*filesystem.Stat) callconv(abi.guest) i32 {
    const record = writableRecord(filesystem.Stat, out) orelse return KernelError.efault.raw();
    filesystem.fstat(descriptor, record) catch |err| return kernelStatus(err);
    return errno.ok;
}

/// Writing is refused for every descriptor the filesystem owns.
fn kernelWrite(_: i32, _: ?[*]const u8, _: usize) callconv(abi.guest) i64 {
    return KernelError.eacces.raw();
}

fn kernelPwrite(_: i32, _: ?[*]const u8, _: usize, _: i64) callconv(abi.guest) i64 {
    return KernelError.eacces.raw();
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

fn posixOpen(path: ?[*:0]const u8, flags: i32, _: u16) callconv(abi.guest) i64 {
    const name = spanOf(path) orelse return posixFail(Error.InvalidArgument);
    const descriptor = filesystem.open(name, flags) catch |err| return posixFail(err);
    return descriptor;
}

fn posixClose(descriptor: i32) callconv(abi.guest) i64 {
    filesystem.close(descriptor) catch |err| return posixFail(err);
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
    filesystem.stat(name, record) catch |err| return posixFail(err);
    return 0;
}

fn posixFstat(descriptor: i32, out: ?*filesystem.Stat) callconv(abi.guest) i64 {
    const record = writableRecord(filesystem.Stat, out) orelse return posixFail(Error.InvalidArgument);
    filesystem.fstat(descriptor, record) catch |err| return posixFail(err);
    return 0;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceKernelOpen", .function = trace.wrap("sceKernelOpen", &kernelOpen), .expect_id = "1G3lF1Gg1k8" },
    .{ .name = "sceKernelClose", .function = trace.wrap("sceKernelClose", &kernelClose), .expect_id = "UK2Tl2DWUns" },
    .{ .name = "sceKernelRead", .function = trace.wrap("sceKernelRead", &kernelRead), .expect_id = "Cg4srZ6TKbU" },
    .{ .name = "sceKernelWrite", .function = trace.wrap("sceKernelWrite", &kernelWrite), .expect_id = "4wSze92BhLI" },
    .{ .name = "sceKernelPread", .function = trace.wrap("sceKernelPread", &kernelPread), .expect_id = "+r3rMFwItV4" },
    .{ .name = "sceKernelPwrite", .function = trace.wrap("sceKernelPwrite", &kernelPwrite), .expect_id = "nKWi-N2HBV4" },
    .{ .name = "sceKernelLseek", .function = trace.wrap("sceKernelLseek", &kernelLseek), .expect_id = "oib76F-12fk" },
    .{ .name = "sceKernelStat", .function = trace.wrap("sceKernelStat", &kernelStat), .expect_id = "eV9wAD2riIA" },
    .{ .name = "sceKernelFstat", .function = trace.wrap("sceKernelFstat", &kernelFstat), .expect_id = "kBwCPsYX-m4" },
    .{ .name = "sceKernelFsync", .function = trace.wrap("sceKernelFsync", &readOnlyStatus), .expect_id = "fTx66l5iWIA" },
    .{ .name = "sceKernelFchmod", .function = trace.wrap("sceKernelFchmod", &readOnlyStatus), .expect_id = "UtszJWHrDcA" },
    .{ .name = "sceKernelFtruncate", .function = trace.wrap("sceKernelFtruncate", &readOnlyStatus), .expect_id = "VW3TVZiM4-E" },
    .{ .name = "sceKernelRmdir", .function = trace.wrap("sceKernelRmdir", &readOnlyStatus), .expect_id = "naInUjYt3so" },

    .{ .name = "open", .function = trace.wrap("open", &posixOpen), .expect_id = "wuCroIGjt2g" },
    .{ .name = "_open", .function = trace.wrap("_open", &posixOpen), .expect_id = "6c3rCVE-fTU" },
    .{ .name = "close", .function = trace.wrap("close", &posixClose), .expect_id = "bY-PO6JhzhQ" },
    .{ .name = "_close", .function = trace.wrap("_close", &posixClose), .expect_id = "NNtFaKJbPt0" },
    .{ .name = "read", .function = trace.wrap("read", &posixRead), .expect_id = "AqBioC2vF3I" },
    .{ .name = "_read", .function = trace.wrap("_read", &posixRead), .expect_id = "DRuBt2pvICk" },
    .{ .name = "lseek", .function = trace.wrap("lseek", &posixLseek), .expect_id = "Oy6IpwgtYOk" },
    .{ .name = "stat", .function = trace.wrap("stat", &posixStat), .expect_id = "E6ao34wPw+U" },
    .{ .name = "fstat", .function = trace.wrap("fstat", &posixFstat), .expect_id = "mqQMh1zPPT8" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
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
    try testing.expectEqual(@as(i64, KernelError.eacces.raw()), kernelWrite(3, "x", 1));
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
    try testing.expect(db.findByName("sceKernelOpen", .function) != null);
}
