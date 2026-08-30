// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest audio services and the host AudioOut backend.
//!
//! AudioOut and AudioIn preserve port lifetimes, validate the common ABI, and
//! pace producer/consumer calls without touching a host sound device. AudioOut2
//! does the same for its context/port queue model and reports a connected
//! primary port from `sceAudioOut2PortGetState`. AJM executes ATRAC9 and MP3
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

pub const default_host_target_latency_ms = audio_device.default_target_latency_ms;

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
const ngs2_error_invalid_output: i32 = @bitCast(@as(u32, 0x804a_0053));

const audiodec_error_invalid_type: i32 = @bitCast(@as(u32, 0x807f_0001));
const audiodec_error_argument: i32 = @bitCast(@as(u32, 0x807f_0002));
const audiodec_error_invalid_param_size: i32 = @bitCast(@as(u32, 0x807f_0004));
const audiodec_error_invalid_bsi_info_size: i32 = @bitCast(@as(u32, 0x807f_0005));
const audiodec_error_invalid_au_info_size: i32 = @bitCast(@as(u32, 0x807f_0006));
const audiodec_error_invalid_pcm_item_size: i32 = @bitCast(@as(u32, 0x807f_0007));
const audiodec_error_invalid_ctrl_pointer: i32 = @bitCast(@as(u32, 0x807f_0008));
const audiodec_error_invalid_param_pointer: i32 = @bitCast(@as(u32, 0x807f_0009));
const audiodec_error_invalid_bsi_info_pointer: i32 = @bitCast(@as(u32, 0x807f_000a));
const audiodec_error_invalid_au_info_pointer: i32 = @bitCast(@as(u32, 0x807f_000b));
const audiodec_error_invalid_pcm_item_pointer: i32 = @bitCast(@as(u32, 0x807f_000c));
const audiodec_error_invalid_au_pointer: i32 = @bitCast(@as(u32, 0x807f_000d));
const audiodec_error_invalid_pcm_pointer: i32 = @bitCast(@as(u32, 0x807f_000e));
const audiodec_error_invalid_handle: i32 = @bitCast(@as(u32, 0x807f_000f));
const audiodec_error_invalid_word_length: i32 = @bitCast(@as(u32, 0x807f_0010));
const audiodec_error_invalid_au_size: i32 = @bitCast(@as(u32, 0x807f_0011));
const audiodec_error_invalid_pcm_size: i32 = @bitCast(@as(u32, 0x807f_0012));

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
        0, 1, 2, 6 => .signed16,
        3, 4, 5, 7 => .float32,
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
};

/// The single sound output, and the port that holds it.
///
/// One port is audible because there is one pair of speakers. A title opens a
/// main output port and, often, further ports for other purposes; letting each
/// claim the device would interleave unrelated streams into one another. The
/// rest keep the silent path, which is what they had before and costs a title
/// nothing.
var device: audio_device.Device = .{};
var device_owner = std.atomic.Value(i32).init(-1);
var device_owner_last_signal_ms = std.atomic.Value(u64).init(0);
var device_mutex: std.Io.Mutex = .init;
var host_target_latency_ms = std.atomic.Value(u16).init(audio_device.default_target_latency_ms);

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn audioClockMilliseconds() u64 {
    return if (comptime builtin.os.tag == .windows) GetTickCount64() else 0;
}

/// Selects the host jitter reserve before a title opens its primary port.
/// A per-title profile can tolerate measured mixer gaps without imposing that
/// latency on every other game.
pub fn setHostTargetLatencyMilliseconds(milliseconds: u16) void {
    host_target_latency_ms.store(@max(milliseconds, 1), .release);
}

fn lockDevice() ?std.Io {
    const io = filesystem.attachedIo() orelse return null;
    device_mutex.lockUncancelable(io);
    return io;
}

fn unlockDevice(io: std.Io) void {
    device_mutex.unlock(io);
}

/// Tries to make a port audible, and says whether it worked.
///
/// Failure is not reported to the title. A title must not stall or behave
/// differently because the host has no sound card, denies access to it, or will
/// not take the format it asked for — those are facts about this machine, not
/// about the title.
fn claimDevice(handle: i32, port: LegacyPort) bool {
    const io = lockDevice() orelse return false;
    defer unlockDevice(io);
    if (device_owner.load(.acquire) != -1) return false;
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
        .target_latency_ms = host_target_latency_ms.load(.acquire),
    }) catch |err| {
        std.debug.print(
            "[audio] host device open failed handle={d} {d}Hz ch={d} fmt={s} frames={d}: {s}\n",
            .{ handle, port.frequency, port.channels, @tagName(port.samples), port.frames, @errorName(err) },
        );
        return false;
    };
    device_owner.store(handle, .release);
    device_owner_last_signal_ms.store(audioClockMilliseconds(), .release);
    std.debug.print(
        "[audio] host device open ok handle={d} {d}Hz ch={d} fmt={s} frames={d} queue={d}\n",
        .{ handle, port.frequency, port.channels, @tagName(port.samples), port.frames, device.queueCapacity() },
    );
    return true;
}

fn releaseDevice(handle: i32) void {
    const io = lockDevice() orelse return;
    defer unlockDevice(io);
    if (device_owner.load(.acquire) != handle) return;
    device.close();
    device_owner.store(-1, .release);
    device_owner_last_signal_ms.store(0, .release);
}

/// Moves the one host device to the guest port that currently carries the
/// title's real mix. Music/video helpers can leave their first-opened port
/// alive after they stop submitting PCM; without reassignment every later NGS2
/// buffer is valid but discarded as a "secondary" port.
fn routeDevice(handle: i32, port: LegacyPort) bool {
    const io = lockDevice() orelse return false;
    defer unlockDevice(io);
    const previous = device_owner.load(.acquire);
    if (previous == handle) return true;
    if (audioDisabled()) return false;
    if (previous != -1) device.close();
    device_owner.store(-1, .release);
    device.open(.{
        .frequency = port.frequency,
        .channels = port.channels,
        .format = port.samples,
        .frames = port.frames,
        .target_latency_ms = host_target_latency_ms.load(.acquire),
    }) catch |err| {
        std.debug.print(
            "[audio] host route {d}->{d} failed {d}Hz ch={d} fmt={s}: {s}\n",
            .{ previous, handle, port.frequency, port.channels, @tagName(port.samples), @errorName(err) },
        );
        return false;
    };
    device_owner.store(handle, .release);
    device_owner_last_signal_ms.store(audioClockMilliseconds(), .release);
    std.debug.print(
        "[audio] host route {d}->{d} {d}Hz ch={d} fmt={s}\n",
        .{ previous, handle, port.frequency, port.channels, @tagName(port.samples) },
    );
    return true;
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
        if (kind == .output) _ = claimDevice(handle, port.*);
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
    releaseDevice(handle);
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

const audio_route_stale_ms: u64 = 100;

fn audioOutOutputImpl(handle: i32, data: ?*const anyopaque, fallback_pacing: bool, force_route: bool) i32 {
    const port = legacyPort(handle, .output) orelse return audio_out_error_invalid_port;
    // A null buffer is a legal drain/pacing request (and is used by JnG2 when
    // stopping its BGM output thread), not an invalid guest pointer.
    const samples = data orelse {
        if (fallback_pacing) pace(port.frames, port.frequency);
        return errno.ok;
    };

    const length = port.frames * @as(u32, port.channels) * port.samples.bytes();
    if (kernel_memory.isGuestRangeAccessible(@intFromPtr(samples), length)) {
        const bytes: [*]const u8 = @ptrCast(samples);
        var play_slice = bytes[0..length];
        const source_peak = bufferPeak(port, play_slice);
        const now = audioClockMilliseconds();
        const owner = device_owner.load(.acquire);
        const last_signal = device_owner_last_signal_ms.load(.acquire);
        if (force_route or owner == -1 or
            (owner != handle and source_peak >= 8 and now -| last_signal >= audio_route_stale_ms))
        {
            _ = routeDevice(handle, port);
        }

        if (device_owner.load(.acquire) == handle) {
            // Optional host-side tone when the title is still feeding silence
            // (codec/assets not ready). Real non-zero content is never replaced.
            var tone_storage: [audio_device.maximum_buffer_bytes]u8 align(16) = undefined;
            if (audioTestToneEnabled() and length <= tone_storage.len and source_peak < 8) {
                @memcpy(tone_storage[0..length], play_slice);
                fillTestTone(port, tone_storage[0..length]);
                play_slice = tone_storage[0..length];
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
            const io = lockDevice() orelse {
                if (fallback_pacing) pace(port.frames, port.frequency);
                return errno.ok;
            };
            const play_result = if (device_owner.load(.acquire) == handle)
                device.play(play_slice)
            else
                audio_device.Error.DeviceUnavailable;
            unlockDevice(io);
            if (play_result) |_| {
                if (source_peak >= 8) device_owner_last_signal_ms.store(now, .release);
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
        } else {
            const n = audio_out_play_silent.fetchAdd(1, .monotonic);
            if (n < 3) {
                std.debug.print(
                    "[audio] inactive output route handle={d} owner={d} peak~{d}\n",
                    .{ handle, device_owner.load(.acquire), source_peak },
                );
            }
        }
    }

    if (fallback_pacing) pace(port.frames, port.frequency);
    return errno.ok;
}

fn audioOutOutput(handle: i32, data: ?*const anyopaque) callconv(abi.guest) i32 {
    return audioOutOutputImpl(handle, data, true, false);
}

const AudioOutOutputParam = extern struct {
    handle: i32,
    padding: u32,
    data: u64,
};

fn audioOutOutputs(parameters: ?[*]const AudioOutOutputParam, count: u32) callconv(abi.guest) i32 {
    if (count == 0 or count > 25) return audio_out_error_port_full;
    const list = parameters orelse return audio_out_error_invalid_pointer;
    const byte_size = @as(u64, count) * @sizeOf(AudioOutOutputParam);
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(list), byte_size)) {
        return audio_out_error_invalid_pointer;
    }

    // Validate the complete batch before submitting its first buffer. A bad
    // later descriptor must not leave the host device with a partial batch.
    var frames: ?u32 = null;
    var frequency: u32 = 0;
    const owner = device_owner.load(.acquire);
    var owner_entry: ?AudioOutOutputParam = null;
    var owner_peak: u32 = 0;
    var first_data_entry: ?AudioOutOutputParam = null;
    var strongest_entry: ?AudioOutOutputParam = null;
    var strongest_peak: u32 = 0;
    for (list[0..count], 0..) |entry, index| {
        const port = legacyPort(entry.handle, .output) orelse return audio_out_error_invalid_port;
        if (frames) |expected| {
            if (port.frames != expected) return audio_out_error_invalid_size;
        } else {
            frames = port.frames;
            frequency = port.frequency;
        }
        for (list[0..index]) |previous| {
            if (previous.handle == entry.handle) return audio_out_error_invalid_port;
        }
        if (entry.data != 0) {
            const length = port.frames * @as(u32, port.channels) * port.samples.bytes();
            if (!kernel_memory.isGuestRangeAccessible(entry.data, length)) return audio_out_error_invalid_pointer;
            const bytes: [*]const u8 = @ptrFromInt(entry.data);
            const peak = bufferPeak(port, bytes[0..length]);
            if (first_data_entry == null) first_data_entry = entry;
            if (strongest_entry == null or peak > strongest_peak) {
                strongest_entry = entry;
                strongest_peak = peak;
            }
            if (entry.handle == owner) {
                owner_entry = entry;
                owner_peak = peak;
            }
        }
    }

    // All ports in one call describe the same audio quantum. Submitting or
    // sleeping once is therefore the whole batch contract; pacing every silent
    // auxiliary port in sequence multiplies 5.3 ms by the port count and drains
    // the audible queue between otherwise timely mixer calls.
    // Keep a live owner stable, but when its entry is null/silent route the
    // strongest real buffer in this quantum. This is the MusicPlayer -> NGS2
    // transition used by Jets 'n' Guns 2.
    const selected = if (owner_entry != null and owner_peak >= 8)
        owner_entry
    else if (strongest_entry != null and strongest_peak >= 8)
        strongest_entry
    else
        owner_entry orelse first_data_entry;
    if (selected) |entry| {
        return audioOutOutputImpl(
            entry.handle,
            @ptrFromInt(entry.data),
            true,
            entry.handle != owner,
        );
    }
    pace(frames.?, frequency);
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
    .{ .name = "sceAudioOutOutputs", .function = trace.wrap("sceAudioOutOutputs", &audioOutOutputs), .expect_id = "w3PdaSTSwGE" },
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
    data_format: u32 = 0,
};

const maximum_audio_objects = 512;
var audio_object_mutex: Lock = .{};
var audio_objects: [maximum_audio_objects]AudioObject = [_]AudioObject{.{}} ** maximum_audio_objects;

fn allocateAudioObject(kind: AudioObjectKind, parent: u64, queue_depth: u32, grains: u32) ?u64 {
    audio_object_mutex.lock();
    defer audio_object_mutex.unlock();
    for (&audio_objects, 0..) |*object, index| {
        if (object.kind != .none) continue;
        object.* = .{
            .kind = kind,
            .parent = parent,
            .queue_depth = queue_depth,
            .grains = grains,
        };
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
    const input = parameters orelse return audio_out2_error_invalid_parameter;
    if (audioObject(context, .context) == null or port == null) return audio_out2_error_invalid_parameter;
    const handle = allocateAudioObject(.port, context, 0, 0) orelse return audio_out2_error_port_full;
    audio_object_mutex.lock();
    audio_objects[@intCast(handle - 1)].data_format = input.data_format;
    audio_object_mutex.unlock();
    port.?.* = handle;
    return errno.ok;
}

fn audioOut2PortChannels(data_format: u32) u8 {
    const encoded: u8 = @truncate(data_format >> 8);
    if (encoded == 0) return 2;
    return @min(encoded, 16);
}

/// Fixed 0x20-byte connected-primary state. Titles allocate that header next
/// to other AudioOut2 parameter blocks; writing past it overwrites them.
const audio_out2_port_state_bytes: usize = 0x20;

fn audioOut2PortGetState(port: u64, state: ?*[audio_out2_port_state_bytes]u8) callconv(abi.guest) i32 {
    const output = state orelse return audio_out2_error_invalid_parameter;
    @memset(output, 0);
    var channels: u8 = 2;
    if (audioObject(port, .port)) |object| {
        channels = audioOut2PortChannels(object.data_format);
    }
    std.mem.writeInt(u16, output[0x00..0x02], 1, .little);
    output[0x02] = channels;
    std.mem.writeInt(i16, output[0x04..0x06], -1, .little);
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
    .{ .name = "sceAudioOut2PortGetState", .function = trace.wrap("sceAudioOut2PortGetState", &audioOut2PortGetState), .expect_id = "gatEUKG+Ea4" },
    .{ .name = "sceAudioOut2PortDestroy", .function = trace.wrap("sceAudioOut2PortDestroy", &audioOut2PortDestroy), .expect_id = "cd+Rtw+D1x8" },
    .{ .name = "sceAudioOut2PortSetAttributes", .function = trace.wrap("sceAudioOut2PortSetAttributes", &audioOut2PortSetAttributes), .expect_id = "8XTArSPyWHk" },
    .{ .name = "sceAudioOut2UserCreate", .function = trace.wrap("sceAudioOut2UserCreate", &audioOut2UserCreate), .expect_id = "xywYcRB7nbQ" },
    .{ .name = "sceAudioOut2UserDestroy", .function = trace.wrap("sceAudioOut2UserDestroy", &audioOut2UserDestroy), .expect_id = "IaZXJ9M79uo" },
    .{ .name = "sceAudioOut2GetSpeakerInfo", .function = trace.wrap("sceAudioOut2GetSpeakerInfo", &audioOut2GetSpeakerInfo), .expect_id = "DImz2Ft9E2g" },
};

// libSceNgs2 ---------------------------------------------------------------

const Ngs2RenderBuffer = extern struct {
    address: u64,
    size: u64,
    waveform_type: u32,
    channels: u32,
};

const Ngs2WaveformFormat = extern struct {
    waveform_type: u32 = 0,
    channels: u32 = 0,
    sample_rate: u32 = 0,
    config_data: u32 = 0,
    frame_margin: u32 = 0,
    frame_offset: u32 = 0,
};

const Ngs2WaveformBlock = extern struct {
    data_offset: usize = 0,
    data_size: usize = 0,
    repeats: u32 = 0,
    skip_samples: u32 = 0,
    samples: u32 = 0,
    reserved: u32 = 0,
    user_data: usize = 0,
};

const Ngs2WaveformInfo = extern struct {
    format: Ngs2WaveformFormat = .{},
    data_offset: u32 = 0,
    data_size: u32 = 0,
    loop_begin: u32 = 0,
    loop_end: u32 = 0,
    samples: u32 = 0,
    audio_unit_size: u32 = 0,
    audio_unit_samples: u32 = 0,
    audio_units_per_frame: u32 = 0,
    audio_frame_size: u32 = 0,
    audio_frame_samples: u32 = 0,
    delay_samples: u32 = 0,
    block_count: u32 = 0,
    blocks: [4]Ngs2WaveformBlock = @splat(.{}),
};

var next_ngs2_handle = std.atomic.Value(u64).init(0x4e47_0001);
var ngs2_render_calls = std.atomic.Value(u64).init(0);
var ngs2_control_logs = std.atomic.Value(u32).init(0);
var ngs2_state_logs = std.atomic.Value(u32).init(0);
var ngs2_waveform_logs = std.atomic.Value(u32).init(0);
var ngs2_command_logs = std.atomic.Value(u32).init(0);

const maximum_ngs2_systems = 8;
const maximum_ngs2_racks = 64;
const maximum_ngs2_voices = 1024;

const Ngs2VoiceState = enum(u8) {
    empty,
    playing,
    paused,
    stopped,
};

const Ngs2VoiceEvent = enum(u8) {
    none,
    play,
    stop,
    stop_immediate,
    kill,
    pause,
    resume_playback,
};

const Ngs2System = struct {
    active: bool = false,
    handle: u64 = 0,
};

const Ngs2Rack = struct {
    active: bool = false,
    handle: u64 = 0,
    system: u64 = 0,
    rack_id: u32 = 0,
};

const Ngs2Voice = struct {
    active: bool = false,
    handle: u64 = 0,
    rack: u64 = 0,
    voice_id: u32 = 0,
    state: Ngs2VoiceState = .empty,
    event: Ngs2VoiceEvent = .none,
    source_address: u64 = 0,
    source_rate: u32 = 48_000,
    source_channels: u8 = 1,
    samples: []f32 = &.{},
    waveform_cache_index: ?u8 = null,
    position: f64 = 0,
    loop_start: ?usize = null,
    loop_end: usize = 0,
    gain: f32 = 1,
};

const Ngs2VoiceParamHeader = extern struct {
    size: u16,
    next: i16,
    id: u32,
};

const Ngs2VoiceEventParam = extern struct {
    header: Ngs2VoiceParamHeader,
    event_id: u32,
};

const Ngs2VoiceWaveformParam = extern struct {
    header: Ngs2VoiceParamHeader,
    data_address: u64,
};

const maximum_ngs2_waveform_bytes = 8 * 1024 * 1024;

const Ngs2DecodedWaveform = struct {
    samples: []f32,
    sample_rate: u32,
    channels: u8,
    loop_start: ?usize = null,
    loop_end: usize,
};

const maximum_ngs2_cached_waveforms = 64;
const maximum_ngs2_waveform_cache_bytes = 128 * 1024 * 1024;

const Ngs2CachedWaveform = struct {
    active: bool = false,
    address: u64 = 0,
    samples: []f32 = &.{},
    sample_rate: u32 = 48_000,
    channels: u8 = 1,
    loop_start: ?usize = null,
    loop_end: usize = 0,
    references: u16 = 0,
    last_used_sequence: u64 = 0,
};

var ngs2_mutex = Lock{};
var ngs2_systems = [_]Ngs2System{.{}} ** maximum_ngs2_systems;
var ngs2_racks = [_]Ngs2Rack{.{}} ** maximum_ngs2_racks;
var ngs2_voices = [_]Ngs2Voice{.{}} ** maximum_ngs2_voices;
var ngs2_waveform_cache = [_]Ngs2CachedWaveform{.{}} ** maximum_ngs2_cached_waveforms;
var ngs2_waveform_cache_bytes: usize = 0;
var ngs2_waveform_cache_sequence: u64 = 0;

fn ngs2Handle() u64 {
    return next_ngs2_handle.fetchAdd(1, .monotonic);
}

fn ngs2SystemCreateWithAllocator(_: u64, _: u64, output: ?*u64) callconv(abi.guest) i32 {
    const destination = output orelse return ngs2_error_invalid_output;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(u64))) {
        return errno.KernelError.efault.raw();
    }
    ngs2_mutex.lock();
    defer ngs2_mutex.unlock();
    for (&ngs2_systems) |*system| {
        if (system.active) continue;
        const handle = ngs2Handle();
        system.* = .{ .active = true, .handle = handle };
        destination.* = handle;
        return errno.ok;
    }
    return errno.KernelError.enomem.raw();
}

fn ngs2RackCreateWithAllocator(
    system: u64,
    rack_id: u32,
    _: u64,
    _: u64,
    output: ?*u64,
) callconv(abi.guest) i32 {
    if (system == 0) return errno.KernelError.einval.raw();
    const destination = output orelse return ngs2_error_invalid_output;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(u64))) {
        return errno.KernelError.efault.raw();
    }
    ngs2_mutex.lock();
    defer ngs2_mutex.unlock();
    if (ngs2FindSystem(system) == null) return errno.KernelError.einval.raw();
    for (&ngs2_racks) |*rack| {
        if (rack.active) continue;
        const handle = ngs2Handle();
        rack.* = .{ .active = true, .handle = handle, .system = system, .rack_id = rack_id };
        destination.* = handle;
        return errno.ok;
    }
    return errno.KernelError.enomem.raw();
}

fn ngs2RackGetVoiceHandle(rack: u64, voice_id: u32, output: ?*u64) callconv(abi.guest) i32 {
    if (rack == 0) return errno.KernelError.einval.raw();
    const destination = output orelse return ngs2_error_invalid_output;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(u64))) {
        return errno.KernelError.efault.raw();
    }
    ngs2_mutex.lock();
    defer ngs2_mutex.unlock();
    if (ngs2FindRack(rack) == null) return errno.KernelError.einval.raw();
    for (&ngs2_voices) |*voice| {
        if (voice.active and voice.rack == rack and voice.voice_id == voice_id) {
            destination.* = voice.handle;
            return errno.ok;
        }
    }
    for (&ngs2_voices) |*voice| {
        if (voice.active) continue;
        const handle = ngs2Handle();
        voice.* = .{ .active = true, .handle = handle, .rack = rack, .voice_id = voice_id };
        destination.* = handle;
        return errno.ok;
    }
    return errno.KernelError.enomem.raw();
}

fn ngs2FindSystem(handle: u64) ?*Ngs2System {
    for (&ngs2_systems) |*system| if (system.active and system.handle == handle) return system;
    return null;
}

fn ngs2FindRack(handle: u64) ?*Ngs2Rack {
    for (&ngs2_racks) |*rack| if (rack.active and rack.handle == handle) return rack;
    return null;
}

fn ngs2FindVoice(handle: u64) ?*Ngs2Voice {
    for (&ngs2_voices) |*voice| if (voice.active and voice.handle == handle) return voice;
    return null;
}

fn ngs2FreeVoiceWaveform(voice: *Ngs2Voice) void {
    if (voice.waveform_cache_index) |raw_index| {
        const index: usize = raw_index;
        if (index < ngs2_waveform_cache.len) {
            const cached = &ngs2_waveform_cache[index];
            if (cached.active and cached.references != 0) cached.references -= 1;
        }
    } else if (voice.samples.len != 0) {
        std.heap.page_allocator.free(voice.samples);
    }
    voice.samples = &.{};
    voice.waveform_cache_index = null;
    voice.source_address = 0;
    voice.position = 0;
    voice.loop_start = null;
    voice.loop_end = 0;
}

fn ngs2EvictCachedWaveform(index: usize) void {
    const cached = &ngs2_waveform_cache[index];
    if (!cached.active or cached.references != 0) return;
    const bytes = cached.samples.len * @sizeOf(f32);
    if (cached.samples.len != 0) std.heap.page_allocator.free(cached.samples);
    ngs2_waveform_cache_bytes -|= bytes;
    cached.* = .{};
}

fn ngs2OldestUnusedWaveform() ?usize {
    var selected: ?usize = null;
    var oldest: u64 = std.math.maxInt(u64);
    for (&ngs2_waveform_cache, 0..) |*cached, index| {
        if (!cached.active) return index;
        if (cached.references != 0 or cached.last_used_sequence >= oldest) continue;
        selected = index;
        oldest = cached.last_used_sequence;
    }
    return selected;
}

fn ngs2OldestEvictableWaveform() ?usize {
    var selected: ?usize = null;
    var oldest: u64 = std.math.maxInt(u64);
    for (&ngs2_waveform_cache, 0..) |*cached, index| {
        if (!cached.active or cached.references != 0 or cached.last_used_sequence >= oldest) continue;
        selected = index;
        oldest = cached.last_used_sequence;
    }
    return selected;
}

fn ngs2BindCachedWaveform(voice: *Ngs2Voice, index: usize) void {
    const cached = &ngs2_waveform_cache[index];
    std.debug.assert(cached.active);
    cached.references +|= 1;
    ngs2_waveform_cache_sequence +%= 1;
    cached.last_used_sequence = ngs2_waveform_cache_sequence;
    voice.source_address = cached.address;
    voice.source_rate = cached.sample_rate;
    voice.source_channels = cached.channels;
    voice.samples = cached.samples;
    voice.waveform_cache_index = @intCast(index);
    voice.position = 0;
    voice.loop_start = cached.loop_start;
    voice.loop_end = cached.loop_end;
    voice.state = .playing;
}

fn ngs2FindCachedWaveform(address: u64) ?usize {
    for (&ngs2_waveform_cache, 0..) |*cached, index| {
        if (cached.active and cached.address == address) return index;
    }
    return null;
}

/// Takes ownership of `decoded.samples` on success.
fn ngs2CacheWaveform(address: u64, decoded: Ngs2DecodedWaveform) ?usize {
    const bytes = decoded.samples.len * @sizeOf(f32);
    if (bytes > maximum_ngs2_waveform_cache_bytes) return null;
    while (ngs2_waveform_cache_bytes +| bytes > maximum_ngs2_waveform_cache_bytes) {
        const victim = ngs2OldestEvictableWaveform() orelse return null;
        ngs2EvictCachedWaveform(victim);
    }
    const slot = ngs2OldestUnusedWaveform() orelse return null;
    if (ngs2_waveform_cache[slot].active) ngs2EvictCachedWaveform(slot);
    ngs2_waveform_cache_sequence +%= 1;
    ngs2_waveform_cache[slot] = .{
        .active = true,
        .address = address,
        .samples = decoded.samples,
        .sample_rate = decoded.sample_rate,
        .channels = decoded.channels,
        .loop_start = decoded.loop_start,
        .loop_end = decoded.loop_end,
        .last_used_sequence = ngs2_waveform_cache_sequence,
    };
    ngs2_waveform_cache_bytes += bytes;
    return slot;
}

fn ngs2ResetVoice(voice: *Ngs2Voice) void {
    ngs2FreeVoiceWaveform(voice);
    voice.* = .{};
}

fn ngs2RackDestroy(handle: u64, _: u64) callconv(abi.guest) i32 {
    ngs2_mutex.lock();
    defer ngs2_mutex.unlock();
    const rack = ngs2FindRack(handle) orelse return errno.KernelError.einval.raw();
    for (&ngs2_voices) |*voice| {
        if (voice.active and voice.rack == handle) ngs2ResetVoice(voice);
    }
    rack.* = .{};
    return errno.ok;
}

fn ngs2SystemDestroy(handle: u64, _: u64) callconv(abi.guest) i32 {
    ngs2_mutex.lock();
    defer ngs2_mutex.unlock();
    const system = ngs2FindSystem(handle) orelse return errno.KernelError.einval.raw();
    for (&ngs2_racks) |*rack| {
        if (!rack.active or rack.system != handle) continue;
        for (&ngs2_voices) |*voice| {
            if (voice.active and voice.rack == rack.handle) ngs2ResetVoice(voice);
        }
        rack.* = .{};
    }
    system.* = .{};
    return errno.ok;
}

fn ngs2Event(event_id: u32) ?Ngs2VoiceEvent {
    return switch (event_id) {
        0x0001 => .play,
        0x0002 => .stop,
        0x0004 => .stop_immediate,
        0x0008 => .kill,
        0x0010 => .pause,
        0x0020 => .resume_playback,
        else => null,
    };
}

fn ngs2NextParam(address: u64, offset: i16) ?u64 {
    const wide_offset: i32 = offset;
    return if (wide_offset > 0)
        std.math.add(u64, address, @intCast(wide_offset)) catch null
    else
        std.math.sub(u64, address, @intCast(-wide_offset)) catch null;
}

fn ngs2DecodeVag(address: u64) ?Ngs2DecodedWaveform {
    const header_size = 0x30;
    if (!kernel_memory.isGuestRangeAccessible(address, header_size)) return null;
    const pointer: [*]const u8 = @ptrFromInt(address);
    const header = pointer[0..header_size];
    if (!std.mem.eql(u8, header[0..4], "VAGp")) return null;

    const declared_size: usize = std.mem.readInt(u32, header[0x0c..0x10], .big);
    const sample_rate_raw = std.mem.readInt(u32, header[0x10..0x14], .big);
    const frame_bytes = declared_size - (declared_size % 16);
    if (frame_bytes == 0 or frame_bytes > maximum_ngs2_waveform_bytes) return null;
    const total_bytes = std.math.add(usize, header_size, frame_bytes) catch return null;
    if (!kernel_memory.isGuestRangeAccessible(address, total_bytes)) return null;
    const sample_count = std.math.mul(usize, frame_bytes / 16, 28) catch return null;
    if (sample_count > 4 * 1024 * 1024) return null;
    const samples = std.heap.page_allocator.alloc(f32, sample_count) catch return null;

    const coefficients0 = [_]i32{ 0, 60, 115, 98, 122 };
    const coefficients1 = [_]i32{ 0, 0, -52, -55, -60 };
    const frames = pointer[header_size..total_bytes];
    var history1: i32 = 0;
    var history2: i32 = 0;
    var output_index: usize = 0;
    var loop_start: ?usize = null;
    var loop_end: usize = 0;
    var ended = false;
    var frame: usize = 0;
    while (frame < frame_bytes / 16 and !ended) : (frame += 1) {
        const offset = frame * 16;
        const shift: u5 = @intCast(@min(frames[offset] & 0x0f, 12));
        const filter: usize = @min(frames[offset] >> 4, coefficients0.len - 1);
        const flags = frames[offset + 1];
        if (flags == 0x03) loop_start = output_index;
        for (0..14) |byte_index| {
            const sample_byte = frames[offset + 2 + byte_index];
            for (0..2) |nibble_index| {
                const raw: u8 = if (nibble_index == 0) sample_byte & 0x0f else sample_byte >> 4;
                const signed: i32 = if (raw >= 8) @as(i32, raw) - 16 else raw;
                const residual = (signed << 12) >> shift;
                const predicted = (history1 * coefficients0[filter] + history2 * coefficients1[filter]) >> 6;
                const decoded = std.math.clamp(residual + predicted, std.math.minInt(i16), std.math.maxInt(i16));
                samples[output_index] = @as(f32, @floatFromInt(decoded)) / 32768.0;
                output_index += 1;
                history2 = history1;
                history1 = decoded;
            }
        }
        if (flags == 0x06) {
            loop_end = output_index;
        } else if (flags == 0x01 or flags == 0x07) {
            ended = true;
        }
    }
    if (output_index == 0) {
        std.heap.page_allocator.free(samples);
        return null;
    }
    if (loop_start != null and loop_end <= loop_start.?) loop_end = output_index;
    const trimmed = std.heap.page_allocator.realloc(samples, output_index) catch samples;
    return .{
        .samples = trimmed,
        .sample_rate = if (sample_rate_raw == 0) 48_000 else sample_rate_raw,
        .channels = 1,
        .loop_start = loop_start,
        .loop_end = if (loop_end != 0) loop_end else output_index,
    };
}

fn ngs2DecodeWave(address: u64) ?Ngs2DecodedWaveform {
    if (!kernel_memory.isGuestRangeAccessible(address, 12)) return null;
    const pointer: [*]const u8 = @ptrFromInt(address);
    const header = pointer[0..12];
    if (!std.mem.eql(u8, header[0..4], "RIFF") or !std.mem.eql(u8, header[8..12], "WAVE")) return null;
    const riff_payload: usize = std.mem.readInt(u32, header[4..8], .little);
    const riff_bytes = std.math.add(usize, riff_payload, 8) catch return null;
    if (riff_bytes < 12 or riff_bytes > maximum_ngs2_waveform_bytes or
        !kernel_memory.isGuestRangeAccessible(address, riff_bytes)) return null;
    const bytes = pointer[0..riff_bytes];

    var format_tag: u16 = 0;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var block_align: u16 = 0;
    var bits_per_sample: u16 = 0;
    var data_offset: usize = 0;
    var data_size: usize = 0;
    var loop_start: ?usize = null;
    var loop_end: usize = 0;
    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const chunk_size: usize = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const chunk_data = offset + 8;
        if (chunk_size > bytes.len - chunk_data) return null;
        if (std.mem.eql(u8, bytes[offset..][0..4], "fmt ") and chunk_size >= 16) {
            format_tag = std.mem.readInt(u16, bytes[chunk_data..][0..2], .little);
            channels = std.mem.readInt(u16, bytes[chunk_data + 2 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, bytes[chunk_data + 4 ..][0..4], .little);
            block_align = std.mem.readInt(u16, bytes[chunk_data + 12 ..][0..2], .little);
            bits_per_sample = std.mem.readInt(u16, bytes[chunk_data + 14 ..][0..2], .little);
            if (format_tag == 0xfffe and chunk_size >= 40) {
                format_tag = std.mem.readInt(u16, bytes[chunk_data + 24 ..][0..2], .little);
            }
        } else if (std.mem.eql(u8, bytes[offset..][0..4], "data")) {
            data_offset = chunk_data;
            data_size = chunk_size;
        } else if (std.mem.eql(u8, bytes[offset..][0..4], "smpl") and chunk_size >= 60) {
            const loop_count = std.mem.readInt(u32, bytes[chunk_data + 28 ..][0..4], .little);
            if (loop_count != 0) {
                loop_start = std.mem.readInt(u32, bytes[chunk_data + 44 ..][0..4], .little);
                const inclusive_end = std.mem.readInt(u32, bytes[chunk_data + 48 ..][0..4], .little);
                loop_end = @as(usize, inclusive_end) +| 1;
            }
        }
        const padded_size = std.math.add(usize, chunk_size, chunk_size & 1) catch return null;
        offset = std.math.add(usize, chunk_data, padded_size) catch return null;
    }
    if ((format_tag != 1 and format_tag != 3) or channels == 0 or channels > 8 or
        sample_rate == 0 or block_align == 0 or data_offset == 0 or data_size < block_align)
    {
        return null;
    }
    const bytes_per_sample = (bits_per_sample + 7) / 8;
    if (bytes_per_sample == 0 or block_align < channels * bytes_per_sample) return null;
    const frame_count = data_size / block_align;
    const sample_count = std.math.mul(usize, frame_count, channels) catch return null;
    if (sample_count == 0 or sample_count > 4 * 1024 * 1024) return null;
    const samples = std.heap.page_allocator.alloc(f32, sample_count) catch return null;
    const pcm = bytes[data_offset..][0 .. frame_count * block_align];
    for (0..frame_count) |frame| {
        for (0..channels) |channel| {
            const sample_offset = frame * block_align + channel * bytes_per_sample;
            const sample: f32 = if (format_tag == 3 and bits_per_sample == 32)
                @bitCast(std.mem.readInt(u32, pcm[sample_offset..][0..4], .little))
            else if (format_tag == 1) switch (bits_per_sample) {
                8 => (@as(f32, @floatFromInt(pcm[sample_offset])) - 128.0) / 128.0,
                16 => @as(f32, @floatFromInt(std.mem.readInt(i16, pcm[sample_offset..][0..2], .little))) / 32768.0,
                24 => blk: {
                    const raw = @as(u32, pcm[sample_offset]) |
                        (@as(u32, pcm[sample_offset + 1]) << 8) |
                        (@as(u32, pcm[sample_offset + 2]) << 16);
                    const signed: i32 = @bitCast(if (raw & 0x0080_0000 != 0) raw | 0xff00_0000 else raw);
                    break :blk @as(f32, @floatFromInt(signed)) / 8_388_608.0;
                },
                32 => @as(f32, @floatFromInt(std.mem.readInt(i32, pcm[sample_offset..][0..4], .little))) / 2_147_483_648.0,
                else => 0,
            } else 0;
            samples[frame * channels + channel] = if (std.math.isFinite(sample))
                std.math.clamp(sample, -1, 1)
            else
                0;
        }
    }
    if (loop_start) |start| {
        if (start >= frame_count or loop_end <= start or loop_end > frame_count) {
            loop_start = null;
            loop_end = frame_count;
        }
    } else {
        loop_end = frame_count;
    }
    return .{
        .samples = samples,
        .sample_rate = sample_rate,
        .channels = @intCast(channels),
        .loop_start = loop_start,
        .loop_end = loop_end,
    };
}

fn ngs2ArmVoice(voice: *Ngs2Voice, address: u64) void {
    if (address == 0) return;
    if (voice.source_address == address and voice.samples.len != 0) {
        voice.position = 0;
        voice.state = .playing;
        return;
    }
    if (ngs2FindCachedWaveform(address)) |cached_index| {
        ngs2FreeVoiceWaveform(voice);
        ngs2BindCachedWaveform(voice, cached_index);
        return;
    }
    const decoded = ngs2DecodeWave(address) orelse ngs2DecodeVag(address) orelse {
        const log_index = ngs2_waveform_logs.fetchAdd(1, .monotonic);
        if (log_index < 16) std.debug.print(
            "[audio] NGS2 unsupported sampler waveform @0x{x}\n",
            .{address},
        );
        return;
    };
    ngs2FreeVoiceWaveform(voice);
    if (ngs2CacheWaveform(address, decoded)) |cached_index| {
        ngs2BindCachedWaveform(voice, cached_index);
    } else {
        voice.source_address = address;
        voice.source_rate = decoded.sample_rate;
        voice.source_channels = decoded.channels;
        voice.samples = decoded.samples;
        voice.position = 0;
        voice.loop_start = decoded.loop_start;
        voice.loop_end = decoded.loop_end;
        voice.state = .playing;
    }
    const log_index = ngs2_waveform_logs.fetchAdd(1, .monotonic);
    if (log_index < 16) std.debug.print(
        "[audio] NGS2 sampler armed voice=0x{x} source=0x{x} rate={d} channels={d} frames={d} loop={?d}-{d}\n",
        .{ voice.handle, address, voice.source_rate, voice.source_channels, voice.samples.len / voice.source_channels, voice.loop_start, voice.loop_end },
    );
}

fn ngs2VoiceControl(handle: u64, params_address: u64) callconv(abi.guest) i32 {
    if (params_address == 0) return errno.KernelError.einval.raw();
    ngs2_mutex.lock();
    defer ngs2_mutex.unlock();
    const voice = ngs2FindVoice(handle) orelse return errno.KernelError.einval.raw();

    var address = params_address;
    for (0..256) |_| {
        if (!kernel_memory.isGuestRangeAccessible(address, @sizeOf(Ngs2VoiceParamHeader))) {
            return errno.KernelError.efault.raw();
        }
        const header: *const Ngs2VoiceParamHeader = @ptrFromInt(address);
        if (header.size < @sizeOf(Ngs2VoiceParamHeader)) return errno.KernelError.einval.raw();
        if (!kernel_memory.isGuestRangeAccessible(address, header.size)) return errno.KernelError.efault.raw();

        const rack_id = header.id >> 16;
        const command_id = header.id & 0x7fff;
        const log_index = ngs2_control_logs.fetchAdd(1, .monotonic);
        if (trace.isLive() and log_index < 128) std.debug.print(
            "[audio] NGS2 voice=0x{x} param id=0x{x} size={d} next={d}\n",
            .{ handle, header.id, header.size, header.next },
        );
        if (rack_id == 0 and command_id == 0x0006) {
            if (header.size < @sizeOf(Ngs2VoiceEventParam)) return errno.KernelError.einval.raw();
            const event: *const Ngs2VoiceEventParam = @ptrFromInt(address);
            voice.event = ngs2Event(event.event_id) orelse return errno.KernelError.einval.raw();
            if (trace.isLive() and log_index < 128) std.debug.print(
                "[audio] NGS2 voice=0x{x} event=0x{x}\n",
                .{ handle, event.event_id },
            );
        } else if (header.id == 0x1000_0001) {
            if (header.size < @sizeOf(Ngs2VoiceWaveformParam)) return errno.KernelError.einval.raw();
            const waveform: *const Ngs2VoiceWaveformParam = @ptrFromInt(address);
            ngs2ArmVoice(voice, waveform.data_address);
        } else if (header.id == 0x0000_0002 and header.size >= 16) {
            const level_bits: *const u32 = @ptrFromInt(address + 12);
            const level: f32 = @bitCast(level_bits.*);
            if (std.math.isFinite(level) and level >= 0 and level <= 8) voice.gain = level;
        }
        if (header.next == 0) return errno.ok;
        address = ngs2NextParam(address, header.next) orelse return errno.KernelError.einval.raw();
    }
    return errno.KernelError.einval.raw();
}

fn ngs2VoiceRunCommands(handle: u64, params_address: u64, command_count: u32, _: u32) callconv(abi.guest) i32 {
    ngs2_mutex.lock();
    const valid_voice = ngs2FindVoice(handle) != null;
    ngs2_mutex.unlock();
    if (!valid_voice) return errno.KernelError.einval.raw();
    if (command_count == 0 or params_address == 0) return errno.ok;

    const log_index = ngs2_command_logs.fetchAdd(1, .monotonic);
    if (trace.isLive() and log_index < 64 and kernel_memory.isGuestRangeAccessible(params_address, 64)) {
        const words: *const [8]u64 = @ptrFromInt(params_address);
        std.debug.print(
            "[audio] NGS2 commands voice=0x{x} count={d} words={x:0>16} {x:0>16} {x:0>16} {x:0>16} {x:0>16} {x:0>16} {x:0>16} {x:0>16}\n",
            .{ handle, command_count, words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7] },
        );
    }

    // Some SDK revisions pass the ordinary parameter-list representation to
    // this entry point. Only route lists whose header is structurally valid;
    // other revisions use a distinct compact command format and must remain
    // accepted until their opcode is decoded.
    if (kernel_memory.isGuestRangeAccessible(params_address, @sizeOf(Ngs2VoiceParamHeader))) {
        const header: *const Ngs2VoiceParamHeader = @ptrFromInt(params_address);
        if (header.size >= @sizeOf(Ngs2VoiceParamHeader) and header.size <= 0x1000) {
            return ngs2VoiceControl(handle, params_address);
        }
    }
    return errno.ok;
}

fn ngs2StateFlags(state: Ngs2VoiceState) u32 {
    return switch (state) {
        .empty => 0,
        .playing => 0x3,
        .paused => 0x5,
        .stopped => 0xb,
    };
}

fn ngs2ApplyEventsLocked(system_handle: u64) void {
    for (&ngs2_racks) |*rack| {
        if (!rack.active or rack.system != system_handle) continue;
        for (&ngs2_voices) |*voice| {
            if (!voice.active or voice.rack != rack.handle) continue;
            switch (voice.event) {
                .none => {},
                .play => if (voice.state == .empty or voice.state == .stopped) {
                    voice.position = 0;
                    voice.state = .playing;
                },
                .pause => if (voice.state == .playing) {
                    voice.state = .paused;
                },
                .resume_playback => if (voice.state == .paused) {
                    voice.state = .playing;
                },
                .stop => if (voice.state == .playing or voice.state == .paused) {
                    voice.state = .stopped;
                },
                .stop_immediate, .kill => voice.state = .empty,
            }
            voice.event = .none;
        }
    }
}

fn ngs2ParseWaveformData(
    data_address: u64,
    data_size: usize,
    output: ?*Ngs2WaveformInfo,
) callconv(abi.guest) i32 {
    const info = output orelse return ngs2_error_invalid_output;
    if (data_address == 0 or data_size == 0 or
        !kernel_memory.isGuestRangeAccessible(data_address, data_size) or
        !kernel_memory.isGuestRangeAccessible(@intFromPtr(info), @sizeOf(Ngs2WaveformInfo)))
    {
        return errno.KernelError.efault.raw();
    }
    info.* = .{};
    info.format = .{ .waveform_type = 0x80, .channels = 1, .sample_rate = 48_000 };
    info.data_size = @intCast(@min(data_size, std.math.maxInt(u32)));
    info.audio_unit_samples = 1;
    info.audio_units_per_frame = 1;
    info.audio_frame_samples = 1;

    // NGS2 accepts ordinary RIFF/WAVE assets directly. Preserve the useful
    // geometry instead of returning a generic one-channel placeholder: JnG2
    // uses it to size voices for hundreds of loose PCM sound effects.
    const bytes: [*]const u8 = @ptrFromInt(data_address);
    const input = bytes[0..data_size];
    if (input.len < 12 or !std.mem.eql(u8, input[0..4], "RIFF") or !std.mem.eql(u8, input[8..12], "WAVE")) {
        return errno.ok;
    }
    var block_align: u16 = 0;
    var data_offset: usize = 0;
    var wave_size: usize = 0;
    var offset: usize = 12;
    while (offset + 8 <= input.len) {
        const chunk_size: usize = std.mem.readInt(u32, input[offset + 4 ..][0..4], .little);
        const chunk_data = offset + 8;
        if (chunk_size > input.len - chunk_data) break;
        if (std.mem.eql(u8, input[offset..][0..4], "fmt ") and chunk_size >= 16) {
            info.format.channels = std.mem.readInt(u16, input[chunk_data + 2 ..][0..2], .little);
            info.format.sample_rate = std.mem.readInt(u32, input[chunk_data + 4 ..][0..4], .little);
            block_align = std.mem.readInt(u16, input[chunk_data + 12 ..][0..2], .little);
        } else if (std.mem.eql(u8, input[offset..][0..4], "data")) {
            data_offset = chunk_data;
            wave_size = chunk_size;
            break;
        }
        offset = chunk_data + chunk_size + (chunk_size & 1);
    }
    if (data_offset == 0) return errno.ok;
    const bounded_size = @min(wave_size, std.math.maxInt(u32));
    info.data_offset = @intCast(data_offset);
    info.data_size = @intCast(bounded_size);
    info.audio_unit_size = block_align;
    info.audio_frame_size = block_align;
    if (block_align != 0) info.samples = @intCast(bounded_size / block_align);
    info.loop_end = info.samples;
    info.block_count = 1;
    info.blocks[0] = .{
        .data_offset = data_offset,
        .data_size = bounded_size,
        .samples = info.samples,
    };
    return errno.ok;
}

fn ngs2CalcWaveformBlock(
    format: ?*const Ngs2WaveformFormat,
    _: u32,
    samples: u32,
    output: ?*Ngs2WaveformBlock,
) callconv(abi.guest) i32 {
    if (format == null) return errno.KernelError.einval.raw();
    const block = output orelse return ngs2_error_invalid_output;
    block.* = .{ .samples = samples };
    return errno.ok;
}

/// One NGS2 render produces one grain of interleaved float32 audio.  Titles
/// normally hand that grain to AudioOut, whose blocking write provides the
/// clock.  Some PS5 titles (JnG2 among them) drive NGS2 from a render worker
/// without a blocking AudioOut call; returning immediately then turns the
/// worker into a 100% CPU busy loop and can starve the game thread.
///
/// All output buses in a call describe the same grain.  Use the smallest valid
/// frame count so malformed or auxiliary buffers cannot over-sleep the title.
fn ngs2RenderFrameCount(buffers: []const Ngs2RenderBuffer) u32 {
    var result: u64 = 0;
    for (buffers) |buffer| {
        if (buffer.size == 0 or buffer.channels == 0 or buffer.channels > 32) continue;
        const bytes_per_frame = @as(u64, buffer.channels) * @sizeOf(f32);
        const frames = buffer.size / bytes_per_frame;
        if (frames == 0) continue;
        result = if (result == 0) frames else @min(result, frames);
    }
    // A corrupt descriptor must not suspend a guest thread for seconds.  NGS2
    // grains are short (JnG2 uses 256 samples); 4096 is already 85 ms at 48 kHz.
    return @intCast(@min(result, 4096));
}

fn ngs2VoiceBelongsToSystem(voice: *const Ngs2Voice, system: u64) bool {
    for (&ngs2_racks) |*rack| {
        if (rack.active and rack.handle == voice.rack) return rack.system == system;
    }
    return false;
}

fn ngs2SourceSample(voice: *const Ngs2Voice, frame: usize, channel: usize) f32 {
    const source_channels: usize = voice.source_channels;
    if (source_channels == 0) return 0;
    const source_channel = @min(channel, source_channels - 1);
    const index = frame * source_channels + source_channel;
    return if (index < voice.samples.len) voice.samples[index] else 0;
}

fn ngs2MixBufferLocked(
    system: u64,
    buffer: Ngs2RenderBuffer,
    frames: u32,
    initial_positions: *const [maximum_ngs2_voices]f64,
    initial_playing: *const [maximum_ngs2_voices]bool,
    advance_voices: bool,
) void {
    if (buffer.address == 0 or buffer.size == 0 or buffer.channels == 0 or buffer.channels > 32) return;
    const output_channels: usize = buffer.channels;
    const capacity: usize = @intCast(buffer.size / @sizeOf(f32));
    const output_frames = @min(@as(usize, frames), capacity / output_channels);
    if (output_frames == 0) return;
    const destination: [*]f32 = @ptrFromInt(buffer.address);
    const output = destination[0 .. output_frames * output_channels];

    for (&ngs2_voices, 0..) |*voice, voice_index| {
        if (!voice.active or !initial_playing[voice_index] or voice.samples.len == 0 or
            voice.source_channels == 0 or !ngs2VoiceBelongsToSystem(voice, system)) continue;
        const source_channels: usize = voice.source_channels;
        const source_frames = voice.samples.len / source_channels;
        const playback_end = @min(if (voice.loop_end != 0) voice.loop_end else source_frames, source_frames);
        if (playback_end == 0) continue;
        const step = @as(f64, @floatFromInt(voice.source_rate)) / 48_000.0;
        var position = initial_positions[voice_index];
        var ended = false;
        for (0..output_frames) |output_frame| {
            var source_frame: usize = @intFromFloat(@max(position, 0));
            if (source_frame >= playback_end) {
                if (voice.loop_start) |loop_start| {
                    if (loop_start < playback_end) {
                        const loop_length = playback_end - loop_start;
                        const overshoot = source_frame - playback_end;
                        source_frame = loop_start + overshoot % loop_length;
                        position = @floatFromInt(source_frame);
                    } else {
                        ended = true;
                        break;
                    }
                } else {
                    ended = true;
                    break;
                }
            }
            var next_frame = source_frame + 1;
            if (next_frame >= playback_end) next_frame = voice.loop_start orelse source_frame;
            const fraction: f32 = @floatCast(position - @as(f64, @floatFromInt(source_frame)));
            const left0 = ngs2SourceSample(voice, source_frame, 0);
            const left1 = ngs2SourceSample(voice, next_frame, 0);
            const left = (left0 + (left1 - left0) * fraction) * voice.gain;
            const right = if (source_channels > 1) blk: {
                const right0 = ngs2SourceSample(voice, source_frame, 1);
                const right1 = ngs2SourceSample(voice, next_frame, 1);
                break :blk (right0 + (right1 - right0) * fraction) * voice.gain;
            } else left;
            const base = output_frame * output_channels;
            output[base] = std.math.clamp(output[base] + left, -1, 1);
            if (output_channels > 1) output[base + 1] = std.math.clamp(output[base + 1] + right, -1, 1);
            position += step;
        }
        if (advance_voices) {
            voice.position = position;
            if (ended) voice.state = .empty;
        }
    }
}

fn ngs2SystemRender(system: u64, buffers_address: u64, count: u32) callconv(abi.guest) i32 {
    if (system == 0) return errno.KernelError.einval.raw();
    if (count == 0) {
        ngs2_mutex.lock();
        defer ngs2_mutex.unlock();
        return if (ngs2FindSystem(system) == null) errno.KernelError.einval.raw() else errno.ok;
    }
    if (buffers_address == 0 or count > 32 or
        !kernel_memory.isGuestRangeAccessible(buffers_address, @as(u64, count) * @sizeOf(Ngs2RenderBuffer)))
    {
        return errno.KernelError.efault.raw();
    }
    const buffers: [*]const Ngs2RenderBuffer = @ptrFromInt(buffers_address);
    const render_buffers = buffers[0..count];
    const frames = ngs2RenderFrameCount(render_buffers);
    var initial_positions: [maximum_ngs2_voices]f64 = @splat(0);
    var initial_playing: [maximum_ngs2_voices]bool = @splat(false);
    ngs2_mutex.lock();
    if (ngs2FindSystem(system) == null) {
        ngs2_mutex.unlock();
        return errno.KernelError.einval.raw();
    }
    ngs2ApplyEventsLocked(system);
    for (&ngs2_voices, 0..) |*voice, index| {
        initial_positions[index] = voice.position;
        initial_playing[index] = voice.state == .playing;
    }
    var advanced = false;
    for (render_buffers) |buffer| {
        if (buffer.address == 0 or buffer.size == 0) continue;
        if (buffer.size > 16 * 1024 * 1024 or
            !kernel_memory.isGuestRangeAccessible(buffer.address, buffer.size))
        {
            return errno.KernelError.efault.raw();
        }
        const destination: [*]u8 = @ptrFromInt(buffer.address);
        @memset(destination[0..buffer.size], 0);
        const usable = buffer.channels != 0 and buffer.channels <= 32 and
            buffer.size >= @as(u64, buffer.channels) * @sizeOf(f32);
        ngs2MixBufferLocked(system, buffer, frames, &initial_positions, &initial_playing, usable and !advanced);
        if (usable) advanced = true;
    }
    ngs2_mutex.unlock();
    const call_index = ngs2_render_calls.fetchAdd(1, .monotonic);
    if (call_index < 4) std.debug.print(
        "[audio] NGS2 render buffers={d} grain={d} frames @48000Hz\n",
        .{ count, frames },
    );
    // Treat the grain as a synchronous software-DSP quantum.  This preserves
    // the real-time contract even while the voice mixer is still incomplete.
    pace(frames, 48_000);
    return errno.ok;
}

fn ngs2VoiceGetState(handle: u64, state_address: u64, state_size: usize) callconv(abi.guest) i32 {
    ngs2_mutex.lock();
    const voice = ngs2FindVoice(handle) orelse {
        ngs2_mutex.unlock();
        return errno.KernelError.einval.raw();
    };
    const state_flags = ngs2StateFlags(voice.state);
    ngs2_mutex.unlock();
    if (state_address != 0 and state_size != 0) {
        const bounded_size = @min(state_size, 0x400);
        if (!kernel_memory.isGuestRangeAccessible(state_address, bounded_size)) return errno.KernelError.efault.raw();
        const destination: [*]u8 = @ptrFromInt(state_address);
        @memset(destination[0..bounded_size], 0);
        if (bounded_size >= @sizeOf(u32)) {
            const flags: *align(1) u32 = @ptrFromInt(state_address);
            flags.* = state_flags;
        }
    }
    return errno.ok;
}

fn ngs2VoiceGetStateFlags(handle: u64, output: ?*u32) callconv(abi.guest) i32 {
    const flags = output orelse return ngs2_error_invalid_output;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(flags), @sizeOf(u32))) return errno.KernelError.efault.raw();
    ngs2_mutex.lock();
    defer ngs2_mutex.unlock();
    const voice = ngs2FindVoice(handle) orelse return errno.KernelError.einval.raw();
    flags.* = ngs2StateFlags(voice.state);
    const log_index = ngs2_state_logs.fetchAdd(1, .monotonic);
    if (trace.isLive() and log_index < 128) std.debug.print(
        "[audio] NGS2 voice=0x{x} state={s} flags=0x{x}\n",
        .{ handle, @tagName(voice.state), flags.* },
    );
    return errno.ok;
}

fn ngs2PanInit(work_address: u64, _: u64, _: f32, _: u32) callconv(abi.guest) i32 {
    if (work_address == 0) return errno.KernelError.einval.raw();
    // The exact work area is SDK-private; callers only pass it back to the pan
    // query, so no host state has to be embedded in guest memory.
    return errno.ok;
}

fn ngs2PanGetVolumeMatrix(_: u64, _: u64, count: u32, format: u32, output_address: u64) callconv(abi.guest) i32 {
    if (count == 0) return errno.ok;
    const channel_count: usize = if (format == 0) 2 else @min(format, 8);
    const float_count = std.math.mul(usize, count, channel_count) catch return errno.KernelError.einval.raw();
    const byte_size = std.math.mul(usize, float_count, @sizeOf(f32)) catch return errno.KernelError.einval.raw();
    if (!kernel_memory.isGuestRangeAccessible(output_address, byte_size)) return errno.KernelError.efault.raw();
    const matrix: [*]f32 = @ptrFromInt(output_address);
    @memset(matrix[0..float_count], 0);
    for (0..count) |row| matrix[row * channel_count] = 1.0;
    return errno.ok;
}

const ngs2_exports = [_]symbols.Export{
    .{ .name = "sceNgs2CalcWaveformBlock", .function = trace.wrap("sceNgs2CalcWaveformBlock", &ngs2CalcWaveformBlock), .expect_id = "3pCNbVM11UA" },
    .{ .name = "sceNgs2ParseWaveformData", .function = trace.wrap("sceNgs2ParseWaveformData", &ngs2ParseWaveformData), .expect_id = "hyVLT2VlOYk" },
    .{ .name = "sceNgs2SystemCreateWithAllocator", .function = trace.wrap("sceNgs2SystemCreateWithAllocator", &ngs2SystemCreateWithAllocator), .expect_id = "mPYgU4oYpuY" },
    .{ .name = "sceNgs2RackCreateWithAllocator", .function = trace.wrap("sceNgs2RackCreateWithAllocator", &ngs2RackCreateWithAllocator), .expect_id = "U546k6orxQo" },
    .{ .name = "sceNgs2RackGetVoiceHandle", .function = trace.wrap("sceNgs2RackGetVoiceHandle", &ngs2RackGetVoiceHandle), .expect_id = "MwmHz8pAdAo" },
    .{ .name = "sceNgs2VoiceControl", .function = trace.wrap("sceNgs2VoiceControl", &ngs2VoiceControl), .expect_id = "uu94irFOGpA" },
    .{ .name = "sceNgs2VoiceRunCommands", .function = trace.wrap("sceNgs2VoiceRunCommands", &ngs2VoiceRunCommands), .expect_id = "AbYvTOZ8Pts" },
    .{ .name = "sceNgs2RackDestroy", .function = trace.wrap("sceNgs2RackDestroy", &ngs2RackDestroy), .expect_id = "lCqD7oycmIM" },
    .{ .name = "sceNgs2SystemDestroy", .function = trace.wrap("sceNgs2SystemDestroy", &ngs2SystemDestroy), .expect_id = "u-WrYDaJA3k" },
    .{ .name = "sceNgs2SystemRender", .function = trace.wrap("sceNgs2SystemRender", &ngs2SystemRender), .expect_id = "i0VnXM-C9fc" },
    .{ .name = "sceNgs2PanInit", .function = trace.wrap("sceNgs2PanInit", &ngs2PanInit), .expect_id = "xa8oL9dmXkM" },
    .{ .name = "sceNgs2PanGetVolumeMatrix", .function = trace.wrap("sceNgs2PanGetVolumeMatrix", &ngs2PanGetVolumeMatrix), .expect_id = "gbMKV+8Enuo" },
    .{ .name = "sceNgs2VoiceGetState", .function = trace.wrap("sceNgs2VoiceGetState", &ngs2VoiceGetState), .expect_id = "-TOuuAQ-buE" },
    .{ .name = "sceNgs2VoiceGetStateFlags", .function = trace.wrap("sceNgs2VoiceGetStateFlags", &ngs2VoiceGetStateFlags), .expect_id = "rEh728kXk3w" },
};

// libSceAudiodec ---------------------------------------------------------

const audiodec_type_atrac9: u32 = 1;
const audiodec_type_mp3: u32 = 2;
const audiodec_type_m4aac: u32 = 3;
const audiodec_word_24bit: i32 = 0;
const audiodec_word_16bit: i32 = 1;
const audiodec_word_float: i32 = 2;

const AudiodecAuInfo = extern struct {
    size: u32,
    address: ?[*]const u8,
    data_size: u32,
};

const AudiodecPcmItem = extern struct {
    size: u32,
    address: ?[*]u8,
    data_size: u32,
};

const AudiodecCtrl = extern struct {
    parameter: ?*anyopaque,
    bsi_info: ?*anyopaque,
    au_info: ?*AudiodecAuInfo,
    pcm_item: ?*AudiodecPcmItem,
};

const AudiodecParamAtrac9 = extern struct {
    size: u32,
    word_length: i32,
    config_data: [4]u8,
};

const AudiodecAtrac9Info = extern struct {
    size: u32,
    channels: u32,
    bitrate: u32,
    sample_rate: u32,
    superframe_size: u32,
    frames_in_superframe: u32,
    next_frame_size: u32,
    frame_samples: u32,
    result: i32,
};

const AudiodecParamMp3 = extern struct {
    size: u32,
    word_length: i32,
};

const AudiodecMp3Info = extern struct {
    size: u32,
    header: u32,
    crc: u8,
    mode: u8,
    mode_extension: u8,
    copyright: u8,
    original: u8,
    emphasis: u8,
    reserved: [2]u8,
    result: i32,
};

const AudiodecParamM4aac = extern struct {
    size: u32,
    word_length: i32,
    config_number: u32,
    sample_rate_index: u32,
    maximum_channels: u32,
    enable_heaac: u32,
};

const AudiodecM4aacInfo = extern struct {
    size: u32,
    sample_rate: u32,
    channels: u32,
    heaac: u32,
    result: i32,
};

const LegacyAudiodec = struct {
    active: bool = false,
    codec_type: u32 = 0,
    word_length: i32 = audiodec_word_16bit,
    channels: u32 = 2,
    sample_rate: u32 = 48_000,
    frame_bytes: u32 = 1441,
    frame_samples: u32 = 1152,
    decoder: ajm_codec.Decoder = .{},
};

const maximum_audiodec_instances = 64;
var audiodec_mutex: Lock = .{};
var audiodec_init_count: [4]u32 = @splat(0);
var audiodec_instances: [maximum_audiodec_instances]LegacyAudiodec =
    [_]LegacyAudiodec{.{}} ** maximum_audiodec_instances;

fn validAudiodecType(codec_type: u32) bool {
    return codec_type >= audiodec_type_atrac9 and codec_type <= audiodec_type_m4aac;
}

fn audiodecWordBytes(word_length: i32) ?u32 {
    return switch (word_length) {
        audiodec_word_16bit => 2,
        audiodec_word_24bit, audiodec_word_float => 4,
        else => null,
    };
}

fn audiodecFlags(word_length: i32) ?u64 {
    const encoding: u64 = switch (word_length) {
        audiodec_word_16bit => 0,
        audiodec_word_24bit => 1,
        audiodec_word_float => 2,
        else => return null,
    };
    return encoding << 7;
}

fn audiodecSampleRate(index: u32) u32 {
    const rates = [_]u32{ 96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000 };
    return if (index < rates.len) rates[index] else 48_000;
}

fn validateAudiodecCtrl(ctrl: ?*AudiodecCtrl, codec_type: u32, decode: bool) i32 {
    const control = ctrl orelse return audiodec_error_invalid_ctrl_pointer;
    if (control.parameter == null) return audiodec_error_invalid_param_pointer;
    if (control.bsi_info == null) return audiodec_error_invalid_bsi_info_pointer;
    const au = control.au_info orelse return audiodec_error_invalid_au_info_pointer;
    const pcm = control.pcm_item orelse return audiodec_error_invalid_pcm_item_pointer;
    if (au.size != @sizeOf(AudiodecAuInfo)) return audiodec_error_invalid_au_info_size;
    if (pcm.size != @sizeOf(AudiodecPcmItem)) return audiodec_error_invalid_pcm_item_size;
    if (decode and au.address == null) return audiodec_error_invalid_au_pointer;
    if (decode and pcm.address == null) return audiodec_error_invalid_pcm_pointer;

    const word_length = switch (codec_type) {
        audiodec_type_atrac9 => blk: {
            const parameter: *const AudiodecParamAtrac9 = @ptrCast(@alignCast(control.parameter.?));
            const info: *const AudiodecAtrac9Info = @ptrCast(@alignCast(control.bsi_info.?));
            if (parameter.size != @sizeOf(AudiodecParamAtrac9)) return audiodec_error_invalid_param_size;
            if (info.size != @sizeOf(AudiodecAtrac9Info)) return audiodec_error_invalid_bsi_info_size;
            break :blk parameter.word_length;
        },
        audiodec_type_mp3 => blk: {
            const parameter: *const AudiodecParamMp3 = @ptrCast(@alignCast(control.parameter.?));
            const info: *const AudiodecMp3Info = @ptrCast(@alignCast(control.bsi_info.?));
            if (parameter.size != @sizeOf(AudiodecParamMp3)) return audiodec_error_invalid_param_size;
            if (info.size != @sizeOf(AudiodecMp3Info)) return audiodec_error_invalid_bsi_info_size;
            break :blk parameter.word_length;
        },
        audiodec_type_m4aac => blk: {
            const parameter: *const AudiodecParamM4aac = @ptrCast(@alignCast(control.parameter.?));
            const info: *const AudiodecM4aacInfo = @ptrCast(@alignCast(control.bsi_info.?));
            if (parameter.size < @sizeOf(AudiodecParamM4aac)) return audiodec_error_invalid_param_size;
            if (info.size != @sizeOf(AudiodecM4aacInfo)) return audiodec_error_invalid_bsi_info_size;
            break :blk parameter.word_length;
        },
        else => return audiodec_error_invalid_type,
    };
    if (audiodecWordBytes(word_length) == null) return audiodec_error_invalid_word_length;
    if (decode and au.data_size == 0) return audiodec_error_invalid_au_size;
    if (decode and pcm.data_size == 0) return audiodec_error_invalid_pcm_size;
    return errno.ok;
}

fn fillAudiodecInfo(ctrl: *AudiodecCtrl, instance: *const LegacyAudiodec) void {
    switch (instance.codec_type) {
        audiodec_type_atrac9 => {
            const output: *AudiodecAtrac9Info = @ptrCast(@alignCast(ctrl.bsi_info.?));
            const info = instance.decoder.codecInfo();
            output.channels = if (info.channels != 0) info.channels else instance.channels;
            output.bitrate = info.bitrate;
            output.sample_rate = if (info.sample_rate != 0) info.sample_rate else instance.sample_rate;
            output.superframe_size = if (info.superframe_size != 0) info.superframe_size else instance.frame_bytes;
            output.frames_in_superframe = if (info.frames_in_superframe != 0) info.frames_in_superframe else 1;
            output.next_frame_size = if (info.next_frame_size != 0) info.next_frame_size else output.superframe_size;
            output.frame_samples = if (info.frame_samples != 0) info.frame_samples else instance.frame_samples;
            output.result = 0;
        },
        audiodec_type_mp3 => {
            const output: *AudiodecMp3Info = @ptrCast(@alignCast(ctrl.bsi_info.?));
            const info = instance.decoder.codecInfo();
            output.header = info.mp3_header;
            output.crc = 0;
            output.mode = if (info.channels == 1) 3 else 0;
            output.mode_extension = 0;
            output.copyright = 0;
            output.original = 0;
            output.emphasis = 0;
            output.reserved = .{ 0, 0 };
            output.result = 0;
        },
        audiodec_type_m4aac => {
            const output: *AudiodecM4aacInfo = @ptrCast(@alignCast(ctrl.bsi_info.?));
            const info = instance.decoder.codecInfo();
            output.sample_rate = if (info.sample_rate != 0) info.sample_rate else instance.sample_rate;
            output.channels = if (info.channels != 0) info.channels else instance.channels;
            output.heaac = info.heaac;
            output.result = 0;
        },
        else => {},
    }
}

fn audiodecInitLibrary(codec_type: u32) callconv(abi.guest) i32 {
    if (!validAudiodecType(codec_type)) return audiodec_error_invalid_type;
    audiodec_mutex.lock();
    defer audiodec_mutex.unlock();
    audiodec_init_count[codec_type] +|= 1;
    return errno.ok;
}

fn audiodecTermLibrary(codec_type: u32) callconv(abi.guest) i32 {
    if (!validAudiodecType(codec_type)) return audiodec_error_invalid_type;
    audiodec_mutex.lock();
    defer audiodec_mutex.unlock();
    if (audiodec_init_count[codec_type] != 0) audiodec_init_count[codec_type] -= 1;
    return errno.ok;
}

fn audiodecCreateDecoder(ctrl: ?*AudiodecCtrl, codec_type: u32) callconv(abi.guest) i32 {
    if (!validAudiodecType(codec_type)) return audiodec_error_invalid_type;
    const status = validateAudiodecCtrl(ctrl, codec_type, false);
    if (status != errno.ok) return status;
    const control = ctrl.?;

    audiodec_mutex.lock();
    defer audiodec_mutex.unlock();
    if (audiodec_init_count[codec_type] == 0) return audiodec_error_argument;

    for (&audiodec_instances, 0..) |*slot, index| {
        if (slot.active) continue;
        var instance = LegacyAudiodec{ .active = true, .codec_type = codec_type };
        switch (codec_type) {
            audiodec_type_atrac9 => {
                const parameter: *const AudiodecParamAtrac9 = @ptrCast(@alignCast(control.parameter.?));
                instance.word_length = parameter.word_length;
                instance.frame_bytes = 2048;
                instance.frame_samples = 256;
                instance.decoder = ajm_codec.Decoder.create(ajm_codec.codec_atrac9, audiodecFlags(parameter.word_length).?) catch
                    return audiodec_error_argument;
                const initialized = instance.decoder.initialize(&parameter.config_data);
                if (initialized.result != 0) {
                    instance.decoder.deinit();
                    return audiodec_error_argument;
                }
                const info = instance.decoder.codecInfo();
                instance.channels = info.channels;
                instance.sample_rate = info.sample_rate;
                instance.frame_bytes = info.superframe_size;
                instance.frame_samples = info.frame_samples;
            },
            audiodec_type_mp3 => {
                const parameter: *const AudiodecParamMp3 = @ptrCast(@alignCast(control.parameter.?));
                instance.word_length = parameter.word_length;
                instance.decoder = ajm_codec.Decoder.create(ajm_codec.codec_mp3, audiodecFlags(parameter.word_length).?) catch
                    return audiodec_error_argument;
                _ = instance.decoder.initialize(&.{});
            },
            audiodec_type_m4aac => {
                const parameter: *const AudiodecParamM4aac = @ptrCast(@alignCast(control.parameter.?));
                instance.word_length = parameter.word_length;
                instance.channels = @min(if (parameter.maximum_channels == 0) 2 else parameter.maximum_channels, 8);
                instance.sample_rate = audiodecSampleRate(parameter.sample_rate_index);
                instance.frame_bytes = 2048;
                instance.frame_samples = 1024;
                const flags = (audiodecFlags(parameter.word_length) orelse 0) |
                    instance.channels |
                    (if (parameter.enable_heaac != 0) @as(u64, 1) << 32 else 0);
                instance.decoder = ajm_codec.Decoder.create(ajm_codec.codec_m4aac, flags) catch
                    return audiodec_error_argument;
                var init_bytes: [8]u8 = undefined;
                std.mem.writeInt(u32, init_bytes[0..4], parameter.config_number, .little);
                std.mem.writeInt(u32, init_bytes[4..8], parameter.sample_rate_index, .little);
                const initialized = instance.decoder.initialize(&init_bytes);
                if (initialized.result != 0) {
                    instance.decoder.deinit();
                    return audiodec_error_argument;
                }
                const info = instance.decoder.codecInfo();
                if (info.channels != 0) instance.channels = info.channels;
                if (info.sample_rate != 0) instance.sample_rate = info.sample_rate;
                if (info.frame_samples != 0) instance.frame_samples = info.frame_samples;
            },
            else => unreachable,
        }
        slot.* = instance;
        fillAudiodecInfo(control, slot);
        std.debug.print(
            "[audio audiodec] create handle={d} codec={s} format={d}\n",
            .{ index + 1, if (codec_type == audiodec_type_mp3) "mp3" else if (codec_type == audiodec_type_atrac9) "atrac9" else "aac", instance.word_length },
        );
        return @intCast(index + 1);
    }
    return audiodec_error_argument;
}

fn audiodecDeleteDecoder(handle: i32) callconv(abi.guest) i32 {
    if (handle <= 0 or handle > maximum_audiodec_instances) return audiodec_error_invalid_handle;
    audiodec_mutex.lock();
    defer audiodec_mutex.unlock();
    const instance = &audiodec_instances[@intCast(handle - 1)];
    if (!instance.active) return audiodec_error_invalid_handle;
    instance.decoder.deinit();
    instance.* = .{};
    return errno.ok;
}

fn audiodecDecode(handle: i32, ctrl: ?*AudiodecCtrl) callconv(abi.guest) i32 {
    if (handle <= 0 or handle > maximum_audiodec_instances) return audiodec_error_invalid_handle;
    audiodec_mutex.lock();
    defer audiodec_mutex.unlock();
    const instance = &audiodec_instances[@intCast(handle - 1)];
    if (!instance.active) return audiodec_error_invalid_handle;
    const status = validateAudiodecCtrl(ctrl, instance.codec_type, true);
    if (status != errno.ok) return status;
    const control = ctrl.?;
    const au = control.au_info.?;
    const pcm = control.pcm_item.?;
    const input = au.address.?[0..au.data_size];
    const output = pcm.address.?[0..pcm.data_size];

    const report = instance.decoder.decode(input, output);
    au.data_size = @intCast(report.consumed);
    pcm.data_size = @intCast(report.produced);
    if (report.frames == 0 and report.consumed == 0) return audiodec_error_argument;
    const info = instance.decoder.codecInfo();
    if (info.channels != 0) instance.channels = info.channels;
    if (info.sample_rate != 0) instance.sample_rate = info.sample_rate;
    if (info.frame_samples != 0) instance.frame_samples = info.frame_samples;
    fillAudiodecInfo(control, instance);
    return errno.ok;
}

fn audiodecClearContext(handle: i32) callconv(abi.guest) i32 {
    if (handle <= 0 or handle > maximum_audiodec_instances) return audiodec_error_invalid_handle;
    audiodec_mutex.lock();
    defer audiodec_mutex.unlock();
    const instance = &audiodec_instances[@intCast(handle - 1)];
    if (!instance.active) return audiodec_error_invalid_handle;
    instance.decoder.reset();
    return errno.ok;
}

const audiodec_exports = [_]symbols.Export{
    .{ .name = "sceAudiodecInitLibrary", .function = trace.wrap("sceAudiodecInitLibrary", &audiodecInitLibrary), .expect_id = "VjhsmxpcezI" },
    .{ .name = "sceAudiodecTermLibrary", .function = trace.wrap("sceAudiodecTermLibrary", &audiodecTermLibrary), .expect_id = "h5jSB2QIDV0" },
    .{ .name = "sceAudiodecDeleteDecoder", .function = trace.wrap("sceAudiodecDeleteDecoder", &audiodecDeleteDecoder), .expect_id = "Tp+ZEy69mLk" },
    .{ .name = "sceAudiodecDecode", .function = trace.wrap("sceAudiodecDecode", &audiodecDecode), .expect_id = "KHXHMDLkILw" },
    .{ .name = "sceAudiodecClearContext", .function = trace.wrap("sceAudiodecClearContext", &audiodecClearContext), .expect_id = "6Vf9WTLDoss" },
    .{ .name = "sceAudiodecCreateDecoder", .function = trace.wrap("sceAudiodecCreateDecoder", &audiodecCreateDecoder), .expect_id = "O3f1sLMWRvs" },
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
    if (!ajm_codec.isSupported(codec)) return ajm_error_codec_not_supported;
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
    if (!ajm_codec.isSupported(codec)) return ajm_error_codec_not_supported;
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
            .{ id, ajm_codec.codecName(codec), flags, (flags >> 7) & 7, flags & 0x7f },
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
            } else if (candidate.codec == ajm_codec.codec_m4aac and output_size >= 16) {
                std.mem.writeInt(u32, output[8..12], codec_info.heaac, .little);
                std.mem.writeInt(u32, output[12..16], 0, .little);
            } else if (candidate.codec == ajm_codec.codec_opus and output_size >= 12) {
                std.mem.writeInt(u32, output[8..12], codec_info.frames_per_packet, .little);
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
    device_owner.store(-1, .release);
    device_owner_last_signal_ms.store(0, .release);

    port_mutex.lock();
    legacy_ports = [_]LegacyPort{.{}} ** maximum_legacy_ports;
    port_mutex.unlock();

    audio_object_mutex.lock();
    audio_objects = [_]AudioObject{.{}} ** maximum_audio_objects;
    audio_object_mutex.unlock();

    audiodec_mutex.lock();
    for (&audiodec_instances) |*instance| if (instance.active) instance.decoder.deinit();
    audiodec_init_count = @splat(0);
    audiodec_instances = [_]LegacyAudiodec{.{}} ** maximum_audiodec_instances;
    audiodec_mutex.unlock();

    ajm_mutex.lock();
    for (&ajm_instances) |*instance| if (instance.active) instance.decoder.deinit();
    ajm_contexts = [_]bool{false} ** maximum_ajm_contexts;
    ajm_modules = [_][maximum_ajm_codecs]bool{[_]bool{false} ** maximum_ajm_codecs} ** maximum_ajm_contexts;
    ajm_instances = [_]AjmInstance{.{}} ** maximum_ajm_instances;
    ajm_mutex.unlock();
    next_batch.store(1, .monotonic);
    ngs2_mutex.lock();
    for (&ngs2_voices) |*voice| ngs2FreeVoiceWaveform(voice);
    for (&ngs2_waveform_cache, 0..) |*cached, index| {
        cached.references = 0;
        ngs2EvictCachedWaveform(index);
    }
    ngs2_waveform_cache = [_]Ngs2CachedWaveform{.{}} ** maximum_ngs2_cached_waveforms;
    ngs2_waveform_cache_bytes = 0;
    ngs2_waveform_cache_sequence = 0;
    ngs2_systems = [_]Ngs2System{.{}} ** maximum_ngs2_systems;
    ngs2_racks = [_]Ngs2Rack{.{}} ** maximum_ngs2_racks;
    ngs2_voices = [_]Ngs2Voice{.{}} ** maximum_ngs2_voices;
    ngs2_mutex.unlock();
    next_ngs2_handle.store(0x4e47_0001, .monotonic);
    ngs2_render_calls.store(0, .monotonic);
    ngs2_control_logs.store(0, .monotonic);
    ngs2_state_logs.store(0, .monotonic);
    ngs2_waveform_logs.store(0, .monotonic);
    ngs2_command_logs.store(0, .monotonic);
    ajm_decode_jobs.store(0, .monotonic);
    audio_out_play_ok.store(0, .monotonic);
    audio_out_play_silent.store(0, .monotonic);
    audio_out_play_fail.store(0, .monotonic);
    audio_test_tone_phase = 0;
    audio_test_tone_enabled = null;
    audio_disabled = null;
    host_target_latency_ms.store(audio_device.default_target_latency_ms, .release);
}

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libSceAudioOut", .version = 1 }, .{ .name = "libSceAudioOut" }, &audio_out_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAudioIn", .version = 1 }, .{ .name = "libSceAudioIn" }, &audio_in_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAudioOut2", .version = 1 }, .{ .name = "libSceAudioOut" }, &audio_out2_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAudiodec", .version = 1 }, .{ .name = "libSceAudiodec" }, &audiodec_exports);
    try db.addLibrary(gpa, .{ .name = "libSceNgs2", .version = 1 }, .{ .name = "libSceNgs2" }, &ngs2_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAjm", .version = 1 }, .{ .name = "libSceAjm" }, &ajm_exports);
}

test "legacy AudioOut formats distinguish standard 8-channel integer and float PCM" {
    try std.testing.expectEqual(@as(?u8, 8), formatChannels(6));
    try std.testing.expectEqual(audio_device.SampleFormat.signed16, formatSamples(6).?);
    try std.testing.expectEqual(@as(?u8, 8), formatChannels(7));
    try std.testing.expectEqual(audio_device.SampleFormat.float32, formatSamples(7).?);
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
    var port: u64 = 0;
    const port_parameters = AudioOut2PortParam{
        .port_type = 0,
        .padding = 0,
        .data_format = 8 << 8,
        .sampling_frequency = 48_000,
        .flags = 0,
        .user_handle = 0,
        .reserved = [_]u32{0} ** 10,
    };
    try std.testing.expectEqual(errno.ok, audioOut2PortCreate(context, &port_parameters, &port));
    var state: [audio_out2_port_state_bytes]u8 = @splat(0xab);
    try std.testing.expectEqual(errno.ok, audioOut2PortGetState(port, &state));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, state[0x00..0x02], .little));
    try std.testing.expectEqual(@as(u8, 8), state[0x02]);
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, state[0x04..0x06], .little));
    try std.testing.expectEqual(@as(u8, 0), state[0x10]);
    try std.testing.expectEqual(audio_out2_error_invalid_parameter, audioOut2PortGetState(port, null));
}

test "NGS2 derives one bounded float32 render grain from all buses" {
    const buffers = [_]Ngs2RenderBuffer{
        .{ .address = 1, .size = 8192, .waveform_type = 0x18, .channels = 8 },
        .{ .address = 2, .size = 1024, .waveform_type = 0x18, .channels = 1 },
        .{ .address = 3, .size = 0, .waveform_type = 0x18, .channels = 2 },
    };
    try std.testing.expectEqual(@as(u32, 256), ngs2RenderFrameCount(&buffers));
    try std.testing.expectEqual(@as(u32, 4096), ngs2RenderFrameCount(&.{
        .{ .address = 1, .size = 1024 * 1024, .waveform_type = 0x18, .channels = 1 },
    }));
    try std.testing.expectEqual(@as(u32, 0), ngs2RenderFrameCount(&.{
        .{ .address = 1, .size = 1024, .waveform_type = 0x18, .channels = 0 },
    }));
}

test "NGS2 decodes and mixes PCM waveforms used by sampler voices" {
    reset();
    defer reset();

    var wave: [60]u8 = @splat(0);
    @memcpy(wave[0..4], "RIFF");
    std.mem.writeInt(u32, wave[4..8], wave.len - 8, .little);
    @memcpy(wave[8..12], "WAVE");
    @memcpy(wave[12..16], "fmt ");
    std.mem.writeInt(u32, wave[16..20], 16, .little);
    std.mem.writeInt(u16, wave[20..22], 1, .little);
    std.mem.writeInt(u16, wave[22..24], 2, .little);
    std.mem.writeInt(u32, wave[24..28], 48_000, .little);
    std.mem.writeInt(u32, wave[28..32], 48_000 * 4, .little);
    std.mem.writeInt(u16, wave[32..34], 4, .little);
    std.mem.writeInt(u16, wave[34..36], 16, .little);
    @memcpy(wave[36..40], "data");
    std.mem.writeInt(u32, wave[40..44], 16, .little);
    const pcm = [_]i16{ 32_767, -32_768, 16_384, -16_384, 8_192, -8_192, 0, 0 };
    for (pcm, 0..) |sample, index| {
        std.mem.writeInt(i16, wave[44 + index * 2 ..][0..2], sample, .little);
    }

    const decoded = ngs2DecodeWave(@intFromPtr(&wave)).?;
    defer std.heap.page_allocator.free(decoded.samples);
    try std.testing.expectEqual(@as(u32, 48_000), decoded.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), decoded.channels);
    try std.testing.expectEqual(@as(usize, pcm.len), decoded.samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 32_767.0 / 32_768.0), decoded.samples[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), decoded.samples[1], 0.0001);

    var system: u64 = 0;
    var rack: u64 = 0;
    var voice: u64 = 0;
    try std.testing.expectEqual(errno.ok, ngs2SystemCreateWithAllocator(0, 0, &system));
    try std.testing.expectEqual(errno.ok, ngs2RackCreateWithAllocator(system, 0x1000, 0, 0, &rack));
    try std.testing.expectEqual(errno.ok, ngs2RackGetVoiceHandle(rack, 0, &voice));
    var waveform = Ngs2VoiceWaveformParam{
        .header = .{ .size = @sizeOf(Ngs2VoiceWaveformParam), .next = 0, .id = 0x1000_0001 },
        .data_address = @intFromPtr(&wave),
    };
    try std.testing.expectEqual(errno.ok, ngs2VoiceControl(voice, @intFromPtr(&waveform)));

    var output: [8]f32 = @splat(0);
    const render = [_]Ngs2RenderBuffer{.{
        .address = @intFromPtr(&output),
        .size = @sizeOf(@TypeOf(output)),
        .waveform_type = 0x18,
        .channels = 2,
    }};
    try std.testing.expectEqual(errno.ok, ngs2SystemRender(system, @intFromPtr(&render), render.len));
    try std.testing.expectApproxEqAbs(@as(f32, 32_767.0 / 32_768.0), output[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), output[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), output[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), output[3], 0.0001);

    @memset(&output, 0);
    try std.testing.expectEqual(errno.ok, ngs2VoiceControl(voice, @intFromPtr(&waveform)));
    try std.testing.expectEqual(errno.ok, ngs2SystemRender(system, @intFromPtr(&render), render.len));
    try std.testing.expectApproxEqAbs(@as(f32, 32_767.0 / 32_768.0), output[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), output[1], 0.0001);

    var compact_commands = [_]u64{ 0x0000_0400_0000_0002, 1, 0xd8, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(
        errno.ok,
        ngs2VoiceRunCommands(voice, @intFromPtr(&compact_commands), 1, 0),
    );

    var second_voice: u64 = 0;
    try std.testing.expectEqual(errno.ok, ngs2RackGetVoiceHandle(rack, 1, &second_voice));
    try std.testing.expectEqual(errno.ok, ngs2VoiceControl(second_voice, @intFromPtr(&waveform)));
    ngs2_mutex.lock();
    const first = ngs2FindVoice(voice).?;
    const second = ngs2FindVoice(second_voice).?;
    const first_cache = first.waveform_cache_index;
    const second_cache = second.waveform_cache_index;
    const first_samples = @intFromPtr(first.samples.ptr);
    const second_samples = @intFromPtr(second.samples.ptr);
    const references = ngs2_waveform_cache[first_cache.?].references;
    ngs2_mutex.unlock();
    try std.testing.expectEqual(first_cache, second_cache);
    try std.testing.expectEqual(first_samples, second_samples);
    try std.testing.expectEqual(@as(u16, 2), references);
}

test "NGS2 voice handles are stable and state flags preserve adjacent guest data" {
    reset();
    var system: u64 = 0;
    var rack: u64 = 0;
    var voice: u64 = 0;
    try std.testing.expectEqual(errno.ok, ngs2SystemCreateWithAllocator(0, 0, &system));
    try std.testing.expectEqual(errno.ok, ngs2RackCreateWithAllocator(system, 0x1000, 0, 0, &rack));
    try std.testing.expectEqual(errno.ok, ngs2RackGetVoiceHandle(rack, 7, &voice));
    var same_voice: u64 = 0;
    try std.testing.expectEqual(errno.ok, ngs2RackGetVoiceHandle(rack, 7, &same_voice));
    try std.testing.expectEqual(voice, same_voice);

    var event = Ngs2VoiceEventParam{
        .header = .{ .size = @sizeOf(Ngs2VoiceEventParam), .next = 0, .id = 0x0006 },
        .event_id = 0x0001,
    };
    try std.testing.expectEqual(errno.ok, ngs2VoiceControl(voice, @intFromPtr(&event)));
    ngs2_mutex.lock();
    ngs2ApplyEventsLocked(system);
    ngs2_mutex.unlock();

    var result = extern struct {
        flags: u32 = 0,
        canary: u32 = 0xa5a5_5a5a,
    }{};
    try std.testing.expectEqual(errno.ok, ngs2VoiceGetStateFlags(voice, &result.flags));
    try std.testing.expectEqual(@as(u32, 0x3), result.flags);
    try std.testing.expectEqual(@as(u32, 0xa5a5_5a5a), result.canary);

    event.event_id = 0x0010;
    try std.testing.expectEqual(errno.ok, ngs2VoiceControl(voice, @intFromPtr(&event)));
    ngs2_mutex.lock();
    ngs2ApplyEventsLocked(system);
    ngs2_mutex.unlock();
    try std.testing.expectEqual(errno.ok, ngs2VoiceGetStateFlags(voice, &result.flags));
    try std.testing.expectEqual(@as(u32, 0x5), result.flags);

    event.event_id = 0x0004;
    try std.testing.expectEqual(errno.ok, ngs2VoiceControl(voice, @intFromPtr(&event)));
    ngs2_mutex.lock();
    ngs2ApplyEventsLocked(system);
    ngs2_mutex.unlock();
    try std.testing.expectEqual(errno.ok, ngs2VoiceGetStateFlags(voice, &result.flags));
    try std.testing.expectEqual(@as(u32, 0), result.flags);
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

test "AJM accepts MPEG-4 AAC and Opus instances" {
    reset();
    var context: u32 = 0;
    try std.testing.expectEqual(errno.ok, ajmInitialize(0, &context));
    try std.testing.expectEqual(errno.ok, ajmModuleRegister(context, ajm_codec.codec_m4aac, 0));
    try std.testing.expectEqual(errno.ok, ajmModuleRegister(context, ajm_codec.codec_opus, 0));
    var aac: u32 = 0;
    var opus: u32 = 0;
    try std.testing.expectEqual(errno.ok, ajmInstanceCreate(context, ajm_codec.codec_m4aac, 2, &aac));
    try std.testing.expectEqual(errno.ok, ajmInstanceCreate(context, ajm_codec.codec_opus, 2, &opus));
    try std.testing.expect(aac != 0);
    try std.testing.expect(opus != 0);
    try std.testing.expectEqual(ajm_error_codec_not_supported, ajmModuleRegister(context, 3, 0));
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
    try std.testing.expect(db.findById("gatEUKG+Ea4", .function) != null);
    try std.testing.expect(db.findById("39WxhR-ePew", .function) != null);
}
