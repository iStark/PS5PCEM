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
const builtin = @import("builtin");
const gpu = @import("gpu");
const abi = @import("../abi.zig");
const trace = @import("../trace.zig");
const errno = @import("../errno.zig");
const symbols = @import("../symbols.zig");
const memory = @import("kernel_memory.zig");
const shader_registry = @import("agc_shader_registry.zig");
const event_queue = @import("kernel_event_queue.zig");
const kernel_sync = @import("kernel_sync.zig");
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
var soft_wait_batch_reports: u32 = 0;
var trimmed_submission_reports: u32 = 0;
var compact_release_reports: u32 = 0;
var submission_reports: u32 = 0;
var interrupt_release_reports: u32 = 0;
var release_delivery_reports: u32 = 0;
var retirement_bridge_reports: u32 = 0;

const maximum_submission_aliases = 256;
const SubmissionAlias = struct {
    cpu_address: u64 = 0,
    byte_length: u64 = 0,
};
var submission_alias_lock = ExecutionLock{};
var submission_aliases: [maximum_submission_aliases]SubmissionAlias =
    [_]SubmissionAlias{.{}} ** maximum_submission_aliases;
var next_submission_alias: usize = 0;

const PendingGraphicsSegment = struct {
    start: u64 = 0,
    end: u64 = 0,
    range_end: u64 = 0,
};
var pending_graphics_lock = ExecutionLock{};
var pending_graphics_segment = PendingGraphicsSegment{};
var pending_graphics_reports: u32 = 0;

const CompletionKind = enum {
    release,
    dcb,
    acb,
};

const PendingCompletion = struct {
    kind: CompletionKind,
    context_id: u32 = 0,
    ready_after_ns: u64 = 0,
    ack_sequence: u64 = 0,
    delivered: bool = false,
};

/// GPU completion is asynchronous with respect to sceAgcDriverSubmit*. The
/// guest records its ring entry only after that call returns, so delivering an
/// event from inside the synchronous host renderer races ahead of the record
/// and eventually exhausts the ring. Keep completions ordered and publish them
/// on the next driver boundary / suspend point instead.
const maximum_pending_completions = 4096;
// The submitting guest thread records its retirement node only after the HLE
// call has returned. Keep the first notification asynchronous, then retain the
// FIFO head until AgcInterruptThread signals one of the driver's retirement
// conditions. If the event was consumed before the node existed, reissue it;
// a fixed delay alone only changes how often that race occurs.
const completion_latency_ns = 250 * std.time.ns_per_ms;
const completion_retry_ns = 250 * std.time.ns_per_ms;
var completion_lock = ExecutionLock{};
var completion_drain_lock = ExecutionLock{};
var pending_completions: [maximum_pending_completions]PendingCompletion = undefined;
var pending_completion_head: usize = 0;
var pending_completion_count: usize = 0;
var dropped_completion_reports: u32 = 0;
var completion_worker_started: std.atomic.Value(bool) = .init(false);

// RELEASE_MEM is encountered while a submission is still executing. A large
// DCB can spend seconds in later draw/dispatch callbacks, so arming its event
// at the packet itself can notify the guest before SubmitDcb returns and before
// the guest records the corresponding retirement node. Execution is serialized
// by execution_lock; collect release edges there and arm them only when the
// complete scheduler pass has finished.
var completion_batch_active: bool = false;
var batched_release_contexts: [maximum_pending_completions]u32 = undefined;
var batched_release_count: usize = 0;

fn sleepCompletionWorker() void {
    if (comptime builtin.os.tag == .windows) {
        var interval: i64 = -10_000; // one millisecond in relative 100-ns units
        _ = std.os.windows.ntdll.NtDelayExecution(.FALSE, &interval);
    } else {
        std.Thread.yield() catch {};
    }
}

fn completionWorkerMain() void {
    while (kernel_runtime.activeIo() != null and !kernel_runtime.guestStopRequested()) {
        sleepCompletionWorker();
        drainCompletionNotifications();
    }
    completion_worker_started.store(false, .release);
}

fn ensureCompletionWorker() void {
    if (kernel_runtime.activeIo() == null or
        completion_worker_started.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, completionWorkerMain, .{}) catch {
        completion_worker_started.store(false, .release);
        return;
    };
    thread.detach();
}

fn enqueueCompletion(completion: PendingCompletion) void {
    completion_lock.lock();
    if (pending_completion_count == pending_completions.len) {
        if (dropped_completion_reports < 8) {
            std.debug.print("[agc delivery] completion FIFO full; dropping {s}\n", .{@tagName(completion.kind)});
            dropped_completion_reports += 1;
        }
        completion_lock.unlock();
        return;
    }
    const tail = (pending_completion_head + pending_completion_count) % pending_completions.len;
    var deferred = completion;
    deferred.ready_after_ns = kernel_runtime.processTimeCounter() +|
        @as(u64, completion_latency_ns);
    pending_completions[tail] = deferred;
    pending_completion_count += 1;
    completion_lock.unlock();
    ensureCompletionWorker();
}

fn beginCompletionBatch() void {
    std.debug.assert(!completion_batch_active);
    completion_batch_active = true;
    batched_release_count = 0;
}

fn finishCompletionBatch() void {
    std.debug.assert(completion_batch_active);
    completion_batch_active = false;
    for (batched_release_contexts[0..batched_release_count]) |context_id| {
        enqueueCompletion(.{ .kind = .release, .context_id = context_id });
    }
    batched_release_count = 0;
}

fn deliverCompletion(completion: PendingCompletion) usize {
    return switch (completion.kind) {
        .release => {
            const queued_graphics = event_queue.triggerGraphicsEvent(0, completion.context_id);
            // Current PS5 AGC registers its direct EOP edge as 0x20. Older
            // SDK/reference implementations use 0x40, so publish to either
            // registration when present rather than silently dropping the
            // title's second completion class.
            const direct_eop_ps5 = event_queue.triggerGraphicsEvent(0x20, completion.context_id);
            const direct_eop_legacy = event_queue.triggerGraphicsEvent(0x40, completion.context_id);
            if (release_delivery_reports < 64) {
                std.debug.print(
                    "[agc delivery] interrupt context={d} graphics={d} eop={d}\n",
                    .{ completion.context_id, queued_graphics, direct_eop_ps5 + direct_eop_legacy },
                );
                release_delivery_reports += 1;
            }
            return queued_graphics + direct_eop_ps5 + direct_eop_legacy;
        },
        .dcb => {
            return event_queue.triggerGraphicsEvent(0, 0) +
                event_queue.triggerGraphicsEvent(0x40, 0);
        },
        .acb => event_queue.triggerUserEventForAll(
            0x1800,
            @bitCast(kernel_runtime.processTimeCounter()),
        ),
    };
}

fn drainCompletionNotifications() void {
    // The completion worker and the host vblank ticker may pump concurrently.
    // Only one may observe/deliver the retained FIFO head at a time.
    completion_drain_lock.lock();
    defer completion_drain_lock.unlock();
    while (true) {
        completion_lock.lock();
        if (pending_completion_count == 0) {
            completion_lock.unlock();
            return;
        }
        const completion = &pending_completions[pending_completion_head];
        // Returning from Submit* is not enough by itself: another guest thread
        // can enter SuspendPoint before the submitting thread has recorded its
        // completion-ring entry. A real GPU cannot interrupt in that window.
        // Preserve FIFO order and leave a short scheduling interval for that
        // post-submit bookkeeping before publishing the event.
        const now = kernel_runtime.processTimeCounter();
        if (completion.delivered) {
            const acknowledged = kernel_sync.agcInterruptCondSequence() != completion.ack_sequence;
            if (acknowledged) {
                pending_completion_head = (pending_completion_head + 1) % pending_completions.len;
                pending_completion_count -= 1;
                completion_lock.unlock();
                continue;
            }
        }
        if (now < completion.ready_after_ns) {
            completion_lock.unlock();
            return;
        }
        completion.delivered = true;
        completion.ack_sequence = kernel_sync.agcInterruptCondSequence();
        completion.ready_after_ns = now +| @as(u64, completion_retry_ns);
        const delivery = completion.*;
        completion_lock.unlock();
        const triggered = deliverCompletion(delivery);
        if (triggered != 0) return;

        // No queue had a matching registration. There can be no guest-side
        // acknowledgement for this edge, and retaining it would block every
        // later completion in the FIFO.
        completion_lock.lock();
        pending_completion_head = (pending_completion_head + 1) % pending_completions.len;
        pending_completion_count -= 1;
        completion_lock.unlock();
    }
}

/// Publishes GPU completions whose asynchronous grace period has elapsed.
/// The host vblank ticker calls this even when every guest AGC thread is
/// sleeping, so the last submission in a batch cannot wait forever for a
/// subsequent driver entry point.
pub fn pumpCompletionNotifications() void {
    drainCompletionNotifications();
}

fn armPendingGraphicsSegment(stream: []const u32) void {
    if (stream.len == 0) return;
    const byte_length = std.math.mul(u64, stream.len, @sizeOf(u32)) catch return;
    const start = std.math.add(u64, @intFromPtr(stream.ptr), byte_length) catch return;
    const range_bytes: u64 = 0x10_0000 * @sizeOf(u32);
    const range_end = std.math.add(u64, start, range_bytes) catch std.math.maxInt(u64);
    pending_graphics_lock.lock();
    defer pending_graphics_lock.unlock();
    pending_graphics_segment = .{ .start = start, .end = start, .range_end = range_end };
}

/// Records AGC commands allocated immediately after the last submitted DCB.
/// The retail library permits this producer pattern and flushes the contiguous
/// extension before a compute buffer waits on its release label.
pub fn trackGraphicsCommandAllocation(address: u64, dword_count: usize) void {
    if (address == 0 or dword_count == 0) return;
    const byte_length = std.math.mul(u64, dword_count, @sizeOf(u32)) catch return;
    const command_end = std.math.add(u64, address, byte_length) catch return;

    pending_graphics_lock.lock();
    defer pending_graphics_lock.unlock();
    const segment = &pending_graphics_segment;
    if (segment.start == 0 or address < segment.start or address >= segment.range_end) return;
    if (address > segment.end) {
        if (pending_graphics_reports < 32) {
            std.debug.print(
                "[agc pending] ignored non-contiguous allocation 0x{x}+{d}, expected 0x{x}\n",
                .{ address, dword_count, segment.end },
            );
            pending_graphics_reports += 1;
        }
        return;
    }
    if (command_end > segment.range_end or command_end <= segment.end) return;
    segment.end = command_end;
    if (pending_graphics_reports < 32) {
        std.debug.print(
            "[agc pending] extended DCB tail @0x{x} to {d} dwords\n",
            .{ segment.start, (segment.end - segment.start) / @sizeOf(u32) },
        );
        pending_graphics_reports += 1;
    }
}

/// AGC command arenas have a CPU mapping and a compact GPU VA whose low 32
/// bits are shared. RELEASE_MEM commonly targets a label embedded in that same
/// arena, so retain enough recent CPU ranges to resolve the compact form.
fn rememberSubmissionAlias(stream: []const u32) void {
    const bytes = std.mem.sliceAsBytes(stream);
    if (bytes.len == 0) return;
    const cpu_address = @intFromPtr(bytes.ptr);
    const low = cpu_address & 0xffff_ffff;
    if (low + bytes.len > (@as(u64, 1) << 32)) return;

    submission_alias_lock.lock();
    defer submission_alias_lock.unlock();
    submission_aliases[next_submission_alias] = .{
        .cpu_address = cpu_address,
        .byte_length = bytes.len,
    };
    next_submission_alias = (next_submission_alias + 1) % submission_aliases.len;
}

fn resolveSubmissionAlias(address: u64, byte_length: usize) ?u64 {
    const low = address & 0xffff_ffff;
    const length: u64 = byte_length;
    submission_alias_lock.lock();
    defer submission_alias_lock.unlock();

    var age: usize = 0;
    while (age < submission_aliases.len) : (age += 1) {
        const index = (next_submission_alias + submission_aliases.len - 1 - age) %
            submission_aliases.len;
        const alias = submission_aliases[index];
        if (alias.byte_length == 0) continue;
        const alias_low = alias.cpu_address & 0xffff_ffff;
        if (low < alias_low) continue;
        const offset = low - alias_low;
        if (offset > alias.byte_length or length > alias.byte_length - offset) continue;
        // The arena itself was validated when the submission was accepted.
        // isGuestRangeAccessible() only describes the reserved guest address
        // space and can also return true for an uncommitted compact GPU VA,
        // so it cannot distinguish the two mappings here.
        return alias.cpu_address + offset;
    }
    return null;
}

pub fn readGuestMemory(_: ?*anyopaque, address: u64, bytes: []u8) bool {
    if (video_out.readLabelMemory(address, bytes)) return true;
    // Prefer a known AGC arena alias. Compact GPU VAs live in the broad guest
    // reservation too, but do not necessarily have committed CPU pages there.
    const resolved = resolveSubmissionAlias(address, bytes.len) orelse
        if (memory.isGuestRangeAccessible(address, bytes.len)) address else return false;
    const source: [*]const u8 = @ptrFromInt(resolved);
    @memcpy(bytes, source[0..bytes.len]);
    return true;
}

pub fn writeGuestMemory(_: ?*anyopaque, address: u64, bytes: []const u8) bool {
    if (video_out.writeLabelMemory(address, bytes)) return true;
    const resolved = resolveSubmissionAlias(address, bytes.len) orelse
        if (memory.isGuestRangeAccessible(address, bytes.len)) address else return false;
    const destination: [*]u8 = @ptrFromInt(resolved);
    @memcpy(destination[0..bytes.len], bytes);
    if (resolved != address) kernel_runtime.wakeSyncAddress(resolved, std.math.maxInt(usize));
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
            "[gpu draw state #{d}] color {d}/{d} mask=0x{x} mode={d}",
            .{ traced_draw_states, render.active_color_count, render.color_count, render.target_mask, render.color_control.mode },
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

fn triggerAgcUserInterrupt() void {
    _ = event_queue.triggerUserEventForAll(
        0x1800,
        @bitCast(kernel_runtime.processTimeCounter()),
    );
}

fn triggerReleaseInterrupt(value: gpu.state.ReleaseMem) void {
    if (value.interrupt != 1 and value.interrupt != 2 and value.interrupt != 4) return;
    if (completion_batch_active and batched_release_count < batched_release_contexts.len) {
        batched_release_contexts[batched_release_count] = value.interrupt_context_id;
        batched_release_count += 1;
        return;
    }
    enqueueCompletion(.{ .kind = .release, .context_id = value.interrupt_context_id });
}

/// Some AGC runtimes keep a CPU retirement label immediately before their
/// hardware EOP label. The real interrupt handler advances the former after
/// observing the latter. Our renderer completes a submitted DCB synchronously,
/// but the approximate interrupt path does not know this private driver
/// structure, leaving the CPU label at zero. Unity then busy-polls it for the
/// full three-second watchdog timeout before every frame.
///
/// Recognize the observed self-describing layout conservatively and publish
/// the driver's issued sequence. This is valid for the synchronous backend:
/// the submitting guest thread cannot regain control until the whole stream
/// has completed. Unrelated release labels fail the signature, pointer,
/// padding, and bounded-sequence checks and remain untouched.
fn synchronousRetirementValue(
    release_address: u64,
    release_data: u64,
    signature: u64,
    retirement_address: u64,
    issued: u64,
    reserved: u64,
    completed: u64,
    retired: u64,
) ?u64 {
    if (release_address < 0x40 or release_address & 0xf != 0) return null;
    // All fields must share the release label's mapped guest page. This also
    // keeps the prefix probes from crossing into an unrelated/unmapped page.
    if (release_address & 0xfff < 0x40) return null;
    if (signature != 0x0000_0002_0000_0000) return null;
    if (retirement_address != release_address - 0x40) return null;
    if (reserved != 0 or completed != release_data) return null;
    if (issued < release_data or issued - release_data > 0x100) return null;
    if (retired >= issued) return null;
    return issued;
}

fn publishSynchronousRetirement(value: gpu.state.ReleaseMem) void {
    if (value.data_selection != 2 or
        value.address < 0x40 or
        value.address & 0xf != 0 or
        value.address & 0xfff < 0x40)
    {
        return;
    }

    // [signature, retirement pointer, issued, reserved, hardware completed]
    var state: [5 * @sizeOf(u64)]u8 = undefined;
    if (!readGuestMemory(null, value.address - 0x20, &state)) return;
    const signature = std.mem.readInt(u64, state[0..8], .little);
    const retirement_address = std.mem.readInt(u64, state[8..16], .little);
    const issued = std.mem.readInt(u64, state[16..24], .little);
    const reserved = std.mem.readInt(u64, state[24..32], .little);
    const completed = std.mem.readInt(u64, state[32..40], .little);
    if (signature != 0x0000_0002_0000_0000 or
        retirement_address != value.address - 0x40 or reserved != 0)
    {
        return;
    }

    var retired_bytes: [8]u8 = undefined;
    if (!readGuestMemory(null, retirement_address, &retired_bytes)) return;
    const retired = std.mem.readInt(u64, &retired_bytes, .little);
    const publish = synchronousRetirementValue(
        value.address,
        value.data,
        signature,
        retirement_address,
        issued,
        reserved,
        completed,
        retired,
    ) orelse return;

    std.mem.writeInt(u64, &retired_bytes, publish, .little);
    if (!writeGuestMemory(null, retirement_address, &retired_bytes)) return;
    kernel_runtime.wakeSyncAddress(retirement_address, std.math.maxInt(usize));
    if (retirement_bridge_reports < 8) {
        std.debug.print(
            "[agc retirement] hardware=0x{x}/0x{x} cpu=0x{x} 0x{x}->0x{x}\n",
            .{ value.address, completed, retirement_address, retired, publish },
        );
        retirement_bridge_reports += 1;
    }
}

fn backendRelease(_: ?*anyopaque, value: gpu.state.ReleaseMem) bool {
    if (compact_release_reports < 64) {
        if (resolveSubmissionAlias(value.address, switch (value.data_selection) {
            1 => 4,
            2, 3, 4 => 8,
            else => 0,
        })) |cpu_address| {
            if (cpu_address != value.address) {
                std.debug.print(
                    "[agc release alias] gpu=0x{x} cpu=0x{x} data=0x{x} selection={d} interrupt={d} context={d}\n",
                    .{
                        value.address,
                        cpu_address,
                        value.data,
                        value.data_selection,
                        value.interrupt,
                        value.interrupt_context_id,
                    },
                );
                compact_release_reports += 1;
            }
        }
    }
    const reports_interrupt = value.interrupt == 1 or value.interrupt == 2 or value.interrupt == 4;
    var old_label: [8]u8 = [_]u8{0} ** 8;
    const label_size: usize = switch (value.data_selection) {
        1 => 4,
        2, 3, 4 => 8,
        else => 0,
    };
    const old_label_valid = reports_interrupt and label_size != 0 and
        readGuestMemory(null, value.address, old_label[0..label_size]);
    if (installed_backend) |backend| {
        if (backend.vtable.release) |callback| {
            const accepted = callback(backend.context, value);
            if (reports_interrupt and interrupt_release_reports < 64) {
                var new_label: [8]u8 = [_]u8{0} ** 8;
                const new_label_valid = label_size != 0 and
                    readGuestMemory(null, value.address, new_label[0..label_size]);
                std.debug.print(
                    "[agc eop] address=0x{x} old={s}0x{x} new={s}0x{x} data=0x{x} selection={d} dst={d} int={d} ctx={d} event={d}/{d} gcr=0x{x} std={d} accepted={d}\n",
                    .{
                        value.address,
                        if (old_label_valid) "" else "?",
                        std.mem.readInt(u64, &old_label, .little),
                        if (new_label_valid) "" else "?",
                        std.mem.readInt(u64, &new_label, .little),
                        value.data,
                        value.data_selection,
                        value.destination,
                        value.interrupt,
                        value.interrupt_context_id,
                        value.event_type,
                        value.event_index,
                        value.gcr_control,
                        @intFromBool(value.standard_packet),
                        @intFromBool(accepted),
                    },
                );
                interrupt_release_reports += 1;
            }
            // The EOP edge is observable only after its preceding Vulkan work
            // and release-label write. Waking before callback completion lets
            // the driver consume the event while the old fence is still set.
            if (accepted) {
                publishSynchronousRetirement(value);
                triggerReleaseInterrupt(value);
            }
            return accepted;
        }
    }
    if ((value.destination != 0 and value.destination != 1) or value.address == 0) {
        triggerReleaseInterrupt(value);
        return true;
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
        publishSynchronousRetirement(value);
        kernel_runtime.wakeSyncAddress(value.address, std.math.maxInt(usize));
        triggerReleaseInterrupt(value);
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

fn backendDmaData(_: ?*anyopaque, value: gpu.state.DmaData) bool {
    if (installed_backend) |backend| {
        if (backend.vtable.dma_data) |callback| return callback(backend.context, value);
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
    .dma_data = backendDmaData,
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
    trimmed_submission_reports = 0;
    compact_release_reports = 0;
    submission_reports = 0;
    interrupt_release_reports = 0;
    release_delivery_reports = 0;
    retirement_bridge_reports = 0;
    submission_alias_lock.lock();
    submission_aliases = [_]SubmissionAlias{.{}} ** submission_aliases.len;
    next_submission_alias = 0;
    submission_alias_lock.unlock();
    pending_graphics_lock.lock();
    pending_graphics_segment = .{};
    pending_graphics_reports = 0;
    pending_graphics_lock.unlock();
    completion_lock.lock();
    pending_completion_head = 0;
    pending_completion_count = 0;
    dropped_completion_reports = 0;
    completion_lock.unlock();
    completion_batch_active = false;
    batched_release_count = 0;
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
    queued_interrupt: bool = false,
};

/// AGC emits its own graphics event for RELEASE_MEM packets that request an
/// interrupt. The submit-call fallback must not emit a second event for the
/// same DCB: the guest driver treats each queued-graphics event as one ring
/// completion and duplicate edges can advance its bookkeeping past the fence
/// that is actually becoming visible.
fn hasQueuedInterrupt(stream: []const u32) bool {
    var walker = gpu.pm4.Walker.init(stream);
    while (walker.next() catch return false) |packet| {
        if (packet.kind != .command or packet.body.len < 2) continue;
        const custom = gpu.pm4.customCode(packet);
        const release = packet.opcode == gpu.pm4.release_mem or
            (custom != null and custom.? == gpu.pm4.custom.release_mem);
        if (!release) continue;
        const selector = (packet.body[1] >> 24) & 0x7;
        if (selector == 1 or selector == 2 or selector == 4) return true;
    }
    return false;
}

/// Returns the executable Gen5 command prefix of a submitted allocation.
///
/// AGC allocators may place descriptor tables and other CPU data immediately
/// after the DCB while reporting the complete allocation capacity. A Gen5 DCB
/// itself contains Type-3 packets plus the one-word Type-2 alignment filler;
/// Type-0 words are therefore the boundary, not register writes to execute.
/// Stopping there also preserves a terminal RELEASE_MEM that precedes the
/// trailing data, so the title receives its completion interrupt/fence.
fn submittedCommandPrefix(stream: []const u32) []const u32 {
    var walker = gpu.pm4.Walker.init(stream);
    while (true) {
        const offset = walker.index;
        const packet = walker.next() catch return stream[0..offset];
        const value = packet orelse return stream;
        if (value.kind != .command and value.kind != .filler) return stream[0..offset];
    }
}

const SubmittedSegment = struct {
    start: usize,
    end: usize,
    packets: usize,
    releases: usize,
};

/// Finds the next command island inside a mixed AGC arena.
///
/// Core command buffers do not merely have an upward prefix and one downward
/// suffix. They may contain several small, complete PM4 streams separated by
/// descriptor tables before the large continuation at the end. A release
/// packet is a strong boundary witness for an interior island; the final
/// continuation is also accepted when its walk reaches the allocation end.
fn nextSubmittedCommandSegment(stream: []const u32, search_start: usize) ?SubmittedSegment {
    if (search_start >= stream.len) return null;
    var start = search_start;
    while (start < stream.len) : (start += 1) {
        const header = stream[start];
        const kind = header >> 30;
        if (kind != 2 and kind != 3) continue;

        var walker = gpu.pm4.Walker.init(stream[start..]);
        var packets: usize = 0;
        var releases: usize = 0;
        var end: usize = 0;
        while (true) {
            const packet = walker.next() catch break orelse break;
            if (packet.kind != .command and packet.kind != .filler) {
                break;
            }
            packets += 1;
            end = walker.index;
            if (packet.kind == .command) {
                const custom = gpu.pm4.customCode(packet);
                if (packet.opcode == gpu.pm4.release_mem or
                    (custom != null and custom.? == gpu.pm4.custom.release_mem))
                {
                    releases += 1;
                }
            }
        }
        // Descriptor words can accidentally resemble one large Type-3 packet.
        // A real island contains a sequence and either publishes a label or is
        // the terminal continuation that consumes the rest of the allocation.
        if (packets >= 4 and (releases != 0 or start + end == stream.len)) {
            return .{
                .start = start,
                .end = start + end,
                .packets = packets,
                .releases = releases,
            };
        }
    }
    return null;
}

fn executeAcceptedStream(label: []const u8, stream: []const u32) SubmitOutcome {
    rememberSubmissionAlias(stream);
    const commands = submittedCommandPrefix(stream);
    if (commands.len == 0) return .{};

    var segment_count: usize = 0;
    var segment_words: usize = 0;
    var scan = commands.len;
    while (nextSubmittedCommandSegment(stream, scan)) |segment| {
        segment_count += 1;
        segment_words += segment.end - segment.start;
        scan = segment.end;
    }
    if (commands.len != stream.len) {
        if (trace.isLive() or trimmed_submission_reports < 8) {
            if (segment_count != 0) {
                std.debug.print(
                    "[{s}] split command arena: prefix={d}, islands={d}/{d}, data={d}/{d} dwords @0x{x}\n",
                    .{
                        label,
                        commands.len,
                        segment_count,
                        segment_words,
                        stream.len - commands.len - segment_words,
                        stream.len,
                        @intFromPtr(stream.ptr),
                    },
                );
            } else {
                std.debug.print(
                    "[{s}] trimmed trailing allocation data: {d}/{d} dwords @0x{x}\n",
                    .{ label, commands.len, stream.len, @intFromPtr(stream.ptr) },
                );
            }
        }
        trimmed_submission_reports +|= 1;
    }
    var outcome = executeSubmitted(label, commands);
    outcome.queued_interrupt = hasQueuedInterrupt(commands);

    scan = commands.len;
    while (nextSubmittedCommandSegment(stream, scan)) |segment| {
        const island = stream[segment.start..segment.end];
        const island_outcome = executeSubmitted(label, island);
        outcome.accepted = outcome.accepted and island_outcome.accepted;
        outcome.completed = island_outcome.completed;
        outcome.queued_interrupt = outcome.queued_interrupt or hasQueuedInterrupt(island);
        scan = segment.end;
    }
    if (std.mem.eql(u8, label, "dcb") and outcome.accepted) {
        armPendingGraphicsSegment(stream);
    }
    return outcome;
}

/// Executes the contiguous graphics commands appended after the last submit.
/// Only a completely walkable Type-2/Type-3 prefix is accepted; descriptor
/// bytes or a half-written final packet remain untouched.
fn flushPendingGraphicsSegment() void {
    var start: u64 = 0;
    var byte_length: u64 = 0;
    pending_graphics_lock.lock();
    if (pending_graphics_segment.end > pending_graphics_segment.start) {
        start = pending_graphics_segment.start;
        byte_length = pending_graphics_segment.end - pending_graphics_segment.start;
    }
    pending_graphics_segment = .{};
    pending_graphics_lock.unlock();
    if (start == 0 or byte_length == 0 or byte_length % @sizeOf(u32) != 0) return;
    if (!memory.isGuestRangeAccessible(start, byte_length)) return;

    const pointer: [*]const u32 = @ptrFromInt(start);
    const available = pointer[0..@intCast(byte_length / @sizeOf(u32))];
    const commands = submittedCommandPrefix(available);
    if (commands.len == 0) return;
    if (pending_graphics_reports < 32) {
        std.debug.print(
            "[agc pending] flushing {d}/{d} appended DCB dwords @0x{x} before ACB\n",
            .{ commands.len, available.len, start },
        );
        pending_graphics_reports += 1;
    }
    rememberSubmissionAlias(commands);
    var outcome = executeSubmitted("dcb", commands);
    outcome.queued_interrupt = hasQueuedInterrupt(commands);
    publishDcbCompletion(outcome);
    if (outcome.accepted) armPendingGraphicsSegment(commands);
}

pub fn submitDeviceStream(stream: []const u32) SubmitOutcome {
    drainCompletionNotifications();
    announce("dcb", stream);
    return executeAcceptedStream("dcb", stream);
}

/// Advance both queues and soft-satisfy any permanent WAIT_REG_MEM heads.
/// Called from SuspendPoint so the driver observes GPU progress between frames.
pub fn pumpQueues() void {
    execution_lock.lock();
    beginCompletionBatch();
    var host_time = kernel_runtime.beginHostTimeExclusion();
    var force_rounds: u16 = 0;
    while (force_rounds < 256) : (force_rounds += 1) {
        var progressed = false;
        for ([_]gpu.QueueKind{ .graphics, .compute }) |kind| {
            if (!submission_scheduler.isBlocked(kind)) continue;
            const wait = submission_scheduler.state(kind).blocked_wait orelse continue;
            if (!forceSatisfyWait(kind, wait)) continue;
            progressed = true;
        }
        _ = submission_scheduler.pump() catch break;
        if (!progressed and
            !submission_scheduler.isBlocked(.graphics) and
            !submission_scheduler.isBlocked(.compute)) break;
    }
    host_time.end();
    finishCompletionBatch();
    execution_lock.unlock();
    drainCompletionNotifications();
}

/// Queues one submitted buffer and advances both command processors. A blocked
/// head retains its exact root/indirect continuation; a real release-label
/// write from the other queue makes the following pump resume it in place.
fn executeSubmitted(label: []const u8, stream: []const u32) SubmitOutcome {
    execution_lock.lock();
    defer execution_lock.unlock();
    beginCompletionBatch();
    defer finishCompletionBatch();
    var host_time = kernel_runtime.beginHostTimeExclusion();
    defer host_time.end();

    const kind: gpu.QueueKind = if (std.mem.eql(u8, label, "acb"))
        .compute
    else
        .graphics;
    const release_count_before = submission_scheduler.state(kind).release_count;
    var report = submission_scheduler.submit(kind, stream) catch |err| {
        std.debug.print("[{s}] queue stopped: {s}\n", .{ label, @errorName(err) });
        return .{};
    };

    // Bring-up: if WAIT_REG_MEM parks the queue on a label that never updates
    // (missing EOP writer / wrong aperture), publish the expected value and
    // pump again so later ring kicks are not stuck behind a permanent head.
    var force_rounds: u16 = 0;
    var first_forced_wait: ?gpu.state.WaitRegMem = null;
    var last_forced_wait: ?gpu.state.WaitRegMem = null;
    while (submission_scheduler.isBlocked(kind) and force_rounds < 256) : (force_rounds += 1) {
        const wait = submission_scheduler.state(kind).blocked_wait orelse break;
        if (!forceSatisfyWait(kind, wait)) break;
        if (first_forced_wait == null) first_forced_wait = wait;
        last_forced_wait = wait;
        report = submission_scheduler.pump() catch |err| {
            std.debug.print("[{s}] pump after soft-satisfy failed: {s}\n", .{ label, @errorName(err) });
            break;
        };
    }
    if (first_forced_wait) |first| {
        if (trace.isLive() or soft_wait_batch_reports < 8) {
            const last = last_forced_wait.?;
            std.debug.print(
                "[{s}] soft-satisfied {d} WAIT_REG_MEM packets: first=0x{x}/0x{x}, last=0x{x}/0x{x}, queued={d}\n",
                .{
                    label,
                    force_rounds,
                    first.address,
                    first.reference,
                    last.address,
                    last.reference,
                    submission_scheduler.pendingCount(kind),
                },
            );
        }
        soft_wait_batch_reports +|= 1;
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
    if (submission_reports < 64) {
        const state = submission_scheduler.state(kind);
        if (state.release_count != release_count_before) {
            const release = state.last_release.?;
            std.debug.print(
                "[agc submit] {s} words={d} releases={d} last=0x{x}/0x{x} selection={d} interrupt={d} context={d}\n",
                .{
                    label,
                    stream.len,
                    state.release_count - release_count_before,
                    release.address,
                    release.data,
                    release.data_selection,
                    release.interrupt,
                    release.interrupt_context_id,
                },
            );
        } else {
            std.debug.print("[agc submit] {s} words={d} releases=0\n", .{ label, stream.len });
        }
        submission_reports += 1;
    }
    return .{ .accepted = true, .completed = completed };
}

/// Writes the WAIT_REG_MEM reference into the watched location so a re-poll
/// succeeds. Register-space waits update the scheduler's tracked registers.
fn forceSatisfyWait(queue_kind: gpu.QueueKind, wait: gpu.state.WaitRegMem) bool {
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
    var bytes: [8]u8 = undefined;
    const payload: []const u8 = switch (wait.width) {
        .bits_32 => blk: {
            std.mem.writeInt(u32, bytes[0..4], @truncate(wait.reference), .little);
            break :blk bytes[0..4];
        },
        .bits_64 => blk: {
            std.mem.writeInt(u64, &bytes, wait.reference, .little);
            break :blk &bytes;
        },
    };
    const ok = writeGuestMemory(null, wait.address, payload);
    if (ok) {
        // Indirect command buffers are snapshotted at submit time. Unreal can
        // colocate a mutable fence label in the same allocation, so mirror the
        // recovery write into the active snapshot before the next re-poll.
        _ = submission_scheduler.mirrorActiveWrite(queue_kind, wait.address, payload);
        kernel_runtime.wakeSyncAddress(wait.address, std.math.maxInt(usize));
    }
    return ok;
}

fn acceptSubmitted(label: []const u8, stream: []const u32) SubmitOutcome {
    const commands = if (std.mem.eql(u8, label, "dcb"))
        dcbWithCompletionPrelude(stream)
    else
        stream;
    announce(label, commands);
    return executeAcceptedStream(label, commands);
}

/// Includes the driver-owned EOP packet placed immediately before a DCB.
///
/// Recent AGC drivers use the bytes preceding the public packet address for a
/// small completion prologue. Unreal's submission ring points at the fence
/// written by that RELEASE_MEM, but SubmitDcb names the first command after it.
/// Dropping the hidden packet leaves the fence at one forever and the interrupt
/// worker holds that node at the front of its retirement queue. Only accept a
/// self-contained, interrupting release that ends exactly at the supplied DCB;
/// this avoids treating unrelated allocation metadata as commands.
fn dcbWithCompletionPrelude(stream: []const u32) []const u32 {
    if (stream.len == 0) return stream;
    const address = @intFromPtr(stream.ptr);
    const page_start = std.mem.alignBackward(usize, address, 0x4000);
    const maximum_words = @min(@as(usize, 16), (address - page_start) / @sizeOf(u32));

    var words: usize = 2;
    while (words <= maximum_words) : (words += 1) {
        const bytes = words * @sizeOf(u32);
        const candidate_address = address - bytes;
        if (!memory.isGuestRangeAccessible(candidate_address, bytes)) continue;
        const candidate_ptr: [*]const u32 = @ptrFromInt(candidate_address);
        const candidate = candidate_ptr[0..words];

        var walker = gpu.pm4.Walker.init(candidate);
        const packet = walker.next() catch continue orelse continue;
        if (packet.kind != .command) continue;
        const custom = gpu.pm4.customCode(packet);
        if (packet.opcode != gpu.pm4.release_mem and
            (custom == null or custom.? != gpu.pm4.custom.release_mem)) continue;
        if (!hasQueuedInterrupt(candidate)) continue;
        if ((walker.next() catch continue) != null) continue;

        if (pending_graphics_reports < 32) {
            std.debug.print(
                "[agc submit] included {d}-dword completion prelude @0x{x} before DCB 0x{x}\n",
                .{ words, candidate_address, address },
            );
            pending_graphics_reports += 1;
        }
        return candidate_ptr[0 .. words + stream.len];
    }
    return stream;
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

/// A graphics submission without an explicit RELEASE_MEM interrupt still
/// raises the EOP registrations when the command processor drains it. AGC's
/// user interrupt belongs to compute completion only; emitting it for a DCB
/// advances the guest cleanup ring independently of the graphics fence.
fn publishDcbCompletion(outcome: SubmitOutcome) void {
    if (!outcome.accepted or outcome.queued_interrupt) return;
    enqueueCompletion(.{ .kind = .dcb });
}

/// Compute completion uses the shared AGC user interrupt. Queue identifiers
/// are not synthetic graphics events; explicit compute RELEASE_MEM packets
/// publish their own EOP event through `triggerReleaseInterrupt`.
fn publishAcbCompletion(outcome: SubmitOutcome) void {
    if (!outcome.accepted or outcome.queued_interrupt) return;
    enqueueCompletion(.{ .kind = .acb });
}

/// Graphics work, described by one descriptor.
fn submitDcb(descriptor: ?*const Submission) callconv(abi.guest) i32 {
    drainCompletionNotifications();
    // The graphics queue completion interrupt is registered under ident zero.
    // Other graphics-filter registrations (notably EOP ident 0x40) represent
    // different hardware events and must not be woken by every submission.
    publishDcbCompletion(submitOne("dcb", descriptor));
    return errno.ok;
}

/// Compute work on a named queue.
fn submitAcb(_: u32, descriptor: ?*const Submission) callconv(abi.guest) i32 {
    drainCompletionNotifications();
    const submission = descriptor orelse return errno.ok;
    const stream = streamOf(submission.address, submission.word_count) orelse return errno.ok;
    flushPendingGraphicsSegment();
    publishAcbCompletion(acceptSubmitted("acb", stream));
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
    drainCompletionNotifications();
    if (count == 0) return errno.ok;
    const buffers = addresses orelse return errno.KernelError.einval.raw();
    const sizes = word_counts orelse return errno.KernelError.einval.raw();

    for (0..count) |index| {
        const stream = streamOf(buffers[index], sizes[index]) orelse continue;
        publishDcbCompletion(acceptSubmitted("dcb", stream));
    }
    return errno.ok;
}

pub fn submitMultiAcbs(
    queue: u32,
    addresses: ?[*]const ?[*]const u32,
    word_counts: ?[*]const u32,
    count: u32,
) callconv(abi.guest) i32 {
    drainCompletionNotifications();
    _ = queue;
    if (count == 0) return errno.ok;
    const buffers = addresses orelse return errno.KernelError.einval.raw();
    const sizes = word_counts orelse return errno.KernelError.einval.raw();
    for (0..count) |index| {
        const stream = streamOf(buffers[index], sizes[index]) orelse continue;
        flushPendingGraphicsSegment();
        publishAcbCompletion(acceptSubmitted("acb", stream));
    }
    return errno.ok;
}

/// One buffer submitted directly, without a descriptor around it.
fn submitCommandBuffer(_: u32, address: ?[*]const u32, word_count: u32) callconv(abi.guest) i32 {
    drainCompletionNotifications();
    const stream = streamOf(address, word_count) orelse return errno.ok;
    publishDcbCompletion(acceptSubmitted("dcb", stream));
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

test "submitted DCB stops before trailing allocation data" {
    const stream = [_]u32{
        command(gpu.pm4.clear_state, 1),                                       0,
        command(gpu.pm4.nop, 7) | (@as(u32, gpu.pm4.custom.release_mem) << 2), 0x2d,
        0x2001_0000,                                                           0x1234_5678,
        1,                                                                     0,
        0,                                                                     0,
        // Descriptor storage in the same allocation is not a Type-3 packet.
        0,                                                                     0,
        0xef28_e1c0,                                                           0x0020_0020,
    };
    const commands = submittedCommandPrefix(&stream);
    try testing.expectEqual(@as(usize, 10), commands.len);
    try testing.expectEqualSlices(u32, stream[0..10], commands);
    try testing.expect(nextSubmittedCommandSegment(&stream, commands.len) == null);
}

test "submitted DCB retains a downward continuation after arena data" {
    const stream = [_]u32{
        command(gpu.pm4.clear_state, 1), 0,
        0,                                 0,           0,                                   0, // descriptor/data gap
        command(gpu.pm4.num_instances, 1), 1,           command(gpu.pm4.draw_index_auto, 2), 3,
        0,                                 0x8000_0000, command(gpu.pm4.dispatch_direct, 3), 1,
        1,                                 1,           command(gpu.pm4.clear_state, 1),     0,
    };
    const prefix = submittedCommandPrefix(&stream);
    try testing.expectEqual(@as(usize, 2), prefix.len);
    const suffix = nextSubmittedCommandSegment(&stream, prefix.len).?;
    try testing.expectEqual(@as(usize, 6), suffix.start);
    try testing.expectEqual(stream.len, suffix.end);
    try testing.expectEqualSlices(u32, stream[6..], stream[suffix.start..suffix.end]);
}

test "submitted DCB retains release-terminated command islands" {
    const release = [_]u32{
        command(gpu.pm4.nop, 7) | (@as(u32, gpu.pm4.custom.release_mem) << 2),
        0x28,
        (@as(u32, 1) << 29) | (@as(u32, 1) << 16),
        0x1000,
        0,
        1,
        0,
        0,
    };
    const stream = [_]u32{
        command(gpu.pm4.clear_state, 1), 0,
        0,                               0,
        0,                               0,
        command(gpu.pm4.nop, 1),         0,
        command(gpu.pm4.nop, 1),         0,
        command(gpu.pm4.nop, 1),         0,
    } ++ release ++ [_]u32{
        0,                                 0, 0,
        command(gpu.pm4.num_instances, 1), 1, command(gpu.pm4.draw_index_auto, 2),
        3,                                 0, command(gpu.pm4.dispatch_direct, 3),
        1,                                 1, 1,
        command(gpu.pm4.clear_state, 1),   0,
    };

    const prefix = submittedCommandPrefix(&stream);
    try testing.expectEqual(@as(usize, 2), prefix.len);
    const island = nextSubmittedCommandSegment(&stream, prefix.len).?;
    try testing.expectEqual(@as(usize, 6), island.start);
    try testing.expectEqual(@as(usize, 20), island.end);
    try testing.expectEqual(@as(usize, 1), island.releases);
    const suffix = nextSubmittedCommandSegment(&stream, island.end).?;
    try testing.expectEqual(@as(usize, 23), suffix.start);
    try testing.expectEqual(stream.len, suffix.end);
}

test "submitted DCB retains Type-2 alignment filler" {
    const stream = [_]u32{
        command(gpu.pm4.clear_state, 1), 0,
        0x8000_0000,                     command(gpu.pm4.num_instances, 1),
        1,
    };
    try testing.expectEqual(stream.len, submittedCommandPrefix(&stream).len);
}

test "queued release interrupt suppresses submit fallback event" {
    const no_interrupt = [_]u32{
        command(gpu.pm4.release_mem, 7), 0x28, (@as(u32, 2) << 29) | (@as(u32, 1) << 16),
        0x1000,                          0,    0,
        0,                               0,
    };
    const queued_interrupt = [_]u32{
        command(gpu.pm4.nop, 7) | (@as(u32, gpu.pm4.custom.release_mem) << 2),
        0x28,
        (@as(u32, 2) << 29) | (@as(u32, 2) << 24) | (@as(u32, 1) << 16),
        0x1000,
        0,
        0,
        0,
        0,
    };
    try testing.expect(!hasQueuedInterrupt(&no_interrupt));
    try testing.expect(hasQueuedInterrupt(&queued_interrupt));
}

test "compact GPU label address resolves into submitted CPU arena" {
    reset();
    defer reset();
    var arena: [16]u32 = @splat(0);
    rememberSubmissionAlias(&arena);

    const cpu_address = @intFromPtr(&arena[7]);
    const cpu_high = cpu_address & 0xffff_ffff_0000_0000;
    const other_high: u64 = if (cpu_high == 0x0000_0001_0000_0000)
        0x0000_0002_0000_0000
    else
        0x0000_0001_0000_0000;
    const gpu_address = other_high | (cpu_address & 0xffff_ffff);
    const value: u32 = 0x1234_5678;
    try testing.expect(writeGuestMemory(null, gpu_address, std.mem.asBytes(&value)));
    try testing.expectEqual(value, arena[7]);

    var observed: u32 = 0;
    try testing.expect(readGuestMemory(null, gpu_address, std.mem.asBytes(&observed)));
    try testing.expectEqual(value, observed);
}

test "synchronous AGC completion advances a paired CPU retirement label" {
    const release_address: u64 = 0x2008_a2a50;
    try testing.expectEqual(@as(?u64, 88), synchronousRetirementValue(
        release_address,
        84,
        0x0000_0002_0000_0000,
        release_address - 0x40,
        88,
        0,
        84,
        0,
    ));
    try testing.expect(synchronousRetirementValue(
        release_address,
        84,
        0x0000_0002_0000_0000,
        release_address - 0x40,
        88,
        0,
        84,
        88,
    ) == null);
    try testing.expect(synchronousRetirementValue(
        release_address,
        84,
        0x0000_0002_0000_0000,
        release_address - 0x38,
        88,
        0,
        84,
        0,
    ) == null);
    try testing.expect(synchronousRetirementValue(
        release_address,
        84,
        0,
        release_address - 0x40,
        88,
        0,
        84,
        0,
    ) == null);
    try testing.expect(synchronousRetirementValue(
        release_address,
        84,
        0x0000_0002_0000_0000,
        release_address - 0x40,
        84 + 0x101,
        0,
        84,
        0,
    ) == null);
    try testing.expect(synchronousRetirementValue(
        0x2008_a2010,
        84,
        0x0000_0002_0000_0000,
        0x2008_a1fd0,
        88,
        0,
        84,
        0,
    ) == null);
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
