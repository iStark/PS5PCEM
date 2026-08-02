// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Maps and relocates a real executable/PRX dependency graph without running it.

const std = @import("std");
const runtime = @import("runtime");

const DiagnosticContext = struct {
    writer: *std.Io.Writer,
    count: usize = 0,
    write_error: ?std.Io.Writer.Error = null,

    fn unresolved(raw: ?*anyopaque, diagnostic: runtime.module_graph.UnresolvedImport) void {
        const self: *DiagnosticContext = @ptrCast(@alignCast(raw.?));
        self.count += 1;
        if (self.write_error != null) return;
        self.writer.print("  unresolved {s}: {s} {s} {s}\n", .{
            diagnostic.path,
            diagnostic.import.id,
            diagnostic.import.library orelse diagnostic.import.library_code,
            @tagName(diagnostic.import.symbol_type),
        }) catch |err| {
            self.write_error = err;
        };
    }
};

const usage =
    \\graph-info <eboot.bin|module.prx>
    \\
    \\Discovers adjacent PRX dependencies, maps the complete reachable graph,
    \\publishes guest exports and performs every relocation without executing
    \\guest initializers or entry points.
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        try stderr.writeAll(usage);
        try stderr.flush();
        return error.InvalidUsage;
    }

    var emu = runtime.Runtime{};
    try emu.init(allocator);
    defer emu.deinit();

    var diagnostic_context = DiagnosticContext{ .writer = stderr };
    var graph = emu.loadModuleGraph(io, args[1], .{
        .diagnostics = .{
            .context = &diagnostic_context,
            .unresolved_fn = &DiagnosticContext.unresolved,
        },
    }) catch |err| {
        if (diagnostic_context.write_error) |write_err| return write_err;
        try stderr.print("cannot link {s}: {s}\n", .{ args[1], @errorName(err) });
        if (diagnostic_context.count != 0) {
            try stderr.print("{d} unresolved strong imports in the failing module\n", .{
                diagnostic_context.count,
            });
        }
        try stderr.flush();
        return err;
    };
    defer graph.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("{s}\n", .{args[1]});
    try out.print("  modules       {d} dependencies\n", .{graph.moduleCount()});
    try out.print("  guest exports {d}\n", .{emu.guest_exports.symbolCount()});
    try out.print("  entry          0x{x}\n", .{graph.executable().entry_point});
    try out.print("\nload order\n", .{});
    for (graph.nodes.items) |*node| {
        const mapped = &node.mapped.?;
        try out.print("  0x{x:0>12}  {s}\n", .{ mapped.load_bias, node.path });
    }
    try out.flush();
}
