// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The files a title can see.
//!
//! A title addresses its own content through mount points rather than host
//! paths: everything it ships lives under `/app0`. This maps those paths onto a
//! host directory and hands out descriptors.
//!
//! Title content remains read-only. Saves and downloaded/generated data live
//! on explicitly writable mounts, while `/devlog` is redirected to the
//! emulator's `out` directory. None can alter installed game data.

const std = @import("std");
const builtin = @import("builtin");
const audio_fs = @import("audio_fs.zig");
const font_substitutes = @import("font_substitutes.zig");
const savedata = @import("savedata.zig");
const boot_config = @import("boot_config.zig");
const guest_memory = @import("memory");
const zarchive = @import("zarchive");

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
    /// An exclusive create found the file already there.
    Exists,
    CrossDevice,
    NotDirectory,
    DirectoryNotEmpty,
    Busy,
    NoSpace,
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
const devlog_root = "/devlog";
const devlog_app = "/devlog/app";
const devlog_file = "/devlog/app/debug.log";
const host_devlog_file = "out/guest-debug.log";

fn isDevlogDirectory(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(path, devlog_root) or
        std.ascii.eqlIgnoreCase(path, devlog_app);
}

fn isDevlogFile(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(path, devlog_file);
}

/// Whether `path` names something inside the title's writable diagnostic tree.
fn isDevlogTree(path: []const u8) bool {
    if (path.len <= devlog_app.len) return false;
    if (!std.ascii.eqlIgnoreCase(path[0..devlog_app.len], devlog_app)) return false;
    return path[devlog_app.len] == '/';
}

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

/// Which host directory a mount point resolves against.
///
/// Everything a title ships is read-only and lives together. Saves and
/// downloaded/generated title data are writable and outlive the installation,
/// but the console exposes them through separate mount points. A path therefore
/// has to say which host directory it belongs to before it can be resolved.
pub const Mount = enum { title, savedata, download, temporary };

const MountPoint = struct { prefix: []const u8, mount: Mount };

/// Mount points a title uses to name its own files.
const mount_points = [_]MountPoint{
    .{ .prefix = "/app0/", .mount = .title },
    .{ .prefix = "/hostapp/", .mount = .title },
    .{ .prefix = "/host/", .mount = .title },
    .{ .prefix = "/savedata0/", .mount = .savedata },
    .{ .prefix = "/download0/", .mount = .download },
    .{ .prefix = "/temp0/", .mount = .temporary },
};

/// Whether a path names a mount itself rather than one of its children.
///
/// `stripMount` deliberately has no relative child to return for these paths,
/// but filesystem APIs still have to expose the mount as a directory. Managed
/// runtimes commonly stat every parent before opening a file; reporting
/// `/app0` missing makes an existing `/app0/content.txt` look unreachable.
fn isMountRoot(path: []const u8) bool {
    for (mount_points) |point| {
        const without_slash = point.prefix[0 .. point.prefix.len - 1];
        if (std.ascii.eqlIgnoreCase(path, without_slash) or
            std.ascii.eqlIgnoreCase(path, point.prefix)) return true;
    }
    return false;
}

/// Which host directory a guest path resolves against.
///
/// Anything that names no mount is a path relative to the title's own files,
/// which is how the loader refers to them.
pub fn mountOf(path: []const u8) Mount {
    for (mount_points) |point| {
        const without_slash = point.prefix[0 .. point.prefix.len - 1];
        if (path.len >= point.prefix.len and
            std.ascii.eqlIgnoreCase(path[0..point.prefix.len], point.prefix)) return point.mount;
        if (std.ascii.eqlIgnoreCase(path, without_slash)) return point.mount;
    }
    return .title;
}

/// Strips a mount prefix, yielding a path relative to the title root.
///
/// Returns null for a path outside every known mount: only content the title
/// ships is visible, and quietly resolving anything else against the host
/// filesystem would expose more than a title can see on hardware.
pub fn stripMount(path: []const u8) ?[]const u8 {
    for (mount_points) |point| {
        if (path.len >= point.prefix.len and
            std.ascii.eqlIgnoreCase(path[0..point.prefix.len], point.prefix))
        {
            const rest = path[point.prefix.len..];
            return if (rest.len == 0) null else rest;
        }
    }
    // A relative path is already how the loader knows its own files.
    if (path.len != 0 and path[0] != '/') return path;
    return null;
}

/// Resolves a guest path relative to its mount without ever letting `..`
/// escape the title root.
///
/// Unreal Engine builds its base directory as `<app>/Binaries/<platform>` and
/// consequently opens cooked content through paths such as
/// `../../../TetrisEffect/Content/Paks`. On the console those leading parents
/// are clamped at `/app0`; passing them directly to the host directory instead
/// walks above the title and makes the engine enumerate the wrong directory.
fn normalizedMountRelative(path: []const u8, storage: *[maximum_path]u8) ?[]const u8 {
    if (isMountRoot(path)) {
        storage[0] = '.';
        return storage[0..1];
    }
    const raw = stripMount(path) orelse return null;
    if (raw.len > maximum_path) return null;

    // One start per possible non-empty segment. With a 256-byte path there can
    // be no more than 128 one-byte segments separated by slashes, but keeping a
    // full-path-sized stack makes the bound self-evident and cheap.
    var starts: [maximum_path]usize = undefined;
    var depth: usize = 0;
    var written: usize = 0;
    var cursor: usize = 0;
    while (cursor < raw.len) {
        while (cursor < raw.len and (raw[cursor] == '/' or raw[cursor] == '\\')) cursor += 1;
        const begin = cursor;
        while (cursor < raw.len and raw[cursor] != '/' and raw[cursor] != '\\') cursor += 1;
        const segment = raw[begin..cursor];
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (depth != 0) {
                depth -= 1;
                written = starts[depth];
            }
            continue;
        }

        // A drive-qualified segment would make a Windows host API discard the
        // mount root. Guest filenames cannot contain a colon, so reject it.
        if (std.mem.indexOfScalar(u8, segment, ':') != null) return null;
        const old_written = written;
        const needed = segment.len + @as(usize, if (written == 0) 0 else 1);
        if (written + needed > storage.len) return null;
        if (written != 0) {
            storage[written] = '/';
            written += 1;
        }
        @memcpy(storage[written .. written + segment.len], segment);
        written += segment.len;
        starts[depth] = old_written;
        depth += 1;
    }

    // std.Io.Dir names its own root as "." rather than an empty path.
    if (written == 0) {
        storage[0] = '.';
        written = 1;
    }
    return storage[0..written];
}

/// Rewrites `relative`, in place, to the case the host directory uses.
///
/// Console storage ignores case, as NTFS does, so titles routinely open
/// `Data/Maps.pak` for a file shipped as `data/maps.pak`. Linux file systems do
/// not ignore it. When the path does not exist as written, each segment is
/// looked up in its parent and replaced by the one entry naming it in another
/// case; ASCII case folding keeps the length. The walk stops at the first
/// segment with no match, so a path being created keeps its new leaf as given
/// beneath parents spelled the host's way.
fn matchHostCase(relative: []u8, io: std.Io, base: std.Io.Dir) void {
    if (comptime builtin.os.tag != .linux) return;
    if (std.mem.eql(u8, relative, ".")) return;
    if (base.statFile(io, relative, .{})) |_| return else |_| {}

    var begin: usize = 0;
    while (begin < relative.len) {
        const end = std.mem.indexOfScalarPos(u8, relative, begin, '/') orelse relative.len;
        const prefix = relative[0..end];
        if (base.statFile(io, prefix, .{})) |_| {} else |_| {
            const parent_path = if (begin == 0) "." else relative[0 .. begin - 1];
            var parent = base.openDir(io, parent_path, .{ .iterate = true }) catch return;
            defer parent.close(io);
            const segment = relative[begin..end];
            var iterator = parent.iterate();
            const found = while (iterator.next(io) catch null) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.name, segment)) {
                    @memcpy(segment, entry.name);
                    break true;
                }
            } else false;
            if (!found) return;
        }
        begin = end + 1;
    }
}

/// Normalizes a guest path below `base` and matches it to the host's case.
fn hostRelative(path: []const u8, storage: *[maximum_path]u8, io: std.Io, base: std.Io.Dir) ?[]const u8 {
    const relative = normalizedMountRelative(path, storage) orelse return null;
    matchHostCase(storage[0..relative.len], io, base);
    return relative;
}

/// Returns a normalized path below the attached title root for host helpers
/// which need to consume the same file through an external decoder. Parent
/// segments remain clamped at the mount and drive-qualified paths are rejected.
pub fn mountRelative(path: []const u8, storage: *[maximum_path]u8) ?[]const u8 {
    const io = active_io orelse return normalizedMountRelative(path, storage);
    const base = rootFor(mountOf(path)) orelse return normalizedMountRelative(path, storage);
    return hostRelative(path, storage, io, base);
}

const OpenFile = struct {
    descriptor: i32 = -1,
    /// Null for a device node, which has no host file behind it.
    file: ?std.Io.File = null,
    /// Directory descriptors retain their iterator between getdents calls.
    directory: ?std.Io.Dir = null,
    directory_iterator: ?std.Io.Dir.Iterator = null,
    /// Archive node behind a directory descriptor on a `.zar` title mount.
    archive_dir: ?u32 = null,
    /// Archive node behind a file descriptor on a `.zar` title mount.
    /// Reads go through the reader's block cache; nothing is extracted.
    archive_node: ?u32 = null,
    /// The first two directory entries are synthesized as `.` and `..`.
    directory_index: u64 = 0,
    /// An entry taken from the iterator that did not fit the caller's buffer.
    /// The iterator cannot hand it back, so it waits here for the next call.
    pending_name: [maximum_name]u8 = undefined,
    pending_length: u16 = 0,
    pending_directory: bool = false,
    device: ?Device = null,
    /// An offline POSIX socket. It owns only a descriptor slot; network
    /// operations decide whether to acknowledge local state or report ENETDOWN.
    virtual_socket: bool = false,
    /// Set for a descriptor inside a writable mount.
    writable: bool = false,
    /// `/devlog/app/debug.log`, redirected outside the read-only title mount.
    diagnostic_log: bool = false,
    /// In-memory `/devlog` directory; it owns no host directory handle.
    diagnostic_directory: bool = false,
    /// In-memory payload for synthesised files (FSB-backed virtual WAVs).
    /// Owned by this descriptor; freed on close via page_allocator.
    memory: ?[]u8 = null,
    /// `memory` is a bundled read-only payload, such as a substitute font,
    /// that outlives the descriptor and must not be freed with it.
    borrowed_memory: bool = false,
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
/// A ZArchive dump serving `/app0` instead of a host directory. Borrowed for
/// the mount lifetime; the opener (game-run, tests) owns and closes it.
var title_archive: ?*zarchive.Reader = null;
/// Where `/savedata0` resolves. Absent until a title's save directory has been
/// prepared, which is what keeps a title without one from writing into its own
/// installation.
var savedata_root: ?std.Io.Dir = null;
/// Where `/download0` resolves. Unlike `/app0`, titles may create generated
/// configuration, caches, and downloaded content here.
var download_root: ?std.Io.Dir = null;
/// Scratch storage exposed by AppContentTemporaryDataMount2. Keep it separate
/// from both installed content and saves: Unity stages new saves here first.
var temporary_root: ?std.Io.Dir = null;
var open_files: [maximum_open_files]?OpenFile = @splat(null);
// Unity's PS5 read-ahead cache keys buffered bytes by the guest descriptor,
// including across opens on different threads. Recycling a table slot must
// not give a different file the same cache identity during this process.
var next_descriptor: u32 = first_descriptor;
var table_lock: Lock = .{};
var virtual_socket_signal: std.atomic.Value(u8) = .init(0);
var guest_address_space: ?*guest_memory.AddressSpace = null;
// HLE calls can run on a guest stack, including pages observed by the GPU.
// Keep the synchronous I/O destination in host TLS, outside guest mappings,
// and reuse it without growing the guest stack or allocating on every read.
threadlocal var host_file_read_scratch: [64 * 1024]u8 = undefined;

/// Shares libkernel's guest mapping lifetime with host file reads.
pub fn attachGuestAddressSpace(space: ?*guest_memory.AddressSpace) void {
    @atomicStore(?*guest_memory.AddressSpace, &guest_address_space, space, .release);
}

var boot_override: [boot_config.maximum_bytes]u8 = undefined;
var boot_override_length: usize = 0;
const unreal_command_path = "ue4commandline.txt";
var unreal_command_override: [64 * 1024]u8 = undefined;
var unreal_command_override_length: usize = 0;

fn isLaunchOverridePath(relative: []const u8) bool {
    return std.ascii.eqlIgnoreCase(relative, boot_config.path) or std.ascii.eqlIgnoreCase(relative, unreal_command_path);
}

/// The caller holds table_lock; open FDs take their own immutable copy.
fn launchOverride(relative: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(relative, boot_config.path) and boot_override_length != 0)
        return boot_override[0..boot_override_length];
    if (std.ascii.eqlIgnoreCase(relative, unreal_command_path) and unreal_command_override_length != 0)
        return unreal_command_override[0..unreal_command_override_length];
    return null;
}

/// Use Unreal's raster rendering path through its own command-line option.
/// This is a launch preference, not shader elision. Installed files, archives
/// and saves remain unchanged; reattaching /app0 removes the preference.
pub fn configureUnrealRayTracing(enabled: bool) Error!bool {
    const io = active_io orelse return Error.NotAttached;
    table_lock.lock();
    defer table_lock.unlock();
    unreal_command_override_length = 0;
    if (enabled) return false;
    var original: [64 * 1024]u8 = undefined;
    const source = if (title_archive) |archive| source: {
        const node = archive.lookup(unreal_command_path) orelse return false;
        if (!archive.isFile(node) or archive.fileSize(node) > original.len) return false;
        const size = archive.readAt(node, 0, &original) catch return false;
        break :source original[0..size];
    } else (root orelse return Error.NotAttached).readFile(io, unreal_command_path, &original) catch return false;
    // This adapter handles the UTF-8 launch file, not arbitrary binary data.
    if (std.mem.indexOfScalar(u8, source, 0) != null) return false;
    var tokens = std.mem.tokenizeAny(u8, source, " \t\r\n");
    while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(token, "-noraytracing")) return false;
    const replacement = std.fmt.bufPrint(&unreal_command_override, "{s} -noraytracing", .{std.mem.trimEnd(u8, source, " \t\r\n")}) catch return false;
    unreal_command_override_length = replacement.len;
    return true;
}

/// Called before guest threads start. All reads/stat calls see one immutable
/// launch document, including positional reads and independently opened FDs.
pub fn configureDisplay(width: u32, height: u32) Error!bool {
    const io = active_io orelse return Error.NotAttached;
    if (title_archive) |archive| {
        const node = archive.lookup(boot_config.path) orelse return false;
        if (!archive.isFile(node)) return false;
        var original: [boot_config.maximum_bytes]u8 = undefined;
        const size = archive.readAt(node, 0, &original) catch return false;
        // A boot document larger than the rewrite buffer cannot be overlaid;
        // run without the override rather than with a truncated one.
        if (size == original.len and archive.fileSize(node) > original.len) return false;
        table_lock.lock();
        defer table_lock.unlock();
        boot_override_length = 0;
        const replacement = boot_config.rewrite(original[0..size], &boot_override, width, height) catch return Error.IoFailed;
        if (replacement) |bytes| boot_override_length = bytes.len;
        return replacement != null;
    }
    const directory = root orelse return Error.NotAttached;
    var original: [boot_config.maximum_bytes]u8 = undefined;
    const source = directory.readFile(io, boot_config.path, &original) catch return false;
    table_lock.lock();
    defer table_lock.unlock();
    boot_override_length = 0;
    const replacement = boot_config.rewrite(source, &boot_override, width, height) catch return Error.IoFailed;
    if (replacement) |bytes| boot_override_length = bytes.len;
    return replacement != null;
}

/// Makes a host directory visible to the title as `/app0`.
pub fn attach(io: std.Io, directory: std.Io.Dir) void {
    table_lock.lock();
    defer table_lock.unlock();
    active_io = io;
    root = directory;
    clearArchiveDescriptorsLocked();
    title_archive = null;
    boot_override_length = 0;
    unreal_command_override_length = 0;
    virtual_socket_signal.store(0, .release);
}

/// Makes a ZArchive dump visible to the title as `/app0`, streamed read-only
/// without extracting. The reader is borrowed, not owned.
pub fn attachArchive(io: std.Io, reader: *zarchive.Reader) void {
    table_lock.lock();
    defer table_lock.unlock();
    active_io = io;
    root = null;
    clearArchiveDescriptorsLocked();
    title_archive = reader;
    boot_override_length = 0;
    unreal_command_override_length = 0;
    virtual_socket_signal.store(0, .release);
}

/// Drops descriptors bound to an archive dump. Node indexes name entries in
/// one reader; a mount switch must not let them address another.
fn clearArchiveDescriptorsLocked() void {
    for (&open_files) |*slot| {
        if (slot.*) |entry| {
            if (entry.archive_node != null or entry.archive_dir != null) slot.* = null;
        }
    }
}

/// Makes a host directory visible to the title as `/savedata0`.
pub fn attachSaveData(directory: std.Io.Dir) void {
    table_lock.lock();
    defer table_lock.unlock();
    savedata_root = directory;
}

/// Makes a per-title host directory visible as writable `/download0`.
/// The caller retains ownership of the directory handle.
pub fn attachDownloadData(directory: std.Io.Dir) void {
    table_lock.lock();
    defer table_lock.unlock();
    download_root = directory;
}

pub fn detachDownloadData() void {
    table_lock.lock();
    defer table_lock.unlock();
    download_root = null;
}

/// The caller owns this per-title scratch directory until detachment.
pub fn attachTemporaryData(directory: std.Io.Dir) void {
    table_lock.lock();
    defer table_lock.unlock();
    temporary_root = directory;
}

pub fn detachTemporaryData() void {
    table_lock.lock();
    defer table_lock.unlock();
    temporary_root = null;
}

/// The host directory a mount resolves against, if one is attached.
fn rootFor(mount: Mount) ?std.Io.Dir {
    return switch (mount) {
        .title => root,
        .savedata => savedata_root,
        .download => download_root,
        .temporary => temporary_root,
    };
}

pub fn attachedSaveDataRoot() ?std.Io.Dir {
    return savedata_root;
}

/// Where every title's saves are kept, and which title is running.
///
/// Set once at startup. The directory is opened rather than kept as a path so a
/// mount cannot be redirected by anything that renames the tree underneath it.
var savedata_home: ?std.Io.Dir = null;
var title_identifier_storage: [savedata.maximum_slot_name]u8 = undefined;
var title_identifier_length: usize = 0;
/// The slot `/savedata0` currently resolves to. The descriptive parameters
/// belong to it rather than to the files inside, so they are addressed by name
/// rather than through the mount.
var mounted_slot_storage: [savedata.maximum_slot_name]u8 = undefined;
var mounted_slot_length: usize = 0;

pub fn mountedSaveDataSlot() []const u8 {
    return mounted_slot_storage[0..mounted_slot_length];
}

pub fn attachSaveDataHome(directory: std.Io.Dir, title_id: []const u8) void {
    table_lock.lock();
    defer table_lock.unlock();
    savedata_home = directory;
    title_identifier_length = @min(title_id.len, title_identifier_storage.len);
    @memcpy(title_identifier_storage[0..title_identifier_length], title_id[0..title_identifier_length]);
}

pub fn titleIdentifier() []const u8 {
    return title_identifier_storage[0..title_identifier_length];
}

/// Some extracted retail packages rename the generic title metadata record to
/// the numeric suffix of the product code. The guest still asks for the
/// mounted `/app0/cache_ps5/t00000.dat` name that the console resolves.
fn titleCacheMetadataAlias(relative: []const u8, storage: []u8) ?[]const u8 {
    if (!std.ascii.eqlIgnoreCase(relative, "cache_ps5/t00000.dat")) return null;
    const identifier = titleIdentifier();
    if (identifier.len <= 4) return null;
    const numeric = identifier[4..];
    for (numeric) |character| if (!std.ascii.isDigit(character)) return null;
    return std.fmt.bufPrint(storage, "cache_ps5/t{s}.dat", .{numeric}) catch null;
}

/// Points `/savedata0` at one slot of the running title.
///
/// Answers false when the slot does not exist and the title did not ask for one
/// to be made: a title probing for a save it has never written expects to be
/// told so, and inventing an empty slot would have it load a save that was
/// never there.
pub const SaveDataMountOutcome = enum { missing, existed, created };

/// Deletes only an unmounted slot belonging to the running title. Unlike a
/// creating mount, deletion must reject names that would be sanitized into a
/// different slot. Open each parent separately without following symlinks.
pub fn deleteSaveDataSlot(slot: []const u8) (Error || error{Busy})!void {
    var checked: [savedata.maximum_slot_name]u8 = undefined;
    if (slot.len == 0 or slot.len >= checked.len or
        !std.mem.eql(u8, slot, savedata.sanitizeName(slot, &checked)))
        return Error.InvalidArgument;
    table_lock.lock();
    defer table_lock.unlock();
    if (savedata_root != null and std.ascii.eqlIgnoreCase(slot, mountedSaveDataSlot()))
        return error.Busy;
    const io = active_io orelse return Error.NotAttached;
    const home = savedata_home orelse return Error.NotAttached;
    const title = titleIdentifier();
    if (title.len == 0 or !std.mem.eql(u8, title, savedata.sanitizeName(title, &checked)))
        return Error.InvalidArgument;
    const directory = home.openDir(io, title, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return Error.IoFailed,
    };
    defer directory.close(io);
    directory.deleteTree(io, slot) catch return Error.IoFailed;
}

pub fn mountSaveDataSlot(slot: []const u8, may_create: bool) Error!SaveDataMountOutcome {
    const io = active_io orelse return Error.NotAttached;
    const home = savedata_home orelse return Error.NotAttached;

    var slot_storage: [savedata.maximum_slot_name]u8 = undefined;
    const safe_slot = savedata.sanitizeName(slot, &slot_storage);
    var identifier_storage: [savedata.maximum_slot_name]u8 = undefined;
    const safe_title = savedata.sanitizeName(titleIdentifier(), &identifier_storage);

    var path_storage: [maximum_path]u8 = undefined;
    const relative = savedata.joinPath(&path_storage, &.{ safe_title, safe_slot }) orelse
        return Error.InvalidArgument;

    var created = false;
    const directory = home.openDir(io, relative, .{ .iterate = true }) catch |err| blk: {
        switch (err) {
            error.FileNotFound, error.NotDir, error.BadPathName => {},
            else => return Error.IoFailed,
        }
        if (!may_create) return .missing;
        home.createDirPath(io, relative) catch return Error.IoFailed;
        created = true;
        break :blk home.openDir(io, relative, .{ .iterate = true }) catch return Error.IoFailed;
    };

    // A named mount tests whether the container exists, not whether the title
    // has written a nonempty file yet. Games can create/unmount a container,
    // then mount it read-only to probe their settings before the first write.
    // Treating that valid empty container as missing aborts first-run startup
    // (Jets 'n' Guns 2). Do not infer creation status from title-owned payload.

    table_lock.lock();
    defer table_lock.unlock();
    if (savedata_root) |previous| previous.close(io);
    savedata_root = directory;
    mounted_slot_length = @min(safe_slot.len, mounted_slot_storage.len);
    @memcpy(mounted_slot_storage[0..mounted_slot_length], safe_slot[0..mounted_slot_length]);
    return if (created) .created else .existed;
}

/// Fills a buffer from the title's memory-backed save, leaving it untouched
/// where none has been stored yet.
pub fn readSaveDataMemory(buffer: []u8) void {
    const io = active_io orelse return;
    const home = savedata_home orelse return;
    var path_storage: [maximum_path]u8 = undefined;
    const relative = saveDataMemoryPath(&path_storage) orelse return;
    _ = home.readFile(io, relative, buffer) catch return;
}

/// Stores the title's memory-backed save.
pub fn writeSaveDataMemory(buffer: []const u8) Error!void {
    const io = active_io orelse return Error.NotAttached;
    const home = savedata_home orelse return Error.NotAttached;
    var identifier_storage: [savedata.maximum_slot_name]u8 = undefined;
    const safe_title = savedata.sanitizeName(titleIdentifier(), &identifier_storage);
    var directory_storage: [maximum_path]u8 = undefined;
    const directory = savedata.joinPath(&directory_storage, &.{ safe_title, savedata.memory_directory }) orelse
        return Error.InvalidArgument;
    home.createDirPath(io, directory) catch return Error.IoFailed;

    var path_storage: [maximum_path]u8 = undefined;
    const relative = saveDataMemoryPath(&path_storage) orelse return Error.InvalidArgument;
    const file = home.createFile(io, relative, .{ .truncate = true }) catch return Error.IoFailed;
    defer file.close(io);
    file.writeStreamingAll(io, buffer) catch return Error.IoFailed;
}

fn saveDataMemoryPath(storage: *[maximum_path]u8) ?[]const u8 {
    var identifier_storage: [savedata.maximum_slot_name]u8 = undefined;
    const safe_title = savedata.sanitizeName(titleIdentifier(), &identifier_storage);
    return savedata.joinPath(storage, &.{
        safe_title,
        savedata.memory_directory,
        savedata.memory_file,
    });
}

/// Names of the slots the running title has written.
///
/// A title finds its saves by asking for this list, not by opening a path it
/// already knows: which slots exist is precisely what it does not know. Leaving
/// it unanswered made a title with a save on disk behave as though it had none.
pub fn listSaveDataSlots(names: [][savedata.maximum_slot_name]u8) usize {
    const io = active_io orelse return 0;
    const home = savedata_home orelse return 0;

    var identifier_storage: [savedata.maximum_slot_name]u8 = undefined;
    const safe_title = savedata.sanitizeName(titleIdentifier(), &identifier_storage);
    var directory = home.openDir(io, safe_title, .{ .iterate = true }) catch return 0;
    defer directory.close(io);

    var found: usize = 0;
    var iterator = directory.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        // The blob behind the memory-backed API is not a save slot; a title
        // offered it as one would try to mount it and find nothing it wrote.
        if (std.mem.eql(u8, entry.name, savedata.memory_directory)) continue;

        // Save-data writes are a transaction on the console. A process killed
        // while creating a slot must therefore leave no slot for the next run
        // to discover. The host backing currently exposes writes immediately,
        // so reject directories which contain only metadata or empty staging
        // files. Otherwise a title can find the half-written slot, fail while
        // opening its missing payload, and wait forever for a load callback.
        var slot_directory = directory.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        const has_payload = saveDataDirectoryHasPayload(slot_directory, io, true, 0);
        slot_directory.close(io);
        if (!has_payload) continue;

        if (found == names.len) break;
        const length = @min(entry.name.len, savedata.maximum_slot_name - 1);
        @memset(&names[found], 0);
        @memcpy(names[found][0..length], entry.name[0..length]);
        found += 1;
    }
    return found;
}

const maximum_save_data_directory_depth = 32;

/// Whether a slot contains at least one byte of title-owned payload.
///
/// `sce_sys` contains only firmware metadata and cannot make an interrupted
/// write into a loadable save. Payloads may be nested, so inspect child
/// directories too while retaining a hard recursion bound for hostile trees.
fn saveDataDirectoryHasPayload(
    directory: std.Io.Dir,
    io: std.Io,
    skip_metadata: bool,
    depth: usize,
) bool {
    if (depth == maximum_save_data_directory_depth) return false;

    var iterator = directory.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (skip_metadata and
            std.ascii.eqlIgnoreCase(entry.name, savedata.metadata_directory)) continue;

        switch (entry.kind) {
            .file => {
                const file = directory.openFile(io, entry.name, .{}) catch continue;
                const length = file.length(io) catch 0;
                file.close(io);
                if (length != 0) return true;
            },
            .directory => {
                var child = directory.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                const has_payload = saveDataDirectoryHasPayload(child, io, false, depth + 1);
                child.close(io);
                if (has_payload) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Reads the descriptive parameters a slot recorded for itself.
pub fn readSaveDataParameters(slot: []const u8, storage: []u8) ?[]const u8 {
    const io = active_io orelse return null;
    const home = savedata_home orelse return null;
    var identifier_storage: [savedata.maximum_slot_name]u8 = undefined;
    const safe_title = savedata.sanitizeName(titleIdentifier(), &identifier_storage);
    var slot_storage: [savedata.maximum_slot_name]u8 = undefined;
    const safe_slot = savedata.sanitizeName(slot, &slot_storage);
    var path_storage: [maximum_path]u8 = undefined;
    const relative = savedata.joinPath(&path_storage, &.{
        safe_title,
        safe_slot,
        savedata.metadata_directory,
        savedata.parameter_file,
    }) orelse return null;
    return home.readFile(io, relative, storage) catch null;
}

/// Stores the descriptive parameters of a slot.
pub fn writeSaveDataParameters(slot: []const u8, contents: []const u8) Error!void {
    return writeSaveDataMetadata(slot, savedata.parameter_file, contents);
}

/// Icons are slot metadata, not game payload. Keep them under sce_sys so an
/// interrupted save containing only its icon is not advertised as complete.
pub fn writeSaveDataIcon(contents: []const u8) Error!void {
    if (savedata_root == null or mountedSaveDataSlot().len == 0) return Error.NotAttached;
    return writeSaveDataMetadata(mountedSaveDataSlot(), "icon0.png", contents);
}

fn writeSaveDataMetadata(slot: []const u8, filename: []const u8, contents: []const u8) Error!void {
    const io = active_io orelse return Error.NotAttached;
    const home = savedata_home orelse return Error.NotAttached;
    var identifier_storage: [savedata.maximum_slot_name]u8 = undefined;
    const safe_title = savedata.sanitizeName(titleIdentifier(), &identifier_storage);
    var slot_storage: [savedata.maximum_slot_name]u8 = undefined;
    const safe_slot = savedata.sanitizeName(slot, &slot_storage);

    var directory_storage: [maximum_path]u8 = undefined;
    const directory = savedata.joinPath(&directory_storage, &.{
        safe_title,
        safe_slot,
        savedata.metadata_directory,
    }) orelse return Error.InvalidArgument;
    home.createDirPath(io, directory) catch return Error.IoFailed;

    var path_storage: [maximum_path]u8 = undefined;
    const relative = savedata.joinPath(&path_storage, &.{ directory, filename }) orelse
        return Error.InvalidArgument;
    const file = home.createFile(io, relative, .{ .truncate = true }) catch return Error.IoFailed;
    defer file.close(io);
    file.writeStreamingAll(io, contents) catch return Error.IoFailed;
}

/// Stops `/savedata0` resolving. The files themselves are already on disk.
pub fn unmountSaveData() void {
    table_lock.lock();
    defer table_lock.unlock();
    if (savedata_root) |directory| {
        if (active_io) |io| directory.close(io);
    }
    savedata_root = null;
    mounted_slot_length = 0;
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
                if (entry.memory) |bytes| {
                    if (!entry.borrowed_memory) std.heap.page_allocator.free(bytes);
                }
            }
            slot.* = null;
        }
    } else {
        for (&open_files) |*slot| slot.* = null;
    }
    active_io = null;
    next_descriptor = first_descriptor;
    root = null;
    title_archive = null;
    boot_override_length = 0;
    unreal_command_override_length = 0;
    download_root = null;
    temporary_root = null;
    virtual_socket_signal.store(0, .release);
    audio_fs.reset();
}

pub fn isAttached() bool {
    return root != null or title_archive != null;
}

/// Index FSB banks and preseed host mix as soon as `/app0` is mounted.
/// Safe to call repeatedly; no-ops when detached or already indexed.
/// shortcut: banked FSB audio inside archives is not indexed yet; loose
/// files stream normally. Upgrade by teaching audio_fs to read through
/// the archive instead of a host directory.
pub fn ensureAudioIndexed() void {
    if (title_archive != null) return;
    const io = active_io orelse return;
    const directory = root orelse return;
    audio_fs.ensureIndexed(directory, io);
}

/// After the first VideoOut present, load a short attract bed into the host mix.
pub fn ensureAudioMixAfterPresent() void {
    if (title_archive != null) return;
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
    for (&open_files) |*slot| {
        if (slot.*) |*entry| {
            if (entry.descriptor == descriptor) return slot;
        }
    }
    return null;
}

/// Reuses bounded host storage while retaining a distinct guest file identity.
/// All descriptor kinds share this namespace; exhaustion never wraps an ID.
fn insertFileLocked(value: OpenFile) Error!i32 {
    if (next_descriptor > std.math.maxInt(i32)) return Error.TooManyOpenFiles;
    for (&open_files) |*slot| {
        if (slot.* != null) continue;
        var entry = value;
        entry.descriptor = @intCast(next_descriptor);
        next_descriptor += 1;
        slot.* = entry;
        return entry.descriptor;
    }
    return Error.TooManyOpenFiles;
}

/// Opens a file the title named.
///
/// Anything that would modify the filesystem is refused rather than ignored, so
/// a title cannot proceed believing its data was stored.
pub fn open(path: []const u8, flags: i32) Error!i32 {
    if (isDevlogDirectory(path)) {
        if (flags & O.directory == 0) return Error.IsDirectory;
        return openDevlogDirectory(path);
    }
    if (isDevlogFile(path)) return openDevlog(path, flags);
    if (isDevlogTree(path)) return openDevlogTree(path, flags);

    if (deviceForPath(path)) |device| {
        // A title asking to create `/dev/gc` has misunderstood something, and
        // answering it would hide that.
        if (flags & (O.creat | O.trunc | O.excl) != 0) return Error.ReadOnly;
        return openDevice(device, path);
    }

    const io = active_io orelse return Error.NotAttached;
    const mount = mountOf(path);
    if (mount == .title) {
        if (flags & (O.creat | O.trunc | O.excl) != 0) return Error.ReadOnly;
        if (flags & O.accmode != O.rdonly) return Error.ReadOnly;
        if (flags & O.append != 0) return Error.ReadOnly;
        if (title_archive) |archive| return openArchive(path, flags, archive);
    }
    const directory = rootFor(mount) orelse return Error.NotAttached;

    // Everything a title ships stays read-only. Save and download mounts are
    // explicitly writable storage owned by the running title.
    var relative_storage: [maximum_path]u8 = undefined;
    const relative = hostRelative(path, &relative_storage, io, directory) orelse return Error.NotFound;

    if (flags & O.directory != 0) return openDirectory(path, relative, io, directory);

    if (mount != .title) return openWritableFile(path, relative, flags, io, directory);

    if (isLaunchOverridePath(relative)) {
        table_lock.lock();
        defer table_lock.unlock();
        if (launchOverride(relative)) |replacement| {
            const bytes = std.heap.page_allocator.dupe(u8, replacement) catch return Error.IoFailed;
            errdefer std.heap.page_allocator.free(bytes);
            var entry = OpenFile{ .memory = bytes, .size = bytes.len };
            entry.path_length = @min(path.len, maximum_path);
            @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
            return insertFileLocked(entry);
        }
    }

    var alias_storage: [maximum_path]u8 = undefined;
    const file = directory.openFile(io, relative, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => missing: {
            if (titleCacheMetadataAlias(relative, &alias_storage)) |alias| {
                if (directory.openFile(io, alias, .{})) |aliased| {
                    break :missing aliased;
                } else |_| {}
            }
            if (font_substitutes.forPath(relative)) |substitute| return openSubstituteFont(path, substitute);
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

    var entry = OpenFile{ .file = file, .size = size };
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
}

/// Opens a title file inside an attached ZArchive dump. The archive is
/// already case-insensitive, so no host-case matching applies.
fn openArchive(path: []const u8, flags: i32, archive: *zarchive.Reader) Error!i32 {
    var relative_storage: [maximum_path]u8 = undefined;
    const relative = normalizedMountRelative(path, &relative_storage) orelse return Error.NotFound;

    if (flags & O.directory != 0) {
        const node = archive.lookup(relative) orelse return Error.NotFound;
        if (!archive.isDirectory(node)) return Error.NotDirectory;
        return openArchiveDirectory(path, node);
    }

    if (isLaunchOverridePath(relative)) {
        table_lock.lock();
        defer table_lock.unlock();
        if (launchOverride(relative)) |replacement| {
            const bytes = std.heap.page_allocator.dupe(u8, replacement) catch return Error.IoFailed;
            errdefer std.heap.page_allocator.free(bytes);
            var entry = OpenFile{ .memory = bytes, .size = bytes.len };
            entry.path_length = @min(path.len, maximum_path);
            @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
            return insertFileLocked(entry);
        }
    }

    const node = archive.lookup(relative) orelse {
        if (font_substitutes.forPath(relative)) |substitute| return openSubstituteFont(path, substitute);
        return Error.NotFound;
    };
    if (!archive.isFile(node)) return openArchiveDirectory(path, node);

    table_lock.lock();
    defer table_lock.unlock();
    var entry = OpenFile{ .archive_node = node, .size = archive.fileSize(node) };
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
}

fn openArchiveDirectory(path: []const u8, node: u32) Error!i32 {
    table_lock.lock();
    defer table_lock.unlock();
    var entry = OpenFile{ .archive_dir = node };
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
}

fn openDevlogDirectory(path: []const u8) Error!i32 {
    table_lock.lock();
    defer table_lock.unlock();
    var entry = OpenFile{ .diagnostic_directory = true, .directory_index = 0 };
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
}

/// `/devlog/app/<sub path>` is redirected to `out/devlog`. Keep guest
/// components relative on both Windows and Linux; Windows also treats colons,
/// backslashes, device names and trailing dots/spaces specially.
fn devlogRelative(path: []const u8) Error![]const u8 {
    if (!isDevlogTree(path) or path.len > maximum_path) return Error.InvalidArgument;
    const relative = path[devlog_app.len + 1 ..];
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return Error.InvalidArgument;
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return Error.InvalidArgument;
        for (part) |byte| {
            if (byte < 32 or std.mem.indexOfScalar(u8, "\\:<>\"|?*", byte) != null) return Error.InvalidArgument;
        }
        const base = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| {
            if (std.ascii.eqlIgnoreCase(base, device)) return Error.InvalidArgument;
        }
        if (base.len == 4 and (std.ascii.eqlIgnoreCase(base[0..3], "COM") or std.ascii.eqlIgnoreCase(base[0..3], "LPT")) and
            base[3] >= '1' and base[3] <= '9') return Error.InvalidArgument;
    }
    return relative;
}

fn openDevlogTree(path: []const u8, flags: i32) Error!i32 {
    const io = active_io orelse return Error.NotAttached;
    return openDevlogTreeAt(path, flags, io, .cwd());
}

fn openDevlogTreeAt(path: []const u8, flags: i32, io: std.Io, directory: std.Io.Dir) Error!i32 {
    const relative = try devlogRelative(path);
    if (flags & O.accmode == O.accmode) return Error.InvalidArgument;
    if (flags & O.accmode == O.rdonly and flags & O.trunc != 0) return Error.ReadOnly;
    var host_storage: [maximum_path]u8 = undefined;
    const host = std.fmt.bufPrint(&host_storage, "out/devlog/{s}", .{relative}) catch return Error.InvalidArgument;
    if (flags & O.directory != 0) return openDirectory(path, host, io, directory);
    return openWritableFile(path, host, flags, io, directory);
}

fn openDevlog(path: []const u8, flags: i32) Error!i32 {
    const io = active_io orelse return Error.NotAttached;
    if (flags & O.accmode == O.rdonly) return Error.ReadOnly;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, "out") catch return Error.IoFailed;
    const truncate = flags & O.trunc != 0;
    const file = cwd.createFile(io, host_devlog_file, .{
        .read = flags & O.accmode == O.rdwr,
        .truncate = truncate,
    }) catch return Error.IoFailed;
    errdefer file.close(io);
    const size = if (truncate) 0 else file.length(io) catch return Error.IoFailed;

    table_lock.lock();
    defer table_lock.unlock();
    var entry = OpenFile{
        .file = file,
        .diagnostic_log = true,
        .offset = if (flags & O.append != 0) size else 0,
        .size = size,
    };
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
}

/// Opens a file inside a writable mount, creating it when asked.
fn openWritableFile(
    path: []const u8,
    relative: []const u8,
    flags: i32,
    io: std.Io,
    directory: std.Io.Dir,
) Error!i32 {
    const writing = flags & O.accmode != O.rdonly;
    const create = flags & O.creat != 0;
    const truncate = flags & O.trunc != 0;

    if (create) ensureParentDirectory(relative, io, directory);
    const file = if (create)
        directory.createFile(io, relative, .{
            .read = true,
            .truncate = truncate,
            .exclusive = flags & O.excl != 0,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => return Error.Exists,
            else => return Error.IoFailed,
        }
    else
        directory.openFile(io, relative, .{
            .mode = if (writing) .read_write else .read_only,
        }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.BadPathName => return Error.NotFound,
            error.IsDir => return openDirectory(path, relative, io, directory),
            else => return Error.IoFailed,
        };
    errdefer file.close(io);

    if (truncate and !create) {
        if (!writing) return Error.ReadOnly;
        file.setLength(io, 0) catch return Error.IoFailed;
    }
    const size = if (create and truncate) 0 else file.length(io) catch return Error.IoFailed;

    table_lock.lock();
    defer table_lock.unlock();
    var entry = OpenFile{ .file = file, .size = size, .writable = writing };
    // Appending starts at the end; a title reopening its save to add to it
    // must not overwrite what it wrote last time.
    if (flags & O.append != 0) entry.offset = size;
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
}

/// Creates the directories leading to a file a title is about to write.
///
/// A title that mounts a save and immediately opens `data/progress.bin` expects
/// the mount to have made the path usable. Failing here is not reported: the
/// create that follows produces the real error if the path is genuinely bad.
fn ensureParentDirectory(relative: []const u8, io: std.Io, directory: std.Io.Dir) void {
    const separator = std.mem.lastIndexOfAny(u8, relative, "/\\") orelse return;
    if (separator == 0) return;
    directory.createDirPath(io, relative[0..separator]) catch {};
}

/// Creates a directory inside a writable mount, or accepts the diagnostic
/// directories. Everything a title ships stays read-only.
pub fn makeDirectory(path: []const u8) Error!void {
    if (isDevlogDirectory(path)) return;
    const mount = mountOf(path);
    if (mount == .title) return Error.ReadOnly;
    const io = active_io orelse return Error.NotAttached;
    const directory = rootFor(mount) orelse return Error.NotAttached;
    var relative_storage: [maximum_path]u8 = undefined;
    const relative = hostRelative(path, &relative_storage, io, directory) orelse return Error.NotFound;
    if (std.mem.eql(u8, relative, ".")) return;
    directory.createDirPath(io, relative) catch return Error.IoFailed;
}

/// Atomically publishes a file or directory under another name in the same
/// writable guest mount. In particular, database CURRENT/manifest replacement
/// must not delete the destination before the host rename succeeds.
pub fn rename(old_path: []const u8, new_path: []const u8) Error!void {
    const old_mount = mountOf(old_path);
    const new_mount = mountOf(new_path);
    if (old_mount == .title or new_mount == .title) return Error.ReadOnly;
    if (old_mount != new_mount) return Error.CrossDevice;
    const io = active_io orelse return Error.NotAttached;
    const directory = rootFor(old_mount) orelse return Error.NotAttached;
    var old_storage: [maximum_path]u8 = undefined;
    var new_storage: [maximum_path]u8 = undefined;
    const old_relative = hostRelative(old_path, &old_storage, io, directory) orelse return Error.NotFound;
    const new_relative = hostRelative(new_path, &new_storage, io, directory) orelse return Error.NotFound;
    if (std.mem.eql(u8, old_relative, ".") or std.mem.eql(u8, new_relative, ".")) return Error.Busy;
    // Do not create missing parents, copy across mounts, or close open guest
    // descriptors: native rename preserves their object and file position.
    directory.rename(old_relative, directory, new_relative, io) catch |err| return switch (err) {
        error.FileNotFound => Error.NotFound,
        error.NotDir => Error.NotDirectory,
        error.IsDir => Error.IsDirectory,
        error.DirNotEmpty => Error.DirectoryNotEmpty,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => Error.ReadOnly,
        error.CrossDevice => Error.CrossDevice,
        error.FileBusy => Error.Busy,
        error.NoSpaceLeft, error.DiskQuota => Error.NoSpace,
        else => Error.IoFailed,
    };
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
    var entry = OpenFile{
        .directory = directory,
        .directory_iterator = iterator,
    };
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
}

/// Answers a title's missing font file with a bundled freely licensed face.
/// See font_substitutes.zig for why the request cannot simply fail.
fn openSubstituteFont(path: []const u8, substitute: font_substitutes.Substitute) Error!i32 {
    std.debug.print("[font] {s} is missing from the title; serving {s} (SIL OFL) in its place\n", .{ path, substitute.name });
    table_lock.lock();
    defer table_lock.unlock();
    var entry = OpenFile{
        .memory = @constCast(substitute.bytes),
        .borrowed_memory = true,
        .size = substitute.bytes.len,
    };
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
}

fn openVirtualAudio(path: []const u8, relative: []const u8, io: std.Io, directory: std.Io.Dir) Error!i32 {
    const resolved = audio_fs.resolveVirtualWav(relative, directory, io, std.heap.page_allocator) catch {
        return Error.NotFound;
    };
    errdefer std.heap.page_allocator.free(resolved.bytes);

    table_lock.lock();
    defer table_lock.unlock();

    var entry = OpenFile{ .memory = resolved.bytes, .size = resolved.size };
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
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

    var entry = OpenFile{ .device = device };
    entry.path_length = @min(path.len, maximum_path);
    @memcpy(entry.path_buffer[0..entry.path_length], path[0..entry.path_length]);
    return insertFileLocked(entry);
}

/// Allocates a descriptor for a POSIX socket without opening host networking.
pub fn openVirtualSocket() Error!i32 {
    table_lock.lock();
    defer table_lock.unlock();
    const entry = OpenFile{ .virtual_socket = true };
    return insertFileLocked(entry);
}

pub fn isVirtualSocket(descriptor: i32) bool {
    table_lock.lock();
    defer table_lock.unlock();
    const slot = slotOf(descriptor) orelse return false;
    return if (slot.*) |entry| entry.virtual_socket else false;
}

/// A local wake byte has no remote peer and may be discarded after it has
/// served its purpose. Returning the byte count keeps event-loop bookkeeping
/// coherent while all actual network traffic remains offline.
pub fn writeVirtualSocket(descriptor: i32, length: usize) Error!usize {
    if (!isVirtualSocket(descriptor)) return Error.BadDescriptor;
    if (length != 0) virtual_socket_signal.store(1, .release);
    return length;
}

pub fn virtualSocketReadable() bool {
    return virtual_socket_signal.load(.acquire) != 0;
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
        if (!entry.borrowed_memory) std.heap.page_allocator.free(memory);
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
    const virtual_socket = slot.*.?.virtual_socket;
    if (slot.*.?.directory != null or slot.*.?.archive_dir != null or slot.*.?.diagnostic_directory) {
        table_lock.unlock();
        return Error.NotSupported;
    }
    if (virtual_socket) {
        table_lock.unlock();
        if (buffer.len == 0 or virtual_socket_signal.swap(0, .acq_rel) == 0) return 0;
        buffer[0] = 0;
        return 1;
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
            if (entry.descriptor == descriptor and entry.memory != null) entry.offset = offset + count;
        }
        return count;
    }
    const file = slot.*.?.file orelse {
        // Archive descriptors stream through the reader's block cache. The
        // mount globals are copied under the lock; the read itself runs
        // outside it, as host file reads do.
        if (slot.*.?.archive_node) |node| {
            const archive = title_archive;
            const io = active_io;
            table_lock.unlock();
            const count = try readArchiveFile(archive orelse return Error.NotAttached, node, io orelse return Error.NotAttached, buffer, offset);
            table_lock.lock();
            defer table_lock.unlock();
            if (slot.*) |*entry| {
                if (entry.descriptor == descriptor and entry.archive_node == node) entry.offset = offset + count;
            }
            return count;
        }
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
    const count = try readHostFile(file, io, buffer, offset);

    table_lock.lock();
    defer table_lock.unlock();
    // The descriptor may have been closed while the read ran; advancing a
    // reused slot would corrupt an unrelated file's position.
    if (slot.*) |*entry| {
        if (entry.file) |current| {
            if (entry.descriptor == descriptor and current.handle == file.handle) entry.offset = offset + count;
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
    const archive = title_archive;
    const reader_io = active_io;
    table_lock.unlock();

    if (entry.directory != null or entry.archive_dir != null or entry.diagnostic_directory) return Error.NotSupported;
    if (entry.memory) |memory| {
        if (offset >= memory.len) return 0;
        const available = memory.len - offset;
        const count = @min(buffer.len, available);
        @memcpy(buffer[0..count], memory[offset .. offset + count]);
        return count;
    }
    if (entry.archive_node) |node| {
        return readArchiveFile(archive orelse return Error.NotAttached, node, reader_io orelse return Error.NotAttached, buffer, offset);
    }
    const file = entry.file orelse {
        // Reading entropy at an offset is the same as reading it anywhere: the
        // device has no positions, so an offset names nothing to skip.
        if (entry.device == .random) return fillWithEntropy(buffer);
        return Error.NotSupported;
    };
    const io = active_io orelse return Error.NotAttached;
    return readHostFile(file, io, buffer, offset);
}

/// Kernel I/O writes do not raise the user-mode fault used by GPU page
/// tracking. Read mapped guest destinations through host scratch, then publish
/// each chunk with AddressSpace.write. Merely unprotecting before ReadFile is
/// insufficient: another GPU read can rearm the page while the I/O is pending.
/// Archive reads bounce through the same scratch path when the destination is
/// GPU-watched guest memory.
fn readArchiveFile(archive: *zarchive.Reader, node: u32, io: std.Io, buffer: []u8, offset: u64) Error!usize {
    if (buffer.len == 0) return 0;
    if (@atomicLoad(?*guest_memory.AddressSpace, &guest_address_space, .acquire)) |space| {
        if (space.isWritable(@intFromPtr(buffer.ptr), buffer.len)) {
            const scratch = &host_file_read_scratch;
            var total: usize = 0;
            while (total < buffer.len) {
                const chunk = @min(scratch.len, buffer.len - total);
                const position = std.math.add(u64, offset, total) catch return Error.InvalidArgument;
                const count = archive.readAt(node, position, scratch[0..chunk]) catch return Error.IoFailed;
                if (count == 0) break;
                space.write(@intFromPtr(buffer.ptr) + total, scratch[0..count]) catch return Error.IoFailed;
                total += count;
                if (count < chunk) break;
            }
            return total;
        }
    }
    _ = io;
    return archive.readAt(node, offset, buffer) catch Error.IoFailed;
}

fn readHostFile(file: std.Io.File, io: std.Io, buffer: []u8, offset: u64) Error!usize {
    if (buffer.len == 0) return 0;
    if (@atomicLoad(?*guest_memory.AddressSpace, &guest_address_space, .acquire)) |space| {
        if (space.isWritable(@intFromPtr(buffer.ptr), buffer.len)) {
            return readGuestFile(space, file, io, buffer, offset);
        }
    }
    return file.readPositionalAll(io, buffer, offset) catch Error.IoFailed;
}

noinline fn readGuestFile(space: *guest_memory.AddressSpace, file: std.Io.File, io: std.Io, buffer: []u8, offset: u64) Error!usize {
    const scratch = &host_file_read_scratch;
    var total: usize = 0;
    while (total < buffer.len) {
        const chunk = @min(scratch.len, buffer.len - total);
        const position = std.math.add(u64, offset, total) catch return Error.InvalidArgument;
        const count = file.readPositionalAll(io, scratch[0..chunk], position) catch return Error.IoFailed;
        if (count == 0) break;
        space.write(@intFromPtr(buffer.ptr) + total, scratch[0..count]) catch return Error.IoFailed;
        total += count;
        if (count < chunk) break;
    }
    return total;
}

/// Writes to writable mounts and the diagnostic descriptor. Reserving the range
/// under the table lock makes concurrent Unity logging positional and prevents
/// two messages from overwriting one another.
pub fn write(descriptor: i32, buffer: []const u8) Error!usize {
    if (buffer.len == 0) return 0;
    const io = active_io orelse return Error.NotAttached;

    table_lock.lock();
    const slot = slotOf(descriptor) orelse {
        table_lock.unlock();
        return Error.BadDescriptor;
    };
    const entry = if (slot.*) |*value| value else {
        table_lock.unlock();
        return Error.BadDescriptor;
    };
    if (!entry.diagnostic_log and !entry.writable) {
        table_lock.unlock();
        return Error.ReadOnly;
    }
    const file = entry.file orelse {
        table_lock.unlock();
        return Error.BadDescriptor;
    };
    const offset = entry.offset;
    entry.offset +|= buffer.len;
    entry.size = @max(entry.size, entry.offset);
    table_lock.unlock();

    file.writePositionalAll(io, buffer, offset) catch return Error.IoFailed;
    return buffer.len;
}

/// Positional writes preserve the descriptor's seek position. Keep the handle
/// alive under the table lock until the write and size update have completed.
pub fn pwrite(descriptor: i32, buffer: []const u8, offset: u64) Error!usize {
    const end = std.math.add(u64, offset, buffer.len) catch return Error.InvalidArgument;
    if (end > std.math.maxInt(i64)) return Error.InvalidArgument;
    const io = active_io orelse return Error.NotAttached;
    table_lock.lock();
    defer table_lock.unlock();
    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = if (slot.*) |*value| value else return Error.BadDescriptor;
    if (!entry.diagnostic_log and !entry.writable) return Error.ReadOnly;
    const file = entry.file orelse return Error.BadDescriptor;
    if (buffer.len == 0) return 0;
    file.writePositionalAll(io, buffer, offset) catch return Error.IoFailed;
    entry.size = @max(entry.size, end);
    return buffer.len;
}

/// Changes the host file length without moving the guest seek position.
pub fn ftruncate(descriptor: i32, length: u64) Error!void {
    if (length > std.math.maxInt(i64)) return Error.InvalidArgument;
    const io = active_io orelse return Error.NotAttached;
    table_lock.lock();
    defer table_lock.unlock();
    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = if (slot.*) |*value| value else return Error.BadDescriptor;
    if (!entry.diagnostic_log and !entry.writable) return Error.ReadOnly;
    const file = entry.file orelse return Error.BadDescriptor;
    file.setLength(io, length) catch return Error.IoFailed;
    entry.size = length;
}

/// Wait for the host filesystem to commit the file's contents and metadata.
/// Retaining the table lock prevents close/reuse of the handle during the flush.
pub fn fsync(descriptor: i32) Error!void {
    const io = active_io orelse return Error.NotAttached;
    table_lock.lock();
    defer table_lock.unlock();
    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = slot.* orelse return Error.BadDescriptor;
    const file = entry.file orelse return Error.InvalidArgument;
    file.sync(io) catch return Error.IoFailed;
}

/// Flush every writable guest file while keeping its host handle alive.
pub fn sync() Error!void {
    const io = active_io orelse return Error.NotAttached;
    table_lock.lock();
    defer table_lock.unlock();
    var failed = false;
    for (open_files) |slot| {
        const entry = slot orelse continue;
        if (!entry.writable and !entry.diagnostic_log) continue;
        if (entry.file) |file| file.sync(io) catch {
            failed = true;
        };
    }
    if (failed) return Error.IoFailed;
}

pub const DescriptorReadiness = struct {
    readable: bool = false,
    writable: bool = false,
    bytes: u64 = 0,
    eof: bool = false,
};

/// Observe readiness without advancing the descriptor's read position.
pub fn descriptorReadiness(descriptor: i32, low_water: u64) Error!DescriptorReadiness {
    table_lock.lock();
    defer table_lock.unlock();
    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = slot.* orelse return Error.BadDescriptor;
    if (entry.virtual_socket) return .{
        .readable = virtualSocketReadable(),
        .writable = true,
        .bytes = if (virtualSocketReadable()) 1 else 0,
    };
    if (entry.file == null and entry.memory == null and entry.archive_node == null) return Error.InvalidArgument;
    const remaining = entry.size -| entry.offset;
    return .{
        .readable = remaining >= @max(low_water, 1) or remaining == 0,
        .writable = entry.writable or entry.diagnostic_log,
        .bytes = remaining,
        .eof = remaining == 0,
    };
}

pub fn seek(descriptor: i32, offset: i64, whence: i32) Error!i64 {
    table_lock.lock();
    defer table_lock.unlock();

    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = if (slot.*) |*value| value else return Error.BadDescriptor;
    // A device has no contents to hold a position in.
    if (entry.device != null or entry.directory != null or entry.archive_dir != null or entry.diagnostic_directory) return Error.NotSupported;

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
    // Archives name files up to 2^48-1 bytes; saturate rather than trap.
    const clamped = @min(size, std.math.maxInt(i64));
    // clamped fits i64 by the min above; blocks cannot overflow u64 from it.
    out.size = @intCast(clamped);
    out.blksize = 512;
    out.blocks = @intCast((clamped + 511) / 512);
}

fn guestTimespec(timestamp: std.Io.Timestamp) Timespec {
    return .{
        .seconds = @intCast(@divFloor(timestamp.nanoseconds, std.time.ns_per_s)),
        .nanoseconds = @intCast(@mod(timestamp.nanoseconds, std.time.ns_per_s)),
    };
}

fn fillHostStat(out: *Stat, info: std.Io.File.Stat) void {
    fillStat(out, info.size, info.kind == .directory);
    // Resource catalogs use mtime to decide whether to read their contents.
    // Reporting zero makes the first lookup match an uninitialized cache.
    out.mtim = guestTimespec(info.mtime);
    out.ctim = guestTimespec(info.ctime);
    if (info.atime) |atime| out.atim = guestTimespec(atime);
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
    if (isDevlogDirectory(path)) {
        fillStat(out, 0, true);
        out.mode = mode_ifdir | mode_read_write;
        return;
    }
    if (isDevlogFile(path)) {
        fillStat(out, 0, false);
        out.mode = mode_ifreg | mode_read_write;
        return;
    }
    if (deviceForPath(path) != null) {
        fillDeviceStat(out);
        return;
    }

    const io = active_io orelse return Error.NotAttached;
    // Saves resolve against their own root. Asking the title's directory about
    // a save path finds nothing, which is how a title checking whether its save
    // exists was told it did not.
    if (mountOf(path) == .title) {
        if (title_archive) |archive| return statArchive(path, out, archive);
    }
    const directory = rootFor(mountOf(path)) orelse return Error.NotAttached;

    var relative_storage: [maximum_path]u8 = undefined;
    const relative = hostRelative(path, &relative_storage, io, directory) orelse return Error.NotFound;

    if (mountOf(path) == .title and isLaunchOverridePath(relative)) {
        table_lock.lock();
        defer table_lock.unlock();
        if (launchOverride(relative)) |replacement| {
            fillStat(out, replacement.len, false);
            return;
        }
    }

    const info = directory.statFile(io, relative, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => {
            if (mountOf(path) == .title) {
                if (font_substitutes.forPath(relative)) |substitute| {
                    fillStat(out, substitute.bytes.len, false);
                    return;
                }
            }
            if (audio_fs.virtualWavSize(relative, directory, io)) |size| {
                fillStat(out, size, false);
                return;
            }
            return Error.NotFound;
        },
        else => return Error.IoFailed,
    };
    fillHostStat(out, info);
}

/// Stats a title path inside an attached ZArchive dump. Archives carry no
/// timestamps, so only size and kind are reported.
fn statArchive(path: []const u8, out: *Stat, archive: *zarchive.Reader) Error!void {
    var relative_storage: [maximum_path]u8 = undefined;
    const relative = normalizedMountRelative(path, &relative_storage) orelse return Error.NotFound;

    if (isLaunchOverridePath(relative)) {
        table_lock.lock();
        defer table_lock.unlock();
        if (launchOverride(relative)) |replacement| {
            fillStat(out, replacement.len, false);
            return;
        }
    }

    const node = archive.lookup(relative) orelse {
        if (font_substitutes.forPath(relative)) |substitute| {
            fillStat(out, substitute.bytes.len, false);
            return;
        }
        return Error.NotFound;
    };
    if (archive.isDirectory(node)) {
        fillStat(out, 0, true);
    } else {
        fillStat(out, archive.fileSize(node), false);
    }
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
    if (entry.file) |file| {
        const io = active_io orelse return Error.NotAttached;
        fillHostStat(out, file.stat(io) catch return Error.IoFailed);
    } else if (entry.directory) |directory| {
        const io = active_io orelse return Error.NotAttached;
        fillHostStat(out, directory.stat(io) catch return Error.IoFailed);
    } else if (entry.archive_dir != null) {
        fillStat(out, 0, true);
    } else {
        fillStat(out, entry.size, entry.diagnostic_directory);
    }
    if (entry.diagnostic_log) out.mode = mode_ifreg | mode_read_write;
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
/// Longest name a `SceKernelDirent` carries, and the size of the record that
/// holds one. The guest reads `d_name` as a fixed 256-byte array, so a caller
/// that copies the whole field must stay inside the record we reported.
const maximum_name: usize = 255;
const dirent_maximum: usize = direntLength(maximum_name);

/// Record length for a name: the fixed header, the name, its terminator, and
/// padding up to the eight-byte alignment the guest's own iteration assumes.
fn direntLength(name_length: usize) usize {
    return std.mem.alignForward(usize, 8 + name_length + 1, 8);
}

pub fn getDents(descriptor: i32, buffer: []u8, base_position: ?*u64) Error!usize {
    if (buffer.len < dirent_maximum) return Error.InvalidArgument;
    const io = active_io orelse return Error.NotAttached;

    table_lock.lock();
    defer table_lock.unlock();
    const slot = slotOf(descriptor) orelse return Error.BadDescriptor;
    const entry = if (slot.*) |*value| value else return Error.BadDescriptor;
    if (entry.directory == null and entry.archive_dir == null and !entry.diagnostic_directory) return Error.InvalidArgument;
    if (base_position) |position| position.* = entry.directory_index;

    // Pack as many entries as the caller's buffer holds, each `d_reclen` long.
    //
    // One entry padded to a full record per call is a listing a caller can only
    // read by looping, and a caller that reads a directory in a single call --
    // Quake II reads /app0/baseq2 exactly once -- then sees a directory holding
    // nothing but `.`, misses pak0.pak beside it, and fails on the first file
    // it expected to find inside.
    var written: usize = 0;
    while (buffer.len - written >= dirent_maximum) {
        var name_storage: [maximum_name]u8 = undefined;
        var is_directory = true;
        const name: []const u8 = blk: {
            if (entry.pending_length != 0) {
                const length = entry.pending_length;
                is_directory = entry.pending_directory;
                @memcpy(name_storage[0..length], entry.pending_name[0..length]);
                entry.pending_length = 0;
                break :blk name_storage[0..length];
            }
            switch (entry.directory_index) {
                0 => break :blk ".",
                1 => break :blk "..",
                else => {
                    if (entry.diagnostic_directory) {
                        if (entry.directory_index > 2) break;
                        const devlog = std.ascii.eqlIgnoreCase(entry.path(), devlog_root);
                        is_directory = devlog;
                        break :blk if (devlog) "app" else "debug.log";
                    }
                    if (entry.archive_dir) |node| {
                        const archive = title_archive orelse return Error.NotAttached;
                        // directory_index counts ".", "..", then children;
                        // indices past u32 range cannot name a child.
                        const child = std.math.sub(u64, entry.directory_index, 2) catch break;
                        if (child > std.math.maxInt(u32)) break;
                        if (child >= archive.dirChildCount(node)) break;
                        const listed = archive.dirChild(node, @intCast(child));
                        is_directory = !listed.is_file;
                        const length = @min(listed.name.len, maximum_name);
                        @memcpy(name_storage[0..length], listed.name[0..length]);
                        break :blk name_storage[0..length];
                    }
                    const iterator = if (entry.directory_iterator) |*value| value else return Error.IoFailed;
                    const child = iterator.next(io) catch return Error.IoFailed;
                    const found = child orelse break;
                    is_directory = found.kind == .directory;
                    const length = @min(found.name.len, maximum_name);
                    @memcpy(name_storage[0..length], found.name[0..length]);
                    break :blk name_storage[0..length];
                },
            }
        };

        const record = direntLength(name.len);
        if (buffer.len - written < record) {
            // Hold the entry rather than drop it: the iterator has already
            // moved past it and cannot produce it a second time.
            entry.pending_length = @intCast(name.len);
            entry.pending_directory = is_directory;
            @memcpy(entry.pending_name[0..name.len], name);
            break;
        }

        const slice = buffer[written..][0..record];
        @memset(slice, 0);
        std.mem.writeInt(u32, slice[0..4], directoryEntryHash(name), .little);
        std.mem.writeInt(u16, slice[4..6], @intCast(record), .little);
        slice[6] = if (is_directory) 4 else 8;
        slice[7] = @intCast(name.len);
        @memcpy(slice[8 .. 8 + name.len], name);
        written += record;
        entry.directory_index += 1;
    }
    return written;
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

test "mount-relative parent segments clamp at the title root" {
    var storage: [maximum_path]u8 = undefined;
    try testing.expectEqualStrings(".", normalizedMountRelative("/app0", &storage).?);
    try testing.expectEqualStrings(".", normalizedMountRelative("/APP0/", &storage).?);
    try testing.expectEqualStrings(".", normalizedMountRelative("/hostapp", &storage).?);
    try testing.expectEqualStrings(
        "TetrisEffect/Content/Paks",
        normalizedMountRelative("../../../TetrisEffect/Content/Paks", &storage).?,
    );
    try testing.expectEqualStrings(
        "Media/file.bin",
        normalizedMountRelative("/app0/Media/tmp/../file.bin", &storage).?,
    );
    try testing.expectEqualStrings(".", normalizedMountRelative("/app0/..", &storage).?);
    try testing.expect(normalizedMountRelative("C:/Windows/system.ini", &storage) == null);
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

test "devlog directories exist without making title content writable" {
    var info: Stat = undefined;
    try stat("/devlog", &info);
    try testing.expect(info.mode & mode_ifdir != 0);
    try makeDirectory("/devlog/app");
    try testing.expectError(Error.ReadOnly, makeDirectory("/app0/save"));
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

test "file reads into GPU-watched guest pages preserve bytes offsets and generations" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const contents = try testing.allocator.alloc(u8, 64 * 1024 + 37);
    defer testing.allocator.free(contents);
    for (contents, 0..) |*byte, index| byte.* = @truncate(index * 31 + 7);
    var fixture = try Fixture.init(contents);
    defer fixture.deinit();
    var space = try guest_memory.AddressSpace.init(testing.allocator);
    defer space.deinit();
    attachGuestAddressSpace(&space);
    defer attachGuestAddressSpace(null);
    const page = guest_memory.page_size;
    const base = guest_memory.system_managed.start;
    try space.mapFixed(base, 6 * page, .read_write, .private, null);
    const mapped = @as([*]u8, @ptrFromInt(base))[0 .. 6 * page];
    @memset(mapped, 0xa5);
    const destination = mapped[123 .. 123 + contents.len + 7];
    const address = @intFromPtr(destination.ptr);
    space.enableGpuMemoryTracking();
    _ = try space.trackGpuRead(base, mapped.len);
    const untouched = space.gpuGeneration(base + 5 * page, page);
    try testing.expect(untouched != 0);
    const fd = try open("/app0/data.bin", O.rdonly);
    defer close(fd) catch {};

    try testing.expectEqual(contents.len - 11, try pread(fd, destination, 11));
    try testing.expectEqualSlices(u8, contents[11..], destination[0 .. contents.len - 11]);
    try testing.expectEqual(@as(i64, 0), try seek(fd, 0, 1));
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, contents.len));
    try testing.expectEqual(untouched, space.gpuGeneration(base + 5 * page, page));
    const rearmed = try space.trackGpuRead(address, contents.len);
    try testing.expect(rearmed != 0);

    try testing.expectEqual(contents.len, try read(fd, destination));
    try testing.expectEqualSlices(u8, contents, destination[0..contents.len]);
    for (destination[contents.len..]) |byte| try testing.expectEqual(@as(u8, 0xa5), byte);
    try testing.expectEqual(@as(i64, @intCast(contents.len)), try seek(fd, 0, 1));
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, contents.len));
    try testing.expectEqual(untouched, space.gpuGeneration(base + 5 * page, page));
    const at_eof = try space.trackGpuRead(address, destination.len);
    try testing.expect(at_eof != rearmed);
    try testing.expectEqual(@as(usize, 0), try read(fd, destination));
    try testing.expectEqual(at_eof, space.gpuGeneration(address, destination.len));
}

test "display boot overlay has consistent reads and stat without modifying title content" {
    var fixture = try Fixture.init("unchanged");
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "Media");
    const original = "platform-ps5-video-out-width=3840\nkeep=value\n";
    const expected = "platform-ps5-video-out-width=1920\nkeep=value\n";
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = boot_config.path, .data = original });
    try testing.expect(try configureDisplay(1920, 1080));
    var info: Stat = undefined;
    try stat("/app0/Media/boot.config", &info);
    try testing.expectEqual(@as(i64, expected.len), info.size);
    const fd = try open("/app0/Media/boot.config", O.rdonly);
    defer close(fd) catch {};
    try fstat(fd, &info);
    try testing.expectEqual(@as(i64, expected.len), info.size);
    var bytes: [128]u8 = undefined;
    const head = try read(fd, bytes[0..11]);
    const tail = try read(fd, bytes[head..]);
    try testing.expectEqualStrings(expected, bytes[0 .. head + tail]);
    try testing.expectEqual(@as(usize, 0), try read(fd, &bytes));
    const second = try open("/app0/Media\\boot.config", O.rdonly);
    defer close(second) catch {};
    try testing.expectEqual(expected.len, try pread(second, &bytes, 0));
    try testing.expectEqualStrings(expected, bytes[0..expected.len]);
    const disk = try fixture.tmp.dir.readFile(testing.io, boot_config.path, &bytes);
    try testing.expectEqualStrings(original, disk);
    try testing.expectError(Error.ReadOnly, open("/app0/Media/boot.config", O.wronly));
    detach();
    attach(testing.io, fixture.tmp.dir);
    const raw = try open("/app0/Media/boot.config", O.rdonly);
    defer close(raw) catch {};
    const length = try read(raw, &bytes);
    try testing.expectEqualStrings(original, bytes[0..length]);
}

test "Unreal raster launch preference preserves files and consistent reads across reconfiguration" {
    var fixture = try Fixture.init("title data");
    defer fixture.deinit();
    const source = "../../../Game/Game.uproject -SessionName=\"Game Name\"\r\n";
    const expected = "../../../Game/Game.uproject -SessionName=\"Game Name\" -noraytracing";
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = unreal_command_path, .data = source });
    try testing.expect(try configureUnrealRayTracing(false));
    var info: Stat = undefined;
    try stat("/app0/ue4commandline.txt", &info);
    try testing.expectEqual(@as(i64, expected.len), info.size);
    const fd = try open("/app0/ue4commandline.txt", O.rdonly);
    defer close(fd) catch {};
    var bytes: [256]u8 = undefined;
    const head = try read(fd, bytes[0..7]);
    const tail = try read(fd, bytes[head..]);
    try testing.expectEqualStrings(expected, bytes[0 .. head + tail]);
    try testing.expectEqual(@as(usize, 0), try read(fd, &bytes));
    try fstat(fd, &info);
    try testing.expectEqual(@as(i64, expected.len), info.size);
    try testing.expect(!(try configureUnrealRayTracing(true)));
    // Already-open files retain their own immutable launch document.
    try testing.expectEqual(expected.len, try pread(fd, &bytes, 0));
    try testing.expectEqualStrings(expected, bytes[0..expected.len]);
    const raw = try open("/app0/ue4commandline.txt", O.rdonly);
    defer close(raw) catch {};
    const length = try read(raw, &bytes);
    try testing.expectEqualStrings(source, bytes[0..length]);
    try testing.expectEqualStrings(source, try fixture.tmp.dir.readFile(testing.io, unreal_command_path, &bytes));
    try testing.expectError(Error.ReadOnly, open("/app0/ue4commandline.txt", O.wronly));
    try testing.expect(try configureUnrealRayTracing(false));
    detach();
    attach(testing.io, fixture.tmp.dir);
    try stat("/app0/ue4commandline.txt", &info);
    try testing.expectEqual(@as(i64, source.len), info.size);
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = unreal_command_path, .data = "Game.uproject -NoRayTracing\n" });
    try testing.expect(!(try configureUnrealRayTracing(false)));
}

test "Unreal raster launch preference serves archived command lines without changing the archive" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "../../../Game/Game.uproject -log\n";
    const expected = "../../../Game/Game.uproject -log -noraytracing";
    try zarchive.writeTestArchive(testing.io, tmp.dir, "game.zar", &.{
        .{ .path = unreal_command_path, .data = source },
        .{ .path = "data.bin", .data = "title content" },
    });
    var reader = try zarchive.Reader.open(testing.io, tmp.dir, "game.zar", testing.allocator);
    defer reader.close();
    attachArchive(testing.io, reader);
    defer detach();
    try testing.expect(try configureUnrealRayTracing(false));
    var info: Stat = undefined;
    try stat("/APP0/UE4COMMANDLINE.TXT", &info);
    try testing.expectEqual(@as(i64, expected.len), info.size);
    const fd = try open("/APP0/UE4COMMANDLINE.TXT", O.rdonly);
    defer close(fd) catch {};
    try fstat(fd, &info);
    try testing.expectEqual(@as(i64, expected.len), info.size);
    var bytes: [256]u8 = undefined;
    try testing.expectEqual(expected.len - 7, try pread(fd, &bytes, 7));
    try testing.expectEqualStrings(expected[7..], bytes[0 .. expected.len - 7]);
    try testing.expectEqual(@as(usize, 0), try pread(fd, &bytes, expected.len));
    try testing.expectError(Error.ReadOnly, open("/app0/ue4commandline.txt", O.wronly));
    const node = reader.lookup(unreal_command_path).?;
    try testing.expectEqual(source.len, try reader.readAt(node, 0, &bytes));
    try testing.expectEqualStrings(source, bytes[0..source.len]);
    try testing.expect(!(try configureUnrealRayTracing(true)));
    try stat("/app0/ue4commandline.txt", &info);
    try testing.expectEqual(@as(i64, source.len), info.size);
    try testing.expectEqual(expected.len, try pread(fd, &bytes, 0));
    try testing.expectEqualStrings(expected, bytes[0..expected.len]);
}

test "a missing title font is served from the bundled stand-ins and a shipped one is not" {
    var fixture = try Fixture.init("title data");
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "data/common/font");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "data/common/font/FuturaStd-Bold.otf", .data = "shipped font" });

    const missing = "/app0/data/common/font/SIE-ShinGoPr6N-Heavy.otf";
    const substitute = font_substitutes.forPath(missing).?;
    var info: Stat = undefined;
    try stat(missing, &info);
    try testing.expectEqual(@as(i64, @intCast(substitute.bytes.len)), info.size);
    const fd = try open(missing, O.rdonly);
    var head: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try pread(fd, &head, 0));
    try testing.expectEqualSlices(u8, substitute.bytes[0..4], &head);
    // Closing must not free the bundled bytes; a second open reads them again.
    try close(fd);
    const again = try open(missing, O.rdonly);
    defer close(again) catch {};
    try testing.expectEqual(@as(usize, 4), try pread(again, &head, 0));
    try testing.expectEqualSlices(u8, substitute.bytes[0..4], &head);

    const shipped = try open("/app0/data/common/font/FuturaStd-Bold.otf", O.rdonly);
    defer close(shipped) catch {};
    var bytes: [32]u8 = undefined;
    const length = try read(shipped, &bytes);
    try testing.expectEqualStrings("shipped font", bytes[0..length]);
    try testing.expectError(Error.NotFound, stat("/app0/data/common/missing.xml", &info));
}

test "save-data delete is confined to an unmounted slot of the active title" {
    var fixture = try Fixture.init("title data");
    defer fixture.deinit();
    attachSaveDataHome(fixture.tmp.dir, "PPSA15065");
    defer {
        unmountSaveData();
        savedata_home = null;
        title_identifier_length = 0;
    }
    try fixture.tmp.dir.createDirPath(testing.io, "PPSA15065/remove/data");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "PPSA15065/remove/data/save.bin", .data = "progress" });
    try fixture.tmp.dir.createDirPath(testing.io, "PPSA15065/keep");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "PPSA15065/keep/save.bin", .data = "keep" });
    try fixture.tmp.dir.createDirPath(testing.io, "OTHER/remove");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "OTHER/remove/save.bin", .data = "other" });
    _ = try mountSaveDataSlot("remove", false);
    try testing.expectError(error.Busy, deleteSaveDataSlot("remove"));
    try testing.expectError(error.Busy, deleteSaveDataSlot("REMOVE"));
    unmountSaveData();
    for ([_][]const u8{ "", ".", "..", "../keep", "..\\keep", "remove/", "remove.", " remove", "C:remove" }) |name|
        try testing.expectError(Error.InvalidArgument, deleteSaveDataSlot(name));
    try deleteSaveDataSlot("remove");
    try deleteSaveDataSlot("remove");
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(testing.io, "PPSA15065/remove", .{}));
    var bytes: [16]u8 = undefined;
    try testing.expectEqualStrings("keep", try fixture.tmp.dir.readFile(testing.io, "PPSA15065/keep/save.bin", &bytes));
    try testing.expectEqualStrings("other", try fixture.tmp.dir.readFile(testing.io, "OTHER/remove/save.bin", &bytes));
}

test "save-data search hides interrupted slots without payload" {
    var fixture = try Fixture.init("title data");
    defer fixture.deinit();

    attachSaveDataHome(fixture.tmp.dir, "PPSA15065");
    defer {
        savedata_home = null;
        title_identifier_length = 0;
    }

    try fixture.tmp.dir.createDirPath(testing.io, "PPSA15065/incomplete/sce_sys");
    try fixture.tmp.dir.writeFile(testing.io, .{
        .sub_path = "PPSA15065/incomplete/path.txt",
        .data = "",
    });
    try fixture.tmp.dir.writeFile(testing.io, .{
        .sub_path = "PPSA15065/incomplete/sce_sys/param.txt",
        .data = "title metadata",
    });

    try fixture.tmp.dir.createDirPath(testing.io, "PPSA15065/complete/data");
    try fixture.tmp.dir.writeFile(testing.io, .{
        .sub_path = "PPSA15065/complete/data/progress.bin",
        .data = "progress",
    });

    var names: [4][savedata.maximum_slot_name]u8 = undefined;
    const found = listSaveDataSlots(&names);
    try testing.expectEqual(@as(usize, 1), found);
    try testing.expectEqualStrings("complete", std.mem.sliceTo(&names[0], 0));
}

test "save-data named mounts preserve empty containers and missing probes preserve the active mount" {
    var fixture = try Fixture.init("title data");
    defer fixture.deinit();
    attachSaveDataHome(fixture.tmp.dir, "PPSA15065");
    defer {
        unmountSaveData();
        savedata_home = null;
        title_identifier_length = 0;
    }
    try fixture.tmp.dir.createDirPath(testing.io, "PPSA15065/incomplete/sce_sys");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "PPSA15065/incomplete/save.bin", .data = "" });
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "PPSA15065/incomplete/sce_sys/param.txt", .data = "metadata" });
    try fixture.tmp.dir.createDirPath(testing.io, "PPSA15065/complete/data");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "PPSA15065/complete/data/progress.bin", .data = "progress" });

    try testing.expectEqual(SaveDataMountOutcome.existed, try mountSaveDataSlot("complete", false));
    try testing.expectEqual(SaveDataMountOutcome.missing, try mountSaveDataSlot("absent", false));
    try testing.expectEqualStrings("complete", mountedSaveDataSlot());
    var bytes: [32]u8 = undefined;
    const metadata = try fixture.tmp.dir.readFile(testing.io, "PPSA15065/incomplete/sce_sys/param.txt", &bytes);
    try testing.expectEqualStrings("metadata", metadata);
    try testing.expectEqual(SaveDataMountOutcome.existed, try mountSaveDataSlot("incomplete", false));
    try testing.expectEqual(SaveDataMountOutcome.existed, try mountSaveDataSlot("incomplete", true));
    const fd = try open("/savedata0/save.bin", O.wronly);
    try testing.expectEqual(@as(usize, 8), try write(fd, "new save"));
    try close(fd);
    unmountSaveData();
    try testing.expectEqual(SaveDataMountOutcome.existed, try mountSaveDataSlot("incomplete", false));
    const restored = try open("/savedata0/save.bin", O.rdonly);
    defer close(restored) catch {};
    const count = try read(restored, &bytes);
    try testing.expectEqualStrings("new save", bytes[0..count]);
}

test "save-data first-run create unmount read-only remount needs no payload" {
    var fixture = try Fixture.init("title data");
    defer fixture.deinit();
    attachSaveDataHome(fixture.tmp.dir, "PPSA17163");
    defer {
        unmountSaveData();
        savedata_home = null;
        title_identifier_length = 0;
    }
    try testing.expectEqual(SaveDataMountOutcome.missing, try mountSaveDataSlot("jng2", false));
    try testing.expectEqual(SaveDataMountOutcome.created, try mountSaveDataSlot("jng2", true));
    unmountSaveData();
    try testing.expectEqual(SaveDataMountOutcome.existed, try mountSaveDataSlot("jng2", false));
    try testing.expectError(Error.NotFound, open("/savedata0/game.ini", O.rdonly));
    unmountSaveData();
    try testing.expectEqual(SaveDataMountOutcome.existed, try mountSaveDataSlot("jng2", true));
    const fd = try open("/savedata0/game.ini", O.wronly | O.creat);
    try testing.expectEqual(@as(usize, 8), try write(fd, "settings"));
    try close(fd);
    unmountSaveData();
    try testing.expectEqual(SaveDataMountOutcome.existed, try mountSaveDataSlot("jng2", false));
    const restored = try open("/savedata0/game.ini", O.rdonly);
    defer close(restored) catch {};
    var bytes: [16]u8 = undefined;
    const count = try read(restored, &bytes);
    try testing.expectEqualStrings("settings", bytes[0..count]);
}

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

test "generic title cache metadata resolves to an extracted product record" {
    var fixture = try Fixture.init("title data");
    defer fixture.deinit();
    attachSaveDataHome(fixture.tmp.dir, "PPSA26344");
    defer title_identifier_length = 0;
    try fixture.tmp.dir.createDirPath(testing.io, "cache_ps5");
    try fixture.tmp.dir.writeFile(testing.io, .{
        .sub_path = "cache_ps5/t26344.dat",
        .data = "metadata",
    });

    const fd = try open("/app0/cache_ps5/t00000.dat", O.rdonly);
    defer close(fd) catch {};
    var contents: [8]u8 = undefined;
    try testing.expectEqual(contents.len, try read(fd, &contents));
    try testing.expectEqualStrings("metadata", &contents);
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

test "reopened files cannot alias a previous descriptor read-ahead cache" {
    var fixture = try Fixture.init("mesh");
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "shader.bin", .data = "shader" });

    const original = try open("/app0/data.bin", O.rdonly);
    var cached: [4]u8 = undefined;
    _ = try pread(original, &cached, 0);
    try close(original);

    // Reuse the bounded table repeatedly, as Unity does while loading bundles.
    var previous = original;
    for (0..maximum_open_files * 2) |_| {
        const current = try open("/app0/shader.bin", O.rdonly);
        try testing.expect(current > previous);
        try testing.expectEqual(@as(usize, 1), openCount());
        try testing.expectError(Error.BadDescriptor, pread(original, &cached, 0));
        try testing.expectError(Error.BadDescriptor, close(previous));
        var bytes: [6]u8 = undefined;
        try testing.expectEqual(bytes.len, try pread(current, &bytes, 0));
        try testing.expectEqualStrings("shader", &bytes);
        try testing.expectEqualStrings("mesh", &cached);
        try close(current);
        previous = current;
    }
}

test "descriptor identities share a namespace and preserve the live file limit" {
    var fixture = try Fixture.init("data");
    defer fixture.deinit();
    const file = try open("/app0/data.bin", O.rdonly);
    try close(file);
    const directory = try open("/app0", O.directory);
    try testing.expect(directory > file);
    try close(directory);
    const device = try open("/dev/gc", O.rdwr);
    try testing.expect(device > directory);
    try close(device);

    var descriptors: [maximum_open_files]i32 = undefined;
    for (&descriptors) |*fd| fd.* = try openVirtualSocket();
    try testing.expect(descriptors[0] > device);
    try testing.expectError(Error.TooManyOpenFiles, openVirtualSocket());
    try close(descriptors[0]);
    const replacement = try openVirtualSocket();
    try testing.expect(replacement > descriptors[descriptors.len - 1]);
    try testing.expect(!isVirtualSocket(descriptors[0]));
    try testing.expect(isVirtualSocket(replacement));
    try testing.expectEqual(maximum_open_files, openCount());
}

test "descriptor exhaustion does not wrap or publish a file" {
    var fixture = try Fixture.init("data");
    defer fixture.deinit();
    next_descriptor = std.math.maxInt(i32);
    const last = try openVirtualSocket();
    try testing.expectEqual(std.math.maxInt(i32), last);
    try close(last);
    try testing.expectError(Error.TooManyOpenFiles, open("/app0/data.bin", O.rdonly));
    try testing.expectEqual(@as(usize, 0), openCount());
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
    const host_file = try fixture.tmp.dir.statFile(testing.io, "data.bin", .{});
    try testing.expect(host_file.mtime.nanoseconds != 0);
    try testing.expectEqual(host_file.mtime.nanoseconds, @as(i96, info.mtim.seconds) * std.time.ns_per_s + info.mtim.nanoseconds);
    try testing.expectEqual(host_file.ctime.nanoseconds, @as(i96, info.ctim.seconds) * std.time.ns_per_s + info.ctim.nanoseconds);

    try stat("/app0/sub", &info);
    try testing.expect(info.mode & mode_ifdir != 0);
    const host_dir = try fixture.tmp.dir.statFile(testing.io, "sub", .{});
    try testing.expectEqual(host_dir.mtime.nanoseconds, @as(i96, info.mtim.seconds) * std.time.ns_per_s + info.mtim.nanoseconds);

    const fd = try open("/app0/data.bin", O.rdonly);
    defer close(fd) catch {};
    var by_descriptor = Stat{};
    try fstat(fd, &by_descriptor);
    try testing.expectEqual(@as(i64, 10), by_descriptor.size);
    try testing.expectEqual(host_file.mtime.nanoseconds, @as(i96, by_descriptor.mtim.seconds) * std.time.ns_per_s + by_descriptor.mtim.nanoseconds);
    try testing.expectEqual(host_file.ctime.nanoseconds, @as(i96, by_descriptor.ctim.seconds) * std.time.ns_per_s + by_descriptor.ctim.nanoseconds);
}

test "guest file timestamps retain fractions before and after the epoch" {
    try testing.expectEqual(Timespec{ .seconds = 1, .nanoseconds = 234_567_800 }, guestTimespec(.{ .nanoseconds = 1_234_567_800 }));
    try testing.expectEqual(Timespec{ .seconds = -1, .nanoseconds = 999_999_900 }, guestTimespec(.{ .nanoseconds = -100 }));
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

test "download data is writable without making title content writable" {
    var fixture = try Fixture.init("title data");
    defer fixture.deinit();
    attachDownloadData(fixture.tmp.dir);
    defer detachDownloadData();

    try makeDirectory("/download0/generated/cache");
    const fd = try open(
        "/download0/generated/cache/config.bin",
        O.rdwr | O.creat | O.trunc,
    );
    try testing.expectEqual(@as(usize, 6), try write(fd, "config"));
    try close(fd);

    const reopened = try open("/download0/generated/cache/config.bin", O.rdonly);
    defer close(reopened) catch {};
    var contents: [6]u8 = undefined;
    try testing.expectEqual(contents.len, try read(reopened, &contents));
    try testing.expectEqualStrings("config", &contents);

    try testing.expectError(Error.ReadOnly, makeDirectory("/app0/generated"));
}

test "temporary mount supports save staging and remains isolated from content" {
    var fixture = try Fixture.init("title data");
    defer fixture.deinit();
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    attachTemporaryData(scratch.dir);
    defer detachTemporaryData();

    var metadata: Stat = undefined;
    try stat("/temp0", &metadata);
    try testing.expectEqual(mode_ifdir, metadata.mode & 0o170000);
    try stat("/temp0/", &metadata);
    try makeDirectory("/temp0/TempSave");
    const fd = try open("/temp0/TempSave/slot.bin", O.rdwr | O.creat | O.trunc);
    try testing.expectEqual(@as(usize, 4), try write(fd, "save"));
    try close(fd);
    const reopened = try open("/temp0/TempSave/slot.bin", O.rdonly);
    defer close(reopened) catch {};
    var bytes: [4]u8 = undefined;
    try testing.expectEqual(bytes.len, try read(reopened, &bytes));
    try testing.expectEqualStrings("save", &bytes);
    try testing.expectError(Error.NotFound, stat("/app0/TempSave/slot.bin", &metadata));
    try testing.expectError(Error.ReadOnly, makeDirectory("/app0/TempSave"));

    // Parent components cannot walk out of the attached scratch directory.
    var path: [maximum_path]u8 = undefined;
    try testing.expectEqualStrings("slot.bin", mountRelative("/temp0/../../slot.bin", &path).?);
    try testing.expect(mountRelative("/temp00/slot.bin", &path) == null);
    detachTemporaryData();
    try testing.expectError(Error.NotAttached, stat("/temp0", &metadata));
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

test "an attached archive serves title content read-only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try zarchive.writeTestArchive(testing.io, tmp.dir, "game.zar", &.{
        .{ .path = "eboot.bin", .data = "fake-elf" },
        .{ .path = "sce_sys/param.json", .data = "{\"titleId\":\"PPSA00001\"}" },
    });
    var reader = try zarchive.Reader.open(testing.io, tmp.dir, "game.zar", testing.allocator);
    defer reader.close();
    attachArchive(testing.io, reader);
    defer detach();

    const fd = try open("/app0/eboot.bin", O.rdonly);
    defer close(fd) catch {};
    var bytes: [8]u8 = undefined;
    try testing.expectEqual(bytes.len, try read(fd, &bytes));
    try testing.expectEqualStrings("fake-elf", &bytes);
    try testing.expectEqual(@as(usize, 0), try read(fd, &bytes));

    var info: Stat = undefined;
    try stat("/app0/sce_sys/param.json", &info);
    try testing.expectEqual(@as(i64, "{\"titleId\":\"PPSA00001\"}".len), info.size);
    try fstat(fd, &info);
    try testing.expectEqual(@as(i64, "fake-elf".len), info.size);

    // The archive is case-insensitive; the mount stays read-only.
    const upper = try open("/APP0/EBOOT.BIN", O.rdonly);
    defer close(upper) catch {};
    try testing.expectEqual(@as(usize, 3), try pread(upper, bytes[0..3], 5));
    try testing.expectEqualStrings("elf", bytes[0..3]);
    try testing.expectError(Error.ReadOnly, open("/app0/eboot.bin", O.wronly));
    try testing.expectError(Error.ReadOnly, open("/app0/new.bin", O.rdonly | O.creat));
    try testing.expectError(Error.NotFound, open("/app0/absent.bin", O.rdonly));

    // Polling sees archive files as immediately readable regular files.
    const probe = try open("/app0/eboot.bin", O.rdonly);
    defer close(probe) catch {};
    const readiness = try descriptorReadiness(probe, 1);
    try testing.expect(readiness.readable);
    try testing.expect(!readiness.eof);
    try testing.expectEqual(@as(u64, "fake-elf".len), readiness.bytes);
}

test "switching mounts drops stale archive descriptors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try zarchive.writeTestArchive(testing.io, tmp.dir, "a.zar", &.{.{ .path = "eboot.bin", .data = "elf-a" }});
    try zarchive.writeTestArchive(testing.io, tmp.dir, "b.zar", &.{.{ .path = "eboot.bin", .data = "elf-b" }});
    var first = try zarchive.Reader.open(testing.io, tmp.dir, "a.zar", testing.allocator);
    defer first.close();
    attachArchive(testing.io, first);
    const fd = try open("/app0/eboot.bin", O.rdonly);

    var second = try zarchive.Reader.open(testing.io, tmp.dir, "b.zar", testing.allocator);
    defer second.close();
    attachArchive(testing.io, second);
    defer detach();
    // The old descriptor named a node in another reader; it must not read.
    var bytes: [5]u8 = undefined;
    try testing.expectError(Error.BadDescriptor, read(fd, &bytes));
    try testing.expectError(Error.BadDescriptor, close(fd));

    const current = try open("/app0/eboot.bin", O.rdonly);
    defer close(current) catch {};
    try testing.expectEqual(@as(usize, 5), try read(current, &bytes));
    try testing.expectEqualStrings("elf-b", &bytes);
}

test "an attached archive enumerates directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try zarchive.writeTestArchive(testing.io, tmp.dir, "game.zar", &.{
        .{ .path = "eboot.bin", .data = "elf" },
        .{ .path = "sce_sys/param.json", .data = "{}" },
    });
    var reader = try zarchive.Reader.open(testing.io, tmp.dir, "game.zar", testing.allocator);
    defer reader.close();
    attachArchive(testing.io, reader);
    defer detach();

    const fd = try open("/app0", O.rdonly | O.directory);
    defer close(fd) catch {};
    var buffer: [512]u8 = undefined;
    const written = try getDents(fd, &buffer, null);
    var seen_eboot = false;
    var seen_sce_sys = false;
    var offset: usize = 0;
    while (offset < written) {
        const record = std.mem.readInt(u16, buffer[offset + 4 ..][0..2], .little);
        const name_len: usize = buffer[offset + 7];
        const name = buffer[offset + 8 ..][0..name_len];
        if (std.mem.eql(u8, name, "eboot.bin")) seen_eboot = true;
        if (std.mem.eql(u8, name, "sce_sys")) seen_sce_sys = true;
        offset += record;
    }
    try testing.expect(seen_eboot and seen_sce_sys);
}

test "directory descriptors enumerate BSD dirent records" {
    // Records are packed and variable-length, each `d_reclen` long, as many as
    // the caller's buffer holds. Returning one entry per call padded to a fixed
    // record is a listing only a looping caller can read, and a caller that
    // reads a directory once -- Quake II reads /app0/baseq2 exactly once --
    // then sees a directory holding nothing but `.`, misses the pak file
    // beside it, and fails on the first thing it expected to find inside.
    var fixture = try Fixture.init("data");
    defer fixture.deinit();

    const fd = try open("/app0/sub", O.rdonly | O.directory);
    defer close(fd) catch {};
    var buffer: [512]u8 = undefined;
    var base: u64 = 99;

    const written = try getDents(fd, &buffer, &base);
    try testing.expectEqual(@as(u64, 0), base);

    var names: [8][]const u8 = undefined;
    var types: [8]u8 = undefined;
    var count: usize = 0;
    var offset: usize = 0;
    var last_start: usize = 0;
    while (offset < written) {
        last_start = offset;
        const record = std.mem.readInt(u16, buffer[offset + 4 ..][0..2], .little);
        // A caller walks this buffer by stepping d_reclen, so a record short
        // enough to loop for ever, or long enough to run past what we said we
        // wrote, is worse than a missing entry.
        try testing.expect(record >= 8 and record <= written - offset);
        try testing.expectEqual(@as(usize, 0), record % 8);
        const name_length = buffer[offset + 7];
        try testing.expect(8 + @as(usize, name_length) < record);
        names[count] = buffer[offset + 8 ..][0..name_length];
        types[count] = buffer[offset + 6];
        count += 1;
        offset += record;
    }

    // `.`, `..` and the one file the fixture puts in sub/, in one call.
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings(".", names[0]);
    try testing.expectEqual(@as(u8, 4), types[0]);
    try testing.expectEqualStrings("..", names[1]);
    try testing.expectEqualStrings("inner.txt", names[2]);
    try testing.expectEqual(@as(u8, 8), types[2]);
    // Each name stays terminated inside its own record, so a caller that reads
    // d_name as a C string stops before the next entry rather than running on
    // into it.
    try testing.expectEqualStrings("inner.txt", std.mem.sliceTo(buffer[last_start + 8 ..], 0));

    try testing.expectEqual(@as(usize, 0), try getDents(fd, &buffer, null));
}

test "descriptor storage is released without reusing guest identities" {
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
    try testing.expect(second > first);
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

test "devlog recognizes nested paths without confusing other mounts" {
    // The engine names its log after the run, so an exact-path allowlist
    // refuses the write and the title loses its diagnostics.
    try testing.expect(isDevlogTree("/devlog/app/logs/demonssoul_ps5_x_0.log"));
    try testing.expect(isDevlogTree("/devlog/app/commandlineargs.txt"));
    try testing.expect(!isDevlogTree("/devlog/app"));
    try testing.expect(!isDevlogTree("/devlog/appx/file.log"));
    try testing.expect(!isDevlogTree("/app0/logs/file.log"));
}

test "devlog paths reject host traversal and accept dots inside filenames" {
    try testing.expectEqualStrings("logs/run..1.log", try devlogRelative("/devlog/app/logs/run..1.log"));
    for ([_][]const u8{
        "/devlog/app/",                  "/devlog/app/../outside",       "/devlog/app/logs/../../outside",
        "/devlog/app//root",             "/devlog/app/logs/.. /outside", "/devlog/app/logs./x",
        "/devlog/app/logs\\..\\outside", "/devlog/app/C:/outside",       "/devlog/app/a:stream",
        "/devlog/app/NUL.txt",           "/devlog/app/logs/com1",        "/devlog/appx/outside",
    }) |path| try testing.expectError(Error.InvalidArgument, devlogRelative(path));
}

test "devlog files honor create exclusive append truncate and read-only flags" {
    var fixture = try Fixture.init("title content");
    defer fixture.deinit();
    const path = "/devlog/app/logs/run..1.log";
    try testing.expectError(Error.NotFound, openDevlogTreeAt(path, O.wronly, testing.io, fixture.tmp.dir));
    var fd = try openDevlogTreeAt(path, O.creat | O.excl | O.rdwr, testing.io, fixture.tmp.dir);
    try testing.expectEqual(@as(usize, 3), try write(fd, "abc"));
    try close(fd);
    try testing.expectError(Error.Exists, openDevlogTreeAt(path, O.creat | O.excl | O.wronly, testing.io, fixture.tmp.dir));
    fd = try openDevlogTreeAt(path, O.append | O.wronly, testing.io, fixture.tmp.dir);
    try testing.expectEqual(@as(usize, 1), try write(fd, "d"));
    try close(fd);
    fd = try openDevlogTreeAt(path, O.rdonly, testing.io, fixture.tmp.dir);
    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try read(fd, &buffer));
    try testing.expectEqualStrings("abcd", &buffer);
    try testing.expectError(Error.ReadOnly, write(fd, "x"));
    try close(fd);
    try testing.expectError(Error.ReadOnly, openDevlogTreeAt(path, O.rdonly | O.trunc, testing.io, fixture.tmp.dir));
    fd = try openDevlogTreeAt(path, O.wronly | O.trunc, testing.io, fixture.tmp.dir);
    try testing.expectEqual(@as(i64, 0), try seek(fd, 0, Seek.end));
    try close(fd);
    try testing.expectError(Error.ReadOnly, open("/app0/data.bin", O.wronly));
}
