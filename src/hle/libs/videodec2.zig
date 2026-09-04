// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! CPU-visible libSceVideodec2 lifecycle.
//!
//! The hardware video decoder is not translated yet.  Titles still need its
//! memory-query and object contracts to succeed before they open movie data.
//! This implementation consumes access units and reports no completed picture;
//! that lets a player reach end-of-stream (and the title continue) without
//! claiming that an undecoded frame is valid.

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const kernel_memory = @import("kernel_memory.zig");
const h264 = @import("videodec2_h264.zig");

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
    const bytes = h264.pictureBytes(@intCast(width), @intCast(height));
    return @max(minimum_frame_slot_size, std.mem.alignForward(u64, bytes, 0x100));
}

var announced_decoders: u8 = 0;
var announced_units: u8 = 0;
var published_pictures: u32 = 0;

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

/// What a decode call reports back.
///
/// Only the prefix is named: a title reads the ready flag first and then the
/// picture size, and those are the fields whose meaning is established. The
/// remainder is left exactly as the title prepared it, because filling in
/// fields whose meaning is a guess is how a caller is told a picture is
/// something other than what it is.
const OutputInfo = extern struct {
    /// 0 = no picture from this call, 1 = one is waiting in the frame buffer.
    picture_ready: u8,
    reserved0: [7]u8,
    width: u64,
    height: u64,
    unnamed: [32]u8,
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
    // CPU memory is stable for the decoder lifetime and therefore makes a
    // useful opaque token without allocating host-side state.
    const handle = if (memory.?.cpu_memory != 0) memory.?.cpu_memory else @intFromPtr(config.?);
    output.?.* = handle;
    const settings = config.?;
    if (settings.max_frame_width > 0 and settings.max_frame_height > 0) {
        _ = h264.ensureDecoder(
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
    h264.destroyDecoder();
    return errno.ok;
}

/// Decodes one access unit and, when a picture comes back, copies it into the
/// slot the title provided and describes it.
///
/// Returning false is the ordinary case early in a stream: H.264 needs several
/// units before a first picture, and reordering delays later ones.
fn publishDecodedPicture(
    input: *const InputData,
    frame: *FrameBuffer,
    output: *OutputInfo,
) bool {
    if (input.au_data == 0 or input.au_size == 0) return false;
    const unit_length = std.math.cast(usize, input.au_size) orelse return false;
    if (!kernel_memory.isGuestRangeAccessible(input.au_data, input.au_size)) return false;
    const unit: [*]const u8 = @ptrFromInt(input.au_data);

    const picture = h264.decodeAccessUnit(unit[0..unit_length], 0) orelse return false;
    if (frame.frame_buffer == 0) return false;
    const capacity = std.math.cast(usize, frame.frame_buffer_size) orelse return false;
    if (capacity < picture.bytes.len) return false;
    if (!kernel_memory.isGuestRangeAccessible(frame.frame_buffer, picture.bytes.len)) return false;

    const destination: [*]u8 = @ptrFromInt(frame.frame_buffer);
    @memcpy(destination[0..picture.bytes.len], picture.bytes);

    published_pictures += 1;
    if (published_pictures <= 4 or published_pictures % 32 == 0) {
        std.debug.print(
            "[videodec] published picture #{d} into 0x{x}\n",
            .{ published_pictures, frame.frame_buffer },
        );
    }
    output.width = picture.width;
    output.height = picture.height;
    output.picture_ready = 1;
    return true;
}

/// Says no picture came of a call, which is the first thing every call reports
/// before a decoded one can replace it.
fn fillNoPicture(_: *FrameBuffer, output: *OutputInfo) void {
    output.picture_ready = 0;
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
    if (publishDecodedPicture(input.?, frame.?, output.?)) return errno.ok;
    fillNoPicture(frame.?, output.?);
    return errno.ok;
}

pub fn flush(
    decoder: u64,
    frame: ?*FrameBuffer,
    output: ?*OutputInfo,
) callconv(abi.guest) i32 {
    if (decoder == 0) return error_decoder_instance;
    if (!accessible(frame) or !accessible(output)) return error_argument_pointer;
    fillNoPicture(frame.?, output.?);
    return errno.ok;
}

pub fn reset(decoder: u64) callconv(abi.guest) i32 {
    if (decoder == 0) return error_decoder_instance;
    // Everything already handed over belongs to the position being left.
    h264.flushDecoder();
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
    report.unnamed[0] = 0xa5;

    fillNoPicture(&slot, &report);
    try std.testing.expectEqual(@as(u8, 0), report.picture_ready);

    report.width = 1920;
    report.height = 1088;
    report.picture_ready = 1;

    // The flag a title checks is the first byte of the record, and the size
    // follows it as two 64-bit halves. Reading them back through the raw bytes
    // is what catches a field drifting to another offset.
    const raw: *const [@sizeOf(OutputInfo)]u8 = @ptrCast(&report);
    try std.testing.expectEqual(@as(u8, 1), raw[0]);
    try std.testing.expectEqual(@as(u64, 1920), std.mem.readInt(u64, raw[8..16], .little));
    try std.testing.expectEqual(@as(u64, 1088), std.mem.readInt(u64, raw[16..24], .little));
    // Everything past the size belongs to the title.
    try std.testing.expectEqual(@as(u8, 0xa5), raw[24]);
}

test "Videodec2 ABI records retain SDK sizes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ComputeMemoryInfo));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(DecoderConfigInfo));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(OutputInfo));
}
