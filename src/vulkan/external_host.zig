// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Optional coherent host allocation imports. The embedding retains an
//! independent mapping until Vulkan has finished and freed its memory object.
const vk = @import("api.zig");

pub const handle_type: u32 = 0x80;
pub const Mapping = struct {
    /// Retained, committed host view, including any required alignment prefix.
    bytes: []u8,
    /// Offset of the requested guest range within bytes.
    offset: usize,
    /// Physical byte offset of the requested range in this Source.
    identity: u64,
    release: *const fn ([]u8) void,
};
pub const Source = struct {
    context: ?*anyopaque,
    /// Must change when a guest VA is remapped to different physical bytes.
    identity: *const fn (?*anyopaque, u64, usize) ?u64,
    /// Recheck the expected identity and retain a view until release is called.
    acquire: *const fn (?*anyopaque, u64, usize, u64) ?Mapping,
    /// Publish completed GPU writes without copying the coherent bytes again.
    publish: *const fn (?*anyopaque, u64, usize) bool,
};
pub const BufferInfo = extern struct {
    s_type: u32 = 1000072000,
    p_next: ?*const anyopaque = null,
    handle_types: u32 = handle_type,
};
pub const ImportInfo = extern struct {
    s_type: u32 = 1000178000,
    p_next: ?*const anyopaque = null,
    handle: u32 = handle_type,
    pointer: *anyopaque,
};
pub const PointerProperties = extern struct {
    s_type: u32 = 1000178001,
    p_next: ?*anyopaque = null,
    memory_type_bits: u32 = 0,
};
pub const HostProperties = extern struct {
    s_type: u32 = 1000178002,
    p_next: ?*anyopaque = null,
    alignment: u64 = 0,
};
pub const Properties2 = extern struct {
    s_type: u32 = 1000059001,
    p_next: ?*anyopaque,
    // vkGetPhysicalDeviceProperties2 writes the complete core properties.
    properties: [1024]u64 = @splat(0),
};
pub const GetProperties2 = *const fn (vk.PhysicalDevice, *Properties2) callconv(vk.call) void;
pub const GetPointerProperties = *const fn (vk.Device, u32, *const anyopaque, *PointerProperties) callconv(vk.call) vk.Result;
