// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! libSceVideodec2 lifecycle and host H.264 decoding into guest NV12 buffers.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const kernel_memory = @import("kernel_memory.zig");
const h264 = @import("videodec2_h264.zig");

fn hostTimestampNs() u64 {
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

extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

const error_argument_pointer: i32 = @bitCast(@as(u32, 0x811d_0102));
const error_decoder_instance: i32 = @bitCast(@as(u32, 0x811d_0103));
const error_compute_queue: i32 = @bitCast(@as(u32, 0x811d_0110));
const error_output_info: i32 = @bitCast(@as(u32, 0x811d_010f));

const minimum_memory_size: u64 = 16 * 1024 * 1024;

/// Smallest slot reported when a configuration names no picture size.
const minimum_frame_slot_size: u64 = 0x1000;

/// Bytes one decoded picture occupies, which is what a title reserves per slot.
///
/// A title divides its frame arena by this, so it has to describe a real
/// picture: too large and the arena holds none, too small and a decoded frame
/// has nowhere to go.
fn decodedFrameSlotSize(config: *const DecoderConfigInfo) u64 {
    if (config.max_frame_width <= 0 or config.max_frame_height <= 0) {
        return minimum_frame_slot_size;
    }
    const width: u64 = @intCast(config.max_frame_width);
    const height: u64 = @intCast(config.max_frame_height);
    const bytes = h264.pictureBytes(guestFramePitch(@intCast(width)), @intCast(height));
    return @max(minimum_frame_slot_size, std.mem.alignForward(u64, bytes, 0x100));
}

var announced_decoders: u8 = 0;
var announced_units: u8 = 0;
var published_pictures: u32 = 0;

/// Recognisable prefix for a decoder handle, so one that reaches a log or a
/// fault reads as this module's token rather than a guest address.
const decoder_token_base: u64 = 0x5644_4543_0000_0000;
var next_decoder_token: u64 = 0;
var drain_requests: u32 = 0;
/// Pictures handed to the display, which the next one waits behind.
var submitted_pictures: u64 = 0;
/// Longest a decode call is held for the display before giving up on it.
const maximum_pacing_wait_ms: u32 = 250;
var last_picture_deadline_ns: ?u64 = null;

pub const VideoFrameSink = struct {
    context: ?*anyopaque = null,
    submit: *const fn (?*anyopaque, u64, u32, u32, u32, []const u8) u64,
    finish: *const fn (?*anyopaque, u64) void,
    /// How many handed-over pictures have actually reached the display, which
    /// is what the next one waits behind.
    presented: *const fn (?*anyopaque) u64,
};

var global_frame_sink: ?VideoFrameSink = null;

pub fn attachVideoFrameSink(sink: ?VideoFrameSink) void {
    global_frame_sink = sink;
}

const ComputeMemoryInfo = extern struct {
    this_size: u64,
    cpu_gpu_memory_size: u64,
    cpu_gpu_memory: u64,
};

const ComputeConfigInfo = extern struct {
    this_size: u64,
    compute_pipe_id: u16,
    compute_queue_id: u16,
    check_memory_type: u8,
    reserved0: u8,
    reserved1: u16,
};

const DecoderConfigInfo = extern struct {
    this_size: u64,
    resource_type: u32,
    codec_type: u32,
    profile: u32,
    max_level: u32,
    max_frame_width: i32,
    max_frame_height: i32,
    max_dpb_frame_count: i32,
    decode_input_queue_depth: u32,
    compute_queue: u64,
    cpu_affinity_mask: u64,
    cpu_thread_priority: i32,
    optimize_progressive_video: u8,
    check_memory_type: u8,
    reserved0: u8,
    reserved1: u8,
    extra_config_info: u64,
};

const DecoderMemoryInfo = extern struct {
    this_size: u64,
    cpu_memory_size: u64,
    cpu_memory: u64,
    gpu_memory_size: u64,
    gpu_memory: u64,
    cpu_gpu_memory_size: u64,
    cpu_gpu_memory: u64,
    max_frame_buffer_size: u64,
    frame_buffer_alignment: u32,
    reserved0: u32,
};

const InputData = extern struct {
    this_size: u64,
    au_data: u64,
    au_size: u64,
    pts_data: u64,
    dts_data: u64,
    attached_data: u64,
};

const FrameBuffer = extern struct {
    this_size: u64,
    frame_buffer: u64,
    frame_buffer_size: u64,
    is_accepted: u8,
    reserved: [7]u8,
};

/// The caller supplies this_size (48 or 56), then tests is_valid at +8.
/// Width/pitch/height are 32-bit fields at +16/+20/+24. Yotei compares
/// is_valid to exactly 1 before queuing the picture and starting playback.
const OutputInfo = extern struct {
    this_size: u64,
    is_valid: u8,
    is_error_frame: u8,
    picture_count: u8,
    is_discarded_frame: u8,
    codec_type: u32,
    frame_width: u32,
    frame_pitch: u32,
    frame_height: u32,
    reserved: u32,
    frame_buffer: u64,
    frame_buffer_size: u64,
    frame_format: u32,
    frame_pitch_in_bytes: u32,
};

comptime {
    std.debug.assert(@sizeOf(ComputeMemoryInfo) == 24);
    std.debug.assert(@sizeOf(ComputeConfigInfo) == 16);
    std.debug.assert(@sizeOf(DecoderConfigInfo) == 72);
    std.debug.assert(@sizeOf(DecoderMemoryInfo) == 72);
    std.debug.assert(@sizeOf(InputData) == 48);
    std.debug.assert(@sizeOf(FrameBuffer) == 32);
    std.debug.assert(@sizeOf(OutputInfo) == 56);
}

fn accessible(pointer: anytype) bool {
    const value = pointer orelse return false;
    const T = @TypeOf(value.*);
    return kernel_memory.isGuestRangeAccessible(@intFromPtr(value), @sizeOf(T));
}

/// Reports how much backing a compute queue needs.
///
/// The title allocates from the size reported here and stores the result in
/// the same record before allocating the queue, so leaving the size alone
/// makes it allocate nothing and the allocation is then refused.
pub fn queryComputeMemoryInfo(info: ?*ComputeMemoryInfo) callconv(abi.guest) i32 {
    if (!accessible(info)) return error_argument_pointer;
    info.?.cpu_gpu_memory_size = minimum_memory_size;
    info.?.cpu_gpu_memory = 0;
    return errno.ok;
}

pub fn allocateComputeQueue(
    config: ?*const ComputeConfigInfo,
    memory: ?*const ComputeMemoryInfo,
    output: ?*u64,
) callconv(abi.guest) i32 {
    if (!accessible(config) or !accessible(memory) or !accessible(output)) {
        return error_argument_pointer;
    }
    const backing = memory.?.cpu_gpu_memory;
    if (backing == 0) return error_argument_pointer;
    output.?.* = backing;
    return errno.ok;
}

pub fn releaseComputeQueue(queue: u64) callconv(abi.guest) i32 {
    return if (queue != 0) errno.ok else error_compute_queue;
}

pub fn queryDecoderMemoryInfo(
    config: ?*const DecoderConfigInfo,
    memory: ?*DecoderMemoryInfo,
) callconv(abi.guest) i32 {
    if (!accessible(config) or !accessible(memory)) return error_argument_pointer;
    const output = memory.?;
    // Only the sizes this can actually speak for. A decoder that runs on the
    // host needs no guest-side working memory, and claiming some makes the
    // title reserve arenas for a decode that never touches them.
    output.cpu_memory_size = 0;
    output.cpu_gpu_memory_size = 0;
    // The frame-slot size is the one figure the title cannot do without: it
    // divides its frame arena by this to decide how many pictures it can hold,
    // so a zero here ends the setup before a single frame is decoded, and a
    // slot as large as the arena leaves room for none.
    output.max_frame_buffer_size = decodedFrameSlotSize(config.?);
    output.frame_buffer_alignment = 256;
    return errno.ok;
}

pub fn createDecoder(
    config: ?*const DecoderConfigInfo,
    memory: ?*const DecoderMemoryInfo,
    output: ?*u64,
) callconv(abi.guest) i32 {
    if (!accessible(config) or !accessible(memory) or !accessible(output)) {
        return error_argument_pointer;
    }
    // The handle is opaque to the title, which only hands it back, but it has
    // to tell one decoder from another. Neither field of the record it passes
    // can: this reports no working memory, so `cpu_memory` stays zero, and the
    // configuration is built on the caller's stack, so two decoders created
    // from the same call site share an address. A title that holds two at once
    // then drives both through whichever was created first, which breaks the
    // stream each of them is following. Issue a token of this module's own.
    next_decoder_token +%= 1;
    const handle = decoder_token_base | next_decoder_token;
    output.?.* = handle;
    const settings = config.?;
    if (settings.max_frame_width > 0 and settings.max_frame_height > 0) {
        _ = h264.ensureDecoder(
            handle,
            @intCast(settings.max_frame_width),
            @intCast(settings.max_frame_height),
        );
    }
    if (announced_decoders < 4) {
        announced_decoders += 1;
        std.debug.print(
            "[videodec] decoder codec={d} profile={d} level={d} {d}x{d} dpb={d} queue_depth={d} resource={d}" ++ "\n",
            .{
                settings.codec_type,
                settings.profile,
                settings.max_level,
                settings.max_frame_width,
                settings.max_frame_height,
                settings.max_dpb_frame_count,
                settings.decode_input_queue_depth,
                settings.resource_type,
            },
        );
    }
    return errno.ok;
}

pub fn deleteDecoder(decoder: u64) callconv(abi.guest) i32 {
    if (decoder == 0) return error_decoder_instance;
    if (global_frame_sink) |sink| sink.finish(sink.context, decoder);
    last_picture_deadline_ns = null;
    published_pictures = 0;
    h264.destroyDecoder(decoder);
    return errno.ok;
}

/// Decodes one access unit and, when a picture comes back, copies it into the
/// slot the title provided and describes it.
///
/// Returning false is the ordinary case early in a stream: H.264 needs several
/// units before a first picture, and reordering delays later ones.
fn publishDecodedPicture(
    decoder: u64,
    input: *const InputData,
    frame: *FrameBuffer,
    output: *OutputInfo,
) bool {
    if (input.au_data == 0 or input.au_size == 0) return false;
    const unit_length = std.math.cast(usize, input.au_size) orelse return false;
    if (!kernel_memory.isGuestRangeAccessible(input.au_data, input.au_size)) return false;
    const unit: [*]const u8 = @ptrFromInt(input.au_data);

    const picture = h264.decodeAccessUnit(decoder, unit[0..unit_length], 0) orelse return false;
    return handOverPicture(decoder, picture, frame, output);
}

/// Holds the title back until the picture handed over last has been shown.
///
/// A title decodes as fast as its pictures are accepted, which while frames are
/// expensive is far faster than they can be displayed. Pacing against a clock
/// alone does not help: the clip still runs to its end, and only the fraction
/// of it that happened to land on a flip is ever seen. Waiting for the display
/// makes the title advance a frame at a time, so the whole clip plays.
///
/// The wait is bounded. Presentation can stop for reasons that have nothing to
/// do with this -- a headless run, a window that is not drawing -- and a title
/// blocked forever in its decoder is worse than one whose movie runs fast.
fn waitForPreviousPicture(target_frame_interval_ns: u64) void {
    const sink = global_frame_sink orelse return;
    const target = submitted_pictures;
    var waited_ms: u32 = 0;
    while (sink.presented(sink.context) < target and waited_ms < maximum_pacing_wait_ms) {
        Sleep(1);
        waited_ms += 1;
    }
    // Advance the original schedule, not the actual wake time. Otherwise a
    // millisecond of Windows timer jitter accumulates on every decoded frame.
    var now = hostTimestampNs();
    if (now == 0) return;
    const deadline = pictureDeadline(last_picture_deadline_ns, now, target_frame_interval_ns);
    while (now < deadline) {
        Sleep(@intCast(@max(1, (deadline - now) / std.time.ns_per_ms)));
        now = hostTimestampNs();
        if (now == 0) return;
    }
    last_picture_deadline_ns = deadline;
}

fn pictureDeadline(previous: ?u64, now: u64, interval: u64) u64 {
    const next = (previous orelse return now) +| interval;
    // Rebase after a long pause instead of presenting a burst of stale frames.
    return if (now -| next > maximum_pacing_wait_ms * std.time.ns_per_ms) now else next;
}

test "video cadence does not accumulate wake jitter and rebases after pauses" {
    const interval: u64 = 33_333_333;
    var deadline: u64 = 1_000_000_000;
    for (0..300) |_| {
        deadline = pictureDeadline(deadline, deadline + interval + std.time.ns_per_ms, interval);
    }
    try std.testing.expectEqual(@as(u64, 1_000_000_000) + 300 * interval, deadline);
    const resumed = deadline + std.time.ns_per_s;
    try std.testing.expectEqual(resumed, pictureDeadline(deadline, resumed, interval));
}

/// Copies one decoded picture into the slot the title lent and describes it.
fn handOverPicture(decoder: u64, picture: h264.Picture, frame: *FrameBuffer, output: *OutputInfo) bool {
    if (frame.frame_buffer == 0) return false;
    const capacity = std.math.cast(usize, frame.frame_buffer_size) orelse return false;
    const guest_bytes = h264.pictureBytes(guestFramePitch(picture.width), picture.height);
    if (capacity < guest_bytes) return false;
    if (!kernel_memory.isGuestRangeAccessible(frame.frame_buffer, guest_bytes)) return false;

    waitForPreviousPicture(picture.frame_interval_ns);

    const destination: [*]u8 = @ptrFromInt(frame.frame_buffer);
    copyGuestPicture(picture, destination[0..@intCast(guest_bytes)]);

    if (global_frame_sink) |sink| {
        submitted_pictures = sink.submit(sink.context, decoder, picture.width, picture.height, picture.pitch, picture.bytes);
    }

    published_pictures += 1;
    if (published_pictures == 1) {
        kernel_memory.reportDirectMemoryAliases("decoded frame slot", frame.frame_buffer);
    }
    if (published_pictures <= 4 or published_pictures % 30 == 0) {
        std.debug.print(
            "[videodec] published picture #{d} ({d}x{d}, pitch={d}) into 0x{x}\n",
            .{ published_pictures, picture.width, picture.height, picture.pitch, frame.frame_buffer },
        );
    }
    describePicture(picture, frame, output);
    return true;
}

fn describePicture(picture: h264.Picture, frame: *FrameBuffer, output: *OutputInfo) void {
    fillNoPicture(frame, output);
    frame.is_accepted = 1;
    output.is_valid = 1;
    output.picture_count = 1;
    output.frame_width = picture.width;
    output.frame_pitch = guestFramePitch(picture.width);
    output.frame_height = picture.height;
    if (output.this_size >= @sizeOf(OutputInfo)) output.frame_pitch_in_bytes = output.frame_pitch;
}

/// The two NV12 planes are sampled as linear AGC textures, whose rows must
/// align to 256 bytes. A tight 1920-byte MFT pitch underallocates both planes:
/// the title rejects their combined texture size and polls until its 100 ms
/// timeout on every frame. Keep host decoder storage private and repack here.
fn guestFramePitch(width: u32) u32 {
    return std.mem.alignForward(u32, width, 256);
}

fn copyGuestPicture(picture: h264.Picture, destination: []u8) void {
    const pitch: usize = guestFramePitch(picture.width);
    const rows: usize = picture.height + picture.height / 2;
    if (pitch == picture.pitch) {
        @memcpy(destination[0 .. pitch * rows], picture.bytes[0 .. pitch * rows]);
        return;
    }
    for (0..rows) |row| {
        const target = destination[row * pitch ..][0..pitch];
        @memcpy(target[0..picture.width], picture.bytes[row * picture.pitch ..][0..picture.width]);
        @memset(target[picture.width..], 0);
    }
}

test "guest NV12 storage aligns both planes to AGC rows" {
    try std.testing.expectEqual(@as(u32, 2048), guestFramePitch(1920));
    var config = std.mem.zeroes(DecoderConfigInfo);
    config.max_frame_width = 1920;
    config.max_frame_height = 1088;
    try std.testing.expectEqual(@as(u64, 2048 * 1088 * 3 / 2), decodedFrameSlotSize(&config));
    var source: [6]u8 = .{ 16, 235, 17, 234, 128, 129 };
    var destination: [3 * 256 + 8]u8 = @splat(0xcd);
    const picture = h264.Picture{ .width = 2, .height = 2, .pitch = 2, .bytes = &source };
    copyGuestPicture(picture, destination[0 .. 3 * 256]);
    try std.testing.expectEqualSlices(u8, source[0..2], destination[0..2]);
    try std.testing.expectEqualSlices(u8, source[2..4], destination[256..258]);
    try std.testing.expectEqualSlices(u8, source[4..6], destination[512..514]);
    try std.testing.expect(std.mem.allEqual(u8, destination[2..256], 0));
    try std.testing.expect(std.mem.allEqual(u8, destination[514..768], 0));
    try std.testing.expect(std.mem.allEqual(u8, destination[768..], 0xcd));
}

/// Says no picture came of a call, which is the first thing every call reports
/// before a decoded one can replace it.
fn fillNoPicture(frame: *FrameBuffer, output: *OutputInfo) void {
    frame.is_accepted = 0;
    output.is_valid = 0;
    output.is_error_frame = 0;
    output.picture_count = 0;
    output.is_discarded_frame = 0;
    output.codec_type = 1; // AVC
    output.frame_width = 0;
    output.frame_pitch = 0;
    output.frame_height = 0;
    output.reserved = 0;
    output.frame_buffer = frame.frame_buffer;
    output.frame_buffer_size = frame.frame_buffer_size;
    if (output.this_size >= @sizeOf(OutputInfo)) {
        output.frame_format = 0; // default NV12
        output.frame_pitch_in_bytes = 0;
    }
}

pub fn decode(
    decoder: u64,
    input: ?*const InputData,
    frame: ?*FrameBuffer,
    output: ?*OutputInfo,
) callconv(abi.guest) i32 {
    if (decoder == 0) return error_decoder_instance;
    if (!accessible(input) or !accessible(frame) or !accessible(output)) {
        return error_argument_pointer;
    }
    if (announced_units < 4) {
        announced_units += 1;
        const unit = input.?;
        var prefix: [16]u8 = @splat(0);
        const readable = @min(prefix.len, unit.au_size);
        if (unit.au_data != 0 and readable != 0 and
            kernel_memory.isGuestRangeAccessible(unit.au_data, readable))
        {
            const source: [*]const u8 = @ptrFromInt(unit.au_data);
            @memcpy(prefix[0..readable], source[0..readable]);
        }
        var kinds: [32]u8 = @splat(0);
        var kind_count: usize = 0;
        if (unit.au_data != 0 and unit.au_size >= 5 and
            kernel_memory.isGuestRangeAccessible(unit.au_data, unit.au_size))
        {
            const all: [*]const u8 = @ptrFromInt(unit.au_data);
            const bytes = all[0..@intCast(unit.au_size)];
            var scan: usize = 0;
            while (scan + 4 < bytes.len and kind_count < kinds.len) : (scan += 1) {
                if (bytes[scan] != 0 or bytes[scan + 1] != 0 or bytes[scan + 2] != 1) continue;
                kinds[kind_count] = bytes[scan + 3] & 0x1f;
                kind_count += 1;
            }
        }
        std.debug.print(
            "[videodec] access unit size={d} frame_buffer=0x{x}/0x{x} nal_types={any} first={x}" ++ "\n",
            .{ unit.au_size, frame.?.frame_buffer, frame.?.frame_buffer_size, kinds[0..kind_count], prefix[0..readable] },
        );
    }
    if (publishDecodedPicture(decoder, input.?, frame.?, output.?)) return errno.ok;
    fillNoPicture(frame.?, output.?);
    return errno.ok;
}

/// Hands back what the decoder still holds once a title stops feeding it.
///
/// A title plays a clip to its end by submitting every access unit and then
/// asking here for the pictures the decoder was holding back to reorder.
/// Answering "no picture" to all of those drops the tail of the clip, and a
/// title waiting for it never moves on to the next one.
pub fn flush(
    decoder: u64,
    frame: ?*FrameBuffer,
    output: ?*OutputInfo,
) callconv(abi.guest) i32 {
    if (decoder == 0) return error_decoder_instance;
    if (!accessible(frame) or !accessible(output)) return error_argument_pointer;
    fillNoPicture(frame.?, output.?);
    const drained = h264.drainPicture(decoder);
    if (drained) |picture| {
        _ = handOverPicture(decoder, picture, frame.?, output.?);
    } else if (global_frame_sink) |sink| {
        sink.finish(sink.context, decoder);
    }
    drain_requests += 1;
    if (drain_requests <= 12) {
        std.debug.print(
            "[videodec] drain #{d}: {s}\n",
            .{ drain_requests, if (drained != null) "picture" else "nothing left" },
        );
    }
    return errno.ok;
}

pub fn reset(decoder: u64) callconv(abi.guest) i32 {
    if (decoder == 0) return error_decoder_instance;
    if (global_frame_sink) |sink| sink.finish(sink.context, decoder);
    // Everything already handed over belongs to the position being left.
    last_picture_deadline_ns = null;
    published_pictures = 0;
    h264.flushDecoder(decoder);
    return errno.ok;
}

pub fn getPictureInfo(
    output: ?*const OutputInfo,
    first: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (!accessible(output) or first == 0) return error_argument_pointer;
    return error_output_info;
}

test "a decoder reports a usable frame-slot size and claims no working memory" {
    var config = std.mem.zeroes(DecoderConfigInfo);
    var info = std.mem.zeroes(DecoderMemoryInfo);
    info.cpu_memory_size = 0xdead;
    info.cpu_gpu_memory_size = 0xbeef;

    try std.testing.expectEqual(errno.ok, queryDecoderMemoryInfo(&config, &info));

    // The title divides its frame arena by this to decide how many pictures it
    // can hold. A zero ends the setup before it decodes anything, which is how
    // Yotei's splash never reached sceVideodec2Decode.
    try std.testing.expect(info.max_frame_buffer_size != 0);
    // A host-side decoder needs no guest working memory, and claiming some
    // makes the title reserve arenas nothing ever writes to.
    try std.testing.expectEqual(@as(u64, 0), info.cpu_memory_size);
    try std.testing.expectEqual(@as(u64, 0), info.cpu_gpu_memory_size);
}

test "a compute queue is told how much backing to allocate" {
    var info = std.mem.zeroes(ComputeMemoryInfo);
    try std.testing.expectEqual(errno.ok, queryComputeMemoryInfo(&info));
    // The title allocates from this and stores the result before allocating
    // the queue; leaving it at zero makes that allocation refused.
    try std.testing.expect(info.cpu_gpu_memory_size != 0);
}

test "a reported picture puts its readiness where a title reads it" {
    var slot = std.mem.zeroes(FrameBuffer);
    var report = std.mem.zeroes(OutputInfo);
    report.this_size = @sizeOf(OutputInfo);
    slot.frame_buffer = 0x2000_1000;
    slot.frame_buffer_size = 2048 * 1088 * 3 / 2;
    fillNoPicture(&slot, &report);
    try std.testing.expectEqual(@as(u8, 0), report.is_valid);
    describePicture(.{ .width = 1920, .height = 1088, .pitch = 1920, .bytes = &.{} }, &slot, &report);
    const raw: *const [@sizeOf(OutputInfo)]u8 = @ptrCast(&report);
    try std.testing.expectEqual(@as(u64, 56), std.mem.readInt(u64, raw[0..8], .little));
    try std.testing.expectEqual(@as(u8, 1), raw[8]);
    try std.testing.expectEqual(@as(u8, 1), raw[10]);
    try std.testing.expectEqual(@as(u32, 1920), std.mem.readInt(u32, raw[16..20], .little));
    try std.testing.expectEqual(@as(u32, 2048), std.mem.readInt(u32, raw[20..24], .little));
    try std.testing.expectEqual(@as(u32, 1088), std.mem.readInt(u32, raw[24..28], .little));
    try std.testing.expectEqual(slot.frame_buffer, std.mem.readInt(u64, raw[32..40], .little));
    try std.testing.expectEqual(@as(u8, 1), slot.is_accepted);
    report.this_size = 48;
    report.frame_format = 0xaabbccdd;
    report.frame_pitch_in_bytes = 0x11223344;
    fillNoPicture(&slot, &report);
    try std.testing.expectEqual(@as(u32, 0xaabbccdd), report.frame_format);
    try std.testing.expectEqual(@as(u32, 0x11223344), report.frame_pitch_in_bytes);
}

test "Videodec2 ABI records retain SDK sizes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ComputeMemoryInfo));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(DecoderConfigInfo));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(OutputInfo));
}
