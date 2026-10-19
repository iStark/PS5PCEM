// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Read-only graphics snapshots. Every memory instruction must have a proven
//! descriptor/address; the shared translator's missing-resource fallbacks are
//! never used. VS and PS share one native descriptor namespace per draw.
const std = @import("std");
const gpu = @import("gpu");
const rdna2 = @import("rdna2");
const native = @import("root.zig");
const staging = @import("staging.zig");

pub const Stage = struct {
    buffers: std.ArrayList(rdna2.spirv.StorageBufferBinding) = .empty,
    pointers: std.ArrayList(rdna2.spirv.ScalarMemoryBinding) = .empty,
    images: std.ArrayList(rdna2.spirv.SampledImageBinding) = .empty,
    pub fn deinit(self: *Stage, allocator: std.mem.Allocator) void {
        self.buffers.deinit(allocator);
        self.pointers.deinit(allocator);
        self.images.deinit(allocator);
    }
};

pub const DrawResources = struct {
    allocator: std.mem.Allocator,
    reader: gpu.ShaderMemoryReader,
    pool: ?*staging.Pool = null,
    leases: [96]staging.Lease = undefined,
    lease_count: usize = 0,
    buffers: std.ArrayList(native.Buffer) = .empty,
    images: std.ArrayList(native.SampledImage) = .empty,
    total: usize = 0,

    pub fn deinit(self: *DrawResources) void {
        for (self.leases[0..self.lease_count]) |*lease| lease.deinit();
        self.buffers.deinit(self.allocator);
        self.images.deinit(self.allocator);
    }

    fn snapshot(self: *DrawResources, address: u64, size: usize, pointer_header: bool) !u32 {
        const header: usize = if (pointer_header) 8 else 0;
        const bytes_needed = std.mem.alignForward(usize, @max(4, try std.math.add(usize, size, header)), 4);
        if (self.buffers.items.len >= 64 or bytes_needed > 256 * 1024 * 1024 or
            self.total + bytes_needed > 256 * 1024 * 1024) return error.GraphicsSnapshotBudgetExceeded;
        _ = try std.math.add(u64, address, size);
        var lease = try staging.Lease.alloc(self.allocator, self.pool, bytes_needed);
        errdefer lease.deinit();
        const bytes = lease.bytes;
        // Guest reads and the optional pointer header overwrite their ranges.
        // Only padding (including the empty-buffer default) needs zeroing.
        @memset(bytes[header + size ..], 0);
        if (pointer_header) std.mem.writeInt(u64, bytes[0..8], address, .little);
        if (size != 0) try self.reader.read(address, bytes[header..][0..size]);
        const slot: u32 = @intCast(self.buffers.items.len);
        try self.buffers.append(self.allocator, native.Buffer.fromSlice(bytes));
        self.leases[self.lease_count] = lease;
        self.lease_count += 1;
        self.total += bytes_needed;
        return slot;
    }

    pub fn capture(self: *DrawResources, bindings: *const gpu.ShaderBindings, analysis: *const gpu.ShaderAnalysis) !Stage {
        var stage = Stage{};
        errdefer stage.deinit(self.allocator);
        const unknown: gpu.scalar_provenance.ScalarRegisters = @splat(.{});
        for (analysis.program.instructions.items) |inst| {
            var resolver = gpu.scalar_resources.Resolver{
                .bindings = bindings,
                .reader = self.reader,
                .instructions = analysis.program.instructions.items,
                .graph = &analysis.graph,
                .snapshot = &unknown,
            };
            switch (inst.family) {
                .smem => switch (inst.opcode) {
                    .s_load_dword, .s_load_dwordx2, .s_load_dwordx4, .s_load_dwordx8, .s_load_dwordx16 => {
                        const reg = gpu.scalar_provenance.scalarRegisterIndex(inst.src0) orelse return error.InvalidScalarPointer;
                        var base: [2]u32 = undefined;
                        if (!try resolver.words(@intCast(reg), inst.pc, &base) or base[1] > 0xffff or inst.memory_offset < 0)
                            return error.DynamicScalarPointerNotImplemented;
                        const offset = try scalarOffset(&resolver, inst.src1, inst.pc);
                        var address = try std.math.add(u64, @as(u64, base[0]) | (@as(u64, base[1]) << 32), offset);
                        address = (try std.math.add(u64, address, @intCast(inst.memory_offset))) & ~@as(u64, 3);
                        const size = @as(usize, inst.data_words) * 4;
                        const end = try std.math.add(u64, address, size);
                        if (address == 0 or size == 0 or size > 64 or end > 0x1000000000000 or address >> 32 != (end - 1) >> 32)
                            return error.UnsupportedScalarPointerRange;
                        const slot = try self.snapshot(address, size, true);
                        try stage.pointers.append(self.allocator, .{ .resource_sgpr = @intCast(reg), .instruction_pc = inst.pc, .descriptor_index = slot });
                    },
                    .s_buffer_load_dword, .s_buffer_load_dwordx2, .s_buffer_load_dwordx4, .s_buffer_load_dwordx8, .s_buffer_load_dwordx16 => try self.captureBuffer(&stage, &resolver, inst, true),
                    else => return error.GraphicsScalarMemoryOperationNotImplemented,
                },
                .mubuf, .mtbuf => {
                    const name = @tagName(inst.opcode);
                    if (!std.mem.startsWith(u8, name, "buffer_load_") and !std.mem.startsWith(u8, name, "tbuffer_load_"))
                        return error.GraphicsStorageWritesNotImplemented;
                    try self.captureBuffer(&stage, &resolver, inst, false);
                },
                .mimg => try self.captureImage(&stage, &resolver, inst),
                .flat => return error.GraphicsFlatMemoryNotImplemented,
                .ds => return error.GraphicsLdsNotImplemented,
                else => {},
            }
        }
        return stage;
    }

    fn captureBuffer(self: *DrawResources, stage: *Stage, resolver: *gpu.scalar_resources.Resolver, inst: gpu.ShaderInstruction, scalar: bool) !void {
        const reg = gpu.scalar_provenance.scalarRegisterIndex(if (scalar) inst.src0 else inst.src1) orelse return error.InvalidBufferDescriptor;
        var words: [4]u32 = @splat(0);
        if (!try resolver.words(@intCast(reg), inst.pc, words[0..if (scalar) @as(usize, 3) else 4])) {
            std.debug.print("[d3d12 resources] unresolved buffer program=0x{x} pc=0x{x} op={s} s{d}\n", .{ resolver.bindings.program_address, inst.pc, @tagName(inst.opcode), reg });
            return error.DynamicGraphicsBufferNotImplemented;
        }
        const descriptor = if (scalar) try gpu.resources.decodeScalarBufferDescriptor(&words) else try gpu.resources.decodeBufferDescriptor(&words);
        if (descriptor.out_of_bounds_select == 2 or descriptor.add_thread_id or
            (descriptor.address == 0 and descriptor.size_bytes != 0) or descriptor.size_bytes > 256 * 1024 * 1024)
            return error.UnsupportedGraphicsBufferDescriptor;
        const slot = try self.snapshot(descriptor.address, @intCast(descriptor.size_bytes), false);
        try stage.buffers.append(self.allocator, .{
            .resource_sgpr = @intCast(reg),
            .instruction_pc = inst.pc,
            .descriptor_index = slot,
            .stride = descriptor.stride,
            .swizzled = descriptor.swizzle_enabled,
            .index_stride = descriptor.index_stride,
            .unified_format = descriptor.unified_format,
            .dst_select = descriptor.dst_select,
            .extent_bytes = @intCast(descriptor.size_bytes),
        });
    }

    fn captureImage(self: *DrawResources, stage: *Stage, resolver: *gpu.scalar_resources.Resolver, inst: gpu.ShaderInstruction) !void {
        if (inst.opcode != .image_sample or inst.image_dimension != .dim_2d or inst.image_sample_flags.compare or inst.image_r128)
            return error.GraphicsImageOperationNotImplemented;
        var words: [8]u32 = undefined;
        var sampler_words: [4]u32 = undefined;
        if (!try resolver.words(inst.src1.reg, inst.pc, &words) or !try resolver.words(inst.src2.reg, inst.pc, &sampler_words))
            return error.DynamicGraphicsImageNotImplemented;
        const descriptor = try gpu.resources.decodeImageDescriptor(&words);
        const sampler = try gpu.resources.decodeSamplerDescriptor(&sampler_words);
        errdefer std.debug.print("[d3d12 sampler] program=0x{x} pc=0x{x} words={x},{x},{x},{x} descriptor={any}\n", .{
            resolver.bindings.program_address, inst.pc, sampler_words[0], sampler_words[1], sampler_words[2], sampler_words[3], sampler,
        });
        const format: u32 = switch (descriptor.unified_format) {
            1 => 61, // R8_UNORM
            14 => 49, // R8G8_UNORM
            56 => 28,
            136 => 115, // B4G4R4A4_UNORM; component mapping restores guest XYZW.
            169, 170 => 71,
            171, 172 => 74,
            173, 174 => 77,
            else => 0,
        };
        // A 2D instruction can view the sole layer of an array descriptor.
        // Multi-layer descriptors and array-indexed instructions remain rejected.
        const single_layer = descriptor.depth_or_layers == 1 and descriptor.base_array == 0;
        const view_2d = descriptor.image_type == .color_2d or (descriptor.image_type == .color_2d_array and single_layer);
        const compressed = format == 71 or format == 74 or format == 77;
        if (!view_2d or !single_layer or format == 0 or descriptor.viewBaseLevel() != 0 or
            descriptor.viewMipLevels() != 1 or descriptor.max_mip != 0 or descriptor.base_array != 0 or
            descriptor.min_lod != 0 or (compressed and descriptor.bc_swizzle != 0) or
            descriptor.dccMetadataAddress() != null or gpu.MetadataSurface.fromImage(descriptor).hasAny())
        {
            std.debug.print("[d3d12 image] program=0x{x} pc=0x{x} descriptor={any}\n", .{ resolver.bindings.program_address, inst.pc, descriptor });
            return error.GraphicsTextureFormatOrMipNotImplemented;
        }
        const expected_bytes = try native.sampledImageSize(descriptor.width, descriptor.height, format);
        // Narrow and packed formats have no sRGB DXGI variants; adding one
        // to their enum does not select a gamma-decoding view.
        if (sampler.force_srgb and (format == 61 or format == 49 or format == 115)) return error.GraphicsSamplerModeNotImplemented;
        if (sampler.trunc_coordinates or sampler.filter_mode != 0 or
            sampler.maximum_anisotropy != 0 or sampler.minification_filter > 1 or sampler.magnification_filter > 1 or
            sampler.mip_filter > 2 or sampler.border_color_type == 3)
            return error.GraphicsSamplerModeNotImplemented;
        const unnormalized = sampler.unnormalized_coordinates;
        if (unnormalized and (resolver.bindings.stage != .pixel or @as(u16, @bitCast(inst.image_sample_flags)) != 0 or
            sampler.mip_filter != 0 or sampler.minimum_lod != 0 or sampler.lod_bias != 0 or
            sampler.minification_filter != sampler.magnification_filter)) return error.GraphicsSamplerModeNotImplemented;
        const layout = try gpu.SurfaceLayout.fromImage(descriptor);
        if (layout.staging_bytes != expected_bytes) return error.GraphicsImageFootprintMismatch;
        if (self.images.items.len >= 32 or layout.required_source_bytes > 256 * 1024 * 1024 or
            self.total + layout.staging_bytes > 256 * 1024 * 1024) return error.GraphicsSnapshotBudgetExceeded;
        _ = try layout.sourceRange(descriptor.address);
        var backing_lease = try staging.Lease.alloc(self.allocator, self.pool, @intCast(layout.required_source_bytes));
        defer backing_lease.deinit();
        const backing = backing_lease.bytes;
        try self.reader.read(descriptor.address, backing);
        var pixel_lease = try staging.Lease.alloc(self.allocator, self.pool, @intCast(layout.staging_bytes));
        const pixels = pixel_lease.bytes;
        var owns_pixels = true;
        errdefer if (owns_pixels) pixel_lease.deinit();
        try layout.detile(backing, pixels);
        var components: u32 = 1 << 12;
        for (descriptor.dst_select, 0..) |select, i| {
            const mapped: u32 = switch (select) {
                0 => 4,
                1 => 5,
                // Guest 4_4_4_4 assigns X/Y/Z/W from low to high bits.
                // DXGI B4G4R4A4 exposes those bits as B/G/R/A. Keep the
                // original packed bytes and compensate in the SRV mapping.
                4...7 => if (format == 115) ([_]u32{ 2, 1, 0, 3 })[select - 4] else select - 4,
                else => return error.InvalidTextureComponent,
            };
            components |= mapped << @intCast(i * 3);
        }
        const slot: u32 = @intCast(self.images.items.len);
        try self.images.append(self.allocator, .{
            .pixels = pixels.ptr,
            .size = pixels.len,
            .width = descriptor.width,
            .height = descriptor.height,
            .format = format,
            .srgb = @intFromBool(sampler.force_srgb or (compressed and descriptor.unified_format % 2 == 0)),
            .components = components,
            .filter = (@as(u32, sampler.minification_filter) << 4) | (@as(u32, sampler.magnification_filter) << 2) | @intFromBool(sampler.mip_filter == 2),
            .address_u = if (unnormalized) try unnormalizedAddressMode(sampler.clamp_x) else try addressMode(sampler.clamp_x),
            .address_v = if (unnormalized) try unnormalizedAddressMode(sampler.clamp_y) else try addressMode(sampler.clamp_y),
            .address_w = if (unnormalized) 3 else try addressMode(sampler.clamp_z),
            .min_lod = if (unnormalized) 0 else sampler.minimum_lod,
            .max_lod = if (unnormalized) 0 else sampler.maximum_lod,
            .lod_bias = if (unnormalized) 0 else sampler.lod_bias,
            .border = switch (sampler.border_color_type) {
                0 => .{ 0, 0, 0, 0 },
                1 => .{ 0, 0, 0, 1 },
                2 => .{ 1, 1, 1, 1 },
                else => unreachable,
            },
        });
        owns_pixels = false;
        self.leases[self.lease_count] = pixel_lease;
        self.lease_count += 1;
        self.total += pixels.len;
        try stage.images.append(self.allocator, .{
            .resource_sgpr = inst.src1.reg,
            .sampler_sgpr = inst.src2.reg,
            .descriptor_index = slot,
            .instruction_pc = inst.pc,
            .minimum_lod = sampler.minimum_lod,
            .maximum_lod = sampler.maximum_lod,
            .texel_coordinates_extent = if (unnormalized) .{ descriptor.width, descriptor.height } else null,
        });
    }
};

fn scalarOffset(resolver: *gpu.scalar_resources.Resolver, operand: gpu.ShaderOperand, pc: u32) !u32 {
    if (gpu.scalar_provenance.scalarRegisterIndex(operand)) |reg| {
        var value: [1]u32 = undefined;
        if (!try resolver.words(@intCast(reg), pc, &value)) return error.DynamicScalarOffsetNotImplemented;
        return value[0];
    }
    return switch (operand.kind) {
        .null => 0,
        .integer_inline_constant, .literal_constant => operand.value,
        else => error.InvalidScalarOffset,
    };
}

fn addressMode(guest: u8) !u32 {
    return switch (guest) {
        0 => 1,
        1 => 2,
        2 => 3,
        4 => 4,
        else => error.GraphicsSamplerAddressModeNotImplemented,
    };
}

fn unnormalizedAddressMode(guest: u8) !u32 {
    // With FORCE_UNNORMALIZED, wrap uses the same edge clamp as mode 2.
    // Mode 6 preserves the explicit border. Mirror/half-border need their
    // own coordinate rules and must not silently become ordinary wrapping.
    return switch (guest) {
        0, 2 => 3,
        6 => 4,
        else => error.GraphicsSamplerAddressModeNotImplemented,
    };
}

test "pooled graphics snapshots initialize headers, padding and changed guest contents" {
    const Memory = struct {
        value: u8 = 0,
        fail: bool = false,
        fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.fail) return false;
            for (bytes, 0..) |*byte, i| byte.* = @truncate(address + i + self.value);
            return true;
        }
    };
    var pool = staging.Pool{ .allocator = std.testing.allocator };
    defer pool.deinit();
    var memory = Memory{};
    for (0..3) |iteration| {
        memory.value = @intCast(iteration * 17);
        var captured = DrawResources{ .allocator = std.testing.allocator, .pool = &pool, .reader = .{ .context = &memory, .read_fn = Memory.read } };
        defer captured.deinit();
        for ([_]bool{ false, true }) |header| for ([_]usize{ 0, 1, 3, 4, 17, 257 }) |size| {
            const slot = try captured.snapshot(0x1234, size, header);
            const buffer = captured.buffers.items[slot];
            const bytes = buffer.bytes[0..buffer.size];
            const offset: usize = if (header) 8 else 0;
            if (header) try std.testing.expectEqual(@as(u64, 0x1234), std.mem.readInt(u64, bytes[0..8], .little));
            for (bytes[offset..][0..size], 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(0x1234 + i + memory.value)), byte);
            try std.testing.expect(std.mem.allEqual(u8, bytes[offset + size ..], 0));
        };
        const count = captured.lease_count;
        memory.fail = true;
        try std.testing.expectError(error.MemoryReadFailed, captured.snapshot(0x1234, 8, true));
        try std.testing.expectEqual(count, captured.lease_count);
        memory.fail = false;
    }
    for (pool.entries) |entry| try std.testing.expect(!entry.busy);
    try std.testing.expect(pool.hits > 0);
}
