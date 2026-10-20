// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Asynchronous file reads and writes.
//!
//! A title hands over a batch of read requests and an identifier comes back;
//! later it asks whether that batch is done and collects the results. Engines
//! that stream assets do all of their loading this way, so without it such a
//! title cannot read a single file.
//!
//! The reads are carried out where the batch is submitted, so a batch is always
//! finished by the time anyone asks about it. That is a legal outcome of this
//! interface rather than a shortcut around it: a caller has to cope with a
//! request that completed immediately, because a fast device does exactly that.
//! The alternative — a pool of threads of our own — would invent an ordering
//! between requests that a title could come to depend on before there is any
//! real device to justify it.
//!
//! Save writes use the same completed-batch model and positional filesystem
//! writes. Installed game content remains read-only; writable save and staging
//! mounts persist the bytes before a request reports success.

const std = @import("std");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const filesystem = @import("../filesystem.zig");
const memory = @import("kernel_memory.zig");

const KernelError = errno.KernelError;

/// How a request or a batch stands.
pub const state_submitted: u32 = 1;
pub const state_processing: u32 = 2;
pub const state_completed: u32 = 3;
pub const state_aborted: u32 = 4;

/// The most requests one batch may carry.
pub const maximum_requests: i32 = 128;

/// How many batches can be outstanding at once.
const queue_size: usize = 512;

/// Where one request's outcome is written, in the title's own memory.
pub const Result = extern struct {
    return_value: i64,
    state: u32,
};

/// One read or write, as the title describes it.
pub const Request = extern struct {
    offset: i64,
    length: u64,
    buffer: ?[*]u8,
    result: ?*Result,
    descriptor: i32,
};

comptime {
    // The title allocates these itself and the fields are read straight out of
    // its memory, so a layout that drifts silently misreads every request.
    if (@sizeOf(Result) != 16) @compileError("SceKernelAioResult must be 16 bytes");
    if (@offsetOf(Result, "state") != 8) @compileError("result state sits after the value");
    if (@sizeOf(Request) != 40) @compileError("SceKernelAioRWRequest must be 40 bytes");
    if (@offsetOf(Request, "length") != 8) @compileError("request length follows the offset");
    if (@offsetOf(Request, "buffer") != 16) @compileError("request buffer follows the length");
    if (@offsetOf(Request, "result") != 24) @compileError("request result follows the buffer");
    if (@offsetOf(Request, "descriptor") != 32) @compileError("request descriptor comes last");
}

/// A spin lock over the batch table, matching the one the memory pool uses.
const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

/// Batch states, indexed by identifier. Slot zero is never handed out so that
/// zero stays available as "no batch".
var batches: [queue_size]u32 = @splat(0);
var next_identifier: usize = 1;
var table_lock: Lock = .{};

pub fn reset() void {
    table_lock.lock();
    defer table_lock.unlock();
    batches = @splat(0);
    next_identifier = 1;
}

fn isValidIdentifier(identifier: i32) bool {
    return identifier > 0 and identifier < queue_size;
}

/// Claims a free batch slot, or zero when every slot is still held.
///
/// The search skips slots a title has not deleted yet. Handing out an
/// identifier that is still outstanding makes two batches share one slot: the
/// older batch then reports the newer one's state, deleting either frees the
/// slot both believe they own, and the survivor's own delete fails. A title
/// that streams keeps requests alive across many submissions, so a table this
/// size wraps onto live entries during ordinary loading rather than only under
/// abuse.
fn claimIdentifier() i32 {
    table_lock.lock();
    defer table_lock.unlock();
    var examined: usize = 0;
    while (examined < queue_size - 1) : (examined += 1) {
        const identifier = next_identifier;
        next_identifier += 1;
        if (next_identifier >= queue_size) next_identifier = 1;
        if (batches[identifier] != 0) continue;
        batches[identifier] = state_processing;
        return @intCast(identifier);
    }
    return 0;
}

fn setBatchState(identifier: i32, value: u32) void {
    if (!isValidIdentifier(identifier)) return;
    table_lock.lock();
    defer table_lock.unlock();
    batches[@intCast(identifier)] = value;
}

fn batchState(identifier: i32) ?u32 {
    if (!isValidIdentifier(identifier)) return null;
    table_lock.lock();
    defer table_lock.unlock();
    const value = batches[@intCast(identifier)];
    return if (value == 0) null else value;
}

/// Carries out one read and records what happened where the title asked.
fn performRead(request: *const Request) void {
    const record = request.result.?;
    record.state = state_submitted;

    if (request.offset < 0 or request.length == 0) {
        record.return_value = KernelError.einval.raw();
        record.state = state_aborted;
        return;
    }

    const address = @intFromPtr(request.buffer orelse {
        record.return_value = KernelError.efault.raw();
        record.state = state_aborted;
        return;
    });
    if (!memory.isGuestRangeAccessible(address, request.length)) {
        record.return_value = KernelError.efault.raw();
        record.state = state_aborted;
        return;
    }

    const destination: [*]u8 = @ptrFromInt(address);
    const count = filesystem.pread(
        request.descriptor,
        destination[0..request.length],
        @intCast(request.offset),
    ) catch {
        record.return_value = KernelError.eio.raw();
        record.state = state_aborted;
        return;
    };

    // A short read is not a failure: it means the file ended, and the count is
    // how the caller learns that.
    record.return_value = @intCast(count);
    record.state = state_completed;
}

fn performWrite(request: *const Request) void {
    const record = request.result.?;
    record.state = state_aborted;
    if (request.offset < 0 or request.length == 0) {
        record.return_value = KernelError.einval.raw();
        return;
    }
    const buffer = request.buffer orelse {
        record.return_value = KernelError.efault.raw();
        return;
    };
    if (!memory.isGuestRangeAccessible(@intFromPtr(buffer), request.length)) {
        record.return_value = KernelError.efault.raw();
        return;
    }
    const count = filesystem.pwrite(request.descriptor, buffer[0..request.length], @intCast(request.offset)) catch |err| {
        record.return_value = switch (err) {
            error.ReadOnly => KernelError.eacces.raw(),
            error.BadDescriptor => KernelError.ebadf.raw(),
            error.InvalidArgument => KernelError.einval.raw(),
            else => KernelError.eio.raw(),
        };
        return;
    };
    record.return_value = @intCast(count);
    record.state = state_completed;
}

fn submit(
    requests: ?[*]Request,
    count: i32,
    identifier_out: ?*i32,
    comptime writing: bool,
) i32 {
    const batch = requests orelse return KernelError.efault.raw();
    const out = identifier_out orelse return KernelError.efault.raw();
    if (count <= 0 or count > maximum_requests) return KernelError.einval.raw();
    if (!memory.isGuestRangeAccessible(@intFromPtr(out), @sizeOf(i32))) return KernelError.efault.raw();

    const total: usize = @intCast(count);
    if (!memory.isGuestRangeAccessible(@intFromPtr(batch), total * @sizeOf(Request))) {
        return KernelError.efault.raw();
    }

    // Checked before anything runs: a batch that names nowhere to put an
    // outcome cannot report one, and finding that out halfway through would
    // leave some requests done and the caller unable to learn which.
    for (batch[0..total]) |*request| {
        const result = request.result orelse return KernelError.efault.raw();
        if (!memory.isGuestRangeAccessible(@intFromPtr(result), @sizeOf(Result))) return KernelError.efault.raw();
    }

    // Every slot outstanding is a real condition for a caller to see, and the
    // interface has an answer for it. Carrying on with a stolen identifier
    // would corrupt the batch a title still holds.
    const identifier = claimIdentifier();
    if (identifier == 0) return KernelError.eagain.raw();
    for (batch[0..total]) |*request| {
        if (writing) performWrite(request) else performRead(request);
    }
    setBatchState(identifier, state_completed);

    out.* = identifier;
    return errno.ok;
}

fn submitReadCommands(
    requests: ?[*]Request,
    count: i32,
    _: i32,
    identifier_out: ?*i32,
) callconv(abi.guest) i32 {
    return submit(requests, count, identifier_out, false);
}

fn submitWriteCommands(
    requests: ?[*]Request,
    count: i32,
    _: i32,
    identifier_out: ?*i32,
) callconv(abi.guest) i32 {
    return submit(requests, count, identifier_out, true);
}

/// Waits for a batch, which has already finished.
///
/// The timeout is left untouched rather than being reported as fully consumed:
/// no time passed, and a caller that subtracts what it was told would count
/// time that was never spent.
fn waitRequest(identifier: i32, state_out: ?*u32, _: ?*u32) callconv(abi.guest) i32 {
    const out = state_out orelse return KernelError.efault.raw();
    const value = batchState(identifier) orelse return KernelError.einval.raw();
    out.* = value;
    return errno.ok;
}

/// Reports a batch's state without waiting.
fn pollRequests(identifier: i32, state_out: ?*u32) callconv(abi.guest) i32 {
    const out = state_out orelse return KernelError.efault.raw();
    const value = batchState(identifier) orelse return KernelError.einval.raw();
    out.* = value;
    return errno.ok;
}

/// Releases a batch. Its per-request outcomes live in the title's memory and
/// stay readable afterwards; only the identifier is given up.
fn deleteRequest(identifier: i32, status_out: ?*i32) callconv(abi.guest) i32 {
    const out = status_out orelse return KernelError.efault.raw();
    if (batchState(identifier) == null) return KernelError.einval.raw();
    setBatchState(identifier, 0);
    out.* = errno.ok;
    return errno.ok;
}

/// Accepts the tuning a title offers for a subsystem that needs none.
///
/// There is no queue depth or thread count to set when the work is done where
/// it is submitted, and refusing would stop a title over a preference.
fn initializeImpl(_: ?*anyopaque, _: i32) callconv(abi.guest) i32 {
    return errno.ok;
}

fn initializeParam(_: ?*anyopaque) callconv(abi.guest) void {}

const SchedulingParam = extern struct {
    window: i32,
    delayed_limit: i32,
    split_enabled: u32,
    split_size: u32,
    split_chunk_size: u32,
};

fn setParam(param: ?*align(1) SchedulingParam, window: i32, delayed_limit: i32, split_enabled: u32, split_size: u32, split_chunk_size: u32) callconv(abi.guest) i32 {
    const output = param orelse return KernelError.efault.raw();
    if (window < 0 or window > 128 or delayed_limit < 0 or delayed_limit > 128 or
        split_enabled > 1 or split_size > 0x1000000 or split_chunk_size > 0x1000000) return KernelError.einval.raw();
    if (!@import("memory").isHostRangeWritable(@intFromPtr(output), @sizeOf(SchedulingParam))) return KernelError.efault.raw();
    output.* = .{ .window = window, .delayed_limit = delayed_limit, .split_enabled = split_enabled, .split_size = split_size, .split_chunk_size = split_chunk_size };
    return errno.ok;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceKernelAioSubmitReadCommands", .function = trace.wrap("sceKernelAioSubmitReadCommands", &submitReadCommands), .expect_id = "HgX7+AORI58" },
    .{ .name = "sceKernelAioSubmitWriteCommands", .function = trace.wrap("sceKernelAioSubmitWriteCommands", &submitWriteCommands), .expect_id = "XQ8C8y+de+E" },
    .{ .name = "sceKernelAioWaitRequest", .function = trace.wrap("sceKernelAioWaitRequest", &waitRequest), .expect_id = "KOF-oJbQVvc" },
    .{ .name = "sceKernelAioPollRequests", .function = trace.wrap("sceKernelAioPollRequests", &pollRequests), .expect_id = "o7O4z3jwKzo" },
    .{ .name = "sceKernelAioPollRequest", .function = trace.wrap("sceKernelAioPollRequest", &pollRequests), .expect_id = "2pOuoWoCxdk" },
    .{ .name = "sceKernelAioDeleteRequest", .function = trace.wrap("sceKernelAioDeleteRequest", &deleteRequest), .expect_id = "5TgME6AYty4" },
    .{ .name = "sceKernelAioInitializeImpl", .function = trace.wrap("sceKernelAioInitializeImpl", &initializeImpl), .expect_id = "vYU8P9Td2Zo" },
    .{ .name = "sceKernelAioInitializeParam", .function = trace.wrap("sceKernelAioInitializeParam", &initializeParam), .expect_id = "nu4a0-arQis" },
    .{ .name = "sceKernelAioSetParam", .function = trace.wrap("sceKernelAioSetParam", &setParam), .expect_id = "9WK-vhNXimw" },
};

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(
        gpa,
        .{ .name = "libkernel", .version = 1 },
        .{ .name = "libkernel", .version_major = 1, .version_minor = 1 },
        &exports,
    );
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "a batch is finished by the time anyone asks" {
    // Completing at submit is a legal outcome of this interface, not a shortcut
    // around it: a caller has to cope with a request that finished at once,
    // because a fast device does exactly that.
    reset();
    var record = Result{ .return_value = -1, .state = 0 };
    var request = Request{
        .offset = 0,
        .length = 8,
        .buffer = null,
        .result = &record,
        .descriptor = -1,
    };

    var identifier: i32 = 0;
    try testing.expectEqual(errno.ok, submitReadCommands(@ptrCast(&request), 1, 0, &identifier));
    try testing.expect(identifier > 0);

    var state: u32 = 0;
    try testing.expectEqual(errno.ok, pollRequests(identifier, &state));
    try testing.expectEqual(state_completed, state);
    try testing.expectEqual(errno.ok, waitRequest(identifier, &state, null));
    try testing.expectEqual(state_completed, state);
}

test "a request with nowhere to put its outcome is refused before any work" {
    // Finding this out halfway through would leave some requests done and the
    // caller unable to learn which.
    reset();
    var record = Result{ .return_value = 0, .state = 0 };
    var batch = [_]Request{
        .{ .offset = 0, .length = 8, .buffer = null, .result = &record, .descriptor = -1 },
        .{ .offset = 0, .length = 8, .buffer = null, .result = null, .descriptor = -1 },
    };

    var identifier: i32 = 0;
    try testing.expectEqual(
        KernelError.efault.raw(),
        submitReadCommands(&batch, batch.len, 0, &identifier),
    );
    // The first request was not carried out either.
    try testing.expectEqual(@as(u32, 0), record.state);
}

test "a batch outside what one submission may carry is refused" {
    reset();
    var record = Result{ .return_value = 0, .state = 0 };
    var request = Request{
        .offset = 0,
        .length = 8,
        .buffer = null,
        .result = &record,
        .descriptor = -1,
    };
    var identifier: i32 = 0;

    try testing.expectEqual(
        KernelError.einval.raw(),
        submitReadCommands(@ptrCast(&request), 0, 0, &identifier),
    );
    try testing.expectEqual(
        KernelError.einval.raw(),
        submitReadCommands(@ptrCast(&request), maximum_requests + 1, 0, &identifier),
    );
    try testing.expectEqual(
        KernelError.efault.raw(),
        submitReadCommands(null, 1, 0, &identifier),
    );
    try testing.expectEqual(
        KernelError.efault.raw(),
        submitReadCommands(@ptrCast(&request), 1, 0, null),
    );
}

test "an invalid asynchronous write reports a failed request" {
    // A title told its data was written when it was not carries on and loses it
    // somewhere further along, where nothing points back to here.
    reset();
    var record = Result{ .return_value = 0, .state = 0 };
    var request = Request{
        .offset = 0,
        .length = 8,
        .buffer = null,
        .result = &record,
        .descriptor = -1,
    };

    var identifier: i32 = 0;
    try testing.expectEqual(errno.ok, submitWriteCommands(@ptrCast(&request), 1, 0, &identifier));
    try testing.expectEqual(state_aborted, record.state);
    try testing.expect(record.return_value < 0);
}

test "asynchronous save writes persist positional batches and reject read-only descriptors" {
    reset();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    filesystem.attach(testing.io, tmp.dir);
    defer filesystem.detach();
    filesystem.attachSaveDataHome(tmp.dir, "PPSA00001");
    _ = try filesystem.mountSaveDataSlot("slot", true);
    const fd = try filesystem.open("/savedata0/save.bin", filesystem.O.rdwr | filesystem.O.creat);
    _ = try filesystem.write(fd, "........");
    _ = try filesystem.seek(fd, 2, filesystem.Seek.set);
    var data = "SAVE".*;
    var outcomes: [2]Result = @splat(.{ .return_value = 0, .state = 0 });
    var requests = [_]Request{
        .{ .offset = 0, .length = 4, .buffer = &data, .result = &outcomes[0], .descriptor = fd },
        .{ .offset = 6, .length = 4, .buffer = &data, .result = &outcomes[1], .descriptor = fd },
    };
    var id: i32 = 0;
    try testing.expectEqual(errno.ok, submitWriteCommands(&requests, 2, 0, &id));
    for (outcomes) |result| {
        try testing.expectEqual(state_completed, result.state);
        try testing.expectEqual(@as(i64, 4), result.return_value);
    }
    try testing.expectEqual(@as(i64, 2), try filesystem.seek(fd, 0, filesystem.Seek.cur));
    try filesystem.close(fd);
    filesystem.unmountSaveData();
    try testing.expectEqual(filesystem.SaveDataMountOutcome.existed, try filesystem.mountSaveDataSlot("slot", false));
    const reopened = try filesystem.open("/savedata0/save.bin", filesystem.O.rdonly);
    defer filesystem.close(reopened) catch {};
    var bytes: [10]u8 = undefined;
    try testing.expectEqual(@as(usize, 10), try filesystem.read(reopened, &bytes));
    try testing.expectEqualStrings("SAVE..SAVE", &bytes);
    requests[0].descriptor = reopened;
    try testing.expectEqual(errno.ok, submitWriteCommands(&requests, 1, 0, &id));
    try testing.expectEqual(state_aborted, outcomes[0].state);
    try testing.expectEqual(@as(i64, KernelError.eacces.raw()), outcomes[0].return_value);
    requests[0].offset = -1;
    try testing.expectEqual(errno.ok, submitWriteCommands(&requests, 1, 0, &id));
    try testing.expectEqual(@as(i64, KernelError.einval.raw()), outcomes[0].return_value);
}

test "an unknown batch is refused, and a deleted one stops being known" {
    reset();
    var state: u32 = 0;
    var status: i32 = 0;
    try testing.expectEqual(KernelError.einval.raw(), pollRequests(0, &state));
    try testing.expectEqual(KernelError.einval.raw(), pollRequests(-1, &state));
    try testing.expectEqual(KernelError.einval.raw(), waitRequest(7, &state, null));
    try testing.expectEqual(KernelError.einval.raw(), deleteRequest(7, &status));

    var record = Result{ .return_value = 0, .state = 0 };
    var request = Request{
        .offset = 0,
        .length = 8,
        .buffer = null,
        .result = &record,
        .descriptor = -1,
    };
    var identifier: i32 = 0;
    try testing.expectEqual(errno.ok, submitReadCommands(@ptrCast(&request), 1, 0, &identifier));
    try testing.expectEqual(errno.ok, deleteRequest(identifier, &status));
    try testing.expectEqual(errno.ok, status);
    try testing.expectEqual(KernelError.einval.raw(), pollRequests(identifier, &state));

    // The outcome stays readable: it lives in the title's memory, and only the
    // identifier was given up.
    try testing.expectEqual(state_aborted, record.state);
}

test "identifiers wrap without ever handing out the reserved one" {
    reset();
    var record = Result{ .return_value = 0, .state = 0 };
    var request = Request{
        .offset = 0,
        .length = 8,
        .buffer = null,
        .result = &record,
        .descriptor = -1,
    };

    // Deleting each batch returns its slot, so the table wraps indefinitely.
    for (0..queue_size + 4) |_| {
        var identifier: i32 = 0;
        try testing.expectEqual(errno.ok, submitReadCommands(@ptrCast(&request), 1, 0, &identifier));
        try testing.expect(identifier > 0);
        try testing.expect(identifier < queue_size);
        var status: i32 = 0;
        try testing.expectEqual(errno.ok, deleteRequest(identifier, &status));
    }
}

test "an outstanding batch keeps its identifier until it is deleted" {
    reset();
    var record = Result{ .return_value = 0, .state = 0 };
    var request = Request{
        .offset = 0,
        .length = 8,
        .buffer = null,
        .result = &record,
        .descriptor = -1,
    };

    // A title that streams holds batches open across many submissions. Reusing
    // a live identifier would make two batches share one slot, so the table
    // fills up instead and says so.
    var seen: [queue_size]bool = @splat(false);
    var held: usize = 0;
    while (held < queue_size - 1) : (held += 1) {
        var identifier: i32 = 0;
        try testing.expectEqual(errno.ok, submitReadCommands(@ptrCast(&request), 1, 0, &identifier));
        try testing.expect(identifier > 0);
        try testing.expect(!seen[@intCast(identifier)]);
        seen[@intCast(identifier)] = true;
    }

    var overflow: i32 = 0;
    try testing.expectEqual(
        KernelError.eagain.raw(),
        submitReadCommands(@ptrCast(&request), 1, 0, &overflow),
    );

    // Releasing one makes exactly that slot available again.
    var status: i32 = 0;
    try testing.expectEqual(errno.ok, deleteRequest(7, &status));
    var reused: i32 = 0;
    try testing.expectEqual(errno.ok, submitReadCommands(@ptrCast(&request), 1, 0, &reused));
    try testing.expectEqual(@as(i32, 7), reused);
}

test "asynchronous read exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len, db.count());
    try testing.expect(db.findByName("sceKernelAioSubmitReadCommands", .function) != null);
}

test "AMM AIO scheduling parameters write the guest structure and reject invalid values" {
    var params = SchedulingParam{ .window = -1, .delayed_limit = -1, .split_enabled = 99, .split_size = 99, .split_chunk_size = 99 };
    try testing.expectEqual(errno.ok, setParam(&params, 128, 64, 1, 0x100000, 0x10000));
    try testing.expectEqualDeep(SchedulingParam{ .window = 128, .delayed_limit = 64, .split_enabled = 1, .split_size = 0x100000, .split_chunk_size = 0x10000 }, params);
    const before = params;
    try testing.expectEqual(KernelError.einval.raw(), setParam(&params, 129, 0, 0, 0, 0));
    try testing.expectEqualDeep(before, params);
    try testing.expectEqual(KernelError.efault.raw(), setParam(null, 0, 0, 0, 0, 0));
}
