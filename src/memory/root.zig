// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Identity-mapped guest virtual memory.
//!
//! Guest x86-64 code carries absolute virtual addresses and executes natively,
//! so a guest address must be the same numeric address in the host process.
//! `AddressSpace` reserves the console's three usable windows before any image
//! is loaded, then commits, protects, and releases 16 KiB page ranges inside
//! those reservations.
//!
//! The design deliberately separates host reservation from guest mappings:
//! reserving a several-hundred-gigabyte window consumes virtual address space,
//! not physical memory. Physical pages are committed only by `mapFixed` or
//! `map`, and `unmap` returns them while keeping the outer reservation intact.

const std = @import("std");
const builtin = @import("builtin");

const windows_mem_free: u32 = 0x0001_0000;
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
} else struct {};

fn windowsVirtualQuery(address: u64, info: *WindowsMemoryInfo) usize {
    if (builtin.os.tag != .windows) unreachable;
    return WindowsApi.VirtualQuery(@ptrFromInt(address), info, @sizeOf(WindowsMemoryInfo));
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

/// Addresses reserved for the guest system software.
pub const system_reserved = Range{
    .start = 0x08_0000_0000,
    .end = 0x0f_c000_0000,
};

/// Addresses exposed to title-controlled mappings.
pub const user = Range{
    .start = 0x70_0000_0000,
    .end = 0xfc_0000_0000,
};

pub const guest_ranges = [_]Range{ system_managed, system_reserved, user };

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
};

/// Why a range is present. This is metadata; every mapping remains an identity
/// mapping from the guest address to the same host address.
pub const MappingKind = enum {
    module,
    private,
    direct_memory,
};

pub const Mapping = struct {
    address: u64,
    size: u64,
    protection: Protection,
    kind: MappingKind,
    /// Physical direct-memory offset, when `kind == .direct_memory`.
    backing_offset: ?u64 = null,

    pub fn end(self: Mapping) u64 {
        return self.address + self.size;
    }
};

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
} || std.mem.Allocator.Error;

/// A small lock for the address-space interval table.
///
/// Mapping operations are rare and their critical sections are short. An
/// atomic lock keeps this low-level module independent of an `std.Io` instance,
/// which the general-purpose mutex in Zig 0.16 requires.
const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

/// Owns all guest-address reservations in one host process.
///
/// There must be at most one live instance per process. Creating a second one
/// correctly fails because the first instance already owns the fixed ranges.
pub const AddressSpace = struct {
    allocator: std.mem.Allocator,
    mappings: std.ArrayList(Mapping) = .empty,
    /// Host-owned pieces of the three guest windows. Windows has permanent
    /// mappings such as KUSER_SHARED_DATA inside the low window, so ownership
    /// is intentionally a list of free extents rather than three booleans.
    reservations: std.ArrayList(Range) = .empty,
    mutex: Lock = .{},

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

    pub fn deinit(self: *AddressSpace) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.releaseReservations();
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

    /// Changes permissions over a fully mapped range. Mapping metadata is split
    /// where necessary so later queries retain page-accurate protection.
    pub fn protect(
        self: *AddressSpace,
        address: u64,
        size: u64,
        protection: Protection,
    ) Error!void {
        try validateMappedRange(address, size);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.coversLocked(address, size, null)) return Error.RangeNotMapped;

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
            false,
        );

        hostProtect(address, size, protection) catch return Error.ProtectionDenied;

        self.mappings.deinit(self.allocator);
        self.mappings = replacement;
    }

    /// Decommits pages while preserving the outer fixed-address reservation.
    pub fn unmap(self: *AddressSpace, address: u64, size: u64) Error!void {
        try validateMappedRange(address, size);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.coversLocked(address, size, null)) return Error.RangeNotMapped;

        var replacement: std.ArrayList(Mapping) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.ensureTotalCapacity(self.allocator, self.mappings.items.len + 1);
        try appendTransformed(
            self.allocator,
            &replacement,
            self.mappings.items,
            address,
            size,
            .none,
            true,
        );

        try hostDecommit(address, size);

        self.mappings.deinit(self.allocator);
        self.mappings = replacement;
    }

    pub fn isMapped(self: *AddressSpace, address: u64, size: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.coversLocked(address, size, null);
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

    /// Copies into guest memory only when the entire destination is mapped and
    /// writable. The identity mapping makes the final copy a normal host copy.
    pub fn write(self: *AddressSpace, address: u64, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        const size: u64 = @intCast(bytes.len);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.coversWithProtectionLocked(address, size, .write)) {
            return Error.ProtectionDenied;
        }

        const destination: [*]u8 = @ptrFromInt(address);
        @memcpy(destination[0..bytes.len], bytes);
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
        if (!self.ownsLocked(address, size)) return Error.AddressUnavailable;
        if (self.overlapsLocked(address, size)) return Error.AddressUnavailable;
        try self.mappings.ensureUnusedCapacity(self.allocator, 1);

        try hostCommit(address, size, protection);
        errdefer hostDecommit(address, size) catch {};

        const index = self.insertionIndex(address);
        self.mappings.insertAssumeCapacity(index, .{
            .address = address,
            .size = size,
            .protection = protection,
            .kind = kind,
            .backing_offset = backing_offset,
        });
    }

    fn insertionIndex(self: *const AddressSpace, address: u64) usize {
        var low: usize = 0;
        var high = self.mappings.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.mappings.items[middle].address < address) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
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

        for (self.mappings.items) |mapping| {
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

    const RequiredPermission = enum { read, write };

    fn coversWithProtectionLocked(
        self: *const AddressSpace,
        address: u64,
        size: u64,
        required: RequiredPermission,
    ) bool {
        const end = std.math.add(u64, address, size) catch return false;
        var cursor = address;

        for (self.mappings.items) |mapping| {
            if (mapping.end() <= cursor) continue;
            if (mapping.address > cursor) return false;
            const allowed = switch (required) {
                .read => mapping.protection.read,
                .write => mapping.protection.write,
            };
            if (!allowed) return false;
            cursor = @min(end, mapping.end());
            if (cursor == end) return true;
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

/// Rebuilds a mapping list after a protect or unmap operation.
fn appendTransformed(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Mapping),
    mappings: []const Mapping,
    address: u64,
    size: u64,
    protection: Protection,
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

fn hostReserve(range: Range) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            var base: ?*anyopaque = @ptrFromInt(range.start);
            var size: windows.SIZE_T = @intCast(range.len());
            const status = windows.ntdll.NtAllocateVirtualMemory(
                windows.GetCurrentProcess(),
                @ptrCast(&base),
                0,
                &size,
                .{ .RESERVE = true },
                .{ .NOACCESS = true },
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
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            var base: ?*anyopaque = @ptrFromInt(address);
            var host_size: windows.SIZE_T = @intCast(size);
            const page = windows.PAGE.fromProtection(protection.host()) orelse
                return Error.ProtectionDenied;
            const status = windows.ntdll.NtAllocateVirtualMemory(
                windows.GetCurrentProcess(),
                @ptrCast(&base),
                0,
                &host_size,
                .{ .COMMIT = true },
                page,
            );
            if (status != .SUCCESS or @intFromPtr(base) != address) return Error.HostCommitFailed;
        },
        .linux, .macos => hostProtect(address, size, protection) catch
            return Error.HostCommitFailed,
        else => return Error.UnsupportedHost,
    }
}

fn hostProtect(address: u64, size: u64, protection: Protection) Error!void {
    const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(address);
    std.process.protectMemory(pointer[0..@intCast(size)], protection.host()) catch
        return Error.ProtectionDenied;
}

fn hostDecommit(address: u64, size: u64) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            var base: ?*anyopaque = @ptrFromInt(address);
            var host_size: windows.SIZE_T = @intCast(size);
            const status = windows.ntdll.NtFreeVirtualMemory(
                windows.GetCurrentProcess(),
                @ptrCast(&base),
                &host_size,
                .{ .DECOMMIT = true },
            );
            if (status != .SUCCESS) return Error.HostDecommitFailed;
        },
        .linux, .macos => {
            hostProtect(address, size, .none) catch return Error.HostDecommitFailed;
            const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(address);
            std.posix.madvise(pointer, @intCast(size), std.posix.MADV.DONTNEED) catch {};
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
    try testing.expectEqual(@as(u64, 0x70_0000_0000), user.start);
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
