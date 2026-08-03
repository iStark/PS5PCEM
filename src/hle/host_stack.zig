// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Runs firmware on a stack of the host's own.
//!
//! A guest calls firmware directly, so firmware executes on the calling guest
//! thread's stack. That stack is sized by the title — commonly one megabyte —
//! while host code routinely needs far more: opening a file reserves a path
//! buffer of tens of kilobytes, and a compiler allocates a function's whole
//! frame on entry, before any branch can return early. The result is that a
//! firmware call can overrun the guest stack without ever reaching the code
//! that needed the room.
//!
//! Worse, the overrun lands outside any guest mapping, so the guest fault
//! handler declines it and the process dies with nothing to explain why.
//!
//! Every entry point therefore switches to a per-thread host stack for the
//! duration of the call. Arguments travel through memory rather than registers,
//! which keeps the assembly to a single function that knows nothing about any
//! signature: it takes a context pointer and a target, and returns nothing.

const std = @import("std");
const builtin = @import("builtin");

/// Size of each thread's firmware stack.
///
/// Chosen from what a title's own stack cannot supply rather than from
/// measurement of any one call: the point is to be comfortably clear of the
/// largest frame the host toolchain might place on it.
pub const stack_size: usize = 4 * 1024 * 1024;

/// Switching is only meaningful where guest and host share a stack in the first
/// place. Elsewhere the call runs directly and this whole layer is inert.
pub const supported = builtin.cpu.arch == .x86_64 and builtin.os.tag == .windows;

threadlocal var stack: ?[]align(16) u8 = null;
/// Guards against switching twice. Firmware calling firmware is common, and the
/// inner call must stay on the stack the outer one already established.
threadlocal var active: bool = false;

/// The top of this thread's firmware stack, or zero if it has none.
///
/// Allocation happens on first use and is deliberately small-framed, so it can
/// safely run on the guest stack that prompted it. A failure yields zero, which
/// makes the call proceed unswitched — degraded but working, which is better
/// than refusing a call the title needs.
fn top() u64 {
    if (stack) |value| return @intFromPtr(value.ptr) + value.len;

    const allocated = std.heap.page_allocator.alignedAlloc(u8, .@"16", stack_size) catch
        return 0;
    stack = allocated;
    return @intFromPtr(allocated.ptr) + allocated.len;
}

/// Releases this thread's firmware stack.
///
/// Worth calling when a guest thread ends; leaking one stack per thread would
/// otherwise accumulate over a title's lifetime.
pub fn release() void {
    if (stack) |value| std.heap.page_allocator.free(value);
    stack = null;
    active = false;
}

extern fn ps5HleCallOnStack(
    context: *anyopaque,
    target: *const fn (*anyopaque) callconv(.c) void,
    stack_top: u64,
) callconv(.c) void;

comptime {
    if (supported) asm (
    // Switches to `stack_top`, calls `target(context)`, and restores.
    //
    // The Microsoft x64 convention places context in rcx, target in rdx and the
    // new top in r8. Only r10 is used as scratch, and it is volatile, so
    // nothing the caller relies on is disturbed. Argument and return registers
    // are untouched by design: everything the call needs travels through the
    // context, so this works for any signature and any return type.
        \\.text
        \\.p2align 4
        \\.globl ps5HleCallOnStack
        \\ps5HleCallOnStack:
        \\  movq %rsp, %r10
        \\  movq %r8, %rsp
        \\  pushq %r10
        // The pushed word leaves rsp 8 past alignment. Thirty-two bytes of
        // shadow space are mandatory for the callee, and eight more restore the
        // sixteen-byte alignment the convention requires at the call.
        \\  subq $40, %rsp
        \\  callq *%rdx
        \\  addq $40, %rsp
        \\  popq %r10
        \\  movq %r10, %rsp
        \\  retq
    );
}

/// Calls `func` with `args` on this thread's firmware stack.
///
/// `args` is a tuple matching the function's parameters. The result travels
/// back through the same memory the arguments went out in, so floating-point
/// and aggregate returns need no special handling.
pub inline fn call(comptime Result: type, comptime func: anytype, args: anytype) Result {
    if (!supported or active) return @call(.auto, func, args);

    const stack_top = top();
    if (stack_top == 0) return @call(.auto, func, args);

    const Args = @TypeOf(args);
    const Frame = struct {
        arguments: Args,
        result: if (Result == void) void else Result,
    };

    const Invoker = struct {
        fn invoke(raw: *anyopaque) callconv(.c) void {
            const frame: *Frame = @ptrCast(@alignCast(raw));
            if (Result == void) {
                @call(.auto, func, frame.arguments);
            } else {
                frame.result = @call(.auto, func, frame.arguments);
            }
        }
    };

    var frame: Frame = .{ .arguments = args, .result = undefined };

    active = true;
    defer active = false;
    ps5HleCallOnStack(&frame, &Invoker.invoke, stack_top);

    if (Result == void) return;
    return frame.result;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn addThree(a: u64, b: u64, c: u64) u64 {
    return a + b + c;
}

fn returnsFloat(a: f64) f64 {
    return a * 2.0;
}

fn returnsNothing(out: *u64) void {
    out.* = 42;
}

/// Touches a frame far larger than a title's own stack would allow, which is
/// the situation this layer exists for.
fn largeFrame(seed: u8) u64 {
    var scratch: [1024 * 1024]u8 = undefined;
    // Both ends are written so the whole frame really has to exist.
    @memset(scratch[0..16], seed);
    scratch[scratch.len - 1] = seed;
    var total: u64 = 0;
    for (scratch[0..16]) |byte| total += byte;
    return total + scratch[scratch.len - 1];
}

test "a call returns its result unchanged" {
    try testing.expectEqual(@as(u64, 6), call(u64, addThree, .{ @as(u64, 1), @as(u64, 2), @as(u64, 3) }));
}

test "floating-point results survive the switch" {
    // The result travels through memory, so no register class needs special
    // handling.
    try testing.expectEqual(@as(f64, 5.0), call(f64, returnsFloat, .{@as(f64, 2.5)}));
}

test "a call returning nothing still runs" {
    var observed: u64 = 0;
    call(void, returnsNothing, .{&observed});
    try testing.expectEqual(@as(u64, 42), observed);
}

test "a frame larger than a guest stack is accommodated" {
    // One megabyte of locals is what a title's whole stack often is.
    try testing.expectEqual(@as(u64, 7 * 16 + 7), call(u64, largeFrame, .{@as(u8, 7)}));
}

test "nested calls stay on the stack the outer one established" {
    const Nested = struct {
        fn inner(value: u64) u64 {
            // Switching again here would abandon the outer frame.
            return value + 1;
        }
        fn outer(value: u64) u64 {
            if (supported) std.debug.assert(active);
            return call(u64, inner, .{value}) + 1;
        }
    };
    try testing.expectEqual(@as(u64, 3), call(u64, Nested.outer, .{@as(u64, 1)}));
}

test "the stack is released and reallocated on demand" {
    _ = call(u64, addThree, .{ @as(u64, 1), @as(u64, 1), @as(u64, 1) });
    release();
    try testing.expectEqual(@as(u64, 3), call(u64, addThree, .{ @as(u64, 1), @as(u64, 1), @as(u64, 1) }));
    release();
}
