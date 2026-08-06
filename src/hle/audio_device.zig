// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Sound leaving the emulator.
//!
//! A title hands over one buffer of samples at a time and expects the call to
//! take about as long as the sound lasts, because that is how it keeps time
//! with audio. Until now that wait was a sleep and the samples were discarded:
//! correct pacing, no sound.
//!
//! This plays them. The queue a host device already keeps is the same shape as
//! what the title is doing — hand over a buffer, wait until there is room for
//! the next — so the device does the pacing itself, and its clock is the real
//! one rather than an approximation of it.
//!
//! Where no device can be opened, nothing is lost: the caller keeps sleeping,
//! exactly as before. A title must not stall or fail because the host has no
//! sound card, is denied access to it, or is asked for a format it will not
//! take.

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows;

pub const Error = error{
    /// No sound output exists on this host build.
    Unsupported,
    /// The host refused the format, or has no device to play it on.
    DeviceUnavailable,
    /// One buffer of this size does not fit the fixed reserve below.
    BufferTooLarge,
};

/// How samples are represented.
pub const SampleFormat = enum {
    signed16,
    float32,

    pub fn bytes(self: SampleFormat) u16 {
        return switch (self) {
            .signed16 => 2,
            .float32 => 4,
        };
    }
};

pub const Config = struct {
    frequency: u32,
    channels: u8,
    format: SampleFormat,
    /// Samples per channel in one buffer.
    frames: u32,

    pub fn bytesPerFrame(self: Config) u32 {
        return @as(u32, self.channels) * self.format.bytes();
    }

    pub fn bufferBytes(self: Config) u64 {
        return @as(u64, self.frames) * self.bytesPerFrame();
    }
};

/// How many buffers are in flight at once.
///
/// One is not enough: the device would run dry between the moment it finishes a
/// buffer and the moment the title hands over the next, which is audible as a
/// click every buffer. Two keeps latency near one buffer (~5–10 ms at 256
/// frames) while still covering late submits; three was adding ~15–30 ms of
/// host-side delay on top of the title's own mix timing.
const queue_depth = 2;

/// The largest buffer that can be played, as channels x bytes x frames.
///
/// Fixed rather than allocated: this module is reached from firmware entry
/// points that have no allocator of their own, and a title picks its buffer size
/// once at startup. A title asking for more than this keeps the silent path
/// rather than being refused outright.
pub const maximum_buffer_bytes = 8 * 4 * 4096;

// ---------------------------------------------------------------------------
// Windows multimedia output.

const WAVEFORMATEX = extern struct {
    wFormatTag: u16,
    nChannels: u16,
    nSamplesPerSec: u32,
    nAvgBytesPerSec: u32,
    nBlockAlign: u16,
    wBitsPerSample: u16,
    cbSize: u16,
};

const WAVEHDR = extern struct {
    lpData: ?[*]u8,
    dwBufferLength: u32,
    dwBytesRecorded: u32 = 0,
    dwUser: usize = 0,
    dwFlags: u32 = 0,
    dwLoops: u32 = 0,
    lpNext: ?*WAVEHDR = null,
    reserved: usize = 0,
};

const format_pcm: u16 = 1;
const format_ieee_float: u16 = 3;
const wave_mapper: u32 = 0xffff_ffff;
const callback_null: u32 = 0;
const header_done: u32 = 0x0000_0001;
const mmsyserr_noerror: u32 = 0;

extern "winmm" fn waveOutOpen(
    out_handle: *?*anyopaque,
    device_id: u32,
    format: *const WAVEFORMATEX,
    callback: usize,
    instance: usize,
    flags: u32,
) callconv(.winapi) u32;
extern "winmm" fn waveOutPrepareHeader(handle: ?*anyopaque, header: *WAVEHDR, size: u32) callconv(.winapi) u32;
extern "winmm" fn waveOutUnprepareHeader(handle: ?*anyopaque, header: *WAVEHDR, size: u32) callconv(.winapi) u32;
extern "winmm" fn waveOutWrite(handle: ?*anyopaque, header: *WAVEHDR, size: u32) callconv(.winapi) u32;
extern "winmm" fn waveOutReset(handle: ?*anyopaque) callconv(.winapi) u32;
extern "winmm" fn waveOutClose(handle: ?*anyopaque) callconv(.winapi) u32;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

/// One open sound output.
///
/// A single instance, because a title opens one main output port and that is
/// what reaches the speakers. Ports beyond it keep the silent path rather than
/// competing for the device, which would interleave two unrelated streams.
/// The sample buffers the device plays from.
///
/// Module scope rather than inside `Device`: they are a third of a megabyte,
/// and there is one device, so carrying them in a value callers might place on
/// a stack buys nothing and risks a great deal.
var buffers: [queue_depth][maximum_buffer_bytes]u8 align(16) = undefined;

pub const Device = struct {
    handle: ?*anyopaque = null,
    config: Config = .{ .frequency = 0, .channels = 0, .format = .signed16, .frames = 0 },
    headers: [queue_depth]WAVEHDR = @splat(.{ .lpData = null, .dwBufferLength = 0 }),
    prepared: usize = 0,
    next: usize = 0,

    pub fn isOpen(self: *const Device) bool {
        return self.handle != null;
    }

    pub fn open(self: *Device, config: Config) Error!void {
        // Sizes are checked before the platform, so that a caller learns its
        // configuration is wrong on every host rather than only on the one that
        // has sound.
        if (config.bufferBytes() > maximum_buffer_bytes) return Error.BufferTooLarge;
        if (comptime !supported) return Error.Unsupported;
        if (config.frequency == 0 or config.channels == 0 or config.frames == 0) {
            return Error.DeviceUnavailable;
        }

        const block_align: u16 = @intCast(config.bytesPerFrame());
        const wave_format = WAVEFORMATEX{
            .wFormatTag = switch (config.format) {
                .signed16 => format_pcm,
                .float32 => format_ieee_float,
            },
            .nChannels = config.channels,
            .nSamplesPerSec = config.frequency,
            .nAvgBytesPerSec = config.frequency * block_align,
            .nBlockAlign = block_align,
            .wBitsPerSample = config.format.bytes() * 8,
            .cbSize = 0,
        };

        var handle: ?*anyopaque = null;
        if (waveOutOpen(&handle, wave_mapper, &wave_format, 0, 0, callback_null) != mmsyserr_noerror) {
            return Error.DeviceUnavailable;
        }
        errdefer _ = waveOutClose(handle);

        self.handle = handle;
        self.config = config;
        self.prepared = 0;
        self.next = 0;

        const length: u32 = @intCast(config.bufferBytes());
        for (&self.headers, 0..) |*header, index| {
            header.* = .{ .lpData = &buffers[index], .dwBufferLength = length };
            if (waveOutPrepareHeader(handle, header, @sizeOf(WAVEHDR)) != mmsyserr_noerror) {
                self.close();
                return Error.DeviceUnavailable;
            }
            self.prepared = index + 1;
            // Marked done so the first rounds find them free; nothing was
            // played, and a buffer that was never queued is free by definition.
            header.dwFlags |= header_done;
        }
        return;
    }

    /// Hands one buffer of samples to the device, waiting for room.
    ///
    /// The wait is the point: it is what paces the title. Returning early would
    /// let a title run ahead of the sound and pile up buffers until the delay
    /// between what it submits and what is heard became obvious.
    pub fn play(self: *Device, samples: []const u8) Error!void {
        if (samples.len > maximum_buffer_bytes) return Error.BufferTooLarge;
        const handle = self.handle orelse return Error.DeviceUnavailable;
        if (samples.len == 0) return;
        if (comptime !supported) return Error.Unsupported;

        const slot = self.next;
        const header = &self.headers[slot];

        // A buffer still playing is exactly the back-pressure wanted. Waiting a
        // fraction of a buffer keeps the check cheap without adding a delay of
        // its own.
        const slice = self.waitSliceMilliseconds();
        while (header.dwFlags & header_done == 0) Sleep(slice);

        // Into the buffer this header was prepared against. The pairing is
        // fixed at open: a prepared header is pinned to its buffer, and pointing
        // it somewhere else afterwards is not something the device permits.
        @memcpy(buffers[slot][0..samples.len], samples);
        header.dwBufferLength = @intCast(samples.len);
        header.dwFlags &= ~header_done;
        self.next = (slot + 1) % queue_depth;

        if (waveOutWrite(handle, header, @sizeOf(WAVEHDR)) != mmsyserr_noerror) {
            header.dwFlags |= header_done;
            return Error.DeviceUnavailable;
        }
    }

    /// A fraction of one buffer, and never zero.
    ///
    /// Zero would spin on the flag with nothing between checks, burning a core
    /// for the whole time a buffer plays.
    fn waitSliceMilliseconds(self: *const Device) u32 {
        if (self.config.frequency == 0) return 1;
        const buffer_ms = (@as(u64, self.config.frames) * std.time.ms_per_s) / self.config.frequency;
        return @intCast(@max(buffer_ms / 4, 1));
    }

    pub fn close(self: *Device) void {
        const handle = self.handle orelse return;
        if (comptime supported) {
            // Reset first: a header cannot be unprepared while the device still
            // holds it, and stopping playback is what releases them.
            _ = waveOutReset(handle);
            for (self.headers[0..self.prepared]) |*header| {
                _ = waveOutUnprepareHeader(handle, header, @sizeOf(WAVEHDR));
            }
            _ = waveOutClose(handle);
        }
        self.handle = null;
        self.prepared = 0;
        self.next = 0;
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a frame is as wide as its channels and sample size" {
    const stereo16 = Config{ .frequency = 48000, .channels = 2, .format = .signed16, .frames = 256 };
    try testing.expectEqual(@as(u32, 4), stereo16.bytesPerFrame());
    try testing.expectEqual(@as(u64, 1024), stereo16.bufferBytes());

    const surround32 = Config{ .frequency = 48000, .channels = 8, .format = .float32, .frames = 256 };
    try testing.expectEqual(@as(u32, 32), surround32.bytesPerFrame());
    try testing.expectEqual(@as(u64, 8192), surround32.bufferBytes());
}

test "a buffer larger than the reserve is declined, not truncated" {
    // Playing part of a buffer would be worse than playing none: the title
    // would hear its own sound cut short and have no way to know why.
    var device = Device{};
    const huge = Config{
        .frequency = 48000,
        .channels = 8,
        .format = .float32,
        .frames = maximum_buffer_bytes,
    };
    try testing.expect(huge.bufferBytes() > maximum_buffer_bytes);
    try testing.expectError(Error.BufferTooLarge, device.open(huge));
    try testing.expect(!device.isOpen());
}

test "a configuration that describes no sound is refused" {
    var device = Device{};
    const base = Config{ .frequency = 48000, .channels = 2, .format = .signed16, .frames = 256 };

    var no_rate = base;
    no_rate.frequency = 0;
    var no_channels = base;
    no_channels.channels = 0;
    var no_frames = base;
    no_frames.frames = 0;

    const expected = if (supported) Error.DeviceUnavailable else Error.Unsupported;
    try testing.expectError(expected, device.open(no_rate));
    try testing.expectError(expected, device.open(no_channels));
    try testing.expectError(expected, device.open(no_frames));
}

test "a device that was never opened plays nothing rather than crashing" {
    var device = Device{};
    try testing.expect(!device.isOpen());
    try testing.expectError(Error.DeviceUnavailable, device.play(&[_]u8{ 0, 0, 0, 0 }));
    // Closing one that was never opened is allowed, so callers need no state of
    // their own to decide whether to.
    device.close();
}

test "a real device takes as long to play as the sound lasts" {
    // The only automatic evidence that sound is leaving the machine: a device
    // that accepted the buffers and consumed them at the rate they describe.
    // Timing is the check because a title keeps its own clock this way — if
    // these returned immediately, a title would run as fast as it could submit.
    if (comptime !supported) return error.SkipZigTest;

    const frequency = 48000;
    const frames = 480; // 10 ms
    var device = Device{};
    device.open(.{
        .frequency = frequency,
        .channels = 2,
        .format = .signed16,
        .frames = frames,
    }) catch return error.SkipZigTest; // No sound hardware here.
    defer device.close();

    // A quiet tone rather than silence: a device asked for silence can look
    // like it is working while doing nothing at all.
    var tone: [frames * 2]i16 = undefined;
    for (0..frames) |index| {
        const phase = @as(f32, @floatFromInt(index)) * 440.0 * 2.0 * std.math.pi / frequency;
        const sample: i16 = @intFromFloat(@sin(phase) * 2000.0);
        tone[index * 2] = sample;
        tone[index * 2 + 1] = sample;
    }
    const pcm = std.mem.sliceAsBytes(tone[0..]);

    const buffer_count = 20; // 200 ms
    const started = GetTickCount64();
    for (0..buffer_count) |_| try device.play(pcm);
    const elapsed_ms = GetTickCount64() - started;

    // Wide bounds on purpose. What is being distinguished is "the device paced
    // this" from "the calls returned at once", not one clock from another.
    const expected_ms = buffer_count * 1000 / (frequency / frames);
    try testing.expect(elapsed_ms >= expected_ms / 2);
    try testing.expect(elapsed_ms <= expected_ms * 4);
}

test "the wait between checks is a fraction of a buffer and never zero" {
    var device = Device{};
    device.config = .{ .frequency = 48000, .channels = 2, .format = .signed16, .frames = 1920 };
    // One buffer lasts 40 ms here, so a check every 10 ms.
    try testing.expectEqual(@as(u32, 10), device.waitSliceMilliseconds());

    // A buffer shorter than the granularity must not produce a wait of zero,
    // which would spin on the flag and burn a core for the whole buffer.
    device.config = .{ .frequency = 48000, .channels = 2, .format = .signed16, .frames = 1 };
    try testing.expectEqual(@as(u32, 1), device.waitSliceMilliseconds());
    device.config = .{ .frequency = 0, .channels = 2, .format = .signed16, .frames = 0 };
    try testing.expectEqual(@as(u32, 1), device.waitSliceMilliseconds());
}
