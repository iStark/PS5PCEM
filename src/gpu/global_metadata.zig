// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Small parameter blocks shared by SMEM and scalar-base GLOBAL reads.
const std = @import("std");
const rdna2 = @import("rdna2");
const definitions = @import("index_bounds.zig");

pub const maximum_bytes = 64 * 1024;
pub const Region = struct { register: u32, size: u32 };
pub const PageRange = struct { address: u64, size: usize };

/// Indexed GLOBAL fields can follow the last fixed SMEM field. Expose the
/// containing pages, as for pointer-form SMEM, only after the memory reader
/// validates each page. A reservation alone is never readable evidence.
pub fn pageRange(address: u64, size: u32) ?PageRange {
    if (address == 0 or size == 0 or size > maximum_bytes) return null;
    const end = std.math.add(u64, address, size) catch return null;
    const rounded = std.math.add(u64, end, 4095) catch return null;
    const start = address & ~@as(u64, 4095);
    return .{ .address = start, .size = @intCast((rounded & ~@as(u64, 4095)) - start) };
}

test "GLOBAL metadata page spans retain edge fields without overflowing" {
    try std.testing.expectEqual(PageRange{ .address = 0x2000, .size = 4096 }, pageRange(0x24f0, 172).?);
    try std.testing.expectEqual(PageRange{ .address = 0x2000, .size = 8192 }, pageRange(0x2ff0, 772).?);
    try std.testing.expectEqual(PageRange{ .address = 0x2000, .size = 4096 }, pageRange(0x2000, 4096).?);
    try std.testing.expect(pageRange(0, 16) == null);
    try std.testing.expect(pageRange(0x2000, 0) == null);
    try std.testing.expect(pageRange(0x2000, maximum_bytes + 1) == null);
    try std.testing.expect(pageRange(std.math.maxInt(u64) - 8, 16) == null);
}

fn entryPair(code: []const rdna2.Instruction, graph: *const rdna2.control_flow.Graph, before: usize, register: u32, first: u32, count: u32, cache: ?*definitions.ScalarDefinitionCache) bool {
    if (register >= 127 or register < first or register + 1 >= @as(u64, first) + count) return false;
    for (0..2) |word| {
        const source = register + @as(u32, @intCast(word));
        const origin = (if (cache) |retained| retained.definition(before, source) else definitions.scalarDefinition(code, graph, before, source)) orelse return false;
        if (origin != .entry) return false;
    }
    return true;
}

/// The SMEM accesses establish the extent of a parameter block, not the
/// range of every possible GLOBAL address. The backend validates and captures
/// its containing pages; reads outside them still fault. No guest bytes or
/// pointer values are cached here, and rewritten USER_DATA pairs are rejected.
pub fn collect(code: []const rdna2.Instruction, graph: *const rdna2.control_flow.Graph, first: u32, count: u32, output: []Region) usize {
    return collectCached(code, graph, first, count, output, null);
}

pub fn collectCached(code: []const rdna2.Instruction, graph: *const rdna2.control_flow.Graph, first: u32, count: u32, output: []Region, retained: ?*definitions.ScalarDefinitionCache) usize {
    const cache = if (retained) |value| if (value.matches(code, graph)) value else null else null;
    var roots: [128]bool = @splat(false);
    var any = false;
    for (code, 0..) |inst, index| {
        switch (inst.opcode) {
            .flat_load_dword, .flat_load_dwordx2, .flat_load_dwordx3, .flat_load_dwordx4 => {},
            else => continue,
        }
        if (inst.memory_segment != 2 or inst.src1.kind != .sgpr or
            !entryPair(code, graph, index, inst.src1.reg, first, count, cache)) continue;
        roots[inst.src1.reg] = true;
        any = true;
    }
    if (!any) return 0;
    var extents: [128]u32 = @splat(0);
    for (code, 0..) |inst, index| {
        switch (inst.opcode) {
            .s_load_dword, .s_load_dwordx2, .s_load_dwordx4, .s_load_dwordx8, .s_load_dwordx16 => {},
            else => continue,
        }
        if (inst.src0.kind != .sgpr or inst.src0.reg >= roots.len or !roots[inst.src0.reg] or
            inst.memory_offset < 0 or inst.data_words == 0 or
            !entryPair(code, graph, index, inst.src0.reg, first, count, cache)) continue;
        const extra: u64 = switch (inst.src1.kind) {
            .null => 0,
            .integer_inline_constant, .literal_constant => inst.src1.value,
            else => continue,
        };
        if (extra > maximum_bytes) continue;
        const end = @as(u64, @intCast(inst.memory_offset)) + extra + @as(u64, inst.data_words) * 4;
        if (end > maximum_bytes) continue;
        extents[inst.src0.reg] = @max(extents[inst.src0.reg], @as(u32, @intCast(end)));
    }
    var length: usize = 0;
    for (extents, 0..) |size, register| {
        if (size == 0 or length == output.len) continue;
        output[length] = .{ .register = @intCast(register), .size = size };
        length += 1;
    }
    return length;
}

test "GLOBAL metadata rejects a scalar base clobbered on just one incoming path" {
    const code = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_load_dword, .src0 = .{ .kind = .sgpr, .reg = 2 }, .src1 = .{ .kind = .null }, .dst = .{ .kind = .sgpr, .reg = 8 }, .memory_offset = 768, .data_words = 1 },
        .{ .pc = 8, .opcode = .s_cbranch_scc0, .family = .sopp, .branch_target = 16 },
        .{ .pc = 12, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 3 } },
        .{ .pc = 16, .opcode = .flat_load_dwordx4, .memory_segment = 2, .src0 = .{ .kind = .vgpr }, .src1 = .{ .kind = .sgpr, .reg = 2 }, .memory_offset = 236, .data_words = 4 },
        .{ .pc = 24, .opcode = .s_endpgm },
    };
    var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &code);
    defer graph.deinit(std.testing.allocator);
    var regions: [4]Region = undefined;
    try std.testing.expectEqual(@as(usize, 0), collect(&code, &graph, 2, 2, &regions));
}

test "GLOBAL metadata shares only bounded unchanged entry parameter blocks" {
    var code = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_load_dword, .src0 = .{ .kind = .sgpr, .reg = 2 }, .src1 = .{ .kind = .null }, .dst = .{ .kind = .sgpr, .reg = 8 }, .memory_offset = 768, .data_words = 1 },
        .{ .pc = 8, .opcode = .s_nop },
        .{ .pc = 12, .opcode = .flat_load_dwordx4, .memory_segment = 2, .src0 = .{ .kind = .vgpr }, .src1 = .{ .kind = .sgpr, .reg = 2 }, .memory_offset = 236, .data_words = 4 },
        .{ .pc = 20, .opcode = .s_endpgm },
    };
    const original = code;
    for (0..10) |variant| {
        code = original;
        switch (variant) {
            1 => code[2].memory_segment = 0,
            2 => code[2].opcode = .flat_store_dwordx4,
            3 => code[1] = .{ .pc = 8, .opcode = .s_mov_b32, .dst = .{ .kind = .sgpr, .reg = 3 } },
            4 => code[0].src1 = .{ .kind = .sgpr, .reg = 10 },
            5 => code[0].memory_offset = maximum_bytes,
            6 => code[0].memory_offset = -4,
            7 => code[0].src0.reg = 4,
            8 => code[0].src1 = .{ .kind = .literal_constant, .value = 64 },
            9 => code[0].src1 = .{ .kind = .literal_constant, .value = 0xffff_ffff },
            else => {},
        }
        var graph = try rdna2.control_flow.buildInstructions(std.testing.allocator, &code);
        defer graph.deinit(std.testing.allocator);
        var regions: [4]Region = undefined;
        const length = collect(&code, &graph, 2, 2, &regions);
        var cache = definitions.ScalarDefinitionCache.init(std.testing.allocator, &code, &graph);
        defer cache.deinit();
        var cached_regions: [4]Region = undefined;
        for (0..2) |_| {
            const cached_count = collectCached(&code, &graph, 2, 2, &cached_regions, &cache);
            try std.testing.expectEqual(length, cached_count);
            try std.testing.expectEqualSlices(Region, regions[0..length], cached_regions[0..cached_count]);
        }
        if (variant == 0 or variant == 8) {
            try std.testing.expectEqual(@as(usize, 1), length);
            try std.testing.expectEqual(Region{ .register = 2, .size = if (variant == 8) 836 else 772 }, regions[0]);
            try std.testing.expectEqual(@as(usize, 0), collect(&code, &graph, 2, 1, &regions));
        } else try std.testing.expectEqual(@as(usize, 0), length);
    }
}
