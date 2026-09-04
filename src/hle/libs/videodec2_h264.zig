// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Decoding of the H.264 access units a title hands to libSceVideodec2.
//!
//! Titles feed the decoder Annex B access units and expect decoded pictures
//! back in their own memory. Windows already carries an H.264 decoder, so one
//! is driven here rather than vendored: the Media Foundation transform accepts
//! the same Annex B bytes and returns NV12, which is the layout the guest
//! interface describes.
//!
//! Everything here is best effort. A host without the decoder, or a stream it
//! refuses, leaves decoding reporting no picture, which is exactly what the
//! interface said before any decoding existed.

const std = @import("std");
const builtin = @import("builtin");

pub const Picture = struct {
    width: u32,
    height: u32,
    /// Distance between the starts of two luma rows, in bytes.
    pitch: u32,
    /// NV12: `height` luma rows followed by `height / 2` interleaved chroma
    /// rows, both at `pitch`.
    bytes: []const u8,
};

const HRESULT = i32;
const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

fn failed(result: HRESULT) bool {
    return result < 0;
}

const need_more_input: HRESULT = @bitCast(@as(u32, 0xc00d_6d72));
const stream_change: HRESULT = @bitCast(@as(u32, 0xc00d_6d61));
const not_accepting: HRESULT = @bitCast(@as(u32, 0xc00d_36b5));

// Only the members this drives are named; the rest keep their slots so the
// vtable layout still matches what the runtime hands back.
const IUnknownVtable = extern struct {
    query_interface: *const anyopaque,
    add_ref: *const anyopaque,
    release: *const fn (*anyopaque) callconv(.winapi) u32,
};

const IMFTransformVtable = extern struct {
    base: IUnknownVtable,
    get_stream_limits: *const anyopaque,
    get_stream_count: *const anyopaque,
    get_stream_ids: *const anyopaque,
    get_input_stream_info: *const anyopaque,
    get_output_stream_info: *const fn (*anyopaque, u32, *OutputStreamInfo) callconv(.winapi) HRESULT,
    get_attributes: *const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT,
    get_input_stream_attributes: *const anyopaque,
    get_output_stream_attributes: *const anyopaque,
    delete_input_stream: *const anyopaque,
    add_input_streams: *const anyopaque,
    get_input_available_type: *const anyopaque,
    get_output_available_type: *const fn (*anyopaque, u32, u32, **anyopaque) callconv(.winapi) HRESULT,
    set_input_type: *const fn (*anyopaque, u32, ?*anyopaque, u32) callconv(.winapi) HRESULT,
    set_output_type: *const fn (*anyopaque, u32, ?*anyopaque, u32) callconv(.winapi) HRESULT,
    get_input_current_type: *const anyopaque,
    get_output_current_type: *const fn (*anyopaque, u32, **anyopaque) callconv(.winapi) HRESULT,
    get_input_status: *const anyopaque,
    get_output_status: *const anyopaque,
    set_output_bounds: *const anyopaque,
    process_event: *const anyopaque,
    process_message: *const fn (*anyopaque, u32, usize) callconv(.winapi) HRESULT,
    process_input: *const fn (*anyopaque, u32, *anyopaque, u32) callconv(.winapi) HRESULT,
    process_output: *const fn (*anyopaque, u32, u32, [*]OutputDataBuffer, *u32) callconv(.winapi) HRESULT,
};

const OutputStreamInfo = extern struct {
    flags: u32,
    size: u32,
    alignment: u32,
};

const OutputDataBuffer = extern struct {
    stream_id: u32,
    sample: ?*anyopaque,
    status: u32,
    events: ?*anyopaque,
};

const IMFAttributesVtable = extern struct {
    base: IUnknownVtable,
    get_item: *const anyopaque,
    get_item_type: *const anyopaque,
    compare_item: *const anyopaque,
    compare: *const anyopaque,
    get_uint32: *const fn (*anyopaque, *const GUID, *u32) callconv(.winapi) HRESULT,
    get_uint64: *const fn (*anyopaque, *const GUID, *u64) callconv(.winapi) HRESULT,
    get_double: *const anyopaque,
    get_guid: *const fn (*anyopaque, *const GUID, *GUID) callconv(.winapi) HRESULT,
    get_string_length: *const anyopaque,
    get_string: *const anyopaque,
    get_allocated_string: *const anyopaque,
    get_blob_size: *const anyopaque,
    get_blob: *const anyopaque,
    get_allocated_blob: *const anyopaque,
    get_unknown: *const anyopaque,
    set_item: *const anyopaque,
    delete_item: *const anyopaque,
    delete_all_items: *const anyopaque,
    set_uint32: *const fn (*anyopaque, *const GUID, u32) callconv(.winapi) HRESULT,
    set_uint64: *const fn (*anyopaque, *const GUID, u64) callconv(.winapi) HRESULT,
    set_double: *const anyopaque,
    set_guid: *const fn (*anyopaque, *const GUID, *const GUID) callconv(.winapi) HRESULT,
    set_string: *const anyopaque,
    set_blob: *const anyopaque,
    set_unknown: *const anyopaque,
    lock_store: *const anyopaque,
    unlock_store: *const anyopaque,
    get_count: *const anyopaque,
    get_item_by_index: *const anyopaque,
    copy_all_items: *const anyopaque,
};

const IMFSampleVtable = extern struct {
    attributes: IMFAttributesVtable,
    get_sample_flags: *const anyopaque,
    set_sample_flags: *const anyopaque,
    get_sample_time: *const anyopaque,
    set_sample_time: *const fn (*anyopaque, i64) callconv(.winapi) HRESULT,
    get_sample_duration: *const anyopaque,
    set_sample_duration: *const fn (*anyopaque, i64) callconv(.winapi) HRESULT,
    get_buffer_count: *const anyopaque,
    get_buffer_by_index: *const anyopaque,
    convert_to_contiguous_buffer: *const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT,
    add_buffer: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    remove_buffer_by_index: *const anyopaque,
    remove_all_buffers: *const anyopaque,
    get_total_length: *const anyopaque,
    copy_to_buffer: *const anyopaque,
};

const IMFMediaBufferVtable = extern struct {
    base: IUnknownVtable,
    lock: *const fn (*anyopaque, *[*]u8, ?*u32, ?*u32) callconv(.winapi) HRESULT,
    unlock: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    get_current_length: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
    set_current_length: *const fn (*anyopaque, u32) callconv(.winapi) HRESULT,
    get_max_length: *const anyopaque,
};

fn vtableOf(comptime T: type, object: *anyopaque) *const T {
    return @as(*const *const T, @ptrCast(@alignCast(object))).*;
}

fn release(object: ?*anyopaque) void {
    const value = object orelse return;
    _ = vtableOf(IUnknownVtable, value).release(value);
}

const clsid_h264_decoder = GUID{
    .data1 = 0x62ce7e72,
    .data2 = 0x4c71,
    .data3 = 0x4d20,
    .data4 = .{ 0xb1, 0x5d, 0x45, 0x28, 0x31, 0xa8, 0x7d, 0x9d },
};
const iid_transform = GUID{
    .data1 = 0xbf94c121,
    .data2 = 0x5b05,
    .data3 = 0x4e6f,
    .data4 = .{ 0x80, 0x00, 0xba, 0x59, 0x89, 0x61, 0x41, 0x4d },
};

/// Media Foundation spells a video format as a four-character code inside a
/// fixed suffix, so the codes are built rather than written out.
fn videoFormat(code: *const [4]u8) GUID {
    return .{
        .data1 = std.mem.readInt(u32, code, .little),
        .data2 = 0x0000,
        .data3 = 0x0010,
        .data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 },
    };
}

const major_type_video = videoFormat("vids");
const format_h264 = videoFormat("H264");
const format_nv12 = videoFormat("NV12");

const attribute_major_type = GUID{
    .data1 = 0x48eba18e,
    .data2 = 0xf8c9,
    .data3 = 0x4687,
    .data4 = .{ 0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f },
};
const attribute_subtype = GUID{
    .data1 = 0xf7e34c9a,
    .data2 = 0x42e8,
    .data3 = 0x4714,
    .data4 = .{ 0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5 },
};
const attribute_frame_size = GUID{
    .data1 = 0x1652c33d,
    .data2 = 0xd6b2,
    .data3 = 0x4012,
    .data4 = .{ 0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d },
};
const attribute_interlace_mode = GUID{
    .data1 = 0xe2724bb8,
    .data2 = 0xe676,
    .data3 = 0x4806,
    .data4 = .{ 0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd },
};

const interlace_progressive: u32 = 2;

const attribute_transform_async = GUID{
    .data1 = 0xf81a699a,
    .data2 = 0x649a,
    .data3 = 0x497d,
    .data4 = .{ 0x8c, 0x73, 0x29, 0xf8, 0xfe, 0xd6, 0xad, 0x7a },
};
const attribute_transform_async_unlock = GUID{
    .data1 = 0xe5666d6b,
    .data2 = 0x3422,
    .data3 = 0x4eb6,
    .data4 = .{ 0xa4, 0x21, 0xda, 0x7d, 0xb1, 0xf8, 0xe2, 0x07 },
};
const attribute_low_latency = GUID{
    .data1 = 0x9c27891a,
    .data2 = 0xed7a,
    .data3 = 0x40e1,
    .data4 = .{ 0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee },
};

/// One frame at 30 Hz in 100-nanosecond units, used only to give samples
/// distinct, increasing stamps; the title decides real presentation timing.
const frame_duration: i64 = 333_333;

/// Output-stream flags saying the transform allocates its own samples.
const stream_provides_samples: u32 = 0x0000_0100;
const stream_can_provide_samples: u32 = 0x0000_0200;

const message_begin_streaming: u32 = 0x1000_0000;
const message_start_of_stream: u32 = 0x1000_0002;
const message_flush: u32 = 0;
/// Tells a transform no more input is coming, so it releases the pictures it
/// was still holding back to reorder.
const message_drain: u32 = 1;

extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoCreateInstance(
    *const GUID,
    ?*anyopaque,
    u32,
    *const GUID,
    **anyopaque,
) callconv(.winapi) HRESULT;
extern "mfplat" fn MFStartup(u32, u32) callconv(.winapi) HRESULT;
extern "mfplat" fn MFCreateMediaType(**anyopaque) callconv(.winapi) HRESULT;
extern "mfplat" fn MFCreateSample(**anyopaque) callconv(.winapi) HRESULT;
extern "mfplat" fn MFCreateMemoryBuffer(u32, **anyopaque) callconv(.winapi) HRESULT;

const mf_version: u32 = 0x0002_0070;
const coinit_multithreaded: u32 = 0;
const clsctx_inproc_server: u32 = 1;

/// Frame sizes are one attribute holding two 32-bit halves.
fn packedFrameSize(width: u32, height: u32) u64 {
    return (@as(u64, width) << 32) | height;
}

const Decoder = struct {
    transform: *anyopaque,
    width: u32,
    height: u32,
    output_pitch: u32,
    /// Where a decoded picture is assembled before the caller copies it out.
    frame: std.ArrayList(u8) = .empty,
    /// Whether this decoder has been told its stream ended. A drain is one
    /// message, not one per collected picture, and new input starts a fresh
    /// stream that can be drained again.
    draining: bool = false,
};

/// A spin lock over the decoder, matching the one the asynchronous reads use.
const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

/// One host decoder per decoder a title created.
///
/// A title can hold several at once -- Yotei creates two before playing
/// anything -- and each carries its own stream. Sharing one host decoder
/// between them feeds two streams into a decoder that can only follow one, so
/// the first breaks up and the second never starts.
const DecoderSlot = struct {
    /// The title's own decoder handle, or zero when the slot is free.
    handle: u64 = 0,
    state: ?Decoder = null,
};

const maximum_decoders = 8;

var decoders: [maximum_decoders]DecoderSlot = @splat(.{});
/// A title decodes on one thread and may reset or delete from another, while
/// the picture handed back borrows the buffer its decoder owns. One lock over
/// the table keeps those from overlapping.
var lock: Lock = .{};

fn slotFor(handle: u64) ?*DecoderSlot {
    if (handle == 0) return null;
    for (&decoders) |*slot| {
        if (slot.handle == handle and slot.state != null) return slot;
    }
    return null;
}

fn freeSlot() ?*DecoderSlot {
    for (&decoders) |*slot| {
        if (slot.state == null) return slot;
    }
    return null;
}

/// Releases one slot. The caller already holds the lock.
fn releaseSlotLocked(slot: *DecoderSlot) void {
    if (slot.state) |*active| {
        release(active.transform);
        active.frame.deinit(std.heap.page_allocator);
    }
    slot.* = .{};
}
var platform_started = false;
var reported_failure = false;
var reported_first_picture = false;
var reported_output_failure = false;
var reported_submission_failure = false;
/// Consecutive collections that produced nothing, so a permanent stall shows.
var starved: u32 = 0;
/// Stamp given to the next access unit that arrives without one.
var next_stamp: i64 = 0;
/// Whether the host transform must be driven through its event queue.
var asynchronous = false;

fn reportOnce(comptime message: []const u8, arguments: anytype) void {
    if (reported_failure) return;
    reported_failure = true;
    std.debug.print("[videodec] " ++ message ++ "\n", arguments);
}

fn startPlatform() bool {
    if (platform_started) return true;
    // A decoding thread may already live in a single-threaded apartment; that
    // is not an error for what this does.
    _ = CoInitializeEx(null, coinit_multithreaded);
    if (failed(MFStartup(mf_version, 0))) {
        reportOnce("Media Foundation is unavailable; pictures stay undecoded", .{});
        return false;
    }
    platform_started = true;
    return true;
}

/// Chooses the output layout, leaving the input type and everything the
/// decoder has already parsed from the stream untouched.
fn selectOutputType(transform: *anyopaque, width: u32, height: u32) bool {
    const vtable = vtableOf(IMFTransformVtable, transform);

    // The decoder publishes the output types it can produce, in its own order.
    // Taking the first one it accepts picked a packed 4:2:2 layout, which is
    // not what the guest interface describes and is twice the size the title
    // reserved, so NV12 is chosen by name.
    var index: u32 = 0;
    while (index < 16) : (index += 1) {
        var candidate: *anyopaque = undefined;
        if (failed(vtable.get_output_available_type(transform, 0, index, &candidate))) break;
        defer release(candidate);
        var subtype: GUID = undefined;
        const attributes = vtableOf(IMFAttributesVtable, candidate);
        if (failed(attributes.get_guid(candidate, &attribute_subtype, &subtype))) continue;
        if (!std.meta.eql(subtype, format_nv12)) continue;
        if (!failed(vtable.set_output_type(transform, 0, candidate, 0))) return true;
    }

    // Nothing offered was accepted; describe NV12 outright.
    var output: *anyopaque = undefined;
    if (failed(MFCreateMediaType(&output))) return false;
    defer release(output);
    const output_attributes = vtableOf(IMFAttributesVtable, output);
    if (failed(output_attributes.set_guid(output, &attribute_major_type, &major_type_video))) return false;
    if (failed(output_attributes.set_guid(output, &attribute_subtype, &format_nv12))) return false;
    if (failed(output_attributes.set_uint64(output, &attribute_frame_size, packedFrameSize(width, height)))) return false;
    return !failed(vtable.set_output_type(transform, 0, output, 0));
}

fn configureTypes(transform: *anyopaque, width: u32, height: u32) bool {
    const vtable = vtableOf(IMFTransformVtable, transform);

    var input: *anyopaque = undefined;
    if (failed(MFCreateMediaType(&input))) return false;
    defer release(input);
    const input_attributes = vtableOf(IMFAttributesVtable, input);
    if (failed(input_attributes.set_guid(input, &attribute_major_type, &major_type_video))) return false;
    if (failed(input_attributes.set_guid(input, &attribute_subtype, &format_h264))) return false;
    if (failed(input_attributes.set_uint64(input, &attribute_frame_size, packedFrameSize(width, height)))) return false;
    if (failed(input_attributes.set_uint32(input, &attribute_interlace_mode, interlace_progressive))) return false;
    if (failed(vtable.set_input_type(transform, 0, input, 0))) return false;
    return selectOutputType(transform, width, height);
}

fn readOutputGeometry(transform: *anyopaque, into: *Decoder) void {
    var current: *anyopaque = undefined;
    if (failed(vtableOf(IMFTransformVtable, transform).get_output_current_type(transform, 0, &current))) return;
    defer release(current);
    var size: u64 = 0;
    if (failed(vtableOf(IMFAttributesVtable, current).get_uint64(current, &attribute_frame_size, &size))) return;
    const width: u32 = @truncate(size >> 32);
    const height: u32 = @truncate(size);
    if (width == 0 or height == 0) return;
    into.width = width;
    into.height = height;
    into.output_pitch = width;
}


/// Settles how the transform will be driven before streaming starts.
///
/// An asynchronous transform accepts every input and answers every collection
/// with "need more" until its caller waits on its events, which is
/// indistinguishable from a decoder that simply has no picture yet. Unlocking
/// it is what a caller that intends to drive it must do, and asking for low
/// latency stops a decoder holding pictures back to reorder them.
fn prepareTransformAttributes(transform: *anyopaque) void {
    var attributes: *anyopaque = undefined;
    if (failed(vtableOf(IMFTransformVtable, transform).get_attributes(transform, &attributes))) return;
    defer release(attributes);
    const table = vtableOf(IMFAttributesVtable, attributes);
    _ = table.set_uint32(attributes, &attribute_low_latency, 1);
    var is_async: u32 = 0;
    if (failed(table.get_uint32(attributes, &attribute_transform_async, &is_async))) return;
    if (is_async == 0) return;
    _ = table.set_uint32(attributes, &attribute_transform_async_unlock, 1);
    asynchronous = true;
    std.debug.print("[videodec] host decoder is asynchronous; driving it by events\n", .{});
}

/// Prepares a decoder for a stream of the given size, reusing one already
/// running for the same geometry.
pub fn ensureDecoder(handle: u64, width: u32, height: u32) bool {
    lock.lock();
    defer lock.unlock();
    if (comptime builtin.os.tag != .windows) return false;
    if (handle == 0 or width == 0 or height == 0) return false;
    if (slotFor(handle)) |existing| {
        const state = &existing.state.?;
        if (state.width == width and state.height == height) return true;
        // Released here rather than through the public entry point, which
        // takes the lock this already holds.
        releaseSlotLocked(existing);
    }
    const slot = freeSlot() orelse return false;
    if (!startPlatform()) return false;

    var transform: *anyopaque = undefined;
    if (failed(CoCreateInstance(
        &clsid_h264_decoder,
        null,
        clsctx_inproc_server,
        &iid_transform,
        &transform,
    ))) {
        reportOnce("no host H.264 decoder; pictures stay undecoded", .{});
        return false;
    }
    if (!configureTypes(transform, width, height)) {
        release(transform);
        reportOnce("host H.264 decoder refused a {d}x{d} stream", .{ width, height });
        return false;
    }
    const vtable = vtableOf(IMFTransformVtable, transform);
    prepareTransformAttributes(transform);
    _ = vtable.process_message(transform, message_begin_streaming, 0);
    _ = vtable.process_message(transform, message_start_of_stream, 0);

    slot.* = .{
        .handle = handle,
        .state = .{
            .transform = transform,
            .width = width,
            .height = height,
            .output_pitch = width,
        },
    };
    readOutputGeometry(transform, &slot.state.?);
    std.debug.print(
        "[videodec] host H.264 decoder ready {d}x{d} for decoder 0x{x}\n",
        .{ slot.state.?.width, slot.state.?.height, handle },
    );
    return true;
}

/// Reports one picture the decoder was still holding after the last access
/// unit, telling it the stream ended the first time it is asked.
///
/// A title plays a movie to its end by feeding every access unit and then
/// asking for what is left, so a decoder that answers nothing here loses the
/// tail of every clip and leaves the title waiting for frames that never come.
pub fn drainPicture(handle: u64) ?Picture {
    if (comptime builtin.os.tag != .windows) return null;
    lock.lock();
    defer lock.unlock();
    const slot = slotFor(handle) orelse return null;
    const active = &slot.state.?;
    if (!active.draining) {
        active.draining = true;
        _ = vtableOf(IMFTransformVtable, active.transform)
            .process_message(active.transform, message_drain, 0);
    }
    if (!collectPicture(active)) return null;
    return currentPicture(active);
}

pub fn destroyDecoder(handle: u64) void {
    lock.lock();
    defer lock.unlock();
    const slot = slotFor(handle) orelse return;
    releaseSlotLocked(slot);
}

pub fn flushDecoder(handle: u64) void {
    lock.lock();
    defer lock.unlock();
    const slot = slotFor(handle) orelse return;
    const active = &slot.state.?;
    _ = vtableOf(IMFTransformVtable, active.transform)
        .process_message(active.transform, message_flush, 0);
}

fn makeInputSample(unit: []const u8, timestamp: i64) ?*anyopaque {
    var buffer: *anyopaque = undefined;
    if (failed(MFCreateMemoryBuffer(@intCast(unit.len), &buffer))) return null;
    const buffer_vtable = vtableOf(IMFMediaBufferVtable, buffer);
    var destination: [*]u8 = undefined;
    if (failed(buffer_vtable.lock(buffer, &destination, null, null))) {
        release(buffer);
        return null;
    }
    @memcpy(destination[0..unit.len], unit);
    _ = buffer_vtable.unlock(buffer);
    _ = buffer_vtable.set_current_length(buffer, @intCast(unit.len));

    var sample: *anyopaque = undefined;
    if (failed(MFCreateSample(&sample))) {
        release(buffer);
        return null;
    }
    const sample_vtable = vtableOf(IMFSampleVtable, sample);
    const added = sample_vtable.add_buffer(sample, buffer);
    release(buffer);
    if (failed(added)) {
        release(sample);
        return null;
    }
    // A transform is entitled to hold a sample back until it can order it
    // against its neighbours, and every sample carrying the same instant with
    // no duration gives it nothing to order by. Titles hand over access units
    // in decode order, so a steadily advancing stamp is enough.
    _ = sample_vtable.set_sample_time(sample, timestamp);
    _ = sample_vtable.set_sample_duration(sample, frame_duration);
    return sample;
}

fn collectPicture(active: *Decoder) bool {
    const vtable = vtableOf(IMFTransformVtable, active.transform);

    var info = OutputStreamInfo{ .flags = 0, .size = 0, .alignment = 0 };
    _ = vtable.get_output_stream_info(active.transform, 0, &info);
    const needed: u32 = if (info.size != 0)
        info.size
    else
        active.width * active.height * 3 / 2;

    // A transform either allocates its output sample or fills one it is given,
    // and says which through these two flags. The remaining flags describe the
    // samples themselves and say nothing about who allocates them, so they must
    // not be read as though they did.
    var provided: ?*anyopaque = null;
    if (info.flags & (stream_provides_samples | stream_can_provide_samples) == 0) {
        var buffer: *anyopaque = undefined;
        if (failed(MFCreateMemoryBuffer(needed, &buffer))) return false;
        var sample: *anyopaque = undefined;
        if (failed(MFCreateSample(&sample))) {
            release(buffer);
            return false;
        }
        const added = vtableOf(IMFSampleVtable, sample).add_buffer(sample, buffer);
        release(buffer);
        if (failed(added)) {
            release(sample);
            return false;
        }
        provided = sample;
    }

    var outputs = [_]OutputDataBuffer{.{
        .stream_id = 0,
        .sample = provided,
        .status = 0,
        .events = null,
    }};
    var status: u32 = 0;
    const result = vtable.process_output(active.transform, 0, 1, &outputs, &status);
    if (result == need_more_input) starved += 1 else starved = 0;
    release(outputs[0].events);
    if (result == stream_change) {
        // A stream change replaces the output type; renegotiating keeps the
        // geometry this reports in step with what the decoder now produces.
        // Only the output layout changes here. Setting the input type again
        // would restart the decoder and discard the parameter sets it has
        // already parsed, which turns every stream change into a fresh start
        // and means a picture is never reached.
        release(outputs[0].sample);
        _ = selectOutputType(active.transform, active.width, active.height);
        readOutputGeometry(active.transform, active);
        return false;
    }
    if (failed(result)) {
        if (!reported_output_failure and (result != need_more_input or starved > 240)) {
            reported_output_failure = true;
            std.debug.print("[videodec] no picture: result=0x{x} flags=0x{x} size={d}\n", .{ @as(u32, @bitCast(result)), info.flags, info.size });
        }
        release(outputs[0].sample);
        return false;
    }
    const sample = outputs[0].sample orelse return false;
    defer release(sample);

    var contiguous: *anyopaque = undefined;
    if (failed(vtableOf(IMFSampleVtable, sample).convert_to_contiguous_buffer(sample, &contiguous))) {
        return false;
    }
    defer release(contiguous);
    const buffer_vtable = vtableOf(IMFMediaBufferVtable, contiguous);
    var pixels: [*]u8 = undefined;
    var length: u32 = 0;
    if (failed(buffer_vtable.lock(contiguous, &pixels, null, &length))) return false;
    defer _ = buffer_vtable.unlock(contiguous);
    if (length == 0) return false;

    active.frame.clearRetainingCapacity();
    active.frame.appendSlice(std.heap.page_allocator, pixels[0..length]) catch return false;
    return true;
}

/// Hands one Annex B access unit to the decoder and reports a picture when the
/// decoder has one ready. Reporting none is ordinary: H.264 needs several
/// units before the first picture, and reordering delays later ones.
pub fn decodeAccessUnit(handle: u64, unit: []const u8, timestamp: i64) ?Picture {
    if (comptime builtin.os.tag != .windows) return null;
    if (unit.len == 0) return null;
    lock.lock();
    defer lock.unlock();
    const slot = slotFor(handle) orelse return null;
    const active = &slot.state.?;
    const vtable = vtableOf(IMFTransformVtable, active.transform);

    active.draining = false;
    const stamp = if (timestamp != 0) timestamp else next_stamp;
    next_stamp += frame_duration;
    const sample = makeInputSample(unit, stamp) orelse return null;
    defer release(sample);

    var submitted = vtable.process_input(active.transform, 0, sample, 0);
    if (submitted == not_accepting) {
        // The transform holds a finished picture and will take nothing more
        // until it is collected. Draining first is the whole of the contract;
        // giving up here instead stalls the stream permanently.
        const drained = collectPicture(active);
        submitted = vtable.process_input(active.transform, 0, sample, 0);
        if (drained) {
            reportFirstPicture(active);
            return currentPicture(active);
        }
    }
    if (failed(submitted)) {
        reportSubmissionOnce(submitted);
        return null;
    }

    if (!collectPicture(active)) return null;
    reportFirstPicture(active);
    return currentPicture(active);
}

fn currentPicture(active: *const Decoder) Picture {
    return .{
        .width = active.width,
        .height = active.height,
        .pitch = active.output_pitch,
        .bytes = active.frame.items,
    };
}

fn reportFirstPicture(active: *const Decoder) void {
    if (reported_first_picture) return;
    reported_first_picture = true;
    std.debug.print(
        "[videodec] first decoded picture {d}x{d} pitch={d} bytes={d}\n",
        .{ active.width, active.height, active.output_pitch, active.frame.items.len },
    );
}

fn reportSubmissionOnce(result: HRESULT) void {
    if (reported_submission_failure) return;
    reported_submission_failure = true;
    std.debug.print(
        "[videodec] decoder refused an access unit: 0x{x}\n",
        .{@as(u32, @bitCast(result))},
    );
}

/// Bytes one NV12 picture of this size occupies.
pub fn pictureBytes(width: u32, height: u32) u64 {
    return @as(u64, width) * height * 3 / 2;
}

const testing = std.testing;

test "a frame size packs width above height" {
    try testing.expectEqual(@as(u64, (1920 << 32) | 1088), packedFrameSize(1920, 1088));
}

test "video format codes keep the Media Foundation suffix" {
    try testing.expectEqual(@as(u32, 0x3231564e), format_nv12.data1);
    try testing.expectEqual(@as(u32, 0x34363248), format_h264.data1);
    try testing.expectEqual(@as(u8, 0x71), format_h264.data4[7]);
}

test "an NV12 picture is one and a half bytes per pixel" {
    try testing.expectEqual(@as(u64, 1920 * 1088 * 3 / 2), pictureBytes(1920, 1088));
}
