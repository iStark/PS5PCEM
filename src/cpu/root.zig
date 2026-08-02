// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Guest CPU dispatch and pthread scheduling.
//!
//! The dispatcher owns host workers and implements the complete libkernel
//! threading backend. Machine execution is deliberately behind `Bridge`: the
//! bridge is the only layer allowed to install or translate the guest FS base.
//! This matters on POSIX hosts, where FS commonly addresses host TLS. Windows
//! x86-64 keeps its TEB under GS, which permits the direct backend below to use
//! FS for the guest while Zig and Win32 code run on the same worker.

const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory");
const hle = @import("hle");
const x86_64_compat = @import("x86_64_compat.zig");
const threading = hle.libs.kernel_threading;

const key_state_capacity: usize = 256;
const events_per_key: usize = 16;
const wake_all = std.math.maxInt(usize);

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

pub const ExecutionError = error{
    Unsupported,
    ExecutionFailed,
    GuestFault,
    Interrupted,
};

pub const Error = error{
    AlreadyInitialized,
    NotInitialized,
    InvalidArgument,
    DispatcherBusy,
    FaultHandlerUnavailable,
} || std.mem.Allocator.Error || threading.Error || ExecutionError;

pub const EntryKind = enum {
    process_entry,
    module_initializer,
    pthread_entry,
    guest_callback,
};

pub const maximum_arguments: usize = 6;

pub const FaultKind = enum(u32) {
    none,
    access_violation,
    illegal_instruction,
};

pub const FaultAccess = enum(u32) {
    unknown,
    read,
    write,
    execute,
};

/// Register state captured by the Windows vectored exception handler before
/// the native bridge leaves guest execution.
pub const GuestRegisters = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rbp: u64 = 0,
    rsp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
    rflags: u64 = 0,
};

/// Platform-neutral diagnostic record for a contained guest CPU fault.
pub const FaultInfo = extern struct {
    kind: FaultKind = .none,
    access: FaultAccess = .unknown,
    exception_code: u32 = 0,
    padding: u32 = 0,
    instruction_address: u64 = 0,
    memory_address: u64 = 0,
    registers: GuestRegisters = .{},
};

pub const FaultRecord = struct {
    thread_handle: u64,
    info: FaultInfo,
};

/// Complete machine state required by an execution bridge for one guest call.
///
/// `stack_address` is the lowest writable byte. The initial RSP is normally
/// derived from `stack_address + stack_size` and aligned down to 16 bytes.
pub const ExecuteRequest = struct {
    kind: EntryKind,
    entry_point: u64,
    thread_handle: u64,
    arguments: [maximum_arguments]u64 = [_]u64{0} ** maximum_arguments,
    argument_count: u8 = 0,
    context: threading.ThreadContext,
    stack_address: u64,
    stack_size: u64,
    guard_size: u64,
    /// Stack pointer immediately before the bridge's CALL instruction. When
    /// omitted, the bridge uses the aligned top of the mapped thread stack.
    stack_pointer: ?u64 = null,
};

/// Platform/native machine bridge used by `Dispatcher`.
///
/// Implementations execute System V AMD64 guest code and must make
/// `request.context.fs_base` visible to guest FS-relative instructions without
/// exposing that FS state to host Zig/HLE code. `interrupt` must make an active
/// `execute` return `error.Interrupted`; it is used by `scePthreadExit` and
/// dispatcher shutdown.
pub const Bridge = struct {
    context: ?*anyopaque = null,
    execute_fn: *const fn (?*anyopaque, ExecuteRequest) ExecutionError!u64,
    interrupt_fn: ?*const fn (?*anyopaque, u64) void = null,

    fn execute(self: Bridge, request: ExecuteRequest) ExecutionError!u64 {
        return self.execute_fn(self.context, request);
    }

    fn interrupt(self: Bridge, thread_handle: u64) void {
        if (self.interrupt_fn) |interrupt_fn| interrupt_fn(self.context, thread_handle);
    }
};

/// Whether this build can contain the direct Windows x86-64 execution path.
/// Runtime availability additionally depends on the operating system exposing
/// user-mode RDFSBASE/WRFSBASE support.
pub const can_use_native_bridge = builtin.cpu.arch == .x86_64 and
    builtin.os.tag == .windows;

const NativeCallFrame = extern struct {
    // The first 272 bytes are shared with the hand-written assembly below.
    host_rsp: u64 = 0,
    host_fs_base: u64 = 0,
    host_rbx: u64 = 0,
    host_rbp: u64 = 0,
    host_rsi: u64 = 0,
    host_rdi: u64 = 0,
    host_r12: u64 = 0,
    host_r13: u64 = 0,
    host_r14: u64 = 0,
    host_r15: u64 = 0,
    guest_fs_base: u64 = 0,
    result: u64 = 0,
    interrupted: u32 = 0,
    host_mxcsr: u32 = 0,
    host_x87_control: u16 = 0,
    padding: [6]u8 = [_]u8{0} ** 6,
    host_xmm_nonvolatile: [10][16]u8 = [_][16]u8{[_]u8{0} ** 16} ** 10,

    // Dispatcher metadata is never accessed by assembly.
    owner: ?*NativeBridge = null,
    thread_handle: u64 = 0,
    guest_arguments: [maximum_arguments]u64 = [_]u64{0} ** maximum_arguments,
    fault: FaultInfo = .{},
};

comptime {
    // Keep these checks beside the assembly so a layout edit fails loudly.
    std.debug.assert(@offsetOf(NativeCallFrame, "host_rsp") == 0);
    std.debug.assert(@offsetOf(NativeCallFrame, "host_fs_base") == 8);
    std.debug.assert(@offsetOf(NativeCallFrame, "guest_fs_base") == 80);
    std.debug.assert(@offsetOf(NativeCallFrame, "result") == 88);
    std.debug.assert(@offsetOf(NativeCallFrame, "interrupted") == 96);
    std.debug.assert(@offsetOf(NativeCallFrame, "host_mxcsr") == 100);
    std.debug.assert(@offsetOf(NativeCallFrame, "host_x87_control") == 104);
    std.debug.assert(@offsetOf(NativeCallFrame, "host_xmm_nonvolatile") == 112);
    std.debug.assert(@offsetOf(NativeCallFrame, "owner") == 272);
    std.debug.assert(@offsetOf(NativeCallFrame, "guest_arguments") == 288);
    std.debug.assert(@offsetOf(NativeCallFrame, "fault") == 336);
}

threadlocal var active_native_frame: ?*NativeCallFrame = null;
threadlocal var handling_native_fault = false;

/// Direct System V AMD64 execution on a Windows x86-64 host.
///
/// Windows x64 uses GS rather than FS for its TEB, so Zig and Win32 remain able
/// to run while the guest FS base is installed. The assembly boundary still
/// restores FS before it returns to ordinary Zig code and preserves every
/// register which Win64 requires a callee to retain, including XMM6-XMM15.
/// Other hosts intentionally report `error.Unsupported`: POSIX runtimes use FS
/// for host TLS and need import trampolines that restore it before entering HLE.
pub const NativeBridge = struct {
    allocator: std.mem.Allocator = undefined,
    address_space: *memory.AddressSpace = undefined,
    active_frames: std.ArrayList(*NativeCallFrame) = .empty,
    fault_handler_handle: ?*anyopaque = null,
    last_fault: ?FaultRecord = null,
    lock: Lock = .{},
    initialized: bool = false,

    pub fn init(
        self: *NativeBridge,
        allocator: std.mem.Allocator,
        address_space: *memory.AddressSpace,
    ) Error!void {
        if (self.initialized) return error.AlreadyInitialized;
        if (!NativeMachine.isSupported()) return error.Unsupported;
        const fault_handler_handle = NativeMachine.installFaultHandler() orelse
            return error.FaultHandlerUnavailable;
        self.* = .{
            .allocator = allocator,
            .address_space = address_space,
            .fault_handler_handle = fault_handler_handle,
            .initialized = true,
        };
    }

    pub fn deinit(self: *NativeBridge) void {
        if (!self.initialized) return;
        self.lock.lock();
        std.debug.assert(self.active_frames.items.len == 0);
        self.active_frames.deinit(self.allocator);
        self.lock.unlock();
        if (self.fault_handler_handle) |handle| {
            NativeMachine.removeFaultHandler(handle);
        }
        self.* = .{};
    }

    pub fn isInitialized(self: *const NativeBridge) bool {
        return self.initialized;
    }

    pub fn isSupported() bool {
        return NativeMachine.isSupported();
    }

    pub fn bridge(self: *NativeBridge) Bridge {
        return .{
            .context = self,
            .execute_fn = &executeThunk,
            .interrupt_fn = &interruptThunk,
        };
    }

    /// Returns the most recently contained fault. The thread handle identifies
    /// the execution which produced it; a later guest fault replaces it.
    pub fn lastFault(self: *NativeBridge) ?FaultRecord {
        if (!self.initialized) return null;
        self.lock.lock();
        defer self.lock.unlock();
        return self.last_fault;
    }

    fn executeThunk(raw: ?*anyopaque, request: ExecuteRequest) ExecutionError!u64 {
        const pointer = raw orelse return error.ExecutionFailed;
        const self: *NativeBridge = @ptrCast(@alignCast(pointer));
        return self.execute(request);
    }

    fn execute(self: *NativeBridge, request: ExecuteRequest) ExecutionError!u64 {
        if (!self.initialized) return error.Unsupported;
        if (request.entry_point == 0 or request.argument_count > maximum_arguments) {
            return error.ExecutionFailed;
        }

        const previous = active_native_frame;
        const nested = previous != null;
        if (previous) |parent| {
            if (parent.owner != self or parent.thread_handle != request.thread_handle or
                parent.guest_fs_base != request.context.fs_base or
                request.kind != .guest_callback)
            {
                return error.ExecutionFailed;
            }
        } else if (!self.validateInitialRequest(request)) {
            return error.ExecutionFailed;
        }

        if (!self.isExecutableAddress(request.entry_point)) {
            return error.ExecutionFailed;
        }
        self.clearFault(request.thread_handle);

        const stack_pointer = if (nested)
            0
        else
            resolveStackPointer(request) orelse
                return error.ExecutionFailed;

        var frame: NativeCallFrame align(16) = .{
            .guest_fs_base = request.context.fs_base,
            .owner = self,
            .thread_handle = request.thread_handle,
            .guest_arguments = request.arguments,
        };
        try self.registerFrame(&frame);
        defer self.unregisterFrame(&frame);
        active_native_frame = &frame;
        defer active_native_frame = previous;

        const result = NativeMachine.call(
            &frame,
            request.entry_point,
            stack_pointer,
        );
        if (frame.fault.kind != .none) {
            self.recordFault(.{
                .thread_handle = request.thread_handle,
                .info = frame.fault,
            });
            return error.GuestFault;
        }
        if (@atomicLoad(u32, &frame.interrupted, .acquire) != 0) {
            return error.Interrupted;
        }
        return result;
    }

    fn interruptThunk(raw: ?*anyopaque, thread_handle: u64) void {
        const pointer = raw orelse return;
        const self: *NativeBridge = @ptrCast(@alignCast(pointer));
        self.interrupt(thread_handle);
    }

    fn interrupt(self: *NativeBridge, thread_handle: u64) void {
        if (!self.initialized) return;

        // pthread_exit reaches this path synchronously on the executing host
        // worker. The assembly escape discards the guest/HLE frames and returns
        // from NativeMachine.call with the host FS and ABI state restored.
        if (active_native_frame) |frame| {
            if (frame.owner == self and frame.thread_handle == thread_handle) {
                @atomicStore(u32, &frame.interrupted, 1, .release);
                NativeMachine.escape(frame);
            }
        }

        // Shutdown may request interruption from another host thread. Marking
        // the frame is race-safe and makes a returning guest report Interrupted.
        // Forced cross-thread context transfer belongs with the fault backend;
        // suspending a worker while it owns an HLE lock would corrupt state.
        self.lock.lock();
        for (self.active_frames.items) |frame| {
            if (frame.thread_handle != thread_handle) continue;
            @atomicStore(u32, &frame.interrupted, 1, .release);
        }
        self.lock.unlock();
    }

    fn registerFrame(
        self: *NativeBridge,
        frame: *NativeCallFrame,
    ) ExecutionError!void {
        self.lock.lock();
        defer self.lock.unlock();
        self.active_frames.append(self.allocator, frame) catch
            return error.ExecutionFailed;
    }

    fn unregisterFrame(self: *NativeBridge, frame: *NativeCallFrame) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.active_frames.items, 0..) |known, index| {
            if (known != frame) continue;
            _ = self.active_frames.swapRemove(index);
            return;
        }
        unreachable;
    }

    fn clearFault(self: *NativeBridge, thread_handle: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.last_fault) |record| {
            if (record.thread_handle == thread_handle) self.last_fault = null;
        }
    }

    fn recordFault(self: *NativeBridge, record: FaultRecord) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.last_fault = record;
    }

    fn validateInitialRequest(self: *NativeBridge, request: ExecuteRequest) bool {
        if (request.context.fs_base == 0 or request.stack_address == 0 or
            request.stack_size < 256)
        {
            return false;
        }
        const stack_end = std.math.add(
            u64,
            request.stack_address,
            request.stack_size,
        ) catch return false;
        const stack = self.address_space.query(request.stack_address, false) orelse
            return false;
        if (!stack.protection.write or stack.kind == .reserved or stack.end() < stack_end) {
            return false;
        }
        const tls = self.address_space.query(request.context.fs_base, false) orelse
            return false;
        return tls.kind != .reserved and tls.protection.read and tls.protection.write;
    }

    fn isExecutableAddress(self: *NativeBridge, address: u64) bool {
        const mapping = self.address_space.query(address, false) orelse return false;
        return mapping.kind != .reserved and mapping.protection.execute;
    }
};

fn resolveStackPointer(request: ExecuteRequest) ?u64 {
    const address = request.stack_address;
    const size = request.stack_size;
    const end = std.math.add(u64, address, size) catch return null;
    const minimum_top = std.math.add(u64, address, 256) catch return null;
    const stack_pointer = request.stack_pointer orelse
        std.mem.alignBackward(u64, end, 16);
    if (!std.mem.isAligned(stack_pointer, 16)) return null;
    return if (stack_pointer >= minimum_top and stack_pointer <= end)
        stack_pointer
    else
        null;
}

const NativeMachine = if (can_use_native_bridge) WindowsX64Machine else UnsupportedMachine;

const UnsupportedMachine = struct {
    fn isSupported() bool {
        return false;
    }

    fn installFaultHandler() ?*anyopaque {
        return null;
    }

    fn removeFaultHandler(_: *anyopaque) void {
        unreachable;
    }

    fn call(_: *NativeCallFrame, _: u64, _: u64) u64 {
        unreachable;
    }

    fn escape(_: *NativeCallFrame) noreturn {
        unreachable;
    }

    fn readFsBase() u64 {
        return 0;
    }
};

const WindowsX64Machine = struct {
    const exception_continue_execution: c_long = -1;
    const exception_noncontinuable: u32 = 0x1;

    fn isSupported() bool {
        return std.os.windows.IsProcessorFeaturePresent(.RDWRFSGBASE_AVAILABLE);
    }

    fn installFaultHandler() ?*anyopaque {
        return std.os.windows.ntdll.RtlAddVectoredExceptionHandler(
            1,
            &handleGuestException,
        );
    }

    fn removeFaultHandler(handle: *anyopaque) void {
        _ = std.os.windows.ntdll.RtlRemoveVectoredExceptionHandler(handle);
    }

    fn call(
        frame: *NativeCallFrame,
        entry_point: u64,
        stack_pointer: u64,
    ) u64 {
        return ps5NativeCallWindowsX64(
            frame,
            entry_point,
            stack_pointer,
        );
    }

    fn escape(frame: *NativeCallFrame) noreturn {
        ps5NativeEscapeWindowsX64(frame);
    }

    fn readFsBase() u64 {
        return asm volatile ("rdfsbase %[base]"
            : [base] "=r" (-> u64),
        );
    }

    fn handleGuestException(
        exception: *std.os.windows.EXCEPTION_POINTERS,
    ) callconv(.winapi) c_long {
        const frame = active_native_frame orelse
            return std.os.windows.EXCEPTION_CONTINUE_SEARCH;
        if (handling_native_fault) return std.os.windows.EXCEPTION_CONTINUE_SEARCH;

        const record = exception.ExceptionRecord;
        const context = exception.ContextRecord;
        // A call through a function pointer that was never filled in leaves
        // Rip at or near zero, which belongs to neither guest nor host. That is
        // exactly the fault worth containing: declining it kills the process at
        // the one moment the guest registers still explain why. Reaching a null
        // address requires a control transfer, and `active_native_frame` has
        // already established that this thread is inside a guest call.
        const from_guest = isGuestAddress(context.Rip) or isNullControlTransfer(context.Rip);
        if (record.ExceptionFlags & exception_noncontinuable != 0 or !from_guest) {
            return std.os.windows.EXCEPTION_CONTINUE_SEARCH;
        }

        const kind: FaultKind = switch (record.ExceptionCode) {
            std.os.windows.EXCEPTION_ACCESS_VIOLATION => .access_violation,
            std.os.windows.EXCEPTION_ILLEGAL_INSTRUCTION => .illegal_instruction,
            else => return std.os.windows.EXCEPTION_CONTINUE_SEARCH,
        };

        handling_native_fault = true;
        defer handling_native_fault = false;

        if (kind == .illegal_instruction and tryEmulateIllegalInstruction(context)) {
            return exception_continue_execution;
        }

        var fault = FaultInfo{
            .kind = kind,
            .exception_code = record.ExceptionCode,
            .instruction_address = context.Rip,
            .registers = .{
                .rax = context.Rax,
                .rbx = context.Rbx,
                .rcx = context.Rcx,
                .rdx = context.Rdx,
                .rsi = context.Rsi,
                .rdi = context.Rdi,
                .rbp = context.Rbp,
                .rsp = context.Rsp,
                .r8 = context.R8,
                .r9 = context.R9,
                .r10 = context.R10,
                .r11 = context.R11,
                .r12 = context.R12,
                .r13 = context.R13,
                .r14 = context.R14,
                .r15 = context.R15,
                .rip = context.Rip,
                .rflags = context.EFlags,
            },
        };
        if (kind == .access_violation and record.NumberParameters >= 2) {
            fault.access = switch (record.ExceptionInformation[0]) {
                0 => .read,
                1 => .write,
                8 => .execute,
                else => .unknown,
            };
            fault.memory_address = record.ExceptionInformation[1];
        }
        frame.fault = fault;

        // Returning CONTINUE_EXECUTION makes Windows restore this edited
        // context. The assembly escape does not touch the potentially damaged
        // guest stack: it restores the saved host RSP and FS base first.
        context.Rcx = @intFromPtr(frame);
        context.Rip = @intFromPtr(&ps5NativeEscapeWindowsX64);
        return exception_continue_execution;
    }

    fn tryEmulateIllegalInstruction(context: *std.os.windows.CONTEXT) bool {
        const code: [*]const u8 = @ptrFromInt(context.Rip);
        const instruction = x86_64_compat.decode(code) orelse return false;
        switch (instruction.kind) {
            .monitorx, .mwaitx => {},
            .extrq => {
                const destination = contextXmm(context, instruction.destination);
                const result = x86_64_compat.extractBitField(
                    destination.Low,
                    instruction.field_length,
                    instruction.field_index,
                ) orelse return false;
                destination.Low = result;
                destination.High = 0;
            },
            .insertq => {
                const destination = contextXmm(context, instruction.destination);
                const source = contextXmm(context, instruction.source);
                const result = x86_64_compat.insertBitField(
                    destination.Low,
                    source.Low,
                    instruction.field_length,
                    instruction.field_index,
                ) orelse return false;
                destination.Low = result;
                destination.High = 0;
            },
        }
        // MONITORX arms a cache-line monitor and MWAITX waits for a write or
        // timeout. The compatibility path treats both as completed operations,
        // preserving forward progress without blocking inside the VEH.
        context.Rip += instruction.length;
        return true;
    }

    fn contextXmm(
        context: *std.os.windows.CONTEXT,
        index: u8,
    ) *std.os.windows.M128A {
        std.debug.assert(index < 16);
        const first = &context.DUMMYUNIONNAME.DUMMYSTRUCTNAME.Xmm0;
        const registers: [*]std.os.windows.M128A = @ptrCast(first);
        return &registers[index];
    }
};

fn isGuestAddress(address: u64) bool {
    inline for (memory.guest_ranges) |range| {
        if (range.contains(address, 1)) return true;
    }
    return false;
}

/// Whether an instruction pointer looks like a jump through a null pointer.
///
/// The whole first page counts, not just zero: a null vtable slot or a callback
/// reached through a struct field lands a little above it. No guest mapping
/// exists there, so nothing legitimate is misclassified.
fn isNullControlTransfer(address: u64) bool {
    return address < memory.page_size;
}

test "a null instruction pointer is treated as guest control flow" {
    // The fault a title hits when it calls a callback that was never
    // registered. Declining to contain it loses every register that explains
    // the failure.
    try std.testing.expect(isNullControlTransfer(0));
    try std.testing.expect(isNullControlTransfer(0x10));
    try std.testing.expect(!isNullControlTransfer(memory.page_size));
    // Real guest code stays out of the first page.
    try std.testing.expect(!isGuestAddress(0));
    try std.testing.expect(isGuestAddress(memory.system_managed.start));
}

extern fn ps5NativeCallWindowsX64(
    frame: *NativeCallFrame,
    entry_point: u64,
    stack_pointer: u64,
) callconv(.winapi) u64;

extern fn ps5NativeEscapeWindowsX64(frame: *NativeCallFrame) callconv(.winapi) noreturn;

comptime {
    if (can_use_native_bridge) asm (
        \\.text
        \\.p2align 4
        \\.globl ps5NativeCallWindowsX64
        \\ps5NativeCallWindowsX64:
        \\  movq %rsp, 0(%rcx)
        \\  rdfsbase %rax
        \\  movq %rax, 8(%rcx)
        \\  movq %rbx, 16(%rcx)
        \\  movq %rbp, 24(%rcx)
        \\  movq %rsi, 32(%rcx)
        \\  movq %rdi, 40(%rcx)
        \\  movq %r12, 48(%rcx)
        \\  movq %r13, 56(%rcx)
        \\  movq %r14, 64(%rcx)
        \\  movq %r15, 72(%rcx)
        \\  stmxcsr 100(%rcx)
        \\  fnstcw 104(%rcx)
        \\  movdqu %xmm6, 112(%rcx)
        \\  movdqu %xmm7, 128(%rcx)
        \\  movdqu %xmm8, 144(%rcx)
        \\  movdqu %xmm9, 160(%rcx)
        \\  movdqu %xmm10, 176(%rcx)
        \\  movdqu %xmm11, 192(%rcx)
        \\  movdqu %xmm12, 208(%rcx)
        \\  movdqu %xmm13, 224(%rcx)
        \\  movdqu %xmm14, 240(%rcx)
        \\  movdqu %xmm15, 256(%rcx)
        \\  movq %rdx, %r11
        \\  movq %rcx, %r15
        \\  movq 80(%r15), %r10
        \\  wrfsbase %r10
        \\  testq %r8, %r8
        \\  jz 1f
        \\  movq %r8, %rsp
        \\1:
        \\  andq $-16, %rsp
        \\  movq 288(%r15), %rdi
        \\  movq 296(%r15), %rsi
        \\  movq 304(%r15), %rdx
        \\  movq 312(%r15), %rcx
        \\  movq 320(%r15), %r8
        \\  movq 328(%r15), %r9
        \\  xorl %eax, %eax
        \\  callq *%r11
        \\  movq %rax, 88(%r15)
        \\  movq 8(%r15), %r10
        \\  wrfsbase %r10
        \\  movq %r15, %r10
        \\  movq 0(%r10), %rsp
        \\  ldmxcsr 100(%r10)
        \\  fldcw 104(%r10)
        \\  movdqu 112(%r10), %xmm6
        \\  movdqu 128(%r10), %xmm7
        \\  movdqu 144(%r10), %xmm8
        \\  movdqu 160(%r10), %xmm9
        \\  movdqu 176(%r10), %xmm10
        \\  movdqu 192(%r10), %xmm11
        \\  movdqu 208(%r10), %xmm12
        \\  movdqu 224(%r10), %xmm13
        \\  movdqu 240(%r10), %xmm14
        \\  movdqu 256(%r10), %xmm15
        \\  movq 88(%r10), %rax
        \\  movq 16(%r10), %rbx
        \\  movq 24(%r10), %rbp
        \\  movq 32(%r10), %rsi
        \\  movq 40(%r10), %rdi
        \\  movq 48(%r10), %r12
        \\  movq 56(%r10), %r13
        \\  movq 64(%r10), %r14
        \\  movq 72(%r10), %r15
        \\  retq
        \\.p2align 4
        \\.globl ps5NativeEscapeWindowsX64
        \\ps5NativeEscapeWindowsX64:
        \\  movq $0, 88(%rcx)
        \\  movq 8(%rcx), %r10
        \\  wrfsbase %r10
        \\  movq %rcx, %r10
        \\  movq 0(%r10), %rsp
        \\  ldmxcsr 100(%r10)
        \\  fldcw 104(%r10)
        \\  movdqu 112(%r10), %xmm6
        \\  movdqu 128(%r10), %xmm7
        \\  movdqu 144(%r10), %xmm8
        \\  movdqu 160(%r10), %xmm9
        \\  movdqu 176(%r10), %xmm10
        \\  movdqu 192(%r10), %xmm11
        \\  movdqu 208(%r10), %xmm12
        \\  movdqu 224(%r10), %xmm13
        \\  movdqu 240(%r10), %xmm14
        \\  movdqu 256(%r10), %xmm15
        \\  xorl %eax, %eax
        \\  movq 16(%r10), %rbx
        \\  movq 24(%r10), %rbp
        \\  movq 32(%r10), %rsi
        \\  movq 40(%r10), %rdi
        \\  movq 48(%r10), %r12
        \\  movq 56(%r10), %r13
        \\  movq 64(%r10), %r14
        \\  movq 72(%r10), %r15
        \\  retq
    );
}

const WakeEvent = struct {
    sequence: u64 = 0,
    remaining: usize = 0,
};

const KeyState = struct {
    used: bool = false,
    key: u64 = 0,
    latest_sequence: u64 = 0,
    broadcast_sequence: u64 = 0,
    events: [events_per_key]WakeEvent = [_]WakeEvent{.{}} ** events_per_key,
};

const Worker = struct {
    dispatcher: *Dispatcher,
    request: threading.StartRequest,
    host_thread: ?std.Thread = null,
    result: u64 = 0,
    finished: bool = false,
    detached: bool,
    joining: bool = false,
    interrupt_sent: bool = false,
    execution_failed: bool = false,
};

const ActiveExecution = struct {
    dispatcher: *Dispatcher,
    thread_handle: u64,
    context: threading.ThreadContext,
    stack_address: u64,
    stack_size: u64,
    guard_size: u64,
    exit_requested: bool = false,
    exit_result: u64 = 0,
};

threadlocal var active_execution: ?ActiveExecution = null;

pub const Dispatcher = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    manager: *threading.Manager = undefined,
    bridge: Bridge = undefined,
    workers: std.ArrayList(*Worker) = .empty,
    key_states: []KeyState = &.{},
    lock: Lock = .{},
    wake_epoch: u32 align(@alignOf(u32)) = 1,
    saturated_keys: bool = false,
    shutting_down: bool = false,
    initialized: bool = false,

    /// Initializes a stable, caller-owned dispatcher and attaches its pthread
    /// backend. The value must not move while guest execution is active.
    pub fn init(
        self: *Dispatcher,
        allocator: std.mem.Allocator,
        io: std.Io,
        manager: *threading.Manager,
        bridge: Bridge,
    ) Error!void {
        if (self.initialized) return error.AlreadyInitialized;
        if (manager.hasBackend()) return error.DispatcherBusy;
        const states = try allocator.alloc(KeyState, key_state_capacity);
        @memset(states, .{});
        self.* = .{
            .allocator = allocator,
            .io = io,
            .manager = manager,
            .bridge = bridge,
            .key_states = states,
            .initialized = true,
        };
        manager.setBackend(self.backend());
    }

    /// Stops accepting work, requests every bridge execution to unwind, then
    /// joins all host workers before detaching from the pthread manager.
    pub fn deinit(self: *Dispatcher) void {
        if (!self.initialized) return;
        self.manager.setBackend(null);

        self.lock.lock();
        self.shutting_down = true;
        self.lock.unlock();
        self.publishWake();

        // Do not call bridge code under the dispatcher lock. An interrupt may
        // synchronously unwind through HLE and finish the same worker.
        while (true) {
            self.lock.lock();
            var handle: ?u64 = null;
            for (self.workers.items) |worker| {
                if (worker.finished or worker.interrupt_sent) continue;
                worker.interrupt_sent = true;
                handle = worker.request.thread_handle;
                break;
            }
            self.lock.unlock();
            const thread_handle = handle orelse break;
            self.bridge.interrupt(thread_handle);
        }

        while (true) {
            self.lock.lock();
            const worker = if (self.workers.items.len == 0)
                null
            else
                self.workers.pop();
            self.lock.unlock();
            const current = worker orelse break;
            if (current.host_thread) |host_thread| host_thread.join();
            self.allocator.destroy(current);
        }

        self.workers.deinit(self.allocator);
        self.allocator.free(self.key_states);
        self.* = .{};
    }

    pub fn backend(self: *Dispatcher) threading.Backend {
        return .{
            .context = self,
            .start_fn = &start,
            .join_fn = &join,
            .detach_fn = &detach,
            .yield_fn = &yield,
            .sleep_fn = &sleep,
            .wait_fn = &wait,
            .wake_fn = &wake,
            .call_fn = &call,
            .request_exit_fn = &requestExit,
        };
    }

    pub fn isInitialized(self: *const Dispatcher) bool {
        return self.initialized;
    }

    /// Executes the initial process thread on the caller's host worker.
    /// Callers retain ownership of `prepared` and release it afterwards.
    pub fn dispatchInitial(
        self: *Dispatcher,
        prepared: threading.PreparedThread,
        entry_point: u64,
        arguments: []const u64,
    ) Error!u64 {
        return self.dispatchPrepared(
            prepared,
            .process_entry,
            entry_point,
            arguments,
            null,
            true,
        );
    }

    /// Executes the process entry with a caller-built initial stack frame.
    pub fn dispatchInitialAtStack(
        self: *Dispatcher,
        prepared: threading.PreparedThread,
        entry_point: u64,
        arguments: []const u64,
        stack_pointer: u64,
    ) Error!u64 {
        return self.dispatchPrepared(
            prepared,
            .process_entry,
            entry_point,
            arguments,
            stack_pointer,
            true,
        );
    }

    /// Runs a module initializer on the prepared initial thread without
    /// finalizing that thread's POSIX TLS-key values after the call returns.
    pub fn dispatchInitializer(
        self: *Dispatcher,
        prepared: threading.PreparedThread,
        entry_point: u64,
        arguments: []const u64,
    ) Error!u64 {
        return self.dispatchPrepared(
            prepared,
            .module_initializer,
            entry_point,
            arguments,
            null,
            false,
        );
    }

    fn dispatchPrepared(
        self: *Dispatcher,
        prepared: threading.PreparedThread,
        kind: EntryKind,
        entry_point: u64,
        arguments: []const u64,
        stack_pointer: ?u64,
        finalize_thread: bool,
    ) Error!u64 {
        if (!self.initialized) return error.NotInitialized;
        if (entry_point == 0 or arguments.len > maximum_arguments or active_execution != null) {
            return error.InvalidArgument;
        }

        try self.manager.enter(prepared.handle);
        defer self.manager.leave();
        active_execution = .{
            .dispatcher = self,
            .thread_handle = @intFromPtr(prepared.handle.?),
            .context = prepared.context,
            .stack_address = prepared.stack_address,
            .stack_size = prepared.stack_size,
            .guard_size = prepared.guard_size,
        };
        defer active_execution = null;

        var request = ExecuteRequest{
            .kind = kind,
            .entry_point = entry_point,
            .thread_handle = active_execution.?.thread_handle,
            .context = prepared.context,
            .stack_address = prepared.stack_address,
            .stack_size = prepared.stack_size,
            .guard_size = prepared.guard_size,
            .argument_count = @intCast(arguments.len),
            .stack_pointer = stack_pointer,
        };
        @memcpy(request.arguments[0..arguments.len], arguments);
        const returned = self.bridge.execute(request) catch |err| {
            if (err == error.Interrupted and active_execution.?.exit_requested) {
                if (finalize_thread) return active_execution.?.exit_result;
            }
            return err;
        };
        if (active_execution.?.exit_requested) {
            if (finalize_thread) return active_execution.?.exit_result;
            return error.Interrupted;
        }
        if (finalize_thread) try self.manager.runSpecificDestructors();
        return returned;
    }

    fn start(raw: ?*anyopaque, request: threading.StartRequest) threading.BackendError!void {
        const self = fromContext(raw) orelse return error.Unsupported;
        self.reapDetachedFinished();

        const worker = self.allocator.create(Worker) catch return error.StartFailed;
        worker.* = .{
            .dispatcher = self,
            .request = request,
            .detached = request.detached,
        };
        errdefer self.allocator.destroy(worker);

        self.lock.lock();
        if (self.shutting_down) {
            self.lock.unlock();
            return error.StartFailed;
        }
        self.workers.append(self.allocator, worker) catch {
            self.lock.unlock();
            return error.StartFailed;
        };
        self.lock.unlock();
        errdefer self.removeWorker(worker);

        worker.host_thread = std.Thread.spawn(.{}, workerMain, .{worker}) catch
            return error.StartFailed;
    }

    fn join(raw: ?*anyopaque, thread_handle: u64) threading.BackendError!u64 {
        const self = fromContext(raw) orelse return error.Unsupported;
        self.lock.lock();
        const worker = self.findWorkerLocked(thread_handle) orelse {
            self.lock.unlock();
            return error.ThreadNotFound;
        };
        if (worker.joining) {
            self.lock.unlock();
            return error.JoinFailed;
        }
        worker.joining = true;
        const host_thread = worker.host_thread orelse {
            self.lock.unlock();
            return error.JoinFailed;
        };
        self.lock.unlock();

        host_thread.join();
        self.lock.lock();
        const result = worker.result;
        _ = self.removeWorkerLocked(worker);
        self.lock.unlock();
        self.allocator.destroy(worker);
        return result;
    }

    fn detach(raw: ?*anyopaque, thread_handle: u64) threading.BackendError!void {
        const self = fromContext(raw) orelse return error.Unsupported;
        self.lock.lock();
        const worker = self.findWorkerLocked(thread_handle) orelse {
            self.lock.unlock();
            return error.ThreadNotFound;
        };
        worker.detached = true;
        self.lock.unlock();
        self.reapDetachedFinished();
    }

    fn yield(_: ?*anyopaque) void {
        std.Thread.yield() catch {};
    }

    fn sleep(raw: ?*anyopaque, microseconds: u64) threading.BackendError!void {
        const self = fromContext(raw) orelse return error.Unsupported;
        const duration = std.Io.Clock.Duration{
            .clock = .awake,
            .raw = .fromNanoseconds(@as(i96, microseconds) * std.time.ns_per_us),
        };
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, duration);
        while (true) {
            self.lock.lock();
            if (self.shutting_down) {
                self.lock.unlock();
                return error.WaitFailed;
            }
            const epoch = @atomicLoad(u32, &self.wake_epoch, .acquire);
            self.lock.unlock();

            const now = std.Io.Clock.Timestamp.now(self.io, deadline.clock);
            if (std.Io.Clock.Timestamp.compare(deadline, .lte, now)) return;
            self.io.futexWaitTimeout(
                u32,
                &self.wake_epoch,
                epoch,
                .{ .deadline = deadline },
            ) catch return error.WaitFailed;
        }
    }

    fn wait(
        raw: ?*anyopaque,
        request: threading.WaitRequest,
    ) threading.BackendError!threading.WaitResult {
        const self = fromContext(raw) orelse return error.Unsupported;
        const timeout = makeTimeout(self.io, request);
        const deadline = timeout.toTimestamp(self.io);

        while (true) {
            self.lock.lock();
            if (self.shutting_down) {
                self.lock.unlock();
                return error.WaitFailed;
            }
            if (self.consumeWakeLocked(request)) {
                self.lock.unlock();
                return .awoken;
            }
            const epoch = @atomicLoad(u32, &self.wake_epoch, .acquire);
            self.lock.unlock();

            if (deadline) |end| {
                const now = std.Io.Clock.Timestamp.now(self.io, end.clock);
                if (std.Io.Clock.Timestamp.compare(end, .lte, now)) return .timed_out;
            }
            self.io.futexWaitTimeout(u32, &self.wake_epoch, epoch, timeout) catch
                return error.WaitFailed;
        }
    }

    fn wake(
        raw: ?*anyopaque,
        key: u64,
        sequence: u64,
        maximum_waiters: usize,
    ) void {
        const self = fromContext(raw) orelse return;
        self.lock.lock();
        if (!self.shutting_down) self.recordWakeLocked(key, sequence, maximum_waiters);
        self.lock.unlock();
        self.publishWake();
    }

    fn call(raw: ?*anyopaque, guest_call: threading.GuestCall) threading.BackendError!void {
        const self = fromContext(raw) orelse return error.Unsupported;
        const active = active_execution orelse return error.CallFailed;
        if (active.dispatcher != self or active.thread_handle != guest_call.thread_handle) {
            return error.CallFailed;
        }
        var request = ExecuteRequest{
            .kind = .guest_callback,
            .entry_point = guest_call.entry_point,
            .thread_handle = guest_call.thread_handle,
            .argument_count = guest_call.argument_count,
            .context = active.context,
            .stack_address = active.stack_address,
            .stack_size = active.stack_size,
            .guard_size = active.guard_size,
        };
        @memcpy(request.arguments[0..guest_call.argument_count], guest_call.arguments[0..guest_call.argument_count]);
        _ = self.bridge.execute(request) catch |err| {
            if (err == error.Unsupported) return error.Unsupported;
            if (err == error.Interrupted and active_execution.?.exit_requested) return;
            return error.CallFailed;
        };
    }

    fn requestExit(raw: ?*anyopaque, thread_handle: u64, result: u64) void {
        const self = fromContext(raw) orelse return;
        if (active_execution) |*active| {
            if (active.dispatcher != self or active.thread_handle != thread_handle) return;
            active.exit_requested = true;
            active.exit_result = result;
            self.bridge.interrupt(thread_handle);
        }
    }

    fn workerMain(worker: *Worker) void {
        const self = worker.dispatcher;
        const handle: threading.ThreadHandle = @ptrFromInt(worker.request.thread_handle);
        var result: u64 = 0;
        var failed = false;

        self.manager.enter(handle) catch {
            failed = true;
        };
        if (!failed) {
            active_execution = .{
                .dispatcher = self,
                .thread_handle = worker.request.thread_handle,
                .context = worker.request.context,
                .stack_address = worker.request.stack_address,
                .stack_size = worker.request.stack_size,
                .guard_size = worker.request.guard_size,
            };
            const request = ExecuteRequest{
                .kind = .pthread_entry,
                .entry_point = worker.request.entry_point,
                .thread_handle = worker.request.thread_handle,
                .arguments = .{ worker.request.argument, 0, 0, 0, 0, 0 },
                .argument_count = 1,
                .context = worker.request.context,
                .stack_address = worker.request.stack_address,
                .stack_size = worker.request.stack_size,
                .guard_size = worker.request.guard_size,
            };
            result = self.bridge.execute(request) catch |err| blk: {
                if (err == error.Interrupted and active_execution.?.exit_requested) {
                    break :blk active_execution.?.exit_result;
                }
                failed = true;
                break :blk 0;
            };
            if (active_execution.?.exit_requested) {
                result = active_execution.?.exit_result;
            } else if (!failed) {
                self.manager.runSpecificDestructors() catch {
                    failed = true;
                };
            }
            active_execution = null;
            self.manager.leave();
        }

        self.manager.complete(handle, result) catch {
            failed = true;
        };
        self.lock.lock();
        worker.result = result;
        worker.execution_failed = failed;
        worker.finished = true;
        self.lock.unlock();
        self.publishWake();
    }

    fn reapDetachedFinished(self: *Dispatcher) void {
        while (true) {
            self.lock.lock();
            var found: ?*Worker = null;
            for (self.workers.items) |worker| {
                if (worker.detached and worker.finished and !worker.joining) {
                    worker.joining = true;
                    found = worker;
                    _ = self.removeWorkerLocked(worker);
                    break;
                }
            }
            self.lock.unlock();
            const worker = found orelse return;
            if (worker.host_thread) |host_thread| host_thread.join();
            self.allocator.destroy(worker);
        }
    }

    fn removeWorker(self: *Dispatcher, worker: *Worker) void {
        self.lock.lock();
        _ = self.removeWorkerLocked(worker);
        self.lock.unlock();
    }

    fn removeWorkerLocked(self: *Dispatcher, worker: *Worker) bool {
        for (self.workers.items, 0..) |known, index| {
            if (known != worker) continue;
            _ = self.workers.orderedRemove(index);
            return true;
        }
        return false;
    }

    fn findWorkerLocked(self: *Dispatcher, thread_handle: u64) ?*Worker {
        for (self.workers.items) |worker| {
            if (worker.request.thread_handle == thread_handle) return worker;
        }
        return null;
    }

    fn findKeyLocked(self: *Dispatcher, key: u64) ?*KeyState {
        for (self.key_states) |*state| {
            if (state.used and state.key == key) return state;
        }
        return null;
    }

    fn findOrCreateKeyLocked(self: *Dispatcher, key: u64) ?*KeyState {
        if (self.findKeyLocked(key)) |state| return state;
        for (self.key_states) |*state| {
            if (state.used) continue;
            state.* = .{ .used = true, .key = key };
            return state;
        }
        self.saturated_keys = true;
        return null;
    }

    fn consumeWakeLocked(self: *Dispatcher, request: threading.WaitRequest) bool {
        // Saturation degrades to polling rather than risking a permanent lost
        // wakeup when a title creates more synchronization keys than expected.
        if (self.saturated_keys) return true;
        const state = self.findOrCreateKeyLocked(request.key) orelse return true;
        if (sequenceAfter(state.broadcast_sequence, request.observed_sequence)) return true;
        for (&state.events) |*event| {
            if (event.remaining == 0 or
                !sequenceAfter(event.sequence, request.observed_sequence)) continue;
            event.remaining -= 1;
            return true;
        }
        return false;
    }

    fn recordWakeLocked(
        self: *Dispatcher,
        key: u64,
        sequence: u64,
        maximum_waiters: usize,
    ) void {
        if (maximum_waiters == 0) return;
        const state = self.findOrCreateKeyLocked(key) orelse return;
        state.latest_sequence = sequence;
        if (maximum_waiters == wake_all) {
            state.broadcast_sequence = sequence;
            @memset(&state.events, .{});
            return;
        }

        for (&state.events) |*event| {
            if (event.remaining != 0 and event.sequence == sequence) {
                event.remaining +|= maximum_waiters;
                return;
            }
        }
        for (&state.events) |*event| {
            if (event.remaining != 0) continue;
            event.* = .{ .sequence = sequence, .remaining = maximum_waiters };
            return;
        }

        // More than `events_per_key` unconsumed signals means the exact waiter
        // cardinality is unavailable. A broadcast is the only safe fallback:
        // over-waking is recoverable because HLE rechecks object state, while a
        // dropped wake can deadlock the process.
        state.broadcast_sequence = sequence;
        @memset(&state.events, .{});
    }

    fn publishWake(self: *Dispatcher) void {
        _ = @atomicRmw(u32, &self.wake_epoch, .Add, 1, .release);
        self.io.futexWake(u32, &self.wake_epoch, std.math.maxInt(u32));
    }
};

fn fromContext(raw: ?*anyopaque) ?*Dispatcher {
    const pointer = raw orelse return null;
    const self: *Dispatcher = @ptrCast(@alignCast(pointer));
    return if (self.initialized) self else null;
}

fn sequenceAfter(candidate: u64, observed: u64) bool {
    if (candidate == 0 or candidate == observed) return false;
    return candidate -% observed < (@as(u64, 1) << 63);
}

fn guestClock(clock_id: i32) std.Io.Clock {
    return switch (clock_id) {
        0, 9, 10, 13 => .real,
        else => .awake,
    };
}

fn makeTimeout(io: std.Io, request: threading.WaitRequest) std.Io.Timeout {
    if (request.absolute_deadline_ns) |nanoseconds| {
        return .{ .deadline = .{
            .clock = guestClock(request.clock_id),
            .raw = .fromNanoseconds(@intCast(nanoseconds)),
        } };
    }
    if (request.timeout_microseconds) |microseconds| {
        const duration = std.Io.Clock.Duration{
            .clock = .awake,
            .raw = .fromNanoseconds(@as(i96, microseconds) * std.time.ns_per_us),
        };
        return .{ .deadline = std.Io.Clock.Timestamp.fromNow(io, duration) };
    }
    return .none;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const loader = @import("loader");

const TestBridge = struct {
    manager: *threading.Manager,
    calls: std.atomic.Value(usize) = .init(0),
    callbacks: std.atomic.Value(usize) = .init(0),
    last_fs_base: std.atomic.Value(u64) = .init(0),
    saw_stack: std.atomic.Value(bool) = .init(false),
    invoke_callback: bool = false,
    request_exit_result: ?u64 = null,

    fn execute(raw: ?*anyopaque, request: ExecuteRequest) ExecutionError!u64 {
        const self: *TestBridge = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.last_fs_base.store(request.context.fs_base, .release);
        self.saw_stack.store(request.stack_address != 0 and request.stack_size != 0, .release);
        if (request.kind == .guest_callback) {
            _ = self.callbacks.fetchAdd(1, .acq_rel);
            return 0;
        }
        if (self.invoke_callback) {
            self.manager.callGuest(0xfeed, &.{0xbeef}) catch return error.ExecutionFailed;
        }
        if (self.request_exit_result) |result| {
            threading.scePthreadExit(@ptrFromInt(result));
        }
        return request.arguments[0] + 1;
    }

    fn value(self: *TestBridge) Bridge {
        return .{ .context = self, .execute_fn = &execute };
    }
};

const TestContext = struct {
    address_space: memory.AddressSpace = undefined,
    tls_registry: loader.TlsRegistry = .{},
    manager: threading.Manager = .{},
    bridge: TestBridge = undefined,
    dispatcher: Dispatcher = .{},

    fn init(self: *TestContext) !void {
        self.* = .{};
        self.address_space = try memory.AddressSpace.init(testing.allocator);
        self.manager.init(testing.allocator, &self.address_space, &self.tls_registry);
        self.bridge = .{ .manager = &self.manager };
        try self.dispatcher.init(
            testing.allocator,
            testing.io,
            &self.manager,
            self.bridge.value(),
        );
        threading.attachManager(&self.manager);
    }

    fn deinit(self: *TestContext) void {
        threading.attachManager(null);
        self.dispatcher.deinit();
        self.manager.deinit();
        self.tls_registry.deinit(testing.allocator);
        self.address_space.deinit();
    }
};

test "initial dispatch carries FS, stack, arguments, and nested callbacks" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    context.bridge.invoke_callback = true;

    const prepared = try context.manager.prepareInitialThread("eboot-main");
    defer context.manager.releaseInitialThread(prepared.handle) catch {};
    const stack_mapping_address = prepared.stack_address - prepared.guard_size;
    const stack_mapping_size = prepared.guard_size +
        (try alignForwardForTest(prepared.stack_size, memory.page_size));
    const guard = context.address_space.query(stack_mapping_address, false).?;
    const stack = context.address_space.query(prepared.stack_address, false).?;
    try testing.expectEqual(memory.Protection.none, guard.protection);
    try testing.expect(stack.protection.write);
    const result = try context.dispatcher.dispatchInitial(prepared, 0x1234, &.{41});

    try testing.expectEqual(@as(u64, 42), result);
    try testing.expect(context.bridge.last_fs_base.load(.acquire) != 0);
    try testing.expect(context.bridge.saw_stack.load(.acquire));
    try testing.expectEqual(@as(usize, 1), context.bridge.callbacks.load(.acquire));
    try context.manager.releaseInitialThread(prepared.handle);
    try testing.expect(!context.address_space.isMapped(stack_mapping_address, stack_mapping_size));
}

test "pthread start and join run on a dispatcher host worker" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();

    var handle: threading.ThreadHandle = null;
    try context.manager.create(&handle, .{}, 0x4567, 9, "guest-worker");
    const result = try context.manager.join(handle);

    try testing.expectEqual(@as(u64, 10), result);
    try testing.expect(context.bridge.last_fs_base.load(.acquire) != 0);
    try testing.expect(context.bridge.saw_stack.load(.acquire));
}

test "scePthreadExit overrides a pthread entry return value" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();
    context.bridge.request_exit_result = 0x55;

    var handle: threading.ThreadHandle = null;
    try context.manager.create(&handle, .{}, 0x4567, 9, "guest-exit");
    try testing.expectEqual(@as(u64, 0x55), try context.manager.join(handle));
}

test "wake before park is consumed exactly once" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();

    Dispatcher.wake(&context.dispatcher, 0x1000, 2, 1);
    try testing.expectEqual(
        threading.WaitResult.awoken,
        try Dispatcher.wait(&context.dispatcher, .{
            .key = 0x1000,
            .observed_sequence = 1,
            .timeout_microseconds = 0,
        }),
    );
    try testing.expectEqual(
        threading.WaitResult.timed_out,
        try Dispatcher.wait(&context.dispatcher, .{
            .key = 0x1000,
            .observed_sequence = 1,
            .timeout_microseconds = 0,
        }),
    );
}

test "new waiters do not consume stale signal tokens" {
    var context = TestContext{};
    try context.init();
    defer context.deinit();

    Dispatcher.wake(&context.dispatcher, 0x2000, 2, 1);
    Dispatcher.wake(&context.dispatcher, 0x2000, 3, 1);
    try testing.expectEqual(
        threading.WaitResult.awoken,
        try Dispatcher.wait(&context.dispatcher, .{
            .key = 0x2000,
            .observed_sequence = 2,
            .timeout_microseconds = 0,
        }),
    );
    try testing.expectEqual(
        threading.WaitResult.timed_out,
        try Dispatcher.wait(&context.dispatcher, .{
            .key = 0x2000,
            .observed_sequence = 3,
            .timeout_microseconds = 0,
        }),
    );
}

test "native bridge installs FS, SysV arguments, and the guest stack" {
    if (!NativeBridge.isSupported()) return error.SkipZigTest;

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();

    const code_address = memory.system_managed.start;
    const tls_address = code_address + memory.page_size;
    const stack_address = tls_address + memory.page_size;
    try address_space.mapFixed(
        code_address,
        memory.page_size,
        .read_write,
        .module,
        null,
    );
    try address_space.mapFixed(
        tls_address,
        memory.page_size,
        .read_write,
        .private,
        null,
    );
    try address_space.mapFixed(
        stack_address,
        memory.page_size,
        .read_write,
        .private,
        null,
    );
    try address_space.writeInt(u64, tls_address, tls_address);

    // Read FS:[0] and add all six System V integer argument registers.
    const fs_program = [_]u8{
        0x64, 0x48, 0x8b, 0x04, 0x25, 0x00, 0x00, 0x00, 0x00,
        0x48, 0x01, 0xf8, 0x48, 0x01, 0xf0, 0x48, 0x01, 0xd0,
        0x48, 0x01, 0xc8, 0x4c, 0x01, 0xc0, 0x4c, 0x01, 0xc8,
        0xc3,
    };
    // mov rax, rsp; ret
    const stack_program = [_]u8{ 0x48, 0x89, 0xe0, 0xc3 };
    try address_space.write(code_address, &fs_program);
    try address_space.write(code_address + 0x20, &stack_program);
    try address_space.protect(code_address, memory.page_size, .read_execute);

    var native = NativeBridge{};
    try native.init(testing.allocator, &address_space);
    defer native.deinit();
    const machine = native.bridge();
    const context = threading.ThreadContext{
        .tls_mapping_address = tls_address,
        .tls_mapping_size = memory.page_size,
        .fs_base = tls_address,
        .dtv_address = tls_address + 0x100,
        .tls_generation = 1,
    };
    const host_fs_before = NativeMachine.readFsBase();
    const result = try machine.execute(.{
        .kind = .process_entry,
        .entry_point = code_address,
        .thread_handle = 1,
        .arguments = .{ 1, 2, 3, 4, 5, 6 },
        .argument_count = 6,
        .context = context,
        .stack_address = stack_address,
        .stack_size = memory.page_size,
        .guard_size = 0,
    });
    try testing.expectEqual(tls_address + 21, result);
    try testing.expectEqual(host_fs_before, NativeMachine.readFsBase());

    const requested_stack_pointer = stack_address + memory.page_size - 0x100;
    const observed_rsp = try machine.execute(.{
        .kind = .process_entry,
        .entry_point = code_address + 0x20,
        .thread_handle = 1,
        .context = context,
        .stack_address = stack_address,
        .stack_size = memory.page_size,
        .guard_size = 0,
        .stack_pointer = requested_stack_pointer,
    });
    try testing.expectEqual(requested_stack_pointer - 8, observed_rsp);
    try testing.expectEqual(@as(u64, 8), observed_rsp & 0xf);
}

test "Windows context compatibility advances AMD wait instructions" {
    if (can_use_native_bridge) {
        const monitorx = [_]u8{ 0x0f, 0x01, 0xfa };
        const mwaitx = [_]u8{ 0x0f, 0x01, 0xfb };
        const unknown = [_]u8{ 0x0f, 0x0b };
        var context = std.mem.zeroes(std.os.windows.CONTEXT);

        context.Rip = @intFromPtr(&monitorx);
        try testing.expect(WindowsX64Machine.tryEmulateIllegalInstruction(&context));
        try testing.expectEqual(@intFromPtr(&monitorx) + monitorx.len, context.Rip);

        context.Rip = @intFromPtr(&mwaitx);
        try testing.expect(WindowsX64Machine.tryEmulateIllegalInstruction(&context));
        try testing.expectEqual(@intFromPtr(&mwaitx) + mwaitx.len, context.Rip);

        context.Rip = @intFromPtr(&unknown);
        try testing.expect(!WindowsX64Machine.tryEmulateIllegalInstruction(&context));
        try testing.expectEqual(@intFromPtr(&unknown), context.Rip);
    } else {
        return error.SkipZigTest;
    }
}

test "native bridge contains guest access and illegal instruction faults" {
    if (!NativeBridge.isSupported()) return error.SkipZigTest;

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();

    const code_address = memory.system_managed.start;
    const tls_address = code_address + memory.page_size;
    const stack_address = tls_address + memory.page_size;
    try address_space.mapFixed(
        code_address,
        memory.page_size,
        .read_write,
        .module,
        null,
    );
    try address_space.mapFixed(
        tls_address,
        memory.page_size,
        .read_write,
        .private,
        null,
    );
    try address_space.mapFixed(
        stack_address,
        memory.page_size,
        .read_write,
        .private,
        null,
    );

    // mov rax, qword ptr [0]; ret
    try address_space.write(
        code_address,
        &.{ 0x48, 0x8b, 0x04, 0x25, 0, 0, 0, 0, 0xc3 },
    );
    // ud2; ret
    try address_space.write(code_address + 0x20, &.{ 0x0f, 0x0b, 0xc3 });
    // mov eax, 42; ret
    try address_space.write(
        code_address + 0x40,
        &.{ 0xb8, 42, 0, 0, 0, 0xc3 },
    );
    // mov rax, value; movq xmm1, rax; extrq xmm1, 8, 8;
    // movq rax, xmm1; ret
    var extrq_program = [_]u8{
        0x48, 0xb8, 0,    0,    0,    0,    0,    0,    0,    0,
        0x66, 0x48, 0x0f, 0x6e, 0xc8, 0x66, 0x0f, 0x78, 0xc1, 0x08,
        0x08, 0x66, 0x48, 0x0f, 0x7e, 0xc8, 0xc3,
    };
    std.mem.writeInt(u64, extrq_program[2..10], 0x0123_4567_89ab_cdef, .little);
    try address_space.write(code_address + 0x80, &extrq_program);

    // movq xmm1, destination; movq xmm2, source;
    // insertq xmm1, xmm2, 8, 16; movq rax, xmm1; ret
    var insertq_program = [_]u8{
        0x48, 0xb8, 0,    0,    0,    0,    0,    0,    0,    0,
        0x66, 0x48, 0x0f, 0x6e, 0xc8, 0x48, 0xb8, 0,    0,    0,
        0,    0,    0,    0,    0,    0x66, 0x48, 0x0f, 0x6e, 0xd0,
        0xf2, 0x0f, 0x78, 0xca, 0x08, 0x10, 0x66, 0x48, 0x0f, 0x7e,
        0xc8, 0xc3,
    };
    std.mem.writeInt(u64, insertq_program[2..10], 0xaaaa_bbbb_ccdd_eeee, .little);
    std.mem.writeInt(u64, insertq_program[17..25], 0x1234, .little);
    try address_space.write(code_address + 0xc0, &insertq_program);
    try address_space.protect(code_address, memory.page_size, .read_execute);

    var native = NativeBridge{};
    try native.init(testing.allocator, &address_space);
    defer native.deinit();
    const machine = native.bridge();
    const thread_handle = 0x1234;
    const context = threading.ThreadContext{
        .tls_mapping_address = tls_address,
        .tls_mapping_size = memory.page_size,
        .fs_base = tls_address,
        .dtv_address = tls_address + 0x100,
        .tls_generation = 1,
    };
    const base_request = ExecuteRequest{
        .kind = .process_entry,
        .entry_point = code_address,
        .thread_handle = thread_handle,
        .context = context,
        .stack_address = stack_address,
        .stack_size = memory.page_size,
        .guard_size = 0,
    };
    const host_fs_before = NativeMachine.readFsBase();

    try testing.expectError(error.GuestFault, machine.execute(base_request));
    const access_fault = native.lastFault().?;
    try testing.expectEqual(thread_handle, access_fault.thread_handle);
    try testing.expectEqual(FaultKind.access_violation, access_fault.info.kind);
    try testing.expectEqual(FaultAccess.read, access_fault.info.access);
    try testing.expectEqual(
        @as(u32, std.os.windows.EXCEPTION_ACCESS_VIOLATION),
        access_fault.info.exception_code,
    );
    try testing.expectEqual(code_address, access_fault.info.instruction_address);
    try testing.expectEqual(@as(u64, 0), access_fault.info.memory_address);
    try testing.expect(access_fault.info.registers.rsp >= stack_address);
    try testing.expect(
        access_fault.info.registers.rsp < stack_address + memory.page_size,
    );
    try testing.expectEqual(host_fs_before, NativeMachine.readFsBase());

    var illegal_request = base_request;
    illegal_request.entry_point = code_address + 0x20;
    try testing.expectError(error.GuestFault, machine.execute(illegal_request));
    const illegal_fault = native.lastFault().?;
    try testing.expectEqual(FaultKind.illegal_instruction, illegal_fault.info.kind);
    try testing.expectEqual(FaultAccess.unknown, illegal_fault.info.access);
    try testing.expectEqual(code_address + 0x20, illegal_fault.info.registers.rip);
    try testing.expectEqual(host_fs_before, NativeMachine.readFsBase());

    var valid_request = base_request;
    valid_request.entry_point = code_address + 0x40;
    try testing.expectEqual(@as(u64, 42), try machine.execute(valid_request));
    try testing.expect(native.lastFault() == null);

    var extract_request = base_request;
    extract_request.entry_point = code_address + 0x80;
    try testing.expectEqual(@as(u64, 0xcd), try machine.execute(extract_request));
    try testing.expect(native.lastFault() == null);

    var insert_request = base_request;
    insert_request.entry_point = code_address + 0xc0;
    try testing.expectEqual(
        @as(u64, 0xaaaa_bbbb_cc34_eeee),
        try machine.execute(insert_request),
    );
    try testing.expect(native.lastFault() == null);
}

test "native bridge executes a pthread on its dispatcher worker" {
    if (!NativeBridge.isSupported()) return error.SkipZigTest;

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    const code_address = memory.system_managed.start;
    try address_space.mapFixed(
        code_address,
        memory.page_size,
        .read_write,
        .module,
        null,
    );
    // lea rax, [rdi + 1]; ret
    try address_space.write(code_address, &.{ 0x48, 0x8d, 0x47, 0x01, 0xc3 });
    try address_space.protect(code_address, memory.page_size, .read_execute);

    var tls_registry: loader.TlsRegistry = .{};
    defer tls_registry.deinit(testing.allocator);
    var manager = threading.Manager{};
    manager.init(testing.allocator, &address_space, &tls_registry);
    defer manager.deinit();
    var native = NativeBridge{};
    try native.init(testing.allocator, &address_space);
    defer native.deinit();
    var dispatcher = Dispatcher{};
    try dispatcher.init(
        testing.allocator,
        testing.io,
        &manager,
        native.bridge(),
    );
    defer dispatcher.deinit();

    var handle: threading.ThreadHandle = null;
    try manager.create(&handle, .{}, code_address, 41, "native-worker");
    try testing.expectEqual(@as(u64, 42), try manager.join(handle));
}

test "native bridge unwinds scePthreadExit to the dispatcher" {
    if (!NativeBridge.isSupported()) return error.SkipZigTest;

    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    const code_address = memory.system_managed.start;
    try address_space.mapFixed(
        code_address,
        memory.page_size,
        .read_write,
        .module,
        null,
    );

    // mov rdi, 0x55; mov rax, scePthreadExit; call rax; ud2
    var program = [_]u8{
        0x48, 0xbf, 0,    0,    0, 0, 0, 0, 0, 0,
        0x48, 0xb8, 0,    0,    0, 0, 0, 0, 0, 0,
        0xff, 0xd0, 0x0f, 0x0b,
    };
    std.mem.writeInt(u64, program[2..10], 0x55, .little);
    std.mem.writeInt(
        u64,
        program[12..20],
        @intFromPtr(&threading.scePthreadExit),
        .little,
    );
    try address_space.write(code_address, &program);
    try address_space.protect(code_address, memory.page_size, .read_execute);

    var tls_registry: loader.TlsRegistry = .{};
    defer tls_registry.deinit(testing.allocator);
    var manager = threading.Manager{};
    manager.init(testing.allocator, &address_space, &tls_registry);
    defer manager.deinit();
    var native = NativeBridge{};
    try native.init(testing.allocator, &address_space);
    defer native.deinit();
    var dispatcher = Dispatcher{};
    try dispatcher.init(
        testing.allocator,
        testing.io,
        &manager,
        native.bridge(),
    );
    defer dispatcher.deinit();
    threading.attachManager(&manager);
    defer threading.attachManager(null);

    const prepared = try manager.prepareInitialThread("native-exit");
    defer manager.releaseInitialThread(prepared.handle) catch {};
    try testing.expectEqual(
        @as(u64, 0x55),
        try dispatcher.dispatchInitial(prepared, code_address, &.{}),
    );
}

fn alignForwardForTest(value: u64, alignment: u64) !u64 {
    return std.mem.alignForward(u64, value, alignment);
}
