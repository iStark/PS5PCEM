// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Turns guest addresses back into module names and symbols.
//!
//! Once a title is running, every diagnostic the emulator can produce is an
//! address. On its own an address says nothing: it depends on where modules
//! happened to be placed, and the same fault reads differently between runs.
//!
//! This maps an address back to the module that owns it, the offset within
//! that module, and the nearest export at or below it. Only exported symbols
//! are available — a title ships no debug information — so the nearest export
//! is an anchor rather than an exact function name. It is still the difference
//! between "faulted at 0x40070" and "faulted 0x2c into a known libc export".

const std = @import("std");
const memory = @import("memory");
const loader = @import("loader");

/// One exported symbol, reduced to what attribution needs.
const Symbol = struct {
    address: u64,
    id: []const u8,
    library: []const u8,
};

const Module = struct {
    /// Display name, usually the file's basename. Borrowed.
    name: []const u8,
    load_bias: u64,
    /// Extent of everything the module has mapped.
    start: u64,
    end: u64,
    /// Exports sorted by address, so the nearest one is a binary search.
    symbols: std.ArrayList(Symbol) = .empty,

    fn contains(self: Module, address: u64) bool {
        return address >= self.start and address < self.end;
    }

    /// Nearest export at or below `address`.
    fn nearest(self: Module, address: u64) ?Symbol {
        const items = self.symbols.items;
        if (items.len == 0) return null;

        var low: usize = 0;
        var high: usize = items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (items[mid].address <= address) low = mid + 1 else high = mid;
        }
        if (low == 0) return null;
        return items[low - 1];
    }
};

/// Where an address falls.
pub const Location = struct {
    /// Null when no loaded module covers the address.
    module: ?[]const u8 = null,
    /// Offset from the module's load bias, which is what a disassembly of the
    /// file on disk uses.
    module_offset: u64 = 0,
    /// Nearest export at or below the address, if the module has any.
    symbol: ?[]const u8 = null,
    symbol_library: ?[]const u8 = null,
    symbol_offset: u64 = 0,

    pub fn isKnown(self: Location) bool {
        return self.module != null;
    }
};

pub const SymbolMap = struct {
    modules: std.ArrayList(Module) = .empty,

    pub fn deinit(self: *SymbolMap, gpa: std.mem.Allocator) void {
        for (self.modules.items) |*m| m.symbols.deinit(gpa);
        self.modules.deinit(gpa);
    }

    /// Registers a mapped module.
    ///
    /// `ranges` are the committed regions; their span defines what the module
    /// owns. `exports` may be empty — attribution then stops at module and
    /// offset, which is still enough to locate the code in a file dump.
    pub fn addModule(
        self: *SymbolMap,
        gpa: std.mem.Allocator,
        name: []const u8,
        load_bias: u64,
        ranges: []const memory.Range,
        module_exports: []const loader.GuestExport,
    ) std.mem.Allocator.Error!void {
        var start: u64 = std.math.maxInt(u64);
        var end: u64 = 0;
        for (ranges) |range| {
            start = @min(start, range.start);
            end = @max(end, range.end);
        }
        // A module with no committed ranges still deserves an entry, anchored
        // at its load bias, so its exports remain attributable.
        if (end == 0) {
            start = load_bias;
            end = load_bias;
        }

        var module = Module{
            .name = name,
            .load_bias = load_bias,
            .start = start,
            .end = end,
        };
        errdefer module.symbols.deinit(gpa);

        try module.symbols.ensureTotalCapacity(gpa, module_exports.len);
        for (module_exports) |e| {
            // Data exports would pull address attribution toward variables that
            // never appear in a call stack.
            if (e.symbol_type != .func) continue;
            module.symbols.appendAssumeCapacity(.{
                .address = e.address,
                .id = e.id,
                .library = e.library,
            });
        }
        std.mem.sort(Symbol, module.symbols.items, {}, lessByAddress);

        try self.modules.append(gpa, module);
    }

    fn lessByAddress(_: void, a: Symbol, b: Symbol) bool {
        return a.address < b.address;
    }

    pub fn locate(self: *const SymbolMap, address: u64) Location {
        for (self.modules.items) |*module| {
            if (!module.contains(address)) continue;

            var location = Location{
                .module = module.name,
                .module_offset = address - module.load_bias,
            };
            if (module.nearest(address)) |symbol| {
                location.symbol = symbol.id;
                location.symbol_library = symbol.library;
                location.symbol_offset = address - symbol.address;
            }
            return location;
        }
        return .{};
    }

    /// Writes an address in the most specific form available.
    ///
    /// `libc.prx+0x8f3c (rTXw65xmLIA+0x2c)` when a symbol anchors it,
    /// `libc.prx+0x8f3c` when the module has no usable exports, and
    /// `0x0000000000000000 <unmapped>` when nothing owns the address — which is
    /// itself the answer when a title calls through a null pointer.
    pub fn write(self: *const SymbolMap, address: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const location = self.locate(address);
        if (location.module == null) {
            try w.print("0x{x:0>16} <unmapped>", .{address});
            return;
        }

        try w.print("0x{x:0>16} {s}+0x{x}", .{ address, location.module.?, location.module_offset });
        if (location.symbol) |symbol| {
            try w.print(" ({s}+0x{x})", .{ symbol, location.symbol_offset });
        }
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn funcExport(id: []const u8, address: u64) loader.GuestExport {
    return .{
        .id = id,
        .library = "libkernel",
        .library_version = 1,
        .module = "libkernel",
        .symbol_type = .func,
        .address = address,
    };
}

test "an address resolves to its module and offset" {
    var map = SymbolMap{};
    defer map.deinit(testing.allocator);

    try map.addModule(
        testing.allocator,
        "libc.prx",
        0x1000,
        &.{.{ .start = 0x1000, .end = 0x9000 }},
        &.{},
    );

    const location = map.locate(0x1234);
    try testing.expect(location.isKnown());
    try testing.expectEqualStrings("libc.prx", location.module.?);
    try testing.expectEqual(@as(u64, 0x234), location.module_offset);
    // Without exports there is nothing to anchor to.
    try testing.expect(location.symbol == null);
}

test "the nearest preceding export anchors the address" {
    var map = SymbolMap{};
    defer map.deinit(testing.allocator);

    try map.addModule(
        testing.allocator,
        "libc.prx",
        0x1000,
        &.{.{ .start = 0x1000, .end = 0x9000 }},
        // Deliberately out of order: registration must sort them.
        &.{
            funcExport("cccccccccc1", 0x5000),
            funcExport("aaaaaaaaaa1", 0x2000),
            funcExport("bbbbbbbbbb1", 0x3000),
        },
    );

    const inside = map.locate(0x3040);
    try testing.expectEqualStrings("bbbbbbbbbb1", inside.symbol.?);
    try testing.expectEqual(@as(u64, 0x40), inside.symbol_offset);

    // Exactly on a symbol.
    try testing.expectEqual(@as(u64, 0), map.locate(0x5000).symbol_offset);
    try testing.expectEqualStrings("cccccccccc1", map.locate(0x5000).symbol.?);

    // Past the last symbol still anchors to it; there is nothing better.
    try testing.expectEqualStrings("cccccccccc1", map.locate(0x8000).symbol.?);

    // Below the first symbol has no anchor, and must not pick the last one.
    try testing.expect(map.locate(0x1100).symbol == null);
}

test "data exports do not anchor code addresses" {
    var map = SymbolMap{};
    defer map.deinit(testing.allocator);

    var data = funcExport("dddddddddd1", 0x2000);
    data.symbol_type = .object;

    try map.addModule(
        testing.allocator,
        "libc.prx",
        0x1000,
        &.{.{ .start = 0x1000, .end = 0x9000 }},
        &.{ data, funcExport("ffffffffff1", 0x1800) },
    );

    // The object at 0x2000 is nearer, but a variable never appears in a call
    // stack, so the function below it is the honest anchor.
    const location = map.locate(0x2100);
    try testing.expectEqualStrings("ffffffffff1", location.symbol.?);
}

test "addresses outside every module are reported as unmapped" {
    var map = SymbolMap{};
    defer map.deinit(testing.allocator);

    try map.addModule(
        testing.allocator,
        "libc.prx",
        0x1000,
        &.{.{ .start = 0x1000, .end = 0x9000 }},
        &.{},
    );

    try testing.expect(!map.locate(0).isKnown());
    try testing.expect(!map.locate(0x9000).isKnown());
    try testing.expect(map.locate(0x8fff).isKnown());
}

test "several modules are distinguished" {
    var map = SymbolMap{};
    defer map.deinit(testing.allocator);

    try map.addModule(
        testing.allocator,
        "eboot.bin",
        0x40000,
        &.{.{ .start = 0x40000, .end = 0x80000 }},
        &.{},
    );
    try map.addModule(
        testing.allocator,
        "libc.prx",
        0x100000,
        &.{.{ .start = 0x100000, .end = 0x200000 }},
        &.{funcExport("aaaaaaaaaa1", 0x110000)},
    );

    try testing.expectEqualStrings("eboot.bin", map.locate(0x40070).module.?);
    try testing.expectEqual(@as(u64, 0x70), map.locate(0x40070).module_offset);

    const in_libc = map.locate(0x110020);
    try testing.expectEqualStrings("libc.prx", in_libc.module.?);
    try testing.expectEqualStrings("aaaaaaaaaa1", in_libc.symbol.?);
}

test "written form carries as much detail as is known" {
    var map = SymbolMap{};
    defer map.deinit(testing.allocator);

    try map.addModule(
        testing.allocator,
        "libc.prx",
        0x1000,
        &.{.{ .start = 0x1000, .end = 0x9000 }},
        &.{funcExport("aaaaaaaaaa1", 0x2000)},
    );

    var buf: [256]u8 = undefined;

    var w = std.Io.Writer.fixed(&buf);
    try map.write(0x202c, &w);
    try testing.expectEqualStrings(
        "0x000000000000202c libc.prx+0x102c (aaaaaaaaaa1+0x2c)",
        w.buffered(),
    );

    var w2 = std.Io.Writer.fixed(&buf);
    try map.write(0, &w2);
    try testing.expectEqualStrings("0x0000000000000000 <unmapped>", w2.buffered());
}
