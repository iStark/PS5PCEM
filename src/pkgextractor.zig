// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Extracts metadata from a PS5 debug package (FPKG / `\x7FFIH`).
//!
//! Usage:
//!   pkgextractor <game.pkg> [-o <output-dir>]
//!
//! Unencrypted CNT entries (param.json, icons, PlayGo tables, trophies) are
//! written under `sce_sys/`. Debug / passcode packages also unpack
//! uncompressed SELF modules from the nested `pfs_image.dat` (`eboot.bin`
//! and `sce_module/*.prx`). Kraken-compressed game assets stay packed;
//! retail packages are refused.

const std = @import("std");
const pkg = @import("pkg");

const usage =
    \\pkgextractor <game.pkg> [-o <output-dir>]
    \\
    \\Reads a PS5 debug package (FIH FPKG) and writes unencrypted metadata
    \\into output-dir/sce_sys plus uncompressed SELF modules (eboot.bin,
    \\sce_module/*.prx) from the inner PFS image.
    \\Retail packages cannot be extracted. Kraken-compressed game assets
    \\are not unpacked yet.
    \\
;

const WriteCtx = struct {
    dest: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,

    fn visit(self: *WriteCtx, relative: []const u8, bytes: []const u8) anyerror!void {
        const path = try std.fmt.allocPrint(self.allocator, "sce_sys/{s}", .{relative});
        defer self.allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| {
            self.dest.createDirPath(self.io, parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        try self.dest.writeFile(self.io, .{ .sub_path = path, .data = bytes });
        std.debug.print("  {s}  {d} bytes\n", .{ path, bytes.len });
    }
};

fn defaultOutputPath(allocator: std.mem.Allocator, pkg_path: []const u8) ![]u8 {
    const stem = std.fs.path.stem(pkg_path);
    const dir = std.fs.path.dirname(pkg_path) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir, std.fs.path.sep, stem });
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

    var pkg_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= args.len) {
                try stderr.writeAll("missing value for -o\n");
                try stderr.flush();
                return error.InvalidUsage;
            }
            out_path = args[index];
        } else if (pkg_path == null) {
            pkg_path = arg;
        } else {
            try stderr.writeAll(usage);
            try stderr.flush();
            return error.InvalidUsage;
        }
    }
    const input = pkg_path orelse {
        try stderr.writeAll(usage);
        try stderr.flush();
        return error.InvalidUsage;
    };
    const dest_path = out_path orelse try defaultOutputPath(arena, input);

    var file = std.Io.Dir.cwd().openFile(io, input, .{ .mode = .read_only }) catch |err| {
        try stderr.print("cannot open {s}: {s}\n", .{ input, @errorName(err) });
        try stderr.flush();
        return err;
    };
    defer file.close(io);

    const file_size = file.length(io) catch |err| {
        try stderr.print("cannot stat {s}: {s}\n", .{ input, @errorName(err) });
        try stderr.flush();
        return err;
    };

    var header: [0x100]u8 = undefined;
    _ = file.readPositionalAll(io, &header, 0) catch |err| {
        try stderr.print("cannot read {s}: {s}\n", .{ input, @errorName(err) });
        try stderr.flush();
        return err;
    };

    const kind = pkg.detectKind(&header) orelse {
        try stderr.writeAll("not a PS5 package (expected FIH or CNT magic)\n");
        try stderr.flush();
        return error.NotAPackage;
    };
    if (kind == .fih_retail) {
        try stderr.writeAll("retail packages cannot be extracted without console image keys\n");
        try stderr.flush();
        std.process.exit(2);
    }

    var cnt_offset: u64 = 0;
    var cnt_size: u64 = file_size;
    var pfs_offset: u64 = 0;
    var pfs_size: u64 = 0;
    var superblock_abs: u64 = 0;
    if (kind != .cnt) {
        const fih = pkg.parseFih(&header, file_size) catch |err| {
            try stderr.print("invalid FIH header: {s}\n", .{@errorName(err)});
            try stderr.flush();
            return err;
        };
        cnt_offset = fih.cnt_offset;
        cnt_size = file_size - fih.cnt_offset;
        pfs_offset = fih.pfs_offset;
        pfs_size = fih.pfs_size;
        superblock_abs = fih.superblock_offset;
        std.debug.print(
            "FIH debug  format={d}  pfs=0x{x}+0x{x}  sb=0x{x}  cnt=0x{x}\n",
            .{ fih.format_version, pfs_offset, pfs_size, superblock_abs, cnt_offset },
        );
    }

    if (cnt_size > 64 * 1024 * 1024) cnt_size = 64 * 1024 * 1024;
    const cnt_len: usize = std.math.cast(usize, cnt_size) orelse return error.TruncatedPackage;
    const cnt_buf = try arena.alloc(u8, cnt_len);
    const got = file.readPositionalAll(io, cnt_buf, cnt_offset) catch |err| {
        try stderr.print("cannot read CNT: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };

    std.Io.Dir.cwd().createDirPath(io, dest_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            try stderr.print("cannot create {s}: {s}\n", .{ dest_path, @errorName(err) });
            try stderr.flush();
            return err;
        },
    };
    var dest = std.Io.Dir.cwd().openDir(io, dest_path, .{}) catch |err| {
        try stderr.print("cannot open {s}: {s}\n", .{ dest_path, @errorName(err) });
        try stderr.flush();
        return err;
    };
    defer dest.close(io);

    var ctx = WriteCtx{ .dest = dest, .io = io, .allocator = arena };
    const result = pkg.visitExtractable(cnt_buf[0..got], &ctx, WriteCtx.visit) catch |err| {
        try stderr.print("extract failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };

    std.debug.print(
        "content-id {s}\nextracted {d} file(s) to {s}\nskipped {d} encrypted CNT entries\n",
        .{
            std.mem.sliceTo(&result.content_id, 0),
            result.written,
            dest_path,
            result.skipped_encrypted,
        },
    );
    if (pfs_size != 0) {
        const app = pkg.pfs.extractAppFiles(file, io, arena, pfs_offset, pfs_size, superblock_abs, dest) catch |err| {
            std.debug.print(
                "inner PFS unpack failed ({s}); eboot.bin was not written\n",
                .{@errorName(err)},
            );
            return;
        };
        if (app.eboot) {
            std.debug.print("unpacked eboot.bin and {d} module(s)\n", .{app.modules});
        } else {
            std.debug.print(
                "inner PFS had no SCE_DYNEXEC eboot.bin ({d} other SELF module(s))\n",
                .{app.modules},
            );
        }
    }
}
