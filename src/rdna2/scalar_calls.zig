// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bounded scalar calls. Each static call owns a distinct ordinary SGPR pair
//! and a single return. Validate the entire body before emitting fixed edges.
const std = @import("std");
const Instruction = @import("instruction.zig").Instruction;
const Operand = @import("operand.zig").Operand;

pub const Error = error{InvalidScalarCall};
pub const fixtures = @import("scalar_call_fixtures.zig");

pub fn present(instructions: []const Instruction) bool {
    for (instructions) |inst| if (inst.opcode.isCall()) return true;
    return false;
}

pub fn indexAt(instructions: []const Instruction, pc: u32) ?usize {
    for (instructions, 0..) |inst, index| if (inst.pc == pc) return index;
    return null;
}

fn immediate(op: Operand) ?u32 {
    return switch (op.kind) {
        .integer_inline_constant, .literal_constant => op.value,
        .null => 0,
        else => null,
    };
}

fn scalar(op: Operand, reg: u32) bool {
    return op.kind == .sgpr and op.reg == reg;
}

/// Only a local GETPC + optional full-width immediate add/sub is a proof of
/// an indirect target. Runtime/user-data pointers need explicit fetch linking.
pub fn directTarget(instructions: []const Instruction, call_index: usize) ?u32 {
    const call = instructions[call_index];
    if (call.opcode == .s_call_b64) return call.branch_target;
    if (call.opcode != .s_swappc_b64 or call.src0.kind != .sgpr or call.src0.reg % 2 != 0) return null;
    const reg = call.src0.reg;
    if (call_index == 0) return null;
    const last = instructions[call_index - 1];
    if (last.opcode == .s_getpc_b64 and scalar(last.dst, reg)) return last.pc + 4;
    if (call_index < 3) return null;
    const getpc = instructions[call_index - 3];
    const low = instructions[call_index - 2];
    const add = low.opcode == .s_add_u32 and last.opcode == .s_addc_u32;
    const sub = low.opcode == .s_sub_u32 and last.opcode == .s_subb_u32;
    if ((!add and !sub) or getpc.opcode != .s_getpc_b64 or !scalar(getpc.dst, reg) or
        !scalar(low.dst, reg) or !scalar(last.dst, reg + 1) or !scalar(low.src0, reg) or
        !scalar(last.src0, reg + 1) or (immediate(last.src1) orelse return null) != 0) return null;
    const delta = immediate(low.src1) orelse return null;
    return (if (add) getpc.pc +% 4 +% delta else getpc.pc +% 4 -% delta) & ~@as(u32, 3);
}

pub fn returnTarget(instructions: []const Instruction, return_index: usize) ?u32 {
    const ret = instructions[return_index];
    if (ret.opcode != .s_setpc_b64 or ret.src0.kind != .sgpr) return null;
    for (instructions) |call| {
        if (call.opcode.isCall() and scalar(call.dst, ret.src0.reg)) return call.pc + call.word_count * 4;
    }
    return null;
}

/// An ENDPGM before a referenced callee must not hide that callee's return.
pub fn needsMoreCode(instructions: []const Instruction) bool {
    for (instructions, 0..) |call, index| {
        if (!call.opcode.isCall() or directTarget(instructions, index) == null) continue;
        var found = false;
        for (instructions) |ret| {
            if (ret.opcode == .s_setpc_b64 and scalar(ret.src0, call.dst.reg)) found = true;
        }
        if (!found) return true;
    }
    return false;
}

fn overlaps(op: Operand, words: u32, link: u32) bool {
    return op.kind == .sgpr and op.reg <= link + 1 and op.reg + words > link;
}

fn destinationWidth(inst: Instruction) u32 {
    // Vector compares can write a pair even though they operate on f32/u32.
    return @max(inst.data_words, if (std.mem.indexOf(u8, @tagName(inst.opcode), "64") != null or
        inst.family == .vopc or inst.family == .vop3) @as(u32, 2) else 1);
}

fn touchesLink(inst: Instruction, link: u32) bool {
    if (inst.opcode == .unknown or inst.opcode == .unsupported or
        std.mem.startsWith(u8, @tagName(inst.opcode), "s_movrel")) return true;
    if (overlaps(inst.dst, destinationWidth(inst), link) or overlaps(inst.dst2, 2, link)) return true;
    const sources = inst.sources();
    for (sources.slice(), 0..) |op, index| {
        const width: u32 = switch (inst.family) {
            .mimg => if (index == 1) inst.imageResourceWords() else 4,
            .mubuf, .mtbuf => 4,
            .smem => 4,
            .flat => 2,
            else => if (std.mem.indexOf(u8, @tagName(inst.opcode), "64") != null) 2 else 1,
        };
        if (overlaps(op, width, link)) return true;
    }
    return false;
}

const Call = struct { site: usize, target: ?usize, ret: ?usize, link: u32 };

pub fn validate(instructions: []const Instruction, allow_fetch_placeholder: bool) Error!void {
    var calls: [53]Call = undefined;
    var count: usize = 0;
    for (instructions, 0..) |inst, index| {
        if (!inst.opcode.isCall()) continue;
        if (inst.dst.kind != .sgpr or inst.dst.reg > 104 or inst.dst.reg % 2 != 0 or count == calls.len or
            indexAt(instructions, inst.pc + inst.word_count * 4) == null) return error.InvalidScalarCall;
        const link = inst.dst.reg;
        for (calls[0..count]) |other| if (other.link == link) return error.InvalidScalarCall;
        const target = if (directTarget(instructions, index)) |pc|
            indexAt(instructions, pc) orelse return error.InvalidScalarCall
        else
            null;
        var ret: ?usize = null;
        for (instructions, 0..) |other, other_index| {
            if (other_index == index) continue;
            if (other.opcode == .s_setpc_b64 and scalar(other.src0, link)) {
                if (ret != null) return error.InvalidScalarCall;
                ret = other_index;
            } else if (touchesLink(other, link)) return error.InvalidScalarCall;
        }
        if (target) |begin| {
            const end = ret orelse return error.InvalidScalarCall;
            if (end < begin or (index >= begin and index <= end)) return error.InvalidScalarCall;
        } else {
            // Analysis can retain one unresolved fetch pointer until the live
            // backend matches it to AGC's fetch address. Translation cannot.
            if (!allow_fetch_placeholder or ret != null or inst.src0.kind != .sgpr or
                inst.src0.reg > 104 or inst.src0.reg % 2 != 0 or overlaps(inst.src0, 2, link)) return error.InvalidScalarCall;
            for (instructions, 0..) |other, other_index| {
                if (overlaps(other.dst, destinationWidth(other), inst.src0.reg) or overlaps(other.dst2, 2, inst.src0.reg)) return error.InvalidScalarCall;
                if (other_index < index and (other.opcode.isBranch() or other.opcode.isCall() or other.opcode == .s_setpc_b64 or
                    other.opcode.isProgramEnd() or (other.family != .sop1 and other.family != .sop2 and other.family != .sopk and other.family != .sopc and other.family != .sopp and other.family != .smem))) return error.InvalidScalarCall;
            }
        }
        calls[count] = .{ .site = index, .target = target, .ret = ret, .link = link };
        count += 1;
    }
    if (count == 0) return;
    for (calls[0..count]) |call| {
        const begin = call.target orelse continue;
        const end = call.ret.?;
        for (calls[0..count]) |other| {
            const other_begin = other.target orelse continue;
            const other_end = other.ret.?;
            if (!(end < other_begin or other_end < begin or (begin <= other_begin and other_end <= end) or
                (other_begin <= begin and end <= other_end))) return error.InvalidScalarCall;
        }
        for (instructions, 0..) |inst, index| {
            if (returnTarget(instructions, index) != null) continue;
            if (inst.opcode == .s_setpc_b64) return error.InvalidScalarCall;
            if (inst.opcode.isProgramEnd()) {
                if (index >= begin and index <= end) return error.InvalidScalarCall;
                continue;
            }
            var next: ?usize = if (index + 1 < instructions.len) index + 1 else null;
            if (inst.opcode.isCall()) {
                for (calls[0..count]) |other| if (other.site == index) {
                    next = other.target orelse next;
                };
            } else if (inst.opcode.isBranch()) {
                const dest = indexAt(instructions, inst.branch_target) orelse return error.InvalidScalarCall;
                try checkTransfer(call, index, dest);
                if (inst.opcode == .s_branch) continue;
            }
            if (next) |dest| try checkTransfer(call, index, dest);
        }
    }
}

fn checkTransfer(call: Call, from: usize, to: usize) Error!void {
    const begin = call.target.?;
    const end = call.ret.?;
    const inside = from >= begin and from <= end;
    const enters = to >= begin and to <= end;
    if ((!inside and enters and from != call.site) or (inside and !enters and from != end)) return error.InvalidScalarCall;
}

test "scalar calls decode signed targets and retain callees after ENDPGM" {
    const decoder = @import("decoder.zig");
    var program = try decoder.decodeProgram(std.testing.allocator, &.{ 0xbb080001, 0xbf810000, 0xbe800381, 0xbe802008 });
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), program.instructions.items.len);
    try std.testing.expectEqual(@as(u32, 8), program.instructions.items[0].branch_target);
    try validate(program.instructions.items, false);
    const back = try decoder.decodeInstruction(0x100, &.{0xbb08fffe}, 0);
    try std.testing.expectEqual(@as(u32, 0xfc), back.branch_target);
}

test "scalar calls reject recursion invalid targets escaped links and unknown fetch pointers" {
    const decoder = @import("decoder.zig");
    const variants = [_][4]u32{
        .{ 0xbb080001, 0xbf810000, 0xbe880381, 0xbe802008 }, // link overwritten
        .{ 0xbb080001, 0xbf810000, 0xbe870480, 0xbe802008 }, // overlapping b64 destination
        .{ 0xbb080001, 0xbf810000, 0xbe800308, 0xbe802008 }, // escaped return address
        .{ 0xbb080000, 0xbf800000, 0xbf810000, 0xbe802008 }, // fallthrough into callee
        .{ 0xbb080002, 0xbf810000, 0xbe8003ff, 0xabcdef01 }, // target inside literal
        .{ 0xbb080001, 0xbf810000, 0xbb0cffff, 0xbe802008 }, // recursion/missing paired return
        .{ 0xbb090001, 0xbf810000, 0xbe800381, 0xbe802009 }, // unaligned link
    };
    for (variants) |code| {
        var list: std.ArrayList(Instruction) = .empty;
        defer list.deinit(std.testing.allocator);
        var offset: u32 = 0;
        while (offset < code.len) {
            const inst = try decoder.decodeInstruction(offset * 4, &code, offset);
            try list.append(std.testing.allocator, inst);
            offset += inst.word_count;
        }
        try std.testing.expectError(error.InvalidScalarCall, validate(list.items, false));
    }
    var fetch = try decoder.decodeProgram(std.testing.allocator, &.{ 0xbe882100, 0xbf810000 });
    defer fetch.deinit(std.testing.allocator);
    try validate(fetch.instructions.items, true);
    try std.testing.expectError(error.InvalidScalarCall, validate(fetch.instructions.items, false));
}
