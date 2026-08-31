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

pub const SharedBacking = @import("backing_store.zig").SharedBacking;

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
    var cursor = allocation_start;
    while (true) {
        if (windowsVirtualQuery(cursor, &info) == 0) return Error.HostDecommitFailed;
        if (@intFromPtr(info.allocation_base) != allocation_start) break;
        const region_start: u64 = @intFromPtr(info.base_address);
        const region_end = std.math.add(u64, region_start, info.region_size) catch
            return Error.HostDecommitFailed;
        if (region_end <= cursor) return Error.HostDecommitFailed;
        cursor = region_end;
    }
    return .{ .start = allocation_start, .end = cursor };
}

const HostPermission = enum { read, write, execute };

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

/// Checks native allocations returned to guest code by the host CRT. These
/// pages are outside AddressSpace's console windows but remain valid pointers
/// for native guest execution and for HLE output parameters.
pub fn isHostRangeReadable(address: u64, size: u64) bool {
    return windowsRangeAccessible(address, size, .read);
}

pub fn isHostRangeWritable(address: u64, size: u64) bool {
    return windowsRangeAccessible(address, size, .write);
}

/// Checks that a native return address belongs to committed executable code.
/// This is intentionally stricter than readability: an exception unwinder can
/// encounter host bridge frames, but must not mistake an arbitrary host heap
/// pointer for one of those frames.
pub fn isHostRangeExecutable(address: u64, size: u64) bool {
    return windowsRangeAccessible(address, size, .execute);
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
    /// Physical direct-memory offset, when `kind == .direct_memory`.
    backing_offset: ?u64 = null,
    /// Original guest ABI protection mask, including GPU access bits.
    protection_bits: i32 = 0,
    memory_type: i32 = 0,
    name: [maximum_name_length]u8 = [_]u8{0} ** maximum_name_length,

    pub fn end(self: Mapping) u64 {
        return self.address + self.size;
    }
};

/// Optional guest-visible attributes applied to an already mapped range.
pub const MappingMetadata = struct {
    protection_bits: ?i32 = null,
    memory_type: ?i32 = null,
    name: ?[]const u8 = null,
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
    BackingStoreUnavailable,
    BackingOffsetInvalid,
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

const TrackedGpuPage = struct {
    generation: u64,
    restore_protection: Protection,
    armed: bool = false,
};

/// CPU-write watch state for memory which has been consumed by the GPU.  The
/// guest uses 16 KiB pages, so the tracker deliberately has the same
/// granularity instead of hashing whole textures and buffers every draw.
const GpuPageTracker = struct {
    pages: std.AutoHashMapUnmanaged(u64, TrackedGpuPage) = .empty,
    lock: Lock = .{},
    generation_counter: u64 = 1,
    enabled: bool = false,

    fn nextGeneration(self: *GpuPageTracker) u64 {
        self.generation_counter +%= 1;
        if (self.generation_counter == 0) self.generation_counter = 1;
        return self.generation_counter;
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
    allocator: std.mem.Allocator,
    mappings: std.ArrayList(Mapping) = .empty,
    /// Host-owned pieces of the guest windows. Windows has permanent
    /// mappings such as KUSER_SHARED_DATA inside the low window, so ownership
    /// is intentionally a list of free extents rather than three booleans.
    reservations: std.ArrayList(Range) = .empty,
    direct_backing: ?SharedBacking = null,
    mutex: Lock = .{},
    gpu_tracker: GpuPageTracker = .{},

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
        return self;
    }

    pub fn deinit(self: *AddressSpace) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.gpu_tracker.deinit(self.allocator);
        self.discardMappingsLocked();
        self.releaseReservations();
        if (self.direct_backing) |*backing| backing.deinit();
        self.direct_backing = null;
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

        self.invalidateGpuTrackingLocked(address, size);

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
            0,
            true,
        );

        const free_range = freeRangeInMappings(
            self.reservations.items,
            replacement.items,
            address,
            size,
        ) orelse return Error.HostDecommitFailed;

        try self.hostUnmapLocked(address, size);
        try hostCoalescePlaceholder(free_range);

        self.mappings.deinit(self.allocator);
        self.mappings = replacement;
    }

    pub fn isMapped(self: *AddressSpace, address: u64, size: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.coversLocked(address, size, null);
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

        var replacement: std.ArrayList(Mapping) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.ensureTotalCapacity(self.allocator, self.mappings.items.len + 2);
        try appendMetadataTransformed(
            self.allocator,
            &replacement,
            self.mappings.items,
            address,
            size,
            metadata,
        );
        self.mappings.deinit(self.allocator);
        self.mappings = replacement;
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
    /// Returns how many mappings were removed.
    pub fn unmapDirectMemoryBacking(self: *AddressSpace, offset: u64, size: u64) usize {
        if (size == 0) return 0;
        const end = std.math.add(u64, offset, size) catch return 0;

        var removed: usize = 0;
        while (true) {
            const victim = self.findDirectMemoryAlias(offset, end) orelse return removed;
            // Dropped outside the lock the search took, because unmapping takes
            // it again. Re-searching from the start each time is fine: the list
            // shrinks by one every round.
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
            if (mapping_offset < end and offset < mapping_end) return mapping;
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

        var fingerprint: u64 = 0xcbf2_9ce4_8422_2325;
        var page = first_page;
        while (page < end_page) : (page += page_size) {
            const mapping = self.mappingForPageLocked(page) orelse return Error.RangeNotMapped;
            const result = try tracker.pages.getOrPut(self.allocator, page);
            if (!result.found_existing) {
                result.value_ptr.* = .{
                    .generation = tracker.nextGeneration(),
                    .restore_protection = mapping.protection,
                };
            } else {
                result.value_ptr.restore_protection = mapping.protection;
            }
            if (mapping.protection.write and !result.value_ptr.armed) {
                var watched = mapping.protection;
                watched.read = true;
                watched.write = false;
                try hostProtect(page, page_size, watched);
                result.value_ptr.armed = true;
            }
            fingerprint ^= page;
            fingerprint *%= 0x100_0000_01b3;
            fingerprint ^= result.value_ptr.generation;
            fingerprint *%= 0x100_0000_01b3;
        }
        return if (fingerprint == 0) 1 else fingerprint;
    }

    /// Returns the current ordered generation fingerprint, or zero when the
    /// range has not yet been registered as a GPU source.
    pub fn gpuGeneration(self: *AddressSpace, address: u64, size: usize) u64 {
        if (size == 0) return 0;
        const range_end = std.math.add(u64, address, @as(u64, @intCast(size))) catch return 0;
        const first_page = address & ~(page_size - 1);
        const end_page = alignForward(range_end, page_size) orelse return 0;
        const tracker = &self.gpu_tracker;
        tracker.lock.lock();
        defer tracker.lock.unlock();
        if (!tracker.enabled) return 0;

        var fingerprint: u64 = 0xcbf2_9ce4_8422_2325;
        var page = first_page;
        while (page < end_page) : (page += page_size) {
            const tracked = tracker.pages.get(page) orelse return 0;
            fingerprint ^= page;
            fingerprint *%= 0x100_0000_01b3;
            fingerprint ^= tracked.generation;
            fingerprint *%= 0x100_0000_01b3;
        }
        return if (fingerprint == 0) 1 else fingerprint;
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
        while (page < end_page) : (page += page_size) {
            const tracked = tracker.pages.getPtr(page) orelse continue;
            if (tracked.armed) {
                hostProtect(page, page_size, tracked.restore_protection) catch continue;
                tracked.armed = false;
            }
            tracked.generation = tracker.nextGeneration();
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
        if (!tracked.armed or !tracked.restore_protection.write) return false;
        hostProtect(page, page_size, tracked.restore_protection) catch return false;
        tracked.armed = false;
        tracked.generation = tracker.nextGeneration();
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

        const free_range = self.freeRangeLocked(address, size) orelse {
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
            try hostMapBacking(backing, address, size, offset, protection);
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

        const end = address + size;
        const reservation = for (self.mappings.items) |mapping| {
            if (mapping.kind != .reserved) continue;
            if (mapping.address <= address and end <= mapping.end()) break mapping;
        } else return Error.RangeNotMapped;

        var replacement: std.ArrayList(Mapping) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.ensureTotalCapacity(self.allocator, self.mappings.items.len + 2);
        // Drop the reserved cover for this sub-range; anything of the
        // reservation on either side stays reserved and still belongs to the
        // guest.
        try appendTransformed(
            self.allocator,
            &replacement,
            self.mappings.items,
            address,
            size,
            .none,
            0,
            true,
        );

        const spans_host_holes = !self.ownsLocked(reservation.address, reservation.size);
        // A normal reservation was isolated as one exact placeholder. A huge
        // semantic reservation can span small host holes; for that case carve
        // only within the real owned/free placeholder containing this concrete
        // mapping and never touch the host allocation in the hole.
        const placeholder = if (spans_host_holes)
            self.hostFreeRangeIgnoringReservationsLocked(address, size) orelse
                return Error.AddressUnavailable
        else
            Range{ .start = reservation.address, .end = reservation.end() };
        const host_view_size = hostMappingViewSize(kind, address, size, backing_offset);
        if (spans_host_holes) {
            try hostPrepareMappingPlaceholders(placeholder, address, size, host_view_size);
        } else {
            try hostSplitWithinPlaceholder(placeholder, address, size, host_view_size);
        }
        errdefer hostCoalescePlaceholder(placeholder) catch {};

        if (kind == .direct_memory) {
            const offset = backing_offset orelse return Error.BackingOffsetInvalid;
            const backing = if (self.direct_backing) |*value| value else return Error.BackingStoreUnavailable;
            const backing_end = std.math.add(u64, offset, size) catch
                return Error.BackingOffsetInvalid;
            if (!isAligned(offset, page_size) or backing_end > backing.size) {
                return Error.BackingOffsetInvalid;
            }
            try hostMapBacking(backing, address, size, offset, protection);
            errdefer hostUnmapBacking(address, size) catch {};
        } else {
            if (backing_offset != null) return Error.BackingOffsetInvalid;
            try hostCommit(address, size, protection);
            errdefer hostDecommit(address, size) catch {};
        }

        const index = insertionIndexIn(replacement.items, address);
        try replacement.insert(self.allocator, index, .{
            .address = address,
            .size = size,
            .protection = protection,
            .kind = kind,
            // Carried through, not dropped. This mapping is a window onto
            // physical memory, and the offset is the only record of which
            // physical memory: without it a title asking what backs the address
            // is told zero, and everything it does with that answer — releasing
            // the memory, in particular — names the wrong region.
            .backing_offset = backing_offset,
            .protection_bits = 0,
            .name = namedMapping("anon"),
        });

        self.mappings.deinit(self.allocator);
        self.mappings = replacement;
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

    fn hostUnmapLocked(self: *AddressSpace, address: u64, size: u64) Error!void {
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
                    try hostUnmapBacking(direct_start.?, direct_end - direct_start.?);
                    direct_start = part_start;
                    direct_end = part_end;
                }
            } else if (mapping.kind != .reserved) {
                if (direct_start) |start| {
                    try hostUnmapBacking(start, direct_end - start);
                    direct_start = null;
                }
                try hostDecommit(part_start, part_end - part_start);
            }
        }
        if (direct_start) |start| try hostUnmapBacking(start, direct_end - start);
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
            for (self.mappings.items) |mapping| {
                if (mapping.kind == .reserved) continue;
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
        for (self.mappings.items) |mapping| {
            if (mapping.kind == .reserved) continue;
            if (page >= mapping.address and page_size <= mapping.end() - page) return mapping;
        }
        return null;
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
            if (removed.value.armed) {
                hostProtect(page, page_size, removed.value.restore_protection) catch {};
            }
        }
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

fn hostProtect(address: u64, size: u64, protection: Protection) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            var cursor = address;
            while (cursor < address + size) : (cursor += page_size) {
                const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(cursor);
                std.process.protectMemory(
                    pointer[0..@intCast(page_size)],
                    protection.host(),
                ) catch return Error.ProtectionDenied;
            }
        },
        .linux, .macos => {
            const pointer: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(address);
            std.process.protectMemory(pointer[0..@intCast(size)], protection.host()) catch
                return Error.ProtectionDenied;
        },
        else => return Error.UnsupportedHost,
    }
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
        const offset = backing_offset orelse return page_size;
        if (isAligned(address, windows_allocation_granularity) and
            isAligned(size, windows_allocation_granularity) and
            isAligned(offset, windows_allocation_granularity))
        {
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
) Error!void {
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

fn hostUnmapBacking(address: u64, size: u64) Error!void {
    switch (builtin.os.tag) {
        .windows => {
            const end = address + size;
            var cursor = address;
            while (cursor < end) {
                const view = try windowsAllocationRange(cursor);
                if (view.start != cursor or view.end > end) return Error.HostDecommitFailed;

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

test "GPU page tracker advances generations on HLE and native writes" {
    var space = try AddressSpace.init(testing.allocator);
    defer space.deinit();

    const address = system_managed.start;
    try space.mapFixed(address, 2 * page_size, .read_write, .private, null);
    try space.write(address, "initial");
    space.enableGpuMemoryTracking();

    const first = try space.trackGpuRead(address, @intCast(2 * page_size));
    try testing.expect(first != 0);
    try testing.expectEqual(first, space.gpuGeneration(address, @intCast(2 * page_size)));

    try space.write(address + 8, "changed");
    const after_hle_write = space.gpuGeneration(address, @intCast(2 * page_size));
    try testing.expect(after_hle_write != 0 and after_hle_write != first);

    _ = try space.trackGpuRead(address, @intCast(2 * page_size));
    try testing.expect(space.handleGpuTrackedWriteFault(address + page_size + 4));
    const after_native_write = space.gpuGeneration(address, @intCast(2 * page_size));
    try testing.expect(after_native_write != after_hle_write);
    const native_pointer: *u8 = @ptrFromInt(address + page_size + 4);
    native_pointer.* = 0xa5;

    try space.unmap(address, 2 * page_size);
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(address, @intCast(2 * page_size)));
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
