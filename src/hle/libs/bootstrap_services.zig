// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Early title-bootstrap services which do not yet have a host presentation or
//! GPU backend. These implementations are intentionally headless, but preserve
//! handles and output structures so a title can pass initialization safely.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const services = @import("services.zig");
const symbols = @import("../symbols.zig");
const kernel_runtime = @import("kernel_runtime.zig");
const kernel_threading = @import("kernel_threading.zig");
const kernel_memory = @import("kernel_memory.zig");
const kernel_event_queue = @import("kernel_event_queue.zig");
const kernel_ioctl = @import("kernel_ioctl.zig");
const agc_submit = @import("agc_submit.zig");
const agc = @import("agc.zig");
const savedata = @import("../savedata.zig");
const agc_register_defaults = @import("agc_register_defaults.zig");
const agc_shader_registry = @import("agc_shader_registry.zig");
const av_player = @import("av_player.zig");
const gpu = @import("gpu");
const apr = @import("../apr.zig");
const filesystem = @import("../filesystem.zig");
const video_out = @import("../video_out.zig");
const guest_memory = @import("memory");

const invalid_argument = errno.KernelError.einval.raw();
const ampr_command_buffer_header_size: u64 = 0x28;
const ampr_command_buffer_maximum_size: u64 = 64 * 1024 * 1024;
const ampr_read_file_record_size: u32 = 0x30;

fn success() callconv(abi.guest) i32 {
    return errno.ok;
}

fn aprError(err: apr.Error) i32 {
    return switch (err) {
        error.FileNotFound, error.UnknownFile => errno.KernelError.enoent.raw(),
        error.FileTableFull, error.CommandBufferTableFull, error.SubmissionTableFull => errno.KernelError.enomem.raw(),
        error.IoFailed => errno.KernelError.eio.raw(),
        error.InvalidPath, error.InvalidCommandBuffer, error.TooManyCommands, error.InvalidRead, error.UnknownSubmission, error.MappingFailed => errno.KernelError.einval.raw(),
        error.OutOfDirectMemory => errno.KernelError.eagain.raw(),
    };
}

fn amprCommandBufferConstructor(address: u64) callconv(abi.guest) i32 {
    if (address == 0) return errno.ok;
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    apr.constructCommandBuffer(address) catch |err| return aprError(err);
    const header: *[ampr_command_buffer_header_size]u8 = @ptrFromInt(address);
    @memset(header, 0);
    writeGuestU64(address + 0x00, address);
    return errno.ok;
}

fn amprAprCommandBufferConstructor(address: u64, reserved_state_0: u64, reserved_state_1: u64) callconv(abi.guest) i32 {
    if (address == 0) return errno.ok;
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    apr.constructCommandBuffer(address) catch |err| return aprError(err);
    writeGuestU64(address + 0x00, address);
    writeGuestU64(address + 0x18, reserved_state_0);
    writeGuestU64(address + 0x20, reserved_state_1);
    return errno.ok;
}

fn amprCommandBufferSetBuffer(address: u64, storage_address: u64, storage_size: usize) callconv(abi.guest) i32 {
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    if (storage_address == 0 or (storage_address & 3) != 0 or storage_size == 0 or
        storage_size > ampr_command_buffer_maximum_size or (storage_size & 3) != 0)
    {
        return errno.KernelError.einval.raw();
    }
    if (readGuestU64(address + 0x08) != 0) return errno.KernelError.ebusy.raw();
    if (!kernel_memory.isGuestRangeAccessible(storage_address, storage_size)) {
        return errno.KernelError.efault.raw();
    }
    apr.setCommandBufferStorage(address, storage_address, storage_size) catch |err| return aprError(err);
    writeGuestU64(address + 0x00, address);
    writeGuestU64(address + 0x08, storage_address);
    writeGuestU64(address + 0x10, storage_size);
    return errno.ok;
}

fn amprCommandBufferReset(address: u64) callconv(abi.guest) i32 {
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    if (readGuestU64(address + 0x08) == 0 or readGuestU64(address + 0x10) == 0) {
        return errno.KernelError.eperm.raw();
    }
    apr.resetCommandBuffer(address) catch |err| return aprError(err);
    writeGuestU64(address + 0x00, address);
    return errno.ok;
}

fn amprCommandBufferClearBuffer(address: u64) callconv(abi.guest) u64 {
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) return 0;
    const storage_address = readGuestU64(address + 0x08);
    apr.destroyCommandBuffer(address) catch {};
    writeGuestU64(address + 0x00, address);
    writeGuestU64(address + 0x08, 0);
    writeGuestU64(address + 0x10, 0);
    return storage_address;
}

fn amprCommandBufferDestructor(address: u64) callconv(abi.guest) void {
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) return;
    apr.destroyCommandBuffer(address) catch {};
    writeGuestU64(address + 0x00, address);
    writeGuestU64(address + 0x08, 0);
    writeGuestU64(address + 0x10, 0);
}

fn amprAprCommandBufferDestructor(address: u64) callconv(abi.guest) void {
    if (!kernel_memory.isGuestRangeAccessible(address + 0x18, 16)) return;
    writeGuestU64(address + 0x18, 0);
    writeGuestU64(address + 0x20, 0);
}

fn amprCommandBufferGetType(address: u64) callconv(abi.guest) u64 {
    const map = apr.mapActive(address) catch return 0;
    const cursor = apr.gatherScatterCursor(address) catch return 0;
    var bits: u64 = 0;
    if (cursor != null) bits |= ampr_type_gather_scatter_valid;
    if (map) bits |= ampr_type_map_active;
    return bits;
}

fn amprCommandBufferGetSize(address: u64) callconv(abi.guest) u64 {
    if (!kernel_memory.isGuestRangeAccessible(address + 0x10, 8)) return 0;
    return readGuestU64(address + 0x10);
}

fn amprCommandBufferGetBufferBaseAddress(address: u64) callconv(abi.guest) u64 {
    if (!kernel_memory.isGuestRangeAccessible(address + 0x08, 8)) return 0;
    return readGuestU64(address + 0x08);
}

fn amprCommandBufferGetNumCommands(address: u64) callconv(abi.guest) u64 {
    const info = apr.commandBufferInfo(address) catch return 0;
    return info.command_count;
}

fn amprCommandBufferGetCurrentOffset(address: u64) callconv(abi.guest) u64 {
    const info = apr.commandBufferInfo(address) catch return 0;
    return info.write_offset;
}

fn amprAprCommandBufferReadFile(
    address: u64,
    _: u64,
    _: u64,
    file_identifier: u32,
    destination: u64,
    size: u64,
    file_offset: u64,
) callconv(abi.guest) i32 {
    if (size == 0 or size > apr.maximum_read_bytes or file_offset >= apr.maximum_file_offset) {
        return errno.KernelError.einval.raw();
    }
    if (!kernel_memory.isGuestRangeAccessible(destination, size)) return errno.KernelError.efault.raw();
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    const info = apr.commandBufferInfo(address) catch |err| return aprError(err);
    if (info.storage_address == 0 or info.write_offset > info.storage_size or
        ampr_read_file_record_size > info.storage_size - info.write_offset)
    {
        return errno.KernelError.efault.raw();
    }
    const record_address = std.math.add(u64, info.storage_address, info.write_offset) catch {
        return errno.KernelError.efault.raw();
    };
    if (!kernel_memory.isGuestRangeAccessible(record_address, ampr_read_file_record_size)) {
        return errno.KernelError.efault.raw();
    }
    apr.appendRead(address, .{
        .file_identifier = file_identifier,
        .destination = destination,
        .size = @intCast(size),
        .file_offset = file_offset,
    }) catch |err| return aprError(err);
    const record: [*]u8 = @ptrFromInt(record_address);
    @memset(record[0..ampr_read_file_record_size], 0);
    writeGuestU32(record_address + 0x00, 1);
    writeGuestU32(record_address + 0x04, file_identifier);
    writeGuestU64(record_address + 0x08, destination);
    writeGuestU64(record_address + 0x10, size);
    writeGuestU64(record_address + 0x18, file_offset);
    writeGuestU64(record_address + 0x20, size);
    return errno.ok;
}

fn amprMeasureCommandSizeReadFile(
    _: u64,
    destination: u64,
    size: u64,
    file_offset: u64,
) callconv(abi.guest) u64 {
    if ((destination == 0 and size != 0) or
        size > apr.maximum_read_bytes or
        file_offset >= apr.maximum_file_offset)
    {
        return @bitCast(@as(i64, errno.KernelError.einval.raw()));
    }
    return ampr_read_file_record_size;
}

fn amprMeasureCommandSizeWriteKernelEventQueue(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) u64 {
    return 0x30;
}

const ampr_opcode_gather: u32 = 0x18;
const ampr_opcode_scatter: u32 = 0x19;
const ampr_opcode_gather_scatter: u32 = 0x1a;
const ampr_scatter_record_size: u32 = 0x0c;
const ampr_reset_gather_scatter_size: u32 = 0x04;

fn amprGatherRecordSize(file_offset: u64) u32 {
    return if (file_offset > 0x3ffff) 0x0c else 0x08;
}

fn amprGatherScatterRecordSize(file_offset: u64) u32 {
    return if (file_offset >> 32 != 0) 0x14 else 0x10;
}

fn amprInvalidMeasure() u64 {
    return @bitCast(@as(i64, errno.KernelError.einval.raw()));
}

fn amprReserveRecord(address: u64, record_size: u32) apr.Error!u64 {
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return error.InvalidCommandBuffer;
    }
    const info = try apr.commandBufferInfo(address);
    if (info.storage_address == 0 or info.write_offset > info.storage_size or
        record_size > info.storage_size - info.write_offset)
    {
        return error.InvalidCommandBuffer;
    }
    const record_address = std.math.add(u64, info.storage_address, info.write_offset) catch
        return error.InvalidCommandBuffer;
    if (!kernel_memory.isGuestRangeAccessible(record_address, record_size)) {
        return error.InvalidCommandBuffer;
    }
    return record_address;
}

fn amprWriteOpcodeRecord(record_address: u64, record_size: u32, opcode: u32) void {
    const record: [*]u8 = @ptrFromInt(record_address);
    @memset(record[0..record_size], 0);
    writeGuestU32(record_address + 0x00, opcode);
}

fn amprAprCommandBufferReadFileGather(
    address: u64,
    _: u64,
    _: u64,
    size: u64,
    file_offset: u64,
) callconv(abi.guest) i32 {
    if (size == 0 or size > apr.maximum_read_bytes or file_offset >= apr.maximum_file_offset) {
        return errno.KernelError.einval.raw();
    }
    const cursor = (apr.gatherScatterCursor(address) catch |err| return aprError(err)) orelse
        return errno.KernelError.einval.raw();
    if (!kernel_memory.isGuestRangeAccessible(cursor.destination, size)) {
        return errno.KernelError.efault.raw();
    }
    const record_size = amprGatherRecordSize(file_offset);
    const record_address = amprReserveRecord(address, record_size) catch |err| return aprError(err);
    apr.appendReadRecord(address, .{
        .file_identifier = cursor.file_identifier,
        .destination = cursor.destination,
        .size = @intCast(size),
        .file_offset = file_offset,
    }, record_size) catch |err| return aprError(err);
    amprWriteOpcodeRecord(record_address, record_size, ampr_opcode_gather);
    return errno.ok;
}

fn amprAprCommandBufferReadFileScatter(
    address: u64,
    _: u64,
    _: u64,
    destination: u64,
    size: u64,
) callconv(abi.guest) i32 {
    if (size == 0 or size > apr.maximum_read_bytes or destination == 0) {
        return errno.KernelError.einval.raw();
    }
    if (!kernel_memory.isGuestRangeAccessible(destination, size)) {
        return errno.KernelError.efault.raw();
    }
    const cursor = (apr.gatherScatterCursor(address) catch |err| return aprError(err)) orelse
        return errno.KernelError.einval.raw();
    if (cursor.file_offset >= apr.maximum_file_offset) return errno.KernelError.einval.raw();
    const record_address = amprReserveRecord(address, ampr_scatter_record_size) catch |err|
        return aprError(err);
    apr.appendReadRecord(address, .{
        .file_identifier = cursor.file_identifier,
        .destination = destination,
        .size = @intCast(size),
        .file_offset = cursor.file_offset,
    }, ampr_scatter_record_size) catch |err| return aprError(err);
    amprWriteOpcodeRecord(record_address, ampr_scatter_record_size, ampr_opcode_scatter);
    return errno.ok;
}

fn amprAprCommandBufferReadFileGatherScatter(
    address: u64,
    _: u64,
    _: u64,
    destination: u64,
    size: u64,
    file_offset: u64,
) callconv(abi.guest) i32 {
    if (size == 0 or size > apr.maximum_read_bytes or destination == 0 or
        file_offset >= apr.maximum_file_offset)
    {
        return errno.KernelError.einval.raw();
    }
    if (!kernel_memory.isGuestRangeAccessible(destination, size)) {
        return errno.KernelError.efault.raw();
    }
    const cursor = (apr.gatherScatterCursor(address) catch |err| return aprError(err)) orelse
        return errno.KernelError.einval.raw();
    const record_size = amprGatherScatterRecordSize(file_offset);
    const record_address = amprReserveRecord(address, record_size) catch |err| return aprError(err);
    apr.appendReadRecord(address, .{
        .file_identifier = cursor.file_identifier,
        .destination = destination,
        .size = @intCast(size),
        .file_offset = file_offset,
    }, record_size) catch |err| return aprError(err);
    amprWriteOpcodeRecord(record_address, record_size, ampr_opcode_gather_scatter);
    return errno.ok;
}

fn amprAprCommandBufferResetGatherScatterState(
    address: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    const record_address = amprReserveRecord(address, ampr_reset_gather_scatter_size) catch |err|
        return aprError(err);
    apr.appendRecordBytes(address, ampr_reset_gather_scatter_size) catch |err| return aprError(err);
    apr.clearGatherScatterCursor(address) catch |err| return aprError(err);
    amprWriteOpcodeRecord(record_address, ampr_reset_gather_scatter_size, 0);
    return errno.ok;
}

fn amprMeasureCommandSizeReadFileGather(size: u64, file_offset: u64) callconv(abi.guest) u64 {
    if (size == 0 or size > apr.maximum_read_bytes or file_offset >= apr.maximum_file_offset) {
        return amprInvalidMeasure();
    }
    return amprGatherRecordSize(file_offset);
}

fn amprMeasureCommandSizeReadFileScatter(destination: u64, size: u64) callconv(abi.guest) u64 {
    if (destination == 0 or size == 0 or size > apr.maximum_read_bytes) {
        return amprInvalidMeasure();
    }
    return ampr_scatter_record_size;
}

fn amprMeasureCommandSizeReadFileGatherScatter(
    destination: u64,
    size: u64,
    file_offset: u64,
) callconv(abi.guest) u64 {
    if (destination == 0 or size == 0 or size > apr.maximum_read_bytes or
        file_offset >= apr.maximum_file_offset)
    {
        return amprInvalidMeasure();
    }
    return amprGatherScatterRecordSize(file_offset);
}

fn amprMeasureCommandSizeResetGatherScatterState(
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) u64 {
    return ampr_reset_gather_scatter_size;
}

const ampr_opcode_write_address: u32 = 3;
const ampr_fixed_record_size: u32 = 0x20;
const ampr_map_begin_record_size: u32 = 0x0c;
const ampr_map_direct_begin_record_size: u32 = 0x10;
const ampr_map_end_record_size: u32 = 0x04;
const ampr_map_page_size: u64 = 0x4000;
const ampr_maximum_nop_words: u32 = 16;
const ampr_type_gather_scatter_valid: u64 = 0x0001_0000;
const ampr_type_map_active: u64 = 0x0002_0000;

fn amprAlignUp4(value: u64) u64 {
    return (value + 3) & ~@as(u64, 3);
}

fn amprGuestCStringBytes(text: ?[*:0]const u8) usize {
    const pointer = text orelse return 0;
    const address = @intFromPtr(pointer);
    var index: usize = 0;
    while (index < 256) : (index += 1) {
        if (!kernel_memory.isGuestRangeAccessible(address + index, 1)) break;
        if (pointer[index] == 0) return index + 1;
    }
    return index;
}

fn amprMarkerRecordSize(text: ?[*:0]const u8, with_color: bool) u32 {
    const header: u64 = if (with_color) 8 else 4;
    return @intCast(amprAlignUp4(header + amprGuestCStringBytes(text)));
}

fn amprAppendNop(address: u64, record_size: u64) i32 {
    if (record_size == 0 or record_size > std.math.maxInt(u32)) return errno.KernelError.einval.raw();
    const size: u32 = @intCast(record_size);
    const record_address = amprReserveRecord(address, size) catch |err| return aprError(err);
    apr.appendRecordBytes(address, size) catch |err| return aprError(err);
    amprWriteOpcodeRecord(record_address, size, 0);
    return errno.ok;
}

fn amprAppendWriteAddress(address: u64, destination: u64, value: u64) i32 {
    if (destination == 0) return errno.KernelError.einval.raw();
    if (!kernel_memory.isGuestRangeAccessible(destination, 8)) return errno.KernelError.efault.raw();
    const record_address = amprReserveRecord(address, ampr_fixed_record_size) catch |err|
        return aprError(err);
    apr.appendWrite(address, .{ .destination = destination, .value = value }, ampr_fixed_record_size) catch |err|
        return aprError(err);
    const record: [*]u8 = @ptrFromInt(record_address);
    @memset(record[0..ampr_fixed_record_size], 0);
    writeGuestU32(record_address + 0x00, ampr_opcode_write_address);
    writeGuestU64(record_address + 0x08, destination);
    writeGuestU64(record_address + 0x10, value);
    return errno.ok;
}

fn amprMapArgsValid(va: u64, size: u64) bool {
    return va != 0 and size != 0 and
        va & (ampr_map_page_size - 1) == 0 and
        size & (ampr_map_page_size - 1) == 0 and
        va +% size >= va;
}

fn amprCommandBufferNop(address: u64, word_count: u32) callconv(abi.guest) i32 {
    if (word_count == 0 or word_count > ampr_maximum_nop_words) return errno.KernelError.einval.raw();
    return amprAppendNop(address, @as(u64, word_count) * 4);
}

fn amprCommandBufferNopWithData(address: u64, word_count: u32, _: ?*const u32) callconv(abi.guest) i32 {
    if (word_count > ampr_maximum_nop_words - 1) return errno.KernelError.einval.raw();
    return amprAppendNop(address, (@as(u64, word_count) + 1) * 4);
}

fn amprCommandBufferConstructNop(
    address: u64,
    _: u32,
    _: ?*const anyopaque,
    bytes: u32,
    _: ?*const u32,
) callconv(abi.guest) i32 {
    return amprAppendNop(address, @as(u64, 4) + bytes);
}

fn amprCommandBufferConstructMarker(
    address: u64,
    _: u32,
    text: ?[*:0]const u8,
    color: ?*const u32,
) callconv(abi.guest) i32 {
    return amprAppendNop(address, amprMarkerRecordSize(text, color != null));
}

fn amprCommandBufferSetMarker(address: u64, text: ?[*:0]const u8) callconv(abi.guest) i32 {
    return amprAppendNop(address, amprMarkerRecordSize(text, false));
}

fn amprCommandBufferSetMarkerWithColor(address: u64, text: ?[*:0]const u8, _: u32) callconv(abi.guest) i32 {
    return amprAppendNop(address, amprMarkerRecordSize(text, true));
}

fn amprCommandBufferPushMarker(address: u64, text: ?[*:0]const u8) callconv(abi.guest) i32 {
    return amprAppendNop(address, amprMarkerRecordSize(text, false));
}

fn amprCommandBufferPushMarkerWithColor(address: u64, text: ?[*:0]const u8, _: u32) callconv(abi.guest) i32 {
    return amprAppendNop(address, amprMarkerRecordSize(text, true));
}

fn amprCommandBufferPopMarker(address: u64) callconv(abi.guest) i32 {
    return amprAppendNop(address, 4);
}

fn amprCommandBufferWaitOnAddress(
    address: u64,
    _: ?*volatile u64,
    _: u64,
    _: u8,
    _: u8,
) callconv(abi.guest) i32 {
    return amprAppendNop(address, ampr_fixed_record_size);
}

fn amprCommandBufferWaitOnCounter(
    address: u64,
    _: u8,
    _: u8,
    _: u64,
    _: u8,
    _: u8,
    _: u64,
    _: u8,
) callconv(abi.guest) i32 {
    return amprAppendNop(address, ampr_fixed_record_size);
}

fn amprCommandBufferWriteAddress(
    address: u64,
    destination: ?*volatile u64,
    value: u64,
    _: u32,
) callconv(abi.guest) i32 {
    const target = destination orelse return errno.KernelError.einval.raw();
    return amprAppendWriteAddress(address, @intFromPtr(target), value);
}

fn amprCommandBufferWriteAddressFromTimeCounter(
    address: u64,
    destination: ?*volatile u64,
    _: u32,
) callconv(abi.guest) i32 {
    const target = destination orelse return errno.KernelError.einval.raw();
    return amprAppendWriteAddress(address, @intFromPtr(target), 0);
}

fn amprCommandBufferWriteAddressFromCounter(
    address: u64,
    destination: ?*volatile u64,
    _: u8,
    _: u32,
) callconv(abi.guest) i32 {
    const target = destination orelse return errno.KernelError.einval.raw();
    return amprAppendWriteAddress(address, @intFromPtr(target), 0);
}

fn amprCommandBufferWriteAddressFromCounterPair(
    address: u64,
    destination: ?*volatile u64,
    _: u8,
    _: u32,
) callconv(abi.guest) i32 {
    const target = destination orelse return errno.KernelError.einval.raw();
    return amprAppendWriteAddress(address, @intFromPtr(target), 0);
}

fn amprCommandBufferWriteCounter(
    address: u64,
    _: u8,
    _: u8,
    _: u64,
    _: u8,
    _: u32,
) callconv(abi.guest) i32 {
    return amprAppendNop(address, ampr_fixed_record_size);
}

fn amprAprCommandBufferMapBegin(
    address: u64,
    va: u64,
    size: u64,
    _: i32,
    _: i32,
) callconv(abi.guest) i32 {
    if (!amprMapArgsValid(va, size)) return errno.KernelError.einval.raw();
    const status = amprAppendNop(address, ampr_map_begin_record_size);
    if (status != errno.ok) return status;
    apr.setMapActive(address, true) catch |err| return aprError(err);
    return errno.ok;
}

fn amprAprCommandBufferMapDirectBegin(
    address: u64,
    va: u64,
    dmem_offset: u64,
    size: u64,
    _: i32,
    _: i32,
) callconv(abi.guest) i32 {
    if (!amprMapArgsValid(va, size) or dmem_offset & (ampr_map_page_size - 1) != 0) {
        return errno.KernelError.einval.raw();
    }
    const status = amprAppendNop(address, ampr_map_direct_begin_record_size);
    if (status != errno.ok) return status;
    apr.setMapActive(address, true) catch |err| return aprError(err);
    return errno.ok;
}

fn amprAprCommandBufferMapEnd(address: u64) callconv(abi.guest) i32 {
    const active = apr.mapActive(address) catch |err| return aprError(err);
    if (!active) return errno.KernelError.eperm.raw();
    const status = amprAppendNop(address, ampr_map_end_record_size);
    if (status != errno.ok) return status;
    apr.setMapActive(address, false) catch |err| return aprError(err);
    return errno.ok;
}

const amm_map_record_size: u32 = 0x20;
const amm_map_direct_record_size: u32 = 0x30;
const amm_unmap_record_size: u32 = 0x20;
const amm_usage_direct: i32 = 0;
const amm_usage_auto: i32 = 1;
const amm_va_start: u64 = 0x10_0000_0000;
const amm_va_size: u64 = 0x10_0000_0000;
const amm_prot_cpu_read: i32 = 0x01;
const amm_prot_cpu_write: i32 = 0x02;
const amm_prot_cpu_exec: i32 = 0x04;
const amm_prot_gpu_read: i32 = 0x10;
const amm_prot_gpu_write: i32 = 0x20;
const amm_prot_ampr_read: i32 = 0x40;
const amm_prot_ampr_write: i32 = 0x80;
const amm_prot_acp_read: i32 = 0x100;
const amm_prot_acp_write: i32 = 0x200;

const AmmUsageStats = extern struct {
    size_in_bytes: u64 = 0,
    num_page_table_pool_entries: u16 = 0,
    snapshot_allocated_entries: u16 = 0,
    high_watermark_allocated_entries: u16 = 0,
    reserved1: u16 = 0,
    ring_idle_flags: u32 = 0,
};

comptime {
    if (@sizeOf(AmmUsageStats) != 0x18) @compileError("AMM usage stats must be 24 bytes");
}

fn normalizeAmmProtection(prot: i32) i32 {
    const cpu_gpu = amm_prot_cpu_read | amm_prot_cpu_write | amm_prot_cpu_exec |
        amm_prot_gpu_read | amm_prot_gpu_write;
    var bits = prot & cpu_gpu;
    if (prot & amm_prot_ampr_read != 0) bits |= amm_prot_cpu_read;
    if (prot & amm_prot_ampr_write != 0) bits |= amm_prot_cpu_read | amm_prot_cpu_write;
    if (prot & amm_prot_acp_read != 0) bits |= amm_prot_cpu_read;
    if (prot & amm_prot_acp_write != 0) bits |= amm_prot_cpu_read | amm_prot_cpu_write;
    return bits;
}

fn amprAppendAmmMap(address: u64, command: apr.AmmMapCommand, record_size: u32) i32 {
    const record_address = amprReserveRecord(address, record_size) catch |err| return aprError(err);
    apr.appendAmmMap(address, command, record_size) catch |err| return aprError(err);
    amprWriteOpcodeRecord(record_address, record_size, 0);
    return errno.ok;
}

fn amprAmmCommandBufferConstructor(address: u64) callconv(abi.guest) i32 {
    return amprCommandBufferConstructor(address);
}

fn amprAmmCommandBufferDestructor(address: u64) callconv(abi.guest) void {
    amprCommandBufferDestructor(address);
}

fn amprAmmCommandBufferMap(
    address: u64,
    va: u64,
    size: u64,
    memory_type: i32,
    prot: i32,
) callconv(abi.guest) i32 {
    if (!amprMapArgsValid(va, size)) return errno.KernelError.einval.raw();
    return amprAppendAmmMap(address, .{
        .kind = .map_auto,
        .va = va,
        .size = size,
        .memory_type = memory_type,
        .protection = normalizeAmmProtection(prot),
    }, amm_map_record_size);
}

fn amprAmmCommandBufferMapWithGpuMaskId(
    address: u64,
    va: u64,
    size: u64,
    memory_type: i32,
    prot: i32,
    _: u8,
) callconv(abi.guest) i32 {
    return amprAmmCommandBufferMap(address, va, size, memory_type, prot);
}

fn amprAmmCommandBufferMapDirect(
    address: u64,
    va: u64,
    dmem_offset: u64,
    size: u64,
    memory_type: i32,
    prot: i32,
) callconv(abi.guest) i32 {
    if (!amprMapArgsValid(va, size) or dmem_offset & (ampr_map_page_size - 1) != 0) {
        return errno.KernelError.einval.raw();
    }
    return amprAppendAmmMap(address, .{
        .kind = .map_direct,
        .va = va,
        .dmem_offset = dmem_offset,
        .size = size,
        .memory_type = memory_type,
        .protection = normalizeAmmProtection(prot),
    }, amm_map_direct_record_size);
}

fn amprAmmCommandBufferMapDirectWithGpuMaskId(
    address: u64,
    va: u64,
    dmem_offset: u64,
    size: u64,
    memory_type: i32,
    prot: i32,
    _: u8,
) callconv(abi.guest) i32 {
    return amprAmmCommandBufferMapDirect(address, va, dmem_offset, size, memory_type, prot);
}

fn amprAmmCommandBufferUnmap(address: u64, va: u64, size: u64) callconv(abi.guest) i32 {
    if (!amprMapArgsValid(va, size)) return errno.KernelError.einval.raw();
    return amprAppendAmmMap(address, .{
        .kind = .unmap,
        .va = va,
        .size = size,
    }, amm_unmap_record_size);
}

fn amprAmmGiveDirectMemory(
    search_start: i64,
    search_end: i64,
    size: u64,
    alignment: u64,
    usage: i32,
    dmem_offset: ?*i64,
) callconv(abi.guest) i32 {
    const output = dmem_offset orelse return errno.KernelError.einval.raw();
    if (size == 0 or (usage != amm_usage_direct and usage != amm_usage_auto)) {
        return errno.KernelError.einval.raw();
    }
    if (search_start < 0 or search_end < 0) return errno.KernelError.einval.raw();
    var allocated: u64 = 0;
    const status = kernel_memory.hostAllocateDirectMemory(
        @intCast(search_start),
        @intCast(search_end),
        size,
        alignment,
        0,
        &allocated,
    );
    if (status != errno.ok) return status;
    output.* = @intCast(allocated);
    if (usage == amm_usage_auto) {
        apr.giveAutoPool(allocated, size) catch |err| return aprError(err);
    }
    return errno.ok;
}

fn amprAmmGetVirtualAddressRanges(
    va_start: ?*u64,
    va_end: ?*u64,
    multimap_va_start: ?*u64,
    multimap_va_end: ?*u64,
) callconv(abi.guest) void {
    if (va_start) |out| out.* = amm_va_start;
    if (va_end) |out| out.* = amm_va_start + amm_va_size;
    if (multimap_va_start) |out| out.* = amm_va_start + amm_va_size / 2;
    if (multimap_va_end) |out| out.* = amm_va_start + amm_va_size;
}

fn amprAmmGetUsageStatsData(stats: ?*AmmUsageStats) callconv(abi.guest) i32 {
    const output = stats orelse return errno.KernelError.einval.raw();
    if (output.size_in_bytes > @sizeOf(AmmUsageStats)) return errno.KernelError.einval.raw();
    const address = @intFromPtr(output);
    if (!kernel_memory.isGuestRangeAccessible(address, output.size_in_bytes)) {
        return errno.KernelError.efault.raw();
    }
    var filled = AmmUsageStats{
        .size_in_bytes = output.size_in_bytes,
        .num_page_table_pool_entries = 512,
        .ring_idle_flags = 0x7,
    };
    const bytes = output.size_in_bytes;
    if (bytes == 0) return errno.ok;
    const source: [*]const u8 = @ptrCast(&filled);
    const dest: [*]u8 = @ptrFromInt(address);
    @memcpy(dest[0..bytes], source[0..bytes]);
    return errno.ok;
}

fn amprAmmSetPageTablePoolOccupancyNotificationThreshold(_: u32) callconv(abi.guest) i32 {
    return errno.ok;
}

fn amprAmmSubmitCommandBuffer(address: u64, _: u32, _: u32) callconv(abi.guest) i32 {
    if (address == 0) return errno.KernelError.einval.raw();
    _ = apr.submitCommandBuffer(address) catch |err| return aprError(err);
    return errno.ok;
}

fn amprAmmSubmitCommandBufferAndGetId(
    address: u64,
    _: u32,
    _: u32,
    out_identifier: ?*u32,
) callconv(abi.guest) i32 {
    const output = out_identifier orelse return errno.KernelError.einval.raw();
    if (address == 0) return errno.KernelError.einval.raw();
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(u32))) {
        return errno.KernelError.efault.raw();
    }
    output.* = apr.submitCommandBuffer(address) catch |err| return aprError(err);
    return errno.ok;
}

fn amprAmmSubmitCommandBufferAndGetResult(
    address: u64,
    _: u32,
    _: u32,
    result: ?*u64,
    out_identifier: ?*u32,
) callconv(abi.guest) i32 {
    if (address == 0) return errno.KernelError.einval.raw();
    const identifier = apr.submitCommandBuffer(address) catch |err| return aprError(err);
    if (result) |output| {
        if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), 8)) {
            return errno.KernelError.efault.raw();
        }
        output.* = 0;
    }
    if (out_identifier) |output| {
        if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(u32))) {
            return errno.KernelError.efault.raw();
        }
        output.* = identifier;
    }
    return errno.ok;
}

fn amprAmmWaitCommandBufferCompletion(identifier: u32) callconv(abi.guest) i32 {
    apr.waitCommandBuffer(identifier) catch |err| return switch (err) {
        error.UnknownSubmission => errno.KernelError.esrch.raw(),
        else => aprError(err),
    };
    return errno.ok;
}

fn amprMeasureAmmCommandSizeMap(_: u64, _: u64, _: i32, _: i32) callconv(abi.guest) i64 {
    return amm_map_record_size;
}

fn amprMeasureAmmCommandSizeMapWithGpuMaskId(_: u64, _: u64, _: i32, _: i32, _: u8) callconv(abi.guest) i64 {
    return amm_map_record_size;
}

fn amprMeasureAmmCommandSizeMapDirect(_: u64, _: u64, _: u64, _: i32, _: i32) callconv(abi.guest) i64 {
    return amm_map_direct_record_size;
}

fn amprMeasureAmmCommandSizeMapDirectWithGpuMaskId(
    _: u64,
    _: u64,
    _: u64,
    _: i32,
    _: i32,
    _: u8,
) callconv(abi.guest) i64 {
    return amm_map_direct_record_size;
}

fn amprMeasureAmmCommandSizeUnmap(_: u64, _: u64) callconv(abi.guest) i64 {
    return amm_unmap_record_size;
}

fn amprMeasureCommandSizeFixed32(
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) u64 {
    return ampr_fixed_record_size;
}

fn amprMeasureCommandSizeNop(word_count: u32) callconv(abi.guest) u64 {
    if (word_count == 0) return 4;
    return amprAlignUp4(@as(u64, word_count) * 4);
}

fn amprMeasureCommandSizeNopWithData(word_count: u32, _: ?*const u32) callconv(abi.guest) u64 {
    return amprAlignUp4((@as(u64, word_count) + 1) * 4);
}

fn amprMeasureCommandSizeSetMarker(text: ?[*:0]const u8) callconv(abi.guest) u64 {
    return amprMarkerRecordSize(text, false);
}

fn amprMeasureCommandSizeSetMarkerWithColor(text: ?[*:0]const u8, _: u32) callconv(abi.guest) u64 {
    return amprMarkerRecordSize(text, true);
}

fn amprMeasureCommandSizePopMarker() callconv(abi.guest) u64 {
    return 4;
}

fn amprMeasureCommandSizeMapBegin(va: u64, size: u64, _: i32, _: i32) callconv(abi.guest) u64 {
    if (!amprMapArgsValid(va, size)) return amprInvalidMeasure();
    return ampr_map_begin_record_size;
}

fn amprMeasureCommandSizeMapDirectBegin(
    va: u64,
    dmem_offset: u64,
    size: u64,
    _: i32,
    _: i32,
) callconv(abi.guest) u64 {
    if (!amprMapArgsValid(va, size) or dmem_offset & (ampr_map_page_size - 1) != 0) {
        return amprInvalidMeasure();
    }
    return ampr_map_direct_begin_record_size;
}

fn amprCommandBufferWriteKernelEventQueue(
    address: u64,
    queue_handle: i64,
    ident: u64,
    completion_token: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (!kernel_memory.isGuestRangeAccessible(address, ampr_command_buffer_header_size)) {
        return errno.KernelError.efault.raw();
    }
    const record_size: u32 = 0x30;
    const info = apr.commandBufferInfo(address) catch |err| return aprError(err);
    if (info.storage_address == 0 or info.write_offset > info.storage_size or
        record_size > info.storage_size - info.write_offset)
    {
        return errno.KernelError.efault.raw();
    }
    const record_address = std.math.add(u64, info.storage_address, info.write_offset) catch
        return errno.KernelError.efault.raw();
    if (!kernel_memory.isGuestRangeAccessible(record_address, record_size)) {
        return errno.KernelError.efault.raw();
    }
    apr.appendCompletion(address, .{
        .queue_handle = queue_handle,
        .ident = ident,
        .completion_token = completion_token,
        .user_data = 0,
    }) catch |err| return aprError(err);

    const record: [*]u8 = @ptrFromInt(record_address);
    @memset(record[0..record_size], 0);
    writeGuestU32(record_address + 0x00, 2);
    @as(*i16, @ptrFromInt(record_address + 0x04)).* = kernel_event_queue.ampr_filter;
    writeGuestU64(record_address + 0x08, @bitCast(queue_handle));
    writeGuestU64(record_address + 0x10, ident);
    writeGuestU64(record_address + 0x18, 0);
    writeGuestU64(record_address + 0x20, completion_token);
    return errno.ok;
}

fn readGuestU32(address: u64) u32 {
    const source: *const [4]u8 = @ptrFromInt(address);
    return std.mem.readInt(u32, source, .little);
}

fn readGuestU64(address: u64) u64 {
    const source: *const [8]u8 = @ptrFromInt(address);
    return std.mem.readInt(u64, source, .little);
}

fn writeGuestU32(address: u64, value: u32) void {
    const destination: *[4]u8 = @ptrFromInt(address);
    std.mem.writeInt(u32, destination, value, .little);
}

fn writeGuestU64(address: u64, value: u64) void {
    const destination: *[8]u8 = @ptrFromInt(address);
    std.mem.writeInt(u64, destination, value, .little);
}

// Offline POSIX sockets ----------------------------------------------------

fn posixSocket(family: i32, socket_type: i32, _: i32) callconv(abi.guest) i32 {
    if (family != 2 or socket_type & 0xf == 0) {
        kernel_runtime.setPosixErrno(errno.Posix.einval);
        return -1;
    }
    return filesystem.openVirtualSocket() catch {
        kernel_runtime.setPosixErrno(errno.Posix.emfile);
        return -1;
    };
}

fn posixSocketConnect(descriptor: i32, address: ?[*]const u8, length: u32) callconv(abi.guest) i32 {
    if (!filesystem.isVirtualSocket(descriptor)) {
        kernel_runtime.setPosixErrno(errno.Posix.ebadf);
        return -1;
    }
    const peer = address orelse {
        kernel_runtime.setPosixErrno(errno.Posix.efault);
        return -1;
    };
    if (length >= 8 and peer[1] == 2 and peer[4] == 127 and peer[5] == 0 and peer[6] == 0 and peer[7] == 1) {
        return errno.ok;
    }
    kernel_runtime.setPosixErrno(50); // FreeBSD/Orbis ENETDOWN
    return -1;
}

fn posixSocketNeedsPeer(descriptor: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (!filesystem.isVirtualSocket(descriptor)) {
        kernel_runtime.setPosixErrno(errno.Posix.ebadf);
        return -1;
    }
    kernel_runtime.setPosixErrno(50);
    return -1;
}

fn posixSocketLocalState(descriptor: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    if (filesystem.isVirtualSocket(descriptor)) return errno.ok;
    kernel_runtime.setPosixErrno(errno.Posix.ebadf);
    return -1;
}

fn posixMessageOperation(_: i32, _: ?*anyopaque, _: i32) callconv(abi.guest) i64 {
    kernel_runtime.setPosixErrno(50); // FreeBSD/Orbis ENETDOWN
    return -1;
}

fn posixInetNtopFail(reason: i32) ?[*]u8 {
    kernel_runtime.setPosixErrno(reason);
    return null;
}

/// Converts a binary IP address without opening a host socket. The guest uses
/// this during runtime initialization even when all networking is offline.
fn posixInetNtop(
    family: i32,
    source_optional: ?[*]const u8,
    destination_optional: ?[*]u8,
    destination_size: u32,
) callconv(abi.guest) ?[*]u8 {
    const source = source_optional orelse return posixInetNtopFail(errno.Posix.efault);
    const destination = destination_optional orelse return posixInetNtopFail(errno.Posix.efault);
    const source_size: usize = switch (family) {
        2 => 4, // ORBIS_AF_INET
        28 => 16, // ORBIS_AF_INET6
        else => return posixInetNtopFail(errno.Posix.einval),
    };
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(source), source_size)) {
        return posixInetNtopFail(errno.Posix.efault);
    }

    var text_buffer: [40]u8 = undefined;
    const text = if (family == 2)
        std.fmt.bufPrint(
            &text_buffer,
            "{d}.{d}.{d}.{d}",
            .{ source[0], source[1], source[2], source[3] },
        ) catch return posixInetNtopFail(errno.Posix.einval)
    else blk: {
        const bytes = source[0..16];
        var groups: [8]u16 = undefined;
        for (&groups, 0..) |*group, index| {
            group.* = std.mem.readInt(u16, bytes[index * 2 ..][0..2], .big);
        }
        break :blk std.fmt.bufPrint(
            &text_buffer,
            "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}",
            .{ groups[0], groups[1], groups[2], groups[3], groups[4], groups[5], groups[6], groups[7] },
        ) catch return posixInetNtopFail(errno.Posix.einval);
    };
    const required = text.len + 1;
    if (destination_size < required) return posixInetNtopFail(errno.Posix.enospc);
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(destination), required)) {
        return posixInetNtopFail(errno.Posix.efault);
    }
    @memcpy(destination[0..text.len], text);
    destination[text.len] = 0;
    return destination;
}

fn posixSelect(nfds: i32, read_set: u64, write_set: u64, error_set: u64, timeout: ?*const anyopaque) callconv(abi.guest) i32 {
    _ = timeout;
    const bytes: usize = if (nfds <= 0) 0 else @min(@as(usize, @intCast(nfds + 7)) / 8, 128);
    if (!filesystem.virtualSocketReadable()) {
        _ = kernel_threading.sceKernelUsleep(1_000);
    }
    const readable = filesystem.virtualSocketReadable();
    const first_to_clear: usize = if (readable) 1 else 0;
    for (([_]u64{ read_set, write_set, error_set })[first_to_clear..]) |address| {
        if (address != 0 and bytes != 0 and kernel_memory.isGuestRangeAccessible(address, bytes)) {
            const output: [*]u8 = @ptrFromInt(address);
            @memset(output[0..bytes], 0);
        }
    }
    return if (readable) 1 else 0;
}

const posix_exports = [_]symbols.Export{
    .{ .name = "socket", .function = trace.wrap("socket", &posixSocket), .expect_id = "TU-d9PfIHPM" },
    .{ .name = "connect", .function = trace.wrap("connect", &posixSocketConnect), .expect_id = "XVL8So3QJUk" },
    .{ .name = "shutdown", .function = trace.wrap("shutdown", &posixSocketLocalState), .expect_id = "TUuiYS2kE8s" },
    .{ .name = "setsockopt", .function = trace.wrap("setsockopt", &posixSocketLocalState), .expect_id = "fFxGkxF2bVo" },
    .{ .name = "recv", .function = trace.wrap("recv", &posixSocketNeedsPeer), .expect_id = "Ez8xjo9UF4E" },
    .{ .name = "sendmsg", .function = trace.wrap("sendmsg", &posixMessageOperation), .expect_id = "aNeavPDNKzA" },
    .{ .name = "recvmsg", .function = trace.wrap("recvmsg", &posixMessageOperation), .expect_id = "hI7oVeOluPM" },
    .{ .name = "inet_ntop", .function = trace.wrap("inet_ntop", &posixInetNtop), .expect_id = "5jRCs2axtr4" },
    .{ .name = "select", .function = trace.wrap("select", &posixSelect), .expect_id = "T8fER+tIGgk" },
    .{ .name = "libScePosix:w5IHyvahg-o", .function = trace.wrap("libScePosix:w5IHyvahg-o", &success), .id_override = "w5IHyvahg-o" },
};

// Deterministic random data ------------------------------------------------

var random_state = std.atomic.Value(u64).init(0x9e37_79b9_7f4a_7c15);

fn randomGetRandomNumber(buffer: ?[*]u8, size: usize) callconv(abi.guest) i32 {
    const output = buffer orelse return invalid_argument;
    var state = random_state.load(.monotonic);
    for (output[0..size]) |*byte| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = @truncate(state);
    }
    random_state.store(state, .monotonic);
    return errno.ok;
}

const random_exports = [_]symbols.Export{
    .{ .name = "sceRandomGetRandomNumber", .function = trace.wrap("sceRandomGetRandomNumber", &randomGetRandomNumber), .expect_id = "PI7jIZj4pcE" },
};

// VideoOut ---------------------------------------------------------------

const video_out_error_invalid_value: i32 = @bitCast(@as(u32, 0x8029_0001));
const video_out_error_invalid_address: i32 = @bitCast(@as(u32, 0x8029_0002));
const video_out_error_invalid_index: i32 = @bitCast(@as(u32, 0x8029_000a));
const video_out_error_invalid_handle: i32 = @bitCast(@as(u32, 0x8029_000b));
const video_out_error_invalid_event_queue: i32 = @bitCast(@as(u32, 0x8029_000c));
const video_out_error_slot_occupied: i32 = @bitCast(@as(u32, 0x8029_0010));
const video_out_error_invalid_option: i32 = @bitCast(@as(u32, 0x8029_001a));
const video_out_error_invalid_category: i32 = @bitCast(@as(u32, 0x8029_001d));

pub const VideoOutBufferAttribute2 = video_out.BufferAttribute2;
pub const VideoOutBuffer = video_out.Buffer;

const VideoOutFlipStatus = extern struct {
    count: u64 = 0,
    process_time: u64 = 0,
    reserved0: u64 = 0,
    flip_argument: i64 = 0,
    reserved1: u64 = 0,
    process_time_counter: u64 = 0,
    gc_queue_count: i32 = 0,
    flip_pending_count: i32 = 0,
    current_buffer: i32 = -1,
    reserved2: u32 = 0,
    submit_process_time_counter: u64 = 0,
    reserved3: [7]u64 = [_]u64{0} ** 7,
};

const VideoOutOutputStatus = extern struct {
    resolution: u32 = 1,
    dynamic_range: u32 = 1,
    refresh_rate: u64 = 60_000,
    flags: u64 = 0,
    reserved: [3]u64 = .{ 0, 0, 0 },
};

fn validVideoHandle(handle: i32) bool {
    return video_out.validHandle(handle);
}

/// Host-side ~60 Hz refresh so WaitEqueue(vblank) keeps waking between flips.
var vblank_ticker_started: std.atomic.Value(bool) = .init(false);

fn hostSleepMilliseconds(ms: u32) void {
    if (comptime builtin.os.tag != .windows) return;
    // Negative 100-ns units = relative delay (not wall-clock sensitive).
    var interval: i64 = -@as(i64, @intCast(ms)) * 10_000;
    _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
}

fn vblankTickerMain() void {
    while (!kernel_runtime.guestStopRequested()) {
        // Host sleep: this thread is not a guest pthread, so sceKernelUsleep
        // would return ENOSYS and spin.
        hostSleepMilliseconds(16);
        if (!video_out.validHandle(video_out.primary_handle)) continue;
        _ = video_out.advanceVblank(
            kernel_runtime.processTimeMicroseconds(),
            kernel_runtime.processTimeCounter(),
        );
        // Only the real vblank edge. Re-firing flip/graphics every tick flooded
        // WaitEqueue (~60 Hz spam) and kept the GPU worker busy without new
        // ring content — frame 2 never got encoded past ACQUIRE_MEM kicks.
        _ = kernel_event_queue.triggerVideoOutVblank();
        // Producer may finish filling a short-kicked ring IB between submits;
        // re-scan remembered tails each refresh so multi-draw DCBs land.
        kernel_ioctl.drainPendingTailsPublic();
        // A batch's last AGC submission has no following Submit* call to drain
        // its deferred completion. Publish it from this independent host tick
        // after the short post-submit ring-bookkeeping grace period.
        agc_submit.pumpCompletionNotifications();
    }
}

fn ensureVblankTicker() void {
    if (vblank_ticker_started.swap(true, .monotonic)) return;
    const thread = std.Thread.spawn(.{}, vblankTickerMain, .{}) catch {
        vblank_ticker_started.store(false, .monotonic);
        return;
    };
    thread.detach();
}

fn videoOutOpen(_: i32, _: i32, index: i32, _: ?*const anyopaque) callconv(abi.guest) i32 {
    if (!video_out.open(index)) return video_out_error_invalid_handle;
    video_out.noteOpenProcessTime(kernel_runtime.processTimeMicroseconds());
    ensureVblankTicker();
    return video_out.primary_handle;
}

fn videoOutSetBufferAttribute2(
    attribute: ?*VideoOutBufferAttribute2,
    pixel_format: u64,
    tiling_mode: u32,
    width: u32,
    height: u32,
    option: u64,
    dcc_control: u32,
    dcc_clear_color: u64,
) callconv(abi.guest) void {
    const output = attribute orelse return;
    output.* = .{
        .tiling_mode = tiling_mode,
        .aspect_ratio = 1,
        .width = width,
        .height = height,
        .pitch_in_pixels = width,
        .option = option,
        .pixel_format = pixel_format,
        .dcc_clear_color = dcc_clear_color,
        .dcc_control = dcc_control,
    };
}

fn videoHandleOption(handle: i32, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) errno.ok else video_out_error_invalid_handle;
}

fn videoOutClose(handle: i32) callconv(abi.guest) i32 {
    return if (video_out.close(handle)) errno.ok else video_out_error_invalid_handle;
}

fn videoOutError(err: video_out.RegisterError) i32 {
    return switch (err) {
        error.InvalidValue => video_out_error_invalid_value,
        error.InvalidAddress => video_out_error_invalid_address,
        error.InvalidOption => video_out_error_invalid_option,
        error.InvalidCategory => video_out_error_invalid_category,
        error.InvalidIndex => video_out_error_invalid_index,
        error.SlotOccupied => video_out_error_slot_occupied,
    };
}

fn videoOutRegisterBuffers2(
    handle: i32,
    set_index: i32,
    buffer_index_start: i32,
    buffer_pointer: ?[*]const VideoOutBuffer,
    count: i32,
    attribute: ?*const VideoOutBufferAttribute2,
    category: i32,
    option: ?*anyopaque,
) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const input = buffer_pointer orelse return video_out_error_invalid_address;
    const attributes = attribute orelse return video_out_error_invalid_option;
    if (count <= 0) return video_out_error_invalid_value;
    if (option != null) return video_out_error_invalid_option;
    if (trace.announces("sceVideoOutRegisterBuffers2")) {
        std.debug.print(
            "[video out] register set={d} first={d} count={d} category={d} " ++
                "format=0x{x} tile={d} size={d}x{d} pitch={d} option=0x{x}\n",
            .{
                set_index,
                buffer_index_start,
                count,
                category,
                attributes.pixel_format,
                attributes.tiling_mode,
                attributes.width,
                attributes.height,
                attributes.pitch_in_pixels,
                attributes.option,
            },
        );
    }
    video_out.registerBuffers(
        set_index,
        buffer_index_start,
        input[0..@intCast(count)],
        attributes.*,
        category,
    ) catch |err| return videoOutError(err);
    return errno.ok;
}

fn videoOutUnregisterBuffers(handle: i32, set_index: i32) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    video_out.unregisterBuffers(set_index) catch |err| return videoOutError(err);
    return errno.ok;
}

fn videoOutSubmitChangeBufferAttribute2(
    handle: i32,
    set_index: i32,
    attribute: ?*const VideoOutBufferAttribute2,
    option: ?*anyopaque,
) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const value = attribute orelse return video_out_error_invalid_option;
    if (option != null) return video_out_error_invalid_option;
    video_out.changeAttribute(set_index, value.*) catch |err| return videoOutError(err);
    return errno.ok;
}

fn videoOutSubmitFlip(handle: i32, index: i32, mode: i32, argument: i64) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    if (index < -1 or (index >= 0 and video_out.resolve(@intCast(handle), index) == null)) {
        return video_out_error_invalid_index;
    }
    video_out.noteFlipSubmit(argument, kernel_runtime.processTimeCounter());
    _ = agc_submit.presentFlip(.{
        .video_out_handle = @intCast(handle),
        .display_buffer_index = index,
        .mode = @bitCast(mode),
        .argument = argument,
    });
    _ = kernel_threading.sceKernelUsleep(16_667);
    return errno.ok;
}

fn videoOutGetFlipStatus(handle: i32, status: ?*VideoOutFlipStatus) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const output = status orelse return video_out_error_invalid_address;
    const current = video_out.status(handle) orelse return video_out_error_invalid_handle;
    // Full PS5 layout: titles poll process-time fields after
    // WaitEqueue(filter=-13) and skip init paths when they look unset/stale.
    // Report the real pending count so the title does not race the next frame
    // encode against an incomplete flip (observed as ACQUIRE_MEM-only #50 kicks
    // after the first full DCB). completeFlip drains the counter.
    output.* = .{
        .count = current.count,
        .process_time = kernel_runtime.processTimeMicroseconds(),
        .reserved0 = 0,
        .flip_argument = current.flip_argument,
        .reserved1 = 0,
        .process_time_counter = kernel_runtime.processTimeCounter(),
        .gc_queue_count = 0,
        .flip_pending_count = current.flip_pending_count,
        .current_buffer = current.current_buffer,
        .reserved2 = 0,
        .submit_process_time_counter = current.submit_process_time_counter,
        .reserved3 = [_]u64{0} ** 7,
    };
    return errno.ok;
}

/// Decodes the flip/vblank payload from a VideoOut equeue event.
/// Event `data` stores `ident | (flip_arg << 16)`; titles read the arg via
/// this helper rather than raw sceKernelGetEventData.
fn videoOutGetEventData(event: ?*const kernel_event_queue.Event, out_data: ?*u64) callconv(abi.guest) i32 {
    const value = event orelse return video_out_error_invalid_address;
    const output = out_data orelse return video_out_error_invalid_address;
    if (value.filter != kernel_event_queue.video_out_filter) {
        return video_out_error_invalid_value;
    }
    if (value.ident != kernel_event_queue.video_out_flip_ident and
        value.ident != kernel_event_queue.video_out_vblank_ident)
    {
        return video_out_error_invalid_value;
    }
    // High 48 bits of data carry the flip argument.
    const packed_data: u64 = @bitCast(value.data);
    output.* = packed_data >> 16;
    return errno.ok;
}

fn videoOutGetOutputStatus(handle: i32, status: ?*VideoOutOutputStatus) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const output = status orelse return video_out_error_invalid_address;
    output.* = .{};
    return errno.ok;
}

fn videoOutIsOutputSupported(handle: i32, _: u64, _: ?*const anyopaque, _: ?*anyopaque, _: u64) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) 1 else video_out_error_invalid_handle;
}

fn videoOutGetEventId(event: ?*const @import("kernel_event_queue.zig").Event) callconv(abi.guest) i32 {
    const value = event orelse return 0;
    if (value.filter != kernel_event_queue.video_out_filter) return 0;
    // 0 = flip, 1 = vblank (console convention).
    if (value.ident == kernel_event_queue.video_out_flip_ident) return 0;
    if (value.ident == kernel_event_queue.video_out_vblank_ident) return 1;
    return @bitCast(@as(u32, @truncate(value.ident)));
}

const VideoOutVblankStatus = extern struct {
    count: u64 = 0,
    process_time: u64 = 0,
    reserved: u64 = 0,
    process_time_counter: u64 = 0,
    flags: u8 = 0,
    phase: u8 = 0,
    pad: [6]u8 = @splat(0),
};

fn videoOutAddVblankEvent(equeue: i64, handle: i32, user_data: u64) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    return if (kernel_event_queue.addVideoOutVblankEvent(equeue, user_data) == errno.ok)
        errno.ok
    else
        video_out_error_invalid_event_queue;
}

fn videoOutDeleteVblankEvent(equeue: i64, handle: i32) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    return if (kernel_event_queue.deleteVideoOutVblankEvent(equeue) == errno.ok)
        errno.ok
    else
        video_out_error_invalid_event_queue;
}

fn videoOutWaitVblank(handle: i32) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    // Pace to ~60 Hz so titles that spin on vblank do not burn a core.
    _ = kernel_threading.sceKernelUsleep(16_667);
    _ = video_out.advanceVblank(
        kernel_runtime.processTimeMicroseconds(),
        kernel_runtime.processTimeCounter(),
    );
    _ = kernel_event_queue.triggerVideoOutVblank();
    return errno.ok;
}

fn videoOutGetVblankStatus(handle: i32, status: ?*VideoOutVblankStatus) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    const output = status orelse return video_out_error_invalid_address;
    const current = video_out.vblankStatus(
        handle,
        kernel_runtime.processTimeMicroseconds(),
        kernel_runtime.processTimeCounter(),
    ) orelse return video_out_error_invalid_handle;
    output.* = .{
        .count = current.count,
        .process_time = current.process_time,
        .reserved = 0,
        .process_time_counter = current.process_time_counter,
        .flags = current.flags,
        .phase = current.phase,
        .pad = @splat(0),
    };
    return errno.ok;
}

fn videoOutAddFlipEvent(equeue: i64, handle: i32, user_data: u64) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    return if (kernel_event_queue.addVideoOutFlipEvent(equeue, user_data) == errno.ok)
        errno.ok
    else
        video_out_error_invalid_event_queue;
}

fn videoOutDeleteFlipEvent(equeue: i64, handle: i32) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    return if (kernel_event_queue.deleteVideoOutFlipEvent(equeue) == errno.ok)
        errno.ok
    else
        video_out_error_invalid_event_queue;
}

fn videoOutIsFlipPending(handle: i32) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) 0 else video_out_error_invalid_handle;
}

/// A flip submitted to complete when the GPU finishes the frame.
///
/// The live backend drains prior queue work before presenting it. Unlike the
/// ordinary CPU flip, this entry point does not add display pacing because its
/// caller expects GPU end-of-pipe ordering to provide that boundary.
fn videoOutSubmitEopFlip(
    handle: i32,
    index: i32,
    mode: u32,
    argument: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (!validVideoHandle(handle)) return video_out_error_invalid_handle;
    if (video_out.resolve(@intCast(handle), index) == null) return video_out_error_invalid_index;

    // Reported rather than discarded. A flip that is not accepted publishes no
    // completion, and a title that was told the flip was accepted waits for
    // that completion for as long as it runs — with nothing anywhere saying
    // which call was the one that did not happen. Answering truthfully turns a
    // silent stall into a failure at the call responsible for it.
    const flip_arg: i64 = @bitCast(argument);
    video_out.noteFlipSubmit(flip_arg, kernel_runtime.processTimeCounter());
    if (!agc_submit.presentFlip(.{
        .video_out_handle = @intCast(handle),
        .display_buffer_index = index,
        .mode = mode,
        .argument = flip_arg,
    })) {
        return video_out_error_invalid_index;
    }
    return errno.ok;
}

/// Which display bus the output is attached to. There is only one.
fn videoOutSysGetBus(handle: i32) callconv(abi.guest) i32 {
    return if (validVideoHandle(handle)) 0 else video_out_error_invalid_handle;
}

/// Returns the base of 16 contiguous 64-bit flip-completion labels.
fn videoOutGetBufferLabelAddress(handle: i32, output_address: u64) callconv(abi.guest) i32 {
    if (output_address == 0 or !kernel_memory.isGuestRangeAccessible(output_address, @sizeOf(u64))) {
        return video_out_error_invalid_address;
    }
    const label_address = video_out.labelAddress(handle) orelse return video_out_error_invalid_handle;
    const output: *[8]u8 = @ptrFromInt(output_address);
    std.mem.writeInt(u64, output, label_address, .little);
    return video_out.maximum_buffers;
}

/// How far the display pipeline has progressed.
///
/// Refused: the answer is a record whose layout is not established here, and
/// writing a guessed one into the caller's buffer would corrupt whatever it
/// keeps alongside.
fn videoOutGetPipelineStatus(_: i32, _: u64) callconv(abi.guest) i32 {
    return video_out_error_invalid_address;
}

const video_out_exports = [_]symbols.Export{
    .{ .name = "sceVideoOutOpen", .function = trace.wrap("sceVideoOutOpen", &videoOutOpen), .expect_id = "Up36PTk687E" },
    .{ .name = "sceVideoOutClose", .function = trace.wrap("sceVideoOutClose", &videoOutClose), .expect_id = "uquVH4-Du78" },
    .{ .name = "sceVideoOutSetBufferAttribute2", .function = trace.wrap("sceVideoOutSetBufferAttribute2", &videoOutSetBufferAttribute2), .expect_id = "PjS5uASwcV8" },
    .{ .name = "sceVideoOutRegisterBuffers2", .function = trace.wrap("sceVideoOutRegisterBuffers2", &videoOutRegisterBuffers2), .expect_id = "rKBUtgRrtbk" },
    .{ .name = "sceVideoOutUnregisterBuffers", .function = trace.wrap("sceVideoOutUnregisterBuffers", &videoOutUnregisterBuffers), .expect_id = "N5KDtkIjjJ4" },
    .{ .name = "sceVideoOutSubmitChangeBufferAttribute2", .function = trace.wrap("sceVideoOutSubmitChangeBufferAttribute2", &videoOutSubmitChangeBufferAttribute2), .expect_id = "HuViW4HnrOw" },
    .{ .name = "sceVideoOutSubmitFlip", .function = trace.wrap("sceVideoOutSubmitFlip", &videoOutSubmitFlip), .expect_id = "U46NwOiJpys" },
    .{ .name = "sceVideoOutGetFlipStatus", .function = trace.wrap("sceVideoOutGetFlipStatus", &videoOutGetFlipStatus), .expect_id = "SbU3dwp80lQ" },
    .{ .name = "sceVideoOutIsFlipPending", .function = trace.wrap("sceVideoOutIsFlipPending", &videoOutIsFlipPending), .expect_id = "zgXifHT9ErY" },
    .{ .name = "sceVideoOutSetFlipRate", .function = trace.wrap("sceVideoOutSetFlipRate", &videoHandleOption), .expect_id = "CBiu4mCE1DA" },
    .{ .name = "sceVideoOutAddFlipEvent", .function = trace.wrap("sceVideoOutAddFlipEvent", &videoOutAddFlipEvent), .expect_id = "HXzjK9yI30k" },
    .{ .name = "sceVideoOutDeleteFlipEvent", .function = trace.wrap("sceVideoOutDeleteFlipEvent", &videoOutDeleteFlipEvent), .expect_id = "-Ozn0F1AFRg" },
    .{ .name = "sceVideoOutAddVblankEvent", .function = trace.wrap("sceVideoOutAddVblankEvent", &videoOutAddVblankEvent), .expect_id = "Xru92wHJRmg" },
    .{ .name = "sceVideoOutDeleteVblankEvent", .function = trace.wrap("sceVideoOutDeleteVblankEvent", &videoOutDeleteVblankEvent), .expect_id = "oNOQn3knW6s" },
    .{ .name = "sceVideoOutWaitVblank", .function = trace.wrap("sceVideoOutWaitVblank", &videoOutWaitVblank), .expect_id = "j6RaAUlaLv0" },
    .{ .name = "sceVideoOutGetVblankStatus", .function = trace.wrap("sceVideoOutGetVblankStatus", &videoOutGetVblankStatus), .expect_id = "1FZBKy8HeNU" },
    .{ .name = "sceVideoOutGetEventId", .function = trace.wrap("sceVideoOutGetEventId", &videoOutGetEventId), .expect_id = "U2JJtSqNKZI" },
    .{ .name = "sceVideoOutGetEventData", .function = trace.wrap("sceVideoOutGetEventData", &videoOutGetEventData), .expect_id = "rWUTcKdkUzQ" },
    .{ .name = "sceVideoOutGetOutputStatus", .function = trace.wrap("sceVideoOutGetOutputStatus", &videoOutGetOutputStatus), .expect_id = "utPrVdxio-8" },
    .{ .name = "sceVideoOutIsOutputSupported", .function = trace.wrap("sceVideoOutIsOutputSupported", &videoOutIsOutputSupported), .expect_id = "Nv8c-Kb+DUM" },
    .{ .name = "sceVideoOutConfigureOutput", .function = trace.wrap("sceVideoOutConfigureOutput", &videoHandleOption), .expect_id = "w0hLuNarQxY" },
    .{ .name = "sceVideoOutSetWindowModeMargins", .function = trace.wrap("sceVideoOutSetWindowModeMargins", &videoHandleOption), .expect_id = "MTxxrOCeSig" },
    .{ .name = "sceVideoOutVrrPegToFixedRate", .function = trace.wrap("sceVideoOutVrrPegToFixedRate", &videoHandleOption), .expect_id = "5tRaBjtdTzY" },
    .{ .name = "sceVideoOutVrrUnpegFromFixedRate", .function = trace.wrap("sceVideoOutVrrUnpegFromFixedRate", &videoHandleOption), .expect_id = "T4ucGB8CsnM" },
    .{ .name = "sceVideoOutSubmitEopFlip", .function = trace.wrap("sceVideoOutSubmitEopFlip", &videoOutSubmitEopFlip), .expect_id = "j8xl+92A0q4" },
    .{ .name = "sceVideoOutSysGetBus", .function = trace.wrap("sceVideoOutSysGetBus", &videoOutSysGetBus), .expect_id = "7VSZJxxcTL8" },
    .{ .name = "sceVideoOutSysAddSetModeEvent2", .function = trace.wrap("sceVideoOutSysAddSetModeEvent2", &videoHandleOption), .expect_id = "fYWVVDKZOCk" },
    .{ .name = "sceVideoOutGetBufferLabelAddress", .function = trace.wrap("sceVideoOutGetBufferLabelAddress", &videoOutGetBufferLabelAddress), .expect_id = "OcQybQejHEY" },
    .{ .name = "sceVideoOutGetPipelineStatus", .function = trace.wrap("sceVideoOutGetPipelineStatus", &videoOutGetPipelineStatus), .expect_id = "Ygv0S+Hi+hA" },
};

// Offline platform peripherals and account services -----------------------

fn outputZero32(_: i32, output: ?*u32) callconv(abi.guest) i32 {
    if (output) |value| value.* = 0;
    return errno.ok;
}

fn outputZero64(_: i32, output: ?*u64) callconv(abi.guest) i32 {
    if (output) |value| value.* = 0;
    return errno.ok;
}

fn availableSpace(_: u32, output: ?*u64) callconv(abi.guest) i32 {
    const value = output orelse return invalid_argument;
    value.* = 1024 * 1024;
    return errno.ok;
}

fn mouseOpen(_: i32, _: i32, _: i32, _: ?*const anyopaque) callconv(abi.guest) i32 {
    return @bitCast(@as(u32, 0x8024_0001));
}

fn mouseRead(_: i32, _: ?*anyopaque, _: i32) callconv(abi.guest) i32 {
    return 0;
}

const SaveDataMountResult = extern struct {
    mount_point: [16]u8,
    required_blocks: u64,
    unused: u32,
    mount_status: u32,
    reserved: [28]u8,
    padding: i32,
};

var next_save_data_resource = std.atomic.Value(u32).init(1);

fn saveDataCreateTransactionResource(_: u32) callconv(abi.guest) i32 {
    const resource = next_save_data_resource.fetchAdd(1, .monotonic);
    return @intCast(if (resource == 0) 1 else resource);
}

/// The request a title hands to `sceSaveDataMount3`.
///
/// Only the fields the mount actually turns into a decision are named: which
/// slot, and whether the title is willing to have it created. The block counts
/// describe a quota this host does not impose.
const SaveDataMountRequest = extern struct {
    user_id: i32,
    reserved: u32,
    directory_name: u64,
    blocks: u64,
    system_blocks: u64,
    mount_mode: u32,
    resource: u32,
    mode: u32,
    padding: u32,
};

/// Mount-mode bits that say the title accepts a slot being made for it.
///
/// A title probing for an existing save mounts read-only and expects to be told
/// it is not there; answering that probe by creating an empty slot would make
/// it load a save that never existed.
const save_data_mount_create_bits: u32 = 0x04 | 0x20;

const save_data_error_not_found: i32 = @bitCast(@as(u32, 0x809f0008));

fn saveDataMount3(request_address: u64, result: ?*SaveDataMountResult) callconv(abi.guest) i32 {
    const output = result orelse return invalid_argument;
    if (!kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(SaveDataMountResult))) {
        return errno.KernelError.efault.raw();
    }
    if (request_address == 0 or
        !kernel_memory.isGuestRangeAccessible(request_address, @sizeOf(SaveDataMountRequest)))
    {
        return invalid_argument;
    }
    const request: *const SaveDataMountRequest = @ptrFromInt(request_address);

    var slot_storage: [savedata.maximum_slot_name]u8 = undefined;
    const slot = readSlotName(request.directory_name, &slot_storage) orelse return invalid_argument;
    const may_create = request.mount_mode & save_data_mount_create_bits != 0;

    const outcome = filesystem.mountSaveDataSlot(slot, may_create) catch {
        return errno.KernelError.eio.raw();
    };
    if (outcome == .missing) return save_data_error_not_found;

    output.* = .{
        .mount_point = [_]u8{0} ** 16,
        .required_blocks = 0,
        .unused = 0,
        // A title reads this to learn whether it is looking at a save it wrote
        // before or at an empty one just made for it. Always claiming the
        // latter made a game overwrite its own profile on every run instead of
        // loading it.
        .mount_status = if (outcome == .created) 1 else 0,
        .reserved = [_]u8{0} ** 28,
        .padding = 0,
    };
    @memcpy(output.mount_point[0.."/savedata0".len], "/savedata0");
    return errno.ok;
}

/// Copies the fixed-width slot name out of guest memory.
fn readSlotName(address: u64, storage: *[savedata.maximum_slot_name]u8) ?[]const u8 {
    if (address == 0 or !kernel_memory.isGuestRangeAccessible(address, storage.len)) return null;
    const bytes: [*]const u8 = @ptrFromInt(address);
    @memcpy(storage, bytes[0..storage.len]);
    return savedata.boundedName(storage);
}

fn saveDataTwoPointers(first: u64, second: u64) callconv(abi.guest) i32 {
    return if (first == 0 or second == 0) invalid_argument else errno.ok;
}

fn saveDataOnePointer(pointer: u64) callconv(abi.guest) i32 {
    return if (pointer == 0) invalid_argument else errno.ok;
}

fn saveDataUmount(_: u32, mount_point: u64) callconv(abi.guest) i32 {
    if (mount_point == 0) return invalid_argument;
    // Everything written through the mount is already on disk; detaching only
    // stops the path resolving, which is what makes a later mount of another
    // slot land in the right place.
    filesystem.unmountSaveData();
    return errno.ok;
}

/// The block-shaped save API.
///
/// It is the other half of saved games: instead of writing files through a
/// mount, a title hands over one buffer and expects the same bytes back on a
/// later run. There is no slot to name, so the blob belongs to the title as a
/// whole and is kept beside its slots rather than inside one.
const SaveDataMemoryData = extern struct {
    buffer: u64,
    size: u64,
    offset: u64,
};

/// The largest blob that will be held. A title asking for more than this has
/// not understood the API, and reserving it would be a denial of service
/// against the host rather than a save.
const maximum_save_data_memory = 32 * 1024 * 1024;

var save_data_memory: ?[]u8 = null;
/// A spin lock rather than a general mutex: the critical sections are a memcpy
/// of a save blob, and this module has no `std.Io` instance to hand.
var save_data_memory_lock: std.atomic.Mutex = .unlocked;

fn lockSaveDataMemory() void {
    while (!save_data_memory_lock.tryLock()) std.atomic.spinLoopHint();
}

/// Reads the descriptor a title passes for a memory transfer.
fn readMemoryData(address: u64) ?SaveDataMemoryData {
    if (address == 0 or !kernel_memory.isGuestRangeAccessible(address, @sizeOf(SaveDataMemoryData))) {
        return null;
    }
    const data: *const SaveDataMemoryData = @ptrFromInt(address);
    return data.*;
}

/// Prepares the blob and loads whatever a previous run left in it.
fn saveDataSetupMemory(parameter_address: u64, _: u64) callconv(abi.guest) i32 {
    if (parameter_address == 0 or !kernel_memory.isGuestRangeAccessible(parameter_address, 0x10)) {
        return invalid_argument;
    }
    const requested: u64 = @as(*const u64, @ptrFromInt(parameter_address + 0x08)).*;
    if (requested == 0 or requested > maximum_save_data_memory) return invalid_argument;
    const size: usize = @intCast(requested);

    lockSaveDataMemory();
    defer save_data_memory_lock.unlock();
    if (save_data_memory) |existing| {
        if (existing.len == size) return errno.ok;
        std.heap.page_allocator.free(existing);
        save_data_memory = null;
    }
    const buffer = std.heap.page_allocator.alloc(u8, size) catch return errno.KernelError.enomem.raw();
    @memset(buffer, 0);
    // A title expects the blob it stored last time, so the reserve is filled
    // from disk before it is handed back rather than starting empty.
    filesystem.readSaveDataMemory(buffer);
    save_data_memory = buffer;
    return errno.ok;
}

/// Copies out of the blob into the title's buffer.
fn saveDataGetMemory(request_address: u64) callconv(abi.guest) i32 {
    return transferSaveDataMemory(request_address, false);
}

/// Copies the title's buffer into the blob.
fn saveDataSetMemory(request_address: u64) callconv(abi.guest) i32 {
    return transferSaveDataMemory(request_address, true);
}

fn transferSaveDataMemory(request_address: u64, storing: bool) i32 {
    if (request_address == 0 or !kernel_memory.isGuestRangeAccessible(request_address, 0x10)) {
        return invalid_argument;
    }
    const data_address: u64 = @as(*const u64, @ptrFromInt(request_address + 0x08)).*;
    const data = readMemoryData(data_address) orelse return invalid_argument;
    if (data.buffer == 0 or data.size == 0) return invalid_argument;
    if (!kernel_memory.isGuestRangeAccessible(data.buffer, @intCast(data.size))) {
        return errno.KernelError.efault.raw();
    }

    lockSaveDataMemory();
    defer save_data_memory_lock.unlock();
    const blob = save_data_memory orelse return invalid_argument;
    // A transfer past the end of the reserve is refused rather than clamped: a
    // short read would hand the title a partly stale save and look like one it
    // had written.
    if (data.offset > blob.len or data.size > blob.len - data.offset) return invalid_argument;

    const start: usize = @intCast(data.offset);
    const length: usize = @intCast(data.size);
    const guest: [*]u8 = @ptrFromInt(data.buffer);
    if (storing) {
        @memcpy(blob[start..][0..length], guest[0..length]);
    } else {
        @memcpy(guest[0..length], blob[start..][0..length]);
    }
    return errno.ok;
}

/// Puts the blob on disk. A title calls this when it wants the save to survive
/// the process, so nothing is written until it does.
fn saveDataSyncMemory(_: u64) callconv(abi.guest) i32 {
    lockSaveDataMemory();
    defer save_data_memory_lock.unlock();
    const blob = save_data_memory orelse return errno.ok;
    filesystem.writeSaveDataMemory(blob) catch return errno.KernelError.eio.raw();
    return errno.ok;
}

/// The answer `sceSaveDataDirNameSearch` fills in.
///
/// The caller supplies the array the names go into and says how long it is; the
/// reply says how many slots exist and how many of them fitted.
const SaveDataDirNameSearchResult = extern struct {
    hit_count: u32,
    reserved: u32,
    names: u64,
    name_capacity: u32,
    set_count: u32,
};

/// Lists the slots the running title has written.
///
/// A title does not know which of its saves exist; asking is how it finds out.
/// Refusing the question made a title with a save already on disk behave as
/// though it had never written one.
fn saveDataDirNameSearch(_: u64, result_address: u64) callconv(abi.guest) i32 {
    if (result_address == 0 or
        !kernel_memory.isGuestRangeAccessible(result_address, @sizeOf(SaveDataDirNameSearchResult)))
    {
        return invalid_argument;
    }
    const result: *SaveDataDirNameSearchResult = @ptrFromInt(result_address);

    var names: [maximum_listed_slots][savedata.maximum_slot_name]u8 = undefined;
    const found = filesystem.listSaveDataSlots(&names);
    result.hit_count = @intCast(found);

    // A caller may ask only how many there are, passing no array for them.
    if (result.names == 0 or result.name_capacity == 0) {
        result.set_count = 0;
        return errno.ok;
    }
    const capacity = @min(@as(usize, result.name_capacity), found);
    const bytes = capacity * savedata.maximum_slot_name;
    if (bytes != 0 and !kernel_memory.isGuestRangeAccessible(result.names, bytes)) {
        return errno.KernelError.efault.raw();
    }
    const destination: [*]u8 = @ptrFromInt(result.names);
    for (0..capacity) |index| {
        @memcpy(destination[index * savedata.maximum_slot_name ..][0..savedata.maximum_slot_name], &names[index]);
    }
    result.set_count = @intCast(capacity);
    return errno.ok;
}

/// How many slots one search will report. A title with more saves than this has
/// written more than a single query is expected to carry.
const maximum_listed_slots = 64;

/// The descriptive parameters of a slot, in the order the API numbers them.
const save_data_param_title: u32 = 0;
const save_data_param_subtitle: u32 = 1;
const save_data_param_detail: u32 = 2;
const save_data_param_user: u32 = 3;

/// Reads one descriptive parameter of a mounted slot.
fn saveDataGetParam(
    _: u64,
    parameter: u32,
    value_address: u64,
    size: u64,
    written_address: u64,
) callconv(abi.guest) i32 {
    if (value_address == 0 or size == 0) return invalid_argument;
    if (!kernel_memory.isGuestRangeAccessible(value_address, @intCast(size))) {
        return errno.KernelError.efault.raw();
    }

    var storage: [1024]u8 = undefined;
    const text = filesystem.readSaveDataParameters(filesystem.mountedSaveDataSlot(), &storage) orelse "";
    const decoded = savedata.decodeParameters(text);
    const value = switch (parameter) {
        save_data_param_title => decoded.title,
        save_data_param_subtitle => decoded.subtitle,
        save_data_param_detail => decoded.detail,
        save_data_param_user => {
            if (size < @sizeOf(u32)) return invalid_argument;
            @as(*u32, @ptrFromInt(value_address)).* = decoded.user_parameter;
            reportParameterLength(written_address, @sizeOf(u32));
            return errno.ok;
        },
        else => return invalid_argument,
    };

    const destination: [*]u8 = @ptrFromInt(value_address);
    const length = @min(value.len, @as(usize, @intCast(size)) - 1);
    @memcpy(destination[0..length], value[0..length]);
    destination[length] = 0;
    reportParameterLength(written_address, length);
    return errno.ok;
}

fn reportParameterLength(address: u64, length: usize) void {
    if (address == 0 or !kernel_memory.isGuestRangeAccessible(address, @sizeOf(u64))) return;
    @as(*u64, @ptrFromInt(address)).* = length;
}

/// Records the descriptive parameters a title attaches to the mounted slot.
fn saveDataSetParam(
    _: u64,
    parameter: u32,
    value_address: u64,
    size: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (value_address == 0 or size == 0) return invalid_argument;
    if (!kernel_memory.isGuestRangeAccessible(value_address, @intCast(size))) {
        return errno.KernelError.efault.raw();
    }
    const slot = filesystem.mountedSaveDataSlot();
    if (slot.len == 0) return invalid_argument;

    var storage: [1024]u8 = undefined;
    const existing = filesystem.readSaveDataParameters(slot, &storage) orelse "";
    var decoded = savedata.decodeParameters(existing);
    // The decoded values point into `storage`, which the encode below reuses;
    // copy the ones that are being kept before that happens.
    var kept: [768]u8 = undefined;
    var kept_length: usize = 0;
    const title = retainValue(&kept, &kept_length, decoded.title);
    const subtitle = retainValue(&kept, &kept_length, decoded.subtitle);
    const detail = retainValue(&kept, &kept_length, decoded.detail);
    decoded = .{
        .title = title,
        .subtitle = subtitle,
        .detail = detail,
        .user_parameter = decoded.user_parameter,
    };

    const source: [*]const u8 = @ptrFromInt(value_address);
    switch (parameter) {
        save_data_param_title => decoded.title = savedata.boundedName(source[0..@intCast(size)]),
        save_data_param_subtitle => decoded.subtitle = savedata.boundedName(source[0..@intCast(size)]),
        save_data_param_detail => decoded.detail = savedata.boundedName(source[0..@intCast(size)]),
        save_data_param_user => {
            if (size < @sizeOf(u32)) return invalid_argument;
            decoded.user_parameter = @as(*const u32, @ptrFromInt(value_address)).*;
        },
        else => return invalid_argument,
    }

    var encoded_storage: [1024]u8 = undefined;
    const encoded = savedata.encodeParameters(&encoded_storage, decoded) orelse return invalid_argument;
    filesystem.writeSaveDataParameters(slot, encoded) catch return errno.KernelError.eio.raw();
    return errno.ok;
}

/// Copies a value out of a buffer that is about to be reused.
fn retainValue(storage: []u8, length: *usize, value: []const u8) []const u8 {
    if (value.len == 0 or length.* + value.len > storage.len) return "";
    const start = length.*;
    @memcpy(storage[start..][0..value.len], value);
    length.* += value.len;
    return storage[start..][0..value.len];
}

const app_content_exports = [_]symbols.Export{
    .{ .name = "sceAppContentAddcontMount", .function = trace.wrap("sceAppContentAddcontMount", &success), .expect_id = "VANhIWcqYak" },
    .{ .name = "sceAppContentAddcontUnmount", .function = trace.wrap("sceAppContentAddcontUnmount", &success), .expect_id = "3rHWaV-1KC4" },
    .{ .name = "sceAppContentTemporaryDataFormat", .function = trace.wrap("sceAppContentTemporaryDataFormat", &success), .expect_id = "a5N7lAG0y2Q" },
    .{ .name = "sceAppContentTemporaryDataUnmount", .function = trace.wrap("sceAppContentTemporaryDataUnmount", &success), .expect_id = "bcolXMmp6qQ" },
    .{ .name = "sceAppContentTemporaryDataGetAvailableSpaceKb", .function = trace.wrap("sceAppContentTemporaryDataGetAvailableSpaceKb", &availableSpace), .expect_id = "SaKib2Ug0yI" },
    .{ .name = "sceAppContentDownloadDataGetAvailableSpaceKb", .function = trace.wrap("sceAppContentDownloadDataGetAvailableSpaceKb", &availableSpace), .expect_id = "Gl6w5i0JokY" },
    .{ .name = "sceAppContentAppParamGetInt", .function = trace.wrap("sceAppContentAppParamGetInt", &outputZero32), .expect_id = "99b82IKXpH4" },
};

const np_manager_exports = [_]symbols.Export{
    .{ .name = "sceNpGetAccountIdA", .function = trace.wrap("sceNpGetAccountIdA", &outputZero64), .expect_id = "rbknaUjpqWo" },
    .{ .name = "sceNpGetAccountCountryA", .function = trace.wrap("sceNpGetAccountCountryA", &outputZero32), .expect_id = "JT+t00a3TxA" },
    .{ .name = "sceNpGetState", .function = trace.wrap("sceNpGetState", &outputZero32), .expect_id = "eQH7nWPcAgc" },
    .{ .name = "sceNpGetNpReachabilityState", .function = trace.wrap("sceNpGetNpReachabilityState", &outputZero32), .expect_id = "e-ZuhGEoeC4" },
};

const remoteplay_exports = [_]symbols.Export{
    .{ .name = "sceRemoteplayInitialize", .function = trace.wrap("sceRemoteplayInitialize", &success), .expect_id = "k1SwgkMSOM8" },
    .{ .name = "sceRemoteplayGetConnectionStatus", .function = trace.wrap("sceRemoteplayGetConnectionStatus", &services.remoteplayGetConnectionStatus), .expect_id = "g3PNjYKWqnQ" },
    .{ .name = "sceRemoteplayTerminate", .function = trace.wrap("sceRemoteplayTerminate", &success), .expect_id = "BOwybKVa3Do" },
};

const mouse_exports = [_]symbols.Export{
    .{ .name = "sceMouseInit", .function = trace.wrap("sceMouseInit", &success), .expect_id = "Qs0wWulgl7U" },
    .{ .name = "sceMouseOpen", .function = trace.wrap("sceMouseOpen", &mouseOpen), .expect_id = "RaqxZIf6DvE" },
    .{ .name = "sceMouseRead", .function = trace.wrap("sceMouseRead", &mouseRead), .expect_id = "x8qnXqh-tiM" },
    .{ .name = "sceMouseClose", .function = trace.wrap("sceMouseClose", &success), .expect_id = "cAnT0Rw-IwU" },
};

// Mounting resolves a slot under the host save directory and makes it the
// title's `/savedata0`; its files are then written through the ordinary file
// API, which is how a title stores its progress.
const save_data_exports = [_]symbols.Export{
    .{ .name = "sceSaveDataInitialize3", .function = trace.wrap("sceSaveDataInitialize3", &success), .expect_id = "TywrFKCoLGY" },
    .{ .name = "sceSaveDataSetupSaveDataMemory2", .function = trace.wrap("sceSaveDataSetupSaveDataMemory2", &saveDataSetupMemory), .expect_id = "oQySEUfgXRA" },
    .{ .name = "sceSaveDataGetSaveDataMemory2", .function = trace.wrap("sceSaveDataGetSaveDataMemory2", &saveDataGetMemory), .expect_id = "QwOO7vegnV8" },
    .{ .name = "sceSaveDataSetSaveDataMemory2", .function = trace.wrap("sceSaveDataSetSaveDataMemory2", &saveDataSetMemory), .expect_id = "cduy9v4YmT4" },
    .{ .name = "sceSaveDataSyncSaveDataMemory", .function = trace.wrap("sceSaveDataSyncSaveDataMemory", &saveDataSyncMemory), .expect_id = "wiT9jeC7xPw" },
    .{ .name = "sceSaveDataCreateTransactionResource", .function = trace.wrap("sceSaveDataCreateTransactionResource", &saveDataCreateTransactionResource), .expect_id = "gjRZNnw0JPE" },
    .{ .name = "sceSaveDataDeleteTransactionResource", .function = trace.wrap("sceSaveDataDeleteTransactionResource", &success), .expect_id = "lJUQuaKqoKY" },
    .{ .name = "sceSaveDataMount3", .function = trace.wrap("sceSaveDataMount3", &saveDataMount3), .expect_id = "ZP4e7rlzOUk" },
    .{ .name = "sceSaveDataPrepare", .function = trace.wrap("sceSaveDataPrepare", &saveDataTwoPointers), .expect_id = "sDCBrmc61XU" },
    .{ .name = "sceSaveDataCommit", .function = trace.wrap("sceSaveDataCommit", &saveDataOnePointer), .expect_id = "ie7qhZ4X0Cc" },
    .{ .name = "sceSaveDataUmount2", .function = trace.wrap("sceSaveDataUmount2", &saveDataUmount), .expect_id = "uW4vfTwMQVo" },
    .{ .name = "sceSaveDataDirNameSearch", .function = trace.wrap("sceSaveDataDirNameSearch", &saveDataDirNameSearch), .expect_id = "dyIhnXq-0SM" },
    .{ .name = "sceSaveDataGetParam", .function = trace.wrap("sceSaveDataGetParam", &saveDataGetParam), .expect_id = "XgvSuIdnMlw" },
    .{ .name = "sceSaveDataSetParam", .function = trace.wrap("sceSaveDataSetParam", &saveDataSetParam), .expect_id = "85zul--eGXs" },
};

const sysmodule_bootstrap_exports = [_]symbols.Export{
    .{ .name = "sceSysmoduleUnloadModule", .function = trace.wrap("sceSysmoduleUnloadModule", &success), .expect_id = "eR2bZFAAU0Q" },
    .{ .name = "sceSysmoduleIsLoaded", .function = trace.wrap("sceSysmoduleIsLoaded", &success), .expect_id = "fMP5NHUOaMk" },
};

// AGC command construction ------------------------------------------------

const AgcCommandBuffer = extern struct {
    bottom: ?[*]u32,
    top: ?[*]u32,
    cursor_up: ?[*]u32,
    cursor_down: ?[*]u32,
    callback: ?*const anyopaque,
    user_data: ?*anyopaque,
    reserved_dwords: u32,
};

fn reserveAgcDwords(buffer: ?*AgcCommandBuffer, dword_count: usize) ?[*]u32 {
    if (dword_count == 0 or dword_count > std.math.maxInt(usize) / @sizeOf(u32)) return null;
    const state = buffer orelse return null;
    const cursor = state.cursor_up orelse state.bottom orelse return null;
    const top = state.top orelse return null;
    const cursor_address = @intFromPtr(cursor);
    const top_address = @intFromPtr(top);
    const byte_count = dword_count * @sizeOf(u32);
    if (cursor_address > top_address or top_address - cursor_address < byte_count) return null;
    state.cursor_up = cursor + dword_count;
    agc_submit.trackGraphicsCommandAllocation(cursor_address, dword_count);
    return cursor;
}

fn pm4Header(opcode: u8, body_words: usize) u32 {
    std.debug.assert(body_words > 0 and body_words <= 0x4000);
    return (@as(u32, 3) << 30) |
        (@as(u32, @intCast(body_words - 1)) << 16) |
        (@as(u32, opcode) << 8);
}

fn writeAgcPacket(buffer: ?*AgcCommandBuffer, opcode: u8, body: []const u32) ?[*]u32 {
    if (body.len == 0) return null;
    const cursor = reserveAgcDwords(buffer, body.len + 1) orelse return null;
    cursor[0] = pm4Header(opcode, body.len);
    @memcpy(cursor[1 .. body.len + 1], body);
    return cursor;
}

fn writeExactAgcPacket(buffer: ?*AgcCommandBuffer, opcode: u8, body: []const u32) ?[*]u32 {
    if (body.len == 0) return null;
    const cursor = reserveAgcDwords(buffer, body.len + 1) orelse return null;
    cursor[0] = pm4Header(opcode, body.len);
    @memcpy(cursor[1 .. body.len + 1], body);
    return cursor;
}

fn writeAgcCustomPacket(buffer: ?*AgcCommandBuffer, code: u6, body: []const u32) ?[*]u32 {
    if (body.len == 0) return null;
    const cursor = reserveAgcDwords(buffer, body.len + 1) orelse return null;
    cursor[0] = pm4Header(gpu.pm4.nop, body.len) | (@as(u32, code) << 2);
    @memcpy(cursor[1 .. body.len + 1], body);
    return cursor;
}

fn agcCommand(buffer: ?*AgcCommandBuffer, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) ?[*]u32 {
    const body = [_]u32{0} ** 15;
    return writeAgcPacket(buffer, gpu.pm4.nop, &body);
}

fn agcReleaseMem(
    buffer: ?*AgcCommandBuffer,
    action: u64,
    gcr_control: u64,
    destination: u64,
    cache_policy: u64,
    destination_address: u64,
    data_selection: u64,
    data: u64,
    gds_offset: u64,
    gds_size: u64,
    interrupt: u64,
    interrupt_context_id: u64,
) callconv(abi.guest) ?[*]u32 {
    if (destination > 1 or data_selection > 5 or gds_offset != 0 or gds_size > 2 or interrupt > 4) {
        return null;
    }
    var packet_gcr_control: u32 = @truncate(gcr_control);
    packet_gcr_control &= 0x0fff;
    if (packet_gcr_control & 0x300 == 0x100) packet_gcr_control |= 0x200;
    var packet_address = destination_address;
    var packet_data = data;
    if ((interrupt & 0x7) == 4) {
        packet_address = 0;
        packet_data = 0;
    } else if ((data_selection & 0x7) == 5) {
        packet_data = (gds_offset & 0xffff) | ((gds_size & 0xffff) << 16);
    }
    const packet_action: u32 = @as(u32, @truncate(action)) & 0x3f;
    const event_index: u32 = if (action >= 0x2f) 6 else 5;
    const body = [_]u32{
        packet_action |
            (event_index << 8) |
            (packet_gcr_control << 12) |
            ((@as(u32, @truncate(cache_policy)) & 0x3) << 25),
        ((@as(u32, @truncate(destination)) & 0x3) << 16) |
            ((@as(u32, @truncate(interrupt)) & 0x7) << 24) |
            ((@as(u32, @truncate(data_selection)) & 0x7) << 29),
        @as(u32, @truncate(packet_address)) & 0xffff_fffc,
        @truncate(packet_address >> 32),
        @truncate(packet_data),
        @truncate(packet_data >> 32),
        @as(u32, @truncate(interrupt_context_id)) & 0x07ff_ffff,
    };
    return writeAgcCustomPacket(buffer, gpu.pm4.custom.release_mem, &body);
}

fn agcWaitRegMem(
    buffer: ?*AgcCommandBuffer,
    size: u64,
    compare_function: u64,
    operation: u64,
    cache_policy: u64,
    address: u64,
    reference: u64,
    mask: u64,
    poll_cycles: u64,
) callconv(abi.guest) ?[*]u32 {
    if (size > 1 or compare_function > 7 or operation > 4 or cache_policy > 3) return null;

    if (size == 0) {
        const body = [_]u32{
            @as(u32, @truncate(address)) & 0xffff_fffc,
            @as(u32, @truncate(address >> 32)) & 0x0003_ffff,
            @truncate(mask),
            @truncate(reference),
            0x10 |
                (@as(u32, @truncate(compare_function)) & 0x7) |
                ((@as(u32, @truncate(operation)) & 0x3) << 8) |
                ((@as(u32, @truncate(operation)) & 0xc) << 4) |
                ((@as(u32, @truncate(cache_policy)) & 0x3) << 25),
            @intCast(@min(poll_cycles >> 4, 0xffff)),
        };
        return writeAgcCustomPacket(buffer, gpu.pm4.custom.wait_mem_32, &body);
    }

    const body = [_]u32{
        @as(u32, @truncate(address)) & 0xffff_fff8,
        @as(u32, @truncate(address >> 32)) & 0x0003_ffff,
        @truncate(mask),
        @truncate(mask >> 32),
        @truncate(reference),
        @truncate(reference >> 32),
        0x10 |
            (@as(u32, @truncate(compare_function)) & 0x7) |
            ((@as(u32, @truncate(operation)) & 0x1) << 8) |
            ((@as(u32, @truncate(operation)) & 0x6) << 5) |
            ((@as(u32, @truncate(cache_policy)) & 0x3) << 25),
        @intCast(@min(poll_cycles >> 4, 0xffff)),
    };
    return writeAgcCustomPacket(buffer, gpu.pm4.custom.wait_mem_64, &body);
}

fn agcWaitRegMemPatchAddress(command_address: u64, address: u64) callconv(abi.guest) i32 {
    if (!kernel_memory.isGuestRangeAccessible(command_address, 12)) {
        return errno.KernelError.efault.raw();
    }
    const header = readGuestU32(command_address);
    if (((header >> 30) & 0x3) != 3 or @as(u8, @truncate(header >> 8)) != gpu.pm4.nop) {
        return errno.KernelError.einval.raw();
    }
    const code: u6 = @truncate(header >> 2);
    const alignment_mask: u32 = switch (code) {
        gpu.pm4.custom.wait_mem_32 => 0xffff_fffc,
        gpu.pm4.custom.wait_mem_64 => 0xffff_fff8,
        else => return errno.KernelError.einval.raw(),
    };
    writeGuestU32(command_address + 4, @as(u32, @truncate(address)) & alignment_mask);
    writeGuestU32(command_address + 8, @as(u32, @truncate(address >> 32)) & 0x0003_ffff);
    return errno.ok;
}

fn agcEventWrite(
    buffer: ?*AgcCommandBuffer,
    event_type_raw: u64,
    address: u64,
) callconv(abi.guest) ?[*]u32 {
    if (event_type_raw > 0x3f) return null;
    const event_type: u32 = @truncate(event_type_raw);
    if ((event_type & 0x3e) == 0x38) {
        const body = [_]u32{
            0x100 | event_type,
            @as(u32, @truncate(address)) & 0xffff_fff8,
            @truncate(address >> 32),
        };
        return writeAgcPacket(buffer, gpu.pm4.event_write, &body);
    }

    const body = [_]u32{if (event_type == 7 or event_type == 15 or event_type == 16)
        0x400 | event_type
    else
        event_type};
    return writeAgcPacket(buffer, gpu.pm4.event_write, &body);
}

fn agcAcquireMem(
    buffer: ?*AgcCommandBuffer,
    engine: u64,
    cb_db_control: u64,
    gcr_control: u64,
    base_address: u64,
    size_bytes: u64,
    poll_cycles: u64,
) callconv(abi.guest) ?[*]u32 {
    const no_size = size_bytes == std.math.maxInt(u64);
    const body = [_]u32{
        ((@as(u32, @truncate(engine)) & 1) << 31) | @as(u32, @truncate(cb_db_control)),
        if (no_size) 0 else @as(u32, @truncate(size_bytes >> 8)),
        0,
        @truncate(base_address >> 8),
        0,
        @intCast(@min(poll_cycles / 40, std.math.maxInt(u32))),
        @truncate(gcr_control),
    };
    return writeAgcCustomPacket(buffer, gpu.pm4.custom.acquire_mem, &body);
}

fn agcDmaData(
    buffer: ?*AgcCommandBuffer,
    engine: u64,
    destination: u64,
    destination_cache_policy: u64,
    destination_address_or_offset: u64,
    source: u64,
    source_cache_policy: u64,
    source_address_or_offset_or_immediate: u64,
    byte_count: u64,
    wait_for_previous: u64,
    write_confirm: u64,
    block_engine: u64,
) callconv(abi.guest) ?[*]u32 {
    var source_address = source_address_or_offset_or_immediate;
    source_address = switch (source) {
        0x14 => if (engine == 1) 0x30148 else 0x30174,
        0x24 => if (engine == 1) 0x30150 else 0x3017c,
        0x64 => if (engine == 1) 0x30158 else 0x30184,
        else => source_address,
    };

    const source_u32: u32 = @truncate(source);
    const destination_u32: u32 = @truncate(destination);
    const body = [_]u32{
        (@as(u32, @truncate(engine)) & 1) |
            ((@as(u32, @truncate(source_cache_policy)) & 3) << 13) |
            ((destination_u32 & 3) << 20) |
            ((@as(u32, @truncate(destination_cache_policy)) & 3) << 25) |
            ((source_u32 & 3) << 29) |
            ((@as(u32, @truncate(block_engine)) & 1) << 31),
        @truncate(source_address),
        @truncate(source_address >> 32),
        @truncate(destination_address_or_offset),
        @truncate(destination_address_or_offset >> 32),
        (@as(u32, @truncate(byte_count)) & 0x03ff_ffff) |
            ((source_u32 & 4) << 24) |
            ((destination_u32 & 4) << 25) |
            ((source_u32 & 8) << 25) |
            ((destination_u32 & 8) << 26) |
            ((@as(u32, @truncate(wait_for_previous)) & 1) << 30) |
            ((@as(u32, @truncate(write_confirm)) & 1) << 31),
    };
    return writeAgcPacket(buffer, gpu.pm4.dma_data, &body);
}

fn agcDmaDataPatchDestination(command_address: u64, address: u64) callconv(abi.guest) i32 {
    if (!kernel_memory.isGuestRangeAccessible(command_address, 24)) {
        return errno.KernelError.efault.raw();
    }
    const header = readGuestU32(command_address);
    if (((header >> 30) & 3) != 3 or @as(u8, @truncate(header >> 8)) != gpu.pm4.dma_data) {
        return errno.KernelError.einval.raw();
    }
    writeGuestU32(command_address + 16, @truncate(address));
    writeGuestU32(command_address + 20, @truncate(address >> 32));
    return errno.ok;
}

fn agcDmaDataPatchSource(command_address: u64, address: u64) callconv(abi.guest) i32 {
    if (!kernel_memory.isGuestRangeAccessible(command_address, 16)) {
        return errno.KernelError.efault.raw();
    }
    const header = readGuestU32(command_address);
    if (((header >> 30) & 3) != 3 or @as(u8, @truncate(header >> 8)) != gpu.pm4.dma_data) {
        return errno.KernelError.einval.raw();
    }
    writeGuestU32(command_address + 8, @truncate(address));
    writeGuestU32(command_address + 12, @truncate(address >> 32));
    return errno.ok;
}

fn agcGetDataPacketPayloadAddress(
    out_address: ?*u64,
    command_address: u64,
    payload_type: i32,
) callconv(abi.guest) i32 {
    const output = out_address orelse return errno.KernelError.einval.raw();
    if (command_address == 0 or
        !kernel_memory.isGuestRangeAccessible(@intFromPtr(output), @sizeOf(u64)) or
        !kernel_memory.isGuestRangeAccessible(command_address, @sizeOf(u32)))
    {
        return errno.KernelError.efault.raw();
    }

    if (payload_type != 0) {
        output.* = command_address + 2 * @sizeOf(u32);
        return errno.ok;
    }

    const header = readGuestU32(command_address);
    // The maximal type-3 count represents a packet with no separately
    // addressable payload. Every ordinary packet exposes its first body word.
    output.* = if (header & 0x3fff_0000 == 0x3fff_0000)
        0
    else
        command_address + @sizeOf(u32);
    return errno.ok;
}

fn agcReleaseMemPatchAddress(command_address: u64, address: u64) callconv(abi.guest) i32 {
    if (!kernel_memory.isGuestRangeAccessible(command_address, 20)) {
        return errno.KernelError.efault.raw();
    }
    const header = readGuestU32(command_address);
    const opcode: u8 = @truncate(header >> 8);
    if (((header >> 30) & 3) != 3) return errno.KernelError.einval.raw();

    if (opcode == gpu.pm4.nop and
        @as(u6, @truncate(header >> 2)) == gpu.pm4.custom.release_mem)
    {
        writeGuestU32(command_address + 12, @truncate(address));
        writeGuestU32(command_address + 16, @truncate(address >> 32));
        return errno.ok;
    }
    if (opcode == gpu.pm4.release_mem) {
        writeGuestU32(command_address + 12, @truncate(address));
        writeGuestU32(command_address + 16, @truncate(address >> 32));
        return errno.ok;
    }
    return errno.KernelError.einval.raw();
}

fn agcDispatch(
    buffer: ?*AgcCommandBuffer,
    group_x: u32,
    group_y: u32,
    group_z: u32,
    modifier: u32,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    const body = [_]u32{ group_x, group_y, group_z, (modifier & 0xa038) | 0x41 };
    return writeAgcPacket(buffer, gpu.pm4.dispatch_direct, &body);
}

fn agcSetFlip(
    buffer: ?*AgcCommandBuffer,
    video_out_handle: u32,
    display_buffer_index: i32,
    flip_mode: u32,
    flip_argument: i64,
) callconv(abi.guest) ?[*]u32 {
    const raw_argument: u64 = @bitCast(flip_argument);
    const body = [_]u32{
        video_out_handle,
        @bitCast(display_buffer_index),
        flip_mode,
        @truncate(raw_argument),
        @truncate(raw_argument >> 32),
    };
    return writeAgcCustomPacket(buffer, gpu.pm4.custom.flip, &body);
}

fn agcDrawIndex(
    buffer: ?*AgcCommandBuffer,
    index_count: u32,
    index_address: u64,
    modifier: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    if (index_address == 0 or index_address & 1 != 0) return null;
    const initiator: u32 = if (modifier & (@as(u64, 1) << 32) != 0)
        0
    else
        @as(u32, @truncate(modifier >> 3)) & 0x20;
    const body = [_]u32{
        if (index_count == 0) 1 else index_count,
        @truncate(index_address),
        @truncate(index_address >> 32),
        index_count,
        initiator,
    };
    return writeAgcPacket(buffer, gpu.pm4.draw_index_2, &body);
}

fn agcDrawIndexAuto(
    buffer: ?*AgcCommandBuffer,
    index_count: u32,
    modifier: u64,
) callconv(abi.guest) ?[*]u32 {
    const cursor = reserveAgcDwords(buffer, 3) orelse return null;
    const initiator: u32 = if (modifier & (@as(u64, 1) << 32) != 0)
        0
    else
        @as(u32, @truncate(modifier >> 3)) & 0x20;
    cursor[0] = pm4Header(gpu.pm4.draw_index_auto, 2);
    cursor[1] = index_count;
    cursor[2] = initiator | 0x2;
    return cursor;
}

fn agcDrawIndexAutoGetSize() callconv(abi.guest) u32 {
    return 3 * @sizeOf(u32);
}

fn agcSetIndexBuffer(
    buffer: ?*AgcCommandBuffer,
    index_address: u64,
) callconv(abi.guest) ?[*]u32 {
    if (index_address & 1 != 0) return null;
    const body = [_]u32{ @truncate(index_address), @truncate(index_address >> 32) };
    return writeExactAgcPacket(buffer, gpu.pm4.index_base, &body);
}

fn agcSetIndexCount(
    buffer: ?*AgcCommandBuffer,
    index_count: u32,
) callconv(abi.guest) ?[*]u32 {
    const body = [_]u32{index_count};
    return writeExactAgcPacket(buffer, gpu.pm4.index_buffer_size, &body);
}

fn agcDrawIndexOffset(
    buffer: ?*AgcCommandBuffer,
    index_offset: u32,
    index_count: u32,
    modifier: u64,
) callconv(abi.guest) ?[*]u32 {
    const initiator: u32 = if (modifier & (@as(u64, 1) << 32) != 0)
        0
    else
        @as(u32, @truncate(modifier >> 3)) & 0x20;
    const body = [_]u32{
        if (index_count == 0) 1 else index_count,
        index_offset,
        index_count,
        initiator,
    };
    return writeExactAgcPacket(buffer, gpu.pm4.draw_index_offset_2, &body);
}

fn agcDrawIndexOffsetGetSize() callconv(abi.guest) u32 {
    return 5 * @sizeOf(u32);
}

fn agcSetIndexTypeIndexed(
    buffer: ?*AgcCommandBuffer,
    index_size: u32,
    cache_policy: u32,
    index_swap: u32,
) callconv(abi.guest) ?[*]u32 {
    if (index_size > 2 or cache_policy > 3 or index_swap > 1) return null;
    const body = [_]u32{
        0x2000_0243,
        0x400 | (index_size & 3) | ((cache_policy & 3) << 6) | ((index_swap & 1) << 14),
    };
    return writeExactAgcPacket(buffer, gpu.pm4.set_uconfig_reg_index, &body);
}

fn agcSetNumInstances(
    buffer: ?*AgcCommandBuffer,
    instance_count: u32,
    _: u64,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    const body = [_]u32{instance_count};
    return writeAgcPacket(buffer, gpu.pm4.num_instances, &body);
}

fn agcSetIndexSize(
    buffer: ?*AgcCommandBuffer,
    index_size: u32,
    cache_policy: u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    if (cache_policy != 0 or index_size > 2) return null;
    const body = [_]u32{index_size};
    return writeAgcPacket(buffer, gpu.pm4.index_type, &body);
}

fn agcSetRegistersIndirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    opcode: u8,
) ?[*]u32 {
    const body = [_]u32{
        @as(u32, @truncate(registers_address)) & 0xffff_fffc,
        @truncate(registers_address >> 32),
        0x8000_0000,
        register_count & 0x3fff,
    };
    return writeAgcPacket(buffer, opcode, &body);
}

const graphics_error_invalid_packet: i32 = @bitCast(@as(u32, 0x8a6c_000c));

fn agcRegIndirectPatchSetAddress(command_address: u64, registers_address: u64, opcode: u8) i32 {
    if (!kernel_memory.isGuestRangeAccessible(command_address, 3 * @sizeOf(u32))) {
        return errno.KernelError.efault.raw();
    }
    const header = readGuestU32(command_address);
    if (((header >> 30) & 3) != 3 or @as(u8, @truncate(header >> 8)) != opcode) {
        return graphics_error_invalid_packet;
    }
    const old_low = readGuestU32(command_address + @sizeOf(u32));
    writeGuestU32(
        command_address + @sizeOf(u32),
        (old_low & 0x3) | (@as(u32, @truncate(registers_address)) & 0xffff_fffc),
    );
    writeGuestU32(command_address + 2 * @sizeOf(u32), @truncate(registers_address >> 32));
    return errno.ok;
}

fn agcRegIndirectPatchSetNumRegisters(command_address: u64, register_count: u32, opcode: u8) i32 {
    if (!kernel_memory.isGuestRangeAccessible(command_address, 5 * @sizeOf(u32))) {
        return errno.KernelError.efault.raw();
    }
    const header = readGuestU32(command_address);
    if (((header >> 30) & 3) != 3 or @as(u8, @truncate(header >> 8)) != opcode) {
        return graphics_error_invalid_packet;
    }
    const old_count = readGuestU32(command_address + 4 * @sizeOf(u32));
    writeGuestU32(
        command_address + 4 * @sizeOf(u32),
        (old_count & ~@as(u32, 0x3fff)) | (register_count & 0x3fff),
    );
    return errno.ok;
}

fn agcRegIndirectPatchAddRegisters(command_address: u64, register_count: u32, opcode: u8) i32 {
    if (!kernel_memory.isGuestRangeAccessible(command_address, 5 * @sizeOf(u32))) {
        return errno.KernelError.efault.raw();
    }
    const header = readGuestU32(command_address);
    if (((header >> 30) & 3) != 3 or @as(u8, @truncate(header >> 8)) != opcode) {
        return graphics_error_invalid_packet;
    }
    const old_count = readGuestU32(command_address + 4 * @sizeOf(u32));
    const new_count = ((old_count & 0x3fff) +% register_count) & 0x3fff;
    writeGuestU32(
        command_address + 4 * @sizeOf(u32),
        (old_count & ~@as(u32, 0x3fff)) | new_count,
    );
    if (opcode == gpu.pm4.set_sh_reg_indirect and
        trace.announces("sceAgcDcbSetShRegistersIndirect"))
    {
        traceIndirectShaderPrograms(command_address, new_count);
    }
    return errno.ok;
}

/// AGC builds indirect lists incrementally.  When call tracing is enabled,
/// report the program registers visible after each patch so a missing shader
/// can be distinguished from a command-processor decode error without dumping
/// thousands of unrelated state pairs.
fn traceIndirectShaderPrograms(command_address: u64, register_count: u32) void {
    const low = readGuestU32(command_address + @sizeOf(u32)) & 0xffff_fffc;
    const high = readGuestU32(command_address + 2 * @sizeOf(u32));
    const registers_address = (@as(u64, high) << 32) | low;
    const byte_count = @as(usize, register_count) * @sizeOf(ShaderRegister);
    if (register_count == 0 or registers_address == 0 or !accessible(registers_address, byte_count)) return;

    const registers: [*]const ShaderRegister = @ptrFromInt(registers_address);
    var found = false;
    for (registers[0..register_count], 0..) |entry, index| {
        if (entry.offset == std.math.maxInt(u32)) continue;
        var offset = entry.offset & ~@as(u32, 0x7000_0000);
        if (offset >= gpu.pm4.RegisterSpace.shader.base()) {
            offset -%= gpu.pm4.RegisterSpace.shader.base();
        }
        const is_program_word = switch (offset) {
            0x008, 0x009, 0x048, 0x049, 0x088, 0x089, 0x0c8, 0x0c9, 0x108, 0x109, 0x20c, 0x20d => true,
            else => false,
        };
        if (!is_program_word) continue;
        if (!found) {
            std.debug.print(
                "[agc sh indirect] cmd=0x{x} list=0x{x} count={d}\n",
                .{ command_address, registers_address, register_count },
            );
            found = true;
        }
        std.debug.print(
            "  sh[{d}] raw=0x{x} offset=0x{x} value=0x{x}\n",
            .{ index, entry.offset, offset, entry.value },
        );
    }
}

fn agcSetCxRegIndirectPatchSetAddress(command_address: u64, registers_address: u64) callconv(abi.guest) i32 {
    return agcRegIndirectPatchSetAddress(command_address, registers_address, gpu.pm4.set_context_reg_indirect);
}

fn agcSetShRegIndirectPatchSetAddress(command_address: u64, registers_address: u64) callconv(abi.guest) i32 {
    return agcRegIndirectPatchSetAddress(command_address, registers_address, gpu.pm4.set_sh_reg_indirect);
}

fn agcSetUcRegIndirectPatchSetAddress(command_address: u64, registers_address: u64) callconv(abi.guest) i32 {
    return agcRegIndirectPatchSetAddress(command_address, registers_address, gpu.pm4.set_uconfig_reg_indirect);
}

fn agcSetCxRegIndirectPatchSetNumRegisters(command_address: u64, register_count: u32) callconv(abi.guest) i32 {
    return agcRegIndirectPatchSetNumRegisters(command_address, register_count, gpu.pm4.set_context_reg_indirect);
}

fn agcSetShRegIndirectPatchSetNumRegisters(command_address: u64, register_count: u32) callconv(abi.guest) i32 {
    return agcRegIndirectPatchSetNumRegisters(command_address, register_count, gpu.pm4.set_sh_reg_indirect);
}

fn agcSetUcRegIndirectPatchSetNumRegisters(command_address: u64, register_count: u32) callconv(abi.guest) i32 {
    return agcRegIndirectPatchSetNumRegisters(command_address, register_count, gpu.pm4.set_uconfig_reg_indirect);
}

fn agcSetCxRegIndirectPatchAddRegisters(command_address: u64, register_count: u32) callconv(abi.guest) i32 {
    return agcRegIndirectPatchAddRegisters(command_address, register_count, gpu.pm4.set_context_reg_indirect);
}

fn agcSetShRegIndirectPatchAddRegisters(command_address: u64, register_count: u32) callconv(abi.guest) i32 {
    return agcRegIndirectPatchAddRegisters(command_address, register_count, gpu.pm4.set_sh_reg_indirect);
}

fn agcSetUcRegIndirectPatchAddRegisters(command_address: u64, register_count: u32) callconv(abi.guest) i32 {
    return agcRegIndirectPatchAddRegisters(command_address, register_count, gpu.pm4.set_uconfig_reg_indirect);
}

fn agcSetCxRegistersIndirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    return agcSetRegistersIndirect(buffer, registers_address, register_count, gpu.pm4.set_context_reg_indirect);
}

fn agcSetShRegistersIndirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    return agcSetRegistersIndirect(buffer, registers_address, register_count, gpu.pm4.set_sh_reg_indirect);
}

fn agcSetUcRegistersIndirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    return agcSetRegistersIndirect(buffer, registers_address, register_count, gpu.pm4.set_uconfig_reg_indirect);
}

fn agcSetShRegisterRangeDirect(
    buffer: ?*AgcCommandBuffer,
    first_register: u32,
    values_address: u64,
    value_count: u32,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    if (value_count == 0 or value_count > 0x3fff) return null;
    const byte_count = @as(usize, value_count) * @sizeOf(u32);
    if (values_address != 0 and
        (values_address & (@alignOf(u32) - 1) != 0 or !accessible(values_address, byte_count))) return null;

    const total_dwords = @as(usize, value_count) + 2;
    const cursor = reserveAgcDwords(buffer, total_dwords) orelse return null;
    cursor[0] = pm4Header(gpu.pm4.set_sh_reg, @as(usize, value_count) + 1);
    cursor[1] = first_register & 0xffff;
    if (values_address == 0) {
        @memset(cursor[2..total_dwords], 0);
    } else {
        const values: [*]const u32 = @ptrFromInt(values_address);
        @memcpy(cursor[2..total_dwords], values[0..value_count]);
    }
    return cursor;
}

fn agcSetShRegisterRangeDirectGetSize(value_count: u32) callconv(abi.guest) u32 {
    if (value_count == 0 or value_count > 0x3fff) return 0;
    return (value_count + 2) * @sizeOf(u32);
}

fn agcSetRegistersDirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    opcode: u8,
) ?[*]u32 {
    if (register_count == 0 or register_count > 0x1000 or registers_address == 0) return null;
    const byte_count = std.math.mul(
        usize,
        @as(usize, register_count),
        @sizeOf(agc_register_defaults.ShaderRegister),
    ) catch return null;
    if (registers_address & (@alignOf(agc_register_defaults.ShaderRegister) - 1) != 0 or
        !accessible(registers_address, byte_count)) return null;

    // Snapshot the volatile list before advancing the command cursor. Besides
    // matching the retail API, this keeps an aliased source from being
    // overwritten while several register runs are emitted.
    var local: [0x1000]agc_register_defaults.ShaderRegister = undefined;
    const registers: [*]const agc_register_defaults.ShaderRegister = @ptrFromInt(registers_address);
    @memcpy(local[0..register_count], registers[0..register_count]);

    var first_command: ?[*]u32 = null;
    var run_start: usize = 0;
    while (run_start < register_count) {
        var run_end = run_start + 1;
        while (run_end < register_count and
            local[run_end].offset == local[run_end - 1].offset +% 1) : (run_end += 1)
        {}

        const run_count = run_end - run_start;
        const total_dwords = run_count + 2;
        const cursor = reserveAgcDwords(buffer, total_dwords) orelse return first_command;
        if (first_command == null) first_command = cursor;
        cursor[0] = pm4Header(opcode, run_count + 1);
        cursor[1] = local[run_start].offset & 0xffff;
        for (local[run_start..run_end], 0..) |entry, index| cursor[index + 2] = entry.value;
        run_start = run_end;
    }
    return first_command;
}

fn agcSetShRegistersDirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    return agcSetRegistersDirect(buffer, registers_address, register_count, gpu.pm4.set_sh_reg);
}

fn agcSetUcRegistersDirect(
    buffer: ?*AgcCommandBuffer,
    registers_address: u64,
    register_count: u32,
    _: u64,
    _: u64,
    _: u64,
) callconv(abi.guest) ?[*]u32 {
    return agcSetRegistersDirect(buffer, registers_address, register_count, gpu.pm4.set_uconfig_reg);
}

fn agcPatch(_: u64, _: u64, _: u64, _: u64, _: u64, _: u64) callconv(abi.guest) i32 {
    return errno.ok;
}

/// Guest libSceAgc's SuspendPoint busy-waits and prints TRC R5089 forever when
/// the real GPU is not there. Prefer the HLE entry (see preferHleImportId) and
/// yield so other threads can submit frames.
fn agcSuspendPoint() callconv(abi.guest) i32 {
    if (kernel_runtime.guestStopRequested()) {
        kernel_threading.scePthreadExit(null);
    }
    // Pump deferred ring tails and soft-unblock WAIT_REG_MEM so the driver
    // sees GPU "progress" between frames. Without this the title can park
    // mid-encode after ACQUIRE_MEM while SuspendPoint spins on a stale view.
    kernel_ioctl.drainPendingTailsPublic();
    agc_submit.pumpQueues();
    // ~1 ms: enough to free a core without under-pacing a 60 Hz flip loop.
    _ = kernel_threading.sceKernelUsleep(1_000);
    return errno.ok;
}

fn agcGetSize(_: u64) callconv(abi.guest) u32 {
    return 64;
}

fn agcGetRegisterDefaults(version: u32) callconv(abi.guest) *anyopaque {
    return agc_register_defaults.get(version, false);
}

fn agcGetRegisterDefaultsInternal(version: u32) callconv(abi.guest) *anyopaque {
    return agc_register_defaults.get(version, true);
}

const shader_file_header: u32 = 0x3433_3231;
const shader_version: u32 = 0x18;
const shader_structure_size: usize = 0x60;
const shader_user_data_offset: usize = 0x08;
const shader_code_offset: usize = 0x10;
const shader_cx_registers_offset: usize = 0x18;
const shader_sh_registers_offset: usize = 0x20;
const shader_specials_offset: usize = 0x28;
const shader_input_semantics_offset: usize = 0x30;
const shader_output_semantics_offset: usize = 0x38;
const shader_type_offset: usize = 0x5a;
const shader_sh_register_count_offset: usize = 0x5c;

const ShaderRegister = extern struct {
    offset: u32,
    value: u32,
};

fn accessible(address: u64, length: usize) bool {
    return kernel_memory.isGuestRangeAccessible(address, length);
}

fn relocateShaderPointer(field_address: u64) bool {
    if (!accessible(field_address, @sizeOf(u64))) return false;
    const value = readGuestU64(field_address);
    if (value != 0) writeGuestU64(field_address, value +% field_address);
    return true;
}

// Prospero ShaderBinaryType: Cs=0 Ps=1 Gs=2 Hs=3 GsFront=4 HsFront=5 GsBack=6 HsBack=7 Fs=8.
// Front halves and fetch shaders publish no program PGM pair; fuse writes the
// front code address into the fused back-half SH table (ES or LS bank).
fn shaderProgramRegisters(shader_type: u8) ?struct { low: u32, high: u32 } {
    return switch (shader_type) {
        0 => .{ .low = 0x20c, .high = 0x20d }, // compute
        1 => .{ .low = 0x008, .high = 0x009 }, // pixel
        2 => .{ .low = 0x0c8, .high = 0x0c9 }, // GS / NGG export (ES bank)
        3 => .{ .low = 0x148, .high = 0x149 }, // HS (LS bank)
        6 => .{ .low = 0x088, .high = 0x089 }, // GS back half
        7 => .{ .low = 0x108, .high = 0x109 }, // HS back half
        else => null, // 4 GsFront, 5 HsFront, 8 Fs: no PGM pair here
    };
}

fn isShaderFrontOrFetch(shader_type: u8) bool {
    return shader_type == 4 or shader_type == 5 or shader_type == 8;
}

fn isFusableShaderPair(front_type: u8, back_type: u8) bool {
    return (front_type == 4 and back_type == 6) or (front_type == 5 and back_type == 7);
}

fn findShaderRegister(registers: [*]ShaderRegister, count: u8, offset: u32, occurrence: u32) ?*ShaderRegister {
    var seen: u32 = 0;
    for (registers[0..count]) |*entry| {
        if (entry.offset != offset) continue;
        if (seen == occurrence) return entry;
        seen += 1;
    }
    return null;
}

fn patchShaderRegisterAddress(registers: [*]ShaderRegister, count: u8, lo_offset: u32, address: u64) void {
    const low = findShaderRegister(registers, count, lo_offset, 0) orelse return;
    const high = findShaderRegister(registers, count, lo_offset + 1, 0) orelse return;
    low.value = @truncate(address >> 8);
    high.value = (high.value & 0xffff_ff00) | @as(u32, @truncate(address >> 40));
}

fn patchShaderProgram(header_address: u64, code_address: u64) ?u64 {
    if (!accessible(header_address, shader_structure_size)) return null;
    const bytes: [*]u8 = @ptrFromInt(header_address);
    const shader_type = bytes[shader_type_offset];
    // Front halves publish their program address when they are fused with the
    // back half. Fetch shaders likewise have no SH program pair in this table.
    const wanted = shaderProgramRegisters(shader_type) orelse
        return if (isShaderFrontOrFetch(shader_type)) code_address else null;
    const count = bytes[shader_sh_register_count_offset];
    const registers_address = readGuestU64(header_address + shader_sh_registers_offset);
    if (registers_address == 0 or !accessible(registers_address, @as(usize, count) * @sizeOf(ShaderRegister))) {
        return null;
    }

    const registers: [*]ShaderRegister = @ptrFromInt(registers_address);
    var low: ?*ShaderRegister = null;
    var high: ?*ShaderRegister = null;
    for (registers[0..count]) |*entry| {
        if (entry.offset == wanted.low) low = entry;
        if (entry.offset == wanted.high) high = entry;
    }
    if (low == null or high == null) return null;

    const shader_offset = (@as(u64, low.?.value) << 8) | (@as(u64, high.?.value & 0xff) << 40);
    const program_address = code_address +% shader_offset;
    low.?.value = @truncate(program_address >> 8);
    high.?.value = (high.?.value & 0xffff_ff00) | @as(u32, @truncate(program_address >> 40));
    return program_address;
}

fn agcCreateShader(
    output: ?*?*anyopaque,
    header: ?*anyopaque,
    code: ?*const volatile anyopaque,
) callconv(abi.guest) i32 {
    const header_pointer = header orelse return invalid_argument;
    const code_pointer = code orelse return invalid_argument;
    const header_address = @intFromPtr(header_pointer);
    const code_address = @intFromPtr(code_pointer);
    if (!accessible(header_address, shader_structure_size)) return errno.KernelError.efault.raw();

    const header_words: *const [2]u32 = @ptrFromInt(header_address);
    if (header_words[0] != shader_file_header or header_words[1] != shader_version) {
        return invalid_argument;
    }
    const pointer_fields = [_]usize{
        shader_cx_registers_offset,
        shader_sh_registers_offset,
        shader_user_data_offset,
        shader_specials_offset,
        shader_input_semantics_offset,
        shader_output_semantics_offset,
    };
    for (pointer_fields) |offset| {
        if (!relocateShaderPointer(header_address + offset)) return errno.KernelError.efault.raw();
    }
    writeGuestU64(header_address + shader_code_offset, code_address);

    const user_data_address = readGuestU64(header_address + shader_user_data_offset);
    if (user_data_address != 0) {
        for ([_]usize{ 0, 8, 16, 24, 32 }) |offset| {
            if (!relocateShaderPointer(user_data_address + offset)) return errno.KernelError.efault.raw();
        }
    }
    const program_address = patchShaderProgram(header_address, code_address) orelse return invalid_argument;
    // Prefer the front-half header for registry lookups: fused Gs/Hs headers
    // clear user_data, while the export program still runs front code and the
    // attribute / SRT tables live on the front half.
    _ = agc_shader_registry.record(code_address, header_address);
    if (program_address != code_address) _ = agc_shader_registry.record(program_address, header_address);
    if (output) |destination| destination.* = header_pointer;
    return errno.ok;
}

const shader_special_vgt_stages_offset: usize = 0x08;
const spi_shader_pgm_chksum_gs: u32 = 0x80;
const spi_shader_pgm_lo_es: u32 = 0x0c8;
const spi_shader_pgm_lo_ls: u32 = 0x148;
const fused_shader_scratch_align: u64 = 4;
const graphics_error_invalid_shader_halves: i32 = @bitCast(@as(u32, 0x8a6c_0008));

const SizeAlign = extern struct {
    size: u64,
    align_bytes: u64,
};

fn agcGetFusedShaderSize(
    destination: ?*SizeAlign,
    front: ?*const anyopaque,
    back: ?*const anyopaque,
) callconv(abi.guest) i32 {
    const out = destination orelse return invalid_argument;
    const front_address = @intFromPtr(front orelse return invalid_argument);
    const back_address = @intFromPtr(back orelse return invalid_argument);
    if (!accessible(front_address, shader_structure_size) or !accessible(back_address, shader_structure_size)) {
        return errno.KernelError.efault.raw();
    }
    const front_bytes: [*]const u8 = @ptrFromInt(front_address);
    const back_bytes: [*]const u8 = @ptrFromInt(back_address);
    if (!isFusableShaderPair(front_bytes[shader_type_offset], back_bytes[shader_type_offset])) {
        return graphics_error_invalid_shader_halves;
    }
    const register_count = back_bytes[shader_sh_register_count_offset];
    out.* = .{
        .size = @as(u64, register_count) * @sizeOf(ShaderRegister),
        .align_bytes = fused_shader_scratch_align,
    };
    return errno.ok;
}

fn agcFuseShaderHalves(
    fused: ?*anyopaque,
    front: ?*const anyopaque,
    back: ?*const anyopaque,
    scratch: ?*anyopaque,
) callconv(abi.guest) i32 {
    const fused_address = @intFromPtr(fused orelse return invalid_argument);
    const front_address = @intFromPtr(front orelse return invalid_argument);
    const back_address = @intFromPtr(back orelse return invalid_argument);
    if (!accessible(fused_address, shader_structure_size) or
        !accessible(front_address, shader_structure_size) or
        !accessible(back_address, shader_structure_size))
    {
        return errno.KernelError.efault.raw();
    }

    const front_bytes: [*]const u8 = @ptrFromInt(front_address);
    const back_bytes: [*]const u8 = @ptrFromInt(back_address);
    const front_type = front_bytes[shader_type_offset];
    const back_type = back_bytes[shader_type_offset];
    if (!isFusableShaderPair(front_type, back_type)) return graphics_error_invalid_shader_halves;

    const is_geometry = front_type == 4;
    // Wave32 enable bits in VGT_SHADER_STAGES_EN must agree across halves.
    const front_specials = readGuestU64(front_address + shader_specials_offset);
    const back_specials = readGuestU64(back_address + shader_specials_offset);
    if (front_specials != 0 and back_specials != 0) {
        if (!accessible(front_specials + shader_special_vgt_stages_offset + 4, 4) or
            !accessible(back_specials + shader_special_vgt_stages_offset + 4, 4))
        {
            return errno.KernelError.efault.raw();
        }
        const front_stages = @as(*const u32, @ptrFromInt(front_specials + shader_special_vgt_stages_offset + 4)).*;
        const back_stages = @as(*const u32, @ptrFromInt(back_specials + shader_special_vgt_stages_offset + 4)).*;
        const wave_bit: u32 = if (is_geometry) (@as(u32, 1) << 22) else (@as(u32, 1) << 21);
        if ((front_stages ^ back_stages) & wave_bit != 0) return graphics_error_invalid_shader_halves;
    }

    // Fused header starts as a copy of the back half, then becomes Gs/Hs.
    const fused_bytes: [*]u8 = @ptrFromInt(fused_address);
    const back_src: [*]const u8 = @ptrFromInt(back_address);
    @memcpy(fused_bytes[0..shader_structure_size], back_src[0..shader_structure_size]);
    fused_bytes[shader_type_offset] = if (is_geometry) 2 else 3;
    writeGuestU64(fused_address + shader_user_data_offset, 0);

    const back_registers_address = readGuestU64(back_address + shader_sh_registers_offset);
    const register_count = back_bytes[shader_sh_register_count_offset];
    var fused_registers_address = back_registers_address;
    if (scratch) |scratch_pointer| {
        if (back_registers_address != 0 and register_count != 0) {
            const byte_count = @as(usize, register_count) * @sizeOf(ShaderRegister);
            const scratch_address = @intFromPtr(scratch_pointer);
            if (!accessible(back_registers_address, byte_count) or !accessible(scratch_address, byte_count)) {
                return errno.KernelError.efault.raw();
            }
            const dst: [*]u8 = @ptrFromInt(scratch_address);
            const src: [*]const u8 = @ptrFromInt(back_registers_address);
            @memcpy(dst[0..byte_count], src[0..byte_count]);
            fused_registers_address = scratch_address;
        }
    }
    writeGuestU64(fused_address + shader_sh_registers_offset, fused_registers_address);

    const front_code = readGuestU64(front_address + shader_code_offset);
    if (fused_registers_address != 0 and register_count != 0) {
        if (!accessible(fused_registers_address, @as(usize, register_count) * @sizeOf(ShaderRegister))) {
            return errno.KernelError.efault.raw();
        }
        const fused_regs: [*]ShaderRegister = @ptrFromInt(fused_registers_address);
        if (is_geometry) {
            const front_registers_address = readGuestU64(front_address + shader_sh_registers_offset);
            const front_count = front_bytes[shader_sh_register_count_offset];
            if (front_registers_address != 0 and front_count != 0 and
                accessible(front_registers_address, @as(usize, front_count) * @sizeOf(ShaderRegister)))
            {
                const front_regs: [*]ShaderRegister = @ptrFromInt(front_registers_address);
                for (0..2) |occurrence| {
                    const dst = findShaderRegister(fused_regs, register_count, spi_shader_pgm_chksum_gs, @intCast(occurrence));
                    const src = findShaderRegister(front_regs, front_count, spi_shader_pgm_chksum_gs, @intCast(occurrence));
                    if (dst) |d| {
                        if (src) |s| d.value = s.value;
                    }
                }
            }
            patchShaderRegisterAddress(fused_regs, register_count, spi_shader_pgm_lo_es, front_code);
        } else {
            patchShaderRegisterAddress(fused_regs, register_count, spi_shader_pgm_lo_ls, front_code);
        }
    }

    // Draw-time lookup keys off the export program address (front code). The
    // front header still owns user_data / attribute tables after user_data is
    // cleared on the fused object.
    if (front_code != 0) _ = agc_shader_registry.record(front_code, front_address);
    return errno.ok;
}

fn agcCreatePrimState(
    cx_registers: ?[*]ShaderRegister,
    uc_registers: ?[*]ShaderRegister,
    _: ?*const anyopaque,
    geometry_shader: ?*const anyopaque,
    primitive_type: u32,
    _: u64,
) callconv(abi.guest) i32 {
    if (cx_registers == null and uc_registers == null) return errno.ok;
    const shader = geometry_shader orelse return invalid_argument;
    const shader_address = @intFromPtr(shader);
    if (!accessible(shader_address, shader_structure_size)) return errno.KernelError.efault.raw();
    const specials_address = readGuestU64(shader_address + shader_specials_offset);
    if (specials_address == 0 or !accessible(specials_address, 0x30)) return invalid_argument;
    const specials: [*]const ShaderRegister = @ptrFromInt(specials_address);

    if (cx_registers) |cx| {
        cx[0] = specials[1]; // VGT_SHADER_STAGES_EN at +0x08
        cx[1] = specials[4]; // VGT_GS_OUT_PRIM_TYPE at +0x20
    }
    if (uc_registers) |uc| {
        uc[0] = specials[0]; // GE_CNTL at +0x00
        uc[1] = specials[5]; // GE_USER_VGPR_EN at +0x28
        uc[2] = .{ .offset = 0x242, .value = primitive_type };
    }
    return errno.ok;
}

const agc_exports = [_]symbols.Export{
    .{ .name = "sceAgcInitialize", .function = trace.wrap("sceAgcInitialize", &agcPatch), .id_override = "23LRUSvYu1M" },
    .{ .name = "sceAgcGetRegisterDefaults2", .function = trace.wrap("sceAgcGetRegisterDefaults2", &agcGetRegisterDefaults), .expect_id = "2JtWUUiYBXs" },
    .{ .name = "sceAgcGetRegisterDefaults2Internal", .function = trace.wrap("sceAgcGetRegisterDefaults2Internal", &agcGetRegisterDefaultsInternal), .expect_id = "wRbq6ZjNop4" },
    .{ .name = "sceAgcCreateShader", .function = trace.wrap("sceAgcCreateShader", &agcCreateShader), .expect_id = "f3dg2CSgRKY" },
    .{ .name = "sceAgcUnknownGetFusedShaderSize", .function = trace.wrap("sceAgcUnknownGetFusedShaderSize", &agcGetFusedShaderSize), .id_override = "dolOmWH+huQ" },
    .{ .name = "sceAgcUnknownFuseShaderHalves", .function = trace.wrap("sceAgcUnknownFuseShaderHalves", &agcFuseShaderHalves), .id_override = "fd5Bp5tGTgo" },
    .{ .name = "sceAgcSetCxRegIndirectPatchSetAddress", .function = trace.wrap("sceAgcSetCxRegIndirectPatchSetAddress", &agcSetCxRegIndirectPatchSetAddress), .expect_id = "vcmNN+AAXnY" },
    .{ .name = "sceAgcSetShRegIndirectPatchSetAddress", .function = trace.wrap("sceAgcSetShRegIndirectPatchSetAddress", &agcSetShRegIndirectPatchSetAddress), .expect_id = "Qrj4c+61z4A" },
    .{ .name = "sceAgcSetUcRegIndirectPatchSetAddress", .function = trace.wrap("sceAgcSetUcRegIndirectPatchSetAddress", &agcSetUcRegIndirectPatchSetAddress), .expect_id = "6lNcCp+fxi4" },
    .{ .name = "sceAgcSetCxRegIndirectPatchSetNumRegisters", .function = trace.wrap("sceAgcSetCxRegIndirectPatchSetNumRegisters", &agcSetCxRegIndirectPatchSetNumRegisters), .expect_id = "whb1RL7K4Ss" },
    .{ .name = "sceAgcSetShRegIndirectPatchSetNumRegisters", .function = trace.wrap("sceAgcSetShRegIndirectPatchSetNumRegisters", &agcSetShRegIndirectPatchSetNumRegisters), .expect_id = "nCUgItdN2ms" },
    .{ .name = "sceAgcSetUcRegIndirectPatchSetNumRegisters", .function = trace.wrap("sceAgcSetUcRegIndirectPatchSetNumRegisters", &agcSetUcRegIndirectPatchSetNumRegisters), .expect_id = "fRG-JOH5+sI" },
    .{ .name = "sceAgcSetCxRegIndirectPatchAddRegisters", .function = trace.wrap("sceAgcSetCxRegIndirectPatchAddRegisters", &agcSetCxRegIndirectPatchAddRegisters), .expect_id = "d-6uF9sZDIU" },
    .{ .name = "sceAgcSetShRegIndirectPatchAddRegisters", .function = trace.wrap("sceAgcSetShRegIndirectPatchAddRegisters", &agcSetShRegIndirectPatchAddRegisters), .expect_id = "z2duB-hHQSM" },
    .{ .name = "sceAgcSetUcRegIndirectPatchAddRegisters", .function = trace.wrap("sceAgcSetUcRegIndirectPatchAddRegisters", &agcSetUcRegIndirectPatchAddRegisters), .expect_id = "vRoArM9zaIk" },
    .{ .name = "sceAgcCreatePrimState", .function = trace.wrap("sceAgcCreatePrimState", &agcCreatePrimState), .expect_id = "D9sr1xGUriE" },
    .{ .name = "sceAgcWriteDataPatchSetAddressOrOffset", .function = trace.wrap("sceAgcWriteDataPatchSetAddressOrOffset", &agcPatch), .expect_id = "fPSCdQxgpSw" },
    .{ .name = "sceAgcDmaDataPatchSetDstAddressOrOffset", .function = trace.wrap("sceAgcDmaDataPatchSetDstAddressOrOffset", &agcDmaDataPatchDestination), .expect_id = "IxYiarKlXxM" },
    .{ .name = "sceAgcDmaDataPatchSetSrcAddressOrOffsetOrImmediate", .function = trace.wrap("sceAgcDmaDataPatchSetSrcAddressOrOffsetOrImmediate", &agcDmaDataPatchSource), .expect_id = "cdDRpqcFGbU" },
    .{ .name = "sceAgcQueueEndOfPipeActionPatchAddress", .function = trace.wrap("sceAgcQueueEndOfPipeActionPatchAddress", &agcReleaseMemPatchAddress), .expect_id = "0fWWK5uG9rQ" },
    .{ .name = "sceAgcWaitRegMemPatchAddress", .function = trace.wrap("sceAgcWaitRegMemPatchAddress", &agcWaitRegMemPatchAddress), .expect_id = "3KDcnM3lrcU" },
    .{ .name = "sceAgcSetNop", .function = trace.wrap("sceAgcSetNop", &agcPatch), .expect_id = "K2mciNVxUCE" },
    .{ .name = "sceAgcSuspendPoint", .function = trace.wrap("sceAgcSuspendPoint", &agcSuspendPoint), .expect_id = "h9z6+0hEydk" },
    .{ .name = "sceAgcGetIsTrinityMode", .function = trace.wrap("sceAgcGetIsTrinityMode", &agcPatch), .expect_id = "BfBDZGbti7A" },
    .{ .name = "sceAgcDebugRaiseException", .function = trace.wrap("sceAgcDebugRaiseException", &agcPatch), .expect_id = "T6xuVw0KUJo" },
    .{ .name = "sceAgcCbSetShRegisterRangeDirectGetSize", .function = trace.wrap("sceAgcCbSetShRegisterRangeDirectGetSize", &agcSetShRegisterRangeDirectGetSize), .expect_id = "bxGoVxpdSPQ" },
    .{ .name = "sceAgcUnknownDb", .function = trace.wrap("sceAgcUnknownDb", &agcPatch), .id_override = "dbOlWdppb4o" },
    .{ .name = "sceAgcUnknownKRzWekV120", .function = trace.wrap("sceAgcUnknownKRzWekV120", &agcSetIndexTypeIndexed), .id_override = "-KRzWekV120" },
    .{ .name = "sceAgcUnknownIkfdtRIqCE", .function = trace.wrap("sceAgcUnknownIkfdtRIqCE", &agcPatch), .id_override = "Ikfdt-rIqCE" },
    .{ .name = "sceAgcGetDataPacketPayloadAddress", .function = trace.wrap("sceAgcGetDataPacketPayloadAddress", &agcGetDataPacketPayloadAddress), .id_override = "V++UgBtQhn0" },

    .{ .name = "sceAgcCbNop", .function = trace.wrap("sceAgcCbNop", &agcCommand), .expect_id = "LtTouSCZjHM" },
    .{ .name = "sceAgcCbDispatch", .function = trace.wrap("sceAgcCbDispatch", &agcDispatch), .expect_id = "k3GhuSNmBLU" },
    .{ .name = "sceAgcCbSetShRegisterRangeDirect", .function = trace.wrap("sceAgcCbSetShRegisterRangeDirect", &agcSetShRegisterRangeDirect), .expect_id = "n2fD4A+pb+g" },
    .{ .name = "sceAgcCbSetShRegistersDirect", .function = trace.wrap("sceAgcCbSetShRegistersDirect", &agcSetShRegistersDirect), .expect_id = "UZbQjYAwwXM" },
    .{ .name = "sceAgcCbSetUcRegistersDirect", .function = trace.wrap("sceAgcCbSetUcRegistersDirect", &agcSetUcRegistersDirect), .expect_id = "03RZmELWWzw" },
    .{ .name = "sceAgcCbReleaseMem", .function = trace.wrap("sceAgcCbReleaseMem", &agcReleaseMem), .expect_id = "wr23dPKyWc0" },

    .{ .name = "sceAgcAcbResetQueue", .function = trace.wrap("sceAgcAcbResetQueue", &agcCommand), .expect_id = "JrtiDtKeS38" },
    .{ .name = "sceAgcAcbDispatchIndirect", .function = trace.wrap("sceAgcAcbDispatchIndirect", &agcCommand), .expect_id = "j3EtxFkSIhQ" },
    .{ .name = "sceAgcAcbWaitUntilSafeForRendering", .function = trace.wrap("sceAgcAcbWaitUntilSafeForRendering", &agcCommand), .expect_id = "GPbUp9jXQa8" },
    .{ .name = "sceAgcAcbWaitRegMem", .function = trace.wrap("sceAgcAcbWaitRegMem", &agcCommand), .expect_id = "htn36gPnBk4" },
    .{ .name = "sceAgcAcbAcquireMem", .function = trace.wrap("sceAgcAcbAcquireMem", &agcCommand), .expect_id = "KT-hTp-Ch14" },
    .{ .name = "sceAgcAcbDmaData", .function = trace.wrap("sceAgcAcbDmaData", &agcCommand), .expect_id = "-RnpfpxIhec" },
    .{ .name = "sceAgcAcbCopyData", .function = trace.wrap("sceAgcAcbCopyData", &agcCommand), .expect_id = "qzMN2XKGA4k" },
    .{ .name = "sceAgcAcbWriteData", .function = trace.wrap("sceAgcAcbWriteData", &agcCommand), .expect_id = "eZ4+17OQz4Q" },
    .{ .name = "sceAgcAcbEventWrite", .function = trace.wrap("sceAgcAcbEventWrite", &agcCommand), .expect_id = "cFazmnXpJOE" },
    .{ .name = "sceAgcAcbJump", .function = trace.wrap("sceAgcAcbJump", &agcCommand), .expect_id = "e1DFTg+Sd8U" },
    .{ .name = "sceAgcAcbPushMarker", .function = trace.wrap("sceAgcAcbPushMarker", &agcCommand), .expect_id = "cpCILPya5Zk" },
    .{ .name = "sceAgcAcbPopMarker", .function = trace.wrap("sceAgcAcbPopMarker", &agcCommand), .expect_id = "6mFxkVqdmbQ" },

    .{ .name = "sceAgcDcbResetQueue", .function = trace.wrap("sceAgcDcbResetQueue", &agcCommand), .expect_id = "TRO721eVt4g" },
    .{ .name = "sceAgcDcbWaitUntilSafeForRendering", .function = trace.wrap("sceAgcDcbWaitUntilSafeForRendering", &agcCommand), .expect_id = "MWiElSNE8j8" },
    .{ .name = "sceAgcDcbSetIndexBuffer", .function = trace.wrap("sceAgcDcbSetIndexBuffer", &agcSetIndexBuffer), .expect_id = "l4fM9K-Lyks" },
    .{ .name = "sceAgcDcbSetIndexCount", .function = trace.wrap("sceAgcDcbSetIndexCount", &agcSetIndexCount), .expect_id = "8N2tmT3jmC8" },
    .{ .name = "sceAgcDcbSetIndexSize", .function = trace.wrap("sceAgcDcbSetIndexSize", &agcSetIndexSize), .expect_id = "GIIW2J37e70" },
    .{ .name = "sceAgcDcbDrawIndex", .function = trace.wrap("sceAgcDcbDrawIndex", &agcDrawIndex), .expect_id = "q88lQ+GP5Yk" },
    .{ .name = "sceAgcDcbDrawIndexAuto", .function = trace.wrap("sceAgcDcbDrawIndexAuto", &agcDrawIndexAuto), .expect_id = "Yw0jKSqop+E" },
    .{ .name = "sceAgcDcbDrawIndexAutoGetSize", .function = trace.wrap("sceAgcDcbDrawIndexAutoGetSize", &agcDrawIndexAutoGetSize), .expect_id = "WrdP9Zxx3lQ" },
    .{ .name = "sceAgcDcbDrawIndexOffset", .function = trace.wrap("sceAgcDcbDrawIndexOffset", &agcDrawIndexOffset), .expect_id = "B+aG9DUnTKA" },
    .{ .name = "sceAgcDcbDrawIndexOffsetGetSize", .function = trace.wrap("sceAgcDcbDrawIndexOffsetGetSize", &agcDrawIndexOffsetGetSize), .expect_id = "qMlfB1ZhMDc" },
    .{ .name = "sceAgcDcbDrawIndexIndirect", .function = trace.wrap("sceAgcDcbDrawIndexIndirect", &agcCommand), .expect_id = "t1vNu082-jM" },
    .{ .name = "sceAgcDcbDrawIndirect", .function = trace.wrap("sceAgcDcbDrawIndirect", &agcCommand), .expect_id = "1q1titRBL6o" },
    .{ .name = "sceAgcDcbDispatchIndirect", .function = trace.wrap("sceAgcDcbDispatchIndirect", &agcCommand), .expect_id = "CtB+A9-VxO0" },
    .{ .name = "sceAgcDcbSetNumInstances", .function = trace.wrap("sceAgcDcbSetNumInstances", &agcSetNumInstances), .expect_id = "tSBxhAPyytQ" },
    .{ .name = "sceAgcDcbStallCommandBufferParser", .function = trace.wrap("sceAgcDcbStallCommandBufferParser", &agcCommand), .expect_id = "u2T2DiA5hRI" },
    .{ .name = "sceAgcDcbSetBaseIndirectArgs", .function = trace.wrap("sceAgcDcbSetBaseIndirectArgs", &agcCommand), .expect_id = "RmaJwLtc8rY" },
    .{ .name = "sceAgcDcbSetShRegistersIndirect", .function = trace.wrap("sceAgcDcbSetShRegistersIndirect", &agcSetShRegistersIndirect), .expect_id = "-HOOCn0JY48" },
    .{ .name = "sceAgcDcbSetUcRegistersIndirect", .function = trace.wrap("sceAgcDcbSetUcRegistersIndirect", &agcSetUcRegistersIndirect), .expect_id = "hvUfkUIQcOE" },
    .{ .name = "sceAgcDcbSetCxRegistersIndirect", .function = trace.wrap("sceAgcDcbSetCxRegistersIndirect", &agcSetCxRegistersIndirect), .expect_id = "ZvwO9euwYzc" },
    .{ .name = "sceAgcDcbWaitRegMem", .function = trace.wrap("sceAgcDcbWaitRegMem", &agcWaitRegMem), .expect_id = "VmW0Tdpy420" },
    .{ .name = "sceAgcDcbAcquireMem", .function = trace.wrap("sceAgcDcbAcquireMem", &agcAcquireMem), .expect_id = "57labkp+rSQ" },
    .{ .name = "sceAgcDcbDmaData", .function = trace.wrap("sceAgcDcbDmaData", &agcDmaData), .expect_id = "WmAc2MEj6Io" },
    .{ .name = "sceAgcDcbCopyData", .function = trace.wrap("sceAgcDcbCopyData", &agcCommand), .expect_id = "1rZSWUv1IRc" },
    .{ .name = "sceAgcDcbWriteData", .function = trace.wrap("sceAgcDcbWriteData", &agcCommand), .expect_id = "i1jyy49AjXU" },
    .{ .name = "sceAgcDcbEventWrite", .function = trace.wrap("sceAgcDcbEventWrite", &agcEventWrite), .expect_id = "aJf+j5yntiU" },
    .{ .name = "sceAgcDcbJump", .function = trace.wrap("sceAgcDcbJump", &agcCommand), .expect_id = "xSAR0LTcRKM" },
    .{ .name = "sceAgcDcbPushMarker", .function = trace.wrap("sceAgcDcbPushMarker", &agcCommand), .expect_id = "+kSrjIVxKFE" },
    .{ .name = "sceAgcDcbPopMarker", .function = trace.wrap("sceAgcDcbPopMarker", &agcCommand), .expect_id = "H7uZqCoNuWk" },
    .{ .name = "sceAgcDcbSetFlip", .function = trace.wrap("sceAgcDcbSetFlip", &agcSetFlip), .expect_id = "YUeqkyT7mEQ" },
};

const agc_driver_exports = [_]symbols.Export{
    .{ .name = "sceAgcDriverRegisterOwner", .function = trace.wrap("sceAgcDriverRegisterOwner", &success), .expect_id = "X-Nm5KLREeg" },
    .{ .name = "sceAgcDriverSetHsOffchipParam", .function = trace.wrap("sceAgcDriverSetHsOffchipParam", &success), .expect_id = "MM4IZSEYytQ" },
    .{ .name = "sceAgcDriverRegisterResource", .function = trace.wrap("sceAgcDriverRegisterResource", &success), .expect_id = "W5z4eZrjEas" },
    .{ .name = "sceAgcDriverAddEqEvent", .function = trace.wrap("sceAgcDriverAddEqEvent", &agc.driverAddEqEvent), .expect_id = "w2rJhmD+dsE" },
    .{ .name = "sceAgcDriverGetEqContextId", .function = trace.wrap("sceAgcDriverGetEqContextId", &agc.driverGetEqContextId), .expect_id = "Zw7uUVPulbw" },
    .{ .name = "sceAgcDriverSetTFRing", .function = trace.wrap("sceAgcDriverSetTFRing", &success), .expect_id = "XlNp7jzGiPo" },
};

const ampr_exports = [_]symbols.Export{
    .{ .name = "sceAmprCommandBufferConstructor", .function = trace.wrap("sceAmprCommandBufferConstructor", &amprCommandBufferConstructor), .expect_id = "8aI7R7WaOlc" },
    .{ .name = "sceAmprAprCommandBufferConstructor", .function = trace.wrap("sceAmprAprCommandBufferConstructor", &amprAprCommandBufferConstructor), .expect_id = "a8uLzYY--tM" },
    .{ .name = "sceAmprCommandBufferDestructor", .function = trace.wrap("sceAmprCommandBufferDestructor", &amprCommandBufferDestructor), .expect_id = "GuchCTefuZw" },
    .{ .name = "sceAmprAprCommandBufferDestructor", .function = trace.wrap("sceAmprAprCommandBufferDestructor", &amprAprCommandBufferDestructor), .expect_id = "Qs1xtplKo0U" },
    .{ .name = "sceAmprCommandBufferReset", .function = trace.wrap("sceAmprCommandBufferReset", &amprCommandBufferReset), .expect_id = "baQO9ez2gL4" },
    .{ .name = "sceAmprCommandBufferSetBuffer", .function = trace.wrap("sceAmprCommandBufferSetBuffer", &amprCommandBufferSetBuffer), .expect_id = "N-FSPA4S3nI" },
    .{ .name = "sceAmprCommandBufferClearBuffer", .function = trace.wrap("sceAmprCommandBufferClearBuffer", &amprCommandBufferClearBuffer), .expect_id = "ULvXMDz56po" },
    .{ .name = "sceAmprCommandBufferGetType", .function = trace.wrap("sceAmprCommandBufferGetType", &amprCommandBufferGetType), .expect_id = "VEDMaQmJZng" },
    .{ .name = "sceAmprCommandBufferGetSize", .function = trace.wrap("sceAmprCommandBufferGetSize", &amprCommandBufferGetSize), .expect_id = "tZDDEo2tE5k" },
    .{ .name = "sceAmprCommandBufferGetBufferBaseAddress", .function = trace.wrap("sceAmprCommandBufferGetBufferBaseAddress", &amprCommandBufferGetBufferBaseAddress), .expect_id = "RPCAhx-aabE" },
    .{ .name = "sceAmprCommandBufferGetNumCommands", .function = trace.wrap("sceAmprCommandBufferGetNumCommands", &amprCommandBufferGetNumCommands), .expect_id = "gzndltBEzWc" },
    .{ .name = "sceAmprCommandBufferGetCurrentOffset", .function = trace.wrap("sceAmprCommandBufferGetCurrentOffset", &amprCommandBufferGetCurrentOffset), .expect_id = "GnxKOHEawhk" },
    .{ .name = "sceAmprAprCommandBufferReadFile", .function = trace.wrap("sceAmprAprCommandBufferReadFile", &amprAprCommandBufferReadFile), .expect_id = "mQ16-QdKv7k" },
    .{ .name = "sceAmprAprCommandBufferReadFileGather", .function = trace.wrap("sceAmprAprCommandBufferReadFileGather", &amprAprCommandBufferReadFileGather), .expect_id = "mZSbNJVJpV8" },
    .{ .name = "sceAmprAprCommandBufferReadFileScatter", .function = trace.wrap("sceAmprAprCommandBufferReadFileScatter", &amprAprCommandBufferReadFileScatter), .expect_id = "Jg-AgkdJHkk" },
    .{ .name = "sceAmprAprCommandBufferReadFileGatherScatter", .function = trace.wrap("sceAmprAprCommandBufferReadFileGatherScatter", &amprAprCommandBufferReadFileGatherScatter), .expect_id = "BVmR1H8l+XI" },
    .{ .name = "sceAmprAprCommandBufferResetGatherScatterState", .function = trace.wrap("sceAmprAprCommandBufferResetGatherScatterState", &amprAprCommandBufferResetGatherScatterState), .expect_id = "YPxkUDhgoNI" },
    .{ .name = "sceAmprMeasureCommandSizeReadFile", .function = trace.wrap("sceAmprMeasureCommandSizeReadFile", &amprMeasureCommandSizeReadFile), .expect_id = "vWU-odnS+fU" },
    .{ .name = "sceAmprMeasureCommandSizeReadFileGather", .function = trace.wrap("sceAmprMeasureCommandSizeReadFileGather", &amprMeasureCommandSizeReadFileGather), .expect_id = "qesF88X4DRg" },
    .{ .name = "sceAmprMeasureCommandSizeReadFileScatter", .function = trace.wrap("sceAmprMeasureCommandSizeReadFileScatter", &amprMeasureCommandSizeReadFileScatter), .expect_id = "7nXGDGMXSqo" },
    .{ .name = "sceAmprMeasureCommandSizeReadFileGatherScatter", .function = trace.wrap("sceAmprMeasureCommandSizeReadFileGatherScatter", &amprMeasureCommandSizeReadFileGatherScatter), .expect_id = "DXmgc5op8Yw" },
    .{ .name = "sceAmprMeasureCommandSizeResetGatherScatterState", .function = trace.wrap("sceAmprMeasureCommandSizeResetGatherScatterState", &amprMeasureCommandSizeResetGatherScatterState), .expect_id = "rddQYXM0CjM" },
    .{ .name = "sceAmprMeasureCommandSizeWriteKernelEventQueue_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteKernelEventQueue_04_00", &amprMeasureCommandSizeWriteKernelEventQueue), .expect_id = "sSAUCCU1dv4" },
    .{ .name = "sceAmprCommandBufferWriteKernelEventQueue_04_00", .function = trace.wrap("sceAmprCommandBufferWriteKernelEventQueue_04_00", &amprCommandBufferWriteKernelEventQueue), .expect_id = "H896Pt-yB4I" },
    .{ .name = "sceAmprCommandBufferWaitOnAddress_04_00", .function = trace.wrap("sceAmprCommandBufferWaitOnAddress_04_00", &amprCommandBufferWaitOnAddress), .expect_id = "DLfoNxTFNVk" },
    .{ .name = "sceAmprCommandBufferWaitOnCounter_04_00", .function = trace.wrap("sceAmprCommandBufferWaitOnCounter_04_00", &amprCommandBufferWaitOnCounter), .expect_id = "cQb8Zr8Q0Y0" },
    .{ .name = "sceAmprCommandBufferWriteAddress_04_00", .function = trace.wrap("sceAmprCommandBufferWriteAddress_04_00", &amprCommandBufferWriteAddress), .expect_id = "j0+3uJMxYJY" },
    .{ .name = "sceAmprCommandBufferWriteAddressFromTimeCounter_04_00", .function = trace.wrap("sceAmprCommandBufferWriteAddressFromTimeCounter_04_00", &amprCommandBufferWriteAddressFromTimeCounter), .expect_id = "bt3LHR9xjK4" },
    .{ .name = "sceAmprCommandBufferWriteAddressFromCounter_04_00", .function = trace.wrap("sceAmprCommandBufferWriteAddressFromCounter_04_00", &amprCommandBufferWriteAddressFromCounter), .expect_id = "t4ExS+SwLjs" },
    .{ .name = "sceAmprCommandBufferWriteAddressFromCounterPair_04_00", .function = trace.wrap("sceAmprCommandBufferWriteAddressFromCounterPair_04_00", &amprCommandBufferWriteAddressFromCounterPair), .expect_id = "enZm-6GjWqw" },
    .{ .name = "sceAmprCommandBufferWriteCounter_04_00", .function = trace.wrap("sceAmprCommandBufferWriteCounter_04_00", &amprCommandBufferWriteCounter), .expect_id = "jK+yuYCI7MA" },
    .{ .name = "sceAmprCommandBufferConstructNop", .function = trace.wrap("sceAmprCommandBufferConstructNop", &amprCommandBufferConstructNop), .expect_id = "GmOguNIsuKk" },
    .{ .name = "sceAmprCommandBufferNop", .function = trace.wrap("sceAmprCommandBufferNop", &amprCommandBufferNop), .expect_id = "tNn5WBkta60" },
    .{ .name = "sceAmprCommandBufferNopWithData", .function = trace.wrap("sceAmprCommandBufferNopWithData", &amprCommandBufferNopWithData), .expect_id = "pFQ9UHpO52s" },
    .{ .name = "sceAmprCommandBufferConstructMarker", .function = trace.wrap("sceAmprCommandBufferConstructMarker", &amprCommandBufferConstructMarker), .expect_id = "4UkZbYKVF7c" },
    .{ .name = "sceAmprCommandBufferSetMarkerWithColor", .function = trace.wrap("sceAmprCommandBufferSetMarkerWithColor", &amprCommandBufferSetMarkerWithColor), .expect_id = "sWbST0oQKsc" },
    .{ .name = "sceAmprCommandBufferSetMarker", .function = trace.wrap("sceAmprCommandBufferSetMarker", &amprCommandBufferSetMarker), .expect_id = "4quckD2y7Pg" },
    .{ .name = "sceAmprCommandBufferPushMarkerWithColor", .function = trace.wrap("sceAmprCommandBufferPushMarkerWithColor", &amprCommandBufferPushMarkerWithColor), .expect_id = "f12ObAMEi9A" },
    .{ .name = "sceAmprCommandBufferPushMarker", .function = trace.wrap("sceAmprCommandBufferPushMarker", &amprCommandBufferPushMarker), .expect_id = "dXPaz65HNmk" },
    .{ .name = "sceAmprCommandBufferPopMarker", .function = trace.wrap("sceAmprCommandBufferPopMarker", &amprCommandBufferPopMarker), .expect_id = "mv0O8Zg0woU" },
    .{ .name = "sceAmprAprCommandBufferMapBegin", .function = trace.wrap("sceAmprAprCommandBufferMapBegin", &amprAprCommandBufferMapBegin), .expect_id = "Eul7AGEpjLo" },
    .{ .name = "sceAmprAprCommandBufferMapDirectBegin", .function = trace.wrap("sceAmprAprCommandBufferMapDirectBegin", &amprAprCommandBufferMapDirectBegin), .expect_id = "bFEs0Gs6D2A" },
    .{ .name = "sceAmprAprCommandBufferMapEnd", .function = trace.wrap("sceAmprAprCommandBufferMapEnd", &amprAprCommandBufferMapEnd), .expect_id = "X169CE6G3Y4" },
    .{ .name = "sceAmprMeasureCommandSizeWaitOnAddress_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWaitOnAddress_04_00", &amprMeasureCommandSizeFixed32), .expect_id = "0BMj1hgG+kE" },
    .{ .name = "sceAmprMeasureCommandSizeWaitOnCounter_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWaitOnCounter_04_00", &amprMeasureCommandSizeFixed32), .expect_id = "ClnsFLLLcss" },
    .{ .name = "sceAmprMeasureCommandSizeWriteAddress_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteAddress_04_00", &amprMeasureCommandSizeFixed32), .expect_id = "4fgtGfXDrFc" },
    .{ .name = "sceAmprMeasureCommandSizeWriteAddressFromTimeCounter_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteAddressFromTimeCounter_04_00", &amprMeasureCommandSizeFixed32), .expect_id = "gAtc79UTt5E" },
    .{ .name = "sceAmprMeasureCommandSizeWriteAddressFromCounter_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteAddressFromCounter_04_00", &amprMeasureCommandSizeFixed32), .expect_id = "JYd9g9L+TmE" },
    .{ .name = "sceAmprMeasureCommandSizeWriteAddressFromCounterPair_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteAddressFromCounterPair_04_00", &amprMeasureCommandSizeFixed32), .expect_id = "2Hw8gjMdwSY" },
    .{ .name = "sceAmprMeasureCommandSizeWriteCounter_04_00", .function = trace.wrap("sceAmprMeasureCommandSizeWriteCounter_04_00", &amprMeasureCommandSizeFixed32), .expect_id = "I-Qm+MEso5c" },
    .{ .name = "sceAmprMeasureCommandSizeNop", .function = trace.wrap("sceAmprMeasureCommandSizeNop", &amprMeasureCommandSizeNop), .expect_id = "NNIZ-FMyz3M" },
    .{ .name = "sceAmprMeasureCommandSizeNopWithData", .function = trace.wrap("sceAmprMeasureCommandSizeNopWithData", &amprMeasureCommandSizeNopWithData), .expect_id = "Xp85BP3+BBI" },
    .{ .name = "sceAmprMeasureCommandSizeMapBegin", .function = trace.wrap("sceAmprMeasureCommandSizeMapBegin", &amprMeasureCommandSizeMapBegin), .expect_id = "kdFImtTD0hc" },
    .{ .name = "sceAmprMeasureCommandSizeMapDirectBegin", .function = trace.wrap("sceAmprMeasureCommandSizeMapDirectBegin", &amprMeasureCommandSizeMapDirectBegin), .expect_id = "qvbdJc7bG+s" },
    .{ .name = "sceAmprMeasureCommandSizeMapEnd", .function = trace.wrap("sceAmprMeasureCommandSizeMapEnd", &amprMeasureCommandSizePopMarker), .expect_id = "iwTNhyaemnw" },
    .{ .name = "sceAmprMeasureCommandSizeSetMarkerWithColor", .function = trace.wrap("sceAmprMeasureCommandSizeSetMarkerWithColor", &amprMeasureCommandSizeSetMarkerWithColor), .expect_id = "tmfr97+ED5I" },
    .{ .name = "sceAmprMeasureCommandSizeSetMarker", .function = trace.wrap("sceAmprMeasureCommandSizeSetMarker", &amprMeasureCommandSizeSetMarker), .expect_id = "VGkEj4d6-Kg" },
    .{ .name = "sceAmprMeasureCommandSizePushMarkerWithColor", .function = trace.wrap("sceAmprMeasureCommandSizePushMarkerWithColor", &amprMeasureCommandSizeSetMarkerWithColor), .expect_id = "3OfeY4pzDV0" },
    .{ .name = "sceAmprMeasureCommandSizePushMarker", .function = trace.wrap("sceAmprMeasureCommandSizePushMarker", &amprMeasureCommandSizeSetMarker), .expect_id = "0RdLmAh7WVo" },
    .{ .name = "sceAmprMeasureCommandSizePopMarker", .function = trace.wrap("sceAmprMeasureCommandSizePopMarker", &amprMeasureCommandSizePopMarker), .expect_id = "pbnNnahE8vk" },
    .{ .name = "sceAmprAmmMeasureAmmCommandSizeMap", .function = trace.wrap("sceAmprAmmMeasureAmmCommandSizeMap", &amprMeasureAmmCommandSizeMap), .expect_id = "6hbai6KIXkk" },
    .{ .name = "sceAmprAmmMeasureAmmCommandSizeMapWithGpuMaskId", .function = trace.wrap("sceAmprAmmMeasureAmmCommandSizeMapWithGpuMaskId", &amprMeasureAmmCommandSizeMapWithGpuMaskId), .expect_id = "m+fYyX8oFqw" },
    .{ .name = "sceAmprAmmMeasureAmmCommandSizeMapDirect", .function = trace.wrap("sceAmprAmmMeasureAmmCommandSizeMapDirect", &amprMeasureAmmCommandSizeMapDirect), .expect_id = "ZFDZoN9IbVU" },
    .{ .name = "sceAmprAmmMeasureAmmCommandSizeMapDirectWithGpuMaskId", .function = trace.wrap("sceAmprAmmMeasureAmmCommandSizeMapDirectWithGpuMaskId", &amprMeasureAmmCommandSizeMapDirectWithGpuMaskId), .expect_id = "KUjtdPZJo5I" },
    .{ .name = "sceAmprAmmMeasureAmmCommandSizeUnmap", .function = trace.wrap("sceAmprAmmMeasureAmmCommandSizeUnmap", &amprMeasureAmmCommandSizeUnmap), .expect_id = "Ayg6PIon2wA" },
    .{ .name = "sceAmprAmmGiveDirectMemory", .function = trace.wrap("sceAmprAmmGiveDirectMemory", &amprAmmGiveDirectMemory), .expect_id = "Q07J7XpvhrU" },
    .{ .name = "sceAmprAmmGetVirtualAddressRanges", .function = trace.wrap("sceAmprAmmGetVirtualAddressRanges", &amprAmmGetVirtualAddressRanges), .expect_id = "wkQR9+xTFKY" },
    .{ .name = "sceAmprAmmGetUsageStatsData", .function = trace.wrap("sceAmprAmmGetUsageStatsData", &amprAmmGetUsageStatsData), .expect_id = "KqiWXLgCVe0" },
    .{ .name = "sceAmprAmmSetPageTablePoolOccupancyNotificationThreshold", .function = trace.wrap("sceAmprAmmSetPageTablePoolOccupancyNotificationThreshold", &amprAmmSetPageTablePoolOccupancyNotificationThreshold), .expect_id = "touqMEt6qXQ" },
    .{ .name = "sceAmprAmmCommandBufferConstructor", .function = trace.wrap("sceAmprAmmCommandBufferConstructor", &amprAmmCommandBufferConstructor), .expect_id = "EDq5bqCqYpA" },
    .{ .name = "sceAmprAmmCommandBufferDestructor", .function = trace.wrap("sceAmprAmmCommandBufferDestructor", &amprAmmCommandBufferDestructor), .expect_id = "pvUFDOHilnE" },
    .{ .name = "sceAmprAmmCommandBufferMap", .function = trace.wrap("sceAmprAmmCommandBufferMap", &amprAmmCommandBufferMap), .expect_id = "JEVYGhDc97M" },
    .{ .name = "sceAmprAmmCommandBufferMapWithGpuMaskId", .function = trace.wrap("sceAmprAmmCommandBufferMapWithGpuMaskId", &amprAmmCommandBufferMapWithGpuMaskId), .expect_id = "ojBkmG7+CgE" },
    .{ .name = "sceAmprAmmCommandBufferMapDirect", .function = trace.wrap("sceAmprAmmCommandBufferMapDirect", &amprAmmCommandBufferMapDirect), .expect_id = "8TBE+9XCZbI" },
    .{ .name = "sceAmprAmmCommandBufferMapDirectWithGpuMaskId", .function = trace.wrap("sceAmprAmmCommandBufferMapDirectWithGpuMaskId", &amprAmmCommandBufferMapDirectWithGpuMaskId), .expect_id = "kOfZlhbVAkc" },
    .{ .name = "sceAmprAmmCommandBufferUnmap", .function = trace.wrap("sceAmprAmmCommandBufferUnmap", &amprAmmCommandBufferUnmap), .expect_id = "M-VFI2DJWQA" },
    .{ .name = "sceAmprAmmSubmitCommandBuffer", .function = trace.wrap("sceAmprAmmSubmitCommandBuffer", &amprAmmSubmitCommandBuffer), .expect_id = "lwS-7y3jcBI" },
    .{ .name = "sceAmprAmmSubmitCommandBuffer3", .function = trace.wrap("sceAmprAmmSubmitCommandBuffer3", &amprAmmSubmitCommandBufferAndGetId), .expect_id = "NnKhlMJtIsI" },
    .{ .name = "sceAmprAmmSubmitCommandBuffer2", .function = trace.wrap("sceAmprAmmSubmitCommandBuffer2", &amprAmmSubmitCommandBufferAndGetResult), .expect_id = "OJf3vCckPAM" },
    .{ .name = "sceAmprAmmWaitCommandBufferCompletion", .function = trace.wrap("sceAmprAmmWaitCommandBufferCompletion", &amprAmmWaitCommandBufferCompletion), .expect_id = "HXymib4T8gc" },
};

pub fn reset() void {
    agc_shader_registry.reset();
    agc_submit.reset();
    video_out.reset();
    random_state.store(0x9e37_79b9_7f4a_7c15, .monotonic);
    next_save_data_resource.store(1, .monotonic);
}

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, .{ .name = "libScePosix" }, .{ .name = "libkernel" }, &posix_exports);
    try db.addLibrary(gpa, .{ .name = "libSceRandom" }, .{ .name = "libSceRandom" }, &random_exports);
    try db.addLibrary(gpa, .{ .name = "libSceVideoOut" }, .{ .name = "libSceVideoOut" }, &video_out_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAvPlayer" }, .{ .name = "libSceAvPlayer", .version_minor = 0 }, &av_player.exports);
    try db.addLibrary(gpa, .{ .name = "libSceAppContent" }, .{ .name = "libSceAppContentUtil" }, &app_content_exports);
    try db.addLibrary(gpa, .{ .name = "libSceNpManager" }, .{ .name = "libSceNpManager" }, &np_manager_exports);
    try db.addLibrary(gpa, .{ .name = "libSceRemoteplay" }, .{ .name = "libSceRemoteplay" }, &remoteplay_exports);
    try db.addLibrary(gpa, .{ .name = "libSceMouse" }, .{ .name = "libSceMouse" }, &mouse_exports);
    try db.addLibrary(gpa, .{ .name = "libSceSaveData_native" }, .{ .name = "libSceSaveData_native" }, &save_data_exports);
    try db.addLibrary(gpa, .{ .name = "libSceSysmodule" }, .{ .name = "libSceSysmodule" }, &sysmodule_bootstrap_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAgc" }, .{ .name = "libSceAgc" }, &agc_exports);
    try db.addLibrary(gpa, .{ .name = "libSceAgcDriver" }, .{ .name = "libSceAgcDriver" }, &agc_driver_exports);
    // The submission entry points live apart from these, because unlike the
    // rest of this surface they read what the title passes rather than only
    // acknowledging it.
    try db.addLibrary(gpa, .{ .name = "libSceAgcDriver" }, .{ .name = "libSceAgcDriver" }, &agc_submit.exports);
    try db.addLibrary(gpa, .{ .name = "libSceAmpr" }, .{ .name = "libSceAmpr" }, &ampr_exports);
}

test "bootstrap AGC commands are one walkable PM4 NOP" {
    var words: [32]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try std.testing.expect(agcCommand(&command_buffer, 0, 0, 0, 0, 0) != null);
    try std.testing.expectEqual(words[0..].ptr + 16, command_buffer.cursor_up.?);

    var walker = gpu.pm4.Walker.init(words[0..16]);
    const packet = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.nop, packet.opcode);
    try std.testing.expectEqual(@as(usize, 16), packet.wordCount());
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC release publishes a walkable custom fence packet" {
    var words: [8]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    const address: u64 = 0x1234_5678_9abc_def0;
    const data: u64 = 0xfedc_ba98_7654_3210;
    try std.testing.expect(agcReleaseMem(
        &command_buffer,
        0x28,
        0x345,
        1,
        2,
        address,
        2,
        data,
        0,
        0,
        1,
        7,
    ) != null);

    var walker = gpu.pm4.Walker.init(&words);
    const release = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.custom.release_mem, gpu.pm4.customCode(release).?);
    try std.testing.expectEqual(@as(usize, 8), release.wordCount());
    try std.testing.expectEqual(@as(u32, @truncate(address)), release.body[2]);
    try std.testing.expectEqual(@as(u32, @truncate(address >> 32)), release.body[3]);
    try std.testing.expectEqual(@as(u32, @truncate(data)), release.body[4]);
    try std.testing.expectEqual(@as(u32, @truncate(data >> 32)), release.body[5]);
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC wait packet keeps its copied address patchable" {
    var words: [7]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try std.testing.expect(agcWaitRegMem(&command_buffer, 0, 3, 0, 0, 0, 1, 0xffff_ffff, 16) != null);
    const patched_address: u64 = 0x0000_8833_0c05_00;
    try std.testing.expectEqual(errno.ok, agcWaitRegMemPatchAddress(@intFromPtr(&words), patched_address));

    var walker = gpu.pm4.Walker.init(&words);
    const wait = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.custom.wait_mem_32, gpu.pm4.customCode(wait).?);
    try std.testing.expectEqual(@as(u32, @truncate(patched_address)), wait.body[0]);
    try std.testing.expectEqual(@as(u32, @truncate(patched_address >> 32)), wait.body[1]);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), wait.body[2]);
    try std.testing.expectEqual(@as(u32, 1), wait.body[3]);
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC emits event acquire and patchable DMA packets" {
    var words: [48]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try std.testing.expect(agcEventWrite(&command_buffer, 16, 0) != null);
    const dma_command = agcDmaData(
        &command_buffer,
        0,
        3,
        0,
        0,
        2,
        0,
        0x1122_3344,
        256,
        1,
        1,
        0,
    ).?;
    try std.testing.expect(agcAcquireMem(&command_buffer, 1, 0, 0x9000, 0, 0x20, 40) != null);

    const used = (@intFromPtr(command_buffer.cursor_up.?) - @intFromPtr(words[0..].ptr)) / @sizeOf(u32);
    var walker = gpu.pm4.Walker.init(words[0..used]);
    const event = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.event_write, event.opcode);
    try std.testing.expectEqual(@as(u32, 0x410), event.body[0]);

    const dma = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.dma_data, dma.opcode);
    const dma_address = @intFromPtr(dma_command);
    try std.testing.expectEqual(errno.ok, agcDmaDataPatchDestination(dma_address, 0x1234_5678_9abc_def0));
    try std.testing.expectEqual(errno.ok, agcDmaDataPatchSource(dma_address, 0xfedc_ba98_7654_3210));
    try std.testing.expectEqual(@as(u32, 0x9abc_def0), dma.body[3]);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), dma.body[4]);
    try std.testing.expectEqual(@as(u32, 0x7654_3210), dma.body[1]);
    try std.testing.expectEqual(@as(u32, 0xfedc_ba98), dma.body[2]);

    const acquire = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.custom.acquire_mem, gpu.pm4.customCode(acquire).?);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), acquire.body[0]);
    try std.testing.expectEqual(@as(u32, 1), acquire.body[5]);
    try std.testing.expectEqual(@as(u32, 0x9000), acquire.body[6]);
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC emits exact dispatch draw and instance packets" {
    var words: [48]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try std.testing.expect(agcDispatch(&command_buffer, 3, 5, 7, 0, 0) != null);
    try std.testing.expect(agcDrawIndex(&command_buffer, 6, 0x1234_5600, 0x4000_0000, 0, 0) != null);
    try std.testing.expect(agcSetNumInstances(&command_buffer, 2, 0, 0, 0, 0) != null);
    try std.testing.expectEqual(words[0..].ptr + 13, command_buffer.cursor_up.?);

    var walker = gpu.pm4.Walker.init(words[0..13]);
    const dispatch = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.dispatch_direct, dispatch.opcode);
    try std.testing.expectEqualSlices(u32, &.{ 3, 5, 7, 0x41 }, dispatch.body);

    const draw = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.draw_index_2, draw.opcode);
    try std.testing.expectEqualSlices(u32, &.{ 6, 0x1234_5600, 0, 6, 0 }, draw.body);

    const instances = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.num_instances, instances.opcode);
    try std.testing.expectEqualSlices(u32, &.{2}, instances.body);
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC emits exact draw-index-auto packet" {
    var words: [3]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try std.testing.expectEqual(@as(u32, 12), agcDrawIndexAutoGetSize());
    try std.testing.expect(agcDrawIndexAuto(&command_buffer, 3, 0x4000_0000) != null);
    try std.testing.expectEqual(words[0..].ptr + words.len, command_buffer.cursor_up.?);

    var walker = gpu.pm4.Walker.init(&words);
    const draw = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.draw_index_auto, draw.opcode);
    try std.testing.expectEqualSlices(u32, &.{ 3, 0x2 }, draw.body);
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC emits indexed-buffer state and offset draw packets" {
    var words: [13]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    const address: u64 = 0x1234_5678_9abc_def0;
    try std.testing.expect(agcSetIndexBuffer(&command_buffer, address) != null);
    try std.testing.expect(agcSetIndexCount(&command_buffer, 0x200) != null);
    try std.testing.expect(agcSetIndexTypeIndexed(&command_buffer, 2, 1, 1) != null);
    try std.testing.expectEqual(@as(u32, 20), agcDrawIndexOffsetGetSize());
    try std.testing.expect(agcDrawIndexOffset(&command_buffer, 5, 12, 0) != null);
    try std.testing.expectEqual(words[0..].ptr + words.len, command_buffer.cursor_up.?);

    var walker = gpu.pm4.Walker.init(&words);
    const base = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.index_base, base.opcode);
    try std.testing.expectEqualSlices(u32, &.{ 0x9abc_def0, 0x1234_5678 }, base.body);

    const count = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.index_buffer_size, count.opcode);
    try std.testing.expectEqualSlices(u32, &.{0x200}, count.body);

    const index_type = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.set_uconfig_reg_index, index_type.opcode);
    try std.testing.expectEqualSlices(u32, &.{ 0x2000_0243, 0x4442 }, index_type.body);

    const draw = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.draw_index_offset_2, draw.opcode);
    try std.testing.expectEqualSlices(u32, &.{ 12, 5, 12, 0 }, draw.body);
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC emits exact native indirect register packets" {
    var words: [48]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    const address: u64 = 0x1234_5678_9abc_def0;
    try std.testing.expect(agcSetCxRegistersIndirect(&command_buffer, address, 7, 0, 0, 0) != null);
    try std.testing.expect(agcSetShRegistersIndirect(&command_buffer, address + 8, 11, 0, 0, 0) != null);
    try std.testing.expect(agcSetUcRegistersIndirect(&command_buffer, address + 16, 3, 0, 0, 0) != null);
    try std.testing.expectEqual(words[0..].ptr + 15, command_buffer.cursor_up.?);

    var walker = gpu.pm4.Walker.init(words[0..15]);
    const expected = [_]u8{
        gpu.pm4.set_context_reg_indirect,
        gpu.pm4.set_sh_reg_indirect,
        gpu.pm4.set_uconfig_reg_indirect,
    };
    for (expected) |opcode| try std.testing.expectEqual(opcode, (try walker.next()).?.opcode);
    try std.testing.expect((try walker.next()) == null);
    try std.testing.expectEqual(@as(u32, @truncate(address)) & 0xffff_fffc, words[1]);
    try std.testing.expectEqual(@as(u32, @truncate(address >> 32)), words[2]);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), words[3]);
    try std.testing.expectEqual(@as(u32, 7), words[4]);
}

test "bootstrap AGC patches native indirect register packets" {
    var words: [48]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    const cx_command = agcSetCxRegistersIndirect(&command_buffer, 8, 0, 0, 0, 0).?;
    const sh_command = agcSetShRegistersIndirect(&command_buffer, 8, 0, 0, 0, 0).?;
    const uc_command = agcSetUcRegistersIndirect(&command_buffer, 8, 0, 0, 0, 0).?;

    const cx_address: u64 = 0x1234_5678_9abc_def1;
    const sh_address: u64 = 0x2234_5678_8765_4322;
    const uc_address: u64 = 0x3234_5678_1020_3043;
    try std.testing.expectEqual(errno.ok, agcSetCxRegIndirectPatchSetAddress(@intFromPtr(cx_command), cx_address));
    try std.testing.expectEqual(errno.ok, agcSetShRegIndirectPatchSetAddress(@intFromPtr(sh_command), sh_address));
    try std.testing.expectEqual(errno.ok, agcSetUcRegIndirectPatchSetAddress(@intFromPtr(uc_command), uc_address));
    try std.testing.expectEqual(errno.ok, agcSetCxRegIndirectPatchAddRegisters(@intFromPtr(cx_command), 10));
    try std.testing.expectEqual(errno.ok, agcSetCxRegIndirectPatchAddRegisters(@intFromPtr(cx_command), 5));
    try std.testing.expectEqual(errno.ok, agcSetShRegIndirectPatchSetNumRegisters(@intFromPtr(sh_command), 0x400b));
    try std.testing.expectEqual(errno.ok, agcSetUcRegIndirectPatchAddRegisters(@intFromPtr(uc_command), 3));

    try std.testing.expectEqual(@as(u32, @truncate(cx_address)) & 0xffff_fffc, cx_command[1]);
    try std.testing.expectEqual(@as(u32, @truncate(cx_address >> 32)), cx_command[2]);
    try std.testing.expectEqual(@as(u32, 15), cx_command[4] & 0x3fff);
    try std.testing.expectEqual(@as(u32, @truncate(sh_address)) & 0xffff_fffc, sh_command[1]);
    try std.testing.expectEqual(@as(u32, 11), sh_command[4] & 0x3fff);
    try std.testing.expectEqual(@as(u32, @truncate(uc_address)) & 0xffff_fffc, uc_command[1]);
    try std.testing.expectEqual(@as(u32, 3), uc_command[4] & 0x3fff);
    try std.testing.expectEqual(
        graphics_error_invalid_packet,
        agcSetShRegIndirectPatchAddRegisters(@intFromPtr(cx_command), 1),
    );
}

test "bootstrap AGC emits a backend-visible flip packet" {
    var words: [6]u32 = @splat(0xdead_beef);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    const argument: i64 = @bitCast(@as(u64, 0x0123_4567_89ab_cdef));
    try std.testing.expect(agcSetFlip(&command_buffer, 4, -2, 1, argument) != null);

    var walker = gpu.pm4.Walker.init(&words);
    const flip = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.nop, flip.opcode);
    try std.testing.expectEqual(@as(?u6, gpu.pm4.custom.flip), gpu.pm4.customCode(flip));
    try std.testing.expectEqualSlices(u32, &.{
        4,
        @bitCast(@as(i32, -2)),
        1,
        0x89ab_cdef,
        0x0123_4567,
    }, flip.body);
    try std.testing.expect((try walker.next()) == null);
}

test "bootstrap AGC shader range uses its exact variable packet size" {
    var words: [24]u32 = @splat(0xdead_beef);
    var values: [16]u32 = undefined;
    for (&values, 0..) |*value, index| value.* = @intCast(0x100 + index);
    var command_buffer = AgcCommandBuffer{
        .bottom = words[0..].ptr,
        .top = words[0..].ptr + words.len,
        .cursor_up = words[0..].ptr,
        .cursor_down = null,
        .callback = null,
        .user_data = null,
        .reserved_dwords = 0,
    };
    try std.testing.expectEqual(@as(u32, 72), agcSetShRegisterRangeDirectGetSize(values.len));
    try std.testing.expect(agcSetShRegisterRangeDirect(
        &command_buffer,
        0x240,
        @intFromPtr(&values),
        values.len,
        0,
        0,
    ) != null);
    try std.testing.expectEqual(words[0..].ptr + 18, command_buffer.cursor_up.?);

    var walker = gpu.pm4.Walker.init(words[0..18]);
    const packet = (try walker.next()).?;
    try std.testing.expectEqual(gpu.pm4.set_sh_reg, packet.opcode);
    try std.testing.expectEqual(@as(usize, 18), packet.wordCount());
    try std.testing.expectEqual(@as(u32, 0x240), packet.body[0]);
    try std.testing.expectEqualSlices(u32, &values, packet.body[1..]);
    try std.testing.expect((try walker.next()) == null);
}

test "shader creation relocates its header and builds primitive state" {
    var header: [shader_structure_size]u8 align(8) = @splat(0);
    var registers = [_]ShaderRegister{
        .{ .offset = 0x0c8, .value = 0x100 },
        .{ .offset = 0x0c9, .value = 0xabcd_ef00 },
    };
    var specials = [_]ShaderRegister{
        .{ .offset = 0x100, .value = 1 },
        .{ .offset = 0x101, .value = 2 },
        .{ .offset = 0x102, .value = 3 },
        .{ .offset = 0x103, .value = 4 },
        .{ .offset = 0x104, .value = 5 },
        .{ .offset = 0x105, .value = 6 },
    };
    var code: [16]u8 align(256) = @splat(0);

    std.mem.writeInt(u32, header[0..4], shader_file_header, .little);
    std.mem.writeInt(u32, header[4..8], shader_version, .little);
    header[shader_type_offset] = 2;
    header[shader_sh_register_count_offset] = registers.len;

    const header_address = @intFromPtr(&header);
    const register_field = header_address + shader_sh_registers_offset;
    const specials_field = header_address + shader_specials_offset;
    @as(*u64, @ptrFromInt(register_field)).* = @intFromPtr(&registers) -% register_field;
    @as(*u64, @ptrFromInt(specials_field)).* = @intFromPtr(&specials) -% specials_field;

    var shader: ?*anyopaque = null;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreateShader(&shader, &header, @ptrCast(&code)),
    );
    try std.testing.expectEqual(@intFromPtr(&header), @intFromPtr(shader.?));
    try std.testing.expectEqual(@intFromPtr(&registers), @as(*const u64, @ptrFromInt(register_field)).*);
    try std.testing.expectEqual(@intFromPtr(&specials), @as(*const u64, @ptrFromInt(specials_field)).*);
    try std.testing.expectEqual(@intFromPtr(&code), @as(*const u64, @ptrFromInt(header_address + shader_code_offset)).*);
    const expected_program_address = @intFromPtr(&code) + 0x1_0000;
    try std.testing.expectEqual(@as(u32, @truncate(expected_program_address >> 8)), registers[0].value);
    try std.testing.expectEqual(
        @as(u32, 0xabcd_ef00) | @as(u32, @truncate(expected_program_address >> 40)),
        registers[1].value,
    );
    try std.testing.expectEqual(@as(?u64, header_address), agc_shader_registry.find(@intFromPtr(&code)));
    try std.testing.expectEqual(@as(?u64, header_address), agc_shader_registry.find(expected_program_address));

    var cx: [2]ShaderRegister = undefined;
    var uc: [3]ShaderRegister = undefined;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreatePrimState(&cx, &uc, null, @ptrCast(&header), 4, 0),
    );
    try std.testing.expectEqual(specials[1], cx[0]);
    try std.testing.expectEqual(specials[4], cx[1]);
    try std.testing.expectEqual(specials[0], uc[0]);
    try std.testing.expectEqual(specials[5], uc[1]);
    try std.testing.expectEqual(@as(u32, 0x242), uc[2].offset);
    try std.testing.expectEqual(@as(u32, 4), uc[2].value);
}

test "shader creation accepts a fused front half without program registers" {
    var header: [shader_structure_size]u8 align(8) = @splat(0);
    var code: [16]u8 align(256) = @splat(0);
    std.mem.writeInt(u32, header[0..4], shader_file_header, .little);
    std.mem.writeInt(u32, header[4..8], shader_version, .little);
    header[shader_type_offset] = 4;

    var shader: ?*anyopaque = null;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreateShader(&shader, &header, @ptrCast(&code)),
    );
    try std.testing.expectEqual(@intFromPtr(&header), @intFromPtr(shader.?));
    try std.testing.expectEqual(
        @as(?u64, @intFromPtr(&header)),
        agc_shader_registry.find(@intFromPtr(&code)),
    );
}

test "shader creation accepts four-byte-aligned AGC headers" {
    agc_shader_registry.reset();
    defer agc_shader_registry.reset();

    var storage: [shader_structure_size + 4]u8 align(8) = @splat(0);
    var specials = [_]ShaderRegister{
        .{ .offset = 0x100, .value = 1 },
        .{ .offset = 0x101, .value = 2 },
        .{ .offset = 0x102, .value = 3 },
        .{ .offset = 0x103, .value = 4 },
        .{ .offset = 0x104, .value = 5 },
        .{ .offset = 0x105, .value = 6 },
    };
    var code: [16]u8 align(256) = @splat(0);
    const header = storage[4..][0..shader_structure_size];
    std.mem.writeInt(u32, header[0..4], shader_file_header, .little);
    std.mem.writeInt(u32, header[4..8], shader_version, .little);
    header[shader_type_offset] = 4;

    const header_address = @intFromPtr(header.ptr);
    try std.testing.expectEqual(@as(u64, 4), header_address & 7);
    const specials_field = header_address + shader_specials_offset;
    writeGuestU64(specials_field, @intFromPtr(&specials) -% specials_field);

    var shader: ?*anyopaque = null;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreateShader(&shader, @ptrFromInt(header_address), @ptrCast(&code)),
    );
    try std.testing.expectEqual(header_address, @intFromPtr(shader.?));
    try std.testing.expectEqual(@intFromPtr(&specials), readGuestU64(specials_field));
    try std.testing.expectEqual(@intFromPtr(&code), readGuestU64(header_address + shader_code_offset));

    var cx: [2]ShaderRegister = undefined;
    var uc: [3]ShaderRegister = undefined;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreatePrimState(&cx, &uc, null, @ptrFromInt(header_address), 4, 0),
    );
    try std.testing.expectEqual(specials[1], cx[0]);
    try std.testing.expectEqual(specials[4], cx[1]);
}

test "fuse shader halves patches ES program and keeps front header lookup" {
    agc_shader_registry.reset();
    defer agc_shader_registry.reset();

    var front: [shader_structure_size]u8 align(8) = @splat(0);
    var back: [shader_structure_size]u8 align(8) = @splat(0);
    var fused: [shader_structure_size]u8 align(8) = @splat(0);
    var front_registers = [_]ShaderRegister{
        .{ .offset = spi_shader_pgm_chksum_gs, .value = 0x1111_1111 },
        .{ .offset = spi_shader_pgm_chksum_gs, .value = 0x2222_2222 },
    };
    var back_registers = [_]ShaderRegister{
        .{ .offset = 0x088, .value = 0 }, // GS PGM for CreateShader(type=6)
        .{ .offset = 0x089, .value = 0 },
        .{ .offset = spi_shader_pgm_lo_es, .value = 0 },
        .{ .offset = spi_shader_pgm_lo_es + 1, .value = 0 },
        .{ .offset = spi_shader_pgm_chksum_gs, .value = 0 },
        .{ .offset = spi_shader_pgm_chksum_gs, .value = 0 },
    };
    var scratch: [6]ShaderRegister = undefined;
    var front_code: [16]u8 align(256) = @splat(0);
    var back_code: [16]u8 align(256) = @splat(0);

    std.mem.writeInt(u32, front[0..4], shader_file_header, .little);
    std.mem.writeInt(u32, front[4..8], shader_version, .little);
    front[shader_type_offset] = 4;
    front[shader_sh_register_count_offset] = front_registers.len;
    const front_address = @intFromPtr(&front);
    @as(*u64, @ptrFromInt(front_address + shader_sh_registers_offset)).* =
        @intFromPtr(&front_registers) -% (front_address + shader_sh_registers_offset);

    std.mem.writeInt(u32, back[0..4], shader_file_header, .little);
    std.mem.writeInt(u32, back[4..8], shader_version, .little);
    back[shader_type_offset] = 6;
    back[shader_sh_register_count_offset] = back_registers.len;
    const back_address = @intFromPtr(&back);
    @as(*u64, @ptrFromInt(back_address + shader_sh_registers_offset)).* =
        @intFromPtr(&back_registers) -% (back_address + shader_sh_registers_offset);

    var front_shader: ?*anyopaque = null;
    var back_shader: ?*anyopaque = null;
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreateShader(&front_shader, &front, @ptrCast(&front_code)),
    );
    try std.testing.expectEqual(
        @as(i32, 0),
        agcCreateShader(&back_shader, &back, @ptrCast(&back_code)),
    );

    var size_align: SizeAlign = .{ .size = 0, .align_bytes = 0 };
    try std.testing.expectEqual(
        @as(i32, 0),
        agcGetFusedShaderSize(&size_align, &front, &back),
    );
    try std.testing.expectEqual(@as(u64, back_registers.len * @sizeOf(ShaderRegister)), size_align.size);
    try std.testing.expectEqual(fused_shader_scratch_align, size_align.align_bytes);

    try std.testing.expectEqual(
        @as(i32, 0),
        agcFuseShaderHalves(&fused, &front, &back, &scratch),
    );
    try std.testing.expectEqual(@as(u8, 2), fused[shader_type_offset]);
    try std.testing.expectEqual(@as(u64, 0), @as(*const u64, @ptrFromInt(@intFromPtr(&fused) + shader_user_data_offset)).*);
    try std.testing.expectEqual(@intFromPtr(&scratch), @as(*const u64, @ptrFromInt(@intFromPtr(&fused) + shader_sh_registers_offset)).*);

    const front_code_address = @intFromPtr(&front_code);
    // Scratch is a copy of back_registers; ES PGM pair is at indices 2/3.
    try std.testing.expectEqual(@as(u32, @truncate(front_code_address >> 8)), scratch[2].value);
    try std.testing.expectEqual(@as(u32, 0x1111_1111), scratch[4].value);
    try std.testing.expectEqual(@as(u32, 0x2222_2222), scratch[5].value);
    try std.testing.expectEqual(
        @as(?u64, front_address),
        agc_shader_registry.find(front_code_address),
    );
}

test "bootstrap service libraries register the title link surface" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    try std.testing.expect(db.findById("Up36PTk687E", .function) != null);
    try std.testing.expect(db.findById("PI7jIZj4pcE", .function) != null);
    try std.testing.expect(db.findById("YUeqkyT7mEQ", .function) != null);
    try std.testing.expect(db.findByName("sceAgcDcbDrawIndexOffset", .function) != null);
    try std.testing.expect(db.findById("mZSbNJVJpV8", .function) != null);
    try std.testing.expect(db.findById("Jg-AgkdJHkk", .function) != null);
    try std.testing.expect(db.findById("BVmR1H8l+XI", .function) != null);
    try std.testing.expect(db.findById("YPxkUDhgoNI", .function) != null);
    try std.testing.expect(db.findById("DLfoNxTFNVk", .function) != null);
    try std.testing.expect(db.findById("j0+3uJMxYJY", .function) != null);
    try std.testing.expect(db.findById("Eul7AGEpjLo", .function) != null);
    try std.testing.expect(db.findById("4quckD2y7Pg", .function) != null);
    try std.testing.expect(db.findById("JEVYGhDc97M", .function) != null);
    try std.testing.expect(db.findById("8TBE+9XCZbI", .function) != null);
    try std.testing.expect(db.findById("M-VFI2DJWQA", .function) != null);
    try std.testing.expect(db.findById("Q07J7XpvhrU", .function) != null);
}

test "AMPR gather and scatter sizes match the recorded command stream" {
    try std.testing.expectEqual(@as(u64, 0x08), amprMeasureCommandSizeReadFileGather(16, 0));
    try std.testing.expectEqual(@as(u64, 0x0c), amprMeasureCommandSizeReadFileGather(16, 0x40000));
    try std.testing.expectEqual(@as(u64, 0x0c), amprMeasureCommandSizeReadFileScatter(1, 16));
    try std.testing.expectEqual(@as(u64, 0x10), amprMeasureCommandSizeReadFileGatherScatter(1, 16, 0));
    try std.testing.expectEqual(@as(u64, 0x14), amprMeasureCommandSizeReadFileGatherScatter(1, 16, 1 << 32));
    try std.testing.expectEqual(@as(u64, 0x04), amprMeasureCommandSizeResetGatherScatterState(0, 0, 0));
    try std.testing.expect(amprMeasureCommandSizeReadFileGather(0, 0) != 0x08);
}

test "AMPR gather and scatter continue a recorded file read" {
    apr.reset();
    defer apr.reset();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const file = try temporary.dir.createFile(io, "stream.bin", .{});
    try file.writeStreamingAll(io, "abcdefghijkl");
    file.close(io);
    filesystem.attach(io, temporary.dir);
    defer filesystem.detach();

    var header: [ampr_command_buffer_header_size]u8 align(8) = @splat(0);
    var storage: [0x100]u8 align(4) = @splat(0);
    const address = @intFromPtr(&header);
    try std.testing.expectEqual(errno.ok, amprCommandBufferConstructor(address));
    try std.testing.expectEqual(
        errno.ok,
        amprCommandBufferSetBuffer(address, @intFromPtr(&storage), storage.len),
    );
    const resolved = try apr.resolve("/app0/stream.bin");
    var destination: [12]u8 = undefined;
    try std.testing.expectEqual(errno.ok, amprAprCommandBufferReadFile(
        address,
        0,
        0,
        resolved.identifier,
        @intFromPtr(&destination),
        4,
        0,
    ));
    try std.testing.expectEqual(errno.ok, amprAprCommandBufferReadFileGather(address, 0, 0, 4, 4));
    try std.testing.expectEqual(errno.ok, amprAprCommandBufferReadFileScatter(
        address,
        0,
        0,
        @intFromPtr(&destination) + 8,
        4,
    ));
    _ = try apr.submitCommandBuffer(address);
    try std.testing.expectEqualStrings("abcdefghijkl", &destination);
    try std.testing.expectEqual(@as(u64, 0x30 + 0x08 + 0x0c), amprCommandBufferGetCurrentOffset(address));
    try std.testing.expectEqual(errno.ok, amprAprCommandBufferResetGatherScatterState(address, 0, 0));
    try std.testing.expectEqual(
        errno.KernelError.einval.raw(),
        amprAprCommandBufferReadFileGather(address, 0, 0, 4, 0),
    );
}

test "AMPR map wait write and markers record the measured sizes" {
    apr.reset();
    defer apr.reset();
    var header: [ampr_command_buffer_header_size]u8 align(8) = @splat(0);
    var storage: [0x200]u8 align(4) = @splat(0);
    const address = @intFromPtr(&header);
    try std.testing.expectEqual(errno.ok, amprCommandBufferConstructor(address));
    try std.testing.expectEqual(
        errno.ok,
        amprCommandBufferSetBuffer(address, @intFromPtr(&storage), storage.len),
    );

    try std.testing.expectEqual(@as(u64, 0x20), amprMeasureCommandSizeFixed32(0, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(u64, 4), amprMeasureCommandSizeNop(0));
    try std.testing.expectEqual(@as(u64, 12), amprMeasureCommandSizeNop(3));
    try std.testing.expectEqual(@as(u64, 8), amprMeasureCommandSizeSetMarker("hi"));
    try std.testing.expectEqual(@as(u64, 12), amprMeasureCommandSizeSetMarkerWithColor("hi", 0));
    try std.testing.expectEqual(@as(u64, 4), amprMeasureCommandSizePopMarker());
    try std.testing.expectEqual(@as(u64, 0x0c), amprMeasureCommandSizeMapBegin(0x10000, 0x4000, 0, 0));
    try std.testing.expect(amprMeasureCommandSizeMapBegin(1, 0x4000, 0, 0) != 0x0c);
    try std.testing.expectEqual(@as(u64, 0x10), amprMeasureCommandSizeMapDirectBegin(0x10000, 0, 0x4000, 0, 0));
    try std.testing.expect(amprMeasureCommandSizeMapDirectBegin(0x10000, 1, 0x4000, 0, 0) != 0x10);

    try std.testing.expectEqual(errno.KernelError.einval.raw(), amprAprCommandBufferMapBegin(address, 1, 0x4000, 0, 0));
    try std.testing.expectEqual(
        errno.KernelError.einval.raw(),
        amprAprCommandBufferMapDirectBegin(address, 0x10000, 1, 0x4000, 0, 0),
    );
    try std.testing.expectEqual(errno.KernelError.eperm.raw(), amprAprCommandBufferMapEnd(address));
    try std.testing.expectEqual(@as(u64, 0), amprCommandBufferGetType(address));
    try std.testing.expectEqual(errno.ok, amprAprCommandBufferMapBegin(address, 0x10000, 0x4000, 0, 0));
    try std.testing.expectEqual(ampr_type_map_active, amprCommandBufferGetType(address));
    try std.testing.expectEqual(errno.ok, amprAprCommandBufferMapEnd(address));
    try std.testing.expectEqual(@as(u64, 0), amprCommandBufferGetType(address));
    try std.testing.expectEqual(errno.KernelError.eperm.raw(), amprAprCommandBufferMapEnd(address));
    try std.testing.expectEqual(errno.ok, amprAprCommandBufferMapDirectBegin(address, 0x10000, 0, 0x4000, 0, 0));
    try std.testing.expectEqual(ampr_type_map_active, amprCommandBufferGetType(address));
    try std.testing.expectEqual(errno.ok, amprAprCommandBufferMapEnd(address));

    try std.testing.expectEqual(errno.KernelError.einval.raw(), amprCommandBufferNop(address, 0));
    try std.testing.expectEqual(errno.KernelError.einval.raw(), amprCommandBufferNop(address, 17));
    try std.testing.expectEqual(errno.KernelError.einval.raw(), amprCommandBufferWriteAddress(address, null, 1, 0));

    var label: u64 = 0;
    try std.testing.expectEqual(errno.ok, amprCommandBufferWriteAddress(address, &label, 0x55aa_55aa_55aa_55aa, 0));
    try std.testing.expectEqual(errno.ok, amprCommandBufferWaitOnAddress(address, &label, 0, 0, 0));
    try std.testing.expectEqual(errno.ok, amprCommandBufferWriteCounter(address, 0, 0, 0, 0, 0));
    try std.testing.expectEqual(errno.ok, amprCommandBufferSetMarker(address, "draw"));
    try std.testing.expectEqual(errno.ok, amprCommandBufferPopMarker(address));
    try std.testing.expectEqual(errno.ok, amprCommandBufferNop(address, 1));
    try std.testing.expectEqual(
        @as(u64, 0x0c + 0x04 + 0x10 + 0x04 + 0x20 + 0x20 + 0x20 + 0x0c + 0x04 + 0x04),
        amprCommandBufferGetCurrentOffset(address),
    );
    _ = try apr.submitCommandBuffer(address);
    try std.testing.expectEqual(@as(u64, 0x55aa_55aa_55aa_55aa), label);
}

test "AMM map and unmap commit direct memory at the requested VA" {
    apr.reset();
    defer apr.reset();

    var address_space = try guest_memory.AddressSpace.initWithDirectMemory(
        std.testing.allocator,
        16 * kernel_memory.page_size,
    );
    defer address_space.deinit();
    kernel_memory.init(std.testing.allocator);
    defer kernel_memory.deinit();
    kernel_memory.attachAddressSpace(&address_space);

    try std.testing.expectEqual(@as(i64, amm_map_record_size), amprMeasureAmmCommandSizeMap(0, 0, 0, 0));
    try std.testing.expectEqual(@as(i64, amm_map_direct_record_size), amprMeasureAmmCommandSizeMapDirect(0, 0, 0, 0, 0));
    try std.testing.expectEqual(@as(i64, amm_unmap_record_size), amprMeasureAmmCommandSizeUnmap(0, 0));

    var va_start: u64 = 0;
    var va_end: u64 = 0;
    amprAmmGetVirtualAddressRanges(&va_start, &va_end, null, null);
    try std.testing.expectEqual(amm_va_start, va_start);
    try std.testing.expectEqual(amm_va_start + amm_va_size, va_end);

    var stats = AmmUsageStats{ .size_in_bytes = @sizeOf(AmmUsageStats) };
    try std.testing.expectEqual(errno.ok, amprAmmGetUsageStatsData(&stats));
    try std.testing.expectEqual(@as(u16, 512), stats.num_page_table_pool_entries);
    try std.testing.expectEqual(@as(u32, 0x7), stats.ring_idle_flags);

    const map_size = kernel_memory.page_size;
    const va = guest_memory.user.start;
    try address_space.reserveFixed(va, map_size * 2);

    var dmem: i64 = -1;
    try std.testing.expectEqual(
        errno.ok,
        amprAmmGiveDirectMemory(0, @intCast(kernel_memory.direct_memory_size), map_size, map_size, amm_usage_direct, &dmem),
    );
    try std.testing.expect(dmem >= 0);

    var header: [ampr_command_buffer_header_size]u8 align(8) = @splat(0);
    var storage: [0x80]u8 align(4) = @splat(0);
    const address = @intFromPtr(&header);
    try std.testing.expectEqual(errno.ok, amprAmmCommandBufferConstructor(address));
    try std.testing.expectEqual(
        errno.ok,
        amprCommandBufferSetBuffer(address, @intFromPtr(&storage), storage.len),
    );
    try std.testing.expectEqual(
        errno.KernelError.einval.raw(),
        amprAmmCommandBufferMapDirect(address, 1, @intCast(dmem), map_size, 0, 0),
    );
    try std.testing.expectEqual(
        errno.ok,
        amprAmmCommandBufferMapDirect(
            address,
            va,
            @intCast(dmem),
            map_size,
            0,
            amm_prot_ampr_read | amm_prot_ampr_write,
        ),
    );
    try std.testing.expectEqual(@as(u64, amm_map_direct_record_size), amprCommandBufferGetCurrentOffset(address));
    try std.testing.expectEqual(errno.ok, amprAmmSubmitCommandBuffer(address, 0, 0));
    try std.testing.expect(address_space.isMapped(va, map_size));

    const mapped: *u64 = @ptrFromInt(va);
    mapped.* = 0x1122_3344_5566_7788;
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), mapped.*);

    try std.testing.expectEqual(errno.ok, amprCommandBufferReset(address));
    try std.testing.expectEqual(errno.ok, amprAmmCommandBufferUnmap(address, va, map_size));
    var submission: u32 = 0;
    try std.testing.expectEqual(errno.ok, amprAmmSubmitCommandBufferAndGetId(address, 0, 0, &submission));
    try std.testing.expect(submission != 0);
    try std.testing.expectEqual(errno.ok, amprAmmWaitCommandBufferCompletion(submission));
    try std.testing.expect(!address_space.isMapped(va, map_size));

    try std.testing.expectEqual(errno.ok, amprCommandBufferReset(address));
    try std.testing.expectEqual(
        errno.ok,
        amprAmmGiveDirectMemory(0, @intCast(kernel_memory.direct_memory_size), map_size, map_size, amm_usage_auto, &dmem),
    );
    try std.testing.expectEqual(
        errno.ok,
        amprAmmCommandBufferMap(address, va + map_size, map_size, 0, amm_prot_ampr_read | amm_prot_ampr_write),
    );
    try std.testing.expectEqual(errno.ok, amprAmmSubmitCommandBuffer(address, 0, 0));
    try std.testing.expect(address_space.isMapped(va + map_size, map_size));
}
