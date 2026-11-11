// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Semantic replacement of a verified NGG triangle-copy exporter. This is
//! not permission to ignore GS_EN: arbitrary geometry programs still reject.
const std = @import("std");
const gpu = @import("gpu");
const rdna2 = @import("rdna2");

pub fn triangleCopy(code: []const u32) bool {
    // Complete 275-instruction exporter, including every control-flow edge.
    // Reads three 7-dword ES records, emits the same three vertices/triangle,
    // compacts the LDS records and exports POS=words 2..5, PARAM0.xy=0..1,
    // LAYER=6. There are no user-data reads, arithmetic on payloads, external
    // writes, culling tests or generated vertices. Native triangle assembly
    // is equivalent to its allocation/compaction/primitive bookkeeping.
    // The full digest intentionally fails closed for other compiler variants.
    const bytes = std.mem.sliceAsBytes(code);
    if (bytes.len < 0x674) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..0x674], &digest, .{});
    var expected_bytes: [32]u8 = undefined;
    const expected = std.fmt.hexToBytes(&expected_bytes, "499ab81b450d4937ebbb1da4996ce4c72203981889e2e83599e6fab7282e422e") catch unreachable;
    return std.mem.eql(u8, &digest, expected);
}

/// Capture the ES payload at each LDS write, before later VGPR reuse. This
/// exporter has a fixed seven-word ABI; incomplete/different records reject.
pub fn exports(instructions: []const gpu.ShaderInstruction) ![3]rdna2.spirv.NggLdsExport {
    var words: [7]?gpu.ShaderOperand = @splat(null);
    var pcs: [7]?u32 = @splat(null);
    var base: ?gpu.ShaderOperand = null;
    var terminal: ?usize = null;
    for (instructions, 0..) |inst, i| {
        if (inst.opcode == .s_setpc_b64 and inst.src0.kind == .sgpr and inst.src0.reg == 6) terminal = i;
    }
    var i = terminal orelse return error.UnsupportedNggExportRecord;
    while (i > 0) {
        i -= 1;
        const inst = instructions[i];
        if (inst.opcode.isBranch()) break;
        if (inst.opcode != .ds_write_b32 and inst.opcode != .ds_write2_b32) continue;
        if (inst.gds) return error.UnsupportedNggExportRecord;
        if (base) |address| {
            if (!std.meta.eql(address, inst.src0)) return error.UnsupportedNggExportRecord;
        } else base = inst.src0;
        const count: usize = if (inst.opcode == .ds_write2_b32) 2 else 1;
        const offsets = [_]i32{ inst.memory_offset, inst.secondary_memory_offset };
        const sources = [_]gpu.ShaderOperand{ inst.src1, inst.src2 };
        for (offsets[0..count], sources[0..count]) |offset, source| {
            if (offset < 0 or @mod(offset, 4) != 0 or offset >= 28) return error.UnsupportedNggExportRecord;
            const index: usize = @intCast(@divTrunc(offset, 4));
            if (words[index] == null) {
                words[index] = source;
                pcs[index] = inst.pc;
            }
        }
    }
    for (words) |word| if (word == null) return error.UnsupportedNggExportRecord;
    return .{
        .{ .target = 0x0c, .enable = 15, .sources = .{ words[2].?, words[3].?, words[4].?, words[5].? }, .source_pcs = .{ pcs[2], pcs[3], pcs[4], pcs[5] } },
        .{ .target = 0x20, .enable = 3, .sources = .{ words[0].?, words[1].?, .{}, .{} }, .source_pcs = .{ pcs[0], pcs[1], null, null } },
        .{ .target = 0x0d, .enable = 4, .sources = .{ .{}, .{}, words[6].?, .{} }, .source_pcs = .{ null, null, pcs[6], null } },
    };
}

test "unknown geometry programs cannot opt into triangle-copy lowering" {
    try std.testing.expect(!triangleCopy(&.{}));
    const code: [0x674 / 4]u32 = @splat(0);
    try std.testing.expect(!triangleCopy(&code));
}

test "ES record snapshots retain source PCs and reject missing fields" {
    var instructions: [8]gpu.ShaderInstruction = undefined;
    for (instructions[0..7], 0..) |*inst, i| inst.* = .{
        .opcode = .ds_write_b32,
        .pc = @intCast(i * 8),
        .src0 = .{ .kind = .vgpr, .reg = 5 },
        .src1 = .{ .kind = .vgpr, .reg = @intCast(10 + i) },
        .memory_offset = @intCast(i * 4),
    };
    instructions[7] = .{ .opcode = .s_setpc_b64, .src0 = .{ .kind = .sgpr, .reg = 6 } };
    const result = try exports(&instructions);
    try std.testing.expectEqual(@as(u32, 12), result[0].sources[0].reg);
    try std.testing.expectEqual(@as(?u32, 16), result[0].source_pcs[0]);
    try std.testing.expectEqual(@as(u32, 16), result[2].sources[2].reg);
    instructions[3].opcode = .s_nop;
    try std.testing.expectError(error.UnsupportedNggExportRecord, exports(&instructions));
}
