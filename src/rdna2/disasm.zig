// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Textual output of decoded instructions.

const std = @import("std");
const isa = @import("isa.zig");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");

const Instruction = instruction.Instruction;
const Operand = operand.Operand;
const Writer = std.Io.Writer;

pub fn formatOperand(op: Operand, w: *Writer) Writer.Error!void {
    if (op.negate) try w.writeAll("-");
    if (op.absolute) try w.writeAll("abs(");
    switch (op.kind) {
        .literal_constant => try w.print("0x{x:0>8}", .{op.value}),
        .integer_inline_constant => try w.print("{d}", .{op.signed_val}),
        .float_inline_constant => try w.print("{d:.6}", .{op.float_val}),
        .sgpr => try w.print("s{d}", .{op.reg}),
        .vgpr => try w.print("v{d}", .{op.reg}),
        .vcc_lo => try w.writeAll("vcc_lo"),
        .vcc_hi => try w.writeAll("vcc_hi"),
        .vcc_z => try w.writeAll("vccz"),
        .exec_lo => try w.writeAll("exec_lo"),
        .exec_hi => try w.writeAll("exec_hi"),
        .exec_z => try w.writeAll("execz"),
        .scc => try w.writeAll("scc"),
        .m0 => try w.writeAll("m0"),
        .pops_exiting_wave_id => try w.writeAll("pops_exiting_wave_id"),
        .null => try w.writeAll("null"),
        .unknown => try w.writeAll("unknown"),
    }
    if (op.absolute) try w.writeAll(")");
}

fn formatRawWords(inst: Instruction, w: *Writer) Writer.Error!void {
    for (0..inst.raw_count) |i| {
        if (i != 0) try w.writeAll(" ");
        try w.print("0x{x:0>8}", .{inst.raw[i]});
    }
}

/// Prints one instruction as `0xPC: mnemonic operands`.
pub fn formatInstruction(inst: Instruction, w: *Writer) Writer.Error!void {
    if (inst.opcode == .unsupported) {
        try w.print("0x{x:0>8}: unsupported family={s} opcode=0x{x:0>2} raw=[", .{
            inst.pc,
            inst.family.name(),
            inst.opcode_id,
        });
        try formatRawWords(inst, w);
        try w.print("] reason={s}", .{inst.unsupported_reason});
        return;
    }

    try w.print("0x{x:0>8}: {s}", .{ inst.pc, inst.opcode.mnemonic() });

    // Branches print their target rather than the raw immediate field.
    if (inst.opcode.isBranch()) {
        try w.print(" 0x{x:0>8}", .{inst.branch_target});
        return;
    }

    var need_comma = false;
    if (inst.dst.kind != .unknown) {
        try w.writeAll(" ");
        try formatOperand(inst.dst, w);
        need_comma = true;
    }

    const srcs = inst.sources();
    for (srcs.slice()) |src| {
        try w.writeAll(if (need_comma) ", " else " ");
        try formatOperand(src, w);
        need_comma = true;
    }

    if (inst.family == .smem) {
        try w.print(" offset:{d}", .{inst.memory_offset});
        if (inst.globally_coherent) try w.writeAll(" glc");
    } else switch (inst.family) {
        .mubuf, .mtbuf, .flat, .ds => {
            try w.print(" offset:{d}", .{inst.memory_offset});
            if (inst.index_enable) try w.writeAll(" idxen");
            if (inst.offset_enable) try w.writeAll(" offen");
            if (inst.globally_coherent) try w.writeAll(" glc");
            if (inst.system_coherent) try w.writeAll(" slc");
        },
        .mimg => try w.print(" dmask:0x{x} dim:{s}", .{ inst.data_mask, @tagName(inst.image_dimension) }),
        .exp => try w.print(" target:{d} en:0x{x}{s}", .{
            inst.export_target,
            inst.export_enable,
            if (inst.export_done) " done" else "",
        }),
        else => {},
    }
}

/// Prints a whole decoded program, one instruction per line.
pub fn formatProgram(program: instruction.Program, w: *Writer) Writer.Error!void {
    for (program.instructions.items) |inst| {
        try formatInstruction(inst, w);
        try w.writeAll("\n");
    }
}

/// Formats an instruction into the given buffer. Convenient in tests.
pub fn bufPrintInstruction(buf: []u8, inst: Instruction) ![]const u8 {
    var w = Writer.fixed(buf);
    try formatInstruction(inst, &w);
    return w.buffered();
}

const scalar_alu = @import("scalar_alu.zig");
const scalar_memory = @import("scalar_memory.zig");

test "printing s_mov_b32" {
    const code = [_]u32{0xbe80_0301};
    const inst = try scalar_alu.decodeSop1(0, &code, 0);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0x00000000: s_mov_b32 s0, s1",
        try bufPrintInstruction(&buf, inst),
    );
}

test "printing a literal" {
    const code = [_]u32{ 0xbe80_03ff, 0x1234_5678 };
    const inst = try scalar_alu.decodeSop1(0, &code, 0);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0x00000000: s_mov_b32 s0, 0x12345678",
        try bufPrintInstruction(&buf, inst),
    );
}

test "printing s_endpgm, which has no operands" {
    const code = [_]u32{0xbf81_0000};
    const inst = try scalar_alu.decodeSopp(4, &code, 0);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0x00000004: s_endpgm",
        try bufPrintInstruction(&buf, inst),
    );
}

test "printing a branch shows the target" {
    const code = [_]u32{0xbf82_fffe};
    const inst = try scalar_alu.decodeSopp(8, &code, 0);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0x00000008: s_branch 0x00000004",
        try bufPrintInstruction(&buf, inst),
    );
}

test "printing an unimplemented instruction" {
    const code = [_]u32{0xbe80_0200};
    const inst = try scalar_alu.decodeSop1(0, &code, 0);

    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0x00000000: unsupported family=SOP1 opcode=0x02 raw=[0xbe800200] reason=SOP1 opcode is not implemented",
        try bufPrintInstruction(&buf, inst),
    );
}

test "printing scalar memory includes its byte offset" {
    const code = [_]u32{ 0xf404_0201, 0x0000_0010 };
    const inst = try scalar_memory.decodeSmem(0, &code, 0);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0x00000000: s_load_dwordx2 s8, s2, s0 offset:16",
        try bufPrintInstruction(&buf, inst),
    );
}
