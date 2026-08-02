//! The calling convention boundary between guest and host code.
//!
//! Guest binaries are compiled for the System V AMD64 ABI. On Linux and macOS
//! that is also the host convention, so the boundary is invisible; on Windows
//! the host uses the Microsoft x64 convention, which passes different registers
//! and reserves shadow space on the stack.
//!
//! Every function the guest can call therefore has to be declared explicitly
//! with `callconv(abi.guest)`. Omitting it on Windows does not fail to compile —
//! it silently reads arguments from the wrong registers, which surfaces much
//! later as nonsensical parameter values. Declaring it through this one constant
//! keeps that decision in a single place.

const std = @import("std");
const builtin = @import("builtin");

/// The convention guest code expects of everything it calls.
pub const guest: std.builtin.CallingConvention = .{ .x86_64_sysv = .{} };

/// Whether host and guest conventions coincide on this target.
///
/// Only useful for diagnostics: correctness does not depend on it, because
/// entry points are annotated unconditionally.
pub const conventions_match = builtin.target.cpu.arch == .x86_64 and
    builtin.target.os.tag != .windows;

/// The signature every guest-callable entry point conforms to once erased.
///
/// The dynamic linker stores implementations as plain addresses and the guest
/// supplies its own arguments, so the recorded type only has to be callable —
/// the real signature lives with the implementation.
pub const RawEntryPoint = *const fn () callconv(guest) void;

/// Erases an entry point to the form the symbol database stores.
///
/// Accepts any function pointer, so a table of implementations with differing
/// signatures can be registered uniformly. The cast is sound because the guest
/// — not the host — decides how the call is made.
pub fn erase(function: anytype) RawEntryPoint {
    const T = @TypeOf(function);
    const info = @typeInfo(T);
    if (info != .pointer or @typeInfo(info.pointer.child) != .@"fn") {
        @compileError("expected a function pointer, found " ++ @typeName(T));
    }
    return @ptrCast(function);
}

test "the guest convention is System V regardless of host" {
    try std.testing.expect(guest == .x86_64_sysv);
}

test "erase accepts differing signatures" {
    const S = struct {
        fn noArgs() callconv(guest) void {}
        fn twoArgs(_: u64, _: i32) callconv(guest) i32 {
            return 0;
        }
    };

    const a = erase(&S.noArgs);
    const b = erase(&S.twoArgs);
    try std.testing.expect(a != b);
}
