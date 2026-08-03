// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The device control call, and what a title asks of its devices through it.
//!
//! This is the boundary between the graphics driver and the kernel. The driver
//! that a title ships builds command buffers itself and then hands them to the
//! hardware through exactly one door: a control request on a device descriptor.
//! Everything a GPU is asked to do arrives here.
//!
//! Nothing is carried out yet. What matters for now is that the requests are
//! *legible*: a request code is not an opaque number but a packed record of
//! which device group is being addressed, which command it is, which way the
//! payload travels and how large it is. Decoding it turns a trace of bare
//! integers into a description of what the driver wanted, which is the
//! specification any future implementation has to satisfy.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const runtime_api = @import("kernel_runtime.zig");

/// Which way the payload travels, from the caller's point of view.
pub const Direction = enum {
    /// No payload; the argument is the value itself.
    none,
    /// The caller reads a result out of its buffer.
    read,
    /// The caller passes data in.
    write,
    /// Both.
    read_write,
    /// The encoding carried no direction, which no well-formed request does.
    unknown,

    pub fn name(self: Direction) []const u8 {
        return switch (self) {
            .none => "void",
            .read => "out",
            .write => "in",
            .read_write => "inout",
            .unknown => "?",
        };
    }
};

/// A request code, unpacked.
///
/// The layout is the BSD one the guest kernel inherits: direction in the top
/// three bits, payload length below it, then a group letter and a command
/// number. The group is written as a character because that is how drivers
/// spell it — a request on the graphics device reads as a letter, not a number.
pub const Request = struct {
    direction: Direction,
    /// Payload size in bytes, as the encoding declares it.
    length: u16,
    /// Device group, conventionally a printable letter.
    group: u8,
    /// Command within the group.
    number: u8,
    raw: u32,

    pub fn groupIsPrintable(self: Request) bool {
        return self.group >= 0x20 and self.group < 0x7f;
    }
};

const direction_void: u32 = 0x2000_0000;
const direction_out: u32 = 0x4000_0000;
const direction_in: u32 = 0x8000_0000;
const direction_mask: u32 = direction_void | direction_out | direction_in;

/// Payload length occupies thirteen bits, which caps a request at 8191 bytes.
const length_shift: u5 = 16;
const length_mask: u32 = 0x1fff;

pub fn decode(raw: u64) Request {
    const value: u32 = @truncate(raw);
    const direction: Direction = switch (value & direction_mask) {
        direction_void => .none,
        direction_out => .read,
        direction_in => .write,
        direction_in | direction_out => .read_write,
        else => .unknown,
    };

    return .{
        .direction = direction,
        .length = @intCast((value >> length_shift) & length_mask),
        .group = @truncate(value >> 8),
        .number = @truncate(value),
        .raw = value,
    };
}

/// Writes a request in the form a driver author would recognise.
pub fn write(request: Request, descriptor: i32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("fd={d} ", .{descriptor});
    if (request.groupIsPrintable()) {
        try w.print("'{c}'", .{request.group});
    } else {
        try w.print("0x{x:0>2}", .{request.group});
    }
    try w.print(
        " #{d} {s} {d} bytes (0x{x:0>8})",
        .{ request.number, request.direction.name(), request.length, request.raw },
    );
}

/// Announces a request when live tracing is on.
///
/// The generic call trace already records the raw arguments; this adds the only
/// part that is not reconstructable from them at a glance.
fn announce(descriptor: i32, request: Request) void {
    if (!trace.isLive()) return;
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    write(request, descriptor, &writer) catch return;
    std.debug.print("[ioctl] {s}\n", .{writer.buffered()});
}

/// Carries out a device control request.
///
/// Every request is refused, with the error a device gives for a command it
/// does not implement. That is deliberate: this is where a graphics driver
/// submits work, and pretending a submission succeeded would leave a title
/// waiting on a fence that will never be signalled — a hang with nothing to
/// explain it, rather than an error naming the request that was not handled.
fn ioctl(descriptor: i32, request_code: u64, _: u64) callconv(abi.guest) i64 {
    const request = decode(request_code);
    announce(descriptor, request);

    runtime_api.setPosixErrno(errno.Posix.enotty);
    return -1;
}

pub const exports = [_]symbols.Export{
    .{ .name = "ioctl", .function = trace.wrap("ioctl", &ioctl), .expect_id = "PfccT7qURYE" },
    .{ .name = "_ioctl", .function = trace.wrap("_ioctl", &ioctl), .expect_id = "wW+k21cmbwQ" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a request the way a driver header would.
fn encode(direction: u32, group: u8, number: u8, length: u16) u64 {
    return direction |
        (@as(u32, length & length_mask) << length_shift) |
        (@as(u32, group) << 8) |
        number;
}

test "a request code unpacks into what the driver asked" {
    const request = decode(encode(direction_in | direction_out, 'G', 42, 128));
    try testing.expectEqual(Direction.read_write, request.direction);
    try testing.expectEqual(@as(u8, 'G'), request.group);
    try testing.expectEqual(@as(u8, 42), request.number);
    try testing.expectEqual(@as(u16, 128), request.length);
    try testing.expect(request.groupIsPrintable());
}

test "each direction is distinguished" {
    try testing.expectEqual(Direction.none, decode(encode(direction_void, 'A', 1, 0)).direction);
    try testing.expectEqual(Direction.read, decode(encode(direction_out, 'A', 1, 4)).direction);
    try testing.expectEqual(Direction.write, decode(encode(direction_in, 'A', 1, 4)).direction);
    // A code with no direction bits is not something a driver header produces.
    try testing.expectEqual(Direction.unknown, decode(0x0000_1234).direction);
}

test "the length field is bounded by its encoding" {
    // Thirteen bits cap a payload at 8191 bytes; a larger request cannot be
    // expressed, so a decoded length is never larger than that.
    const request = decode(encode(direction_in, 'G', 1, 0x1fff));
    try testing.expectEqual(@as(u16, 0x1fff), request.length);
    try testing.expect(decode(0xffff_ffff).length <= 0x1fff);
}

test "a request is written the way a driver author reads it" {
    var buffer: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(decode(encode(direction_in | direction_out, 'G', 7, 64)), 5, &w);
    const text = w.buffered();
    try testing.expect(std.mem.startsWith(u8, text, "fd=5 'G' #7 inout 64 bytes"));
}

test "an unprintable group is written as a number" {
    var buffer: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(decode(encode(direction_void, 0x01, 3, 0)), 9, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "0x01") != null);
}

test "a request is refused rather than silently accepted" {
    // Claiming a submission succeeded would leave a title waiting on a fence
    // that will never be signalled.
    try testing.expectEqual(@as(i64, -1), ioctl(3, encode(direction_in, 'G', 1, 8), 0));
}

test "device control exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len, db.count());
    try testing.expect(db.findByName("ioctl", .function) != null);
    try testing.expect(db.findByName("_ioctl", .function) != null);
}
