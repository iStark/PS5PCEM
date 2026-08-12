// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Host-backed implementation of the SceAvPlayer surface used by PS5 titles.
//!
//! FFmpeg performs container, H.264 and AAC decoding. Video is delivered to
//! the guest in the native NV12 layout expected by SceAvPlayer; audio is
//! returned as interleaved signed 16-bit stereo PCM. Allocations are made
//! through the callbacks supplied by the title so its GPU descriptors can use
//! the returned addresses directly.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const trace = @import("../trace.zig");
const filesystem = @import("../filesystem.zig");
const kernel_memory = @import("kernel_memory.zig");
const kernel_threading = @import("kernel_threading.zig");

const av_error_invalid_params: i32 = @bitCast(@as(u32, 0x806a_0001));
const av_error_operation_failed: i32 = @bitCast(@as(u32, 0x806a_0002));
const av_error_not_supported: i32 = @bitCast(@as(u32, 0x806a_0004));

const trick_speed_normal: i32 = 100;

const event_state_stop: u64 = 0x01;
const event_state_ready: u64 = 0x02;
const event_state_play: u64 = 0x03;
const event_state_pause: u64 = 0x04;
const event_warning: u64 = 0x20;
const warning_jump_complete: i32 = -2_140_536_669;

const stream_video: u32 = 1;
const stream_audio: u32 = 2;

// Safe defaults used until ffprobe supplies the actual stream geometry. The
// guest ABI must receive the source extent: Unity creates its video texture
// from these values, so silently downscaling a 4K stream breaks its upload.
const default_video_width: u32 = 1920;
const default_video_height: u32 = 1080;
const video_fps: u32 = 60;
const video_buffer_count = 2;

const audio_channels: u16 = 2;
const audio_sample_rate: u32 = 48_000;
const audio_samples_per_frame: u32 = 1024;
const audio_frame_bytes: usize = audio_samples_per_frame * audio_channels * @sizeOf(i16);
const audio_buffer_count = 8;
const playback_frame_ms: u64 = (1000 + video_fps - 1) / video_fps;
const unbounded_playback_ms: u64 = std.math.maxInt(u64);

const pipe_buffer_bytes = 64 * 1024;
const callback_read_bytes = 1024 * 1024;
const maximum_callback_source_bytes: u64 = 4 * 1024 * 1024 * 1024;

fn alignUp(value: u32, alignment: u32) u32 {
    return if (alignment == 0) value else (value +| alignment - 1) / alignment * alignment;
}

fn playbackClockNs() u64 {
    if (comptime builtin.os.tag != .windows) return 0;
    var counter: std.os.windows.LARGE_INTEGER = 0;
    var frequency: std.os.windows.LARGE_INTEGER = 0;
    if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() or
        !std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or
        counter < 0 or frequency <= 0)
    {
        return 0;
    }
    const scaled = @as(u128, @intCast(counter)) * std.time.ns_per_s;
    return @intCast(scaled / @as(u128, @intCast(frequency)));
}

const GuestAllocation = struct {
    address: u64 = 0,
    texture: bool = false,
};

const AllocationCallback = struct {
    address: u64,
    texture: bool,
};

const Player = struct {
    token: u8 = 0,
    allocated: bool = false,
    initialized: bool = false,
    source_ready: bool = false,
    started: bool = false,
    paused: bool = false,
    looping: bool = false,
    auto_start: bool = false,
    end_of_stream: bool = true,
    video_end_of_stream: bool = true,
    audio_end_of_stream: bool = true,
    seek_video_frame_pending: bool = false,
    seek_time_ms: u64 = 0,
    video_decode_start_ms: u64 = 0,
    duration_ms: u64 = 0,
    play_clock_started_ns: u64 = 0,
    pause_clock_started_ns: u64 = 0,
    paused_clock_ns: u64 = 0,
    /// Host shader translation can take seconds while one guest frame is in
    /// flight. Do not let that host-only stall skip an entire short movie:
    /// video delivery advances this ceiling one media frame at a time.
    playback_ceiling_ms: std.atomic.Value(u64) = .init(unbounded_playback_ms),
    software_video_decoder: bool = false,
    video_visible_width: u32 = default_video_width,
    video_visible_height: u32 = default_video_height,
    video_width: u32 = default_video_width,
    video_height: u32 = alignUp(default_video_height, 16),
    video_pitch: u32 = alignUp(default_video_width, 256),
    video_frame_bytes: usize = @as(usize, alignUp(default_video_width, 256)) * alignUp(default_video_height, 16) * 3 / 2,

    memory_object: u64 = 0,
    allocate: u64 = 0,
    deallocate: u64 = 0,
    allocate_texture: u64 = 0,
    deallocate_texture: u64 = 0,
    file_object: u64 = 0,
    file_open: u64 = 0,
    file_close: u64 = 0,
    file_read_offset: u64 = 0,
    file_size: u64 = 0,
    event_object: u64 = 0,
    event_callback: u64 = 0,

    source_path: [filesystem.maximum_path]u8 = undefined,
    source_path_length: usize = 0,
    temporary_source_path: [filesystem.maximum_path]u8 = undefined,
    temporary_source_path_length: usize = 0,

    video_child: ?std.process.Child = null,
    video_reader: ?std.Io.File.Reader = null,
    video_pipe_buffer: [pipe_buffer_bytes]u8 = undefined,
    video_buffers: [video_buffer_count]GuestAllocation = @splat(.{}),
    next_video_buffer: usize = 0,
    video_frame_index: u64 = 0,

    audio_child: ?std.process.Child = null,
    audio_reader: ?std.Io.File.Reader = null,
    audio_pipe_buffer: [pipe_buffer_bytes]u8 = undefined,
    audio_buffer: GuestAllocation = .{},
    next_audio_buffer: usize = 0,
    audio_frame_index: u64 = 0,
};

const maximum_players = 8;
var players: [maximum_players]Player = @splat(.{});
var materialized_source_sequence: u64 = 0;

/// FFmpeg's pipe readers and `std.process.Child` values are stateful and must
/// never be consumed or stopped concurrently. Unity is allowed to query audio
/// from several worker threads, so keep independent locks for the two streams:
/// serializing them with one lock would make a large video-frame read stall the
/// audio callback and introduce the very underruns AvPlayer is meant to avoid.
const PlayerLocks = struct {
    video: std.Io.Mutex = .init,
    audio: std.Io.Mutex = .init,
};

var player_locks: [maximum_players]PlayerLocks = @splat(.{});

fn locksForPlayer(player: *Player) *PlayerLocks {
    for (&players, 0..) |*candidate, index| {
        if (candidate == player) return &player_locks[index];
    }
    unreachable;
}

fn lockVideo(player: *Player) ?std.Io {
    const io = filesystem.attachedIo() orelse return null;
    locksForPlayer(player).video.lockUncancelable(io);
    return io;
}

fn unlockVideo(player: *Player, io: std.Io) void {
    locksForPlayer(player).video.unlock(io);
}

fn lockAudio(player: *Player) ?std.Io {
    const io = filesystem.attachedIo() orelse return null;
    locksForPlayer(player).audio.lockUncancelable(io);
    return io;
}

fn unlockAudio(player: *Player, io: std.Io) void {
    locksForPlayer(player).audio.unlock(io);
}

fn lockStreams(player: *Player) ?std.Io {
    const io = filesystem.attachedIo() orelse return null;
    const locks = locksForPlayer(player);
    locks.video.lockUncancelable(io);
    locks.audio.lockUncancelable(io);
    return io;
}

fn unlockStreams(player: *Player, io: std.Io) void {
    const locks = locksForPlayer(player);
    locks.audio.unlock(io);
    locks.video.unlock(io);
}

fn playerForHandle(handle: ?*anyopaque) ?*Player {
    const handle_value = handle orelse return null;
    for (&players) |*candidate| {
        if (handle_value == @as(*anyopaque, @ptrCast(&candidate.token)) and candidate.initialized) {
            return candidate;
        }
    }
    return null;
}

fn allocatePlayer() ?*Player {
    for (&players) |*candidate| {
        if (candidate.allocated) continue;
        candidate.* = .{ .allocated = true, .initialized = true };
        return candidate;
    }
    return null;
}

fn readGuestU32(address: u64) u32 {
    const bytes: *const [4]u8 = @ptrFromInt(address);
    return std.mem.readInt(u32, bytes, .little);
}

fn readGuestU64(address: u64) u64 {
    const bytes: *const [8]u8 = @ptrFromInt(address);
    return std.mem.readInt(u64, bytes, .little);
}

fn writeGuestU16(address: u64, value: u16) void {
    const bytes: *[2]u8 = @ptrFromInt(address);
    std.mem.writeInt(u16, bytes, value, .little);
}

fn writeGuestU32(address: u64, value: u32) void {
    const bytes: *[4]u8 = @ptrFromInt(address);
    std.mem.writeInt(u32, bytes, value, .little);
}

fn writeGuestU64(address: u64, value: u64) void {
    const bytes: *[8]u8 = @ptrFromInt(address);
    std.mem.writeInt(u64, bytes, value, .little);
}

fn writeGuestF32(address: u64, value: f32) void {
    writeGuestU32(address, @bitCast(value));
}

fn writeGuestF64(address: u64, value: f64) void {
    writeGuestU64(address, @bitCast(value));
}

/// Writes `SceAvPlayerVideoEx` at either the stream-info details offset or the
/// frame-info details offset. Keeping one layout writer avoids the two ABI
/// views drifting apart (the stream path previously placed crop and pitch
/// fields four bytes early, so Unity allocated a malformed video surface).
fn writeVideoDetailsEx(player: *const Player, address: u64) void {
    writeGuestU32(address, player.video_width);
    // The software decoder ABI reports the aligned allocation extent; the
    // visible 1080-line picture is expressed by crop_bottom=8. Reporting 1080
    // here makes clients seek the NV12 chroma plane eight rows too early.
    writeGuestU32(address + 4, player.video_height);
    writeGuestF32(
        address + 8,
        @as(f32, @floatFromInt(player.video_visible_width)) /
            @as(f32, @floatFromInt(player.video_visible_height)),
    );
    @as(*[3]u8, @ptrFromInt(address + 12)).* = .{ 'u', 'n', 'd' };
    writeGuestU32(address + 20, 0); // crop left
    writeGuestU32(address + 24, player.video_pitch - player.video_visible_width); // crop right
    writeGuestU32(address + 28, 0); // crop top
    writeGuestU32(address + 32, player.video_height - player.video_visible_height); // crop bottom
    writeGuestU32(address + 36, player.video_pitch);
    @as(*u8, @ptrFromInt(address + 40)).* = 8; // luma bit depth
    @as(*u8, @ptrFromInt(address + 41)).* = 8; // chroma bit depth
    @as(*u8, @ptrFromInt(address + 42)).* = 0; // limited range
    writeGuestF64(address + 48, @floatFromInt(video_fps));
}

fn clearGuest(address: u64, size: usize) bool {
    if (address == 0 or !kernel_memory.isGuestRangeAccessible(address, size)) return false;
    const bytes: [*]u8 = @ptrFromInt(address);
    @memset(bytes[0..size], 0);
    return true;
}

fn emitEventData(player: *Player, event_id: u64, data: u64) void {
    if (player.event_callback == 0) return;
    _ = kernel_threading.callGuestCurrent(player.event_callback, &.{
        player.event_object,
        event_id,
        0,
        data,
    }) catch |err| {
        std.debug.print(
            "[avplayer] event callback 0x{x} id={d} failed: {s}\n",
            .{ player.event_callback, event_id, @errorName(err) },
        );
    };
}

fn emitEvent(player: *Player, event_id: u64) void {
    emitEventData(player, event_id, 0);
}

fn emitWarning(player: *Player, warning: i32) void {
    const allocation = allocateGuest(player, @sizeOf(i32), false) orelse return;
    defer deallocateGuest(player, allocation);
    writeGuestU32(allocation.address, @bitCast(warning));
    emitEventData(player, event_warning, allocation.address);
}

fn allocateGuest(player: *Player, size: usize, prefer_texture: bool) ?GuestAllocation {
    const callbacks: [2]AllocationCallback = if (prefer_texture)
        .{
            .{ .address = player.allocate_texture, .texture = true },
            .{ .address = player.allocate, .texture = false },
        }
    else
        .{
            .{ .address = player.allocate, .texture = false },
            .{ .address = player.allocate_texture, .texture = true },
        };
    for (callbacks) |callback| {
        if (callback.address == 0) continue;
        const address = kernel_threading.callGuestCurrent(callback.address, &.{
            player.memory_object,
            0x100,
            size,
        }) catch continue;
        if (address == 0 or !kernel_memory.isGuestRangeAccessible(address, size)) continue;
        return .{ .address = address, .texture = callback.texture };
    }
    return null;
}

fn deallocateGuest(player: *Player, allocation: GuestAllocation) void {
    if (allocation.address == 0) return;
    const callback = if (allocation.texture) player.deallocate_texture else player.deallocate;
    if (callback == 0) return;
    _ = kernel_threading.callGuestCurrent(callback, &.{
        player.memory_object,
        allocation.address,
    }) catch |err| {
        std.debug.print(
            "[avplayer] deallocation callback 0x{x} failed: {s}\n",
            .{ callback, @errorName(err) },
        );
    };
}

fn releaseGuestBuffers(player: *Player) void {
    releaseVideoBuffers(player);
    releaseAudioBuffer(player);
}

fn releaseVideoBuffers(player: *Player) void {
    for (&player.video_buffers) |*allocation| {
        deallocateGuest(player, allocation.*);
        allocation.* = .{};
    }
}

fn releaseAudioBuffer(player: *Player) void {
    deallocateGuest(player, player.audio_buffer);
    player.audio_buffer = .{};
}

fn stopVideoDecoder(player: *Player) void {
    player.video_reader = null;
    if (player.video_child) |*child| {
        if (filesystem.attachedIo()) |io| child.kill(io);
    }
    player.video_child = null;
}

fn stopAudioDecoder(player: *Player) void {
    player.audio_reader = null;
    if (player.audio_child) |*child| {
        if (filesystem.attachedIo()) |io| child.kill(io);
    }
    player.audio_child = null;
}

fn stopDecoders(player: *Player) void {
    stopVideoDecoder(player);
    stopAudioDecoder(player);
}

fn finishStream(player: *Player, video: bool) void {
    if (video) {
        player.video_end_of_stream = true;
        player.playback_ceiling_ms.store(unbounded_playback_ms, .release);
    } else {
        player.audio_end_of_stream = true;
    }
    if (!player.video_end_of_stream or !player.audio_end_of_stream) return;
    player.end_of_stream = true;
    player.started = false;
    emitEvent(player, event_state_stop);
}

fn sourcePath(player: *Player) []const u8 {
    return player.source_path[0..player.source_path_length];
}

fn releaseTemporarySource(player: *Player) void {
    if (player.temporary_source_path_length == 0) return;
    if (filesystem.attachedIo()) |io| {
        std.Io.Dir.cwd().deleteFile(
            io,
            player.temporary_source_path[0..player.temporary_source_path_length],
        ) catch {};
    }
    player.temporary_source_path_length = 0;
}

fn callbackResult(raw: u64) i32 {
    return @bitCast(@as(u32, @truncate(raw)));
}

/// Unity commonly exposes VideoClip byte ranges through AvPlayer's custom
/// file callbacks even though every URI names the same `.resource` file. Feed
/// FFmpeg an exact host-side snapshot of that virtual file; opening the URI on
/// the host directly would always decode the first embedded movie instead.
fn materializeCallbackSource(player: *Player, guest_path: []const u8) !void {
    if (player.file_open == 0 or player.file_close == 0 or
        player.file_read_offset == 0 or player.file_size == 0)
    {
        return error.MissingFileCallbacks;
    }
    const io = filesystem.attachedIo() orelse return error.NotAttached;
    const path_allocation = allocateGuest(player, guest_path.len + 1, false) orelse return error.OutOfMemory;
    defer deallocateGuest(player, path_allocation);
    const callback_path: [*]u8 = @ptrFromInt(path_allocation.address);
    @memcpy(callback_path[0..guest_path.len], guest_path);
    callback_path[guest_path.len] = 0;

    const opened = callbackResult(try kernel_threading.callGuestCurrent(player.file_open, &.{
        player.file_object,
        path_allocation.address,
    }));
    if (opened < 0) return error.OpenFailed;
    defer _ = kernel_threading.callGuestCurrent(player.file_close, &.{player.file_object}) catch 0;

    const source_size = try kernel_threading.callGuestCurrent(player.file_size, &.{player.file_object});
    if (source_size == 0 or source_size > maximum_callback_source_bytes) return error.InvalidSourceSize;

    const chunk_size: usize = @intCast(@min(source_size, callback_read_bytes));
    const chunk_allocation = allocateGuest(player, chunk_size, false) orelse return error.OutOfMemory;
    defer deallocateGuest(player, chunk_allocation);
    const chunk: [*]const u8 = @ptrFromInt(chunk_allocation.address);

    materialized_source_sequence +%= 1;
    const relative = try std.fmt.bufPrint(
        &player.temporary_source_path,
        "out\\avplayer-source-{x}-{d}.bin",
        .{ @intFromPtr(&player.token), materialized_source_sequence },
    );
    player.temporary_source_path_length = relative.len;
    errdefer releaseTemporarySource(player);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "out");
    const file = try cwd.createFile(io, relative, .{ .truncate = true });
    defer file.close(io);

    var offset: u64 = 0;
    while (offset < source_size) {
        const requested: u32 = @intCast(@min(source_size - offset, chunk_size));
        const read_result = callbackResult(try kernel_threading.callGuestCurrent(
            player.file_read_offset,
            &.{ player.file_object, chunk_allocation.address, offset, requested },
        ));
        if (read_result <= 0) return error.ReadFailed;
        const received: usize = @min(@as(usize, @intCast(read_result)), requested);
        try file.writePositionalAll(io, chunk[0..received], offset);
        offset += received;
    }

    var absolute: [filesystem.maximum_path]u8 = undefined;
    const absolute_length = try cwd.realPathFile(io, relative, &absolute);
    @memcpy(player.source_path[0..absolute_length], absolute[0..absolute_length]);
    player.source_path_length = absolute_length;
    std.debug.print(
        "[avplayer] materialized callback source bytes={d} path='{s}'\n",
        .{ source_size, sourcePath(player) },
    );
}

fn probeDurationMs(player: *Player) ?u64 {
    const io = filesystem.attachedIo() orelse return null;
    const root = filesystem.attachedRoot() orelse return null;
    const argv = [_][]const u8{
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        sourcePath(player),
    };
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = root },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const value = std.mem.trim(u8, result.stdout, " \r\n\t");
    const seconds = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(seconds) or seconds <= 0 or seconds > 24 * 60 * 60) return null;
    return @intFromFloat(@round(seconds * 1000.0));
}

fn probeVideoGeometry(player: *Player) bool {
    const io = filesystem.attachedIo() orelse return false;
    const root = filesystem.attachedRoot() orelse return false;
    const argv = [_][]const u8{
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height",
        "-of",
        "csv=p=0:s=x",
        sourcePath(player),
    };
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = root },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const value = std.mem.trim(u8, result.stdout, " \r\n\t");
    var fields = std.mem.splitScalar(u8, value, 'x');
    const width = std.fmt.parseInt(u32, fields.next() orelse return false, 10) catch return false;
    const height = std.fmt.parseInt(u32, fields.next() orelse return false, 10) catch return false;
    if (fields.next() != null or width == 0 or height == 0 or width > 8192 or height > 8192) return false;

    const surface_width = if (player.software_video_decoder) width else alignUp(width, 16);
    const surface_height = if (player.software_video_decoder) height else alignUp(height, 16);
    const pitch = alignUp(surface_width, 256);
    const byte_count_u64 = @as(u64, pitch) * surface_height * 3 / 2;
    const byte_count = std.math.cast(usize, byte_count_u64) orelse return false;
    if (byte_count == 0 or byte_count > 256 * 1024 * 1024) return false;

    player.video_visible_width = width;
    player.video_visible_height = height;
    player.video_width = surface_width;
    player.video_height = surface_height;
    player.video_pitch = pitch;
    player.video_frame_bytes = byte_count;
    return true;
}

fn startVideoDecoder(player: *Player) !void {
    stopVideoDecoder(player);
    const io = filesystem.attachedIo() orelse return error.NotAttached;
    const root = filesystem.attachedRoot() orelse return error.NotAttached;
    var filter_buffer: [128]u8 = undefined;
    const filter = try std.fmt.bufPrint(
        &filter_buffer,
        "pad={d}:{d}:0:0:black",
        .{ player.video_pitch, player.video_height },
    );
    var seek_buffer: [32]u8 = undefined;
    const seek_seconds = try std.fmt.bufPrint(
        &seek_buffer,
        "{d}.{d:0>3}",
        .{ player.video_decode_start_ms / 1000, player.video_decode_start_ms % 1000 },
    );
    const argv = [_][]const u8{
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        seek_seconds,
        "-i",
        sourcePath(player),
        "-map",
        "0:v:0",
        "-an",
        "-vf",
        filter,
        "-pix_fmt",
        "nv12",
        "-f",
        "rawvideo",
        "pipe:1",
    };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .dir = root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    });
    errdefer child.kill(io);
    const output = child.stdout orelse return error.MissingPipe;
    player.video_child = child;
    player.video_reader = output.readerStreaming(io, &player.video_pipe_buffer);
}

fn startAudioDecoder(player: *Player) !void {
    stopAudioDecoder(player);
    const io = filesystem.attachedIo() orelse return error.NotAttached;
    const root = filesystem.attachedRoot() orelse return error.NotAttached;
    var seek_buffer: [32]u8 = undefined;
    const seek_seconds = try std.fmt.bufPrint(
        &seek_buffer,
        "{d}.{d:0>3}",
        .{ player.seek_time_ms / 1000, player.seek_time_ms % 1000 },
    );
    const argv = [_][]const u8{
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        sourcePath(player),
        "-ss",
        seek_seconds,
        "-map",
        "0:a:0",
        "-vn",
        "-acodec",
        "pcm_s16le",
        "-ar",
        "48000",
        "-ac",
        "2",
        "-f",
        "s16le",
        "pipe:1",
    };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .dir = root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    });
    errdefer child.kill(io);
    const output = child.stdout orelse return error.MissingPipe;
    player.audio_child = child;
    player.audio_reader = output.readerStreaming(io, &player.audio_pipe_buffer);
}

fn ensureVideoBuffers(player: *Player) bool {
    for (&player.video_buffers) |*allocation| {
        if (allocation.address != 0) continue;
        allocation.* = allocateGuest(player, player.video_frame_bytes, true) orelse {
            releaseVideoBuffers(player);
            return false;
        };
    }
    return true;
}

fn ensureAudioBuffer(player: *Player) bool {
    if (player.audio_buffer.address != 0) return true;
    player.audio_buffer = allocateGuest(player, audio_frame_bytes * audio_buffer_count, false) orelse return false;
    return true;
}

fn readVideoFrame(player: *Player) ?u64 {
    if (!ensureVideoBuffers(player)) return null;
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        if (player.video_reader == null) startVideoDecoder(player) catch return null;
        const allocation = player.video_buffers[player.next_video_buffer];
        const frame: [*]u8 = @ptrFromInt(allocation.address);
        if (player.video_reader) |*reader| {
            reader.interface.readSliceAll(frame[0..player.video_frame_bytes]) catch {
                stopVideoDecoder(player);
                if (!player.looping) {
                    finishStream(player, true);
                    return null;
                }
                player.seek_time_ms = 0;
                player.video_decode_start_ms = 0;
                player.video_frame_index = 0;
                player.video_end_of_stream = false;
                continue;
            };
            player.next_video_buffer = (player.next_video_buffer + 1) % video_buffer_count;
            return allocation.address;
        }
    }
    return null;
}

fn readAudioFrame(player: *Player) ?u64 {
    if (!ensureAudioBuffer(player)) return null;
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        if (player.audio_reader == null) startAudioDecoder(player) catch return null;
        const address = player.audio_buffer.address + player.next_audio_buffer * audio_frame_bytes;
        const frame: [*]u8 = @ptrFromInt(address);
        if (player.audio_reader) |*reader| {
            reader.interface.readSliceAll(frame[0..audio_frame_bytes]) catch {
                stopAudioDecoder(player);
                if (!player.looping) {
                    finishStream(player, false);
                    return null;
                }
                player.seek_time_ms = 0;
                player.audio_frame_index = 0;
                player.audio_end_of_stream = false;
                continue;
            };
            player.next_audio_buffer = (player.next_audio_buffer + 1) % audio_buffer_count;
            return address;
        }
    }
    return null;
}

fn initEx(init_data: ?*const anyopaque, handle: ?*?*anyopaque) callconv(abi.guest) i32 {
    const output = handle orelse return av_error_invalid_params;
    const init_address = if (init_data) |data| @intFromPtr(data) else return av_error_invalid_params;
    if (!kernel_memory.isGuestRangeAccessible(init_address, 120)) return av_error_invalid_params;

    const player = allocatePlayer() orelse return av_error_operation_failed;
    player.memory_object = readGuestU64(init_address + 8);
    player.allocate = readGuestU64(init_address + 16);
    player.deallocate = readGuestU64(init_address + 24);
    player.allocate_texture = readGuestU64(init_address + 32);
    player.deallocate_texture = readGuestU64(init_address + 40);
    player.file_object = readGuestU64(init_address + 48);
    player.file_open = readGuestU64(init_address + 56);
    player.file_close = readGuestU64(init_address + 64);
    player.file_read_offset = readGuestU64(init_address + 72);
    player.file_size = readGuestU64(init_address + 80);
    player.event_object = readGuestU64(init_address + 88);
    player.event_callback = readGuestU64(init_address + 96);
    player.auto_start = @as(*const u8, @ptrFromInt(init_address + 116)).* != 0;
    output.* = &player.token;
    std.debug.print(
        "[avplayer] InitEx ffmpeg auto_start={any} alloc=0x{x}/0x{x} file=0x{x}/0x{x}/0x{x} event=0x{x}\n",
        .{
            player.auto_start,
            player.allocate_texture,
            player.allocate,
            player.file_open,
            player.file_read_offset,
            player.file_size,
            player.event_callback,
        },
    );
    return errno.ok;
}

fn postInit(handle: ?*anyopaque, post_data: ?*const anyopaque) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    if (post_data) |data| {
        const address = @intFromPtr(data);
        if (!kernel_memory.isGuestRangeAccessible(address, 12)) return av_error_invalid_params;
        player.software_video_decoder = readGuestU32(address + 8) == 1;
    }
    std.debug.print(
        "[avplayer] PostInit video_decoder={s}\n",
        .{if (player.software_video_decoder) "software2" else "default"},
    );
    return errno.ok;
}

fn addSourceEx(
    handle: ?*anyopaque,
    uri_type: u32,
    source_details: ?*const anyopaque,
) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    const io = lockStreams(player) orelse return av_error_operation_failed;
    defer unlockStreams(player, io);
    if (!player.initialized) return av_error_invalid_params;
    if (uri_type != 0) return av_error_invalid_params;
    const details_address = if (source_details) |details| @intFromPtr(details) else return av_error_invalid_params;
    if (!kernel_memory.isGuestRangeAccessible(details_address, 16)) return av_error_invalid_params;
    const path_address = readGuestU64(details_address);
    const path_length = readGuestU32(details_address + 8);
    if (path_address == 0 or path_length == 0 or path_length > filesystem.maximum_path or
        !kernel_memory.isGuestRangeAccessible(path_address, path_length))
    {
        return av_error_invalid_params;
    }

    const guest_path: [*]const u8 = @ptrFromInt(path_address);
    var normalized: [filesystem.maximum_path]u8 = undefined;
    const relative = filesystem.mountRelative(guest_path[0..path_length], &normalized) orelse {
        return av_error_invalid_params;
    };
    stopDecoders(player);
    releaseGuestBuffers(player);
    releaseTemporarySource(player);
    @memcpy(player.source_path[0..relative.len], relative);
    player.source_path_length = relative.len;
    if (player.file_open != 0 or player.file_read_offset != 0 or player.file_size != 0) {
        materializeCallbackSource(player, guest_path[0..path_length]) catch |err| {
            std.debug.print(
                "[avplayer] custom file source '{s}' failed: {s}; using host path\n",
                .{ relative, @errorName(err) },
            );
        };
    }
    player.source_ready = true;
    player.end_of_stream = false;
    player.video_end_of_stream = false;
    player.audio_end_of_stream = false;
    player.seek_video_frame_pending = false;
    player.seek_time_ms = 0;
    player.video_decode_start_ms = 0;
    player.playback_ceiling_ms.store(unbounded_playback_ms, .release);
    if (!probeVideoGeometry(player)) {
        std.debug.print("[avplayer] ffprobe video geometry unavailable; using {d}x{d}\n", .{
            player.video_visible_width,
            player.video_visible_height,
        });
    }
    player.duration_ms = probeDurationMs(player) orelse 0;
    std.debug.print(
        "[avplayer] source '{s}' duration={d}ms video={d}x{d} pitch={d} bytes={d} (FFmpeg NV12 + PCM16)\n",
        .{
            relative,
            player.duration_ms,
            player.video_width,
            player.video_height,
            player.video_pitch,
            player.video_frame_bytes,
        },
    );
    emitEvent(player, event_state_ready);
    // `start` takes the same stream locks. Auto-start is uncommon, but handle
    // it inline so the callback cannot deadlock on a non-recursive mutex.
    if (player.auto_start) return startLocked(player);
    return errno.ok;
}

fn streamCount(handle: ?*anyopaque) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    return if (player.source_ready) 2 else 0;
}

/// Writes the original 32-byte `SceAvPlayerStreamInfo` ABI. Some PS5 Unity
/// middleware still queries this view even when the player itself was created
/// with `sceAvPlayerInitEx`.
fn writeStreamInfo(player: *const Player, stream_id: u32, address: u64) void {
    if (stream_id == 0) {
        writeGuestU32(address, stream_video);
        writeGuestU32(address + 8, player.video_visible_width);
        writeGuestU32(address + 12, player.video_visible_height);
        writeGuestF32(
            address + 16,
            @as(f32, @floatFromInt(player.video_visible_width)) /
                @as(f32, @floatFromInt(player.video_visible_height)),
        );
        @as(*[3]u8, @ptrFromInt(address + 20)).* = .{ 'u', 'n', 'd' };
    } else {
        writeGuestU32(address, stream_audio);
        writeGuestU16(address + 8, audio_channels);
        writeGuestU32(address + 12, audio_sample_rate);
        // Stream metadata describes the format; the per-frame API supplies
        // the actual decoded payload size.
        writeGuestU32(address + 16, 0);
        @as(*[3]u8, @ptrFromInt(address + 20)).* = .{ 'u', 'n', 'd' };
    }
    writeGuestU64(address + 24, player.duration_ms);
}

pub fn getStreamInfo(handle: ?*anyopaque, stream_id: u32, info: ?*anyopaque) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    if (!player.source_ready or stream_id > 1) return av_error_invalid_params;
    const address = if (info) |value| @intFromPtr(value) else return av_error_invalid_params;
    if (!clearGuest(address, 32)) return av_error_invalid_params;
    writeStreamInfo(player, stream_id, address);
    return errno.ok;
}

fn getStreamInfoEx(handle: ?*anyopaque, stream_id: u32, info: ?*anyopaque) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    if (!player.source_ready or stream_id > 1) return av_error_invalid_params;
    const address = if (info) |value| @intFromPtr(value) else return av_error_invalid_params;
    if (!clearGuest(address, 104)) return av_error_invalid_params;
    writeGuestU64(address, 104);
    if (stream_id == 0) {
        writeGuestU32(address + 8, stream_video);
        writeVideoDetailsEx(player, address + 16);
    } else {
        writeGuestU32(address + 8, stream_audio);
        writeGuestU16(address + 16, audio_channels);
        writeGuestU32(address + 20, audio_sample_rate);
        @as(*[3]u8, @ptrFromInt(address + 28)).* = .{ 'u', 'n', 'd' };
    }
    writeGuestU64(address + 96, player.duration_ms);
    return errno.ok;
}

fn enableStream(handle: ?*anyopaque, stream_id: u32) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    return if (player.source_ready and stream_id < 2)
        errno.ok
    else
        av_error_invalid_params;
}

pub fn disableStream(handle: ?*anyopaque, stream_id: u32) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    return if (player.source_ready and stream_id < 2)
        errno.ok
    else
        av_error_invalid_params;
}

fn startLocked(player: *Player) i32 {
    if (!player.source_ready) return av_error_invalid_params;
    stopDecoders(player);
    player.started = true;
    player.paused = false;
    player.end_of_stream = false;
    player.video_end_of_stream = false;
    player.audio_end_of_stream = false;
    player.seek_video_frame_pending = false;
    player.seek_time_ms = 0;
    player.video_decode_start_ms = 0;
    player.video_frame_index = 0;
    player.audio_frame_index = 0;
    player.play_clock_started_ns = playbackClockNs();
    player.pause_clock_started_ns = 0;
    player.paused_clock_ns = 0;
    player.playback_ceiling_ms.store(playback_frame_ms, .release);
    startVideoDecoder(player) catch |err| {
        std.debug.print("[avplayer] cannot start FFmpeg video: {s}\n", .{@errorName(err)});
        player.started = false;
        player.end_of_stream = true;
        player.video_end_of_stream = true;
        player.audio_end_of_stream = true;
        return av_error_operation_failed;
    };
    emitEvent(player, event_state_play);
    return errno.ok;
}

fn start(handle: ?*anyopaque) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    const io = lockStreams(player) orelse return av_error_operation_failed;
    defer unlockStreams(player, io);
    if (!player.initialized) return av_error_invalid_params;
    return startLocked(player);
}

fn stop(handle: ?*anyopaque) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    const io = lockStreams(player) orelse return av_error_operation_failed;
    defer unlockStreams(player, io);
    if (!player.initialized) return av_error_invalid_params;
    std.debug.print(
        "[avplayer] stop video_frames={d} audio_frames={d} duration={d}ms\n",
        .{ player.video_frame_index, player.audio_frame_index, player.duration_ms },
    );
    stopDecoders(player);
    player.started = false;
    player.paused = false;
    player.end_of_stream = true;
    player.video_end_of_stream = true;
    player.audio_end_of_stream = true;
    player.playback_ceiling_ms.store(unbounded_playback_ms, .release);
    emitEvent(player, event_state_stop);
    return errno.ok;
}

fn pause(handle: ?*anyopaque) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    const io = lockStreams(player) orelse return av_error_operation_failed;
    defer unlockStreams(player, io);
    if (!player.initialized) return av_error_invalid_params;
    if (!player.started) return av_error_invalid_params;
    player.paused = true;
    player.pause_clock_started_ns = playbackClockNs();
    emitEvent(player, event_state_pause);
    return errno.ok;
}

fn resumePlayback(handle: ?*anyopaque) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    const io = lockStreams(player) orelse return av_error_operation_failed;
    defer unlockStreams(player, io);
    if (!player.initialized) return av_error_invalid_params;
    if (!player.started) return av_error_invalid_params;
    const now = playbackClockNs();
    if (player.paused and now >= player.pause_clock_started_ns) {
        player.paused_clock_ns +|= now - player.pause_clock_started_ns;
    }
    player.paused = false;
    player.pause_clock_started_ns = 0;
    emitEvent(player, event_state_play);
    return errno.ok;
}

fn setLooping(handle: ?*anyopaque, looping: u8) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    const io = lockStreams(player) orelse return av_error_operation_failed;
    defer unlockStreams(player, io);
    if (!player.initialized) return av_error_invalid_params;
    if (!player.source_ready) return av_error_invalid_params;
    player.looping = looping != 0;
    return errno.ok;
}

fn jumpToTime(handle: ?*anyopaque, time_ms: u64) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    const io = lockStreams(player) orelse return av_error_operation_failed;
    defer unlockStreams(player, io);
    if (!player.initialized) return av_error_invalid_params;
    if (!player.source_ready) return av_error_invalid_params;
    stopDecoders(player);
    player.seek_time_ms = time_ms;
    player.video_decode_start_ms = time_ms;
    player.video_frame_index = time_ms * video_fps / 1000;
    player.audio_frame_index = time_ms * audio_sample_rate / audio_samples_per_frame / 1000;
    player.play_clock_started_ns = playbackClockNs();
    player.pause_clock_started_ns = if (player.paused) player.play_clock_started_ns else 0;
    player.paused_clock_ns = 0;
    player.playback_ceiling_ms.store(time_ms +| playback_frame_ms, .release);
    player.end_of_stream = false;
    player.video_end_of_stream = false;
    player.audio_end_of_stream = false;
    player.seek_video_frame_pending = player.paused;
    emitWarning(player, warning_jump_complete);
    return errno.ok;
}

fn simpleAction(handle: ?*anyopaque, _: u64, _: u64) callconv(abi.guest) i32 {
    return if (playerForHandle(handle) != null) errno.ok else av_error_invalid_params;
}

fn playbackPositionMs(player: *const Player) u64 {
    const now = if (player.paused) player.pause_clock_started_ns else playbackClockNs();
    if (now == 0 or player.play_clock_started_ns == 0 or now < player.play_clock_started_ns) {
        return player.seek_time_ms;
    }
    const elapsed_ns = now - player.play_clock_started_ns;
    const active_ns = elapsed_ns -| player.paused_clock_ns;
    const host_position = player.seek_time_ms + active_ns / std.time.ns_per_ms;
    return @min(host_position, player.playback_ceiling_ms.load(.acquire));
}

pub fn currentTime(handle: ?*anyopaque) callconv(abi.guest) u64 {
    const player = playerForHandle(handle) orelse return 0;
    if (!player.source_ready or !player.started) return 0;
    const io = lockStreams(player) orelse return 0;
    defer unlockStreams(player, io);
    return playbackPositionMs(player);
}

pub fn setTrickSpeed(handle: ?*anyopaque, speed: i32) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    if (!player.source_ready) return av_error_invalid_params;
    // Software playback currently implements real-time forward playback only.
    // Reporting the other documented rates as unsupported lets middleware
    // fall back cleanly instead of assuming that the clock was changed.
    return if (speed == trick_speed_normal) errno.ok else av_error_not_supported;
}

fn playbackVideoFrame(position_ms: u64, duration_ms: u64) u64 {
    var frame = (position_ms *| video_fps) / 1000;
    if (duration_ms != 0) {
        const frame_count = @max(@as(u64, 1), (duration_ms *| video_fps) / 1000);
        frame = @min(frame, frame_count - 1);
    }
    return frame;
}

fn getVideoDataEx(handle: ?*anyopaque, info: ?*anyopaque) callconv(abi.guest) u8 {
    const player = playerForHandle(handle) orelse return 0;
    const io = lockVideo(player) orelse return 0;
    defer unlockVideo(player, io);
    if (!player.initialized) return 0;
    if (!player.started or player.end_of_stream or player.video_end_of_stream or
        (player.paused and !player.seek_video_frame_pending)) return 0;
    const playback_position = playbackPositionMs(player);
    const desired_frame = playbackVideoFrame(playback_position, player.duration_ms);
    if (!player.seek_video_frame_pending and
        desired_frame > player.video_frame_index + video_fps / 5)
    {
        stopVideoDecoder(player);
        player.video_frame_index = desired_frame;
        player.video_decode_start_ms = desired_frame * 1000 / video_fps;
        std.debug.print(
            "[avplayer] video resync frame={d} timestamp={d}ms clock={d}ms\n",
            .{ player.video_frame_index, player.video_decode_start_ms, playback_position },
        );
    }
    const next_timestamp = player.video_frame_index * 1000 / video_fps;
    if (!player.seek_video_frame_pending and next_timestamp > playback_position) return 0;
    const address = if (info) |value| @intFromPtr(value) else return 0;
    if (!clearGuest(address, 104)) return 0;
    const frame_address = readVideoFrame(player) orelse return 0;
    const timestamp = next_timestamp;
    player.video_frame_index += 1;
    player.playback_ceiling_ms.store(
        player.video_frame_index * 1000 / video_fps +| playback_frame_ms,
        .release,
    );
    player.seek_video_frame_pending = false;
    writeGuestU64(address, frame_address);
    writeGuestU64(address + 16, timestamp);
    writeVideoDetailsEx(player, address + 24);
    if (player.video_frame_index <= 4) {
        const frame: [*]const u8 = @ptrFromInt(frame_address);
        var sample_min: u8 = 255;
        var sample_max: u8 = 0;
        var sample_sum: u64 = 0;
        var sample_count: u64 = 0;
        var sample_offset: usize = 0;
        while (sample_offset < player.video_frame_bytes) : (sample_offset += 4096) {
            const value = frame[sample_offset];
            sample_min = @min(sample_min, value);
            sample_max = @max(sample_max, value);
            sample_sum += value;
            sample_count += 1;
        }
        std.debug.print(
            "[avplayer] video frame={d} timestamp={d}ms data=0x{x} {d}x{d} pitch={d} sample={d}..{d} avg={d}\n",
            .{
                player.video_frame_index,
                timestamp,
                frame_address,
                player.video_visible_width,
                player.video_visible_height,
                player.video_pitch,
                sample_min,
                sample_max,
                sample_sum / sample_count,
            },
        );
    }
    return 1;
}

fn getAudioData(handle: ?*anyopaque, info: ?*anyopaque) callconv(abi.guest) u8 {
    const player = playerForHandle(handle) orelse return 0;
    const io = lockAudio(player) orelse return 0;
    defer unlockAudio(player, io);
    if (!player.initialized) return 0;
    if (!player.started or player.paused or player.end_of_stream or player.audio_end_of_stream) return 0;
    const next_timestamp = player.audio_frame_index * audio_samples_per_frame * 1000 / audio_sample_rate;
    if (next_timestamp > playbackPositionMs(player)) return 0;
    const address = if (info) |value| @intFromPtr(value) else return 0;
    if (!clearGuest(address, 40)) return 0;
    const frame_address = readAudioFrame(player) orelse return 0;
    const timestamp = next_timestamp;
    player.audio_frame_index += 1;
    writeGuestU64(address, frame_address);
    writeGuestU64(address + 16, timestamp);
    writeGuestU16(address + 24, audio_channels);
    writeGuestU32(address + 28, audio_sample_rate);
    writeGuestU32(address + 32, audio_frame_bytes);
    @as(*[3]u8, @ptrFromInt(address + 36)).* = .{ 'u', 'n', 'd' };
    if (player.audio_frame_index == 1) {
        std.debug.print(
            "[avplayer] first audio frame data=0x{x} rate={d} channels={d} bytes={d}\n",
            .{ frame_address, audio_sample_rate, audio_channels, audio_frame_bytes },
        );
    }
    return 1;
}

fn isActive(handle: ?*anyopaque) callconv(abi.guest) u8 {
    const player = playerForHandle(handle) orelse return 0;
    const io = lockStreams(player) orelse return 0;
    defer unlockStreams(player, io);
    if (!player.initialized) return 0;
    return if (player.started and !player.end_of_stream) 1 else 0;
}

fn close(handle: ?*anyopaque) callconv(abi.guest) i32 {
    const player = playerForHandle(handle) orelse return av_error_invalid_params;
    const io = lockStreams(player) orelse return av_error_operation_failed;
    defer unlockStreams(player, io);
    if (!player.initialized) return av_error_invalid_params;
    stopDecoders(player);
    releaseGuestBuffers(player);
    releaseTemporarySource(player);
    player.initialized = false;
    player.source_ready = false;
    player.started = false;
    player.end_of_stream = true;
    player.video_end_of_stream = true;
    player.audio_end_of_stream = true;
    player.playback_ceiling_ms.store(unbounded_playback_ms, .release);
    player.event_object = 0;
    player.event_callback = 0;
    return errno.ok;
}

fn success() callconv(abi.guest) i32 {
    return errno.ok;
}

test "custom file callback results preserve signed ABI values" {
    try std.testing.expectEqual(@as(i32, -1), callbackResult(0xffff_ffff));
    try std.testing.expectEqual(@as(i32, 4096), callbackResult(4096));
}

test "video playback catch-up is duration bounded" {
    try std.testing.expectEqual(@as(u64, 0), playbackVideoFrame(0, 2950));
    try std.testing.expectEqual(@as(u64, 90), playbackVideoFrame(1500, 2950));
    try std.testing.expectEqual(@as(u64, 176), playbackVideoFrame(10_000, 2950));
}

test "video details use the SceAvPlayerVideoEx ABI layout" {
    var player = Player{};
    var bytes: [80]u8 = @splat(0);
    writeVideoDetailsEx(&player, @intFromPtr(&bytes));
    try std.testing.expectEqual(player.video_width, std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(player.video_height, std.mem.readInt(u32, bytes[4..8], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[20..24], .little));
    try std.testing.expectEqual(player.video_pitch - player.video_visible_width, std.mem.readInt(u32, bytes[24..28], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[28..32], .little));
    try std.testing.expectEqual(player.video_height - player.video_visible_height, std.mem.readInt(u32, bytes[32..36], .little));
    try std.testing.expectEqual(player.video_pitch, std.mem.readInt(u32, bytes[36..40], .little));
    try std.testing.expectEqualSlices(u8, &.{ 8, 8, 0 }, bytes[40..43]);
    try std.testing.expectEqual(
        @as(f64, video_fps),
        @as(f64, @bitCast(std.mem.readInt(u64, bytes[48..56], .little))),
    );
}

test "legacy stream info uses the bounded 32-byte ABI layout" {
    var player = Player{
        .duration_ms = 2_950,
        .video_visible_width = 1920,
        .video_visible_height = 1080,
    };
    var bytes: [40]u8 = @splat(0xcc);

    @memset(bytes[0..32], 0);
    writeStreamInfo(&player, 0, @intFromPtr(&bytes));
    try std.testing.expectEqual(stream_video, std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(player.video_visible_width, std.mem.readInt(u32, bytes[8..12], .little));
    try std.testing.expectEqual(player.video_visible_height, std.mem.readInt(u32, bytes[12..16], .little));
    try std.testing.expectEqualSlices(u8, "und", bytes[20..23]);
    try std.testing.expectEqual(player.duration_ms, std.mem.readInt(u64, bytes[24..32], .little));
    try std.testing.expectEqualSlices(u8, &([_]u8{0xcc} ** 8), bytes[32..40]);

    @memset(bytes[0..32], 0);
    writeStreamInfo(&player, 1, @intFromPtr(&bytes));
    try std.testing.expectEqual(stream_audio, std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(audio_channels, std.mem.readInt(u16, bytes[8..10], .little));
    try std.testing.expectEqual(audio_sample_rate, std.mem.readInt(u32, bytes[12..16], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[16..20], .little));
    try std.testing.expectEqualSlices(u8, &([_]u8{0xcc} ** 8), bytes[32..40]);
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceAvPlayerInitEx", .function = trace.wrap("sceAvPlayerInitEx", &initEx), .expect_id = "o9eWRkSL+M4" },
    .{ .name = "sceAvPlayerPostInit", .function = trace.wrap("sceAvPlayerPostInit", &postInit), .expect_id = "HD1YKVU26-M" },
    .{ .name = "sceAvPlayerAddSourceEx", .function = trace.wrap("sceAvPlayerAddSourceEx", &addSourceEx), .expect_id = "x8uvuFOPZhU" },
    .{ .name = "sceAvPlayerStart", .function = trace.wrap("sceAvPlayerStart", &start), .expect_id = "ET4Gr-Uu07s" },
    .{ .name = "sceAvPlayerStop", .function = trace.wrap("sceAvPlayerStop", &stop), .expect_id = "ZC17w3vB5Lo" },
    .{ .name = "sceAvPlayerPause", .function = trace.wrap("sceAvPlayerPause", &pause), .expect_id = "9y5v+fGN4Wk" },
    .{ .name = "sceAvPlayerResume", .function = trace.wrap("sceAvPlayerResume", &resumePlayback), .expect_id = "w5moABNwnRY" },
    .{ .name = "sceAvPlayerSetLooping", .function = trace.wrap("sceAvPlayerSetLooping", &setLooping), .expect_id = "OVths0xGfho" },
    .{ .name = "sceAvPlayerSetAvSyncMode", .function = trace.wrap("sceAvPlayerSetAvSyncMode", &simpleAction), .expect_id = "k-q+xOxdc3E" },
    .{ .name = "sceAvPlayerSetAvailableBandwidth", .function = trace.wrap("sceAvPlayerSetAvailableBandwidth", &simpleAction), .expect_id = "N6Oy-EjduiY" },
    .{ .name = "sceAvPlayerJumpToTime", .function = trace.wrap("sceAvPlayerJumpToTime", &jumpToTime), .expect_id = "XC9wM+xULz8" },
    .{ .name = "sceAvPlayerChangeStream", .function = trace.wrap("sceAvPlayerChangeStream", &simpleAction), .expect_id = "buMCiJftcfw" },
    .{ .name = "sceAvPlayerEnableStream", .function = trace.wrap("sceAvPlayerEnableStream", &enableStream), .expect_id = "ODJK2sn9w4A" },
    .{ .name = "sceAvPlayerGetVideoDataEx", .function = trace.wrap("sceAvPlayerGetVideoDataEx", &getVideoDataEx), .expect_id = "JdksQu8pNdQ" },
    .{ .name = "sceAvPlayerGetAudioData", .function = trace.wrap("sceAvPlayerGetAudioData", &getAudioData), .expect_id = "Wnp1OVcrZgk" },
    .{ .name = "sceAvPlayerGetStreamInfoEx", .function = trace.wrap("sceAvPlayerGetStreamInfoEx", &getStreamInfoEx), .expect_id = "ctTAcF5DiKQ" },
    .{ .name = "sceAvPlayerStreamCount", .function = trace.wrap("sceAvPlayerStreamCount", &streamCount), .expect_id = "hdTyRzCXQeQ" },
    .{ .name = "sceAvPlayerIsActive", .function = trace.wrap("sceAvPlayerIsActive", &isActive), .expect_id = "UbQoYawOsfY" },
    .{ .name = "sceAvPlayerClose", .function = trace.wrap("sceAvPlayerClose", &close), .expect_id = "NkJwDzKmIlw" },
    .{ .name = "sceAvPlayerSetLogCallback", .function = trace.wrap("sceAvPlayerSetLogCallback", &success), .expect_id = "eBTreZ84JFY" },
};
