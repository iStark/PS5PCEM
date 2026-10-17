// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Initial native PM4 backend. Work completes before guest memory and release
//! labels become visible. Unsupported state rejects the submission; it never
//! delegates rendering to Vulkan or acknowledges a skipped draw as complete.
const std = @import("std");
const gpu = @import("gpu");
const rdna2 = @import("rdna2");
const native = @import("root.zig");

pub const Memory = struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, []u8) bool,
    write: *const fn (?*anyopaque, u64, []const u8) bool,
};
pub const DisplayBuffer = struct {
    address: u64,
    width: u32,
    height: u32,
    pitch_in_pixels: u32,
    tiling_mode: u32,
    pixel_format: u64,
};
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    device: native.Device,
    memory: Memory,
    failure: ?anyerror = null,
    on_failure: ?*const fn (anyerror) void = null,
    display_resolver: ?*const fn (gpu.state.Flip) ?DisplayBuffer = null,
    fps_context: ?*anyopaque = null,
    fps_update: ?*const fn (?*anyopaque, u32) void = null,
    frames: u32 = 0,
    frame_started_ns: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, memory: Memory, debug: bool) !Renderer {
        return .{ .allocator = allocator, .memory = memory, .device = try native.Device.init(debug) };
    }
    pub fn deinit(self: *Renderer) void {
        self.device.deinit();
        self.* = undefined;
    }
    pub fn dcbBackend(self: *Renderer) gpu.DcbBackend {
        return .{ .context = self, .vtable = &vtable };
    }
    fn reader(self: *Renderer) gpu.ShaderMemoryReader {
        return .{ .context = self.memory.context, .read_fn = self.memory.read };
    }
    fn from(context: ?*anyopaque) *Renderer {
        return @ptrCast(@alignCast(context.?));
    }
    fn rejected(self: *Renderer, operation: []const u8, err: anyerror) bool {
        if (self.failure == null) {
            self.failure = err;
            std.debug.print("[d3d12] {s} rejected: {s}; experimental backend stopped, no Vulkan fallback\n", .{ operation, @errorName(err) });
            if (self.on_failure) |callback| callback(err);
        }
        return false;
    }
    fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self = from(context);
        return self.failure == null and self.memory.read(self.memory.context, address, bytes);
    }
    fn write(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
        const self = from(context);
        return self.failure == null and self.memory.write(self.memory.context, address, bytes);
    }
    fn dispatchCallback(context: ?*anyopaque, state: *const gpu.State, packet: gpu.pm4.Packet) bool {
        const self = from(context);
        if (self.failure != null) return false;
        self.dispatch(state, packet) catch |err| return self.rejected("dispatch", err);
        return true;
    }
    fn drawCallback(context: ?*anyopaque, state: *const gpu.State, packet: gpu.pm4.Packet) bool {
        const self = from(context);
        if (self.failure != null) return false;
        self.draw(state, packet) catch |err| return self.rejected("draw", err);
        return true;
    }
    fn flipCallback(context: ?*anyopaque, flip: gpu.state.Flip) bool {
        const self = from(context);
        if (self.failure != null) return false;
        self.present(flip) catch |err| return self.rejected("presentation", err);
        return true;
    }
    const vtable = gpu.DcbBackend.VTable{
        .read = read,
        .write = write,
        .read_live = read,
        .read_wait = read,
        .dispatch = dispatchCallback,
        .draw = drawCallback,
        .flip = flipCallback,
    };

    pub fn dispatch(self: *Renderer, state: *const gpu.State, packet: gpu.pm4.Packet) !void {
        if (packet.opcode != gpu.pm4.dispatch_direct or packet.body.len < 3) return error.UnsupportedDispatchPacket;
        const local = [3]u32{
            @max(1, state.readRegister(.shader, 0x207) orelse 1),
            @max(1, state.readRegister(.shader, 0x208) orelse 1),
            @max(1, state.readRegister(.shader, 0x209) orelse 1),
        };
        if (local[0] > 1024 or local[1] > 1024 or local[2] > 64 or @as(u64, local[0]) * local[1] * local[2] > 1024) return error.UnsupportedWorkgroupSize;
        var groups = [3]u32{ packet.body[0], packet.body[1], packet.body[2] };
        const initiator = if (packet.body.len >= 4) packet.body[3] else 0;
        if (initiator & (1 << 5) != 0) for (&groups, local) |*dimension, size| {
            dimension.* = dimension.* / size + @intFromBool(dimension.* % size != 0);
        };
        for (groups) |size| if (size == 0) return;
        for (groups) |size| if (size > 65535) return error.UnsupportedDispatchSize;
        var bindings = try gpu.ShaderBindings.capture(state, .compute, null, self.reader());
        const system = gpu.resources.decodeComputeSystemRegisters(state);
        bindings.compute_dispatch = .{ .system = system, .group_count = groups, .local_size = local };
        var analysis = try gpu.shader_analysis.decode(self.allocator, self.reader(), bindings.program_address, 4096);
        defer analysis.deinit(self.allocator);
        var storage = Storage{ .allocator = self.allocator };
        defer storage.deinit();
        const unknown: gpu.scalar_provenance.ScalarRegisters = @splat(.{});
        for (analysis.program.instructions.items) |inst| {
            switch (inst.family) {
                .mimg => return error.SampledAndStorageImagesNotImplemented,
                .flat => return error.FlatMemoryNotImplemented,
                .smem => return error.ScalarMemoryBindingsNotImplemented,
                .ds => return error.WorkgroupMemoryNotImplemented,
                .mubuf, .mtbuf => {},
                else => continue,
            }
            var resolver = gpu.scalar_resources.Resolver{ .bindings = &bindings, .reader = self.reader(), .instructions = analysis.program.instructions.items, .graph = &analysis.graph, .snapshot = &unknown };
            var words: [4]u32 = undefined;
            if (!try resolver.words(inst.src1.reg, inst.pc, &words)) return error.DynamicBufferDescriptorNotImplemented;
            const descriptor = try gpu.resources.decodeBufferDescriptor(&words);
            // OOB_SELECT=2 has special zero-stride extent rules; do not assume
            // that its NUM_RECORDS field bounds the allocation.
            if (descriptor.out_of_bounds_select == 2 or descriptor.address == 0 or descriptor.size_bytes == 0) return error.UnsupportedBufferDescriptor;
            const name = @tagName(inst.opcode);
            const writable = std.mem.indexOf(u8, name, "store") != null or std.mem.indexOf(u8, name, "atomic") != null;
            const slot = try storage.stage(self.memory, descriptor.address, descriptor.size_bytes, writable);
            try storage.mappings.append(self.allocator, .{
                .resource_sgpr = inst.src1.reg,
                .instruction_pc = inst.pc,
                .descriptor_index = slot,
                .stride = descriptor.stride,
                .swizzled = descriptor.swizzle_enabled,
                .index_stride = descriptor.index_stride,
                .add_thread_id = descriptor.add_thread_id,
                .unified_format = descriptor.unified_format,
                .dst_select = descriptor.dst_select,
                .extent_bytes = @intCast(descriptor.size_bytes),
            });
        }
        var scalar: [64]rdna2.spirv.ScalarRegister = undefined;
        const scalar_count = entryScalars(bindings, &scalar);
        var module = try analysis.translateSpirv(self.allocator, .{
            .stage = .compute,
            .program_address = bindings.program_address,
            .local_size = local,
            .wave32 = initiator & (1 << 15) != 0,
            .compute_inputs = .{ .workgroup_id_sgprs = system.workgroup_id_sgprs, .threadgroup_size_sgpr = system.threadgroup_size_sgpr, .local_invocation_id_components = system.local_invocation_id_components },
            .scalar_registers = scalar[0..scalar_count],
            .storage_buffers = storage.mappings.items,
            .descriptor_array_length = @intCast(@max(1, storage.count)),
            .allow_control_flow_fallback = false,
        });
        defer module.deinit(self.allocator);
        if (module.used_dispatcher or module.used_control_flow_fallback) return error.UnboundedControlFlowNotImplemented;
        var native_buffers: [64]native.Buffer = undefined;
        for (storage.data[0..storage.count], native_buffers[0..storage.count]) |bytes, *buffer| buffer.* = native.Buffer.fromSlice(bytes);
        try self.device.dispatchSpirv(module.words, native_buffers[0..storage.count], groups);
        for (0..storage.count) |i| {
            if (storage.writable[i] and !self.memory.write(self.memory.context, storage.addresses[i], storage.data[i][0..storage.sizes[i]])) return error.GuestWriteFailed;
        }
    }

    pub fn draw(self: *Renderer, state: *const gpu.State, packet: gpu.pm4.Packet) !void {
        if (packet.opcode != gpu.pm4.draw_index_auto or packet.body.len < 1) return error.IndexedAndIndirectDrawNotImplemented;
        if (packet.body[0] == 0 or state.instance_count == 0) return;
        for ([_]gpu.resources.ShaderStage{ .export_shader, .geometry, .hull }) |stage| {
            if (stage.programAddress(state) != null) return error.AdvancedGraphicsStagesNotImplemented;
        }
        const render = gpu.resources.decodeRenderState(state);
        const target = render.color_targets[0] orelse return error.MissingColorTarget;
        if (render.color_count != 1 or render.depth_control.test_enabled or render.depth_control.write_enabled or render.depth_control.stencil_enabled or render.depth_control.clear_enabled or render.depth_control.stencil_clear_enabled or render.blends[0].enabled) return error.DepthBlendAndMultipleTargetsNotImplemented;
        if (target.format != 10 or target.number_type != 0 or target.component_swap != 0 or target.tile_mode != .linear or target.samples_log2 != 0 or target.fragments_log2 != 0 or target.mip_level != 0 or target.base_array_slice != 0 or target.last_array_slice != 0 or target.dcc_enabled or target.cmask_fast_clear or target.force_destination_alpha_one) return error.UnsupportedRenderTargetLayout;
        if (render.color_control.isMetadataOperation() or (state.readRegister(.context, 0x202) != null and !render.color_control.allowsAttachmentWrites(render.target_mask)) or render.color_control.logic_operation != 0xcc) return error.ColorMetadataAndLogicOpsNotImplemented;
        if (render.raster.rasterizer_discard or render.raster.polygon_mode != 0 or render.raster.depth_bias_front or render.raster.depth_bias_back or (render.raster.cull_front and render.raster.cull_back)) return error.UnsupportedRasterState;
        if (render.primitive_type != 4 and render.primitive_type != 5) return error.UnsupportedPrimitive;
        var draw_state = try native.Draw.fullTarget(target.width, target.height);
        draw_state.vertex_count = packet.body[0];
        draw_state.instance_count = state.instance_count;
        draw_state.first_vertex = state.readRegister(.uconfig, 0x24a) orelse 0;
        draw_state.topology = render.primitive_type;
        draw_state.cull_mode = if (render.raster.cull_front) 2 else if (render.raster.cull_back) 3 else 1;
        draw_state.front_ccw = @intFromBool(!render.raster.clockwise_front_face);
        draw_state.write_mask = target.write_mask & (render.shader_mask & 0xf);
        if (render.viewport) |vp| {
            if (vp.x_scale <= 0 or vp.y_scale >= 0) return error.PositiveYOrMirroredViewportNotImplemented;
            draw_state.viewport = .{ vp.x_offset - vp.x_scale, vp.y_offset + vp.y_scale, vp.x_scale * 2, -vp.y_scale * 2, if (render.raster.zero_to_one_depth) vp.z_offset else vp.z_offset - vp.z_scale, vp.z_offset + vp.z_scale };
        }
        if (render.scissor) |scissor| draw_state.scissor = .{ scissor.left, scissor.top, scissor.right, scissor.bottom };
        const vs_bindings = try gpu.ShaderBindings.capture(state, .vertex, null, self.reader());
        const ps_bindings = try gpu.ShaderBindings.capture(state, .pixel, null, self.reader());
        var vs = try gpu.shader_analysis.decode(self.allocator, self.reader(), vs_bindings.program_address, 4096);
        defer vs.deinit(self.allocator);
        var ps = try gpu.shader_analysis.decode(self.allocator, self.reader(), ps_bindings.program_address, 4096);
        defer ps.deinit(self.allocator);
        // Stage resources need a shared descriptor layout and are the next
        // porting step. Reject them before GPU submission or target writes.
        for ([_]*const gpu.ShaderAnalysis{ &vs, &ps }) |analysis| for (analysis.program.instructions.items) |inst| switch (inst.family) {
            .mimg, .mubuf, .mtbuf, .flat, .smem, .ds => return error.GraphicsResourceBindingsNotImplemented,
            .vintrp => return error.FragmentVaryingInterfaceNotImplemented,
            else => {},
        };
        var vs_scalar: [64]rdna2.spirv.ScalarRegister = undefined;
        var ps_scalar: [64]rdna2.spirv.ScalarRegister = undefined;
        var vertex = try vs.translateSpirv(self.allocator, .{ .stage = .vertex, .program_address = vs_bindings.program_address, .vertex_index_vgpr = 5, .convert_negative_one_to_one_depth = !render.raster.zero_to_one_depth, .scalar_registers = vs_scalar[0..entryScalars(vs_bindings, &vs_scalar)], .allow_control_flow_fallback = false });
        defer vertex.deinit(self.allocator);
        var fragment = try ps.translateSpirv(self.allocator, .{ .stage = .fragment, .program_address = ps_bindings.program_address, .fragment_extent = .{ target.width, target.height }, .scalar_registers = ps_scalar[0..entryScalars(ps_bindings, &ps_scalar)], .allow_control_flow_fallback = false });
        defer fragment.deinit(self.allocator);
        if (vertex.used_dispatcher or fragment.used_dispatcher) return error.UnboundedControlFlowNotImplemented;
        const pixels = try self.readLinear(target.address, target.width, target.height, target.pitch);
        defer self.allocator.free(pixels);
        try self.device.drawSpirv(vertex.words, fragment.words, draw_state, pixels);
        try self.writeLinear(target.address, target.width, target.height, target.pitch, pixels);
    }

    fn readLinear(self: *Renderer, address: u64, width: u32, height: u32, pitch: u32) ![]u8 {
        const bytes = try native.rgbaSize(width, height);
        if (pitch < width or pitch > 16384) return error.InvalidPitch;
        const pixels = try self.allocator.alloc(u8, bytes);
        errdefer self.allocator.free(pixels);
        for (0..height) |y| {
            const row_address = try std.math.add(u64, address, @as(u64, y) * pitch * 4);
            if (!self.memory.read(self.memory.context, row_address, pixels[y * width * 4 ..][0 .. width * 4])) return error.GuestReadFailed;
        }
        return pixels;
    }
    fn writeLinear(self: *Renderer, address: u64, width: u32, height: u32, pitch: u32, pixels: []const u8) !void {
        for (0..height) |y| {
            const row_address = try std.math.add(u64, address, @as(u64, y) * pitch * 4);
            if (!self.memory.write(self.memory.context, row_address, pixels[y * width * 4 ..][0 .. width * 4])) return error.GuestWriteFailed;
        }
    }
    pub fn present(self: *Renderer, flip: gpu.state.Flip) !void {
        const resolve = self.display_resolver orelse return error.DisplayResolverUnavailable;
        const display = resolve(flip) orelse return error.DisplayBufferUnavailable;
        if (display.tiling_mode != 1 or (display.pixel_format != 0 and display.pixel_format != 0x8000000000000000)) return error.UnsupportedScanoutLayout;
        const pixels = try self.readLinear(display.address, display.width, display.height, display.pitch_in_pixels);
        defer self.allocator.free(pixels);
        if (display.pixel_format == 0x8000000000000000) {
            var offset: usize = 0;
            while (offset < pixels.len) : (offset += 4) std.mem.swap(u8, &pixels[offset], &pixels[offset + 2]);
        }
        try self.device.presentRgba(pixels, display.width, display.height);
        const now = gpu.frame_timing.timestampNs();
        if (self.frame_started_ns == 0) self.frame_started_ns = now;
        self.frames +|= 1;
        const elapsed = now -| self.frame_started_ns;
        if (elapsed >= std.time.ns_per_s) {
            if (self.fps_update) |update| update(self.fps_context, @intCast(@min(std.math.maxInt(u32), @as(u64, self.frames) * 10 * std.time.ns_per_s / elapsed)));
            self.frames = 0;
            self.frame_started_ns = now;
        }
    }
};

fn entryScalars(bindings: gpu.ShaderBindings, output: *[64]rdna2.spirv.ScalarRegister) usize {
    for (bindings.user_data[0..bindings.user_data_count], 0..) |value, index| output[index] = .{ .register = @as(u32, @intCast(index)) + bindings.scalar_user_data_base, .value = value };
    return bindings.user_data_count;
}

const Storage = struct {
    allocator: std.mem.Allocator,
    data: [64][]u8 = undefined,
    addresses: [64]u64 = undefined,
    sizes: [64]usize = undefined,
    writable: [64]bool = undefined,
    count: usize = 0,
    total: u64 = 0,
    mappings: std.ArrayList(rdna2.spirv.StorageBufferBinding) = .empty,

    fn deinit(self: *Storage) void {
        for (self.data[0..self.count]) |bytes| self.allocator.free(bytes);
        self.mappings.deinit(self.allocator);
    }
    fn stage(self: *Storage, memory: Memory, address: u64, size: u64, writable: bool) !u32 {
        const end = try std.math.add(u64, address, size);
        for (0..self.count) |i| {
            if (address == self.addresses[i] and size == self.sizes[i]) {
                self.writable[i] = self.writable[i] or writable;
                return @intCast(i);
            }
            if (address < self.addresses[i] + self.sizes[i] and self.addresses[i] < end) return error.OverlappingBufferViewsNotImplemented;
        }
        if (size == 0 or size > 256 * 1024 * 1024 or self.total + size > 256 * 1024 * 1024 or self.count == self.data.len) return error.StorageBudgetExceeded;
        const bytes = try self.allocator.alloc(u8, std.mem.alignForward(usize, @intCast(size), 4));
        errdefer self.allocator.free(bytes);
        @memset(bytes, 0);
        if (!memory.read(memory.context, address, bytes[0..@intCast(size)])) return error.GuestReadFailed;
        const slot = self.count;
        self.data[slot] = bytes;
        self.addresses[slot] = address;
        self.sizes[slot] = @intCast(size);
        self.writable[slot] = writable;
        self.count += 1;
        self.total += size;
        return @intCast(slot);
    }
};
