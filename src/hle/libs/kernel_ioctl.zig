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
//!
//! ## What a shipped driver asks for
//!
//! Observed by running a title's own `libSceAgcDriver` against this layer and
//! reading its diagnostics. Neither reference emulator records any of it: both
//! reimplement the graphics API instead and never reach a device node. Recorded
//! here because it is the specification, and it took a working driver to
//! obtain.
//!
//! - `/dev/gc` `#46`, in/out, 4 bytes. Asked first, with the buffer zeroed.
//!   Answering non-zero satisfies the driver's GPU presence check: its
//!   "Cannot initialize the Gpu" diagnostic stops, and it proceeds to `#59`.
//! - `/dev/gc` `#59`, in/out, 16 bytes. The wrapper fills the buffer with
//!   `0xff` *before* calling, so the all-ones payload is an unset-output
//!   sentinel and not a request. It tests only whether the call returned zero,
//!   then copies all 16 bytes to its caller. What the fields mean is still
//!   unknown: supplying plausible base/size pairs did not satisfy the library
//!   above it, so the acceptance test lives elsewhere.
//! - `/dev/dipsw` `#6`, out, 4 bytes. Answered here; see below.
//!
//! Past that, the driver's global device context is still null and it
//! dereferences it unchecked. Reaching a first frame therefore means finding
//! which request populates that context, not adding more replies at random.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const runtime_api = @import("kernel_runtime.zig");
const filesystem = @import("../filesystem.zig");
const memory = @import("kernel_memory.zig");

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
///
/// The device is named when the descriptor is known to be one, because a
/// request means something different depending on what it was addressed to,
/// and a bare descriptor number does not say.
pub fn write(
    request: Request,
    descriptor: i32,
    device: ?filesystem.Device,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    if (device) |named| {
        try w.print("{s} ", .{named.name()});
    } else {
        try w.print("fd={d} ", .{descriptor});
    }
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

/// The most payload bytes shown in one trace line.
const maximum_traced_payload: u16 = 32;

/// Appends the bytes the caller sent, when it sent any.
///
/// The shape of a request says what kind of thing was asked; the payload is the
/// question itself. Without it a submission and a query look alike. Only what
/// genuinely travels inward is shown — a caller filling a read-only buffer has
/// told us nothing, and printing its uninitialized contents would invent a
/// pattern where there is none.
fn writePayload(request: Request, payload: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (request.direction) {
        .write, .read_write => {},
        else => return,
    }
    if (request.length == 0) return;
    const shown = @min(request.length, maximum_traced_payload);
    if (!memory.isGuestRangeAccessible(payload, shown)) return;

    const bytes: [*]const u8 = @ptrFromInt(payload);
    try w.writeAll(" in:");
    for (bytes[0..shown]) |byte| try w.print(" {x:0>2}", .{byte});
    if (shown < request.length) try w.writeAll(" ...");
}

/// Announces a request when live tracing is on.
///
/// The generic call trace already records the raw arguments; this adds the only
/// parts that are not reconstructable from them at a glance.
fn announce(descriptor: i32, device: ?filesystem.Device, request: Request, payload: u64) void {
    if (!trace.isLive()) return;
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    write(request, descriptor, device, &writer) catch return;
    writePayload(request, payload, &writer) catch {};
    std.debug.print("[ioctl] {s}\n", .{writer.buffered()});
}

/// The largest payload answered here, which is every switch read seen so far.
///
/// A bound is needed because the answer is written through a guest pointer, and
/// the size comes from the request rather than from anything verified.
const maximum_answered_payload: u16 = 8;

/// Answers a read of the console's mode switches.
///
/// The switches are development flags, and on a retail console every one of
/// them is clear. Reporting them clear is therefore not an invented value: it
/// is the state of the hardware a shipped title is built to run on, and the one
/// its libraries take as ordinary. The payload size is not guessed either — the
/// request code declares it, and exactly that many bytes are written.
fn answerDipSwitch(request: Request, payload: u64) bool {
    switch (request.direction) {
        .read, .read_write => {},
        else => return false,
    }
    if (request.length == 0 or request.length > maximum_answered_payload) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;

    const destination: [*]u8 = @ptrFromInt(payload);
    @memset(destination[0..request.length], 0);
    return true;
}

/// Carries out a device control request.
///
/// Requests are refused unless answering one is grounded in something better
/// than a guess, with the error a device gives for a command it does not
/// implement. That is deliberate for the graphics device in particular: it is
/// where a driver submits work, and pretending a submission succeeded would
/// leave a title waiting on a fence that will never be signalled — a hang with
/// nothing to explain it, rather than an error naming the request that was not
/// handled.
fn ioctl(descriptor: i32, request_code: u64, payload: u64) callconv(abi.guest) i64 {
    const device = filesystem.deviceOf(descriptor);
    const request = decode(request_code);
    announce(descriptor, device, request, payload);

    if (device == .dip_switches and answerDipSwitch(request, payload)) return 0;

    runtime_api.setPosixErrno(errno.Posix.enotty);
    return -1;
}

/// A private kernel entry point the graphics driver calls.
///
/// Its published name has not been recovered, so it is registered by the
/// identifier the driver imports rather than by a name — a descriptive
/// placeholder would hash to something else entirely and resolve nothing.
/// Reported as unimplemented, which is at least true.
fn unnamedGraphicsKernelCall() callconv(abi.guest) i32 {
    return errno.KernelError.enosys.raw();
}

pub const exports = [_]symbols.Export{
    .{ .name = "ioctl", .function = trace.wrap("ioctl", &ioctl), .expect_id = "PfccT7qURYE" },
    .{ .name = "_ioctl", .function = trace.wrap("_ioctl", &ioctl), .expect_id = "wW+k21cmbwQ" },
    .{
        .name = "libkernel:LzoM-wVLJDE",
        .function = trace.wrap("libkernel:LzoM-wVLJDE", &unnamedGraphicsKernelCall),
        .id_override = "LzoM-wVLJDE",
    },
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
    try write(decode(encode(direction_in | direction_out, 'G', 7, 64)), 5, null, &w);
    const text = w.buffered();
    try testing.expect(std.mem.startsWith(u8, text, "fd=5 'G' #7 inout 64 bytes"));
}

test "a request names the device it was addressed to" {
    // The same request code means different things on different devices, and a
    // descriptor number does not say which one was meant.
    var buffer: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(decode(encode(direction_in, 'G', 1, 8)), 5, .graphics, &w);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "/dev/gc 'G' #1 in 8 bytes"));
}

test "an unprintable group is written as a number" {
    var buffer: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(decode(encode(direction_void, 0x01, 3, 0)), 9, null, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "0x01") != null);
}

test "a request is refused rather than silently accepted" {
    // Claiming a submission succeeded would leave a title waiting on a fence
    // that will never be signalled.
    try testing.expectEqual(@as(i64, -1), ioctl(3, encode(direction_in, 'G', 1, 8), 0));
}

test "a mode switch reads as clear, which is the retail state" {
    filesystem.detach();
    const fd = try filesystem.open("/dev/dipsw", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var value: u32 = 0xdead_beef;
    const request = encode(direction_out, 0x88, 6, @sizeOf(u32));
    try testing.expectEqual(@as(i64, 0), ioctl(fd, request, @intFromPtr(&value)));
    try testing.expectEqual(@as(u32, 0), value);
}

test "only what the request itself declares is written" {
    filesystem.detach();
    const fd = try filesystem.open("/dev/dipsw", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    // The declared length is the only bound there is, so a request larger than
    // anything observed is refused rather than trusted to be honest.
    var guard: [16]u8 = @splat(0xaa);
    const oversized = encode(direction_out, 0x88, 6, maximum_answered_payload + 1);
    try testing.expectEqual(@as(i64, -1), ioctl(fd, oversized, @intFromPtr(&guard)));
    try testing.expectEqual(@as(u8, 0xaa), guard[0]);

    // Four declared bytes touch four bytes and no more.
    try testing.expectEqual(@as(i64, 0), ioctl(fd, encode(direction_out, 0x88, 6, 4), @intFromPtr(&guard)));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, guard[0..4]);
    try testing.expectEqual(@as(u8, 0xaa), guard[4]);
}

test "a null payload is refused rather than written through" {
    filesystem.detach();
    const fd = try filesystem.open("/dev/dipsw", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};
    try testing.expectEqual(@as(i64, -1), ioctl(fd, encode(direction_out, 0x88, 6, 4), 0));
}

test "the graphics device is not answered by the switch reply" {
    // The two devices share an entry point but nothing else; a submission must
    // not be absorbed by the reply meant for switches.
    filesystem.detach();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var value: u32 = 0xdead_beef;
    const request = encode(direction_in | direction_out, 0x81, 46, @sizeOf(u32));
    try testing.expectEqual(@as(i64, -1), ioctl(fd, request, @intFromPtr(&value)));
    try testing.expectEqual(@as(u32, 0xdead_beef), value);
}

test "device control exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len, db.count());
    try testing.expect(db.findByName("ioctl", .function) != null);
    try testing.expect(db.findByName("_ioctl", .function) != null);
}
