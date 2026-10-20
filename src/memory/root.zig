// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Identity-mapped guest virtual memory.
//!
//! Guest x86-64 code carries absolute virtual addresses and executes natively,
//! so a guest address must be the same numeric address in the host process.
//! `AddressSpace` reserves the console's usable windows before any image
//! is loaded, then commits, protects, and releases 16 KiB page ranges inside
//! those reservations.
//!
//! The design deliberately separates host reservation from guest mappings:
//! reserving a several-hundred-gigabyte window consumes virtual address space,
//! not physical memory. Physical pages are committed only by `mapFixed` or
//! `map`, and `unmap` returns them while keeping the outer reservation intact.

const std = @import("std");
const builtin = @import("builtin");
pub export var reuse_armed_gpu_pages: bool = true;
pub export var armed_gpu_page_reuses: u64 = 0;
pub export var fine_gpu_range_guards: bool = true;
pub export var fine_gpu_range_pages_avoided: u64 = 0;

pub const SharedBacking = @import("backing_store.zig").SharedBacking;
pub const SharedView = @import("backing_store.zig").SharedView;
pub const HostMutex = @import("host_mutex.zig").Mutex;

const windows_mem_free: u32 = 0x0001_0000;
const windows_mem_commit: u32 = 0x0000_1000;
const windows_page_noaccess: u32 = 0x01;
const windows_page_readonly: u32 = 0x02;
const windows_page_readwrite: u32 = 0x04;
const windows_page_writecopy: u32 = 0x08;
const windows_page_execute: u32 = 0x10;
const windows_page_execute_read: u32 = 0x20;
const windows_page_execute_readwrite: u32 = 0x40;
const windows_page_execute_writecopy: u32 = 0x80;
const windows_page_guard: u32 = 0x100;
const windows_allocation_granularity: u64 = 0x1_0000;

/// Native x64 layout returned by VirtualQuery. Kept local so the memory module
/// does not need libc or translated Windows headers.
const WindowsMemoryInfo = extern struct {
    base_address: ?*anyopaque,
    allocation_base: ?*anyopaque,
    allocation_protect: u32,
    partition_id: u16,
    _padding0: u16,
    region_size: usize,
    state: u32,
    protect: u32,
    kind: u32,
    _padding1: u32,
};

const WindowsApi = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn VirtualQuery(
        address: ?*const anyopaque,
        info: *WindowsMemoryInfo,
        length: usize,
    ) callconv(.winapi) usize;

    extern "ntdll" fn NtAllocateVirtualMemoryEx(
        process: std.os.windows.HANDLE,
        base_address: *std.os.windows.PVOID,
        region_size: *std.os.windows.SIZE_T,
        allocation_type: std.os.windows.MEM.ALLOCATE,
        page_protection: std.os.windows.PAGE,
        extended_parameters: ?*std.os.windows.MEM.EXTENDED_PARAMETER,
        parameter_count: std.os.windows.ULONG,
    ) callconv(.winapi) std.os.windows.NTSTATUS;

    extern "ntdll" fn NtMapViewOfSectionEx(
        section: std.os.windows.HANDLE,
        process: std.os.windows.HANDLE,
        base_address: *std.os.windows.PVOID,
        section_offset: ?*std.os.windows.LARGE_INTEGER,
        view_size: *std.os.windows.SIZE_T,
        allocation_type: std.os.windows.MEM.MAP,
        page_protection: std.os.windows.PAGE,
        extended_parameters: ?*std.os.windows.MEM.EXTENDED_PARAMETER,
        parameter_count: std.os.windows.ULONG,
    ) callconv(.winapi) std.os.windows.NTSTATUS;
} else struct {};

fn windowsVirtualQuery(address: u64, info: *WindowsMemoryInfo) usize {
    if (builtin.os.tag != .windows) unreachable;
    return WindowsApi.VirtualQuery(@ptrFromInt(address), info, @sizeOf(WindowsMemoryInfo));
}

/// Returns the complete native allocation containing `address`. Protection can
/// split one section view into several VirtualQuery regions, but every region
/// retains the same allocation base.
fn windowsAllocationRange(address: u64) Error!Range {
    if (builtin.os.tag != .windows) unreachable;

    var info: WindowsMemoryInfo = undefined;
    if (windowsVirtualQuery(address, &info) == 0) return Error.HostDecommitFailed;
    const allocation_start: u64 = @intFromPtr(info.allocation_base);
    // The first query already describes this allocation when it starts at
    // the requested address. Unmap preflight and execution both walk every
    // native view; do not query each first region twice.
    var cursor = address;
    while (true) {
        const region_start: u64 = @intFromPtr(info.base_address);
        const region_end = std.math.add(u64, region_start, info.region_size) catch
            return Error.HostDecommitFailed;
        if (region_end <= cursor) return Error.HostDecommitFailed;
        cursor = region_end;
        if (windowsVirtualQuery(cursor, &info) == 0) return Error.HostDecommitFailed;
        if (@intFromPtr(info.allocation_base) != allocation_start) break;
    }
    return .{ .start = allocation_start, .end = cursor };
}

const HostPermission = enum { read, write, execute };

test "maps lines answer coverage and permission" {
    const line = "7f0000001000-7f0000003000 rw-p 00000000 00:00 0";
    try std.testing.expectEqual(@as(?MapsCoverage, null), mapsLineCovers(line, 0x7f0000003000, .read));
    try std.testing.expectEqual(MapsCoverage{ .end = 0x7f0000003000, .allowed = true }, mapsLineCovers(line, 0x7f0000002000, .write).?);
    try std.testing.expectEqual(MapsCoverage{ .end = 0x7f0000003000, .allowed = false }, mapsLineCovers(line, 0x7f0000002000, .execute).?);
    // A mapping that begins after the cursor leaves a gap.
    try std.testing.expectEqual(false, mapsLineCovers(line, 0x7f0000000000, .read).?.allowed);
}

fn windowsRangeAccessible(address: u64, size: u64, required: HostPermission) bool {
    if (builtin.os.tag != .windows or address == 0 or size == 0) return false;
    const end = std.math.add(u64, address, size) catch return false;
    var cursor = address;
    while (cursor < end) {
        var info: WindowsMemoryInfo = undefined;
        if (windowsVirtualQuery(cursor, &info) == 0 or info.state != windows_mem_commit) return false;
        const protection = info.protect;
        if (protection & (windows_page_noaccess | windows_page_guard) != 0) return false;
        const allowed = switch (required) {
            .read => protection & (windows_page_readonly | windows_page_readwrite |
                windows_page_writecopy | windows_page_execute_read |
                windows_page_execute_readwrite | windows_page_execute_writecopy) != 0,
            .write => protection & (windows_page_readwrite | windows_page_writecopy |
                windows_page_execute_readwrite | windows_page_execute_writecopy) != 0,
            .execute => protection & (windows_page_execute | windows_page_execute_read |
                windows_page_execute_readwrite | windows_page_execute_writecopy) != 0,
        };
        if (!allowed) return false;
        const region_start: u64 = @intFromPtr(info.base_address);
        const region_end = std.math.add(u64, region_start, info.region_size) catch return false;
        if (region_end <= cursor) return false;
        cursor = @min(end, region_end);
    }
    return true;
}

/// Linux has no VirtualQuery. Readability is answered by copying one byte of
/// every page out of this process with process_vm_readv, which fails with
/// EFAULT on the first unmapped or unreadable page: exact, and free of signals
/// and locks. Write and execute permission are read from /proc/self/maps.
/// Both paths use only system calls and stack buffers, because the native
/// fault handler asks these questions from inside a signal handler.
fn linuxRangeAccessible(address: u64, size: u64, required: HostPermission) bool {
    if (builtin.os.tag != .linux or address == 0 or size == 0) return false;
    const end = std.math.add(u64, address, size) catch return false;
    if (required == .read) {
        if (linuxProbeReadable(address, end)) |readable| return readable;
    }
    return linuxMapsAllow(address, end, required);
}

/// Null when the probe is unavailable, for instance where a seccomp profile
/// forbids process_vm_readv; the caller then reads the mappings instead.
fn linuxProbeReadable(address: u64, end: u64) ?bool {
    const linux = std.os.linux;
    const batch = 64;
    var scratch: [batch]u8 = undefined;
    var local: [batch]std.posix.iovec = undefined;
    var remote: [batch]std.posix.iovec_const = undefined;
    const pid = linux.getpid();
    var cursor = address;
    while (cursor < end) {
        var count: usize = 0;
        while (count < batch and cursor < end) : (count += 1) {
            local[count] = .{ .base = @ptrCast(&scratch[count]), .len = 1 };
            remote[count] = .{ .base = @ptrFromInt(cursor), .len = 1 };
            cursor = std.mem.alignForward(u64, cursor + 1, std.heap.page_size_min);
        }
        const result = linux.process_vm_readv(pid, local[0..count], remote[0..count], 0);
        switch (linux.errno(result)) {
            .SUCCESS => if (result != count) return false,
            .FAULT => return false,
            else => return null,
        }
    }
    return true;
}

/// Walks /proc/self/maps, whose lines are sorted, and requires the range to be
/// covered without a gap by mappings carrying the permission.
fn linuxMapsAllow(address: u64, end: u64, required: HostPermission) bool {
    const linux = std.os.linux;
    const opened = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return false;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);

    var buffer: [4096]u8 = undefined;
    var filled: usize = 0;
    var cursor = address;
    while (true) {
        const result = linux.read(fd, buffer[filled..].ptr, buffer.len - filled);
        if (linux.errno(result) != .SUCCESS) return false;
        filled += result;
        const at_end = result == 0;
        var consumed: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buffer[0..filled], consumed, '\n')) |newline| {
            const line = buffer[consumed..newline];
            consumed = newline + 1;
            const covered = mapsLineCovers(line, cursor, required) orelse continue;
            if (!covered.allowed) return false;
            cursor = @min(end, covered.end);
            if (cursor >= end) return true;
        }
        if (at_end) return false;
        // Keep the partial last line for the next read.
        std.mem.copyForwards(u8, buffer[0 .. filled - consumed], buffer[consumed..filled]);
        filled -= consumed;
        if (filled == buffer.len) return false;
    }
}

const MapsCoverage = struct { end: u64, allowed: bool };

/// For a line of /proc/self/maps: null if it ends at or before `cursor` (keep
/// looking), otherwise whether it permits the access from `cursor` and where
/// it ends. A line starting after `cursor` leaves a gap, which denies.
fn mapsLineCovers(line: []const u8, cursor: u64, required: HostPermission) ?MapsCoverage {
    const dash = std.mem.indexOfScalar(u8, line, '-') orelse return null;
    const space = std.mem.indexOfScalarPos(u8, line, dash, ' ') orelse return null;
    if (space + 4 > line.len) return null;
    const start = std.fmt.parseInt(u64, line[0..dash], 16) catch return null;
    const stop = std.fmt.parseInt(u64, line[dash + 1 .. space], 16) catch return null;
    if (stop <= cursor) return null;
    if (start > cursor) return .{ .end = stop, .allowed = false };
    const permissions = line[space + 1 ..][0..3];
    const allowed = switch (required) {
        .read => permissions[0] == 'r',
        .write => permissions[1] == 'w',
        .execute => permissions[2] == 'x',
    };
    return .{ .end = stop, .allowed = allowed };
}

fn hostRangeAccessible(address: u64, size: u64, required: HostPermission) bool {
    return switch (builtin.os.tag) {
        .windows => windowsRangeAccessible(address, size, required),
        .linux => linuxRangeAccessible(address, size, required),
        else => false,
    };
}

/// Checks native allocations returned to guest code by the host CRT. These
/// pages are outside AddressSpace's console windows but remain valid pointers
/// for native guest execution and for HLE output parameters.
pub fn isHostRangeReadable(address: u64, size: u64) bool {
    return hostRangeAccessible(address, size, .read);
}

pub fn isHostRangeWritable(address: u64, size: u64) bool {
    return hostRangeAccessible(address, size, .write);
}

/// Checks that a native return address belongs to committed executable code.
/// This is intentionally stricter than readability: an exception unwinder can
/// encounter host bridge frames, but must not mistake an arbitrary host heap
/// pointer for one of those frames.
pub fn isHostRangeExecutable(address: u64, size: u64) bool {
    return hostRangeAccessible(address, size, .execute);
}

/// Guest mappings are aligned to the hardware's 16 KiB page size.
pub const page_size: u64 = 0x4000;

/// A half-open interval in the guest address space.
pub const Range = struct {
    start: u64,
    end: u64,

    pub fn len(self: Range) u64 {
        return self.end - self.start;
    }

    pub fn contains(self: Range, address: u64, size: u64) bool {
        if (size == 0 or address < self.start) return false;
        const end = std.math.add(u64, address, size) catch return false;
        return end <= self.end;
    }
};

/// Addresses managed by the guest kernel.
pub const system_managed = Range{
    .start = 0x00_0004_0000,
    .end = 0x08_0000_0000 - page_size,
};

/// Search start for kernel-owned thread state and stacks.
///
/// Keeping these allocations near the top of the system-managed window
/// mirrors the console layout and, critically, leaves the title user-window
/// base (`0x10_0000_0000`) available for fixed heap arenas.
pub const thread_runtime_search_base: u64 = 0x07_e000_0000;

/// Addresses reserved for the guest system software.
pub const system_reserved = Range{
    .start = 0x08_0000_0000,
    .end = 0x0f_c000_0000,
};

/// Fixed device apertures exposed by the guest kernel. The AGC firmware table
/// and graphics MMIO compatibility mapping both live in this window.
pub const device = Range{
    .start = 0x0f_e000_0000,
    .end = 0x0f_f000_0000,
};

/// Addresses exposed to title-controlled mappings.
pub const user = Range{
    // macOS keeps the lower host VA span unavailable to this native-x64
    // layout. Windows and Linux can expose the console user window from
    // 64 GiB, which is also a common explicit reservation hint from titles.
    .start = if (builtin.os.tag == .macos) 0x70_0000_0000 else 0x10_0000_0000,
    .end = 0xfc_0000_0000,
};

pub const guest_ranges = [_]Range{ system_managed, system_reserved, device, user };

/// Host memory that guest code addresses directly, placed below 1 TiB.
///
/// Console user addresses fit in 40 bits, and engines rely on it: Arkanoid's
/// job system packs fiber stack addresses into 40-bit fields. Windows hands
/// out such memory bottom-up, so after the guest windows are reserved its
/// allocations land in the free 16 GiB between the user window and 1 TiB and
/// the packing holds. Linux maps top-down, near 128 TiB, and the same pointer
/// is truncated. Stacks that guest code runs on, or whose locals it receives,
/// are therefore taken from that gap on Linux; other hosts use the page
/// allocator as before.
pub const low_host = struct {
    pub const start: u64 = user.end;
    pub const end: u64 = 0x100_0000_0000;

    var cursor = std.atomic.Value(u64).init(start);

    pub fn alloc(size: usize) ?[]align(std.heap.page_size_min) u8 {
        const length = std.mem.alignForward(usize, size, std.heap.page_size_min);
        if (builtin.os.tag != .linux) {
            return std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), length) catch null;
        }
        const linux = std.os.linux;
        // A bump cursor that wraps once: freed ranges are found again by
        // MAP_FIXED_NOREPLACE succeeding where it failed before.
        var address = cursor.load(.monotonic);
        var wrapped = false;
        while (true) {
            if (address + length > end) {
                if (wrapped) break;
                wrapped = true;
                address = start;
                continue;
            }
            const result = linux.mmap(
                @ptrFromInt(address),
                length,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED_NOREPLACE = true },
                -1,
                0,
            );
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result != address) {
                        // Kernels before 4.17 treat the flag as a hint only.
                        _ = linux.munmap(@ptrFromInt(result), length);
                        break;
                    }
                    cursor.store(address + length, .monotonic);
                    const bytes: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(address);
                    return bytes[0..length];
                },
                .EXIST => address += length,
                else => break,
            }
        }
        return std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), length) catch null;
    }

    pub fn free(bytes: []align(std.heap.page_size_min) u8) void {
        if (bytes.len == 0) return;
        const address = @intFromPtr(bytes.ptr);
        if (builtin.os.tag == .linux and address >= start and address < end) {
            _ = std.os.linux.munmap(bytes.ptr, bytes.len);
            return;
        }
        std.heap.page_allocator.free(bytes);
    }
};

test "low host memory stays below the 40-bit guest pointer limit" {
    const bytes = low_host.alloc(64 * 1024) orelse return error.SkipZigTest;
    defer low_host.free(bytes);
    bytes[0] = 1;
    bytes[bytes.len - 1] = 2;
    if (builtin.os.tag == .linux) {
        try std.testing.expect(@intFromPtr(bytes.ptr) >= low_host.start);
        try std.testing.expect(@intFromPtr(bytes.ptr) + bytes.len <= low_host.end);
    }
}

/// The window searched by an address chosen by the emulator.
pub const Area = enum {
    system_managed,
    user,

    fn range(self: Area) Range {
        return switch (self) {
            .system_managed => memory.system_managed,
            .user => memory.user,
        };
    }
};

// Referring to the namespace avoids a field/name collision in Area.range.
const memory = @This();

/// Guest-visible page permissions.
pub const Protection = packed struct(u3) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,

    pub const none: Protection = .{};
    pub const read_only: Protection = .{ .read = true };
    pub const read_write: Protection = .{ .read = true, .write = true };
    pub const read_execute: Protection = .{ .read = true, .execute = true };
    pub const read_write_execute: Protection = .{
        .read = true,
        .write = true,
        .execute = true,
    };

    fn host(self: Protection) std.process.MemoryProtection {
        // Win32 has no write-only page mode. Promoting it to read/write also
        // matches the effective x86-64 permission seen by guest code.
        return .{
            .read = self.read or self.write,
            .write = self.write,
            .execute = self.execute,
        };
    }

    /// CPU protection bits used by the guest kernel ABI. GPU access bits are
    /// retained separately in Mapping.protection_bits when HLE supplies them.
    pub fn guestBits(self: Protection) i32 {
        return (@as(i32, @intFromBool(self.read)) * 0x01) |
            (@as(i32, @intFromBool(self.write)) * 0x02) |
            (@as(i32, @intFromBool(self.execute)) * 0x04);
    }
};

/// Why a range is present. This is metadata; every mapping remains an identity
/// mapping from the guest address to the same host address.
pub const MappingKind = enum {
    module,
    private,
    stack,
    direct_memory,
    flexible,
    reserved,
};

pub const maximum_name_length: usize = 32;

pub const Mapping = struct {
    address: u64,
    size: u64,
    protection: Protection,
    kind: MappingKind,
    /// Ownership of one mapping operation, retained by protection/metadata splits.
    /// A later mapping at the same VA receives a different nonzero identity.
    identity: u64 = 0,
    /// Physical direct-memory offset, when `kind == .direct_memory`.
    backing_offset: ?u64 = null,
    /// Original guest ABI protection mask, including GPU access bits.
    protection_bits: i32 = 0,
    memory_type: i32 = 0,
    gpu_mask_id: u8 = 0,
    /// Kernel MemoryPool ownership; retained by commits and interval splits.
    pooled: bool = false,
    name: [maximum_name_length]u8 = [_]u8{0} ** maximum_name_length,

    pub fn end(self: Mapping) u64 {
        return self.address + self.size;
    }
};

/// Optional guest-visible attributes applied to an already mapped range.
pub const MappingMetadata = struct {
    protection_bits: ?i32 = null,
    memory_type: ?i32 = null,
    gpu_mask_id: ?u8 = null,
    name: ?[]const u8 = null,
    pooled: ?bool = null,
};

pub const PoolBacking = struct { offset: u64, size: u64 };

test "mapping identities survive splits and reject remapped allocation backing" {
    const base = user.start;
    var space = try AddressSpace.initWithDirectMemory(std.testing.allocator, 4 * page_size);
    defer space.deinit();
    try space.mapFixed(base, 3 * page_size, .read_write, .direct_memory, 0);
    const original = space.mappingIdentity(base + 32, 3 * page_size - 32);
    try std.testing.expect(original != 0);
    try space.protect(base + page_size, page_size, .read_only);
    try space.setMetadata(base + 2 * page_size, page_size, .{ .name = "split" });
    try std.testing.expectEqual(original, space.mappingIdentity(base + 32, 3 * page_size - 32));
    try space.unmap(base + page_size, page_size);
    try std.testing.expectEqual(@as(u64, 0), space.mappingIdentity(base + 32, 3 * page_size - 32));
    try space.mapFixed(base + page_size, page_size, .read_write, .direct_memory, page_size);
    try std.testing.expect(space.mappingIdentity(base + page_size, page_size) != original);
    try std.testing.expectEqual(@as(u64, 0), space.mappingIdentity(base + 32, 3 * page_size - 32));
    try std.testing.expectEqual(original, space.mappingIdentity(base + 32, page_size - 32));
    try space.reserveFixed(base + 3 * page_size, page_size);
    try std.testing.expectEqual(@as(u64, 0), space.mappingIdentity(base + 3 * page_size, page_size));
    try space.mapInReservation(base + 3 * page_size, page_size, .read_write, .private, null);
    const committed = space.mappingIdentity(base + 3 * page_size, page_size);
    try std.testing.expect(committed != 0 and committed != original);
    try std.testing.expectEqual(@as(u64, 0), space.mappingIdentity(std.math.maxInt(u64), 2));
}

test "system-managed aligned direct allocations support guest-page recycling" {
    const base = system_managed.start;
    const granule = windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 2 * granule);
    defer space.deinit();
    try space.mapFixed(base, 2 * granule, .read_write, .direct_memory, 0);
    try space.writeInt(u32, base, 0xa1b2c3d4);
    try space.writeInt(u32, base + 2 * granule - 4, 0x55667788);
    // The allocator keeps both neighbours live while recycling an unaligned
    // part of an originally 64 KiB-aligned acquisition.
    try space.unmap(base + page_size, granule);
    try space.reserveFixed(base + page_size, granule);
    try space.mapInReservation(base + page_size, granule, .read_write, .direct_memory, page_size);
    var bytes: [4]u8 = undefined;
    try space.read(base, &bytes);
    try testing.expectEqual(@as(u32, 0xa1b2c3d4), std.mem.readInt(u32, &bytes, .little));
    try space.read(base + 2 * granule - 4, &bytes);
    try testing.expectEqual(@as(u32, 0x55667788), std.mem.readInt(u32, &bytes, .little));
    try space.writeInt(u32, base + page_size, 0x11223344);
    try space.unmap(base, 2 * granule);
}

test "rejected partial direct unmap leaves earlier Windows views intact" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const base = user.start;
    const granule = windows_allocation_granularity;
    for ([_]bool{ false, true }) |private_prefix| {
        var space = try AddressSpace.initWithDirectMemory(testing.allocator, 2 * granule);
        defer space.deinit();
        if (private_prefix) {
            try space.mapFixed(base, granule, .read_write, .private, null);
            try space.mapFixed(base + granule, granule, .read_write, .direct_memory, granule);
        } else {
            try space.mapFixed(base, 2 * granule, .read_write, .direct_memory, 0);
            try space.protect(base + page_size, page_size, .read_only);
        }
        try space.writeInt(u32, base, 0xa1b2c3d4);
        // The last 16 KiB cuts a 64 KiB host view. Reject before unmapping
        // earlier direct/private views, including protection-split intervals.
        try testing.expectError(Error.HostDecommitFailed, space.unmap(base, granule + page_size));
        try testing.expect(isHostRangeReadable(base, 2 * granule));
        var bytes: [4]u8 = undefined;
        try space.read(base, &bytes);
        try testing.expectEqual(@as(u32, 0xa1b2c3d4), std.mem.readInt(u32, &bytes, .little));
        try testing.expect(space.isReadable(base, 2 * granule));
        try space.unmap(base, 2 * granule);
    }
}

test "failed host protection does not lend pages left inaccessible" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const base = user.start;
    var space = try AddressSpace.init(testing.allocator);
    defer space.deinit();
    try space.mapFixed(base, 2 * page_size, .read_write, .private, null);
    // Emulate native state changing behind the interval table, then provoke
    // an operation which protects its first page but fails on the second.
    try hostDecommit(base + page_size, page_size);
    defer {
        hostCommit(base + page_size, page_size, .read_write) catch unreachable;
        space.protect(base, 2 * page_size, .read_write) catch unreachable;
    }
    try testing.expectError(Error.ProtectionDenied, space.protect(base, 2 * page_size, .none));
    try testing.expect(space.host_mapping_state_uncertain);
    try testing.expect(!space.isReadable(base, 4));
    try testing.expect(!space.isWritable(base, 4));
    try testing.expect(space.borrowReadable(base, 4) == null);
    try testing.expect(space.borrowReadable(base + page_size, 4) == null);
    var bytes: [4]u8 = undefined;
    try testing.expectError(Error.ProtectionDenied, space.read(base, &bytes));
}

test "read lease holds backing across a concurrent unmap and rejects released ranges" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const base = user.start;
    var space = try AddressSpace.init(std.testing.allocator);
    defer space.deinit();
    try space.mapFixed(base, 2 * page_size, .read_write, .private, null);
    try space.writeInt(u32, base, 0x12345678);
    try space.protect(base + page_size, page_size, .read_only);
    var lease = space.borrowReadable(base, 2 * page_size).?;
    var held = true;
    const Shared = struct {
        space: *AddressSpace,
        started: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),
        failure: ?Error = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.space.unmap(user.start, 2 * page_size) catch |err| {
                self.failure = err;
            };
            self.finished.store(true, .release);
        }
    };
    var shared = Shared{ .space = &space };
    const worker = std.Thread.spawn(.{}, Shared.run, .{&shared}) catch |err| {
        lease.release();
        return err;
    };
    defer {
        if (held) lease.release();
        worker.join();
    }
    while (!shared.started.load(.acquire)) std.atomic.spinLoopHint();
    const expected = std.hash.Wyhash.hash(0, lease.bytes);
    for (0..128) |_| {
        try std.testing.expectEqual(expected, std.hash.Wyhash.hash(0, lease.bytes));
        try std.testing.expect(!shared.finished.load(.acquire));
    }
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, lease.bytes[0..4], .little));
    lease.release();
    held = false;
    while (!shared.finished.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expect(shared.failure == null);
    try std.testing.expect(space.borrowReadable(base, 4) == null);
    try std.testing.expect(space.borrowReadable(0, 1) == null);
    try std.testing.expect(space.borrowReadable(std.math.maxInt(u64), 2) == null);
    // CRT and host-stack sources keep the native allocation fallback.
    const host_bytes = "host source";
    var host_lease = space.borrowReadable(@intFromPtr(host_bytes.ptr), host_bytes.len).?;
    defer host_lease.release();
    try std.testing.expectEqualStrings(host_bytes, host_lease.bytes);
}

pub const Error = error{
    UnsupportedHost,
    AddressSpaceUnavailable,
    InvalidAddress,
    InvalidSize,
    InvalidAlignment,
    AddressUnavailable,
    RangeNotMapped,
    ProtectionDenied,
    HostCommitFailed,
    HostDecommitFailed,
    BackingStoreUnavailable,
    BackingOffsetInvalid,
} || std.mem.Allocator.Error;

/// A small lock for the address-space interval table.
///
/// Mapping and page-tracker operations retain exclusive access. Contenders
/// park during long host commits/protection changes without requiring std.Io.
const Lock = HostMutex;

pub export var known_uniform_publications: bool = true;
pub export var uniform_publication_compares_avoided: u64 = 0;

const TrackedGpuPage = struct {
    generation: u64,
    uniform_generation: u64 = 0,
    uniform_value: u32 = 0,
    restore_protection: Protection,
    armed: bool = false,
    /// A hint only: every grouped protection still checks the native region.
    batch_protection: bool = false,
};

/// CPU-write watch state for memory which has been consumed by the GPU.  The
/// guest uses 16 KiB pages, so the tracker deliberately has the same
/// granularity instead of hashing whole textures and buffers every draw.
const GpuPageTracker = struct {
    const region_shift = 21;
    const fine_region_shift = 18;
    const RangeGeneration = struct {
        first: u64 = 0,
        end: u64 = 0,
        epoch: u64 = 0,
        region_epoch: u64 = 0,
        fine_region_epoch: u64 = 0,
        fingerprint: u64 = 0,
    };
    pages: std.AutoHashMapUnmanaged(u64, TrackedGpuPage) = .empty,
    /// Positive queries remain valid until any tracked page changes. Guard
    /// both range endpoints; collisions only replace an optimization entry.
    range_generations: [2048]RangeGeneration = @splat(.{}),
    // Coarse change epochs let a cached query survive writes to unrelated
    // allocations. Hash collisions only cause extra page walks. The fault
    // handler updates this fixed table without allocating or scanning ranges.
    region_epochs: [4096]u64 = @splat(0),
    fine_region_epochs: [8192]u64 = @splat(0),
    lock: Lock = .{},
    generation_counter: u64 = 1,
    enabled: bool = false,
    /// Watch-related host protection attempts, for diagnostics and native probes.
    protection_calls: u64 = 0,

    fn rangeGenerationSlot(self: *GpuPageTracker, first: u64, end: u64) *RangeGeneration {
        // GPU allocations commonly share 64 KiB or larger alignment. Mix the
        // high page bits before indexing so those ranges can use every slot.
        var key = (first / page_size) ^ (((end - first) / page_size) *% 0x9e3779b97f4a7c15);
        key ^= key >> 30;
        key *%= 0xbf58476d1ce4e5b9;
        key ^= key >> 27;
        key *%= 0x94d049bb133111eb;
        key ^= key >> 31;
        return &self.range_generations[key & (self.range_generations.len - 1)];
    }

    fn rememberRangeGeneration(self: *GpuPageTracker, first: u64, end: u64, fingerprint: u64) u64 {
        const value = if (fingerprint == 0) 1 else fingerprint;
        self.rangeGenerationSlot(first, end).* = .{
            .first = first,
            .end = end,
            .epoch = self.generation_counter,
            .region_epoch = self.rangeRegionEpoch(first, end),
            .fine_region_epoch = if (@atomicLoad(bool, &fine_gpu_range_guards, .monotonic)) self.rangeFineRegionEpoch(first, end) else 0,
            .fingerprint = value,
        };
        return value;
    }

    fn cachedRangeGeneration(self: *GpuPageTracker, first: u64, end: u64) ?u64 {
        const cached = self.rangeGenerationSlot(first, end);
        if (cached.first != first or cached.end != end) return null;
        if (cached.epoch != self.generation_counter and cached.region_epoch != self.rangeRegionEpoch(first, end)) {
            // A neighboring 256 KiB block can invalidate the coarse 2 MiB
            // guard without changing any page in this query. Every mutation
            // updates both tables under the tracker lock; collisions cause
            // extra misses, never endorsement of an older page generation.
            if (!@atomicLoad(bool, &fine_gpu_range_guards, .monotonic) or cached.fine_region_epoch == 0 or
                cached.fine_region_epoch != self.rangeFineRegionEpoch(first, end)) return null;
            _ = @atomicRmw(u64, &fine_gpu_range_pages_avoided, .Add, (end - first) / page_size, .monotonic);
        }
        cached.epoch = self.generation_counter;
        return cached.fingerprint;
    }

    fn rangeFineRegionEpoch(self: *const GpuPageTracker, first: u64, end: u64) u64 {
        var region = first >> fine_region_shift;
        const last = (end - 1) >> fine_region_shift;
        if (last - region >= self.fine_region_epochs.len) return self.generation_counter;
        var newest: u64 = 0;
        while (region <= last) : (region += 1)
            newest = @max(newest, self.fine_region_epochs[region & (self.fine_region_epochs.len - 1)]);
        return newest;
    }

    fn rangeRegionEpoch(self: *const GpuPageTracker, first: u64, end: u64) u64 {
        var region = first >> region_shift;
        const last = (end - 1) >> region_shift;
        if (last - region >= self.region_epochs.len) return self.generation_counter;
        var newest: u64 = 0;
        while (region <= last) : (region += 1)
            newest = @max(newest, self.region_epochs[region & (self.region_epochs.len - 1)]);
        return newest;
    }

    fn protectRun(self: *GpuPageTracker, address: u64, end: u64, protection: Protection) Error!u64 {
        self.protection_calls +|= 1;
        hostProtectContiguous(address, end - address, protection) catch |err| {
            if (end - address == page_size) return err;
            // A failed grouped operation must not publish armed metadata.
            // Retain the original page operation if the host rejects a group.
            self.protection_calls +|= 1;
            try hostProtectContiguous(address, page_size, protection);
            return address + page_size;
        };
        return end;
    }

    fn nextGeneration(self: *GpuPageTracker, page: u64) u64 {
        const next = @atomicLoad(u64, &self.generation_counter, .monotonic) +% 1;
        const value = if (next == 0) 1 else next;
        @atomicStore(u64, &self.generation_counter, value, .release);
        if (next == 0) {
            @memset(&self.range_generations, .{});
            @memset(&self.region_epochs, 0);
            @memset(&self.fine_region_epochs, 0);
        }
        self.region_epochs[(page >> region_shift) & (self.region_epochs.len - 1)] = value;
        self.fine_region_epochs[(page >> fine_region_shift) & (self.fine_region_epochs.len - 1)] = value;
        return value;
    }

    fn deinit(self: *GpuPageTracker, allocator: std.mem.Allocator) void {
        self.pages.deinit(allocator);
        self.* = .{};
    }
};

/// Owns all guest-address reservations in one host process.
///
/// There must be at most one live instance per process. Creating a second one
/// correctly fails because the first instance already owns the fixed ranges.
pub const AddressSpace = struct {
    const PublicationView = struct { physical: u64, view: SharedView };

    allocator: std.mem.Allocator,
    mappings: std.ArrayList(Mapping) = .empty,
    // Indices are hints only: every use rechecks the current interval and its
    // permissions while holding mutex. Insertions, splits and removals cannot
    // make a stale hint authorize access to a former mapping.
    access_mapping_hints: [32]usize = @splat(0),
    /// Host-owned pieces of the guest windows. Windows has permanent
    /// mappings such as KUSER_SHARED_DATA inside the low window, so ownership
    /// is intentionally a list of free extents rather than three booleans.
    reservations: std.ArrayList(Range) = .empty,
    direct_backing: ?SharedBacking = null,
    // SEC_RESERVE section pages remain committed until the backing section
    // dies, even after its last guest view is removed. Protected by mutex;
    // tracks physical offsets, never guest addresses or mapping identities.
    direct_committed: std.DynamicBitSetUnmanaged = .{},
    mutex: Lock = .{},
    gpu_tracker: GpuPageTracker = .{},
    mapping_identity: u64 = 0,
    // An unexpected host mutation failure can leave only part of a range
    // changed. Until destruction, native access checks must then verify the
    // actual host pages instead of relying solely on interval metadata.
    host_mapping_state_uncertain: bool = false,
    // Independent aliases change no guest VA permissions. Bound the retained
    // virtual views, and recheck the current guest mapping before every copy.
    publication_views: [64]?PublicationView = @splat(null),
    next_publication_view: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Error!AddressSpace {
        if (@sizeOf(usize) != @sizeOf(u64)) return Error.UnsupportedHost;

        var self = AddressSpace{ .allocator = allocator };
        errdefer {
            self.releaseReservations();
            self.reservations.deinit(allocator);
        }

        try self.reserveGuestRanges();
        return self;
    }

    /// Creates the address space and its sparse physical direct-memory store.
    /// Ordinary loader tests can use `init`; a complete runtime uses this form
    /// so mappings of the same physical offset become coherent aliases.
    pub fn initWithDirectMemory(
        allocator: std.mem.Allocator,
        backing_size: u64,
    ) Error!AddressSpace {
        var self = try init(allocator);
        errdefer self.deinit();
        self.direct_backing = SharedBacking.init(backing_size) catch
            return Error.BackingStoreUnavailable;
        if (builtin.os.tag == .windows) {
            self.direct_committed = try std.DynamicBitSetUnmanaged.initEmpty(
                allocator,
                @intCast(std.math.divCeil(u64, backing_size, page_size) catch return Error.InvalidSize),
            );
        }
        return self;
    }

    pub fn deinit(self: *AddressSpace) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.gpu_tracker.deinit(self.allocator);
        for (&self.publication_views) |*entry| {
            if (entry.*) |cached| cached.view.deinit();
            entry.* = null;
        }
        self.discardMappingsLocked();
        self.releaseReservations();
        if (self.direct_backing) |*backing| backing.deinit();
        self.direct_backing = null;
        self.direct_committed.deinit(self.allocator);
        self.reservations.deinit(self.allocator);
        self.reservations = .empty;
        self.mappings.deinit(self.allocator);
        self.mappings = .empty;
    }

    /// Commits an exact guest range. The host must return the requested address;
    /// relocation to a different address is never accepted.
    pub fn mapFixed(
        self: *AddressSpace,
        address: u64,
        size: u64,
        protection: Protection,
        kind: MappingKind,
        backing_offset: ?u64,
    ) Error!void {
        try validateMappedRange(address, size);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.mapFixedLocked(address, size, protection, kind, backing_offset);
    }

    /// Finds and commits the first suitable free range in `area`.
    ///
    /// `hint` is a lower bound, not a request that may be silently ignored.
    pub fn map(
        self: *AddressSpace,
        area: Area,
        hint: u64,
        size: u64,
        alignment: u64,
        protection: Protection,
        kind: MappingKind,
        backing_offset: ?u64,
    ) Error!u64 {
        if (size == 0 or !isAligned(size, page_size)) return Error.InvalidSize;
        const effective_alignment = @max(alignment, page_size);
        if (!std.math.isPowerOfTwo(effective_alignment)) return Error.InvalidAlignment;

        self.mutex.lock();
        defer self.mutex.unlock();

        const window = area.range();
        const search_start = if (hint == 0) window.start else @max(hint, window.start);
        const address = self.findFreeLocked(window, search_start, size, effective_alignment) orelse
            return Error.AddressUnavailable;

        try self.mapFixedLocked(address, size, protection, kind, backing_offset);
        return address;
    }

    /// Marks an exact guest range as reserved without committing physical
    /// pages. A later fixed mapping may consume this metadata reservation.
    pub fn reserveFixed(self: *AddressSpace, address: u64, size: u64) Error!void {
        try validateMappedRange(address, size);

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.reserveFixedLocked(address, size);
    }

    /// Finds and records a virtual reservation in one guest address window.
    pub fn reserve(
        self: *AddressSpace,
        area: Area,
        hint: u64,
        size: u64,
        alignment: u64,
    ) Error!u64 {
        if (size == 0 or !isAligned(size, page_size)) return Error.InvalidSize;
        const effective_alignment = @max(alignment, page_size);
        if (!std.math.isPowerOfTwo(effective_alignment)) return Error.InvalidAlignment;

        self.mutex.lock();
        defer self.mutex.unlock();

        const window = area.range();
        const search_start = if (hint == 0) window.start else @max(hint, window.start);
        const address = self.findFreeLocked(window, search_start, size, effective_alignment) orelse
            return Error.AddressUnavailable;
        try self.reserveFixedLocked(address, size);
        return address;
    }

    /// Records a very large semantic reservation even when small host-owned
    /// allocations split the architectural window. Windows can place its main
    /// thread stack or process heap near the middle of the sub-terabyte PS5
    /// user range, leaving two ~470 GiB placeholders and making a 512 GiB
    /// virtual-only request fail despite almost the whole window being free.
    ///
    /// Concrete mappings remain strict: `mapInReservation` below accepts a
    /// subrange only when that exact subrange belongs to one host placeholder.
    /// Thus an unreachable host hole can live under reservation metadata, but
    /// guest pages can never replace or overwrite it.
    pub fn reserveSpanningHostHoles(
        self: *AddressSpace,
        area: Area,
        hint: u64,
        size: u64,
        alignment: u64,
    ) Error!u64 {
        if (size == 0 or !isAligned(size, page_size)) return Error.InvalidSize;
        const effective_alignment = @max(alignment, page_size);
        if (!std.math.isPowerOfTwo(effective_alignment)) return Error.InvalidAlignment;

        self.mutex.lock();
        defer self.mutex.unlock();

        const window = area.range();
        const search_start = if (hint == 0) window.start else @max(hint, window.start);
        const address = self.findLogicalFreeLocked(
            window,
            search_start,
            size,
            effective_alignment,
        ) orelse return Error.AddressUnavailable;
        try self.mappings.ensureUnusedCapacity(self.allocator, 1);
        const index = self.insertionIndex(address);
        self.mappings.insertAssumeCapacity(index, .{
            .address = address,
            .size = size,
            .protection = .none,
            .kind = .reserved,
            .protection_bits = 0,
            .name = namedMapping("anon"),
        });
        return address;
    }

    /// Prints the host-owned pieces of one guest window. This is deliberately
    /// only a failure-path diagnostic: Windows ASLR can place an allocation in
    /// the console's sub-terabyte window before AddressSpace is initialized,
    /// and the resulting hole is otherwise invisible in a guest ENOMEM.
    pub fn announceOwnedRanges(self: *AddressSpace, area: Area) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const window = area.range();
        for (self.reservations.items) |reservation| {
            const start = @max(window.start, reservation.start);
            const end = @min(window.end, reservation.end);
            if (start >= end) continue;
            std.debug.print(
                "[memory owned] area={s} start=0x{x} end=0x{x} size=0x{x}\n",
                .{ @tagName(area), start, end, end - start },
            );
        }
    }

    /// Changes permissions over a fully mapped range. Mapping metadata is split
    /// where necessary so later queries retain page-accurate protection.
    pub fn protect(
        self: *AddressSpace,
        address: u64,
        size: u64,
        protection: Protection,
    ) Error!void {
        return self.protectGuest(address, size, protection, protection.guestBits());
    }

    /// Changes host permissions and the original guest ABI protection mask as
    /// one mapping-table transaction. HLE uses this to retain GPU access bits.
    pub fn protectGuest(
        self: *AddressSpace,
        address: u64,
        size: u64,
        protection: Protection,
        protection_bits: i32,
    ) Error!void {
        return self.protectGuestWithType(address, size, protection, protection_bits, null);
    }

    pub fn protectGuestWithType(
        self: *AddressSpace,
        address: u64,
        size: u64,
        protection: Protection,
        protection_bits: i32,
        memory_type: ?i32,
    ) Error!void {
        try validateMappedRange(address, size);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.coversCommittedLocked(address, size)) return Error.RangeNotMapped;

        self.invalidateGpuTrackingLocked(address, size);

        var replacement: std.ArrayList(Mapping) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.ensureTotalCapacity(self.allocator, self.mappings.items.len + 2);
        try appendTransformed(
            self.allocator,
            &replacement,
            self.mappings.items,
            address,
            size,
            protection,
            protection_bits,
            false,
        );
        if (memory_type) |value| for (replacement.items) |*mapping| {
            if (mapping.address >= address and mapping.end() <= address + size) mapping.memory_type = value;
        };

        hostProtect(address, size, protection) catch {
            self.host_mapping_state_uncertain = true;
            return Error.ProtectionDenied;
        };

        self.mappings.deinit(self.allocator);
        self.mappings = replacement;
    }

    /// Decommits pages while preserving the outer fixed-address reservation.
    pub fn unmap(self: *AddressSpace, address: u64, size: u64) Error!void {
        try validateMappedRange(address, size);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.coversLocked(address, size, null)) return Error.RangeNotMapped;

        // A later partial host view must be rejected before any earlier view
        // is removed. Protection splits can divide a view into several guest
        // intervals, so validate the same merged runs used for the mutation.
        try self.hostUnmapLocked(address, size, true);
        self.invalidateGpuTrackingLocked(address, size);

        // Rebuilding the table here cost the whole of it per call, and a batch
        // unmap is hundreds of calls against tens of thousands of intervals.
        // Reserve the one interval a middle split can add before touching host
        // state; after that the edit itself cannot fail, so a failed host
        // transaction still leaves the table describing what is really mapped.
        const end = address + size;
        const span = overlappingMappingSpan(self.mappings.items, address, end);
        const free_range = freeRangeAroundSpan(
            self.reservations.items,
            self.mappings.items,
            span,
            address,
            end,
        ) orelse return Error.HostDecommitFailed;
        try self.mappings.ensureUnusedCapacity(self.allocator, 1);

        self.hostUnmapLocked(address, size, false) catch |err| {
            if (!self.host_mapping_state_uncertain) std.debug.print(
                "[memory] host unmap failed address=0x{x} size=0x{x}; verifying native page access\n",
                .{ address, size },
            );
            self.host_mapping_state_uncertain = true;
            return err;
        };
        removeMappingSpanAssumeCapacity(&self.mappings, span, address, end);
        // Coalescing is only an optimization. The pages are already unmapped;
        // its failure cannot roll back that fact or retain readable metadata.
        hostCoalescePlaceholder(free_range) catch {};
    }

    pub fn isMapped(self: *AddressSpace, address: u64, size: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.coversLocked(address, size, null);
    }

    /// Identifies one allocation even after protection or metadata splits.
    /// Zero declines a proof for holes, reservations and multiple allocations.
    pub fn mappingIdentity(self: *AddressSpace, address: u64, size: usize) u64 {
        if (size == 0) return 0;
        const end = std.math.add(u64, address, size) catch return 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        var cursor = address;
        var identity: u64 = 0;
        const first = firstOverlappingMapping(self.mappings.items, address);
        for (self.mappings.items[first..]) |mapping| {
            if (mapping.address > cursor or mapping.kind == .reserved or mapping.identity == 0) return 0;
            if (identity != 0 and identity != mapping.identity) return 0;
            identity = mapping.identity;
            cursor = @min(end, mapping.end());
            if (cursor == end) return identity;
        }
        return 0;
    }

    fn nextMappingIdentity(self: *AddressSpace) u64 {
        self.mapping_identity +%= 1;
        if (self.mapping_identity == 0) self.mapping_identity = 1;
        return self.mapping_identity;
    }

    /// A fixed direct-memory request can retain an identical complete mapping.
    /// Restrict reuse to one exact entry so partial replacements and metadata
    /// boundaries continue through the normal unmap/map transaction.
    pub fn matchesDirectMemoryMapping(self: *AddressSpace, address: u64, size: u64, offset: u64, protection: Protection) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (size == 0) return false;
        const index = self.insertionIndex(address);
        if (index == self.mappings.items.len) return false;
        const mapping = self.mappings.items[index];
        return mapping.address == address and mapping.size == size and
            mapping.kind == .direct_memory and mapping.backing_offset == offset and
            std.meta.eql(mapping.protection, protection);
    }

    /// Stable physical identity for an entire readable direct-memory range.
    /// Private pages and ranges crossing a mapping boundary use the copy path.
    pub fn directMemoryOffset(self: *AddressSpace, address: u64, size: usize) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.directMemoryOffsetLocked(address, size);
    }

    fn directMemoryOffsetLocked(self: *AddressSpace, address: u64, size: usize) ?u64 {
        if (size == 0) return null;
        for (self.mappings.items) |mapping| {
            if (mapping.kind != .direct_memory or !mapping.protection.read) continue;
            if (address < mapping.address or address >= mapping.end() or size > mapping.end() - address) continue;
            return (mapping.backing_offset orelse continue) + (address - mapping.address);
        }
        return null;
    }

    /// Recheck identity under the mapping lock before acquiring an independent
    /// view. The returned view remains valid after guest unmap/remap or deinit.
    pub fn pinDirectMemory(self: *AddressSpace, address: u64, size: usize, expected_offset: u64) ?SharedView {
        self.mutex.lock();
        defer self.mutex.unlock();
        if ((self.directMemoryOffsetLocked(address, size) orelse return null) != expected_offset) return null;
        const backing = if (self.direct_backing) |*value| value else return null;
        const view = backing.mapView(expected_offset, size) catch return null;
        if (!isHostRangeReadable(@intFromPtr(view.bytes.ptr), view.bytes.len)) {
            view.deinit();
            return null;
        }
        return view;
    }

    /// Publish an independent GPU readback through a writable physical alias,
    /// preserving the guest's CPU-write watches. Returns unchanged bytes, or
    /// null before modifying anything when the ordinary copy path is needed.
    /// Only a single readable/writable direct mapping with no guest aliases is
    /// eligible; private memory, split mappings and uncertain host state fall
    /// back. Mapping and tracker locks cover both the copy and its generations.
    pub fn publishGpuBytes(self: *AddressSpace, address: u64, source: []const u8) ?usize {
        return self.publishGpuBytesWithPattern(address, source, null);
    }

    /// The renderer must supply exactly the repeated little-endian word in
    /// source. Full watched pages can then remember that value until a CPU or
    /// GPU publication changes their generation. Partial writes cannot certify
    /// an entire page. Unaligned ranges retain the ordinary byte comparison.
    pub fn publishGpuUniform32(self: *AddressSpace, address: u64, source: []const u8, value: u32) ?usize {
        const pattern: ?u32 = if (address & 3 == 0 and source.len & 3 == 0 and
            @atomicLoad(bool, &known_uniform_publications, .monotonic)) value else null;
        return self.publishGpuBytesWithPattern(address, source, pattern);
    }

    fn publishGpuBytesWithPattern(self: *AddressSpace, address: u64, source: []const u8, pattern: ?u32) ?usize {
        if (builtin.os.tag != .windows or source.len == 0 or source.len > 64 * 1024 * 1024) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.host_mapping_state_uncertain) return null;
        const backing = if (self.direct_backing) |*value| value else return null;
        const index = owner: {
            var i = self.insertionIndex(address);
            if (i == self.mappings.items.len or self.mappings.items[i].address != address) {
                if (i == 0) return null;
                i -= 1;
            }
            const mapping = self.mappings.items[i];
            // x86/Windows write permission also permits reads, including the
            // GPU garlic mappings whose guest CPU mask contains only WRITE.
            if (mapping.kind != .direct_memory or !mapping.protection.write or
                address < mapping.address or address >= mapping.end() or source.len > mapping.end() - address)
                return null;
            break :owner i;
        };
        const owner = self.mappings.items[index];
        const physical = (owner.backing_offset orelse return null) + address - owner.address;
        for (self.mappings.items, 0..) |mapping, other| {
            if (other == index or mapping.kind != .direct_memory) continue;
            const offset = mapping.backing_offset orelse continue;
            if (physical < offset + mapping.size and offset < physical + source.len) return null;
        }
        const destination = alias: {
            for (self.publication_views) |maybe| if (maybe) |cached| {
                if (physical >= cached.physical and physical - cached.physical <= cached.view.bytes.len and
                    source.len <= cached.view.bytes.len - (physical - cached.physical))
                    break :alias cached.view.bytes[@intCast(physical - cached.physical)..][0..source.len];
            };
            // A streaming workload can touch more windows than this bounded
            // cache holds. Preserve hot aliases and use the ordinary copy for
            // new ranges instead of mapping/unmapping every publication.
            if (self.next_publication_view == self.publication_views.len) return null;
            // Neighbouring render targets/readbacks share one sparse alias.
            // Mapping a wider SEC_RESERVE view does not commit its unused
            // pages; only the currently validated request is ever touched.
            const window = 64 * 1024 * 1024;
            const first = std.mem.alignBackward(u64, physical, window);
            const end = @min(backing.size, std.mem.alignForward(u64, physical + source.len, window));
            const view = backing.mapView(first, @intCast(end - first)) catch return null;
            const bytes = view.bytes[@intCast(physical - first)..][0..source.len];
            if (!isHostRangeReadable(@intFromPtr(bytes.ptr), bytes.len)) {
                view.deinit();
                return null;
            }
            const slot = &self.publication_views[self.next_publication_view];
            slot.* = .{ .physical = first, .view = view };
            self.next_publication_view += 1;
            break :alias bytes;
        };
        const tracker = &self.gpu_tracker;
        tracker.lock.lock();
        defer tracker.lock.unlock();
        var cursor: usize = 0;
        var unchanged: usize = 0;
        var avoided: usize = 0;
        while (cursor < source.len) {
            const page = (address + cursor) & ~(page_size - 1);
            const end = cursor + @min(source.len - cursor, page_size - ((address + cursor) - page));
            const uniform_page = if (pattern != null and tracker.enabled) tracker.pages.getPtr(page) else null;
            const known_equal = if (uniform_page) |tracked| tracked.armed and
                tracked.uniform_generation != 0 and tracked.uniform_generation == tracked.generation and
                tracked.uniform_value == pattern.? else false;
            if (known_equal) {
                unchanged += end - cursor;
                avoided += end - cursor;
            } else if (std.mem.eql(u8, destination[cursor..end], source[cursor..end])) {
                unchanged += end - cursor;
            } else {
                @memcpy(destination[cursor..end], source[cursor..end]);
                if (tracker.enabled) if (tracker.pages.getPtr(page)) |tracked| {
                    // Keep armed exactly as it was. A later native CPU write
                    // still faults and advances the generation a second time.
                    tracked.generation = tracker.nextGeneration(page);
                };
            }
            if (uniform_page) |tracked| {
                if (tracked.armed and address + cursor == page and end - cursor == page_size) {
                    tracked.uniform_generation = tracked.generation;
                    tracked.uniform_value = pattern.?;
                }
            }
            cursor = end;
        }
        if (avoided != 0) _ = @atomicRmw(u64, &uniform_publication_compares_avoided, .Add, avoided, .monotonic);
        return unchanged;
    }

    /// Whether every byte is backed by committed, CPU-readable guest pages.
    ///
    /// `isMapped` intentionally includes virtual reservations because kernel
    /// queries need to see them. HLE code must use this stricter predicate
    /// before turning a guest integer into a native pointer: reserved and
    /// GPU-only/no-access mappings have no host-readable storage.
    pub fn isReadable(self: *AddressSpace, address: u64, size: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.coversWithProtectionLocked(address, size, .read);
    }

    pub const ReadLease = struct {
        bytes: []const u8,
        space: *AddressSpace,

        pub fn release(self: *ReadLease) void {
            self.space.mutex.unlock();
            self.* = undefined;
        }
    };

    /// Keep guest unmap/protect operations out of a native read or hash. The
    /// caller must release the lease before calling another AddressSpace API.
    /// Host-owned CRT memory retains its accessibility fallback; this lock
    /// only serializes mappings owned by this address space, not CRT frees.
    pub fn borrowReadable(self: *AddressSpace, address: u64, size: usize) ?ReadLease {
        if (size != 0 and address == 0) return null;
        _ = std.math.add(u64, address, size) catch return null;
        self.mutex.lock();
        if (size != 0 and !self.coversWithProtectionLocked(address, size, .read) and
            !isHostRangeReadable(address, size))
        {
            self.mutex.unlock();
            return null;
        }
        return .{
            .bytes = if (size == 0) &.{} else @as([*]const u8, @ptrFromInt(address))[0..size],
            .space = self,
        };
    }

    /// Whether every byte is backed by committed, CPU-writable guest pages.
    pub fn isWritable(self: *AddressSpace, address: u64, size: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.coversWithProtectionLocked(address, size, .write);
    }

    pub fn isMappedAs(
        self: *AddressSpace,
        address: u64,
        size: u64,
        kind: MappingKind,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.coversLocked(address, size, kind);
    }

    /// Returns the mapping containing `address`, or the first mapping after it
    /// when `find_next` is set. This mirrors the firmware's VirtualQuery walk.
    pub fn query(self: *AddressSpace, address: u64, find_next: bool) ?Mapping {
        self.mutex.lock();
        defer self.mutex.unlock();

        const index = self.insertionIndex(address);
        if (index > 0) {
            const previous = self.mappings.items[index - 1];
            if (address < previous.end()) return previous;
        }
        if (index < self.mappings.items.len and
            self.mappings.items[index].address == address)
        {
            return self.mappings.items[index];
        }
        return if (find_next and index < self.mappings.items.len)
            self.mappings.items[index]
        else
            null;
    }

    pub fn mappedBytes(self: *AddressSpace, kind: MappingKind) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var total: u64 = 0;
        for (self.mappings.items) |mapping| {
            if (mapping.kind == kind) total += mapping.size;
        }
        return total;
    }

    /// Updates guest-visible metadata while preserving host mappings. The
    /// interval table is split at the requested boundaries so later queries
    /// report attributes for precisely the range the kernel call changed.
    pub fn setMetadata(
        self: *AddressSpace,
        address: u64,
        size: u64,
        metadata: MappingMetadata,
    ) Error!void {
        try validateMappedRange(address, size);
        if (metadata.name) |name| {
            if (name.len >= maximum_name_length) return Error.InvalidSize;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.coversLocked(address, size, null)) return Error.RangeNotMapped;

        try updateMappingMetadata(self.allocator, &self.mappings, address, size, metadata);
    }

    /// Removes every mapping that views a physical direct-memory range.
    ///
    /// Physical memory is owned by offset, and a mapping is a window onto it. A
    /// title that hands the memory back has given up what those windows look at,
    /// so they cannot outlive it: leaving them would let the pool hand the same
    /// offsets to another allocation while stale aliases still reach them, which
    /// is the one way an emulated address space can corrupt a title invisibly.
    ///
    /// A title is not required to take the windows down first. Real firmware
    /// does this for it, and refusing the release until it does would fail every
    /// hand-back a title makes.
    ///
    /// Returns how many mapped slices were removed. Aliases outside the
    /// released physical interval retain their pages and contents.
    pub fn unmapDirectMemoryBacking(self: *AddressSpace, offset: u64, size: u64) usize {
        if (size == 0) return 0;
        const end = std.math.add(u64, offset, size) catch return 0;

        var removed: usize = 0;
        while (true) {
            const victim = self.findDirectMemoryAlias(offset, end) orelse return removed;
            // Dropped outside the lock the search took, because unmapping takes
            // it again. Each successful removal eliminates one overlap with
            // the released interval, even when it splits a surviving mapping.
            self.unmap(victim.address, victim.size) catch return removed;
            removed += 1;
        }
    }

    fn findDirectMemoryAlias(self: *AddressSpace, offset: u64, end: u64) ?Mapping {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.mappings.items) |mapping| {
            if (mapping.kind != .direct_memory) continue;
            const mapping_offset = mapping.backing_offset orelse continue;
            const mapping_end = std.math.add(u64, mapping_offset, mapping.size) catch continue;
            if (mapping_offset < end and offset < mapping_end) {
                const overlap_start = @max(offset, mapping_offset);
                const overlap_end = @min(end, mapping_end);
                return offsetMapping(mapping, mapping.address + overlap_start - mapping_offset, overlap_end - overlap_start);
            }
        }
        return null;
    }

    /// Reports whether a physical direct-memory range is visible through any
    /// guest mapping.
    pub fn hasDirectMemoryMappings(self: *AddressSpace, offset: u64, size: u64) bool {
        if (size == 0) return false;
        const end = std.math.add(u64, offset, size) catch return true;

        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.mappings.items) |mapping| {
            if (mapping.kind != .direct_memory) continue;
            const mapping_offset = mapping.backing_offset orelse continue;
            const mapping_end = std.math.add(u64, mapping_offset, mapping.size) catch
                return true;
            if (mapping_offset < end and offset < mapping_end) return true;
        }
        return false;
    }

    /// Copies into guest memory only when the entire destination is mapped and
    /// writable. The identity mapping makes the final copy a normal host copy.
    pub fn write(self: *AddressSpace, address: u64, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        const size: u64 = @intCast(bytes.len);

        // A tracked writable page is host-read-only until its first CPU write.
        // Disarm it before taking the mapping lock and before memcpy touches it.
        self.notifyGuestWrite(address, bytes.len);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.coversWithProtectionLocked(address, size, .write)) {
            return Error.ProtectionDenied;
        }

        const destination: [*]u8 = @ptrFromInt(address);
        @memcpy(destination[0..bytes.len], bytes);
    }

    /// Enables page-generation tracking. It is kept opt-in because loader and
    /// unit-test address spaces do not need the write-fault machinery.
    pub fn enableGpuMemoryTracking(self: *AddressSpace) void {
        self.gpu_tracker.lock.lock();
        defer self.gpu_tracker.lock.unlock();
        self.gpu_tracker.enabled = true;
    }

    /// Marks every guest page in a GPU source range as observed and makes
    /// writable pages read-only at the host level. The first subsequent CPU
    /// write is caught by the native fault handler, restores the logical guest
    /// protection, and advances that page's generation.
    pub fn trackGpuRead(self: *AddressSpace, address: u64, size: usize) Error!u64 {
        if (size == 0) return 0;
        const byte_size: u64 = @intCast(size);
        const range_end = std.math.add(u64, address, byte_size) catch return Error.InvalidSize;
        const first_page = address & ~(page_size - 1);
        const end_page = alignForward(range_end, page_size) orelse return Error.InvalidSize;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.coversWithProtectionLocked(address, byte_size, .read)) return Error.ProtectionDenied;

        const tracker = &self.gpu_tracker;
        tracker.lock.lock();
        defer tracker.lock.unlock();
        if (!tracker.enabled) return 0;

        // A positive observation already proves that every writable page is
        // armed. Unrelated writes need not walk and recheck this whole range.
        if (tracker.cachedRangeGeneration(first_page, end_page)) |generation| return generation;

        var fingerprint: u64 = 0xcbf2_9ce4_8422_2325;
        var page = first_page;
        const reuse_armed = @atomicLoad(bool, &reuse_armed_gpu_pages, .monotonic);
        var reused_pages: u64 = 0;
        defer if (reused_pages != 0) {
            _ = @atomicRmw(u64, &armed_gpu_page_reuses, .Add, reused_pages, .monotonic);
        };
        while (page < end_page) {
            // The mapping mutex excludes unmap/protect; those operations
            // remove tracked entries before changing a mapping. An armed
            // page (or a logically read-only page) therefore already carries
            // the current mapping permissions. A write fault disarms it and
            // takes the original registration/protection path below.
            if (reuse_armed) if (tracker.pages.getPtr(page)) |tracked| {
                if (tracked.armed or !tracked.restore_protection.write) {
                    fingerprintGpuPage(&fingerprint, page, tracked.generation);
                    reused_pages += 1;
                    page += page_size;
                    continue;
                }
            };
            const mapping = self.mappingForPageLocked(page) orelse return Error.RangeNotMapped;
            const can_batch = builtin.os.tag == .windows and
                hostMappingViewSize(mapping.kind, mapping.address, mapping.size, mapping.backing_offset) > page_size;
            const result = try tracker.pages.getOrPut(self.allocator, page);
            if (!result.found_existing) result.value_ptr.* = .{
                .generation = tracker.nextGeneration(page),
                .restore_protection = mapping.protection,
            };
            result.value_ptr.restore_protection = mapping.protection;
            result.value_ptr.batch_protection = can_batch;
            if (mapping.protection.write and !result.value_ptr.armed) {
                var run_end = page + page_size;
                if (can_batch) {
                    const limit = @min(end_page, mapping.end(), (page & ~(windows_allocation_granularity - 1)) + windows_allocation_granularity);
                    while (run_end < limit) : (run_end += page_size) {
                        if (tracker.pages.get(run_end)) |next| {
                            if (next.armed) break;
                        }
                    }
                    run_end = gpuProtectionRunEnd(page, run_end);
                }
                // Finish every potentially allocating insertion before changing
                // host permissions. Hash-map growth can invalidate result pointers.
                var next_page = page + page_size;
                while (next_page < run_end) : (next_page += page_size) {
                    const next = try tracker.pages.getOrPut(self.allocator, next_page);
                    if (!next.found_existing) next.value_ptr.* = .{
                        .generation = tracker.nextGeneration(next_page),
                        .restore_protection = mapping.protection,
                    };
                    next.value_ptr.restore_protection = mapping.protection;
                    next.value_ptr.batch_protection = can_batch;
                }
                var watched = mapping.protection;
                watched.read = true;
                watched.write = false;
                run_end = try tracker.protectRun(page, run_end, watched);
                // Native fault handlers share the tracker lock and cannot see
                // a partially published group. Each page retains its own epoch.
                while (page < run_end) : (page += page_size) {
                    const tracked = tracker.pages.getPtr(page).?;
                    tracked.armed = true;
                    fingerprintGpuPage(&fingerprint, page, tracked.generation);
                }
            } else {
                fingerprintGpuPage(&fingerprint, page, result.value_ptr.generation);
                page += page_size;
            }
        }
        return tracker.rememberRangeGeneration(first_page, end_page, fingerprint);
    }

    /// Epoch for caches of page-generation queries. A native write fault must
    /// invalidate those queries even when no renderer write callback runs.
    pub fn gpuTrackingEpoch(self: *const AddressSpace) u64 {
        return @atomicLoad(u64, &self.gpu_tracker.generation_counter, .acquire);
    }

    /// Returns the current ordered generation fingerprint, or zero when the
    /// range is untracked or writable without a watch. After the first write
    /// fault, further native writes are invisible until trackGpuRead rearms it.
    pub fn gpuGeneration(self: *AddressSpace, address: u64, size: usize) u64 {
        if (size == 0) return 0;
        const range_end = std.math.add(u64, address, @as(u64, @intCast(size))) catch return 0;
        const first_page = address & ~(page_size - 1);
        const end_page = alignForward(range_end, page_size) orelse return 0;
        const tracker = &self.gpu_tracker;
        tracker.lock.lock();
        defer tracker.lock.unlock();
        if (!tracker.enabled) return 0;
        if (tracker.cachedRangeGeneration(first_page, end_page)) |generation| return generation;

        var fingerprint: u64 = 0xcbf2_9ce4_8422_2325;
        var page = first_page;
        while (page < end_page) : (page += page_size) {
            const tracked = tracker.pages.get(page) orelse return 0;
            if (tracked.restore_protection.write and !tracked.armed) return 0;
            fingerprint ^= page;
            fingerprint *%= 0x100_0000_01b3;
            fingerprint ^= tracked.generation;
            fingerprint *%= 0x100_0000_01b3;
        }
        return tracker.rememberRangeGeneration(first_page, end_page, fingerprint);
    }

    /// An immutable CPU snapshot also needs protection against writes through
    /// independently mapped physical aliases. Conservatively decline those
    /// ranges, and include mapping creation/protection identity so an alias
    /// created, written and removed between observations cannot restore an old
    /// certificate. The ordinary GPU residency query retains its existing API.
    pub fn gpuSnapshotGeneration(self: *AddressSpace, address: u64, size: usize) u64 {
        if (size == 0) return 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.host_mapping_state_uncertain) return 0;
        const mapping = self.mappingForPageLocked(address & ~(page_size - 1)) orelse return 0;
        if (address < mapping.address or address >= mapping.end() or size > mapping.end() - address) return 0;
        if (mapping.kind == .direct_memory) {
            const physical = (mapping.backing_offset orelse return 0) + address - mapping.address;
            for (self.mappings.items) |other| {
                if (other.address == mapping.address or other.kind != .direct_memory) continue;
                const offset = other.backing_offset orelse continue;
                if (physical < offset + other.size and offset < physical + size) return 0;
            }
        }
        const generation = self.gpuGeneration(address, size);
        if (generation == 0) return 0;
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&[_]u64{ generation, self.mapping_identity }));
    }

    /// Invalidates tracked pages before an emulator/HLE write. Native guest
    /// writes take the exception path below instead.
    pub fn notifyGuestWrite(self: *AddressSpace, address: u64, size: usize) void {
        if (size == 0) return;
        const range_end = std.math.add(u64, address, @as(u64, @intCast(size))) catch return;
        const first_page = address & ~(page_size - 1);
        const end_page = alignForward(range_end, page_size) orelse return;
        const tracker = &self.gpu_tracker;
        tracker.lock.lock();
        defer tracker.lock.unlock();
        if (!tracker.enabled) return;

        var page = first_page;
        while (page < end_page) {
            const tracked = tracker.pages.getPtr(page) orelse {
                page += page_size;
                continue;
            };
            var run_end = page + page_size;
            if (tracked.armed) {
                if (tracked.batch_protection) {
                    const limit = @min(end_page, (page & ~(windows_allocation_granularity - 1)) + windows_allocation_granularity);
                    while (run_end < limit) : (run_end += page_size) {
                        const next = tracker.pages.get(run_end) orelse break;
                        if (!next.armed or !next.batch_protection or
                            next.restore_protection.guestBits() != tracked.restore_protection.guestBits()) break;
                    }
                    run_end = gpuProtectionRunEnd(page, run_end);
                }
                run_end = tracker.protectRun(page, run_end, tracked.restore_protection) catch {
                    page += page_size;
                    continue;
                };
            }
            while (page < run_end) : (page += page_size) {
                const changed = tracker.pages.getPtr(page).?;
                changed.armed = false;
                changed.generation = tracker.nextGeneration(page);
            }
        }
    }

    /// Handles the first native CPU store after a GPU observation. This path is
    /// deliberately allocation-free because Windows calls it from a vectored
    /// exception handler on arbitrary guest worker threads.
    pub fn handleGpuTrackedWriteFault(self: *AddressSpace, fault_address: u64) bool {
        const page = fault_address & ~(page_size - 1);
        const tracker = &self.gpu_tracker;
        tracker.lock.lock();
        defer tracker.lock.unlock();
        if (!tracker.enabled) return false;
        const tracked = tracker.pages.getPtr(page) orelse return false;
        if (!tracked.restore_protection.write) return false;
        if (!tracked.armed) {
            // Two writers can fault before either handler gets this lock.
            // The first handler (or an HLE write) already restored access;
            // the second must retry its store instead of killing the guest.
            // Only accept a now-writable host address: unrelated protection
            // faults and unmapped pages still belong to the normal handler.
            return windowsRangeAccessible(fault_address, 1, .write);
        }
        _ = tracker.protectRun(page, page + page_size, tracked.restore_protection) catch return false;
        tracked.armed = false;
        tracked.generation = tracker.nextGeneration(page);
        return true;
    }

    /// Copies from guest memory only when the entire source is mapped and
    /// readable.
    pub fn read(self: *AddressSpace, address: u64, out: []u8) Error!void {
        if (out.len == 0) return;
        const size: u64 = @intCast(out.len);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.coversWithProtectionLocked(address, size, .read)) {
            return Error.ProtectionDenied;
        }

        const source: [*]const u8 = @ptrFromInt(address);
        @memcpy(out, source[0..out.len]);
    }

    pub fn writeInt(self: *AddressSpace, comptime T: type, address: u64, value: T) Error!void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try self.write(address, &bytes);
    }

    pub fn flushInstructionCache(_: *AddressSpace, address: u64, size: u64) void {
        // The only native guest target is x86-64, whose instruction and data
        // caches are coherent. Keep this boundary explicit for a future
        // translated ARM64 backend, where cache maintenance will be required.
        _ = address;
        _ = size;
    }

    pub fn snapshot(self: *AddressSpace, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Mapping {
        self.mutex.lock();
        defer self.mutex.unlock();
        return allocator.dupe(Mapping, self.mappings.items);
    }

    fn mapFixedLocked(
        self: *AddressSpace,
        address: u64,
        size: u64,
        protection: Protection,
        kind: MappingKind,
        backing_offset: ?u64,
    ) Error!void {
        if (!self.ownsLocked(address, size)) {
            std.debug.print("[memory] fixed map not owned addr=0x{x} size=0x{x} kind={s}\n", .{ address, size, @tagName(kind) });
            return Error.AddressUnavailable;
        }
        if (self.overlapsLocked(address, size)) {
            std.debug.print("[memory] fixed map overlaps addr=0x{x} size=0x{x} kind={s}\n", .{ address, size, @tagName(kind) });
            return Error.AddressUnavailable;
        }
        try self.mappings.ensureUnusedCapacity(self.allocator, 1);

        // Adjacent guest reservations may share larger host placeholders.
        // After replacing only part of them, a metadata boundary can fall
        // inside the next placeholder. Coalescing up to that artificial end
        // fails on Windows. The overlap check above still protects all guest
        // mappings; only placeholder preparation may cross reserved metadata.
        const free_range = self.hostFreeRangeIgnoringReservationsLocked(address, size) orelse {
            std.debug.print("[memory] fixed map has no host extent addr=0x{x} size=0x{x} kind={s}\n", .{ address, size, @tagName(kind) });
            return Error.AddressUnavailable;
        };
        const host_view_size = hostMappingViewSize(kind, address, size, backing_offset);
        try hostPrepareMappingPlaceholders(free_range, address, size, host_view_size);
        errdefer hostCoalescePlaceholder(free_range) catch {};

        if (kind == .direct_memory) {
            const offset = backing_offset orelse return Error.BackingOffsetInvalid;
            const backing = if (self.direct_backing) |*value| value else return Error.BackingStoreUnavailable;
            const backing_end = std.math.add(u64, offset, size) catch
                return Error.BackingOffsetInvalid;
            if (!isAligned(offset, page_size) or backing_end > backing.size) {
                return Error.BackingOffsetInvalid;
            }
            try hostMapBacking(backing, address, size, offset, protection, &self.direct_committed);
            errdefer hostUnmapBacking(address, size) catch {};
        } else {
            if (backing_offset != null) return Error.BackingOffsetInvalid;
            try hostCommit(address, size, protection);
            errdefer hostDecommit(address, size) catch {};
        }

        const index = self.insertionIndex(address);
        self.mappings.insertAssumeCapacity(index, .{
            .address = address,
            .size = size,
            .protection = protection,
            .kind = kind,
            .identity = self.nextMappingIdentity(),
            .backing_offset = backing_offset,
            .protection_bits = protection.guestBits(),
        });
    }

    /// Commits a mapping inside a range the guest has already reserved.
    ///
    /// Mapping into a reservation is the whole point of reserving, and titles
    /// routinely map less than they reserved, in several pieces. Releasing the
    /// reservation and mapping afterwards only works when the two match
    /// exactly: the host placeholder covering the reservation has to be split
    /// for the sub-range, whereas releasing tries to coalesce it with
    /// neighbouring free space that is not part of the same placeholder.
    ///
    /// Returns `RangeNotMapped` when the range is not wholly inside one
    /// reservation, so the caller can fall back to ordinary fixed mapping.
    /// Number of guest-visible intervals, including semantic reservations.
    pub fn mappingCount(self: *AddressSpace) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.mappings.items.len;
    }

    pub fn mapInReservation(
        self: *AddressSpace,
        address: u64,
        size: u64,
        protection: Protection,
        kind: MappingKind,
        backing_offset: ?u64,
    ) Error!void {
        try validateMappedRange(address, size);

        self.mutex.lock();
        defer self.mutex.unlock();

        const found = firstOverlappingMapping(self.mappings.items, address);
        if (found < self.mappings.items.len and self.mappings.items[found].pooled) return Error.RangeNotMapped;
        return self.mapInReservationLocked(address, size, protection, kind, backing_offset);
    }

    fn mapInReservationLocked(self: *AddressSpace, address: u64, size: u64, protection: Protection, kind: MappingKind, backing_offset: ?u64) Error!void {
        const index = firstOverlappingMapping(self.mappings.items, address);
        if (index == self.mappings.items.len) return Error.RangeNotMapped;
        const reservation = self.mappings.items[index];
        if (reservation.kind != .reserved or reservation.address > address or
            address + size > reservation.end()) return Error.RangeNotMapped;

        // Reserve only the two possible boundary splits before touching host
        // memory. After a successful host map, publishing metadata cannot fail.
        const extra: usize = @as(usize, @intFromBool(reservation.address < address)) +
            @intFromBool(address + size < reservation.end());
        try self.mappings.ensureUnusedCapacity(self.allocator, extra);

        // Guest reservations are metadata. A later reservation can coalesce
        // the remaining host placeholders, so query the actual host boundary
        // even when this reservation does not span a host-owned hole.
        const placeholder = self.hostFreeRangeIgnoringReservationsLocked(address, size) orelse
            return Error.AddressUnavailable;
        const host_view_size = hostMappingViewSize(kind, address, size, backing_offset);
        try hostPrepareMappingPlaceholders(placeholder, address, size, host_view_size);
        errdefer hostCoalescePlaceholder(placeholder) catch {};

        if (kind == .direct_memory) {
            const offset = backing_offset orelse return Error.BackingOffsetInvalid;
            const backing = if (self.direct_backing) |*value| value else return Error.BackingStoreUnavailable;
            const backing_end = std.math.add(u64, offset, size) catch
                return Error.BackingOffsetInvalid;
            if (!isAligned(offset, page_size) or backing_end > backing.size) {
                return Error.BackingOffsetInvalid;
            }
            try hostMapBacking(backing, address, size, offset, protection, &self.direct_committed);
            errdefer hostUnmapBacking(address, size) catch {};
        } else {
            if (backing_offset != null) return Error.BackingOffsetInvalid;
            try hostCommit(address, size, protection);
            errdefer hostDecommit(address, size) catch {};
        }

        replaceReservationAssumeCapacity(&self.mappings, index, .{
            .address = address,
            .size = size,
            .protection = protection,
            .kind = kind,
            .identity = self.nextMappingIdentity(),
            // Carried through, not dropped. This mapping is a window onto
            // physical memory, and the offset is the only record of which
            // physical memory: without it a title asking what backs the address
            // is told zero, and everything it does with that answer — releasing
            // the memory, in particular — names the wrong region.
            .backing_offset = backing_offset,
            .protection_bits = 0,
            .pooled = reservation.pooled,
            .name = if (reservation.pooled) reservation.name else namedMapping("anon"),
        });
    }

    pub fn hasPooledMappings(self: *AddressSpace, address: u64, size: u64) bool {
        const end = std.math.add(u64, address, size) catch return true;
        self.mutex.lock();
        defer self.mutex.unlock();
        const first = firstOverlappingMapping(self.mappings.items, address);
        for (self.mappings.items[first..]) |mapping| {
            if (mapping.address >= end) break;
            if (mapping.pooled) return true;
        }
        return false;
    }

    /// Commit donated physical spans as one operation. Allocate all interval
    /// storage before touching native pages; failure restores the reservations.
    pub fn commitPooled(self: *AddressSpace, address: u64, size: u64, backing: []const PoolBacking, protection: Protection, bits: i32, memory_type: i32) Error!void {
        try validateMappedRange(address, size);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validatePooledLocked(address, size, true);
        var total: u64 = 0;
        for (backing) |part| {
            if (part.size == 0 or part.size % page_size != 0) return Error.InvalidSize;
            total = std.math.add(u64, total, part.size) catch return Error.InvalidSize;
        }
        if (total != size) return Error.InvalidSize;
        // Existing reservation/name boundaries do not add entries: only the
        // physical-span boundaries and the two ends of this commit can do so.
        // Keep two spare slots for rollback without scaling to the whole table.
        try self.mappings.ensureUnusedCapacity(self.allocator, backing.len + 3);
        var cursor = address;
        errdefer if (cursor != address) {
            self.decommitPooledLocked(address, cursor - address) catch {
                self.host_mapping_state_uncertain = true;
            };
        };
        for (backing) |part| {
            var remaining = part.size;
            var offset = part.offset;
            while (remaining != 0) {
                const index = firstOverlappingMapping(self.mappings.items, cursor);
                const len = @min(remaining, self.mappings.items[index].end() - cursor);
                try self.mapInReservationLocked(cursor, len, protection, .direct_memory, offset);
                const mapped = &self.mappings.items[firstOverlappingMapping(self.mappings.items, cursor)];
                mapped.protection_bits = bits;
                mapped.memory_type = memory_type;
                cursor += len;
                offset += len;
                remaining -= len;
            }
        }
    }

    fn validatePooledLocked(self: *AddressSpace, address: u64, size: u64, reserved_only: bool) Error!void {
        if (!self.coversLocked(address, size, null)) return Error.RangeNotMapped;
        const first = firstOverlappingMapping(self.mappings.items, address);
        for (self.mappings.items[first..]) |mapping| {
            if (mapping.address >= address + size) break;
            if (!mapping.pooled or (reserved_only and mapping.kind != .reserved)) return Error.RangeNotMapped;
        }
    }

    /// Return backing to the pool without giving up the guest's virtual arena.
    pub fn decommitPooled(self: *AddressSpace, address: u64, size: u64) Error!void {
        try validateMappedRange(address, size);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.decommitPooledLocked(address, size);
    }

    fn decommitPooledLocked(self: *AddressSpace, address: u64, size: u64) Error!void {
        try self.validatePooledLocked(address, size, false);
        try self.mappings.ensureUnusedCapacity(self.allocator, 2);
        try self.hostUnmapLocked(address, size, true);
        self.invalidateGpuTrackingLocked(address, size);
        self.hostUnmapLocked(address, size, false) catch |err| {
            self.host_mapping_state_uncertain = true;
            return err;
        };
        // Capacity was reserved above, so splitting and publishing cannot fail.
        try updateMappingMetadata(self.allocator, &self.mappings, address, size, .{});
        const first = firstOverlappingMapping(self.mappings.items, address);
        for (self.mappings.items[first..]) |*mapping| {
            if (mapping.address >= address + size) break;
            mapping.kind = .reserved;
            mapping.protection = .none;
            mapping.protection_bits = 0;
            mapping.memory_type = 0;
            mapping.backing_offset = null;
            mapping.identity = 0;
        }
        // Repeated partial decommits must not grow the interval table forever.
        var retained = first -| 1;
        var scanned = retained + 1;
        while (scanned < self.mappings.items.len and self.mappings.items[retained].address <= address + size) : (scanned += 1) {
            const a = &self.mappings.items[retained];
            const b = self.mappings.items[scanned];
            if (a.pooled and b.pooled and a.kind == .reserved and b.kind == .reserved and a.end() == b.address and std.mem.eql(u8, &a.name, &b.name)) {
                a.size += b.size;
            } else {
                retained += 1;
                self.mappings.items[retained] = b;
            }
        }
        const tail = self.mappings.items.len - scanned;
        std.mem.copyForwards(Mapping, self.mappings.items[retained + 1 ..][0..tail], self.mappings.items[scanned..]);
        self.mappings.items.len = retained + 1 + tail;
    }

    fn reserveFixedLocked(self: *AddressSpace, address: u64, size: u64) Error!void {
        if (!self.ownsLocked(address, size)) return Error.AddressUnavailable;
        if (self.overlapsLocked(address, size)) return Error.AddressUnavailable;
        try self.mappings.ensureUnusedCapacity(self.allocator, 1);

        // A semantic reservation may span host holes without physically
        // splitting the placeholders underneath it.  When a later reservation
        // starts immediately before or after that logical range,
        // `freeRangeLocked` is bounded by metadata at an address that is not a
        // real Windows placeholder boundary.  Coalescing from that artificial
        // boundary fails with STATUS_CONFLICTING_ADDRESSES.  Prepare the whole
        // host-free placeholder around the target instead; reserved mappings
        // are metadata only, while committed/direct mappings still bound this
        // range and can never be overwritten.
        const free_range = self.hostFreeRangeIgnoringReservationsLocked(address, size) orelse
            return Error.AddressUnavailable;
        try hostPreparePlaceholderRange(free_range, address, size);
        errdefer hostCoalescePlaceholder(free_range) catch {};

        const index = self.insertionIndex(address);
        self.mappings.insertAssumeCapacity(index, .{
            .address = address,
            .size = size,
            .protection = .none,
            .kind = .reserved,
            .protection_bits = 0,
            .name = namedMapping("anon"),
        });
    }

    fn freeRangeLocked(self: *const AddressSpace, address: u64, size: u64) ?Range {
        return freeRangeInMappings(self.reservations.items, self.mappings.items, address, size);
    }

    fn hostUnmapLocked(self: *AddressSpace, address: u64, size: u64, comptime validate_only: bool) Error!void {
        const end = address + size;
        var direct_start: ?u64 = null;
        var direct_end: u64 = 0;
        for (self.mappings.items) |mapping| {
            const part_start = @max(address, mapping.address);
            const part_end = @min(end, mapping.end());
            if (part_start >= part_end) continue;

            if (mapping.kind == .direct_memory) {
                if (direct_start == null) {
                    direct_start = part_start;
                    direct_end = part_end;
                } else if (part_start == direct_end) {
                    direct_end = part_end;
                } else {
                    try hostUnmapBackingOperation(direct_start.?, direct_end - direct_start.?, validate_only);
                    direct_start = part_start;
                    direct_end = part_end;
                }
            } else if (mapping.kind != .reserved) {
                if (direct_start) |start| {
                    try hostUnmapBackingOperation(start, direct_end - start, validate_only);
                    direct_start = null;
                }
                if (validate_only) {
                    try hostValidateUnmapBacking(part_start, part_end - part_start);
                } else try hostDecommit(part_start, part_end - part_start);
            }
        }
        if (direct_start) |start| try hostUnmapBackingOperation(start, direct_end - start, validate_only);
    }

    fn discardMappingsLocked(self: *AddressSpace) void {
        var direct_start: ?u64 = null;
        var direct_end: u64 = 0;
        for (self.mappings.items) |mapping| {
            if (mapping.kind == .direct_memory) {
                if (direct_start == null) {
                    direct_start = mapping.address;
                    direct_end = mapping.end();
                } else if (mapping.address == direct_end) {
                    direct_end = mapping.end();
                } else {
                    hostUnmapBacking(direct_start.?, direct_end - direct_start.?) catch {};
                    direct_start = mapping.address;
                    direct_end = mapping.end();
                }
            } else if (mapping.kind != .reserved) {
                if (direct_start) |start| {
                    hostUnmapBacking(start, direct_end - start) catch {};
                    direct_start = null;
                }
                hostDecommit(mapping.address, mapping.size) catch {};
            }
        }
        if (direct_start) |start| hostUnmapBacking(start, direct_end - start) catch {};
        self.mappings.clearRetainingCapacity();
        for (self.reservations.items) |reservation| {
            hostCoalescePlaceholder(reservation) catch {};
        }
    }

    fn insertionIndex(self: *const AddressSpace, address: u64) usize {
        return insertionIndexIn(self.mappings.items, address);
    }

    fn overlapsLocked(self: *const AddressSpace, address: u64, size: u64) bool {
        const end = address + size;
        const index = self.insertionIndex(address);
        if (index > 0 and self.mappings.items[index - 1].end() > address) return true;
        return index < self.mappings.items.len and self.mappings.items[index].address < end;
    }

    fn findFreeLocked(
        self: *const AddressSpace,
        window: Range,
        search_start: u64,
        size: u64,
        alignment: u64,
    ) ?u64 {
        if (search_start >= window.end or size > window.end - search_start) return null;

        for (self.reservations.items) |reservation| {
            const owned_start = @max(reservation.start, window.start);
            const owned_end = @min(reservation.end, window.end);
            if (owned_start >= owned_end or owned_end <= search_start) continue;

            const candidate = self.findFreeInOwnedRangeLocked(
                .{ .start = @max(owned_start, search_start), .end = owned_end },
                size,
                alignment,
            ) orelse continue;
            return candidate;
        }
        return null;
    }

    fn findLogicalFreeLocked(
        self: *const AddressSpace,
        window: Range,
        search_start: u64,
        size: u64,
        alignment: u64,
    ) ?u64 {
        if (search_start >= window.end or size > window.end - search_start) return null;

        // Start only in memory actually owned by AddressSpace. The logical
        // range may cross later host holes, but its first pages are where large
        // Unreal arenas immediately create their allocator metadata.
        for (self.reservations.items) |reservation| {
            const owned_start = @max(reservation.start, window.start);
            const owned_end = @min(reservation.end, window.end);
            if (owned_start >= owned_end or owned_end <= search_start) continue;
            const candidate = findLogicalFreeInMappings(
                self.mappings.items,
                window,
                @max(owned_start, search_start),
                size,
                alignment,
            ) orelse continue;
            if (reservation.contains(candidate, page_size)) return candidate;
        }
        return null;
    }

    fn findFreeInOwnedRangeLocked(
        self: *const AddressSpace,
        owned: Range,
        size: u64,
        alignment: u64,
    ) ?u64 {
        if (size > owned.len()) return null;
        var cursor = alignForward(owned.start, alignment) orelse return null;
        for (self.mappings.items) |mapping| {
            if (mapping.end() <= cursor) continue;
            if (mapping.address >= owned.end) break;

            if (mapping.address > cursor and size <= mapping.address - cursor) return cursor;
            cursor = alignForward(@max(cursor, mapping.end()), alignment) orelse return null;
            if (cursor >= owned.end or size > owned.end - cursor) return null;
        }
        return if (size <= owned.end - cursor) cursor else null;
    }

    fn hostFreeRangeIgnoringReservationsLocked(
        self: *const AddressSpace,
        address: u64,
        size: u64,
    ) ?Range {
        const requested_end = std.math.add(u64, address, size) catch return null;
        for (self.reservations.items) |reservation| {
            if (!reservation.contains(address, size)) continue;

            var free_start = reservation.start;
            var free_end = reservation.end;
            const at = self.insertionIndex(address);
            var before = at;
            while (before > 0) {
                before -= 1;
                const mapping = self.mappings.items[before];
                if (mapping.kind == .reserved) continue;
                if (mapping.end() > address) return null;
                free_start = @max(free_start, mapping.end());
                break;
            }
            for (self.mappings.items[at..]) |mapping| {
                if (mapping.kind == .reserved) continue;
                if (mapping.address < requested_end) return null;
                free_end = @min(free_end, mapping.address);
                break;
            }
            if (free_start <= address and requested_end <= free_end) {
                return .{ .start = free_start, .end = free_end };
            }
        }
        return null;
    }

    fn ownsLocked(self: *const AddressSpace, address: u64, size: u64) bool {
        for (self.reservations.items) |reservation| {
            if (reservation.contains(address, size)) return true;
        }
        return false;
    }

    fn coversLocked(
        self: *const AddressSpace,
        address: u64,
        size: u64,
        expected_kind: ?MappingKind,
    ) bool {
        if (size == 0) return false;
        const end = std.math.add(u64, address, size) catch return false;
        var cursor = address;

        for (self.mappings.items[firstOverlappingMapping(self.mappings.items, address)..]) |mapping| {
            if (mapping.end() <= cursor) continue;
            if (mapping.address > cursor) return false;
            if (expected_kind) |kind| {
                if (mapping.kind != kind) return false;
            }
            cursor = @min(end, mapping.end());
            if (cursor == end) return true;
        }
        return false;
    }

    fn coversCommittedLocked(self: *const AddressSpace, address: u64, size: u64) bool {
        if (size == 0) return false;
        const end = std.math.add(u64, address, size) catch return false;
        var cursor = address;

        for (self.mappings.items) |mapping| {
            if (mapping.end() <= cursor) continue;
            if (mapping.address > cursor or mapping.kind == .reserved) return false;
            cursor = @min(end, mapping.end());
            if (cursor == end) return true;
        }
        return false;
    }

    fn mappingForPageLocked(self: *const AddressSpace, page: u64) ?Mapping {
        // Mappings are ordered and disjoint. Only an exact start or its
        // predecessor can contain this page; earlier ends may be below it.
        var index = self.insertionIndex(page);
        if (index == self.mappings.items.len or self.mappings.items[index].address != page) {
            if (index == 0) return null;
            index -= 1;
        }
        const mapping = self.mappings.items[index];
        if (mapping.kind == .reserved or page >= mapping.end() or
            page_size > mapping.end() - page) return null;
        return mapping;
    }

    /// Caller owns the mapping mutex. Removing the entry prevents a later
    /// mapping at the same VA from inheriting a stale cache generation.
    fn invalidateGpuTrackingLocked(self: *AddressSpace, address: u64, size: u64) void {
        if (!self.gpu_tracker.enabled or size == 0) return;
        const range_end = std.math.add(u64, address, size) catch return;
        const first_page = address & ~(page_size - 1);
        const end_page = alignForward(range_end, page_size) orelse return;
        const tracker = &self.gpu_tracker;
        tracker.lock.lock();
        defer tracker.lock.unlock();

        var page = first_page;
        while (page < end_page) : (page += page_size) {
            const removed = tracker.pages.fetchRemove(page) orelse continue;
            _ = tracker.nextGeneration(page);
            if (removed.value.armed) {
                hostProtect(page, page_size, removed.value.restore_protection) catch {};
            }
        }
    }

    const RequiredPermission = enum { read, write };

    fn coversWithProtectionLocked(
        self: *AddressSpace,
        address: u64,
        size: u64,
        required: RequiredPermission,
    ) bool {
        const end = std.math.add(u64, address, size) catch return false;
        var cursor = address;

        // Mappings are ordered and non-overlapping. Checked GPU reads often
        // target an allocation near the end of thousands of streamed ranges;
        // start at that allocation instead of scanning all earlier mappings.
        const hint = &self.access_mapping_hints[((address >> 14) ^ (address >> 23)) % self.access_mapping_hints.len];
        const first = find: {
            if (hint.* < self.mappings.items.len) {
                const mapping = &self.mappings.items[hint.*];
                if (mapping.address <= address and address < mapping.end()) break :find hint.*;
            }
            var index = self.insertionIndex(address);
            if (index > 0 and self.mappings.items[index - 1].end() > address) index -= 1;
            hint.* = index;
            break :find index;
        };
        for (self.mappings.items[first..]) |*mapping| {
            if (mapping.end() <= cursor) continue;
            if (mapping.address > cursor) return false;
            const allowed = switch (required) {
                // Match the permissions installed by Protection.host():
                // x86 write access also permits reads. Testing only the
                // requested READ bit sent every GPU descriptor load from a
                // write-only guest allocation through VirtualQuery instead.
                .read => mapping.protection.read or mapping.protection.write,
                .write => mapping.protection.write,
            };
            if (!allowed) return false;
            cursor = @min(end, mapping.end());
            if (cursor == end) {
                if (self.host_mapping_state_uncertain and builtin.os.tag == .windows) {
                    return windowsRangeAccessible(address, size, switch (required) {
                        .read => .read,
                        .write => .write,
                    });
                }
                return true;
            }
        }
        return false;
    }

    fn releaseReservations(self: *AddressSpace) void {
        var i = self.reservations.items.len;
        while (i > 0) {
            i -= 1;
            hostRelease(self.reservations.items[i]);
        }
        self.reservations.clearRetainingCapacity();
    }

    fn reserveGuestRanges(self: *AddressSpace) Error!void {
        switch (builtin.os.tag) {
            .windows => {
                for (guest_ranges) |range| {
                    var cursor = range.start;
                    while (cursor < range.end) {
                        var info: WindowsMemoryInfo = undefined;
                        if (windowsVirtualQuery(cursor, &info) == 0) {
                            return Error.AddressSpaceUnavailable;
                        }

                        const region_start = @intFromPtr(info.base_address);
                        const unbounded_end = std.math.add(u64, region_start, info.region_size) catch
                            return Error.AddressSpaceUnavailable;
                        const region_end = @min(unbounded_end, range.end);
                        if (region_end <= cursor) return Error.AddressSpaceUnavailable;

                        if (info.state == windows_mem_free) {
                            const reserve_start = alignForward(
                                @max(region_start, range.start),
                                windows_allocation_granularity,
                            ) orelse return Error.AddressSpaceUnavailable;
                            if (reserve_start < region_end) {
                                const owned = Range{ .start = reserve_start, .end = region_end };
                                try hostReserve(owned);
                                errdefer hostRelease(owned);
                                try self.reservations.append(self.allocator, owned);
                            }
                        }
                        cursor = region_end;
                    }
                }
            },
            .linux, .macos => {
                try self.reservations.ensureTotalCapacity(self.allocator, guest_ranges.len);
                for (guest_ranges) |range| {
                    try hostReserve(range);
                    self.reservations.appendAssumeCapacity(range);
                }
            },
            else => return Error.UnsupportedHost,
        }
    }
};

fn validateMappedRange(address: u64, size: u64) Error!void {
    if (size == 0 or !isAligned(size, page_size)) return Error.InvalidSize;
    if (!isAligned(address, page_size)) return Error.InvalidAddress;
    for (guest_ranges) |range| {
        if (range.contains(address, size)) return;
    }
    return Error.InvalidAddress;
}

fn isAligned(value: u64, alignment: u64) bool {
    return value & (alignment - 1) == 0;
}

fn alignForward(value: u64, alignment: u64) ?u64 {
    const mask = alignment - 1;
    const added = std.math.add(u64, value, mask) catch return null;
    return added & ~mask;
}

fn offsetMapping(mapping: Mapping, new_address: u64, new_size: u64) Mapping {
    var copy = mapping;
    if (copy.backing_offset) |offset| {
        copy.backing_offset = offset + (new_address - mapping.address);
    }
    copy.address = new_address;
    copy.size = new_size;
    return copy;
}

/// First interval that could overlap a range starting at address. The table
/// is sorted and disjoint, so only the lower bound or its predecessor fits.
fn firstOverlappingMapping(mappings: []const Mapping, address: u64) usize {
    const index = insertionIndexIn(mappings, address);
    return if (index > 0 and mappings[index - 1].end() > address) index - 1 else index;
}

fn replaceReservationAssumeCapacity(mappings: *std.ArrayList(Mapping), index: usize, inserted: Mapping) void {
    const original = mappings.items[index];
    std.debug.assert(original.kind == .reserved and original.address <= inserted.address and inserted.end() <= original.end());
    var parts: [3]Mapping = undefined;
    var count: usize = 0;
    if (original.address < inserted.address) {
        parts[count] = offsetMapping(original, original.address, inserted.address - original.address);
        count += 1;
    }
    parts[count] = inserted;
    count += 1;
    if (inserted.end() < original.end()) {
        parts[count] = offsetMapping(original, inserted.end(), original.end() - inserted.end());
        count += 1;
    }
    // One tail move, no copy of the unaffected prefix and no reallocation.
    mappings.replaceRangeAssumeCapacity(index, 1, parts[0..count]);
}

/// Caller has checked complete coverage. Allocate before any metadata change;
/// exact-boundary updates require no allocation or movement at all.
fn updateMappingMetadata(allocator: std.mem.Allocator, mappings: *std.ArrayList(Mapping), address: u64, size: u64, metadata: MappingMetadata) std.mem.Allocator.Error!void {
    const end = address + size;
    const first = firstOverlappingMapping(mappings.items, address);
    const last = insertionIndexIn(mappings.items, end);
    std.debug.assert(first < last);
    const leading = mappings.items[first];
    const trailing = mappings.items[last - 1];
    const prefix: usize = @intFromBool(leading.address < address);
    const suffix: usize = @intFromBool(end < trailing.end());
    const extra = prefix + suffix;
    try mappings.ensureUnusedCapacity(allocator, extra);
    if (extra != 0) {
        // Move the untouched tail once for both splits. If the first interval
        // splits too, move just the affected intervals into their final slots.
        _ = mappings.addManyAtAssumeCapacity(last, extra);
        if (prefix != 0) {
            std.mem.copyBackwards(Mapping, mappings.items[first + 1 .. last + 1], mappings.items[first..last]);
            mappings.items[first] = offsetMapping(leading, leading.address, address - leading.address);
        }
        if (suffix != 0) mappings.items[last + prefix] = offsetMapping(trailing, end, trailing.end() - end);
    }
    for (mappings.items[first + prefix .. last + prefix]) |*mapping| {
        const start = @max(mapping.address, address);
        const stop = @min(mapping.end(), end);
        mapping.* = offsetMapping(mapping.*, start, stop - start);
        if (metadata.protection_bits) |bits| mapping.protection_bits = bits;
        if (metadata.memory_type) |memory_type| mapping.memory_type = memory_type;
        if (metadata.gpu_mask_id) |value| mapping.gpu_mask_id = value;
        if (metadata.pooled) |pooled| mapping.pooled = pooled;
        if (metadata.name) |name| mapping.name = namedMapping(name);
    }
}

/// Rebuilds a mapping list after a protect or unmap operation.
fn appendTransformed(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Mapping),
    mappings: []const Mapping,
    address: u64,
    size: u64,
    protection: Protection,
    protection_bits: i32,
    remove_middle: bool,
) std.mem.Allocator.Error!void {
    const end = address + size;
    for (mappings) |mapping| {
        const mapping_end = mapping.end();
        if (mapping_end <= address or mapping.address >= end) {
            try out.append(allocator, mapping);
            continue;
        }

        const middle_start = @max(mapping.address, address);
        const middle_end = @min(mapping_end, end);
        if (mapping.address < middle_start) {
            try out.append(
                allocator,
                offsetMapping(mapping, mapping.address, middle_start - mapping.address),
            );
        }
        if (!remove_middle) {
            var middle = offsetMapping(mapping, middle_start, middle_end - middle_start);
            middle.protection = protection;
            middle.protection_bits = protection_bits;
            try out.append(allocator, middle);
        }
        if (middle_end < mapping_end) {
            try out.append(
                allocator,
                offsetMapping(mapping, middle_end, mapping_end - middle_end),
            );
        }
    }
}

fn appendMetadataTransformed(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Mapping),
    mappings: []const Mapping,
    address: u64,
    size: u64,
    metadata: MappingMetadata,
) std.mem.Allocator.Error!void {
    const end = address + size;
    for (mappings) |mapping| {
        const mapping_end = mapping.end();
        if (mapping_end <= address or mapping.address >= end) {
            try out.append(allocator, mapping);
            continue;
        }

        const middle_start = @max(mapping.address, address);
        const middle_end = @min(mapping_end, end);
        if (mapping.address < middle_start) {
            try out.append(
                allocator,
                offsetMapping(mapping, mapping.address, middle_start - mapping.address),
            );
        }

        var middle = offsetMapping(mapping, middle_start, middle_end - middle_start);
        if (metadata.protection_bits) |bits| middle.protection_bits = bits;
        if (metadata.memory_type) |memory_type| middle.memory_type = memory_type;
        if (metadata.gpu_mask_id) |value| middle.gpu_mask_id = value;
        if (metadata.pooled) |pooled| middle.pooled = pooled;
        if (metadata.name) |name| middle.name = namedMapping(name);
        try out.append(allocator, middle);

        if (middle_end < mapping_end) {
            try out.append(
                allocator,
                offsetMapping(mapping, middle_end, mapping_end - middle_end),
            );
        }
    }
}

fn namedMapping(name: []const u8) [maximum_name_length]u8 {
    var result = [_]u8{0} ** maximum_name_length;
    const copy_len = @min(name.len, maximum_name_length - 1);
    @memcpy(result[0..copy_len], name[0..copy_len]);
    return result;
}

/// Returns the complete free interval around a requested range. The mapping
/// slice may be the current table or a prospective table built for `unmap`.
/// Wall time spent inside host virtual-memory calls, so a slow mapping
/// can be attributed to Windows rather than to this table.
/// Local monotonic clock: this module has no dependencies to borrow one
/// from, and the counter is only read around host calls.
const timing = struct {
    fn timestampNs() u64 {
        if (comptime builtin.os.tag != .windows) return 0;
        var counter: std.os.windows.LARGE_INTEGER = 0;
        var frequency: std.os.windows.LARGE_INTEGER = 0;
        if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() or
            !std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or
            frequency <= 0) return 0;
        const ticks: u128 = @intCast(@max(counter, 0));
        return @intCast(ticks * std.time.ns_per_s / @as(u128, @intCast(frequency)));
    }
    fn elapsedNs(started: u64) u64 {
        if (started == 0) return 0;
        const now = timestampNs();
        return if (now >= started) now - started else 0;
    }
};

var host_map_ns: u64 = 0;

pub fn hostMapNanoseconds() u64 {
    return @atomicLoad(u64, &host_map_ns, .monotonic);
}

/// A contiguous half-open run of interval indices.
const MappingSpan = struct { first: usize, last: usize };

/// The intervals a range overlaps, as a half-open index span. The table is
/// sorted and disjoint, so the span is contiguous.
fn overlappingMappingSpan(mappings: []const Mapping, address: u64, end: u64) MappingSpan {
    const first = firstOverlappingMapping(mappings, address);
    var last = first;
    while (last < mappings.len and mappings[last].address < end) last += 1;
    return .{ .first = first, .last = last };
}

/// The host range freed by removing `address..end`, read from the neighbours
/// the removal leaves behind rather than from a rebuilt table.
///
/// `freeRangeInMappings` answers the same question by walking every interval,
/// which is what made an unmap cost the whole table. A sorted table already
/// says who the neighbours are: everything before the span ends at or below
/// `address`, everything after starts at or above `end`, and the enclosing
/// reservation bounds both sides.
fn freeRangeAroundSpan(
    reservations: []const Range,
    mappings: []const Mapping,
    span: MappingSpan,
    address: u64,
    end: u64,
) ?Range {
    for (reservations) |reservation| {
        if (!reservation.contains(address, end - address)) continue;
        var free_start = reservation.start;
        var free_end = reservation.end;
        // A partially covered interval at either boundary keeps its remainder,
        // so the hole starts and ends exactly where the request did.
        if (span.first < span.last and mappings[span.first].address < address) {
            free_start = address;
        } else if (span.first > 0) {
            free_start = @max(free_start, mappings[span.first - 1].end());
        }
        if (span.first < span.last and mappings[span.last - 1].end() > end) {
            free_end = end;
        } else if (span.last < mappings.len) {
            free_end = @min(free_end, mappings[span.last].address);
        }
        if (free_start <= address and end <= free_end) {
            return .{ .start = free_start, .end = free_end };
        }
    }
    return null;
}

/// Removes `address..end` from the table, keeping the remainders of the
/// intervals it partially covers. Capacity for one extra interval must be
/// reserved by the caller: a range strictly inside one mapping splits it in
/// two. Nothing here can fail, so the caller commits host state first.
fn removeMappingSpanAssumeCapacity(
    mappings: *std.ArrayList(Mapping),
    span: MappingSpan,
    address: u64,
    end: u64,
) void {
    if (span.first == span.last) return;
    var parts: [2]Mapping = undefined;
    var count: usize = 0;
    const head = mappings.items[span.first];
    if (head.address < address) {
        parts[count] = offsetMapping(head, head.address, address - head.address);
        count += 1;
    }
    const tail = mappings.items[span.last - 1];
    if (tail.end() > end) {
        parts[count] = offsetMapping(tail, end, tail.end() - end);
        count += 1;
    }
    const removed = span.last - span.first;
    const items = mappings.items;
    if (count > removed) {
        // One interval split in two: make room by moving the tail out once.
        std.debug.assert(count == 2 and removed == 1);
        mappings.items.len += 1;
        std.mem.copyBackwards(
            Mapping,
            mappings.items[span.last + 1 ..],
            items[span.last..items.len],
        );
    } else if (count < removed) {
        std.mem.copyForwards(
            Mapping,
            mappings.items[span.first + count ..],
            items[span.last..items.len],
        );
        mappings.items.len -= removed - count;
    }
    for (parts[0..count], 0..) |part, offset| mappings.items[span.first + offset] = part;
}

/// Where `address` belongs in an address-ordered mapping list.
fn insertionIndexIn(mappings: []const Mapping, address: u64) usize {
    var low: usize = 0;
    var high = mappings.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (mappings[middle].address < address) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low;
}

fn findLogicalFreeInMappings(
    mappings: []const Mapping,
    window: Range,
    search_start: u64,
    size: u64,
    alignment: u64,
) ?u64 {
    if (search_start >= window.end or size > window.end - search_start) return null;
    var cursor = alignForward(search_start, alignment) orelse return null;
    for (mappings) |mapping| {
        if (mapping.end() <= cursor) continue;
        if (mapping.address >= window.end) break;
        if (mapping.address > cursor and size <= mapping.address - cursor) return cursor;
        cursor = alignForward(@max(cursor, mapping.end()), alignment) orelse return null;
        if (cursor >= window.end or size > window.end - cursor) return null;
    }
    return if (size <= window.end - cursor) cursor else null;
}

fn freeRangeInMappings(
    reservations: []const Range,
    mappings: []const Mapping,
    address: u64,
    size: u64,
) ?Range {
    const requested_end = std.math.add(u64, address, size) catch return null;
    for (reservations) |reservation| {
        if (!reservation.contains(address, size)) continue;

        var free_start = reservation.start;
        var free_end = reservation.end;
        for (mappings) |mapping| {
            if (mapping.end() <= address) {
                free_start = @max(free_start, mapping.end());
                continue;
            }
            if (mapping.address >= requested_end) {
                free_end = @min(free_end, mapping.address);
                break;
            }
            return null;
        }
        if (free_start <= address and requested_end <= free_end) {
            return .{ .start = free_start, .end = free_end };
        }
    }
    return null;
}

fn hostReserve(range: Range) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            var base: ?*anyopaque = @ptrFromInt(range.start);
            var size: windows.SIZE_T = @intCast(range.len());
            const status = WindowsApi.NtAllocateVirtualMemoryEx(
                windows.GetCurrentProcess(),
                @ptrCast(&base),
                &size,
                .{ .RESERVE = true, .RESERVE_PLACEHOLDER = true },
                .{ .NOACCESS = true },
                null,
                0,
            );
            if (status != .SUCCESS or @intFromPtr(base) != range.start) {
                if (status == .SUCCESS) {
                    var release_size: windows.SIZE_T = 0;
                    _ = windows.ntdll.NtFreeVirtualMemory(
                        windows.GetCurrentProcess(),
                        @ptrCast(&base),
                        &release_size,
                        .{ .RELEASE = true },
                    );
                }
                return Error.AddressSpaceUnavailable;
            }
        },
        .linux, .macos => {
            const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(range.start);
            const flags: std.posix.MAP = switch (builtin.os.tag) {
                .linux => .{
                    .TYPE = .PRIVATE,
                    .ANONYMOUS = true,
                    .NORESERVE = true,
                    .FIXED_NOREPLACE = true,
                },
                .macos => .{
                    .TYPE = .PRIVATE,
                    .ANONYMOUS = true,
                    .NORESERVE = true,
                },
                else => unreachable,
            };
            const mapped = std.posix.mmap(pointer, @intCast(range.len()), .{}, flags, -1, 0) catch
                return Error.AddressSpaceUnavailable;
            if (@intFromPtr(mapped.ptr) != range.start) {
                std.posix.munmap(mapped);
                return Error.AddressSpaceUnavailable;
            }
        },
        else => return Error.UnsupportedHost,
    }
}

fn hostRelease(range: Range) void {
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            var base: ?*anyopaque = @ptrFromInt(range.start);
            var size: windows.SIZE_T = 0;
            _ = windows.ntdll.NtFreeVirtualMemory(
                windows.GetCurrentProcess(),
                @ptrCast(&base),
                &size,
                .{ .RELEASE = true },
            );
        },
        .linux, .macos => {
            const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(range.start);
            std.posix.munmap(pointer[0..@intCast(range.len())]);
        },
        else => {},
    }
}

fn hostCommit(address: u64, size: u64, protection: Protection) Error!void {
    const host_started = timing.timestampNs();
    defer _ = @atomicRmw(u64, &host_map_ns, .Add, timing.elapsedNs(host_started), .monotonic);
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            const page = windows.PAGE.fromProtection(protection.host()) orelse
                return Error.ProtectionDenied;
            var cursor = address;
            while (cursor < address + size) : (cursor += page_size) {
                var base: ?*anyopaque = @ptrFromInt(cursor);
                var host_size: windows.SIZE_T = @intCast(page_size);
                const status = WindowsApi.NtAllocateVirtualMemoryEx(
                    windows.GetCurrentProcess(),
                    @ptrCast(&base),
                    &host_size,
                    .{
                        .COMMIT = true,
                        .RESERVE = true,
                        .REPLACE_PLACEHOLDER = true,
                    },
                    page,
                    null,
                    0,
                );
                if (status != .SUCCESS or @intFromPtr(base) != cursor) {
                    if (cursor > address) hostDecommit(address, cursor - address) catch {};
                    return Error.HostCommitFailed;
                }
            }
        },
        .linux, .macos => hostProtect(address, size, protection) catch
            return Error.HostCommitFailed,
        else => return Error.UnsupportedHost,
    }
}

fn fingerprintGpuPage(fingerprint: *u64, page: u64, generation: u64) void {
    fingerprint.* ^= page;
    fingerprint.* *%= 0x100_0000_01b3;
    fingerprint.* ^= generation;
    fingerprint.* *%= 0x100_0000_01b3;
}

/// A Windows protection operation cannot cross independently mapped views.
/// VirtualQuery also bounds a run at an existing protection split. Never cache
/// this boundary: partial unmapping can replace a view at the same address.
fn gpuProtectionRunEnd(address: u64, requested_end: u64) u64 {
    if (builtin.os.tag != .windows or requested_end - address <= page_size) return requested_end;
    var info: WindowsMemoryInfo = undefined;
    if (windowsVirtualQuery(address, &info) == 0 or info.state != windows_mem_commit) return address + page_size;
    const end = std.math.add(u64, @intFromPtr(info.base_address), info.region_size) catch return address + page_size;
    const bounded = @min(requested_end, end & ~(page_size - 1));
    return @max(address + page_size, bounded);
}

fn hostProtectContiguous(address: u64, size: u64, protection: Protection) Error!void {
    switch (builtin.os.tag) {
        .windows, .linux, .macos => {
            const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(address);
            std.process.protectMemory(pointer[0..@intCast(size)], protection.host()) catch return Error.ProtectionDenied;
        },
        else => return Error.UnsupportedHost,
    }
}

fn hostProtect(address: u64, size: u64, protection: Protection) Error!void {
    if (builtin.os.tag == .windows) {
        var cursor = address;
        while (cursor < address + size) : (cursor += page_size)
            try hostProtectContiguous(cursor, page_size, protection);
    } else try hostProtectContiguous(address, size, protection);
}

fn hostDecommit(address: u64, size: u64) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            var cursor = address;
            while (cursor < address + size) : (cursor += page_size) {
                var base: ?*anyopaque = @ptrFromInt(cursor);
                var host_size: windows.SIZE_T = @intCast(page_size);
                const status = windows.ntdll.NtFreeVirtualMemory(
                    windows.GetCurrentProcess(),
                    @ptrCast(&base),
                    &host_size,
                    .{ .RELEASE = true, .PRESERVE_PLACEHOLDER = true },
                );
                if (status != .SUCCESS) return Error.HostDecommitFailed;
            }
        },
        .linux, .macos => {
            hostProtect(address, size, .none) catch return Error.HostDecommitFailed;
            const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(address);
            std.posix.madvise(pointer, @intCast(size), std.posix.MADV.DONTNEED) catch {};
        },
        else => return Error.UnsupportedHost,
    }
}

/// Windows charges page-file section views at its 64 KiB allocation
/// granularity. Use that granularity when the guest address, physical offset,
/// and complete mapping permit it; otherwise retain one host view per 16 KiB
/// guest page so unaligned direct-memory windows remain representable.
fn hostMappingViewSize(
    kind: MappingKind,
    address: u64,
    size: u64,
    backing_offset: ?u64,
) u64 {
    if (builtin.os.tag == .windows and kind == .direct_memory) {
        // System-managed CPU heaps recycle individual guest pages even when
        // their original acquisition is aligned to 64 KiB. A wider native
        // section view cannot be unmapped in parts, and rebuilding it would
        // temporarily revoke live neighbouring pages from other guest threads.
        if (system_managed.contains(address, size)) return page_size;
        const offset = backing_offset orelse return page_size;
        if (isAligned(address, windows_allocation_granularity) and
            isAligned(size, windows_allocation_granularity) and
            isAligned(offset, windows_allocation_granularity))
        {
            // One view per granule. Mapping the whole aligned range as a
            // single view is fewer calls and measurably faster on Yotei, but
            // it costs Cat Quest III 2640 frames against 60 and takes the
            // title into the stall watchdog, reproducibly, three runs of
            // each. Whatever the wider view changes for that guest, it is not
            // worth a title that no longer runs; the coalescing in the two
            // commits around this one stays and carries most of the win.
            return windows_allocation_granularity;
        }
    }
    return page_size;
}

/// Splits one Windows placeholder into pieces matching the views that will
/// replace them.
fn hostPrepareMappingPlaceholders(
    free: Range,
    address: u64,
    size: u64,
    view_size: u64,
) Error!void {
    const host_started = timing.timestampNs();
    defer _ = @atomicRmw(u64, &host_map_ns, .Add, timing.elapsedNs(host_started), .monotonic);
    if (builtin.os.tag != .windows) return;

    // Recycled thread stacks and TLS blocks normally already sit inside one
    // sufficiently large placeholder.  Splitting that allocation directly is
    // both cheaper and more reliable than trying to coalesce the entire free
    // interval, whose metadata boundary can span unrelated placeholder
    // allocations after many short-lived threads have come and gone.
    const existing = try windowsAllocationRange(address);
    if (existing.start <= address and address + size <= existing.end) {
        return hostSplitWithinPlaceholder(existing, address, size, view_size);
    }

    try hostCoalescePlaceholder(free);
    if (address > free.start) try hostSplitPlaceholder(free.start, address - free.start);

    var cursor = address;
    const end = address + size;
    while (cursor < end) : (cursor += view_size) {
        if (cursor + view_size < free.end) {
            try hostSplitPlaceholder(cursor, view_size);
        }
    }
}

/// Isolates an uncommitted guest reservation without splitting every page.
/// Only its two boundaries matter until a real mapping consumes the range.
fn hostPreparePlaceholderRange(free: Range, address: u64, size: u64) Error!void {
    if (builtin.os.tag != .windows) return;

    try hostCoalescePlaceholder(free);
    if (address > free.start) try hostSplitPlaceholder(free.start, address - free.start);
    if (address + size < free.end) try hostSplitPlaceholder(address, size);
}

/// Carves per-view placeholders for `address`/`size` out of an existing one.
///
/// Two differences from `hostPrepareMappingPlaceholders`. It does not coalesce
/// first: a guest reservation is already a single placeholder, and coalescing
/// needs at least two adjacent ones to merge, so asking for it fails outright.
/// And each view has to be split individually because replacing a placeholder
/// requires the target to be a placeholder of exactly that size.
fn hostSplitWithinPlaceholder(
    placeholder: Range,
    address: u64,
    size: u64,
    view_size: u64,
) Error!void {
    if (builtin.os.tag != .windows) return;

    if (address > placeholder.start) {
        try hostSplitPlaceholder(placeholder.start, address - placeholder.start);
    }

    var cursor = address;
    const end = address + size;
    while (cursor < end) : (cursor += view_size) {
        // The final view needs no split when it already ends the placeholder;
        // splitting a placeholder at its own end is rejected.
        if (cursor + view_size < placeholder.end) {
            try hostSplitPlaceholder(cursor, view_size);
        }
    }
}

fn hostSplitPlaceholder(address: u64, size: u64) Error!void {
    if (builtin.os.tag != .windows) return;
    var base: ?*anyopaque = @ptrFromInt(address);
    var host_size: std.os.windows.SIZE_T = @intCast(size);
    const status = std.os.windows.ntdll.NtFreeVirtualMemory(
        std.os.windows.GetCurrentProcess(),
        @ptrCast(&base),
        &host_size,
        .{ .RELEASE = true, .PRESERVE_PLACEHOLDER = true },
    );
    if (status != .SUCCESS) return Error.HostCommitFailed;
}

/// Joins adjacent Windows placeholders after pages are unmapped. VirtualQuery
/// avoids issuing MEM_COALESCE_PLACEHOLDERS when the range is already one
/// placeholder, which Windows reports as an invalid request.
fn hostCoalescePlaceholder(range: Range) Error!void {
    if (builtin.os.tag != .windows or range.len() == 0) return;

    var info: WindowsMemoryInfo = undefined;
    if (windowsVirtualQuery(range.start, &info) == 0) return Error.HostDecommitFailed;
    const allocation_start = @intFromPtr(info.allocation_base);
    if (allocation_start == range.start and info.region_size >= range.len()) return;

    var base: ?*anyopaque = @ptrFromInt(range.start);
    var size: std.os.windows.SIZE_T = @intCast(range.len());
    const status = std.os.windows.ntdll.NtFreeVirtualMemory(
        std.os.windows.GetCurrentProcess(),
        @ptrCast(&base),
        &size,
        .{ .RELEASE = true, .COALESCE_PLACEHOLDERS = true },
    );
    if (status != .SUCCESS) return Error.HostDecommitFailed;
}

fn hostMapBacking(
    backing: *const SharedBacking,
    address: u64,
    size: u64,
    offset: u64,
    protection: Protection,
    committed: *std.DynamicBitSetUnmanaged,
) Error!void {
    const host_started = timing.timestampNs();
    defer _ = @atomicRmw(u64, &host_map_ns, .Add, timing.elapsedNs(host_started), .monotonic);
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            const page = windows.PAGE.fromProtection(protection.host()) orelse
                return Error.ProtectionDenied;
            const view_size_bytes = hostMappingViewSize(
                .direct_memory,
                address,
                size,
                offset,
            );
            var cursor = address;
            while (cursor < address + size) : (cursor += view_size_bytes) {
                const page_offset = offset + (cursor - address);
                var base: ?*anyopaque = @ptrFromInt(cursor);
                var section_offset: windows.LARGE_INTEGER = @intCast(page_offset);
                var view_size: windows.SIZE_T = @intCast(view_size_bytes);
                const status = WindowsApi.NtMapViewOfSectionEx(
                    backing.handle,
                    windows.GetCurrentProcess(),
                    @ptrCast(&base),
                    &section_offset,
                    &view_size,
                    .{ .REPLACE_PLACEHOLDER = true },
                    page,
                    null,
                    0,
                );
                if (status != .SUCCESS or @intFromPtr(base) != cursor) {
                    if (cursor > address) hostUnmapBacking(address, cursor - address) catch {};
                    return Error.HostCommitFailed;
                }

                const first_page: usize = @intCast(page_offset / page_size);
                const end_page: usize = @intCast((page_offset + view_size_bytes) / page_size);
                const already_committed = for (first_page..end_page) |physical_page| {
                    if (!committed.isSet(physical_page)) break false;
                } else true;
                // Mapping supplies the new view's protection. Recommitting
                // existing section pages adds a syscall per view but changes
                // neither their contents nor the physical allocation.
                if (already_committed) continue;

                var commit_base = base;
                var commit_size: windows.SIZE_T = @intCast(view_size_bytes);
                const commit_status = WindowsApi.NtAllocateVirtualMemoryEx(
                    windows.GetCurrentProcess(),
                    @ptrCast(&commit_base),
                    &commit_size,
                    .{ .COMMIT = true },
                    page,
                    null,
                    0,
                );
                if (commit_status != .SUCCESS or @intFromPtr(commit_base) != cursor) {
                    _ = windows.ntdll.NtUnmapViewOfSectionEx(
                        windows.GetCurrentProcess(),
                        base.?,
                        .{ .PRESERVE_PLACEHOLDER = true },
                    );
                    if (cursor > address) hostUnmapBacking(address, cursor - address) catch {};
                    return Error.HostCommitFailed;
                }
                committed.setRangeValue(.{ .start = first_page, .end = end_page }, true);
            }
        },
        .linux, .macos => {
            const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(address);
            const mapped = std.posix.mmap(
                pointer,
                @intCast(size),
                .{
                    .READ = protection.read or protection.write,
                    .WRITE = protection.write,
                    .EXEC = protection.execute,
                },
                .{ .TYPE = .SHARED, .FIXED = true },
                backing.handle,
                @intCast(offset),
            ) catch return Error.HostCommitFailed;
            if (@intFromPtr(mapped.ptr) != address) {
                std.posix.munmap(mapped);
                return Error.HostCommitFailed;
            }
        },
        else => return Error.UnsupportedHost,
    }
}

fn hostValidateUnmapBacking(address: u64, size: u64) Error!void {
    if (builtin.os.tag != .windows) return;
    const end = address + size;
    var cursor = address;
    while (cursor < end) {
        const view = try windowsAllocationRange(cursor);
        if (view.start != cursor or view.end > end) return Error.HostDecommitFailed;
        cursor = view.end;
    }
}

fn hostUnmapBackingOperation(address: u64, size: u64, comptime validate_only: bool) Error!void {
    if (validate_only) return hostValidateUnmapBacking(address, size);
    return hostUnmapBacking(address, size);
}

fn hostUnmapBacking(address: u64, size: u64) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            const end = address + size;
            var cursor = address;
            while (cursor < end) {
                const view = try windowsAllocationRange(cursor);
                if (view.start != cursor or view.end > end) {
                    // A view wider than the range being removed cannot be
                    // unmapped piecewise. Say so: it is the failure mode a
                    // larger mapping view introduces.
                    std.debug.print("[memory] partial unmap of wider view: request=0x{x}..0x{x} view=0x{x}..0x{x}\n", .{ address, end, view.start, view.end });
                    return Error.HostDecommitFailed;
                }

                const status = std.os.windows.ntdll.NtUnmapViewOfSectionEx(
                    std.os.windows.GetCurrentProcess(),
                    @ptrFromInt(cursor),
                    .{ .PRESERVE_PLACEHOLDER = true },
                );
                if (status != .SUCCESS) return Error.HostDecommitFailed;
                cursor = view.end;
            }
        },
        .linux, .macos => {
            const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(address);
            const mapped = std.posix.mmap(
                pointer,
                @intCast(size),
                .{},
                .{
                    .TYPE = .PRIVATE,
                    .ANONYMOUS = true,
                    .NORESERVE = true,
                    .FIXED = true,
                },
                -1,
                0,
            ) catch return Error.HostDecommitFailed;
            if (@intFromPtr(mapped.ptr) != address) return Error.HostDecommitFailed;
        },
        else => return Error.UnsupportedHost,
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "guest windows match the native layout" {
    try testing.expectEqual(@as(u64, 0x00_0004_0000), system_managed.start);
    try testing.expectEqual(@as(u64, 0x07_ffff_c000), system_managed.end);
    try testing.expectEqual(@as(u64, 0x08_0000_0000), system_reserved.start);
    try testing.expectEqual(@as(u64, 0x0f_c000_0000), system_reserved.end);
    try testing.expectEqual(@as(u64, 0x0f_e000_0000), device.start);
    try testing.expectEqual(@as(u64, 0x0f_f000_0000), device.end);
    const expected_user_start: u64 = if (builtin.os.tag == .macos)
        0x70_0000_0000
    else
        0x10_0000_0000;
    try testing.expectEqual(expected_user_start, user.start);
    try testing.expectEqual(@as(u64, 0xfc_0000_0000), user.end);
}

test "fixed pages are identity mapped, protected, and decommitted" {
    var space = try AddressSpace.init(testing.allocator);
    defer space.deinit();

    const address = system_managed.start;
    try space.mapFixed(address, page_size, .read_write, .private, null);

    const input = "guest-address-space";
    try space.write(address, input);
    var output: [input.len]u8 = undefined;
    try space.read(address, &output);
    try testing.expectEqualStrings(input, &output);

    try space.protect(address, page_size, .read_only);
    try testing.expectError(Error.ProtectionDenied, space.write(address, "x"));
    try space.unmap(address, page_size);
    try testing.expect(!space.isMapped(address, page_size));
}

test "write-only guest pages retain effective host readability and GPU write tracking" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var space = try AddressSpace.init(testing.allocator);
    defer space.deinit();
    const address = system_managed.start;
    try space.mapFixed(address, page_size, .{ .write = true }, .private, null);
    try space.write(address, "first");
    try testing.expect(space.isReadable(address, page_size));
    try testing.expect(isHostRangeReadable(address, page_size));
    try testing.expectEqual(@as(i32, 2), space.query(address, false).?.protection_bits);
    space.enableGpuMemoryTracking();
    const generation = try space.trackGpuRead(address, 5);
    try testing.expect(generation != 0);
    var bytes: [5]u8 = undefined;
    try space.read(address, &bytes);
    try testing.expectEqualStrings("first", &bytes);
    try testing.expect(space.handleGpuTrackedWriteFault(address));
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, bytes.len));
    @memcpy(@as([*]u8, @ptrFromInt(address))[0..5], "after");
    try space.read(address, &bytes);
    try testing.expectEqualStrings("after", &bytes);
    try space.protect(address, page_size, .none);
    try testing.expect(!space.isReadable(address, 1));
    try testing.expect(!isHostRangeReadable(address, 1));
    try space.unmap(address, page_size);
    try testing.expect(!space.isReadable(address, 1));
}

test "pinned direct memory preserves physical identity across remapping" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 256 * 1024);
    var space_alive = true;
    defer if (space_alive) space.deinit();
    const address = user.start;
    try space.mapFixed(address, 64 * 1024, .read_write, .direct_memory, 0);
    try space.write(address + 4096, "first");
    const original = space.directMemoryOffset(address + 4096, 4096).?;
    const view = space.pinDirectMemory(address + 4096, 4096, original).?;
    defer view.deinit();
    try testing.expectEqualStrings("first", view.bytes[view.offset..][0..5]);
    try space.unmap(address, 64 * 1024);
    try testing.expectEqual(null, space.directMemoryOffset(address + 4096, 4096));
    try space.mapFixed(address, 64 * 1024, .read_write, .direct_memory, 64 * 1024);
    try space.write(address + 4096, "other");
    try testing.expectEqual(@as(?u64, 64 * 1024 + 4096), space.directMemoryOffset(address + 4096, 4096));
    try testing.expectEqual(null, space.pinDirectMemory(address + 4096, 4096, original));
    try testing.expectEqualStrings("first", view.bytes[view.offset..][0..5]);
    @memcpy(view.bytes[view.offset..][0..5], "alias");
    var text: [5]u8 = undefined;
    try space.read(address + 4096, &text);
    try testing.expectEqualStrings("other", &text);
    try space.mapFixed(address + 128 * 1024, 64 * 1024, .read_write, .direct_memory, 0);
    try space.read(address + 128 * 1024 + 4096, &text);
    try testing.expectEqualStrings("alias", &text);
    try testing.expectEqual(null, space.directMemoryOffset(address + 65532, 8));
    space.deinit();
    space_alive = false;
    try testing.expectEqualStrings("alias", view.bytes[view.offset..][0..5]);
}

test "GPU page mapping lookup selects the containing range and its protection" {
    var mappings = [_]Mapping{
        .{ .address = 2 * page_size, .size = page_size, .protection = .read_execute, .kind = .module },
        .{ .address = 8 * page_size, .size = 2 * page_size, .protection = .read_write, .kind = .private },
        .{ .address = 12 * page_size, .size = page_size, .protection = .none, .kind = .reserved },
        .{ .address = 16 * page_size, .size = page_size, .protection = .read_only, .kind = .direct_memory },
    };
    var space = AddressSpace{
        .allocator = testing.allocator,
        .mappings = .{ .items = &mappings, .capacity = mappings.len },
    };
    // Metadata only: selecting a later writable mapping must not borrow the
    // protection of the earlier module when subtracting an address past it.
    try testing.expectEqualDeep(mappings[1], space.mappingForPageLocked(8 * page_size).?);
    try testing.expectEqualDeep(mappings[1], space.mappingForPageLocked(9 * page_size).?);
    try testing.expectEqualDeep(mappings[0], space.mappingForPageLocked(2 * page_size).?);
    try testing.expectEqualDeep(mappings[3], space.mappingForPageLocked(16 * page_size).?);
    for ([_]u64{ 0, 3 * page_size, 7 * page_size, 10 * page_size, 12 * page_size, 17 * page_size, std.math.maxInt(u64) }) |page| {
        try testing.expectEqual(null, space.mappingForPageLocked(page));
    }
    try testing.expectEqual(null, space.mappingForPageLocked(10 * page_size - 1));
    space.mappings.items = &.{};
    try testing.expectEqual(null, space.mappingForPageLocked(8 * page_size));
}

test "fine GPU range guards reject changed pages boundaries collisions and missing proofs" {
    const saved = fine_gpu_range_guards;
    defer fine_gpu_range_guards = saved;
    fine_gpu_range_guards = true;
    var tracker = GpuPageTracker{};
    const first = 0x1000000;
    const end = first + 2 * page_size;
    _ = tracker.nextGeneration(first);
    _ = tracker.rememberRangeGeneration(first, end, 123);
    _ = tracker.nextGeneration(first + 512 * 1024);
    fine_gpu_range_guards = false;
    try testing.expectEqual(null, tracker.cachedRangeGeneration(first, end));
    fine_gpu_range_guards = true;
    const avoided = fine_gpu_range_pages_avoided;
    try testing.expectEqual(@as(?u64, 123), tracker.cachedRangeGeneration(first, end));
    try testing.expectEqual(avoided + 2, fine_gpu_range_pages_avoided);
    _ = tracker.nextGeneration(end - page_size);
    try testing.expectEqual(null, tracker.cachedRangeGeneration(first, end));
    fine_gpu_range_guards = false;
    _ = tracker.rememberRangeGeneration(first, end, 234);
    fine_gpu_range_guards = true;
    _ = tracker.nextGeneration(first + 512 * 1024);
    try testing.expectEqual(null, tracker.cachedRangeGeneration(first, end));
    _ = tracker.rememberRangeGeneration(first, end, 345);
    _ = tracker.nextGeneration(first + 512 * 1024);
    _ = tracker.nextGeneration(first + (@as(u64, tracker.fine_region_epochs.len) << GpuPageTracker.fine_region_shift));
    try testing.expectEqual(null, tracker.cachedRangeGeneration(first, end));
    const boundary_first = first + 256 * 1024 - page_size;
    const boundary_end = boundary_first + 2 * page_size;
    _ = tracker.rememberRangeGeneration(boundary_first, boundary_end, 456);
    _ = tracker.nextGeneration(boundary_end - page_size);
    try testing.expectEqual(null, tracker.cachedRangeGeneration(boundary_first, boundary_end));
    _ = tracker.rememberRangeGeneration(first, end, 567);
    tracker.generation_counter = std.math.maxInt(u64);
    _ = tracker.nextGeneration(first + 512 * 1024);
    try testing.expectEqual(null, tracker.cachedRangeGeneration(first, end));
}

test "fine range guards preserve native write invalidation outside and inside a queried view" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const saved = fine_gpu_range_guards;
    defer fine_gpu_range_guards = saved;
    fine_gpu_range_guards = true;
    const bytes = 1024 * 1024;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, bytes);
    defer space.deinit();
    const address = user.start;
    try space.mapFixed(address, bytes, .read_write, .direct_memory, 0);
    space.enableGpuMemoryTracking();
    _ = try space.trackGpuRead(address, bytes);
    const first = try space.trackGpuRead(address, windows_allocation_granularity);
    try testing.expect(space.handleGpuTrackedWriteFault(address + 512 * 1024));
    const avoided = fine_gpu_range_pages_avoided;
    try testing.expectEqual(first, space.gpuGeneration(address, windows_allocation_granularity));
    try testing.expectEqual(avoided + windows_allocation_granularity / page_size, fine_gpu_range_pages_avoided);
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, bytes));
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address + 512 * 1024, page_size));
    try testing.expect(space.handleGpuTrackedWriteFault(address + page_size));
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, windows_allocation_granularity));
    const changed = try space.trackGpuRead(address, windows_allocation_granularity);
    try testing.expect(changed != first);
    try space.protect(address, page_size, .none);
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, windows_allocation_granularity));
    try testing.expectError(Error.ProtectionDenied, space.trackGpuRead(address, windows_allocation_granularity));
}

test "armed GPU page reuse preserves faults protection changes and remapping" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const saved = reuse_armed_gpu_pages;
    defer reuse_armed_gpu_pages = saved;
    var baseline: [5]u64 = undefined;
    for ([_]bool{ false, true }) |enabled| {
        reuse_armed_gpu_pages = enabled;
        const bytes = 2 * windows_allocation_granularity;
        var space = try AddressSpace.initWithDirectMemory(testing.allocator, bytes);
        defer space.deinit();
        const address = user.start;
        try space.mapFixed(address, bytes, .read_write, .direct_memory, 0);
        space.enableGpuMemoryTracking();
        var generations: [5]u64 = undefined;
        generations[0] = try space.trackGpuRead(address, bytes);
        const calls = space.gpu_tracker.protection_calls;
        try testing.expect(space.handleGpuTrackedWriteFault(address + 2 * page_size));
        const reused_before = armed_gpu_page_reuses;
        generations[1] = try space.trackGpuRead(address, bytes);
        try testing.expectEqual(enabled, armed_gpu_page_reuses > reused_before);
        try testing.expectEqual(calls + 2, space.gpu_tracker.protection_calls);
        try testing.expectEqual(generations[1], space.gpuGeneration(address, bytes));
        try testing.expect(!isHostRangeWritable(address, bytes));
        try space.protect(address + page_size, page_size, .read_only);
        generations[2] = try space.trackGpuRead(address, bytes);
        try testing.expect(!space.handleGpuTrackedWriteFault(address + page_size));
        space.notifyGuestWrite(address + 4 * page_size, page_size);
        _ = try space.trackGpuRead(address, bytes);
        try testing.expect(!isHostRangeWritable(address + page_size, page_size));
        try space.protect(address + page_size, page_size, .none);
        try testing.expectError(Error.ProtectionDenied, space.trackGpuRead(address, bytes));
        try space.protect(address + page_size, page_size, .read_write);
        generations[3] = try space.trackGpuRead(address, bytes);
        try testing.expect(space.handleGpuTrackedWriteFault(address + page_size));
        try space.unmap(address, windows_allocation_granularity);
        try space.mapFixed(address, windows_allocation_granularity, .read_write, .direct_memory, 0);
        generations[4] = try space.trackGpuRead(address, bytes);
        for (generations[1..], generations[0..4]) |current, previous| try testing.expect(current != previous);
        if (enabled) try testing.expectEqualDeep(baseline, generations) else baseline = generations;
    }
}

test "GPU watches batch within native views and retain per-page write epochs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const bytes = 2 * windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, bytes);
    defer space.deinit();
    const address = user.start;
    try space.mapFixed(address, bytes, .read_write, .direct_memory, 0);
    space.enableGpuMemoryTracking();
    const first = try space.trackGpuRead(address, bytes);
    try testing.expectEqual(@as(u64, 2), space.gpu_tracker.protection_calls);
    try testing.expectEqual(first, space.gpuGeneration(address, bytes));
    try testing.expect(!isHostRangeWritable(address, bytes));
    const calls = space.gpu_tracker.protection_calls;
    try testing.expectEqual(first, try space.trackGpuRead(address + 1, bytes - 2));
    try testing.expectEqual(calls, space.gpu_tracker.protection_calls);
    const untouched = space.gpu_tracker.pages.get(address).?.generation;
    try testing.expect(space.handleGpuTrackedWriteFault(address + 2 * page_size));
    try testing.expect(isHostRangeWritable(address + 2 * page_size, page_size));
    try testing.expect(!isHostRangeWritable(address, page_size));
    try testing.expect(!isHostRangeWritable(address + 3 * page_size, page_size));
    try testing.expectEqual(untouched, space.gpu_tracker.pages.get(address).?.generation);
    const rearmed = try space.trackGpuRead(address, bytes);
    try testing.expect(rearmed != first);
    try testing.expectEqual(calls + 2, space.gpu_tracker.protection_calls);
    const before_write = space.gpu_tracker.protection_calls;
    space.notifyGuestWrite(address + 1, bytes - 2);
    try testing.expectEqual(before_write + 2, space.gpu_tracker.protection_calls);
    try testing.expect(isHostRangeWritable(address, bytes));
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, bytes));
    const written: [*]u8 = @ptrFromInt(address);
    @memset(written[0..bytes], 0x5a);
    var previous: u64 = 0;
    for (0..bytes / page_size) |index| {
        const page = space.gpu_tracker.pages.get(address + index * page_size).?;
        try testing.expect(!page.armed and page.generation > previous);
        previous = page.generation;
    }
}

test "GPU watch groups preserve protection splits and requery remapped view boundaries" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const bytes = 2 * windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, bytes);
    defer space.deinit();
    const address = user.start;
    // Start with executable view rights, then narrow individual pages.
    try space.mapFixed(address, bytes, .read_write_execute, .direct_memory, 0);
    space.enableGpuMemoryTracking();
    _ = try space.trackGpuRead(address, bytes);
    space.notifyGuestWrite(address, bytes);
    try space.protect(address + page_size, page_size, .read_only);
    try space.protect(address + 3 * page_size, page_size, .read_write);
    _ = try space.trackGpuRead(address, bytes);
    space.notifyGuestWrite(address, bytes);
    try testing.expect(isHostRangeWritable(address, page_size));
    try testing.expect(!isHostRangeWritable(address + page_size, page_size));
    var info: WindowsMemoryInfo = undefined;
    try testing.expect(windowsVirtualQuery(address + 2 * page_size, &info) != 0);
    try testing.expectEqual(windows_page_execute_readwrite, info.protect);
    try testing.expect(windowsVirtualQuery(address + 3 * page_size, &info) != 0);
    try testing.expectEqual(windows_page_readwrite, info.protect);

    try space.unmap(address, windows_allocation_granularity);
    for (0..4) |index| try space.mapFixed(address + index * page_size, page_size, .read_write, .direct_memory, index * page_size);
    // An old 64 KiB view is now four independent 16 KiB views at the same VA.
    try testing.expectEqual(address + page_size, gpuProtectionRunEnd(address, address + windows_allocation_granularity));
    const calls = space.gpu_tracker.protection_calls;
    _ = try space.trackGpuRead(address, windows_allocation_granularity);
    try testing.expectEqual(calls + 4, space.gpu_tracker.protection_calls);
    space.notifyGuestWrite(address, windows_allocation_granularity);
    try testing.expect(isHostRangeWritable(address, windows_allocation_granularity));
}

test "a rejected grouped watch operation falls back without claiming later pages" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const bytes = 2 * windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, bytes);
    defer space.deinit();
    const address = user.start;
    try space.mapFixed(address, bytes, .read_write, .direct_memory, 0);
    // Deliberately bypass the region-bound helper to exercise rejection.
    const protected_end = try space.gpu_tracker.protectRun(address, address + bytes, .read_only);
    try testing.expectEqual(address + page_size, protected_end);
    try testing.expectEqual(@as(u64, 2), space.gpu_tracker.protection_calls);
    try testing.expect(!isHostRangeWritable(address, page_size));
    try testing.expect(isHostRangeWritable(address + page_size, bytes - page_size));
}

test "GPU publication aliases keep watches armed and preserve later CPU invalidation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const size = 3 * windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, size);
    defer space.deinit();
    const address = user.start;
    try space.mapFixed(address, size, .{ .write = true }, .direct_memory, 0);
    space.enableGpuMemoryTracking();
    const before = try space.trackGpuRead(address, size);
    const untouched = space.gpuGeneration(address + 4 * page_size, page_size);
    const calls = space.gpu_tracker.protection_calls;
    const source = try testing.allocator.alloc(u8, size - 246);
    defer testing.allocator.free(source);
    @memset(source, 0);
    @memset(source[0..100], 0x3a);
    @memset(source[page_size + 123 .. 2 * page_size + 123], 0x5a);
    source[source.len - 1] = 0x5b;
    const changed_fragments = (page_size - 123) * 2 + 2 * page_size;
    try testing.expectEqual(source.len - changed_fragments, space.publishGpuBytes(address + 123, source).?);
    const guest = @as([*]const u8, @ptrFromInt(address))[0..size];
    try testing.expectEqualSlices(u8, source, guest[123 .. size - 123]);
    try testing.expectEqual(@as(u8, 0), guest[122]);
    try testing.expectEqual(@as(u8, 0), guest[size - 123]);
    const published = space.gpuGeneration(address, size);
    try testing.expect(published != 0 and published != before);
    try testing.expectEqual(untouched, space.gpuGeneration(address + 4 * page_size, page_size));
    try testing.expectEqual(calls, space.gpu_tracker.protection_calls);
    try testing.expect(!isHostRangeWritable(address, size));
    try testing.expectEqual(source.len, space.publishGpuBytes(address + 123, source).?);
    try testing.expectEqual(published, try space.trackGpuRead(address, size));
    try testing.expectEqual(calls, space.gpu_tracker.protection_calls);
    try testing.expect(space.handleGpuTrackedWriteFault(address + 4 * page_size));
    @as(*u8, @ptrFromInt(address + 4 * page_size)).* = 0x73;
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, size));
    _ = space.publishGpuBytes(address + 123, source).?;
    // A GPU copy cannot certify a page whose native CPU watch is disarmed.
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, size));
    try testing.expect((try space.trackGpuRead(address, size)) != published);
}

test "uniform GPU publications reuse only complete unchanged watched pages" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const enabled = known_uniform_publications;
    defer known_uniform_publications = enabled;
    known_uniform_publications = true;
    const size = windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 2 * size);
    defer space.deinit();
    const address = user.start;
    try space.mapFixed(address, size, .read_write, .direct_memory, 0);
    space.enableGpuMemoryTracking();
    _ = try space.trackGpuRead(address, size);
    const source = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(source);
    const value: u32 = 0x7531_ba92;
    var offset: usize = 0;
    while (offset < source.len) : (offset += 4) std.mem.writeInt(u32, source[offset..][0..4], value, .little);
    const start = uniform_publication_compares_avoided;
    try testing.expectEqual(@as(usize, 0), space.publishGpuUniform32(address, source, value).?);
    const generation = space.gpuGeneration(address, size);
    const guest = @as([*]const u8, @ptrFromInt(address))[0..size];
    try testing.expectEqualSlices(u8, source, guest);
    try testing.expectEqual(start, uniform_publication_compares_avoided);
    try testing.expectEqual(source.len, space.publishGpuUniform32(address, source, value).?);
    try testing.expectEqual(start + size, uniform_publication_compares_avoided);
    try testing.expectEqual(generation, space.gpuGeneration(address, size));
    try testing.expectEqual(@as(usize, 4), space.publishGpuUniform32(address + 4, source[0..4], value).?);
    try testing.expectEqual(start + size + 4, uniform_publication_compares_avoided);

    // Native CPU invalidation must defeat the saved uniform value, even after
    // rearming the same virtual page. Restore only the word actually cleared.
    try testing.expect(space.handleGpuTrackedWriteFault(address));
    @as(*u8, @ptrFromInt(address)).* = 0;
    @as(*u8, @ptrFromInt(address + 8)).* = 0;
    _ = try space.trackGpuRead(address, size);
    const before_partial = uniform_publication_compares_avoided;
    try testing.expectEqual(@as(usize, 0), space.publishGpuUniform32(address, source[0..4], value).?);
    try testing.expectEqual(before_partial, uniform_publication_compares_avoided);
    try testing.expectEqual(@as(u8, 0), guest[8]);
    try testing.expectEqual(@as(usize, 0), space.publishGpuUniform32(address + 8, source[0..4], value).?);
    // Two partial writes do not certify the complete page.
    try testing.expectEqual(@as(usize, 4), space.publishGpuUniform32(address + 8, source[0..4], value).?);
    try testing.expectEqual(before_partial, uniform_publication_compares_avoided);

    // A generic publication changes the generation while keeping watches armed.
    _ = space.publishGpuUniform32(address, source, value).?;
    const changed = [_]u8{ 1, 2, 3, 4 };
    // A different uniform value must not reuse the previous certificate.
    const different = std.mem.readInt(u32, &changed, .little);
    try testing.expectEqual(@as(usize, 0), space.publishGpuUniform32(address + 12, &changed, different).?);
    try testing.expectEqual(@as(usize, 0), space.publishGpuUniform32(address + 12, source[0..4], value).?);
    try testing.expectEqualSlices(u8, source, guest);
    _ = space.publishGpuUniform32(address, source, value).?;
    try testing.expectEqual(@as(usize, 0), space.publishGpuBytes(address + 12, &changed).?);
    try testing.expectEqual(@as(usize, 0), space.publishGpuUniform32(address + 12, source[0..4], value).?);
    try testing.expectEqualSlices(u8, source, guest);
    _ = space.publishGpuUniform32(address, source, value).?;
    const before_disabled = uniform_publication_compares_avoided;
    known_uniform_publications = false;
    _ = space.publishGpuUniform32(address, source, value).?;
    try testing.expectEqual(before_disabled, uniform_publication_compares_avoided);
    known_uniform_publications = true;

    // Removing/remapping the same VA cannot retain the old value certificate.
    try space.unmap(address, size);
    try space.mapFixed(address, size, .read_write, .direct_memory, size);
    _ = try space.trackGpuRead(address, size);
    const before_remap = uniform_publication_compares_avoided;
    try testing.expectEqual(@as(usize, 0), space.publishGpuUniform32(address, source, value).?);
    try testing.expectEqual(before_remap, uniform_publication_compares_avoided);
    try testing.expectEqualSlices(u8, source, guest);
    // An independently writable guest alias prevents the optimization entirely.
    const alias = address + 4 * size;
    try space.mapFixed(alias, size, .read_write, .direct_memory, size);
    try testing.expectEqual(null, space.publishGpuUniform32(address, source, value));
}

test "immutable snapshot generations reject physical aliases and detect their removal" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const size = windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 2 * size);
    defer space.deinit();
    const address = user.start;
    const alias = address + 4 * size;
    try space.mapFixed(address, size, .read_write, .direct_memory, 0);
    space.enableGpuMemoryTracking();
    _ = try space.trackGpuRead(address, size);
    const initial = space.gpuSnapshotGeneration(address + 3, 17);
    try testing.expect(initial != 0);
    try testing.expectEqual(initial, space.gpuSnapshotGeneration(address + 3, 17));
    try space.mapFixed(alias, size, .read_write, .direct_memory, 0);
    try testing.expectEqual(@as(u64, 0), space.gpuSnapshotGeneration(address + 3, 17));
    @as(*volatile u8, @ptrFromInt(alias + 3)).* = 0x7d;
    try space.unmap(alias, size);
    const changed = space.gpuSnapshotGeneration(address + 3, 17);
    try testing.expect(changed != 0 and changed != initial);
    try testing.expectEqual(@as(u8, 0x7d), @as(*volatile u8, @ptrFromInt(address + 3)).*);
    space.notifyGuestWrite(address + 3, 1);
    try testing.expectEqual(@as(u64, 0), space.gpuSnapshotGeneration(address + 3, 17));
    try testing.expectEqual(@as(u64, 0), space.gpuSnapshotGeneration(address + size - 8, 16));
}

test "GPU publication aliases revalidate remaps permissions and physical aliases" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const size = windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 2 * size);
    defer space.deinit();
    const address = user.start;
    const alias = address + 4 * size;
    const source = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(source);
    @memset(source, 0x4d);
    try space.mapFixed(address, size, .read_write, .direct_memory, 0);
    try testing.expectEqual(@as(usize, 0), space.publishGpuBytes(address, source).?);
    try space.unmap(address, size);
    try testing.expectEqual(null, space.publishGpuBytes(address, source));
    try space.mapFixed(address, size, .read_write, .direct_memory, size);
    @memset(source, 0x62);
    try testing.expectEqual(@as(usize, 0), space.publishGpuBytes(address, source).?);
    try space.mapFixed(alias, size, .read_write, .direct_memory, 0);
    try testing.expectEqual(@as(u8, 0x4d), @as(*const u8, @ptrFromInt(alias)).*);
    try space.unmap(alias, size);
    try space.mapFixed(alias, size, .read_write, .direct_memory, size);
    @memset(source, 0x91);
    try testing.expectEqual(null, space.publishGpuBytes(address, source));
    try testing.expectEqual(@as(u8, 0x62), @as(*const u8, @ptrFromInt(alias)).*);
    try space.unmap(alias, size);
    try space.protect(address, size, .read_only);
    try testing.expectEqual(null, space.publishGpuBytes(address, source));
    try testing.expectEqual(@as(u8, 0x62), @as(*const u8, @ptrFromInt(address)).*);
    try space.unmap(address, size);
    try space.mapFixed(address, size, .read_write, .private, null);
    try testing.expectEqual(null, space.publishGpuBytes(address, source));
}

test "GPU publication alias saturation retains hot views and falls back without remapping" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const window = 64 * 1024 * 1024;
    const size = windows_allocation_granularity;
    const count = 65;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, count * window);
    defer space.deinit();
    const source = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(source);
    @memset(source, 0x47);
    for (0..count) |i| {
        const address = user.start + i * size;
        // Commit only one small slice of each sparse physical window.
        try space.mapFixed(address, size, .read_write, .direct_memory, i * window);
        if (i < space.publication_views.len) {
            try testing.expectEqual(@as(usize, 0), space.publishGpuBytes(address, source).?);
        } else {
            try testing.expectEqual(null, space.publishGpuBytes(address, source));
            try testing.expectEqual(@as(u8, 0), @as(*const u8, @ptrFromInt(address)).*);
        }
    }
    const first = space.publication_views[0].?.view.bytes.ptr;
    try testing.expectEqual(source.len, space.publishGpuBytes(user.start, source).?);
    try testing.expectEqual(first, space.publication_views[0].?.view.bytes.ptr);
    try testing.expectEqual(space.publication_views.len, space.next_publication_view);
}

test "GPU page tracker advances generations on HLE and native writes" {
    var space = try AddressSpace.init(testing.allocator);
    defer space.deinit();

    try space.mapFixed(system_managed.start, page_size, .read_only, .module, null);
    const address = system_managed.start + 4 * page_size;
    try space.mapFixed(address, 2 * page_size, .read_write, .private, null);
    try space.write(address, "initial");
    space.enableGpuMemoryTracking();

    const first = try space.trackGpuRead(address, @intCast(2 * page_size));
    const first_epoch = space.gpuTrackingEpoch();
    try testing.expect(first != 0);
    try testing.expectEqual(first, space.gpuGeneration(address, @intCast(2 * page_size)));
    // Repeated and byte-shifted views of the same pages share the proof.
    try testing.expectEqual(first, space.gpuGeneration(address + 8, @intCast(2 * page_size - 8)));
    // Writes and unmapping in another coarse region preserve this allocation's
    // observation, while the HLE/native writes below must still invalidate it.
    const unrelated = address + 4 * 1024 * 1024;
    try space.mapFixed(unrelated, page_size, .read_write, .private, null);
    _ = try space.trackGpuRead(unrelated, page_size);
    try space.write(unrelated, "other");
    try testing.expectEqual(first, space.gpuGeneration(address, @intCast(2 * page_size)));
    const protection_calls = space.gpu_tracker.protection_calls;
    try testing.expectEqual(first, try space.trackGpuRead(address + 8, @intCast(2 * page_size - 8)));
    try testing.expectEqual(protection_calls, space.gpu_tracker.protection_calls);
    try space.unmap(unrelated, page_size);
    try testing.expectEqual(first, space.gpuGeneration(address, @intCast(2 * page_size)));
    // An unobserved neighbor must not inherit the cached shorter range.
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, @intCast(3 * page_size)));

    try space.write(address + 8, "changed");
    const after_hle_write = space.gpuGeneration(address, @intCast(2 * page_size));
    try testing.expectEqual(@as(u64, 0), after_hle_write);
    try testing.expect(space.gpuTrackingEpoch() != first_epoch);

    const rearmed = try space.trackGpuRead(address, @intCast(2 * page_size));
    try testing.expect(rearmed != 0 and rearmed != first);
    try testing.expectEqual(rearmed, space.gpuGeneration(address, @intCast(2 * page_size)));
    const rearmed_epoch = space.gpuTrackingEpoch();
    try testing.expect(space.handleGpuTrackedWriteFault(address + page_size + 4));
    const after_native_write = space.gpuGeneration(address, @intCast(2 * page_size));
    try testing.expectEqual(@as(u64, 0), after_native_write);
    try testing.expect(space.gpuTrackingEpoch() != rearmed_epoch);
    const native_pointer: *u8 = @ptrFromInt(address + page_size + 4);
    native_pointer.* = 0xa5;
    native_pointer.* = 0x3c; // A second store does not fault or advance the epoch.
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, @intCast(2 * page_size)));
    const final = try space.trackGpuRead(address, @intCast(2 * page_size));
    try testing.expect(final != 0 and final != rearmed);
    try testing.expectEqual(final, space.gpuGeneration(address, @intCast(2 * page_size)));
    const before_unmap = space.gpuTrackingEpoch();

    try space.unmap(address, 2 * page_size);
    try testing.expect(space.gpuTrackingEpoch() != before_unmap);
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, @intCast(2 * page_size)));
}

test "GPU page tracker accepts a delayed write fault only after access was restored" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var space = try AddressSpace.init(testing.allocator);
    defer space.deinit();
    const address = system_managed.start + 4 * page_size;
    try space.mapFixed(address, page_size, .read_write, .private, null);
    space.enableGpuMemoryTracking();
    _ = try space.trackGpuRead(address, 4);
    try testing.expect(space.handleGpuTrackedWriteFault(address));
    const epoch = space.gpuTrackingEpoch();
    // A second exception was raised before the first handler disarmed it.
    try testing.expect(space.handleGpuTrackedWriteFault(address + 4));
    try testing.expectEqual(epoch, space.gpuTrackingEpoch());
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, 4));
    // Do not swallow a real protection fault merely because a watch existed.
    try hostProtect(address, page_size, .read_only);
    try testing.expect(!space.handleGpuTrackedWriteFault(address));
    try space.protect(address, page_size, .read_only);
    _ = try space.trackGpuRead(address, 4);
    try testing.expect(!space.handleGpuTrackedWriteFault(address));
    try space.unmap(address, page_size);
    try testing.expect(!space.handleGpuTrackedWriteFault(address));
}

test "automatic mappings use aligned first fit in the requested area" {
    var space = try AddressSpace.init(testing.allocator);
    defer space.deinit();

    const alignment = 4 * page_size;
    const first = try space.map(.user, 0, page_size, alignment, .read_write, .private, null);
    const second = try space.map(.user, 0, page_size, alignment, .read_write, .private, null);

    try testing.expectEqual(@as(u64, 0), first % alignment);
    try testing.expectEqual(@as(u64, 0), second % alignment);
    try testing.expect(second >= first + alignment);
}

test "direct-memory aliases share one sparse backing store" {
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 4 * page_size);
    defer space.deinit();

    const first = user.start;
    const second = user.start + 2 * page_size;
    try space.mapFixed(first, 2 * page_size, .read_write, .direct_memory, 0);
    try space.mapFixed(second, page_size, .read_write, .direct_memory, 0);

    try space.write(first, "coherent");
    var output: [8]u8 = undefined;
    try space.read(second, &output);
    try testing.expectEqualStrings("coherent", &output);

    // Removing one view must neither discard the physical page nor disturb a
    // second alias that still refers to it.
    try space.unmap(first, page_size);
    try testing.expect(!space.isMapped(first, page_size));
    try testing.expect(space.isMappedAs(first + page_size, page_size, .direct_memory));
    try space.read(second, &output);
    try testing.expectEqualStrings("coherent", &output);
}

test "aligned Windows direct memory shares one allocation-granularity view" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const view_size = windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, view_size);
    defer space.deinit();

    const address = user.start;
    try space.mapFixed(address, view_size, .read_write, .direct_memory, 0);

    var first_info: WindowsMemoryInfo = undefined;
    var last_info: WindowsMemoryInfo = undefined;
    try testing.expect(windowsVirtualQuery(address, &first_info) != 0);
    try testing.expect(windowsVirtualQuery(address + view_size - page_size, &last_info) != 0);
    try testing.expectEqual(address, @intFromPtr(first_info.allocation_base));
    try testing.expectEqual(address, @intFromPtr(last_info.allocation_base));

    // Permission metadata may split VirtualQuery regions, but releasing the
    // complete guest range still has to unmap its single section view once.
    try space.protect(address + page_size, page_size, .read_only);
    try space.unmap(address, view_size);
    try testing.expect(!space.isMapped(address, view_size));
}

test "recycled direct views retain committed contents and apply fresh protections" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const granule = windows_allocation_granularity;
    const base = user.start;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 3 * granule);
    defer space.deinit();

    // Seed just one 16 KiB physical page, then drop every alias. A later
    // 64 KiB view mixes previously committed pages with untouched ones.
    try space.mapFixed(base, page_size, .read_write, .direct_memory, page_size);
    try space.writeInt(u32, base, 0xa1b2c3d4);
    try space.unmap(base, page_size);
    try space.mapFixed(base, granule, .read_write, .direct_memory, 0);
    var word: [4]u8 = undefined;
    try space.read(base + page_size, &word);
    try testing.expectEqual(@as(u32, 0xa1b2c3d4), std.mem.readInt(u32, &word, .little));
    try space.writeInt(u32, base + 3 * page_size, 0x55667788);
    const original_identity = space.mappingIdentity(base, granule);
    try space.protect(base + page_size, page_size, .read_only);
    try space.unmap(base, granule);
    try testing.expect(!isHostRangeReadable(base, granule));

    // Reuse fully committed storage through a new read-only view. This skips
    // commitment but must not inherit the old view's read-write permissions.
    try space.reserveFixed(base, granule);
    try space.mapInReservation(base, granule, .read_only, .direct_memory, 0);
    try testing.expect(space.mappingIdentity(base, granule) != original_identity);
    try testing.expect(isHostRangeReadable(base, granule));
    try testing.expect(!isHostRangeWritable(base, granule));
    try space.read(base + 3 * page_size, &word);
    try testing.expectEqual(@as(u32, 0x55667788), std.mem.readInt(u32, &word, .little));
    try space.unmap(base, granule);

    // An unaligned offset still gets independent 16 KiB views. Partial
    // removal and a writable alias preserve both data and native boundaries.
    try space.mapFixed(base, 2 * page_size, .read_write, .direct_memory, page_size);
    try space.mapFixed(base + granule, page_size, .read_write, .direct_memory, page_size);
    try space.writeInt(u32, base + granule, 0x99887766);
    try space.unmap(base + page_size, page_size);
    try space.read(base, &word);
    try testing.expectEqual(@as(u32, 0x99887766), std.mem.readInt(u32, &word, .little));
    try testing.expect(isHostRangeWritable(base, page_size));
    try testing.expect(!isHostRangeReadable(base + page_size, page_size));
    try space.unmap(base, page_size);
    try space.unmap(base + granule, page_size);
    try space.mapFixed(base, page_size, .none, .direct_memory, page_size);
    try testing.expect(!isHostRangeReadable(base, page_size));
    try space.unmap(base, page_size);
}

test "virtual reservations and mapping queries retain guest metadata" {
    var space = try AddressSpace.init(testing.allocator);
    defer space.deinit();

    const reserved_address = system_managed.start + 8 * page_size;
    try space.reserveFixed(reserved_address, 2 * page_size);
    const reservation = space.query(reserved_address + page_size, false).?;
    try testing.expectEqual(MappingKind.reserved, reservation.kind);
    try testing.expectEqual(@as(i32, 0), reservation.protection_bits);
    try testing.expect(space.isMapped(reserved_address, 2 * page_size));
    try testing.expect(!space.isReadable(reserved_address, 2 * page_size));
    try testing.expect(!space.isWritable(reserved_address, 2 * page_size));

    try space.unmap(reserved_address, 2 * page_size);
    try space.mapFixed(
        reserved_address,
        2 * page_size,
        .read_write,
        .flexible,
        null,
    );
    try space.setMetadata(reserved_address, 2 * page_size, .{
        .protection_bits = 0x23,
        .memory_type = 7,
        .name = "flex-test",
    });

    const mapping = space.query(reserved_address, false).?;
    try testing.expectEqual(MappingKind.flexible, mapping.kind);
    try testing.expectEqual(@as(i32, 0x23), mapping.protection_bits);
    try testing.expect(space.isReadable(reserved_address, 2 * page_size));
    try testing.expect(space.isWritable(reserved_address, 2 * page_size));
    try testing.expectEqual(@as(i32, 7), mapping.memory_type);
    try testing.expectEqualStrings("flex-test", std.mem.sliceTo(&mapping.name, 0));

    try space.unmap(reserved_address, page_size);
    try testing.expect(space.query(reserved_address, false) == null);
    try testing.expectEqual(
        reserved_address + page_size,
        space.query(reserved_address, true).?.address,
    );
    try testing.expectEqual(@as(u64, page_size), space.mappedBytes(.flexible));
}

test "permission lookup preserves gaps boundaries and adjacent protections" {
    var mappings = [_]Mapping{
        .{ .address = 0x1008, .size = 8, .protection = .{ .read = true }, .kind = .private },
        .{ .address = 0x1010, .size = 8, .protection = .{ .read = true, .write = true }, .kind = .private },
        .{ .address = 0x1018, .size = 8, .protection = .{ .write = true }, .kind = .private },
        .{ .address = 0x1028, .size = 8, .protection = .none, .kind = .reserved },
        .{ .address = 0x1030, .size = 8, .protection = .{ .read = true, .write = true }, .kind = .direct_memory },
    };
    var space = AddressSpace{
        .allocator = testing.allocator,
        .mappings = .{ .items = &mappings, .capacity = mappings.len },
    };
    // This metadata-only fixture never owns native pages. A byte-level oracle
    // covers both interior starts and exact mapping boundaries.
    inline for (.{ AddressSpace.RequiredPermission.read, AddressSpace.RequiredPermission.write }) |permission| {
        var permitted = [_]bool{false} ** 128;
        for (mappings) |mapping| {
            const allowed = if (permission == .read) mapping.protection.read or mapping.protection.write else mapping.protection.write;
            for (mapping.address - 0x1000..mapping.end() - 0x1000) |index| permitted[index] = allowed;
        }
        for (0..64) |start| {
            for (0..64) |length| {
                var expected = true;
                for (permitted[start..][0..@max(length, 1)]) |allowed| expected = expected and allowed;
                const actual = if (permission == .read)
                    space.isReadable(0x1000 + start, length)
                else
                    space.isWritable(0x1000 + start, length);
                try testing.expectEqual(expected, actual);
            }
        }
    }
    try testing.expect(!space.isReadable(std.math.maxInt(u64) - 1, 4));
    try testing.expect(!space.isWritable(std.math.maxInt(u64) - 1, 4));
    space.mappings.items = &.{};
    try testing.expect(!space.isReadable(0x1008, 1));
}

test "permission hints recheck replaced mappings protections and shortened lists" {
    var mappings = [_]Mapping{
        .{ .address = 0x10000, .size = 0x4000, .protection = .read_write, .kind = .private },
        .{ .address = 0x20000, .size = 0x4000, .protection = .read_write, .kind = .private },
        .{ .address = 0x24000, .size = 0x4000, .protection = .read_write, .kind = .private },
    };
    var space = AddressSpace{ .allocator = testing.allocator, .mappings = .{ .items = &mappings, .capacity = mappings.len } };
    // Populate hints at an interior point and across adjacent intervals.
    try testing.expect(space.isWritable(0x20008, 8));
    try testing.expect(space.isReadable(0x23ffc, 8));
    mappings[1].protection = .read_only;
    try testing.expect(space.isReadable(0x20008, 8));
    try testing.expect(!space.isWritable(0x20008, 8));
    try testing.expect(!space.isWritable(0x23ffc, 8));
    mappings[1].protection = .none;
    mappings[1].kind = .reserved;
    try testing.expect(!space.isReadable(0x20008, 8));
    // Removing the first entry shifts every remaining index. The replacement
    // at the same address has no access, while its neighbor remains readable.
    space.mappings.items = mappings[1..];
    try testing.expect(!space.isReadable(0x20008, 8));
    try testing.expect(space.isWritable(0x24008, 8));
    space.mappings.items = mappings[2..];
    try testing.expect(!space.isReadable(0x20008, 8));
    try testing.expect(space.isReadable(0x24008, 8));
    mappings[2].address = 0x30000;
    try testing.expect(!space.isReadable(0x24008, 8));
    try testing.expect(space.isWritable(0x30008, 8));
    space.mappings.items = &.{};
    try testing.expect(!space.isReadable(0x30008, 8));
}

test "large semantic reservation can span small host holes" {
    var space = AddressSpace{ .allocator = testing.allocator };
    defer space.mappings.deinit(testing.allocator);
    defer space.reservations.deinit(testing.allocator);

    const start = user.start;
    try space.reservations.append(testing.allocator, .{
        .start = start,
        .end = start + 6 * page_size,
    });
    try space.reservations.append(testing.allocator, .{
        .start = start + 8 * page_size,
        .end = start + 32 * page_size,
    });

    const size = 12 * page_size;
    const address = try space.reserveSpanningHostHoles(.user, start, size, page_size);
    try testing.expectEqual(start, address);
    const mapping = space.query(start + 7 * page_size, false).?;
    try testing.expectEqual(MappingKind.reserved, mapping.kind);
    try testing.expectEqual(size, mapping.size);
    try testing.expect(space.hostFreeRangeIgnoringReservationsLocked(start, page_size) != null);
    try testing.expect(space.hostFreeRangeIgnoringReservationsLocked(
        start + 6 * page_size,
        page_size,
    ) == null);
}

test "fill reservation after neighboring allocation changes host placeholder boundaries" {
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 16 * page_size);
    defer space.deinit();
    const first = try space.reserve(.system_managed, 0x200000000, 8 * page_size, page_size);
    try space.mapInReservation(first, 7 * page_size, .read_write, .direct_memory, 0);
    // Leave a gap: carving this reserve coalesces the first one's reserved
    // tail into a larger host placeholder. Its guest boundary stays intact.
    const neighbor = try space.reserve(.system_managed, first + 9 * page_size, 4 * page_size, page_size);
    try space.mapInReservation(first + 7 * page_size, page_size, .read_write, .direct_memory, 7 * page_size);
    try space.write(first + 7 * page_size, "tail");
    var observed: [4]u8 = undefined;
    try space.read(first + 7 * page_size, &observed);
    try testing.expectEqualStrings("tail", &observed);
    try testing.expectEqual(MappingKind.reserved, space.query(neighbor, false).?.kind);
    try testing.expectEqual(@as(u64, 4 * page_size), space.query(neighbor, false).?.size);
    try testing.expect(space.query(first + 8 * page_size, false) == null);
}

test "reservation edits match rebuilding at every pair of boundaries" {
    const original = [_]Mapping{
        .{ .address = 2 * page_size, .size = 2 * page_size, .kind = .direct_memory, .protection = .read_only, .backing_offset = 7 * page_size, .name = namedMapping("before") },
        .{ .address = 5 * page_size, .size = 16 * page_size, .kind = .reserved, .protection = .none, .memory_type = 3, .name = namedMapping("reservation") },
        .{ .address = 22 * page_size, .size = page_size, .kind = .flexible, .protection = .read_write, .name = namedMapping("after") },
    };
    for (0..16) |start| {
        for (start + 1..17) |end| {
            var actual: std.ArrayList(Mapping) = .empty;
            defer actual.deinit(testing.allocator);
            try actual.ensureTotalCapacity(testing.allocator, original.len + 2);
            actual.appendSliceAssumeCapacity(&original);
            const pointer = actual.items.ptr;
            const inserted = Mapping{ .address = (5 + start) * page_size, .size = (end - start) * page_size, .kind = .direct_memory, .protection = .read_write, .backing_offset = 100 * page_size, .name = namedMapping("anon") };
            var expected: std.ArrayList(Mapping) = .empty;
            defer expected.deinit(testing.allocator);
            try appendTransformed(testing.allocator, &expected, &original, inserted.address, inserted.size, .none, 0, true);
            try expected.insert(testing.allocator, insertionIndexIn(expected.items, inserted.address), inserted);
            replaceReservationAssumeCapacity(&actual, firstOverlappingMapping(actual.items, inserted.address), inserted);
            try testing.expectEqual(pointer, actual.items.ptr);
            try testing.expectEqualDeep(expected.items, actual.items);
        }
    }
}

test "metadata edits match rebuilding across offsets gaps and repeated splits" {
    const base = system_managed.start;
    const original = [_]Mapping{
        .{ .address = base + 2 * page_size, .size = 5 * page_size, .kind = .direct_memory, .protection = .read_only, .backing_offset = 11 * page_size, .protection_bits = 0x11, .name = namedMapping("first") },
        .{ .address = base + 7 * page_size, .size = 3 * page_size, .kind = .direct_memory, .protection = .read_write, .backing_offset = 40 * page_size, .memory_type = 7, .name = namedMapping("alias") },
        .{ .address = base + 10 * page_size, .size = 4 * page_size, .kind = .reserved, .protection = .none, .name = namedMapping("reserve") },
        .{ .address = base + 16 * page_size, .size = 5 * page_size, .kind = .flexible, .protection = .read_write, .name = namedMapping("after gap") },
    };
    const edits = [_]MappingMetadata{ .{}, .{ .name = "" }, .{ .memory_type = 0 }, .{ .protection_bits = 0x33, .memory_type = 5, .name = "changed" } };
    for (0..23) |start| {
        for (start + 1..24) |end| {
            var space = AddressSpace{ .allocator = testing.allocator };
            defer space.mappings.deinit(testing.allocator);
            try space.mappings.appendSlice(testing.allocator, &original);
            var expected: std.ArrayList(Mapping) = .empty;
            defer expected.deinit(testing.allocator);
            try expected.appendSlice(testing.allocator, &original);
            var covered = true;
            for (start..end) |page| {
                const present = for (original) |mapping| {
                    if (mapping.address <= base + page * page_size and base + page * page_size < mapping.end()) break true;
                } else false;
                covered = covered and present;
            }
            for (edits) |metadata| {
                if (!covered) {
                    try testing.expectError(Error.RangeNotMapped, space.setMetadata(base + start * page_size, (end - start) * page_size, metadata));
                } else {
                    var replacement: std.ArrayList(Mapping) = .empty;
                    errdefer replacement.deinit(testing.allocator);
                    try appendMetadataTransformed(testing.allocator, &replacement, expected.items, base + start * page_size, (end - start) * page_size, metadata);
                    expected.deinit(testing.allocator);
                    expected = replacement;
                    try space.setMetadata(base + start * page_size, (end - start) * page_size, metadata);
                }
                try testing.expectEqualDeep(expected.items, space.mappings.items);
            }
        }
    }
}

test "reserved mapping and exact metadata updates use preallocated table storage" {
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 8 * page_size);
    defer space.deinit();
    const address = try space.reserve(.system_managed, 0x200000000, 4 * page_size, page_size);
    try space.mappings.ensureUnusedCapacity(testing.allocator, 2);
    const pointer = space.mappings.items.ptr;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    space.allocator = failing.allocator();
    defer space.allocator = testing.allocator;
    try space.mapInReservation(address + page_size, 2 * page_size, .read_write, .direct_memory, 3 * page_size);
    try space.setMetadata(address + page_size, 2 * page_size, .{ .protection_bits = 0x33, .memory_type = 7, .name = "mapped" });
    try testing.expectEqual(pointer, space.mappings.items.ptr);
    try space.write(address + page_size, "intact");
    var observed: [6]u8 = undefined;
    try space.read(address + page_size, &observed);
    try testing.expectEqualStrings("intact", &observed);
    const middle = space.query(address + 2 * page_size, false).?;
    try testing.expectEqual(@as(?u64, 3 * page_size), middle.backing_offset);
    try testing.expectEqual(@as(i32, 0x33), middle.protection_bits);
    try testing.expectEqualStrings("mapped", std.mem.sliceTo(&middle.name, 0));
    try testing.expectEqual(MappingKind.reserved, space.query(address, false).?.kind);
    try testing.expectEqual(MappingKind.reserved, space.query(address + 3 * page_size, false).?.kind);
}

test "failed reservation and metadata edits preserve the mapping table" {
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 4 * page_size);
    defer space.deinit();
    const address = try space.reserve(.system_managed, 0x200000000, 4 * page_size, page_size);
    // Force an exact-sized table, then fail the allocation needed for splits.
    const snapshot = try testing.allocator.dupe(Mapping, space.mappings.items);
    defer testing.allocator.free(snapshot);
    const exact = try testing.allocator.dupe(Mapping, snapshot);
    space.mappings.deinit(testing.allocator);
    space.mappings = .fromOwnedSlice(exact);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    space.allocator = failing.allocator();
    defer space.allocator = testing.allocator;
    try testing.expectError(error.OutOfMemory, space.mapInReservation(address + page_size, page_size, .read_write, .direct_memory, 0));
    try testing.expectEqualDeep(snapshot, space.mappings.items);
    try testing.expectError(error.OutOfMemory, space.setMetadata(address + page_size, page_size, .{ .name = "split" }));
    try testing.expectEqualDeep(snapshot, space.mappings.items);
    if (builtin.os.tag == .windows) try testing.expect(!windowsRangeAccessible(address + page_size, page_size, .write));
    space.allocator = testing.allocator;
    try testing.expectError(Error.BackingOffsetInvalid, space.mapInReservation(address + page_size, page_size, .read_write, .direct_memory, 4 * page_size));
    try testing.expectEqualDeep(snapshot, space.mappings.items);
    // The failed host transaction must leave a placeholder usable by retry.
    try space.mapInReservation(address + page_size, page_size, .read_write, .direct_memory, 0);
    try space.write(address + page_size, "retry");
    const committed = try testing.allocator.dupe(Mapping, space.mappings.items);
    defer testing.allocator.free(committed);
    try testing.expectError(Error.RangeNotMapped, space.mapInReservation(address, 3 * page_size, .read_write, .direct_memory, 0));
    try testing.expectEqualDeep(committed, space.mappings.items);
}

test "MemoryPool allocation failure leaves reservations and committed pages intact" {
    const block = windows_allocation_granularity;
    var space = try AddressSpace.initWithDirectMemory(testing.allocator, 2 * block);
    defer space.deinit();
    const address = try space.reserve(.system_managed, 0x200000000, 4 * block, block);
    try space.setMetadata(address, 4 * block, .{ .pooled = true, .name = "pool" });
    var exact = try testing.allocator.dupe(Mapping, space.mappings.items);
    space.mappings.deinit(testing.allocator);
    space.mappings = .fromOwnedSlice(exact);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    space.allocator = failing.allocator();
    defer space.allocator = testing.allocator;
    try testing.expectError(error.OutOfMemory, space.commitPooled(address + block, block, &.{.{ .offset = 0, .size = block }}, .read_write, 3, 3));
    try testing.expectEqual(@as(usize, 1), space.mappingCount());
    try testing.expect(!space.isReadable(address + block, block));
    space.allocator = testing.allocator;
    try space.commitPooled(address + block, 2 * block, &.{.{ .offset = 0, .size = 2 * block }}, .read_write, 3, 3);
    try space.write(address + block, "kept");
    exact = try testing.allocator.dupe(Mapping, space.mappings.items);
    space.mappings.deinit(testing.allocator);
    space.mappings = .fromOwnedSlice(exact);
    space.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, space.decommitPooled(address + block, block));
    try testing.expectEqualStrings("kept", @as([*]const u8, @ptrFromInt(address + block))[0..4]);
    try testing.expect(space.query(address + block, false).?.pooled);
    space.allocator = testing.allocator;
    try space.decommitPooled(address + block, 2 * block);
    try testing.expectEqual(@as(usize, 1), space.mappingCount());
}

test "host placeholder bounds match a full table scan around reserved runs" {
    const mappings = [_]Mapping{
        .{ .address = 2, .size = 2, .kind = .direct_memory, .protection = .read_write },
        .{ .address = 4, .size = 3, .kind = .reserved, .protection = .none },
        .{ .address = 8, .size = 2, .kind = .reserved, .protection = .none },
        .{ .address = 10, .size = 4, .kind = .flexible, .protection = .read_write },
        .{ .address = 16, .size = 2, .kind = .reserved, .protection = .none },
        .{ .address = 18, .size = 2, .kind = .reserved, .protection = .none },
        .{ .address = 22, .size = 3, .kind = .direct_memory, .protection = .read_only },
    };
    var owned = [_]Range{ .{ .start = 1, .end = 15 }, .{ .start = 16, .end = 30 } };
    var space = AddressSpace{ .allocator = testing.allocator, .reservations = .{ .items = &owned, .capacity = owned.len } };
    defer space.mappings.deinit(testing.allocator);
    try space.mappings.appendSlice(testing.allocator, &mappings);
    for (0..32) |start| {
        for (start + 1..33) |end| {
            const expected: ?Range = expected: {
                for (owned) |reservation| {
                    if (!reservation.contains(start, end - start)) continue;
                    var free = reservation;
                    for (mappings) |mapping| {
                        if (mapping.kind == .reserved) continue;
                        if (mapping.end() <= start) {
                            free.start = @max(free.start, mapping.end());
                        } else if (mapping.address >= end) {
                            free.end = @min(free.end, mapping.address);
                            break;
                        } else break :expected null;
                    }
                    break :expected free;
                }
                break :expected null;
            };
            try testing.expectEqualDeep(expected, space.hostFreeRangeIgnoringReservationsLocked(start, end - start));
        }
    }
}

test "span removal and its free range match rebuilding at every pair of boundaries" {
    const base = system_managed.start;
    const original = [_]Mapping{
        .{ .address = base + 2 * page_size, .size = 4 * page_size, .kind = .direct_memory, .protection = .read_only, .backing_offset = 7 * page_size, .name = namedMapping("first") },
        .{ .address = base + 6 * page_size, .size = 3 * page_size, .kind = .flexible, .protection = .read_write, .name = namedMapping("second") },
        // A gap here: removal must not invent coverage across it.
        .{ .address = base + 11 * page_size, .size = 5 * page_size, .kind = .direct_memory, .protection = .read_write, .backing_offset = 64 * page_size, .name = namedMapping("third") },
    };
    const reservations = [_]Range{.{ .start = base, .end = base + 20 * page_size }};
    for (0..19) |start| {
        for (start + 1..20) |end| {
            const address = base + start * page_size;
            const finish = base + end * page_size;

            var expected: std.ArrayList(Mapping) = .empty;
            defer expected.deinit(testing.allocator);
            try appendTransformed(testing.allocator, &expected, &original, address, finish - address, .none, 0, true);

            var actual: std.ArrayList(Mapping) = .empty;
            defer actual.deinit(testing.allocator);
            try actual.ensureTotalCapacity(testing.allocator, original.len + 1);
            actual.appendSliceAssumeCapacity(&original);
            const pointer = actual.items.ptr;
            const span = overlappingMappingSpan(actual.items, address, finish);

            // The free range has to agree with the walk it replaces, which
            // reads the table the removal produces.
            const reference = freeRangeInMappings(&reservations, expected.items, address, finish - address);
            const computed = freeRangeAroundSpan(&reservations, actual.items, span, address, finish);
            try testing.expectEqualDeep(reference, computed);

            removeMappingSpanAssumeCapacity(&actual, span, address, finish);
            try testing.expectEqualDeep(expected.items, actual.items);
            // One reserved interval is enough for the worst case, so the table
            // never reallocates and no unaffected interval is copied.
            try testing.expectEqual(pointer, actual.items.ptr);
        }
    }
}

test "unmapping a range inside one mapping splits it without rebuilding the table" {
    const base = system_managed.start;
    var space = AddressSpace{ .allocator = testing.allocator };
    defer space.mappings.deinit(testing.allocator);
    try space.mappings.ensureTotalCapacity(testing.allocator, 4);
    space.mappings.appendAssumeCapacity(.{
        .address = base,
        .size = 8 * page_size,
        .kind = .flexible,
        .protection = .read_write,
        .name = namedMapping("whole"),
    });
    const span = overlappingMappingSpan(space.mappings.items, base + 3 * page_size, base + 5 * page_size);
    try testing.expectEqual(@as(usize, 0), span.first);
    try testing.expectEqual(@as(usize, 1), span.last);
    removeMappingSpanAssumeCapacity(&space.mappings, span, base + 3 * page_size, base + 5 * page_size);
    try testing.expectEqual(@as(usize, 2), space.mappings.items.len);
    try testing.expectEqual(base, space.mappings.items[0].address);
    try testing.expectEqual(3 * page_size, space.mappings.items[0].size);
    try testing.expectEqual(base + 5 * page_size, space.mappings.items[1].address);
    try testing.expectEqual(3 * page_size, space.mappings.items[1].size);
}
