// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Native Linux launcher for PS5PCEM.
//!
//! The Linux counterpart of launcher.zig: the same pages, geometry, colours
//! and phrases, drawn through GTK 3, cairo and Pango instead of GDI. Every
//! desktop distribution ships those, and they are opened at run time, so the
//! build needs no development packages, just as game-run needs none for X11 or
//! PulseAudio. Settings use the same ps5pcem.ini keys, and game-run receives
//! the same environment contract as on Windows.

const std = @import("std");
const builtin = @import("builtin");
const input = @import("input");
const build_options = @import("build_options");
const zarchive = @import("zarchive");
const common = @import("launcher_common.zig");
const display_mode = @import("display_mode.zig");
const performance_mode = @import("performance_mode.zig");
const graphics_api = @import("graphics_api.zig");
const frame_limit = @import("frame_limit.zig");

const Language = common.Language;
const language_labels = common.language_labels;
const Phrase = common.Phrase;

test {
    // The shared files' own tests run with each launcher's.
    _ = common;
    _ = frame_limit;
}

/// The branding icon, embedded so the sidebar and the window have it however
/// the launcher was installed.
const app_icon_png = @embedFile("app_icon");

const site_url = "https://ps5pcem.com";
const releases_url = "https://github.com/iStark/PS5PCEM/releases/latest";
const latest_release_url = "https://api.github.com/repos/iStark/PS5PCEM/releases/latest";
const github_url = "https://github.com/iStark/PS5PCEM";
const boosty_url = "https://boosty.to/ps5pcem";
const window_width = 1180;
const window_height = 760;
const sidebar_width = 222;

const Page = enum { library, input, saves, settings };
const InputMode = enum(u8) { controller = 0, keyboard = 1, hybrid = 2 };
const LibraryView = enum(u8) { grid = 0, table = 1 };

const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.left and x < self.right and y >= self.top and y < self.bottom;
    }
};

const mapping_names = [_][]const u8{
    "Cross",   "Circle",    "Square",   "Triangle",    "L1",         "L2",         "R1", "R2",
    "Options", "Touch pad", "D-pad up", "D-pad right", "D-pad down", "D-pad left",
};
const mapping_defaults = [_]u8{ 0x20, 'E', 'F', 'Q', 0x10, 0x11, 'R', 'T', 0x0d, 0x09, 0x26, 0x27, 0x28, 0x25 };

var app_io: std.Io = undefined;
var current_page: Page = .library;
var input_mode: InputMode = .hybrid;
var language: Language = .english;
var controller_index: u8 = 0;
var sound_enabled = true;
var show_fps = false;
var selected_frame_limit = frame_limit.default;
var output_mode = display_mode.default;
var render_preset = performance_mode.default;
var game_performance = true;
var mapping = mapping_defaults;
var capture_mapping: ?usize = null;
var game_folder: [1024]u8 = @splat(0);
var game_folder_length: usize = 0;

/// Six pages of eight, as on Windows.
const maximum_recent_games = 48;
const library_page_size = 8;
var library_view: LibraryView = .grid;
var library_matches: [maximum_recent_games]u8 = undefined;
var library_match_count: usize = 0;
/// UTF-8, as GTK hands it over. 128 characters fit even at four bytes each.
var search_text: [512]u8 = @splat(0);
var search_length: usize = 0;
var search_shown = false;

const RecentGame = struct {
    folder: [1024]u8 = @splat(0),
    folder_length: usize = 0,
    title: [256]u8 = @splat(0),
    title_length: usize = 0,
    identifier: [32]u8 = @splat(0),
    identifier_length: usize = 0,
    /// A GdkPixbuf of the title's icon0.png, owned by this entry.
    icon: ?*anyopaque = null,
};
var recent_games: [maximum_recent_games]RecentGame = @splat(.{});
var recent_game_count: usize = 0;
var hovered_recent_game: ?usize = null;
var hovered_recent_remove = false;
var library_page: usize = 0;
var hovered_library_arrow: ?u1 = null;
/// Smooth scrolling reports fractions of a notch; a page turns per whole one.
var scroll_accumulator: f64 = 0;
var title_identifier: [32]u8 = @splat(0);
var title_identifier_length: usize = 0;

/// A package extraction runs in pkgextractor while the window stays
/// responsive. A reader thread collects its output; the window repaints from
/// a timer, and the thread hands the exit status back through an idle call.
const ExtractState = enum { idle, running, succeeded, failed };
var extract_state: ExtractState = .idle;
var extract_pid: c_int = 0;
var extract_result: Phrase = .extract_running;
var extract_name: [256]u8 = @splat(0);
var extract_name_length: usize = 0;
var extract_output: [1024]u8 = @splat(0);
var extract_output_length: usize = 0;
const extract_log_capacity = 8;
const extract_log_bytes = 200;
const ExtractFeed = struct {
    done: u64 = 0,
    total: u64 = 0,
    log: [extract_log_capacity][extract_log_bytes]u8 = undefined,
    log_lengths: [extract_log_capacity]u8 = @splat(0),
    log_next: usize = 0,
    log_count: usize = 0,
};
var extract_feed: ExtractFeed = .{};
var extract_full_log: std.ArrayList(u8) = .empty;
const extract_full_log_limit = 8 * 1024 * 1024;
var extract_lock: std.atomic.Mutex = .unlocked;
var extract_dirty: std.atomic.Value(bool) = .init(false);
const extract_panel_rect = Rect{ .left = 282, .top = 158, .right = 1086, .bottom = 510 };
const extract_copy_rect = Rect{ .left = 882, .top = 174, .right = 1062, .bottom = 208 };

const UpdateState = enum { idle, checking, latest, available, failed };
var update_state: UpdateState = .idle;
var hovered_update = false;
var update_remote_tag: [32]u8 = undefined;
var update_remote_tag_length: usize = 0;

var status_text: [256]u8 = @splat(0);
var status_length: usize = 0;
var status_error = false;
var ini_path: [1024]u8 = @splat(0);
var ini_path_length: usize = 0;
var vulkan_report: common.VulkanReport = .{};

var main_window: ?*anyopaque = null;
var drawing_area: ?*anyopaque = null;
var search_entry: ?*anyopaque = null;
var brand_icon: ?*anyopaque = null;
var cursors: [3]?*anyopaque = @splat(null);
const Cursor = enum(u2) { arrow, hand, text };
var shown_cursor: Cursor = .arrow;
var fonts: [4]?*anyopaque = @splat(null);
const Font = enum(u2) { regular, medium, title, small };

// ---------------------------------------------------------------------------
// GTK, GDK, GLib, cairo and Pango, opened at run time.

const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]const u8,
};

const EventButton = extern struct {
    type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
    axes: ?*f64,
    state: c_uint,
    button: c_uint,
    device: ?*anyopaque,
    x_root: f64,
    y_root: f64,
};

const EventMotion = extern struct {
    type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
    axes: ?*f64,
    state: c_uint,
    is_hint: i16,
    device: ?*anyopaque,
    x_root: f64,
    y_root: f64,
};

const EventScroll = extern struct {
    type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    x: f64,
    y: f64,
    state: c_uint,
    direction: c_int,
    device: ?*anyopaque,
    x_root: f64,
    y_root: f64,
    delta_x: f64,
    delta_y: f64,
    is_stop: c_uint,
};

const EventKey = extern struct {
    type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    state: c_uint,
    keyval: c_uint,
    length: c_int,
    string: ?[*:0]u8,
    hardware_keycode: u16,
    group: u8,
    is_modifier: c_uint,
};

const gdk_button_press: c_int = 4;
const gdk_control_mask: c_uint = 1 << 2;
const gdk_alt_mask: c_uint = 1 << 3;
const gdk_scroll_up: c_int = 0;
const gdk_scroll_down: c_int = 1;
const gdk_scroll_smooth: c_int = 4;
const gdk_event_masks: c_int = (1 << 2) | (1 << 8) | (1 << 9) | (1 << 13) | (1 << 21) | (1 << 23);
const keyval_escape: c_uint = 0xff1b;
const keyval_return: c_uint = 0xff0d;
const keyval_keypad_enter: c_uint = 0xff8d;
const response_accept: c_int = -3;
const file_chooser_open: c_int = 0;
const file_chooser_select_folder: c_int = 2;
const spawn_do_not_reap_child: c_int = 1 << 1;
const pango_scale = 1024;

const SourceFunction = *const fn (?*anyopaque) callconv(.c) c_int;
const ChildSetup = *const fn (?*anyopaque) callconv(.c) void;
const Argv = [*:null]const ?[*:0]const u8;

/// Every entry point the launcher uses, named as exported. GTK 3 links GDK,
/// GLib, cairo and Pango, so one handle reaches all of them.
const Native = struct {
    g_signal_connect_data: *const fn (*anyopaque, [*:0]const u8, *const anyopaque, ?*anyopaque, ?*const anyopaque, c_int) callconv(.c) c_ulong,
    g_idle_add: *const fn (SourceFunction, ?*anyopaque) callconv(.c) c_uint,
    g_timeout_add: *const fn (c_uint, SourceFunction, ?*anyopaque) callconv(.c) c_uint,
    g_free: *const fn (?*anyopaque) callconv(.c) void,
    g_object_unref: *const fn (*anyopaque) callconv(.c) void,
    g_object_ref: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    g_error_free: *const fn (*GError) callconv(.c) void,
    g_filename_to_uri: *const fn ([*:0]const u8, ?[*:0]const u8, ?*?*GError) callconv(.c) ?[*:0]u8,
    g_utf8_strdown: *const fn ([*]const u8, isize) callconv(.c) ?[*:0]u8,
    g_get_user_config_dir: *const fn () callconv(.c) [*:0]const u8,
    g_get_user_data_dir: *const fn () callconv(.c) [*:0]const u8,
    g_getenv: *const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8,
    g_spawn_async: *const fn (?[*:0]const u8, Argv, ?Argv, c_int, ?ChildSetup, ?*anyopaque, ?*c_int, ?*?*GError) callconv(.c) c_int,
    g_spawn_async_with_pipes: *const fn (?[*:0]const u8, Argv, ?Argv, c_int, ?ChildSetup, ?*anyopaque, ?*c_int, ?*c_int, ?*c_int, ?*c_int, ?*?*GError) callconv(.c) c_int,

    gtk_init_check: *const fn (?*c_int, ?*anyopaque) callconv(.c) c_int,
    gtk_main: *const fn () callconv(.c) void,
    gtk_main_quit: *const fn () callconv(.c) void,
    gtk_window_new: *const fn (c_int) callconv(.c) ?*anyopaque,
    gtk_window_set_title: *const fn (*anyopaque, [*:0]const u8) callconv(.c) void,
    gtk_window_set_default_size: *const fn (*anyopaque, c_int, c_int) callconv(.c) void,
    gtk_window_set_resizable: *const fn (*anyopaque, c_int) callconv(.c) void,
    gtk_window_set_position: *const fn (*anyopaque, c_int) callconv(.c) void,
    gtk_window_set_icon: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void,
    gtk_window_iconify: *const fn (*anyopaque) callconv(.c) void,
    gtk_fixed_new: *const fn () callconv(.c) ?*anyopaque,
    gtk_fixed_put: *const fn (*anyopaque, *anyopaque, c_int, c_int) callconv(.c) void,
    gtk_container_add: *const fn (*anyopaque, *anyopaque) callconv(.c) void,
    gtk_drawing_area_new: *const fn () callconv(.c) ?*anyopaque,
    gtk_widget_set_size_request: *const fn (*anyopaque, c_int, c_int) callconv(.c) void,
    gtk_widget_add_events: *const fn (*anyopaque, c_int) callconv(.c) void,
    gtk_widget_set_can_focus: *const fn (*anyopaque, c_int) callconv(.c) void,
    gtk_widget_grab_focus: *const fn (*anyopaque) callconv(.c) void,
    gtk_widget_has_focus: *const fn (*anyopaque) callconv(.c) c_int,
    gtk_widget_show_all: *const fn (*anyopaque) callconv(.c) void,
    gtk_widget_show: *const fn (*anyopaque) callconv(.c) void,
    gtk_widget_hide: *const fn (*anyopaque) callconv(.c) void,
    gtk_widget_queue_draw: *const fn (*anyopaque) callconv(.c) void,
    gtk_widget_get_window: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    gtk_widget_set_name: *const fn (*anyopaque, [*:0]const u8) callconv(.c) void,
    gtk_entry_new: *const fn () callconv(.c) ?*anyopaque,
    gtk_entry_get_text: *const fn (*anyopaque) callconv(.c) [*:0]const u8,
    gtk_entry_set_text: *const fn (*anyopaque, [*:0]const u8) callconv(.c) void,
    gtk_entry_set_max_length: *const fn (*anyopaque, c_int) callconv(.c) void,
    gtk_entry_set_has_frame: *const fn (*anyopaque, c_int) callconv(.c) void,
    gtk_editable_set_position: *const fn (*anyopaque, c_int) callconv(.c) void,
    gtk_css_provider_new: *const fn () callconv(.c) ?*anyopaque,
    gtk_css_provider_load_from_data: *const fn (*anyopaque, [*]const u8, isize, ?*?*GError) callconv(.c) c_int,
    gtk_style_context_add_provider_for_screen: *const fn (*anyopaque, *anyopaque, c_uint) callconv(.c) void,
    gtk_file_chooser_native_new: *const fn ([*:0]const u8, ?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) ?*anyopaque,
    gtk_native_dialog_run: *const fn (*anyopaque) callconv(.c) c_int,
    gtk_file_chooser_get_filename: *const fn (*anyopaque) callconv(.c) ?[*:0]u8,
    gtk_file_chooser_add_filter: *const fn (*anyopaque, *anyopaque) callconv(.c) void,
    gtk_file_filter_new: *const fn () callconv(.c) ?*anyopaque,
    gtk_file_filter_set_name: *const fn (*anyopaque, [*:0]const u8) callconv(.c) void,
    gtk_file_filter_add_pattern: *const fn (*anyopaque, [*:0]const u8) callconv(.c) void,
    gtk_show_uri_on_window: *const fn (?*anyopaque, [*:0]const u8, u32, ?*?*GError) callconv(.c) c_int,
    gtk_clipboard_get: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    gtk_clipboard_set_text: *const fn (*anyopaque, [*]const u8, c_int) callconv(.c) void,

    gdk_screen_get_default: *const fn () callconv(.c) ?*anyopaque,
    gdk_atom_intern: *const fn ([*:0]const u8, c_int) callconv(.c) ?*anyopaque,
    gdk_keyval_to_unicode: *const fn (c_uint) callconv(.c) u32,
    gdk_display_get_default: *const fn () callconv(.c) ?*anyopaque,
    gdk_cursor_new_from_name: *const fn (*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
    gdk_window_set_cursor: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void,
    gdk_pixbuf_new_from_file_at_scale: *const fn ([*:0]const u8, c_int, c_int, c_int, ?*?*GError) callconv(.c) ?*anyopaque,
    gdk_pixbuf_loader_new: *const fn () callconv(.c) ?*anyopaque,
    gdk_pixbuf_loader_write: *const fn (*anyopaque, [*]const u8, usize, ?*?*GError) callconv(.c) c_int,
    gdk_pixbuf_loader_close: *const fn (*anyopaque, ?*?*GError) callconv(.c) c_int,
    gdk_pixbuf_loader_get_pixbuf: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    gdk_pixbuf_scale_simple: *const fn (*anyopaque, c_int, c_int, c_int) callconv(.c) ?*anyopaque,
    gdk_pixbuf_get_width: *const fn (*anyopaque) callconv(.c) c_int,
    gdk_pixbuf_get_height: *const fn (*anyopaque) callconv(.c) c_int,
    gdk_cairo_set_source_pixbuf: *const fn (*anyopaque, *anyopaque, f64, f64) callconv(.c) void,

    cairo_set_source_rgb: *const fn (*anyopaque, f64, f64, f64) callconv(.c) void,
    cairo_rectangle: *const fn (*anyopaque, f64, f64, f64, f64) callconv(.c) void,
    cairo_fill: *const fn (*anyopaque) callconv(.c) void,
    cairo_arc: *const fn (*anyopaque, f64, f64, f64, f64, f64) callconv(.c) void,
    cairo_new_sub_path: *const fn (*anyopaque) callconv(.c) void,
    cairo_close_path: *const fn (*anyopaque) callconv(.c) void,
    cairo_move_to: *const fn (*anyopaque, f64, f64) callconv(.c) void,
    cairo_line_to: *const fn (*anyopaque, f64, f64) callconv(.c) void,
    cairo_stroke: *const fn (*anyopaque) callconv(.c) void,
    cairo_set_line_width: *const fn (*anyopaque, f64) callconv(.c) void,
    cairo_save: *const fn (*anyopaque) callconv(.c) void,
    cairo_restore: *const fn (*anyopaque) callconv(.c) void,
    cairo_clip: *const fn (*anyopaque) callconv(.c) void,
    cairo_translate: *const fn (*anyopaque, f64, f64) callconv(.c) void,
    cairo_scale: *const fn (*anyopaque, f64, f64) callconv(.c) void,
    cairo_paint: *const fn (*anyopaque) callconv(.c) void,
    cairo_new_path: *const fn (*anyopaque) callconv(.c) void,

    pango_cairo_create_layout: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    pango_cairo_show_layout: *const fn (*anyopaque, *anyopaque) callconv(.c) void,
    pango_layout_set_text: *const fn (*anyopaque, [*]const u8, c_int) callconv(.c) void,
    pango_layout_set_font_description: *const fn (*anyopaque, ?*anyopaque) callconv(.c) void,
    pango_layout_set_width: *const fn (*anyopaque, c_int) callconv(.c) void,
    pango_layout_set_ellipsize: *const fn (*anyopaque, c_int) callconv(.c) void,
    pango_layout_set_alignment: *const fn (*anyopaque, c_int) callconv(.c) void,
    pango_layout_set_wrap: *const fn (*anyopaque, c_int) callconv(.c) void,
    pango_layout_get_pixel_size: *const fn (*anyopaque, *c_int, *c_int) callconv(.c) void,
    pango_font_description_new: *const fn () callconv(.c) ?*anyopaque,
    pango_font_description_set_family: *const fn (*anyopaque, [*:0]const u8) callconv(.c) void,
    pango_font_description_set_weight: *const fn (*anyopaque, c_int) callconv(.c) void,
    pango_font_description_set_absolute_size: *const fn (*anyopaque, f64) callconv(.c) void,
};

var native: Native = undefined;

fn loadNative() bool {
    var library = std.DynLib.open("libgtk-3.so.0") catch return false;
    inline for (@typeInfo(Native).@"struct".fields) |field| {
        @field(native, field.name) = library.lookup(field.type, field.name) orelse {
            std.debug.print("[launcher] libgtk-3 lacks {s}\n", .{field.name});
            return false;
        };
    }
    // The library stays loaded for the life of the process.
    return true;
}

fn connect(instance: *anyopaque, signal: [*:0]const u8, handler: *const anyopaque) void {
    _ = native.g_signal_connect_data(instance, signal, handler, null, null, 0);
}

// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    app_io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        std.debug.print("PS5PCEM {s}\n", .{build_options.release_version});
        return;
    }
    if (!loadNative()) {
        std.debug.print("PS5PCEM launcher: GTK 3 (libgtk-3.so.0) is required to show the launcher.\n", .{});
        return error.GtkUnavailable;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--check-install")) {
        initializeIniPath();
        var home: [1100]u8 = undefined;
        const directory = emulatorHomeDirectory(&home) orelse return error.DataDirectoryUnavailable;
        for ([_][]const u8{ "game-run", "pkgextractor" }) |name| {
            var path: [1100]u8 = undefined;
            const executable = siblingExecutable(name, &path) orelse return error.ExecutableNotFound;
            if (!pathExists(executable)) return error.ExecutableNotFound;
        }
        std.debug.print("PS5PCEM {s}: GTK 3 and companion executables available\nSettings: {s}\nData: {s}\n", .{ build_options.release_version, ini_path[0..ini_path_length], directory });
        return;
    }
    if (native.gtk_init_check(null, null) == 0) {
        std.debug.print("PS5PCEM launcher: no display to open the window on.\n", .{});
        return error.NoDisplay;
    }

    initializeIniPath();
    loadSettings();
    probeVulkan();
    createFonts();
    loadBrandIcon();

    const window = native.gtk_window_new(0) orelse return error.WindowCreationFailed;
    main_window = window;
    native.gtk_window_set_title(window, "PS5PCEM — Launcher");
    native.gtk_window_set_default_size(window, window_width, window_height);
    native.gtk_window_set_resizable(window, 0);
    native.gtk_window_set_position(window, 1);
    if (brand_icon) |icon| native.gtk_window_set_icon(window, icon);
    connect(window, "destroy", @ptrCast(&onDestroy));
    connect(window, "key-press-event", @ptrCast(&onKeyPress));

    const layout = native.gtk_fixed_new() orelse return error.WindowCreationFailed;
    native.gtk_container_add(window, layout);

    const area = native.gtk_drawing_area_new() orelse return error.WindowCreationFailed;
    drawing_area = area;
    native.gtk_widget_set_size_request(area, window_width, window_height);
    native.gtk_widget_add_events(area, gdk_event_masks);
    native.gtk_widget_set_can_focus(area, 1);
    native.gtk_fixed_put(layout, area, 0, 0);
    connect(area, "draw", @ptrCast(&onDraw));
    connect(area, "button-press-event", @ptrCast(&onButtonPress));
    connect(area, "button-release-event", @ptrCast(&onButtonRelease));
    connect(area, "motion-notify-event", @ptrCast(&onMotion));
    connect(area, "leave-notify-event", @ptrCast(&onLeave));
    connect(area, "scroll-event", @ptrCast(&onScroll));

    createSearchEntry(layout);

    native.gtk_widget_show_all(window);
    if (search_entry) |entry| native.gtk_widget_hide(entry);
    native.gtk_widget_grab_focus(area);
    if (native.gdk_display_get_default()) |display| {
        cursors[@intFromEnum(Cursor.arrow)] = native.gdk_cursor_new_from_name(display, "default");
        cursors[@intFromEnum(Cursor.hand)] = native.gdk_cursor_new_from_name(display, "pointer");
        cursors[@intFromEnum(Cursor.text)] = native.gdk_cursor_new_from_name(display, "text");
    }
    native.gtk_main();
}

fn onDestroy(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    // Closing the launcher abandons the extraction, as on Windows.
    if (extract_pid > 0) _ = std.c.kill(extract_pid, std.c.SIG.TERM);
    native.gtk_main_quit();
}

fn redraw() void {
    if (drawing_area) |area| native.gtk_widget_queue_draw(area);
}

/// The search box is a GtkEntry over the drawn box, so typing gets the caret,
/// selection, clipboard and input methods GTK already provides. It is hidden
/// behind a drawn placeholder until the search is used, as on Windows.
fn createSearchEntry(layout: *anyopaque) void {
    const entry = native.gtk_entry_new() orelse return;
    search_entry = entry;
    native.gtk_widget_set_name(entry, "ps5pcem-search");
    native.gtk_entry_set_has_frame(entry, 0);
    native.gtk_entry_set_max_length(entry, 127);
    native.gtk_widget_set_size_request(entry, search_edit_rect.right - search_edit_rect.left, search_edit_rect.bottom - search_edit_rect.top);
    native.gtk_fixed_put(layout, entry, search_edit_rect.left, search_edit_rect.top);
    connect(entry, "changed", @ptrCast(&onSearchChanged));
    connect(entry, "key-press-event", @ptrCast(&onSearchKey));
    connect(entry, "focus-out-event", @ptrCast(&onSearchFocusOut));

    // The entry takes the drawn box's colours; GTK's theme would otherwise
    // paint a light field with a frame into the dark heading row.
    const css =
        \\#ps5pcem-search, #ps5pcem-search:focus {
        \\  background: #1b1f25; background-image: none; color: #eaf0f4;
        \\  border: none; box-shadow: none; outline: none;
        \\  padding: 0 2px; min-height: 0; font-size: 15px; caret-color: #64acff;
        \\}
        \\#ps5pcem-search selection { background: #3d9cff; color: #10151a; }
    ;
    const provider = native.gtk_css_provider_new() orelse return;
    _ = native.gtk_css_provider_load_from_data(provider, css.ptr, css.len, null);
    if (native.gdk_screen_get_default()) |screen| {
        // GTK_STYLE_PROVIDER_PRIORITY_APPLICATION.
        native.gtk_style_context_add_provider_for_screen(screen, provider, 600);
    }
}

// ---------------------------------------------------------------------------
// Geometry, shared by hit testing and drawing exactly as on Windows.

const nav_rects = [_]Rect{
    .{ .left = 20, .top = 126, .right = 202, .bottom = 174 },
    .{ .left = 20, .top = 184, .right = 202, .bottom = 232 },
    .{ .left = 20, .top = 242, .right = 202, .bottom = 290 },
    .{ .left = 20, .top = 300, .right = 202, .bottom = 348 },
    .{ .left = 20, .top = 584, .right = 202, .bottom = 616 },
    .{ .left = 20, .top = 626, .right = 202, .bottom = 670 },
    .{ .left = 20, .top = 680, .right = 202, .bottom = 724 },
};

const library_browse_rect = Rect{ .left = 282, .top = 646, .right = 500, .bottom = 700 };
const library_extract_rect = Rect{ .left = 516, .top = 646, .right = 760, .bottom = 700 };
const library_launch_rect = Rect{ .left = 776, .top = 646, .right = 1086, .bottom = 700 };
// Same groups as the Windows library card: folder, graphics API, frame limit.
const library_frame_limit_rects = [_]Rect{
    .{ .left = 764, .top = 571, .right = 814, .bottom = 611 },
    .{ .left = 820, .top = 571, .right = 870, .bottom = 611 },
    .{ .left = 876, .top = 571, .right = 932, .bottom = 611 },
    .{ .left = 938, .top = 571, .right = 1066, .bottom = 611 },
};
const library_prev_rect = Rect{ .left = 236, .top = 298, .right = 270, .bottom = 354 };
const library_next_rect = Rect{ .left = 1085, .top = 298, .right = 1119, .bottom = 354 };
const update_rect = Rect{ .left = 936, .top = 44, .right = 1086, .bottom = 72 };
const library_search_rect = Rect{ .left = 580, .top = 44, .right = 840, .bottom = 72 };
const library_view_rects = [_]Rect{
    .{ .left = 852, .top = 44, .right = 886, .bottom = 72 },
    .{ .left = 892, .top = 44, .right = 926, .bottom = 72 },
};
const search_edit_rect = Rect{ .left = 614, .top = 48, .right = 830, .bottom = 69 };
const search_box_colour: u32 = 0x00251f1b;

const input_mode_rects = [_]Rect{
    .{ .left = 282, .top = 170, .right = 532, .bottom = 246 },
    .{ .left = 548, .top = 170, .right = 798, .bottom = 246 },
    .{ .left = 814, .top = 170, .right = 1086, .bottom = 246 },
};

// Six narrower cards a row rather than four keep twelve languages in the
// same two rows: a third would push the settings page past the window.
const language_rects = [_]Rect{
    .{ .left = 282, .top = 190, .right = 406, .bottom = 246 },
    .{ .left = 418, .top = 190, .right = 542, .bottom = 246 },
    .{ .left = 554, .top = 190, .right = 678, .bottom = 246 },
    .{ .left = 690, .top = 190, .right = 814, .bottom = 246 },
    .{ .left = 826, .top = 190, .right = 950, .bottom = 246 },
    .{ .left = 962, .top = 190, .right = 1086, .bottom = 246 },
    .{ .left = 282, .top = 258, .right = 406, .bottom = 314 },
    .{ .left = 418, .top = 258, .right = 542, .bottom = 314 },
    .{ .left = 554, .top = 258, .right = 678, .bottom = 314 },
    .{ .left = 690, .top = 258, .right = 814, .bottom = 314 },
    .{ .left = 826, .top = 258, .right = 950, .bottom = 314 },
    .{ .left = 962, .top = 258, .right = 1086, .bottom = 314 },
};

const settings_toggle_rects = [_]Rect{
    .{ .left = 282, .top = 464, .right = 540, .bottom = 548 },
    .{ .left = 554, .top = 464, .right = 812, .bottom = 548 },
    .{ .left = 826, .top = 464, .right = 1086, .bottom = 548 },
};

const resolution_rects = [_]Rect{
    .{ .left = 282, .top = 360, .right = 398, .bottom = 414 },
    .{ .left = 408, .top = 360, .right = 524, .bottom = 414 },
    .{ .left = 534, .top = 360, .right = 650, .bottom = 414 },
    .{ .left = 660, .top = 360, .right = 776, .bottom = 414 },
};

const preset_rects = [_]Rect{
    .{ .left = 796, .top = 360, .right = 936, .bottom = 414 },
    .{ .left = 946, .top = 360, .right = 1086, .bottom = 414 },
};

const saves_open_rect = Rect{ .left = 880, .top = 148, .right = 1086, .bottom = 190 };

fn mappingRect(index: usize) Rect {
    const column: i32 = @intCast(index / 7);
    const row: i32 = @intCast(index % 7);
    return .{
        .left = 282 + column * 404,
        .top = 310 + row * 48,
        .right = 660 + column * 404,
        .bottom = 350 + row * 48,
    };
}

fn indexOfRect(rects: []const Rect, x: i32, y: i32) ?usize {
    for (rects, 0..) |rectangle, index| {
        if (rectangle.contains(x, y)) return index;
    }
    return null;
}

fn libraryPageCount() usize {
    if (library_match_count == 0) return 1;
    return (library_match_count + library_page_size - 1) / library_page_size;
}

fn libraryGameAtSlot(slot: usize) ?usize {
    const position = library_page * library_page_size + slot;
    if (slot >= library_page_size or position >= library_match_count) return null;
    return library_matches[position];
}

fn librarySlotOf(index: usize) ?usize {
    for (0..library_page_size) |slot| {
        if (libraryGameAtSlot(slot) == index) return slot;
    }
    return null;
}

fn clampLibraryPage() void {
    const pages = libraryPageCount();
    if (library_page >= pages) library_page = pages - 1;
}

fn libraryGameRect(slot: usize) Rect {
    if (library_view == .table) {
        const top: i32 = 170 + @as(i32, @intCast(slot)) * 42;
        return .{ .left = 282, .top = top, .right = 1074, .bottom = top + 38 };
    }
    const column: i32 = @intCast(slot % 4);
    const row: i32 = @intCast(slot / 4);
    const left = 282 + column * 201;
    const top = 142 + row * 190;
    return .{ .left = left, .top = top, .right = left + 188, .bottom = top + 178 };
}

fn recentRemoveRect(slot: usize) Rect {
    const game = libraryGameRect(slot);
    if (library_view == .table) {
        return .{ .left = game.right - 36, .top = game.top + 6, .right = game.right - 10, .bottom = game.bottom - 6 };
    }
    return .{ .left = game.right - 34, .top = game.top + 8, .right = game.right - 8, .bottom = game.top + 34 };
}

fn libraryDotRect(page: usize) Rect {
    const pages: i32 = @intCast(libraryPageCount());
    const step: i32 = 20;
    const span: i32 = (pages - 1) * step;
    const x: i32 = 678 - @divTrunc(span, 2) + @as(i32, @intCast(page)) * step;
    return .{ .left = x - 10, .top = 513, .right = x + 10, .bottom = 533 };
}

fn libraryArrowAt(x: i32, y: i32) ?u1 {
    if (extract_state != .idle or libraryPageCount() < 2) return null;
    if (library_prev_rect.contains(x, y)) return 0;
    if (library_next_rect.contains(x, y)) return 1;
    return null;
}

fn libraryDotAt(x: i32, y: i32) ?usize {
    const pages = libraryPageCount();
    if (extract_state != .idle or pages < 2) return null;
    for (0..pages) |page| {
        if (libraryDotRect(page).contains(x, y)) return page;
    }
    return null;
}

fn stepLibraryPage(delta: i32) bool {
    const pages: i32 = @intCast(libraryPageCount());
    const next = @as(i32, @intCast(library_page)) + delta;
    if (next < 0 or next >= pages) return false;
    showLibraryPage(@intCast(next));
    return true;
}

fn showLibraryPage(page: usize) void {
    library_page = page;
    hovered_recent_game = null;
    hovered_recent_remove = false;
}

fn recentGameAt(x: i32, y: i32) ?usize {
    if (extract_state != .idle) return null;
    for (0..library_page_size) |slot| {
        const index = libraryGameAtSlot(slot) orelse break;
        if (libraryGameRect(slot).contains(x, y)) return index;
    }
    return null;
}

fn recentRemoveAt(x: i32, y: i32) ?usize {
    if (extract_state != .idle) return null;
    for (0..library_page_size) |slot| {
        const index = libraryGameAtSlot(slot) orelse break;
        if (recentRemoveRect(slot).contains(x, y)) return index;
    }
    return null;
}

fn libraryToolbarVisible() bool {
    return current_page == .library and extract_state == .idle and recent_game_count != 0;
}

fn libraryViewAt(x: i32, y: i32) ?LibraryView {
    if (!libraryToolbarVisible()) return null;
    const index = indexOfRect(&library_view_rects, x, y) orelse return null;
    return @enumFromInt(index);
}

fn searchPlaceholderAt(x: i32, y: i32) bool {
    return libraryToolbarVisible() and !search_shown and library_search_rect.contains(x, y);
}

fn clickableAt(x: i32, y: i32) bool {
    if (indexOfRect(&nav_rects, x, y) != null) return true;
    if (update_rect.contains(x, y)) return update_state != .checking;
    return switch (current_page) {
        .library => recentGameAt(x, y) != null or
            indexOfRect(&library_frame_limit_rects, x, y) != null or
            libraryViewAt(x, y) != null or
            libraryArrowAt(x, y) != null or
            libraryDotAt(x, y) != null or
            library_browse_rect.contains(x, y) or
            (extract_state != .running and library_extract_rect.contains(x, y)) or
            (extractFinished() and extract_panel_rect.contains(x, y)) or
            (extract_state != .idle and extract_copy_rect.contains(x, y)) or
            library_launch_rect.contains(x, y),
        .input => blk: {
            if (indexOfRect(&input_mode_rects, x, y) != null) break :blk true;
            for (0..mapping.len) |index| {
                if (mappingRect(index).contains(x, y)) break :blk true;
            }
            break :blk false;
        },
        .saves => saves_open_rect.contains(x, y),
        .settings => indexOfRect(&language_rects, x, y) != null or
            indexOfRect(&resolution_rects, x, y) != null or
            indexOfRect(&preset_rects, x, y) != null or
            indexOfRect(&settings_toggle_rects, x, y) != null,
    };
}

// ---------------------------------------------------------------------------
// Events.

fn eventPoint(x: f64, y: f64) [2]i32 {
    return .{ @intFromFloat(@floor(x)), @intFromFloat(@floor(y)) };
}

fn onButtonPress(_: *anyopaque, event: *const EventButton, _: ?*anyopaque) callconv(.c) c_int {
    // A click anywhere outside the search box ends typing there; clicks in
    // the entry go to the entry and never reach the drawing area.
    if (search_entry) |entry| {
        if (native.gtk_widget_has_focus(entry) != 0) {
            if (drawing_area) |area| native.gtk_widget_grab_focus(area);
            syncSearchBox();
        }
    }
    return @intFromBool(event.button == 1);
}

fn onButtonRelease(_: *anyopaque, event: *const EventButton, _: ?*anyopaque) callconv(.c) c_int {
    if (event.button != 1) return 0;
    const point = eventPoint(event.x, event.y);
    handleClick(point[0], point[1]);
    syncSearchBox();
    return 1;
}

fn onMotion(_: *anyopaque, event: *const EventMotion, _: ?*anyopaque) callconv(.c) c_int {
    const point = eventPoint(event.x, event.y);
    const x = point[0];
    const y = point[1];
    const next_game = if (current_page == .library) recentGameAt(x, y) else null;
    const next_remove = if (next_game) |index| blk: {
        const slot = librarySlotOf(index) orelse break :blk false;
        break :blk recentRemoveRect(slot).contains(x, y);
    } else false;
    const next_arrow = if (current_page == .library) libraryArrowAt(x, y) else null;
    const next_update = update_rect.contains(x, y);
    if (next_game != hovered_recent_game or
        next_remove != hovered_recent_remove or
        next_arrow != hovered_library_arrow or
        next_update != hovered_update)
    {
        hovered_recent_game = next_game;
        hovered_recent_remove = next_remove;
        hovered_library_arrow = next_arrow;
        hovered_update = next_update;
        redraw();
    }
    setCursor(if (searchPlaceholderAt(x, y)) .text else if (clickableAt(x, y)) .hand else .arrow);
    return 0;
}

fn onLeave(_: *anyopaque, _: *anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    if (hovered_recent_game != null or hovered_recent_remove or hovered_library_arrow != null or hovered_update) {
        hovered_recent_game = null;
        hovered_recent_remove = false;
        hovered_library_arrow = null;
        hovered_update = false;
        redraw();
    }
    setCursor(.arrow);
    return 0;
}

fn onScroll(_: *anyopaque, event: *const EventScroll, _: ?*anyopaque) callconv(.c) c_int {
    if (current_page != .library or extract_state != .idle) return 0;
    // Down the wheel is towards later pages, as a list scrolls.
    const steps: i32 = switch (event.direction) {
        gdk_scroll_up => -1,
        gdk_scroll_down => 1,
        gdk_scroll_smooth => smooth: {
            scroll_accumulator += event.delta_y;
            if (@abs(scroll_accumulator) < 1.0) break :smooth 0;
            const whole: i32 = if (scroll_accumulator > 0) 1 else -1;
            scroll_accumulator = 0;
            break :smooth whole;
        },
        else => 0,
    };
    if (steps != 0 and stepLibraryPage(steps)) redraw();
    return 1;
}

fn onKeyPress(_: *anyopaque, event: *const EventKey, _: ?*anyopaque) callconv(.c) c_int {
    if (search_entry) |entry| {
        // The entry handles its own keys; see onSearchKey.
        if (native.gtk_widget_has_focus(entry) != 0) return 0;
    }
    if (capture_mapping) |index| {
        if (event.keyval == keyval_escape) {
            capture_mapping = null;
        } else if (input.virtualKeyFromKey(event.keyval, event.hardware_keycode)) |key| {
            mapping[index] = key;
            capture_mapping = null;
            saveSettings();
            setStatusPhrase(.status_layout_saved, false);
        } else {
            // A key game-run cannot report on Linux; keep waiting for one.
            return 1;
        }
        redraw();
        return 1;
    }
    const modifiers = event.state & (gdk_control_mask | gdk_alt_mask);
    if (modifiers == gdk_control_mask and (event.keyval == 'f' or event.keyval == 'F') and libraryToolbarVisible()) {
        activateSearch();
        return 1;
    }
    // Typing on the library starts a search with that character. A space
    // does not: on its own it would match nearly every title.
    if (modifiers == 0 and libraryToolbarVisible()) {
        const character = native.gdk_keyval_to_unicode(event.keyval);
        if (character > 0x20 and character != 0x7f) {
            var encoded: [5]u8 = @splat(0);
            const length = std.unicode.utf8Encode(@intCast(character), &encoded) catch return 0;
            encoded[length] = 0;
            activateSearch();
            if (search_entry) |entry| {
                native.gtk_entry_set_text(entry, @ptrCast(&encoded));
                native.gtk_editable_set_position(entry, -1);
            }
            return 1;
        }
    }
    return 0;
}

/// Escape clears the search and leaves the box; Enter picks the first result.
fn onSearchKey(entry: *anyopaque, event: *const EventKey, _: ?*anyopaque) callconv(.c) c_int {
    if (event.keyval == keyval_escape) {
        native.gtk_entry_set_text(entry, "");
        if (drawing_area) |area| native.gtk_widget_grab_focus(area);
        syncSearchBox();
        redraw();
        return 1;
    }
    if (event.keyval == keyval_return or event.keyval == keyval_keypad_enter) {
        if (library_match_count != 0) {
            selectRecentGame(library_matches[0]);
            redraw();
        }
        return 1;
    }
    return 0;
}

fn onSearchChanged(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    readSearchText();
    syncSearchBox();
    redraw();
}

fn onSearchFocusOut(_: *anyopaque, _: *anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    syncSearchBox();
    redraw();
    return 0;
}

fn setCursor(cursor: Cursor) void {
    if (cursor == shown_cursor) return;
    const area = drawing_area orelse return;
    const window = native.gtk_widget_get_window(area) orelse return;
    native.gdk_window_set_cursor(window, cursors[@intFromEnum(cursor)]);
    shown_cursor = cursor;
}

fn handleClick(x: i32, y: i32) void {
    if (indexOfRect(&nav_rects, x, y)) |index| {
        switch (index) {
            0 => current_page = .library,
            1 => current_page = .input,
            2 => current_page = .saves,
            3 => current_page = .settings,
            4 => openUri(site_url),
            5 => openUri(boosty_url),
            else => openUri(github_url),
        }
        if (current_page != .library) {
            hovered_recent_game = null;
            hovered_recent_remove = false;
        }
        if (current_page == .saves) invalidateSaves();
    } else if (update_rect.contains(x, y)) {
        handleUpdateClick();
    } else switch (current_page) {
        .library => handleLibraryClick(x, y),
        .input => handleInputClick(x, y),
        .saves => handleSavesClick(x, y),
        .settings => handleSettingsClick(x, y),
    }
    redraw();
}

fn handleLibraryClick(x: i32, y: i32) void {
    if (indexOfRect(&library_frame_limit_rects, x, y)) |index| {
        selected_frame_limit = frame_limit.choices[index];
        saveSettings();
        setStatusPhrase(.status_fps_limit_saved, false);
        return;
    }
    if (extract_state != .idle and extract_copy_rect.contains(x, y)) {
        copyExtractLog();
        return;
    }
    if (extractFinished() and extract_panel_rect.contains(x, y)) {
        extract_state = .idle;
        return;
    }
    if (searchPlaceholderAt(x, y)) {
        activateSearch();
        return;
    }
    if (libraryViewAt(x, y)) |view| {
        if (view != library_view) {
            library_view = view;
            hovered_recent_game = null;
            hovered_recent_remove = false;
            saveSettings();
        }
        return;
    }
    if (libraryArrowAt(x, y)) |arrow| {
        _ = stepLibraryPage(if (arrow == 0) -1 else 1);
        return;
    }
    if (libraryDotAt(x, y)) |page| {
        if (page != library_page) showLibraryPage(page);
        return;
    }
    if (recentRemoveAt(x, y)) |index| {
        removeRecentGame(index);
        return;
    }
    if (recentGameAt(x, y)) |index| {
        selectRecentGame(index);
        return;
    }
    if (library_browse_rect.contains(x, y)) chooseGameFolder();
    if (library_extract_rect.contains(x, y) and extract_state != .running) extractPackage();
    if (library_launch_rect.contains(x, y)) launchGame();
}

fn handleInputClick(x: i32, y: i32) void {
    if (indexOfRect(&input_mode_rects, x, y)) |index| {
        input_mode = @enumFromInt(index);
        saveSettings();
        setStatusPhrase(.status_input_saved, false);
        return;
    }
    for (0..mapping.len) |index| {
        if (mappingRect(index).contains(x, y)) {
            capture_mapping = index;
            setStatusPhrase(.status_press_key, false);
            return;
        }
    }
}

fn handleSettingsClick(x: i32, y: i32) void {
    if (indexOfRect(&resolution_rects, x, y)) |index| {
        output_mode = display_mode.choices[index];
        saveSettings();
        setStatusPhrase(.status_resolution_saved, false);
        return;
    }
    if (indexOfRect(&preset_rects, x, y)) |index| {
        render_preset = performance_mode.Mode.fromIndex(index) orelse render_preset;
        saveSettings();
        setStatusPhrase(.status_preset_saved, false);
        return;
    }
    if (indexOfRect(&language_rects, x, y)) |index| {
        language = @enumFromInt(index);
        status_length = 0;
        saveSettings();
        return;
    }
    const toggle = indexOfRect(&settings_toggle_rects, x, y) orelse return;
    if (toggle == 0) {
        sound_enabled = !sound_enabled;
        saveSettings();
        setStatusPhrase(if (sound_enabled) .status_sound_on else .status_sound_off, false);
    } else if (toggle == 1) {
        show_fps = !show_fps;
        saveSettings();
        setStatusPhrase(if (show_fps) .status_fps_on else .status_fps_off, false);
    } else {
        game_performance = !game_performance;
        saveSettings();
        setStatusPhrase(.status_preset_saved, false);
    }
}

// ---------------------------------------------------------------------------
// Search.

/// Lowercases through GLib, so Cyrillic, Greek and accented Latin titles
/// match as they do on Windows.
fn lowered(value: []const u8, output: []u8) []const u8 {
    if (value.len == 0) return output[0..0];
    const folded = native.g_utf8_strdown(value.ptr, @intCast(value.len)) orelse return output[0..0];
    defer native.g_free(folded);
    const span = std.mem.span(folded);
    const length = @min(span.len, output.len);
    @memcpy(output[0..length], span[0..length]);
    return output[0..length];
}

fn containsIgnoringCase(haystack: []const u8, lowered_needle: []const u8) bool {
    if (lowered_needle.len == 0) return true;
    var storage: [2048]u8 = undefined;
    return std.mem.indexOf(u8, lowered(haystack, &storage), lowered_needle) != null;
}

fn refreshLibraryMatches() void {
    var needle_storage: [2048]u8 = undefined;
    const needle = lowered(search_text[0..search_length], &needle_storage);
    library_match_count = 0;
    for (recent_games[0..recent_game_count], 0..) |game, index| {
        const folder = game.folder[0..game.folder_length];
        const name = folder[baseNameStart(folder)..];
        if (containsIgnoringCase(game.title[0..game.title_length], needle) or
            containsIgnoringCase(game.identifier[0..game.identifier_length], needle) or
            containsIgnoringCase(name, needle))
        {
            library_matches[library_match_count] = @intCast(index);
            library_match_count += 1;
        }
    }
    clampLibraryPage();
}

fn readSearchText() void {
    const entry = search_entry orelse return;
    const value = std.mem.span(native.gtk_entry_get_text(entry));
    search_length = @min(value.len, search_text.len - 1);
    @memcpy(search_text[0..search_length], value[0..search_length]);
    search_text[search_length] = 0;
    refreshLibraryMatches();
    showLibraryPage(0);
}

fn activateSearch() void {
    const entry = search_entry orelse return;
    if (!libraryToolbarVisible()) return;
    search_shown = true;
    native.gtk_widget_show(entry);
    native.gtk_widget_grab_focus(entry);
    redraw();
}

fn clearSearch() void {
    if (search_entry) |entry| {
        if (search_length != 0) native.gtk_entry_set_text(entry, "");
    }
    search_length = 0;
    refreshLibraryMatches();
}

/// Shows the entry only on the library, and only while it holds text or has
/// the focus, as on Windows.
fn syncSearchBox() void {
    const entry = search_entry orelse return;
    if (recent_game_count == 0 and search_length != 0) clearSearch();
    const focused = native.gtk_widget_has_focus(entry) != 0;
    const shown = libraryToolbarVisible() and (search_length != 0 or focused);
    if (!shown and focused) {
        if (drawing_area) |area| native.gtk_widget_grab_focus(area);
    }
    search_shown = shown;
    if (shown) native.gtk_widget_show(entry) else native.gtk_widget_hide(entry);
}

// ---------------------------------------------------------------------------
// Drawing.

fn onDraw(_: *anyopaque, cr: *anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    paint(cr);
    return 1;
}

fn paint(cr: *anyopaque) void {
    fill(cr, .{ .left = 0, .top = 0, .right = window_width, .bottom = window_height }, 0x0015110e);
    fill(cr, .{ .left = 0, .top = 0, .right = sidebar_width, .bottom = window_height }, 0x00201915);
    fill(cr, .{ .left = sidebar_width, .top = 0, .right = sidebar_width + 1, .bottom = window_height }, 0x00352b25);

    drawBrand(cr);
    drawNavigation(cr);
    switch (current_page) {
        .library => drawLibrary(cr),
        .input => drawInput(cr),
        .saves => drawSaves(cr),
        .settings => drawSettings(cr),
    }
    drawFooter(cr);
}

fn drawBrand(cr: *anyopaque) void {
    if (brand_icon) |icon| drawPixbuf(cr, icon, .{ .left = 24, .top = 28, .right = 68, .bottom = 72 });
    text(cr, "PS5PCEM", .{ .left = 80, .top = 26, .right = 216, .bottom = 62 }, 0x00f4f0ea, .title, .{});
    text(cr, "PREVIEW BUILD", .{ .left = 80, .top = 62, .right = 216, .bottom = 80 }, 0x009b9088, .small, .{});
}

fn drawNavigation(cr: *anyopaque) void {
    drawNavItem(cr, .library, 126, .nav_library, "01");
    drawNavItem(cr, .input, 184, .nav_input, "02");
    drawNavItem(cr, .saves, 242, .nav_saves, "03");
    drawNavItem(cr, .settings, 300, .nav_settings, "04");
    drawVulkanStatus(cr);
    localizedText(cr, .project, .{ .left = 28, .top = 560, .right = 190, .bottom = 580 }, 0x007c716a, .small, .{});
    roundFill(cr, .{ .left = 20, .top = 626, .right = 202, .bottom = 670 }, 10, 0x003d3029);
    localizedText(cr, .support_boosty, .{ .left = 32, .top = 639, .right = 192, .bottom = 660 }, 0x00ffac64, .small, .{});
    text(cr, "GitHub · iStark  ↗", .{ .left = 28, .top = 690, .right = 198, .bottom = 716 }, 0x00b9afa8, .regular, .{});
    text(cr, "ps5pcem.com  ↗", .{ .left = 28, .top = 588, .right = 198, .bottom = 612 }, 0x00ffac64, .regular, .{});
}

fn drawVulkanStatus(cr: *anyopaque) void {
    const area = Rect{ .left = 28, .top = 498, .right = 198, .bottom = 520 };
    const second = Rect{ .left = 28, .top = 518, .right = 198, .bottom = 540 };
    const dim: u32 = 0x007c716a;
    const warn: u32 = 0x006f8cff;
    switch (vulkan_report.state) {
        .ready => {
            var line: [64]u8 = undefined;
            const version = std.fmt.bufPrint(&line, "Vulkan {d}.{d} ready", .{ vulkan_report.major, vulkan_report.minor }) catch return;
            text(cr, version, area, 0x0074c98a, .small, .{});
            text(cr, vulkan_report.deviceName(), second, dim, .small, .{});
        },
        .no_loader => localizedText(cr, .vulkan_missing, area, warn, .small, .{}),
        .no_device => localizedText(cr, .vulkan_no_device, area, warn, .small, .{}),
        .too_old => localizedText(cr, .vulkan_too_old, area, warn, .small, .{}),
        .unchecked => {},
    }
}

fn drawNavItem(cr: *anyopaque, page: Page, top: i32, label: Phrase, index: []const u8) void {
    if (current_page == page) roundFill(cr, .{ .left = 20, .top = top, .right = 202, .bottom = top + 48 }, 12, 0x003d3029);
    const colour: u32 = if (current_page == page) 0x00fff8f1 else 0x00a39890;
    text(cr, index, .{ .left = 34, .top = top + 15, .right = 58, .bottom = top + 38 }, if (current_page == page) 0x00ffac64 else 0x006d625b, .small, .{});
    localizedText(cr, label, .{ .left = 66, .top = top + 13, .right = 200, .bottom = top + 39 }, colour, .medium, .{});
}

fn drawLibrary(cr: *anyopaque) void {
    if (libraryToolbarVisible()) {
        pageHeadingBefore(cr, .library_heading, .library_subtitle, library_search_rect.left - 16);
        drawLibraryToolbar(cr);
    } else {
        pageHeading(cr, .library_heading, .library_subtitle);
    }

    if (extract_state != .idle) {
        drawExtractPanel(cr);
    } else if (recent_game_count == 0) {
        card(cr, .{ .left = 282, .top = 158, .right = 1086, .bottom = 510 });
        localizedText(cr, .folder_prompt, .{ .left = 330, .top = 298, .right = 1038, .bottom = 338 }, 0x00f4f0ea, .title, .{ .alignment = .center });
        localizedText(cr, .folder_empty, .{ .left = 330, .top = 350, .right = 1038, .bottom = 376 }, 0x008b817a, .regular, .{ .alignment = .center });
    } else if (library_match_count == 0) {
        card(cr, .{ .left = 282, .top = 158, .right = 1086, .bottom = 510 });
        localizedText(cr, .search_empty, .{ .left = 330, .top = 298, .right = 1038, .bottom = 338 }, 0x00f4f0ea, .title, .{ .alignment = .center });
        text(cr, search_text[0..search_length], .{ .left = 330, .top = 350, .right = 1038, .bottom = 376 }, 0x008b817a, .regular, .{ .alignment = .center });
    } else {
        if (library_view == .table) drawLibraryTableHeader(cr);
        for (0..library_page_size) |slot| {
            const index = libraryGameAtSlot(slot) orelse break;
            switch (library_view) {
                .grid => drawLibraryGame(cr, &recent_games[index], index, slot),
                .table => drawLibraryRow(cr, &recent_games[index], index, slot),
            }
        }
        drawLibraryPager(cr);
    }

    card(cr, .{ .left = 282, .top = 536, .right = 1086, .bottom = 622 });
    localizedText(cr, .graphics_api, .{ .left = 472, .top = 546, .right = 748, .bottom = 566 }, 0x009b9088, .small, .{});
    text(cr, "Windows", .{ .left = 610, .top = 546, .right = 748, .bottom = 566 }, 0x007e746d, .small, .{ .alignment = .right });
    roundFill(cr, .{ .left = 472, .top = 571, .right = 582, .bottom = 611 }, 8, 0x0042362e);
    roundFill(cr, .{ .left = 484, .top = 586, .right = 494, .bottom = 596 }, 5, 0x00ffac64);
    text(cr, "Vulkan", .{ .left = 504, .top = 581, .right = 574, .bottom = 606 }, 0x00f4f0ea, .medium, .{});
    roundFill(cr, .{ .left = 590, .top = 571, .right = 748, .bottom = 611 }, 8, 0x00251f1b);
    text(cr, "DirectX 12", .{ .left = 622, .top = 581, .right = 740, .bottom = 606 }, 0x007e746d, .medium, .{});
    localizedText(cr, .fps_limit, .{ .left = 764, .top = 546, .right = 1066, .bottom = 566 }, 0x009b9088, .small, .{});
    for (library_frame_limit_rects, frame_limit.choices) |rectangle, limit| {
        const selected = selected_frame_limit == limit;
        roundFill(cr, rectangle, 8, if (selected) 0x0042362e else 0x00251f1b);
        const colour: u32 = if (selected) 0x00ffac64 else 0x00f4f0ea;
        const area = Rect{ .left = rectangle.left + 4, .top = rectangle.top + 10, .right = rectangle.right - 4, .bottom = rectangle.bottom - 5 };
        if (limit == .unlimited) {
            localizedText(cr, .fps_unlimited, area, colour, .medium, .{ .alignment = .center });
        } else {
            text(cr, limit.value(), area, colour, .medium, .{ .alignment = .center });
        }
    }
    localizedText(cr, .folder_label, .{ .left = 306, .top = 546, .right = 456, .bottom = 566 }, 0x009b9088, .small, .{});
    if (game_folder_length == 0) {
        localizedText(cr, .folder_empty, .{ .left = 306, .top = 582, .right = 456, .bottom = 607 }, 0x007e746d, .regular, .{});
    } else {
        text(cr, game_folder[0..game_folder_length], .{ .left = 306, .top = 580, .right = 456, .bottom = 607 }, 0x00d8d0c9, .regular, .{});
    }

    button(cr, library_browse_rect, .choose_folder, false);
    button(cr, library_extract_rect, .extract_pkg, extract_state == .running);
    drawLegalNotice(cr);
    button(cr, library_launch_rect, .launch_game, game_folder_length == 0);
}

fn extractFinished() bool {
    return extract_state == .succeeded or extract_state == .failed;
}

fn drawExtractPanel(cr: *anyopaque) void {
    lockExtractFeed();
    const feed = extract_feed;
    extract_lock.unlock();

    const panel = extract_panel_rect;
    card(cr, panel);
    const left = panel.left + 24;
    const right = panel.right - 24;
    localizedText(cr, extract_result, .{ .left = left, .top = panel.top + 20, .right = extract_copy_rect.left - 16, .bottom = panel.top + 46 }, 0x00f4f0ea, .medium, .{});
    roundFill(cr, extract_copy_rect, 10, 0x00342a25);
    localizedText(cr, .copy_log, .{ .left = extract_copy_rect.left + 8, .top = extract_copy_rect.top + 8, .right = extract_copy_rect.right - 8, .bottom = extract_copy_rect.bottom - 6 }, 0x00ffac64, .small, .{ .alignment = .center });
    text(cr, extract_name[0..extract_name_length], .{ .left = left, .top = panel.top + 50, .right = extract_copy_rect.left - 16, .bottom = panel.top + 70 }, 0x009b9088, .small, .{});

    const track = Rect{ .left = left, .top = panel.top + 84, .right = right, .bottom = panel.top + 98 };
    roundFill(cr, track, 14, 0x00342a25);
    const fraction: f64 = if (extract_state == .succeeded)
        1.0
    else if (feed.total == 0)
        0.0
    else
        @as(f64, @floatFromInt(@min(feed.done, feed.total))) / @as(f64, @floatFromInt(feed.total));
    const width: i32 = @intFromFloat(@as(f64, @floatFromInt(track.right - track.left)) * fraction);
    if (width >= 14) {
        const colour: u32 = switch (extract_state) {
            .failed => 0x006b77ff,
            .succeeded => 0x0068d391,
            else => 0x00ff9c3d,
        };
        roundFill(cr, .{ .left = track.left, .top = track.top, .right = track.left + width, .bottom = track.bottom }, 14, colour);
    }
    const detail_area = Rect{ .left = left, .top = panel.top + 106, .right = right - 240, .bottom = panel.top + 126 };
    if (extractFinished()) {
        localizedText(cr, .extract_dismiss, .{ .left = right - 240, .top = panel.top + 106, .right = right, .bottom = panel.top + 126 }, 0x007c716a, .small, .{ .alignment = .right });
    }
    if (feed.total == 0 and extract_state == .running) {
        localizedText(cr, .extract_preparing, detail_area, 0x009b9088, .small, .{});
    } else if (feed.total != 0) {
        var line: [96]u8 = undefined;
        const gib = 1024.0 * 1024.0 * 1024.0;
        const detail = std.fmt.bufPrint(&line, "{d}%  ·  {d:.2} / {d:.2} GB", .{
            @as(u32, @intFromFloat(fraction * 100.0)),
            @as(f64, @floatFromInt(@min(feed.done, feed.total))) / gib,
            @as(f64, @floatFromInt(feed.total)) / gib,
        }) catch "";
        text(cr, detail, detail_area, 0x00d8d0c9, .small, .{});
    }

    const log_area = Rect{ .left = left, .top = panel.top + 138, .right = right, .bottom = panel.bottom - 20 };
    roundFill(cr, log_area, 10, 0x001c1714);
    const first = (feed.log_next + extract_log_capacity - feed.log_count) % extract_log_capacity;
    for (0..feed.log_count) |row| {
        const slot = (first + row) % extract_log_capacity;
        const top = log_area.top + 10 + @as(i32, @intCast(row)) * 22;
        text(cr, feed.log[slot][0..feed.log_lengths[slot]], .{ .left = log_area.left + 14, .top = top, .right = log_area.right - 14, .bottom = top + 20 }, 0x00b9afa8, .small, .{});
    }
}

fn drawLegalNotice(cr: *anyopaque) void {
    const area = Rect{ .left = 282, .top = 708, .right = 1086, .bottom = 730 };
    var line: [512]u8 = undefined;
    const composed: []const u8 = std.fmt.bufPrint(&line, "{s} · v{s}", .{ tr(.legal_notice), build_options.release_version }) catch tr(.legal_notice);
    text(cr, composed, area, 0x007e746d, .small, .{ .alignment = .center });
}

fn drawLibraryPager(cr: *anyopaque) void {
    const pages = libraryPageCount();
    if (pages < 2) return;
    drawLibraryArrow(cr, library_prev_rect, "‹", library_page > 0, hovered_library_arrow == 0);
    drawLibraryArrow(cr, library_next_rect, "›", library_page + 1 < pages, hovered_library_arrow == 1);
    for (0..pages) |page| {
        const dot = libraryDotRect(page);
        const centre_x = @divTrunc(dot.left + dot.right, 2);
        const centre_y = @divTrunc(dot.top + dot.bottom, 2);
        const current = page == library_page;
        const radius: i32 = if (current) 5 else 4;
        roundFill(cr, .{
            .left = centre_x - radius,
            .top = centre_y - radius,
            .right = centre_x + radius,
            .bottom = centre_y + radius,
        }, radius * 2, if (current) 0x00ffac64 else 0x00403934);
    }
}

fn drawLibraryArrow(cr: *anyopaque, rectangle: Rect, glyph: []const u8, enabled: bool, hovered: bool) void {
    const background: u32 = if (!enabled) 0x001f1a16 else if (hovered) 0x004a3a2e else 0x00251f1b;
    roundFill(cr, rectangle, 16, background);
    const colour: u32 = if (!enabled) 0x00463c35 else if (hovered) 0x00fff8f1 else 0x00a39890;
    text(cr, glyph, rectangle, colour, .title, .{ .alignment = .center, .vertical_center = true });
}

fn drawLibraryGame(cr: *anyopaque, game: *const RecentGame, index: usize, slot: usize) void {
    const rectangle = libraryGameRect(slot);
    const selected = sameFolder(game.folder[0..game.folder_length], game_folder[0..game_folder_length]);
    roundFill(cr, rectangle, 12, if (selected) 0x0049362b else 0x00251f1b);
    const artwork = Rect{
        .left = rectangle.left + 26,
        .top = rectangle.top + 10,
        .right = rectangle.right - 26,
        .bottom = rectangle.top + 146,
    };
    if (game.icon) |icon| {
        drawPixbuf(cr, icon, artwork);
    } else {
        roundFill(cr, artwork, 10, 0x00352c27);
        text(cr, "PS5", artwork, 0x00ffac64, .title, .{ .alignment = .center, .vertical_center = true });
    }
    const label_area = Rect{ .left = rectangle.left + 10, .top = rectangle.top + 151, .right = rectangle.right - 10, .bottom = rectangle.bottom - 6 };
    if (game.title_length != 0) {
        text(cr, game.title[0..game.title_length], label_area, 0x00f4f0ea, .small, .{ .alignment = .center });
    } else {
        text(cr, game.identifier[0..game.identifier_length], label_area, 0x00a39890, .small, .{ .alignment = .center });
    }
    if (hovered_recent_game == index) {
        const remove = recentRemoveRect(slot);
        roundFill(cr, remove, 13, if (hovered_recent_remove) 0x004848d8 else 0x00403934);
        text(cr, "×", remove, 0x00f4f0ea, .medium, .{ .alignment = .center, .vertical_center = true });
    }
}

fn drawLibraryToolbar(cr: *anyopaque) void {
    const box = library_search_rect;
    const focused = if (search_entry) |entry| native.gtk_widget_has_focus(entry) != 0 else false;
    roundFill(cr, box, 12, if (focused) 0x00ffac64 else 0x00403934);
    roundFill(cr, .{ .left = box.left + 1, .top = box.top + 1, .right = box.right - 1, .bottom = box.bottom - 1 }, 11, search_box_colour);
    drawMagnifier(cr, box.left + 12, box.top + 8, if (focused) 0x00ffac64 else 0x008b817a);
    if (!search_shown) {
        localizedText(cr, .search_placeholder, .{ .left = search_edit_rect.left, .top = box.top, .right = search_edit_rect.right, .bottom = box.bottom }, 0x007e746d, .regular, .{ .vertical_center = true });
    }

    for (library_view_rects, 0..) |rectangle, index| {
        const view: LibraryView = @enumFromInt(index);
        const selected = view == library_view;
        roundFill(cr, rectangle, 10, if (selected) 0x003d3029 else search_box_colour);
        const colour: u32 = if (selected) 0x00ffac64 else 0x008b817a;
        const x = rectangle.left + @divTrunc(rectangle.right - rectangle.left - 16, 2);
        const y = rectangle.top + 6;
        switch (view) {
            .grid => for (0..4) |tile| {
                const tile_x = x + @as(i32, @intCast(tile % 2)) * 9;
                const tile_y = y + @as(i32, @intCast(tile / 2)) * 9;
                fill(cr, .{ .left = tile_x, .top = tile_y, .right = tile_x + 7, .bottom = tile_y + 7 }, colour);
            },
            .table => for (0..3) |row| {
                const row_y = y + 1 + @as(i32, @intCast(row)) * 6;
                fill(cr, .{ .left = x, .top = row_y, .right = x + 3, .bottom = row_y + 3 }, colour);
                fill(cr, .{ .left = x + 5, .top = row_y, .right = x + 16, .bottom = row_y + 3 }, colour);
            },
        }
    }
}

fn drawMagnifier(cr: *anyopaque, x: i32, y: i32, colour: u32) void {
    setColour(cr, colour);
    native.cairo_set_line_width(cr, 2);
    native.cairo_new_path(cr);
    native.cairo_arc(cr, @as(f64, @floatFromInt(x)) + 5, @as(f64, @floatFromInt(y)) + 5, 4.5, 0, 2 * std.math.pi);
    native.cairo_stroke(cr);
    native.cairo_move_to(cr, @as(f64, @floatFromInt(x)) + 8.5, @as(f64, @floatFromInt(y)) + 8.5);
    native.cairo_line_to(cr, @as(f64, @floatFromInt(x)) + 13, @as(f64, @floatFromInt(y)) + 13);
    native.cairo_stroke(cr);
}

const table_title_left = 340;
const table_identifier_left = 700;
const table_folder_left = 812;
const table_folder_right = 1030;

fn drawLibraryTableHeader(cr: *anyopaque) void {
    const colour: u32 = 0x007c716a;
    text(cr, tr(.column_title), .{ .left = table_title_left, .top = 146, .right = table_identifier_left - 12, .bottom = 164 }, colour, .small, .{});
    text(cr, tr(.column_identifier), .{ .left = table_identifier_left, .top = 146, .right = table_folder_left - 12, .bottom = 164 }, colour, .small, .{});
    text(cr, tr(.column_folder), .{ .left = table_folder_left, .top = 146, .right = table_folder_right, .bottom = 164 }, colour, .small, .{});
}

fn drawLibraryRow(cr: *anyopaque, game: *const RecentGame, index: usize, slot: usize) void {
    const row = libraryGameRect(slot);
    const selected = sameFolder(game.folder[0..game.folder_length], game_folder[0..game_folder_length]);
    const hovered = hovered_recent_game == index;
    roundFill(cr, row, 10, if (selected) 0x0049362b else if (hovered) 0x002e2621 else 0x00251f1b);
    const icon = Rect{ .left = row.left + 10, .top = row.top + 3, .right = row.left + 42, .bottom = row.top + 35 };
    if (game.icon) |pixbuf| {
        drawPixbuf(cr, pixbuf, icon);
    } else {
        roundFill(cr, icon, 6, 0x00352c27);
    }
    const line = TextOptions{ .vertical_center = true };
    text(cr, game.title[0..game.title_length], .{ .left = table_title_left, .top = row.top, .right = table_identifier_left - 12, .bottom = row.bottom }, 0x00f4f0ea, .regular, line);
    text(cr, game.identifier[0..game.identifier_length], .{ .left = table_identifier_left, .top = row.top, .right = table_folder_left - 12, .bottom = row.bottom }, 0x00a39890, .small, line);
    // The end of a path names the game's own folder, so the middle is what
    // gives way when it does not fit.
    text(cr, game.folder[0..game.folder_length], .{ .left = table_folder_left, .top = row.top, .right = table_folder_right, .bottom = row.bottom }, 0x007e746d, .small, .{ .vertical_center = true, .ellipsis = .middle });
    if (hovered) {
        const remove = recentRemoveRect(slot);
        roundFill(cr, remove, 13, if (hovered_recent_remove) 0x004848d8 else 0x00403934);
        text(cr, "×", remove, 0x00f4f0ea, .medium, .{ .alignment = .center, .vertical_center = true });
    }
}

fn drawInput(cr: *anyopaque) void {
    pageHeading(cr, .input_heading, .input_subtitle);
    // game-run reads no gamepads on Linux yet, which is what the first card
    // says in place of the XInput slot it shows on Windows.
    drawModeCard(cr, .controller, input_mode_rects[0], .gamepad, .pad_absent);
    drawModeCard(cr, .keyboard, input_mode_rects[1], .keyboard, .wasd_mapping);
    drawModeCard(cr, .hybrid, input_mode_rects[2], .hybrid, .both_sources);

    localizedText(cr, .keyboard_layout, .{ .left = 282, .top = 278, .right = 1086, .bottom = 300 }, 0x009b9088, .small, .{});
    for (0..mapping.len) |index| {
        const column: i32 = @intCast(index / 7);
        const row: i32 = @intCast(index % 7);
        const left = 282 + column * 404;
        const top = 310 + row * 48;
        roundFill(cr, .{ .left = left, .top = top, .right = left + 378, .bottom = top + 40 }, 8, if (capture_mapping == index) 0x0042362e else 0x00251f1b);
        text(cr, mapping_names[index], .{ .left = left + 14, .top = top + 11, .right = left + 210, .bottom = top + 32 }, 0x00d8d0c9, .regular, .{});
        var key_buffer: [16]u8 = undefined;
        text(cr, keyDisplayName(mapping[index], &key_buffer), .{ .left = left + 218, .top = top + 10, .right = left + 356, .bottom = top + 33 }, if (capture_mapping == index) 0x00ffac64 else 0x00f4f0ea, .medium, .{ .alignment = .right });
    }
    localizedText(cr, .mapping_hint, .{ .left = 282, .top = 660, .right = 1086, .bottom = 686 }, 0x008b817a, .small, .{});
}

fn drawSaves(cr: *anyopaque) void {
    pageHeading(cr, .saves_heading, .saves_subtitle);
    if (!save_scan_done) scanSaves();

    button(cr, saves_open_rect, .saves_open_folder, false);

    if (save_slot_count == 0) {
        card(cr, .{ .left = 282, .top = 200, .right = 1086, .bottom = 268 });
        localizedText(cr, .saves_empty, .{ .left = 306, .top = 224, .right = 1062, .bottom = 248 }, 0x008b817a, .regular, .{});
        return;
    }

    for (save_slots[0..save_slot_count], 0..) |*slot, index| {
        const top = 200 + @as(i32, @intCast(index)) * 44;
        if (top > 660) break;
        roundFill(cr, .{ .left = 282, .top = top, .right = 1086, .bottom = top + 38 }, 8, 0x00251f1b);
        text(cr, slot.title_id[0..slot.title_id_length], .{ .left = 300, .top = top + 10, .right = 410, .bottom = top + 32 }, 0x00ffac64, .small, .{});
        text(cr, slot.name[0..slot.name_length], .{ .left = 425, .top = top + 9, .right = 675, .bottom = top + 32 }, 0x00f4f0ea, .medium, .{});
        if (slot.detail_length != 0) {
            text(cr, slot.detail[0..slot.detail_length], .{ .left = 690, .top = top + 10, .right = 1066, .bottom = top + 32 }, 0x009b9088, .regular, .{});
        }
    }
}

fn drawSettings(cr: *anyopaque) void {
    pageHeading(cr, .settings_heading, .settings_subtitle);
    localizedText(cr, .language, .{ .left = 282, .top = 158, .right = 1086, .bottom = 180 }, 0x009b9088, .small, .{});
    for (language_rects, language_labels, 0..) |rectangle, label, index| {
        drawLanguageCard(cr, @enumFromInt(index), rectangle, label);
    }

    localizedText(cr, .output_resolution, .{ .left = 282, .top = 332, .right = 776, .bottom = 354 }, 0x009b9088, .small, .{});
    for (resolution_rects, display_mode.choices) |rectangle, mode| {
        const selected = output_mode == mode;
        roundFill(cr, rectangle, 10, if (selected) 0x0042362e else 0x00251f1b);
        if (selected) roundFill(cr, .{ .left = rectangle.left + 12, .top = rectangle.top + 22, .right = rectangle.left + 22, .bottom = rectangle.top + 32 }, 5, 0x00ffac64);
        text(cr, mode.label(), .{ .left = rectangle.left + 32, .top = rectangle.top + 17, .right = rectangle.right - 8, .bottom = rectangle.bottom - 10 }, 0x00f4f0ea, .medium, .{});
    }
    localizedText(cr, .output_resolution_description, .{ .left = 282, .top = 420, .right = 776, .bottom = 458 }, 0x009b9088, .small, .{ .wrap = true });

    localizedText(cr, .render_preset, .{ .left = 796, .top = 332, .right = 1086, .bottom = 354 }, 0x009b9088, .small, .{});
    for (preset_rects, performance_mode.choices, [_]Phrase{ .preset_speed, .preset_graphics }) |rectangle, mode, label| {
        const selected = render_preset == mode;
        roundFill(cr, rectangle, 10, if (selected) 0x0042362e else 0x00251f1b);
        if (selected) roundFill(cr, .{ .left = rectangle.left + 12, .top = rectangle.top + 22, .right = rectangle.left + 22, .bottom = rectangle.top + 32 }, 5, 0x00ffac64);
        localizedText(cr, label, .{ .left = rectangle.left + 32, .top = rectangle.top + 17, .right = rectangle.right - 8, .bottom = rectangle.bottom - 10 }, 0x00f4f0ea, .medium, .{});
    }
    localizedText(cr, .render_preset_description, .{ .left = 796, .top = 420, .right = 1086, .bottom = 458 }, 0x009b9088, .small, .{ .wrap = true });

    for (settings_toggle_rects, [_]Phrase{ .sound_output, .fps_counter, .game_performance }, [_]Phrase{ .sound_output_description, .fps_counter_description, .game_performance_description }, [_]bool{ sound_enabled, show_fps, game_performance }) |rectangle, heading, description, enabled| {
        card(cr, rectangle);
        localizedText(cr, heading, .{ .left = rectangle.left + 20, .top = 476, .right = rectangle.right - 90, .bottom = 501 }, 0x00f4f0ea, .medium, .{});
        localizedText(cr, description, .{ .left = rectangle.left + 20, .top = 507, .right = rectangle.right - 20, .bottom = 544 }, 0x008b817a, .small, .{ .wrap = true });
        drawToggle(cr, rectangle.right - 78, 474, enabled);
    }

    card(cr, .{ .left = 282, .top = 560, .right = 1086, .bottom = 640 });
    localizedText(cr, .graphics_api, .{ .left = 302, .top = 570, .right = 640, .bottom = 595 }, 0x009b9088, .small, .{});
    text(cr, "Vulkan", .{ .left = 310, .top = 603, .right = 640, .bottom = 632 }, 0x00f4f0ea, .medium, .{});
    localizedText(cr, .graphics_api_linux_description, .{ .left = 660, .top = 572, .right = 1066, .bottom = 637 }, 0x00aaa098, .small, .{ .wrap = true });

    card(cr, .{ .left = 282, .top = 650, .right = 1086, .bottom = 714 });
    text(cr, "PS5PCEM", .{ .left = 310, .top = 654, .right = 500, .bottom = 680 }, 0x00f4f0ea, .medium, .{});
    localizedText(cr, .author, .{ .left = 310, .top = 684, .right = 840, .bottom = 708 }, 0x00ffac64, .regular, .{});
    text(cr, "GPL-3.0-or-later", .{ .left = 860, .top = 684, .right = 1048, .bottom = 708 }, 0x008b817a, .regular, .{ .alignment = .right });
}

fn pageHeading(cr: *anyopaque, heading: Phrase, subtitle: Phrase) void {
    pageHeadingBefore(cr, heading, subtitle, update_rect.left - 16);
}

fn pageHeadingBefore(cr: *anyopaque, heading: Phrase, subtitle: Phrase, heading_right: i32) void {
    localizedText(cr, heading, .{ .left = 282, .top = 42, .right = heading_right, .bottom = 82 }, 0x00f4f0ea, .title, .{});
    localizedText(cr, subtitle, .{ .left = 282, .top = 91, .right = 1086, .bottom = 118 }, 0x009b9088, .regular, .{});
    drawUpdateButton(cr);
}

fn drawUpdateButton(cr: *anyopaque) void {
    const background: u32 = if (update_state == .available)
        (if (hovered_update) 0x00ffb366 else 0x00ff9c3d)
    else if (hovered_update and update_state != .checking)
        0x004a3a2e
    else
        0x00342a25;
    roundFill(cr, update_rect, 14, background);
    const label: Phrase = switch (update_state) {
        .idle => .update_check,
        .checking => .update_checking,
        .latest => .update_latest,
        .available => .update_available,
        .failed => .update_failed,
    };
    const colour: u32 = switch (update_state) {
        .idle => 0x00ffac64,
        .checking => 0x009b9088,
        .latest => 0x0068d391,
        .available => 0x00181510,
        .failed => 0x006b77ff,
    };
    localizedText(cr, label, .{ .left = update_rect.left + 6, .top = update_rect.top, .right = update_rect.right - 6, .bottom = update_rect.bottom }, colour, .small, .{ .alignment = .center, .vertical_center = true });
}

fn drawFooter(cr: *anyopaque) void {
    if (status_length == 0) return;
    text(cr, status_text[0..status_length], .{ .left = 600, .top = 124, .right = 1086, .bottom = 146 }, if (status_error) 0x006b77ff else 0x0068d391, .small, .{ .alignment = .right });
}

fn drawModeCard(cr: *anyopaque, mode: InputMode, rectangle: Rect, heading: Phrase, subtitle: Phrase) void {
    const selected = input_mode == mode;
    roundFill(cr, rectangle, 12, if (selected) 0x0042362e else 0x00251f1b);
    if (selected) roundFill(cr, .{ .left = rectangle.left + 14, .top = rectangle.top + 16, .right = rectangle.left + 24, .bottom = rectangle.top + 26 }, 5, 0x00ffac64);
    localizedText(cr, heading, .{ .left = rectangle.left + 36, .top = rectangle.top + 13, .right = rectangle.right - 12, .bottom = rectangle.top + 38 }, 0x00f4f0ea, .medium, .{});
    localizedText(cr, subtitle, .{ .left = rectangle.left + 36, .top = rectangle.top + 44, .right = rectangle.right - 12, .bottom = rectangle.top + 66 }, 0x008b817a, .small, .{});
}

fn drawLanguageCard(cr: *anyopaque, value: Language, rectangle: Rect, label: []const u8) void {
    const selected = language == value;
    roundFill(cr, rectangle, 10, if (selected) 0x0042362e else 0x00251f1b);
    if (selected) roundFill(cr, .{ .left = rectangle.left + 12, .top = rectangle.top + 23, .right = rectangle.left + 22, .bottom = rectangle.top + 33 }, 5, 0x00ffac64);
    text(cr, label, .{ .left = rectangle.left + 30, .top = rectangle.top + 18, .right = rectangle.right - 8, .bottom = rectangle.bottom - 10 }, 0x00f4f0ea, .medium, .{});
}

fn card(cr: *anyopaque, rectangle: Rect) void {
    roundFill(cr, rectangle, 14, 0x00251f1b);
}

fn button(cr: *anyopaque, rectangle: Rect, label: Phrase, disabled: bool) void {
    roundFill(cr, rectangle, 10, if (disabled) 0x00352c27 else 0x00ff9c3d);
    localizedText(cr, label, rectangle, if (disabled) 0x007d736c else 0x00181510, .medium, .{ .alignment = .center, .vertical_center = true });
}

fn drawToggle(cr: *anyopaque, x: i32, y: i32, enabled: bool) void {
    roundFill(cr, .{ .left = x, .top = y, .right = x + 58, .bottom = y + 30 }, 15, if (enabled) 0x00ff9c3d else 0x00483d36);
    const knob_x = if (enabled) x + 32 else x + 4;
    roundFill(cr, .{ .left = knob_x, .top = y + 4, .right = knob_x + 22, .bottom = y + 26 }, 11, 0x00fffaf5);
}

/// Colours are written as on Windows, blue-green-red from high to low, so
/// the two launchers can be compared value for value.
fn setColour(cr: *anyopaque, colour: u32) void {
    const red: f64 = @floatFromInt(colour & 0xff);
    const green: f64 = @floatFromInt((colour >> 8) & 0xff);
    const blue: f64 = @floatFromInt((colour >> 16) & 0xff);
    native.cairo_set_source_rgb(cr, red / 255.0, green / 255.0, blue / 255.0);
}

fn fill(cr: *anyopaque, rectangle: Rect, colour: u32) void {
    setColour(cr, colour);
    native.cairo_new_path(cr);
    native.cairo_rectangle(
        cr,
        @floatFromInt(rectangle.left),
        @floatFromInt(rectangle.top),
        @floatFromInt(rectangle.right - rectangle.left),
        @floatFromInt(rectangle.bottom - rectangle.top),
    );
    native.cairo_fill(cr);
}

/// `diameter` is GDI's RoundRect ellipse size, so the same numbers give the
/// same corners as the Windows launcher.
fn roundFill(cr: *anyopaque, rectangle: Rect, diameter: i32, colour: u32) void {
    const x: f64 = @floatFromInt(rectangle.left);
    const y: f64 = @floatFromInt(rectangle.top);
    const width: f64 = @floatFromInt(rectangle.right - rectangle.left);
    const height: f64 = @floatFromInt(rectangle.bottom - rectangle.top);
    if (width <= 0 or height <= 0) return;
    const radius = @min(@as(f64, @floatFromInt(diameter)) / 2.0, @min(width, height) / 2.0);
    const pi = std.math.pi;
    setColour(cr, colour);
    native.cairo_new_path(cr);
    native.cairo_new_sub_path(cr);
    native.cairo_arc(cr, x + width - radius, y + radius, radius, -pi / 2.0, 0);
    native.cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, pi / 2.0);
    native.cairo_arc(cr, x + radius, y + height - radius, radius, pi / 2.0, pi);
    native.cairo_arc(cr, x + radius, y + radius, radius, pi, 3.0 * pi / 2.0);
    native.cairo_close_path(cr);
    native.cairo_fill(cr);
}

fn drawPixbuf(cr: *anyopaque, pixbuf: *anyopaque, rectangle: Rect) void {
    const width = native.gdk_pixbuf_get_width(pixbuf);
    const height = native.gdk_pixbuf_get_height(pixbuf);
    if (width <= 0 or height <= 0) return;
    native.cairo_save(cr);
    native.cairo_translate(cr, @floatFromInt(rectangle.left), @floatFromInt(rectangle.top));
    native.cairo_scale(
        cr,
        @as(f64, @floatFromInt(rectangle.right - rectangle.left)) / @as(f64, @floatFromInt(width)),
        @as(f64, @floatFromInt(rectangle.bottom - rectangle.top)) / @as(f64, @floatFromInt(height)),
    );
    native.gdk_cairo_set_source_pixbuf(cr, pixbuf, 0, 0);
    native.cairo_paint(cr);
    native.cairo_restore(cr);
}

const TextOptions = struct {
    alignment: enum { left, center, right } = .left,
    ellipsis: enum { end, middle } = .end,
    vertical_center: bool = false,
    /// Wraps at words inside the rectangle and clips what does not fit;
    /// otherwise the text is one line ending in an ellipsis.
    wrap: bool = false,
};

/// Draws UTF-8 text the way the Windows launcher's DrawText calls do. Pango
/// takes the paragraph direction from the text itself, so Arabic reads right
/// to left and its left alignment becomes a right one, as on Windows.
fn text(cr: *anyopaque, value: []const u8, rectangle: Rect, colour: u32, font: Font, options: TextOptions) void {
    if (value.len == 0) return;
    const layout = native.pango_cairo_create_layout(cr) orelse return;
    defer native.g_object_unref(layout);
    const width = rectangle.right - rectangle.left;
    native.pango_layout_set_font_description(layout, fonts[@intFromEnum(font)]);
    native.pango_layout_set_text(layout, value.ptr, @intCast(value.len));
    native.pango_layout_set_width(layout, width * pango_scale);
    native.pango_layout_set_alignment(layout, switch (options.alignment) {
        .left => 0,
        .center => 1,
        .right => 2,
    });
    if (options.wrap) {
        native.pango_layout_set_wrap(layout, 0);
    } else {
        native.pango_layout_set_ellipsize(layout, switch (options.ellipsis) {
            .end => 3,
            .middle => 2,
        });
    }
    var layout_width: c_int = 0;
    var layout_height: c_int = 0;
    native.pango_layout_get_pixel_size(layout, &layout_width, &layout_height);
    var top: f64 = @floatFromInt(rectangle.top);
    if (options.vertical_center) {
        top += @as(f64, @floatFromInt(rectangle.bottom - rectangle.top - layout_height)) / 2.0;
    }
    native.cairo_save(cr);
    if (options.wrap) {
        native.cairo_new_path(cr);
        native.cairo_rectangle(cr, @floatFromInt(rectangle.left), @floatFromInt(rectangle.top), @floatFromInt(width), @floatFromInt(rectangle.bottom - rectangle.top));
        native.cairo_clip(cr);
    }
    setColour(cr, colour);
    native.cairo_move_to(cr, @floatFromInt(rectangle.left), top);
    native.pango_cairo_show_layout(cr, layout);
    native.cairo_restore(cr);
}

fn localizedText(cr: *anyopaque, phrase: Phrase, rectangle: Rect, colour: u32, font: Font, options: TextOptions) void {
    text(cr, tr(phrase), rectangle, colour, font, options);
}

/// The Windows sizes in pixels and weights, in families Linux desktops have.
fn createFonts() void {
    const specifications = [_]struct { size: f64, weight: c_int }{
        .{ .size = 16, .weight = 400 },
        .{ .size = 17, .weight = 600 },
        .{ .size = 27, .weight = 600 },
        .{ .size = 13, .weight = 600 },
    };
    for (&fonts, specifications) |*slot, specification| {
        const description = native.pango_font_description_new() orelse continue;
        native.pango_font_description_set_family(description, "Noto Sans,Ubuntu,Cantarell,DejaVu Sans,Sans");
        native.pango_font_description_set_weight(description, specification.weight);
        native.pango_font_description_set_absolute_size(description, specification.size * pango_scale);
        slot.* = description;
    }
}

fn loadBrandIcon() void {
    const loader = native.gdk_pixbuf_loader_new() orelse return;
    defer native.g_object_unref(loader);
    if (native.gdk_pixbuf_loader_write(loader, app_icon_png.ptr, app_icon_png.len, null) == 0) return;
    if (native.gdk_pixbuf_loader_close(loader, null) == 0) return;
    const pixbuf = native.gdk_pixbuf_loader_get_pixbuf(loader) orelse return;
    // The loader owns its image; the window keeps it for its whole life.
    brand_icon = native.g_object_ref(pixbuf);
}

fn tr(phrase: Phrase) []const u8 {
    return common.translate(language, phrase);
}

fn setStatus(value: []const u8, is_error: bool) void {
    var length = @min(value.len, status_text.len);
    while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
    @memcpy(status_text[0..length], value[0..length]);
    status_length = length;
    status_error = is_error;
}

fn setStatusPhrase(phrase: Phrase, is_error: bool) void {
    setStatus(tr(phrase), is_error);
}

fn setStatusWithVersion(phrase: Phrase, version: []const u8) void {
    const template = tr(phrase);
    var line: [256]u8 = undefined;
    const marker = std.mem.indexOf(u8, template, "{v}") orelse return setStatus(template, false);
    const composed = std.fmt.bufPrint(&line, "{s}{s}{s}", .{ template[0..marker], version, template[marker + 3 ..] }) catch return setStatus(template, false);
    setStatus(composed, false);
}

/// The names of the keys game-run can report on Linux, in Windows
/// virtual-key codes as the mapping stores them.
fn keyDisplayName(key: u8, output: *[16]u8) []const u8 {
    return switch (key) {
        0x08 => "Backspace",
        0x09 => "Tab",
        0x0d => "Enter",
        0x10 => "Shift",
        0x11 => "Ctrl",
        0x12 => "Alt",
        0x1b => "Esc",
        0x20 => "Space",
        0x25 => "Left",
        0x26 => "Up",
        0x27 => "Right",
        0x28 => "Down",
        '0'...'9', 'A'...'Z' => blk: {
            output[0] = key;
            break :blk output[0..1];
        },
        0x70...0x7b => std.fmt.bufPrint(output, "F{d}", .{key - 0x70 + 1}) catch "Key",
        else => std.fmt.bufPrint(output, "Key {d}", .{key}) catch "Key",
    };
}

// ---------------------------------------------------------------------------
// The library.

fn baseNameStart(path: []const u8) usize {
    var start = path.len;
    while (start > 0 and path[start - 1] != '/') : (start -= 1) {}
    return start;
}

/// Paths are compared exactly: Linux file systems tell case apart.
fn sameFolder(first: []const u8, second: []const u8) bool {
    return first.len != 0 and std.mem.eql(u8, first, second);
}

fn childPath(output: []u8, folder: []const u8, suffix: []const u8) ?[:0]const u8 {
    if (folder.len + suffix.len + 1 > output.len) return null;
    @memcpy(output[0..folder.len], folder);
    @memcpy(output[folder.len..][0..suffix.len], suffix);
    output[folder.len + suffix.len] = 0;
    return output[0 .. folder.len + suffix.len :0];
}

fn readSmallFile(path: []const u8, buffer: []u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFile(app_io, path, buffer) catch null;
}

/// Whether a path names a ZArchive dump, by extension.
fn isZarPath(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".zar");
}

/// Opens an archive for a short metadata read. Caller closes.
fn openHelperArchive(path: []const u8) ?*zarchive.Reader {
    const dirname = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);
    var directory = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openDirAbsolute(app_io, dirname, .{}) catch return null
    else
        std.Io.Dir.cwd().openDir(app_io, dirname, .{}) catch return null;
    defer directory.close(app_io);
    return zarchive.Reader.open(app_io, directory, basename, std.heap.smp_allocator) catch null;
}

/// Whether an archive ships an executable at its root.
fn archiveHasEboot(path: []const u8) bool {
    var reader = openHelperArchive(path) orelse return false;
    defer reader.close();
    const node = reader.lookup("eboot.bin") orelse return false;
    return reader.isFile(node);
}

/// Reads a title parameter document out of an archive dump.
fn readArchiveParam(path: []const u8, buffer: []u8) ?[]const u8 {
    var reader = openHelperArchive(path) orelse return null;
    defer reader.close();
    const node = reader.lookup("sce_sys/param.json") orelse return null;
    if (!reader.isFile(node)) return null;
    if (reader.fileSize(node) > buffer.len) return null;
    const size = reader.readAt(node, 0, buffer) catch return null;
    return buffer[0..size];
}

/// Resolves the current selection to an archive dump: either the selection
/// itself or the single `.zar` inside the selected folder.
fn resolveGameArchive(output: []u8) ?[]const u8 {
    if (game_folder_length == 0) return null;
    const folder = game_folder[0..game_folder_length];
    if (isZarPath(folder)) {
        if (folder.len + 1 > output.len) return null;
        @memcpy(output[0..folder.len], folder);
        output[folder.len] = 0;
        return output[0..folder.len];
    }
    return findArchiveInFolder(folder, output);
}

/// A folder holding exactly one top-level `.zar` dump runs it. Anything else
/// keeps the classic layout: an extracted title wins over an archive.
fn findArchiveInFolder(folder: []const u8, output: []u8) ?[]const u8 {
    var directory = if (std.fs.path.isAbsolute(folder))
        std.Io.Dir.openDirAbsolute(app_io, folder, .{ .iterate = true }) catch return null
    else
        std.Io.Dir.cwd().openDir(app_io, folder, .{ .iterate = true }) catch return null;
    defer directory.close(app_io);
    var iterator = directory.iterate();
    var name_storage: [256]u8 = undefined;
    var name_length: usize = 0;
    var count: usize = 0;
    while (iterator.next(app_io) catch null) |entry| {
        if (entry.kind != .file or !isZarPath(entry.name)) continue;
        count += 1;
        if (count > 1 or entry.name.len > name_storage.len) return null;
        // entry.name borrows the iterator; copy before continuing.
        @memcpy(name_storage[0..entry.name.len], entry.name);
        name_length = entry.name.len;
    }
    if (count != 1) return null;
    const name = name_storage[0..name_length];
    if (folder.len + 1 + name.len + 1 > output.len) return null;
    @memcpy(output[0..folder.len], folder);
    output[folder.len] = '/';
    @memcpy(output[folder.len + 1 ..][0..name.len], name);
    output[folder.len + 1 + name.len] = 0;
    return output[0 .. folder.len + 1 + name.len];
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(app_io, path, .{}) catch return false;
    return true;
}

/// Copies whole UTF-8 characters only, so a cut never leaves half of one.
fn copyUtf8(output: []u8, value: []const u8) usize {
    var length = @min(value.len, output.len);
    while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
    @memcpy(output[0..length], value[0..length]);
    return length;
}

fn loadGameIcon(folder: []const u8) ?*anyopaque {
    var path: [1100]u8 = undefined;
    const icon = childPath(&path, folder, "/sce_sys/icon0.png") orelse return null;
    if (!pathExists(icon)) return null;
    return native.gdk_pixbuf_new_from_file_at_scale(icon.ptr, 136, 136, 1, null);
}

fn loadRecentGame(folder: []const u8) ?RecentGame {
    if (folder.len == 0 or folder.len >= 1024) return null;
    var game = RecentGame{};
    @memcpy(game.folder[0..folder.len], folder);
    game.folder_length = folder.len;

    var path: [1100]u8 = undefined;
    if (childPath(&path, folder, "/sce_sys/param.json")) |parameters| {
        var document: [8192]u8 = undefined;
        if (readSmallFile(parameters, &document)) |bytes| {
            if (common.jsonStringValue(bytes, "\"titleName\"")) |value| game.title_length = copyUtf8(&game.title, value);
            if (common.jsonStringValue(bytes, "\"titleId\"")) |value| game.identifier_length = copyUtf8(&game.identifier, value);
        }
    }
    if (game.identifier_length == 0) {
        var archive_storage: [1100]u8 = undefined;
        // A remembered folder may hold an archive instead of an extract.
        const probe = if (isZarPath(folder)) folder else findArchiveInFolder(folder, &archive_storage);
        if (probe) |archive| {
            var document: [8192]u8 = undefined;
            if (readArchiveParam(archive, &document)) |bytes| {
                if (common.jsonStringValue(bytes, "\"titleName\"")) |value| game.title_length = copyUtf8(&game.title, value);
                if (common.jsonStringValue(bytes, "\"titleId\"")) |value| game.identifier_length = copyUtf8(&game.identifier, value);
            }
        }
    }
    if (game.title_length == 0) game.title_length = copyUtf8(&game.title, folder[baseNameStart(folder)..]);
    game.icon = loadGameIcon(folder);
    return game;
}

fn releaseIcon(game: *RecentGame) void {
    if (game.icon) |icon| native.g_object_unref(icon);
    game.icon = null;
}

fn rememberGameFolder(folder: []const u8, persist: bool) void {
    const candidate = loadRecentGame(folder) orelse return;
    var existing: ?usize = null;
    for (recent_games[0..recent_game_count], 0..) |game, index| {
        if (sameFolder(game.folder[0..game.folder_length], folder)) {
            existing = index;
            break;
        }
    }
    if (existing) |index| {
        releaseIcon(&recent_games[index]);
        var cursor = index;
        while (cursor > 0) : (cursor -= 1) recent_games[cursor] = recent_games[cursor - 1];
    } else {
        if (recent_game_count == maximum_recent_games) {
            releaseIcon(&recent_games[maximum_recent_games - 1]);
        } else {
            recent_game_count += 1;
        }
        var cursor = recent_game_count - 1;
        while (cursor > 0) : (cursor -= 1) recent_games[cursor] = recent_games[cursor - 1];
    }
    recent_games[0] = candidate;
    refreshLibraryMatches();
    showLibraryPage(0);
    if (persist) saveSettings();
}

fn removeRecentGame(index: usize) void {
    if (index >= recent_game_count) return;
    const removed_selected = sameFolder(
        recent_games[index].folder[0..recent_games[index].folder_length],
        game_folder[0..game_folder_length],
    );
    releaseIcon(&recent_games[index]);
    var cursor = index;
    while (cursor + 1 < recent_game_count) : (cursor += 1) recent_games[cursor] = recent_games[cursor + 1];
    recent_game_count -= 1;
    recent_games[recent_game_count] = .{};
    hovered_recent_game = null;
    hovered_recent_remove = false;
    refreshLibraryMatches();
    if (removed_selected) {
        @memset(&game_folder, 0);
        game_folder_length = 0;
        refreshTitleIdentifier();
    }
    saveSettings();
    setStatusPhrase(.status_game_removed, false);
}

fn selectGameFolder(folder: []const u8) void {
    @memset(&game_folder, 0);
    game_folder_length = @min(folder.len, game_folder.len - 1);
    @memcpy(game_folder[0..game_folder_length], folder[0..game_folder_length]);
    refreshTitleIdentifier();
}

fn selectRecentGame(index: usize) void {
    if (index >= recent_game_count) return;
    const selected = recent_games[index];
    selectGameFolder(selected.folder[0..selected.folder_length]);
    rememberGameFolder(game_folder[0..game_folder_length], true);
    setStatusPhrase(.status_folder_selected, false);
}

fn refreshTitleIdentifier() void {
    title_identifier_length = 0;
    invalidateSaves();
    if (game_folder_length == 0) return;
    // Use metadata from the same source selected by findGameExecutable:
    // extracted titles take precedence over an archive in the same folder.
    var executable_storage: [1100]u8 = undefined;
    const executable = findGameExecutable(&executable_storage) orelse return;
    var archive_storage: [1100]u8 = undefined;
    if (isZarPath(executable)) {
        const archive = resolveGameArchive(&archive_storage) orelse return;
        var document: [8192]u8 = undefined;
        const bytes = readArchiveParam(archive, &document) orelse return;
        const value = common.jsonStringValue(bytes, "\"titleId\"") orelse return;
        title_identifier_length = copyUtf8(title_identifier[0 .. title_identifier.len - 1], value);
        return;
    }
    var path: [1100]u8 = undefined;
    const parameters = childPath(&path, game_folder[0..game_folder_length], "/sce_sys/param.json") orelse return;
    var document: [8192]u8 = undefined;
    const bytes = readSmallFile(parameters, &document) orelse return;
    const value = common.jsonStringValue(bytes, "\"titleId\"") orelse return;
    title_identifier_length = copyUtf8(title_identifier[0 .. title_identifier.len - 1], value);
}

fn findGameExecutable(output: []u8) ?[:0]const u8 {
    const suffixes = [_][]const u8{ "/eboot.bin", "/decrypted/eboot.bin", "/sce_sys/eboot.bin" };
    for (suffixes) |suffix| {
        const path = childPath(output, game_folder[0..game_folder_length], suffix) orelse continue;
        if (pathExists(path)) return path;
    }
    // No extracted executable: a lone archive dump in the folder runs
    // directly, after proving it ships an executable.
    var archive_storage: [1100]u8 = undefined;
    const archive = resolveGameArchive(&archive_storage) orelse return null;
    if (!archiveHasEboot(archive)) return null;
    if (archive.len + 1 > output.len) return null;
    @memcpy(output[0..archive.len], archive);
    output[archive.len] = 0;
    return output[0..archive.len :0];
}

// ---------------------------------------------------------------------------
// Saves.

const maximum_listed_saves = 12;

const SaveSlot = struct {
    title_id: [32]u8 = @splat(0),
    title_id_length: usize = 0,
    name: [128]u8 = @splat(0),
    name_length: usize = 0,
    detail: [192]u8 = @splat(0),
    detail_length: usize = 0,
};

var save_slots: [maximum_listed_saves]SaveSlot = @splat(.{});
var save_slot_count: usize = 0;
var save_scan_done = false;

fn invalidateSaves() void {
    save_scan_done = false;
}

/// The directory game-run is started in: the launcher's own, or the
/// repository root for a development build in `zig-out/bin`. Installed packages
/// and AppImages use writable XDG data storage for saves, logs and caches.
fn emulatorHomeDirectory(output: []u8) ?[]const u8 {
    var executable: [1024]u8 = undefined;
    const length = std.process.executablePath(app_io, &executable) catch return null;
    var directory = executable[0..baseNameStart(executable[0..length])];
    const development_tail = "zig-out/bin/";
    if (std.mem.endsWith(u8, directory, development_tail)) directory = directory[0 .. directory.len - development_tail.len];
    if (native.g_getenv("APPIMAGE") != null) return userDataDirectory(output);
    std.Io.Dir.cwd().access(app_io, directory, .{ .write = true }) catch return userDataDirectory(output);
    if (directory.len == 0 or directory.len > output.len) return null;
    @memcpy(output[0..directory.len], directory);
    return output[0..directory.len];
}

fn userDataDirectory(output: []u8) ?[]const u8 {
    const base = std.mem.span(native.g_get_user_data_dir());
    const directory = std.fmt.bufPrint(output, "{s}/ps5pcem/", .{base}) catch return null;
    std.Io.Dir.cwd().createDirPath(app_io, directory) catch return null;
    return directory;
}

fn saveRootDirectory(output: []u8) ?[:0]const u8 {
    var home: [1024]u8 = undefined;
    const directory = emulatorHomeDirectory(&home) orelse return null;
    return childPath(output, directory, "savedata");
}

fn scanSaves() void {
    save_slot_count = 0;
    save_scan_done = true;
    var root_storage: [1100]u8 = undefined;
    const root = saveRootDirectory(&root_storage) orelse return;
    var directory = std.Io.Dir.openDirAbsolute(app_io, root, .{ .iterate = true }) catch return;
    defer directory.close(app_io);

    // The selected title first, then every other title, as on Windows.
    const selected = title_identifier[0..title_identifier_length];
    if (selected.len != 0) scanTitleSaveSlots(directory, selected);
    var iterator = directory.iterate();
    while (iterator.next(app_io) catch null) |entry| {
        if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, selected)) continue;
        if (save_slot_count == save_slots.len) break;
        scanTitleSaveSlots(directory, entry.name);
    }
}

fn scanTitleSaveSlots(root: std.Io.Dir, title_id: []const u8) void {
    var title = root.openDir(app_io, title_id, .{ .iterate = true }) catch return;
    defer title.close(app_io);
    var iterator = title.iterate();
    while (iterator.next(app_io) catch null) |entry| {
        if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '.') continue;
        if (save_slot_count == save_slots.len) return;
        var slot = SaveSlot{};
        slot.title_id_length = copyUtf8(&slot.title_id, title_id);
        slot.name_length = copyUtf8(&slot.name, entry.name);
        var path: [512]u8 = undefined;
        if (std.fmt.bufPrint(&path, "{s}/sce_sys/param.txt", .{entry.name})) |relative| {
            var contents: [512]u8 = undefined;
            if (title.readFile(app_io, relative, &contents)) |document| {
                if (parameterValue(document, "title=")) |value| slot.detail_length = copyUtf8(&slot.detail, value);
            } else |_| {}
        } else |_| {}
        save_slots[save_slot_count] = slot;
        save_slot_count += 1;
    }
}

fn parameterValue(document: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, document, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len > key.len and std.mem.startsWith(u8, line, key)) return line[key.len..];
    }
    return null;
}

fn handleSavesClick(x: i32, y: i32) void {
    if (!saves_open_rect.contains(x, y)) return;
    var root_storage: [1100]u8 = undefined;
    const root = saveRootDirectory(&root_storage) orelse return;
    var title_storage: [1200]u8 = undefined;
    if (title_identifier_length != 0) {
        if (std.fmt.bufPrintZ(&title_storage, "{s}/{s}", .{ root, title_identifier[0..title_identifier_length] })) |title| {
            if (pathExists(title)) return openPath(title);
        } else |_| {}
    }
    if (pathExists(root)) openPath(root);
}

// ---------------------------------------------------------------------------
// Actions.

fn openUri(uri: [*:0]const u8) void {
    var failure: ?*GError = null;
    if (native.gtk_show_uri_on_window(main_window, uri, 0, &failure) == 0) {
        if (failure) |value| native.g_error_free(value);
    }
}

fn openPath(path: [:0]const u8) void {
    const uri = native.g_filename_to_uri(path.ptr, null, null) orelse return;
    defer native.g_free(uri);
    openUri(uri);
}

/// Runs a native chooser and returns the selected path in `output`.
fn chooseFile(title: Phrase, action: c_int, pattern: ?[*:0]const u8, output: []u8) ?[]const u8 {
    var title_storage: [256]u8 = undefined;
    const title_z = std.fmt.bufPrintZ(&title_storage, "{s}", .{tr(title)}) catch return null;
    const dialog = native.gtk_file_chooser_native_new(title_z.ptr, main_window, action, null, null) orelse return null;
    defer native.g_object_unref(dialog);
    if (pattern) |glob| {
        if (native.gtk_file_filter_new()) |filter| {
            native.gtk_file_filter_set_name(filter, "PS5 PKG (*.pkg)");
            native.gtk_file_filter_add_pattern(filter, glob);
            native.gtk_file_filter_add_pattern(filter, "*.PKG");
            native.gtk_file_chooser_add_filter(dialog, filter);
        }
    }
    if (native.gtk_native_dialog_run(dialog) != response_accept) return null;
    const chosen = native.gtk_file_chooser_get_filename(dialog) orelse return null;
    defer native.g_free(chosen);
    const value = std.mem.span(chosen);
    if (value.len == 0 or value.len >= output.len) return null;
    @memcpy(output[0..value.len], value);
    return output[0..value.len];
}

fn chooseGameFolder() void {
    var chosen: [1024]u8 = undefined;
    const folder = chooseFile(.browse_dialog, file_chooser_select_folder, null, &chosen) orelse return;
    selectGameFolder(folder);
    clearSearch();
    rememberGameFolder(game_folder[0..game_folder_length], true);
    setStatusPhrase(.status_folder_selected, false);
    syncSearchBox();
}

fn siblingExecutable(name: []const u8, output: []u8) ?[:0]const u8 {
    var executable: [1024]u8 = undefined;
    const length = std.process.executablePath(app_io, &executable) catch return null;
    const directory = executable[0..baseNameStart(executable[0..length])];
    return childPath(output, directory, name);
}

fn launchGame() void {
    if (game_folder_length == 0) {
        setStatusPhrase(.status_choose_folder, true);
        return;
    }
    var executable_storage: [1100]u8 = undefined;
    const executable = findGameExecutable(&executable_storage) orelse {
        setStatusPhrase(.status_eboot_missing, true);
        return;
    };
    var runner_storage: [1100]u8 = undefined;
    const runner = siblingExecutable("game-run", &runner_storage) orelse {
        setStatusPhrase(.status_runner_missing, true);
        return;
    };
    if (!pathExists(runner)) {
        setStatusPhrase(.status_runner_missing, true);
        return;
    }
    var home_storage: [1100]u8 = undefined;
    const home = emulatorHomeDirectory(home_storage[0 .. home_storage.len - 1]) orelse {
        setStatusPhrase(.status_launch_failed, true);
        return;
    };
    home_storage[home.len] = 0;

    // The same contract the Windows launcher sets: game-run inherits it.
    setEnvironment("PS5_AUDIO_DISABLED", if (sound_enabled) null else "1");
    setEnvironment("PS5_SHOW_FPS", if (show_fps) "1" else null);
    setEnvironment(display_mode.environment_name, output_mode.value());
    setEnvironment(performance_mode.environment_name, render_preset.value());
    setEnvironment(graphics_api.environment_name, graphics_api.Api.vulkan.value());
    setEnvironment(frame_limit.environment_name, selected_frame_limit.value());
    setEnvironment("PS5_GAME_PRESET", if (game_performance) "performance" else "default");
    setEnvironment("PS5_INPUT_MODE", switch (input_mode) {
        .controller => "controller",
        .keyboard => "keyboard",
        .hybrid => "hybrid",
    });
    var controller = [_:0]u8{'0' + controller_index};
    setEnvironment("PS5_CONTROLLER_INDEX", &controller);
    var keymap: [512]u8 = undefined;
    setEnvironment("PS5_KEYMAP", buildKeymap(&keymap));

    var folder_storage: [1025]u8 = undefined;
    @memcpy(folder_storage[0..game_folder_length], game_folder[0..game_folder_length]);
    folder_storage[game_folder_length] = 0;
    // Archive dumps run as a single argument; directories keep --app0.
    var argv_storage: [4:null]?[*:0]const u8 = .{ runner.ptr, null, null, null };
    var argv_len: usize = 1;
    if (!isZarPath(executable[0..executable.len])) {
        argv_storage[argv_len] = "--app0";
        argv_len += 1;
        // NUL-terminated at game_folder_length just above.
        argv_storage[argv_len] = @ptrCast(&folder_storage);
        argv_len += 1;
    }
    argv_storage[argv_len] = executable.ptr;
    var failure: ?*GError = null;
    // Without DO_NOT_REAP_CHILD GLib reaps the runner itself, so a game that
    // exits leaves no zombie behind the launcher.
    // home_storage is NUL-terminated where the home path is built.
    if (native.g_spawn_async(@ptrCast(&home_storage), &argv_storage, null, 0, null, null, null, &failure) == 0) {
        var line: [256]u8 = undefined;
        const reason: []const u8 = if (failure) |value| std.mem.span(value.message orelse "") else "";
        setStatus(std.fmt.bufPrint(&line, "{s} · {s}", .{ tr(.status_launch_failed), reason }) catch tr(.status_launch_failed), true);
        if (failure) |value| native.g_error_free(value);
        return;
    }
    rememberGameFolder(game_folder[0..game_folder_length], true);
    setStatusPhrase(.status_launched, false);
    if (main_window) |window| native.gtk_window_iconify(window);
}

fn setEnvironment(comptime name: [:0]const u8, value: ?[:0]const u8) void {
    if (value) |text_value| {
        _ = setenv(name, text_value, 1);
    } else {
        _ = unsetenv(name);
    }
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn buildKeymap(output: *[512]u8) ?[:0]const u8 {
    const names = [_][]const u8{ "cross", "circle", "square", "triangle", "l1", "l2", "r1", "r2", "options", "touch", "up", "right", "down", "left" };
    var stream = std.Io.Writer.fixed(output[0 .. output.len - 1]);
    for (names, mapping, 0..) |name, key, index| {
        if (index != 0) stream.writeByte(',') catch return null;
        stream.print("{s}={d}", .{ name, key }) catch return null;
    }
    const length = stream.buffered().len;
    output[length] = 0;
    return output[0..length :0];
}

// ---------------------------------------------------------------------------
// Package extraction.

fn extractPackage() void {
    var extractor_storage: [1100]u8 = undefined;
    const extractor = siblingExecutable("pkgextractor", &extractor_storage) orelse {
        setStatusPhrase(.status_extractor_missing, true);
        return;
    };
    if (!pathExists(extractor)) {
        setStatusPhrase(.status_extractor_missing, true);
        return;
    }
    var package_storage: [1024]u8 = undefined;
    const package = chooseFile(.extract_pkg_dialog, file_chooser_open, "*.pkg", &package_storage) orelse return;

    // The output folder is the package path without its extension.
    const dot = std.mem.lastIndexOfScalar(u8, package, '.');
    const output_length = if (dot) |at| (if (at > baseNameStart(package)) at else package.len) else package.len;
    var package_z: [1025]u8 = undefined;
    @memcpy(package_z[0..package.len], package);
    package_z[package.len] = 0;
    var output_z: [1025]u8 = undefined;
    @memcpy(output_z[0..output_length], package[0..output_length]);
    output_z[output_length] = 0;

    const argv = [_:null]?[*:0]const u8{ extractor.ptr, @ptrCast(&package_z), "-o", @ptrCast(&output_z) };
    var pid: c_int = 0;
    var output_fd: c_int = -1;
    var failure: ?*GError = null;
    if (native.g_spawn_async_with_pipes(null, &argv, null, spawn_do_not_reap_child, &mergeStandardError, null, &pid, null, &output_fd, null, &failure) == 0) {
        if (failure) |value| native.g_error_free(value);
        setStatusPhrase(.status_extract_failed, true);
        return;
    }

    lockExtractFeed();
    extract_feed = .{};
    extract_full_log.clearRetainingCapacity();
    extract_lock.unlock();
    extract_dirty.store(false, .release);
    @memcpy(extract_output[0..output_length], package[0..output_length]);
    extract_output_length = output_length;
    extract_name_length = copyUtf8(&extract_name, package[baseNameStart(package)..]);

    const reader = std.Thread.spawn(.{}, readExtractorOutput, .{ output_fd, pid }) catch {
        _ = std.c.kill(pid, std.c.SIG.TERM);
        _ = std.c.close(output_fd);
        setStatusPhrase(.status_extract_failed, true);
        return;
    };
    reader.detach();
    extract_pid = pid;
    extract_state = .running;
    extract_result = .extract_running;
    status_length = 0;
    syncSearchBox();
    _ = native.g_timeout_add(100, &extractTick, null);
}

/// Runs in the extractor after the pipes are in place: the Windows launcher
/// gives it one pipe for both streams, and so does this.
fn mergeStandardError(_: ?*anyopaque) callconv(.c) void {
    _ = std.c.dup2(1, 2);
}

fn extractTick(_: ?*anyopaque) callconv(.c) c_int {
    if (extract_dirty.swap(false, .acq_rel)) redraw();
    return @intFromBool(extract_state == .running);
}

fn lockExtractFeed() void {
    while (!extract_lock.tryLock()) std.atomic.spinLoopHint();
}

fn readExtractorOutput(fd: c_int, pid: c_int) void {
    var chunk: [4096]u8 = undefined;
    var line: [512]u8 = undefined;
    var line_length: usize = 0;
    while (true) {
        const read = std.c.read(fd, &chunk, chunk.len);
        if (read <= 0) {
            if (read < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            break;
        }
        for (chunk[0..@intCast(read)]) |byte| {
            if (byte == '\n') {
                acceptExtractorLine(line[0..line_length]);
                line_length = 0;
            } else if (byte != '\r' and line_length < line.len) {
                line[line_length] = byte;
                line_length += 1;
            }
        }
    }
    if (line_length != 0) acceptExtractorLine(line[0..line_length]);
    _ = std.c.close(fd);
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) break;
    }
    const exited = (status & 0x7f) == 0;
    const code: usize = if (exited) @intCast((status >> 8) & 0xff) else 1;
    // Zero cannot travel through the pointer, so the code is offset by one.
    _ = native.g_idle_add(&extractFinishedIdle, @ptrFromInt(code + 1));
}

fn acceptExtractorLine(raw: []const u8) void {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return;
    if (std.mem.startsWith(u8, value, "progress ")) {
        var fields = std.mem.tokenizeScalar(u8, value["progress ".len..], ' ');
        const done = std.fmt.parseInt(u64, fields.next() orelse return, 10) catch return;
        const total = std.fmt.parseInt(u64, fields.next() orelse return, 10) catch return;
        lockExtractFeed();
        extract_feed.done = done;
        extract_feed.total = total;
        extract_lock.unlock();
        extract_dirty.store(true, .release);
        return;
    }
    var length = value.len;
    while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
    if (length == 0) return;
    var drawn = @min(length, extract_log_bytes);
    while (drawn > 0 and !std.unicode.utf8ValidateSlice(value[0..drawn])) drawn -= 1;
    lockExtractFeed();
    if (extract_full_log.items.len + length + 1 <= extract_full_log_limit) {
        extract_full_log.appendSlice(std.heap.page_allocator, value[0..length]) catch {};
        extract_full_log.append(std.heap.page_allocator, '\n') catch {};
    }
    const slot = extract_feed.log_next;
    @memcpy(extract_feed.log[slot][0..drawn], value[0..drawn]);
    extract_feed.log_lengths[slot] = @intCast(drawn);
    extract_feed.log_next = (slot + 1) % extract_log_capacity;
    extract_feed.log_count = @min(extract_feed.log_count + 1, extract_log_capacity);
    extract_lock.unlock();
    extract_dirty.store(true, .release);
}

fn extractFinishedIdle(data: ?*anyopaque) callconv(.c) c_int {
    const exit_code = @intFromPtr(data) - 1;
    extract_pid = 0;
    finishExtraction(exit_code);
    syncSearchBox();
    redraw();
    return 0;
}

fn finishExtraction(exit_code: usize) void {
    if (exit_code != 0) {
        extract_state = .failed;
        extract_result = if (exit_code == 2) .status_extract_retail else .status_extract_failed;
        setStatusPhrase(extract_result, true);
        return;
    }
    selectGameFolder(extract_output[0..extract_output_length]);
    clearSearch();
    rememberGameFolder(game_folder[0..game_folder_length], true);
    var eboot: [1100]u8 = undefined;
    const found = findGameExecutable(&eboot) != null;
    extract_state = if (found) .succeeded else .failed;
    extract_result = if (found) .status_extracted else .status_extracted_no_eboot;
    setStatusPhrase(extract_result, !found);
}

fn copyExtractLog() void {
    lockExtractFeed();
    defer extract_lock.unlock();
    const atom = native.gdk_atom_intern("CLIPBOARD", 0);
    const clipboard = native.gtk_clipboard_get(atom) orelse return;
    const log = extract_full_log.items;
    native.gtk_clipboard_set_text(clipboard, log.ptr, @intCast(log.len));
    setStatusPhrase(.status_log_copied, false);
}

// ---------------------------------------------------------------------------
// Update check.

fn handleUpdateClick() void {
    switch (update_state) {
        .checking => {},
        .available => openUri(releases_url),
        .idle, .latest, .failed => {
            update_state = .checking;
            const checker = std.Thread.spawn(.{}, checkLatestRelease, .{}) catch {
                finishUpdateCheck(false);
                return;
            };
            checker.detach();
        },
    }
}

/// Runs on its own thread: a slow or unreachable network must not freeze the
/// window. The answer returns to the window thread through an idle call.
fn checkLatestRelease() void {
    const found = fetchLatestReleaseTag();
    _ = native.g_idle_add(&updateCheckedIdle, @ptrFromInt(@as(usize, @intFromBool(found)) + 1));
}

fn fetchLatestReleaseTag() bool {
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = app_io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    const result = client.fetch(.{
        .location = .{ .url = latest_release_url },
        .response_writer = &body.writer,
        // GitHub refuses requests without a User-Agent.
        .headers = .{ .user_agent = .{ .override = "PS5PCEM-Launcher/" ++ build_options.release_version } },
        .extra_headers = &.{.{ .name = "Accept", .value = "application/vnd.github+json" }},
    }) catch return false;
    if (result.status != .ok) return false;
    const tag = common.jsonStringValue(body.written(), "\"tag_name\"") orelse return false;
    if (tag.len == 0 or tag.len > update_remote_tag.len or common.parseReleaseVersion(tag) == null) return false;
    @memcpy(update_remote_tag[0..tag.len], tag);
    update_remote_tag_length = tag.len;
    return true;
}

fn updateCheckedIdle(data: ?*anyopaque) callconv(.c) c_int {
    finishUpdateCheck(@intFromPtr(data) == 2);
    redraw();
    return 0;
}

fn finishUpdateCheck(found: bool) void {
    const remote = if (found) common.parseReleaseVersion(update_remote_tag[0..update_remote_tag_length]) else null;
    const local = common.parseReleaseVersion(build_options.release_version);
    if (remote == null or local == null) {
        update_state = .failed;
        setStatusPhrase(.status_update_failed, true);
        return;
    }
    if (common.isNewerRelease(remote.?, local.?)) {
        update_state = .available;
        setStatusWithVersion(.status_update_available, common.versionDigits(update_remote_tag[0..update_remote_tag_length]));
    } else {
        update_state = .latest;
        setStatusWithVersion(.status_update_latest, build_options.release_version);
    }
}

// ---------------------------------------------------------------------------
// Vulkan.

fn probeVulkan() void {
    var library = std.DynLib.open("libvulkan.so.1") catch {
        vulkan_report.state = .no_loader;
        return;
    };
    // Kept loaded: unloading a driver right after use is a known source of
    // crashes in some of them, and the probe runs once.
    vulkan_report = common.probeVulkan(library.lookup(common.GetInstanceProcAddr, "vkGetInstanceProcAddr"));
}

// ---------------------------------------------------------------------------
// Settings, in the Windows launcher's ps5pcem.ini layout.

/// Beside the executable, as on Windows, unless that directory is not the
/// user's to write, as for a system-wide install; then the XDG config home.
fn initializeIniPath() void {
    if (native.g_getenv("APPIMAGE") != null) return initializeConfigIniPath();
    var executable: [1024]u8 = undefined;
    if (std.process.executablePath(app_io, &executable)) |length| {
        const directory = executable[0..baseNameStart(executable[0..length])];
        std.Io.Dir.cwd().access(app_io, directory, .{ .write = true }) catch {
            return initializeConfigIniPath();
        };
        if (childPath(&ini_path, directory, "ps5pcem.ini")) |path| ini_path_length = path.len;
    } else |_| initializeConfigIniPath();
}

fn initializeConfigIniPath() void {
    const config = std.mem.span(native.g_get_user_config_dir());
    var directory: [1024]u8 = undefined;
    const folder = std.fmt.bufPrint(&directory, "{s}/ps5pcem", .{config}) catch return;
    std.Io.Dir.cwd().createDirPath(app_io, folder) catch return;
    if (childPath(&ini_path, folder, "/ps5pcem.ini")) |path| ini_path_length = path.len;
}

const Section = enum { none, launcher, keymap, recent };

fn loadSettings() void {
    if (ini_path_length == 0) return;
    var document: [96 * 1024]u8 = undefined;
    const contents = readSmallFile(ini_path[0..ini_path_length], &document) orelse return;
    var recent_paths: [maximum_recent_games]?[]const u8 = @splat(null);
    var section: Section = .none;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[') {
            const name = std.mem.trim(u8, line[1 .. std.mem.indexOfScalar(u8, line, ']') orelse line.len], " \t");
            section = std.meta.stringToEnum(Section, name) orelse .none;
            continue;
        }
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        switch (section) {
            .launcher => applyLauncherSetting(key, value),
            .keymap => if (std.mem.startsWith(u8, key, "key_")) {
                const index = std.fmt.parseInt(usize, key["key_".len..], 10) catch continue;
                const code = std.fmt.parseInt(u32, value, 10) catch continue;
                if (index < mapping.len and code < 256) mapping[index] = @intCast(code);
            },
            .recent => if (std.mem.startsWith(u8, key, "path_")) {
                const index = std.fmt.parseInt(usize, key["path_".len..], 10) catch continue;
                if (index < recent_paths.len and value.len != 0) recent_paths[index] = value;
            },
            .none => {},
        }
    }
    for (recent_paths) |maybe_path| {
        const path = maybe_path orelse continue;
        if (recent_game_count == maximum_recent_games) break;
        const game = loadRecentGame(path) orelse continue;
        recent_games[recent_game_count] = game;
        recent_game_count += 1;
    }
    refreshLibraryMatches();
    if (game_folder_length != 0) {
        refreshTitleIdentifier();
        rememberGameFolder(game_folder[0..game_folder_length], false);
    }
}

fn applyLauncherSetting(key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "game_folder")) {
        game_folder_length = @min(value.len, game_folder.len - 1);
        @memcpy(game_folder[0..game_folder_length], value[0..game_folder_length]);
        return;
    }
    const number = std.fmt.parseInt(u32, value, 10) catch return;
    if (std.mem.eql(u8, key, "sound")) {
        sound_enabled = number != 0;
    } else if (std.mem.eql(u8, key, "show_fps")) {
        show_fps = number != 0;
    } else if (std.mem.eql(u8, key, "fps_limit")) {
        selected_frame_limit = frame_limit.Limit.fromHz(number) orelse frame_limit.default;
    } else if (std.mem.eql(u8, key, "output_resolution")) {
        output_mode = display_mode.Mode.fromHeight(number) orelse display_mode.default;
    } else if (std.mem.eql(u8, key, "render_preset")) {
        render_preset = performance_mode.Mode.fromIndex(number) orelse performance_mode.default;
    } else if (std.mem.eql(u8, key, "game_performance")) {
        game_performance = number != 0;
    } else if (std.mem.eql(u8, key, "input_mode")) {
        if (number <= 2) input_mode = @enumFromInt(number);
    } else if (std.mem.eql(u8, key, "language")) {
        if (number < @typeInfo(Language).@"enum".fields.len) language = @enumFromInt(number);
    } else if (std.mem.eql(u8, key, "controller_index")) {
        if (number <= 3) controller_index = @intCast(number);
    } else if (std.mem.eql(u8, key, "library_view")) {
        if (number < @typeInfo(LibraryView).@"enum".fields.len) library_view = @enumFromInt(number);
    }
}

/// Writes the whole file: the launcher is its only writer, and a complete
/// rewrite cannot leave a half-updated section behind.
fn saveSettings() void {
    if (ini_path_length == 0) return;
    var document: [96 * 1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&document);
    writeSettings(&stream) catch return;
    std.Io.Dir.cwd().writeFile(app_io, .{ .sub_path = ini_path[0..ini_path_length], .data = stream.buffered() }) catch {};
}

fn writeSettings(stream: *std.Io.Writer) !void {
    try stream.writeAll("[launcher]\n");
    try stream.print("game_folder={s}\n", .{game_folder[0..game_folder_length]});
    try stream.print("sound={d}\n", .{@intFromBool(sound_enabled)});
    try stream.print("show_fps={d}\n", .{@intFromBool(show_fps)});
    try stream.print("output_resolution={d}\n", .{output_mode.height()});
    try stream.writeAll("graphics_api=vulkan\n");
    try stream.print("fps_limit={d}\n", .{selected_frame_limit.hz()});
    try stream.print("render_preset={d}\n", .{@intFromEnum(render_preset)});
    try stream.print("game_performance={d}\n", .{@intFromBool(game_performance)});
    try stream.print("input_mode={d}\n", .{@intFromEnum(input_mode)});
    try stream.print("language={d}\n", .{@intFromEnum(language)});
    try stream.print("controller_index={d}\n", .{controller_index});
    try stream.print("library_view={d}\n", .{@intFromEnum(library_view)});
    try stream.writeAll("[keymap]\n");
    for (mapping, 0..) |key, index| try stream.print("key_{d}={d}\n", .{ index, key });
    try stream.writeAll("[recent]\n");
    for (recent_games[0..recent_game_count], 0..) |game, index| {
        try stream.print("path_{d}={s}\n", .{ index, game.folder[0..game.folder_length] });
    }
}

// ---------------------------------------------------------------------------

test "save parameters read only the title record" {
    try std.testing.expectEqualStrings("Ghost of Yotei", parameterValue("version=1\r\ntitle=Ghost of Yotei\r\ndetail=x\n", "title=").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parameterValue("detail=title=no\n", "title="));
}

test "key names cover every key the Linux window reports" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Space", keyDisplayName(0x20, &buffer));
    try std.testing.expectEqualStrings("W", keyDisplayName('W', &buffer));
    try std.testing.expectEqualStrings("F12", keyDisplayName(0x7b, &buffer));
    for (0..0x10000) |keysym| {
        const key = input.virtualKeyFromKeysym(keysym) orelse continue;
        try std.testing.expect(!std.mem.startsWith(u8, keyDisplayName(key, &buffer), "Key"));
    }
}

test "UTF-8 copies stop at a character boundary" {
    var output: [4]u8 = undefined;
    // "Приз" is eight bytes; four of them hold two whole letters.
    try std.testing.expectEqual(@as(usize, 4), copyUtf8(&output, "Приз"));
    try std.testing.expectEqualStrings("Пр", output[0..4]);
    var short: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), copyUtf8(&short, "Приз"));
}

test "settings round-trip through the ps5pcem.ini layout" {
    mapping[0] = 'Z';
    defer mapping = mapping_defaults;
    language = .russian;
    defer language = .english;
    var document: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&document);
    try writeSettings(&stream);
    const written = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "[keymap]\nkey_0=90\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "language=1\n") != null);
}

test "the keymap names every binding for game-run" {
    var output: [512]u8 = undefined;
    const keymap = buildKeymap(&output).?;
    try std.testing.expect(std.mem.startsWith(u8, keymap, "cross=32,circle=69,"));
    try std.testing.expect(std.mem.endsWith(u8, keymap, ",left=37"));
}
