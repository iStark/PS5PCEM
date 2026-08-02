// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! What a module needs from outside itself.
//!
//! This is where the three tables finally come together. A relocation names a
//! symbol index; the symbol names a string; the string carries an identifier
//! plus library and module codes; and the codes only mean anything against the
//! declarations in the same module. Walking all four is the only way to learn
//! that a module wants, say, `sceKernelAllocateDirectMemory` from `libkernel`.
//!
//! The result is a description, not an action. Writing resolved addresses back
//! into the image requires it to be mapped, which happens elsewhere.

const std = @import("std");
const elf = @import("elf.zig");
const dynamic = @import("dynamic.zig");
const symbols = @import("symbols.zig");
const relocations = @import("relocations.zig");

pub const Error = error{
    /// A table offset or size falls outside the dynamic-data segment.
    MalformedTable,
} || elf.Error || dynamic.Error || symbols.Error || relocations.Error;

/// One symbol a module expects to be supplied from outside.
pub const Import = struct {
    /// The symbol identifier, as the firmware registry keys on.
    id: []const u8,
    /// Resolved library name, or null if the module declares no matching code.
    library: ?[]const u8,
    library_version: ?u16,
    /// Resolved module name, or null if the code matches no declaration.
    module: ?[]const u8,
    /// The raw codes, retained so an unresolved import can still be reported
    /// usefully.
    library_code: []const u8,
    module_code: []const u8,

    binding: symbols.Binding = .global,
    symbol_type: symbols.Type,
    relocation_type: relocations.Type,
    table: relocations.TableKind,
    /// Where the resolved address is written, relative to the load address.
    target_offset: u64,
    addend: i64,

    /// Whether both codes matched a declaration.
    ///
    /// An import can be well-formed and still land here unresolved: a module
    /// may reference a library code it never declared, and that is worth
    /// reporting rather than silently dropping.
    pub fn isFullyDescribed(self: Import) bool {
        return self.library != null and self.module != null;
    }
};

/// Everything a module imports, plus what could not be described.
pub const Imports = struct {
    items: std.ArrayList(Import) = .empty,
    /// Relocations that reference a symbol whose name is not in the
    /// `identifier#library#module` form. Counted rather than rejected: one
    /// malformed entry should not make the rest of a module unreadable.
    malformed_names: usize = 0,
    /// Relocations that carry no symbol, such as load-bias adjustments. Not
    /// imports, but worth knowing the module has them.
    non_symbolic: usize = 0,

    pub fn deinit(self: *Imports, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
    }

    /// Finds an import by symbol identifier.
    pub fn findById(self: *const Imports, id: []const u8) ?*const Import {
        for (self.items.items) |*imp| {
            if (std.mem.eql(u8, imp.id, id)) return imp;
        }
        return null;
    }
};

/// Reads a NUL-terminated string from the string table.
fn readString(strings: []const u8, offset: u32) Error![]const u8 {
    if (offset >= strings.len) return dynamic.Error.BadStringOffset;
    const rest = strings[offset..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse
        return dynamic.Error.BadStringOffset;
    return rest[0..end];
}

/// Walks one relocation table, appending the imports it describes.
fn collectFrom(
    gpa: std.mem.Allocator,
    out: *Imports,
    table: relocations.Table,
    symtab: symbols.Table,
    strings: []const u8,
    info: *const dynamic.DynamicInfo,
) (Error || std.mem.Allocator.Error)!void {
    for (table.entries) |rela| {
        const reloc_type = rela.relocationType();
        if (!reloc_type.referencesSymbol()) {
            out.non_symbolic += 1;
            continue;
        }

        const sym = try symtab.at(rela.symbolIndex());
        // A defined symbol is provided by the module itself; only undefined
        // ones have to come from outside.
        if (sym.isDefined()) continue;

        const raw_name = try readString(strings, sym.name);
        const parsed = dynamic.parseSymbolName(raw_name) catch {
            out.malformed_names += 1;
            continue;
        };

        const lib = info.findImportLibrary(parsed.library);
        const mod = info.findModule(parsed.module);

        try out.items.append(gpa, .{
            .id = parsed.id,
            .library = if (lib) |l| l.name else null,
            .library_version = if (lib) |l| l.version else null,
            .module = if (mod) |m| m.name else null,
            .library_code = parsed.library,
            .module_code = parsed.module,
            .binding = sym.binding(),
            .symbol_type = sym.symbolType(),
            .relocation_type = reloc_type,
            .table = table.kind,
            .target_offset = rela.offset,
            .addend = if (reloc_type.usesAddend()) rela.addend else 0,
        });
    }
}

/// Collects everything a module imports.
///
/// Both relocation tables are walked; PLT entries and general entries are
/// reported the same way, tagged by which table they came from.
pub fn collect(
    gpa: std.mem.Allocator,
    image: elf.Image,
    info: *const dynamic.DynamicInfo,
) (Error || std.mem.Allocator.Error)!Imports {
    const strings = try info.tableData(image, info.strtab_offset, info.strtab_size);
    const symtab_bytes = try info.tableData(image, info.symtab_offset, info.symtab_size);
    const symtab = try symbols.Table.init(symtab_bytes);

    var out = Imports{};
    errdefer out.deinit(gpa);

    const general = try info.tableData(image, info.rela_offset, info.rela_size);
    if (general.len != 0) {
        try collectFrom(
            gpa,
            &out,
            try relocations.Table.init(general, .general),
            symtab,
            strings,
            info,
        );
    }

    const plt = try info.tableData(image, info.jmprel_offset, info.jmprel_size);
    if (plt.len != 0) {
        try collectFrom(
            gpa,
            &out,
            try relocations.Table.init(plt, .plt),
            symtab,
            strings,
            info,
        );
    }

    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds an image whose dynamic-data segment holds a string table, a symbol
/// table and a relocation table, laid out the way a real module lays them out.
const Fixture = struct {
    image: elf.TestImage,
    payload: std.ArrayList(u8),

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.image.deinit(gpa);
        self.payload.deinit(gpa);
    }

    fn build(
        gpa: std.mem.Allocator,
        strings: []const u8,
        syms: []const symbols.Sym,
        plt_relocs: []const relocations.Rela,
        extra_entries: []const dynamic.Entry,
    ) !Fixture {
        var payload: std.ArrayList(u8) = .empty;
        errdefer payload.deinit(gpa);

        const strtab_off = payload.items.len;
        try payload.appendSlice(gpa, strings);

        // Symbol entries are 8-byte aligned in practice; pad so offsets stay
        // realistic even though the reader does not require it.
        while (payload.items.len % 8 != 0) try payload.append(gpa, 0);
        const symtab_off = payload.items.len;
        try payload.appendSlice(gpa, std.mem.sliceAsBytes(syms));

        const jmprel_off = payload.items.len;
        try payload.appendSlice(gpa, std.mem.sliceAsBytes(plt_relocs));

        const dynlib_len = payload.items.len;

        var entries: std.ArrayList(dynamic.Entry) = .empty;
        defer entries.deinit(gpa);
        try entries.appendSlice(gpa, &.{
            .{ .tag = @intFromEnum(dynamic.Tag.sce_strtab), .value = strtab_off },
            .{ .tag = @intFromEnum(dynamic.Tag.sce_strsz), .value = strings.len },
            .{ .tag = @intFromEnum(dynamic.Tag.sce_symtab), .value = symtab_off },
            .{
                .tag = @intFromEnum(dynamic.Tag.sce_symtabsz),
                .value = syms.len * @sizeOf(symbols.Sym),
            },
            .{ .tag = @intFromEnum(dynamic.Tag.sce_jmprel), .value = jmprel_off },
            .{
                .tag = @intFromEnum(dynamic.Tag.sce_pltrelsz),
                .value = plt_relocs.len * @sizeOf(relocations.Rela),
            },
        });
        try entries.appendSlice(gpa, extra_entries);
        try entries.append(gpa, .{ .tag = @intFromEnum(dynamic.Tag.null), .value = 0 });

        const dynamic_start = payload.items.len;
        try payload.appendSlice(gpa, std.mem.sliceAsBytes(entries.items));

        const base = elf.TestImage.payloadOffset(2);
        const segments = [_]elf.ProgramHeader{
            .{
                .type = @intFromEnum(elf.SegmentType.sce_dynlibdata),
                .flags = 0,
                .offset = base,
                .vaddr = 0,
                .paddr = 0,
                .filesz = dynlib_len,
                .memsz = dynlib_len,
                .@"align" = 1,
            },
            .{
                .type = @intFromEnum(elf.SegmentType.dynamic),
                .flags = 0,
                .offset = base + dynamic_start,
                .vaddr = 0,
                .paddr = 0,
                .filesz = payload.items.len - dynamic_start,
                .memsz = payload.items.len - dynamic_start,
                .@"align" = 8,
            },
        };

        const image = try elf.TestImage.build(gpa, .sce_dynexec, &segments, payload.items);
        return .{ .image = image, .payload = payload };
    }
};

fn undefinedFunc(name_offset: u32) symbols.Sym {
    return .{
        .name = name_offset,
        .info = (1 << 4) | 2, // global func
        .other = 0,
        .shndx = 0, // undefined: must come from outside
        .value = 0,
        .size = 0,
    };
}

fn jumpSlot(sym_index: u32, offset: u64) relocations.Rela {
    return .{
        .offset = offset,
        .info = (@as(u64, sym_index) << 32) | @intFromEnum(relocations.Type.jump_slot),
        .addend = 0,
    };
}

fn packLibrary(id: u16, version: u16, name_offset: u32) u64 {
    return (@as(u64, id) << 48) | (@as(u64, version) << 32) | name_offset;
}

fn packModule(id: u16, major: u8, minor: u8, name_offset: u32) u64 {
    return (@as(u64, id) << 48) | (@as(u64, major) << 40) |
        (@as(u64, minor) << 32) | name_offset;
}

test "an import is described with its library and module resolved" {
    //                0          1          2         3         4         5
    //                0123456789 0123456789 0123456789012345678901234567890
    const strings = "\x00libkernel\x00rTXw65xmLIA#A#A\x00";
    const off_libkernel = 1;
    const off_symbol = 11;

    const syms = [_]symbols.Sym{
        std.mem.zeroes(symbols.Sym), // index 0 is always reserved
        undefinedFunc(off_symbol),
    };
    const relocs = [_]relocations.Rela{jumpSlot(1, 0x3000)};
    const extra = [_]dynamic.Entry{
        .{
            .tag = @intFromEnum(dynamic.Tag.sce_import_lib),
            .value = packLibrary(0, 1, off_libkernel),
        },
        .{
            .tag = @intFromEnum(dynamic.Tag.sce_module_info),
            .value = packModule(0, 1, 1, off_libkernel),
        },
    };

    var fixture = try Fixture.build(testing.allocator, strings, &syms, &relocs, &extra);
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try dynamic.parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    var imports = try collect(testing.allocator, image, &info);
    defer imports.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), imports.items.items.len);

    const imp = imports.items.items[0];
    try testing.expectEqualStrings("rTXw65xmLIA", imp.id);
    try testing.expectEqualStrings("libkernel", imp.library.?);
    try testing.expectEqual(@as(u16, 1), imp.library_version.?);
    try testing.expectEqualStrings("libkernel", imp.module.?);
    try testing.expectEqual(symbols.Binding.global, imp.binding);
    try testing.expectEqual(relocations.Type.jump_slot, imp.relocation_type);
    try testing.expectEqual(relocations.TableKind.plt, imp.table);
    try testing.expectEqual(@as(u64, 0x3000), imp.target_offset);
    try testing.expect(imp.isFullyDescribed());
}

test "a symbol the module defines itself is not an import" {
    const strings = "\x00rTXw65xmLIA#A#A\x00";
    var defined = undefinedFunc(1);
    defined.shndx = 1; // provided by this module
    defined.value = 0x1000;

    const syms = [_]symbols.Sym{ std.mem.zeroes(symbols.Sym), defined };
    const relocs = [_]relocations.Rela{jumpSlot(1, 0x3000)};

    var fixture = try Fixture.build(testing.allocator, strings, &syms, &relocs, &.{});
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try dynamic.parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    var imports = try collect(testing.allocator, image, &info);
    defer imports.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), imports.items.items.len);
}

test "relocations without a symbol are counted, not treated as imports" {
    const strings = "\x00rTXw65xmLIA#A#A\x00";
    const syms = [_]symbols.Sym{ std.mem.zeroes(symbols.Sym), undefinedFunc(1) };
    const relocs = [_]relocations.Rela{
        // A load-bias adjustment: no symbol involved.
        .{
            .offset = 0x1000,
            .info = @intFromEnum(relocations.Type.relative),
            .addend = 0x2000,
        },
        jumpSlot(1, 0x3000),
    };

    var fixture = try Fixture.build(testing.allocator, strings, &syms, &relocs, &.{});
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try dynamic.parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    var imports = try collect(testing.allocator, image, &info);
    defer imports.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), imports.items.items.len);
    try testing.expectEqual(@as(usize, 1), imports.non_symbolic);
}

test "an undeclared library code leaves the import described but unresolved" {
    const strings = "\x00rTXw65xmLIA#B#A\x00";
    const syms = [_]symbols.Sym{ std.mem.zeroes(symbols.Sym), undefinedFunc(1) };
    const relocs = [_]relocations.Rela{jumpSlot(1, 0x3000)};
    // Declares library code "A", but the symbol asks for "B".
    const extra = [_]dynamic.Entry{
        .{ .tag = @intFromEnum(dynamic.Tag.sce_import_lib), .value = packLibrary(0, 1, 0) },
    };

    var fixture = try Fixture.build(testing.allocator, strings, &syms, &relocs, &extra);
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try dynamic.parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    var imports = try collect(testing.allocator, image, &info);
    defer imports.deinit(testing.allocator);

    // Still reported: dropping it would hide why the module fails to load.
    try testing.expectEqual(@as(usize, 1), imports.items.items.len);
    const imp = imports.items.items[0];
    try testing.expect(!imp.isFullyDescribed());
    try testing.expect(imp.library == null);
    try testing.expectEqualStrings("B", imp.library_code);
    try testing.expectEqualStrings("rTXw65xmLIA", imp.id);
}

test "a malformed symbol name is counted and does not stop the walk" {
    //                0        1        2                3
    //                01234567890123456789012345678901234567890
    const strings = "\x00not_a_symbol_name\x00rTXw65xmLIA#A#A\x00";
    const off_bad = 1;
    const off_good = 19;

    const syms = [_]symbols.Sym{
        std.mem.zeroes(symbols.Sym),
        undefinedFunc(off_bad),
        undefinedFunc(off_good),
    };
    const relocs = [_]relocations.Rela{
        jumpSlot(1, 0x3000),
        jumpSlot(2, 0x3008),
    };
    const extra = [_]dynamic.Entry{
        .{ .tag = @intFromEnum(dynamic.Tag.sce_import_lib), .value = packLibrary(0, 1, 0) },
    };

    var fixture = try Fixture.build(testing.allocator, strings, &syms, &relocs, &extra);
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try dynamic.parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    var imports = try collect(testing.allocator, image, &info);
    defer imports.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), imports.malformed_names);
    // The well-formed entry after it is still collected.
    try testing.expectEqual(@as(usize, 1), imports.items.items.len);
    try testing.expect(imports.findById("rTXw65xmLIA") != null);
}

test "a symbol index past the table is rejected" {
    const strings = "\x00rTXw65xmLIA#A#A\x00";
    const syms = [_]symbols.Sym{ std.mem.zeroes(symbols.Sym), undefinedFunc(1) };
    const relocs = [_]relocations.Rela{jumpSlot(9, 0x3000)};

    var fixture = try Fixture.build(testing.allocator, strings, &syms, &relocs, &.{});
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try dynamic.parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    try testing.expectError(
        symbols.Error.SymbolOutOfRange,
        collect(testing.allocator, image, &info),
    );
}

test "a relocation table reaching past its segment is rejected" {
    const strings = "\x00rTXw65xmLIA#A#A\x00";
    const syms = [_]symbols.Sym{ std.mem.zeroes(symbols.Sym), undefinedFunc(1) };
    const relocs = [_]relocations.Rela{jumpSlot(1, 0x3000)};

    var fixture = try Fixture.build(testing.allocator, strings, &syms, &relocs, &.{});
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try dynamic.parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    // Claim a far larger PLT table than the segment holds.
    info.jmprel_size = 64 * 1024;
    try testing.expectError(Error.MalformedTable, collect(testing.allocator, image, &info));
}
