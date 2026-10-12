// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Keeps the guest's FS base away from host code on Linux.
//!
//! Guest code keeps its thread pointer in FS, and native execution installs it
//! there. Windows x64 uses GS for its own thread block, so host code is
//! unaffected and nothing here does anything on Windows. Linux x86-64 keeps the
//! host's thread-local storage in FS as well: glibc, and every Zig `threadlocal`,
//! read through it. Host code entered from the guest must therefore switch FS to
//! the host value first, and switch back before returning.
//!
//! The values needed for that switch cannot live in thread-local storage, since
//! reaching it is exactly what is not possible yet. Each OS thread that runs
//! guest code instead points GS, unused by Linux user space, at a small block
//! holding the host FS base and the FS base of the guest thread it currently
//! runs. A thread that has never run guest code has a zero GS base, which these
//! routines take to mean the host FS is already in place.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this build switches FS at firmware entry points.
pub const enabled = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;

/// The per-OS-thread block GS points at. The offsets are read by assembly.
pub const ThreadBlock = extern struct {
    /// FS base of the host thread: its glibc/Zig thread pointer.
    host_fs: u64,
    /// FS base of the guest thread executing on this host thread, or zero
    /// outside native execution. Nested callbacks of one guest thread share it.
    guest_fs: u64,
    /// Syscall User Dispatch selector: `syscall_block` while guest code runs,
    /// `syscall_allow` while host code does. A guest `syscall` instruction
    /// would otherwise execute a Linux call with a FreeBSD number; blocked, it
    /// raises SIGSYS and the fault handler answers it (see the cpu module).
    syscall_selector: u8 = syscall_allow,
    padding: [7]u8 = @splat(0),
};

pub const syscall_allow: u8 = 0;
pub const syscall_block: u8 = 1;

comptime {
    std.debug.assert(@offsetOf(ThreadBlock, "host_fs") == 0);
    std.debug.assert(@offsetOf(ThreadBlock, "guest_fs") == 8);
    std.debug.assert(@offsetOf(ThreadBlock, "syscall_selector") == 16);
}

test "guest thread pointers lie below the shift that enterHost tests" {
    const memory = @import("memory");
    // The assembly tests `FS >> 40`; every guest range must end below it.
    for (memory.guest_ranges) |range| {
        try std.testing.expect(range.end <= (@as(u64, 1) << guest_address_limit_shift));
    }
}

/// Guest thread pointers live in the console's address window, which ends
/// below 1 TiB. Host thread-local storage never does: glibc places it in the
/// mmap region near 128 TiB, and the runner itself is linked at 2 TiB.
pub const guest_address_limit_shift = 40;

/// Switches to the host FS base if the guest's is installed.
///
/// Returns the base that was replaced, or zero when nothing changed. Written
/// as one assembly block so that no host thread-local access can be scheduled
/// before it, and so that it touches no register besides RAX and R11.
///
/// The decision rests on where FS points, not merely on GS being set. A thread
/// created from a guest worker, by a host library or by the runner itself,
/// inherits that worker's GS base with its own host FS; comparing FS against
/// the block's host value would then install another thread's storage.
pub inline fn enterHost() u64 {
    if (comptime !enabled) return 0;
    return asm volatile (
        \\  xorl %%eax, %%eax
        \\  rdgsbase %%r11
        \\  testq %%r11, %%r11
        \\  jz 1f
        \\  rdfsbase %%rax
        \\  movq %%rax, %%r11
        \\  shrq $40, %%r11
        \\  jnz 2f
        \\  rdgsbase %%r11
        \\  movb $0, 16(%%r11)
        \\  movq (%%r11), %%r11
        \\  wrfsbase %%r11
        \\  jmp 1f
        \\2:
        \\  xorl %%eax, %%eax
        \\1:
        : [replaced] "={rax}" (-> u64),
        :
        : .{ .r11 = true, .cc = true, .memory = true });
}

/// Undoes `enterHost`.
///
/// The guest base reinstalled is the one this host thread is running now, not
/// necessarily `replaced`: a cooperative fiber can suspend inside a firmware
/// call and resume on another host thread, whose guest thread pointer differs.
pub inline fn leaveHost(replaced: u64) void {
    if (comptime !enabled) return;
    if (replaced == 0) return;
    asm volatile (
        \\  rdgsbase %%r11
        \\  testq %%r11, %%r11
        \\  jz 1f
        \\  movb $1, 16(%%r11)
        \\  movq 8(%%r11), %%r11
        \\  testq %%r11, %%r11
        \\  cmovzq %%rax, %%r11
        \\  wrfsbase %%r11
        \\1:
        :
        : [replaced] "{rax}" (replaced),
        : .{ .r11 = true, .cc = true, .memory = true });
}

/// Installs this host thread's guest FS base before host code calls guest code
/// directly rather than through the native bridge, as a fiber entry does.
///
/// Returns the host base to hand to `leaveGuest`, or zero when this thread runs
/// no guest code (FS is then left alone).
pub inline fn enterGuest() u64 {
    if (comptime !enabled) return 0;
    const block = currentBlock() orelse return 0;
    if (block.guest_fs == 0) return 0;
    setSyscallSelector(block, syscall_block);
    // The output is early-clobber: it is written before the input is read, so
    // the two must not share a register. Sharing one made RDFSBASE overwrite
    // the guest value and WRFSBASE reinstall the host base, and fiber code ran
    // reading host thread-local storage as its own.
    return asm volatile (
        \\  rdfsbase %[host]
        \\  wrfsbase %[guest]
        : [host] "=&r" (-> u64),
        : [guest] "r" (block.guest_fs),
        : .{ .memory = true });
}

/// Returns to the host FS base after `enterGuest`.
pub inline fn leaveGuest(host: u64) void {
    if (comptime !enabled) return;
    if (host == 0) return;
    asm volatile ("wrfsbase %[host]"
        :
        : [host] "r" (host),
        : .{ .memory = true });
    if (currentBlock()) |block| setSyscallSelector(block, syscall_allow);
}

/// The kernel reads the selector on every system call, so the store must not
/// be reordered or elided.
pub fn setSyscallSelector(block: *ThreadBlock, value: u8) void {
    const selector: *volatile u8 = &block.syscall_selector;
    selector.* = value;
}

/// The block GS points at on this thread, or null if it has none yet.
pub fn currentBlock() ?*ThreadBlock {
    if (comptime !enabled) return null;
    const address = asm volatile ("rdgsbase %[address]"
        : [address] "=r" (-> u64),
    );
    return if (address == 0) null else @ptrFromInt(address);
}

/// Points GS at `block` for the calling thread.
pub fn install(block: *ThreadBlock) void {
    if (comptime !enabled) return;
    asm volatile ("wrgsbase %[address]"
        :
        : [address] "r" (@intFromPtr(block)),
        : .{ .memory = true });
}

pub fn readFsBase() u64 {
    if (comptime !enabled) return 0;
    return asm volatile ("rdfsbase %[base]"
        : [base] "=r" (-> u64),
    );
}
