// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz
// Bounded scalar-expression analysis informed by SharpEmu's
// Gen5MoveRelativeOffsets.cs, Copyright (C) 2026 SharpEmu Emulator Project,
// SPDX-License-Identifier: GPL-2.0-or-later.

//! M0 bounds for indirect VGPR moves. A missing proof retains all 256 registers.
//! Cross block boundaries only through a unique predecessor; reject joins and
//! unmodelled clobbers. A bounded scan also terminates on cyclic predecessors.
const std = @import("std");
const isa = @import("isa.zig");
const instruction = @import("instruction.zig");
const operand = @import("operand.zig");
const control_flow = @import("control_flow.zig");

pub const Values = struct {
    data: [64]u32 = undefined,
    len: usize = 0,

    fn add(self: *Values, value: u32) bool {
        for (self.data[0..self.len]) |existing| if (existing == value) return true;
        if (self.len == self.data.len) return false;
        self.data[self.len] = value;
        self.len += 1;
        return true;
    }

    fn one(value: u32) Values {
        var result = Values{};
        _ = result.add(value);
        return result;
    }
};

pub const Entry = struct { pc: u32, values: Values };

pub fn isRelative(op: isa.Opcode) bool {
    return switch (op) {
        .v_movreld_b32, .v_movrels_b32, .v_movrelsd_b32, .v_movrelsd_2_b32 => true,
        else => false,
    };
}

pub fn sourceRelative(op: isa.Opcode) bool {
    return isRelative(op) and op != .v_movreld_b32;
}

pub fn destinationRelative(op: isa.Opcode) bool {
    return isRelative(op) and op != .v_movrels_b32;
}

pub fn offset(op: isa.Opcode, m0: u32, destination: bool) u32 {
    return if (op == .v_movrelsd_2_b32) (m0 >> @as(u5, if (destination) 16 else 0)) & 0x3ff else m0;
}

pub fn find(entries: []const Entry, pc: u32) ?*const Values {
    const at = std.sort.binarySearch(Entry, entries, pc, struct {
        fn compare(key: u32, entry: Entry) std.math.Order {
            return std.math.order(key, entry.pc);
        }
    }.compare) orelse return null;
    return &entries[at].values;
}

fn constant(op: operand.Operand) ?u32 {
    return switch (op.kind) {
        .integer_inline_constant, .literal_constant, .float_inline_constant => op.value,
        .null => 0,
        else => null,
    };
}

fn scalarIndex(op: operand.Operand) ?u32 {
    return switch (op.kind) {
        .sgpr => if (op.reg < 128) op.reg else null,
        .m0 => 124,
        .vcc_lo => 106,
        .vcc_hi => 107,
        .exec_lo => 126,
        .exec_hi => 127,
        .ttmp => 108 + op.reg,
        else => null,
    };
}

const Resolver = struct {
    instructions: []const instruction.Instruction,
    first: usize,
    graph: ?*const control_flow.Graph = null,
    steps: usize = 0,

    fn value(self: *Resolver, index: usize, op: operand.Operand, depth: usize) ?Values {
        if (constant(op)) |bits| return Values.one(bits);
        const reg = scalarIndex(op) orelse return null;
        return self.register(index, reg, depth + 1);
    }

    fn register(self: *Resolver, index: usize, reg: u32, depth: usize) ?Values {
        if (depth > 8) return null;
        var at = index;
        var first = self.first;
        var block_index: ?u32 = null;
        if (self.graph) |graph| for (graph.blocks.items) |block| {
            if (index >= block.first_instruction and index < block.first_instruction + block.instruction_count) {
                first = block.first_instruction;
                block_index = block.index;
                break;
            }
        };
        while (true) {
            if (at == first) {
                const graph = self.graph orelse return null;
                const current = block_index orelse return null;
                var predecessor: ?u32 = null;
                for (graph.edges.items) |edge| if (edge.to == current) {
                    if (predecessor != null) return null;
                    predecessor = edge.from;
                };
                const previous = graph.blocks.items[predecessor orelse return null];
                block_index = previous.index;
                first = previous.first_instruction;
                at = first + previous.instruction_count;
                if (at == first) return null;
            }
            at -= 1;
            self.steps += 1;
            if (self.steps > 4096) return null;
            const inst = self.instructions[at];
            const name = @tagName(inst.opcode);
            if (inst.opcode == .unknown or inst.opcode == .unsupported or
                std.mem.startsWith(u8, name, "s_movrel")) return null;
            // Conservatively account for implicit wave-mask/carry outputs.
            if ((reg == 126 or reg == 127) and std.mem.startsWith(u8, name, "v_cmpx_")) return null;
            if ((reg == 106 or reg == 107) and std.mem.startsWith(u8, name, "v_") and
                ((std.mem.startsWith(u8, name, "v_cmp") and !std.mem.startsWith(u8, name, "v_cmpx_")) or std.mem.indexOf(u8, name, "_co_") != null or
                    std.mem.indexOf(u8, name, "_div_") != null)) return null;
            const wide = std.mem.endsWith(u8, name, "64");
            for ([_]operand.Operand{ inst.dst, inst.dst2 }, 0..) |dst, which| {
                const start = scalarIndex(dst) orelse continue;
                const count: u32 = if (inst.family == .smem) @max(1, inst.data_words) else if (wide or which == 1) 2 else 1;
                if (reg < start or reg - start >= count) continue;
                if (which != 0 or reg != start or count != 1) return null;
                return self.evaluate(at, inst, depth);
            }
        }
    }

    fn evaluate(self: *Resolver, index: usize, inst: instruction.Instruction, depth: usize) ?Values {
        if (inst.opcode == .s_mov_b32 or inst.opcode == .s_movk_i32)
            return self.value(index, inst.src0, depth);
        if (inst.opcode == .s_bfe_u32) {
            const field = constant(inst.src1) orelse return null;
            const width = (field >> 16) & 0x7f;
            if (width > 6) return null;
            var result = Values{};
            for (0..@as(usize, 1) << @intCast(width)) |v| _ = result.add(@intCast(v));
            return result;
        }
        if (inst.opcode == .s_and_b32) {
            const mask = constant(inst.src1) orelse constant(inst.src0) orelse return null;
            if (mask >= 64) return null;
            var result = Values{};
            for (0..mask + 1) |v| if (@as(u32, @intCast(v)) & ~mask == 0) {
                _ = result.add(@intCast(v));
            };
            return result;
        }
        const shift = inst.opcode == .s_lshl_b32;
        const mul = inst.opcode == .s_mul_i32;
        if (!shift and !mul and inst.opcode != .s_add_u32 and inst.opcode != .s_add_i32) return null;
        var source = inst.src0;
        const rhs = constant(inst.src1) orelse blk: {
            if (shift) return null;
            source = inst.src1;
            break :blk constant(inst.src0) orelse return null;
        };
        const inputs = self.value(index, source, depth) orelse return null;
        var result = Values{};
        for (inputs.data[0..inputs.len]) |input| {
            const output = if (shift) input << @as(u5, @truncate(rhs)) else if (mul) input *% rhs else input +% rhs;
            if (!result.add(output)) return null;
        }
        return result;
    }
};

pub fn analyze(allocator: std.mem.Allocator, instructions: []const instruction.Instruction, graph: *const control_flow.Graph) ![]Entry {
    var result: std.ArrayList(Entry) = .empty;
    errdefer result.deinit(allocator);
    // Computed targets may enter any instruction, not just a decoded leader.
    for (instructions) |inst| if (inst.opcode == .s_setpc_b64 or inst.opcode.isCall()) return result.toOwnedSlice(allocator);
    for (graph.blocks.items) |block| {
        const first: usize = block.first_instruction;
        for (first..first + block.instruction_count) |index| {
            if (!isRelative(instructions[index].opcode)) continue;
            var resolver = Resolver{ .instructions = instructions, .first = first, .graph = graph };
            const values = resolver.register(index, 124, 0) orelse continue;
            try result.append(allocator, .{ .pc = instructions[index].pc, .values = values });
        }
    }
    std.mem.sort(Entry, result.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.pc < b.pc;
        }
    }.less);
    return result.toOwnedSlice(allocator);
}

/// Registers that can be read or overwritten, including the old destination
/// for inactive lanes. Unknown bounds deliberately keep the complete file live.
pub fn vectorMask(inst: instruction.Instruction, entries: []const Entry) u256 {
    var result: u256 = 0;
    const values = find(entries, inst.pc) orelse return ~@as(u256, 0);
    for ([_]operand.Operand{ inst.src0, inst.dst }, 0..) |op, i| {
        if (op.kind != .vgpr or op.reg >= 256) continue;
        const relative = if (i == 0) sourceRelative(inst.opcode) else destinationRelative(inst.opcode);
        if (!relative) {
            result |= @as(u256, 1) << @intCast(op.reg);
            continue;
        }
        for (values.data[0..values.len]) |m0| {
            const displacement = offset(inst.opcode, m0, i == 1);
            if (displacement < 256 - op.reg) result |= @as(u256, 1) << @intCast(op.reg + displacement);
        }
    }
    return result;
}

test "relative moves bound bitfield times stride without trusting runtime input" {
    const a = std.testing.allocator;
    const code = [_]instruction.Instruction{
        .{ .pc = 0, .family = .sop2, .opcode = .s_bfe_u32, .dst = .{ .kind = .sgpr, .reg = 4 }, .src0 = .{ .kind = .sgpr, .reg = 0 }, .src1 = .{ .kind = .literal_constant, .value = 0x30005 } },
        .{ .pc = 4, .family = .sop2, .opcode = .s_mul_i32, .dst = .{ .kind = .m0 }, .src0 = .{ .kind = .sgpr, .reg = 4 }, .src1 = .{ .kind = .integer_inline_constant, .value = 5 } },
        .{ .pc = 8, .family = .vop1, .opcode = .v_movrels_b32, .src0 = .{ .kind = .vgpr, .reg = 10 }, .dst = .{ .kind = .vgpr, .reg = 80 } },
        .{ .pc = 12, .family = .sopp, .opcode = .s_endpgm },
    };
    var graph = try control_flow.buildInstructionsWithBarriers(a, &code, false);
    defer graph.deinit(a);
    const entries = try analyze(a, &code, &graph);
    defer a.free(entries);
    const values = find(entries, 8).?;
    try std.testing.expectEqualSlices(u32, &.{ 0, 5, 10, 15, 20, 25, 30, 35 }, values.data[0..values.len]);
    var expected: u256 = @as(u256, 1) << 80;
    for (values.data[0..values.len]) |v| expected |= @as(u256, 1) << @intCast(10 + v);
    try std.testing.expectEqual(expected, vectorMask(code[2], entries));
}

test "relative bounds reject scalar load pair clobbers and control-flow joins" {
    const a = std.testing.allocator;
    var code = [_]instruction.Instruction{
        .{ .pc = 0, .family = .sop1, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 5 }, .src0 = .{ .kind = .integer_inline_constant, .value = 7 } },
        .{ .pc = 4, .family = .sop1, .opcode = .s_mov_b64, .dst = .{ .kind = .sgpr, .reg = 4 } },
        .{ .pc = 8, .family = .sop1, .opcode = .s_mov_b32, .dst = .{ .kind = .m0 }, .src0 = .{ .kind = .sgpr, .reg = 5 } },
        .{ .pc = 12, .family = .vop1, .opcode = .v_movrels_b32, .src0 = .{ .kind = .vgpr }, .dst = .{ .kind = .vgpr, .reg = 20 } },
        .{ .pc = 16, .family = .sopp, .opcode = .s_endpgm },
    };
    for (0..4) |mode| {
        if (mode == 1) code[1] = .{ .pc = 4, .family = .smem, .opcode = .s_load_dwordx4, .dst = .{ .kind = .sgpr, .reg = 4 }, .data_words = 4 };
        if (mode == 2) code[1] = .{ .pc = 4, .family = .sopp, .opcode = .s_cbranch_scc0, .branch_target = 12 };
        if (mode == 3) code[1] = .{ .pc = 4, .family = .sop1, .opcode = .s_setpc_b64 };
        var graph = try control_flow.buildInstructionsWithBarriers(a, &code, false);
        defer graph.deinit(a);
        const entries = try analyze(a, &code, &graph);
        defer a.free(entries);
        try std.testing.expectEqual(@as(usize, 0), entries.len);
        try std.testing.expectEqual(~@as(u256, 0), vectorMask(code[3], entries));
    }
}

test "relative offsets preserve split M0 fields and reject wide sets" {
    try std.testing.expectEqual(@as(u32, 3), offset(.v_movrelsd_2_b32, 0x00070003, false));
    try std.testing.expectEqual(@as(u32, 7), offset(.v_movrelsd_2_b32, 0x00070003, true));
    const code = [_]instruction.Instruction{
        .{ .pc = 0, .family = .sop2, .opcode = .s_bfe_u32, .dst = .{ .kind = .m0 }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .literal_constant, .value = 0x70000 } },
        .{ .pc = 4, .family = .vop1, .opcode = .v_movreld_b32 },
    };
    var resolver = Resolver{ .instructions = &code, .first = 0 };
    try std.testing.expect(resolver.register(1, 124, 0) == null);
}

test "relative bounds cross unique predecessors and RDNA2 CMPX preserves VCC" {
    const a = std.testing.allocator;
    var code = [_]instruction.Instruction{
        .{ .pc = 0, .family = .sop2, .opcode = .s_and_b32, .dst = .{ .kind = .vcc_lo }, .src0 = .{ .kind = .sgpr }, .src1 = .{ .kind = .integer_inline_constant, .value = 3 } },
        .{ .pc = 4, .family = .vopc, .opcode = .v_cmpx_eq_u32, .dst = .{ .kind = .exec_lo } },
        .{ .pc = 8, .family = .sopp, .opcode = .s_cbranch_execz, .branch_target = 20 },
        .{ .pc = 12, .family = .sop1, .opcode = .s_mov_b32, .dst = .{ .kind = .m0 }, .src0 = .{ .kind = .vcc_lo } },
        .{ .pc = 16, .family = .vop1, .opcode = .v_movrels_b32 },
        .{ .pc = 20, .family = .sopp, .opcode = .s_endpgm },
    };
    var graph = try control_flow.buildInstructionsWithBarriers(a, &code, false);
    defer graph.deinit(a);
    const bounds = try analyze(a, &code, &graph);
    defer a.free(bounds);
    const values = find(bounds, 16).?;
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, values.data[0..values.len]);
    code[1] = .{ .pc = 4, .family = .vop2, .opcode = .v_addc_u32, .dst2 = .{ .kind = .vcc_lo } };
    const clobbered = try analyze(a, &code, &graph);
    defer a.free(clobbered);
    try std.testing.expectEqual(@as(usize, 0), clobbered.len);
}
