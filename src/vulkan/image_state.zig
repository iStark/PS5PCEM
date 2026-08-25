// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Subresource-aware Vulkan image layout and hazard tracking.

const std = @import("std");
const vk = @import("api.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidSubresourceRange,
    ImageAlreadyRegistered,
    ImageNotRegistered,
    TransitionCapacityExceeded,
};

pub const Usage = struct {
    layout: u32,
    access: vk.Flags,
    stages: vk.Flags,

    pub fn eql(self: Usage, other: Usage) bool {
        return self.layout == other.layout and
            self.access == other.access and
            self.stages == other.stages;
    }

    pub fn readOnly(self: Usage) bool {
        return self.access & write_access_mask == 0;
    }
};

pub const undefined_usage = Usage{
    .layout = vk.image_layout_undefined,
    .access = 0,
    .stages = vk.pipeline_stage_top_of_pipe_bit,
};

pub const color_attachment_usage = Usage{
    .layout = vk.image_layout_color_attachment_optimal,
    .access = vk.access_color_attachment_read_bit | vk.access_color_attachment_write_bit,
    .stages = vk.pipeline_stage_color_attachment_output_bit,
};

pub const depth_attachment_usage = Usage{
    .layout = vk.image_layout_depth_stencil_attachment_optimal,
    .access = vk.access_depth_stencil_attachment_read_bit | vk.access_depth_stencil_attachment_write_bit,
    .stages = vk.pipeline_stage_early_fragment_tests_bit | vk.pipeline_stage_late_fragment_tests_bit,
};

pub const shader_read_usage = Usage{
    .layout = vk.image_layout_shader_read_only_optimal,
    .access = vk.access_shader_read_bit,
    .stages = vk.pipeline_stage_vertex_shader_bit |
        vk.pipeline_stage_fragment_shader_bit |
        vk.pipeline_stage_compute_shader_bit,
};

pub const storage_usage = Usage{
    .layout = vk.image_layout_general,
    .access = vk.access_shader_read_bit | vk.access_shader_write_bit,
    .stages = vk.pipeline_stage_compute_shader_bit |
        vk.pipeline_stage_fragment_shader_bit,
};

pub const transfer_source_usage = Usage{
    .layout = vk.image_layout_transfer_src_optimal,
    .access = vk.access_transfer_read_bit,
    .stages = vk.pipeline_stage_transfer_bit,
};

pub const transfer_destination_usage = Usage{
    .layout = vk.image_layout_transfer_dst_optimal,
    .access = vk.access_transfer_write_bit,
    .stages = vk.pipeline_stage_transfer_bit,
};

pub const present_usage = Usage{
    .layout = vk.image_layout_present_src_khr,
    .access = 0,
    .stages = vk.pipeline_stage_bottom_of_pipe_bit,
};

const write_access_mask: vk.Flags = vk.access_shader_write_bit |
    vk.access_color_attachment_write_bit |
    vk.access_depth_stencil_attachment_write_bit |
    vk.access_transfer_write_bit |
    vk.access_host_write_bit;

pub const SubresourceRange = struct {
    aspect_mask: vk.Flags,
    base_mip_level: u32 = 0,
    level_count: u32 = 1,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,

    pub fn fromVulkan(range: vk.ImageSubresourceRange) SubresourceRange {
        return .{
            .aspect_mask = range.aspect_mask,
            .base_mip_level = range.base_mip_level,
            .level_count = range.level_count,
            .base_array_layer = range.base_array_layer,
            .layer_count = range.layer_count,
        };
    }

    pub fn toVulkan(self: SubresourceRange) vk.ImageSubresourceRange {
        return .{
            .aspect_mask = self.aspect_mask,
            .base_mip_level = self.base_mip_level,
            .level_count = self.level_count,
            .base_array_layer = self.base_array_layer,
            .layer_count = self.layer_count,
        };
    }

    fn valid(self: SubresourceRange) bool {
        return self.aspect_mask != 0 and self.level_count != 0 and self.layer_count != 0;
    }
};

const Cell = struct {
    image: vk.Image,
    aspect: vk.Flags,
    mip_level: u32,
    array_layer: u32,
    usage: Usage = undefined_usage,
};

pub const Transition = struct {
    source_stages: vk.Flags,
    destination_stages: vk.Flags,
    barrier: vk.ImageMemoryBarrier,
};

pub const Tracker = struct {
    cells: std.ArrayList(Cell) = .empty,

    pub fn deinit(self: *Tracker, allocator: std.mem.Allocator) void {
        self.cells.deinit(allocator);
        self.* = .{};
    }

    pub fn registerImage(
        self: *Tracker,
        allocator: std.mem.Allocator,
        image: vk.Image,
        range: SubresourceRange,
    ) Error!void {
        if (!range.valid()) return Error.InvalidSubresourceRange;
        for (self.cells.items) |cell| {
            if (cell.image == image) return Error.ImageAlreadyRegistered;
        }
        var aspect_count: usize = 0;
        var bits = range.aspect_mask;
        while (bits != 0) : (bits &= bits - 1) aspect_count += 1;
        const mip_layers = std.math.mul(usize, range.level_count, range.layer_count) catch
            return Error.InvalidSubresourceRange;
        const cell_count = std.math.mul(usize, aspect_count, mip_layers) catch
            return Error.InvalidSubresourceRange;
        try self.cells.ensureUnusedCapacity(allocator, cell_count);

        bits = range.aspect_mask;
        while (bits != 0) : (bits &= bits - 1) {
            const aspect = bits & (~bits +% 1);
            var mip: u32 = 0;
            while (mip < range.level_count) : (mip += 1) {
                var layer: u32 = 0;
                while (layer < range.layer_count) : (layer += 1) {
                    self.cells.appendAssumeCapacity(.{
                        .image = image,
                        .aspect = aspect,
                        .mip_level = range.base_mip_level + mip,
                        .array_layer = range.base_array_layer + layer,
                    });
                }
            }
        }
    }

    pub fn forgetImage(self: *Tracker, image: vk.Image) void {
        var index = self.cells.items.len;
        while (index > 0) {
            index -= 1;
            if (self.cells.items[index].image == image) _ = self.cells.swapRemove(index);
        }
    }

    pub fn current(
        self: *const Tracker,
        image: vk.Image,
        aspect: vk.Flags,
        mip_level: u32,
        array_layer: u32,
    ) ?Usage {
        for (self.cells.items) |cell| {
            if (cell.image == image and cell.aspect == aspect and
                cell.mip_level == mip_level and cell.array_layer == array_layer)
            {
                return cell.usage;
            }
        }
        return null;
    }

    /// Plans and commits transitions in queue-recording order. One barrier is
    /// returned per aspect/mip/layer cell, which stays correct even when a view
    /// spans subresources currently in different layouts.
    pub fn transition(
        self: *Tracker,
        image: vk.Image,
        range: SubresourceRange,
        next: Usage,
        output: []Transition,
    ) Error!usize {
        if (!range.valid()) return Error.InvalidSubresourceRange;
        var matched = false;
        var required: usize = 0;
        for (self.cells.items, 0..) |cell, cell_index| {
            if (cell.image != image or range.aspect_mask & cell.aspect == 0 or
                cell.mip_level < range.base_mip_level or
                cell.mip_level - range.base_mip_level >= range.level_count or
                cell.array_layer < range.base_array_layer or
                cell.array_layer - range.base_array_layer >= range.layer_count)
            {
                continue;
            }
            matched = true;
            const previous = cell.usage;
            // Read-after-read in the same layout is already ordered. Any write
            // retains a memory dependency even when no layout change is needed.
            if (previous.eql(next) and previous.readOnly()) continue;
            var grouped = false;
            for (self.cells.items[0..cell_index]) |earlier| {
                if (earlier.image == image and range.aspect_mask & earlier.aspect != 0 and
                    earlier.mip_level == cell.mip_level and earlier.array_layer == cell.array_layer and
                    earlier.usage.eql(previous) and !(earlier.usage.eql(next) and earlier.usage.readOnly()))
                {
                    grouped = true;
                    break;
                }
            }
            if (!grouped) required += 1;
        }
        if (!matched) return Error.ImageNotRegistered;
        if (required > output.len) return Error.TransitionCapacityExceeded;

        var count: usize = 0;
        for (self.cells.items) |*cell| {
            if (cell.image != image or range.aspect_mask & cell.aspect == 0 or
                cell.mip_level < range.base_mip_level or
                cell.mip_level - range.base_mip_level >= range.level_count or
                cell.array_layer < range.base_array_layer or
                cell.array_layer - range.base_array_layer >= range.layer_count)
            {
                continue;
            }
            const previous = cell.usage;
            if (previous.eql(next) and previous.readOnly()) continue;
            var merged = false;
            for (output[0..count]) |*existing| {
                const barrier = &existing.barrier;
                if (existing.source_stages != previous.stages or
                    existing.destination_stages != next.stages or
                    barrier.source_access_mask != previous.access or
                    barrier.destination_access_mask != next.access or
                    barrier.old_layout != previous.layout or barrier.new_layout != next.layout or
                    barrier.subresource_range.base_mip_level != cell.mip_level or
                    barrier.subresource_range.base_array_layer != cell.array_layer)
                {
                    continue;
                }
                barrier.subresource_range.aspect_mask |= cell.aspect;
                merged = true;
                break;
            }
            if (merged) {
                cell.usage = next;
                continue;
            }
            output[count] = .{
                .source_stages = previous.stages,
                .destination_stages = next.stages,
                .barrier = .{
                    .source_access_mask = previous.access,
                    .destination_access_mask = next.access,
                    .old_layout = previous.layout,
                    .new_layout = next.layout,
                    .image = image,
                    .subresource_range = .{
                        .aspect_mask = cell.aspect,
                        .base_mip_level = cell.mip_level,
                        .level_count = 1,
                        .base_array_layer = cell.array_layer,
                        .layer_count = 1,
                    },
                },
            };
            count += 1;
            cell.usage = next;
        }
        return count;
    }
};

test "subresources retain independent layouts" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    try tracker.registerImage(std.testing.allocator, 7, .{
        .aspect_mask = vk.image_aspect_color_bit,
        .level_count = 3,
        .layer_count = 2,
    });
    var transitions: [8]Transition = undefined;
    const count = try tracker.transition(7, .{
        .aspect_mask = vk.image_aspect_color_bit,
        .base_mip_level = 1,
        .level_count = 1,
        .base_array_layer = 1,
        .layer_count = 1,
    }, shader_read_usage, &transitions);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(shader_read_usage, tracker.current(
        7,
        vk.image_aspect_color_bit,
        1,
        1,
    ).?);
    try std.testing.expectEqual(undefined_usage, tracker.current(
        7,
        vk.image_aspect_color_bit,
        0,
        1,
    ).?);
}

test "same-layout writes still produce a memory hazard" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    try tracker.registerImage(std.testing.allocator, 11, .{
        .aspect_mask = vk.image_aspect_color_bit,
    });
    var transitions: [2]Transition = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try tracker.transition(11, .{ .aspect_mask = vk.image_aspect_color_bit }, storage_usage, &transitions),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try tracker.transition(11, .{ .aspect_mask = vk.image_aspect_color_bit }, storage_usage, &transitions),
    );
    try std.testing.expectEqual(vk.image_layout_general, transitions[0].barrier.old_layout);
    try std.testing.expect(transitions[0].barrier.source_access_mask & vk.access_shader_write_bit != 0);
}

test "same-layout read-only reuse needs no barrier" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    try tracker.registerImage(std.testing.allocator, 13, .{
        .aspect_mask = vk.image_aspect_depth_bit | vk.image_aspect_stencil_bit,
    });
    var transitions: [4]Transition = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try tracker.transition(13, .{
            .aspect_mask = vk.image_aspect_depth_bit | vk.image_aspect_stencil_bit,
        }, shader_read_usage, &transitions),
    );
    try std.testing.expectEqual(
        vk.image_aspect_depth_bit | vk.image_aspect_stencil_bit,
        transitions[0].barrier.subresource_range.aspect_mask,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try tracker.transition(13, .{
            .aspect_mask = vk.image_aspect_depth_bit | vk.image_aspect_stencil_bit,
        }, shader_read_usage, &transitions),
    );
}

test "capacity failure does not partially commit subresource state" {
    var tracker = Tracker{};
    defer tracker.deinit(std.testing.allocator);
    try tracker.registerImage(std.testing.allocator, 17, .{
        .aspect_mask = vk.image_aspect_color_bit,
        .level_count = 2,
    });
    var too_small: [1]Transition = undefined;
    try std.testing.expectError(Error.TransitionCapacityExceeded, tracker.transition(
        17,
        .{ .aspect_mask = vk.image_aspect_color_bit, .level_count = 2 },
        transfer_destination_usage,
        &too_small,
    ));
    try std.testing.expect(tracker.current(17, vk.image_aspect_color_bit, 0, 0).?.eql(undefined_usage));
    try std.testing.expect(tracker.current(17, vk.image_aspect_color_bit, 1, 0).?.eql(undefined_usage));
}
