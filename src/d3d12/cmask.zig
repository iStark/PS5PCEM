// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Single-sample CMASK fast-clear materialization. The metadata has its own
//! FMASK_SW_MODE/CMASK_PIPE_ALIGNED fields, independent of the color swizzle.
const std = @import("std");
const gpu = @import("gpu");

pub const Cmask = struct {
    address: u64,
    layout: gpu.CmaskLayout,
    texel: [8]u8,
    texel_bytes: u8,

    pub fn fromTarget(target: gpu.resources.ColorTarget, state: *const gpu.State) !?Cmask {
        if (!target.cmask_fast_clear) return null;
        const attrib3 = state.readRegister(.context, 0x3b8 + @as(u32, target.slot)) orelse return error.UnsupportedMetadataLayout;
        if (target.dcc_enabled or target.fmask_compression or target.cmask_address == 0 or target.cmask_address & 4095 != 0 or target.cmask_linear or
            target.samples_log2 != 0 or target.fragments_log2 != 0 or target.maximum_mip != 0 or target.mip_level != 0 or
            target.resource_type == 2 or target.depth > 1 or target.base_array_slice != 0 or target.last_array_slice != 0 or
            (attrib3 >> 19) & 31 != 24 or attrib3 & (1 << 26) == 0 or
            (target.tile_mode != .render_target and target.tile_mode != .depth)) return error.UnsupportedMetadataLayout;
        const color = try gpu.SurfaceLayout.fromColorTarget(target);
        if (color.block.bytes_per_element > 8) return error.UnsupportedMetadataLayout;
        // Shared CMASK addressing currently takes its mode from the color
        // descriptor. Supply the actual metadata mode without changing color.
        var metadata_target = target;
        metadata_target.tile_mode = .depth;
        const layout = try gpu.CmaskLayout.fromColorTarget(metadata_target);
        const end = try std.math.add(u64, target.cmask_address, layout.required_bytes);
        const color_end = try std.math.add(u64, target.address, color.required_source_bytes);
        if (target.cmask_address < color_end and target.address < end) return error.AttachmentAliasNotImplemented;
        var texel: [8]u8 = undefined;
        std.mem.writeInt(u32, texel[0..4], target.clear_words[0], .little);
        std.mem.writeInt(u32, texel[4..8], target.clear_words[1], .little);
        return .{ .address = target.cmask_address, .layout = layout, .texel = texel, .texel_bytes = color.block.bytes_per_element };
    }

    pub fn read(self: Cmask, allocator: std.mem.Allocator, memory: anytype) ![]u8 {
        const keys = try allocator.alloc(u8, @intCast(self.layout.required_bytes));
        errdefer allocator.free(keys);
        if (!memory.read(memory.context, self.address, keys)) return error.GuestReadFailed;
        // Validate before modifying any color bytes, including mixed keys.
        var y: u32 = 0;
        while (y < self.layout.height) : (y += 8) {
            var x: u32 = 0;
            while (x < self.layout.width) : (x += 8) {
                const key = try self.layout.value(keys, x, y, 0);
                if (key != 0 and key != 15) return error.CompressedColorTargetNotImplemented;
            }
        }
        return keys;
    }

    pub fn expand(self: Cmask, keys: []const u8, color: gpu.SurfaceLayout, backing: []u8) !void {
        if (color.subresource != null or color.layers != 1 or color.block.bytes_per_element != self.texel_bytes or
            color.width != self.layout.width or color.height != self.layout.height or backing.len != color.required_source_bytes)
            return error.UnsupportedMetadataLayout;
        var padded = color;
        padded.width = std.mem.alignForward(u32, color.width, 8);
        padded.height = std.mem.alignForward(u32, color.height, 8);
        // A nibble covers all 8x8 texels, including padding at a view edge.
        // Materialize the entire region before marking its metadata expanded.
        var by: u32 = 0;
        while (by < color.height) : (by += 8) {
            var bx: u32 = 0;
            while (bx < color.width) : (bx += 8) {
                if (try self.layout.value(keys, bx, by, 0) != 0) continue;
                for (by..by + 8) |y| for (bx..bx + 8) |x| {
                    const offset: usize = @intCast(try padded.sourceByteOffset(@intCast(x), @intCast(y), 0));
                    if (offset > backing.len or self.texel_bytes > backing.len - offset) return error.DestinationTooSmall;
                    @memcpy(backing[offset..][0..self.texel_bytes], self.texel[0..self.texel_bytes]);
                };
            }
        }
    }

    pub fn publish(self: Cmask, keys: []u8, memory: anytype) !void {
        var y: u32 = 0;
        while (y < self.layout.height) : (y += 8) {
            var x: u32 = 0;
            while (x < self.layout.width) : (x += 8) try self.layout.setValue(keys, x, y, 0, 15);
        }
        if (!memory.write(memory.context, self.address, keys)) return error.GuestWriteFailed;
    }
};
