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

const supported = builtin.cpu.arch == .x86_64 and builtin.os.tag == .windows;

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

comptime {
    if (@sizeOf(Fiber) != 128) @compileError("SceFiber ABI size must be 128 bytes");
    if (@offsetOf(Fiber, "context_pointer") != 72) @compileError("SceFiber context pointer offset mismatch");
    if (@offsetOf(Fiber, "context_start") != 88) @compileError("SceFiber context start offset mismatch");
    if (@offsetOf(Fiber, "end_signature") != 104) @compileError("SceFiber end signature offset mismatch");
}

const Host = struct {
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

const RuntimeFiber = struct {
    guest: *Fiber,
    host: ?*anyopaque = null,
    owner_root: ?*anyopaque = null,
    entry: u64,
    argument_on_initialize: u64,
    context_size: u64,
    incoming_argument: u64 = 0,
    waiting_output: ?*u64 = null,
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

fn lookup(fiber: *Fiber) ?*RuntimeFiber {
    registry_lock.lock();
    defer registry_lock.unlock();
    return registry.get(@intFromPtr(fiber));
}

fn ensureRootFiber() bool {
    if (!supported) return false;
    if (root_fiber != null) return true;
    root_fiber = Host.ConvertThreadToFiberEx(null, 0);
    return root_fiber != null;
}

fn ensureHostFiber(runtime_fiber: *RuntimeFiber) bool {
    if (!ensureRootFiber()) return false;
    if (runtime_fiber.host != null) return runtime_fiber.owner_root == root_fiber;

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
    runtime_fiber.owner_root = root_fiber;
    return runtime_fiber.host != null;
}

/// Host-fiber entry trampoline.  The entry function itself uses the guest
/// System V convention even though the Windows trampoline uses WINAPI.
fn fiberEntry(parameter: ?*anyopaque) callconv(.winapi) void {
    const runtime_fiber: *RuntimeFiber = @ptrCast(@alignCast(parameter.?));
    current_fiber = runtime_fiber;
    const entry: *const fn (u64, u64) callconv(abi.guest) void = @ptrFromInt(runtime_fiber.entry);
    entry(runtime_fiber.argument_on_initialize, runtime_fiber.incoming_argument);

    // Returning from an entry function terminates it and hands control back to
    // the root thread.  A finalized fiber is never resumed at this point.
    runtime_fiber.guest.state = state_terminated;
    root_incoming_argument = 0;
    current_fiber = null;
    Host.SwitchToFiber(runtime_fiber.owner_root.?);
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

fn finalize(fiber: ?*Fiber) callconv(abi.guest) i32 {
    const value = fiber orelse return error_null;
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
    const target = lookup(value) orelse return error_invalid;
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
    Host.SwitchToFiber(target.host.?);

    // Execution resumes here only after another fiber explicitly targets this
    // caller (or returns to the root thread).
    if (source) |from| {
        current_fiber = from;
        if (!writeArgument(from.waiting_output, from.incoming_argument)) return error_invalid;
    } else {
        current_fiber = null;
        if (!writeArgument(root_waiting_output, root_incoming_argument)) return error_invalid;
    }
    return 0;
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
    const root = source.owner_root orelse return error_permission;

    source.waiting_output = next_argument_on_run;
    source.guest.state = state_idle;
    root_incoming_argument = argument_on_return;
    current_fiber = null;
    Host.SwitchToFiber(root);

    // A later sceFiberRun of this same object resumes the suspended call.
    current_fiber = source;
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

pub fn reset() void {
    registry_lock.lock();
    defer registry_lock.unlock();
    var values = registry.valueIterator();
    while (values.next()) |runtime_fiber| {
        if (supported) if (runtime_fiber.*.host) |host| Host.DeleteFiber(host);
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
    .{ .name = "sceFiberFinalize", .function = trace.wrap("sceFiberFinalize", &finalize), .expect_id = "JeNX5F-NzQU" },
    .{ .name = "sceFiberGetSelf", .function = trace.wrap("sceFiberGetSelf", &getSelf), .expect_id = "p+zLIOg27zU" },
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
