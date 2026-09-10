// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! One outstanding driver-cache snapshot. The renderer joins before destroying
//! the cache/device; no driver handles or renderer allocator reach a detached job.
const std = @import("std");
const vk = @import("api.zig");

pub const Source = struct {
    device: vk.Device,
    cache: vk.PipelineCache,
    get_data: vk.PfnGetPipelineCacheData,
    generation: u64,
    maximum_bytes: usize,
    directory: std.Io.Dir,
    path: []const u8,
};

pub const Saver = struct {
    job: ?*Job = null,
    persisted_generation: u64 = 0,

    /// A busy writer coalesces requests. A newer generation is retried after
    /// this snapshot completes, without claiming it was included in the file.
    pub fn request(self: *Saver, source: Source) bool {
        self.reap(false);
        if (self.job != null or source.generation == self.persisted_generation) return false;
        const job = std.heap.page_allocator.create(Job) catch return false;
        job.* = .{ .source = source };
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
            std.heap.page_allocator.destroy(job);
            return false;
        };
        self.job = job;
        return true;
    }

    pub fn join(self: *Saver) void {
        self.reap(true);
    }

    /// Called only after pipeline producers stop, while driver handles and
    /// the directory/path still exist. Also retries a failed earlier save.
    pub fn finish(self: *Saver, source: Source) void {
        self.join();
        _ = self.request(source);
        self.join();
    }

    fn reap(self: *Saver, wait: bool) void {
        const job = self.job orelse return;
        if (!wait and !job.done.load(.acquire)) return;
        job.thread.?.join();
        if (job.saved) self.persisted_generation = job.source.generation;
        std.heap.page_allocator.destroy(job);
        self.job = null;
    }
};

const Job = struct {
    source: Source,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    saved: bool = false,

    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        const source = self.source;
        var data_size: usize = 0;
        if (source.get_data(source.device, source.cache, &data_size, null) != vk.success) return;
        if (data_size == 0 or data_size > source.maximum_bytes) return;
        const bytes = std.heap.page_allocator.alloc(u8, data_size) catch return;
        defer std.heap.page_allocator.free(bytes);
        if (source.get_data(source.device, source.cache, &data_size, bytes.ptr) != vk.success) return;
        if (data_size == 0 or data_size > bytes.len) return;
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        // Keep the last complete cache if extraction or writing fails. Each
        // writer uses a separate temporary file, including concurrent processes.
        var path_buffer: [1024]u8 = undefined;
        var suffix: u64 = undefined;
        io.random(std.mem.asBytes(&suffix));
        const temporary = std.fmt.bufPrint(&path_buffer, "{s}.{x}.tmp", .{ source.path, suffix }) catch return;
        const file = source.directory.createFile(io, temporary, .{ .exclusive = true }) catch return;
        defer source.directory.deleteFile(io, temporary) catch {};
        {
            defer file.close(io);
            file.writePositionalAll(io, bytes[0..data_size], 0) catch return;
        }
        source.directory.rename(temporary, source.directory, source.path, io) catch return;
        self.saved = true;
        if (data_size > 256 * 1024 * 1024)
            std.debug.print("[vulkan cache] persisted {d} MiB driver pipeline cache asynchronously\n", .{data_size / (1024 * 1024)});
    }
};

const TestDriver = struct {
    entered: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    reads: std.atomic.Value(u32) = .init(0),
    fail: bool = false,

    fn get(device: vk.Device, _: vk.PipelineCache, size: *usize, data: ?*anyopaque) callconv(vk.call) vk.Result {
        const self: *TestDriver = @ptrCast(@alignCast(device));
        self.entered.store(true, .release);
        while (!self.released.load(.acquire)) std.Thread.yield() catch {};
        if (data) |destination| {
            _ = self.reads.fetchAdd(1, .monotonic);
            if (self.fail) return vk.error_device_lost;
            const value = "complete snapshot";
            if (size.* < value.len) return vk.error_device_lost;
            @memcpy(@as([*]u8, @ptrCast(destination))[0..value.len], value);
            // Drivers may write fewer bytes than the initial size query.
            size.* = value.len;
        } else size.* = 64;
        return vk.success;
    }
};

test "pipeline cache saving returns while extraction waits and retains sampled generation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var driver = TestDriver{};
    var saver = Saver{};
    defer {
        driver.released.store(true, .release);
        saver.join();
    }
    var source = Source{ .device = @ptrCast(&driver), .cache = 1, .get_data = TestDriver.get, .generation = 1, .maximum_bytes = 128, .directory = temporary.dir, .path = "cache.bin" };
    try std.testing.expect(saver.request(source));
    while (!driver.entered.load(.acquire)) std.Thread.yield() catch {};
    source.generation = 2;
    try std.testing.expect(!saver.request(source));
    try std.testing.expectEqual(@as(u64, 0), saver.persisted_generation);
    driver.released.store(true, .release);
    saver.join();
    try std.testing.expectEqual(@as(u64, 1), saver.persisted_generation);
    saver.finish(source);
    try std.testing.expectEqual(@as(u64, 2), saver.persisted_generation);
    try std.testing.expectEqual(@as(u32, 2), driver.reads.load(.acquire));
    try std.testing.expect(!saver.request(source));
    const bytes = try temporary.dir.readFileAlloc(std.testing.io, "cache.bin", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "complete snapshot", bytes);
}

test "failed and oversized pipeline snapshots preserve the previous file and retry" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "cache.bin", .data = "old cache" });
    var driver = TestDriver{ .released = .init(true), .fail = true };
    var saver = Saver{};
    defer saver.join();
    var source = Source{ .device = @ptrCast(&driver), .cache = 1, .get_data = TestDriver.get, .generation = 1, .maximum_bytes = 128, .directory = temporary.dir, .path = "cache.bin" };
    saver.finish(source);
    try std.testing.expectEqual(@as(u64, 0), saver.persisted_generation);
    source.maximum_bytes = 32;
    driver.fail = false;
    saver.finish(source);
    try std.testing.expectEqual(@as(u64, 0), saver.persisted_generation);
    const before = try temporary.dir.readFileAlloc(std.testing.io, "cache.bin", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(before);
    try std.testing.expectEqualSlices(u8, "old cache", before);
    source.maximum_bytes = 128;
    saver.finish(source);
    try std.testing.expectEqual(@as(u64, 1), saver.persisted_generation);
    const after = try temporary.dir.readFileAlloc(std.testing.io, "cache.bin", std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, "complete snapshot", after);
}
