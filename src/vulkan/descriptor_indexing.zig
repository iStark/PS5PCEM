// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Limits for optional update-after-bind sampled image banks. Buffer/image
//! writes still use the existing fence-owned descriptor slots.
const std = @import("std");

pub const Properties = extern struct {
    s_type: u32 = 1_000_161_002,
    p_next: ?*anyopaque = null,
    max_pool_descriptors: u32 = 0,
    uniform_nonuniform_native: u32 = 0,
    sampled_nonuniform_native: u32 = 0,
    storage_buffer_nonuniform_native: u32 = 0,
    storage_image_nonuniform_native: u32 = 0,
    input_attachment_nonuniform_native: u32 = 0,
    robust_buffer_access: u32 = 0,
    quad_divergent_implicit_lod: u32 = 0,
    stage_samplers: u32 = 0,
    stage_uniform_buffers: u32 = 0,
    stage_storage_buffers: u32 = 0,
    stage_sampled_images: u32 = 0,
    stage_storage_images: u32 = 0,
    stage_input_attachments: u32 = 0,
    stage_resources: u32 = 0,
    set_samplers: u32 = 0,
    set_uniform_buffers: u32 = 0,
    set_dynamic_uniform_buffers: u32 = 0,
    set_storage_buffers: u32 = 0,
    set_dynamic_storage_buffers: u32 = 0,
    set_sampled_images: u32 = 0,
    set_storage_images: u32 = 0,
    set_input_attachments: u32 = 0,

    pub fn fits(self: Properties, images: u64, buffers: u64, storage_images: u64, sets: u64) bool {
        const per_set = images + buffers + storage_images;
        return images <= self.stage_samplers and images <= self.set_samplers and
            images <= self.stage_sampled_images and images <= self.set_sampled_images and
            buffers <= self.stage_storage_buffers and buffers <= self.set_storage_buffers and
            storage_images <= self.stage_storage_images and storage_images <= self.set_storage_images and
            per_set <= self.stage_resources and per_set * sets <= self.max_pool_descriptors;
    }
};

test "update-after-bind keeps the full layout only when stage set and pool limits fit" {
    var p = Properties{ .max_pool_descriptors = 60000, .stage_samplers = 100, .set_samplers = 100, .stage_sampled_images = 100, .set_sampled_images = 100, .stage_storage_buffers = 10, .set_storage_buffers = 10, .stage_storage_images = 5, .set_storage_images = 5, .stage_resources = 115 };
    try std.testing.expect(p.fits(100, 10, 5, 512));
    try std.testing.expect(!p.fits(101, 10, 5, 512));
    try std.testing.expect(!p.fits(100, 11, 5, 512));
    try std.testing.expect(!p.fits(100, 10, 6, 512));
    try std.testing.expect(!p.fits(100, 10, 5, 523));
    p.stage_resources = 114;
    try std.testing.expect(!p.fits(100, 10, 5, 512));
}
