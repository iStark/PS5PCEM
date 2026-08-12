// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Input reports of Sony's own controllers.
//!
//! XInput cannot see these pads at all. It only enumerates Xbox-compatible
//! devices, so a DualSense or DualShock 4 plugged straight into the host is
//! invisible to it and appears connected only when a translation layer puts a
//! virtual Xbox pad in front of it. Reading the HID reports directly is what
//! makes the controller the title expects work without one.
//!
//! Parsing is kept apart from the host I/O so the byte layouts can be tested
//! without a device attached.

const std = @import("std");

pub const sony_vendor: u16 = 0x054c;

pub const Family = enum { dual_sense, dual_shock_4 };

/// Identifies a pad this module can read. Unknown products are rejected rather
/// than guessed at: a wrong layout produces plausible-looking axes that respond
/// to nothing, which is harder to recognize than an unsupported device.
pub fn identify(vendor: u16, product: u16) ?Family {
    if (vendor != sony_vendor) return null;
    return switch (product) {
        // DualSense, and the Edge revision that reports the same layout.
        0x0ce6, 0x0df2 => .dual_sense,
        // DualShock 4, first and second hardware revisions.
        0x05c4, 0x09cc => .dual_shock_4,
        else => null,
    };
}

/// One sampled controller state, in the units the reports carry: sticks are
/// unsigned with 128 at rest and Y growing downwards, triggers are 0..255.
pub const Pad = struct {
    cross: bool = false,
    circle: bool = false,
    square: bool = false,
    triangle: bool = false,
    l1: bool = false,
    r1: bool = false,
    l2: bool = false,
    r2: bool = false,
    l3: bool = false,
    r3: bool = false,
    options: bool = false,
    create: bool = false,
    touch_pad: bool = false,
    home: bool = false,
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
    left_x: u8 = 128,
    left_y: u8 = 128,
    right_x: u8 = 128,
    right_y: u8 = 128,
    analog_l2: u8 = 0,
    analog_r2: u8 = 0,
};

/// Where each field sits inside one report.
///
/// The fields themselves are identical across every form; only their offsets
/// move, because Bluetooth prefixes the payload and because the DualSense
/// carries its triggers ahead of the button bytes rather than after them.
const Layout = struct {
    left_x: usize,
    left_y: usize,
    right_x: usize,
    right_y: usize,
    buttons_face: usize,
    buttons_shoulder: usize,
    buttons_system: usize,
    analog_l2: usize,
    analog_r2: usize,

    fn minimumLength(self: Layout) usize {
        var highest = self.buttons_system;
        for ([_]usize{
            self.left_x,     self.left_y,          self.right_x,
            self.right_y,    self.buttons_face,    self.buttons_shoulder,
            self.analog_l2,  self.analog_r2,
        }) |offset| {
            if (offset > highest) highest = offset;
        }
        return highest + 1;
    }
};

/// The DualShock 4 order: both sticks, the three button bytes, then the
/// analogue triggers. The DualSense repeats it verbatim in the compact report
/// it sends over Bluetooth before a host asks for the full one.
fn compactLayout(base: usize) Layout {
    return .{
        .left_x = base,
        .left_y = base + 1,
        .right_x = base + 2,
        .right_y = base + 3,
        .buttons_face = base + 4,
        .buttons_shoulder = base + 5,
        .buttons_system = base + 6,
        .analog_l2 = base + 7,
        .analog_r2 = base + 8,
    };
}

/// The DualSense order: both sticks, the analogue triggers, a sequence counter,
/// then the three button bytes.
fn extendedLayout(base: usize) Layout {
    return .{
        .left_x = base,
        .left_y = base + 1,
        .right_x = base + 2,
        .right_y = base + 3,
        .analog_l2 = base + 4,
        .analog_r2 = base + 5,
        .buttons_face = base + 7,
        .buttons_shoulder = base + 8,
        .buttons_system = base + 9,
    };
}

/// The smallest DualSense report that still carries the full layout. Its
/// Bluetooth compact form is far shorter, which is what separates the two
/// meanings of report id 1 on that pad.
const dual_sense_extended_length = 64;

fn layoutFor(family: Family, report: []const u8) ?Layout {
    if (report.len == 0) return null;
    return switch (family) {
        .dual_sense => switch (report[0]) {
            // Wired, and the full Bluetooth report once the pad has been asked
            // for it. Both start their payload immediately after the id.
            0x01 => if (report.len >= dual_sense_extended_length)
                extendedLayout(1)
            else
                // Until that request arrives the pad reports over Bluetooth in
                // the older compact form.
                compactLayout(1),
            // The full Bluetooth report inserts one sequence byte first.
            0x31 => extendedLayout(2),
            else => null,
        },
        .dual_shock_4 => switch (report[0]) {
            0x01 => compactLayout(1),
            // Bluetooth prefixes two bytes before the wired payload.
            0x11 => compactLayout(3),
            else => null,
        },
    };
}

/// Decodes one host report, or reports that it is not one this module knows.
pub fn parse(family: Family, report: []const u8) ?Pad {
    const layout = layoutFor(family, report) orelse return null;
    if (report.len < layout.minimumLength()) return null;

    const face = report[layout.buttons_face];
    const shoulder = report[layout.buttons_shoulder];
    const system = report[layout.buttons_system];

    var pad = Pad{
        .left_x = report[layout.left_x],
        .left_y = report[layout.left_y],
        .right_x = report[layout.right_x],
        .right_y = report[layout.right_y],
        .analog_l2 = report[layout.analog_l2],
        .analog_r2 = report[layout.analog_r2],
        .square = face & 0x10 != 0,
        .cross = face & 0x20 != 0,
        .circle = face & 0x40 != 0,
        .triangle = face & 0x80 != 0,
        .l1 = shoulder & 0x01 != 0,
        .r1 = shoulder & 0x02 != 0,
        .l2 = shoulder & 0x04 != 0,
        .r2 = shoulder & 0x08 != 0,
        .create = shoulder & 0x10 != 0,
        .options = shoulder & 0x20 != 0,
        .l3 = shoulder & 0x40 != 0,
        .r3 = shoulder & 0x80 != 0,
        .home = system & 0x01 != 0,
        .touch_pad = system & 0x02 != 0,
    };
    applyHat(&pad, face & 0x0f);
    return pad;
}

/// The directional pad arrives as one of eight compass positions rather than
/// four independent bits, so the diagonals set two directions at once and any
/// value past the last position means nothing is held.
fn applyHat(pad: *Pad, hat: u8) void {
    switch (hat) {
        0 => pad.up = true,
        1 => {
            pad.up = true;
            pad.right = true;
        },
        2 => pad.right = true,
        3 => {
            pad.right = true;
            pad.down = true;
        },
        4 => pad.down = true,
        5 => {
            pad.down = true;
            pad.left = true;
        },
        6 => pad.left = true,
        7 => {
            pad.left = true;
            pad.up = true;
        },
        else => {},
    }
}

/// How the pad is attached, which decides the shape of an outgoing report.
///
/// Bluetooth wraps the same payload: it shifts the fields along and appends a
/// checksum the pad verifies before acting on anything, so a report built for
/// the cable is silently ignored over the air.
pub const Transport = enum { usb, bluetooth };

/// Reads the transport back from an input report. The pad announces it by which
/// report it sends, so nothing has to be tracked separately.
pub fn transportOf(family: Family, report: []const u8) ?Transport {
    if (report.len == 0) return null;
    return switch (family) {
        .dual_sense => switch (report[0]) {
            0x01 => if (report.len >= dual_sense_extended_length) .usb else .bluetooth,
            0x31 => .bluetooth,
            else => null,
        },
        .dual_shock_4 => switch (report[0]) {
            0x01 => .usb,
            0x11 => .bluetooth,
            else => null,
        },
    };
}

/// What a host can drive on these pads without touching the advanced haptics.
pub const Output = struct {
    /// The large, low-frequency motor.
    rumble_strong: u8 = 0,
    /// The small, high-frequency motor.
    rumble_weak: u8 = 0,
    red: u8 = 0,
    green: u8 = 0,
    blue: u8 = 0,
};

/// The longest report any of these forms needs.
pub const maximum_output_bytes = 78;

/// The byte the checksum is seeded with. It stands for the HID output-report
/// message type and is not itself transmitted.
const bluetooth_checksum_seed: u8 = 0xa2;

/// Writes one output report into `buffer` and answers how much of it to send.
pub fn buildOutput(
    family: Family,
    transport: Transport,
    output: Output,
    buffer: []u8,
) ?usize {
    const length: usize = switch (family) {
        .dual_sense => if (transport == .usb) 48 else 78,
        .dual_shock_4 => if (transport == .usb) 32 else 78,
    };
    if (buffer.len < length) return null;
    @memset(buffer[0..length], 0);

    switch (family) {
        .dual_sense => {
            const base: usize = if (transport == .usb) 1 else 2;
            buffer[0] = if (transport == .usb) 0x02 else 0x31;
            // Bluetooth carries a sequence tag ahead of the payload.
            if (transport == .bluetooth) buffer[1] = 0x02;
            // Ask for the plain motors rather than the haptic actuators, and
            // for control of the light bar. A pad ignores every field whose
            // enable bit is clear, so these are what make the rest take effect.
            buffer[base] = 0x03;
            buffer[base + 1] = 0x04;
            buffer[base + 2] = output.rumble_weak;
            buffer[base + 3] = output.rumble_strong;
            buffer[base + 44] = output.red;
            buffer[base + 45] = output.green;
            buffer[base + 46] = output.blue;
        },
        .dual_shock_4 => {
            const base: usize = if (transport == .usb) 1 else 3;
            buffer[0] = if (transport == .usb) 0x05 else 0x11;
            if (transport == .bluetooth) {
                buffer[1] = 0xc0;
                buffer[2] = 0xa0;
            }
            // Enable the motors, the light bar and its blink timers together.
            buffer[base] = 0xf7;
            buffer[base + 3] = output.rumble_weak;
            buffer[base + 4] = output.rumble_strong;
            buffer[base + 5] = output.red;
            buffer[base + 6] = output.green;
            buffer[base + 7] = output.blue;
        },
    }

    if (transport == .bluetooth) appendChecksum(buffer[0..length]);
    return length;
}

fn appendChecksum(report: []u8) void {
    const body = report[0 .. report.len - 4];
    var crc = std.hash.Crc32.init();
    crc.update(&[_]u8{bluetooth_checksum_seed});
    crc.update(body);
    std.mem.writeInt(u32, report[report.len - 4 ..][0..4], crc.final(), .little);
}

test "the transport is recovered from the report the pad sends" {
    var wired = [_]u8{0} ** dual_sense_extended_length;
    wired[0] = 0x01;
    try std.testing.expectEqual(Transport.usb, transportOf(.dual_sense, &wired).?);

    var wireless = [_]u8{0} ** 78;
    wireless[0] = 0x31;
    try std.testing.expectEqual(Transport.bluetooth, transportOf(.dual_sense, &wireless).?);

    // Report id one is wired on a DualShock 4 but the compact wireless form on
    // a DualSense, which is why the length matters only for the latter.
    var compact = [_]u8{0} ** 10;
    compact[0] = 0x01;
    try std.testing.expectEqual(Transport.bluetooth, transportOf(.dual_sense, &compact).?);
    try std.testing.expectEqual(Transport.usb, transportOf(.dual_shock_4, &compact).?);
}

test "a wired DualSense output report carries the motors and the light bar" {
    var buffer: [maximum_output_bytes]u8 = undefined;
    const length = buildOutput(
        .dual_sense,
        .usb,
        .{ .rumble_strong = 0x80, .rumble_weak = 0x40, .red = 1, .green = 2, .blue = 3 },
        &buffer,
    ) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 48), length);
    try std.testing.expectEqual(@as(u8, 0x02), buffer[0]);
    // Without these enable bits the pad accepts the report and does nothing.
    try std.testing.expectEqual(@as(u8, 0x03), buffer[1]);
    try std.testing.expectEqual(@as(u8, 0x04), buffer[2]);
    try std.testing.expectEqual(@as(u8, 0x40), buffer[3]);
    try std.testing.expectEqual(@as(u8, 0x80), buffer[4]);
    try std.testing.expectEqual(@as(u8, 1), buffer[45]);
    try std.testing.expectEqual(@as(u8, 2), buffer[46]);
    try std.testing.expectEqual(@as(u8, 3), buffer[47]);
}

test "a wireless report shifts its payload and ends in a checksum" {
    var buffer: [maximum_output_bytes]u8 = undefined;
    const length = buildOutput(
        .dual_sense,
        .bluetooth,
        .{ .rumble_strong = 0x11, .red = 0xaa },
        &buffer,
    ) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 78), length);
    try std.testing.expectEqual(@as(u8, 0x31), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x11), buffer[5]);
    try std.testing.expectEqual(@as(u8, 0xaa), buffer[46]);

    var expected = std.hash.Crc32.init();
    expected.update(&[_]u8{bluetooth_checksum_seed});
    expected.update(buffer[0..74]);
    try std.testing.expectEqual(expected.final(), std.mem.readInt(u32, buffer[74..78], .little));
}

test "a DualShock 4 puts its light bar right after the motors" {
    var buffer: [maximum_output_bytes]u8 = undefined;
    const wired = buildOutput(
        .dual_shock_4,
        .usb,
        .{ .rumble_strong = 0x33, .rumble_weak = 0x22, .red = 9, .green = 8, .blue = 7 },
        &buffer,
    ) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 32), wired);
    try std.testing.expectEqual(@as(u8, 0x05), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x22), buffer[4]);
    try std.testing.expectEqual(@as(u8, 0x33), buffer[5]);
    try std.testing.expectEqual(@as(u8, 9), buffer[6]);

    const wireless = buildOutput(.dual_shock_4, .bluetooth, .{ .red = 9 }, &buffer) orelse
        return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 78), wireless);
    try std.testing.expectEqual(@as(u8, 0x11), buffer[0]);
    try std.testing.expectEqual(@as(u8, 9), buffer[8]);
}

test "a buffer too small for the report is refused" {
    var small: [16]u8 = undefined;
    try std.testing.expect(buildOutput(.dual_sense, .usb, .{}, &small) == null);
}

test "only Sony's own products are claimed" {
    try std.testing.expectEqual(Family.dual_sense, identify(sony_vendor, 0x0ce6).?);
    try std.testing.expectEqual(Family.dual_sense, identify(sony_vendor, 0x0df2).?);
    try std.testing.expectEqual(Family.dual_shock_4, identify(sony_vendor, 0x09cc).?);
    try std.testing.expect(identify(sony_vendor, 0x0001) == null);
    try std.testing.expect(identify(0x045e, 0x0ce6) == null);
}

test "a wired DualSense report reads its sticks, triggers and buttons" {
    var report = [_]u8{0} ** dual_sense_extended_length;
    report[0] = 0x01;
    report[1] = 0x20; // left x
    report[2] = 0xd0; // left y
    report[3] = 0x90; // right x
    report[4] = 0x40; // right y
    report[5] = 0x7f; // L2
    report[6] = 0xff; // R2
    report[8] = 0x20 | 4; // cross, hat south
    report[9] = 0x21; // L1 and options
    report[10] = 0x02; // touch pad

    const pad = parse(.dual_sense, &report) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 0x20), pad.left_x);
    try std.testing.expectEqual(@as(u8, 0xd0), pad.left_y);
    try std.testing.expectEqual(@as(u8, 0x90), pad.right_x);
    try std.testing.expectEqual(@as(u8, 0x40), pad.right_y);
    try std.testing.expectEqual(@as(u8, 0x7f), pad.analog_l2);
    try std.testing.expectEqual(@as(u8, 0xff), pad.analog_r2);
    try std.testing.expect(pad.cross and pad.l1 and pad.options and pad.touch_pad);
    try std.testing.expect(pad.down and !pad.up and !pad.left and !pad.right);
    try std.testing.expect(!pad.circle and !pad.square and !pad.triangle);
}

test "the Bluetooth DualSense report carries the same fields one byte later" {
    var wired = [_]u8{0} ** dual_sense_extended_length;
    wired[0] = 0x01;
    wired[1] = 0x11;
    wired[2] = 0x22;
    wired[3] = 0x33;
    wired[4] = 0x44;
    wired[5] = 0x55;
    wired[6] = 0x66;
    wired[8] = 0x80 | 2; // triangle, hat east
    wired[9] = 0x82; // R1 and R3

    var wireless = [_]u8{0} ** 78;
    wireless[0] = 0x31;
    @memcpy(wireless[2..12], wired[1..11]);

    const from_cable = parse(.dual_sense, &wired) orelse return error.TestFailed;
    const from_radio = parse(.dual_sense, &wireless) orelse return error.TestFailed;
    try std.testing.expectEqualDeep(from_cable, from_radio);
    try std.testing.expect(from_radio.triangle and from_radio.right and from_radio.r1 and from_radio.r3);
}

test "a DualShock 4 puts its triggers after the button bytes" {
    var wired = [_]u8{0} ** 64;
    wired[0] = 0x01;
    wired[1] = 0x10; // left x
    wired[2] = 0x20; // left y
    wired[3] = 0x30; // right x
    wired[4] = 0x40; // right y
    wired[5] = 0x40 | 6; // circle, hat west
    wired[6] = 0x08; // R2 pressed
    wired[7] = 0x01; // home
    wired[8] = 0x11; // L2 analogue
    wired[9] = 0xf0; // R2 analogue

    const pad = parse(.dual_shock_4, &wired) orelse return error.TestFailed;
    try std.testing.expectEqual(@as(u8, 0x10), pad.left_x);
    try std.testing.expectEqual(@as(u8, 0x11), pad.analog_l2);
    try std.testing.expectEqual(@as(u8, 0xf0), pad.analog_r2);
    try std.testing.expect(pad.circle and pad.left and pad.r2 and pad.home);

    // Over Bluetooth the same payload begins two bytes further in.
    var wireless = [_]u8{0} ** 78;
    wireless[0] = 0x11;
    @memcpy(wireless[3..13], wired[1..11]);
    const wireless_pad = parse(.dual_shock_4, &wireless) orelse return error.TestFailed;
    try std.testing.expectEqualDeep(pad, wireless_pad);
}

test "the compact DualSense report is told apart by its length" {
    // Bluetooth before the host asks for the full report: report id one, but
    // the shorter DualShock 4 ordering.
    var compact = [_]u8{0} ** 10;
    compact[0] = 0x01;
    compact[1] = 0x7f;
    compact[5] = 0x20 | 8; // cross, hat neutral
    compact[8] = 0x33; // L2 analogue in the compact position

    const pad = parse(.dual_sense, &compact) orelse return error.TestFailed;
    try std.testing.expect(pad.cross);
    try std.testing.expectEqual(@as(u8, 0x33), pad.analog_l2);
    try std.testing.expect(!pad.up and !pad.down and !pad.left and !pad.right);
}

test "reports that are unknown or too short are refused" {
    try std.testing.expect(parse(.dual_sense, &.{}) == null);
    try std.testing.expect(parse(.dual_sense, &.{0x05}) == null);
    // A truncated report never yields a half-decoded pad.
    try std.testing.expect(parse(.dual_shock_4, &[_]u8{ 0x01, 0, 0 }) == null);
}
