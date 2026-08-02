//! Error codes returned by firmware entry points.
//!
//! Two numbering schemes coexist in the guest ABI and a lot of confusion comes
//! from mixing them up:
//!
//!   * Kernel-style entry points (`sceKernel*`) return `0` on success and a
//!     negative status of the form `0x8002_00xx` on failure, where the low byte
//!     is a POSIX error number.
//!   * POSIX-style entry points (`open`, `stat`, `pthread_*`) follow C library
//!     conventions: `-1` with the error stored in a thread-local `errno`, or —
//!     for the `pthread_*` family — the plain positive error number.
//!
//! `KernelError` models the first scheme; `Posix` holds the numbers used by the
//! second. Note that the guest's POSIX numbering diverges from the host's above
//! 1000, so the two are not interchangeable.

const std = @import("std");

/// Every kernel error shares this prefix; the low byte is a POSIX error number.
pub const kernel_error_base: u32 = 0x8002_0000;

/// Returned by kernel entry points that succeed.
pub const ok: i32 = 0;

/// POSIX error numbers as the guest defines them.
///
/// Values up to 100 match the usual Unix numbering. Above that the guest uses
/// its own allocations, which is why this is an explicit list rather than a
/// reuse of the host's `std.posix.E`.
pub const Posix = struct {
    pub const eperm: i32 = 1;
    pub const enoent: i32 = 2;
    pub const esrch: i32 = 3;
    pub const eintr: i32 = 4;
    pub const eio: i32 = 5;
    pub const enxio: i32 = 6;
    pub const e2big: i32 = 7;
    pub const enoexec: i32 = 8;
    pub const ebadf: i32 = 9;
    pub const echild: i32 = 10;
    pub const edeadlk: i32 = 11;
    pub const enomem: i32 = 12;
    pub const eacces: i32 = 13;
    pub const efault: i32 = 14;
    pub const ebusy: i32 = 16;
    pub const eexist: i32 = 17;
    pub const einval: i32 = 22;
    pub const enfile: i32 = 23;
    pub const emfile: i32 = 24;
    pub const enospc: i32 = 28;
    pub const erange: i32 = 34;
    pub const enosys: i32 = 78;
    pub const eagain: i32 = 35;
    pub const etimedout: i32 = 60;

    /// Substituted when a kernel status has no POSIX counterpart.
    pub const eother: i32 = 1062;
};

/// A kernel-scheme status code.
///
/// Stored as the raw `i32` the guest sees, so it can be returned directly from
/// an entry point without conversion.
pub const KernelError = enum(i32) {
    unknown = @bitCast(kernel_error_base),
    eperm = @bitCast(kernel_error_base | 1),
    enoent = @bitCast(kernel_error_base | 2),
    esrch = @bitCast(kernel_error_base | 3),
    eintr = @bitCast(kernel_error_base | 4),
    eio = @bitCast(kernel_error_base | 5),
    enxio = @bitCast(kernel_error_base | 6),
    e2big = @bitCast(kernel_error_base | 7),
    enoexec = @bitCast(kernel_error_base | 8),
    ebadf = @bitCast(kernel_error_base | 9),
    echild = @bitCast(kernel_error_base | 10),
    edeadlk = @bitCast(kernel_error_base | 11),
    enomem = @bitCast(kernel_error_base | 12),
    eacces = @bitCast(kernel_error_base | 13),
    efault = @bitCast(kernel_error_base | 14),
    ebusy = @bitCast(kernel_error_base | 16),
    eexist = @bitCast(kernel_error_base | 17),
    einval = @bitCast(kernel_error_base | 22),
    enfile = @bitCast(kernel_error_base | 23),
    emfile = @bitCast(kernel_error_base | 24),
    enospc = @bitCast(kernel_error_base | 28),
    eagain = @bitCast(kernel_error_base | 35),
    erange = @bitCast(kernel_error_base | 34),
    etimedout = @bitCast(kernel_error_base | 60),
    enosys = @bitCast(kernel_error_base | 78),

    /// The status as the guest observes it.
    pub fn raw(self: KernelError) i32 {
        return @intFromEnum(self);
    }

    /// The POSIX error number carried in the low byte.
    pub fn toPosix(self: KernelError) i32 {
        return kernelToPosix(self.raw());
    }
};

/// The highest kernel status that carries a POSIX error number.
///
/// The guest defines POSIX numbers 1..101 for this range; anything outside it
/// has no counterpart.
const kernel_error_max: u32 = kernel_error_base | 101;

/// Extracts the POSIX error number from a kernel status.
///
/// Statuses outside the mapped range collapse to `Posix.eother`, matching what
/// the firmware does rather than inventing a more precise answer.
pub fn kernelToPosix(status: i32) i32 {
    const bits: u32 = @bitCast(status);
    if (bits > kernel_error_base and bits <= kernel_error_max) {
        return @intCast(bits - kernel_error_base);
    }
    return Posix.eother;
}

/// Builds a kernel status from a POSIX error number.
pub fn posixToKernel(posix: i32) i32 {
    if (posix <= 0 or posix > 101) return @bitCast(kernel_error_base);
    return @bitCast(kernel_error_base | @as(u32, @intCast(posix)));
}

/// Whether a kernel entry point reported failure.
pub fn failed(status: i32) bool {
    return status != ok;
}

test "kernel statuses carry the documented bit patterns" {
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8002_0016))), KernelError.einval.raw());
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8002_000C))), KernelError.enomem.raw());
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x8002_0002))), KernelError.enoent.raw());
    // Kernel statuses are negative when read as a signed integer, which is how
    // guest code tests for failure.
    try std.testing.expect(KernelError.einval.raw() < 0);
}

test "kernel statuses map to their POSIX numbers" {
    try std.testing.expectEqual(Posix.einval, KernelError.einval.toPosix());
    try std.testing.expectEqual(Posix.enomem, KernelError.enomem.toPosix());
    try std.testing.expectEqual(Posix.eperm, KernelError.eperm.toPosix());
}

test "unmapped statuses collapse to eother" {
    // The base itself carries no error number.
    try std.testing.expectEqual(Posix.eother, kernelToPosix(@bitCast(kernel_error_base)));
    // Past the mapped range.
    try std.testing.expectEqual(Posix.eother, kernelToPosix(@bitCast(kernel_error_base | 200)));
    // Not a kernel status at all.
    try std.testing.expectEqual(Posix.eother, kernelToPosix(0));
    try std.testing.expectEqual(Posix.eother, kernelToPosix(-1));
}

test "posixToKernel round-trips through kernelToPosix" {
    const numbers = [_]i32{ 1, 2, 12, 22, 60, 78, 101 };
    for (numbers) |n| {
        try std.testing.expectEqual(n, kernelToPosix(posixToKernel(n)));
    }
}

test "failed distinguishes success from any status" {
    try std.testing.expect(!failed(ok));
    try std.testing.expect(failed(KernelError.einval.raw()));
}
