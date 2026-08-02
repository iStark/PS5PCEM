// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Direct memory management from `libkernel`.
//!
//! "Direct memory" is the guest's name for physical video memory. A title
//! reserves a range of it, then maps that range into its address space. The two
//! steps are separate: the reservation is a claim on a physical range, and the
//! mapping decides where and with what protection it becomes visible.
//!
//! What is modelled here is the allocator's bookkeeping — which physical ranges
//! are taken, and with what alignment and memory type. Establishing the actual
//! host mapping needs the guest address space, which does not exist yet, so
//! `sceKernelMapDirectMemory` currently reports the reservation state without
//! mapping anything.

const std = @import("std");
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

/// Installs the allocator the pool uses for its bookkeeping.
pub fn init(gpa: std.mem.Allocator) void {
    pool_lock.lock();
    defer pool_lock.unlock();
    pool_gpa = gpa;
}

pub fn deinit() void {
    pool_lock.lock();
    defer pool_lock.unlock();
    if (pool_gpa) |gpa| pool.deinit(gpa);
    pool = .{};
    pool_gpa = null;
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

/// Maps a reserved range into the guest address space.
///
/// Not implemented: establishing the mapping needs the guest address space.
/// The reservation is still validated, so a title that maps an address it never
/// reserved gets the same rejection it would on hardware.
fn sceKernelMapDirectMemory(
    _: ?*u64,
    len: u64,
    _: i32,
    _: i32,
    physical_address: u64,
    _: u64,
) callconv(abi.guest) i32 {
    if (len == 0) return KernelError.einval.raw();

    pool_lock.lock();
    defer pool_lock.unlock();

    if (pool.findContaining(physical_address) == null) return KernelError.einval.raw();
    return KernelError.enosys.raw();
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
        .name = "sceKernelMapDirectMemory",
        .function = abi.erase(&sceKernelMapDirectMemory),
        .expect_id = "L-Q3LEjIbgA",
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

test "mapping an unreserved address is rejected" {
    init(testing.allocator);
    defer deinit();

    var start: u64 = 0;
    _ = sceKernelAllocateDirectMemory(0, direct_memory_size, page_size, page_size, 0, &start);

    // Far outside anything reserved.
    try testing.expectEqual(
        KernelError.einval.raw(),
        sceKernelMapDirectMemory(null, page_size, 0, 0, direct_memory_size - page_size, 0),
    );
    // A reserved address gets as far as the unimplemented mapping step.
    try testing.expectEqual(
        KernelError.enosys.raw(),
        sceKernelMapDirectMemory(null, page_size, 0, 0, start, 0),
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
