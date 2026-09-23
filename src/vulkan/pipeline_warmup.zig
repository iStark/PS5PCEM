// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bounded, per-title SPIR-V catalog for warming the driver's compute cache.
//! Jobs load their own inputs, so queued warmups do not retain shader bodies.
//! Catalogs only affect compilation; their contents are never dispatched.
const std = @import("std");
const compiler = @import("pipeline_compiler.zig");
const allocator = std.heap.page_allocator;
pub const maximum_module_bytes = 16 * 1024 * 1024;
const maximum_catalog_bytes = 512 * 1024 * 1024;
const maximum_save_bytes = 32 * 1024 * 1024;
const maximum_jobs = 2048;

pub const Source = struct {
    context: ?*anyopaque,
    compile: *const fn (?*anyopaque, []const u32) bool,
};

pub const Cache = struct {
    directory: std.Io.Dir,
    jobs: std.ArrayList(*Work) = .empty,
    source: Source = undefined,
    started: bool = false,
    stopping: std.atomic.Value(bool) = .init(false),
    catalog_bytes: u64 = 0,
    pending_save_bytes: std.atomic.Value(usize) = .init(0),
    warmed: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    warmup_count: u32 = 0,

    pub fn open(path: []const u8) !*Cache {
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        try std.Io.Dir.cwd().createDirPath(io, path);
        const directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        errdefer directory.close(io);
        const self = try allocator.create(Cache);
        self.* = .{ .directory = directory };
        return self;
    }

    /// Called on the renderer thread after its address and driver handles are
    /// stable. Enumeration retains only small job records, not SPIR-V bytes.
    pub fn start(self: *Cache, queue: *compiler.Queue, source: Source) void {
        if (self.started) return;
        self.started = true;
        self.source = source;
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var iterator = self.directory.iterate();
        while (iterator.next(io) catch null) |entry| {
            if (self.jobs.items.len >= maximum_jobs) break;
            if (entry.kind != .file or entry.name.len != 20 or !std.mem.endsWith(u8, entry.name, ".spv")) continue;
            const hash = std.fmt.parseInt(u64, entry.name[0..16], 16) catch continue;
            const file = self.directory.openFile(io, entry.name, .{}) catch continue;
            const length = file.length(io) catch 0;
            file.close(io);
            if (length < 20 or length > maximum_module_bytes or length % 4 != 0) continue;
            if (self.catalog_bytes + length > maximum_catalog_bytes) continue;
            const work = allocator.create(Work) catch break;
            work.* = .{ .owner = self, .hash = hash };
            self.jobs.append(allocator, work) catch {
                allocator.destroy(work);
                break;
            };
            self.catalog_bytes += length;
        }
        self.warmup_count = @intCast(self.jobs.items.len);
        for (self.jobs.items) |work| queue.submitBackground(&work.job);
        if (self.jobs.items.len != 0) std.debug.print(
            "[vulkan compiler] queued {d} compute warmups, workers={d}, catalog={d}MiB\n",
            .{ self.jobs.items.len, queue.worker_limit, self.catalog_bytes / (1024 * 1024) },
        );
    }

    /// Remember successful runtime compilations for the next launch. Workers
    /// own copied words until atomic publication; pending writes are bounded.
    pub fn record(self: *Cache, queue: *compiler.Queue, words: []const u32) void {
        const bytes = std.mem.sliceAsBytes(words);
        if (!self.started or bytes.len < 20 or bytes.len > maximum_module_bytes or self.jobs.items.len >= maximum_jobs) return;
        const hash = std.hash.Wyhash.hash(0, bytes);
        for (self.jobs.items) |work| {
            if (work.hash != hash) continue;
            // A corrupted catalog entry may be replaced by a successfully
            // compiled live module. Never inspect worker fields before done.
            if (work.save or !work.job.done.isSet() or work.validated) return;
        }
        if (self.catalog_bytes + bytes.len > maximum_catalog_bytes or
            self.pending_save_bytes.load(.acquire) + bytes.len > maximum_save_bytes) return;
        const owned = allocator.dupe(u32, words) catch return;
        const work = allocator.create(Work) catch {
            allocator.free(owned);
            return;
        };
        work.* = .{ .owner = self, .hash = hash, .words = owned, .save = true };
        self.jobs.append(allocator, work) catch {
            allocator.free(owned);
            allocator.destroy(work);
            return;
        };
        self.catalog_bytes += bytes.len;
        _ = self.pending_save_bytes.fetchAdd(bytes.len, .release);
        queue.submitBackground(&work.job);
    }

    pub fn stop(self: *Cache) void {
        self.stopping.store(true, .release);
    }

    /// The compiler queue must have been drained/joined first.
    pub fn deinit(self: *Cache) void {
        for (self.jobs.items) |work| allocator.destroy(work);
        self.jobs.deinit(allocator);
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        self.directory.close(threaded.io());
        allocator.destroy(self);
    }
};

const Work = struct {
    job: compiler.Job = .{ .run = run },
    owner: *Cache,
    hash: u64,
    words: ?[]u32 = null,
    save: bool = false,
    validated: bool = false,

    fn run(base: *compiler.Job) void {
        const self: *@This() = @fieldParentPtr("job", base);
        defer if (!self.save) {
            if (self.owner.finished.fetchAdd(1, .acq_rel) + 1 == self.owner.warmup_count) {
                std.debug.print("[vulkan compiler] warmup complete: compiled={d} failed={d} total={d}\n", .{
                    self.owner.warmed.load(.acquire), self.owner.failed.load(.acquire), self.owner.warmup_count,
                });
            }
        };
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var name_buffer: [20]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{x:0>16}.spv", .{self.hash}) catch unreachable;
        if (self.words) |words| {
            defer {
                _ = self.owner.pending_save_bytes.fetchSub(words.len * 4, .release);
                allocator.free(words);
                self.words = null;
            }
            var nonce: u64 = undefined;
            io.random(std.mem.asBytes(&nonce));
            var temporary_buffer: [48]u8 = undefined;
            const temporary = std.fmt.bufPrint(&temporary_buffer, "{s}.{x}.tmp", .{ name, nonce }) catch unreachable;
            const file = self.owner.directory.createFile(io, temporary, .{ .exclusive = true }) catch return;
            defer self.owner.directory.deleteFile(io, temporary) catch {};
            {
                defer file.close(io);
                file.writePositionalAll(io, std.mem.sliceAsBytes(words), 0) catch return;
            }
            self.owner.directory.rename(temporary, self.owner.directory, name, io) catch return;
            self.validated = true;
            return;
        }
        if (self.owner.stopping.load(.acquire)) return;
        const bytes = self.owner.directory.readFileAllocOptions(io, name, allocator, .limited(maximum_module_bytes), .of(u32), null) catch return;
        defer allocator.free(bytes);
        if (!validModule(bytes, self.hash)) {
            _ = self.owner.failed.fetchAdd(1, .monotonic);
            return;
        }
        self.validated = true;
        if (self.owner.source.compile(self.owner.source.context, std.mem.bytesAsSlice(u32, bytes))) {
            _ = self.owner.warmed.fetchAdd(1, .monotonic);
        } else {
            _ = self.owner.failed.fetchAdd(1, .monotonic);
        }
    }
};

fn validModule(bytes: []const u8, hash: u64) bool {
    if (bytes.len < 20 or bytes.len % 4 != 0 or std.hash.Wyhash.hash(0, bytes) != hash) return false;
    if (std.mem.readInt(u32, bytes[0..4], .little) != 0x07230203) return false;
    var offset: usize = 20;
    while (offset < bytes.len) {
        const count = std.mem.readInt(u32, bytes[offset..][0..4], .little) >> 16;
        if (count == 0 or count > (bytes.len - offset) / 4) return false;
        offset += count * 4;
    }
    return true;
}

test "warmup validates complete module bytes and rejects corruption" {
    const words = [_]u32{ 0x07230203, 0x00010500, 0, 1, 0, 0x00010000 };
    const bytes = std.mem.sliceAsBytes(&words);
    const hash = std.hash.Wyhash.hash(0, bytes);
    try std.testing.expect(validModule(bytes, hash));
    try std.testing.expect(!validModule(bytes[0 .. bytes.len - 1], hash));
    var corrupt = words;
    corrupt[5] = 0;
    const corrupt_bytes = std.mem.sliceAsBytes(&corrupt);
    try std.testing.expect(!validModule(corrupt_bytes, std.hash.Wyhash.hash(0, corrupt_bytes)));
    try std.testing.expect(!validModule(bytes, hash +% 1));
}

test "catalog saves once then warms validated words and repairs corruption" {
    const Probe = struct {
        calls: std.atomic.Value(u32) = .init(0),
        fn compile(raw: ?*anyopaque, words: []const u32) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (words.len != 6 or words[5] != 0x00010000) return false;
            _ = self.calls.fetchAdd(1, .monotonic);
            return true;
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var queue = compiler.Queue{};
    defer queue.deinit();
    const cache = try allocator.create(Cache);
    cache.* = .{ .directory = try temporary.dir.openDir(std.testing.io, ".", .{ .iterate = true }) };
    defer {
        queue.waitIdle();
        cache.deinit();
    }
    var probe = Probe{};
    const source = Source{ .context = &probe, .compile = Probe.compile };
    cache.start(&queue, source);
    const words = [_]u32{ 0x07230203, 0x00010500, 0, 1, 0, 0x00010000 };
    cache.record(&queue, &words);
    cache.record(&queue, &words);
    queue.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), cache.jobs.items.len);
    try std.testing.expectEqual(@as(usize, 0), cache.pending_save_bytes.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), probe.calls.load(.acquire));

    const replay = try allocator.create(Cache);
    replay.* = .{ .directory = try temporary.dir.openDir(std.testing.io, ".", .{ .iterate = true }) };
    defer {
        queue.waitIdle();
        replay.deinit();
    }
    replay.start(&queue, source);
    queue.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), probe.calls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), replay.warmed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), replay.failed.load(.acquire));

    var name_buffer: [20]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{x:0>16}.spv", .{std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&words))});
    var corrupt = words;
    corrupt[5] = 0;
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = std.mem.sliceAsBytes(&corrupt) });
    const repair = try allocator.create(Cache);
    repair.* = .{ .directory = try temporary.dir.openDir(std.testing.io, ".", .{ .iterate = true }) };
    defer {
        queue.waitIdle();
        repair.deinit();
    }
    repair.start(&queue, source);
    queue.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), repair.failed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), probe.calls.load(.acquire));
    repair.record(&queue, &words);
    queue.waitIdle();
    const restored = try temporary.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&words), restored);
}

test "catalog bounds pending saves and cancels unstarted warmups at shutdown" {
    const Probe = struct {
        fn compile(_: ?*anyopaque, _: []const u32) bool {
            @panic("stopped warmup must not compile");
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const cache = try allocator.create(Cache);
    cache.* = .{ .directory = try temporary.dir.openDir(std.testing.io, ".", .{ .iterate = true }) };
    defer cache.deinit();
    var queue = compiler.Queue{};
    defer queue.deinit();
    cache.start(&queue, .{ .context = null, .compile = Probe.compile });
    const words = [_]u32{ 0x07230203, 0x00010500, 0, 1, 0, 0x00010000 };
    cache.pending_save_bytes.store(maximum_save_bytes, .release);
    cache.record(&queue, &words);
    try std.testing.expectEqual(@as(usize, 0), cache.jobs.items.len);
    cache.pending_save_bytes.store(0, .release);
    cache.record(&queue, &words);
    queue.waitIdle();
    const replay = try allocator.create(Cache);
    replay.* = .{ .directory = try temporary.dir.openDir(std.testing.io, ".", .{ .iterate = true }) };
    defer {
        queue.waitIdle();
        replay.deinit();
    }
    replay.stop();
    replay.start(&queue, .{ .context = null, .compile = Probe.compile });
    queue.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), replay.jobs.items.len);
    try std.testing.expectEqual(@as(u32, 0), replay.warmed.load(.acquire));
}
