// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Single-subresource compute UAV snapshots. Guest layout is preserved by
//! detiling before dispatch and retiling only the selected mip/layers afterward.
const std = @import("std");
const gpu = @import("gpu");
const rdna2 = @import("rdna2");
const native = @import("root.zig");

pub const Images = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayList(rdna2.spirv.StorageImageBinding) = .empty,
    native_images: [32]native.StorageImage = undefined,
    entries: [32]Entry = undefined,
    count: usize = 0,
    total: usize = 0,

    const Entry = struct {
        descriptor: gpu.resources.ImageDescriptor,
        layout: gpu.TextureSubresourceLayout,
        pixels: []u8,
    };

    pub fn deinit(self: *Images) void {
        for (self.entries[0..self.count]) |entry| self.allocator.free(entry.pixels);
        self.bindings.deinit(self.allocator);
    }

    pub fn capture(self: *Images, resolver: *gpu.scalar_resources.Resolver, inst: gpu.ShaderInstruction) !void {
        errdefer std.debug.print("[d3d12 compute image] program=0x{x} pc=0x{x} op={s} dim={s}\n", .{ resolver.bindings.program_address, inst.pc, @tagName(inst.opcode), @tagName(inst.image_dimension) });
        if (inst.opcode != .image_load and inst.opcode != .image_store and inst.opcode != .image_get_resinfo)
            return error.ComputeImageOperationNotImplemented;
        if (inst.image_r128) return error.ComputeImageOperationNotImplemented;
        var words: [8]u32 = undefined;
        if (!try resolver.words(inst.src1.reg, inst.pc, &words)) return error.DynamicComputeImageNotImplemented;
        const descriptor = try gpu.resources.decodeImageDescriptor(&words);
        errdefer std.debug.print("[d3d12 compute image] descriptor={any}\n", .{descriptor});
        if (descriptor.address == 0 or descriptor.viewMipLevels() != 1 or descriptor.samplesLog2() != 0 or
            gpu.MetadataSurface.fromImage(descriptor).hasAny()) return error.ComputeImageLayoutNotImplemented;
        const dimension: rdna2.spirv.StorageImageDimension = switch (inst.image_dimension) {
            .dim_2d => .two_d,
            .dim_2d_array_alt => .two_d_array,
            .dim_3d => .three_d,
            else => return error.ComputeImageLayoutNotImplemented,
        };
        const matching_type = switch (dimension) {
            .two_d => descriptor.image_type == .color_2d or descriptor.image_type == .color_2d_array,
            .two_d_array => descriptor.image_type == .color_2d_array or descriptor.image_type == .cube,
            .three_d => descriptor.image_type == .color_3d,
        };
        const native_dimension: u32 = switch (dimension) {
            .two_d => 0,
            .two_d_array => 1,
            .three_d => 2,
        };
        if (!matching_type) return error.ComputeImageLayoutNotImplemented;
        const format = std.enums.fromInt(rdna2.spirv.StorageImageFormat, descriptor.unified_format) orelse return error.ComputeImageFormatNotImplemented;
        const native_format = try nativeFormat(format);
        const texture = try gpu.TextureLayout.fromImage(descriptor);
        const view = try texture.subresource(descriptor.viewBaseLevel(), 0, if (dimension == .two_d_array) texture.layers else 1);
        if (dimension == .two_d and view.depth_or_layers != 1) return error.ComputeImageLayoutNotImplemented;
        const writable = inst.opcode == .image_store;
        const slot: u32 = blk: {
            for (self.entries[0..self.count], 0..) |entry, i| {
                if (std.meta.eql(entry.descriptor, descriptor) and self.native_images[i].dimension == native_dimension) {
                    self.native_images[i].writable |= @intFromBool(writable);
                    break :blk @intCast(i);
                }
                // Distinct subresources of the same allocation are permitted.
                // Overlapping views with different formats/layouts are not.
                if (descriptor.address < entry.descriptor.address + entry.layout.required_source_bytes and
                    entry.descriptor.address < descriptor.address + view.required_source_bytes and
                    !(descriptor.address == entry.descriptor.address and
                        descriptor.width == entry.descriptor.width and descriptor.height == entry.descriptor.height and
                        descriptor.depth_or_layers == entry.descriptor.depth_or_layers and descriptor.tile_mode == entry.descriptor.tile_mode and
                        descriptor.pitch == entry.descriptor.pitch and descriptor.unified_format == entry.descriptor.unified_format and
                        descriptor.resourceMipLevels() == entry.descriptor.resourceMipLevels() and
                        descriptor.viewBaseLevel() != entry.descriptor.viewBaseLevel())) return error.ComputeImageAliasNotImplemented;
            }
            const size: usize = @intCast(try view.stagingBytes());
            if (self.count == self.entries.len or view.required_source_bytes > 256 * 1024 * 1024 or size > 256 * 1024 * 1024 or self.total + size > 256 * 1024 * 1024) return error.StorageBudgetExceeded;
            _ = try std.math.add(u64, descriptor.address, view.required_source_bytes);
            const backing = try self.allocator.alloc(u8, @intCast(view.required_source_bytes));
            defer self.allocator.free(backing);
            try resolver.reader.read(descriptor.address, backing);
            const pixels = try self.allocator.alloc(u8, size);
            errdefer self.allocator.free(pixels);
            try view.detile(backing, pixels);
            const index = self.count;
            self.entries[index] = .{ .descriptor = descriptor, .layout = view, .pixels = pixels };
            self.native_images[index] = .{
                .pixels = pixels.ptr,
                .size = pixels.len,
                .width = view.width,
                .height = view.height,
                .layers = view.depth_or_layers,
                .dimension = native_dimension,
                .format = native_format,
                .writable = @intFromBool(writable),
            };
            self.count += 1;
            self.total += size;
            break :blk @intCast(index);
        };
        try self.bindings.append(self.allocator, .{ .resource_sgpr = inst.src1.reg, .instruction_pc = inst.pc, .descriptor_index = slot, .format = format, .dimension = dimension, .dst_select = descriptor.dst_select });
    }

    pub fn commit(self: *Images, memory: anytype) !void {
        for (self.entries[0..self.count], self.native_images[0..self.count]) |entry, image| {
            if (image.writable == 0) continue;
            const backing = try self.allocator.alloc(u8, @intCast(entry.layout.required_source_bytes));
            defer self.allocator.free(backing);
            // Read the current backing, including previous mip writebacks.
            if (!memory.read(memory.context, entry.descriptor.address, backing)) return error.GuestReadFailed;
            try entry.layout.tile(entry.pixels, backing);
            if (!memory.write(memory.context, entry.descriptor.address, backing)) return error.GuestWriteFailed;
        }
    }
};

pub fn nativeFormat(format: rdna2.spirv.StorageImageFormat) !u32 {
    return switch (format) {
        .r8_unorm => 61,
        .r8_snorm => 63,
        .r8_uint => 62,
        .r8_sint => 64,
        .r16_unorm => 56,
        .r16_snorm => 58,
        .r16_uint => 57,
        .r16_sint => 59,
        .r16_float => 54,
        .rg8_unorm => 49,
        .rg8_snorm => 51,
        .rg8_uint => 50,
        .rg8_sint => 52,
        .r32_uint => 42,
        .r32_sint => 43,
        .r32_float => 41,
        .rg16_unorm => 35,
        .rg16_snorm => 37,
        .rg16_uint => 36,
        .rg16_sint => 38,
        .rg16_float => 34,
        .r11g11b10_float => 26,
        .rgb10a2_unorm => 24,
        .rgba8_unorm => 28,
        .rgba8_snorm => 31,
        .rgba8_uint => 30,
        .rgba8_sint => 32,
        .rg32_uint => 17,
        .rg32_sint => 18,
        .rg32_float => 16,
        .rgba16_unorm => 11,
        .rgba16_snorm => 13,
        .rgba16_uint => 12,
        .rgba16_sint => 14,
        .rgba16_float => 10,
        .rgba32_uint => 3,
        .rgba32_sint => 4,
        .rgba32_float => 2,
        .r11g11b10_unorm => error.ComputeImageFormatNotImplemented,
    };
}
