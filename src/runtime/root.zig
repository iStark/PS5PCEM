// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Runtime composition for the memory, loader, and HLE modules.
//!
//! The lower layers remain independently useful. `Runtime` is the place where
//! they deliberately meet: it owns the one process-wide guest address space,
//! registers firmware exports, adapts the HLE database to the loader's resolver
//! interface, and returns fully mapped and relocated modules.

const std = @import("std");
const memory = @import("memory");
const loader = @import("loader");
const hle = @import("hle");

pub const Error = error{
    AlreadyInitialized,
    NotInitialized,
} || memory.Error || hle.symbols.Error || loader.elf.Error || loader.dynamic.Error ||
    loader.image_loader.Error || std.mem.Allocator.Error;

pub const Runtime = struct {
    allocator: ?std.mem.Allocator = null,
    address_space: ?memory.AddressSpace = null,
    database: hle.Database = .{},
    tls_registry: loader.TlsRegistry = .{},
    initialized: bool = false,

    /// Initializes a stable, caller-owned Runtime value.
    ///
    /// This is an in-place initializer because libkernel retains a pointer to
    /// `address_space`; returning Runtime by value could invalidate that pointer
    /// when the value is moved.
    pub fn init(self: *Runtime, allocator: std.mem.Allocator) Error!void {
        if (self.initialized or self.address_space != null) return Error.AlreadyInitialized;
        self.allocator = allocator;
        self.address_space = try memory.AddressSpace.initWithDirectMemory(
            allocator,
            hle.libs.kernel_memory.direct_memory_size,
        );
        errdefer {
            if (self.address_space) |*space| space.deinit();
            self.address_space = null;
            self.allocator = null;
        }

        hle.libs.kernel_memory.init(allocator);
        errdefer hle.libs.kernel_memory.deinit();
        if (self.address_space) |*space| hle.libs.kernel_memory.attachAddressSpace(space);
        errdefer hle.libs.kernel_memory.attachAddressSpace(null);

        try hle.registerAll(&self.database, allocator);
        self.initialized = true;
    }

    pub fn deinit(self: *Runtime) void {
        if (!self.initialized) return;
        const allocator = self.allocator.?;

        hle.libs.kernel_memory.attachAddressSpace(null);
        hle.libs.kernel_memory.deinit();
        self.database.deinit(allocator);
        self.database = .{};
        self.tls_registry.deinit(allocator);
        if (self.address_space) |*space| space.deinit();
        self.address_space = null;
        self.allocator = null;
        self.initialized = false;
    }

    /// Parses and loads one module through the complete runtime path.
    pub fn loadModule(
        self: *Runtime,
        image_bytes: []const u8,
        options: loader.LoadOptions,
    ) Error!loader.MappedImage {
        if (!self.initialized) return Error.NotInitialized;
        const allocator = self.allocator.?;
        const image = try loader.parseImage(image_bytes);
        var dynamic_info = try loader.parseDynamic(allocator, image);
        defer dynamic_info.deinit(allocator);

        var resolver_context = ResolverContext{
            .database = &self.database,
            .tls_registry = &self.tls_registry,
        };
        const resolver = loader.Resolver{
            .context = &resolver_context,
            .resolve_fn = resolveImport,
            .resolve_tls_fn = resolveTlsImport,
        };
        var load_options = options;
        load_options.tls_registry = &self.tls_registry;
        return loader.loadImage(
            allocator,
            &self.address_space.?,
            image,
            &dynamic_info,
            resolver,
            load_options,
        );
    }
};

const ResolverContext = struct {
    database: *const hle.Database,
    tls_registry: *loader.TlsRegistry,
};

fn resolveImport(raw_context: ?*anyopaque, import: *const loader.Import) ?u64 {
    const raw = raw_context orelse return null;
    const context: *ResolverContext = @ptrCast(@alignCast(raw));
    const symbol_type = toHleSymbolType(import.symbol_type);

    if (import.id.len == hle.nid.encoded_len and
        import.library != null and import.library_version != null and import.module != null)
    {
        var id: hle.nid.Encoded = undefined;
        @memcpy(&id, import.id);
        const key = hle.symbols.Key{
            .id = id,
            .library = .{
                .name = import.library.?,
                .version = @intCast(import.library_version.?),
            },
            .module = .{ .name = import.module.? },
            .type = symbol_type,
        };
        if (context.database.find(key)) |symbol| return symbol.address;
    }

    const symbol = context.database.findById(import.id, symbol_type) orelse return null;
    return symbol.address;
}

fn resolveTlsImport(
    raw_context: ?*anyopaque,
    import: *const loader.Import,
) ?loader.TlsResolvedSymbol {
    const raw = raw_context orelse return null;
    const context: *ResolverContext = @ptrCast(@alignCast(raw));
    return context.tls_registry.resolve(import);
}

fn toHleSymbolType(symbol_type: loader.symbols.Type) hle.SymbolType {
    return switch (symbol_type) {
        .func => .function,
        .object => .object,
        .tls => .tls_module,
        else => .no_type,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "runtime owns one address space and loads a fixed module" {
    const payload = "runtime image";
    const offset = loader.elf.TestImage.payloadOffset(1);
    const segments = [_]loader.ProgramHeader{.{
        .type = @intFromEnum(loader.SegmentType.load),
        .flags = 0x4,
        .offset = offset,
        .vaddr = 0,
        .paddr = 0,
        .filesz = payload.len,
        .memsz = memory.page_size,
        .@"align" = memory.page_size,
    }};
    var fixture = try loader.elf.TestImage.build(
        testing.allocator,
        .sce_dynexec,
        &segments,
        payload,
    );
    defer fixture.deinit(testing.allocator);

    var runtime = Runtime{};
    try runtime.init(testing.allocator);
    defer runtime.deinit();

    var mapped = try runtime.loadModule(
        fixture.bytes(),
        .{ .load_bias = memory.system_managed.start },
    );
    defer mapped.deinit();

    var output: [payload.len]u8 = undefined;
    try runtime.address_space.?.read(memory.system_managed.start, &output);
    try testing.expectEqualStrings(payload, &output);
    try testing.expect(runtime.database.count() != 0);
}

test "runtime registers PT_TLS and unregisters it with the mapped image" {
    const payload = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const offset = loader.elf.TestImage.payloadOffset(2);
    const segments = [_]loader.ProgramHeader{
        .{
            .type = @intFromEnum(loader.SegmentType.load),
            .flags = 0x6,
            .offset = offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = payload.len,
            .memsz = memory.page_size,
            .@"align" = memory.page_size,
        },
        .{
            .type = @intFromEnum(loader.SegmentType.tls),
            .flags = 0x4,
            .offset = offset,
            .vaddr = 0,
            .paddr = 0,
            .filesz = payload.len,
            .memsz = 0x20,
            .@"align" = 0x10,
        },
    };
    var fixture = try loader.elf.TestImage.build(
        testing.allocator,
        .sce_dynexec,
        &segments,
        &payload,
    );
    defer fixture.deinit(testing.allocator);

    var runtime = Runtime{};
    try runtime.init(testing.allocator);
    defer runtime.deinit();
    var mapped = try runtime.loadModule(
        fixture.bytes(),
        .{ .load_bias = memory.system_managed.start },
    );

    const tls_module = mapped.tls_module orelse return error.TestExpectedTlsModule;
    try testing.expectEqual(@as(u64, 1), tls_module.id);
    try testing.expectEqual(@as(u64, 0x20), tls_module.static_offset);
    try testing.expectEqual(@as(usize, 1), runtime.tls_registry.count());

    try mapped.unload();
    try testing.expectEqual(@as(usize, 0), runtime.tls_registry.count());
}
