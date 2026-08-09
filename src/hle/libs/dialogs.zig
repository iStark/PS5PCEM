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
var keyboard_open: std.atomic.Value(u8) = .init(0);

pub fn reset() void {
    message_status.store(status_none, .release);
    message_mode.store(0, .release);
    browser_status.store(status_none, .release);
    ime_dialog_status.store(status_none, .release);
    signin_dialog_status.store(status_none, .release);
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

fn signinDialogTerminate() callconv(abi.guest) i32 {
    signin_dialog_status.store(status_none, .release);
    return errno.ok;
}

const signin_dialog_exports = [_]symbols.Export{
    .{ .name = "sceSigninDialogUpdateStatus", .function = trace.wrap("sceSigninDialogUpdateStatus", &signinDialogUpdateStatus), .expect_id = "Bw31liTFT3A" },
    .{ .name = "sceSigninDialogInitialize", .function = trace.wrap("sceSigninDialogInitialize", &signinDialogInitialize), .expect_id = "mlYGfmqE3fQ" },
    .{ .name = "sceSigninDialogOpen", .function = trace.wrap("sceSigninDialogOpen", &signinDialogOpen), .expect_id = "JlpJVoRWv7U" },
    .{ .name = "sceSigninDialogTerminate", .function = trace.wrap("sceSigninDialogTerminate", &signinDialogTerminate), .expect_id = "LXlmS6PvJdU" },
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
};

const ime_exports = [_]symbols.Export{
    .{ .name = "sceImeKeyboardOpen", .function = trace.wrap("sceImeKeyboardOpen", &keyboardOpenFn), .expect_id = "eaFXjfJv3xs" },
    .{ .name = "sceImeKeyboardClose", .function = trace.wrap("sceImeKeyboardClose", &keyboardClose), .expect_id = "PMVehSlfZ94" },
    .{ .name = "sceImeKeyboardGetResourceId", .function = trace.wrap("sceImeKeyboardGetResourceId", &keyboardGetResourceId), .expect_id = "dKadqZFgKKQ" },
    .{ .name = "sceImeKeyboardGetInfo", .function = trace.wrap("sceImeKeyboardGetInfo", &keyboardGetInfo), .expect_id = "VkqLPArfFdc" },
    .{ .name = "sceImeUpdate", .function = trace.wrap("sceImeUpdate", &imeUpdate), .expect_id = "-4GCfYdNF1s" },
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libSceCommonDialog" }, .{ .name = "libSceCommonDialog" }, &common_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceMsgDialog.native" }, .{ .name = "libSceMsgDialog" }, &message_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceWebBrowserDialog" }, .{ .name = "libSceWebBrowserDialog" }, &browser_dialog_exports);
    try db.addLibrary(gpa, .{ .name = "libSceSigninDialog" }, .{ .name = "libSceSigninDialog" }, &signin_dialog_exports);
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

test "dialog libraries register the title import surface" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("FraP7debcdg", .function) != null);
    try std.testing.expect(db.findById("6fIC3XKt2k0", .function) != null);
    try std.testing.expect(db.findById("x01jxu+vxlc", .function) != null);
    try std.testing.expect(db.findById("-4GCfYdNF1s", .function) != null);
}
