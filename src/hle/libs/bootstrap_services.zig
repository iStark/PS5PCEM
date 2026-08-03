// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Early title-bootstrap services which do not yet have a host presentation or
//! GPU backend. These implementations are intentionally headless, but preserve
//! handles and output structures so a title can pass initialization safely.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_runtime = @import("kernel_runtime.zig");
const kernel_threading = @import("kernel_threading.zig");

const invalid_argument = errno.KernelError.einval.raw();

fn success() callconv(abi.guest) i32 {
    return errno.ok;
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

// Headless VideoOut -------------------------------------------------------

const video_out_error_invalid_handle: i32 = @bitCast(@as(u32, 0x8029_0001));
const video_out_error_invalid_address: i32 = @bitCast(@as(u32, 0x8029_0002));

const VideoOutBufferAttribute2 = extern struct {
    reserved0: u32 = 0,
    tiling_mode: u32 = 0,
    aspect_ratio: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch_in_pixels: u32 = 0,
    option: u64 = 0,
    pixel_format: u64 = 0,
    dcc_clear_color: u64 = 0,
    dcc_control: u32 = 0,
    padding: u32 = 0,
    reserved1: [3]u64 = .{ 0, 0, 0 },
};

const VideoOutFlipStatus = extern struct {
    count: u64 = 0,
    process_time: u64 = 0,
    reserved0: u64 = 0,
    flip_argument: i64 = 0,
    reserved1: u64 = 0,
    process_time_counter: u64 = 0,
    gc_queue_count: i32 = 0,
    flip_pending_count: i32 = 0,
    current_buffer: i32 = 0,
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

var video_open = std.atomic.Value(bool).init(false);
var video_flip_count = std.atomic.Value(u64).init(0);
var video_current_buffer = std.atomic.Value(i32).init(0);

fn validVideoHandle(handle: i32) bool {
    return handle == 1 and video_open.load(.acquire);
}

fn videoOutOpen(_: i32, _: i32, index: i32, _: ?*const anyopaque) callconv(abi.guest) i32 {
    if (index != 0) return video_out_error_invalid_handle;
    if (video_open.swap(true, .acq_rel)) return video_out_error_invalid_handle;
    return 1;
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

fn videoOutRegisterBuffers2(
    handle: i32,
    _: i32,
    _: i32,
    buffers: ?*const anyopaque,
    count: i32,
    attribute: ?*const VideoOutBufferAttribute2,
    _: i32,
    _: ?*anyopaque,
) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    if (buffers == null or attribute == null or count <= 0) return video_out_error_invalid_address;
    return errno.ok;
}

fn videoOutSubmitFlip(handle: i32, index: i32, _: i32, _: i64) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    video_current_buffer.store(index, .release);
    _ = video_flip_count.fetchAdd(1, .monotonic);
    _ = kernel_threading.sceKernelUsleep(16_667);
    return errno.ok;
}

fn videoOutGetFlipStatus(handle: i32, status: ?*VideoOutFlipStatus) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const output = status orelse return video_out_error_invalid_address;
    output.* = .{
        .count = video_flip_count.load(.acquire),
        .current_buffer = video_current_buffer.load(.acquire),
    };
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
    return @bitCast(@as(u32, @truncate(value.ident)));
}

fn videoOutIsFlipPending(handle: i32) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) 0 else video_out_error_invalid_handle;
}

/// A flip submitted to complete when the GPU finishes the frame.
///
/// The difference from an ordinary flip is only *when* it takes effect: the
/// caller does not wait, because the pipeline signals it. Nothing here runs a
/// pipeline, so it takes effect at once — and unlike the ordinary flip it does
/// not pace itself, since a caller that expected to be paced would have used
/// the other call.
fn videoOutSubmitEopFlip(
    handle: i32,
    index: i32,
    _: u32,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    video_current_buffer.store(index, .release);
    _ = video_flip_count.fetchAdd(1, .monotonic);
    return errno.ok;
}

/// Which display bus the output is attached to. There is only one.
fn videoOutSysGetBus(handle: i32) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) 0 else video_out_error_invalid_handle;
}

/// Where the hardware writes the labels that say a buffer is free again.
///
/// Refused. A driver reads these to know when it may reuse a buffer, so
/// handing back an address whose contents nothing ever updates would leave it
/// waiting on a value that never changes — a stall with nothing to point at,
/// rather than an error naming the facility that is missing.
fn videoOutGetBufferLabelAddress(_: i32, _: u64) callconv(abi.guest) i32 {
    return video_out_error_invalid_address;
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
    .{ .name = "sceVideoOutSetBufferAttribute2", .function = trace.wrap("sceVideoOutSetBufferAttribute2", &videoOutSetBufferAttribute2), .expect_id = "PjS5uASwcV8" },
    .{ .name = "sceVideoOutRegisterBuffers2", .function = trace.wrap("sceVideoOutRegisterBuffers2", &videoOutRegisterBuffers2), .expect_id = "rKBUtgRrtbk" },
    .{ .name = "sceVideoOutUnregisterBuffers", .function = trace.wrap("sceVideoOutUnregisterBuffers", &videoHandleOption), .expect_id = "N5KDtkIjjJ4" },
    .{ .name = "sceVideoOutSubmitChangeBufferAttribute2", .function = trace.wrap("sceVideoOutSubmitChangeBufferAttribute2", &videoHandleOption), .expect_id = "HuViW4HnrOw" },
    .{ .name = "sceVideoOutSubmitFlip", .function = trace.wrap("sceVideoOutSubmitFlip", &videoOutSubmitFlip), .expect_id = "U46NwOiJpys" },
    .{ .name = "sceVideoOutGetFlipStatus", .function = trace.wrap("sceVideoOutGetFlipStatus", &videoOutGetFlipStatus), .expect_id = "SbU3dwp80lQ" },
    .{ .name = "sceVideoOutIsFlipPending", .function = trace.wrap("sceVideoOutIsFlipPending", &videoOutIsFlipPending), .expect_id = "zgXifHT9ErY" },
    .{ .name = "sceVideoOutSetFlipRate", .function = trace.wrap("sceVideoOutSetFlipRate", &videoHandleOption), .expect_id = "CBiu4mCE1DA" },
    .{ .name = "sceVideoOutAddFlipEvent", .function = trace.wrap("sceVideoOutAddFlipEvent", &videoHandleOption), .expect_id = "HXzjK9yI30k" },
    .{ .name = "sceVideoOutDeleteFlipEvent", .function = trace.wrap("sceVideoOutDeleteFlipEvent", &videoHandleOption), .expect_id = "-Ozn0F1AFRg" },
    .{ .name = "sceVideoOutGetEventId", .function = trace.wrap("sceVideoOutGetEventId", &videoOutGetEventId), .expect_id = "U2JJtSqNKZI" },
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

fn agcCommand(buffer: ?*AgcCommandBuffer, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) ?[*]u32 {
    const state = buffer orelse return null;
    const cursor = state.cursor_up orelse state.bottom orelse return null;
    const top = state.top orelse return null;
    const cursor_address = @intFromPtr(cursor);
    const top_address = @intFromPtr(top);
    const byte_count = 16 * @sizeOf(u32);
    if (cursor_address > top_address or top_address - cursor_address < byte_count) return null;
    @memset(cursor[0..16], 0);
    state.cursor_up = cursor + 16;
    return cursor;
}

fn agcPatch(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

fn agcGetSize(_: u64) callconv(abi.guest) u32 {
    return 64;
}

var register_defaults: [256]u32 align(16) = [_]u32{0} ** 256;

fn agcGetRegisterDefaults(_: u32) callconv(abi.guest) *anyopaque {
    return &register_defaults;
}

fn agcCreateShader(output: ?*?*anyopaque, header: ?*anyopaque, _: ?*const volatile anyopaque) callconv(abi.guest) i32 {
    if (output) |value| value.* = header;
    return errno.ok;
}

const agc_exports = [_]symbols.Export{
    .{ .name = "sceAgcInitialize", .function = trace.wrap("sceAgcInitialize", &agcPatch), .id_override = "23LRUSvYu1M" },
    .{ .name = "sceAgcGetRegisterDefaults2", .function = trace.wrap("sceAgcGetRegisterDefaults2", &agcGetRegisterDefaults), .expect_id = "2JtWUUiYBXs" },
    .{ .name = "sceAgcGetRegisterDefaults2Internal", .function = trace.wrap("sceAgcGetRegisterDefaults2Internal", &agcGetRegisterDefaults), .expect_id = "wRbq6ZjNop4" },
    .{ .name = "sceAgcCreateShader", .function = trace.wrap("sceAgcCreateShader", &agcCreateShader), .expect_id = "f3dg2CSgRKY" },
    .{ .name = "sceAgcUnknownGetFusedShaderSize", .function = trace.wrap("sceAgcUnknownGetFusedShaderSize", &agcPatch), .id_override = "dolOmWH+huQ" },
    .{ .name = "sceAgcUnknownFuseShaderHalves", .function = trace.wrap("sceAgcUnknownFuseShaderHalves", &agcPatch), .id_override = "fd5Bp5tGTgo" },
    .{ .name = "sceAgcSetCxRegIndirectPatchSetAddress", .function = trace.wrap("sceAgcSetCxRegIndirectPatchSetAddress", &agcPatch), .expect_id = "vcmNN+AAXnY" },
    .{ .name = "sceAgcSetShRegIndirectPatchSetAddress", .function = trace.wrap("sceAgcSetShRegIndirectPatchSetAddress", &agcPatch), .expect_id = "Qrj4c+61z4A" },
    .{ .name = "sceAgcSetUcRegIndirectPatchSetAddress", .function = trace.wrap("sceAgcSetUcRegIndirectPatchSetAddress", &agcPatch), .expect_id = "6lNcCp+fxi4" },
    .{ .name = "sceAgcSetCxRegIndirectPatchAddRegisters", .function = trace.wrap("sceAgcSetCxRegIndirectPatchAddRegisters", &agcPatch), .expect_id = "d-6uF9sZDIU" },
    .{ .name = "sceAgcSetShRegIndirectPatchAddRegisters", .function = trace.wrap("sceAgcSetShRegIndirectPatchAddRegisters", &agcPatch), .expect_id = "z2duB-hHQSM" },
    .{ .name = "sceAgcSetUcRegIndirectPatchAddRegisters", .function = trace.wrap("sceAgcSetUcRegIndirectPatchAddRegisters", &agcPatch), .expect_id = "vRoArM9zaIk" },
    .{ .name = "sceAgcCreatePrimState", .function = trace.wrap("sceAgcCreatePrimState", &agcPatch), .expect_id = "D9sr1xGUriE" },
    .{ .name = "sceAgcWriteDataPatchSetAddressOrOffset", .function = trace.wrap("sceAgcWriteDataPatchSetAddressOrOffset", &agcPatch), .expect_id = "fPSCdQxgpSw" },
    .{ .name = "sceAgcQueueEndOfPipeActionPatchAddress", .function = trace.wrap("sceAgcQueueEndOfPipeActionPatchAddress", &agcPatch), .expect_id = "0fWWK5uG9rQ" },
    .{ .name = "sceAgcWaitRegMemPatchAddress", .function = trace.wrap("sceAgcWaitRegMemPatchAddress", &agcPatch), .expect_id = "3KDcnM3lrcU" },
    .{ .name = "sceAgcSetNop", .function = trace.wrap("sceAgcSetNop", &agcPatch), .expect_id = "K2mciNVxUCE" },
    .{ .name = "sceAgcSuspendPoint", .function = trace.wrap("sceAgcSuspendPoint", &agcPatch), .expect_id = "h9z6+0hEydk" },
    .{ .name = "sceAgcGetIsTrinityMode", .function = trace.wrap("sceAgcGetIsTrinityMode", &agcPatch), .expect_id = "BfBDZGbti7A" },
    .{ .name = "sceAgcDebugRaiseException", .function = trace.wrap("sceAgcDebugRaiseException", &agcPatch), .expect_id = "T6xuVw0KUJo" },
    .{ .name = "sceAgcCbSetShRegisterRangeDirectGetSize", .function = trace.wrap("sceAgcCbSetShRegisterRangeDirectGetSize", &agcGetSize), .expect_id = "bxGoVxpdSPQ" },
    .{ .name = "sceAgcUnknownDb", .function = trace.wrap("sceAgcUnknownDb", &agcPatch), .id_override = "dbOlWdppb4o" },
    .{ .name = "sceAgcUnknownKRzWekV120", .function = trace.wrap("sceAgcUnknownKRzWekV120", &agcPatch), .id_override = "-KRzWekV120" },
    .{ .name = "sceAgcUnknownIkfdtRIqCE", .function = trace.wrap("sceAgcUnknownIkfdtRIqCE", &agcPatch), .id_override = "Ikfdt-rIqCE" },
    .{ .name = "sceAgcGetDataPacketPayloadAddress", .function = trace.wrap("sceAgcGetDataPacketPayloadAddress", &agcPatch), .id_override = "V++UgBtQhn0" },

    .{ .name = "sceAgcCbNop", .function = trace.wrap("sceAgcCbNop", &agcCommand), .expect_id = "LtTouSCZjHM" },
    .{ .name = "sceAgcCbDispatch", .function = trace.wrap("sceAgcCbDispatch", &agcCommand), .expect_id = "k3GhuSNmBLU" },
    .{ .name = "sceAgcCbSetShRegisterRangeDirect", .function = trace.wrap("sceAgcCbSetShRegisterRangeDirect", &agcCommand), .expect_id = "n2fD4A+pb+g" },
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
    .{ .name = "sceAgcDcbDrawIndex", .function = trace.wrap("sceAgcDcbDrawIndex", &agcCommand), .expect_id = "q88lQ+GP5Yk" },
    .{ .name = "sceAgcDcbDrawIndexAuto", .function = trace.wrap("sceAgcDcbDrawIndexAuto", &agcCommand), .expect_id = "Yw0jKSqop+E" },
    .{ .name = "sceAgcDcbDrawIndexIndirect", .function = trace.wrap("sceAgcDcbDrawIndexIndirect", &agcCommand), .expect_id = "t1vNu082-jM" },
    .{ .name = "sceAgcDcbDrawIndirect", .function = trace.wrap("sceAgcDcbDrawIndirect", &agcCommand), .expect_id = "1q1titRBL6o" },
    .{ .name = "sceAgcDcbDispatchIndirect", .function = trace.wrap("sceAgcDcbDispatchIndirect", &agcCommand), .expect_id = "CtB+A9-VxO0" },
    .{ .name = "sceAgcDcbSetNumInstances", .function = trace.wrap("sceAgcDcbSetNumInstances", &agcCommand), .expect_id = "tSBxhAPyytQ" },
    .{ .name = "sceAgcDcbStallCommandBufferParser", .function = trace.wrap("sceAgcDcbStallCommandBufferParser", &agcCommand), .expect_id = "u2T2DiA5hRI" },
    .{ .name = "sceAgcDcbSetBaseIndirectArgs", .function = trace.wrap("sceAgcDcbSetBaseIndirectArgs", &agcCommand), .expect_id = "RmaJwLtc8rY" },
    .{ .name = "sceAgcDcbSetShRegistersIndirect", .function = trace.wrap("sceAgcDcbSetShRegistersIndirect", &agcCommand), .expect_id = "-HOOCn0JY48" },
    .{ .name = "sceAgcDcbSetUcRegistersIndirect", .function = trace.wrap("sceAgcDcbSetUcRegistersIndirect", &agcCommand), .expect_id = "hvUfkUIQcOE" },
    .{ .name = "sceAgcDcbSetCxRegistersIndirect", .function = trace.wrap("sceAgcDcbSetCxRegistersIndirect", &agcCommand), .expect_id = "ZvwO9euwYzc" },
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
    .{ .name = "sceAgcDriverSubmitDcb", .function = trace.wrap("sceAgcDriverSubmitDcb", &success), .expect_id = "UglJIZjGssM" },
    .{ .name = "sceAgcDriverAgrSubmitDcb", .function = trace.wrap("sceAgcDriverAgrSubmitDcb", &success), .expect_id = "AhGvpITrf4M" },
    .{ .name = "sceAgcDriverSubmitAcb", .function = trace.wrap("sceAgcDriverSubmitAcb", &success), .expect_id = "gSRnr79F8tQ" },
    .{ .name = "sceAgcDriverRegisterResource", .function = trace.wrap("sceAgcDriverRegisterResource", &success), .expect_id = "W5z4eZrjEas" },
    .{ .name = "sceAgcDriverAddEqEvent", .function = trace.wrap("sceAgcDriverAddEqEvent", &success), .expect_id = "w2rJhmD+dsE" },
    .{ .name = "sceAgcDriverGetEqContextId", .function = trace.wrap("sceAgcDriverGetEqContextId", &success), .expect_id = "Zw7uUVPulbw" },
    .{ .name = "sceAgcDriverSetTFRing", .function = trace.wrap("sceAgcDriverSetTFRing", &success), .expect_id = "XlNp7jzGiPo" },
};

const ampr_exports = [_]symbols.Export{
    .{ .name = "sceAmprCommandBufferConstructor", .function = trace.wrap("sceAmprCommandBufferConstructor", &success), .expect_id = "8aI7R7WaOlc" },
    .{ .name = "sceAmprAprCommandBufferConstructor", .function = trace.wrap("sceAmprAprCommandBufferConstructor", &success), .expect_id = "a8uLzYY--tM" },
    .{ .name = "sceAmprCommandBufferReset", .function = trace.wrap("sceAmprCommandBufferReset", &success), .expect_id = "baQO9ez2gL4" },
    .{ .name = "sceAmprCommandBufferSetBuffer", .function = trace.wrap("sceAmprCommandBufferSetBuffer", &success), .expect_id = "N-FSPA4S3nI" },
    .{ .name = "sceAmprAprCommandBufferReadFile", .function = trace.wrap("sceAmprAprCommandBufferReadFile", &success), .expect_id = "mQ16-QdKv7k" },
};

pub fn reset() void {
    random_state.store(0x9e37_79b9_7f4a_7c15, .monotonic);
    video_open.store(false, .release);
    video_flip_count.store(0, .monotonic);
    video_current_buffer.store(0, .monotonic);
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
    try db.addLibrary(gpa, .{ .name = "libSceAmpr" }, .{ .name = "libSceAmpr" }, &ampr_exports);
}

test "bootstrap service libraries register the title link surface" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("Up36PTk687E", .function) != null);
    try std.testing.expect(db.findById("PI7jIZj4pcE", .function) != null);
    try std.testing.expect(db.findById("YUeqkyT7mEQ", .function) != null);
}
