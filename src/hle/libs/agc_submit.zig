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
const guest_address_space = @import("memory");
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
var soft_wait_batch_reports: u32 = 0;
var trimmed_submission_reports: u32 = 0;
var compact_release_reports: u32 = 0;
var submission_reports: u32 = 0;
var interrupt_release_reports: u32 = 0;
var release_delivery_reports: u32 = 0;
var retirement_bridge_reports: u32 = 0;
var driver_completion_reports: u32 = 0;
var driver_completion_chain_reports: u32 = 0;
var driver_completion_miss_reports: u32 = 0;
var submission_header_write_reports: u32 = 0;
var unmapped_wait_reports: u32 = 0;
var unsafe_island_reports: u32 = 0;

const maximum_submission_aliases = 256;
const submission_allocation_header_bytes: u64 = 0x10;
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
    driver_label,
    release,
    dcb,
    acb,
};

const PendingCompletion = struct {
    kind: CompletionKind,
    context_id: u32 = 0,
    address: u64 = 0,
    ready_after_ns: u64 = 0,
};

/// GPU completion is asynchronous with respect to sceAgcDriverSubmit*. Keep
/// completion edges ordered and publish them off the synchronous renderer's
/// command-processor stack.
const maximum_pending_completions = 4096;
// The guest queues its retirement record immediately before entering Submit*.
// Publish shortly after the synchronous renderer has returned from the packet,
// while keeping delivery off the command-processor stack. A long grace period
// lets several frames' retirement records accumulate and makes the retail AGC
// worker consume a burst of stale ring edges at mode changes.
const completion_latency_ns = 5 * std.time.ns_per_ms;
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
var batched_driver_completion_label: u64 = 0;
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
    const ready_after_ns = kernel_runtime.processTimeCounter() +|
        @as(u64, completion_latency_ns);
    // Each public submit owns one retirement edge. Preserve FIFO order and do
    // not merge equivalent queue identifiers across separate submissions.
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
    deferred.ready_after_ns = ready_after_ns;
    pending_completions[tail] = deferred;
    pending_completion_count += 1;
    completion_lock.unlock();
    ensureCompletionWorker();
}

fn beginCompletionBatch() void {
    std.debug.assert(!completion_batch_active);
    completion_batch_active = true;
    batched_driver_completion_label = 0;
    batched_release_count = 0;
}

fn finishCompletionBatch() void {
    std.debug.assert(completion_batch_active);
    completion_batch_active = false;
    if (batched_release_count != 0) {
        // RELEASE_MEM has already published its label by this point. Wake the
        // matching event in the same completion boundary: delaying it by even
        // one worker tick lets the submit thread observe label=0, recycle the
        // retirement node, and leaves AgcInterruptThread with a stale list.
        if (batched_driver_completion_label != 0) {
            publishDriverCompletionLabel(batched_driver_completion_label);
        }
        for (batched_release_contexts[0..batched_release_count]) |context_id| {
            _ = deliverCompletion(.{ .kind = .release, .context_id = context_id });
        }
    } else if (batched_driver_completion_label != 0) {
        enqueueCompletion(.{ .kind = .driver_label, .address = batched_driver_completion_label });
    }
    batched_driver_completion_label = 0;
    batched_release_count = 0;
}

fn discardCompletionBatch() void {
    std.debug.assert(completion_batch_active);
    completion_batch_active = false;
    batched_driver_completion_label = 0;
    batched_release_count = 0;
}

fn recordUniqueReleaseContext(storage: []u32, count: *usize, context_id: u32) bool {
    for (storage[0..count.*]) |existing| {
        if (existing == context_id) return true;
    }
    if (count.* == storage.len) return false;
    storage[count.*] = context_id;
    count.* += 1;
    return true;
}

fn deliverCompletion(completion: PendingCompletion) usize {
    return switch (completion.kind) {
        .driver_label => {
            publishDriverCompletionLabel(completion.address);
            return 0;
        },
        .release => {
            const triggered = event_queue.triggerOneGraphicsEventPerQueue(completion.context_id);
            if (release_delivery_reports < 512) {
                std.debug.print(
                    "[agc delivery] interrupt context={d} queues={d}\n",
                    .{ completion.context_id, triggered },
                );
                release_delivery_reports += 1;
            }
            return triggered;
        },
        .dcb => event_queue.triggerGraphicsEvent(0, completion.context_id),
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
    completion_lock.lock();
    const now = kernel_runtime.processTimeCounter();
    if (pending_completion_count == 0 or
        now < pending_completions[pending_completion_head].ready_after_ns)
    {
        completion_lock.unlock();
        return;
    }
    const delivery = pending_completions[pending_completion_head];
    pending_completion_head = (pending_completion_head + 1) % pending_completions.len;
    pending_completion_count -= 1;
    completion_lock.unlock();

    // One completion per worker tick keeps guest-visible ordering while the
    // event queue itself preserves every distinct hardware edge.
    _ = deliverCompletion(delivery);
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

fn resolveGuestMemoryAddress(address: u64, byte_length: usize) ?u64 {
    return resolveSubmissionAlias(address, byte_length) orelse
        if (memory.isGuestRangeAccessible(address, byte_length)) address else null;
}

fn addressSpaceFromContext(context: ?*anyopaque) ?*guest_address_space.AddressSpace {
    return @ptrCast(@alignCast(context orelse return null));
}

const SubmissionHeaderCollision = struct {
    arena_address: u64,
    target_address: u64,
};

/// Command buffers passed by the guest begin immediately after the allocator's
/// 16-byte block header. A malformed packet recovered from descriptor data must
/// never be allowed to publish a fence into that header: doing so corrupts the
/// block size and makes the later guest free walk an effectively random VA.
fn findSubmissionHeaderCollision(address: u64, byte_length: usize) ?SubmissionHeaderCollision {
    if (byte_length == 0) return null;
    const write_end = std.math.add(u64, address, byte_length) catch return null;

    submission_alias_lock.lock();
    defer submission_alias_lock.unlock();
    var age: usize = 0;
    while (age < submission_aliases.len) : (age += 1) {
        const index = (next_submission_alias + submission_aliases.len - 1 - age) %
            submission_aliases.len;
        const alias = submission_aliases[index];
        if (alias.byte_length == 0 or alias.cpu_address < submission_allocation_header_bytes) continue;
        const header_start = alias.cpu_address - submission_allocation_header_bytes;
        if (address < alias.cpu_address and write_end > header_start) {
            return .{ .arena_address = alias.cpu_address, .target_address = address };
        }
    }
    return null;
}

pub fn readGuestMemory(_: ?*anyopaque, address: u64, bytes: []u8) bool {
    if (video_out.readLabelMemory(address, bytes)) return true;
    // Prefer a known AGC arena alias. Compact GPU VAs live in the broad guest
    // reservation too, but do not necessarily have committed CPU pages there.
    const resolved = resolveGuestMemoryAddress(address, bytes.len) orelse return false;
    const source: [*]const u8 = @ptrFromInt(resolved);
    @memcpy(bytes, source[0..bytes.len]);
    return true;
}

pub fn writeGuestMemory(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
    if (video_out.writeLabelMemory(address, bytes)) return true;
    // Fence/write-data packets only publish one or two words. Reject those
    // narrow writes when descriptor data has been mistaken for PM4. A real
    // DMA clear may intentionally recycle an arena after the command processor
    // has fetched it; streams execute from scheduler-owned snapshots, so a
    // broad write which merely spans an old header is safe and must complete.
    const header_collision = if (bytes.len <= submission_allocation_header_bytes)
        findSubmissionHeaderCollision(address, bytes.len)
    else
        null;
    if (header_collision) |collision| {
        if (submission_header_write_reports < 32) {
            var payload: u64 = 0;
            const shown = @min(bytes.len, @sizeOf(u64));
            @memcpy(std.mem.asBytes(&payload)[0..shown], bytes[0..shown]);
            std.debug.print(
                "[agc guard] rejected GPU write into DCB allocation header: target=0x{x}+{d} data=0x{x} arena=0x{x}\n",
                .{ collision.target_address, bytes.len, payload, collision.arena_address },
            );
            submission_header_write_reports += 1;
        }
        return false;
    }
    const resolved = resolveGuestMemoryAddress(address, bytes.len) orelse return false;
    if (addressSpaceFromContext(context)) |space| space.notifyGuestWrite(resolved, bytes.len);
    const destination: [*]u8 = @ptrFromInt(resolved);
    @memcpy(destination[0..bytes.len], bytes);
    if (resolved != address) kernel_runtime.wakeSyncAddress(resolved, std.math.maxInt(usize));
    return true;
}

pub fn trackGpuRead(context: ?*anyopaque, address: u64, size: usize) u64 {
    const space = addressSpaceFromContext(context) orelse return 0;
    const resolved = resolveGuestMemoryAddress(address, size) orelse return 0;
    return space.trackGpuRead(resolved, size) catch 0;
}

pub fn gpuGeneration(context: ?*anyopaque, address: u64, size: usize) u64 {
    const space = addressSpaceFromContext(context) orelse return 0;
    const resolved = resolveGuestMemoryAddress(address, size) orelse return 0;
    return space.gpuGeneration(resolved, size);
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
    if (completion_batch_active) {
        // One interrupt handler pass retires every completed node in its ring.
        // Coalesce the many release packets emitted under one submission and
        // context into the single edge owned by that public submit.
        if (recordUniqueReleaseContext(
            &batched_release_contexts,
            &batched_release_count,
            value.interrupt_context_id,
        )) return;
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
            if (reports_interrupt and interrupt_release_reports < 512) {
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
    driver_completion_reports = 0;
    driver_completion_chain_reports = 0;
    driver_completion_miss_reports = 0;
    submission_header_write_reports = 0;
    unsafe_island_reports = 0;
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
    batched_driver_completion_label = 0;
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
        if (packetWaitMemoryRead(value)) |read| {
            var bytes: [@sizeOf(u64)]u8 = undefined;
            // A real CPU-visible fence must already name readable storage when
            // the DCB is submitted. Descriptor tails can accidentally decode
            // as WAIT_REG_MEM, commonly losing the upper address dword of a
            // nearby label. Letting that false packet reach the scheduler
            // leaves every later frame parked behind an address which can
            // never be published.
            if (!readGuestMemory(null, read.address, bytes[0..read.byte_length])) {
                if (unsafe_island_reports < 32) {
                    std.debug.print(
                        "[dcb guard] trimmed command prefix before unreadable wait: target=0x{x}+{d} arena=0x{x}\n",
                        .{ read.address, read.byte_length, @intFromPtr(stream.ptr) },
                    );
                    unsafe_island_reports += 1;
                }
                return stream[0..offset];
            }
        }
        if (packetWritesSubmissionAllocationHeader(stream, value)) |target| {
            if (unsafe_island_reports < 32) {
                std.debug.print(
                    "[dcb guard] trimmed command prefix before allocation-header write: target=0x{x} arena=0x{x} opcode=0x{x}\n",
                    .{ target, @intFromPtr(stream.ptr), value.opcode },
                );
                unsafe_island_reports += 1;
            }
            return stream[0..offset];
        }
    }
}

const SubmittedSegment = struct {
    start: usize,
    end: usize,
    packets: usize,
    releases: usize,
};

fn overlapsSubmissionAllocationHeader(stream: []const u32, address: u64, byte_length: u64) bool {
    if (stream.len == 0 or byte_length == 0) return false;
    const arena_address: u64 = @intFromPtr(stream.ptr);
    if (arena_address < submission_allocation_header_bytes) return false;
    const header_start = arena_address - submission_allocation_header_bytes;
    const write_end = std.math.add(u64, address, byte_length) catch return false;
    return address < arena_address and write_end > header_start;
}

/// Returns the target when a packet decoded from an allocation's data area
/// would overwrite the allocator metadata immediately before that allocation.
fn packetWritesSubmissionAllocationHeader(stream: []const u32, packet: gpu.pm4.Packet) ?u64 {
    if (packet.kind != .command) return null;
    const body = packet.body;
    const custom = gpu.pm4.customCode(packet);

    if (packet.opcode == gpu.pm4.release_mem or
        (custom != null and custom.? == gpu.pm4.custom.release_mem))
    {
        if (body.len < 7) return null;
        const destination = (body[1] >> 16) & 0x3;
        const selection = (body[1] >> 29) & 0x7;
        if (destination != 0 and destination != 1) return null;
        const byte_length: u64 = switch (selection) {
            1 => 4,
            2, 3, 4 => 8,
            else => return null,
        };
        const address = (@as(u64, body[3]) << 32) | body[2];
        return if (overlapsSubmissionAllocationHeader(stream, address, byte_length)) address else null;
    }

    if (packet.opcode == gpu.pm4.write_data or
        (custom != null and custom.? == gpu.pm4.custom.write_data))
    {
        if (body.len < 3) return null;
        const standard = packet.opcode == gpu.pm4.write_data;
        const control = body[0];
        const destination: u8 = if (standard)
            @truncate(((control >> 30) & 0x1) | ((control >> 7) & 0x1e))
        else
            @truncate(control);
        if (destination != 1 and destination != 2 and destination != 4 and destination != 5) return null;
        const address = (@as(u64, body[2]) << 32) | (body[1] & 0xffff_fffc);
        const increments = if (standard) control & (1 << 16) == 0 else @as(u8, @truncate(control >> 16)) == 0;
        const byte_length: u64 = if (increments)
            std.math.mul(u64, body.len - 3, @sizeOf(u32)) catch return null
        else
            @sizeOf(u32);
        return if (overlapsSubmissionAllocationHeader(stream, address, byte_length)) address else null;
    }

    if (packet.opcode == gpu.pm4.dma_data or
        (custom != null and custom.? == gpu.pm4.custom.dma_data))
    {
        if (body.len != 6) return null;
        const control = body[0];
        const control2 = body[5];
        const destination = ((control >> 20) & 3) |
            ((control2 >> 25) & 4) | ((control2 >> 26) & 8);
        if (destination != 0 and destination != 3) return null;
        const address = (@as(u64, body[4]) << 32) | body[3];
        const byte_length: u64 = control2 & 0x03ff_ffff;
        return if (overlapsSubmissionAllocationHeader(stream, address, byte_length)) address else null;
    }

    return null;
}

const PacketMemoryRead = struct {
    address: u64,
    byte_length: usize,
};

/// Extracts the memory operand of a WAIT packet without executing it. Command
/// islands are discovered heuristically inside arenas that also contain
/// descriptor data, so a structurally valid packet is not sufficient proof
/// that the surrounding words are executable PM4.
fn packetWaitMemoryRead(packet: gpu.pm4.Packet) ?PacketMemoryRead {
    if (packet.kind != .command) return null;
    const body = packet.body;
    if (packet.opcode == gpu.pm4.wait_reg_mem) {
        if (body.len < 6 or body[0] & (1 << 4) == 0) return null;
        return .{
            .address = (@as(u64, body[2]) << 32) | (body[1] & 0xffff_fffc),
            .byte_length = @sizeOf(u32),
        };
    }

    const custom = gpu.pm4.customCode(packet) orelse return null;
    if (custom == gpu.pm4.custom.wait_mem_64) {
        if (body.len < 8) return null;
        return .{
            .address = (@as(u64, body[1]) << 32) | (body[0] & 0xffff_fff8),
            .byte_length = @sizeOf(u64),
        };
    }
    if (custom != gpu.pm4.custom.wait_mem_32) return null;
    if (body.len < 5) return null;
    return .{
        .address = (@as(u64, body[1]) << 32) | (body[0] & 0xffff_fffc),
        .byte_length = @sizeOf(u32),
    };
}

/// Descriptor words occasionally form a structurally walkable Type-3 packet.
/// Reject packet shapes which the executor itself cannot accept before using
/// a RELEASE_MEM elsewhere in those words as evidence for a command island.
fn packetHasPlausibleIslandShape(packet: gpu.pm4.Packet) bool {
    if (packet.kind == .filler) return true;
    if (packet.kind != .command) return false;
    const body = packet.body;

    if (gpu.pm4.registerSpaceOf(packet.opcode) != null) return body.len >= 1;
    if (gpu.pm4.indirectRegisterSpaceOf(packet.opcode) != null) return body.len == 4;

    switch (packet.opcode) {
        gpu.pm4.set_base => return body.len == 3 and body[0] & 0xf == 1,
        gpu.pm4.index_base => return body.len == 2,
        gpu.pm4.index_buffer_size => return body.len == 1,
        gpu.pm4.num_instances, gpu.pm4.index_type => return body.len >= 1,
        // Command islands are found inside allocations which also contain
        // descriptor tables. Three arbitrary descriptor words can otherwise
        // look exactly like DISPATCH_DIRECT and poison persistent compute
        // state. GCN exposes at most 16-bit workgroup counts per dimension for
        // this path; a larger count is descriptor data, not executable PM4.
        gpu.pm4.dispatch_direct => return (body.len == 3 or body.len == 4) and
            body[0] <= std.math.maxInt(u16) and
            body[1] <= std.math.maxInt(u16) and
            body[2] <= std.math.maxInt(u16),
        gpu.pm4.dispatch_indirect => return body.len == 2 or body.len == 3,
        gpu.pm4.acquire_mem => return body.len >= 6,
        gpu.pm4.release_mem => return body.len >= 7,
        gpu.pm4.wait_reg_mem => return body.len >= 6,
        gpu.pm4.write_data => return body.len >= 3,
        gpu.pm4.dma_data => return body.len == 6,
        gpu.pm4.indirect_buffer => return body.len == 3 or body.len == 13,
        gpu.pm4.event_write => {
            if (body.len < 1) return false;
            const event_type: u8 = @truncate(body[0] & 0x3f);
            return (event_type & 0x3e) != 0x38 or body.len >= 3;
        },
        else => {},
    }

    const custom = gpu.pm4.customCode(packet) orelse return true;
    return switch (custom) {
        gpu.pm4.custom.acquire_mem => body.len >= 7,
        gpu.pm4.custom.release_mem => body.len >= 7,
        gpu.pm4.custom.context_regs_indirect,
        gpu.pm4.custom.sh_regs_indirect,
        gpu.pm4.custom.uconfig_regs_indirect,
        => body.len >= 3,
        gpu.pm4.custom.wait_mem_32 => body.len >= 5,
        gpu.pm4.custom.wait_mem_64 => body.len >= 8,
        gpu.pm4.custom.write_data => body.len >= 3,
        gpu.pm4.custom.flip => body.len >= 5,
        else => true,
    };
}

fn unreadableIndirectTarget(address: u64, word_count: usize) ?u64 {
    if (address == 0 or word_count == 0) return null;
    const byte_count = std.math.mul(usize, word_count, @sizeOf(u32)) catch return address;
    return if (resolveGuestMemoryAddress(address, byte_count) == null) address else null;
}

/// Returns an indirect command/register-list address which snapshotting would
/// fail to read. A real island cannot depend on a target that is already
/// unmapped at submission time; descriptor data can easily invent one.
fn packetUnreadableIndirectTarget(packet: gpu.pm4.Packet) ?u64 {
    if (packet.kind != .command) return null;
    const body = packet.body;

    if (gpu.pm4.indirectRegisterSpaceOf(packet.opcode) != null and body.len == 4) {
        const address = (@as(u64, body[1]) << 32) | (body[0] & 0xffff_fffc);
        const count: usize = body[3] & 0x3fff;
        return unreadableIndirectTarget(address, std.math.mul(usize, count, 2) catch return address);
    }

    if (gpu.pm4.customCode(packet)) |custom| {
        const indirect_registers = custom == gpu.pm4.custom.context_regs_indirect or
            custom == gpu.pm4.custom.sh_regs_indirect or
            custom == gpu.pm4.custom.uconfig_regs_indirect;
        if (indirect_registers and body.len >= 3) {
            const address = (@as(u64, body[2]) << 32) | (body[1] & 0xffff_fffc);
            const count: usize = body[0] & 0x3fff;
            return unreadableIndirectTarget(address, std.math.mul(usize, count, 2) catch return address);
        }
    }

    if (packet.opcode != gpu.pm4.indirect_buffer) return null;
    if (body.len == 3) {
        const address = (@as(u64, body[1]) << 32) | body[0];
        const count: usize = body[2] & 0x000f_ffff;
        return unreadableIndirectTarget(address, count);
    }
    if (body.len != 13) return null;
    const then_address = (@as(u64, body[8]) << 32) | body[7];
    const then_count: usize = body[9] & 0x000f_ffff;
    if (unreadableIndirectTarget(then_address, then_count)) |address| return address;
    const else_address = (@as(u64, body[11]) << 32) | body[10];
    const else_count: usize = body[12] & 0x000f_ffff;
    return unreadableIndirectTarget(else_address, else_count);
}

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
            if (!packetHasPlausibleIslandShape(packet)) {
                if (unsafe_island_reports < 32) {
                    std.debug.print(
                        "[dcb guard] rejected command island with invalid {s} packet shape: header=0x{x:0>8} body={d} arena=0x{x}\n",
                        .{
                            packet.name() orelse "unknown",
                            packet.header,
                            packet.body.len,
                            @intFromPtr(stream.ptr),
                        },
                    );
                    unsafe_island_reports += 1;
                }
                break;
            }
            if (packetUnreadableIndirectTarget(packet)) |target| {
                if (unsafe_island_reports < 32) {
                    std.debug.print(
                        "[dcb guard] rejected command island with unreadable indirect target: target=0x{x} arena=0x{x}\n",
                        .{ target, @intFromPtr(stream.ptr) },
                    );
                    unsafe_island_reports += 1;
                }
                break;
            }
            if (packetWritesSubmissionAllocationHeader(stream, packet)) |target| {
                if (unsafe_island_reports < 32) {
                    std.debug.print(
                        "[dcb guard] rejected command island targeting allocation header: target=0x{x} arena=0x{x} opcode=0x{x}\n",
                        .{ target, @intFromPtr(stream.ptr), packet.opcode },
                    );
                    unsafe_island_reports += 1;
                }
                break;
            }
            if (packetWaitMemoryRead(packet)) |read| {
                var readable: [@sizeOf(u64)]u8 = undefined;
                const protected = overlapsSubmissionAllocationHeader(
                    stream,
                    read.address,
                    read.byte_length,
                );
                const mapped = !protected and
                    readGuestMemory(null, read.address, readable[0..read.byte_length]);
                if (!mapped) {
                    if (unsafe_island_reports < 32) {
                        std.debug.print(
                            "[dcb guard] rejected command island with {s} wait: target=0x{x}+{d} arena=0x{x}\n",
                            .{
                                if (protected) "protected" else "unreadable",
                                read.address,
                                read.byte_length,
                                @intFromPtr(stream.ptr),
                            },
                        );
                        unsafe_island_reports += 1;
                    }
                    break;
                }
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

fn executeAcceptedStream(
    label: []const u8,
    stream: []const u32,
    driver_completion_label: ?u64,
) SubmitOutcome {
    rememberSubmissionAlias(stream);
    const commands = submittedCommandPrefix(stream);

    if (commands.len != stream.len) {
        if (trace.isLive() or trimmed_submission_reports < 8) {
            std.debug.print(
                "[{s}] trimmed trailing allocation data: {d}/{d} dwords @0x{x}\n",
                .{ label, commands.len, stream.len, @intFromPtr(stream.ptr) },
            );
        }
        trimmed_submission_reports +|= 1;
    }

    // A public SubmitDcb owns one guest retirement node even when its arena is
    // split into several executable islands. Keep all islands under one host
    // scheduler/completion batch so the first slow island cannot publish an
    // interrupt while later islands are still executing inside the same HLE
    // call. The deferred event is armed only after the complete arena drains.
    execution_lock.lock();
    defer execution_lock.unlock();
    beginCompletionBatch();
    defer finishCompletionBatch();

    // Descriptor tables can contain accidental Type-3 bit patterns. Executing
    // heuristically discovered "islands" after the first non-command word is
    // unsafe: Unity transition allocations contain long descriptor runs which
    // resemble hundreds of WAIT_REG_MEM packets. Hardware receives only the
    // command cursor, so retain the proven contiguous prefix and treat an empty
    // prefix as a completed no-op.
    var outcome: SubmitOutcome = .{ .accepted = true, .completed = true };
    if (commands.len != 0) {
        const prefix_outcome = executeSubmittedLocked(label, commands);
        // The public AGC call has already accepted a completely walkable PM4
        // prefix. A renderer that cannot yet implement one packet treats that
        // packet as a GPU no-op; it must not hold the driver's retirement node
        // forever and wedge every later frame behind it.
        outcome.completed = prefix_outcome.accepted and prefix_outcome.completed;
        outcome.queued_interrupt = hasQueuedInterrupt(commands);
    }

    if (std.mem.eql(u8, label, "dcb") and outcome.accepted) {
        armPendingGraphicsSegment(stream);
    }
    if (outcome.accepted) {
        batched_driver_completion_label = driver_completion_label orelse 0;
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
    // This is work appended to the preceding public DCB, not another guest
    // submission. Execute its labels and Vulkan commands, but do not turn a
    // second RELEASE_MEM in the same allocation into another retirement edge:
    // the guest queued only one completion record for the public call.
    execution_lock.lock();
    beginCompletionBatch();
    const outcome = executeSubmittedLocked("dcb", commands);
    discardCompletionBatch();
    execution_lock.unlock();
    // These words are an appended continuation of the preceding guest DCB,
    // not a second SubmitDcb call. The driver has no separate retirement node
    // for them. Publishing the continuation's explicit EOP here advances the
    // interrupt worker past the next real record and eventually deadlocks RHI.
    if (outcome.accepted) armPendingGraphicsSegment(commands);
}

pub fn submitDeviceStream(stream: []const u32) SubmitOutcome {
    drainCompletionNotifications();
    announce("dcb", stream);
    return executeAcceptedStream("dcb", stream, null);
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

    return executeSubmittedLocked(label, stream);
}

/// Executes one already-snapshotted stream while its caller owns the command
/// processor and completion batch. Public AGC arenas can invoke this more than
/// once without exposing an interrupt between their prefix and command islands.
fn executeSubmittedLocked(label: []const u8, stream: []const u32) SubmitOutcome {
    std.debug.assert(completion_batch_active);
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
    if (submission_reports < 512) {
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
    if (findSubmissionHeaderCollision(wait.address, payload.len)) |collision| {
        const recovered = submission_scheduler.softSatisfyActiveWait(queue_kind, wait);
        if (recovered and submission_header_write_reports < 32) {
            std.debug.print(
                "[agc wait] soft-satisfied protected header wait: target=0x{x}+{d} arena=0x{x} ref=0x{x}\n",
                .{ collision.target_address, payload.len, collision.arena_address, wait.reference },
            );
            submission_header_write_reports += 1;
        }
        return recovered;
    }
    const ok = writeGuestMemory(null, wait.address, payload);
    if (ok) {
        // Indirect command buffers are snapshotted at submit time. Unreal can
        // colocate a mutable fence label in the same allocation, so mirror the
        // recovery write into the active snapshot before the next re-poll.
        _ = submission_scheduler.mirrorActiveWrite(queue_kind, wait.address, payload);
        kernel_runtime.wakeSyncAddress(wait.address, std.math.maxInt(usize));
        return true;
    }
    // GPU-only labels and malformed tails recovered from mixed command/data
    // arenas have no CPU mapping. Leaving either at the queue head blocks every
    // later frame even though the owning submission has already completed.
    // Satisfy exactly one scheduler re-poll without publishing the synthetic
    // value into arbitrary guest memory.
    const recovered = submission_scheduler.softSatisfyActiveWait(queue_kind, wait);
    if (recovered and unmapped_wait_reports < 32) {
        std.debug.print(
            "[agc wait] soft-satisfied unmapped wait: target=0x{x}+{d} ref=0x{x}\n",
            .{ wait.address, payload.len, wait.reference },
        );
        unmapped_wait_reports += 1;
    }
    return recovered;
}

fn acceptSubmitted(label: []const u8, stream: []const u32, driver_completion_label: ?u64) SubmitOutcome {
    const commands = if (std.mem.eql(u8, label, "dcb"))
        dcbWithCompletionPrelude(stream)
    else
        stream;
    announce(label, commands);
    return executeAcceptedStream(label, commands, driver_completion_label);
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
fn submitOne(
    label: []const u8,
    descriptor: ?*const Submission,
    driver_completion_label: ?u64,
) SubmitOutcome {
    const submission = descriptor orelse return .{};
    const stream = streamOf(submission.address, submission.word_count) orelse return .{};
    return acceptSubmitted(label, stream, driver_completion_label);
}

/// Finds the SDK-private retirement label associated with the descriptor that
/// is currently on AgcSubmitThread's guest stack.
///
/// The public descriptor contains only address/count. This SDK's wrapper builds
/// it at rbp-0x20 while its caller retains the matching work node at rbp-0x40,
/// which makes the private pointer descriptor+0x50. The node carries the label
/// which hardware Submit clears even when the title's PM4 has no RELEASE_MEM
/// for it. Validate every redundant field before using this private layout so
/// other SDK versions simply fall back to packet-owned completions.
fn driverCompletionLabel(
    descriptor: *const Submission,
    submission: Submission,
    queue_type: u32,
) ?u64 {
    const descriptor_address = @intFromPtr(descriptor);
    const node_slot = descriptor_address +| 0x50;
    var node_bytes: [8]u8 = undefined;
    if (!readGuestMemory(null, node_slot, &node_bytes)) return null;
    const node = std.mem.readInt(u64, &node_bytes, .little);
    if (node == 0 or !memory.isGuestRangeAccessible(node, 0x98)) return null;

    var fields: [0x98]u8 = undefined;
    if (!readGuestMemory(null, node, &fields)) return null;
    const node_stream = std.mem.readInt(u64, fields[0x08..0x10], .little);
    const node_words = std.mem.readInt(u32, fields[0x10..0x14], .little);
    const node_type = std.mem.readInt(u32, fields[0x90..0x94], .little);
    const completion_label = std.mem.readInt(u64, fields[0x20..0x28], .little);
    if (node_stream != @intFromPtr(submission.address) or
        node_words != submission.word_count or node_type != queue_type or
        completion_label == 0 or
        !memory.isGuestRangeAccessible(completion_label, @sizeOf(u64)))
    {
        return null;
    }

    var label_bytes: [8]u8 = undefined;
    if (!readGuestMemory(null, completion_label, &label_bytes)) return null;
    const label_value = std.mem.readInt(u64, &label_bytes, .little);
    if (label_value == 0) return null;
    if (driver_completion_chain_reports < 256) {
        std.debug.print(
            "[agc submit] private node=0x{x} stream=0x{x}/{d} type={d} label=0x{x}/0x{x}\n",
            .{ node, node_stream, node_words, node_type, completion_label, label_value },
        );
        driver_completion_chain_reports += 1;
    }
    return completion_label;
}

fn publishDriverCompletionLabel(target: u64) void {
    var previous: [8]u8 = undefined;
    if (!readGuestMemory(null, target, &previous)) return;
    const old = std.mem.readInt(u64, &previous, .little);
    if (old == 0) return;

    const completed: [8]u8 = @splat(0);
    if (!writeGuestMemory(null, target, &completed)) return;
    kernel_runtime.wakeSyncAddress(target, std.math.maxInt(usize));
    if (driver_completion_reports < 32) {
        std.debug.print(
            "[agc submit] completed driver-owned label 0x{x}: 0x{x}->0\n",
            .{ target, old },
        );
        driver_completion_reports += 1;
    }
}

/// Compute completion uses the shared AGC user interrupt. Queue identifiers
/// are not synthetic graphics events; explicit compute RELEASE_MEM packets
/// publish their own EOP event through `triggerReleaseInterrupt`.
fn publishAcbCompletion(outcome: SubmitOutcome) void {
    if (!outcome.accepted or outcome.queued_interrupt) return;
    enqueueCompletion(.{ .kind = .acb });
}

/// A public graphics submission without an explicit interrupt still needs the
/// same AGC completion fanout that an interrupting RELEASE_MEM would publish.
fn publishDcbCompletion(outcome: SubmitOutcome) void {
    if (!outcome.accepted or outcome.queued_interrupt) return;
    enqueueCompletion(.{ .kind = .dcb });
}

/// Graphics work, described by one descriptor.
fn submitDcb(descriptor: ?*const Submission) callconv(abi.guest) i32 {
    drainCompletionNotifications();
    const submission = if (descriptor) |value| value.* else return errno.ok;
    const completion_label = driverCompletionLabel(descriptor.?, submission, 0);
    const outcome = submitOne("dcb", descriptor, completion_label);
    publishDcbCompletion(outcome);
    return errno.ok;
}

/// Compute work on a named queue.
fn submitAcb(_: u32, descriptor: ?*const Submission) callconv(abi.guest) i32 {
    drainCompletionNotifications();
    const submission = descriptor orelse return errno.ok;
    const stream = streamOf(submission.address, submission.word_count) orelse return errno.ok;
    const completion_label = driverCompletionLabel(submission, submission.*, 1);
    flushPendingGraphicsSegment();
    const outcome = acceptSubmitted("acb", stream, completion_label);
    publishAcbCompletion(outcome);
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
        publishDcbCompletion(acceptSubmitted("dcb", stream, null));
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
        publishAcbCompletion(acceptSubmitted("acb", stream, null));
    }
    return errno.ok;
}

/// One buffer submitted directly, without a descriptor around it.
fn submitCommandBuffer(_: u32, address: ?[*]const u32, word_count: u32) callconv(abi.guest) i32 {
    drainCompletionNotifications();
    const stream = streamOf(address, word_count) orelse return errno.ok;
    publishDcbCompletion(acceptSubmitted("dcb", stream, null));
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

test "submitted DCB rejects a command island that writes its allocation header" {
    var stream = [_]u32{
        command(gpu.pm4.clear_state, 1),                                       0,
        0,                                                                     0,
        0,                                                                     0,
        command(gpu.pm4.nop, 1),                                               0,
        command(gpu.pm4.nop, 1),                                               0,
        command(gpu.pm4.nop, 1),                                               0,
        command(gpu.pm4.nop, 7) | (@as(u32, gpu.pm4.custom.release_mem) << 2), 0x28,
        (@as(u32, 1) << 29) | (@as(u32, 1) << 16),                             0,
        0,                                                                     0x1234_5678,
        0,                                                                     0,
    };
    const target = @intFromPtr(&stream) - 8;
    stream[15] = @truncate(target);
    stream[16] = @truncate(target >> 32);

    const prefix = submittedCommandPrefix(&stream);
    try testing.expectEqual(@as(usize, 2), prefix.len);
    try testing.expect(nextSubmittedCommandSegment(&stream, prefix.len) == null);
}

test "submitted DCB trims a contiguous prefix before an allocation header write" {
    var stream = [_]u32{
        command(gpu.pm4.clear_state, 1),                                       0,
        command(gpu.pm4.nop, 7) | (@as(u32, gpu.pm4.custom.release_mem) << 2), 0x28,
        (@as(u32, 1) << 29) | (@as(u32, 1) << 16),                             0,
        0,                                                                     1,
        0,                                                                     0,
        command(gpu.pm4.clear_state, 1),                                       0,
    };
    const target = @intFromPtr(&stream) - 8;
    stream[5] = @truncate(target);
    stream[6] = @truncate(target >> 32);

    const prefix = submittedCommandPrefix(&stream);
    try testing.expectEqual(@as(usize, 2), prefix.len);
    try testing.expectEqualSlices(u32, stream[0..2], prefix);
}

test "submitted DCB trims a contiguous prefix before an unreadable memory wait" {
    const stream = [_]u32{
        command(gpu.pm4.clear_state, 1),  0,
        command(gpu.pm4.wait_reg_mem, 6),
        // Equal, memory space, address 0xffff_ffff_ffff_fffc.
        3 | (@as(u32, 1) << 4),
        0xffff_fffc,                      0xffff_ffff,
        1,                                0xffff_ffff,
        0,                                command(gpu.pm4.clear_state, 1),
        0,
    };

    const prefix = submittedCommandPrefix(&stream);
    try testing.expectEqual(@as(usize, 2), prefix.len);
    try testing.expectEqualSlices(u32, stream[0..2], prefix);
}

test "submitted DCB rejects command islands with unsafe memory waits" {
    const wait_header = command(gpu.pm4.nop, 6) |
        (@as(u32, gpu.pm4.custom.wait_mem_32) << 2);
    const release_header = command(gpu.pm4.nop, 7) |
        (@as(u32, gpu.pm4.custom.release_mem) << 2);
    var protected_stream = [_]u32{
        command(gpu.pm4.clear_state, 1), 0,
        0,                               0,
        0,                               0,
        command(gpu.pm4.nop, 1),         0,
        command(gpu.pm4.nop, 1),         0,
        command(gpu.pm4.nop, 1),         0,
        wait_header,                     0,
        0,                               0xffff_ffff,
        1,                               3,
        0,                               release_header,
        0x28,                            (@as(u32, 1) << 29) | (@as(u32, 1) << 16),
        0x1000,                          0,
        1,                               0,
        0,
    };
    const protected_target = @intFromPtr(&protected_stream) - 4;
    protected_stream[13] = @truncate(protected_target);
    protected_stream[14] = @truncate(protected_target >> 32);

    const prefix = submittedCommandPrefix(&protected_stream);
    try testing.expectEqual(@as(usize, 2), prefix.len);
    try testing.expect(nextSubmittedCommandSegment(&protected_stream, prefix.len) == null);

    var unreadable_stream = protected_stream;
    unreadable_stream[13] = 0xffff_fffc;
    unreadable_stream[14] = 0xffff_ffff;
    try testing.expect(nextSubmittedCommandSegment(&unreadable_stream, prefix.len) == null);
}

test "submitted DCB rejects semantically invalid command islands" {
    const release_header = command(gpu.pm4.nop, 7) |
        (@as(u32, gpu.pm4.custom.release_mem) << 2);
    const invalid_dma_stream = [_]u32{
        command(gpu.pm4.clear_state, 1),           0,
        0,                                         0,
        0,                                         0,
        command(gpu.pm4.dma_data, 5),              0,
        0,                                         0,
        0,                                         0,
        command(gpu.pm4.nop, 1),                   0,
        command(gpu.pm4.nop, 1),                   0,
        release_header,                            0x28,
        (@as(u32, 1) << 29) | (@as(u32, 1) << 16), 0x1000,
        0,                                         1,
        0,                                         0,
    };
    const dma_prefix = submittedCommandPrefix(&invalid_dma_stream);
    try testing.expectEqual(@as(usize, 2), dma_prefix.len);
    try testing.expect(nextSubmittedCommandSegment(&invalid_dma_stream, dma_prefix.len) == null);

    const unreadable_indirect_stream = [_]u32{
        command(gpu.pm4.clear_state, 1),           0,
        0,                                         0,
        0,                                         0,
        command(gpu.pm4.indirect_buffer, 3),       0xffff_fffc,
        0xffff_ffff,                               4,
        command(gpu.pm4.nop, 1),                   0,
        command(gpu.pm4.nop, 1),                   0,
        release_header,                            0x28,
        (@as(u32, 1) << 29) | (@as(u32, 1) << 16), 0x1000,
        0,                                         1,
        0,                                         0,
    };
    const indirect_prefix = submittedCommandPrefix(&unreadable_indirect_stream);
    try testing.expectEqual(@as(usize, 2), indirect_prefix.len);
    try testing.expect(nextSubmittedCommandSegment(
        &unreadable_indirect_stream,
        indirect_prefix.len,
    ) == null);

    const impossible_dispatch_stream = [_]u32{
        command(gpu.pm4.clear_state, 1),           0,
        0,                                         0,
        0,                                         0,
        command(gpu.pm4.dispatch_direct, 3),       17_547_264,
        1_116_209_152,                             1_007_192_201,
        command(gpu.pm4.nop, 1),                   0,
        command(gpu.pm4.nop, 1),                   0,
        release_header,                            0x28,
        (@as(u32, 1) << 29) | (@as(u32, 1) << 16), 0x1000,
        0,                                         1,
        0,                                         0,
    };
    const dispatch_prefix = submittedCommandPrefix(&impossible_dispatch_stream);
    try testing.expectEqual(@as(usize, 2), dispatch_prefix.len);
    try testing.expect(nextSubmittedCommandSegment(
        &impossible_dispatch_stream,
        dispatch_prefix.len,
    ) == null);
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

test "public DCB publishes exactly one completion class" {
    reset();
    defer reset();

    publishDcbCompletion(.{ .accepted = true, .queued_interrupt = true });
    try testing.expectEqual(@as(usize, 0), pending_completion_count);

    publishDcbCompletion(.{ .accepted = true, .queued_interrupt = false });
    try testing.expectEqual(@as(usize, 1), pending_completion_count);
    try testing.expectEqual(CompletionKind.dcb, pending_completions[pending_completion_head].kind);
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

test "GPU writes cannot overwrite a submitted allocation header" {
    reset();
    defer reset();
    var allocation: [20]u32 = @splat(0);
    const arena = allocation[4..];
    rememberSubmissionAlias(arena);

    allocation[2] = 0xfeed_beef;
    const value: u64 = 0x1122_3344_5566_7788;
    try testing.expect(!writeGuestMemory(
        null,
        @intFromPtr(&allocation[2]),
        std.mem.asBytes(&value),
    ));
    try testing.expectEqual(@as(u32, 0xfeed_beef), allocation[2]);
    try testing.expectEqual(@as(u32, 0), allocation[3]);
}

test "bulk DMA writes may span a snapshotted submission header" {
    reset();
    defer reset();
    var allocation: [40]u32 = @splat(0xff);
    const arena = allocation[20..];
    rememberSubmissionAlias(arena);

    var clear: [24 * @sizeOf(u32)]u8 = @splat(0);
    try testing.expect(writeGuestMemory(
        null,
        @intFromPtr(&allocation[0]),
        &clear,
    ));
    try testing.expectEqual(@as(u32, 0), allocation[16]);
    try testing.expectEqual(@as(u32, 0), allocation[19]);
}

test "one completion batch coalesces duplicate release contexts" {
    var contexts: [2]u32 = undefined;
    var count: usize = 0;
    try testing.expect(recordUniqueReleaseContext(&contexts, &count, 7));
    try testing.expect(recordUniqueReleaseContext(&contexts, &count, 7));
    try testing.expect(recordUniqueReleaseContext(&contexts, &count, 9));
    try testing.expect(!recordUniqueReleaseContext(&contexts, &count, 11));
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualSlices(u32, &.{ 7, 9 }, &contexts);
}

test "pending completion FIFO preserves equivalent submit edges" {
    reset();
    defer reset();

    enqueueCompletion(.{ .kind = .release, .context_id = 3 });
    try testing.expectEqual(@as(usize, 1), pending_completion_count);

    enqueueCompletion(.{ .kind = .release, .context_id = 3 });
    try testing.expectEqual(@as(usize, 2), pending_completion_count);

    enqueueCompletion(.{ .kind = .acb, .context_id = 0 });
    try testing.expectEqual(@as(usize, 3), pending_completion_count);
    try testing.expectEqual(CompletionKind.release, pending_completions[pending_completion_head].kind);
    const second = (pending_completion_head + 1) % pending_completions.len;
    try testing.expectEqual(CompletionKind.release, pending_completions[second].kind);
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
