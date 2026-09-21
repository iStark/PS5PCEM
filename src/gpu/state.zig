// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Persistent state reconstructed from submitted GPU command buffers.
//!
//! A Vulkan backend cannot translate one draw in isolation: render targets,
//! shader programs, user data and synchronization were established by earlier
//! packets and often by an earlier DCB. This is the deliberately API-neutral
//! state between the PM4 parser and a future renderer.

const std = @import("std");
const pm4 = @import("pm4.zig");

pub const Error = error{RegisterOutOfRange};

const config_register_count = 0x0c00;
const context_register_count = 0x0400;
const shader_register_count = 0x0300;
const uconfig_register_count = 0x4000;

fn RegisterFile(comptime count: usize) type {
    return struct {
        values: [count]u32 = [_]u32{0} ** count,
        written: [count]bool = [_]bool{false} ** count,

        fn write(self: *@This(), offset: u32, value: u32) Error!void {
            if (offset >= count) return Error.RegisterOutOfRange;
            self.values[offset] = value;
            self.written[offset] = true;
        }

        fn read(self: *const @This(), offset: u32) ?u32 {
            if (offset >= count or !self.written[offset]) return null;
            return self.values[offset];
        }

        fn clear(self: *@This()) void {
            @memset(&self.values, 0);
            @memset(&self.written, false);
        }
    };
}

pub const AcquireMem = struct {
    engine: u8,
    cb_db_control: u32,
    base_address: u64,
    size_bytes: u64,
    poll_interval: u32,
    gcr_control: u32,
    standard_packet: bool,
};

pub const ReleaseMem = struct {
    event_type: u8,
    event_index: u8,
    gcr_control: u16,
    cache_policy: u8,
    destination: u8,
    interrupt: u8,
    data_selection: u8,
    address: u64,
    data: u64,
    interrupt_context_id: u32,
    standard_packet: bool,
};

pub const WaitWidth = enum { bits_32, bits_64 };

pub const WaitRegMem = struct {
    width: WaitWidth,
    memory_space: bool,
    address: u64,
    mask: u64,
    reference: u64,
    compare_function: u8,
    operation: u8,
    poll_interval: u32,
    standard_packet: bool,
};

pub const WriteData = struct {
    destination: u8,
    cache_policy: u8,
    increment_address: bool,
    write_confirm: bool,
    address: u64,
    word_count: u32,
    standard_packet: bool,
};

pub const DmaData = struct {
    engine: u8,
    source: u8,
    source_cache_policy: u8,
    source_address: u64,
    destination: u8,
    destination_cache_policy: u8,
    destination_address: u64,
    byte_count: u32,
    wait_for_previous: bool,
    write_confirm: bool,
    block_engine: bool,
};

pub const EventWrite = struct {
    event_type: u8,
    event_index: u8,
    address: ?u64,
};

pub const Flip = struct {
    video_out_handle: u32,
    display_buffer_index: i32,
    mode: u32,
    argument: i64,
};

/// What `SET_PREDICATION` asked for.
///
/// The packet does not carry the predicate, only where to find it and how to
/// read it. `op` selects that: zero turns predication off outright, three
/// names a 64-bit value in memory, and one names a block of occlusion-query
/// results. `condition` then says which way round the answer runs.
pub const SetPredication = struct {
    pub const disable: u3 = 0;
    pub const zpass: u3 = 1;
    pub const boolean: u3 = 3;

    op: u3,
    /// 0 skips predicated packets when the value is non-zero, 1 when it is zero.
    condition: u1,
    /// The title asks the parser to wait for the value rather than read it now.
    wait: u1,
    address: u64,
};
/// What one `COPY_DATA` packet moves.
///
/// Selectors below are PM4 fields, after the writer converts the guest ABI.
/// Source and destination enumerations differ; engine selection is separate.
/// See AMD PAL gfx9_plus_merged_f32_{me,pfp,mec}_pm4_packets.h, COPY_DATA.
pub const CopyData = struct {
    pub const Selector = enum {
        memory,
        gds,
        immediate,
        other,

        pub fn fromSource(raw: u32) Selector {
            return switch (raw) {
                1, 2 => .memory,
                3 => .gds,
                5 => .immediate,
                else => .other,
            };
        }

        pub fn fromDestination(raw: u32) Selector {
            return switch (raw) {
                1, 2, 5 => .memory,
                3 => .gds,
                else => .other,
            };
        }
    };

    source: Selector,
    destination: Selector,
    source_raw: u32,
    destination_raw: u32,
    engine: u2,
    source_cache_policy: u2,
    destination_cache_policy: u2,
    write_confirm: bool,
    /// Four or eight. The packet carries one bit; everything else about the
    /// transfer is the same either way.
    byte_count: u4,
    /// A memory address, or the immediate itself when the source says so.
    source_address_or_immediate: u64,
    destination_address: u64,
};
/// What one context-state packet asks the command processor to do with the
/// context register file.
///
/// Only the context registers take part. The shader and uconfig files, the
/// index state, the predicate and everything about synchronisation are queue
/// state that a save and restore must not touch: a title pushes context
/// around a pass it wants to draw differently, not around the fence it is
/// waiting on.
pub const ContextStateOperation = enum(u32) {
    clear = 0,
    push = 1,
    pop = 2,
    push_clear = 3,

    pub fn from(value: u32) ?ContextStateOperation {
        return switch (value) {
            0 => .clear,
            1 => .push,
            2 => .pop,
            3 => .push_clear,
            else => null,
        };
    }
};

/// How deep the saved context registers stack.
///
/// Emulator limit for saved context frames, not a verified hardware depth.
/// Exhaustion must stop the submission; ignoring a push unbalances its pops.
pub const context_state_depth: usize = 4;
pub const State = struct {
    config: RegisterFile(config_register_count) = .{},
    context: RegisterFile(context_register_count) = .{},
    /// Saved copies of `context`, innermost last.
    context_stack: [context_state_depth]RegisterFile(context_register_count) = @splat(.{}),
    context_depth: u8 = 0,
    shader: RegisterFile(shader_register_count) = .{},
    uconfig: RegisterFile(uconfig_register_count) = .{},

    last_acquire: ?AcquireMem = null,
    last_release: ?ReleaseMem = null,
    last_wait: ?WaitRegMem = null,
    blocked_wait: ?WaitRegMem = null,
    last_write: ?WriteData = null,
    last_dma: ?DmaData = null,
    last_event: ?EventWrite = null,
    last_flip: ?Flip = null,
    last_predication: ?SetPredication = null,
    last_copy: ?CopyData = null,

    /// Whether packets carrying the predicate bit are currently dropped.
    ///
    /// This is queue state, not a context register: it survives CLEAR_STATE,
    /// it is inherited by nested indirect buffers, and it is still in force
    /// when a submission that blocked on a wait is resumed. All three follow
    /// from the command processor holding one predicate per queue, and all
    /// three matter -- a title sets the predicate once and then submits the
    /// draws it guards from a different buffer.
    predicate_skip: bool = false,

    packets_executed: u64 = 0,
    register_writes: u64 = 0,
    acquire_count: u64 = 0,
    release_count: u64 = 0,
    wait_count: u64 = 0,
    write_data_count: u64 = 0,
    dma_data_count: u64 = 0,
    event_count: u64 = 0,
    flip_count: u64 = 0,
    indirect_buffer_count: u64 = 0,
    draw_count: u64 = 0,
    dispatch_count: u64 = 0,
    instance_count: u32 = 1,
    index_base_address: u64 = 0,
    index_buffer_size: u32 = 0,
    draw_indirect_args_base_address: u64 = 0,
    dispatch_indirect_args_base_address: u64 = 0,
    /// 0 = u16, 1 = u32, 2 = u8 (VGT_INDEX_TYPE).
    index_type: u2 = 0,

    // Predication counters. `predicated_opcode_counts` is indexed by opcode
    // so a capture can say which commands a title actually guards, including
    // the ones it built into its buffer itself rather than through an AGC
    // constructor -- the packet bit is the same either way.
    predication_enable_count: u64 = 0,
    predication_disable_count: u64 = 0,
    predication_unsupported_count: u64 = 0,
    predicated_executed: u64 = 0,
    predicated_skipped: u64 = 0,
    predicated_opcode_counts: [256]u32 = @splat(0),

    copy_data_count: u64 = 0,
    /// Transfers whose selectors name something this does not move yet.
    copy_data_unsupported_count: u64 = 0,

    context_state_clear_count: u64 = 0,
    context_state_push_count: u64 = 0,
    context_state_pop_count: u64 = 0,
    /// A push with nowhere left to save, or a pop with nothing saved.
    context_state_refused_count: u64 = 0,

    /// How many times in a row the queue has re-entered the REWIND it is
    /// parked on. A rewind is made valid by someone else patching the packet,
    /// and nothing here guarantees that ever happens, so the count is what
    /// stops the queue re-reading it forever.
    rewind_reentry_count: u32 = 0,
    rewind_wait_count: u64 = 0,
    /// Times the guard gave up waiting and let the stream continue.
    rewind_abandoned_count: u64 = 0,

    pub fn writeRegister(self: *State, space: pm4.RegisterSpace, offset: u32, value: u32) Error!void {
        switch (space) {
            .config => try self.config.write(offset, value),
            .context => try self.context.write(offset, value),
            .shader => try self.shader.write(offset, value),
            .uconfig => try self.uconfig.write(offset, value),
        }
        self.register_writes += 1;
    }

    /// Returns null both for an unwritten register and an offset outside its
    /// bank. Writes remain strict, while inspection is convenient for callers.
    pub fn readRegister(self: *const State, space: pm4.RegisterSpace, offset: u32) ?u32 {
        return switch (space) {
            .config => self.config.read(offset),
            .context => self.context.read(offset),
            .shader => self.shader.read(offset),
            .uconfig => self.uconfig.read(offset),
        };
    }

    /// Applies one context-state operation, and says whether it could be.
    ///
    /// A push onto a full stack and a pop from an empty one are refused
    /// rather than silently dropping or inventing a context: either would
    /// leave later draws reading registers that belong to a different pass,
    /// which is far harder to see than a counter going up.
    pub fn applyContextStateOperation(self: *State, operation: ContextStateOperation) bool {
        switch (operation) {
            .clear => {
                self.context.clear();
                self.context_state_clear_count += 1;
                return true;
            },
            .push, .push_clear => {
                if (self.context_depth >= context_state_depth) {
                    self.context_state_refused_count += 1;
                    return false;
                }
                self.context_stack[self.context_depth] = self.context;
                self.context_depth += 1;
                self.context_state_push_count += 1;
                if (operation == .push_clear) {
                    self.context.clear();
                    self.context_state_clear_count += 1;
                }
                return true;
            },
            .pop => {
                if (self.context_depth == 0) {
                    self.context_state_refused_count += 1;
                    return false;
                }
                self.context_depth -= 1;
                self.context = self.context_stack[self.context_depth];
                self.context_stack[self.context_depth] = .{};
                self.context_state_pop_count += 1;
                return true;
            },
        }
    }
    pub fn clearRegisters(self: *State) void {
        self.config.clear();
        self.context.clear();
        self.shader.clear();
        self.uconfig.clear();
        self.instance_count = 1;
        self.index_base_address = 0;
        self.index_buffer_size = 0;
        self.draw_indirect_args_base_address = 0;
        self.dispatch_indirect_args_base_address = 0;
        self.index_type = 0;
        // `predicate_skip` and the saved context stack are deliberately left
        // alone. CLEAR_STATE drops the
        // register files; the predicate is not one of them, and a title that
        // clears state between passes does not expect its guarded draws to
        // start issuing again.
    }
};

const testing = std.testing;

test "register banks retain zero writes and reject impossible offsets" {
    var gpu_state = State{};
    try gpu_state.writeRegister(.context, 0, 0);
    try gpu_state.writeRegister(.shader, 0x20, 0x1234_5678);

    try testing.expectEqual(@as(?u32, 0), gpu_state.readRegister(.context, 0));
    try testing.expectEqual(@as(?u32, 0x1234_5678), gpu_state.readRegister(.shader, 0x20));
    try testing.expect(gpu_state.readRegister(.context, 1) == null);
    try testing.expectError(
        Error.RegisterOutOfRange,
        gpu_state.writeRegister(.context, context_register_count, 1),
    );
}

test "clearing register state does not erase submission statistics" {
    var gpu_state = State{};
    try gpu_state.writeRegister(.uconfig, 5, 9);
    gpu_state.packets_executed = 7;
    gpu_state.clearRegisters();

    try testing.expect(gpu_state.readRegister(.uconfig, 5) == null);
    try testing.expectEqual(@as(u64, 7), gpu_state.packets_executed);
    try testing.expectEqual(@as(u64, 1), gpu_state.register_writes);
    try testing.expectEqual(@as(u32, 1), gpu_state.instance_count);
    try testing.expectEqual(@as(u64, 0), gpu_state.index_base_address);
    try testing.expectEqual(@as(u32, 0), gpu_state.index_buffer_size);
    try testing.expectEqual(@as(u64, 0), gpu_state.draw_indirect_args_base_address);
    try testing.expectEqual(@as(u64, 0), gpu_state.dispatch_indirect_args_base_address);
}
