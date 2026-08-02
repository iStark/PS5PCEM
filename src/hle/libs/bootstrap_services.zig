// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Early title-bootstrap services which do not yet have a host presentation or
//! GPU backend. These implementations are intentionally headless, but preserve
//! handles and output structures so a title can pass initialization safely.

const std = @import("std");
const abi = @import("../abi.zig");
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
    .{ .name = "socket", .function = abi.erase(&posixSocket), .expect_id = "TU-d9PfIHPM" },
    .{ .name = "connect", .function = abi.erase(&posixSocketOperation), .expect_id = "XVL8So3QJUk" },
    .{ .name = "shutdown", .function = abi.erase(&posixSocketOperation), .expect_id = "TUuiYS2kE8s" },
    .{ .name = "setsockopt", .function = abi.erase(&posixSocketOperation), .expect_id = "fFxGkxF2bVo" },
    .{ .name = "recv", .function = abi.erase(&posixSocketOperation), .expect_id = "Ez8xjo9UF4E" },
    .{ .name = "select", .function = abi.erase(&posixSelect), .expect_id = "T8fER+tIGgk" },
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
    .{ .name = "sceRandomGetRandomNumber", .function = abi.erase(&randomGetRandomNumber), .expect_id = "PI7jIZj4pcE" },
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

const video_out_exports = [_]symbols.Export{
    .{ .name = "sceVideoOutOpen", .function = abi.erase(&videoOutOpen), .expect_id = "Up36PTk687E" },
    .{ .name = "sceVideoOutSetBufferAttribute2", .function = abi.erase(&videoOutSetBufferAttribute2), .expect_id = "PjS5uASwcV8" },
    .{ .name = "sceVideoOutRegisterBuffers2", .function = abi.erase(&videoOutRegisterBuffers2), .expect_id = "rKBUtgRrtbk" },
    .{ .name = "sceVideoOutUnregisterBuffers", .function = abi.erase(&videoHandleOption), .expect_id = "N5KDtkIjjJ4" },
    .{ .name = "sceVideoOutSubmitChangeBufferAttribute2", .function = abi.erase(&videoHandleOption), .expect_id = "HuViW4HnrOw" },
    .{ .name = "sceVideoOutSubmitFlip", .function = abi.erase(&videoOutSubmitFlip), .expect_id = "U46NwOiJpys" },
    .{ .name = "sceVideoOutGetFlipStatus", .function = abi.erase(&videoOutGetFlipStatus), .expect_id = "SbU3dwp80lQ" },
    .{ .name = "sceVideoOutIsFlipPending", .function = abi.erase(&videoOutIsFlipPending), .expect_id = "zgXifHT9ErY" },
    .{ .name = "sceVideoOutSetFlipRate", .function = abi.erase(&videoHandleOption), .expect_id = "CBiu4mCE1DA" },
    .{ .name = "sceVideoOutAddFlipEvent", .function = abi.erase(&videoHandleOption), .expect_id = "HXzjK9yI30k" },
    .{ .name = "sceVideoOutDeleteFlipEvent", .function = abi.erase(&videoHandleOption), .expect_id = "-Ozn0F1AFRg" },
    .{ .name = "sceVideoOutGetEventId", .function = abi.erase(&videoOutGetEventId), .expect_id = "U2JJtSqNKZI" },
    .{ .name = "sceVideoOutGetOutputStatus", .function = abi.erase(&videoOutGetOutputStatus), .expect_id = "utPrVdxio-8" },
    .{ .name = "sceVideoOutIsOutputSupported", .function = abi.erase(&videoOutIsOutputSupported), .expect_id = "Nv8c-Kb+DUM" },
    .{ .name = "sceVideoOutConfigureOutput", .function = abi.erase(&videoHandleOption), .expect_id = "w0hLuNarQxY" },
    .{ .name = "sceVideoOutSetWindowModeMargins", .function = abi.erase(&videoHandleOption), .expect_id = "MTxxrOCeSig" },
    .{ .name = "sceVideoOutVrrPegToFixedRate", .function = abi.erase(&videoHandleOption), .expect_id = "5tRaBjtdTzY" },
    .{ .name = "sceVideoOutVrrUnpegFromFixedRate", .function = abi.erase(&videoHandleOption), .expect_id = "T4ucGB8CsnM" },
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
    .{ .name = "sceAvPlayerInitEx", .function = abi.erase(&avPlayerInitEx), .expect_id = "o9eWRkSL+M4" },
    .{ .name = "sceAvPlayerPostInit", .function = abi.erase(&avPlayerAction), .expect_id = "HD1YKVU26-M" },
    .{ .name = "sceAvPlayerAddSourceEx", .function = abi.erase(&avPlayerAction), .expect_id = "x8uvuFOPZhU" },
    .{ .name = "sceAvPlayerStart", .function = abi.erase(&avPlayerAction), .expect_id = "ET4Gr-Uu07s" },
    .{ .name = "sceAvPlayerStop", .function = abi.erase(&avPlayerAction), .expect_id = "ZC17w3vB5Lo" },
    .{ .name = "sceAvPlayerPause", .function = abi.erase(&avPlayerAction), .expect_id = "9y5v+fGN4Wk" },
    .{ .name = "sceAvPlayerResume", .function = abi.erase(&avPlayerAction), .expect_id = "w5moABNwnRY" },
    .{ .name = "sceAvPlayerSetLooping", .function = abi.erase(&avPlayerAction), .expect_id = "OVths0xGfho" },
    .{ .name = "sceAvPlayerSetAvSyncMode", .function = abi.erase(&avPlayerAction), .expect_id = "k-q+xOxdc3E" },
    .{ .name = "sceAvPlayerSetAvailableBandwidth", .function = abi.erase(&avPlayerAction), .expect_id = "N6Oy-EjduiY" },
    .{ .name = "sceAvPlayerJumpToTime", .function = abi.erase(&avPlayerAction), .expect_id = "XC9wM+xULz8" },
    .{ .name = "sceAvPlayerChangeStream", .function = abi.erase(&avPlayerAction), .expect_id = "buMCiJftcfw" },
    .{ .name = "sceAvPlayerEnableStream", .function = abi.erase(&avPlayerAction), .expect_id = "ODJK2sn9w4A" },
    .{ .name = "sceAvPlayerGetVideoDataEx", .function = abi.erase(&avPlayerNoFrame), .expect_id = "JdksQu8pNdQ" },
    .{ .name = "sceAvPlayerGetAudioData", .function = abi.erase(&avPlayerNoFrame), .expect_id = "Wnp1OVcrZgk" },
    .{ .name = "sceAvPlayerGetStreamInfoEx", .function = abi.erase(&avPlayerAction), .expect_id = "ctTAcF5DiKQ" },
    .{ .name = "sceAvPlayerStreamCount", .function = abi.erase(&avPlayerStreamCount), .expect_id = "hdTyRzCXQeQ" },
    .{ .name = "sceAvPlayerIsActive", .function = abi.erase(&avPlayerNoFrame), .expect_id = "UbQoYawOsfY" },
    .{ .name = "sceAvPlayerClose", .function = abi.erase(&avPlayerClose), .expect_id = "NkJwDzKmIlw" },
    .{ .name = "sceAvPlayerSetLogCallback", .function = abi.erase(&success), .expect_id = "eBTreZ84JFY" },
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
    .{ .name = "sceAppContentAddcontMount", .function = abi.erase(&success), .expect_id = "VANhIWcqYak" },
    .{ .name = "sceAppContentAddcontUnmount", .function = abi.erase(&success), .expect_id = "3rHWaV-1KC4" },
    .{ .name = "sceAppContentTemporaryDataFormat", .function = abi.erase(&success), .expect_id = "a5N7lAG0y2Q" },
    .{ .name = "sceAppContentTemporaryDataGetAvailableSpaceKb", .function = abi.erase(&availableSpace), .expect_id = "SaKib2Ug0yI" },
    .{ .name = "sceAppContentDownloadDataGetAvailableSpaceKb", .function = abi.erase(&availableSpace), .expect_id = "Gl6w5i0JokY" },
    .{ .name = "sceAppContentAppParamGetInt", .function = abi.erase(&outputZero32), .expect_id = "99b82IKXpH4" },
};

const np_manager_exports = [_]symbols.Export{
    .{ .name = "sceNpGetAccountIdA", .function = abi.erase(&outputZero64), .expect_id = "rbknaUjpqWo" },
    .{ .name = "sceNpGetAccountCountryA", .function = abi.erase(&outputZero32), .expect_id = "JT+t00a3TxA" },
    .{ .name = "sceNpGetState", .function = abi.erase(&outputZero32), .expect_id = "eQH7nWPcAgc" },
    .{ .name = "sceNpGetNpReachabilityState", .function = abi.erase(&outputZero32), .expect_id = "e-ZuhGEoeC4" },
};

const remoteplay_exports = [_]symbols.Export{
    .{ .name = "sceRemoteplayInitialize", .function = abi.erase(&success), .expect_id = "k1SwgkMSOM8" },
    .{ .name = "sceRemoteplayGetConnectionStatus", .function = abi.erase(&outputZero32), .expect_id = "g3PNjYKWqnQ" },
};

const mouse_exports = [_]symbols.Export{
    .{ .name = "sceMouseInit", .function = abi.erase(&success), .expect_id = "Qs0wWulgl7U" },
    .{ .name = "sceMouseOpen", .function = abi.erase(&mouseOpen), .expect_id = "RaqxZIf6DvE" },
    .{ .name = "sceMouseRead", .function = abi.erase(&mouseRead), .expect_id = "x8qnXqh-tiM" },
    .{ .name = "sceMouseClose", .function = abi.erase(&success), .expect_id = "cAnT0Rw-IwU" },
};

// Save-data memory is accepted as an in-process compatibility surface. The
// title still sees no persistent storage until a VFS-backed implementation is
// attached.
const save_data_exports = [_]symbols.Export{
    .{ .name = "sceSaveDataInitialize3", .function = abi.erase(&success), .expect_id = "TywrFKCoLGY" },
    .{ .name = "sceSaveDataSetupSaveDataMemory2", .function = abi.erase(&success), .expect_id = "oQySEUfgXRA" },
    .{ .name = "sceSaveDataGetSaveDataMemory2", .function = abi.erase(&success), .expect_id = "QwOO7vegnV8" },
    .{ .name = "sceSaveDataSetSaveDataMemory2", .function = abi.erase(&success), .expect_id = "cduy9v4YmT4" },
    .{ .name = "sceSaveDataSyncSaveDataMemory", .function = abi.erase(&success), .expect_id = "wiT9jeC7xPw" },
};

const sysmodule_bootstrap_exports = [_]symbols.Export{
    .{ .name = "sceSysmoduleUnloadModule", .function = abi.erase(&success), .expect_id = "eR2bZFAAU0Q" },
    .{ .name = "sceSysmoduleIsLoaded", .function = abi.erase(&success), .expect_id = "fMP5NHUOaMk" },
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
    .{ .name = "sceAgcInitialize", .function = abi.erase(&agcPatch), .id_override = "23LRUSvYu1M" },
    .{ .name = "sceAgcGetRegisterDefaults2", .function = abi.erase(&agcGetRegisterDefaults), .expect_id = "2JtWUUiYBXs" },
    .{ .name = "sceAgcGetRegisterDefaults2Internal", .function = abi.erase(&agcGetRegisterDefaults), .expect_id = "wRbq6ZjNop4" },
    .{ .name = "sceAgcCreateShader", .function = abi.erase(&agcCreateShader), .expect_id = "f3dg2CSgRKY" },
    .{ .name = "sceAgcUnknownGetFusedShaderSize", .function = abi.erase(&agcPatch), .id_override = "dolOmWH+huQ" },
    .{ .name = "sceAgcUnknownFuseShaderHalves", .function = abi.erase(&agcPatch), .id_override = "fd5Bp5tGTgo" },
    .{ .name = "sceAgcSetCxRegIndirectPatchSetAddress", .function = abi.erase(&agcPatch), .expect_id = "vcmNN+AAXnY" },
    .{ .name = "sceAgcSetShRegIndirectPatchSetAddress", .function = abi.erase(&agcPatch), .expect_id = "Qrj4c+61z4A" },
    .{ .name = "sceAgcSetUcRegIndirectPatchSetAddress", .function = abi.erase(&agcPatch), .expect_id = "6lNcCp+fxi4" },
    .{ .name = "sceAgcSetCxRegIndirectPatchAddRegisters", .function = abi.erase(&agcPatch), .expect_id = "d-6uF9sZDIU" },
    .{ .name = "sceAgcSetShRegIndirectPatchAddRegisters", .function = abi.erase(&agcPatch), .expect_id = "z2duB-hHQSM" },
    .{ .name = "sceAgcSetUcRegIndirectPatchAddRegisters", .function = abi.erase(&agcPatch), .expect_id = "vRoArM9zaIk" },
    .{ .name = "sceAgcCreatePrimState", .function = abi.erase(&agcPatch), .expect_id = "D9sr1xGUriE" },
    .{ .name = "sceAgcWriteDataPatchSetAddressOrOffset", .function = abi.erase(&agcPatch), .expect_id = "fPSCdQxgpSw" },
    .{ .name = "sceAgcQueueEndOfPipeActionPatchAddress", .function = abi.erase(&agcPatch), .expect_id = "0fWWK5uG9rQ" },
    .{ .name = "sceAgcWaitRegMemPatchAddress", .function = abi.erase(&agcPatch), .expect_id = "3KDcnM3lrcU" },
    .{ .name = "sceAgcSetNop", .function = abi.erase(&agcPatch), .expect_id = "K2mciNVxUCE" },
    .{ .name = "sceAgcSuspendPoint", .function = abi.erase(&agcPatch), .expect_id = "h9z6+0hEydk" },
    .{ .name = "sceAgcGetIsTrinityMode", .function = abi.erase(&agcPatch), .expect_id = "BfBDZGbti7A" },
    .{ .name = "sceAgcDebugRaiseException", .function = abi.erase(&agcPatch), .expect_id = "T6xuVw0KUJo" },
    .{ .name = "sceAgcCbSetShRegisterRangeDirectGetSize", .function = abi.erase(&agcGetSize), .expect_id = "bxGoVxpdSPQ" },
    .{ .name = "sceAgcUnknownDb", .function = abi.erase(&agcPatch), .id_override = "dbOlWdppb4o" },
    .{ .name = "sceAgcUnknownKRzWekV120", .function = abi.erase(&agcPatch), .id_override = "-KRzWekV120" },
    .{ .name = "sceAgcUnknownIkfdtRIqCE", .function = abi.erase(&agcPatch), .id_override = "Ikfdt-rIqCE" },
    .{ .name = "sceAgcGetDataPacketPayloadAddress", .function = abi.erase(&agcPatch), .id_override = "V++UgBtQhn0" },

    .{ .name = "sceAgcCbNop", .function = abi.erase(&agcCommand), .expect_id = "LtTouSCZjHM" },
    .{ .name = "sceAgcCbDispatch", .function = abi.erase(&agcCommand), .expect_id = "k3GhuSNmBLU" },
    .{ .name = "sceAgcCbSetShRegisterRangeDirect", .function = abi.erase(&agcCommand), .expect_id = "n2fD4A+pb+g" },
    .{ .name = "sceAgcCbSetShRegistersDirect", .function = abi.erase(&agcCommand), .expect_id = "UZbQjYAwwXM" },
    .{ .name = "sceAgcCbSetUcRegistersDirect", .function = abi.erase(&agcCommand), .expect_id = "03RZmELWWzw" },
    .{ .name = "sceAgcCbReleaseMem", .function = abi.erase(&agcCommand), .expect_id = "wr23dPKyWc0" },

    .{ .name = "sceAgcAcbResetQueue", .function = abi.erase(&agcCommand), .expect_id = "JrtiDtKeS38" },
    .{ .name = "sceAgcAcbDispatchIndirect", .function = abi.erase(&agcCommand), .expect_id = "j3EtxFkSIhQ" },
    .{ .name = "sceAgcAcbWaitUntilSafeForRendering", .function = abi.erase(&agcCommand), .expect_id = "GPbUp9jXQa8" },
    .{ .name = "sceAgcAcbWaitRegMem", .function = abi.erase(&agcCommand), .expect_id = "htn36gPnBk4" },
    .{ .name = "sceAgcAcbAcquireMem", .function = abi.erase(&agcCommand), .expect_id = "KT-hTp-Ch14" },
    .{ .name = "sceAgcAcbDmaData", .function = abi.erase(&agcCommand), .expect_id = "-RnpfpxIhec" },
    .{ .name = "sceAgcAcbCopyData", .function = abi.erase(&agcCommand), .expect_id = "qzMN2XKGA4k" },
    .{ .name = "sceAgcAcbWriteData", .function = abi.erase(&agcCommand), .expect_id = "eZ4+17OQz4Q" },
    .{ .name = "sceAgcAcbEventWrite", .function = abi.erase(&agcCommand), .expect_id = "cFazmnXpJOE" },
    .{ .name = "sceAgcAcbJump", .function = abi.erase(&agcCommand), .expect_id = "e1DFTg+Sd8U" },
    .{ .name = "sceAgcAcbPushMarker", .function = abi.erase(&agcCommand), .expect_id = "cpCILPya5Zk" },
    .{ .name = "sceAgcAcbPopMarker", .function = abi.erase(&agcCommand), .expect_id = "6mFxkVqdmbQ" },

    .{ .name = "sceAgcDcbResetQueue", .function = abi.erase(&agcCommand), .expect_id = "TRO721eVt4g" },
    .{ .name = "sceAgcDcbWaitUntilSafeForRendering", .function = abi.erase(&agcCommand), .expect_id = "MWiElSNE8j8" },
    .{ .name = "sceAgcDcbSetIndexBuffer", .function = abi.erase(&agcCommand), .expect_id = "l4fM9K-Lyks" },
    .{ .name = "sceAgcDcbSetIndexCount", .function = abi.erase(&agcCommand), .expect_id = "8N2tmT3jmC8" },
    .{ .name = "sceAgcDcbDrawIndex", .function = abi.erase(&agcCommand), .expect_id = "q88lQ+GP5Yk" },
    .{ .name = "sceAgcDcbDrawIndexAuto", .function = abi.erase(&agcCommand), .expect_id = "Yw0jKSqop+E" },
    .{ .name = "sceAgcDcbDrawIndexIndirect", .function = abi.erase(&agcCommand), .expect_id = "t1vNu082-jM" },
    .{ .name = "sceAgcDcbDrawIndirect", .function = abi.erase(&agcCommand), .expect_id = "1q1titRBL6o" },
    .{ .name = "sceAgcDcbDispatchIndirect", .function = abi.erase(&agcCommand), .expect_id = "CtB+A9-VxO0" },
    .{ .name = "sceAgcDcbSetNumInstances", .function = abi.erase(&agcCommand), .expect_id = "tSBxhAPyytQ" },
    .{ .name = "sceAgcDcbStallCommandBufferParser", .function = abi.erase(&agcCommand), .expect_id = "u2T2DiA5hRI" },
    .{ .name = "sceAgcDcbSetBaseIndirectArgs", .function = abi.erase(&agcCommand), .expect_id = "RmaJwLtc8rY" },
    .{ .name = "sceAgcDcbSetShRegistersIndirect", .function = abi.erase(&agcCommand), .expect_id = "-HOOCn0JY48" },
    .{ .name = "sceAgcDcbSetUcRegistersIndirect", .function = abi.erase(&agcCommand), .expect_id = "hvUfkUIQcOE" },
    .{ .name = "sceAgcDcbSetCxRegistersIndirect", .function = abi.erase(&agcCommand), .expect_id = "ZvwO9euwYzc" },
    .{ .name = "sceAgcDcbWaitRegMem", .function = abi.erase(&agcCommand), .expect_id = "VmW0Tdpy420" },
    .{ .name = "sceAgcDcbAcquireMem", .function = abi.erase(&agcCommand), .expect_id = "57labkp+rSQ" },
    .{ .name = "sceAgcDcbDmaData", .function = abi.erase(&agcCommand), .expect_id = "WmAc2MEj6Io" },
    .{ .name = "sceAgcDcbCopyData", .function = abi.erase(&agcCommand), .expect_id = "1rZSWUv1IRc" },
    .{ .name = "sceAgcDcbWriteData", .function = abi.erase(&agcCommand), .expect_id = "i1jyy49AjXU" },
    .{ .name = "sceAgcDcbEventWrite", .function = abi.erase(&agcCommand), .expect_id = "aJf+j5yntiU" },
    .{ .name = "sceAgcDcbJump", .function = abi.erase(&agcCommand), .expect_id = "xSAR0LTcRKM" },
    .{ .name = "sceAgcDcbPushMarker", .function = abi.erase(&agcCommand), .expect_id = "+kSrjIVxKFE" },
    .{ .name = "sceAgcDcbPopMarker", .function = abi.erase(&agcCommand), .expect_id = "H7uZqCoNuWk" },
    .{ .name = "sceAgcDcbSetFlip", .function = abi.erase(&agcCommand), .expect_id = "YUeqkyT7mEQ" },
};

const agc_driver_exports = [_]symbols.Export{
    .{ .name = "sceAgcDriverRegisterOwner", .function = abi.erase(&success), .expect_id = "X-Nm5KLREeg" },
    .{ .name = "sceAgcDriverSetHsOffchipParam", .function = abi.erase(&success), .expect_id = "MM4IZSEYytQ" },
    .{ .name = "sceAgcDriverSubmitDcb", .function = abi.erase(&success), .expect_id = "UglJIZjGssM" },
    .{ .name = "sceAgcDriverAgrSubmitDcb", .function = abi.erase(&success), .expect_id = "AhGvpITrf4M" },
    .{ .name = "sceAgcDriverSubmitAcb", .function = abi.erase(&success), .expect_id = "gSRnr79F8tQ" },
    .{ .name = "sceAgcDriverRegisterResource", .function = abi.erase(&success), .expect_id = "W5z4eZrjEas" },
    .{ .name = "sceAgcDriverAddEqEvent", .function = abi.erase(&success), .expect_id = "w2rJhmD+dsE" },
    .{ .name = "sceAgcDriverGetEqContextId", .function = abi.erase(&success), .expect_id = "Zw7uUVPulbw" },
    .{ .name = "sceAgcDriverSetTFRing", .function = abi.erase(&success), .expect_id = "XlNp7jzGiPo" },
};

const ampr_exports = [_]symbols.Export{
    .{ .name = "sceAmprCommandBufferConstructor", .function = abi.erase(&success), .expect_id = "8aI7R7WaOlc" },
    .{ .name = "sceAmprAprCommandBufferConstructor", .function = abi.erase(&success), .expect_id = "a8uLzYY--tM" },
    .{ .name = "sceAmprCommandBufferReset", .function = abi.erase(&success), .expect_id = "baQO9ez2gL4" },
    .{ .name = "sceAmprCommandBufferSetBuffer", .function = abi.erase(&success), .expect_id = "N-FSPA4S3nI" },
    .{ .name = "sceAmprAprCommandBufferReadFile", .function = abi.erase(&success), .expect_id = "mQ16-QdKv7k" },
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
