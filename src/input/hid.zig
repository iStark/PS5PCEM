// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Finding and reading a Sony controller over the host's HID stack.
//!
//! Shared read/write access drives gameplay feedback; read-only fallback still
//! accepts input when another application owns output access.
//!
//! Reads are overlapped and never block. A poll drains whatever the driver has
//! queued and keeps the newest report: the queue holds several samples once a
//! frame runs long, and answering with the oldest of them would make the sticks
//! lag behind the player by however far behind the emulator had fallen.

const std = @import("std");
const builtin = @import("builtin");
const dualshock = @import("dualshock.zig");
const Mutex = @import("memory").HostMutex;
var mutex: Mutex = .{};

pub const supported = builtin.os.tag == .windows;

pub const Presence = struct {
    connected: bool = false,
    family: ?dualshock.Family = null,
    transport: ?dualshock.Transport = null,
    /// Whether the pad can also be driven, not only read.
    writable: bool = false,
};

/// How many queued reports one poll will consume before settling for what it
/// has. A driver that is producing faster than the caller polls must not turn
/// this into an unbounded loop.
const maximum_drained_reports = 32;

/// Polls between attempts to find a controller. Enumerating the HID tree is far
/// more expensive than a read, so a host with no pad attached must not pay for
/// the search on every frame.
const rediscovery_interval = 240;

/// Room for one report of any size these pads declare. Their Bluetooth
/// descriptors declare reports of several hundred bytes, and Windows sizes
/// every read and write by the longest one.
const maximum_report_bytes = 1024;

var device: Device = .{};
var polls_since_search: u32 = rediscovery_interval;
var latest: ?dualshock.Pad = null;
var write_event: ?*anyopaque = null;
var completed_reports: u64 = 0;

pub const OutputStatus = struct {
    completed_reports: u64,
    applied: ?dualshock.Output,
    pending: bool,
};

/// Diagnostic completion state; a successful queue operation alone does not
/// prove the OS completed a controller report.
pub fn outputStatus() OutputStatus {
    mutex.lock();
    defer mutex.unlock();
    return .{ .completed_reports = completed_reports, .applied = device.output.applied, .pending = device.write_pending };
}

/// Keep the newest requested state while an older HID report is in flight.
/// Completing an older write must never erase a later stop request.
const OutputQueue = struct {
    wanted: ?dualshock.Output = null,
    applied: ?dualshock.Output = null,

    fn next(self: *const OutputQueue) ?dualshock.Output {
        const wanted = self.wanted orelse return null;
        if (self.applied) |applied| if (std.meta.eql(wanted, applied)) return null;
        return wanted;
    }
};

const LightBarSetup = struct {
    first_ms: ?u64 = null,
    ready: bool = false,
    complete: bool = false,

    fn prepare(self: *LightBarSetup, output: dualshock.Output, now_ms: u64) dualshock.Output {
        if (!output.set_light_bar or self.complete) return output;
        if (self.first_ms == null) self.first_ms = now_ms;
        var next = output;
        next.set_light_bar = false;
        // A bounded fallback also permits LEDs if no enhanced input arrives.
        next.reset_light_bar = self.ready or now_ms -| self.first_ms.? >= 3500;
        return next;
    }
};

const Device = struct {
    handle: ?*anyopaque = null,
    event: ?*anyopaque = null,
    family: dualshock.Family = .dual_sense,
    /// Read from the declared report lengths when the pad is opened, because an
    /// outgoing report has to match the transport it will travel over.
    transport: ?dualshock.Transport = null,
    /// The longest input and output reports the descriptor declares. Windows
    /// accepts a ReadFile or WriteFile on the pad only at these sizes.
    input_length: u32 = 0,
    output_length: u32 = 0,
    /// False when the device could only be opened for reading, which happens
    /// when another process holds it for writing.
    writable: bool = false,
    overlapped: Overlapped = .{},
    buffer: [maximum_report_bytes]u8 = @splat(0),
    read_pending: bool = false,
    output: OutputQueue = .{},
    write_overlapped: Overlapped = .{},
    write_buffer: [maximum_report_bytes]u8 = undefined,
    write_size: u32 = 0,
    write_pending: bool = false,
    in_flight_output: dualshock.Output = .{},
    sequence: u4 = 0,
    light_bar_setup: LightBarSetup = .{},

    fn isOpen(self: Device) bool {
        return self.handle != null;
    }
};

/// The newest controller state, or null when no supported pad is attached.
pub fn poll() ?dualshock.Pad {
    if (comptime !supported) return null;
    mutex.lock();
    defer mutex.unlock();
    return pollLocked();
}

fn pollLocked() ?dualshock.Pad {
    ensureOpen();
    if (!device.isOpen()) {
        latest = null;
        return null;
    }
    drain();
    _ = pumpOutputLocked();
    return latest;
}

/// Whether a supported pad is attached, for callers that only want to show it.
pub fn presence() Presence {
    if (comptime !supported) return .{};
    mutex.lock();
    defer mutex.unlock();
    _ = pollLocked();
    if (!device.isOpen()) return .{};
    return .{ .connected = true, .family = device.family, .transport = device.transport, .writable = device.writable };
}

/// The colours the self-test walks through, in order.
const test_colours = [_][3]u8{
    .{ 255, 0, 0 },
    .{ 255, 140, 0 },
    .{ 255, 255, 0 },
    .{ 0, 255, 0 },
    .{ 0, 200, 255 },
    .{ 0, 0, 255 },
    .{ 255, 0, 255 },
};

/// How long the whole self-test lasts, and how long each colour holds. The
/// colours are spread across the run so the last one ends with it.
pub const test_duration_ms: u32 = 1000;
pub const test_step_ms: u32 = test_duration_ms / test_colours.len;

var test_elapsed_ms: u32 = 0;
var test_running = false;

/// Starts a one-second rumble with the light bar cycling through its colours.
///
/// Both motors run: they are physically different, and driving only one leaves
/// a working pad feeling like half of it is broken.
pub fn startTest() bool {
    if (comptime !supported) return false;
    mutex.lock();
    defer mutex.unlock();
    _ = pollLocked();
    if (!device.isOpen() or !device.writable) return false;
    test_elapsed_ms = 0;
    test_running = true;
    return advanceTestLocked(0);
}

/// Drives the next slice of the self-test. Returns false once it has finished,
/// having already returned the pad to rest.
pub fn advanceTest(elapsed_ms: u32) bool {
    if (comptime !supported) return false;
    mutex.lock();
    defer mutex.unlock();
    return advanceTestLocked(elapsed_ms);
}

fn advanceTestLocked(elapsed_ms: u32) bool {
    if (!test_running) return false;
    test_elapsed_ms +|= elapsed_ms;
    if (!device.isOpen() or !device.writable) {
        test_running = false;
        return false;
    }
    if (test_elapsed_ms >= test_duration_ms) {
        test_running = false;
        // Silence the motors and clear the light bar; a pad left buzzing
        // because the window closed mid-test is worse than no test at all.
        _ = send(.{});
        finishOutputLocked();
        return false;
    }
    const step = @min(test_elapsed_ms / test_step_ms, test_colours.len - 1);
    const colour = test_colours[step];
    return send(.{
        .rumble_strong = 0xa0,
        .rumble_weak = 0x60,
        .red = colour[0],
        .green = colour[1],
        .blue = colour[2],
    });
}

pub fn testRunning() bool {
    mutex.lock();
    defer mutex.unlock();
    return test_running;
}

/// The colour the light bar is showing right now, so a caller can mirror it.
pub fn testColour() ?[3]u8 {
    mutex.lock();
    defer mutex.unlock();
    if (!test_running) return null;
    const step = @min(test_elapsed_ms / test_step_ms, test_colours.len - 1);
    return test_colours[step];
}

/// Stops the self-test wherever it is and leaves the pad at rest.
pub fn stopTest() void {
    if (comptime !supported) return;
    mutex.lock();
    defer mutex.unlock();
    if (!test_running) return;
    test_running = false;
    _ = send(.{});
    finishOutputLocked();
}

/// Called by the feedback worker, never waiting on USB/Bluetooth completion.
pub fn setVibration(large: u8, small: u8) bool {
    return setFeedback(.{ .rumble_strong = large, .rumble_weak = small, .set_light_bar = false });
}

/// A complete snapshot prevents independent RGB and motor requests from
/// replacing one another while an older report is still in flight.
pub fn setFeedback(output: dualshock.Output) bool {
    if (comptime !supported) return false;
    mutex.lock();
    defer mutex.unlock();
    _ = pollLocked();
    return send(output);
}

pub fn pumpOutput() bool {
    if (comptime !supported) return false;
    mutex.lock();
    defer mutex.unlock();
    return pumpOutputLocked();
}

fn send(output: dualshock.Output) bool {
    if (!device.isOpen() or !device.writable or device.transport == null) return false;
    device.output.wanted = output;
    _ = pumpOutputLocked();
    return device.isOpen();
}

fn pumpOutputLocked() bool {
    const handle = device.handle orelse return false;
    if (device.write_pending) {
        var written: u32 = 0;
        if (Win32.GetOverlappedResult(handle, &device.write_overlapped, &written, 0) == 0) {
            if (Win32.GetLastError() == Win32.error_io_incomplete) return true;
            device.write_pending = false;
            refuseOutput();
            return false;
        }
        device.write_pending = false;
        if (written != device.write_size) {
            refuseOutput();
            return false;
        }
        device.output.applied = device.in_flight_output;
        if (device.in_flight_output.reset_light_bar) device.light_bar_setup.complete = true;
        completed_reports +%= 1;
    }
    var output = device.output.next() orelse return false;
    const transport = device.transport orelse return false;
    if (device.family == .dual_sense and transport == .bluetooth) {
        output = device.light_bar_setup.prepare(output, Win32.GetTickCount64());
        // Waiting for the LED animation must not resend unchanged motor data.
        if (device.output.applied) |applied| if (std.meta.eql(output, applied)) return true;
    }
    device.in_flight_output = output;
    output.sequence = device.sequence;
    const length = dualshock.buildOutput(device.family, transport, output, &device.write_buffer) orelse return false;
    device.sequence +%= 1;
    device.write_size = @intCast(padToDeclared(&device.write_buffer, length, device.output_length));
    device.write_overlapped = .{ .event = write_event };
    _ = Win32.ResetEvent(write_event);
    var written: u32 = 0;
    if (Win32.WriteFile(handle, &device.write_buffer, device.write_size, &written, &device.write_overlapped) != 0) {
        if (written == device.write_size) {
            device.output.applied = device.in_flight_output;
            if (device.in_flight_output.reset_light_bar) device.light_bar_setup.complete = true;
            completed_reports +%= 1;
        } else refuseOutput();
        return device.output.next() != null;
    }
    if (Win32.GetLastError() == Win32.error_io_pending) {
        device.write_pending = true;
        return true;
    }
    refuseOutput();
    return false;
}

/// Zero-pads a built report to the longest output report the pad declares.
/// Windows refuses a WriteFile of any other size; the pad acts on its own report
/// and ignores the tail, which is exactly what hidapi sends as well.
fn padToDeclared(buffer: []u8, length: usize, declared: usize) usize {
    const size = @min(@max(length, declared), buffer.len);
    @memset(buffer[length..size], 0);
    return size;
}

/// Stops driving a pad that rejected an output report, but keeps reading it.
/// An unplugged pad is noticed by the read side; any other refusal (a report
/// the stack does not accept, a driver holding the output) used to close the
/// device and drop the player's input on every rumble. Feedback then goes to
/// the XInput slot instead.
fn refuseOutput() void {
    device.writable = false;
    device.output = .{};
}

fn finishOutputLocked() void {
    const until = Win32.GetTickCount64() + 250;
    while (pumpOutputLocked() and Win32.GetTickCount64() < until) Win32.Sleep(1);
}

/// Forces the next poll to search again. The launcher calls this when Windows
/// reports a device arriving or leaving, so the display reacts immediately
/// rather than at the end of the rediscovery interval.
pub fn invalidate() void {
    if (comptime !supported) return;
    mutex.lock();
    defer mutex.unlock();
    polls_since_search = rediscovery_interval;
}

pub fn close() void {
    if (comptime !supported) return;
    mutex.lock();
    defer mutex.unlock();
    // Do not discover or write a controller which this process never used.
    if (device.output.wanted != null) {
        _ = send(.{ .set_light_bar = false, .set_motors = device.output.wanted.?.set_motors });
        finishOutputLocked();
    }
    closeDevice();
    latest = null;
}

fn ensureOpen() void {
    if (device.isOpen()) return;
    polls_since_search +|= 1;
    if (polls_since_search < rediscovery_interval) return;
    polls_since_search = 0;
    openFirstController();
}

fn closeDevice() void {
    test_running = false;
    if (device.handle) |handle| {
        // Reads and writes may originate on different host threads. CancelIo
        // cancels only the calling thread's I/O; retain storage until completion.
        var transferred: u32 = 0;
        if (device.read_pending) {
            _ = Win32.CancelIoEx(handle, &device.overlapped);
            _ = Win32.GetOverlappedResult(handle, &device.overlapped, &transferred, 1);
        }
        if (device.write_pending) {
            _ = Win32.CancelIoEx(handle, &device.write_overlapped);
            _ = Win32.GetOverlappedResult(handle, &device.write_overlapped, &transferred, 1);
        }
    }
    if (write_event) |event| {
        _ = Win32.CloseHandle(event);
        write_event = null;
    }
    if (device.handle) |handle| {
        _ = Win32.CloseHandle(handle);
    }
    if (device.event) |event| _ = Win32.CloseHandle(event);
    device = .{};
    latest = null;
}

/// Consumes every report the driver has ready, keeping the last one.
fn drain() void {
    var drained: u32 = 0;
    while (drained < maximum_drained_reports) : (drained += 1) {
        if (!device.read_pending and !beginRead()) return;
        var transferred: u32 = 0;
        if (Win32.GetOverlappedResult(device.handle.?, &device.overlapped, &transferred, 0) == 0) {
            // Still in flight is the ordinary case between reports; anything
            // else means the pad went away mid-read.
            if (Win32.GetLastError() != Win32.error_io_incomplete) closeDevice();
            return;
        }
        device.read_pending = false;
        accept(transferred);
    }
}

fn accept(transferred: u32) void {
    if (transferred == 0) return;
    const report = device.buffer[0..transferred];
    if (device.family == .dual_sense and dualshock.bluetoothLightBarReady(report)) device.light_bar_setup.ready = true;
    if (dualshock.parse(device.family, report)) |pad| latest = pad;
}

/// Starts one overlapped read. Returns false when the device is gone.
fn beginRead() bool {
    const handle = device.handle orelse return false;
    device.overlapped = .{ .event = device.event };
    var transferred: u32 = 0;
    if (Win32.ReadFile(handle, &device.buffer, device.input_length, &transferred, &device.overlapped) != 0) {
        // Completed without queuing; the payload is already in the buffer.
        accept(transferred);
        return true;
    }
    if (Win32.GetLastError() != Win32.error_io_pending) {
        closeDevice();
        return false;
    }
    device.read_pending = true;
    return true;
}

fn openFirstController() void {
    var interface_guid = Win32.hid_interface_guid;
    const set = Win32.SetupDiGetClassDevsW(
        &interface_guid,
        null,
        null,
        Win32.digcf_present | Win32.digcf_device_interface,
    );
    if (@intFromPtr(set) == Win32.invalid_handle) return;
    defer _ = Win32.SetupDiDestroyDeviceInfoList(set);

    var index: u32 = 0;
    while (true) : (index += 1) {
        var interface_data = Win32.DeviceInterfaceData{};
        if (Win32.SetupDiEnumDeviceInterfaces(set, null, &interface_guid, index, &interface_data) == 0) return;

        // The detail structure is variable length: the path follows the size
        // field, so the whole thing is read into one buffer whose declared
        // header size must stay the ABI value rather than the buffer's.
        var detail: [Win32.maximum_detail_bytes]u8 align(8) = undefined;
        const header: *Win32.DeviceInterfaceDetail = @ptrCast(&detail);
        header.* = .{};
        var required: u32 = 0;
        if (Win32.SetupDiGetDeviceInterfaceDetailW(
            set,
            &interface_data,
            header,
            detail.len,
            &required,
            null,
        ) == 0) continue;

        const path: [*:0]const u16 = @ptrCast(&header.path);
        if (tryOpen(path)) return;
    }
}

fn tryOpen(path: [*:0]const u16) bool {
    // Writing is what drives the motors and the light bar, but another process
    // may already hold the pad for output. Losing the read as well would be the
    // worse trade, so a refused write access falls back to reading only.
    var writable = true;
    var handle = Win32.CreateFileW(
        path,
        Win32.generic_read | Win32.generic_write,
        Win32.file_share_read | Win32.file_share_write,
        null,
        Win32.open_existing,
        Win32.file_flag_overlapped,
        null,
    );
    if (@intFromPtr(handle) == Win32.invalid_handle) {
        writable = false;
        handle = Win32.CreateFileW(
            path,
            Win32.generic_read,
            Win32.file_share_read | Win32.file_share_write,
            null,
            Win32.open_existing,
            Win32.file_flag_overlapped,
            null,
        );
    }
    if (@intFromPtr(handle) == Win32.invalid_handle) return false;
    var keep = false;
    defer if (!keep) {
        _ = Win32.CloseHandle(handle);
    };

    var attributes = Win32.HidAttributes{};
    if (Win32.HidD_GetAttributes(handle, &attributes) == 0) return false;
    const family = dualshock.identify(attributes.vendor, attributes.product) orelse return false;
    const lengths = reportLengths(handle) orelse return false;
    if (lengths.input == 0 or lengths.input > maximum_report_bytes) return false;
    const drivable = lengths.output != 0 and lengths.output <= maximum_report_bytes;

    const event = Win32.CreateEventW(null, 1, 0, null);
    if (event == null) return false;

    write_event = Win32.CreateEventW(null, 1, 0, null);
    device = .{
        .handle = handle,
        .event = event,
        .family = family,
        .transport = dualshock.transportFromOutputLength(lengths.output),
        .input_length = lengths.input,
        .output_length = lengths.output,
        .writable = writable and drivable and write_event != null,
    };
    keep = true;
    return true;
}

const ReportLengths = struct { input: u32, output: u32 };

fn reportLengths(handle: *anyopaque) ?ReportLengths {
    var preparsed: ?*anyopaque = null;
    if (Win32.HidD_GetPreparsedData(handle, &preparsed) == 0) return null;
    const data = preparsed orelse return null;
    defer _ = Win32.HidD_FreePreparsedData(data);
    var caps = Win32.HidpCaps{};
    if (Win32.HidP_GetCaps(data, &caps) != Win32.hidp_status_success) return null;
    return .{ .input = caps.input_report_byte_length, .output = caps.output_report_byte_length };
}

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?*anyopaque = null,
};

const Win32 = if (builtin.os.tag == .windows) struct {
    const Guid = extern struct {
        data1: u32,
        data2: u16,
        data3: u16,
        data4: [8]u8,
    };

    /// GUID_DEVINTERFACE_HID.
    const hid_interface_guid = Guid{
        .data1 = 0x4d1e55b2,
        .data2 = 0xf16f,
        .data3 = 0x11cf,
        .data4 = .{ 0x88, 0xcb, 0x00, 0x11, 0x11, 0x00, 0x00, 0x30 },
    };

    const DeviceInterfaceData = extern struct {
        size: u32 = @sizeOf(DeviceInterfaceData),
        interface_class_guid: Guid = std.mem.zeroes(Guid),
        flags: u32 = 0,
        reserved: usize = 0,
    };

    /// The ABI size of the fixed header, which is what the field must carry
    /// even though the buffer handed over is much larger. On 64-bit Windows the
    /// structure is a four-byte size followed by a two-byte-aligned path, so
    /// the declared value is eight rather than the padded Zig size.
    const detail_header_size: u32 = 8;
    const maximum_detail_bytes = 1024;

    const DeviceInterfaceDetail = extern struct {
        size: u32 = detail_header_size,
        path: [1]u16 = .{0},
    };

    const HidAttributes = extern struct {
        size: u32 = @sizeOf(HidAttributes),
        vendor: u16 = 0,
        product: u16 = 0,
        version: u16 = 0,
    };

    /// HIDP_CAPS: the three report lengths, then reserved words and the
    /// capability counts this module does not use.
    const HidpCaps = extern struct {
        usage: u16 = 0,
        usage_page: u16 = 0,
        input_report_byte_length: u16 = 0,
        output_report_byte_length: u16 = 0,
        feature_report_byte_length: u16 = 0,
        reserved: [17]u16 = @splat(0),
        counts: [10]u16 = @splat(0),
    };

    comptime {
        if (@sizeOf(HidpCaps) != 64) @compileError("HIDP_CAPS ABI size must be 64 bytes");
    }

    /// HIDP_STATUS_SUCCESS.
    const hidp_status_success: i32 = 0x0011_0000;

    const digcf_present: u32 = 0x0000_0002;
    const digcf_device_interface: u32 = 0x0000_0010;
    const generic_read: u32 = 0x8000_0000;
    const generic_write: u32 = 0x4000_0000;
    const file_share_read: u32 = 0x0000_0001;
    const file_share_write: u32 = 0x0000_0002;
    const open_existing: u32 = 3;
    const file_flag_overlapped: u32 = 0x4000_0000;
    const invalid_handle: usize = std.math.maxInt(usize);
    const error_io_pending: u32 = 997;
    const error_io_incomplete: u32 = 996;

    extern "setupapi" fn SetupDiGetClassDevsW(*const Guid, ?[*:0]const u16, ?*anyopaque, u32) callconv(.winapi) *anyopaque;
    extern "setupapi" fn SetupDiDestroyDeviceInfoList(*anyopaque) callconv(.winapi) i32;
    extern "setupapi" fn SetupDiEnumDeviceInterfaces(*anyopaque, ?*anyopaque, *const Guid, u32, *DeviceInterfaceData) callconv(.winapi) i32;
    extern "setupapi" fn SetupDiGetDeviceInterfaceDetailW(*anyopaque, *DeviceInterfaceData, ?*DeviceInterfaceDetail, u32, ?*u32, ?*anyopaque) callconv(.winapi) i32;
    extern "hid" fn HidD_GetAttributes(*anyopaque, *HidAttributes) callconv(.winapi) u8;
    extern "hid" fn HidD_GetPreparsedData(*anyopaque, *?*anyopaque) callconv(.winapi) u8;
    extern "hid" fn HidD_FreePreparsedData(*anyopaque) callconv(.winapi) u8;
    extern "hid" fn HidP_GetCaps(*anyopaque, *HidpCaps) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) *anyopaque;
    extern "kernel32" fn CreateEventW(?*anyopaque, i32, i32, ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn ReadFile(*anyopaque, [*]u8, u32, ?*u32, ?*Overlapped) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(*anyopaque, [*]const u8, u32, ?*u32, ?*Overlapped) callconv(.winapi) i32;
    extern "kernel32" fn GetOverlappedResult(*anyopaque, *Overlapped, *u32, i32) callconv(.winapi) i32;
    extern "kernel32" fn CancelIoEx(*anyopaque, ?*Overlapped) callconv(.winapi) i32;
    extern "kernel32" fn ResetEvent(?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
    extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
} else struct {};

test "an in-flight rumble cannot replace a newer stop or repeated request" {
    var queue = OutputQueue{};
    const rumble = dualshock.Output{ .rumble_strong = 170, .rumble_weak = 85, .set_light_bar = false };
    queue.wanted = rumble;
    const pending = queue.next().?;
    queue.wanted = .{ .set_light_bar = false };
    queue.applied = pending;
    try std.testing.expectEqual(@as(u8, 0), queue.next().?.rumble_strong);
    queue.applied = queue.next();
    try std.testing.expect(queue.next() == null);
    queue.wanted = rumble;
    queue.applied = queue.next();
    queue.wanted = rumble;
    try std.testing.expect(queue.next() == null);
    queue.applied = null; // reconnect must send the current state again
    try std.testing.expectEqual(rumble, queue.next().?);
}

test "Bluetooth RGB follows completed LED reset and retains motors" {
    var setup = LightBarSetup{};
    const wanted = dualshock.Output{ .red = 25, .green = 80, .blue = 195, .rumble_strong = 70, .rumble_weak = 30 };
    const waiting = setup.prepare(wanted, 100);
    try std.testing.expect(!waiting.set_light_bar and !waiting.reset_light_bar);
    try std.testing.expectEqual(wanted.rumble_strong, waiting.rumble_strong);
    try std.testing.expect(!setup.prepare(wanted, 3599).reset_light_bar);
    const fallback = setup.prepare(wanted, 3600);
    try std.testing.expect(fallback.reset_light_bar and !fallback.set_light_bar);
    setup.complete = true;
    try std.testing.expectEqual(wanted, setup.prepare(wanted, 3601));
    setup = .{ .ready = true };
    try std.testing.expect(setup.prepare(wanted, 0).reset_light_bar);
}

test "a pending report cannot erase a newer combined RGB and motor state" {
    var queue = OutputQueue{};
    const first = dualshock.Output{ .set_light_bar = false, .rumble_strong = 90 };
    queue.wanted = first;
    const pending = queue.next().?;
    const color = dualshock.Output{ .red = 123, .green = 45, .blue = 67, .rumble_strong = 90 };
    queue.wanted = color;
    queue.applied = pending;
    try std.testing.expectEqual(color, queue.next().?);
    const pending_color = queue.next().?;
    var stop = color;
    stop.rumble_strong = 0;
    queue.wanted = stop;
    queue.applied = pending_color;
    try std.testing.expectEqual(stop, queue.next().?);
    queue.applied = stop;
    try std.testing.expect(queue.next() == null);
}

test "a wireless report is padded to the declared length with its checksum intact" {
    var buffer: [maximum_report_bytes]u8 = @splat(0xee);
    const length = dualshock.buildOutput(.dual_shock_4, .bluetooth, .{ .rumble_strong = 200, .set_light_bar = false }, &buffer).?;
    try std.testing.expectEqual(@as(usize, dualshock.bluetooth_output_bytes), length);
    var report: [dualshock.bluetooth_output_bytes]u8 = undefined;
    @memcpy(&report, buffer[0..length]);
    // A Bluetooth descriptor declares longer output reports than the one sent.
    const size = padToDeclared(&buffer, length, 548);
    try std.testing.expectEqual(@as(usize, 548), size);
    try std.testing.expectEqualSlices(u8, &report, buffer[0..length]);
    for (buffer[length..size]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    // The cable form already has the declared size and is sent unchanged.
    const wired = dualshock.buildOutput(.dual_sense, .usb, .{}, &buffer).?;
    try std.testing.expectEqual(wired, padToDeclared(&buffer, wired, 48));
    // A descriptor that declares nothing never truncates the report.
    try std.testing.expectEqual(wired, padToDeclared(&buffer, wired, 0));
}

test "an unsupported host reports no controller" {
    if (comptime supported) return error.SkipZigTest;
    try std.testing.expect(poll() == null);
    try std.testing.expect(!presence().connected);
}
