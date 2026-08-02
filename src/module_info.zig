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
    \\module-info <module.elf>
    \\
    \\Prints a guest module's identity, its dependencies, and every symbol it
    \\imports, marking which ones the firmware emulation provides.
    \\
;

const max_module_bytes: usize = 512 * 1024 * 1024;

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

fn resolve(db: *const hle.Database, imp: loader.Import) Resolution {
    if (imp.id.len != hle.nid.encoded_len) return .not_found;

    if (imp.library != null and imp.module != null) {
        var id: hle.nid.Encoded = undefined;
        @memcpy(&id, imp.id);

        const key = hle.symbols.Key{
            .id = id,
            .library = .{ .name = imp.library.?, .version = @intCast(imp.library_version.?) },
            .module = .{ .name = imp.module.? },
            .type = .function,
        };
        if (db.find(key) != null) return .exact;
    }

    if (db.findById(imp.id, .function) != null) return .by_identifier;
    return .not_found;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        try stderr.writeAll(usage);
        try stderr.flush();
        return error.InvalidUsage;
    }
    const path = args[1];

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

    var db = hle.Database{};
    defer db.deinit(arena);
    try hle.registerAll(&db, arena);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("{s}\n", .{path});
    try out.print("  type          {s}\n", .{@tagName(image.objectType())});
    try out.print("  entry         0x{x}\n", .{image.entryPoint()});
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

    try out.print("\nimports ({d})\n", .{module_imports.items.items.len});
    var resolved: usize = 0;
    for (module_imports.items.items) |imp| {
        const status = resolve(&db, imp);
        if (status != .not_found) resolved += 1;
        try out.print("  {s} {s}  {s}  {s}\n", .{
            status.mark(),
            imp.id,
            imp.library orelse imp.library_code,
            @tagName(imp.relocation_type),
        });
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
