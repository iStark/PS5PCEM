// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! What a title can ask about the machine it is running on.
//!
//! These are the questions a runtime asks once during startup — which console
//! model, which firmware, which CPU, how fast the timestamp counter ticks — and
//! then branches on for the rest of its life. None of them do any work; what
//! matters is that the answers are consistent and plausible.
//!
//! Two rules shape the implementations. Where a real answer exists, it is
//! measured rather than invented: the timestamp counter is the host's, and its
//! frequency is calibrated against the same clock every other firmware library
//! uses, so a title dividing one by the other gets real elapsed time.
//!
//! Where no real answer exists, the entry point is declared to take no
//! arguments even when the guest passes some. Ignoring argument registers is
//! always safe; writing through a pointer whose layout is a guess is not, and
//! several of these have an output parameter whose shape is not established.
//! An entry point that cannot fill its output reports failure rather than
//! leaving the guest to read whatever was on its stack.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const runtime_api = @import("kernel_runtime.zig");

const KernelError = errno.KernelError;

/// Reported as the process identifier.
///
/// A title runs alone, so the value only has to be stable and non-zero: it is
/// used to name things and to compare against itself.
pub const process_id: i32 = 1;

/// Reported as the user identifier. Titles run unprivileged.
pub const user_id: i32 = 1;

/// Reported for the main system-on-chip revision.
///
/// A title reads this to pick between hardware workarounds. Zero means the
/// baseline part, which is the model a title is always prepared for.
pub const main_soc_id: u32 = 0;

/// Reported as the SDK the title was built against, and as the firmware it is
/// running on, in the packed `0xMMmmpppp` form these values use.
///
/// A title compares these to decide which behaviours are available. The value
/// is deliberately recent enough that nothing is gated off, and deliberately a
/// constant: the real one lives in the title's process parameters, whose layout
/// is not established here, and reading it wrongly would be worse than
/// answering consistently.
pub const sdk_version: u32 = 0x0500_0000;

/// Frequency reported when the host counter cannot be calibrated.
const fallback_tsc_frequency: u64 = 1_000_000_000;

/// How long to observe the counter when calibrating. Long enough that clock
/// granularity does not dominate, short enough to be unnoticeable at startup.
const calibration_nanoseconds: i96 = 1_000_000;

var tsc_frequency: std.atomic.Value(u64) = .init(0);

/// Reads the host timestamp counter.
///
/// The counter itself is reported rather than a synthesised one, so that a
/// title measuring an interval sees genuinely elapsed time once it divides by
/// the frequency below.
pub fn readTsc() u64 {
    if (builtin.cpu.arch != .x86_64) {
        const io = runtime_api.activeIo() orelse return 0;
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        return @intCast(@max(now, 0));
    }
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

/// Measures how fast the timestamp counter ticks, once.
///
/// Calibrating against the clock the rest of the firmware uses keeps the two
/// consistent: a title that mixes counter deltas with clock readings gets
/// answers that agree. The measurement is a busy wait rather than a sleep,
/// because it runs once and a sleep would need a scheduler this layer does not
/// have.
pub fn tscFrequency() u64 {
    const cached = tsc_frequency.load(.acquire);
    if (cached != 0) return cached;

    const measured = measureTscFrequency() orelse fallback_tsc_frequency;
    tsc_frequency.store(measured, .release);
    return measured;
}

fn measureTscFrequency() ?u64 {
    if (builtin.cpu.arch != .x86_64) return null;
    const io = runtime_api.activeIo() orelse return null;

    const start_ticks = readTsc();
    const start_time = std.Io.Clock.awake.now(io).nanoseconds;

    var elapsed: i96 = 0;
    while (elapsed < calibration_nanoseconds) {
        elapsed = std.Io.Clock.awake.now(io).nanoseconds - start_time;
    }

    const end_ticks = readTsc();
    if (end_ticks <= start_ticks or elapsed <= 0) return null;

    const ticks: u128 = end_ticks - start_ticks;
    const nanoseconds: u128 = @intCast(elapsed);
    const frequency = (ticks * 1_000_000_000) / nanoseconds;
    if (frequency == 0) return null;
    return @intCast(@min(frequency, std.math.maxInt(u64)));
}

// ---------------------------------------------------------------------------
// Guest entry points
// ---------------------------------------------------------------------------

/// Whether the console is the enhanced model of its generation.
///
/// Reported as the base model. A title uses this to enable optional extra
/// fidelity, and claiming hardware we do not emulate would only invite work
/// that cannot be honoured.
fn isNeoMode() callconv(abi.guest) i32 {
    return 0;
}

fn getMainSocId() callconv(abi.guest) u32 {
    return main_soc_id;
}

/// Which CPU the calling thread is running on.
///
/// Always the first. Titles use this to index per-processor caches, where a
/// constant answer costs contention but never correctness.
fn getCurrentCpu() callconv(abi.guest) i32 {
    return 0;
}

fn getCompiledSdkVersion() callconv(abi.guest) u32 {
    return sdk_version;
}

fn getSystemSwVersion() callconv(abi.guest) u32 {
    return sdk_version;
}

fn getPid() callconv(abi.guest) i32 {
    return process_id;
}

fn getUid() callconv(abi.guest) i32 {
    return user_id;
}

/// Whether the system is applying a compatibility workaround for this title.
///
/// None are, and a title told otherwise would take a path written for hardware
/// behaviour we do not reproduce.
fn titleWorkaroundIsEnabled() callconv(abi.guest) i32 {
    return 0;
}

/// A per-installation value a title mixes into its private paths.
///
/// Constant, because it has to survive across runs: a title that derived a
/// directory name from it once must find the same name next time.
fn getFsSandboxRandomWord() callconv(abi.guest) u64 {
    return 0;
}

/// Records a property the process wants remembered.
///
/// Accepted and discarded. Nothing reads these back yet, and refusing would
/// stop a startup path over bookkeeping the title never checks.
fn setProcessProperty() callconv(abi.guest) i32 {
    return errno.ok;
}

/// The last error the kernel recorded for this thread.
///
/// Reported as no error. Every entry point that fails already reports the
/// reason through its own return, so this is a second channel nothing writes.
fn kernelError() callconv(abi.guest) i32 {
    return errno.ok;
}

/// Describes the running application.
///
/// Refused rather than filled: the record's layout is not established, and
/// writing a guessed one into the title's buffer would corrupt whatever it
/// keeps after the record.
fn getAppInfo() callconv(abi.guest) i32 {
    return KernelError.enosys.raw();
}

/// Which category the application belongs to.
///
/// The ordinary game category. Titles branch on this to disable features that
/// only apply to system applications.
fn getAppCategoryType() callconv(abi.guest) i32 {
    return 0;
}

fn kernelReadTsc() callconv(abi.guest) u64 {
    return readTsc();
}

fn kernelGetTscFrequency() callconv(abi.guest) u64 {
    return tscFrequency();
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceKernelIsNeoMode", .function = trace.wrap("sceKernelIsNeoMode", &isNeoMode), .expect_id = "WslcK1FQcGI" },
    .{ .name = "sceKernelGetMainSocId", .function = trace.wrap("sceKernelGetMainSocId", &getMainSocId), .expect_id = "0vTn5IDMU9A" },
    .{ .name = "sceKernelGetCurrentCpu", .function = trace.wrap("sceKernelGetCurrentCpu", &getCurrentCpu), .expect_id = "g0VTBxfJyu0" },
    .{ .name = "sceKernelGetCompiledSdkVersion", .function = trace.wrap("sceKernelGetCompiledSdkVersion", &getCompiledSdkVersion), .expect_id = "WB66evu8bsU" },
    .{ .name = "sceKernelGetProsperoCompiledSdkVersion", .function = trace.wrap("sceKernelGetProsperoCompiledSdkVersion", &getCompiledSdkVersion), .expect_id = "GGeRJk1XdWc" },
    .{ .name = "sceKernelGetProsperoSystemSwVersion", .function = trace.wrap("sceKernelGetProsperoSystemSwVersion", &getSystemSwVersion), .expect_id = "aML18Z0J0t0" },
    .{ .name = "sceKernelTitleWorkaroundIsEnabled", .function = trace.wrap("sceKernelTitleWorkaroundIsEnabled", &titleWorkaroundIsEnabled), .expect_id = "1yca4VvfcNA" },
    .{ .name = "sceKernelGetFsSandboxRandomWord", .function = trace.wrap("sceKernelGetFsSandboxRandomWord", &getFsSandboxRandomWord), .expect_id = "JGfTMBOdUJo" },
    .{ .name = "sceKernelSetProcessProperty", .function = trace.wrap("sceKernelSetProcessProperty", &setProcessProperty), .expect_id = "-W4xI5aVI8w" },
    .{ .name = "sceKernelError", .function = trace.wrap("sceKernelError", &kernelError), .expect_id = "D4yla3vx4tY" },
    .{ .name = "sceKernelGetAppInfo", .function = trace.wrap("sceKernelGetAppInfo", &getAppInfo), .expect_id = "G-MYv5erXaU" },
    .{ .name = "sceKernelGetAppCategoryType", .function = trace.wrap("sceKernelGetAppCategoryType", &getAppCategoryType), .expect_id = "+xy9ORMbd8U" },
    .{ .name = "sceKernelReadTsc", .function = trace.wrap("sceKernelReadTsc", &kernelReadTsc), .expect_id = "-2IRUCO--PM" },
    .{ .name = "sceKernelGetTscFrequency", .function = trace.wrap("sceKernelGetTscFrequency", &kernelGetTscFrequency), .expect_id = "1j3S3n-tTW4" },
    .{ .name = "getpid", .function = trace.wrap("getpid", &getPid), .expect_id = "HoLVWNanBBc" },
    .{ .name = "getuid", .function = trace.wrap("getuid", &getUid), .expect_id = "kg4x8Prhfxw" },
};

pub const library = symbols.Library{ .name = "libkernel", .version = 1 };
pub const module = symbols.Module{ .name = "libkernel", .version_major = 1, .version_minor = 1 };

pub fn register(db: *symbols.Database, gpa: std.mem.Allocator) symbols.Error!void {
    try db.addLibrary(gpa, library, module, &exports);
}

/// Forgets the calibrated frequency, so a later measurement starts clean.
pub fn reset() void {
    tsc_frequency.store(0, .release);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "machine facts are reported consistently" {
    // These are read once and branched on forever, so the values matter less
    // than their stability.
    try testing.expectEqual(@as(i32, 0), isNeoMode());
    try testing.expectEqual(@as(i32, 0), getCurrentCpu());
    try testing.expectEqual(@as(i32, 0), titleWorkaroundIsEnabled());
    try testing.expectEqual(process_id, getPid());
    try testing.expectEqual(user_id, getUid());
    try testing.expect(getPid() != 0);
}

test "a record whose layout is unknown is refused rather than guessed" {
    // Filling a guessed layout would corrupt whatever the title keeps after it.
    try testing.expectEqual(KernelError.enosys.raw(), getAppInfo());
}

test "the timestamp counter advances" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    const first = readTsc();
    var second = readTsc();
    // The counter is free-running, so a second read cannot precede the first.
    var attempts: usize = 0;
    while (second == first and attempts < 1000) : (attempts += 1) second = readTsc();
    try testing.expect(second >= first);
}

test "the frequency is measured once and then reused" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    reset();
    runtime_api.attachIo(testing.io);
    defer runtime_api.attachIo(null);

    const first = tscFrequency();
    // A modern part ticks somewhere between a hundred megahertz and a hundred
    // gigahertz; anything outside that is a broken measurement, not a fast one.
    try testing.expect(first > 100_000_000);
    try testing.expect(first < 100_000_000_000);

    // The second call must not measure again.
    try testing.expectEqual(first, tscFrequency());
    reset();
}

test "without a clock the frequency falls back rather than reporting zero" {
    reset();
    runtime_api.attachIo(null);
    // Dividing by zero is worse than dividing by a plausible constant.
    try testing.expectEqual(fallback_tsc_frequency, tscFrequency());
    reset();
}

test "machine-info exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try register(&db, testing.allocator);
    try testing.expectEqual(exports.len, db.count());
    try testing.expect(db.findByName("sceKernelIsNeoMode", .function) != null);
    try testing.expect(db.findByName("sceKernelReadTsc", .function) != null);
}
