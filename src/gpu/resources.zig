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
    descriptor_flags: u32,
    extended: bool,

    pub fn isNull(self: ImageDescriptor) bool {
        return self.address == 0;
    }

    pub fn resourceMipLevels(self: ImageDescriptor) u8 {
        var largest = @max(self.width, self.height);
        if (self.image_type == .color_3d) largest = @max(largest, self.depth_or_layers);
        var maximum: u8 = 1;
        while (largest > 1) : (maximum += 1) largest >>= 1;
        if (!self.extended) return maximum;
        return @min(@max(self.max_mip + 1, 1), maximum);
    }

    pub fn viewBaseLevel(self: ImageDescriptor) u8 {
        return @min(self.base_level, self.resourceMipLevels() - 1);
    }

    pub fn viewMipLevels(self: ImageDescriptor) u8 {
        const base = self.viewBaseLevel();
        const described = if (self.last_level >= base) self.last_level - base + 1 else 1;
        return @min(described, self.resourceMipLevels() - base);
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
    fmask_compression: bool,
    force_destination_alpha_one: bool,
    cmask_address: u64,
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
};

pub const RenderState = struct {
    color_targets: [color_target_count]?ColorTarget = [_]?ColorTarget{null} ** color_target_count,
    color_count: u8 = 0,
    active_color_count: u8 = 0,
    target_mask: u32 = std.math.maxInt(u32),
    depth_control: DepthControl,
    depth_target: ?DepthTarget,
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
    };
    for (0..color_target_count) |slot| {
        const target = decodeColorTarget(state, @intCast(slot), target_mask) orelse continue;
        result.color_targets[slot] = target;
        result.color_count += 1;
        if (target.isActive()) result.active_color_count += 1;
    }
    return result;
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

    return .{
        .slot = slot,
        .address = address,
        .width = ((attrib2 >> 14) & 0x3fff) + 1,
        .height = (attrib2 & 0x3fff) + 1,
        .depth = (attrib3 & 0x1fff) + 1,
        .pitch = if (pitch) |value| ((value & 0x7ff) + 1) * 8 else 0,
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
        .fmask_compression = info & (1 << 14) != 0,
        .force_destination_alpha_one = attrib & (1 << 17) != 0,
        .cmask_address = optionalAddress256(state, base + 7, 0x398 + index),
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
    try state.writeRegister(.context, 0x31c, (10 << 2) | (1 << 8) | (2 << 11) | (1 << 28));
    try state.writeRegister(.context, 0x31d, (2 << 12) | (1 << 15));
    try state.writeRegister(.context, 0x31f, 0x0012_0000);
    try state.writeRegister(.context, 0x323, 0x1122_3344);
    try state.writeRegister(.context, 0x324, 0x5566_7788);
    try state.writeRegister(.context, 0x325, 0x0013_0000);
    try state.writeRegister(.context, 0x390, @truncate(color_address >> 40));
    try state.writeRegister(.context, 0x398, 0);
    try state.writeRegister(.context, 0x3a8, 0);
    try state.writeRegister(.context, 0x3b0, (1919 << 14) | 1079 | (4 << 28));
    try state.writeRegister(.context, 0x3b8, 5 | (0x1b << 14) | (1 << 24));
    try state.writeRegister(.context, 0x08e, 0x0000_000f);

    const depth_address: u64 = 0x0012_3456_7800;
    try state.writeRegister(.context, 0x000, 1);
    try state.writeRegister(.context, 0x002, (1 << 24));
    try state.writeRegister(.context, 0x005, 0x0014_0000);
    try state.writeRegister(.context, 0x007, 1919 | (1079 << 16));
    try state.writeRegister(.context, 0x00b, 0x3f00_0000);
    try state.writeRegister(.context, 0x010, 3 | (0x18 << 4) | (1 << 29));
    try state.writeRegister(.context, 0x012, @truncate(depth_address >> 8));
    try state.writeRegister(.context, 0x014, @truncate(depth_address >> 8));
    try state.writeRegister(.context, 0x01a, @truncate(depth_address >> 40));
    try state.writeRegister(.context, 0x01c, @truncate(depth_address >> 40));
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

    const depth = render.depth_target.?;
    try testing.expectEqual(depth_address, depth.read_address);
    try testing.expectEqual(@as(u32, 1920), depth.width);
    try testing.expectEqual(@as(u32, 1080), depth.height);
    try testing.expectEqual(TileMode.depth, depth.tile_mode);
    try testing.expect(depth.depth_read_only);
    try testing.expectEqual(@as(f32, 0.5), depth.clear_depth);
    try testing.expect(render.depth_control.test_enabled);
    try testing.expect(render.depth_control.write_enabled);
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
