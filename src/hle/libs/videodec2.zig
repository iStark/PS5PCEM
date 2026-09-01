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

const error_argument_pointer: i32 = @bitCast(@as(u32, 0x811d_0102));
const error_decoder_instance: i32 = @bitCast(@as(u32, 0x811d_0103));
const error_compute_queue: i32 = @bitCast(@as(u32, 0x811d_0110));
const error_output_info: i32 = @bitCast(@as(u32, 0x811d_010f));

const minimum_memory_size: u64 = 16 * 1024 * 1024;

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
    padding: u32,
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
    output.cpu_memory_size = minimum_memory_size;
    output.cpu_memory = 0;
    output.gpu_memory_size = minimum_memory_size;
    output.gpu_memory = 0;
    output.cpu_gpu_memory_size = minimum_memory_size;
    output.cpu_gpu_memory = 0;
    output.max_frame_buffer_size = minimum_memory_size;
    output.frame_buffer_alignment = 0x100;
    output.reserved0 = 0;
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
    return errno.ok;
}

pub fn deleteDecoder(decoder: u64) callconv(abi.guest) i32 {
    return if (decoder != 0) errno.ok else error_decoder_instance;
}

fn fillNoPicture(frame: *FrameBuffer, output: *OutputInfo) void {
    frame.is_accepted = 1;
    output.is_valid = 0;
    output.is_error_frame = 0;
    output.picture_count = 0;
    output.is_discarded_frame = 0;
    output.codec_type = 0;
    output.frame_width = 0;
    output.frame_pitch = 0;
    output.frame_height = 0;
    output.padding = 0;
    output.frame_buffer = frame.frame_buffer;
    output.frame_buffer_size = frame.frame_buffer_size;
    output.frame_format = 0;
    output.frame_pitch_in_bytes = 0;
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
    return if (decoder != 0) errno.ok else error_decoder_instance;
}

pub fn getPictureInfo(
    output: ?*const OutputInfo,
    first: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (!accessible(output) or first == 0) return error_argument_pointer;
    return error_output_info;
}

test "Videodec2 ABI records retain SDK sizes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ComputeMemoryInfo));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(DecoderConfigInfo));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(OutputInfo));
}
