// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! RenderDoc frame capture for any title's GPU debugging.
//!
//! RenderDoc is an optional diagnostic: its native library is opened at runtime
//! only when `PS5_RENDERDOC_FLIPS` names flips to capture (`"2"` or `"1-2"`).
//! Nothing is linked, nothing runs without the variable, and the render path
//! never calls here on a hot path — only flip boundaries do.
//!
//! Layout of Api mirrors renderdoc_app.h (RENDERDOC_API_1_7_0); field order is
//! ABI, so a comptime offset check pins StartFrameCapture below.

const std = @import("std");
const builtin = @import("builtin");

pub const library_name = if (builtin.os.tag == .windows) "renderdoc.dll" else "librenderdoc.so";
pub const api_version_1_6_0: c_int = 10600;

const WindowsLibrary = struct {
    handle: *anyopaque,
    extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*const anyopaque;

    fn open(name: [:0]const u8) !WindowsLibrary {
        return .{ .handle = LoadLibraryA(name) orelse return error.FileNotFound };
    }
    fn close(self: *WindowsLibrary) void {
        _ = FreeLibrary(self.handle);
    }
    fn lookup(self: *WindowsLibrary, comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(GetProcAddress(self.handle, name) orelse return null);
    }
};
const NativeLibrary = if (builtin.os.tag == .windows) WindowsLibrary else std.DynLib;

extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "kernel32" fn SetEnvironmentVariableA([*:0]const u8, ?[*:0]const u8) callconv(.winapi) i32;

/// Enable the implicit layer before Vulkan instance creation.
pub fn prepareEnvironment() bool {
    if (comptime builtin.os.tag == .windows) {
        return SetEnvironmentVariableA("ENABLE_VULKAN_RENDERDOC_CAPTURE", "1") != 0;
    } else if (comptime builtin.os.tag == .linux) {
        return setenv("ENABLE_VULKAN_RENDERDOC_CAPTURE", "1", 1) == 0;
    } else return false;
}

/// RenderDoc expects the first dispatch-table pointer in the VkInstance,
/// not the handle value itself (RENDERDOC_DEVICEPOINTER_FROM_VKINSTANCE).
pub fn vulkanDevice(instance: *anyopaque) ?*anyopaque {
    return @as(*const ?*anyopaque, @ptrCast(@alignCast(instance))).*;
}

const DevicePointer = ?*anyopaque;
const WindowHandle = ?*anyopaque;

const Api = extern struct {
    GetAPIVersion: *const fn (major: ?*c_int, minor: ?*c_int, patch: ?*c_int) callconv(.c) void,
    SetCaptureOptionU32: *const fn (option: c_int, value: u32) callconv(.c) c_int,
    SetCaptureOptionF32: *const fn (option: c_int, value: f32) callconv(.c) c_int,
    GetCaptureOptionU32: *const fn (option: c_int) callconv(.c) u32,
    GetCaptureOptionF32: *const fn (option: c_int) callconv(.c) f32,
    SetFocusToggleKeys: *const fn (keys: ?[*]const c_int, count: c_int) callconv(.c) void,
    SetCaptureKeys: *const fn (keys: ?[*]const c_int, count: c_int) callconv(.c) void,
    GetOverlayBits: *const fn () callconv(.c) u32,
    MaskOverlayBits: *const fn (and_mask: u32, or_mask: u32) callconv(.c) void,
    RemoveHooks: *const fn () callconv(.c) void,
    UnloadCrashHandler: *const fn () callconv(.c) void,
    SetCaptureFilePathTemplate: *const fn (template: ?[*:0]const u8) callconv(.c) void,
    GetCaptureFilePathTemplate: *const fn () callconv(.c) ?[*:0]const u8,
    GetNumCaptures: *const fn () callconv(.c) u32,
    GetCapture: *const fn (index: u32, filename: ?[*]u8, path_length: ?*u32, timestamp: ?*u64) callconv(.c) u32,
    TriggerCapture: *const fn () callconv(.c) void,
    IsTargetControlConnected: *const fn () callconv(.c) u32,
    LaunchReplayUI: *const fn (connect: u32, cmdline: ?[*:0]const u8) callconv(.c) u32,
    SetActiveWindow: *const fn (device: DevicePointer, window: WindowHandle) callconv(.c) void,
    StartFrameCapture: *const fn (device: DevicePointer, window: WindowHandle) callconv(.c) void,
    IsFrameCapturing: *const fn () callconv(.c) u32,
    EndFrameCapture: *const fn (device: DevicePointer, window: WindowHandle) callconv(.c) u32,
    TriggerMultiFrameCapture: *const fn (count: u32) callconv(.c) void,
    SetCaptureFileComments: *const fn (path: ?[*:0]const u8, comments: ?[*:0]const u8) callconv(.c) void,
    DiscardFrameCapture: *const fn (device: DevicePointer, window: WindowHandle) callconv(.c) u32,
    ShowReplayUI: *const fn () callconv(.c) u32,
    SetCaptureTitle: *const fn (title: ?[*:0]const u8) callconv(.c) void,
    SetObjectAnnotation: *const fn (device: DevicePointer, object: ?*anyopaque, key: ?[*:0]const u8, value_type: c_int, width: u32, value: ?*const anyopaque) callconv(.c) u32,
    SetCommandAnnotation: *const fn (device: DevicePointer, queue_or_command_buffer: ?*anyopaque, key: ?[*:0]const u8, value_type: c_int, width: u32, value: ?*const anyopaque) callconv(.c) u32,

    comptime {
        // renderdoc_app.h appends; StartFrameCapture is the 20th pointer.
        if (@offsetOf(Api, "StartFrameCapture") != 19 * @sizeOf(*const fn () callconv(.c) void)) @compileError("RenderDoc API layout drifted");
    }
};

pub const Range = struct { first: u64, last: u64 };

/// Parses `"2"` or `"1-2"` flip ranges. Null on garbage, zero, or inversion.
pub fn parseRange(text: []const u8) ?Range {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash| {
        const first = std.fmt.parseInt(u64, trimmed[0..dash], 10) catch return null;
        const last = std.fmt.parseInt(u64, trimmed[dash + 1 ..], 10) catch return null;
        if (first == 0 or last < first) return null;
        return .{ .first = first, .last = last };
    }
    const single = std.fmt.parseInt(u64, trimmed, 10) catch return null;
    if (single == 0) return null;
    return .{ .first = single, .last = single };
}

var library: ?NativeLibrary = null;
var api: ?*const Api = null;
var armed_first: u64 = 0;
var armed_last: u64 = 0;
var capturing = false;

/// Opens the library and arms [first, last]. False keeps everything disabled.
pub fn arm(first: u64, last: u64) bool {
    if (first == 0 or last < first or capturing) return false;
    if (api != null) {
        armed_first = first;
        armed_last = last;
        return true;
    }
    var opened = NativeLibrary.open(library_name) catch |err| {
        std.debug.print("[renderdoc] cannot open {s}: {s}\n", .{ library_name, @errorName(err) });
        return false;
    };
    const get_api = opened.lookup(*const fn (version: c_int, out: *?*const Api) callconv(.c) c_int, "RENDERDOC_GetAPI") orelse {
        std.debug.print("[renderdoc] RENDERDOC_GetAPI missing in {s}\n", .{library_name});
        opened.close();
        return false;
    };
    var table: ?*const Api = null;
    if (get_api(api_version_1_6_0, &table) == 0 or table == null) {
        std.debug.print("[renderdoc] API 1.6.0 not returned by {s}\n", .{library_name});
        opened.close();
        return false;
    }
    library = opened;
    api = table;
    armed_first = first;
    armed_last = last;
    return true;
}

/// Start before recording work for a selected frame. At renderer startup this
/// is frame 1; subsequent frames start after the previous flip completes.
pub fn beginFrame(device_dispatch_table: ?*anyopaque, flip: u64) void {
    const table = api orelse return;
    if (!capturing and flip == armed_first) {
        std.debug.print("[renderdoc] starting capture at flip {d} (device=0x{x})\n", .{ flip, @intFromPtr(device_dispatch_table) });
        table.SetCaptureFilePathTemplate("ps5pcem_renderdoc");
        table.StartFrameCapture(device_dispatch_table, null);
        capturing = table.IsFrameCapturing() != 0;
        if (capturing) std.debug.print("[renderdoc] capturing from flip {d}\n", .{flip});
    }
}

/// Called after presentation, outside any inner scope's defer. Ending and
/// starting are separate phases so a one-frame range includes actual work.
pub fn afterFlip(device_dispatch_table: ?*anyopaque, flip: u64) void {
    const table = api orelse return;
    if (capturing and flip == armed_last) {
        const saved = table.EndFrameCapture(device_dispatch_table, null);
        capturing = false;
        std.debug.print("[renderdoc] capture ended at flip {d}: {s}\n", .{ flip, if (saved != 0) "saved" else "failed" });
    }
    if (flip != std.math.maxInt(u64)) beginFrame(device_dispatch_table, flip + 1);
}

pub fn disarm(device_dispatch_table: ?*anyopaque) void {
    if (api) |table| {
        if (capturing) _ = table.DiscardFrameCapture(device_dispatch_table, null);
    }
    capturing = false;
    armed_first = 0;
    armed_last = 0;
}

test "RenderDoc flip ranges parse single, span, and garbage" {
    try std.testing.expectEqual(Range{ .first = 2, .last = 2 }, parseRange("2").?);
    try std.testing.expectEqual(Range{ .first = 1, .last = 3 }, parseRange("1-3").?);
    try std.testing.expect(parseRange("") == null);
    try std.testing.expect(parseRange("0") == null);
    try std.testing.expect(parseRange("3-1") == null);
    try std.testing.expect(parseRange("x") == null);
}

test {
    _ = Api;
}

test "capture boundaries include one frame or an inclusive range and can rearm" {
    const Fake = struct {
        var active: bool = false;
        var starts: usize = 0;
        var ends: usize = 0;
        var discards: usize = 0;
        fn path(_: ?[*:0]const u8) callconv(.c) void {}
        fn start(_: DevicePointer, _: WindowHandle) callconv(.c) void {
            active = true;
            starts += 1;
        }
        fn isActive() callconv(.c) u32 {
            return @intFromBool(active);
        }
        fn end(_: DevicePointer, _: WindowHandle) callconv(.c) u32 {
            active = false;
            ends += 1;
            return 1;
        }
        fn discard(_: DevicePointer, _: WindowHandle) callconv(.c) u32 {
            active = false;
            discards += 1;
            return 1;
        }
    };
    var callbacks: Api = undefined;
    callbacks.SetCaptureFilePathTemplate = Fake.path;
    callbacks.StartFrameCapture = Fake.start;
    callbacks.IsFrameCapturing = Fake.isActive;
    callbacks.EndFrameCapture = Fake.end;
    callbacks.DiscardFrameCapture = Fake.discard;
    api = &callbacks;
    defer {
        disarm(null);
        api = null;
    }
    Fake.active = false;
    Fake.starts = 0;
    Fake.ends = 0;
    Fake.discards = 0;
    for ([_]Range{ .{ .first = 1, .last = 1 }, .{ .first = 2, .last = 2 }, .{ .first = 2, .last = 4 } }) |range| {
        try std.testing.expect(arm(range.first, range.last));
        beginFrame(null, 1);
        for (1..6) |flip| {
            // This is where scene commands and presentation execute.
            try std.testing.expectEqual(flip >= range.first and flip <= range.last, Fake.active);
            afterFlip(null, flip);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), Fake.starts);
    try std.testing.expectEqual(@as(usize, 3), Fake.ends);
    try std.testing.expect(arm(1, 2));
    beginFrame(null, 1);
    disarm(null);
    try std.testing.expect(!Fake.active);
    try std.testing.expectEqual(@as(usize, 1), Fake.discards);
}

test "Vulkan capture device is the instance dispatch table" {
    var dispatch: usize = 42;
    var instance: ?*anyopaque = &dispatch;
    try std.testing.expectEqual(@as(?*anyopaque, &dispatch), vulkanDevice(@ptrCast(&instance)));
}
