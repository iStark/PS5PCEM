// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Readable reports for contained guest faults.
//!
//! The native bridge captures a fault as raw numbers. That is the right thing
//! to store and the wrong thing to read: an address alone cannot say which
//! module failed, and the most common failure while bringing a title up — a
//! call through a function pointer that was never filled in — looks identical
//! to every other access violation.
//!
//! This turns that record into an explanation. The important case is a jump to
//! a null pointer: the faulting address is useless because it belongs to no
//! module, but the return address the `call` just pushed identifies the caller
//! exactly. Recovering it is the difference between "crashed at 0" and "libc
//! called through a null callback from this offset".

const std = @import("std");
const memory = @import("memory");
const cpu = @import("cpu");
const symbolize = @import("symbolize.zig");

const SymbolMap = symbolize.SymbolMap;

/// Addresses below one page are treated as a null pointer rather than a real
/// target. A null vtable slot or a null callback with a small field offset
/// lands here, and no title maps the first page.
const null_pointer_limit: u64 = memory.page_size;

/// What the fault appears to be, beyond the raw exception code.
pub const Diagnosis = enum {
    /// Control was transferred to a null pointer. The caller is recoverable
    /// from the stack.
    null_call,
    /// A read or write through a null pointer.
    null_access,
    /// An access to an address no module or mapping owns.
    unmapped_access,
    /// A legitimate address the guest lacked permission for.
    protection,
    illegal_instruction,
    unknown,
};

pub const Report = struct {
    info: cpu.FaultInfo,
    diagnosis: Diagnosis,
    /// Caller recovered from the stack, present only for `null_call`.
    return_address: ?u64 = null,
};

/// Reads eight bytes of guest memory, or null if that address is not mapped.
///
/// The guest address space is identity mapped, so this is a host load — but it
/// has to be guarded, because reading unmapped memory while reporting a fault
/// would fault again and lose the original report.
fn readGuestWord(address_space: *memory.AddressSpace, address: u64) ?u64 {
    if (address == 0 or !address_space.isMapped(address, @sizeOf(u64))) return null;
    const bytes: [*]const u8 = @ptrFromInt(address);
    return std.mem.readInt(u64, bytes[0..8], .little);
}

fn classify(info: cpu.FaultInfo) Diagnosis {
    if (info.kind == .illegal_instruction) return .illegal_instruction;
    if (info.kind != .access_violation) return .unknown;

    // An execute fault at a null address means control reached there, which
    // only happens through a call or jump.
    if (info.instruction_address < null_pointer_limit) return .null_call;
    if (info.access == .execute and info.memory_address < null_pointer_limit) return .null_call;
    if (info.memory_address < null_pointer_limit) return .null_access;
    return .unknown;
}

/// Builds a report from a captured fault.
///
/// `address_space` is optional: without it the caller of a null call cannot be
/// recovered, but everything else still resolves.
pub fn analyze(info: cpu.FaultInfo, address_space: ?*memory.AddressSpace) Report {
    var report = Report{ .info = info, .diagnosis = classify(info) };

    if (report.diagnosis == .null_call) {
        // `call` pushes the return address before transferring control, so the
        // top of the stack is the instruction after the call that failed.
        if (address_space) |space| {
            report.return_address = readGuestWord(space, info.registers.rsp);
        }
    }

    if (report.diagnosis == .unknown and address_space != null) {
        const space = address_space.?;
        report.diagnosis = if (space.isMapped(info.memory_address, 1))
            .protection
        else
            .unmapped_access;
    }

    return report;
}

/// How far up the stack to look for return addresses.
///
/// Guest code is compiled with frame pointers omitted in places, so a reliable
/// unwind is not available. Scanning a bounded window and keeping the words
/// that land inside a loaded module recovers the call chain in practice, at the
/// cost of occasional stale entries — which is why the output is labelled a
/// scan rather than a backtrace.
const stack_scan_words: usize = 48;

/// Writes stack words that point into loaded code.
pub fn writeStackTrace(
    report: Report,
    map: *const SymbolMap,
    address_space: *memory.AddressSpace,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var rsp = report.info.registers.rsp;
    if (rsp == 0) return;

    var printed: usize = 0;
    for (0..stack_scan_words) |_| {
        const word = readGuestWord(address_space, rsp) orelse break;
        rsp += @sizeOf(u64);

        // A return address points after its call instruction; stepping back
        // keeps the lookup on the calling instruction.
        const location = map.locate(word -| 1);
        if (!location.isKnown()) continue;

        if (printed == 0) try w.writeAll("  stack scan\n");
        try w.writeAll("    ");
        try map.write(word -| 1, w);
        try w.writeAll("\n");

        printed += 1;
        if (printed >= 8) break;
    }
}

fn describe(diagnosis: Diagnosis) []const u8 {
    return switch (diagnosis) {
        .null_call => "call through a null pointer",
        .null_access => "access through a null pointer",
        .unmapped_access => "access to unmapped memory",
        .protection => "access violated page protection",
        .illegal_instruction => "illegal instruction",
        .unknown => "unclassified fault",
    };
}

/// Writes a human-readable report.
pub fn write(
    report: Report,
    map: *const SymbolMap,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const info = report.info;

    try w.print("guest fault: {s}\n", .{describe(report.diagnosis)});
    try w.print("  kind        {s}", .{@tagName(info.kind)});
    if (info.access != .unknown) try w.print(" ({s})", .{@tagName(info.access)});
    try w.print("  code 0x{x:0>8}\n", .{info.exception_code});

    try w.writeAll("  rip         ");
    try map.write(info.instruction_address, w);
    try w.writeAll("\n");

    try w.writeAll("  target      ");
    try map.write(info.memory_address, w);
    try w.writeAll("\n");

    if (report.return_address) |caller| {
        // For a null call this is the whole answer: the address that follows
        // the call instruction, and therefore the code that made it.
        try w.writeAll("  called from ");
        // The return address points after the call; step back into it so the
        // symbol lookup lands on the calling instruction, not the next one.
        try map.write(caller -| 1, w);
        try w.writeAll("\n");
    } else if (report.diagnosis == .null_call) {
        try w.writeAll("  called from <stack unreadable>\n");
    }

    const r = info.registers;
    try w.print("  rsp 0x{x:0>16}  rbp 0x{x:0>16}\n", .{ r.rsp, r.rbp });
    try w.print("  rax 0x{x:0>16}  rbx 0x{x:0>16}  rcx 0x{x:0>16}\n", .{ r.rax, r.rbx, r.rcx });
    try w.print("  rdx 0x{x:0>16}  rsi 0x{x:0>16}  rdi 0x{x:0>16}\n", .{ r.rdx, r.rsi, r.rdi });
    try w.print("  r8  0x{x:0>16}  r9  0x{x:0>16}  r10 0x{x:0>16}\n", .{ r.r8, r.r9, r.r10 });
    try w.print("  r11 0x{x:0>16}  r12 0x{x:0>16}  r13 0x{x:0>16}\n", .{ r.r11, r.r12, r.r13 });
    try w.print("  r14 0x{x:0>16}  r15 0x{x:0>16}  rflags 0x{x:0>8}\n", .{ r.r14, r.r15, r.rflags });
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn accessViolation(rip: u64, target: u64, access: cpu.FaultAccess) cpu.FaultInfo {
    return .{
        .kind = .access_violation,
        .access = access,
        .exception_code = 0xc0000005,
        .instruction_address = rip,
        .memory_address = target,
        .registers = .{ .rip = rip },
    };
}

test "a jump to null is diagnosed as a null call" {
    const info = accessViolation(0, 0, .execute);
    const report = analyze(info, null);
    try testing.expectEqual(Diagnosis.null_call, report.diagnosis);
}

test "a small non-zero target is still a null pointer" {
    // A null vtable slot or a null callback reached through a field offset.
    const info = accessViolation(0x10, 0x10, .execute);
    try testing.expectEqual(Diagnosis.null_call, analyze(info, null).diagnosis);
}

test "a null dereference is distinguished from a null call" {
    const info = accessViolation(0x40070, 0x8, .write);
    try testing.expectEqual(Diagnosis.null_access, analyze(info, null).diagnosis);
}

test "an illegal instruction is reported as itself" {
    var info = accessViolation(0x40070, 0, .unknown);
    info.kind = .illegal_instruction;
    try testing.expectEqual(Diagnosis.illegal_instruction, analyze(info, null).diagnosis);
}

test "without an address space a null call has no caller" {
    const report = analyze(accessViolation(0, 0, .execute), null);
    try testing.expectEqual(Diagnosis.null_call, report.diagnosis);
    try testing.expect(report.return_address == null);
}

test "the report names the module and anchors the address" {
    var map = SymbolMap{};
    defer map.deinit(testing.allocator);

    try map.addModule(
        testing.allocator,
        "libc.prx",
        0x100000,
        &.{.{ .start = 0x100000, .end = 0x200000 }},
        &.{.{
            .id = "aaaaaaaaaa1",
            .library = "libc",
            .library_version = 1,
            .module = "libc",
            .symbol_type = .func,
            .address = 0x110000,
        }},
    );

    const report = analyze(accessViolation(0x110040, 0x110040, .execute), null);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(report, &map, &w);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "libc.prx+0x10040") != null);
    try testing.expect(std.mem.indexOf(u8, text, "aaaaaaaaaa1+0x40") != null);
}

test "a null call reports the caller recovered from the stack" {
    var space = try memory.AddressSpace.init(testing.allocator);
    defer space.deinit();

    // A stack page holding the pushed return address.
    const stack = memory.system_managed.start;
    try space.mapFixed(stack, memory.page_size, memory.Protection.read_write, .stack, null);

    const caller: u64 = 0x110044;
    const rsp = stack + 0x100;
    const slot: *u64 = @ptrFromInt(rsp);
    slot.* = caller;

    var info = accessViolation(0, 0, .execute);
    info.registers.rsp = rsp;

    const report = analyze(info, &space);
    try testing.expectEqual(Diagnosis.null_call, report.diagnosis);
    try testing.expectEqual(caller, report.return_address.?);

    var map = SymbolMap{};
    defer map.deinit(testing.allocator);
    try map.addModule(
        testing.allocator,
        "libc.prx",
        0x100000,
        &.{.{ .start = 0x100000, .end = 0x200000 }},
        &.{.{
            .id = "aaaaaaaaaa1",
            .library = "libc",
            .library_version = 1,
            .module = "libc",
            .symbol_type = .func,
            .address = 0x110000,
        }},
    );

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(report, &map, &w);
    const text = w.buffered();

    // This line is the point of the whole module.
    try testing.expect(std.mem.indexOf(u8, text, "called from") != null);
    try testing.expect(std.mem.indexOf(u8, text, "aaaaaaaaaa1+0x43") != null);
}

test "an unreadable stack is reported rather than guessed" {
    var space = try memory.AddressSpace.init(testing.allocator);
    defer space.deinit();

    var info = accessViolation(0, 0, .execute);
    info.registers.rsp = memory.system_managed.start + 0x1000; // never mapped

    const report = analyze(info, &space);
    try testing.expectEqual(Diagnosis.null_call, report.diagnosis);
    try testing.expect(report.return_address == null);

    var map = SymbolMap{};
    defer map.deinit(testing.allocator);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(report, &map, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "<stack unreadable>") != null);
}
