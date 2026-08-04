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
//! Nothing is rendered yet. A submission is decoded into named commands for
//! tracing and applied to persistent command-processor state. Register writes,
//! labels, waits, events and flips therefore have their real ordering before a
//! rendering backend exists, and draw/dispatch callbacks form its boundary.
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

fn backendRead(_: ?*anyopaque, address: u64, bytes: []u8) bool {
    if (!memory.isGuestRangeAccessible(address, bytes.len)) return false;
    const source: [*]const u8 = @ptrFromInt(address);
    @memcpy(bytes, source[0..bytes.len]);
    return true;
}

fn backendWrite(_: ?*anyopaque, address: u64, bytes: []const u8) bool {
    if (!memory.isGuestRangeAccessible(address, bytes.len)) return false;
    const destination: [*]u8 = @ptrFromInt(address);
    @memcpy(destination[0..bytes.len], bytes);
    return true;
}

const shader_memory_reader = gpu.ShaderMemoryReader{
    .context = null,
    .read_fn = backendRead,
};

fn traceSurfaceLayout(layout: gpu.SurfaceLayout) void {
    std.debug.print(
        "    layout block={d}x{d}/{d} pitch={d} source={d} staging={d}\n",
        .{
            layout.block.width,
            layout.block.height,
            layout.block.bytes,
            layout.row_pitch_elements,
            layout.required_source_bytes,
            layout.staging_bytes,
        },
    );
}

fn traceImageLayout(image: gpu.ImageDescriptor) void {
    const layout = gpu.SurfaceLayout.fromImage(image) catch |err| {
        std.debug.print("    layout unavailable={s}\n", .{@errorName(err)});
        return;
    };
    traceSurfaceLayout(layout);
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

fn backendDraw(_: ?*anyopaque, state: *const gpu.State, _: gpu.pm4.Packet) bool {
    traceShaderBinding(state, .export_shader);
    traceShaderBinding(state, .geometry);
    traceShaderBinding(state, .vertex);
    traceShaderBinding(state, .hull);
    traceShaderBinding(state, .pixel);
    if (!trace.isLive() or traced_draw_states >= 16) return true;
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
        if (gpu.SurfaceLayout.fromDepthTarget(depth)) |layout| {
            traceSurfaceLayout(layout);
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
        if (gpu.SurfaceLayout.fromColorTarget(target)) |layout| {
            traceSurfaceLayout(layout);
        } else |err| {
            std.debug.print("    layout unavailable={s}\n", .{@errorName(err)});
        }
    }
    return true;
}

fn backendDispatch(_: ?*anyopaque, state: *const gpu.State, _: gpu.pm4.Packet) bool {
    traceShaderBinding(state, .compute);
    return true;
}

const executor_backend_vtable = gpu.DcbBackend.VTable{
    .read = backendRead,
    .write = backendWrite,
    .draw = backendDraw,
    .dispatch = backendDispatch,
};

const executor_backend = gpu.DcbBackend{
    .context = null,
    .vtable = &executor_backend_vtable,
};

var submission_scheduler = gpu.QueueScheduler.init(std.heap.page_allocator, executor_backend);

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
            std.debug.print("  {d:0>5}: <{s} at this word>\n", .{ offset, @errorName(err) });
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

/// Queues one submitted buffer and advances both command processors. A blocked
/// head retains its exact root/indirect continuation; a real release-label
/// write from the other queue makes the following pump resume it in place.
fn executeSubmitted(label: []const u8, stream: []const u32) void {
    execution_lock.lock();
    defer execution_lock.unlock();

    const kind: gpu.QueueKind = if (std.mem.eql(u8, label, "acb"))
        .compute
    else
        .graphics;
    const report = submission_scheduler.submit(kind, stream) catch |err| {
        if (trace.isLive()) {
            std.debug.print("[{s}] queue stopped: {s}\n", .{ label, @errorName(err) });
        }
        return;
    };
    if (!trace.isLive()) return;

    if (submission_scheduler.isBlocked(kind)) {
        const submitted_state = submission_scheduler.state(kind);
        const wait = submitted_state.blocked_wait.?;
        const continuation = submission_scheduler.continuation(kind).?;
        const resume_word = continuation.frames[0].resume_word;
        std.debug.print(
            "[{s}] blocked at root word {d} (depth {d}): WAIT_REG_MEM 0x{x} mask=0x{x} ref=0x{x}; {d} queued\n",
            .{
                label,
                resume_word,
                continuation.frame_count,
                wait.address,
                wait.mask,
                wait.reference,
                submission_scheduler.pendingCount(kind),
            },
        );
    }
    if (report.completed_submissions > 1) {
        std.debug.print(
            "[gpu queues] completed {d} submissions after cross-queue progress\n",
            .{report.completed_submissions},
        );
    }
}

fn acceptSubmitted(label: []const u8, stream: []const u32) void {
    announce(label, stream);
    executeSubmitted(label, stream);
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
fn submitOne(label: []const u8, descriptor: ?*const Submission) void {
    const submission = descriptor orelse return;
    const stream = streamOf(submission.address, submission.word_count) orelse return;
    acceptSubmitted(label, stream);
}

/// Graphics work, described by one descriptor.
fn submitDcb(descriptor: ?*const Submission) callconv(abi.guest) i32 {
    submitOne("dcb", descriptor);
    return errno.ok;
}

/// Compute work on a named queue.
fn submitAcb(_: u32, descriptor: ?*const Submission) callconv(abi.guest) i32 {
    submitOne("acb", descriptor);
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
        acceptSubmitted("dcb", stream);
    }
    return errno.ok;
}

/// One buffer submitted directly, without a descriptor around it.
fn submitCommandBuffer(_: u32, address: ?[*]const u32, word_count: u32) callconv(abi.guest) i32 {
    const stream = streamOf(address, word_count) orelse return errno.ok;
    acceptSubmitted("dcb", stream);
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
    try testing.expectEqual(errno.ok, submitCommandBuffer(0, null, 0));

    // Naming a count but no arrays is a caller error, and saying so costs
    // nothing because there is no frame described anywhere to lose.
    try testing.expectEqual(errno.KernelError.einval.raw(), submitMultiDcbs(null, null, 2));
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
