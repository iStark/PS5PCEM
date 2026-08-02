// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Virtual and direct memory management from `libkernel`.
//!
//! "Direct memory" is the guest's name for physical video memory. A title
//! reserves a range of it, then maps that range into its address space. The two
//! steps are separate: the reservation is a claim on a physical range, and the
//! mapping decides where and with what protection it becomes visible.
//!
//! Physical reservations are kept here, while virtual placement is delegated to
//! the process-wide `memory.AddressSpace`. Keeping one owner for virtual ranges
//! is essential: ELF segments, relocations, and kernel mappings must agree on
//! which exact host addresses are already occupied.

const std = @import("std");
const memory = @import("memory");
const abi = @import("../abi.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");

const KernelError = errno.KernelError;

/// Failures the pool can report.
///
/// Kept as a Zig error set rather than a guest status: the pool is host-side
/// bookkeeping, and translating to the guest's numbering is the entry point's
/// job. Mixing the two makes it easy to leak a raw status into host code where
/// nothing checks it.
pub const PoolError = error{
    /// No free range satisfies the request.
    OutOfDirectMemory,
    /// The range was never reserved, or does not match a reservation exactly.
    NotReserved,
} || std.mem.Allocator.Error;

/// A spin lock over the pool.
///
/// `std.atomic.Mutex` offers only `tryLock`, and `std.Io.Mutex` needs an `Io`
/// instance that this layer does not have. Spinning is acceptable here because
/// the critical sections are a few list operations and memory reservation is
/// rare — titles do it during startup, not per frame.
const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

/// Physical memory is handed out in 16 KiB units.
pub const page_size: u64 = 16 * 1024;

/// Size of the direct memory pool reported to the guest.
///
/// Real hardware exposes a little under 13 GiB to titles. The figure is
/// deliberately a constant here: a title queries it during startup and sizes its
/// own allocators from the answer, so it has to be stable and plausible before
/// any real memory backend exists.
pub const direct_memory_size: u64 = 12 * 1024 * 1024 * 1024;

/// Default flexible-memory budget used until system-content configuration is
/// parsed. This matches the reference emulator's PS5 default.
pub const flexible_memory_size: u64 = 4 * 1024 * 1024 * 1024;

pub const maximum_name_length: usize = memory.maximum_name_length;

/// Guest ABI layout filled by sceKernelVirtualQuery.
pub const VirtualQueryInfo = extern struct {
    start: u64 = 0,
    end: u64 = 0,
    offset: u64 = 0,
    protection: i32 = 0,
    memory_type: i32 = 0,
    state: u32 = 0,
    name: [maximum_name_length]u8 = [_]u8{0} ** maximum_name_length,
    gpu_mask_id: u8 = 0,
    reserved: u8 = 0,
    padding: [2]u8 = .{ 0, 0 },
};

pub const DirectMemoryQueryInfo = extern struct {
    start: i64 = 0,
    end: i64 = 0,
    memory_type: i32 = 0,
    padding: i32 = 0,
};

comptime {
    if (@sizeOf(VirtualQueryInfo) != 72) @compileError("VirtualQueryInfo ABI size must be 72 bytes");
    if (@sizeOf(DirectMemoryQueryInfo) != 24) {
        @compileError("DirectMemoryQueryInfo ABI size must be 24 bytes");
    }
}

/// Memory types a title can ask for. The distinction drives caching behaviour on
/// hardware; here it is recorded but not yet acted upon.
pub const MemoryType = enum(i32) {
    wb_onion = 0,
    wc_garlic = 3,
    wb_garlic = 10,
    _,
};

/// One satisfied reservation.
pub const Reservation = struct {
    start: u64,
    len: u64,
    alignment: u64,
    memory_type: MemoryType,

    pub fn end(self: Reservation) u64 {
        return self.start + self.len;
    }

    pub fn overlaps(self: Reservation, start: u64, len: u64) bool {
        return self.start < start + len and start < self.end();
    }
};

/// Bookkeeping for the direct memory pool.
///
/// Deliberately not a general-purpose allocator: the guest addresses physical
/// memory by offset, so reservations have to be placed at specific addresses
/// and identified by them later.
pub const Pool = struct {
    size: u64 = direct_memory_size,
    reservations: std.ArrayList(Reservation) = .empty,

    pub fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        self.reservations.deinit(gpa);
    }

    /// Total reserved, whether or not it has been mapped.
    pub fn used(self: *const Pool) u64 {
        var total: u64 = 0;
        for (self.reservations.items) |r| total += r.len;
        return total;
    }

    pub fn findContaining(self: *const Pool, addr: u64) ?*const Reservation {
        for (self.reservations.items) |*r| {
            if (addr >= r.start and addr < r.end()) return r;
        }
        return null;
    }

    pub fn findContainingRange(self: *const Pool, start: u64, len: u64) ?*const Reservation {
        if (len == 0) return null;
        const end = std.math.add(u64, start, len) catch return null;
        for (self.reservations.items) |*r| {
            if (start >= r.start and end <= r.end()) return r;
        }
        return null;
    }

    pub fn hasExactReservation(self: *const Pool, start: u64, len: u64) bool {
        for (self.reservations.items) |reservation| {
            if (reservation.start == start and reservation.len == len) return true;
        }
        return false;
    }

    fn isFree(self: *const Pool, start: u64, len: u64) bool {
        for (self.reservations.items) |r| {
            if (r.overlaps(start, len)) return false;
        }
        return true;
    }

    /// Reserves `len` bytes with the requested alignment, searching upward from
    /// `search_start` and stopping at `search_end`.
    ///
    /// Placement is first-fit. The guest cannot observe the policy — only that
    /// the returned address satisfies the constraints it asked for — so the
    /// simplest policy that is correct is the right one until a title turns out
    /// to depend on something more specific.
    pub fn reserve(
        self: *Pool,
        gpa: std.mem.Allocator,
        search_start: u64,
        search_end: u64,
        len: u64,
        alignment: u64,
        memory_type: MemoryType,
    ) PoolError!u64 {
        const step = @max(alignment, page_size);

        var candidate = std.mem.alignForward(u64, search_start, step);
        while (candidate + len <= @min(search_end, self.size)) : (candidate += step) {
            if (!self.isFree(candidate, len)) continue;

            try self.reservations.append(gpa, .{
                .start = candidate,
                .len = len,
                .alignment = alignment,
                .memory_type = memory_type,
            });
            return candidate;
        }
        return error.OutOfDirectMemory;
    }

    /// Releases a previously reserved range.
    ///
    /// Only exact ranges are accepted. Hardware permits releasing a sub-range,
    /// which would split the reservation; that is not implemented, and saying so
    /// through an error is better than silently freeing more than asked.
    pub fn release(self: *Pool, start: u64, len: u64) PoolError!void {
        for (self.reservations.items, 0..) |r, i| {
            if (r.start == start and r.len == len) {
                _ = self.reservations.orderedRemove(i);
                return;
            }
        }
        return PoolError.NotReserved;
    }
};

/// Process-wide direct memory state.
///
/// A single global is correct here: the pool models a hardware resource that
/// exists once per machine, and the guest addresses it by physical offset.
var pool: Pool = .{};
var pool_gpa: ?std.mem.Allocator = null;
var pool_lock: Lock = .{};
var guest_address_space: ?*memory.AddressSpace = null;

/// Installs the allocator the pool uses for its bookkeeping.
pub fn init(gpa: std.mem.Allocator) void {
    pool_lock.lock();
    defer pool_lock.unlock();
    pool_gpa = gpa;
}

/// Connects libkernel memory exports to the process-wide guest address space.
/// Passing null detaches it during runtime teardown.
pub fn attachAddressSpace(address_space: ?*memory.AddressSpace) void {
    pool_lock.lock();
    defer pool_lock.unlock();
    guest_address_space = address_space;
}

pub fn deinit() void {
    pool_lock.lock();
    defer pool_lock.unlock();
    if (pool_gpa) |gpa| pool.deinit(gpa);
    pool = .{};
    pool_gpa = null;
    guest_address_space = null;
}

// ---------------------------------------------------------------------------
// Guest entry points
// ---------------------------------------------------------------------------

/// Reserves a range of physical memory.
///
/// On success the chosen physical address is written through `out_start`.
fn sceKernelAllocateDirectMemory(
    search_start: u64,
    search_end: u64,
    len: u64,
    alignment: u64,
    memory_type: i32,
    out_start: ?*u64,
) callconv(abi.guest) i32 {
    if (out_start == null) return KernelError.efault.raw();
    if (len == 0 or len % page_size != 0) return KernelError.einval.raw();
    if (alignment != 0 and !std.math.isPowerOfTwo(alignment)) return KernelError.einval.raw();
    if (search_end <= search_start) return KernelError.einval.raw();

    pool_lock.lock();
    defer pool_lock.unlock();

    const gpa = pool_gpa orelse return KernelError.enomem.raw();

    const start = pool.reserve(
        gpa,
        search_start,
        search_end,
        len,
        alignment,
        @enumFromInt(memory_type),
    ) catch |err| return switch (err) {
        error.OutOfDirectMemory => KernelError.eagain.raw(),
        error.OutOfMemory => KernelError.enomem.raw(),
        error.NotReserved => unreachable, // reserve() never reports this
    };

    out_start.?.* = start;
    return errno.ok;
}

/// Releases a range reserved by `sceKernelAllocateDirectMemory`.
fn sceKernelReleaseDirectMemory(start: u64, len: u64) callconv(abi.guest) i32 {
    pool_lock.lock();
    defer pool_lock.unlock();

    if (!pool.hasExactReservation(start, len)) return KernelError.einval.raw();
    if (guest_address_space) |address_space| {
        if (address_space.hasDirectMemoryMappings(start, len)) {
            return KernelError.ebusy.raw();
        }
    }
    pool.release(start, len) catch |err| return switch (err) {
        error.NotReserved => KernelError.einval.raw(),
        else => KernelError.enomem.raw(),
    };
    return errno.ok;
}

/// Total size of the direct memory pool.
fn sceKernelGetDirectMemorySize() callconv(abi.guest) u64 {
    pool_lock.lock();
    defer pool_lock.unlock();
    return pool.size;
}

fn sceKernelAllocateMainDirectMemory(
    len: u64,
    alignment: u64,
    memory_type: i32,
    out_start: ?*u64,
) callconv(abi.guest) i32 {
    return sceKernelAllocateDirectMemory(
        0,
        direct_memory_size,
        len,
        alignment,
        memory_type,
        out_start,
    );
}

fn sceKernelCheckedReleaseDirectMemory(start: u64, len: u64) callconv(abi.guest) i32 {
    return sceKernelReleaseDirectMemory(start, len);
}

const map_fixed: i32 = 0x10;
const map_no_overwrite: u32 = 0x80;
const map_dmem_compat: u32 = 0x400;
const map_unknown_8000: u32 = 0x8000;
const map_no_coalesce: u32 = 0x40_0000;
const map_alignment_mask: u32 = 0xff00_0000;
const default_map_search_base: u64 = 0x02_0000_0000;
const prot_cpu_read: i32 = 0x01;
const prot_cpu_write: i32 = 0x02;
const prot_cpu_execute: i32 = 0x04;
const prot_gpu_read: i32 = 0x10;
const prot_gpu_write: i32 = 0x20;
const supported_protection_bits: i32 = prot_cpu_read | prot_cpu_write | prot_cpu_execute |
    prot_gpu_read | prot_gpu_write;

fn decodeProtection(bits: i32) ?memory.Protection {
    if (bits & ~supported_protection_bits != 0) return null;
    return .{
        .read = bits & prot_cpu_read != 0,
        .write = bits & prot_cpu_write != 0,
        .execute = bits & prot_cpu_execute != 0,
    };
}

/// Maps a reserved physical range into the identity-mapped guest address space.
fn sceKernelMapDirectMemory(
    out_address: ?*u64,
    len: u64,
    protection_bits: i32,
    flags: i32,
    physical_address: u64,
    alignment: u64,
) callconv(abi.guest) i32 {
    if (len == 0 or len % page_size != 0) return KernelError.einval.raw();
    if (physical_address % page_size != 0) return KernelError.einval.raw();
    const effective_alignment = @max(alignment, page_size);
    if (!std.math.isPowerOfTwo(effective_alignment)) return KernelError.einval.raw();

    pool_lock.lock();
    defer pool_lock.unlock();

    const reservation = pool.findContainingRange(physical_address, len) orelse
        return KernelError.einval.raw();
    const output = out_address orelse return KernelError.efault.raw();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    const protection = decodeProtection(protection_bits) orelse return KernelError.einval.raw();

    const requested_address = output.*;
    const mapped_address = if (flags & map_fixed != 0) fixed: {
        if (requested_address == 0 or requested_address % page_size != 0) {
            return KernelError.einval.raw();
        }
        address_space.mapFixed(
            requested_address,
            len,
            protection,
            .direct_memory,
            physical_address,
        ) catch |err| return mapAddressSpaceError(err);
        break :fixed requested_address;
    } else address_space.map(
        .user,
        requested_address,
        len,
        effective_alignment,
        protection,
        .direct_memory,
        physical_address,
    ) catch |err| return mapAddressSpaceError(err);

    address_space.setMetadata(mapped_address, len, .{
        .protection_bits = protection_bits,
        .memory_type = @intFromEnum(reservation.memory_type),
        .name = "direct",
    }) catch |err| {
        address_space.unmap(mapped_address, len) catch {};
        return mapAddressSpaceError(err);
    };
    output.* = mapped_address;
    return errno.ok;
}

fn sceKernelMapNamedDirectMemory(
    out_address: ?*u64,
    len: u64,
    protection_bits: i32,
    flags: i32,
    physical_address: u64,
    alignment: u64,
    name_pointer: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    const output = out_address orelse return KernelError.efault.raw();
    const pointer = name_pointer orelse return KernelError.efault.raw();
    const name = std.mem.span(pointer);
    if (name.len >= maximum_name_length) return KernelError.enametoolong.raw();
    const status = sceKernelMapDirectMemory(
        output,
        len,
        protection_bits,
        flags,
        physical_address,
        alignment,
    );
    if (status != errno.ok) return status;

    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    address_space.setMetadata(output.*, len, .{ .name = name }) catch |err| {
        address_space.unmap(output.*, len) catch {};
        return mapAddressSpaceError(err);
    };
    return errno.ok;
}

fn sceKernelDirectMemoryQuery(
    offset: i64,
    flags: i32,
    out_info: ?*DirectMemoryQueryInfo,
    info_size: u64,
) callconv(abi.guest) i32 {
    const info = out_info orelse return KernelError.einval.raw();
    if (offset < 0 or (flags != 0 and flags != 1) or info_size != @sizeOf(DirectMemoryQueryInfo)) {
        return KernelError.einval.raw();
    }

    pool_lock.lock();
    defer pool_lock.unlock();
    const query_offset: u64 = @intCast(offset);
    var reservation = pool.findContaining(query_offset);
    if (reservation == null and flags == 1) {
        for (pool.reservations.items) |*candidate| {
            if (candidate.start < query_offset) continue;
            if (reservation == null or candidate.start < reservation.?.start) {
                reservation = candidate;
            }
        }
    }
    const found = reservation orelse {
        if (flags == 1 and query_offset < pool.size) {
            info.* = .{ .start = @intCast(pool.size), .end = @intCast(pool.size) };
            return errno.ok;
        }
        return KernelError.eacces.raw();
    };
    info.* = .{
        .start = @intCast(found.start),
        .end = @intCast(found.end()),
        .memory_type = @intFromEnum(found.memory_type),
    };
    return errno.ok;
}

fn sceKernelIsStack(address: u64, out_start: ?*u64, out_end: ?*u64) callconv(abi.guest) i32 {
    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    const mapping = address_space.query(address, false) orelse return KernelError.eacces.raw();
    const is_stack = mapping.kind == .stack;
    if (out_start) |output| output.* = if (is_stack) mapping.address else 0;
    if (out_end) |output| output.* = if (is_stack) mapping.end() else 0;
    return errno.ok;
}

fn mapFlexibleMemory(
    out_address: ?*u64,
    len: u64,
    protection_bits: i32,
    flags: i32,
    name: []const u8,
) i32 {
    const output = out_address orelse return KernelError.efault.raw();
    if (len == 0 or len % page_size != 0) return KernelError.einval.raw();
    if (name.len >= maximum_name_length) return KernelError.enametoolong.raw();
    const protection = decodeProtection(protection_bits) orelse return KernelError.einval.raw();

    const map_flags: u32 = @bitCast(flags);
    const supported_flags = @as(u32, @intCast(map_fixed)) | map_no_overwrite |
        map_dmem_compat | map_unknown_8000 | map_no_coalesce | map_alignment_mask;
    const alignment_shift: u8 = @intCast((map_flags & map_alignment_mask) >> 24);
    if (map_flags & ~supported_flags != 0 or
        (alignment_shift != 0 and (alignment_shift < 14 or alignment_shift > 31)))
    {
        return KernelError.einval.raw();
    }
    const alignment = if (alignment_shift == 0)
        page_size
    else
        @as(u64, 1) << @intCast(alignment_shift);

    pool_lock.lock();
    defer pool_lock.unlock();

    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    const used = address_space.mappedBytes(.flexible);
    if (used > flexible_memory_size or len > flexible_memory_size - used) {
        return KernelError.enomem.raw();
    }

    const requested_address = output.*;
    output.* = 0;
    const mapped_address = if (map_flags & @as(u32, @intCast(map_fixed)) != 0) fixed: {
        if (requested_address == 0 or requested_address % alignment != 0) {
            return KernelError.einval.raw();
        }

        if (address_space.isMapped(requested_address, len)) {
            if (map_flags & map_no_overwrite != 0) return KernelError.enomem.raw();
            address_space.unmap(requested_address, len) catch |err|
                return mapAddressSpaceError(err);
        }
        address_space.mapFixed(
            requested_address,
            len,
            protection,
            .flexible,
            null,
        ) catch |err| return mapAddressSpaceError(err);
        break :fixed requested_address;
    } else first_fit: {
        const hint = if (requested_address == 0) default_map_search_base else requested_address;
        if (hint >= memory.user.start) {
            break :first_fit address_space.map(
                .user,
                hint,
                len,
                alignment,
                protection,
                .flexible,
                null,
            ) catch |err| return mapAddressSpaceError(err);
        }

        break :first_fit address_space.map(
            .system_managed,
            hint,
            len,
            alignment,
            protection,
            .flexible,
            null,
        ) catch |err| switch (err) {
            error.AddressUnavailable => address_space.map(
                .user,
                0,
                len,
                alignment,
                protection,
                .flexible,
                null,
            ) catch |fallback_err| return mapAddressSpaceError(fallback_err),
            else => return mapAddressSpaceError(err),
        };
    };

    address_space.setMetadata(mapped_address, len, .{
        .protection_bits = protection_bits,
        .name = name,
    }) catch |err| {
        address_space.unmap(mapped_address, len) catch {};
        return mapAddressSpaceError(err);
    };
    output.* = mapped_address;
    return errno.ok;
}

pub fn sceKernelMapNamedFlexibleMemory(
    out_address: ?*u64,
    len: u64,
    protection_bits: i32,
    flags: i32,
    name_pointer: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    const pointer = name_pointer orelse return KernelError.efault.raw();
    return mapFlexibleMemory(out_address, len, protection_bits, flags, std.mem.span(pointer));
}

fn sceKernelMapFlexibleMemory(
    out_address: ?*u64,
    len: u64,
    protection_bits: i32,
    flags: i32,
) callconv(abi.guest) i32 {
    return mapFlexibleMemory(out_address, len, protection_bits, flags, "");
}

/// Removes any fully covered combination of direct, flexible, or reserved
/// mappings. AddressSpace preserves the process-wide outer reservations.
fn sceKernelMunmap(address: u64, len: u64) callconv(abi.guest) i32 {
    if (address == 0 or len == 0 or address % page_size != 0 or len % page_size != 0) {
        return KernelError.einval.raw();
    }
    _ = std.math.add(u64, address, len) catch return KernelError.einval.raw();

    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    address_space.unmap(address, len) catch |err| return mapAddressSpaceError(err);
    return errno.ok;
}

fn sceKernelAvailableFlexibleMemorySize(out_size: ?*u64) callconv(abi.guest) i32 {
    const output = out_size orelse return KernelError.einval.raw();
    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    const used = address_space.mappedBytes(.flexible);
    output.* = flexible_memory_size -| used;
    return errno.ok;
}

fn sceKernelConfiguredFlexibleMemorySize(out_size: ?*u64) callconv(abi.guest) i32 {
    const output = out_size orelse return KernelError.einval.raw();
    output.* = flexible_memory_size;
    return errno.ok;
}

fn sceKernelVirtualQuery(
    address: u64,
    flags: i32,
    out_info: ?*VirtualQueryInfo,
    info_size: u64,
) callconv(abi.guest) i32 {
    const info = out_info orelse return KernelError.einval.raw();
    if (info_size != @sizeOf(VirtualQueryInfo) or (flags != 0 and flags != 1)) {
        return KernelError.einval.raw();
    }

    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    const mapping = address_space.query(address, flags == 1) orelse
        return KernelError.eacces.raw();

    info.* = .{};
    info.start = mapping.address;
    info.end = mapping.end();
    info.offset = mapping.backing_offset orelse 0;
    info.protection = mapping.protection_bits;
    info.memory_type = mapping.memory_type;
    info.state = switch (mapping.kind) {
        .flexible => 0x01 | 0x10,
        .direct_memory => 0x02 | 0x10,
        .reserved => 0,
        else => 0x10,
    };
    info.name = mapping.name;
    return errno.ok;
}

fn sceKernelQueryMemoryProtection(
    address: u64,
    out_start: ?*u64,
    out_end: ?*u64,
    out_protection: ?*i32,
) callconv(abi.guest) i32 {
    if (address == 0) return KernelError.einval.raw();
    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    const mapping = address_space.query(address, false) orelse return KernelError.eacces.raw();
    if (out_start) |output| output.* = mapping.address;
    if (out_end) |output| output.* = mapping.end();
    if (out_protection) |output| output.* = mapping.protection_bits;
    return errno.ok;
}

fn sceKernelMprotect(
    address: u64,
    len: u64,
    protection_bits: i32,
) callconv(abi.guest) i32 {
    const protection = decodeProtection(protection_bits) orelse return KernelError.einval.raw();
    if (address == 0 or len == 0) return KernelError.einval.raw();
    const page_offset = address & (page_size - 1);
    const aligned_address = address - page_offset;
    const covered_size = std.math.add(u64, len, page_offset) catch
        return KernelError.einval.raw();
    const rounded_size = std.math.add(u64, covered_size, page_size - 1) catch
        return KernelError.einval.raw();
    const aligned_len = rounded_size & ~(page_size - 1);

    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    address_space.protectGuest(
        aligned_address,
        aligned_len,
        protection,
        protection_bits,
    ) catch |err| return mapAddressSpaceError(err);
    return errno.ok;
}

fn sceKernelSetVirtualRangeName(
    address: u64,
    len: u64,
    name_pointer: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    const pointer = name_pointer orelse return KernelError.efault.raw();
    const name = std.mem.span(pointer);
    if (name.len >= maximum_name_length) return KernelError.enametoolong.raw();

    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    address_space.setMetadata(address, len, .{ .name = name }) catch |err|
        return mapAddressSpaceError(err);
    return errno.ok;
}

fn sceKernelReserveVirtualRange(
    out_address: ?*u64,
    len: u64,
    flags: i32,
    alignment: u64,
) callconv(abi.guest) i32 {
    const output = out_address orelse return KernelError.efault.raw();
    if (len == 0 or len % page_size != 0) return KernelError.einval.raw();
    const effective_alignment = @max(alignment, page_size);
    if (!std.math.isPowerOfTwo(effective_alignment)) return KernelError.einval.raw();
    const map_flags: u32 = @bitCast(flags);
    const supported_flags = @as(u32, @intCast(map_fixed)) | map_no_overwrite;
    if (map_flags & ~supported_flags != 0) return KernelError.einval.raw();

    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    const requested_address = output.*;
    output.* = 0;

    const reserved_address = if (map_flags & @as(u32, @intCast(map_fixed)) != 0) fixed: {
        if (requested_address == 0 or requested_address % effective_alignment != 0) {
            return KernelError.einval.raw();
        }
        if (address_space.isMapped(requested_address, len)) {
            if (map_flags & map_no_overwrite != 0) return KernelError.enomem.raw();
            address_space.unmap(requested_address, len) catch |err|
                return mapAddressSpaceError(err);
        }
        address_space.reserveFixed(requested_address, len) catch |err|
            return mapAddressSpaceError(err);
        break :fixed requested_address;
    } else first_fit: {
        const hint = if (requested_address == 0) default_map_search_base else requested_address;
        const area: memory.Area = if (hint >= memory.user.start) .user else .system_managed;
        break :first_fit address_space.reserve(
            area,
            hint,
            len,
            effective_alignment,
        ) catch |err| return mapAddressSpaceError(err);
    };

    output.* = reserved_address;
    return errno.ok;
}

fn mapAddressSpaceError(err: memory.Error) i32 {
    return switch (err) {
        error.InvalidAddress, error.InvalidSize, error.InvalidAlignment => KernelError.einval.raw(),
        error.UnsupportedHost => KernelError.enosys.raw(),
        error.AddressSpaceUnavailable,
        error.AddressUnavailable,
        error.HostCommitFailed,
        error.BackingStoreUnavailable,
        error.OutOfMemory,
        => KernelError.enomem.raw(),
        error.BackingOffsetInvalid => KernelError.einval.raw(),
        error.RangeNotMapped,
        error.ProtectionDenied,
        error.HostDecommitFailed,
        => KernelError.eacces.raw(),
    };
}

/// Exports of this library, paired with the identifiers the guest imports them
/// by. The identifiers are asserted rather than trusted: a mistyped name fails
/// at registration instead of becoming an unresolved import at load time.
pub const exports = [_]symbols.Export{
    .{
        .name = "sceKernelAllocateDirectMemory",
        .function = abi.erase(&sceKernelAllocateDirectMemory),
        .expect_id = "rTXw65xmLIA",
    },
    .{
        .name = "sceKernelReleaseDirectMemory",
        .function = abi.erase(&sceKernelReleaseDirectMemory),
        .expect_id = "MBuItvba6z8",
    },
    .{
        .name = "sceKernelGetDirectMemorySize",
        .function = abi.erase(&sceKernelGetDirectMemorySize),
        .expect_id = "pO96TwzOm5E",
    },
    .{
        .name = "sceKernelAllocateMainDirectMemory",
        .function = abi.erase(&sceKernelAllocateMainDirectMemory),
        .expect_id = "B+vc2AO2Zrc",
    },
    .{
        .name = "sceKernelCheckedReleaseDirectMemory",
        .function = abi.erase(&sceKernelCheckedReleaseDirectMemory),
        .expect_id = "hwVSPCmp5tM",
    },
    .{
        .name = "sceKernelMapDirectMemory",
        .function = abi.erase(&sceKernelMapDirectMemory),
        .expect_id = "L-Q3LEjIbgA",
    },
    .{
        .name = "sceKernelMapNamedDirectMemory",
        .function = abi.erase(&sceKernelMapNamedDirectMemory),
        .expect_id = "NcaWUxfMNIQ",
    },
    .{
        .name = "sceKernelDirectMemoryQuery",
        .function = abi.erase(&sceKernelDirectMemoryQuery),
        .expect_id = "BHouLQzh0X0",
    },
    .{
        .name = "sceKernelIsStack",
        .function = abi.erase(&sceKernelIsStack),
        .expect_id = "yDBwVAolDgg",
    },
    .{
        .name = "sceKernelMapNamedFlexibleMemory",
        .function = abi.erase(&sceKernelMapNamedFlexibleMemory),
        .expect_id = "mL8NDH86iQI",
    },
    .{
        .name = "sceKernelMapFlexibleMemory",
        .function = abi.erase(&sceKernelMapFlexibleMemory),
        .expect_id = "IWIBBdTHit4",
    },
    .{
        .name = "sceKernelMunmap",
        .function = abi.erase(&sceKernelMunmap),
        .expect_id = "cQke9UuBQOk",
    },
    .{
        .name = "sceKernelVirtualQuery",
        .function = abi.erase(&sceKernelVirtualQuery),
        .expect_id = "rVjRvHJ0X6c",
    },
    .{
        .name = "sceKernelQueryMemoryProtection",
        .function = abi.erase(&sceKernelQueryMemoryProtection),
        .expect_id = "WFcfL2lzido",
    },
    .{
        .name = "sceKernelAvailableFlexibleMemorySize",
        .function = abi.erase(&sceKernelAvailableFlexibleMemorySize),
        .expect_id = "aNz11fnnzi4",
    },
    .{
        .name = "sceKernelConfiguredFlexibleMemorySize",
        .function = abi.erase(&sceKernelConfiguredFlexibleMemorySize),
        .expect_id = "n1-v6FgU7MQ",
    },
    .{
        .name = "sceKernelMprotect",
        .function = abi.erase(&sceKernelMprotect),
        .expect_id = "vSMAm3cxYTY",
    },
    .{
        .name = "sceKernelSetVirtualRangeName",
        .function = abi.erase(&sceKernelSetVirtualRangeName),
        .expect_id = "DGMG3JshrZU",
    },
    .{
        .name = "sceKernelReserveVirtualRange",
        .function = abi.erase(&sceKernelReserveVirtualRange),
        .expect_id = "7oxv3PPCumo",
    },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

/// Registers this library with a symbol database.
pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "guest GPU protection does not grant native CPU access" {
    const protection = decodeProtection(prot_gpu_read | prot_gpu_write).?;
    try testing.expectEqual(memory.Protection.none, protection);
}

test "reservations are aligned and do not overlap" {
    var p = Pool{ .size = 64 * page_size };
    defer p.deinit(testing.allocator);

    const a = try p.reserve(testing.allocator, 0, p.size, 4 * page_size, page_size, .wb_onion);
    const b = try p.reserve(testing.allocator, 0, p.size, 4 * page_size, page_size, .wb_onion);

    try testing.expectEqual(@as(u64, 0), a);
    // The second reservation cannot overlap the first.
    try testing.expect(b >= a + 4 * page_size);
    try testing.expectEqual(@as(u64, 0), b % page_size);
    try testing.expectEqual(@as(u64, 8 * page_size), p.used());
}

test "a larger alignment is honoured" {
    var p = Pool{ .size = 64 * page_size };
    defer p.deinit(testing.allocator);

    // Occupy the start so the next reservation cannot simply land at zero.
    _ = try p.reserve(testing.allocator, 0, p.size, page_size, page_size, .wb_onion);

    const aligned = try p.reserve(testing.allocator, 0, p.size, page_size, 8 * page_size, .wb_onion);
    try testing.expectEqual(@as(u64, 0), aligned % (8 * page_size));
    try testing.expect(aligned >= page_size);
}

test "the pool reports exhaustion rather than overcommitting" {
    var p = Pool{ .size = 4 * page_size };
    defer p.deinit(testing.allocator);

    _ = try p.reserve(testing.allocator, 0, p.size, 4 * page_size, page_size, .wb_onion);
    try testing.expectError(
        error.OutOfDirectMemory,
        p.reserve(testing.allocator, 0, p.size, page_size, page_size, .wb_onion),
    );
}

test "release accepts an exact range and rejects anything else" {
    var p = Pool{ .size = 64 * page_size };
    defer p.deinit(testing.allocator);

    const start = try p.reserve(testing.allocator, 0, p.size, 4 * page_size, page_size, .wb_onion);

    // A partial release would have to split the reservation, which is not
    // supported; it must not silently free the whole range.
    try testing.expectError(PoolError.NotReserved, p.release(start, 2 * page_size));
    try testing.expectEqual(@as(u64, 4 * page_size), p.used());

    try p.release(start, 4 * page_size);
    try testing.expectEqual(@as(u64, 0), p.used());
}

test "released ranges become available again" {
    var p = Pool{ .size = 4 * page_size };
    defer p.deinit(testing.allocator);

    const start = try p.reserve(testing.allocator, 0, p.size, 4 * page_size, page_size, .wb_onion);
    try p.release(start, 4 * page_size);

    const again = try p.reserve(testing.allocator, 0, p.size, 4 * page_size, page_size, .wb_onion);
    try testing.expectEqual(start, again);
}

test "the entry point rejects malformed requests" {
    init(testing.allocator);
    defer deinit();

    var out: u64 = 0;

    // A length that is not a multiple of the page size.
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelAllocateDirectMemory(0, direct_memory_size, page_size + 1, page_size, 0, &out),
    );
    // A zero length.
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelAllocateDirectMemory(0, direct_memory_size, 0, page_size, 0, &out),
    );
    // An alignment that is not a power of two.
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelAllocateDirectMemory(0, direct_memory_size, page_size, 3, 0, &out),
    );
    // No output pointer.
    try testing.expectEqual(
        KernelError.efault.raw(),
        sceKernelAllocateDirectMemory(0, direct_memory_size, page_size, page_size, 0, null),
    );
}

test "allocate and release round-trip through the entry points" {
    init(testing.allocator);
    defer deinit();

    var start: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateDirectMemory(0, direct_memory_size, 2 * page_size, page_size, 0, &start),
    );
    try testing.expectEqual(@as(u64, 2 * page_size), pool.used());

    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(start, 2 * page_size));
    try testing.expectEqual(@as(u64, 0), pool.used());

    // Releasing twice must fail rather than corrupt the bookkeeping.
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelReleaseDirectMemory(start, 2 * page_size),
    );
}

test "main direct-memory wrappers preserve reservation metadata" {
    init(testing.allocator);
    defer deinit();

    var start: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateMainDirectMemory(2 * page_size, page_size, 3, &start),
    );
    var info = DirectMemoryQueryInfo{};
    try testing.expectEqual(
        errno.ok,
        sceKernelDirectMemoryQuery(@intCast(start), 0, &info, @sizeOf(DirectMemoryQueryInfo)),
    );
    try testing.expectEqual(@as(i64, @intCast(start)), info.start);
    try testing.expectEqual(@as(i64, @intCast(start + 2 * page_size)), info.end);
    try testing.expectEqual(@as(i32, 3), info.memory_type);
    try testing.expectEqual(errno.ok, sceKernelCheckedReleaseDirectMemory(start, 2 * page_size));
}

test "direct memory maps at an exact guest address" {
    var address_space = try memory.AddressSpace.initWithDirectMemory(
        testing.allocator,
        direct_memory_size,
    );
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    var start: u64 = 0;
    _ = sceKernelAllocateDirectMemory(0, direct_memory_size, page_size, page_size, 0, &start);
    var virtual_address = memory.user.start;

    // Far outside anything reserved.
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelMapDirectMemory(
            &virtual_address,
            page_size,
            prot_cpu_read | prot_cpu_write,
            map_fixed,
            direct_memory_size - page_size,
            0,
        ),
    );

    try testing.expectEqual(
        errno.ok,
        sceKernelMapDirectMemory(
            &virtual_address,
            page_size,
            prot_cpu_read | prot_cpu_write,
            map_fixed,
            start,
            0,
        ),
    );
    try testing.expectEqual(memory.user.start, virtual_address);
    try testing.expect(address_space.isMappedAs(virtual_address, page_size, .direct_memory));

    try address_space.write(virtual_address, "direct");
    var bytes: [6]u8 = undefined;
    const alias_address = virtual_address + page_size;
    var alias = alias_address;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapDirectMemory(
            &alias,
            page_size,
            prot_cpu_read | prot_cpu_write,
            map_fixed,
            start,
            0,
        ),
    );
    try address_space.read(alias, &bytes);
    try testing.expectEqualStrings("direct", &bytes);
    try testing.expectEqual(
        KernelError.ebusy.raw(),
        sceKernelReleaseDirectMemory(start, page_size),
    );

    var direct_info = VirtualQueryInfo{};
    try testing.expectEqual(
        errno.ok,
        sceKernelVirtualQuery(alias, 0, &direct_info, @sizeOf(VirtualQueryInfo)),
    );
    try testing.expectEqual(@as(u32, 0x12), direct_info.state);
    try testing.expectEqual(start, direct_info.offset);
    try testing.expectEqual(@as(i32, 0), direct_info.memory_type);

    try testing.expectEqual(errno.ok, sceKernelMunmap(virtual_address, page_size));
    try testing.expectEqual(errno.ok, sceKernelMunmap(alias, page_size));
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(start, page_size));
}

test "flexible memory maps, queries, protects, unmaps, and reuses ranges" {
    try testing.expectEqual(@as(usize, 72), @sizeOf(VirtualQueryInfo));

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    var configured: u64 = 0;
    var available: u64 = 0;
    try testing.expectEqual(errno.ok, sceKernelConfiguredFlexibleMemorySize(&configured));
    try testing.expectEqual(flexible_memory_size, configured);
    try testing.expectEqual(errno.ok, sceKernelAvailableFlexibleMemorySize(&available));
    try testing.expectEqual(flexible_memory_size, available);

    const original_protection = prot_cpu_read | prot_cpu_write | prot_gpu_write;
    var mapped: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapNamedFlexibleMemory(
            &mapped,
            2 * page_size,
            original_protection,
            @bitCast(@as(u32, 16 << 24)),
            "flex-test",
        ),
    );
    try testing.expectEqual(@as(u64, 0), mapped % (64 * 1024));
    try testing.expectEqual(errno.ok, sceKernelAvailableFlexibleMemorySize(&available));
    try testing.expectEqual(flexible_memory_size - 2 * page_size, available);

    var initial: [16]u8 = undefined;
    try address_space.read(mapped, &initial);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** initial.len), &initial);
    try address_space.write(mapped, "flexible");

    var info = VirtualQueryInfo{};
    try testing.expectEqual(
        errno.ok,
        sceKernelVirtualQuery(mapped + page_size, 0, &info, @sizeOf(VirtualQueryInfo)),
    );
    try testing.expectEqual(mapped, info.start);
    try testing.expectEqual(mapped + 2 * page_size, info.end);
    try testing.expectEqual(original_protection, info.protection);
    try testing.expectEqual(@as(u32, 0x11), info.state);
    try testing.expectEqualStrings("flex-test", std.mem.sliceTo(&info.name, 0));

    var range_start: u64 = 0;
    var range_end: u64 = 0;
    var queried_protection: i32 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelQueryMemoryProtection(
            mapped + page_size,
            &range_start,
            &range_end,
            &queried_protection,
        ),
    );
    try testing.expectEqual(mapped, range_start);
    try testing.expectEqual(mapped + 2 * page_size, range_end);
    try testing.expectEqual(original_protection, queried_protection);

    try testing.expectEqual(
        errno.ok,
        sceKernelMprotect(mapped + page_size + 1, page_size - 1, prot_cpu_read),
    );
    try testing.expectError(
        memory.Error.ProtectionDenied,
        address_space.write(mapped + page_size, "x"),
    );
    try testing.expectEqual(
        errno.ok,
        sceKernelSetVirtualRangeName(mapped + page_size, page_size, "read-only-tail"),
    );
    try testing.expectEqual(
        errno.ok,
        sceKernelVirtualQuery(mapped + page_size, 0, &info, @sizeOf(VirtualQueryInfo)),
    );
    try testing.expectEqual(prot_cpu_read, info.protection);
    try testing.expectEqualStrings("read-only-tail", std.mem.sliceTo(&info.name, 0));

    try testing.expectEqual(errno.ok, sceKernelMunmap(mapped + page_size, page_size));
    try testing.expectEqual(errno.ok, sceKernelAvailableFlexibleMemorySize(&available));
    try testing.expectEqual(flexible_memory_size - page_size, available);
    try testing.expectEqual(errno.ok, sceKernelMunmap(mapped, page_size));
    try testing.expectEqual(errno.ok, sceKernelAvailableFlexibleMemorySize(&available));
    try testing.expectEqual(flexible_memory_size, available);

    var reserved = mapped;
    try testing.expectEqual(
        errno.ok,
        sceKernelReserveVirtualRange(&reserved, page_size, map_fixed, page_size),
    );
    try testing.expectEqual(
        errno.ok,
        sceKernelVirtualQuery(reserved, 0, &info, @sizeOf(VirtualQueryInfo)),
    );
    try testing.expectEqual(@as(u32, 0), info.state);

    var reused = reserved;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapFlexibleMemory(
            &reused,
            page_size,
            prot_cpu_read | prot_cpu_write,
            map_fixed,
        ),
    );
    try testing.expectEqual(reserved, reused);
    var reused_bytes: [8]u8 = undefined;
    try address_space.read(reused, &reused_bytes);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** reused_bytes.len), &reused_bytes);

    var collision = reused;
    try testing.expectEqual(
        KernelError.enomem.raw(),
        sceKernelMapFlexibleMemory(
            &collision,
            page_size,
            prot_cpu_read,
            @bitCast(@as(u32, @intCast(map_fixed)) | map_no_overwrite),
        ),
    );
    try testing.expectEqual(errno.ok, sceKernelMunmap(reused, page_size));
    try testing.expectEqual(errno.ok, sceKernelAvailableFlexibleMemorySize(&available));
    try testing.expectEqual(flexible_memory_size, available);
}

test "the library registers under the expected identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);

    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len, db.count());

    const found = db.findByName("sceKernelGetDirectMemorySize", .function) orelse
        return error.TestExpectedSymbol;
    try testing.expectEqualStrings("pO96TwzOm5E", &found.key.id);
}
