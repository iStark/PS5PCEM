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
const filesystem = @import("../filesystem.zig");
const kernel_memory = @import("kernel_memory.zig");

const error_invalid_argument: i32 = @bitCast(@as(u32, 0x80b2_0004));
const error_not_initialized: i32 = @bitCast(@as(u32, 0x80b2_0005));
const error_already_initialized: i32 = @bitCast(@as(u32, 0x80b2_0006));
const error_bad_handle: i32 = @bitCast(@as(u32, 0x80b2_0009));
const error_bad_pointer: i32 = @bitCast(@as(u32, 0x80b2_000a));
const error_bad_size: i32 = @bitCast(@as(u32, 0x80b2_000b));
const error_bad_chunk_id: i32 = @bitCast(@as(u32, 0x80b2_000c));
const error_bad_locus: i32 = @bitCast(@as(u32, 0x80b2_0010));
const error_bad_optional_type: i32 = @bitCast(@as(u32, 0x80b2_0024));

const handle: u32 = 1;
const base_chunk: u16 = 0;
const locus_not_downloaded: u8 = 0;
const locus_local_slow: u8 = 2;
const locus_local_fast: u8 = 3;
const maximum_entries: u32 = 0x4000;
const all_entries: u32 = std.math.maxInt(u32);
const optional_language: i32 = 0;
const optional_scenario: i32 = 1;
const all_languages: u64 = std.math.maxInt(u64);
const all_scenarios: u64 = 0x1f;
const maximum_manifest_bytes: usize = 4 * 1024 * 1024;

const InitParams = extern struct {
    buffer: u64,
    buffer_size: u32,
    reserved: u32,
};

var initialized = std.atomic.Value(bool).init(false);
var opened = std.atomic.Value(bool).init(false);
var install_speed = std.atomic.Value(i32).init(2);
var installed_chunks: [maximum_entries]u16 = undefined;
var installed_chunk_count: u32 = 1;

fn resetInstalledChunks() void {
    installed_chunks[0] = base_chunk;
    installed_chunk_count = 1;
}

fn containsChunk(id: u16) bool {
    for (installed_chunks[0..installed_chunk_count]) |installed| {
        if (installed == id) return true;
    }
    return false;
}

/// Extracts the numeric `id` members from the top-level `chunks` array in the
/// package manifest. Strings are skipped so filenames containing JSON-looking
/// text cannot become synthetic chunks.
fn parseManifestChunkIds(text: []const u8) u32 {
    const chunks_key = std.mem.indexOf(u8, text, "\"chunks\"") orelse return 0;
    const array_offset = std.mem.indexOfScalarPos(u8, text, chunks_key + "\"chunks\"".len, '[') orelse return 0;

    var count: u32 = 0;
    var depth: u32 = 1;
    var cursor = array_offset + 1;
    while (cursor < text.len and depth != 0) {
        switch (text[cursor]) {
            '"' => {
                const string_start = cursor;
                cursor += 1;
                while (cursor < text.len) : (cursor += 1) {
                    if (text[cursor] == '\\') {
                        cursor += 1;
                        continue;
                    }
                    if (text[cursor] == '"') break;
                }
                if (cursor >= text.len) break;
                const key = text[string_start + 1 .. cursor];
                cursor += 1;
                if (!std.mem.eql(u8, key, "id")) continue;
                while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) cursor += 1;
                if (cursor >= text.len or text[cursor] != ':') continue;
                cursor += 1;
                while (cursor < text.len and std.ascii.isWhitespace(text[cursor])) cursor += 1;
                const number_start = cursor;
                while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
                if (number_start == cursor) continue;
                const id = std.fmt.parseInt(u16, text[number_start..cursor], 10) catch continue;
                var duplicate = false;
                for (installed_chunks[0..count]) |installed| {
                    if (installed == id) duplicate = true;
                }
                if (!duplicate and count < maximum_entries) {
                    installed_chunks[count] = id;
                    count += 1;
                }
            },
            '[' => {
                depth += 1;
                cursor += 1;
            },
            ']' => {
                depth -= 1;
                cursor += 1;
            },
            else => cursor += 1,
        }
    }
    return count;
}

/// Directory dumps produced by the package extractor include the authoritative
/// chunk list as JSON. Reading it makes every shipped chunk immediately local
/// instead of advertising only chunk zero and leaving engines on an endless
/// "installing content" screen.
fn loadInstalledChunks() void {
    resetInstalledChunks();
    var info: filesystem.Stat = .{};
    filesystem.stat("/app0/package.manifest", &info) catch return;
    if (info.size <= 0 or info.size > maximum_manifest_bytes) return;
    const byte_count: usize = @intCast(info.size);
    const bytes = std.heap.page_allocator.alloc(u8, byte_count) catch return;
    defer std.heap.page_allocator.free(bytes);
    const descriptor = filesystem.open("/app0/package.manifest", filesystem.O.rdonly) catch return;
    defer filesystem.close(descriptor) catch {};

    var filled: usize = 0;
    while (filled < bytes.len) {
        const read = filesystem.read(descriptor, bytes[filled..]) catch return;
        if (read == 0) break;
        filled += read;
    }
    const count = parseManifestChunkIds(bytes[0..filled]);
    if (count != 0) installed_chunk_count = count;
}

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
    install_speed.store(2, .release);
    loadInstalledChunks();
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
    for (ids) |id| if (!containsChunk(id)) return error_bad_chunk_id;
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
    // ScePlayGoProgress is { progress_size, total_size }. A complete dump has
    // made all requested chunks available, so both values must be equal. A
    // zero/zero answer is treated as indeterminate by Unreal's install gate.
    std.mem.writeInt(u64, output[0..8], count, .little);
    std.mem.writeInt(u64, output[8..16], count, .little);
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
    if (output_count == null) return error_bad_pointer;
    if (capacity != 0 and output_list_address == 0) return error_bad_pointer;
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

/// Enumerates the one locally installed base chunk exposed by a directory
/// dump. A zero-capacity query is valid and reports no written entries.
pub fn getChunkId(
    value: u32,
    output_address: u64,
    capacity: u32,
    output_count: ?*u32,
) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    const count = output_count orelse return error_bad_pointer;
    if (!writable(@intFromPtr(count), @sizeOf(u32))) return error_bad_pointer;
    const entries = @min(capacity, installed_chunk_count);
    if (entries != 0) {
        const bytes = @as(u64, entries) * @sizeOf(u16);
        if (!writable(output_address, bytes)) return error_bad_pointer;
        const chunks: [*]u16 = @ptrFromInt(output_address);
        @memcpy(chunks[0..entries], installed_chunks[0..entries]);
    }
    count.* = entries;
    return errno.ok;
}

pub fn getInstallChunkId(
    value: u32,
    output_address: u64,
    capacity: u32,
    output_count: ?*u32,
) callconv(abi.guest) i32 {
    return getChunkId(value, output_address, capacity, output_count);
}

fn validateOptionalType(kind: i32) i32 {
    return if (kind == optional_language or kind == optional_scenario)
        errno.ok
    else
        error_bad_optional_type;
}

pub fn getOptionalChunk(value: u32, kind: i32, output: ?*u64) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    const kind_status = validateOptionalType(kind);
    if (kind_status != errno.ok) return kind_status;
    const result = output orelse return error_bad_pointer;
    if (!writable(@intFromPtr(result), @sizeOf(u64))) return error_bad_pointer;
    result.* = if (kind == optional_language) all_languages else all_scenarios;
    return errno.ok;
}

pub fn getSupportedOptionalChunk(value: u32, kind: i32, output: ?*u64) callconv(abi.guest) i32 {
    return getOptionalChunk(value, kind, output);
}

pub fn prefetchOptionalChunk(value: u32, kind: i32, option: ?*const u64) callconv(abi.guest) i32 {
    const status = validateHandle(value);
    if (status != errno.ok) return status;
    const kind_status = validateOptionalType(kind);
    if (kind_status != errno.ok) return kind_status;
    const input = option orelse return error_bad_pointer;
    if (!readable(@intFromPtr(input), @sizeOf(u64))) return error_bad_pointer;
    return errno.ok;
}

pub fn reset() void {
    initialized.store(false, .release);
    opened.store(false, .release);
    install_speed.store(2, .release);
    resetInstalledChunks();
}

test "package manifest exposes every installed chunk" {
    const manifest =
        \\{"chunks":[
        \\ {"id":0,"files":["not-an-\\\"id\\\":99.json"]},
        \\ {"id":2,"culture":[]},
        \\ {"id":5,"files":[]}
        \\],"other":{"id":77}}
    ;
    resetInstalledChunks();
    try std.testing.expectEqual(@as(u32, 3), parseManifestChunkIds(manifest));
    try std.testing.expectEqualSlices(u16, &.{ 0, 2, 5 }, installed_chunks[0..3]);
}
