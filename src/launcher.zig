// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Native Windows launcher for PS5PCEM.
//!
//! The interface deliberately uses only Win32/GDI so the emulator keeps its
//! zero-dependency build. Settings are persisted next to the executable and
//! passed to game-run through its small environment contract.

const std = @import("std");
const input = @import("input");
const build_options = @import("build_options");
const builtin = @import("builtin");
const display_mode = @import("display_mode.zig");
const performance_mode = @import("performance_mode.zig");
const graphics_api = @import("graphics_api.zig");
const frame_limit = @import("frame_limit.zig");

comptime {
    // The interface contains a fair amount of Cyrillic text converted to
    // UTF-16 at compile time.
    @setEvalBranchQuota(20_000);
}

const site_url = "https://ps5pcem.com";
/// Where a newer release is downloaded. `latest` redirects to the newest
/// published release; the API below reports the same one.
const releases_url = "https://github.com/iStark/PS5PCEM/releases/latest";
const latest_release_host = "api.github.com";
const latest_release_path = "/repos/iStark/PS5PCEM/releases/latest";
const github_url = "https://github.com/iStark/PS5PCEM";
const boosty_url = "https://boosty.to/ps5pcem";
const window_width = 1180;
const window_height = 760;
const sidebar_width = 222;

const Page = enum { library, input, saves, settings };
const InputMode = enum(u8) { controller = 0, keyboard = 1, hybrid = 2 };
const common = @import("launcher_common.zig");
const Language = common.Language;
const language_labels = common.language_labels;
const Phrase = common.Phrase;
const parseReleaseVersion = common.parseReleaseVersion;
const versionDigits = common.versionDigits;
const isNewerRelease = common.isNewerRelease;
const jsonStringValue = common.jsonStringValue;

test {
    // The shared files' own tests run with each launcher's.
    _ = common;
    _ = frame_limit;
}

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

var current_page: Page = .library;
var input_mode: InputMode = .hybrid;
var language: Language = .english;
var controller_index: u8 = 0;
/// What the HID scan last saw. Polled on a timer rather than during paint so
/// the answer does not depend on how often the window happens to redraw.
var pad_presence: input.hid.Presence = .{};
const pad_timer_id: usize = 1;
const pad_test_timer_id: usize = 2;
/// How often the self-test advances. Fine enough that the colours read as a
/// sweep rather than a slideshow.
const pad_test_tick_ms: u32 = 40;
var current_window: Win32.Window = null;
var sound_enabled = true;
var show_fps = false;
var output_mode = display_mode.default;
var render_preset = performance_mode.default;
var selected_graphics_api = graphics_api.default;
var selected_frame_limit = frame_limit.default;
var game_performance = true;
var mapping = mapping_defaults;
var capture_mapping: ?usize = null;
var game_folder: [1024]u16 = [_]u16{0} ** 1024;
var game_folder_length: usize = 0;
/// Six pages of eight. The grid shows one page at a time, so the ceiling is
/// about how many titles are worth keeping, not about how many fit on screen.
const maximum_recent_games = 48;
/// One page of the library: four columns by two rows in the grid, or eight
/// rows in the table. Both views page alike, so switching keeps the count.
const library_page_size = 8;
// Saved as a number in the settings file; keep the existing values.
const LibraryView = enum(u8) { grid = 0, table = 1 };
var library_view: LibraryView = .grid;
/// Positions in `recent_games` that pass the search, in library order. With no
/// search text every game passes, so paging always works on this list.
var library_matches: [maximum_recent_games]u8 = undefined;
var library_match_count: usize = 0;
var search_text: [128]u16 = @splat(0);
var search_length: usize = 0;
/// A native edit control, so typing gets the caret, selection, clipboard and
/// IME composition Windows already provides. It is hidden behind a drawn
/// placeholder until the search is used, and while it holds no text.
var search_edit: Win32.Window = null;
var search_edit_original: isize = 0;
/// Whether the edit control is on screen; the placeholder is drawn otherwise.
var search_shown = false;
var search_brush: Win32.Brush = null;
const search_edit_id: usize = 100;
const RecentGame = struct {
    folder: [1024]u16 = @splat(0),
    folder_length: usize = 0,
    title: [128]u16 = @splat(0),
    title_length: usize = 0,
    identifier: [32]u16 = @splat(0),
    identifier_length: usize = 0,
    icon: Win32.Bitmap = null,
};
var recent_games: [maximum_recent_games]RecentGame = @splat(.{});
var recent_game_count: usize = 0;
var hovered_recent_game: ?usize = null;
var hovered_recent_remove = false;
var library_page: usize = 0;
var hovered_library_arrow: ?u1 = null;
var tracking_mouse_leave = false;
/// The product code the selected title publishes about itself. Saves are keyed
/// by it, so without one there is no directory to show.
var title_identifier: [32]u16 = @splat(0);
var title_identifier_length: usize = 0;
/// A package extraction runs in pkgextractor.exe while the window stays
/// responsive. Its output arrives on a pipe read by a background thread; the
/// window thread owns everything else here and repaints on a timer.
const ExtractState = enum { idle, running, succeeded, failed };
var extract_state: ExtractState = .idle;
var extract_process: Win32.Handle = null;
var extract_result: Phrase = .extract_running;
var extract_name: [260]u16 = @splat(0);
var extract_name_length: usize = 0;
var extract_output: [1024]u16 = @splat(0);
var extract_output_length: usize = 0;
const extract_timer_id: usize = 3;
const wm_extract_finished: u32 = Win32.wm_app + 1;
/// Posted by the update check with 1 when `update_remote_tag` holds the latest
/// release tag and 0 when GitHub could not be asked.
const wm_update_checked: u32 = Win32.wm_app + 2;
const UpdateState = enum { idle, checking, latest, available, failed };
var update_state: UpdateState = .idle;
var hovered_update = false;
/// Written by the checking thread before it posts its message, read by the
/// window thread after it arrives.
var update_remote_tag: [32]u8 = undefined;
var update_remote_tag_length: usize = 0;
const extract_log_capacity = 8;
const extract_log_bytes = 200;
/// Shared with the reader thread, under `extract_lock`.
const ExtractFeed = struct {
    done: u64 = 0,
    total: u64 = 0,
    log: [extract_log_capacity][extract_log_bytes]u8 = undefined,
    log_lengths: [extract_log_capacity]u8 = @splat(0),
    log_next: usize = 0,
    log_count: usize = 0,
};
var extract_feed: ExtractFeed = .{};
/// Every line the extractor printed except progress, for "Copy log". Also
/// under `extract_lock`; capped so a runaway stream cannot exhaust memory.
var extract_full_log: std.ArrayList(u8) = .empty;
const extract_full_log_limit = 8 * 1024 * 1024;
var extract_lock: std.atomic.Mutex = .unlocked;
var extract_dirty: std.atomic.Value(bool) = .init(false);
const extract_panel_rect = Rect{ .left = 282, .top = 158, .right = 1086, .bottom = 510 };
const extract_copy_rect = Rect{ .left = 882, .top = 174, .right = 1062, .bottom = 208 };

var status_text: [256]u16 = [_]u16{0} ** 256;
var status_length: usize = 0;
var status_error = false;
var ini_path: [1024]u16 = [_]u16{0} ** 1024;
var ini_path_length: usize = 0;
var regular_font: Win32.Font = null;
var medium_font: Win32.Font = null;
var title_font: Win32.Font = null;
var small_font: Win32.Font = null;
var application_icon: Win32.Icon = null;
var gdiplus_ready = false;

fn tr(phrase: Phrase) []const u8 {
    return common.translate(language, phrase);
}

pub fn main(_: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    _ = Win32.SetProcessDpiAwarenessContext(Win32.dpi_awareness_per_monitor_v2);
    _ = Win32.CoInitializeEx(null, Win32.coinit_apartment_threaded);
    defer Win32.CoUninitialize();

    var gdiplus_token: usize = 0;
    const gdiplus_input = Win32.GdiplusStartupInput{};
    gdiplus_ready = Win32.GdiplusStartup(&gdiplus_token, &gdiplus_input, null) == 0;
    defer if (gdiplus_ready) {
        Win32.GdiplusShutdown(gdiplus_token);
        gdiplus_ready = false;
    };

    initializeIniPath();
    loadSettings();
    // Once, before the window exists: the answer never changes while the
    // launcher runs, and asking per repaint would load the loader every frame.
    probeVulkan();
    defer destroyRecentGames();
    createFonts();
    defer destroyFonts();

    const instance = Win32.GetModuleHandleW(null) orelse return error.WindowCreationFailed;
    application_icon = Win32.LoadIconW(instance, Win32.app_icon_resource);
    const class = Win32.WndClassExW{
        .size = @sizeOf(Win32.WndClassExW),
        .style = Win32.class_redraw,
        .window_procedure = windowProcedure,
        .class_extra = 0,
        .window_extra = 0,
        .instance = instance,
        .icon = application_icon,
        .cursor = Win32.LoadCursorW(null, Win32.arrow_cursor),
        .background = null,
        .menu_name = null,
        .class_name = w("PS5PCEM_LAUNCHER"),
        .small_icon = application_icon,
    };
    if (Win32.RegisterClassExW(&class) == 0 and Win32.GetLastError() != Win32.error_class_already_exists) {
        return error.WindowCreationFailed;
    }

    // CreateWindowExW sizes the whole window, frame included, so passing the
    // layout size directly left the client area short of it. The bottom row of
    // the page fell outside and was clipped away, and a taller caption at a
    // higher DPI took more of it.
    var outer = Win32.NativeRect{ .left = 0, .top = 0, .right = window_width, .bottom = window_height };
    _ = Win32.AdjustWindowRect(&outer, Win32.window_style, 0);
    const window = Win32.CreateWindowExW(
        0,
        w("PS5PCEM_LAUNCHER"),
        w("PS5PCEM — Launcher"),
        Win32.window_style,
        Win32.centered,
        Win32.centered,
        outer.right - outer.left,
        outer.bottom - outer.top,
        null,
        null,
        instance,
        null,
    ) orelse return error.WindowCreationFailed;
    createSearchEdit(window, instance);
    defer if (search_brush != null) {
        _ = Win32.DeleteObject(search_brush);
    };
    var dark: i32 = 1;
    _ = Win32.DwmSetWindowAttribute(window, 20, &dark, @sizeOf(i32));
    _ = Win32.ShowWindow(window, Win32.show_normal);
    _ = Win32.UpdateWindow(window);
    // Half a second is fast enough to feel immediate for a pad that is plugged
    // in while the launcher is open, and rare enough that the HID scan costs
    // nothing noticeable when none is attached.
    current_window = window;
    pad_presence = input.hid.presence();
    _ = Win32.SetTimer(window, pad_timer_id, 500, null);

    var message: Win32.Message = undefined;
    while (Win32.GetMessageW(&message, null, 0, 0) > 0) {
        _ = Win32.TranslateMessage(&message);
        _ = Win32.DispatchMessageW(&message);
    }
}

fn windowProcedure(
    window: Win32.Window,
    message: u32,
    word_parameter: usize,
    long_parameter: isize,
) callconv(.winapi) isize {
    switch (message) {
        Win32.wm_paint => {
            paint(window);
            return 0;
        },
        Win32.wm_erase_background => return 1,
        Win32.wm_timer => {
            if (word_parameter == extract_timer_id) {
                if (extract_dirty.swap(false, .acq_rel)) invalidateExtractPanel(window);
                return 0;
            }
            if (word_parameter == pad_test_timer_id) {
                if (!input.hid.advanceTest(pad_test_tick_ms)) {
                    _ = Win32.KillTimer(window, pad_test_timer_id);
                    _ = Win32.InvalidateRect(window, null, 0);
                }
                return 0;
            }
            const found = input.hid.presence();
            if (found.connected != pad_presence.connected or found.family != pad_presence.family) {
                pad_presence = found;
                _ = Win32.InvalidateRect(window, null, 0);
            }
            return 0;
        },
        Win32.wm_device_change => {
            // A pad that was just plugged in should appear now, not at the end
            // of the scan interval.
            input.hid.invalidate();
            pad_presence = input.hid.presence();
            _ = Win32.InvalidateRect(window, null, 0);
            return 0;
        },
        Win32.wm_mouse_move => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(long_parameter))))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(long_parameter)) >> 16))));
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
                _ = Win32.InvalidateRect(window, null, 0);
            }
            if (!tracking_mouse_leave) {
                var tracking = Win32.TrackMouseEventData{
                    .size = @sizeOf(Win32.TrackMouseEventData),
                    .flags = Win32.tme_leave,
                    .window = window,
                    .hover_time = 0,
                };
                tracking_mouse_leave = Win32.TrackMouseEvent(&tracking) != 0;
            }
            return 0;
        },
        Win32.wm_mouse_wheel => {
            if (current_page == .library and extract_state == .idle) {
                const delta: i16 = @bitCast(@as(u16, @truncate(word_parameter >> 16)));
                // Away from the user is back towards the first page, the
                // direction a list scrolls under the same gesture everywhere
                // else. Pages are the only unit this grid has, so a notch is
                // a page.
                if (delta != 0 and stepLibraryPage(if (delta < 0) 1 else -1)) {
                    _ = Win32.InvalidateRect(window, null, 0);
                }
            }
            return 0;
        },
        Win32.wm_mouse_leave => {
            tracking_mouse_leave = false;
            if (hovered_recent_game != null or hovered_recent_remove or hovered_library_arrow != null or hovered_update) {
                hovered_recent_game = null;
                hovered_recent_remove = false;
                hovered_library_arrow = null;
                hovered_update = false;
                _ = Win32.InvalidateRect(window, null, 0);
            }
            return 0;
        },
        Win32.wm_set_cursor => {
            // Only the client area; the frame keeps the cursors Windows gives
            // it for sizing and the system menu.
            if (@as(u16, @truncate(@as(usize, @bitCast(long_parameter)))) == Win32.hit_test_client) {
                var point = Win32.NativePoint{};
                if (Win32.GetCursorPos(&point) != 0 and Win32.ScreenToClient(window, &point) != 0) {
                    if (searchPlaceholderAt(point.x, point.y)) {
                        _ = Win32.SetCursor(Win32.LoadCursorW(null, Win32.ibeam_cursor));
                        return 1;
                    }
                    const over = clickableAt(point.x, point.y);
                    _ = Win32.SetCursor(Win32.LoadCursorW(null, if (over) Win32.hand_cursor else Win32.arrow_cursor));
                    return 1;
                }
            }
        },
        Win32.wm_left_button_down => {
            // A click anywhere outside the search box ends typing there. Clicks
            // inside the edit control go to the control and never reach here.
            if (search_edit != null and Win32.GetFocus() == search_edit) _ = Win32.SetFocus(window);
            return 0;
        },
        Win32.wm_left_button_up => {
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(long_parameter))))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(long_parameter)) >> 16))));
            handleClick(window, x, y);
            syncSearchBox(window);
            return 0;
        },
        Win32.wm_command => {
            const notification: u16 = @truncate(word_parameter >> 16);
            if ((word_parameter & 0xffff) == search_edit_id) {
                if (notification == Win32.en_change) readSearchText();
                if (notification == Win32.en_change or notification == Win32.en_kill_focus) {
                    syncSearchBox(window);
                    _ = Win32.InvalidateRect(window, null, 0);
                }
                return 0;
            }
        },
        Win32.wm_control_color_edit => {
            const dc: Win32.DeviceContext = @ptrFromInt(word_parameter);
            _ = Win32.SetTextColor(dc, 0x00f4f0ea);
            _ = Win32.SetBkColor(dc, search_box_colour);
            return @bitCast(@intFromPtr(search_brush));
        },
        Win32.wm_char => {
            // Typing on the library starts a search with that character, so a
            // long library is filtered without reaching for the mouse first.
            // A space does not: on its own it would match nearly every title.
            if (capture_mapping == null and libraryToolbarVisible() and
                word_parameter > 0x20 and word_parameter != 0x7f)
            {
                activateSearch(window);
                _ = Win32.SendMessageW(search_edit, Win32.wm_char, word_parameter, long_parameter);
                return 0;
            }
        },
        Win32.wm_key_down => {
            if (capture_mapping == null and word_parameter == 'F' and
                Win32.GetKeyState(Win32.vk_control) < 0 and libraryToolbarVisible())
            {
                activateSearch(window);
                return 0;
            }
            if (capture_mapping) |index| {
                if (word_parameter == 0x1b) {
                    capture_mapping = null;
                } else if (word_parameter < 256) {
                    mapping[index] = @intCast(word_parameter);
                    capture_mapping = null;
                    saveSettings();
                    setStatusPhrase(.status_layout_saved, false);
                }
                _ = Win32.InvalidateRect(window, null, 0);
                return 0;
            }
        },
        Win32.wm_close => {
            _ = Win32.DestroyWindow(window);
            return 0;
        },
        wm_extract_finished => {
            finishExtraction(window, @truncate(word_parameter));
            syncSearchBox(window);
            return 0;
        },
        wm_update_checked => {
            finishUpdateCheck(word_parameter != 0);
            _ = Win32.InvalidateRect(window, null, 0);
            return 0;
        },
        Win32.wm_destroy => {
            // Closing the launcher abandons the extraction; the extractor has
            // no window of its own to be stopped from.
            if (extract_process != null) _ = Win32.TerminateProcess(extract_process, 1);
            input.hid.stopTest();
            Win32.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return Win32.DefWindowProcW(window, message, word_parameter, long_parameter);
}

/// Every rectangle the pointer can act on, in one place.
///
/// The click handler and the hover cursor have to agree about what is
/// interactive: a hand over something inert, or an arrow over a real button,
/// is worse than having no hand cursor at all. Sharing the geometry is what
/// keeps the two from drifting apart.
const nav_rects = [_]Rect{
    .{ .left = 20, .top = 126, .right = 202, .bottom = 174 },
    .{ .left = 20, .top = 184, .right = 202, .bottom = 232 },
    .{ .left = 20, .top = 242, .right = 202, .bottom = 290 },
    .{ .left = 20, .top = 300, .right = 202, .bottom = 348 },
    // The project site, under the PROJECT heading and above the Boosty pill.
    .{ .left = 20, .top = 584, .right = 202, .bottom = 616 },
    .{ .left = 20, .top = 626, .right = 202, .bottom = 670 },
    .{ .left = 20, .top = 680, .right = 202, .bottom = 724 },
};

const library_browse_rect = Rect{ .left = 282, .top = 646, .right = 500, .bottom = 700 };
const library_extract_rect = Rect{ .left = 516, .top = 646, .right = 760, .bottom = 700 };
const library_launch_rect = Rect{ .left = 776, .top = 646, .right = 1086, .bottom = 700 };

// The arrows sit in the margins either side of the grid rather than inside
// it, so a second page costs the artwork none of its width.
const library_prev_rect = Rect{ .left = 236, .top = 298, .right = 270, .bottom = 354 };
const library_next_rect = Rect{ .left = 1085, .top = 298, .right = 1119, .bottom = 354 };

/// The update button every page carries at the end of its heading row.
const update_rect = Rect{ .left = 936, .top = 44, .right = 1086, .bottom = 72 };

// The search box and the view switch share the heading row with the title,
// left of the update button.
const library_search_rect = Rect{ .left = 580, .top = 44, .right = 840, .bottom = 72 };
const library_view_rects = [_]Rect{
    .{ .left = 852, .top = 44, .right = 886, .bottom = 72 },
    .{ .left = 892, .top = 44, .right = 926, .bottom = 72 },
};
/// Where the edit control sits inside the drawn box, right of the magnifier.
const search_edit_rect = Rect{ .left = 614, .top = 48, .right = 830, .bottom = 69 };
const search_box_colour: u32 = 0x00251f1b;

/// Pages the library needs. Always at least one, so an empty library or an
/// empty search still has a page to be on.
fn libraryPageCount() usize {
    if (library_match_count == 0) return 1;
    return (library_match_count + library_page_size - 1) / library_page_size;
}

/// The game shown in a slot of the current page, or null for an empty slot.
fn libraryGameAtSlot(slot: usize) ?usize {
    const position = library_page * library_page_size + slot;
    if (slot >= library_page_size or position >= library_match_count) return null;
    return library_matches[position];
}

/// Where a game sits on the page being shown, or null when it is on another
/// page or hidden by the search.
fn librarySlotOf(index: usize) ?usize {
    for (0..library_page_size) |slot| {
        if (libraryGameAtSlot(slot) == index) return slot;
    }
    return null;
}

/// Keeps the shown page inside the list after games are added or removed.
/// A page past the end would draw empty with nothing on it to get back from.
fn clampLibraryPage() void {
    const pages = libraryPageCount();
    if (library_page >= pages) library_page = pages - 1;
}

/// Rectangles are addressed by slot on the page, not by position in the list:
/// the page has eight places and the list can be longer than that.
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
    return .{
        .left = game.right - 34,
        .top = game.top + 8,
        .right = game.right - 8,
        .bottom = game.top + 34,
    };
}

/// A dot per page under the grid. The hit area is wider than the dot it
/// draws, because an eight-pixel target is not one a pointer can be asked to
/// hit.
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

/// Moves by whole pages and stops at the ends. Reports whether anything
/// moved, so a wheel notch at the last page does not repaint the window.
fn stepLibraryPage(delta: i32) bool {
    const pages: i32 = @intCast(libraryPageCount());
    const next = @as(i32, @intCast(library_page)) + delta;
    if (next < 0 or next >= pages) return false;
    showLibraryPage(@intCast(next));
    return true;
}

/// The hover belongs to a slot, and the same slot holds a different game
/// after the page turns; leaving it set would highlight the newcomer.
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

/// Search and the view switch only mean something once there is a library to
/// look through, and they make way for the extraction panel.
fn libraryToolbarVisible() bool {
    return current_page == .library and extract_state == .idle and recent_game_count != 0;
}

fn libraryViewAt(x: i32, y: i32) ?LibraryView {
    if (!libraryToolbarVisible()) return null;
    const index = indexOfRect(&library_view_rects, x, y) orelse return null;
    return @enumFromInt(index);
}

/// The drawn placeholder, which turns into the edit control when clicked.
fn searchPlaceholderAt(x: i32, y: i32) bool {
    return libraryToolbarVisible() and !search_shown and library_search_rect.contains(x, y);
}

/// Case-insensitive substring test. Both sides go through the system's own
/// lowercase mapping, so Cyrillic, Greek and accented Latin titles match too.
fn containsIgnoringCase(haystack: []const u16, lowered_needle: []const u16) bool {
    if (lowered_needle.len == 0) return true;
    if (lowered_needle.len > haystack.len or haystack.len > 1024) return false;
    var lowered: [1024]u16 = undefined;
    @memcpy(lowered[0..haystack.len], haystack);
    _ = Win32.CharLowerBuffW(&lowered, @intCast(haystack.len));
    return std.mem.indexOf(u16, lowered[0..haystack.len], lowered_needle) != null;
}

/// Recomputes which games pass the search. Called whenever the library or the
/// search text changes, so drawing and hit testing read a settled list.
fn refreshLibraryMatches() void {
    var needle: [128]u16 = undefined;
    @memcpy(needle[0..search_length], search_text[0..search_length]);
    if (search_length != 0) _ = Win32.CharLowerBuffW(&needle, @intCast(search_length));
    const query = needle[0..search_length];
    library_match_count = 0;
    for (recent_games[0..recent_game_count], 0..) |game, index| {
        const folder = game.folder[0..game.folder_length];
        var name_start = folder.len;
        while (name_start > 0 and folder[name_start - 1] != '\\' and folder[name_start - 1] != '/') : (name_start -= 1) {}
        if (containsIgnoringCase(game.title[0..game.title_length], query) or
            containsIgnoringCase(game.identifier[0..game.identifier_length], query) or
            containsIgnoringCase(folder[name_start..], query))
        {
            library_matches[library_match_count] = @intCast(index);
            library_match_count += 1;
        }
    }
    clampLibraryPage();
}

fn readSearchText() void {
    const edit = search_edit orelse return;
    const length = Win32.GetWindowTextW(edit, &search_text, search_text.len);
    search_length = if (length > 0) @intCast(length) else 0;
    search_text[search_length] = 0;
    refreshLibraryMatches();
    // A new query starts from its first result.
    showLibraryPage(0);
}

fn createSearchEdit(window: Win32.Window, instance: Win32.Instance) void {
    search_brush = Win32.CreateSolidBrush(search_box_colour);
    const edit = Win32.CreateWindowExW(
        0,
        w("EDIT"),
        w(""),
        Win32.ws_child | Win32.es_auto_horizontal_scroll,
        search_edit_rect.left,
        search_edit_rect.top,
        search_edit_rect.right - search_edit_rect.left,
        search_edit_rect.bottom - search_edit_rect.top,
        window,
        @ptrFromInt(search_edit_id),
        instance,
        null,
    ) orelse return;
    search_edit = edit;
    _ = Win32.SendMessageW(edit, Win32.wm_set_font, @intFromPtr(regular_font), 0);
    _ = Win32.SendMessageW(edit, Win32.em_limit_text, search_text.len - 1, 0);
    search_edit_original = Win32.SetWindowLongPtrW(edit, Win32.gwlp_window_procedure, @bitCast(@intFromPtr(&searchEditProcedure)));
}

/// Escape clears the search and leaves the box; Enter picks the first result.
/// A single-line edit would otherwise beep at both, and Ctrl+Backspace would
/// insert a box character instead of deleting.
fn searchEditProcedure(window: Win32.Window, message: u32, word_parameter: usize, long_parameter: isize) callconv(.winapi) isize {
    switch (message) {
        Win32.wm_key_down => {
            if (word_parameter == 0x1b) {
                _ = Win32.SetWindowTextW(window, w(""));
                _ = Win32.SetFocus(current_window);
                return 0;
            }
            if (word_parameter == 0x0d) {
                if (library_match_count != 0) {
                    selectRecentGame(library_matches[0]);
                    _ = Win32.InvalidateRect(current_window, null, 0);
                }
                return 0;
            }
        },
        Win32.wm_char => if (word_parameter == 0x0d or word_parameter == 0x1b or word_parameter == 0x7f) return 0,
        else => {},
    }
    const original: Win32.WindowProcedure = @ptrFromInt(@as(usize, @bitCast(search_edit_original)));
    return Win32.CallWindowProcW(original, window, message, word_parameter, long_parameter);
}

fn activateSearch(window: Win32.Window) void {
    const edit = search_edit orelse return;
    if (!libraryToolbarVisible()) return;
    search_shown = true;
    _ = Win32.ShowWindow(edit, Win32.show_normal);
    _ = Win32.SetFocus(edit);
    _ = Win32.InvalidateRect(window, null, 0);
}

/// Empties the search without moving focus into it. A newly chosen or
/// extracted game must not be hidden by a filter typed for something else.
fn clearSearch() void {
    if (search_edit) |edit| {
        if (search_length != 0) _ = Win32.SetWindowTextW(edit, w(""));
    }
    search_length = 0;
    refreshLibraryMatches();
}

/// Shows the edit control only on the library, and only while it holds text
/// or has the focus. It is a child window, so it would otherwise stay on top
/// of other pages. Deriving this from the state rather than tracking it means
/// a focus change Windows makes on its own, such as switching applications,
/// cannot leave an empty box open.
fn syncSearchBox(window: Win32.Window) void {
    const edit = search_edit orelse return;
    if (recent_game_count == 0 and search_length != 0) clearSearch();
    const shown = libraryToolbarVisible() and (search_length != 0 or Win32.GetFocus() == edit);
    if (!shown and Win32.GetFocus() == edit) _ = Win32.SetFocus(window);
    search_shown = shown;
    _ = Win32.ShowWindow(edit, if (shown) Win32.show_normal else Win32.show_hide);
}

/// Sits beside the presence indicator on the input page.
const pad_test_rect = Rect{ .left = 946, .top = 250, .right = 1086, .bottom = 278 };

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

// The resolution row was four cards across the full content width. The
// preset belongs beside it rather than below: the settings page already
// reaches the bottom of the window, and both are launch-time choices that
// read naturally on one line. Four narrower cards leave room for two.
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

fn controllerSlotRect(index: usize) Rect {
    const left = 406 + @as(i32, @intCast(index)) * 28;
    return .{ .left = left, .top = 212, .right = left + 24, .bottom = 238 };
}

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

/// Whether the pointer is over something that responds to a click.
fn clickableAt(x: i32, y: i32) bool {
    if (indexOfRect(&nav_rects, x, y) != null) return true;
    if (update_rect.contains(x, y)) return update_state != .checking;
    return switch (current_page) {
        .library => recentGameAt(x, y) != null or
            indexOfRect(&library_graphics_api_rects, x, y) != null or
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
            if (pad_presence.connected and pad_test_rect.contains(x, y)) break :blk true;
            if (indexOfRect(&input_mode_rects, x, y) != null) break :blk true;
            for (0..4) |index| {
                if (controllerSlotRect(index).contains(x, y)) break :blk true;
            }
            for (0..mapping.len) |index| {
                if (mappingRect(index).contains(x, y)) break :blk true;
            }
            break :blk false;
        },
        .saves => saves_open_rect.contains(x, y),
        .settings => indexOfRect(&language_rects, x, y) != null or
            indexOfRect(&graphics_api_rects, x, y) != null or
            indexOfRect(&resolution_rects, x, y) != null or
            indexOfRect(&preset_rects, x, y) != null or
            indexOfRect(&settings_toggle_rects, x, y) != null,
    };
}

fn handleClick(window: Win32.Window, x: i32, y: i32) void {
    if (indexOfRect(&nav_rects, x, y)) |index| {
        switch (index) {
            0 => current_page = .library,
            1 => current_page = .input,
            2 => current_page = .saves,
            3 => current_page = .settings,
            4 => openSite(window),
            5 => openBoosty(window),
            else => openGithub(window),
        }
        if (current_page != .library) {
            hovered_recent_game = null;
            hovered_recent_remove = false;
        }
    } else if (update_rect.contains(x, y)) {
        handleUpdateClick(window);
    } else switch (current_page) {
        .library => handleLibraryClick(window, x, y),
        .input => handleInputClick(x, y),
        .saves => handleSavesClick(window, x, y),
        .settings => handleSettingsClick(x, y),
    }
    _ = Win32.InvalidateRect(window, null, 0);
}

fn handleLibraryClick(window: Win32.Window, x: i32, y: i32) void {
    if (indexOfRect(&library_graphics_api_rects, x, y)) |index| {
        selectGraphicsApi(index);
        return;
    }
    if (indexOfRect(&library_frame_limit_rects, x, y)) |index| {
        selected_frame_limit = frame_limit.choices[index];
        saveSettings();
        setStatusPhrase(.status_fps_limit_saved, false);
        return;
    }
    if (extract_state != .idle and extract_copy_rect.contains(x, y)) {
        copyExtractLog(window);
        return;
    }
    if (extractFinished() and extract_panel_rect.contains(x, y)) {
        extract_state = .idle;
        return;
    }
    if (searchPlaceholderAt(x, y)) {
        activateSearch(window);
        return;
    }
    if (libraryViewAt(x, y)) |view| {
        if (view != library_view) {
            library_view = view;
            // The same page holds the same eight games in either view.
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
    if (library_browse_rect.contains(x, y)) chooseGameFolder(window);
    if (library_extract_rect.contains(x, y) and extract_state != .running) extractPackage(window);
    if (library_launch_rect.contains(x, y)) launchGame(window);
}

fn handleInputClick(x: i32, y: i32) void {
    if (pad_presence.connected and pad_test_rect.contains(x, y)) {
        if (input.hid.startTest()) {
            // A short timer drives the colour steps; the half-second presence
            // timer is far too coarse to walk through them.
            _ = Win32.SetTimer(current_window, pad_test_timer_id, pad_test_tick_ms, null);
            setStatusPhrase(.pad_test, false);
        } else {
            setStatusPhrase(.pad_test_unavailable, true);
        }
        return;
    }
    for (0..4) |index| {
        if (controllerSlotRect(index).contains(x, y)) {
            controller_index = @intCast(index);
            saveSettings();
            setStatusPhrase(.status_controller_saved, false);
            return;
        }
    }
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

const graphics_api_rects = [_]Rect{
    .{ .left = 294, .top = 592, .right = 450, .bottom = 632 },
    .{ .left = 462, .top = 592, .right = 640, .bottom = 632 },
};

// The library's bottom card holds three groups: the game folder (306-456),
// the graphics API (472-748) and the frame limit (764-1066). The API group is
// as wide as Russian needs for its label beside the experimental note, and the
// last frame-limit button fits the longest "Unlimited" (German, 100 px).
const library_graphics_api_rects = [_]Rect{
    .{ .left = 472, .top = 571, .right = 582, .bottom = 611 },
    .{ .left = 590, .top = 571, .right = 748, .bottom = 611 },
};

const library_frame_limit_rects = [_]Rect{
    .{ .left = 764, .top = 571, .right = 814, .bottom = 611 },
    .{ .left = 820, .top = 571, .right = 870, .bottom = 611 },
    .{ .left = 876, .top = 571, .right = 932, .bottom = 611 },
    .{ .left = 938, .top = 571, .right = 1066, .bottom = 611 },
};

fn selectGraphicsApi(index: usize) void {
    selected_graphics_api = graphics_api.choices[index];
    saveSettings();
    setStatusPhrase(.status_graphics_api_saved, false);
}

fn handleSettingsClick(x: i32, y: i32) void {
    if (indexOfRect(&graphics_api_rects, x, y)) |index| {
        selectGraphicsApi(index);
        return;
    }
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

fn paint(window: Win32.Window) void {
    var paint_data: Win32.PaintStruct = undefined;
    const dc = Win32.BeginPaint(window, &paint_data) orelse return;
    defer _ = Win32.EndPaint(window, &paint_data);

    var client: Win32.NativeRect = undefined;
    _ = Win32.GetClientRect(window, &client);
    fill(dc, .{ .left = 0, .top = 0, .right = client.right, .bottom = client.bottom }, 0x0015110e);
    fill(dc, .{ .left = 0, .top = 0, .right = sidebar_width, .bottom = client.bottom }, 0x00201915);
    fill(dc, .{ .left = sidebar_width, .top = 0, .right = sidebar_width + 1, .bottom = client.bottom }, 0x00352b25);

    drawBrand(dc);
    drawNavigation(dc);
    switch (current_page) {
        .library => drawLibrary(dc),
        .input => drawInput(dc),
        .saves => drawSaves(dc),
        .settings => drawSettings(dc),
    }
    drawFooter(dc);
}

fn drawBrand(dc: Win32.DeviceContext) void {
    _ = Win32.DrawIconEx(dc, 24, 28, application_icon, 44, 44, 0, null, Win32.di_normal);
    // The 27-pixel title needs a cell about 36 pixels tall; the old 25-pixel
    // one sliced the bottom off every glyph. Both lines are sized for their
    // font and the pair is centred against the 44-pixel icon beside them.
    text(dc, w("PS5PCEM"), -1, .{ .left = 80, .top = 26, .right = 216, .bottom = 62 }, 0x00f4f0ea, title_font, Win32.dt_left);
    // The sidebar leaves 136 pixels beside the icon, which "LAUNCHER ·
    // PREVIEW" overran: it was drawn cut off mid-word. The window title
    // already says this is the launcher, so the line only has to say which
    // kind of build it is. The ellipsis flag keeps a future string degrading
    // readably instead of being chopped through a glyph.
    text(dc, w("PREVIEW BUILD"), -1, .{ .left = 80, .top = 62, .right = 216, .bottom = 80 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
}

fn drawNavigation(dc: Win32.DeviceContext) void {
    drawNavItem(dc, .library, 126, .nav_library, "01");
    drawNavItem(dc, .input, 184, .nav_input, "02");
    drawNavItem(dc, .saves, 242, .nav_saves, "03");
    drawNavItem(dc, .settings, 300, .nav_settings, "04");
    drawVulkanStatus(dc);
    localizedText(dc, .project, .{ .left = 28, .top = 560, .right = 190, .bottom = 580 }, 0x007c716a, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    roundFill(dc, .{ .left = 20, .top = 626, .right = 202, .bottom = 670 }, 10, 0x003d3029);
    localizedText(dc, .support_boosty, .{ .left = 32, .top = 639, .right = 192, .bottom = 660 }, 0x00ffac64, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    text(dc, w("GitHub · iStark  ↗"), -1, .{ .left = 28, .top = 690, .right = 198, .bottom = 716 }, 0x00b9afa8, regular_font, Win32.dt_left);
    text(dc, w("ps5pcem.com  ↗"), -1, .{ .left = 28, .top = 588, .right = 198, .bottom = 612 }, 0x00ffac64, regular_font, Win32.dt_left);
}

/// Says what the probe found, in the place that used to assert success.
///
/// A ready line names the device, because "Vulkan 1.3 · NVIDIA GeForce RTX
/// 3070 Ti" tells someone reporting a problem what this machine resolved to,
/// and a version alone does not. The failures are phrased as what to do, since
/// each of them is fixed by the same person at the same keyboard.
/// Draws a runtime string. The localized path takes a phrase, and a device
/// name is not one: it comes from the driver and is the same in every language.
fn drawAscii(dc: Win32.DeviceContext, value: []const u8, area: Rect, color: u32, font: Win32.Font, flags: u32) void {
    var wide: [320]u16 = undefined;
    if (value.len == 0 or value.len >= wide.len) return;
    const length = std.unicode.utf8ToUtf16Le(&wide, value) catch return;
    wide[length] = 0;
    text(dc, @ptrCast(&wide), @intCast(length), area, color, font, flags);
}

fn drawVulkanStatus(dc: Win32.DeviceContext) void {
    const area = Rect{ .left = 28, .top = 498, .right = 198, .bottom = 520 };
    const second = Rect{ .left = 28, .top = 518, .right = 198, .bottom = 540 };
    const dim: u32 = 0x007c716a;
    const warn: u32 = 0x006f8cff;
    const flags = Win32.dt_left | Win32.dt_end_ellipsis;
    if (selected_graphics_api == .d3d12) {
        drawAscii(dc, "DirectX 12", area, warn, small_font, flags);
        localizedText(dc, .graphics_api_experimental, second, warn, small_font, flags);
        return;
    }
    switch (vulkan_report.state) {
        .ready => {
            var line: [64]u8 = undefined;
            const version = std.fmt.bufPrint(&line, "Vulkan {d}.{d} ready", .{
                vulkan_report.major,
                vulkan_report.minor,
            }) catch return;
            drawAscii(dc, version, area, 0x0074c98a, small_font, flags);
            drawAscii(dc, vulkan_report.deviceName(), second, dim, small_font, flags);
        },
        .no_loader => localizedText(dc, .vulkan_missing, area, warn, small_font, flags),
        .no_device => localizedText(dc, .vulkan_no_device, area, warn, small_font, flags),
        .too_old => localizedText(dc, .vulkan_too_old, area, warn, small_font, flags),
        .unchecked => {},
    }
}

fn drawNavItem(dc: Win32.DeviceContext, page: Page, top: i32, label: Phrase, comptime index: []const u8) void {
    if (current_page == page) roundFill(dc, .{ .left = 20, .top = top, .right = 202, .bottom = top + 48 }, 12, 0x003d3029);
    const color: u32 = if (current_page == page) 0x00fff8f1 else 0x00a39890;
    text(dc, w(index), -1, .{ .left = 34, .top = top + 15, .right = 58, .bottom = top + 38 }, if (current_page == page) 0x00ffac64 else 0x006d625b, small_font, Win32.dt_left);
    localizedText(dc, label, .{ .left = 66, .top = top + 13, .right = 200, .bottom = top + 39 }, color, medium_font, Win32.dt_left);
}

fn drawLibrary(dc: Win32.DeviceContext) void {
    if (libraryToolbarVisible()) {
        pageHeadingBefore(dc, .library_heading, .library_subtitle, library_search_rect.left - 16);
        drawLibraryToolbar(dc);
    } else {
        pageHeading(dc, .library_heading, .library_subtitle);
    }

    if (extract_state != .idle) {
        drawExtractPanel(dc);
    } else if (recent_game_count == 0) {
        card(dc, .{ .left = 282, .top = 158, .right = 1086, .bottom = 510 });
        localizedText(dc, .folder_prompt, .{ .left = 330, .top = 298, .right = 1038, .bottom = 338 }, 0x00f4f0ea, title_font, Win32.dt_center | Win32.dt_end_ellipsis);
        localizedText(dc, .folder_empty, .{ .left = 330, .top = 350, .right = 1038, .bottom = 376 }, 0x008b817a, regular_font, Win32.dt_center | Win32.dt_end_ellipsis);
    } else if (library_match_count == 0) {
        card(dc, .{ .left = 282, .top = 158, .right = 1086, .bottom = 510 });
        localizedText(dc, .search_empty, .{ .left = 330, .top = 298, .right = 1038, .bottom = 338 }, 0x00f4f0ea, title_font, Win32.dt_center | Win32.dt_end_ellipsis);
        text(dc, &search_text, @intCast(search_length), .{ .left = 330, .top = 350, .right = 1038, .bottom = 376 }, 0x008b817a, regular_font, Win32.dt_center | Win32.dt_end_ellipsis);
    } else {
        if (library_view == .table) drawLibraryTableHeader(dc);
        for (0..library_page_size) |slot| {
            const index = libraryGameAtSlot(slot) orelse break;
            switch (library_view) {
                .grid => drawLibraryGame(dc, recent_games[index], index, slot),
                .table => drawLibraryRow(dc, recent_games[index], index, slot),
            }
        }
        drawLibraryPager(dc);
    }

    card(dc, .{ .left = 282, .top = 536, .right = 1086, .bottom = 622 });
    localizedText(dc, .graphics_api, .{ .left = 472, .top = 546, .right = 748, .bottom = 566 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    if (selected_graphics_api == .d3d12) localizedText(dc, .graphics_api_experimental, .{ .left = 610, .top = 546, .right = 748, .bottom = 566 }, 0x006f8cff, small_font, Win32.dt_right | Win32.dt_end_ellipsis);
    drawGraphicsApiButtons(dc, &library_graphics_api_rects);
    localizedText(dc, .fps_limit, .{ .left = 764, .top = 546, .right = 1066, .bottom = 566 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    drawFrameLimitButtons(dc);
    localizedText(dc, .folder_label, .{ .left = 306, .top = 546, .right = 456, .bottom = 566 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    if (game_folder_length == 0) {
        localizedText(dc, .folder_empty, .{ .left = 306, .top = 582, .right = 456, .bottom = 607 }, 0x007e746d, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    } else {
        text(dc, &game_folder, @intCast(game_folder_length), .{ .left = 306, .top = 580, .right = 456, .bottom = 607 }, 0x00d8d0c9, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    }

    button(dc, library_browse_rect, .choose_folder, false);
    button(dc, library_extract_rect, .extract_pkg, extract_state == .running);
    drawLegalNotice(dc);
    button(dc, library_launch_rect, .launch_game, game_folder_length == 0);
}

fn extractFinished() bool {
    return extract_state == .succeeded or extract_state == .failed;
}

fn drawExtractPanel(dc: Win32.DeviceContext) void {
    var feed: ExtractFeed = undefined;
    lockExtractFeed();
    feed = extract_feed;
    extract_lock.unlock();

    const panel = extract_panel_rect;
    card(dc, panel);
    const left = panel.left + 24;
    const right = panel.right - 24;
    const title_flags = Win32.dt_left | Win32.dt_end_ellipsis;
    localizedText(dc, extract_result, .{ .left = left, .top = panel.top + 20, .right = extract_copy_rect.left - 16, .bottom = panel.top + 46 }, 0x00f4f0ea, medium_font, title_flags);
    roundFill(dc, extract_copy_rect, 10, 0x00342a25);
    localizedText(dc, .copy_log, .{ .left = extract_copy_rect.left + 8, .top = extract_copy_rect.top + 8, .right = extract_copy_rect.right - 8, .bottom = extract_copy_rect.bottom - 6 }, 0x00ffac64, small_font, Win32.dt_center | Win32.dt_end_ellipsis);
    text(dc, &extract_name, @intCast(extract_name_length), .{ .left = left, .top = panel.top + 50, .right = extract_copy_rect.left - 16, .bottom = panel.top + 70 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);

    // The bar fills from the bytes the extractor has written. Before its
    // first report it is still reading the package's metadata.
    const track = Rect{ .left = left, .top = panel.top + 84, .right = right, .bottom = panel.top + 98 };
    roundFill(dc, track, 14, 0x00342a25);
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
        roundFill(dc, .{ .left = track.left, .top = track.top, .right = track.left + width, .bottom = track.bottom }, 14, colour);
    }
    const detail_area = Rect{ .left = left, .top = panel.top + 106, .right = right - 240, .bottom = panel.top + 126 };
    if (extractFinished()) {
        localizedText(dc, .extract_dismiss, .{ .left = right - 240, .top = panel.top + 106, .right = right, .bottom = panel.top + 126 }, 0x007c716a, small_font, Win32.dt_right | Win32.dt_end_ellipsis);
    }
    if (feed.total == 0 and extract_state == .running) {
        localizedText(dc, .extract_preparing, detail_area, 0x009b9088, small_font, Win32.dt_left);
    } else if (feed.total != 0) {
        var line: [96]u8 = undefined;
        const gib = 1024.0 * 1024.0 * 1024.0;
        const detail = std.fmt.bufPrint(&line, "{d}%  ·  {d:.2} / {d:.2} GB", .{
            @as(u32, @intFromFloat(fraction * 100.0)),
            @as(f64, @floatFromInt(@min(feed.done, feed.total))) / gib,
            @as(f64, @floatFromInt(feed.total)) / gib,
        }) catch "";
        drawAscii(dc, detail, detail_area, 0x00d8d0c9, small_font, Win32.dt_left);
    }

    const log_area = Rect{ .left = left, .top = panel.top + 138, .right = right, .bottom = panel.bottom - 20 };
    roundFill(dc, log_area, 10, 0x001c1714);
    const first = (feed.log_next + extract_log_capacity - feed.log_count) % extract_log_capacity;
    for (0..feed.log_count) |row| {
        const slot = (first + row) % extract_log_capacity;
        const top = log_area.top + 10 + @as(i32, @intCast(row)) * 22;
        drawAscii(dc, feed.log[slot][0..feed.log_lengths[slot]], .{ .left = log_area.left + 14, .top = top, .right = log_area.right - 14, .bottom = top + 20 }, 0x00b9afa8, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    }
}

/// The notice the library has always carried, with the build's own version
/// after it. A screenshot of a problem nearly always carries this line, and a
/// version that has to be asked for arrives a day late.
fn drawLegalNotice(dc: Win32.DeviceContext) void {
    const area = Rect{ .left = 282, .top = 708, .right = 1086, .bottom = 730 };
    const format = languageTextFormat(language, Win32.dt_center | Win32.dt_end_ellipsis);
    var line: [512]u8 = undefined;
    const composed: []const u8 = std.fmt.bufPrint(
        &line,
        "{s} · v{s}",
        .{ tr(.legal_notice), build_options.release_version },
    ) catch tr(.legal_notice);
    textUtf8(dc, composed, area, 0x007e746d, small_font, format);
}

/// Arrows beside the grid and a dot for each page under it, drawn only once
/// the library outgrows one page. A library that fits on one page shows no
/// controls at all, which is the state most of them stay in.
fn drawLibraryPager(dc: Win32.DeviceContext) void {
    const pages = libraryPageCount();
    if (pages < 2) return;
    drawLibraryArrow(dc, library_prev_rect, w("‹"), library_page > 0, hovered_library_arrow == 0);
    drawLibraryArrow(dc, library_next_rect, w("›"), library_page + 1 < pages, hovered_library_arrow == 1);
    for (0..pages) |page| {
        const dot = libraryDotRect(page);
        const centre_x = @divTrunc(dot.left + dot.right, 2);
        const centre_y = @divTrunc(dot.top + dot.bottom, 2);
        const current = page == library_page;
        const radius: i32 = if (current) 5 else 4;
        roundFill(dc, .{
            .left = centre_x - radius,
            .top = centre_y - radius,
            .right = centre_x + radius,
            .bottom = centre_y + radius,
        }, radius * 2, if (current) 0x00ffac64 else 0x00403934);
    }
}

fn drawLibraryArrow(dc: Win32.DeviceContext, rectangle: Rect, glyph: [*:0]const u16, enabled: bool, hovered: bool) void {
    const background: u32 = if (!enabled) 0x001f1a16 else if (hovered) 0x004a3a2e else 0x00251f1b;
    roundFill(dc, rectangle, 16, background);
    // An end of the list keeps its arrow and greys it, so the controls do not
    // change width as the pages turn.
    const color: u32 = if (!enabled) 0x00463c35 else if (hovered) 0x00fff8f1 else 0x00a39890;
    text(dc, glyph, -1, .{
        .left = rectangle.left,
        .top = rectangle.top + 10,
        .right = rectangle.right,
        .bottom = rectangle.bottom,
    }, color, title_font, Win32.dt_center);
}

fn drawLibraryGame(dc: Win32.DeviceContext, game: RecentGame, index: usize, slot: usize) void {
    const rectangle = libraryGameRect(slot);
    const selected = sameFolder(game.folder[0..game.folder_length], game_folder[0..game_folder_length]);
    roundFill(dc, rectangle, 12, if (selected) 0x0049362b else 0x00251f1b);
    const artwork = Rect{
        .left = rectangle.left + 26,
        .top = rectangle.top + 10,
        .right = rectangle.right - 26,
        .bottom = rectangle.top + 146,
    };
    if (game.icon) |icon| {
        drawBitmap(dc, icon, artwork);
    } else {
        roundFill(dc, artwork, 10, 0x00352c27);
        text(dc, w("PS5"), -1, .{ .left = artwork.left, .top = artwork.top + 52, .right = artwork.right, .bottom = artwork.bottom }, 0x00ffac64, title_font, Win32.dt_center);
    }
    if (game.title_length != 0) {
        text(dc, &game.title, @intCast(game.title_length), .{ .left = rectangle.left + 10, .top = rectangle.top + 151, .right = rectangle.right - 10, .bottom = rectangle.bottom - 6 }, 0x00f4f0ea, small_font, Win32.dt_center | Win32.dt_end_ellipsis);
    } else {
        text(dc, &game.identifier, @intCast(game.identifier_length), .{ .left = rectangle.left + 10, .top = rectangle.top + 151, .right = rectangle.right - 10, .bottom = rectangle.bottom - 6 }, 0x00a39890, small_font, Win32.dt_center | Win32.dt_end_ellipsis);
    }
    if (hovered_recent_game == index) {
        const remove = recentRemoveRect(slot);
        roundFill(dc, remove, 13, if (hovered_recent_remove) 0x004848d8 else 0x00403934);
        text(dc, w("×"), -1, .{ .left = remove.left, .top = remove.top + 2, .right = remove.right, .bottom = remove.bottom }, 0x00f4f0ea, medium_font, Win32.dt_center);
    }
}

/// The search box, drawn around the edit control or as a placeholder when the
/// control is hidden, and the two view buttons beside it.
fn drawLibraryToolbar(dc: Win32.DeviceContext) void {
    const box = library_search_rect;
    const focused = search_edit != null and Win32.GetFocus() == search_edit;
    // A one-pixel ring: the outline colour underneath, the box colour inset.
    roundFill(dc, box, 12, if (focused) 0x00ffac64 else 0x00403934);
    roundFill(dc, .{ .left = box.left + 1, .top = box.top + 1, .right = box.right - 1, .bottom = box.bottom - 1 }, 11, search_box_colour);
    drawMagnifier(dc, box.left + 12, box.top + 8, if (focused) 0x00ffac64 else 0x008b817a);
    if (!search_shown) {
        localizedText(dc, .search_placeholder, .{ .left = search_edit_rect.left, .top = box.top, .right = search_edit_rect.right, .bottom = box.bottom }, 0x007e746d, regular_font, Win32.dt_left | Win32.dt_vertical_center | Win32.dt_single_line | Win32.dt_end_ellipsis);
    }

    for (library_view_rects, 0..) |rectangle, index| {
        const view: LibraryView = @enumFromInt(index);
        const selected = view == library_view;
        roundFill(dc, rectangle, 10, if (selected) 0x003d3029 else search_box_colour);
        const colour: u32 = if (selected) 0x00ffac64 else 0x008b817a;
        const x = rectangle.left + @divTrunc(rectangle.right - rectangle.left - 16, 2);
        const y = rectangle.top + 6;
        switch (view) {
            // Four tiles.
            .grid => for (0..4) |tile| {
                const tile_x = x + @as(i32, @intCast(tile % 2)) * 9;
                const tile_y = y + @as(i32, @intCast(tile / 2)) * 9;
                fill(dc, .{ .left = tile_x, .top = tile_y, .right = tile_x + 7, .bottom = tile_y + 7 }, colour);
            },
            // Three rows, each a marker and a line.
            .table => for (0..3) |row| {
                const row_y = y + 1 + @as(i32, @intCast(row)) * 6;
                fill(dc, .{ .left = x, .top = row_y, .right = x + 3, .bottom = row_y + 3 }, colour);
                fill(dc, .{ .left = x + 5, .top = row_y, .right = x + 16, .bottom = row_y + 3 }, colour);
            },
        }
    }
}

/// A lens and a handle. Drawn with GDI rather than a glyph, because the
/// interface font has no magnifier and GDI does not fall back to one.
fn drawMagnifier(dc: Win32.DeviceContext, x: i32, y: i32, colour: u32) void {
    const pen = Win32.CreatePen(0, 2, colour) orelse return;
    defer _ = Win32.DeleteObject(pen);
    const old_pen = Win32.SelectObject(dc, pen);
    const old_brush = Win32.SelectObject(dc, Win32.GetStockObject(Win32.null_brush));
    _ = Win32.Ellipse(dc, x, y, x + 10, y + 10);
    _ = Win32.MoveToEx(dc, x + 9, y + 9, null);
    _ = Win32.LineTo(dc, x + 13, y + 13);
    _ = Win32.SelectObject(dc, old_brush);
    _ = Win32.SelectObject(dc, old_pen);
}

/// Column positions shared by the header and every row.
const table_title_left = 340;
const table_identifier_left = 700;
const table_folder_left = 812;
const table_folder_right = 1030;

fn drawLibraryTableHeader(dc: Win32.DeviceContext) void {
    // The rows keep their left-to-right layout in every language, so each
    // heading starts where its column does. Arabic keeps its reading order but
    // not the right alignment localizedText would give it.
    const flags = Win32.dt_left | Win32.dt_end_ellipsis | (if (language == .arabic) Win32.dt_rtl_reading else 0);
    const colour: u32 = 0x007c716a;
    textUtf8(dc, tr(.column_title), .{ .left = table_title_left, .top = 146, .right = table_identifier_left - 12, .bottom = 164 }, colour, small_font, flags);
    textUtf8(dc, tr(.column_identifier), .{ .left = table_identifier_left, .top = 146, .right = table_folder_left - 12, .bottom = 164 }, colour, small_font, flags);
    textUtf8(dc, tr(.column_folder), .{ .left = table_folder_left, .top = 146, .right = table_folder_right, .bottom = 164 }, colour, small_font, flags);
}

fn drawLibraryRow(dc: Win32.DeviceContext, game: RecentGame, index: usize, slot: usize) void {
    const row = libraryGameRect(slot);
    const selected = sameFolder(game.folder[0..game.folder_length], game_folder[0..game_folder_length]);
    const hovered = hovered_recent_game == index;
    roundFill(dc, row, 10, if (selected) 0x0049362b else if (hovered) 0x002e2621 else 0x00251f1b);
    const icon = Rect{ .left = row.left + 10, .top = row.top + 3, .right = row.left + 42, .bottom = row.top + 35 };
    if (game.icon) |bitmap| {
        drawBitmap(dc, bitmap, icon);
    } else {
        roundFill(dc, icon, 6, 0x00352c27);
    }
    const line = Win32.dt_left | Win32.dt_vertical_center | Win32.dt_single_line;
    const title_area = Rect{ .left = table_title_left, .top = row.top, .right = table_identifier_left - 12, .bottom = row.bottom };
    text(dc, &game.title, @intCast(game.title_length), title_area, 0x00f4f0ea, regular_font, line | Win32.dt_end_ellipsis);
    text(dc, &game.identifier, @intCast(game.identifier_length), .{ .left = table_identifier_left, .top = row.top, .right = table_folder_left - 12, .bottom = row.bottom }, 0x00a39890, small_font, line | Win32.dt_end_ellipsis);
    const folder_area = Rect{ .left = table_folder_left, .top = row.top, .right = table_folder_right, .bottom = row.bottom };
    text(dc, &game.folder, @intCast(game.folder_length), folder_area, 0x007e746d, small_font, line | folderEllipsis(dc, game.folder[0..game.folder_length], folder_area));
    if (hovered) {
        const remove = recentRemoveRect(slot);
        roundFill(dc, remove, 13, if (hovered_recent_remove) 0x004848d8 else 0x00403934);
        text(dc, w("×"), -1, .{ .left = remove.left, .top = remove.top + 1, .right = remove.right, .bottom = remove.bottom }, 0x00f4f0ea, medium_font, Win32.dt_center);
    }
}

/// The end of a path names the game's own folder, so the path ellipsis
/// shortens the middle and keeps it. That ellipsis clips a final folder name
/// too long to fit by itself, so such a path ends in an ellipsis instead. The
/// two flags cannot be combined: DrawTextW stops drawing partway through.
fn folderEllipsis(dc: Win32.DeviceContext, folder: []const u16, area: Rect) u32 {
    var name_start = folder.len;
    while (name_start > 0 and folder[name_start - 1] != '\\' and folder[name_start - 1] != '/') : (name_start -= 1) {}
    const previous = Win32.SelectObject(dc, small_font);
    defer _ = Win32.SelectObject(dc, previous);
    var name_size = Win32.NativePoint{};
    var prefix_size = Win32.NativePoint{};
    const prefix = w("D:\\...\\");
    if (Win32.GetTextExtentPoint32W(dc, folder[name_start..].ptr, @intCast(folder.len - name_start), &name_size) == 0 or
        Win32.GetTextExtentPoint32W(dc, prefix, @intCast(wideLength(prefix)), &prefix_size) == 0)
    {
        return Win32.dt_end_ellipsis;
    }
    return if (name_size.x + prefix_size.x <= area.right - area.left) Win32.dt_path_ellipsis else Win32.dt_end_ellipsis;
}

fn drawInput(dc: Win32.DeviceContext) void {
    pageHeading(dc, .input_heading, .input_subtitle);
    drawModeCard(dc, .controller, .{ .left = 282, .top = 170, .right = 532, .bottom = 246 }, .gamepad, .xinput_slot);
    drawModeCard(dc, .keyboard, .{ .left = 548, .top = 170, .right = 798, .bottom = 246 }, .keyboard, .wasd_mapping);
    drawModeCard(dc, .hybrid, .{ .left = 814, .top = 170, .right = 1086, .bottom = 246 }, .hybrid, .both_sources);
    for (0..4) |index| {
        const left = 406 + @as(i32, @intCast(index)) * 28;
        const selected = controller_index == index;
        roundFill(dc, .{ .left = left, .top = 212, .right = left + 24, .bottom = 238 }, 6, if (selected) 0x00ff9c3d else 0x00352c27);
        var number = [_:0]u16{@as(u16, '1') + @as(u16, @intCast(index))};
        text(dc, &number, 1, .{ .left = left, .top = 218, .right = left + 24, .bottom = 234 }, if (selected) 0x00181510 else 0x00a89e96, small_font, Win32.dt_center);
    }

    drawPadPresence(dc);
    drawPadTest(dc);

    localizedText(dc, .keyboard_layout, .{ .left = 282, .top = 278, .right = 1086, .bottom = 300 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    for (0..mapping.len) |index| {
        const column: i32 = @intCast(index / 7);
        const row: i32 = @intCast(index % 7);
        const left = 282 + column * 404;
        const top = 310 + row * 48;
        roundFill(dc, .{ .left = left, .top = top, .right = left + 378, .bottom = top + 40 }, 8, if (capture_mapping == index) 0x0042362e else 0x00251f1b);
        textUtf8(dc, mapping_names[index], .{ .left = left + 14, .top = top + 11, .right = left + 210, .bottom = top + 32 }, 0x00d8d0c9, regular_font, Win32.dt_left);
        var key_buffer: [48]u16 = undefined;
        const key_length = keyDisplayName(mapping[index], &key_buffer);
        text(dc, &key_buffer, @intCast(key_length), .{ .left = left + 218, .top = top + 10, .right = left + 356, .bottom = top + 33 }, if (capture_mapping == index) 0x00ffac64 else 0x00f4f0ea, medium_font, Win32.dt_right);
    }
    localizedText(dc, .mapping_hint, .{ .left = 282, .top = 660, .right = 1086, .bottom = 686 }, 0x008b817a, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
}

/// Reports whether a Sony pad is attached, and which one.
///
/// The XInput slot beside it selects an Xbox-compatible controller; a DualSense
/// or DualShock 4 is read straight from HID and needs no slot, so saying which
/// path is live is the only way to tell that a connected pad will actually be
/// heard.
fn drawPadPresence(dc: Win32.DeviceContext) void {
    const area = Rect{ .left = 282, .top = 252, .right = 1086, .bottom = 274 };
    const connected = pad_presence.connected;
    roundFill(dc, .{ .left = area.left, .top = area.top + 6, .right = area.left + 10, .bottom = area.top + 16 }, 5, if (connected) 0x0055c46a else 0x00554a44);
    if (pad_presence.family) |family| {
        const name = switch (family) {
            .dual_sense => "DualSense",
            .dual_shock_4 => "DualShock 4",
        };
        textUtf8(dc, name, .{ .left = area.left + 20, .top = area.top, .right = area.right, .bottom = area.bottom }, 0x00d8d0c9, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
        return;
    }
    localizedText(dc, .pad_absent, .{ .left = area.left + 20, .top = area.top, .right = area.right, .bottom = area.bottom }, 0x008b817a, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
}

/// Runs the pad through a second of rumble and its colour sweep, so a player
/// can tell a pad that is merely detected from one the host can actually drive.
fn drawPadTest(dc: Win32.DeviceContext) void {
    if (!pad_presence.connected) return;
    const running = input.hid.testRunning();
    roundFill(dc, pad_test_rect, 8, if (running) 0x00ff9c3d else 0x00352c27);

    // The swatch is the light bar the pad is showing at this instant, so the
    // button doubles as the readout for its own test: a pad that rumbles but
    // never lights up is visible here without watching the hardware.
    const swatch = Rect{
        .left = pad_test_rect.left + 12,
        .top = pad_test_rect.top + 8,
        .right = pad_test_rect.left + 24,
        .bottom = pad_test_rect.top + 20,
    };
    const swatch_colour: u32 = if (input.hid.testColour()) |colour|
        deviceColour(colour[0], colour[1], colour[2])
    else if (running)
        0x00181510
    else
        0x00a89e96;
    roundFill(dc, swatch, 6, swatch_colour);

    localizedText(
        dc,
        .pad_test,
        .{ .left = swatch.right + 8, .top = pad_test_rect.top + 6, .right = pad_test_rect.right - 10, .bottom = pad_test_rect.bottom },
        if (running) 0x00181510 else 0x00d8d0c9,
        small_font,
        Win32.dt_center | Win32.dt_end_ellipsis,
    );
}

/// GDI takes its colours as blue, green and red packed low to high, which is
/// the reverse of the order the pad reports them in.
fn deviceColour(red: u8, green: u8, blue: u8) u32 {
    return (@as(u32, blue) << 16) | (@as(u32, green) << 8) | @as(u32, red);
}

/// Opens the host directory holding the selected title's saves.
const saves_open_rect = Rect{ .left = 880, .top = 148, .right = 1086, .bottom = 190 };

/// How many slots the page will list. A title with more has written more saves
/// than a launcher page can usefully show at once.
const maximum_listed_saves = 12;

const SaveSlot = struct {
    title_id: [32]u16 = @splat(0),
    title_id_length: usize = 0,
    name: [64]u16 = @splat(0),
    name_length: usize = 0,
    detail: [96]u16 = @splat(0),
    detail_length: usize = 0,
};

var save_slots: [maximum_listed_saves]SaveSlot = @splat(.{});
var save_slot_count: usize = 0;
var save_scan_done = false;

/// Rescans on the next paint. A selection change moves that title's slots to
/// the front while retaining saves from the rest of the library.
fn invalidateSaves() void {
    save_scan_done = false;
}

/// Builds the selected title's save path, or the all-title root when there is
/// no current title. The Saves page can therefore remain useful on startup.
fn saveDirectoryPath(output: *[1024]u16) usize {
    var length = saveRootDirectoryPath(output);
    if (length == 0) return 0;
    if (title_identifier_length == 0) {
        return length;
    }
    if (length + 1 >= output.len) return 0;
    output[length] = '\\';
    length += 1;
    if (length + title_identifier_length >= output.len) return 0;
    @memcpy(output[length..][0..title_identifier_length], title_identifier[0..title_identifier_length]);
    length += title_identifier_length;
    output[length] = 0;
    return length;
}

fn saveRootDirectoryPath(output: *[1024]u16) usize {
    var length = emulatorHomeDirectory(output);
    if (length == 0) return 0;
    const savedata = w("savedata");
    const savedata_length = wideLength(savedata);
    if (length + savedata_length >= output.len) return 0;
    @memcpy(output[length..][0..savedata_length], savedata[0..savedata_length]);
    length += savedata_length;
    output[length] = 0;
    return length;
}

/// The directory the launcher itself lives in, terminated after its
/// trailing separator. Without the terminator the buffer still read as the
/// launcher's own path, and CreateProcessW rejected that file as the
/// runner's working directory (ERROR_DIRECTORY) outside `zig-out\bin`.
fn siblingDirectory(output: *[1024]u16) usize {
    var length = Win32.GetModuleFileNameW(null, output, output.len);
    if (length == 0 or length >= output.len) return 0;
    while (length > 0 and output[length - 1] != '\\') : (length -= 1) {}
    output[length] = 0;
    return length;
}

/// Development builds live in `<root>/zig-out/bin`, while packaged builds put
/// the launcher directly in their root. Normalize both to the directory which
/// owns `savedata`, logs and the Vulkan driver cache.
fn emulatorHomeDirectory(output: *[1024]u16) usize {
    var length = siblingDirectory(output);
    if (length == 0) return 0;
    const development_tail = w("zig-out\\bin\\");
    const tail_length = wideLength(development_tail);
    if (length >= tail_length and
        sameFolder(output[length - tail_length .. length], development_tail[0..tail_length]))
    {
        length -= tail_length;
        output[length] = 0;
    }
    return length;
}

/// Lists every local title's slots, with the selected title first.
fn scanSaves() void {
    save_slot_count = 0;
    save_scan_done = true;

    var root: [1024]u16 = @splat(0);
    var root_length = emulatorHomeDirectory(&root);
    if (root_length == 0) return;
    const savedata = w("savedata");
    const savedata_length = wideLength(savedata);
    if (root_length + savedata_length >= root.len) return;
    @memcpy(root[root_length..][0..savedata_length], savedata[0..savedata_length]);
    root_length += savedata_length;
    root[root_length] = 0;

    // Put the selected title first, then continue through every other title
    // root. The Saves page is a library browser, so selecting a game without a
    // save must not make existing saves from all other games disappear.
    if (title_identifier_length != 0) {
        var selected: [1024]u16 = root;
        var selected_length = root_length;
        if (selected_length + 1 + title_identifier_length < selected.len) {
            selected[selected_length] = '\\';
            selected_length += 1;
            @memcpy(selected[selected_length..][0..title_identifier_length], title_identifier[0..title_identifier_length]);
            selected_length += title_identifier_length;
            selected[selected_length] = 0;
            scanTitleSaveSlots(&selected, selected_length, title_identifier[0..title_identifier_length]);
        }
    }

    // FindFirstFileW wants a pattern rather than a directory.
    const pattern = w("\\*");
    const pattern_length = wideLength(pattern);
    var search: [1024]u16 = root;
    if (root_length + pattern_length >= search.len) return;
    @memcpy(search[root_length..][0..pattern_length], pattern[0..pattern_length]);
    search[root_length + pattern_length] = 0;

    var found: Win32.FindData = undefined;
    const handle = Win32.FindFirstFileW(@ptrCast(&search), &found);
    if (@intFromPtr(handle) == Win32.invalid_handle) return;
    defer _ = Win32.FindClose(handle);

    while (true) {
        const is_directory = found.attributes & Win32.file_attribute_directory != 0;
        const name_length = wideLength(@ptrCast(&found.name));
        const skip = !is_directory or name_length == 0 or found.name[0] == '.';
        const is_selected = title_identifier_length != 0 and
            sameFolder(found.name[0..name_length], title_identifier[0..title_identifier_length]);
        if (!skip and !is_selected and save_slot_count < save_slots.len) {
            var title_root: [1024]u16 = root;
            var length = root_length;
            if (length + 1 + name_length < title_root.len) {
                title_root[length] = '\\';
                length += 1;
                @memcpy(title_root[length..][0..name_length], found.name[0..name_length]);
                length += name_length;
                title_root[length] = 0;
                scanTitleSaveSlots(&title_root, length, found.name[0..name_length]);
            }
        }
        if (Win32.FindNextFileW(handle, &found) == 0) break;
    }
}

fn scanTitleSaveSlots(root: *[1024]u16, root_length: usize, title_id: []const u16) void {
    const pattern = w("\\*");
    const pattern_length = wideLength(pattern);
    if (root_length + pattern_length >= root.len) return;
    @memcpy(root[root_length..][0..pattern_length], pattern[0..pattern_length]);
    root[root_length + pattern_length] = 0;

    var found: Win32.FindData = undefined;
    const handle = Win32.FindFirstFileW(@ptrCast(root), &found);
    if (@intFromPtr(handle) == Win32.invalid_handle) return;
    defer _ = Win32.FindClose(handle);
    while (true) {
        const is_directory = found.attributes & Win32.file_attribute_directory != 0;
        const name_length = wideLength(@ptrCast(&found.name));
        if (is_directory and name_length != 0 and found.name[0] != '.' and save_slot_count < save_slots.len) {
            var slot = SaveSlot{};
            slot.title_id_length = @min(title_id.len, slot.title_id.len - 1);
            @memcpy(slot.title_id[0..slot.title_id_length], title_id[0..slot.title_id_length]);
            slot.name_length = @min(name_length, slot.name.len - 1);
            @memcpy(slot.name[0..slot.name_length], found.name[0..slot.name_length]);
            slot.detail_length = describeSlot(root, root_length, found.name[0..name_length], &slot.detail);
            save_slots[save_slot_count] = slot;
            save_slot_count += 1;
        }
        if (Win32.FindNextFileW(handle, &found) == 0) break;
    }
    root[root_length] = 0;
}

/// Reads the title a slot recorded for itself, falling back to its size.
///
/// The descriptive parameters are what a save browser is for: a directory name
/// is chosen by the game and often means nothing to the player.
fn describeSlot(
    root: *[1024]u16,
    root_length: usize,
    name: []const u16,
    output: *[96]u16,
) usize {
    var path: [1024]u16 = undefined;
    @memcpy(path[0..root_length], root[0..root_length]);
    var length = root_length;
    const separator = w("\\");
    const tail = w("\\sce_sys\\param.txt");
    if (length + name.len + wideLength(tail) + 2 >= path.len) return 0;
    const separator_length = wideLength(separator);
    @memcpy(path[length..][0..separator_length], separator[0..separator_length]);
    length += separator_length;
    @memcpy(path[length..][0..name.len], name);
    length += name.len;
    const tail_length = wideLength(tail);
    @memcpy(path[length..][0..tail_length], tail[0..tail_length]);
    length += tail_length;
    path[length] = 0;

    var contents: [512]u8 = undefined;
    const read = readSmallFile(@ptrCast(&path), &contents) orelse return 0;
    const title = parameterValue(read, "title=") orelse return 0;
    var written: usize = 0;
    for (title) |byte| {
        if (written + 1 >= output.len) break;
        output[written] = byte;
        written += 1;
    }
    output[written] = 0;
    return written;
}

/// Reads the first record of a parameter file. Only the title is shown, so the
/// rest of the file is not parsed.
fn parameterValue(document: []const u8, key: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < document.len) {
        var end = cursor;
        while (end < document.len and document[end] != '\n') end += 1;
        var line = document[cursor..end];
        while (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > key.len and std.mem.eql(u8, line[0..key.len], key)) {
            const value = line[key.len..];
            return if (value.len == 0) null else value;
        }
        cursor = end + 1;
    }
    return null;
}

fn readSmallFile(path: [*:0]const u16, buffer: []u8) ?[]const u8 {
    const handle = Win32.CreateFileW(
        path,
        Win32.generic_read,
        Win32.file_share_read,
        null,
        Win32.open_existing,
        0,
        null,
    );
    if (@intFromPtr(handle) == Win32.invalid_handle) return null;
    defer _ = Win32.CloseHandle(handle);
    var read: u32 = 0;
    if (Win32.ReadFile(handle, buffer.ptr, @intCast(buffer.len), &read, null) == 0) return null;
    return buffer[0..read];
}

fn sameFolder(first: []const u16, second: []const u16) bool {
    if (first.len == 0 or first.len != second.len) return false;
    return Win32.CompareStringOrdinal(first.ptr, @intCast(first.len), second.ptr, @intCast(second.len), 1) == Win32.cstr_equal;
}

fn childPath(output: *[1024]u16, folder: []const u16, comptime suffix: []const u8) usize {
    if (folder.len >= output.len) return 0;
    @memcpy(output[0..folder.len], folder);
    var converted: [128]u16 = undefined;
    const suffix_length = std.unicode.utf8ToUtf16Le(&converted, suffix) catch return 0;
    if (folder.len + suffix_length >= output.len) return 0;
    @memcpy(output[folder.len..][0..suffix_length], converted[0..suffix_length]);
    const length = folder.len + suffix_length;
    output[length] = 0;
    return length;
}

fn loadGameIcon(folder: []const u16) Win32.Bitmap {
    if (!gdiplus_ready) return null;
    var path: [1024]u16 = @splat(0);
    if (childPath(&path, folder, "\\sce_sys\\icon0.png") == 0) return null;
    if (Win32.GetFileAttributesW(@ptrCast(&path)) == Win32.invalid_file_attributes) return null;

    var source: Win32.GdiPlusImage = null;
    if (Win32.GdipCreateBitmapFromFile(@ptrCast(&path), &source) != 0) return null;
    const source_image = source orelse return null;
    defer _ = Win32.GdipDisposeImage(source_image);

    var thumbnail: Win32.GdiPlusImage = null;
    if (Win32.GdipGetImageThumbnail(source_image, 136, 136, &thumbnail, null, null) != 0) return null;
    const thumbnail_image = thumbnail orelse return null;
    defer _ = Win32.GdipDisposeImage(thumbnail_image);

    // The card uses an opaque GDI blit. Flatten transparent PNG pixels against
    // its background while GDI+ still understands the source alpha channel.
    var bitmap: Win32.Bitmap = null;
    if (Win32.GdipCreateHBITMAPFromBitmap(thumbnail_image, &bitmap, 0xff1b1f25) != 0) return null;
    return bitmap;
}

fn fallbackFolderTitle(folder: []const u16, output: *[128]u16) usize {
    var start = folder.len;
    while (start > 0 and folder[start - 1] != '\\' and folder[start - 1] != '/') : (start -= 1) {}
    const length = @min(folder.len - start, output.len - 1);
    @memcpy(output[0..length], folder[start..][0..length]);
    output[length] = 0;
    return length;
}

fn loadRecentGame(folder: []const u16) ?RecentGame {
    if (folder.len == 0 or folder.len >= 1024) return null;
    var game = RecentGame{};
    @memcpy(game.folder[0..folder.len], folder);
    game.folder_length = folder.len;

    var path: [1024]u16 = @splat(0);
    if (childPath(&path, folder, "\\sce_sys\\param.json") != 0) {
        var document: [8192]u8 = undefined;
        if (readSmallFile(@ptrCast(&path), &document)) |bytes| {
            if (jsonStringValue(bytes, "\"titleName\"")) |value| {
                game.title_length = std.unicode.utf8ToUtf16Le(&game.title, value) catch 0;
                game.title[game.title_length] = 0;
            }
            if (jsonStringValue(bytes, "\"titleId\"")) |value| {
                game.identifier_length = std.unicode.utf8ToUtf16Le(&game.identifier, value) catch 0;
                game.identifier[game.identifier_length] = 0;
            }
        }
    }
    if (game.title_length == 0) game.title_length = fallbackFolderTitle(folder, &game.title);
    game.icon = loadGameIcon(folder);
    return game;
}

fn recentKey(index: usize, output: *[32]u16) void {
    var utf8: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&utf8);
    stream.print("path_{d}", .{index}) catch return;
    const converted = std.unicode.utf8ToUtf16Le(output, stream.buffered()) catch return;
    output[converted] = 0;
}

fn saveRecentGames() void {
    if (ini_path_length == 0) return;
    for (0..maximum_recent_games) |index| {
        var key: [32]u16 = @splat(0);
        recentKey(index, &key);
        const value: ?[*:0]const u16 = if (index < recent_game_count)
            @ptrCast(&recent_games[index].folder)
        else
            null;
        _ = Win32.WritePrivateProfileStringW(w("recent"), @ptrCast(&key), value, @ptrCast(&ini_path));
    }
}

fn rememberGameFolder(folder: []const u16, persist: bool) void {
    const candidate = loadRecentGame(folder) orelse return;
    var existing: ?usize = null;
    for (recent_games[0..recent_game_count], 0..) |game, index| {
        if (sameFolder(game.folder[0..game.folder_length], folder)) {
            existing = index;
            break;
        }
    }

    if (existing) |index| {
        if (recent_games[index].icon != null) _ = Win32.DeleteObject(recent_games[index].icon);
        var cursor = index;
        while (cursor > 0) : (cursor -= 1) recent_games[cursor] = recent_games[cursor - 1];
    } else {
        if (recent_game_count == maximum_recent_games) {
            if (recent_games[maximum_recent_games - 1].icon != null) {
                _ = Win32.DeleteObject(recent_games[maximum_recent_games - 1].icon);
            }
        } else {
            recent_game_count += 1;
        }
        var cursor = recent_game_count - 1;
        while (cursor > 0) : (cursor -= 1) recent_games[cursor] = recent_games[cursor - 1];
    }
    recent_games[0] = candidate;
    refreshLibraryMatches();
    showLibraryPage(0);
    if (persist) saveRecentGames();
}

fn loadRecentGames() void {
    if (ini_path_length == 0) return;
    for (0..maximum_recent_games) |index| {
        var key: [32]u16 = @splat(0);
        recentKey(index, &key);
        var folder: [1024]u16 = @splat(0);
        const length = Win32.GetPrivateProfileStringW(w("recent"), @ptrCast(&key), w(""), &folder, folder.len, @ptrCast(&ini_path));
        if (length == 0) continue;
        const game = loadRecentGame(folder[0..length]) orelse continue;
        if (recent_game_count == maximum_recent_games) break;
        recent_games[recent_game_count] = game;
        recent_game_count += 1;
    }
    refreshLibraryMatches();
}

fn destroyRecentGames() void {
    showLibraryPage(0);
    for (recent_games[0..recent_game_count]) |game| {
        if (game.icon != null) _ = Win32.DeleteObject(game.icon);
    }
    recent_game_count = 0;
    library_match_count = 0;
}

/// Removes only the launcher's reference. The installed game and every save
/// remain untouched on disk.
fn removeRecentGame(index: usize) void {
    if (index >= recent_game_count) return;
    const removed_selected = sameFolder(
        recent_games[index].folder[0..recent_games[index].folder_length],
        game_folder[0..game_folder_length],
    );
    if (recent_games[index].icon != null) _ = Win32.DeleteObject(recent_games[index].icon);

    var cursor = index;
    while (cursor + 1 < recent_game_count) : (cursor += 1) {
        recent_games[cursor] = recent_games[cursor + 1];
    }
    recent_game_count -= 1;
    recent_games[recent_game_count] = .{};
    hovered_recent_game = null;
    hovered_recent_remove = false;
    // Emptying the last page leaves the view on one that no longer exists;
    // refreshing the matches clamps it back.
    refreshLibraryMatches();
    saveRecentGames();

    if (removed_selected) {
        @memset(&game_folder, 0);
        game_folder_length = 0;
        refreshTitleIdentifier();
        saveSettings();
    }
    setStatusPhrase(.status_game_removed, false);
}

fn selectRecentGame(index: usize) void {
    if (index >= recent_game_count) return;
    const selected = recent_games[index];
    @memset(&game_folder, 0);
    @memcpy(game_folder[0..selected.folder_length], selected.folder[0..selected.folder_length]);
    game_folder_length = selected.folder_length;
    refreshTitleIdentifier();
    rememberGameFolder(game_folder[0..game_folder_length], true);
    saveSettings();
    setStatusPhrase(.status_folder_selected, false);
}

/// Reads the selected title's product code out of the document it ships.
///
/// The launcher needs the same identifier the emulator keys saves by; deriving
/// it from the folder name instead would disagree the moment a dump is renamed.
fn refreshTitleIdentifier() void {
    title_identifier_length = 0;
    invalidateSaves();
    if (game_folder_length == 0) return;

    var path: [1024]u16 = undefined;
    if (game_folder_length >= path.len) return;
    @memcpy(path[0..game_folder_length], game_folder[0..game_folder_length]);
    var length = game_folder_length;
    const tail = w("\\sce_sys\\param.json");
    const tail_length = wideLength(tail);
    if (length + tail_length >= path.len) return;
    @memcpy(path[length..][0..tail_length], tail[0..tail_length]);
    length += tail_length;
    path[length] = 0;

    var document: [8192]u8 = undefined;
    const text_bytes = readSmallFile(@ptrCast(&path), &document) orelse return;
    const value = jsonStringValue(text_bytes, "\"titleId\"") orelse return;
    for (value) |byte| {
        if (title_identifier_length + 1 >= title_identifier.len) break;
        title_identifier[title_identifier_length] = byte;
        title_identifier_length += 1;
    }
    title_identifier[title_identifier_length] = 0;
}

fn handleSavesClick(window: Win32.Window, x: i32, y: i32) void {
    if (!saves_open_rect.contains(x, y)) return;
    var path: [1024]u16 = undefined;
    var length = saveDirectoryPath(&path);
    if (length == 0) return;
    if (Win32.GetFileAttributesW(@ptrCast(&path)) == Win32.invalid_file_attributes) {
        length = saveRootDirectoryPath(&path);
        if (length == 0 or Win32.GetFileAttributesW(@ptrCast(&path)) == Win32.invalid_file_attributes) return;
    }
    _ = Win32.ShellExecuteW(window, w("open"), @ptrCast(&path), null, null, Win32.show_normal);
}

fn drawSaves(dc: Win32.DeviceContext) void {
    pageHeading(dc, .saves_heading, .saves_subtitle);
    if (!save_scan_done) scanSaves();

    button(dc, saves_open_rect, .saves_open_folder, false);

    if (save_slot_count == 0) {
        card(dc, .{ .left = 282, .top = 200, .right = 1086, .bottom = 268 });
        localizedText(dc, .saves_empty, .{ .left = 306, .top = 224, .right = 1062, .bottom = 248 }, 0x008b817a, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
        return;
    }

    for (save_slots[0..save_slot_count], 0..) |slot, index| {
        const top = 200 + @as(i32, @intCast(index)) * 44;
        if (top > 660) break;
        roundFill(dc, .{ .left = 282, .top = top, .right = 1086, .bottom = top + 38 }, 8, 0x00251f1b);
        text(dc, &slot.title_id, @intCast(slot.title_id_length), .{ .left = 300, .top = top + 10, .right = 410, .bottom = top + 32 }, 0x00ffac64, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
        text(dc, &slot.name, @intCast(slot.name_length), .{ .left = 425, .top = top + 9, .right = 675, .bottom = top + 32 }, 0x00f4f0ea, medium_font, Win32.dt_left | Win32.dt_end_ellipsis);
        if (slot.detail_length != 0) {
            text(dc, &slot.detail, @intCast(slot.detail_length), .{ .left = 690, .top = top + 10, .right = 1066, .bottom = top + 32 }, 0x009b9088, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
        }
    }
}

fn drawSettings(dc: Win32.DeviceContext) void {
    pageHeading(dc, .settings_heading, .settings_subtitle);
    localizedText(dc, .language, .{ .left = 282, .top = 158, .right = 1086, .bottom = 180 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    for (language_rects, language_labels, 0..) |rectangle, label, index| {
        drawLanguageCard(dc, @enumFromInt(index), rectangle, label);
    }

    localizedText(dc, .output_resolution, .{ .left = 282, .top = 332, .right = 776, .bottom = 354 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    for (resolution_rects, display_mode.choices) |rectangle, mode| {
        const selected = output_mode == mode;
        roundFill(dc, rectangle, 10, if (selected) 0x0042362e else 0x00251f1b);
        if (selected) roundFill(dc, .{ .left = rectangle.left + 12, .top = rectangle.top + 22, .right = rectangle.left + 22, .bottom = rectangle.top + 32 }, 5, 0x00ffac64);
        textUtf8(dc, mode.label(), .{ .left = rectangle.left + 32, .top = rectangle.top + 17, .right = rectangle.right - 8, .bottom = rectangle.bottom - 10 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    }
    localizedText(dc, .output_resolution_description, .{ .left = 282, .top = 420, .right = 776, .bottom = 458 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_word_break);

    localizedText(dc, .render_preset, .{ .left = 796, .top = 332, .right = 1086, .bottom = 354 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    for (preset_rects, performance_mode.choices, [_]Phrase{ .preset_speed, .preset_graphics }) |rectangle, mode, label| {
        const selected = render_preset == mode;
        roundFill(dc, rectangle, 10, if (selected) 0x0042362e else 0x00251f1b);
        if (selected) roundFill(dc, .{ .left = rectangle.left + 12, .top = rectangle.top + 22, .right = rectangle.left + 22, .bottom = rectangle.top + 32 }, 5, 0x00ffac64);
        localizedText(dc, label, .{ .left = rectangle.left + 32, .top = rectangle.top + 17, .right = rectangle.right - 8, .bottom = rectangle.bottom - 10 }, 0x00f4f0ea, medium_font, Win32.dt_left | Win32.dt_end_ellipsis);
    }
    localizedText(dc, .render_preset_description, .{ .left = 796, .top = 420, .right = 1086, .bottom = 458 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_word_break);

    for (settings_toggle_rects, [_]Phrase{ .sound_output, .fps_counter, .game_performance }, [_]Phrase{ .sound_output_description, .fps_counter_description, .game_performance_description }, [_]bool{ sound_enabled, show_fps, game_performance }) |rectangle, heading, description, enabled| {
        card(dc, rectangle);
        localizedText(dc, heading, .{ .left = rectangle.left + 20, .top = 476, .right = rectangle.right - 90, .bottom = 501 }, 0x00f4f0ea, medium_font, Win32.dt_left | Win32.dt_end_ellipsis);
        localizedText(dc, description, .{ .left = rectangle.left + 20, .top = 507, .right = rectangle.right - 20, .bottom = 544 }, 0x008b817a, small_font, Win32.dt_left | Win32.dt_word_break);
        drawToggle(dc, rectangle.right - 78, 474, enabled);
    }

    card(dc, .{ .left = 282, .top = 560, .right = 1086, .bottom = 640 });
    localizedText(dc, .graphics_api, .{ .left = 302, .top = 567, .right = 640, .bottom = 591 }, 0x009b9088, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
    drawGraphicsApiButtons(dc, &graphics_api_rects);
    localizedText(dc, .graphics_api_description, .{ .left = 660, .top = 572, .right = 1066, .bottom = 637 }, 0x00aaa098, small_font, Win32.dt_left | Win32.dt_word_break);

    card(dc, .{ .left = 282, .top = 650, .right = 1086, .bottom = 714 });
    text(dc, w("PS5PCEM"), -1, .{ .left = 310, .top = 654, .right = 500, .bottom = 680 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    localizedText(dc, .author, .{ .left = 310, .top = 684, .right = 840, .bottom = 708 }, 0x00ffac64, regular_font, Win32.dt_left | Win32.dt_end_ellipsis);
    text(dc, w("GPL-3.0-or-later"), -1, .{ .left = 860, .top = 684, .right = 1048, .bottom = 708 }, 0x008b817a, regular_font, Win32.dt_right);
}

fn drawGraphicsApiButtons(dc: Win32.DeviceContext, rectangles: *const [2]Rect) void {
    for (rectangles, graphics_api.choices) |rectangle, api| {
        const selected = selected_graphics_api == api;
        roundFill(dc, rectangle, 8, if (selected) 0x0042362e else 0x00251f1b);
        if (selected) roundFill(dc, .{ .left = rectangle.left + 12, .top = rectangle.top + 15, .right = rectangle.left + 22, .bottom = rectangle.top + 25 }, 5, 0x00ffac64);
        textUtf8(dc, api.label(), .{ .left = rectangle.left + 32, .top = rectangle.top + 10, .right = rectangle.right - 8, .bottom = rectangle.bottom - 5 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    }
}

/// A segmented row: the chosen limit is lit and drawn in the accent colour.
fn drawFrameLimitButtons(dc: Win32.DeviceContext) void {
    for (library_frame_limit_rects, frame_limit.choices) |rectangle, limit| {
        const selected = selected_frame_limit == limit;
        roundFill(dc, rectangle, 8, if (selected) 0x0042362e else 0x00251f1b);
        const color: u32 = if (selected) 0x00ffac64 else 0x00f4f0ea;
        const area = Rect{ .left = rectangle.left + 4, .top = rectangle.top + 10, .right = rectangle.right - 4, .bottom = rectangle.bottom - 5 };
        if (limit == .unlimited) {
            localizedText(dc, .fps_unlimited, area, color, medium_font, Win32.dt_center | Win32.dt_end_ellipsis);
        } else {
            textUtf8(dc, limit.value(), area, color, medium_font, Win32.dt_center);
        }
    }
}

fn pageHeading(dc: Win32.DeviceContext, heading: Phrase, subtitle: Phrase) void {
    pageHeadingBefore(dc, heading, subtitle, update_rect.left - 16);
}

/// The library shares the heading row with its search box, so its title stops
/// short of it and is shortened with an ellipsis rather than drawn under it.
fn pageHeadingBefore(dc: Win32.DeviceContext, heading: Phrase, subtitle: Phrase, heading_right: i32) void {
    localizedText(dc, heading, .{ .left = 282, .top = 42, .right = heading_right, .bottom = 82 }, 0x00f4f0ea, title_font, Win32.dt_left | Win32.dt_end_ellipsis);
    localizedText(dc, subtitle, .{ .left = 282, .top = 91, .right = 1086, .bottom = 118 }, 0x009b9088, regular_font, Win32.dt_left);
    drawUpdateButton(dc);
}

/// The pill that used to read EARLY BUILD, now a button that asks GitHub for
/// the latest release and then says what it found. An available update fills
/// it with the accent colour; clicking it then opens the release page.
fn drawUpdateButton(dc: Win32.DeviceContext) void {
    const background: u32 = if (update_state == .available)
        (if (hovered_update) 0x00ffb366 else 0x00ff9c3d)
    else if (hovered_update and update_state != .checking)
        0x004a3a2e
    else
        0x00342a25;
    roundFill(dc, update_rect, 14, background);
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
    // The label needs the pill's whole inner width. A narrower rectangle
    // centred the text and then clipped both of its ends, which read as a
    // misspelling rather than as truncation.
    localizedText(dc, label, .{ .left = update_rect.left + 6, .top = update_rect.top + 7, .right = update_rect.right - 6, .bottom = update_rect.bottom - 4 }, colour, small_font, Win32.dt_center | Win32.dt_end_ellipsis);
}

fn drawFooter(dc: Win32.DeviceContext) void {
    if (status_length == 0) return;
    text(dc, &status_text, @intCast(status_length), .{ .left = 600, .top = 124, .right = 1086, .bottom = 146 }, if (status_error) 0x006b77ff else 0x0068d391, small_font, languageTextFormat(language, Win32.dt_right | Win32.dt_end_ellipsis));
}

fn drawModeCard(dc: Win32.DeviceContext, mode: InputMode, rectangle: Rect, heading: Phrase, subtitle: Phrase) void {
    const selected = input_mode == mode;
    roundFill(dc, rectangle, 12, if (selected) 0x0042362e else 0x00251f1b);
    if (selected) roundFill(dc, .{ .left = rectangle.left + 14, .top = rectangle.top + 16, .right = rectangle.left + 24, .bottom = rectangle.top + 26 }, 5, 0x00ffac64);
    localizedText(dc, heading, .{ .left = rectangle.left + 36, .top = rectangle.top + 13, .right = rectangle.right - 12, .bottom = rectangle.top + 38 }, 0x00f4f0ea, medium_font, Win32.dt_left);
    // The controller subtitle shares its row with four slot buttons. Limit its
    // rectangle before applying RTL alignment so neither can cover the other.
    const subtitle_right = if (subtitle == .xinput_slot) controllerSlotRect(0).left - 8 else rectangle.right - 12;
    localizedText(dc, subtitle, .{ .left = rectangle.left + 36, .top = rectangle.top + 44, .right = subtitle_right, .bottom = rectangle.top + 66 }, 0x008b817a, small_font, Win32.dt_left | Win32.dt_end_ellipsis);
}

fn drawLanguageCard(dc: Win32.DeviceContext, value: Language, rectangle: Rect, label: []const u8) void {
    const selected = language == value;
    roundFill(dc, rectangle, 10, if (selected) 0x0042362e else 0x00251f1b);
    if (selected) roundFill(dc, .{ .left = rectangle.left + 12, .top = rectangle.top + 23, .right = rectangle.left + 22, .bottom = rectangle.top + 33 }, 5, 0x00ffac64);
    textUtf8(dc, label, .{ .left = rectangle.left + 30, .top = rectangle.top + 18, .right = rectangle.right - 8, .bottom = rectangle.bottom - 10 }, 0x00f4f0ea, medium_font, languageTextFormat(value, Win32.dt_left));
}

fn card(dc: Win32.DeviceContext, rectangle: Rect) void {
    roundFill(dc, rectangle, 14, 0x00251f1b);
}

fn button(dc: Win32.DeviceContext, rectangle: Rect, label: Phrase, disabled: bool) void {
    roundFill(dc, rectangle, 10, if (disabled) 0x00352c27 else 0x00ff9c3d);
    localizedText(dc, label, .{ .left = rectangle.left + 12, .top = rectangle.top + 14, .right = rectangle.right - 12, .bottom = rectangle.bottom - 8 }, if (disabled) 0x007d736c else 0x00181510, medium_font, Win32.dt_center);
}

fn drawToggle(dc: Win32.DeviceContext, x: i32, y: i32, enabled: bool) void {
    roundFill(dc, .{ .left = x, .top = y, .right = x + 58, .bottom = y + 30 }, 15, if (enabled) 0x00ff9c3d else 0x00483d36);
    const knob_x = if (enabled) x + 32 else x + 4;
    roundFill(dc, .{ .left = knob_x, .top = y + 4, .right = knob_x + 22, .bottom = y + 26 }, 11, 0x00fffaf5);
}

fn fill(dc: Win32.DeviceContext, rectangle: Rect, color: u32) void {
    const brush = Win32.CreateSolidBrush(color) orelse return;
    defer _ = Win32.DeleteObject(brush);
    var native = Win32.NativeRect{ .left = rectangle.left, .top = rectangle.top, .right = rectangle.right, .bottom = rectangle.bottom };
    _ = Win32.FillRect(dc, &native, brush);
}

fn roundFill(dc: Win32.DeviceContext, rectangle: Rect, radius: i32, color: u32) void {
    const brush = Win32.CreateSolidBrush(color) orelse return;
    defer _ = Win32.DeleteObject(brush);
    const old_brush = Win32.SelectObject(dc, brush);
    const old_pen = Win32.SelectObject(dc, Win32.GetStockObject(Win32.null_pen));
    _ = Win32.RoundRect(dc, rectangle.left, rectangle.top, rectangle.right, rectangle.bottom, radius, radius);
    _ = Win32.SelectObject(dc, old_brush);
    _ = Win32.SelectObject(dc, old_pen);
}

fn drawBitmap(dc: Win32.DeviceContext, bitmap: Win32.Bitmap, rectangle: Rect) void {
    const memory_dc = Win32.CreateCompatibleDC(dc) orelse return;
    defer _ = Win32.DeleteDC(memory_dc);
    const previous = Win32.SelectObject(memory_dc, bitmap);
    _ = Win32.SetStretchBltMode(dc, Win32.halftone);
    _ = Win32.StretchBlt(
        dc,
        rectangle.left,
        rectangle.top,
        rectangle.right - rectangle.left,
        rectangle.bottom - rectangle.top,
        memory_dc,
        0,
        0,
        136,
        136,
        Win32.source_copy,
    );
    _ = Win32.SelectObject(memory_dc, previous);
}

fn text(
    dc: Win32.DeviceContext,
    value: [*]const u16,
    length: i32,
    rectangle: Rect,
    color: u32,
    font: Win32.Font,
    format: u32,
) void {
    _ = Win32.SetBkMode(dc, Win32.transparent);
    _ = Win32.SetTextColor(dc, color);
    const previous = Win32.SelectObject(dc, font);
    var native = Win32.NativeRect{ .left = rectangle.left, .top = rectangle.top, .right = rectangle.right, .bottom = rectangle.bottom };
    _ = Win32.DrawTextW(dc, value, length, &native, format | Win32.dt_no_prefix);
    _ = Win32.SelectObject(dc, previous);
}

fn textUtf8(dc: Win32.DeviceContext, value: []const u8, rectangle: Rect, color: u32, font: Win32.Font, format: u32) void {
    var buffer: [512]u16 = undefined;
    const converted = std.unicode.utf8ToUtf16Le(&buffer, value) catch return;
    text(dc, &buffer, @intCast(converted), rectangle, color, font, format);
}

fn localizedText(dc: Win32.DeviceContext, phrase: Phrase, rectangle: Rect, color: u32, font: Win32.Font, format: u32) void {
    textUtf8(dc, tr(phrase), rectangle, color, font, languageTextFormat(language, format));
}

fn languageTextFormat(value: Language, format: u32) u32 {
    if (value != .arabic) return format;
    // Give GDI the paragraph direction for Arabic shaping and mixed Latin text.
    // Keep centered buttons centered; paths, artwork and key names use text()
    // directly and retain their own direction.
    const alignment = if (format & (Win32.dt_center | Win32.dt_right) == 0) Win32.dt_right else @as(u32, 0);
    return format | alignment | Win32.dt_rtl_reading;
}

fn chooseGameFolder(owner: Win32.Window) void {
    var display: [1024]u16 = [_]u16{0} ** 1024;
    var dialog_title: [256]u16 = [_]u16{0} ** 256;
    const dialog_title_length = std.unicode.utf8ToUtf16Le(&dialog_title, tr(.browse_dialog)) catch return;
    dialog_title[dialog_title_length] = 0;
    var browse = Win32.BrowseInfoW{
        .owner = owner,
        .root = null,
        .display_name = &display,
        .title = @ptrCast(&dialog_title),
        .flags = Win32.bif_return_only_fs_dirs | Win32.bif_new_dialog_style,
        .callback = null,
        .l_param = 0,
        .image = 0,
    };
    const item = Win32.SHBrowseForFolderW(&browse) orelse return;
    defer Win32.CoTaskMemFree(item);
    if (Win32.SHGetPathFromIDListW(item, &game_folder) == 0) return;
    game_folder_length = wideLength(@ptrCast(&game_folder));
    refreshTitleIdentifier();
    clearSearch();
    rememberGameFolder(game_folder[0..game_folder_length], true);
    saveSettings();
    setStatusPhrase(.status_folder_selected, false);
}

fn extractPackage(owner: Win32.Window) void {
    var extractor: [1024]u16 = [_]u16{0} ** 1024;
    const extractor_len = siblingExecutable("pkgextractor.exe", &extractor);
    if (extractor_len == 0 or Win32.GetFileAttributesW(@ptrCast(&extractor)) == Win32.invalid_file_attributes) {
        setStatusPhrase(.status_extractor_missing, true);
        return;
    }

    var filter: [96]u16 = @splat(0);
    var filter_len: usize = 0;
    const filter_parts = [_][]const u8{ "PS5 PKG (*.pkg)", "*.pkg" };
    for (filter_parts) |part| {
        const converted = std.unicode.utf8ToUtf16Le(filter[filter_len..], part) catch return;
        filter_len += converted;
        filter[filter_len] = 0;
        filter_len += 1;
    }

    var dialog_title: [256]u16 = @splat(0);
    const dialog_title_length = std.unicode.utf8ToUtf16Le(&dialog_title, tr(.extract_pkg_dialog)) catch return;
    dialog_title[dialog_title_length] = 0;

    var pkg_path: [1024]u16 = @splat(0);
    var ofn = Win32.OpenFileNameW{
        .size = @sizeOf(Win32.OpenFileNameW),
        .owner = owner,
        .filter = @ptrCast(&filter),
        .file = &pkg_path,
        .max_file = pkg_path.len,
        .title = @ptrCast(&dialog_title),
        .flags = Win32.ofn_explorer | Win32.ofn_file_must_exist | Win32.ofn_path_must_exist | Win32.ofn_hide_readonly,
        .def_ext = w("pkg"),
    };
    if (Win32.GetOpenFileNameW(&ofn) == 0) return;

    var out_path: [1024]u16 = @splat(0);
    const pkg_len = wideLength(@ptrCast(&pkg_path));
    @memcpy(out_path[0..pkg_len], pkg_path[0..pkg_len]);
    var out_len = pkg_len;
    while (out_len > 0 and out_path[out_len - 1] != '.') : (out_len -= 1) {}
    if (out_len == 0) {
        out_len = pkg_len;
    } else {
        out_len -= 1;
    }
    out_path[out_len] = 0;

    var command: [4096]u16 = [_]u16{0} ** 4096;
    var length: usize = 0;
    appendWide(&command, &length, w("\""));
    appendWideSlice(&command, &length, extractor[0..extractor_len]);
    appendWide(&command, &length, w("\" \""));
    appendWideSlice(&command, &length, pkg_path[0..pkg_len]);
    appendWide(&command, &length, w("\" -o \""));
    appendWideSlice(&command, &length, out_path[0..out_len]);
    appendWide(&command, &length, w("\""));
    command[length] = 0;

    // The extractor writes both streams into one pipe; only its end of the
    // pipe is inheritable, so the child holds no other launcher handle.
    var security = Win32.SecurityAttributes{ .inherit = 1 };
    var read_end: Win32.Handle = null;
    var write_end: Win32.Handle = null;
    if (Win32.CreatePipe(&read_end, &write_end, &security, 0) == 0) {
        setStatusPhrase(.status_extract_failed, true);
        return;
    }
    _ = Win32.SetHandleInformation(read_end, Win32.handle_flag_inherit, 0);
    var startup = Win32.StartupInfoW{
        .size = @sizeOf(Win32.StartupInfoW),
        .flags = Win32.startf_use_std_handles,
        .std_output = write_end,
        .std_error = write_end,
    };
    var process: Win32.ProcessInformation = undefined;
    const started = Win32.CreateProcessW(
        @ptrCast(&extractor),
        @ptrCast(&command),
        null,
        null,
        1,
        Win32.create_no_window,
        null,
        null,
        &startup,
        &process,
    );
    // The child's copy keeps the pipe open; the reader sees its end when the
    // extractor exits.
    _ = Win32.CloseHandle(write_end);
    if (started == 0) {
        _ = Win32.CloseHandle(read_end);
        setStatusPhrase(.status_extract_failed, true);
        return;
    }
    _ = Win32.CloseHandle(process.thread);

    extract_feed = .{};
    extract_full_log.clearRetainingCapacity();
    extract_dirty.store(false, .release);
    @memcpy(extract_output[0..out_len], out_path[0..out_len]);
    extract_output_length = out_len;
    var name_start = pkg_len;
    while (name_start > 0 and pkg_path[name_start - 1] != '\\' and pkg_path[name_start - 1] != '/') : (name_start -= 1) {}
    extract_name_length = @min(pkg_len - name_start, extract_name.len);
    @memcpy(extract_name[0..extract_name_length], pkg_path[name_start..][0..extract_name_length]);

    const reader = std.Thread.spawn(.{}, readExtractorOutput, .{ owner, read_end, process.process }) catch {
        _ = Win32.TerminateProcess(process.process, 1);
        _ = Win32.CloseHandle(process.process);
        _ = Win32.CloseHandle(read_end);
        setStatusPhrase(.status_extract_failed, true);
        return;
    };
    reader.detach();
    extract_process = process.process;
    extract_state = .running;
    extract_result = .extract_running;
    status_length = 0;
    _ = Win32.SetTimer(owner, extract_timer_id, 100, null);
}

fn lockExtractFeed() void {
    while (!extract_lock.tryLock()) std.atomic.spinLoopHint();
}

/// Runs on its own thread until the extractor closes its output.
fn readExtractorOutput(window: Win32.Window, pipe: Win32.Handle, process: Win32.Handle) void {
    var chunk: [4096]u8 = undefined;
    var line: [512]u8 = undefined;
    var line_length: usize = 0;
    while (true) {
        var read: u32 = 0;
        if (Win32.ReadFile(pipe, &chunk, chunk.len, &read, null) == 0 or read == 0) break;
        for (chunk[0..read]) |byte| {
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
    _ = Win32.CloseHandle(pipe);
    _ = Win32.WaitForSingleObject(process, Win32.infinite);
    var exit_code: u32 = 1;
    _ = Win32.GetExitCodeProcess(process, &exit_code);
    _ = Win32.PostMessageW(window, wm_extract_finished, exit_code, 0);
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
    // Keep whole UTF-8 sequences; a cut one would make the line undrawable
    // and the copied log unconvertible.
    var length = value.len;
    while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
    if (length == 0) return;
    const drawn = shownLength(value[0..length]);
    lockExtractFeed();
    if (extract_full_log.items.len + length + 2 <= extract_full_log_limit) {
        extract_full_log.appendSlice(std.heap.page_allocator, value[0..length]) catch {};
        extract_full_log.appendSlice(std.heap.page_allocator, "\r\n") catch {};
    }
    const slot = extract_feed.log_next;
    @memcpy(extract_feed.log[slot][0..drawn], value[0..drawn]);
    extract_feed.log_lengths[slot] = @intCast(drawn);
    extract_feed.log_next = (slot + 1) % extract_log_capacity;
    extract_feed.log_count = @min(extract_feed.log_count + 1, extract_log_capacity);
    extract_lock.unlock();
    extract_dirty.store(true, .release);
}

/// The prefix of a valid UTF-8 line that fits a panel row, ending on a
/// whole character.
fn shownLength(value: []const u8) usize {
    var length = @min(value.len, extract_log_bytes);
    while (length > 0 and !std.unicode.utf8ValidateSlice(value[0..length])) length -= 1;
    return length;
}

/// Puts the whole extractor log on the clipboard as Unicode text.
fn copyExtractLog(window: Win32.Window) void {
    lockExtractFeed();
    defer extract_lock.unlock();
    const log = extract_full_log.items;
    const units = std.unicode.calcUtf16LeLen(log) catch return;
    const memory = Win32.GlobalAlloc(Win32.gmem_moveable, (units + 1) * 2) orelse return;
    const locked: [*]u16 = @ptrCast(@alignCast(Win32.GlobalLock(memory) orelse {
        _ = Win32.GlobalFree(memory);
        return;
    }));
    const written = std.unicode.utf8ToUtf16Le(locked[0..units], log) catch 0;
    locked[written] = 0;
    _ = Win32.GlobalUnlock(memory);
    if (Win32.OpenClipboard(window) == 0) {
        _ = Win32.GlobalFree(memory);
        return;
    }
    defer _ = Win32.CloseClipboard();
    _ = Win32.EmptyClipboard();
    // The clipboard owns the memory once it accepts it.
    if (Win32.SetClipboardData(Win32.cf_unicode_text, memory) == null) {
        _ = Win32.GlobalFree(memory);
        return;
    }
    setStatusPhrase(.status_log_copied, false);
}

fn invalidateExtractPanel(window: Win32.Window) void {
    const panel = extract_panel_rect;
    const native = Win32.NativeRect{ .left = panel.left, .top = panel.top, .right = panel.right, .bottom = panel.bottom };
    _ = Win32.InvalidateRect(window, &native, 0);
}

fn finishExtraction(window: Win32.Window, exit_code: u32) void {
    _ = Win32.KillTimer(window, extract_timer_id);
    if (extract_process != null) _ = Win32.CloseHandle(extract_process);
    extract_process = null;
    defer _ = Win32.InvalidateRect(window, null, 0);
    if (exit_code != 0) {
        extract_state = .failed;
        extract_result = if (exit_code == 2) .status_extract_retail else .status_extract_failed;
        setStatusPhrase(extract_result, true);
        return;
    }
    const out_len = extract_output_length;
    @memcpy(game_folder[0..out_len], extract_output[0..out_len]);
    game_folder[out_len] = 0;
    game_folder_length = out_len;
    refreshTitleIdentifier();
    clearSearch();
    rememberGameFolder(game_folder[0..game_folder_length], true);
    saveSettings();
    var eboot: [1024]u16 = [_]u16{0} ** 1024;
    const found = findGameExecutable(&eboot);
    extract_state = if (found) .succeeded else .failed;
    extract_result = if (found) .status_extracted else .status_extracted_no_eboot;
    setStatusPhrase(extract_result, !found);
}

fn launchGame(owner: Win32.Window) void {
    if (game_folder_length == 0) {
        setStatusPhrase(.status_choose_folder, true);
        return;
    }
    var executable: [1024]u16 = [_]u16{0} ** 1024;
    if (!findGameExecutable(&executable)) {
        setStatusPhrase(.status_eboot_missing, true);
        return;
    }

    var runner: [1024]u16 = [_]u16{0} ** 1024;
    const runner_len = siblingExecutable("game-run.exe", &runner);
    if (runner_len == 0 or Win32.GetFileAttributesW(@ptrCast(&runner)) == Win32.invalid_file_attributes) {
        setStatusPhrase(.status_runner_missing, true);
        return;
    }

    _ = Win32.SetEnvironmentVariableW(w("PS5_AUDIO_DISABLED"), if (sound_enabled) null else w("1"));
    _ = Win32.SetEnvironmentVariableW(w("PS5_SHOW_FPS"), if (show_fps) w("1") else null);
    var resolution_value: [8]u16 = @splat(0);
    const resolution_length = std.unicode.utf8ToUtf16Le(&resolution_value, output_mode.value()) catch unreachable;
    resolution_value[resolution_length] = 0;
    _ = Win32.SetEnvironmentVariableW(w(display_mode.environment_name), @ptrCast(&resolution_value));
    _ = Win32.SetEnvironmentVariableW(w(performance_mode.environment_name), presetEnvironment());
    _ = Win32.SetEnvironmentVariableW(w(graphics_api.environment_name), if (selected_graphics_api == .d3d12) w("d3d12") else w("vulkan"));
    _ = Win32.SetEnvironmentVariableW(w(frame_limit.environment_name), switch (selected_frame_limit) {
        .fps30 => w("30"),
        .fps60 => w("60"),
        .fps120 => w("120"),
        .unlimited => w("0"),
    });
    _ = Win32.SetEnvironmentVariableW(w("PS5_GAME_PRESET"), if (game_performance) w("performance") else w("default"));
    _ = Win32.SetEnvironmentVariableW(w("PS5_INPUT_MODE"), inputModeEnvironment());
    var controller_value = [_:0]u16{@as(u16, '0') + controller_index};
    _ = Win32.SetEnvironmentVariableW(w("PS5_CONTROLLER_INDEX"), &controller_value);
    var keymap: [512]u16 = [_]u16{0} ** 512;
    buildKeymap(&keymap);
    _ = Win32.SetEnvironmentVariableW(w("PS5_KEYMAP"), @ptrCast(&keymap));

    var command: [4096]u16 = [_]u16{0} ** 4096;
    var length: usize = 0;
    appendWide(&command, &length, w("\""));
    appendWideSlice(&command, &length, runner[0..runner_len]);
    // findGameExecutable returns NUL-terminated paths.
    const executable_length = wideLength(@ptrCast(&executable));
    // Archive dumps run as a single argument; directories keep --app0.
    if (wideEndsWithZar(executable[0..executable_length])) {
        appendWide(&command, &length, w("\" \""));
        appendWideSlice(&command, &length, executable[0..executable_length]);
    } else {
        appendWide(&command, &length, w("\" --app0 \""));
        appendWideSlice(&command, &length, game_folder[0..game_folder_length]);
        appendWide(&command, &length, w("\" \""));
        appendWideSlice(&command, &length, executable[0..executable_length]);
    }
    appendWide(&command, &length, w("\""));
    command[length] = 0;

    var startup = Win32.StartupInfoW{ .size = @sizeOf(Win32.StartupInfoW) };
    var process: Win32.ProcessInformation = undefined;
    var emulator_home: [1024]u16 = @splat(0);
    if (emulatorHomeDirectory(&emulator_home) == 0) {
        setStatusPhrase(.status_launch_failed, true);
        return;
    }
    if (Win32.CreateProcessW(
        @ptrCast(&runner),
        @ptrCast(&command),
        null,
        null,
        0,
        Win32.create_new_console,
        null,
        @ptrCast(&emulator_home),
        &startup,
        &process,
    ) == 0) {
        reportLaunchFailure(owner, Win32.GetLastError());
        return;
    }
    _ = Win32.CloseHandle(process.thread);
    _ = Win32.CloseHandle(process.process);
    rememberGameFolder(game_folder[0..game_folder_length], true);
    setStatusPhrase(.status_launched, false);
    _ = Win32.ShowWindow(owner, Win32.show_minimized);
}

/// What a player can do about a refused process creation. The code is the
/// one Windows returned from CreateProcessW; nothing of the emulator has run.
fn launchFailureHint(code: u32) Phrase {
    return switch (code) {
        // ERROR_SYSTEM_INTEGRITY_* is Smart App Control and other code
        // integrity policies; 786 and 1260 are Software Restriction and
        // AppLocker style group policies.
        4550...4560, 786, 1260 => .launch_hint_policy,
        225, 226 => .launch_hint_antivirus, // ERROR_VIRUS_INFECTED / _DELETED
        5 => .launch_hint_access,
        11, 193, 216, 1392 => .launch_hint_damaged, // bad format, wrong machine, corrupt
        else => .launch_hint_generic,
    };
}

/// Tells the player why Windows refused to start game-run.exe. The status
/// line alone gave no reason, and the people who meet this are the least
/// likely to try the runner from a command prompt. Windows supplies its own
/// explanation in the user's language; the hint says what to do about it.
fn reportLaunchFailure(owner: Win32.Window, code: u32) void {
    var status: [160]u8 = undefined;
    const summary = std.fmt.bufPrint(&status, "{s} · {s} {d}", .{ tr(.status_launch_failed), tr(.launch_windows_error), code }) catch tr(.status_launch_failed);
    setStatus(summary, true);
    _ = Win32.InvalidateRect(owner, null, 0);

    var message: [4096]u16 = @splat(0);
    var length: usize = 0;
    appendUtf8(&message, &length, tr(launchFailureHint(code)));
    appendUtf8(&message, &length, "\n\n");
    var system: [1024]u16 = @splat(0);
    var system_length: usize = Win32.FormatMessageW(
        Win32.format_message_from_system | Win32.format_message_ignore_inserts,
        null,
        code,
        0,
        &system,
        system.len,
        null,
    );
    while (system_length > 0 and (system[system_length - 1] == '\r' or system[system_length - 1] == '\n' or system[system_length - 1] == ' ')) : (system_length -= 1) {}
    if (system_length != 0) {
        appendWideSlice(&message, &length, system[0..system_length]);
        appendUtf8(&message, &length, "\n");
    }
    var number: [64]u8 = undefined;
    appendUtf8(&message, &length, std.fmt.bufPrint(&number, "{s} {d} (0x{X})", .{ tr(.launch_windows_error), code, code }) catch "");
    message[@min(length, message.len - 1)] = 0;

    var title: [128]u16 = @splat(0);
    var title_length: usize = 0;
    appendUtf8(&title, &title_length, tr(.status_launch_failed));
    title[@min(title_length, title.len - 1)] = 0;
    const direction: u32 = if (language == .arabic) Win32.mb_right | Win32.mb_rtl_reading else 0;
    _ = Win32.MessageBoxW(owner, @ptrCast(&message), @ptrCast(&title), Win32.mb_ok | Win32.mb_icon_error | direction);
}

fn appendUtf8(output: []u16, length: *usize, value: []const u8) void {
    if (length.* >= output.len) return;
    const written = std.unicode.utf8ToUtf16Le(output[length.*..], value) catch return;
    length.* += written;
}

fn wideEndsWithZar(name: []const u16) bool {
    if (name.len < 4) return false;
    const tail = name[name.len - 4 ..];
    return (tail[0] == '.' and
        (tail[1] == 'z' or tail[1] == 'Z') and
        (tail[2] == 'a' or tail[2] == 'A') and
        (tail[3] == 'r' or tail[3] == 'R'));
}

/// A folder holding exactly one top-level `.zar` dump runs it. Anything else
/// keeps the classic layout: an extracted title wins over an archive.
fn findArchiveInFolder(output: *[1024]u16) bool {
    const pattern = w("*.zar");
    const pattern_length = wideLength(pattern);
    var search: [1024]u16 = @splat(0);
    if (game_folder_length + 1 + pattern_length >= search.len) return false;
    @memcpy(search[0..game_folder_length], game_folder[0..game_folder_length]);
    var length = game_folder_length;
    if (length == 0 or (search[length - 1] != '\\' and search[length - 1] != '/')) {
        search[length] = '\\';
        length += 1;
    }
    @memcpy(search[length..][0..pattern_length], pattern[0..pattern_length]);
    length += pattern_length;
    search[length] = 0;

    var found: Win32.FindData = undefined;
    // search is NUL-terminated at length, bounds-checked above.
    const handle = Win32.FindFirstFileW(@ptrCast(&search), &found);
    if (@intFromPtr(handle) == Win32.invalid_handle) return false;
    defer _ = Win32.FindClose(handle);

    var name: [260]u16 = @splat(0);
    var name_length: usize = 0;
    var count: usize = 0;
    while (true) {
        const is_directory = found.attributes & Win32.file_attribute_directory != 0;
        // The OS NUL-terminates the fixed FindData name buffer.
        const entry_length = wideLength(@ptrCast(&found.name));
        if (!is_directory and entry_length != 0 and wideEndsWithZar(found.name[0..entry_length])) {
            count += 1;
            if (count > 1) return false;
            @memcpy(name[0..entry_length], found.name[0..entry_length]);
            name[entry_length] = 0;
            name_length = entry_length;
        }
        if (Win32.FindNextFileW(handle, &found) == 0) break;
    }
    if (count != 1) return false;

    @memset(output, 0);
    @memcpy(output[0..game_folder_length], game_folder[0..game_folder_length]);
    var out_length = game_folder_length;
    if (out_length == 0 or (output[out_length - 1] != '\\' and output[out_length - 1] != '/')) {
        output[out_length] = '\\';
        out_length += 1;
    }
    if (out_length + name_length >= output.len) return false;
    @memcpy(output[out_length..][0..name_length], name[0..name_length]);
    out_length += name_length;
    output[out_length] = 0;
    return true;
}

fn findGameExecutable(output: *[1024]u16) bool {
    const suffixes = [_][]const u8{ "\\eboot.bin", "\\decrypted\\eboot.bin", "\\sce_sys\\eboot.bin" };
    for (suffixes) |suffix| {
        @memset(output, 0);
        @memcpy(output[0..game_folder_length], game_folder[0..game_folder_length]);
        var length = game_folder_length;
        var converted: [64]u16 = undefined;
        const suffix_length = std.unicode.utf8ToUtf16Le(&converted, suffix) catch continue;
        @memcpy(output[length..][0..suffix_length], converted[0..suffix_length]);
        length += suffix_length;
        output[length] = 0;
        // output is NUL-terminated at length just above.
        if (Win32.GetFileAttributesW(@ptrCast(output)) != Win32.invalid_file_attributes) return true;
    }
    // No extracted executable: the selection itself may be an archive dump,
    // or the folder holds exactly one. game-run reports a missing eboot.
    if (wideEndsWithZar(game_folder[0..game_folder_length])) {
        // game_folder stays NUL-terminated through length-checked writes.
        if (Win32.GetFileAttributesW(@ptrCast(&game_folder)) == Win32.invalid_file_attributes) return false;
        @memset(output, 0);
        @memcpy(output[0..game_folder_length], game_folder[0..game_folder_length]);
        output[game_folder_length] = 0;
        return true;
    }
    return findArchiveInFolder(output);
}

fn openGithub(owner: Win32.Window) void {
    _ = Win32.ShellExecuteW(owner, w("open"), w(github_url), null, null, Win32.show_normal);
}

fn handleUpdateClick(window: Win32.Window) void {
    switch (update_state) {
        .checking => {},
        .available => _ = Win32.ShellExecuteW(window, w("open"), w(releases_url), null, null, Win32.show_normal),
        .idle, .latest, .failed => {
            update_state = .checking;
            const checker = std.Thread.spawn(.{}, checkLatestRelease, .{window}) catch {
                finishUpdateCheck(false);
                return;
            };
            checker.detach();
        },
    }
}

/// Runs on its own thread: a slow or unreachable network must not freeze the
/// window. GitHub requires a User-Agent, which WinHttpOpen supplies.
fn checkLatestRelease(window: Win32.Window) void {
    const found = fetchLatestReleaseTag();
    _ = Win32.PostMessageW(window, wm_update_checked, @intFromBool(found), 0);
}

fn fetchLatestReleaseTag() bool {
    const session = Win32.WinHttpOpen(w("PS5PCEM-Launcher/" ++ build_options.release_version), Win32.winhttp_automatic_proxy, null, null, 0) orelse return false;
    defer _ = Win32.WinHttpCloseHandle(session);
    _ = Win32.WinHttpSetTimeouts(session, 10_000, 10_000, 10_000, 10_000);
    const connection = Win32.WinHttpConnect(session, w(latest_release_host), 443, 0) orelse return false;
    defer _ = Win32.WinHttpCloseHandle(connection);
    const request = Win32.WinHttpOpenRequest(connection, w("GET"), w(latest_release_path), null, null, null, Win32.winhttp_flag_secure) orelse return false;
    defer _ = Win32.WinHttpCloseHandle(request);
    const accept = w("Accept: application/vnd.github+json\r\n");
    _ = Win32.WinHttpAddRequestHeaders(request, accept, @intCast(wideLength(accept)), Win32.winhttp_add_header);
    if (Win32.WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) return false;
    if (Win32.WinHttpReceiveResponse(request, null) == 0) return false;
    var status: u32 = 0;
    var status_size: u32 = @sizeOf(u32);
    if (Win32.WinHttpQueryHeaders(request, Win32.winhttp_query_status_code | Win32.winhttp_query_flag_number, null, &status, &status_size, null) == 0 or status != 200) return false;

    // The tag comes near the start of the document, ahead of the release
    // notes and asset list, so the first part of a long response is enough.
    var document: [16 * 1024]u8 = undefined;
    var length: usize = 0;
    while (length < document.len) {
        var read: u32 = 0;
        if (Win32.WinHttpReadData(request, document[length..].ptr, @intCast(document.len - length), &read) == 0) return false;
        if (read == 0) break;
        length += read;
    }
    const tag = jsonStringValue(document[0..length], "\"tag_name\"") orelse return false;
    if (tag.len == 0 or tag.len > update_remote_tag.len or parseReleaseVersion(tag) == null) return false;
    @memcpy(update_remote_tag[0..tag.len], tag);
    update_remote_tag_length = tag.len;
    return true;
}

fn finishUpdateCheck(found: bool) void {
    const remote = if (found) parseReleaseVersion(update_remote_tag[0..update_remote_tag_length]) else null;
    const local = parseReleaseVersion(build_options.release_version);
    if (remote == null or local == null) {
        update_state = .failed;
        setStatusPhrase(.status_update_failed, true);
        return;
    }
    if (isNewerRelease(remote.?, local.?)) {
        update_state = .available;
        setStatusWithVersion(.status_update_available, versionDigits(update_remote_tag[0..update_remote_tag_length]));
    } else {
        update_state = .latest;
        // A development build can be ahead of the latest release; it names
        // the release it was built from, not the older one GitHub reported.
        setStatusWithVersion(.status_update_latest, build_options.release_version);
    }
}

/// Fills the `{v}` in a status phrase with a version number.
fn setStatusWithVersion(phrase: Phrase, version: []const u8) void {
    const template = tr(phrase);
    var line: [256]u8 = undefined;
    const marker = std.mem.indexOf(u8, template, "{v}") orelse return setStatus(template, false);
    const composed = std.fmt.bufPrint(&line, "{s}{s}{s}", .{ template[0..marker], version, template[marker + 3 ..] }) catch return setStatus(template, false);
    setStatus(composed, false);
}

fn openSite(owner: Win32.Window) void {
    _ = Win32.ShellExecuteW(owner, w("open"), w(site_url), null, null, Win32.show_normal);
}

fn openBoosty(owner: Win32.Window) void {
    _ = Win32.ShellExecuteW(owner, w("open"), w(boosty_url), null, null, Win32.show_normal);
}

fn inputModeTitle() Phrase {
    return switch (input_mode) {
        .controller => .gamepad,
        .keyboard => .keyboard_dualsense,
        .hybrid => .gamepad_keyboard,
    };
}

fn inputModeDescription() Phrase {
    return switch (input_mode) {
        .controller => .controller_description,
        .keyboard => .keyboard_description,
        .hybrid => .hybrid_description,
    };
}

/// The preset name game-run parses, as a wide literal.
fn presetEnvironment() [*:0]const u16 {
    return switch (render_preset) {
        .speed => w("speed"),
        .graphics => w("graphics"),
    };
}

fn inputModeEnvironment() [*:0]const u16 {
    return switch (input_mode) {
        .controller => w("controller"),
        .keyboard => w("keyboard"),
        .hybrid => w("hybrid"),
    };
}

fn buildKeymap(output: *[512]u16) void {
    const names = [_][]const u8{ "cross", "circle", "square", "triangle", "l1", "l2", "r1", "r2", "options", "touch", "up", "right", "down", "left" };
    var utf8: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&utf8);
    for (names, mapping, 0..) |name, key, index| {
        if (index != 0) stream.writeByte(',') catch return;
        stream.print("{s}={d}", .{ name, key }) catch return;
    }
    const converted = std.unicode.utf8ToUtf16Le(output, stream.buffered()) catch return;
    output[converted] = 0;
}

fn setStatus(value: []const u8, is_error: bool) void {
    @memset(&status_text, 0);
    const converted = std.unicode.utf8ToUtf16Le(&status_text, value) catch return;
    status_length = converted;
    status_error = is_error;
}

fn setStatusPhrase(phrase: Phrase, is_error: bool) void {
    setStatus(tr(phrase), is_error);
}

fn initializeIniPath() void {
    ini_path_length = Win32.GetModuleFileNameW(null, &ini_path, ini_path.len);
    if (ini_path_length == 0 or ini_path_length >= ini_path.len) return;
    while (ini_path_length > 0 and ini_path[ini_path_length - 1] != '\\') : (ini_path_length -= 1) {}
    const name = w("ps5pcem.ini");
    const name_length = wideLength(name);
    if (ini_path_length + name_length >= ini_path.len) return;
    @memcpy(ini_path[ini_path_length..][0..name_length], name[0..name_length]);
    ini_path_length += name_length;
    ini_path[ini_path_length] = 0;
}

fn siblingExecutable(comptime name: []const u8, output: *[1024]u16) usize {
    var length: usize = Win32.GetModuleFileNameW(null, output, output.len);
    if (length == 0 or length >= output.len) return 0;
    while (length > 0 and output[length - 1] != '\\') : (length -= 1) {}
    const file_name = w(name);
    const file_length = wideLength(file_name);
    if (length + file_length >= output.len) return 0;
    @memcpy(output[length..][0..file_length], file_name[0..file_length]);
    length += file_length;
    output[length] = 0;
    return length;
}

fn loadSettings() void {
    if (ini_path_length == 0) return;
    loadRecentGames();
    game_folder_length = Win32.GetPrivateProfileStringW(w("launcher"), w("game_folder"), w(""), &game_folder, game_folder.len, @ptrCast(&ini_path));
    refreshTitleIdentifier();
    if (game_folder_length != 0) rememberGameFolder(game_folder[0..game_folder_length], true);
    sound_enabled = Win32.GetPrivateProfileIntW(w("launcher"), w("sound"), 1, @ptrCast(&ini_path)) != 0;
    show_fps = Win32.GetPrivateProfileIntW(w("launcher"), w("show_fps"), 0, @ptrCast(&ini_path)) != 0;
    output_mode = display_mode.Mode.fromHeight(Win32.GetPrivateProfileIntW(w("launcher"), w("output_resolution"), display_mode.default.height(), @ptrCast(&ini_path))) orelse display_mode.default;
    render_preset = performance_mode.Mode.fromIndex(Win32.GetPrivateProfileIntW(w("launcher"), w("render_preset"), @intFromEnum(performance_mode.default), @ptrCast(&ini_path))) orelse performance_mode.default;
    var api_value: [32]u16 = @splat(0);
    const api_length = Win32.GetPrivateProfileStringW(w("launcher"), w("graphics_api"), w("vulkan"), &api_value, api_value.len, @ptrCast(&ini_path));
    var api_utf8: [96]u8 = undefined;
    const api_utf8_length = std.unicode.utf16LeToUtf8(&api_utf8, api_value[0..api_length]) catch 0;
    selected_graphics_api = graphics_api.Api.parse(api_utf8[0..api_utf8_length]) orelse graphics_api.default;
    selected_frame_limit = frame_limit.Limit.fromHz(Win32.GetPrivateProfileIntW(w("launcher"), w("fps_limit"), frame_limit.default.hz(), @ptrCast(&ini_path))) orelse frame_limit.default;
    game_performance = Win32.GetPrivateProfileIntW(w("launcher"), w("game_performance"), 1, @ptrCast(&ini_path)) != 0;
    const mode_value = Win32.GetPrivateProfileIntW(w("launcher"), w("input_mode"), 2, @ptrCast(&ini_path));
    if (mode_value <= 2) input_mode = @enumFromInt(mode_value);
    const language_value = Win32.GetPrivateProfileIntW(w("launcher"), w("language"), 0, @ptrCast(&ini_path));
    if (language_value < @typeInfo(Language).@"enum".fields.len) language = @enumFromInt(language_value);
    const controller_value = Win32.GetPrivateProfileIntW(w("launcher"), w("controller_index"), 0, @ptrCast(&ini_path));
    if (controller_value <= 3) controller_index = @intCast(controller_value);
    const view_value = Win32.GetPrivateProfileIntW(w("launcher"), w("library_view"), 0, @ptrCast(&ini_path));
    if (view_value < @typeInfo(LibraryView).@"enum".fields.len) library_view = @enumFromInt(view_value);
    for (0..mapping.len) |index| {
        var key_name: [32]u16 = [_]u16{0} ** 32;
        keyName(index, &key_name);
        const value = Win32.GetPrivateProfileIntW(w("keymap"), @ptrCast(&key_name), mapping_defaults[index], @ptrCast(&ini_path));
        if (value < 256) mapping[index] = @intCast(value);
    }
}

fn saveSettings() void {
    if (ini_path_length == 0) return;
    _ = Win32.WritePrivateProfileStringW(w("launcher"), w("game_folder"), @ptrCast(&game_folder), @ptrCast(&ini_path));
    writeIniInt(w("launcher"), w("sound"), @intFromBool(sound_enabled));
    writeIniInt(w("launcher"), w("show_fps"), @intFromBool(show_fps));
    writeIniInt(w("launcher"), w("output_resolution"), output_mode.height());
    writeIniInt(w("launcher"), w("render_preset"), @intFromEnum(render_preset));
    _ = Win32.WritePrivateProfileStringW(w("launcher"), w("graphics_api"), if (selected_graphics_api == .d3d12) w("d3d12") else w("vulkan"), @ptrCast(&ini_path));
    writeIniInt(w("launcher"), w("fps_limit"), selected_frame_limit.hz());
    writeIniInt(w("launcher"), w("game_performance"), @intFromBool(game_performance));
    writeIniInt(w("launcher"), w("input_mode"), @intFromEnum(input_mode));
    writeIniInt(w("launcher"), w("language"), @intFromEnum(language));
    writeIniInt(w("launcher"), w("controller_index"), controller_index);
    writeIniInt(w("launcher"), w("library_view"), @intFromEnum(library_view));
    for (0..mapping.len) |index| {
        var name: [32]u16 = [_]u16{0} ** 32;
        keyName(index, &name);
        writeIniInt(w("keymap"), @ptrCast(&name), mapping[index]);
    }
}

fn keyName(index: usize, output: *[32]u16) void {
    var utf8: [32]u8 = undefined;
    var stream = std.Io.Writer.fixed(&utf8);
    stream.print("key_{d}", .{index}) catch return;
    const converted = std.unicode.utf8ToUtf16Le(output, stream.buffered()) catch return;
    output[converted] = 0;
}

fn writeIniInt(section: [*:0]const u16, name: [*:0]const u16, value: u32) void {
    var utf8: [24]u8 = undefined;
    var stream = std.Io.Writer.fixed(&utf8);
    stream.print("{d}", .{value}) catch return;
    var wide: [24]u16 = [_]u16{0} ** 24;
    const converted = std.unicode.utf8ToUtf16Le(&wide, stream.buffered()) catch return;
    wide[converted] = 0;
    _ = Win32.WritePrivateProfileStringW(section, name, @ptrCast(&wide), @ptrCast(&ini_path));
}

fn keyDisplayName(key: u8, output: *[48]u16) usize {
    const scan = Win32.MapVirtualKeyW(key, 0);
    const extended: u32 = if (key >= 0x21 and key <= 0x2e) 1 << 24 else 0;
    const length = Win32.GetKeyNameTextW(@bitCast((scan << 16) | extended), output, output.len);
    if (length > 0) return @intCast(length);
    const fallback = w("Key");
    const fallback_length = wideLength(fallback);
    @memcpy(output[0..fallback_length], fallback[0..fallback_length]);
    return fallback_length;
}

fn createFonts() void {
    regular_font = Win32.CreateFontW(-16, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, w("Segoe UI"));
    medium_font = Win32.CreateFontW(-17, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, w("Segoe UI"));
    title_font = Win32.CreateFontW(-27, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, w("Segoe UI"));
    small_font = Win32.CreateFontW(-13, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, w("Segoe UI"));
}

fn destroyFonts() void {
    if (regular_font != null) _ = Win32.DeleteObject(regular_font);
    if (medium_font != null) _ = Win32.DeleteObject(medium_font);
    if (title_font != null) _ = Win32.DeleteObject(title_font);
    if (small_font != null) _ = Win32.DeleteObject(small_font);
}

fn appendWide(output: *[4096]u16, length: *usize, value: [*:0]const u16) void {
    appendWideSlice(output, length, value[0..wideLength(value)]);
}

fn appendWideSlice(output: *[4096]u16, length: *usize, value: []const u16) void {
    if (length.* + value.len >= output.len) return;
    @memcpy(output[length.*..][0..value.len], value);
    length.* += value.len;
}

fn wideLength(value: [*:0]const u16) usize {
    var length: usize = 0;
    while (value[length] != 0) : (length += 1) {}
    return length;
}

fn w(comptime value: []const u8) [*:0]const u16 {
    @setEvalBranchQuota(20_000);
    return std.unicode.utf8ToUtf16LeStringLiteral(value);
}

const VulkanReport = common.VulkanReport;
var vulkan_report: VulkanReport = .{};

/// Loads the Vulkan loader the way Windows finds it; the probe itself is
/// shared with the Linux launcher.
fn probeVulkan() void {
    if (builtin.os.tag != .windows) return;
    const library = Win32.LoadLibraryW(w("vulkan-1.dll")) orelse {
        vulkan_report.state = .no_loader;
        return;
    };
    vulkan_report = common.probeVulkan(@ptrCast(Win32.GetProcAddress(library, "vkGetInstanceProcAddr")));
}

const Win32 = if (builtin.os.tag == .windows) struct {
    const Window = ?*anyopaque;
    const Instance = ?*anyopaque;
    const Icon = ?*anyopaque;
    const Cursor = ?*anyopaque;
    const Brush = ?*anyopaque;
    const Font = ?*anyopaque;
    const Bitmap = ?*anyopaque;
    const DeviceContext = ?*anyopaque;
    const Menu = ?*anyopaque;
    const Object = ?*anyopaque;
    const Handle = ?*anyopaque;

    const Point = extern struct { x: i32, y: i32 };
    const GdiPlusImage = ?*anyopaque;
    const GdiplusStartupInput = extern struct {
        version: u32 = 1,
        debug_event_callback: ?*const anyopaque = null,
        suppress_background_thread: i32 = 0,
        suppress_external_codecs: i32 = 0,
    };
    const NativeRect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
    const Message = extern struct {
        window: Window,
        message: u32,
        word_parameter: usize,
        long_parameter: isize,
        time: u32,
        point: Point,
        private: u32,
    };
    const TrackMouseEventData = extern struct {
        size: u32,
        flags: u32,
        window: Window,
        hover_time: u32,
    };
    const PaintStruct = extern struct {
        dc: DeviceContext,
        erase: i32,
        paint: NativeRect,
        restore: i32,
        inc_update: i32,
        reserved: [32]u8,
    };
    const WindowProcedure = *const fn (Window, u32, usize, isize) callconv(.winapi) isize;
    const WndClassExW = extern struct {
        size: u32,
        style: u32,
        window_procedure: WindowProcedure,
        class_extra: i32,
        window_extra: i32,
        instance: Instance,
        icon: Icon,
        cursor: Cursor,
        background: Brush,
        menu_name: ?[*:0]const u16,
        class_name: [*:0]const u16,
        small_icon: Icon,
    };
    const BrowseInfoW = extern struct {
        owner: Window,
        root: ?*anyopaque,
        display_name: [*]u16,
        title: [*:0]const u16,
        flags: u32,
        callback: ?*const anyopaque,
        l_param: isize,
        image: i32,
    };
    const OpenFileNameW = extern struct {
        size: u32 = 0,
        owner: Window = null,
        instance: Instance = null,
        filter: ?[*]const u16 = null,
        custom_filter: ?[*]u16 = null,
        max_custom_filter: u32 = 0,
        filter_index: u32 = 0,
        file: ?[*]u16 = null,
        max_file: u32 = 0,
        file_title: ?[*]u16 = null,
        max_file_title: u32 = 0,
        initial_dir: ?[*:0]const u16 = null,
        title: ?[*:0]const u16 = null,
        flags: u32 = 0,
        file_offset: u16 = 0,
        file_extension: u16 = 0,
        def_ext: ?[*:0]const u16 = null,
        cust_data: usize = 0,
        hook: ?*anyopaque = null,
        template_name: ?[*:0]const u16 = null,
        reserved: ?*anyopaque = null,
        reserved_flags: u32 = 0,
        flags_ex: u32 = 0,
    };
    const StartupInfoW = extern struct {
        size: u32 = 0,
        reserved: ?[*]u16 = null,
        desktop: ?[*]u16 = null,
        title: ?[*]u16 = null,
        x: u32 = 0,
        y: u32 = 0,
        x_size: u32 = 0,
        y_size: u32 = 0,
        x_count_chars: u32 = 0,
        y_count_chars: u32 = 0,
        fill_attribute: u32 = 0,
        flags: u32 = 0,
        show_window: u16 = 0,
        reserved2_size: u16 = 0,
        reserved2: ?[*]u8 = null,
        std_input: Handle = null,
        std_output: Handle = null,
        std_error: Handle = null,
    };
    const SecurityAttributes = extern struct {
        length: u32 = @sizeOf(SecurityAttributes),
        descriptor: ?*anyopaque = null,
        inherit: i32 = 0,
    };
    const ProcessInformation = extern struct {
        process: Handle,
        thread: Handle,
        process_id: u32,
        thread_id: u32,
    };

    const class_redraw: u32 = 0x0001 | 0x0002;
    // WS_CLIPCHILDREN keeps the full-window repaint from drawing over the
    // search box and making it flicker.
    const window_style: u32 = 0x00c0_0000 | 0x0008_0000 | 0x0002_0000 | 0x0001_0000 | 0x0200_0000;
    const centered: i32 = @bitCast(@as(u32, 0x8000_0000));
    const show_normal: i32 = 5;
    const show_minimized: i32 = 2;
    const wm_destroy: u32 = 0x0002;
    const wm_paint: u32 = 0x000f;
    const wm_close: u32 = 0x0010;
    const wm_erase_background: u32 = 0x0014;
    const wm_timer: u32 = 0x0113;
    const wm_mouse_move: u32 = 0x0200;
    const wm_mouse_wheel: u32 = 0x020a;
    const wm_mouse_leave: u32 = 0x02a3;
    const wm_device_change: u32 = 0x0219;
    const hit_test_client: u16 = 1;
    const wm_set_cursor: u32 = 0x0020;
    // IDC_HAND is an odd numeric identifier passed in a pointer slot, so it
    // cannot carry the alignment a real UTF-16 string would.
    const hand_cursor: [*:0]align(1) const u16 = @ptrFromInt(32649);
    const app_icon_resource: [*:0]align(1) const u16 = @ptrFromInt(1);
    const wm_key_down: u32 = 0x0100;
    const wm_char: u32 = 0x0102;
    const wm_command: u32 = 0x0111;
    const wm_control_color_edit: u32 = 0x0133;
    const wm_set_font: u32 = 0x0030;
    const wm_left_button_down: u32 = 0x0201;
    const wm_left_button_up: u32 = 0x0202;
    const en_kill_focus: u16 = 0x0200;
    const en_change: u16 = 0x0300;
    const em_limit_text: u32 = 0x00c5;
    const ws_child: u32 = 0x4000_0000;
    const es_auto_horizontal_scroll: u32 = 0x0080;
    const gwlp_window_procedure: i32 = -4;
    const show_hide: i32 = 0;
    const vk_control: i32 = 0x11;
    const ibeam_cursor: [*:0]align(1) const u16 = @ptrFromInt(32513);
    const dt_vertical_center: u32 = 0x0004;
    const dt_single_line: u32 = 0x0020;
    const dt_path_ellipsis: u32 = 0x4000;
    const null_brush: i32 = 5;
    const tme_leave: u32 = 0x0000_0002;
    const transparent: i32 = 1;
    const dt_left: u32 = 0x0000;
    const dt_center: u32 = 0x0001;
    const dt_right: u32 = 0x0002;
    const dt_word_break: u32 = 0x0010;
    const dt_no_prefix: u32 = 0x0800;
    const dt_end_ellipsis: u32 = 0x8000;
    const dt_rtl_reading: u32 = 0x20000;
    const di_normal: u32 = 0x0003;
    const null_pen: i32 = 8;
    const arrow_cursor: [*:0]const u16 = @ptrFromInt(32512);
    const NativePoint = extern struct { x: i32 = 0, y: i32 = 0 };

    const FindData = extern struct {
        attributes: u32 = 0,
        creation_time: [2]u32 = .{ 0, 0 },
        access_time: [2]u32 = .{ 0, 0 },
        write_time: [2]u32 = .{ 0, 0 },
        size_high: u32 = 0,
        size_low: u32 = 0,
        reserved: [2]u32 = .{ 0, 0 },
        name: [260]u16 = @splat(0),
        alternate_name: [14]u16 = @splat(0),
    };

    const file_attribute_directory: u32 = 0x10;
    const generic_read: u32 = 0x8000_0000;
    const file_share_read: u32 = 0x0000_0001;
    const open_existing: u32 = 3;
    const invalid_handle: usize = std.math.maxInt(usize);
    const error_class_already_exists: u32 = 1410;
    const bif_return_only_fs_dirs: u32 = 0x0001;
    const bif_new_dialog_style: u32 = 0x0040;
    const coinit_apartment_threaded: u32 = 0x0002;
    const invalid_file_attributes: u32 = 0xffff_ffff;
    const create_new_console: u32 = 0x0000_0010;
    const create_no_window: u32 = 0x0800_0000;
    const startf_use_std_handles: u32 = 0x0000_0100;
    const handle_flag_inherit: u32 = 0x0000_0001;
    const wm_app: u32 = 0x8000;
    const format_message_from_system: u32 = 0x0000_1000;
    const format_message_ignore_inserts: u32 = 0x0000_0200;
    const mb_ok: u32 = 0x0000_0000;
    const mb_icon_error: u32 = 0x0000_0010;
    const mb_right: u32 = 0x0008_0000;
    const mb_rtl_reading: u32 = 0x0010_0000;
    const gmem_moveable: u32 = 0x0002;
    const cf_unicode_text: u32 = 13;
    const ofn_explorer: u32 = 0x0008_0000;
    const ofn_file_must_exist: u32 = 0x0000_1000;
    const ofn_path_must_exist: u32 = 0x0000_0800;
    const ofn_hide_readonly: u32 = 0x0000_0004;
    const infinite: u32 = 0xffff_ffff;
    const cstr_equal: i32 = 2;
    const halftone: i32 = 4;
    const source_copy: u32 = 0x00cc_0020;
    const dpi_awareness_per_monitor_v2: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) Instance;
    extern "kernel32" fn GetProcAddress(module: Instance, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) Instance;
    extern "kernel32" fn GetModuleFileNameW(module: Instance, output: [*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn CreateProcessW(application: ?[*:0]const u16, command: ?[*:0]u16, process_attributes: ?*anyopaque, thread_attributes: ?*anyopaque, inherit: i32, flags: u32, environment: ?*anyopaque, directory: ?[*:0]const u16, startup: *StartupInfoW, process: *ProcessInformation) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(handle: Handle, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeProcess(handle: Handle, exit_code: *u32) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
    extern "kernel32" fn CreatePipe(read: *Handle, write: *Handle, attributes: ?*SecurityAttributes, size: u32) callconv(.winapi) i32;
    extern "kernel32" fn SetHandleInformation(handle: Handle, mask: u32, flags: u32) callconv(.winapi) i32;
    extern "kernel32" fn TerminateProcess(handle: Handle, exit_code: u32) callconv(.winapi) i32;
    extern "user32" fn PostMessageW(Window, u32, usize, isize) callconv(.winapi) i32;
    extern "user32" fn MessageBoxW(Window, [*:0]const u16, [*:0]const u16, u32) callconv(.winapi) i32;
    extern "kernel32" fn FormatMessageW(flags: u32, source: ?*const anyopaque, message: u32, language: u32, output: [*]u16, size: u32, arguments: ?*anyopaque) callconv(.winapi) u32;
    extern "user32" fn OpenClipboard(Window) callconv(.winapi) i32;
    extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
    extern "user32" fn SetClipboardData(u32, Handle) callconv(.winapi) Handle;
    extern "user32" fn CloseClipboard() callconv(.winapi) i32;
    extern "kernel32" fn GlobalAlloc(u32, usize) callconv(.winapi) Handle;
    extern "kernel32" fn GlobalLock(Handle) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GlobalUnlock(Handle) callconv(.winapi) i32;
    extern "kernel32" fn GlobalFree(Handle) callconv(.winapi) Handle;
    extern "comdlg32" fn GetOpenFileNameW(ofn: *OpenFileNameW) callconv(.winapi) i32;
    extern "kernel32" fn CompareStringOrdinal([*]const u16, i32, [*]const u16, i32, i32) callconv(.winapi) i32;
    extern "kernel32" fn GetPrivateProfileStringW(section: [*:0]const u16, key: [*:0]const u16, default: [*:0]const u16, output: [*]u16, size: u32, file: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetPrivateProfileIntW(section: [*:0]const u16, key: [*:0]const u16, default: u32, file: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn WritePrivateProfileStringW(section: [*:0]const u16, key: [*:0]const u16, value: ?[*:0]const u16, file: [*:0]const u16) callconv(.winapi) i32;

    extern "user32" fn RegisterClassExW(class: *const WndClassExW) callconv(.winapi) u16;
    extern "user32" fn CreateWindowExW(extended_style: u32, class_name: [*:0]const u16, window_name: [*:0]const u16, style: u32, x: i32, y: i32, width: i32, height: i32, parent: Window, menu: Menu, instance: Instance, parameter: ?*anyopaque) callconv(.winapi) Window;
    extern "user32" fn DefWindowProcW(Window, u32, usize, isize) callconv(.winapi) isize;
    extern "user32" fn DestroyWindow(Window) callconv(.winapi) i32;
    extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
    extern "user32" fn ShowWindow(Window, i32) callconv(.winapi) i32;
    extern "user32" fn UpdateWindow(Window) callconv(.winapi) i32;
    extern "user32" fn GetMessageW(*Message, Window, u32, u32) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(*const Message) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(*const Message) callconv(.winapi) isize;
    extern "user32" fn LoadCursorW(Instance, [*:0]align(1) const u16) callconv(.winapi) Cursor;
    extern "user32" fn SetCursor(Cursor) callconv(.winapi) Cursor;
    extern "user32" fn AdjustWindowRect(*NativeRect, u32, i32) callconv(.winapi) i32;
    extern "user32" fn SetTimer(Window, usize, u32, ?*anyopaque) callconv(.winapi) usize;
    extern "user32" fn KillTimer(Window, usize) callconv(.winapi) i32;
    extern "user32" fn TrackMouseEvent(*TrackMouseEventData) callconv(.winapi) i32;
    extern "kernel32" fn FindFirstFileW([*:0]const u16, *FindData) callconv(.winapi) *anyopaque;
    extern "kernel32" fn FindNextFileW(*anyopaque, *FindData) callconv(.winapi) i32;
    extern "kernel32" fn FindClose(*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) Handle;
    extern "kernel32" fn ReadFile(Handle, [*]u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn GetCursorPos(*NativePoint) callconv(.winapi) i32;
    extern "user32" fn ScreenToClient(Window, *NativePoint) callconv(.winapi) i32;
    extern "user32" fn LoadIconW(Instance, ?[*:0]align(1) const u16) callconv(.winapi) Icon;
    extern "user32" fn BeginPaint(Window, *PaintStruct) callconv(.winapi) DeviceContext;
    extern "user32" fn EndPaint(Window, *const PaintStruct) callconv(.winapi) i32;
    extern "user32" fn GetClientRect(Window, *NativeRect) callconv(.winapi) i32;
    extern "user32" fn FillRect(DeviceContext, *const NativeRect, Brush) callconv(.winapi) i32;
    extern "user32" fn DrawTextW(DeviceContext, [*]const u16, i32, *NativeRect, u32) callconv(.winapi) i32;
    extern "user32" fn DrawIconEx(DeviceContext, i32, i32, Icon, i32, i32, u32, Brush, u32) callconv(.winapi) i32;
    extern "user32" fn InvalidateRect(Window, ?*const NativeRect, i32) callconv(.winapi) i32;
    extern "user32" fn SetProcessDpiAwarenessContext(?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) callconv(.winapi) u32;
    extern "user32" fn GetFocus() callconv(.winapi) Window;
    extern "user32" fn SetFocus(Window) callconv(.winapi) Window;
    extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
    extern "user32" fn SendMessageW(Window, u32, usize, isize) callconv(.winapi) isize;
    extern "user32" fn SetWindowLongPtrW(Window, i32, isize) callconv(.winapi) isize;
    extern "user32" fn CallWindowProcW(WindowProcedure, Window, u32, usize, isize) callconv(.winapi) isize;
    extern "user32" fn GetWindowTextW(Window, [*]u16, i32) callconv(.winapi) i32;
    extern "user32" fn SetWindowTextW(Window, [*:0]const u16) callconv(.winapi) i32;
    extern "user32" fn CharLowerBuffW([*]u16, u32) callconv(.winapi) u32;
    extern "user32" fn GetKeyNameTextW(long_parameter: i32, output: [*]u16, size: i32) callconv(.winapi) i32;

    extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) Brush;
    extern "gdi32" fn CreateCompatibleDC(DeviceContext) callconv(.winapi) DeviceContext;
    extern "gdi32" fn DeleteDC(DeviceContext) callconv(.winapi) i32;
    extern "gdi32" fn SetStretchBltMode(DeviceContext, i32) callconv(.winapi) i32;
    extern "gdi32" fn StretchBlt(DeviceContext, i32, i32, i32, i32, DeviceContext, i32, i32, i32, i32, u32) callconv(.winapi) i32;
    extern "gdi32" fn DeleteObject(Object) callconv(.winapi) i32;
    extern "gdi32" fn SelectObject(DeviceContext, Object) callconv(.winapi) Object;
    extern "gdi32" fn GetStockObject(i32) callconv(.winapi) Object;
    extern "gdi32" fn RoundRect(DeviceContext, i32, i32, i32, i32, i32, i32) callconv(.winapi) i32;
    extern "gdi32" fn SetBkMode(DeviceContext, i32) callconv(.winapi) i32;
    extern "gdi32" fn SetTextColor(DeviceContext, u32) callconv(.winapi) u32;
    extern "gdi32" fn SetBkColor(DeviceContext, u32) callconv(.winapi) u32;
    // SIZE has the same layout as POINT: two LONGs.
    extern "gdi32" fn GetTextExtentPoint32W(DeviceContext, [*]const u16, i32, *NativePoint) callconv(.winapi) i32;
    extern "gdi32" fn CreatePen(i32, i32, u32) callconv(.winapi) Object;
    extern "gdi32" fn Ellipse(DeviceContext, i32, i32, i32, i32) callconv(.winapi) i32;
    extern "gdi32" fn MoveToEx(DeviceContext, i32, i32, ?*NativePoint) callconv(.winapi) i32;
    extern "gdi32" fn LineTo(DeviceContext, i32, i32) callconv(.winapi) i32;
    extern "gdi32" fn CreateFontW(i32, i32, i32, i32, i32, u32, u32, u32, u32, u32, u32, u32, u32, [*:0]const u16) callconv(.winapi) Font;

    extern "gdiplus" fn GdiplusStartup(*usize, *const GdiplusStartupInput, ?*anyopaque) callconv(.winapi) i32;
    extern "gdiplus" fn GdiplusShutdown(usize) callconv(.winapi) void;
    extern "gdiplus" fn GdipCreateBitmapFromFile([*:0]const u16, *GdiPlusImage) callconv(.winapi) i32;
    extern "gdiplus" fn GdipGetImageThumbnail(GdiPlusImage, u32, u32, *GdiPlusImage, ?*const anyopaque, ?*anyopaque) callconv(.winapi) i32;
    extern "gdiplus" fn GdipCreateHBITMAPFromBitmap(GdiPlusImage, *Bitmap, u32) callconv(.winapi) i32;
    extern "gdiplus" fn GdipDisposeImage(GdiPlusImage) callconv(.winapi) i32;

    extern "shell32" fn SHBrowseForFolderW(*BrowseInfoW) callconv(.winapi) ?*anyopaque;
    extern "shell32" fn SHGetPathFromIDListW(?*anyopaque, [*]u16) callconv(.winapi) i32;
    extern "shell32" fn ShellExecuteW(Window, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) Handle;
    extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
    extern "dwmapi" fn DwmSetWindowAttribute(Window, u32, *const anyopaque, u32) callconv(.winapi) i32;

    const winhttp_automatic_proxy: u32 = 4;
    const winhttp_flag_secure: u32 = 0x0080_0000;
    const winhttp_add_header: u32 = 0x2000_0000;
    const winhttp_query_status_code: u32 = 19;
    const winhttp_query_flag_number: u32 = 0x2000_0000;
    extern "winhttp" fn WinHttpOpen([*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) Handle;
    extern "winhttp" fn WinHttpSetTimeouts(Handle, i32, i32, i32, i32) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpConnect(Handle, [*:0]const u16, u16, u32) callconv(.winapi) Handle;
    extern "winhttp" fn WinHttpOpenRequest(Handle, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, ?*const ?[*:0]const u16, u32) callconv(.winapi) Handle;
    extern "winhttp" fn WinHttpAddRequestHeaders(Handle, [*]const u16, u32, u32) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpSendRequest(Handle, ?[*]const u16, u32, ?*anyopaque, u32, u32, usize) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpReceiveResponse(Handle, ?*anyopaque) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpQueryHeaders(Handle, u32, ?[*:0]const u16, ?*anyopaque, *u32, ?*u32) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpReadData(Handle, [*]u8, u32, *u32) callconv(.winapi) i32;
    extern "winhttp" fn WinHttpCloseHandle(Handle) callconv(.winapi) i32;
} else struct {};
