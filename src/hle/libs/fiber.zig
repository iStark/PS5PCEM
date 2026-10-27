// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Cooperative libSceFiber execution for native x86-64 guests.
//!
//! Guest code runs natively, so a fiber cannot be represented by a function
//! that merely returns success: switching has to preserve the guest register
//! and stack state at the call site.  On Windows the host fiber API already
//! provides precisely that mechanism.  A guest fiber is backed by one host
//! fiber, while the thread that called sceFiberRun is the root fiber.
//!
//! The PS5-supplied context buffer is still recorded in the public ABI object,
//! but Windows owns the actual backing stack.  Using the title's buffer as a
//! native Windows stack would bypass guard-page and unwind bookkeeping that the
//! operating system requires.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const symbols = @import("../symbols.zig");
const kernel_memory = @import("kernel_memory.zig");
const memory = @import("memory");
const host_stack = @import("../host_stack.zig");
const guest_fs = @import("../guest_fs.zig");

const supported = builtin.cpu.arch == .x86_64 and
    (builtin.os.tag == .windows or builtin.os.tag == .linux);

/// The host fiber's start routine is called by Windows with WINAPI, and by
/// the Linux switch trampoline with the C convention.
const entry_convention: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

const error_null: i32 = @bitCast(@as(u32, 0x8059_0001));
const error_alignment: i32 = @bitCast(@as(u32, 0x8059_0002));
const error_range: i32 = @bitCast(@as(u32, 0x8059_0003));
const error_invalid: i32 = @bitCast(@as(u32, 0x8059_0004));
const error_permission: i32 = @bitCast(@as(u32, 0x8059_0005));
const error_state: i32 = @bitCast(@as(u32, 0x8059_0006));

const signature_start: u32 = 0xdef1_649c;
const signature_end: u32 = 0xb375_92a0;
const stack_signature: u64 = 0x7149_f2ca_7149_f2ca;
const state_run: u32 = 1;
const state_idle: u32 = 2;
const state_terminated: u32 = 3;
const minimum_context_size: u64 = 512;

/// Public 128-byte SceFiber record written by the firmware library.
const Fiber = extern struct {
    signature: u32,
    state: u32,
    entry: u64,
    argument_on_initialize: u64,
    context_address: u64,
    context_size: u64,
    name: [32]u8,
    context_pointer: u64,
    flags: u32,
    context_start: u64,
    context_end: u64,
    end_signature: u32,
    reserved: [20]u8,
};

const FiberInfo = extern struct {
    size: u64 = 128,
    entry: u64 = 0,
    argument_on_initialize: u64 = 0,
    context_address: u64 = 0,
    context_size: u64 = 0,
    name: [32]u8 = @splat(0),
    context_margin: u64 = std.math.maxInt(u64),
    reserved: [48]u8 = @splat(0),
};

comptime {
    if (@sizeOf(FiberInfo) != 128 or @offsetOf(FiberInfo, "context_margin") != 72)
        @compileError("SceFiberInfo ABI layout mismatch");
    if (@sizeOf(Fiber) != 128) @compileError("SceFiber ABI size must be 128 bytes");
    if (@offsetOf(Fiber, "context_pointer") != 72) @compileError("SceFiber context pointer offset mismatch");
    if (@offsetOf(Fiber, "context_start") != 88) @compileError("SceFiber context start offset mismatch");
    if (@offsetOf(Fiber, "end_signature") != 104) @compileError("SceFiber end signature offset mismatch");
}

const Host = if (builtin.os.tag == .linux) LinuxHost else struct {
    const StartRoutine = *const fn (?*anyopaque) callconv(.winapi) void;

    extern "kernel32" fn ConvertThreadToFiberEx(
        parameter: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CreateFiberEx(
        commit_size: usize,
        reserve_size: usize,
        flags: u32,
        start: StartRoutine,
        parameter: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn SwitchToFiber(fiber: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn DeleteFiber(fiber: *anyopaque) callconv(.winapi) void;
};

/// The four Windows fiber calls this file relies on, for Linux.
///
/// A fiber is a saved stack pointer. Switching pushes the System V callee-saved
/// registers onto the current stack, stores the stack pointer, loads the
/// target's and pops the same frame. Like a Windows fiber created without
/// FIBER_FLAG_FLOAT_SWITCH, it leaves MXCSR and the x87 control word alone, so
/// every fiber sees the thread's floating-point mode, FTZ/DAZ included. A new
/// fiber's stack is prepared so that the first switch to it pops into a
/// trampoline that calls the start routine. As with Windows fibers, a fiber
/// suspended on one thread can be resumed on another.
const LinuxHost = struct {
    const StartRoutine = *const fn (?*anyopaque) callconv(.c) void;
    /// What Windows reserves for a fiber whose reserve size is zero.
    const default_stack_size: usize = 1024 * 1024;

    const Context = struct {
        /// Saved stack pointer while the fiber is suspended.
        stack_pointer: u64 = 0,
        /// Owned stack of a created fiber; a converted thread keeps its own.
        stack: []align(std.heap.page_size_min) u8 = &.{},
    };

    threadlocal var current: ?*Context = null;

    fn ConvertThreadToFiberEx(_: ?*anyopaque, _: u32) ?*anyopaque {
        const context = std.heap.page_allocator.create(Context) catch return null;
        context.* = .{};
        current = context;
        return context;
    }

    fn CreateFiberEx(_: usize, reserve_size: usize, _: u32, start: StartRoutine, parameter: ?*anyopaque) ?*anyopaque {
        const size = std.mem.alignForward(usize, @max(if (reserve_size == 0) default_stack_size else reserve_size, 64 * 1024), std.heap.page_size_min);
        // Below 1 TiB like a Windows fiber stack: guest code packs these
        // addresses into 40-bit fields (see memory.low_host).
        const stack = memory.low_host.alloc(size) orelse return null;
        const context = std.heap.page_allocator.create(Context) catch {
            memory.low_host.free(stack);
            return null;
        };
        // The first switch pops this frame: an unused word, r15, r14, r13 (the
        // parameter), r12 (the start routine), rbx, rbp, then returns into the
        // trampoline with the stack aligned as at a function entry.
        const top = std.mem.alignBackward(u64, @intFromPtr(stack.ptr) + stack.len, 16);
        const frame: [*]u64 = @ptrFromInt(top - 72);
        frame[0] = 0; // keeps the frame the same size as a suspended fiber's
        frame[1] = 0; // r15
        frame[2] = 0; // r14
        frame[3] = @intFromPtr(parameter); // r13
        frame[4] = @intFromPtr(start); // r12
        frame[5] = 0; // rbx
        frame[6] = 0; // rbp
        frame[7] = @intFromPtr(&ps5LinuxFiberStart);
        context.* = .{ .stack_pointer = top - 72, .stack = stack };
        return context;
    }

    fn SwitchToFiber(raw_target: *anyopaque) void {
        const target: *Context = @ptrCast(@alignCast(raw_target));
        const source = current orelse return;
        current = target;
        ps5LinuxFiberSwitch(&source.stack_pointer, target.stack_pointer);
    }

    fn DeleteFiber(raw_fiber: *anyopaque) void {
        const context: *Context = @ptrCast(@alignCast(raw_fiber));
        if (context.stack.len != 0) memory.low_host.free(context.stack);
        std.heap.page_allocator.destroy(context);
    }

    extern fn ps5LinuxFiberSwitch(save: *u64, load: u64) callconv(.c) void;
    extern fn ps5LinuxFiberStart() callconv(.c) void;

    comptime {
        if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux) asm (
            \\.text
            \\.p2align 4
            \\.globl ps5LinuxFiberSwitch
            \\ps5LinuxFiberSwitch:
            \\  pushq %rbp
            \\  pushq %rbx
            \\  pushq %r12
            \\  pushq %r13
            \\  pushq %r14
            \\  pushq %r15
            \\  subq $8, %rsp
            \\  movq %rsp, (%rdi)
            \\  movq %rsi, %rsp
            \\  addq $8, %rsp
            \\  popq %r15
            \\  popq %r14
            \\  popq %r13
            \\  popq %r12
            \\  popq %rbx
            \\  popq %rbp
            \\  retq
            \\.p2align 4
            \\.globl ps5LinuxFiberStart
            \\ps5LinuxFiberStart:
            \\  subq $8, %rsp
            \\  movq %r13, %rdi
            \\  callq *%r12
            \\  ud2
        );
    }
};

const RuntimeFiber = struct {
    guest: *Fiber,
    host: ?*anyopaque = null,
    entry: u64,
    argument_on_initialize: u64,
    context_size: u64,
    incoming_argument: u64 = 0,
    waiting_output: ?*u64 = null,
    firmware_state: host_stack.FiberState = .{},
};

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

var registry_lock: Lock = .{};
var registry: std.AutoHashMapUnmanaged(usize, *RuntimeFiber) = .{};

threadlocal var root_fiber: ?*anyopaque = null;
threadlocal var current_fiber: ?*RuntimeFiber = null;
threadlocal var root_incoming_argument: u64 = 0;
threadlocal var root_waiting_output: ?*u64 = null;
threadlocal var root_firmware_state: host_stack.FiberState = .{};

fn accessible(address: usize, size: usize) bool {
    return address != 0 and kernel_memory.isGuestRangeAccessible(address, size);
}

fn writeArgument(output: ?*u64, value: u64) bool {
    const pointer = output orelse return true;
    if (!accessible(@intFromPtr(pointer), @sizeOf(u64))) return false;
    pointer.* = value;
    return true;
}

fn validFiber(fiber: *const Fiber) bool {
    return accessible(@intFromPtr(fiber), @sizeOf(Fiber)) and
        fiber.signature == signature_start and fiber.end_signature == signature_end;
}

fn ensureRootFiber() bool {
    if (!supported) return false;
    if (root_fiber != null) return true;
    root_fiber = Host.ConvertThreadToFiberEx(null, 0);
    return root_fiber != null;
}

fn ensureHostFiber(runtime_fiber: *RuntimeFiber) bool {
    if (!ensureRootFiber()) return false;
    if (runtime_fiber.host != null) return true;

    const reserve_size: usize = if (runtime_fiber.context_size == 0)
        0
    else
        std.math.cast(usize, runtime_fiber.context_size) orelse return false;
    runtime_fiber.host = Host.CreateFiberEx(
        0,
        reserve_size,
        0,
        &fiberEntry,
        runtime_fiber,
    );
    return runtime_fiber.host != null;
}

/// Host-fiber entry trampoline.  The entry function itself uses the guest
/// System V convention even though the Windows trampoline uses WINAPI.
fn fiberEntry(parameter: ?*anyopaque) callconv(entry_convention) void {
    const runtime_fiber: *RuntimeFiber = @ptrCast(@alignCast(parameter.?));
    completeSwitch(runtime_fiber);
    const entry: *const fn (u64, u64) callconv(abi.guest) void = @ptrFromInt(runtime_fiber.entry);
    const argument_on_initialize = runtime_fiber.argument_on_initialize;
    const incoming_argument = runtime_fiber.incoming_argument;
    // Called directly rather than through the bridge, so on Linux the guest
    // thread pointer has to be installed here; Windows leaves FS to the guest.
    const host_fs = guest_fs.enterGuest();
    entry(argument_on_initialize, incoming_argument);
    guest_fs.leaveGuest(host_fs);

    // Returning from an entry function terminates it and hands control back to
    // the root thread.  A finalized fiber is never resumed at this point.
    terminateFiber(runtime_fiber);
}

// The registry lock stays held across SwitchToFiber. The destination releases
// it only after Windows has saved the source context; otherwise another worker
// could resume an "idle" source while it is still executing the switch itself.
// Keep post-switch TLS access out of the switching function: a suspended call
// can resume on another OS thread, so cached TLS addresses are no longer valid.
noinline fn completeSwitch(resumed: ?*RuntimeFiber) void {
    current_fiber = resumed;
    registry_lock.unlock();
}

noinline fn terminateFiber(value: *RuntimeFiber) noreturn {
    registry_lock.lock();
    value.guest.state = state_terminated;
    root_incoming_argument = 0;
    current_fiber = null;
    const root = root_fiber.?;
    host_stack.switchFiberState(&value.firmware_state, &root_firmware_state);
    Host.SwitchToFiber(root);
    unreachable;
}

/// _sceFiberInitializeImpl has two stack arguments after the six System V
/// register arguments: option pointer and SDK build version.
fn initialize(
    fiber: ?*Fiber,
    name: ?[*:0]const u8,
    entry: u64,
    argument_on_initialize: u64,
    context_address: u64,
    context_size: u64,
    option: u64,
    build_version: u64,
) callconv(abi.guest) i32 {
    _ = option;
    _ = build_version;
    const value = fiber orelse return error_null;
    const name_bytes = name orelse return error_null;
    if (entry == 0) return error_null;
    if ((@intFromPtr(value) & 7) != 0 or (context_address & 15) != 0) return error_alignment;
    if (context_size != 0 and context_size < minimum_context_size) return error_range;
    if ((context_size & 15) != 0 or (context_address == 0) != (context_size == 0)) return error_invalid;
    if (!accessible(@intFromPtr(value), @sizeOf(Fiber))) return error_invalid;

    var copied_name: [32]u8 = @splat(0);
    var name_terminated = false;
    for (0..copied_name.len) |index| {
        const address = @intFromPtr(name_bytes) + index;
        if (!accessible(address, 1)) return error_invalid;
        const byte: u8 = @as(*const u8, @ptrFromInt(address)).*;
        if (byte == 0) {
            name_terminated = true;
            break;
        }
        if (index + 1 == copied_name.len) return error_range;
        copied_name[index] = byte;
    }
    if (!name_terminated) return error_range;

    registry_lock.lock();
    defer registry_lock.unlock();
    if (registry.contains(@intFromPtr(value))) return error_state;

    const runtime_fiber = std.heap.page_allocator.create(RuntimeFiber) catch return error_invalid;
    errdefer std.heap.page_allocator.destroy(runtime_fiber);
    runtime_fiber.* = .{
        .guest = value,
        .entry = entry,
        .argument_on_initialize = argument_on_initialize,
        .context_size = context_size,
    };
    registry.put(std.heap.page_allocator, @intFromPtr(value), runtime_fiber) catch return error_invalid;

    value.* = .{
        .signature = signature_start,
        .state = state_idle,
        .entry = entry,
        .argument_on_initialize = argument_on_initialize,
        .context_address = context_address,
        .context_size = context_size,
        .name = copied_name,
        .context_pointer = 0,
        .flags = 0,
        .context_start = context_address,
        .context_end = if (context_address == 0) 0 else context_address + context_size,
        .end_signature = signature_end,
        .reserved = @splat(0),
    };
    if (context_address != 0) {
        if (!accessible(@intCast(context_address), @sizeOf(u64))) return error_invalid;
        @as(*u64, @ptrFromInt(context_address)).* = stack_signature;
    }
    return 0;
}

/// Initializes a fiber option block from its leading size field, following
/// Sony's sized-structure convention (as in `JpegEncCreateParam.this_size`).
/// The layout past the size is not known, so only the claimed bytes are
/// zeroed, capped to keep a corrupt size from clearing the neighborhood.
/// Downstream `_sceFiberInitializeImpl` ignores the option block, which is
/// what makes defaults-by-zeroing observationally complete here.
fn optParamInitialize(option: ?*anyopaque) callconv(abi.guest) i32 {
    const base = @intFromPtr(option orelse return error_null);
    if (!accessible(base, 4)) return error_invalid;
    const size = std.mem.readInt(u32, @as(*const [4]u8, @ptrFromInt(base)), .little);
    if (size == 0 or size > 256) return error_invalid;
    if (!accessible(base, size)) return error_invalid;
    @memset(@as([*]u8, @ptrFromInt(base))[0..size], 0);
    return 0;
}

fn finalize(fiber: ?*Fiber) callconv(abi.guest) i32 {    const value = fiber orelse return error_null;
    if (!validFiber(value)) return error_invalid;

    registry_lock.lock();
    defer registry_lock.unlock();
    const removed = registry.fetchRemove(@intFromPtr(value)) orelse return error_invalid;
    const runtime_fiber = removed.value;
    if (value.state == state_run or current_fiber == runtime_fiber) {
        registry.put(std.heap.page_allocator, removed.key, runtime_fiber) catch {};
        return error_state;
    }
    if (supported) if (runtime_fiber.host) |host| Host.DeleteFiber(host);
    runtime_fiber.firmware_state.deinit();
    std.heap.page_allocator.destroy(runtime_fiber);
    value.state = state_terminated;
    return 0;
}

fn transfer(
    fiber: ?*Fiber,
    argument_on_run: u64,
    argument_on_return: ?*u64,
    is_switch: bool,
) i32 {
    const value = fiber orelse return error_null;
    if (!validFiber(value)) return error_invalid;
    if (argument_on_return != null and
        !accessible(@intFromPtr(argument_on_return.?), @sizeOf(u64))) return error_invalid;

    const source = current_fiber;
    if (is_switch != (source != null)) return error_permission;
    registry_lock.lock();
    var switching = false;
    defer if (!switching) registry_lock.unlock();
    const target = registry.get(@intFromPtr(value)) orelse return error_invalid;
    if (target == source or value.state != state_idle) return error_state;
    if (!ensureHostFiber(target)) return error_permission;

    if (source) |from| {
        from.waiting_output = argument_on_return;
        from.guest.state = state_idle;
    } else {
        root_waiting_output = argument_on_return;
    }
    target.incoming_argument = argument_on_run;
    target.guest.state = state_run;
    current_fiber = target;
    host_stack.switchFiberState(if (source) |from| &from.firmware_state else &root_firmware_state, &target.firmware_state);
    switching = true;
    Host.SwitchToFiber(target.host.?);
    completeSwitch(source);

    // Execution resumes here only after another fiber explicitly targets this
    // caller (or returns to the root thread).
    if (source) |from| {
        if (!writeArgument(from.waiting_output, from.incoming_argument)) return error_invalid;
    } else {
        if (!writeRootArgument()) return error_invalid;
    }
    return 0;
}

noinline fn writeRootArgument() bool {
    return writeArgument(root_waiting_output, root_incoming_argument);
}

fn run(fiber: ?*Fiber, argument_on_run: u64, argument_on_return: ?*u64) callconv(abi.guest) i32 {
    return transfer(fiber, argument_on_run, argument_on_return, false);
}

fn switchTo(fiber: ?*Fiber, argument_on_run: u64, argument_on_return: ?*u64) callconv(abi.guest) i32 {
    return transfer(fiber, argument_on_run, argument_on_return, true);
}

fn returnToThread(argument_on_return: u64, next_argument_on_run: ?*u64) callconv(abi.guest) i32 {
    const source = current_fiber orelse return error_permission;
    if (next_argument_on_run != null and
        !accessible(@intFromPtr(next_argument_on_run.?), @sizeOf(u64))) return error_invalid;
    const root = root_fiber orelse return error_permission;

    registry_lock.lock();
    source.waiting_output = next_argument_on_run;
    source.guest.state = state_idle;
    root_incoming_argument = argument_on_return;
    current_fiber = null;
    host_stack.switchFiberState(&source.firmware_state, &root_firmware_state);
    Host.SwitchToFiber(root);

    // A later sceFiberRun of this same object resumes the suspended call.
    completeSwitch(source);
    if (!writeArgument(source.waiting_output, source.incoming_argument)) return error_invalid;
    return 0;
}

fn getSelf(output: ?**Fiber) callconv(abi.guest) i32 {
    const result = output orelse return error_null;
    if (!accessible(@intFromPtr(result), @sizeOf(*Fiber))) return error_invalid;
    const active = current_fiber orelse return error_permission;
    result.* = active.guest;
    return 0;
}

fn writable(address: usize, size: usize) bool {
    if (!accessible(address, size)) return false;
    if (kernel_memory.attachedAddressSpace()) |space| {
        return space.isWritable(address, size) or memory.isHostRangeWritable(address, size);
    }
    return true;
}

fn notifyWrite(address: usize, size: usize) void {
    if (kernel_memory.attachedAddressSpace()) |space| space.notifyGuestWrite(address, size);
}

fn getInfo(fiber: ?*Fiber, output: ?*FiberInfo) callconv(abi.guest) i32 {
    const value = fiber orelse return error_null;
    const info = output orelse return error_null;
    if ((@intFromPtr(value) & 7) != 0 or (@intFromPtr(info) & 7) != 0) return error_alignment;
    if (!writable(@intFromPtr(info), @sizeOf(FiberInfo)) or info.size != @sizeOf(FiberInfo)) return error_invalid;
    registry_lock.lock();
    defer registry_lock.unlock();
    if (!validFiber(value) or !registry.contains(@intFromPtr(value))) return error_invalid;
    // Snapshot before writing, including when the caller aliases the records.
    const snapshot = value.*;
    notifyWrite(@intFromPtr(info), @offsetOf(FiberInfo, "reserved"));
    info.entry = snapshot.entry;
    info.argument_on_initialize = snapshot.argument_on_initialize;
    info.context_address = snapshot.context_address;
    info.context_size = snapshot.context_size;
    info.name = snapshot.name;
    // Context-size checking is not enabled by this implementation. The ABI
    // uses -1 for unavailable margin, not an invented amount of free stack.
    info.context_margin = std.math.maxInt(u64);
    return 0;
}

fn rename(fiber: ?*Fiber, name: ?[*:0]const u8) callconv(abi.guest) i32 {
    const value = fiber orelse return error_null;
    const input = name orelse return error_null;
    if ((@intFromPtr(value) & 7) != 0) return error_alignment;
    registry_lock.lock();
    defer registry_lock.unlock();
    if (!validFiber(value) or !registry.contains(@intFromPtr(value))) return error_invalid;
    if (!writable(@intFromPtr(&value.name), value.name.len)) return error_invalid;
    // Firmware names are truncated to 31 bytes and always NUL terminated.
    // Copy first so renaming from the current name or a suffix is safe.
    var copied: [32]u8 = @splat(0);
    for (0..copied.len - 1) |index| {
        const address = std.math.add(usize, @intFromPtr(input), index) catch return error_invalid;
        if (!accessible(address, 1)) return error_invalid;
        const byte = @as(*const u8, @ptrFromInt(address)).*;
        if (byte == 0) break;
        copied[index] = byte;
    }
    notifyWrite(@intFromPtr(&value.name), value.name.len);
    value.name = copied;
    return 0;
}

pub fn reset() void {
    registry_lock.lock();
    defer registry_lock.unlock();
    var values = registry.valueIterator();
    while (values.next()) |runtime_fiber| {
        if (supported) if (runtime_fiber.*.host) |host| Host.DeleteFiber(host);
        runtime_fiber.*.firmware_state.deinit();
        std.heap.page_allocator.destroy(runtime_fiber.*);
    }
    registry.deinit(std.heap.page_allocator);
    registry = .{};
    current_fiber = null;
    root_incoming_argument = 0;
    root_waiting_output = null;
    // A thread converted to a Windows fiber remains one for its lifetime.
    // Keep root_fiber so a subsequent Runtime in the same process can reuse it.
}

pub const exports = [_]symbols.Export{
    .{ .name = "_sceFiberInitializeImpl", .function = trace.wrap("_sceFiberInitializeImpl", &initialize), .expect_id = "hVYD7Ou2pCQ" },
    .{ .name = "sceFiberOptParamInitialize", .function = trace.wrap("sceFiberOptParamInitialize", &optParamInitialize), .expect_id = "asjUJJ+aa8s" },
    .{ .name = "sceFiberFinalize", .function = trace.wrap("sceFiberFinalize", &finalize), .expect_id = "JeNX5F-NzQU" },
    .{ .name = "sceFiberGetSelf", .function = trace.wrap("sceFiberGetSelf", &getSelf), .expect_id = "p+zLIOg27zU" },
    .{ .name = "sceFiberGetInfo", .function = trace.wrap("sceFiberGetInfo", &getInfo), .expect_id = "uq2Y5BFz0PE" },
    .{ .name = "sceFiberRename", .function = trace.wrap("sceFiberRename", &rename), .expect_id = "JzyT91ucGDc" },
    .{ .name = "sceFiberSwitch", .function = trace.wrap("sceFiberSwitch", &switchTo), .expect_id = "PFT2S-tJ7Uk" },
    .{ .name = "sceFiberRun", .function = trace.wrap("sceFiberRun", &run), .expect_id = "a0LLrZWac0M" },
    .{ .name = "sceFiberReturnToThread", .function = trace.wrap("sceFiberReturnToThread", &returnToThread), .expect_id = "B0ZX2hx9DMw" },
};

pub const library = symbols.Library{ .name = "libSceFiber", .version = 1 };
pub const module = symbols.Module{ .name = "libSceFiber", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, allocator: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(allocator, library, module, &exports);
}

test "fiber ABI and Rita's Rewind imports are registered" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    inline for (&.{ "hVYD7Ou2pCQ", "JeNX5F-NzQU", "p+zLIOg27zU", "PFT2S-tJ7Uk", "a0LLrZWac0M", "B0ZX2hx9DMw" }) |id| {
        try std.testing.expect(db.findById(id, .function) != null);
    }
}

test "fiber info reports live state and rename truncates without overwriting neighbors" {
    defer reset();
    const Guest = struct {
        fn entry(_: u64, _: u64) callconv(abi.guest) void {}
    };
    var fiber: Fiber = undefined;
    var stack: [65536]u8 align(16) = undefined;
    try std.testing.expectEqual(@as(i32, 0), initialize(&fiber, "original", @intFromPtr(&Guest.entry), 0x12345678, @intFromPtr(&stack), stack.len, 0, 0));
    var guarded = struct { info: FiberInfo = .{}, guard: u64 = 0xdeadbeef }{};
    @memset(&guarded.info.reserved, 0xa5);
    try std.testing.expectEqual(@as(i32, 0), getInfo(&fiber, &guarded.info));
    try std.testing.expectEqual(@intFromPtr(&Guest.entry), guarded.info.entry);
    try std.testing.expectEqual(@as(u64, 0x12345678), guarded.info.argument_on_initialize);
    try std.testing.expectEqual(@intFromPtr(&stack), guarded.info.context_address);
    try std.testing.expectEqual(@as(u64, stack.len), guarded.info.context_size);
    try std.testing.expectEqual(std.math.maxInt(u64), guarded.info.context_margin);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), guarded.guard);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 48), &guarded.info.reserved);
    try std.testing.expectEqual(@as(i32, 0), rename(&fiber, "abcdefghijklmnopqrstuvwxyz0123456789"));
    try std.testing.expectEqual(@as(i32, 0), getInfo(&fiber, &guarded.info));
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz01234", std.mem.sliceTo(&guarded.info.name, 0));
    try std.testing.expectEqual(@as(i32, 0), rename(&fiber, @ptrCast(&fiber.name[26])));
    try std.testing.expectEqual(@as(i32, 0), getInfo(&fiber, &guarded.info));
    try std.testing.expectEqualStrings("01234", std.mem.sliceTo(&guarded.info.name, 0));
    try std.testing.expectEqual(@as(i32, 0), finalize(&fiber));
    try std.testing.expectEqual(error_invalid, getInfo(&fiber, &guarded.info));
    try std.testing.expectEqual(error_invalid, rename(&fiber, "stale"));
    try std.testing.expectEqual(error_null, getInfo(null, &guarded.info));
    try std.testing.expectEqual(error_null, getInfo(&fiber, null));
    try std.testing.expectEqual(error_null, rename(&fiber, null));
    guarded.info.size = 80;
    try std.testing.expectEqual(error_invalid, getInfo(&fiber, &guarded.info));
}

test "fibers preserve independent firmware stacks across yields and resumes" {
    if (!supported) return error.SkipZigTest;
    defer host_stack.release();
    defer reset();
    const Probe = struct {
        iterations: u64 = 0,
        failed: bool = false,
        firmware_base: u64 = 0,

        fn largeFrame(self: *@This(), seed: u64) u64 {
            // More than Arkanoid's 256 KiB guest fiber context. It must execute
            // on this fiber's 4 MiB HLE stack, never on its native guest stack.
            var scratch: [512 * 1024]u8 = undefined;
            @memset(&scratch, @truncate(seed));
            std.mem.doNotOptimizeAway(&scratch);
            const state = host_stack.CallState.capture();
            if (!state.was_active or state.suspended == null or
                state.stack_base - state.stack_limit != host_stack.stack_size or
                @intFromPtr(&scratch) < state.stack_limit or
                @intFromPtr(&scratch) + scratch.len > state.stack_base) self.failed = true;
            if (self.firmware_base != 0 and self.firmware_base != state.stack_base) self.failed = true;
            self.firmware_base = state.stack_base;
            return scratch[0] + @as(u64, scratch[scratch.len - 1]);
        }

        fn entry(raw: u64, first: u64) callconv(abi.guest) void {
            const self: *@This() = @ptrFromInt(raw);
            var argument = first;
            while (self.iterations < 2) : (self.iterations += 1) {
                const value = host_stack.call(u64, largeFrame, .{ self, argument });
                if (value != argument * 2) self.failed = true;
                if (host_stack.call(i32, returnToThread, .{ value, &argument }) != 0) self.failed = true;
            }
        }
    };
    var fibers: [2]Fiber = undefined;
    var probes: [2]Probe = .{ .{}, .{} };
    var contexts: [2][256 * 1024]u8 align(16) = undefined;
    for (&fibers, &probes, &contexts) |*fiber, *probe, *context| {
        try std.testing.expectEqual(@as(i32, 0), initialize(fiber, "stack-test", @intFromPtr(&Probe.entry), @intFromPtr(probe), @intFromPtr(context), context.len, 0, 0));
    }
    const before = host_stack.CallState.capture();
    for (0..3) |iteration| {
        for (&fibers, &probes) |*fiber, *probe| {
            var returned: u64 = 0;
            try std.testing.expectEqual(@as(i32, 0), host_stack.call(i32, run, .{ fiber, @as(u64, 17), &returned }));
            try std.testing.expectEqual(@as(u64, if (iteration < 2) 34 else 0), returned);
            try std.testing.expect(!probe.failed);
            try std.testing.expectEqualDeep(before, host_stack.CallState.capture());
        }
    }
    try std.testing.expect(probes[0].firmware_base != probes[1].firmware_base);
    for (&fibers, &probes) |*fiber, *probe| {
        try std.testing.expectEqual(@as(u64, 2), probe.iterations);
        try std.testing.expectEqual(@as(i32, 0), finalize(fiber));
    }
}

test "fibers migrate between live threads after direct switches and yields" {
    if (!supported) return error.SkipZigTest;
    defer reset();
    const Probe = struct {
        fibers: [2]Fiber = undefined,
        phase: std.atomic.Value(u32) = .init(0),
        failures: std.atomic.Value(u32) = .init(0),

        fn check(self: *@This(), ok: bool) void {
            if (!ok) _ = self.failures.fetchAdd(1, .monotonic);
        }

        fn largeFrame(seed: u64) u64 {
            var scratch: [512 * 1024]u8 = undefined;
            @memset(&scratch, @truncate(seed));
            std.mem.doNotOptimizeAway(&scratch);
            const state = host_stack.CallState.capture();
            if (!state.was_active or state.suspended == null or
                @intFromPtr(&scratch) < state.stack_limit or
                @intFromPtr(&scratch) + scratch.len > state.stack_base) return 0;
            return scratch[0] + @as(u64, scratch[scratch.len - 1]);
        }

        fn entryA(raw: u64, first: u64) callconv(abi.guest) void {
            const self: *@This() = @ptrFromInt(raw);
            self.check(host_stack.call(u64, largeFrame, .{first}) == 22);
            const switch_entry: *const fn (?*Fiber, u64, ?*u64) callconv(abi.guest) i32 = @ptrCast(trace.wrap("sceFiberSwitch", &switchTo));
            var next: u64 = 0;
            self.check(switch_entry(&self.fibers[1], 12, &next) == 0);
            // This continuation runs on worker 1, having started on worker 0.
            self.check(next == 21);
            self.check(host_stack.call(u64, largeFrame, .{next}) == 42);
            const return_entry: *const fn (u64, ?*u64) callconv(abi.guest) i32 = @ptrCast(trace.wrap("sceFiberReturnToThread", &returnToThread));
            self.check(return_entry(42, &next) == 0);
            self.check(next == 77);
        }

        fn entryB(raw: u64, first: u64) callconv(abi.guest) void {
            const self: *@This() = @ptrFromInt(raw);
            self.check(host_stack.call(u64, largeFrame, .{first}) == 24);
            const return_entry: *const fn (u64, ?*u64) callconv(abi.guest) i32 = @ptrCast(trace.wrap("sceFiberReturnToThread", &returnToThread));
            var next: u64 = 0;
            self.check(return_entry(24, &next) == 0);
            self.check(next == 55);
            self.check(host_stack.call(u64, largeFrame, .{next}) == 110);
        }

        fn wait(self: *@This(), value: u32) void {
            while (self.phase.load(.acquire) < value) std.atomic.spinLoopHint();
        }

        fn worker(self: *@This(), index: usize) void {
            defer host_stack.release();
            const before = host_stack.CallState.capture();
            const run_entry: *const fn (?*Fiber, u64, ?*u64) callconv(abi.guest) i32 = @ptrCast(trace.wrap("sceFiberRun", &run));
            var returned: u64 = 0;
            if (index == 0) {
                self.check(run_entry(&self.fibers[0], 11, &returned) == 0);
                self.check(returned == 24);
                self.check(std.meta.eql(before, host_stack.CallState.capture()));
                self.phase.store(1, .release);
                self.wait(2);
                self.check(std.meta.eql(before, host_stack.CallState.capture()));
                self.check(run_entry(&self.fibers[1], 55, &returned) == 0);
                self.check(returned == 0);
                self.check(std.meta.eql(before, host_stack.CallState.capture()));
                self.phase.store(3, .release);
                self.wait(4);
            } else {
                self.wait(1);
                self.check(run_entry(&self.fibers[0], 21, &returned) == 0);
                self.check(returned == 42);
                self.check(std.meta.eql(before, host_stack.CallState.capture()));
                self.phase.store(2, .release);
                self.wait(3);
                self.check(run_entry(&self.fibers[0], 77, &returned) == 0);
                self.check(returned == 0);
                self.check(std.meta.eql(before, host_stack.CallState.capture()));
                self.phase.store(4, .release);
            }
        }
    };
    var probe: Probe = .{};
    var contexts: [2][256 * 1024]u8 align(16) = undefined;
    try std.testing.expectEqual(@as(i32, 0), initialize(&probe.fibers[0], "migrate-a", @intFromPtr(&Probe.entryA), @intFromPtr(&probe), @intFromPtr(&contexts[0]), contexts[0].len, 0, 0));
    try std.testing.expectEqual(@as(i32, 0), initialize(&probe.fibers[1], "migrate-b", @intFromPtr(&Probe.entryB), @intFromPtr(&probe), @intFromPtr(&contexts[1]), contexts[1].len, 0, 0));
    const first = try std.Thread.spawn(.{}, Probe.worker, .{ &probe, 0 });
    const second = try std.Thread.spawn(.{}, Probe.worker, .{ &probe, 1 });
    first.join();
    second.join();
    try std.testing.expectEqual(@as(u32, 0), probe.failures.load(.acquire));
    for (&probe.fibers) |*fiber| try std.testing.expectEqual(@as(i32, 0), finalize(fiber));
}

test "fiber option parameters initialize from their size field" {
    var db = symbols.Database{};
    defer db.deinit(std.testing.allocator);
    try register(&db, std.testing.allocator);
    const symbol = db.findById("asjUJJ+aa8s", .function) orelse return error.MissingFiberOptParamInit;
    try std.testing.expectEqualStrings("libSceFiber", symbol.key.library.name);
    const init: *const fn (?*anyopaque) callconv(abi.guest) i32 = @ptrFromInt(symbol.address);
    try std.testing.expectEqual(error_null, init(null));
    var storage: [64]u8 = @splat(0xa5);
    std.mem.writeInt(u32, storage[0..4], 16, .little);
    try std.testing.expectEqual(@as(i32, 0), init(@ptrCast(&storage)));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 16), storage[0..16]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 48), storage[16..64]);
    std.mem.writeInt(u32, storage[0..4], 1024, .little);
    try std.testing.expectEqual(error_invalid, init(@ptrCast(&storage)));
}
