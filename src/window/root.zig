// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Minimal host window boundary for live frame presentation.
//!
//! Win32 owns windows and their message queues per thread. The emulator may
//! submit a flip from any guest pthread, so the HWND is created and pumped by a
//! dedicated host thread while Vulkan presentation remains serialized by the
//! GPU submission layer.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    UnsupportedPlatform,
    ThreadCreationFailed,
    WindowCreationFailed,
};

pub const NativeHandle = struct {
    instance: *anyopaque,
    window: *anyopaque,
    width: u32,
    height: u32,
};

const status_starting: u8 = 0;
const status_open: u8 = 1;
const status_failed: u8 = 2;
const status_closed: u8 = 3;

const Extent = struct { width: u32, height: u32 };

fn fitClientExtent(width: u32, height: u32, available_width: u32, available_height: u32) Extent {
    var result = Extent{ .width = width, .height = height };
    if (result.width > available_width) {
        result.height = @intCast(@max(1, @as(u64, height) * available_width / width));
        result.width = available_width;
    }
    if (result.height > available_height) {
        result.width = @intCast(@max(1, @as(u64, width) * available_height / height));
        result.height = available_height;
    }
    return result;
}

pub const HostWindow = struct {
    thread: ?std.Thread = null,
    status: std.atomic.Value(u8) = .init(status_closed),
    instance: std.atomic.Value(usize) = .init(0),
    window: std.atomic.Value(usize) = .init(0),
    width: u32 = 1280,
    height: u32 = 720,

    pub fn init(self: *HostWindow, width: u32, height: u32) Error!void {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        if (width == 0 or height == 0) return error.WindowCreationFailed;
        self.* = .{
            .status = .init(status_starting),
            .instance = .init(0),
            .window = .init(0),
            .width = width,
            .height = height,
        };
        self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch
            return error.ThreadCreationFailed;
        while (self.status.load(.acquire) == status_starting) {
            std.Thread.yield() catch {};
        }
        if (self.status.load(.acquire) != status_open) {
            self.thread.?.join();
            self.thread = null;
            return error.WindowCreationFailed;
        }
    }

    pub fn deinit(self: *HostWindow) void {
        if (self.thread == null) return;
        self.requestClose();
        self.thread.?.join();
        self.* = .{};
    }

    pub fn isOpen(self: *const HostWindow) bool {
        return self.status.load(.acquire) == status_open and self.window.load(.acquire) != 0;
    }

    pub fn nativeHandle(self: *const HostWindow) ?NativeHandle {
        if (!self.isOpen()) return null;
        const instance_value = self.instance.load(.acquire);
        const window_value = self.window.load(.acquire);
        if (instance_value == 0 or window_value == 0) return null;
        return .{
            .instance = @ptrFromInt(instance_value),
            .window = @ptrFromInt(window_value),
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn requestClose(self: *HostWindow) void {
        if (builtin.os.tag != .windows) return;
        const value = self.window.load(.acquire);
        if (value != 0) _ = Win32.PostMessageA(@ptrFromInt(value), Win32.wm_close, 0, 0);
    }

    /// Updates the native title at the renderer's low-frequency sampling rate.
    /// SetWindowText is safe across threads within the same process and avoids
    /// touching the Vulkan client area or adding work to every presented frame.
    pub fn updateFps(self: *HostWindow, fps_tenths: u32) void {
        if (builtin.os.tag != .windows) return;
        const value = self.window.load(.acquire);
        if (value == 0) return;
        var title: [96]u8 = undefined;
        const title_z = std.fmt.bufPrintZ(
            &title,
            "PS5PCEM - Vulkan guest output - {d}.{d} FPS",
            .{ fps_tenths / 10, fps_tenths % 10 },
        ) catch return;
        _ = Win32.SetWindowTextA(@ptrFromInt(value), title_z.ptr);
    }

    fn threadMain(self: *HostWindow) void {
        if (builtin.os.tag != .windows) {
            self.status.store(status_failed, .release);
            return;
        }
        const instance = Win32.GetModuleHandleA(null) orelse {
            self.status.store(status_failed, .release);
            return;
        };
        const class = Win32.WndClassExA{
            .size = @sizeOf(Win32.WndClassExA),
            .style = Win32.class_redraw,
            .window_procedure = windowProcedure,
            .class_extra = 0,
            .window_extra = 0,
            .instance = instance,
            .icon = null,
            .cursor = Win32.LoadCursorA(null, Win32.arrow_cursor),
            .background = null,
            .menu_name = null,
            .class_name = Win32.class_name,
            .small_icon = null,
        };
        if (Win32.RegisterClassExA(&class) == 0 and Win32.GetLastError() != Win32.error_class_already_exists) {
            self.status.store(status_failed, .release);
            return;
        }
        // Fit the requested client area to the desktop without changing the
        // display profile exposed to the guest or resizing its render targets.
        var border = Win32.Rect{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = Win32.AdjustWindowRect(&border, Win32.window_style, 0);
        const border_width = border.right - border.left;
        const border_height = border.bottom - border.top;
        var work_area: Win32.Rect = undefined;
        var x = Win32.use_default;
        var y = Win32.use_default;
        if (Win32.SystemParametersInfoA(0x0030, 0, &work_area, 0) != 0) {
            const fitted = fitClientExtent(self.width, self.height, @intCast(@max(1, work_area.right - work_area.left - border_width)), @intCast(@max(1, work_area.bottom - work_area.top - border_height)));
            self.width = fitted.width;
            self.height = fitted.height;
            x = work_area.left + @divTrunc(work_area.right - work_area.left - @as(i32, @intCast(self.width)) - border_width, 2);
            y = work_area.top + @divTrunc(work_area.bottom - work_area.top - @as(i32, @intCast(self.height)) - border_height, 2);
        }
        const window = Win32.CreateWindowExA(
            0,
            Win32.class_name,
            "PS5PCEM - Vulkan guest output",
            Win32.window_style,
            x,
            y,
            @as(i32, @intCast(self.width)) + border_width,
            @as(i32, @intCast(self.height)) + border_height,
            null,
            null,
            instance,
            null,
        ) orelse {
            self.status.store(status_failed, .release);
            return;
        };
        var client: Win32.Rect = undefined;
        if (Win32.GetClientRect(window, &client) != 0) {
            self.width = @intCast(client.right - client.left);
            self.height = @intCast(client.bottom - client.top);
        }
        self.instance.store(@intFromPtr(instance), .release);
        self.window.store(@intFromPtr(window), .release);
        self.status.store(status_open, .release);
        _ = Win32.ShowWindow(window, Win32.show_normal);
        _ = Win32.UpdateWindow(window);

        var message: Win32.Message = undefined;
        while (Win32.GetMessageA(&message, null, 0, 0) > 0) {
            _ = Win32.TranslateMessage(&message);
            _ = Win32.DispatchMessageA(&message);
        }
        self.window.store(0, .release);
        self.status.store(status_closed, .release);
    }

    fn windowProcedure(
        window: ?*anyopaque,
        message: u32,
        word_parameter: usize,
        long_parameter: isize,
    ) callconv(.winapi) isize {
        switch (message) {
            Win32.wm_close => {
                _ = Win32.DestroyWindow(window);
                return 0;
            },
            Win32.wm_destroy => {
                Win32.PostQuitMessage(0);
                return 0;
            },
            else => return Win32.DefWindowProcA(window, message, word_parameter, long_parameter),
        }
    }
};

const Win32 = if (builtin.os.tag == .windows) struct {
    const Window = ?*anyopaque;
    const Instance = ?*anyopaque;
    const Icon = ?*anyopaque;
    const Cursor = ?*anyopaque;
    const Brush = ?*anyopaque;
    const Menu = ?*anyopaque;

    const Point = extern struct { x: i32, y: i32 };
    const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
    const Message = extern struct {
        window: Window,
        message: u32,
        word_parameter: usize,
        long_parameter: isize,
        time: u32,
        point: Point,
        private: u32,
    };
    const WindowProcedure = *const fn (Window, u32, usize, isize) callconv(.winapi) isize;
    const WndClassExA = extern struct {
        size: u32,
        style: u32,
        window_procedure: WindowProcedure,
        class_extra: i32,
        window_extra: i32,
        instance: Instance,
        icon: Icon,
        cursor: Cursor,
        background: Brush,
        menu_name: ?[*:0]const u8,
        class_name: [*:0]const u8,
        small_icon: Icon,
    };

    const class_name: [*:0]const u8 = "PS5PCEM_VULKAN_WINDOW";
    const class_redraw: u32 = 0x0001 | 0x0002;
    const window_style: u32 = 0x00c0_0000 | 0x0008_0000 | 0x0002_0000;
    const use_default: i32 = @bitCast(@as(u32, 0x8000_0000));
    const show_normal: i32 = 5;
    const wm_destroy: u32 = 0x0002;
    const wm_close: u32 = 0x0010;
    const arrow_cursor: [*:0]const u8 = @ptrFromInt(32512);
    const error_class_already_exists: u32 = 1410;

    extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) Instance;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "user32" fn RegisterClassExA(class: *const WndClassExA) callconv(.winapi) u16;
    extern "user32" fn AdjustWindowRect(*Rect, u32, i32) callconv(.winapi) i32;
    extern "user32" fn GetClientRect(Window, *Rect) callconv(.winapi) i32;
    extern "user32" fn SystemParametersInfoA(u32, u32, ?*anyopaque, u32) callconv(.winapi) i32;
    extern "user32" fn CreateWindowExA(
        extended_style: u32,
        class_name: [*:0]const u8,
        window_name: [*:0]const u8,
        style: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: Window,
        menu: Menu,
        instance: Instance,
        parameter: ?*anyopaque,
    ) callconv(.winapi) Window;
    extern "user32" fn DefWindowProcA(Window, u32, usize, isize) callconv(.winapi) isize;
    extern "user32" fn DestroyWindow(Window) callconv(.winapi) i32;
    extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
    extern "user32" fn PostMessageA(Window, u32, usize, isize) callconv(.winapi) i32;
    extern "user32" fn ShowWindow(Window, i32) callconv(.winapi) i32;
    extern "user32" fn UpdateWindow(Window) callconv(.winapi) i32;
    extern "user32" fn SetWindowTextA(Window, [*:0]const u8) callconv(.winapi) i32;
    extern "user32" fn GetMessageA(*Message, Window, u32, u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(*const Message) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageA(*const Message) callconv(.winapi) isize;
    extern "user32" fn LoadCursorA(Instance, [*:0]const u8) callconv(.winapi) Cursor;
} else struct {};

test "native handle is unavailable before window creation" {
    const window = HostWindow{};
    try std.testing.expect(window.nativeHandle() == null);
}

test "large output windows fit the desktop while preserving the aspect ratio" {
    try std.testing.expectEqual(Extent{ .width = 1920, .height = 1080 }, fitClientExtent(1920, 1080, 2500, 1400));
    try std.testing.expectEqual(Extent{ .width = 1920, .height = 1080 }, fitClientExtent(7680, 4320, 1920, 1200));
    try std.testing.expectEqual(Extent{ .width = 1280, .height = 720 }, fitClientExtent(3840, 2160, 1900, 720));
}
