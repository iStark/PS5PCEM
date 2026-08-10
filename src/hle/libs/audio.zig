// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest audio services and the host AudioOut backend.
//!
//! AudioOut and AudioIn preserve port lifetimes, validate the common ABI, and
//! pace producer/consumer calls without touching a host sound device. AudioOut2
//! does the same for its context/port queue model. AJM executes ATRAC9 and MP3
//! decode jobs through stateful host codec instances.

const std = @import("std");

/// Set to true to enable verbose per-frame audio debug logging.
const log_verbose_audio = false;
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_threading = @import("kernel_threading.zig");
const kernel_memory = @import("kernel_memory.zig");
const audio_device = @import("../audio_device.zig");
const audio_fs = @import("../audio_fs.zig");
const ajm_codec = @import("../ajm_codec.zig");
const filesystem = @import("../filesystem.zig");

const audio_out_error_invalid_port: i32 = @bitCast(@as(u32, 0x8026_0003));
const audio_out_error_invalid_pointer: i32 = @bitCast(@as(u32, 0x8026_0004));
const audio_out_error_port_full: i32 = @bitCast(@as(u32, 0x8026_0005));
const audio_out_error_invalid_size: i32 = @bitCast(@as(u32, 0x8026_0006));
const audio_out_error_invalid_format: i32 = @bitCast(@as(u32, 0x8026_0007));
const audio_out_error_invalid_frequency: i32 = @bitCast(@as(u32, 0x8026_0008));
const audio_out_error_invalid_port_type: i32 = @bitCast(@as(u32, 0x8026_000A));

const audio_in_error_invalid_handle: i32 = @bitCast(@as(u32, 0x8026_0101));
const audio_in_error_invalid_size: i32 = @bitCast(@as(u32, 0x8026_0102));
const audio_in_error_invalid_frequency: i32 = @bitCast(@as(u32, 0x8026_0103));
const audio_in_error_invalid_pointer: i32 = @bitCast(@as(u32, 0x8026_0105));
const audio_in_error_invalid_parameter: i32 = @bitCast(@as(u32, 0x8026_0106));
const audio_in_error_port_full: i32 = @bitCast(@as(u32, 0x8026_0107));

const audio_out2_error_invalid_parameter: i32 = @bitCast(@as(u32, 0x8026_8001));
const audio_out2_error_port_full: i32 = @bitCast(@as(u32, 0x8026_8012));

const ajm_error_invalid_context: i32 = @bitCast(@as(u32, 0x8093_0002));
const ajm_error_invalid_parameter: i32 = @bitCast(@as(u32, 0x8093_0005));
const ajm_error_codec_not_supported: i32 = @bitCast(@as(u32, 0x8093_0008));
const ajm_error_job_creation: i32 = @bitCast(@as(u32, 0x8093_0012));
const ajm_result_invalid_parameter: i32 = 0x0000_0004;

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

fn formatChannels(format: u32) ?u8 {
    return switch (format & 0xff) {
        0, 3 => 1,
        1, 4 => 2,
        2, 5, 6, 7 => 8,
        else => null,
    };
}

fn pace(frames: u32, frequency: u32) void {
    if (frames == 0 or frequency == 0) return;
    const duration = (@as(u64, frames) * std.time.us_per_s) / frequency;
    const microseconds: u32 = @intCast(@min(duration, std.math.maxInt(u32)));
    _ = kernel_threading.sceKernelUsleep(@max(microseconds, 1));
}

/// Whether a format carries integer or floating-point samples.
///
/// The low byte selects both channel count and representation, and the two are
/// not separable: the same number names a different layout depending on which
/// half of the table it falls in.
fn formatSamples(format: u32) ?audio_device.SampleFormat {
    return switch (format & 0xff) {
        0, 1, 2 => .signed16,
        3, 4, 5, 6, 7 => .float32,
        else => null,
    };
}

const PortKind = enum(u8) { none, output, input };
const LegacyPort = struct {
    kind: PortKind = .none,
    frames: u32 = 0,
    frequency: u32 = 0,
    channels: u8 = 0,
    samples: audio_device.SampleFormat = .signed16,
    /// Whether this port is the one reaching the speakers.
    audible: bool = false,
};

/// The single sound output, and the port that holds it.
///
/// One port is audible because there is one pair of speakers. A title opens a
/// main output port and, often, further ports for other purposes; letting each
/// claim the device would interleave unrelated streams into one another. The
/// rest keep the silent path, which is what they had before and costs a title
/// nothing.
var device: audio_device.Device = .{};
var device_owner: i32 = -1;

/// Tries to make a port audible, and says whether it worked.
///
/// Failure is not reported to the title. A title must not stall or behave
/// differently because the host has no sound card, denies access to it, or will
/// not take the format it asked for — those are facts about this machine, not
/// about the title.
fn claimDevice(handle: i32, port: LegacyPort) bool {
    if (device_owner != -1) return false;
    if (audioDisabled()) {
        std.debug.print("[audio] host output disabled by launcher\n", .{});
        return false;
    }
    // Warm FSB index + host mix before the first audible Output so silent
    // mixer buffers immediately carry real game PCM.
    filesystem.ensureAudioIndexed();
    device.open(.{
        .frequency = port.frequency,
        .channels = port.channels,
        .format = port.samples,
        .frames = port.frames,
    }) catch |err| {
        std.debug.print(
            "[audio] host device open failed handle={d} {d}Hz ch={d} fmt={s} frames={d}: {s}\n",
            .{ handle, port.frequency, port.channels, @tagName(port.samples), port.frames, @errorName(err) },
        );
        return false;
    };
    device_owner = handle;
    std.debug.print(
        "[audio] host device open ok handle={d} {d}Hz ch={d} fmt={s} frames={d}\n",
        .{ handle, port.frequency, port.channels, @tagName(port.samples), port.frames },
    );
    return true;
}

fn releaseDevice(handle: i32) void {
    if (device_owner != handle) return;
    device.close();
    device_owner = -1;
}

const maximum_legacy_ports = 64;
var port_mutex: Lock = .{};
var legacy_ports: [maximum_legacy_ports]LegacyPort = [_]LegacyPort{.{}} ** maximum_legacy_ports;

fn allocateLegacyPort(
    kind: PortKind,
    frames: u32,
    frequency: u32,
    channels: u8,
    samples: audio_device.SampleFormat,
) ?i32 {
    port_mutex.lock();
    defer port_mutex.unlock();
    for (&legacy_ports, 0..) |*port, index| {
        if (port.kind != .none) continue;
        port.* = .{
            .kind = kind,
            .frames = frames,
            .frequency = frequency,
            .channels = channels,
            .samples = samples,
        };
        const handle: i32 = @intCast(index + 1);
        if (kind == .output) port.audible = claimDevice(handle, port.*);
        return handle;
    }
    return null;
}

fn legacyPort(handle: i32, kind: PortKind) ?LegacyPort {
    if (handle <= 0 or handle > maximum_legacy_ports) return null;
    port_mutex.lock();
    defer port_mutex.unlock();
    const port = legacy_ports[@intCast(handle - 1)];
    return if (port.kind == kind) port else null;
}

fn releaseLegacyPort(handle: i32, kind: PortKind) bool {
    if (handle <= 0 or handle > maximum_legacy_ports) return false;
    port_mutex.lock();
    defer port_mutex.unlock();
    const port = &legacy_ports[@intCast(handle - 1)];
    if (port.kind != kind) return false;
    if (port.audible) releaseDevice(handle);
    port.* = .{};
    return true;
}

const AudioOutPortState = extern struct {
    output: u16 = 0,
    channel: u8 = 0,
    reserved1: u8 = 0,
    volume: i16 = 0,
    reroute_counter: u16 = 0,
    flag: u64 = 0,
    reserved2: [2]u64 = .{ 0, 0 },
};

fn audioOutInit() callconv(abi.guest) i32 {
    return errno.ok;
}

fn audioOutOpen(_: i32, port_type: i32, index: i32, frames: u32, frequency: u32, format: u32) callconv(abi.guest) i32 {
    if (port_type < 0 or (port_type > 4 and port_type != 10 and port_type != 127)) return audio_out_error_invalid_port_type;
    if (index != 0) return audio_out_error_invalid_port_type;
    if (frames == 0) return audio_out_error_invalid_size;
    if (frequency == 0) return audio_out_error_invalid_frequency;
    const channels = formatChannels(format) orelse return audio_out_error_invalid_format;
    const samples = formatSamples(format) orelse return audio_out_error_invalid_format;
    return allocateLegacyPort(.output, frames, frequency, channels, samples) orelse
        audio_out_error_port_full;
}

fn audioOutSetVolume(handle: i32, _: u32, volumes: ?[*]const i32) callconv(abi.guest) i32 {
    if (legacyPort(handle, .output) == null) return audio_out_error_invalid_port;
    if (volumes == null) return audio_out_error_invalid_pointer;
    return errno.ok;
}

fn audioOutSetMixLevelPadSpeaker(handle: i32, _: f32) callconv(abi.guest) i32 {
    return if (legacyPort(handle, .output) != null) errno.ok else audio_out_error_invalid_port;
}

/// Hands one buffer of samples over, and takes about as long as it will sound.
///
/// The wait is what a title keeps time with, so it happens either way: the
/// device provides it by making room for the next buffer, and where there is no
/// device it is a sleep, exactly as before. A title cannot tell which, and must
/// not be able to.
var audio_out_play_ok: std.atomic.Value(u64) = .init(0);
var audio_out_play_silent: std.atomic.Value(u64) = .init(0);
var audio_out_play_fail: std.atomic.Value(u64) = .init(0);
var audio_test_tone_phase: f32 = 0;
/// Set once from `PS5_AUDIO_TEST_TONE=1` — inject a quiet 440 Hz tone when the
/// title submits silent buffers so host speakers can be verified.
var audio_test_tone_enabled: ?bool = null;
var audio_disabled: ?bool = null;

extern "kernel32" fn GetEnvironmentVariableA(
    name: [*:0]const u8,
    buffer: ?[*]u8,
    size: u32,
) callconv(.winapi) u32;

fn audioTestToneEnabled() bool {
    if (audio_test_tone_enabled) |value| return value;
    var on = false;
    if (comptime builtin.os.tag == .windows) {
        var buf: [8]u8 = undefined;
        const n = GetEnvironmentVariableA("PS5_AUDIO_TEST_TONE", &buf, buf.len);
        if (n > 0 and n < buf.len) {
            on = buf[0] != '0' and buf[0] != 'n' and buf[0] != 'N';
        }
    }
    audio_test_tone_enabled = on;
    if (on) std.debug.print("[audio] PS5_AUDIO_TEST_TONE: inject 440 Hz on silent buffers\n", .{});
    return on;
}

fn audioDisabled() bool {
    if (audio_disabled) |value| return value;
    var disabled = false;
    if (comptime builtin.os.tag == .windows) {
        var buf: [8]u8 = undefined;
        const n = GetEnvironmentVariableA("PS5_AUDIO_DISABLED", &buf, buf.len);
        if (n > 0 and n < buf.len) disabled = buf[0] != '0' and buf[0] != 'n' and buf[0] != 'N';
    }
    audio_disabled = disabled;
    return disabled;
}

fn readF32Le(bytes: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, bytes, .little));
}

fn writeF32Le(bytes: *[4]u8, value: f32) void {
    std.mem.writeInt(u32, bytes, @bitCast(value), .little);
}

fn bufferPeak(port: LegacyPort, bytes: []const u8) u32 {
    var peak: u32 = 0;
    if (port.samples == .signed16) {
        var offset: usize = 0;
        while (offset + 2 <= bytes.len) : (offset += 2) {
            const s = std.mem.readInt(i16, bytes[offset..][0..2], .little);
            peak = @max(peak, @as(u32, @intCast(@abs(s))));
        }
    } else {
        var offset: usize = 0;
        while (offset + 4 <= bytes.len) : (offset += 4) {
            const s = readF32Le(bytes[offset..][0..4]);
            const a: f32 = if (s < 0) -s else s;
            peak = @max(peak, @as(u32, @intFromFloat(@min(a * 32768.0, 65535.0))));
        }
    }
    return peak;
}

/// Quiet 440 Hz tone used only when `PS5_AUDIO_TEST_TONE` is set and the title
/// buffer is effectively silent.
fn fillTestTone(port: LegacyPort, dest: []u8) void {
    const frames = port.frames;
    const ch = port.channels;
    const two_pi = 2.0 * std.math.pi;
    const step = two_pi * 440.0 / @as(f32, @floatFromInt(port.frequency));
    var frame: u32 = 0;
    var phase = audio_test_tone_phase;
    while (frame < frames) : (frame += 1) {
        const sample = @sin(phase) * 0.15;
        phase += step;
        if (phase > two_pi) phase -= two_pi;
        var c: u8 = 0;
        while (c < ch) : (c += 1) {
            if (port.samples == .signed16) {
                const i: i16 = @intFromFloat(sample * 8000.0);
                const off = (@as(usize, frame) * ch + c) * 2;
                if (off + 2 > dest.len) return;
                std.mem.writeInt(i16, dest[off..][0..2], i, .little);
            } else {
                const off = (@as(usize, frame) * ch + c) * 4;
                if (off + 4 > dest.len) return;
                writeF32Le(dest[off..][0..4], sample);
            }
        }
    }
    audio_test_tone_phase = phase;
}

fn audioOutOutput(handle: i32, data: ?*const anyopaque) callconv(abi.guest) i32 {
    const port = legacyPort(handle, .output) orelse return audio_out_error_invalid_port;
    const samples = data orelse return audio_out_error_invalid_pointer;

    if (port.audible) {
        const length = port.frames * @as(u32, port.channels) * port.samples.bytes();
        if (kernel_memory.isGuestRangeAccessible(@intFromPtr(samples), length)) {
            const bytes: [*]const u8 = @ptrCast(samples);
            var play_slice = bytes[0..length];
            // Optional host-side tone when the title is still feeding silence
            // (codec/assets not ready). Real non-zero content is never replaced.
            var tone_storage: [audio_device.maximum_buffer_bytes]u8 align(16) = undefined;
            if (audioTestToneEnabled() and length <= tone_storage.len) {
                const peak = bufferPeak(port, play_slice);
                if (peak < 8) {
                    @memcpy(tone_storage[0..length], play_slice);
                    fillTestTone(port, tone_storage[0..length]);
                    play_slice = tone_storage[0..length];
                }
            }
            // A device that stopped working mid-run falls back to pacing rather
            // than failing the call, because losing sound is not a reason to
            // stop a title.
            // When the title's mixer is still silent after first present, blend
            // in FSB-backed attract clips (not the full load-time library).
            var mixed_storage: [audio_device.maximum_buffer_bytes]u8 align(16) = undefined;
            var peak = bufferPeak(port, play_slice);
            if (peak < 8 and length <= mixed_storage.len) {
                if (audio_fs.isMixLive()) {
                    filesystem.ensureAudioMixAfterPresent();
                }
                if (audio_fs.isMixLive()) {
                    @memcpy(mixed_storage[0..length], play_slice);
                    const mixed = if (port.samples == .float32)
                        audio_fs.mixIntoFloat32Buffer(mixed_storage[0..length], port.channels)
                    else
                        audio_fs.mixIntoInt16Buffer(mixed_storage[0..length], port.channels);
                    if (mixed) {
                        play_slice = mixed_storage[0..length];
                        peak = bufferPeak(port, play_slice);
                    }
                }
            }
            if (device.play(play_slice)) |_| {
                const n = audio_out_play_ok.fetchAdd(1, .monotonic);
                if (n < 3 or n % 1000 == 0 or (peak > 8 and n < 20)) {
                    if (log_verbose_audio) std.debug.print(
                        "[audio] play ok #{d} handle={d} bytes={d} peak~{d}\n",
                        .{ n + 1, handle, length, peak },
                    );
                }
                return errno.ok;
            } else |err| {
                const n = audio_out_play_fail.fetchAdd(1, .monotonic);
                if (n < 5) {
                    std.debug.print("[audio] play failed #{d}: {s}\n", .{ n + 1, @errorName(err) });
                }
            }
        }
    } else {
        const n = audio_out_play_silent.fetchAdd(1, .monotonic);
        if (n == 0) {
            std.debug.print("[audio] output on silent port handle={d} (no host device)\n", .{handle});
        }
    }

    pace(port.frames, port.frequency);
    return errno.ok;
}

fn audioOutClose(handle: i32) callconv(abi.guest) i32 {
    return if (releaseLegacyPort(handle, .output)) errno.ok else audio_out_error_invalid_port;
}

fn audioOutGetPortState(handle: i32, state: ?*AudioOutPortState) callconv(abi.guest) i32 {
    const port = legacyPort(handle, .output) orelse return audio_out_error_invalid_port;
    const output = state orelse return audio_out_error_invalid_pointer;
    output.* = .{ .output = 1, .channel = port.channels };
    return errno.ok;
}

const audio_out_exports = [_]symbols.Export{
    .{ .name = "sceAudioOutInit", .function = trace.wrap("sceAudioOutInit", &audioOutInit), .expect_id = "JfEPXVxhFqA" },
    .{ .name = "sceAudioOutOpen", .function = trace.wrap("sceAudioOutOpen", &audioOutOpen), .expect_id = "ekNvsT22rsY" },
    .{ .name = "sceAudioOutSetVolume", .function = trace.wrap("sceAudioOutSetVolume", &audioOutSetVolume), .expect_id = "b+uAV89IlxE" },
    .{ .name = "sceAudioOutSetMixLevelPadSpk", .function = trace.wrap("sceAudioOutSetMixLevelPadSpk", &audioOutSetMixLevelPadSpeaker), .expect_id = "wVwPU50pS1c" },
    .{ .name = "sceAudioOutOutput", .function = trace.wrap("sceAudioOutOutput", &audioOutOutput), .expect_id = "QOQtbeDqsT4" },
    .{ .name = "sceAudioOutClose", .function = trace.wrap("sceAudioOutClose", &audioOutClose), .expect_id = "s1--uE9mBFw" },
    .{ .name = "sceAudioOutGetPortState", .function = trace.wrap("sceAudioOutGetPortState", &audioOutGetPortState), .expect_id = "GrQ9s4IrNaQ" },
};

fn audioInOpen(_: i32, _: u32, _: u32, frames: u32, frequency: u32, parameter: u32) callconv(abi.guest) i32 {
    if (frames == 0) return audio_in_error_invalid_size;
    if (frequency == 0) return audio_in_error_invalid_frequency;
    const channels: u8 = switch (parameter & 0xff) {
        0 => 1,
        1 => 2,
        else => return audio_in_error_invalid_parameter,
    };
    return allocateLegacyPort(.input, frames, frequency, channels, .signed16) orelse
        audio_in_error_port_full;
}

fn audioInInput(handle: i32, destination: ?[*]u8) callconv(abi.guest) i32 {
    const port = legacyPort(handle, .input) orelse return audio_in_error_invalid_handle;
    const output = destination orelse return audio_in_error_invalid_pointer;
    @memset(output[0 .. @as(usize, port.frames) * port.channels * @sizeOf(i16)], 0);
    pace(port.frames, port.frequency);
    return @intCast(port.frames);
}

fn audioInClose(handle: i32) callconv(abi.guest) i32 {
    return if (releaseLegacyPort(handle, .input)) errno.ok else audio_in_error_invalid_handle;
}

fn audioInGetSilentState(handle: i32) callconv(abi.guest) i32 {
    return if (legacyPort(handle, .input) != null) 1 else audio_in_error_invalid_handle;
}

const audio_in_exports = [_]symbols.Export{
    .{ .name = "sceAudioInOpen", .function = trace.wrap("sceAudioInOpen", &audioInOpen), .expect_id = "5NE8Sjc7VC8" },
    .{ .name = "sceAudioInInput", .function = trace.wrap("sceAudioInInput", &audioInInput), .expect_id = "LozEOU8+anM" },
    .{ .name = "sceAudioInClose", .function = trace.wrap("sceAudioInClose", &audioInClose), .expect_id = "Jh6WbHhnI68" },
    .{ .name = "sceAudioInGetSilentState", .function = trace.wrap("sceAudioInGetSilentState", &audioInGetSilentState), .expect_id = "BohEAQ7DlUE" },
};

// libSceAudioOut2 ----------------------------------------------------------

const AudioOut2ContextParam = extern struct {
    max_ports: u32 = 0,
    max_object_ports: u32 = 0,
    guarantee_object_ports: u32 = 0,
    queue_depth: u32 = 0,
    num_grains: u32 = 0,
    flags: u32 = 0,
    reserved: [10]u32 = [_]u32{0} ** 10,
};

const AudioOut2PortParam = extern struct {
    port_type: u16,
    padding: u16,
    data_format: u32,
    sampling_frequency: u32,
    flags: u32,
    user_handle: usize,
    reserved: [10]u32,
};

const AudioObjectKind = enum(u8) { none, context, port, user };
const AudioObject = struct {
    kind: AudioObjectKind = .none,
    parent: u64 = 0,
    queue_depth: u32 = 0,
    grains: u32 = 0,
};

const maximum_audio_objects = 512;
var audio_object_mutex: Lock = .{};
var audio_objects: [maximum_audio_objects]AudioObject = [_]AudioObject{.{}} ** maximum_audio_objects;

fn allocateAudioObject(kind: AudioObjectKind, parent: u64, queue_depth: u32, grains: u32) ?u64 {
    audio_object_mutex.lock();
    defer audio_object_mutex.unlock();
    for (&audio_objects, 0..) |*object, index| {
        if (object.kind != .none) continue;
        object.* = .{ .kind = kind, .parent = parent, .queue_depth = queue_depth, .grains = grains };
        return index + 1;
    }
    return null;
}

fn audioObject(handle: u64, kind: AudioObjectKind) ?AudioObject {
    if (handle == 0 or handle > maximum_audio_objects) return null;
    audio_object_mutex.lock();
    defer audio_object_mutex.unlock();
    const object = audio_objects[@intCast(handle - 1)];
    return if (object.kind == kind) object else null;
}

fn releaseAudioObject(handle: u64, kind: AudioObjectKind) bool {
    if (handle == 0 or handle > maximum_audio_objects) return false;
    audio_object_mutex.lock();
    defer audio_object_mutex.unlock();
    const object = &audio_objects[@intCast(handle - 1)];
    if (object.kind != kind) return false;
    object.* = .{};
    if (kind == .context) {
        for (&audio_objects) |*child| if (child.kind == .port and child.parent == handle) {
            child.* = .{};
        };
    }
    return true;
}

fn audioOut2Initialize() callconv(abi.guest) i32 {
    return errno.ok;
}

fn audioOut2ContextResetParam(parameters: ?*AudioOut2ContextParam) callconv(abi.guest) i32 {
    const output = parameters orelse return audio_out2_error_invalid_parameter;
    output.* = .{
        .max_ports = 256,
        .max_object_ports = 256,
        .queue_depth = 4,
        .num_grains = 512,
        .flags = 1,
    };
    return errno.ok;
}

fn audioOut2ContextQueryMemory(parameters: ?*const AudioOut2ContextParam, memory_size: ?*usize) callconv(abi.guest) i32 {
    const input = parameters orelse return audio_out2_error_invalid_parameter;
    const output = memory_size orelse return audio_out2_error_invalid_parameter;
    const depth = if (input.queue_depth == 0) 4 else input.queue_depth;
    output.* = 0x10000 + @as(usize, depth) * 0x590;
    return errno.ok;
}

fn audioOut2ContextCreate(parameters: ?*const AudioOut2ContextParam, _: ?*anyopaque, _: usize, context: ?*u64) callconv(abi.guest) i32 {
    const input = parameters orelse return audio_out2_error_invalid_parameter;
    const output = context orelse return audio_out2_error_invalid_parameter;
    const handle = allocateAudioObject(
        .context,
        0,
        if (input.queue_depth == 0) 4 else input.queue_depth,
        if (input.num_grains == 0) 512 else input.num_grains,
    ) orelse return audio_out2_error_port_full;
    output.* = handle;
    return errno.ok;
}

fn audioOut2ContextDestroy(context: u64) callconv(abi.guest) i32 {
    return if (releaseAudioObject(context, .context)) errno.ok else audio_out2_error_invalid_parameter;
}

fn audioOut2ContextAdvance(context: u64) callconv(abi.guest) i32 {
    return if (audioObject(context, .context) != null) errno.ok else audio_out2_error_invalid_parameter;
}

fn audioOut2ContextPush(context: u64, blocking: u32) callconv(abi.guest) i32 {
    const object = audioObject(context, .context) orelse return audio_out2_error_invalid_parameter;
    if (blocking != 0) pace(object.grains, 48_000);
    return errno.ok;
}

fn audioOut2ContextGetQueueLevel(context: u64, queue_level: ?*u32, available: ?*u32) callconv(abi.guest) i32 {
    const object = audioObject(context, .context) orelse return audio_out2_error_invalid_parameter;
    if (queue_level) |output| output.* = 0;
    if (available) |output| output.* = object.queue_depth;
    return errno.ok;
}

fn audioOut2PortCreate(context: u64, parameters: ?*const AudioOut2PortParam, port: ?*u64) callconv(abi.guest) i32 {
    if (audioObject(context, .context) == null or parameters == null or port == null) return audio_out2_error_invalid_parameter;
    const handle = allocateAudioObject(.port, context, 0, 0) orelse return audio_out2_error_port_full;
    port.?.* = handle;
    return errno.ok;
}

fn audioOut2PortDestroy(port: u64) callconv(abi.guest) i32 {
    return if (releaseAudioObject(port, .port)) errno.ok else audio_out2_error_invalid_parameter;
}

fn audioOut2PortSetAttributes(port: u64, attributes: ?*const anyopaque, count: u32) callconv(abi.guest) i32 {
    if (audioObject(port, .port) == null) return audio_out2_error_invalid_parameter;
    if (count != 0 and attributes == null) return audio_out2_error_invalid_parameter;
    return errno.ok;
}

fn audioOut2UserCreate(_: u32, user: ?*usize) callconv(abi.guest) i32 {
    const output = user orelse return audio_out2_error_invalid_parameter;
    output.* = allocateAudioObject(.user, 0, 0, 0) orelse return audio_out2_error_port_full;
    return errno.ok;
}

fn audioOut2UserDestroy(user: usize) callconv(abi.guest) i32 {
    return if (releaseAudioObject(user, .user)) errno.ok else audio_out2_error_invalid_parameter;
}

fn audioOut2GetSpeakerInfo(output: ?*[0x20]u8, _: u32) callconv(abi.guest) i32 {
    const info = output orelse return audio_out2_error_invalid_parameter;
    @memset(info, 0);
    std.mem.writeInt(u32, info[0x00..0x04], 2, .little); // stereo
    std.mem.writeInt(u32, info[0x04..0x08], 48_000, .little);
    std.mem.writeInt(u16, info[0x08..0x0a], 1, .little); // connected primary output
    return errno.ok;
}

const audio_out2_exports = [_]symbols.Export{
    .{ .name = "sceAudioOut2Initialize", .function = trace.wrap("sceAudioOut2Initialize", &audioOut2Initialize), .expect_id = "g2tViFIohHE" },
    .{ .name = "sceAudioOut2ContextResetParam", .function = trace.wrap("sceAudioOut2ContextResetParam", &audioOut2ContextResetParam), .expect_id = "t5YrizufpQc" },
    .{ .name = "sceAudioOut2ContextQueryMemory", .function = trace.wrap("sceAudioOut2ContextQueryMemory", &audioOut2ContextQueryMemory), .expect_id = "pDmme7Bgm6E" },
    .{ .name = "sceAudioOut2ContextCreate", .function = trace.wrap("sceAudioOut2ContextCreate", &audioOut2ContextCreate), .expect_id = "0x6o1VVAYSY" },
    .{ .name = "sceAudioOut2ContextDestroy", .function = trace.wrap("sceAudioOut2ContextDestroy", &audioOut2ContextDestroy), .expect_id = "on6ZH7Abo10" },
    .{ .name = "sceAudioOut2ContextAdvance", .function = trace.wrap("sceAudioOut2ContextAdvance", &audioOut2ContextAdvance), .expect_id = "PE2zHMqLSHs" },
    .{ .name = "sceAudioOut2ContextPush", .function = trace.wrap("sceAudioOut2ContextPush", &audioOut2ContextPush), .expect_id = "aII9h5nli9U" },
    .{ .name = "sceAudioOut2ContextGetQueueLevel", .function = trace.wrap("sceAudioOut2ContextGetQueueLevel", &audioOut2ContextGetQueueLevel), .expect_id = "R7d0F1g2qsU" },
    .{ .name = "sceAudioOut2PortCreate", .function = trace.wrap("sceAudioOut2PortCreate", &audioOut2PortCreate), .expect_id = "JK2wamZPzwM" },
    .{ .name = "sceAudioOut2PortDestroy", .function = trace.wrap("sceAudioOut2PortDestroy", &audioOut2PortDestroy), .expect_id = "cd+Rtw+D1x8" },
    .{ .name = "sceAudioOut2PortSetAttributes", .function = trace.wrap("sceAudioOut2PortSetAttributes", &audioOut2PortSetAttributes), .expect_id = "8XTArSPyWHk" },
    .{ .name = "sceAudioOut2UserCreate", .function = trace.wrap("sceAudioOut2UserCreate", &audioOut2UserCreate), .expect_id = "xywYcRB7nbQ" },
    .{ .name = "sceAudioOut2UserDestroy", .function = trace.wrap("sceAudioOut2UserDestroy", &audioOut2UserDestroy), .expect_id = "IaZXJ9M79uo" },
    .{ .name = "sceAudioOut2GetSpeakerInfo", .function = trace.wrap("sceAudioOut2GetSpeakerInfo", &audioOut2GetSpeakerInfo), .expect_id = "DImz2Ft9E2g" },
};

// libSceAjm ---------------------------------------------------------------

const AjmBatchInfo = extern struct {
    buffer: ?[*]u8 = null,
    offset: usize = 0,
    size: usize = 0,
    last_good_job: ?[*]u8 = null,
    last_good_job_return_address: ?*const anyopaque = null,
};

const AjmBatchError = extern struct {
    error_code: i32 = 0,
    padding1: u32 = 0,
    job_address: ?*const anyopaque = null,
    command_offset: u32 = 0,
    padding2: u32 = 0,
    job_return_address: ?*const anyopaque = null,
};

const AjmDecodeResult = extern struct {
    result: i32 = 0,
    internal_result: i32 = 0,
    size_consumed: i32 = 0,
    size_produced: i32 = 0,
    total_decoded_samples: u64 = 0,
    number_of_frames: u32 = 0,
    reserved: u32 = 0,
};

const AjmBuffer = extern struct {
    address: ?[*]u8 = null,
    size: usize = 0,
};

const AjmInstance = struct {
    active: bool = false,
    context: u32 = 0,
    codec: u32 = 0,
    flags: u64 = 0,
    id: u32 = 0,
    decoder: ajm_codec.Decoder = .{},
};

const maximum_ajm_contexts = 16;
const maximum_ajm_codecs = 64;
const maximum_ajm_instances = 64;
var ajm_mutex: Lock = .{};
var ajm_contexts: [maximum_ajm_contexts]bool = [_]bool{false} ** maximum_ajm_contexts;
var ajm_modules: [maximum_ajm_contexts][maximum_ajm_codecs]bool = [_][maximum_ajm_codecs]bool{[_]bool{false} ** maximum_ajm_codecs} ** maximum_ajm_contexts;
var ajm_instances: [maximum_ajm_instances]AjmInstance = [_]AjmInstance{.{}} ** maximum_ajm_instances;
var next_batch = std.atomic.Value(u32).init(1);
var ajm_decode_jobs = std.atomic.Value(u64).init(0);

fn ajmContextIndex(context: u32) ?usize {
    if (context == 0 or context > maximum_ajm_contexts) return null;
    return context - 1;
}

fn isAjmContext(context: u32) bool {
    const index = ajmContextIndex(context) orelse return false;
    ajm_mutex.lock();
    defer ajm_mutex.unlock();
    return ajm_contexts[index];
}

fn isAjmInstance(instance: u32) bool {
    ajm_mutex.lock();
    defer ajm_mutex.unlock();
    for (ajm_instances) |candidate| if (candidate.active and candidate.id == instance) return true;
    return false;
}

fn findAjmInstanceLocked(instance: u32) ?*AjmInstance {
    for (&ajm_instances) |*candidate| {
        if (candidate.active and candidate.id == instance) return candidate;
    }
    return null;
}

fn ajmInitialize(reserved: i64, context: ?*u32) callconv(abi.guest) i32 {
    if (reserved != 0) return ajm_error_invalid_parameter;
    const output = context orelse return ajm_error_invalid_parameter;
    ajm_mutex.lock();
    defer ajm_mutex.unlock();
    for (&ajm_contexts, 0..) |*active, index| {
        if (active.*) continue;
        active.* = true;
        output.* = @intCast(index + 1);
        return errno.ok;
    }
    return ajm_error_invalid_parameter;
}

fn ajmFinalize(context: u32) callconv(abi.guest) i32 {
    const index = ajmContextIndex(context) orelse return ajm_error_invalid_context;
    ajm_mutex.lock();
    defer ajm_mutex.unlock();
    if (!ajm_contexts[index]) return ajm_error_invalid_context;
    ajm_contexts[index] = false;
    ajm_modules[index] = [_]bool{false} ** maximum_ajm_codecs;
    for (&ajm_instances) |*instance| if (instance.active and instance.context == context) {
        instance.decoder.deinit();
        instance.* = .{};
    };
    return errno.ok;
}

fn ajmModuleRegister(context: u32, codec: u32, reserved: i64) callconv(abi.guest) i32 {
    if (reserved != 0) return ajm_error_invalid_parameter;
    const context_index = ajmContextIndex(context) orelse return ajm_error_invalid_context;
    if (codec != ajm_codec.codec_mp3 and codec != ajm_codec.codec_atrac9) return ajm_error_codec_not_supported;
    ajm_mutex.lock();
    defer ajm_mutex.unlock();
    if (!ajm_contexts[context_index]) return ajm_error_invalid_context;
    ajm_modules[context_index][codec] = true;
    return errno.ok;
}

fn ajmModuleUnregister(context: u32, codec: u32) callconv(abi.guest) i32 {
    const context_index = ajmContextIndex(context) orelse return ajm_error_invalid_context;
    if (codec >= maximum_ajm_codecs) return ajm_error_codec_not_supported;
    ajm_mutex.lock();
    defer ajm_mutex.unlock();
    if (!ajm_contexts[context_index]) return ajm_error_invalid_context;
    ajm_modules[context_index][codec] = false;
    return errno.ok;
}

fn ajmInstanceCreate(context: u32, codec: u32, flags: u64, instance: ?*u32) callconv(abi.guest) i32 {
    const output = instance orelse return ajm_error_invalid_parameter;
    const context_index = ajmContextIndex(context) orelse return ajm_error_invalid_context;
    if (codec != ajm_codec.codec_mp3 and codec != ajm_codec.codec_atrac9) return ajm_error_codec_not_supported;
    ajm_mutex.lock();
    defer ajm_mutex.unlock();
    if (!ajm_contexts[context_index]) return ajm_error_invalid_context;
    if (!ajm_modules[context_index][codec]) return ajm_error_codec_not_supported;
    var decoder = ajm_codec.Decoder.create(codec, flags) catch return ajm_error_codec_not_supported;
    for (&ajm_instances, 0..) |*candidate, index| {
        if (candidate.active) continue;
        const id = (codec << 14) | @as(u32, @intCast(index + 1));
        candidate.* = .{ .active = true, .context = context, .codec = codec, .flags = flags, .id = id, .decoder = decoder };
        output.* = id;
        std.debug.print(
            "[audio ajm] instance={d} codec={s} flags=0x{x} format={d} channels={d}\n",
            .{ id, if (codec == ajm_codec.codec_atrac9) "atrac9" else "mp3", flags, (flags >> 7) & 7, (flags >> 3) & 0xf },
        );
        return errno.ok;
    }
    decoder.deinit();
    return ajm_error_invalid_parameter;
}

fn ajmInstanceDestroy(context: u32, instance: u32) callconv(abi.guest) i32 {
    if (!isAjmContext(context)) return ajm_error_invalid_context;
    ajm_mutex.lock();
    defer ajm_mutex.unlock();
    for (&ajm_instances) |*candidate| {
        if (!candidate.active or candidate.id != instance or candidate.context != context) continue;
        candidate.decoder.deinit();
        candidate.* = .{};
        return errno.ok;
    }
    return ajm_error_invalid_parameter;
}

fn ajmBatchInitialize(buffer: ?[*]u8, size: usize, info: ?*AjmBatchInfo) callconv(abi.guest) i32 {
    if (buffer == null or size == 0 or info == null) return ajm_error_invalid_parameter;
    info.?.* = .{ .buffer = buffer, .size = size };
    return errno.ok;
}

fn appendAjmJob(info: ?*AjmBatchInfo, size: usize) i32 {
    const batch = info orelse return ajm_error_invalid_parameter;
    const buffer = batch.buffer orelse return ajm_error_invalid_parameter;
    if (batch.offset > batch.size or size > batch.size - batch.offset) return ajm_error_job_creation;
    const start = batch.offset;
    batch.offset += size;
    @memset(buffer[start..batch.offset], 0);
    batch.last_good_job = buffer + start;
    batch.last_good_job_return_address = null;
    return errno.ok;
}

fn ajmBatchStart(context: u32, info: ?*const AjmBatchInfo, _: i32, batch_error: ?*AjmBatchError, batch: ?*u32) callconv(abi.guest) i32 {
    if (!isAjmContext(context)) return ajm_error_invalid_context;
    if (info == null or batch == null) return ajm_error_invalid_parameter;
    if (batch_error) |output| output.* = .{};
    batch.?.* = next_batch.fetchAdd(1, .monotonic);
    return errno.ok;
}

fn ajmBatchWait(context: u32, _: u32, _: u32, batch_error: ?*AjmBatchError) callconv(abi.guest) i32 {
    if (!isAjmContext(context)) return ajm_error_invalid_context;
    if (batch_error) |output| output.* = .{};
    return errno.ok;
}

fn ajmBatchCancel(context: u32, _: u32) callconv(abi.guest) i32 {
    return if (isAjmContext(context)) errno.ok else ajm_error_invalid_context;
}

fn ajmBatchErrorDump(info: ?*const AjmBatchInfo, batch_error: ?*AjmBatchError) callconv(abi.guest) i32 {
    if (info == null) return ajm_error_invalid_parameter;
    if (batch_error) |output| output.* = .{};
    return errno.ok;
}

fn zeroAjmResult(result: ?[*]u8, size: usize, valid_instance: bool) void {
    const output = result orelse return;
    @memset(output[0..size], 0);
    if (!valid_instance and size >= @sizeOf(i32)) {
        const code: i32 = ajm_result_invalid_parameter;
        @memcpy(output[0..@sizeOf(i32)], std.mem.asBytes(&code));
    }
}

fn writeAjmBasicResult(result: ?[*]u8, code: i32, internal: i32) void {
    const output = result orelse return;
    @memcpy(output[0..4], std.mem.asBytes(&code));
    @memcpy(output[4..8], std.mem.asBytes(&internal));
}

fn ajmBatchJobInitialize(info: ?*AjmBatchInfo, instance: u32, parameters: ?*const anyopaque, parameter_size: usize, result: ?[*]u8) callconv(abi.guest) i32 {
    var decoded = ajm_codec.Report{ .result = ajm_result_invalid_parameter };
    ajm_mutex.lock();
    if (findAjmInstanceLocked(instance)) |candidate| {
        const input: []const u8 = if (parameters) |address|
            @as([*]const u8, @ptrCast(address))[0..@min(parameter_size, 4096)]
        else
            &.{};
        decoded = candidate.decoder.initialize(input);
        const codec_info = candidate.decoder.codecInfo();
        std.debug.print(
            "[audio ajm] initialized instance={d} result=0x{x} {d}Hz ch={d} frame={d} superframe={d}\n",
            .{ instance, @as(u32, @bitCast(decoded.result)), codec_info.sample_rate, codec_info.channels, codec_info.frame_samples, codec_info.superframe_size },
        );
    }
    ajm_mutex.unlock();
    writeAjmBasicResult(result, decoded.result, decoded.internal_result);
    return appendAjmJob(info, 48);
}

fn ajmBatchJobGetCodecInfo(info: ?*AjmBatchInfo, instance: u32, result: ?[*]u8, result_size: usize) callconv(abi.guest) i32 {
    const output_size = @min(result_size, 4096);
    if (result) |output| @memset(output[0..output_size], 0);
    var valid = false;
    ajm_mutex.lock();
    if (findAjmInstanceLocked(instance)) |candidate| {
        valid = true;
        const codec_info = candidate.decoder.codecInfo();
        if (result) |output| {
            if (candidate.codec == ajm_codec.codec_atrac9 and output_size >= 24) {
                std.mem.writeInt(u32, output[8..12], codec_info.superframe_size, .little);
                std.mem.writeInt(u32, output[12..16], codec_info.frames_in_superframe, .little);
                std.mem.writeInt(u32, output[16..20], codec_info.next_frame_size, .little);
                std.mem.writeInt(u32, output[20..24], codec_info.frame_samples, .little);
            } else if (candidate.codec == ajm_codec.codec_mp3 and output_size >= 24) {
                std.mem.writeInt(u32, output[8..12], codec_info.mp3_header, .little);
                const header = @byteSwap(codec_info.mp3_header);
                output[12] = @intFromBool(header & 0x0001_0000 == 0);
                output[13] = @truncate((header >> 6) & 3);
                output[14] = @truncate((header >> 4) & 3);
                output[15] = @truncate((header >> 3) & 1);
                output[16] = @truncate((header >> 2) & 1);
                output[17] = @truncate(header & 3);
            }
        }
    }
    ajm_mutex.unlock();
    if (result != null and output_size >= 8) writeAjmBasicResult(result, if (valid) 0 else ajm_result_invalid_parameter, 0);
    return appendAjmJob(info, 64);
}

fn ajmBatchJobSetGaplessDecode(info: ?*AjmBatchInfo, instance: u32, parameters: ?*const anyopaque, parameter_size: i32, result: ?[*]u8) callconv(abi.guest) i32 {
    _ = parameter_size;
    var code: i32 = ajm_result_invalid_parameter;
    ajm_mutex.lock();
    if (findAjmInstanceLocked(instance)) |candidate| {
        if (parameters != null) {
            const bytes = @as([*]const u8, @ptrCast(parameters.?))[0..8];
            candidate.decoder.setGapless(std.mem.readInt(u32, bytes[0..4], .little), std.mem.readInt(u16, bytes[4..6], .little));
            code = 0;
        }
    }
    ajm_mutex.unlock();
    writeAjmBasicResult(result, code, 0);
    return appendAjmJob(info, 48);
}

fn setAjmDecodeResult(result: ?*AjmDecodeResult, decoded: ajm_codec.Report) void {
    const output = result orelse return;
    output.* = .{
        .result = decoded.result,
        .internal_result = decoded.internal_result,
        .size_consumed = std.math.cast(i32, decoded.consumed) orelse std.math.maxInt(i32),
        .size_produced = std.math.cast(i32, decoded.produced) orelse std.math.maxInt(i32),
        .total_decoded_samples = decoded.total_samples,
        .number_of_frames = decoded.frames,
    };
}

fn ajmBatchJobDecode(
    info: ?*AjmBatchInfo,
    instance: u32,
    input: ?*const anyopaque,
    input_size: usize,
    pcm: ?[*]u8,
    pcm_size: usize,
    result: ?*AjmDecodeResult,
) callconv(abi.guest) i32 {
    const bounded_input_size = @min(input_size, 64 * 1024 * 1024);
    const bounded_pcm_size = @min(pcm_size, 64 * 1024 * 1024);
    if (pcm) |output| @memset(output[0..bounded_pcm_size], 0);
    var decoded = ajm_codec.Report{ .result = ajm_result_invalid_parameter };
    if ((input != null or bounded_input_size == 0) and (pcm != null or bounded_pcm_size == 0)) {
        const input_bytes: []const u8 = if (input) |address| @as([*]const u8, @ptrCast(address))[0..bounded_input_size] else &.{};
        const output_bytes: []u8 = if (pcm) |address| address[0..bounded_pcm_size] else &.{};
        ajm_mutex.lock();
        if (findAjmInstanceLocked(instance)) |candidate| decoded = candidate.decoder.decode(input_bytes, output_bytes);
        ajm_mutex.unlock();
    }
    setAjmDecodeResult(result, decoded);
    const job_number = ajm_decode_jobs.fetchAdd(1, .monotonic) + 1;
    if (job_number <= 6 or (decoded.result != 0 and std.math.isPowerOfTwo(job_number))) {
        std.debug.print(
            "[audio ajm] decode #{d} instance={d} in={d}/{d} pcm={d}/{d} frames={d} result=0x{x}\n",
            .{ job_number, instance, decoded.consumed, bounded_input_size, decoded.produced, bounded_pcm_size, decoded.frames, @as(u32, @bitCast(decoded.result)) },
        );
    }
    return appendAjmJob(info, 64);
}

fn ajmBatchJobDecodeSplit(
    info: ?*AjmBatchInfo,
    instance: u32,
    input_buffers: ?[*]const AjmBuffer,
    input_count: usize,
    output_buffers: ?[*]const AjmBuffer,
    output_count: usize,
    result: ?*AjmDecodeResult,
) callconv(abi.guest) i32 {
    const maximum_buffers: usize = 4096;
    const maximum_bytes: usize = 64 * 1024 * 1024;
    const safe_input_count = @min(input_count, maximum_buffers);
    const safe_output_count = @min(output_count, maximum_buffers);
    var input_bytes: usize = 0;
    var output_bytes: usize = 0;
    var buffers_valid = input_count == safe_input_count and output_count == safe_output_count;
    if (safe_input_count != 0 and input_buffers == null) buffers_valid = false;
    if (safe_output_count != 0 and output_buffers == null) buffers_valid = false;
    if (input_buffers) |buffers| for (buffers[0..safe_input_count]) |buffer| {
        if (buffer.size != 0 and buffer.address == null) buffers_valid = false;
        input_bytes = std.math.add(usize, input_bytes, buffer.size) catch {
            buffers_valid = false;
            break;
        };
        if (input_bytes > maximum_bytes) buffers_valid = false;
    };
    if (output_buffers) |buffers| for (buffers[0..safe_output_count]) |buffer| {
        if (buffer.size != 0 and buffer.address == null) buffers_valid = false;
        output_bytes = std.math.add(usize, output_bytes, buffer.size) catch {
            buffers_valid = false;
            break;
        };
        if (output_bytes > maximum_bytes) buffers_valid = false;
        if (buffer.address) |address| @memset(address[0..@min(buffer.size, maximum_bytes)], 0);
    };

    var decoded = ajm_codec.Report{ .result = ajm_result_invalid_parameter };
    if (buffers_valid) decode: {
        const joined_input = std.heap.page_allocator.alloc(u8, input_bytes) catch break :decode;
        defer std.heap.page_allocator.free(joined_input);
        const joined_output = std.heap.page_allocator.alloc(u8, output_bytes) catch break :decode;
        defer std.heap.page_allocator.free(joined_output);
        @memset(joined_output, 0);
        var offset: usize = 0;
        if (input_buffers) |buffers| for (buffers[0..safe_input_count]) |buffer| {
            if (buffer.address) |address| @memcpy(joined_input[offset..][0..buffer.size], address[0..buffer.size]);
            offset += buffer.size;
        };
        ajm_mutex.lock();
        if (findAjmInstanceLocked(instance)) |candidate| decoded = candidate.decoder.decode(joined_input, joined_output);
        ajm_mutex.unlock();

        offset = 0;
        if (output_buffers) |buffers| for (buffers[0..safe_output_count]) |buffer| {
            const copied = @min(buffer.size, decoded.produced -| offset);
            if (buffer.address) |address| @memcpy(address[0..copied], joined_output[offset..][0..copied]);
            offset += copied;
        };
    }
    setAjmDecodeResult(result, decoded);
    const buffer_count = std.math.add(usize, input_count, output_count) catch return ajm_error_job_creation;
    const buffer_bytes = std.math.mul(usize, buffer_count, 16) catch return ajm_error_job_creation;
    const job_size = std.math.add(usize, buffer_bytes, 32) catch return ajm_error_job_creation;
    return appendAjmJob(info, job_size);
}

fn ajmBatchJobSetResampleParametersEx(
    info: ?*AjmBatchInfo,
    instance: u32,
    _: f32,
    _: f32,
    _: u32,
    result: ?[*]u8,
) callconv(abi.guest) i32 {
    writeAjmBasicResult(result, if (isAjmInstance(instance)) ajm_codec.result_unsupported_flag else ajm_result_invalid_parameter, 0);
    return appendAjmJob(info, 72);
}

fn ajmBatchJobGetResampleInfo(info: ?*AjmBatchInfo, instance: u32, result: ?[*]u8) callconv(abi.guest) i32 {
    zeroAjmResult(result, 48, isAjmInstance(instance));
    if (result) |output| {
        var unity: f32 = 1.0;
        @memcpy(output[8..12], std.mem.asBytes(&unity));
    }
    return appendAjmJob(info, 64);
}

fn ajmBatchJobGetStatistics(info: ?*AjmBatchInfo, _: f32, result: ?[*]u8) callconv(abi.guest) i32 {
    if (result) |output| @memset(output[0..48], 0);
    return appendAjmJob(info, 88);
}

const ajm_exports = [_]symbols.Export{
    .{ .name = "sceAjmInitialize", .function = trace.wrap("sceAjmInitialize", &ajmInitialize), .expect_id = "dl+4eHSzUu4" },
    .{ .name = "sceAjmFinalize", .function = trace.wrap("sceAjmFinalize", &ajmFinalize), .expect_id = "MHur6qCsUus" },
    .{ .name = "sceAjmModuleRegister", .function = trace.wrap("sceAjmModuleRegister", &ajmModuleRegister), .expect_id = "Q3dyFuwGn64" },
    .{ .name = "sceAjmModuleUnregister", .function = trace.wrap("sceAjmModuleUnregister", &ajmModuleUnregister), .expect_id = "Wi7DtlLV+KI" },
    .{ .name = "sceAjmInstanceCreate", .function = trace.wrap("sceAjmInstanceCreate", &ajmInstanceCreate), .expect_id = "AxoDrINp4J8" },
    .{ .name = "sceAjmInstanceDestroy", .function = trace.wrap("sceAjmInstanceDestroy", &ajmInstanceDestroy), .expect_id = "RbLbuKv8zho" },
    .{ .name = "sceAjmBatchInitialize", .function = trace.wrap("sceAjmBatchInitialize", &ajmBatchInitialize), .expect_id = "MmpF1XsQiHw" },
    .{ .name = "sceAjmBatchStart", .function = trace.wrap("sceAjmBatchStart", &ajmBatchStart), .expect_id = "5tOfnaClcqM" },
    .{ .name = "sceAjmBatchWait", .function = trace.wrap("sceAjmBatchWait", &ajmBatchWait), .expect_id = "-qLsfDAywIY" },
    .{ .name = "sceAjmBatchCancel", .function = trace.wrap("sceAjmBatchCancel", &ajmBatchCancel), .expect_id = "NVDXiUesSbA" },
    .{ .name = "sceAjmBatchErrorDump", .function = trace.wrap("sceAjmBatchErrorDump", &ajmBatchErrorDump), .expect_id = "WfAiBW8Wcek" },
    .{ .name = "sceAjmBatchJobInitialize", .function = trace.wrap("sceAjmBatchJobInitialize", &ajmBatchJobInitialize), .expect_id = "ezM2OhNxzck" },
    .{ .name = "sceAjmBatchJobGetCodecInfo", .function = trace.wrap("sceAjmBatchJobGetCodecInfo", &ajmBatchJobGetCodecInfo), .expect_id = "uSrXaxT+oPQ" },
    .{ .name = "sceAjmBatchJobSetGaplessDecode", .function = trace.wrap("sceAjmBatchJobSetGaplessDecode", &ajmBatchJobSetGaplessDecode), .expect_id = "SkEwpiu3tZg" },
    .{ .name = "sceAjmBatchJobDecode", .function = trace.wrap("sceAjmBatchJobDecode", &ajmBatchJobDecode), .expect_id = "39WxhR-ePew" },
    .{ .name = "sceAjmBatchJobDecodeSplit", .function = trace.wrap("sceAjmBatchJobDecodeSplit", &ajmBatchJobDecodeSplit), .expect_id = "SJ3i0DXP8vg" },
    .{ .name = "sceAjmBatchJobSetResampleParametersEx", .function = trace.wrap("sceAjmBatchJobSetResampleParametersEx", &ajmBatchJobSetResampleParametersEx), .expect_id = "5ldnD16rYZw" },
    .{ .name = "sceAjmBatchJobGetResampleInfo", .function = trace.wrap("sceAjmBatchJobGetResampleInfo", &ajmBatchJobGetResampleInfo), .expect_id = "JkdNCocpu1M" },
    .{ .name = "sceAjmBatchJobGetStatistics", .function = trace.wrap("sceAjmBatchJobGetStatistics", &ajmBatchJobGetStatistics), .expect_id = "3cAg7xN995U" },
};

pub fn reset() void {
    // Runtime teardown can happen without the title closing its port. Release
    // WinMM before forgetting port ownership so a later runtime in this process
    // can claim the device cleanly.
    device.close();
    device_owner = -1;

    port_mutex.lock();
    legacy_ports = [_]LegacyPort{.{}} ** maximum_legacy_ports;
    port_mutex.unlock();

    audio_object_mutex.lock();
    audio_objects = [_]AudioObject{.{}} ** maximum_audio_objects;
    audio_object_mutex.unlock();

    ajm_mutex.lock();
    for (&ajm_instances) |*instance| if (instance.active) instance.decoder.deinit();
    ajm_contexts = [_]bool{false} ** maximum_ajm_contexts;
    ajm_modules = [_][maximum_ajm_codecs]bool{[_]bool{false} ** maximum_ajm_codecs} ** maximum_ajm_contexts;
    ajm_instances = [_]AjmInstance{.{}} ** maximum_ajm_instances;
    ajm_mutex.unlock();
    next_batch.store(1, .monotonic);
    ajm_decode_jobs.store(0, .monotonic);
    audio_out_play_ok.store(0, .monotonic);
    audio_out_play_silent.store(0, .monotonic);
    audio_out_play_fail.store(0, .monotonic);
    audio_test_tone_phase = 0;
    audio_test_tone_enabled = null;
    audio_disabled = null;
}

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libSceAudioOut", .version = 1 }, .{ .name = "libSceAudioOut" }, &audio_out_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAudioIn", .version = 1 }, .{ .name = "libSceAudioIn" }, &audio_in_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAudioOut2", .version = 1 }, .{ .name = "libSceAudioOut" }, &audio_out2_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAjm", .version = 1 }, .{ .name = "libSceAjm" }, &ajm_exports);
}

test "headless AudioOut preserves port lifecycle" {
    reset();
    const handle = audioOutOpen(1, 0, 0, 256, 48_000, 1);
    try std.testing.expect(handle > 0);
    var samples: [512]i16 = [_]i16{1} ** 512;
    try std.testing.expectEqual(errno.ok, audioOutOutput(handle, &samples));
    var state = AudioOutPortState{};
    try std.testing.expectEqual(errno.ok, audioOutGetPortState(handle, &state));
    try std.testing.expectEqual(@as(u8, 2), state.channel);
    try std.testing.expectEqual(errno.ok, audioOutClose(handle));
    try std.testing.expectEqual(audio_out_error_invalid_port, audioOutClose(handle));
}

test "AudioOut2 context defaults and handles are deterministic" {
    reset();
    var parameters = AudioOut2ContextParam{};
    try std.testing.expectEqual(errno.ok, audioOut2ContextResetParam(&parameters));
    try std.testing.expectEqual(@as(u32, 4), parameters.queue_depth);
    var size: usize = 0;
    try std.testing.expectEqual(errno.ok, audioOut2ContextQueryMemory(&parameters, &size));
    try std.testing.expect(size > 0x10000);
    var context: u64 = 0;
    try std.testing.expectEqual(errno.ok, audioOut2ContextCreate(&parameters, null, size, &context));
    var available: u32 = 0;
    try std.testing.expectEqual(errno.ok, audioOut2ContextGetQueueLevel(context, null, &available));
    try std.testing.expectEqual(@as(u32, 4), available);
}

test "AJM executes an MP3 decode job and reports actual PCM" {
    reset();
    var context: u32 = 0;
    try std.testing.expectEqual(errno.ok, ajmInitialize(0, &context));
    try std.testing.expectEqual(errno.ok, ajmModuleRegister(context, 0, 0));
    var instance: u32 = 0;
    try std.testing.expectEqual(errno.ok, ajmInstanceCreate(context, 0, 1, &instance));
    var storage: [256]u8 = undefined;
    var info = AjmBatchInfo{};
    try std.testing.expectEqual(errno.ok, ajmBatchInitialize(&storage, storage.len, &info));
    var frame: [417]u8 = @splat(0);
    frame[0..4].* = .{ 0xff, 0xfb, 0x90, 0x64 };
    var pcm: [4608]u8 = undefined;
    var result = AjmDecodeResult{};
    try std.testing.expectEqual(errno.ok, ajmBatchJobDecode(&info, instance, &frame, frame.len, &pcm, pcm.len, &result));
    try std.testing.expectEqual(@as(i32, 0), result.result);
    try std.testing.expectEqual(@as(i32, frame.len), result.size_consumed);
    try std.testing.expect(result.size_produced > 0);
    try std.testing.expectEqual(@as(u32, 1), result.number_of_frames);
    var codec_info: [24]u8 = undefined;
    try std.testing.expectEqual(errno.ok, ajmBatchJobGetCodecInfo(&info, instance, &codec_info, codec_info.len));
    try std.testing.expectEqualSlices(u8, frame[0..4], codec_info[8..12]);
    try std.testing.expectEqual(@as(u8, 0), codec_info[12]);
    try std.testing.expectEqual(@as(u8, 1), codec_info[13]);
}

test "AJM split decode joins input and scatters actual output" {
    reset();
    var context: u32 = 0;
    try std.testing.expectEqual(errno.ok, ajmInitialize(0, &context));
    try std.testing.expectEqual(errno.ok, ajmModuleRegister(context, ajm_codec.codec_mp3, 0));
    var instance: u32 = 0;
    try std.testing.expectEqual(errno.ok, ajmInstanceCreate(context, ajm_codec.codec_mp3, 1, &instance));

    var storage: [256]u8 = undefined;
    var info = AjmBatchInfo{};
    try std.testing.expectEqual(errno.ok, ajmBatchInitialize(&storage, storage.len, &info));
    var frame: [417]u8 = @splat(0);
    frame[0..4].* = .{ 0xff, 0xfb, 0x90, 0x64 };
    const inputs = [_]AjmBuffer{
        .{ .address = frame[0..2].ptr, .size = 2 },
        .{ .address = frame[2..].ptr, .size = frame.len - 2 },
    };
    var first: [1024]u8 = undefined;
    var second: [3584]u8 = undefined;
    const outputs = [_]AjmBuffer{
        .{ .address = &first, .size = first.len },
        .{ .address = &second, .size = second.len },
    };
    var result = AjmDecodeResult{};
    try std.testing.expectEqual(
        errno.ok,
        ajmBatchJobDecodeSplit(&info, instance, &inputs, inputs.len, &outputs, outputs.len, &result),
    );
    try std.testing.expectEqual(@as(i32, 0), result.result);
    try std.testing.expectEqual(@as(i32, frame.len), result.size_consumed);
    try std.testing.expectEqual(@as(i32, first.len + second.len), result.size_produced);
    try std.testing.expectEqual(@as(u32, 1), result.number_of_frames);
}

test "audio libraries register the title import surface" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("QOQtbeDqsT4", .function) != null);
    try std.testing.expect(db.findById("aII9h5nli9U", .function) != null);
    try std.testing.expect(db.findById("39WxhR-ePew", .function) != null);
}
