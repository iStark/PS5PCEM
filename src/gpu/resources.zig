// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Typed GFX10 resources reconstructed at a draw/dispatch boundary.
//!
//! PM4 state deliberately remains a lossless register file. This layer turns
//! the relevant words into API-neutral attachments and shader descriptors only
//! when work is emitted, so partial register updates never leave a second,
//! stale copy of GPU state behind.

const std = @import("std");
const gpu_state = @import("state.zig");

pub const Error = error{
    IncompleteDescriptor,
    InvalidDescriptor,
    InvalidFormat,
    UserDataOutOfRange,
};

pub const color_target_count: usize = 8;
/// GFX10 exposes up to 64 hardware user SGPRs for one shader stage. The
/// ordinary USER_DATA register range covers the first half; AGC indirect lists
/// may also populate the accumulator-backed upper half.
pub const maximum_user_data_words: u8 = 64;

pub const ComputeSystemRegisters = struct {
    workgroup_id_sgprs: [3]?u8 = .{ null, null, null },
    threadgroup_size_sgpr: ?u8 = null,
    local_invocation_id_components: u2 = 1,
};

/// Maps the system values appended after COMPUTE_USER_DATA to their hardware
/// SGPR/VGPR positions. RSRC2 names which workgroup components exist; local
/// invocation IDs always begin at v0 and TIDIG_COMP_CNT stores count minus one.
pub fn decodeComputeSystemRegisters(state: *const gpu_state.State) ComputeSystemRegisters {
    const rsrc2 = state.readRegister(.shader, 0x213) orelse 0;
    var next = ShaderStage.compute.activeUserDataCount(state);
    var result = ComputeSystemRegisters{
        .local_invocation_id_components = @intCast(@min(@as(u32, 3), ((rsrc2 >> 11) & 0x3) + 1)),
    };
    for ([_]u5{ 7, 8, 9 }, 0..) |bit, component| {
        if (rsrc2 & (@as(u32, 1) << bit) == 0) continue;
        result.workgroup_id_sgprs[component] = next;
        next += 1;
    }
    if (rsrc2 & (1 << 10) != 0) result.threadgroup_size_sgpr = next;
    return result;
}

pub const TileMode = enum(u5) {
    linear = 0x00,
    standard_256b = 0x01,
    standard_4kb = 0x05,
    standard_64kb = 0x09,
    partially_resident = 0x11,
    depth = 0x18,
    render_target = 0x1b,
    _,

    pub fn isLinear(self: TileMode) bool {
        return self == .linear;
    }
};

pub const ImageType = enum(u4) {
    color_1d = 8,
    color_2d = 9,
    color_3d = 10,
    cube = 11,
    color_1d_array = 12,
    color_2d_array = 13,
    color_2d_msaa = 14,
    color_2d_msaa_array = 15,

    pub fn isArray(self: ImageType) bool {
        return switch (self) {
            .color_1d_array, .color_2d_array, .color_2d_msaa_array, .cube => true,
            else => false,
        };
    }
};

pub const ShaderStage = enum {
    pixel,
    vertex,
    geometry,
    export_shader,
    hull,
    compute,

    pub fn userDataBase(self: ShaderStage) u32 {
        return switch (self) {
            .pixel => 0x00c,
            .vertex => 0x04c,
            .geometry => 0x08c,
            .export_shader => 0x0cc,
            .hull => 0x10c,
            .compute => 0x240,
        };
    }

    pub fn userDataCount(self: ShaderStage) u8 {
        _ = self;
        return maximum_user_data_words;
    }

    pub fn programRegisterBase(self: ShaderStage) u32 {
        return switch (self) {
            .pixel => 0x008,
            .vertex => 0x048,
            .geometry => 0x088,
            .export_shader => 0x0c8,
            .hull => 0x108,
            .compute => 0x20c,
        };
    }

    pub fn programAddress(self: ShaderStage, state: *const gpu_state.State) ?u64 {
        const base = self.programRegisterBase();
        const low = state.readRegister(.shader, base) orelse return null;
        const high = state.readRegister(.shader, base + 1) orelse return null;
        const address = (@as(u64, low) << 8) | (@as(u64, high & 0xff) << 40);
        return if (address == 0) null else address;
    }

    /// Decodes SPI_SHADER_PGM_RSRC2.USER_SGPR, including the sixth GFX10 bit
    /// where the register layout provides it. Some AGC default lists leave
    /// RSRC2 zero while still writing a contiguous user-data window, so the
    /// graphics stages retain that observable fallback.
    pub fn activeUserDataCount(self: ShaderStage, state: *const gpu_state.State) u8 {
        const rsrc2_offset = if (self == .compute) @as(u32, 0x213) else self.userDataBase() - 1;
        const rsrc2 = state.readRegister(.shader, rsrc2_offset) orelse return self.probedUserDataCount(state);
        var count: u8 = @truncate((rsrc2 >> 1) & 0x1f);
        if (self == .pixel or self == .vertex or self == .geometry) {
            if (rsrc2 & (1 << 27) != 0) count |= 0x20;
        }
        if (count == 0 and self != .compute) return self.probedUserDataCount(state);
        return @min(count, maximum_user_data_words);
    }

    fn probedUserDataCount(self: ShaderStage, state: *const gpu_state.State) u8 {
        var count: u8 = 0;
        while (count < maximum_user_data_words and
            state.readRegister(.shader, self.userDataBase() + count) != null) : (count += 1)
        {}
        return count;
    }
};

pub const BufferDescriptor = struct {
    address: u64,
    stride: u16,
    record_count: u32,
    size_bytes: u64,
    unified_format: u8,
    dst_select: [4]u8,
    swizzle_enabled: bool,
    index_stride: u8,
    add_thread_id: bool,
    out_of_bounds_select: u8,

    pub fn isNull(self: BufferDescriptor) bool {
        return self.address == 0 and self.record_count == 0;
    }
};

pub const ImageDescriptor = struct {
    address: u64,
    width: u32,
    height: u32,
    depth_or_layers: u32,
    pitch: u32,
    unified_format: u16,
    tile_mode: TileMode,
    image_type: ImageType,
    dst_select: [4]u8,
    base_level: u8,
    last_level: u8,
    base_array: u16,
    array_pitch: u8,
    max_mip: u8,
    min_lod: u16,
    min_lod_warning: u16,
    bc_swizzle: u8,
    metadata_address: u64,
    dcc_enabled: bool,
    cmask_fast_clear: bool,
    fmask_compression: bool,
    cmask_address: u64,
    fmask_address: u64,
    dcc_address: u64,
    descriptor_flags: u32,
    extended: bool,

    pub fn isNull(self: ImageDescriptor) bool {
        return self.address == 0;
    }

    pub fn resourceMipLevels(self: ImageDescriptor) u8 {
        if (self.image_type == .color_2d_msaa or self.image_type == .color_2d_msaa_array) return 1;
        var largest = @max(self.width, self.height);
        if (self.image_type == .color_3d) largest = @max(largest, self.depth_or_layers);
        var maximum: u8 = 1;
        while (largest > 1) : (maximum += 1) largest >>= 1;
        if (!self.extended) return maximum;
        return @min(@max(self.max_mip + 1, 1), maximum);
    }

    pub fn viewBaseLevel(self: ImageDescriptor) u8 {
        if (self.image_type == .color_2d_msaa or self.image_type == .color_2d_msaa_array) return 0;
        return @min(self.base_level, self.resourceMipLevels() - 1);
    }

    pub fn viewMipLevels(self: ImageDescriptor) u8 {
        if (self.image_type == .color_2d_msaa or self.image_type == .color_2d_msaa_array) return 1;
        const base = self.viewBaseLevel();
        const described = if (self.last_level >= base) self.last_level - base + 1 else 1;
        return @min(described, self.resourceMipLevels() - base);
    }

    /// MSAA descriptors repurpose LAST_LEVEL as log2(sample count).
    pub fn samplesLog2(self: ImageDescriptor) u8 {
        return if (self.image_type == .color_2d_msaa or self.image_type == .color_2d_msaa_array)
            @min(self.last_level, 3)
        else
            0;
    }
};

pub const SamplerDescriptor = struct {
    clamp_x: u8,
    clamp_y: u8,
    clamp_z: u8,
    maximum_anisotropy: u8,
    depth_compare: u8,
    unnormalized_coordinates: bool,
    force_srgb: bool,
    trunc_coordinates: bool,
    disable_cube_wrap: bool,
    filter_mode: u8,
    minimum_lod: f32,
    maximum_lod: f32,
    lod_bias: f32,
    magnification_filter: u8,
    minification_filter: u8,
    z_filter: u8,
    mip_filter: u8,
    border_color_pointer: u16,
    border_color_type: u8,
};

pub const ColorTarget = struct {
    slot: u8,
    address: u64,
    width: u32,
    height: u32,
    depth: u32,
    pitch: u32,
    format: u8,
    number_type: u8,
    component_swap: u8,
    tile_mode: TileMode,
    resource_type: u8,
    write_mask: u8,
    base_array_slice: u16,
    last_array_slice: u16,
    mip_level: u8,
    maximum_mip: u8,
    samples_log2: u8,
    fragments_log2: u8,
    dcc_enabled: bool,
    cmask_fast_clear: bool,
    cmask_linear: bool,
    fmask_compression: bool,
    force_destination_alpha_one: bool,
    cmask_address: u64,
    cmask_slice_bytes: u32,
    fmask_address: u64,
    dcc_address: u64,
    clear_words: [2]u32,

    pub fn isActive(self: ColorTarget) bool {
        return self.write_mask != 0;
    }
};

pub const DepthControl = struct {
    test_enabled: bool,
    write_enabled: bool,
    compare_function: u8,
    clear_enabled: bool,
    stencil_clear_enabled: bool,
};

pub const DepthTarget = struct {
    read_address: u64,
    write_address: u64,
    stencil_read_address: u64,
    stencil_write_address: u64,
    htile_address: u64,
    width: u32,
    height: u32,
    format: u8,
    stencil_format: u8,
    tile_mode: TileMode,
    stencil_tile_mode: TileMode,
    samples_log2: u8,
    maximum_mip: u8,
    base_array_slice: u16,
    last_array_slice: u16,
    mip_level: u8,
    depth_read_only: bool,
    stencil_read_only: bool,
    clear_depth: f32,
    clear_stencil: u8,
    htile_enabled: bool,
    htile_pipe_aligned: bool,
    tile_stencil_disabled: bool,
};

pub const ViewportTransform = struct {
    x_scale: f32,
    x_offset: f32,
    y_scale: f32,
    y_offset: f32,
    z_scale: f32,
    z_offset: f32,
};

pub const Scissor = struct {
    left: u16,
    top: u16,
    right: u16,
    bottom: u16,

    pub fn isSet(self: Scissor) bool {
        return self.left != 0 or self.top != 0 or self.right != 0 or self.bottom != 0;
    }

    pub fn intersect(a: Scissor, b: Scissor) Scissor {
        const left = @max(a.left, b.left);
        const top = @max(a.top, b.top);
        return .{
            .left = left,
            .top = top,
            .right = @max(left, @min(a.right, b.right)),
            .bottom = @max(top, @min(a.bottom, b.bottom)),
        };
    }
};

pub const RasterState = struct {
    cull_front: bool = false,
    cull_back: bool = false,
    clockwise_front_face: bool = false,
    polygon_mode: u2 = 0,
    polygon_type_front: u3 = 0,
    polygon_type_back: u3 = 0,
    depth_bias_front: bool = false,
    depth_bias_back: bool = false,
    rasterizer_discard: bool = false,
};

pub const BlendControl = struct {
    enabled: bool = false,
    color_source: u5 = 0,
    color_operation: u3 = 0,
    color_destination: u5 = 0,
    separate_alpha: bool = false,
    alpha_source: u5 = 0,
    alpha_operation: u3 = 0,
    alpha_destination: u5 = 0,
};

pub const ColorControl = struct {
    mode: u3 = 0,
    logic_operation: u8 = 0xcc,
};

pub const RenderState = struct {
    color_targets: [color_target_count]?ColorTarget = [_]?ColorTarget{null} ** color_target_count,
    color_count: u8 = 0,
    active_color_count: u8 = 0,
    target_mask: u32 = std.math.maxInt(u32),
    depth_control: DepthControl,
    depth_target: ?DepthTarget,
    viewport: ?ViewportTransform,
    scissor: ?Scissor,
    raster: RasterState,
    blends: [color_target_count]BlendControl,
    color_control: ColorControl,
};

pub fn decodeBufferDescriptor(words: []const u32) Error!BufferDescriptor {
    if (words.len < 4) return Error.IncompleteDescriptor;
    const word1 = words[1];
    const word3 = words[3];
    if ((word3 >> 30) != 0) return Error.InvalidDescriptor;

    const format: u8 = @truncate((word3 >> 12) & 0x7f);
    if (format != 0 and !isValidUnifiedFormat(format)) return Error.InvalidFormat;
    const stride: u16 = @truncate((word1 >> 16) & 0x3fff);
    const records = words[2];
    return .{
        .address = @as(u64, words[0]) | (@as(u64, word1 & 0xffff) << 32),
        .stride = stride,
        .record_count = records,
        .size_bytes = if (stride == 0) records else @as(u64, stride) * records,
        .unified_format = format,
        .dst_select = decodeDstSelect(word3),
        .swizzle_enabled = word1 & 0x8000_0000 != 0,
        .index_stride = @truncate((word3 >> 21) & 0x3),
        .add_thread_id = word3 & (1 << 23) != 0,
        .out_of_bounds_select = @truncate((word3 >> 28) & 0x3),
    };
}

pub fn decodeImageDescriptor(words: []const u32) Error!ImageDescriptor {
    if (words.len < 4) return Error.IncompleteDescriptor;
    const word1 = words[1];
    const word2 = words[2];
    const word3 = words[3];
    const format: u16 = @truncate((word1 >> 20) & 0x1ff);
    if (format == 0 or !isValidUnifiedFormat(format)) return Error.InvalidFormat;
    const raw_type: u8 = @truncate((word3 >> 28) & 0xf);
    if (raw_type < 8) return Error.InvalidDescriptor;
    const image_type: ImageType = @enumFromInt(@as(u4, @truncate(raw_type)));
    const address = ((@as(u64, word1 & 0xff) << 32) | words[0]) << 8;
    if (address == 0) return Error.InvalidDescriptor;

    const width = (((word1 >> 30) & 0x3) | ((word2 & 0x3fff) << 2)) + 1;
    const height = ((word2 >> 14) & 0xffff) + 1;
    const extended = words.len >= 8;
    const word4 = if (words.len >= 5) words[4] else 0;
    const word5 = if (words.len >= 6) words[5] else 0;
    const word6 = if (words.len >= 7) words[6] else 0;
    const word7 = if (words.len >= 8) words[7] else 0;
    const depth_or_layers = if (image_type.isArray() or image_type == .color_3d)
        (word4 & 0x1fff) + 1
    else
        1;
    const has_explicit_pitch = extended and
        (image_type == .color_1d or image_type == .color_2d or image_type == .color_2d_msaa) and
        word4 != 0;

    return .{
        .address = address,
        .width = width,
        .height = height,
        .depth_or_layers = depth_or_layers,
        .pitch = if (has_explicit_pitch) (word4 & 0x3fff) + 1 else width,
        .unified_format = format,
        .tile_mode = @enumFromInt(@as(u5, @truncate((word3 >> 20) & 0x1f))),
        .image_type = image_type,
        .dst_select = decodeDstSelect(word3),
        .base_level = @truncate((word3 >> 12) & 0xf),
        .last_level = @truncate((word3 >> 16) & 0xf),
        .base_array = @truncate((word4 >> 16) & 0x1fff),
        .array_pitch = @truncate(word5 & 0xf),
        .max_mip = @truncate((word5 >> 4) & 0xf),
        .min_lod = @truncate((word1 >> 8) & 0xfff),
        .min_lod_warning = @truncate((word5 >> 8) & 0xfff),
        .bc_swizzle = @truncate((word3 >> 25) & 0x7),
        .metadata_address = ((@as(u64, word7) << 8) | (word6 >> 24)) << 8,
        .dcc_enabled = false,
        .cmask_fast_clear = false,
        .fmask_compression = false,
        .cmask_address = 0,
        .fmask_address = 0,
        .dcc_address = 0,
        .descriptor_flags = word6 & 0x00ff_ffff,
        .extended = extended,
    };
}

pub fn decodeSamplerDescriptor(words: []const u32) Error!SamplerDescriptor {
    if (words.len < 4) return Error.IncompleteDescriptor;
    const raw_bias = words[2] & 0x3fff;
    const signed_bias: i32 = if (raw_bias & 0x2000 != 0)
        @as(i32, @intCast(raw_bias)) - 0x4000
    else
        @intCast(raw_bias);
    return .{
        .clamp_x = @truncate(words[0] & 0x7),
        .clamp_y = @truncate((words[0] >> 3) & 0x7),
        .clamp_z = @truncate((words[0] >> 6) & 0x7),
        .maximum_anisotropy = @truncate((words[0] >> 9) & 0x7),
        .depth_compare = @truncate((words[0] >> 12) & 0x7),
        .unnormalized_coordinates = words[0] & (1 << 15) != 0,
        .force_srgb = words[0] & (1 << 20) != 0,
        .trunc_coordinates = words[0] & (1 << 27) != 0,
        .disable_cube_wrap = words[0] & (1 << 28) != 0,
        .filter_mode = @truncate((words[0] >> 29) & 0x3),
        .minimum_lod = @as(f32, @floatFromInt(words[1] & 0xfff)) / 256.0,
        .maximum_lod = @as(f32, @floatFromInt((words[1] >> 12) & 0xfff)) / 256.0,
        .lod_bias = @as(f32, @floatFromInt(signed_bias)) / 256.0,
        .magnification_filter = @truncate((words[2] >> 20) & 0x3),
        .minification_filter = @truncate((words[2] >> 22) & 0x3),
        .z_filter = @truncate((words[2] >> 24) & 0x3),
        .mip_filter = @truncate((words[2] >> 26) & 0x3),
        .border_color_pointer = @truncate(words[3] & 0xfff),
        .border_color_type = @truncate((words[3] >> 30) & 0x3),
    };
}

pub fn bufferDescriptorFromUserData(
    state: *const gpu_state.State,
    stage: ShaderStage,
    first_word: u8,
) Error!BufferDescriptor {
    var words: [4]u32 = undefined;
    try readUserData(state, stage, first_word, &words);
    return decodeBufferDescriptor(&words);
}

pub fn imageDescriptorFromUserData(
    state: *const gpu_state.State,
    stage: ShaderStage,
    first_word: u8,
) Error!ImageDescriptor {
    var words: [8]u32 = undefined;
    try readUserData(state, stage, first_word, &words);
    return decodeImageDescriptor(&words);
}

pub fn samplerDescriptorFromUserData(
    state: *const gpu_state.State,
    stage: ShaderStage,
    first_word: u8,
) Error!SamplerDescriptor {
    var words: [4]u32 = undefined;
    try readUserData(state, stage, first_word, &words);
    return decodeSamplerDescriptor(&words);
}

pub fn decodeRenderState(state: *const gpu_state.State) RenderState {
    const target_mask = state.readRegister(.context, 0x08e) orelse std.math.maxInt(u32);
    var result = RenderState{
        .target_mask = target_mask,
        .depth_control = decodeDepthControl(state),
        .depth_target = decodeDepthTarget(state),
        .viewport = decodeViewport(state, 0),
        .scissor = decodeScissor(state, 0),
        .raster = decodeRasterState(state),
        .blends = decodeBlendControls(state),
        .color_control = decodeColorControl(state),
    };
    for (0..color_target_count) |slot| {
        const target = decodeColorTarget(state, @intCast(slot), target_mask) orelse continue;
        result.color_targets[slot] = target;
        result.color_count += 1;
        if (target.isActive()) result.active_color_count += 1;
    }
    return result;
}

pub fn decodeViewport(state: *const gpu_state.State, index: u8) ?ViewportTransform {
    if (index >= 16) return null;
    const base = 0x10f + @as(u32, index) * 6;
    const x_scale = context(state, base) orelse return null;
    const x_offset = context(state, base + 1) orelse return null;
    const y_scale = context(state, base + 2) orelse return null;
    const y_offset = context(state, base + 3) orelse return null;
    const z_scale = context(state, base + 4) orelse return null;
    const z_offset = context(state, base + 5) orelse return null;
    return .{
        .x_scale = @bitCast(x_scale),
        .x_offset = @bitCast(x_offset),
        .y_scale = @bitCast(y_scale),
        .y_offset = @bitCast(y_offset),
        .z_scale = @bitCast(z_scale),
        .z_offset = @bitCast(z_offset),
    };
}

pub fn decodeScissor(state: *const gpu_state.State, index: u8) ?Scissor {
    if (index >= 16) return null;
    const viewport_base = 0x094 + @as(u32, index) * 2;
    const viewport_tl = context(state, viewport_base);
    const viewport_br = context(state, viewport_base + 1);
    const screen_tl = context(state, 0x00c);
    const screen_br = context(state, 0x00d);
    const mode_control = context(state, 0x292);
    const viewport_enabled = mode_control == null or mode_control.? & (1 << 1) != 0;
    const decoded_viewport = decodeScissorWords(viewport_tl, viewport_br, 0x7fff);
    const viewport = if (viewport_enabled and decoded_viewport != null and decoded_viewport.?.isSet())
        decoded_viewport
    else
        null;
    // AGC reset-state blocks use an all-zero screen-scissor pair as an
    // unpatched placeholder while the viewport scissor carries the active
    // bounds. Test decoded coordinates: TL can contain only the window-offset
    // flag while the rectangle itself is still unset. Some AGC paths use an
    // all-ones pair as the same unset sentinel.
    const decoded_screen = decodeScissorWords(screen_tl, screen_br, 0xffff);
    const screen_is_unset = screen_tl != null and screen_br != null and
        screen_tl.? == std.math.maxInt(u32) and screen_br.? == std.math.maxInt(u32);
    const screen = if (!screen_is_unset and decoded_screen != null and decoded_screen.?.isSet()) decoded_screen else null;
    if (viewport) |value| return if (screen) |screen_value| value.intersect(screen_value) else value;
    return screen;
}

fn decodeScissorWords(tl: ?u32, br: ?u32, mask: u32) ?Scissor {
    const top_left = tl orelse return null;
    const bottom_right = br orelse return null;
    return .{
        .left = @truncate(top_left & mask),
        .top = @truncate((top_left >> 16) & mask),
        .right = @truncate(bottom_right & mask),
        .bottom = @truncate((bottom_right >> 16) & mask),
    };
}

test "an all-zero AGC screen scissor does not erase the viewport scissor" {
    var state = gpu_state.State{};
    try state.writeRegister(.context, 0x00c, 0);
    try state.writeRegister(.context, 0x00d, 0);
    try state.writeRegister(.context, 0x094, 1 << 31);
    try state.writeRegister(.context, 0x095, 3840 | (2160 << 16));

    const scissor = decodeScissor(&state, 0).?;
    try std.testing.expectEqual(@as(u16, 0), scissor.left);
    try std.testing.expectEqual(@as(u16, 0), scissor.top);
    try std.testing.expectEqual(@as(u16, 3840), scissor.right);
    try std.testing.expectEqual(@as(u16, 2160), scissor.bottom);
}

test "an all-ones AGC screen scissor is an unset sentinel" {
    var state = gpu_state.State{};
    try state.writeRegister(.context, 0x00c, std.math.maxInt(u32));
    try state.writeRegister(.context, 0x00d, std.math.maxInt(u32));

    try std.testing.expectEqual(@as(?Scissor, null), decodeScissor(&state, 0));
}

test "a disabled viewport scissor does not clip with reset-state zeros" {
    var state = gpu_state.State{};
    try state.writeRegister(.context, 0x00c, 0);
    try state.writeRegister(.context, 0x00d, 0);
    try state.writeRegister(.context, 0x094, 0);
    try state.writeRegister(.context, 0x095, 0);
    try state.writeRegister(.context, 0x292, 0);

    try std.testing.expectEqual(@as(?Scissor, null), decodeScissor(&state, 0));
}

test "a viewport scissor with only the offset flag is an AGC reset placeholder" {
    var state = gpu_state.State{};
    try state.writeRegister(.context, 0x00c, 0);
    try state.writeRegister(.context, 0x00d, 0);
    try state.writeRegister(.context, 0x094, 1 << 31);
    try state.writeRegister(.context, 0x095, 0);
    try state.writeRegister(.context, 0x292, 1 << 1);

    try std.testing.expectEqual(@as(?Scissor, null), decodeScissor(&state, 0));
}

pub fn decodeRasterState(state: *const gpu_state.State) RasterState {
    const mode = context(state, 0x205) orelse 0;
    const clip = context(state, 0x204) orelse 0;
    return .{
        .cull_front = mode & 1 != 0,
        .cull_back = mode & 2 != 0,
        .clockwise_front_face = mode & 4 != 0,
        .polygon_mode = @truncate((mode >> 3) & 0x3),
        .polygon_type_front = @truncate((mode >> 5) & 0x7),
        .polygon_type_back = @truncate((mode >> 8) & 0x7),
        .depth_bias_front = mode & (1 << 11) != 0,
        .depth_bias_back = mode & (1 << 12) != 0,
        .rasterizer_discard = clip & (1 << 22) != 0,
    };
}

pub fn decodeBlendControls(state: *const gpu_state.State) [color_target_count]BlendControl {
    var result = [_]BlendControl{.{}} ** color_target_count;
    for (&result, 0..) |*blend, index| {
        const raw = context(state, 0x1e0 + @as(u32, @intCast(index))) orelse continue;
        blend.* = .{
            .enabled = raw & (1 << 30) != 0,
            .color_source = @truncate(raw & 0x1f),
            .color_operation = @truncate((raw >> 5) & 0x7),
            .color_destination = @truncate((raw >> 8) & 0x1f),
            .separate_alpha = raw & (1 << 29) != 0,
            .alpha_source = @truncate((raw >> 16) & 0x1f),
            .alpha_operation = @truncate((raw >> 21) & 0x7),
            .alpha_destination = @truncate((raw >> 24) & 0x1f),
        };
    }
    return result;
}

pub fn decodeColorControl(state: *const gpu_state.State) ColorControl {
    const raw = context(state, 0x202) orelse return .{};
    return .{
        .mode = @truncate((raw >> 4) & 0x7),
        .logic_operation = @truncate(raw >> 16),
    };
}

pub fn decodeColorTarget(state: *const gpu_state.State, slot: u8, target_mask: u32) ?ColorTarget {
    if (slot >= color_target_count) return null;
    const index: u32 = slot;
    const base = 0x318 + index * 15;
    const base_low = context(state, base) orelse return null;
    const base_high = context(state, 0x390 + index) orelse return null;
    const info = context(state, base + 4) orelse return null;
    const attrib = context(state, base + 5) orelse 0;
    const attrib2 = context(state, 0x3b0 + index) orelse return null;
    const attrib3 = context(state, 0x3b8 + index) orelse return null;
    const address = address256(base_low, base_high);
    const format: u8 = @truncate((info >> 2) & 0x1f);
    if (address == 0 or format == 0) return null;
    const view = context(state, base + 3) orelse 0;
    const pitch = context(state, base + 1);
    const cmask_slice = context(state, base + 8);
    const width: u32 = ((attrib2 >> 14) & 0x3fff) + 1;
    const decoded_pitch: u32 = if (pitch) |value| ((value & 0x7ff) + 1) * 8 else 0;

    return .{
        .slot = slot,
        .address = address,
        .width = width,
        .height = (attrib2 & 0x3fff) + 1,
        .depth = (attrib3 & 0x1fff) + 1,
        .pitch = if (decoded_pitch < width) 0 else decoded_pitch,
        .format = format,
        .number_type = @truncate((info >> 8) & 0x7),
        .component_swap = @truncate((info >> 11) & 0x3),
        .tile_mode = @enumFromInt(@as(u5, @truncate((attrib3 >> 14) & 0x1f))),
        .resource_type = @truncate((attrib3 >> 24) & 0x3),
        .write_mask = @truncate((target_mask >> @intCast(index * 4)) & 0xf),
        .base_array_slice = @truncate(view & 0x1fff),
        .last_array_slice = @truncate((view >> 13) & 0x1fff),
        .mip_level = @truncate((view >> 26) & 0xf),
        .maximum_mip = @truncate((attrib2 >> 28) & 0xf),
        .samples_log2 = @truncate((attrib >> 12) & 0x7),
        .fragments_log2 = @truncate((attrib >> 15) & 0x3),
        .dcc_enabled = info & (1 << 28) != 0,
        .cmask_fast_clear = info & (1 << 13) != 0,
        .cmask_linear = info & (1 << 19) != 0,
        .fmask_compression = info & (1 << 14) != 0,
        .force_destination_alpha_one = attrib & (1 << 17) != 0,
        .cmask_address = optionalAddress256(state, base + 7, 0x398 + index),
        .cmask_slice_bytes = if (cmask_slice) |value| ((value & 0x3fff) + 1) * 256 else 0,
        .fmask_address = optionalAddress256(state, base + 9, 0x3a0 + index),
        .dcc_address = optionalAddress256(state, base + 13, 0x3a8 + index),
        .clear_words = .{
            context(state, base + 11) orelse 0,
            context(state, base + 12) orelse 0,
        },
    };
}

pub fn decodeDepthControl(state: *const gpu_state.State) DepthControl {
    const depth = context(state, 0x200) orelse 0;
    const render = context(state, 0x000) orelse 0;
    return .{
        .test_enabled = depth & (1 << 1) != 0,
        .write_enabled = depth & (1 << 2) != 0,
        .compare_function = @truncate((depth >> 4) & 0x7),
        .clear_enabled = render & 1 != 0,
        .stencil_clear_enabled = render & 2 != 0,
    };
}

pub fn decodeDepthTarget(state: *const gpu_state.State) ?DepthTarget {
    const z_info = context(state, 0x010) orelse return null;
    const size = context(state, 0x007) orelse return null;
    const format: u8 = @truncate(z_info & 0x3);
    if (format == 0) return null;

    const read_address = registerAddress256(state, 0x012, 0x01a);
    const write_address = registerAddress256(state, 0x014, 0x01c);
    if (read_address == 0 and write_address == 0) return null;
    const view = context(state, 0x002) orelse 0;
    const stencil_info = context(state, 0x011) orelse 0;
    const htile_surface = context(state, 0x2af) orelse 0;

    return .{
        .read_address = read_address,
        .write_address = write_address,
        .stencil_read_address = registerAddress256(state, 0x013, 0x01b),
        .stencil_write_address = registerAddress256(state, 0x015, 0x01d),
        .htile_address = registerAddress256(state, 0x005, 0x01e),
        .width = (size & 0x3fff) + 1,
        .height = ((size >> 16) & 0x3fff) + 1,
        .format = format,
        .stencil_format = @truncate(stencil_info & 0x1),
        .tile_mode = @enumFromInt(@as(u5, @truncate((z_info >> 4) & 0x1f))),
        .stencil_tile_mode = @enumFromInt(@as(u5, @truncate((stencil_info >> 4) & 0x1f))),
        .samples_log2 = @truncate((z_info >> 2) & 0x3),
        .maximum_mip = @truncate((z_info >> 16) & 0xf),
        .base_array_slice = @truncate((view & 0x7ff) | (((view >> 11) & 0x3) << 11)),
        .last_array_slice = @truncate(((view >> 13) & 0x7ff) | (((view >> 30) & 0x3) << 11)),
        .mip_level = @truncate((view >> 26) & 0xf),
        .depth_read_only = view & (1 << 24) != 0 or write_address == 0,
        .stencil_read_only = view & (1 << 25) != 0,
        .clear_depth = @bitCast(context(state, 0x00b) orelse @as(u32, 0x3f80_0000)),
        .clear_stencil = @truncate(context(state, 0x00a) orelse 0),
        .htile_enabled = z_info & (1 << 29) != 0,
        .htile_pipe_aligned = htile_surface & (1 << 18) != 0,
        .tile_stencil_disabled = stencil_info & (1 << 29) != 0,
    };
}

fn readUserData(
    state: *const gpu_state.State,
    stage: ShaderStage,
    first_word: u8,
    words: []u32,
) Error!void {
    if (@as(usize, first_word) + words.len > stage.userDataCount()) return Error.UserDataOutOfRange;
    for (words, 0..) |*word, index| {
        const offset = stage.userDataBase() + first_word + @as(u32, @intCast(index));
        word.* = state.readRegister(.shader, offset) orelse return Error.IncompleteDescriptor;
    }
}

fn context(state: *const gpu_state.State, offset: u32) ?u32 {
    return state.readRegister(.context, offset);
}

fn address256(low: u32, high: u32) u64 {
    return (@as(u64, low) << 8) | (@as(u64, high & 0xff) << 40);
}

fn optionalAddress256(state: *const gpu_state.State, low_offset: u32, high_offset: u32) u64 {
    const low = context(state, low_offset) orelse return 0;
    return address256(low, context(state, high_offset) orelse 0);
}

fn registerAddress256(state: *const gpu_state.State, low_offset: u32, high_offset: u32) u64 {
    return optionalAddress256(state, low_offset, high_offset);
}

fn decodeDstSelect(word: u32) [4]u8 {
    return .{
        @truncate(word & 0x7),
        @truncate((word >> 3) & 0x7),
        @truncate((word >> 6) & 0x7),
        @truncate((word >> 9) & 0x7),
    };
}

fn isValidUnifiedFormat(value: u16) bool {
    return switch (value) {
        1...29, 36, 43...45, 48...77, 128...154, 169...182 => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "buffer descriptors retain 48-bit addresses and byte extent" {
    const address: u64 = 0x1234_5678_9abc;
    const words = [_]u32{
        @truncate(address),
        @as(u32, @truncate(address >> 32)) | (32 << 16) | (1 << 31),
        19,
        0x0fac | (56 << 12) | (2 << 21) | (1 << 23),
    };
    const descriptor = try decodeBufferDescriptor(&words);

    try testing.expectEqual(address, descriptor.address);
    try testing.expectEqual(@as(u16, 32), descriptor.stride);
    try testing.expectEqual(@as(u64, 608), descriptor.size_bytes);
    try testing.expectEqual(@as(u8, 56), descriptor.unified_format);
    try testing.expectEqualSlices(u8, &.{ 4, 5, 6, 7 }, &descriptor.dst_select);
    try testing.expect(descriptor.swizzle_enabled);
    try testing.expectEqual(@as(u8, 2), descriptor.index_stride);
    try testing.expect(descriptor.add_thread_id);
}

test "image descriptors decode Gen5 dimensions views and metadata" {
    const address: u64 = 0x00ab_cdef_1200;
    const encoded_address = address >> 8;
    const width: u32 = 1920;
    const height: u32 = 1080;
    const width_minus_one = width - 1;
    const metadata: u64 = 0x0012_3456_7800;
    const words = [_]u32{
        @truncate(encoded_address),
        @as(u32, @truncate(encoded_address >> 32)) | (56 << 20) | ((width_minus_one & 0x3) << 30),
        ((width_minus_one >> 2) & 0x3fff) | ((height - 1) << 14),
        0x0fac | (1 << 12) | (3 << 16) | (0x1b << 20) | (13 << 28),
        5 | (2 << 16),
        1 | (4 << 4) | (0x120 << 8),
        0x0055_4321 | (@as(u32, @truncate(metadata >> 8)) << 24),
        @truncate(metadata >> 16),
    };
    const descriptor = try decodeImageDescriptor(&words);

    try testing.expectEqual(address, descriptor.address);
    try testing.expectEqual(width, descriptor.width);
    try testing.expectEqual(height, descriptor.height);
    try testing.expectEqual(@as(u32, 6), descriptor.depth_or_layers);
    try testing.expectEqual(ImageType.color_2d_array, descriptor.image_type);
    try testing.expectEqual(TileMode.render_target, descriptor.tile_mode);
    try testing.expectEqual(@as(u8, 1), descriptor.base_level);
    try testing.expectEqual(@as(u8, 3), descriptor.last_level);
    try testing.expectEqual(@as(u16, 2), descriptor.base_array);
    try testing.expectEqual(metadata, descriptor.metadata_address);
    try testing.expectEqual(@as(u8, 3), descriptor.viewMipLevels());
}

test "sampler descriptors normalize fixed-point lod values" {
    const words = [_]u32{
        2 | (4 << 3) | (7 << 6) | (3 << 9) | (4 << 12),
        0x180 | (0x600 << 12),
        0x3f80 | (1 << 20) | (3 << 22) | (2 << 26),
        0x123 | (2 << 30),
    };
    const descriptor = try decodeSamplerDescriptor(&words);

    try testing.expectEqual(@as(u8, 2), descriptor.clamp_x);
    try testing.expectEqual(@as(u8, 4), descriptor.clamp_y);
    try testing.expectEqual(@as(f32, 1.5), descriptor.minimum_lod);
    try testing.expectEqual(@as(f32, 6.0), descriptor.maximum_lod);
    try testing.expectEqual(@as(f32, -0.5), descriptor.lod_bias);
    try testing.expectEqual(@as(u8, 2), descriptor.mip_filter);
    try testing.expectEqual(@as(u8, 2), descriptor.border_color_type);
}

test "render state decodes PS5 color and depth target extensions" {
    var state = gpu_state.State{};
    const color_address: u64 = 0x00ab_cdef_1200;
    try state.writeRegister(.context, 0x318, @truncate(color_address >> 8));
    try state.writeRegister(.context, 0x319, 239);
    try state.writeRegister(.context, 0x31b, 2 | (5 << 13) | (1 << 26));
    try state.writeRegister(.context, 0x31c, (10 << 2) | (1 << 8) | (2 << 11) |
        (1 << 13) | (1 << 19) | (1 << 28));
    try state.writeRegister(.context, 0x31d, (2 << 12) | (1 << 15));
    try state.writeRegister(.context, 0x31f, 0x0012_0000);
    try state.writeRegister(.context, 0x320, 95);
    try state.writeRegister(.context, 0x323, 0x1122_3344);
    try state.writeRegister(.context, 0x324, 0x5566_7788);
    try state.writeRegister(.context, 0x325, 0x0013_0000);
    try state.writeRegister(.context, 0x390, @truncate(color_address >> 40));
    try state.writeRegister(.context, 0x398, 0);
    try state.writeRegister(.context, 0x3a8, 0);
    try state.writeRegister(.context, 0x3b0, (1919 << 14) | 1079 | (4 << 28));
    try state.writeRegister(.context, 0x3b8, 5 | (0x1b << 14) | (1 << 24));
    try state.writeRegister(.context, 0x08e, 0x0000_000f);
    try state.writeRegister(.context, 0x00c, 0);
    try state.writeRegister(.context, 0x00d, 1920 | (1080 << 16));
    try state.writeRegister(.context, 0x094, 10 | (20 << 16) | (1 << 31));
    try state.writeRegister(.context, 0x095, 1900 | (1060 << 16));
    const viewport_words = [_]f32{ 960, 960, 540, 540, 0.5, 0.5 };
    for (viewport_words, 0..) |value, index| {
        try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
    }
    try state.writeRegister(.context, 0x1e0, 4 | (5 << 8) | (1 << 30));
    try state.writeRegister(.context, 0x202, (1 << 4) | (0xcc << 16));
    try state.writeRegister(.context, 0x204, 0);
    try state.writeRegister(.context, 0x205, 2 | 4);

    const depth_address: u64 = 0x0012_3456_7800;
    try state.writeRegister(.context, 0x000, 1);
    try state.writeRegister(.context, 0x002, (1 << 24));
    try state.writeRegister(.context, 0x005, 0x0014_0000);
    try state.writeRegister(.context, 0x007, 1919 | (1079 << 16));
    try state.writeRegister(.context, 0x00b, 0x3f00_0000);
    try state.writeRegister(.context, 0x010, 3 | (0x18 << 4) | (1 << 29));
    try state.writeRegister(.context, 0x011, (0x18 << 4) | (1 << 29));
    try state.writeRegister(.context, 0x012, @truncate(depth_address >> 8));
    try state.writeRegister(.context, 0x014, @truncate(depth_address >> 8));
    try state.writeRegister(.context, 0x01a, @truncate(depth_address >> 40));
    try state.writeRegister(.context, 0x01c, @truncate(depth_address >> 40));
    try state.writeRegister(.context, 0x2af, 1 << 18);
    try state.writeRegister(.context, 0x200, 2 | 4 | (3 << 4));

    const render = decodeRenderState(&state);
    const color = render.color_targets[0].?;
    try testing.expectEqual(@as(u8, 1), render.color_count);
    try testing.expectEqual(@as(u8, 1), render.active_color_count);
    try testing.expectEqual(color_address, color.address);
    try testing.expectEqual(@as(u32, 1920), color.width);
    try testing.expectEqual(@as(u32, 1080), color.height);
    try testing.expectEqual(TileMode.render_target, color.tile_mode);
    try testing.expect(color.dcc_enabled);
    try testing.expect(color.cmask_fast_clear);
    try testing.expect(color.cmask_linear);
    try testing.expectEqual(@as(u64, 0x1200_0000), color.cmask_address);
    try testing.expectEqual(@as(u32, 24 * 1024), color.cmask_slice_bytes);

    const depth = render.depth_target.?;
    try testing.expectEqual(depth_address, depth.read_address);
    try testing.expectEqual(@as(u32, 1920), depth.width);
    try testing.expectEqual(@as(u32, 1080), depth.height);
    try testing.expectEqual(TileMode.depth, depth.tile_mode);
    try testing.expectEqual(TileMode.depth, depth.stencil_tile_mode);
    try testing.expect(depth.depth_read_only);
    try testing.expectEqual(@as(f32, 0.5), depth.clear_depth);
    try testing.expect(depth.htile_pipe_aligned);
    try testing.expect(depth.tile_stencil_disabled);
    try testing.expect(render.depth_control.test_enabled);
    try testing.expect(render.depth_control.write_enabled);
    try testing.expectEqual(@as(f32, 960), render.viewport.?.x_scale);
    try testing.expectEqual(@as(f32, 540), render.viewport.?.y_offset);
    try testing.expectEqual(@as(u16, 10), render.scissor.?.left);
    try testing.expectEqual(@as(u16, 1060), render.scissor.?.bottom);
    try testing.expect(render.raster.cull_back);
    try testing.expect(render.raster.clockwise_front_face);
    try testing.expect(render.blends[0].enabled);
    try testing.expectEqual(@as(u5, 4), render.blends[0].color_source);
    try testing.expectEqual(@as(u5, 5), render.blends[0].color_destination);
    try testing.expectEqual(@as(u3, 1), render.color_control.mode);
    try testing.expectEqual(@as(u8, 0xcc), render.color_control.logic_operation);
}

test "inline user-data decoding is stage-relative and complete" {
    var state = gpu_state.State{};
    const words = [_]u32{ 0x1234_5000, (16 << 16), 4, 56 << 12 };
    for (words, 0..) |word, index| {
        try state.writeRegister(.shader, ShaderStage.compute.userDataBase() + @as(u32, @intCast(index)), word);
    }
    const descriptor = try bufferDescriptorFromUserData(&state, .compute, 0);
    try testing.expectEqual(@as(u64, 0x1234_5000), descriptor.address);
    try testing.expectEqual(@as(u64, 64), descriptor.size_bytes);
    try testing.expectError(
        Error.UserDataOutOfRange,
        imageDescriptorFromUserData(&state, .compute, 60),
    );
    try testing.expectError(
        Error.IncompleteDescriptor,
        samplerDescriptorFromUserData(&state, .pixel, 0),
    );
}

test "compute system values follow the active user SGPR window" {
    var state = gpu_state.State{};
    try state.writeRegister(.shader, 0x213, (8 << 1) | (1 << 7) | (1 << 9) | (1 << 10) | (2 << 11));
    const system = decodeComputeSystemRegisters(&state);
    try testing.expectEqual(@as(?u8, 8), system.workgroup_id_sgprs[0]);
    try testing.expectEqual(@as(?u8, null), system.workgroup_id_sgprs[1]);
    try testing.expectEqual(@as(?u8, 9), system.workgroup_id_sgprs[2]);
    try testing.expectEqual(@as(?u8, 10), system.threadgroup_size_sgpr);
    try testing.expectEqual(@as(u2, 3), system.local_invocation_id_components);
}
