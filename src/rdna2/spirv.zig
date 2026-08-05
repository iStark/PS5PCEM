// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Deterministic SPIR-V 1.5 writer for executable RDNA2 graphics and compute shaders.

const std = @import("std");
const builtin = @import("builtin");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
const instruction = @import("instruction.zig");
const control_flow = @import("control_flow.zig");

pub const Stage = enum(u32) {
    vertex = 0,
    fragment = 4,
    compute = 5,
};

/// Static association recovered at a dispatch boundary. GFX10 names a V#
/// descriptor by its first SGPR; Vulkan names the same resource by an element
/// in the storage-buffer descriptor array.
pub const StorageBufferBinding = struct {
    resource_sgpr: u32,
    descriptor_index: u32,
    stride: u32 = 0,
    swizzled: bool = false,
    index_stride: u8 = 0,
    add_thread_id: bool = false,
    /// How many bytes the descriptor says the buffer holds, when the caller
    /// knows. The hardware answers an access past this with zero on a read and
    /// drops it on a write, rather than touching whatever lies beyond — a shader
    /// that indexes past the end is a normal thing for one to do, because the
    /// bound is how it discovers where the data stopped.
    ///
    /// Null leaves the access unchecked, which is what a caller that has not
    /// recovered the descriptor should say rather than guessing a size.
    extent_bytes: ?u32 = null,
};

pub const SampledImageBinding = struct {
    resource_sgpr: u32,
    sampler_sgpr: u32,
    descriptor_index: u32,
};

/// Scalar user data is captured by the API-neutral GPU state tracker. Supplying
/// it here lets address operands use the same values that the guest shader saw.
pub const ScalarRegister = struct {
    register: u32,
    value: u32,
};

pub const ComputeInputs = struct {
    workgroup_id_sgprs: [3]?u8 = .{ null, null, null },
    threadgroup_size_sgpr: ?u8 = null,
    local_invocation_id_components: u2 = 0,
};

pub const Options = struct {
    stage: Stage,
    local_size: [3]u32 = .{ 1, 1, 1 },
    /// VGPR populated from Vulkan's VertexIndex system value before a vertex
    /// shader starts. Other graphics system values remain explicit future
    /// stage-interface work rather than silently receiving zero.
    vertex_index_vgpr: ?u8 = null,
    storage_buffers: []const StorageBufferBinding = &.{},
    /// Whether the program narrows the execution mask, and so needs to know
    /// which lane it is running as. Decided from the program by `translate`,
    /// because the input has to be declared before the body that reads it.
    uses_execution_mask: bool = false,
    sampled_images: []const SampledImageBinding = &.{},
    scalar_registers: []const ScalarRegister = &.{},
    compute_inputs: ?ComputeInputs = null,
    descriptor_array_length: u32 = 64,
    /// Exclusive PC ending a straight scalar prolog evaluated against the
    /// captured dispatch state and checked guest memory.
    specialized_scalar_prefix_end: u32 = 0,
};

pub const Error = std.mem.Allocator.Error || control_flow.Error || error{
    UnsupportedOpcode,
    UnsupportedControlFlow,
    UnsupportedDestination,
    UndefinedRegister,
    InvalidStorageBinding,
    UnsupportedBufferAddressing,
    InvalidStageInterface,
};

pub const Module = struct {
    words: []u32,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
        self.* = undefined;
    }
};

const ValueType = enum { bits32, sint32, float32 };
const Value = struct { id: u32 = 0, value_type: ValueType = .bits32 };
const Constant = struct { value_type: ValueType, bits: u32, id: u32 };
const State = struct {
    registers: [384]Value = [_]Value{.{}} ** 384,
    scc: u32 = 0,
    valid: bool = false,
};

const BufferAddress = struct {
    binding: StorageBufferBinding,
    byte_offset: u32,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    annotations: std.ArrayList(u32) = .empty,
    declarations: std.ArrayList(u32) = .empty,
    body: std.ArrayList(u32) = .empty,
    constants: std.ArrayList(Constant) = .empty,
    registers: [384]Value = [_]Value{.{}} ** 384,
    next_id: u32 = 1,
    void_type: u32,
    function_type: u32,
    bits_type: u32,
    signed_type: u32,
    float_type: u32,
    bool_type: u32,
    vector3_bits_type: u32 = 0,
    vector4_type: u32 = 0,
    main_function: u32,
    label: u32,
    stage: Stage,
    vertex_index_vgpr: ?u8,
    vertex_index_input: u32 = 0,
    position_output: u32 = 0,
    color_output: u32 = 0,
    storage_bindings: []const StorageBufferBinding,
    sampled_bindings: []const SampledImageBinding,
    storage_array: u32 = 0,
    storage_word_pointer_type: u32 = 0,
    local_invocation_index: u32 = 0,
    /// The execution mask, as low and high halves, once a shader has narrowed
    /// it. Null means untouched — every lane on — which is how a wave starts
    /// and needs no test emitted for it.
    exec_mask: ?[2]u32 = null,
    workgroup_id_input: u32 = 0,
    local_invocation_id_input: u32 = 0,
    compute_inputs: ?ComputeInputs,
    local_size: [3]u32,
    vector2_type: u32 = 0,
    sampled_image_type: u32 = 0,
    sampled_image_array: u32 = 0,
    sampled_image_pointer_type: u32 = 0,
    specialized_scalar_registers: [128]bool = @splat(false),
    specialized_scalar_prefix_end: u32,
    scc: u32 = 0,

    fn init(allocator: std.mem.Allocator, options: Options) Error!Builder {
        var self = Builder{
            .allocator = allocator,
            .void_type = 0,
            .function_type = 0,
            .bits_type = 0,
            .signed_type = 0,
            .float_type = 0,
            .bool_type = 0,
            .main_function = 0,
            .label = 0,
            .stage = options.stage,
            .vertex_index_vgpr = options.vertex_index_vgpr,
            .storage_bindings = options.storage_buffers,
            .sampled_bindings = options.sampled_images,
            .compute_inputs = options.compute_inputs,
            .local_size = options.local_size,
            .specialized_scalar_prefix_end = options.specialized_scalar_prefix_end,
        };
        errdefer self.deinit();
        self.void_type = self.id();
        self.function_type = self.id();
        self.bits_type = self.id();
        self.signed_type = self.id();
        self.float_type = self.id();
        self.bool_type = self.id();
        self.main_function = self.id();
        self.label = self.id();
        try self.emit(&self.declarations, 19, &.{self.void_type}); // OpTypeVoid
        try self.emit(&self.declarations, 33, &.{ self.function_type, self.void_type }); // OpTypeFunction
        try self.emit(&self.declarations, 21, &.{ self.bits_type, 32, 0 }); // OpTypeInt
        try self.emit(&self.declarations, 21, &.{ self.signed_type, 32, 1 }); // OpTypeInt
        try self.emit(&self.declarations, 22, &.{ self.float_type, 32 }); // OpTypeFloat
        try self.emit(&self.declarations, 20, &.{self.bool_type}); // OpTypeBool

        if (options.vertex_index_vgpr != null and options.stage != .vertex) {
            return Error.InvalidStageInterface;
        }
        if (options.compute_inputs != null and options.stage != .compute) return Error.InvalidStageInterface;
        switch (options.stage) {
            .vertex => {
                self.vector4_type = self.id();
                const output_pointer = self.id();
                self.position_output = self.id();
                try self.emit(&self.annotations, 71, &.{ self.position_output, 11, 0 }); // BuiltIn Position
                try self.emit(&self.declarations, 23, &.{ self.vector4_type, self.float_type, 4 }); // OpTypeVector
                try self.emit(&self.declarations, 32, &.{ output_pointer, 3, self.vector4_type }); // ptr Output
                try self.emit(&self.declarations, 59, &.{ output_pointer, self.position_output, 3 }); // OpVariable

                if (options.vertex_index_vgpr != null) {
                    const input_pointer = self.id();
                    self.vertex_index_input = self.id();
                    try self.emit(&self.annotations, 71, &.{ self.vertex_index_input, 11, 42 }); // BuiltIn VertexIndex
                    try self.emit(&self.declarations, 32, &.{ input_pointer, 1, self.signed_type }); // ptr Input
                    try self.emit(&self.declarations, 59, &.{ input_pointer, self.vertex_index_input, 1 }); // OpVariable
                }
            },
            .fragment => {
                self.vector4_type = self.id();
                const output_pointer = self.id();
                self.color_output = self.id();
                try self.emit(&self.annotations, 71, &.{ self.color_output, 30, 0 }); // Location 0
                try self.emit(&self.declarations, 23, &.{ self.vector4_type, self.float_type, 4 }); // OpTypeVector
                try self.emit(&self.declarations, 32, &.{ output_pointer, 3, self.vector4_type }); // ptr Output
                try self.emit(&self.declarations, 59, &.{ output_pointer, self.color_output, 3 }); // OpVariable
            },
            .compute => {
                if (options.compute_inputs) |inputs| {
                    if (inputs.local_invocation_id_components > 3) return Error.InvalidStageInterface;
                    var needs_workgroup_id = false;
                    for (inputs.workgroup_id_sgprs) |reg| {
                        if (reg) |index| {
                            if (index >= 128) return Error.InvalidStageInterface;
                            needs_workgroup_id = true;
                        }
                    }
                    if (inputs.threadgroup_size_sgpr) |index| {
                        if (index >= 128) return Error.InvalidStageInterface;
                    }
                    if (needs_workgroup_id or inputs.local_invocation_id_components != 0) {
                        self.vector3_bits_type = self.id();
                        const input_vector_pointer = self.id();
                        try self.emit(&self.declarations, 23, &.{ self.vector3_bits_type, self.bits_type, 3 }); // OpTypeVector
                        try self.emit(&self.declarations, 32, &.{ input_vector_pointer, 1, self.vector3_bits_type }); // ptr Input
                        if (needs_workgroup_id) {
                            self.workgroup_id_input = self.id();
                            try self.emit(&self.annotations, 71, &.{ self.workgroup_id_input, 11, 26 }); // BuiltIn WorkgroupId
                            try self.emit(&self.declarations, 59, &.{ input_vector_pointer, self.workgroup_id_input, 1 });
                        }
                        if (inputs.local_invocation_id_components != 0) {
                            self.local_invocation_id_input = self.id();
                            try self.emit(&self.annotations, 71, &.{ self.local_invocation_id_input, 11, 27 }); // BuiltIn LocalInvocationId
                            try self.emit(&self.declarations, 59, &.{ input_vector_pointer, self.local_invocation_id_input, 1 });
                        }
                    }
                }
            },
        }

        for (options.scalar_registers) |scalar| {
            if (scalar.register >= 128) return Error.InvalidStorageBinding;
            self.registers[scalar.register] = .{
                .id = try self.constant(.bits32, scalar.value),
                .value_type = .bits32,
            };
            self.specialized_scalar_registers[scalar.register] = true;
        }

        if (options.storage_buffers.len != 0) {
            if (options.stage != .compute or options.descriptor_array_length == 0) {
                return Error.InvalidStorageBinding;
            }
            for (options.storage_buffers, 0..) |binding, index| {
                if (binding.resource_sgpr >= 128 or
                    binding.descriptor_index >= options.descriptor_array_length or
                    binding.index_stride > 3)
                {
                    return Error.InvalidStorageBinding;
                }
                for (options.storage_buffers[0..index]) |previous| {
                    if (previous.resource_sgpr == binding.resource_sgpr) return Error.InvalidStorageBinding;
                }
            }

            const runtime_words = self.id();
            const storage_block = self.id();
            const descriptor_count = try self.constant(.bits32, options.descriptor_array_length);
            const descriptor_array = self.id();
            const storage_array_pointer = self.id();
            self.storage_word_pointer_type = self.id();
            self.storage_array = self.id();

            try self.emit(&self.annotations, 71, &.{ runtime_words, 6, 4 }); // ArrayStride 4
            try self.emit(&self.annotations, 72, &.{ storage_block, 0, 35, 0 }); // member Offset 0
            try self.emit(&self.annotations, 71, &.{ storage_block, 2 }); // Block
            try self.emit(&self.annotations, 71, &.{ self.storage_array, 34, 0 }); // DescriptorSet 0
            try self.emit(&self.annotations, 71, &.{ self.storage_array, 33, 0 }); // Binding 0
            try self.emit(&self.declarations, 29, &.{ runtime_words, self.bits_type }); // OpTypeRuntimeArray
            try self.emit(&self.declarations, 30, &.{ storage_block, runtime_words }); // OpTypeStruct
            try self.emit(&self.declarations, 28, &.{ descriptor_array, storage_block, descriptor_count }); // OpTypeArray
            try self.emit(&self.declarations, 32, &.{ storage_array_pointer, 12, descriptor_array }); // ptr StorageBuffer
            try self.emit(&self.declarations, 32, &.{ self.storage_word_pointer_type, 12, self.bits_type });
            try self.emit(&self.declarations, 59, &.{ storage_array_pointer, self.storage_array, 12 }); // OpVariable

            var needs_thread_id = false;
            for (options.storage_buffers) |binding| {
                needs_thread_id = needs_thread_id or binding.add_thread_id;
            }
            needs_thread_id = needs_thread_id or options.uses_execution_mask;
            if (needs_thread_id) {
                const input_uint_pointer = self.id();
                self.local_invocation_index = self.id();
                try self.emit(&self.annotations, 71, &.{ self.local_invocation_index, 11, 29 }); // BuiltIn LocalInvocationIndex
                try self.emit(&self.declarations, 32, &.{ input_uint_pointer, 1, self.bits_type }); // ptr Input
                try self.emit(&self.declarations, 59, &.{ input_uint_pointer, self.local_invocation_index, 1 }); // OpVariable
            }
        }
        if (options.sampled_images.len != 0) {
            if (options.stage != .fragment or options.descriptor_array_length == 0) {
                return Error.InvalidStorageBinding;
            }
            for (options.sampled_images, 0..) |binding, index| {
                if (binding.resource_sgpr >= 128 or binding.sampler_sgpr >= 128 or
                    binding.descriptor_index >= options.descriptor_array_length)
                {
                    return Error.InvalidStorageBinding;
                }
                for (options.sampled_images[0..index]) |previous| {
                    if (previous.resource_sgpr == binding.resource_sgpr and
                        previous.sampler_sgpr == binding.sampler_sgpr)
                    {
                        return Error.InvalidStorageBinding;
                    }
                }
            }
            self.vector2_type = self.id();
            const image_type = self.id();
            self.sampled_image_type = self.id();
            const descriptor_count = try self.constant(.bits32, options.descriptor_array_length);
            const descriptor_array = self.id();
            const array_pointer = self.id();
            self.sampled_image_pointer_type = self.id();
            self.sampled_image_array = self.id();
            try self.emit(&self.annotations, 71, &.{ self.sampled_image_array, 34, 0 }); // DescriptorSet 0
            try self.emit(&self.annotations, 71, &.{ self.sampled_image_array, 33, 1 }); // Binding 1
            try self.emit(&self.declarations, 23, &.{ self.vector2_type, self.float_type, 2 }); // OpTypeVector
            try self.emit(&self.declarations, 25, &.{ image_type, self.float_type, 1, 0, 0, 0, 1, 0 }); // sampled 2D image
            try self.emit(&self.declarations, 27, &.{ self.sampled_image_type, image_type }); // OpTypeSampledImage
            try self.emit(&self.declarations, 28, &.{ descriptor_array, self.sampled_image_type, descriptor_count });
            try self.emit(&self.declarations, 32, &.{ array_pointer, 0, descriptor_array }); // ptr UniformConstant
            try self.emit(&self.declarations, 32, &.{ self.sampled_image_pointer_type, 0, self.sampled_image_type });
            try self.emit(&self.declarations, 59, &.{ array_pointer, self.sampled_image_array, 0 }); // OpVariable
        }
        return self;
    }

    fn deinit(self: *Builder) void {
        self.annotations.deinit(self.allocator);
        self.declarations.deinit(self.allocator);
        self.body.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }

    fn id(self: *Builder) u32 {
        const result = self.next_id;
        self.next_id += 1;
        return result;
    }

    fn emit(self: *Builder, list: *std.ArrayList(u32), opcode: u16, args: []const u32) Error!void {
        try list.append(self.allocator, (@as(u32, @intCast(args.len + 1)) << 16) | opcode);
        try list.appendSlice(self.allocator, args);
    }

    fn typeId(self: *const Builder, value_type: ValueType) u32 {
        return switch (value_type) {
            .bits32 => self.bits_type,
            .sint32 => self.signed_type,
            .float32 => self.float_type,
        };
    }

    fn constant(self: *Builder, value_type: ValueType, bits: u32) Error!u32 {
        for (self.constants.items) |entry| {
            if (entry.value_type == value_type and entry.bits == bits) return entry.id;
        }
        const result = self.id();
        try self.emit(&self.declarations, 43, &.{ self.typeId(value_type), result, bits }); // OpConstant
        try self.constants.append(self.allocator, .{ .value_type = value_type, .bits = bits, .id = result });
        return result;
    }

    fn registerIndex(op: operand.Operand) ?usize {
        return switch (op.kind) {
            .sgpr => if (op.reg < 128) @intCast(op.reg) else null,
            .vgpr => if (op.reg < 256) @intCast(128 + op.reg) else null,
            .vcc_lo => 106,
            .vcc_hi => 107,
            .exec_lo => 126,
            .exec_hi => 127,
            else => null,
        };
    }

    fn convert(self: *Builder, value: Value, expected: ValueType) Error!u32 {
        if (value.value_type == expected) return value.id;
        const converted = self.id();
        try self.emit(&self.body, 124, &.{ self.typeId(expected), converted, value.id }); // OpBitcast
        return converted;
    }

    fn rawSource(self: *Builder, op: operand.Operand) Error!u32 {
        return switch (op.kind) {
            .integer_inline_constant, .literal_constant, .float_inline_constant => self.constant(.bits32, op.value),
            .null => self.constant(.bits32, 0),
            .sgpr, .vgpr => blk: {
                const index = registerIndex(op) orelse return Error.UndefinedRegister;
                const current = self.registers[index];
                if (current.id == 0) return Error.UndefinedRegister;
                break :blk try self.convert(current, .bits32);
            },
            else => Error.UndefinedRegister,
        };
    }

    fn source(self: *Builder, op: operand.Operand, expected: ValueType) Error!u32 {
        if (op.dpp) {
            std.debug.print("[rdna2] Unsupported DPP operand\n", .{});
            return Error.UnsupportedOpcode;
        }
        var raw = try self.rawSource(op);
        if (op.sdwa_sel != 6) {
            const width: u32 = if (op.sdwa_sel < 4) 8 else if (op.sdwa_sel < 6) 16 else return Error.UnsupportedOpcode;
            const shift: u32 = if (op.sdwa_sel < 4)
                @as(u32, op.sdwa_sel) * 8
            else
                @as(u32, op.sdwa_sel - 4) * 16;
            if (shift != 0) {
                const shifted = self.id();
                try self.emit(&self.body, 194, &.{ self.bits_type, shifted, raw, try self.constant(.bits32, shift) });
                raw = shifted;
            }
            const masked = self.id();
            const mask = if (width == 8) @as(u32, 0xff) else 0xffff;
            try self.emit(&self.body, 199, &.{ self.bits_type, masked, raw, try self.constant(.bits32, mask) });
            raw = masked;
            if (op.sdwa_sext) {
                const left = self.id();
                const amount = 32 - width;
                try self.emit(&self.body, 196, &.{ self.bits_type, left, raw, try self.constant(.bits32, amount) });
                const signed = try self.convert(.{ .id = left, .value_type = .bits32 }, .sint32);
                const extended = self.id();
                try self.emit(&self.body, 195, &.{ self.signed_type, extended, signed, try self.constant(.sint32, amount) });
                raw = try self.convert(.{ .id = extended, .value_type = .sint32 }, .bits32);
            }
        }
        if (op.absolute or op.negate) {
            if (expected != .float32) {
                std.debug.print("[rdna2] Unsupported abs/neg on non-float type\n", .{});
                return Error.UnsupportedOpcode;
            }
            if (op.absolute) {
                const absolute = self.id();
                try self.emit(&self.body, 199, &.{ self.bits_type, absolute, raw, try self.constant(.bits32, 0x7fff_ffff) });
                raw = absolute;
            }
            if (op.negate) {
                const negated = self.id();
                try self.emit(&self.body, 198, &.{ self.bits_type, negated, raw, try self.constant(.bits32, 0x8000_0000) });
                raw = negated;
            }
        }
        return self.convert(.{ .id = raw, .value_type = .bits32 }, expected);
    }

    fn destination(self: *Builder, op: operand.Operand, value: Value) Error!void {
        if (op.sdwa_sel != 6 or op.sdwa_dst_unused != 0) return Error.UnsupportedDestination;
        const index = registerIndex(op) orelse return Error.UnsupportedDestination;
        self.registers[index] = .{
            .id = try self.convert(value, .bits32),
            .value_type = .bits32,
        };
    }

    fn unary(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType) Error!void {
        const source_id = try self.source(inst.src0, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(value_type), result, source_id });
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
    }

    fn binary(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType, reverse: bool) Error!void {
        const a = try self.source(if (reverse) inst.src1 else inst.src0, value_type);
        const b = try self.source(if (reverse) inst.src0 else inst.src1, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(value_type), result, a, b });
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
    }

    fn comparison(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType) Error!void {
        const a = try self.source(inst.src0, value_type);
        const b = try self.source(inst.src1, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.bool_type, result, a, b });
        self.scc = result;
    }

    fn shiftLeftAdd(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .bits32);
        const raw_shift = try self.source(inst.src1, .bits32);
        const addend = try self.source(inst.src2, .bits32);
        const shift = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, shift, raw_shift, try self.constant(.bits32, 31) }); // OpBitwiseAnd
        const shifted = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shifted, value, shift }); // OpShiftLeftLogical
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, result, shifted, addend }); // OpIAdd
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn initializeStageInputs(self: *Builder) Error!void {
        if (self.vertex_index_input != 0) {
            const result = self.id();
            try self.emit(&self.body, 61, &.{ self.signed_type, result, self.vertex_index_input }); // OpLoad
            const vgpr = self.vertex_index_vgpr orelse return Error.InvalidStageInterface;
            self.registers[128 + @as(usize, vgpr)] = .{ .id = result, .value_type = .sint32 };
        }
        const inputs = self.compute_inputs orelse return;
        if (self.workgroup_id_input != 0) {
            const vector = self.id();
            try self.emit(&self.body, 61, &.{ self.vector3_bits_type, vector, self.workgroup_id_input }); // OpLoad
            for (inputs.workgroup_id_sgprs, 0..) |maybe_register, component| {
                const register = maybe_register orelse continue;
                const value = self.id();
                try self.emit(&self.body, 81, &.{ self.bits_type, value, vector, @intCast(component) }); // OpCompositeExtract
                self.registers[register] = .{ .id = value, .value_type = .bits32 };
            }
        }
        if (self.local_invocation_id_input != 0) {
            const vector = self.id();
            try self.emit(&self.body, 61, &.{ self.vector3_bits_type, vector, self.local_invocation_id_input }); // OpLoad
            for (0..inputs.local_invocation_id_components) |component| {
                const value = self.id();
                try self.emit(&self.body, 81, &.{ self.bits_type, value, vector, @intCast(component) }); // OpCompositeExtract
                self.registers[128 + component] = .{ .id = value, .value_type = .bits32 };
            }
        }
        if (inputs.threadgroup_size_sgpr) |register| {
            const xy = std.math.mul(u32, self.local_size[0], self.local_size[1]) catch return Error.InvalidStageInterface;
            const size = std.math.mul(u32, xy, self.local_size[2]) catch return Error.InvalidStageInterface;
            self.registers[register] = .{ .id = try self.constant(.bits32, size), .value_type = .bits32 };
        }
    }

    fn integerToFloat(self: *Builder, inst: instruction.Instruction, signed: bool) Error!void {
        const source_type: ValueType = if (signed) .sint32 else .bits32;
        const source_id = try self.source(inst.src0, source_type);
        const result = self.id();
        try self.emit(&self.body, if (signed) 111 else 112, &.{ self.float_type, result, source_id });
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn exportValue(self: *Builder, inst: instruction.Instruction) Error!void {
        if (inst.export_compressed or inst.export_enable != 0xf or self.vector4_type == 0) {
            std.debug.print("[rdna2] Unsupported export: compressed={}, enable=0x{x}, vector4_type={}\n", .{
                inst.export_compressed,
                inst.export_enable,
                self.vector4_type,
            });
            return Error.UnsupportedOpcode;
        }
        const output = switch (self.stage) {
            .vertex => if (inst.export_target == 12) self.position_output else 0,
            .fragment => if (inst.export_target == 0) self.color_output else 0,
            .compute => 0,
        };
        if (output == 0) {
            std.debug.print("[rdna2] Unsupported export target {} for stage {s}\n", .{
                inst.export_target,
                @tagName(self.stage),
            });
            return Error.UnsupportedOpcode;
        }
        const x = try self.source(inst.src0, .float32);
        const y = try self.source(inst.src1, .float32);
        const z = try self.source(inst.src2, .float32);
        const w = try self.source(inst.src3, .float32);
        const vector = self.id();
        try self.emit(&self.body, 80, &.{ self.vector4_type, vector, x, y, z, w }); // OpCompositeConstruct
        try self.emit(&self.body, 62, &.{ output, vector }); // OpStore
    }

    fn storageBinding(self: *const Builder, resource_sgpr: u32) ?StorageBufferBinding {
        for (self.storage_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr) return binding;
        }
        return null;
    }

    fn sampledImageBinding(self: *const Builder, resource_sgpr: u32, sampler_sgpr: u32) ?SampledImageBinding {
        for (self.sampled_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr and binding.sampler_sgpr == sampler_sgpr) return binding;
        }
        return null;
    }

    fn sampleImage(self: *Builder, inst: instruction.Instruction) Error!void {
        if (self.stage != .fragment or self.sampled_image_array == 0 or
            inst.opcode_id != 0x20 or inst.image_dimension != .dim_2d or
            inst.image_address_components != 2 or inst.image_nsa_words != 0 or
            @as(u16, @bitCast(inst.image_sample_flags)) != 0 or inst.data_mask == 0)
        {
            return Error.UnsupportedOpcode;
        }
        if (inst.src0.kind != .vgpr or inst.src1.kind != .sgpr or inst.src2.kind != .sgpr) {
            return Error.UnsupportedBufferAddressing;
        }
        const binding = self.sampledImageBinding(inst.src1.reg, inst.src2.reg) orelse {
            return Error.InvalidStorageBinding;
        };
        const coordinate_x = try self.source(inst.src0, .float32);
        const coordinate_y = try self.source(try consecutiveRegister(inst.src0, 1), .float32);
        const coordinates = self.id();
        try self.emit(&self.body, 80, &.{ self.vector2_type, coordinates, coordinate_x, coordinate_y });
        const pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.sampled_image_pointer_type,
            pointer,
            self.sampled_image_array,
            try self.constant(.bits32, binding.descriptor_index),
        });
        const sampled_image = self.id();
        try self.emit(&self.body, 61, &.{ self.sampled_image_type, sampled_image, pointer });
        const sampled = self.id();
        try self.emit(&self.body, 87, &.{ self.vector4_type, sampled, sampled_image, coordinates }); // OpImageSampleImplicitLod

        var destination_index: u32 = 0;
        for (0..4) |component| {
            const bit = @as(u4, 1) << @intCast(component);
            if (inst.data_mask & bit == 0) continue;
            const value = self.id();
            try self.emit(&self.body, 81, &.{ self.float_type, value, sampled, @intCast(component) }); // OpCompositeExtract
            try self.destination(
                try consecutiveRegister(inst.dst, destination_index),
                .{ .id = value, .value_type = .float32 },
            );
            destination_index += 1;
        }
    }

    fn addBits(self: *Builder, a: u32, b: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, result, a, b }); // OpIAdd
        return result;
    }

    fn consecutiveRegister(op: operand.Operand, delta: u32) Error!operand.Operand {
        var result = op;
        if (op.kind == .vgpr) {
            if (op.reg + delta >= 256) return Error.UnsupportedBufferAddressing;
            result.reg += delta;
        } else if (op.kind == .sgpr) {
            if (op.reg + delta >= 128) return Error.UnsupportedBufferAddressing;
            result.reg += delta;
        } else if (op.kind == .vcc_lo) {
            if (delta == 1) result.kind = .vcc_hi else if (delta != 0) return Error.UnsupportedBufferAddressing;
        } else if (op.kind == .exec_lo) {
            if (delta == 1) result.kind = .exec_hi else if (delta != 0) return Error.UnsupportedBufferAddressing;
        } else {
            return Error.UnsupportedBufferAddressing;
        }
        return result;
    }

    fn multiplyBits(self: *Builder, a: u32, b: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 132, &.{ self.bits_type, result, a, b }); // OpIMul
        return result;
    }

    fn shiftRightBits(self: *Builder, value: u32, amount: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, result, value, try self.constant(.bits32, amount) });
        return result;
    }

    fn andBits(self: *Builder, value: u32, mask: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, result, value, try self.constant(.bits32, mask) });
        return result;
    }

    fn bufferAddressDelta(self: *Builder, inst: instruction.Instruction, extra_offset: u32) Error!BufferAddress {
        if (self.storage_array == 0 or inst.src1.kind != .sgpr) {
            return Error.UnsupportedBufferAddressing;
        }
        if (inst.memory_offset < 0) return Error.UnsupportedBufferAddressing;
        const binding = self.storageBinding(inst.src1.reg) orelse {
            return Error.InvalidStorageBinding;
        };

        var index = if (inst.index_enable)
            try self.source(inst.src0, .bits32)
        else
            try self.constant(.bits32, 0);
        if (binding.add_thread_id) {
            if (self.local_invocation_index == 0) return Error.UnsupportedBufferAddressing;
            const invocation = self.id();
            try self.emit(&self.body, 61, &.{ self.bits_type, invocation, self.local_invocation_index }); // OpLoad
            index = try self.addBits(index, try self.andBits(invocation, 63));
        }

        var offset = try self.constant(.bits32, @as(u32, @intCast(inst.memory_offset)) + extra_offset);
        if (inst.offset_enable) {
            const offset_operand = if (inst.index_enable) try consecutiveRegister(inst.src0, 1) else inst.src0;
            offset = try self.addBits(offset, try self.source(offset_operand, .bits32));
        }
        const stride = try self.constant(.bits32, binding.stride);
        var byte_offset = if (binding.swizzled and binding.stride != 0) blk: {
            const index_stride: u32 = @as(u32, 8) << @as(u5, @intCast(binding.index_stride));
            const index_msb = try self.shiftRightBits(index, @as(u32, binding.index_stride) + 3);
            const index_lsb = try self.andBits(index, index_stride - 1);
            const offset_msb = try self.andBits(offset, 0xffff_fffc);
            const offset_lsb = try self.andBits(offset, 3);
            const index_part = try self.multiplyBits(index_msb, stride);
            const msb = try self.multiplyBits(
                try self.addBits(index_part, offset_msb),
                try self.constant(.bits32, index_stride),
            );
            const lsb_index = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, lsb_index, index_lsb, try self.constant(.bits32, 2) }); // OpShiftLeftLogical
            break :blk try self.addBits(msb, try self.addBits(lsb_index, offset_lsb));
        } else try self.addBits(try self.multiplyBits(index, stride), offset);
        byte_offset = try self.addBits(byte_offset, try self.source(inst.src2, .bits32));
        return .{ .binding = binding, .byte_offset = byte_offset };
    }

    fn bufferAddress(self: *Builder, inst: instruction.Instruction) Error!BufferAddress {
        return self.bufferAddressDelta(inst, 0);
    }

    /// Whether a word access lies inside what the descriptor describes.
    ///
    /// Null when the caller supplied no extent, which means every access is
    /// taken as valid — the same behaviour as before a bound was known.
    fn wordInRange(self: *Builder, address: BufferAddress, delta: u32) Error!?u32 {
        const extent = address.binding.extent_bytes orelse return null;
        // The last byte this word touches, so a word straddling the end counts
        // as outside rather than half inside.
        const last = try self.addBits(address.byte_offset, try self.constant(.bits32, delta * 4 + 3));
        const result = self.id();
        try self.emit(&self.body, 176, &.{ // OpULessThan
            self.bool_type,
            result,
            last,
            try self.constant(.bits32, extent),
        });
        return result;
    }

    /// A word access: where it is, and whether it is really there.
    const WordAccess = struct {
        pointer: u32,
        /// Null when the descriptor carried no extent, so nothing was checked.
        in_range: ?u32,
    };

    fn bufferWordAccess(self: *Builder, address: BufferAddress, delta: u32) Error!WordAccess {
        const word_index = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, word_index, address.byte_offset, try self.constant(.bits32, 2) }); // OpShiftRightLogical
        const indexed_word = if (delta == 0) word_index else try self.addBits(word_index, try self.constant(.bits32, delta));

        const in_range = try self.wordInRange(address, delta);
        // Steered to the first word when out of range. The value there is never
        // used — a read past the end selects zero and a write past it is
        // skipped — but the access is emitted either way, and an access chain
        // that leaves a bound buffer is not defined. Naming a word that exists
        // keeps the undefined case from arising at all.
        const safe_word = if (in_range) |predicate| blk: {
            const chosen = self.id();
            try self.emit(&self.body, 169, &.{ // OpSelect
                self.bits_type,
                chosen,
                predicate,
                indexed_word,
                try self.constant(.bits32, 0),
            });
            break :blk chosen;
        } else indexed_word;

        const pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.storage_word_pointer_type,
            pointer,
            self.storage_array,
            try self.constant(.bits32, address.binding.descriptor_index),
            try self.constant(.bits32, 0),
            safe_word,
        }); // OpAccessChain descriptor, block member, dword
        return .{ .pointer = pointer, .in_range = in_range };
    }

    fn bufferWordPointer(self: *Builder, address: BufferAddress, delta: u32) Error!u32 {
        return (try self.bufferWordAccess(address, delta)).pointer;
    }

    fn loadBufferWord(self: *Builder, address: BufferAddress, delta: u32) Error!u32 {
        const access = try self.bufferWordAccess(address, delta);
        const loaded = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, loaded, access.pointer }); // OpLoad
        const predicate = access.in_range orelse return loaded;

        // Zero past the end, which is what the hardware returns. A shader reads
        // beyond its data on purpose — the bound is how it finds where the data
        // stopped — so this is an ordinary answer rather than an error.
        const result = self.id();
        try self.emit(&self.body, 169, &.{ // OpSelect
            self.bits_type,
            result,
            predicate,
            loaded,
            try self.constant(.bits32, 0),
        });
        return result;
    }

    /// Writes a word only where the descriptor says there is one.
    ///
    /// A store past the end is dropped by the hardware. It cannot be dropped
    /// with a select here, because a select still stores — so the store is put
    /// behind a branch, which is the only way SPIR-V has of not doing one.
    fn storeBufferWord(self: *Builder, address: BufferAddress, delta: u32, value: u32) Error!void {
        const access = try self.bufferWordAccess(address, delta);
        const predicate = try self.writePredicate(access.in_range) orelse {
            try self.emit(&self.body, 62, &.{ access.pointer, value }); // OpStore
            return;
        };
        try self.guardedStore(predicate, access.pointer, value);
    }

    /// Whether this invocation is a lane the execution mask has switched on.
    ///
    /// A wave runs all its lanes together and uses the mask to say which of them
    /// count; a SPIR-V invocation *is* one lane, so the mask becomes a question
    /// asked of the lane's own index. Null while the mask is untouched, which is
    /// every lane enabled and needs no test.
    fn laneEnabled(self: *Builder) Error!?u32 {
        const mask = self.exec_mask orelse return null;
        if (self.local_invocation_index == 0) return Error.UnsupportedControlFlow;

        const invocation = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, invocation, self.local_invocation_index }); // OpLoad
        const lane = try self.andBits(invocation, 63);

        // The mask is sixty-four bits and a lane index is six, so which half a
        // lane lives in is itself part of the question.
        const half = try self.shiftRightBits(lane, 5);
        const within = try self.andBits(lane, 31);
        const chosen = self.id();
        try self.emit(&self.body, 169, &.{ // OpSelect
            self.bits_type,
            chosen,
            try self.isNonZero(half),
            mask[1],
            mask[0],
        });

        const bit = try self.andBits(try self.shiftRightVariable(chosen, within), 1);
        return try self.isNonZero(bit);
    }

    fn isNonZero(self: *Builder, value: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 171, &.{ // OpINotEqual
            self.bool_type,
            result,
            value,
            try self.constant(.bits32, 0),
        });
        return result;
    }

    fn shiftRightVariable(self: *Builder, value: u32, amount: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, result, value, amount }); // OpShiftRightLogical
        return result;
    }

    /// Combines the execution mask with whatever else has to hold for a write.
    fn writePredicate(self: *Builder, in_range: ?u32) Error!?u32 {
        const lane = try self.laneEnabled();
        const range = in_range orelse return lane;
        const enabled = lane orelse return range;
        const result = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, result, enabled, range }); // OpLogicalAnd
        return result;
    }

    /// Emits `if (predicate) store` as a structured selection.
    fn guardedStore(self: *Builder, predicate: u32, pointer: u32, value: u32) Error!void {
        const taken = self.id();
        const merge = self.id();
        try self.emit(&self.body, 247, &.{ merge, 0 }); // OpSelectionMerge
        try self.emit(&self.body, 250, &.{ predicate, taken, merge }); // OpBranchConditional
        try self.emit(&self.body, 248, &.{taken}); // OpLabel
        try self.emit(&self.body, 62, &.{ pointer, value }); // OpStore
        try self.emit(&self.body, 249, &.{merge}); // OpBranch
        try self.emit(&self.body, 248, &.{merge}); // OpLabel
    }

    fn bufferLoadWords(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        var addresses: [16]BufferAddress = undefined;
        for (0..count) |index| {
            addresses[index] = try self.bufferAddressDelta(inst, @intCast(index * 4));
        }
        for (0..count) |index| {
            const result = try self.loadBufferWord(addresses[index], 0);
            try self.destination(try consecutiveRegister(inst.dst, @intCast(index)), .{ .id = result, .value_type = .bits32 });
        }
    }

    fn scalarBufferLoadWords(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        var mubuf_inst = inst;
        mubuf_inst.src1 = inst.src0; // Descriptor
        mubuf_inst.src2 = inst.src1; // SOFFSET
        mubuf_inst.index_enable = false;
        mubuf_inst.offset_enable = false;
        try self.bufferLoadWords(mubuf_inst, count);
    }

    fn bufferStoreWords(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        for (0..count) |index| {
            const value = try self.source(try consecutiveRegister(inst.dst, @intCast(index)), .bits32);
            const address = try self.bufferAddressDelta(inst, @intCast(index * 4));
            try self.storeBufferWord(address, 0, value);
        }
    }

    fn bufferAtomic(self: *Builder, inst: instruction.Instruction, opcode: u16) Error!void {
        const value = try self.source(inst.dst, .bits32);
        const address = try self.bufferAddress(inst);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{
            self.bits_type,
            result,
            try self.bufferWordPointer(address, 0),
            try self.constant(.bits32, 1), // ScopeDevice
            try self.constant(.bits32, 0), // MemorySemanticsNone
            value,
        });
        if (inst.globally_coherent) {
            try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
        }
        try self.emit(&self.body, 225, &.{
            try self.constant(.bits32, 1),
            try self.constant(.bits32, 0x48), // AcquireRelease | UniformMemory
        }); // OpMemoryBarrier
    }

    fn subwordShift(self: *Builder, byte_offset: u32) Error!u32 {
        const byte = try self.andBits(byte_offset, 3);
        const shift = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shift, byte, try self.constant(.bits32, 3) }); // OpShiftLeftLogical
        return shift;
    }

    fn loadBufferByte(self: *Builder, address: BufferAddress) Error!u32 {
        const word = try self.loadBufferWord(address, 0);
        const shifted = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, shifted, word, try self.subwordShift(address.byte_offset) });
        return self.andBits(shifted, 0xff);
    }

    fn bufferLoadSubword(self: *Builder, inst: instruction.Instruction, width: u8, signed: bool) Error!void {
        const address = try self.bufferAddress(inst);
        var result = try self.loadBufferByte(address);
        if (width == 16) {
            const high_byte = try self.loadBufferByte(try self.bufferAddressDelta(inst, 1));
            const shifted_high = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, shifted_high, high_byte, try self.constant(.bits32, 8) });
            const combined = self.id();
            try self.emit(&self.body, 197, &.{ self.bits_type, combined, result, shifted_high }); // OpBitwiseOr
            result = combined;
        }
        if (signed) {
            const amount: u32 = 32 - width;
            const left = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, left, result, try self.constant(.bits32, amount) });
            const as_signed = try self.convert(.{ .id = left, .value_type = .bits32 }, .sint32);
            const extended = self.id();
            try self.emit(&self.body, 195, &.{ self.signed_type, extended, as_signed, try self.constant(.sint32, amount) });
            result = try self.convert(.{ .id = extended, .value_type = .sint32 }, .bits32);
        }
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn storeBufferByte(self: *Builder, address: BufferAddress, value: u32) Error!void {
        const access = try self.bufferWordAccess(address, 0);
        const pointer = access.pointer;
        const current = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, current, pointer });
        const shift = try self.subwordShift(address.byte_offset);
        const shifted_mask = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shifted_mask, try self.constant(.bits32, 0xff), shift });
        const inverse_mask = self.id();
        try self.emit(&self.body, 200, &.{ self.bits_type, inverse_mask, shifted_mask }); // OpNot
        const preserved = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, preserved, current, inverse_mask });
        const masked_value = try self.andBits(value, 0xff);
        const inserted = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, inserted, masked_value, shift });
        const combined = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, combined, preserved, inserted }); // OpBitwiseOr
        // A byte write past the end must not disturb the word it was clamped
        // onto, so the read-modify-write is computed either way and only the
        // store is withheld.
        if (try self.writePredicate(access.in_range)) |predicate| {
            try self.guardedStore(predicate, pointer, combined);
        } else {
            try self.emit(&self.body, 62, &.{ pointer, combined });
        }
    }

    fn bufferStoreSubword(self: *Builder, inst: instruction.Instruction, width: u8) Error!void {
        const value = try self.source(inst.dst, .bits32);
        try self.storeBufferByte(try self.bufferAddress(inst), value);
        if (width == 16) {
            try self.storeBufferByte(
                try self.bufferAddressDelta(inst, 1),
                try self.shiftRightBits(value, 8),
            );
        }
    }

    fn specializedScalarDestination(self: *const Builder, inst: instruction.Instruction) bool {
        if (inst.pc >= self.specialized_scalar_prefix_end or inst.dst.kind != .sgpr or inst.dst.reg >= 128) return false;
        if (!self.specialized_scalar_registers[inst.dst.reg]) return false;
        return switch (inst.family) {
            .sop1, .sop2, .sopk, .smem => true,
            else => false,
        };
    }

    /// Takes a write to the execution mask, and says whether it did.
    ///
    /// Only the plain move is taken. The read-modify-write forms that fold a
    /// comparison into the mask carry a scalar result as well, and answering
    /// half of one would leave the shader believing a value it never received.
    fn lowerExecutionMask(self: *Builder, inst: instruction.Instruction) Error!bool {
        if (inst.dst.kind != .exec_lo) return false;
        if (inst.opcode != .s_mov_b64) return Error.UnsupportedControlFlow;

        const low = try self.source(inst.src0, .bits32);
        // The mask is one sixty-four bit value. Held in scalar registers it
        // occupies a pair, so the second half is the register after the first —
        // the consecutive-register helper nearby is for vector registers and
        // would refuse this, which is a different thing from the pair being
        // wrong. Written from a constant instead, the second half is the first
        // one's sign, which is what shifting it right by thirty-one produces.
        const high = if (inst.src0.kind == .sgpr) blk: {
            var high_operand = inst.src0;
            high_operand.reg += 1;
            break :blk try self.source(high_operand, .bits32);
        } else blk: {
            const extended = self.id();
            try self.emit(&self.body, 195, &.{ // OpShiftRightArithmetic
                self.bits_type,
                extended,
                low,
                try self.constant(.bits32, 31),
            });
            break :blk extended;
        };
        self.exec_mask = .{ low, high };
        return true;
    }

    fn snapshot(self: *const Builder) State {
        return .{ .registers = self.registers, .scc = self.scc, .valid = true };
    }

    fn restore(self: *Builder, state: State) void {
        self.registers = state.registers;
        self.scc = state.scc;
    }

    fn lower(self: *Builder, inst: instruction.Instruction) Error!void {
        if (inst.dst.clamp or inst.dst.omod != 0) return Error.UnsupportedOpcode;
        if (try self.lowerExecutionMask(inst)) return;
        if (self.specializedScalarDestination(inst)) return;
        switch (inst.opcode) {
            .s_nop, .s_waitcnt, .s_barrier, .s_inst_prefetch, .v_nop, .s_endpgm => {},
            .s_branch, .s_cbranch_scc0, .s_cbranch_scc1, .s_cbranch_vccz, .s_cbranch_vccnz, .s_cbranch_execz, .s_cbranch_execnz => return Error.UnsupportedControlFlow,
            .s_mov_b32, .v_mov_b32 => try self.unary(inst, 83, .bits32), // OpCopyObject
            .v_cvt_f32_i32 => try self.integerToFloat(inst, true),
            .v_cvt_f32_u32 => try self.integerToFloat(inst, false),
            .s_add_u32, .s_add_i32, .v_add_nc_u32 => try self.binary(inst, 128, .bits32, false), // OpIAdd
            .v_lshl_add_u32 => try self.shiftLeftAdd(inst),
            .s_sub_u32, .s_sub_i32, .v_sub_nc_u32 => try self.binary(inst, 130, .bits32, false), // OpISub
            .v_subrev_nc_u32 => try self.binary(inst, 130, .bits32, true),
            .v_add_f32 => try self.binary(inst, 129, .float32, false), // OpFAdd
            .v_sub_f32 => try self.binary(inst, 131, .float32, false), // OpFSub
            .v_subrev_f32 => try self.binary(inst, 131, .float32, true),
            .v_mul_f32 => try self.binary(inst, 133, .float32, false), // OpFMul
            .v_lshr_b32 => try self.binary(inst, 194, .bits32, false), // OpShiftRightLogical
            .v_lshrrev_b32 => try self.binary(inst, 194, .bits32, true),
            .v_ashr_i32 => try self.binary(inst, 195, .sint32, false), // OpShiftRightArithmetic
            .v_ashrrev_i32 => try self.binary(inst, 195, .sint32, true),
            .v_lshl_b32 => try self.binary(inst, 196, .bits32, false), // OpShiftLeftLogical
            .v_lshlrev_b32 => try self.binary(inst, 196, .bits32, true),
            .v_mul_lo_u32 => try self.binary(inst, 132, .bits32, false), // OpIMul
            .s_and_b32, .v_and_b32 => try self.binary(inst, 199, .bits32, false),
            .s_or_b32, .v_or_b32 => try self.binary(inst, 197, .bits32, false),
            .s_xor_b32, .v_xor_b32 => try self.binary(inst, 198, .bits32, false),
            .s_cmp_eq_i32, .s_cmp_eq_u32 => try self.comparison(inst, 170, .bits32), // OpIEqual
            .s_cmp_lg_i32, .s_cmp_lg_u32 => try self.comparison(inst, 171, .bits32), // OpINotEqual
            .s_cmp_gt_i32 => try self.comparison(inst, 173, .sint32),
            .s_cmp_ge_i32 => try self.comparison(inst, 175, .sint32),
            .s_cmp_lt_i32 => try self.comparison(inst, 177, .sint32),
            .s_cmp_le_i32 => try self.comparison(inst, 179, .sint32),
            .s_cmp_gt_u32 => try self.comparison(inst, 172, .bits32),
            .s_cmp_ge_u32 => try self.comparison(inst, 174, .bits32),
            .s_cmp_lt_u32 => try self.comparison(inst, 176, .bits32),
            .s_cmp_le_u32 => try self.comparison(inst, 178, .bits32),
            .buffer_load_ubyte => try self.bufferLoadSubword(inst, 8, false),
            .buffer_load_sbyte => try self.bufferLoadSubword(inst, 8, true),
            .buffer_load_ushort => try self.bufferLoadSubword(inst, 16, false),
            .buffer_load_sshort => try self.bufferLoadSubword(inst, 16, true),
            // FORMAT ops with 32-bit components are dword transfers through the
            // V# stride. Unity's first live compute after the GDS/copy path is
            // exactly buffer_store_format_xyzw of a constant float4/uint4; the
            // typed conversion path is not required until a non-32-bit format
            // shows up in a rejected program.
            .buffer_load_dword,
            .buffer_load_format_x,
            => try self.bufferLoadWords(inst, 1),
            .buffer_load_dwordx2,
            .buffer_load_format_xy,
            => try self.bufferLoadWords(inst, 2),
            .buffer_load_dwordx3,
            .buffer_load_format_xyz,
            => try self.bufferLoadWords(inst, 3),
            .buffer_load_dwordx4,
            .buffer_load_format_xyzw,
            => try self.bufferLoadWords(inst, 4),
            .s_buffer_load_dword => try self.scalarBufferLoadWords(inst, 1),
            .s_buffer_load_dwordx2 => try self.scalarBufferLoadWords(inst, 2),
            .s_buffer_load_dwordx4 => try self.scalarBufferLoadWords(inst, 4),
            .s_buffer_load_dwordx8 => try self.scalarBufferLoadWords(inst, 8),
            .s_buffer_load_dwordx16 => try self.scalarBufferLoadWords(inst, 16),
            .buffer_store_byte => try self.bufferStoreSubword(inst, 8),
            .buffer_store_short => try self.bufferStoreSubword(inst, 16),
            .buffer_store_dword,
            .buffer_store_format_x,
            => try self.bufferStoreWords(inst, 1),
            .buffer_store_dwordx2,
            .buffer_store_format_xy,
            => try self.bufferStoreWords(inst, 2),
            .buffer_store_dwordx3,
            .buffer_store_format_xyz,
            => try self.bufferStoreWords(inst, 3),
            .buffer_store_dwordx4,
            .buffer_store_format_xyzw,
            => try self.bufferStoreWords(inst, 4),
            .buffer_atomic_swap => try self.bufferAtomic(inst, 229), // OpAtomicExchange
            .buffer_atomic_add => try self.bufferAtomic(inst, 234), // OpAtomicIAdd
            .buffer_atomic_sub => try self.bufferAtomic(inst, 235), // OpAtomicISub
            .buffer_atomic_smin => try self.bufferAtomic(inst, 236), // OpAtomicSMin
            .buffer_atomic_umin => try self.bufferAtomic(inst, 237), // OpAtomicUMin
            .buffer_atomic_smax => try self.bufferAtomic(inst, 238), // OpAtomicSMax
            .buffer_atomic_umax => try self.bufferAtomic(inst, 239), // OpAtomicUMax
            .buffer_atomic_and => try self.bufferAtomic(inst, 240), // OpAtomicAnd
            .buffer_atomic_or => try self.bufferAtomic(inst, 241), // OpAtomicOr
            .buffer_atomic_xor => try self.bufferAtomic(inst, 242), // OpAtomicXor
            .image_sample => try self.sampleImage(inst),
            .exp => try self.exportValue(inst),
            else => {
                if (!builtin.is_test) {
                    std.debug.print("[rdna2] Unsupported opcode: {s} (0x{x}) at pc=0x{x}\n", .{
                        @tagName(inst.opcode),
                        @intFromEnum(inst.opcode),
                        inst.pc,
                    });
                }
                return Error.UnsupportedOpcode;
            },
        }
    }
};

fn appendInstruction(allocator: std.mem.Allocator, words: *std.ArrayList(u32), opcode: u16, args: []const u32) Error!void {
    try words.append(allocator, (@as(u32, @intCast(args.len + 1)) << 16) | opcode);
    try words.appendSlice(allocator, args);
}

fn emitPhi(
    builder: *Builder,
    value_type: u32,
    values: []const Value,
    parents: []const u32,
) Error!u32 {
    std.debug.assert(values.len == parents.len and values.len >= 2);
    var args: std.ArrayList(u32) = .empty;
    defer args.deinit(builder.allocator);
    const result = builder.id();
    try args.append(builder.allocator, value_type);
    try args.append(builder.allocator, result);
    for (values, parents) |value, parent| {
        try args.append(builder.allocator, value.id);
        try args.append(builder.allocator, parent);
    }
    try builder.emit(&builder.body, 245, args.items); // OpPhi
    return result;
}

fn mergeState(
    builder: *Builder,
    graph: *const control_flow.Graph,
    states: []const State,
    labels: []const u32,
    block: u32,
) Error!State {
    if (block == 0) return .{ .valid = true };
    var predecessors: std.ArrayList(u32) = .empty;
    defer predecessors.deinit(builder.allocator);
    for (graph.edges.items) |edge| {
        if (edge.to != block) continue;
        if (edge.from >= block or !states[edge.from].valid) return Error.UnsupportedControlFlow;
        try predecessors.append(builder.allocator, edge.from);
    }
    if (predecessors.items.len == 0) return Error.UnsupportedControlFlow;
    if (predecessors.items.len == 1) return states[predecessors.items[0]];

    var merged = State{ .valid = true };
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(builder.allocator);
    var parents: std.ArrayList(u32) = .empty;
    defer parents.deinit(builder.allocator);

    for (0..merged.registers.len) |reg| {
        values.clearRetainingCapacity();
        parents.clearRetainingCapacity();
        var missing = false;
        var differs = false;
        var first = Value{};
        for (predecessors.items, 0..) |pred, index| {
            const value = states[pred].registers[reg];
            if (value.id == 0) missing = true;
            if (index == 0) first = value else if (value.id != first.id) differs = true;
            try values.append(builder.allocator, value);
            try parents.append(builder.allocator, labels[pred]);
        }
        if (missing) continue;
        merged.registers[reg] = if (!differs)
            first
        else
            .{ .id = try emitPhi(builder, builder.bits_type, values.items, parents.items), .value_type = .bits32 };
    }

    values.clearRetainingCapacity();
    parents.clearRetainingCapacity();
    var missing_scc = false;
    var different_scc = false;
    var first_scc: u32 = 0;
    for (predecessors.items, 0..) |pred, index| {
        const id = states[pred].scc;
        if (id == 0) missing_scc = true;
        if (index == 0) first_scc = id else if (id != first_scc) different_scc = true;
        try values.append(builder.allocator, .{ .id = id, .value_type = .bits32 });
        try parents.append(builder.allocator, labels[pred]);
    }
    if (!missing_scc) {
        merged.scc = if (!different_scc)
            first_scc
        else
            try emitPhi(builder, builder.bool_type, values.items, parents.items);
    }
    return merged;
}

fn translateStructured(builder: *Builder, program: *const instruction.Program, graph: *const control_flow.Graph) Error!void {
    if (graph.back_edge_count != 0) return Error.UnsupportedControlFlow;
    const labels = try builder.allocator.alloc(u32, graph.blocks.items.len);
    defer builder.allocator.free(labels);
    labels[0] = builder.label;
    for (labels[1..]) |*label| label.* = builder.id();
    const states = try builder.allocator.alloc(State, graph.blocks.items.len);
    defer builder.allocator.free(states);
    @memset(states, State{});

    for (graph.blocks.items) |block| {
        try builder.emit(&builder.body, 248, &.{labels[block.index]}); // OpLabel
        const incoming = try mergeState(builder, graph, states, labels, block.index);
        builder.restore(incoming);
        if (block.index == 0) try builder.initializeStageInputs();

        const first: usize = block.first_instruction;
        const end: usize = first + block.instruction_count;
        const last = program.instructions.items[end - 1];
        for (program.instructions.items[first..end]) |inst| {
            if (inst.opcode.isBranch() or inst.opcode == .s_endpgm or inst.opcode == .s_setpc_b64) continue;
            try builder.lower(inst);
        }
        states[block.index] = builder.snapshot();

        if (last.opcode == .s_endpgm) {
            try builder.emit(&builder.body, 253, &.{}); // OpReturn
        } else if (last.opcode == .s_branch) {
            const target = graph.blockForPc(last.branch_target) orelse return Error.UnsupportedControlFlow;
            try builder.emit(&builder.body, 249, &.{labels[target]}); // OpBranch
        } else if (last.opcode.isBranch()) {
            const selection = graph.selectionForHeader(block.index) orelse return Error.UnsupportedControlFlow;
            if (selection.condition != .scc or builder.scc == 0) return Error.UnsupportedControlFlow;
            var condition = builder.scc;
            if (!selection.branch_when) {
                const inverted = builder.id();
                try builder.emit(&builder.body, 168, &.{ builder.bool_type, inverted, condition }); // OpLogicalNot
                condition = inverted;
            }
            try builder.emit(&builder.body, 247, &.{ labels[selection.merge], 0 }); // OpSelectionMerge
            try builder.emit(&builder.body, 250, &.{
                condition,
                labels[selection.branch_successor],
                labels[selection.fallthrough_successor],
            });
        } else if (block.index + 1 < graph.blocks.items.len) {
            try builder.emit(&builder.body, 249, &.{labels[block.index + 1]});
        } else {
            return Error.UnsupportedControlFlow;
        }
    }
}

fn assemble(allocator: std.mem.Allocator, builder: *Builder, options: Options) Error!Module {
    var words: std.ArrayList(u32) = .empty;
    errdefer words.deinit(allocator);
    try words.appendSlice(allocator, &.{
        0x0723_0203,
        0x0001_0500,
        0x0050_4300,
        builder.next_id,
        0,
    });
    try appendInstruction(allocator, &words, 17, &.{1});
    try appendInstruction(allocator, &words, 14, &.{ 0, 1 });
    var entry_point: std.ArrayList(u32) = .empty;
    defer entry_point.deinit(allocator);
    try entry_point.appendSlice(allocator, &.{ @intFromEnum(options.stage), builder.main_function, 0x6e69_616d, 0 });
    if (builder.storage_array != 0) try entry_point.append(allocator, builder.storage_array);
    if (builder.sampled_image_array != 0) try entry_point.append(allocator, builder.sampled_image_array);
    if (builder.local_invocation_index != 0) try entry_point.append(allocator, builder.local_invocation_index);
    if (builder.workgroup_id_input != 0) try entry_point.append(allocator, builder.workgroup_id_input);
    if (builder.local_invocation_id_input != 0) try entry_point.append(allocator, builder.local_invocation_id_input);
    if (builder.vertex_index_input != 0) try entry_point.append(allocator, builder.vertex_index_input);
    if (builder.position_output != 0) try entry_point.append(allocator, builder.position_output);
    if (builder.color_output != 0) try entry_point.append(allocator, builder.color_output);
    try appendInstruction(allocator, &words, 15, entry_point.items);
    switch (options.stage) {
        .fragment => try appendInstruction(allocator, &words, 16, &.{ builder.main_function, 7 }),
        .compute => try appendInstruction(allocator, &words, 16, &.{ builder.main_function, 17, options.local_size[0], options.local_size[1], options.local_size[2] }),
        .vertex => {},
    }
    try words.appendSlice(allocator, builder.annotations.items);
    try words.appendSlice(allocator, builder.declarations.items);
    try appendInstruction(allocator, &words, 54, &.{ builder.void_type, builder.main_function, 0, builder.function_type });
    try words.appendSlice(allocator, builder.body.items);
    try appendInstruction(allocator, &words, 56, &.{});
    return .{ .words = try words.toOwnedSlice(allocator) };
}

/// Translates the executable ALU/SDWA subset and forward scalar selections.
/// The writer fails explicitly for operations or control-flow shapes whose
/// semantics are not implemented; it never emits a placeholder guest shader.
pub fn translate(allocator: std.mem.Allocator, program: *const instruction.Program, options: Options) Error!Module {
    var effective = options;
    for (program.instructions.items) |candidate| {
        if (candidate.dst.kind == .exec_lo) effective.uses_execution_mask = true;
    }
    var builder = try Builder.init(allocator, effective);
    defer builder.deinit();
    var graph = try control_flow.build(allocator, program);
    defer graph.deinit(allocator);
    if (graph.blocks.items.len == 1) {
        try builder.emit(&builder.body, 248, &.{builder.label});
        try builder.initializeStageInputs();
        for (program.instructions.items) |inst| try builder.lower(inst);
        try builder.emit(&builder.body, 253, &.{});
    } else {
        try translateStructured(&builder, program, &graph);
    }
    return assemble(allocator, &builder, options);
}

fn containsOpcode(words: []const u32, wanted: u16) bool {
    var index: usize = 5;
    while (index < words.len) {
        const first = words[index];
        if (@as(u16, @truncate(first)) == wanted) return true;
        const count = first >> 16;
        if (count == 0) return false;
        index += count;
    }
    return false;
}

fn countOpcode(words: []const u32, wanted: u16) usize {
    var count: usize = 0;
    var index: usize = 5;
    while (index < words.len) {
        const first = words[index];
        if (@as(u16, @truncate(first)) == wanted) count += 1;
        const word_count = first >> 16;
        if (word_count == 0) break;
        index += word_count;
    }
    return count;
}

fn firstInstructionOperand(words: []const u32, wanted: u16, operand_index: usize) ?u32 {
    var index: usize = 5;
    while (index < words.len) {
        const first = words[index];
        const count: usize = @intCast(first >> 16);
        if (@as(u16, @truncate(first)) == wanted and operand_index + 1 < count) {
            return words[index + operand_index + 1];
        }
        if (count == 0) return null;
        index += count;
    }
    return null;
}

test "straight-line vector ALU translates to a SPIR-V function" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255, // v_mov_b32 v0, literal
        0x3f80_0000,
        (@as(u32, 3) << 25) | (@as(u32, 1) << 17) | 256, // v_add_f32 v1, v0, v0
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute, .local_size = .{ 8, 1, 1 } });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0x0723_0203), module.words[0]);
    try std.testing.expectEqual(@as(u32, 0x0001_0500), module.words[1]);
    try std.testing.expect(containsOpcode(module.words, 129)); // OpFAdd
    try std.testing.expect(containsOpcode(module.words, 253)); // OpReturn
}

test "vector shifts and low unsigned multiply lower to SPIR-V arithmetic" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);

    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 16, .signed_val = 16 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 2, .signed_val = 2 },
        .src_count = 1,
    });
    inline for ([_]isa.Opcode{
        .v_lshr_b32,
        .v_lshrrev_b32,
        .v_ashr_i32,
        .v_ashrrev_i32,
        .v_lshl_b32,
        .v_lshlrev_b32,
        .v_mul_lo_u32,
    }, 0..) |opcode, index| {
        try program.instructions.append(std.testing.allocator, .{
            .opcode = opcode,
            .dst = .{ .kind = .vgpr, .reg = @intCast(index + 2) },
            .src0 = .{ .kind = .vgpr, .reg = 0 },
            .src1 = .{ .kind = .vgpr, .reg = 1 },
            .src_count = 2,
        });
    }
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 194)); // OpShiftRightLogical
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 195)); // OpShiftRightArithmetic
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 196)); // OpShiftLeftLogical
    try std.testing.expect(containsOpcode(module.words, 132)); // OpIMul
}

test "instruction prefetch is a translation no-op" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbfa0_0001, // s_inst_prefetch 1
        0xbf81_0000, // s_endpgm
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 253)); // OpReturn
}

test "native vector shift-add masks its shift and adds the third source" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xd746_0000,
        @as(u32, 129) | (@as(u32, 130) << 9) | (@as(u32, 131) << 18),
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 199)); // OpBitwiseAnd
    try std.testing.expect(containsOpcode(module.words, 196)); // OpShiftLeftLogical
    try std.testing.expect(containsOpcode(module.words, 128)); // OpIAdd
}

test "vertex system value and position export lower to a stage interface" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 17) | (@as(u32, 0x06) << 9) | 256, // v_cvt_f32_u32 v1, v0
        (@as(u32, 0x3f) << 25) | (@as(u32, 2) << 17) | (@as(u32, 0x01) << 9) | 255,
        0,
        (@as(u32, 0x3f) << 25) | (@as(u32, 3) << 17) | (@as(u32, 0x01) << 9) | 255,
        0,
        (@as(u32, 0x3f) << 25) | (@as(u32, 4) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3f80_0000,
        0xf800_08cf, // exp pos0, v1, v2, v3, v4 done
        0x0403_0201,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .vertex,
        .vertex_index_vgpr = 0,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 61)); // OpLoad VertexIndex
    try std.testing.expect(containsOpcode(module.words, 112)); // OpConvertUToF
    try std.testing.expect(containsOpcode(module.words, 80)); // OpCompositeConstruct
    try std.testing.expect(containsOpcode(module.words, 62)); // OpStore Position
}

/// One indexed buffer access, encoded the way the hardware spells it.
fn testMubuf(opcode: u7, byte_offset: u12, data: u8, address: u8, resource: u8) [2]u32 {
    return .{
        0xe000_0000 | (@as(u32, opcode) << 18) | (1 << 13) | byte_offset,
        (0x80 << 24) | (@as(u32, resource / 4) << 16) | (@as(u32, data) << 8) | address,
    };
}

fn testSop1(opcode: u8, destination: u8, source: u9) u32 {
    return 0xbe80_0000 | (@as(u32, destination) << 16) | (@as(u32, opcode) << 8) | source;
}

test "an indexed copy is held to its buffer bounds and its execution mask" {
    // The shape of nearly every compute kernel a title dispatches: each lane
    // copies the element its own index names. What is established here is the
    // two rules around that — a lane reading past the end of its source is
    // given zero, a lane writing past the end of its destination is ignored,
    // and lanes the mask has switched off do neither.
    const decoder = @import("decoder.zig");
    const code =
        [_]u32{testSop1(0x04, 126, 128 + 15)} ++ // s_mov_b64 exec, 15 -> lanes 0..3
        testMubuf(0x0c, 0, 1, 0, 8) ++ // v1 <- source[lane]
        testMubuf(0x1c, 0, 1, 0, 12) ++ // destination[lane] <- v1
        testMubuf(0x0c, 16, 2, 0, 8) ++ // v2 <- past the end of the source
        testMubuf(0x1c, 32, 2, 0, 12) ++ // destination past its end <- v2
        [_]u32{0xbf81_0000};

    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);

    const storage = [_]StorageBufferBinding{
        .{ .resource_sgpr = 8, .descriptor_index = 0, .stride = 4, .extent_bytes = 16 },
        .{ .resource_sgpr = 12, .descriptor_index = 1, .stride = 4, .extent_bytes = 32 },
    };
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .local_size = .{ 16, 1, 1 },
        .storage_buffers = &storage,
        .descriptor_array_length = 2,
        // The index each lane copies by is its own invocation id, which the
        // hardware places in v0 before the kernel starts.
        .compute_inputs = .{ .local_invocation_id_components = 1 },
    });
    defer module.deinit(std.testing.allocator);

    // A bound turns every access into a question, and the answers are chosen
    // and branched on rather than assumed.
    try std.testing.expect(containsOpcode(module.words, 176)); // OpULessThan
    try std.testing.expect(containsOpcode(module.words, 169)); // OpSelect
    try std.testing.expect(containsOpcode(module.words, 247)); // OpSelectionMerge
    try std.testing.expect(containsOpcode(module.words, 250)); // OpBranchConditional
    // The mask is answered per lane, which means reading which lane this is.
    try std.testing.expect(containsOpcode(module.words, 61)); // OpLoad LocalInvocationIndex
    try std.testing.expect(containsOpcode(module.words, 171)); // OpINotEqual
    try std.testing.expect(containsOpcode(module.words, 167)); // OpLogicalAnd
}

test "without a known extent nothing is checked" {
    // A caller that has not recovered a descriptor says so by supplying no
    // extent, and the access is emitted as it always was. Guessing a size would
    // be worse than leaving it unchecked: it would drop writes a title made
    // legitimately.
    const decoder = @import("decoder.zig");
    const code =
        [_]u32{ (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 17) | (@as(u32, 0x01) << 9) | 255, 7 } ++
        testMubuf(0x1c, 0, 1, 0, 8) ++ [_]u32{0xbf81_0000};
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);

    const storage = [_]StorageBufferBinding{
        .{ .resource_sgpr = 8, .descriptor_index = 0, .stride = 4 },
    };
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
        .descriptor_array_length = 1,
        .compute_inputs = .{ .local_invocation_id_components = 1 },
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 62)); // OpStore
    try std.testing.expect(!containsOpcode(module.words, 176)); // no OpULessThan
    try std.testing.expect(!containsOpcode(module.words, 250)); // no OpBranchConditional
}

test "fragment MRT0 export lowers to location zero" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 0) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3f80_0000,
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 17) | (@as(u32, 0x01) << 9) | 255,
        0,
        (@as(u32, 0x3f) << 25) | (@as(u32, 2) << 17) | (@as(u32, 0x01) << 9) | 255,
        0,
        (@as(u32, 0x3f) << 25) | (@as(u32, 3) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3f80_0000,
        0xf800_080f, // exp mrt0, v0, v1, v2, v3 done
        0x0302_0100,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 80)); // OpCompositeConstruct
    try std.testing.expect(containsOpcode(module.words, 62)); // OpStore MRT0
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(Stage.fragment));
}

test "fragment image sample lowers through a combined descriptor array" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 0) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3f00_0000,
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3f00_0000,
        0xf080_0f08, // image_sample dim:2d dmask:xyzw v2, v[0:1], s[0:7], s[8:11]
        0x0040_0200,
        0xf800_080f, // exp mrt0, v2, v3, v4, v5 done
        0x0504_0302,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 0,
        .sampler_sgpr = 8,
        .descriptor_index = 3,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 25)); // OpTypeImage
    try std.testing.expect(containsOpcode(module.words, 27)); // OpTypeSampledImage
    try std.testing.expect(containsOpcode(module.words, 87)); // OpImageSampleImplicitLod
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 81)); // RGBA extracts
}

test "MUBUF dword load and store lower through a descriptor array" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe030_0000, // buffer_load_dword v0, v0, s4:s7, 0
        0x8001_0000,
        0xe070_0004, // buffer_store_dword v0, v0, s4:s7, 0 offset:4
        0x8001_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 4, .descriptor_index = 7 }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
        .descriptor_array_length = 8,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 29)); // OpTypeRuntimeArray
    try std.testing.expect(containsOpcode(module.words, 65)); // OpAccessChain
    try std.testing.expect(containsOpcode(module.words, 61)); // OpLoad
    try std.testing.expect(containsOpcode(module.words, 62)); // OpStore
}

test "MUBUF format load and store lower as multi-dword transfers" {
    const decoder = @import("decoder.zig");
    // FORMAT ops with 32-bit components use the same MUBUF path as dwordxN.
    // Encoded without idxen so the address does not depend on an undefined
    // VGPR; the live Unity kernel adds an index after computing it.
    const code = [_]u32{
        0xe00c_0000, // buffer_load_format_xyzw v0:v3, v0, s4:s7, 0
        0x8001_0000,
        0xe01c_0010, // buffer_store_format_xyzw v0:v3, v0, s4:s7, offset:16
        0x8001_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(isa.Opcode.buffer_load_format_xyzw, program.instructions.items[0].opcode);
    try std.testing.expectEqual(isa.Opcode.buffer_store_format_xyzw, program.instructions.items[1].opcode);

    const storage = [_]StorageBufferBinding{.{
        .resource_sgpr = 4,
        .descriptor_index = 0,
        .stride = 16,
        .extent_bytes = 64,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 61)); // OpLoad
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 62)); // four component stores
}

test "resolved SMEM descriptor prolog specializes before MUBUF" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf408_0200, // s_load_dwordx4 s8:s11, s0:s1, 0
        125 << 25,
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
        0x1122_3344,
        0xe070_0000, // buffer_store_dword v0, v0, s8:s11, 0
        0x8002_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 8, .descriptor_index = 0 }};
    const scalars = [_]ScalarRegister{
        .{ .register = 8, .value = 0x1000 },
        .{ .register = 9, .value = 0 },
        .{ .register = 10, .value = 64 },
        .{ .register = 11, .value = 0 },
    };
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
        .scalar_registers = &scalars,
        .specialized_scalar_prefix_end = 8,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 62)); // OpStore
}

test "vector and subword MUBUF operations lower explicitly" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe038_0000, // buffer_load_dwordx4 v0:v3, v0, s4:s7, 0
        0x8001_0000,
        0xe078_0010, // buffer_store_dwordx4 v0:v3, v0, s4:s7, offset:16
        0x8001_0000,
        0xe024_0001, // buffer_load_sbyte v4, v0, s4:s7, offset:1
        0x8001_0400,
        0xe068_0002, // buffer_store_short v4, v0, s4:s7, offset:2
        0x8001_0400,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 4, .descriptor_index = 2 }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 200)); // OpNot for subword RMW
    try std.testing.expect(containsOpcode(module.words, 195)); // signed extraction
}

test "MUBUF atomics and add_tid lower to explicit SPIR-V operations" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255, // v_mov_b32 v0, literal
        5,
        0xe0c0_0000, 0x8001_0000, // buffer_atomic_swap
        0xe0c8_0000, 0x8001_0000, // buffer_atomic_add
        0xe0cc_0000, 0x8001_0000, // buffer_atomic_sub
        0xe0d4_0000, 0x8001_0000, // buffer_atomic_smin
        0xe0d8_0000, 0x8001_0000, // buffer_atomic_umin
        0xe0dc_0000, 0x8001_0000, // buffer_atomic_smax
        0xe0e0_0000, 0x8001_0000, // buffer_atomic_umax
        0xe0e4_0000, 0x8001_0000, // buffer_atomic_and
        0xe0e8_0000, 0x8001_0000, // buffer_atomic_or
        0xe0ec_0000, 0x8001_0000, // buffer_atomic_xor
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{
        .resource_sgpr = 4,
        .descriptor_index = 0,
        .stride = 4,
        .add_thread_id = true,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .local_size = .{ 4, 1, 1 },
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 229)); // OpAtomicExchange
    inline for (234..243) |opcode| {
        try std.testing.expect(containsOpcode(module.words, opcode));
    }
    try std.testing.expect(containsOpcode(module.words, 225)); // OpMemoryBarrier
    try std.testing.expect(containsOpcode(module.words, 132)); // lane * descriptor stride
}

test "MUBUF glc controls atomic return-value writeback" {
    const decoder = @import("decoder.zig");
    const common_tail = [_]u32{
        0x8001_0000,
        0xe070_0000, // buffer_store_dword v0, v0, s8:s11, 0
        0x8002_0000,
        0xbf81_0000,
    };
    const storage = [_]StorageBufferBinding{
        .{ .resource_sgpr = 4, .descriptor_index = 0 },
        .{ .resource_sgpr = 8, .descriptor_index = 1 },
    };

    for ([_]bool{ false, true }) |glc| {
        const code = [_]u32{
            (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
            5,
            0xe0c8_0000 | if (glc) @as(u32, 1 << 14) else 0,
            common_tail[0],
            common_tail[1],
            common_tail[2],
            common_tail[3],
        };
        var program = try decoder.decodeProgram(std.testing.allocator, &code);
        defer program.deinit(std.testing.allocator);
        var module = try translate(std.testing.allocator, &program, .{
            .stage = .compute,
            .storage_buffers = &storage,
        });
        defer module.deinit(std.testing.allocator);

        const atomic_result = firstInstructionOperand(module.words, 234, 1).?;
        const stored_value = firstInstructionOperand(module.words, 62, 1).?;
        if (glc) {
            try std.testing.expectEqual(atomic_result, stored_value);
        } else {
            try std.testing.expect(atomic_result != stored_value);
        }
    }
}

test "cross-dword short load and store lower as two byte accesses" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe02c_0003, // buffer_load_sshort at byte 3 crosses a dword
        0x8001_0000,
        0xe068_0007, // buffer_store_short at byte 7 crosses a dword
        0x8001_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 4, .descriptor_index = 0 }};
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute, .storage_buffers = &storage });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 62)); // two byte stores
    try std.testing.expect(containsOpcode(module.words, 195)); // signed extension
}

test "swizzled V# addressing lowers index_stride permutation" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
        1, // v_mov_b32 v0, index 1
        0xe034_2004, // buffer_load_dwordx2 idxen offset:4
        0x8001_0100,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{
        .resource_sgpr = 4,
        .descriptor_index = 0,
        .stride = 16,
        .swizzled = true,
        .index_stride = 2,
    }};
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute, .storage_buffers = &storage });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(countOpcode(module.words, 132) >= 4); // index and swizzle products for both dwords
    try std.testing.expect(containsOpcode(module.words, 196)); // index_lsb << 2
}

test "unsupported shader semantics never produce placeholder SPIR-V" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{ 0xf404_0201, 0, 0xbf81_0000 };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectError(Error.UnsupportedOpcode, translate(std.testing.allocator, &program, .{ .stage = .compute }));
}

test "forward scalar selection lowers with a structured merge and register phi" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbe80_0381, // s_mov_b32 s0, 1
        0xbe81_0381, // s_mov_b32 s1, 1
        0xbf06_0100, // s_cmp_eq_u32 s0, s1
        0xbf84_0002, // s_cbranch_scc0 -> pc 24
        0xbe82_0382, // s_mov_b32 s2, 2
        0xbf82_0001, // s_branch -> pc 28
        0xbe82_0383, // s_mov_b32 s2, 3
        0x8003_8102, // s_add_u32 s3, s2, 1
        0xbf81_0000, // s_endpgm
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 247)); // OpSelectionMerge
    try std.testing.expect(containsOpcode(module.words, 250)); // OpBranchConditional
    try std.testing.expect(containsOpcode(module.words, 245)); // OpPhi
}

test "back edges remain explicit until loop structuring is implemented" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{ 0xbf80_0000, 0xbf82_fffe, 0xbf81_0000 };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectError(
        Error.UnsupportedControlFlow,
        translate(std.testing.allocator, &program, .{ .stage = .compute }),
    );
}

test "full destination SDWA lowers source extraction before vector ALU" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
        0x3f80_0000,
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 17) | (@as(u32, 1) << 9) | 255,
        0x4000_0000,
        (@as(u32, 3) << 25) | (@as(u32, 2) << 17) | (@as(u32, 1) << 9) | 249,
        (@as(u32, 6) << 8) | (@as(u32, 4) << 16) | (@as(u32, 6) << 24),
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 199)); // OpBitwiseAnd
    try std.testing.expect(containsOpcode(module.words, 129)); // OpFAdd
}
