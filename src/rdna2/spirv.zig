// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Deterministic SPIR-V 1.5 writer for executable RDNA2 graphics and compute shaders.

const std = @import("std");
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
    /// When present, this descriptor is the value held by `resource_sgpr` at
    /// one particular memory instruction. Vertex shaders routinely reload the
    /// same four SGPRs with position and UV V#s at different PCs.
    instruction_pc: ?u32 = null,
    /// Scalar byte offset as it stood at `instruction_pc`. Attribute fetch
    /// prologs reuse (and overwrite) the same SOFFSET SGPR between position and
    /// UV loads even when both attributes share one interleaved allocation.
    soffset_value: ?u32 = null,
    /// This mapping came from the AGC vertex-attribute table. NGG prologs may
    /// copy the hardware vertex id into v0, v3, or another temporary before
    /// MUBUF; Vulkan's VertexIndex is the authoritative per-vertex index.
    use_vertex_index: bool = false,
    stride: u32 = 0,
    swizzled: bool = false,
    index_stride: u8 = 0,
    add_thread_id: bool = false,
    /// GFX10 unified FORMAT and destination-channel selectors captured from
    /// the V# descriptor. FORMAT loads convert packed vertex attributes to
    /// the values the shader expects; ordinary DWORD loads ignore these.
    unified_format: u8 = 0,
    dst_select: [4]u8 = .{ 4, 5, 6, 7 },
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
    dimension: SampledImageDimension = .two_d,
    /// Null is a stage-wide association. Compute shaders can qualify a binding
    /// by PC when the guest reloads the same T#/S# SGPR pair between samples.
    instruction_pc: ?u32 = null,
};

pub const SampledImageDimension = enum {
    two_d,
    three_d,
    cube,
};

pub const sampled_image_2d_descriptor_binding: u32 = 1;
pub const sampled_image_3d_descriptor_binding: u32 = 11;
pub const sampled_image_cube_descriptor_binding: u32 = 12;

fn sampledImageDimensionIndex(dimension: SampledImageDimension) usize {
    return switch (dimension) {
        .two_d => 0,
        .three_d => 1,
        .cube => 2,
    };
}

/// Static association between a GFX10 T# and an element in Vulkan's storage
/// image array. Storage images are declared with an exact format: this avoids
/// requiring the optional read/write-without-format device features and keeps
/// validation deterministic on older Vulkan drivers.
pub const StorageImageBinding = struct {
    resource_sgpr: u32,
    descriptor_index: u32,
    format: StorageImageFormat,
    dimension: StorageImageDimension = .two_d,
    dst_select: [4]u8 = .{ 4, 5, 6, 7 },
};

pub const StorageImageDimension = enum(u8) {
    two_d,
    three_d,
};

pub const StorageImageFormat = enum(u16) {
    r8_uint = 5,
    r16_unorm = 7,
    r16_uint = 11,
    r32_uint = 20,
    r11g11b10_float = 36,
    rgba8_unorm = 56,
    rgba8_uint = 60,
    rgba16_float = 71,
    rgba32_float = 77,
};

/// Scalar user data is captured by the API-neutral GPU state tracker. Supplying
/// it here lets address operands use the same values that the guest shader saw.
pub const ScalarRegister = struct {
    register: u32,
    value: u32,
    /// Null denotes state present at shader entry (USER_DATA or another host
    /// input). A PC denotes the SMEM instruction whose destination receives
    /// this value. Keeping these distinct is essential when a shader reuses
    /// the same SGPRs for several loads.
    producer_pc: ?u32 = null,
};

/// Places recovered SGPR values in a host-updated storage buffer instead of
/// baking them into OpConstant instructions. The list index is stable for one
/// shader/resource shape, while the value can change for every draw.
pub const DynamicScalarBinding = struct {
    binding: u32,
    value_base: u32 = 0,
};

pub const ComputeInputs = struct {
    workgroup_id_sgprs: [3]?u8 = .{ null, null, null },
    threadgroup_size_sgpr: ?u8 = null,
    local_invocation_id_components: u2 = 0,
};

/// One export reconstructed from the LDS record written by a PS5 NGG export
/// program.  On that ABI `S_SETPC_B64 s[6:7]` enters a hardware epilogue which
/// reads the record and performs the ordinary POS/PARAM exports.  Vulkan has
/// no equivalent hidden continuation, so the backend describes the recovered
/// sources and the translator emits the export at the terminal SETPC.
pub const NggLdsExport = struct {
    target: u6,
    enable: u4,
    sources: [4]operand.Operand,
};

pub const Options = struct {
    stage: Stage,
    local_size: [3]u32 = .{ 1, 1, 1 },
    /// Pixel extent used to normalize FragCoord when the paired vertex PARAM
    /// interface is unavailable. The backend supplies the active color target.
    fragment_extent: [2]u32 = .{ 1280, 720 },
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
    storage_images: []const StorageImageBinding = &.{},
    /// Amount of per-workgroup LDS made available by COMPUTE_PGM_RSRC2. DS
    /// instructions address it in bytes; the SPIR-V declaration is a u32 array.
    workgroup_memory_size_bytes: u32 = 0,
    /// POS/PARAM values encoded in a terminal NGG LDS record. When present,
    /// vertex-stage DS writes are only the transport for the hardware epilogue
    /// and are replaced by these explicit Vulkan stage outputs.
    ngg_lds_exports: []const NggLdsExport = &.{},
    /// PARAM locations exported by a vertex shader, or raw VINTRP ATTR slots
    /// consumed by a fragment shader. `fragment_input_controls` maps the latter
    /// onto the former before declaring the Vulkan interface.
    parameter_mask: u32 = 0,
    /// SPI_PS_INPUT_CNTL values indexed by the raw VINTRP ATTR slot. The low
    /// five bits select the matching VS PARAM export; bit 10 requests flat
    /// interpolation. An empty slice preserves the identity mapping.
    fragment_input_controls: []const u32 = &.{},
    /// Standalone translation infers PARAM inputs from VINTRP. A graphics
    /// backend that knows the paired VS interface can disable that inference
    /// and supply only locations the vertex stage actually exports.
    infer_fragment_parameter_mask: bool = true,
    scalar_registers: []const ScalarRegister = &.{},
    dynamic_scalar_binding: ?DynamicScalarBinding = null,
    compute_inputs: ?ComputeInputs = null,
    descriptor_array_length: u32 = 64,
    /// Exclusive PC ending a straight scalar prolog evaluated against the
    /// captured dispatch state and checked guest memory.
    specialized_scalar_prefix_end: u32 = 0,
    /// Keep the permissive straight-line path for runtime bring-up. Offline
    /// shader validation can disable it to prove that the complete CFG was
    /// represented with structured SPIR-V selections.
    allow_control_flow_fallback: bool = true,
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
    /// True when structured control-flow lowering was unavailable and the
    /// translator used its linear graphics bring-up fallback.
    used_control_flow_fallback: bool = false,

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
    arithmetic_carry: u32 = 0,
    valid: bool = false,
};

const BufferAddress = struct {
    binding: StorageBufferBinding,
    byte_offset: u32,
};

const BufferFormat = struct {
    data: u8,
    number: u8,
};

const BufferComponentLayout = struct {
    byte_offset: u8,
    bit_offset: u8 = 0,
    bit_count: u8,
};

/// RDNA2 ISA table 47. Keeping this static is intentional: each translated
/// Vulkan binding is already qualified by the exact guest instruction PC, so
/// unlike a reusable native descriptor the format cannot change underneath
/// the generated module.
fn decodeBufferUnifiedFormat(format: u8) ?BufferFormat {
    return switch (format) {
        0 => .{ .data = 0, .number = 0 },
        1...6 => .{ .data = 1, .number = format - 1 },
        7...12 => .{ .data = 2, .number = format - 7 },
        13 => .{ .data = 2, .number = 7 },
        14...19 => .{ .data = 3, .number = format - 14 },
        20 => .{ .data = 4, .number = 4 },
        21 => .{ .data = 4, .number = 5 },
        22 => .{ .data = 4, .number = 7 },
        23...28 => .{ .data = 5, .number = format - 23 },
        29 => .{ .data = 5, .number = 7 },
        36 => .{ .data = 6, .number = 7 },
        43 => .{ .data = 7, .number = 7 },
        44 => .{ .data = 8, .number = 0 },
        45 => .{ .data = 8, .number = 1 },
        48 => .{ .data = 8, .number = 4 },
        49 => .{ .data = 8, .number = 5 },
        50...55 => .{ .data = 9, .number = format - 50 },
        56...61 => .{ .data = 10, .number = format - 56 },
        62 => .{ .data = 11, .number = 4 },
        63 => .{ .data = 11, .number = 5 },
        64 => .{ .data = 11, .number = 7 },
        65...70 => .{ .data = 12, .number = format - 65 },
        71 => .{ .data = 12, .number = 7 },
        72 => .{ .data = 13, .number = 4 },
        73 => .{ .data = 13, .number = 5 },
        74 => .{ .data = 13, .number = 7 },
        75 => .{ .data = 14, .number = 4 },
        76 => .{ .data = 14, .number = 5 },
        77 => .{ .data = 14, .number = 7 },
        else => null,
    };
}

fn bufferComponentLayout(data_format: u8, component: u8) ?BufferComponentLayout {
    return switch (data_format) {
        1 => if (component == 0) .{ .byte_offset = 0, .bit_count = 8 } else null,
        2 => if (component == 0) .{ .byte_offset = 0, .bit_count = 16 } else null,
        3 => switch (component) {
            0 => .{ .byte_offset = 0, .bit_count = 8 },
            1 => .{ .byte_offset = 1, .bit_count = 8 },
            else => null,
        },
        4 => if (component == 0) .{ .byte_offset = 0, .bit_count = 32 } else null,
        5 => switch (component) {
            0 => .{ .byte_offset = 0, .bit_count = 16 },
            1 => .{ .byte_offset = 2, .bit_count = 16 },
            else => null,
        },
        6 => switch (component) {
            0 => .{ .byte_offset = 0, .bit_offset = 0, .bit_count = 10 },
            1 => .{ .byte_offset = 0, .bit_offset = 10, .bit_count = 11 },
            2 => .{ .byte_offset = 0, .bit_offset = 21, .bit_count = 11 },
            else => null,
        },
        7 => switch (component) {
            0 => .{ .byte_offset = 0, .bit_offset = 0, .bit_count = 11 },
            1 => .{ .byte_offset = 0, .bit_offset = 11, .bit_count = 11 },
            2 => .{ .byte_offset = 0, .bit_offset = 22, .bit_count = 10 },
            else => null,
        },
        8 => switch (component) {
            0 => .{ .byte_offset = 0, .bit_offset = 0, .bit_count = 10 },
            1 => .{ .byte_offset = 0, .bit_offset = 10, .bit_count = 10 },
            2 => .{ .byte_offset = 0, .bit_offset = 20, .bit_count = 10 },
            3 => .{ .byte_offset = 0, .bit_offset = 30, .bit_count = 2 },
            else => null,
        },
        9 => switch (component) {
            0 => .{ .byte_offset = 0, .bit_offset = 0, .bit_count = 2 },
            1 => .{ .byte_offset = 0, .bit_offset = 2, .bit_count = 10 },
            2 => .{ .byte_offset = 0, .bit_offset = 12, .bit_count = 10 },
            3 => .{ .byte_offset = 0, .bit_offset = 22, .bit_count = 10 },
            else => null,
        },
        10 => if (component < 4)
            .{ .byte_offset = component, .bit_count = 8 }
        else
            null,
        11 => if (component < 2)
            .{ .byte_offset = component * 4, .bit_count = 32 }
        else
            null,
        12 => if (component < 4)
            .{ .byte_offset = component * 2, .bit_count = 16 }
        else
            null,
        13 => if (component < 3)
            .{ .byte_offset = component * 4, .bit_count = 32 }
        else
            null,
        14 => if (component < 4)
            .{ .byte_offset = component * 4, .bit_count = 32 }
        else
            null,
        else => null,
    };
}

const WorkgroupAccess = struct {
    pointer: u32,
    in_range: u32,
};

fn storageImageValueType(format: StorageImageFormat) ValueType {
    return switch (format) {
        .r8_uint, .r16_uint, .r32_uint, .rgba8_uint => .bits32,
        .r16_unorm, .r11g11b10_float, .rgba8_unorm, .rgba16_float, .rgba32_float => .float32,
    };
}

fn storageImageSpirvFormat(format: StorageImageFormat) u32 {
    return switch (format) {
        .rgba32_float => 1, // Rgba32f
        .rgba16_float => 2, // Rgba16f
        .rgba8_unorm => 4, // Rgba8
        .r11g11b10_float => 8, // R11fG11fB10f
        .r16_unorm => 14, // R16
        .rgba8_uint => 32, // Rgba8ui
        .r32_uint => 33, // R32ui
        .r16_uint => 38, // R16ui
        .r8_uint => 39, // R8ui
    };
}

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
    vector2_signed_type: u32 = 0,
    vector3_type: u32 = 0,
    vector4_type: u32 = 0,
    main_function: u32,
    label: u32,
    stage: Stage,
    vertex_index_vgpr: ?u8,
    vertex_index_input: u32 = 0,
    instance_index_input: u32 = 0,
    position_output: u32 = 0,
    color_output: u32 = 0,
    parameter_variables: [32]u32 = @splat(0),
    /// BuiltIn FragCoord (float4) for fragment UV fallback when PARAM interps
    /// are not yet wired from the vertex stage.
    frag_coord_input: u32 = 0,
    storage_bindings: []const StorageBufferBinding,
    sampled_bindings: []const SampledImageBinding,
    storage_image_bindings: []const StorageImageBinding,
    ngg_lds_exports: []const NggLdsExport,
    storage_array: u32 = 0,
    storage_word_pointer_type: u32 = 0,
    storage_block_pointer_type: u32 = 0,
    local_invocation_index: u32 = 0,
    /// The execution mask, as low and high halves, once a shader has narrowed
    /// it. Null means untouched — every lane on — which is how a wave starts
    /// and needs no test emitted for it.
    exec_mask: ?[2]u32 = null,
    workgroup_id_input: u32 = 0,
    local_invocation_id_input: u32 = 0,
    compute_inputs: ?ComputeInputs,
    local_size: [3]u32,
    fragment_extent: [2]u32,
    vector2_type: u32 = 0,
    vector2_bits_type: u32 = 0,
    sampled_image_image_types: [3]u32 = @splat(0),
    sampled_image_types: [3]u32 = @splat(0),
    sampled_image_arrays: [3]u32 = @splat(0),
    sampled_image_pointer_types: [3]u32 = @splat(0),
    storage_image_types: [8]u32 = @splat(0),
    storage_image_vector_types: [8]u32 = @splat(0),
    storage_image_variables: [8]u32 = @splat(0),
    workgroup_memory: u32 = 0,
    workgroup_word_pointer_type: u32 = 0,
    workgroup_memory_words: u32 = 0,
    /// GLSL.std.450 extended instruction set (PackHalf2x16, etc.). 0 = unused.
    glsl_std_450: u32 = 0,
    scalar_specializations: []const ScalarRegister,
    dynamic_scalar_binding: ?DynamicScalarBinding,
    scalar_buffer: u32 = 0,
    scalar_word_pointer_type: u32 = 0,
    specialized_scalar_prefix_end: u32,
    scc: u32 = 0,
    /// Carry chained specifically between S_ADD_U32 and S_ADDC_U32. Keep it
    /// separate from branch SCC until all scalar arithmetic flag consumers are
    /// modelled, so adding carry support cannot perturb established CFG paths.
    arithmetic_carry: u32 = 0,
    used_control_flow_fallback: bool = false,

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
            .storage_image_bindings = options.storage_images,
            .ngg_lds_exports = options.ngg_lds_exports,
            .compute_inputs = options.compute_inputs,
            .local_size = options.local_size,
            .fragment_extent = options.fragment_extent,
            .scalar_specializations = options.scalar_registers,
            .dynamic_scalar_binding = options.dynamic_scalar_binding,
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

        if (options.dynamic_scalar_binding) |dynamic| {
            const runtime_words = self.id();
            const storage_block = self.id();
            const storage_pointer = self.id();
            self.scalar_word_pointer_type = self.id();
            self.scalar_buffer = self.id();
            try self.emit(&self.annotations, 71, &.{ runtime_words, 6, 4 }); // ArrayStride 4
            try self.emit(&self.annotations, 72, &.{ storage_block, 0, 35, 0 }); // member Offset 0
            try self.emit(&self.annotations, 71, &.{ storage_block, 2 }); // Block
            try self.emit(&self.annotations, 71, &.{ self.scalar_buffer, 34, 0 }); // DescriptorSet 0
            try self.emit(&self.annotations, 71, &.{ self.scalar_buffer, 33, dynamic.binding }); // Binding
            try self.emit(&self.declarations, 29, &.{ runtime_words, self.bits_type }); // OpTypeRuntimeArray
            try self.emit(&self.declarations, 30, &.{ storage_block, runtime_words }); // OpTypeStruct
            try self.emit(&self.declarations, 32, &.{ storage_pointer, 12, storage_block }); // ptr StorageBuffer
            try self.emit(&self.declarations, 32, &.{ self.scalar_word_pointer_type, 12, self.bits_type });
            try self.emit(&self.declarations, 59, &.{ storage_pointer, self.scalar_buffer, 12 }); // OpVariable
        }

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

                for (0..32) |location| {
                    const bit = @as(u32, 1) << @intCast(location);
                    if (options.parameter_mask & bit == 0) continue;
                    const variable = self.id();
                    self.parameter_variables[location] = variable;
                    try self.emit(&self.annotations, 71, &.{ variable, 30, @intCast(location) }); // Location
                    try self.emit(&self.declarations, 59, &.{ output_pointer, variable, 3 }); // OpVariable
                }

                if (options.vertex_index_vgpr != null) {
                    const input_pointer = self.id();
                    self.vertex_index_input = self.id();
                    try self.emit(&self.annotations, 71, &.{ self.vertex_index_input, 11, 42 }); // BuiltIn VertexIndex
                    try self.emit(&self.declarations, 32, &.{ input_pointer, 1, self.signed_type }); // ptr Input
                    try self.emit(&self.declarations, 59, &.{ input_pointer, self.vertex_index_input, 1 }); // OpVariable

                    const instance_pointer = self.id();
                    self.instance_index_input = self.id();
                    try self.emit(&self.annotations, 71, &.{ self.instance_index_input, 11, 43 }); // BuiltIn InstanceIndex
                    try self.emit(&self.declarations, 32, &.{ instance_pointer, 1, self.signed_type }); // ptr Input
                    try self.emit(&self.declarations, 59, &.{ instance_pointer, self.instance_index_input, 1 }); // OpVariable
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
                // FragCoord for UV fallback (BuiltIn 15).
                const frag_ptr = self.id();
                self.frag_coord_input = self.id();
                try self.emit(&self.annotations, 71, &.{ self.frag_coord_input, 11, 15 }); // BuiltIn FragCoord
                try self.emit(&self.declarations, 32, &.{ frag_ptr, 1, self.vector4_type }); // ptr Input
                try self.emit(&self.declarations, 59, &.{ frag_ptr, self.frag_coord_input, 1 }); // OpVariable

                for (0..32) |location| {
                    const bit = @as(u32, 1) << @intCast(location);
                    if (options.parameter_mask & bit == 0) continue;
                    const variable = self.id();
                    self.parameter_variables[location] = variable;
                    const control = if (location < options.fragment_input_controls.len)
                        options.fragment_input_controls[location]
                    else
                        @as(u32, @intCast(location));
                    try self.emit(&self.annotations, 71, &.{ variable, 30, control & 0x1f }); // Location
                    if (control & 0x400 != 0) {
                        try self.emit(&self.annotations, 71, &.{ variable, 14 }); // Flat
                    }
                    try self.emit(&self.declarations, 59, &.{ frag_ptr, variable, 1 }); // OpVariable
                }
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
            if (scalar.producer_pc != null) continue;
            if (options.dynamic_scalar_binding != null) continue;
            self.registers[scalar.register] = .{
                .id = try self.constant(.bits32, scalar.value),
                .value_type = .bits32,
            };
        }

        if (options.storage_buffers.len != 0) {
            // Storage buffers are used by compute and by graphics attribute
            // fetch / constant buffer MUBUF paths.
            if (options.descriptor_array_length == 0) {
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
                    if (previous.resource_sgpr == binding.resource_sgpr and
                        previous.instruction_pc == binding.instruction_pc)
                    {
                        return Error.InvalidStorageBinding;
                    }
                }
            }

            const runtime_words = self.id();
            const storage_block = self.id();
            const descriptor_count = try self.constant(.bits32, options.descriptor_array_length);
            const descriptor_array = self.id();
            const storage_array_pointer = self.id();
            self.storage_word_pointer_type = self.id();
            self.storage_block_pointer_type = self.id();
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
            try self.emit(&self.declarations, 32, &.{ self.storage_block_pointer_type, 12, storage_block });
            try self.emit(&self.declarations, 59, &.{ storage_array_pointer, self.storage_array, 12 }); // OpVariable

            var needs_thread_id = false;
            for (options.storage_buffers) |binding| {
                needs_thread_id = needs_thread_id or binding.add_thread_id;
            }
            needs_thread_id = needs_thread_id or options.uses_execution_mask;
            if (needs_thread_id) {
                const input_uint_pointer = self.id();
                self.local_invocation_index = self.id();
                const invocation_builtin: u32 = if (options.stage == .compute) 29 else 41;
                try self.emit(&self.annotations, 71, &.{ self.local_invocation_index, 11, invocation_builtin });
                if (options.stage == .fragment) {
                    try self.emit(&self.annotations, 71, &.{ self.local_invocation_index, 14 }); // Flat
                }
                try self.emit(&self.declarations, 32, &.{ input_uint_pointer, 1, self.bits_type }); // ptr Input
                try self.emit(&self.declarations, 59, &.{ input_uint_pointer, self.local_invocation_index, 1 }); // OpVariable
            }
        }
        if (options.sampled_images.len != 0) {
            if ((options.stage != .vertex and options.stage != .fragment and options.stage != .compute) or
                options.descriptor_array_length == 0)
            {
                return Error.InvalidStorageBinding;
            }
            var sampled_dimensions: [3]bool = @splat(false);
            for (options.sampled_images, 0..) |binding, index| {
                if (binding.resource_sgpr >= 128 or binding.sampler_sgpr >= 128 or
                    binding.descriptor_index >= options.descriptor_array_length)
                {
                    return Error.InvalidStorageBinding;
                }
                for (options.sampled_images[0..index]) |previous| {
                    if (previous.resource_sgpr == binding.resource_sgpr and
                        previous.sampler_sgpr == binding.sampler_sgpr and
                        previous.instruction_pc == binding.instruction_pc)
                    {
                        return Error.InvalidStorageBinding;
                    }
                }
                sampled_dimensions[sampledImageDimensionIndex(binding.dimension)] = true;
            }
            if (self.vector4_type == 0) {
                self.vector4_type = self.id();
                try self.emit(&self.declarations, 23, &.{ self.vector4_type, self.float_type, 4 }); // OpTypeVector
            }
            const descriptor_count = try self.constant(.bits32, options.descriptor_array_length);
            for (sampled_dimensions, 0..) |present, dimension_index| {
                if (!present) continue;
                const dimensions: u32 = if (dimension_index == 0) 2 else 3;
                // SPIR-V Dim values are 1=2D, 2=3D and 3=Cube. Keeping
                // volume and cube descriptors distinct is required because
                // Vulkan image-view compatibility follows the declared Dim.
                const spirv_dimension: u32 = switch (dimension_index) {
                    0 => 1,
                    1 => 2,
                    2 => 3,
                    else => unreachable,
                };
                const descriptor_binding = switch (dimension_index) {
                    0 => sampled_image_2d_descriptor_binding,
                    1 => sampled_image_3d_descriptor_binding,
                    2 => sampled_image_cube_descriptor_binding,
                    else => unreachable,
                };
                if (dimension_index == 0 and self.vector2_type == 0) {
                    self.vector2_type = self.id();
                    try self.emit(&self.declarations, 23, &.{ self.vector2_type, self.float_type, dimensions }); // OpTypeVector
                } else if (dimension_index != 0 and self.vector3_type == 0) {
                    self.vector3_type = self.id();
                    try self.emit(&self.declarations, 23, &.{ self.vector3_type, self.float_type, dimensions }); // OpTypeVector
                }
                const image_type = self.id();
                self.sampled_image_image_types[dimension_index] = image_type;
                self.sampled_image_types[dimension_index] = self.id();
                const descriptor_array = self.id();
                const array_pointer = self.id();
                self.sampled_image_pointer_types[dimension_index] = self.id();
                self.sampled_image_arrays[dimension_index] = self.id();
                try self.emit(&self.annotations, 71, &.{ self.sampled_image_arrays[dimension_index], 34, 0 }); // DescriptorSet 0
                try self.emit(&self.annotations, 71, &.{ self.sampled_image_arrays[dimension_index], 33, descriptor_binding });
                try self.emit(&self.declarations, 25, &.{ image_type, self.float_type, spirv_dimension, 0, 0, 0, 1, 0 });
                try self.emit(&self.declarations, 27, &.{ self.sampled_image_types[dimension_index], image_type });
                try self.emit(&self.declarations, 28, &.{ descriptor_array, self.sampled_image_types[dimension_index], descriptor_count });
                try self.emit(&self.declarations, 32, &.{ array_pointer, 0, descriptor_array }); // ptr UniformConstant
                try self.emit(&self.declarations, 32, &.{ self.sampled_image_pointer_types[dimension_index], 0, self.sampled_image_types[dimension_index] });
                try self.emit(&self.declarations, 59, &.{ array_pointer, self.sampled_image_arrays[dimension_index], 0 }); // OpVariable
            }
        }
        if (options.storage_images.len != 0) {
            if (options.stage != .compute) return Error.InvalidStorageBinding;
            for (options.storage_images, 0..) |binding, index| {
                if (binding.resource_sgpr >= 128 or
                    binding.descriptor_index >= self.storage_image_variables.len)
                {
                    return Error.InvalidStorageBinding;
                }
                for (options.storage_images[0..index]) |previous| {
                    if (previous.resource_sgpr == binding.resource_sgpr) {
                        return Error.InvalidStorageBinding;
                    }
                    if (previous.descriptor_index == binding.descriptor_index and
                        (previous.format != binding.format or previous.dimension != binding.dimension))
                    {
                        return Error.InvalidStorageBinding;
                    }
                }
                for (binding.dst_select) |selector| {
                    if (selector > 7 or selector == 2 or selector == 3) {
                        return Error.InvalidStorageBinding;
                    }
                }
            }

            self.vector2_bits_type = if (self.vector2_bits_type != 0) self.vector2_bits_type else self.id();
            try self.emit(&self.declarations, 23, &.{ self.vector2_bits_type, self.bits_type, 2 });
            var needs_3d_coordinates = false;
            for (options.storage_images) |binding| {
                needs_3d_coordinates = needs_3d_coordinates or binding.dimension == .three_d;
            }
            if (needs_3d_coordinates and self.vector3_bits_type == 0) {
                self.vector3_bits_type = self.id();
                try self.emit(&self.declarations, 23, &.{ self.vector3_bits_type, self.bits_type, 3 });
            }
            for (options.storage_images) |binding| {
                const descriptor_index: usize = @intCast(binding.descriptor_index);
                if (self.storage_image_variables[descriptor_index] != 0) continue;
                const value_type = storageImageValueType(binding.format);
                const component_type = self.typeId(value_type);
                const vector_type = self.id();
                const image_type = self.id();
                const image_pointer_type = self.id();
                const variable = self.id();
                self.storage_image_vector_types[descriptor_index] = vector_type;
                self.storage_image_types[descriptor_index] = image_type;
                self.storage_image_variables[descriptor_index] = variable;
                try self.emit(&self.annotations, 71, &.{ variable, 34, 0 }); // DescriptorSet 0
                try self.emit(&self.annotations, 71, &.{ variable, 33, 2 + binding.descriptor_index }); // Binding 2 + slot
                try self.emit(&self.declarations, 23, &.{ vector_type, component_type, 4 });
                try self.emit(&self.declarations, 25, &.{
                    image_type,
                    component_type,
                    if (binding.dimension == .three_d) 2 else 1, // Dim3D / Dim2D
                    0, // not depth
                    0, // not arrayed
                    0, // not multisampled
                    2, // storage image
                    storageImageSpirvFormat(binding.format),
                });
                try self.emit(&self.declarations, 32, &.{ image_pointer_type, 0, image_type }); // ptr UniformConstant
                try self.emit(&self.declarations, 59, &.{ image_pointer_type, variable, 0 });
            }
        }
        if (options.workgroup_memory_size_bytes != 0) {
            if (options.stage != .compute) return Error.InvalidStageInterface;
            const words = std.math.divCeil(u32, options.workgroup_memory_size_bytes, 4) catch
                return Error.InvalidStageInterface;
            if (words == 0) return Error.InvalidStageInterface;
            self.workgroup_memory_words = words;
            const word_count = try self.constant(.bits32, words);
            const array_type = self.id();
            const array_pointer_type = self.id();
            self.workgroup_word_pointer_type = self.id();
            self.workgroup_memory = self.id();
            try self.emit(&self.declarations, 28, &.{ array_type, self.bits_type, word_count }); // OpTypeArray
            try self.emit(&self.declarations, 32, &.{ array_pointer_type, 4, array_type }); // ptr Workgroup array
            try self.emit(&self.declarations, 32, &.{ self.workgroup_word_pointer_type, 4, self.bits_type });
            try self.emit(&self.declarations, 59, &.{ array_pointer_type, self.workgroup_memory, 4 }); // OpVariable
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

    fn dynamicScalar(self: *Builder, specialization_index: usize) Error!u32 {
        const dynamic = self.dynamic_scalar_binding orelse return Error.InvalidStorageBinding;
        if (self.scalar_buffer == 0 or self.scalar_word_pointer_type == 0) return Error.InvalidStorageBinding;
        const word_index = std.math.add(u32, dynamic.value_base, @intCast(specialization_index)) catch
            return Error.InvalidStorageBinding;
        const pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.scalar_word_pointer_type,
            pointer,
            self.scalar_buffer,
            try self.constant(.bits32, 0),
            try self.constant(.bits32, word_index),
        }); // OpAccessChain block member, dword
        const loaded = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, loaded, pointer }); // OpLoad
        return loaded;
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
            // An untouched mask starts with all lanes enabled. VCC writes from
            // vector comparisons are kept in the scalar register slots so a
            // following CNDMASK or scalar mask operation observes the result.
            .exec_lo, .exec_hi, .vcc_lo, .vcc_hi => blk: {
                const index = registerIndex(op).?;
                const current = self.registers[index];
                if (current.id == 0) break :blk try self.constant(.bits32, 0xffff_ffff);
                break :blk try self.convert(current, .bits32);
            },
            .m0,
            .ttmp,
            .flat_scratch_base_lo,
            .flat_scratch_base_hi,
            .shared_base,
            .shared_limit,
            .private_base,
            .private_limit,
            .lds_direct,
            .vcc_z,
            .exec_z,
            .scc,
            .pops_exiting_wave_id,
            => self.constant(.bits32, 0),
            .sgpr, .vgpr => blk: {
                const index = registerIndex(op) orelse return Error.UndefinedRegister;
                const current = self.registers[index];
                if (current.id == 0) return Error.UndefinedRegister;
                break :blk try self.convert(current, .bits32);
            },
            // Partially decoded sources (NSA holes, unimplemented specials)
            // read as zero so a single unknown operand does not abort the whole
            // shader — wrong values are better than no draw during bring-up.
            .unknown => self.constant(.bits32, 0),
        };
    }

    fn source(self: *Builder, op: operand.Operand, expected: ValueType) Error!u32 {
        var raw = try self.rawSource(op);
        if (op.dpp) {
            const scope = try self.constant(.bits32, 3); // Subgroup scope
            var shuffled = self.id();
            if (op.dpp_ctrl <= 0x0ff) { // quad_perm
                // TODO: exact quad perm using shift/and lane math + Shuffle
                shuffled = raw;
            } else if (op.dpp_ctrl >= 0x101 and op.dpp_ctrl <= 0x10f) { // row_shl
                const delta = try self.constant(.bits32, op.dpp_ctrl - 0x100);
                try self.emit(&self.body, 347, &.{ self.bits_type, shuffled, scope, raw, delta }); // OpGroupNonUniformShuffleUp
            } else if (op.dpp_ctrl >= 0x111 and op.dpp_ctrl <= 0x11f) { // row_shr
                const delta = try self.constant(.bits32, op.dpp_ctrl - 0x110);
                try self.emit(&self.body, 348, &.{ self.bits_type, shuffled, scope, raw, delta }); // OpGroupNonUniformShuffleDown
            } else if (op.dpp_ctrl >= 0x121 and op.dpp_ctrl <= 0x12f) { // row_ror
                const delta = try self.constant(.bits32, op.dpp_ctrl - 0x120);
                try self.emit(&self.body, 348, &.{ self.bits_type, shuffled, scope, raw, delta }); // Approx using down
            } else if (op.dpp_ctrl == 0x140) { // row_mirror
                const mask = try self.constant(.bits32, 15);
                try self.emit(&self.body, 346, &.{ self.bits_type, shuffled, scope, raw, mask }); // OpGroupNonUniformShuffleXor
            } else if (op.dpp_ctrl == 0x141) { // row_half_mirror
                const mask = try self.constant(.bits32, 7);
                try self.emit(&self.body, 346, &.{ self.bits_type, shuffled, scope, raw, mask }); // OpGroupNonUniformShuffleXor
            } else {
                shuffled = raw;
            }
            raw = shuffled;
        }
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
            if (expected == .float32) {
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
            } else {
                var signed_value = try self.convert(.{ .id = raw, .value_type = .bits32 }, .sint32);
                if (op.absolute) {
                    const absolute = self.id();
                    try self.emit(&self.body, 12, &.{ self.signed_type, absolute, self.ensureGlslStd450(), 5, signed_value }); // SAbs
                    signed_value = absolute;
                }
                if (op.negate) {
                    const negated = self.id();
                    try self.emit(&self.body, 126, &.{ self.signed_type, negated, signed_value }); // OpSNegate
                    signed_value = negated;
                }
                raw = try self.convert(.{ .id = signed_value, .value_type = .sint32 }, .bits32);
            }
        }
        return self.convert(.{ .id = raw, .value_type = .bits32 }, expected);
    }

    fn destination(self: *Builder, op: operand.Operand, value: Value) Error!void {
        var final_value = value;
        if (op.omod != 0 or op.clamp) {
            if (value.value_type != .float32) return Error.UnsupportedOpcode;
            if (op.omod != 0) {
                const mul_bits: u32 = if (op.omod == 1) 0x4000_0000 else if (op.omod == 2) 0x4080_0000 else 0x3f00_0000;
                const cst = try self.constant(.float32, mul_bits);
                const mul_res = self.id();
                try self.emit(&self.body, 133, &.{ self.float_type, mul_res, final_value.id, cst });
                final_value.id = mul_res;
            }
            if (op.clamp) {
                const glsl = self.ensureGlslStd450();
                const zero = try self.constant(.float32, 0);
                const one = try self.constant(.float32, 0x3f80_0000);
                const clamped = self.id();
                try self.emit(&self.body, 12, &.{ self.float_type, clamped, glsl, 43, final_value.id, zero, one });
                final_value.id = clamped;
            }
        }
        // SDWA destination packing is not modelled yet; keep the full dword.
        const index = registerIndex(op) orelse {
            // Writes to SCC/VCC/EXEC are tracked separately or ignored.
            if (op.kind == .vcc_lo or op.kind == .vcc_hi or
                op.kind == .exec_lo or op.kind == .exec_hi or op.kind == .m0 or
                op.kind == .ttmp)
            {
                return;
            }
            return Error.UnsupportedDestination;
        };
        self.registers[index] = .{
            .id = try self.convert(final_value, .bits32),
            .value_type = .bits32,
        };
    }

    fn unary(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType) Error!void {
        const source_id = try self.source(inst.src0, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(value_type), result, source_id });
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
    }

    fn glslFloatUnary(self: *Builder, inst: instruction.Instruction, opcode: u32) Error!void {
        const source_id = try self.source(inst.src0, .float32);
        const result = self.id();
        try self.emit(&self.body, 12, &.{ // OpExtInst
            self.float_type,
            result,
            self.ensureGlslStd450(),
            opcode,
            source_id,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn glslBinary(self: *Builder, inst: instruction.Instruction, opcode: u32, value_type: ValueType) Error!void {
        const a = try self.source(inst.src0, value_type);
        const b = try self.source(inst.src1, value_type);
        const result = try self.glslBinaryValue(opcode, value_type, a, b);
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
    }

    fn scalarMinMax(
        self: *Builder,
        inst: instruction.Instruction,
        extended_opcode: u32,
        value_type: ValueType,
        compare_opcode: u16,
    ) Error!void {
        const a = try self.source(inst.src0, value_type);
        const b = try self.source(inst.src1, value_type);
        const result = try self.glslBinaryValue(extended_opcode, value_type, a, b);
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
        self.scc = self.id();
        // GCN scalar MIN/MAX sets SCC when src0 wins the strict comparison.
        try self.emit(&self.body, compare_opcode, &.{ self.bool_type, self.scc, a, b });
    }

    fn glslBinaryValue(self: *Builder, opcode: u32, value_type: ValueType, a: u32, b: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 12, &.{ // OpExtInst
            self.typeId(value_type),
            result,
            self.ensureGlslStd450(),
            opcode,
            a,
            b,
        });
        return result;
    }

    fn minMax3Float(self: *Builder, inst: instruction.Instruction, opcode: isa.Opcode) Error!void {
        const a = try self.source(inst.src0, .float32);
        const b = try self.source(inst.src1, .float32);
        const c = try self.source(inst.src2, .float32);
        const result = switch (opcode) {
            .v_min3_f32 => try self.glslBinaryValue(37, .float32, try self.glslBinaryValue(37, .float32, a, b), c),
            .v_max3_f32 => try self.glslBinaryValue(40, .float32, try self.glslBinaryValue(40, .float32, a, b), c),
            .v_med3_f32 => blk: {
                const low = try self.glslBinaryValue(37, .float32, a, b);
                const high = try self.glslBinaryValue(40, .float32, a, b);
                const upper_low = try self.glslBinaryValue(37, .float32, high, c);
                break :blk try self.glslBinaryValue(40, .float32, low, upper_low);
            },
            else => unreachable,
        };
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn floatNegateValue(self: *Builder, value: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 127, &.{ self.float_type, result, value }); // OpFNegate
        return result;
    }

    fn floatMultiplyValue(self: *Builder, a: u32, b: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 133, &.{ self.float_type, result, a, b }); // OpFMul
        return result;
    }

    fn floatCompareValue(self: *Builder, opcode: u16, a: u32, b: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.bool_type, result, a, b });
        return result;
    }

    fn logicalAndValue(self: *Builder, a: u32, b: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, result, a, b }); // OpLogicalAnd
        return result;
    }

    fn selectFloatValue(self: *Builder, condition: u32, true_value: u32, false_value: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 169, &.{ // OpSelect
            self.float_type,
            result,
            condition,
            true_value,
            false_value,
        });
        return result;
    }

    fn cubeFloat(self: *Builder, inst: instruction.Instruction) Error!void {
        const x = try self.source(inst.src0, .float32);
        const y = try self.source(inst.src1, .float32);
        const z = try self.source(inst.src2, .float32);
        const glsl = self.ensureGlslStd450();

        const ax = self.id();
        try self.emit(&self.body, 12, &.{ self.float_type, ax, glsl, 4, x }); // FAbs
        const ay = self.id();
        try self.emit(&self.body, 12, &.{ self.float_type, ay, glsl, 4, y });
        const az = self.id();
        try self.emit(&self.body, 12, &.{ self.float_type, az, glsl, 4, z });

        const z_ge_x = try self.floatCompareValue(190, az, ax); // OpFOrdGreaterThanEqual
        const z_ge_y = try self.floatCompareValue(190, az, ay);
        const z_face = try self.logicalAndValue(z_ge_x, z_ge_y);
        const y_face = try self.floatCompareValue(190, ay, ax);
        const zero = try self.constant(.float32, 0);
        const x_neg = try self.floatCompareValue(184, x, zero); // OpFOrdLessThan
        const y_neg = try self.floatCompareValue(184, y, zero);
        const z_neg = try self.floatCompareValue(184, z, zero);

        const result = switch (inst.opcode) {
            .v_cubeid_f32 => blk: {
                const one = try self.constant(.float32, @bitCast(@as(f32, 1.0)));
                const two = try self.constant(.float32, @bitCast(@as(f32, 2.0)));
                const three = try self.constant(.float32, @bitCast(@as(f32, 3.0)));
                const four = try self.constant(.float32, @bitCast(@as(f32, 4.0)));
                const five = try self.constant(.float32, @bitCast(@as(f32, 5.0)));
                const x_id = try self.selectFloatValue(x_neg, one, zero);
                const y_id = try self.selectFloatValue(y_neg, three, two);
                const z_id = try self.selectFloatValue(z_neg, five, four);
                const xy_id = try self.selectFloatValue(y_face, y_id, x_id);
                break :blk try self.selectFloatValue(z_face, z_id, xy_id);
            },
            .v_cubesc_f32 => blk: {
                const neg_z = try self.floatNegateValue(z);
                const neg_x = try self.floatNegateValue(x);
                const x_sc = try self.selectFloatValue(x_neg, z, neg_z);
                const z_sc = try self.selectFloatValue(z_neg, neg_x, x);
                const xy_sc = try self.selectFloatValue(y_face, x, x_sc);
                break :blk try self.selectFloatValue(z_face, z_sc, xy_sc);
            },
            .v_cubetc_f32 => blk: {
                const neg_z = try self.floatNegateValue(z);
                const neg_y = try self.floatNegateValue(y);
                const y_tc = try self.selectFloatValue(y_neg, neg_z, z);
                const xy_tc = try self.selectFloatValue(y_face, y_tc, neg_y);
                break :blk try self.selectFloatValue(z_face, neg_y, xy_tc);
            },
            .v_cubema_f32 => blk: {
                const two = try self.constant(.float32, @bitCast(@as(f32, 2.0)));
                const x_ma = try self.floatMultiplyValue(x, two);
                const y_ma = try self.floatMultiplyValue(y, two);
                const z_ma = try self.floatMultiplyValue(z, two);
                const xy_ma = try self.selectFloatValue(y_face, y_ma, x_ma);
                break :blk try self.selectFloatValue(z_face, z_ma, xy_ma);
            },
            else => unreachable,
        };
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn reciprocalFloat(self: *Builder, inst: instruction.Instruction) Error!void {
        const divisor = try self.source(inst.src0, .float32);
        const result = self.id();
        try self.emit(&self.body, 136, &.{ // OpFDiv
            self.float_type,
            result,
            try self.constant(.float32, @bitCast(@as(f32, 1.0))),
            divisor,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn ldexpFloat(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .float32);
        const exponent = try self.source(inst.src1, .sint32);
        const result = self.id();
        try self.emit(&self.body, 12, &.{ // GLSL.std.450 Ldexp
            self.float_type,
            result,
            self.ensureGlslStd450(),
            53,
            value,
            exponent,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn binary(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType, reverse: bool) Error!void {
        const a = try self.source(if (reverse) inst.src1 else inst.src0, value_type);
        const b = try self.source(if (reverse) inst.src0 else inst.src1, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(value_type), result, a, b });
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
    }

    fn scalarAddUnsigned(self: *Builder, inst: instruction.Instruction, with_carry: bool) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const partial = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, partial, a, b }); // OpIAdd
        const partial_carry = self.id();
        try self.emit(&self.body, 176, &.{ self.bool_type, partial_carry, partial, a }); // OpULessThan

        var result = partial;
        var carry = partial_carry;
        if (with_carry) {
            const carry_condition = if (self.arithmetic_carry != 0) self.arithmetic_carry else blk: {
                const zero = try self.constant(.bits32, 0);
                const false_value = self.id();
                try self.emit(&self.body, 171, &.{ self.bool_type, false_value, zero, zero }); // false
                break :blk false_value;
            };
            const carry_bits = self.id();
            try self.emit(&self.body, 169, &.{ // OpSelect
                self.bits_type,
                carry_bits,
                carry_condition,
                try self.constant(.bits32, 1),
                try self.constant(.bits32, 0),
            });
            result = self.id();
            try self.emit(&self.body, 128, &.{ self.bits_type, result, partial, carry_bits });
            const carry_overflow = self.id();
            try self.emit(&self.body, 176, &.{ self.bool_type, carry_overflow, result, partial });
            carry = self.id();
            try self.emit(&self.body, 166, &.{ self.bool_type, carry, partial_carry, carry_overflow }); // OpLogicalOr
        }
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
        self.arithmetic_carry = carry;
        if (with_carry) self.scc = carry;
    }

    fn vectorAddCarry(self: *Builder, inst: instruction.Instruction) Error!void {
        var first = inst.src0;
        var second = inst.src1;
        // VOP3 integer ADDC reuses modifier bits for its scalar carry/output
        // encoding. They are not integer abs/neg modifiers.
        first.absolute = false;
        first.negate = false;
        second.absolute = false;
        second.negate = false;
        const a = try self.source(first, .bits32);
        const b = try self.source(second, .bits32);
        const carry_source = if (inst.src2.kind == .unknown)
            try self.source(.{ .kind = .vcc_lo }, .bits32)
        else
            try self.source(inst.src2, .bits32);
        const carry = try self.andBits(carry_source, 1);
        const partial = try self.addBits(a, b);
        const partial_carry = self.id();
        try self.emit(&self.body, 176, &.{ self.bool_type, partial_carry, partial, a }); // OpULessThan
        const result = try self.addBits(partial, carry);
        const carry_overflow = self.id();
        try self.emit(&self.body, 176, &.{ self.bool_type, carry_overflow, result, partial });
        const carry_out = self.id();
        try self.emit(&self.body, 166, &.{ self.bool_type, carry_out, partial_carry, carry_overflow }); // OpLogicalOr
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
        var carry_inst = inst;
        carry_inst.dst = inst.dst2;
        try self.vectorConditionDestination(carry_inst, carry_out);
    }

    fn multiply24(self: *Builder, inst: instruction.Instruction, signed: bool) Error!void {
        var a = try self.source(inst.src0, if (signed) .sint32 else .bits32);
        var b = try self.source(inst.src1, if (signed) .sint32 else .bits32);
        if (signed) {
            const shift = try self.constant(.bits32, 8);
            const a_shifted = self.id();
            try self.emit(&self.body, 196, &.{ self.signed_type, a_shifted, a, shift }); // OpShiftLeftLogical
            a = self.id();
            try self.emit(&self.body, 195, &.{ self.signed_type, a, a_shifted, shift }); // OpShiftRightArithmetic
            const b_shifted = self.id();
            try self.emit(&self.body, 196, &.{ self.signed_type, b_shifted, b, shift });
            b = self.id();
            try self.emit(&self.body, 195, &.{ self.signed_type, b, b_shifted, shift });
        } else {
            const mask = try self.constant(.bits32, 0x00ff_ffff);
            const masked_a = self.id();
            try self.emit(&self.body, 199, &.{ self.bits_type, masked_a, a, mask }); // OpBitwiseAnd
            a = masked_a;
            const masked_b = self.id();
            try self.emit(&self.body, 199, &.{ self.bits_type, masked_b, b, mask });
            b = masked_b;
        }
        const result = self.id();
        const result_type: ValueType = if (signed) .sint32 else .bits32;
        try self.emit(&self.body, 132, &.{ self.typeId(result_type), result, a, b }); // OpIMul
        try self.destination(inst.dst, .{ .id = result, .value_type = result_type });
    }

    fn comparison(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType) Error!void {
        const a = try self.source(inst.src0, value_type);
        const b = try self.source(inst.src1, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.bool_type, result, a, b });
        self.scc = result;
    }

    fn vectorConditionDestination(self: *Builder, inst: instruction.Instruction, condition: u32) Error!void {
        const mask = self.id();
        try self.emit(&self.body, 169, &.{ // OpSelect
            self.bits_type,
            mask,
            condition,
            try self.constant(.bits32, 0xffff_ffff),
            try self.constant(.bits32, 0),
        });
        try self.destination(inst.dst, .{ .id = mask, .value_type = .bits32 });
    }

    fn vectorComparison(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType) Error!void {
        const a = try self.source(inst.src0, value_type);
        const b = try self.source(inst.src1, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.bool_type, result, a, b });
        try self.vectorConditionDestination(inst, result);
    }

    fn vectorConstantComparison(self: *Builder, inst: instruction.Instruction, truth: bool) Error!void {
        const zero = try self.constant(.bits32, 0);
        const result = self.id();
        try self.emit(&self.body, if (truth) 170 else 171, &.{ self.bool_type, result, zero, zero });
        try self.vectorConditionDestination(inst, result);
    }

    fn vectorOrderedComparison(self: *Builder, inst: instruction.Instruction, unordered: bool) Error!void {
        const a = try self.source(inst.src0, .float32);
        const b = try self.source(inst.src1, .float32);
        const a_ordered = self.id();
        try self.emit(&self.body, 180, &.{ self.bool_type, a_ordered, a, a }); // OpFOrdEqual
        const b_ordered = self.id();
        try self.emit(&self.body, 180, &.{ self.bool_type, b_ordered, b, b });
        const both_ordered = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, both_ordered, a_ordered, b_ordered }); // OpLogicalAnd
        if (!unordered) return self.vectorConditionDestination(inst, both_ordered);
        const any_unordered = self.id();
        try self.emit(&self.body, 168, &.{ self.bool_type, any_unordered, both_ordered }); // OpLogicalNot
        try self.vectorConditionDestination(inst, any_unordered);
    }

    fn mov64(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.sourcePair(inst.src0);
        try self.destinationPair(inst.dst, value);
    }

    fn sourcePair(self: *Builder, op: operand.Operand) Error![2]u32 {
        const low = try self.source(op, .bits32);
        const high = switch (op.kind) {
            .sgpr, .vgpr, .vcc_lo, .exec_lo => try self.source(try consecutiveRegister(op, 1), .bits32),
            else => blk: {
                // Scalar constants in a 64-bit ALU instruction are sign
                // extended to the high dword.
                const extended = self.id();
                try self.emit(&self.body, 195, &.{
                    self.bits_type,
                    extended,
                    low,
                    try self.constant(.bits32, 31),
                }); // OpShiftRightArithmetic
                break :blk extended;
            },
        };
        return .{ low, high };
    }

    fn destinationPair(self: *Builder, op: operand.Operand, value: [2]u32) Error!void {
        try self.destination(op, .{ .id = value[0], .value_type = .bits32 });
        try self.destination(try consecutiveRegister(op, 1), .{ .id = value[1], .value_type = .bits32 });
    }

    fn updateSccFromPair(self: *Builder, value: [2]u32) Error!void {
        const zero = try self.constant(.bits32, 0);
        const low_nonzero = self.id();
        try self.emit(&self.body, 171, &.{ self.bool_type, low_nonzero, value[0], zero }); // OpINotEqual
        const high_nonzero = self.id();
        try self.emit(&self.body, 171, &.{ self.bool_type, high_nonzero, value[1], zero });
        self.scc = self.id();
        try self.emit(&self.body, 166, &.{ self.bool_type, self.scc, low_nonzero, high_nonzero }); // OpLogicalOr
    }

    fn bitwise64(self: *Builder, inst: instruction.Instruction, opcode: isa.Opcode) Error!void {
        const a = try self.sourcePair(inst.src0);
        const b = try self.sourcePair(inst.src1);
        var result: [2]u32 = undefined;
        for (0..2) |index| {
            var right = b[index];
            if (opcode == .s_andn2_b64 or opcode == .s_orn2_b64) {
                const inverted = self.id();
                try self.emit(&self.body, 200, &.{ self.bits_type, inverted, right }); // OpNot
                right = inverted;
            }
            const binary_opcode: u16 = switch (opcode) {
                .s_and_b64, .s_andn2_b64, .s_nand_b64 => 199,
                .s_or_b64, .s_orn2_b64, .s_nor_b64 => 197,
                .s_xor_b64, .s_xnor_b64 => 198,
                else => unreachable,
            };
            const combined = self.id();
            try self.emit(&self.body, binary_opcode, &.{ self.bits_type, combined, a[index], right });
            if (opcode == .s_nand_b64 or opcode == .s_nor_b64 or opcode == .s_xnor_b64) {
                result[index] = self.id();
                try self.emit(&self.body, 200, &.{ self.bits_type, result[index], combined });
            } else {
                result[index] = combined;
            }
        }
        try self.destinationPair(inst.dst, result);
        try self.updateSccFromPair(result);
    }

    /// Saves the current wave mask and intersects EXEC with a lane predicate.
    /// A Vulkan fragment invocation represents one RDNA lane, so the low mask
    /// word produced by V_CMP becomes that invocation's structured-branch
    /// condition. Keeping both halves also preserves the guest SGPR snapshot
    /// used by the later `s_mov_b64 exec, saved` reconvergence sequence.
    fn andSaveExec64(self: *Builder, inst: instruction.Instruction) Error!void {
        const previous = try self.sourcePair(.{ .kind = .exec_lo });
        const predicate = try self.sourcePair(inst.src0);
        var active: [2]u32 = undefined;
        for (0..2) |index| {
            active[index] = self.id();
            try self.emit(&self.body, 199, &.{ self.bits_type, active[index], previous[index], predicate[index] }); // OpBitwiseAnd
        }
        try self.destinationPair(inst.dst, previous);
        try self.destinationPair(.{ .kind = .exec_lo }, active);
        self.exec_mask = active;
        try self.updateSccFromPair(active);
    }

    fn not64(self: *Builder, inst: instruction.Instruction) Error!void {
        const source_value = try self.sourcePair(inst.src0);
        var result: [2]u32 = undefined;
        for (0..2) |index| {
            result[index] = self.id();
            try self.emit(&self.body, 200, &.{ self.bits_type, result[index], source_value[index] });
        }
        try self.destinationPair(inst.dst, result);
        try self.updateSccFromPair(result);
    }

    fn cselect64(self: *Builder, inst: instruction.Instruction) Error!void {
        const condition = if (self.scc != 0) self.scc else blk: {
            const zero = try self.constant(.bits32, 0);
            const fallback = self.id();
            try self.emit(&self.body, 170, &.{ self.bool_type, fallback, zero, zero });
            break :blk fallback;
        };
        const true_value = try self.sourcePair(inst.src0);
        const false_value = try self.sourcePair(inst.src1);
        var result: [2]u32 = undefined;
        for (0..2) |index| {
            result[index] = self.id();
            try self.emit(&self.body, 169, &.{ self.bits_type, result[index], condition, true_value[index], false_value[index] });
        }
        try self.destinationPair(inst.dst, result);
    }

    fn cselect32(self: *Builder, inst: instruction.Instruction) Error!void {
        const condition = if (self.scc != 0) self.scc else blk: {
            const zero = try self.constant(.bits32, 0);
            const fallback = self.id();
            try self.emit(&self.body, 170, &.{ self.bool_type, fallback, zero, zero });
            break :blk fallback;
        };
        const true_value = try self.source(inst.src0, .bits32);
        const false_value = try self.source(inst.src1, .bits32);
        const result = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, result, condition, true_value, false_value });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn getPcFallback(self: *Builder, inst: instruction.Instruction) Error!void {
        // Live shaders specialize GETPC-derived descriptor pointers before
        // lowering. Keep a deterministic null pair for standalone translation.
        const zero = try self.constant(.bits32, 0);
        try self.destinationPair(inst.dst, .{ zero, zero });
    }

    fn cndmask(self: *Builder, inst: instruction.Instruction) Error!void {
        // dst = vcc ? src1 : src0  (lane-wise; we approximate VCC as a scalar bool).
        const false_val = try self.source(inst.src0, .bits32);
        const true_val = try self.source(inst.src1, .bits32);
        const vcc = try self.source(inst.src2, .bits32);
        const is_true = self.id();
        try self.emit(&self.body, 171, &.{ // OpINotEqual
            self.bool_type,
            is_true,
            vcc,
            try self.constant(.bits32, 0),
        });
        const result = self.id();
        try self.emit(&self.body, 169, &.{ // OpSelect
            self.bits_type,
            result,
            is_true,
            true_val,
            false_val,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn andOr(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const c = try self.source(inst.src2, .bits32);
        const masked = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, masked, a, b }); // OpBitwiseAnd
        const result = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, result, masked, c }); // OpBitwiseOr
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn bitfieldInsert(self: *Builder, inst: instruction.Instruction) Error!void {
        // V_BFI_B32 selects bits from src1 where src0 is set and from src2
        // everywhere else: (mask & src1) | (~mask & src2).
        const mask = try self.source(inst.src0, .bits32);
        const selected = try self.source(inst.src1, .bits32);
        const fallback = try self.source(inst.src2, .bits32);
        const masked_selected = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, masked_selected, mask, selected }); // OpBitwiseAnd
        const inverted_mask = self.id();
        try self.emit(&self.body, 200, &.{ self.bits_type, inverted_mask, mask }); // OpNot
        const masked_fallback = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, masked_fallback, inverted_mask, fallback }); // OpBitwiseAnd
        const result = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, result, masked_selected, masked_fallback }); // OpBitwiseOr
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    /// dst = (src0 OP1 src1) OP2 src2 for common ternary packing ops.
    fn ternaryBits(
        self: *Builder,
        inst: instruction.Instruction,
        op1: u16,
        op2: u16,
    ) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const c = try self.source(inst.src2, .bits32);
        const mid = self.id();
        try self.emit(&self.body, op1, &.{ self.bits_type, mid, a, b });
        const result = self.id();
        try self.emit(&self.body, op2, &.{ self.bits_type, result, mid, c });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    /// V_SAD_U32: dst = abs(src0 - src1) + src2, with unsigned operands.
    fn sadUnsigned(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const addend = try self.source(inst.src2, .bits32);
        const a_less_b = self.id();
        try self.emit(&self.body, 176, &.{ self.bool_type, a_less_b, a, b }); // OpULessThan
        const a_minus_b = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, a_minus_b, a, b }); // OpISub
        const b_minus_a = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, b_minus_a, b, a }); // OpISub
        const difference = self.id();
        try self.emit(&self.body, 169, &.{ // OpSelect
            self.bits_type,
            difference,
            a_less_b,
            b_minus_a,
            a_minus_b,
        });
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, result, difference, addend }); // OpIAdd
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn shiftLeftOr(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .bits32);
        const raw_shift = try self.source(inst.src1, .bits32);
        const or_value = try self.source(inst.src2, .bits32);
        const shift = try self.andBits(raw_shift, 31);
        const shifted = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shifted, value, shift }); // OpShiftLeftLogical
        const result = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, result, shifted, or_value }); // OpBitwiseOr
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn bitfieldExtract(self: *Builder, inst: instruction.Instruction, signed_field: bool) Error!void {
        const value = try self.source(inst.src0, .bits32);
        const offset_raw = try self.source(inst.src1, .bits32);
        const width_raw = try self.source(inst.src2, .bits32);
        const offset = try self.andBits(offset_raw, 31);
        const width = try self.andBits(width_raw, 31);
        const shifted = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, shifted, value, offset }); // OpShiftRightLogical
        // V_BFE uses a separate five-bit width; a zero-width field is zero.
        const one = try self.constant(.bits32, 1);
        const shifted_one = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shifted_one, one, width }); // OpShiftLeftLogical
        const mask = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, mask, shifted_one, one }); // OpISub
        const extracted = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, extracted, shifted, mask }); // OpBitwiseAnd
        if (signed_field) {
            // Sign-extend: (extracted << ((32-width)&31)) >>a the same amount.
            const raw_shift_amount = self.id();
            try self.emit(&self.body, 130, &.{ // OpISub
                self.bits_type,
                raw_shift_amount,
                try self.constant(.bits32, 32),
                width,
            });
            const shift_amount = try self.andBits(raw_shift_amount, 31);
            const up = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, up, extracted, shift_amount }); // OpShiftLeftLogical
            const signed_up = self.id();
            try self.emit(&self.body, 114, &.{ self.signed_type, signed_up, up }); // OpBitcast
            const down = self.id();
            try self.emit(&self.body, 195, &.{ self.signed_type, down, signed_up, shift_amount }); // OpShiftRightArithmetic
            const as_bits = self.id();
            try self.emit(&self.body, 114, &.{ self.bits_type, as_bits, down }); // OpBitcast
            try self.destination(inst.dst, .{ .id = as_bits, .value_type = .bits32 });
            return;
        }
        try self.destination(inst.dst, .{ .id = extracted, .value_type = .bits32 });
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

    fn addShiftLeft(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const raw_shift = try self.source(inst.src2, .bits32);
        const sum = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, sum, a, b }); // OpIAdd
        const shift = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, shift, raw_shift, try self.constant(.bits32, 31) }); // OpBitwiseAnd
        const result = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, result, sum, shift }); // OpShiftLeftLogical
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn fixedShiftLeftAdd(self: *Builder, inst: instruction.Instruction, shift_amount: u32) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const shifted = self.id();
        try self.emit(&self.body, 196, &.{ // OpShiftLeftLogical
            self.bits_type,
            shifted,
            a,
            try self.constant(.bits32, shift_amount),
        });
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, result, shifted, b }); // OpIAdd
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn initializeStageInputs(self: *Builder) Error!void {
        if (self.dynamic_scalar_binding != null) {
            for (self.scalar_specializations, 0..) |scalar, index| {
                if (scalar.producer_pc != null) continue;
                self.registers[scalar.register] = .{
                    .id = try self.dynamicScalar(index),
                    .value_type = .bits32,
                };
            }
        }
        // Graphics descriptor payloads are represented by Vulkan bindings and
        // deliberately removed from scalar specialization. Their remaining
        // bitfield uses still need a deterministic value on paths where no
        // scalar instruction writes the corresponding SGPR. Zero mirrors the
        // unavailable-hardware-register policy used by the pixel prolog. Keep
        // VCC and EXEC untouched: rawSource gives pristine wave masks all ones.
        //
        // A vertex program needs the same treatment for a different reason. On
        // this generation a vertex shader is launched as the ES half of a
        // merged NGG wave, and its prolog reads hardware SGPRs that describe
        // the wave rather than the draw: the merged wave info holds the vertex
        // and primitive counts packed into bitfields. Those registers are not
        // user data, so scalar provenance never resolves them. Everything the
        // prolog derives from them — the GS_ALLOC_REQ payload in M0 and the
        // execution masks that narrow the wave to its live lanes — is dropped
        // here anyway, because Vulkan runs one invocation per vertex and does
        // its own primitive assembly. Leaving them undefined only rejects the
        // shader; zero lets the live part of the program translate.
        if (self.stage == .fragment or self.stage == .vertex) {
            const zero = try self.constant(.bits32, 0);
            for (0..126) |sgpr| {
                if (sgpr == 106 or sgpr == 107) continue;
                if (self.registers[sgpr].id == 0) {
                    self.registers[sgpr] = .{ .id = zero, .value_type = .bits32 };
                }
            }
        }
        // Seed unused VGPRs with zero so attribute holes / skipped ops do not
        // abort translation with UndefinedRegister during bring-up.
        const zero = try self.constant(.bits32, 0);
        for (0..64) |vgpr| {
            if (self.registers[128 + vgpr].id == 0) {
                self.registers[128 + vgpr] = .{ .id = zero, .value_type = .bits32 };
            }
        }
        if (self.vertex_index_input != 0) {
            const result = self.id();
            try self.emit(&self.body, 61, &.{ self.signed_type, result, self.vertex_index_input }); // OpLoad
            const vgpr = self.vertex_index_vgpr orelse return Error.InvalidStageInterface;
            self.registers[128 + @as(usize, vgpr)] = .{ .id = result, .value_type = .sint32 };

            // The hardware VGPRs of a merged NGG wave. The ES half receives its
            // vertex id in V5 and its instance id in V8, and a vertex prolog
            // reads them directly: the usual `v_cndmask v0, v8, v5, s8` picks
            // one of the two as the attribute-fetch index. Seeding only the
            // configured fetch VGPR left both at zero, so a program that
            // computes its position from V5 — a procedural full-screen
            // triangle, for one — placed every vertex at the same corner.
            self.registers[128 + 5] = .{ .id = result, .value_type = .sint32 };
            if (self.instance_index_input != 0) {
                const instance = self.id();
                try self.emit(&self.body, 61, &.{ self.signed_type, instance, self.instance_index_input }); // OpLoad
                self.registers[128 + 8] = .{ .id = instance, .value_type = .sint32 };
            }
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

    fn bitfieldMask(self: *Builder, inst: instruction.Instruction) Error!void {
        // S_BFM_B32 creates a run of src0 low bits and then shifts it by src1.
        // RDNA masks both operands to five bits; keeping the two shifts separate
        // also gives the required truncation when the field crosses bit 31.
        const count_raw = try self.source(inst.src0, .bits32);
        const offset_raw = try self.source(inst.src1, .bits32);
        const count = try self.andBits(count_raw, 31);
        const offset = try self.andBits(offset_raw, 31);
        const one = try self.constant(.bits32, 1);
        const shifted_one = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shifted_one, one, count }); // OpShiftLeftLogical
        const low_mask = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, low_mask, shifted_one, one }); // OpISub
        const result = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, result, low_mask, offset }); // OpShiftLeftLogical
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn scalarBitfieldExtract(self: *Builder, inst: instruction.Instruction) Error!void {
        // SOP2 packs OFFSET in bits 4:0 and WIDTH in bits 22:16 of src1.
        // Unlike V_BFE, there is no third source operand.
        const value = try self.source(inst.src0, .bits32);
        const field = try self.source(inst.src1, .bits32);
        const offset = try self.andBits(field, 31);
        const shifted_field = self.id();
        try self.emit(&self.body, 194, &.{
            self.bits_type,
            shifted_field,
            field,
            try self.constant(.bits32, 16),
        }); // OpShiftRightLogical
        const width = try self.andBits(shifted_field, 0x7f);
        const result = self.id();
        try self.emit(&self.body, 203, &.{ self.bits_type, result, value, offset, width }); // OpBitFieldUExtract
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn shiftRightLogical64(self: *Builder, value: [2]u32, offset: u32) Error![2]u32 {
        const within_dword = try self.andBits(offset, 31);
        const offset_lt_32 = self.id();
        try self.emit(&self.body, 176, &.{
            self.bool_type,
            offset_lt_32,
            offset,
            try self.constant(.bits32, 32),
        }); // OpULessThan
        const offset_is_zero = self.id();
        try self.emit(&self.body, 170, &.{
            self.bool_type,
            offset_is_zero,
            offset,
            try self.constant(.bits32, 0),
        }); // OpIEqual
        const low_right = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, low_right, value[0], within_dword });
        const high_right = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, high_right, value[1], within_dword });
        const raw_carry_shift = self.id();
        try self.emit(&self.body, 130, &.{
            self.bits_type,
            raw_carry_shift,
            try self.constant(.bits32, 32),
            within_dword,
        });
        const carry_shift = try self.andBits(raw_carry_shift, 31);
        const carry = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, carry, value[1], carry_shift });
        const merged_low = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, merged_low, low_right, carry });
        const below_32_low = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            below_32_low,
            offset_is_zero,
            low_right,
            merged_low,
        });
        const zero = try self.constant(.bits32, 0);
        const result_low = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            result_low,
            offset_lt_32,
            below_32_low,
            high_right,
        });
        const result_high = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            result_high,
            offset_lt_32,
            high_right,
            zero,
        });
        return .{ result_low, result_high };
    }

    fn rightAlignedMask64(self: *Builder, count: u32) Error![2]u32 {
        const thirty_two = try self.constant(.bits32, 32);
        const count_lt_32 = self.id();
        try self.emit(&self.body, 176, &.{ self.bool_type, count_lt_32, count, thirty_two }); // OpULessThan
        const count_gt_32 = self.id();
        try self.emit(&self.body, 172, &.{ self.bool_type, count_gt_32, count, thirty_two }); // OpUGreaterThan
        const low_count = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, low_count, count_lt_32, count, thirty_two });
        const high_base = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, high_base, count, thirty_two });
        const zero = try self.constant(.bits32, 0);
        const high_count = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, high_count, count_gt_32, high_base, zero });
        const full = try self.constant(.bits32, 0xffff_ffff);
        const low = self.id();
        try self.emit(&self.body, 201, &.{ self.bits_type, low, zero, full, zero, low_count }); // OpBitFieldInsert
        const high = self.id();
        try self.emit(&self.body, 201, &.{ self.bits_type, high, zero, full, zero, high_count });
        return .{ low, high };
    }

    fn scalarBitfieldExtract64(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.sourcePair(inst.src0);
        const field = try self.source(inst.src1, .bits32);
        const offset = try self.andBits(field, 63);
        const shifted_field = self.id();
        try self.emit(&self.body, 194, &.{
            self.bits_type,
            shifted_field,
            field,
            try self.constant(.bits32, 16),
        });
        const raw_count = try self.andBits(shifted_field, 0x7f);
        const available = self.id();
        try self.emit(&self.body, 130, &.{
            self.bits_type,
            available,
            try self.constant(.bits32, 64),
            offset,
        });
        const use_raw_count = self.id();
        try self.emit(&self.body, 176, &.{ self.bool_type, use_raw_count, raw_count, available });
        const count = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, count, use_raw_count, raw_count, available });
        const shifted = try self.shiftRightLogical64(value, offset);
        const mask = try self.rightAlignedMask64(count);
        var result: [2]u32 = undefined;
        for (0..2) |index| {
            result[index] = self.id();
            try self.emit(&self.body, 199, &.{ self.bits_type, result[index], shifted[index], mask[index] });
        }
        try self.destinationPair(inst.dst, result);
    }

    fn integerToFloat(self: *Builder, inst: instruction.Instruction, signed: bool) Error!void {
        const source_type: ValueType = if (signed) .sint32 else .bits32;
        const source_id = try self.source(inst.src0, source_type);
        const result = self.id();
        try self.emit(&self.body, if (signed) 111 else 112, &.{ self.float_type, result, source_id });
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn floatToInteger(self: *Builder, inst: instruction.Instruction, signed: bool) Error!void {
        const source_id = try self.source(inst.src0, .float32);
        const result = self.id();
        const destination_type: ValueType = if (signed) .sint32 else .bits32;
        try self.emit(&self.body, if (signed) 110 else 109, &.{
            self.typeId(destination_type),
            result,
            source_id,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = destination_type });
    }

    fn floatFloorToSignedInteger(self: *Builder, inst: instruction.Instruction) Error!void {
        const source_id = try self.source(inst.src0, .float32);
        const floored = self.id();
        try self.emit(&self.body, 12, &.{ // GLSL.std.450 Floor
            self.float_type,
            floored,
            self.ensureGlslStd450(),
            8,
            source_id,
        });
        const result = self.id();
        try self.emit(&self.body, 110, &.{ self.signed_type, result, floored }); // OpConvertFToS
        try self.destination(inst.dst, .{ .id = result, .value_type = .sint32 });
    }

    fn madFloat(self: *Builder, inst: instruction.Instruction) Error!void {
        // dst = src0 * src1 + src2
        const a = try self.source(inst.src0, .float32);
        const b = try self.source(inst.src1, .float32);
        const c = try self.source(inst.src2, .float32);
        const product = self.id();
        try self.emit(&self.body, 133, &.{ self.float_type, product, a, b }); // OpFMul
        const result = self.id();
        try self.emit(&self.body, 129, &.{ self.float_type, result, product, c }); // OpFAdd
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn fmaFloat(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.source(inst.src0, .float32);
        const b = try self.source(inst.src1, .float32);
        const c = try self.source(inst.src2, .float32);
        const result = self.id();
        try self.emit(&self.body, 12, &.{ // GLSL.std.450 Fma
            self.float_type,
            result,
            self.ensureGlslStd450(),
            50,
            a,
            b,
            c,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn macFloat(self: *Builder, inst: instruction.Instruction) Error!void {
        // dst = src0 * src1 + dst
        const a = try self.source(inst.src0, .float32);
        const b = try self.source(inst.src1, .float32);
        const acc = try self.source(inst.dst, .float32);
        const product = self.id();
        try self.emit(&self.body, 133, &.{ self.float_type, product, a, b }); // OpFMul
        const result = self.id();
        try self.emit(&self.body, 129, &.{ self.float_type, result, product, acc }); // OpFAdd
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    /// Ensure a float2 vector type exists (shared with sampled-image coords).
    fn ensureFloatVec2(self: *Builder) Error!u32 {
        if (self.vector2_type == 0) {
            self.vector2_type = self.id();
            try self.emit(&self.declarations, 23, &.{ self.vector2_type, self.float_type, 2 }); // OpTypeVector
        }
        return self.vector2_type;
    }

    fn ensureSignedVec2(self: *Builder) Error!u32 {
        if (self.vector2_signed_type == 0) {
            self.vector2_signed_type = self.id();
            try self.emit(&self.declarations, 23, &.{ self.vector2_signed_type, self.signed_type, 2 }); // OpTypeVector
        }
        return self.vector2_signed_type;
    }

    fn ensureBitsVec2(self: *Builder) Error!u32 {
        if (self.vector2_bits_type == 0) {
            self.vector2_bits_type = self.id();
            try self.emit(&self.declarations, 23, &.{ self.vector2_bits_type, self.bits_type, 2 }); // OpTypeVector
        }
        return self.vector2_bits_type;
    }

    /// Ensure GLSL.std.450 is imported; assemble() places OpExtInstImport
    /// before the memory model when this id is non-zero.
    fn ensureGlslStd450(self: *Builder) u32 {
        if (self.glsl_std_450 == 0) self.glsl_std_450 = self.id();
        return self.glsl_std_450;
    }

    /// v_cvt_pkrtz_f16_f32: pack two f32 into one u32 as two IEEE f16 halves
    /// (low = src0, high = src1). GLSL.std.450 performs the conversion without
    /// requiring Float16 storage or arithmetic capabilities from the device.
    fn packHalf2x16(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.source(inst.src0, .float32);
        const b = try self.source(inst.src1, .float32);
        const vector_type = try self.ensureFloatVec2();
        const pair = self.id();
        try self.emit(&self.body, 80, &.{ vector_type, pair, a, b }); // OpCompositeConstruct
        const result = self.id();
        try self.emit(&self.body, 12, &.{
            self.bits_type,
            result,
            self.ensureGlslStd450(),
            58, // PackHalf2x16
            pair,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn exportValue(self: *Builder, inst: instruction.Instruction) Error!void {
        if (self.vector4_type == 0) return Error.UnsupportedOpcode;
        const output = switch (self.stage) {
            // GFX10 export targets: POS0 is 0x0c and PARAM0..31 are
            // 0x20..0x3f. PARAM values become ordinary Vulkan locations and
            // are interpolated by the rasterizer for the fragment stage.
            .vertex => if (inst.export_target == 0x0c or inst.export_target == 0)
                self.position_output
            else if (inst.export_target >= 0x20)
                self.parameter_variables[inst.export_target - 0x20]
            else
                0,
            .fragment => if (inst.export_target == 0) self.color_output else 0,
            .compute => 0,
        };
        if (output == 0) {
            // Skip secondary position, primitive and null exports rather than
            // aborting the complete shader.
            return;
        }
        const is_position = output == self.position_output;
        const zero = try self.constant(.float32, @bitCast(@as(f32, 0)));
        const one = try self.constant(.float32, @bitCast(@as(f32, 1)));
        const x: u32, const y: u32, const z: u32, const w: u32 = if (inst.export_compressed) blk: {
            const xy_bits = try self.source(inst.src0, .bits32);
            const zw_bits = try self.source(inst.src1, .bits32);
            const vector_type = try self.ensureFloatVec2();
            const xy = self.id();
            try self.emit(&self.body, 12, &.{
                vector_type,
                xy,
                self.ensureGlslStd450(),
                62, // UnpackHalf2x16
                xy_bits,
            });
            const zw = self.id();
            try self.emit(&self.body, 12, &.{
                vector_type,
                zw,
                self.ensureGlslStd450(),
                62,
                zw_bits,
            });
            const cx = self.id();
            try self.emit(&self.body, 81, &.{ self.float_type, cx, xy, 0 }); // OpCompositeExtract
            const cy = self.id();
            try self.emit(&self.body, 81, &.{ self.float_type, cy, xy, 1 });
            const cz = self.id();
            try self.emit(&self.body, 81, &.{ self.float_type, cz, zw, 0 });
            const cw = self.id();
            try self.emit(&self.body, 81, &.{ self.float_type, cw, zw, 1 });
            break :blk .{
                if (inst.export_enable & 1 != 0) cx else zero,
                if (inst.export_enable & 2 != 0) cy else zero,
                if (inst.export_enable & 4 != 0) cz else zero,
                if (inst.export_enable & 8 != 0) cw else if (is_position) one else zero,
            };
        } else .{
            // Uncompressed: one f32 per channel from src0..src3.
            if (inst.export_enable & 1 != 0) try self.source(inst.src0, .float32) else zero,
            if (inst.export_enable & 2 != 0) try self.source(inst.src1, .float32) else zero,
            if (inst.export_enable & 4 != 0) try self.source(inst.src2, .float32) else zero,
            if (inst.export_enable & 8 != 0)
                try self.source(inst.src3, .float32)
            else if (is_position)
                one
            else
                zero,
        };
        // If W is exactly 0 (failed constant-buffer row), force W=1 so
        // clip-space positions stay finite and rasterizable.
        var out_w = w;
        if (is_position) {
            const w_is_zero = self.id();
            try self.emit(&self.body, 180, &.{ self.bool_type, w_is_zero, w, zero }); // OpFOrdEqual
            const w_fixed = self.id();
            try self.emit(&self.body, 169, &.{ self.float_type, w_fixed, w_is_zero, one, w }); // OpSelect
            out_w = w_fixed;
        }
        const vector = self.id();
        try self.emit(&self.body, 80, &.{ self.vector4_type, vector, x, y, z, out_w }); // OpCompositeConstruct
        try self.emit(&self.body, 62, &.{ output, vector }); // OpStore
    }

    fn exportNggLdsRecord(self: *Builder) Error!void {
        if (self.stage != .vertex or self.ngg_lds_exports.len == 0) return;
        for (self.ngg_lds_exports) |record| {
            try self.exportValue(.{
                .opcode = .exp,
                .export_target = record.target,
                .export_enable = record.enable,
                .src0 = record.sources[0],
                .src1 = record.sources[1],
                .src2 = record.sources[2],
                .src3 = record.sources[3],
                .src_count = 4,
            });
        }
    }

    fn storageBinding(self: *const Builder, resource_sgpr: u32, instruction_pc: u32) ?StorageBufferBinding {
        for (self.storage_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr and
                binding.instruction_pc != null and binding.instruction_pc.? == instruction_pc)
            {
                return binding;
            }
        }
        for (self.storage_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr and binding.instruction_pc == null) return binding;
        }
        return null;
    }

    /// Returns whether this particular buffer instruction has a staged host
    /// descriptor. A shader can legitimately reference more V# descriptors
    /// than the backend managed to recover for one draw. Treating that as a
    /// fatal translation error discards every other valid attribute fetch in
    /// the shader, so missing resources are handled as null buffers by the
    /// individual load/store lowering paths instead.
    fn hasBufferStorage(self: *const Builder, inst: instruction.Instruction) Error!bool {
        if (self.storage_array == 0) return false;
        if (inst.src1.kind != .sgpr) return Error.UnsupportedBufferAddressing;
        return self.storageBinding(inst.src1.reg, inst.pc) != null;
    }

    fn sampledImageBinding(
        self: *const Builder,
        resource_sgpr: u32,
        sampler_sgpr: u32,
        instruction_pc: u32,
    ) ?SampledImageBinding {
        for (self.sampled_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr and
                binding.sampler_sgpr == sampler_sgpr and
                binding.instruction_pc != null and binding.instruction_pc.? == instruction_pc)
            {
                return binding;
            }
        }
        for (self.sampled_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr and
                binding.sampler_sgpr == sampler_sgpr and binding.instruction_pc == null)
            {
                return binding;
            }
        }
        return null;
    }

    fn storageImageBinding(self: *const Builder, resource_sgpr: u32) ?StorageImageBinding {
        for (self.storage_image_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr) return binding;
        }
        return null;
    }

    fn loadStorageImage(self: *Builder, binding: StorageImageBinding) Error!u32 {
        if (binding.descriptor_index >= self.storage_image_variables.len) return Error.InvalidStorageBinding;
        const descriptor_index: usize = @intCast(binding.descriptor_index);
        const image_type = self.storage_image_types[descriptor_index];
        const variable = self.storage_image_variables[descriptor_index];
        if (image_type == 0 or variable == 0) return Error.InvalidStorageBinding;
        const image = self.id();
        try self.emit(&self.body, 61, &.{ image_type, image, variable }); // OpLoad
        return image;
    }

    fn storageImageCoordinates(
        self: *Builder,
        inst: instruction.Instruction,
        dimension: StorageImageDimension,
    ) Error!u32 {
        const x = try self.source(try imageAddressOperand(inst, 0), .bits32);
        const y = try self.source(try imageAddressOperand(inst, 1), .bits32);
        const coordinates = self.id();
        if (dimension == .three_d) {
            if (self.vector3_bits_type == 0) return Error.InvalidStorageBinding;
            const z = try self.source(try imageAddressOperand(inst, 2), .bits32);
            try self.emit(&self.body, 80, &.{ self.vector3_bits_type, coordinates, x, y, z }); // OpCompositeConstruct
        } else {
            try self.emit(&self.body, 80, &.{ self.vector2_bits_type, coordinates, x, y }); // OpCompositeConstruct
        }
        return coordinates;
    }

    fn storageImageConstant(self: *Builder, value_type: ValueType, selector: u8) Error!u32 {
        return switch (selector) {
            0 => self.constant(value_type, 0),
            1 => self.constant(
                value_type,
                if (value_type == .float32) @bitCast(@as(f32, 1.0)) else 1,
            ),
            else => Error.InvalidStorageBinding,
        };
    }

    fn sampledImageFetch(self: *Builder, inst: instruction.Instruction) Error!void {
        if ((self.stage != .vertex and self.stage != .fragment and self.stage != .compute) or inst.opcode_id != 0 or
            inst.image_dimension != .dim_2d or inst.image_address_components != 2 or
            inst.data_mask == 0 or inst.src0.kind != .vgpr or
            inst.src1.kind != .sgpr or inst.src2.kind != .sgpr)
        {
            return Error.UnsupportedOpcode;
        }
        const binding = self.sampledImageBinding(inst.src1.reg, inst.src2.reg, inst.pc) orelse
            return Error.InvalidStorageBinding;
        if (binding.dimension != .two_d or self.sampled_image_arrays[0] == 0 or
            self.sampled_image_image_types[0] == 0)
        {
            return Error.InvalidStorageBinding;
        }

        const x = try self.source(try imageAddressOperand(inst, 0), .bits32);
        const y = try self.source(try imageAddressOperand(inst, 1), .bits32);
        const coordinates = self.id();
        try self.emit(&self.body, 80, &.{ try self.ensureBitsVec2(), coordinates, x, y }); // OpCompositeConstruct
        const pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.sampled_image_pointer_types[0],
            pointer,
            self.sampled_image_arrays[0],
            try self.constant(.bits32, binding.descriptor_index),
        });
        const sampled_image = self.id();
        try self.emit(&self.body, 61, &.{ self.sampled_image_types[0], sampled_image, pointer });
        const image = self.id();
        try self.emit(&self.body, 100, &.{ self.sampled_image_image_types[0], image, sampled_image }); // OpImage
        const texel = self.id();
        try self.emit(&self.body, 95, &.{
            self.vector4_type,
            texel,
            image,
            coordinates,
            0x2, // ImageOperands Lod
            try self.constant(.bits32, 0),
        }); // OpImageFetch

        var destination_index: u32 = 0;
        for (0..4) |component| {
            const bit = @as(u4, 1) << @intCast(component);
            if (inst.data_mask & bit == 0) continue;
            const value = self.id();
            try self.emit(&self.body, 81, &.{ self.float_type, value, texel, @intCast(component) });
            try self.destination(
                try consecutiveRegister(inst.dst, destination_index),
                .{ .id = value, .value_type = .float32 },
            );
            destination_index += 1;
        }
    }

    fn imageLoad(self: *Builder, inst: instruction.Instruction) Error!void {
        if (self.stage != .compute) return self.sampledImageFetch(inst);
        if (inst.opcode_id != 0 or
            (inst.image_dimension != .dim_2d and inst.image_dimension != .dim_3d) or
            (inst.image_address_components != 2 and inst.image_address_components != 3) or
            inst.data_mask == 0 or
            inst.src0.kind != .vgpr or inst.src1.kind != .sgpr)
        {
            return Error.UnsupportedOpcode;
        }
        const binding = self.storageImageBinding(inst.src1.reg) orelse
            return self.sampledImageFetch(inst);
        if ((binding.dimension == .three_d) != (inst.image_dimension == .dim_3d)) {
            return Error.InvalidStorageBinding;
        }
        const descriptor_index: usize = @intCast(binding.descriptor_index);
        const value_type = storageImageValueType(binding.format);
        const vector_type = self.storage_image_vector_types[descriptor_index];
        if (vector_type == 0) return Error.InvalidStorageBinding;
        const image = try self.loadStorageImage(binding);
        const coordinates = try self.storageImageCoordinates(inst, binding.dimension);
        const texel = self.id();
        try self.emit(&self.body, 98, &.{ vector_type, texel, image, coordinates }); // OpImageRead

        var destination_index: u32 = 0;
        for (0..4) |component| {
            const bit = @as(u4, 1) << @intCast(component);
            if (inst.data_mask & bit == 0) continue;
            const selector = binding.dst_select[component];
            const value = if (selector >= 4) blk: {
                const extracted = self.id();
                try self.emit(&self.body, 81, &.{
                    self.typeId(value_type),
                    extracted,
                    texel,
                    selector - 4,
                }); // OpCompositeExtract
                break :blk extracted;
            } else try self.storageImageConstant(value_type, selector);
            try self.destination(
                try consecutiveRegister(inst.dst, destination_index),
                .{ .id = value, .value_type = value_type },
            );
            destination_index += 1;
        }
    }

    fn imageStore(self: *Builder, inst: instruction.Instruction) Error!void {
        if (self.stage != .compute or
            inst.opcode_id != 8 or
            (inst.image_dimension != .dim_2d and inst.image_dimension != .dim_3d and
                inst.image_dimension != .dim_2d_array_alt) or
            (inst.image_address_components != 2 and inst.image_address_components != 3) or
            inst.data_mask != 0xf or
            inst.dst.kind != .vgpr or inst.src0.kind != .vgpr or inst.src1.kind != .sgpr)
        {
            return Error.UnsupportedOpcode;
        }
        const binding = self.storageImageBinding(inst.src1.reg) orelse return Error.InvalidStorageBinding;
        if ((binding.dimension == .three_d) != (inst.image_dimension == .dim_3d)) {
            return Error.InvalidStorageBinding;
        }
        const descriptor_index: usize = @intCast(binding.descriptor_index);
        const value_type = storageImageValueType(binding.format);
        const vector_type = self.storage_image_vector_types[descriptor_index];
        if (vector_type == 0) return Error.InvalidStorageBinding;
        const image = try self.loadStorageImage(binding);
        // Unity's generic copy kernel uses the 2D-array opcode even when the
        // bound T# is a one-slice 2D view. The descriptor already selects that
        // slice, so its third coordinate is intentionally ignored here.
        const coordinates = try self.storageImageCoordinates(inst, binding.dimension);
        var shader_values: [4]u32 = undefined;
        for (&shader_values, 0..) |*value, component| {
            value.* = try self.source(try consecutiveRegister(inst.dst, @intCast(component)), value_type);
        }
        var physical_values: [4]u32 = undefined;
        for (&physical_values, 0..) |*value, physical_component| {
            value.* = try self.storageImageConstant(value_type, 0);
            const target: u8 = @intCast(4 + physical_component);
            for (binding.dst_select, 0..) |selector, shader_component| {
                if (selector == target) {
                    value.* = shader_values[shader_component];
                    break;
                }
            }
        }
        const texel = self.id();
        try self.emit(&self.body, 80, &.{
            vector_type,
            texel,
            physical_values[0],
            physical_values[1],
            physical_values[2],
            physical_values[3],
        }); // OpCompositeConstruct
        try self.emit(&self.body, 99, &.{ image, coordinates, texel }); // OpImageWrite
    }

    /// FragCoord.xy scaled into 0..1 UVs for the active color-target extent.
    fn fragCoordUv(self: *Builder) Error![2]u32 {
        if (self.frag_coord_input == 0 or self.vector4_type == 0) {
            const half = try self.constant(.float32, @bitCast(@as(f32, 0.5)));
            return .{ half, half };
        }
        const coord = self.id();
        try self.emit(&self.body, 61, &.{ self.vector4_type, coord, self.frag_coord_input }); // OpLoad
        const x = self.id();
        const y = self.id();
        try self.emit(&self.body, 81, &.{ self.float_type, x, coord, 0 }); // OpCompositeExtract
        try self.emit(&self.body, 81, &.{ self.float_type, y, coord, 1 });
        const width: f32 = @floatFromInt(@max(self.fragment_extent[0], 1));
        const height: f32 = @floatFromInt(@max(self.fragment_extent[1], 1));
        const inv_w = try self.constant(.float32, @bitCast(@as(f32, 1.0) / width));
        const inv_h = try self.constant(.float32, @bitCast(@as(f32, 1.0) / height));
        const u = self.id();
        const v = self.id();
        try self.emit(&self.body, 133, &.{ self.float_type, u, x, inv_w }); // OpFMul
        try self.emit(&self.body, 133, &.{ self.float_type, v, y, inv_h });
        return .{ u, v };
    }

    fn sampleCoordinates(_: *Builder, raw_x: u32, raw_y: u32) Error![2]u32 {
        return .{ raw_x, raw_y };
    }

    fn imageAddressOperand(inst: instruction.Instruction, component: u32) Error!operand.Operand {
        if (inst.src0.kind != .vgpr) return Error.UnsupportedBufferAddressing;
        if (component == 0) return inst.src0;
        if (inst.image_nsa_words != 0) {
            const nsa_index = component - 1;
            const nsa_count = @as(u32, inst.image_nsa_words) * 4;
            if (nsa_index >= nsa_count) return Error.UnsupportedBufferAddressing;
            return .{ .kind = .vgpr, .reg = inst.image_nsa_address[nsa_index] };
        }
        return consecutiveRegister(inst.src0, component);
    }

    fn interpolateParameter(self: *Builder, inst: instruction.Instruction) Error!void {
        if (self.stage != .fragment or inst.src1.kind != .integer_inline_constant) {
            return Error.InvalidStageInterface;
        }
        const attribute = inst.src1.value;
        const component = if (inst.opcode == .v_interp_mov_f32)
            inst.src0.value
        else
            inst.src2.value;
        if (attribute >= self.parameter_variables.len or component >= 4) {
            return Error.InvalidStageInterface;
        }

        const variable = self.parameter_variables[attribute];
        const value = if (variable != 0) blk: {
            const vector = self.id();
            try self.emit(&self.body, 61, &.{ self.vector4_type, vector, variable }); // OpLoad
            const scalar = self.id();
            try self.emit(&self.body, 81, &.{ self.float_type, scalar, vector, component }); // OpCompositeExtract
            break :blk scalar;
        } else blk: {
            // A malformed or partially recovered interface still gets a
            // deterministic screen-space fallback instead of an undefined VGPR.
            const uv = try self.fragCoordUv();
            if (component < 2) break :blk uv[component];
            break :blk try self.constant(.float32, @bitCast(@as(f32, 0)));
        };
        try self.destination(inst.dst, .{ .id = value, .value_type = .float32 });
    }

    fn sampleImage(self: *Builder, inst: instruction.Instruction) Error!void {
        const flags: u16 = @bitCast(inst.image_sample_flags);
        const implicit_lod = inst.opcode_id == 0x20 and flags == 0;
        const level_zero = inst.opcode_id == 0x27 and
            inst.image_sample_flags.level_zero and
            flags == (@as(u16, 1) << 5);
        const level_zero_offset = inst.opcode_id == 0x37 and
            inst.image_sample_flags.level_zero and inst.image_sample_flags.offset and
            flags == ((@as(u16, 1) << 5) | (@as(u16, 1) << 4));
        const explicit_lod = inst.opcode_id == 0x24 and
            inst.image_sample_flags.lod and flags == (@as(u16, 1) << 0);
        const biased_lod = inst.opcode_id == 0x25 and
            inst.image_sample_flags.bias and flags == (@as(u16, 1) << 1);
        const image_dimension: SampledImageDimension = switch (inst.image_dimension) {
            .dim_2d => .two_d,
            .dim_3d => .three_d,
            // GFX10 DIM=3 is Cube. The historical enum name predates the
            // sampled-image implementation and is retained for ABI stability.
            .dim_2d_array => .cube,
            else => return Error.UnsupportedOpcode,
        };
        const dimension_index = sampledImageDimensionIndex(image_dimension);
        const coordinate_components: u8 = if (image_dimension == .two_d) 2 else 3;
        if ((self.stage != .vertex and self.stage != .fragment and self.stage != .compute) or
            self.sampled_image_arrays[dimension_index] == 0 or
            (!implicit_lod and !level_zero and !level_zero_offset and !explicit_lod and !biased_lod) or
            ((self.stage == .vertex or self.stage == .compute) and
                !level_zero and !level_zero_offset and !explicit_lod) or
            inst.image_address_components != coordinate_components +
                @as(u8, @intFromBool(level_zero_offset or explicit_lod or biased_lod)) or
            inst.data_mask == 0)
        {
            return Error.UnsupportedOpcode;
        }
        if (inst.src0.kind != .vgpr or inst.src1.kind != .sgpr or inst.src2.kind != .sgpr) {
            return Error.UnsupportedBufferAddressing;
        }
        const binding = self.sampledImageBinding(inst.src1.reg, inst.src2.reg, inst.pc) orelse {
            return Error.InvalidStorageBinding;
        };
        if (binding.dimension != image_dimension) return Error.InvalidStorageBinding;
        // Coordinates now come from the real VS PARAM -> PS VINTRP interface.
        const coordinate_base: u32 = @intFromBool(level_zero_offset);
        const raw_x = try self.source(try imageAddressOperand(inst, coordinate_base), .float32);
        const raw_y = try self.source(try imageAddressOperand(inst, coordinate_base + 1), .float32);
        const coordinate_x, const coordinate_y = try self.sampleCoordinates(raw_x, raw_y);
        const coordinates = self.id();
        if (image_dimension != .two_d) {
            const coordinate_z = try self.source(try imageAddressOperand(inst, coordinate_base + 2), .float32);
            try self.emit(&self.body, 80, &.{ self.vector3_type, coordinates, coordinate_x, coordinate_y, coordinate_z });
        } else {
            try self.emit(&self.body, 80, &.{ self.vector2_type, coordinates, coordinate_x, coordinate_y });
        }
        const pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.sampled_image_pointer_types[dimension_index],
            pointer,
            self.sampled_image_arrays[dimension_index],
            try self.constant(.bits32, binding.descriptor_index),
        });
        const sampled_image = self.id();
        try self.emit(&self.body, 61, &.{ self.sampled_image_types[dimension_index], sampled_image, pointer });
        const sampled = self.id();
        if (level_zero_offset) {
            const offset = try self.imageTexelOffset(inst);
            try self.emit(&self.body, 88, &.{
                self.vector4_type,
                sampled,
                sampled_image,
                coordinates,
                0x12, // ImageOperands Lod | Offset
                try self.constant(.float32, @bitCast(@as(f32, 0))),
                offset,
            }); // OpImageSampleExplicitLod
        } else if (level_zero or explicit_lod) {
            // Compute shaders have no implicit derivatives. GFX10's
            // image_sample_lz names mip zero explicitly, which maps directly to
            // an explicit SPIR-V Lod operand and is valid in every shader stage.
            const lod = if (explicit_lod)
                try self.source(try imageAddressOperand(inst, coordinate_components), .float32)
            else
                try self.constant(.float32, @bitCast(@as(f32, 0)));
            try self.emit(&self.body, 88, &.{
                self.vector4_type,
                sampled,
                sampled_image,
                coordinates,
                0x2, // ImageOperands Lod
                lod,
            }); // OpImageSampleExplicitLod
        } else if (biased_lod) {
            const bias = try self.source(try imageAddressOperand(inst, coordinate_components), .float32);
            try self.emit(&self.body, 87, &.{
                self.vector4_type,
                sampled,
                sampled_image,
                coordinates,
                0x1, // ImageOperands Bias
                bias,
            }); // OpImageSampleImplicitLod
        } else {
            try self.emit(&self.body, 87, &.{ self.vector4_type, sampled, sampled_image, coordinates }); // OpImageSampleImplicitLod
        }

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

    fn imageTexelOffset(self: *Builder, inst: instruction.Instruction) Error!u32 {
        const packed_bits = try self.source(try imageAddressOperand(inst, 0), .bits32);
        const packed_signed = try self.convert(.{ .id = packed_bits, .value_type = .bits32 }, .sint32);
        const bit_zero = try self.constant(.sint32, 0);
        const bit_eight = try self.constant(.sint32, 8);
        const six = try self.constant(.sint32, 6);
        const offset_x = self.id();
        const offset_y = self.id();
        try self.emit(&self.body, 202, &.{ self.signed_type, offset_x, packed_signed, bit_zero, six }); // OpBitFieldSExtract
        try self.emit(&self.body, 202, &.{ self.signed_type, offset_y, packed_signed, bit_eight, six });
        const offset = self.id();
        try self.emit(&self.body, 80, &.{ try self.ensureSignedVec2(), offset, offset_x, offset_y });
        return offset;
    }

    fn gatherImage(self: *Builder, inst: instruction.Instruction) Error!void {
        const flags: u16 = @bitCast(inst.image_sample_flags);
        const supported_flags = (@as(u16, 1) << 5) | (@as(u16, 1) << 4);
        if (self.stage != .fragment or inst.image_dimension != .dim_2d or
            !inst.image_sample_flags.level_zero or inst.image_sample_flags.compare or
            flags & ~supported_flags != 0 or inst.data_mask == 0 or
            inst.image_address_components != 2 + @as(u8, @intFromBool(inst.image_sample_flags.offset)))
        {
            return Error.UnsupportedOpcode;
        }
        if (inst.src0.kind != .vgpr or inst.src1.kind != .sgpr or inst.src2.kind != .sgpr) {
            return Error.UnsupportedBufferAddressing;
        }
        const binding = self.sampledImageBinding(inst.src1.reg, inst.src2.reg, inst.pc) orelse
            return Error.InvalidStorageBinding;
        if (binding.dimension != .two_d or self.sampled_image_arrays[0] == 0) {
            return Error.InvalidStorageBinding;
        }

        const coordinate_base: u32 = @intFromBool(inst.image_sample_flags.offset);
        const raw_x = try self.source(try imageAddressOperand(inst, coordinate_base), .float32);
        const raw_y = try self.source(try imageAddressOperand(inst, coordinate_base + 1), .float32);
        const coordinates = self.id();
        try self.emit(&self.body, 80, &.{ self.vector2_type, coordinates, raw_x, raw_y }); // OpCompositeConstruct

        const pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.sampled_image_pointer_types[0],
            pointer,
            self.sampled_image_arrays[0],
            try self.constant(.bits32, binding.descriptor_index),
        });
        const sampled_image = self.id();
        try self.emit(&self.body, 61, &.{ self.sampled_image_types[0], sampled_image, pointer });

        const component: u32 = @ctz(inst.data_mask);
        const gathered = self.id();
        if (inst.image_sample_flags.offset) {
            const offset = try self.imageTexelOffset(inst);
            try self.emit(&self.body, 96, &.{
                self.vector4_type,
                gathered,
                sampled_image,
                coordinates,
                try self.constant(.bits32, component),
                0x10, // ImageOperands Offset
                offset,
            }); // OpImageGather
        } else {
            try self.emit(&self.body, 96, &.{
                self.vector4_type,
                gathered,
                sampled_image,
                coordinates,
                try self.constant(.bits32, component),
            }); // OpImageGather
        }

        for (0..4) |index| {
            const value = self.id();
            try self.emit(&self.body, 81, &.{ self.float_type, value, gathered, @intCast(index) }); // OpCompositeExtract
            try self.destination(
                try consecutiveRegister(inst.dst, @intCast(index)),
                .{ .id = value, .value_type = .float32 },
            );
        }
    }

    fn addBits(self: *Builder, a: u32, b: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, result, a, b }); // OpIAdd
        return result;
    }

    fn consecutiveRegister(op: operand.Operand, delta: u32) Error!operand.Operand {
        if (delta == 0) return op;
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

    fn multiplyHighUnsignedBits(self: *Builder, a: u32, b: u32) Error!u32 {
        const mask = try self.constant(.bits32, 0xffff);
        const sixteen = try self.constant(.bits32, 16);
        const a0 = try self.andBits(a, 0xffff);
        const b0 = try self.andBits(b, 0xffff);
        const a1 = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, a1, a, sixteen });
        const b1 = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, b1, b, sixteen });

        const w0 = try self.multiplyBits(a0, b0);
        const w0_high = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, w0_high, w0, sixteen });
        const t0 = try self.multiplyBits(a1, b0);
        const t = try self.addBits(t0, w0_high);
        const w2 = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, w2, t, sixteen });
        const w1_low = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, w1_low, t, mask });
        const cross = try self.multiplyBits(a0, b1);
        const w1 = try self.addBits(w1_low, cross);
        const w1_high = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, w1_high, w1, sixteen });
        const high_product = try self.multiplyBits(a1, b1);
        return self.addBits(try self.addBits(high_product, w2), w1_high);
    }

    fn multiplyHighUnsigned(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const high = try self.multiplyHighUnsignedBits(a, b);
        try self.destination(inst.dst, .{ .id = high, .value_type = .bits32 });
    }

    fn multiplyHighSigned(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const unsigned_high = try self.multiplyHighUnsignedBits(a, b);
        const signed_a = try self.convert(.{ .id = a, .value_type = .bits32 }, .sint32);
        const signed_b = try self.convert(.{ .id = b, .value_type = .bits32 }, .sint32);
        const signed_zero = try self.constant(.sint32, 0);
        const a_negative = self.id();
        try self.emit(&self.body, 177, &.{ self.bool_type, a_negative, signed_a, signed_zero }); // OpSLessThan
        const b_negative = self.id();
        try self.emit(&self.body, 177, &.{ self.bool_type, b_negative, signed_b, signed_zero }); // OpSLessThan
        const zero = try self.constant(.bits32, 0);
        const correction_a = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, correction_a, a_negative, b, zero }); // OpSelect
        const correction_b = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, correction_b, b_negative, a, zero }); // OpSelect
        const partially_corrected = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, partially_corrected, unsigned_high, correction_a }); // OpISub
        const high = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, high, partially_corrected, correction_b }); // OpISub
        try self.destination(inst.dst, .{ .id = high, .value_type = .bits32 });
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

    fn workgroupByteAddress(self: *Builder, inst: instruction.Instruction, offset: u32) Error!u32 {
        if (self.stage != .compute or self.workgroup_memory == 0 or inst.gds or
            inst.src0.kind != .vgpr or inst.memory_offset < 0)
        {
            return Error.UnsupportedBufferAddressing;
        }
        const address = try self.source(inst.src0, .bits32);
        return self.addBits(address, try self.constant(.bits32, offset));
    }

    fn workgroupAccess(self: *Builder, byte_address: u32) Error!WorkgroupAccess {
        if (self.workgroup_memory == 0 or self.workgroup_word_pointer_type == 0) {
            return Error.UnsupportedBufferAddressing;
        }
        const word_index = try self.shiftRightBits(byte_address, 2);
        const in_range = self.id();
        try self.emit(&self.body, 176, &.{
            self.bool_type,
            in_range,
            word_index,
            try self.constant(.bits32, self.workgroup_memory_words),
        }); // OpULessThan
        const safe_index = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            safe_index,
            in_range,
            word_index,
            try self.constant(.bits32, 0),
        }); // OpSelect
        const pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.workgroup_word_pointer_type,
            pointer,
            self.workgroup_memory,
            safe_index,
        }); // OpAccessChain
        return .{ .pointer = pointer, .in_range = in_range };
    }

    fn loadWorkgroupWord(self: *Builder, byte_address: u32) Error!u32 {
        const access = try self.workgroupAccess(byte_address);
        const loaded = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, loaded, access.pointer }); // OpLoad
        const result = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            result,
            access.in_range,
            loaded,
            try self.constant(.bits32, 0),
        }); // OpSelect
        return result;
    }

    fn storeWorkgroupWord(self: *Builder, byte_address: u32, value: u32) Error!void {
        const access = try self.workgroupAccess(byte_address);
        const predicate = (try self.writePredicate(access.in_range)) orelse access.in_range;
        try self.guardedStore(predicate, access.pointer, value);
    }

    fn loadDsWord(self: *Builder, inst: instruction.Instruction, offset: u32) Error!u32 {
        return self.loadWorkgroupWord(try self.workgroupByteAddress(inst, offset));
    }

    fn storeDsWord(self: *Builder, inst: instruction.Instruction, offset: u32, value: u32) Error!void {
        try self.storeWorkgroupWord(try self.workgroupByteAddress(inst, offset), value);
    }

    fn dsReadWords(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        const base_offset: u32 = @intCast(inst.memory_offset);
        for (0..count) |index| {
            const value = try self.loadDsWord(inst, base_offset + @as(u32, @intCast(index)) * 4);
            try self.destination(try consecutiveRegister(inst.dst, @intCast(index)), .{
                .id = value,
                .value_type = .bits32,
            });
        }
    }

    fn dsWriteWords(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        const base_offset: u32 = @intCast(inst.memory_offset);
        for (0..count) |index| {
            const value = try self.source(try consecutiveRegister(inst.src1, @intCast(index)), .bits32);
            try self.storeDsWord(inst, base_offset + @as(u32, @intCast(index)) * 4, value);
        }
    }

    fn dsReadPair(self: *Builder, inst: instruction.Instruction) Error!void {
        const offsets = [_]u32{
            @intCast(inst.memory_offset),
            @intCast(inst.secondary_memory_offset),
        };
        for (offsets, 0..) |offset, index| {
            const value = try self.loadDsWord(inst, offset);
            try self.destination(try consecutiveRegister(inst.dst, @intCast(index)), .{
                .id = value,
                .value_type = .bits32,
            });
        }
    }

    fn dsWritePair(self: *Builder, inst: instruction.Instruction) Error!void {
        const offsets = [_]u32{
            @intCast(inst.memory_offset),
            @intCast(inst.secondary_memory_offset),
        };
        const sources = [_]operand.Operand{ inst.src1, inst.src2 };
        for (offsets, sources) |offset, source_operand| {
            try self.storeDsWord(inst, offset, try self.source(source_operand, .bits32));
        }
    }

    fn loadDsByte(self: *Builder, inst: instruction.Instruction, offset: u32) Error!u32 {
        const byte_address = try self.workgroupByteAddress(inst, offset);
        const word = try self.loadWorkgroupWord(byte_address);
        const byte_index = try self.andBits(byte_address, 3);
        const shift = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shift, byte_index, try self.constant(.bits32, 3) });
        const shifted = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, shifted, word, shift });
        return self.andBits(shifted, 0xff);
    }

    fn dsReadSubword(self: *Builder, inst: instruction.Instruction, width: u8, signed: bool) Error!void {
        const base_offset: u32 = @intCast(inst.memory_offset);
        var result = try self.loadDsByte(inst, base_offset);
        if (width == 16) {
            const high = try self.loadDsByte(inst, base_offset + 1);
            const shifted = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, shifted, high, try self.constant(.bits32, 8) });
            const combined = self.id();
            try self.emit(&self.body, 197, &.{ self.bits_type, combined, result, shifted });
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

    fn dsAtomic(self: *Builder, inst: instruction.Instruction, opcode: u16) Error!void {
        const byte_address = try self.workgroupByteAddress(inst, @intCast(inst.memory_offset));
        const access = try self.workgroupAccess(byte_address);
        const predicate = (try self.writePredicate(access.in_range)) orelse access.in_range;
        const taken = self.id();
        const merge = self.id();
        try self.emit(&self.body, 247, &.{ merge, 0 }); // OpSelectionMerge
        try self.emit(&self.body, 250, &.{ predicate, taken, merge }); // OpBranchConditional
        try self.emit(&self.body, 248, &.{taken});
        const result = self.id();
        try self.emit(&self.body, opcode, &.{
            self.bits_type,
            result,
            access.pointer,
            try self.constant(.bits32, 2), // ScopeWorkgroup
            try self.constant(.bits32, 0), // relaxed
            try self.source(inst.src1, .bits32),
        });
        try self.emit(&self.body, 249, &.{merge});
        try self.emit(&self.body, 248, &.{merge});
    }

    fn controlBarrier(self: *Builder) Error!void {
        if (self.stage != .compute) return;
        try self.emit(&self.body, 224, &.{
            try self.constant(.bits32, 2), // execution scope Workgroup
            try self.constant(.bits32, 2), // memory scope Workgroup
            try self.constant(.bits32, 0x108), // AcquireRelease | WorkgroupMemory
        });
    }

    fn readFirstLane(self: *Builder, inst: instruction.Instruction) Error!void {
        const source_value = try self.source(inst.src0, .bits32);
        const result = self.id();
        try self.emit(&self.body, 338, &.{
            self.bits_type,
            result,
            try self.constant(.bits32, 3), // ScopeSubgroup
            source_value,
        }); // OpGroupNonUniformBroadcastFirst
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn bufferAddressDelta(self: *Builder, inst: instruction.Instruction, extra_offset: u32) Error!BufferAddress {
        if (self.storage_array == 0 or inst.src1.kind != .sgpr) {
            // No host storage for this V# — emit a zeroed load/store target by
            // reporting a clear error that the caller may soft-skip.
            return Error.UnsupportedBufferAddressing;
        }
        if (inst.memory_offset < 0) return Error.UnsupportedBufferAddressing;
        const binding = self.storageBinding(inst.src1.reg, inst.pc) orelse {
            return Error.InvalidStorageBinding;
        };

        // NGG/export VS programs often clobber the VertexIndex VGPR (v0) with
        // v_cndmask before the attribute MUBUF. Prefer the system VertexIndex
        // whenever the load still *names* that VGPR as its index so every
        // vertex does not alias record 0 and collapse to a zero-area draw.
        var index = if (inst.index_enable) blk: {
            if (self.stage == .vertex and self.vertex_index_input != 0 and
                (binding.use_vertex_index or
                    (inst.src0.kind == .vgpr and self.vertex_index_vgpr != null and
                        inst.src0.reg == self.vertex_index_vgpr.?)))
            {
                const loaded = self.id();
                try self.emit(&self.body, 61, &.{ self.signed_type, loaded, self.vertex_index_input }); // OpLoad
                break :blk try self.convert(.{ .id = loaded, .value_type = .sint32 }, .bits32);
            }
            break :blk try self.source(inst.src0, .bits32);
        } else try self.constant(.bits32, 0);
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
        // SOFFSET: VCC/EXEC/M0 encodings mean "no scalar offset" (zero), not
        // the all-ones mask used when those registers are read as lane masks.
        // Treating them as 0xffffffff made every attribute MUBUF OOB → zero
        // verts → black guest VS writeback.
        const soffset = if (binding.soffset_value) |value|
            try self.constant(.bits32, value)
        else switch (inst.src2.kind) {
            .null,
            .m0,
            .vcc_lo,
            .vcc_hi,
            .exec_lo,
            .exec_hi,
            .ttmp,
            .flat_scratch_base_lo,
            .flat_scratch_base_hi,
            .shared_base,
            .shared_limit,
            .private_base,
            .private_limit,
            .lds_direct,
            .vcc_z,
            .exec_z,
            .scc,
            .pops_exiting_wave_id,
            => try self.constant(.bits32, 0),
            else => try self.source(inst.src2, .bits32),
        };
        byte_offset = try self.addBits(byte_offset, soffset);
        // Scalar-buffer addressing is dword based: GFX10 clears the low two
        // bits after adding the descriptor-relative immediate and SOFFSET.
        // This differs subtly from MUBUF, where byte/subword addressing must
        // retain those bits.  Keeping the alignment here also makes dynamic
        // S_BUFFER_LOAD match the host scalar evaluator used for recovered
        // prolog constants.
        if (inst.family == .smem) {
            byte_offset = try self.andBits(byte_offset, 0xffff_fffc);
        }
        return .{ .binding = binding, .byte_offset = byte_offset };
    }

    fn bufferAddress(self: *Builder, inst: instruction.Instruction) Error!BufferAddress {
        return self.bufferAddressDelta(inst, 0);
    }

    /// Whether a word access lies inside the descriptor's live Vulkan range.
    /// Keeping the range dynamic prevents streamed buffer sizes from becoming
    /// part of the generated module (and consequently the pipeline cache key).
    fn wordInRange(self: *Builder, address: BufferAddress, delta: u32) Error!?u32 {
        if (self.storage_array == 0 or self.storage_block_pointer_type == 0) return null;
        // Query the descriptor's live range. Baking `extent_bytes` into SPIR-V
        // makes an otherwise identical shader a new pipeline whenever a sprite
        // batch contains a different number of vertices.
        const block_pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.storage_block_pointer_type,
            block_pointer,
            self.storage_array,
            try self.constant(.bits32, address.binding.descriptor_index),
        }); // OpAccessChain descriptor
        const word_count = self.id();
        try self.emit(&self.body, 68, &.{ self.bits_type, word_count, block_pointer, 0 }); // OpArrayLength
        const extent = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, extent, word_count, try self.constant(.bits32, 2) });
        // The last byte this word touches, so a word straddling the end counts
        // as outside rather than half inside.
        const last = try self.addBits(address.byte_offset, try self.constant(.bits32, delta * 4 + 3));
        const result = self.id();
        try self.emit(&self.body, 176, &.{ // OpULessThan
            self.bool_type,
            result,
            last,
            extent,
        });
        return result;
    }

    /// A word access: where it is, and whether it is really there.
    const WordAccess = struct {
        pointer: u32,
        /// Null only when no storage descriptor array was declared.
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
        if (!try self.hasBufferStorage(inst)) {
            // No host V# mapping. Zero is correct for missing vertex attributes,
            // but fragment s_buffer_load often feeds a colour scale that multiplies
            // the sample — zero kills the whole writeback. Use 1.0f so a missing
            // constant buffer acts as an identity scale during bring-up.
            const fill_bits: u32 = if (inst.family == .smem)
                @as(u32, @bitCast(@as(f32, 1.0)))
            else
                0;
            const fill = try self.constant(.bits32, fill_bits);
            for (0..count) |index| {
                try self.destination(try consecutiveRegister(inst.dst, @intCast(index)), .{
                    .id = fill,
                    .value_type = .bits32,
                });
            }
            return;
        }
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
        if (!try self.hasBufferStorage(inst)) return; // drop stores without this host V#
        for (0..count) |index| {
            const value = try self.source(try consecutiveRegister(inst.dst, @intCast(index)), .bits32);
            const address = try self.bufferAddressDelta(inst, @intCast(index * 4));
            try self.storeBufferWord(address, 0, value);
        }
    }

    fn bufferAtomic(self: *Builder, inst: instruction.Instruction, opcode: u16) Error!void {
        if (!try self.hasBufferStorage(inst)) {
            if (inst.globally_coherent) {
                try self.destination(inst.dst, .{
                    .id = try self.constant(.bits32, 0),
                    .value_type = .bits32,
                });
            }
            return;
        }
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

    fn bufferAddressAdd(self: *Builder, address: BufferAddress, byte_offset: u32) Error!BufferAddress {
        if (byte_offset == 0) return address;
        return .{
            .binding = address.binding,
            .byte_offset = try self.addBits(
                address.byte_offset,
                try self.constant(.bits32, byte_offset),
            ),
        };
    }

    /// A formatted component may start at any byte and packed formats share a
    /// dword. Rebuild one little-endian word byte-by-byte so the generated
    /// access remains correct across host storage-buffer word boundaries.
    fn loadUnalignedBufferWord(self: *Builder, address: BufferAddress) Error!u32 {
        var result = try self.loadBufferByte(address);
        for (1..4) |byte_index| {
            const byte = try self.loadBufferByte(try self.bufferAddressAdd(address, @intCast(byte_index)));
            const shifted = self.id();
            try self.emit(&self.body, 196, &.{
                self.bits_type,
                shifted,
                byte,
                try self.constant(.bits32, @intCast(byte_index * 8)),
            }); // OpShiftLeftLogical
            const combined = self.id();
            try self.emit(&self.body, 197, &.{ self.bits_type, combined, result, shifted }); // OpBitwiseOr
            result = combined;
        }
        return result;
    }

    fn signExtendBits(self: *Builder, raw: u32, width: u8) Error!u32 {
        if (width == 32) return raw;
        const amount: u32 = 32 - width;
        const left = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, left, raw, try self.constant(.bits32, amount) });
        const as_signed = try self.convert(.{ .id = left, .value_type = .bits32 }, .sint32);
        const extended = self.id();
        try self.emit(&self.body, 195, &.{ self.signed_type, extended, as_signed, try self.constant(.sint32, amount) });
        return self.convert(.{ .id = extended, .value_type = .sint32 }, .bits32);
    }

    fn unsignedBitsToFloat(self: *Builder, raw: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 112, &.{ self.float_type, result, raw }); // OpConvertUToF
        return result;
    }

    fn signedBitsToFloat(self: *Builder, raw: u32) Error!u32 {
        const signed = try self.convert(.{ .id = raw, .value_type = .bits32 }, .sint32);
        const result = self.id();
        try self.emit(&self.body, 111, &.{ self.float_type, result, signed }); // OpConvertSToF
        return result;
    }

    fn divideFloat(self: *Builder, numerator: u32, denominator: f32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 136, &.{
            self.float_type,
            result,
            numerator,
            try self.constant(.float32, @bitCast(denominator)),
        }); // OpFDiv
        return result;
    }

    /// Decode the unsigned 10/11-bit floating components used by
    /// 10_11_11_FLOAT and 11_11_10_FLOAT. They have a five-bit exponent and no
    /// sign, with a six- or five-bit mantissa respectively.
    fn decodeUnsignedMiniFloat(self: *Builder, raw: u32, width: u8) Error!u32 {
        const mantissa_bits: u32 = width - 5;
        const mantissa_mask: u32 = (@as(u32, 1) << @intCast(mantissa_bits)) - 1;
        const mantissa = try self.andBits(raw, mantissa_mask);
        const exponent = try self.andBits(try self.shiftRightBits(raw, mantissa_bits), 0x1f);

        const biased = try self.addBits(exponent, try self.constant(.bits32, 112));
        const exponent_bits = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, exponent_bits, biased, try self.constant(.bits32, 23) });
        const fraction_bits = self.id();
        try self.emit(&self.body, 196, &.{
            self.bits_type,
            fraction_bits,
            mantissa,
            try self.constant(.bits32, 23 - mantissa_bits),
        });
        const normal = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, normal, exponent_bits, fraction_bits });

        const mantissa_float = try self.unsignedBitsToFloat(mantissa);
        const scale: f32 = if (mantissa_bits == 6) 1.0 / 1_048_576.0 else 1.0 / 524_288.0;
        const subnormal_float = self.id();
        try self.emit(&self.body, 133, &.{
            self.float_type,
            subnormal_float,
            mantissa_float,
            try self.constant(.float32, @bitCast(scale)),
        }); // OpFMul
        const subnormal = try self.convert(.{ .id = subnormal_float, .value_type = .float32 }, .bits32);
        const special = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, special, try self.constant(.bits32, 0x7f80_0000), fraction_bits });

        const exponent_is_zero = self.id();
        try self.emit(&self.body, 170, &.{ self.bool_type, exponent_is_zero, exponent, try self.constant(.bits32, 0) });
        const finite = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, finite, exponent_is_zero, subnormal, normal });
        const exponent_is_special = self.id();
        try self.emit(&self.body, 170, &.{ self.bool_type, exponent_is_special, exponent, try self.constant(.bits32, 31) });
        const result = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, result, exponent_is_special, special, finite });
        return result;
    }

    fn convertFormattedBufferComponent(
        self: *Builder,
        raw: u32,
        layout: BufferComponentLayout,
        format: BufferFormat,
    ) Error!u32 {
        const unsigned_max: u32 = if (layout.bit_count == 32)
            0xffff_ffff
        else
            (@as(u32, 1) << @intCast(layout.bit_count)) - 1;
        const signed_bits = try self.signExtendBits(raw, layout.bit_count);
        return switch (format.number) {
            0 => blk: { // UNORM
                const value = try self.divideFloat(
                    try self.unsignedBitsToFloat(raw),
                    @floatFromInt(unsigned_max),
                );
                break :blk try self.convert(.{ .id = value, .value_type = .float32 }, .bits32);
            },
            1 => blk: { // SNORM
                const signed_max: u32 = unsigned_max >> 1;
                const normalized = try self.divideFloat(
                    try self.signedBitsToFloat(signed_bits),
                    @floatFromInt(signed_max),
                );
                const clamped = try self.glslBinaryValue(
                    40,
                    .float32,
                    normalized,
                    try self.constant(.float32, @bitCast(@as(f32, -1.0))),
                ); // FMax
                break :blk try self.convert(.{ .id = clamped, .value_type = .float32 }, .bits32);
            },
            2 => blk: { // USCALED
                const value = try self.unsignedBitsToFloat(raw);
                break :blk try self.convert(.{ .id = value, .value_type = .float32 }, .bits32);
            },
            3 => blk: { // SSCALED
                const value = try self.signedBitsToFloat(signed_bits);
                break :blk try self.convert(.{ .id = value, .value_type = .float32 }, .bits32);
            },
            4 => raw, // UINT
            5 => signed_bits, // SINT
            7 => blk: { // FLOAT
                if (format.data == 6 or format.data == 7) {
                    break :blk try self.decodeUnsignedMiniFloat(raw, layout.bit_count);
                }
                if (layout.bit_count == 16) {
                    const vector_type = try self.ensureFloatVec2();
                    const unpacked = self.id();
                    try self.emit(&self.body, 12, &.{
                        vector_type,
                        unpacked,
                        self.ensureGlslStd450(),
                        62, // UnpackHalf2x16
                        raw,
                    });
                    const value = self.id();
                    try self.emit(&self.body, 81, &.{ self.float_type, value, unpacked, 0 });
                    break :blk try self.convert(.{ .id = value, .value_type = .float32 }, .bits32);
                }
                break :blk raw;
            },
            else => raw,
        };
    }

    fn loadFormattedBufferComponent(
        self: *Builder,
        element_address: BufferAddress,
        layout: BufferComponentLayout,
        format: BufferFormat,
    ) Error!u32 {
        const component_address = try self.bufferAddressAdd(element_address, layout.byte_offset);
        var raw = try self.loadUnalignedBufferWord(component_address);
        if (layout.bit_offset != 0) raw = try self.shiftRightBits(raw, layout.bit_offset);
        if (layout.bit_count != 32) {
            const mask = (@as(u32, 1) << @intCast(layout.bit_count)) - 1;
            raw = try self.andBits(raw, mask);
        }
        return self.convertFormattedBufferComponent(raw, layout, format);
    }

    fn bufferLoadFormat(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        if (!try self.hasBufferStorage(inst)) {
            const zero = try self.constant(.bits32, 0);
            for (0..count) |destination_index| {
                try self.destination(try consecutiveRegister(inst.dst, @intCast(destination_index)), .{
                    .id = zero,
                    .value_type = .bits32,
                });
            }
            return;
        }
        const binding = self.storageBinding(inst.src1.reg, inst.pc) orelse return Error.InvalidStorageBinding;
        const format = decodeBufferUnifiedFormat(binding.unified_format) orelse {
            try self.bufferLoadWords(inst, count);
            return;
        };
        // FORMAT=0 is invalid/null. Preserve the former raw-dword behaviour
        // for callers that have not captured descriptor format metadata yet.
        if (format.data == 0) {
            try self.bufferLoadWords(inst, count);
            return;
        }

        const element_address = try self.bufferAddress(inst);
        const one_bits: u32 = if (format.number == 4 or format.number == 5)
            1
        else
            @bitCast(@as(f32, 1.0));
        var canonical: [4]u32 = undefined;
        for (&canonical, 0..) |*value, component| {
            value.* = if (bufferComponentLayout(format.data, @intCast(component))) |layout|
                try self.loadFormattedBufferComponent(element_address, layout, format)
            else
                try self.constant(.bits32, if (component == 3) one_bits else 0);
        }

        for (0..count) |destination_index| {
            const selector = binding.dst_select[destination_index];
            const value = switch (selector) {
                0 => try self.constant(.bits32, 0),
                1 => try self.constant(.bits32, one_bits),
                4...7 => canonical[selector - 4],
                else => try self.constant(.bits32, 0),
            };
            try self.destination(try consecutiveRegister(inst.dst, @intCast(destination_index)), .{
                .id = value,
                .value_type = .bits32,
            });
        }
    }

    fn bufferLoadSubword(self: *Builder, inst: instruction.Instruction, width: u8, signed: bool) Error!void {
        if (!try self.hasBufferStorage(inst)) {
            try self.destination(inst.dst, .{
                .id = try self.constant(.bits32, 0),
                .value_type = .bits32,
            });
            return;
        }
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
        if (!try self.hasBufferStorage(inst)) return;
        const value = try self.source(inst.dst, .bits32);
        try self.storeBufferByte(try self.bufferAddress(inst), value);
        if (width == 16) {
            try self.storeBufferByte(
                try self.bufferAddressDelta(inst, 1),
                try self.shiftRightBits(value, 8),
            );
        }
    }

    fn lowerSpecializedScalarDestination(self: *Builder, inst: instruction.Instruction) Error!bool {
        if (inst.pc >= self.specialized_scalar_prefix_end or
            inst.family != .smem)
        {
            return false;
        }

        // Multi-dword SMEM writes may only be replaced when every destination
        // word was recovered from this exact instruction. A final register
        // snapshot is not sufficient: Unity NGG prologs repeatedly reuse the
        // same SGPR window for unrelated descriptors and matrices.
        const word_count: usize = @max(inst.data_words, 1);
        const first = registerIndex(inst.dst) orelse return false;
        if (first + word_count > 128) return false;
        var values: [16]u32 = @splat(0);
        var specialization_indices: [16]usize = @splat(0);
        if (word_count > values.len) return false;
        for (0..word_count) |word_index| {
            const register: u32 = @intCast(first + word_index);
            var found = false;
            for (self.scalar_specializations, 0..) |scalar, specialization_index| {
                if (scalar.producer_pc == inst.pc and scalar.register == register) {
                    values[word_index] = scalar.value;
                    specialization_indices[word_index] = specialization_index;
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        for (0..word_count) |word_index| {
            try self.destination(try consecutiveRegister(inst.dst, @intCast(word_index)), .{
                .id = if (self.dynamic_scalar_binding != null)
                    try self.dynamicScalar(specialization_indices[word_index])
                else
                    try self.constant(.bits32, values[word_index]),
                .value_type = .bits32,
            });
        }
        return true;
    }

    /// Takes a write to the execution mask, and says whether it did.
    ///
    /// Only the plain move is taken. The read-modify-write forms that fold a
    /// comparison into the mask carry a scalar result as well, and answering
    /// half of one would leave the shader believing a value it never received.
    fn lowerExecutionMask(self: *Builder, inst: instruction.Instruction) Error!bool {
        if (inst.dst.kind != .exec_lo) return false;
        // CMPX is a vector comparison whose destination is EXEC. Lower it like
        // the matching V_CMP operation so EXECZ/EXECNZ branches can consume the
        // per-invocation predicate in structured SPIR-V.
        if (inst.family == .vopc or inst.family == .vop3) return self.stage != .fragment;
        // Only plain s_mov_b64 is modelled; other exec updates are ignored so
        // vertex/pixel translation can continue during bring-up.
        if (inst.opcode != .s_mov_b64) return true;

        // Pixel prologs may restore EXEC from a hardware-provided SGPR pair
        // which is not part of USER_DATA. Vulkan has already selected the live
        // fragment invocations, so an unavailable snapshot means "keep the
        // current host mask", not "reject the shader". Known compute masks
        // still take the exact lowering below for guarded buffer accesses.
        if (inst.src0.kind == .sgpr) {
            const low_index = registerIndex(inst.src0) orelse return true;
            if (low_index + 1 >= self.registers.len or
                self.registers[low_index].id == 0 or
                self.registers[low_index + 1].id == 0)
            {
                return true;
            }
        }

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
        try self.destinationPair(inst.dst, .{ low, high });
        return true;
    }

    fn nonExecCompareOpcode(opcode: isa.Opcode) ?isa.Opcode {
        return switch (opcode) {
            .v_cmpx_f_f32 => .v_cmp_f_f32,
            .v_cmpx_lt_f32 => .v_cmp_lt_f32,
            .v_cmpx_eq_f32 => .v_cmp_eq_f32,
            .v_cmpx_le_f32 => .v_cmp_le_f32,
            .v_cmpx_gt_f32 => .v_cmp_gt_f32,
            .v_cmpx_lg_f32 => .v_cmp_lg_f32,
            .v_cmpx_ge_f32 => .v_cmp_ge_f32,
            .v_cmpx_o_f32 => .v_cmp_o_f32,
            .v_cmpx_u_f32 => .v_cmp_u_f32,
            .v_cmpx_nge_f32 => .v_cmp_nge_f32,
            .v_cmpx_nlg_f32 => .v_cmp_nlg_f32,
            .v_cmpx_ngt_f32 => .v_cmp_ngt_f32,
            .v_cmpx_nle_f32 => .v_cmp_nle_f32,
            .v_cmpx_neq_f32 => .v_cmp_neq_f32,
            .v_cmpx_nlt_f32 => .v_cmp_nlt_f32,
            .v_cmpx_tru_f32 => .v_cmp_tru_f32,
            .v_cmpx_lt_i32 => .v_cmp_lt_i32,
            .v_cmpx_eq_i32 => .v_cmp_eq_i32,
            .v_cmpx_le_i32 => .v_cmp_le_i32,
            .v_cmpx_gt_i32 => .v_cmp_gt_i32,
            .v_cmpx_ne_i32 => .v_cmp_ne_i32,
            .v_cmpx_ge_i32 => .v_cmp_ge_i32,
            .v_cmpx_lt_u32 => .v_cmp_lt_u32,
            .v_cmpx_eq_u32 => .v_cmp_eq_u32,
            .v_cmpx_le_u32 => .v_cmp_le_u32,
            .v_cmpx_gt_u32 => .v_cmp_gt_u32,
            .v_cmpx_ne_u32 => .v_cmp_ne_u32,
            .v_cmpx_ge_u32 => .v_cmp_ge_u32,
            else => null,
        };
    }

    fn snapshot(self: *const Builder) State {
        return .{
            .registers = self.registers,
            .scc = self.scc,
            .arithmetic_carry = self.arithmetic_carry,
            .valid = true,
        };
    }

    fn restore(self: *Builder, state: State) void {
        self.registers = state.registers;
        self.scc = state.scc;
        self.arithmetic_carry = state.arithmetic_carry;
    }

    fn lower(self: *Builder, source_inst: instruction.Instruction) Error!void {
        var inst = source_inst;
        if (self.stage == .fragment) {
            if (nonExecCompareOpcode(inst.opcode)) |opcode| inst.opcode = opcode;
        }
        if (try self.lowerExecutionMask(inst)) return;
        if (try self.lowerSpecializedScalarDestination(inst)) return;
        // M0 only feeds hardware interpolation/LDS addressing. Those paths
        // are represented by host built-ins or dedicated lowering below, so
        // copying an unavailable hardware SGPR into M0 must not reject the
        // entire shader merely to produce a value nobody subsequently reads.
        if (inst.dst.kind == .m0) return;
        switch (inst.opcode) {
            .s_nop, .s_waitcnt, .s_inst_prefetch, .s_sendmsg, .s_sleep, .s_ttrace_data, .v_nop, .s_endpgm, .s_code_end, .s_wqm_b64 => {},
            .s_barrier => try self.controlBarrier(),
            // Branches are handled by structured CF or skipped in the linear fallback.
            .s_branch, .s_cbranch_scc0, .s_cbranch_scc1, .s_cbranch_vccz, .s_cbranch_vccnz, .s_cbranch_execz, .s_cbranch_execnz => {},
            .s_setpc_b64 => try self.exportNggLdsRecord(),
            .s_mov_b32, .s_movk_i32, .v_mov_b32 => try self.unary(inst, 83, .bits32), // OpCopyObject
            .v_readfirstlane_b32 => try self.readFirstLane(inst),
            .s_mov_b64 => try self.mov64(inst),
            .s_getpc_b64 => try self.getPcFallback(inst),
            .s_not_b64 => try self.not64(inst),
            .s_and_b64,
            .s_or_b64,
            .s_xor_b64,
            .s_andn2_b64,
            .s_orn2_b64,
            .s_nand_b64,
            .s_nor_b64,
            .s_xnor_b64,
            => try self.bitwise64(inst, inst.opcode),
            .s_cselect_b32 => try self.cselect32(inst),
            .s_cselect_b64 => try self.cselect64(inst),
            .s_and_saveexec_b64 => try self.andSaveExec64(inst),
            .v_cndmask_b32 => try self.cndmask(inst),
            .v_interp_p1_f32, .v_interp_p2_f32, .v_interp_mov_f32 => try self.interpolateParameter(inst),
            .v_cvt_f32_i32 => try self.integerToFloat(inst, true),
            .v_cvt_f32_u32 => try self.integerToFloat(inst, false),
            .v_cvt_i32_f32 => try self.floatToInteger(inst, true),
            .v_cvt_u32_f32 => try self.floatToInteger(inst, false),
            .v_cvt_flr_i32_f32 => try self.floatFloorToSignedInteger(inst),
            // Pack two f32 → two f16 in one dword (Unity PS export path).
            .v_cvt_pkrtz_f16_f32 => try self.packHalf2x16(inst),
            .s_add_u32 => try self.scalarAddUnsigned(inst, false),
            .s_addc_u32 => try self.scalarAddUnsigned(inst, true),
            .v_addc_u32 => try self.vectorAddCarry(inst),
            .s_add_i32, .v_add_nc_u32 => try self.binary(inst, 128, .bits32, false), // OpIAdd
            .v_lshl_add_u32 => try self.shiftLeftAdd(inst),
            // dst = (src0 + src1) << (src2 & 31)
            .v_add_lshl_u32 => try self.addShiftLeft(inst),
            .s_lshl1_add_u32 => try self.fixedShiftLeftAdd(inst, 1),
            .s_lshl2_add_u32 => try self.fixedShiftLeftAdd(inst, 2),
            .s_lshl3_add_u32 => try self.fixedShiftLeftAdd(inst, 3),
            .s_lshl4_add_u32 => try self.fixedShiftLeftAdd(inst, 4),
            // Bitfield mask: dst = (((1 << (src0 & 31)) - 1) << (src1 & 31)).
            .s_bfm_b32 => try self.bitfieldMask(inst),
            // Scalar BFE packs offset/width in src1; vector BFE uses src1/src2.
            .s_bfe_u32 => try self.scalarBitfieldExtract(inst),
            .v_bfe_u32 => try self.bitfieldExtract(inst, false),
            .v_bfe_i32 => try self.bitfieldExtract(inst, true),
            .s_bfe_u64 => try self.scalarBitfieldExtract64(inst),
            // Ternary packing helpers used heavily by Unity compute kernels.
            .v_and_or_b32 => try self.andOr(inst),
            .v_bfi_b32 => try self.bitfieldInsert(inst),
            .v_or3_b32 => try self.ternaryBits(inst, 197, 197), // (a|b)|c
            .v_xor3_b32 => try self.ternaryBits(inst, 198, 198), // (a^b)^c
            .v_xad_u32 => try self.ternaryBits(inst, 198, 128), // (a^b)+c
            .v_add3_u32 => try self.ternaryBits(inst, 128, 128), // (a+b)+c
            .v_sad_u32 => try self.sadUnsigned(inst),
            .v_lshl_or_b32 => try self.shiftLeftOr(inst),
            .s_sub_u32, .s_sub_i32, .v_sub_nc_u32 => try self.binary(inst, 130, .bits32, false), // OpISub
            .v_subrev_nc_u32 => try self.binary(inst, 130, .bits32, true),
            .v_add_f32 => try self.binary(inst, 129, .float32, false), // OpFAdd
            .v_sub_f32 => try self.binary(inst, 131, .float32, false), // OpFSub
            .v_subrev_f32 => try self.binary(inst, 131, .float32, true),
            .v_mul_f32 => try self.binary(inst, 133, .float32, false), // OpFMul
            .v_mul_i32_i24 => try self.multiply24(inst, true),
            .v_mul_u32_u24 => try self.multiply24(inst, false),
            .v_mad_f32, .v_madmk_f32, .v_madak_f32 => try self.madFloat(inst),
            .v_fma_f32 => try self.fmaFloat(inst),
            .v_cubeid_f32, .v_cubesc_f32, .v_cubetc_f32, .v_cubema_f32 => try self.cubeFloat(inst),
            .v_mac_f32 => try self.macFloat(inst),
            .v_min_f32 => try self.glslBinary(inst, 37, .float32), // FMin
            .s_min_u32 => try self.scalarMinMax(inst, 38, .bits32, 176), // UMin, OpULessThan
            .s_min_i32 => try self.scalarMinMax(inst, 39, .sint32, 177), // SMin, OpSLessThan
            .s_max_u32 => try self.scalarMinMax(inst, 41, .bits32, 172), // UMax, OpUGreaterThan
            .s_max_i32 => try self.scalarMinMax(inst, 42, .sint32, 173), // SMax, OpSGreaterThan
            .v_min_u32 => try self.glslBinary(inst, 38, .bits32), // UMin
            .v_min_i32 => try self.glslBinary(inst, 39, .sint32), // SMin
            .v_max_f32 => try self.glslBinary(inst, 40, .float32), // FMax
            .v_max_u32 => try self.glslBinary(inst, 41, .bits32), // UMax
            .v_max_i32 => try self.glslBinary(inst, 42, .sint32), // SMax
            .v_min3_f32, .v_max3_f32, .v_med3_f32 => try self.minMax3Float(inst, inst.opcode),
            .v_rcp_f32 => try self.reciprocalFloat(inst),
            .v_ldexp_f32 => try self.ldexpFloat(inst),
            .v_rndne_f32 => try self.glslFloatUnary(inst, 2), // RoundEven
            .v_trunc_f32 => try self.glslFloatUnary(inst, 3),
            .v_floor_f32 => try self.glslFloatUnary(inst, 8),
            .v_ceil_f32 => try self.glslFloatUnary(inst, 9),
            .v_fract_f32 => try self.glslFloatUnary(inst, 10),
            .v_sin_f32 => try self.glslFloatUnary(inst, 13),
            .v_cos_f32 => try self.glslFloatUnary(inst, 14),
            .v_exp_f32 => try self.glslFloatUnary(inst, 29), // Exp2
            .v_log_f32 => try self.glslFloatUnary(inst, 30), // Log2
            .v_sqrt_f32 => try self.glslFloatUnary(inst, 31),
            .v_rsq_f32 => try self.glslFloatUnary(inst, 32), // InverseSqrt
            .s_lshr_b32, .v_lshr_b32 => try self.binary(inst, 194, .bits32, false), // OpShiftRightLogical
            .v_lshrrev_b32 => try self.binary(inst, 194, .bits32, true),
            .s_ashr_i32, .v_ashr_i32 => try self.binary(inst, 195, .sint32, false), // OpShiftRightArithmetic
            .v_ashrrev_i32 => try self.binary(inst, 195, .sint32, true),
            .s_lshl_b32, .v_lshl_b32 => try self.binary(inst, 196, .bits32, false), // OpShiftLeftLogical
            .v_lshlrev_b32 => try self.binary(inst, 196, .bits32, true),
            .s_mul_i32, .v_mul_lo_u32 => try self.binary(inst, 132, .bits32, false), // OpIMul
            .s_mul_hi_u32, .v_mul_hi_u32 => try self.multiplyHighUnsigned(inst),
            .v_mul_hi_i32 => try self.multiplyHighSigned(inst),
            .s_and_b32, .v_and_b32 => try self.binary(inst, 199, .bits32, false),
            .s_or_b32, .v_or_b32 => try self.binary(inst, 197, .bits32, false),
            .s_xor_b32, .v_xor_b32 => try self.binary(inst, 198, .bits32, false),
            .s_not_b32, .v_not_b32 => try self.unary(inst, 200, .bits32), // OpNot
            .s_brev_b32 => try self.unary(inst, 204, .bits32), // OpBitReverse
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
            .v_cmp_f_f32 => try self.vectorConstantComparison(inst, false),
            .v_cmp_lt_f32 => try self.vectorComparison(inst, 184, .float32), // OpFOrdLessThan
            .v_cmp_eq_f32 => try self.vectorComparison(inst, 180, .float32), // OpFOrdEqual
            .v_cmp_le_f32 => try self.vectorComparison(inst, 188, .float32), // OpFOrdLessThanEqual
            .v_cmp_gt_f32 => try self.vectorComparison(inst, 186, .float32), // OpFOrdGreaterThan
            .v_cmp_lg_f32 => try self.vectorComparison(inst, 182, .float32), // OpFOrdNotEqual
            .v_cmp_ge_f32 => try self.vectorComparison(inst, 190, .float32), // OpFOrdGreaterThanEqual
            .v_cmp_o_f32 => try self.vectorOrderedComparison(inst, false),
            .v_cmp_u_f32 => try self.vectorOrderedComparison(inst, true),
            .v_cmp_nge_f32 => try self.vectorComparison(inst, 185, .float32), // OpFUnordLessThan
            .v_cmp_nlg_f32 => try self.vectorComparison(inst, 181, .float32), // OpFUnordEqual
            .v_cmp_ngt_f32 => try self.vectorComparison(inst, 189, .float32), // OpFUnordLessThanEqual
            .v_cmp_nle_f32 => try self.vectorComparison(inst, 187, .float32), // OpFUnordGreaterThan
            .v_cmp_neq_f32 => try self.vectorComparison(inst, 183, .float32), // OpFUnordNotEqual
            .v_cmp_nlt_f32 => try self.vectorComparison(inst, 191, .float32), // OpFUnordGreaterThanEqual
            .v_cmp_tru_f32 => try self.vectorConstantComparison(inst, true),
            .v_cmp_lt_i32 => try self.vectorComparison(inst, 177, .sint32),
            .v_cmp_eq_i32 => try self.vectorComparison(inst, 170, .sint32),
            .v_cmp_le_i32 => try self.vectorComparison(inst, 179, .sint32),
            .v_cmp_gt_i32 => try self.vectorComparison(inst, 173, .sint32),
            .v_cmp_ne_i32 => try self.vectorComparison(inst, 171, .sint32),
            .v_cmp_ge_i32 => try self.vectorComparison(inst, 175, .sint32),
            .v_cmp_lt_u32 => try self.vectorComparison(inst, 176, .bits32),
            .v_cmp_eq_u32 => try self.vectorComparison(inst, 170, .bits32),
            .v_cmp_le_u32 => try self.vectorComparison(inst, 178, .bits32),
            .v_cmp_gt_u32 => try self.vectorComparison(inst, 172, .bits32),
            .v_cmp_ne_u32 => try self.vectorComparison(inst, 171, .bits32),
            .v_cmp_ge_u32 => try self.vectorComparison(inst, 174, .bits32),
            .buffer_load_ubyte => try self.bufferLoadSubword(inst, 8, false),
            .buffer_load_sbyte => try self.bufferLoadSubword(inst, 8, true),
            .buffer_load_ushort => try self.bufferLoadSubword(inst, 16, false),
            .buffer_load_sshort => try self.bufferLoadSubword(inst, 16, true),
            .buffer_load_dword,
            => try self.bufferLoadWords(inst, 1),
            .buffer_load_dwordx2,
            => try self.bufferLoadWords(inst, 2),
            .buffer_load_dwordx3,
            => try self.bufferLoadWords(inst, 3),
            .buffer_load_dwordx4,
            => try self.bufferLoadWords(inst, 4),
            .buffer_load_format_x,
            .tbuffer_load_format_x,
            => try self.bufferLoadFormat(inst, 1),
            .buffer_load_format_xy,
            .tbuffer_load_format_xy,
            => try self.bufferLoadFormat(inst, 2),
            .buffer_load_format_xyz,
            .tbuffer_load_format_xyz,
            => try self.bufferLoadFormat(inst, 3),
            .buffer_load_format_xyzw,
            .tbuffer_load_format_xyzw,
            => try self.bufferLoadFormat(inst, 4),
            .s_buffer_load_dword => try self.scalarBufferLoadWords(inst, 1),
            .s_buffer_load_dwordx2 => try self.scalarBufferLoadWords(inst, 2),
            .s_buffer_load_dwordx4 => try self.scalarBufferLoadWords(inst, 4),
            .s_buffer_load_dwordx8 => try self.scalarBufferLoadWords(inst, 8),
            .s_buffer_load_dwordx16 => try self.scalarBufferLoadWords(inst, 16),
            // Pointer-form SMEM is expected to be specialized away; if not,
            // leave destination zero rather than aborting the shader.
            .s_load_dword, .s_load_dwordx2, .s_load_dwordx4, .s_load_dwordx8, .s_load_dwordx16 => {
                if (inst.dst.kind == .sgpr) {
                    var i: u8 = 0;
                    while (i < inst.data_words) : (i += 1) {
                        var dest = inst.dst;
                        dest.reg += i;
                        try self.destination(dest, .{
                            .id = try self.constant(.bits32, 0),
                            .value_type = .bits32,
                        });
                    }
                }
            },
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
            .ds_write_b32 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWriteWords(inst, 1),
            .ds_write2_b32 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWritePair(inst),
            .ds_write_b64 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWriteWords(inst, 2),
            .ds_write_b96 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWriteWords(inst, 3),
            .ds_write_b128 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWriteWords(inst, 4),
            .ds_read_b32 => try self.dsReadWords(inst, 1),
            .ds_read2_b32 => try self.dsReadPair(inst),
            .ds_read_b64 => try self.dsReadWords(inst, 2),
            .ds_read_b96 => try self.dsReadWords(inst, 3),
            .ds_read_b128 => try self.dsReadWords(inst, 4),
            .ds_read_ubyte => try self.dsReadSubword(inst, 8, false),
            .ds_read_sbyte => try self.dsReadSubword(inst, 8, true),
            .ds_read_ushort => try self.dsReadSubword(inst, 16, false),
            .ds_read_sshort => try self.dsReadSubword(inst, 16, true),
            .ds_add_u32 => try self.dsAtomic(inst, 234),
            .ds_sub_u32 => try self.dsAtomic(inst, 235),
            .ds_min_i32 => try self.dsAtomic(inst, 236),
            .ds_min_u32 => try self.dsAtomic(inst, 237),
            .ds_max_i32 => try self.dsAtomic(inst, 238),
            .ds_max_u32 => try self.dsAtomic(inst, 239),
            .ds_and_b32 => try self.dsAtomic(inst, 240),
            .ds_or_b32 => try self.dsAtomic(inst, 241),
            .ds_xor_b32 => try self.dsAtomic(inst, 242),
            .image_load => try self.imageLoad(inst),
            .image_store => try self.imageStore(inst),
            .image_sample => try self.sampleImage(inst),
            .image_gather4 => try self.gatherImage(inst),
            .exp => try self.exportValue(inst),
            else => return Error.UnsupportedOpcode,
        }
    }
};

fn lowerDiagnosed(builder: *Builder, inst: instruction.Instruction) Error!void {
    builder.lower(inst) catch |err| {
        // A program-level error name is not enough to distinguish a missing
        // opcode from a supported opcode whose particular encoding or stage is
        // not implemented. Shader analyses are cached, so this is emitted once
        // for the failed translation rather than once for every draw.
        std.debug.print(
            "[spirv] lowering failed pc=0x{x} opcode={s} id=0x{x}: {s}\n",
            .{ inst.pc, @tagName(inst.opcode), inst.opcode_id, @errorName(err) },
        );
        return err;
    };
}

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

fn falseCondition(builder: *Builder) Error!u32 {
    const result = builder.id();
    try builder.emit(&builder.body, 170, &.{
        builder.bool_type,
        result,
        try builder.constant(.bits32, 0),
        try builder.constant(.bits32, 1),
    }); // OpIEqual(false)
    return result;
}

fn structuredCondition(builder: *Builder, condition: control_flow.Condition) Error!u32 {
    return switch (condition) {
        .scc => if (builder.scc != 0) builder.scc else try falseCondition(builder),
        .vcc_zero, .exec_zero => blk: {
            // One Vulkan vertex/fragment invocation represents one active
            // RDNA lane, so its VCC/EXEC word is a valid per-invocation branch
            // predicate. Compute still needs a wave-wide ballot model: taking
            // this path there could send inactive lanes into buffer traffic.
            if (builder.stage == .compute) return Error.UnsupportedControlFlow;
            const index: usize = if (condition == .vcc_zero) 106 else 126;
            const mask = builder.registers[index];
            if (mask.id == 0) break :blk try falseCondition(builder);
            const zero = builder.id();
            try builder.emit(&builder.body, 170, &.{
                builder.bool_type,
                zero,
                try builder.convert(mask, .bits32),
                try builder.constant(.bits32, 0),
            }); // OpIEqual
            break :blk zero;
        },
        .none => return Error.UnsupportedControlFlow,
    };
}

fn mergeIncomingStates(builder: *Builder, incoming: []const State, parent_labels: []const u32) Error!State {
    if (incoming.len == 0 or incoming.len != parent_labels.len) return Error.UnsupportedControlFlow;
    for (incoming) |state| {
        if (!state.valid) return Error.UnsupportedControlFlow;
    }
    if (incoming.len == 1) return incoming[0];

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
        for (incoming, 0..) |state, index| {
            const value = state.registers[reg];
            if (value.id == 0) missing = true;
            if (index == 0) first = value else if (value.id != first.id) differs = true;
            try values.append(builder.allocator, value);
            try parents.append(builder.allocator, parent_labels[index]);
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
    for (incoming, 0..) |state, index| {
        const id = state.scc;
        if (id == 0) missing_scc = true;
        if (index == 0) first_scc = id else if (id != first_scc) different_scc = true;
        try values.append(builder.allocator, .{ .id = id, .value_type = .bits32 });
        try parents.append(builder.allocator, parent_labels[index]);
    }
    if (!missing_scc) {
        merged.scc = if (!different_scc)
            first_scc
        else
            try emitPhi(builder, builder.bool_type, values.items, parents.items);
    }

    values.clearRetainingCapacity();
    parents.clearRetainingCapacity();
    var missing_carry = false;
    var different_carry = false;
    var first_carry: u32 = 0;
    for (incoming, 0..) |state, index| {
        const id = state.arithmetic_carry;
        if (id == 0) missing_carry = true;
        if (index == 0) first_carry = id else if (id != first_carry) different_carry = true;
        try values.append(builder.allocator, .{ .id = id, .value_type = .bits32 });
        try parents.append(builder.allocator, parent_labels[index]);
    }
    if (!missing_carry) {
        merged.arithmetic_carry = if (!different_carry)
            first_carry
        else
            try emitPhi(builder, builder.bool_type, values.items, parents.items);
    }
    return merged;
}

fn mergeState(
    builder: *Builder,
    graph: *const control_flow.Graph,
    states: []const State,
    labels: []const u32,
    block: u32,
) Error!State {
    // Builder initialization owns the ABI inputs: specialized USER_DATA,
    // descriptors and any stage-provided registers. Starting the entry block
    // from an empty State discarded those values only for shaders with CFG,
    // so their first scalar comparison failed with UndefinedRegister even
    // though the caller had supplied the SGPR.
    if (block == 0) return builder.snapshot();
    var incoming: std.ArrayList(State) = .empty;
    defer incoming.deinit(builder.allocator);
    var parents: std.ArrayList(u32) = .empty;
    defer parents.deinit(builder.allocator);
    for (graph.edges.items) |edge| {
        if (edge.to != block) continue;
        if (edge.from >= block or !states[edge.from].valid) return Error.UnsupportedControlFlow;
        try incoming.append(builder.allocator, states[edge.from]);
        try parents.append(builder.allocator, labels[edge.from]);
    }
    return mergeIncomingStates(builder, incoming.items, parents.items);
}

fn buildDominators(builder: *Builder, graph: *const control_flow.Graph) Error![]bool {
    const block_count = graph.blocks.items.len;
    const dominators = try builder.allocator.alloc(bool, block_count * block_count);
    @memset(dominators, false);
    if (block_count == 0) return dominators;
    dominators[0] = true;

    for (1..block_count) |block| {
        var saw_predecessor = false;
        for (graph.edges.items) |edge| {
            if (edge.to != block) continue;
            if (edge.from >= block) {
                builder.allocator.free(dominators);
                return Error.UnsupportedControlFlow;
            }
            const row = dominators[block * block_count ..][0..block_count];
            const predecessor_row = dominators[@as(usize, edge.from) * block_count ..][0..block_count];
            if (!saw_predecessor) {
                @memcpy(row, predecessor_row);
                saw_predecessor = true;
            } else {
                for (row, predecessor_row) |*value, predecessor_value| value.* = value.* and predecessor_value;
            }
        }
        if (!saw_predecessor) {
            builder.allocator.free(dominators);
            return Error.UnsupportedControlFlow;
        }
        dominators[block * block_count + block] = true;
    }
    return dominators;
}

fn blockDominates(dominators: []const bool, block_count: usize, dominator: u32, block: u32) bool {
    return dominators[@as(usize, block) * block_count + dominator];
}

fn structuredSelectionForEdge(
    graph: *const control_flow.Graph,
    dominators: []const bool,
    source: u32,
    target: u32,
) ?usize {
    const block_count = graph.blocks.items.len;
    var chosen: ?usize = null;
    for (graph.selections.items, 0..) |selection, index| {
        if (selection.merge != target or !blockDominates(dominators, block_count, selection.header, source)) continue;
        if (chosen == null or blockDominates(
            dominators,
            block_count,
            graph.selections.items[chosen.?].header,
            selection.header,
        )) chosen = index;
    }
    return chosen;
}

fn structuredEdgeLabel(
    graph: *const control_flow.Graph,
    dominators: []const bool,
    labels: []const u32,
    selection_merge_labels: []const u32,
    source: u32,
    target: u32,
) u32 {
    const selection = structuredSelectionForEdge(graph, dominators, source, target) orelse return labels[target];
    return selection_merge_labels[selection];
}

fn structuredSelectionIndex(graph: *const control_flow.Graph, header: u32) ?usize {
    for (graph.selections.items, 0..) |selection, index| {
        if (selection.header == header) return index;
    }
    return null;
}

fn structuredSelectionParent(
    graph: *const control_flow.Graph,
    dominators: []const bool,
    selection_index: usize,
) ?usize {
    const selection = graph.selections.items[selection_index];
    const block_count = graph.blocks.items.len;
    var parent: ?usize = null;
    for (graph.selections.items, 0..) |candidate, index| {
        if (index == selection_index or candidate.merge != selection.merge or
            !blockDominates(dominators, block_count, candidate.header, selection.header)) continue;
        if (parent == null or blockDominates(
            dominators,
            block_count,
            graph.selections.items[parent.?].header,
            candidate.header,
        )) parent = index;
    }
    return parent;
}

fn translateStructured(builder: *Builder, program: *const instruction.Program, graph: *const control_flow.Graph) Error!void {
    if (graph.back_edge_count != 0) return Error.UnsupportedControlFlow;
    const labels = try builder.allocator.alloc(u32, graph.blocks.items.len);
    defer builder.allocator.free(labels);
    labels[0] = builder.label;
    for (labels[1..]) |*label| label.* = builder.id();
    // SPIR-V forbids two selection headers from naming the same merge block.
    // Acyclic guest shaders commonly produce if/else-if ladders whose immediate
    // post-dominator is shared. Give every header a synthetic merge and chain
    // those blocks from the innermost (latest header) to the outermost.
    const selection_merge_labels = try builder.allocator.alloc(u32, graph.selections.items.len);
    defer builder.allocator.free(selection_merge_labels);
    for (selection_merge_labels) |*label| label.* = builder.id();
    const dominators = try buildDominators(builder, graph);
    defer builder.allocator.free(dominators);
    const states = try builder.allocator.alloc(State, graph.blocks.items.len);
    defer builder.allocator.free(states);
    @memset(states, State{});
    const selection_states = try builder.allocator.alloc(State, graph.selections.items.len);
    defer builder.allocator.free(selection_states);
    @memset(selection_states, State{});

    for (graph.blocks.items) |block| {
        var incoming: State = undefined;
        var has_selection_merge = false;
        for (graph.selections.items) |selection| {
            if (selection.merge == block.index) {
                has_selection_merge = true;
                break;
            }
        }
        if (has_selection_merge) {
            // Emit child merges before their parents. Each synthetic block only
            // receives original edges dominated by that selection plus the
            // completed states of its immediately nested selections.
            var index = graph.selections.items.len;
            while (index != 0) {
                index -= 1;
                if (graph.selections.items[index].merge != block.index) continue;
                try builder.emit(&builder.body, 248, &.{selection_merge_labels[index]}); // OpLabel

                var merge_incoming: std.ArrayList(State) = .empty;
                defer merge_incoming.deinit(builder.allocator);
                var merge_parents: std.ArrayList(u32) = .empty;
                defer merge_parents.deinit(builder.allocator);
                for (graph.edges.items) |edge| {
                    if (edge.to != block.index) continue;
                    const owner = structuredSelectionForEdge(graph, dominators, edge.from, block.index) orelse continue;
                    if (owner != index or !states[edge.from].valid) continue;
                    try merge_incoming.append(builder.allocator, states[edge.from]);
                    try merge_parents.append(builder.allocator, labels[edge.from]);
                }
                for (graph.selections.items, 0..) |candidate, child_index| {
                    if (candidate.merge != block.index) continue;
                    if (structuredSelectionParent(graph, dominators, child_index) != index) continue;
                    if (!selection_states[child_index].valid) return Error.UnsupportedControlFlow;
                    try merge_incoming.append(builder.allocator, selection_states[child_index]);
                    try merge_parents.append(builder.allocator, selection_merge_labels[child_index]);
                }
                const merged = try mergeIncomingStates(builder, merge_incoming.items, merge_parents.items);
                builder.restore(merged);
                selection_states[index] = merged;
                const parent_label = if (structuredSelectionParent(graph, dominators, index)) |parent|
                    selection_merge_labels[parent]
                else
                    labels[block.index];
                try builder.emit(&builder.body, 249, &.{parent_label}); // OpBranch
            }

            try builder.emit(&builder.body, 248, &.{labels[block.index]}); // OpLabel
            var block_incoming: std.ArrayList(State) = .empty;
            defer block_incoming.deinit(builder.allocator);
            var block_parents: std.ArrayList(u32) = .empty;
            defer block_parents.deinit(builder.allocator);
            for (graph.edges.items) |edge| {
                if (edge.to != block.index or
                    structuredSelectionForEdge(graph, dominators, edge.from, block.index) != null) continue;
                if (!states[edge.from].valid) return Error.UnsupportedControlFlow;
                try block_incoming.append(builder.allocator, states[edge.from]);
                try block_parents.append(builder.allocator, labels[edge.from]);
            }
            for (graph.selections.items, 0..) |selection, selection_index| {
                if (selection.merge != block.index or
                    structuredSelectionParent(graph, dominators, selection_index) != null) continue;
                if (!selection_states[selection_index].valid) return Error.UnsupportedControlFlow;
                try block_incoming.append(builder.allocator, selection_states[selection_index]);
                try block_parents.append(builder.allocator, selection_merge_labels[selection_index]);
            }
            incoming = try mergeIncomingStates(builder, block_incoming.items, block_parents.items);
        } else {
            try builder.emit(&builder.body, 248, &.{labels[block.index]}); // OpLabel
            incoming = try mergeState(builder, graph, states, labels, block.index);
        }
        builder.restore(incoming);
        if (block.index == 0) try builder.initializeStageInputs();

        const first: usize = block.first_instruction;
        const end: usize = first + block.instruction_count;
        const last = program.instructions.items[end - 1];
        for (program.instructions.items[first..end]) |inst| {
            if (inst.opcode.isBranch() or inst.opcode.isProgramEnd() or inst.opcode == .s_setpc_b64) continue;
            try lowerDiagnosed(builder, inst);
        }
        states[block.index] = builder.snapshot();

        if (last.opcode.isProgramEnd()) {
            try builder.emit(&builder.body, 253, &.{}); // OpReturn
        } else if (last.opcode == .s_setpc_b64) {
            try builder.exportNggLdsRecord();
            try builder.emit(&builder.body, 253, &.{}); // hardware NGG continuation becomes the stage return
        } else if (last.opcode == .s_branch) {
            const target = graph.blockForPc(last.branch_target) orelse return Error.UnsupportedControlFlow;
            try builder.emit(&builder.body, 249, &.{structuredEdgeLabel(
                graph,
                dominators,
                labels,
                selection_merge_labels,
                block.index,
                target,
            )}); // OpBranch
        } else if (last.opcode.isBranch()) {
            const selection_index = structuredSelectionIndex(graph, block.index) orelse return Error.UnsupportedControlFlow;
            const selection = graph.selections.items[selection_index];
            var condition = try structuredCondition(builder, selection.condition);
            if (!selection.branch_when) {
                const inverted = builder.id();
                try builder.emit(&builder.body, 168, &.{ builder.bool_type, inverted, condition }); // OpLogicalNot
                condition = inverted;
            }
            try builder.emit(&builder.body, 247, &.{ selection_merge_labels[selection_index], 0 }); // OpSelectionMerge
            try builder.emit(&builder.body, 250, &.{
                condition,
                structuredEdgeLabel(graph, dominators, labels, selection_merge_labels, block.index, selection.branch_successor),
                structuredEdgeLabel(graph, dominators, labels, selection_merge_labels, block.index, selection.fallthrough_successor),
            });
        } else if (block.index + 1 < graph.blocks.items.len) {
            try builder.emit(&builder.body, 249, &.{structuredEdgeLabel(
                graph,
                dominators,
                labels,
                selection_merge_labels,
                block.index,
                block.index + 1,
            )});
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
    try appendInstruction(allocator, &words, 17, &.{1}); // OpCapability Shader
    try appendInstruction(allocator, &words, 17, &.{61}); // OpCapability GroupNonUniform
    try appendInstruction(allocator, &words, 17, &.{64}); // OpCapability GroupNonUniformShuffle
    // ExtInstImport must precede OpMemoryModel when PackHalf2x16 (etc.) is used.
    if (builder.glsl_std_450 != 0) {
        // "GLSL.std.450" null-terminated, padded to 4-word alignment.
        try appendInstruction(allocator, &words, 11, &.{
            builder.glsl_std_450,
            0x4c53_4c47, // 'GLSL'
            0x6474_732e, // '.std'
            0x3035_342e, // '.450'
            0x0000_0000, // NUL pad
        });
    }
    try appendInstruction(allocator, &words, 14, &.{ 0, 1 }); // OpMemoryModel Logical GLSL450
    var entry_point: std.ArrayList(u32) = .empty;
    defer entry_point.deinit(allocator);
    try entry_point.appendSlice(allocator, &.{ @intFromEnum(options.stage), builder.main_function, 0x6e69_616d, 0 });
    if (builder.storage_array != 0) try entry_point.append(allocator, builder.storage_array);
    if (builder.scalar_buffer != 0) try entry_point.append(allocator, builder.scalar_buffer);
    for (builder.sampled_image_arrays) |sampled_image_array| {
        if (sampled_image_array != 0) try entry_point.append(allocator, sampled_image_array);
    }
    for (builder.storage_image_variables) |variable| {
        if (variable != 0) try entry_point.append(allocator, variable);
    }
    if (builder.local_invocation_index != 0) try entry_point.append(allocator, builder.local_invocation_index);
    if (builder.workgroup_id_input != 0) try entry_point.append(allocator, builder.workgroup_id_input);
    if (builder.local_invocation_id_input != 0) try entry_point.append(allocator, builder.local_invocation_id_input);
    if (builder.vertex_index_input != 0) try entry_point.append(allocator, builder.vertex_index_input);
    if (builder.instance_index_input != 0) try entry_point.append(allocator, builder.instance_index_input);
    if (builder.frag_coord_input != 0) try entry_point.append(allocator, builder.frag_coord_input);
    if (builder.position_output != 0) try entry_point.append(allocator, builder.position_output);
    if (builder.color_output != 0) try entry_point.append(allocator, builder.color_output);
    for (builder.parameter_variables) |variable| {
        if (variable != 0) try entry_point.append(allocator, variable);
    }
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
    return .{
        .words = try words.toOwnedSlice(allocator),
        .used_control_flow_fallback = builder.used_control_flow_fallback,
    };
}

/// Translates the executable ALU/SDWA subset and forward scalar selections.
/// The writer fails explicitly for operations or control-flow shapes whose
/// semantics are not implemented; it never emits a placeholder guest shader.
pub fn translate(allocator: std.mem.Allocator, program: *const instruction.Program, options: Options) Error!Module {
    var effective = options;
    for (effective.ngg_lds_exports) |ngg_export| {
        if (effective.stage == .vertex and ngg_export.target >= 0x20 and ngg_export.target < 0x40) {
            effective.parameter_mask |= @as(u32, 1) << @intCast(ngg_export.target - 0x20);
        }
    }
    for (program.instructions.items) |candidate| {
        if (candidate.dst.kind == .exec_lo) effective.uses_execution_mask = true;
        switch (effective.stage) {
            .vertex => if (candidate.opcode == .exp and candidate.export_target >= 0x20) {
                effective.parameter_mask |= @as(u32, 1) << @intCast(candidate.export_target - 0x20);
            },
            .fragment => if (effective.infer_fragment_parameter_mask) switch (candidate.opcode) {
                .v_interp_p1_f32, .v_interp_p2_f32, .v_interp_mov_f32 => {
                    if (candidate.src1.kind == .integer_inline_constant and candidate.src1.value < 32) {
                        effective.parameter_mask |= @as(u32, 1) << @intCast(candidate.src1.value);
                    }
                },
                else => {},
            },
            .compute => {},
        }
    }
    var builder = try Builder.init(allocator, effective);
    var builder_alive = true;
    defer if (builder_alive) builder.deinit();
    var graph = try control_flow.build(allocator, program);
    defer graph.deinit(allocator);
    if (graph.blocks.items.len == 1) {
        try builder.emit(&builder.body, 248, &.{builder.label});
        try builder.initializeStageInputs();
        for (program.instructions.items) |inst| try lowerDiagnosed(&builder, inst);
        try builder.emit(&builder.body, 253, &.{});
    } else {
        translateStructured(&builder, program, &graph) catch |err| {
            // Structured CF is incomplete. Fall back to a straight-line pass
            // that skips branches so vertex/pixel programs still produce SPIR-V
            // during bring-up (wrong for divergent paths, enough for a frame).
            if (err != Error.UnsupportedControlFlow) return err;
            if (!effective.allow_control_flow_fallback) return err;
            // Structured lowering may already have created labels, function
            // values and stage-input loads before discovering an unsupported
            // branch condition. Reusing that half-built Builder leaves the
            // linear body referring to IDs whose defining instructions were
            // cleared, which is invalid SPIR-V and can crash a driver during
            // pipeline compilation. Restart from the same immutable options.
            builder.deinit();
            builder_alive = false;
            builder = try Builder.init(allocator, effective);
            builder_alive = true;
            builder.used_control_flow_fallback = true;
            try builder.emit(&builder.body, 248, &.{builder.label});
            try builder.initializeStageInputs();
            for (program.instructions.items) |inst| {
                if (inst.opcode.isBranch()) continue;
                try lowerDiagnosed(&builder, inst);
            }
            try builder.emit(&builder.body, 253, &.{});
        };
    }
    return assemble(allocator, &builder, effective);
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

test "float transcendental VOP1 operations use explicit SPIR-V math" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 1.0)) },
        .src_count = 1,
    });
    inline for ([_]isa.Opcode{
        .v_rndne_f32, .v_trunc_f32, .v_floor_f32, .v_ceil_f32, .v_fract_f32,
        .v_sin_f32,   .v_cos_f32,   .v_exp_f32,   .v_log_f32,  .v_sqrt_f32,
        .v_rsq_f32,
    }, 0..) |opcode, index| {
        try program.instructions.append(std.testing.allocator, .{
            .opcode = opcode,
            .dst = .{ .kind = .vgpr, .reg = @intCast(index + 1) },
            .src0 = .{ .kind = .vgpr, .reg = 0 },
            .src_count = 1,
        });
    }
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_rcp_f32,
        .dst = .{ .kind = .vgpr, .reg = 12 },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 11), countOpcode(module.words, 12)); // OpExtInst
    try std.testing.expect(containsOpcode(module.words, 136)); // OpFDiv
}

test "VOP3 ldexp lowers the Tetris tone-mapping instruction" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 11) << 17) | (@as(u32, 1) << 9) | 255, // v_mov_b32 v11, literal
        0x3f80_0000,
        0xd762_011e,
        0x0001_850b,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(isa.Opcode.v_ldexp_f32, program.instructions.items[1].opcode);
    try std.testing.expectEqual(@as(i32, -2), program.instructions.items[1].src1.signed_val);

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u32, 53), firstInstructionOperand(module.words, 12, 3));
}

test "VOP3 cube coordinate operations lower the Tetris environment shader" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    inline for ([_]isa.Opcode{
        .v_cubeid_f32,
        .v_cubesc_f32,
        .v_cubetc_f32,
        .v_cubema_f32,
    }, 0..) |opcode, index| {
        try program.instructions.append(std.testing.allocator, .{
            .opcode = opcode,
            .dst = .{ .kind = .vgpr, .reg = @intCast(index + 3) },
            .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 1.0)) },
            .src1 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 2.0)) },
            .src2 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 3.0)) },
            .src_count = 3,
        });
    }
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 190)); // OpFOrdGreaterThanEqual
    try std.testing.expect(containsOpcode(module.words, 184)); // OpFOrdLessThan
    try std.testing.expect(containsOpcode(module.words, 167)); // OpLogicalAnd
    try std.testing.expect(containsOpcode(module.words, 169)); // OpSelect
    try std.testing.expect(containsOpcode(module.words, 133)); // OpFMul
}

test "literal MAD conversions and min-max lower explicitly" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_madak_f32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 2.0)) },
        .src1 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 3.0)) },
        .src2 = .{ .kind = .literal_constant, .value = @bitCast(@as(f32, 4.0)) },
        .src_count = 3,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_cvt_u32_f32,
        .dst = .{ .kind = .vgpr, .reg = 2 },
        .src0 = .{ .kind = .vgpr, .reg = 1 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_min_u32,
        .dst = .{ .kind = .vgpr, .reg = 3 },
        .src0 = .{ .kind = .vgpr, .reg = 2 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 64, .signed_val = 64 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 133)); // OpFMul
    try std.testing.expect(containsOpcode(module.words, 129)); // OpFAdd
    try std.testing.expect(containsOpcode(module.words, 109)); // OpConvertFToU
    try std.testing.expect(containsOpcode(module.words, 12)); // UMin via OpExtInst
}

test "scalar integer min-max lower and update SCC" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    for ([_]isa.Opcode{ .s_min_u32, .s_max_u32, .s_min_i32, .s_max_i32 }, 0..) |opcode, index| {
        try program.instructions.append(std.testing.allocator, .{
            .opcode = opcode,
            .dst = .{ .kind = .sgpr, .reg = @intCast(index) },
            .src0 = .{ .kind = .integer_inline_constant, .value = 7, .signed_val = 7 },
            .src1 = .{ .kind = .integer_inline_constant, .value = 11, .signed_val = 11 },
            .src_count = 2,
        });
    }
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 12)); // GLSL min/max
    try std.testing.expect(containsOpcode(module.words, 176)); // OpULessThan
    try std.testing.expect(containsOpcode(module.words, 172)); // OpUGreaterThan
    try std.testing.expect(containsOpcode(module.words, 177)); // OpSLessThan
    try std.testing.expect(containsOpcode(module.words, 173)); // OpSGreaterThan
}

test "signed high multiply and floor conversion lower explicitly" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_mul_hi_i32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .literal_constant, .value = @bitCast(@as(i32, -7)) },
        .src1 = .{ .kind = .integer_inline_constant, .value = 3, .signed_val = 3 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_cvt_flr_i32_f32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, -1.25)) },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 177)); // OpSLessThan
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 169)); // OpSelect
    try std.testing.expect(countOpcode(module.words, 130) >= 2); // OpISub
    try std.testing.expect(containsOpcode(module.words, 12)); // GLSL Floor
    try std.testing.expect(containsOpcode(module.words, 110)); // OpConvertFToS
}

test "fused multiply-add uses GLSL Fma" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_fma_f32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 2.0)) },
        .src1 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 4.0)) },
        .src2 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, -1.0)) },
        .src_count = 3,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 12));
    try std.testing.expect(!containsOpcode(module.words, 133)); // no separate multiply
    try std.testing.expect(!containsOpcode(module.words, 129)); // no separate add
}

test "floating destination clamp and output modifier lower after arithmetic" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_mul_f32,
        .dst = .{ .kind = .vgpr, .reg = 0, .clamp = true, .omod = 1 },
        .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 0.25)) },
        .src1 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 4.0)) },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 133)); // multiply plus OMOD x2
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 12)); // FClamp
}

test "three-input float min max and median lower explicitly" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    inline for ([_]isa.Opcode{ .v_min3_f32, .v_max3_f32, .v_med3_f32 }, 0..) |opcode, index| {
        try program.instructions.append(std.testing.allocator, .{
            .opcode = opcode,
            .dst = .{ .kind = .vgpr, .reg = @intCast(index) },
            .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 1.0)) },
            .src1 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 2.0)) },
            .src2 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 4.0)) },
            .src_count = 3,
        });
    }
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), countOpcode(module.words, 12)); // min3/max3: two, med3: four
}

test "bitfield insert lowers to mask select operations" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_bfi_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .literal_constant, .value = 0x00ff_00ff },
        .src1 = .{ .kind = .literal_constant, .value = 0x1234_5678 },
        .src2 = .{ .kind = .literal_constant, .value = 0xabcd_ef01 },
        .src_count = 3,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 199)); // OpBitwiseAnd
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 200)); // OpNot
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 197)); // OpBitwiseOr
}

test "scalar bitfield mask lowers the Tetris shader instruction" {
    const decoder = @import("decoder.zig");
    // s_bfm_b32 vcc_lo, 8, 22; s_endpgm
    const code = [_]u32{ 0x926a_9688, 0xbf81_0000 };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(isa.Opcode.s_bfm_b32, program.instructions.items[0].opcode);

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 199)); // OpBitwiseAnd
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 196)); // OpShiftLeftLogical
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 130)); // OpISub
}

test "scalar bitfield extract unpacks its SOP2 control operand" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_bfe_u32,
        .dst = .{ .kind = .sgpr, .reg = 0 },
        .src0 = .{ .kind = .literal_constant, .value = 0xf000_0000 },
        .src1 = .{ .kind = .literal_constant, .value = 0x8_0018 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 194)); // OpShiftRightLogical
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 199)); // OpBitwiseAnd
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 203)); // OpBitFieldUExtract
}

test "64-bit scalar bitfield extract writes both result dwords" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_bfe_u64,
        .dst = .{ .kind = .sgpr, .reg = 2 },
        .src0 = .{ .kind = .sgpr, .reg = 0 },
        .src1 = .{ .kind = .literal_constant, .value = 0x20_0018 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 201)); // mask halves
    try std.testing.expect(countOpcode(module.words, 169) >= 5); // selects for shift/count halves
    try std.testing.expect(countOpcode(module.words, 199) >= 5); // masks plus extraction
}

test "vector comparison writes VCC for a following conditional mask" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_cmp_le_f32,
        .dst = .{ .kind = .vcc_lo },
        .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 0.5)) },
        .src1 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 1.0)) },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_cndmask_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 2 },
        .src2 = .{ .kind = .vcc_lo },
        .src_count = 3,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 188)); // OpFOrdLessThanEqual
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 169)); // mask and cndmask selects
}

test "64-bit scalar mask operations lower both register halves" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_nand_b64,
        .dst = .{ .kind = .vcc_lo },
        .src0 = .{ .kind = .integer_inline_constant, .value = 7, .signed_val = 7 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 3, .signed_val = 3 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_andn2_b64,
        .dst = .{ .kind = .sgpr, .reg = 0 },
        .src0 = .{ .kind = .vcc_lo },
        .src1 = .{ .kind = .integer_inline_constant, .value = 1, .signed_val = 1 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_cselect_b64,
        .dst = .{ .kind = .sgpr, .reg = 2 },
        .src0 = .{ .kind = .vcc_lo },
        .src1 = .{ .kind = .sgpr, .reg = 0 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 199)); // two NAND and two ANDN2 halves
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 200)); // NAND results and ANDN2 rhs
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 169)); // 64-bit CSELECT halves
}

test "and-saveexec preserves the old mask and lowers the new mask" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_cmp_eq_f32,
        .dst = .{ .kind = .vcc_lo },
        .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 1.0)) },
        .src1 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 1.0)) },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_and_saveexec_b64,
        .dst = .{ .kind = .sgpr, .reg = 44 },
        .src0 = .{ .kind = .vcc_lo },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_mov_b64,
        .dst = .{ .kind = .exec_lo },
        .src0 = .{ .kind = .sgpr, .reg = 44 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 199)); // two EXEC halves
}

test "zero register delta accepts a high mask register" {
    const same = try Builder.consecutiveRegister(.{ .kind = .vcc_hi }, 0);
    try std.testing.expectEqual(isa.OperandKind.vcc_hi, same.kind);
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

test "24-bit vector multiply masks or sign extends its inputs" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    inline for ([_]isa.Opcode{ .v_mul_u32_u24, .v_mul_i32_i24 }, 0..) |opcode, index| {
        try program.instructions.append(std.testing.allocator, .{
            .opcode = .v_mov_b32,
            .dst = .{ .kind = .vgpr, .reg = @intCast(index * 2) },
            .src0 = .{ .kind = .integer_inline_constant, .value = 3, .signed_val = 3 },
            .src_count = 1,
        });
        try program.instructions.append(std.testing.allocator, .{
            .opcode = opcode,
            .dst = .{ .kind = .vgpr, .reg = @intCast(index * 2 + 1) },
            .src0 = .{ .kind = .vgpr, .reg = @intCast(index * 2) },
            .src1 = .{ .kind = .integer_inline_constant, .value = 7, .signed_val = 7 },
            .src_count = 2,
        });
    }
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 132)); // OpIMul
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 199)); // unsigned masks
    try std.testing.expect(countOpcode(module.words, 195) >= 2); // signed extension
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

test "native vector unsigned SAD lowers absolute difference plus addend" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xd55d_0005,
        @as(u32, 16) | (@as(u32, 128) << 9) | (@as(u32, 256 + 5) << 18),
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .vertex });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 176)); // OpULessThan
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 130)); // OpISub
    try std.testing.expect(containsOpcode(module.words, 169)); // OpSelect
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

test "merged NGG vertex prolog reaches its position export" {
    // The shape a Gen5 vertex program actually arrives in: it runs as the ES
    // half of a merged NGG wave, reads the wave description out of a hardware
    // SGPR that is not user data, and takes its vertex id from V5 rather than
    // from the attribute-fetch VGPR.
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    // s_bfe_u32 vcc_lo, s3, 0x80008 — unpack the merged wave info.
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_bfe_u32,
        .dst = .{ .kind = .vcc_lo },
        .src0 = .{ .kind = .sgpr, .reg = 3 },
        .src1 = .{ .kind = .literal_constant, .value = 0x8_0008 },
        .src_count = 2,
    });
    // The primitive export a merged wave issues before its vertex work.
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .exp,
        .export_target = 20,
        .export_enable = 0x1,
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src_count = 1,
    });
    inline for (.{ 0, 1, 2, 3 }) |component| {
        try program.instructions.append(std.testing.allocator, .{
            .opcode = .v_cvt_f32_i32,
            .dst = .{ .kind = .vgpr, .reg = component },
            .src0 = .{ .kind = .vgpr, .reg = 5 },
            .src_count = 1,
        });
    }
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .exp,
        .export_target = 0x0c,
        .export_enable = 0xf,
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .vgpr, .reg = 1 },
        .src2 = .{ .kind = .vgpr, .reg = 2 },
        .src3 = .{ .kind = .vgpr, .reg = 3 },
        .src_count = 4,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{
        .stage = .vertex,
        .vertex_index_vgpr = 0,
    });
    defer module.deinit(std.testing.allocator);

    // The wave-info read no longer rejects the program, the primitive export is
    // dropped rather than translated, and the position still reaches Vulkan.
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 62)); // OpStore Position
    try std.testing.expect(containsOpcode(module.words, 111)); // OpConvertSToF from V5
    // Position, VertexIndex and InstanceIndex are decorated: a vertex prolog
    // selects between the latter two, so neither may be left undefined.
    try std.testing.expectEqual(@as(usize, 3), countOpcode(module.words, 71)); // OpDecorate BuiltIn
}

test "vertex PARAM export and fragment interpolation share a location" {
    var vertex = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer vertex.deinit(std.testing.allocator);
    for (0..4) |component| {
        try vertex.instructions.append(std.testing.allocator, .{
            .opcode = .v_mov_b32,
            .dst = .{ .kind = .vgpr, .reg = @intCast(component) },
            .src0 = .{ .kind = .literal_constant, .value = @bitCast(@as(f32, @floatFromInt(component))) },
            .src_count = 1,
        });
    }
    try vertex.instructions.append(std.testing.allocator, .{
        .opcode = .exp,
        .export_target = 0x20,
        .export_enable = 0xf,
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .vgpr, .reg = 1 },
        .src2 = .{ .kind = .vgpr, .reg = 2 },
        .src3 = .{ .kind = .vgpr, .reg = 3 },
        .src_count = 4,
    });
    try vertex.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });
    var vertex_module = try translate(std.testing.allocator, &vertex, .{ .stage = .vertex });
    defer vertex_module.deinit(std.testing.allocator);

    var fragment = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer fragment.deinit(std.testing.allocator);
    inline for (.{ isa.Opcode.v_interp_p1_f32, isa.Opcode.v_interp_p2_f32 }) |opcode| {
        try fragment.instructions.append(std.testing.allocator, .{
            .opcode = opcode,
            .dst = .{ .kind = .vgpr, .reg = 4 },
            .src0 = .{ .kind = .vgpr, .reg = 4 },
            .src1 = .{ .kind = .integer_inline_constant, .value = 0 }, // ATTR0
            .src2 = .{ .kind = .integer_inline_constant, .value = 0 }, // channel X
            .src_count = 3,
        });
    }
    try fragment.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });
    var fragment_module = try translate(std.testing.allocator, &fragment, .{ .stage = .fragment });
    defer fragment_module.deinit(std.testing.allocator);

    // Both modules declare Location 0. The VS stores PARAM0 and VINTRP loads
    // and extracts ATTR0 in the PS instead of manufacturing screen-space UVs.
    try std.testing.expectEqual(@as(usize, 2), countOpcode(vertex_module.words, 71)); // OpDecorate
    try std.testing.expectEqual(@as(usize, 1), countOpcode(vertex_module.words, 62)); // OpStore PARAM0
    try std.testing.expectEqual(@as(usize, 3), countOpcode(fragment_module.words, 71)); // OpDecorate
    try std.testing.expectEqual(@as(usize, 2), countOpcode(fragment_module.words, 61)); // OpLoad
    try std.testing.expectEqual(@as(usize, 2), countOpcode(fragment_module.words, 81)); // OpCompositeExtract
}

test "pixel input control maps VINTRP attribute to vertex PARAM location" {
    var fragment = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer fragment.deinit(std.testing.allocator);
    try fragment.instructions.appendSlice(std.testing.allocator, &.{
        .{
            .opcode = .v_interp_mov_f32,
            .dst = .{ .kind = .vgpr, .reg = 0 },
            .src0 = .{ .kind = .integer_inline_constant, .value = 0 },
            .src1 = .{ .kind = .integer_inline_constant, .value = 0 }, // ATTR0
            .src2 = .{ .kind = .integer_inline_constant, .value = 0 },
            .src_count = 3,
        },
        .{ .opcode = .s_endpgm },
    });
    const controls = [_]u32{0x402}; // PARAM2 + FLAT_SHADE
    var module = try translate(std.testing.allocator, &fragment, .{
        .stage = .fragment,
        .fragment_input_controls = &controls,
    });
    defer module.deinit(std.testing.allocator);

    var location_variable: u32 = 0;
    var saw_flat = false;
    var index: usize = 5;
    while (index < module.words.len) {
        const word_count: usize = @intCast(module.words[index] >> 16);
        if (word_count == 0 or index + word_count > module.words.len) break;
        if (@as(u16, @truncate(module.words[index])) == 71) { // OpDecorate
            if (word_count == 4 and module.words[index + 2] == 30 and module.words[index + 3] == 2) {
                location_variable = module.words[index + 1];
            }
            if (word_count == 3 and module.words[index + 2] == 14 and
                module.words[index + 1] == location_variable and location_variable != 0)
            {
                saw_flat = true;
            }
        }
        index += word_count;
    }
    try std.testing.expect(location_variable != 0);
    try std.testing.expect(saw_flat);
}

/// One indexed buffer access, encoded the way the hardware spells it.
fn testMubuf(opcode: u7, byte_offset: u12, data: u8, address: u8, resource: u8) [2]u32 {
    return .{
        0xe000_0000 | (@as(u32, opcode) << 18) | (1 << 13) | byte_offset,
        (0x80 << 24) | (@as(u32, resource / 4) << 16) | (@as(u32, data) << 8) | address,
    };
}

test "one V# SGPR can select different buffers at different instruction PCs" {
    const decoder = @import("decoder.zig");
    const code = testMubuf(0x0c, 0, 1, 0, 4) ++
        testMubuf(0x0c, 0, 2, 0, 4) ++ [_]u32{0xbf81_0000};
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);

    const storage = [_]StorageBufferBinding{
        .{ .resource_sgpr = 4, .descriptor_index = 0, .instruction_pc = 0, .stride = 12, .extent_bytes = 48 },
        .{ .resource_sgpr = 4, .descriptor_index = 1, .instruction_pc = 8, .stride = 8, .extent_bytes = 32 },
    };
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .vertex,
        .vertex_index_vgpr = 0,
        .storage_buffers = &storage,
        .descriptor_array_length = 2,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(countOpcode(module.words, 65) >= 2); // OpAccessChain
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

test "live descriptor extent guards access without a static extent" {
    // A caller that has not recovered a stable descriptor size leaves the
    // compile-time extent empty. The shader still queries the descriptor's
    // live Vulkan range, so streamed buffer sizes remain safe without becoming
    // part of the generated module or pipeline key.
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
    try std.testing.expect(containsOpcode(module.words, 68)); // OpArrayLength
    try std.testing.expect(containsOpcode(module.words, 176)); // OpULessThan
    try std.testing.expect(containsOpcode(module.words, 250)); // OpBranchConditional
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

test "fragment EXEC restore from an unavailable hardware SGPR is a no-op" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        testSop1(0x04, 126, 12), // s_mov_b64 exec, s[12:13]
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 253)); // OpReturn
}

test "fragment M0 setup from an unavailable hardware SGPR is a no-op" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        testSop1(0x03, 124, 12), // s_mov_b32 m0, s12
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 253)); // OpReturn
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

test "fragment image sample supports a three-dimensional descriptor" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf080_0f10, // image_sample dim:3d dmask:xyzw v2, v[0:2], s[0:7], s[8:11]
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
        .descriptor_index = 0,
        .dimension = .three_d,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), firstInstructionOperand(module.words, 25, 2)); // Dim3D
    try std.testing.expect(containsOpcode(module.words, 87)); // OpImageSampleImplicitLod
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 81)); // RGBA extracts
}

test "fragment image sample supports a cube descriptor" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf080_0f18, // image_sample dim:cube dmask:xyzw v2, v[0:2], s[0:7], s[8:11]
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
        .descriptor_index = 0,
        .dimension = .cube,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), firstInstructionOperand(module.words, 25, 2)); // DimCube
    try std.testing.expect(containsOpcode(module.words, 87)); // OpImageSampleImplicitLod
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 81));
}

test "fragment cube image sample accepts an explicit LOD address" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf090_071a, // image_sample_l dim:cube dmask:xyz v0, v[32:35], T#s8, S#s60
        0x01e2_0020,
        0x0023_2221,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 4), program.instructions.items[0].image_address_components);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 8,
        .sampler_sgpr = 60,
        .descriptor_index = 0,
        .dimension = .cube,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3), firstInstructionOperand(module.words, 25, 2)); // DimCube
    try std.testing.expect(containsOpcode(module.words, 88)); // OpImageSampleExplicitLod
    try std.testing.expect(!containsOpcode(module.words, 87));
}

test "fragment gather4 level zero writes four texels and preserves a packed offset" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        // v0 contains packed signed six-bit offsets x=-1, y=-1.
        (@as(u32, 0x3f) << 25) | (@as(u32, 0) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x0000_3f3f,
        (@as(u32, 0x3f) << 25) | (@as(u32, 14) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3f00_0000,
        (@as(u32, 0x3f) << 25) | (@as(u32, 15) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3f00_0000,
        0xf15c_080a, // image_gather4_lz_o dim:2d dmask:w v[4:7], v0, NSA v14/v15
        0x0040_0400,
        0x0000_0f0e,
        0xf800_080f, // exp mrt0, v4, v5, v6, v7 done
        0x0706_0504,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 0,
        .sampler_sgpr = 8,
        .descriptor_index = 0,
        .instruction_pc = 0x18,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 96)); // OpImageGather
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 202)); // signed X/Y offset extraction
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 81)); // four gathered texels
}

test "fragment sample level zero accepts a packed texel offset before NSA coordinates" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 0) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x0000_3f3f, // v0 = packed offset x=-1, y=-1
        (@as(u32, 0x3f) << 25) | (@as(u32, 14) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3f00_0000,
        (@as(u32, 0x3f) << 25) | (@as(u32, 15) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3f00_0000,
        0xf0dc_080a,
        0x0040_1100,
        0x0000_0f0e,
        0xf800_080f,
        0x1413_1211,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 0,
        .sampler_sgpr = 8,
        .descriptor_index = 0,
        .instruction_pc = 0x18,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 88)); // OpImageSampleExplicitLod
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 202));
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 81)); // dmask:w
}

test "compute image sample level zero uses explicit lod" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 0) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3e80_0000,
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 17) | (@as(u32, 0x01) << 9) | 255,
        0x3e80_0000,
        0xf09c_010a, // image_sample_lz dim:2d dmask:x v2, v[0:1], s[0:7], s[8:11]
        0x0040_0200,
        0x0000_0001, // NSA: the second coordinate is v1
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 0,
        .sampler_sgpr = 8,
        .descriptor_index = 0,
        .instruction_pc = 0x10,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 88)); // OpImageSampleExplicitLod
    try std.testing.expect((firstInstructionOperand(module.words, 88, 0) orelse 0) != 0); // vec4 result type
    try std.testing.expect(!containsOpcode(module.words, 87)); // no derivative-dependent implicit LOD
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 81)); // dmask:x extract
}

test "vertex image sample level zero uses explicit lod" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf09c_0f08, // image_sample_lz dim:2d dmask:xyzw v2, v[0:1], s[0:7], s[8:11]
        0x0040_0200,
        0xf800_080f,
        0x0504_0302,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 0,
        .sampler_sgpr = 8,
        .descriptor_index = 0,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .vertex,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 88)); // OpImageSampleExplicitLod
    try std.testing.expect(!containsOpcode(module.words, 87));
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 81));
}

test "vertex image load fetches an integer texel through a sampled descriptor" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 0) << 17) | (@as(u32, 0x01) << 9) | 255,
        12,
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 17) | (@as(u32, 0x01) << 9) | 255,
        7,
        0xf000_0108, // image_load dim:2d dmask:x v6, v[0:1], T#s8
        0x0002_0600,
        0xf800_080f,
        0x0908_0706,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 8,
        .sampler_sgpr = 0,
        .descriptor_index = 0,
        .instruction_pc = 0x10,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .vertex,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 100)); // OpImage
    try std.testing.expect(containsOpcode(module.words, 95)); // OpImageFetch
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 81));
}

test "compute image load can fetch a compressed read-only sampled descriptor" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf000_0f08, // image_load dim:2d dmask:xyzw v0, v[0:1], s[0:7]
        0x0000_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 0,
        .sampler_sgpr = 0,
        .descriptor_index = 0,
        .instruction_pc = 0,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 100)); // OpImage
    try std.testing.expect(containsOpcode(module.words, 95)); // OpImageFetch
    try std.testing.expect(!containsOpcode(module.words, 98)); // no storage OpImageRead
}

test "compute image load and NSA store use independently typed storage image bindings" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf000_0f08, // image_load dmask:xyzw v0, v[0:1], s[0:7]
        0x0000_0000,
        0xf020_0f0a, // image_store dmask:xyzw v0, v4, s[24:31], NSA v5
        0x0006_0004,
        0x0000_0005,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]StorageImageBinding{
        .{ .resource_sgpr = 0, .descriptor_index = 0, .format = .rgba32_float },
        .{ .resource_sgpr = 24, .descriptor_index = 1, .format = .rgba8_unorm },
    };
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 98)); // OpImageRead
    try std.testing.expect(containsOpcode(module.words, 99)); // OpImageWrite
}

test "compute image store accepts a one-slice 2D array opcode" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf020_0f28, // image_store dim:2d_array dmask:xyzw v0, v[4:6], s[16:23]
        0x0004_0004,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]StorageImageBinding{.{
        .resource_sgpr = 16,
        .descriptor_index = 0,
        .format = .rgba8_unorm,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 99)); // OpImageWrite
}

test "compute image store declares an R16 UNORM storage image" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf020_0f28, // image_store dim:2d_array dmask:xyzw v0, v[4:6], s[16:23]
        0x0004_0004,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]StorageImageBinding{.{
        .resource_sgpr = 16,
        .descriptor_index = 0,
        .format = .r16_unorm,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 14), firstInstructionOperand(module.words, 25, 7)); // ImageFormatR16
    try std.testing.expect(containsOpcode(module.words, 99)); // OpImageWrite
}

test "compute image load and store support three-dimensional storage images" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf000_0f10, // image_load dim:3d dmask:xyzw v0, v[4:6], s[16:23]
        0x0004_0004,
        0xf020_0f10, // image_store dim:3d dmask:xyzw v0, v[4:6], s[16:23]
        0x0004_0004,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]StorageImageBinding{.{
        .resource_sgpr = 16,
        .descriptor_index = 0,
        .format = .rgba16_float,
        .dimension = .three_d,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), firstInstructionOperand(module.words, 25, 2)); // Dim3D
    try std.testing.expect(containsOpcode(module.words, 98)); // OpImageRead
    try std.testing.expect(containsOpcode(module.words, 99)); // OpImageWrite
}

test "scalar bit reverse lowers to SPIR-V" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbeeb_0bc4, // s_brev_b32 vcc_hi, 4
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 204)); // OpBitReverse
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

test "unresolved individual MUBUF binding behaves as a null buffer" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe030_0000, // buffer_load_dword v0, v0, s4:s7, 0
        0x8001_0000,
        0xe070_0004, // buffer_store_dword v0, v0, s4:s7, offset:4
        0x8001_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);

    // A different descriptor is available to the shader, but the V# used by
    // these two instructions was not recoverable for this draw.
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 8, .descriptor_index = 0 }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(!containsOpcode(module.words, 65)); // no OpAccessChain
    try std.testing.expect(!containsOpcode(module.words, 62)); // missing store is dropped
}

test "GFX10 unified buffer formats expose packed component layouts" {
    try std.testing.expectEqual(BufferFormat{ .data = 10, .number = 0 }, decodeBufferUnifiedFormat(56).?);
    try std.testing.expectEqual(BufferFormat{ .data = 12, .number = 7 }, decodeBufferUnifiedFormat(71).?);
    try std.testing.expectEqual(
        BufferComponentLayout{ .byte_offset = 3, .bit_count = 8 },
        bufferComponentLayout(10, 3).?,
    );
    try std.testing.expectEqual(
        BufferComponentLayout{ .byte_offset = 0, .bit_offset = 30, .bit_count = 2 },
        bufferComponentLayout(8, 3).?,
    );
    try std.testing.expect(bufferComponentLayout(5, 2) == null);
    try std.testing.expect(decodeBufferUnifiedFormat(47) == null);
}

test "MUBUF format load converts packed descriptor components" {
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
        .unified_format = 56, // R8G8B8A8_UNORM
        .dst_select = .{ 4, 5, 6, 7 },
        .extent_bytes = 64,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 61)); // OpLoad
    try std.testing.expect(containsOpcode(module.words, 112)); // OpConvertUToF
    try std.testing.expect(containsOpcode(module.words, 136)); // OpFDiv
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 62)); // four component stores
}

test "MUBUF format load unpacks half-float components" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe004_0000, // buffer_load_format_xy v0:v1, v0, s4:s7, 0
        0x8001_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);

    const storage = [_]StorageBufferBinding{.{
        .resource_sgpr = 4,
        .descriptor_index = 0,
        .stride = 4,
        .unified_format = 29, // R16G16_FLOAT
        .extent_bytes = 64,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 12)); // UnpackHalf2x16 via OpExtInst
    try std.testing.expect(containsOpcode(module.words, 81)); // OpCompositeExtract
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
        .{ .register = 8, .value = 0x1000, .producer_pc = 0 },
        .{ .register = 9, .value = 0, .producer_pc = 0 },
        .{ .register = 10, .value = 64, .producer_pc = 0 },
        .{ .register = 11, .value = 0, .producer_pc = 0 },
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

test "dynamic scalar values do not create distinct SPIR-V modules" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .sgpr, .reg = 0 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    const first = [_]ScalarRegister{.{ .register = 0, .value = 0x1122_3344 }};
    const second = [_]ScalarRegister{.{ .register = 0, .value = 0xaabb_ccdd }};
    var first_module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .scalar_registers = &first,
        .dynamic_scalar_binding = .{ .binding = 10 },
    });
    defer first_module.deinit(std.testing.allocator);
    var second_module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .scalar_registers = &second,
        .dynamic_scalar_binding = .{ .binding = 10 },
    });
    defer second_module.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u32, first_module.words, second_module.words);
    try std.testing.expect(containsOpcode(first_module.words, 65)); // OpAccessChain
    try std.testing.expect(containsOpcode(first_module.words, 61)); // OpLoad
}

test "SMEM recovery requires every word from the same producer" {
    var partial_scalars = [_]ScalarRegister{.{
        .register = 28,
        .value = 0x1000,
        .producer_pc = 0x20,
    }};
    var partial_builder = try Builder.init(std.testing.allocator, .{
        .stage = .vertex,
        .scalar_registers = &partial_scalars,
        .specialized_scalar_prefix_end = 0x100,
    });
    defer partial_builder.deinit();

    const load = instruction.Instruction{
        .pc = 0x20,
        .family = .smem,
        .opcode = .s_buffer_load_dwordx16,
        .dst = .{ .kind = .sgpr, .reg = 28 },
        .data_words = 16,
    };
    try std.testing.expect(!try partial_builder.lowerSpecializedScalarDestination(load));

    var complete_scalars: [16]ScalarRegister = undefined;
    for (&complete_scalars, 0..) |*scalar, index| {
        scalar.* = .{
            .register = @intCast(28 + index),
            .value = @intCast(index),
            .producer_pc = 0x20,
        };
    }
    var complete_builder = try Builder.init(std.testing.allocator, .{
        .stage = .vertex,
        .scalar_registers = &complete_scalars,
        .specialized_scalar_prefix_end = 0x100,
    });
    defer complete_builder.deinit();
    try std.testing.expect(try complete_builder.lowerSpecializedScalarDestination(load));
    for (0..16) |index| {
        try std.testing.expect(complete_builder.registers[28 + index].id != 0);
    }
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

test "LDS paired reads writes barriers and first-lane transfer lower explicitly" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 0 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 2 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 2 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 12,
        .family = .ds,
        .opcode = .ds_write2_b32,
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .vgpr, .reg = 1 },
        .src2 = .{ .kind = .vgpr, .reg = 2 },
        .src_count = 3,
        .memory_offset = 0,
        .secondary_memory_offset = 128,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 20, .opcode = .s_barrier });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 24,
        .family = .ds,
        .opcode = .ds_read2_b32,
        .dst = .{ .kind = .vgpr, .reg = 3 },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src_count = 1,
        .memory_offset = 0,
        .secondary_memory_offset = 128,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 32,
        .opcode = .v_readfirstlane_b32,
        .dst = .{ .kind = .sgpr, .reg = 0 },
        .src0 = .{ .kind = .vgpr, .reg = 3 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 36, .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .local_size = .{ 8, 4, 1 },
        .workgroup_memory_size_bytes = 8192,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 28)); // OpTypeArray
    try std.testing.expect(containsOpcode(module.words, 65)); // OpAccessChain
    try std.testing.expect(containsOpcode(module.words, 62)); // OpStore
    try std.testing.expect(containsOpcode(module.words, 61)); // OpLoad
    try std.testing.expect(containsOpcode(module.words, 224)); // OpControlBarrier
    try std.testing.expect(containsOpcode(module.words, 338)); // OpGroupNonUniformBroadcastFirst
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
    const code = [_]u32{ 0xbe80_0200, 0xbf81_0000 }; // unsupported SOP1 opcode 0x02
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

test "scalar unsigned add and addc lower carry through SCC" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0x8000_81c1, // s_add_u32 s0, -1, 1 -> SCC=1
        0x8201_8080, // s_addc_u32 s1, 0, 0 -> 1
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(countOpcode(module.words, 128) >= 3); // OpIAdd
    try std.testing.expect(countOpcode(module.words, 176) >= 3); // OpULessThan carry tests
    try std.testing.expect(containsOpcode(module.words, 169)); // carry bit OpSelect
    try std.testing.expect(containsOpcode(module.words, 166)); // combined carry OpLogicalOr
}

test "structured EXECZ selection consumes a CMPX predicate" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .family = .vopc,
        .opcode = .v_cmpx_gt_u32,
        .dst = .{ .kind = .exec_lo },
        .src0 = .{ .kind = .integer_inline_constant, .value = 2, .signed_val = 2 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 1, .signed_val = 1 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .family = .sopp,
        .opcode = .s_cbranch_execz,
        .branch_target = 12,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .family = .vop1,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1, .signed_val = 1 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 12, .family = .sopp, .opcode = .s_endpgm });
    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 247)); // OpSelectionMerge
    try std.testing.expect(containsOpcode(module.words, 250)); // OpBranchConditional
}

test "vertex VCC selection preserves divergent attribute paths" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .family = .vopc,
        .opcode = .v_cmp_neq_f32,
        .dst = .{ .kind = .vcc_lo },
        .src0 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 1.0)) },
        .src1 = .{ .kind = .float_inline_constant, .value = @bitCast(@as(f32, 0.0)) },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .family = .sopp,
        .opcode = .s_cbranch_vccnz,
        .branch_target = 12,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .family = .vop1,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1, .signed_val = 1 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 12, .family = .sopp, .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .vertex });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 247)); // OpSelectionMerge
    try std.testing.expect(containsOpcode(module.words, 250)); // OpBranchConditional
}

test "compute EXECZ selection stays on the wave-safe linear fallback" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .family = .vopc,
        .opcode = .v_cmpx_gt_u32,
        .dst = .{ .kind = .exec_lo },
        .src0 = .{ .kind = .integer_inline_constant, .value = 2, .signed_val = 2 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 1, .signed_val = 1 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .family = .sopp,
        .opcode = .s_cbranch_execz,
        .branch_target = 12,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .family = .vop1,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1, .signed_val = 1 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 12, .family = .sopp, .opcode = .s_endpgm });
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(!containsOpcode(module.words, 247)); // OpSelectionMerge
}

test "structured entry block retains specialized scalar inputs" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbf09_8356, // s_cmp_ge_u32 s86, 0
        0xbf84_0001, // s_cbranch_scc0 -> pc 12
        0xbf81_0000, // fallthrough end
        0xbf81_0000, // branch end
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const scalars = [_]ScalarRegister{.{ .register = 86, .value = 0 }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .scalar_registers = &scalars,
        .specialized_scalar_prefix_end = 0x100,
    });
    defer module.deinit(std.testing.allocator);
    // Translation itself is the assertion: before entry-state inheritance the
    // first comparison returned UndefinedRegister for s86.
    try std.testing.expect(containsOpcode(module.words, 253)); // OpReturn
}

test "back edges use the linear fallback until loop structuring is implemented" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{ 0xbf80_0000, 0xbf82_fffe, 0xbf81_0000 };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(!containsOpcode(module.words, 246)); // OpLoopMerge
    try std.testing.expect(containsOpcode(module.words, 253)); // OpReturn
}

test "partial structured lowering restarts a clean linear builder" {
    const first = instruction.Instruction{
        .pc = 0,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1, .signed_val = 1 },
        .src_count = 1,
    };
    const second = instruction.Instruction{
        .pc = 8,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 2, .signed_val = 2 },
        .src_count = 1,
    };
    const finish = instruction.Instruction{ .pc = 12, .opcode = .s_endpgm };

    var branched = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer branched.deinit(std.testing.allocator);
    try branched.instructions.append(std.testing.allocator, first);
    try branched.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .family = .sopp,
        // The direct branch leaves the following block unreachable. Structured
        // lowering deliberately rejects that graph after it has already
        // emitted the entry block, exercising the clean-builder fallback.
        .opcode = .s_branch,
        .branch_target = 12,
    });
    try branched.instructions.append(std.testing.allocator, second);
    try branched.instructions.append(std.testing.allocator, finish);

    var straight = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer straight.deinit(std.testing.allocator);
    try straight.instructions.append(std.testing.allocator, first);
    try straight.instructions.append(std.testing.allocator, second);
    try straight.instructions.append(std.testing.allocator, finish);

    var fallback_module = try translate(std.testing.allocator, &branched, .{ .stage = .fragment });
    defer fallback_module.deinit(std.testing.allocator);
    var straight_module = try translate(std.testing.allocator, &straight, .{ .stage = .fragment });
    defer straight_module.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u32, straight_module.words, fallback_module.words);
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
