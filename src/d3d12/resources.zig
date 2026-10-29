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
const surface_cache = @import("surface_cache.zig");
const texture_cache = @import("texture_cache.zig");
const surfaces = @import("surfaces.zig");

/// Count immutable image storage once per batch. Sampler/view differences
/// still occupy independent descriptors, but do not duplicate the CPU pixels.
pub const ImageBudget = struct {
    images: [native.max_draw_batch * 32]native.SampledImage = undefined,
    count: usize = 0,

    fn contains(images: []const native.SampledImage, image: native.SampledImage) bool {
        for (images) |previous| {
            if (previous.pixels == image.pixels and previous.size == image.size) return true;
        }
        return false;
    }
    pub fn additional(self: *const ImageBudget, total: usize, images: []const native.SampledImage) usize {
        var bytes = total;
        for (images, 0..) |image, i| {
            // A cache-retained snapshot is pinned by the texture cache anyway;
            // holding it for the group adds no CPU memory and no native upload.
            if (image.content_id != 0 or contains(self.images[0..self.count], image) or contains(images[0..i], image))
                bytes -= image.size;
        }
        return bytes;
    }
    pub fn append(self: *ImageBudget, images: []const native.SampledImage) void {
        for (images) |image| {
            if (contains(self.images[0..self.count], image)) continue;
            std.debug.assert(self.count < self.images.len);
            self.images[self.count] = image;
            self.count += 1;
        }
    }
};

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

test "batch budget counts pinned image storage once, not its views or equal contents" {
    var first: [16]u8 = @splat(1);
    var second = first;
    const images = [_]native.SampledImage{
        .{ .pixels = &first, .size = first.len, .width = 2, .height = 2 },
        .{ .pixels = &first, .size = first.len, .width = 2, .height = 2, .filter = 0x15 },
        .{ .pixels = &second, .size = second.len, .width = 2, .height = 2 },
    };
    var budget = ImageBudget{};
    try std.testing.expectEqual(@as(usize, 39), budget.additional(55, &images));
    budget.append(&images);
    try std.testing.expectEqual(@as(usize, 2), budget.count);
    try std.testing.expectEqual(@as(usize, 7), budget.additional(55, &images));
    budget.append(&images);
    try std.testing.expectEqual(@as(usize, 2), budget.count);
    budget = .{};
    try std.testing.expectEqual(@as(usize, 39), budget.additional(55, &images));
}

pub const DrawResources = struct {
    allocator: std.mem.Allocator,
    reader: gpu.ShaderMemoryReader,
    pool: ?*staging.Pool = null,
    cache: ?*surface_cache.Cache = null,
    textures: ?*texture_cache.Cache = null,
    tracking: texture_cache.Tracking = .{},
    texture_leases: [32]texture_cache.Lease = undefined,
    texture_lease_count: usize = 0,
    leases: [96]staging.Lease = undefined,
    lease_count: usize = 0,
    buffers: std.ArrayList(native.Buffer) = .empty,
    buffer_keys: [64]struct { address: u64, size: usize, pointer_header: bool } = undefined,
    images: std.ArrayList(native.SampledImage) = .empty,
    total: usize = 0,

    pub fn deinit(self: *DrawResources) void {
        for (self.leases[0..self.lease_count]) |*lease| lease.deinit();
        for (self.texture_leases[0..self.texture_lease_count]) |lease| lease.release();
        self.buffers.deinit(self.allocator);
        self.images.deinit(self.allocator);
    }

    fn snapshot(self: *DrawResources, address: u64, size: usize, pointer_header: bool) !u32 {
        const header: usize = if (pointer_header) 8 else 0;
        const bytes_needed = std.mem.alignForward(usize, @max(4, try std.math.add(usize, size, header)), 4);
        _ = try std.math.add(u64, address, size);
        // Several instructions often read the same complete descriptor.
        // Validate current guest bytes before sharing its immutable snapshot;
        // even a changed tail byte or a failed read must prevent reuse.
        for (self.buffers.items, self.buffer_keys[0..self.buffers.items.len], 0..) |buffer, key, i| {
            if (key.address != address or key.size != size or key.pointer_header != pointer_header) continue;
            var scratch: [16384]u8 = undefined;
            var offset: usize = 0;
            while (offset < size) {
                const count = @min(scratch.len, size - offset);
                try self.reader.read(address + offset, scratch[0..count]);
                if (!std.mem.eql(u8, scratch[0..count], buffer.bytes[header + offset ..][0..count])) break;
                offset += count;
            }
            if (offset == size) return @intCast(i);
        }
        if (self.buffers.items.len >= 64 or bytes_needed > 256 * 1024 * 1024 or
            self.total + bytes_needed > 256 * 1024 * 1024)
        {
            std.debug.print("[d3d12 resource budget] buffer address=0x{x} bytes={d} total={d} buffers={d} images={d}\n", .{ address, bytes_needed, self.total, self.buffers.items.len, self.images.items.len });
            return error.GraphicsSnapshotBudgetExceeded;
        }
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
        self.buffer_keys[slot] = .{ .address = address, .size = size, .pointer_header = pointer_header };
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
            for (resolver.instructions) |producer| {
                if (producer.pc >= inst.pc or producer.pc + 128 < inst.pc) continue;
                std.debug.print("  descriptor 0x{x}: {s} dst={s}{d} src={s}{d}/0x{x},{s}{d}/0x{x}\n", .{ producer.pc, @tagName(producer.opcode), @tagName(producer.dst.kind), producer.dst.reg, @tagName(producer.src0.kind), producer.src0.reg, producer.src0.value, @tagName(producer.src1.kind), producer.src1.reg, producer.src1.value });
            }
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
        errdefer std.debug.print("[d3d12 image operation] program=0x{x} pc=0x{x} op={s} dimension={s} flags={any} r128={any} resource=s{d} sampler=s{d}\n", .{
            resolver.bindings.program_address, inst.pc, @tagName(inst.opcode), @tagName(inst.image_dimension), inst.image_sample_flags, inst.image_r128, inst.src1.reg, inst.src2.reg,
        });
        if (inst.opcode != .image_sample or inst.image_sample_flags.compare or inst.image_r128)
            return error.GraphicsImageOperationNotImplemented;
        var words: [8]u32 = undefined;
        var sampler_words: [4]u32 = undefined;
        if (!try resolver.words(inst.src1.reg, inst.pc, &words) or !try resolver.words(inst.src2.reg, inst.pc, &sampler_words))
            return error.DynamicGraphicsImageNotImplemented;
        const descriptor = try gpu.resources.decodeImageDescriptor(&words);
        errdefer std.debug.print("[d3d12 image] program=0x{x} pc=0x{x} descriptor={any}\n", .{ resolver.bindings.program_address, inst.pc, descriptor });
        // GFX10 DIM=3 is Cube; its historical decoder name is dim_2d_array.
        const dimension: u32 = switch (inst.image_dimension) {
            .dim_2d => 0,
            .dim_2d_array => 1,
            .dim_2d_array_alt => 2,
            else => return error.GraphicsImageOperationNotImplemented,
        };
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
        if (descriptor.base_array >= descriptor.depth_or_layers) return error.GraphicsTextureFormatOrMipNotImplemented;
        const layers = descriptor.depth_or_layers - descriptor.base_array;
        const view_supported = switch (dimension) {
            0 => layers == 1 and (descriptor.image_type == .color_2d or descriptor.image_type == .color_2d_array),
            1 => descriptor.image_type == .cube and descriptor.base_array % 6 == 0 and layers % 6 == 0 and descriptor.width == descriptor.height,
            2 => descriptor.image_type == .color_2d_array or descriptor.image_type == .cube,
            else => unreachable,
        };
        const compressed = format == 71 or format == 74 or format == 77;
        const mips = descriptor.viewMipLevels();
        const mip_allocation = descriptor.resourceMipLevels() > 1;
        // A DCC-compressed RGBA8 view (for example a render target the guest
        // samples next) resolves its fast-clear keys before detiling. CMASK
        // and FMASK compression remain unsupported.
        const dcc: ?surfaces.Dcc = if (descriptor.dccMetadataAddress()) |address| .{ .address = address, .clear_word = null } else null;
        if (!view_supported or format == 0 or descriptor.viewBaseLevel() != 0 or
            descriptor.min_lod != 0 or (compressed and descriptor.bc_swizzle != 0) or
            descriptor.cmask_fast_clear or descriptor.fmask_compression or (dcc != null and (format != 28 or layers != 1 or mip_allocation)) or
            (dcc == null and gpu.MetadataSurface.fromImage(descriptor).hasAny()))
        {
            return error.GraphicsTextureFormatOrMipNotImplemented;
        }
        const expected_bytes = native.sampledImageMipChainSize(descriptor.width, descriptor.height, format, layers, dimension, mips) catch return error.GraphicsTextureFormatOrMipNotImplemented;
        if (dimension == 1 and sampler.disable_cube_wrap) return error.GraphicsSamplerModeNotImplemented;
        // Narrow and packed formats have no sRGB DXGI variants; adding one
        // to their enum does not select a gamma-decoding view.
        if (sampler.force_srgb and (format == 61 or format == 49 or format == 115)) return error.GraphicsSamplerModeNotImplemented;
        if (sampler.trunc_coordinates or sampler.filter_mode != 0 or sampler.maximum_anisotropy > 4 or
            sampler.mip_filter > 2 or sampler.border_color_type == 3)
            return error.GraphicsSamplerModeNotImplemented;
        const anisotropy = sampler.maximum_anisotropy != 0 and (sampler.minification_filter >= 2 or sampler.magnification_filter >= 2);
        if (anisotropy and (sampler.minification_filter != sampler.magnification_filter or
            dimension == 1 or resolver.bindings.stage != .pixel or sampler.unnormalized_coordinates or
            @as(u16, @bitCast(inst.image_sample_flags)) != 0 or sampler.mip_filter == 0)) return error.GraphicsSamplerModeNotImplemented;
        const unnormalized = sampler.unnormalized_coordinates;
        if (unnormalized and (mips != 1 or dimension != 0 or resolver.bindings.stage != .pixel or @as(u16, @bitCast(inst.image_sample_flags)) != 0 or
            sampler.mip_filter != 0 or sampler.minimum_lod != 0 or sampler.lod_bias != 0 or
            sampler.minification_filter != sampler.magnification_filter)) return error.GraphicsSamplerModeNotImplemented;
        const layout = if (!mip_allocation) try gpu.SurfaceLayout.fromImage(descriptor) else null;
        if (layout) |single| {
            if (single.staging_bytes != expected_bytes) return error.GraphicsImageFootprintMismatch;
            if (single.required_source_bytes > 256 * 1024 * 1024 or single.staging_bytes > 256 * 1024 * 1024) return error.GraphicsSnapshotBudgetExceeded;
            _ = try single.sourceRange(descriptor.address);
        }
        var retained: ?texture_cache.Lease = null;
        var pixel_lease: staging.Lease = undefined;
        // DCC keys are not covered by the texture cache's page proof, so a
        // compressed view always takes the fresh read path.
        const pixels: []const u8 = if (mip_allocation) blk: {
            const texture = try gpu.TextureLayout.fromImage(descriptor);
            var required: u64 = 0;
            for (0..mips) |level| required = @max(required, (try texture.subresource(@intCast(level), 0, layers)).required_source_bytes);
            if (required > 256 * 1024 * 1024) return error.GraphicsSnapshotBudgetExceeded;
            _ = try std.math.add(u64, descriptor.address, required);
            var backing = try staging.Lease.alloc(self.allocator, self.pool, @intCast(required));
            defer backing.deinit();
            try self.reader.read(descriptor.address, backing.bytes);
            pixel_lease = try staging.Lease.alloc(self.allocator, self.pool, expected_bytes);
            errdefer pixel_lease.deinit();
            var offset: usize = 0;
            // Native D3D subresource order: mip + layer * mip_count.
            for (0..layers) |layer| for (0..mips) |level| {
                const view = try texture.subresource(@intCast(level), @intCast(layer), 1);
                const size: usize = @intCast(try view.stagingBytes());
                if (size > pixel_lease.bytes.len - offset) return error.GraphicsImageFootprintMismatch;
                try view.detile(backing.bytes, pixel_lease.bytes[offset..][0..size]);
                offset += size;
            };
            if (offset != expected_bytes) return error.GraphicsImageFootprintMismatch;
            break :blk pixel_lease.bytes;
        } else if (self.textures != null and dcc == null) blk: {
            retained = try self.textures.?.acquire(self.allocator, self.reader, self.tracking, descriptor.address, layout.?);
            break :blk retained.?.pixels();
        } else blk: {
            var backing_lease = try staging.Lease.alloc(self.allocator, self.pool, @intCast(layout.?.required_source_bytes));
            defer backing_lease.deinit();
            const backing = backing_lease.bytes;
            try self.reader.read(descriptor.address, backing);
            if (dcc) |metadata| {
                const keys = try self.allocator.alloc(u8, std.math.divCeil(usize, backing.len, surfaces.Dcc.block_bytes) catch unreachable);
                defer self.allocator.free(keys);
                try metadata.expand(.{ .context = self.reader.context, .read = self.reader.read_fn }, backing, keys);
            }
            pixel_lease = try staging.Lease.alloc(self.allocator, self.pool, @intCast(layout.?.staging_bytes));
            errdefer pixel_lease.deinit();
            if (self.cache) |c| try c.detile(descriptor.address, layout.?, backing, pixel_lease.bytes) else try layout.?.detile(backing, pixel_lease.bytes);
            break :blk pixel_lease.bytes;
        };
        var owns_pixels = true;
        errdefer if (owns_pixels) {
            if (retained) |lease| lease.release() else pixel_lease.deinit();
        };
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
        const image = native.SampledImage{
            .pixels = pixels.ptr,
            .size = pixels.len,
            .content_id = if (retained) |lease| lease.contentId() else 0,
            .width = descriptor.width,
            .height = descriptor.height,
            .layers = layers,
            .dimension = dimension,
            .mip_levels = mips,
            .format = format,
            .srgb = @intFromBool(sampler.force_srgb or (compressed and descriptor.unified_format % 2 == 0)),
            .components = components,
            .filter = (@as(u32, sampler.minification_filter & 1) << 4) | (@as(u32, sampler.magnification_filter & 1) << 2) | @intFromBool(sampler.mip_filter == 2),
            .address_u = if (unnormalized) try unnormalizedAddressMode(sampler.clamp_x) else try addressMode(sampler.clamp_x),
            .address_v = if (unnormalized) try unnormalizedAddressMode(sampler.clamp_y) else try addressMode(sampler.clamp_y),
            .address_w = if (unnormalized) 3 else try addressMode(sampler.clamp_z),
            .min_lod = if (unnormalized) 0 else sampler.minimum_lod,
            .max_lod = if (unnormalized) 0 else sampler.maximum_lod,
            // Shader anisotropy adds bias while selecting its explicit LOD.
            // Keep the native sampler neutral to avoid applying it twice.
            .lod_bias = if (unnormalized or anisotropy) 0 else sampler.lod_bias,
            .border = switch (sampler.border_color_type) {
                0 => .{ 0, 0, 0, 0 },
                1 => .{ 0, 0, 0, 1 },
                2 => .{ 1, 1, 1, 1 },
                else => unreachable,
            },
        };
        const slot = matchingImage(self.images.items, image) orelse fresh: {
            if (self.images.items.len >= 32 or self.total + pixels.len > 256 * 1024 * 1024) {
                std.debug.print("[d3d12 resource budget] image program=0x{x} pc=0x{x} bytes={d} total={d} buffers={d} images={d}\n", .{ resolver.bindings.program_address, inst.pc, pixels.len, self.total, self.buffers.items.len, self.images.items.len });
                return error.GraphicsSnapshotBudgetExceeded;
            }
            const index: u32 = @intCast(self.images.items.len);
            try self.images.append(self.allocator, image);
            owns_pixels = false;
            if (retained) |lease| {
                self.texture_leases[self.texture_lease_count] = lease;
                self.texture_lease_count += 1;
            } else {
                self.leases[self.lease_count] = pixel_lease;
                self.lease_count += 1;
            }
            self.total += pixels.len;
            break :fresh index;
        };
        if (owns_pixels) {
            if (retained) |lease| lease.release() else pixel_lease.deinit();
            owns_pixels = false;
        }
        try stage.images.append(self.allocator, .{
            .resource_sgpr = inst.src1.reg,
            .sampler_sgpr = inst.src2.reg,
            .descriptor_index = slot,
            .instruction_pc = inst.pc,
            .dimension = switch (dimension) {
                0 => .two_d,
                1 => .cube,
                2 => .two_d_array,
                else => unreachable,
            },
            .minimum_lod = sampler.minimum_lod,
            .maximum_lod = sampler.maximum_lod,
            .texel_coordinates_extent = if (unnormalized) .{ descriptor.width, descriptor.height } else null,
            .anisotropy = if (anisotropy) .{
                .extent = .{ descriptor.width, descriptor.height },
                .max_taps = @as(u8, 1) << @as(u3, @intCast(sampler.maximum_anisotropy)),
                .lod_bias = sampler.lod_bias,
            } else null,
        });
    }
};

/// Instruction count is not descriptor count. Reuse an identical native view
/// only after acquiring a fresh, validated immutable snapshot for this read.
fn matchingImage(images: []const native.SampledImage, candidate: native.SampledImage) ?u32 {
    for (images, 0..) |previous, index| {
        var view = candidate;
        view.pixels = previous.pixels;
        view.content_id = previous.content_id;
        if (!std.meta.eql(previous, view)) continue;
        if ((candidate.content_id != 0 and candidate.content_id == previous.content_id) or
            std.mem.eql(u8, previous.pixels[0..previous.size], candidate.pixels[0..candidate.size])) return @intCast(index);
    }
    return null;
}

test "sampled instructions share only matching views with freshly proven complete contents" {
    var a: [64]u8 = @splat(0x41);
    var b = a;
    const previous = [_]native.SampledImage{.{ .pixels = &a, .size = a.len, .width = 4, .height = 4 }};
    var candidate = previous[0];
    candidate.pixels = &b;
    try std.testing.expectEqual(@as(?u32, 0), matchingImage(&previous, candidate));
    b[b.len - 1] ^= 1;
    try std.testing.expect(matchingImage(&previous, candidate) == null);
    b = a;
    candidate.filter = 0x15;
    try std.testing.expect(matchingImage(&previous, candidate) == null);
    candidate = previous[0];
    candidate.components ^= 7;
    try std.testing.expect(matchingImage(&previous, candidate) == null);
    candidate = previous[0];
    candidate.width = 8;
    candidate.height = 2;
    try std.testing.expect(matchingImage(&previous, candidate) == null);
    candidate = previous[0];
    candidate.dimension = 2;
    try std.testing.expect(matchingImage(&previous, candidate) == null);
    candidate = previous[0];
    candidate.layers = 2;
    try std.testing.expect(matchingImage(&previous, candidate) == null);
}

test "duplicate instruction snapshots compare all current bytes and keep changed versions" {
    const Memory = struct {
        data: [32769]u8 = @splat(0x51),
        fail: bool = false,
        fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.fail or address < 0x1000 or address - 0x1000 + bytes.len > self.data.len) return false;
            @memcpy(bytes, self.data[@intCast(address - 0x1000)..][0..bytes.len]);
            return true;
        }
    };
    var memory = Memory{};
    var captured = DrawResources{ .allocator = std.testing.allocator, .reader = .{ .context = &memory, .read_fn = Memory.read } };
    defer captured.deinit();
    const first = try captured.snapshot(0x1000, memory.data.len, false);
    const cost = captured.total;
    try std.testing.expectEqual(first, try captured.snapshot(0x1000, memory.data.len, false));
    try std.testing.expectEqual(cost, captured.total);
    memory.data[memory.data.len - 1] ^= 0x80;
    const changed = try captured.snapshot(0x1000, memory.data.len, false);
    try std.testing.expect(changed != first);
    try std.testing.expectEqual(@as(u8, 0x51), captured.buffers.items[first].bytes[memory.data.len - 1]);
    try std.testing.expectEqual(changed, try captured.snapshot(0x1000, memory.data.len, false));
    try std.testing.expect(changed != try captured.snapshot(0x1000, memory.data.len, true));
    memory.fail = true;
    try std.testing.expectError(error.MemoryReadFailed, captured.snapshot(0x1000, memory.data.len, false));
}

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
