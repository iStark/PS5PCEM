//! CLI disassembler: reads a binary RDNA2 shader and prints the decoded code.

const std = @import("std");
const rdna2 = @import("rdna2");

const usage =
    \\rdna2-disasm <file.bin>
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
    if (args.len != 2) {
        try stderr.writeAll(usage);
        try stderr.flush();
        return error.InvalidUsage;
    }
    const path = args[1];

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

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try rdna2.formatProgram(program, stdout);
    try stdout.flush();
}
