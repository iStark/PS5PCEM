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
const audio_fs = @import("audio_fs.zig");

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
    /// The descriptor names a device, which is not driven by reading and
    /// writing it.
    NotSupported,
};

/// Devices a title can open by name.
///
/// A device node is not a file: nothing is stored behind it, and the only
/// meaningful operations are control requests. They live in the same namespace
/// as files because that is how a title reaches them, but they are answered
/// from here rather than from the host filesystem — the host has no such
/// devices, and resolving these paths against it would find nothing or, worse,
/// something unrelated.
pub const Device = enum {
    /// The graphics core. A display driver opens this and then submits all of
    /// its work through control requests on the descriptor.
    graphics,
    /// Mode switches a system library reads during startup.
    dip_switches,
    /// Entropy. Unlike the others this device *is* driven by reading it, which
    /// is the whole of what it does.
    random,

    pub fn name(self: Device) []const u8 {
        return switch (self) {
            .graphics => "/dev/gc",
            .dip_switches => "/dev/dipsw",
            .random => "/dev/urandom",
        };
    }
};

const device_nodes = [_]Device{ .graphics, .dip_switches, .random };

/// The second spelling of the entropy device.
///
/// The two differ on a console only in whether a read may block waiting for
/// entropy to be gathered. Nothing here gathers any, so nothing here can
/// block, and the distinction has no consequence — but a title asking for one
/// name must not be told the other does not exist.
const blocking_random_node = "/dev/random";

/// Fills a buffer from the entropy device, and says how much it wrote.
///
/// Genuinely unpredictable rather than a fixed sequence. A title seeds its own
/// generators from here, and a fixed sequence would make every run of a game
/// deal the same cards and place the same debris — which is a difference a
/// player sees, and one nothing in the title would explain.
var entropy_source: ?std.Random.DefaultCsprng = null;
var entropy_lock: Lock = .{};

/// How far the processor has counted, where it can be asked.
///
/// Only used to make a seed differ between runs. Where the counter is not
/// available the seed still varies, because the addresses mixed with it do.
fn processorCounter() u64 {
    if (@import("builtin").cpu.arch != .x86_64) return 0;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

/// Seeds the entropy device once, from what this process can observe of itself.
///
/// The host offers no single call here that yields real entropy, so the seed is
/// mixed from things that differ between runs: where the loader placed this
/// process, and how far the processor has counted. Neither is secret, and this
/// device is not asked to keep secrets — it is asked not to repeat itself, and
/// this does not.
fn seedEntropy() std.Random.DefaultCsprng {
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    var mixed: u64 = @intFromPtr(&seed);
    mixed ^= @intFromPtr(&entropy_source) *% 0x9e37_79b9_7f4a_7c15;
    mixed ^= processorCounter() *% 0xff51_afd7_ed55_8ccd;

    for (&seed, 0..) |*byte, index| {
        mixed ^= mixed >> 33;
        mixed *%= 0xc4ce_b9fe_1a85_ec53;
        mixed +%= index;
        byte.* = @truncate(mixed >> 24);
    }
    return std.Random.DefaultCsprng.init(seed);
}

fn fillWithEntropy(buffer: []u8) Error!usize {
    if (buffer.len == 0) return 0;
    entropy_lock.lock();
    defer entropy_lock.unlock();
    if (entropy_source == null) entropy_source = seedEntropy();
    entropy_source.?.random().bytes(buffer);
    return buffer.len;
}

/// Recognises a path as one of the devices served here.
pub fn deviceForPath(path: []const u8) ?Device {
    for (device_nodes) |device| {
        if (std.ascii.eqlIgnoreCase(path, device.name())) return device;
    }
    if (std.ascii.eqlIgnoreCase(path, blocking_random_node)) return .random;
    return null;
}

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
const mode_ifchr: u16 = 0o020000;
const mode_read_only: u16 = 0o444;
const mode_read_write: u16 = 0o666;

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
    /// Null for a device node, which has no host file behind it.
    file: ?std.Io.File = null,
    /// Directory descriptors retain their iterator between getdents calls.
    directory: ?std.Io.Dir = null,
    directory_iterator: ?std.Io.Dir.Iterator = null,
    /// The first two directory entries are synthesized as `.` and `..`.
    directory_index: u64 = 0,
    device: ?Device = null,
    /// In-memory payload for synthesised files (FSB-backed virtual WAVs).
    /// Owned by this descriptor; freed on close via page_allocator.
    memory: ?[]u8 = null,
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
            if (slot.*) |entry| {
                if (entry.file) |file| file.close(io);
                if (entry.directory) |directory| directory.close(io);
            }
            slot.* = null;
        }
    } else {
        for (&open_files) |*slot| slot.* = null;
    }
    active_io = null;
    root = null;
    audio_fs.reset();
}

pub fn isAttached() bool {
    return root != null;
}

/// Index FSB banks and preseed host mix as soon as `/app0` is mounted.
/// Safe to call repeatedly; no-ops when detached or already indexed.
pub fn ensureAudioIndexed() void {
    const io = active_io orelse return;
    const directory = root orelse return;
    audio_fs.ensureIndexed(directory, io);
}

/// After the first VideoOut present, load a short attract bed into the host mix.
pub fn ensureAudioMixAfterPresent() void {
    const io = active_io orelse return;
    const directory = root orelse return;
    audio_fs.noteFirstPresent();
    audio_fs.maybePreseedAfterPresent(directory, io);
}

pub fn attachedRoot() ?std.Io.Dir {
    return root;
}

pub fn attachedIo() ?std.Io {
    return active_io;
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
    // Creation flags are refused everywhere, devices included: a title asking
    // to create `/dev/gc` has misunderstood something, and answering it would
    // hide that.
    if (flags & (O.creat | O.trunc | O.excl) != 0) return Error.ReadOnly;
    if (deviceForPath(path)) |device| return openDevice(device, path);

    const io = active_io orelse return Error.NotAttached;
    const directory = root orelse return Error.NotAttached;

    if (flags & O.accmode != O.rdonly) return Error.ReadOnly;
    if (flags & (O.creat | O.trunc | O.excl | O.append) != 0) return Error.ReadOnly;

    const relative = stripMount(path) orelse return Error.NotFound;
    if (relative.len > maximum_path) return Error.InvalidArgument;

    if (flags & O.directory != 0) return openDirectory(path, relative, io, directory);

    const file = directory.openFile(io, relative, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => {
            // Sparse dumps omit loose Media/Resources/audio/**.wav; serve PCM
            // extracted from FSB5 banks inside resources.resource instead.
            return openVirtualAudio(path, relative, io, directory);
        },
        error.IsDir => return openDirectory(path, relative, io, directory),
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

fn openDirectory(
    path: []const u8,
    relative: []const u8,
    io: std.Io,
    root_directory: std.Io.Dir,
) Error!i32 {
    var directory = root_directory.openDir(io, relative, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => return Error.NotFound,
        else => return Error.IoFailed,
    };
    errdefer directory.close(io);
    const iterator = directory.iterateAssumeFirstIteration();

    table_lock.lock();
    defer table_lock.unlock();
    for (&open_files, 0..) |*slot, index| {
        if (slot.* != null) continue;
        var entry = OpenFile{
            .directory = directory,
            .directory_iterator = iterator,
        };
        entry.path_length = @min(path.len, maximum_path);
        @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
        slot.* = entry;
        return first_descriptor + @as(i32, @intCast(index));
    }
    return Error.TooManyOpenFiles;
}

fn openVirtualAudio(path: []const u8, relative: []const u8, io: std.Io, directory: std.Io.Dir) Error!i32 {
    const resolved = audio_fs.resolveVirtualWav(relative, directory, io, std.heap.page_allocator) catch {
        return Error.NotFound;
    };

    table_lock.lock();
    defer table_lock.unlock();

    for (&open_files, 0..) |*slot, index| {
        if (slot.* != null) continue;
        var entry = OpenFile{ .memory = resolved.bytes, .size = resolved.size };
        entry.path_length = @min(path.len, maximum_path);
        @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
        slot.* = entry;
        return first_descriptor + @as(i32, @intCast(index));
    }
    return Error.TooManyOpenFiles;
}

/// Hands out a descriptor onto a device.
///
/// Two things differ from opening a file. The access mode is not examined: a
/// control request carries data both ways whatever the descriptor was opened
/// for, so a driver opening its device for writing is asking for control, not
/// for stores into a file. And no mount is required — a device is not reached
/// through the title's filesystem, and refusing it because no game directory
/// happens to be attached would tie together two unrelated things.
fn openDevice(device: Device, path: []const u8) Error!i32 {
    table_lock.lock();
    defer table_lock.unlock();

    for (&open_files, 0..) |*slot, index| {
        if (slot.* != null) continue;
        var entry = OpenFile{ .device = device };
        entry.path_length = @min(path.len, maximum_path);
        @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
        slot.* = entry;
        return first_descriptor + @as(i32, @intCast(index));
    }
    return Error.TooManyOpenFiles;
}

/// The device a descriptor names, if it names one.
///
/// Control requests arrive with nothing but a descriptor number, so this is how
/// the layer answering them learns which device is being addressed.
pub fn deviceOf(descriptor: i32) ?Device {
    table_lock.lock();
    defer table_lock.unlock();
    const slot = slotOf(descriptor) orelse return null;
    const entry = slot.* orelse return null;
    return entry.device;
}

pub fn close(descriptor: i32) Error!void {
    table_lock.lock();
    defer table_lock.unlock();

    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = slot.* orelse return Error.BadDescriptor;
    if (entry.file) |file| {
        const io = active_io orelse return Error.NotAttached;
        file.close(io);
    }
    if (entry.directory) |directory| {
        const io = active_io orelse return Error.NotAttached;
        directory.close(io);
    }
    if (entry.memory) |memory| {
        std.heap.page_allocator.free(memory);
    }
    slot.* = null;
}

/// Reads from the descriptor's own position and advances it.
pub fn read(descriptor: i32, buffer: []u8) Error!usize {
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
    const device = slot.*.?.device;
    if (slot.*.?.directory != null) {
        table_lock.unlock();
        return Error.NotSupported;
    }
    if (slot.*.?.memory) |memory| {
        table_lock.unlock();
        if (offset >= memory.len) return 0;
        const available = memory.len - offset;
        const count = @min(buffer.len, available);
        @memcpy(buffer[0..count], memory[offset .. offset + count]);
        table_lock.lock();
        defer table_lock.unlock();
        if (slot.*) |*entry| {
            if (entry.memory != null) entry.offset = offset + count;
        }
        return count;
    }
    const file = slot.*.?.file orelse {
        table_lock.unlock();
        // The entropy device is read like a file even though nothing is stored
        // behind it, which is the one exception to a device having no contents.
        if (device == .random) return fillWithEntropy(buffer);
        return Error.NotSupported;
    };
    table_lock.unlock();

    // Looked up only once the descriptor is known to be a file: what a
    // descriptor *is* does not depend on whether a mount happens to be
    // attached, and diagnosing it by the mount would mislabel a device.
    const io = active_io orelse return Error.NotAttached;
    const count = file.readPositionalAll(io, buffer, offset) catch return Error.IoFailed;

    table_lock.lock();
    defer table_lock.unlock();
    // The descriptor may have been closed while the read ran; advancing a
    // reused slot would corrupt an unrelated file's position.
    if (slot.*) |*entry| {
        if (entry.file) |current| {
            if (current.handle == file.handle) entry.offset = offset + count;
        }
    }
    return count;
}

/// Reads from an explicit offset without disturbing the descriptor's position.
pub fn pread(descriptor: i32, buffer: []u8, offset: u64) Error!usize {
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

    if (entry.directory != null) return Error.NotSupported;
    if (entry.memory) |memory| {
        if (offset >= memory.len) return 0;
        const available = memory.len - offset;
        const count = @min(buffer.len, available);
        @memcpy(buffer[0..count], memory[offset .. offset + count]);
        return count;
    }
    const file = entry.file orelse {
        // Reading entropy at an offset is the same as reading it anywhere: the
        // device has no positions, so an offset names nothing to skip.
        if (entry.device == .random) return fillWithEntropy(buffer);
        return Error.NotSupported;
    };
    const io = active_io orelse return Error.NotAttached;
    return file.readPositionalAll(io, buffer, offset) catch Error.IoFailed;
}

pub fn seek(descriptor: i32, offset: i64, whence: i32) Error!i64 {
    table_lock.lock();
    defer table_lock.unlock();

    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = if (slot.*) |*value| value else return Error.BadDescriptor;
    // A device has no contents to hold a position in.
    if (entry.device != null or entry.directory != null) return Error.NotSupported;

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

/// Describes a device as what it is: a character device of no length.
///
/// A caller that checks before opening is deciding whether the device exists,
/// and a size of zero is the truthful answer for something that holds nothing.
fn fillDeviceStat(out: *Stat) void {
    out.* = .{};
    out.mode = mode_ifchr | mode_read_write;
    out.blksize = 512;
}

pub fn stat(path: []const u8, out: *Stat) Error!void {
    if (deviceForPath(path) != null) {
        fillDeviceStat(out);
        return;
    }

    const io = active_io orelse return Error.NotAttached;
    const directory = root orelse return Error.NotAttached;

    const relative = stripMount(path) orelse return Error.NotFound;

    const info = directory.statFile(io, relative, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => {
            if (audio_fs.virtualWavSize(relative, directory, io)) |size| {
                fillStat(out, size, false);
                return;
            }
            return Error.NotFound;
        },
        else => return Error.IoFailed,
    };
    fillStat(out, info.size, info.kind == .directory);
}

pub fn fstat(descriptor: i32, out: *Stat) Error!void {
    table_lock.lock();
    defer table_lock.unlock();

    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = slot.* orelse return Error.BadDescriptor;
    if (entry.device != null) {
        fillDeviceStat(out);
        return;
    }
    fillStat(out, entry.size, entry.directory != null);
}

fn directoryEntryHash(name: []const u8) u32 {
    var hash: u32 = 2_166_136_261;
    for (name) |byte| {
        hash ^= byte;
        hash *%= 16_777_619;
    }
    return hash;
}

/// Writes one PS5/BSD directory record. The ABI uses a fixed 512-byte record:
/// inode, record length, type, name length, then a zero-terminated name.
pub fn getDents(descriptor: i32, buffer: []u8, base_position: ?*u64) Error!usize {
    if (buffer.len < 512) return Error.InvalidArgument;
    const io = active_io orelse return Error.NotAttached;

    table_lock.lock();
    defer table_lock.unlock();
    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = if (slot.*) |*value| value else return Error.BadDescriptor;
    if (entry.directory == null) return Error.InvalidArgument;
    if (base_position) |position| position.* = entry.directory_index;

    var kind: std.Io.File.Kind = .directory;
    const name: []const u8 = switch (entry.directory_index) {
        0 => ".",
        1 => "..",
        else => blk: {
            const iterator = if (entry.directory_iterator) |*value| value else return Error.IoFailed;
            const child = iterator.next(io) catch return Error.IoFailed;
            const found = child orelse return 0;
            kind = found.kind;
            break :blk found.name;
        },
    };

    const name_length = @min(name.len, 255);
    @memset(buffer[0..512], 0);
    std.mem.writeInt(u32, buffer[0..4], directoryEntryHash(name[0..name_length]), .little);
    std.mem.writeInt(u16, buffer[4..6], 512, .little);
    buffer[6] = if (kind == .directory) 4 else 8;
    buffer[7] = @intCast(name_length);
    @memcpy(buffer[8 .. 8 + name_length], name[0..name_length]);
    entry.directory_index += 1;
    return 512;
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

test "device paths are recognised however they are spelled" {
    try testing.expectEqual(Device.graphics, deviceForPath("/dev/gc").?);
    try testing.expectEqual(Device.dip_switches, deviceForPath("/dev/dipsw").?);
    try testing.expectEqual(Device.graphics, deviceForPath("/DEV/GC").?);

    // Nothing else is a device, including paths that merely start alike.
    try testing.expect(deviceForPath("/dev/gcx") == null);
    try testing.expect(deviceForPath("/dev/") == null);
    try testing.expect(deviceForPath("/app0/dev/gc") == null);
}

test "a device opens without a mount and is not a file" {
    // A device is not reached through the title's filesystem, so whether a game
    // directory happens to be attached has nothing to do with it.
    detach();
    const fd = try open("/dev/gc", O.rdonly);
    defer close(fd) catch {};

    try testing.expectEqual(Device.graphics, deviceOf(fd).?);
    try testing.expectEqualStrings("/dev/gc", pathOf(fd).?);

    // Reading and seeking a device is not how one is driven, and saying so is
    // better than reporting an empty file.
    var buffer: [8]u8 = undefined;
    try testing.expectError(Error.NotSupported, read(fd, &buffer));
    try testing.expectError(Error.NotSupported, pread(fd, &buffer, 0));
    try testing.expectError(Error.NotSupported, seek(fd, 0, Seek.end));
}

test "the entropy device is read like a file, and does not repeat itself" {
    // The one device that is driven by reading it. A fixed sequence would make
    // every run of a game deal the same cards, which a player sees and nothing
    // in the title explains.
    detach();
    for ([_][]const u8{ "/dev/urandom", "/dev/random" }) |path| {
        const fd = try open(path, O.rdonly);
        defer close(fd) catch {};
        try testing.expectEqual(Device.random, deviceOf(fd).?);

        var first: [64]u8 = @splat(0);
        var second: [64]u8 = @splat(0);
        try testing.expectEqual(first.len, try read(fd, &first));
        try testing.expectEqual(second.len, try read(fd, &second));
        try testing.expect(!std.mem.eql(u8, &first, &second));

        // An offset names nothing to skip on a device with no positions, so a
        // positional read is still a read.
        var third: [32]u8 = @splat(0);
        try testing.expectEqual(third.len, try pread(fd, &third, 4096));
        try testing.expect(!std.mem.allEqual(u8, &third, 0));

        // Asking for nothing yields nothing rather than failing.
        try testing.expectEqual(@as(usize, 0), try read(fd, &.{}));
    }
}

test "a device is described as a device" {
    var info: Stat = undefined;
    try stat("/dev/gc", &info);
    try testing.expect(info.mode & mode_ifchr != 0);
    try testing.expect(info.mode & mode_ifreg == 0);
    try testing.expectEqual(@as(i64, 0), info.size);

    detach();
    const fd = try open("/dev/dipsw", O.rdonly);
    defer close(fd) catch {};
    try fstat(fd, &info);
    try testing.expect(info.mode & mode_ifchr != 0);
}

test "creating a device is refused rather than answered" {
    detach();
    try testing.expectError(Error.ReadOnly, open("/dev/gc", O.rdonly | O.creat));
}

test "a closed device descriptor stops naming a device" {
    detach();
    const fd = try open("/dev/gc", O.rdonly);
    try close(fd);
    try testing.expect(deviceOf(fd) == null);
    try testing.expectError(Error.BadDescriptor, close(fd));
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
    const directory = try open("/app0/sub", O.rdonly | O.directory);
    try close(directory);

    var buffer: [4]u8 = undefined;
    try testing.expectError(Error.BadDescriptor, read(99, &buffer));
    try testing.expectError(Error.BadDescriptor, close(99));
    // The standard streams are not filesystem descriptors.
    try testing.expectError(Error.BadDescriptor, read(1, &buffer));
}

test "directory descriptors enumerate BSD dirent records" {
    var fixture = try Fixture.init("data");
    defer fixture.deinit();

    const fd = try open("/app0/sub", O.rdonly | O.directory);
    defer close(fd) catch {};
    var record: [512]u8 = undefined;
    var base: u64 = 99;

    try testing.expectEqual(@as(usize, 512), try getDents(fd, &record, &base));
    try testing.expectEqual(@as(u64, 0), base);
    try testing.expectEqualStrings(".", std.mem.sliceTo(record[8..], 0));
    try testing.expectEqual(@as(u8, 4), record[6]);

    _ = try getDents(fd, &record, null); // `..`
    try testing.expectEqual(@as(usize, 512), try getDents(fd, &record, null));
    try testing.expectEqualStrings("inner.txt", std.mem.sliceTo(record[8..], 0));
    try testing.expectEqual(@as(u8, 8), record[6]);
    try testing.expectEqual(@as(usize, 0), try getDents(fd, &record, null));
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
