// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Prints a GPU command stream as a list of commands.
//!
//! A captured submission is a wall of hexadecimal that says nothing at a
//! glance. Decoded, it shows the shape of the work: how state is set up, where
//! the draws are, what is waited on and when. That is what has to be
//! reproduced, so being able to read a capture is the first requirement for
//! reproducing one — and it is checkable against a real capture long before
//! anything can render.

const std = @import("std");
const gpu = @import("gpu");

const usage =
    \\pm4-dump <capture> [--offset <bytes>] [--count <packets>]
    \\
    \\Decodes a raw GPU command stream: one packet per line, prefixed by its
    \\word offset. Undocumented commands are shown by number rather than named.
    \\
;

const max_capture_bytes: usize = 256 * 1024 * 1024;

/// Reads a decimal or `0x`-prefixed argument.
fn parseNumber(text: []const u8) !usize {
    if (std.mem.startsWith(u8, text, "0x")) return std.fmt.parseInt(usize, text[2..], 16);
    return std.fmt.parseInt(usize, text, 10);
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

    var byte_offset: usize = 0;
    var packet_limit: ?usize = null;

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const option = args[index];
        const value = if (index + 1 < args.len) args[index + 1] else null;
        if (std.mem.eql(u8, option, "--offset")) {
            byte_offset = parseNumber(value orelse return error.InvalidUsage) catch return error.InvalidUsage;
            index += 1;
        } else if (std.mem.eql(u8, option, "--count")) {
            packet_limit = parseNumber(value orelse return error.InvalidUsage) catch return error.InvalidUsage;
            index += 1;
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
        .limited(max_capture_bytes),
    ) catch |err| {
        try stderr.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return err;
    };

    if (byte_offset >= bytes.len) {
        try stderr.print(
            "offset 0x{x} is past the end of a {d}-byte capture\n",
            .{ byte_offset, bytes.len },
        );
        try stderr.flush();
        return error.InvalidUsage;
    }

    // The stream is words, so a capture that does not end on a word boundary
    // has a partial one at the end. Saying so is better than silently dropping
    // it, since it usually means the offset is wrong.
    const body = bytes[byte_offset..];
    const word_count = body.len / @sizeOf(u32);
    const leftover = body.len % @sizeOf(u32);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("{s}\n", .{path});
    try out.print("  offset  0x{x}\n", .{byte_offset});
    try out.print("  words   {d}\n\n", .{word_count});

    // Copied rather than reinterpreted in place: a file mapping carries no
    // alignment guarantee, and a misaligned word read is undefined on some of
    // the hosts this is built for.
    const stream = try arena.alloc(u32, word_count);
    for (stream, 0..) |*word, position| {
        word.* = std.mem.readInt(u32, body[position * 4 ..][0..4], .little);
    }

    var walker = gpu.pm4.Walker.init(stream);
    var draws: usize = 0;
    var dispatches: usize = 0;
    var shown: usize = 0;

    while (true) {
        if (packet_limit) |limit| {
            if (shown >= limit) break;
        }
        const offset = walker.index;
        const packet = walker.next() catch |err| {
            try out.print("{d:0>5}: <{s} at this word>\n", .{ offset, @errorName(err) });
            break;
        } orelse break;

        try out.print("{d:0>5}: ", .{offset});
        try gpu.pm4.write(packet, out);
        try out.writeByte('\n');

        if (packet.kind == .command) {
            if (gpu.pm4.isDraw(packet.opcode)) draws += 1;
            if (gpu.pm4.isDispatch(packet.opcode)) dispatches += 1;
        }
        shown += 1;
    }

    try out.print("\n  packets    {d}\n", .{shown});
    try out.print("  draws      {d}\n", .{draws});
    try out.print("  dispatches {d}\n", .{dispatches});
    if (leftover != 0) {
        try out.print("  {d} trailing bytes are not a whole word\n", .{leftover});
    }
    try out.flush();
}

test "a numeric argument is accepted in either base" {
    try std.testing.expectEqual(@as(usize, 16), try parseNumber("0x10"));
    try std.testing.expectEqual(@as(usize, 10), try parseNumber("10"));
    try std.testing.expectError(error.InvalidCharacter, parseNumber("ten"));
}
