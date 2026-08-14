// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Executes the stateful, externally visible part of a direct command buffer.
//!
//! The executor owns no guest memory and no rendering API. Both are supplied
//! by `Backend`, which makes the same command processor usable by the live HLE,
//! deterministic tests and the Vulkan renderer that will consume draw and
//! dispatch callbacks later.

const std = @import("std");
const pm4 = @import("pm4.zig");
const gpu_state = @import("state.zig");

pub const Error = pm4.Error || gpu_state.Error || std.mem.Allocator.Error || error{
    InvalidPacket,
    InvalidContinuation,
    IndirectBufferCycle,
    IndirectBufferTooDeep,
    MemoryReadFailed,
    MemoryWriteFailed,
    BackendRejected,
};

/// Host services visible to the command processor.
///
/// Reads and writes are mandatory because indirect registers and GPU labels
/// live in guest memory. Handlers are optional; a state-only consumer can omit
/// them, while a renderer implements ordered release/write operations plus
/// draw/dispatch and presentation. When a release or write-data handler exists,
/// it owns that operation so an asynchronous renderer can publish it at the
/// correct point instead of receiving an eager host-memory write.
pub const Backend = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (?*anyopaque, u64, []u8) bool,
        write: *const fn (?*anyopaque, u64, []const u8) bool,
        acquire: ?*const fn (?*anyopaque, gpu_state.AcquireMem) bool = null,
        release: ?*const fn (?*anyopaque, gpu_state.ReleaseMem) bool = null,
        wait: ?*const fn (?*anyopaque, gpu_state.WaitRegMem, bool) bool = null,
        write_data: ?*const fn (?*anyopaque, gpu_state.WriteData, []const u32) bool = null,
        dma_data: ?*const fn (?*anyopaque, gpu_state.DmaData) bool = null,
        event: ?*const fn (?*anyopaque, gpu_state.EventWrite) bool = null,
        flip: ?*const fn (?*anyopaque, gpu_state.Flip) bool = null,
        draw: ?*const fn (?*anyopaque, *const gpu_state.State, pm4.Packet) bool = null,
        dispatch: ?*const fn (?*anyopaque, *const gpu_state.State, pm4.Packet) bool = null,
    };

    fn read(self: Backend, address: u64, bytes: []u8) Error!void {
        if (!self.vtable.read(self.context, address, bytes)) return Error.MemoryReadFailed;
    }

    fn write(self: Backend, address: u64, bytes: []const u8) Error!void {
        if (!self.vtable.write(self.context, address, bytes)) return Error.MemoryWriteFailed;
    }
};

pub const Status = enum { complete, blocked };

/// Root DCB plus at most fifteen active indirect buffers. The fixed bound makes
/// malformed self-referential streams a reported guest error instead of host
/// stack exhaustion.
pub const maximum_stream_depth: usize = 16;

pub const Continuation = struct {
    pub const Frame = struct {
        /// Zero for the root slice supplied by the caller.
        address: u64 = 0,
        word_count: usize = 0,
        resume_word: usize = 0,
    };

    frame_count: u8 = 0,
    frames: [maximum_stream_depth]Frame = [_]Frame{.{}} ** maximum_stream_depth,
};

pub const Result = struct {
    status: Status,
    /// Root-stream word at which execution should resume. For a nested wait it
    /// points to the outer indirect packet; `continuation` carries child words.
    resume_word: usize,
    /// Full root-to-leaf path when a wait blocked inside an indirect buffer.
    /// Passing it to `DcbExecutor.resumeFrom` avoids replaying earlier child work.
    continuation: ?Continuation,
    packets: usize,
    draws: usize,
    dispatches: usize,
};

const PacketOutcome = enum { complete, blocked };

pub const DcbExecutor = struct {
    state: *gpu_state.State,
    backend: Backend,
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn execute(self: *DcbExecutor, stream: []const u32) Error!Result {
        return self.executeFrom(stream, 0);
    }

    pub fn executeFrom(self: *DcbExecutor, stream: []const u32, start_word: usize) Error!Result {
        if (start_word > stream.len) return Error.InvalidPacket;

        var result = Result{
            .status = .complete,
            .resume_word = start_word,
            .continuation = null,
            .packets = 0,
            .draws = 0,
            .dispatches = 0,
        };
        var active_addresses: [maximum_stream_depth]u64 = undefined;
        const blocked = try self.executeStream(
            stream,
            start_word,
            .{ .word_count = stream.len, .resume_word = start_word },
            0,
            &active_addresses,
            null,
            &result,
        );
        if (blocked) {
            result.status = .blocked;
            result.resume_word = result.continuation.?.frames[0].resume_word;
        } else {
            result.resume_word = stream.len;
        }
        return result;
    }

    /// Re-enters a blocked root or nested wait without replaying packets that
    /// precede it in any active indirect buffer.
    pub fn resumeFrom(self: *DcbExecutor, stream: []const u32, continuation: Continuation) Error!Result {
        if (continuation.frame_count == 0) return Error.InvalidContinuation;
        const root = continuation.frames[0];
        if (root.address != 0 or root.word_count != stream.len or root.resume_word > stream.len) {
            return Error.InvalidContinuation;
        }

        var result = Result{
            .status = .complete,
            .resume_word = root.resume_word,
            .continuation = null,
            .packets = 0,
            .draws = 0,
            .dispatches = 0,
        };
        var active_addresses: [maximum_stream_depth]u64 = undefined;
        const blocked = try self.executeStream(
            stream,
            root.resume_word,
            root,
            0,
            &active_addresses,
            &continuation,
            &result,
        );
        if (blocked) {
            result.status = .blocked;
            result.resume_word = result.continuation.?.frames[0].resume_word;
        } else {
            result.resume_word = stream.len;
        }
        return result;
    }

    fn executeStream(
        self: *DcbExecutor,
        stream: []const u32,
        start_word: usize,
        descriptor: Continuation.Frame,
        depth: usize,
        active_addresses: *[maximum_stream_depth]u64,
        resume_path: ?*const Continuation,
        result: *Result,
    ) Error!bool {
        if (depth >= maximum_stream_depth or start_word > stream.len) return Error.InvalidContinuation;
        if (resume_path) |continuation| {
            if (depth >= continuation.frame_count) return Error.InvalidContinuation;
            const expected = continuation.frames[depth];
            if (expected.address != descriptor.address or
                expected.word_count != descriptor.word_count or
                expected.resume_word != start_word)
            {
                return Error.InvalidContinuation;
            }
        }

        var walker = pm4.Walker.init(stream);
        walker.index = start_word;

        while (true) {
            const packet_word = walker.index;
            const packet = (try walker.next()) orelse return false;
            result.packets += 1;

            const resumes_child = if (resume_path) |continuation|
                depth + 1 < continuation.frame_count and packet_word == continuation.frames[depth].resume_word
            else
                false;

            if (packet.kind == .command and packet.opcode == pm4.indirect_buffer) {
                const indirect = try self.executeIndirectBuffer(
                    packet,
                    depth,
                    active_addresses,
                    if (resumes_child) resume_path else null,
                    result,
                );
                if (indirect.blocked) {
                    setContinuationFrame(result, depth, descriptor, packet_word);
                    return true;
                }
                self.state.indirect_buffer_count += 1;
                self.state.packets_executed += 1;
                if (indirect.chain) return false;
                continue;
            }
            if (resumes_child) return Error.InvalidContinuation;

            const outcome = self.executePacket(packet, result) catch |err| {
                std.debug.print(
                    "[gpu executor] packet rejected depth={d} stream=0x{x} word={d}/{d} header=0x{x:0>8} op={s}: {s}\n",
                    .{
                        depth,
                        descriptor.address,
                        packet_word,
                        stream.len,
                        packet.header,
                        packet.name() orelse "unknown",
                        @errorName(err),
                    },
                );
                return err;
            };
            if (outcome == .blocked) {
                setContinuationFrame(result, depth, descriptor, packet_word);
                return true;
            }

            self.state.packets_executed += 1;
        }
    }

    const IndirectOutcome = struct { blocked: bool, chain: bool };

    fn executeIndirectBuffer(
        self: *DcbExecutor,
        packet: pm4.Packet,
        depth: usize,
        active_addresses: *[maximum_stream_depth]u64,
        resume_path: ?*const Continuation,
        result: *Result,
    ) Error!IndirectOutcome {
        if (packet.body.len == 13) {
            return self.executeConditionalIndirectBuffer(
                packet.body,
                depth,
                active_addresses,
                resume_path,
                result,
            );
        }
        if (packet.body.len != 3) return Error.InvalidPacket;
        if (packet.body[0] & 0x3 != 0) return Error.InvalidPacket;

        const control = packet.body[2];
        const address = (@as(u64, packet.body[1]) << 32) | packet.body[0];
        const word_count: usize = control & 0x000f_ffff;
        const chain = control & (1 << 20) != 0;
        if (word_count == 0) return .{ .blocked = false, .chain = chain };
        return self.executeIndirectTarget(
            address,
            word_count,
            chain,
            depth,
            active_addresses,
            resume_path,
            result,
        );
    }

    /// Gen5 also uses the 14-dword form as a memory-tested branch selecting a
    /// then/else indirect stream. Once a selected child blocks, its saved
    /// continuation fixes that choice even if the compare value changes before
    /// resume.
    fn executeConditionalIndirectBuffer(
        self: *DcbExecutor,
        body: []const u32,
        depth: usize,
        active_addresses: *[maximum_stream_depth]u64,
        resume_path: ?*const Continuation,
        result: *Result,
    ) Error!IndirectOutcome {
        const mode = body[0] & 0x3;
        const function: u8 = @truncate((body[0] >> 8) & 0x7);
        if ((mode != 1 and mode != 2) or function > 6) return Error.InvalidPacket;
        if (body[1] & 0x7 != 0 or body[7] & 0x3 != 0 or body[10] & 0x3 != 0) {
            return Error.InvalidPacket;
        }

        const then_address = (@as(u64, body[8]) << 32) | body[7];
        const then_count: usize = body[9] & 0x000f_ffff;
        const else_address = (@as(u64, body[11]) << 32) | body[10];
        const else_count: usize = body[12] & 0x000f_ffff;
        if (then_address == 0 or then_count == 0) return Error.InvalidPacket;

        var selected_address: u64 = 0;
        var selected_count: usize = 0;
        if (resume_path) |continuation| {
            if (depth + 1 >= continuation.frame_count) return Error.InvalidContinuation;
            const expected = continuation.frames[depth + 1];
            if (expected.address == then_address and expected.word_count == then_count) {
                selected_address = then_address;
                selected_count = then_count;
            } else if (mode == 2 and expected.address == else_address and expected.word_count == else_count) {
                selected_address = else_address;
                selected_count = else_count;
            } else {
                return Error.InvalidContinuation;
            }
        } else {
            const compare_address = (@as(u64, body[2]) << 32) | body[1];
            if (compare_address == 0) return Error.InvalidPacket;
            const mask = (@as(u64, body[4]) << 32) | body[3];
            const reference = (@as(u64, body[6]) << 32) | body[5];
            const take_then = compareWait(try self.readU64(compare_address), reference, mask, function);
            if (take_then) {
                selected_address = then_address;
                selected_count = then_count;
            } else if (mode == 2 and else_count != 0) {
                if (else_address == 0) return Error.InvalidPacket;
                selected_address = else_address;
                selected_count = else_count;
            }
        }

        if (selected_count == 0) return .{ .blocked = false, .chain = false };
        return self.executeIndirectTarget(
            selected_address,
            selected_count,
            false,
            depth,
            active_addresses,
            resume_path,
            result,
        );
    }

    fn executeIndirectTarget(
        self: *DcbExecutor,
        address: u64,
        word_count: usize,
        chain: bool,
        depth: usize,
        active_addresses: *[maximum_stream_depth]u64,
        resume_path: ?*const Continuation,
        result: *Result,
    ) Error!IndirectOutcome {
        if (depth + 1 >= maximum_stream_depth) return Error.IndirectBufferTooDeep;
        if (address == 0 or address & 0x3 != 0) return Error.InvalidPacket;
        for (active_addresses[0..depth]) |active| {
            if (active == address) return Error.IndirectBufferCycle;
        }
        active_addresses[depth] = address;

        const child_descriptor = Continuation.Frame{
            .address = address,
            .word_count = word_count,
            .resume_word = 0,
        };
        var child_start: usize = 0;
        if (resume_path) |continuation| {
            if (depth + 1 >= continuation.frame_count) return Error.InvalidContinuation;
            const expected = continuation.frames[depth + 1];
            if (expected.address != address or expected.word_count != word_count) {
                return Error.InvalidContinuation;
            }
            child_start = expected.resume_word;
        }

        const child = try self.allocator.alloc(u32, word_count);
        defer self.allocator.free(child);
        try self.backend.read(address, std.mem.sliceAsBytes(child));

        var resumed_descriptor = child_descriptor;
        resumed_descriptor.resume_word = child_start;
        const blocked = try self.executeStream(
            child,
            child_start,
            resumed_descriptor,
            depth + 1,
            active_addresses,
            resume_path,
            result,
        );
        return .{ .blocked = blocked, .chain = chain };
    }

    fn executePacket(self: *DcbExecutor, packet: pm4.Packet, result: *Result) Error!PacketOutcome {
        switch (packet.kind) {
            .filler => return .complete,
            .reserved => unreachable,
            .register_write => {
                try self.writeTypeZeroRegisters(packet);
                return .complete;
            },
            .command => {},
        }

        if (pm4.registerSpaceOf(packet.opcode)) |space| {
            try self.writeDirectRegisters(space, packet.body);
            return .complete;
        }
        if (pm4.indirectRegisterSpaceOf(packet.opcode)) |space| {
            try self.writeIndirectRegisters(space, packet.body);
            return .complete;
        }

        if (packet.opcode == pm4.clear_state) {
            self.state.clearRegisters();
            return .complete;
        }
        if (packet.opcode == pm4.set_base) {
            if (packet.body.len != 3 or packet.body[0] & 0xf != 1) return Error.InvalidPacket;
            const address = (@as(u64, packet.body[2] & 0xffff) << 32) |
                (packet.body[1] & 0xffff_fff8);
            if (packet.compute) {
                self.state.dispatch_indirect_args_base_address = address;
            } else {
                self.state.draw_indirect_args_base_address = address;
            }
            return .complete;
        }
        if (packet.opcode == pm4.num_instances) {
            if (packet.body.len < 1) return Error.InvalidPacket;
            self.state.instance_count = @max(packet.body[0], 1);
            return .complete;
        }
        if (packet.opcode == pm4.index_base) {
            if (packet.body.len != 2) return Error.InvalidPacket;
            self.state.index_base_address = (@as(u64, packet.body[1]) << 32) | packet.body[0];
            return .complete;
        }
        if (packet.opcode == pm4.index_buffer_size) {
            if (packet.body.len != 1) return Error.InvalidPacket;
            self.state.index_buffer_size = packet.body[0];
            return .complete;
        }
        if (packet.opcode == pm4.index_type) {
            if (packet.body.len < 1) return Error.InvalidPacket;
            self.state.index_type = @truncate(packet.body[0]);
            return .complete;
        }

        if (packet.opcode == pm4.acquire_mem) {
            try self.acquireMem(packet, true);
            return .complete;
        }
        if (packet.opcode == pm4.release_mem) {
            try self.releaseMem(packet, true);
            return .complete;
        }
        if (packet.opcode == pm4.wait_reg_mem) {
            return self.waitRegMem(packet, true, false);
        }
        if (packet.opcode == pm4.write_data) {
            try self.writeData(packet, true);
            return .complete;
        }
        if (packet.opcode == pm4.dma_data) {
            try self.dmaData(packet);
            return .complete;
        }
        if (packet.opcode == pm4.event_write) {
            try self.eventWrite(packet);
            return .complete;
        }

        if (pm4.customCode(packet)) |code| {
            switch (code) {
                pm4.custom.acquire_mem => try self.acquireMem(packet, false),
                pm4.custom.release_mem => try self.releaseMem(packet, false),
                pm4.custom.context_regs_indirect => try self.writeLegacyIndirectRegisters(.context, packet.body),
                pm4.custom.sh_regs_indirect => try self.writeLegacyIndirectRegisters(.shader, packet.body),
                pm4.custom.uconfig_regs_indirect => try self.writeLegacyIndirectRegisters(.uconfig, packet.body),
                pm4.custom.wait_mem_32 => return self.waitRegMem(packet, false, false),
                pm4.custom.wait_mem_64 => return self.waitRegMem(packet, false, true),
                pm4.custom.write_data => try self.writeData(packet, false),
                pm4.custom.flip => try self.setFlip(packet),
                // WaitUntilSafeForRendering: labels are released on the next flip
                // of a different buffer. Bring-up treats the wait as already
                // satisfied so a second frame can be built without parking the CP.
                pm4.custom.wait_flip_done => {},
                else => {},
            }
            return .complete;
        }

        if (pm4.isDraw(packet.opcode)) {
            self.state.draw_count += 1;
            result.draws += 1;
            if (self.backend.vtable.draw) |callback| {
                if (!callback(self.backend.context, self.state, packet)) return Error.BackendRejected;
            }
        } else if (pm4.isDispatch(packet.opcode)) {
            self.state.dispatch_count += 1;
            result.dispatches += 1;
            if (self.backend.vtable.dispatch) |callback| {
                if (!callback(self.backend.context, self.state, packet)) return Error.BackendRejected;
            }
        }
        return .complete;
    }

    fn writeTypeZeroRegisters(self: *DcbExecutor, packet: pm4.Packet) Error!void {
        for (packet.body, 0..) |value, index| {
            const absolute = @as(u32, packet.base_register) + @as(u32, @intCast(index));
            const location = registerLocation(absolute) orelse continue;
            try self.state.writeRegister(location.space, location.offset, value);
        }
    }

    fn writeDirectRegisters(
        self: *DcbExecutor,
        space: pm4.RegisterSpace,
        body: []const u32,
    ) Error!void {
        if (body.len < 1) return Error.InvalidPacket;
        const first = body[0] & 0xffff;
        for (body[1..], 0..) |value, index| {
            try self.state.writeRegister(space, first + @as(u32, @intCast(index)), value);
        }
        if (space == .uconfig and first <= 0x243 and first + body.len - 1 > 0x243) {
            self.state.index_type = @truncate(body[1 + 0x243 - first]);
        }
    }

    fn writeIndirectRegisters(
        self: *DcbExecutor,
        space: pm4.RegisterSpace,
        body: []const u32,
    ) Error!void {
        if (body.len != 4) return Error.InvalidPacket;
        const address = (@as(u64, body[1]) << 32) | (body[0] & 0xffff_fffc);
        const count = body[3] & 0x3fff;

        try self.writeIndirectRegisterList(space, address, count);
    }

    /// Early Gen5 libraries wrap the same list as a custom NOP containing
    /// `{count, address_lo, address_hi}`. Captures and replacement libraries
    /// contain both this form and the native 0x63/0x64/0x9f packets.
    fn writeLegacyIndirectRegisters(
        self: *DcbExecutor,
        space: pm4.RegisterSpace,
        body: []const u32,
    ) Error!void {
        if (body.len < 3) return Error.InvalidPacket;
        const count = body[0] & 0x3fff;
        const address = (@as(u64, body[2]) << 32) | (body[1] & 0xffff_fffc);
        try self.writeIndirectRegisterList(space, address, count);
    }

    fn writeIndirectRegisterList(
        self: *DcbExecutor,
        space: pm4.RegisterSpace,
        address: u64,
        count: u32,
    ) Error!void {
        var pair: [8]u8 = undefined;
        for (0..count) |index| {
            try self.backend.read(address + @as(u64, index) * pair.len, &pair);
            const raw_offset = std.mem.readInt(u32, pair[0..4], .little);
            const value = std.mem.readInt(u32, pair[4..8], .little);
            if (raw_offset == std.math.maxInt(u32)) continue;
            const offset = normalizeIndirectOffset(space, raw_offset);
            // AGC register lists can carry generation-specific extension and
            // pseudo-register selectors alongside ordinary hardware state.
            // They do not fit the architectural register files we retain and
            // are intentionally skipped by real-world Gen5 command processors;
            // rejecting one here would discard every later draw and flip.
            if (!indirectOffsetTracked(space, offset)) {
                continue;
            }
            try self.state.writeRegister(space, offset, value);
        }
    }

    fn acquireMem(self: *DcbExecutor, packet: pm4.Packet, standard: bool) Error!void {
        const body = packet.body;
        const acquire = if (standard) blk: {
            if (body.len < 6) return Error.InvalidPacket;
            break :blk gpu_state.AcquireMem{
                .engine = @intFromBool(packet.compute),
                .cb_db_control = 0,
                .size_bytes = units256(body[1], body[2], 8),
                .base_address = units256(body[3], body[4], 24),
                .poll_interval = body[5],
                .gcr_control = body[0],
                .standard_packet = true,
            };
        } else blk: {
            if (body.len < 7) return Error.InvalidPacket;
            break :blk gpu_state.AcquireMem{
                .engine = @truncate(body[0] >> 31),
                .cb_db_control = body[0] & 0x7fff_ffff,
                .size_bytes = units256(body[1], body[2], 8),
                .base_address = units256(body[3], body[4], 24),
                .poll_interval = body[5],
                .gcr_control = body[6],
                .standard_packet = false,
            };
        };

        self.state.last_acquire = acquire;
        self.state.acquire_count += 1;
        if (self.backend.vtable.acquire) |callback| {
            if (!callback(self.backend.context, acquire)) return Error.BackendRejected;
        }
    }

    fn releaseMem(self: *DcbExecutor, packet: pm4.Packet, standard: bool) Error!void {
        const body = packet.body;
        if (body.len < 7) return Error.InvalidPacket;

        const release = gpu_state.ReleaseMem{
            .event_type = @truncate(body[0]),
            .event_index = @truncate((body[0] >> 8) & 0x7),
            .gcr_control = @truncate((body[0] >> 12) & 0x0fff),
            .cache_policy = @truncate((body[0] >> 25) & 0x3),
            .destination = @truncate((body[1] >> 16) & 0x3),
            .interrupt = @truncate((body[1] >> 24) & 0x7),
            .data_selection = @truncate((body[1] >> 29) & 0x7),
            .address = (@as(u64, body[3]) << 32) | body[2],
            .data = (@as(u64, body[5]) << 32) | body[4],
            .interrupt_context_id = body[6] & 0x07ff_ffff,
            .standard_packet = standard,
        };

        self.state.last_release = release;
        self.state.release_count += 1;

        if (self.backend.vtable.release) |callback| {
            if (!callback(self.backend.context, release)) return Error.BackendRejected;
        } else if ((release.destination == 0 or release.destination == 1) and release.address != 0) {
            switch (release.data_selection) {
                1 => try self.writeU32(release.address, @truncate(release.data)),
                2 => try self.writeU64(release.address, release.data),
                // Selections 3/4 are sampled counters and 5 is GDS. A backend
                // can implement those without mistaking packet payload for time.
                else => {},
            }
        }
    }

    fn waitRegMem(
        self: *DcbExecutor,
        packet: pm4.Packet,
        standard: bool,
        is_64_bit: bool,
    ) Error!PacketOutcome {
        const body = packet.body;
        const wait = if (standard) blk: {
            if (body.len < 6) return Error.InvalidPacket;
            break :blk gpu_state.WaitRegMem{
                .width = .bits_32,
                .memory_space = body[0] & (1 << 4) != 0,
                .address = if (body[0] & (1 << 4) != 0)
                    (@as(u64, body[2]) << 32) | (body[1] & 0xffff_fffc)
                else
                    body[1],
                .reference = body[3],
                .mask = body[4],
                .compare_function = @truncate(body[0] & 0x7),
                .operation = @truncate((body[0] >> 6) & 0x3),
                .poll_interval = body[5],
                .standard_packet = true,
            };
        } else if (is_64_bit) blk: {
            if (body.len < 8) return Error.InvalidPacket;
            break :blk gpu_state.WaitRegMem{
                .width = .bits_64,
                .memory_space = true,
                .address = (@as(u64, body[1]) << 32) | (body[0] & 0xffff_fff8),
                .mask = (@as(u64, body[3]) << 32) | body[2],
                .reference = (@as(u64, body[5]) << 32) | body[4],
                .compare_function = @truncate(body[6] & 0x7),
                .operation = decodeWaitOperation(body[6], true),
                .poll_interval = body[7],
                .standard_packet = false,
            };
        } else blk: {
            if (body.len == 5) {
                break :blk gpu_state.WaitRegMem{
                    .width = .bits_32,
                    .memory_space = true,
                    .address = (@as(u64, body[1]) << 32) | (body[0] & 0xffff_fffc),
                    .mask = body[2],
                    .reference = body[4],
                    .compare_function = @truncate(body[3] & 0x7),
                    .operation = decodeWaitOperation(body[3], false),
                    .poll_interval = 0,
                    .standard_packet = false,
                };
            }
            if (body.len < 6) return Error.InvalidPacket;
            break :blk gpu_state.WaitRegMem{
                .width = .bits_32,
                .memory_space = true,
                .address = (@as(u64, body[1]) << 32) | (body[0] & 0xffff_fffc),
                .mask = body[2],
                .reference = body[3],
                .compare_function = @truncate(body[4] & 0x7),
                .operation = decodeWaitOperation(body[4], false),
                .poll_interval = body[5],
                .standard_packet = false,
            };
        };

        const value = if (!wait.memory_space)
            self.readTrackedRegister(@truncate(wait.address))
        else switch (wait.width) {
            .bits_32 => @as(u64, try self.readU32(wait.address)),
            .bits_64 => try self.readU64(wait.address),
        };
        const satisfied = compareWait(value, wait.reference, wait.mask, wait.compare_function);
        self.state.last_wait = wait;
        self.state.wait_count += 1;
        self.state.blocked_wait = if (satisfied) null else wait;
        if (self.backend.vtable.wait) |callback| {
            if (!callback(self.backend.context, wait, satisfied)) return Error.BackendRejected;
        }
        return if (satisfied) .complete else .blocked;
    }

    fn writeData(self: *DcbExecutor, packet: pm4.Packet, standard: bool) Error!void {
        const body = packet.body;
        if (body.len < 3) return Error.InvalidPacket;
        const control = body[0];
        const destination: u8 = if (standard)
            @truncate(((control >> 30) & 0x1) | ((control >> 7) & 0x1e))
        else
            @truncate(control);
        const info = gpu_state.WriteData{
            .destination = destination,
            .cache_policy = if (standard) @truncate((control >> 25) & 0x3) else @truncate(control >> 8),
            .increment_address = if (standard) control & (1 << 16) == 0 else @as(u8, @truncate(control >> 16)) == 0,
            .write_confirm = if (standard) control & (1 << 20) != 0 else @as(u8, @truncate(control >> 24)) != 0,
            .address = (@as(u64, body[2]) << 32) | (body[1] & 0xffff_fffc),
            .word_count = @intCast(body.len - 3),
            .standard_packet = standard,
        };
        const values = body[3..];

        if (self.backend.vtable.write_data) |callback| {
            if (!callback(self.backend.context, info, values)) return Error.BackendRejected;
        } else if (destination == 1 or destination == 2 or destination == 4 or destination == 5) {
            for (values, 0..) |value, index| {
                const target = info.address + if (info.increment_address) @as(u64, index) * 4 else 0;
                try self.writeU32(target, value);
            }
        }
        self.state.last_write = info;
        self.state.write_data_count += 1;
    }

    fn dmaData(self: *DcbExecutor, packet: pm4.Packet) Error!void {
        if (packet.body.len != 6) return Error.InvalidPacket;
        const body = packet.body;
        const control = body[0];
        const control2 = body[5];
        const value = gpu_state.DmaData{
            .engine = @truncate(control & 1),
            .source = @truncate(((control >> 29) & 3) |
                ((control2 >> 24) & 4) | ((control2 >> 25) & 8)),
            .source_cache_policy = @truncate((control >> 13) & 3),
            .source_address = (@as(u64, body[2]) << 32) | body[1],
            .destination = @truncate(((control >> 20) & 3) |
                ((control2 >> 25) & 4) | ((control2 >> 26) & 8)),
            .destination_cache_policy = @truncate((control >> 25) & 3),
            .destination_address = (@as(u64, body[4]) << 32) | body[3],
            .byte_count = control2 & 0x03ff_ffff,
            .wait_for_previous = control2 & (1 << 30) != 0,
            .write_confirm = control2 & (1 << 31) != 0,
            .block_engine = control & (1 << 31) != 0,
        };

        if (self.backend.vtable.dma_data) |callback| {
            if (!callback(self.backend.context, value)) return Error.BackendRejected;
        } else if ((value.destination == 0 or value.destination == 3) and value.byte_count != 0) {
            const byte_count = std.math.cast(usize, value.byte_count) orelse return Error.InvalidPacket;
            const bytes = try self.allocator.alloc(u8, byte_count);
            defer self.allocator.free(bytes);
            switch (value.source) {
                0, 3 => try self.backend.read(value.source_address, bytes),
                2 => {
                    const immediate: [4]u8 = @bitCast(@as(u32, @truncate(value.source_address)));
                    for (bytes, 0..) |*byte, index| byte.* = immediate[index & 3];
                },
                else => {},
            }
            if (value.source == 0 or value.source == 2 or value.source == 3) {
                try self.backend.write(value.destination_address, bytes);
            }
        }
        self.state.last_dma = value;
        self.state.dma_data_count += 1;
    }

    fn eventWrite(self: *DcbExecutor, packet: pm4.Packet) Error!void {
        if (packet.body.len < 1) return Error.InvalidPacket;
        const raw = packet.body[0];
        const event_type: u8 = @truncate(raw & 0x3f);
        const addressed = (event_type & 0x3e) == 0x38;
        if (addressed and packet.body.len < 3) return Error.InvalidPacket;
        const event = gpu_state.EventWrite{
            .event_type = event_type,
            .event_index = @truncate((raw >> 8) & 0x7),
            .address = if (addressed)
                (@as(u64, packet.body[2]) << 32) | (packet.body[1] & 0xffff_fff8)
            else
                null,
        };
        self.state.last_event = event;
        self.state.event_count += 1;
        if (self.backend.vtable.event) |callback| {
            if (!callback(self.backend.context, event)) return Error.BackendRejected;
        }
    }

    fn setFlip(self: *DcbExecutor, packet: pm4.Packet) Error!void {
        if (packet.body.len < 5) return Error.InvalidPacket;
        const raw_argument = (@as(u64, packet.body[4]) << 32) | packet.body[3];
        const flip = gpu_state.Flip{
            .video_out_handle = packet.body[0],
            .display_buffer_index = @bitCast(packet.body[1]),
            .mode = packet.body[2],
            .argument = @bitCast(raw_argument),
        };
        self.state.last_flip = flip;
        self.state.flip_count += 1;
        if (self.backend.vtable.flip) |callback| {
            if (!callback(self.backend.context, flip)) return Error.BackendRejected;
        }
    }

    fn readU32(self: *DcbExecutor, address: u64) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.backend.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn readTrackedRegister(self: *DcbExecutor, absolute: u32) u64 {
        const location = registerLocation(absolute) orelse return 0;
        return self.state.readRegister(location.space, location.offset) orelse 0;
    }

    fn readU64(self: *DcbExecutor, address: u64) Error!u64 {
        var bytes: [8]u8 = undefined;
        try self.backend.read(address, &bytes);
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn writeU32(self: *DcbExecutor, address: u64, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.backend.write(address, &bytes);
    }

    fn writeU64(self: *DcbExecutor, address: u64, value: u64) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.backend.write(address, &bytes);
    }
};

const RegisterLocation = struct { space: pm4.RegisterSpace, offset: u32 };

fn setContinuationFrame(
    result: *Result,
    depth: usize,
    descriptor: Continuation.Frame,
    resume_word: usize,
) void {
    if (result.continuation == null) result.continuation = .{};
    if (result.continuation) |*continuation| {
        continuation.frames[depth] = .{
            .address = descriptor.address,
            .word_count = descriptor.word_count,
            .resume_word = resume_word,
        };
        const required_count: u8 = @intCast(depth + 1);
        continuation.frame_count = @max(continuation.frame_count, required_count);
    }
}

fn registerLocation(absolute: u32) ?RegisterLocation {
    inline for ([_]pm4.RegisterSpace{ .config, .shader, .context, .uconfig }) |space| {
        const base = space.base();
        const count: u32 = switch (space) {
            .config => configCount(),
            .context => 0x400,
            .shader => 0x300,
            .uconfig => 0x4000,
        };
        if (absolute >= base and absolute - base < count) {
            return .{ .space = space, .offset = absolute - base };
        }
    }
    return null;
}

fn configCount() u32 {
    return 0x0c00;
}

fn normalizeIndirectOffset(space: pm4.RegisterSpace, raw: u32) u32 {
    const selector = raw & 0x7000_0000;
    const offset = raw & ~@as(u32, 0x7000_0000);
    if (space == .context and selector == 0x1000_0000 and offset < 32) {
        return 0x191 + offset;
    }
    return offset;
}

fn indirectOffsetTracked(space: pm4.RegisterSpace, offset: u32) bool {
    return offset < switch (space) {
        .config => configCount(),
        .context => 0x400,
        .shader => 0x300,
        .uconfig => 0x4000,
    };
}

fn units256(low: u32, high: u32, high_bits: u6) u64 {
    const mask = if (high_bits == 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(high_bits)) - 1;
    return ((@as(u64, high & mask) << 32) | low) << 8;
}

fn decodeWaitOperation(control: u32, is_64_bit: bool) u8 {
    return if (is_64_bit)
        @truncate(((control >> 8) & 0x1) | ((control >> 5) & 0x6))
    else
        @truncate(((control >> 8) & 0x3) | ((control >> 4) & 0x0c));
}

pub fn compareWait(value: u64, reference: u64, mask: u64, function: u8) bool {
    const masked = value & mask;
    return switch (function) {
        0 => true,
        1 => masked < reference,
        2 => masked <= reference,
        3 => masked == reference,
        4 => masked != reference,
        5 => masked >= reference,
        6 => masked > reference,
        else => true,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const FakeBackend = struct {
    base: u64 = 0x1000,
    memory: [512]u8 = [_]u8{0} ** 512,
    draws: usize = 0,
    dispatches: usize = 0,
    flips: usize = 0,

    fn interface(self: *FakeBackend) Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    fn putWords(self: *FakeBackend, address: u64, words: []const u32) void {
        const offset: usize = @intCast(address - self.base);
        for (words, 0..) |word, index| {
            std.mem.writeInt(u32, self.memory[offset + index * 4 ..][0..4], word, .little);
        }
    }

    const vtable = Backend.VTable{
        .read = read,
        .write = write,
        .flip = onFlip,
        .draw = onDraw,
        .dispatch = onDispatch,
    };

    fn from(context: ?*anyopaque) *FakeBackend {
        return @ptrCast(@alignCast(context.?));
    }

    fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
        const self = from(context);
        if (address < self.base) return false;
        const offset: usize = @intCast(address - self.base);
        if (offset + bytes.len > self.memory.len) return false;
        @memcpy(bytes, self.memory[offset .. offset + bytes.len]);
        return true;
    }

    fn write(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
        const self = from(context);
        if (address < self.base) return false;
        const offset: usize = @intCast(address - self.base);
        if (offset + bytes.len > self.memory.len) return false;
        @memcpy(self.memory[offset .. offset + bytes.len], bytes);
        return true;
    }

    fn onFlip(context: ?*anyopaque, _: gpu_state.Flip) bool {
        from(context).flips += 1;
        return true;
    }

    fn onDraw(context: ?*anyopaque, _: *const gpu_state.State, _: pm4.Packet) bool {
        from(context).draws += 1;
        return true;
    }

    fn onDispatch(context: ?*anyopaque, _: *const gpu_state.State, _: pm4.Packet) bool {
        from(context).dispatches += 1;
        return true;
    }
};

fn command(opcode: u8, body_words: u14) u32 {
    return (@as(u32, 3) << 30) |
        (@as(u32, body_words - 1) << 16) |
        (@as(u32, opcode) << 8);
}

fn customCommand(code: u6, body_words: u14) u32 {
    return command(pm4.nop, body_words) | (@as(u32, code) << 2);
}

test "direct and Gen5 indirect register packets share persistent state" {
    var host = FakeBackend{};
    std.mem.writeInt(u32, host.memory[0..4], 0x20, .little);
    std.mem.writeInt(u32, host.memory[4..8], 0xaaaa_5555, .little);
    std.mem.writeInt(u32, host.memory[8..12], 0x1000_0002, .little);
    std.mem.writeInt(u32, host.memory[12..16], 0x1357_2468, .little);
    std.mem.writeInt(u32, host.memory[16..20], 8, .little);
    std.mem.writeInt(u32, host.memory[20..24], 0xcafe_babe, .little);

    const stream = [_]u32{
        command(pm4.set_context_reg, 3),     0x10,                                     0x1111,                                             0x2222,
        command(pm4.set_sh_reg_indirect, 4), 0x1000,                                   0,                                                  0x8000_0000,
        1,                                   command(pm4.set_context_reg_indirect, 4), 0x1008,                                             0,
        0x8000_0000,                         1,                                        customCommand(pm4.custom.uconfig_regs_indirect, 3), 1,
        0x1010,                              0,                                        command(pm4.set_uconfig_reg, 2),                    7,
        0x3333,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface() };
    const result = try executor.execute(&stream);

    try testing.expectEqual(Status.complete, result.status);
    try testing.expectEqual(@as(?u32, 0x1111), state.readRegister(.context, 0x10));
    try testing.expectEqual(@as(?u32, 0x2222), state.readRegister(.context, 0x11));
    try testing.expectEqual(@as(?u32, 0xaaaa_5555), state.readRegister(.shader, 0x20));
    try testing.expectEqual(@as(?u32, 0x1357_2468), state.readRegister(.context, 0x193));
    try testing.expectEqual(@as(?u32, 0x3333), state.readRegister(.uconfig, 7));
    try testing.expectEqual(@as(?u32, 0xcafe_babe), state.readRegister(.uconfig, 8));
}

test "indexed offset draw retains index buffer state for the backend" {
    var host = FakeBackend{};
    const stream = [_]u32{
        command(pm4.index_base, 2),        0x9abc_def0, 0x1234_5678,
        command(pm4.index_buffer_size, 1), 0x200,       command(pm4.set_uconfig_reg_index, 2),
        0x2000_0243,                       0x400,       command(pm4.draw_index_offset_2, 4),
        12,                                5,           12,
        0,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface() };
    const result = try executor.execute(&stream);

    try testing.expectEqual(Status.complete, result.status);
    try testing.expectEqual(@as(u64, 0x1234_5678_9abc_def0), state.index_base_address);
    try testing.expectEqual(@as(u32, 0x200), state.index_buffer_size);
    try testing.expectEqual(@as(u2, 0), state.index_type);
    try testing.expectEqual(@as(usize, 1), result.draws);
    try testing.expectEqual(@as(usize, 1), host.draws);
}

test "SET_BASE retains separate draw and dispatch indirect argument addresses" {
    var host = FakeBackend{};
    const stream = [_]u32{
        command(pm4.set_base, 3),     1, 0x2345_6780, 0x0000_1234,
        command(pm4.set_base, 3) | 2, 1, 0x9abc_def8, 0x0000_5678,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface() };
    const result = try executor.execute(&stream);

    try testing.expectEqual(Status.complete, result.status);
    try testing.expectEqual(@as(u64, 0x1234_2345_6780), state.draw_indirect_args_base_address);
    try testing.expectEqual(@as(u64, 0x5678_9abc_def8), state.dispatch_indirect_args_base_address);
}

test "Gen5 indirect lists skip untracked extension registers" {
    var host = FakeBackend{};
    std.mem.writeInt(u32, host.memory[0..4], 0x400, .little);
    std.mem.writeInt(u32, host.memory[4..8], 0xdead_beef, .little);
    std.mem.writeInt(u32, host.memory[8..12], 0x21, .little);
    std.mem.writeInt(u32, host.memory[12..16], 0x1234_5678, .little);
    const stream = [_]u32{
        command(pm4.set_context_reg_indirect, 4),
        0x1000,
        0,
        0x8000_0000,
        2,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface() };
    const result = try executor.execute(&stream);

    try testing.expectEqual(Status.complete, result.status);
    try testing.expectEqual(@as(?u32, 0x1234_5678), state.readRegister(.context, 0x21));
}

test "write data and release memory publish values seen by a wait" {
    var host = FakeBackend{};
    const stream = [_]u32{
        customCommand(pm4.custom.write_data, 5),
        5,
        0x1020,
        0,
        0x1122_3344,
        0x5566_7788,
        customCommand(pm4.custom.wait_mem_32, 6),
        0x1020,
        0,
        0xffff_ffff,
        0x1122_3344,
        0x13,
        1,
        customCommand(pm4.custom.release_mem, 7),
        0x28 | (5 << 8),
        (1 << 29),
        0x1040,
        0,
        0xaabb_ccdd,
        0,
        0,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface() };
    const result = try executor.execute(&stream);

    try testing.expectEqual(Status.complete, result.status);
    try testing.expectEqual(@as(u32, 0x1122_3344), std.mem.readInt(u32, host.memory[0x20..0x24], .little));
    try testing.expectEqual(@as(u32, 0x5566_7788), std.mem.readInt(u32, host.memory[0x24..0x28], .little));
    try testing.expectEqual(@as(u32, 0xaabb_ccdd), std.mem.readInt(u32, host.memory[0x40..0x44], .little));
    try testing.expect(state.blocked_wait == null);
    try testing.expectEqual(@as(u64, 1), state.release_count);
}

test "an unmet wait suspends at its packet and resumes after a producer write" {
    var host = FakeBackend{};
    const stream = [_]u32{
        customCommand(pm4.custom.wait_mem_32, 6),
        0x1080,
        0,
        0xffff_ffff,
        7,
        0x13,
        1,
        command(pm4.event_write, 1),
        0x2f,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface() };

    const blocked = try executor.execute(&stream);
    try testing.expectEqual(Status.blocked, blocked.status);
    try testing.expectEqual(@as(usize, 0), blocked.resume_word);
    try testing.expectEqual(@as(u64, 0), state.event_count);

    std.mem.writeInt(u32, host.memory[0x80..0x84], 7, .little);
    const resumed = try executor.resumeFrom(&stream, blocked.continuation.?);
    try testing.expectEqual(Status.complete, resumed.status);
    try testing.expectEqual(@as(u64, 1), state.event_count);
    try testing.expect(state.blocked_wait == null);
}

test "INDIRECT_BUFFER executes child state and work before returning to its parent" {
    var host = FakeBackend{};
    const child = [_]u32{
        command(pm4.set_sh_reg, 2),      0x20, 0x7654_3210,
        command(pm4.draw_index_auto, 2), 3,    0,
    };
    host.putWords(0x1100, &child);
    const parent = [_]u32{
        command(pm4.set_context_reg, 2), 4,                           0x1234,
        command(pm4.indirect_buffer, 3), 0x1100,                      0,
        0x0f20_0000 | child.len,         command(pm4.event_write, 1), 0x2f,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface(), .allocator = testing.allocator };
    const result = try executor.execute(&parent);

    try testing.expectEqual(Status.complete, result.status);
    try testing.expectEqual(@as(usize, 5), result.packets);
    try testing.expectEqual(@as(usize, 1), result.draws);
    try testing.expectEqual(@as(?u32, 0x1234), state.readRegister(.context, 4));
    try testing.expectEqual(@as(?u32, 0x7654_3210), state.readRegister(.shader, 0x20));
    try testing.expectEqual(@as(u64, 1), state.event_count);
    try testing.expectEqual(@as(u64, 1), state.indirect_buffer_count);
    try testing.expectEqual(@as(usize, 1), host.draws);
}

test "INDIRECT_BUFFER chain ends its parent and conditional form selects else" {
    var host = FakeBackend{};
    const chained_child = [_]u32{ command(pm4.event_write, 1), 0x20 };
    host.putWords(0x1100, &chained_child);
    const chained_parent = [_]u32{
        command(pm4.indirect_buffer, 3), 0x1100, 0, 0x0f30_0000 | chained_child.len,
        command(pm4.event_write, 1),     0x21,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface(), .allocator = testing.allocator };
    const chained = try executor.execute(&chained_parent);
    try testing.expectEqual(@as(usize, 2), chained.packets);
    try testing.expectEqual(@as(u64, 1), state.event_count);

    const then_child = [_]u32{ command(pm4.event_write, 1), 0x22 };
    const else_child = [_]u32{ command(pm4.set_uconfig_reg, 2), 9, 0xbeef };
    host.putWords(0x1120, &then_child);
    host.putWords(0x1140, &else_child);
    const branch = [_]u32{
        command(pm4.indirect_buffer, 13),
        2 | (3 << 8),
        0x1080,
        0,
        0xffff_ffff,
        0xffff_ffff,
        7,
        0,
        0x1120,
        0,
        then_child.len,
        0x1140,
        0,
        else_child.len,
    };
    const branched = try executor.execute(&branch);
    try testing.expectEqual(Status.complete, branched.status);
    try testing.expectEqual(@as(?u32, 0xbeef), state.readRegister(.uconfig, 9));
    try testing.expectEqual(@as(u64, 1), state.event_count);
}

test "a nested wait resumes in place without replaying earlier child packets" {
    var host = FakeBackend{};
    const child = [_]u32{
        command(pm4.event_write, 1),              0x20,
        customCommand(pm4.custom.wait_mem_32, 6), 0x1080,
        0,                                        0xffff_ffff,
        7,                                        0x13,
        1,                                        command(pm4.event_write, 1),
        0x21,
    };
    host.putWords(0x1100, &child);
    const parent = [_]u32{
        command(pm4.indirect_buffer, 3), 0x1100, 0, 0x0f20_0000 | child.len,
        command(pm4.event_write, 1),     0x22,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface(), .allocator = testing.allocator };

    const blocked = try executor.execute(&parent);
    try testing.expectEqual(Status.blocked, blocked.status);
    try testing.expectEqual(@as(u8, 2), blocked.continuation.?.frame_count);
    try testing.expectEqual(@as(usize, 0), blocked.continuation.?.frames[0].resume_word);
    try testing.expectEqual(@as(usize, 2), blocked.continuation.?.frames[1].resume_word);
    try testing.expectEqual(@as(u64, 1), state.event_count);

    std.mem.writeInt(u32, host.memory[0x80..0x84], 7, .little);
    const resumed = try executor.resumeFrom(&parent, blocked.continuation.?);
    try testing.expectEqual(Status.complete, resumed.status);
    try testing.expectEqual(@as(usize, 4), resumed.packets);
    try testing.expectEqual(@as(u64, 3), state.event_count);
    try testing.expectEqual(@as(u64, 5), state.packets_executed);
}

test "conditional INDIRECT_BUFFER keeps its selected branch across resume" {
    var host = FakeBackend{};
    const then_child = [_]u32{
        customCommand(pm4.custom.wait_mem_32, 6),
        0x1080,
        0,
        0xffff_ffff,
        7,
        0x13,
        1,
        command(pm4.event_write, 1),
        0x30,
    };
    const else_child = [_]u32{ command(pm4.event_write, 1), 0x31 };
    host.putWords(0x1160, &then_child);
    host.putWords(0x11a0, &else_child);
    const branch = [_]u32{
        command(pm4.indirect_buffer, 13),
        2 | (3 << 8),
        0x1090,
        0,
        0xffff_ffff,
        0xffff_ffff,
        0,
        0,
        0x1160,
        0,
        then_child.len,
        0x11a0,
        0,
        else_child.len,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface(), .allocator = testing.allocator };

    const blocked = try executor.execute(&branch);
    try testing.expectEqual(Status.blocked, blocked.status);
    std.mem.writeInt(u32, host.memory[0x80..0x84], 7, .little);
    std.mem.writeInt(u64, host.memory[0x90..0x98], 1, .little);

    const resumed = try executor.resumeFrom(&branch, blocked.continuation.?);
    try testing.expectEqual(Status.complete, resumed.status);
    try testing.expectEqual(@as(u8, 0x30), state.last_event.?.event_type);
    try testing.expectEqual(@as(u64, 1), state.event_count);
}

test "INDIRECT_BUFFER rejects active cycles, excessive depth and unreadable ranges" {
    var host = FakeBackend{};
    const cycle = [_]u32{ command(pm4.indirect_buffer, 3), 0x1000, 0, 0x0f20_0004 };
    host.putWords(0x1000, &cycle);
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface(), .allocator = testing.allocator };
    try testing.expectError(Error.IndirectBufferCycle, executor.execute(&cycle));

    for (0..maximum_stream_depth - 1) |index| {
        const address = 0x1000 + index * 16;
        const next = address + 16;
        const nested = [_]u32{
            command(pm4.indirect_buffer, 3),
            @intCast(next),
            0,
            0x0f20_0004,
        };
        host.putWords(address, &nested);
    }
    const deep_root = [_]u32{ command(pm4.indirect_buffer, 3), 0x1000, 0, 0x0f20_0004 };
    try testing.expectError(Error.IndirectBufferTooDeep, executor.execute(&deep_root));

    const out_of_range = [_]u32{ command(pm4.indirect_buffer, 3), 0x11f0, 0, 0x0f20_0008 };
    try testing.expectError(Error.MemoryReadFailed, executor.execute(&out_of_range));
}

test "standard WAIT_REG_MEM can compare a tracked register" {
    var host = FakeBackend{};
    const stream = [_]u32{
        command(pm4.set_context_reg, 2), 0x10,                        0x55,
        command(pm4.wait_reg_mem, 6),    3,                           0xa010,
        0,                               0x55,                        0xffff_ffff,
        1,                               command(pm4.event_write, 1), 0x2f,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface() };
    const result = try executor.execute(&stream);

    try testing.expectEqual(Status.complete, result.status);
    try testing.expect(!state.last_wait.?.memory_space);
    try testing.expectEqual(@as(u64, 1), state.event_count);
}

test "acquire event flip draw and dispatch cross the backend interface" {
    var host = FakeBackend{};
    const stream = [_]u32{
        customCommand(pm4.custom.acquire_mem, 7),
        0x8000_0001,
        0x20,
        0,
        0x10,
        0,
        3,
        0x388,
        command(pm4.event_write, 3),
        0x138,
        0x1100,
        0,
        customCommand(pm4.custom.flip, 5),
        4,
        2,
        1,
        0x89ab_cdef,
        0x0123_4567,
        command(pm4.draw_index_auto, 2),
        3,
        0,
        command(pm4.dispatch_direct, 4),
        1,
        2,
        3,
        0x41,
    };
    var state = gpu_state.State{};
    var executor = DcbExecutor{ .state = &state, .backend = host.interface() };
    const result = try executor.execute(&stream);

    try testing.expectEqual(Status.complete, result.status);
    try testing.expectEqual(@as(u8, 1), state.last_acquire.?.engine);
    try testing.expectEqual(@as(u64, 0x2000), state.last_acquire.?.size_bytes);
    try testing.expectEqual(@as(?u64, 0x1100), state.last_event.?.address);
    try testing.expectEqual(@as(i64, 0x0123_4567_89ab_cdef), state.last_flip.?.argument);
    try testing.expectEqual(@as(usize, 1), host.flips);
    try testing.expectEqual(@as(usize, 1), host.draws);
    try testing.expectEqual(@as(usize, 1), host.dispatches);
}

test "wait comparisons apply the mask to the observed value" {
    try testing.expect(compareWait(0xff12, 0x12, 0xff, 3));
    try testing.expect(compareWait(9, 10, std.math.maxInt(u64), 1));
    try testing.expect(!compareWait(10, 10, std.math.maxInt(u64), 4));
}
