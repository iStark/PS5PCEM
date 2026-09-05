// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Headless common, message, browser, and input-dialog services.
//!
//! Dialogs complete immediately because there is no console shell to render
//! them. Their state still follows the guest lifecycle so polling code cannot
//! hang and result buffers never expose uninitialized memory.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const kernel_memory = @import("kernel_memory.zig");
const symbols = @import("../symbols.zig");

const status_none: i32 = 0;
const status_initialized: i32 = 1;
const status_running: i32 = 2;
const status_finished: i32 = 3;

const msg_error_not_initialized: i32 = @bitCast(@as(u32, 0x80B8_0003));
const msg_error_not_finished: i32 = @bitCast(@as(u32, 0x80B8_0005));
const msg_error_not_running: i32 = @bitCast(@as(u32, 0x80B8_000B));
const msg_error_argument_null: i32 = @bitCast(@as(u32, 0x80B8_000D));
const ime_error_invalid_address: i32 = @bitCast(@as(u32, 0x80BC_0001));

var message_status: std.atomic.Value(i32) = .init(status_none);
var message_mode: std.atomic.Value(i32) = .init(0);
var browser_status: std.atomic.Value(i32) = .init(status_none);
var ime_dialog_status: std.atomic.Value(i32) = .init(status_none);
var signin_dialog_status: std.atomic.Value(i32) = .init(status_none);
var playgo_dialog_status: std.atomic.Value(i32) = .init(status_none);
var save_dialog_status: std.atomic.Value(i32) = .init(status_none);
var save_dialog_mode: std.atomic.Value(i32) = .init(0);
var save_dialog_user_data: std.atomic.Value(u64) = .init(0);
var player_review_status: std.atomic.Value(i32) = .init(status_none);
var error_dialog_status: std.atomic.Value(i32) = .init(status_none);
var keyboard_open: std.atomic.Value(u8) = .init(0);

pub fn reset() void {
    message_status.store(status_none, .release);
    message_mode.store(0, .release);
    browser_status.store(status_none, .release);
    ime_dialog_status.store(status_none, .release);
    signin_dialog_status.store(status_none, .release);
    playgo_dialog_status.store(status_none, .release);
    save_dialog_status.store(status_none, .release);
    save_dialog_mode.store(0, .release);
    save_dialog_user_data.store(0, .release);
    player_review_status.store(status_none, .release);
    error_dialog_status.store(status_none, .release);
    keyboard_open.store(0, .release);
}

// Common and message dialogs ------------------------------------------------

fn commonDialogInitialize() callconv(abi.guest) i32 {
    return errno.ok;
}

fn commonDialogIsUsed() callconv(abi.guest) i32 {
    return 0;
}

fn messageInitialize() callconv(abi.guest) i32 {
    _ = message_status.cmpxchgStrong(status_none, status_initialized, .acq_rel, .acquire);
    return errno.ok;
}

fn messageTerminate() callconv(abi.guest) i32 {
    if (message_status.swap(status_none, .acq_rel) == status_none) return msg_error_not_initialized;
    message_mode.store(0, .release);
    return errno.ok;
}

fn messageOpen(parameter: ?[*]const u8) callconv(abi.guest) i32 {
    const bytes = parameter orelse return msg_error_argument_null;
    if (message_status.load(.acquire) == status_none) return msg_error_not_initialized;
    // SceMsgDialogParam::mode follows the 0x30-byte common base and u64 size.
    message_mode.store(std.mem.readInt(i32, bytes[0x38..0x3c], .little), .release);
    // A headless dialog has no user interaction to wait for.
    message_status.store(status_finished, .release);
    return errno.ok;
}

fn messageUpdateStatus() callconv(abi.guest) i32 {
    if (message_status.load(.acquire) == status_running) {
        message_status.store(status_finished, .release);
    }
    return message_status.load(.acquire);
}

fn messageGetStatus() callconv(abi.guest) i32 {
    return message_status.load(.acquire);
}

fn messageGetResult(result: ?*[32]u8) callconv(abi.guest) i32 {
    const output = result orelse return msg_error_argument_null;
    if (message_status.load(.acquire) == status_none) return msg_error_not_initialized;
    if (message_status.load(.acquire) != status_finished) return msg_error_not_finished;
    @memset(output, 0);
    std.mem.writeInt(i32, output[0x00..0x04], message_mode.load(.acquire), .little);
    std.mem.writeInt(i32, output[0x08..0x0c], 1, .little); // affirmative/OK
    return errno.ok;
}

fn messageClose() callconv(abi.guest) i32 {
    if (message_status.load(.acquire) == status_none) return msg_error_not_initialized;
    if (message_status.load(.acquire) != status_running and
        message_status.load(.acquire) != status_finished)
    {
        return msg_error_not_running;
    }
    message_status.store(status_finished, .release);
    return errno.ok;
}

fn messageProgress(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return if (message_status.load(.acquire) == status_none) msg_error_not_initialized else errno.ok;
}

const common_dialog_exports = [_]symbols.Export{
    .{ .name = "sceCommonDialogInitialize", .function = trace.wrap("sceCommonDialogInitialize", &commonDialogInitialize), .expect_id = "uoUpLGNkygk" },
    .{ .name = "sceCommonDialogIsUsed", .function = trace.wrap("sceCommonDialogIsUsed", &commonDialogIsUsed), .expect_id = "BQ3tey0JmQM" },
};

const message_dialog_exports = [_]symbols.Export{
    .{ .name = "sceMsgDialogInitialize", .function = trace.wrap("sceMsgDialogInitialize", &messageInitialize), .expect_id = "lDqxaY1UbEo" },
    .{ .name = "sceMsgDialogTerminate", .function = trace.wrap("sceMsgDialogTerminate", &messageTerminate), .expect_id = "ePw-kqZmelo" },
    .{ .name = "sceMsgDialogOpen", .function = trace.wrap("sceMsgDialogOpen", &messageOpen), .expect_id = "b06Hh0DPEaE" },
    .{ .name = "sceMsgDialogUpdateStatus", .function = trace.wrap("sceMsgDialogUpdateStatus", &messageUpdateStatus), .expect_id = "6fIC3XKt2k0" },
    .{ .name = "sceMsgDialogGetStatus", .function = trace.wrap("sceMsgDialogGetStatus", &messageGetStatus), .expect_id = "CWVW78Qc3fI" },
    .{ .name = "sceMsgDialogGetResult", .function = trace.wrap("sceMsgDialogGetResult", &messageGetResult), .expect_id = "Lr8ovHH9l6A" },
    .{ .name = "sceMsgDialogClose", .function = trace.wrap("sceMsgDialogClose", &messageClose), .expect_id = "HTrcDKlFKuM" },
    .{ .name = "sceMsgDialogProgressBarSetValue", .function = trace.wrap("sceMsgDialogProgressBarSetValue", &messageProgress), .expect_id = "wTpfglkmv34" },
    .{ .name = "sceMsgDialogProgressBarInc", .function = trace.wrap("sceMsgDialogProgressBarInc", &messageProgress), .expect_id = "Gc5k1qcK4fs" },
    .{ .name = "sceMsgDialogProgressBarSetMsg", .function = trace.wrap("sceMsgDialogProgressBarSetMsg", &messageProgress), .expect_id = "6H-71OdrpXM" },
};

// Error dialog -------------------------------------------------------------

const error_dialog_error_not_initialized: i32 = @bitCast(@as(u32, 0x80ED_0001));
const error_dialog_error_already_initialized: i32 = @bitCast(@as(u32, 0x80ED_0002));
const error_dialog_error_parameter: i32 = @bitCast(@as(u32, 0x80ED_0003));
const error_dialog_error_invalid_state: i32 = @bitCast(@as(u32, 0x80ED_0005));

pub fn errorDialogInitialize() callconv(abi.guest) i32 {
    if (error_dialog_status.cmpxchgStrong(
        status_none,
        status_initialized,
        .acq_rel,
        .acquire,
    ) != null) return error_dialog_error_already_initialized;
    return errno.ok;
}

pub fn errorDialogOpen(parameter: ?[*]const u8) callconv(abi.guest) i32 {
    const status = error_dialog_status.load(.acquire);
    if (status != status_initialized and status != status_finished) {
        return error_dialog_error_invalid_state;
    }
    const bytes = parameter orelse return error_dialog_error_parameter;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(bytes), 16)) {
        return error_dialog_error_parameter;
    }
    if (std.mem.readInt(i32, bytes[0..4], .little) != 16) {
        return error_dialog_error_parameter;
    }
    // There is no host error-dialog window yet. Preserve the guest's error
    // code in the log before UpdateStatus acknowledges the dialog, otherwise
    // a startup failure disappears without any explanation.
    std.debug.print("[error dialog] code=0x{x:0>8} user={d}\n", .{
        std.mem.readInt(u32, bytes[4..8], .little),
        std.mem.readInt(i32, bytes[8..12], .little),
    });
    error_dialog_status.store(status_running, .release);
    return errno.ok;
}

pub fn errorDialogUpdateStatus() callconv(abi.guest) i32 {
    if (error_dialog_status.load(.acquire) == status_running) {
        error_dialog_status.store(status_finished, .release);
    }
    return error_dialog_status.load(.acquire);
}

pub fn errorDialogGetStatus() callconv(abi.guest) i32 {
    return error_dialog_status.load(.acquire);
}

pub fn errorDialogClose() callconv(abi.guest) i32 {
    if (error_dialog_status.load(.acquire) != status_running) {
        return error_dialog_error_invalid_state;
    }
    error_dialog_status.store(status_finished, .release);
    return errno.ok;
}

pub fn errorDialogTerminate() callconv(abi.guest) i32 {
    if (error_dialog_status.swap(status_none, .acq_rel) == status_none) {
        return error_dialog_error_not_initialized;
    }
    return errno.ok;
}

// Web-browser dialog --------------------------------------------------------

fn browserInitialize() callconv(abi.guest) i32 {
    browser_status.store(status_initialized, .release);
    return errno.ok;
}

fn browserOpen(_: ?*const anyopaque) callconv(abi.guest) i32 {
    if (browser_status.load(.acquire) == status_none) browser_status.store(status_initialized, .release);
    browser_status.store(status_finished, .release);
    return errno.ok;
}

fn browserUpdateStatus() callconv(abi.guest) i32 {
    if (browser_status.load(.acquire) == status_running) browser_status.store(status_finished, .release);
    return browser_status.load(.acquire);
}

fn browserTerminate() callconv(abi.guest) i32 {
    browser_status.store(status_none, .release);
    return errno.ok;
}

const browser_dialog_exports = [_]symbols.Export{
    .{ .name = "sceWebBrowserDialogInitialize", .function = trace.wrap("sceWebBrowserDialogInitialize", &browserInitialize), .expect_id = "jqb7HntFQFc" },
    .{ .name = "sceWebBrowserDialogOpen", .function = trace.wrap("sceWebBrowserDialogOpen", &browserOpen), .expect_id = "FraP7debcdg" },
    .{ .name = "sceWebBrowserDialogUpdateStatus", .function = trace.wrap("sceWebBrowserDialogUpdateStatus", &browserUpdateStatus), .expect_id = "h1dR-t5ISgg" },
    .{ .name = "sceWebBrowserDialogTerminate", .function = trace.wrap("sceWebBrowserDialogTerminate", &browserTerminate), .expect_id = "ocHtyBwHfys" },
};

// Sign-in dialog -----------------------------------------------------------

fn signinDialogInitialize() callconv(abi.guest) i32 {
    signin_dialog_status.store(status_initialized, .release);
    return errno.ok;
}

fn signinDialogOpen(_: ?*const anyopaque) callconv(abi.guest) i32 {
    if (signin_dialog_status.load(.acquire) == status_none) {
        signin_dialog_status.store(status_initialized, .release);
    }
    // The emulator already exposes its local user, so there is no shell UI to
    // wait for. Completing the dialog lets the title continue offline.
    signin_dialog_status.store(status_finished, .release);
    return errno.ok;
}

fn signinDialogUpdateStatus() callconv(abi.guest) i32 {
    return signin_dialog_status.load(.acquire);
}

fn signinDialogClose() callconv(abi.guest) i32 {
    if (signin_dialog_status.load(.acquire) == status_none) {
        return @bitCast(@as(u32, 0x8135_0001));
    }
    signin_dialog_status.store(status_finished, .release);
    return errno.ok;
}

fn signinDialogGetResult(result: ?*[16]u8) callconv(abi.guest) i32 {
    const output = result orelse return @bitCast(@as(u32, 0x8135_0003));
    @memset(output, 0);
    // No platform sign-in UI exists. Report the documented user-cancelled
    // outcome so middleware takes its offline path instead of waiting.
    std.mem.writeInt(i32, output[0..4], 1, .little);
    return errno.ok;
}

fn signinDialogTerminate() callconv(abi.guest) i32 {
    signin_dialog_status.store(status_none, .release);
    return errno.ok;
}

const signin_dialog_exports = [_]symbols.Export{
    .{ .name = "sceSigninDialogUpdateStatus", .function = trace.wrap("sceSigninDialogUpdateStatus", &signinDialogUpdateStatus), .expect_id = "Bw31liTFT3A" },
    .{ .name = "sceSigninDialogInitialize", .function = trace.wrap("sceSigninDialogInitialize", &signinDialogInitialize), .expect_id = "mlYGfmqE3fQ" },
    .{ .name = "sceSigninDialogOpen", .function = trace.wrap("sceSigninDialogOpen", &signinDialogOpen), .expect_id = "JlpJVoRWv7U" },
    .{ .name = "sceSigninDialogTerminate", .function = trace.wrap("sceSigninDialogTerminate", &signinDialogTerminate), .expect_id = "LXlmS6PvJdU" },
    .{ .name = "sceSigninDialogClose", .function = trace.wrap("sceSigninDialogClose", &signinDialogClose), .expect_id = "M3OkENHcyiU" },
    .{ .name = "sceSigninDialogGetResult", .function = trace.wrap("sceSigninDialogGetResult", &signinDialogGetResult), .expect_id = "nqG7rqnYw1U" },
};

// PlayGo dialog ------------------------------------------------------------

fn playGoDialogInitialize() callconv(abi.guest) i32 {
    playgo_dialog_status.store(status_initialized, .release);
    return errno.ok;
}

fn playGoDialogOpen(_: ?*const anyopaque) callconv(abi.guest) i32 {
    if (playgo_dialog_status.load(.acquire) == status_none) {
        playgo_dialog_status.store(status_initialized, .release);
    }
    // All package chunks are local, so the progress dialog has no work to
    // display and completes in the same poll cycle.
    playgo_dialog_status.store(status_finished, .release);
    return errno.ok;
}

fn playGoDialogStatus() callconv(abi.guest) i32 {
    return playgo_dialog_status.load(.acquire);
}

fn playGoDialogGetResult(result: ?*[16]u8) callconv(abi.guest) i32 {
    const output = result orelse return msg_error_argument_null;
    @memset(output, 0);
    return errno.ok;
}

fn playGoDialogClose() callconv(abi.guest) i32 {
    playgo_dialog_status.store(status_finished, .release);
    return errno.ok;
}

fn playGoDialogTerminate() callconv(abi.guest) i32 {
    playgo_dialog_status.store(status_none, .release);
    return errno.ok;
}

const playgo_dialog_exports = [_]symbols.Export{
    .{ .name = "scePlayGoDialogInitialize", .function = trace.wrap("scePlayGoDialogInitialize", &playGoDialogInitialize), .expect_id = "fECamTJKpsM" },
    .{ .name = "scePlayGoDialogOpen", .function = trace.wrap("scePlayGoDialogOpen", &playGoDialogOpen), .expect_id = "kHd72ukqbxw" },
    .{ .name = "scePlayGoDialogUpdateStatus", .function = trace.wrap("scePlayGoDialogUpdateStatus", &playGoDialogStatus), .expect_id = "Yb60K7BST48" },
    .{ .name = "scePlayGoDialogGetStatus", .function = trace.wrap("scePlayGoDialogGetStatus", &playGoDialogStatus), .expect_id = "NOAMxY2EGS0" },
    .{ .name = "scePlayGoDialogGetResult", .function = trace.wrap("scePlayGoDialogGetResult", &playGoDialogGetResult), .expect_id = "wx9TDplJKB4" },
    .{ .name = "scePlayGoDialogClose", .function = trace.wrap("scePlayGoDialogClose", &playGoDialogClose), .expect_id = "fbigNQiZpm0" },
    .{ .name = "scePlayGoDialogTerminate", .function = trace.wrap("scePlayGoDialogTerminate", &playGoDialogTerminate), .expect_id = "okgIGdr5Iz0" },
};

// Player-review dialog ------------------------------------------------------

fn playerReviewInitialize() callconv(abi.guest) i32 {
    player_review_status.store(status_initialized, .release);
    return errno.ok;
}

fn playerReviewOpen(_: ?*const anyopaque) callconv(abi.guest) i32 {
    if (player_review_status.load(.acquire) == status_none) {
        player_review_status.store(status_initialized, .release);
    }
    // There is no platform shell to collect a review. Completing immediately
    // is the offline result and, importantly, never stalls a polling plug-in.
    player_review_status.store(status_finished, .release);
    return errno.ok;
}

fn playerReviewStatus() callconv(abi.guest) i32 {
    return player_review_status.load(.acquire);
}

fn playerReviewGetResult(result: ?*[8]u8) callconv(abi.guest) i32 {
    const output = result orelse return msg_error_argument_null;
    @memset(output, 0);
    return errno.ok;
}

fn playerReviewClose() callconv(abi.guest) i32 {
    if (player_review_status.load(.acquire) != status_none) {
        player_review_status.store(status_finished, .release);
    }
    return errno.ok;
}

fn playerReviewTerminate() callconv(abi.guest) i32 {
    player_review_status.store(status_none, .release);
    return errno.ok;
}

const player_review_dialog_exports = [_]symbols.Export{
    .{ .name = "scePlayerReviewDialogInitialize", .function = trace.wrap("scePlayerReviewDialogInitialize", &playerReviewInitialize), .expect_id = "UtXl-tmi7iw" },
    .{ .name = "scePlayerReviewDialogOpen", .function = trace.wrap("scePlayerReviewDialogOpen", &playerReviewOpen), .expect_id = "CtygVRCL+bA" },
    .{ .name = "scePlayerReviewDialogUpdateStatus", .function = trace.wrap("scePlayerReviewDialogUpdateStatus", &playerReviewStatus), .expect_id = "4J5F23VgTjY" },
    .{ .name = "scePlayerReviewDialogGetStatus", .function = trace.wrap("scePlayerReviewDialogGetStatus", &playerReviewStatus), .expect_id = "UYw6RlK7bcQ" },
    .{ .name = "scePlayerReviewDialogGetResult", .function = trace.wrap("scePlayerReviewDialogGetResult", &playerReviewGetResult), .expect_id = "VuKbx6zlEG4" },
    .{ .name = "scePlayerReviewDialogClose", .function = trace.wrap("scePlayerReviewDialogClose", &playerReviewClose), .expect_id = "HDMHJ9zsCFg" },
    .{ .name = "scePlayerReviewDialogTerminate", .function = trace.wrap("scePlayerReviewDialogTerminate", &playerReviewTerminate), .expect_id = "RmJKkzZFNFA" },
};

// Save-data dialog ---------------------------------------------------------

fn saveDialogInitialize() callconv(abi.guest) i32 {
    save_dialog_status.store(status_initialized, .release);
    save_dialog_mode.store(0, .release);
    save_dialog_user_data.store(0, .release);
    return errno.ok;
}

fn saveDialogOpen(parameter: ?[*]const u8) callconv(abi.guest) i32 {
    if (parameter) |bytes| {
        // Common-dialog base (0x30), then size/mode/dispType/padding and eight
        // pointers. Mode and userData are reflected by GetResult.
        save_dialog_mode.store(std.mem.readInt(i32, bytes[0x34..0x38], .little), .release);
        save_dialog_user_data.store(std.mem.readInt(u64, bytes[0x70..0x78], .little), .release);
    }
    save_dialog_status.store(status_finished, .release);
    return errno.ok;
}

fn saveDialogStatus() callconv(abi.guest) i32 {
    return save_dialog_status.load(.acquire);
}

fn saveDialogGetResult(result: ?*[72]u8) callconv(abi.guest) i32 {
    const output = result orelse return msg_error_argument_null;
    @memset(output, 0);
    std.mem.writeInt(i32, output[0..4], save_dialog_mode.load(.acquire), .little);
    std.mem.writeInt(i32, output[4..8], 0, .little); // OK
    std.mem.writeInt(i32, output[8..12], 1, .little); // OK button
    std.mem.writeInt(u64, output[32..40], save_dialog_user_data.load(.acquire), .little);
    return errno.ok;
}

fn saveDialogClose(_: ?*const anyopaque) callconv(abi.guest) i32 {
    save_dialog_status.store(status_finished, .release);
    return errno.ok;
}

fn saveDialogReady() callconv(abi.guest) i32 {
    return 1;
}

fn saveDialogTerminate() callconv(abi.guest) i32 {
    save_dialog_status.store(status_none, .release);
    return errno.ok;
}

const save_dialog_exports = [_]symbols.Export{
    .{ .name = "sceSaveDataDialogInitialize", .function = trace.wrap("sceSaveDataDialogInitialize", &saveDialogInitialize), .expect_id = "s9e3+YpRnzw" },
    .{ .name = "sceSaveDataDialogOpen", .function = trace.wrap("sceSaveDataDialogOpen", &saveDialogOpen), .expect_id = "4tPhsP6FpDI" },
    .{ .name = "sceSaveDataDialogUpdateStatus", .function = trace.wrap("sceSaveDataDialogUpdateStatus", &saveDialogStatus), .expect_id = "KK3Bdg1RWK0" },
    .{ .name = "sceSaveDataDialogGetStatus", .function = trace.wrap("sceSaveDataDialogGetStatus", &saveDialogStatus), .expect_id = "ERKzksauAJA" },
    .{ .name = "sceSaveDataDialogGetResult", .function = trace.wrap("sceSaveDataDialogGetResult", &saveDialogGetResult), .expect_id = "yEiJ-qqr6Cg" },
    .{ .name = "sceSaveDataDialogClose", .function = trace.wrap("sceSaveDataDialogClose", &saveDialogClose), .expect_id = "fH46Lag88XY" },
    .{ .name = "sceSaveDataDialogIsReadyToDisplay", .function = trace.wrap("sceSaveDataDialogIsReadyToDisplay", &saveDialogReady), .expect_id = "en7gNVnh878" },
    .{ .name = "sceSaveDataDialogTerminate", .function = trace.wrap("sceSaveDataDialogTerminate", &saveDialogTerminate), .expect_id = "YuH2FA7azqQ" },
    .{ .name = "sceSaveDataDialogProgressBarInc", .function = trace.wrap("sceSaveDataDialogProgressBarInc", &messageProgress), .expect_id = "V-uEeFKARJU" },
    .{ .name = "sceSaveDataDialogProgressBarSetValue", .function = trace.wrap("sceSaveDataDialogProgressBarSetValue", &messageProgress), .expect_id = "hay1CfTmLyA" },
};

// IME dialog and optional physical keyboard --------------------------------

fn imeDialogInit(parameter: ?*const anyopaque) callconv(abi.guest) i32 {
    if (parameter == null) return ime_error_invalid_address;
    ime_dialog_status.store(2, .release); // FINISHED in the IME-dialog ABI
    return errno.ok;
}

fn imeDialogAbort() callconv(abi.guest) i32 {
    ime_dialog_status.store(2, .release);
    return errno.ok;
}

fn imeDialogGetStatus() callconv(abi.guest) i32 {
    return ime_dialog_status.load(.acquire);
}

fn imeDialogGetResult(result: ?*[8]u8) callconv(abi.guest) i32 {
    const output = result orelse return ime_error_invalid_address;
    @memset(output, 0); // endStatus = OK, reserved = 0
    return errno.ok;
}

/// Reports how much of the screen the on-screen keyboard would cover.
///
/// A title asks this to lay its own text field out around the panel. This
/// dialog never presents one — it completes as soon as it is opened, because
/// there is nobody here to type — so the honest answer is that nothing is
/// covered. Naming a plausible-looking panel instead would push the title's
/// own interface aside to make room for a keyboard that never appears.
/// Size of `SceImeParam`, which `sceImeParamInit` is asked to blank.
const ime_param_bytes: usize = 0x60;
/// Size of the panel position-and-form description.
const ime_position_and_form_bytes: usize = 0x1c;

var ime_session_open: std.atomic.Value(u32) = .init(0);

fn imeWritableRange(address: u64, size: usize) bool {
    return address != 0 and kernel_memory.isGuestRangeAccessible(address, size);
}

/// Reports the panel size for the keyboard, which covers nothing.
///
/// Shared by the dialog and the session forms of the question, because both
/// describe the same keyboard and this one is never drawn.
fn writeEmptyPanelSize(width: ?*u32, height: ?*u32) i32 {
    const width_output = width orelse return ime_error_invalid_address;
    const height_output = height orelse return ime_error_invalid_address;
    if (!imeWritableRange(@intFromPtr(width_output), @sizeOf(u32)) or
        !imeWritableRange(@intFromPtr(height_output), @sizeOf(u32)))
    {
        return ime_error_invalid_address;
    }
    width_output.* = 0;
    height_output.* = 0;
    return errno.ok;
}

pub fn imeGetPanelSize(_: ?*const anyopaque, width: ?*u32, height: ?*u32) callconv(abi.guest) i32 {
    return writeEmptyPanelSize(width, height);
}

pub fn imeDialogGetPanelSize(_: ?*const anyopaque, width: ?*u32, height: ?*u32) callconv(abi.guest) i32 {
    return writeEmptyPanelSize(width, height);
}

/// Describes where the panel sits and how it is shaped. With no panel there
/// is nothing to place, so every field is left at zero rather than at a
/// position a title would lay itself out around.
pub fn imeDialogGetPanelPositionAndForm(form: ?*[ime_position_and_form_bytes]u8) callconv(abi.guest) i32 {
    const output = form orelse return ime_error_invalid_address;
    if (!imeWritableRange(@intFromPtr(output), ime_position_and_form_bytes)) {
        return ime_error_invalid_address;
    }
    @memset(output, 0);
    return errno.ok;
}

/// Blanks a parameter block before a title fills in the fields it cares
/// about. The block is the title's, so it is only written once its whole
/// extent is known to be there.
pub fn imeParamInit(param: ?*[ime_param_bytes]u8) callconv(abi.guest) void {
    const output = param orelse return;
    if (!imeWritableRange(@intFromPtr(output), ime_param_bytes)) return;
    @memset(output, 0);
}

/// Opens a text-entry session without a dialog.
///
/// The session is accepted and remembered so that closing it is meaningful,
/// but nothing is presented: there is nobody here to type, and a title that
/// opens one receives the events it would receive from a keyboard left alone.
pub fn imeOpen(_: ?*const anyopaque, _: ?*const anyopaque) callconv(abi.guest) i32 {
    ime_session_open.store(1, .release);
    return errno.ok;
}

pub fn imeClose() callconv(abi.guest) i32 {
    ime_session_open.store(0, .release);
    return errno.ok;
}

/// Accepts text, caret and geometry a title sets on its own field.
///
/// These describe what the title has already drawn, so there is nothing for
/// this side to do with them; refusing would tell the title its own display
/// is invalid, which it is not.
pub fn imeSetText(_: ?[*]const u16, _: u32) callconv(abi.guest) i32 {
    return errno.ok;
}

pub fn imeSetCaret(_: ?*const anyopaque) callconv(abi.guest) i32 {
    return errno.ok;
}

pub fn imeSetTextGeometry(_: u32, _: ?*const anyopaque) callconv(abi.guest) i32 {
    return errno.ok;
}

pub fn imeKeyboardSetMode(_: i32, _: u32) callconv(abi.guest) i32 {
    return errno.ok;
}

pub fn imeDialogGetPanelSizeExtended(
    _: ?*const anyopaque,
    _: ?*const anyopaque,
    width: ?*u32,
    height: ?*u32,
) callconv(abi.guest) i32 {
    const width_output = width orelse return ime_error_invalid_address;
    const height_output = height orelse return ime_error_invalid_address;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(width_output), @sizeOf(u32)) or
        !kernel_memory.isGuestRangeAccessible(@intFromPtr(height_output), @sizeOf(u32)))
    {
        return ime_error_invalid_address;
    }
    width_output.* = 0;
    height_output.* = 0;
    return errno.ok;
}

fn imeDialogTerm() callconv(abi.guest) i32 {
    ime_dialog_status.store(status_none, .release);
    return errno.ok;
}

fn keyboardOpenFn(_: i32, parameter: ?*const anyopaque) callconv(abi.guest) i32 {
    if (parameter == null) return ime_error_invalid_address;
    keyboard_open.store(1, .release);
    return errno.ok;
}

fn keyboardClose(_: i32) callconv(abi.guest) i32 {
    keyboard_open.store(0, .release);
    return errno.ok;
}

fn keyboardGetResourceId(_: i32, output: ?*u32) callconv(abi.guest) i32 {
    if (output) |resource_id| resource_id.* = 0;
    return errno.ok;
}

fn keyboardGetInfo(_: u32, output: ?*[64]u8) callconv(abi.guest) i32 {
    if (output) |info| @memset(info, 0);
    return errno.ok;
}

fn imeUpdate(_: ?*anyopaque) callconv(abi.guest) i32 {
    return errno.ok;
}

const ime_dialog_exports = [_]symbols.Export{
    .{ .name = "sceImeDialogInit", .function = trace.wrap("sceImeDialogInit", &imeDialogInit), .expect_id = "NUeBrN7hzf0" },
    .{ .name = "sceImeDialogAbort", .function = trace.wrap("sceImeDialogAbort", &imeDialogAbort), .expect_id = "oBmw4xrmfKs" },
    .{ .name = "sceImeDialogGetStatus", .function = trace.wrap("sceImeDialogGetStatus", &imeDialogGetStatus), .expect_id = "IADmD4tScBY" },
    .{ .name = "sceImeDialogGetResult", .function = trace.wrap("sceImeDialogGetResult", &imeDialogGetResult), .expect_id = "x01jxu+vxlc" },
    .{ .name = "sceImeDialogTerm", .function = trace.wrap("sceImeDialogTerm", &imeDialogTerm), .expect_id = "gyTyVn+bXMw" },
    .{ .name = "sceImeDialogGetPanelSize", .function = trace.wrap("sceImeDialogGetPanelSize", &imeDialogGetPanelSize), .expect_id = "wqsJvRXwl58" },
    .{ .name = "sceImeDialogGetPanelPositionAndForm", .function = trace.wrap("sceImeDialogGetPanelPositionAndForm", &imeDialogGetPanelPositionAndForm), .expect_id = "8jqzzPioYl8" },
};

const ime_exports = [_]symbols.Export{
    .{ .name = "sceImeKeyboardOpen", .function = trace.wrap("sceImeKeyboardOpen", &keyboardOpenFn), .expect_id = "eaFXjfJv3xs" },
    .{ .name = "sceImeKeyboardClose", .function = trace.wrap("sceImeKeyboardClose", &keyboardClose), .expect_id = "PMVehSlfZ94" },
    .{ .name = "sceImeKeyboardGetResourceId", .function = trace.wrap("sceImeKeyboardGetResourceId", &keyboardGetResourceId), .expect_id = "dKadqZFgKKQ" },
    .{ .name = "sceImeKeyboardGetInfo", .function = trace.wrap("sceImeKeyboardGetInfo", &keyboardGetInfo), .expect_id = "VkqLPArfFdc" },
    .{ .name = "sceImeUpdate", .function = trace.wrap("sceImeUpdate", &imeUpdate), .expect_id = "-4GCfYdNF1s" },
    .{ .name = "sceImeOpen", .function = trace.wrap("sceImeOpen", &imeOpen), .expect_id = "RPydv-Jr1bc" },
    .{ .name = "sceImeClose", .function = trace.wrap("sceImeClose", &imeClose), .expect_id = "TmVP8LzcFcY" },
    .{ .name = "sceImeParamInit", .function = trace.wrap("sceImeParamInit", &imeParamInit), .expect_id = "WmYDzdC4EHI" },
    .{ .name = "sceImeSetText", .function = trace.wrap("sceImeSetText", &imeSetText), .expect_id = "ieCNrVrzKd4" },
    .{ .name = "sceImeSetCaret", .function = trace.wrap("sceImeSetCaret", &imeSetCaret), .expect_id = "WLxUN2WMim8" },
    .{ .name = "sceImeSetTextGeometry", .function = trace.wrap("sceImeSetTextGeometry", &imeSetTextGeometry), .expect_id = "TXYHFRuL8UY" },
    .{ .name = "sceImeGetPanelSize", .function = trace.wrap("sceImeGetPanelSize", &imeGetPanelSize), .expect_id = "ziPDcIjO0Vk" },
    .{ .name = "sceImeKeyboardSetMode", .function = trace.wrap("sceImeKeyboardSetMode", &imeKeyboardSetMode), .expect_id = "ua+13Hk9kKs" },
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libSceCommonDialog" }, .{ .name = "libSceCommonDialog" }, &common_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceMsgDialog.native" }, .{ .name = "libSceMsgDialog" }, &message_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceWebBrowserDialog" }, .{ .name = "libSceWebBrowserDialog" }, &browser_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceSigninDialog" }, .{ .name = "libSceSigninDialog" }, &signin_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libScePlayGoDialog" }, .{ .name = "libScePlayGoDialog" }, &playgo_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceCdlgPlayerReview" }, .{ .name = "libSceCdlgPlayerReview" }, &player_review_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceSaveDataDialog.native" }, .{ .name = "libSceSaveDataDialog" }, &save_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceImeDialog" }, .{ .name = "libSceImeDialog" }, &ime_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceIme" }, .{ .name = "libSceIme" }, &ime_exports);
}

test "headless message dialog finishes immediately with an affirmative result" {
    reset();
    try std.testing.expectEqual(errno.ok, messageInitialize());
    var parameter: [0x80]u8 = [_]u8{0} ** 0x80;
    std.mem.writeInt(i32, parameter[0x38..0x3c], 7, .little);
    try std.testing.expectEqual(errno.ok, messageOpen(&parameter));
    try std.testing.expectEqual(status_finished, messageUpdateStatus());
    var result: [32]u8 = undefined;
    try std.testing.expectEqual(errno.ok, messageGetResult(&result));
    try std.testing.expectEqual(@as(i32, 7), std.mem.readInt(i32, result[0..4], .little));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, result[8..12], .little));
}

test "headless player-review dialog completes without shell UI" {
    reset();
    try std.testing.expectEqual(errno.ok, playerReviewInitialize());
    try std.testing.expectEqual(status_initialized, playerReviewStatus());
    try std.testing.expectEqual(errno.ok, playerReviewOpen(null));
    try std.testing.expectEqual(status_finished, playerReviewStatus());
    var result: [8]u8 = @splat(0xff);
    try std.testing.expectEqual(errno.ok, playerReviewGetResult(&result));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &result);
    try std.testing.expectEqual(errno.ok, playerReviewTerminate());
    try std.testing.expectEqual(status_none, playerReviewStatus());
}

test "headless error dialog follows the platform lifecycle" {
    reset();
    try std.testing.expectEqual(errno.ok, errorDialogInitialize());
    try std.testing.expectEqual(error_dialog_error_already_initialized, errorDialogInitialize());
    var parameter: [16]u8 = @splat(0);
    std.mem.writeInt(i32, parameter[0..4], 16, .little);
    try std.testing.expectEqual(errno.ok, errorDialogOpen(&parameter));
    try std.testing.expectEqual(status_finished, errorDialogUpdateStatus());
    try std.testing.expectEqual(status_finished, errorDialogGetStatus());
    try std.testing.expectEqual(error_dialog_error_invalid_state, errorDialogClose());
    try std.testing.expectEqual(errno.ok, errorDialogTerminate());
    try std.testing.expectEqual(error_dialog_error_not_initialized, errorDialogTerminate());
}

test "dialog libraries register the title import surface" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("FraP7debcdg", .function) != null);
    try std.testing.expect(db.findById("6fIC3XKt2k0", .function) != null);
    try std.testing.expect(db.findById("x01jxu+vxlc", .function) != null);
    try std.testing.expect(db.findById("-4GCfYdNF1s", .function) != null);
    try std.testing.expect(db.findById("UtXl-tmi7iw", .function) != null);
    try std.testing.expect(db.findById("wx9TDplJKB4", .function) != null);
    try std.testing.expect(db.findById("nqG7rqnYw1U", .function) != null);
}

test "the keyboard panel covers nothing and refuses a bad destination" {
    var width: u32 = 0xdead;
    var height: u32 = 0xbeef;
    try std.testing.expectEqual(errno.ok, imeDialogGetPanelSizeExtended(null, null, &width, &height));
    try std.testing.expectEqual(@as(u32, 0), width);
    try std.testing.expectEqual(@as(u32, 0), height);

    // A missing destination is refused rather than written past.
    try std.testing.expectEqual(
        ime_error_invalid_address,
        imeDialogGetPanelSizeExtended(null, null, null, &height),
    );
    try std.testing.expectEqual(
        ime_error_invalid_address,
        imeDialogGetPanelSizeExtended(null, null, &width, null),
    );
}

test "the text-entry session opens, closes and covers no screen" {
    var width: u32 = 0xdead;
    var height: u32 = 0xbeef;
    try std.testing.expectEqual(errno.ok, imeGetPanelSize(null, &width, &height));
    try std.testing.expectEqual(@as(u32, 0), width);
    try std.testing.expectEqual(@as(u32, 0), height);
    try std.testing.expectEqual(errno.ok, imeDialogGetPanelSize(null, &width, &height));
    try std.testing.expectEqual(ime_error_invalid_address, imeGetPanelSize(null, null, &height));

    var form: [ime_position_and_form_bytes]u8 = @splat(0xcc);
    try std.testing.expectEqual(errno.ok, imeDialogGetPanelPositionAndForm(&form));
    for (form) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(ime_error_invalid_address, imeDialogGetPanelPositionAndForm(null));

    // A parameter block is blanked in full, so a title reads its own fields
    // and not whatever the memory held before.
    var param: [ime_param_bytes]u8 = @splat(0xa5);
    imeParamInit(&param);
    for (param) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    try std.testing.expectEqual(errno.ok, imeOpen(null, null));
    try std.testing.expectEqual(@as(u32, 1), ime_session_open.load(.acquire));
    try std.testing.expectEqual(errno.ok, imeSetText(null, 0));
    try std.testing.expectEqual(errno.ok, imeSetCaret(null));
    try std.testing.expectEqual(errno.ok, imeSetTextGeometry(0, null));
    try std.testing.expectEqual(errno.ok, imeKeyboardSetMode(0, 0));
    try std.testing.expectEqual(errno.ok, imeClose());
    try std.testing.expectEqual(@as(u32, 0), ime_session_open.load(.acquire));
}
