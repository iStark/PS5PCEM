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

/// What the host puts in the faulting-address field when there is no address.
const no_faulting_address: u64 = std.math.maxInt(u64);

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
    /// The guest ran an instruction the processor would not let it run — a
    /// software interrupt, most often, which is how a title's own assertions
    /// stop it. Not a memory failure at all, despite how it arrives.
    trap,
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

/// Copies a run of guest bytes, or null if the range is not fully mapped.
///
/// Used to recover text a title wrote for its own diagnostics. Bounded by the
/// caller's buffer and guarded by a mapping check, since reading unmapped
/// memory while reporting a failure would lose the report.
pub fn readGuestText(
    address_space: *memory.AddressSpace,
    address: u64,
    length: u64,
    buffer: []u8,
) ?[]const u8 {
    if (address == 0 or length == 0) return null;
    const wanted: usize = @intCast(@min(length, buffer.len));
    if (!address_space.isMapped(address, wanted)) return null;

    const bytes: [*]const u8 = @ptrFromInt(address);
    @memcpy(buffer[0..wanted], bytes[0..wanted]);
    return buffer[0..wanted];
}

fn classify(info: cpu.FaultInfo) Diagnosis {
    if (info.kind == .illegal_instruction) return .illegal_instruction;
    if (info.kind != .access_violation) return .unknown;

    // An execute fault at a null address means control reached there, which
    // only happens through a call or jump.
    // A general-protection fault has no faulting address, and the host reports
    // that absence as an all-ones one. Reading it as an address sends the reader
    // hunting for a wild pointer when the guest in fact executed a software
    // interrupt on purpose — which is how a title's own assertions stop it, and
    // means the explanation is in the title's message rather than in memory.
    if (info.memory_address == no_faulting_address) return .trap;

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

/// The longest message recovered from a register.
///
/// Generous on purpose. A title's diagnostic is often several lines — what it
/// wanted, how much, and where it asked from — and the last of those is usually
/// the part that names the subsystem to look at.
const message_limit: usize = 320;

/// Whether a run of guest bytes reads as a message rather than as data.
///
/// Deliberately strict. A pointer into mapped memory nearly always has *some*
/// printable bytes at it, and a report that offers noise as though it were the
/// title's own words is worse than one that offers nothing: it sends the reader
/// after a meaning that was never there.
fn looksLikeMessage(bytes: []const u8) ?[]const u8 {
    var length: usize = 0;
    while (length < bytes.len) : (length += 1) {
        const byte = bytes[length];
        if (byte == '\t' or byte == '\n') continue;
        if (byte < 0x20 or byte >= 0x7f) break;
    }
    if (length < 8) return null;

    // What follows the printable run decides whether it was text. A terminator
    // means it was a string; running to the end of the window means it is a
    // string longer than the window, which is worth showing cut short. Anything
    // else is bytes that merely began like text.
    if (length < bytes.len and bytes[length] != 0) return null;

    const text = bytes[0..length];
    // A run with no letters at all is a table, a key, or a coincidence.
    for (text) |byte| {
        if (std.ascii.isAlphabetic(byte)) return text;
    }
    return null;
}

/// Writes any text the argument registers point at.
///
/// A title about to fail usually says why first, and it says it by passing a
/// message to something. The System V argument registers are where that message
/// is at the moment of the fault, so recovering it turns a register dump into
/// the title's own account of what went wrong — which is worth more than every
/// other line of the report put together when it is there.
pub fn writeMessageArguments(
    report: Report,
    address_space: *memory.AddressSpace,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const registers = report.info.registers;
    const candidates = [_]struct { []const u8, u64 }{
        .{ "rdi", registers.rdi },
        .{ "rsi", registers.rsi },
        .{ "rdx", registers.rdx },
        .{ "rcx", registers.rcx },
        .{ "r8", registers.r8 },
        .{ "r9", registers.r9 },
        .{ "rax", registers.rax },
        .{ "rbx", registers.rbx },
        .{ "r12", registers.r12 },
        .{ "r13", registers.r13 },
        .{ "r14", registers.r14 },
        .{ "r15", registers.r15 },
    };

    var buffer: [message_limit]u8 = undefined;
    var printed: usize = 0;
    for (candidates) |candidate| {
        const name = candidate[0];
        const value = candidate[1];

        if (textAt(address_space, value, &buffer)) |text| {
            if (printed == 0) try w.writeAll("  text in registers\n");
            try w.print("    {s}  \"{s}\"\n", .{ name, text });
            printed += 1;
            continue;
        }

        // One indirection, because a message is as often passed by reference as
        // by value: a string object holds a pointer to its characters, and at
        // the moment of a fault the register holds the object, not the text.
        const indirect = readGuestWord(address_space, value) orelse continue;
        const text = textAt(address_space, indirect, &buffer) orelse continue;
        if (printed == 0) try w.writeAll("  text in registers\n");
        try w.print("    [{s}] \"{s}\"\n", .{ name, text });
        printed += 1;
    }
}

fn textAt(address_space: *memory.AddressSpace, address: u64, buffer: []u8) ?[]const u8 {
    const bytes = readGuestText(address_space, address, buffer.len, buffer) orelse return null;
    return looksLikeMessage(bytes);
}

fn describe(diagnosis: Diagnosis) []const u8 {
    return switch (diagnosis) {
        .null_call => "call through a null pointer",
        .null_access => "access through a null pointer",
        .unmapped_access => "access to unmapped memory",
        .protection => "access violated page protection",
        .illegal_instruction => "illegal instruction",
        .trap => "the guest trapped on purpose, or ran what it may not",
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

test "a deliberate trap is not read as a wild pointer" {
    // A general-protection fault has no faulting address, and the host reports
    // that absence as an all-ones one. Calling it an access to 0xffff...ffff
    // sends the reader hunting through memory for something that was never a
    // memory problem: the guest executed a software interrupt on purpose.
    const info = accessViolation(0x17954a3, std.math.maxInt(u64), .read);
    try testing.expectEqual(Diagnosis.trap, analyze(info, null).diagnosis);

    // One below is an ordinary address and stays an ordinary fault.
    const near = accessViolation(0x17954a3, std.math.maxInt(u64) - 1, .read);
    try testing.expect(analyze(near, null).diagnosis != .trap);
}

test "text is recognised, and near-text is not offered as text" {
    try testing.expectEqualStrings(
        "Could not allocate memory",
        looksLikeMessage("Could not allocate memory\x00rest").?,
    );

    // Too short to be anything but a coincidence: a pointer into mapped memory
    // nearly always has a few printable bytes at it.
    try testing.expect(looksLikeMessage("%s\x00") == null);
    try testing.expect(looksLikeMessage("abc\x00") == null);
    // A message longer than the window is still a message, shown cut short.
    try testing.expectEqualStrings(
        "Could not allocate memory: System",
        looksLikeMessage("Could not allocate memory: System").?,
    );
    // Binary that happens to start with letters.
    try testing.expect(looksLikeMessage("abcdefgh\x01\x02\x00") == null);
    // Digits and punctuation alone are a key or a table, not a message.
    try testing.expect(looksLikeMessage("1234-5678-90\x00") == null);
    // Tabs and newlines belong in a message and do not disqualify one.
    try testing.expect(looksLikeMessage("line one\n\tindented\x00") != null);
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
