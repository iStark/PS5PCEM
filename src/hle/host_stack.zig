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

/// Registers spilled on the interrupted stack before firmware switches stacks.
/// A conservative guest GC must scan from here, not from a host-stack local.
pub const SuspendedStack = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    return_address: u64,
};
threadlocal var suspended_stack: ?*const SuspendedStack = null;

/// A cooperative fiber may suspend inside a firmware call. Its host stack and
/// nesting flag must travel together: reusing another fiber's allocation would
/// overwrite that suspended call, while retaining `active` runs HLE on a small
/// guest stack. Windows switches the NT_TIB bounds with the native fiber.
pub const FiberState = struct {
    allocation: ?[]align(16) u8 = null,
    was_active: bool = false,
    suspended: ?*const SuspendedStack = null,

    pub fn deinit(self: *FiberState) void {
        if (self.allocation) |value| std.heap.page_allocator.free(value);
        self.* = .{};
    }
};

/// Move ownership of the current TLS stack into the suspended fiber, then take
/// the destination's stack. The caller must immediately perform SwitchToFiber.
pub fn switchFiberState(outgoing: *FiberState, incoming: *FiberState) void {
    std.debug.assert(outgoing != incoming and outgoing.allocation == null);
    outgoing.* = .{ .allocation = stack, .was_active = active, .suspended = suspended_stack };
    stack = incoming.allocation;
    active = incoming.was_active;
    suspended_stack = incoming.suspended;
    incoming.* = .{};
}

pub fn suspendedStack() ?*const SuspendedStack {
    return suspended_stack;
}

/// A native guest escape can bypass call's normal return and defers. Capture
/// at the native bridge boundary, including nested callbacks, so returning to
/// its saved stack also restores the corresponding Windows exception bounds.
pub const CallState = struct {
    was_active: bool,
    suspended: ?*const SuspendedStack,
    stack_base: u64,
    stack_limit: u64,

    pub fn capture() CallState {
        return .{
            .was_active = active,
            .suspended = suspended_stack,
            .stack_base = if (supported) asm volatile ("movq %%gs:8, %[value]"
                : [value] "=r" (-> u64),
            ) else 0,
            .stack_limit = if (supported) asm volatile ("movq %%gs:16, %[value]"
                : [value] "=r" (-> u64),
            ) else 0,
        };
    }

    pub fn restore(self: CallState) void {
        active = self.was_active;
        suspended_stack = self.suspended;
        if (supported) asm volatile (
            \\movq %[base], %%gs:8
            \\movq %[limit], %%gs:16
            :
            : [base] "r" (self.stack_base),
              [limit] "r" (self.stack_limit),
            : .{ .memory = true });
    }
};

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
    suspended_stack = null;
}

extern fn ps5HleCallOnStack(
    context: *anyopaque,
    target: *const fn (*anyopaque) callconv(.c) void,
    stack_top: u64,
    saved_stack: *?*const SuspendedStack,
) callconv(.c) void;

comptime {
    if (supported) asm (
    // Switches to `stack_top`, calls `target(context)`, and restores.
    //
    // The Microsoft x64 convention places context in rcx, target in rdx and the
    // new top in r8 and saved_stack in r9. Spill all SysV nonvolatile GPRs on
    // the original stack so roots held only in registers remain visible when
    // a guest signal suspends this call for garbage collection.
        \\.text
        \\.p2align 4
        \\.globl ps5HleCallOnStack
        \\ps5HleCallOnStack:
        \\  pushq %rbx
        \\  pushq %rbp
        \\  pushq %r12
        \\  pushq %r13
        \\  pushq %r14
        \\  pushq %r15
        \\  movq %rsp, %r10
        \\  movq %r10, (%r9)
        \\  movq %gs:8, %rax
        \\  movq %gs:16, %r11
        \\  movq %r8, %rsp
        \\  pushq %r10
        \\  pushq %rax
        \\  pushq %r11
        // Windows validates frames against NT_TIB.StackBase/StackLimit during
        // SEH dispatch. Leaving the original bounds here makes even a handled
        // OutputDebugString exception terminate a non-debugged process.
        \\  movq %r8, %gs:8
        \\  leaq -4194304(%r8), %rax
        \\  movq %rax, %gs:16
        // Three pushed words leave rsp 8 past alignment. Thirty-two bytes of
        // shadow space are mandatory for the callee, and eight more restore the
        // sixteen-byte alignment the convention requires at the call.
        \\  subq $40, %rsp
        \\  callq *%rdx
        \\  addq $40, %rsp
        \\  popq %r11
        \\  movq %r11, %gs:16
        \\  popq %rax
        \\  movq %rax, %gs:8
        \\  popq %r10
        \\  movq %r10, %rsp
        \\  popq %r15
        \\  popq %r14
        \\  popq %r13
        \\  popq %r12
        \\  popq %rbp
        \\  popq %rbx
        \\  retq
    );
}

noinline fn finishCall() void {
    // A firmware call may yield a fiber and resume on a different OS thread.
    // Resolve TLS after the switch, never through an address cached on entry.
    active = false;
    suspended_stack = null;
}

/// Calls `func` with `args` on this thread's firmware stack.
///
/// `args` is a tuple matching the function's parameters. The result travels
/// back through the same memory the arguments went out in, so floating-point
/// and aggregate returns need no special handling.
pub fn call(comptime Result: type, comptime func: anytype, args: anytype) Result {
    // Keep the firmware implementation outside this dispatcher.  Inlining it
    // into either fallback branch makes LLVM reserve the implementation's
    // entire frame before we have switched stacks.  Codec entry points can
    // need hundreds of kilobytes even when the switched path is the one that
    // will actually run.
    if (!supported or active) return @call(.never_inline, func, args);

    const stack_top = top();
    if (stack_top == 0) return @call(.never_inline, func, args);

    const Args = @TypeOf(args);
    const Frame = struct {
        arguments: Args,
        result: if (Result == void) void else Result,
    };

    const Invoker = struct {
        fn invoke(raw: *anyopaque) callconv(.c) void {
            const frame: *Frame = @ptrCast(@alignCast(raw));
            if (Result == void) {
                @call(.never_inline, func, frame.arguments);
            } else {
                frame.result = @call(.never_inline, func, frame.arguments);
            }
        }
    };

    var frame: Frame = .{ .arguments = args, .result = undefined };

    active = true;
    defer finishCall();
    ps5HleCallOnStack(&frame, &Invoker.invoke, stack_top, &suspended_stack);

    if (Result == void) return;
    return frame.result;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const DebugOutput = struct {
    extern "kernel32" fn OutputDebugStringA([*:0]const u8) callconv(.winapi) void;
    extern "kernel32" fn OutputDebugStringW([*:0]const u16) callconv(.winapi) void;
};

test "Windows debug output returns on firmware stacks and restores native bounds" {
    if (!supported) return error.SkipZigTest;
    defer release();
    const original = CallState.capture();
    const Probe = struct {
        fn output() !void {
            var local: u64 = 0;
            const state = CallState.capture();
            try testing.expect(state.was_active);
            try testing.expect(@intFromPtr(&local) >= state.stack_limit);
            try testing.expect(@intFromPtr(&local) < state.stack_base);
            try testing.expectEqual(@as(u64, stack_size), state.stack_base - state.stack_limit);
            DebugOutput.OutputDebugStringA("PS5PCEM firmware stack regression");
            DebugOutput.OutputDebugStringW(std.unicode.utf8ToUtf16LeStringLiteral("PS5PCEM firmware stack regression"));
        }
        fn nested() !void {
            const before = CallState.capture();
            try call(anyerror!void, output, .{});
            try testing.expectEqualDeep(before, CallState.capture());
        }
    };
    try call(anyerror!void, Probe.nested, .{});
    try testing.expectEqualDeep(original, CallState.capture());
    DebugOutput.OutputDebugStringA("PS5PCEM restored native stack regression");
}

comptime {
    std.debug.assert(@sizeOf(SuspendedStack) == 7 * @sizeOf(u64));
    std.debug.assert(stack_size == 4194304); // Shared with the switch assembly.
    if (supported and builtin.is_test) asm (
        \\.text
        \\.p2align 4
        \\.globl ps5HleTestRegisterRoot
        \\ps5HleTestRegisterRoot:
        \\  pushq %r12
        \\  subq $32, %rsp
        \\  movabsq $0x1234567887654321, %r12
        \\  callq ps5HleCallOnStack
        \\  movq %r12, %rax
        \\  addq $32, %rsp
        \\  popq %r12
        \\  retq
    );
}

extern fn ps5HleTestRegisterRoot(
    context: *anyopaque,
    target: *const fn (*anyopaque) callconv(.c) void,
    stack_top: u64,
    saved_stack: *?*const SuspendedStack,
) callconv(.c) u64;

test "register-only roots are spilled before switching firmware stacks" {
    if (!supported) return error.SkipZigTest;
    defer release();
    const Probe = struct {
        fn invoke(raw: *anyopaque) callconv(.c) void {
            const observed: *u64 = @ptrCast(@alignCast(raw));
            observed.* = suspendedStack().?.r12;
        }
    };
    var observed: u64 = 0;
    const marker: u64 = 0x1234567887654321;
    const stack_top = top();
    try testing.expect(stack_top != 0);
    const preserved = ps5HleTestRegisterRoot(&observed, &Probe.invoke, stack_top, &suspended_stack);
    try testing.expectEqual(marker, observed);
    try testing.expectEqual(marker, preserved);
    suspended_stack = null;
}

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
