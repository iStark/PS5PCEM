// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Deterministic SPIR-V 1.5 writer for executable RDNA2 graphics and compute shaders.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
const instruction = @import("instruction.zig");
const control_flow = @import("control_flow.zig");
const shader_ir = @import("ir.zig");

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
    two_d_array,
};

pub const sampled_image_2d_descriptor_binding: u32 = 1;
pub const maximum_storage_images: usize = 32;
pub const sampled_image_3d_descriptor_binding: u32 = 3 + maximum_storage_images;
pub const sampled_image_cube_descriptor_binding: u32 = 4 + maximum_storage_images;
pub const sampled_image_2d_array_descriptor_binding: u32 = 5 + maximum_storage_images;
pub const gds_descriptor_binding: u32 = 6 + maximum_storage_images;

fn sampledImageDimensionIndex(dimension: SampledImageDimension) usize {
    return switch (dimension) {
        .two_d => 0,
        .three_d => 1,
        .cube => 2,
        .two_d_array => 3,
    };
}

/// Static association between a GFX10 T# and an element in Vulkan's storage
/// image array. Storage images are declared with an exact format: this avoids
/// requiring the optional read/write-without-format device features and keeps
/// validation deterministic on older Vulkan drivers.
pub const StorageImageBinding = struct {
    resource_sgpr: u32,
    descriptor_index: u32,
    /// Reserved for kernels which reload one T# SGPR range mid-program. Null
    /// is the common whole-program association.
    instruction_pc: ?u32 = null,
    format: StorageImageFormat,
    dimension: StorageImageDimension = .two_d,
    dst_select: [4]u8 = .{ 4, 5, 6, 7 },
};

pub const StorageImageDimension = enum(u8) {
    two_d,
    three_d,
};

pub const StorageImageFormat = enum(u16) {
    r8_unorm = 1,
    r8_snorm = 2,
    r8_uint = 5,
    r8_sint = 6,
    r16_unorm = 7,
    r16_snorm = 8,
    r16_uint = 11,
    r16_sint = 12,
    r16_float = 13,
    rg8_unorm = 14,
    rg8_snorm = 15,
    rg8_uint = 18,
    rg8_sint = 19,
    r32_uint = 20,
    r32_sint = 21,
    r32_float = 22,
    rg16_unorm = 23,
    rg16_snorm = 24,
    rg16_uint = 27,
    rg16_sint = 28,
    rg16_float = 29,
    r11g11b10_float = 36,
    rgb10a2_unorm = 50,
    rgba8_unorm = 56,
    rgba8_snorm = 57,
    rgba8_uint = 60,
    rgba8_sint = 61,
    rg32_uint = 62,
    rg32_sint = 63,
    rg32_float = 64,
    rgba16_unorm = 65,
    rgba16_snorm = 66,
    rgba16_uint = 69,
    rgba16_sint = 70,
    rgba16_float = 71,
    rgba32_uint = 75,
    rgba32_sint = 76,
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
    /// Converts a guest -W..W position export to Vulkan's 0..W clip-depth
    /// convention. Leave clear when PA_CL_CLIP_CNTL selects DX clip space.
    convert_negative_one_to_one_depth: bool = false,
    storage_buffers: []const StorageBufferBinding = &.{},
    /// Whether the program narrows the execution mask, and so needs to know
    /// which stores are active. Decided from the program by `translate`.
    uses_execution_mask: bool = false,
    /// Whether an instruction actually reads the current lane identity. Keep
    /// this separate from EXEC bookkeeping: graphics shaders commonly restore
    /// EXEC before an export, but an export does not need a subgroup input.
    uses_lane_identity: bool = false,
    sampled_images: []const SampledImageBinding = &.{},
    storage_images: []const StorageImageBinding = &.{},
    /// Amount of per-workgroup LDS made available by COMPUTE_PGM_RSRC2. DS
    /// instructions address it in bytes; the SPIR-V declaration is a u32 array.
    workgroup_memory_size_bytes: u32 = 0,
    /// Per-invocation scratch used by graphics DS addtid spill/fill pairs.
    private_memory_size_bytes: u32 = 0,
    /// Exposes the persistent 64 KiB Global Data Share as a storage buffer.
    gds_storage: bool = false,
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
    /// Fragment EXP MRT0..7 bits. Empty leaves Location 0 declared so a
    /// pixel program that never exports still has a legal colour output.
    color_export_mask: u8 = 0,
    /// Selects the logical guest EXP component written to every physical
    /// Vulkan attachment component. Two bits per component; 0xe4 is RGBA.
    /// CB_COLOR_INFO.COMP_SWAP supplies one mapping for each active MRT.
    color_export_mappings: [8]u8 = @splat(0xe4),
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
    InvalidIrStage,
};

pub const Module = struct {
    words: []u32,
    /// True when structured control-flow lowering was unavailable and the
    /// translator used its linear graphics bring-up fallback.
    used_control_flow_fallback: bool = false,
    /// True when the CFG was emitted as a block-index dispatcher rather than
    /// structured selections and natural loops.
    used_dispatcher: bool = false,

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
        .r8_uint, .r16_uint, .rg8_uint, .r32_uint, .rg16_uint, .rgba8_uint, .rg32_uint, .rgba16_uint, .rgba32_uint => .bits32,
        .r8_sint, .r16_sint, .rg8_sint, .r32_sint, .rg16_sint, .rgba8_sint, .rg32_sint, .rgba16_sint, .rgba32_sint => .sint32,
        .r8_unorm, .r8_snorm, .r16_unorm, .r16_snorm, .r16_float, .rg8_unorm, .rg8_snorm, .r32_float, .rg16_unorm, .rg16_snorm, .rg16_float, .r11g11b10_float, .rgb10a2_unorm, .rgba8_unorm, .rgba8_snorm, .rg32_float, .rgba16_unorm, .rgba16_snorm, .rgba16_float, .rgba32_float => .float32,
    };
}

fn storageImageSpirvFormat(format: StorageImageFormat) u32 {
    return switch (format) {
        .rgba32_float => 1, // Rgba32f
        .rgba16_float => 2, // Rgba16f
        .r32_float => 3, // R32f
        .rgba8_unorm => 4, // Rgba8
        .rgba8_snorm => 5, // Rgba8Snorm
        .rg32_float => 6, // Rg32f
        .rg16_float => 7, // Rg16f
        .r11g11b10_float => 8, // R11fG11fB10f
        .r16_float => 9, // R16f
        .rgba16_unorm => 10, // Rgba16
        .rgb10a2_unorm => 11, // Rgb10A2
        .rg16_unorm => 12, // Rg16
        .rg8_unorm => 13, // Rg8
        .r16_unorm => 14, // R16
        .r8_unorm => 15, // R8
        .rgba16_snorm => 16, // Rgba16Snorm
        .rg16_snorm => 17, // Rg16Snorm
        .rg8_snorm => 18, // Rg8Snorm
        .r16_snorm => 19, // R16Snorm
        .r8_snorm => 20, // R8Snorm
        .rgba32_sint => 21, // Rgba32i
        .rgba16_sint => 22, // Rgba16i
        .rgba8_sint => 23, // Rgba8i
        .r32_sint => 24, // R32i
        .rg32_sint => 25, // Rg32i
        .rg16_sint => 26, // Rg16i
        .rg8_sint => 27, // Rg8i
        .r16_sint => 28, // R16i
        .r8_sint => 29, // R8i
        .rgba32_uint => 30, // Rgba32ui
        .rgba16_uint => 31, // Rgba16ui
        .rgba8_uint => 32, // Rgba8ui
        .r32_uint => 33, // R32ui
        .rg32_uint => 35, // Rg32ui
        .rg16_uint => 36, // Rg16ui
        .rg8_uint => 37, // Rg8ui
        .r16_uint => 38, // R16ui
        .r8_uint => 39, // R8ui
    };
}

fn storageImageNeedsExtendedFormats(format: StorageImageFormat) bool {
    return switch (format) {
        .rgba32_float,
        .rgba16_float,
        .r32_float,
        .rgba8_unorm,
        .rgba8_snorm,
        .rgba32_sint,
        .rgba16_sint,
        .rgba8_sint,
        .r32_sint,
        .rgba32_uint,
        .rgba16_uint,
        .rgba8_uint,
        .r32_uint,
        => false,
        else => true,
    };
}

/// A render-target component mapping names the logical shader component for
/// each physical attachment component. Keeping this transformation in the
/// fragment epilogue lets one resident VkImage retain the guest byte layout
/// even when later draws bind the allocation with another COMP_SWAP value.
fn remapColorExportComponents(components: [4]u32, mapping: u8) [4]u32 {
    var result: [4]u32 = undefined;
    for (&result, 0..) |*component, physical| {
        const shift: u3 = @intCast(physical * 2);
        const logical: u2 = @truncate(mapping >> shift);
        component.* = components[logical];
    }
    return result;
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
    vector4_signed_type: u32 = 0,
    vector4_bits_type: u32 = 0,
    main_function: u32,
    label: u32,
    stage: Stage,
    vertex_index_vgpr: ?u8,
    convert_negative_one_to_one_depth: bool,
    vertex_index_input: u32 = 0,
    instance_index_input: u32 = 0,
    position_output: u32 = 0,
    color_outputs: [8]u32 = @splat(0),
    color_export_mappings: [8]u8,
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
    /// Multiple memory stores commonly share one unchanged EXEC value. Reuse
    /// the per-invocation predicate instead of rebuilding the same lane-index,
    /// half-selection and bit-test graph for every store.
    lane_predicate_mask: ?[2]u32 = null,
    lane_predicate: u32 = 0,
    workgroup_id_input: u32 = 0,
    local_invocation_id_input: u32 = 0,
    compute_inputs: ?ComputeInputs,
    local_size: [3]u32,
    fragment_extent: [2]u32,
    vector2_type: u32 = 0,
    vector2_bits_type: u32 = 0,
    sampled_image_image_types: [4]u32 = @splat(0),
    sampled_image_types: [4]u32 = @splat(0),
    sampled_image_arrays: [4]u32 = @splat(0),
    sampled_image_pointer_types: [4]u32 = @splat(0),
    storage_image_types: [maximum_storage_images]u32 = @splat(0),
    storage_image_pointer_types: [maximum_storage_images]u32 = @splat(0),
    storage_image_vector_types: [maximum_storage_images]u32 = @splat(0),
    storage_image_texel_pointer_types: [maximum_storage_images]u32 = @splat(0),
    storage_texel_pointer_types: [3]u32 = @splat(0),
    storage_image_variables: [maximum_storage_images]u32 = @splat(0),
    workgroup_memory: u32 = 0,
    workgroup_word_pointer_type: u32 = 0,
    workgroup_memory_words: u32 = 0,
    private_memory: u32 = 0,
    private_word_pointer_type: u32 = 0,
    private_memory_words: u32 = 0,
    gds_memory: u32 = 0,
    gds_word_pointer_type: u32 = 0,
    /// GLSL.std.450 extended instruction set (PackHalf2x16, etc.). 0 = unused.
    glsl_std_450: u32 = 0,
    uses_image_query: bool = false,
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
    /// Function-local backing used only while translating reducible guest
    /// loops. SSA snapshots are sufficient for acyclic selections, but a
    /// back edge needs values produced later in the function. Keeping the
    /// guest registers mutable in that path avoids manufacturing forward
    /// OpPhi operands and maps naturally onto nested RDNA scalar loops.
    mutable_register_pointers: [384]u32 = @splat(0),
    mutable_scc_pointer: u32 = 0,
    mutable_carry_pointer: u32 = 0,
    dispatch_pc_pointer: u32 = 0,
    function_bits_pointer_type: u32 = 0,
    used_control_flow_fallback: bool = false,
    used_dispatcher: bool = false,

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
            .convert_negative_one_to_one_depth = options.convert_negative_one_to_one_depth,
            .color_export_mappings = options.color_export_mappings,
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
        if (options.gds_storage) {
            if (options.stage != .compute) return Error.InvalidStageInterface;
            const words = self.id();
            const block = self.id();
            const block_pointer = self.id();
            self.gds_word_pointer_type = self.id();
            self.gds_memory = self.id();
            try self.emit(&self.annotations, 71, &.{ words, 6, 4 }); // ArrayStride 4
            try self.emit(&self.annotations, 72, &.{ block, 0, 35, 0 }); // member Offset 0
            try self.emit(&self.annotations, 71, &.{ block, 2 }); // Block
            try self.emit(&self.annotations, 71, &.{ self.gds_memory, 34, 0 }); // DescriptorSet 0
            try self.emit(&self.annotations, 71, &.{ self.gds_memory, 33, gds_descriptor_binding });
            try self.emit(&self.declarations, 29, &.{ words, self.bits_type }); // OpTypeRuntimeArray
            try self.emit(&self.declarations, 30, &.{ block, words }); // OpTypeStruct
            try self.emit(&self.declarations, 32, &.{ block_pointer, 12, block });
            try self.emit(&self.declarations, 32, &.{ self.gds_word_pointer_type, 12, self.bits_type });
            try self.emit(&self.declarations, 59, &.{ block_pointer, self.gds_memory, 12 }); // OpVariable
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
                try self.emit(&self.declarations, 23, &.{ self.vector4_type, self.float_type, 4 }); // OpTypeVector
                try self.emit(&self.declarations, 32, &.{ output_pointer, 3, self.vector4_type }); // ptr Output
                var color_mask = options.color_export_mask;
                if (color_mask == 0) color_mask = 1;
                for (0..self.color_outputs.len) |slot| {
                    if (color_mask & (@as(u8, 1) << @intCast(slot)) == 0) continue;
                    const variable = self.id();
                    self.color_outputs[slot] = variable;
                    try self.emit(&self.annotations, 71, &.{ variable, 30, @intCast(slot) }); // Location
                    try self.emit(&self.declarations, 59, &.{ output_pointer, variable, 3 }); // OpVariable
                }
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
        }
        {
            var needs_thread_id = options.uses_lane_identity;
            for (options.storage_buffers) |binding| {
                needs_thread_id = needs_thread_id or binding.add_thread_id;
            }
            if (needs_thread_id and self.local_invocation_index == 0) {
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
            var sampled_dimensions: [4]bool = @splat(false);
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
                    3 => 1,
                    else => unreachable,
                };
                const descriptor_binding = switch (dimension_index) {
                    0 => sampled_image_2d_descriptor_binding,
                    1 => sampled_image_3d_descriptor_binding,
                    2 => sampled_image_cube_descriptor_binding,
                    3 => sampled_image_2d_array_descriptor_binding,
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
                try self.emit(&self.declarations, 25, &.{
                    image_type,
                    self.float_type,
                    spirv_dimension,
                    0,
                    @intFromBool(dimension_index == 3),
                    0,
                    1,
                    0,
                });
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
                    if (previous.resource_sgpr == binding.resource_sgpr and
                        previous.instruction_pc == binding.instruction_pc)
                    {
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

            _ = try self.ensureBitsVec2();
            var needs_3d_coordinates = false;
            for (options.storage_images) |binding| {
                needs_3d_coordinates = needs_3d_coordinates or binding.dimension == .three_d;
            }
            if (needs_3d_coordinates and self.vector3_bits_type == 0) {
                self.vector3_bits_type = self.id();
                try self.emit(&self.declarations, 23, &.{ self.vector3_bits_type, self.bits_type, 3 });
            }
            for (options.storage_images, 0..) |binding, index| {
                const descriptor_index: usize = @intCast(binding.descriptor_index);
                if (self.storage_image_variables[descriptor_index] != 0) continue;
                const value_type = storageImageValueType(binding.format);
                const component_type = self.typeId(value_type);
                const vector_type = try self.ensureVec4(value_type);
                var image_type: u32 = 0;
                var image_pointer_type: u32 = 0;
                for (options.storage_images[0..index]) |previous| {
                    if (previous.format != binding.format or previous.dimension != binding.dimension) continue;
                    const previous_index: usize = @intCast(previous.descriptor_index);
                    image_type = self.storage_image_types[previous_index];
                    image_pointer_type = self.storage_image_pointer_types[previous_index];
                    if (image_type != 0) break;
                }
                const declare_image_type = image_type == 0;
                if (declare_image_type) {
                    image_type = self.id();
                    image_pointer_type = self.id();
                }
                const value_type_index: usize = @intFromEnum(value_type);
                var texel_pointer_type = self.storage_texel_pointer_types[value_type_index];
                const declare_texel_pointer_type = texel_pointer_type == 0;
                if (declare_texel_pointer_type) {
                    texel_pointer_type = self.id();
                    self.storage_texel_pointer_types[value_type_index] = texel_pointer_type;
                }
                const variable = self.id();
                self.storage_image_vector_types[descriptor_index] = vector_type;
                self.storage_image_types[descriptor_index] = image_type;
                self.storage_image_pointer_types[descriptor_index] = image_pointer_type;
                self.storage_image_texel_pointer_types[descriptor_index] = texel_pointer_type;
                self.storage_image_variables[descriptor_index] = variable;
                try self.emit(&self.annotations, 71, &.{ variable, 34, 0 }); // DescriptorSet 0
                try self.emit(&self.annotations, 71, &.{ variable, 33, 2 + binding.descriptor_index }); // Binding 2 + slot
                if (declare_image_type) {
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
                }
                if (declare_texel_pointer_type) {
                    try self.emit(&self.declarations, 32, &.{ texel_pointer_type, 11, component_type }); // ptr Image component
                }
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
        if (options.private_memory_size_bytes != 0) {
            if (options.stage == .compute) return Error.InvalidStageInterface;
            const words = std.math.divCeil(u32, options.private_memory_size_bytes, 4) catch
                return Error.InvalidStageInterface;
            if (words == 0) return Error.InvalidStageInterface;
            self.private_memory_words = words;
            const word_count = try self.constant(.bits32, words);
            const array_type = self.id();
            const array_pointer_type = self.id();
            self.private_word_pointer_type = self.id();
            self.private_memory = self.id();
            try self.emit(&self.declarations, 28, &.{ array_type, self.bits_type, word_count }); // OpTypeArray
            try self.emit(&self.declarations, 32, &.{ array_pointer_type, 6, array_type }); // ptr Private array
            try self.emit(&self.declarations, 32, &.{ self.private_word_pointer_type, 6, self.bits_type });
            try self.emit(&self.declarations, 59, &.{ array_pointer_type, self.private_memory, 6 }); // OpVariable
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
            .m0 => 124,
            else => null,
        };
    }

    fn registerBits(self: *Builder, index: usize, default_bits: u32) Error!u32 {
        if (self.mutable_register_pointers[index] != 0) {
            const loaded = self.id();
            try self.emit(&self.body, 61, &.{ self.bits_type, loaded, self.mutable_register_pointers[index] }); // OpLoad
            return loaded;
        }
        const current = self.registers[index];
        if (current.id == 0) return self.constant(.bits32, default_bits);
        return self.convert(current, .bits32);
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
                break :blk try self.registerBits(index, 0xffff_ffff);
            },
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
            .m0 => self.registerBits(124, 0),
            .sgpr, .vgpr => blk: {
                const index = registerIndex(op) orelse return Error.UndefinedRegister;
                if (self.mutable_register_pointers[index] != 0) {
                    break :blk try self.registerBits(index, 0);
                }
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
                const lane = try self.currentLaneId();
                const quad_lane = try self.andBits(lane, 3);
                const quad_base = try self.andBits(lane, 0xffff_fffc);
                const lane_shift = self.id();
                try self.emit(&self.body, 196, &.{
                    self.bits_type,
                    lane_shift,
                    quad_lane,
                    try self.constant(.bits32, 1),
                }); // OpShiftLeftLogical: quad_lane * 2
                const shifted_ctrl = self.id();
                try self.emit(&self.body, 194, &.{
                    self.bits_type,
                    shifted_ctrl,
                    try self.constant(.bits32, op.dpp_ctrl),
                    lane_shift,
                }); // OpShiftRightLogical
                const select = try self.andBits(shifted_ctrl, 3);
                const dest_lane = self.id();
                try self.emit(&self.body, 197, &.{ self.bits_type, dest_lane, quad_base, select }); // OpBitwiseOr
                try self.emit(&self.body, 345, &.{ self.bits_type, shuffled, scope, raw, dest_lane }); // OpGroupNonUniformShuffle
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
        const bits = try self.convert(final_value, .bits32);
        self.registers[index] = .{
            .id = bits,
            .value_type = .bits32,
        };
        if (self.mutable_register_pointers[index] != 0) {
            try self.emit(&self.body, 62, &.{ self.mutable_register_pointers[index], bits }); // OpStore
        }
        if (index == 126 or index == 127) {
            const low = try self.registerBits(126, 0xffff_ffff);
            const high = try self.registerBits(127, 0xffff_ffff);
            self.exec_mask = .{ low, high };
            self.lane_predicate_mask = null;
            self.lane_predicate = 0;
        }
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

    fn scalarBitCompare(self: *Builder, inst: instruction.Instruction, expected_set: bool) Error!void {
        const value = try self.source(inst.src0, .bits32);
        const bit_index = try self.andBits(try self.source(inst.src1, .bits32), 31);
        const shifted = try self.shiftRightVariable(value, bit_index);
        const bit = try self.andBits(shifted, 1);
        self.scc = self.id();
        try self.emit(&self.body, if (expected_set) 171 else 170, &.{
            self.bool_type,
            self.scc,
            bit,
            try self.constant(.bits32, 0),
        }); // OpINotEqual / OpIEqual
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

    fn vectorComparisonF16(self: *Builder, inst: instruction.Instruction, opcode: u16) Error!void {
        const a = try self.unpackF16Low(try self.source(inst.src0, .bits32));
        const b = try self.unpackF16Low(try self.source(inst.src1, .bits32));
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.bool_type, result, a, b });
        try self.vectorConditionDestination(inst, result);
    }

    fn vectorComparisonI16(self: *Builder, inst: instruction.Instruction, opcode: u16, signed: bool) Error!void {
        const mask = try self.constant(.bits32, 0xffff);
        const a_bits = try self.andBits(try self.source(inst.src0, .bits32), 0xffff);
        const b_bits = try self.andBits(try self.source(inst.src1, .bits32), 0xffff);
        const a = if (signed) try self.signExtend16(a_bits) else a_bits;
        const b = if (signed) try self.signExtend16(b_bits) else b_bits;
        _ = mask;
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.bool_type, result, a, b });
        try self.vectorConditionDestination(inst, result);
    }

    fn signExtend16(self: *Builder, value: u32) Error!u32 {
        const shifted = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shifted, value, try self.constant(.bits32, 16) });
        const as_signed = try self.convert(.{ .id = shifted, .value_type = .bits32 }, .sint32);
        const extended = self.id();
        try self.emit(&self.body, 195, &.{ self.signed_type, extended, as_signed, try self.constant(.sint32, 16) });
        return extended;
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
    const SaveExecMode = enum { and_mask, or_not, not_and };

    fn combineExecWord(self: *Builder, mode: SaveExecMode, previous: u32, predicate: u32) Error!u32 {
        return switch (mode) {
            .and_mask => blk: {
                const result = self.id();
                try self.emit(&self.body, 199, &.{ self.bits_type, result, previous, predicate });
                break :blk result;
            },
            .or_not => blk: {
                const inverted = self.id();
                try self.emit(&self.body, 200, &.{ self.bits_type, inverted, predicate });
                const result = self.id();
                try self.emit(&self.body, 197, &.{ self.bits_type, result, previous, inverted });
                break :blk result;
            },
            .not_and => blk: {
                const inverted = self.id();
                try self.emit(&self.body, 200, &.{ self.bits_type, inverted, previous });
                const result = self.id();
                try self.emit(&self.body, 199, &.{ self.bits_type, result, inverted, predicate });
                break :blk result;
            },
        };
    }

    fn saveExec(self: *Builder, inst: instruction.Instruction, mode: SaveExecMode) Error!void {
        const previous = try self.sourcePair(.{ .kind = .exec_lo });
        const predicate = try self.sourcePair(inst.src0);
        const active = [2]u32{
            try self.combineExecWord(mode, previous[0], predicate[0]),
            try self.combineExecWord(mode, previous[1], predicate[1]),
        };
        try self.destinationPair(inst.dst, previous);
        try self.destinationPair(.{ .kind = .exec_lo }, active);
        self.exec_mask = active;
        try self.updateSccFromPair(active);
    }

    fn saveExec32(self: *Builder, inst: instruction.Instruction, mode: SaveExecMode) Error!void {
        const previous = try self.source(.{ .kind = .exec_lo }, .bits32);
        const predicate = try self.source(inst.src0, .bits32);
        const active = try self.combineExecWord(mode, previous, predicate);
        try self.destination(inst.dst, .{ .id = previous, .value_type = .bits32 });
        try self.destination(.{ .kind = .exec_lo }, .{ .id = active, .value_type = .bits32 });
        const high = if (self.exec_mask) |mask| mask[1] else try self.constant(.bits32, 0);
        self.exec_mask = .{ active, high };
        try self.updateSccFromPair(.{ active, high });
    }

    fn bitwise32(self: *Builder, inst: instruction.Instruction, opcode: isa.Opcode) Error!void {
        const a = try self.source(inst.src0, .bits32);
        var right = try self.source(inst.src1, .bits32);
        if (opcode == .s_andn2_b32 or opcode == .s_orn2_b32) {
            const inverted = self.id();
            try self.emit(&self.body, 200, &.{ self.bits_type, inverted, right });
            right = inverted;
        }
        const spirv_op: u16 = switch (opcode) {
            .s_andn2_b32, .s_nand_b32 => 199,
            .s_orn2_b32, .s_nor_b32 => 197,
            .s_xnor_b32 => 198,
            else => unreachable,
        };
        const combined = self.id();
        try self.emit(&self.body, spirv_op, &.{ self.bits_type, combined, a, right });
        const result = if (opcode == .s_nand_b32 or opcode == .s_nor_b32 or opcode == .s_xnor_b32) blk: {
            const inverted = self.id();
            try self.emit(&self.body, 200, &.{ self.bits_type, inverted, combined });
            break :blk inverted;
        } else combined;
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn packHalves(self: *Builder, inst: instruction.Instruction, src0_high: bool, src1_high: bool) Error!void {
        var low = try self.source(inst.src0, .bits32);
        var high = try self.source(inst.src1, .bits32);
        if (src0_high) low = try self.shiftRightBits(low, 16);
        if (!src1_high) high = try self.andBits(high, 0xffff);
        low = try self.andBits(low, 0xffff);
        if (!src1_high) {
            const shifted = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, shifted, high, try self.constant(.bits32, 16) });
            high = shifted;
        } else {
            high = try self.andBits(high, 0xffff_0000);
        }
        const result = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, result, low, high });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn absSigned(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .sint32);
        const result = self.id();
        try self.emit(&self.body, 12, &.{ self.signed_type, result, self.ensureGlslStd450(), 5, value });
        try self.destination(inst.dst, .{ .id = result, .value_type = .sint32 });
    }

    fn scalarBitfieldExtractSigned(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .sint32);
        const field = try self.source(inst.src1, .bits32);
        const offset_bits = try self.andBits(field, 31);
        const shifted_field = self.id();
        try self.emit(&self.body, 194, &.{
            self.bits_type,
            shifted_field,
            field,
            try self.constant(.bits32, 16),
        }); // OpShiftRightLogical
        const width_bits = try self.andBits(shifted_field, 0x7f);
        const offset = try self.convert(.{ .id = offset_bits, .value_type = .bits32 }, .sint32);
        const width = try self.convert(.{ .id = width_bits, .value_type = .bits32 }, .sint32);
        const result = self.id();
        try self.emit(&self.body, 202, &.{ self.signed_type, result, value, offset, width }); // OpBitFieldSExtract
        try self.destination(inst.dst, .{ .id = result, .value_type = .sint32 });
    }

    fn unpackF16Low(self: *Builder, bits: u32) Error!u32 {
        const vector_type = try self.ensureFloatVec2();
        const pair = self.id();
        try self.emit(&self.body, 12, &.{
            vector_type,
            pair,
            self.ensureGlslStd450(),
            62,
            bits,
        });
        const low = self.id();
        try self.emit(&self.body, 81, &.{ self.float_type, low, pair, 0 });
        return low;
    }

    fn packF16Low(self: *Builder, value: u32) Error!u32 {
        const vector_type = try self.ensureFloatVec2();
        const zero = try self.constant(.float32, 0);
        const pair = self.id();
        try self.emit(&self.body, 80, &.{ vector_type, pair, value, zero });
        const result = self.id();
        try self.emit(&self.body, 12, &.{
            self.bits_type,
            result,
            self.ensureGlslStd450(),
            58,
            pair,
        });
        return result;
    }

    fn binaryF16(self: *Builder, inst: instruction.Instruction, opcode: u16, reverse: bool) Error!void {
        const a_bits = try self.source(if (reverse) inst.src1 else inst.src0, .bits32);
        const b_bits = try self.source(if (reverse) inst.src0 else inst.src1, .bits32);
        const a = try self.unpackF16Low(a_bits);
        const b = try self.unpackF16Low(b_bits);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.float_type, result, a, b });
        try self.destination(inst.dst, .{ .id = try self.packF16Low(result), .value_type = .bits32 });
    }

    fn glslBinaryF16(self: *Builder, inst: instruction.Instruction, opcode: u32) Error!void {
        const a = try self.unpackF16Low(try self.source(inst.src0, .bits32));
        const b = try self.unpackF16Low(try self.source(inst.src1, .bits32));
        const result = try self.glslBinaryValue(opcode, .float32, a, b);
        try self.destination(inst.dst, .{ .id = try self.packF16Low(result), .value_type = .bits32 });
    }

    fn packedBinaryF16(self: *Builder, inst: instruction.Instruction, opcode: u16) Error!void {
        const a_bits = try self.source(inst.src0, .bits32);
        const b_bits = try self.source(inst.src1, .bits32);
        const vector_type = try self.ensureFloatVec2();
        const a = self.id();
        try self.emit(&self.body, 12, &.{ vector_type, a, self.ensureGlslStd450(), 62, a_bits });
        const b = self.id();
        try self.emit(&self.body, 12, &.{ vector_type, b, self.ensureGlslStd450(), 62, b_bits });
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ vector_type, result, a, b });
        const packed_bits = self.id();
        try self.emit(&self.body, 12, &.{ self.bits_type, packed_bits, self.ensureGlslStd450(), 58, result });
        try self.destination(inst.dst, .{ .id = packed_bits, .value_type = .bits32 });
    }

    fn packedFmaF16(self: *Builder, inst: instruction.Instruction) Error!void {
        const a_bits = try self.source(inst.src0, .bits32);
        const b_bits = try self.source(inst.src1, .bits32);
        const c_bits = try self.source(inst.src2, .bits32);
        const vector_type = try self.ensureFloatVec2();
        const a = self.id();
        try self.emit(&self.body, 12, &.{ vector_type, a, self.ensureGlslStd450(), 62, a_bits });
        const b = self.id();
        try self.emit(&self.body, 12, &.{ vector_type, b, self.ensureGlslStd450(), 62, b_bits });
        const c = self.id();
        try self.emit(&self.body, 12, &.{ vector_type, c, self.ensureGlslStd450(), 62, c_bits });
        const product = self.id();
        try self.emit(&self.body, 133, &.{ vector_type, product, a, b });
        const result = self.id();
        try self.emit(&self.body, 129, &.{ vector_type, result, product, c });
        const packed_bits = self.id();
        try self.emit(&self.body, 12, &.{ self.bits_type, packed_bits, self.ensureGlslStd450(), 58, result });
        try self.destination(inst.dst, .{ .id = packed_bits, .value_type = .bits32 });
    }

    fn convertF16ToF32(self: *Builder, inst: instruction.Instruction) Error!void {
        const bits = try self.source(inst.src0, .bits32);
        try self.destination(inst.dst, .{ .id = try self.unpackF16Low(bits), .value_type = .float32 });
    }

    fn convertF32ToF16(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .float32);
        try self.destination(inst.dst, .{ .id = try self.packF16Low(value), .value_type = .bits32 });
    }

    fn unpackF16Pair(self: *Builder, bits: u32) Error![2]u32 {
        const vector_type = try self.ensureFloatVec2();
        const pair = self.id();
        try self.emit(&self.body, 12, &.{ vector_type, pair, self.ensureGlslStd450(), 62, bits });
        const lo = self.id();
        const hi = self.id();
        try self.emit(&self.body, 81, &.{ self.float_type, lo, pair, 0 });
        try self.emit(&self.body, 81, &.{ self.float_type, hi, pair, 1 });
        return .{ lo, hi };
    }

    fn packF16Pair(self: *Builder, lo: u32, hi: u32) Error!u32 {
        const vector_type = try self.ensureFloatVec2();
        const pair = self.id();
        try self.emit(&self.body, 80, &.{ vector_type, pair, lo, hi });
        const result = self.id();
        try self.emit(&self.body, 12, &.{ self.bits_type, result, self.ensureGlslStd450(), 58, pair });
        return result;
    }

    fn glslFloatUnaryValue(self: *Builder, opcode: u32, value: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 12, &.{ self.float_type, result, self.ensureGlslStd450(), opcode, value });
        return result;
    }

    fn unaryF16(self: *Builder, inst: instruction.Instruction, glsl_opcode: u32) Error!void {
        const value = try self.unpackF16Low(try self.source(inst.src0, .bits32));
        const result = try self.glslFloatUnaryValue(glsl_opcode, value);
        try self.destination(inst.dst, .{ .id = try self.packF16Low(result), .value_type = .bits32 });
    }

    fn reciprocalF16(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.unpackF16Low(try self.source(inst.src0, .bits32));
        const result = self.id();
        try self.emit(&self.body, 136, &.{
            self.float_type,
            result,
            try self.constant(.float32, @bitCast(@as(f32, 1.0))),
            value,
        });
        try self.destination(inst.dst, .{ .id = try self.packF16Low(result), .value_type = .bits32 });
    }

    fn fmaF16(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.unpackF16Low(try self.source(inst.src0, .bits32));
        const b = try self.unpackF16Low(try self.source(inst.src1, .bits32));
        const c = try self.unpackF16Low(try self.source(inst.src2, .bits32));
        const result = self.id();
        try self.emit(&self.body, 12, &.{ self.float_type, result, self.ensureGlslStd450(), 50, a, b, c });
        try self.destination(inst.dst, .{ .id = try self.packF16Low(result), .value_type = .bits32 });
    }

    fn fmacF16(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.unpackF16Low(try self.source(inst.src0, .bits32));
        const b = try self.unpackF16Low(try self.source(inst.src1, .bits32));
        const acc = try self.unpackF16Low(try self.source(inst.dst, .bits32));
        const product = self.id();
        try self.emit(&self.body, 133, &.{ self.float_type, product, a, b });
        const result = self.id();
        try self.emit(&self.body, 129, &.{ self.float_type, result, product, acc });
        try self.destination(inst.dst, .{ .id = try self.packF16Low(result), .value_type = .bits32 });
    }

    fn packedFmacF16(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.unpackF16Pair(try self.source(inst.src0, .bits32));
        const b = try self.unpackF16Pair(try self.source(inst.src1, .bits32));
        const acc = try self.unpackF16Pair(try self.source(inst.dst, .bits32));
        const lo_p = self.id();
        const hi_p = self.id();
        try self.emit(&self.body, 133, &.{ self.float_type, lo_p, a[0], b[0] });
        try self.emit(&self.body, 133, &.{ self.float_type, hi_p, a[1], b[1] });
        const lo = self.id();
        const hi = self.id();
        try self.emit(&self.body, 129, &.{ self.float_type, lo, lo_p, acc[0] });
        try self.emit(&self.body, 129, &.{ self.float_type, hi, hi_p, acc[1] });
        try self.destination(inst.dst, .{ .id = try self.packF16Pair(lo, hi), .value_type = .bits32 });
    }

    fn packedGlslF16(self: *Builder, inst: instruction.Instruction, opcode: u32) Error!void {
        const a = try self.unpackF16Pair(try self.source(inst.src0, .bits32));
        const b = try self.unpackF16Pair(try self.source(inst.src1, .bits32));
        try self.destination(inst.dst, .{
            .id = try self.packF16Pair(
                try self.glslBinaryValue(opcode, .float32, a[0], b[0]),
                try self.glslBinaryValue(opcode, .float32, a[1], b[1]),
            ),
            .value_type = .bits32,
        });
    }

    fn mixSourceF32(self: *Builder, op: operand.Operand) Error!u32 {
        if (op.op_sel) {
            const bits = try self.source(op, .bits32);
            const pair = try self.unpackF16Pair(bits);
            return if (op.op_sel_hi) pair[1] else pair[0];
        }
        return self.source(op, .float32);
    }

    fn insertF16Half(self: *Builder, current: u32, value: u32, high: bool) Error!u32 {
        const packed_half = try self.packF16Low(value);
        if (high) {
            const shifted = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, shifted, packed_half, try self.constant(.bits32, 16) });
            const preserved = try self.andBits(current, 0xffff);
            const result = self.id();
            try self.emit(&self.body, 197, &.{ self.bits_type, result, preserved, shifted });
            return result;
        }
        const preserved = try self.andBits(current, 0xffff_0000);
        const low = try self.andBits(packed_half, 0xffff);
        const result = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, result, preserved, low });
        return result;
    }

    fn madMixF16(self: *Builder, inst: instruction.Instruction, high: bool) Error!void {
        const a = try self.mixSourceF32(inst.src0);
        const b = try self.mixSourceF32(inst.src1);
        const c = try self.mixSourceF32(inst.src2);
        const result = self.id();
        try self.emit(&self.body, 12, &.{ self.float_type, result, self.ensureGlslStd450(), 50, a, b, c });
        const current = try self.source(inst.dst, .bits32);
        try self.destination(inst.dst, .{ .id = try self.insertF16Half(current, result, high), .value_type = .bits32 });
    }

    fn halfU16(self: *Builder, bits: u32, high: bool) Error!u32 {
        return if (high) self.shiftRightBits(bits, 16) else self.andBits(bits, 0xffff);
    }

    fn packU16Pair(self: *Builder, lo: u32, hi: u32) Error!u32 {
        const low = try self.andBits(lo, 0xffff);
        const shifted = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shifted, try self.andBits(hi, 0xffff), try self.constant(.bits32, 16) });
        const result = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, result, low, shifted });
        return result;
    }

    fn packedIntegerBinary(self: *Builder, inst: instruction.Instruction, opcode: u16, signed: bool, reverse: bool) Error!void {
        const a_bits = try self.source(if (reverse) inst.src1 else inst.src0, .bits32);
        const b_bits = try self.source(if (reverse) inst.src0 else inst.src1, .bits32);
        var lo_a = try self.halfU16(a_bits, false);
        var lo_b = try self.halfU16(b_bits, false);
        var hi_a = try self.halfU16(a_bits, true);
        var hi_b = try self.halfU16(b_bits, true);
        const ty: ValueType = if (signed) .sint32 else .bits32;
        if (signed) {
            lo_a = try self.signExtend16(lo_a);
            lo_b = try self.signExtend16(lo_b);
            hi_a = try self.signExtend16(hi_a);
            hi_b = try self.signExtend16(hi_b);
        }
        const lo = self.id();
        const hi = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(ty), lo, lo_a, lo_b });
        try self.emit(&self.body, opcode, &.{ self.typeId(ty), hi, hi_a, hi_b });
        try self.destination(inst.dst, .{ .id = try self.packU16Pair(lo, hi), .value_type = .bits32 });
    }

    fn packedIntegerGlsl(self: *Builder, inst: instruction.Instruction, opcode: u32, signed: bool) Error!void {
        const a_bits = try self.source(inst.src0, .bits32);
        const b_bits = try self.source(inst.src1, .bits32);
        var lo_a = try self.halfU16(a_bits, false);
        var lo_b = try self.halfU16(b_bits, false);
        var hi_a = try self.halfU16(a_bits, true);
        var hi_b = try self.halfU16(b_bits, true);
        const ty: ValueType = if (signed) .sint32 else .bits32;
        if (signed) {
            lo_a = try self.signExtend16(lo_a);
            lo_b = try self.signExtend16(lo_b);
            hi_a = try self.signExtend16(hi_a);
            hi_b = try self.signExtend16(hi_b);
        }
        try self.destination(inst.dst, .{
            .id = try self.packU16Pair(
                try self.glslBinaryValue(opcode, ty, lo_a, lo_b),
                try self.glslBinaryValue(opcode, ty, hi_a, hi_b),
            ),
            .value_type = .bits32,
        });
    }

    fn packedIntegerMad(self: *Builder, inst: instruction.Instruction, signed: bool) Error!void {
        const a_bits = try self.source(inst.src0, .bits32);
        const b_bits = try self.source(inst.src1, .bits32);
        const c_bits = try self.source(inst.src2, .bits32);
        const ty: ValueType = if (signed) .sint32 else .bits32;
        var halves: [2]u32 = undefined;
        for (0..2) |index| {
            const high = index == 1;
            var a = try self.halfU16(a_bits, high);
            var b = try self.halfU16(b_bits, high);
            var c = try self.halfU16(c_bits, high);
            if (signed) {
                a = try self.signExtend16(a);
                b = try self.signExtend16(b);
                c = try self.signExtend16(c);
            }
            const product = self.id();
            try self.emit(&self.body, 132, &.{ self.typeId(ty), product, a, b });
            const sum = self.id();
            try self.emit(&self.body, 128, &.{ self.typeId(ty), sum, product, c });
            halves[index] = sum;
        }
        try self.destination(inst.dst, .{ .id = try self.packU16Pair(halves[0], halves[1]), .value_type = .bits32 });
    }

    fn integer16Binary(self: *Builder, inst: instruction.Instruction, opcode: u16, signed: bool, reverse: bool) Error!void {
        var a = try self.halfU16(try self.source(if (reverse) inst.src1 else inst.src0, .bits32), false);
        var b = try self.halfU16(try self.source(if (reverse) inst.src0 else inst.src1, .bits32), false);
        const ty: ValueType = if (signed) .sint32 else .bits32;
        if (signed) {
            a = try self.signExtend16(a);
            b = try self.signExtend16(b);
        }
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(ty), result, a, b });
        const current = try self.source(inst.dst, .bits32);
        const preserved = try self.andBits(current, 0xffff_0000);
        const low = try self.andBits(result, 0xffff);
        const combined = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, combined, preserved, low });
        try self.destination(inst.dst, .{ .id = combined, .value_type = .bits32 });
    }

    fn integer16Glsl(self: *Builder, inst: instruction.Instruction, opcode: u32, signed: bool) Error!void {
        var a = try self.halfU16(try self.source(inst.src0, .bits32), false);
        var b = try self.halfU16(try self.source(inst.src1, .bits32), false);
        const ty: ValueType = if (signed) .sint32 else .bits32;
        if (signed) {
            a = try self.signExtend16(a);
            b = try self.signExtend16(b);
        }
        const result = try self.glslBinaryValue(opcode, ty, a, b);
        const current = try self.source(inst.dst, .bits32);
        const preserved = try self.andBits(current, 0xffff_0000);
        const low = try self.andBits(result, 0xffff);
        const combined = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, combined, preserved, low });
        try self.destination(inst.dst, .{ .id = combined, .value_type = .bits32 });
    }

    fn currentLaneId(self: *Builder) Error!u32 {
        if (self.local_invocation_index == 0) return self.constant(.bits32, 0);
        const invocation = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, invocation, self.local_invocation_index });
        return self.andBits(invocation, 63);
    }

    fn permlane(self: *Builder, inst: instruction.Instruction, exchange: bool) Error!void {
        const value = try self.source(inst.src0, .bits32);
        const lane = try self.currentLaneId();
        const in_high = self.id();
        try self.emit(&self.body, 172, &.{ self.bool_type, in_high, lane, try self.constant(.bits32, 15) });
        const select = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            select,
            in_high,
            try self.source(inst.src2, .bits32),
            try self.source(inst.src1, .bits32),
        });
        const group = try self.andBits(lane, 0xffff_fff0);
        const index_base = if (exchange) blk: {
            const flipped = self.id();
            try self.emit(&self.body, 198, &.{ self.bits_type, flipped, group, try self.constant(.bits32, 16) });
            break :blk flipped;
        } else group;
        const dest_lane = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, dest_lane, index_base, try self.andBits(select, 15) });
        const result = self.id();
        try self.emit(&self.body, 345, &.{
            self.bits_type,
            result,
            try self.constant(.bits32, 3),
            value,
            dest_lane,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn maskedBitCount(self: *Builder, inst: instruction.Instruction, high_half: bool) Error!void {
        const bits = try self.source(inst.src0, .bits32);
        const addend = try self.source(inst.src1, .bits32);
        const lane = try self.currentLaneId();
        const relative = if (high_half) blk: {
            const shifted = self.id();
            try self.emit(&self.body, 130, &.{ self.bits_type, shifted, lane, try self.constant(.bits32, 32) });
            break :blk shifted;
        } else lane;
        const one = try self.constant(.bits32, 1);
        const shifted = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shifted, one, relative });
        const mask = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, mask, shifted, one });
        const in_range = self.id();
        try self.emit(&self.body, 176, &.{
            self.bool_type,
            in_range,
            relative,
            try self.constant(.bits32, 32),
        });
        const selected_mask = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, selected_mask, in_range, mask, try self.constant(.bits32, 0) });
        const masked = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, masked, bits, selected_mask });
        const count = self.id();
        try self.emit(&self.body, 205, &.{ self.bits_type, count, masked });
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, result, count, addend });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn popCountAdd(self: *Builder, inst: instruction.Instruction) Error!void {
        const bits = try self.source(inst.src0, .bits32);
        const addend = try self.source(inst.src1, .bits32);
        const count = self.id();
        try self.emit(&self.body, 205, &.{ self.bits_type, count, bits });
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, result, count, addend });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn findFirstBit(self: *Builder, inst: instruction.Instruction, from_high: bool) Error!void {
        const bits = try self.source(inst.src0, .bits32);
        const result = self.id();
        try self.emit(&self.body, 12, &.{
            self.signed_type,
            result,
            self.ensureGlslStd450(),
            if (from_high) @as(u32, 75) else 73,
            bits,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = .sint32 });
    }

    fn findFirstBit64(self: *Builder, inst: instruction.Instruction, from_high: bool) Error!void {
        const pair = try self.sourcePair(inst.src0);
        const zero = try self.constant(.bits32, 0);
        const minus_one = try self.constant(.sint32, 0xffff_ffff);
        const thirty_two = try self.constant(.sint32, 32);
        const low_zero = self.id();
        const high_zero = self.id();
        try self.emit(&self.body, 170, &.{ self.bool_type, low_zero, pair[0], zero });
        try self.emit(&self.body, 170, &.{ self.bool_type, high_zero, pair[1], zero });
        const both_zero = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, both_zero, low_zero, high_zero });
        const glsl = self.ensureGlslStd450();
        const op: u32 = if (from_high) 75 else 73;
        const low_pos = self.id();
        const high_pos = self.id();
        try self.emit(&self.body, 12, &.{ self.signed_type, low_pos, glsl, op, pair[0] });
        try self.emit(&self.body, 12, &.{ self.signed_type, high_pos, glsl, op, pair[1] });
        const result = if (from_high) blk: {
            const thirty_one = try self.constant(.sint32, 31);
            const from_top_high = self.id();
            try self.emit(&self.body, 130, &.{ self.signed_type, from_top_high, thirty_one, high_pos });
            const from_top_low = self.id();
            try self.emit(&self.body, 130, &.{ self.signed_type, from_top_low, try self.constant(.sint32, 63), low_pos });
            const chosen = self.id();
            try self.emit(&self.body, 169, &.{ self.signed_type, chosen, high_zero, from_top_low, from_top_high });
            break :blk chosen;
        } else blk: {
            const high_adjusted = self.id();
            try self.emit(&self.body, 128, &.{ self.signed_type, high_adjusted, high_pos, thirty_two });
            const chosen = self.id();
            try self.emit(&self.body, 169, &.{ self.signed_type, chosen, low_zero, high_adjusted, low_pos });
            break :blk chosen;
        };
        const final_result = self.id();
        try self.emit(&self.body, 169, &.{ self.signed_type, final_result, both_zero, minus_one, result });
        try self.destination(inst.dst, .{ .id = final_result, .value_type = .sint32 });
    }

    fn scalarPopCount64(self: *Builder, inst: instruction.Instruction) Error!void {
        const pair = try self.sourcePair(inst.src0);
        const low = self.id();
        const high = self.id();
        try self.emit(&self.body, 205, &.{ self.bits_type, low, pair[0] });
        try self.emit(&self.body, 205, &.{ self.bits_type, high, pair[1] });
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, result, low, high });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn smearNibbleGroups(self: *Builder, bits: u32) Error!u32 {
        const shift1 = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, shift1, bits, try self.constant(.bits32, 1) });
        const any1 = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, any1, bits, shift1 });
        const shift2 = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, shift2, any1, try self.constant(.bits32, 2) });
        const any2 = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, any2, any1, shift2 });
        const groups = try self.andBits(any2, 0x1111_1111);
        const smeared = self.id();
        try self.emit(&self.body, 132, &.{ self.bits_type, smeared, groups, try self.constant(.bits32, 0xf) });
        return smeared;
    }

    fn wholeQuadMask64(self: *Builder, inst: instruction.Instruction) Error!void {
        const pair = try self.sourcePair(inst.src0);
        try self.destinationPair(inst.dst, .{
            try self.smearNibbleGroups(pair[0]),
            try self.smearNibbleGroups(pair[1]),
        });
    }

    fn vectorCompareClassF32(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .float32);
        const class_mask = try self.source(inst.src1, .bits32);
        const bits = try self.convert(.{ .id = value, .value_type = .float32 }, .bits32);
        const exponent = try self.andBits(try self.shiftRightBits(bits, 23), 0xff);
        const mantissa = try self.andBits(bits, 0x7f_ffff);
        const sign = try self.shiftRightBits(bits, 31);
        const zero = try self.constant(.bits32, 0);
        const exp_255 = try self.constant(.bits32, 255);
        const exp_is_zero = self.id();
        const exp_is_255 = self.id();
        const mant_is_zero = self.id();
        try self.emit(&self.body, 170, &.{ self.bool_type, exp_is_zero, exponent, zero });
        try self.emit(&self.body, 170, &.{ self.bool_type, exp_is_255, exponent, exp_255 });
        try self.emit(&self.body, 170, &.{ self.bool_type, mant_is_zero, mantissa, zero });
        const mant_nonzero = self.id();
        try self.emit(&self.body, 171, &.{ self.bool_type, mant_nonzero, mantissa, zero });
        const is_nan = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, is_nan, exp_is_255, mant_nonzero });
        const quiet_bit = try self.andBits(try self.shiftRightBits(mantissa, 22), 1);
        const is_qnan_bit = self.id();
        try self.emit(&self.body, 171, &.{ self.bool_type, is_qnan_bit, quiet_bit, zero });
        const is_qnan = self.id();
        const is_snan = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, is_qnan, is_nan, is_qnan_bit });
        const not_qnan = self.id();
        try self.emit(&self.body, 168, &.{ self.bool_type, not_qnan, is_qnan_bit });
        try self.emit(&self.body, 167, &.{ self.bool_type, is_snan, is_nan, not_qnan });
        const is_inf = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, is_inf, exp_is_255, mant_is_zero });
        const is_zero = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, is_zero, exp_is_zero, mant_is_zero });
        const is_denorm = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, is_denorm, exp_is_zero, mant_nonzero });
        const not_special_exp = self.id();
        const not_zero_exp = self.id();
        try self.emit(&self.body, 168, &.{ self.bool_type, not_special_exp, exp_is_255 });
        try self.emit(&self.body, 168, &.{ self.bool_type, not_zero_exp, exp_is_zero });
        const is_normal = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, is_normal, not_special_exp, not_zero_exp });
        const is_neg = self.id();
        try self.emit(&self.body, 171, &.{ self.bool_type, is_neg, sign, zero });
        const is_pos = self.id();
        try self.emit(&self.body, 168, &.{ self.bool_type, is_pos, is_neg });
        const classes = [_]struct { cond: u32, bit: u32 }{
            .{ .cond = is_snan, .bit = 0 },
            .{ .cond = is_qnan, .bit = 1 },
            .{ .cond = is_inf, .bit = 2 },
            .{ .cond = is_normal, .bit = 3 },
            .{ .cond = is_denorm, .bit = 4 },
            .{ .cond = is_zero, .bit = 5 },
            .{ .cond = is_zero, .bit = 6 },
            .{ .cond = is_denorm, .bit = 7 },
            .{ .cond = is_normal, .bit = 8 },
            .{ .cond = is_inf, .bit = 9 },
        };
        var matched = try self.constant(.bits32, 0);
        for (classes, 0..) |entry, index| {
            const signed = index == 2 or index == 3 or index == 4 or index == 5;
            const polarity = if (signed) is_neg else if (index >= 6) is_pos else try self.constantBool(true);
            const kind = self.id();
            try self.emit(&self.body, 167, &.{ self.bool_type, kind, entry.cond, polarity });
            const bit = try self.andBits(try self.shiftRightBits(class_mask, entry.bit), 1);
            const bit_set = self.id();
            try self.emit(&self.body, 171, &.{ self.bool_type, bit_set, bit, zero });
            const hit = self.id();
            try self.emit(&self.body, 167, &.{ self.bool_type, hit, kind, bit_set });
            const next = self.id();
            try self.emit(&self.body, 169, &.{
                self.bits_type,
                next,
                hit,
                try self.constant(.bits32, 1),
                matched,
            });
            matched = next;
        }
        const condition = self.id();
        try self.emit(&self.body, 171, &.{ self.bool_type, condition, matched, zero });
        try self.vectorConditionDestination(inst, condition);
    }

    fn constantBool(self: *Builder, value: bool) Error!u32 {
        const result = self.id();
        const zero = try self.constant(.bits32, 0);
        try self.emit(&self.body, if (value) 170 else 171, &.{ self.bool_type, result, zero, zero });
        return result;
    }

    const Cmp64 = enum { eq, ne, gt_u };

    fn vectorComparison64(self: *Builder, inst: instruction.Instruction, kind: Cmp64) Error!void {
        const a = try self.sourcePair(inst.src0);
        const b = try self.sourcePair(inst.src1);
        const lo_eq = self.id();
        const hi_eq = self.id();
        try self.emit(&self.body, 170, &.{ self.bool_type, lo_eq, a[0], b[0] });
        try self.emit(&self.body, 170, &.{ self.bool_type, hi_eq, a[1], b[1] });
        const equal = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, equal, lo_eq, hi_eq });
        const condition = switch (kind) {
            .eq => equal,
            .ne => blk: {
                const ne = self.id();
                try self.emit(&self.body, 168, &.{ self.bool_type, ne, equal });
                break :blk ne;
            },
            .gt_u => blk: {
                const hi_gt = self.id();
                try self.emit(&self.body, 172, &.{ self.bool_type, hi_gt, a[1], b[1] });
                const lo_gt = self.id();
                try self.emit(&self.body, 172, &.{ self.bool_type, lo_gt, a[0], b[0] });
                const hi_eq_and_lo_gt = self.id();
                try self.emit(&self.body, 167, &.{ self.bool_type, hi_eq_and_lo_gt, hi_eq, lo_gt });
                const gt = self.id();
                try self.emit(&self.body, 166, &.{ self.bool_type, gt, hi_gt, hi_eq_and_lo_gt });
                break :blk gt;
            },
        };
        try self.vectorConditionDestination(inst, condition);
    }

    fn bufferAtomicFloat(self: *Builder, inst: instruction.Instruction, is_min: bool) Error!void {
        if (!try self.hasBufferStorage(inst)) {
            if (inst.globally_coherent) {
                try self.destination(inst.dst, .{
                    .id = try self.constant(.bits32, 0),
                    .value_type = .bits32,
                });
            }
            return;
        }
        const value_bits = try self.source(inst.dst, .bits32);
        const value = try self.convert(.{ .id = value_bits, .value_type = .bits32 }, .float32);
        const pointer = try self.bufferWordPointer(try self.bufferAddress(inst), 0);
        const scope = try self.constant(.bits32, 1);
        const semantics = try self.constant(.bits32, 0);
        const original = self.id();
        try self.emit(&self.body, 227, &.{ self.bits_type, original, pointer, scope, semantics }); // OpAtomicLoad
        const current = try self.convert(.{ .id = original, .value_type = .bits32 }, .float32);
        const selected = try self.glslBinaryValue(if (is_min) 37 else 40, .float32, current, value);
        const desired = try self.convert(.{ .id = selected, .value_type = .float32 }, .bits32);
        try self.emit(&self.body, 228, &.{ pointer, scope, semantics, desired }); // OpAtomicStore
        if (inst.globally_coherent) {
            try self.destination(inst.dst, .{ .id = original, .value_type = .bits32 });
        }
        try self.emit(&self.body, 225, &.{
            try self.constant(.bits32, 1),
            try self.constant(.bits32, 0x48),
        });
    }

    fn alignBit(self: *Builder, inst: instruction.Instruction, byte_shift: bool) Error!void {
        const high = try self.source(inst.src0, .bits32);
        const low = try self.source(inst.src1, .bits32);
        var shift = try self.source(inst.src2, .bits32);
        if (byte_shift) {
            shift = try self.andBits(shift, 3);
            const scaled = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, scaled, shift, try self.constant(.bits32, 3) });
            shift = scaled;
        } else {
            shift = try self.andBits(shift, 31);
        }
        const low_part = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, low_part, low, shift });
        const left_amount = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, left_amount, try self.constant(.bits32, 32), shift });
        const high_part = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, high_part, high, left_amount });
        const shifted = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, shifted, low_part, high_part });
        const zero_shift = self.id();
        try self.emit(&self.body, 170, &.{ self.bool_type, zero_shift, shift, try self.constant(.bits32, 0) });
        const result = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, result, zero_shift, low, shifted });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn minMax3Integer(self: *Builder, inst: instruction.Instruction, opcode: isa.Opcode) Error!void {
        const signed = opcode == .v_min3_i32 or opcode == .v_max3_i32 or opcode == .v_med3_i32 or opcode == .v_med3_i16;
        const ty: ValueType = if (signed) .sint32 else .bits32;
        const min_op: u32 = if (signed) 39 else 38;
        const max_op: u32 = if (signed) 42 else 41;
        const a = try self.source(inst.src0, ty);
        const b = try self.source(inst.src1, ty);
        const c = try self.source(inst.src2, ty);
        const result = switch (opcode) {
            .v_min3_i32, .v_min3_u32 => try self.glslBinaryValue(min_op, ty, try self.glslBinaryValue(min_op, ty, a, b), c),
            .v_max3_i32, .v_max3_u32 => try self.glslBinaryValue(max_op, ty, try self.glslBinaryValue(max_op, ty, a, b), c),
            else => blk: {
                const low = try self.glslBinaryValue(min_op, ty, a, b);
                const high = try self.glslBinaryValue(max_op, ty, a, b);
                const upper_low = try self.glslBinaryValue(min_op, ty, high, c);
                break :blk try self.glslBinaryValue(max_op, ty, low, upper_low);
            },
        };
        try self.destination(inst.dst, .{ .id = result, .value_type = ty });
    }

    fn packConvert(self: *Builder, inst: instruction.Instruction, kind: enum { u16, i16, unorm, snorm }) Error!void {
        const a = try self.source(inst.src0, if (kind == .u16 or kind == .i16) .bits32 else .float32);
        const b = try self.source(inst.src1, if (kind == .u16 or kind == .i16) .bits32 else .float32);
        const lo: u32, const hi: u32 = switch (kind) {
            .u16 => .{ a, b },
            .i16 => .{ a, b },
            .unorm => .{
                try self.floatToUnorm16(a),
                try self.floatToUnorm16(b),
            },
            .snorm => .{
                try self.floatToSnorm16(a),
                try self.floatToSnorm16(b),
            },
        };
        try self.destination(inst.dst, .{ .id = try self.packU16Pair(lo, hi), .value_type = .bits32 });
    }

    fn floatToUnorm16(self: *Builder, value: u32) Error!u32 {
        const clamped = try self.glslBinaryValue(40, .float32, value, try self.constant(.float32, 0));
        const one = try self.constant(.float32, @bitCast(@as(f32, 1.0)));
        const saturated = try self.glslBinaryValue(37, .float32, clamped, one);
        const scaled = self.id();
        try self.emit(&self.body, 133, &.{ self.float_type, scaled, saturated, try self.constant(.float32, @bitCast(@as(f32, 65535.0))) });
        const rounded = try self.glslFloatUnaryValue(2, scaled);
        const as_uint = self.id();
        try self.emit(&self.body, 109, &.{ self.bits_type, as_uint, rounded });
        return as_uint;
    }

    fn floatToSnorm16(self: *Builder, value: u32) Error!u32 {
        const neg_one = try self.constant(.float32, @bitCast(@as(f32, -1.0)));
        const one = try self.constant(.float32, @bitCast(@as(f32, 1.0)));
        const low = try self.glslBinaryValue(40, .float32, value, neg_one);
        const saturated = try self.glslBinaryValue(37, .float32, low, one);
        const scaled = self.id();
        try self.emit(&self.body, 133, &.{ self.float_type, scaled, saturated, try self.constant(.float32, @bitCast(@as(f32, 32767.0))) });
        const rounded = try self.glslFloatUnaryValue(2, scaled);
        const as_int = self.id();
        try self.emit(&self.body, 110, &.{ self.signed_type, as_int, rounded });
        return as_int;
    }

    fn packU8Float(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .float32);
        const slot = try self.andBits(try self.source(inst.src1, .bits32), 3);
        const current = try self.source(inst.dst, .bits32);
        const unorm = try self.floatToUnorm16(value);
        const byte = try self.andBits(unorm, 0xff);
        const shift = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shift, slot, try self.constant(.bits32, 3) });
        const inserted = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, inserted, byte, shift });
        const mask = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, mask, try self.constant(.bits32, 0xff), shift });
        const inverse = self.id();
        try self.emit(&self.body, 200, &.{ self.bits_type, inverse, mask });
        const preserved = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, preserved, current, inverse });
        const result = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, result, preserved, inserted });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn convertHalfInteger(self: *Builder, inst: instruction.Instruction, to_float: bool, signed: bool) Error!void {
        if (to_float) {
            var bits = try self.halfU16(try self.source(inst.src0, .bits32), false);
            if (signed) bits = try self.signExtend16(bits);
            const converted = self.id();
            try self.emit(&self.body, if (signed) 111 else 112, &.{ self.float_type, converted, bits });
            try self.destination(inst.dst, .{ .id = try self.packF16Low(converted), .value_type = .bits32 });
        } else {
            const value = try self.unpackF16Low(try self.source(inst.src0, .bits32));
            const converted = self.id();
            try self.emit(&self.body, if (signed) 110 else 109, &.{ self.typeId(if (signed) .sint32 else .bits32), converted, value });
            try self.destination(inst.dst, .{ .id = converted, .value_type = if (signed) .sint32 else .bits32 });
        }
    }

    fn roundToSigned(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .float32);
        const rounded = try self.glslFloatUnaryValue(2, value);
        const result = self.id();
        try self.emit(&self.body, 110, &.{ self.signed_type, result, rounded });
        try self.destination(inst.dst, .{ .id = result, .value_type = .sint32 });
    }

    fn frexpMantissa(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .float32);
        const abs = try self.glslFloatUnaryValue(4, value);
        const log2 = try self.glslFloatUnaryValue(30, abs);
        const exponent = try self.glslFloatUnaryValue(8, log2);
        const scale = try self.glslFloatUnaryValue(29, exponent);
        const mantissa = self.id();
        try self.emit(&self.body, 136, &.{ self.float_type, mantissa, value, scale });
        const zero = try self.constant(.float32, 0);
        const is_zero = self.id();
        try self.emit(&self.body, 180, &.{ self.bool_type, is_zero, value, zero });
        const result = self.id();
        try self.emit(&self.body, 169, &.{ self.float_type, result, is_zero, zero, mantissa });
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn frexpExponent(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .float32);
        const abs = try self.glslFloatUnaryValue(4, value);
        const log2 = try self.glslFloatUnaryValue(30, abs);
        const exponent = try self.glslFloatUnaryValue(8, log2);
        const plus_one = self.id();
        try self.emit(&self.body, 129, &.{ self.float_type, plus_one, exponent, try self.constant(.float32, @bitCast(@as(f32, 1.0))) });
        const as_int = self.id();
        try self.emit(&self.body, 110, &.{ self.signed_type, as_int, plus_one });
        const zero = try self.constant(.float32, 0);
        const is_zero = self.id();
        try self.emit(&self.body, 180, &.{ self.bool_type, is_zero, value, zero });
        const result = self.id();
        try self.emit(&self.body, 169, &.{ self.signed_type, result, is_zero, try self.constant(.sint32, 0), as_int });
        try self.destination(inst.dst, .{ .id = result, .value_type = .sint32 });
    }

    fn dot2PackedF16(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.unpackF16Pair(try self.source(inst.src0, .bits32));
        const b = try self.unpackF16Pair(try self.source(inst.src1, .bits32));
        const acc = try self.source(inst.dst, .float32);
        const p0 = self.id();
        const p1 = self.id();
        try self.emit(&self.body, 133, &.{ self.float_type, p0, a[0], b[0] });
        try self.emit(&self.body, 133, &.{ self.float_type, p1, a[1], b[1] });
        const sum = self.id();
        try self.emit(&self.body, 129, &.{ self.float_type, sum, p0, p1 });
        const result = self.id();
        try self.emit(&self.body, 129, &.{ self.float_type, result, sum, acc });
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
    }

    fn shift64(self: *Builder, inst: instruction.Instruction, arithmetic: bool) Error!void {
        const value = try self.sourcePair(inst.src1);
        const amount = try self.andBits(try self.source(inst.src0, .bits32), 63);
        const low = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, low, value[0], amount });
        const high_shift = self.id();
        try self.emit(&self.body, if (arithmetic) @as(u16, 195) else 194, &.{
            if (arithmetic) self.signed_type else self.bits_type,
            high_shift,
            value[1],
            amount,
        });
        const cross_amount = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, cross_amount, try self.constant(.bits32, 32), amount });
        const cross = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, cross, value[1], cross_amount });
        const combined_low = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, combined_low, low, cross });
        const ge_32 = self.id();
        try self.emit(&self.body, 174, &.{ self.bool_type, ge_32, amount, try self.constant(.bits32, 32) });
        const low_result = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, low_result, ge_32, high_shift, combined_low });
        const zero = try self.constant(.bits32, 0);
        const high_result = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, high_result, ge_32, zero, high_shift });
        try self.destinationPair(inst.dst, .{ low_result, high_result });
    }

    fn shiftLeft64Vector(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.sourcePair(inst.src1);
        const amount = try self.andBits(try self.source(inst.src0, .bits32), 63);
        const high = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, high, value[1], amount });
        const low = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, low, value[0], amount });
        const cross_amount = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, cross_amount, try self.constant(.bits32, 32), amount });
        const cross = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, cross, value[0], cross_amount });
        const combined_high = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, combined_high, high, cross });
        const ge_32 = self.id();
        try self.emit(&self.body, 174, &.{ self.bool_type, ge_32, amount, try self.constant(.bits32, 32) });
        const high_result = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, high_result, ge_32, low, combined_high });
        const zero = try self.constant(.bits32, 0);
        const low_result = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, low_result, ge_32, zero, low });
        try self.destinationPair(inst.dst, .{ low_result, high_result });
    }

    fn mad24(self: *Builder, inst: instruction.Instruction, signed: bool) Error!void {
        var a = try self.source(inst.src0, if (signed) .sint32 else .bits32);
        var b = try self.source(inst.src1, if (signed) .sint32 else .bits32);
        const c = try self.source(inst.src2, if (signed) .sint32 else .bits32);
        if (signed) {
            const shift = try self.constant(.bits32, 8);
            const a_shifted = self.id();
            try self.emit(&self.body, 196, &.{ self.signed_type, a_shifted, a, shift });
            a = self.id();
            try self.emit(&self.body, 195, &.{ self.signed_type, a, a_shifted, shift });
            const b_shifted = self.id();
            try self.emit(&self.body, 196, &.{ self.signed_type, b_shifted, b, shift });
            b = self.id();
            try self.emit(&self.body, 195, &.{ self.signed_type, b, b_shifted, shift });
        } else {
            a = try self.andBits(a, 0x00ff_ffff);
            b = try self.andBits(b, 0x00ff_ffff);
        }
        const ty: ValueType = if (signed) .sint32 else .bits32;
        const product_id = self.id();
        try self.emit(&self.body, 132, &.{ self.typeId(ty), product_id, a, b });
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.typeId(ty), result, product_id, c });
        try self.destination(inst.dst, .{ .id = result, .value_type = ty });
    }

    fn madU64U32(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const add_low = try self.source(inst.src2, .bits32);
        const add_high = try self.source(try consecutiveRegister(inst.src2, 1), .bits32);
        const low_product = try self.multiplyBits(a, b);
        const high_product = try self.multiplyHighUnsignedBits(a, b);
        const low = try self.addBits(low_product, add_low);
        const carry = self.id();
        try self.emit(&self.body, 176, &.{ self.bool_type, carry, low, low_product });
        const carry_bits = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            carry_bits,
            carry,
            try self.constant(.bits32, 1),
            try self.constant(.bits32, 0),
        });
        const high = try self.addBits(try self.addBits(high_product, add_high), carry_bits);
        try self.destinationPair(inst.dst, .{ low, high });
    }

    fn vectorSubBorrow(self: *Builder, inst: instruction.Instruction) Error!void {
        var first = inst.src0;
        var second = inst.src1;
        first.absolute = false;
        first.negate = false;
        second.absolute = false;
        second.negate = false;
        const a = try self.source(first, .bits32);
        const b = try self.source(second, .bits32);
        const borrow_source = if (inst.src2.kind == .unknown)
            try self.source(.{ .kind = .vcc_lo }, .bits32)
        else
            try self.source(inst.src2, .bits32);
        const borrow = try self.andBits(borrow_source, 1);
        const partial = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, partial, b, a });
        const partial_borrow = self.id();
        try self.emit(&self.body, 176, &.{ self.bool_type, partial_borrow, b, a });
        const result = self.id();
        try self.emit(&self.body, 130, &.{ self.bits_type, result, partial, borrow });
        const extra_borrow = self.id();
        try self.emit(&self.body, 176, &.{ self.bool_type, extra_borrow, partial, borrow });
        const borrow_out = self.id();
        try self.emit(&self.body, 166, &.{ self.bool_type, borrow_out, partial_borrow, extra_borrow });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
        var carry_inst = inst;
        carry_inst.dst = inst.dst2;
        try self.vectorConditionDestination(carry_inst, borrow_out);
    }

    fn xnor32(self: *Builder, inst: instruction.Instruction) Error!void {
        const a = try self.source(inst.src0, .bits32);
        const b = try self.source(inst.src1, .bits32);
        const xored = self.id();
        try self.emit(&self.body, 198, &.{ self.bits_type, xored, a, b });
        const result = self.id();
        try self.emit(&self.body, 200, &.{ self.bits_type, result, xored });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn scalarPopCount(self: *Builder, inst: instruction.Instruction) Error!void {
        const bits = try self.source(inst.src0, .bits32);
        const result = self.id();
        try self.emit(&self.body, 205, &.{ self.bits_type, result, bits });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn bitSet(self: *Builder, inst: instruction.Instruction, set: bool) Error!void {
        const bit = try self.andBits(try self.source(inst.src0, .bits32), 31);
        const one = try self.constant(.bits32, 1);
        const mask = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, mask, one, bit });
        const current = try self.source(inst.dst, .bits32);
        const result = self.id();
        if (set) {
            try self.emit(&self.body, 197, &.{ self.bits_type, result, current, mask });
        } else {
            const inverse = self.id();
            try self.emit(&self.body, 200, &.{ self.bits_type, inverse, mask });
            try self.emit(&self.body, 199, &.{ self.bits_type, result, current, inverse });
        }
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn bitReplicate(self: *Builder, inst: instruction.Instruction) Error!void {
        const bits = try self.source(inst.src0, .bits32);
        var low = try self.constant(.bits32, 0);
        var high = try self.constant(.bits32, 0);
        var index: u32 = 0;
        while (index < 32) : (index += 1) {
            const bit = try self.andBits(try self.shiftRightBits(bits, index), 1);
            const pair = self.id();
            try self.emit(&self.body, 132, &.{ self.bits_type, pair, bit, try self.constant(.bits32, 3) });
            const shifted = self.id();
            const dest_shift = (index % 16) * 2;
            try self.emit(&self.body, 196, &.{ self.bits_type, shifted, pair, try self.constant(.bits32, dest_shift) });
            if (index < 16) {
                const next = self.id();
                try self.emit(&self.body, 197, &.{ self.bits_type, next, low, shifted });
                low = next;
            } else {
                const next = self.id();
                try self.emit(&self.body, 197, &.{ self.bits_type, next, high, shifted });
                high = next;
            }
        }
        try self.destinationPair(inst.dst, .{ low, high });
    }

    fn scalarCompare64(self: *Builder, inst: instruction.Instruction, equal: bool) Error!void {
        const a = try self.sourcePair(inst.src0);
        const b = try self.sourcePair(inst.src1);
        const lo = self.id();
        const hi = self.id();
        try self.emit(&self.body, 170, &.{ self.bool_type, lo, a[0], b[0] });
        try self.emit(&self.body, 170, &.{ self.bool_type, hi, a[1], b[1] });
        const both = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, both, lo, hi });
        if (equal) {
            self.scc = both;
        } else {
            const ne = self.id();
            try self.emit(&self.body, 168, &.{ self.bool_type, ne, both });
            self.scc = ne;
        }
    }

    fn dsSwizzle(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .bits32);
        const pattern: u32 = @bitCast(inst.memory_offset);
        if (pattern & 0x8000 != 0) {
            try self.destination(inst.dst, .{ .id = value, .value_type = .bits32 });
            return;
        }
        const lane = try self.currentLaneId();
        const and_mask = try self.constant(.bits32, (pattern >> 10) & 0x1f);
        const or_mask = try self.constant(.bits32, (pattern >> 5) & 0x1f);
        const xor_mask = try self.constant(.bits32, pattern & 0x1f);
        const masked = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, masked, lane, and_mask });
        const ored = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, ored, masked, or_mask });
        const dest_lane = self.id();
        try self.emit(&self.body, 198, &.{ self.bits_type, dest_lane, ored, xor_mask });
        const result = self.id();
        try self.emit(&self.body, 345, &.{
            self.bits_type,
            result,
            try self.constant(.bits32, 3),
            value,
            dest_lane,
        });
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn imageGetResinfo(self: *Builder, inst: instruction.Instruction) Error!void {
        self.uses_image_query = true;
        if (inst.src1.kind != .sgpr or inst.data_mask == 0) return Error.UnsupportedOpcode;
        const lod = if (inst.src0.kind == .vgpr)
            try self.source(try imageAddressOperand(inst, 0), .bits32)
        else
            try self.constant(.bits32, 0);

        var width = try self.constant(.bits32, 1);
        var height = try self.constant(.bits32, 1);
        var depth = try self.constant(.bits32, 1);
        var levels = try self.constant(.bits32, 1);

        if (inst.src2.kind == .sgpr) {
            if (self.sampledImageBinding(inst.src1.reg, inst.src2.reg, inst.pc)) |binding| {
                const dim = sampledImageDimensionIndex(binding.dimension);
                if (self.sampled_image_arrays[dim] != 0 and self.sampled_image_image_types[dim] != 0) {
                    const pointer = self.id();
                    try self.emit(&self.body, 65, &.{
                        self.sampled_image_pointer_types[dim],
                        pointer,
                        self.sampled_image_arrays[dim],
                        try self.constant(.bits32, binding.descriptor_index),
                    });
                    const sampled = self.id();
                    try self.emit(&self.body, 61, &.{ self.sampled_image_types[dim], sampled, pointer });
                    const image = self.id();
                    try self.emit(&self.body, 100, &.{ self.sampled_image_image_types[dim], image, sampled });
                    const size_type: u32 = if (binding.dimension == .two_d)
                        try self.ensureBitsVec2()
                    else
                        self.vector3_bits_type;
                    if (size_type != 0) {
                        const size = self.id();
                        try self.emit(&self.body, 107, &.{ size_type, size, image, lod });
                        width = self.id();
                        try self.emit(&self.body, 81, &.{ self.bits_type, width, size, 0 });
                        height = self.id();
                        try self.emit(&self.body, 81, &.{ self.bits_type, height, size, 1 });
                        if (binding.dimension != .two_d and self.vector3_bits_type != 0) {
                            depth = self.id();
                            try self.emit(&self.body, 81, &.{ self.bits_type, depth, size, 2 });
                        }
                    }
                    levels = self.id();
                    try self.emit(&self.body, 106, &.{ self.bits_type, levels, image });
                }
            }
        } else if (self.storageImageBinding(inst.src1.reg, inst.pc)) |binding| {
            const image = try self.loadStorageImage(binding);
            const size_type: u32 = if (binding.dimension == .two_d)
                try self.ensureBitsVec2()
            else
                self.vector3_bits_type;
            if (size_type != 0) {
                const size = self.id();
                try self.emit(&self.body, 104, &.{ size_type, size, image });
                width = self.id();
                try self.emit(&self.body, 81, &.{ self.bits_type, width, size, 0 });
                height = self.id();
                try self.emit(&self.body, 81, &.{ self.bits_type, height, size, 1 });
                if (binding.dimension == .three_d and self.vector3_bits_type != 0) {
                    depth = self.id();
                    try self.emit(&self.body, 81, &.{ self.bits_type, depth, size, 2 });
                }
            }
        }

        const components = [_]u32{ width, height, depth, levels };
        var destination_index: u32 = 0;
        for (components, 0..) |value, component| {
            const bit = @as(u4, 1) << @intCast(component);
            if (inst.data_mask & bit == 0) continue;
            try self.destination(
                try consecutiveRegister(inst.dst, destination_index),
                .{ .id = value, .value_type = .bits32 },
            );
            destination_index += 1;
        }
    }

    fn imageGetLod(self: *Builder, inst: instruction.Instruction) Error!void {
        self.uses_image_query = true;
        if (self.stage != .fragment or inst.src0.kind != .vgpr or inst.src1.kind != .sgpr or
            inst.src2.kind != .sgpr or inst.data_mask == 0)
        {
            var destination_index: u32 = 0;
            for (0..4) |component| {
                const bit = @as(u4, 1) << @intCast(component);
                if (inst.data_mask & bit == 0) continue;
                try self.destination(
                    try consecutiveRegister(inst.dst, destination_index),
                    .{ .id = try self.constant(.float32, 0), .value_type = .float32 },
                );
                destination_index += 1;
            }
            return;
        }
        const binding = self.sampledImageBinding(inst.src1.reg, inst.src2.reg, inst.pc) orelse {
            return Error.InvalidStorageBinding;
        };
        const dim = sampledImageDimensionIndex(binding.dimension);
        const x = try self.source(try imageAddressOperand(inst, 0), .float32);
        const y = try self.source(try imageAddressOperand(inst, 1), .float32);
        const coordinates = self.id();
        if (binding.dimension == .two_d) {
            try self.emit(&self.body, 80, &.{ try self.ensureFloatVec2(), coordinates, x, y });
        } else {
            if (self.vector3_type == 0) {
                var destination_index: u32 = 0;
                for (0..2) |component| {
                    const bit = @as(u4, 1) << @intCast(component);
                    if (inst.data_mask & bit == 0) continue;
                    try self.destination(
                        try consecutiveRegister(inst.dst, destination_index),
                        .{ .id = try self.constant(.float32, 0), .value_type = .float32 },
                    );
                    destination_index += 1;
                }
                return;
            }
            const z = try self.source(try imageAddressOperand(inst, 2), .float32);
            try self.emit(&self.body, 80, &.{ self.vector3_type, coordinates, x, y, z });
        }
        const pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.sampled_image_pointer_types[dim],
            pointer,
            self.sampled_image_arrays[dim],
            try self.constant(.bits32, binding.descriptor_index),
        });
        const sampled = self.id();
        try self.emit(&self.body, 61, &.{ self.sampled_image_types[dim], sampled, pointer });
        const lod = self.id();
        try self.emit(&self.body, 103, &.{ try self.ensureFloatVec2(), lod, sampled, coordinates });
        var destination_index: u32 = 0;
        for (0..2) |component| {
            const bit = @as(u4, 1) << @intCast(component);
            if (inst.data_mask & bit == 0) continue;
            const value = self.id();
            try self.emit(&self.body, 81, &.{ self.float_type, value, lod, @intCast(component) });
            try self.destination(
                try consecutiveRegister(inst.dst, destination_index),
                .{ .id = value, .value_type = .float32 },
            );
            destination_index += 1;
        }
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
        // Descriptor payloads are represented by Vulkan bindings and
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
        // shader; zero lets the live part of the program translate. Compute
        // prologs likewise consume hardware wave metadata SGPRs which are not
        // part of USER_DATA; compute built-ins below overwrite the SGPRs that
        // do have a Vulkan equivalent.
        if (self.stage == .fragment or self.stage == .vertex or self.stage == .compute) {
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

    fn shiftLeftLogical64(self: *Builder, value: [2]u32, offset: u32) Error![2]u32 {
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
        const low_left = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, low_left, value[0], within_dword });
        const high_left = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, high_left, value[1], within_dword });
        const raw_carry_shift = self.id();
        try self.emit(&self.body, 130, &.{
            self.bits_type,
            raw_carry_shift,
            try self.constant(.bits32, 32),
            within_dword,
        });
        const carry_shift = try self.andBits(raw_carry_shift, 31);
        const carry = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, carry, value[0], carry_shift });
        const merged_high = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, merged_high, high_left, carry });
        const below_32_high = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            below_32_high,
            offset_is_zero,
            high_left,
            merged_high,
        });
        const zero = try self.constant(.bits32, 0);
        const result_low = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, result_low, offset_lt_32, low_left, zero });
        const result_high = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            result_high,
            offset_lt_32,
            below_32_high,
            low_left,
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

    /// S_BFM_B64: a run of `src0` low bits, shifted up by `src1`.
    ///
    /// A shader that builds a resource descriptor out of immediates rather
    /// than loading one reaches this instruction, so leaving it untranslated
    /// costs the whole program rather than one value.
    fn bitfieldMask64(self: *Builder, inst: instruction.Instruction) Error!void {
        const count_raw = try self.source(inst.src0, .bits32);
        const offset_raw = try self.source(inst.src1, .bits32);
        const count = try self.andBits(count_raw, 63);
        const offset = try self.andBits(offset_raw, 63);
        const mask = try self.rightAlignedMask64(count);
        const result = try self.shiftLeftLogical64(mask, offset);
        try self.destinationPair(inst.dst, result);
    }

    fn shiftLeft64(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.sourcePair(inst.src0);
        const raw_offset = try self.source(inst.src1, .bits32);
        const offset = try self.andBits(raw_offset, 63);
        const result = try self.shiftLeftLogical64(value, offset);
        try self.destinationPair(inst.dst, result);
        try self.updateSccFromPair(result);
    }

    fn shiftRight64(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.sourcePair(inst.src0);
        const raw_offset = try self.source(inst.src1, .bits32);
        const offset = try self.andBits(raw_offset, 63);
        const result = try self.shiftRightLogical64(value, offset);
        try self.destinationPair(inst.dst, result);
        try self.updateSccFromPair(result);
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

    /// V_CVT_F32_UBYTE<n>: one byte of a packed dword as a float.
    ///
    /// Vertex colours and other normalized attributes arrive packed four to a
    /// dword, and this is how a shader takes them apart. All four selectors
    /// belong together — a program that unpacks a colour uses every one of
    /// them, so supporting only some translates none of them.
    fn unsignedByteToFloat(self: *Builder, inst: instruction.Instruction, byte_index: u5) Error!void {
        const packed_value = try self.source(inst.src0, .bits32);
        const shifted = if (byte_index == 0) packed_value else blk: {
            const result = self.id();
            try self.emit(&self.body, 194, &.{
                self.bits_type,
                result,
                packed_value,
                try self.constant(.bits32, @as(u32, byte_index) * 8),
            }); // OpShiftRightLogical
            break :blk result;
        };
        const byte_value = try self.andBits(shifted, 0xff);
        const result = self.id();
        try self.emit(&self.body, 112, &.{ self.float_type, result, byte_value }); // OpConvertUToF
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

    /// Converts the signed low nibble to the fractional interpolation offset
    /// used by GFX10: sign_extend(src[3:0]) / 16.0.
    fn i4ToOffsetFloat(self: *Builder, inst: instruction.Instruction) Error!void {
        const raw = try self.source(inst.src0, .bits32);
        const extended = try self.signExtendBits(try self.andBits(raw, 0xf), 4);
        const as_float = try self.signedBitsToFloat(extended);
        const result = try self.divideFloat(as_float, 16.0);
        try self.destination(inst.dst, .{ .id = result, .value_type = .float32 });
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

    /// SPIR-V requires structurally identical scalar/vector types to be
    /// declared only once. Storage-image descriptors frequently use the same
    /// texel component type at many bindings, so share their vec4 declaration
    /// with sampled-image and stage-interface types where possible.
    fn ensureVec4(self: *Builder, value_type: ValueType) Error!u32 {
        const cached = switch (value_type) {
            .float32 => &self.vector4_type,
            .sint32 => &self.vector4_signed_type,
            .bits32 => &self.vector4_bits_type,
        };
        if (cached.* == 0) {
            cached.* = self.id();
            try self.emit(&self.declarations, 23, &.{ cached.*, self.typeId(value_type), 4 }); // OpTypeVector
        }
        return cached.*;
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
            .fragment => if (inst.export_target < self.color_outputs.len)
                self.color_outputs[inst.export_target]
            else
                0,
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
        var out_z = z;
        if (is_position and self.convert_negative_one_to_one_depth) {
            // Vulkan clips Z to 0..W. The guest's OpenGL-style convention
            // clips to -W..W, so preserve its NDC depth with
            // z_vk = 0.5 * (z_guest + w).
            const sum = self.id();
            try self.emit(&self.body, 129, &.{ self.float_type, sum, z, out_w }); // OpFAdd
            const converted = self.id();
            try self.emit(&self.body, 133, &.{
                self.float_type,
                converted,
                sum,
                try self.constant(.float32, @bitCast(@as(f32, 0.5))),
            }); // OpFMul
            out_z = converted;
        }
        var components = [4]u32{ x, y, out_z, out_w };
        if (self.stage == .fragment and inst.export_target < self.color_export_mappings.len) {
            components = remapColorExportComponents(
                components,
                self.color_export_mappings[inst.export_target],
            );
        }
        const vector = self.id();
        try self.emit(&self.body, 80, &.{
            self.vector4_type,
            vector,
            components[0],
            components[1],
            components[2],
            components[3],
        }); // OpCompositeConstruct
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

    fn storageImageBinding(
        self: *const Builder,
        resource_sgpr: u32,
        instruction_pc: u32,
    ) ?StorageImageBinding {
        for (self.storage_image_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr and
                binding.instruction_pc != null and binding.instruction_pc.? == instruction_pc)
            {
                return binding;
            }
        }
        for (self.storage_image_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr and binding.instruction_pc == null) return binding;
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
        if ((inst.opcode_id != 0 and inst.opcode_id != 1) or
            (inst.image_dimension != .dim_2d and inst.image_dimension != .dim_3d) or
            (inst.image_address_components < 2 or inst.image_address_components > 4) or
            inst.data_mask == 0 or
            inst.src0.kind != .vgpr or inst.src1.kind != .sgpr)
        {
            return Error.UnsupportedOpcode;
        }
        const binding = self.storageImageBinding(inst.src1.reg, inst.pc) orelse
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
            (inst.opcode_id != 8 and inst.opcode_id != 9) or
            (inst.image_dimension != .dim_2d and inst.image_dimension != .dim_3d and
                inst.image_dimension != .dim_2d_array_alt) or
            (inst.image_address_components != 2 and inst.image_address_components != 3) or
            inst.data_mask == 0 or
            inst.dst.kind != .vgpr or inst.src0.kind != .vgpr or inst.src1.kind != .sgpr)
        {
            return Error.UnsupportedOpcode;
        }
        const binding = self.storageImageBinding(inst.src1.reg, inst.pc) orelse return Error.InvalidStorageBinding;
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
        for (&shader_values) |*value| value.* = try self.storageImageConstant(value_type, 0);
        var source_index: u32 = 0;
        for (&shader_values, 0..) |*value, component| {
            const bit = @as(u4, 1) << @intCast(component);
            if (inst.data_mask & bit == 0) continue;
            value.* = try self.source(try consecutiveRegister(inst.dst, source_index), value_type);
            source_index += 1;
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

    fn imageAtomic(self: *Builder, inst: instruction.Instruction, opcode: u16) Error!void {
        if (self.stage != .compute or
            (inst.image_dimension != .dim_2d and inst.image_dimension != .dim_3d) or
            (inst.image_address_components != 2 and inst.image_address_components != 3) or
            inst.data_mask != 1 or inst.dst.kind != .vgpr or inst.src0.kind != .vgpr or
            inst.src1.kind != .sgpr)
        {
            return Error.UnsupportedOpcode;
        }
        const binding = self.storageImageBinding(inst.src1.reg, inst.pc) orelse
            return Error.InvalidStorageBinding;
        // SPIR-V storage-image atomics are defined for single-component
        // 32-bit integer images. Other typed formats need a buffer alias.
        if (binding.format != .r32_uint or
            (binding.dimension == .three_d) != (inst.image_dimension == .dim_3d))
        {
            return Error.InvalidStorageBinding;
        }
        const descriptor_index: usize = @intCast(binding.descriptor_index);
        const pointer_type = self.storage_image_texel_pointer_types[descriptor_index];
        const image_variable = self.storage_image_variables[descriptor_index];
        if (pointer_type == 0 or image_variable == 0) return Error.InvalidStorageBinding;
        const value = try self.source(inst.dst, .bits32);
        const coordinates = try self.storageImageCoordinates(inst, binding.dimension);
        const pointer = self.id();
        try self.emit(&self.body, 60, &.{
            pointer_type,
            pointer,
            image_variable,
            coordinates,
            try self.constant(.bits32, 0), // sample
        }); // OpImageTexelPointer
        const previous = self.id();
        try self.emit(&self.body, opcode, &.{
            self.bits_type,
            previous,
            pointer,
            try self.constant(.bits32, 1), // ScopeDevice
            try self.constant(.bits32, 0), // MemorySemanticsNone
            value,
        });
        if (inst.globally_coherent) {
            try self.destination(inst.dst, .{ .id = previous, .value_type = .bits32 });
        }
        try self.emit(&self.body, 225, &.{
            try self.constant(.bits32, 1),
            try self.constant(.bits32, 0x48), // AcquireRelease | UniformMemory
        }); // OpMemoryBarrier
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
        // Opcode 0x20 is IMAGE_SAMPLE. 0x22 is IMAGE_SAMPLE_D: explicit
        // derivatives from VGPRs, lowered with SPIR-V Grad. 1D samples a
        // height-1 2D view so the host descriptor set stays 2D-only.
        const explicit_grad = inst.image_sample_flags.derivative;
        const implicit_lod = !inst.image_sample_flags.lod and
            !inst.image_sample_flags.bias and
            !inst.image_sample_flags.level_zero and
            !explicit_grad;
        const level_zero = inst.image_sample_flags.level_zero and !inst.image_sample_flags.offset;
        const level_zero_offset = inst.image_sample_flags.level_zero and inst.image_sample_flags.offset;
        const explicit_lod = inst.image_sample_flags.lod;
        const biased_lod = inst.image_sample_flags.bias;
        const compare = inst.image_sample_flags.compare;
        const one_dimensional = inst.image_dimension == .dim_1d;
        const requested_dimension: SampledImageDimension = switch (inst.image_dimension) {
            .dim_1d, .dim_2d => .two_d,
            .dim_3d => .three_d,
            // GFX10 DIM=3 is Cube. The historical enum name predates the
            // sampled-image implementation and is retained for ABI stability.
            .dim_2d_array => .cube,
            .dim_2d_array_alt => .two_d_array,
            else => return Error.UnsupportedOpcode,
        };
        if (inst.src0.kind != .vgpr or inst.src1.kind != .sgpr or inst.src2.kind != .sgpr) {
            return Error.UnsupportedBufferAddressing;
        }
        const binding = self.sampledImageBinding(inst.src1.reg, inst.src2.reg, inst.pc) orelse {
            return Error.InvalidStorageBinding;
        };
        const image_dimension = if (inst.image_dimension == .dim_2d_array_alt and
            (binding.dimension == .three_d or binding.dimension == .two_d_array))
            binding.dimension
        else
            requested_dimension;
        const dimension_index = sampledImageDimensionIndex(image_dimension);
        const coordinate_components: u8 = if (one_dimensional) 1 else if (image_dimension == .two_d) 2 else 3;
        const gradient_components: u8 = if (!explicit_grad) 0 else switch (inst.image_dimension) {
            .dim_1d, .dim_1d_array => 2,
            .dim_3d => 6,
            else => 4,
        };
        const extra_components: u8 = @intFromBool(inst.image_sample_flags.offset) +
            @intFromBool(compare) +
            @intFromBool(explicit_lod or biased_lod) +
            gradient_components;
        if ((self.stage != .vertex and self.stage != .fragment and self.stage != .compute) or
            self.sampled_image_arrays[dimension_index] == 0 or
            (!implicit_lod and !level_zero and !level_zero_offset and !explicit_lod and !biased_lod and !explicit_grad) or
            ((self.stage == .vertex or self.stage == .compute) and
                !level_zero and !level_zero_offset and !explicit_lod and !explicit_grad) or
            inst.image_address_components != coordinate_components + extra_components or
            inst.data_mask == 0)
        {
            return Error.UnsupportedOpcode;
        }
        if (binding.dimension != image_dimension) return Error.InvalidStorageBinding;
        // Coordinates now come from the real VS PARAM -> PS VINTRP interface.
        const coordinate_base: u32 = @intFromBool(inst.image_sample_flags.offset);
        const raw_x = try self.source(try imageAddressOperand(inst, coordinate_base), .float32);
        const coordinates = self.id();
        if (one_dimensional) {
            const coordinate_y = try self.constant(.float32, @bitCast(@as(f32, 0.5)));
            try self.emit(&self.body, 80, &.{ self.vector2_type, coordinates, raw_x, coordinate_y });
        } else {
            const raw_y = try self.source(try imageAddressOperand(inst, coordinate_base + 1), .float32);
            const coordinate_x, const coordinate_y = try self.sampleCoordinates(raw_x, raw_y);
            if (image_dimension != .two_d) {
                const coordinate_z = try self.source(try imageAddressOperand(inst, coordinate_base + 2), .float32);
                try self.emit(&self.body, 80, &.{ self.vector3_type, coordinates, coordinate_x, coordinate_y, coordinate_z });
            } else {
                try self.emit(&self.body, 80, &.{ self.vector2_type, coordinates, coordinate_x, coordinate_y });
            }
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
        const gradient_base = coordinate_base + coordinate_components;
        const dref_index = gradient_base + gradient_components;
        const lod_index = dref_index + @intFromBool(compare);
        const sampled = self.id();
        if (compare) {
            const dref = try self.source(try imageAddressOperand(inst, dref_index), .float32);
            if (level_zero or explicit_lod or inst.image_sample_flags.offset) {
                const lod = if (explicit_lod)
                    try self.source(try imageAddressOperand(inst, lod_index), .float32)
                else
                    try self.constant(.float32, @bitCast(@as(f32, 0)));
                if (inst.image_sample_flags.offset) {
                    const offset = try self.imageTexelOffset(inst);
                    try self.emit(&self.body, 90, &.{
                        self.float_type,
                        sampled,
                        sampled_image,
                        coordinates,
                        dref,
                        0x12,
                        lod,
                        offset,
                    }); // OpImageSampleDrefExplicitLod
                } else {
                    try self.emit(&self.body, 90, &.{
                        self.float_type,
                        sampled,
                        sampled_image,
                        coordinates,
                        dref,
                        0x2,
                        lod,
                    }); // OpImageSampleDrefExplicitLod
                }
            } else if (biased_lod) {
                const bias = try self.source(try imageAddressOperand(inst, lod_index), .float32);
                try self.emit(&self.body, 89, &.{
                    self.float_type,
                    sampled,
                    sampled_image,
                    coordinates,
                    dref,
                    0x1,
                    bias,
                }); // OpImageSampleDrefImplicitLod
            } else if (explicit_grad) {
                const dx, const dy = try self.sampleExplicitGradients(inst, image_dimension, one_dimensional, gradient_base);
                try self.emit(&self.body, 90, &.{
                    self.float_type,
                    sampled,
                    sampled_image,
                    coordinates,
                    dref,
                    0x4, // ImageOperands Grad
                    dx,
                    dy,
                }); // OpImageSampleDrefExplicitLod
            } else {
                try self.emit(&self.body, 89, &.{
                    self.float_type,
                    sampled,
                    sampled_image,
                    coordinates,
                    dref,
                }); // OpImageSampleDrefImplicitLod
            }
            var destination_index: u32 = 0;
            for (0..4) |component| {
                const bit = @as(u4, 1) << @intCast(component);
                if (inst.data_mask & bit == 0) continue;
                const value = if (destination_index == 0)
                    sampled
                else
                    try self.constant(.float32, 0);
                try self.destination(
                    try consecutiveRegister(inst.dst, destination_index),
                    .{ .id = value, .value_type = .float32 },
                );
                destination_index += 1;
            }
            return;
        }
        if (level_zero_offset or (inst.image_sample_flags.offset and (level_zero or explicit_lod))) {
            const offset = try self.imageTexelOffset(inst);
            const lod = if (explicit_lod)
                try self.source(try imageAddressOperand(inst, lod_index), .float32)
            else
                try self.constant(.float32, @bitCast(@as(f32, 0)));
            try self.emit(&self.body, 88, &.{
                self.vector4_type,
                sampled,
                sampled_image,
                coordinates,
                0x12, // ImageOperands Lod | Offset
                lod,
                offset,
            }); // OpImageSampleExplicitLod
        } else if (level_zero or explicit_lod) {
            // Compute shaders have no implicit derivatives. GFX10's
            // image_sample_lz names mip zero explicitly, which maps directly to
            // an explicit SPIR-V Lod operand and is valid in every shader stage.
            const lod = if (explicit_lod)
                try self.source(try imageAddressOperand(inst, lod_index), .float32)
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
            const bias = try self.source(try imageAddressOperand(inst, lod_index), .float32);
            try self.emit(&self.body, 87, &.{
                self.vector4_type,
                sampled,
                sampled_image,
                coordinates,
                0x1, // ImageOperands Bias
                bias,
            }); // OpImageSampleImplicitLod
        } else if (explicit_grad) {
            const dx, const dy = try self.sampleExplicitGradients(inst, image_dimension, one_dimensional, gradient_base);
            if (inst.image_sample_flags.offset) {
                const offset = try self.imageTexelOffset(inst);
                try self.emit(&self.body, 88, &.{
                    self.vector4_type,
                    sampled,
                    sampled_image,
                    coordinates,
                    0x14, // ImageOperands Grad | Offset
                    dx,
                    dy,
                    offset,
                }); // OpImageSampleExplicitLod
            } else {
                try self.emit(&self.body, 88, &.{
                    self.vector4_type,
                    sampled,
                    sampled_image,
                    coordinates,
                    0x4, // ImageOperands Grad
                    dx,
                    dy,
                }); // OpImageSampleExplicitLod
            }
        } else if (inst.image_sample_flags.offset) {
            const offset = try self.imageTexelOffset(inst);
            try self.emit(&self.body, 87, &.{
                self.vector4_type,
                sampled,
                sampled_image,
                coordinates,
                0x10, // ImageOperands Offset
                offset,
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

    fn sampleExplicitGradients(
        self: *Builder,
        inst: instruction.Instruction,
        image_dimension: SampledImageDimension,
        one_dimensional: bool,
        gradient_base: u32,
    ) Error![2]u32 {
        const zero = try self.constant(.float32, @bitCast(@as(f32, 0)));
        if (one_dimensional) {
            const dudx = try self.source(try imageAddressOperand(inst, gradient_base), .float32);
            const dudy = try self.source(try imageAddressOperand(inst, gradient_base + 1), .float32);
            const dx = self.id();
            const dy = self.id();
            try self.emit(&self.body, 80, &.{ self.vector2_type, dx, dudx, zero });
            try self.emit(&self.body, 80, &.{ self.vector2_type, dy, dudy, zero });
            return .{ dx, dy };
        }
        const dudx = try self.source(try imageAddressOperand(inst, gradient_base), .float32);
        const dvdx = try self.source(try imageAddressOperand(inst, gradient_base + 1), .float32);
        if (image_dimension == .three_d) {
            const dwdx = try self.source(try imageAddressOperand(inst, gradient_base + 2), .float32);
            const dudy = try self.source(try imageAddressOperand(inst, gradient_base + 3), .float32);
            const dvdy = try self.source(try imageAddressOperand(inst, gradient_base + 4), .float32);
            const dwdy = try self.source(try imageAddressOperand(inst, gradient_base + 5), .float32);
            const dx = self.id();
            const dy = self.id();
            try self.emit(&self.body, 80, &.{ self.vector3_type, dx, dudx, dvdx, dwdx });
            try self.emit(&self.body, 80, &.{ self.vector3_type, dy, dudy, dvdy, dwdy });
            return .{ dx, dy };
        }
        const dudy = try self.source(try imageAddressOperand(inst, gradient_base + 2), .float32);
        const dvdy = try self.source(try imageAddressOperand(inst, gradient_base + 3), .float32);
        if (image_dimension == .two_d) {
            const dx = self.id();
            const dy = self.id();
            try self.emit(&self.body, 80, &.{ self.vector2_type, dx, dudx, dvdx });
            try self.emit(&self.body, 80, &.{ self.vector2_type, dy, dudy, dvdy });
            return .{ dx, dy };
        }
        const dx = self.id();
        const dy = self.id();
        try self.emit(&self.body, 80, &.{ self.vector3_type, dx, dudx, dvdx, zero });
        try self.emit(&self.body, 80, &.{ self.vector3_type, dy, dudy, dvdy, zero });
        return .{ dx, dy };
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
        const compare = inst.image_sample_flags.compare;
        const supported_with_compare = supported_flags | (@as(u16, 1) << 3);
        if (self.stage != .fragment or inst.image_dimension != .dim_2d or
            !inst.image_sample_flags.level_zero or
            flags & ~(if (compare) supported_with_compare else supported_flags) != 0 or
            inst.data_mask == 0 or
            inst.image_address_components != 2 + @as(u8, @intFromBool(inst.image_sample_flags.offset)) +
                @as(u8, @intFromBool(compare)))
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
        const dref_index = coordinate_base + 2;
        if (compare) {
            const dref = try self.source(try imageAddressOperand(inst, dref_index), .float32);
            if (inst.image_sample_flags.offset) {
                const offset = try self.imageTexelOffset(inst);
                try self.emit(&self.body, 97, &.{
                    self.vector4_type,
                    gathered,
                    sampled_image,
                    coordinates,
                    dref,
                    0x10,
                    offset,
                }); // OpImageDrefGather
            } else {
                try self.emit(&self.body, 97, &.{
                    self.vector4_type,
                    gathered,
                    sampled_image,
                    coordinates,
                    dref,
                }); // OpImageDrefGather
            }
        } else if (inst.image_sample_flags.offset) {
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

    fn privateAccess(self: *Builder, byte_address: u32) Error!WorkgroupAccess {
        if (self.private_memory == 0 or self.private_word_pointer_type == 0) {
            return Error.UnsupportedBufferAddressing;
        }
        const word_index = try self.shiftRightBits(byte_address, 2);
        const in_range = self.id();
        try self.emit(&self.body, 176, &.{
            self.bool_type,
            in_range,
            word_index,
            try self.constant(.bits32, self.private_memory_words),
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
            self.private_word_pointer_type,
            pointer,
            self.private_memory,
            safe_index,
        }); // OpAccessChain
        return .{ .pointer = pointer, .in_range = in_range };
    }

    fn dsAddtidAddress(self: *Builder, inst: instruction.Instruction) Error!u32 {
        if (self.stage == .compute or inst.gds or inst.memory_offset < 0) {
            return Error.UnsupportedBufferAddressing;
        }
        const m0 = try self.source(.{ .kind = .m0 }, .bits32);
        const base = try self.andBits(m0, 0xffff);
        return self.addBits(base, try self.constant(.bits32, @intCast(inst.memory_offset)));
    }

    fn dsWriteAddtid(self: *Builder, inst: instruction.Instruction) Error!void {
        const access = try self.privateAccess(try self.dsAddtidAddress(inst));
        const predicate = (try self.writePredicate(access.in_range)) orelse access.in_range;
        try self.guardedStore(predicate, access.pointer, try self.source(inst.src1, .bits32));
    }

    fn dsReadAddtid(self: *Builder, inst: instruction.Instruction) Error!void {
        const access = try self.privateAccess(try self.dsAddtidAddress(inst));
        const loaded = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, loaded, access.pointer }); // OpLoad
        const value = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            value,
            access.in_range,
            loaded,
            try self.constant(.bits32, 0),
        }); // OpSelect
        try self.destination(inst.dst, .{ .id = value, .value_type = .bits32 });
    }

    fn gdsAccess(self: *Builder, word_index: u32) Error!WorkgroupAccess {
        if (self.gds_memory == 0 or self.gds_word_pointer_type == 0) {
            return Error.UnsupportedBufferAddressing;
        }
        const in_range = self.id();
        try self.emit(&self.body, 176, &.{
            self.bool_type,
            in_range,
            word_index,
            try self.constant(.bits32, 64 * 1024 / 4),
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
            self.gds_word_pointer_type,
            pointer,
            self.gds_memory,
            try self.constant(.bits32, 0),
            safe_index,
        }); // OpAccessChain
        return .{ .pointer = pointer, .in_range = in_range };
    }

    /// DS_APPEND reserves one counter entry per active lane. Issuing a
    /// one-element atomic from each Vulkan invocation yields the same unique
    /// range as the hardware's one-wave add plus broadcast, without depending
    /// on a fixed host subgroup width.
    fn dsAppend(self: *Builder, inst: instruction.Instruction) Error!void {
        if (self.stage != .compute or !inst.gds or inst.memory_offset < 0) {
            return Error.UnsupportedBufferAddressing;
        }
        const m0 = try self.source(.{ .kind = .m0 }, .bits32);
        const base = try self.shiftRightBits(m0, 16);
        const size = try self.andBits(m0, 0xffff);
        const byte_address = try self.addBits(base, try self.constant(.bits32, @intCast(inst.memory_offset)));
        const word_index = try self.shiftRightBits(byte_address, 2);
        const access = try self.gdsAccess(word_index);
        const within_m0 = self.id();
        try self.emit(&self.body, 176, &.{
            self.bool_type,
            within_m0,
            try self.constant(.bits32, @intCast(inst.memory_offset + 3)),
            size,
        }); // OpULessThan
        const bounded = self.id();
        try self.emit(&self.body, 167, &.{ self.bool_type, bounded, access.in_range, within_m0 }); // OpLogicalAnd
        const predicate = (try self.writePredicate(bounded)) orelse bounded;
        const delta = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            delta,
            predicate,
            try self.constant(.bits32, 1),
            try self.constant(.bits32, 0),
        }); // OpSelect
        const previous = self.id();
        try self.emit(&self.body, 234, &.{
            self.bits_type,
            previous,
            access.pointer,
            try self.constant(.bits32, 1), // ScopeDevice
            try self.constant(.bits32, 0), // MemorySemanticsNone
            delta,
        }); // OpAtomicIAdd
        const result = self.id();
        try self.emit(&self.body, 169, &.{
            self.bits_type,
            result,
            predicate,
            previous,
            try self.constant(.bits32, 0),
        }); // OpSelect
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
        try self.emit(&self.body, 225, &.{
            try self.constant(.bits32, 1),
            try self.constant(.bits32, 0x48),
        }); // OpMemoryBarrier
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

    fn readLane(self: *Builder, inst: instruction.Instruction) Error!void {
        const source_value = try self.source(inst.src0, .bits32);
        const lane = try self.source(inst.src1, .bits32);
        const result = self.id();
        try self.emit(&self.body, 345, &.{
            self.bits_type,
            result,
            try self.constant(.bits32, 3), // ScopeSubgroup
            source_value,
            lane,
        }); // OpGroupNonUniformShuffle
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn writeLane(self: *Builder, inst: instruction.Instruction) Error!void {
        const value = try self.source(inst.src0, .bits32);
        const lane = try self.source(inst.src1, .bits32);
        const current = if (registerIndex(inst.dst)) |index|
            try self.registerBits(index, 0)
        else
            try self.constant(.bits32, 0);
        if (self.local_invocation_index == 0) {
            try self.destination(inst.dst, .{ .id = value, .value_type = .bits32 });
            return;
        }
        const invocation = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, invocation, self.local_invocation_index }); // OpLoad
        const lane_id = try self.andBits(invocation, 63);
        const matches = self.id();
        try self.emit(&self.body, 170, &.{ self.bool_type, matches, lane_id, lane }); // OpIEqual
        const result = self.id();
        try self.emit(&self.body, 169, &.{ self.bits_type, result, matches, value, current }); // OpSelect
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
        if (self.lane_predicate_mask) |cached_mask| {
            if (cached_mask[0] == mask[0] and cached_mask[1] == mask[1]) return self.lane_predicate;
        }

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
        const predicate = try self.isNonZero(bit);
        self.lane_predicate_mask = mask;
        self.lane_predicate = predicate;
        return predicate;
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

    fn asBufferFromFlat(inst: instruction.Instruction) instruction.Instruction {
        var buffer = inst;
        buffer.index_enable = true;
        buffer.offset_enable = false;
        const offset: u32 = @bitCast(inst.memory_offset);
        buffer.src2 = .{
            .kind = .integer_inline_constant,
            .value = offset,
            .signed_val = inst.memory_offset,
        };
        return buffer;
    }

    fn flatLoadWords(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        try self.bufferLoadWords(asBufferFromFlat(inst), count);
    }

    fn flatStoreWords(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        try self.bufferStoreWords(asBufferFromFlat(inst), count);
    }

    fn flatLoadSubword(self: *Builder, inst: instruction.Instruction, width: u8, signed: bool) Error!void {
        try self.bufferLoadSubword(asBufferFromFlat(inst), width, signed);
    }

    fn flatStoreSubword(self: *Builder, inst: instruction.Instruction, width: u8) Error!void {
        try self.bufferStoreSubword(asBufferFromFlat(inst), width);
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
        // CMPX is remapped to the matching V_CMP before this runs, so the
        // comparison lowering writes EXEC as a 0/~0 per-invocation predicate.
        // Other ALU writes to EXEC fall through and refresh the mask in
        // `destination`.
        if (inst.family == .vopc or inst.family == .vop3) return false;
        if (inst.opcode != .s_mov_b64) return false;

        // Pixel prologs may restore EXEC from a hardware-provided SGPR pair
        // which is not part of USER_DATA. Vulkan has already selected the live
        // fragment invocations, so an unavailable snapshot means "keep the
        // current host mask", not "reject the shader". Known compute masks
        // still take the exact lowering below for guarded buffer accesses.
        if (inst.src0.kind == .sgpr) {
            const low_index = registerIndex(inst.src0) orelse return true;
            if (low_index + 1 >= self.registers.len or
                (self.mutable_register_pointers[low_index] == 0 and
                    self.registers[low_index].id == 0) or
                (self.mutable_register_pointers[low_index + 1] == 0 and
                    self.registers[low_index + 1].id == 0))
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
        self.lane_predicate_mask = null;
        self.lane_predicate = 0;
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
            .v_cmpx_lt_f16 => .v_cmp_lt_f16,
            .v_cmpx_eq_f16 => .v_cmp_eq_f16,
            .v_cmpx_le_f16 => .v_cmp_le_f16,
            .v_cmpx_gt_f16 => .v_cmp_gt_f16,
            .v_cmpx_ge_f16 => .v_cmp_ge_f16,
            .v_cmpx_neq_f16 => .v_cmp_neq_f16,
            .v_cmpx_nlt_f16 => .v_cmp_ge_f16,
            .v_cmpx_ne_i64, .v_cmpx_ne_u64 => .v_cmp_ne_u64,
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
        if (nonExecCompareOpcode(inst.opcode)) |opcode| inst.opcode = opcode;
        if (try self.lowerExecutionMask(inst)) return;
        if (try self.lowerSpecializedScalarDestination(inst)) return;
        switch (inst.opcode) {
            .s_nop, .s_waitcnt, .s_waitcnt_depctr, .s_inst_prefetch, .s_sendmsg, .s_trap, .s_sleep, .s_ttrace_data, .s_setreg_b32, .v_nop, .s_endpgm, .s_code_end, .s_wqm_b64 => {},
            .s_quadmask_b64 => try self.wholeQuadMask64(inst),
            .s_barrier => try self.controlBarrier(),
            // Branches are handled by structured CF or skipped in the linear fallback.
            .s_branch, .s_cbranch_scc0, .s_cbranch_scc1, .s_cbranch_vccz, .s_cbranch_vccnz, .s_cbranch_execz, .s_cbranch_execnz => {},
            .s_setpc_b64 => try self.exportNggLdsRecord(),
            .s_mov_b32, .s_movk_i32, .v_mov_b32 => try self.unary(inst, 83, .bits32), // OpCopyObject
            .v_readfirstlane_b32 => try self.readFirstLane(inst),
            .v_readlane_b32 => try self.readLane(inst),
            .v_writelane_b32 => try self.writeLane(inst),
            .v_permlane16_b32 => try self.permlane(inst, false),
            .v_permlanex16_b32 => try self.permlane(inst, true),
            .v_movreld_b32, .v_movrels_b32 => try self.unary(inst, 83, .bits32),
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
            .s_and_saveexec_b64 => try self.saveExec(inst, .and_mask),
            .s_and_saveexec_b32 => try self.saveExec32(inst, .and_mask),
            .s_orn2_saveexec_b64 => try self.saveExec(inst, .or_not),
            .s_andn1_saveexec_b64 => try self.saveExec(inst, .not_and),
            .s_andn1_saveexec_b32 => try self.saveExec32(inst, .not_and),
            .v_cndmask_b32 => try self.cndmask(inst),
            .v_interp_p1_f32, .v_interp_p2_f32, .v_interp_mov_f32 => try self.interpolateParameter(inst),
            .v_cvt_f32_i32 => try self.integerToFloat(inst, true),
            .v_cvt_f32_u32 => try self.integerToFloat(inst, false),
            .v_cvt_i32_f32 => try self.floatToInteger(inst, true),
            .v_cvt_u32_f32 => try self.floatToInteger(inst, false),
            .v_cvt_flr_i32_f32 => try self.floatFloorToSignedInteger(inst),
            .v_cvt_f32_ubyte0 => try self.unsignedByteToFloat(inst, 0),
            .v_cvt_f32_ubyte1 => try self.unsignedByteToFloat(inst, 1),
            .v_cvt_f32_ubyte2 => try self.unsignedByteToFloat(inst, 2),
            .v_cvt_f32_ubyte3 => try self.unsignedByteToFloat(inst, 3),
            .v_cvt_off_f32_i4 => try self.i4ToOffsetFloat(inst),
            // Pack two f32 → two f16 in one dword (Unity PS export path).
            .v_cvt_pkrtz_f16_f32, .v_pack_b32_f16 => try self.packHalf2x16(inst),
            .v_cvt_pk_u16_u32 => try self.packConvert(inst, .u16),
            .v_cvt_pk_i16_i32 => try self.packConvert(inst, .i16),
            .v_cvt_pknorm_u16_f32 => try self.packConvert(inst, .unorm),
            .v_cvt_pknorm_i16_f32 => try self.packConvert(inst, .snorm),
            .v_cvt_pk_u8_f32 => try self.packU8Float(inst),
            .v_cvt_f16_u16 => try self.convertHalfInteger(inst, true, false),
            .v_cvt_f16_i16 => try self.convertHalfInteger(inst, true, true),
            .v_cvt_u16_f16 => try self.convertHalfInteger(inst, false, false),
            .v_cvt_i16_f16 => try self.convertHalfInteger(inst, false, true),
            .v_cvt_rpi_i32_f32 => try self.roundToSigned(inst),
            .v_frexp_mant_f32 => try self.frexpMantissa(inst),
            .v_frexp_exp_i32_f32 => try self.frexpExponent(inst),
            .s_add_u32 => try self.scalarAddUnsigned(inst, false),
            .s_addc_u32 => try self.scalarAddUnsigned(inst, true),
            .v_addc_u32 => try self.vectorAddCarry(inst),
            .v_subrev_co_ci_u32 => try self.vectorSubBorrow(inst),
            .s_add_i32, .v_add_nc_u32 => try self.binary(inst, 128, .bits32, false), // OpIAdd
            .v_lshl_add_u32 => try self.shiftLeftAdd(inst),
            // dst = (src0 + src1) << (src2 & 31)
            .v_add_lshl_u32 => try self.addShiftLeft(inst),
            .s_lshl1_add_u32 => try self.fixedShiftLeftAdd(inst, 1),
            .s_lshl2_add_u32 => try self.fixedShiftLeftAdd(inst, 2),
            .s_lshl3_add_u32 => try self.fixedShiftLeftAdd(inst, 3),
            .s_lshl4_add_u32 => try self.fixedShiftLeftAdd(inst, 4),
            // Bitfield mask: dst = (((1 << (src0 & 31)) - 1) << (src1 & 31)).
            .s_bfm_b32, .v_bfm_b32 => try self.bitfieldMask(inst),
            // Scalar BFE packs offset/width in src1; vector BFE uses src1/src2.
            .s_bfe_u32 => try self.scalarBitfieldExtract(inst),
            .v_bfe_u32 => try self.bitfieldExtract(inst, false),
            .v_bfe_i32 => try self.bitfieldExtract(inst, true),
            .s_bfe_u64 => try self.scalarBitfieldExtract64(inst),
            .s_bfm_b64 => try self.bitfieldMask64(inst),
            .s_lshl_b64 => try self.shiftLeft64(inst),
            .s_lshr_b64 => try self.shiftRight64(inst),
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
            .v_mad_i32_i24 => try self.mad24(inst, true),
            .v_mad_u32_u24 => try self.mad24(inst, false),
            .v_mad_u64_u32 => try self.madU64U32(inst),
            .v_fma_f32 => try self.fmaFloat(inst),
            .v_fma_f16 => try self.fmaF16(inst),
            .v_dot2c_f32_f16 => try self.dot2PackedF16(inst),
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
            .v_min3_i32, .v_min3_u32, .v_max3_i32, .v_max3_u32, .v_med3_i32, .v_med3_u32, .v_med3_i16 => try self.minMax3Integer(inst, inst.opcode),
            .v_min3_f16 => try self.glslBinaryF16(inst, 37),
            .v_max3_f16 => try self.glslBinaryF16(inst, 40),
            .v_med3_f16 => try self.glslBinaryF16(inst, 40),
            .v_rcp_f32, .v_rcp_iflag_f32 => try self.reciprocalFloat(inst),
            .v_add_f16 => try self.binaryF16(inst, 129, false),
            .v_sub_f16 => try self.binaryF16(inst, 131, false),
            .v_subrev_f16 => try self.binaryF16(inst, 131, true),
            .v_mul_f16 => try self.binaryF16(inst, 133, false),
            .v_max_f16 => try self.glslBinaryF16(inst, 40),
            .v_min_f16 => try self.glslBinaryF16(inst, 37),
            .v_pk_add_f16 => try self.packedBinaryF16(inst, 129),
            .v_pk_mul_f16 => try self.packedBinaryF16(inst, 133),
            .v_pk_fma_f16 => try self.packedFmaF16(inst),
            .v_pk_min_f16 => try self.packedGlslF16(inst, 37),
            .v_pk_max_f16 => try self.packedGlslF16(inst, 40),
            .v_pk_fmac_f16 => try self.packedFmacF16(inst),
            .v_pk_add_i16 => try self.packedIntegerBinary(inst, 128, true, false),
            .v_pk_sub_i16 => try self.packedIntegerBinary(inst, 130, true, false),
            .v_pk_add_u16 => try self.packedIntegerBinary(inst, 128, false, false),
            .v_pk_sub_u16 => try self.packedIntegerBinary(inst, 130, false, false),
            .v_pk_mul_lo_u16 => try self.packedIntegerBinary(inst, 132, false, false),
            .v_pk_lshlrev_b16 => try self.packedIntegerBinary(inst, 196, false, true),
            .v_pk_lshrrev_b16 => try self.packedIntegerBinary(inst, 194, false, true),
            .v_pk_ashrrev_i16 => try self.packedIntegerBinary(inst, 195, true, true),
            .v_pk_max_i16 => try self.packedIntegerGlsl(inst, 42, true),
            .v_pk_min_i16 => try self.packedIntegerGlsl(inst, 39, true),
            .v_pk_max_u16 => try self.packedIntegerGlsl(inst, 41, false),
            .v_pk_min_u16 => try self.packedIntegerGlsl(inst, 38, false),
            .v_pk_mad_i16 => try self.packedIntegerMad(inst, true),
            .v_pk_mad_u16 => try self.packedIntegerMad(inst, false),
            .v_fmac_f16 => try self.fmacF16(inst),
            .v_fmamk_f16, .v_fmaak_f16 => try self.fmaF16(inst),
            .v_mad_mixlo_f16 => try self.madMixF16(inst, false),
            .v_mad_mixhi_f16 => try self.madMixF16(inst, true),
            .v_rcp_f16 => try self.reciprocalF16(inst),
            .v_rsq_f16 => try self.unaryF16(inst, 32),
            .v_sqrt_f16 => try self.unaryF16(inst, 31),
            .v_log_f16 => try self.unaryF16(inst, 30),
            .v_exp_f16 => try self.unaryF16(inst, 29),
            .v_floor_f16 => try self.unaryF16(inst, 8),
            .v_ceil_f16 => try self.unaryF16(inst, 9),
            .v_trunc_f16 => try self.unaryF16(inst, 3),
            .v_rndne_f16 => try self.unaryF16(inst, 2),
            .v_add_nc_u16 => try self.integer16Binary(inst, 128, false, false),
            .v_sub_nc_u16 => try self.integer16Binary(inst, 130, false, false),
            .v_add_nc_i16 => try self.integer16Binary(inst, 128, true, false),
            .v_sub_nc_i16 => try self.integer16Binary(inst, 130, true, false),
            .v_lshlrev_b16 => try self.integer16Binary(inst, 196, false, true),
            .v_lshrrev_b16 => try self.integer16Binary(inst, 194, false, true),
            .v_ashrrev_i16 => try self.integer16Binary(inst, 195, true, true),
            .v_max_u16 => try self.integer16Glsl(inst, 41, false),
            .v_max_i16 => try self.integer16Glsl(inst, 42, true),
            .v_min_u16 => try self.integer16Glsl(inst, 38, false),
            .v_min_i16 => try self.integer16Glsl(inst, 39, true),
            .v_lshlrev_b64 => try self.shiftLeft64Vector(inst),
            .v_lshrrev_b64 => try self.shift64(inst, false),
            .v_cvt_f32_f16 => try self.convertF16ToF32(inst),
            .v_cvt_f16_f32 => try self.convertF32ToF16(inst),
            .v_ffbh_u32 => try self.findFirstBit(inst, true),
            .v_ffbl_b32 => try self.findFirstBit(inst, false),
            .s_ff1_i32_b32 => try self.findFirstBit(inst, false),
            .s_ff1_i32_b64 => try self.findFirstBit64(inst, false),
            .s_flbit_i32_b64 => try self.findFirstBit64(inst, true),
            .s_bcnt1_i32_b32 => try self.scalarPopCount(inst),
            .s_bcnt1_i32_b64 => try self.scalarPopCount64(inst),
            .s_bitset0_b32 => try self.bitSet(inst, false),
            .s_bitset1_b32 => try self.bitSet(inst, true),
            .s_bitreplicate_b64_b32 => try self.bitReplicate(inst),
            .s_cmp_eq_u64 => try self.scalarCompare64(inst, true),
            .s_cmp_lg_u64 => try self.scalarCompare64(inst, false),
            .v_bcnt_u32_b32 => try self.popCountAdd(inst),
            .v_mbcnt_lo_u32_b32 => try self.maskedBitCount(inst, false),
            .v_mbcnt_hi_u32_b32 => try self.maskedBitCount(inst, true),
            .v_alignbit_b32 => try self.alignBit(inst, false),
            .v_alignbyte_b32 => try self.alignBit(inst, true),
            .v_xnor_b32 => try self.xnor32(inst),
            .v_mul_lo_i32 => try self.binary(inst, 132, .bits32, false),
            .v_add_i32 => try self.binary(inst, 128, .bits32, false),
            .v_sub_i32 => try self.binary(inst, 130, .bits32, false),
            .v_subrev_i32 => try self.binary(inst, 130, .bits32, true),
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
            .s_andn2_b32, .s_orn2_b32, .s_nand_b32, .s_nor_b32, .s_xnor_b32 => try self.bitwise32(inst, inst.opcode),
            .s_pack_ll_b32_b16 => try self.packHalves(inst, false, false),
            .s_pack_lh_b32_b16 => try self.packHalves(inst, false, true),
            .s_pack_hh_b32_b16 => try self.packHalves(inst, true, true),
            .s_abs_i32 => try self.absSigned(inst),
            .s_bfe_i32 => try self.scalarBitfieldExtractSigned(inst),
            .s_mulk_i32 => try self.binary(inst, 132, .bits32, false),
            .s_not_b32, .v_not_b32 => try self.unary(inst, 200, .bits32), // OpNot
            .s_brev_b32, .v_bfrev_b32 => try self.unary(inst, 204, .bits32), // OpBitReverse
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
            .s_bitcmp0_b32 => try self.scalarBitCompare(inst, false),
            .s_bitcmp1_b32 => try self.scalarBitCompare(inst, true),
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
            .v_cmp_f_i32, .v_cmp_f_u32 => try self.vectorConstantComparison(inst, false),
            .v_cmp_t_i32, .v_cmp_t_u32 => try self.vectorConstantComparison(inst, true),
            .v_cmp_lt_f16 => try self.vectorComparisonF16(inst, 184),
            .v_cmp_eq_f16 => try self.vectorComparisonF16(inst, 180),
            .v_cmp_le_f16 => try self.vectorComparisonF16(inst, 188),
            .v_cmp_gt_f16 => try self.vectorComparisonF16(inst, 186),
            .v_cmp_lg_f16 => try self.vectorComparisonF16(inst, 182),
            .v_cmp_ge_f16 => try self.vectorComparisonF16(inst, 190),
            .v_cmp_neq_f16 => try self.vectorComparisonF16(inst, 183),
            .v_cmp_lt_i16 => try self.vectorComparisonI16(inst, 177, true),
            .v_cmp_eq_i16 => try self.vectorComparisonI16(inst, 170, true),
            .v_cmp_le_i16 => try self.vectorComparisonI16(inst, 179, true),
            .v_cmp_gt_i16 => try self.vectorComparisonI16(inst, 173, true),
            .v_cmp_ne_i16 => try self.vectorComparisonI16(inst, 171, true),
            .v_cmp_ge_i16 => try self.vectorComparisonI16(inst, 175, true),
            .v_cmp_lt_u16 => try self.vectorComparisonI16(inst, 176, false),
            .v_cmp_eq_u16 => try self.vectorComparisonI16(inst, 170, false),
            .v_cmp_le_u16 => try self.vectorComparisonI16(inst, 178, false),
            .v_cmp_gt_u16 => try self.vectorComparisonI16(inst, 172, false),
            .v_cmp_ne_u16 => try self.vectorComparisonI16(inst, 171, false),
            .v_cmp_ge_u16 => try self.vectorComparisonI16(inst, 174, false),
            .v_cmp_class_f32 => try self.vectorCompareClassF32(inst),
            .v_cmp_eq_i64 => try self.vectorComparison64(inst, .eq),
            .v_cmp_ne_u64 => try self.vectorComparison64(inst, .ne),
            .v_cmp_gt_u64 => try self.vectorComparison64(inst, .gt_u),
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
            .tbuffer_store_format_x,
            => try self.bufferStoreWords(inst, 1),
            .buffer_store_dwordx2,
            .buffer_store_format_xy,
            .tbuffer_store_format_xy,
            => try self.bufferStoreWords(inst, 2),
            .buffer_store_dwordx3,
            .buffer_store_format_xyz,
            .tbuffer_store_format_xyz,
            => try self.bufferStoreWords(inst, 3),
            .buffer_store_dwordx4,
            .buffer_store_format_xyzw,
            .tbuffer_store_format_xyzw,
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
            .buffer_atomic_fmin => try self.bufferAtomicFloat(inst, true),
            .buffer_atomic_fmax => try self.bufferAtomicFloat(inst, false),
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
            .ds_write_addtid_b32 => try self.dsWriteAddtid(inst),
            .ds_read_addtid_b32 => try self.dsReadAddtid(inst),
            .ds_append => try self.dsAppend(inst),
            .ds_add_u32, .ds_add_rtn_u32 => try self.dsAtomic(inst, 234),
            .ds_sub_u32, .ds_sub_rtn_u32 => try self.dsAtomic(inst, 235),
            .ds_min_i32, .ds_min_rtn_i32 => try self.dsAtomic(inst, 236),
            .ds_min_u32, .ds_min_rtn_u32 => try self.dsAtomic(inst, 237),
            .ds_max_i32, .ds_max_rtn_i32 => try self.dsAtomic(inst, 238),
            .ds_max_u32, .ds_max_rtn_u32 => try self.dsAtomic(inst, 239),
            .ds_and_b32, .ds_and_rtn_b32 => try self.dsAtomic(inst, 240),
            .ds_or_b32, .ds_or_rtn_b32 => try self.dsAtomic(inst, 241),
            .ds_xor_b32, .ds_xor_rtn_b32 => try self.dsAtomic(inst, 242),
            .ds_write2st64_b32 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWritePair(inst),
            .ds_read2st64_b32 => try self.dsReadPair(inst),
            .ds_consume => try self.dsAppend(inst),
            .flat_load_ubyte => try self.flatLoadSubword(inst, 8, false),
            .flat_load_sbyte => try self.flatLoadSubword(inst, 8, true),
            .flat_load_ushort => try self.flatLoadSubword(inst, 16, false),
            .flat_load_sshort => try self.flatLoadSubword(inst, 16, true),
            .flat_load_dword => try self.flatLoadWords(inst, 1),
            .flat_load_dwordx2 => try self.flatLoadWords(inst, 2),
            .flat_load_dwordx3 => try self.flatLoadWords(inst, 3),
            .flat_load_dwordx4 => try self.flatLoadWords(inst, 4),
            .flat_store_byte => try self.flatStoreSubword(inst, 8),
            .flat_store_short => try self.flatStoreSubword(inst, 16),
            .flat_store_dword => try self.flatStoreWords(inst, 1),
            .flat_store_dwordx2 => try self.flatStoreWords(inst, 2),
            .flat_store_dwordx3 => try self.flatStoreWords(inst, 3),
            .flat_store_dwordx4 => try self.flatStoreWords(inst, 4),
            .image_load, .image_load_mip => try self.imageLoad(inst),
            .image_store, .image_store_mip => try self.imageStore(inst),
            .image_atomic_add => try self.imageAtomic(inst, 234),
            .image_atomic_umin => try self.imageAtomic(inst, 237),
            .image_atomic_umax => try self.imageAtomic(inst, 239),
            .image_atomic_and => try self.imageAtomic(inst, 240),
            .image_atomic_or => try self.imageAtomic(inst, 241),
            .image_atomic_xor => try self.imageAtomic(inst, 242),
            .image_sample => try self.sampleImage(inst),
            .image_gather4 => try self.gatherImage(inst),
            .image_get_resinfo => try self.imageGetResinfo(inst),
            .image_get_lod => try self.imageGetLod(inst),
            .ds_swizzle_b32 => try self.dsSwizzle(inst),
            .ds_write_b8 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWriteWords(inst, 1),
            .ds_write_b16 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWriteWords(inst, 1),
            .ds_read_u16_d16 => try self.dsReadSubword(inst, 16, false),
            .ds_write2_b64 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWritePair(inst),
            .ds_write2st64_b64 => if (self.stage != .vertex or self.ngg_lds_exports.len == 0) try self.dsWritePair(inst),
            .ds_read2_b64 => try self.dsReadPair(inst),
            .ds_read2st64_b64 => try self.dsReadPair(inst),
            .ds_min_f32 => try self.dsAtomic(inst, 236),
            .ds_max_f32 => try self.dsAtomic(inst, 238),
            .ds_wrxchg_rtn_b32 => try self.dsAtomic(inst, 229),
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
            "[spirv] lowering failed pc=0x{x} family={s} opcode={s} id=0x{x}: {s} dim={s} addr_components={d} dmask=0x{x} gds={} operands={s}/{s}/{s}/{s} raw=",
            .{ inst.pc, @tagName(inst.family), @tagName(inst.opcode), inst.opcode_id, @errorName(err), @tagName(inst.image_dimension), inst.image_address_components, inst.data_mask, inst.gds, @tagName(inst.dst.kind), @tagName(inst.src0.kind), @tagName(inst.src1.kind), @tagName(inst.src2.kind) },
        );
        for (inst.raw[0..inst.raw_count]) |word| std.debug.print(" {x:0>8}", .{word});
        std.debug.print("\n", .{});
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
            // One Vulkan invocation is one RDNA lane. V_CMP/CMPX write 0/~0
            // into VCC or EXEC for that invocation, so comparing the word with
            // zero is the lane predicate. When EXEC has been narrowed to a
            // real 64-bit mask, test this lane's bit instead.
            if (condition == .exec_zero and builder.local_invocation_index != 0) {
                if (try builder.laneEnabled()) |enabled| {
                    const inverted = builder.id();
                    try builder.emit(&builder.body, 168, &.{ builder.bool_type, inverted, enabled }); // OpLogicalNot
                    break :blk inverted;
                }
                break :blk try falseCondition(builder);
            }
            const index: usize = if (condition == .vcc_zero) 106 else 126;
            const mask = if (builder.mutable_register_pointers[index] != 0)
                Value{ .id = try builder.registerBits(index, 0xffff_ffff), .value_type = .bits32 }
            else
                builder.registers[index];
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

fn directBranchCondition(opcode: isa.Opcode) ?struct { control_flow.Condition, bool } {
    return switch (opcode) {
        .s_cbranch_scc0 => .{ .scc, false },
        .s_cbranch_scc1 => .{ .scc, true },
        .s_cbranch_vccz => .{ .vcc_zero, true },
        .s_cbranch_vccnz => .{ .vcc_zero, false },
        .s_cbranch_execz => .{ .exec_zero, true },
        .s_cbranch_execnz => .{ .exec_zero, false },
        else => null,
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

fn setpcSuccessor(graph: *const control_flow.Graph, block_index: u32) ?u32 {
    for (graph.edges.items) |edge| {
        if (edge.from == block_index) return edge.to;
    }
    return null;
}

fn markMutableOperand(marked: *[384]bool, op: operand.Operand) void {
    const first = Builder.registerIndex(op) orelse return;
    // Memory instructions name the first word of a descriptor, coordinate or
    // result tuple. A small conservative window covers those implicit words
    // as well as all scalar/vector pairs without teaching the CFG pass every
    // individual instruction width.
    const end = @min(marked.len, first + 16);
    @memset(marked[first..end], true);
}

fn configureMutableLoopState(builder: *Builder, instructions: []const instruction.Instruction) Error!void {
    var marked: [384]bool = @splat(false);
    for (instructions) |inst| {
        markMutableOperand(&marked, inst.dst);
        markMutableOperand(&marked, inst.dst2);
        const sources = inst.sources();
        for (sources.slice()) |source_op| markMutableOperand(&marked, source_op);
    }

    builder.function_bits_pointer_type = builder.id();
    try builder.emit(&builder.declarations, 32, &.{ builder.function_bits_pointer_type, 7, builder.bits_type }); // ptr Function
    for (marked, 0..) |needed, index| {
        if (needed) builder.mutable_register_pointers[index] = builder.id();
    }
    builder.mutable_scc_pointer = builder.id();
    builder.mutable_carry_pointer = builder.id();
}

fn emitMutableLoopPrelude(builder: *Builder, entry_label: u32) Error!void {
    try builder.emit(&builder.body, 248, &.{builder.label}); // OpLabel
    for (builder.mutable_register_pointers) |pointer| {
        if (pointer != 0) {
            try builder.emit(&builder.body, 59, &.{ builder.function_bits_pointer_type, pointer, 7 }); // OpVariable Function
        }
    }
    try builder.emit(&builder.body, 59, &.{ builder.function_bits_pointer_type, builder.mutable_scc_pointer, 7 });
    try builder.emit(&builder.body, 59, &.{ builder.function_bits_pointer_type, builder.mutable_carry_pointer, 7 });
    if (builder.dispatch_pc_pointer != 0) {
        try builder.emit(&builder.body, 59, &.{ builder.function_bits_pointer_type, builder.dispatch_pc_pointer, 7 });
    }

    try builder.initializeStageInputs();
    for (builder.mutable_register_pointers, 0..) |pointer, index| {
        if (pointer == 0) continue;
        const current = builder.registers[index];
        const default_bits: u32 = if (index == 106 or index == 107 or index == 126 or index == 127)
            0xffff_ffff
        else
            0;
        const value = if (current.id != 0)
            try builder.convert(current, .bits32)
        else
            try builder.constant(.bits32, default_bits);
        try builder.emit(&builder.body, 62, &.{ pointer, value }); // OpStore
    }
    const zero = try builder.constant(.bits32, 0);
    try builder.emit(&builder.body, 62, &.{ builder.mutable_scc_pointer, zero });
    try builder.emit(&builder.body, 62, &.{ builder.mutable_carry_pointer, zero });
    if (builder.dispatch_pc_pointer != 0) {
        try builder.emit(&builder.body, 62, &.{ builder.dispatch_pc_pointer, zero });
    }
    try builder.emit(&builder.body, 249, &.{entry_label}); // OpBranch
}

fn loadMutableControlState(builder: *Builder) Error!void {
    const zero = try builder.constant(.bits32, 0);
    const scc_bits = builder.id();
    try builder.emit(&builder.body, 61, &.{ builder.bits_type, scc_bits, builder.mutable_scc_pointer }); // OpLoad
    builder.scc = builder.id();
    try builder.emit(&builder.body, 171, &.{ builder.bool_type, builder.scc, scc_bits, zero }); // OpINotEqual
    const carry_bits = builder.id();
    try builder.emit(&builder.body, 61, &.{ builder.bits_type, carry_bits, builder.mutable_carry_pointer });
    builder.arithmetic_carry = builder.id();
    try builder.emit(&builder.body, 171, &.{ builder.bool_type, builder.arithmetic_carry, carry_bits, zero });
    if (builder.mutable_register_pointers[126] != 0) {
        builder.exec_mask = .{
            try builder.registerBits(126, 0xffff_ffff),
            try builder.registerBits(127, 0xffff_ffff),
        };
        builder.lane_predicate_mask = null;
        builder.lane_predicate = 0;
    }
}

fn storeMutableControlState(builder: *Builder) Error!void {
    const zero = try builder.constant(.bits32, 0);
    const one = try builder.constant(.bits32, 1);
    const scc_condition = if (builder.scc != 0) builder.scc else try falseCondition(builder);
    const scc_bits = builder.id();
    try builder.emit(&builder.body, 169, &.{ builder.bits_type, scc_bits, scc_condition, one, zero }); // OpSelect
    try builder.emit(&builder.body, 62, &.{ builder.mutable_scc_pointer, scc_bits });
    const carry_condition = if (builder.arithmetic_carry != 0) builder.arithmetic_carry else try falseCondition(builder);
    const carry_bits = builder.id();
    try builder.emit(&builder.body, 169, &.{ builder.bits_type, carry_bits, carry_condition, one, zero });
    try builder.emit(&builder.body, 62, &.{ builder.mutable_carry_pointer, carry_bits });
}

/// Lowers reducible natural loops through function-local guest registers. The
/// RDNA programs seen in Unity post-processing use canonical nested loops: a
/// conditional header, one latch/back edge and the header's other successor as
/// the merge. SPIR-V requires those edges to be declared with OpLoopMerge.
fn translateStructuredLoops(builder: *Builder, instructions: []const instruction.Instruction, graph: *const control_flow.Graph) Error!void {
    if (graph.back_edge_count == 0) return Error.UnsupportedControlFlow;
    const block_count = graph.blocks.items.len;
    const none = std.math.maxInt(u32);
    const loop_merges = try builder.allocator.alloc(u32, block_count);
    defer builder.allocator.free(loop_merges);
    const loop_continues = try builder.allocator.alloc(u32, block_count);
    defer builder.allocator.free(loop_continues);
    @memset(loop_merges, none);
    @memset(loop_continues, none);

    var loop_count: u32 = 0;
    for (graph.edges.items) |edge| {
        if (edge.to > edge.from) continue;
        const selection = graph.selectionForHeader(edge.to) orelse return Error.UnsupportedControlFlow;
        if (selection.merge <= edge.to or loop_merges[edge.to] != none) return Error.UnsupportedControlFlow;
        loop_merges[edge.to] = selection.merge;
        loop_continues[edge.to] = edge.from;
        loop_count += 1;
    }
    if (loop_count != graph.back_edge_count) return Error.UnsupportedControlFlow;
    // Acyclic selections retain the existing SSA path. Mixing them with loop
    // headers needs selection nesting analysis beyond the canonical loop form.
    for (graph.selections.items) |selection| {
        if (loop_merges[selection.header] == none) return Error.UnsupportedControlFlow;
    }

    try configureMutableLoopState(builder, instructions);
    const labels = try builder.allocator.alloc(u32, block_count);
    defer builder.allocator.free(labels);
    for (labels) |*label| label.* = builder.id();
    try emitMutableLoopPrelude(builder, labels[0]);

    for (graph.blocks.items) |block| {
        try builder.emit(&builder.body, 248, &.{labels[block.index]}); // OpLabel
        try loadMutableControlState(builder);

        const first: usize = block.first_instruction;
        const end: usize = first + block.instruction_count;
        const last = instructions[end - 1];
        for (instructions[first..end]) |inst| {
            if (inst.opcode.isBranch() or inst.opcode.isProgramEnd() or inst.opcode == .s_setpc_b64) continue;
            try lowerDiagnosed(builder, inst);
        }

        if (last.opcode.isProgramEnd()) {
            try builder.emit(&builder.body, 253, &.{}); // OpReturn
        } else if (last.opcode == .s_setpc_b64) {
            if (setpcSuccessor(graph, block.index)) |target| {
                try builder.emit(&builder.body, 249, &.{labels[target]});
            } else {
                try builder.exportNggLdsRecord();
                try builder.emit(&builder.body, 253, &.{});
            }
        } else if (last.opcode == .s_branch) {
            try storeMutableControlState(builder);
            const target = graph.blockForPc(last.branch_target) orelse return Error.UnsupportedControlFlow;
            try builder.emit(&builder.body, 249, &.{labels[target]});
        } else if (last.opcode.isBranch()) {
            const selection = graph.selectionForHeader(block.index) orelse return Error.UnsupportedControlFlow;
            if (loop_merges[block.index] == none or loop_merges[block.index] != selection.merge) {
                return Error.UnsupportedControlFlow;
            }
            var condition = try structuredCondition(builder, selection.condition);
            if (!selection.branch_when) {
                const inverted = builder.id();
                try builder.emit(&builder.body, 168, &.{ builder.bool_type, inverted, condition }); // OpLogicalNot
                condition = inverted;
            }
            try storeMutableControlState(builder);
            try builder.emit(&builder.body, 246, &.{ // OpLoopMerge
                labels[loop_merges[block.index]],
                labels[loop_continues[block.index]],
                0,
            });
            try builder.emit(&builder.body, 250, &.{
                condition,
                labels[selection.branch_successor],
                labels[selection.fallthrough_successor],
            });
        } else if (block.index + 1 < block_count) {
            try storeMutableControlState(builder);
            try builder.emit(&builder.body, 249, &.{labels[block.index + 1]});
        } else {
            return Error.UnsupportedControlFlow;
        }
    }
}

const dispatch_sentinel: u32 = 0xffff_ffff;

fn emitDispatchJump(builder: *Builder, after_label: u32, next_index: u32) Error!void {
    try storeMutableControlState(builder);
    try builder.emit(&builder.body, 62, &.{
        builder.dispatch_pc_pointer,
        try builder.constant(.bits32, next_index),
    });
    try builder.emit(&builder.body, 249, &.{after_label}); // OpBranch
}

fn emitDispatchConditional(
    builder: *Builder,
    graph: *const control_flow.Graph,
    block: control_flow.BasicBlock,
    last: instruction.Instruction,
    after_label: u32,
) Error!void {
    const info = directBranchCondition(last.opcode) orelse return Error.UnsupportedControlFlow;
    const target = graph.blockForPc(last.branch_target) orelse return Error.UnsupportedControlFlow;
    if (block.index + 1 >= graph.blocks.items.len) return Error.UnsupportedControlFlow;
    var condition = try structuredCondition(builder, info[0]);
    if (!info[1]) {
        const inverted = builder.id();
        try builder.emit(&builder.body, 168, &.{ builder.bool_type, inverted, condition }); // OpLogicalNot
        condition = inverted;
    }
    const taken = try builder.constant(.bits32, target);
    const not_taken = try builder.constant(.bits32, block.index + 1);
    const next = builder.id();
    try builder.emit(&builder.body, 169, &.{ // OpSelect
        builder.bits_type,
        next,
        condition,
        taken,
        not_taken,
    });
    try storeMutableControlState(builder);
    try builder.emit(&builder.body, 62, &.{ builder.dispatch_pc_pointer, next });
    try builder.emit(&builder.body, 249, &.{after_label});
}

/// Emits an irreducible or otherwise unstructured CFG as a SPIR-V dispatcher.
///
/// Each guest block is a switch case. The next block index lives in a
/// function-local variable, so back edges, shared merges and VCC/EXEC
/// divergence do not have to form a reducible loop tree.
fn translateDispatcher(builder: *Builder, instructions: []const instruction.Instruction, graph: *const control_flow.Graph) Error!void {
    if (graph.blocks.items.len == 0) return Error.UnsupportedControlFlow;
    try configureMutableLoopState(builder, instructions);
    builder.dispatch_pc_pointer = builder.id();
    const header = builder.id();
    const select = builder.id();
    const after = builder.id();
    const cont = builder.id();
    const merge = builder.id();
    const default_label = builder.id();
    const labels = try builder.allocator.alloc(u32, graph.blocks.items.len);
    defer builder.allocator.free(labels);
    for (labels) |*label| label.* = builder.id();

    try emitMutableLoopPrelude(builder, header);

    try builder.emit(&builder.body, 248, &.{header}); // OpLabel
    const pc = builder.id();
    try builder.emit(&builder.body, 61, &.{ builder.bits_type, pc, builder.dispatch_pc_pointer }); // OpLoad
    const done = builder.id();
    try builder.emit(&builder.body, 170, &.{
        builder.bool_type,
        done,
        pc,
        try builder.constant(.bits32, dispatch_sentinel),
    }); // OpIEqual
    try builder.emit(&builder.body, 246, &.{ merge, cont, 0 }); // OpLoopMerge
    try builder.emit(&builder.body, 250, &.{ done, merge, select }); // OpBranchConditional

    try builder.emit(&builder.body, 248, &.{select}); // OpLabel
    try builder.emit(&builder.body, 247, &.{ after, 0 }); // OpSelectionMerge
    var switch_args: std.ArrayList(u32) = .empty;
    defer switch_args.deinit(builder.allocator);
    try switch_args.append(builder.allocator, pc);
    try switch_args.append(builder.allocator, default_label);
    for (labels, 0..) |label, index| {
        try switch_args.append(builder.allocator, @intCast(index));
        try switch_args.append(builder.allocator, label);
    }
    try builder.emit(&builder.body, 251, switch_args.items); // OpSwitch

    try builder.emit(&builder.body, 248, &.{default_label}); // OpLabel
    try emitDispatchJump(builder, after, dispatch_sentinel);

    for (graph.blocks.items) |block| {
        try builder.emit(&builder.body, 248, &.{labels[block.index]}); // OpLabel
        try loadMutableControlState(builder);
        const first: usize = block.first_instruction;
        const end: usize = first + block.instruction_count;
        const last = instructions[end - 1];
        for (instructions[first..end]) |inst| {
            if (inst.opcode.isBranch() or inst.opcode.isProgramEnd() or inst.opcode == .s_setpc_b64) continue;
            try lowerDiagnosed(builder, inst);
        }
        if (last.opcode.isProgramEnd()) {
            try emitDispatchJump(builder, after, dispatch_sentinel);
        } else if (last.opcode == .s_setpc_b64) {
            if (setpcSuccessor(graph, block.index)) |target| {
                try emitDispatchJump(builder, after, target);
            } else {
                try builder.exportNggLdsRecord();
                try emitDispatchJump(builder, after, dispatch_sentinel);
            }
        } else if (last.opcode == .s_branch) {
            const target = graph.blockForPc(last.branch_target) orelse return Error.UnsupportedControlFlow;
            try emitDispatchJump(builder, after, target);
        } else if (last.opcode.isBranch()) {
            try emitDispatchConditional(builder, graph, block, last, after);
        } else if (block.index + 1 < graph.blocks.items.len) {
            try emitDispatchJump(builder, after, block.index + 1);
        } else {
            try emitDispatchJump(builder, after, dispatch_sentinel);
        }
    }

    try builder.emit(&builder.body, 248, &.{after}); // OpLabel
    try builder.emit(&builder.body, 249, &.{cont}); // OpBranch
    try builder.emit(&builder.body, 248, &.{cont}); // OpLabel
    try builder.emit(&builder.body, 249, &.{header}); // OpBranch
    try builder.emit(&builder.body, 248, &.{merge}); // OpLabel
    try builder.emit(&builder.body, 253, &.{}); // OpReturn
    builder.used_dispatcher = true;
}

fn translateStructured(builder: *Builder, instructions: []const instruction.Instruction, graph: *const control_flow.Graph) Error!void {
    if (graph.back_edge_count != 0) return Error.UnsupportedControlFlow;
    const labels = try builder.allocator.alloc(u32, graph.blocks.items.len);
    defer builder.allocator.free(labels);
    labels[0] = builder.label;
    for (labels[1..]) |*label| label.* = builder.id();
    // Instruction lowering may introduce internal selection blocks for bounds
    // checks and EXEC-predicated stores. The block left open afterwards is not
    // necessarily the guest block's entry label, so OpPhi cannot name `labels`
    // as its predecessor. Route every guest block through a canonical exit and
    // use those labels for all state-merge parents.
    const exit_labels = try builder.allocator.alloc(u32, graph.blocks.items.len);
    defer builder.allocator.free(exit_labels);
    for (exit_labels) |*label| label.* = builder.id();
    // SPIR-V forbids two selection headers from naming the same merge block.
    // Acyclic guest shaders commonly produce if/else-if ladders whose immediate
    // post-dominator is shared. Give every header a synthetic merge and chain
    // those blocks from the innermost (latest header) to the outermost.
    const selection_merge_labels = try builder.allocator.alloc(u32, graph.selections.items.len);
    defer builder.allocator.free(selection_merge_labels);
    for (selection_merge_labels) |*label| label.* = builder.id();
    // A conditional whose paths both terminate has no real post-dominator,
    // yet SPIR-V still requires an OpSelectionMerge target. Give those headers
    // an unreachable synthetic merge rather than discarding the branch and
    // linearly executing both paths.
    const terminal_merge_labels = try builder.allocator.alloc(u32, graph.blocks.items.len);
    defer builder.allocator.free(terminal_merge_labels);
    @memset(terminal_merge_labels, 0);
    for (graph.blocks.items) |block| {
        const last_index: usize = block.first_instruction + block.instruction_count - 1;
        const last = instructions[last_index];
        if (!last.opcode.isBranch() or last.opcode == .s_branch or
            structuredSelectionIndex(graph, block.index) != null)
        {
            continue;
        }
        if (directBranchCondition(last.opcode) == null) return Error.UnsupportedControlFlow;
        terminal_merge_labels[block.index] = builder.id();
    }
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
                    try merge_parents.append(builder.allocator, exit_labels[edge.from]);
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
                try block_parents.append(builder.allocator, exit_labels[edge.from]);
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
            incoming = try mergeState(builder, graph, states, exit_labels, block.index);
        }
        builder.restore(incoming);
        if (block.index == 0) try builder.initializeStageInputs();

        const first: usize = block.first_instruction;
        const end: usize = first + block.instruction_count;
        const last = instructions[end - 1];
        for (instructions[first..end]) |inst| {
            if (inst.opcode.isBranch() or inst.opcode.isProgramEnd() or inst.opcode == .s_setpc_b64) continue;
            try lowerDiagnosed(builder, inst);
        }
        states[block.index] = builder.snapshot();
        try builder.emit(&builder.body, 249, &.{exit_labels[block.index]}); // OpBranch
        try builder.emit(&builder.body, 248, &.{exit_labels[block.index]}); // OpLabel

        if (last.opcode.isProgramEnd()) {
            try builder.emit(&builder.body, 253, &.{}); // OpReturn
        } else if (last.opcode == .s_setpc_b64) {
            if (setpcSuccessor(graph, block.index)) |target| {
                try builder.emit(&builder.body, 249, &.{structuredEdgeLabel(
                    graph,
                    dominators,
                    labels,
                    selection_merge_labels,
                    block.index,
                    target,
                )});
            } else {
                try builder.exportNggLdsRecord();
                try builder.emit(&builder.body, 253, &.{}); // hardware NGG continuation becomes the stage return
            }
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
            const selection_index = structuredSelectionIndex(graph, block.index);
            const branch_info = if (selection_index) |index| blk: {
                const selection = graph.selections.items[index];
                break :blk .{
                    selection.condition,
                    selection.branch_when,
                    selection.branch_successor,
                    selection.fallthrough_successor,
                    selection_merge_labels[index],
                };
            } else blk: {
                const condition_info = directBranchCondition(last.opcode) orelse return Error.UnsupportedControlFlow;
                const target = graph.blockForPc(last.branch_target) orelse return Error.UnsupportedControlFlow;
                if (block.index + 1 >= graph.blocks.items.len or terminal_merge_labels[block.index] == 0) {
                    return Error.UnsupportedControlFlow;
                }
                break :blk .{
                    condition_info[0],
                    condition_info[1],
                    target,
                    block.index + 1,
                    terminal_merge_labels[block.index],
                };
            };
            var condition = try structuredCondition(builder, branch_info[0]);
            if (!branch_info[1]) {
                const inverted = builder.id();
                try builder.emit(&builder.body, 168, &.{ builder.bool_type, inverted, condition }); // OpLogicalNot
                condition = inverted;
            }
            try builder.emit(&builder.body, 247, &.{ branch_info[4], 0 }); // OpSelectionMerge
            try builder.emit(&builder.body, 250, &.{
                condition,
                if (selection_index != null)
                    structuredEdgeLabel(graph, dominators, labels, selection_merge_labels, block.index, branch_info[2])
                else
                    labels[branch_info[2]],
                if (selection_index != null)
                    structuredEdgeLabel(graph, dominators, labels, selection_merge_labels, block.index, branch_info[3])
                else
                    labels[branch_info[3]],
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
    for (terminal_merge_labels) |label| {
        if (label == 0) continue;
        try builder.emit(&builder.body, 248, &.{label}); // OpLabel
        try builder.emit(&builder.body, 255, &.{}); // OpUnreachable
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
    if (builder.uses_image_query) {
        try appendInstruction(allocator, &words, 17, &.{50}); // OpCapability ImageQuery
    }
    for (options.storage_images) |binding| {
        if (!storageImageNeedsExtendedFormats(binding.format)) continue;
        try appendInstruction(allocator, &words, 17, &.{49}); // OpCapability StorageImageExtendedFormats
        break;
    }
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
    if (builder.gds_memory != 0) try entry_point.append(allocator, builder.gds_memory);
    for (builder.sampled_image_arrays) |sampled_image_array| {
        if (sampled_image_array != 0) try entry_point.append(allocator, sampled_image_array);
    }
    for (builder.storage_image_variables) |variable| {
        if (variable != 0) try entry_point.append(allocator, variable);
    }
    if (builder.workgroup_memory != 0) try entry_point.append(allocator, builder.workgroup_memory);
    if (builder.private_memory != 0) try entry_point.append(allocator, builder.private_memory);
    if (builder.local_invocation_index != 0) try entry_point.append(allocator, builder.local_invocation_index);
    if (builder.workgroup_id_input != 0) try entry_point.append(allocator, builder.workgroup_id_input);
    if (builder.local_invocation_id_input != 0) try entry_point.append(allocator, builder.local_invocation_id_input);
    if (builder.vertex_index_input != 0) try entry_point.append(allocator, builder.vertex_index_input);
    if (builder.instance_index_input != 0) try entry_point.append(allocator, builder.instance_index_input);
    if (builder.frag_coord_input != 0) try entry_point.append(allocator, builder.frag_coord_input);
    if (builder.position_output != 0) try entry_point.append(allocator, builder.position_output);
    for (builder.color_outputs) |color_output| {
        if (color_output != 0) try entry_point.append(allocator, color_output);
    }
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
        .used_dispatcher = builder.used_dispatcher,
    };
}

fn opcodeUsesWritePredicate(opcode: isa.Opcode) bool {
    return switch (opcode) {
        .buffer_store_byte,
        .buffer_store_short,
        .buffer_store_dword,
        .buffer_store_dwordx2,
        .buffer_store_dwordx3,
        .buffer_store_dwordx4,
        .buffer_store_format_x,
        .buffer_store_format_xy,
        .buffer_store_format_xyz,
        .buffer_store_format_xyzw,
        .ds_write_b32,
        .ds_write2_b32,
        .ds_write_b64,
        .ds_write_b96,
        .ds_write_b128,
        .ds_write_addtid_b32,
        .ds_append,
        .ds_add_u32,
        .ds_sub_u32,
        .ds_min_i32,
        .ds_min_u32,
        .ds_max_i32,
        .ds_max_u32,
        .ds_and_b32,
        .ds_or_b32,
        .ds_xor_b32,
        => true,
        else => false,
    };
}

/// Translates the executable ALU/SDWA subset and forward scalar selections.
/// The writer fails explicitly for operations or control-flow shapes whose
/// semantics are not implemented; it never emits a placeholder guest shader.
pub fn translateIr(
    allocator: std.mem.Allocator,
    module: *const shader_ir.Module,
    options: Options,
) Error!Module {
    if (module.stage != .legalized) return Error.InvalidIrStage;
    return translateBackend(allocator, module.backendView(), options);
}

pub fn translateBackend(
    allocator: std.mem.Allocator,
    view: shader_ir.BackendView,
    options: Options,
) Error!Module {
    return translateInstructions(allocator, view.instructions, options);
}

/// Low-level SPIR-V backend entry point. Runtime callers normally arrive via
/// `translateIr`; this form remains public for backend unit tests and tools
/// which deliberately construct decoded instructions by hand.
pub fn translate(allocator: std.mem.Allocator, program: *const instruction.Program, options: Options) Error!Module {
    return translateInstructions(allocator, program.instructions.items, options);
}

fn translateInstructions(
    allocator: std.mem.Allocator,
    instructions: []const instruction.Instruction,
    options: Options,
) Error!Module {
    var effective = options;
    var has_predicated_write = false;
    for (effective.ngg_lds_exports) |ngg_export| {
        if (effective.stage == .vertex and ngg_export.target >= 0x20 and ngg_export.target < 0x40) {
            effective.parameter_mask |= @as(u32, 1) << @intCast(ngg_export.target - 0x20);
        }
    }
    for (instructions) |candidate| {
        if (candidate.dst.kind == .exec_lo) effective.uses_execution_mask = true;
        if (candidate.opcode == .v_writelane_b32 or candidate.opcode == .v_readlane_b32 or
            candidate.opcode == .v_permlane16_b32 or candidate.opcode == .v_permlanex16_b32 or
            candidate.opcode == .v_mbcnt_lo_u32_b32 or candidate.opcode == .v_mbcnt_hi_u32_b32 or
            candidate.opcode == .ds_swizzle_b32 or
            candidate.src0.dpp or candidate.src1.dpp or candidate.src2.dpp)
        {
            effective.uses_lane_identity = true;
        }
        has_predicated_write = has_predicated_write or opcodeUsesWritePredicate(candidate.opcode);
        // Some system compute kernels use LDS while COMPUTE_PGM_RSRC2 reports
        // LDS_SIZE=0.  Hardware still exposes a small default LDS window to
        // these kernels (and they program M0 with their effective bound).
        // Keep a conservative 4 KiB fallback, matching the window used by the
        // reference implementation, so a legitimate DS access is not rejected
        // before the shader can run.
        if (effective.stage == .compute and effective.workgroup_memory_size_bytes == 0 and
            candidate.family == .ds and !candidate.gds)
        {
            effective.workgroup_memory_size_bytes = 4096;
        }
        if (effective.stage != .compute and effective.private_memory_size_bytes == 0 and
            (candidate.opcode == .ds_write_addtid_b32 or candidate.opcode == .ds_read_addtid_b32))
        {
            // Graphics addtid is compiler-generated per-lane spill/fill. A
            // Private array preserves that isolation without exposing an
            // invalid Workgroup storage class to a fragment shader.
            effective.private_memory_size_bytes = 32 * 1024;
        }
        switch (effective.stage) {
            .vertex => if (candidate.opcode == .exp and candidate.export_target >= 0x20) {
                effective.parameter_mask |= @as(u32, 1) << @intCast(candidate.export_target - 0x20);
            },
            .fragment => {
                if (candidate.opcode == .exp and candidate.export_target < 8) {
                    effective.color_export_mask |= @as(u8, 1) << @intCast(candidate.export_target);
                }
                if (effective.infer_fragment_parameter_mask) switch (candidate.opcode) {
                    .v_interp_p1_f32, .v_interp_p2_f32, .v_interp_mov_f32 => {
                        if (candidate.src1.kind == .integer_inline_constant and candidate.src1.value < 32) {
                            effective.parameter_mask |= @as(u32, 1) << @intCast(candidate.src1.value);
                        }
                    },
                    else => {},
                };
            },
            .compute => {},
        }
    }
    effective.uses_lane_identity = effective.uses_lane_identity or effective.uses_execution_mask or
        (effective.uses_execution_mask and has_predicated_write);
    var builder = try Builder.init(allocator, effective);
    var builder_alive = true;
    defer if (builder_alive) builder.deinit();
    var graph = try control_flow.buildInstructions(allocator, instructions);
    defer graph.deinit(allocator);
    if (graph.blocks.items.len == 1) {
        try builder.emit(&builder.body, 248, &.{builder.label});
        try builder.initializeStageInputs();
        for (instructions) |inst| try lowerDiagnosed(&builder, inst);
        try builder.emit(&builder.body, 253, &.{});
    } else {
        const structured_result = if (graph.back_edge_count == 0)
            translateStructured(&builder, instructions, &graph)
        else
            translateStructuredLoops(&builder, instructions, &graph);
        structured_result catch |err| {
            if (err != Error.UnsupportedControlFlow) return err;
            // Structured lowering may already have created labels before
            // discovering an unsupported shape. Restart so the dispatcher
            // (and the linear fallback) do not refer to IDs whose defining
            // instructions were discarded.
            builder.deinit();
            builder_alive = false;
            builder = try Builder.init(allocator, effective);
            builder_alive = true;
            translateDispatcher(&builder, instructions, &graph) catch |dispatch_err| {
                if (dispatch_err != Error.UnsupportedControlFlow) return dispatch_err;
                if (!effective.allow_control_flow_fallback) return err;
                builder.deinit();
                builder_alive = false;
                builder = try Builder.init(allocator, effective);
                builder_alive = true;
                builder.used_control_flow_fallback = true;
                try builder.emit(&builder.body, 248, &.{builder.label});
                try builder.initializeStageInputs();
                for (instructions) |inst| {
                    if (inst.opcode.isBranch()) continue;
                    try lowerDiagnosed(&builder, inst);
                }
                try builder.emit(&builder.body, 253, &.{});
            };
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

fn expectPhiParentsArePredecessors(words: []const u32) !void {
    const Edge = struct { source: u32, target: u32 };
    const PhiParent = struct { block: u32, parent: u32 };
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(std.testing.allocator);
    var phi_parents: std.ArrayList(PhiParent) = .empty;
    defer phi_parents.deinit(std.testing.allocator);

    var current_label: u32 = 0;
    var index: usize = 5;
    while (index < words.len) {
        const first = words[index];
        const word_count: usize = first >> 16;
        try std.testing.expect(word_count != 0 and index + word_count <= words.len);
        const opcode: u16 = @truncate(first);
        switch (opcode) {
            248 => current_label = words[index + 1], // OpLabel
            249 => try edges.append(std.testing.allocator, .{ // OpBranch
                .source = current_label,
                .target = words[index + 1],
            }),
            250 => { // OpBranchConditional
                try edges.append(std.testing.allocator, .{ .source = current_label, .target = words[index + 2] });
                try edges.append(std.testing.allocator, .{ .source = current_label, .target = words[index + 3] });
            },
            251 => { // OpSwitch
                try edges.append(std.testing.allocator, .{ .source = current_label, .target = words[index + 2] });
                var target_index = index + 4;
                while (target_index < index + word_count) : (target_index += 2) {
                    try edges.append(std.testing.allocator, .{ .source = current_label, .target = words[target_index] });
                }
            },
            245 => { // OpPhi
                var parent_index = index + 4;
                while (parent_index < index + word_count) : (parent_index += 2) {
                    try phi_parents.append(std.testing.allocator, .{
                        .block = current_label,
                        .parent = words[parent_index],
                    });
                }
            },
            else => {},
        }
        index += word_count;
    }

    for (phi_parents.items) |phi| {
        var found = false;
        for (edges.items) |edge| {
            if (edge.source == phi.parent and edge.target == phi.block) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
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

test "typed IR pipeline feeds SPIR-V emission" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
        0x3f80_0000,
        (@as(u32, 3) << 25) | (@as(u32, 1) << 17) | 256,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var ir_module = try shader_ir.lower(std.testing.allocator, &program);
    defer ir_module.deinit(std.testing.allocator);
    var module = try translateIr(
        std.testing.allocator,
        &ir_module,
        .{ .stage = .compute, .local_size = .{ 8, 1, 1 } },
    );
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(shader_ir.PipelineStage.legalized, ir_module.stage);
    try std.testing.expect(ir_module.optimization.constant_folds >= 2);
    try std.testing.expect(ir_module.optimization.dead_instructions >= 1);
    try std.testing.expect(!containsOpcode(module.words, 129)); // dead OpFAdd
}

test "VOP1 signed I4 interpolation offset converts to fractional float" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0x7e0e_1c84, // v_cvt_off_f32_i4 v7, -4 -> -0.25
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(isa.Opcode.v_cvt_off_f32_i4, program.instructions.items[0].opcode);

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 195)); // OpShiftRightArithmetic (sign extension)
    try std.testing.expect(containsOpcode(module.words, 111)); // OpConvertSToF
    try std.testing.expect(containsOpcode(module.words, 136)); // OpFDiv
}

test "compute hardware SGPR holes are deterministic zero masks" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .family = .sop2,
        .opcode = .s_and_b64,
        .dst = .{ .kind = .sgpr, .reg = 0 },
        .src0 = .{ .kind = .sgpr, .reg = 34 },
        .src1 = .{ .kind = .sgpr, .reg = 38 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 4, .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 199)); // OpBitwiseAnd
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

test "trap waitcnt-depctr and packed f16 add lower" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbf92_0000, // s_trap
        0xbfa3_0000, // s_waitcnt_depctr
        0xcc0f_0002, // v_pk_add_f16 v2, s0, s1
        0x0002_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 129)); // OpFAdd on unpacked f16 pair
    try std.testing.expect(containsOpcode(module.words, 253));
}

test "permlane mix and image resinfo lower" {
    const decoder = @import("decoder.zig");
    const permlane_code = [_]u32{
        0xd777_0001, // v_permlane16_b32 v1, v0, s0, s1
        0x0002_0000,
        0xbf81_0000,
    };
    var permlane_program = try decoder.decodeProgram(std.testing.allocator, &permlane_code);
    defer permlane_program.deinit(std.testing.allocator);
    var permlane_module = try translate(std.testing.allocator, &permlane_program, .{ .stage = .compute });
    defer permlane_module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(permlane_module.words, 345)); // OpGroupNonUniformShuffle

    const resinfo_code = [_]u32{
        0xf038_0f00, // image_get_resinfo dim:2d dmask:xyzw
        0x0040_0000,
        0xbf81_0000,
    };
    var resinfo_program = try decoder.decodeProgram(std.testing.allocator, &resinfo_code);
    defer resinfo_program.deinit(std.testing.allocator);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 0,
        .sampler_sgpr = 8,
        .descriptor_index = 0,
    }};
    var resinfo_module = try translate(std.testing.allocator, &resinfo_program, .{
        .stage = .compute,
        .sampled_images = &images,
    });
    defer resinfo_module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(resinfo_module.words, 50) or containsOpcode(resinfo_module.words, 107));
}

test "packed integer add and mad mix lower" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xcc02_0002, // v_pk_add_i16 v2, s0, s1
        0x0002_0000,
        0xcc21_0003, // v_mad_mixlo_f16 v3, s0, s1, s2
        0x0004_0200,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 128)); // OpIAdd
    try std.testing.expect(containsOpcode(module.words, 12)); // GLSL Fma / pack
}

test "64-bit bit scan popcount and quad mask lower" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbe80_1400, // s_ff1_i32_b64 s0, s0
        0xbe80_1600, // s_flbit_i32_b64 s0, s0
        0xbe80_1000, // s_bcnt1_i32_b64 s0, s0
        0xbe80_2d00, // s_quadmask_b64 s0, s0
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 205)); // OpBitCount
    try std.testing.expect(containsOpcode(module.words, 12)); // FindILsb / FindUMsb
}

test "vector class compare and 64-bit equality lower" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_cmp_class_f32,
        .dst = .{ .kind = .vcc_lo },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .vgpr, .reg = 1 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .v_cmp_eq_i64,
        .dst = .{ .kind = .vcc_lo },
        .src0 = .{ .kind = .vgpr, .reg = 2 },
        .src1 = .{ .kind = .vgpr, .reg = 4 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 170)); // OpIEqual
}

test "fragment depth-compare sample uses Dref explicit lod" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf0bc_0f08, // image_sample_c_lz dim:2d dmask:xyzw
        0x0040_0200,
        0xf800_080f,
        0x0504_0302,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expect(program.instructions.items[0].image_sample_flags.compare);
    try std.testing.expect(program.instructions.items[0].image_sample_flags.level_zero);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 0,
        .sampler_sgpr = 8,
        .descriptor_index = 0,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 90)); // OpImageSampleDrefExplicitLod
}

test "buffer float atomics lower through atomic load and store" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .buffer_atomic_fmin,
        .family = .mubuf,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .vgpr, .reg = 1 },
        .src1 = .{ .kind = .sgpr, .reg = 4 },
        .src2 = .{ .kind = .integer_inline_constant, .value = 0 },
        .src_count = 3,
        .globally_coherent = true,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 4, .descriptor_index = 0, .extent_bytes = 16 }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 227)); // OpAtomicLoad
    try std.testing.expect(containsOpcode(module.words, 228)); // OpAtomicStore
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

    var converted = try translate(std.testing.allocator, &program, .{
        .stage = .vertex,
        .vertex_index_vgpr = 0,
        .convert_negative_one_to_one_depth = true,
    });
    defer converted.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(converted.words, 129)); // OpFAdd z + w
    try std.testing.expect(containsOpcode(converted.words, 133)); // OpFMul by 0.5
}

test "GETPC SETPC continuation still exports position" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_getpc_b64,
        .dst = .{ .kind = .sgpr, .reg = 0 },
        .word_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .s_add_u32,
        .dst = .{ .kind = .sgpr, .reg = 0 },
        .src0 = .{ .kind = .sgpr, .reg = 0 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 8 },
        .src_count = 2,
        .word_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .opcode = .s_setpc_b64,
        .src0 = .{ .kind = .sgpr, .reg = 0 },
        .src_count = 1,
        .word_count = 1,
    });
    inline for (.{ 0, 1, 2, 3 }) |component| {
        try program.instructions.append(std.testing.allocator, .{
            .pc = 12 + component * 4,
            .opcode = .v_cvt_f32_i32,
            .dst = .{ .kind = .vgpr, .reg = component },
            .src0 = .{ .kind = .vgpr, .reg = 5 },
            .src_count = 1,
            .word_count = 1,
        });
    }
    try program.instructions.append(std.testing.allocator, .{
        .pc = 28,
        .opcode = .exp,
        .export_target = 0x0c,
        .export_enable = 0xf,
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .vgpr, .reg = 1 },
        .src2 = .{ .kind = .vgpr, .reg = 2 },
        .src3 = .{ .kind = .vgpr, .reg = 3 },
        .src_count = 4,
        .word_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 36, .opcode = .s_endpgm, .word_count = 1 });

    var module = try translate(std.testing.allocator, &program, .{
        .stage = .vertex,
        .vertex_index_vgpr = 0,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), countOpcode(module.words, 62)); // OpStore Position
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

test "fragment MRT0 and MRT1 export distinct color locations" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .exp,
        .export_target = 0,
        .export_enable = 0xf,
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .vgpr, .reg = 1 },
        .src2 = .{ .kind = .vgpr, .reg = 2 },
        .src3 = .{ .kind = .vgpr, .reg = 3 },
        .src_count = 4,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .exp,
        .export_target = 1,
        .export_enable = 0xf,
        .export_done = true,
        .src0 = .{ .kind = .vgpr, .reg = 4 },
        .src1 = .{ .kind = .vgpr, .reg = 5 },
        .src2 = .{ .kind = .vgpr, .reg = 6 },
        .src3 = .{ .kind = .vgpr, .reg = 7 },
        .src_count = 4,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 62)); // OpStore MRT0 and MRT1
    try std.testing.expectEqual(@as(usize, 3), countOpcode(module.words, 71)); // FragCoord + Location 0 + Location 1
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

test "ambiguous DIM5 sample follows the materialized 3D descriptor" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf080_0f28, // image_sample dim:2d_array_alt, three coordinates
        0x0040_0200,
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
    try std.testing.expectEqual(@as(u32, 0), firstInstructionOperand(module.words, 25, 4)); // not arrayed
    try std.testing.expect(containsOpcode(module.words, 87));
}

test "DIM5 sample declares a two-dimensional array for an array descriptor" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf080_0f28, // image_sample dim:2d_array_alt, uv plus layer
        0x0040_0200,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]SampledImageBinding{.{
        .resource_sgpr = 0,
        .sampler_sgpr = 8,
        .descriptor_index = 0,
        .dimension = .two_d_array,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), firstInstructionOperand(module.words, 25, 2)); // Dim2D
    try std.testing.expectEqual(@as(u32, 1), firstInstructionOperand(module.words, 25, 4)); // arrayed
    try std.testing.expect(containsOpcode(module.words, 87));
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
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 23)); // uint2 coords + one shared float4 texel type
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

test "compute image store accepts a partial channel mask" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf020_0328, // image_store dim:2d_array dmask:xy v0:v1, v[4:6], s[16:23]
        0x0004_0004,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]StorageImageBinding{.{
        .resource_sgpr = 16,
        .descriptor_index = 0,
        .format = .rg16_float,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 99)); // OpImageWrite
    try std.testing.expectEqual(@as(usize, 4), countOpcode(module.words, 17)); // includes StorageImageExtendedFormats
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

test "compute R32 UINT image atomics use texel pointers" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf044_2108, 0x0000_0301, // image_atomic_add glc v3, v[1:2], T#s0
        0xf05c_0108, 0x0000_0d00, // image_atomic_umax v13, v[0:1], T#s0
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const images = [_]StorageImageBinding{.{
        .resource_sgpr = 0,
        .descriptor_index = 0,
        .format = .r32_uint,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_images = &images,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 60)); // OpImageTexelPointer
    try std.testing.expectEqual(
        firstInstructionOperand(module.words, 59, 1), // storage-image OpVariable result
        firstInstructionOperand(module.words, 60, 2), // OpImageTexelPointer Image
    );
    try std.testing.expect(containsOpcode(module.words, 234)); // OpAtomicIAdd
    try std.testing.expect(containsOpcode(module.words, 239)); // OpAtomicUMax
    try std.testing.expect(containsOpcode(module.words, 225)); // device memory barrier
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

test "vector bit reverse lowers to SPIR-V" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0x7e18_70bc, // v_bfrev_b32 v12, v60
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 204)); // OpBitReverse
}

test "scalar bit compare tests a dynamically selected bit" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_bitcmp1_b32,
        .src0 = .{ .kind = .literal_constant, .value = 0x80 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 7 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .opcode = .s_bitcmp0_b32,
        .src0 = .{ .kind = .literal_constant, .value = 0x80 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 3 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 194)); // OpShiftRightLogical
    try std.testing.expect(containsOpcode(module.words, 170)); // OpIEqual
    try std.testing.expect(containsOpcode(module.words, 171)); // OpINotEqual
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
    try std.testing.expectEqual(
        firstInstructionOperand(module.words, 59, 1), // Workgroup OpVariable result
        firstInstructionOperand(module.words, 15, 4), // first OpEntryPoint interface
    );
}

test "fragment DS addtid spill and fill use private per-invocation scratch" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_mov_b32,
        .dst = .{ .kind = .m0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 0 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 7 },
        .src0 = .{ .kind = .literal_constant, .value = 0x3f00_0000 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .family = .ds,
        .opcode = .ds_write_addtid_b32,
        .src1 = .{ .kind = .vgpr, .reg = 7 },
        .memory_offset = 256,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 16,
        .family = .ds,
        .opcode = .ds_read_addtid_b32,
        .dst = .{ .kind = .vgpr, .reg = 8 },
        .memory_offset = 256,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 24, .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 28)); // OpTypeArray
    try std.testing.expect(containsOpcode(module.words, 65)); // OpAccessChain
    try std.testing.expect(containsOpcode(module.words, 62)); // OpStore
    try std.testing.expect(containsOpcode(module.words, 61)); // OpLoad
}

test "compute DS append atomically reserves persistent GDS entries" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_mov_b32,
        .dst = .{ .kind = .m0 },
        .src0 = .{ .kind = .literal_constant, .value = 8 }, // base 0, size 8
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .family = .ds,
        .opcode = .ds_append,
        .dst = .{ .kind = .vgpr, .reg = 3 },
        .memory_offset = 4,
        .gds = true,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 12, .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .gds_storage = true,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 65)); // OpAccessChain
    try std.testing.expect(containsOpcode(module.words, 234)); // OpAtomicIAdd
    try std.testing.expect(containsOpcode(module.words, 225)); // OpMemoryBarrier
}

test "compute DS access gets the hardware default LDS window when RSRC2 size is zero" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .family = .ds,
        .opcode = .ds_read_b32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .local_size = .{ 64, 1, 1 },
        .compute_inputs = .{ .local_invocation_id_components = 1 },
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 28)); // OpTypeArray
    try std.testing.expect(containsOpcode(module.words, 65)); // OpAccessChain
    try std.testing.expect(containsOpcode(module.words, 61)); // OpLoad
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

test "terminal conditional paths use an unreachable synthetic merge" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_cmp_eq_u32,
        .src0 = .{ .kind = .integer_inline_constant, .value = 1 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 1 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .s_cbranch_scc0,
        .branch_target = 12,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_endpgm });
    try program.instructions.append(std.testing.allocator, .{ .pc = 12, .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 247)); // OpSelectionMerge
    try std.testing.expect(containsOpcode(module.words, 255)); // OpUnreachable
    try std.testing.expect(!module.used_control_flow_fallback);
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

test "compute EXECZ selection uses the per-lane predicate" {
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
    try std.testing.expect(containsOpcode(module.words, 247)); // OpSelectionMerge
    try std.testing.expect(containsOpcode(module.words, 250)); // OpBranchConditional
    try std.testing.expect(!module.used_control_flow_fallback);
    try std.testing.expect(!module.used_dispatcher);
}

test "structured merge phi names canonical exit after a guarded store" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .family = .vop1,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 0 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .family = .vopc,
        .opcode = .v_cmpx_gt_u32,
        .dst = .{ .kind = .exec_lo },
        .src0 = .{ .kind = .integer_inline_constant, .value = 2, .signed_val = 2 },
        .src1 = .{ .kind = .integer_inline_constant, .value = 1, .signed_val = 1 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .family = .sopp,
        .opcode = .s_cbranch_execz,
        .branch_target = 24,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 12,
        .family = .vop1,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1, .signed_val = 1 },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 16,
        .word_count = 2,
        .family = .mubuf,
        .opcode = .buffer_store_dword,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .sgpr, .reg = 4 },
        .src2 = .{ .kind = .integer_inline_constant, .value = 0 },
        .src_count = 3,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 24,
        .family = .sopp,
        .opcode = .s_endpgm,
    });
    const storage = [_]StorageBufferBinding{.{
        .resource_sgpr = 4,
        .descriptor_index = 0,
        .extent_bytes = 16,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 245)); // OpPhi
    try expectPhiParentsArePredecessors(module.words);
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

test "unstructured back edges lower through a dispatcher" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{ 0xbf80_0000, 0xbf82_fffe, 0xbf81_0000 };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(module.used_dispatcher);
    try std.testing.expect(!module.used_control_flow_fallback);
    try std.testing.expect(containsOpcode(module.words, 246)); // OpLoopMerge
    try std.testing.expect(containsOpcode(module.words, 251)); // OpSwitch
    try std.testing.expect(containsOpcode(module.words, 253)); // OpReturn
}

test "an irreducible cycle lowers through a dispatcher" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .s_cbranch_scc0,
        .branch_target = 8,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 4,
        .opcode = .s_branch,
        .branch_target = 12,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 8,
        .opcode = .s_branch,
        .branch_target = 12,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 12,
        .opcode = .s_cbranch_scc0,
        .branch_target = 4,
    });
    try program.instructions.append(std.testing.allocator, .{
        .pc = 16,
        .opcode = .s_endpgm,
    });
    var graph = try control_flow.build(std.testing.allocator, &program);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expect(graph.irreducible);
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .allow_control_flow_fallback = false,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(module.used_dispatcher);
    try std.testing.expect(containsOpcode(module.words, 246)); // OpLoopMerge
    try std.testing.expect(containsOpcode(module.words, 251)); // OpSwitch
}

test "nested natural loops lower with structured loop merges" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    const s0 = operand.Operand{ .kind = .sgpr, .reg = 0 };
    const s1 = operand.Operand{ .kind = .sgpr, .reg = 1 };
    const zero = operand.Operand{ .kind = .integer_inline_constant, .value = 0 };
    const one = operand.Operand{ .kind = .integer_inline_constant, .value = 1 };
    const two = operand.Operand{ .kind = .integer_inline_constant, .value = 2 };
    const three = operand.Operand{ .kind = .integer_inline_constant, .value = 3 };
    try program.instructions.append(std.testing.allocator, .{ .pc = 0, .opcode = .s_mov_b32, .dst = s0, .src0 = zero, .src_count = 1 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 4, .opcode = .s_cmp_lt_i32, .src0 = s0, .src1 = two, .src_count = 2 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_cbranch_scc0, .branch_target = 40 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 12, .opcode = .s_mov_b32, .dst = s1, .src0 = zero, .src_count = 1 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 16, .opcode = .s_cmp_lt_i32, .src0 = s1, .src1 = three, .src_count = 2 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 20, .opcode = .s_cbranch_scc0, .branch_target = 32 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 24, .opcode = .s_add_i32, .dst = s1, .src0 = s1, .src1 = one, .src_count = 2 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 28, .opcode = .s_branch, .branch_target = 16 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 32, .opcode = .s_add_i32, .dst = s0, .src0 = s0, .src1 = one, .src_count = 2 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 36, .opcode = .s_branch, .branch_target = 4 });
    try program.instructions.append(std.testing.allocator, .{ .pc = 40, .opcode = .s_endpgm });

    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 246)); // OpLoopMerge
    try std.testing.expect(!module.used_control_flow_fallback);
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
    try std.testing.expect(fallback_module.used_dispatcher);
    try std.testing.expect(!fallback_module.used_control_flow_fallback);
    try std.testing.expect(containsOpcode(fallback_module.words, 251)); // OpSwitch
    try std.testing.expect(containsOpcode(straight_module.words, 253)); // OpReturn
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

test "v_writelane_b32 selects the current lane" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .opcode = .v_writelane_b32,
        .dst = .{ .kind = .vgpr, .reg = 0 },
        .src0 = .{ .kind = .sgpr, .reg = 0 },
        .src1 = .{ .kind = .sgpr, .reg = 1 },
        .src_count = 2,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_endpgm });
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .local_size = .{ 64, 1, 1 },
        .scalar_registers = &.{
            .{ .register = 0, .value = 1 },
            .{ .register = 1, .value = 0 },
        },
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 169)); // OpSelect
    try std.testing.expect(containsOpcode(module.words, 170)); // OpIEqual
}

test "image_sample_d lowers explicit derivatives" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .family = .mimg,
        .opcode = .image_sample,
        .opcode_id = 0x22,
        .dst = .{ .kind = .vgpr, .reg = 2 },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .sgpr, .reg = 0 },
        .src2 = .{ .kind = .sgpr, .reg = 8 },
        .src_count = 3,
        .image_dimension = .dim_2d,
        .image_address_components = 6,
        .image_sample_flags = .{ .derivative = true },
        .data_mask = 0xf,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_endpgm });
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &.{
            .{ .resource_sgpr = 0, .sampler_sgpr = 8, .descriptor_index = 0, .instruction_pc = 0, .dimension = .two_d },
        },
        .descriptor_array_length = 8,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 88)); // OpImageSampleExplicitLod
    try std.testing.expect(!containsOpcode(module.words, 87)); // not implicit LOD
}

test "1D image sample uses a height-1 2D descriptor" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .family = .mimg,
        .opcode = .image_sample,
        .opcode_id = 0x20,
        .dst = .{ .kind = .vgpr, .reg = 2 },
        .src0 = .{ .kind = .vgpr, .reg = 0 },
        .src1 = .{ .kind = .sgpr, .reg = 0 },
        .src2 = .{ .kind = .sgpr, .reg = 8 },
        .src_count = 3,
        .image_dimension = .dim_1d,
        .image_address_components = 1,
        .data_mask = 0xf,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_endpgm });
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .fragment,
        .sampled_images = &.{
            .{ .resource_sgpr = 0, .sampler_sgpr = 8, .descriptor_index = 0, .instruction_pc = 0, .dimension = .two_d },
        },
        .descriptor_array_length = 8,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), firstInstructionOperand(module.words, 25, 2)); // Dim2D
    try std.testing.expect(containsOpcode(module.words, 87)); // OpImageSampleImplicitLod
}

test "DPP quad_perm shuffles from the selected lane of the quad" {
    var program = instruction.Program{ .code = &.{}, .instructions = .empty };
    defer program.deinit(std.testing.allocator);
    try program.instructions.append(std.testing.allocator, .{
        .pc = 0,
        .family = .vop1,
        .opcode = .v_mov_b32,
        .dst = .{ .kind = .vgpr, .reg = 1 },
        .src0 = .{ .kind = .integer_inline_constant, .value = 1, .dpp = true, .dpp_ctrl = 0x1b },
        .src_count = 1,
    });
    try program.instructions.append(std.testing.allocator, .{ .pc = 8, .opcode = .s_endpgm });
    var module = try translate(std.testing.allocator, &program, .{ .stage = .fragment });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 345)); // OpGroupNonUniformShuffle
}

test "fragment color export mapping selects logical channels for physical storage" {
    const rgba = [4]u32{ 10, 20, 30, 40 };
    try std.testing.expectEqual(rgba, remapColorExportComponents(rgba, 0xe4));
    try std.testing.expectEqual(
        [4]u32{ 30, 20, 10, 40 },
        remapColorExportComponents(rgba, 0xc6),
    );
    try std.testing.expectEqual(
        [4]u32{ 40, 30, 20, 10 },
        remapColorExportComponents(rgba, 0x1b),
    );
}
