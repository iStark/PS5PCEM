// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Prints a guest shader as a list of instructions.
//!
//! A shader that renders nothing is not diagnosable from its output. What
//! matters is which resources it reads and where they come from, and that is
//! written in its scalar prolog: descriptors arrive through a table whose
//! entries are loaded into registers, sometimes one register holding several
//! different descriptors at different points.
//!
//! This decodes with the same frontend the translator uses, so what it prints
//! is what the emulator sees rather than a second opinion about the encoding.
//! An instruction the decoder drops here is one the translator dropped too.

const std = @import("std");
const rdna2 = @import("rdna2");

const usage =
    \\usage: shader-dump <file> [--offset <bytes>] [--count <instructions>] [--resources]
    \\
    \\  <file>        A raw shader blob, or an ELF carrying a .shader_text
    \\                section, which is what a PS5 shader binary is.
    \\  --offset      Start at this byte offset instead of the section start.
    \\  --count       Stop after this many instructions.
    \\  --resources   Print only the descriptor loads and buffer accesses.
    \\
;

const max_shader_bytes: usize = 16 * 1024 * 1024;

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

    var byte_offset: ?usize = null;
    var instruction_limit: ?usize = null;
    var resources_only = false;

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const option = args[index];
        const value = if (index + 1 < args.len) args[index + 1] else null;
        if (std.mem.eql(u8, option, "--offset")) {
            byte_offset = parseNumber(value orelse return error.InvalidUsage) catch return error.InvalidUsage;
            index += 1;
        } else if (std.mem.eql(u8, option, "--count")) {
            instruction_limit = parseNumber(value orelse return error.InvalidUsage) catch return error.InvalidUsage;
            index += 1;
        } else if (std.mem.eql(u8, option, "--resources")) {
            resources_only = true;
        } else {
            try stderr.print("unknown option {s}\n", .{option});
            try stderr.flush();
            return error.InvalidUsage;
        }
    }

    const path = args[1];
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        .limited(max_shader_bytes),
    ) catch |err| {
        try stderr.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return err;
    };

    // A PS5 shader binary is an ELF whose code lives in .shader_text. Finding
    // it here means the caller does not have to know the offset, and a raw
    // blob still works because the section lookup is optional.
    const section = if (byte_offset) |offset|
        Span{ .offset = offset, .size = bytes.len - offset }
    else
        findShaderText(bytes) orelse Span{ .offset = 0, .size = bytes.len };

    if (section.offset >= bytes.len) {
        try stderr.print(
            "offset 0x{x} is past the end of a {d}-byte file\n",
            .{ section.offset, bytes.len },
        );
        try stderr.flush();
        return error.InvalidUsage;
    }

    const available = @min(section.size, bytes.len - section.offset);
    const body = bytes[section.offset..][0..available];
    const word_count = body.len / @sizeOf(u32);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("{s}\n", .{path});
    try out.print("  offset  0x{x}\n", .{section.offset});
    try out.print("  words   {d}\n\n", .{word_count});

    // Copied rather than reinterpreted: a file read carries no alignment
    // guarantee and a misaligned word read is undefined on some hosts.
    const code = try arena.alloc(u32, word_count);
    for (code, 0..) |*word, position| {
        word.* = std.mem.readInt(u32, body[position * 4 ..][0..4], .little);
    }

    var program = rdna2.decoder.decodeProgram(arena, code) catch |err| {
        try stderr.print("decode failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };
    defer program.deinit(arena);

    var printed: usize = 0;
    var undecoded: usize = 0;
    for (program.instructions.items) |inst| {
        if (inst.opcode == .unknown or inst.opcode == .unsupported) undecoded += 1;
        if (resources_only and !touchesResources(inst)) continue;
        if (instruction_limit) |limit| if (printed >= limit) break;
        try printInstruction(out, inst);
        printed += 1;
    }

    // The count the translator would work from, and how much of it it cannot
    // read. A shader that loses resources usually loses them here first.
    try out.print("\n  instructions {d}\n", .{program.instructions.items.len});
    try out.print("  undecoded    {d}\n", .{undecoded});
    try out.flush();
}

const Span = struct { offset: usize, size: usize };

fn findShaderText(bytes: []const u8) ?Span {
    if (bytes.len < 0x40 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return null;
    const section_offset = std.mem.readInt(u64, bytes[0x28..][0..8], .little);
    const entry_size = std.mem.readInt(u16, bytes[0x3a..][0..2], .little);
    const count = std.mem.readInt(u16, bytes[0x3c..][0..2], .little);
    const name_index = std.mem.readInt(u16, bytes[0x3e..][0..2], .little);
    if (entry_size < 0x28 or count == 0 or name_index >= count) return null;

    const names_header = section_offset + @as(u64, name_index) * entry_size;
    if (names_header + 0x28 > bytes.len) return null;
    const names_offset = std.mem.readInt(u64, bytes[@intCast(names_header + 0x18)..][0..8], .little);

    var index: u16 = 0;
    while (index < count) : (index += 1) {
        const header = section_offset + @as(u64, index) * entry_size;
        if (header + 0x28 > bytes.len) return null;
        const name = std.mem.readInt(u32, bytes[@intCast(header)..][0..4], .little);
        const offset = std.mem.readInt(u64, bytes[@intCast(header + 0x18)..][0..8], .little);
        const size = std.mem.readInt(u64, bytes[@intCast(header + 0x20)..][0..8], .little);
        const label_start: usize = @intCast(names_offset + name);
        if (label_start >= bytes.len) continue;
        const label_end = std.mem.indexOfScalarPos(u8, bytes, label_start, 0) orelse bytes.len;
        if (std.mem.eql(u8, bytes[label_start..label_end], ".shader_text")) {
            return .{ .offset = @intCast(offset), .size = @intCast(size) };
        }
    }
    return null;
}

/// Whether this instruction names a resource: a descriptor load, or a read or
/// write through one. These are the instructions a lost resource shows up in.
fn touchesResources(inst: rdna2.Instruction) bool {
    return switch (inst.family) {
        .smem, .mubuf, .mtbuf, .mimg => true,
        else => false,
    };
}

fn printInstruction(out: *std.Io.Writer, inst: rdna2.Instruction) !void {
    try out.print("  pc=0x{x:0>4} {s:<6} {s}", .{
        inst.pc,
        @tagName(inst.family),
        @tagName(inst.opcode),
    });
    if (inst.dst.kind != .unknown) {
        try out.writeAll("  dst=");
        try printOperand(out, inst.dst);
    }
    const sources = inst.sources();
    for (sources.slice(), 0..) |source, position| {
        try out.print("  src{d}=", .{position});
        try printOperand(out, source);
    }
    if (inst.memory_offset != 0) try out.print("  offset=0x{x}", .{inst.memory_offset});
    if (inst.data_words != 0) try out.print("  words={d}", .{inst.data_words});
    try out.writeAll("\n");
}

fn printOperand(out: *std.Io.Writer, operand: rdna2.operand.Operand) !void {
    switch (operand.kind) {
        .sgpr => try out.print("s{d}", .{operand.reg}),
        .vgpr => try out.print("v{d}", .{operand.reg}),
        .literal_constant => try out.print("0x{x}", .{operand.value}),
        .integer_inline_constant => try out.print("{d}", .{operand.signed_val}),
        .float_inline_constant => try out.print("{d:.3}", .{operand.float_val}),
        else => try out.print("{s}", .{@tagName(operand.kind)}),
    }
}

fn parseNumber(text: []const u8) !usize {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseInt(usize, text[2..], 16);
    }
    return std.fmt.parseInt(usize, text, 10);
}
