// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Process-wide registry of symbols exported by mapped guest modules.
//!
//! A PS5 import is identified by its NID together with library and module
//! metadata.  The registry owns copies of that metadata so parsed SELF buffers
//! may be released independently of the mapped image.

const std = @import("std");
const elf = @import("elf.zig");
const dynamic = @import("dynamic.zig");
const symbols = @import("symbols.zig");
const imports = @import("imports.zig");

pub const Error = error{
    MalformedTable,
    AddressOverflow,
    ModuleIdExhausted,
} || elf.Error || dynamic.Error || symbols.Error || std.mem.Allocator.Error;

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

/// Stable handle used to remove every export owned by one mapped image.
pub const Module = struct {
    id: u64,
    export_count: usize,
};

/// One guest symbol before the registry takes ownership of its metadata.
pub const Export = struct {
    id: []const u8,
    library: []const u8,
    library_version: u16,
    module: []const u8,
    symbol_type: symbols.Type,
    address: u64,
};

const OwnedExport = struct {
    id: []u8,
    library: []u8,
    library_version: u16,
    module: []u8,
    symbol_type: symbols.Type,
    address: u64,

    fn init(gpa: std.mem.Allocator, source: Export) std.mem.Allocator.Error!OwnedExport {
        const id = try gpa.dupe(u8, source.id);
        errdefer gpa.free(id);
        const library = try gpa.dupe(u8, source.library);
        errdefer gpa.free(library);
        const module_name = try gpa.dupe(u8, source.module);
        return .{
            .id = id,
            .library = library,
            .library_version = source.library_version,
            .module = module_name,
            .symbol_type = source.symbol_type,
            .address = source.address,
        };
    }

    fn deinit(self: *OwnedExport, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.library);
        gpa.free(self.module);
    }
};

const RegisteredModule = struct {
    id: u64,
    exports: std.ArrayList(OwnedExport) = .empty,

    fn deinit(self: *RegisteredModule, gpa: std.mem.Allocator) void {
        for (self.exports.items) |*symbol| symbol.deinit(gpa);
        self.exports.deinit(gpa);
    }
};

pub const Registry = struct {
    modules: std.ArrayList(RegisteredModule) = .empty,
    next_id: u64 = 1,
    lock: Lock = .{},

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.modules.items) |*module| module.deinit(gpa);
        self.modules.deinit(gpa);
        self.modules = .empty;
        self.next_id = 1;
    }

    pub fn register(
        self: *Registry,
        gpa: std.mem.Allocator,
        module_exports: []const Export,
    ) Error!Module {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.next_id == 0) return Error.ModuleIdExhausted;

        const module = Module{ .id = self.next_id, .export_count = module_exports.len };
        var registered = RegisteredModule{ .id = module.id };
        errdefer registered.deinit(gpa);
        try registered.exports.ensureTotalCapacity(gpa, module_exports.len);
        for (module_exports) |symbol| {
            registered.exports.appendAssumeCapacity(try OwnedExport.init(gpa, symbol));
        }
        try self.modules.append(gpa, registered);
        self.next_id = if (module.id == std.math.maxInt(u64)) 0 else module.id + 1;
        return module;
    }

    /// Collects all global or weak defined symbols from one parsed image.
    pub fn registerImage(
        self: *Registry,
        gpa: std.mem.Allocator,
        image: elf.Image,
        info: *const dynamic.DynamicInfo,
        load_bias: u64,
    ) Error!?Module {
        var collected: std.ArrayList(Export) = .empty;
        defer collected.deinit(gpa);
        try collect(gpa, &collected, image, info, load_bias);
        if (collected.items.len == 0) return null;
        return try self.register(gpa, collected.items);
    }

    pub fn unregister(self: *Registry, gpa: std.mem.Allocator, id: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.modules.items, 0..) |module, index| {
            if (module.id != id) continue;
            var removed = self.modules.orderedRemove(index);
            removed.deinit(gpa);
            return;
        }
    }

    /// Resolves with complete library/module metadata first.
    pub fn resolveExact(self: *Registry, import: *const imports.Import) ?u64 {
        const library = import.library orelse return null;
        const version = import.library_version orelse return null;
        const module_name = import.module orelse return null;
        self.lock.lock();
        defer self.lock.unlock();

        for (self.modules.items) |module| {
            for (module.exports.items) |symbol| {
                if (symbol.symbol_type != import.symbol_type or
                    !std.mem.eql(u8, symbol.id, import.id) or
                    !std.mem.eql(u8, symbol.library, library) or
                    symbol.library_version != version or
                    !std.mem.eql(u8, symbol.module, module_name)) continue;
                return symbol.address;
            }
        }
        return null;
    }

    /// Identifier-only fallback for images with incomplete declarations.
    pub fn resolveById(self: *Registry, import: *const imports.Import) ?u64 {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.modules.items) |module| {
            for (module.exports.items) |symbol| {
                if (symbol.symbol_type == import.symbol_type and
                    std.mem.eql(u8, symbol.id, import.id)) return symbol.address;
            }
        }
        return null;
    }

    pub fn moduleCount(self: *Registry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.modules.items.len;
    }

    pub fn symbolCount(self: *Registry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        var count: usize = 0;
        for (self.modules.items) |module| count += module.exports.items.len;
        return count;
    }
};

pub fn collect(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Export),
    image: elf.Image,
    info: *const dynamic.DynamicInfo,
    load_bias: u64,
) Error!void {
    if (info.symtab_offset == null and info.symtab_size == null) return;
    const symbol_bytes = try info.tableData(image, info.symtab_offset, info.symtab_size);
    const symbol_table = try symbols.Table.init(symbol_bytes);
    const strings = try info.tableData(image, info.strtab_offset, info.strtab_size);

    for (symbol_table.entries) |symbol| {
        if (!symbol.isDefined() or symbol.name == 0) continue;
        if (symbol.binding() != .global and symbol.binding() != .weak) continue;
        switch (symbol.symbolType()) {
            .no_type, .object, .func => {},
            else => continue,
        }

        const raw_name = try readString(strings, symbol.name);
        const parsed = dynamic.parseSymbolName(raw_name) catch continue;
        const library = info.findExportLibrary(parsed.library) orelse continue;
        const module = info.findModule(parsed.module) orelse continue;
        const address = std.math.add(u64, load_bias, symbol.value) catch
            return Error.AddressOverflow;
        try out.append(gpa, .{
            .id = parsed.id,
            .library = library.name,
            .library_version = library.version,
            .module = module.name,
            .symbol_type = symbol.symbolType(),
            .address = address,
        });
    }
}

fn readString(strings: []const u8, offset: u32) Error![]const u8 {
    if (offset >= strings.len) return dynamic.Error.BadStringOffset;
    const rest = strings[offset..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse
        return dynamic.Error.BadStringOffset;
    return rest[0..end];
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "guest exports resolve exactly and unregister as one module" {
    var registry = Registry{};
    defer registry.deinit(testing.allocator);
    const module = try registry.register(testing.allocator, &.{.{
        .id = "test-nid",
        .library = "libc",
        .library_version = 1,
        .module = "libc",
        .symbol_type = .func,
        .address = 0x1234_5678,
    }});

    const import = imports.Import{
        .id = "test-nid",
        .library = "libc",
        .library_version = 1,
        .module = "libc",
        .library_code = "A",
        .module_code = "A",
        .symbol_type = .func,
        .relocation_type = .jump_slot,
        .table = .plt,
        .target_offset = 0,
        .addend = 0,
    };
    try testing.expectEqual(@as(?u64, 0x1234_5678), registry.resolveExact(&import));
    try testing.expectEqual(@as(usize, 1), registry.symbolCount());

    registry.unregister(testing.allocator, module.id);
    try testing.expectEqual(@as(usize, 0), registry.moduleCount());
    try testing.expect(registry.resolveById(&import) == null);
}

test "identifier fallback still checks the ELF symbol type" {
    var registry = Registry{};
    defer registry.deinit(testing.allocator);
    _ = try registry.register(testing.allocator, &.{.{
        .id = "same-nid",
        .library = "libA",
        .library_version = 1,
        .module = "modA",
        .symbol_type = .object,
        .address = 0x9000,
    }});
    var import = imports.Import{
        .id = "same-nid",
        .library = null,
        .library_version = null,
        .module = null,
        .library_code = "A",
        .module_code = "A",
        .symbol_type = .func,
        .relocation_type = .glob_dat,
        .table = .general,
        .target_offset = 0,
        .addend = 0,
    };
    try testing.expect(registry.resolveById(&import) == null);
    import.symbol_type = .object;
    try testing.expectEqual(@as(?u64, 0x9000), registry.resolveById(&import));
}

test "defined dynamic symbols are collected with PS5 export metadata" {
    const strings = "\x00guest-nid#A#A\x00libc\x00libc\x00";
    const off_library = 15;
    const off_module = 20;
    const symbol_entries = [_]symbols.Sym{
        std.mem.zeroes(symbols.Sym),
        .{
            .name = 1,
            .info = (1 << 4) | 2,
            .other = 0,
            .shndx = 1,
            .value = 0x80,
            .size = 4,
        },
    };

    var dynlib: std.ArrayList(u8) = .empty;
    defer dynlib.deinit(testing.allocator);
    try dynlib.appendSlice(testing.allocator, strings);
    const symtab_offset = dynlib.items.len;
    try dynlib.appendSlice(testing.allocator, std.mem.sliceAsBytes(&symbol_entries));

    const dynamic_entries = [_]dynamic.Entry{
        .{ .tag = @intFromEnum(dynamic.Tag.sce_strtab), .value = 0 },
        .{ .tag = @intFromEnum(dynamic.Tag.sce_strsz), .value = strings.len },
        .{ .tag = @intFromEnum(dynamic.Tag.sce_symtab), .value = symtab_offset },
        .{
            .tag = @intFromEnum(dynamic.Tag.sce_symtabsz),
            .value = @sizeOf(@TypeOf(symbol_entries)),
        },
        .{
            .tag = @intFromEnum(dynamic.Tag.sce_module_info),
            .value = (@as(u64, 1) << 40) | (@as(u64, 1) << 32) | off_module,
        },
        .{
            .tag = @intFromEnum(dynamic.Tag.sce_export_lib),
            .value = (@as(u64, 1) << 32) | off_library,
        },
        .{ .tag = 0, .value = 0 },
    };
    const dynamic_bytes = std.mem.sliceAsBytes(&dynamic_entries);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, dynamic_bytes);
    const dynlib_offset = payload.items.len;
    try payload.appendSlice(testing.allocator, dynlib.items);

    const file_offset = elf.TestImage.payloadOffset(2);
    const headers = [_]elf.ProgramHeader{
        .{
            .type = @intFromEnum(elf.SegmentType.dynamic),
            .flags = 0x4,
            .offset = file_offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = dynamic_bytes.len,
            .memsz = dynamic_bytes.len,
            .@"align" = 8,
        },
        .{
            .type = @intFromEnum(elf.SegmentType.sce_dynlibdata),
            .flags = 0x4,
            .offset = file_offset + dynlib_offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = dynlib.items.len,
            .memsz = dynlib.items.len,
            .@"align" = 1,
        },
    };
    var fixture = try elf.TestImage.build(
        testing.allocator,
        .sce_dynamic,
        &headers,
        payload.items,
    );
    defer fixture.deinit(testing.allocator);
    const image = try elf.parse(fixture.bytes());
    var info = try dynamic.parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    var registry = Registry{};
    defer registry.deinit(testing.allocator);
    const module = (try registry.registerImage(
        testing.allocator,
        image,
        &info,
        0x1000,
    )).?;
    try testing.expectEqual(@as(usize, 1), module.export_count);

    const import = imports.Import{
        .id = "guest-nid",
        .library = "libc",
        .library_version = 1,
        .module = "libc",
        .library_code = "A",
        .module_code = "A",
        .symbol_type = .func,
        .relocation_type = .jump_slot,
        .table = .plt,
        .target_offset = 0,
        .addend = 0,
    };
    try testing.expectEqual(@as(?u64, 0x1080), registry.resolveExact(&import));
}
