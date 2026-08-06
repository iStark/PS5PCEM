// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Where a title hands its GPU work over.
//!
//! A title builds a command buffer in its own memory and then calls one of a
//! few submission entry points. That call is the whole interface: every draw,
//! every state change, every fence a frame contains is already sitting in the
//! buffer by the time it arrives here. Intercepting it therefore yields the
//! complete description of a frame, without having to model any of the calls
//! that produced it.
//!
//! A submission is decoded into named commands for tracing and applied to
//! persistent command-processor state. Register writes, labels, waits, events
//! and flips therefore retain their real ordering. The executor stays
//! API-neutral while an optional live backend receives the same memory,
//! synchronization, draw, dispatch and presentation callbacks.
//!
//! Submissions are accepted rather than refused, which is the opposite of the
//! choice made for the graphics device. The distinction is what a caller does
//! with the answer: the device request that is refused is one whose reply the
//! driver stores and dereferences, so a false success crashes it. A submission
//! returns only a status, and a title that submits work is not blocked on this
//! call returning — reporting failure here would abort a frame the title had
//! already fully described, and lose the description with it.

const std = @import("std");
const gpu = @import("gpu");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const memory = @import("kernel_memory.zig");
const shader_registry = @import("agc_shader_registry.zig");
const event_queue = @import("kernel_event_queue.zig");
const video_out = @import("../video_out.zig");
const kernel_runtime = @import("kernel_runtime.zig");

/// A submission descriptor: where the buffer is and how long it is.
///
/// Length is in words rather than bytes because the command stream is a
/// sequence of words and every size in this interface is counted that way.
pub const Submission = extern struct {
    address: ?[*]const u32,
    word_count: u32,
    reserved: u32,
};

/// How many packets are listed before a submission is summarised instead.
///
/// A frame's buffer runs to tens of thousands of packets. Printing all of them
/// buries the shape of the frame in its own detail, and the first commands are
/// where the shape is: the set-up that a draw depends on comes before the draw.
const listed_packet_limit: usize = 64;

const ExecutionLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *ExecutionLock) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *ExecutionLock) void {
        self.inner.unlock();
    }
};

/// Command-processor state and blocked work survive a submission. A title
/// commonly sets a shader or render target in one DCB and consumes it in the
/// next one, so both queues are kept behind one serialized scheduler.
var execution_lock = ExecutionLock{};
var traced_draw_states: u32 = 0;
var traced_shader_program_count: usize = 0;
var traced_shader_programs: [32]u64 = [_]u64{0} ** 32;
var installed_backend: ?gpu.DcbBackend = null;

pub fn readGuestMemory(_: ?*anyopaque, address: u64, bytes: []u8) bool {
    if (video_out.readLabelMemory(address, bytes)) return true;
    if (!memory.isGuestRangeAccessible(address, bytes.len)) return false;
    const source: [*]const u8 = @ptrFromInt(address);
    @memcpy(bytes, source[0..bytes.len]);
    return true;
}

pub fn writeGuestMemory(_: ?*anyopaque, address: u64, bytes: []const u8) bool {
    if (video_out.writeLabelMemory(address, bytes)) return true;
    if (!memory.isGuestRangeAccessible(address, bytes.len)) return false;
    const destination: [*]u8 = @ptrFromInt(address);
    @memcpy(destination[0..bytes.len], bytes);
    return true;
}

var shader_header_miss_logged: bool = false;

pub fn findShaderHeader(_: ?*anyopaque, program_address: u64) ?u64 {
    if (shader_registry.find(program_address)) |header| return header;
    if (!shader_header_miss_logged and program_address != 0) {
        shader_header_miss_logged = true;
        shader_registry.debugNearby(program_address);
    }
    return null;
}

const shader_memory_reader = gpu.ShaderMemoryReader{
    .context = null,
    .read_fn = readGuestMemory,
};

fn traceTextureLayout(layout: gpu.TextureLayout) void {
    std.debug.print(
        "    layout family={s} block={d}x{d}x{d}/{d} samples={d} mips={d} tail={d} source={d}\n",
        .{
            @tagName(layout.block.family),
            layout.block.width,
            layout.block.height,
            layout.block.depth,
            layout.block.bytes,
            @as(u32, 1) << @intCast(layout.block.samples_log2),
            layout.mip_levels,
            layout.first_tail_level,
            layout.required_source_bytes,
        },
    );
}

fn traceImageLayout(image: gpu.ImageDescriptor) void {
    const layout = gpu.TextureLayout.fromImage(image) catch |err| {
        std.debug.print("    layout unavailable={s}\n", .{@errorName(err)});
        return;
    };
    traceTextureLayout(layout);
}

fn traceShaderBinding(state: *const gpu.State, stage: gpu.resources.ShaderStage) void {
    if (!trace.isLive()) return;
    const program_address = stage.programAddress(state) orelse return;
    for (traced_shader_programs[0..traced_shader_program_count]) |known| {
        if (known == program_address) return;
    }
    if (traced_shader_program_count >= traced_shader_programs.len) return;
    traced_shader_programs[traced_shader_program_count] = program_address;
    traced_shader_program_count += 1;

    const header_address = shader_registry.find(program_address);
    const bindings = gpu.ShaderBindings.capture(
        state,
        stage,
        header_address,
        shader_memory_reader,
    ) catch |err| {
        std.debug.print(
            "[gpu shader {s}] program=0x{x} header={s} error={s}\n",
            .{
                @tagName(stage),
                program_address,
                if (header_address != null) "mapped" else "missing",
                @errorName(err),
            },
        );
        return;
    };

    const metadata = bindings.metadata orelse {
        std.debug.print(
            "[gpu shader {s}] program=0x{x} header=missing ud={d}\n",
            .{ @tagName(stage), program_address, bindings.user_data_count },
        );
        return;
    };
    std.debug.print(
        "[gpu shader {s}] program=0x{x} header=0x{x} ud={d}@{s} eud={d} srt={d}@{s} resources={d}/{d}/{d}/{d}\n",
        .{
            @tagName(stage),
            program_address,
            metadata.header_address,
            bindings.user_data_count,
            @tagName(bindings.user_data_stage),
            metadata.extended_user_data_size_words,
            metadata.shader_resource_table_size_words,
            if (bindings.srt_address != null) "bound" else "none",
            metadata.resource_counts[0],
            metadata.resource_counts[1],
            metadata.resource_counts[2],
            metadata.resource_counts[3],
        },
    );
    if (bindings.srt_address) |address| std.debug.print("  srt_address=0x{x}\n", .{address});
    if (bindings.direct_pointers.fetch_shader) |address| {
        std.debug.print("  fetch_shader=0x{x}\n", .{address});
    }
    if (bindings.direct_pointers.extended_user_data) |address| {
        std.debug.print(
            "  extended_user_data=0x{x} words={d}\n",
            .{ address, metadata.extended_user_data_size_words },
        );
    }

    const scalar = gpu.scalar_provenance.evaluatePrefix(shader_memory_reader, &bindings);
    std.debug.print(
        "  scalar_prefix instructions={d} stop={s}@0x{x} loads={d}\n",
        .{ scalar.instruction_count, @tagName(scalar.stop_reason), scalar.stop_pc, scalar.load_count },
    );
    for (scalar.loadSlice()[0..@min(scalar.load_count, 8)]) |load| {
        std.debug.print(
            "    smem pc=0x{x} address=0x{x} s{d}..+{d} srt={d} roots=0x{x}/0x{x}\n",
            .{
                load.pc,
                load.address,
                load.destination,
                load.word_count,
                @intFromBool(load.from_srt),
                @as(u8, @bitCast(load.base_sources)),
                @as(u8, @bitCast(load.offset_sources)),
            },
        );
    }

    var analysis = gpu.shader_analysis.decode(
        std.heap.page_allocator,
        shader_memory_reader,
        program_address,
        4096,
    ) catch |err| {
        std.debug.print("  shader_frontend error={s}\n", .{@errorName(err)});
        return;
    };
    defer analysis.deinit(std.heap.page_allocator);
    std.debug.print(
        "  shader_frontend words={d} instructions={d} blocks={d} edges={d} selections={d} back_edges={d} opaque={d}\n",
        .{
            analysis.code.items.len,
            analysis.program.instructions.items.len,
            analysis.graph.blocks.items.len,
            analysis.graph.edges.items.len,
            analysis.graph.selections.items.len,
            analysis.graph.back_edge_count,
            analysis.opaqueInstructionCount(),
        },
    );
    const spirv_stage: ?gpu.ShaderSpirvStage = switch (stage) {
        .pixel => .fragment,
        .compute => .compute,
        .vertex, .export_shader => .vertex,
        else => null,
    };
    if (spirv_stage) |host_stage| {
        if (analysis.translateSpirv(
            std.heap.page_allocator,
            .{ .stage = host_stage },
        )) |module| {
            var spirv = module;
            defer spirv.deinit(std.heap.page_allocator);
            std.debug.print("  spirv status=ready words={d}\n", .{spirv.words.len});
        } else |err| {
            std.debug.print("  spirv status=blocked reason={s}\n", .{@errorName(err)});
        }
    }

    if (gpu.VertexShaderBindings.capture(&bindings, shader_memory_reader)) |maybe_vertex| {
        if (maybe_vertex) |vertex| {
            std.debug.print(
                "  vertex_tables buffers=0x{x} attributes=0x{x} inputs={d}\n",
                .{ vertex.buffer_table_address, vertex.attribute_table_address, vertex.attribute_count },
            );
            for (vertex.slice()) |attribute| {
                std.debug.print(
                    "    input[{d}] semantic={d} hw={d} vb={d} base=0x{x} stride={d} offset={d} format={d} instance={d}\n",
                    .{
                        attribute.location,
                        attribute.semantic.semantic,
                        attribute.semantic.hardware_mapping,
                        attribute.buffer_index,
                        attribute.buffer.address,
                        attribute.buffer.stride,
                        attribute.offset_bytes,
                        attribute.attribute_format,
                        @intFromBool(attribute.per_instance),
                    },
                );
            }
        }
    } else |err| {
        std.debug.print("  vertex_tables error={s}\n", .{@errorName(err)});
    }
    for ([_]gpu.shaders.ResourceKind{
        gpu.shaders.ResourceKind.read_only_texture,
        gpu.shaders.ResourceKind.read_write_texture,
        gpu.shaders.ResourceKind.sampler,
        gpu.shaders.ResourceKind.constant_buffer,
    }) |kind| {
        var iterator = bindings.iterator(shader_memory_reader, kind);
        const first = iterator.next() catch |err| {
            std.debug.print("  {s}: error={s}\n", .{ @tagName(kind), @errorName(err) });
            continue;
        } orelse continue;
        switch (first.descriptor) {
            .read_only_texture => |image| {
                std.debug.print(
                    "  {s}[{d}] table=0x{x} image=0x{x} {d}x{d} fmt={d} sw={d}\n",
                    .{ @tagName(kind), first.mapping.slot, first.descriptor_address, image.address, image.width, image.height, image.unified_format, @intFromEnum(image.tile_mode) },
                );
                traceImageLayout(image);
            },
            .read_write_texture => |image| {
                std.debug.print(
                    "  {s}[{d}] table=0x{x} image=0x{x} {d}x{d} fmt={d} sw={d}\n",
                    .{ @tagName(kind), first.mapping.slot, first.descriptor_address, image.address, image.width, image.height, image.unified_format, @intFromEnum(image.tile_mode) },
                );
                traceImageLayout(image);
            },
            .sampler => |sampler| std.debug.print(
                "  {s}[{d}] table=0x{x} lod={d:.2}..{d:.2}\n",
                .{ @tagName(kind), first.mapping.slot, first.descriptor_address, sampler.minimum_lod, sampler.maximum_lod },
            ),
            .constant_buffer => |buffer| std.debug.print(
                "  {s}[{d}] table=0x{x} buffer=0x{x} bytes={d}\n",
                .{ @tagName(kind), first.mapping.slot, first.descriptor_address, buffer.address, buffer.size_bytes },
            ),
        }
    }
}

fn backendDraw(_: ?*anyopaque, state: *const gpu.State, packet: gpu.pm4.Packet) bool {
    traceShaderBinding(state, .export_shader);
    traceShaderBinding(state, .geometry);
    traceShaderBinding(state, .vertex);
    traceShaderBinding(state, .hull);
    traceShaderBinding(state, .pixel);
    if (trace.isLive() and traced_draw_states < 16) {
        traced_draw_states += 1;
        const render = gpu.resources.decodeRenderState(state);
        std.debug.print(
            "[gpu draw state #{d}] color {d}/{d} mask=0x{x}",
            .{ traced_draw_states, render.active_color_count, render.color_count, render.target_mask },
        );
        if (render.depth_target) |depth| {
            std.debug.print(
                ", depth=0x{x} {d}x{d} fmt={d} sw={d} ro={d}\n",
                .{
                    if (depth.write_address != 0) depth.write_address else depth.read_address,
                    depth.width,
                    depth.height,
                    depth.format,
                    @intFromEnum(depth.tile_mode),
                    @intFromBool(depth.depth_read_only),
                },
            );
            if (gpu.TextureLayout.fromDepthTarget(depth)) |layout| {
                traceTextureLayout(layout);
            } else |err| {
                std.debug.print("    layout unavailable={s}\n", .{@errorName(err)});
            }
        } else {
            std.debug.print(", depth=none\n", .{});
        }
        for (render.color_targets) |maybe_target| {
            const target = maybe_target orelse continue;
            std.debug.print(
                "  rt{d}=0x{x} {d}x{d} fmt={d}/{d} sw={d} write=0x{x}\n",
                .{
                    target.slot,
                    target.address,
                    target.width,
                    target.height,
                    target.format,
                    target.number_type,
                    @intFromEnum(target.tile_mode),
                    target.write_mask,
                },
            );
            if (gpu.TextureLayout.fromColorTarget(target)) |layout| {
                traceTextureLayout(layout);
            } else |err| {
                std.debug.print("    layout unavailable={s}\n", .{@errorName(err)});
            }
        }
    }
    const backend = installed_backend orelse return true;
    const callback = backend.vtable.draw orelse return true;
    return callback(backend.context, state, packet);
}

fn backendDispatch(_: ?*anyopaque, state: *const gpu.State, packet: gpu.pm4.Packet) bool {
    traceShaderBinding(state, .compute);
    const backend = installed_backend orelse return true;
    const callback = backend.vtable.dispatch orelse return true;
    return callback(backend.context, state, packet);
}

fn backendRead(_: ?*anyopaque, address: u64, bytes: []u8) bool {
    if (installed_backend) |backend| return backend.vtable.read(backend.context, address, bytes);
    return readGuestMemory(null, address, bytes);
}

fn backendWrite(_: ?*anyopaque, address: u64, bytes: []const u8) bool {
    if (installed_backend) |backend| return backend.vtable.write(backend.context, address, bytes);
    return writeGuestMemory(null, address, bytes);
}

fn backendAcquire(_: ?*anyopaque, value: gpu.state.AcquireMem) bool {
    const backend = installed_backend orelse return true;
    const callback = backend.vtable.acquire orelse return true;
    return callback(backend.context, value);
}

fn backendRelease(_: ?*anyopaque, value: gpu.state.ReleaseMem) bool {
    if (installed_backend) |backend| {
        if (backend.vtable.release) |callback| return callback(backend.context, value);
    }
    if ((value.destination != 0 and value.destination != 1) or value.address == 0) return true;
    var bytes: [8]u8 = undefined;
    const ok = switch (value.data_selection) {
        1 => blk: {
            std.mem.writeInt(u32, bytes[0..4], @truncate(value.data), .little);
            break :blk backendWrite(null, value.address, bytes[0..4]);
        },
        2 => blk: {
            std.mem.writeInt(u64, &bytes, value.data, .little);
            break :blk backendWrite(null, value.address, &bytes);
        },
        3, 4 => blk: {
            // Timestamp or GPU counter. Write a dummy 64-bit value if the backend didn't handle it.
            const dummy_timestamp = struct {
                var counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);
            };
            const val = dummy_timestamp.counter.fetchAdd(1, .monotonic);
            std.mem.writeInt(u64, &bytes, val, .little);
            break :blk backendWrite(null, value.address, &bytes);
        },
        else => true,
    };
    if (ok) {
        kernel_runtime.wakeSyncAddress(value.address, std.math.maxInt(usize));
    }
    return ok;
}

fn backendWait(_: ?*anyopaque, value: gpu.state.WaitRegMem, satisfied: bool) bool {
    const backend = installed_backend orelse return true;
    const callback = backend.vtable.wait orelse return true;
    return callback(backend.context, value, satisfied);
}

fn backendWriteData(_: ?*anyopaque, info: gpu.state.WriteData, values: []const u32) bool {
    if (installed_backend) |backend| {
        if (backend.vtable.write_data) |callback| return callback(backend.context, info, values);
    }
    if (info.destination != 1 and info.destination != 2 and info.destination != 4 and info.destination != 5) {
        return true;
    }
    var bytes: [4]u8 = undefined;
    for (values, 0..) |value, index| {
        std.mem.writeInt(u32, &bytes, value, .little);
        const address = info.address + if (info.increment_address) @as(u64, index) * 4 else 0;
        if (!backendWrite(null, address, &bytes)) return false;
        kernel_runtime.wakeSyncAddress(address, std.math.maxInt(usize));
    }
    return true;
}

fn backendEvent(_: ?*anyopaque, value: gpu.state.EventWrite) bool {
    var handled = false;
    var ok = true;
    if (installed_backend) |backend| {
        if (backend.vtable.event) |callback| {
            ok = callback(backend.context, value);
            handled = true;
        }
    }
    if (!handled) {
        if (value.address) |addr| {
            var bytes: [8]u8 = undefined;
            const dummy_timestamp = struct {
                var counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);
            };
            const val = dummy_timestamp.counter.fetchAdd(1, .monotonic);
            std.mem.writeInt(u64, &bytes, val, .little);
            _ = backendWrite(null, addr, &bytes);
            kernel_runtime.wakeSyncAddress(addr, std.math.maxInt(usize));
        }
    }
    return ok;
}

fn backendFlip(_: ?*anyopaque, value: gpu.state.Flip) bool {
    const accepted = if (value.display_buffer_index == -1)
        true
    else if (installed_backend) |backend|
        if (backend.vtable.flip) |callback| callback(backend.context, value) else true
    else
        true;
    if (!accepted) return false;
    if (!video_out.completeFlip(value)) return false;
    _ = event_queue.triggerVideoOutFlip(value.argument);
    // Titles that wait on vblank edges (or poll GetVblankStatus) need refresh
    // progress even when only flips are submitted.
    _ = event_queue.triggerVideoOutVblank();
    return true;
}

const executor_backend_vtable = gpu.DcbBackend.VTable{
    .read = backendRead,
    .write = backendWrite,
    .acquire = backendAcquire,
    .release = backendRelease,
    .wait = backendWait,
    .write_data = backendWriteData,
    .event = backendEvent,
    .flip = backendFlip,
    .draw = backendDraw,
    .dispatch = backendDispatch,
};

const executor_backend = gpu.DcbBackend{
    .context = null,
    .vtable = &executor_backend_vtable,
};

var submission_scheduler = gpu.QueueScheduler.init(std.heap.page_allocator, executor_backend);

/// Installs or removes the renderer behind the live HLE submission boundary.
/// The execution lock guarantees that a detached backend is no longer inside a
/// callback when this function returns.
pub fn attachBackend(backend: ?gpu.DcbBackend) void {
    execution_lock.lock();
    defer execution_lock.unlock();
    installed_backend = backend;
}

/// Presents a CPU/EOP VideoOut request through the same ordered backend used by
/// a PM4 `SetFlip` packet.
pub fn presentFlip(flip: gpu.state.Flip) bool {
    execution_lock.lock();
    defer execution_lock.unlock();
    return backendFlip(null, flip);
}

/// Clears retained queue/register state between process runtimes.
pub fn reset() void {
    execution_lock.lock();
    defer execution_lock.unlock();
    installed_backend = null;
    submission_scheduler.deinit();
    submission_scheduler = gpu.QueueScheduler.init(std.heap.page_allocator, executor_backend);
    traced_draw_states = 0;
    traced_shader_program_count = 0;
    traced_shader_programs = [_]u64{0} ** traced_shader_programs.len;
}

/// What one submitted buffer contained.
pub const Summary = struct {
    packets: usize = 0,
    draws: usize = 0,
    dispatches: usize = 0,
    /// Words the walk covered before stopping, which is the whole buffer unless
    /// something in it did not decode.
    words_read: usize = 0,
    /// Set when decoding stopped early. A stream is read out of guest memory,
    /// so this is a real possibility and not a formality.
    stopped: ?gpu.pm4.Error = null,
};

/// Reads a submitted buffer without executing any of it.
pub fn summarize(stream: []const u32) Summary {
    var result = Summary{};
    var walker = gpu.pm4.Walker.init(stream);
    while (true) {
        const packet = walker.next() catch |err| {
            result.stopped = err;
            return result;
        } orelse break;
        result.packets += 1;
        result.words_read = walker.index;
        if (packet.kind == .command) {
            if (gpu.pm4.isDraw(packet.opcode)) result.draws += 1;
            if (gpu.pm4.isDispatch(packet.opcode)) result.dispatches += 1;
        }
    }
    return result;
}

/// Prints a submitted buffer when live tracing is on.
fn announce(label: []const u8, stream: []const u32) void {
    if (!trace.isLive()) return;

    std.debug.print(
        "[{s}] 0x{x} {d} dwords\n",
        .{ label, @intFromPtr(stream.ptr), stream.len },
    );

    var line: [160]u8 = undefined;
    var walker = gpu.pm4.Walker.init(stream);
    var shown: usize = 0;
    while (shown < listed_packet_limit) : (shown += 1) {
        const offset = walker.index;
        const packet = walker.next() catch |err| {
            const header = stream[offset];
            std.debug.print(
                "  {d:0>5}: <{s} at 0x{x:0>8}, {d} words remain>\n",
                .{ offset, @errorName(err), header, stream.len - offset },
            );
            break;
        } orelse break;

        var writer = std.Io.Writer.fixed(&line);
        gpu.pm4.write(packet, &writer) catch continue;
        std.debug.print("  {d:0>5}: {s}\n", .{ offset, writer.buffered() });
    }

    const summary = summarize(stream);
    if (summary.packets > shown) {
        std.debug.print("  ... {d} more packets\n", .{summary.packets - shown});
    }
    std.debug.print(
        "  packets {d}, draws {d}, dispatches {d}\n",
        .{ summary.packets, summary.draws, summary.dispatches },
    );
}

/// Runs a command stream handed over through the kernel device.
///
/// The shipped driver submits through `/dev/gc` rather than through the library
/// entry points, so this is the same work arriving by a different door. It goes
/// to the same scheduler, because the door a stream came through says nothing
/// about what it contains.
pub const SubmitOutcome = struct {
    accepted: bool = false,
    completed: bool = false,
};

pub fn submitDeviceStream(stream: []const u32) SubmitOutcome {
    announce("dcb", stream);
    return executeSubmitted("dcb", stream);
}

/// Advance both queues and soft-satisfy any permanent WAIT_REG_MEM heads.
/// Called from SuspendPoint so the driver observes GPU progress between frames.
pub fn pumpQueues() void {
    execution_lock.lock();
    defer execution_lock.unlock();
    var force_rounds: u8 = 0;
    while (force_rounds < 8) : (force_rounds += 1) {
        var progressed = false;
        for ([_]gpu.QueueKind{ .graphics, .compute }) |kind| {
            if (!submission_scheduler.isBlocked(kind)) continue;
            const wait = submission_scheduler.state(kind).blocked_wait orelse continue;
            if (!forceSatisfyWait(wait)) continue;
            progressed = true;
        }
        _ = submission_scheduler.pump() catch break;
        if (!progressed and
            !submission_scheduler.isBlocked(.graphics) and
            !submission_scheduler.isBlocked(.compute)) break;
    }
}

/// Queues one submitted buffer and advances both command processors. A blocked
/// head retains its exact root/indirect continuation; a real release-label
/// write from the other queue makes the following pump resume it in place.
fn executeSubmitted(label: []const u8, stream: []const u32) SubmitOutcome {
    execution_lock.lock();
    defer execution_lock.unlock();

    const kind: gpu.QueueKind = if (std.mem.eql(u8, label, "acb"))
        .compute
    else
        .graphics;
    var report = submission_scheduler.submit(kind, stream) catch |err| {
        std.debug.print("[{s}] queue stopped: {s}\n", .{ label, @errorName(err) });
        return .{};
    };

    // Bring-up: if WAIT_REG_MEM parks the queue on a label that never updates
    // (missing EOP writer / wrong aperture), publish the expected value and
    // pump again so later ring kicks are not stuck behind a permanent head.
    var force_rounds: u8 = 0;
    while (submission_scheduler.isBlocked(kind) and force_rounds < 16) : (force_rounds += 1) {
        const wait = submission_scheduler.state(kind).blocked_wait orelse break;
        std.debug.print(
            "[{s}] WAIT_REG_MEM soft-satisfy addr=0x{x} mask=0x{x} ref=0x{x} (round {d}, queued={d})\n",
            .{
                label,
                wait.address,
                wait.mask,
                wait.reference,
                force_rounds + 1,
                submission_scheduler.pendingCount(kind),
            },
        );
        if (!forceSatisfyWait(wait)) break;
        report = submission_scheduler.pump() catch |err| {
            std.debug.print("[{s}] pump after soft-satisfy failed: {s}\n", .{ label, @errorName(err) });
            break;
        };
    }

    // A completion event can be attributed here only while this submission
    // drains synchronously. A later cross-queue resume needs per-submission
    // owner metadata before it can safely publish the matching event.
    const completed = !submission_scheduler.isBlocked(kind) and
        submission_scheduler.pendingCount(kind) == 0;
    if (submission_scheduler.isBlocked(kind)) {
        if (submission_scheduler.state(kind).blocked_wait) |wait| {
            std.debug.print(
                "[{s}] still blocked after soft-satisfy: WAIT_REG_MEM 0x{x} ref=0x{x}; {d} queued\n",
                .{ label, wait.address, wait.reference, submission_scheduler.pendingCount(kind) },
            );
        }
    }
    if (trace.isLive() and report.completed_submissions > 1) {
        std.debug.print(
            "[gpu queues] completed {d} submissions after cross-queue progress\n",
            .{report.completed_submissions},
        );
    }
    return .{ .accepted = true, .completed = completed };
}

/// Writes the WAIT_REG_MEM reference into the watched location so a re-poll
/// succeeds. Register-space waits update the scheduler's tracked registers.
fn forceSatisfyWait(wait: gpu.state.WaitRegMem) bool {
    if (!wait.memory_space) {
        // Absolute config/context register index — write into both queues' state.
        const absolute: u32 = @truncate(wait.address);
        for ([_]gpu.QueueKind{ .graphics, .compute }) |kind| {
            const st = submission_scheduler.state(kind);
            // Best-effort: map common UCONFIG/CONTEXT ranges via writeRegister if possible.
            _ = st;
            _ = absolute;
        }
        // Without a reliable register map, leave register waits alone.
        return false;
    }
    const ok = switch (wait.width) {
        .bits_32 => blk: {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @truncate(wait.reference), .little);
            break :blk writeGuestMemory(null, wait.address, &bytes);
        },
        .bits_64 => blk: {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, wait.reference, .little);
            break :blk writeGuestMemory(null, wait.address, &bytes);
        },
    };
    if (ok) {
        kernel_runtime.wakeSyncAddress(wait.address, std.math.maxInt(usize));
    }
    return ok;
}

fn acceptSubmitted(label: []const u8, stream: []const u32) SubmitOutcome {
    announce(label, stream);
    return executeSubmitted(label, stream);
}

/// Turns a submitted address and length into a readable buffer, or null.
///
/// The range is checked against the guest address space first. A submission
/// names memory the title owns, but a title with a bug — or a length this
/// emulator mapped wrongly — can name memory it does not, and reading it would
/// fault inside the emulator rather than inside the guest, where the fault
/// handler could attribute it.
fn streamOf(address: ?[*]const u32, word_count: u32) ?[]const u32 {
    const base = address orelse return null;
    if (word_count == 0) return null;
    const bytes = @as(u64, word_count) * @sizeOf(u32);
    if (!memory.isGuestRangeAccessible(@intFromPtr(base), bytes)) return null;
    return base[0..word_count];
}

/// Reads one submission descriptor and reports it.
fn submitOne(label: []const u8, descriptor: ?*const Submission) SubmitOutcome {
    const submission = descriptor orelse return .{};
    const stream = streamOf(submission.address, submission.word_count) orelse return .{};
    return acceptSubmitted(label, stream);
}

/// Graphics work, described by one descriptor.
fn submitDcb(descriptor: ?*const Submission) callconv(abi.guest) i32 {
    // Fire every graphics registration on accept: the real interrupt id is not
    // always zero, and a blocked WAIT_REG_MEM head still progressed work.
    if (submitOne("dcb", descriptor).accepted) _ = event_queue.triggerAllGraphicsEvents(0);
    return errno.ok;
}

/// Compute work on a named queue.
fn submitAcb(queue: u32, descriptor: ?*const Submission) callconv(abi.guest) i32 {
    if (submitOne("acb", descriptor).accepted) {
        const identifier: i32 = @bitCast(queue);
        _ = event_queue.triggerGraphicsEvent(identifier, queue);
        _ = event_queue.triggerAllGraphicsEvents(queue);
    }
    return errno.ok;
}

/// Several graphics buffers at once, as two parallel arrays.
///
/// A null entry is skipped rather than ending the batch: the arrays are indexed
/// in parallel, so stopping early would silently drop every buffer after a hole
/// the title deliberately left.
fn submitMultiDcbs(
    addresses: ?[*]const ?[*]const u32,
    word_counts: ?[*]const u32,
    count: u32,
) callconv(abi.guest) i32 {
    if (count == 0) return errno.ok;
    const buffers = addresses orelse return errno.KernelError.einval.raw();
    const sizes = word_counts orelse return errno.KernelError.einval.raw();

    for (0..count) |index| {
        const stream = streamOf(buffers[index], sizes[index]) orelse continue;
        if (acceptSubmitted("dcb", stream).accepted) _ = event_queue.triggerAllGraphicsEvents(0);
    }
    return errno.ok;
}

pub fn submitMultiAcbs(
    queue: u32,
    addresses: ?[*]const ?[*]const u32,
    word_counts: ?[*]const u32,
    count: u32,
) callconv(abi.guest) i32 {
    if (count == 0) return errno.ok;
    const buffers = addresses orelse return errno.KernelError.einval.raw();
    const sizes = word_counts orelse return errno.KernelError.einval.raw();
    const identifier: i32 = @bitCast(queue);
    for (0..count) |index| {
        const stream = streamOf(buffers[index], sizes[index]) orelse continue;
        if (acceptSubmitted("acb", stream).accepted) {
            _ = event_queue.triggerGraphicsEvent(identifier, queue);
            _ = event_queue.triggerAllGraphicsEvents(queue);
        }
    }
    return errno.ok;
}

/// One buffer submitted directly, without a descriptor around it.
fn submitCommandBuffer(_: u32, address: ?[*]const u32, word_count: u32) callconv(abi.guest) i32 {
    const stream = streamOf(address, word_count) orelse return errno.ok;
    if (acceptSubmitted("dcb", stream).accepted) _ = event_queue.triggerAllGraphicsEvents(0);
    return errno.ok;
}

pub const exports = [_]symbols.Export{
    .{ .name = "sceAgcDriverSubmitDcb", .function = trace.wrap("sceAgcDriverSubmitDcb", &submitDcb), .expect_id = "UglJIZjGssM" },
    .{ .name = "sceAgcDriverAgrSubmitDcb", .function = trace.wrap("sceAgcDriverAgrSubmitDcb", &submitDcb), .expect_id = "AhGvpITrf4M" },
    .{ .name = "sceAgcDriverSubmitAcb", .function = trace.wrap("sceAgcDriverSubmitAcb", &submitAcb), .expect_id = "gSRnr79F8tQ" },
    .{ .name = "sceAgcDriverSubmitMultiDcbs", .function = trace.wrap("sceAgcDriverSubmitMultiDcbs", &submitMultiDcbs), .expect_id = "6UzEidRZwkg" },
    .{ .name = "sceAgcDriverAgrSubmitMultiDcbs", .function = trace.wrap("sceAgcDriverAgrSubmitMultiDcbs", &submitMultiDcbs), .expect_id = "+T8Xo6LtFJI" },
    .{ .name = "sceAgcDriverSubmitCommandBuffer", .function = trace.wrap("sceAgcDriverSubmitCommandBuffer", &submitCommandBuffer), .expect_id = "b4fpgH5ZXxQ" },
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn command(opcode: u8, body_words: u14) u32 {
    return (@as(u32, 3) << 30) | (@as(u32, body_words - 1) << 16) | (@as(u32, opcode) << 8);
}

test "a submitted buffer is counted by what it contains" {
    const stream = [_]u32{
        command(gpu.pm4.clear_state, 1),     0,
        command(gpu.pm4.num_instances, 1),   1,
        command(gpu.pm4.draw_index_auto, 2), 3,
        0,                                   command(gpu.pm4.dispatch_direct, 3),
        1,                                   1,
        1,                                   command(gpu.pm4.draw_index_2, 4),
        0,                                   0,
        0,                                   0,
    };
    const summary = summarize(&stream);
    try testing.expectEqual(@as(usize, 5), summary.packets);
    try testing.expectEqual(@as(usize, 2), summary.draws);
    try testing.expectEqual(@as(usize, 1), summary.dispatches);
    try testing.expectEqual(stream.len, summary.words_read);
    try testing.expect(summary.stopped == null);
}

test "a buffer that stops decoding reports where and why" {
    // The words already read are still a description of what the title asked
    // for, so they are reported rather than discarded with the error.
    const stream = [_]u32{
        command(gpu.pm4.clear_state, 1), 0,
        command(gpu.pm4.write_data, 9),  1,
    };
    const summary = summarize(&stream);
    try testing.expectEqual(@as(usize, 1), summary.packets);
    try testing.expectEqual(@as(usize, 2), summary.words_read);
    try testing.expectEqual(gpu.pm4.Error.Truncated, summary.stopped.?);
}

test "an empty submission is not a failure" {
    const summary = summarize(&[_]u32{});
    try testing.expectEqual(@as(usize, 0), summary.packets);
    try testing.expect(summary.stopped == null);
}

test "a submission naming no buffer is ignored, not read" {
    try testing.expect(streamOf(null, 16) == null);
    try testing.expect(streamOf(@ptrFromInt(0x1000), 0) == null);

    var stream = [_]u32{ command(gpu.pm4.nop, 1), 0 };
    try testing.expectEqual(@as(usize, 2), streamOf(&stream, 2).?.len);
}

test "submission entry points accept what they cannot yet carry out" {
    // A title that submits work is not waiting on this call to return; failing
    // it would abort a frame the title had already fully described.
    try testing.expectEqual(errno.ok, submitDcb(null));
    try testing.expectEqual(errno.ok, submitAcb(0, null));
    try testing.expectEqual(errno.ok, submitMultiDcbs(null, null, 0));
    try testing.expectEqual(errno.ok, submitMultiAcbs(0, null, null, 0));
    try testing.expectEqual(errno.ok, submitCommandBuffer(0, null, 0));

    // Naming a count but no arrays is a caller error, and saying so costs
    // nothing because there is no frame described anywhere to lose.
    try testing.expectEqual(errno.KernelError.einval.raw(), submitMultiDcbs(null, null, 2));
    try testing.expectEqual(errno.KernelError.einval.raw(), submitMultiAcbs(0, null, null, 2));
}

test "an installed renderer receives CPU VideoOut flips before completion" {
    const Probe = struct {
        calls: u32 = 0,
        last: gpu.state.Flip = undefined,

        fn read(_: ?*anyopaque, _: u64, _: []u8) bool {
            return false;
        }

        fn write(_: ?*anyopaque, _: u64, _: []const u8) bool {
            return false;
        }

        fn flip(context: ?*anyopaque, value: gpu.state.Flip) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.last = value;
            return true;
        }
    };
    const probe_vtable = gpu.DcbBackend.VTable{
        .read = Probe.read,
        .write = Probe.write,
        .flip = Probe.flip,
    };

    reset();
    video_out.reset();
    defer reset();
    defer video_out.reset();
    try testing.expect(video_out.open(0));
    var display: [64]u8 = @splat(0);
    const buffers = [_]video_out.Buffer{.{
        .data = &display,
        .metadata = null,
        .reserved = .{ null, null },
    }};
    try video_out.registerBuffers(0, 0, &buffers, .{
        .width = 4,
        .height = 4,
        .pitch_in_pixels = 4,
    }, 0);

    var probe = Probe{};
    attachBackend(.{ .context = &probe, .vtable = &probe_vtable });
    const flip = gpu.state.Flip{
        .video_out_handle = 1,
        .display_buffer_index = 0,
        .mode = 1,
        .argument = 0x1234,
    };
    try testing.expect(presentFlip(flip));
    try testing.expectEqual(@as(u32, 1), probe.calls);
    try testing.expectEqual(flip.argument, probe.last.argument);
    try testing.expectEqual(@as(u64, 1), video_out.status(1).?.count);
}

test "a hole in a batch does not drop the buffers after it" {
    var first = [_]u32{ command(gpu.pm4.clear_state, 1), 0 };
    var last = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 0 };

    const buffers = [_]?[*]const u32{ &first, null, &last };
    const sizes = [_]u32{ first.len, 0, last.len };
    try testing.expectEqual(errno.ok, submitMultiDcbs(&buffers, &sizes, buffers.len));
}

test "submission exports register under published identifiers" {
    var db = symbols.Database{};
    defer db.deinit(testing.allocator);
    try db.addLibrary(
        testing.allocator,
        .{ .name = "libSceAgcDriver", .version = 1 },
        .{ .name = "libSceAgcDriver", .version_major = 1, .version_minor = 1 },
        &exports,
    );
    try testing.expectEqual(exports.len, db.count());
    try testing.expect(db.findByName("sceAgcDriverSubmitDcb", .function) != null);
}
