// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The services a shipped title asks for that this machine does not have.
//!
//! A large title links against a great deal it will happily run without: an
//! online account system, a headset, a store, a voice channel, an accelerator.
//! None of it exists here. But a missing import stops a module from linking at
//! all, so until each one is answered the title cannot start far enough to reach
//! the parts that do work.
//!
//! What every answer here has in common is that it tells the title the facility
//! is not available, rather than that the operation succeeded. That distinction
//! is the whole point. A title told its request succeeded goes looking for a
//! result nothing produced — a session it can join, a headset pose to read, a
//! file the accelerator was to have fetched — and fails somewhere with nothing
//! pointing back here. A title told the facility is absent takes the path it
//! already has for a console with no network, no peripheral and no entitlement,
//! which is a path its own authors wrote and tested.
//!
//! The differences below are only in what "not here" looks like from the
//! caller's side.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const kernel_memory = @import("kernel_memory.zig");

/// Status a service library returns when it has not been, and cannot be,
/// brought up.
///
/// The platform gives each library its own numbering, and inventing a code
/// inside one of those spaces would be a guess a title might act on. This is
/// the kernel's own "not implemented", which is outside every library's space
/// and therefore cannot be mistaken for one of its documented outcomes: a
/// caller sees a failure it does not recognise, which is exactly what it is.
const unavailable: i32 = @intFromEnum(errno.KernelError.enosys);

/// A service that is not present on this machine.
pub fn absent(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return unavailable;
}

/// Anything that needs a network connection.
///
/// Answered the same way as an absent service rather than as a transient
/// network error, because a transient one invites a title to retry forever.
pub fn offline(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return unavailable;
}

/// Hardware that is not attached — a headset, a tracker, an extra pad.
pub fn noDevice(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return unavailable;
}

/// Boolean device probes return false without manufacturing an error path.
pub fn notAttached(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return 0;
}

/// Bookkeeping that changes nothing observable and has nothing to report back.
///
/// Kept apart from the refusals on purpose: refusing a title's attempt to, say,
/// release something it allocated would leave it believing the thing is still
/// live. Nothing here hands back a value a caller then follows.
pub fn accept(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

const game_update_error_not_initialized: i32 = @bitCast(@as(u32, 0x8041_2801));
const game_update_error_invalid_argument: i32 = @bitCast(@as(u32, 0x8041_2803));
const disc_map_error_invalid_argument: i32 = @bitCast(@as(u32, 0x8093_0002));

/// How a connection status block is reported: the whole documented extent,
/// not just its first word.
const remoteplay_status_bytes: usize = 0x10;

/// Reports whether a streaming session is attached, which it never is.
///
/// The block is cleared in full before the state is written. Filling only the
/// first word left the rest of the title's structure holding whatever the
/// memory held before, and a field it happens to read from there is read as a
/// session detail rather than as the leftover it is.
pub fn remoteplayGetConnectionStatus(_: i32, status: ?*[remoteplay_status_bytes]u8) callconv(abi.guest) i32 {
    const output = status orelse return errno.ok;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), remoteplay_status_bytes)) {
        return errno.ok;
    }
    @memset(output, 0);
    return errno.ok;
}

/// Answers whether a byte range of a title's own file is already on the
/// drive rather than still on a disc.
///
/// Everything here is installed locally, so nothing is ever waiting behind a
/// disc read and the answer is always yes. A title asks this to decide
/// whether to stream a resource now or defer it, so the answer it gets is one
/// it can act on rather than a refusal.
pub fn discMapIsRequestOnHDD(
    path: ?[*:0]const u8,
    _: u64,
    _: u64,
    result: ?*u32,
) callconv(abi.guest) i32 {
    if (path == null) return disc_map_error_invalid_argument;
    const output = result orelse return disc_map_error_invalid_argument;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(u32))) {
        return disc_map_error_invalid_argument;
    }
    output.* = 1;
    return errno.ok;
}

const game_update_error_invalid_size: i32 = @bitCast(@as(u32, 0x8041_2804));
const game_update_error_request_not_found: i32 = @bitCast(@as(u32, 0x8041_2805));

const GameUpdateCheckParam = extern struct {
    size: u64,
    option: u32,
    reserved: [9]u32,
};

const GameUpdateCheckResult = extern struct {
    size: u64,
    found: u8,
    addcont_found: u8,
    padding: [2]u8,
    content_version: [11]u8,
    padding2: u8,
    reserved: [6]u32,
};

const GameUpdateAddcontVersionInfo = extern struct {
    size: u64,
    found: u8,
    content_version: [11]u8,
    reserved: [6]u32,
};

var game_update_initialized = std.atomic.Value(bool).init(false);
var game_update_next_request = std.atomic.Value(u32).init(1);
var game_update_requests = std.atomic.Value(u64).init(0);

fn gameUpdateRequestBit(request_id: i32) ?u64 {
    if (request_id < 1 or request_id >= 64) return null;
    return @as(u64, 1) << @intCast(request_id);
}

/// Offline consoles still expose GameUpdate successfully; a check simply says
/// that no newer content is available. Treating the whole service as ENOSYS
/// aborts Unity's platform bootstrap before it can create the first scene.
pub fn gameUpdateInitialize() callconv(abi.guest) i32 {
    game_update_requests.store(0, .release);
    game_update_next_request.store(1, .release);
    game_update_initialized.store(true, .release);
    return errno.ok;
}

pub fn gameUpdateTerminate() callconv(abi.guest) i32 {
    game_update_initialized.store(false, .release);
    game_update_requests.store(0, .release);
    return errno.ok;
}

pub fn gameUpdateCreateRequest() callconv(abi.guest) i32 {
    if (!game_update_initialized.load(.acquire)) return game_update_error_not_initialized;
    var attempts: usize = 0;
    while (attempts < 63) : (attempts += 1) {
        const raw = game_update_next_request.fetchAdd(1, .acq_rel);
        const request_id: u32 = (raw -% 1) % 63 + 1;
        const bit = @as(u64, 1) << @intCast(request_id);
        const old = game_update_requests.fetchOr(bit, .acq_rel);
        if (old & bit == 0) return @intCast(request_id);
    }
    return errno.KernelError.enospc.raw();
}

fn validGameUpdateRequest(request_id: i32) bool {
    const bit = gameUpdateRequestBit(request_id) orelse return false;
    return game_update_requests.load(.acquire) & bit != 0;
}

pub fn gameUpdateCheck(
    request_id: i32,
    parameters: ?*const GameUpdateCheckParam,
    result: ?*GameUpdateCheckResult,
) callconv(abi.guest) i32 {
    if (!game_update_initialized.load(.acquire)) return game_update_error_not_initialized;
    if (!validGameUpdateRequest(request_id)) return game_update_error_request_not_found;
    const input = parameters orelse return game_update_error_invalid_argument;
    const output = result orelse return game_update_error_invalid_argument;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(input), @sizeOf(GameUpdateCheckParam)) or
        !kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(GameUpdateCheckResult)))
    {
        return game_update_error_invalid_argument;
    }
    if (input.size < @sizeOf(GameUpdateCheckParam) or output.size < @sizeOf(GameUpdateCheckResult)) {
        return game_update_error_invalid_size;
    }
    const size = output.size;
    output.* = std.mem.zeroes(GameUpdateCheckResult);
    output.size = size;
    return errno.ok;
}

pub fn gameUpdateAbortRequest(request_id: i32) callconv(abi.guest) i32 {
    if (!game_update_initialized.load(.acquire)) return game_update_error_not_initialized;
    return if (validGameUpdateRequest(request_id)) errno.ok else game_update_error_request_not_found;
}

pub fn gameUpdateDeleteRequest(request_id: i32) callconv(abi.guest) i32 {
    if (!game_update_initialized.load(.acquire)) return game_update_error_not_initialized;
    const bit = gameUpdateRequestBit(request_id) orelse return game_update_error_request_not_found;
    const old = game_update_requests.fetchAnd(~bit, .acq_rel);
    return if (old & bit != 0) errno.ok else game_update_error_request_not_found;
}

pub fn gameUpdateGetAddcontLatestVersion(
    _: u32,
    _: ?*const anyopaque,
    info: ?*GameUpdateAddcontVersionInfo,
) callconv(abi.guest) i32 {
    if (!game_update_initialized.load(.acquire)) return game_update_error_not_initialized;
    const output = info orelse return game_update_error_invalid_argument;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(GameUpdateAddcontVersionInfo))) {
        return game_update_error_invalid_argument;
    }
    if (output.size < @sizeOf(GameUpdateAddcontVersionInfo)) return game_update_error_invalid_size;
    const size = output.size;
    output.* = std.mem.zeroes(GameUpdateAddcontVersionInfo);
    output.size = size;
    return errno.ok;
}

const np_entitlement_error_parameter: i32 = @bitCast(@as(u32, 0x817d_0002));
var np_trophy_next_context = std.atomic.Value(i32).init(1);
var np_trophy_next_handle = std.atomic.Value(i32).init(1);
var np_webapi_next_push_handle = std.atomic.Value(i32).init(1);

/// Entitlement and signaling libraries have useful offline bootstrap states.
/// Network-backed requests may fail later, but constructing these contexts is
/// local and is required before Unity can finish its platform initialization.
pub fn npEntitlementAccessInitialize(
    init_parameters: u64,
    boot_parameters: u64,
) callconv(abi.guest) i32 {
    if (init_parameters == 0 or boot_parameters == 0) return np_entitlement_error_parameter;
    if (!kernel_memory.isGuestRangeAccessible(init_parameters, 32) or
        !kernel_memory.isGuestRangeAccessible(boot_parameters, 32))
    {
        return errno.KernelError.efault.raw();
    }
    const output: *[32]u8 = @ptrFromInt(boot_parameters);
    @memset(output, 0);
    return errno.ok;
}

pub fn npSessionSignalingInitialize(_: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

fn writeServiceHandle(output: ?*i32, counter: *std.atomic.Value(i32)) i32 {
    const destination = output orelse return errno.KernelError.einval.raw();
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), @sizeOf(i32))) {
        return errno.KernelError.efault.raw();
    }
    destination.* = counter.fetchAdd(1, .acq_rel);
    return errno.ok;
}

pub fn npTrophy2CreateContext(
    output: ?*i32,
    _: i32,
    _: u32,
    _: u64,
) callconv(abi.guest) i32 {
    return writeServiceHandle(output, &np_trophy_next_context);
}

pub fn npTrophy2CreateHandle(output: ?*i32) callconv(abi.guest) i32 {
    return writeServiceHandle(output, &np_trophy_next_handle);
}

pub fn npWebApi2PushEventCreateHandle(library_context: i32) callconv(abi.guest) i32 {
    if (library_context <= 0) return errno.KernelError.einval.raw();
    return np_webapi_next_push_handle.fetchAdd(1, .acq_rel);
}

/// UDS is an offline telemetry sink here, but its bootstrap objects are still
/// real from the title's point of view. Initialisation validates the parameter
/// record and context creation supplies the handle later calls carry around.
pub fn udsInitialize(parameters: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (parameters == 0) return @bitCast(@as(u32, 0x8055_3102));
    if (!kernel_memory.isGuestRangeAccessible(parameters, 16)) return errno.KernelError.efault.raw();
    return errno.ok;
}

pub fn udsCreateContext(output: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (output == 0) return errno.ok;
    if (!kernel_memory.isGuestRangeAccessible(output, @sizeOf(i32))) {
        return errno.KernelError.efault.raw();
    }
    const handle: *i32 = @ptrFromInt(output);
    handle.* = 1;
    return errno.ok;
}

var uds_next_handle = std.atomic.Value(i32).init(1);

/// SDK revisions place the created UDS handle in either the first or second
/// argument. Write the first accessible output, matching the firmware's
/// compatibility behaviour without uploading any telemetry.
pub fn udsCreateHandle(first: u64, second: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    const output = if (first != 0 and kernel_memory.isGuestRangeAccessible(first, @sizeOf(i32)))
        first
    else if (second != 0 and kernel_memory.isGuestRangeAccessible(second, @sizeOf(i32)))
        second
    else
        return errno.KernelError.efault.raw();
    const handle: *i32 = @ptrFromInt(output);
    handle.* = uds_next_handle.fetchAdd(1, .acq_rel);
    return errno.ok;
}

pub fn udsCreateEvent(_: u64, _: u64, third: u64, fourth: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    const output = if (third != 0 and kernel_memory.isGuestRangeAccessible(third, @sizeOf(i32)))
        third
    else if (fourth != 0 and kernel_memory.isGuestRangeAccessible(fourth, @sizeOf(i32)))
        fourth
    else
        return errno.KernelError.efault.raw();
    const handle: *i32 = @ptrFromInt(output);
    handle.* = uds_next_handle.fetchAdd(1, .acq_rel);
    return errno.ok;
}

/// There is no host save-data dialog yet, so an opened dialog is considered
/// dismissed by the time the title polls it.  Returning FINISHED avoids the
/// Unity save plug-in waiting forever for UI that cannot be displayed.
pub fn saveDataDialogFinished(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return 3;
}

/// A headless dialog can always be serviced immediately.
pub fn saveDataDialogReady(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return 1;
}

/// Save-data event queues are empty until persistent storage is implemented.
/// This is the platform's normal NOT_FOUND/no-event result, not ENOSYS, and is
/// therefore safe for polling workers.
pub fn saveDataNoEvent(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return @bitCast(@as(u32, 0x809f0008));
}

const np_game_intent_error_invalid_argument: i32 = @bitCast(@as(u32, 0x8055_3804));
const np_game_intent_error_intent_not_found: i32 = @bitCast(@as(u32, 0x8055_3806));
const np_game_intent_error_value_not_found: i32 = @bitCast(@as(u32, 0x8055_3807));

const NpGameIntentData = extern struct {
    data: [16 * 1024 + 1]u8,
    padding: [7]u8,
};

const NpGameIntentInfo = extern struct {
    size: usize,
    user_id: i32,
    intent_type: [33]u8,
    padding: [7]u8,
    reserved: [256]u8,
    intent_data: NpGameIntentData,
};

/// Game Intent is available even when PlayStation Network is offline.  There
/// simply is no launch intent to deliver for a title started from this runner.
pub fn npGameIntentInitialize(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

pub fn npGameIntentTerminate(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

pub fn npGameIntentReceiveIntent(info_address: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (info_address == 0) return np_game_intent_error_invalid_argument;
    if (!kernel_memory.isGuestRangeAccessible(info_address, @sizeOf(NpGameIntentInfo))) {
        return errno.KernelError.efault.raw();
    }

    const info: *NpGameIntentInfo = @ptrFromInt(info_address);
    info.user_id = -1;
    @memset(&info.intent_type, 0);
    @memset(&info.intent_data.data, 0);
    @memset(&info.intent_data.padding, 0);
    return np_game_intent_error_intent_not_found;
}

pub fn npGameIntentGetPropertyValueString(
    intent_data_address: u64,
    key_address: u64,
    value_address: u64,
    value_size: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (intent_data_address == 0 or key_address == 0 or value_address == 0 or value_size == 0) {
        return np_game_intent_error_invalid_argument;
    }
    if (!kernel_memory.isGuestRangeAccessible(intent_data_address, @sizeOf(NpGameIntentData)) or
        !kernel_memory.isGuestRangeAccessible(key_address, 1) or
        !kernel_memory.isGuestRangeAccessible(value_address, 1))
    {
        return errno.KernelError.efault.raw();
    }

    const value: *u8 = @ptrFromInt(value_address);
    value.* = 0;
    return np_game_intent_error_value_not_found;
}

const table = @import("services_table.zig");

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    inline for (table.all) |entry| {
        try db.addLibrary(
            gpa,
            .{ .name = entry.library, .version = 1 },
            .{ .name = entry.module, .version_major = 1, .version_minor = 1 },
            entry.exports,
        );
    }
}

/// How many entry points this module answers, across every library.
pub fn count() usize {
    var total: usize = 0;
    inline for (table.all) |entry| total += entry.exports.len;
    return total;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "an absent service reports absence rather than success" {
    // A title told its request succeeded goes looking for a result nothing
    // produced, and fails somewhere with nothing pointing back here.
    try testing.expect(absent(0, 0, 0, 0, 0, 0) < 0);
    try testing.expect(offline(0, 0, 0, 0, 0, 0) < 0);
    try testing.expect(noDevice(0, 0, 0, 0, 0, 0) < 0);
    try testing.expectEqual(errno.ok, accept(0, 0, 0, 0, 0, 0));
}

test "the refusal sits outside every library's own numbering" {
    // Each service library numbers its errors in a space of its own. A code
    // invented inside one of those spaces could be mistaken for a documented
    // outcome and acted on; this one cannot.
    const status: u32 = @bitCast(unavailable);
    try testing.expectEqual(@as(u32, 0x8002_004e), status);
}

test "game intent ABI and offline outcomes match the platform" {
    try testing.expectEqual(@as(usize, 16_392), @sizeOf(NpGameIntentData));
    try testing.expectEqual(@as(usize, 16_704), @sizeOf(NpGameIntentInfo));
    try testing.expectEqual(errno.ok, npGameIntentInitialize(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(errno.ok, npGameIntentTerminate(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(np_game_intent_error_invalid_argument, npGameIntentReceiveIntent(0, 0, 0, 0, 0, 0));
    try testing.expectEqual(np_game_intent_error_invalid_argument, npGameIntentGetPropertyValueString(0, 0, 0, 0, 0, 0));
}

test "game update reports a successful offline check" {
    try testing.expectEqual(@as(usize, 48), @sizeOf(GameUpdateCheckParam));
    try testing.expectEqual(@as(usize, 48), @sizeOf(GameUpdateCheckResult));
    try testing.expectEqual(@as(usize, 48), @sizeOf(GameUpdateAddcontVersionInfo));
    try testing.expectEqual(errno.ok, gameUpdateInitialize());
    const request = gameUpdateCreateRequest();
    try testing.expectEqual(@as(i32, 1), request);
    const parameters = GameUpdateCheckParam{
        .size = @sizeOf(GameUpdateCheckParam),
        .option = 0,
        .reserved = @splat(0),
    };
    var result = std.mem.zeroes(GameUpdateCheckResult);
    result.size = @sizeOf(GameUpdateCheckResult);
    result.found = 1;
    result.addcont_found = 1;
    try testing.expectEqual(errno.ok, gameUpdateCheck(request, &parameters, &result));
    try testing.expectEqual(@as(u8, 0), result.found);
    try testing.expectEqual(@as(u8, 0), result.addcont_found);
    try testing.expectEqual(errno.ok, gameUpdateDeleteRequest(request));
    try testing.expectEqual(game_update_error_request_not_found, gameUpdateDeleteRequest(request));
    try testing.expectEqual(errno.ok, gameUpdateTerminate());
}

test "offline NP bootstrap creates local contexts" {
    var init_parameters: [32]u8 = @splat(0xa5);
    var boot_parameters: [32]u8 = @splat(0xa5);
    try testing.expectEqual(
        errno.ok,
        npEntitlementAccessInitialize(@intFromPtr(&init_parameters), @intFromPtr(&boot_parameters)),
    );
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &boot_parameters);
    try testing.expectEqual(errno.ok, npSessionSignalingInitialize(0));

    np_trophy_next_context.store(1, .release);
    np_trophy_next_handle.store(1, .release);
    np_webapi_next_push_handle.store(1, .release);
    var context: i32 = 0;
    var handle: i32 = 0;
    try testing.expectEqual(errno.ok, npTrophy2CreateContext(&context, 0x1000_0000, 0, 0));
    try testing.expectEqual(errno.ok, npTrophy2CreateHandle(&handle));
    try testing.expectEqual(@as(i32, 1), context);
    try testing.expectEqual(@as(i32, 1), handle);
    try testing.expectEqual(@as(i32, 1), npWebApi2PushEventCreateHandle(4));
}

test "every service entry point registers under its published identifier" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(count(), db.count());
    try testing.expect(count() > 300);
}

test "a streaming session reports itself absent across its whole block" {
    // The block is the title's, and every byte of it must describe the
    // session rather than whatever the memory held before.
    var status: [remoteplay_status_bytes]u8 = @splat(0xa7);
    try testing.expectEqual(errno.ok, remoteplayGetConnectionStatus(0, &status));
    for (status) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(errno.ok, remoteplayGetConnectionStatus(0, null));
}

test "installed content is answered as being on the drive" {
    var on_drive: u32 = 0;
    try testing.expectEqual(errno.ok, discMapIsRequestOnHDD("/app0/data.pak", 0, 4096, &on_drive));
    try testing.expectEqual(@as(u32, 1), on_drive);

    // A question with nowhere to put the answer is refused rather than
    // reported as answered.
    try testing.expectEqual(
        disc_map_error_invalid_argument,
        discMapIsRequestOnHDD("/app0/data.pak", 0, 4096, null),
    );
    try testing.expectEqual(disc_map_error_invalid_argument, discMapIsRequestOnHDD(null, 0, 0, &on_drive));
}
