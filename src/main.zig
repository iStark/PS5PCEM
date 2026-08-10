// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! CLI disassembler: reads a binary RDNA2 shader and prints the decoded code.

const std = @import("std");
const rdna2 = @import("rdna2");

const usage =
    \\rdna2-disasm [--cfg | --check-fragment] <file.bin>
    \\rdna2-disasm --write-fragment <file.bin> <module.spv>
    \\
    \\Reads a binary RDNA2 shader (a sequence of little-endian 32-bit words)
    \\and prints the disassembled code.
    \\
;

/// A sane ceiling for a shader — guards against being pointed at the wrong file.
const max_shader_bytes: usize = 16 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const show_cfg = args.len == 3 and std.mem.eql(u8, args[1], "--cfg");
    const check_fragment = args.len == 3 and std.mem.eql(u8, args[1], "--check-fragment");
    const write_fragment = args.len == 4 and std.mem.eql(u8, args[1], "--write-fragment");
    if (args.len != 2 and !show_cfg and !check_fragment and !write_fragment) {
        try stderr.writeAll(usage);
        try stderr.flush();
        return error.InvalidUsage;
    }
    const path = if (show_cfg or check_fragment or write_fragment) args[2] else args[1];

    // Words are read as u32, so the buffer has to be aligned for u32.
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        .limited(max_shader_bytes),
        .of(u32),
        null,
    ) catch |err| {
        try stderr.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return err;
    };

    if (bytes.len % 4 != 0) {
        try stderr.print("size of {s} is not a multiple of 4 bytes\n", .{path});
        try stderr.flush();
        return error.MisalignedShader;
    }

    const code = std.mem.bytesAsSlice(u32, bytes);

    var program = rdna2.decodeProgram(arena, code) catch |err| {
        try stderr.print("decode failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };
    defer program.deinit(arena);

    if (show_cfg) {
        var graph = try rdna2.buildControlFlow(arena, &program);
        defer graph.deinit(arena);
        var conditional_edges: usize = 0;
        var back_edges: usize = 0;
        var scc_edges: usize = 0;
        var vcc_edges: usize = 0;
        var exec_edges: usize = 0;
        for (graph.edges.items) |edge| {
            if (edge.condition != .none) conditional_edges += 1;
            if (edge.to <= edge.from) back_edges += 1;
            switch (edge.condition) {
                .scc => scc_edges += 1,
                .vcc_zero => vcc_edges += 1,
                .exec_zero => exec_edges += 1,
                .none => {},
            }
        }
        try stderr.print(
            "cfg: instructions={d} blocks={d} edges={d} conditional={d} (scc={d},vcc={d},exec={d}) selections={d} back_edges={d}\n",
            .{
                program.instructions.items.len,
                graph.blocks.items.len,
                graph.edges.items.len,
                conditional_edges,
                scc_edges,
                vcc_edges,
                exec_edges,
                graph.selections.items.len,
                back_edges,
            },
        );
        for (graph.edges.items) |edge| {
            if (edge.to > edge.from) continue;
            try stderr.print(
                "  back-edge b{d}->b{d} condition={s} expected={any}\n",
                .{ edge.from, edge.to, @tagName(edge.condition), edge.expected },
            );
        }
        try stderr.flush();
    }

    if (check_fragment or write_fragment) {
        var scalars: [128]rdna2.spirv.ScalarRegister = undefined;
        for (&scalars, 0..) |*scalar, register| scalar.* = .{
            .register = @intCast(register),
            .value = 0,
        };

        var storage: [32]rdna2.spirv.StorageBufferBinding = undefined;
        for (&storage, 0..) |*binding, index| binding.* = .{
            .resource_sgpr = @intCast(index * 4),
            .descriptor_index = 0,
        };

        var images: [32 * 32]rdna2.spirv.SampledImageBinding = undefined;
        for (0..32) |resource| for (0..32) |sampler| {
            images[resource * 32 + sampler] = .{
                .resource_sgpr = @intCast(resource * 4),
                .sampler_sgpr = @intCast(sampler * 4),
                .descriptor_index = 0,
            };
        };

        var module = rdna2.translateSpirv(arena, &program, .{
            .stage = .fragment,
            .storage_buffers = &storage,
            .sampled_images = &images,
            .scalar_registers = &scalars,
            .specialized_scalar_prefix_end = 0x0010_0000,
            .infer_fragment_parameter_mask = false,
            .parameter_mask = if (write_fragment) 1 else 0,
            .allow_control_flow_fallback = false,
        }) catch |err| {
            try stderr.print("structured fragment translation failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            return err;
        };
        defer module.deinit(arena);
        try stderr.print("structured fragment translation ok: instructions={d} spirv_words={d}\n", .{
            program.instructions.items.len,
            module.words.len,
        });
        if (write_fragment) {
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = args[3],
                .data = std.mem.sliceAsBytes(module.words),
            });
            try stderr.print("wrote {s}\n", .{args[3]});
        }
        try stderr.flush();
        return;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try rdna2.formatProgram(program, stdout);
    try stdout.flush();
}
