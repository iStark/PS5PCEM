// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Relocation entries of a guest module.
//!
//! Plain ELF64 `RELA` form. A module carries two tables: the general one and a
//! separate PLT table, reached through different dynamic tags but identical in
//! layout.
//!
//! Only a small set of relocation types occurs in practice, and the distinction
//! that matters here is whether an entry references a symbol — that is what
//! makes it an import that has to be satisfied from outside the module.

const std = @import("std");

pub const Error = error{
    /// The table length is not a whole number of entries.
    MalformedTable,
};

/// x86-64 relocation types that appear in guest modules.
pub const Type = enum(u32) {
    none = 0,
    /// Absolute 64-bit address of a symbol, plus addend.
    direct_64 = 1,
    /// Slot in the global offset table.
    glob_dat = 6,
    /// Slot in the procedure linkage table.
    jump_slot = 7,
    /// Load address plus addend; no symbol involved.
    relative = 8,
    /// Thread-local storage: module identifier.
    dtpmod64 = 16,
    /// Thread-local storage: offset within the module's block.
    dtpoff64 = 17,
    /// Thread-local storage: offset from the thread pointer.
    tpoff64 = 18,
    _,

    /// Whether entries of this type name a symbol that must be resolved.
    ///
    /// `relative` is the notable exception: it adjusts an address by the load
    /// bias and involves no symbol at all.
    pub fn referencesSymbol(self: Type) bool {
        return switch (self) {
            .direct_64, .glob_dat, .jump_slot, .dtpmod64, .dtpoff64, .tpoff64 => true,
            else => false,
        };
    }

    /// Whether the addend participates in the computed value.
    ///
    /// GOT and PLT slots are overwritten with the symbol address outright; the
    /// addend field is present but not part of the result.
    pub fn usesAddend(self: Type) bool {
        return switch (self) {
            .glob_dat, .jump_slot => false,
            else => true,
        };
    }
};

/// A relocation entry, in file layout.
pub const Rela = extern struct {
    /// Where the result is written, relative to the module's load address.
    offset: u64,
    /// Symbol index in the high 32 bits, relocation type in the low 32.
    info: u64,
    addend: i64,

    pub fn symbolIndex(self: Rela) u32 {
        return @truncate(self.info >> 32);
    }

    pub fn relocationType(self: Rela) Type {
        return @enumFromInt(@as(u32, @truncate(self.info)));
    }
};

comptime {
    std.debug.assert(@sizeOf(Rela) == 24);
}

/// Which table an entry came from.
///
/// Worth keeping: PLT entries are what lazy binding would go through, and they
/// are the ones that must point at a callable stub rather than at data.
pub const TableKind = enum { general, plt };

/// A view over one relocation table. Borrows the image.
pub const Table = struct {
    entries: []align(1) const Rela,
    kind: TableKind,

    pub fn init(bytes: []const u8, kind: TableKind) Error!Table {
        if (bytes.len % @sizeOf(Rela) != 0) return Error.MalformedTable;
        return .{ .entries = std.mem.bytesAsSlice(Rela, bytes), .kind = kind };
    }

    pub fn len(self: Table) usize {
        return self.entries.len;
    }
};

const testing = std.testing;

test "symbol index and type unpack from r_info" {
    const r = Rela{
        .offset = 0x2000,
        .info = (@as(u64, 7) << 32) | @intFromEnum(Type.jump_slot),
        .addend = 0,
    };
    try testing.expectEqual(@as(u32, 7), r.symbolIndex());
    try testing.expectEqual(Type.jump_slot, r.relocationType());
}

test "relative relocations reference no symbol" {
    try testing.expect(!Type.relative.referencesSymbol());
    try testing.expect(!Type.none.referencesSymbol());

    try testing.expect(Type.jump_slot.referencesSymbol());
    try testing.expect(Type.glob_dat.referencesSymbol());
    try testing.expect(Type.direct_64.referencesSymbol());
    try testing.expect(Type.tpoff64.referencesSymbol());
}

test "GOT and PLT slots ignore the addend" {
    try testing.expect(!Type.glob_dat.usesAddend());
    try testing.expect(!Type.jump_slot.usesAddend());
    try testing.expect(Type.direct_64.usesAddend());
    try testing.expect(Type.relative.usesAddend());
}

test "a table of whole entries is accepted" {
    const entries = [_]Rela{
        .{ .offset = 0, .info = 0, .addend = 0 },
        .{ .offset = 8, .info = 0, .addend = 0 },
    };
    const table = try Table.init(std.mem.sliceAsBytes(&entries), .plt);
    try testing.expectEqual(@as(usize, 2), table.len());
    try testing.expectEqual(TableKind.plt, table.kind);
}

test "a partial entry is rejected" {
    const bytes = [_]u8{0} ** (@sizeOf(Rela) + 8);
    try testing.expectError(Error.MalformedTable, Table.init(&bytes, .general));
}
