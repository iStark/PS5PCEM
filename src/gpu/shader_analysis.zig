// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Allocation-owned RDNA2 shader analysis used by live GPU diagnostics.

const std = @import("std");
const rdna2 = @import("rdna2");
const shaders = @import("shaders.zig");

pub const SpirvStage = rdna2.spirv.Stage;
pub const SpirvOptions = rdna2.spirv.Options;
pub const SpirvStorageBufferBinding = rdna2.spirv.StorageBufferBinding;
pub const SpirvSampledImageBinding = rdna2.spirv.SampledImageBinding;
pub const SpirvStorageImageBinding = rdna2.spirv.StorageImageBinding;
pub const SpirvStorageImageFormat = rdna2.spirv.StorageImageFormat;
pub const SpirvScalarRegister = rdna2.spirv.ScalarRegister;
pub const SpirvComputeInputs = rdna2.spirv.ComputeInputs;
pub const Operand = rdna2.Operand;
pub const OperandKind = rdna2.OperandKind;
pub const Instruction = rdna2.Instruction;
pub const Opcode = rdna2.Opcode;

pub const Error = shaders.Error || rdna2.Error || rdna2.control_flow.Error || std.mem.Allocator.Error || error{
    InstructionLimitExceeded,
    AddressOverflow,
};

pub const Analysis = struct {
    code: std.ArrayList(u32),
    program: rdna2.Program,
    graph: rdna2.control_flow.Graph,
    module: rdna2.ir.Module,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        self.module.deinit(allocator);
        self.graph.deinit(allocator);
        self.program.deinit(allocator);
        self.code.deinit(allocator);
    }

    pub fn opaqueInstructionCount(self: *const Analysis) usize {
        var result: usize = 0;
        for (self.module.nodes.items) |node| {
            if (node.operation == .opaque_instruction) result += 1;
        }
        return result;
    }

    /// Whether a compute program can change state visible after its workgroup
    /// ends. LDS-only writes are deliberately excluded because that storage
    /// dies with the dispatch unless another instruction exports it.
    pub fn hasExternalEffects(self: *const Analysis) bool {
        for (self.program.instructions.items) |inst| {
            if (inst.family == .ds and inst.gds) return true;
            switch (inst.opcode) {
                .buffer_store_format_x,
                .buffer_store_format_xy,
                .buffer_store_format_xyz,
                .buffer_store_format_xyzw,
                .buffer_store_byte,
                .buffer_store_short,
                .buffer_store_dword,
                .buffer_store_dwordx2,
                .buffer_store_dwordx3,
                .buffer_store_dwordx4,
                .buffer_atomic_swap,
                .buffer_atomic_add,
                .buffer_atomic_sub,
                .buffer_atomic_smin,
                .buffer_atomic_umin,
                .buffer_atomic_smax,
                .buffer_atomic_umax,
                .buffer_atomic_and,
                .buffer_atomic_or,
                .buffer_atomic_xor,
                .tbuffer_store_format_x,
                .tbuffer_store_format_xy,
                .tbuffer_store_format_xyz,
                .tbuffer_store_format_xyzw,
                .flat_store_byte,
                .flat_store_short,
                .flat_store_dword,
                .flat_store_dwordx2,
                .flat_store_dwordx3,
                .flat_store_dwordx4,
                .image_store,
                .image_store_mip,
                .image_atomic_add,
                .image_atomic_umin,
                .image_atomic_umax,
                .image_atomic_and,
                .image_atomic_or,
                .image_atomic_xor,
                .s_sendmsg,
                .exp,
                => return true,
                .unsupported => switch (inst.family) {
                    .vop1, .vop2, .vop3, .vop3p, .vopc, .vintrp => {},
                    else => return true,
                },
                else => {},
            }
        }
        return false;
    }

    pub fn translateSpirv(
        self: *const Analysis,
        allocator: std.mem.Allocator,
        options: SpirvOptions,
    ) rdna2.spirv.Error!rdna2.spirv.Module {
        return rdna2.translateSpirv(allocator, &self.program, options);
    }
};

fn readNextWord(reader: shaders.MemoryReader, address: u64, code: *std.ArrayList(u32), allocator: std.mem.Allocator) Error!void {
    const byte_offset = std.math.mul(u64, code.items.len, 4) catch return Error.AddressOverflow;
    const word_address = std.math.add(u64, address, byte_offset) catch return Error.AddressOverflow;
    try code.append(allocator, try reader.readU32(word_address));
}

/// Reads only as many guest words as decoding requires. This matters at the end
/// of a mapped shader allocation: diagnostics must not probe an arbitrary 16 KiB
/// window merely to find `s_endpgm` near the beginning.
pub fn decode(
    allocator: std.mem.Allocator,
    reader: shaders.MemoryReader,
    address: u64,
    instruction_limit: usize,
) Error!Analysis {
    var code: std.ArrayList(u32) = .empty;
    errdefer code.deinit(allocator);
    var instructions: std.ArrayList(rdna2.Instruction) = .empty;
    errdefer instructions.deinit(allocator);
    var branch_targets: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer branch_targets.deinit(allocator);

    var word_index: u32 = 0;
    while (instructions.items.len < instruction_limit) {
        while (code.items.len <= word_index) try readNextWord(reader, address, &code, allocator);
        const pc = word_index * 4;
        const inst = retry: while (true) {
            break :retry rdna2.decodeInstruction(pc, code.items, word_index) catch |err| switch (err) {
                error.TruncatedInstruction, error.MissingLiteralConstant => {
                    try readNextWord(reader, address, &code, allocator);
                    continue;
                },
                else => {
                    std.debug.print(
                        "[gpu shader] decode failed program=0x{x} pc=0x{x} word=0x{x:0>8} error={s}\n",
                        .{ address, pc, code.items[word_index], @errorName(err) },
                    );
                    return err;
                },
            };
        };
        try instructions.append(allocator, inst);
        word_index += inst.word_count;
        if (inst.opcode.isBranch()) try branch_targets.put(allocator, inst.branch_target, {});
        if (inst.opcode.isProgramEnd() and !branch_targets.contains(word_index * 4)) break;
    } else return Error.InstructionLimitExceeded;

    var program = rdna2.Program{ .code = code.items, .instructions = instructions };
    errdefer program.deinit(allocator);
    var graph = try rdna2.buildControlFlow(allocator, &program);
    errdefer graph.deinit(allocator);
    const module = try rdna2.lowerIr(allocator, &program);
    return .{ .code = code, .program = program, .graph = graph, .module = module };
}

const TestMemory = struct {
    bytes: [64]u8 = @splat(0),

    fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
        const self: *TestMemory = @ptrCast(@alignCast(context.?));
        const start: usize = @intCast(address);
        if (start + destination.len > self.bytes.len) return false;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
        return true;
    }

    fn reader(self: *TestMemory) shaders.MemoryReader {
        return .{ .context = self, .read_fn = read };
    }

    fn word(self: *TestMemory, offset: usize, value: u32) void {
        std.mem.writeInt(u32, self.bytes[offset..][0..4], value, .little);
    }
};

test "analysis reads through literals and owns CFG plus typed IR" {
    var memory = TestMemory{};
    memory.word(0, (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255);
    memory.word(4, 0x3f80_0000);
    memory.word(8, 0xbf81_0000);
    var analysis = try decode(std.testing.allocator, memory.reader(), 0, 16);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), analysis.code.items.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.program.instructions.items.len);
    try std.testing.expectEqual(@as(usize, 1), analysis.graph.blocks.items.len);
    try std.testing.expectEqual(rdna2.ir.Operation.move, analysis.module.nodes.items[0].operation);
    var spirv = try analysis.translateSpirv(std.testing.allocator, .{ .stage = .compute });
    defer spirv.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0x0723_0203), spirv.words[0]);
    try std.testing.expect(!analysis.hasExternalEffects());
}

test "analysis identifies a global buffer store as externally visible" {
    var memory = TestMemory{};
    memory.word(0, 0xe000_0000 | (@as(u32, 0x1c) << 18)); // buffer_store_dword
    memory.word(4, 0); // vdata=v0, vaddr=v0, srsrc=s0, soffset=0
    memory.word(8, 0xbf81_0000);
    var analysis = try decode(std.testing.allocator, memory.reader(), 0, 16);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expect(analysis.hasExternalEffects());
}

test "analysis enforces its instruction safety limit" {
    var memory = TestMemory{};
    memory.word(0, 0xbf80_0000); // s_nop
    memory.word(4, 0xbf80_0000);
    try std.testing.expectError(
        Error.InstructionLimitExceeded,
        decode(std.testing.allocator, memory.reader(), 0, 2),
    );
}
