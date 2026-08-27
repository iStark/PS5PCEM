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
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const runtime_api = @import("kernel_runtime.zig");
const filesystem = @import("../filesystem.zig");

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

/// All the memory a title may have, of either kind.
///
/// A little under 13.5 GiB, which is what the console leaves to a title after
/// the system takes its share.
pub const total_memory_size: u64 = 13824 * 1024 * 1024;

/// Flexible-memory budget, until system-content configuration says otherwise.
pub const flexible_memory_size: u64 = 4 * 1024 * 1024 * 1024;

/// Size of the direct memory pool reported to the guest.
///
/// The two kinds of memory are not separate supplies: they are cut from the one
/// the machine has, so what a title can hold directly is what is left after the
/// flexible budget. Reporting the two independently promises more memory than
/// the console has, and a title that sizes its allocators from both answers --
/// which is exactly what titles do with these figures during startup -- budgets
/// for memory that was never going to exist.
pub const direct_memory_size: u64 = total_memory_size - flexible_memory_size;

pub const maximum_name_length: usize = memory.maximum_name_length;

/// Flags packed into `VirtualQueryInfo.state`.
///
/// The guest declares this field as a bitfield rather than an enumeration, so
/// several flags describe one range at once: a mapping is of some type *and*
/// committed. Naming them keeps the distinction visible.
pub const state_flexible: u32 = 1 << 0;
pub const state_direct: u32 = 1 << 1;
pub const state_stack: u32 = 1 << 2;
pub const state_pooled: u32 = 1 << 3;
pub const state_committed: u32 = 1 << 4;
pub const state_gpu_prt: u32 = 1 << 5;

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

    /// Whether any part of a range is reserved.
    ///
    /// Asked before a release does anything, so that a range owning nothing is
    /// refused without having torn down mappings on the way to refusing it.
    pub fn hasAnyReservation(self: *const Pool, start: u64, len: u64) bool {
        for (self.reservations.items) |r| {
            if (r.overlaps(start, len)) return true;
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

    /// Releases part or all of a previously reserved range.
    ///
    /// Titles allocate physical memory in pieces and hand it back in different
    /// pieces, so a release routinely covers only part of one reservation, or
    /// spans several. Anything inside the requested range that is reserved is
    /// released; whatever is left of a partially covered reservation stays.
    ///
    /// A range covering nothing reserved is still an error: it means the title
    /// believes it owns memory it does not, and reporting that is more useful
    /// than silently succeeding.
    pub fn release(self: *Pool, gpa: std.mem.Allocator, start: u64, len: u64) PoolError!void {
        const end = std.math.add(u64, start, len) catch return PoolError.NotReserved;
        var released = false;

        var index: usize = 0;
        while (index < self.reservations.items.len) {
            const reservation = self.reservations.items[index];
            const overlap_start = @max(start, reservation.start);
            const overlap_end = @min(end, reservation.end());
            if (overlap_start >= overlap_end) {
                index += 1;
                continue;
            }

            released = true;
            _ = self.reservations.orderedRemove(index);

            // Reinsert whatever the release did not cover. Growing the list
            // while iterating is safe because the replacements are placed at
            // the current position and re-examined; they no longer overlap.
            if (reservation.start < overlap_start) {
                try self.reservations.insert(gpa, index, .{
                    .start = reservation.start,
                    .len = overlap_start - reservation.start,
                    .alignment = reservation.alignment,
                    .memory_type = reservation.memory_type,
                });
                index += 1;
            }
            if (overlap_end < reservation.end()) {
                try self.reservations.insert(gpa, index, .{
                    .start = overlap_end,
                    .len = reservation.end() - overlap_end,
                    .alignment = reservation.alignment,
                    .memory_type = reservation.memory_type,
                });
                index += 1;
            }
        }

        if (!released) return PoolError.NotReserved;
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

/// Whether a guest buffer is safe for firmware to touch.
///
/// A guest hands firmware raw addresses and lengths. Trusting them means a
/// title's own bug becomes a crash in the emulator, on a host thread where the
/// guest fault handler declines to help — so the failure arrives with none of
/// the state that would explain it. Checking here turns that into the `EFAULT`
/// the title would get on hardware.
///
/// A zero length is accepted regardless of the pointer, matching the calls that
/// treat it as a no-op.
///
/// With no address space attached there is no guest, so any pointer belongs to
/// the host and is accepted. The runtime attaches one before guest code runs,
/// so this only relaxes the check where there is nothing to protect against.
pub fn isGuestRangeAccessible(address: u64, length: u64) bool {
    if (length == 0) return true;
    if (address == 0) return false;
    _ = std.math.add(u64, address, length) catch return false;

    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return true;
    // AddressSpace mappings include virtual reservations so firmware queries
    // can report them. They are not safe native pointers until pages are
    // committed with CPU access; treating a reserve as readable turns a bad
    // guest descriptor into a host-side memcpy access violation.
    if (address_space.isReadable(address, length)) return true;

    // Native guest code also receives allocations from the Windows CRT. Those
    // pages are not AddressSpace mappings and can sit in a hole covered by the
    // title's logical VA reservation. Accept only ranges VirtualQuery proves
    // are committed and CPU-readable; an untouched placeholder/reserve still
    // fails this check.
    return memory.isHostRangeReadable(address, length);
}

pub fn deinit() void {
    pool_lock.lock();
    defer pool_lock.unlock();
    if (pool_gpa) |gpa| pool.deinit(gpa);
    pool = .{};
    pool_gpa = null;
    guest_address_space = null;
}

/// Direct-memory helpers for AMPR AMM command execution. They reuse the guest
/// entry points so pool accounting and AddressSpace placement stay in one place.
pub fn hostAllocateDirectMemory(
    search_start: u64,
    search_end: u64,
    len: u64,
    alignment: u64,
    memory_type: i32,
    out_start: *u64,
) i32 {
    return sceKernelAllocateDirectMemory(
        search_start,
        search_end,
        len,
        alignment,
        memory_type,
        out_start,
    );
}

pub fn hostMapDirectMemoryFixed(va: u64, len: u64, protection_bits: i32, physical: u64) i32 {
    var address = va;
    return sceKernelMapDirectMemory(&address, len, protection_bits, map_fixed, physical, page_size);
}

pub fn hostUnmap(va: u64, len: u64) i32 {
    return sceKernelMunmap(va, len);
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
///
/// The range need not match a reservation. Physical memory is owned by offset,
/// not by the call that acquired it: a title routinely takes a large region once
/// and then hands parts of it back as it finishes with them, and it may hand
/// back a span that crosses two acquisitions. The pool models that; requiring an
/// exact match here would refuse every one of those releases, and a title whose
/// releases all fail exhausts the pool and then dereferences the failure.
///
/// What is still refused is a range covering nothing reserved, which means the
/// title believes it owns memory it does not.
///
/// Any mapping that views the released memory is taken down as part of the
/// release, rather than the release being refused because one exists. A window
/// onto physical memory cannot outlive the memory, and a title is not required
/// to close its windows first — firmware does that for it.
fn sceKernelReleaseDirectMemory(start: u64, len: u64) callconv(abi.guest) i32 {
    pool_lock.lock();
    defer pool_lock.unlock();

    if (len == 0 or
        !std.mem.isAligned(start, page_size) or
        !std.mem.isAligned(len, page_size))
    {
        return KernelError.einval.raw();
    }
    // Ordered before the unmapping so that a range owning nothing is refused
    // without having taken anything down on the way to saying so.
    if (!pool.hasAnyReservation(start, len)) return KernelError.einval.raw();
    if (guest_address_space) |address_space| {
        _ = address_space.unmapDirectMemoryBacking(start, len);
    }
    const gpa = pool_gpa orelse return KernelError.enomem.raw();
    pool.release(gpa, start, len) catch |err| return switch (err) {
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
const prot_ampr_read: i32 = 0x40;
const prot_ampr_write: i32 = 0x80;
const prot_acp_read: i32 = 0x100;
const prot_acp_write: i32 = 0x200;
const supported_protection_bits: i32 = prot_cpu_read | prot_cpu_write | prot_cpu_execute |
    prot_gpu_read | prot_gpu_write | prot_ampr_read | prot_ampr_write |
    prot_acp_read | prot_acp_write;

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
    const map_flags: u32 = @bitCast(flags);

    pool_lock.lock();
    defer pool_lock.unlock();

    const reservation = pool.findContainingRange(physical_address, len) orelse
        return KernelError.einval.raw();
    const output = out_address orelse return KernelError.efault.raw();
    const address_space = guest_address_space orelse return KernelError.enosys.raw();
    const protection = decodeProtection(protection_bits) orelse return KernelError.einval.raw();

    const requested_address = output.*;
    output.* = 0;
    // Shipped graphics drivers map a direct-memory pool at the hardware
    // device VA without setting MAP_FIXED. Inside the dedicated device window
    // the address is nevertheless part of the ABI, not a best-effort hint.
    const explicit_fixed = map_flags & @as(u32, @intCast(map_fixed)) != 0;
    const device_request = requested_address != 0 and memory.device.contains(requested_address, len);
    const mapped_address = if (explicit_fixed or device_request) fixed: {
        if (requested_address == 0 or requested_address % effective_alignment != 0) {
            return KernelError.einval.raw();
        }
        const occupied = address_space.isMapped(requested_address, len);
        if (occupied and (!explicit_fixed or map_flags & map_no_overwrite != 0)) {
            return KernelError.enomem.raw();
        }

        // Mapping into a range the title reserved earlier is the common case
        // and has to commit inside the reservation rather than release it. A
        // title reserves a window once and fills it in pieces, so releasing
        // would give up its claim on everything not yet mapped — and releasing
        // part of a reservation cannot restore the host placeholder correctly
        // anyway.
        if (occupied) {
            if (address_space.mapInReservation(
                requested_address,
                len,
                protection,
                .direct_memory,
                physical_address,
            )) |_| {
                break :fixed requested_address;
            } else |err| switch (err) {
                // Not a reservation: fall through to replacing what is there.
                error.RangeNotMapped => {},
                else => return mapAddressSpaceError(err),
            }

            address_space.unmap(requested_address, len) catch |err|
                return mapAddressSpaceError(err);
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
    // Nothing at or after the offset means the walk is over, and saying so is
    // the whole answer. Reporting success with an empty region at the end of
    // the pool — as this used to — describes a region that does not exist, and
    // a title walking physical memory to learn what it owns is told it owns
    // something it does not. The virtual-address walk ends with an error in
    // exactly this situation and titles handle it, so there is no reason for
    // the physical one to invent a final entry.
    const found = reservation orelse return KernelError.eacces.raw();
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

        const occupied = address_space.isMapped(requested_address, len);
        if (occupied) {
            if (map_flags & map_no_overwrite != 0) return KernelError.enomem.raw();

            // A fixed flexible mapping is also how runtimes commit blocks
            // inside a much larger virtual reservation.  Replacing a slice by
            // unmapping it first loses the Windows placeholder which owns the
            // reservation; commit it in place, exactly as direct memory does.
            if (address_space.mapInReservation(
                requested_address,
                len,
                protection,
                .flexible,
                null,
            )) |_| {
                break :fixed requested_address;
            } else |err| switch (err) {
                // The occupied range is committed rather than reserved. Keep
                // MAP_FIXED replacement semantics for that case.
                error.RangeNotMapped => {},
                else => return mapAddressSpaceError(err),
            }

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

/// System flexible memory, which differs only in whose budget it comes from.
///
/// System libraries use this for their own working memory instead of the
/// title's. Nothing here tracks the two budgets separately yet, so it maps the
/// same way; the distinction costs a title nothing until a budget is enforced.
fn sceKernelMapNamedSystemFlexibleMemory(
    out_address: ?*u64,
    len: u64,
    protection_bits: i32,
    flags: i32,
    name_pointer: ?[*:0]const u8,
) callconv(abi.guest) i32 {
    return sceKernelMapNamedFlexibleMemory(out_address, len, protection_bits, flags, name_pointer);
}

const posix_map_anonymous: i32 = 0x1000;
const posix_map_fixed: i32 = 0x0010;
const posix_map_shared: i32 = 0x0001;
const posix_prot_read: i32 = 0x1;
const posix_prot_write: i32 = 0x2;
const posix_prot_exec: i32 = 0x4;

/// The POSIX mapping call, for the anonymous memory it is usually asked for.
///
/// Anonymous requests are flexible memory under another name, so they are
/// answered that way. A file-backed mapping is refused instead of quietly
/// producing zeroed pages: a caller expecting file contents and finding zeros
/// fails much later and for reasons that point nowhere near here.
///
/// The protection bits are the POSIX ones, which do not match the guest's own
/// numbering, so they are translated rather than passed through.
fn mmap(
    address: u64,
    len: u64,
    protection_bits: i32,
    flags: i32,
    descriptor: i32,
    offset: i64,
) callconv(abi.guest) i64 {
    // The graphics driver maps one shared device aperture before its higher
    // level context exists. It is MMIO on the console; here it is an
    // identity-mapped, zero-filled compatibility page. The exact device,
    // offset, and flags make this distinct from pretending that arbitrary
    // file-backed mappings contain useful data. This is a device virtual
    // address, so it must remain fixed rather than being relocated into an
    // ordinary flexible-memory window.
    if (filesystem.deviceOf(descriptor) == .graphics) {
        if (address == 0 or len == 0 or offset != 0 or flags != posix_map_shared) {
            runtime_api.setPosixErrno(errno.Posix.einval);
            return -1;
        }

        const rounded = std.mem.alignForward(u64, len, page_size);
        var mapped = address;
        const fixed_without_overwrite: i32 = @bitCast(
            @as(u32, @intCast(map_fixed)) | map_no_overwrite,
        );
        const status = mapFlexibleMemory(
            &mapped,
            rounded,
            protection_bits & supported_protection_bits,
            fixed_without_overwrite,
            "/dev/gc",
        );
        if (status != errno.ok) {
            runtime_api.setPosixErrno(errno.kernelToPosix(status));
            return -1;
        }
        return @bitCast(mapped);
    }

    if (flags & posix_map_anonymous == 0 or descriptor >= 0) {
        runtime_api.setPosixErrno(errno.Posix.enosys);
        return -1;
    }
    if (len == 0) {
        runtime_api.setPosixErrno(errno.Posix.einval);
        return -1;
    }

    var guest_protection: i32 = 0;
    if (protection_bits & posix_prot_read != 0) guest_protection |= prot_cpu_read;
    if (protection_bits & posix_prot_write != 0) guest_protection |= prot_cpu_write;
    if (protection_bits & posix_prot_exec != 0) guest_protection |= prot_cpu_execute;

    var mapped: u64 = if (flags & posix_map_fixed != 0) address else 0;
    const rounded = std.mem.alignForward(u64, len, page_size);
    const status = mapFlexibleMemory(
        &mapped,
        rounded,
        guest_protection,
        if (flags & posix_map_fixed != 0) map_fixed else 0,
        "mmap",
    );
    if (status != errno.ok) {
        runtime_api.setPosixErrno(errno.kernelToPosix(status));
        return -1;
    }
    return @bitCast(mapped);
}

/// Memory reserved for development hardware.
///
/// A retail console has none, and reporting otherwise would let a title
/// allocate from a region that does not exist. Every entry point in the family
/// therefore agrees that the pool is empty rather than each guessing.
const tool_memory_size: u64 = 0;

fn availableToolMemorySize() callconv(abi.guest) u64 {
    return tool_memory_size;
}

fn allocateToolMemory() callconv(abi.guest) i32 {
    return KernelError.enomem.raw();
}

fn mapToolMemory() callconv(abi.guest) i32 {
    return KernelError.enomem.raw();
}

fn releaseToolMemory() callconv(abi.guest) i32 {
    return KernelError.einval.raw();
}

fn getToolMemoryRange() callconv(abi.guest) i32 {
    return KernelError.enosys.raw();
}

/// Statistics about the process page tables.
///
/// Refused rather than filled: the record's layout is not established, and a
/// guessed one would be written straight into the caller's buffer.
fn getPageTableStats() callconv(abi.guest) i32 {
    return KernelError.enosys.raw();
}

const BatchMapEntry = extern struct {
    start: u64,
    offset: u64,
    length: u64,
    protection: u8,
    memory_type: u8,
    reserved: i16,
    operation: i32,
};

comptime {
    std.debug.assert(@sizeOf(BatchMapEntry) == 32);
}

const BatchOperation = enum(i32) {
    map_direct = 0,
    unmap = 1,
    protect = 2,
    map_flexible = 3,
    type_protect = 4,
};

/// Applies mappings in order and reports how many completed before an error.
/// The ABI is intentionally non-transactional: callers use the processed count
/// to retain successful prefix operations when a later entry fails.
fn batchMapCore(
    entries_pointer: ?[*]BatchMapEntry,
    entry_count: i32,
    processed_pointer: ?*i32,
    flags: i32,
) i32 {
    if (entry_count < 0) return KernelError.einval.raw();
    const entries = entries_pointer orelse return KernelError.einval.raw();
    const count: usize = @intCast(entry_count);
    const entries_size = std.math.mul(u64, count, @sizeOf(BatchMapEntry)) catch
        return KernelError.einval.raw();
    if (entries_size != 0 and
        !isGuestRangeAccessible(@intFromPtr(entries), entries_size) and
        !memory.isHostRangeReadable(@intFromPtr(entries), entries_size))
    {
        return KernelError.efault.raw();
    }
    if (processed_pointer) |processed| {
        if (!isGuestRangeAccessible(@intFromPtr(processed), @sizeOf(i32)) and
            !memory.isHostRangeWritable(@intFromPtr(processed), @sizeOf(i32)))
        {
            return KernelError.efault.raw();
        }
        processed.* = 0;
    }

    var processed: i32 = 0;
    for (entries[0..count], 0..) |*entry, index| {
        if (trace.announces("sceKernelBatchMap")) {
            std.debug.print(
                "[batch map {d}] op={d} start=0x{x} offset=0x{x} length=0x{x} prot=0x{x} type=0x{x} flags=0x{x}\n",
                .{
                    index,
                    entry.operation,
                    entry.start,
                    entry.offset,
                    entry.length,
                    entry.protection,
                    entry.memory_type,
                    flags,
                },
            );
        }
        if (entry.length == 0) {
            if (processed_pointer) |output| output.* = processed;
            return KernelError.einval.raw();
        }
        if (entry.operation < @intFromEnum(BatchOperation.map_direct) or
            entry.operation > @intFromEnum(BatchOperation.type_protect))
        {
            if (processed_pointer) |output| output.* = processed;
            return KernelError.einval.raw();
        }
        const operation: BatchOperation = @enumFromInt(entry.operation);
        const protection_bits: i32 = entry.protection;
        const result = switch (operation) {
            .map_direct => sceKernelMapDirectMemory(
                &entry.start,
                entry.length,
                protection_bits,
                flags,
                entry.offset,
                0,
            ),
            .unmap => sceKernelMunmap(entry.start, entry.length),
            .protect, .type_protect => sceKernelMprotect(
                entry.start,
                entry.length,
                protection_bits,
            ),
            .map_flexible => mapFlexibleMemory(
                &entry.start,
                entry.length,
                protection_bits,
                flags,
                "batch",
            ),
        };
        if (result != errno.ok) {
            if (processed_pointer) |output| output.* = processed;
            return result;
        }
        processed += 1;
    }
    if (processed_pointer) |output| output.* = processed;
    return errno.ok;
}

fn sceKernelBatchMap(
    entries: ?[*]BatchMapEntry,
    entry_count: i32,
    processed: ?*i32,
) callconv(abi.guest) i32 {
    return batchMapCore(entries, entry_count, processed, map_fixed);
}

fn sceKernelBatchMap2(
    entries: ?[*]BatchMapEntry,
    entry_count: i32,
    processed: ?*i32,
    flags: i32,
) callconv(abi.guest) i32 {
    return batchMapCore(entries, entry_count, processed, flags);
}

/// Maps direct memory, naming the type it should be treated as.
///
/// The type is what the extra parameter adds over the plain call, and it is not
/// something this layer acts on: nothing here distinguishes one kind of
/// physical memory from another. Ignoring it is safe because it changes how the
/// hardware caches a mapping, not where the mapping is or what it contains —
/// so a title gets the memory it asked for at the address it asked for, which
/// is what it will check.
fn sceKernelMapDirectMemory2(
    out_address: ?*u64,
    len: u64,
    _: i32,
    protection_bits: i32,
    flags: i32,
    physical_address: u64,
    alignment: u64,
) callconv(abi.guest) i32 {
    return sceKernelMapDirectMemory(
        out_address,
        len,
        protection_bits,
        flags,
        physical_address,
        alignment,
    );
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
        .flexible => state_flexible | state_committed,
        .direct_memory => state_direct | state_committed,
        .stack => state_stack | state_committed,
        // A reservation is a claim on addresses and nothing more: no type, and
        // nothing committed behind it.
        .reserved => 0,
        else => state_committed,
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
        // A null hint normally starts in the compact system-managed window,
        // but Unreal reserves a 512 GiB address arena during libc startup.
        // Such a request cannot fit below the user boundary and must start in
        // the title-controlled window just as an explicit user hint would.
        const fits_system_window = len <= memory.system_managed.end - default_map_search_base;
        const area: memory.Area = if (requested_address >= memory.user.start or
            (requested_address == 0 and !fits_system_window))
            .user
        else
            .system_managed;
        const hint = if (requested_address != 0)
            requested_address
        else if (area == .user)
            memory.user.start
        else
            default_map_search_base;
        break :first_fit address_space.reserve(
            area,
            hint,
            len,
            effective_alignment,
        ) catch |err| {
            if (trace.announces("sceKernelReserveVirtualRange")) {
                std.debug.print(
                    "[virtual reserve] requested=0x{x} hint=0x{x} len=0x{x} align=0x{x} area={s} error={s}\n",
                    .{
                        requested_address,
                        hint,
                        len,
                        effective_alignment,
                        @tagName(area),
                        @errorName(err),
                    },
                );
            }
            return mapAddressSpaceError(err);
        };
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
        .function = trace.wrap("sceKernelAllocateDirectMemory", &sceKernelAllocateDirectMemory),
        .expect_id = "rTXw65xmLIA",
    },
    .{
        .name = "sceKernelReleaseDirectMemory",
        .function = trace.wrap("sceKernelReleaseDirectMemory", &sceKernelReleaseDirectMemory),
        .expect_id = "MBuItvba6z8",
    },
    .{
        .name = "sceKernelGetDirectMemorySize",
        .function = trace.wrap("sceKernelGetDirectMemorySize", &sceKernelGetDirectMemorySize),
        .expect_id = "pO96TwzOm5E",
    },
    .{
        .name = "sceKernelAllocateMainDirectMemory",
        .function = trace.wrap("sceKernelAllocateMainDirectMemory", &sceKernelAllocateMainDirectMemory),
        .expect_id = "B+vc2AO2Zrc",
    },
    .{
        .name = "sceKernelCheckedReleaseDirectMemory",
        .function = trace.wrap("sceKernelCheckedReleaseDirectMemory", &sceKernelCheckedReleaseDirectMemory),
        .expect_id = "hwVSPCmp5tM",
    },
    .{
        .name = "sceKernelMapDirectMemory",
        .function = trace.wrap("sceKernelMapDirectMemory", &sceKernelMapDirectMemory),
        .expect_id = "L-Q3LEjIbgA",
    },
    .{
        .name = "sceKernelMapNamedDirectMemory",
        .function = trace.wrap("sceKernelMapNamedDirectMemory", &sceKernelMapNamedDirectMemory),
        .expect_id = "NcaWUxfMNIQ",
    },
    .{
        .name = "sceKernelDirectMemoryQuery",
        .function = trace.wrap("sceKernelDirectMemoryQuery", &sceKernelDirectMemoryQuery),
        .expect_id = "BHouLQzh0X0",
    },
    .{
        .name = "sceKernelIsStack",
        .function = trace.wrap("sceKernelIsStack", &sceKernelIsStack),
        .expect_id = "yDBwVAolDgg",
    },
    .{
        .name = "sceKernelMapNamedFlexibleMemory",
        .function = trace.wrap("sceKernelMapNamedFlexibleMemory", &sceKernelMapNamedFlexibleMemory),
        .expect_id = "mL8NDH86iQI",
    },
    .{
        .name = "sceKernelMapFlexibleMemory",
        .function = trace.wrap("sceKernelMapFlexibleMemory", &sceKernelMapFlexibleMemory),
        .expect_id = "IWIBBdTHit4",
    },
    .{
        .name = "sceKernelMapNamedSystemFlexibleMemory",
        .function = trace.wrap("sceKernelMapNamedSystemFlexibleMemory", &sceKernelMapNamedSystemFlexibleMemory),
        .expect_id = "kc+LEEIYakc",
    },
    .{
        .name = "mmap",
        .function = trace.wrap("mmap", &mmap),
        .expect_id = "BPE9s9vQQXo",
    },
    .{
        .name = "sceKernelAvailableToolMemorySize",
        .function = trace.wrap("sceKernelAvailableToolMemorySize", &availableToolMemorySize),
        .expect_id = "YkwlupG-S4E",
    },
    .{
        .name = "sceKernelAllocateToolMemory",
        .function = trace.wrap("sceKernelAllocateToolMemory", &allocateToolMemory),
        .expect_id = "45Yurf7lZmU",
    },
    .{
        .name = "sceKernelMapToolMemory",
        .function = trace.wrap("sceKernelMapToolMemory", &mapToolMemory),
        .expect_id = "d0vezuPZxtg",
    },
    .{
        .name = "sceKernelReleaseToolMemory",
        .function = trace.wrap("sceKernelReleaseToolMemory", &releaseToolMemory),
        .expect_id = "gO98NioN5FM",
    },
    .{
        .name = "sceKernelGetToolMemoryRange",
        .function = trace.wrap("sceKernelGetToolMemoryRange", &getToolMemoryRange),
        .expect_id = "dkBx0YqFQ+Y",
    },
    .{
        .name = "sceKernelGetPageTableStats",
        .function = trace.wrap("sceKernelGetPageTableStats", &getPageTableStats),
        .expect_id = "tZ2yplY8MBY",
    },
    .{
        .name = "sceKernelMapDirectMemory2",
        .function = trace.wrap("sceKernelMapDirectMemory2", &sceKernelMapDirectMemory2),
        .expect_id = "BQQniolj9tQ",
    },
    .{
        .name = "sceKernelBatchMap",
        .function = trace.wrap("sceKernelBatchMap", &sceKernelBatchMap),
        .expect_id = "2SKEx6bSq-4",
    },
    .{
        .name = "sceKernelBatchMap2",
        .function = trace.wrap("sceKernelBatchMap2", &sceKernelBatchMap2),
        .expect_id = "kBJzF8x4SyE",
    },
    .{
        .name = "sceKernelMunmap",
        .function = trace.wrap("sceKernelMunmap", &sceKernelMunmap),
        .expect_id = "cQke9UuBQOk",
    },
    .{
        .name = "sceKernelVirtualQuery",
        .function = trace.wrap("sceKernelVirtualQuery", &sceKernelVirtualQuery),
        .expect_id = "rVjRvHJ0X6c",
    },
    .{
        .name = "sceKernelQueryMemoryProtection",
        .function = trace.wrap("sceKernelQueryMemoryProtection", &sceKernelQueryMemoryProtection),
        .expect_id = "WFcfL2lzido",
    },
    .{
        .name = "sceKernelAvailableFlexibleMemorySize",
        .function = trace.wrap("sceKernelAvailableFlexibleMemorySize", &sceKernelAvailableFlexibleMemorySize),
        .expect_id = "aNz11fnnzi4",
    },
    .{
        .name = "sceKernelConfiguredFlexibleMemorySize",
        .function = trace.wrap("sceKernelConfiguredFlexibleMemorySize", &sceKernelConfiguredFlexibleMemorySize),
        .expect_id = "n1-v6FgU7MQ",
    },
    .{
        .name = "sceKernelMprotect",
        .function = trace.wrap("sceKernelMprotect", &sceKernelMprotect),
        .expect_id = "vSMAm3cxYTY",
    },
    .{
        .name = "sceKernelSetVirtualRangeName",
        .function = trace.wrap("sceKernelSetVirtualRangeName", &sceKernelSetVirtualRangeName),
        .expect_id = "DGMG3JshrZU",
    },
    .{
        .name = "sceKernelReserveVirtualRange",
        .function = trace.wrap("sceKernelReserveVirtualRange", &sceKernelReserveVirtualRange),
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

test "guest AMPR protection is accepted without granting native CPU access" {
    const protection = decodeProtection(prot_ampr_read | prot_ampr_write).?;
    try testing.expectEqual(memory.Protection.none, protection);
    try testing.expect(decodeProtection(prot_cpu_write | prot_acp_read | prot_acp_write) != null);
    try testing.expect(decodeProtection(0x400) == null);
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

test "release frees part of a reservation and keeps the rest" {
    var p = Pool{ .size = 64 * page_size };
    defer p.deinit(testing.allocator);

    const start = try p.reserve(testing.allocator, 0, p.size, 4 * page_size, page_size, .wb_onion);

    // Titles allocate in one shape and hand memory back in another, so a
    // release routinely covers only part of a reservation.
    try p.release(testing.allocator, start, 2 * page_size);
    try testing.expectEqual(@as(u64, 2 * page_size), p.used());
    // The freed half becomes available; the retained half does not.
    try testing.expect(p.findContaining(start) == null);
    try testing.expect(p.findContaining(start + 2 * page_size) != null);

    try p.release(testing.allocator, start + 2 * page_size, 2 * page_size);
    try testing.expectEqual(@as(u64, 0), p.used());
}

test "release can carve a hole out of the middle" {
    var p = Pool{ .size = 64 * page_size };
    defer p.deinit(testing.allocator);

    const start = try p.reserve(testing.allocator, 0, p.size, 8 * page_size, page_size, .wb_onion);
    try p.release(testing.allocator, start + 2 * page_size, 4 * page_size);

    try testing.expectEqual(@as(u64, 4 * page_size), p.used());
    try testing.expect(p.findContaining(start) != null);
    try testing.expect(p.findContaining(start + 3 * page_size) == null);
    try testing.expect(p.findContaining(start + 6 * page_size) != null);
}

test "release spanning several reservations frees them all" {
    var p = Pool{ .size = 64 * page_size };
    defer p.deinit(testing.allocator);

    const first = try p.reserve(testing.allocator, 0, p.size, 2 * page_size, page_size, .wb_onion);
    const second = try p.reserve(testing.allocator, 0, p.size, 2 * page_size, page_size, .wb_onion);
    try testing.expectEqual(first + 2 * page_size, second);

    try p.release(testing.allocator, first, 4 * page_size);
    try testing.expectEqual(@as(u64, 0), p.used());
}

test "releasing memory that was never reserved is an error" {
    var p = Pool{ .size = 64 * page_size };
    defer p.deinit(testing.allocator);

    const start = try p.reserve(testing.allocator, 0, p.size, 2 * page_size, page_size, .wb_onion);
    // Claiming memory it does not own is worth reporting rather than ignoring.
    try testing.expectError(
        PoolError.NotReserved,
        p.release(testing.allocator, start + 8 * page_size, page_size),
    );
    try testing.expectEqual(@as(u64, 2 * page_size), p.used());
}

test "released ranges become available again" {
    var p = Pool{ .size = 4 * page_size };
    defer p.deinit(testing.allocator);

    const start = try p.reserve(testing.allocator, 0, p.size, 4 * page_size, page_size, .wb_onion);
    try p.release(testing.allocator, start, 4 * page_size);

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

test "physical memory is handed back in whatever pieces the title chooses" {
    // A title takes a large region once and returns parts of it as it finishes
    // with them. Refusing a release that is not exactly an acquisition leaves
    // every one of those failing, and a title whose releases all fail exhausts
    // the pool and then dereferences the failure.
    init(testing.allocator);
    defer deinit();

    var start: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateDirectMemory(0, direct_memory_size, 8 * page_size, page_size, 0, &start),
    );
    try testing.expectEqual(@as(u64, 8 * page_size), pool.used());

    // The front of it.
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(start, 2 * page_size));
    try testing.expectEqual(@as(u64, 6 * page_size), pool.used());

    // A piece out of the middle, leaving a hole.
    try testing.expectEqual(
        errno.ok,
        sceKernelReleaseDirectMemory(start + 4 * page_size, page_size),
    );
    try testing.expectEqual(@as(u64, 5 * page_size), pool.used());

    // And the rest, in one span that covers what is left on both sides of the
    // hole as well as ground already released.
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(start, 8 * page_size));
    try testing.expectEqual(@as(u64, 0), pool.used());
}

test "a release still has to name memory the title owns" {
    init(testing.allocator);
    defer deinit();

    var start: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateDirectMemory(0, direct_memory_size, 4 * page_size, page_size, 0, &start),
    );

    // Past everything reserved: the title believes it owns memory it does not.
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelReleaseDirectMemory(start + 64 * page_size, page_size),
    );

    // Sizes and offsets that no allocation could have produced.
    try testing.expectEqual(KernelError.einval.raw(), sceKernelReleaseDirectMemory(start, 0));
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelReleaseDirectMemory(start + 1, page_size),
    );
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelReleaseDirectMemory(start, page_size + 1),
    );
    try testing.expectEqual(@as(u64, 4 * page_size), pool.used());
}

test "the exhaustion a leaked release causes does not return" {
    // The shape of the failure that motivated this: a title probes how much
    // memory it can get by taking a region, handing it back, and asking for
    // twice as much. If the hand-back does not take, the probe runs out.
    init(testing.allocator);
    defer deinit();

    var size: u64 = page_size;
    while (size <= direct_memory_size / 2) : (size *= 2) {
        var start: u64 = 0;
        try testing.expectEqual(
            errno.ok,
            sceKernelAllocateDirectMemory(0, direct_memory_size, size, page_size, 0, &start),
        );
        try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(start, size));
        try testing.expectEqual(@as(u64, 0), pool.used());
    }
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

test "the two kinds of memory are cut from one supply" {
    // Reporting them independently promises more than the console has, and a
    // title sizes its allocators from both answers during startup.
    try testing.expectEqual(total_memory_size, direct_memory_size + flexible_memory_size);
    try testing.expect(direct_memory_size < total_memory_size);
    try testing.expect(flexible_memory_size < total_memory_size);
    try testing.expectEqual(direct_memory_size, pool.size);
}

test "walking physical memory ends rather than inventing a last region" {
    // A title walks its physical reservations to learn what it owns. Answering
    // the step past the end with success and an empty region at the top of the
    // pool describes a region that does not exist, and the title records it.
    // The virtual-address walk ends with an error in exactly this situation and
    // titles handle it.
    init(testing.allocator);
    defer deinit();

    var start: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateDirectMemory(0, direct_memory_size, 2 * page_size, page_size, 0, &start),
    );

    var info = DirectMemoryQueryInfo{};
    const size = @sizeOf(DirectMemoryQueryInfo);
    try testing.expectEqual(errno.ok, sceKernelDirectMemoryQuery(0, 1, &info, size));
    try testing.expectEqual(@as(i64, @intCast(start)), info.start);

    // One past the only reservation, with plenty of pool left above it.
    const past: i64 = @intCast(start + 2 * page_size);
    try testing.expect(@as(u64, @intCast(past)) < direct_memory_size);
    try testing.expectEqual(
        KernelError.eacces.raw(),
        sceKernelDirectMemoryQuery(past, 1, &info, size),
    );
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
    const title_protection = prot_cpu_read | prot_cpu_write | prot_gpu_read | prot_gpu_write |
        prot_ampr_read | prot_ampr_write;

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

    try address_space.reserveFixed(virtual_address, page_size);
    try testing.expectEqual(
        memory.MappingKind.reserved,
        address_space.query(virtual_address, false).?.kind,
    );
    const reserved_address = virtual_address;
    try testing.expectEqual(
        KernelError.enomem.raw(),
        sceKernelMapDirectMemory(
            &virtual_address,
            page_size,
            title_protection,
            @bitCast(@as(u32, @intCast(map_fixed)) | map_no_overwrite),
            start,
            0,
        ),
    );
    try testing.expectEqual(@as(u64, 0), virtual_address);
    try testing.expectEqual(
        memory.MappingKind.reserved,
        address_space.query(reserved_address, false).?.kind,
    );
    virtual_address = reserved_address;

    try testing.expectEqual(
        errno.ok,
        sceKernelMapDirectMemory(
            &virtual_address,
            page_size,
            title_protection,
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
            title_protection,
            map_fixed,
            start,
            0,
        ),
    );
    try address_space.read(alias, &bytes);
    try testing.expectEqualStrings("direct", &bytes);

    var direct_info = VirtualQueryInfo{};
    try testing.expectEqual(
        errno.ok,
        sceKernelVirtualQuery(alias, 0, &direct_info, @sizeOf(VirtualQueryInfo)),
    );
    try testing.expectEqual(@as(u32, 0x12), direct_info.state);
    try testing.expectEqual(start, direct_info.offset);
    try testing.expectEqual(@as(i32, 0), direct_info.memory_type);
    try testing.expectEqual(title_protection, direct_info.protection);

    try testing.expectEqual(errno.ok, sceKernelMunmap(virtual_address, page_size));
    try testing.expectEqual(errno.ok, sceKernelMunmap(alias, page_size));
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(start, page_size));
}

test "direct memory preserves a graphics device-window address without MAP_FIXED" {
    var address_space = try memory.AddressSpace.initWithDirectMemory(
        testing.allocator,
        direct_memory_size,
    );
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    const graphics_pool_size: u64 = 0x20_0000;
    var physical: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateDirectMemory(
            0,
            direct_memory_size,
            graphics_pool_size,
            graphics_pool_size,
            0,
            &physical,
        ),
    );

    var mapped = memory.device.start;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapDirectMemory(
            &mapped,
            graphics_pool_size,
            prot_cpu_read | prot_cpu_write | prot_gpu_read | prot_gpu_write,
            0,
            physical,
            graphics_pool_size,
        ),
    );
    try testing.expectEqual(memory.device.start, mapped);
    try testing.expect(address_space.isMappedAs(mapped, graphics_pool_size, .direct_memory));
    try testing.expect(address_space.isMapped(mapped + 0x40_000, page_size));
}

test "a window onto physical memory does not outlive it" {
    // A title hands physical memory back without closing its windows first, and
    // firmware takes them down for it. Refusing the release while a mapping
    // exists fails every hand-back a title makes; leaving the mapping behind
    // would let the pool reissue those offsets while a stale alias still
    // reaches them, which is how an address space corrupts a title invisibly.
    var address_space = try memory.AddressSpace.initWithDirectMemory(
        testing.allocator,
        direct_memory_size,
    );
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    const title_protection = prot_cpu_read | prot_cpu_write;

    var start: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateDirectMemory(0, direct_memory_size, 2 * page_size, page_size, 0, &start),
    );

    var first = memory.user.start;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapDirectMemory(&first, page_size, title_protection, map_fixed, start, 0),
    );
    var second = memory.user.start + page_size;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapDirectMemory(&second, page_size, title_protection, map_fixed, start, 0),
    );
    try testing.expect(address_space.isMappedAs(first, page_size, .direct_memory));
    try testing.expect(address_space.isMappedAs(second, page_size, .direct_memory));

    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(start, 2 * page_size));

    // Both windows are gone, and so is the reservation behind them.
    try testing.expect(address_space.query(first, false) == null);
    try testing.expect(address_space.query(second, false) == null);
    try testing.expectEqual(@as(u64, 0), pool.used());

    // Releasing memory the title does not own still fails, and takes nothing
    // down on its way to saying so.
    var other: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateDirectMemory(0, direct_memory_size, page_size, page_size, 0, &other),
    );
    var kept = memory.user.start;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapDirectMemory(&kept, page_size, title_protection, map_fixed, other, 0),
    );
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelReleaseDirectMemory(other + 32 * page_size, page_size),
    );
    try testing.expect(address_space.isMappedAs(kept, page_size, .direct_memory));
}

test "direct memory maps into part of a larger reservation" {
    var address_space = try memory.AddressSpace.initWithDirectMemory(
        testing.allocator,
        direct_memory_size,
    );
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    // The sequence a title actually performs: reserve a window, allocate
    // physical memory, then map the memory into part of that window. Mapping
    // into a reservation is what reserving is for, and the mapped length is
    // routinely smaller than the reservation.
    const reservation_size: u64 = 0x80_0000;
    const map_size: u64 = 0x40_0000;
    const alignment: u64 = 0x4_0000;

    var reserved: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelReserveVirtualRange(&reserved, reservation_size, 0, alignment),
    );
    try testing.expect(reserved != 0);

    var physical: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateMainDirectMemory(map_size, alignment, 0, &physical),
    );

    const title_protection = prot_cpu_read | prot_cpu_write | prot_gpu_read | prot_gpu_write;
    var mapped = reserved;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapDirectMemory(&mapped, map_size, title_protection, map_fixed, physical, 0),
    );
    try testing.expectEqual(reserved, mapped);
    try testing.expect(address_space.isMappedAs(mapped, map_size, .direct_memory));

    // The rest of the reservation must survive: the title still owns it and
    // fills it in later.
    const tail = reserved + map_size;
    try testing.expectEqual(
        memory.MappingKind.reserved,
        address_space.query(tail, false).?.kind,
    );

    var second: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateMainDirectMemory(map_size, alignment, 0, &second),
    );
    var tail_mapped = tail;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapDirectMemory(&tail_mapped, map_size, title_protection, map_fixed, second, 0),
    );
    try testing.expectEqual(tail, tail_mapped);
    try testing.expect(address_space.isMappedAs(tail_mapped, map_size, .direct_memory));
}

test "large hinted user reservation leaves room for a later window" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    // Unreal's libc bootstrap reserves a large arena at the native user-area
    // boundary and then searches from the same hint for a much smaller window.
    const arena_size: u64 = 0x80_0000_0000;
    var arena = memory.user.start;
    try testing.expectEqual(
        errno.ok,
        sceKernelReserveVirtualRange(&arena, arena_size, 0, 0x20_0000),
    );
    // The test executable itself may occupy a high-entropy-ASLR hole in the
    // guest window. AddressSpace must choose the first owned extent large
    // enough, which need not begin at the architectural boundary.
    try testing.expect(arena >= memory.user.start);
    try testing.expectEqual(@as(u64, 0), arena % 0x20_0000);
    try testing.expect(arena + arena_size <= memory.user.end);

    const window_size: u64 = 0x400_0000;
    var window = memory.user.start;
    try testing.expectEqual(
        errno.ok,
        sceKernelReserveVirtualRange(&window, window_size, 0, page_size),
    );
    // If ASLR split the architectural range, the smaller allocation may fit
    // in the free extent before the arena instead of after it.  What matters
    // is that both reservations coexist without overlap.
    try testing.expect(window + window_size <= arena or window >= arena + arena_size);
}

test "large unhinted reservation is placed in the user window" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    var arena: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelReserveVirtualRange(&arena, 0x80_0000_0000, 0, 0x20_0000),
    );
    try testing.expect(arena >= memory.user.start);
    try testing.expectEqual(@as(u64, 0), arena % 0x20_0000);
    try testing.expect(arena + 0x80_0000_0000 <= memory.user.end);
}

test "fixed flexible memory commits a slice without consuming its reservation" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    const reservation_size = 4 * page_size;
    var reservation: u64 = memory.user.start;
    try testing.expectEqual(
        errno.ok,
        sceKernelReserveVirtualRange(&reservation, reservation_size, 0, page_size),
    );

    const mapped_address = reservation + page_size;
    var mapped = mapped_address;
    try testing.expectEqual(
        errno.ok,
        sceKernelMapFlexibleMemory(
            &mapped,
            2 * page_size,
            prot_cpu_read | prot_cpu_write,
            map_fixed,
        ),
    );
    try testing.expectEqual(mapped_address, mapped);
    try testing.expect(address_space.isMappedAs(mapped, 2 * page_size, .flexible));
    try testing.expectEqual(
        memory.MappingKind.reserved,
        address_space.query(reservation, false).?.kind,
    );
    try testing.expectEqual(
        memory.MappingKind.reserved,
        address_space.query(reservation + 3 * page_size, false).?.kind,
    );

    try address_space.write(mapped, "committed");
    var bytes: [9]u8 = undefined;
    try address_space.read(mapped, &bytes);
    try testing.expectEqualStrings("committed", &bytes);
}

test "a query reports what a range is and whether it is committed" {
    var address_space = try memory.AddressSpace.initWithDirectMemory(
        testing.allocator,
        direct_memory_size,
    );
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    // The guest reads this field as a bitfield, so a range is of some type and
    // committed at the same time; reporting only one of the two misleads a
    // runtime that checks either.
    const base = memory.system_managed.start;
    try address_space.mapFixed(base, page_size, memory.Protection.read_write, .stack, null);

    var info = VirtualQueryInfo{};
    try testing.expectEqual(
        errno.ok,
        sceKernelVirtualQuery(base, 0, &info, @sizeOf(VirtualQueryInfo)),
    );
    try testing.expect(info.state & state_stack != 0);
    try testing.expect(info.state & state_committed != 0);
    try testing.expect(info.state & state_direct == 0);

    // A reservation claims addresses and nothing else: no type, not committed.
    const reserved_base = base + 0x10_0000;
    try address_space.reserveFixed(reserved_base, page_size);
    try testing.expectEqual(
        errno.ok,
        sceKernelVirtualQuery(reserved_base, 0, &info, @sizeOf(VirtualQueryInfo)),
    );
    try testing.expectEqual(@as(u32, 0), info.state);
    try testing.expectEqual(reserved_base, info.start);
    try testing.expectEqual(reserved_base + page_size, info.end);
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

test "the graphics device exposes its shared compatibility aperture" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    filesystem.detach();
    const descriptor = try filesystem.open("/dev/gc", filesystem.O.rdwr);
    defer filesystem.close(descriptor) catch {};

    const requested: u64 = 0xfe02_00000;
    const result = mmap(
        requested,
        page_size,
        prot_cpu_write | prot_gpu_write,
        posix_map_shared,
        descriptor,
        0,
    );
    try testing.expect(result != -1);
    const mapped: u64 = @bitCast(result);
    try testing.expectEqual(requested, mapped);
    try testing.expect(address_space.isMappedAs(mapped, page_size, .flexible));

    var info = VirtualQueryInfo{};
    try testing.expectEqual(
        errno.ok,
        sceKernelVirtualQuery(mapped, 0, &info, @sizeOf(VirtualQueryInfo)),
    );
    try testing.expectEqualStrings("/dev/gc", std.mem.sliceTo(&info.name, 0));

    try testing.expectEqual(
        @as(i64, -1),
        mmap(requested, page_size, prot_cpu_write, posix_map_shared, descriptor, 1),
    );
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
