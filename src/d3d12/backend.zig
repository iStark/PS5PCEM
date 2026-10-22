// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Initial native PM4 backend. Work completes before guest memory and release
//! labels become visible. Unsupported state rejects the submission; it never
//! delegates rendering to Vulkan or acknowledges a skipped draw as complete.
const std = @import("std");
const gpu = @import("gpu");
const rdna2 = @import("rdna2");
const native = @import("root.zig");
const graphics = @import("graphics.zig");
const surfaces = @import("surfaces.zig");
const resources = @import("resources.zig");
const staging = @import("staging.zig");
const surface_cache = @import("surface_cache.zig");
const shader_cache = @import("shader_cache.zig");
const texture_cache = @import("texture_cache.zig");
const translation_cache = rdna2.translation_cache;

comptime {
    // native.c binds the GDS block by this SPIR-V binding (PS5_GDS_BINDING).
    std.debug.assert(rdna2.spirv.gds_descriptor_binding == 38);
}

pub const Memory = struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, []u8) bool,
    write: *const fn (?*anyopaque, u64, []const u8) bool,
    track_gpu_read: ?*const fn (?*anyopaque, u64, usize) u64 = null,
    gpu_generation: ?*const fn (?*anyopaque, u64, usize) u64 = null,
};
pub const DisplayBuffer = struct {
    address: u64,
    width: u32,
    height: u32,
    pitch_in_pixels: u32,
    tiling_mode: u32,
    pixel_format: u64,
};
const TargetKey = struct { address: u64, layout: gpu.SurfaceLayout };
const PreparedDraw = struct {
    draw: native.Draw,
    indices: []u8,
    resources: resources.DrawResources,
    vertex: translation_cache.Lease,
    fragment: translation_cache.Lease,
    fn deinit(self: *PreparedDraw, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
        self.resources.deinit();
        self.vertex.release();
        self.fragment.release();
    }
};
const PendingDraws = struct {
    color: surfaces.Staged,
    depth: ?surfaces.Staged,
    color_key: TargetKey,
    depth_key: ?TargetKey,
    draws: [native.max_draw_batch]PreparedDraw = undefined,
    count: usize = 0,
    bytes: usize = 0,
    image_budget: resources.ImageBudget = .{},
    depth_write: bool = false,
    fn deinit(self: *PendingDraws, allocator: std.mem.Allocator) void {
        for (self.draws[0..self.count]) |*draw| draw.deinit(allocator);
        self.color.deinit();
        if (self.depth) |*depth| depth.deinit();
    }
    fn overlaps(self: *const PendingDraws, address: u64, size: usize) bool {
        if (size == 0) return false;
        const end = address +| size;
        if (address < self.color.address + self.color.backing.len and self.color.address < end) return true;
        // The pending flush also rewrites the colour target's DCC keys.
        if (self.color.dcc) |dcc| {
            const keys = std.math.divCeil(usize, self.color.backing.len, surfaces.Dcc.block_bytes) catch unreachable;
            if (address < dcc.address + keys and dcc.address < end) return true;
        }
        if (self.depth) |depth| if (address < depth.address + depth.backing.len and depth.address < end) return true;
        return false;
    }
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    device: native.Device,
    staging_pool: staging.Pool,
    conversion_cache: surface_cache.Cache,
    shader_analyses: shader_cache.Cache = .{},
    textures: texture_cache.Cache = .{},
    translations: translation_cache.Cache = .{ .maximum_bytes = 32 * 1024 * 1024, .maximum_entries = 256 },
    memory: Memory,
    failure: ?anyerror = null,
    on_failure: ?*const fn (anyerror) void = null,
    display_resolver: ?*const fn (gpu.state.Flip) ?DisplayBuffer = null,
    fps_context: ?*anyopaque = null,
    fps_update: ?*const fn (?*anyopaque, u32) void = null,
    frames: u32 = 0,
    frame_started_ns: u64 = 0,
    cache_report_ns: u64 = 0,
    presented_frames: u64 = 0,
    // One retains the immediate API contract for direct users. The runner can
    // opt into bounded grouping; no guest bytes are used as a validity stamp.
    draw_batch_limit: usize = 1,
    pending_draws: ?PendingDraws = null,
    batch_groups: u64 = 0,
    batch_draws: u64 = 0,
    batch_hazards: u64 = 0,
    /// Persistent 64 KiB global data share, allocated by the first GDS dispatch.
    gds: ?[]u8 = null,
    const draw_batch_bytes = 128 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator, memory: Memory, debug: bool) !Renderer {
        return .{ .allocator = allocator, .memory = memory, .device = try native.Device.init(debug), .staging_pool = .{ .allocator = allocator }, .conversion_cache = .{ .allocator = allocator } };
    }
    pub fn deinit(self: *Renderer) void {
        // Teardown does not publish unfinished work or acknowledge its labels.
        if (self.pending_draws) |*pending| pending.deinit(self.allocator);
        if (self.gds) |gds| self.allocator.free(gds);
        self.translations.deinit(self.allocator);
        self.shader_analyses.deinit();
        self.textures.deinit();
        self.device.deinit();
        self.conversion_cache.deinit();
        self.staging_pool.deinit();
        self.* = undefined;
    }
    pub fn dcbBackend(self: *Renderer) gpu.DcbBackend {
        return .{ .context = self, .vtable = &vtable };
    }
    fn reader(self: *Renderer) gpu.ShaderMemoryReader {
        return .{ .context = self, .read_fn = read };
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
        if (self.failure != null) return false;
        if (self.pending_draws) |*pending| if (pending.overlaps(address, bytes.len)) {
            self.batch_hazards += 1;
            self.flushDraws() catch |err| return self.rejected("draw dependency", err);
        };
        return self.memory.read(self.memory.context, address, bytes);
    }
    fn textureGeneration(context: ?*anyopaque, address: u64, size: usize) u64 {
        const self = from(context);
        // A cached read still observes every earlier overlapping GPU write.
        if (self.pending_draws) |*pending| if (pending.overlaps(address, size)) {
            self.batch_hazards += 1;
            self.flushDraws() catch |err| {
                _ = self.rejected("texture dependency", err);
                return 0;
            };
        };
        if (self.failure != null) return 0;
        return if (self.memory.gpu_generation) |callback| callback(self.memory.context, address, size) else 0;
    }
    fn trackTexture(context: ?*anyopaque, address: u64, size: usize) u64 {
        _ = textureGeneration(context, address, size);
        const self = from(context);
        if (self.failure != null) return 0;
        return if (self.memory.track_gpu_read) |callback| callback(self.memory.context, address, size) else 0;
    }
    fn write(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
        const self = from(context);
        if (!drain(context)) return false;
        return self.memory.write(self.memory.context, address, bytes);
    }
    fn readLive(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        if (!drain(context)) return false;
        const self = from(context);
        return self.memory.read(self.memory.context, address, bytes);
    }
    fn drain(context: ?*anyopaque) bool {
        const self = from(context);
        if (self.failure != null) return false;
        self.flushDraws() catch |err| return self.rejected("draw completion", err);
        return true;
    }
    fn acquire(context: ?*anyopaque, _: gpu.state.AcquireMem) bool {
        return drain(context);
    }
    fn event(context: ?*anyopaque, value: gpu.state.EventWrite) bool {
        // Non-addressed GPU cache/order events do not publish CPU-visible
        // results. Ordered RT draws and dependency reads preserve that order;
        // releases, addressed events and CPU observations still drain.
        if (value.address != null) return drain(context);
        return from(context).failure == null;
    }
    fn release(context: ?*anyopaque, value: gpu.state.ReleaseMem) bool {
        if (!drain(context)) return false;
        // Preserve the executor's existing immediate-value release semantics,
        // including releases that only carry an interrupt and no memory write.
        const self = from(context);
        if ((value.destination == 0 or value.destination == 1) and value.address != 0) {
            var data: [8]u8 = undefined;
            std.mem.writeInt(u64, &data, value.data, .little);
            const size: usize = switch (value.data_selection) {
                1 => 4,
                2 => 8,
                else => 0,
            };
            if (size != 0) return self.memory.write(self.memory.context, value.address, data[0..size]);
        }
        return true;
    }
    pub fn flushDraws(self: *Renderer) anyerror!void {
        if (self.failure) |err| return err;
        const pending = if (self.pending_draws) |*value| value else return;
        defer {
            pending.deinit(self.allocator);
            self.pending_draws = null;
        }
        var jobs: [native.max_draw_batch]native.DrawJob = undefined;
        for (pending.draws[0..pending.count], jobs[0..pending.count]) |*prepared, *job| job.* = .{
            .vertex = prepared.vertex.view().words,
            .fragment = prepared.fragment.view().words,
            .draw = prepared.draw,
            .indices = prepared.indices,
            .buffers = prepared.resources.buffers.items,
            .images = prepared.resources.images.items,
        };
        try self.device.drawBatchSpirv(jobs[0..pending.count], pending.color.pixels, if (pending.depth) |depth| depth.pixels else &.{});
        try pending.color.write(self.memory);
        if (pending.depth_write) if (pending.depth) |*depth| try depth.write(self.memory);
        self.batch_groups += 1;
        self.batch_draws += pending.count;
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
        self.draw(state, packet) catch |err| {
            self.reportDraw(state, packet);
            return self.rejected("draw", err);
        };
        return true;
    }
    fn reportDraw(self: *Renderer, state: *const gpu.State, packet: gpu.pm4.Packet) void {
        std.debug.print("[d3d12 draw] op=0x{x} body={any} stages=0x{x} gs_mode=0x{x} primitive={d}\n", .{
            packet.opcode,                                packet.body,                                  state.readRegister(.context, 0x2d5) orelse 0,
            state.readRegister(.context, 0x290) orelse 0, state.readRegister(.uconfig, 0x242) orelse 4,
        });
        const render = gpu.resources.decodeRenderState(state);
        std.debug.print("[d3d12 render] colors={d} depth_test={any} depth_write={any} stencil={any} blend={any}\n", .{
            render.color_count,                   render.depth_control.test_enabled, render.depth_control.write_enabled,
            render.depth_control.stencil_enabled, render.blends[0].enabled,
        });
        if (render.depth_target) |depth| std.debug.print("[d3d12 depth] target={any} control={any} viewport={any}\n", .{ depth, render.depth_control, render.viewport });
        std.debug.print("[d3d12 depth registers] clamp={any}/{any} clip={any} vte={any}\n", .{
            state.readRegister(.context, 0xb4),  state.readRegister(.context, 0xb5),
            state.readRegister(.context, 0x204), state.readRegister(.context, 0x206),
        });
        if (render.blends[0].enabled) std.debug.print("[d3d12 blend] control=0x{x} constants={any}\n", .{
            state.readRegister(.context, 0x1e0) orelse 0,
            native.blending.decode(state, render.blends[0]) catch null,
        });
        if (render.color_targets[0]) |target| std.debug.print("[d3d12 target] {d}x{d} pitch={d} format={d}/{d} tile={f} samples={d} fragments={d}\n", .{
            target.width, target.height, target.pitch, target.format, target.number_type, target.tile_mode, target.samples_log2, target.fragments_log2,
        });
        const active = graphics.routing(state) catch null;
        for ([_]gpu.resources.ShaderStage{ .vertex, .export_shader, .geometry, .hull, .pixel }) |stage| {
            if (active) |routing| if (stage != routing.stage and stage != .pixel) continue;
            const address = stage.programAddress(state) orelse continue;
            const bindings = gpu.ShaderBindings.capture(state, stage, null, self.reader()) catch continue;
            const bank = bindings.user_data_stage;
            std.debug.print("[d3d12 shader] stage={s} user_bank={s} address=0x{x} rsrc1=0x{x} rsrc2=0x{x}\n", .{
                @tagName(stage),                                               @tagName(bank), address, state.readRegister(.shader, bank.userDataBase() - 2) orelse 0,
                state.readRegister(.shader, bank.userDataBase() - 1) orelse 0,
            });
            var analysis = gpu.shader_analysis.decode(self.allocator, self.reader(), address, 4096) catch |err| {
                std.debug.print("[d3d12 shader] decode failed: {s}\n", .{@errorName(err)});
                continue;
            };
            defer analysis.deinit(self.allocator);
            for (analysis.program.instructions.items[0..@min(32, analysis.program.instructions.items.len)]) |inst| {
                std.debug.print("  0x{x}: {s} dst={s}{d} src={s}{d},{s}{d}\n", .{
                    inst.pc,                  @tagName(inst.opcode), @tagName(inst.dst.kind),  inst.dst.reg,
                    @tagName(inst.src0.kind), inst.src0.reg,         @tagName(inst.src1.kind), inst.src1.reg,
                });
            }
        }
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
        .read_live = readLive,
        .read_wait = readLive,
        .drain_releases = drain,
        .acquire = acquire,
        .release = release,
        .event = event,
        .dispatch = dispatchCallback,
        .draw = drawCallback,
        .flip = flipCallback,
    };

    pub fn dispatch(self: *Renderer, state: *const gpu.State, packet: gpu.pm4.Packet) !void {
        try self.flushDraws();
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
        const analysis_lease = try self.shader_analyses.acquire(self.allocator, self.reader(), bindings.program_address);
        defer analysis_lease.release();
        const analysis = analysis_lease.view();
        var storage = Storage{ .allocator = self.allocator };
        defer storage.deinit();
        const unknown: gpu.scalar_provenance.ScalarRegisters = @splat(.{});
        // COMPUTE_PGM_RSRC2.LDS_SIZE counts 128-dword (512-byte) granules.
        const lds_bytes = ((state.readRegister(.shader, 0x213) orelse 0) >> 15 & 0x1ff) * 512;
        var uses_gds = false;
        for (analysis.program.instructions.items) |inst| {
            var resolver = gpu.scalar_resources.Resolver{ .bindings = &bindings, .reader = self.reader(), .instructions = analysis.program.instructions.items, .graph = &analysis.graph, .snapshot = &unknown };
            switch (inst.family) {
                .mimg => return error.SampledAndStorageImagesNotImplemented,
                .flat => return error.FlatMemoryNotImplemented,
                .smem => {
                    try storage.stageScalar(self.memory, &resolver, inst);
                    continue;
                },
                .ds => {
                    // The persistent GDS is a separate UAV after the storage
                    // array. Workgroup LDS must fit D3D12's 32 KiB groupshared.
                    if (inst.gds) {
                        uses_gds = true;
                    } else if (lds_bytes == 0 or lds_bytes > 32 * 1024) return error.WorkgroupMemoryNotImplemented;
                    continue;
                },
                .mubuf, .mtbuf => {},
                else => continue,
            }
            var words: [4]u32 = undefined;
            if (!try resolver.words(inst.src1.reg, inst.pc, &words)) return error.DynamicBufferDescriptorNotImplemented;
            const descriptor = try gpu.resources.decodeBufferDescriptor(&words);
            // OOB_SELECT=2 has special zero-stride extent rules; do not assume
            // that its NUM_RECORDS field bounds the allocation.
            if (descriptor.out_of_bounds_select == 2 or descriptor.address == 0 or descriptor.size_bytes == 0) return error.UnsupportedBufferDescriptor;
            const name = @tagName(inst.opcode);
            const writable = std.mem.indexOf(u8, name, "store") != null or std.mem.indexOf(u8, name, "atomic") != null;
            const slot = try storage.stage(self.memory, descriptor.address, descriptor.size_bytes, writable, false);
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
        const module_lease = try self.translations.acquirePrepared(self.allocator, &analysis.program, .{
            .stage = .compute,
            .program_address = bindings.program_address,
            .local_size = local,
            .wave32 = initiator & (1 << 15) != 0,
            .scalarize_ballot_first = true,
            .compute_inputs = .{ .workgroup_id_sgprs = system.workgroup_id_sgprs, .threadgroup_size_sgpr = system.threadgroup_size_sgpr, .local_invocation_id_components = system.local_invocation_id_components },
            .scalar_registers = scalar[0..scalar_count],
            .storage_buffers = storage.mappings.items,
            .scalar_memories = storage.pointers.items,
            .descriptor_array_length = @intCast(@max(1, storage.count)),
            .workgroup_memory_size_bytes = lds_bytes,
            .gds_storage = uses_gds,
            .allow_control_flow_fallback = false,
        }, analysis.pipeline_options, analysis.translation_key);
        defer module_lease.release();
        const module = module_lease.view();
        if (module.used_dispatcher or module.used_control_flow_fallback) return error.UnboundedControlFlowNotImplemented;
        var native_buffers: [65]native.Buffer = undefined;
        for (storage.data[0..storage.count], native_buffers[0..storage.count]) |bytes, *buffer| buffer.* = native.Buffer.fromSlice(bytes);
        var buffer_count = storage.count;
        if (uses_gds) {
            // GDS persists across dispatches like the console's global data
            // share; the native readback writes straight into this copy.
            if (self.gds == null) {
                const gds = try self.allocator.alloc(u8, 64 * 1024);
                @memset(gds, 0);
                self.gds = gds;
            }
            native_buffers[buffer_count] = native.Buffer.fromSlice(self.gds.?);
            buffer_count += 1;
        }
        try self.device.dispatchSpirv(module.words, native_buffers[0..buffer_count], groups, uses_gds);
        for (0..storage.count) |i| {
            if (storage.writable[i] and !self.memory.write(self.memory.context, storage.addresses[i], storage.data[i][0..storage.sizes[i]])) return error.GuestWriteFailed;
        }
    }

    pub fn draw(self: *Renderer, state: *const gpu.State, packet: gpu.pm4.Packet) !void {
        const args = try DrawArguments.decode(state, packet);
        if (args.count == 0 or state.instance_count == 0) return;
        const routing = try graphics.routing(state);
        const render = gpu.resources.decodeRenderState(state);
        const target = render.color_targets[0] orelse return error.MissingColorTarget;
        if (render.color_count != 1) return error.MultipleTargetsNotImplemented;
        if (render.depth_control.stencil_enabled or render.depth_control.clear_enabled or render.depth_control.stencil_clear_enabled or
            (state.readRegister(.context, 0x200) orelse 0) & (1 << 3) != 0) return error.DepthClearStencilAndBoundsNotImplemented;
        const target_layout = try surfaces.colorLayout(target);
        if (render.color_control.isMetadataOperation() or (state.readRegister(.context, 0x202) != null and !render.color_control.allowsAttachmentWrites(render.target_mask)) or render.color_control.logic_operation != 0xcc) return error.ColorMetadataAndLogicOpsNotImplemented;
        if (render.raster.rasterizer_discard or render.raster.polygon_mode != 0 or render.raster.depth_bias_front or render.raster.depth_bias_back or (render.raster.cull_front and render.raster.cull_back)) return error.UnsupportedRasterState;
        const topology = try graphics.nativeTopology(render.primitive_type);
        var draw_state = try native.Draw.fullTarget(target.width, target.height);
        var depth_key: ?TargetKey = null;
        // A test that always passes and never writes cannot change a pixel:
        // stencil and depth bounds were rejected above. It needs no depth
        // attachment, so its HTILE state is irrelevant.
        const depth_active = render.depth_control.test_enabled and
            !(render.depth_control.compare_function == 7 and !render.depth_control.write_enabled);
        if (depth_active) {
            const depth = render.depth_target orelse return error.MissingDepthTarget;
            const writable = render.depth_control.write_enabled and !depth.depth_read_only;
            const layout = try surfaces.depthLayout(depth, target.width, target.height, writable);
            const color_end = try std.math.add(u64, target.address, target_layout.required_source_bytes);
            const depth_end = try std.math.add(u64, depth.read_address, layout.required_source_bytes);
            if (depth.read_address < color_end and target.address < depth_end) return error.DepthColorAliasNotImplemented;
            draw_state.depth_format = if (depth.format == 1) 55 else 40;
            draw_state.depth_write = @intFromBool(writable);
            draw_state.depth_compare = @as(u32, render.depth_control.compare_function) + 1;
            depth_key = .{ .address = depth.read_address, .layout = layout };
        }
        draw_state.blend = try native.blending.decode(state, render.blends[0]);
        draw_state.vertex_count = if (args.index_bytes == 0) args.count else 0;
        draw_state.instance_count = state.instance_count;
        draw_state.first_vertex = state.readRegister(.uconfig, 0x24a) orelse 0;
        draw_state.topology = topology;
        var queued = false;
        const indices = try args.stage(self.allocator, .{ .context = self, .read = read, .write = write }, state, &draw_state, render.primitive_type);
        defer if (!queued) self.allocator.free(indices);
        if (render.primitive_type == 5 and indices.len == 0) return;
        draw_state.cull_mode = if (render.raster.cull_front) 2 else if (render.raster.cull_back) 3 else 1;
        draw_state.front_ccw = @intFromBool(!render.raster.clockwise_front_face);
        draw_state.write_mask = target.write_mask & (render.shader_mask & 0xf);
        var depth_transform: ?rdna2.spirv.VertexDepthTransform = null;
        if (render.viewport) |vp| {
            if (vp.x_scale <= 0 or vp.y_scale >= 0) return error.PositiveYOrMirroredViewportNotImplemented;
            const position_z_enabled = ((state.readRegister(.context, 0x1b4) orelse 0) & (state.readRegister(.context, 0x1b3) orelse 0)) & (1 << 10) != 0;
            const depth = try graphics.viewportDepth(state, vp, render.raster.zero_to_one_depth, depth_active, position_z_enabled);
            depth_transform = depth.transform;
            draw_state.depth_clip_enabled = @intFromBool(depth_transform == null);
            draw_state.viewport = .{ vp.x_offset - vp.x_scale, vp.y_offset + vp.y_scale, vp.x_scale * 2, -vp.y_scale * 2, depth.range[0], depth.range[1] };
        }
        if (render.scissor) |scissor| draw_state.scissor = .{ scissor.left, scissor.top, scissor.right, scissor.bottom };
        const vs_bindings = try gpu.ShaderBindings.capture(state, routing.stage, null, self.reader());
        const ps_bindings = try gpu.ShaderBindings.capture(state, .pixel, null, self.reader());
        const vs_lease = try self.shader_analyses.acquire(self.allocator, self.reader(), vs_bindings.program_address);
        defer vs_lease.release();
        const ps_lease = try self.shader_analyses.acquire(self.allocator, self.reader(), ps_bindings.program_address);
        defer ps_lease.release();
        const vs = vs_lease.view();
        const ps = ps_lease.view();
        const interface = try graphics.linkInterface(state, vs.program.instructions.items, ps.program.instructions.items);
        var draw_resources = resources.DrawResources{
            .allocator = self.allocator,
            .reader = self.reader(),
            .pool = &self.staging_pool,
            .cache = &self.conversion_cache,
            .textures = &self.textures,
            .tracking = .{ .context = self, .generation = textureGeneration, .arm = trackTexture },
        };
        defer if (!queued) draw_resources.deinit();
        var vs_resources = try draw_resources.capture(&vs_bindings, vs);
        defer vs_resources.deinit(self.allocator);
        var ps_resources = try draw_resources.capture(&ps_bindings, ps);
        defer ps_resources.deinit(self.allocator);
        var vs_scalar: [65]rdna2.spirv.ScalarRegister = undefined;
        var ps_scalar: [64]rdna2.spirv.ScalarRegister = undefined;
        var vs_scalar_count = entryScalars(vs_bindings, &vs_scalar);
        if (routing.stage == .export_shader) {
            // NGG USER_DATA comes from the GS bank at s8. s3 contains the
            // live ES/GS counts; it must not receive USER_DATA[3] or zero.
            // The shared vertex lowering handles one live vertex per host
            // invocation and uses full-wave counts for the merged prologue.
            vs_scalar[vs_scalar_count] = .{ .register = 3, .value = if (routing.vertex_wave32) 0x2020 else 0x4040 };
            vs_scalar_count += 1;
        }
        const ps_scalar_count = entryScalars(ps_bindings, &ps_scalar);
        draw_state.dynamic_scalars = 1;
        for (vs_scalar[0..vs_scalar_count], 0..) |scalar, i| draw_state.scalar_values[i] = scalar.value;
        for (ps_scalar[0..ps_scalar_count], 0..) |scalar, i| draw_state.scalar_values[65 + i] = scalar.value;
        const vertex = try self.translations.acquirePrepared(self.allocator, &vs.program, .{
            .stage = .vertex,
            .wave32 = routing.vertex_wave32,
            .scalarize_ballot_first = true,
            .program_address = vs_bindings.program_address,
            .vertex_index_vgpr = 5,
            .convert_negative_one_to_one_depth = !render.raster.zero_to_one_depth and depth_transform == null,
            .vertex_depth_transform = depth_transform,
            .scalar_registers = vs_scalar[0..vs_scalar_count],
            .dynamic_scalar_binding = .{ .binding = 10 },
            .allow_control_flow_fallback = false,
            .parameter_mask = interface.mask,
            .vertex_parameter_sources = &interface.controls,
            .storage_buffers = vs_resources.buffers.items,
            .scalar_memories = vs_resources.pointers.items,
            .sampled_images = vs_resources.images.items,
            .descriptor_array_length = @intCast(@max(1, draw_resources.buffers.items.len)),
            .sampled_image_array_length = @intCast(@max(1, draw_resources.images.items.len)),
        }, vs.pipeline_options, vs.translation_key);
        defer if (!queued) vertex.release();
        const fragment = try self.translations.acquirePrepared(self.allocator, &ps.program, .{
            .stage = .fragment,
            .wave32 = routing.fragment_wave32,
            .scalarize_ballot_first = true,
            .program_address = ps_bindings.program_address,
            .fragment_extent = .{ target.width, target.height },
            .scalar_registers = ps_scalar[0..ps_scalar_count],
            .dynamic_scalar_binding = .{ .binding = 10, .value_base = 65 },
            .allow_control_flow_fallback = false,
            .parameter_mask = interface.mask,
            .fragment_input_controls = &interface.controls,
            .fragment_input_locations = &interface.locations,
            .infer_fragment_parameter_mask = false,
            .storage_buffers = ps_resources.buffers.items,
            .scalar_memories = ps_resources.pointers.items,
            .sampled_images = ps_resources.images.items,
            .descriptor_array_length = @intCast(@max(1, draw_resources.buffers.items.len)),
            .sampled_image_array_length = @intCast(@max(1, draw_resources.images.items.len)),
            .fragment_inputs = .{
                .allocated = @truncate(state.readRegister(.context, 0x1b4) orelse 0),
                .enabled = @truncate(state.readRegister(.context, 0x1b3) orelse 0),
                .front_face_all_bits = ((state.readRegister(.context, 0x1b8) orelse 0) & (1 << 24)) != 0,
            },
        }, ps.pipeline_options, ps.translation_key);
        defer if (!queued) fragment.release();
        if (vertex.view().used_dispatcher or fragment.view().used_dispatcher) return error.UnboundedControlFlowNotImplemented;
        const color_key = TargetKey{ .address = target.address, .layout = target_layout };
        const owned_bytes = draw_resources.total + indices.len + 4 * (vertex.view().words.len + fragment.view().words.len);
        if (self.pending_draws) |*pending| {
            const additional = pending.image_budget.additional(owned_bytes, draw_resources.images.items);
            if (!std.meta.eql(pending.color_key, color_key) or !std.meta.eql(pending.depth_key, depth_key) or
                pending.count >= @min(native.max_draw_batch, @max(1, self.draw_batch_limit)) or
                pending.bytes + additional > draw_batch_bytes) try self.flushDraws();
        }
        if (self.pending_draws == null) {
            var color = try surfaces.Staged.readColor(self.allocator, &self.staging_pool, &self.conversion_cache, self.memory, target.address, target_layout, surfaces.colorDcc(target));
            errdefer color.deinit();
            var depth: ?surfaces.Staged = null;
            if (depth_key) |key| depth = try surfaces.Staged.readCached(self.allocator, &self.staging_pool, &self.conversion_cache, self.memory, key.address, key.layout);
            self.pending_draws = .{ .color = color, .depth = depth, .color_key = color_key, .depth_key = depth_key };
        }
        const pending = &self.pending_draws.?;
        pending.bytes += pending.image_budget.additional(owned_bytes, draw_resources.images.items);
        pending.image_budget.append(draw_resources.images.items);
        pending.draws[pending.count] = .{ .draw = draw_state, .indices = indices, .resources = draw_resources, .vertex = vertex, .fragment = fragment };
        pending.count += 1;
        pending.depth_write = pending.depth_write or draw_state.depth_write != 0;
        queued = true;
        if (pending.count >= @min(native.max_draw_batch, @max(1, self.draw_batch_limit)) or pending.bytes >= draw_batch_bytes) try self.flushDraws();
    }

    pub fn present(self: *Renderer, flip: gpu.state.Flip) !void {
        try self.flushDraws();
        const resolve = self.display_resolver orelse return error.DisplayResolverUnavailable;
        const display = resolve(flip) orelse return error.DisplayBufferUnavailable;
        errdefer std.debug.print("[d3d12 scanout] rejected buffer={any}\n", .{display});
        const swap_red_blue = try surfaces.scanoutSwapsRedBlue(display.pixel_format);
        const layout = try surfaces.scanoutLayout(display.width, display.height, display.pitch_in_pixels, display.tiling_mode);
        var surface = try surfaces.Staged.readCached(self.allocator, &self.staging_pool, &self.conversion_cache, self.memory, display.address, layout);
        defer surface.deinit();
        const pixels = surface.pixels;
        if (swap_red_blue) {
            var offset: usize = 0;
            while (offset < pixels.len) : (offset += 4) std.mem.swap(u8, &pixels[offset], &pixels[offset + 2]);
        }
        try self.device.presentRgba(pixels, display.width, display.height);
        if (self.frame_started_ns == 0) std.debug.print("[d3d12] first frame presented: {d}x{d} format=0x{x} tile={d}\n", .{
            display.width, display.height, display.pixel_format, display.tiling_mode,
        });
        const now = gpu.frame_timing.timestampNs();
        self.presented_frames +|= 1;
        if (self.cache_report_ns == 0 or now -| self.cache_report_ns >= 5 * std.time.ns_per_s) {
            std.debug.print("[d3d12 textures] flip={d} page={d} content={d} miss={d} evict={d} kib={d}\n", .{
                self.presented_frames, self.textures.page_hits, self.textures.content_hits, self.textures.misses, self.textures.evictions, self.textures.bytes / 1024,
            });
            std.debug.print("[d3d12 batches] flip={d} limit={d} draws={d} groups={d} hazards={d}\n", .{
                self.presented_frames, self.draw_batch_limit, self.batch_draws, self.batch_groups, self.batch_hazards,
            });
            std.debug.print("[d3d12 guest shaders] flip={d} analysis={d}/{d} invalidations={d} translation={d}/{d} kib={d}\n", .{
                self.presented_frames,  self.shader_analyses.hits, self.shader_analyses.misses,    self.shader_analyses.invalidations,
                self.translations.hits, self.translations.misses,  self.translations.bytes / 1024,
            });
            const cache = self.device.cacheStats();
            const pool = self.device.resourceStats();
            const attachments = self.device.attachmentStats();
            std.debug.print("[d3d12 attachments] flip={d} enabled={d} color_hit={d} depth_hit={d} miss={d} avoided_kib={d} pairs={d}\n", .{
                self.presented_frames, attachments.enabled,              attachments.color_hits, attachments.depth_hits,
                attachments.misses,    attachments.avoided_bytes / 1024, attachments.pairs,
            });
            const uploads = self.device.uploadStats();
            std.debug.print("[d3d12 uploads] flip={d} buffer_hit={d} image_hit={d} content_hit={d} miss={d} avoided_kib={d} evict={d} bypass={d} kib={d}/{d}\n", .{
                self.presented_frames, uploads.buffer_hits, uploads.image_hits,   uploads.content_hits, uploads.misses, uploads.avoided_bytes / 1024,
                uploads.evictions,     uploads.bypasses,    uploads.bytes / 1024, uploads.limit / 1024,
            });
            const scratch = &self.staging_pool;
            const conversions = &self.conversion_cache;
            std.debug.print("[d3d12 conversions] flip={d} detile={d}/{d} tile={d}/{d} evict={d} bypass={d} kib={d}/{d}\n", .{
                self.presented_frames, conversions.detile_hits, conversions.detile_misses, conversions.tile_hits,    conversions.tile_misses,
                conversions.evictions, conversions.bypasses,    conversions.bytes / 1024,  conversions.limit / 1024,
            });
            std.debug.print("[d3d12 staging] flip={d} hit={d} miss={d} evict={d} bypass={d} kib={d}/{d}\n", .{
                self.presented_frames, scratch.hits, scratch.misses, scratch.evictions, scratch.bypasses, scratch.bytes / 1024, scratch.limit / 1024,
            });
            std.debug.print("[d3d12 resources] flip={d} hit={d} miss={d} evict={d} bypass={d} entries={d} kib={d}/{d} create_ms={d}\n", .{
                self.presented_frames, pool.hits, pool.misses, pool.evictions, pool.bypasses, pool.entries, pool.bytes / 1024, pool.limit / 1024, pool.create_ms,
            });
            std.debug.print("[d3d12 cache] flip={d} enabled={d} shader={d}/{d} pso={d}/{d} entries={d}/{d} evictions={d}/{d} shader_kib={d} compile_ms={d} pso_ms={d}\n", .{
                self.presented_frames, cache.enabled,          cache.shader_hits,      cache.shader_misses,      cache.pipeline_hits,       cache.pipeline_misses,
                cache.shader_entries,  cache.pipeline_entries, cache.shader_evictions, cache.pipeline_evictions, cache.shader_bytes / 1024, cache.compile_ms,
                cache.pipeline_ms,
            });
            self.cache_report_ns = now;
        }
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

const DrawArguments = struct {
    count: u32,
    address: u64 = 0,
    index_bytes: u32 = 0,

    fn decode(state: *const gpu.State, packet: gpu.pm4.Packet) !DrawArguments {
        const body = packet.body;
        if (packet.opcode == gpu.pm4.draw_index_auto) {
            if (body.len < 2) return error.InvalidDrawPacket;
            // Only ordinary auto-index draws; opaque-count/streamout modes
            // require additional state and must not become a guessed count.
            if (body[1] != 2) return error.UnsupportedDrawInitiator;
            return .{ .count = body[0] };
        }
        var args: DrawArguments = undefined;
        var maximum: u32 = undefined;
        var offset: u32 = 0;
        switch (packet.opcode) {
            gpu.pm4.draw_index_2 => {
                if (body.len < 5) return error.InvalidDrawPacket;
                if (body[4] != 0) return error.UnsupportedDrawInitiator;
                args = .{ .count = body[3], .address = @as(u64, body[2]) << 32 | body[1] };
                maximum = body[0];
            },
            gpu.pm4.draw_index_offset_2 => {
                if (body.len < 4) return error.InvalidDrawPacket;
                if (body[3] != 0) return error.UnsupportedDrawInitiator;
                args = .{ .count = body[2], .address = state.index_base_address };
                maximum = body[0];
                offset = body[1];
            },
            else => return error.IndirectAndMultiDrawNotImplemented,
        }
        if (args.count == 0 or state.instance_count == 0) return .{ .count = 0 };
        args.index_bytes = switch (state.index_type) {
            0 => 2,
            1 => 4,
            2 => 1,
            3 => return error.UnsupportedIndexType,
        };
        if (args.count > maximum) return error.IndexCountOutOfBounds;
        args.address = try std.math.add(u64, args.address, @as(u64, offset) * args.index_bytes);
        if (args.address == 0 or args.address % args.index_bytes != 0) return error.InvalidIndexAddress;
        const bytes = @as(u64, args.count) * args.index_bytes;
        if (bytes > 64 * 1024 * 1024) return error.IndexBufferTooLarge;
        _ = try std.math.add(u64, args.address, bytes);
        return args;
    }

    fn stageFan(self: DrawArguments, allocator: std.mem.Allocator, memory: Memory, state: *const gpu.State, draw_state: *native.Draw) ![]u8 {
        if (@as(u64, self.count -| 2) * 12 > 64 * 1024 * 1024) return error.IndexBufferTooLarge;
        const source = try allocator.alloc(u8, @as(usize, self.count) * self.index_bytes);
        defer allocator.free(source);
        var fan = graphics.TriangleFan{
            .count = self.count,
            .indices = source,
            .element_bytes = self.index_bytes,
            .first_vertex = draw_state.first_vertex,
            .provoking_last = (state.readRegister(.context, 0x205) orelse 0) & (1 << 19) != 0,
        };
        if (self.index_bytes != 0) {
            if (!memory.read(memory.context, self.address, source)) return error.GuestReadFailed;
            fan.base_vertex = @bitCast(draw_state.first_vertex);
            const control = state.readRegister(.uconfig, 0x24b) orelse 0;
            const reset = state.readRegister(.context, 0x103) orelse 0;
            const mask: u32 = switch (self.index_bytes) {
                1 => 0xff,
                2 => 0xffff,
                else => 0xffffffff,
            };
            if (control & ~@as(u32, 3) != 0) return error.UnsupportedPrimitiveRestartControl;
            if (control & 1 != 0 and (control & 2 == 0 or reset <= mask)) fan.restart = reset & mask;
        }
        const indices = try fan.expand(allocator);
        draw_state.vertex_count = 0;
        draw_state.first_vertex = 0;
        draw_state.base_vertex = fan.base_vertex;
        draw_state.index_count = @intCast(indices.len / 4);
        draw_state.index_element_bytes = 4;
        draw_state.primitive_restart = 0;
        return indices;
    }

    fn stage(self: DrawArguments, allocator: std.mem.Allocator, memory: Memory, state: *const gpu.State, draw_state: *native.Draw, primitive: u32) ![]u8 {
        if (primitive == 5) return self.stageFan(allocator, memory, state, draw_state);
        if (self.index_bytes == 0) return allocator.alloc(u8, 0);
        const native_bytes = @max(2, self.index_bytes);
        const size = @as(usize, self.count) * native_bytes;
        if (size > 64 * 1024 * 1024) return error.IndexBufferTooLarge;
        const indices = try allocator.alloc(u8, size);
        errdefer allocator.free(indices);
        if (!memory.read(memory.context, self.address, indices[0 .. @as(usize, self.count) * self.index_bytes])) return error.GuestReadFailed;
        const reset_control = state.readRegister(.uconfig, 0x24b) orelse 0;
        const reset_index = state.readRegister(.context, 0x103) orelse 0;
        const index_mask: u32 = switch (self.index_bytes) {
            1 => 0xff,
            2 => 0xffff,
            else => 0xffffffff,
        };
        if (reset_control & ~@as(u32, 3) != 0) return error.UnsupportedPrimitiveRestartControl;
        const restart = draw_state.topology == 5 and reset_control & 1 != 0 and
            (reset_control & 2 == 0 or reset_index <= index_mask);
        if (restart and reset_index & index_mask != index_mask) return error.CustomPrimitiveRestartNotImplemented;
        draw_state.index_count = self.count;
        draw_state.index_element_bytes = native_bytes;
        draw_state.base_vertex = @bitCast(state.readRegister(.uconfig, 0x24a) orelse 0);
        draw_state.first_vertex = 0;
        draw_state.primitive_restart = @intFromBool(restart);
        // Widen backwards in place so 8-bit source indices are not overwritten.
        // Strip-cut markers are tested before applying the signed base vertex.
        var i: usize = self.count;
        while (i != 0) {
            i -= 1;
            const index: u32 = switch (self.index_bytes) {
                1 => indices[i],
                2 => std.mem.readInt(u16, indices[i * 2 ..][0..2], .little),
                else => std.mem.readInt(u32, indices[i * 4 ..][0..4], .little),
            };
            const cut = restart and index == index_mask;
            const vertex = @as(i64, index) + draw_state.base_vertex;
            if (!cut and (vertex < 0 or vertex > std.math.maxInt(u32))) return error.InvalidBaseVertex;
            if (self.index_bytes == 1) std.mem.writeInt(u16, indices[i * 2 ..][0..2], if (cut) 0xffff else @intCast(index), .little);
        }
        return indices;
    }
};

fn entryScalars(bindings: gpu.ShaderBindings, output: []rdna2.spirv.ScalarRegister) usize {
    for (bindings.user_data[0..bindings.user_data_count], 0..) |value, index| output[index] = .{ .register = @as(u32, @intCast(index)) + bindings.scalar_user_data_base, .value = value };
    return bindings.user_data_count;
}

const Storage = struct {
    allocator: std.mem.Allocator,
    data: [64][]u8 = undefined,
    addresses: [64]u64 = undefined,
    sizes: [64]usize = undefined,
    writable: [64]bool = undefined,
    /// SMEM pointer snapshots begin with an 8-byte guest base address.
    headers: [64]bool = undefined,
    count: usize = 0,
    total: u64 = 0,
    mappings: std.ArrayList(rdna2.spirv.StorageBufferBinding) = .empty,
    pointers: std.ArrayList(rdna2.spirv.ScalarMemoryBinding) = .empty,

    fn deinit(self: *Storage) void {
        for (self.data[0..self.count]) |bytes| self.allocator.free(bytes);
        self.mappings.deinit(self.allocator);
        self.pointers.deinit(self.allocator);
    }
    /// Identical views share one slot. Overlapping read-only snapshots are
    /// independent copies, but a writable view may not overlap another view:
    /// one of the two copies would publish or observe stale bytes.
    fn stage(self: *Storage, memory: Memory, address: u64, size: u64, writable: bool, header: bool) !u32 {
        const end = try std.math.add(u64, address, size);
        for (0..self.count) |i| {
            if (address == self.addresses[i] and size == self.sizes[i] and header == self.headers[i] and !(header and writable)) {
                self.writable[i] = self.writable[i] or writable;
                return @intCast(i);
            }
            if (address < self.addresses[i] + self.sizes[i] and self.addresses[i] < end and (writable or self.writable[i]))
                return error.OverlappingBufferViewsNotImplemented;
        }
        const prefix: usize = if (header) 8 else 0;
        if (size == 0 or size > 256 * 1024 * 1024 or self.total + size > 256 * 1024 * 1024 or self.count == self.data.len) return error.StorageBudgetExceeded;
        const bytes = try self.allocator.alloc(u8, std.mem.alignForward(usize, prefix + @as(usize, @intCast(size)), 4));
        errdefer self.allocator.free(bytes);
        @memset(bytes, 0);
        if (header) std.mem.writeInt(u64, bytes[0..8], address, .little);
        if (!memory.read(memory.context, address, bytes[prefix..][0..@intCast(size)])) return error.GuestReadFailed;
        const slot = self.count;
        self.data[slot] = bytes;
        self.addresses[slot] = address;
        self.sizes[slot] = @intCast(size);
        self.writable[slot] = writable;
        self.headers[slot] = header;
        self.count += 1;
        self.total += size;
        return @intCast(slot);
    }
    /// Scalar loads read through the same storage array as vector buffers:
    /// S_BUFFER_LOAD with its three-word descriptor, S_LOAD through a pointer
    /// snapshot. Both pointers and descriptors must be statically proven.
    fn stageScalar(self: *Storage, memory: Memory, resolver: *gpu.scalar_resources.Resolver, inst: gpu.ShaderInstruction) !void {
        switch (inst.opcode) {
            .s_load_dword, .s_load_dwordx2, .s_load_dwordx4, .s_load_dwordx8, .s_load_dwordx16 => {
                const reg = gpu.scalar_provenance.scalarRegisterIndex(inst.src0) orelse return error.InvalidScalarPointer;
                var base: [2]u32 = undefined;
                if (!try resolver.words(@intCast(reg), inst.pc, &base) or base[1] > 0xffff or inst.memory_offset < 0)
                    return error.DynamicScalarPointerNotImplemented;
                const offset = try scalarOffset(resolver, inst.src1, inst.pc);
                var address = try std.math.add(u64, @as(u64, base[0]) | (@as(u64, base[1]) << 32), offset);
                address = (try std.math.add(u64, address, @intCast(inst.memory_offset))) & ~@as(u64, 3);
                const size = @as(u64, inst.data_words) * 4;
                const end = try std.math.add(u64, address, size);
                if (address == 0 or size == 0 or size > 64 or address >> 32 != (end - 1) >> 32) return error.UnsupportedScalarPointerRange;
                const slot = try self.stage(memory, address, size, false, true);
                try self.pointers.append(self.allocator, .{ .resource_sgpr = @intCast(reg), .instruction_pc = inst.pc, .descriptor_index = slot });
            },
            .s_buffer_load_dword, .s_buffer_load_dwordx2, .s_buffer_load_dwordx4, .s_buffer_load_dwordx8, .s_buffer_load_dwordx16 => {
                const reg = gpu.scalar_provenance.scalarRegisterIndex(inst.src0) orelse return error.InvalidBufferDescriptor;
                var words: [4]u32 = @splat(0);
                if (!try resolver.words(@intCast(reg), inst.pc, words[0..3])) return error.DynamicBufferDescriptorNotImplemented;
                const descriptor = try gpu.resources.decodeScalarBufferDescriptor(&words);
                if (descriptor.out_of_bounds_select == 2 or descriptor.add_thread_id or descriptor.address == 0 or descriptor.size_bytes == 0)
                    return error.UnsupportedBufferDescriptor;
                const slot = try self.stage(memory, descriptor.address, descriptor.size_bytes, false, false);
                try self.mappings.append(self.allocator, .{
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
            },
            else => return error.ComputeScalarMemoryOperationNotImplemented,
        }
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
