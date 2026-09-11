// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Allocation-owned RDNA2 shader analysis used by live GPU diagnostics.

const std = @import("std");
const rdna2 = @import("rdna2");
const shaders = @import("shaders.zig");
const ScalarDefinitionCache = @import("index_bounds.zig").ScalarDefinitionCache;
const CheckpointPlan = @import("resource_checkpoints.zig").Plan;

pub const SpirvStage = rdna2.spirv.Stage;
pub const SpirvOptions = rdna2.spirv.Options;
pub const SpirvStorageBufferBinding = rdna2.spirv.StorageBufferBinding;
pub const SpirvBufferLookup = rdna2.spirv.buffer_lookup;
pub const SpirvSampledImageBinding = rdna2.spirv.SampledImageBinding;
pub const SpirvStorageImageBinding = rdna2.spirv.StorageImageBinding;
pub const SpirvStorageImageFormat = rdna2.spirv.StorageImageFormat;
pub const SpirvScalarRegister = rdna2.spirv.ScalarRegister;
pub const SpirvComputeInputs = rdna2.spirv.ComputeInputs;
pub const SpirvNggLdsExport = rdna2.spirv.NggLdsExport;
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
    pipeline_options: rdna2.ir.PipelineOptions = .{},
    scalar_definitions: ?*ScalarDefinitionCache = null,
    resource_checkpoints: ?CheckpointPlan = null,
    uniform_specializations: ?*UniformSpecializations = null,
    translation_key: ?rdna2.cache_key.ProgramKey = null,

    /// Call only after reconstruction, before retaining an immutable analysis.
    pub fn enableTranslationKey(self: *Analysis, allocator: std.mem.Allocator) !void {
        if (self.translation_key != null) return;
        self.translation_key = try rdna2.cache_key.ProgramKey.init(allocator, &self.program, self.pipeline_options);
    }

    pub fn enableUniformSpecializations(self: *Analysis, allocator: std.mem.Allocator) !void {
        if (self.uniform_specializations != null) return;
        const cache = try allocator.create(UniformSpecializations);
        cache.* = .{};
        self.uniform_specializations = cache;
    }

    /// Retain locations only after decoding/reconstruction has finished.
    /// Dispatch-local branch specializations start without the parent's plan.
    pub fn enableResourceCheckpoints(self: *Analysis, allocator: std.mem.Allocator) !void {
        if (self.resource_checkpoints != null) return;
        self.resource_checkpoints = try CheckpointPlan.init(allocator, self.program.instructions.items);
    }

    /// Enable only once this analysis is retained as an immutable program.
    /// Specialized analyses deliberately start with their own empty state.
    pub fn enableScalarDefinitionCache(self: *Analysis, allocator: std.mem.Allocator) !void {
        if (self.scalar_definitions != null) return;
        const cache = try allocator.create(ScalarDefinitionCache);
        cache.* = ScalarDefinitionCache.init(allocator, self.program.instructions.items, &self.graph);
        self.scalar_definitions = cache;
    }

    pub fn scalarIndexUpperBound(self: *const Analysis, before: usize, register: u32) ?u32 {
        const instructions = self.program.instructions.items;
        if (self.scalar_definitions) |cache| {
            if (cache.matches(instructions, &self.graph)) return cache.indexUpperBound(before, register);
        }
        return @import("index_bounds.zig").scalarUpperBound(instructions, &self.graph, before, register);
    }

    pub fn indexLaneDefinitions(self: *const Analysis, before: usize, register: u32, scalar: bool) ?@import("index_bounds.zig").LaneDefinitions {
        const instructions = self.program.instructions.items;
        if (self.scalar_definitions) |cache| {
            if (cache.matches(instructions, &self.graph)) return cache.indexLaneDefinitions(before, register, scalar);
        }
        return if (scalar)
            @import("index_bounds.zig").scalarLaneDefinitions(instructions, &self.graph, before, register, 0)
        else
            @import("index_bounds.zig").vectorLaneDefinitions(instructions, &self.graph, before, register);
    }

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        if (self.translation_key) |key| key.deinit(allocator);
        if (self.uniform_specializations) |cache| {
            cache.deinit(allocator);
            allocator.destroy(cache);
        }
        if (self.resource_checkpoints) |*plan| plan.deinit(allocator);
        if (self.scalar_definitions) |cache| {
            cache.deinit();
            allocator.destroy(cache);
        }
        self.module.deinit(allocator);
        self.graph.deinit(allocator);
        self.program.deinit(allocator);
        self.code.deinit(allocator);
    }

    /// Resource staging and SPIR-V must see exactly the same live branches.
    /// This analysis is dispatch-local; the cached decoded shader stays intact.
    pub fn specializeUniformBranches(
        self: *const Analysis,
        allocator: std.mem.Allocator,
        reader: shaders.MemoryReader,
        bindings: *const shaders.StageBindings,
    ) !?Analysis {
        var instructions = (try @import("scalar_provenance.zig").pruneUniformBranches(
            allocator,
            reader,
            bindings,
            self.program.instructions.items,
            &self.graph,
        )) orelse return null;
        errdefer instructions.deinit(allocator);
        return try self.buildUniformSpecialization(allocator, instructions);
    }

    /// Re-evaluate guest memory on every dispatch; retain only the resulting
    /// immutable program and its static analysis. Leases protect nested users.
    pub fn acquireUniformSpecialization(
        self: *const Analysis,
        allocator: std.mem.Allocator,
        reader: shaders.MemoryReader,
        bindings: *const shaders.StageBindings,
        use_cache: bool,
    ) !?UniformSpecializations.Lease {
        const active_cache = if (use_cache) self.uniform_specializations else null;
        var instructions = (try @import("scalar_provenance.zig").pruneUniformBranches(
            allocator,
            reader,
            bindings,
            self.program.instructions.items,
            &self.graph,
        )) orelse return null;
        var instructions_owned = true;
        defer if (instructions_owned) instructions.deinit(allocator);
        if (active_cache) |cache| {
            cache.sequence +%= 1;
            for (&cache.entries) |*entry| {
                const value = entry.analysis orelse continue;
                if (!UniformSpecializations.samePrunedInstructions(value.program.instructions.items, instructions.items)) continue;
                entry.pins += 1;
                entry.sequence = cache.sequence;
                return .{ .analysis = value, .entry = entry, .allocator = allocator, .reused = true };
            }
        }
        const value = try allocator.create(Analysis);
        errdefer allocator.destroy(value);
        value.* = try self.buildUniformSpecialization(allocator, instructions);
        instructions_owned = false;
        if (active_cache != null) {
            value.enableScalarDefinitionCache(allocator) catch {};
            value.enableResourceCheckpoints(allocator) catch {};
            value.enableTranslationKey(allocator) catch {};
        }
        if (active_cache) |cache| {
            var victim: ?*UniformSpecializations.Entry = null;
            for (&cache.entries) |*entry| {
                if (entry.pins != 0) continue;
                if (victim == null or entry.analysis == null or entry.sequence < victim.?.sequence) victim = entry;
                if (entry.analysis == null) break;
            }
            if (victim) |entry| {
                if (entry.analysis) |old| {
                    old.deinit(allocator);
                    allocator.destroy(old);
                }
                entry.* = .{ .analysis = value, .pins = 1, .sequence = cache.sequence };
                return .{ .analysis = value, .entry = entry, .allocator = allocator };
            }
        }
        return .{ .analysis = value, .entry = null, .allocator = allocator };
    }

    fn buildUniformSpecialization(self: *const Analysis, allocator: std.mem.Allocator, instructions: std.ArrayList(rdna2.Instruction)) !Analysis {
        var code: std.ArrayList(u32) = .empty;
        errdefer code.deinit(allocator);
        try code.appendSlice(allocator, self.code.items);
        const program = rdna2.Program{ .code = code.items, .instructions = instructions };
        var graph = try rdna2.buildControlFlow(allocator, &program);
        errdefer graph.deinit(allocator);
        const module = try rdna2.lowerIrWithOptions(allocator, &program, self.pipeline_options);
        return .{ .code = code, .program = program, .graph = graph, .module = module, .pipeline_options = self.pipeline_options };
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
        return self.hasEffectsBeyondRaster(true);
    }

    /// Raster exports may be hidden by a fullscreen movie; storage writes and
    /// unknown non-ALU instructions still have to execute.
    pub fn hasNonRasterEffects(self: *const Analysis) bool {
        return self.hasEffectsBeyondRaster(false);
    }

    fn hasEffectsBeyondRaster(self: *const Analysis, include_exports: bool) bool {
        const instructions = if (self.pipeline_options.enable_typed_ir)
            self.module.instructions.items
        else
            self.program.instructions.items;
        for (instructions) |inst| {
            if (inst.family == .ds and inst.gds) return true;
            switch (inst.opcode) {
                .buffer_store_format_x,
                .buffer_store_format_xy,
                .buffer_store_format_xyz,
                .buffer_store_format_xyzw,
                .buffer_store_format_d16_x,
                .buffer_store_format_d16_hi_x,
                .buffer_store_format_d16_xy,
                .buffer_store_format_d16_xyz,
                .buffer_store_format_d16_xyzw,
                .buffer_store_byte,
                .buffer_store_short,
                .buffer_store_byte_d16_hi,
                .buffer_store_short_d16_hi,
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
                .image_atomic_fmax,
                => return true,
                // GS_ALLOC_REQ reserves raster export space. It has no work
                // to publish when the entire draw's raster exports are hidden.
                .s_sendmsg => if (include_exports or inst.src0.value != 9) return true,
                .exp => if (include_exports) return true,
                .unsupported => switch (inst.family) {
                    .vop1, .vop2, .vop3, .vop3p, .vopc, .vintrp => {},
                    else => return true,
                },
                else => {},
            }
        }
        return false;
    }

    /// Whether a compute program can publish data through a guest-addressable
    /// buffer (or GDS). This excludes image-only post-processing, allowing a
    /// title startup fast path to retain command/visibility-list generation
    /// without paying for every full-resolution image pass.
    pub fn hasBufferExternalEffects(self: *const Analysis) bool {
        const instructions = if (self.pipeline_options.enable_typed_ir)
            self.module.instructions.items
        else
            self.program.instructions.items;
        for (instructions) |inst| {
            if (inst.family == .ds and inst.gds) return true;
            switch (inst.opcode) {
                .buffer_store_format_x,
                .buffer_store_format_xy,
                .buffer_store_format_xyz,
                .buffer_store_format_xyzw,
                .buffer_store_format_d16_x,
                .buffer_store_format_d16_hi_x,
                .buffer_store_format_d16_xy,
                .buffer_store_format_d16_xyz,
                .buffer_store_format_d16_xyzw,
                .buffer_store_byte,
                .buffer_store_short,
                .buffer_store_byte_d16_hi,
                .buffer_store_short_d16_hi,
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
                => return true,
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
        if (!self.pipeline_options.enable_typed_ir) {
            return rdna2.translateSpirv(allocator, &self.program, options);
        }
        return rdna2.translateIrSpirv(allocator, &self.module, options);
    }
};

pub const UniformSpecializations = struct {
    const Entry = struct {
        analysis: ?*Analysis = null,
        pins: usize = 0,
        sequence: u64 = 0,
    };
    entries: [4]Entry = @splat(.{}),
    sequence: u64 = 0,

    pub const Lease = struct {
        analysis: *Analysis,
        entry: ?*Entry,
        allocator: std.mem.Allocator,
        reused: bool = false,

        pub fn release(self: *Lease) void {
            if (self.entry) |entry| {
                std.debug.assert(entry.pins != 0);
                entry.pins -= 1;
            } else {
                self.analysis.deinit(self.allocator);
                self.allocator.destroy(self.analysis);
            }
            self.* = undefined;
        }
    };

    fn samePrunedInstructions(a: []const rdna2.Instruction, b: []const rdna2.Instruction) bool {
        if (a.len != b.len) return false;
        // This cache belongs to one immutable decoded parent. Pruning only
        // keeps an instruction, replaces it with makeNop, or changes a proven
        // conditional branch to s_branch. PC/opcode therefore identify every
        // rewrite exactly, without comparing the NaN float views of literals.
        for (a, b) |lhs, rhs| if (lhs.pc != rhs.pc or lhs.opcode != rhs.opcode) return false;
        return true;
    }

    fn deinit(self: *UniformSpecializations, allocator: std.mem.Allocator) void {
        for (&self.entries) |*entry| {
            std.debug.assert(entry.pins == 0);
            if (entry.analysis) |value| {
                value.deinit(allocator);
                allocator.destroy(value);
            }
        }
    }
};

fn readNextWord(
    reader: shaders.MemoryReader,
    address: u64,
    code: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
    word_limit: ?usize,
) Error!void {
    if (word_limit) |limit| {
        if (code.items.len >= limit) return Error.MissingEndProgram;
    }
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
    return decodeWithOptions(allocator, reader, address, instruction_limit, .{});
}

pub fn decodeWithOptions(
    allocator: std.mem.Allocator,
    reader: shaders.MemoryReader,
    address: u64,
    instruction_limit: usize,
    pipeline_options: rdna2.ir.PipelineOptions,
) Error!Analysis {
    return decodeImpl(allocator, reader, address, instruction_limit, null, pipeline_options);
}

/// Decodes a program without ever reading beyond the AGC shader allocation.
/// `shader_size_bytes` includes the instruction stream and any trailing AGC
/// metadata; normal end markers stop before that metadata is interpreted.
pub fn decodeBounded(
    allocator: std.mem.Allocator,
    reader: shaders.MemoryReader,
    address: u64,
    instruction_limit: usize,
    shader_size_bytes: usize,
) Error!Analysis {
    return decodeBoundedWithOptions(
        allocator,
        reader,
        address,
        instruction_limit,
        shader_size_bytes,
        .{},
    );
}

pub fn decodeBoundedWithOptions(
    allocator: std.mem.Allocator,
    reader: shaders.MemoryReader,
    address: u64,
    instruction_limit: usize,
    shader_size_bytes: usize,
    pipeline_options: rdna2.ir.PipelineOptions,
) Error!Analysis {
    if (shader_size_bytes < @sizeOf(u32)) return Error.EmptyProgram;
    return decodeImpl(
        allocator,
        reader,
        address,
        instruction_limit,
        shader_size_bytes / @sizeOf(u32),
        pipeline_options,
    );
}

fn decodeImpl(
    allocator: std.mem.Allocator,
    reader: shaders.MemoryReader,
    address: u64,
    instruction_limit: usize,
    word_limit: ?usize,
    pipeline_options: rdna2.ir.PipelineOptions,
) Error!Analysis {
    var code: std.ArrayList(u32) = .empty;
    errdefer code.deinit(allocator);
    var instructions: std.ArrayList(rdna2.Instruction) = .empty;
    errdefer instructions.deinit(allocator);
    var furthest_branch_target: u32 = 0;

    var word_index: u32 = 0;
    while (instructions.items.len < instruction_limit) {
        while (code.items.len <= word_index) try readNextWord(reader, address, &code, allocator, word_limit);
        const pc = word_index * 4;
        const inst = retry: while (true) {
            break :retry rdna2.decodeInstruction(pc, code.items, word_index) catch |err| switch (err) {
                error.TruncatedInstruction, error.MissingLiteralConstant => {
                    try readNextWord(reader, address, &code, allocator, word_limit);
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
        if (inst.opcode.isBranch()) furthest_branch_target = @max(furthest_branch_target, inst.branch_target);
        // An earlier path can jump beyond this return and intervening padding.
        // Decode through every referenced forward target before ending the body.
        if (isProgramTerminator(inst) and furthest_branch_target < word_index * 4) break;
    } else {
        std.debug.print(
            "[gpu shader] instruction limit program=0x{x} instructions={d} words={d} pc=0x{x} first=0x{x:0>8} last=0x{x:0>8}\n",
            .{
                address,
                instructions.items.len,
                code.items.len,
                word_index * 4,
                if (code.items.len != 0) code.items[0] else 0,
                if (code.items.len != 0) code.items[code.items.len - 1] else 0,
            },
        );
        return Error.InstructionLimitExceeded;
    }

    const program = rdna2.Program{ .code = code.items, .instructions = instructions };
    // `instructions` owns this allocation until Analysis is returned. Keeping
    // a second error cleanup on Program double-frees it when CFG creation fails.
    var graph = try rdna2.buildControlFlow(allocator, &program);
    errdefer graph.deinit(allocator);
    const module = try rdna2.lowerIrWithOptions(allocator, &program, pipeline_options);
    return .{
        .code = code,
        .program = program,
        .graph = graph,
        .module = module,
        .pipeline_options = pipeline_options,
    };
}

fn isHardwareNggSetpc(inst: rdna2.Instruction) bool {
    return inst.opcode == .s_setpc_b64 and inst.src0.kind == .sgpr and inst.src0.reg == 6;
}

fn isProgramTerminator(inst: rdna2.Instruction) bool {
    // A merged local/export shader transfers to the hardware continuation
    // through s6:s7. Its following allocation bytes can be AGC metadata,
    // with no intervening END_PGM. Other SETPC sources can enter a fetch
    // shader and must retain the following vertex continuation.
    return inst.opcode.isProgramEnd() or isHardwareNggSetpc(inst);
}

/// Replaces a non-s6 `S_SETPC_B64` with the fetch-shader body, dropping the
/// fetch shader's own returning SETPC so execution falls into the VS
/// continuation. Fetch shaders are typically straight-line attribute loads.
pub fn inlineFetchShader(
    allocator: std.mem.Allocator,
    vertex: []const rdna2.Instruction,
    fetch: []const rdna2.Instruction,
    out: *std.ArrayList(rdna2.Instruction),
) Error!bool {
    if (fetch.len == 0) return false;
    var setpc_index: ?usize = null;
    for (vertex, 0..) |inst, index| {
        if (inst.opcode != .s_setpc_b64 or isHardwareNggSetpc(inst)) continue;
        setpc_index = index;
    }
    const splice = setpc_index orelse return false;

    var fetch_len = fetch.len;
    if (fetch_len != 0 and fetch[fetch_len - 1].opcode == .s_setpc_b64) fetch_len -= 1;
    if (fetch_len != 0 and fetch[fetch_len - 1].opcode.isProgramEnd()) fetch_len -= 1;
    if (fetch_len == 0) return false;

    const fetch_base: u32 = 0x4000_0000;
    try out.ensureTotalCapacity(allocator, vertex.len + fetch_len);
    try out.appendSlice(allocator, vertex[0..splice]);
    for (fetch[0..fetch_len]) |inst| {
        var relocated = inst;
        relocated.pc = fetch_base +% inst.pc;
        if (relocated.opcode.isBranch()) relocated.branch_target = fetch_base +% inst.branch_target;
        try out.append(allocator, relocated);
    }
    try out.appendSlice(allocator, vertex[splice + 1 ..]);
    return true;
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
    try std.testing.expect(analysis.hasBufferExternalEffects());
    try std.testing.expect(analysis.hasNonRasterEffects());
}

test "analysis follows a forward branch beyond an early return and padding" {
    var memory = TestMemory{};
    memory.word(0, 0xbf85_0003); // s_cbranch_scc1 -> pc 16
    memory.word(4, 0xbf81_0000); // s_endpgm on the other path
    memory.word(8, 0xbf80_0000); // padding
    memory.word(12, 0xbf80_0000);
    memory.word(16, 0xbe80_0381); // s_mov_b32 s0, 1
    memory.word(20, 0xbf81_0000);
    var analysis = try decode(std.testing.allocator, memory.reader(), 0, 16);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 20), analysis.program.instructions.items[5].pc);
    try std.testing.expect(analysis.graph.blockForPc(16) != null);
}

test "analysis stops at hardware continuation before trailing shader metadata" {
    var memory = TestMemory{};
    memory.word(0, 0xbe80_0381); // s_mov_b32 s0, 1
    memory.word(4, 0xbefd_2106); // s_setpc_b64 s[6:7]
    memory.word(8, 0x2010_00e0); // Metadata, not a valid instruction.
    var analysis = try decodeBounded(std.testing.allocator, memory.reader(), 0, 16, 12);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), analysis.code.items.len);
    try std.testing.expectEqual(rdna2.Opcode.s_setpc_b64, analysis.program.instructions.items[1].opcode);
}

test "hardware continuation preserves reachable forward paths and ordinary fetch returns" {
    var memory = TestMemory{};
    memory.word(0, 0xbf85_0002); // s_cbranch_scc1 -> pc 12
    memory.word(4, 0xbefd_2106); // Hardware continuation on the other path.
    memory.word(8, 0xbf80_0000);
    memory.word(12, 0xbefd_2102); // Ordinary fetch shader; continuation follows.
    memory.word(16, 0xbe80_0381);
    memory.word(20, 0xbf81_0000);
    var analysis = try decode(std.testing.allocator, memory.reader(), 0, 16);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 6), analysis.code.items.len);
    try std.testing.expect(analysis.graph.blockForPc(12) != null);
    try std.testing.expectEqual(@as(u32, 20), analysis.program.instructions.items[5].pc);
}

test "analysis releases an invalid branch target without freeing instructions twice" {
    var memory = TestMemory{};
    memory.word(0, 0xbf82_0001); // s_branch -> pc 8, inside the literal below
    memory.word(4, 0xbe80_03ff); // s_mov_b32 s0, literal
    memory.word(8, 0x1234_5678);
    memory.word(12, 0xbf81_0000);
    try std.testing.expectError(error.InvalidBranchTarget, decode(std.testing.allocator, memory.reader(), 0, 16));
}

test "analysis owns definitions across moves but not shader replacement or uniform specialization" {
    var memory = TestMemory{};
    const code = [_]u32{
        0xf400_1a80, 125 << 25, // s_load_dword vcc_lo, s0:s1
        0xbefe_04c1, // s_mov_b64 exec, -1
        0xbf8c_007f, // s_waitcnt
        0xbf07_6a80, // s_cmp_lg_u32 0, vcc_lo
        0xbf84_0002, // s_cbranch_scc0 end
        0xf020_0f28, 0x0002_0400, // conditional image_store
        0xbf81_0000,
    };
    for (code, 0..) |word, index| memory.word(index * 4, word);
    var decoded = try decode(std.testing.allocator, memory.reader(), 0, 16);
    try decoded.enableScalarDefinitionCache(std.testing.allocator);
    try decoded.enableResourceCheckpoints(std.testing.allocator);
    try decoded.enableTranslationKey(std.testing.allocator);
    var moved = decoded;
    defer moved.deinit(std.testing.allocator);
    const cache = moved.scalar_definitions.?;
    const key_bytes = moved.translation_key.?.bytes;
    try moved.enableTranslationKey(std.testing.allocator);
    try std.testing.expectEqual(key_bytes.ptr, moved.translation_key.?.bytes.ptr);
    try moved.enableScalarDefinitionCache(std.testing.allocator);
    try std.testing.expectEqual(cache, moved.scalar_definitions.?);
    const checkpoint_pcs = moved.resource_checkpoints.?.resource;
    try moved.enableResourceCheckpoints(std.testing.allocator);
    try std.testing.expectEqual(checkpoint_pcs.ptr, moved.resource_checkpoints.?.resource.ptr);
    try std.testing.expect(moved.resource_checkpoints.?.matches(moved.program.instructions.items));
    try std.testing.expect(cache.matches(moved.program.instructions.items, &moved.graph));
    var batch = @import("index_bounds.zig").ScalarDefinitionBatch{
        .instructions = moved.program.instructions.items,
        .graph = &moved.graph,
        .persistent = cache,
    };
    _ = batch.lookup(6, 106);
    try std.testing.expect(cache.entries.count() > 0);
    _ = moved.scalarIndexUpperBound(6, 106);
    _ = moved.indexLaneDefinitions(6, 106, true);
    try std.testing.expect(cache.bounds.count() > 0 and cache.lanes.count() > 0);

    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 2;
    bindings.user_data[0] = 48;
    for ([_]u32{ 0, 1, 0, 1 }) |enabled| {
        memory.word(48, enabled);
        var specialized = (try moved.specializeUniformBranches(std.testing.allocator, memory.reader(), &bindings)).?;
        defer specialized.deinit(std.testing.allocator);
        try std.testing.expect(specialized.scalar_definitions == null);
        try std.testing.expect(specialized.resource_checkpoints == null);
        try std.testing.expect(specialized.translation_key == null);
        try specialized.enableTranslationKey(std.testing.allocator);
        try std.testing.expect(!std.mem.eql(u8, key_bytes, specialized.translation_key.?.bytes));
        try std.testing.expect(!moved.resource_checkpoints.?.matches(specialized.program.instructions.items));
        try specialized.enableResourceCheckpoints(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, if (enabled == 0) 1 else 2), specialized.resource_checkpoints.?.resource.len);
        try std.testing.expect(!cache.matches(specialized.program.instructions.items, &specialized.graph));
        try std.testing.expectEqual(if (enabled == 0) rdna2.Opcode.s_nop else .image_store, specialized.program.instructions.items[5].opcode);
    }
    // The code-word validation in the backend replaces this whole owner.
    memory.word(0, 0xbf81_0000);
    var replacement = try decode(std.testing.allocator, memory.reader(), 0, 16);
    defer replacement.deinit(std.testing.allocator);
    try replacement.enableScalarDefinitionCache(std.testing.allocator);
    try replacement.enableResourceCheckpoints(std.testing.allocator);
    try replacement.enableTranslationKey(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, key_bytes, replacement.translation_key.?.bytes));
    try std.testing.expectEqual(@as(usize, 0), replacement.resource_checkpoints.?.resource.len);
    try std.testing.expect(!moved.resource_checkpoints.?.matches(replacement.program.instructions.items));
    try std.testing.expect(replacement.scalar_definitions.? != cache);
    try std.testing.expectEqual(@as(u32, 0), replacement.scalar_definitions.?.entries.count());
    try std.testing.expectEqual(@as(u32, 0), replacement.scalar_definitions.?.bounds.count());
    try std.testing.expectEqual(@as(u32, 0), replacement.scalar_definitions.?.lanes.count());
    try std.testing.expect(!cache.matches(replacement.program.instructions.items, &replacement.graph));
}

test "uniform specialization reuse rechecks guest values and owns separate static plans" {
    const allocator = std.testing.allocator;
    var memory = TestMemory{};
    const code = [_]u32{
        0xf400_1a80, 125 << 25,   0xbefe_04c1, 0xbf8c_007f,
        0xbf07_6a80, 0xbf84_0002, 0xf020_0f28, 0x0002_0400,
        0xbf81_0000,
    };
    for (code, 0..) |word, index| memory.word(index * 4, word);
    var analysis = try decode(allocator, memory.reader(), 0, 16);
    defer analysis.deinit(allocator);
    try analysis.enableUniformSpecializations(allocator);
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.resource_instruction_budget = 4096;
    bindings.user_data_count = 2;
    bindings.user_data[0] = 48;
    for ([_]u32{ 0, 1, 2, 0, 1 }, 0..) |flag, iteration| {
        memory.word(48, flag);
        var lease = (try analysis.acquireUniformSpecialization(allocator, memory.reader(), &bindings, true)).?;
        defer lease.release();
        try std.testing.expectEqual(iteration >= 2, lease.reused);
        try std.testing.expectEqual(if (flag == 0) rdna2.Opcode.s_nop else .image_store, lease.analysis.program.instructions.items[5].opcode);
        try std.testing.expect(lease.analysis.resource_checkpoints.?.matches(lease.analysis.program.instructions.items));
        const fresh_key = try rdna2.cache_key.ProgramKey.init(allocator, &lease.analysis.program, lease.analysis.pipeline_options);
        defer fresh_key.deinit(allocator);
        try std.testing.expectEqualSlices(u8, fresh_key.bytes, lease.analysis.translation_key.?.bytes);
        try std.testing.expect(lease.analysis.scalar_definitions.?.matches(lease.analysis.program.instructions.items, &lease.analysis.graph));
        const current = @import("scalar_provenance.zig").evaluateDecodedResourceState(memory.reader(), &bindings, lease.analysis.program.instructions.items);
        try std.testing.expect(current.load_count != 0);
        try std.testing.expectEqual(flag, current.loads[0].values[0]);
    }
    bindings.user_data[0] = 0x10000; // An unavailable flag must not reuse a prior decision.
    try std.testing.expect((try analysis.acquireUniformSpecialization(allocator, memory.reader(), &bindings, true)) == null);
}

fn checkPinnedUniformSpecializations(allocator: std.mem.Allocator) !void {
    var memory = TestMemory{};
    const code = [_]u32{
        0xbf07_0080, 0xbf84_0001, 0xbe8a_0387, // if s0 != 0: s10 = 7
        0xbf07_0180, 0xbf84_0001, 0xbe8b_0387, // if s1 != 0: s11 = 7
        0xbf07_0280, 0xbf84_0001, 0xbe8c_0387, // if s2 != 0: s12 = 7
        0xbf81_0000,
    };
    for (code, 0..) |word, index| memory.word(index * 4, word);
    var analysis = try decode(allocator, memory.reader(), 0, 16);
    defer analysis.deinit(allocator);
    try analysis.enableUniformSpecializations(allocator);
    var leases: [5]UniformSpecializations.Lease = undefined;
    var count: usize = 0;
    defer for (leases[0..count]) |*lease| lease.release();
    var bindings = std.mem.zeroes(shaders.StageBindings);
    bindings.user_data_count = 3;
    for (0..5) |variant| {
        for (0..3) |bit| bindings.user_data[bit] = @intCast((variant >> @intCast(bit)) & 1);
        leases[count] = (try analysis.acquireUniformSpecialization(allocator, memory.reader(), &bindings, true)).?;
        count += 1;
    }
    try std.testing.expect(leases[4].entry == null); // All four retained variants are pinned.
    try std.testing.expectEqual(rdna2.Opcode.s_nop, leases[0].analysis.program.instructions.items[2].opcode);
    leases[1].release();
    bindings.user_data[0] = 1;
    bindings.user_data[1] = 1;
    bindings.user_data[2] = 1;
    // Keep deferred cleanup valid even when replacing the lease fails.
    leases[1] = leases[count - 1];
    count -= 1;
    var replacement = (try analysis.acquireUniformSpecialization(allocator, memory.reader(), &bindings, true)).?;
    defer replacement.release();
    try std.testing.expect(replacement.entry != null);
    try std.testing.expectEqual(rdna2.Opcode.s_nop, leases[0].analysis.program.instructions.items[2].opcode);
}

test "uniform specialization cache protects pinned variants and releases allocation failures" {
    try checkPinnedUniformSpecializations(std.testing.allocator);
    // Optional static memoization may deliberately recover from OOM. Exercise
    // every allocation site while checking ownership on both outcomes.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        checkPinnedUniformSpecializations(failing.allocator()) catch |err| {
            if (err != error.OutOfMemory) return err;
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (!failing.has_induced_failure) break;
    }
}

test "covered raster draw permits exports and GS allocation but retains interrupts" {
    var memory = TestMemory{};
    memory.word(0, 0xbf90_0009); // s_sendmsg GS_ALLOC_REQ
    memory.word(4, 0xf800_08cf); // exp pos0 done
    memory.word(8, 0x0302_0100);
    memory.word(12, 0xbf81_0000);
    var raster = try decode(std.testing.allocator, memory.reader(), 0, 16);
    defer raster.deinit(std.testing.allocator);
    try std.testing.expect(raster.hasExternalEffects());
    try std.testing.expect(!raster.hasNonRasterEffects());
    memory.word(0, 0xbf90_0001); // s_sendmsg interrupt
    var interrupt = try decode(std.testing.allocator, memory.reader(), 0, 16);
    defer interrupt.deinit(std.testing.allocator);
    try std.testing.expect(interrupt.hasNonRasterEffects());
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

test "fetch shader body replaces a non-s6 SETPC" {
    const vs = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_nop, .word_count = 1 },
        .{
            .pc = 4,
            .opcode = .s_setpc_b64,
            .src0 = .{ .kind = .sgpr, .reg = 0 },
            .src_count = 1,
            .word_count = 1,
        },
        .{ .pc = 8, .opcode = .s_endpgm, .word_count = 1 },
    };
    const fetch = [_]rdna2.Instruction{
        .{
            .pc = 0,
            .opcode = .buffer_load_format_xyzw,
            .dst = .{ .kind = .vgpr, .reg = 0 },
            .src1 = .{ .kind = .sgpr, .reg = 4 },
            .src_count = 2,
            .word_count = 2,
        },
        .{
            .pc = 8,
            .opcode = .s_setpc_b64,
            .src0 = .{ .kind = .sgpr, .reg = 2 },
            .src_count = 1,
            .word_count = 1,
        },
    };
    var out: std.ArrayList(rdna2.Instruction) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(try inlineFetchShader(std.testing.allocator, &vs, &fetch, &out));
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(rdna2.Opcode.s_nop, out.items[0].opcode);
    try std.testing.expectEqual(rdna2.Opcode.buffer_load_format_xyzw, out.items[1].opcode);
    try std.testing.expectEqual(rdna2.Opcode.s_endpgm, out.items[2].opcode);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), out.items[1].pc);
}

test "hardware NGG SETPC is not replaced by a fetch shader" {
    const vs = [_]rdna2.Instruction{
        .{
            .pc = 0,
            .opcode = .s_setpc_b64,
            .src0 = .{ .kind = .sgpr, .reg = 6 },
            .src_count = 1,
            .word_count = 1,
        },
        .{ .pc = 4, .opcode = .s_endpgm, .word_count = 1 },
    };
    const fetch = [_]rdna2.Instruction{
        .{ .pc = 0, .opcode = .s_nop, .word_count = 1 },
        .{ .pc = 4, .opcode = .s_endpgm, .word_count = 1 },
    };
    var out: std.ArrayList(rdna2.Instruction) = .empty;
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(!(try inlineFetchShader(std.testing.allocator, &vs, &fetch, &out)));
}

test "bounded analysis stops before reading beyond AGC shader size" {
    var memory = TestMemory{};
    memory.word(0, 0xbf80_0000); // s_nop, with no end marker in the allocation
    memory.word(4, 0xbf81_0000); // outside the declared four-byte program
    try std.testing.expectError(
        Error.MissingEndProgram,
        decodeBounded(std.testing.allocator, memory.reader(), 0, 16, 4),
    );
}
