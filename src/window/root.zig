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
const input = @import("input");

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
    renderer_label: []const u8 = "Vulkan",
    /// Set by `requestClose` on Linux; the X11 event thread polls it.
    close_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(self: *HostWindow, width: u32, height: u32) Error!void {
        return self.initWithRenderer(width, height, "Vulkan");
    }

    /// The label must outlive the window thread (normally a static API name).
    pub fn initWithRenderer(self: *HostWindow, width: u32, height: u32, renderer_label: []const u8) Error!void {
        if (builtin.os.tag != .windows and builtin.os.tag != .linux) return error.UnsupportedPlatform;
        if (width == 0 or height == 0) return error.WindowCreationFailed;
        self.* = .{
            .status = .init(status_starting),
            .instance = .init(0),
            .window = .init(0),
            .width = width,
            .height = height,
            .renderer_label = renderer_label,
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
        var title: [96]u8 = undefined;
        const title_z = std.fmt.bufPrintZ(&title, "PS5PCEM - {s} guest output", .{self.renderer_label}) catch return;
        self.setTitle(title_z);
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
        if (builtin.os.tag == .linux) {
            self.close_requested.store(true, .release);
            return;
        }
        if (builtin.os.tag != .windows) return;
        const value = self.window.load(.acquire);
        if (value != 0) _ = Win32.PostMessageA(@ptrFromInt(value), Win32.wm_close, 0, 0);
    }

    /// Updates the native title at the renderer's low-frequency sampling rate.
    /// SetWindowText is safe across threads within the same process and avoids
    /// touching the rendered client area or adding work to every presented frame.
    pub fn updateFps(self: *HostWindow, fps_tenths: u32) void {
        if (builtin.os.tag != .windows and builtin.os.tag != .linux) return;
        var title: [96]u8 = undefined;
        const title_z = std.fmt.bufPrintZ(
            &title,
            "PS5PCEM - {s} guest output - {d}.{d} FPS",
            .{ self.renderer_label, fps_tenths / 10, fps_tenths % 10 },
        ) catch return;
        self.setTitle(title_z);
    }

    fn setTitle(self: *HostWindow, title_z: [:0]const u8) void {
        const value = self.window.load(.acquire);
        if (value == 0) return;
        if (builtin.os.tag == .linux) {
            // Xlib was initialised for threads, so the title can be set from
            // the renderer's thread like SetWindowText on Windows.
            const display = self.instance.load(.acquire);
            if (display == 0) return;
            _ = X11.functions.store_name(@ptrFromInt(display), value, title_z.ptr);
            _ = X11.functions.flush(@ptrFromInt(display));
            return;
        }
        _ = Win32.SetWindowTextA(@ptrFromInt(value), title_z.ptr);
    }

    fn threadMain(self: *HostWindow) void {
        if (builtin.os.tag == .linux) return X11.threadMain(self);
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
            Win32.wm_keydown, Win32.wm_syskeydown => {
                // Preserve a tap even if key-up arrives before the guest's
                // next controller poll. Auto-repeat is not a new press.
                if (long_parameter & (1 << 30) == 0) input.noteKeyPress(word_parameter);
            },
            Win32.wm_killfocus => input.clearKeyboardPresses(),
            Win32.wm_close => {
                _ = Win32.DestroyWindow(window);
                return 0;
            },
            Win32.wm_destroy => {
                input.clearKeyboardPresses();
                Win32.PostQuitMessage(0);
                return 0;
            },
            else => {},
        }
        return Win32.DefWindowProcA(window, message, word_parameter, long_parameter);
    }
};

/// The Linux window: X11 through Xlib, loaded at run time.
///
/// X11 rather than Wayland because it is present on every Linux desktop,
/// Wayland ones included through XWayland, and every Vulkan driver offers
/// VK_KHR_xlib_surface. Loading libX11 dynamically keeps the runner free of a
/// link-time dependency: without it the runner still starts, headless.
///
/// The native handle carries the Display pointer as `instance` and the window
/// XID as `window`, the two values vkCreateXlibSurfaceKHR needs.
const X11 = struct {
    const Display = opaque {};
    const XWindow = u64;
    const Atom = u64;

    /// XEvent is a union of at most 24 longs.
    const Event = extern union {
        type: i32,
        key: extern struct {
            type: i32,
            serial: u64,
            send_event: i32,
            display: ?*Display,
            window: XWindow,
            root: XWindow,
            subwindow: XWindow,
            time: u64,
            x: i32,
            y: i32,
            x_root: i32,
            y_root: i32,
            state: u32,
            keycode: u32,
            same_screen: i32,
        },
        client: extern struct {
            type: i32,
            serial: u64,
            send_event: i32,
            display: ?*Display,
            window: XWindow,
            message_type: Atom,
            format: i32,
            data: [5]u64,
        },
        padding: [24]u64,
    };

    const key_press: i32 = 2;
    const key_release: i32 = 3;
    const focus_in: i32 = 9;
    const focus_out: i32 = 10;
    const client_message: i32 = 33;
    const key_press_mask: i64 = 1 << 0;
    const key_release_mask: i64 = 1 << 1;
    const structure_notify_mask: i64 = 1 << 17;
    const focus_change_mask: i64 = 1 << 21;

    const Functions = struct {
        init_threads: *const fn () callconv(.c) i32,
        open_display: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
        close_display: *const fn (*Display) callconv(.c) i32,
        default_screen: *const fn (*Display) callconv(.c) i32,
        root_window: *const fn (*Display, i32) callconv(.c) XWindow,
        black_pixel: *const fn (*Display, i32) callconv(.c) u64,
        display_width: *const fn (*Display, i32) callconv(.c) i32,
        display_height: *const fn (*Display, i32) callconv(.c) i32,
        create_simple_window: *const fn (*Display, XWindow, i32, i32, u32, u32, u32, u64, u64) callconv(.c) XWindow,
        destroy_window: *const fn (*Display, XWindow) callconv(.c) i32,
        store_name: *const fn (*Display, XWindow, [*:0]const u8) callconv(.c) i32,
        select_input: *const fn (*Display, XWindow, i64) callconv(.c) i32,
        intern_atom: *const fn (*Display, [*:0]const u8, i32) callconv(.c) Atom,
        set_wm_protocols: *const fn (*Display, XWindow, [*]Atom, i32) callconv(.c) i32,
        map_window: *const fn (*Display, XWindow) callconv(.c) i32,
        flush: *const fn (*Display) callconv(.c) i32,
        pending: *const fn (*Display) callconv(.c) i32,
        next_event: *const fn (*Display, *Event) callconv(.c) i32,
        lookup_keysym: *const fn (*Event, i32) callconv(.c) u64,
        detectable_auto_repeat: *const fn (*Display, i32, ?*i32) callconv(.c) i32,
    };

    var library: ?std.DynLib = null;
    var functions: Functions = undefined;

    fn load() bool {
        if (library != null) return true;
        var opened = std.DynLib.open("libX11.so.6") catch return false;
        inline for (.{
            .{ "init_threads", "XInitThreads" },
            .{ "open_display", "XOpenDisplay" },
            .{ "close_display", "XCloseDisplay" },
            .{ "default_screen", "XDefaultScreen" },
            .{ "root_window", "XRootWindow" },
            .{ "black_pixel", "XBlackPixel" },
            .{ "display_width", "XDisplayWidth" },
            .{ "display_height", "XDisplayHeight" },
            .{ "create_simple_window", "XCreateSimpleWindow" },
            .{ "destroy_window", "XDestroyWindow" },
            .{ "store_name", "XStoreName" },
            .{ "select_input", "XSelectInput" },
            .{ "intern_atom", "XInternAtom" },
            .{ "set_wm_protocols", "XSetWMProtocols" },
            .{ "map_window", "XMapWindow" },
            .{ "flush", "XFlush" },
            .{ "pending", "XPending" },
            .{ "next_event", "XNextEvent" },
            .{ "lookup_keysym", "XLookupKeysym" },
            .{ "detectable_auto_repeat", "XkbSetDetectableAutoRepeat" },
        }) |entry| {
            @field(functions, entry[0]) = opened.lookup(@FieldType(Functions, entry[0]), entry[1]) orelse {
                opened.close();
                return false;
            };
        }
        // Vulkan presents from the renderer's thread through the same Display.
        // XInitThreads must precede every other Xlib call to make that safe.
        if (functions.init_threads() == 0) {
            opened.close();
            return false;
        }
        library = opened;
        return true;
    }

    fn threadMain(window: *HostWindow) void {
        if (!load()) return window.status.store(status_failed, .release);
        const display = functions.open_display(null) orelse
            return window.status.store(status_failed, .release);
        const screen = functions.default_screen(display);
        const fitted = fitClientExtent(
            window.width,
            window.height,
            @intCast(@max(1, functions.display_width(display, screen))),
            @intCast(@max(1, functions.display_height(display, screen))),
        );
        window.width = fitted.width;
        window.height = fitted.height;
        const black = functions.black_pixel(display, screen);
        const native = functions.create_simple_window(
            display,
            functions.root_window(display, screen),
            0,
            0,
            window.width,
            window.height,
            0,
            black,
            black,
        );
        if (native == 0) {
            _ = functions.close_display(display);
            return window.status.store(status_failed, .release);
        }
        _ = functions.store_name(display, native, "PS5PCEM - Vulkan guest output");
        _ = functions.select_input(display, native, key_press_mask | key_release_mask | structure_notify_mask | focus_change_mask);
        // Holding a key otherwise arrives as alternating release/press pairs.
        _ = functions.detectable_auto_repeat(display, 1, null);
        var delete_window = functions.intern_atom(display, "WM_DELETE_WINDOW", 0);
        _ = functions.set_wm_protocols(display, native, @ptrCast(&delete_window), 1);
        _ = functions.map_window(display, native);
        _ = functions.flush(display);

        window.instance.store(@intFromPtr(display), .release);
        window.window.store(native, .release);
        window.status.store(status_open, .release);

        var event: Event = undefined;
        while (!window.close_requested.load(.acquire)) {
            if (functions.pending(display) == 0) {
                // Polling keeps a close request from another thread visible
                // without a wake-up event; 8 ms is well below input latency a
                // player would notice and costs nothing measurable.
                sleepMilliseconds(8);
                continue;
            }
            _ = functions.next_event(display, &event);
            switch (event.type) {
                key_press, key_release => {
                    const virtual_key: usize = input.virtualKeyFromKey(functions.lookup_keysym(&event, 0), event.key.keycode) orelse continue;
                    const down = event.type == key_press;
                    input.noteKeyState(virtual_key, down);
                    if (down) input.noteKeyPress(virtual_key);
                },
                focus_in => input.noteKeyboardFocus(true),
                focus_out => input.noteKeyboardFocus(false),
                client_message => if (event.client.data[0] == delete_window) break,
                else => {},
            }
        }
        input.noteKeyboardFocus(false);
        window.window.store(0, .release);
        window.status.store(status_closed, .release);
        // The Display stays open: the renderer's surface and swapchain refer
        // to it until the process ends, and closing it under them would make
        // their next present fail rather than merely stop.
        _ = functions.destroy_window(display, native);
        _ = functions.flush(display);
    }

    fn sleepMilliseconds(milliseconds: u64) void {
        var request = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(milliseconds * std.time.ns_per_ms) };
        _ = std.os.linux.nanosleep(&request, null);
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
    const wm_killfocus: u32 = 0x0008;
    const wm_close: u32 = 0x0010;
    const wm_keydown: u32 = 0x0100;
    const wm_syskeydown: u32 = 0x0104;
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
