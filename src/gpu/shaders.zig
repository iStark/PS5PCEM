// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! AGC shader metadata and resource bindings at a draw/dispatch boundary.
//!
//! A shader header describes where AGC placed its direct resources and the
//! four logical descriptor classes. The mutable values still come from PM4:
//! the direct ShaderResourceTable entry identifies the user-SGPR pair holding
//! the guest SRT pointer. Keeping those two sources separate is important --
//! assuming that every shader uses s0:s1 silently binds arbitrary addresses.

const std = @import("std");
const gpu_state = @import("state.zig");
const resources = @import("resources.zig");

pub const maximum_metadata_entries: u16 = 4096;
pub const maximum_vertex_semantics: u8 = 32;
pub const illegal_direct_offset: u16 = 0xffff;
pub const illegal_resource_offset: u16 = 0x7fff;
const address_mask: u64 = 0x0000_ffff_ffff_ffff;

pub const Error = resources.Error || error{
    MemoryReadFailed,
    InvalidMetadata,
    MetadataCountOutOfRange,
    MissingProgram,
    UserDataOutOfRange,
    ResourceOutsideSrt,
    AddressOverflow,
    IncompleteVertexTables,
    InvalidVertexSemanticCount,
    VertexTableIndexOutOfRange,
};

/// Checked guest-memory access supplied by a capture, the live HLE or a future
/// renderer. No shader path dereferences a guest pointer directly.
pub const MemoryReader = struct {
    context: ?*anyopaque,
    read_fn: *const fn (?*anyopaque, u64, []u8) bool,

    pub fn read(self: MemoryReader, address: u64, bytes: []u8) Error!void {
        if (!self.read_fn(self.context, address, bytes)) return Error.MemoryReadFailed;
    }

    pub fn readU16(self: MemoryReader, address: u64) Error!u16 {
        var bytes: [2]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u16, &bytes, .little);
    }

    pub fn readU32(self: MemoryReader, address: u64) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }

    pub fn readU64(self: MemoryReader, address: u64) Error!u64 {
        var bytes: [8]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u64, &bytes, .little);
    }

    pub fn readWords(self: MemoryReader, address: u64, words: []u32) Error!void {
        var bytes: [8 * @sizeOf(u32)]u8 = undefined;
        const wanted = words.len * @sizeOf(u32);
        std.debug.assert(wanted <= bytes.len);
        try self.read(address, bytes[0..wanted]);
        for (words, 0..) |*word, index| {
            word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
        }
    }
};

pub const DirectResourceType = enum(u16) {
    gds_counter_range = 0,
    shader_resource_table = 1,
    sub_pointer_fetch_shader = 2,
    pointer_streamout_buffer_table = 3,
    pointer_internal_global_table = 4,
    pointer_extended_user_data = 5,
    geometry_flags = 6,
    gds_memory_range = 7,
    pointer_vertex_buffer_table = 8,
    stereo_x_offset = 9,
    pointer_vertex_attribute_table = 10,
};

pub const ResourceKind = enum(u2) {
    read_only_texture = 0,
    read_write_texture = 1,
    sampler = 2,
    constant_buffer = 3,

    pub fn descriptorWordCount(self: ResourceKind) u8 {
        return switch (self) {
            .read_only_texture, .read_write_texture => 8,
            .sampler, .constant_buffer => 4,
        };
    }
};

pub const ResourceMapping = struct {
    kind: ResourceKind,
    slot: u16,
    offset_words: u16,
    size_flag: bool,
};

/// Allocation-free view of relocated AGC metadata. Individual mapping entries
/// remain in guest memory and are fetched through MemoryReader on demand.
pub const Metadata = struct {
    header_address: u64,
    user_data_address: u64,
    direct_offsets_address: u64,
    resource_offsets_addresses: [4]u64,
    extended_user_data_size_words: u16,
    shader_resource_table_size_words: u16,
    direct_resource_count: u16,
    resource_counts: [4]u16,
    input_semantics_address: u64,
    input_semantics_count: u32,

    pub fn read(reader: MemoryReader, header_address: u64) Error!Metadata {
        const user_data_address = try reader.readU64(try addAddress(header_address, 0x08));
        if (user_data_address == 0) return Error.InvalidMetadata;

        const direct_offsets_address = try reader.readU64(user_data_address);
        var resource_offsets_addresses: [4]u64 = undefined;
        for (&resource_offsets_addresses, 0..) |*address, index| {
            address.* = try reader.readU64(try addAddress(user_data_address, 0x08 + index * 8));
        }

        const extended_size = try reader.readU16(try addAddress(user_data_address, 0x28));
        const srt_size = try reader.readU16(try addAddress(user_data_address, 0x2a));
        const direct_count = try reader.readU16(try addAddress(user_data_address, 0x2c));
        if (direct_count > maximum_metadata_entries or
            (direct_count != 0 and direct_offsets_address == 0))
        {
            return Error.MetadataCountOutOfRange;
        }

        var resource_counts: [4]u16 = undefined;
        for (&resource_counts, 0..) |*count, index| {
            count.* = try reader.readU16(try addAddress(user_data_address, 0x2e + index * 2));
            if (count.* > maximum_metadata_entries or
                (count.* != 0 and resource_offsets_addresses[index] == 0))
            {
                return Error.MetadataCountOutOfRange;
            }
        }

        const input_semantics_address = try reader.readU64(try addAddress(header_address, 0x30));
        const input_semantics_count = try reader.readU32(try addAddress(header_address, 0x50));

        return .{
            .header_address = header_address,
            .user_data_address = user_data_address,
            .direct_offsets_address = direct_offsets_address,
            .resource_offsets_addresses = resource_offsets_addresses,
            .extended_user_data_size_words = extended_size,
            .shader_resource_table_size_words = srt_size,
            .direct_resource_count = direct_count,
            .resource_counts = resource_counts,
            .input_semantics_address = input_semantics_address,
            .input_semantics_count = input_semantics_count,
        };
    }

    pub fn directResourceOffset(
        self: Metadata,
        reader: MemoryReader,
        resource_type: DirectResourceType,
    ) Error!?u16 {
        const index: u16 = @intFromEnum(resource_type);
        if (index >= self.direct_resource_count) return null;
        const address = try addAddress(self.direct_offsets_address, @as(u64, index) * 2);
        const offset = try reader.readU16(address);
        return if (offset == illegal_direct_offset) null else offset;
    }

    pub fn resourceMapping(
        self: Metadata,
        reader: MemoryReader,
        kind: ResourceKind,
        slot: u16,
    ) Error!?ResourceMapping {
        const class: usize = @intFromEnum(kind);
        if (slot >= self.resource_counts[class]) return null;
        const address = try addAddress(self.resource_offsets_addresses[class], @as(u64, slot) * 2);
        const sharp = try reader.readU16(address);
        const offset = sharp & illegal_resource_offset;
        if (offset == illegal_resource_offset) return null;
        return .{
            .kind = kind,
            .slot = slot,
            .offset_words = offset,
            .size_flag = sharp & 0x8000 != 0,
        };
    }
};

pub const Descriptor = union(ResourceKind) {
    read_only_texture: resources.ImageDescriptor,
    read_write_texture: resources.ImageDescriptor,
    sampler: resources.SamplerDescriptor,
    constant_buffer: resources.BufferDescriptor,
};

pub const Binding = struct {
    mapping: ResourceMapping,
    descriptor_address: u64,
    descriptor: Descriptor,
};

pub const DirectPointers = struct {
    fetch_shader: ?u64 = null,
    extended_user_data: ?u64 = null,
};

/// Immutable binding inputs captured exactly when a draw or dispatch crosses
/// the DCB backend interface.
pub const StageBindings = struct {
    stage: resources.ShaderStage,
    user_data_stage: resources.ShaderStage,
    program_address: u64,
    user_data_count: u8,
    /// Physical SGPR index at which USER_DATA[0] enters the scalar program.
    /// NGG export programs reserve s0:s7 for system inputs.
    scalar_user_data_base: u8,
    user_data: [resources.maximum_user_data_words]u32,
    metadata: ?Metadata,
    srt_address: ?u64,
    direct_pointers: DirectPointers,

    pub fn capture(
        state: *const gpu_state.State,
        stage: resources.ShaderStage,
        header_address: ?u64,
        reader: MemoryReader,
    ) Error!StageBindings {
        const program_address = stage.programAddress(state) orelse return Error.MissingProgram;
        const user_data_stage = selectUserDataStage(state, stage);
        const user_data_count = user_data_stage.activeUserDataCount(state);
        var user_data = [_]u32{0} ** resources.maximum_user_data_words;
        for (user_data[0..user_data_count], 0..) |*word, index| {
            word.* = state.readRegister(
                .shader,
                user_data_stage.userDataBase() + @as(u32, @intCast(index)),
            ) orelse 0;
        }

        const metadata = if (header_address) |address| try Metadata.read(reader, address) else null;
        const srt_address = if (metadata) |value|
            try findSrtAddress(value, reader, &user_data, user_data_count)
        else
            null;
        const direct_pointers = if (metadata) |value| DirectPointers{
            .fetch_shader = try findDirectPointer(
                value,
                reader,
                &user_data,
                user_data_count,
                .sub_pointer_fetch_shader,
            ),
            .extended_user_data = try findDirectPointer(
                value,
                reader,
                &user_data,
                user_data_count,
                .pointer_extended_user_data,
            ),
        } else DirectPointers{};
        return .{
            .stage = stage,
            .user_data_stage = user_data_stage,
            .program_address = program_address,
            .user_data_count = user_data_count,
            .scalar_user_data_base = if (stage == .export_shader) 8 else 0,
            .user_data = user_data,
            .metadata = metadata,
            .srt_address = srt_address,
            .direct_pointers = direct_pointers,
        };
    }

    pub fn directPointer(
        self: *const StageBindings,
        reader: MemoryReader,
        resource_type: DirectResourceType,
    ) Error!?u64 {
        const metadata = self.metadata orelse return null;
        return findDirectPointer(
            metadata,
            reader,
            &self.user_data,
            self.user_data_count,
            resource_type,
        );
    }

    pub fn extendedUserDataWord(self: *const StageBindings, reader: MemoryReader, index: u16) Error!?u32 {
        const metadata = self.metadata orelse return null;
        if (index >= metadata.extended_user_data_size_words) return null;
        const address = self.direct_pointers.extended_user_data orelse return null;
        return @as(?u32, try reader.readU32(try addAddress(address, @as(u64, index) * 4)));
    }

    /// Resolves a V# already resident in scalar user data. This is the direct
    /// path used by MUBUF instructions before scalar-memory descriptor loads
    /// are executable: the instruction names the first physical SGPR and the
    /// dispatch snapshot supplies its four descriptor words.
    pub fn inlineBufferDescriptor(self: *const StageBindings, resource_sgpr: u32) Error!?resources.BufferDescriptor {
        if (resource_sgpr < self.scalar_user_data_base) return null;
        const first: usize = resource_sgpr - self.scalar_user_data_base;
        if (first + 4 > self.user_data_count) return null;
        return try resources.decodeBufferDescriptor(self.user_data[first..][0..4]);
    }

    pub fn resolve(
        self: *const StageBindings,
        reader: MemoryReader,
        kind: ResourceKind,
        slot: u16,
    ) Error!?Binding {
        const metadata = self.metadata orelse return null;
        const srt_address = self.srt_address orelse return null;
        const mapping = try metadata.resourceMapping(reader, kind, slot) orelse return null;
        const word_count = kind.descriptorWordCount();
        if (@as(u32, mapping.offset_words) + word_count > metadata.shader_resource_table_size_words) {
            return Error.ResourceOutsideSrt;
        }

        const descriptor_address = try addAddress(srt_address, @as(u64, mapping.offset_words) * 4);
        var words: [8]u32 = undefined;
        try reader.readWords(descriptor_address, words[0..word_count]);
        const descriptor: Descriptor = switch (kind) {
            .read_only_texture => .{ .read_only_texture = try resources.decodeImageDescriptor(words[0..8]) },
            .read_write_texture => .{ .read_write_texture = try resources.decodeImageDescriptor(words[0..8]) },
            .sampler => .{ .sampler = try resources.decodeSamplerDescriptor(words[0..4]) },
            .constant_buffer => .{ .constant_buffer = try resources.decodeBufferDescriptor(words[0..4]) },
        };
        return .{
            .mapping = mapping,
            .descriptor_address = descriptor_address,
            .descriptor = descriptor,
        };
    }

    pub fn iterator(self: *const StageBindings, reader: MemoryReader, kind: ResourceKind) ResourceIterator {
        return .{ .bindings = self, .reader = reader, .kind = kind };
    }
};

/// NGG carries an export program in the ES program registers while exposing
/// its hardware user SGPRs through the GS bank. RSRC2 is authoritative even
/// when no USER_DATA register was written, followed by the observable banks.
fn selectUserDataStage(state: *const gpu_state.State, program_stage: resources.ShaderStage) resources.ShaderStage {
    if (program_stage != .export_shader) return program_stage;
    for ([_]resources.ShaderStage{ .geometry, .export_shader, .vertex }) |candidate| {
        if (state.readRegister(.shader, candidate.userDataBase() - 1) != null) return candidate;
    }
    for ([_]resources.ShaderStage{ .geometry, .export_shader, .vertex }) |candidate| {
        if (state.readRegister(.shader, candidate.userDataBase()) != null) return candidate;
    }
    return .export_shader;
}

pub const ResourceIterator = struct {
    bindings: *const StageBindings,
    reader: MemoryReader,
    kind: ResourceKind,
    next_slot: u16 = 0,

    pub fn next(self: *ResourceIterator) Error!?Binding {
        const metadata = self.bindings.metadata orelse return null;
        const count = metadata.resource_counts[@intFromEnum(self.kind)];
        while (self.next_slot < count) {
            const slot = self.next_slot;
            self.next_slot += 1;
            if (try self.bindings.resolve(self.reader, self.kind, slot)) |binding| return binding;
        }
        return null;
    }
};

pub const VertexSemantic = packed struct(u32) {
    semantic: u8,
    hardware_mapping: u8,
    size_in_elements: u4,
    is_f16: u2,
    is_flat_shaded: bool,
    is_linear: bool,
    is_custom: bool,
    static_vertex_buffer_index: bool,
    static_attribute: bool,
    reserved: bool,
    default_value: u2,
    default_value_high: u2,
};

pub const VertexAttribute = struct {
    location: u8,
    semantic: VertexSemantic,
    buffer_index: u8,
    attribute_format: u16,
    offset_bytes: u16,
    per_instance: bool,
    descriptor_address: u64,
    buffer: resources.BufferDescriptor,

    pub fn vertexAddress(self: VertexAttribute) Error!u64 {
        return addAddress(self.buffer.address, self.offset_bytes);
    }
};

/// Allocation-free, fully checked view of the AGC vertex semantics, attribute
/// table and V# table captured at one draw boundary.
pub const VertexBindings = struct {
    attribute_table_address: u64,
    buffer_table_address: u64,
    attributes: [maximum_vertex_semantics]VertexAttribute = undefined,
    attribute_count: u8 = 0,

    pub fn capture(bindings: *const StageBindings, reader: MemoryReader) Error!?VertexBindings {
        const metadata = bindings.metadata orelse return null;
        const attribute_table = try bindings.directPointer(reader, .pointer_vertex_attribute_table);
        const buffer_table = try bindings.directPointer(reader, .pointer_vertex_buffer_table);
        if (attribute_table == null and buffer_table == null) return null;
        if (attribute_table == null or buffer_table == null) return Error.IncompleteVertexTables;
        if (metadata.input_semantics_count == 0 or
            metadata.input_semantics_count > maximum_vertex_semantics or
            metadata.input_semantics_address == 0)
        {
            return Error.InvalidVertexSemanticCount;
        }

        var result = VertexBindings{
            .attribute_table_address = attribute_table.?,
            .buffer_table_address = buffer_table.?,
        };
        for (0..metadata.input_semantics_count) |location| {
            const semantic_word = try reader.readU32(try addAddress(
                metadata.input_semantics_address,
                location * 4,
            ));
            const semantic: VertexSemantic = @bitCast(semantic_word);
            if (semantic.semantic >= maximum_vertex_semantics) return Error.VertexTableIndexOutOfRange;
            const attribute_word = try reader.readU32(try addAddress(
                attribute_table.?,
                @as(u64, semantic.semantic) * 4,
            ));
            const buffer_index: u8 = @truncate(attribute_word & 0x1f);
            if (buffer_index >= maximum_vertex_semantics) return Error.VertexTableIndexOutOfRange;
            const descriptor_address = try addAddress(buffer_table.?, @as(u64, buffer_index) * 16);
            var descriptor_words: [4]u32 = undefined;
            try reader.readWords(descriptor_address, &descriptor_words);
            result.attributes[location] = .{
                .location = @intCast(location),
                .semantic = semantic,
                .buffer_index = buffer_index,
                .attribute_format = @truncate((attribute_word >> 5) & 0x1ff),
                .offset_bytes = @truncate((attribute_word >> 14) & 0xfff),
                .per_instance = attribute_word & (1 << 26) != 0,
                .descriptor_address = descriptor_address,
                .buffer = try resources.decodeBufferDescriptor(&descriptor_words),
            };
            result.attribute_count += 1;
        }
        return result;
    }

    pub fn slice(self: *const VertexBindings) []const VertexAttribute {
        return self.attributes[0..self.attribute_count];
    }
};

fn findSrtAddress(
    metadata: Metadata,
    reader: MemoryReader,
    user_data: *const [resources.maximum_user_data_words]u32,
    user_data_count: u8,
) Error!?u64 {
    if (metadata.shader_resource_table_size_words == 0) return null;
    const first = try metadata.directResourceOffset(reader, .shader_resource_table) orelse return null;
    if (@as(u32, first) + 1 >= user_data_count) return Error.UserDataOutOfRange;
    const high = user_data[first + 1];
    if (high & 0xffff_0000 != 0) return Error.AddressOverflow;
    const address = @as(u64, user_data[first]) | (@as(u64, high) << 32);
    if (address == 0) return null;
    if (address & ~address_mask != 0) return Error.AddressOverflow;
    return address;
}

fn findDirectPointer(
    metadata: Metadata,
    reader: MemoryReader,
    user_data: *const [resources.maximum_user_data_words]u32,
    user_data_count: u8,
    resource_type: DirectResourceType,
) Error!?u64 {
    const first = try metadata.directResourceOffset(reader, resource_type) orelse return null;
    if (@as(u32, first) + 1 >= user_data_count) return Error.UserDataOutOfRange;
    const high = user_data[first + 1];
    if (high & 0xffff_0000 != 0) return Error.AddressOverflow;
    const address = @as(u64, user_data[first]) | (@as(u64, high) << 32);
    if (address == 0) return null;
    if (address & ~address_mask != 0) return Error.AddressOverflow;
    return address;
}

fn addAddress(base: u64, offset: u64) Error!u64 {
    if (base > address_mask or offset > address_mask - base) return Error.AddressOverflow;
    return base + offset;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const TestMemory = struct {
    base: u64,
    bytes: []u8,

    fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
        const self: *TestMemory = @ptrCast(@alignCast(context.?));
        if (address < self.base) return false;
        const offset64 = address - self.base;
        if (offset64 > std.math.maxInt(usize)) return false;
        const offset: usize = @intCast(offset64);
        if (offset > self.bytes.len or destination.len > self.bytes.len - offset) return false;
        @memcpy(destination, self.bytes[offset .. offset + destination.len]);
        return true;
    }

    fn reader(self: *TestMemory) MemoryReader {
        return .{ .context = self, .read_fn = read };
    }

    fn writeInt(self: *TestMemory, comptime T: type, address: u64, value: T) void {
        const offset: usize = @intCast(address - self.base);
        std.mem.writeInt(T, self.bytes[offset..][0..@sizeOf(T)], value, .little);
    }
};

test "AGC metadata resolves the declared SRT register and descriptors" {
    var storage = [_]u8{0} ** 0x500;
    var memory = TestMemory{ .base = 0x1000, .bytes = &storage };
    const header: u64 = 0x1000;
    const user_data: u64 = 0x1100;
    const direct: u64 = 0x1180;
    const image_offsets: u64 = 0x11a0;
    const sampler_offsets: u64 = 0x11c0;
    const buffer_offsets: u64 = 0x11e0;
    const srt: u64 = 0x1200;

    memory.writeInt(u64, header + 0x08, user_data);
    memory.writeInt(u64, user_data, direct);
    memory.writeInt(u64, user_data + 0x08, image_offsets);
    memory.writeInt(u64, user_data + 0x10, 0);
    memory.writeInt(u64, user_data + 0x18, sampler_offsets);
    memory.writeInt(u64, user_data + 0x20, buffer_offsets);
    memory.writeInt(u16, user_data + 0x28, 4);
    memory.writeInt(u16, user_data + 0x2a, 24);
    memory.writeInt(u16, user_data + 0x2c, 2);
    memory.writeInt(u16, user_data + 0x2e, 2);
    memory.writeInt(u16, user_data + 0x30, 0);
    memory.writeInt(u16, user_data + 0x32, 1);
    memory.writeInt(u16, user_data + 0x34, 1);
    memory.writeInt(u16, direct, illegal_direct_offset);
    memory.writeInt(u16, direct + 2, 3);
    memory.writeInt(u16, image_offsets, 0x8000);
    memory.writeInt(u16, image_offsets + 2, illegal_resource_offset);
    memory.writeInt(u16, sampler_offsets, 8);
    memory.writeInt(u16, buffer_offsets, 12);

    const image_words = [_]u32{
        0x0012_3456,
        (56 << 20) | (3 << 30),
        63 | (63 << 14),
        0x0fac | (0x1b << 20) | (9 << 28),
        0,
        0,
        0,
        0,
    };
    for (image_words, 0..) |word, index| memory.writeInt(u32, srt + index * 4, word);
    const sampler_words = [_]u32{ 0, 0x0fff_f000, 0, 0 };
    for (sampler_words, 0..) |word, index| memory.writeInt(u32, srt + 32 + index * 4, word);
    const buffer_words = [_]u32{ 0x1234_5000, 16 << 16, 4, 56 << 12 };
    for (buffer_words, 0..) |word, index| memory.writeInt(u32, srt + 48 + index * 4, word);

    var state = gpu_state.State{};
    try state.writeRegister(.shader, resources.ShaderStage.compute.programRegisterBase(), 0x40);
    try state.writeRegister(.shader, resources.ShaderStage.compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 5 << 1);
    try state.writeRegister(.shader, resources.ShaderStage.compute.userDataBase() + 3, @truncate(srt));
    try state.writeRegister(.shader, resources.ShaderStage.compute.userDataBase() + 4, @truncate(srt >> 32));

    const bindings = try StageBindings.capture(&state, .compute, header, memory.reader());
    try testing.expectEqual(@as(?u64, srt), bindings.srt_address);
    try testing.expectEqual(@as(u16, 24), bindings.metadata.?.shader_resource_table_size_words);
    const image = (try bindings.resolve(memory.reader(), .read_only_texture, 0)).?;
    try testing.expect(image.mapping.size_flag);
    try testing.expectEqual(@as(u32, 256), image.descriptor.read_only_texture.width);
    try testing.expect((try bindings.resolve(memory.reader(), .read_only_texture, 1)) == null);
    const buffer = (try bindings.resolve(memory.reader(), .constant_buffer, 0)).?;
    try testing.expectEqual(@as(u64, 0x1234_5000), buffer.descriptor.constant_buffer.address);
    try testing.expectEqual(@as(u64, 64), buffer.descriptor.constant_buffer.size_bytes);
}

test "compute bindings decode an inline V# by physical SGPR" {
    var storage = [_]u8{0} ** 0x100;
    var memory = TestMemory{ .base = 0x3000, .bytes = &storage };
    var state = gpu_state.State{};
    try state.writeRegister(.shader, resources.ShaderStage.compute.programRegisterBase(), 0x40);
    try state.writeRegister(.shader, resources.ShaderStage.compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    const words = [_]u32{ 0x1234_5000, 16 << 16, 4, 0 };
    for (words, 0..) |word, index| {
        try state.writeRegister(.shader, resources.ShaderStage.compute.userDataBase() + 4 + @as(u32, @intCast(index)), word);
    }

    const bindings = try StageBindings.capture(&state, .compute, null, memory.reader());
    const descriptor = (try bindings.inlineBufferDescriptor(4)).?;
    try testing.expectEqual(@as(u64, 0x1234_5000), descriptor.address);
    try testing.expectEqual(@as(u64, 64), descriptor.size_bytes);
    try testing.expect((try bindings.inlineBufferDescriptor(8)) == null);
}

test "resource mappings cannot read beyond the declared SRT" {
    var storage = [_]u8{0} ** 0x300;
    var memory = TestMemory{ .base = 0x2000, .bytes = &storage };
    const header: u64 = 0x2000;
    const user_data: u64 = 0x2080;
    const direct: u64 = 0x20c0;
    const offsets: u64 = 0x20e0;
    memory.writeInt(u64, header + 0x08, user_data);
    memory.writeInt(u64, user_data, direct);
    memory.writeInt(u64, user_data + 0x08, offsets);
    memory.writeInt(u64, user_data + 0x10, 0);
    memory.writeInt(u64, user_data + 0x18, 0);
    memory.writeInt(u64, user_data + 0x20, 0);
    memory.writeInt(u16, user_data + 0x2a, 8);
    memory.writeInt(u16, user_data + 0x2c, 2);
    memory.writeInt(u16, user_data + 0x2e, 1);
    memory.writeInt(u16, user_data + 0x30, 0);
    memory.writeInt(u16, user_data + 0x32, 0);
    memory.writeInt(u16, user_data + 0x34, 0);
    memory.writeInt(u16, direct, illegal_direct_offset);
    memory.writeInt(u16, direct + 2, 0);
    memory.writeInt(u16, offsets, 4);

    var state = gpu_state.State{};
    try state.writeRegister(.shader, resources.ShaderStage.pixel.programRegisterBase(), 1);
    try state.writeRegister(.shader, resources.ShaderStage.pixel.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x00b, 2 << 1);
    try state.writeRegister(.shader, resources.ShaderStage.pixel.userDataBase(), 0x2100);
    try state.writeRegister(.shader, resources.ShaderStage.pixel.userDataBase() + 1, 0);
    const bindings = try StageBindings.capture(&state, .pixel, header, memory.reader());
    try testing.expectError(
        Error.ResourceOutsideSrt,
        bindings.resolve(memory.reader(), .read_only_texture, 0),
    );
}

test "user SGPR count includes the GFX10 graphics MSB" {
    var state = gpu_state.State{};
    try state.writeRegister(.shader, 0x00b, (3 << 1) | (1 << 27));
    try testing.expectEqual(@as(u8, 35), resources.ShaderStage.pixel.activeUserDataCount(&state));
}

test "NGG export programs select the GS user-data bank" {
    var storage = [_]u8{0} ** 0x100;
    var memory = TestMemory{ .base = 0x3000, .bytes = &storage };
    var state = gpu_state.State{};
    try state.writeRegister(.shader, resources.ShaderStage.export_shader.programRegisterBase(), 0x40);
    try state.writeRegister(.shader, resources.ShaderStage.export_shader.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, resources.ShaderStage.geometry.userDataBase() - 1, 4 << 1);
    try state.writeRegister(.shader, resources.ShaderStage.geometry.userDataBase(), 0x1122_3344);
    const bindings = try StageBindings.capture(&state, .export_shader, null, memory.reader());
    try testing.expectEqual(resources.ShaderStage.geometry, bindings.user_data_stage);
    try testing.expectEqual(@as(u8, 4), bindings.user_data_count);
    try testing.expectEqual(@as(u8, 8), bindings.scalar_user_data_base);
    try testing.expectEqual(@as(u32, 0x1122_3344), bindings.user_data[0]);
}

test "AGC direct vertex fetch and extended-user-data tables are snapshotted" {
    var storage = [_]u8{0} ** 0x900;
    var memory = TestMemory{ .base = 0x4000, .bytes = &storage };
    const header: u64 = 0x4000;
    const user_metadata: u64 = 0x4100;
    const direct: u64 = 0x4180;
    const semantics: u64 = 0x41c0;
    const attributes: u64 = 0x4200;
    const buffers: u64 = 0x4300;
    const extended: u64 = 0x4400;
    const fetch: u64 = 0x4500;
    const program: u64 = 0x4600;
    const vertex_data: u64 = 0x1234_5678_9000;

    memory.writeInt(u64, header + 0x08, user_metadata);
    memory.writeInt(u64, header + 0x30, semantics);
    memory.writeInt(u32, header + 0x50, 1);
    memory.writeInt(u64, user_metadata, direct);
    for (0..4) |index| memory.writeInt(u64, user_metadata + 0x08 + index * 8, 0);
    memory.writeInt(u16, user_metadata + 0x28, 2);
    memory.writeInt(u16, user_metadata + 0x2a, 0);
    memory.writeInt(u16, user_metadata + 0x2c, 11);
    for (0..4) |index| memory.writeInt(u16, user_metadata + 0x2e + index * 2, 0);
    for (0..11) |index| memory.writeInt(u16, direct + index * 2, illegal_direct_offset);
    memory.writeInt(u16, direct + @as(u16, @intFromEnum(DirectResourceType.sub_pointer_fetch_shader)) * 2, 2);
    memory.writeInt(u16, direct + @as(u16, @intFromEnum(DirectResourceType.pointer_extended_user_data)) * 2, 4);
    memory.writeInt(u16, direct + @as(u16, @intFromEnum(DirectResourceType.pointer_vertex_buffer_table)) * 2, 6);
    memory.writeInt(u16, direct + @as(u16, @intFromEnum(DirectResourceType.pointer_vertex_attribute_table)) * 2, 8);

    // semantic=1, hardware_mapping=4, two elements, f16=1, linear=1.
    memory.writeInt(u32, semantics, 1 | (4 << 8) | (2 << 16) | (1 << 20) | (1 << 23));
    // attrib[1]: buffer=3, format=29, offset=8, instance fetch.
    memory.writeInt(u32, attributes + 4, 3 | (29 << 5) | (8 << 14) | (1 << 26));
    const descriptor = buffers + 3 * 16;
    memory.writeInt(u32, descriptor, @truncate(vertex_data));
    memory.writeInt(u32, descriptor + 4, @as(u32, @truncate(vertex_data >> 32)) | (16 << 16));
    memory.writeInt(u32, descriptor + 8, 10);
    memory.writeInt(u32, descriptor + 12, 0);
    memory.writeInt(u32, extended, 0xfeed_beef);
    memory.writeInt(u32, extended + 4, 0xcafe_babe);

    var state = gpu_state.State{};
    try state.writeRegister(.shader, resources.ShaderStage.vertex.programRegisterBase(), @truncate(program >> 8));
    try state.writeRegister(.shader, resources.ShaderStage.vertex.programRegisterBase() + 1, @truncate(program >> 40));
    try state.writeRegister(.shader, resources.ShaderStage.vertex.userDataBase() - 1, 10 << 1);
    const pointers = [_]u64{ fetch, extended, buffers, attributes };
    const offsets = [_]u8{ 2, 4, 6, 8 };
    for (pointers, offsets) |pointer, offset| {
        try state.writeRegister(.shader, resources.ShaderStage.vertex.userDataBase() + offset, @truncate(pointer));
        try state.writeRegister(.shader, resources.ShaderStage.vertex.userDataBase() + offset + 1, @truncate(pointer >> 32));
    }

    const bindings = try StageBindings.capture(&state, .vertex, header, memory.reader());
    try testing.expectEqual(@as(?u64, fetch), bindings.direct_pointers.fetch_shader);
    try testing.expectEqual(@as(?u64, extended), bindings.direct_pointers.extended_user_data);
    try testing.expectEqual(@as(?u32, 0xfeed_beef), try bindings.extendedUserDataWord(memory.reader(), 0));
    try testing.expect((try bindings.extendedUserDataWord(memory.reader(), 2)) == null);

    const vertex = (try VertexBindings.capture(&bindings, memory.reader())).?;
    try testing.expectEqual(@as(u8, 1), vertex.attribute_count);
    const attribute = vertex.slice()[0];
    try testing.expectEqual(@as(u8, 1), attribute.semantic.semantic);
    try testing.expectEqual(@as(u8, 4), attribute.semantic.hardware_mapping);
    try testing.expectEqual(@as(u16, 29), attribute.attribute_format);
    try testing.expectEqual(@as(u16, 8), attribute.offset_bytes);
    try testing.expect(attribute.per_instance);
    try testing.expectEqual(vertex_data, attribute.buffer.address);
    try testing.expectEqual(@as(u16, 16), attribute.buffer.stride);
    try testing.expectEqual(vertex_data + 8, try attribute.vertexAddress());

    // A partially supplied embedded layout must fail as one unit.
    memory.writeInt(u16, direct + @as(u16, @intFromEnum(DirectResourceType.pointer_vertex_attribute_table)) * 2, illegal_direct_offset);
    try testing.expectError(
        Error.IncompleteVertexTables,
        VertexBindings.capture(&bindings, memory.reader()),
    );
}
