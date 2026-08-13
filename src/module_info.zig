// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Inspects a guest module: what it declares, what it imports, and how much of
//! that the firmware emulation can currently supply.
//!
//! This is the point where the loader and the firmware registry meet. Reading a
//! module tells you which symbols it needs; the registry says which of them
//! exist. The gap between the two is the work remaining before that module can
//! run, so printing it is more useful than any aggregate progress figure.

const std = @import("std");
const loader = @import("loader");
const hle = @import("hle");

const usage =
    \\module-info <module> [provider.prx ...] [--names <list>] [--bytes <vaddr> <count>]
    \\
    \\Prints a bare ELF or decrypted PS5 SELF module's identity, dependencies,
    \\and imports, marking which ones the firmware emulation or optional guest
    \\provider modules supply.
    \\
    \\--names takes a file of candidate symbol names, one per line, and recovers
    \\the published name of every import whose identifier one of them hashes to.
    \\--bytes prints a bounded virtual range from the decrypted ELF/SELF image.
    \\
;

const max_module_bytes: usize = 512 * 1024 * 1024;
const max_name_list_bytes: usize = 64 * 1024 * 1024;

/// Published names, keyed by the identifier they hash to.
const NameTable = std.StringHashMapUnmanaged([]const u8);

/// Builds the identifier-to-name table from a list of candidate names.
///
/// An identifier is a hash, so it cannot be turned back into a name — but a
/// list of candidates can be hashed and matched against it. That is worth doing
/// because an import a title needs is only actionable once it has a name: a
/// report saying `sceKernelAioSubmitReadCommands` is a piece of work, and one
/// saying `HgX7+AORI58` is a puzzle.
///
/// The list is supplied rather than built in. Which names exist is not
/// something this project knows, and a name that hashes correctly is evidence
/// on its own — a wrong guess simply never matches.
fn buildNameTable(gpa: std.mem.Allocator, text: []const u8) !NameTable {
    var table = NameTable{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r");
        if (name.len == 0) continue;
        const id = try gpa.dupe(u8, &hle.nid.fromName(name));
        // First match wins: two names hashing alike is a collision, and the
        // later one is no more likely to be right than the earlier.
        _ = try table.getOrPutValue(gpa, id, name);
    }
    return table;
}

/// How an import matched the registry.
const Resolution = enum {
    /// Matched on identifier, library and module together.
    exact,
    /// Matched on identifier alone. The module asked for a library the
    /// registry does not know under that name, so this may be the wrong
    /// implementation.
    by_identifier,
    not_found,

    fn mark(self: Resolution) []const u8 {
        return switch (self) {
            .exact => "ok  ",
            .by_identifier => "~   ",
            .not_found => "MISS",
        };
    }
};

fn resolve(
    db: *const hle.Database,
    guest_exports: *loader.GuestExportRegistry,
    imp: loader.Import,
) Resolution {
    if (guest_exports.resolveExact(&imp) != null) return .exact;
    if (imp.id.len != hle.nid.encoded_len) return .not_found;
    const symbol_type = toHleSymbolType(imp.symbol_type);

    if (imp.library != null and imp.module != null) {
        var id: hle.nid.Encoded = undefined;
        @memcpy(&id, imp.id);

        const key = hle.symbols.Key{
            .id = id,
            .library = .{ .name = imp.library.?, .version = @intCast(imp.library_version.?) },
            .module = .{ .name = imp.module.? },
            .type = symbol_type,
        };
        if (db.find(key) != null) return .exact;
    }

    if (guest_exports.resolveById(&imp) != null or
        db.findById(imp.id, symbol_type) != null) return .by_identifier;
    return .not_found;
}

fn toHleSymbolType(symbol_type: loader.symbols.Type) hle.SymbolType {
    return switch (symbol_type) {
        .func => .function,
        .object => .object,
        .tls => .tls_module,
        else => .no_type,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try stderr.writeAll(usage);
        try stderr.flush();
        return error.InvalidUsage;
    }
    const path = args[1];

    // Separated from the provider paths so a name list can be given anywhere
    // after the module, which is where a reader naturally puts it.
    var providers: std.ArrayList([]const u8) = .empty;
    defer providers.deinit(arena);
    var names_path: ?[]const u8 = null;
    var bytes_address: ?u64 = null;
    var bytes_count: usize = 0;
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--names")) {
            if (index + 1 >= args.len) {
                try stderr.writeAll(usage);
                try stderr.flush();
                return error.InvalidUsage;
            }
            names_path = args[index + 1];
            index += 1;
        } else if (std.mem.eql(u8, args[index], "--bytes")) {
            if (index + 2 >= args.len) {
                try stderr.writeAll(usage);
                try stderr.flush();
                return error.InvalidUsage;
            }
            bytes_address = std.fmt.parseInt(u64, args[index + 1], 0) catch return error.InvalidUsage;
            bytes_count = std.fmt.parseInt(usize, args[index + 2], 0) catch return error.InvalidUsage;
            if (bytes_count == 0 or bytes_count > 4096) return error.InvalidUsage;
            index += 2;
        } else {
            try providers.append(arena, args[index]);
        }
    }

    var names = NameTable{};
    defer names.deinit(arena);
    if (names_path) |list_path| {
        const list = std.Io.Dir.cwd().readFileAlloc(
            io,
            list_path,
            arena,
            .limited(max_name_list_bytes),
        ) catch |err| {
            try stderr.print("cannot read {s}: {s}\n", .{ list_path, @errorName(err) });
            try stderr.flush();
            return err;
        };
        names = try buildNameTable(arena, list);
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(max_module_bytes),
    ) catch |err| {
        try stderr.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return err;
    };

    const image = loader.parseImage(bytes) catch |err| {
        try stderr.print("not a supported guest module: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };

    var info = try loader.parseDynamic(arena, image);
    defer info.deinit(arena);

    var module_imports = try loader.collectImports(arena, image, &info);
    defer module_imports.deinit(arena);
    var module_exports: std.ArrayList(loader.GuestExport) = .empty;
    defer module_exports.deinit(arena);
    try loader.collectGuestExports(arena, &module_exports, image, &info, 0);

    var db = hle.Database{};
    defer db.deinit(arena);
    try hle.registerAll(&db, arena);

    var guest_exports = loader.GuestExportRegistry{};
    defer guest_exports.deinit(arena);
    for (providers.items, 0..) |provider_path, provider_index| {
        const provider_bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            provider_path,
            arena,
            .limited(max_module_bytes),
        );
        const provider_image = try loader.parseImage(provider_bytes);
        var provider_info = try loader.parseDynamic(arena, provider_image);
        defer provider_info.deinit(arena);
        _ = try guest_exports.registerImage(
            arena,
            provider_image,
            &provider_info,
            (@as(u64, provider_index) + 1) * 0x10_0000_0000,
        );
    }

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("{s}\n", .{path});
    try out.print("  container     {s}\n", .{if (image.isSelf()) "ps5_self" else "bare_elf"});
    try out.print("  type          {s}\n", .{@tagName(image.objectType())});
    try out.print("  entry         0x{x}\n", .{image.entryPoint()});
    if (providers.items.len != 0) {
        try out.print("  providers     {d} modules, {d} guest exports\n", .{
            providers.items.len,
            guest_exports.symbolCount(),
        });
    }
    if (names_path != null) {
        try out.print("  names         {d} candidates\n", .{names.count()});
    }
    if (info.module_info) |own| {
        try out.print("  module        {s} v{d}.{d}\n", .{
            own.name,
            own.version_major,
            own.version_minor,
        });
    }

    var load_buf: [32]loader.ProgramHeader = undefined;
    const loads = image.loadSegments(&load_buf);
    try out.print("\nsegments ({d} loadable)\n", .{loads.len});
    for (loads) |ph| {
        const f = ph.segmentFlags();
        try out.print("  0x{x:0>12} size 0x{x:<8} {c}{c}{c}\n", .{
            ph.vaddr,
            ph.memsz,
            @as(u8, if (f.readable) 'r' else '-'),
            @as(u8, if (f.writable) 'w' else '-'),
            @as(u8, if (f.executable) 'x' else '-'),
        });
    }

    if (bytes_address) |address| {
        const code = image.virtualRange(address, bytes_count) catch |err| {
            try stderr.print("cannot read virtual range 0x{x}+0x{x}: {s}\n", .{ address, bytes_count, @errorName(err) });
            try stderr.flush();
            return err;
        };
        try out.print("\nbytes 0x{x}+0x{x}\n", .{ address, code.len });
        var offset: usize = 0;
        while (offset < code.len) : (offset += 16) {
            const line = code[offset..@min(offset + 16, code.len)];
            try out.print("  {x:0>12} ", .{address + offset});
            for (line) |byte| try out.print(" {x:0>2}", .{byte});
            var padding = line.len;
            while (padding < 16) : (padding += 1) try out.writeAll("   ");
            try out.writeAll("  |");
            for (line) |byte| try out.writeByte(if (byte >= 0x20 and byte < 0x7f) byte else '.');
            try out.writeAll("|\n");
        }
    }

    if (info.needed_modules.items.len != 0) {
        try out.print("\nneeded modules\n", .{});
        for (info.needed_modules.items) |m| {
            try out.print("  [{s}] {s} v{d}.{d}\n", .{
                m.id.slice(),
                m.name,
                m.version_major,
                m.version_minor,
            });
        }
    }

    if (info.import_libraries.items.len != 0) {
        try out.print("\nimported libraries\n", .{});
        for (info.import_libraries.items) |l| {
            try out.print("  [{s}] {s} v{d}\n", .{ l.id.slice(), l.name, l.version });
        }
    }

    try out.print("\nexports ({d})\n", .{module_exports.items.len});
    for (module_exports.items) |exp| {
        try out.print("  0x{x:0>12}  {s}  {s}/{s}  {s}\n", .{
            exp.address,
            exp.id,
            exp.module,
            exp.library,
            @tagName(exp.symbol_type),
        });
    }

    try out.print("\nimports ({d})\n", .{module_imports.items.items.len});
    var resolved: usize = 0;
    for (module_imports.items.items) |imp| {
        const status = resolve(&db, &guest_exports, imp);
        if (status != .not_found) resolved += 1;
        // Both names, because resolution needs both: a library says which set
        // of entry points, and the module says which image publishes that set.
        // The two are routinely spelled differently — a library ending in a
        // version digit usually lives in a module without it — and a report
        // showing only one leaves that difference invisible.
        try out.print("  {s} {s}  {s}/{s}  {s}  {s}", .{
            status.mark(),
            imp.id,
            imp.module orelse imp.module_code,
            imp.library orelse imp.library_code,
            @tagName(imp.symbol_type),
            @tagName(imp.relocation_type),
        });
        if (names.get(imp.id)) |name| try out.print("  {s}", .{name});
        try out.writeByte('\n');
    }

    try out.print("\n{d}/{d} imports provided\n", .{ resolved, module_imports.items.items.len });
    if (module_imports.malformed_names != 0) {
        try out.print("{d} symbol names were malformed\n", .{module_imports.malformed_names});
    }
    if (module_imports.non_symbolic != 0) {
        try out.print("{d} relocations reference no symbol\n", .{module_imports.non_symbolic});
    }

    try out.flush();
}

const testing = std.testing;

test "a candidate name is recovered through the identifier it hashes to" {
    // An identifier is a hash and cannot be inverted; a candidate that hashes
    // to it is the evidence. A wrong guess simply never matches, which is why
    // feeding a large list of names costs nothing in confidence.
    var table = try buildNameTable(testing.allocator,
        \\sceKernelAioSubmitReadCommands
        \\scePthreadGetthreadid
        \\
        \\  sceKernelBatchMap
        \\
    );
    defer {
        var keys = table.keyIterator();
        while (keys.next()) |key| testing.allocator.free(key.*);
        table.deinit(testing.allocator);
    }

    try testing.expectEqual(@as(u32, 3), table.count());
    try testing.expectEqualStrings(
        "sceKernelAioSubmitReadCommands",
        table.get("HgX7+AORI58").?,
    );
    // Surrounding blanks belong to the file, not to the name.
    try testing.expectEqualStrings("sceKernelBatchMap", table.get("2SKEx6bSq-4").?);
    try testing.expect(table.get("AAAAAAAAAAA") == null);
}
