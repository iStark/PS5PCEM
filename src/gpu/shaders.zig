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
};

/// Checked guest-memory access supplied by a capture, the live HLE or a future
/// renderer. No shader path dereferences a guest pointer directly.
pub const MemoryReader = struct {
    context: ?*anyopaque,
    read_fn: *const fn (?*anyopaque, u64, []u8) bool,

    pub fn read(self: MemoryReader, address: u64, bytes: []u8) Error!void {
        if (!self.read_fn(self.context, address, bytes)) return Error.MemoryReadFailed;
    }

    fn readU16(self: MemoryReader, address: u64) Error!u16 {
        var bytes: [2]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u16, &bytes, .little);
    }

    fn readU64(self: MemoryReader, address: u64) Error!u64 {
        var bytes: [8]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn readWords(self: MemoryReader, address: u64, words: []u32) Error!void {
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

        return .{
            .header_address = header_address,
            .user_data_address = user_data_address,
            .direct_offsets_address = direct_offsets_address,
            .resource_offsets_addresses = resource_offsets_addresses,
            .extended_user_data_size_words = extended_size,
            .shader_resource_table_size_words = srt_size,
            .direct_resource_count = direct_count,
            .resource_counts = resource_counts,
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

/// Immutable binding inputs captured exactly when a draw or dispatch crosses
/// the DCB backend interface.
pub const StageBindings = struct {
    stage: resources.ShaderStage,
    user_data_stage: resources.ShaderStage,
    program_address: u64,
    user_data_count: u8,
    user_data: [resources.maximum_user_data_words]u32,
    metadata: ?Metadata,
    srt_address: ?u64,

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
        return .{
            .stage = stage,
            .user_data_stage = user_data_stage,
            .program_address = program_address,
            .user_data_count = user_data_count,
            .user_data = user_data,
            .metadata = metadata,
            .srt_address = srt_address,
        };
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
    try testing.expectEqual(@as(u32, 0x1122_3344), bindings.user_data[0]);
}
