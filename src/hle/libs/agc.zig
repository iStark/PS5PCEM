// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The rest of the graphics library a shipped engine builds its frames with.
//!
//! A title does not ask this library to draw. It asks it to *write* — each of
//! these entry points appends one command to a buffer the title owns, and the
//! buffer is handed to the hardware later in a single submission. So what these
//! have to get right is not rendering but bookkeeping: how much space a command
//! takes, and that the buffer stays a walkable sequence of commands afterwards.
//!
//! Every command written here is a correctly formed no-operation of the size
//! the command would have taken. That is deliberately not the same as filling
//! the space with zeroes. Zeroes decode as a register write of one word, so a
//! buffer full of them is not merely inert — it is a different, shorter stream
//! that nothing can walk. A no-operation says what is true: a command occupied
//! this much room and did nothing, and everything after it still parses.
//!
//! Most placeholder patch entry points are accepted and change nothing. Patch
//! operations for commands that are executed by the emulator, however, must
//! preserve their real fields; release-memory fences are one such command.

const std = @import("std");
const abi = @import("../abi.zig");
const gpu = @import("gpu");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const event_queue = @import("kernel_event_queue.zig");
const kernel_memory = @import("kernel_memory.zig");

var eop_patch_reports: u32 = 0;
var wait_patch_reports: u32 = 0;

/// The cursor a title keeps over its command buffer.
///
/// Laid out as the library's own record: the entry points receive a pointer to
/// it and are expected to advance it, and a title reads the same fields to work
/// out how much room is left.
pub const CommandBuffer = extern struct {
    bottom: ?[*]u32,
    top: ?[*]u32,
    cursor_up: ?[*]u32,
    cursor_down: ?[*]u32,
    callback: ?*const anyopaque,
    user_data: ?*anyopaque,
    reserved_dwords: u32,
};

/// Words one written command occupies.
///
/// Uniform because the real widths vary per command and are not established
/// here; what matters to a title is that the space it was told a command needs
/// and the space the command takes are the same number, and that it can ask for
/// that number in advance. Four words is wide enough for a header and a small
/// body, which is what the narrowest real commands are.
pub const command_words: u32 = 4;

/// Writes one no-operation of `words` total size at the cursor and advances it.
///
/// Returns where the command was written, which is what a title uses to patch
/// it afterwards, or null when it does not fit — the answer the library gives
/// for a buffer with no room left.
fn appendNop(state: ?*CommandBuffer, words: u32) ?[*]u32 {
    const buffer = state orelse return null;
    if (words == 0) return null;

    const cursor = buffer.cursor_up orelse buffer.bottom orelse return null;
    const top = buffer.top orelse return null;

    const at = @intFromPtr(cursor);
    const end = @intFromPtr(top);
    const needed = @as(usize, words) * @sizeOf(u32);
    if (at > end or end - at < needed) return null;

    // A no-operation carries a body like any other command, and its header
    // states that body's length. Writing the header alone would leave the words
    // after it looking like commands of their own.
    cursor[0] = (@as(u32, 3) << 30) |
        (@as(u32, words - 1 - 1) << 16) |
        (@as(u32, gpu.pm4.nop) << 8);
    for (cursor[1..words]) |*word| word.* = 0;

    buffer.cursor_up = cursor + words;
    return cursor;
}

/// One command written into the buffer named by the first argument.
///
/// The remaining arguments describe what the command should do and are not
/// read: what a title checks after one of these is where the command landed and
/// how far the cursor moved.
pub fn writeCommand(
    buffer: ?*CommandBuffer,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    return appendNop(buffer, command_words);
}

/// Edits a field of a command already written.
///
/// Accepted and does nothing. The command being edited is a no-operation, so
/// there is no field whose value would change anything, and a title doing this
/// is doing something ordinary that there is no reason to stop.
pub fn patchCommand(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

fn releasePacket(command_address: u64) ?*[8]u32 {
    if (command_address == 0 or
        !kernel_memory.isGuestRangeAccessible(command_address, 8 * @sizeOf(u32))) return null;
    const words: *[8]u32 = @ptrFromInt(command_address);
    const header = words[0];
    if ((header >> 30) != 3) return null;
    const opcode: u8 = @truncate(header >> 8);
    if (opcode == gpu.pm4.release_mem) return words;
    if (opcode != gpu.pm4.nop or
        @as(u6, @truncate(header >> 2)) != gpu.pm4.custom.release_mem) return null;
    return words;
}

const WaitPacket = struct {
    words: [*]u32,
    is_64_bit: bool,
};

fn waitPacket(command_address: u64) ?WaitPacket {
    if (command_address == 0 or
        !kernel_memory.isGuestRangeAccessible(command_address, 3 * @sizeOf(u32))) return null;
    const words: [*]u32 = @ptrFromInt(command_address);
    const header = words[0];
    if ((header >> 30) != 3 or @as(u8, @truncate(header >> 8)) != gpu.pm4.nop) return null;

    const code: u6 = @truncate(header >> 2);
    const is_64_bit = switch (code) {
        gpu.pm4.custom.wait_mem_32 => false,
        gpu.pm4.custom.wait_mem_64 => true,
        else => return null,
    };
    const word_count: usize = if (is_64_bit) 9 else 7;
    if (!kernel_memory.isGuestRangeAccessible(command_address, word_count * @sizeOf(u32))) return null;
    return .{ .words = words, .is_64_bit = is_64_bit };
}

/// Moves a custom 32/64-bit WAIT_REG_MEM packet to a new watched label.
pub fn patchWaitRegMemAddress(command_address: u64, address: u64) callconv(abi.guest) i32 {
    const packet = waitPacket(command_address) orelse return errno.KernelError.einval.raw();
    const alignment_mask: u32 = if (packet.is_64_bit) 0xffff_fff8 else 0xffff_fffc;
    packet.words[1] = @as(u32, @truncate(address)) & alignment_mask;
    packet.words[2] = @as(u32, @truncate(address >> 32)) & 0x0003_ffff;
    if (wait_patch_reports < 16) {
        std.debug.print(
            "[agc wait patch] cmd=0x{x} width={d} address=0x{x}\n",
            .{ command_address, if (packet.is_64_bit) @as(u32, 64) else 32, address },
        );
        wait_patch_reports += 1;
    }
    return errno.ok;
}

/// Replaces the value a custom WAIT_REG_MEM packet compares against.
pub fn patchWaitRegMemReference(command_address: u64, reference: u64) callconv(abi.guest) i32 {
    const packet = waitPacket(command_address) orelse return errno.KernelError.einval.raw();
    if (packet.is_64_bit) {
        packet.words[5] = @truncate(reference);
        packet.words[6] = @truncate(reference >> 32);
    } else {
        packet.words[4] = @truncate(reference);
    }
    return errno.ok;
}

/// Replaces only the three comparison-function bits, retaining wait operation
/// and cache-policy fields packed alongside them.
pub fn patchWaitRegMemCompareFunction(command_address: u64, compare_function: u32) callconv(abi.guest) i32 {
    if (compare_function > 7) return errno.KernelError.einval.raw();
    const packet = waitPacket(command_address) orelse return errno.KernelError.einval.raw();
    const control_index: usize = if (packet.is_64_bit) 7 else 5;
    packet.words[control_index] = (packet.words[control_index] & ~@as(u32, 0x7)) | compare_function;
    return errno.ok;
}

fn eventWriteEopPacket(command_address: u64) ?*[6]u32 {
    if (command_address == 0 or
        !kernel_memory.isGuestRangeAccessible(command_address, 6 * @sizeOf(u32))) return null;
    const words: *[6]u32 = @ptrFromInt(command_address);
    const header = words[0];
    if ((header >> 30) != 3 or @as(u8, @truncate(header >> 8)) != gpu.pm4.event_write_eop) return null;
    return words;
}

/// Moves either a Gen5 RELEASE_MEM or legacy EVENT_WRITE_EOP completion label.
pub fn patchQueueEndOfPipeAddress(command_address: u64, address: u64) callconv(abi.guest) i32 {
    if (releasePacket(command_address)) |words| {
        words[3] = @truncate(address);
        words[4] = @truncate(address >> 32);
    } else if (eventWriteEopPacket(command_address)) |words| {
        words[2] = @truncate(address);
        words[3] = (words[3] & 0xffff_0000) | (@as(u32, @truncate(address >> 32)) & 0xffff);
    } else {
        return errno.KernelError.einval.raw();
    }
    if (eop_patch_reports < 16) {
        std.debug.print("[agc eop patch] cmd=0x{x} address=0x{x}\n", .{ command_address, address });
        eop_patch_reports += 1;
    }
    return errno.ok;
}

/// Patches the coherency control in the first RELEASE_MEM control word.
pub fn patchQueueEndOfPipeGcr(command_address: u64, gcr_control: u32) callconv(abi.guest) i32 {
    const words = releasePacket(command_address) orelse return errno.KernelError.einval.raw();
    var packet_gcr = gcr_control & 0x0fff;
    // GL2 writeback implies the companion invalidate bit on Gen5.
    if (packet_gcr & 0x300 == 0x100) packet_gcr |= 0x200;
    words[1] = (words[1] & ~@as(u32, 0x00ff_f000)) | (packet_gcr << 12);
    return errno.ok;
}

/// Patches a Core-ring fence payload. The AGC patch context is a monotonic
/// segment generation; the packet stores that generation in the payload's high
/// byte while retaining the caller-provided low 24 bits.
pub fn patchQueueEndOfPipeData(
    command_address: u64,
    context_id: u32,
    data_selection: u32,
    data: u64,
) callconv(abi.guest) i32 {
    if (releasePacket(command_address)) |words| {
        var packet_data = data;
        if (@as(u8, @truncate(words[0] >> 8)) == gpu.pm4.nop and
            context_id > 1 and data_selection == 1)
        {
            packet_data = (@as(u64, context_id - 2) << 24) | (data & 0x00ff_ffff);
        }
        if (eop_patch_reports < 16) {
            std.debug.print(
                "[agc eop patch] cmd=0x{x} context={d} selection={d} data=0x{x}->0x{x}\n",
                .{ command_address, context_id, data_selection, data, packet_data },
            );
            eop_patch_reports += 1;
        }
        words[5] = @truncate(packet_data);
        words[6] = @truncate(packet_data >> 32);
    } else if (eventWriteEopPacket(command_address)) |words| {
        words[4] = @truncate(data);
        words[5] = @truncate(data >> 32);
    } else {
        return errno.KernelError.einval.raw();
    }
    return errno.ok;
}

/// Selects the RELEASE_MEM destination type without disturbing its interrupt
/// selector or payload mode.
pub fn patchQueueEndOfPipeType(command_address: u64, destination: u32) callconv(abi.guest) i32 {
    if (destination > 3) return errno.KernelError.einval.raw();
    const words = releasePacket(command_address) orelse return errno.KernelError.einval.raw();
    words[2] = (words[2] & ~@as(u32, 0x0003_0000)) | (destination << 16);
    return errno.ok;
}

/// How much room a command needs, asked before writing one.
///
/// Has to agree with what the writer actually consumes, or a title that
/// reserves space by asking here will either overrun its buffer or leave a hole
/// in it that nothing accounts for.
pub fn packetSize(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) u32 {
    return command_words;
}

/// Answers "how many" and "which" with nothing.
pub fn zeroQuery(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) u64 {
    return 0;
}

/// Accepts a setting that changes nothing observable here.
pub fn accept(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

/// Reports a debugging facility as switched off.
///
/// Frame capture, submission validation and shader debugging are all things a
/// development machine offers and a retail one does not. Reporting them off is
/// the retail answer, and it is the one that stops a title from waiting for a
/// capture that will never be taken.
pub fn switchedOff(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return 0;
}

/// Refuses a request whose reply a caller stores and then follows.
///
/// Resource registration hands back names, addresses and identifiers that a
/// title keeps and later dereferences. Answering without a registry behind it
/// would furnish it with values naming nothing, and it would carry them until
/// something failed far from here.
pub fn refuse(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.KernelError.enosys.raw();
}

const resource_registration_bytes_per_resource: u64 = 0x118;
const resource_registration_bytes_per_owner: u64 = 0x1e0;
const resource_registration_max_name_length: u32 = 256;

var default_owner = std.atomic.Value(u32).init(1);
var next_owner = std.atomic.Value(u32).init(1);

fn writable(comptime T: type, output: ?*T) ?*T {
    const pointer = output orelse return null;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(pointer), @sizeOf(T))) return null;
    return pointer;
}

/// Returns the exact backing-store requirement used by the PS5 resource
/// registry. Leaving this output untouched makes the caller interpret stack
/// data as a byte count and attempt multi-gigabyte direct-memory allocations.
pub fn driverQueryResourceRegistrationUserMemoryRequirements(
    output: ?*u64,
    resource_count: u64,
    owner_count: u64,
) callconv(abi.guest) i32 {
    const result = writable(u64, output) orelse return errno.KernelError.efault.raw();
    if (resource_count == 0 or owner_count == 0) return errno.KernelError.einval.raw();
    const resources = std.math.mul(u64, resource_count, resource_registration_bytes_per_resource) catch
        return errno.KernelError.einval.raw();
    const owners = std.math.mul(u64, owner_count, resource_registration_bytes_per_owner) catch
        return errno.KernelError.einval.raw();
    result.* = std.math.add(u64, resources, owners) catch
        return errno.KernelError.einval.raw();
    return errno.ok;
}

pub fn driverInitResourceRegistration(
    memory_address: u64,
    memory_size: u64,
    owner_count: u64,
) callconv(abi.guest) i32 {
    if (memory_address == 0 or memory_size == 0 or owner_count == 0) {
        return errno.KernelError.einval.raw();
    }
    if (!kernel_memory.isGuestRangeAccessible(memory_address, memory_size)) {
        return errno.KernelError.efault.raw();
    }
    default_owner.store(1, .release);
    next_owner.store(1, .release);
    return errno.ok;
}

pub fn driverGetResourceRegistrationMaxNameLength(output: ?*u32) callconv(abi.guest) i32 {
    const result = writable(u32, output) orelse return errno.KernelError.efault.raw();
    result.* = resource_registration_max_name_length;
    return errno.ok;
}

pub fn driverRegisterDefaultOwner(owner: u32) callconv(abi.guest) i32 {
    default_owner.store(owner, .release);
    return errno.ok;
}

pub fn driverGetDefaultOwner(output: ?*u32) callconv(abi.guest) i32 {
    const result = writable(u32, output) orelse return errno.KernelError.efault.raw();
    result.* = default_owner.load(.acquire);
    return errno.ok;
}

pub fn driverRegisterOwner(output: ?*u32, name: ?[*:0]const u8) callconv(abi.guest) i32 {
    const result = writable(u32, output) orelse return errno.KernelError.efault.raw();
    if (name == null) return errno.KernelError.einval.raw();
    var owner = next_owner.fetchAdd(1, .acq_rel);
    if (owner == default_owner.load(.acquire)) owner = next_owner.fetchAdd(1, .acq_rel);
    if (owner == 0) return errno.KernelError.enospc.raw();
    result.* = owner;
    return errno.ok;
}

/// Registration is diagnostic metadata; command submission consumes the
/// addresses directly. Preserve the full ABI so callers and traces retain the
/// resource identity even though no host-side name database is needed yet.
pub fn driverRegisterResource(
    resource_address: u64,
    owner: u32,
    name: ?[*:0]const u8,
    base_address: u64,
    resource_type: u32,
    flags: u32,
) callconv(abi.guest) i32 {
    _ = resource_address;
    _ = owner;
    _ = name;
    _ = base_address;
    _ = resource_type;
    _ = flags;
    return errno.ok;
}

pub fn driverAddEqEvent(equeue: i64, id: i32, user_data: u64) callconv(abi.guest) i32 {
    return event_queue.addGraphicsEvent(equeue, id, user_data);
}

pub fn driverDeleteEqEvent(equeue: i64, id: i32) callconv(abi.guest) i32 {
    return event_queue.deleteGraphicsEvent(equeue, id);
}

pub fn driverGetEqEventType(event: ?*const event_queue.Event) callconv(abi.guest) i32 {
    const value = event orelse return 0;
    return if (value.filter == event_queue.graphics_filter)
        @bitCast(@as(u32, @truncate(value.ident)))
    else
        @bitCast(@as(u32, @truncate(@as(u64, @bitCast(value.data)))));
}

pub fn driverGetEqContextId(event: ?*const event_queue.Event) callconv(abi.guest) u32 {
    const value = event orelse return 0;
    return if (value.filter == event_queue.graphics_filter)
        @truncate(@as(u64, @bitCast(value.data)))
    else
        @truncate(value.ident);
}

pub const exports = @import("agc_table.zig").exports;
pub const driver_exports = @import("agc_table.zig").driver_exports;

pub const library = symbols.Library{ .name = "libSceAgc", .version = 1 };
pub const module = symbols.Module{ .name = "libSceAgc", .version_major = 1, .version_minor = 1 };
pub const driver_library = symbols.Library{ .name = "libSceAgcDriver", .version = 1 };
pub const driver_module = symbols.Module{
    .name = "libSceAgcDriver",
    .version_major = 1,
    .version_minor = 1,
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
    try db.addLibrary(gpa, driver_library, driver_module, &driver_exports);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn fixture(storage: []u32) CommandBuffer {
    return .{
        .bottom = storage.ptr,
        .top = storage.ptr + storage.len,
        .cursor_up = storage.ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
}

test "a written command leaves the buffer walkable" {
    // Filling the space with zeroes would not: zeroes decode as a register
    // write of one word, so the buffer becomes a different, shorter stream that
    // nothing can walk.
    var storage: [16]u32 = @splat(0xdead_beef);
    var buffer = fixture(&storage);

    try testing.expect(writeCommand(&buffer, 0, 0, 0, 0, 0) != null);
    try testing.expect(writeCommand(&buffer, 0, 0, 0, 0, 0) != null);

    const written = storage[0 .. 2 * command_words];
    var walker = gpu.pm4.Walker.init(written);
    var seen: usize = 0;
    while (try walker.next()) |packet| {
        try testing.expectEqual(gpu.pm4.nop, packet.opcode);
        try testing.expectEqual(@as(usize, command_words), packet.wordCount());
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);
}

test "the cursor moves by exactly what was written" {
    var storage: [16]u32 = @splat(0);
    var buffer = fixture(&storage);

    const at = writeCommand(&buffer, 0, 0, 0, 0, 0).?;
    try testing.expectEqual(storage[0..].ptr, at);
    try testing.expectEqual(storage[0..].ptr + command_words, buffer.cursor_up.?);
}

test "the size a title is told matches what a write consumes" {
    // A title reserves space by asking first. If the two disagree it either
    // overruns its buffer or leaves a hole nothing accounts for.
    var storage: [64]u32 = @splat(0);
    var buffer = fixture(&storage);
    const announced = packetSize(0, 0, 0, 0, 0, 0);

    const before = @intFromPtr(buffer.cursor_up.?);
    _ = writeCommand(&buffer, 0, 0, 0, 0, 0);
    const consumed = (@intFromPtr(buffer.cursor_up.?) - before) / @sizeOf(u32);
    try testing.expectEqual(@as(usize, announced), consumed);
}

test "AGC wait patches update address reference and comparison in place" {
    const wait32_header = (@as(u32, 3) << 30) |
        (@as(u32, 5) << 16) |
        (@as(u32, gpu.pm4.nop) << 8) |
        (@as(u32, gpu.pm4.custom.wait_mem_32) << 2);
    var wait32 = [_]u32{ wait32_header, 0, 0, 0xffff_ffff, 1, 0x0200_0113, 4 };
    const address32: u64 = 0x0002_1234_5678_9abf;
    try testing.expectEqual(errno.ok, patchWaitRegMemAddress(@intFromPtr(&wait32), address32));
    try testing.expectEqual(errno.ok, patchWaitRegMemReference(@intFromPtr(&wait32), 0xfedc_ba98));
    try testing.expectEqual(errno.ok, patchWaitRegMemCompareFunction(@intFromPtr(&wait32), 6));
    try testing.expectEqual(@as(u32, 0x5678_9abc), wait32[1]);
    try testing.expectEqual(@as(u32, 0x0002_1234), wait32[2]);
    try testing.expectEqual(@as(u32, 0xfedc_ba98), wait32[4]);
    try testing.expectEqual(@as(u32, 0x0200_0116), wait32[5]);

    const wait64_header = (@as(u32, 3) << 30) |
        (@as(u32, 7) << 16) |
        (@as(u32, gpu.pm4.nop) << 8) |
        (@as(u32, gpu.pm4.custom.wait_mem_64) << 2);
    var wait64 = [_]u32{ wait64_header, 0, 0, 0xffff_ffff, 0xffff_ffff, 0, 0, 0x13, 4 };
    const reference64: u64 = 0x0123_4567_89ab_cdef;
    try testing.expectEqual(errno.ok, patchWaitRegMemReference(@intFromPtr(&wait64), reference64));
    try testing.expectEqual(@as(u32, 0x89ab_cdef), wait64[5]);
    try testing.expectEqual(@as(u32, 0x0123_4567), wait64[6]);
}

test "AGC EOP address and data patches support release and legacy packets" {
    const release_header = (@as(u32, 3) << 30) |
        (@as(u32, 6) << 16) |
        (@as(u32, gpu.pm4.release_mem) << 8);
    var release = [_]u32{ release_header, 0, 0, 0, 0, 0, 0, 0 };
    const release_address: u64 = 0x0001_2468_ace0_1000;
    const release_data: u64 = 0x1234_5678_9abc_def0;
    try testing.expectEqual(errno.ok, patchQueueEndOfPipeAddress(@intFromPtr(&release), release_address));
    try testing.expectEqual(errno.ok, patchQueueEndOfPipeData(@intFromPtr(&release), 0, 1, release_data));
    try testing.expectEqual(@as(u32, 0xace0_1000), release[3]);
    try testing.expectEqual(@as(u32, 0x0001_2468), release[4]);
    try testing.expectEqual(@as(u32, 0x9abc_def0), release[5]);
    try testing.expectEqual(@as(u32, 0x1234_5678), release[6]);

    const event_header = (@as(u32, 3) << 30) |
        (@as(u32, 4) << 16) |
        (@as(u32, gpu.pm4.event_write_eop) << 8);
    var event = [_]u32{ event_header, 0, 0, 0xabcd_0000, 0, 0 };
    const event_address: u64 = 0x0000_9876_5432_1000;
    try testing.expectEqual(errno.ok, patchQueueEndOfPipeAddress(@intFromPtr(&event), event_address));
    try testing.expectEqual(errno.ok, patchQueueEndOfPipeData(@intFromPtr(&event), 0, 1, release_data));
    try testing.expectEqual(@as(u32, 0x5432_1000), event[2]);
    try testing.expectEqual(@as(u32, 0xabcd_9876), event[3]);
    try testing.expectEqual(@as(u32, 0x9abc_def0), event[4]);
    try testing.expectEqual(@as(u32, 0x1234_5678), event[5]);
}

test "Rita's Rewind AGC 1.1 imports resolve" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    inline for (&.{
        "eAy8eGNsCuU",
        "tmy-+rBpspY",
        "y5K5tPktiL8",
        "6nths4DHNrs",
        "ICkECTBxrMw",
        "EJBA4dbmvfg",
        "RTpj-tIlvZc",
        "SwI6QxqwAC0",
        "d4NZIlguzv0",
        "ICaGtkEIXTk",
        "WHIOMbb+iIU",
        "chJWZcNSzjk",
        "+iAOE3jCnkk",
    }) |id| {
        try testing.expect(db.findById(id, .function) != null);
    }
}

test "a buffer with no room left says so instead of writing past its end" {
    var storage: [command_words]u32 = @splat(0);
    var buffer = fixture(&storage);

    try testing.expect(writeCommand(&buffer, 0, 0, 0, 0, 0) != null);
    try testing.expect(writeCommand(&buffer, 0, 0, 0, 0, 0) == null);
    // The refusal leaves the cursor where it was, so a title that frees room
    // and retries is not writing into a gap.
    try testing.expectEqual(storage[0..].ptr + command_words, buffer.cursor_up.?);
}

test "a buffer that names no memory is refused rather than followed" {
    var empty = CommandBuffer{
        .bottom = null,
        .top = null,
        .cursor_up = null,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try testing.expect(writeCommand(null, 0, 0, 0, 0, 0) == null);
    try testing.expect(writeCommand(&empty, 0, 0, 0, 0, 0) == null);
}

test "debugging facilities report themselves off, as on a retail machine" {
    // A title told a capture is in progress waits for one that is never taken.
    try testing.expectEqual(@as(i32, 0), switchedOff(0, 0, 0, 0, 0, 0));
}

test "AGC event accessors distinguish event type from context id" {
    const graphics = event_queue.Event{
        .ident = 0x40,
        .filter = event_queue.graphics_filter,
        .data = 0x1234,
    };
    try testing.expectEqual(@as(i32, 0x40), driverGetEqEventType(&graphics));
    try testing.expectEqual(@as(u32, 0x1234), driverGetEqContextId(&graphics));

    const foreign = event_queue.Event{ .ident = 7, .filter = -11, .data = 9 };
    try testing.expectEqual(@as(i32, 9), driverGetEqEventType(&foreign));
    try testing.expectEqual(@as(u32, 7), driverGetEqContextId(&foreign));
}

test "graphics exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len + driver_exports.len, db.count());
    try testing.expect(db.findByName("sceAgcDcbDrawIndexIndirectMulti", .function) != null);
    try testing.expect(db.findByName("sceAgcDriverSubmitMultiAcbs", .function) != null);
}
