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
