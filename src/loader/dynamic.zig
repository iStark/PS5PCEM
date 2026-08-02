// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The dynamic linking tables of a guest module.
//!
//! Two things make these different from a conventional ELF and are the reason
//! this cannot be handed to a stock dynamic linker:
//!
//!   * The tables do not live in the loaded address space. They sit in a
//!     separate segment, and the pointer-valued dynamic entries are offsets
//!     into that segment rather than virtual addresses.
//!
//!   * Imports do not name what they need. A symbol name is
//!     `identifier#library#module`, where the two short codes refer to library
//!     and module declarations carried in the same tables. Resolving an import
//!     means looking up both, which is why they are parsed together here.

const std = @import("std");
const elf = @import("elf.zig");
const ids = @import("ids.zig");

pub const Error = error{
    /// An entry describes a range outside the tables.
    MalformedTable,
    /// A string table offset is out of range or unterminated.
    BadStringOffset,
    /// A symbol name did not have the `identifier#library#module` shape.
    MalformedSymbolName,
} || elf.Error || ids.DecodeError;

/// Dynamic entry tags.
///
/// Standard tags keep their usual values; the vendor tags in the `0x6100_00xx`
/// range replace the standard ones for everything that would otherwise be a
/// virtual address, because these tables are not mapped.
pub const Tag = enum(i64) {
    null = 0,
    needed = 1,
    init = 12,
    fini = 13,
    soname = 14,
    debug = 21,
    init_array = 25,
    fini_array = 26,
    init_arraysz = 27,
    fini_arraysz = 28,
    flags = 30,

    /// Identity of this module.
    sce_module_info = 0x6100_000d,
    sce_module_attr = 0x6100_0011,
    /// A module this one depends on.
    sce_needed_module = 0x6100_000f,
    /// A library this module exports.
    sce_export_lib = 0x6100_0013,
    sce_export_lib_attr = 0x6100_0017,
    /// A library this module imports from.
    sce_import_lib = 0x6100_0015,
    sce_import_lib_attr = 0x6100_0019,
    sce_fingerprint = 0x6100_0007,
    sce_original_filename = 0x6100_0009,
    sce_hash = 0x6100_0025,
    sce_hashsz = 0x6100_003d,
    sce_pltgot = 0x6100_0027,
    sce_jmprel = 0x6100_0029,
    sce_pltrel = 0x6100_002b,
    sce_pltrelsz = 0x6100_002d,
    sce_rela = 0x6100_002f,
    sce_relasz = 0x6100_0031,
    sce_relaent = 0x6100_0033,
    sce_strtab = 0x6100_0035,
    sce_strsz = 0x6100_0037,
    sce_symtab = 0x6100_0039,
    sce_syment = 0x6100_003b,
    sce_symtabsz = 0x6100_003f,

    // Some modules carry a second numbering for the same information.
    sce_module_info_1 = 0x6100_0043,
    sce_needed_module_1 = 0x6100_0045,
    sce_export_lib_1 = 0x6100_0047,
    sce_import_lib_1 = 0x6100_0049,
    sce_original_filename_1 = 0x6100_0041,
    _,

    /// Whether the tag declares an imported library, under either numbering.
    pub fn isImportLib(self: Tag) bool {
        return self == .sce_import_lib or self == .sce_import_lib_1;
    }

    pub fn isExportLib(self: Tag) bool {
        return self == .sce_export_lib or self == .sce_export_lib_1;
    }

    pub fn isNeededModule(self: Tag) bool {
        return self == .sce_needed_module or self == .sce_needed_module_1;
    }

    pub fn isModuleInfo(self: Tag) bool {
        return self == .sce_module_info or self == .sce_module_info_1;
    }
};

/// One dynamic entry, in file layout.
pub const Entry = extern struct {
    tag: i64,
    value: u64,

    pub fn dynamicTag(self: Entry) Tag {
        return @enumFromInt(self.tag);
    }
};

comptime {
    std.debug.assert(@sizeOf(Entry) == 16);
}

/// A library declaration.
///
/// The packing is dictated by the format: identifier in the top 16 bits,
/// version below it, and a string table offset in the low 32.
pub const LibraryDecl = struct {
    id: ids.Id,
    version: u16,
    name: []const u8,

    fn parse(value: u64, strings: []const u8) Error!LibraryDecl {
        return .{
            .id = ids.encode(@truncate(value >> 48)),
            .version = @truncate(value >> 32),
            .name = try readString(strings, @truncate(value)),
        };
    }
};

/// A module declaration. Same packing, but the version is split into a major
/// and minor byte.
pub const ModuleDecl = struct {
    id: ids.Id,
    version_major: u8,
    version_minor: u8,
    name: []const u8,

    fn parse(value: u64, strings: []const u8) Error!ModuleDecl {
        return .{
            .id = ids.encode(@truncate(value >> 48)),
            .version_major = @truncate(value >> 40),
            .version_minor = @truncate(value >> 32),
            .name = try readString(strings, @truncate(value)),
        };
    }
};

/// A symbol name split into its three parts.
///
/// The library and module codes are meaningless on their own; they have to be
/// matched against the declarations in the same module.
pub const SymbolName = struct {
    id: []const u8,
    library: []const u8,
    module: []const u8,
};

/// Splits `identifier#library#module`.
///
/// A name without both separators is rejected rather than guessed at: a bare
/// identifier would silently resolve against the wrong library.
pub fn parseSymbolName(name: []const u8) Error!SymbolName {
    const first = std.mem.indexOfScalar(u8, name, '#') orelse
        return Error.MalformedSymbolName;
    const rest = name[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '#') orelse
        return Error.MalformedSymbolName;

    const parsed = SymbolName{
        .id = name[0..first],
        .library = rest[0..second],
        .module = rest[second + 1 ..],
    };
    if (parsed.id.len == 0 or parsed.library.len == 0 or parsed.module.len == 0) {
        return Error.MalformedSymbolName;
    }
    // Validate the codes so a malformed name fails here rather than as a
    // mysterious failed lookup later.
    _ = try ids.decode(parsed.library);
    _ = try ids.decode(parsed.module);
    return parsed;
}

/// Reads a NUL-terminated string from the string table.
fn readString(strings: []const u8, offset: u32) Error![]const u8 {
    if (offset >= strings.len) return Error.BadStringOffset;
    const rest = strings[offset..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse return Error.BadStringOffset;
    return rest[0..end];
}

/// Everything the dynamic tables declare about a module.
///
/// All slices borrow the image, so this stays valid only as long as the buffer
/// it was parsed from.
pub const DynamicInfo = struct {
    /// This module's own identity, if declared.
    module_info: ?ModuleDecl = null,
    needed_modules: std.ArrayList(ModuleDecl) = .empty,
    import_libraries: std.ArrayList(LibraryDecl) = .empty,
    export_libraries: std.ArrayList(LibraryDecl) = .empty,

    /// Offsets within the dynamic-data segment, not virtual addresses.
    strtab_offset: ?u64 = null,
    strtab_size: ?u64 = null,
    symtab_offset: ?u64 = null,
    symtab_size: ?u64 = null,
    jmprel_offset: ?u64 = null,
    jmprel_size: ?u64 = null,
    rela_offset: ?u64 = null,
    rela_size: ?u64 = null,

    pub fn deinit(self: *DynamicInfo, gpa: std.mem.Allocator) void {
        self.needed_modules.deinit(gpa);
        self.import_libraries.deinit(gpa);
        self.export_libraries.deinit(gpa);
    }

    /// Finds an imported library declaration by its short code.
    pub fn findImportLibrary(self: *const DynamicInfo, id: []const u8) ?*const LibraryDecl {
        for (self.import_libraries.items) |*lib| {
            if (lib.id.eql(id)) return lib;
        }
        return null;
    }

    pub fn findExportLibrary(self: *const DynamicInfo, id: []const u8) ?*const LibraryDecl {
        for (self.export_libraries.items) |*lib| {
            if (lib.id.eql(id)) return lib;
        }
        return null;
    }

    pub fn findModule(self: *const DynamicInfo, id: []const u8) ?*const ModuleDecl {
        if (self.module_info) |*own| {
            if (own.id.eql(id)) return own;
        }
        for (self.needed_modules.items) |*m| {
            if (m.id.eql(id)) return m;
        }
        return null;
    }
};

/// Locates the string table inside the dynamic-data segment.
///
/// Done in a first pass because library and module declarations resolve their
/// names through it, and the entries that declare them can appear before the
/// entry that locates the table.
fn findStringTable(entries: []align(1) const Entry, dynlib_data: []const u8) Error![]const u8 {
    var offset: ?u64 = null;
    var size: ?u64 = null;
    for (entries) |e| {
        switch (e.dynamicTag()) {
            .sce_strtab => offset = e.value,
            .sce_strsz => size = e.value,
            else => {},
        }
    }

    const start = offset orelse return &.{};
    const len = size orelse return Error.MalformedTable;
    const end = std.math.add(u64, start, len) catch return Error.MalformedTable;
    if (end > dynlib_data.len) return Error.MalformedTable;
    return dynlib_data[@intCast(start)..@intCast(end)];
}

/// Parses the dynamic tables of an image.
pub fn parse(gpa: std.mem.Allocator, image: elf.Image) (Error || std.mem.Allocator.Error)!DynamicInfo {
    const dynamic_bytes = (try image.dynamicData()) orelse return .{};
    const dynlib_data = (try image.dynlibData()) orelse &[_]u8{};

    if (dynamic_bytes.len % @sizeOf(Entry) != 0) return Error.MalformedTable;
    const entries = std.mem.bytesAsSlice(Entry, dynamic_bytes);

    const strings = try findStringTable(entries, dynlib_data);

    var info = DynamicInfo{};
    errdefer info.deinit(gpa);

    for (entries) |e| {
        const tag = e.dynamicTag();
        if (tag == .null) break;

        if (tag.isModuleInfo()) {
            info.module_info = try ModuleDecl.parse(e.value, strings);
        } else if (tag.isNeededModule()) {
            try info.needed_modules.append(gpa, try ModuleDecl.parse(e.value, strings));
        } else if (tag.isImportLib()) {
            try info.import_libraries.append(gpa, try LibraryDecl.parse(e.value, strings));
        } else if (tag.isExportLib()) {
            try info.export_libraries.append(gpa, try LibraryDecl.parse(e.value, strings));
        } else switch (tag) {
            .sce_strtab => info.strtab_offset = e.value,
            .sce_strsz => info.strtab_size = e.value,
            .sce_symtab => info.symtab_offset = e.value,
            .sce_symtabsz => info.symtab_size = e.value,
            .sce_jmprel => info.jmprel_offset = e.value,
            .sce_pltrelsz => info.jmprel_size = e.value,
            .sce_rela => info.rela_offset = e.value,
            .sce_relasz => info.rela_size = e.value,
            else => {},
        }
    }

    return info;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "symbol names split into identifier, library and module" {
    const parsed = try parseSymbolName("rTXw65xmLIA#A#A");
    try testing.expectEqualStrings("rTXw65xmLIA", parsed.id);
    try testing.expectEqualStrings("A", parsed.library);
    try testing.expectEqualStrings("A", parsed.module);

    const multi = try parseSymbolName("rTXw65xmLIA#BA#CDE");
    try testing.expectEqualStrings("BA", multi.library);
    try testing.expectEqualStrings("CDE", multi.module);
}

test "malformed symbol names are rejected rather than guessed at" {
    // A bare identifier would otherwise resolve against an arbitrary library.
    try testing.expectError(Error.MalformedSymbolName, parseSymbolName("rTXw65xmLIA"));
    try testing.expectError(Error.MalformedSymbolName, parseSymbolName("rTXw65xmLIA#A"));
    try testing.expectError(Error.MalformedSymbolName, parseSymbolName("#A#A"));
    try testing.expectError(Error.MalformedSymbolName, parseSymbolName("id##A"));
    // A code outside the alphabet.
    try testing.expectError(ids.DecodeError.BadCharacter, parseSymbolName("id#*#A"));
    // A code too long to be one.
    try testing.expectError(ids.DecodeError.BadLength, parseSymbolName("id#ABCD#A"));
}

/// Assembles a dynamic-data segment and a `PT_DYNAMIC` segment for tests.
const Fixture = struct {
    image: elf.TestImage,
    payload: std.ArrayList(u8),

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.image.deinit(gpa);
        self.payload.deinit(gpa);
    }
};

/// Builds an image whose dynamic entries and string table are laid out the way
/// a real module lays them out: entries in `PT_DYNAMIC`, strings in the
/// dynamic-data segment, referenced by offset within it.
fn buildFixture(
    gpa: std.mem.Allocator,
    entries: []const Entry,
    strings: []const u8,
) !Fixture {
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(gpa);

    // Dynamic-data segment first, then the dynamic entry array.
    try payload.appendSlice(gpa, strings);
    const dynamic_start = payload.items.len;
    for (entries) |e| {
        try payload.appendSlice(gpa, std.mem.asBytes(&e));
    }

    const base = elf.TestImage.payloadOffset(2);
    const segments = [_]elf.ProgramHeader{
        .{
            .type = @intFromEnum(elf.SegmentType.sce_dynlibdata),
            .flags = 0,
            .offset = base,
            .vaddr = 0,
            .paddr = 0,
            .filesz = strings.len,
            .memsz = strings.len,
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

/// Packs a library declaration the way the format does.
fn packLibrary(id: u16, version: u16, name_offset: u32) u64 {
    return (@as(u64, id) << 48) | (@as(u64, version) << 32) | name_offset;
}

/// Packs a module declaration: major and minor version occupy separate bytes.
fn packModule(id: u16, major: u8, minor: u8, name_offset: u32) u64 {
    return (@as(u64, id) << 48) |
        (@as(u64, major) << 40) |
        (@as(u64, minor) << 32) |
        name_offset;
}

test "declarations are unpacked with names resolved" {
    // Offsets into the string table below.
    //                0         1         2         3
    //                0123456789012345678901234567890
    const strings = "\x00libkernel\x00libSceGnmDriver\x00app\x00";
    const off_libkernel = 1;
    const off_gnm = 11;
    const off_app = 27;

    const entries = [_]Entry{
        .{ .tag = @intFromEnum(Tag.sce_strtab), .value = 0 },
        .{ .tag = @intFromEnum(Tag.sce_strsz), .value = strings.len },
        .{ .tag = @intFromEnum(Tag.sce_module_info), .value = packModule(0, 1, 1, off_app) },
        .{ .tag = @intFromEnum(Tag.sce_import_lib), .value = packLibrary(1, 1, off_libkernel) },
        .{ .tag = @intFromEnum(Tag.sce_import_lib), .value = packLibrary(0x40, 2, off_gnm) },
        .{ .tag = @intFromEnum(Tag.sce_needed_module), .value = packModule(2, 3, 4, off_libkernel) },
        .{ .tag = @intFromEnum(Tag.null), .value = 0 },
    };

    var fixture = try buildFixture(testing.allocator, &entries, strings);
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    const own = info.module_info orelse return error.TestExpectedModuleInfo;
    try testing.expectEqualStrings("app", own.name);
    try testing.expectEqualStrings("A", own.id.slice());

    try testing.expectEqual(@as(usize, 2), info.import_libraries.items.len);

    // Identifier 1 encodes as "B".
    const kernel = info.findImportLibrary("B") orelse return error.TestExpectedLibrary;
    try testing.expectEqualStrings("libkernel", kernel.name);
    try testing.expectEqual(@as(u16, 1), kernel.version);

    // Identifier 0x40 needs two characters, which is exactly the boundary case.
    const gnm = info.findImportLibrary("BA") orelse return error.TestExpectedLibrary;
    try testing.expectEqualStrings("libSceGnmDriver", gnm.name);
    try testing.expectEqual(@as(u16, 2), gnm.version);

    const needed = info.findModule("C") orelse return error.TestExpectedModule;
    try testing.expectEqualStrings("libkernel", needed.name);
    try testing.expectEqual(@as(u8, 3), needed.version_major);
    try testing.expectEqual(@as(u8, 4), needed.version_minor);
}

test "an import resolves to a named library through its code" {
    const strings = "\x00libkernel\x00";
    const entries = [_]Entry{
        .{ .tag = @intFromEnum(Tag.sce_strtab), .value = 0 },
        .{ .tag = @intFromEnum(Tag.sce_strsz), .value = strings.len },
        .{ .tag = @intFromEnum(Tag.sce_module_info), .value = packModule(0, 1, 1, 1) },
        .{ .tag = @intFromEnum(Tag.sce_import_lib), .value = packLibrary(0, 1, 1) },
        .{ .tag = @intFromEnum(Tag.null), .value = 0 },
    };

    var fixture = try buildFixture(testing.allocator, &entries, strings);
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    // This is the whole point of the format: a symbol name carries codes, and
    // only the module's own tables say what they mean.
    const sym = try parseSymbolName("rTXw65xmLIA#A#A");
    const lib = info.findImportLibrary(sym.library) orelse return error.TestExpectedLibrary;
    const mod = info.findModule(sym.module) orelse return error.TestExpectedModule;

    try testing.expectEqualStrings("libkernel", lib.name);
    try testing.expectEqualStrings("libkernel", mod.name);
    try testing.expectEqualStrings("rTXw65xmLIA", sym.id);
}

test "entries after the terminator are ignored" {
    const strings = "\x00early\x00late\x00";
    const entries = [_]Entry{
        .{ .tag = @intFromEnum(Tag.sce_strtab), .value = 0 },
        .{ .tag = @intFromEnum(Tag.sce_strsz), .value = strings.len },
        .{ .tag = @intFromEnum(Tag.sce_import_lib), .value = packLibrary(0, 1, 1) },
        .{ .tag = @intFromEnum(Tag.null), .value = 0 },
        .{ .tag = @intFromEnum(Tag.sce_import_lib), .value = packLibrary(1, 1, 7) },
    };

    var fixture = try buildFixture(testing.allocator, &entries, strings);
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    var info = try parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), info.import_libraries.items.len);
    try testing.expectEqualStrings("early", info.import_libraries.items[0].name);
}

test "a string table reaching past its segment is rejected" {
    const strings = "\x00libkernel\x00";
    const entries = [_]Entry{
        .{ .tag = @intFromEnum(Tag.sce_strtab), .value = 0 },
        // Larger than the segment actually holds.
        .{ .tag = @intFromEnum(Tag.sce_strsz), .value = 4096 },
        .{ .tag = @intFromEnum(Tag.null), .value = 0 },
    };

    var fixture = try buildFixture(testing.allocator, &entries, strings);
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    try testing.expectError(Error.MalformedTable, parse(testing.allocator, image));
}

test "an unterminated name is rejected" {
    // No trailing NUL, so the name runs off the end of the table.
    const strings = "\x00libkernel";
    const entries = [_]Entry{
        .{ .tag = @intFromEnum(Tag.sce_strtab), .value = 0 },
        .{ .tag = @intFromEnum(Tag.sce_strsz), .value = strings.len },
        .{ .tag = @intFromEnum(Tag.sce_import_lib), .value = packLibrary(0, 1, 1) },
        .{ .tag = @intFromEnum(Tag.null), .value = 0 },
    };

    var fixture = try buildFixture(testing.allocator, &entries, strings);
    defer fixture.deinit(testing.allocator);

    const image = try elf.parse(fixture.image.bytes());
    try testing.expectError(Error.BadStringOffset, parse(testing.allocator, image));
}

test "a module without dynamic tables parses as empty" {
    var img = try elf.TestImage.build(testing.allocator, .sce_dynamic, &.{}, "");
    defer img.deinit(testing.allocator);

    const image = try elf.parse(img.bytes());
    var info = try parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    try testing.expect(info.module_info == null);
    try testing.expectEqual(@as(usize, 0), info.import_libraries.items.len);
}
