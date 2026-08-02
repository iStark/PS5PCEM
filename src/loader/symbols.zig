// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The dynamic symbol table of a guest module.
//!
//! Layout is plain ELF64. What differs is the meaning of `st_name`: instead of
//! a readable name it points at a string of the form
//! `identifier#library#module`, so a symbol is only interpretable together with
//! the module's library and module declarations.

const std = @import("std");

pub const Error = error{
    /// The table length is not a whole number of entries, or runs past its
    /// segment.
    MalformedTable,
    /// A symbol index is outside the table.
    SymbolOutOfRange,
};

/// Symbol binding, from the high nibble of `st_info`.
pub const Binding = enum(u4) {
    local = 0,
    global = 1,
    weak = 2,
    _,
};

/// Symbol type, from the low nibble of `st_info`.
pub const Type = enum(u4) {
    no_type = 0,
    object = 1,
    func = 2,
    section = 3,
    file = 4,
    common = 5,
    tls = 6,
    _,
};

/// A symbol table entry, in file layout.
pub const Sym = extern struct {
    name: u32,
    info: u8,
    other: u8,
    shndx: u16,
    value: u64,
    size: u64,

    pub fn binding(self: Sym) Binding {
        return @enumFromInt(@as(u4, @truncate(self.info >> 4)));
    }

    pub fn symbolType(self: Sym) Type {
        return @enumFromInt(@as(u4, @truncate(self.info)));
    }

    /// Whether the symbol is defined by this module rather than imported.
    ///
    /// `shndx == 0` means undefined, which for a guest module means it is
    /// expected to come from the firmware.
    pub fn isDefined(self: Sym) bool {
        return self.shndx != 0;
    }
};

comptime {
    std.debug.assert(@sizeOf(Sym) == 24);
}

/// A view over a module's symbol table. Borrows the image.
pub const Table = struct {
    entries: []align(1) const Sym,

    /// Wraps a byte range as a symbol table.
    pub fn init(bytes: []const u8) Error!Table {
        if (bytes.len % @sizeOf(Sym) != 0) return Error.MalformedTable;
        return .{ .entries = std.mem.bytesAsSlice(Sym, bytes) };
    }

    pub fn len(self: Table) usize {
        return self.entries.len;
    }

    pub fn at(self: Table, index: usize) Error!Sym {
        if (index >= self.entries.len) return Error.SymbolOutOfRange;
        return self.entries[index];
    }
};

const testing = std.testing;

test "symbol fields decode from st_info and st_shndx" {
    const global_func = Sym{
        .name = 1,
        .info = (1 << 4) | 2, // global, func
        .other = 0,
        .shndx = 0,
        .value = 0,
        .size = 0,
    };
    try testing.expectEqual(Binding.global, global_func.binding());
    try testing.expectEqual(Type.func, global_func.symbolType());
    // Section index zero means the symbol is imported, not provided.
    try testing.expect(!global_func.isDefined());

    const local_object = Sym{
        .name = 5,
        .info = (0 << 4) | 1, // local, object
        .other = 0,
        .shndx = 3,
        .value = 0x1000,
        .size = 8,
    };
    try testing.expectEqual(Binding.local, local_object.binding());
    try testing.expectEqual(Type.object, local_object.symbolType());
    try testing.expect(local_object.isDefined());
}

test "a table of whole entries is accepted and indexed" {
    const syms = [_]Sym{
        .{ .name = 0, .info = 0, .other = 0, .shndx = 0, .value = 0, .size = 0 },
        .{ .name = 1, .info = 0x12, .other = 0, .shndx = 0, .value = 0, .size = 0 },
    };
    const table = try Table.init(std.mem.sliceAsBytes(&syms));

    try testing.expectEqual(@as(usize, 2), table.len());
    try testing.expectEqual(@as(u32, 1), (try table.at(1)).name);
    try testing.expectError(Error.SymbolOutOfRange, table.at(2));
}

test "a partial entry is rejected" {
    const bytes = [_]u8{0} ** (@sizeOf(Sym) + 1);
    try testing.expectError(Error.MalformedTable, Table.init(&bytes));
}
