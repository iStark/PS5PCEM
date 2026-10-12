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
const gpu = @import("gpu");
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

/// Pool operations hold this across host mapping calls. Readability checks
/// must wait for those changes, but should not burn CPU cores while waiting.
const Lock = memory.HostMutex;

/// Physical memory is handed out in 16 KiB units.
pub const page_size: u64 = 16 * 1024;

/// All the memory a title may have, of either kind.
///
/// A little under 13.5 GiB, which is what the console leaves to a title after
/// the system takes its share.
pub const total_memory_size: u64 = 13824 * 1024 * 1024;

/// Default flexible-memory budget when system content does not override it.
///
/// Retail titles that omit `kernel.flexibleMemorySize` receive a 1 GiB pool.
/// Treating the default as 4 GiB removes 3 GiB from direct memory; newer SDKs
/// subtract their fixed arenas from `sceKernelGetDirectMemorySize`, so the
/// wrong answer can underflow their final allocation size.
pub const flexible_memory_size: u64 = 1 * 1024 * 1024 * 1024;

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
    pooled: bool = false,

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
    // Sorted, non-overlapping intervals. Reusing a lower hole inserts in place;
    // allocation must not restart an unordered scan for every occupied range.
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
        const index = self.firstEndingAfter(addr);
        if (index == self.reservations.items.len) return null;
        const r = &self.reservations.items[index];
        return if (r.start <= addr) r else null;
    }

    pub fn findContainingRange(self: *const Pool, start: u64, len: u64) ?*const Reservation {
        if (len == 0) return null;
        const end = std.math.add(u64, start, len) catch return null;
        const r = self.findContaining(start) orelse return null;
        return if (end <= r.end()) r else null;
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

    fn firstEndingAfter(self: *const Pool, address: u64) usize {
        var low: usize = 0;
        var high = self.reservations.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.reservations.items[middle].end() <= address) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low;
    }

    fn alignedCandidate(start: u64, step: u64) ?u64 {
        const rounded = std.math.add(u64, start, step - 1) catch return null;
        return std.mem.alignBackward(u64, rounded, step);
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

        const limit = @min(search_end, self.size);
        var candidate = alignedCandidate(search_start, step) orelse return error.OutOfDirectMemory;
        if (candidate > limit or len > limit - candidate) return error.OutOfDirectMemory;
        var index = self.firstEndingAfter(candidate);
        while (index < self.reservations.items.len) : (index += 1) {
            const occupied = self.reservations.items[index];
            if (occupied.start >= candidate + len) break;
            if (occupied.end() <= candidate) continue;
            candidate = alignedCandidate(occupied.end(), step) orelse return error.OutOfDirectMemory;
            if (candidate > limit or len > limit - candidate) return error.OutOfDirectMemory;
        }
        try self.reservations.insert(gpa, index, .{
            .start = candidate,
            .len = len,
            .alignment = alignment,
            .memory_type = memory_type,
        });
        return candidate;
    }

    /// Largest run of unreserved memory inside a search window, as the guest
    /// would receive it: aligned up to `alignment`, and clipped to the pool.
    ///
    /// Walk free intervals, not pages. The result still names one allocatable
    /// run, with the lowest address winning ties, rather than summing holes.
    pub fn largestFree(
        self: *const Pool,
        search_start: u64,
        search_end: u64,
        alignment: u64,
    ) ?struct { start: u64, len: u64 } {
        const step = @max(alignment, page_size);
        const limit = @min(search_end, self.size);
        var best_start: u64 = 0;
        var best_len: u64 = 0;

        var candidate = alignedCandidate(search_start, step) orelse return null;
        var index = self.firstEndingAfter(candidate);
        while (candidate < limit) : (index += 1) {
            const occupied: ?Reservation = if (index < self.reservations.items.len and
                self.reservations.items[index].start < limit) self.reservations.items[index] else null;
            if (occupied) |reservation| {
                if (reservation.end() <= candidate) continue;
            }
            const free_end = if (occupied) |reservation| reservation.start else limit;
            if (free_end > candidate) {
                // A partial final page cannot be reserved within the window.
                const run_len = std.mem.alignBackward(u64, free_end - candidate, page_size);
                if (run_len > best_len) {
                    best_start = candidate;
                    best_len = run_len;
                }
            }
            const reservation = occupied orelse break;
            candidate = alignedCandidate(reservation.end(), step) orelse break;
        }
        if (best_len == 0) return null;
        return .{ .start = best_start, .len = best_len };
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
        try self.reservations.ensureUnusedCapacity(gpa, 1);
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
                    .pooled = reservation.pooled,
                });
                index += 1;
            }
            if (overlap_end < reservation.end()) {
                try self.reservations.insert(gpa, index, .{
                    .start = overlap_end,
                    .len = reservation.end() - overlap_end,
                    .alignment = reservation.alignment,
                    .memory_type = reservation.memory_type,
                    .pooled = reservation.pooled,
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
var map_place_ns: u64 = 0;
var map_metadata_ns: u64 = 0;
var map_lock_ns: u64 = 0;
var guest_address_space: ?*memory.AddressSpace = null;

const pool_block_size: u64 = 0x10000;
const pool_reserve_alignment: u64 = 0x200000;
const PoolBlock = struct { physical: u64, address: u64 = 0 };
// A zero VA is a free donated block. Commit/decommit never allocate bookkeeping
// for these blocks, which also makes rollback independent of allocator failure.
var pool_blocks: std.ArrayList(PoolBlock) = .empty;
var pool_available_blocks: usize = 0;
var has_memory_pool_reservations = false;

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
    // Published atomically so read-only accessibility queries can observe the
    // attachment without joining the pool's contention. Attach and detach
    // happen once each, around the guest's whole lifetime.
    @atomicStore(?*memory.AddressSpace, &guest_address_space, address_space, .release);
    filesystem.attachGuestAddressSpace(address_space);
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
/// Reports every other virtual address that reaches the same direct memory.
///
/// A title can map one direct-memory allocation twice: once for the CPU to
/// fill and once for the GPU to read. Anything written through one address is
/// then invisible through the other unless both name the same host pages, and
/// the difference looks exactly like a producer that never ran.
pub fn reportDirectMemoryAliases(label: []const u8, address: u64) void {
    const address_space = guest_address_space orelse return;
    const owning = address_space.query(address, false) orelse {
        std.debug.print("[memory] {s} @0x{x} is not mapped" ++ "\n", .{ label, address });
        return;
    };
    const backing = owning.backing_offset orelse {
        std.debug.print(
            "[memory] {s} @0x{x} is {s}, not direct memory" ++ "\n",
            .{ label, address, @tagName(owning.kind) },
        );
        return;
    };
    const offset = backing + (address - owning.address);
    const mappings = address_space.snapshot(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(mappings);
    var aliases: usize = 0;
    for (mappings) |mapping| {
        const other = mapping.backing_offset orelse continue;
        if (offset < other or offset >= other + mapping.size) continue;
        const alias = mapping.address + (offset - other);
        if (alias == address) continue;
        aliases += 1;
        std.debug.print(
            "[memory] {s} @0x{x} also mapped at 0x{x} (direct offset 0x{x})" ++ "\n",
            .{ label, address, alias, offset },
        );
    }
    if (aliases == 0) {
        std.debug.print(
            "[memory] {s} @0x{x} has one mapping only (direct offset 0x{x})" ++ "\n",
            .{ label, address, offset },
        );
    }
}

pub fn attachedAddressSpace() ?*memory.AddressSpace {
    return @atomicLoad(?*memory.AddressSpace, &guest_address_space, .acquire);
}

pub fn isGuestRangeAccessible(address: u64, length: u64) bool {
    if (length == 0) return true;
    if (address == 0) return false;
    _ = std.math.add(u64, address, length) catch return false;

    // The pool lock guards the pool's own bookkeeping, none of which is read
    // here; AddressSpace carries the lock for the interval table this asks
    // about. Holding both put every firmware call that validates a guest
    // pointer behind every direct-memory operation, and a title reaches this
    // from scePthreadMutexLock alone hundreds of thousands of times in ten
    // seconds. Publishing the attachment atomically leaves that query
    // serialised only against the table it actually reads.
    const address_space = @atomicLoad(?*memory.AddressSpace, &guest_address_space, .acquire) orelse return true;
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

/// True when the range sits inside a guest thread stack mapping.
///
/// AGC builders sometimes record a few packets into stack scratch rather than
/// a GPU command arena. Those bottoms must not be treated as stranded DCBs.
pub fn isGuestStackRange(address: u64, length: u64) bool {
    if (address == 0 or length == 0) return false;
    const end = std.math.add(u64, address, length) catch return false;

    pool_lock.lock();
    defer pool_lock.unlock();
    const address_space = guest_address_space orelse return false;
    const mapping = address_space.query(address, false) orelse return false;
    return mapping.kind == .stack and end <= mapping.end();
}

pub fn deinit() void {
    pool_lock.lock();
    defer pool_lock.unlock();
    if (pool_gpa) |gpa| {
        pool.deinit(gpa);
        pool_blocks.deinit(gpa);
    }
    pool_blocks = .empty;
    pool_available_blocks = 0;
    has_memory_pool_reservations = false;
    pool = .{};
    pool_gpa = null;
    guest_address_space = null;
    filesystem.attachGuestAddressSpace(null);
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
    const end = std.math.add(u64, start, len) catch return KernelError.einval.raw();
    for (pool_blocks.items) |block| {
        if (block.physical >= end or block.physical + pool_block_size <= start) continue;
        if (block.address != 0) return KernelError.eacces.raw();
        if (start % pool_block_size != 0 or len % pool_block_size != 0) return KernelError.einval.raw();
    }
    // Ordered before the unmapping so that a range owning nothing is refused
    // without having taken anything down on the way to saying so.
    if (!pool.hasAnyReservation(start, len)) return KernelError.einval.raw();
    const gpa = pool_gpa orelse return KernelError.enomem.raw();
    pool.reservations.ensureUnusedCapacity(gpa, 1) catch return KernelError.enomem.raw();
    if (guest_address_space) |address_space| {
        _ = address_space.unmapDirectMemoryBacking(start, len);
        // A native view can reject a partial unmap. Keep physical ownership
        // in that case rather than recycling pages that remain guest-visible.
        if (address_space.hasDirectMemoryMappings(start, len)) return KernelError.eacces.raw();
    }
    pool.release(gpa, start, len) catch |err| return switch (err) {
        error.NotReserved => KernelError.einval.raw(),
        else => KernelError.enomem.raw(),
    };
    var retained: usize = 0;
    for (pool_blocks.items) |block| {
        if (block.physical >= start and block.physical < end) {
            pool_available_blocks -= 1;
        } else {
            pool_blocks.items[retained] = block;
            retained += 1;
        }
    }
    pool_blocks.items.len = retained;
    return errno.ok;
}

/// Largest allocatable run in a search window, with where it begins.
///
/// Titles call this to size a pool before reserving it, so answering with the
/// total free bytes would promise a single allocation that fragmentation
/// cannot satisfy. Report the largest contiguous run instead.
fn sceKernelAvailableDirectMemorySize(
    search_start: u64,
    search_end: u64,
    alignment: u64,
    out_start: ?*u64,
    out_size: ?*u64,
) callconv(abi.guest) i32 {
    if (out_start == null or out_size == null) return KernelError.efault.raw();
    if (alignment != 0 and !std.math.isPowerOfTwo(alignment)) return KernelError.einval.raw();
    if (search_end <= search_start) return KernelError.einval.raw();

    pool_lock.lock();
    defer pool_lock.unlock();

    const found = pool.largestFree(search_start, search_end, alignment) orelse
        return KernelError.eagain.raw();
    out_start.?.* = found.start;
    out_size.?.* = found.len;
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
const large_semantic_reservation_minimum: u64 = 0x40_0000_0000;
const large_semantic_reservation_alignment: u64 = 0x1_0000_0000;
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
    return mapDirectMemory(
        out_address,
        len,
        protection_bits,
        flags,
        physical_address,
        alignment,
        null,
    );
}

fn mapDirectMemory(
    out_address: ?*u64,
    len: u64,
    protection_bits: i32,
    flags: i32,
    physical_address: u64,
    alignment: u64,
    untracked_memory_type: ?i32,
) i32 {
    if (len == 0 or len % page_size != 0) return KernelError.einval.raw();
    if (physical_address % page_size != 0) return KernelError.einval.raw();
    const effective_alignment = @max(alignment, page_size);
    if (!std.math.isPowerOfTwo(effective_alignment)) return KernelError.einval.raw();
    const map_flags: u32 = @bitCast(flags);

    const lock_started = gpu.frame_timing.timestampNs();
    pool_lock.lock();
    map_lock_ns +%= gpu.frame_timing.elapsedNs(lock_started);
    defer pool_lock.unlock();

    // Donated memory is owned by MemoryPool, including when the legacy batch
    // mapping fallback accepts otherwise untracked direct allocations.
    _ = std.math.add(u64, physical_address, len) catch return KernelError.einval.raw();
    if (pool_blocks.items.len != 0) for (pool.reservations.items) |reservation| {
        if (reservation.pooled and reservation.overlaps(physical_address, len)) return KernelError.eacces.raw();
    };
    const memory_type: i32 = if (pool.findContainingRange(physical_address, len)) |reservation|
        @intFromEnum(reservation.memory_type)
    else untracked: {
        const fallback = untracked_memory_type orelse return KernelError.einval.raw();
        if (physical_address > pool.size or len > pool.size - physical_address) {
            return KernelError.einval.raw();
        }
        break :untracked fallback;
    };
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
    const place_started = gpu.frame_timing.timestampNs();
    const mapped_address = if (explicit_fixed or device_request) fixed: {
        if (requested_address == 0 or requested_address % effective_alignment != 0) {
            return KernelError.einval.raw();
        }
        if (has_memory_pool_reservations and address_space.hasPooledMappings(requested_address, len)) return KernelError.eacces.raw();
        const occupied = address_space.isMapped(requested_address, len);
        if (occupied and (!explicit_fixed or map_flags & map_no_overwrite != 0)) {
            return KernelError.enomem.raw();
        }
        // Rebinding the same complete physical range with the same access
        // permissions changes no pages. Keep its host views and GPU tracking;
        // no-overwrite requests have already retained their failure semantics.
        if (occupied and address_space.matchesDirectMemoryMapping(requested_address, len, physical_address, protection)) {
            break :fixed requested_address;
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

    map_place_ns +%= gpu.frame_timing.elapsedNs(place_started);
    const metadata_started = gpu.frame_timing.timestampNs();
    defer map_metadata_ns +%= gpu.frame_timing.elapsedNs(metadata_started);

    address_space.setMetadata(mapped_address, len, .{
        .protection_bits = protection_bits,
        .memory_type = memory_type,
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
        if (has_memory_pool_reservations and address_space.hasPooledMappings(requested_address, len)) return KernelError.eacces.raw();

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

fn posixMemoryFailure(number: i32) i32 {
    runtime_api.setPosixErrno(number);
    return -1;
}

/// POSIX lengths cover every touched guest page, but the starting address
/// must already be aligned. Reject overflow before changing any mappings.
fn posixMemoryLength(address: u64, len: u64) ?u64 {
    if (address % page_size != 0) return null;
    const rounded = (std.math.add(u64, len, page_size - 1) catch return null) & ~(page_size - 1);
    _ = std.math.add(u64, address, rounded) catch return null;
    return rounded;
}

fn mprotect(address: u64, len: u64, protection_bits: i32) callconv(abi.guest) i32 {
    const supported = posix_prot_read | posix_prot_write | posix_prot_exec;
    if (protection_bits & ~supported != 0) return posixMemoryFailure(errno.Posix.einval);
    const rounded = posixMemoryLength(address, len) orelse return posixMemoryFailure(errno.Posix.einval);
    if (rounded == 0) return 0;
    const protection = memory.Protection{
        .read = protection_bits & posix_prot_read != 0,
        .write = protection_bits & posix_prot_write != 0,
        .execute = protection_bits & posix_prot_exec != 0,
    };
    pool_lock.lock();
    defer pool_lock.unlock();
    const space = guest_address_space orelse return posixMemoryFailure(errno.Posix.enosys);
    space.protectGuest(address, rounded, protection, protection.guestBits()) catch |err|
        return posixMemoryFailure(if (err == error.RangeNotMapped)
            errno.Posix.enomem
        else
            errno.kernelToPosix(mapAddressSpaceError(err)));
    return 0;
}

fn munmap(address: u64, len: u64) callconv(abi.guest) i32 {
    if (len == 0) return posixMemoryFailure(errno.Posix.einval);
    const rounded = posixMemoryLength(address, len) orelse return posixMemoryFailure(errno.Posix.einval);
    const end = address + rounded;
    pool_lock.lock();
    defer pool_lock.unlock();
    const space = guest_address_space orelse return posixMemoryFailure(errno.Posix.enosys);
    if (has_memory_pool_reservations and space.hasPooledMappings(address, rounded) and
        (address % pool_block_size != 0 or rounded % pool_block_size != 0))
        return posixMemoryFailure(errno.Posix.einval);

    // POSIX permits holes and repeated unmaps. Remove each contiguous mapped
    // run, retaining adjacent protection splits in the same host transaction.
    var cursor = address;
    while (cursor < end) {
        const first = space.query(cursor, true) orelse break;
        if (first.address >= end) break;
        const start = @max(cursor, first.address);
        var stop = @min(end, first.end());
        while (stop < end) {
            const next = space.query(stop, true) orelse break;
            if (next.address != stop) break;
            stop = @min(end, next.end());
        }
        space.unmap(start, stop - start) catch |err|
            return posixMemoryFailure(errno.kernelToPosix(mapAddressSpaceError(err)));
        returnPoolBlocks(start, stop - start);
        cursor = stop;
    }
    return 0;
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
/// Length of the maximal run starting at `entries[0]` whose members are
/// adjacent in guest address and agree on operation, protection and memory
/// type. Only direct mappings consume the physical offset; unmap and protect
/// entries commonly leave that unused field zero on every slice.
fn contiguousRun(entries: []const BatchMapEntry) usize {
    if (entries.len == 0) return 0;
    const first = entries[0];
    if (first.length == 0 or first.operation < @intFromEnum(BatchOperation.map_direct) or
        first.operation > @intFromEnum(BatchOperation.type_protect)) return 1;
    const needs_offset = first.operation == @intFromEnum(BatchOperation.map_direct);
    const needs_page_alignment = needs_offset or first.operation == @intFromEnum(BatchOperation.unmap);
    if (needs_page_alignment and (first.start % page_size != 0 or first.length % page_size != 0 or
        (needs_offset and first.offset % page_size != 0))) return 1;
    var length: usize = 1;
    while (length < entries.len) : (length += 1) {
        const last = entries[length - 1];
        const next = entries[length];
        if (last.operation != next.operation or last.protection != next.protection or
            last.memory_type != next.memory_type or next.length == 0) break;
        // Combining invalid slices must not turn an invalid individual entry
        // into a valid page-aligned operation or hide its processed count.
        if (needs_page_alignment and (next.start % page_size != 0 or next.length % page_size != 0 or
            (needs_offset and next.offset % page_size != 0))) break;
        const start_end = std.math.add(u64, last.start, last.length) catch break;
        if (start_end != next.start) break;
        if (needs_offset) {
            const offset_end = std.math.add(u64, last.offset, last.length) catch break;
            if (offset_end != next.offset) break;
        }
    }
    return length;
}

/// Applies a whole run as one host mapping, reporting whether it took.
///
/// Only the unambiguous operations are attempted. A chosen-address map writes
/// the address it picked back into its entry, which a combined call cannot do
/// for every member, so those are left to the per-entry path. A refusal here
/// costs one failed call and changes nothing: the underlying operations undo
/// their host work before returning an error.
fn applyMappingRun(entries: []BatchMapEntry, flags: i32) bool {
    const first = entries[0];
    var total: u64 = 0;
    for (entries) |member| total = std.math.add(u64, total, member.length) catch return false;
    if (total == 0) return false;
    const operation: BatchOperation = @enumFromInt(first.operation);
    const result = switch (operation) {
        .map_direct => direct: {
            if (first.start == 0 or flags & map_fixed == 0) return false;
            var address = first.start;
            break :direct sceKernelMapDirectMemory(&address, total, first.protection, flags, first.offset, 0);
        },
        .unmap => sceKernelMunmap(first.start, total),
        .protect, .type_protect => sceKernelMprotect(first.start, total, first.protection),
        .map_flexible => return false,
    };
    return result == errno.ok;
}

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

    // A batch is a handful of calls per frame, so timing the whole of one is
    // free, and a batch that runs for a large part of a frame is worth saying
    // out loud: the guest is stalled inside it for that whole time.
    const batch_started = gpu.frame_timing.timestampNs();
    var mapped_bytes: u64 = 0;
    const place_before = map_place_ns;
    const host_before = memory.hostMapNanoseconds();
    var runs: u32 = 0;
    var previous: ?BatchMapEntry = null;
    var coalesced_entries: u64 = 0;
    const metadata_before = map_metadata_ns;
    const lock_before = map_lock_ns;
    defer {
        const elapsed = gpu.frame_timing.elapsedNs(batch_started);
        if (elapsed >= 50 * std.time.ns_per_ms) std.debug.print(
            "[batch map] entries={d} mapped_kib={d} elapsed_ms={d} place_ms={d} host_ms={d} metadata_ms={d} lock_ms={d} intervals={d} runs={d} coalesced={d}\n",
            .{ count, mapped_bytes / 1024, elapsed / std.time.ns_per_ms, (map_place_ns -% place_before) / std.time.ns_per_ms, (memory.hostMapNanoseconds() -% host_before) / std.time.ns_per_ms, (map_metadata_ns -% metadata_before) / std.time.ns_per_ms, (map_lock_ns -% lock_before) / std.time.ns_per_ms, if (guest_address_space) |space| space.mappingCount() else 0, runs, coalesced_entries },
        );
    }

    var processed: i32 = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        // Windows charges per call, not per byte: a 128 KiB view costs about
        // four milliseconds once the process holds tens of thousands of
        // mappings, because each one splits a placeholder and shoots down
        // every thread's TLB. Titles stream assets as long runs of
        // adjacent slices, so issuing a run as one call is the same guest
        // state for a fraction of the host work. A run that will not take it
        // falls through to the per-entry path below, unchanged.
        const run = contiguousRun(entries[index..count]);
        if (run > 1 and applyMappingRun(entries[index..][0..run], flags)) {
            for (entries[index..][0..run]) |*member| mapped_bytes +|= member.length;
            runs += 1;
            previous = entries[index + run - 1];
            processed += @intCast(run);
            coalesced_entries +|= run;
            index += run - 1;
            continue;
        }
        const entry = &entries[index];
        {
            mapped_bytes +|= entry.length;
            // Count possible runs with the same operation-specific rules used
            // by the coalescing path, including ignored physical offsets.
            if (previous) |last| {
                if (contiguousRun(&.{ last, entry.* }) != 2) runs += 1;
            } else runs += 1;
            previous = entry.*;
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
            const requested_start = entry.start;
            var result = switch (operation) {
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
            // The graphics driver owns some physical ranges through its main
            // direct-memory arena even after the fine-grained allocation tracker
            // has released or split their bookkeeping nodes. BatchMap is the
            // driver's commit boundary, so accept an otherwise-valid in-pool
            // direct mapping and retain the entry's hardware memory type.
            if (result == KernelError.einval.raw() and operation == .map_direct) {
                result = mapDirectMemory(
                    &entry.start,
                    entry.length,
                    protection_bits,
                    flags,
                    entry.offset,
                    0,
                    entry.memory_type,
                );
                if (result == errno.ok) {
                    std.debug.print(
                        "[batch map {d}] accepted in-pool direct range absent from allocation tracker: offset=0x{x}+0x{x}\n",
                        .{ index, entry.offset, entry.length },
                    );
                }
            }
            // A zero start cannot name a fixed mapping. Some Unreal allocator paths
            // retain that sentinel when asking BatchMap to choose the virtual
            // address, even though the original entry point supplies MAP_FIXED.
            // Retry only that otherwise-impossible combination as a chosen-address
            // map; nonzero fixed mappings keep their strict replacement semantics.
            if (result == KernelError.einval.raw() and
                requested_start == 0 and
                flags & map_fixed != 0 and
                (operation == .map_direct or operation == .map_flexible))
            {
                const choose_address_flags = flags & ~map_fixed;
                result = switch (operation) {
                    .map_direct => mapDirectMemory(
                        &entry.start,
                        entry.length,
                        protection_bits,
                        choose_address_flags,
                        entry.offset,
                        0,
                        entry.memory_type,
                    ),
                    .map_flexible => mapFlexibleMemory(
                        &entry.start,
                        entry.length,
                        protection_bits,
                        choose_address_flags,
                        "batch",
                    ),
                    else => unreachable,
                };
                if (result == errno.ok) {
                    std.debug.print(
                        "[batch map {d}] selected address 0x{x} for zero-start {s} mapping\n",
                        .{ index, entry.start, @tagName(operation) },
                    );
                }
            }
            if (result != errno.ok) {
                std.debug.print(
                    "[batch map {d}] failed result=0x{x} op={s} start=0x{x}->0x{x} offset=0x{x} length=0x{x} prot=0x{x} type=0x{x} flags=0x{x}\n",
                    .{
                        index,
                        @as(u32, @bitCast(result)),
                        @tagName(operation),
                        requested_start,
                        entry.start,
                        entry.offset,
                        entry.length,
                        entry.protection,
                        entry.memory_type,
                        @as(u32, @bitCast(flags)),
                    },
                );
                if (processed_pointer) |output| output.* = processed;
                return result;
            }
            processed += 1;
        }
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
    if (has_memory_pool_reservations and address_space.hasPooledMappings(address, len) and
        (address % pool_block_size != 0 or len % pool_block_size != 0)) return KernelError.einval.raw();
    address_space.unmap(address, len) catch |err| return mapAddressSpaceError(err);
    returnPoolBlocks(address, len);
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
    info.offset = if (mapping.pooled) 0 else mapping.backing_offset orelse 0;
    info.protection = mapping.protection_bits;
    info.memory_type = mapping.memory_type;
    info.state = if (mapping.pooled)
        state_pooled | (if (mapping.kind == .reserved) @as(u32, 0) else state_committed)
    else switch (mapping.kind) {
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
    return reserveVirtualRange(out_address, len, flags, alignment, false);
}

fn reserveVirtualRange(out_address: ?*u64, len: u64, flags: i32, alignment: u64, pooled: bool) i32 {
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
            if (has_memory_pool_reservations and address_space.hasPooledMappings(requested_address, len)) return KernelError.eacces.raw();
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
        // Unreal derives arena metadata addresses by clearing the low 32 bits
        // of pointers inside its 256+ GiB virtual reservation. A merely
        // page-aligned fallback base can therefore produce an address just
        // below the reservation. Place such semantic arenas on a 4 GiB
        // boundary even when the guest requested only 2 MiB alignment.
        const placement_alignment = if (len >= large_semantic_reservation_minimum)
            @max(effective_alignment, large_semantic_reservation_alignment)
        else
            effective_alignment;
        const reserved = address_space.reserve(
            area,
            hint,
            len,
            placement_alignment,
        ) catch |err| {
            if (err == error.AddressUnavailable and
                area == .user and
                len >= large_semantic_reservation_minimum)
            {
                const spanning = address_space.reserveSpanningHostHoles(
                    area,
                    hint,
                    len,
                    placement_alignment,
                ) catch |fallback_err| {
                    if (trace.announces("sceKernelReserveVirtualRange")) {
                        std.debug.print(
                            "[virtual reserve] requested=0x{x} hint=0x{x} len=0x{x} align=0x{x} area={s} error={s} fallback={s}\n",
                            .{
                                requested_address,
                                hint,
                                len,
                                effective_alignment,
                                @tagName(area),
                                @errorName(err),
                                @errorName(fallback_err),
                            },
                        );
                        address_space.announceOwnedRanges(area);
                    }
                    return mapAddressSpaceError(fallback_err);
                };
                if (trace.announces("sceKernelReserveVirtualRange")) {
                    std.debug.print(
                        "[virtual reserve] semantic fallback addr=0x{x} len=0x{x} across host holes\n",
                        .{ spanning, len },
                    );
                }
                break :first_fit spanning;
            }
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
                address_space.announceOwnedRanges(area);
            }
            return mapAddressSpaceError(err);
        };
        break :first_fit reserved;
    };

    if (pooled) address_space.setMetadata(reserved_address, len, .{ .pooled = true }) catch |err| {
        address_space.unmap(reserved_address, len) catch {};
        return mapAddressSpaceError(err);
    };
    if (pooled) has_memory_pool_reservations = true;
    output.* = reserved_address;
    return errno.ok;
}

pub const MemoryPoolBlockStats = extern struct {
    available_flushed_blocks: i32 = 0,
    available_cached_blocks: i32 = 0,
    allocated_flushed_blocks: i32 = 0,
    allocated_cached_blocks: i32 = 0,
};

/// The payload is a 24-byte union: commit/protect use addr, len, prot, type;
/// move uses dst, src, len. Keep the union's full ABI size even for short ops.
pub const MemoryPoolBatchEntry = extern struct {
    operation: u32,
    flags: u32 = 0,
    address: u64,
    length: u64,
    protection: u8 = 0,
    memory_type: u8 = 0,
    padding: [6]u8 = .{0} ** 6,
};

comptime {
    std.debug.assert(@sizeOf(MemoryPoolBlockStats) == 16);
    std.debug.assert(@sizeOf(MemoryPoolBatchEntry) == 32);
    std.debug.assert(@offsetOf(MemoryPoolBatchEntry, "address") == 8);
    std.debug.assert(@offsetOf(MemoryPoolBatchEntry, "protection") == 24);
}

fn poolOutputWritable(address: u64, len: usize) bool {
    if (len == 0) return true;
    if (address == 0) return false;
    if (guest_address_space) |space| {
        if (space.isWritable(address, len)) return true;
    }
    return memory.isHostRangeWritable(address, len);
}

fn poolNotifyWrite(address: u64, len: usize) void {
    if (guest_address_space) |space| space.notifyGuestWrite(address, len);
}

fn sceKernelMemoryPoolExpand(search_start: i64, search_end: i64, len: u64, alignment: u64, out_physical: ?*u64) callconv(abi.guest) i32 {
    if (search_start < 0 or search_end <= search_start or len == 0 or len % pool_block_size != 0 or
        (alignment != 0 and (!std.math.isPowerOfTwo(alignment) or alignment % pool_block_size != 0))) return KernelError.einval.raw();
    const output = out_physical orelse return KernelError.einval.raw();
    if (!poolOutputWritable(@intFromPtr(output), @sizeOf(u64))) return KernelError.efault.raw();
    pool_lock.lock();
    defer pool_lock.unlock();
    const gpa = pool_gpa orelse return KernelError.enomem.raw();
    if (len > pool.size or len > @as(u64, @intCast(search_end - search_start))) return KernelError.enomem.raw();
    const count: usize = @intCast(len / pool_block_size);
    pool_blocks.ensureUnusedCapacity(gpa, count) catch return KernelError.enomem.raw();
    const physical = pool.reserve(gpa, @intCast(search_start), @intCast(search_end), len, @max(alignment, pool_block_size), .wb_onion) catch return KernelError.enomem.raw();
    pool.reservations.items[pool.firstEndingAfter(physical)].pooled = true;
    for (0..count) |index| pool_blocks.appendAssumeCapacity(.{ .physical = physical + index * pool_block_size });
    pool_available_blocks += count;
    poolNotifyWrite(@intFromPtr(output), @sizeOf(u64));
    output.* = physical;
    return errno.ok;
}

fn sceKernelMemoryPoolReserve(address: u64, len: u64, alignment: u64, flags: i32, out_address: ?*u64) callconv(abi.guest) i32 {
    const output = out_address orelse return KernelError.einval.raw();
    if (len == 0 or len % pool_reserve_alignment != 0 or
        (alignment != 0 and (!std.math.isPowerOfTwo(alignment) or alignment % pool_reserve_alignment != 0))) return KernelError.einval.raw();
    if (!poolOutputWritable(@intFromPtr(output), @sizeOf(u64))) return KernelError.efault.raw();
    var result = address;
    const status = reserveVirtualRange(&result, len, flags, @max(alignment, pool_reserve_alignment), true);
    if (status == errno.ok) {
        poolNotifyWrite(@intFromPtr(output), @sizeOf(u64));
        output.* = result;
    }
    return status;
}

fn sceKernelMemoryPoolCommit(address: u64, len: u64, memory_type: i32, protection_bits: i32, flags: i32) callconv(abi.guest) i32 {
    _ = flags;
    if (address == 0 or len == 0 or address % pool_block_size != 0 or len % pool_block_size != 0) return KernelError.einval.raw();
    _ = std.math.add(u64, address, len) catch return KernelError.einval.raw();
    if (protection_bits & prot_cpu_execute != 0) return KernelError.eacces.raw();
    const protection = decodeProtection(protection_bits) orelse return KernelError.einval.raw();
    pool_lock.lock();
    defer pool_lock.unlock();
    const space = guest_address_space orelse return KernelError.enosys.raw();
    const gpa = pool_gpa orelse return KernelError.enomem.raw();
    const count: usize = @intCast(len / pool_block_size);
    if (count > pool_available_blocks) return KernelError.enomem.raw();
    // Group adjacent free physical blocks; fragmented donations still form one
    // contiguous virtual commit. Publish block ownership only after host success.
    var backing: std.ArrayList(memory.PoolBacking) = .empty;
    defer backing.deinit(gpa);
    var selected: usize = 0;
    for (pool_blocks.items) |block| {
        if (block.address != 0) continue;
        if (backing.items.len != 0 and backing.items[backing.items.len - 1].offset + backing.items[backing.items.len - 1].size == block.physical) {
            backing.items[backing.items.len - 1].size += pool_block_size;
        } else backing.append(gpa, .{ .offset = block.physical, .size = pool_block_size }) catch return KernelError.enomem.raw();
        selected += 1;
        if (selected == count) break;
    }
    space.commitPooled(address, len, backing.items, protection, protection_bits, memory_type) catch |err| return mapAddressSpaceError(err);
    var cursor = address;
    for (pool_blocks.items) |*block| {
        if (block.address != 0) continue;
        block.address = cursor;
        cursor += pool_block_size;
        if (cursor == address + len) break;
    }
    pool_available_blocks -= count;
    return errno.ok;
}

fn returnPoolBlocks(address: u64, len: u64) void {
    for (pool_blocks.items) |*block| {
        if (block.address >= address and block.address < address + len and block.address != 0) {
            block.address = 0;
            pool_available_blocks += 1;
        }
    }
}

fn sceKernelMemoryPoolDecommit(address: u64, len: u64, flags: i32) callconv(abi.guest) i32 {
    _ = flags;
    if (address == 0 or len == 0 or address % pool_block_size != 0 or len % pool_block_size != 0) return KernelError.einval.raw();
    _ = std.math.add(u64, address, len) catch return KernelError.einval.raw();
    pool_lock.lock();
    defer pool_lock.unlock();
    const space = guest_address_space orelse return KernelError.enosys.raw();
    space.decommitPooled(address, len) catch |err| return mapAddressSpaceError(err);
    returnPoolBlocks(address, len);
    return errno.ok;
}

fn protectPoolEntry(entry: MemoryPoolBatchEntry, change_type: bool) i32 {
    if (entry.address == 0 or entry.length == 0 or entry.address % page_size != 0 or entry.length % page_size != 0) return KernelError.einval.raw();
    if (entry.protection & prot_cpu_execute != 0) return KernelError.eacces.raw();
    const protection = decodeProtection(entry.protection) orelse return KernelError.einval.raw();
    pool_lock.lock();
    defer pool_lock.unlock();
    const space = guest_address_space orelse return KernelError.enosys.raw();
    space.protectGuestWithType(entry.address, entry.length, protection, entry.protection, if (change_type) entry.memory_type else null) catch |err| return mapAddressSpaceError(err);
    return errno.ok;
}

fn sceKernelMemoryPoolBatch(entries_pointer: ?[*]align(1) const MemoryPoolBatchEntry, count: i32, processed_pointer: ?*i32, flags: i32) callconv(abi.guest) i32 {
    _ = flags;
    if (count < 0) return KernelError.einval.raw();
    const entries = entries_pointer orelse return KernelError.einval.raw();
    const bytes = @as(usize, @intCast(count)) * @sizeOf(MemoryPoolBatchEntry);
    if (bytes != 0 and !isGuestRangeAccessible(@intFromPtr(entries), bytes)) return KernelError.efault.raw();
    if (processed_pointer) |output| {
        if (!poolOutputWritable(@intFromPtr(output), @sizeOf(i32))) return KernelError.efault.raw();
        poolNotifyWrite(@intFromPtr(output), @sizeOf(i32));
    }
    var processed: i32 = 0;
    defer if (processed_pointer) |output| {
        output.* = processed;
    };
    while (processed < count) : (processed += 1) {
        const entry = entries[@intCast(processed)];
        const result = switch (entry.operation) {
            1 => sceKernelMemoryPoolCommit(entry.address, entry.length, entry.memory_type, entry.protection, @bitCast(entry.flags)),
            2 => sceKernelMemoryPoolDecommit(entry.address, entry.length, @bitCast(entry.flags)),
            3 => protectPoolEntry(entry, false),
            4 => protectPoolEntry(entry, true),
            // MOVE's contract is not established by the available reference.
            // Match its explicit EINVAL instead of reporting an unperformed move.
            else => KernelError.einval.raw(),
        };
        if (result != errno.ok) return result;
    }
    return errno.ok;
}

fn sceKernelMemoryPoolGetBlockStats(out_stats: ?*align(1) MemoryPoolBlockStats, output_size: u64) callconv(abi.guest) i32 {
    const len: usize = @intCast(@min(output_size, @sizeOf(MemoryPoolBlockStats)));
    if (len == 0) return errno.ok;
    const output = out_stats orelse return KernelError.efault.raw();
    if (!poolOutputWritable(@intFromPtr(output), len)) return KernelError.efault.raw();
    pool_lock.lock();
    defer pool_lock.unlock();
    const stats = MemoryPoolBlockStats{
        .available_flushed_blocks = @intCast(pool_available_blocks),
        .allocated_flushed_blocks = @intCast(pool_blocks.items.len - pool_available_blocks),
    };
    poolNotifyWrite(@intFromPtr(output), len);
    @memcpy(std.mem.asBytes(output)[0..len], std.mem.asBytes(&stats)[0..len]);
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
    .{ .name = "sceKernelMemoryPoolReserve", .function = trace.wrap("sceKernelMemoryPoolReserve", &sceKernelMemoryPoolReserve), .expect_id = "pU-QydtGcGY" },
    .{ .name = "sceKernelMemoryPoolExpand", .function = trace.wrap("sceKernelMemoryPoolExpand", &sceKernelMemoryPoolExpand), .expect_id = "qCSfqDILlns" },
    .{ .name = "sceKernelMemoryPoolCommit", .function = trace.wrap("sceKernelMemoryPoolCommit", &sceKernelMemoryPoolCommit), .expect_id = "Vzl66WmfLvk" },
    .{ .name = "sceKernelMemoryPoolDecommit", .function = trace.wrap("sceKernelMemoryPoolDecommit", &sceKernelMemoryPoolDecommit), .expect_id = "LXo1tpFqJGs" },
    .{ .name = "sceKernelMemoryPoolBatch", .function = trace.wrap("sceKernelMemoryPoolBatch", &sceKernelMemoryPoolBatch), .expect_id = "YN878uKRBbE" },
    .{ .name = "sceKernelMemoryPoolGetBlockStats", .function = trace.wrap("sceKernelMemoryPoolGetBlockStats", &sceKernelMemoryPoolGetBlockStats), .expect_id = "bvD+95Q6asU" },
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
        .name = "sceKernelAvailableDirectMemorySize",
        .function = trace.wrap("sceKernelAvailableDirectMemorySize", &sceKernelAvailableDirectMemorySize),
        .expect_id = "C0f7TJcbfac",
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
pub const posix_library = symbols.Library{ .name = "libScePosix", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

const posix_exports = [_]symbols.Export{
    .{ .name = "mprotect", .function = trace.wrap("mprotect", &mprotect), .expect_id = "YQOfxL4QfeU" },
    .{ .name = "munmap", .function = trace.wrap("munmap", &munmap), .expect_id = "UqDGjXA5yUM" },
};

/// Registers this library with a symbol database.
pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
    try db.addLibrary(gpa, library, module, &posix_exports);
    try db.addLibrary(gpa, posix_library, module, &posix_exports);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "POSIX memory permissions execute JIT code and unmap across holes" {
    var space = try memory.AddressSpace.init(testing.allocator);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);

    const result = mmap(0, 3 * page_size, posix_prot_read | posix_prot_write, posix_map_anonymous, -1, 0);
    try testing.expect(result > 0);
    const address: u64 = @intCast(result);
    // mov eax, 42; ret. Exercise the host RX mapping, not just its metadata.
    try space.write(address, &.{ 0xb8, 42, 0, 0, 0, 0xc3 });
    try testing.expectEqual(@as(i32, 0), mprotect(address, 1, posix_prot_read | posix_prot_exec));
    try testing.expect(!space.isWritable(address, 1));
    try testing.expect(space.query(address, false).?.protection.execute);
    const generated: *const fn () callconv(abi.guest) u32 = @ptrFromInt(address);
    try testing.expectEqual(@as(u32, 42), generated());
    try testing.expectEqual(@as(i32, 0), mprotect(address, page_size, 0));
    try testing.expect(!space.isReadable(address, 1));
    try testing.expectEqual(@as(i32, 0), mprotect(address, page_size, posix_prot_read | posix_prot_write));
    try space.write(address, "restored");
    try testing.expectEqual(@as(i32, 0), munmap(address + page_size, 1));
    try testing.expect(space.query(address + page_size, false) == null);
    try testing.expect(space.isWritable(address + 2 * page_size, 1));
    try testing.expectEqual(@as(i32, 0), munmap(address, 2 * page_size + 1));
    try testing.expect(space.query(address, false) == null);
    try testing.expect(space.query(address + 2 * page_size, false) == null);
    try testing.expectEqual(@as(i32, 0), munmap(address, 3 * page_size));
    try testing.expectEqual(@as(u64, 0), space.mappedBytes(.flexible));
}

test "fixed direct mapping spans adjacent recycled virtual reservations" {
    var space = try memory.AddressSpace.initWithDirectMemory(testing.allocator, 32 * page_size);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);
    var physical: u64 = 0;
    try testing.expectEqual(errno.ok, sceKernelAllocateDirectMemory(0, direct_memory_size, 16 * page_size, page_size, 0, &physical));
    var base: u64 = 0;
    try testing.expectEqual(errno.ok, sceKernelReserveVirtualRange(&base, 32 * page_size, 0, page_size));
    var first = base;
    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&first, 2 * page_size, 3, map_fixed, physical, 0));
    try space.write(base, "keep");
    // Recycling one allocation leaves two adjacent logical reservations and
    // two differently sized host placeholders, as in Minecraft's allocator.
    var recycled = base + page_size;
    try testing.expectEqual(errno.ok, sceKernelReserveVirtualRange(&recycled, page_size, map_fixed, page_size));
    var combined = recycled;
    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&combined, 8 * page_size, 3, map_fixed, physical + 2 * page_size, 0));
    try space.write(combined + 8 * page_size - 4, "tail");
    var bytes: [4]u8 = undefined;
    try space.read(base, &bytes);
    try testing.expectEqualStrings("keep", &bytes);
    try testing.expectEqual(memory.MappingKind.reserved, space.query(base + 9 * page_size, false).?.kind);
}

test "partial direct release preserves both surviving sides of every alias" {
    var space = try memory.AddressSpace.initWithDirectMemory(testing.allocator, 8 * page_size);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);
    var physical: u64 = 0;
    try testing.expectEqual(errno.ok, sceKernelAllocateDirectMemory(0, direct_memory_size, 3 * page_size, page_size, 0, &physical));
    var first: u64 = 0;
    var second: u64 = 0;
    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&first, 3 * page_size, 3, 0, physical, 0));
    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&second, 3 * page_size, 3, 0, physical, 0));
    try space.write(first, "head");
    try space.write(first + 2 * page_size, "tail");
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(physical + page_size, page_size));
    for ([_]u64{ first, second }) |address| {
        try testing.expect(space.query(address + page_size, false) == null);
        var bytes: [4]u8 = undefined;
        try space.read(address, &bytes);
        try testing.expectEqualStrings("head", &bytes);
        try space.read(address + 2 * page_size, &bytes);
        try testing.expectEqualStrings("tail", &bytes);
    }
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(physical, page_size));
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(physical + 2 * page_size, page_size));
}

test "POSIX memory errors set guest errno without changing valid pages" {
    var space = try memory.AddressSpace.init(testing.allocator);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try runtime_api.register(&db, testing.allocator);
    const get_errno: *const fn () callconv(abi.guest) *i32 = @ptrFromInt(db.findById("9BcDykPmo1I", .function).?.address);
    const cell = get_errno();
    const previous_errno = cell.*;
    defer cell.* = previous_errno;
    const result = mmap(0, page_size, posix_prot_read | posix_prot_write, posix_map_anonymous, -1, 0);
    try testing.expect(result > 0);
    const address: u64 = @intCast(result);
    try testing.expectEqual(@as(i32, -1), mprotect(address + 1, 1, posix_prot_read));
    try testing.expectEqual(errno.Posix.einval, cell.*);
    try testing.expectEqual(@as(i32, -1), mprotect(address, page_size, 0x8000));
    try testing.expectEqual(errno.Posix.einval, cell.*);
    try testing.expectEqual(@as(i32, -1), mprotect(address, 2 * page_size, posix_prot_read));
    try testing.expectEqual(errno.Posix.enomem, cell.*);
    try testing.expectEqual(@as(i32, -1), munmap(address + 1, page_size));
    try testing.expectEqual(errno.Posix.einval, cell.*);
    try testing.expectEqual(@as(i32, -1), munmap(address, 0));
    try testing.expectEqual(errno.Posix.einval, cell.*);
    try testing.expectEqual(@as(i32, -1), munmap(address, std.math.maxInt(u64)));
    try testing.expectEqual(errno.Posix.einval, cell.*);
    try testing.expectEqual(@as(i32, -1), mprotect(address, std.math.maxInt(u64), posix_prot_read));
    try testing.expectEqual(errno.Posix.einval, cell.*);
    try testing.expect(space.isWritable(address, page_size));
    try testing.expectEqual(@as(i32, 0), mprotect(address, 0, posix_prot_read));
    try testing.expect(space.isWritable(address, page_size));
    cell.* = 123;
    try testing.expectEqual(@as(i32, 0), munmap(address, page_size));
    try testing.expectEqual(@as(i32, 123), cell.*);
}

test "POSIX memory exports resolve by NID in both libraries" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    for (posix_exports) |entry| {
        for ([_]symbols.Library{ library, posix_library }) |lib| {
            const found = db.find(.{
                .id = @import("../nid.zig").fromName(entry.name),
                .library = lib,
                .module = module,
                .type = .function,
            }) orelse return error.MissingPosixMemoryExport;
            try testing.expectEqualStrings(entry.name, found.name);
        }
    }
}

fn expectPoolStats(available: i32, allocated: i32) !void {
    var stats: MemoryPoolBlockStats = undefined;
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolGetBlockStats(&stats, @sizeOf(MemoryPoolBlockStats)));
    try testing.expectEqualDeep(MemoryPoolBlockStats{ .available_flushed_blocks = available, .allocated_flushed_blocks = allocated }, stats);
}

test "MemoryPool lifetime preserves physical data and virtual ownership" {
    var space = try memory.AddressSpace.initWithDirectMemory(testing.allocator, 4 * pool_block_size);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);
    var physical: u64 = undefined;
    var address: u64 = undefined;
    var flexible_before: u64 = undefined;
    try testing.expectEqual(errno.ok, sceKernelAvailableFlexibleMemorySize(&flexible_before));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolExpand(0, direct_memory_size, 4 * pool_block_size, 0, &physical));
    try expectPoolStats(4, 0);
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolReserve(memory.user.start, pool_reserve_alignment, 0, 0, &address));
    try testing.expectEqual(@as(u64, 0), address % pool_reserve_alignment);
    try testing.expectEqual(errno.ok, sceKernelSetVirtualRangeName(address, pool_reserve_alignment, "pool-arena"));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolCommit(address, 2 * pool_block_size, 10, 0x33, 0));
    try space.write(address, "first block");
    try space.write(address + pool_block_size, "second block");
    try expectPoolStats(2, 2);
    var query: VirtualQueryInfo = undefined;
    try testing.expectEqual(errno.ok, sceKernelVirtualQuery(address, 0, &query, @sizeOf(VirtualQueryInfo)));
    try testing.expectEqual(state_pooled | state_committed, query.state);
    try testing.expectEqual(@as(u64, 0), query.offset);
    try testing.expectEqual(@as(i32, 10), query.memory_type);
    try testing.expectEqualStrings("pool-arena", std.mem.sliceTo(&query.name, 0));
    var flexible_after: u64 = undefined;
    try testing.expectEqual(errno.ok, sceKernelAvailableFlexibleMemorySize(&flexible_after));
    try testing.expectEqual(flexible_before, flexible_after);
    try testing.expectEqual(KernelError.eacces.raw(), sceKernelCheckedReleaseDirectMemory(physical, 4 * pool_block_size));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolDecommit(address, pool_block_size, 0));
    try testing.expect(!space.isReadable(address, pool_block_size));
    try expectPoolStats(3, 1);
    try testing.expectEqual(errno.ok, sceKernelVirtualQuery(address, 0, &query, @sizeOf(VirtualQueryInfo)));
    try testing.expectEqual(state_pooled, query.state);
    try testing.expectEqual(@as(i32, 0), query.protection);
    try testing.expectEqualStrings("second block", @as([*]const u8, @ptrFromInt(address + pool_block_size))[0..12]);
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolCommit(address, pool_block_size, 3, 3, 0));
    try testing.expectEqualStrings("first block", @as([*]const u8, @ptrFromInt(address))[0..11]);
    // Munmap also returns committed blocks; the virtual arena itself is gone.
    try testing.expectEqual(errno.ok, sceKernelMunmap(address, pool_reserve_alignment));
    try testing.expect(space.query(address, false) == null);
    try expectPoolStats(4, 0);
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(physical, 4 * pool_block_size));
    try expectPoolStats(0, 0);
}

test "MemoryPool fragmented backing exhaustion and safe coexistence with direct memory" {
    var space = try memory.AddressSpace.initWithDirectMemory(testing.allocator, 4 * pool_block_size);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);
    var first: u64 = undefined;
    var gap: u64 = undefined;
    var second: u64 = undefined;
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolExpand(0, direct_memory_size, pool_block_size, 0, &first));
    try testing.expectEqual(errno.ok, sceKernelAllocateDirectMemory(0, direct_memory_size, pool_block_size, pool_block_size, 0, &gap));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolExpand(0, direct_memory_size, pool_block_size, 0, &second));
    try testing.expectEqual(first + 2 * pool_block_size, second);
    var alias: u64 = 0;
    try testing.expectEqual(KernelError.eacces.raw(), sceKernelMapDirectMemory(&alias, pool_block_size, 3, 0, first, 0));
    // Even BatchMap's untracked-range fallback must reject donated pages.
    var ordinary = [_]BatchMapEntry{.{ .start = 0, .offset = gap, .length = 2 * pool_block_size, .protection = 3, .memory_type = 0, .reserved = 0, .operation = 0 }};
    var processed: i32 = -1;
    try testing.expectEqual(KernelError.eacces.raw(), batchMapCore(&ordinary, 1, &processed, 0));
    try testing.expectEqual(@as(i32, 0), processed);
    var address: u64 = undefined;
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolReserve(memory.user.start, pool_reserve_alignment, 0, 0, &address));
    alias = address;
    try testing.expectEqual(KernelError.eacces.raw(), sceKernelMapDirectMemory(&alias, pool_block_size, 3, map_fixed, gap, 0));
    alias = address;
    try testing.expectEqual(KernelError.eacces.raw(), mapFlexibleMemory(&alias, pool_block_size, 3, map_fixed, "wrong"));
    alias = address;
    try testing.expectEqual(KernelError.eacces.raw(), sceKernelReserveVirtualRange(&alias, pool_block_size, map_fixed, 0));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolCommit(address, 2 * pool_block_size, 0, 3, 0));
    try testing.expectEqual(first, space.query(address, false).?.backing_offset.?);
    try testing.expectEqual(second, space.query(address + pool_block_size, false).?.backing_offset.?);
    try testing.expectEqual(KernelError.enomem.raw(), sceKernelMemoryPoolCommit(address + 2 * pool_block_size, pool_block_size, 0, 3, 0));
    try testing.expectEqual(memory.MappingKind.reserved, space.query(address + 2 * pool_block_size, false).?.kind);
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolDecommit(address, 3 * pool_block_size, 0));
    try expectPoolStats(2, 0);
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(first, pool_block_size));
    try expectPoolStats(1, 0);
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolCommit(address, pool_block_size, 0, 3, 0));
    try testing.expectEqual(second, space.query(address, false).?.backing_offset.?);
}

test "MemoryPool expansion into a lower hole marks only the donated interval" {
    init(testing.allocator);
    defer deinit();
    var direct: u64 = undefined;
    var donated: u64 = undefined;
    try testing.expectEqual(errno.ok, sceKernelAllocateDirectMemory(pool_block_size, 2 * pool_block_size, pool_block_size, 0, 0, &direct));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolExpand(0, direct_memory_size, pool_block_size, 0, &donated));
    try testing.expectEqual(@as(u64, 0), donated);
    try testing.expect(pool.findContaining(donated).?.pooled);
    try testing.expect(!pool.findContaining(direct).?.pooled);
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(donated, pool_block_size));
    try testing.expect(pool.findContaining(direct) != null);
    try expectPoolStats(0, 0);
}

test "MemoryPool batch reports completed prefix and applies protection and type" {
    var space = try memory.AddressSpace.initWithDirectMemory(testing.allocator, 4 * pool_block_size);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);
    var physical: u64 = undefined;
    var address: u64 = undefined;
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolExpand(0, direct_memory_size, 4 * pool_block_size, 0, &physical));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolReserve(memory.user.start, pool_reserve_alignment, 0, 0, &address));
    const entries = [_]MemoryPoolBatchEntry{
        .{ .operation = 1, .address = address, .length = 2 * pool_block_size, .protection = 3, .memory_type = 3 },
        .{ .operation = 3, .address = address, .length = page_size, .protection = 1 },
        .{ .operation = 4, .address = address + page_size, .length = page_size, .protection = 0x33, .memory_type = 10 },
        .{ .operation = 5, .address = address, .length = pool_block_size },
        .{ .operation = 2, .address = address, .length = 2 * pool_block_size },
    };
    var processed: i32 = -1;
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMemoryPoolBatch(&entries, entries.len, &processed, 0));
    try testing.expectEqual(@as(i32, 3), processed);
    try testing.expect(!space.isWritable(address, page_size));
    const changed = space.query(address + page_size, false).?;
    try testing.expect(changed.pooled);
    try testing.expectEqual(@as(i32, 10), changed.memory_type);
    try testing.expectEqual(@as(i32, 0x33), changed.protection_bits);
    try expectPoolStats(2, 2);
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolBatch(entries[4..].ptr, 1, &processed, 0));
    try testing.expectEqual(@as(i32, 1), processed);
    try expectPoolStats(4, 0);
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolBatch(&entries, 0, null, 0));
}

test "MemoryPool rejects invalid ranges before changing earlier blocks" {
    var space = try memory.AddressSpace.initWithDirectMemory(testing.allocator, 2 * pool_block_size);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);
    var address: u64 = 0;
    var physical: u64 = 0;
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMemoryPoolReserve(0, page_size, 0, 0, &address));
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMemoryPoolExpand(0, direct_memory_size, page_size, 0, &physical));
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMemoryPoolExpand(0, direct_memory_size, pool_block_size, page_size, &physical));
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMemoryPoolExpand(-1, direct_memory_size, pool_block_size, 0, &physical));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolExpand(0, direct_memory_size, 2 * pool_block_size, 0, &physical));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolReserve(memory.user.start, pool_reserve_alignment, 0, 0, &address));
    const last = address + pool_reserve_alignment - pool_block_size;
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolCommit(last, pool_block_size, 0, 3, 0));
    try space.write(last, "untouched");
    try testing.expectEqual(KernelError.eacces.raw(), sceKernelMemoryPoolDecommit(last, 2 * pool_block_size, 0));
    try testing.expectEqualStrings("untouched", @as([*]const u8, @ptrFromInt(last))[0..9]);
    try expectPoolStats(1, 1);
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMemoryPoolDecommit(last, page_size, 0));
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMunmap(last, page_size));
    try testing.expectEqual(KernelError.eacces.raw(), sceKernelMemoryPoolCommit(address, pool_block_size, 0, 5, 0));
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMemoryPoolCommit(address, pool_block_size, 0, 0x400, 0));
    try testing.expectEqual(KernelError.eacces.raw(), sceKernelMemoryPoolCommit(last, pool_block_size, 0, 3, 0));
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMemoryPoolDecommit(0xffffffffffff0000, 2 * pool_block_size, 0));
    try testing.expectEqual(KernelError.efault.raw(), sceKernelMemoryPoolGetBlockStats(@ptrFromInt(1), 16));
    try testing.expectEqual(KernelError.efault.raw(), sceKernelMemoryPoolExpand(0, direct_memory_size, pool_block_size, 0, @ptrFromInt(8)));
    try testing.expectEqual(KernelError.efault.raw(), sceKernelMemoryPoolBatch(@ptrFromInt(8), 1, null, 0));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolGetBlockStats(null, 0));
    var short: [16]u8 = .{0xaa} ** 16;
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolGetBlockStats(@ptrCast(&short), 4));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, short[0..4], .little));
    try testing.expectEqualSlices(u8, &(.{0xaa} ** 12), short[4..]);
}

test "MemoryPool host commit failure rolls back fragmented mappings and accounting" {
    // Only the first donation fits the test's deliberately smaller host backing.
    var space = try memory.AddressSpace.initWithDirectMemory(testing.allocator, pool_block_size);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);
    var first: u64 = undefined;
    var gap: u64 = undefined;
    var second: u64 = undefined;
    var address: u64 = undefined;
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolExpand(0, direct_memory_size, pool_block_size, 0, &first));
    try testing.expectEqual(errno.ok, sceKernelAllocateDirectMemory(0, direct_memory_size, pool_block_size, pool_block_size, 0, &gap));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolExpand(0, direct_memory_size, pool_block_size, 0, &second));
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolReserve(memory.user.start, pool_reserve_alignment, 0, 0, &address));
    try testing.expectEqual(KernelError.einval.raw(), sceKernelMemoryPoolCommit(address, 2 * pool_block_size, 0, 3, 0));
    try expectPoolStats(2, 0);
    try testing.expect(!space.isReadable(address, pool_block_size));
    try testing.expectEqual(memory.MappingKind.reserved, space.query(address, false).?.kind);
    try testing.expectEqual(errno.ok, sceKernelMemoryPoolCommit(address, pool_block_size, 0, 3, 0));
    try space.write(address, "retry");
    try expectPoolStats(1, 1);
}

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

test "direct memory interval search matches a page map across fragmented windows" {
    var p = Pool{ .size = 8 * page_size };
    defer p.deinit(testing.allocator);
    for (0..256) |mask| {
        p.reservations.clearRetainingCapacity();
        // Allocate in reverse order to exercise insertion ahead of an
        // existing reservation, as happens when a lower hole is reused.
        for (0..8) |reverse| {
            const page = 7 - reverse;
            if (mask & (@as(usize, 1) << @intCast(page)) == 0) continue;
            _ = try p.reserve(testing.allocator, page * page_size, (page + 1) * page_size, page_size, page_size, .wb_onion);
        }
        for ([_]u64{ 0, 1, page_size, 2 * page_size + 7 }) |start| {
            for ([_]u64{ 3 * page_size, 6 * page_size + 17, 8 * page_size, 9 * page_size }) |end| {
                for ([_]u64{ page_size, 2 * page_size, 4 * page_size }) |alignment| {
                    const limit = @min(end, p.size);
                    var expected_start: u64 = 0;
                    var expected_len: u64 = 0;
                    var first_fit = [_]?u64{null} ** 3;
                    const lengths = [_]u64{ page_size, 2 * page_size, 4 * page_size };
                    var candidate = std.mem.alignForward(u64, start, alignment);
                    while (candidate + page_size <= limit) : (candidate += alignment) {
                        var cursor = candidate;
                        while (cursor + page_size <= limit) : (cursor += page_size) {
                            if (mask & (@as(usize, 1) << @intCast(cursor / page_size)) != 0) break;
                        }
                        const len = cursor - candidate;
                        if (len > expected_len) {
                            expected_len = len;
                            expected_start = candidate;
                        }
                        for (lengths, 0..) |length, index| {
                            if (first_fit[index] == null and len >= length) first_fit[index] = candidate;
                        }
                    }
                    const largest = p.largestFree(start, end, alignment);
                    if (expected_len == 0) {
                        try testing.expect(largest == null);
                    } else {
                        try testing.expectEqual(expected_start, largest.?.start);
                        try testing.expectEqual(expected_len, largest.?.len);
                    }
                    for (lengths, first_fit) |length, expected| {
                        if (expected) |address| {
                            try testing.expectEqual(address, try p.reserve(testing.allocator, start, end, length, alignment, .wb_onion));
                            try p.release(testing.allocator, address, length);
                        } else {
                            try testing.expectError(error.OutOfDirectMemory, p.reserve(testing.allocator, start, end, length, alignment, .wb_onion));
                        }
                    }
                }
            }
        }
    }
}

test "dense direct allocations reuse split holes and retain ordered query metadata" {
    const count = 2048;
    var p = Pool{ .size = (count + 8) * page_size };
    defer p.deinit(testing.allocator);
    for (0..count) |index| {
        try testing.expectEqual(index * page_size, try p.reserve(testing.allocator, 0, p.size, page_size, page_size, .wb_onion));
    }
    try p.release(testing.allocator, 3 * page_size, 5 * page_size);
    try testing.expectEqual(4 * page_size, try p.reserve(testing.allocator, 0, p.size, 2 * page_size, 4 * page_size, .wc_garlic));
    try testing.expectEqual(3 * page_size, try p.reserve(testing.allocator, 0, p.size, page_size, page_size, .wb_onion));
    try testing.expectEqual(6 * page_size, try p.reserve(testing.allocator, 0, p.size, 2 * page_size, page_size, .wb_onion));
    for (p.reservations.items[1..], p.reservations.items[0 .. p.reservations.items.len - 1]) |current, previous| {
        try testing.expect(previous.end() <= current.start);
    }
    try testing.expectEqual(MemoryType.wc_garlic, p.findContaining(5 * page_size).?.memory_type);
    const largest = p.largestFree(0, p.size, page_size).?;
    try testing.expectEqual(count * page_size, largest.start);
    try testing.expectEqual(8 * page_size, largest.len);
}

test "direct memory search clips partial pages and rejects overflowing windows" {
    var p = Pool{ .size = 8 * page_size };
    defer p.deinit(testing.allocator);
    try testing.expect(p.largestFree(0, page_size - 1, 0) == null);
    const clipped = p.largestFree(1, 3 * page_size - 1, 0).?;
    try testing.expectEqual(page_size, clipped.start);
    try testing.expectEqual(page_size, clipped.len);
    try testing.expect(p.largestFree(std.math.maxInt(u64) - 1, std.math.maxInt(u64), 0) == null);
    try testing.expectError(error.OutOfDirectMemory, p.reserve(testing.allocator, std.math.maxInt(u64) - 1, std.math.maxInt(u64), page_size, 0, .wb_onion));
    try testing.expectError(error.OutOfDirectMemory, p.reserve(testing.allocator, page_size, p.size, std.math.maxInt(u64), 0, .wb_onion));
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

test "repeated fixed direct memory mapping preserves its observed pages" {
    var space = try memory.AddressSpace.initWithDirectMemory(testing.allocator, direct_memory_size);
    defer space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&space);

    var physical: u64 = 0;
    try testing.expectEqual(errno.ok, sceKernelAllocateDirectMemory(0, direct_memory_size, 4 * page_size, page_size, 0, &physical));
    const base = memory.user.start;
    const bytes = 2 * page_size;
    const permissions = prot_cpu_read | prot_cpu_write | prot_gpu_read | prot_gpu_write;
    var address = base;
    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&address, bytes, permissions, map_fixed, physical, 0));
    try space.write(base, "keep");
    space.enableGpuMemoryTracking();
    const generation = try space.trackGpuRead(base, bytes);
    try testing.expect(generation != 0);

    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&address, bytes, permissions, map_fixed, physical, 0));
    try testing.expectEqual(base, address);
    try testing.expectEqual(generation, space.gpuGeneration(base, bytes));
    var value: [4]u8 = undefined;
    try space.read(base, &value);
    try testing.expectEqualStrings("keep", &value);

    try testing.expectEqual(KernelError.enomem.raw(), sceKernelMapDirectMemory(&address, bytes, permissions, @bitCast(@as(u32, @intCast(map_fixed)) | map_no_overwrite), physical, 0));
    try testing.expectEqual(@as(u64, 0), address);
    try testing.expectEqual(generation, space.gpuGeneration(base, bytes));

    // Fragmented metadata keeps the normal replacement and query boundaries.
    try space.setMetadata(base + page_size, page_size, .{ .name = "split-name" });
    address = base;
    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&address, bytes, permissions, map_fixed, physical, 0));
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(base, bytes));
    try testing.expectEqual(bytes, space.query(base, false).?.size);
    try testing.expectEqualStrings("direct", std.mem.sliceTo(&space.query(base + page_size, false).?.name, 0));
    try space.read(base, &value);
    try testing.expectEqualStrings("keep", &value);

    // A different physical range must still replace the old mapping.
    address = base;
    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&address, bytes, permissions, map_fixed, physical + bytes, 0));
    try testing.expectEqual(@as(u64, 0), space.gpuGeneration(base, bytes));
    try space.read(base, &value);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &value);
    try testing.expectEqual(@as(?u64, physical + bytes), space.directMemoryOffset(base, bytes));

    // Different permissions keep the normal replacement/protection path.
    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&address, bytes, prot_cpu_read, map_fixed, physical + bytes, 0));
    try testing.expect(space.isReadable(base, bytes));
    try testing.expect(!space.isWritable(base, bytes));
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

test "batch map chooses an address for a zero-start direct entry" {
    var address_space = try memory.AddressSpace.initWithDirectMemory(
        testing.allocator,
        direct_memory_size,
    );
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    var physical: u64 = 0;
    try testing.expectEqual(
        errno.ok,
        sceKernelAllocateDirectMemory(0, direct_memory_size, page_size, page_size, 0, &physical),
    );
    var entry = BatchMapEntry{
        .start = 0,
        .offset = physical,
        .length = page_size,
        .protection = prot_cpu_read | prot_cpu_write,
        .memory_type = 0,
        .reserved = 0,
        .operation = @intFromEnum(BatchOperation.map_direct),
    };
    var processed: i32 = -1;
    try testing.expectEqual(
        errno.ok,
        sceKernelBatchMap(@ptrCast(&entry), 1, &processed),
    );
    try testing.expectEqual(@as(i32, 1), processed);
    try testing.expect(entry.start != 0);
    try testing.expect(address_space.isMappedAs(entry.start, page_size, .direct_memory));
    try testing.expectEqual(errno.ok, sceKernelMunmap(entry.start, page_size));
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(physical, page_size));
}

test "batch map coalesces virtual protection and unmaps while preserving partial progress" {
    var address_space = try memory.AddressSpace.initWithDirectMemory(testing.allocator, direct_memory_size);
    defer address_space.deinit();
    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);
    var physical: u64 = 0;
    try testing.expectEqual(errno.ok, sceKernelAllocateDirectMemory(0, direct_memory_size, 3 * page_size, page_size, 0, &physical));
    var address: u64 = 0;
    try testing.expectEqual(errno.ok, sceKernelMapDirectMemory(&address, 3 * page_size, prot_cpu_read | prot_cpu_write, 0, physical, 0));
    var entries: [3]BatchMapEntry = undefined;
    for (&entries, 0..) |*entry, index| entry.* = .{
        .start = address + index * page_size,
        .offset = 0,
        .length = page_size,
        .protection = prot_cpu_read,
        .memory_type = 0,
        .reserved = 0,
        .operation = @intFromEnum(BatchOperation.protect),
    };
    var processed: i32 = -1;
    try testing.expectEqual(errno.ok, sceKernelBatchMap(&entries, entries.len, &processed));
    try testing.expectEqual(@as(i32, 3), processed);
    for (entries) |entry| {
        var info = VirtualQueryInfo{};
        try testing.expectEqual(errno.ok, sceKernelVirtualQuery(entry.start, 0, &info, @sizeOf(VirtualQueryInfo)));
        try testing.expectEqual(@as(i32, prot_cpu_read), info.protection);
    }
    for (&entries) |*entry| entry.operation = @intFromEnum(BatchOperation.unmap);
    // The combined span is one full page, but each slice is invalid for
    // munmap. No entry may be consumed and the original mapping must survive.
    const valid_entries = entries;
    entries[0].length = 1;
    entries[1].start = address + 1;
    entries[1].length = page_size - 1;
    try testing.expectEqual(KernelError.einval.raw(), sceKernelBatchMap(&entries, 2, &processed));
    try testing.expectEqual(@as(i32, 0), processed);
    try testing.expect(address_space.isMappedAs(address, 3 * page_size, .direct_memory));
    entries = valid_entries;
    entries[2].length = 0;
    try testing.expectEqual(KernelError.einval.raw(), sceKernelBatchMap(&entries, entries.len, &processed));
    try testing.expectEqual(@as(i32, 2), processed);
    try testing.expect(!address_space.isMappedAs(address, page_size, .direct_memory));
    try testing.expect(!address_space.isMappedAs(address + page_size, page_size, .direct_memory));
    try testing.expect(address_space.isMappedAs(address + 2 * page_size, page_size, .direct_memory));
    try testing.expectEqual(errno.ok, sceKernelMunmap(address + 2 * page_size, page_size));
    try testing.expectEqual(errno.ok, sceKernelReleaseDirectMemory(physical, 3 * page_size));
}

test "batch map accepts a valid in-pool direct range missing from the tracker" {
    var address_space = try memory.AddressSpace.initWithDirectMemory(
        testing.allocator,
        direct_memory_size,
    );
    defer address_space.deinit();

    init(testing.allocator);
    defer deinit();
    attachAddressSpace(&address_space);

    const virtual_address = memory.user.start;
    try address_space.reserveFixed(virtual_address, page_size);
    var entry = BatchMapEntry{
        .start = virtual_address,
        .offset = 8 * page_size,
        .length = page_size,
        .protection = prot_cpu_read | prot_cpu_write | prot_gpu_read | prot_gpu_write,
        .memory_type = 12,
        .reserved = 0,
        .operation = @intFromEnum(BatchOperation.map_direct),
    };
    var processed: i32 = -1;
    try testing.expectEqual(errno.ok, sceKernelBatchMap(@ptrCast(&entry), 1, &processed));
    try testing.expectEqual(@as(i32, 1), processed);

    var info = VirtualQueryInfo{};
    try testing.expectEqual(
        errno.ok,
        sceKernelVirtualQuery(entry.start, 0, &info, @sizeOf(VirtualQueryInfo)),
    );
    try testing.expectEqual(@as(i32, 12), info.memory_type);
    try testing.expectEqual(entry.offset, info.offset);
    try testing.expectEqual(errno.ok, sceKernelMunmap(entry.start, entry.length));
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
    try testing.expectEqual(@as(u64, 0), arena % large_semantic_reservation_alignment);
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
    try testing.expectEqual(@as(u64, 0), arena % large_semantic_reservation_alignment);
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

    try testing.expect(isGuestStackRange(base, 8));
    try testing.expect(!isGuestStackRange(reserved_base, 8));
    try testing.expect(!isGuestStackRange(0, 8));
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
    try testing.expectEqual(exports.len + 2 * posix_exports.len, db.count());

    const found = db.findByName("sceKernelGetDirectMemorySize", .function) orelse
        return error.TestExpectedSymbol;
    try testing.expectEqualStrings("pO96TwzOm5E", &found.key.id);
}

test "contiguous runs stop at every discontinuity a combined mapping would hide" {
    const base: u64 = 0x1000_0000;
    const step: u64 = 0x2_0000;
    const entry = struct {
        fn at(start: u64, offset: u64, length: u64, operation: BatchOperation) BatchMapEntry {
            return .{
                .start = start,
                .offset = offset,
                .length = length,
                .protection = 3,
                .memory_type = 0,
                .reserved = 0,
                .operation = @intFromEnum(operation),
            };
        }
    };
    // Three adjacent slices of one streamed region become one run.
    var adjacent = [_]BatchMapEntry{
        entry.at(base, 0, step, .map_direct),
        entry.at(base + step, step, step, .map_direct),
        entry.at(base + 2 * step, 2 * step, step, .map_direct),
    };
    try std.testing.expectEqual(@as(usize, 3), contiguousRun(&adjacent));

    // A gap in the guest address ends the run even though the physical
    // offsets stay adjacent; mapping across it would cover memory the guest
    // never asked for.
    var address_gap = adjacent;
    address_gap[2].start += step;
    try std.testing.expectEqual(@as(usize, 2), contiguousRun(&address_gap));

    // A gap in the physical offset ends it too: the combined view would hand
    // the second half the wrong bytes.
    var offset_gap = adjacent;
    offset_gap[1].offset += step;
    try std.testing.expectEqual(@as(usize, 1), contiguousRun(&offset_gap));

    // Differing operation, protection or memory type each stand alone.
    var mixed_operation = adjacent;
    mixed_operation[1].operation = @intFromEnum(BatchOperation.unmap);
    try std.testing.expectEqual(@as(usize, 1), contiguousRun(&mixed_operation));
    var mixed_protection = adjacent;
    mixed_protection[2].protection = 1;
    try std.testing.expectEqual(@as(usize, 2), contiguousRun(&mixed_protection));
    var mixed_type = adjacent;
    mixed_type[1].memory_type = 3;
    try std.testing.expectEqual(@as(usize, 1), contiguousRun(&mixed_type));

    // A zero length is rejected by the per-entry path, so it must not be
    // absorbed into a run that would give it a size.
    var zero_length = adjacent;
    zero_length[1].length = 0;
    try std.testing.expectEqual(@as(usize, 1), contiguousRun(&zero_length));
    zero_length = adjacent;
    zero_length[0].length = 0;
    try std.testing.expectEqual(@as(usize, 1), contiguousRun(&zero_length));

    // Streaming unmaps and protection changes do not name physical memory.
    // Noncontiguous or overflowing unused offsets must not split these runs.
    for ([_]BatchOperation{ .unmap, .protect, .type_protect }) |operation| {
        var virtual_only = adjacent;
        for (&virtual_only) |*item| {
            item.operation = @intFromEnum(operation);
            item.offset = 0;
        }
        try std.testing.expectEqual(@as(usize, 3), contiguousRun(&virtual_only));
        virtual_only[0].offset = std.math.maxInt(u64);
        virtual_only[1].offset = 0x1234;
        try std.testing.expectEqual(@as(usize, 3), contiguousRun(&virtual_only));
        virtual_only[2].start += step;
        try std.testing.expectEqual(@as(usize, 2), contiguousRun(&virtual_only));
    }
    var invalid_operation = adjacent;
    for (&invalid_operation) |*item| item.operation = 255;
    try std.testing.expectEqual(@as(usize, 1), contiguousRun(&invalid_operation));
    try std.testing.expectEqual(@as(usize, 0), contiguousRun(&.{}));

    // A run of one is what a lone entry reports, and the length never exceeds
    // the slice it was given.
    try std.testing.expectEqual(@as(usize, 1), contiguousRun(adjacent[2..]));
}
