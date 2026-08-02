// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Applies x86-64 RELA records to a mapped guest module.
//!
//! Import discovery remains a read-only operation in `imports.zig`. This file is
//! the action side of the boundary: it computes load-bias relocations, resolves
//! undefined symbols through a caller-supplied resolver, and writes results into
//! an identity-mapped guest address space.

const std = @import("std");
const memory = @import("memory");
const elf = @import("elf.zig");
const dynamic = @import("dynamic.zig");
const symbols = @import("symbols.zig");
const relocations = @import("relocations.zig");
const imports = @import("imports.zig");
const tls = @import("tls.zig");

pub const Error = error{
    MalformedTable,
    AddressOverflow,
    UnsupportedRelocation,
    UnresolvedImport,
    RelocationTargetUnavailable,
    TlsModuleUnavailable,
    InvalidTlsSymbol,
    InvalidTlsOffset,
} || elf.Error || symbols.Error || relocations.Error || imports.Error || memory.Error ||
    std.mem.Allocator.Error;

/// A resolver is deliberately independent of HLE. The loader can therefore be
/// used with firmware exports, another guest module, or a test symbol table.
pub const Resolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (context: ?*anyopaque, import: *const imports.Import) ?u64,
    resolve_tls_fn: ?*const fn (
        context: ?*anyopaque,
        import: *const imports.Import,
    ) ?tls.ResolvedSymbol = null,

    pub fn resolve(self: Resolver, import: *const imports.Import) ?u64 {
        return self.resolve_fn(self.context, import);
    }

    pub fn resolveTls(self: Resolver, import: *const imports.Import) ?tls.ResolvedSymbol {
        const resolve_fn = self.resolve_tls_fn orelse return null;
        return resolve_fn(self.context, import);
    }
};

pub const Stats = struct {
    applied: usize = 0,
    relative: usize = 0,
    local_symbols: usize = 0,
    imported_symbols: usize = 0,
    tls: usize = 0,
    ignored: usize = 0,
};

/// Applies both the general and PLT relocation tables.
pub fn apply(
    allocator: std.mem.Allocator,
    address_space: *memory.AddressSpace,
    image: elf.Image,
    info: *const dynamic.DynamicInfo,
    load_bias: u64,
    resolver: ?Resolver,
    tls_module: ?tls.Module,
) Error!Stats {
    const symbol_bytes = try info.tableData(image, info.symtab_offset, info.symtab_size);
    const symbol_table = try symbols.Table.init(symbol_bytes);

    var module_imports = try imports.collect(allocator, image, info);
    defer module_imports.deinit(allocator);

    var stats = Stats{};
    const general_bytes = try info.tableData(image, info.rela_offset, info.rela_size);
    if (general_bytes.len != 0) {
        try applyTable(
            address_space,
            try relocations.Table.init(general_bytes, .general),
            symbol_table,
            &module_imports,
            load_bias,
            resolver,
            tls_module,
            &stats,
        );
    }

    const plt_bytes = try info.tableData(image, info.jmprel_offset, info.jmprel_size);
    if (plt_bytes.len != 0) {
        try applyTable(
            address_space,
            try relocations.Table.init(plt_bytes, .plt),
            symbol_table,
            &module_imports,
            load_bias,
            resolver,
            tls_module,
            &stats,
        );
    }
    return stats;
}

fn applyTable(
    address_space: *memory.AddressSpace,
    table: relocations.Table,
    symbol_table: symbols.Table,
    module_imports: *const imports.Imports,
    load_bias: u64,
    resolver: ?Resolver,
    tls_module: ?tls.Module,
    stats: *Stats,
) Error!void {
    for (table.entries) |rela| {
        const relocation_type = rela.relocationType();
        const value: u64 = switch (relocation_type) {
            .none => {
                stats.ignored += 1;
                continue;
            },
            .relative => blk: {
                stats.relative += 1;
                break :blk try addSigned(load_bias, rela.addend);
            },
            .direct_64, .glob_dat, .jump_slot => blk: {
                const symbol = try symbol_table.at(rela.symbolIndex());
                var symbol_address: u64 = undefined;
                if (symbol.isDefined()) {
                    symbol_address = std.math.add(u64, load_bias, symbol.value) catch
                        return Error.AddressOverflow;
                    stats.local_symbols += 1;
                } else {
                    const import = findImport(module_imports, rela.offset, table.kind) orelse {
                        if (symbol.binding() == .weak) break :blk 0;
                        return Error.UnresolvedImport;
                    };
                    symbol_address = if (resolver) |r| r.resolve(import) orelse {
                        if (symbol.binding() == .weak) break :blk 0;
                        return Error.UnresolvedImport;
                    } else {
                        if (symbol.binding() == .weak) break :blk 0;
                        return Error.UnresolvedImport;
                    };
                    stats.imported_symbols += 1;
                }

                break :blk if (relocation_type.usesAddend())
                    try addSigned(symbol_address, rela.addend)
                else
                    symbol_address;
            },
            .dtpmod64, .dtpoff64, .tpoff64 => blk: {
                const symbol = try symbol_table.at(rela.symbolIndex());
                if (rela.symbolIndex() != 0 and symbol.symbolType() != .tls) {
                    return Error.InvalidTlsSymbol;
                }
                const resolved = if (rela.symbolIndex() == 0 or symbol.isDefined()) local: {
                    const module = tls_module orelse return Error.TlsModuleUnavailable;
                    stats.local_symbols += 1;
                    break :local tls.ResolvedSymbol{
                        .module = module,
                        .offset = symbol.value,
                    };
                } else external: {
                    const import = findImport(module_imports, rela.offset, table.kind) orelse {
                        if (symbol.binding() == .weak) break :blk 0;
                        return Error.UnresolvedImport;
                    };
                    const resolution = if (resolver) |r| r.resolveTls(import) orelse {
                        if (symbol.binding() == .weak) break :blk 0;
                        return Error.UnresolvedImport;
                    } else {
                        if (symbol.binding() == .weak) break :blk 0;
                        return Error.UnresolvedImport;
                    };
                    stats.imported_symbols += 1;
                    break :external resolution;
                };

                if (resolved.offset >= resolved.module.memory_size) {
                    return Error.InvalidTlsOffset;
                }
                if (resolved.module.static_offset < resolved.module.memory_size) {
                    return Error.InvalidTlsOffset;
                }
                stats.tls += 1;
                if (relocation_type == .dtpmod64) break :blk resolved.module.id;

                const module_offset = try addSigned(resolved.offset, rela.addend);
                if (module_offset >= resolved.module.memory_size) {
                    return Error.InvalidTlsOffset;
                }
                break :blk if (relocation_type == .tpoff64)
                    module_offset -% resolved.module.static_offset
                else
                    module_offset;
            },
            _ => return Error.UnsupportedRelocation,
        };

        const target = std.math.add(u64, load_bias, rela.offset) catch
            return Error.AddressOverflow;
        address_space.writeInt(u64, target, value) catch |err| return switch (err) {
            error.ProtectionDenied, error.RangeNotMapped => Error.RelocationTargetUnavailable,
            else => err,
        };
        stats.applied += 1;
    }
}

fn findImport(
    module_imports: *const imports.Imports,
    target_offset: u64,
    table_kind: relocations.TableKind,
) ?*const imports.Import {
    for (module_imports.items.items) |*import| {
        if (import.target_offset == target_offset and import.table == table_kind) return import;
    }
    return null;
}

fn addSigned(base: u64, addend: i64) Error!u64 {
    if (addend >= 0) {
        return std.math.add(u64, base, @intCast(addend)) catch Error.AddressOverflow;
    }

    // Written this way so minInt(i64) does not overflow while being negated.
    const magnitude = @as(u64, @intCast(-(addend + 1))) + 1;
    return std.math.sub(u64, base, magnitude) catch Error.AddressOverflow;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "signed relocation addends are checked in both directions" {
    try testing.expectEqual(@as(u64, 0x1020), try addSigned(0x1000, 0x20));
    try testing.expectEqual(@as(u64, 0x0fe0), try addSigned(0x1000, -0x20));
    try testing.expectError(Error.AddressOverflow, addSigned(0, -1));
    try testing.expectError(Error.AddressOverflow, addSigned(std.math.maxInt(u64), 1));
}

fn testResolve(_: ?*anyopaque, import: *const imports.Import) ?u64 {
    if (std.mem.eql(u8, import.id, "test-import")) return 0x1122_3344_5566_7788;
    return null;
}

test "relative, local, and imported relocations write mapped guest memory" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    const load_bias = memory.system_managed.start;
    try address_space.mapFixed(load_bias, memory.page_size, .read_write, .module, null);

    const symbol_entries = [_]symbols.Sym{
        .{ .name = 0, .info = 0, .other = 0, .shndx = 0, .value = 0, .size = 0 },
        .{ .name = 0, .info = 0x11, .other = 0, .shndx = 1, .value = 0x1234, .size = 8 },
        .{ .name = 0, .info = 0x12, .other = 0, .shndx = 0, .value = 0, .size = 0 },
    };
    const relocation_entries = [_]relocations.Rela{
        .{
            .offset = 0,
            .info = @intFromEnum(relocations.Type.relative),
            .addend = 0x88,
        },
        .{
            .offset = 8,
            .info = (@as(u64, 1) << 32) | @intFromEnum(relocations.Type.direct_64),
            .addend = 4,
        },
        .{
            .offset = 16,
            .info = (@as(u64, 2) << 32) | @intFromEnum(relocations.Type.jump_slot),
            .addend = 0,
        },
    };

    var module_imports = imports.Imports{};
    defer module_imports.deinit(testing.allocator);
    try module_imports.items.append(testing.allocator, .{
        .id = "test-import",
        .library = "libtest",
        .library_version = 1,
        .module = "libtest",
        .library_code = "A",
        .module_code = "A",
        .symbol_type = .func,
        .relocation_type = .jump_slot,
        .table = .general,
        .target_offset = 16,
        .addend = 0,
    });

    var stats = Stats{};
    try applyTable(
        &address_space,
        .{ .entries = &relocation_entries, .kind = .general },
        .{ .entries = &symbol_entries },
        &module_imports,
        load_bias,
        .{ .resolve_fn = testResolve },
        null,
        &stats,
    );

    var output: [24]u8 = undefined;
    try address_space.read(load_bias, &output);
    try testing.expectEqual(load_bias + 0x88, std.mem.readInt(u64, output[0..8], .little));
    try testing.expectEqual(load_bias + 0x1238, std.mem.readInt(u64, output[8..16], .little));
    try testing.expectEqual(
        @as(u64, 0x1122_3344_5566_7788),
        std.mem.readInt(u64, output[16..24], .little),
    );
    try testing.expectEqual(@as(usize, 3), stats.applied);
    try testing.expectEqual(@as(usize, 1), stats.relative);
    try testing.expectEqual(@as(usize, 1), stats.local_symbols);
    try testing.expectEqual(@as(usize, 1), stats.imported_symbols);
}

fn testResolveTls(_: ?*anyopaque, import: *const imports.Import) ?tls.ResolvedSymbol {
    if (!std.mem.eql(u8, import.id, "external-tls")) return null;
    return .{
        .module = .{
            .id = 9,
            .memory_size = 0x80,
            .alignment = 0x10,
            .alignment_bias = 0,
            .static_offset = 0x100,
        },
        .offset = 0x28,
    };
}

test "TLS relocations encode local and imported Variant II values" {
    var address_space = try memory.AddressSpace.init(testing.allocator);
    defer address_space.deinit();
    const load_bias = memory.system_managed.start;
    try address_space.mapFixed(load_bias, memory.page_size, .read_write, .module, null);

    const symbol_entries = [_]symbols.Sym{
        .{ .name = 0, .info = 0, .other = 0, .shndx = 0, .value = 0, .size = 0 },
        .{ .name = 0, .info = 0x06, .other = 0, .shndx = 1, .value = 0x20, .size = 8 },
        .{ .name = 0, .info = 0x16, .other = 0, .shndx = 0, .value = 0, .size = 8 },
    };
    const relocation_entries = [_]relocations.Rela{
        .{
            .offset = 0,
            .info = (@as(u64, 1) << 32) | @intFromEnum(relocations.Type.dtpmod64),
            .addend = 0,
        },
        .{
            .offset = 8,
            .info = (@as(u64, 1) << 32) | @intFromEnum(relocations.Type.dtpoff64),
            .addend = 8,
        },
        .{
            .offset = 16,
            .info = (@as(u64, 1) << 32) | @intFromEnum(relocations.Type.tpoff64),
            .addend = 8,
        },
        .{
            .offset = 24,
            .info = (@as(u64, 2) << 32) | @intFromEnum(relocations.Type.dtpmod64),
            .addend = 0,
        },
        .{
            .offset = 32,
            .info = (@as(u64, 2) << 32) | @intFromEnum(relocations.Type.tpoff64),
            .addend = 8,
        },
    };

    var module_imports = imports.Imports{};
    defer module_imports.deinit(testing.allocator);
    for ([_]struct { u64, relocations.Type }{
        .{ 24, .dtpmod64 },
        .{ 32, .tpoff64 },
    }) |entry| {
        try module_imports.items.append(testing.allocator, .{
            .id = "external-tls",
            .library = "libtls",
            .library_version = 1,
            .module = "tlsmod",
            .library_code = "A",
            .module_code = "A",
            .symbol_type = .tls,
            .relocation_type = entry[1],
            .table = .general,
            .target_offset = entry[0],
            .addend = 0,
        });
    }

    const local_module = tls.Module{
        .id = 3,
        .memory_size = 0x80,
        .alignment = 0x10,
        .alignment_bias = 0,
        .static_offset = 0x80,
    };
    var stats = Stats{};
    try applyTable(
        &address_space,
        .{ .entries = &relocation_entries, .kind = .general },
        .{ .entries = &symbol_entries },
        &module_imports,
        load_bias,
        .{ .resolve_fn = testResolve, .resolve_tls_fn = testResolveTls },
        local_module,
        &stats,
    );

    var output: [40]u8 = undefined;
    try address_space.read(load_bias, &output);
    try testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, output[0..8], .little));
    try testing.expectEqual(@as(u64, 0x28), std.mem.readInt(u64, output[8..16], .little));
    try testing.expectEqual(
        0 -% @as(u64, 0x58),
        std.mem.readInt(u64, output[16..24], .little),
    );
    try testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, output[24..32], .little));
    try testing.expectEqual(
        0 -% @as(u64, 0xd0),
        std.mem.readInt(u64, output[32..40], .little),
    );
    try testing.expectEqual(@as(usize, 5), stats.tls);
    try testing.expectEqual(@as(usize, 3), stats.local_symbols);
    try testing.expectEqual(@as(usize, 2), stats.imported_symbols);
}
