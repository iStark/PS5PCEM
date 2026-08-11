// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Fully-installed PlayGo profile for locally dumped titles.
//!
//! A retail package can expose content in download/install chunks. The runner
//! only starts a complete directory already present on the host, so every
//! chunk the title asks for is local and immediately usable. Unreal Engine
//! treats failure to initialize PlayGo as a platform-component failure and
//! never mounts otherwise valid cooked containers, making this service part of
//! ordinary offline boot rather than an optional network feature.

const std = @import("std");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const kernel_memory = @import("kernel_memory.zig");

const error_invalid_argument: i32 = @bitCast(@as(u32, 0x80b2_0004));
const error_not_initialized: i32 = @bitCast(@as(u32, 0x80b2_0005));
const error_already_initialized: i32 = @bitCast(@as(u32, 0x80b2_0006));
const error_bad_handle: i32 = @bitCast(@as(u32, 0x80b2_0009));
const error_bad_pointer: i32 = @bitCast(@as(u32, 0x80b2_000a));
const error_bad_size: i32 = @bitCast(@as(u32, 0x80b2_000b));
const error_bad_chunk_id: i32 = @bitCast(@as(u32, 0x80b2_000c));
const error_bad_locus: i32 = @bitCast(@as(u32, 0x80b2_0010));

const handle: u32 = 1;
const base_chunk: u16 = 0;
const locus_not_downloaded: u8 = 0;
const locus_local_slow: u8 = 2;
const locus_local_fast: u8 = 3;
const maximum_entries: u32 = 0x4000;
const all_entries: u32 = std.math.maxInt(u32);

const InitParams = extern struct {
    buffer: u64,
    buffer_size: u32,
    reserved: u32,
};

var initialized = std.atomic.Value(bool).init(false);
var opened = std.atomic.Value(bool).init(false);
var install_speed = std.atomic.Value(i32).init(1);

fn readable(address: u64, size: u64) bool {
    return address != 0 and kernel_memory.isGuestRangeAccessible(address, size);
}

fn writable(address: u64, size: u64) bool {
    // Guest mappings used for ABI output are readable as well as writable in
    // every title observed. The central range check prevents a bad pointer
    // from becoming a host fault; individual service code owns the write.
    return readable(address, size);
}

fn validateHandle(value: u32) i32 {
    if (!initialized.load(.acquire)) return error_not_initialized;
    if (value != handle or !opened.load(.acquire)) return error_bad_handle;
    return errno.ok;
}

pub fn initialize(params: ?*const InitParams) callconv(abi.guest) i32 {
    const input = params orelse return error_bad_pointer;
    if (!readable(@intFromPtr(input), @sizeOf(InitParams))) return error_bad_pointer;
    // Sony's API requires a 2 MiB work buffer. Validate the pointer, but accept
    // newer SDKs choosing a larger minimum without baking an upper bound here.
    if (input.buffer == 0) return error_bad_pointer;
    if (input.buffer_size < 0x20_0000) return error_bad_size;
    if (!readable(input.buffer, input.buffer_size)) return error_bad_pointer;
    if (initialized.swap(true, .acq_rel)) return error_already_initialized;
    opened.store(false, .release);
    install_speed.store(1, .release);
    return errno.ok;
}

pub fn open(output_handle: ?*u32, parameters: ?*const anyopaque) callconv(abi.guest) i32 {
    if (!initialized.load(.acquire)) return error_not_initialized;
    if (parameters != null) return error_invalid_argument;
    const output = output_handle orelse return error_bad_pointer;
    if (!writable(@intFromPtr(output), @sizeOf(u32))) return error_bad_pointer;
    output.* = handle;
    opened.store(true, .release);
    return errno.ok;
}

pub fn terminate() callconv(abi.guest) i32 {
    if (!initialized.swap(false, .acq_rel)) return error_not_initialized;
    opened.store(false, .release);
    return errno.ok;
}

pub fn close(value: u32) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    opened.store(false, .release);
    return errno.ok;
}

fn chunkIds(address: u64, count: u32) ?[]const u16 {
    if (count == 0 or count > maximum_entries) return null;
    const bytes = @as(u64, count) * @sizeOf(u16);
    if (!readable(address, bytes)) return null;
    const pointer: [*]const u16 = @ptrFromInt(address);
    return pointer[0..count];
}

fn validateChunks(ids: []const u16) i32 {
    // This dump has no PlayGo sidecar and a single cooked container, hence one
    // fully installed base chunk. Refusing the next id is important: some games
    // enumerate 0,1,2,... until BAD_CHUNK_ID.
    for (ids) |id| if (id != base_chunk) return error_bad_chunk_id;
    return errno.ok;
}

pub fn getLocus(value: u32, ids_address: u64, count: u32, output_address: u64) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    if (ids_address == 0 or output_address == 0) return error_bad_pointer;
    // A few SDK wrappers use UINT32_MAX as an empty/all sentinel.
    if (count == all_entries) return errno.ok;
    if (count == 0 or count > maximum_entries) return error_bad_size;
    const ids = chunkIds(ids_address, count) orelse return error_bad_pointer;
    if (!writable(output_address, count)) return error_bad_pointer;
    const loci: [*]u8 = @ptrFromInt(output_address);
    @memset(loci[0..count], locus_not_downloaded);
    const chunk_status = validateChunks(ids);
    if (chunk_status != errno.ok) return chunk_status;
    @memset(loci[0..count], locus_local_fast);
    return errno.ok;
}

pub fn getEta(value: u32, ids_address: u64, count: u32, output: ?*i64) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    const result = output orelse return error_bad_pointer;
    if (!writable(@intFromPtr(result), @sizeOf(i64))) return error_bad_pointer;
    const ids = chunkIds(ids_address, count) orelse return if (count == 0 or count > maximum_entries) error_bad_size else error_bad_pointer;
    const chunk_status = validateChunks(ids);
    if (chunk_status != errno.ok) return chunk_status;
    result.* = 0;
    return errno.ok;
}

pub fn getProgress(value: u32, ids_address: u64, count: u32, output_address: u64) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    const ids = chunkIds(ids_address, count) orelse return if (count == 0 or count > maximum_entries) error_bad_size else error_bad_pointer;
    const chunk_status = validateChunks(ids);
    if (chunk_status != errno.ok) return chunk_status;
    if (!writable(output_address, 16)) return error_bad_pointer;
    const output: *[16]u8 = @ptrFromInt(output_address);
    @memset(output, 0); // no remaining bytes and no remaining seconds
    return errno.ok;
}

pub fn setInstallSpeed(value: u32, speed: i32) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    if (speed < 0 or speed > 2) return error_invalid_argument;
    install_speed.store(speed, .release);
    return errno.ok;
}

pub fn prefetch(value: u32, ids_address: u64, count: u32, minimum_locus: i32) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    if (minimum_locus != locus_not_downloaded and minimum_locus != locus_local_slow and minimum_locus != locus_local_fast) return error_bad_locus;
    const ids = chunkIds(ids_address, count) orelse return if (count == 0 or count > maximum_entries) error_bad_size else error_bad_pointer;
    return validateChunks(ids);
}

pub fn getInstallSpeed(value: u32, output: ?*i32) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    const result = output orelse return error_bad_pointer;
    if (!writable(@intFromPtr(result), @sizeOf(i32))) return error_bad_pointer;
    result.* = install_speed.load(.acquire);
    return errno.ok;
}

pub fn getLanguageMask(value: u32, output: ?*u64) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    const result = output orelse return error_bad_pointer;
    if (!writable(@intFromPtr(result), @sizeOf(u64))) return error_bad_pointer;
    // A complete local package makes every language group immediately usable.
    result.* = std.math.maxInt(u64);
    return errno.ok;
}

pub fn getToDoList(
    value: u32,
    output_list_address: u64,
    capacity: u32,
    output_count: ?*u32,
) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    if (output_list_address == 0 or output_count == null) return error_bad_pointer;
    if (capacity == 0) return error_bad_size;
    const result = output_count.?;
    if (!writable(@intFromPtr(result), @sizeOf(u32))) return error_bad_pointer;
    result.* = 0;
    return errno.ok;
}

pub fn setToDoList(value: u32, list_address: u64, count: u32) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    if (list_address == 0) return error_bad_pointer;
    if (count == 0) return error_bad_size;
    if (count > maximum_entries or !readable(list_address, @as(u64, count) * @sizeOf(u16))) {
        return error_bad_pointer;
    }
    return errno.ok;
}

pub fn reset() void {
    initialized.store(false, .release);
    opened.store(false, .release);
    install_speed.store(1, .release);
}
