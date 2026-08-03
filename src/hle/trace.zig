// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! A record of the firmware calls a title most recently made.
//!
//! When a title fails, the faulting address says where it died but not what led
//! there. The usual cause during bring-up is not a crash in our code at all: an
//! entry point returns a plausible-looking failure, the guest's own runtime
//! reacts to it, and the process dies somewhere else entirely. By then the call
//! that actually failed is several frames gone.
//!
//! Guest code calls firmware directly through relocated jump slots, so there is
//! no single point to instrument. Instead each entry point is wrapped at
//! declaration by a compile-time generated thunk with the same signature, which
//! records the call and forwards it.
//!
//! Only the most recent calls are kept, in a fixed ring. A title makes millions
//! of these; the last few dozen before a failure are what explain it, and a
//! bounded buffer costs a few stores rather than an ever-growing log.

const std = @import("std");
const abi = @import("abi.zig");
const host_stack = @import("host_stack.zig");

/// How many calls are retained. Two hundred and fifty six covers the run-up to
/// a failure comfortably while keeping the buffer small enough to stay resident.
pub const capacity: usize = 256;

/// Arguments captured per call.
///
/// The System V AMD64 convention passes the first six integer arguments in
/// registers and the rest on the stack. A handful of entry points take more
/// than six; those still record, but only the first six are kept, because the
/// leading arguments are what identify the object being operated on.
pub const maximum_arguments: usize = 6;

pub const Record = struct {
    /// Firmware export name. Static, so this is a borrow with no lifetime.
    name: []const u8 = &.{},
    arguments: [maximum_arguments]u64 = [_]u64{0} ** maximum_arguments,
    argument_count: u8 = 0,
    /// Return value widened to a word. Meaningless when `returns_value` is
    /// false.
    result: u64 = 0,
    returns_value: bool = false,
    /// Monotonic call number, so the ring can be read back in order and gaps
    /// from wrapping are visible.
    sequence: u64 = 0,
};

/// Recording is a diagnostic aid, so it is cheap rather than exact: slots are
/// claimed atomically but written without locking. A record can therefore be
/// torn if a reader races a concurrent guest call. That is an acceptable trade
/// for not serialising every firmware call behind a mutex, and the sequence
/// number makes a torn entry recognisable.
var ring: [capacity]Record = [_]Record{.{}} ** capacity;
var next_sequence: std.atomic.Value(u64) = .init(0);
var enabled = std.atomic.Value(bool).init(true);

pub fn setEnabled(value: bool) void {
    enabled.store(value, .release);
}

pub fn isEnabled() bool {
    return enabled.load(.acquire);
}

/// Forgets everything recorded so far.
pub fn reset() void {
    next_sequence.store(0, .release);
    for (&ring) |*slot| slot.* = .{};
}

/// How many calls have been recorded since the last reset.
pub fn count() u64 {
    return next_sequence.load(.acquire);
}

var live = std.atomic.Value(bool).init(false);

/// Also writes every call to standard error as it happens.
///
/// The ring is enough when a failure is contained, because the report prints it
/// afterwards. It is useless when the process dies outright — the buffer goes
/// with it — so this exists for the failures that leave nothing behind. It is
/// far too noisy to leave on.
pub fn setLive(value: bool) void {
    live.store(value, .release);
}

/// Whether calls are being announced as they happen.
///
/// Entry points that can say something the generic record cannot check this
/// before doing the extra work of saying it.
pub fn isLive() bool {
    return live.load(.acquire);
}

fn store(record: Record) void {
    if (!isEnabled()) return;
    const sequence = next_sequence.fetchAdd(1, .monotonic);
    var stored = record;
    stored.sequence = sequence;
    ring[sequence % capacity] = stored;

    if (live.load(.acquire)) emit(stored);
}

/// Writes one record immediately. Uses the debug printer because it locks and
/// needs no buffer, so it survives being called from any guest thread.
fn emit(record: Record) void {
    std.debug.print("[trace] {d} {s}(", .{ record.sequence, record.name });
    for (record.arguments[0..record.argument_count], 0..) |value, index| {
        if (index != 0) std.debug.print(", ", .{});
        std.debug.print("0x{x}", .{value});
    }
    std.debug.print(")", .{});
    if (record.returns_value) {
        std.debug.print(" = 0x{x}", .{record.result});
        if (looksLikeFailure(record.result)) std.debug.print("  <- failure", .{});
    }
    std.debug.print("\n", .{});
}

/// Widens any argument type to a word for recording.
///
/// Semantics are unavailable here — the recorder cannot know whether a value is
/// a handle, a pointer or a count — so everything becomes a word and reading it
/// is left to whoever knows the function.
fn word(value: anytype) u64 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int => |i| if (i.signedness == .signed)
            @bitCast(@as(i64, @intCast(value)))
        else
            @intCast(value),
        .bool => @intFromBool(value),
        .@"enum" => |e| if (@typeInfo(e.tag_type).int.signedness == .signed)
            @bitCast(@as(i64, @intCast(@intFromEnum(value))))
        else
            @intCast(@intFromEnum(value)),
        .pointer => |p| if (p.size == .slice) @intFromPtr(value.ptr) else @intFromPtr(value),
        .optional => if (value) |inner| word(inner) else 0,
        .float => @intCast(@as(u32, @bitCast(@as(f32, @floatCast(value))))),
        // Structs passed by value carry no useful single-word summary.
        else => 0,
    };
}

/// Builds a thunk with the same signature as `func` that records the call.
///
/// Generated per arity because a Zig function's parameter list has to be
/// written out; six is the System V register limit, so nothing is lost.
pub fn wrap(comptime name: []const u8, comptime func: anytype) abi.RawEntryPoint {
    const Fn = @typeInfo(@TypeOf(func)).pointer.child;
    const info = @typeInfo(Fn).@"fn";
    const Result = info.return_type.?;

    const P = struct {
        fn t(comptime index: usize) type {
            return info.params[index].type.?;
        }
    };

    const Thunk = switch (info.params.len) {
        0 => struct {
            fn call() callconv(abi.guest) Result {
                const args = [_]u64{};
                enter(name, &args);
                return finish(name, host_stack.call(Result, func, .{}), &args);
            }
        },
        1 => struct {
            fn call(a0: P.t(0)) callconv(abi.guest) Result {
                const args = [_]u64{word(a0)};
                enter(name, &args);
                return finish(name, host_stack.call(Result, func, .{ a0 }), &args);
            }
        },
        2 => struct {
            fn call(a0: P.t(0), a1: P.t(1)) callconv(abi.guest) Result {
                const args = [_]u64{ word(a0), word(a1) };
                enter(name, &args);
                return finish(name, host_stack.call(Result, func, .{ a0, a1 }), &args);
            }
        },
        3 => struct {
            fn call(a0: P.t(0), a1: P.t(1), a2: P.t(2)) callconv(abi.guest) Result {
                const args = [_]u64{ word(a0), word(a1), word(a2) };
                enter(name, &args);
                return finish(name, host_stack.call(Result, func, .{ a0, a1, a2 }), &args);
            }
        },
        4 => struct {
            fn call(a0: P.t(0), a1: P.t(1), a2: P.t(2), a3: P.t(3)) callconv(abi.guest) Result {
                const args = [_]u64{ word(a0), word(a1), word(a2), word(a3) };
                enter(name, &args);
                return finish(name, host_stack.call(Result, func, .{ a0, a1, a2, a3 }), &args);
            }
        },
        5 => struct {
            fn call(
                a0: P.t(0),
                a1: P.t(1),
                a2: P.t(2),
                a3: P.t(3),
                a4: P.t(4),
            ) callconv(abi.guest) Result {
                const args = [_]u64{ word(a0), word(a1), word(a2), word(a3), word(a4) };
                enter(name, &args);
                return finish(name, host_stack.call(Result, func, .{ a0, a1, a2, a3, a4 }), &args);
            }
        },
        6 => struct {
            fn call(
                a0: P.t(0),
                a1: P.t(1),
                a2: P.t(2),
                a3: P.t(3),
                a4: P.t(4),
                a5: P.t(5),
            ) callconv(abi.guest) Result {
                const args = [_]u64{ word(a0), word(a1), word(a2), word(a3), word(a4), word(a5) };
                enter(name, &args);
                return finish(
                    name,
                    host_stack.call(Result, func, .{ a0, a1, a2, a3, a4, a5 }),
                    &args,
                );
            }
        },
        7 => struct {
            fn call(
                a0: P.t(0),
                a1: P.t(1),
                a2: P.t(2),
                a3: P.t(3),
                a4: P.t(4),
                a5: P.t(5),
                a6: P.t(6),
            ) callconv(abi.guest) Result {
                // Beyond six the arguments arrive on the stack; only the
                // register ones are recorded, which is where the identifying
                // parameters live.
                const args = [_]u64{ word(a0), word(a1), word(a2), word(a3), word(a4), word(a5) };
                enter(name, &args);
                return finish(
                    name,
                    host_stack.call(Result, func, .{ a0, a1, a2, a3, a4, a5, a6 }),
                    &args,
                );
            }
        },
        8 => struct {
            fn call(
                a0: P.t(0),
                a1: P.t(1),
                a2: P.t(2),
                a3: P.t(3),
                a4: P.t(4),
                a5: P.t(5),
                a6: P.t(6),
                a7: P.t(7),
            ) callconv(abi.guest) Result {
                const args = [_]u64{ word(a0), word(a1), word(a2), word(a3), word(a4), word(a5) };
                enter(name, &args);
                return finish(
                    name,
                    host_stack.call(Result, func, .{ a0, a1, a2, a3, a4, a5, a6, a7 }),
                    &args,
                );
            }
        },
        9 => struct {
            fn call(
                a0: P.t(0),
                a1: P.t(1),
                a2: P.t(2),
                a3: P.t(3),
                a4: P.t(4),
                a5: P.t(5),
                a6: P.t(6),
                a7: P.t(7),
                a8: P.t(8),
            ) callconv(abi.guest) Result {
                const args = [_]u64{ word(a0), word(a1), word(a2), word(a3), word(a4), word(a5) };
                enter(name, &args);
                return finish(
                    name,
                    host_stack.call(Result, func, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8 }),
                    &args,
                );
            }
        },
        10 => struct {
            fn call(
                a0: P.t(0),
                a1: P.t(1),
                a2: P.t(2),
                a3: P.t(3),
                a4: P.t(4),
                a5: P.t(5),
                a6: P.t(6),
                a7: P.t(7),
                a8: P.t(8),
                a9: P.t(9),
            ) callconv(abi.guest) Result {
                const args = [_]u64{ word(a0), word(a1), word(a2), word(a3), word(a4), word(a5) };
                enter(name, &args);
                return finish(
                    name,
                    host_stack.call(Result, func, .{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 }),
                    &args,
                );
            }
        },
        else => @compileError(std.fmt.comptimePrint(
            "cannot trace {s}: {d} parameters exceeds the generated arities",
            .{ name, info.params.len },
        )),
    };

    return abi.erase(&Thunk.call);
}

/// How many words of guest stack a snapshot keeps.
///
/// Enough to reach past a handful of frames without reading far into memory the
/// guest has not written. What comes back is a scan, not a backtrace: guest code
/// omits frame pointers in places, so the useful entries have to be picked out
/// of it by whoever knows the modules.
pub const stack_capture_depth: usize = 512;

/// The longest entry-point name a capture can be armed for.
const capture_name_limit: usize = 64;

var capture_armed = std.atomic.Value(bool).init(false);
var capture_taken = std.atomic.Value(bool).init(false);
var capture_name_storage: [capture_name_limit]u8 = undefined;
var capture_name_length: usize = 0;
var capture_occurrence: u64 = 0;
var capture_seen = std.atomic.Value(u64).init(0);
var capture_stack: [stack_capture_depth]u64 = @splat(0);
var capture_length: usize = 0;
var capture_taken_at: u64 = 0;

/// The guest's page size, which is what bounds a snapshot.
const guest_page_size: usize = 16 * 1024;

pub const StackCapture = struct {
    /// The entry point that was being called.
    name: []const u8,
    /// Which call of that entry point this was, counting from one.
    occurrence: u64,
    words: []const u64,
};

/// Arms a one-shot snapshot of the guest stack at one call of one entry point.
///
/// The call trace says which firmware calls a title made; it does not say which
/// of the title's own code made them. When a title repeats a call thousands of
/// times, that is the only question worth answering, and the answer is on its
/// stack at the moment of the call.
///
/// Named by entry point and occurrence rather than by position in the trace,
/// because a title runs on several threads: the position a call ends up with is
/// decided when it finishes, by which time other threads have taken numbers of
/// their own, so a position chosen from one run does not name the same call in
/// the next. How many times a title has called one entry point is not subject to
/// that.
pub fn captureStackAt(name: []const u8, occurrence: u64) void {
    if (name.len == 0 or name.len > capture_name_limit or occurrence == 0) return;
    @memcpy(capture_name_storage[0..name.len], name);
    capture_name_length = name.len;
    capture_occurrence = occurrence;
    capture_seen.store(0, .release);
    capture_taken.store(false, .release);
    capture_length = 0;
    capture_armed.store(true, .release);
}

/// Forgets any armed or taken snapshot.
pub fn disarmCapture() void {
    capture_armed.store(false, .release);
    capture_taken.store(false, .release);
    capture_name_length = 0;
    capture_occurrence = 0;
    capture_seen.store(0, .release);
}

pub fn capturedStack() ?StackCapture {
    if (!capture_taken.load(.acquire)) return null;
    return .{
        .name = capture_name_storage[0..capture_name_length],
        .occurrence = capture_taken_at,
        .words = capture_stack[0..capture_length],
    };
}

/// Copies words off the guest's own stack.
///
/// Taken here rather than inside the entry point because firmware runs on a host
/// stack of its own: by the time the entry point body executes, the guest stack
/// is no longer the one underfoot. This runs before that switch.
///
/// Reading upward from the current frame reaches the caller's frames, which the
/// guest has already written and which lie inside its mapped stack, so the read
/// stays within memory that exists.
fn takeStackSnapshot(comptime name: []const u8) void {
    if (!std.mem.eql(u8, name, capture_name_storage[0..capture_name_length])) return;
    const seen = capture_seen.fetchAdd(1, .monotonic) + 1;
    if (seen != capture_occurrence) return;
    if (capture_taken.swap(true, .acq_rel)) return;

    // Anchored on a local rather than on the frame address, because the frame
    // pointer is omitted in optimized builds and what it reports then is not the
    // stack at all. The address of something living on the stack is.
    var anchor: u64 = 0;
    const base = std.mem.alignForward(usize, @intFromPtr(&anchor), @alignOf(u64));

    // Stop at the end of the page the frame sits in. Higher addresses are the
    // caller's frames, but only up to where the stack ends -- and a call made
    // from a shallow frame sits close to that end. Reading past it faults, and
    // faulting inside a diagnostic kills the process it was meant to explain.
    // The frame's own page is mapped because the frame is in it, so this bound
    // needs nothing else to be known.
    const page_end = std.mem.alignForward(usize, base + 1, guest_page_size);
    const available = (page_end - base) / @sizeOf(u64);
    const readable = @min(available, stack_capture_depth);

    const words: [*]const u64 = @ptrFromInt(base);
    for (capture_stack[0..readable], 0..) |*slot, index| slot.* = words[index];
    capture_length = readable;
    capture_taken_at = seen;
}

/// Announces a call before it runs, and takes a stack snapshot if one is armed.
///
/// The ring records completed calls only, which is the right default but hides
/// the one case that matters most: a call that never returns because it faulted
/// inside. Live mode therefore prints on entry as well.
///
/// This runs on the guest's own stack, before firmware moves to a stack of its
/// own, which is what makes a snapshot of the caller possible at all.
fn enter(comptime name: []const u8, arguments: []const u64) void {
    if (capture_armed.load(.acquire)) takeStackSnapshot(name);
    if (!live.load(.acquire) or !isEnabled()) return;
    std.debug.print("[call ] {s}(", .{name});
    for (arguments, 0..) |value, index| {
        if (index != 0) std.debug.print(", ", .{});
        std.debug.print("0x{x}", .{value});
    }
    std.debug.print(")\n", .{});
}

/// Records a completed call and passes its result through.
///
/// The result is evaluated by the caller before this runs, so a function that
/// never returns is never recorded — which is correct: it did not complete.
fn finish(comptime name: []const u8, result: anytype, arguments: []const u64) @TypeOf(result) {
    const Result = @TypeOf(result);
    var record = Record{ .name = name, .argument_count = @intCast(arguments.len) };
    for (arguments, 0..) |value, index| record.arguments[index] = value;
    if (Result != void) {
        record.result = word(result);
        record.returns_value = true;
    }
    store(record);
    return result;
}

/// Reads back the retained calls, oldest first.
///
/// `buffer` receives the records; the returned slice is the portion filled.
pub fn recent(buffer: []Record) []const Record {
    const total = next_sequence.load(.acquire);
    if (total == 0) return buffer[0..0];

    const available: u64 = @min(total, capacity);
    const wanted: u64 = @min(available, buffer.len);
    const first = total - wanted;

    for (0..wanted) |offset| {
        buffer[offset] = ring[(first + offset) % capacity];
    }
    return buffer[0..@intCast(wanted)];
}

/// Writes the retained calls, oldest first.
///
/// Calls whose result looks like a firmware failure are marked, because that is
/// almost always the interesting line: the guest's own runtime reacts to a
/// failed call long before anything crashes.
pub fn write(w: *std.Io.Writer, limit: usize) std.Io.Writer.Error!void {
    var buffer: [capacity]Record = undefined;
    const wanted = @min(limit, capacity);
    const records = recent(buffer[0..wanted]);

    if (records.len == 0) {
        try w.writeAll("  no firmware calls recorded\n");
        return;
    }

    try w.print("  last {d} firmware calls (of {d})\n", .{ records.len, count() });
    for (records) |record| {
        try w.print("    {d:>6} {s}(", .{ record.sequence, record.name });
        for (record.arguments[0..record.argument_count], 0..) |value, index| {
            if (index != 0) try w.writeAll(", ");
            try w.print("0x{x}", .{value});
        }
        try w.writeAll(")");
        if (record.returns_value) {
            try w.print(" = 0x{x}", .{record.result});
            if (looksLikeFailure(record.result)) try w.writeAll("  <- failure");
        }
        try w.writeAll("\n");
    }
}

/// Whether a return value looks like a firmware error.
///
/// Two conventions coexist. Kernel entry points report failure as
/// `0x8002_00xx`, and POSIX-style entry points return `-1` with the reason
/// left in a thread-local. Both are worth marking, because the call that fails
/// is rarely the one that crashes.
///
/// A zero return is deliberately not treated as failure: far too many entry
/// points return zero for success. Small positive values are left alone too,
/// since they are indistinguishable from counts and handles.
fn looksLikeFailure(result: u64) bool {
    if (result == std.math.maxInt(u64) or result == std.math.maxInt(u32)) return true;

    const high = result >> 32;
    if (high != 0 and high != 0xffff_ffff) return false;
    const narrowed: u32 = @truncate(result);
    return narrowed >= 0x8000_0000 and narrowed <= 0x8fff_ffff;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn addTwo(a: u64, b: u64) callconv(abi.guest) u64 {
    return a + b;
}

fn failing() callconv(abi.guest) i32 {
    return @bitCast(@as(u32, 0x8002_0016));
}

fn takesNothingReturnsNothing() callconv(abi.guest) void {}

test "a wrapped call is recorded with its arguments and result" {
    reset();
    setEnabled(true);

    const traced = wrap("addTwo", &addTwo);
    const typed: *const fn (u64, u64) callconv(abi.guest) u64 = @ptrCast(traced);
    try testing.expectEqual(@as(u64, 7), typed(3, 4));

    var buffer: [4]Record = undefined;
    const records = recent(&buffer);
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expectEqualStrings("addTwo", records[0].name);
    try testing.expectEqual(@as(u8, 2), records[0].argument_count);
    try testing.expectEqual(@as(u64, 3), records[0].arguments[0]);
    try testing.expectEqual(@as(u64, 4), records[0].arguments[1]);
    try testing.expectEqual(@as(u64, 7), records[0].result);
    try testing.expect(records[0].returns_value);
}

fn takesFour(a: u64, b: u64, c: u64, d: u64) callconv(abi.guest) u64 {
    return a + b + c + d;
}

test "every arity announces its entry, not just the short ones" {
    // Entry announcement used to stop at three arguments, so a title's calls to
    // anything wider were invisible until they returned -- and a call that
    // faults inside never returns. The memory entry points a title leans on
    // hardest are four wide.
    reset();
    setEnabled(true);
    captureStackAt("takesFour", 1);
    defer disarmCapture();

    const traced = wrap("takesFour", &takesFour);
    const typed: *const fn (u64, u64, u64, u64) callconv(abi.guest) u64 = @ptrCast(traced);
    try testing.expectEqual(@as(u64, 10), typed(1, 2, 3, 4));

    // The snapshot is proof the entry hook ran: it can only be taken there.
    const capture = capturedStack() orelse return error.EntryHookDidNotRun;
    try testing.expectEqualStrings("takesFour", capture.name);
    try testing.expectEqual(@as(u64, 1), capture.occurrence);
    try testing.expect(capture.words.len > 0);
}

test "a snapshot stops at the end of the page it started in" {
    // Higher addresses are the caller's frames, but only as far as the stack
    // goes, and a call made from a shallow frame sits close to that end.
    // Reading past it faults -- and a diagnostic that kills the process it was
    // meant to explain is worse than no diagnostic.
    reset();
    setEnabled(true);
    captureStackAt("takesFour", 1);
    defer disarmCapture();

    const traced = wrap("takesFour", &takesFour);
    const typed: *const fn (u64, u64, u64, u64) callconv(abi.guest) u64 = @ptrCast(traced);
    _ = typed(1, 2, 3, 4);

    const capture = capturedStack() orelse return error.EntryHookDidNotRun;
    try testing.expect(capture.words.len <= stack_capture_depth);
    // Whatever the frame's position, the words read never cross out of its page.
    try testing.expect(capture.words.len <= guest_page_size / @sizeOf(u64));
}

test "a snapshot is taken at the requested call and only once" {
    reset();
    setEnabled(true);
    captureStackAt("takesFour", 3);
    defer disarmCapture();

    const traced = wrap("takesFour", &takesFour);
    const typed: *const fn (u64, u64, u64, u64) callconv(abi.guest) u64 = @ptrCast(traced);

    _ = typed(1, 1, 1, 1);
    try testing.expect(capturedStack() == null);
    _ = typed(2, 2, 2, 2);
    try testing.expect(capturedStack() == null);
    _ = typed(3, 3, 3, 3);
    try testing.expectEqual(@as(u64, 3), capturedStack().?.occurrence);

    // Later calls leave the snapshot alone: it names one call, not the newest.
    _ = typed(4, 4, 4, 4);
    try testing.expectEqual(@as(u64, 3), capturedStack().?.occurrence);
}

test "a snapshot request that names nothing is refused" {
    reset();
    disarmCapture();
    captureStackAt("", 1);
    captureStackAt("takesFour", 0);
    const traced = wrap("takesFour", &takesFour);
    const typed: *const fn (u64, u64, u64, u64) callconv(abi.guest) u64 = @ptrCast(traced);
    _ = typed(1, 1, 1, 1);
    try testing.expect(capturedStack() == null);
}

test "a call returning nothing is recorded without a result" {
    reset();

    const traced = wrap("nothing", &takesNothingReturnsNothing);
    const typed: *const fn () callconv(abi.guest) void = @ptrCast(traced);
    typed();

    var buffer: [4]Record = undefined;
    const records = recent(&buffer);
    try testing.expectEqual(@as(usize, 1), records.len);
    try testing.expect(!records[0].returns_value);
    try testing.expectEqual(@as(u8, 0), records[0].argument_count);
}

test "kernel error codes are marked as failures" {
    // The scheme firmware uses: 0x8002_00xx, negative when read as a word.
    try testing.expect(looksLikeFailure(0xffff_ffff_8002_0016));
    try testing.expect(looksLikeFailure(0x8002_0016));
    // POSIX-style entry points return -1, in either width.
    try testing.expect(looksLikeFailure(0xffff_ffff_ffff_ffff));
    try testing.expect(looksLikeFailure(0xffff_ffff));
    // Success and ordinary values are not.
    try testing.expect(!looksLikeFailure(0));
    try testing.expect(!looksLikeFailure(1));
    // A pointer-looking value must not be mistaken for an error.
    try testing.expect(!looksLikeFailure(0x0000_0070_0012_7ed8));
    // Nor a plausible handle in the guest's high window.
    try testing.expect(!looksLikeFailure(0x0000_0801_8942_d0));
}

test "a failing call is recorded and flagged" {
    reset();

    const traced = wrap("failing", &failing);
    const typed: *const fn () callconv(abi.guest) i32 = @ptrCast(traced);
    _ = typed();

    var buffer: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(&w, 8);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "failing()") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<- failure") != null);
}

test "the ring keeps the most recent calls and reports the total" {
    reset();

    const traced = wrap("addTwo", &addTwo);
    const typed: *const fn (u64, u64) callconv(abi.guest) u64 = @ptrCast(traced);

    const total = capacity + 10;
    for (0..total) |index| _ = typed(index, 0);

    try testing.expectEqual(@as(u64, total), count());

    var buffer: [capacity]Record = undefined;
    const records = recent(&buffer);
    // Only the ring's worth survives.
    try testing.expectEqual(capacity, records.len);
    // Oldest first, and the oldest surviving call is the one that displaced the
    // start of the ring.
    try testing.expectEqual(@as(u64, total - capacity), records[0].sequence);
    try testing.expectEqual(@as(u64, total - 1), records[records.len - 1].sequence);
}

test "recording can be switched off" {
    reset();
    setEnabled(false);
    defer setEnabled(true);

    const traced = wrap("addTwo", &addTwo);
    const typed: *const fn (u64, u64) callconv(abi.guest) u64 = @ptrCast(traced);
    // The call still works; only the recording is skipped.
    try testing.expectEqual(@as(u64, 5), typed(2, 3));
    try testing.expectEqual(@as(u64, 0), count());
}

test "an empty trace says so rather than printing nothing" {
    reset();
    setEnabled(true);

    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(&w, 8);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "no firmware calls recorded") != null);
}