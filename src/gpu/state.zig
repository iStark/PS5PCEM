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
/// The selectors are stored as the command processor recovers them, which is
/// deliberately not how either constructor spells them. The graphics form
/// writes the selector shifted right by one and puts the bit it shifted out
/// at bit 30; the compute form writes the selector unshifted and has no bit
/// 30 at all. Recovering `(field << 1) | bit30` undoes the first exactly and
/// doubles the second, and the two land in one space that can be read without
/// knowing which queue wrote the packet: a compute selector of 1, 2 or 3
/// arrives as 2, 4 or 6, and a graphics selector of 2, 4 or 5 arrives
/// unchanged -- all of them memory. The same holds for the immediate
/// selector, which is 5 from compute and 10 from graphics and arrives as 10
/// either way.
pub const CopyData = struct {
    /// Recovered selector values, not the arguments a title passed.
    pub const Selector = enum {
        memory,
        gds,
        immediate,
        other,

        pub fn from(recovered: u32) Selector {
            return switch (recovered) {
                2, 4, 5 => .memory,
                3, 6, 7 => .gds,
                10, 11 => .immediate,
                else => .other,
            };
        }
    };

    source: Selector,
    destination: Selector,
    source_raw: u32,
    destination_raw: u32,
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
pub const State = struct {
    config: RegisterFile(config_register_count) = .{},
    context: RegisterFile(context_register_count) = .{},
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
        // `predicate_skip` is deliberately left alone. CLEAR_STATE drops the
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
