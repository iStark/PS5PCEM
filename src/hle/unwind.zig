// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Where a title's exception-handling tables live.
//!
//! When guest code throws, its C++ runtime walks the stack and asks the kernel,
//! for each return address, which module owns it and where that module's unwind
//! tables are. Without an answer the runtime cannot find a handler, so every
//! exception — including ones the title catches and recovers from — becomes a
//! call to `terminate`.
//!
//! The information is per-module and fixed once a module is mapped, so the
//! loader publishes it here and the firmware entry point reads it back. This
//! layer holds the registry rather than the loader because a guest calls into
//! it, and rather than the runtime because the entry point lives here.

const std = @import("std");

/// One mapped module, as the unwinder needs to see it.
pub const Module = struct {
    /// Module name as the title knows it; reported back verbatim.
    name: []const u8,
    /// Lowest and highest addresses the module occupies.
    start: u64,
    end: u64,
    /// The `PT_GNU_EH_FRAME` segment: the searchable index of unwind records.
    eh_frame_header: u64 = 0,
    eh_frame_header_size: u64 = 0,
    /// The unwind records themselves, when their extent is known.
    eh_frame: u64 = 0,
    eh_frame_size: u64 = 0,

    pub fn contains(self: Module, address: u64) bool {
        return address >= self.start and address < self.end;
    }
};

/// The modules currently mapped.
///
/// A plain slice published by the runtime: modules are registered once at load
/// and the set does not change while a title runs, so nothing here owns memory
/// or needs locking.
var modules: []const Module = &.{};

pub fn attach(value: []const Module) void {
    modules = value;
}

pub fn detach() void {
    modules = &.{};
}

pub fn find(address: u64) ?*const Module {
    for (modules) |*module| {
        if (module.contains(address)) return module;
    }
    return null;
}

pub fn count() usize {
    return modules.len;
}

/// The record the guest's runtime reads, in guest layout.
///
/// `size` is filled in by the caller before the call and checked by the
/// firmware: it is how the guest declares which version of the record it
/// understands, so a smaller value has to be rejected rather than partially
/// filled.
pub const Info = extern struct {
    size: u64 = @sizeOf(Info),
    name: [256]u8 = [_]u8{0} ** 256,
    eh_frame_header: u64 = 0,
    eh_frame: u64 = 0,
    eh_frame_size: u64 = 0,
    segment_address: u64 = 0,
    segment_size: u64 = 0,
};

comptime {
    // The guest allocates this by size, so its layout is part of the ABI.
    std.debug.assert(@sizeOf(Info) == 304);
    std.debug.assert(@offsetOf(Info, "name") == 8);
    std.debug.assert(@offsetOf(Info, "eh_frame_header") == 264);
    std.debug.assert(@offsetOf(Info, "segment_address") == 288);
}

/// Fills `info` from a registered module.
pub fn describe(module: *const Module, info: *Info) void {
    info.* = .{};
    const wanted = @min(module.name.len, info.name.len - 1);
    @memcpy(info.name[0..wanted], module.name[0..wanted]);
    info.eh_frame_header = module.eh_frame_header;
    info.eh_frame = module.eh_frame;
    info.eh_frame_size = module.eh_frame_size;
    info.segment_address = module.start;
    info.segment_size = module.end - module.start;
}

/// Reads the address of the unwind records out of an index header.
///
/// The header stores the pointer in a DWARF encoding chosen by the compiler.
/// Only the one every toolchain actually emits is decoded — a signed 32-bit
/// displacement from the field itself. Anything else leaves the address unset,
/// which is honest: the index alone is enough for a runtime to search, and a
/// wrong address would be worse than none.
///
/// `read` returns the header bytes, or null if they are not readable.
pub fn decodeEhFrame(
    header_address: u64,
    header_size: u64,
    read: *const fn (u64, []u8) bool,
) ?u64 {
    if (header_address == 0 or header_size < 8) return null;

    var bytes: [8]u8 = undefined;
    if (!read(header_address, &bytes)) return null;

    // version, pointer encoding, count encoding, table encoding, then the
    // encoded pointer.
    if (bytes[0] != 1) return null;
    const encoding = bytes[1];
    const pcrel_sdata4 = 0x1b;
    if (encoding != pcrel_sdata4) return null;

    const displacement = std.mem.readInt(i32, bytes[4..8], .little);
    const field_address = header_address + 4;
    const target = @as(i64, @intCast(field_address)) + displacement;
    if (target <= 0) return null;
    return @intCast(target);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const sample = [_]Module{
    .{
        .name = "eboot.bin",
        .start = 0x40000,
        .end = 0x80000,
        .eh_frame_header = 0x70000,
        .eh_frame_header_size = 0x100,
    },
    .{
        .name = "libc.prx",
        .start = 0x8016fc000,
        .end = 0x801900000,
    },
};

test "an address resolves to the module that owns it" {
    attach(&sample);
    defer detach();

    try testing.expectEqualStrings("eboot.bin", find(0x40070).?.name);
    try testing.expectEqualStrings("libc.prx", find(0x801731565).?.name);
    // Between and beyond the modules there is nothing.
    try testing.expect(find(0x100000) == null);
    try testing.expect(find(0) == null);
}

test "the record is filled in guest layout" {
    attach(&sample);
    defer detach();

    var info = Info{};
    describe(find(0x40070).?, &info);

    try testing.expectEqual(@as(u64, @sizeOf(Info)), info.size);
    try testing.expectEqualStrings("eboot.bin", std.mem.sliceTo(&info.name, 0));
    try testing.expectEqual(@as(u64, 0x70000), info.eh_frame_header);
    try testing.expectEqual(@as(u64, 0x40000), info.segment_address);
    try testing.expectEqual(@as(u64, 0x40000), info.segment_size);
}

test "an over-long name is truncated and stays terminated" {
    const long = Module{ .name = "x" ** 400, .start = 0, .end = 1 };
    var info = Info{};
    describe(&long, &info);

    // The guest reads this as a C string, so the terminator has to survive.
    try testing.expectEqual(@as(usize, 255), std.mem.sliceTo(&info.name, 0).len);
    try testing.expectEqual(@as(u8, 0), info.name[255]);
}

var decode_source: []const u8 = &.{};
var decode_base: u64 = 0;

fn readFromSource(address: u64, out: []u8) bool {
    if (address < decode_base) return false;
    const offset = address - decode_base;
    if (offset + out.len > decode_source.len) return false;
    @memcpy(out, decode_source[@intCast(offset)..][0..out.len]);
    return true;
}

test "the common pointer encoding is decoded" {
    // version 1, pcrel|sdata4 pointer, then a displacement of -0x1000 from the
    // field at header+4.
    var header: [8]u8 = .{ 1, 0x1b, 0x03, 0x3b, 0, 0, 0, 0 };
    std.mem.writeInt(i32, header[4..8], -0x1000, .little);

    decode_source = &header;
    decode_base = 0x70000;
    defer decode_source = &.{};

    const decoded = decodeEhFrame(0x70000, 0x100, &readFromSource);
    try testing.expectEqual(@as(u64, 0x70004 - 0x1000), decoded.?);
}

test "an unfamiliar encoding leaves the address unset" {
    var header: [8]u8 = .{ 1, 0x50, 0, 0, 0, 0, 0, 0 };
    decode_source = &header;
    decode_base = 0x70000;
    defer decode_source = &.{};

    // Reporting a wrong address would be worse than reporting none: the index
    // alone is enough for a runtime to search.
    try testing.expect(decodeEhFrame(0x70000, 0x100, &readFromSource) == null);

    // A different version is equally unsafe to guess at.
    header[0] = 2;
    header[1] = 0x1b;
    try testing.expect(decodeEhFrame(0x70000, 0x100, &readFromSource) == null);
}

test "unreadable or absent headers are rejected" {
    decode_source = &.{};
    decode_base = 0;

    try testing.expect(decodeEhFrame(0, 0x100, &readFromSource) == null);
    try testing.expect(decodeEhFrame(0x70000, 4, &readFromSource) == null);
    try testing.expect(decodeEhFrame(0x70000, 0x100, &readFromSource) == null);
}
