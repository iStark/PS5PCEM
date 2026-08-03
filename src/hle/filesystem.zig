// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The files a title can see.
//!
//! A title addresses its own content through mount points rather than host
//! paths: everything it ships lives under `/app0`. This maps those paths onto a
//! host directory and hands out descriptors.
//!
//! Read-only for now. Writable mounts mean save data, which needs a location
//! policy and a container format that do not exist yet — and a title that
//! believes a write succeeded when nothing was stored is far worse off than one
//! told plainly that the filesystem is read-only.

const std = @import("std");

/// Descriptors below this belong to the standard streams.
pub const first_descriptor: i32 = 3;

/// How many files a title may hold open at once.
pub const maximum_open_files: usize = 256;

/// Longest guest path retained per descriptor, for diagnostics.
pub const maximum_path: usize = 256;

pub const Error = error{
    NotAttached,
    NotFound,
    BadDescriptor,
    TooManyOpenFiles,
    ReadOnly,
    IsDirectory,
    InvalidArgument,
    IoFailed,
};

/// Open flags, in the guest's numbering.
///
/// These follow the BSD values the guest's libc was built against; the access
/// mode lives in the low two bits and everything else is a flag.
pub const O = struct {
    pub const rdonly: i32 = 0x0000;
    pub const wronly: i32 = 0x0001;
    pub const rdwr: i32 = 0x0002;
    pub const accmode: i32 = 0x0003;
    pub const append: i32 = 0x0008;
    pub const creat: i32 = 0x0200;
    pub const trunc: i32 = 0x0400;
    pub const excl: i32 = 0x0800;
    pub const directory: i32 = 0x0002_0000;
};

/// `whence` values for seeking.
pub const Seek = struct {
    pub const set: i32 = 0;
    pub const cur: i32 = 1;
    pub const end: i32 = 2;
};

const mode_ifreg: u16 = 0o100000;
const mode_ifdir: u16 = 0o040000;
const mode_read_only: u16 = 0o444;

pub const Timespec = extern struct {
    seconds: i64 = 0,
    nanoseconds: i64 = 0,
};

/// File metadata, in guest layout.
///
/// The guest allocates this, so the field order and size are part of the ABI
/// rather than an implementation choice.
pub const Stat = extern struct {
    dev: u32 = 0,
    ino: u32 = 0,
    mode: u16 = 0,
    nlink: u16 = 1,
    uid: u32 = 0,
    gid: u32 = 0,
    rdev: u32 = 0,
    atim: Timespec = .{},
    mtim: Timespec = .{},
    ctim: Timespec = .{},
    size: i64 = 0,
    blocks: i64 = 0,
    blksize: u32 = 0,
    flags: u32 = 0,
    gen: u32 = 0,
    lspare: i32 = 0,
    birthtim: Timespec = .{},
};

comptime {
    std.debug.assert(@sizeOf(Stat) == 120);
    std.debug.assert(@offsetOf(Stat, "size") == 72);
    std.debug.assert(@offsetOf(Stat, "mode") == 8);
}

/// Mount points a title uses to name its own files.
const mount_points = [_][]const u8{ "/app0/", "/hostapp/", "/host/" };

/// Strips a mount prefix, yielding a path relative to the title root.
///
/// Returns null for a path outside every known mount: only content the title
/// ships is visible, and quietly resolving anything else against the host
/// filesystem would expose more than a title can see on hardware.
pub fn stripMount(path: []const u8) ?[]const u8 {
    for (mount_points) |mount| {
        if (path.len >= mount.len and std.ascii.eqlIgnoreCase(path[0..mount.len], mount)) {
            const rest = path[mount.len..];
            return if (rest.len == 0) null else rest;
        }
    }
    // A relative path is already how the loader knows its own files.
    if (path.len != 0 and path[0] != '/') return path;
    return null;
}

const OpenFile = struct {
    file: std.Io.File,
    /// Read position. Kept here and used with positional reads so that two
    /// descriptors on one file cannot disturb each other.
    offset: u64 = 0,
    size: u64 = 0,
    path_buffer: [maximum_path]u8 = undefined,
    path_length: usize = 0,

    fn path(self: *const OpenFile) []const u8 {
        return self.path_buffer[0..self.path_length];
    }
};

/// Serializes descriptor bookkeeping.
///
/// `std.atomic.Mutex` offers only `tryLock` and `std.Io.Mutex` needs an `Io`
/// this layer does not hold at rest. Spinning is acceptable: the critical
/// sections are a table lookup, and file operations themselves run outside it.
const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

var active_io: ?std.Io = null;
var root: ?std.Io.Dir = null;
var open_files: [maximum_open_files]?OpenFile = @splat(null);
var table_lock: Lock = .{};

/// Makes a host directory visible to the title as `/app0`.
pub fn attach(io: std.Io, directory: std.Io.Dir) void {
    table_lock.lock();
    defer table_lock.unlock();
    active_io = io;
    root = directory;
}

/// Closes everything still open and detaches the mount.
pub fn detach() void {
    table_lock.lock();
    defer table_lock.unlock();
    if (active_io) |io| {
        for (&open_files) |*slot| {
            if (slot.*) |entry| entry.file.close(io);
            slot.* = null;
        }
    } else {
        for (&open_files) |*slot| slot.* = null;
    }
    active_io = null;
    root = null;
}

pub fn isAttached() bool {
    return root != null;
}

/// How many descriptors are currently held.
pub fn openCount() usize {
    table_lock.lock();
    defer table_lock.unlock();
    var total: usize = 0;
    for (open_files) |slot| {
        if (slot != null) total += 1;
    }
    return total;
}

fn slotOf(descriptor: i32) ?*?OpenFile {
    if (descriptor < first_descriptor) return null;
    const index: usize = @intCast(descriptor - first_descriptor);
    if (index >= open_files.len) return null;
    return &open_files[index];
}

/// Opens a file the title named.
///
/// Anything that would modify the filesystem is refused rather than ignored, so
/// a title cannot proceed believing its data was stored.
pub fn open(path: []const u8, flags: i32) Error!i32 {
    const io = active_io orelse return Error.NotAttached;
    const directory = root orelse return Error.NotAttached;

    if (flags & O.accmode != O.rdonly) return Error.ReadOnly;
    if (flags & (O.creat | O.trunc | O.excl | O.append) != 0) return Error.ReadOnly;

    const relative = stripMount(path) orelse return Error.NotFound;
    if (relative.len > maximum_path) return Error.InvalidArgument;

    // A directory open needs directory reads to be useful, which do not exist
    // yet; saying so is better than handing back a descriptor that cannot be
    // read.
    if (flags & O.directory != 0) return Error.IsDirectory;

    const file = directory.openFile(io, relative, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => return Error.NotFound,
        error.IsDir => return Error.IsDirectory,
        else => return Error.IoFailed,
    };
    errdefer file.close(io);

    const size = file.length(io) catch return Error.IoFailed;

    table_lock.lock();
    defer table_lock.unlock();

    for (&open_files, 0..) |*slot, index| {
        if (slot.* != null) continue;
        var entry = OpenFile{ .file = file, .size = size };
        entry.path_length = @min(path.len, maximum_path);
        @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
        slot.* = entry;
        return first_descriptor + @as(i32, @intCast(index));
    }
    return Error.TooManyOpenFiles;
}

pub fn close(descriptor: i32) Error!void {
    const io = active_io orelse return Error.NotAttached;

    table_lock.lock();
    defer table_lock.unlock();

    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = slot.* orelse return Error.BadDescriptor;
    entry.file.close(io);
    slot.* = null;
}

/// Reads from the descriptor's own position and advances it.
pub fn read(descriptor: i32, buffer: []u8) Error!usize {
    const io = active_io orelse return Error.NotAttached;

    table_lock.lock();
    const slot = slotOf(descriptor) orelse {
        table_lock.unlock();
        return Error.BadDescriptor;
    };
    if (slot.* == null) {
        table_lock.unlock();
        return Error.BadDescriptor;
    }
    const offset = slot.*.?.offset;
    const file = slot.*.?.file;
    table_lock.unlock();

    const count = file.readPositionalAll(io, buffer, offset) catch return Error.IoFailed;

    table_lock.lock();
    defer table_lock.unlock();
    // The descriptor may have been closed while the read ran; advancing a
    // reused slot would corrupt an unrelated file's position.
    if (slot.*) |*entry| {
        if (entry.file.handle == file.handle) entry.offset = offset + count;
    }
    return count;
}

/// Reads from an explicit offset without disturbing the descriptor's position.
pub fn pread(descriptor: i32, buffer: []u8, offset: u64) Error!usize {
    const io = active_io orelse return Error.NotAttached;

    table_lock.lock();
    const slot = slotOf(descriptor) orelse {
        table_lock.unlock();
        return Error.BadDescriptor;
    };
    const entry = slot.* orelse {
        table_lock.unlock();
        return Error.BadDescriptor;
    };
    table_lock.unlock();

    return entry.file.readPositionalAll(io, buffer, offset) catch Error.IoFailed;
}

pub fn seek(descriptor: i32, offset: i64, whence: i32) Error!i64 {
    table_lock.lock();
    defer table_lock.unlock();

    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = if (slot.*) |*value| value else return Error.BadDescriptor;

    const base: i64 = switch (whence) {
        Seek.set => 0,
        Seek.cur => @intCast(entry.offset),
        Seek.end => @intCast(entry.size),
        else => return Error.InvalidArgument,
    };
    const target = std.math.add(i64, base, offset) catch return Error.InvalidArgument;
    // Seeking past the end is allowed and reads there simply return nothing;
    // seeking before it is not addressable at all.
    if (target < 0) return Error.InvalidArgument;

    entry.offset = @intCast(target);
    return target;
}

fn fillStat(out: *Stat, size: u64, is_directory: bool) void {
    out.* = .{};
    out.mode = (if (is_directory) mode_ifdir else mode_ifreg) | mode_read_only;
    out.size = @intCast(size);
    out.blksize = 512;
    out.blocks = @intCast((size + 511) / 512);
}

pub fn stat(path: []const u8, out: *Stat) Error!void {
    const io = active_io orelse return Error.NotAttached;
    const directory = root orelse return Error.NotAttached;

    const relative = stripMount(path) orelse return Error.NotFound;

    const info = directory.statFile(io, relative, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => return Error.NotFound,
        else => return Error.IoFailed,
    };
    fillStat(out, info.size, info.kind == .directory);
}

pub fn fstat(descriptor: i32, out: *Stat) Error!void {
    table_lock.lock();
    defer table_lock.unlock();

    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = slot.* orelse return Error.BadDescriptor;
    fillStat(out, entry.size, false);
}

/// The guest path a descriptor was opened with, for diagnostics.
pub fn pathOf(descriptor: i32) ?[]const u8 {
    table_lock.lock();
    defer table_lock.unlock();
    const slot = slotOf(descriptor) orelse return null;
    const entry = if (slot.*) |*value| value else return null;
    return entry.path();
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the stat layout matches the guest ABI" {
    // The guest allocates this by size, so a change here silently corrupts
    // whatever it stores after the record.
    try testing.expectEqual(@as(usize, 120), @sizeOf(Stat));
    try testing.expectEqual(@as(usize, 72), @offsetOf(Stat, "size"));
    try testing.expectEqual(@as(usize, 104), @offsetOf(Stat, "birthtim"));
}

test "mount prefixes are stripped and foreign paths refused" {
    try testing.expectEqualStrings("Media/x.dat", stripMount("/app0/Media/x.dat").?);
    try testing.expectEqualStrings("Media/x.dat", stripMount("/APP0/Media/x.dat").?);
    try testing.expectEqualStrings("Media/x.dat", stripMount("Media/x.dat").?);

    // Only what the title ships is visible; anything else would reach further
    // than a title can on hardware.
    try testing.expect(stripMount("/system/priv.bin") == null);
    try testing.expect(stripMount("/") == null);
    try testing.expect(stripMount("/app0/") == null);
    try testing.expect(stripMount("") == null);
}

test "unattached filesystem reports so rather than failing obscurely" {
    detach();
    try testing.expect(!isAttached());
    try testing.expectError(Error.NotAttached, open("/app0/x", O.rdonly));
    try testing.expectError(Error.BadDescriptor, seek(3, 0, Seek.set));
}

const Fixture = struct {
    tmp: testing.TmpDir,

    fn init(contents: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.bin", .data = contents });
        try tmp.dir.createDirPath(testing.io, "sub");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/inner.txt", .data = "inner" });
        attach(testing.io, tmp.dir);
        return .{ .tmp = tmp };
    }

    fn deinit(self: *Fixture) void {
        detach();
        self.tmp.cleanup();
    }
};

test "a title reads its own content through the mount" {
    var fixture = try Fixture.init("0123456789");
    defer fixture.deinit();

    const fd = try open("/app0/data.bin", O.rdonly);
    // Descriptors never collide with the standard streams.
    try testing.expect(fd >= first_descriptor);
    defer close(fd) catch {};

    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try read(fd, &buffer));
    try testing.expectEqualStrings("0123", &buffer);

    // Reading advances the position.
    try testing.expectEqual(@as(usize, 4), try read(fd, &buffer));
    try testing.expectEqualStrings("4567", &buffer);

    // A short read at the end is not an error.
    try testing.expectEqual(@as(usize, 2), try read(fd, &buffer));
    try testing.expectEqual(@as(usize, 0), try read(fd, &buffer));
}

test "positional reads leave the descriptor position alone" {
    var fixture = try Fixture.init("0123456789");
    defer fixture.deinit();

    const fd = try open("/app0/data.bin", O.rdonly);
    defer close(fd) catch {};

    var buffer: [3]u8 = undefined;
    _ = try read(fd, &buffer);
    try testing.expectEqualStrings("012", &buffer);

    try testing.expectEqual(@as(usize, 3), try pread(fd, &buffer, 7));
    try testing.expectEqualStrings("789", &buffer);

    // The sequential position is where the earlier read left it.
    _ = try read(fd, &buffer);
    try testing.expectEqualStrings("345", &buffer);
}

test "seeking moves the position and rejects negative results" {
    var fixture = try Fixture.init("0123456789");
    defer fixture.deinit();

    const fd = try open("/app0/data.bin", O.rdonly);
    defer close(fd) catch {};

    try testing.expectEqual(@as(i64, 5), try seek(fd, 5, Seek.set));
    try testing.expectEqual(@as(i64, 7), try seek(fd, 2, Seek.cur));
    try testing.expectEqual(@as(i64, 10), try seek(fd, 0, Seek.end));

    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(i64, 8), try seek(fd, -2, Seek.end));
    try testing.expectEqual(@as(usize, 2), try read(fd, &buffer));
    try testing.expectEqualStrings("89", buffer[0..2]);

    try testing.expectError(Error.InvalidArgument, seek(fd, -1, Seek.set));
    try testing.expectError(Error.InvalidArgument, seek(fd, 0, 99));
}

test "metadata is reported for paths and descriptors" {
    var fixture = try Fixture.init("0123456789");
    defer fixture.deinit();

    var info = Stat{};
    try stat("/app0/data.bin", &info);
    try testing.expectEqual(@as(i64, 10), info.size);
    try testing.expect(info.mode & mode_ifreg != 0);

    try stat("/app0/sub", &info);
    try testing.expect(info.mode & mode_ifdir != 0);

    const fd = try open("/app0/data.bin", O.rdonly);
    defer close(fd) catch {};
    var by_descriptor = Stat{};
    try fstat(fd, &by_descriptor);
    try testing.expectEqual(@as(i64, 10), by_descriptor.size);
}

test "writes are refused rather than silently dropped" {
    var fixture = try Fixture.init("data");
    defer fixture.deinit();

    // A title that believes its data was stored is worse off than one told the
    // filesystem is read-only.
    try testing.expectError(Error.ReadOnly, open("/app0/data.bin", O.wronly));
    try testing.expectError(Error.ReadOnly, open("/app0/data.bin", O.rdwr));
    try testing.expectError(Error.ReadOnly, open("/app0/new.bin", O.rdonly | O.creat));
    try testing.expectError(Error.ReadOnly, open("/app0/data.bin", O.rdonly | O.trunc));
}

test "missing files and bad descriptors are reported precisely" {
    var fixture = try Fixture.init("data");
    defer fixture.deinit();

    try testing.expectError(Error.NotFound, open("/app0/absent.bin", O.rdonly));
    try testing.expectError(Error.NotFound, open("/system/secret", O.rdonly));
    try testing.expectError(Error.IsDirectory, open("/app0/sub", O.rdonly | O.directory));

    var buffer: [4]u8 = undefined;
    try testing.expectError(Error.BadDescriptor, read(99, &buffer));
    try testing.expectError(Error.BadDescriptor, close(99));
    // The standard streams are not filesystem descriptors.
    try testing.expectError(Error.BadDescriptor, read(1, &buffer));
}

test "descriptors are released and reused" {
    var fixture = try Fixture.init("data");
    defer fixture.deinit();

    try testing.expectEqual(@as(usize, 0), openCount());
    const first = try open("/app0/data.bin", O.rdonly);
    try testing.expectEqual(@as(usize, 1), openCount());
    try testing.expectEqualStrings("/app0/data.bin", pathOf(first).?);

    try close(first);
    try testing.expectEqual(@as(usize, 0), openCount());
    try testing.expectError(Error.BadDescriptor, close(first));

    const second = try open("/app0/data.bin", O.rdonly);
    defer close(second) catch {};
    try testing.expectEqual(first, second);
}

test "nested paths resolve" {
    var fixture = try Fixture.init("data");
    defer fixture.deinit();

    const fd = try open("/app0/sub/inner.txt", O.rdonly);
    defer close(fd) catch {};
    var buffer: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try read(fd, &buffer));
    try testing.expectEqualStrings("inner", &buffer);
}
