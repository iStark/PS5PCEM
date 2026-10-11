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
};

comptime {
    std.debug.assert(@offsetOf(ThreadBlock, "host_fs") == 0);
    std.debug.assert(@offsetOf(ThreadBlock, "guest_fs") == 8);
}

/// Switches to the host FS base if the guest's is installed.
///
/// Returns the base that was replaced, or zero when nothing changed. Written
/// as one assembly block so that no host thread-local access can be scheduled
/// before it, and so that it touches no register besides RAX and R11.
pub inline fn enterHost() u64 {
    if (comptime !enabled) return 0;
    return asm volatile (
        \\  xorl %%eax, %%eax
        \\  rdgsbase %%r11
        \\  testq %%r11, %%r11
        \\  jz 1f
        \\  rdfsbase %%rax
        \\  movq (%%r11), %%r11
        \\  cmpq %%r11, %%rax
        \\  je 2f
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
        \\  movq 8(%%r11), %%r11
        \\  testq %%r11, %%r11
        \\  cmovzq %%rax, %%r11
        \\  wrfsbase %%r11
        \\1:
        :
        : [replaced] "{rax}" (replaced),
        : .{ .r11 = true, .cc = true, .memory = true });
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
