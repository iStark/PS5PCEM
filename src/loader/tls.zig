// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Process-wide registry of ELF `PT_TLS` templates.
//!
//! AMD64 uses TLS Variant II: every startup module owns an aligned block below
//! the thread pointer. Relocations need the module identifier, the symbol's
//! offset inside that block, and the block's negative thread-pointer offset.
//! Actual per-thread allocation belongs to the threading layer; this registry
//! deliberately owns only the immutable templates and layout metadata it will
//! consume.

const std = @import("std");
const elf = @import("elf.zig");
const dynamic = @import("dynamic.zig");
const symbols = @import("symbols.zig");
const imports = @import("imports.zig");

pub const Error = error{
    InvalidSegment,
    MalformedTable,
    AddressOverflow,
    ModuleIdExhausted,
    BufferTooSmall,
} || elf.Error || symbols.Error || std.mem.Allocator.Error;

const Lock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Lock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Lock) void {
        self.inner.unlock();
    }
};

/// Stable relocation data for one registered module.
pub const Module = struct {
    id: u64,
    memory_size: u64,
    alignment: u64,
    alignment_bias: u64,
    /// Positive distance from the thread pointer to the start of this block.
    static_offset: u64,
};

/// One TLS symbol supplied by a registered guest module.
pub const ResolvedSymbol = struct {
    module: Module,
    offset: u64,
};

pub const Export = struct {
    id: []const u8,
    library: []const u8,
    library_version: u16,
    module: []const u8,
    offset: u64,
};

pub const Template = struct {
    initial_image: []const u8,
    memory_size: u64,
    alignment: u64,
    alignment_bias: u64 = 0,
    exports: []const Export = &.{},
};

/// Immutable copy of one registered template used while constructing a
/// thread's TLS block. The registry lock is held while the complete snapshot is
/// cloned, so module metadata and initialized bytes always describe the same
/// process generation.
pub const SnapshotModule = struct {
    info: Module,
    initial_image: []u8,
};

pub const Snapshot = struct {
    generation: u64,
    static_size: u64,
    maximum_alignment: u64,
    maximum_module_id: u64,
    modules: []SnapshotModule,

    pub fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        for (self.modules) |module| gpa.free(module.initial_image);
        gpa.free(self.modules);
        self.* = undefined;
    }
};

const OwnedExport = struct {
    id: []u8,
    library: []u8,
    library_version: u16,
    module: []u8,
    offset: u64,

    fn init(gpa: std.mem.Allocator, source: Export) std.mem.Allocator.Error!OwnedExport {
        const id = try gpa.dupe(u8, source.id);
        errdefer gpa.free(id);
        const library = try gpa.dupe(u8, source.library);
        errdefer gpa.free(library);
        const module = try gpa.dupe(u8, source.module);
        return .{
            .id = id,
            .library = library,
            .library_version = source.library_version,
            .module = module,
            .offset = source.offset,
        };
    }

    fn deinit(self: *OwnedExport, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.library);
        gpa.free(self.module);
    }
};

const RegisteredModule = struct {
    info: Module,
    initial_image: []u8,
    exports: std.ArrayList(OwnedExport) = .empty,

    fn deinit(self: *RegisteredModule, gpa: std.mem.Allocator) void {
        gpa.free(self.initial_image);
        for (self.exports.items) |*symbol| symbol.deinit(gpa);
        self.exports.deinit(gpa);
    }
};

pub const Registry = struct {
    modules: std.ArrayList(RegisteredModule) = .empty,
    next_id: u64 = 1,
    static_size: u64 = 0,
    generation: u64 = 1,
    lock: Lock = .{},

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.modules.items) |*module| module.deinit(gpa);
        self.modules.deinit(gpa);
        self.modules = .empty;
        self.next_id = 1;
        self.static_size = 0;
        self.generation = 1;
    }

    /// Registers an immutable TLS template and assigns the next module ID.
    pub fn register(
        self: *Registry,
        gpa: std.mem.Allocator,
        template: Template,
    ) Error!Module {
        if (template.memory_size == 0 or template.initial_image.len > template.memory_size) {
            return Error.InvalidSegment;
        }
        const alignment = if (template.alignment == 0) 1 else template.alignment;
        if (!std.math.isPowerOfTwo(alignment)) return Error.InvalidSegment;

        self.lock.lock();
        defer self.lock.unlock();
        if (self.next_id == 0) return Error.ModuleIdExhausted;

        const static_offset = try calculateStaticOffset(
            self.static_size,
            template.memory_size,
            alignment,
            template.alignment_bias,
        );
        const module = Module{
            .id = self.next_id,
            .memory_size = template.memory_size,
            .alignment = alignment,
            .alignment_bias = template.alignment_bias & (alignment - 1),
            .static_offset = static_offset,
        };

        var registered = RegisteredModule{
            .info = module,
            .initial_image = try gpa.dupe(u8, template.initial_image),
        };
        errdefer registered.deinit(gpa);
        try registered.exports.ensureTotalCapacity(gpa, template.exports.len);
        for (template.exports) |symbol| {
            if (symbol.offset >= template.memory_size) return Error.InvalidSegment;
            registered.exports.appendAssumeCapacity(try OwnedExport.init(gpa, symbol));
        }
        try self.modules.append(gpa, registered);

        self.static_size = static_offset;
        self.next_id = if (module.id == std.math.maxInt(u64)) 0 else module.id + 1;
        self.advanceGeneration();
        return module;
    }

    /// Extracts `PT_TLS` and defined TLS exports from one parsed image.
    pub fn registerImage(
        self: *Registry,
        gpa: std.mem.Allocator,
        image: elf.Image,
        info: *const dynamic.DynamicInfo,
    ) Error!?Module {
        const header = image.findSegment(.tls) orelse return null;
        if (header.memsz == 0) return null;
        if (header.filesz > header.memsz) return Error.InvalidSegment;
        const alignment = if (header.@"align" == 0) 1 else header.@"align";
        if (!std.math.isPowerOfTwo(alignment)) return Error.InvalidSegment;
        const initial_image = try image.fileRange(header);

        var exports: std.ArrayList(Export) = .empty;
        defer exports.deinit(gpa);
        try collectExports(gpa, &exports, image, info, header.memsz);
        return try self.register(gpa, .{
            .initial_image = initial_image,
            .memory_size = header.memsz,
            .alignment = alignment,
            .alignment_bias = header.vaddr,
            .exports = exports.items,
        });
    }

    /// Removes a module template without renumbering or repacking survivors.
    /// Stable offsets are required by relocations already written to memory.
    pub fn unregister(self: *Registry, gpa: std.mem.Allocator, id: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.modules.items, 0..) |module, index| {
            if (module.info.id != id) continue;
            var removed = self.modules.orderedRemove(index);
            removed.deinit(gpa);
            self.advanceGeneration();
            return;
        }
    }

    pub fn findModule(self: *Registry, id: u64) ?Module {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.modules.items) |module_entry| {
            if (module_entry.info.id == id) return module_entry.info;
        }
        return null;
    }

    pub fn count(self: *Registry) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.modules.items.len;
    }

    pub fn staticTlsSize(self: *Registry) u64 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.static_size;
    }

    /// Clones the complete process TLS layout for one thread bootstrap.
    /// Loading or unloading a module after this call affects future threads,
    /// never a partially initialized block already being constructed.
    pub fn snapshot(self: *Registry, gpa: std.mem.Allocator) Error!Snapshot {
        self.lock.lock();
        defer self.lock.unlock();

        const cloned = try gpa.alloc(SnapshotModule, self.modules.items.len);
        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |module| gpa.free(module.initial_image);
            gpa.free(cloned);
        }

        var maximum_alignment: u64 = 1;
        var maximum_module_id: u64 = 0;
        for (self.modules.items, cloned) |source, *destination| {
            destination.* = .{
                .info = source.info,
                .initial_image = try gpa.dupe(u8, source.initial_image),
            };
            initialized += 1;
            maximum_alignment = @max(maximum_alignment, source.info.alignment);
            maximum_module_id = @max(maximum_module_id, source.info.id);
        }

        return .{
            .generation = self.generation,
            .static_size = self.static_size,
            .maximum_alignment = maximum_alignment,
            .maximum_module_id = maximum_module_id,
            .modules = cloned,
        };
    }

    /// Copies the initialized `tdata` bytes for a future per-thread block.
    /// The threading layer zero-fills `Module.memory_size` first, then overlays
    /// these bytes; the remaining tail is the ELF `tbss` region.
    pub fn copyInitialImage(
        self: *Registry,
        id: u64,
        destination: []u8,
    ) Error!?usize {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.modules.items) |module_entry| {
            if (module_entry.info.id != id) continue;
            if (destination.len < module_entry.initial_image.len) return Error.BufferTooSmall;
            @memcpy(
                destination[0..module_entry.initial_image.len],
                module_entry.initial_image,
            );
            return module_entry.initial_image.len;
        }
        return null;
    }

    /// Resolves an imported TLS symbol against modules loaded earlier.
    pub fn resolve(self: *Registry, import: *const imports.Import) ?ResolvedSymbol {
        if (import.symbol_type != .tls) return null;
        self.lock.lock();
        defer self.lock.unlock();

        for (self.modules.items) |module_entry| {
            for (module_entry.exports.items) |symbol| {
                if (!std.mem.eql(u8, symbol.id, import.id)) continue;
                if (import.library) |library| {
                    if (!std.mem.eql(u8, symbol.library, library)) continue;
                }
                if (import.library_version) |version| {
                    if (symbol.library_version != version) continue;
                }
                if (import.module) |module_name| {
                    if (!std.mem.eql(u8, symbol.module, module_name)) continue;
                }
                return .{ .module = module_entry.info, .offset = symbol.offset };
            }
        }
        return null;
    }

    fn advanceGeneration(self: *Registry) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
};

fn collectExports(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Export),
    image: elf.Image,
    info: *const dynamic.DynamicInfo,
    tls_size: u64,
) Error!void {
    if (info.symtab_offset == null and info.symtab_size == null) return;
    const symbol_bytes = try info.tableData(image, info.symtab_offset, info.symtab_size);
    const symbol_table = try symbols.Table.init(symbol_bytes);
    const strings = try info.tableData(image, info.strtab_offset, info.strtab_size);

    for (symbol_table.entries) |symbol| {
        if (!symbol.isDefined() or symbol.symbolType() != .tls or symbol.name == 0) continue;
        if (symbol.value >= tls_size) return Error.InvalidSegment;
        const raw_name = try readString(strings, symbol.name);
        const parsed = dynamic.parseSymbolName(raw_name) catch continue;
        const library = info.findExportLibrary(parsed.library) orelse continue;
        const module = info.module_info orelse continue;
        if (!module.id.eql(parsed.module)) continue;
        try out.append(gpa, .{
            .id = parsed.id,
            .library = library.name,
            .library_version = library.version,
            .module = module.name,
            .offset = symbol.value,
        });
    }
}

fn readString(strings: []const u8, offset: u32) Error![]const u8 {
    if (offset >= strings.len) return Error.MalformedTable;
    const rest = strings[offset..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse return Error.MalformedTable;
    return rest[0..end];
}

fn calculateStaticOffset(
    previous_offset: u64,
    size: u64,
    alignment: u64,
    alignment_bias: u64,
) Error!u64 {
    const after_size = std.math.add(u64, previous_offset, size) catch
        return Error.AddressOverflow;
    const upper = std.math.add(u64, after_size, alignment - 1) catch
        return Error.AddressOverflow;
    const biased = std.math.add(u64, upper, alignment_bias & (alignment - 1)) catch
        return Error.AddressOverflow;
    return upper - (biased & (alignment - 1));
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "Variant II layout preserves size and PT_TLS alignment bias" {
    var registry = Registry{};
    defer registry.deinit(testing.allocator);

    const first = try registry.register(testing.allocator, .{
        .initial_image = &.{ 0x11, 0x22 },
        .memory_size = 0x20,
        .alignment = 0x10,
    });
    const second = try registry.register(testing.allocator, .{
        .initial_image = &.{0x7a},
        .memory_size = 0x18,
        .alignment = 0x20,
        .alignment_bias = 8,
    });

    try testing.expectEqual(@as(u64, 1), first.id);
    try testing.expectEqual(@as(u64, 0x20), first.static_offset);
    try testing.expectEqual(@as(u64, 2), second.id);
    try testing.expect(second.static_offset >= first.static_offset + second.memory_size);
    try testing.expectEqual(@as(u64, 8), (0 -% second.static_offset) & 0x1f);
    try testing.expectEqual(second.static_offset, registry.staticTlsSize());
    var initial_image: [2]u8 = undefined;
    try testing.expectEqual(
        @as(?usize, 2),
        try registry.copyInitialImage(first.id, &initial_image),
    );
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22 }, &initial_image);
}

test "snapshot owns one coherent TLS registry generation" {
    var registry = Registry{};
    defer registry.deinit(testing.allocator);

    const first = try registry.register(testing.allocator, .{
        .initial_image = &.{ 0x31, 0x32 },
        .memory_size = 0x20,
        .alignment = 0x10,
    });
    var snapshot = try registry.snapshot(testing.allocator);
    defer snapshot.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), snapshot.modules.len);
    try testing.expectEqual(first, snapshot.modules[0].info);
    try testing.expectEqualSlices(u8, &.{ 0x31, 0x32 }, snapshot.modules[0].initial_image);
    try testing.expectEqual(first.static_offset, snapshot.static_size);
    try testing.expectEqual(@as(u64, 0x10), snapshot.maximum_alignment);
    try testing.expectEqual(first.id, snapshot.maximum_module_id);

    _ = try registry.register(testing.allocator, .{
        .initial_image = &.{0x44},
        .memory_size = 0x10,
        .alignment = 8,
    });
    try testing.expectEqual(@as(usize, 1), snapshot.modules.len);
}

test "TLS exports resolve with exact library and module metadata" {
    var registry = Registry{};
    defer registry.deinit(testing.allocator);
    const module = try registry.register(testing.allocator, .{
        .initial_image = &.{0xaa},
        .memory_size = 0x40,
        .alignment = 0x10,
        .exports = &.{.{
            .id = "tls-symbol",
            .library = "libtls",
            .library_version = 2,
            .module = "tlsmod",
            .offset = 0x18,
        }},
    });
    const import = imports.Import{
        .id = "tls-symbol",
        .library = "libtls",
        .library_version = 2,
        .module = "tlsmod",
        .library_code = "A",
        .module_code = "A",
        .symbol_type = .tls,
        .relocation_type = .dtpoff64,
        .table = .general,
        .target_offset = 0,
        .addend = 0,
    };

    const resolved = registry.resolve(&import) orelse return error.TestExpectedTlsSymbol;
    try testing.expectEqual(module.id, resolved.module.id);
    try testing.expectEqual(@as(u64, 0x18), resolved.offset);

    registry.unregister(testing.allocator, module.id);
    try testing.expectEqual(@as(usize, 0), registry.count());
    try testing.expect(registry.resolve(&import) == null);
}

test "PT_TLS registration collects exports from vendor dynamic tables" {
    const strings = "\x00tls-symbol#A#A\x00libtls\x00tlsmod\x00";
    const library_name_offset = std.mem.indexOf(u8, strings, "libtls").?;
    const module_name_offset = std.mem.indexOf(u8, strings, "tlsmod").?;
    const symbol_entries = [_]symbols.Sym{
        std.mem.zeroes(symbols.Sym),
        .{
            .name = 1,
            .info = 0x16,
            .other = 0,
            .shndx = 1,
            .value = 0x10,
            .size = 8,
        },
    };

    var dynlib_data: std.ArrayList(u8) = .empty;
    defer dynlib_data.deinit(testing.allocator);
    try dynlib_data.appendSlice(testing.allocator, strings);
    const symbol_table_offset = dynlib_data.items.len;
    try dynlib_data.appendSlice(testing.allocator, std.mem.sliceAsBytes(&symbol_entries));

    const entries = [_]dynamic.Entry{
        .{ .tag = @intFromEnum(dynamic.Tag.sce_strtab), .value = 0 },
        .{ .tag = @intFromEnum(dynamic.Tag.sce_strsz), .value = strings.len },
        .{ .tag = @intFromEnum(dynamic.Tag.sce_symtab), .value = symbol_table_offset },
        .{ .tag = @intFromEnum(dynamic.Tag.sce_symtabsz), .value = @sizeOf(@TypeOf(symbol_entries)) },
        .{
            .tag = @intFromEnum(dynamic.Tag.sce_module_info),
            .value = (@as(u64, 1) << 40) | @as(u64, @intCast(module_name_offset)),
        },
        .{
            .tag = @intFromEnum(dynamic.Tag.sce_export_lib),
            .value = (@as(u64, 2) << 32) | @as(u64, @intCast(library_name_offset)),
        },
        .{ .tag = @intFromEnum(dynamic.Tag.null), .value = 0 },
    };

    const tls_initial = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, &tls_initial);
    const dynlib_payload_offset = payload.items.len;
    try payload.appendSlice(testing.allocator, dynlib_data.items);
    const dynamic_payload_offset = payload.items.len;
    try payload.appendSlice(testing.allocator, std.mem.sliceAsBytes(&entries));

    const payload_offset = elf.TestImage.payloadOffset(3);
    const segments = [_]elf.ProgramHeader{
        .{
            .type = @intFromEnum(elf.SegmentType.tls),
            .flags = 0x4,
            .offset = payload_offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = tls_initial.len,
            .memsz = 0x40,
            .@"align" = 0x10,
        },
        .{
            .type = @intFromEnum(elf.SegmentType.sce_dynlibdata),
            .flags = 0,
            .offset = payload_offset + dynlib_payload_offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = dynlib_data.items.len,
            .memsz = dynlib_data.items.len,
            .@"align" = 8,
        },
        .{
            .type = @intFromEnum(elf.SegmentType.dynamic),
            .flags = 0,
            .offset = payload_offset + dynamic_payload_offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = @sizeOf(@TypeOf(entries)),
            .memsz = @sizeOf(@TypeOf(entries)),
            .@"align" = 8,
        },
    };
    var fixture = try elf.TestImage.build(testing.allocator, .sce_dynamic, &segments, payload.items);
    defer fixture.deinit(testing.allocator);
    const image = try elf.parse(fixture.bytes());
    var info = try dynamic.parse(testing.allocator, image);
    defer info.deinit(testing.allocator);

    var registry = Registry{};
    defer registry.deinit(testing.allocator);
    const registered = (try registry.registerImage(testing.allocator, image, &info)) orelse
        return error.TestExpectedTlsModule;
    const import = imports.Import{
        .id = "tls-symbol",
        .library = "libtls",
        .library_version = 2,
        .module = "tlsmod",
        .library_code = "A",
        .module_code = "A",
        .symbol_type = .tls,
        .relocation_type = .dtpoff64,
        .table = .general,
        .target_offset = 0,
        .addend = 0,
    };
    const resolved = registry.resolve(&import) orelse return error.TestExpectedTlsSymbol;
    try testing.expectEqual(registered.id, resolved.module.id);
    try testing.expectEqual(@as(u64, 0x10), resolved.offset);
}
