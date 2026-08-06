// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The device control call, and what a title asks of its devices through it.
//!
//! This is the boundary between the graphics driver and the kernel. The driver
//! that a title ships builds command buffers itself and then hands them to the
//! hardware through exactly one door: a control request on a device descriptor.
//! Everything a GPU is asked to do arrives here.
//!
//! Discovery and queue registration requests described below are carried out.
//! Every other request remains *legible*: a request code is not an opaque number
//! but a packed record of which device group is being addressed, which command
//! it is, which way the payload travels and how large it is. Decoding it turns a
//! trace of bare integers into the specification each implementation has to
//! satisfy.
//!
//! ## What a shipped driver asks for
//!
//! Observed by running a title's own `libSceAgcDriver` against this layer and
//! reading its diagnostics. Recorded here because it is the specification, and
//! it took a working driver to obtain.
//!
//! - `/dev/gc` `#46`, in/out, 4 bytes. Asked first, with the buffer zeroed.
//!   A successful zero reply selects the retail compatibility path, which maps
//!   the small `/dev/gc` aperture and builds the driver's context. A non-zero
//!   reply skips that setup and leaves the context null.
//! - `/dev/gc` `#35`, input, 136 bytes. Installs the trap-handler resources.
//! - `/dev/gc` `#33`, in/out, 64 bytes. Repeated for all 56 hardware queues.
//!   The payload carries engine/family/index identity, queue/control/completion
//!   guest addresses and the fixed graphics aperture, so no reply handle needs
//!   to be invented.
//! - `/dev/gc` `#52` and `#38`, input, 4 bytes each. They retain the compute and
//!   graphics mode selected by the process.
//! - `/dev/gc` `#59`, in/out, 16 bytes. The wrapper fills the buffer with
//!   `0xff` *before* calling and stores the reply in the final 16 bytes of the
//!   driver's private device pool. Its individual fields are not yet consumed
//!   by this layer, so the compatibility response clears them.
//! - `/dev/gc` `#57`, in/out, 16 bytes. Queries the process suspend point.
//!   Retail execution is not suspended, so its output state remains clear.
//! - `/dev/gc` `#40`, input, 16 bytes. Installs the tessellation-factor ring as
//!   a 256-byte-aligned base, dword-sized byte count and zero reserved word.
//! - `/dev/gc` `#42`, input, 4 bytes. Retains the two 16-bit HS offchip values
//!   in the same reversed argument order used by the driver's ioctl wrapper.
//! - `/dev/dipsw` `#6`, out, 4 bytes. Answered here; see below.
//!
//! The discovery reply is only part of the contract. The driver's 2 MiB direct
//! pool must remain at `0xfe0000000`, while its small aperture remains at
//! `0xfe0200000`; `libSceAgc` derives its required FS table address as pool base
//! plus `0x40000` and fatally rejects a relocated pool.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const runtime_api = @import("kernel_runtime.zig");
const filesystem = @import("../filesystem.zig");
const graphics_device = @import("../graphics_device.zig");
const memory = @import("kernel_memory.zig");
const gpu = @import("gpu");
const agc_submit = @import("agc_submit.zig");

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
///
/// Wide enough for the largest request the shipped driver makes. A descriptor
/// shown half-way is worse than useless: the fields that say what the request
/// is for — addresses, sizes, counts — are spread through it, and half of them
/// names nothing.
const maximum_traced_payload: u16 = 128;

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

/// Request used by the shipped AGC driver to choose its initialization path.
/// A successful zero reply selects the retail compatibility path and its
/// `/dev/gc` aperture mapping. Keep the match exact so no later graphics
/// request is accidentally acknowledged as completed work.
fn answerGraphicsPresence(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 46) return false;
    if (request.direction != .read_write or request.length != @sizeOf(u32)) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;

    const destination: *[4]u8 = @ptrFromInt(payload);
    std.mem.writeInt(u32, destination, 0, .little);
    return true;
}

fn answerGraphicsTrapResources(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 35) return false;
    if (request.direction != .write or request.length != 136) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;
    graphics_device.installTrapResources();
    return true;
}

fn answerGraphicsQueueRegistration(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 33) return false;
    if (request.direction != .read_write or request.length != @sizeOf(graphics_device.QueueRegistration)) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;
    const source: *const graphics_device.QueueRegistration = @ptrFromInt(payload);
    graphics_device.registerQueue(source.*) catch return false;
    return true;
}

fn answerGraphicsMode(request: Request, payload: u64) bool {
    if (request.group != 0x81 or (request.number != 52 and request.number != 38)) return false;
    if (request.direction != .write or request.length != @sizeOf(u32)) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;
    const source: *const [4]u8 = @ptrFromInt(payload);
    const value = std.mem.readInt(u32, source, .little);
    if (request.number == 52) {
        graphics_device.setComputeMode(value);
    } else {
        graphics_device.setGraphicsMode(value);
    }
    return true;
}

/// Clears the driver's small service reply. The firmware table address is not
/// encoded here: the shipped driver derives it from its fixed device pool.
fn answerGraphicsServiceQuery(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 59) return false;
    if (request.direction != .read_write or request.length != 16) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;

    const destination: *[16]u8 = @ptrFromInt(payload);
    @memset(destination, 0);
    return true;
}

/// The queue preamble submitted by `/dev/gc` command 49.
///
/// The shipped wrapper copies one queue selector and fifteen PM4 words, primes
/// `result` to one, and accepts the operation only after the kernel replaces it
/// with zero. The final word says whether the optional sixteen-byte context was
/// copied into the PM4 template.
const GraphicsPreambleSubmit = extern struct {
    queue: u32,
    commands: [15]u32,
    result: u32,
    has_optional_context: u32,
};

/// One packed indirect-buffer record consumed by `/dev/gc` command 50.
///
/// The GPU virtual address is 48 bits. The following words retain queue policy
/// bits above the address and dword count, so only their verified low fields are
/// interpreted here.
const GraphicsIndirectDescriptor = extern struct {
    address_low: u32,
    address_high: u16,
    address_flags: u16,
    words_and_flags: u32,
    control: u32,

    fn address(self: GraphicsIndirectDescriptor) u64 {
        return (@as(u64, self.address_high) << 32) | self.address_low;
    }

    fn wordCount(self: GraphicsIndirectDescriptor) u32 {
        return self.words_and_flags & indirect_buffer_length_mask;
    }
};

/// A flat list of constant/draw indirect buffers for one graphics queue.
const GraphicsQueueSubmit = extern struct {
    queue: u32,
    descriptor_count: u32,
    descriptors: u64,
    result: u32,
    reserved: u32,
};

/// Commits the queue after its indirect-buffer list has been accepted.
const GraphicsQueueCommit = extern struct {
    queue: u32,
    result: u32,
};

comptime {
    if (@sizeOf(GraphicsPreambleSubmit) != 72) @compileError("unexpected /dev/gc #49 layout");
    if (@offsetOf(GraphicsPreambleSubmit, "result") != 64) @compileError("unexpected /dev/gc #49 result offset");
    if (@sizeOf(GraphicsIndirectDescriptor) != 16) @compileError("unexpected /dev/gc #50 IB layout");
    if (@sizeOf(GraphicsQueueSubmit) != 24) @compileError("unexpected /dev/gc #50 layout");
    if (@offsetOf(GraphicsQueueSubmit, "result") != 16) @compileError("unexpected /dev/gc #50 result offset");
    if (@sizeOf(GraphicsQueueCommit) != 8) @compileError("unexpected /dev/gc #51 layout");
    if (@offsetOf(GraphicsQueueCommit, "result") != 4) @compileError("unexpected /dev/gc #51 result offset");
}

/// One command stream the descriptor points at.
const IndirectBuffer = struct {
    address: u64,
    /// Length in words. The field also carries flags above the length, which
    /// select caching and privilege and say nothing about where the stream ends.
    words: u32,
};

/// Length occupies the low twenty bits of an indirect buffer's size field.
const indirect_buffer_length_mask: u32 = 0x000f_ffff;
/// The driver leaves this maximum-sized PACKET3_NOP at the first word it has
/// reserved but not committed in a ring allocation.
const uncommitted_ring_sentinel: u32 = 0xffff_1000;

/// Finds the command streams a submission descriptor names.
///
/// The descriptor's own structure is not established, so it is searched rather
/// than parsed: an indirect-buffer packet identifies itself, and does so on
/// three counts at once — packet type, opcode, and a body length that has to be
/// exactly the three words holding its address and size. Guessing a struct
/// layout would risk reading a length as an address; this cannot.
fn collectIndirectBuffers(descriptor: []const u32, out: []IndirectBuffer) usize {
    var found: usize = 0;
    var index: usize = 0;
    while (index + 3 < descriptor.len and found < out.len) : (index += 1) {
        const word = descriptor[index];
        if (word >> 30 != 3) continue;
        const opcode: u8 = @truncate(word >> 8);
        if (opcode != gpu.pm4.indirect_buffer) continue;
        if ((word >> 16) & 0x3fff != 2) continue;

        const address = (@as(u64, descriptor[index + 2]) << 32) | descriptor[index + 1];
        const words = descriptor[index + 3] & indirect_buffer_length_mask;
        if (address == 0 or words == 0) continue;

        out[found] = .{ .address = address, .words = words };
        found += 1;
        index += 3;
    }
    return found;
}

/// Returns only the committed prefix of a capacity-sized queue allocation.
///
/// Command 50 describes the whole reserved range. The driver fills its unused
/// tail with a maximum PACKET3_NOP whose declared body deliberately extends
/// beyond that range; hardware stops at the producer write pointer, which is
/// represented here by trimming at the exact sentinel instead.
fn committedQueueStream(stream: []const u32) []const u32 {
    var walker = gpu.pm4.Walker.init(stream);
    while (true) {
        const offset = walker.index;
        _ = walker.next() catch {
            if (stream[offset] == uncommitted_ring_sentinel) return stream[0..offset];
            return stream;
        } orelse return stream;
    }
}

/// Carries out the request the shipped driver submits graphics work through.
///
/// The payload is a small command stream of its own whose indirect buffers name
/// where the real work lives. Each is read out of guest memory and run.
///
/// A stream whose memory cannot be reached is reported rather than passed on.
/// The driver addresses its buffers through an aperture it established with the
/// device, and until that mapping is modelled some of those addresses name
/// nothing here — saying which one, and how long it was, is what turns that from
/// a silent refusal into something that can be acted on.
fn answerGraphicsSubmit(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 49) return false;
    if (request.direction != .read_write or request.length != @sizeOf(GraphicsPreambleSubmit)) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;

    const submission: *GraphicsPreambleSubmit = @ptrFromInt(payload);

    var buffers: [8]IndirectBuffer = undefined;
    const found = collectIndirectBuffers(&submission.commands, &buffers);
    if (found == 0) return false;

    var ran: usize = 0;
    for (buffers[0..found]) |buffer| {
        const bytes = @as(u64, buffer.words) * @sizeOf(u32);
        if (!memory.isGuestRangeAccessible(buffer.address, bytes)) {
            if (trace.announces("ioctl")) {
                std.debug.print(
                    "[gc submit] stream at 0x{x} ({d} dwords) is not reachable\n",
                    .{ buffer.address, buffer.words },
                );
            }
            continue;
        }
        const stream: [*]const u32 = @ptrFromInt(buffer.address);
        if (agc_submit.submitDeviceStream(stream[0..buffer.words]).accepted) ran += 1;
    }
    if (ran == 0) return false;
    // /dev/gc path does not go through sceAgcDriverSubmit*; still need IRQs.
    const event_queue = @import("kernel_event_queue.zig");
    _ = event_queue.triggerAllGraphicsEvents(0);
    submission.result = 0;
    return true;
}

/// Executes the scene buffers that follow the queue preamble.
fn answerGraphicsQueueSubmit(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 50) return false;
    if (request.direction != .read_write or request.length != @sizeOf(GraphicsQueueSubmit)) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;

    const submission: *GraphicsQueueSubmit = @ptrFromInt(payload);
    if (submission.reserved != 0 or submission.descriptor_count > 4096) return false;
    if (submission.descriptor_count == 0) {
        submission.result = 0;
        return true;
    }
    if (submission.descriptors == 0) return false;
    const descriptor_bytes = std.math.mul(
        u64,
        submission.descriptor_count,
        @sizeOf(GraphicsIndirectDescriptor),
    ) catch return false;
    if (!memory.isGuestRangeAccessible(submission.descriptors, descriptor_bytes)) return false;

    const pointer: [*]const GraphicsIndirectDescriptor = @ptrFromInt(submission.descriptors);
    const descriptors = pointer[0..submission.descriptor_count];
    for (descriptors, 0..) |descriptor, index| {
        const address = descriptor.address();
        const word_count = descriptor.wordCount();
        if (trace.announces("ioctl")) {
            std.debug.print(
                "[gc submit #50] queue {d} IB {d}/{d}: 0x{x} ({d} dwords), addr_flags=0x{x}, control=0x{x}\n",
                .{
                    submission.queue,
                    index,
                    descriptors.len,
                    address,
                    word_count,
                    descriptor.address_flags,
                    descriptor.control,
                },
            );
        }
        if (address == 0 or word_count == 0) continue;
        const byte_count = @as(u64, word_count) * @sizeOf(u32);
        if (!memory.isGuestRangeAccessible(address, byte_count)) return false;
        const stream_pointer: [*]const u32 = @ptrFromInt(address);
        const reserved_stream = stream_pointer[0..word_count];
        const stream = committedQueueStream(reserved_stream);
        if (stream.len != reserved_stream.len and trace.announces("ioctl")) {
            std.debug.print(
                "[gc submit #50] committed {d}/{d} dwords before ring sentinel\n",
                .{ stream.len, reserved_stream.len },
            );
        }
        if (stream.len == 0) continue;
        if (!agc_submit.submitDeviceStream(stream).accepted) return false;
    }

    const event_queue = @import("kernel_event_queue.zig");
    _ = event_queue.triggerAllGraphicsEvents(submission.queue);
    submission.result = 0;
    return true;
}

fn answerGraphicsQueueCommit(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 51) return false;
    if (request.direction != .read_write or request.length != @sizeOf(GraphicsQueueCommit)) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;
    const commit: *GraphicsQueueCommit = @ptrFromInt(payload);
    commit.result = 0;
    return true;
}

fn answerGraphicsSuspendQuery(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 57) return false;
    if (request.direction != .read_write or request.length != 16) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;
    const words: *[4]u32 = @ptrFromInt(payload);
    if (words[0] != 0 or words[1] != 1) return false;
    words[2] = 0;
    words[3] = 0;
    graphics_device.recordSuspendQuery();
    return true;
}

fn answerGraphicsTfRing(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 40) return false;
    if (request.direction != .write or request.length != @sizeOf(graphics_device.TfRingRequest)) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;
    const source: *const graphics_device.TfRingRequest = @ptrFromInt(payload);
    graphics_device.setTfRing(source.*) catch return false;
    return true;
}

fn answerGraphicsHsOffchip(request: Request, payload: u64) bool {
    if (request.group != 0x81 or request.number != 42) return false;
    if (request.direction != .write or request.length != @sizeOf(graphics_device.HsOffchipRequest)) return false;
    if (!memory.isGuestRangeAccessible(payload, request.length)) return false;
    const source: *const graphics_device.HsOffchipRequest = @ptrFromInt(payload);
    graphics_device.setHsOffchipParam(source.*);
    return true;
}

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

    if (device == .graphics and answerGraphicsPresence(request, payload)) return 0;
    if (device == .graphics and answerGraphicsTrapResources(request, payload)) return 0;
    if (device == .graphics and answerGraphicsQueueRegistration(request, payload)) return 0;
    if (device == .graphics and answerGraphicsMode(request, payload)) return 0;
    if (device == .graphics and answerGraphicsServiceQuery(request, payload)) return 0;
    if (device == .graphics and answerGraphicsSuspendQuery(request, payload)) return 0;
    if (device == .graphics and answerGraphicsTfRing(request, payload)) return 0;
    if (device == .graphics and answerGraphicsHsOffchip(request, payload)) return 0;
    if (device == .graphics and answerGraphicsSubmit(request, payload)) return 0;
    if (device == .graphics and answerGraphicsQueueSubmit(request, payload)) return 0;
    if (device == .graphics and answerGraphicsQueueCommit(request, payload)) return 0;
    if (device == .dip_switches and answerDipSwitch(request, payload)) return 0;

    runtime_api.setPosixErrno(errno.Posix.enotty);
    return -1;
}

pub fn reset() void {
    graphics_device.reset();
}

/// A private graphics-related capability query used by the shipped driver.
///
/// Its published name has not been recovered, so it remains registered by the
/// identifier the driver imports. Every call site takes no arguments and uses
/// the result as a boolean to select a hardware-specific memory layout. The
/// retail profile does not expose that optional layout. Returning false also
/// keeps the selected sizes on the PS5's 16 KiB page boundary; returning a
/// kernel error is incorrect because any non-zero value enables the mode.
fn graphicsMemoryModeEnabled() callconv(abi.guest) i32 {
    return 0;
}

pub const exports = [_]symbols.Export{
    .{ .name = "ioctl", .function = trace.wrap("ioctl", &ioctl), .expect_id = "PfccT7qURYE" },
    .{ .name = "_ioctl", .function = trace.wrap("_ioctl", &ioctl), .expect_id = "wW+k21cmbwQ" },
    .{
        .name = "libkernel:LzoM-wVLJDE",
        .function = trace.wrap("libkernel:LzoM-wVLJDE", &graphicsMemoryModeEnabled),
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

/// Builds the indirect-buffer packet a submission descriptor carries.
fn indirectBufferPacket(address: u64, words: u32) [4]u32 {
    return .{
        (@as(u32, 3) << 30) | (@as(u32, 2) << 16) | (@as(u32, gpu.pm4.indirect_buffer) << 8),
        @truncate(address),
        @truncate(address >> 32),
        words,
    };
}

test "the streams a submission names are found without parsing its shape" {
    // The descriptor's own structure is not established, so it is searched. An
    // indirect-buffer packet identifies itself on three counts at once — type,
    // opcode, and a body length that has to be exactly its address and size.
    const first = indirectBufferPacket(0x0f_e000_0000, 150);
    const second = indirectBufferPacket(0x0f_e003_a200, 2);
    const descriptor = [_]u32{
        0,
        // A command that is not an indirect buffer, which must be stepped over.
        (@as(u32, 3) << 30) | (@as(u32, 1) << 16) | (@as(u32, gpu.pm4.context_control) << 8),
        0,
        0,
    } ++ first ++ [_]u32{ 0, 0, 0, 0 } ++ second ++ [_]u32{1};

    var found: [8]IndirectBuffer = undefined;
    const count = collectIndirectBuffers(&descriptor, &found);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual(@as(u64, 0x0f_e000_0000), found[0].address);
    try testing.expectEqual(@as(u32, 150), found[0].words);
    try testing.expectEqual(@as(u64, 0x0f_e003_a200), found[1].address);
    try testing.expectEqual(@as(u32, 2), found[1].words);
}

test "flags above a stream's length are not read as length" {
    // The size field carries caching and privilege bits above the twenty that
    // hold the length. Taking the whole word would submit a stream millions of
    // words long, reaching far past the memory the title set aside.
    const packet = indirectBufferPacket(0x1000, 0x3000_0096);
    const descriptor = [_]u32{0} ++ packet;

    var found: [2]IndirectBuffer = undefined;
    try testing.expectEqual(@as(usize, 1), collectIndirectBuffers(&descriptor, &found));
    try testing.expectEqual(@as(u32, 0x96), found[0].words);
}

test "a descriptor naming nothing yields nothing" {
    var found: [4]IndirectBuffer = undefined;
    const empty = [_]u32{0} ** 15;
    try testing.expectEqual(@as(usize, 0), collectIndirectBuffers(&empty, &found));

    // An indirect buffer with no address or no length names no stream, and
    // running one would read from wherever zero happens to land.
    const null_address = [_]u32{0} ++ indirectBufferPacket(0, 8);
    try testing.expectEqual(@as(usize, 0), collectIndirectBuffers(&null_address, &found));
    const empty_stream = [_]u32{0} ++ indirectBufferPacket(0x2000, 0);
    try testing.expectEqual(@as(usize, 0), collectIndirectBuffers(&empty_stream, &found));
}

test "command 50 trims only its exact uncommitted ring sentinel" {
    const reserved = [_]u32{
        (@as(u32, 3) << 30) | (@as(u32, gpu.pm4.nop) << 8),
        0,
        uncommitted_ring_sentinel,
        0,
        0,
    };
    try testing.expectEqual(@as(usize, 2), committedQueueStream(&reserved).len);

    var malformed = reserved;
    malformed[2] = 0xffff_1001;
    try testing.expectEqual(malformed.len, committedQueueStream(&malformed).len);
}

test "graphics preamble submission clears the driver's result sentinel" {
    filesystem.detach();
    agc_submit.reset();
    defer agc_submit.reset();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var stream = [_]u32{
        (@as(u32, 3) << 30) | (@as(u32, gpu.pm4.nop) << 8),
        0,
    };
    const packet = indirectBufferPacket(@intFromPtr(&stream), stream.len);
    var submission = GraphicsPreambleSubmit{
        .queue = 0,
        .commands = [_]u32{0} ** 15,
        .result = 1,
        .has_optional_context = 0,
    };
    @memcpy(submission.commands[0..packet.len], &packet);

    try testing.expectEqual(@as(i64, 0), ioctl(
        fd,
        encode(direction_in | direction_out, 0x81, 49, @sizeOf(GraphicsPreambleSubmit)),
        @intFromPtr(&submission),
    ));
    try testing.expectEqual(@as(u32, 0), submission.result);
}

test "graphics queue submission decodes packed IB records and commits" {
    filesystem.detach();
    agc_submit.reset();
    defer agc_submit.reset();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var stream = [_]u32{
        (@as(u32, 3) << 30) | (@as(u32, gpu.pm4.nop) << 8),
        0,
    };
    const address = @intFromPtr(&stream);
    var descriptors = [_]GraphicsIndirectDescriptor{
        .{
            .address_low = @truncate(address),
            .address_high = @truncate(address >> 32),
            .address_flags = 0x12,
            .words_and_flags = 0x3000_0000 | stream.len,
            .control = 0,
        },
        .{ .address_low = 0, .address_high = 0, .address_flags = 0, .words_and_flags = 0, .control = 0 },
    };
    try testing.expectEqual(@as(u64, address), descriptors[0].address());
    try testing.expectEqual(@as(u32, stream.len), descriptors[0].wordCount());

    var submission = GraphicsQueueSubmit{
        .queue = 0,
        .descriptor_count = descriptors.len,
        .descriptors = @intFromPtr(&descriptors),
        .result = 1,
        .reserved = 0,
    };
    try testing.expectEqual(@as(i64, 0), ioctl(
        fd,
        encode(direction_in | direction_out, 0x81, 50, @sizeOf(GraphicsQueueSubmit)),
        @intFromPtr(&submission),
    ));
    try testing.expectEqual(@as(u32, 0), submission.result);

    var commit = GraphicsQueueCommit{ .queue = 0, .result = 1 };
    try testing.expectEqual(@as(i64, 0), ioctl(
        fd,
        encode(direction_in | direction_out, 0x81, 51, @sizeOf(GraphicsQueueCommit)),
        @intFromPtr(&commit),
    ));
    try testing.expectEqual(@as(u32, 0), commit.result);
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

test "the graphics initialization query selects the retail path" {
    filesystem.detach();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var value: u32 = 0;
    const request = encode(direction_in | direction_out, 0x81, 46, @sizeOf(u32));
    try testing.expectEqual(@as(i64, 0), ioctl(fd, request, @intFromPtr(&value)));
    try testing.expectEqual(@as(u32, 0), value);
}

test "the graphics service query returns a neutral reply" {
    filesystem.detach();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var reply = [_]u8{0xff} ** 16;
    const request = encode(direction_in | direction_out, 0x81, 59, reply.len);
    try testing.expectEqual(@as(i64, 0), ioctl(fd, request, @intFromPtr(&reply)));
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 16), &reply);
}

test "the graphics driver registers exact queue-owned memory" {
    reset();
    defer reset();
    filesystem.detach();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    const registration = graphics_device.QueueRegistration{
        .engine = 1,
        .family = 0,
        .index = 0,
        .identifier = 1,
        .queue_address = 0x7000_1000_8000,
        .control_address = 0x7000_1000_c000,
        .aperture_address = graphics_device.aperture_address,
        .aperture_slots = 12,
        .completion_address = 0x7000_2000_1000,
        .completion_size = 0x1000,
    };
    const request = encode(direction_in | direction_out, 0x81, 33, @sizeOf(@TypeOf(registration)));
    try testing.expectEqual(@as(i64, 0), ioctl(fd, request, @intFromPtr(&registration)));
    try testing.expectEqual(@as(u32, 1), graphics_device.status().queue_count);
    try testing.expectEqual(registration.queue_address, graphics_device.findQueue(1).?.queue_address);
}

test "the graphics driver initialization requests update device state" {
    reset();
    defer reset();
    filesystem.detach();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var trap: [136]u8 = @splat(0);
    try testing.expectEqual(@as(i64, 0), ioctl(
        fd,
        encode(direction_in, 0x81, 35, trap.len),
        @intFromPtr(&trap),
    ));
    var compute_mode: u32 = 3;
    var graphics_mode: u32 = 1;
    try testing.expectEqual(@as(i64, 0), ioctl(
        fd,
        encode(direction_in, 0x81, 52, @sizeOf(u32)),
        @intFromPtr(&compute_mode),
    ));
    try testing.expectEqual(@as(i64, 0), ioctl(
        fd,
        encode(direction_in, 0x81, 38, @sizeOf(u32)),
        @intFromPtr(&graphics_mode),
    ));
    const current = graphics_device.status();
    try testing.expect(current.trap_resources_installed);
    try testing.expectEqual(compute_mode, current.compute_mode);
    try testing.expectEqual(graphics_mode, current.graphics_mode);
}

test "the graphics suspend query reports an active process" {
    reset();
    defer reset();
    filesystem.detach();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var query = [4]u32{ 0, 1, 0xdead_beef, 0xdead_beef };
    try testing.expectEqual(@as(i64, 0), ioctl(
        fd,
        encode(direction_in | direction_out, 0x81, 57, @sizeOf(@TypeOf(query))),
        @intFromPtr(&query),
    ));
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 0, 0 }, &query);
    try testing.expectEqual(@as(u64, 1), graphics_device.status().suspend_query_count);
}

test "the graphics driver publishes tessellation device state" {
    reset();
    defer reset();
    filesystem.detach();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var tf_ring = graphics_device.TfRingRequest{
        .base_address = 0x0000_0002_0312_6c00,
        .size = 0x0003_fff8,
        .reserved = 0,
    };
    try testing.expectEqual(@as(i64, 0), ioctl(
        fd,
        encode(direction_in, 0x81, 40, @sizeOf(@TypeOf(tf_ring))),
        @intFromPtr(&tf_ring),
    ));
    var hs_offchip = graphics_device.HsOffchipRequest{ .value1 = 0x24, .value0 = 0x10 };
    try testing.expectEqual(@as(i64, 0), ioctl(
        fd,
        encode(direction_in, 0x81, 42, @sizeOf(@TypeOf(hs_offchip))),
        @intFromPtr(&hs_offchip),
    ));
    const current = graphics_device.status();
    try testing.expectEqual(tf_ring.base_address, current.tf_ring_base);
    try testing.expectEqual(tf_ring.size, current.tf_ring_size);
    try testing.expectEqual(hs_offchip.value0, current.hs_offchip_value0);
    try testing.expectEqual(hs_offchip.value1, current.hs_offchip_value1);
}

test "other graphics requests remain refused" {
    // Presence discovery is not a GPU submission. Only its exact shape may be
    // answered until the command behind another request is implemented.
    filesystem.detach();
    const fd = try filesystem.open("/dev/gc", filesystem.O.rdonly);
    defer filesystem.close(fd) catch {};

    var value: u32 = 0xdead_beef;
    const other_request = encode(direction_in | direction_out, 0x81, 47, @sizeOf(u32));
    try testing.expectEqual(@as(i64, -1), ioctl(fd, other_request, @intFromPtr(&value)));
    try testing.expectEqual(@as(u32, 0xdead_beef), value);
}

test "the private graphics memory mode is disabled for retail" {
    try testing.expectEqual(@as(i32, 0), graphicsMemoryModeEnabled());
}

test "device control exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len, db.count());
    try testing.expect(db.findByName("ioctl", .function) != null);
    try testing.expect(db.findByName("_ioctl", .function) != null);
}
