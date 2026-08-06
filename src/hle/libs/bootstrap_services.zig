// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Early title-bootstrap services which do not yet have a host presentation or
//! GPU backend. These implementations are intentionally headless, but preserve
//! handles and output structures so a title can pass initialization safely.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_runtime = @import("kernel_runtime.zig");
const kernel_threading = @import("kernel_threading.zig");
const kernel_memory = @import("kernel_memory.zig");
const kernel_event_queue = @import("kernel_event_queue.zig");
const agc_submit = @import("agc_submit.zig");
const agc = @import("agc.zig");
const agc_shader_registry = @import("agc_shader_registry.zig");
const gpu = @import("gpu");
const apr = @import("../apr.zig");
const video_out = @import("../video_out.zig");

const invalid_argument = errno.KernelError.einval.raw();
const ampr_command_buffer_header_size: u64 = 0x18;
const ampr_command_buffer_maximum_size: u64 = 64 * 1024 * 1024;
const ampr_gather_scatter_valid: u32 = 0x0001_0000;

fn success() callconv(abi.guest) i32 {
    return errno.ok;
}

fn aprError(err: apr.Error) i32 {
    return switch (err) {
        error.FileNotFound, error.UnknownFile => errno.KernelError.enoent.raw(),
        error.FileTableFull, error.CommandBufferTableFull, error.SubmissionTableFull => errno.KernelError.enomem.raw(),
        error.IoFailed => errno.KernelError.eio.raw(),
        error.InvalidPath, error.InvalidCommandBuffer, error.TooManyCommands, error.InvalidRead, error.UnknownSubmission => errno.KernelError.einval.raw(),
    };
}

fn amprCommandBufferConstructor(address: u64) callconv(abi.guest) i32 {
    if (address == 0) return errno.ok;
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    apr.constructCommandBuffer(address) catch |err| return aprError(err);
    const header: *[ampr_command_buffer_header_size]u8 = @ptrFromInt(address);
    @memset(header, 0);
    return errno.ok;
}

fn amprAprCommandBufferConstructor(address: u64, reserved_state_0: u64, reserved_state_1: u64) callconv(abi.guest) i32 {
    if (address == 0) return errno.ok;
    apr.constructCommandBuffer(address) catch |err| return aprError(err);
    const state_0 = if (reserved_state_0 == 0) address + 0x18 else reserved_state_0;
    const state_1 = if (reserved_state_1 == 0) address + 0x20 else reserved_state_1;
    if (!kernel_memory.isGuestRangeAccessible(state_0, @sizeOf(u64)) or
        !kernel_memory.isGuestRangeAccessible(state_1, @sizeOf(u64)))
    {
        return errno.KernelError.efault.raw();
    }
    writeGuestU64(state_0, 0);
    writeGuestU64(state_1, 0);
    return errno.ok;
}

fn amprCommandBufferSetBuffer(address: u64, storage_address: u64, storage_size: usize) callconv(abi.guest) i32 {
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    if (storage_address == 0 or (storage_address & 3) != 0 or storage_size == 0 or
        storage_size > ampr_command_buffer_maximum_size or (storage_size & 3) != 0)
    {
        return errno.KernelError.einval.raw();
    }
    if (readGuestU64(address + 0x10) != 0) return errno.KernelError.ebusy.raw();
    if (!kernel_memory.isGuestRangeAccessible(storage_address, storage_size)) {
        return errno.KernelError.efault.raw();
    }
    apr.setCommandBufferStorage(address, storage_address, storage_size) catch |err| return aprError(err);
    writeGuestU32(address + 0x04, 0);
    writeGuestU32(address + 0x08, 0);
    writeGuestU32(address + 0x0c, @intCast(storage_size));
    writeGuestU64(address + 0x10, storage_address);
    return errno.ok;
}

fn amprCommandBufferReset(address: u64) callconv(abi.guest) i32 {
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    if (readGuestU64(address + 0x10) == 0 or readGuestU32(address + 0x0c) == 0) {
        return errno.KernelError.eperm.raw();
    }
    apr.resetCommandBuffer(address) catch |err| return aprError(err);
    writeGuestU32(address + 0x04, 0);
    writeGuestU32(address + 0x08, 0);
    return errno.ok;
}

fn amprAprCommandBufferReadFile(
    address: u64,
    _: u64,
    _: u64,
    file_identifier: u32,
    destination: u64,
    size: u64,
    file_offset: u64,
) callconv(abi.guest) i32 {
    if (size == 0 or size > apr.maximum_read_bytes or file_offset >= apr.maximum_file_offset) {
        return errno.KernelError.einval.raw();
    }
    if (!kernel_memory.isGuestRangeAccessible(destination, size)) return errno.KernelError.efault.raw();
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    const record_size: u32 = if ((file_offset >> 32) != 0) 0x18 else 0x14;
    const storage_address = readGuestU64(address + 0x10);
    const storage_size = readGuestU32(address + 0x0c);
    const write_offset = readGuestU32(address + 0x04);
    if (storage_address == 0 or write_offset > storage_size or record_size > storage_size - write_offset) {
        return errno.KernelError.efault.raw();
    }
    const record_address = std.math.add(u64, storage_address, write_offset) catch {
        return errno.KernelError.efault.raw();
    };
    if (!kernel_memory.isGuestRangeAccessible(record_address, record_size)) {
        return errno.KernelError.efault.raw();
    }
    apr.appendRead(address, .{
        .file_identifier = file_identifier,
        .destination = destination,
        .size = @intCast(size),
        .file_offset = file_offset,
    }) catch |err| return aprError(err);
    const record: [*]u8 = @ptrFromInt(record_address);
    @memset(record[0..record_size], 0);
    record[0] = 0x17;
    writeGuestU32(address + 0x00, readGuestU32(address + 0x00) | ampr_gather_scatter_valid);
    writeGuestU32(address + 0x04, write_offset + record_size);
    writeGuestU32(address + 0x08, readGuestU32(address + 0x08) +% 1);
    return errno.ok;
}

fn readGuestU32(address: u64) u32 {
    const source: *const [4]u8 = @ptrFromInt(address);
    return std.mem.readInt(u32, source, .little);
}

fn readGuestU64(address: u64) u64 {
    const source: *const [8]u8 = @ptrFromInt(address);
    return std.mem.readInt(u64, source, .little);
}

fn writeGuestU32(address: u64, value: u32) void {
    const destination: *[4]u8 = @ptrFromInt(address);
    std.mem.writeInt(u32, destination, value, .little);
}

fn writeGuestU64(address: u64, value: u64) void {
    const destination: *[8]u8 = @ptrFromInt(address);
    std.mem.writeInt(u64, destination, value, .little);
}

// Offline POSIX sockets ----------------------------------------------------

fn posixSocket(_: i32, _: i32, _: i32) callconv(abi.guest) i32 {
    kernel_runtime.setPosixErrno(50); // FreeBSD/Orbis ENETDOWN
    return -1;
}

fn posixSocketOperation(_: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    kernel_runtime.setPosixErrno(50); // FreeBSD/Orbis ENETDOWN
    return -1;
}

fn posixSelect(_: i32, _: u64, _: u64, _: u64, timeout: ?*const anyopaque) callconv(abi.guest) i32 {
    _ = timeout;
    return 0;
}

const posix_exports = [_]symbols.Export{
    .{ .name = "socket", .function = trace.wrap("socket", &posixSocket), .expect_id = "TU-d9PfIHPM" },
    .{ .name = "connect", .function = trace.wrap("connect", &posixSocketOperation), .expect_id = "XVL8So3QJUk" },
    .{ .name = "shutdown", .function = trace.wrap("shutdown", &posixSocketOperation), .expect_id = "TUuiYS2kE8s" },
    .{ .name = "setsockopt", .function = trace.wrap("setsockopt", &posixSocketOperation), .expect_id = "fFxGkxF2bVo" },
    .{ .name = "recv", .function = trace.wrap("recv", &posixSocketOperation), .expect_id = "Ez8xjo9UF4E" },
    .{ .name = "select", .function = trace.wrap("select", &posixSelect), .expect_id = "T8fER+tIGgk" },
};

// Deterministic random data ------------------------------------------------

var random_state = std.atomic.Value(u64).init(0x9e37_79b9_7f4a_7c15);

fn randomGetRandomNumber(buffer: ?[*]u8, size: usize) callconv(abi.guest) i32 {
    const output = buffer orelse return invalid_argument;
    var state = random_state.load(.monotonic);
    for (output[0..size]) |*byte| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = @truncate(state);
    }
    random_state.store(state, .monotonic);
    return errno.ok;
}

const random_exports = [_]symbols.Export{
    .{ .name = "sceRandomGetRandomNumber", .function = trace.wrap("sceRandomGetRandomNumber", &randomGetRandomNumber), .expect_id = "PI7jIZj4pcE" },
};

// VideoOut ---------------------------------------------------------------

const video_out_error_invalid_value: i32 = @bitCast(@as(u32, 0x8029_0001));
const video_out_error_invalid_address: i32 = @bitCast(@as(u32, 0x8029_0002));
const video_out_error_invalid_index: i32 = @bitCast(@as(u32, 0x8029_000a));
const video_out_error_invalid_handle: i32 = @bitCast(@as(u32, 0x8029_000b));
const video_out_error_invalid_event_queue: i32 = @bitCast(@as(u32, 0x8029_000c));
const video_out_error_slot_occupied: i32 = @bitCast(@as(u32, 0x8029_0010));
const video_out_error_invalid_option: i32 = @bitCast(@as(u32, 0x8029_001a));
const video_out_error_invalid_category: i32 = @bitCast(@as(u32, 0x8029_001d));

pub const VideoOutBufferAttribute2 = video_out.BufferAttribute2;
pub const VideoOutBuffer = video_out.Buffer;

const VideoOutFlipStatus = extern struct {
    count: u64 = 0,
    process_time: u64 = 0,
    reserved0: u64 = 0,
    flip_argument: i64 = 0,
    reserved1: u64 = 0,
    process_time_counter: u64 = 0,
    gc_queue_count: i32 = 0,
    flip_pending_count: i32 = 0,
    current_buffer: i32 = -1,
    reserved2: u32 = 0,
    submit_process_time_counter: u64 = 0,
    reserved3: [7]u64 = [_]u64{0} ** 7,
};

const VideoOutOutputStatus = extern struct {
    resolution: u32 = 1,
    dynamic_range: u32 = 1,
    refresh_rate: u64 = 60_000,
    flags: u64 = 0,
    reserved: [3]u64 = .{ 0, 0, 0 },
};

fn validVideoHandle(handle: i32) bool {
    return video_out.validHandle(handle);
}

/// Host-side ~60 Hz refresh so WaitEqueue(vblank) keeps waking between flips.
var vblank_ticker_started: std.atomic.Value(bool) = .init(false);

fn hostSleepMilliseconds(ms: u32) void {
    if (comptime builtin.os.tag != .windows) return;
    // Negative 100-ns units = relative delay (not wall-clock sensitive).
    var interval: i64 = -@as(i64, @intCast(ms)) * 10_000;
    _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
}

fn vblankTickerMain() void {
    while (!kernel_runtime.guestStopRequested()) {
        // Host sleep: this thread is not a guest pthread, so sceKernelUsleep
        // would return ENOSYS and spin.
        hostSleepMilliseconds(16);
        if (!video_out.validHandle(video_out.primary_handle)) continue;
        _ = video_out.advanceVblank(
            kernel_runtime.processTimeMicroseconds(),
            kernel_runtime.processTimeCounter(),
        );
        _ = kernel_event_queue.triggerVideoOutVblank();
    }
}

fn ensureVblankTicker() void {
    if (vblank_ticker_started.swap(true, .monotonic)) return;
    const thread = std.Thread.spawn(.{}, vblankTickerMain, .{}) catch {
        vblank_ticker_started.store(false, .monotonic);
        return;
    };
    thread.detach();
}

fn videoOutOpen(_: i32, _: i32, index: i32, _: ?*const anyopaque) callconv(abi.guest) i32 {
    if (!video_out.open(index)) return video_out_error_invalid_handle;
    video_out.noteOpenProcessTime(kernel_runtime.processTimeMicroseconds());
    ensureVblankTicker();
    return video_out.primary_handle;
}

fn videoOutSetBufferAttribute2(
    attribute: ?*VideoOutBufferAttribute2,
    pixel_format: u64,
    tiling_mode: u32,
    width: u32,
    height: u32,
    option: u64,
    dcc_control: u32,
    dcc_clear_color: u64,
) callconv(abi.guest) void {
    const output = attribute orelse return;
    output.* = .{
        .tiling_mode = tiling_mode,
        .aspect_ratio = 1,
        .width = width,
        .height = height,
        .pitch_in_pixels = width,
        .option = option,
        .pixel_format = pixel_format,
        .dcc_clear_color = dcc_clear_color,
        .dcc_control = dcc_control,
    };
}

fn videoHandleOption(handle: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) errno.ok else video_out_error_invalid_handle;
}

fn videoOutClose(handle: i32) callconv(abi.guest) i32 {
    return if (video_out.close(handle)) errno.ok else video_out_error_invalid_handle;
}

fn videoOutError(err: video_out.RegisterError) i32 {
    return switch (err) {
        error.InvalidValue => video_out_error_invalid_value,
        error.InvalidAddress => video_out_error_invalid_address,
        error.InvalidOption => video_out_error_invalid_option,
        error.InvalidCategory => video_out_error_invalid_category,
        error.InvalidIndex => video_out_error_invalid_index,
        error.SlotOccupied => video_out_error_slot_occupied,
    };
}

fn videoOutRegisterBuffers2(
    handle: i32,
    set_index: i32,
    buffer_index_start: i32,
    buffer_pointer: ?[*]const VideoOutBuffer,
    count: i32,
    attribute: ?*const VideoOutBufferAttribute2,
    category: i32,
    option: ?*anyopaque,
) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const input = buffer_pointer orelse return video_out_error_invalid_address;
    const attributes = attribute orelse return video_out_error_invalid_option;
    if (count <= 0) return video_out_error_invalid_value;
    if (option != null) return video_out_error_invalid_option;
    video_out.registerBuffers(
        set_index,
        buffer_index_start,
        input[0..@intCast(count)],
        attributes.*,
        category,
    ) catch |err| return videoOutError(err);
    return errno.ok;
}

fn videoOutUnregisterBuffers(handle: i32, set_index: i32) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    video_out.unregisterBuffers(set_index) catch |err| return videoOutError(err);
    return errno.ok;
}

fn videoOutSubmitChangeBufferAttribute2(
    handle: i32,
    set_index: i32,
    attribute: ?*const VideoOutBufferAttribute2,
    option: ?*anyopaque,
) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const value = attribute orelse return video_out_error_invalid_option;
    if (option != null) return video_out_error_invalid_option;
    video_out.changeAttribute(set_index, value.*) catch |err| return videoOutError(err);
    return errno.ok;
}

fn videoOutSubmitFlip(handle: i32, index: i32, mode: i32, argument: i64) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    if (index < -1 or (index >= 0 and video_out.resolve(@intCast(handle), index) == null)) {
        return video_out_error_invalid_index;
    }
    video_out.noteFlipSubmit(argument, kernel_runtime.processTimeCounter());
    _ = agc_submit.presentFlip(.{
        .video_out_handle = @intCast(handle),
        .display_buffer_index = index,
        .mode = @bitCast(mode),
        .argument = argument,
    });
    _ = kernel_threading.sceKernelUsleep(16_667);
    return errno.ok;
}

fn videoOutGetFlipStatus(handle: i32, status: ?*VideoOutFlipStatus) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const output = status orelse return video_out_error_invalid_address;
    const current = video_out.status(handle) orelse return video_out_error_invalid_handle;
    // Full PS5 layout: titles poll process-time fields after
    // WaitEqueue(filter=-13) and skip init paths when they look unset/stale.
    output.* = .{
        .count = current.count,
        .process_time = kernel_runtime.processTimeMicroseconds(),
        .reserved0 = 0,
        .flip_argument = current.flip_argument,
        .reserved1 = 0,
        .process_time_counter = kernel_runtime.processTimeCounter(),
        .gc_queue_count = 0,
        .flip_pending_count = current.flip_pending_count,
        .current_buffer = current.current_buffer,
        .reserved2 = 0,
        .submit_process_time_counter = current.submit_process_time_counter,
        .reserved3 = [_]u64{0} ** 7,
    };
    return errno.ok;
}

/// Decodes the flip/vblank payload from a VideoOut equeue event.
/// Event `data` stores `ident | (flip_arg << 16)`; titles read the arg via
/// this helper rather than raw sceKernelGetEventData.
fn videoOutGetEventData(event: ?*const kernel_event_queue.Event, out_data: ?*u64) callconv(abi.guest) i32 {
    const value = event orelse return video_out_error_invalid_address;
    const output = out_data orelse return video_out_error_invalid_address;
    if (value.filter != kernel_event_queue.video_out_filter) {
        return video_out_error_invalid_value;
    }
    if (value.ident != kernel_event_queue.video_out_flip_ident and
        value.ident != kernel_event_queue.video_out_vblank_ident)
    {
        return video_out_error_invalid_value;
    }
    // High 48 bits of data carry the flip argument.
    const packed_data: u64 = @bitCast(value.data);
    output.* = packed_data >> 16;
    return errno.ok;
}

fn videoOutGetOutputStatus(handle: i32, status: ?*VideoOutOutputStatus) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const output = status orelse return video_out_error_invalid_address;
    output.* = .{};
    return errno.ok;
}

fn videoOutIsOutputSupported(handle: i32, _: u64, _: ?*const anyopaque, _: ?*anyopaque, _: u64) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) 1 else video_out_error_invalid_handle;
}

fn videoOutGetEventId(event: ?*const @import("kernel_event_queue.zig").Event) callconv(abi.guest) i32 {
    const value = event orelse return 0;
    if (value.filter != kernel_event_queue.video_out_filter) return 0;
    // 0 = flip, 1 = vblank (console convention).
    if (value.ident == kernel_event_queue.video_out_flip_ident) return 0;
    if (value.ident == kernel_event_queue.video_out_vblank_ident) return 1;
    return @bitCast(@as(u32, @truncate(value.ident)));
}

const VideoOutVblankStatus = extern struct {
    count: u64 = 0,
    process_time: u64 = 0,
    reserved: u64 = 0,
    process_time_counter: u64 = 0,
    flags: u8 = 0,
    phase: u8 = 0,
    pad: [6]u8 = @splat(0),
};

fn videoOutAddVblankEvent(equeue: i64, handle: i32, user_data: u64) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    return if (kernel_event_queue.addVideoOutVblankEvent(equeue, user_data) == errno.ok)
        errno.ok
    else
        video_out_error_invalid_event_queue;
}

fn videoOutWaitVblank(handle: i32) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    // Pace to ~60 Hz so titles that spin on vblank do not burn a core.
    _ = kernel_threading.sceKernelUsleep(16_667);
    _ = video_out.advanceVblank(
        kernel_runtime.processTimeMicroseconds(),
        kernel_runtime.processTimeCounter(),
    );
    _ = kernel_event_queue.triggerVideoOutVblank();
    return errno.ok;
}

fn videoOutGetVblankStatus(handle: i32, status: ?*VideoOutVblankStatus) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const output = status orelse return video_out_error_invalid_address;
    const current = video_out.vblankStatus(
        handle,
        kernel_runtime.processTimeMicroseconds(),
        kernel_runtime.processTimeCounter(),
    ) orelse return video_out_error_invalid_handle;
    output.* = .{
        .count = current.count,
        .process_time = current.process_time,
        .reserved = 0,
        .process_time_counter = current.process_time_counter,
        .flags = current.flags,
        .phase = current.phase,
        .pad = @splat(0),
    };
    return errno.ok;
}

fn videoOutAddFlipEvent(equeue: i64, handle: i32, user_data: u64) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    return if (kernel_event_queue.addVideoOutFlipEvent(equeue, user_data) == errno.ok)
        errno.ok
    else
        video_out_error_invalid_event_queue;
}

fn videoOutDeleteFlipEvent(equeue: i64, handle: i32) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    return if (kernel_event_queue.deleteVideoOutFlipEvent(equeue) == errno.ok)
        errno.ok
    else
        video_out_error_invalid_event_queue;
}

fn videoOutIsFlipPending(handle: i32) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) 0 else video_out_error_invalid_handle;
}

/// A flip submitted to complete when the GPU finishes the frame.
///
/// The live backend drains prior queue work before presenting it. Unlike the
/// ordinary CPU flip, this entry point does not add display pacing because its
/// caller expects GPU end-of-pipe ordering to provide that boundary.
fn videoOutSubmitEopFlip(
    handle: i32,
    index: i32,
    mode: u32,
    argument: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    if (video_out.resolve(@intCast(handle), index) == null) return video_out_error_invalid_index;

    // Reported rather than discarded. A flip that is not accepted publishes no
    // completion, and a title that was told the flip was accepted waits for
    // that completion for as long as it runs — with nothing anywhere saying
    // which call was the one that did not happen. Answering truthfully turns a
    // silent stall into a failure at the call responsible for it.
    const flip_arg: i64 = @bitCast(argument);
    video_out.noteFlipSubmit(flip_arg, kernel_runtime.processTimeCounter());
    if (!agc_submit.presentFlip(.{
        .video_out_handle = @intCast(handle),
        .display_buffer_index = index,
        .mode = mode,
        .argument = flip_arg,
    })) {
        return video_out_error_invalid_index;
    }
    return errno.ok;
}

/// Which display bus the output is attached to. There is only one.
fn videoOutSysGetBus(handle: i32) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) 0 else video_out_error_invalid_handle;
}

/// Returns the base of 16 contiguous 64-bit flip-completion labels.
fn videoOutGetBufferLabelAddress(handle: i32, output_address: u64) callconv(abi.guest) i32 {
    if (output_address == 0 or !kernel_memory.isGuestRangeAccessible(output_address, @sizeOf(u64))) {
        return video_out_error_invalid_address;
    }
    const label_address = video_out.labelAddress(handle) orelse return video_out_error_invalid_handle;
    const output: *[8]u8 = @ptrFromInt(output_address);
    std.mem.writeInt(u64, output, label_address, .little);
    return video_out.maximum_buffers;
}

/// How far the display pipeline has progressed.
///
/// Refused: the answer is a record whose layout is not established here, and
/// writing a guessed one into the caller's buffer would corrupt whatever it
/// keeps alongside.
fn videoOutGetPipelineStatus(_: i32, _: u64) callconv(abi.guest) i32 {
    return video_out_error_invalid_address;
}

const video_out_exports = [_]symbols.Export{
    .{ .name = "sceVideoOutOpen", .function = trace.wrap("sceVideoOutOpen", &videoOutOpen), .expect_id = "Up36PTk687E" },
    .{ .name = "sceVideoOutClose", .function = trace.wrap("sceVideoOutClose", &videoOutClose), .expect_id = "uquVH4-Du78" },
    .{ .name = "sceVideoOutSetBufferAttribute2", .function = trace.wrap("sceVideoOutSetBufferAttribute2", &videoOutSetBufferAttribute2), .expect_id = "PjS5uASwcV8" },
    .{ .name = "sceVideoOutRegisterBuffers2", .function = trace.wrap("sceVideoOutRegisterBuffers2", &videoOutRegisterBuffers2), .expect_id = "rKBUtgRrtbk" },
    .{ .name = "sceVideoOutUnregisterBuffers", .function = trace.wrap("sceVideoOutUnregisterBuffers", &videoOutUnregisterBuffers), .expect_id = "N5KDtkIjjJ4" },
    .{ .name = "sceVideoOutSubmitChangeBufferAttribute2", .function = trace.wrap("sceVideoOutSubmitChangeBufferAttribute2", &videoOutSubmitChangeBufferAttribute2), .expect_id = "HuViW4HnrOw" },
    .{ .name = "sceVideoOutSubmitFlip", .function = trace.wrap("sceVideoOutSubmitFlip", &videoOutSubmitFlip), .expect_id = "U46NwOiJpys" },
    .{ .name = "sceVideoOutGetFlipStatus", .function = trace.wrap("sceVideoOutGetFlipStatus", &videoOutGetFlipStatus), .expect_id = "SbU3dwp80lQ" },
    .{ .name = "sceVideoOutIsFlipPending", .function = trace.wrap("sceVideoOutIsFlipPending", &videoOutIsFlipPending), .expect_id = "zgXifHT9ErY" },
    .{ .name = "sceVideoOutSetFlipRate", .function = trace.wrap("sceVideoOutSetFlipRate", &videoHandleOption), .expect_id = "CBiu4mCE1DA" },
    .{ .name = "sceVideoOutAddFlipEvent", .function = trace.wrap("sceVideoOutAddFlipEvent", &videoOutAddFlipEvent), .expect_id = "HXzjK9yI30k" },
    .{ .name = "sceVideoOutDeleteFlipEvent", .function = trace.wrap("sceVideoOutDeleteFlipEvent", &videoOutDeleteFlipEvent), .expect_id = "-Ozn0F1AFRg" },
    .{ .name = "sceVideoOutAddVblankEvent", .function = trace.wrap("sceVideoOutAddVblankEvent", &videoOutAddVblankEvent), .expect_id = "Xru92wHJRmg" },
    .{ .name = "sceVideoOutWaitVblank", .function = trace.wrap("sceVideoOutWaitVblank", &videoOutWaitVblank), .expect_id = "j6RaAUlaLv0" },
    .{ .name = "sceVideoOutGetVblankStatus", .function = trace.wrap("sceVideoOutGetVblankStatus", &videoOutGetVblankStatus), .expect_id = "1FZBKy8HeNU" },
    .{ .name = "sceVideoOutGetEventId", .function = trace.wrap("sceVideoOutGetEventId", &videoOutGetEventId), .expect_id = "U2JJtSqNKZI" },
    .{ .name = "sceVideoOutGetEventData", .function = trace.wrap("sceVideoOutGetEventData", &videoOutGetEventData), .expect_id = "rWUTcKdkUzQ" },
    .{ .name = "sceVideoOutGetOutputStatus", .function = trace.wrap("sceVideoOutGetOutputStatus", &videoOutGetOutputStatus), .expect_id = "utPrVdxio-8" },
    .{ .name = "sceVideoOutIsOutputSupported", .function = trace.wrap("sceVideoOutIsOutputSupported", &videoOutIsOutputSupported), .expect_id = "Nv8c-Kb+DUM" },
    .{ .name = "sceVideoOutConfigureOutput", .function = trace.wrap("sceVideoOutConfigureOutput", &videoHandleOption), .expect_id = "w0hLuNarQxY" },
    .{ .name = "sceVideoOutSetWindowModeMargins", .function = trace.wrap("sceVideoOutSetWindowModeMargins", &videoHandleOption), .expect_id = "MTxxrOCeSig" },
    .{ .name = "sceVideoOutVrrPegToFixedRate", .function = trace.wrap("sceVideoOutVrrPegToFixedRate", &videoHandleOption), .expect_id = "5tRaBjtdTzY" },
    .{ .name = "sceVideoOutVrrUnpegFromFixedRate", .function = trace.wrap("sceVideoOutVrrUnpegFromFixedRate", &videoHandleOption), .expect_id = "T4ucGB8CsnM" },
    .{ .name = "sceVideoOutSubmitEopFlip", .function = trace.wrap("sceVideoOutSubmitEopFlip", &videoOutSubmitEopFlip), .expect_id = "j8xl+92A0q4" },
    .{ .name = "sceVideoOutSysGetBus", .function = trace.wrap("sceVideoOutSysGetBus", &videoOutSysGetBus), .expect_id = "7VSZJxxcTL8" },
    .{ .name = "sceVideoOutSysAddSetModeEvent2", .function = trace.wrap("sceVideoOutSysAddSetModeEvent2", &videoHandleOption), .expect_id = "fYWVVDKZOCk" },
    .{ .name = "sceVideoOutGetBufferLabelAddress", .function = trace.wrap("sceVideoOutGetBufferLabelAddress", &videoOutGetBufferLabelAddress), .expect_id = "OcQybQejHEY" },
    .{ .name = "sceVideoOutGetPipelineStatus", .function = trace.wrap("sceVideoOutGetPipelineStatus", &videoOutGetPipelineStatus), .expect_id = "Ygv0S+Hi+hA" },
};

// Headless AV player ------------------------------------------------------

var av_player_token: u8 = 0;

fn avPlayerInitEx(_: ?*const anyopaque, handle: ?*?*anyopaque) callconv(abi.guest) i32 {
    const output = handle orelse return invalid_argument;
    output.* = &av_player_token;
    return errno.ok;
}

fn validAvHandle(handle: ?*anyopaque) bool {
    return handle == @as(*anyopaque, @ptrCast(&av_player_token));
}

fn avPlayerAction(handle: ?*anyopaque, _: u64, _: u64) callconv(abi.guest) i32 {
    return if (validAvHandle(handle)) errno.ok else invalid_argument;
}

fn avPlayerNoFrame(handle: ?*anyopaque, _: ?*anyopaque) callconv(abi.guest) u8 {
    return if (validAvHandle(handle)) 0 else 0;
}

fn avPlayerStreamCount(handle: ?*anyopaque) callconv(abi.guest) i32 {
    return if (validAvHandle(handle)) 0 else invalid_argument;
}

fn avPlayerClose(handle: ?*anyopaque) callconv(abi.guest) i32 {
    return if (validAvHandle(handle)) errno.ok else invalid_argument;
}

const av_player_exports = [_]symbols.Export{
    .{ .name = "sceAvPlayerInitEx", .function = trace.wrap("sceAvPlayerInitEx", &avPlayerInitEx), .expect_id = "o9eWRkSL+M4" },
    .{ .name = "sceAvPlayerPostInit", .function = trace.wrap("sceAvPlayerPostInit", &avPlayerAction), .expect_id = "HD1YKVU26-M" },
    .{ .name = "sceAvPlayerAddSourceEx", .function = trace.wrap("sceAvPlayerAddSourceEx", &avPlayerAction), .expect_id = "x8uvuFOPZhU" },
    .{ .name = "sceAvPlayerStart", .function = trace.wrap("sceAvPlayerStart", &avPlayerAction), .expect_id = "ET4Gr-Uu07s" },
    .{ .name = "sceAvPlayerStop", .function = trace.wrap("sceAvPlayerStop", &avPlayerAction), .expect_id = "ZC17w3vB5Lo" },
    .{ .name = "sceAvPlayerPause", .function = trace.wrap("sceAvPlayerPause", &avPlayerAction), .expect_id = "9y5v+fGN4Wk" },
    .{ .name = "sceAvPlayerResume", .function = trace.wrap("sceAvPlayerResume", &avPlayerAction), .expect_id = "w5moABNwnRY" },
    .{ .name = "sceAvPlayerSetLooping", .function = trace.wrap("sceAvPlayerSetLooping", &avPlayerAction), .expect_id = "OVths0xGfho" },
    .{ .name = "sceAvPlayerSetAvSyncMode", .function = trace.wrap("sceAvPlayerSetAvSyncMode", &avPlayerAction), .expect_id = "k-q+xOxdc3E" },
    .{ .name = "sceAvPlayerSetAvailableBandwidth", .function = trace.wrap("sceAvPlayerSetAvailableBandwidth", &avPlayerAction), .expect_id = "N6Oy-EjduiY" },
    .{ .name = "sceAvPlayerJumpToTime", .function = trace.wrap("sceAvPlayerJumpToTime", &avPlayerAction), .expect_id = "XC9wM+xULz8" },
    .{ .name = "sceAvPlayerChangeStream", .function = trace.wrap("sceAvPlayerChangeStream", &avPlayerAction), .expect_id = "buMCiJftcfw" },
    .{ .name = "sceAvPlayerEnableStream", .function = trace.wrap("sceAvPlayerEnableStream", &avPlayerAction), .expect_id = "ODJK2sn9w4A" },
    .{ .name = "sceAvPlayerGetVideoDataEx", .function = trace.wrap("sceAvPlayerGetVideoDataEx", &avPlayerNoFrame), .expect_id = "JdksQu8pNdQ" },
    .{ .name = "sceAvPlayerGetAudioData", .function = trace.wrap("sceAvPlayerGetAudioData", &avPlayerNoFrame), .expect_id = "Wnp1OVcrZgk" },
    .{ .name = "sceAvPlayerGetStreamInfoEx", .function = trace.wrap("sceAvPlayerGetStreamInfoEx", &avPlayerAction), .expect_id = "ctTAcF5DiKQ" },
    .{ .name = "sceAvPlayerStreamCount", .function = trace.wrap("sceAvPlayerStreamCount", &avPlayerStreamCount), .expect_id = "hdTyRzCXQeQ" },
    .{ .name = "sceAvPlayerIsActive", .function = trace.wrap("sceAvPlayerIsActive", &avPlayerNoFrame), .expect_id = "UbQoYawOsfY" },
    .{ .name = "sceAvPlayerClose", .function = trace.wrap("sceAvPlayerClose", &avPlayerClose), .expect_id = "NkJwDzKmIlw" },
    .{ .name = "sceAvPlayerSetLogCallback", .function = trace.wrap("sceAvPlayerSetLogCallback", &success), .expect_id = "eBTreZ84JFY" },
};

// Offline platform peripherals and account services -----------------------

fn outputZero32(_: i32, output: ?*u32) callconv(abi.guest) i32 {
    if (output) |value| value.* = 0;
    return errno.ok;
}

fn outputZero64(_: i32, output: ?*u64) callconv(abi.guest) i32 {
    if (output) |value| value.* = 0;
    return errno.ok;
}

fn availableSpace(_: u32, output: ?*u64) callconv(abi.guest) i32 {
    const value = output orelse return invalid_argument;
    value.* = 1024 * 1024;
    return errno.ok;
}

fn mouseOpen(_: i32, _: i32, _: i32, _: ?*const anyopaque) callconv(abi.guest) i32 {
    return @bitCast(@as(u32, 0x8024_0001));
}

fn mouseRead(_: i32, _: ?*anyopaque, _: i32) callconv(abi.guest) i32 {
    return 0;
}

const app_content_exports = [_]symbols.Export{
    .{ .name = "sceAppContentAddcontMount", .function = trace.wrap("sceAppContentAddcontMount", &success), .expect_id = "VANhIWcqYak" },
    .{ .name = "sceAppContentAddcontUnmount", .function = trace.wrap("sceAppContentAddcontUnmount", &success), .expect_id = "3rHWaV-1KC4" },
    .{ .name = "sceAppContentTemporaryDataFormat", .function = trace.wrap("sceAppContentTemporaryDataFormat", &success), .expect_id = "a5N7lAG0y2Q" },
    .{ .name = "sceAppContentTemporaryDataGetAvailableSpaceKb", .function = trace.wrap("sceAppContentTemporaryDataGetAvailableSpaceKb", &availableSpace), .expect_id = "SaKib2Ug0yI" },
    .{ .name = "sceAppContentDownloadDataGetAvailableSpaceKb", .function = trace.wrap("sceAppContentDownloadDataGetAvailableSpaceKb", &availableSpace), .expect_id = "Gl6w5i0JokY" },
    .{ .name = "sceAppContentAppParamGetInt", .function = trace.wrap("sceAppContentAppParamGetInt", &outputZero32), .expect_id = "99b82IKXpH4" },
};

const np_manager_exports = [_]symbols.Export{
    .{ .name = "sceNpGetAccountIdA", .function = trace.wrap("sceNpGetAccountIdA", &outputZero64), .expect_id = "rbknaUjpqWo" },
    .{ .name = "sceNpGetAccountCountryA", .function = trace.wrap("sceNpGetAccountCountryA", &outputZero32), .expect_id = "JT+t00a3TxA" },
    .{ .name = "sceNpGetState", .function = trace.wrap("sceNpGetState", &outputZero32), .expect_id = "eQH7nWPcAgc" },
    .{ .name = "sceNpGetNpReachabilityState", .function = trace.wrap("sceNpGetNpReachabilityState", &outputZero32), .expect_id = "e-ZuhGEoeC4" },
};

const remoteplay_exports = [_]symbols.Export{
    .{ .name = "sceRemoteplayInitialize", .function = trace.wrap("sceRemoteplayInitialize", &success), .expect_id = "k1SwgkMSOM8" },
    .{ .name = "sceRemoteplayGetConnectionStatus", .function = trace.wrap("sceRemoteplayGetConnectionStatus", &outputZero32), .expect_id = "g3PNjYKWqnQ" },
};

const mouse_exports = [_]symbols.Export{
    .{ .name = "sceMouseInit", .function = trace.wrap("sceMouseInit", &success), .expect_id = "Qs0wWulgl7U" },
    .{ .name = "sceMouseOpen", .function = trace.wrap("sceMouseOpen", &mouseOpen), .expect_id = "RaqxZIf6DvE" },
    .{ .name = "sceMouseRead", .function = trace.wrap("sceMouseRead", &mouseRead), .expect_id = "x8qnXqh-tiM" },
    .{ .name = "sceMouseClose", .function = trace.wrap("sceMouseClose", &success), .expect_id = "cAnT0Rw-IwU" },
};

// Save-data memory is accepted as an in-process compatibility surface. The
// title still sees no persistent storage until a VFS-backed implementation is
// attached.
const save_data_exports = [_]symbols.Export{
    .{ .name = "sceSaveDataInitialize3", .function = trace.wrap("sceSaveDataInitialize3", &success), .expect_id = "TywrFKCoLGY" },
    .{ .name = "sceSaveDataSetupSaveDataMemory2", .function = trace.wrap("sceSaveDataSetupSaveDataMemory2", &success), .expect_id = "oQySEUfgXRA" },
    .{ .name = "sceSaveDataGetSaveDataMemory2", .function = trace.wrap("sceSaveDataGetSaveDataMemory2", &success), .expect_id = "QwOO7vegnV8" },
    .{ .name = "sceSaveDataSetSaveDataMemory2", .function = trace.wrap("sceSaveDataSetSaveDataMemory2", &success), .expect_id = "cduy9v4YmT4" },
    .{ .name = "sceSaveDataSyncSaveDataMemory", .function = trace.wrap("sceSaveDataSyncSaveDataMemory", &success), .expect_id = "wiT9jeC7xPw" },
};

const sysmodule_bootstrap_exports = [_]symbols.Export{
    .{ .name = "sceSysmoduleUnloadModule", .function = trace.wrap("sceSysmoduleUnloadModule", &success), .expect_id = "eR2bZFAAU0Q" },
    .{ .name = "sceSysmoduleIsLoaded", .function = trace.wrap("sceSysmoduleIsLoaded", &success), .expect_id = "fMP5NHUOaMk" },
};

// AGC command construction ------------------------------------------------

const AgcCommandBuffer = extern struct {
    bottom: ?[*]u32,
    top: ?[*]u32,
    cursor_up: ?[*]u32,
    cursor_down: ?[*]u32,
    callback: ?*const anyopaque,
    user_data: ?*anyopaque,
    reserved_dwords: u32,
};

fn reserveAgcDwords(buffer: ?*AgcCommandBuffer, dword_count: usize) ?[*]u32 {
    if (dword_count == 0 or dword_count > std.math.maxInt(usize) / @sizeOf(u32)) return null;
    const state = buffer orelse return null;
    const cursor = state.cursor_up orelse state.bottom orelse return null;
    const top = state.top orelse return null;
    const cursor_address = @intFromPtr(cursor);
    const top_address = @intFromPtr(top);
    const byte_count = dword_count * @sizeOf(u32);
    if (cursor_address > top_address or top_address - cursor_address < byte_count) return null;
    state.cursor_up = cursor + dword_count;
    return cursor;
}

fn reserveAgcCommand(buffer: ?*AgcCommandBuffer) ?[*]u32 {
    return reserveAgcDwords(buffer, 16);
}

fn pm4Header(opcode: u8, body_words: usize) u32 {
    std.debug.assert(body_words > 0 and body_words <= 0x4000);
    return (@as(u32, 3) << 30) |
        (@as(u32, @intCast(body_words - 1)) << 16) |
        (@as(u32, opcode) << 8);
}

fn writeAgcPacket(buffer: ?*AgcCommandBuffer, opcode: u8, body: []const u32) ?[*]u32 {
    const cursor = reserveAgcCommand(buffer) orelse return null;
    cursor[0] = pm4Header(opcode, body.len);
    @memcpy(cursor[1 .. 1 + body.len], body);

    const used = 1 + body.len;
    const remaining = 16 - used;
    if (remaining != 0) {
        // Specialised writers keep the old fixed footprint until all matching
        // GetSize entry points have their exact retail widths.
        std.debug.assert(remaining >= 2);
        cursor[used] = pm4Header(gpu.pm4.nop, remaining - 1);
        @memset(cursor[used + 1 .. 16], 0);
    }
    return cursor;
}

fn agcCommand(buffer: ?*AgcCommandBuffer, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) ?[*]u32 {
    const body = [_]u32{0} ** 15;
    return writeAgcPacket(buffer, gpu.pm4.nop, &body);
}

fn agcDispatch(
    buffer: ?*AgcCommandBuffer,
    group_x: u32,
    group_y: u32,
    group_z: u32,
    modifier: u32,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    const body = [_]u32{ group_x, group_y, group_z, (modifier & 0xa038) | 0x41 };
    return writeAgcPacket(buffer, gpu.pm4.dispatch_direct, &body);
}

fn agcDrawIndex(
    buffer: ?*AgcCommandBuffer,
    index_count: u32,
    index_address: u64,
    modifier: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    if (index_address == 0 or index_address & 1 != 0) return null;
    const initiator: u32 = if (modifier & (@as(u64, 1) << 32) != 0)
        0
    else
        @as(u32, @truncate(modifier >> 3)) & 0x20;
    const body = [_]u32{
        if (index_count == 0) 1 else index_count,
        @truncate(index_address),
        @truncate(index_address >> 32),
        index_count,
        initiator,
    };
    return writeAgcPacket(buffer, gpu.pm4.draw_index_2, &body);
}

fn agcSetNumInstances(
    buffer: ?*AgcCommandBuffer,
    instance_count: u32,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    const body = [_]u32{instance_count};
    return writeAgcPacket(buffer, gpu.pm4.num_instances, &body);
}

fn agcSetRegistersIndirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    opcode: u8,
) ?[*]u32 {
    const body = [_]u32{
        @as(u32, @truncate(registers_address)) & 0xffff_fffc,
        @truncate(registers_address >> 32),
        0x8000_0000,
        register_count & 0x3fff,
    };
    return writeAgcPacket(buffer, opcode, &body);
}

fn agcSetCxRegistersIndirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    return agcSetRegistersIndirect(buffer, registers_address, register_count, gpu.pm4.set_context_reg_indirect);
}

fn agcSetShRegistersIndirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    return agcSetRegistersIndirect(buffer, registers_address, register_count, gpu.pm4.set_sh_reg_indirect);
}

fn agcSetUcRegistersIndirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    return agcSetRegistersIndirect(buffer, registers_address, register_count, gpu.pm4.set_uconfig_reg_indirect);
}

fn agcSetShRegisterRangeDirect(
    buffer: ?*AgcCommandBuffer,
    first_register: u32,
    values_address: u64,
    value_count: u32,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    if (value_count == 0 or value_count > 0x3fff) return null;
    const byte_count = @as(usize, value_count) * @sizeOf(u32);
    if (values_address != 0 and
        (values_address & (@alignOf(u32) - 1) != 0 or !accessible(values_address, byte_count))) return null;

    const total_dwords = @as(usize, value_count) + 2;
    const cursor = reserveAgcDwords(buffer, total_dwords) orelse return null;
    cursor[0] = pm4Header(gpu.pm4.set_sh_reg, @as(usize, value_count) + 1);
    cursor[1] = first_register & 0xffff;
    if (values_address == 0) {
        @memset(cursor[2..total_dwords], 0);
    } else {
        const values: [*]const u32 = @ptrFromInt(values_address);
        @memcpy(cursor[2..total_dwords], values[0..value_count]);
    }
    return cursor;
}

fn agcSetShRegisterRangeDirectGetSize(value_count: u32) callconv(abi.guest) u32 {
    if (value_count == 0 or value_count > 0x3fff) return 0;
    return (value_count + 2) * @sizeOf(u32);
}

fn agcPatch(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

/// Guest libSceAgc's SuspendPoint busy-waits and prints TRC R5089 forever when
/// the real GPU is not there. Prefer the HLE entry (see preferHleImportId) and
/// yield so other threads can submit frames.
fn agcSuspendPoint() callconv(abi.guest) i32 {
    if (kernel_runtime.guestStopRequested()) {
        kernel_threading.scePthreadExit(null);
    }
    // ~1 ms: enough to free a core without under-pacing a 60 Hz flip loop.
    _ = kernel_threading.sceKernelUsleep(1_000);
    return errno.ok;
}

fn agcGetSize(_: u64) callconv(abi.guest) u32 {
    return 64;
}

var register_defaults: [256]u32 align(16) = [_]u32{0} ** 256;

fn agcGetRegisterDefaults(_: u32) callconv(abi.guest) *anyopaque {
    return &register_defaults;
}

const shader_file_header: u32 = 0x3433_3231;
const shader_version: u32 = 0x18;
const shader_structure_size: usize = 0x60;
const shader_user_data_offset: usize = 0x08;
const shader_code_offset: usize = 0x10;
const shader_cx_registers_offset: usize = 0x18;
const shader_sh_registers_offset: usize = 0x20;
const shader_specials_offset: usize = 0x28;
const shader_input_semantics_offset: usize = 0x30;
const shader_output_semantics_offset: usize = 0x38;
const shader_type_offset: usize = 0x5a;
const shader_sh_register_count_offset: usize = 0x5c;

const ShaderRegister = extern struct {
    offset: u32,
    value: u32,
};

fn accessible(address: u64, length: usize) bool {
    return kernel_memory.isGuestRangeAccessible(address, length);
}

fn relocateShaderPointer(field_address: u64) bool {
    if (!accessible(field_address, @sizeOf(u64))) return false;
    const field: *u64 = @ptrFromInt(field_address);
    if (field.* != 0) field.* +%= field_address;
    return true;
}

// Prospero ShaderBinaryType: Cs=0 Ps=1 Gs=2 Hs=3 GsFront=4 HsFront=5 GsBack=6 HsBack=7 Fs=8.
// Front halves and fetch shaders publish no program PGM pair; fuse writes the
// front code address into the fused back-half SH table (ES or LS bank).
fn shaderProgramRegisters(shader_type: u8) ?struct { low: u32, high: u32 } {
    return switch (shader_type) {
        0 => .{ .low = 0x20c, .high = 0x20d }, // compute
        1 => .{ .low = 0x008, .high = 0x009 }, // pixel
        2 => .{ .low = 0x0c8, .high = 0x0c9 }, // GS / NGG export (ES bank)
        3 => .{ .low = 0x148, .high = 0x149 }, // HS (LS bank)
        6 => .{ .low = 0x088, .high = 0x089 }, // GS back half
        7 => .{ .low = 0x108, .high = 0x109 }, // HS back half
        else => null, // 4 GsFront, 5 HsFront, 8 Fs: no PGM pair here
    };
}

fn isShaderFrontOrFetch(shader_type: u8) bool {
    return shader_type == 4 or shader_type == 5 or shader_type == 8;
}

fn isFusableShaderPair(front_type: u8, back_type: u8) bool {
    return (front_type == 4 and back_type == 6) or (front_type == 5 and back_type == 7);
}

fn findShaderRegister(registers: [*]ShaderRegister, count: u8, offset: u32, occurrence: u32) ?*ShaderRegister {
    var seen: u32 = 0;
    for (registers[0..count]) |*entry| {
        if (entry.offset != offset) continue;
        if (seen == occurrence) return entry;
        seen += 1;
    }
    return null;
}

fn patchShaderRegisterAddress(registers: [*]ShaderRegister, count: u8, lo_offset: u32, address: u64) void {
    const low = findShaderRegister(registers, count, lo_offset, 0) orelse return;
    const high = findShaderRegister(registers, count, lo_offset + 1, 0) orelse return;
    low.value = @truncate(address >> 8);
    high.value = (high.value & 0xffff_ff00) | @as(u32, @truncate(address >> 40));
}

fn patchShaderProgram(header_address: u64, code_address: u64) ?u64 {
    if (!accessible(header_address, shader_structure_size)) return null;
    const bytes: [*]u8 = @ptrFromInt(header_address);
    const shader_type = bytes[shader_type_offset];
    // Front halves publish their program address when they are fused with the
    // back half. Fetch shaders likewise have no SH program pair in this table.
    const wanted = shaderProgramRegisters(shader_type) orelse
        return if (isShaderFrontOrFetch(shader_type)) code_address else null;
    const count = bytes[shader_sh_register_count_offset];
    const registers_address = @as(*const u64, @ptrFromInt(header_address + shader_sh_registers_offset)).*;
    if (registers_address == 0 or !accessible(registers_address, @as(usize, count) * @sizeOf(ShaderRegister))) {
        return null;
    }

    const registers: [*]ShaderRegister = @ptrFromInt(registers_address);
    var low: ?*ShaderRegister = null;
    var high: ?*ShaderRegister = null;
    for (registers[0..count]) |*entry| {
        if (entry.offset == wanted.low) low = entry;
        if (entry.offset == wanted.high) high = entry;
    }
    if (low == null or high == null) return null;

    const shader_offset = (@as(u64, low.?.value) << 8) | (@as(u64, high.?.value & 0xff) << 40);
    const program_address = code_address +% shader_offset;
    low.?.value = @truncate(program_address >> 8);
    high.?.value = (high.?.value & 0xffff_ff00) | @as(u32, @truncate(program_address >> 40));
    return program_address;
}

fn agcCreateShader(
    output: ?*?*anyopaque,
    header: ?*anyopaque,
    code: ?*const volatile anyopaque,
) callconv(abi.guest) i32 {
    const header_pointer = header orelse return invalid_argument;
    const code_pointer = code orelse return invalid_argument;
    const header_address = @intFromPtr(header_pointer);
    const code_address = @intFromPtr(code_pointer);
    if (!accessible(header_address, shader_structure_size)) return errno.KernelError.efault.raw();

    const header_words: *const [2]u32 = @ptrFromInt(header_address);
    if (header_words[0] != shader_file_header or header_words[1] != shader_version) {
        return invalid_argument;
    }
    const pointer_fields = [_]usize{
        shader_cx_registers_offset,
        shader_sh_registers_offset,
        shader_user_data_offset,
        shader_specials_offset,
        shader_input_semantics_offset,
        shader_output_semantics_offset,
    };
    for (pointer_fields) |offset| {
        if (!relocateShaderPointer(header_address + offset)) return errno.KernelError.efault.raw();
    }
    @as(*u64, @ptrFromInt(header_address + shader_code_offset)).* = code_address;

    const user_data_address = @as(*const u64, @ptrFromInt(header_address + shader_user_data_offset)).*;
    if (user_data_address != 0) {
        for ([_]usize{ 0, 8, 16, 24, 32 }) |offset| {
            if (!relocateShaderPointer(user_data_address + offset)) return errno.KernelError.efault.raw();
        }
    }
    const program_address = patchShaderProgram(header_address, code_address) orelse return invalid_argument;
    // Prefer the front-half header for registry lookups: fused Gs/Hs headers
    // clear user_data, while the export program still runs front code and the
    // attribute / SRT tables live on the front half.
    _ = agc_shader_registry.record(code_address, header_address);
    if (program_address != code_address) _ = agc_shader_registry.record(program_address, header_address);
    if (output) |destination| destination.* = header_pointer;
    return errno.ok;
}

const shader_special_vgt_stages_offset: usize = 0x08;
const spi_shader_pgm_chksum_gs: u32 = 0x80;
const spi_shader_pgm_lo_es: u32 = 0x0c8;
const spi_shader_pgm_lo_ls: u32 = 0x148;
const fused_shader_scratch_align: u64 = 4;
const graphics_error_invalid_shader_halves: i32 = @bitCast(@as(u32, 0x8a6c_0008));

const SizeAlign = extern struct {
    size: u64,
    align_bytes: u64,
};

fn agcGetFusedShaderSize(
    destination: ?*SizeAlign,
    front: ?*const anyopaque,
    back: ?*const anyopaque,
) callconv(abi.guest) i32 {
    const out = destination orelse return invalid_argument;
    const front_address = @intFromPtr(front orelse return invalid_argument);
    const back_address = @intFromPtr(back orelse return invalid_argument);
    if (!accessible(front_address, shader_structure_size) or !accessible(back_address, shader_structure_size)) {
        return errno.KernelError.efault.raw();
    }
    const front_bytes: [*]const u8 = @ptrFromInt(front_address);
    const back_bytes: [*]const u8 = @ptrFromInt(back_address);
    if (!isFusableShaderPair(front_bytes[shader_type_offset], back_bytes[shader_type_offset])) {
        return graphics_error_invalid_shader_halves;
    }
    const register_count = back_bytes[shader_sh_register_count_offset];
    out.* = .{
        .size = @as(u64, register_count) * @sizeOf(ShaderRegister),
        .align_bytes = fused_shader_scratch_align,
    };
    return errno.ok;
}

fn agcFuseShaderHalves(
    fused: ?*anyopaque,
    front: ?*const anyopaque,
    back: ?*const anyopaque,
    scratch: ?*anyopaque,
) callconv(abi.guest) i32 {
    const fused_address = @intFromPtr(fused orelse return invalid_argument);
    const front_address = @intFromPtr(front orelse return invalid_argument);
    const back_address = @intFromPtr(back orelse return invalid_argument);
    if (!accessible(fused_address, shader_structure_size) or
        !accessible(front_address, shader_structure_size) or
        !accessible(back_address, shader_structure_size))
    {
        return errno.KernelError.efault.raw();
    }

    const front_bytes: [*]const u8 = @ptrFromInt(front_address);
    const back_bytes: [*]const u8 = @ptrFromInt(back_address);
    const front_type = front_bytes[shader_type_offset];
    const back_type = back_bytes[shader_type_offset];
    if (!isFusableShaderPair(front_type, back_type)) return graphics_error_invalid_shader_halves;

    const is_geometry = front_type == 4;
    // Wave32 enable bits in VGT_SHADER_STAGES_EN must agree across halves.
    const front_specials = @as(*const u64, @ptrFromInt(front_address + shader_specials_offset)).*;
    const back_specials = @as(*const u64, @ptrFromInt(back_address + shader_specials_offset)).*;
    if (front_specials != 0 and back_specials != 0) {
        if (!accessible(front_specials + shader_special_vgt_stages_offset + 4, 4) or
            !accessible(back_specials + shader_special_vgt_stages_offset + 4, 4))
        {
            return errno.KernelError.efault.raw();
        }
        const front_stages = @as(*const u32, @ptrFromInt(front_specials + shader_special_vgt_stages_offset + 4)).*;
        const back_stages = @as(*const u32, @ptrFromInt(back_specials + shader_special_vgt_stages_offset + 4)).*;
        const wave_bit: u32 = if (is_geometry) (@as(u32, 1) << 22) else (@as(u32, 1) << 21);
        if ((front_stages ^ back_stages) & wave_bit != 0) return graphics_error_invalid_shader_halves;
    }

    // Fused header starts as a copy of the back half, then becomes Gs/Hs.
    const fused_bytes: [*]u8 = @ptrFromInt(fused_address);
    const back_src: [*]const u8 = @ptrFromInt(back_address);
    @memcpy(fused_bytes[0..shader_structure_size], back_src[0..shader_structure_size]);
    fused_bytes[shader_type_offset] = if (is_geometry) 2 else 3;
    @as(*u64, @ptrFromInt(fused_address + shader_user_data_offset)).* = 0;

    const back_registers_address = @as(*const u64, @ptrFromInt(back_address + shader_sh_registers_offset)).*;
    const register_count = back_bytes[shader_sh_register_count_offset];
    var fused_registers_address = back_registers_address;
    if (scratch) |scratch_pointer| {
        if (back_registers_address != 0 and register_count != 0) {
            const byte_count = @as(usize, register_count) * @sizeOf(ShaderRegister);
            const scratch_address = @intFromPtr(scratch_pointer);
            if (!accessible(back_registers_address, byte_count) or !accessible(scratch_address, byte_count)) {
                return errno.KernelError.efault.raw();
            }
            const dst: [*]u8 = @ptrFromInt(scratch_address);
            const src: [*]const u8 = @ptrFromInt(back_registers_address);
            @memcpy(dst[0..byte_count], src[0..byte_count]);
            fused_registers_address = scratch_address;
        }
    }
    @as(*u64, @ptrFromInt(fused_address + shader_sh_registers_offset)).* = fused_registers_address;

    const front_code = @as(*const u64, @ptrFromInt(front_address + shader_code_offset)).*;
    if (fused_registers_address != 0 and register_count != 0) {
        if (!accessible(fused_registers_address, @as(usize, register_count) * @sizeOf(ShaderRegister))) {
            return errno.KernelError.efault.raw();
        }
        const fused_regs: [*]ShaderRegister = @ptrFromInt(fused_registers_address);
        if (is_geometry) {
            const front_registers_address = @as(*const u64, @ptrFromInt(front_address + shader_sh_registers_offset)).*;
            const front_count = front_bytes[shader_sh_register_count_offset];
            if (front_registers_address != 0 and front_count != 0 and
                accessible(front_registers_address, @as(usize, front_count) * @sizeOf(ShaderRegister)))
            {
                const front_regs: [*]ShaderRegister = @ptrFromInt(front_registers_address);
                for (0..2) |occurrence| {
                    const dst = findShaderRegister(fused_regs, register_count, spi_shader_pgm_chksum_gs, @intCast(occurrence));
                    const src = findShaderRegister(front_regs, front_count, spi_shader_pgm_chksum_gs, @intCast(occurrence));
                    if (dst) |d| {
                        if (src) |s| d.value = s.value;
                    }
                }
            }
            patchShaderRegisterAddress(fused_regs, register_count, spi_shader_pgm_lo_es, front_code);
        } else {
            patchShaderRegisterAddress(fused_regs, register_count, spi_shader_pgm_lo_ls, front_code);
        }
    }

    // Draw-time lookup keys off the export program address (front code). The
    // front header still owns user_data / attribute tables after user_data is
    // cleared on the fused object.
    if (front_code != 0) _ = agc_shader_registry.record(front_code, front_address);
    return errno.ok;
}

fn agcCreatePrimState(
    cx_registers: ?[*]ShaderRegister,
    uc_registers: ?[*]ShaderRegister,
    _: ?*const anyopaque,
    geometry_shader: ?*const anyopaque,
    primitive_type: u32,
    _: u64,
) callconv(abi.guest) i32 {
    if (cx_registers == null and uc_registers == null) return errno.ok;
    const shader = geometry_shader orelse return invalid_argument;
    const shader_address = @intFromPtr(shader);
    if (!accessible(shader_address, shader_structure_size)) return errno.KernelError.efault.raw();
    const specials_address = @as(*const u64, @ptrFromInt(shader_address + shader_specials_offset)).*;
    if (specials_address == 0 or !accessible(specials_address, 0x30)) return invalid_argument;
    const specials: [*]const ShaderRegister = @ptrFromInt(specials_address);

    if (cx_registers) |cx| {
        cx[0] = specials[1]; // VGT_SHADER_STAGES_EN at +0x08
        cx[1] = specials[4]; // VGT_GS_OUT_PRIM_TYPE at +0x20
    }
    if (uc_registers) |uc| {
        uc[0] = specials[0]; // GE_CNTL at +0x00
        uc[1] = specials[5]; // GE_USER_VGPR_EN at +0x28
        uc[2] = .{ .offset = 0x242, .value = primitive_type };
    }
    return errno.ok;
}

const agc_exports = [_]symbols.Export{
    .{ .name = "sceAgcInitialize", .function = trace.wrap("sceAgcInitialize", &agcPatch), .id_override = "23LRUSvYu1M" },
    .{ .name = "sceAgcGetRegisterDefaults2", .function = trace.wrap("sceAgcGetRegisterDefaults2", &agcGetRegisterDefaults), .expect_id = "2JtWUUiYBXs" },
    .{ .name = "sceAgcGetRegisterDefaults2Internal", .function = trace.wrap("sceAgcGetRegisterDefaults2Internal", &agcGetRegisterDefaults), .expect_id = "wRbq6ZjNop4" },
    .{ .name = "sceAgcCreateShader", .function = trace.wrap("sceAgcCreateShader", &agcCreateShader), .expect_id = "f3dg2CSgRKY" },
    .{ .name = "sceAgcUnknownGetFusedShaderSize", .function = trace.wrap("sceAgcUnknownGetFusedShaderSize", &agcGetFusedShaderSize), .id_override = "dolOmWH+huQ" },
    .{ .name = "sceAgcUnknownFuseShaderHalves", .function = trace.wrap("sceAgcUnknownFuseShaderHalves", &agcFuseShaderHalves), .id_override = "fd5Bp5tGTgo" },
    .{ .name = "sceAgcSetCxRegIndirectPatchSetAddress", .function = trace.wrap("sceAgcSetCxRegIndirectPatchSetAddress", &agcPatch), .expect_id = "vcmNN+AAXnY" },
    .{ .name = "sceAgcSetShRegIndirectPatchSetAddress", .function = trace.wrap("sceAgcSetShRegIndirectPatchSetAddress", &agcPatch), .expect_id = "Qrj4c+61z4A" },
    .{ .name = "sceAgcSetUcRegIndirectPatchSetAddress", .function = trace.wrap("sceAgcSetUcRegIndirectPatchSetAddress", &agcPatch), .expect_id = "6lNcCp+fxi4" },
    .{ .name = "sceAgcSetCxRegIndirectPatchAddRegisters", .function = trace.wrap("sceAgcSetCxRegIndirectPatchAddRegisters", &agcPatch), .expect_id = "d-6uF9sZDIU" },
    .{ .name = "sceAgcSetShRegIndirectPatchAddRegisters", .function = trace.wrap("sceAgcSetShRegIndirectPatchAddRegisters", &agcPatch), .expect_id = "z2duB-hHQSM" },
    .{ .name = "sceAgcSetUcRegIndirectPatchAddRegisters", .function = trace.wrap("sceAgcSetUcRegIndirectPatchAddRegisters", &agcPatch), .expect_id = "vRoArM9zaIk" },
    .{ .name = "sceAgcCreatePrimState", .function = trace.wrap("sceAgcCreatePrimState", &agcCreatePrimState), .expect_id = "D9sr1xGUriE" },
    .{ .name = "sceAgcWriteDataPatchSetAddressOrOffset", .function = trace.wrap("sceAgcWriteDataPatchSetAddressOrOffset", &agcPatch), .expect_id = "fPSCdQxgpSw" },
    .{ .name = "sceAgcQueueEndOfPipeActionPatchAddress", .function = trace.wrap("sceAgcQueueEndOfPipeActionPatchAddress", &agcPatch), .expect_id = "0fWWK5uG9rQ" },
    .{ .name = "sceAgcWaitRegMemPatchAddress", .function = trace.wrap("sceAgcWaitRegMemPatchAddress", &agcPatch), .expect_id = "3KDcnM3lrcU" },
    .{ .name = "sceAgcSetNop", .function = trace.wrap("sceAgcSetNop", &agcPatch), .expect_id = "K2mciNVxUCE" },
    .{ .name = "sceAgcSuspendPoint", .function = trace.wrap("sceAgcSuspendPoint", &agcSuspendPoint), .expect_id = "h9z6+0hEydk" },
    .{ .name = "sceAgcGetIsTrinityMode", .function = trace.wrap("sceAgcGetIsTrinityMode", &agcPatch), .expect_id = "BfBDZGbti7A" },
    .{ .name = "sceAgcDebugRaiseException", .function = trace.wrap("sceAgcDebugRaiseException", &agcPatch), .expect_id = "T6xuVw0KUJo" },
    .{ .name = "sceAgcCbSetShRegisterRangeDirectGetSize", .function = trace.wrap("sceAgcCbSetShRegisterRangeDirectGetSize", &agcSetShRegisterRangeDirectGetSize), .expect_id = "bxGoVxpdSPQ" },
    .{ .name = "sceAgcUnknownDb", .function = trace.wrap("sceAgcUnknownDb", &agcPatch), .id_override = "dbOlWdppb4o" },
    .{ .name = "sceAgcUnknownKRzWekV120", .function = trace.wrap("sceAgcUnknownKRzWekV120", &agcPatch), .id_override = "-KRzWekV120" },
    .{ .name = "sceAgcUnknownIkfdtRIqCE", .function = trace.wrap("sceAgcUnknownIkfdtRIqCE", &agcPatch), .id_override = "Ikfdt-rIqCE" },
    .{ .name = "sceAgcGetDataPacketPayloadAddress", .function = trace.wrap("sceAgcGetDataPacketPayloadAddress", &agcPatch), .id_override = "V++UgBtQhn0" },

    .{ .name = "sceAgcCbNop", .function = trace.wrap("sceAgcCbNop", &agcCommand), .expect_id = "LtTouSCZjHM" },
    .{ .name = "sceAgcCbDispatch", .function = trace.wrap("sceAgcCbDispatch", &agcDispatch), .expect_id = "k3GhuSNmBLU" },
    .{ .name = "sceAgcCbSetShRegisterRangeDirect", .function = trace.wrap("sceAgcCbSetShRegisterRangeDirect", &agcSetShRegisterRangeDirect), .expect_id = "n2fD4A+pb+g" },
    .{ .name = "sceAgcCbSetShRegistersDirect", .function = trace.wrap("sceAgcCbSetShRegistersDirect", &agcCommand), .expect_id = "UZbQjYAwwXM" },
    .{ .name = "sceAgcCbSetUcRegistersDirect", .function = trace.wrap("sceAgcCbSetUcRegistersDirect", &agcCommand), .expect_id = "03RZmELWWzw" },
    .{ .name = "sceAgcCbReleaseMem", .function = trace.wrap("sceAgcCbReleaseMem", &agcCommand), .expect_id = "wr23dPKyWc0" },

    .{ .name = "sceAgcAcbResetQueue", .function = trace.wrap("sceAgcAcbResetQueue", &agcCommand), .expect_id = "JrtiDtKeS38" },
    .{ .name = "sceAgcAcbDispatchIndirect", .function = trace.wrap("sceAgcAcbDispatchIndirect", &agcCommand), .expect_id = "j3EtxFkSIhQ" },
    .{ .name = "sceAgcAcbWaitUntilSafeForRendering", .function = trace.wrap("sceAgcAcbWaitUntilSafeForRendering", &agcCommand), .expect_id = "GPbUp9jXQa8" },
    .{ .name = "sceAgcAcbWaitRegMem", .function = trace.wrap("sceAgcAcbWaitRegMem", &agcCommand), .expect_id = "htn36gPnBk4" },
    .{ .name = "sceAgcAcbAcquireMem", .function = trace.wrap("sceAgcAcbAcquireMem", &agcCommand), .expect_id = "KT-hTp-Ch14" },
    .{ .name = "sceAgcAcbDmaData", .function = trace.wrap("sceAgcAcbDmaData", &agcCommand), .expect_id = "-RnpfpxIhec" },
    .{ .name = "sceAgcAcbCopyData", .function = trace.wrap("sceAgcAcbCopyData", &agcCommand), .expect_id = "qzMN2XKGA4k" },
    .{ .name = "sceAgcAcbWriteData", .function = trace.wrap("sceAgcAcbWriteData", &agcCommand), .expect_id = "eZ4+17OQz4Q" },
    .{ .name = "sceAgcAcbEventWrite", .function = trace.wrap("sceAgcAcbEventWrite", &agcCommand), .expect_id = "cFazmnXpJOE" },
    .{ .name = "sceAgcAcbJump", .function = trace.wrap("sceAgcAcbJump", &agcCommand), .expect_id = "e1DFTg+Sd8U" },
    .{ .name = "sceAgcAcbPushMarker", .function = trace.wrap("sceAgcAcbPushMarker", &agcCommand), .expect_id = "cpCILPya5Zk" },
    .{ .name = "sceAgcAcbPopMarker", .function = trace.wrap("sceAgcAcbPopMarker", &agcCommand), .expect_id = "6mFxkVqdmbQ" },

    .{ .name = "sceAgcDcbResetQueue", .function = trace.wrap("sceAgcDcbResetQueue", &agcCommand), .expect_id = "TRO721eVt4g" },
    .{ .name = "sceAgcDcbWaitUntilSafeForRendering", .function = trace.wrap("sceAgcDcbWaitUntilSafeForRendering", &agcCommand), .expect_id = "MWiElSNE8j8" },
    .{ .name = "sceAgcDcbSetIndexBuffer", .function = trace.wrap("sceAgcDcbSetIndexBuffer", &agcCommand), .expect_id = "l4fM9K-Lyks" },
    .{ .name = "sceAgcDcbSetIndexCount", .function = trace.wrap("sceAgcDcbSetIndexCount", &agcCommand), .expect_id = "8N2tmT3jmC8" },
    .{ .name = "sceAgcDcbDrawIndex", .function = trace.wrap("sceAgcDcbDrawIndex", &agcDrawIndex), .expect_id = "q88lQ+GP5Yk" },
    .{ .name = "sceAgcDcbDrawIndexAuto", .function = trace.wrap("sceAgcDcbDrawIndexAuto", &agcCommand), .expect_id = "Yw0jKSqop+E" },
    .{ .name = "sceAgcDcbDrawIndexIndirect", .function = trace.wrap("sceAgcDcbDrawIndexIndirect", &agcCommand), .expect_id = "t1vNu082-jM" },
    .{ .name = "sceAgcDcbDrawIndirect", .function = trace.wrap("sceAgcDcbDrawIndirect", &agcCommand), .expect_id = "1q1titRBL6o" },
    .{ .name = "sceAgcDcbDispatchIndirect", .function = trace.wrap("sceAgcDcbDispatchIndirect", &agcCommand), .expect_id = "CtB+A9-VxO0" },
    .{ .name = "sceAgcDcbSetNumInstances", .function = trace.wrap("sceAgcDcbSetNumInstances", &agcSetNumInstances), .expect_id = "tSBxhAPyytQ" },
    .{ .name = "sceAgcDcbStallCommandBufferParser", .function = trace.wrap("sceAgcDcbStallCommandBufferParser", &agcCommand), .expect_id = "u2T2DiA5hRI" },
    .{ .name = "sceAgcDcbSetBaseIndirectArgs", .function = trace.wrap("sceAgcDcbSetBaseIndirectArgs", &agcCommand), .expect_id = "RmaJwLtc8rY" },
    .{ .name = "sceAgcDcbSetShRegistersIndirect", .function = trace.wrap("sceAgcDcbSetShRegistersIndirect", &agcSetShRegistersIndirect), .expect_id = "-HOOCn0JY48" },
    .{ .name = "sceAgcDcbSetUcRegistersIndirect", .function = trace.wrap("sceAgcDcbSetUcRegistersIndirect", &agcSetUcRegistersIndirect), .expect_id = "hvUfkUIQcOE" },
    .{ .name = "sceAgcDcbSetCxRegistersIndirect", .function = trace.wrap("sceAgcDcbSetCxRegistersIndirect", &agcSetCxRegistersIndirect), .expect_id = "ZvwO9euwYzc" },
    .{ .name = "sceAgcDcbWaitRegMem", .function = trace.wrap("sceAgcDcbWaitRegMem", &agcCommand), .expect_id = "VmW0Tdpy420" },
    .{ .name = "sceAgcDcbAcquireMem", .function = trace.wrap("sceAgcDcbAcquireMem", &agcCommand), .expect_id = "57labkp+rSQ" },
    .{ .name = "sceAgcDcbDmaData", .function = trace.wrap("sceAgcDcbDmaData", &agcCommand), .expect_id = "WmAc2MEj6Io" },
    .{ .name = "sceAgcDcbCopyData", .function = trace.wrap("sceAgcDcbCopyData", &agcCommand), .expect_id = "1rZSWUv1IRc" },
    .{ .name = "sceAgcDcbWriteData", .function = trace.wrap("sceAgcDcbWriteData", &agcCommand), .expect_id = "i1jyy49AjXU" },
    .{ .name = "sceAgcDcbEventWrite", .function = trace.wrap("sceAgcDcbEventWrite", &agcCommand), .expect_id = "aJf+j5yntiU" },
    .{ .name = "sceAgcDcbJump", .function = trace.wrap("sceAgcDcbJump", &agcCommand), .expect_id = "xSAR0LTcRKM" },
    .{ .name = "sceAgcDcbPushMarker", .function = trace.wrap("sceAgcDcbPushMarker", &agcCommand), .expect_id = "+kSrjIVxKFE" },
    .{ .name = "sceAgcDcbPopMarker", .function = trace.wrap("sceAgcDcbPopMarker", &agcCommand), .expect_id = "H7uZqCoNuWk" },
    .{ .name = "sceAgcDcbSetFlip", .function = trace.wrap("sceAgcDcbSetFlip", &agcCommand), .expect_id = "YUeqkyT7mEQ" },
};

const agc_driver_exports = [_]symbols.Export{
    .{ .name = "sceAgcDriverRegisterOwner", .function = trace.wrap("sceAgcDriverRegisterOwner", &success), .expect_id = "X-Nm5KLREeg" },
    .{ .name = "sceAgcDriverSetHsOffchipParam", .function = trace.wrap("sceAgcDriverSetHsOffchipParam", &success), .expect_id = "MM4IZSEYytQ" },
    .{ .name = "sceAgcDriverRegisterResource", .function = trace.wrap("sceAgcDriverRegisterResource", &success), .expect_id = "W5z4eZrjEas" },
    .{ .name = "sceAgcDriverAddEqEvent", .function = trace.wrap("sceAgcDriverAddEqEvent", &agc.driverAddEqEvent), .expect_id = "w2rJhmD+dsE" },
    .{ .name = "sceAgcDriverGetEqContextId", .function = trace.wrap("sceAgcDriverGetEqContextId", &agc.driverGetEqContextId), .expect_id = "Zw7uUVPulbw" },
    .{ .name = "sceAgcDriverSetTFRing", .function = trace.wrap("sceAgcDriverSetTFRing", &success), .expect_id = "XlNp7jzGiPo" },
};

const ampr_exports = [_]symbols.Export{
    .{ .name = "sceAmprCommandBufferConstructor", .function = trace.wrap("sceAmprCommandBufferConstructor", &amprCommandBufferConstructor), .expect_id = "8aI7R7WaOlc" },
    .{ .name = "sceAmprAprCommandBufferConstructor", .function = trace.wrap("sceAmprAprCommandBufferConstructor", &amprAprCommandBufferConstructor), .expect_id = "a8uLzYY--tM" },
    .{ .name = "sceAmprCommandBufferReset", .function = trace.wrap("sceAmprCommandBufferReset", &amprCommandBufferReset), .expect_id = "baQO9ez2gL4" },
    .{ .name = "sceAmprCommandBufferSetBuffer", .function = trace.wrap("sceAmprCommandBufferSetBuffer", &amprCommandBufferSetBuffer), .expect_id = "N-FSPA4S3nI" },
    .{ .name = "sceAmprAprCommandBufferReadFile", .function = trace.wrap("sceAmprAprCommandBufferReadFile", &amprAprCommandBufferReadFile), .expect_id = "mQ16-QdKv7k" },
};

pub fn reset() void {
    agc_shader_registry.reset();
    agc_submit.reset();
    video_out.reset();
    random_state.store(0x9e37_79b9_7f4a_7c15, .monotonic);
}

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libScePosix" }, .{ .name = "libkernel" }, &posix_exports);
    try db.addLibrary(gpa, .{ .name = "libSceRandom" }, .{ .name = "libSceRandom" }, &random_exports);
    try db.addLibrary(gpa, .{ .name = "libSceVideoOut" }, .{ .name = "libSceVideoOut" }, &video_out_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAvPlayer" }, .{ .name = "libSceAvPlayer", .version_minor = 0 }, &av_player_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAppContent" }, .{ .name = "libSceAppContentUtil" }, &app_content_exports);
    try db.addLibrary(gpa, .{ .name = "libSceNpManager" }, .{ .name = "libSceNpManager" }, &np_manager_exports);
    try db.addLibrary(gpa, .{ .name = "libSceRemoteplay" }, .{ .name = "libSceRemoteplay" }, &remoteplay_exports);
    try db.addLibrary(gpa, .{ .name = "libSceMouse" }, .{ .name = "libSceMouse" }, &mouse_exports);
    try db.addLibrary(gpa, .{ .name = "libSceSaveData_native" }, .{ .name = "libSceSaveData_native" }, &save_data_exports);
    try db.addLibrary(gpa, .{ .name = "libSceSysmodule" }, .{ .name = "libSceSysmodule" }, &sysmodule_bootstrap_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAgc" }, .{ .name = "libSceAgc" }, &agc_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAgcDriver" }, .{ .name = "libSceAgcDriver" }, &agc_driver_exports);
    // The submission entry points live apart from these, because unlike the
    // rest of this surface they read what the title passes rather than only
    // acknowledging it.
    try db.addLibrary(gpa, .{ .name = "libSceAgcDriver" }, .{ .name = "libSceAgcDriver" }, &agc_submit.exports);
    try db.addLibrary(gpa, .{ .name = "libSceAmpr" }, .{ .name = "libSceAmpr" }, &ampr_exports);
}

test "bootstrap AGC commands are one walkable PM4 NOP" {
    var words: [32]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try std.testing.expect(agcCommand(&command_buffer, 0, 0, 0, 0, 0) != null);
    try std.testing.expectEqual(words[0..].ptr + 16, command_buffer.cursor_up.?);

    var walker = gpu.pm4.Walker.init(words[0..16]);
    const packet = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.nop, packet.opcode);
    try std.testing.expectEqual(@as(usize, 16), packet.wordCount());
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC emits dispatch draw and instance packets in fixed slots" {
    var words: [48]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try std.testing.expect(agcDispatch(&command_buffer, 3, 5, 7, 0, 0) != null);
    try std.testing.expect(agcDrawIndex(&command_buffer, 6, 0x1234_5600, 0x4000_0000, 0, 0) != null);
    try std.testing.expect(agcSetNumInstances(&command_buffer, 2, 0, 0, 0, 0) != null);
    try std.testing.expectEqual(words[0..].ptr + words.len, command_buffer.cursor_up.?);

    var walker = gpu.pm4.Walker.init(&words);
    const dispatch = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.dispatch_direct, dispatch.opcode);
    try std.testing.expectEqualSlices(u32, &.{ 3, 5, 7, 0x41 }, dispatch.body);
    try std.testing.expectEqual(gpu.pm4.nop, (try walker.next()).?.opcode);

    const draw = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.draw_index_2, draw.opcode);
    try std.testing.expectEqualSlices(u32, &.{ 6, 0x1234_5600, 0, 6, 0 }, draw.body);
    try std.testing.expectEqual(gpu.pm4.nop, (try walker.next()).?.opcode);

    const instances = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.num_instances, instances.opcode);
    try std.testing.expectEqualSlices(u32, &.{2}, instances.body);
    try std.testing.expectEqual(gpu.pm4.nop, (try walker.next()).?.opcode);
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC emits native indirect register packets in fixed slots" {
    var words: [48]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    const address: u64 = 0x1234_5678_9abc_def0;
    try std.testing.expect(agcSetCxRegistersIndirect(&command_buffer, address, 7, 0, 0, 0) != null);
    try std.testing.expect(agcSetShRegistersIndirect(&command_buffer, address + 8, 11, 0, 0, 0) != null);
    try std.testing.expect(agcSetUcRegistersIndirect(&command_buffer, address + 16, 3, 0, 0, 0) != null);

    var walker = gpu.pm4.Walker.init(words[0..]);
    const expected = [_]u8{
        gpu.pm4.set_context_reg_indirect,
        gpu.pm4.nop,
        gpu.pm4.set_sh_reg_indirect,
        gpu.pm4.nop,
        gpu.pm4.set_uconfig_reg_indirect,
        gpu.pm4.nop,
    };
    for (expected) |opcode| try std.testing.expectEqual(opcode, (try walker.next()).?.opcode);
    try std.testing.expect((try walker.next()) == null);
    try std.testing.expectEqual(@as(u32, @truncate(address)) & 0xffff_fffc, words[1]);
    try std.testing.expectEqual(@as(u32, @truncate(address >> 32)), words[2]);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), words[3]);
    try std.testing.expectEqual(@as(u32, 7), words[4]);
}

test "bootstrap AGC shader range uses its exact variable packet size" {
    var words: [24]u32 = @splat(0xdead_beef);
    var values: [16]u32 = undefined;
    for (&values, 0..) |*value, index| value.* = @intCast(0x100 + index);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try std.testing.expectEqual(@as(u32, 72), agcSetShRegisterRangeDirectGetSize(values.len));
    try std.testing.expect(agcSetShRegisterRangeDirect(
        &command_buffer,
        0x240,
        @intFromPtr(&values),
        values.len,
        0,
        0,
    ) != null);
    try std.testing.expectEqual(words[0..].ptr + 18, command_buffer.cursor_up.?);

    var walker = gpu.pm4.Walker.init(words[0..18]);
    const packet = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.set_sh_reg, packet.opcode);
    try std.testing.expectEqual(@as(usize, 18), packet.wordCount());
    try std.testing.expectEqual(@as(u32, 0x240), packet.body[0]);
    try std.testing.expectEqualSlices(u32, &values, packet.body[1..]);
    try std.testing.expect((try walker.next()) == null);
}

test "shader creation relocates its header and builds primitive state" {
    var header: [shader_structure_size]u8 align(8) = @splat(0);
    var registers = [_]ShaderRegister{
        .{ .offset = 0x0c8, .value = 0x100 },
        .{ .offset = 0x0c9, .value = 0xabcd_ef00 },
    };
    var specials = [_]ShaderRegister{
        .{ .offset = 0x100, .value = 1 },
        .{ .offset = 0x101, .value = 2 },
        .{ .offset = 0x102, .value = 3 },
        .{ .offset = 0x103, .value = 4 },
        .{ .offset = 0x104, .value = 5 },
        .{ .offset = 0x105, .value = 6 },
    };
    var code: [16]u8 align(256) = @splat(0);

    std.mem.writeInt(u32, header[0..4], shader_file_header, .little);
    std.mem.writeInt(u32, header[4..8], shader_version, .little);
    header[shader_type_offset] = 2;
    header[shader_sh_register_count_offset] = registers.len;

    const header_address = @intFromPtr(&header);
    const register_field = header_address + shader_sh_registers_offset;
    const specials_field = header_address + shader_specials_offset;
    @as(*u64, @ptrFromInt(register_field)).* = @intFromPtr(&registers) -% register_field;
    @as(*u64, @ptrFromInt(specials_field)).* = @intFromPtr(&specials) -% specials_field;

    var shader: ?*anyopaque = null;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreateShader(&shader, &header, @ptrCast(&code)),
    );
    try std.testing.expectEqual(@intFromPtr(&header), @intFromPtr(shader.?));
    try std.testing.expectEqual(@intFromPtr(&registers), @as(*const u64, @ptrFromInt(register_field)).*);
    try std.testing.expectEqual(@intFromPtr(&specials), @as(*const u64, @ptrFromInt(specials_field)).*);
    try std.testing.expectEqual(@intFromPtr(&code), @as(*const u64, @ptrFromInt(header_address + shader_code_offset)).*);
    const expected_program_address = @intFromPtr(&code) + 0x1_0000;
    try std.testing.expectEqual(@as(u32, @truncate(expected_program_address >> 8)), registers[0].value);
    try std.testing.expectEqual(
        @as(u32, 0xabcd_ef00) | @as(u32, @truncate(expected_program_address >> 40)),
        registers[1].value,
    );
    try std.testing.expectEqual(@as(?u64, header_address), agc_shader_registry.find(@intFromPtr(&code)));
    try std.testing.expectEqual(@as(?u64, header_address), agc_shader_registry.find(expected_program_address));

    var cx: [2]ShaderRegister = undefined;
    var uc: [3]ShaderRegister = undefined;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreatePrimState(&cx, &uc, null, @ptrCast(&header), 4, 0),
    );
    try std.testing.expectEqual(specials[1], cx[0]);
    try std.testing.expectEqual(specials[4], cx[1]);
    try std.testing.expectEqual(specials[0], uc[0]);
    try std.testing.expectEqual(specials[5], uc[1]);
    try std.testing.expectEqual(@as(u32, 0x242), uc[2].offset);
    try std.testing.expectEqual(@as(u32, 4), uc[2].value);
}

test "shader creation accepts a fused front half without program registers" {
    var header: [shader_structure_size]u8 align(8) = @splat(0);
    var code: [16]u8 align(256) = @splat(0);
    std.mem.writeInt(u32, header[0..4], shader_file_header, .little);
    std.mem.writeInt(u32, header[4..8], shader_version, .little);
    header[shader_type_offset] = 4;

    var shader: ?*anyopaque = null;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreateShader(&shader, &header, @ptrCast(&code)),
    );
    try std.testing.expectEqual(@intFromPtr(&header), @intFromPtr(shader.?));
    try std.testing.expectEqual(
        @as(?u64, @intFromPtr(&header)),
        agc_shader_registry.find(@intFromPtr(&code)),
    );
}

test "fuse shader halves patches ES program and keeps front header lookup" {
    agc_shader_registry.reset();
    defer agc_shader_registry.reset();

    var front: [shader_structure_size]u8 align(8) = @splat(0);
    var back: [shader_structure_size]u8 align(8) = @splat(0);
    var fused: [shader_structure_size]u8 align(8) = @splat(0);
    var front_registers = [_]ShaderRegister{
        .{ .offset = spi_shader_pgm_chksum_gs, .value = 0x1111_1111 },
        .{ .offset = spi_shader_pgm_chksum_gs, .value = 0x2222_2222 },
    };
    var back_registers = [_]ShaderRegister{
        .{ .offset = 0x088, .value = 0 }, // GS PGM for CreateShader(type=6)
        .{ .offset = 0x089, .value = 0 },
        .{ .offset = spi_shader_pgm_lo_es, .value = 0 },
        .{ .offset = spi_shader_pgm_lo_es + 1, .value = 0 },
        .{ .offset = spi_shader_pgm_chksum_gs, .value = 0 },
        .{ .offset = spi_shader_pgm_chksum_gs, .value = 0 },
    };
    var scratch: [6]ShaderRegister = undefined;
    var front_code: [16]u8 align(256) = @splat(0);
    var back_code: [16]u8 align(256) = @splat(0);

    std.mem.writeInt(u32, front[0..4], shader_file_header, .little);
    std.mem.writeInt(u32, front[4..8], shader_version, .little);
    front[shader_type_offset] = 4;
    front[shader_sh_register_count_offset] = front_registers.len;
    const front_address = @intFromPtr(&front);
    @as(*u64, @ptrFromInt(front_address + shader_sh_registers_offset)).* =
        @intFromPtr(&front_registers) -% (front_address + shader_sh_registers_offset);

    std.mem.writeInt(u32, back[0..4], shader_file_header, .little);
    std.mem.writeInt(u32, back[4..8], shader_version, .little);
    back[shader_type_offset] = 6;
    back[shader_sh_register_count_offset] = back_registers.len;
    const back_address = @intFromPtr(&back);
    @as(*u64, @ptrFromInt(back_address + shader_sh_registers_offset)).* =
        @intFromPtr(&back_registers) -% (back_address + shader_sh_registers_offset);

    var front_shader: ?*anyopaque = null;
    var back_shader: ?*anyopaque = null;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreateShader(&front_shader, &front, @ptrCast(&front_code)),
    );
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreateShader(&back_shader, &back, @ptrCast(&back_code)),
    );

    var size_align: SizeAlign = .{ .size = 0, .align_bytes = 0 };
    try std.testing.expectEqual(
        @as(i32, 0),
        agcGetFusedShaderSize(&size_align, &front, &back),
    );
    try std.testing.expectEqual(@as(u64, back_registers.len * @sizeOf(ShaderRegister)), size_align.size);
    try std.testing.expectEqual(fused_shader_scratch_align, size_align.align_bytes);

    try std.testing.expectEqual(
        @as(i32, 0),
        agcFuseShaderHalves(&fused, &front, &back, &scratch),
    );
    try std.testing.expectEqual(@as(u8, 2), fused[shader_type_offset]);
    try std.testing.expectEqual(@as(u64, 0), @as(*const u64, @ptrFromInt(@intFromPtr(&fused) + shader_user_data_offset)).*);
    try std.testing.expectEqual(@intFromPtr(&scratch), @as(*const u64, @ptrFromInt(@intFromPtr(&fused) + shader_sh_registers_offset)).*);

    const front_code_address = @intFromPtr(&front_code);
    // Scratch is a copy of back_registers; ES PGM pair is at indices 2/3.
    try std.testing.expectEqual(@as(u32, @truncate(front_code_address >> 8)), scratch[2].value);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), scratch[4].value);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), scratch[5].value);
    try std.testing.expectEqual(
        @as(?u64, front_address),
        agc_shader_registry.find(front_code_address),
    );
}

test "bootstrap service libraries register the title link surface" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("Up36PTk687E", .function) != null);
    try std.testing.expect(db.findById("PI7jIZj4pcE", .function) != null);
    try std.testing.expect(db.findById("YUeqkyT7mEQ", .function) != null);
}
