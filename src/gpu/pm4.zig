// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! The command stream a title hands to the GPU.
//!
//! A PS5 title does not ask the graphics API to draw. It builds packets in its
//! own memory — state changes, register writes, draws, dispatches, fences — and
//! submits the buffer. Everything the GPU ever does arrives this way, so this
//! stream is the real interface to emulate, whichever layer it is intercepted
//! at: replacing the graphics library and emulating the kernel device both end
//! up holding one of these buffers.
//!
//! Nothing is executed here. What this does is make the stream *legible*: a
//! buffer of opaque words becomes a sequence of named commands with their
//! bodies delimited. That is worth having on its own — a decoded stream is the
//! specification an implementation has to satisfy, and it can be checked
//! against a real capture long before anything can render.
//!
//! The encoding is the command processor's, publicly documented by AMD's own
//! open-source drivers for the same generation of hardware. Only opcodes with a
//! documented meaning are named; the rest are reported by number, because an
//! invented name in a trace is worse than a number — a number invites you to go
//! look it up, and a wrong name does not.

const std = @import("std");

/// What a packet is, taken from the top two bits of its header.
pub const Kind = enum(u2) {
    /// A run of consecutive register writes. Largely superseded by the typed
    /// register commands, but still legal and still emitted.
    register_write = 0,
    /// Not assigned. Encountering one means the stream is being read at the
    /// wrong offset, which is worth reporting rather than skipping.
    reserved = 1,
    /// A single word of padding, used to align what follows. It has no body.
    filler = 2,
    /// A command: an opcode and its arguments.
    command = 3,
};

pub const Error = error{
    /// The header claims a body that runs past the end of the buffer.
    Truncated,
    /// A packet of the unassigned type, which no encoder produces.
    ReservedPacket,
};

/// One decoded packet, with its body still in the caller's buffer.
///
/// The body is a view rather than a copy: a command stream is large and read
/// once, and every argument a command takes is already sitting there in the
/// order the encoder wrote it.
pub const Packet = struct {
    kind: Kind,
    /// Which command this is. Meaningful only for `command` packets.
    opcode: u8 = 0,
    /// First register written, as a word index into the register file.
    /// Meaningful only for `register_write` packets.
    base_register: u16 = 0,
    /// The command is skipped unless the predicate set earlier passes.
    predicated: bool = false,
    /// The command addresses the compute pipe rather than graphics.
    compute: bool = false,
    header: u32,
    body: []const u32,

    /// Total size including the header, which is how far to advance.
    pub fn wordCount(self: Packet) usize {
        return 1 + self.body.len;
    }

    /// The name of this command, when it has a documented one.
    pub fn name(self: Packet) ?[]const u8 {
        if (self.kind != .command) return null;
        if (customCode(self)) |code| {
            if (customName(code)) |named| return named;
        }
        return opcodeName(self.opcode);
    }
};

// The header fields. Body length is stored biased by one, so a packet always
// carries at least one word after its header — there is no way to encode an
// empty body, and a decoder that assumed otherwise would misread every stream.
const kind_shift: u5 = 30;
const count_shift: u5 = 16;
const count_mask: u32 = 0x3fff;
const opcode_shift: u5 = 8;
const predicate_bit: u32 = 1 << 0;
const shader_type_bit: u32 = 1 << 1;

/// Reads a stream from front to back.
///
/// Bounds are enforced on every step. A command stream is read out of guest
/// memory, where a title's own bug — or an address this emulator resolved
/// wrongly — can produce a header claiming more than the buffer holds. Reading
/// past it would turn a guest mistake into a host crash, so a body that does
/// not fit is a reported error and the walk stops there.
pub const Walker = struct {
    stream: []const u32,
    index: usize = 0,

    pub fn init(stream: []const u32) Walker {
        return .{ .stream = stream };
    }

    /// How many words are left, including any partially decoded packet.
    pub fn remaining(self: Walker) usize {
        return self.stream.len - self.index;
    }

    /// Decodes the next packet, or null at the end of the stream.
    pub fn next(self: *Walker) Error!?Packet {
        if (self.index >= self.stream.len) return null;

        const header = self.stream[self.index];
        const kind: Kind = @enumFromInt(@as(u2, @truncate(header >> kind_shift)));
        if (kind == .reserved) return Error.ReservedPacket;

        const body_length: usize = switch (kind) {
            // Padding is one word and carries nothing.
            .filler => 0,
            else => if (header == 0xffff_1000) 0 else @as(usize, (header >> count_shift) & count_mask) + 1,
        };

        const body_start = self.index + 1;
        if (body_start + body_length > self.stream.len) return Error.Truncated;

        const packet = Packet{
            .kind = kind,
            .opcode = @truncate(header >> opcode_shift),
            .base_register = @truncate(header),
            .predicated = header & predicate_bit != 0,
            .compute = header & shader_type_bit != 0,
            .header = header,
            .body = self.stream[body_start .. body_start + body_length],
        };
        self.index = body_start + body_length;
        return packet;
    }
};

// ---------------------------------------------------------------------------
// Commands

pub const nop: u8 = 0x10;
pub const set_base: u8 = 0x11;
pub const clear_state: u8 = 0x12;
pub const index_buffer_size: u8 = 0x13;
pub const dispatch_direct: u8 = 0x15;
pub const dispatch_indirect: u8 = 0x16;
pub const atomic_mem: u8 = 0x1e;
pub const occlusion_query: u8 = 0x1f;
pub const set_predication: u8 = 0x20;
pub const reg_rmw: u8 = 0x21;
pub const cond_exec: u8 = 0x22;
pub const pred_exec: u8 = 0x23;
pub const draw_indirect: u8 = 0x24;
pub const draw_index_indirect: u8 = 0x25;
pub const index_base: u8 = 0x26;
pub const draw_index_2: u8 = 0x27;
pub const context_control: u8 = 0x28;
pub const index_type: u8 = 0x2a;
pub const draw_indirect_multi: u8 = 0x2c;
pub const draw_index_auto: u8 = 0x2d;
pub const num_instances: u8 = 0x2f;
pub const draw_index_multi_auto: u8 = 0x30;
pub const indirect_buffer_const: u8 = 0x33;
pub const strmout_buffer_update: u8 = 0x34;
pub const draw_index_offset_2: u8 = 0x35;
pub const draw_preamble: u8 = 0x36;
pub const write_data: u8 = 0x37;
pub const draw_index_indirect_multi: u8 = 0x38;
pub const mem_semaphore: u8 = 0x39;
pub const copy_dw: u8 = 0x3b;
pub const wait_reg_mem: u8 = 0x3c;
pub const indirect_buffer: u8 = 0x3f;
pub const copy_data: u8 = 0x40;
pub const cp_dma: u8 = 0x41;
pub const pfp_sync_me: u8 = 0x42;
pub const surface_sync: u8 = 0x43;
pub const cond_write: u8 = 0x45;
pub const event_write: u8 = 0x46;
pub const event_write_eop: u8 = 0x47;
pub const event_write_eos: u8 = 0x48;
pub const release_mem: u8 = 0x49;
pub const preamble_cntl: u8 = 0x4a;
pub const dma_data: u8 = 0x50;
pub const context_reg_rmw: u8 = 0x51;
pub const one_reg_write: u8 = 0x57;
pub const acquire_mem: u8 = 0x58;
pub const rewind: u8 = 0x59;
pub const load_uconfig_reg: u8 = 0x5e;
pub const load_sh_reg: u8 = 0x5f;
pub const load_config_reg: u8 = 0x60;
pub const load_context_reg: u8 = 0x61;
pub const set_sh_reg_indirect: u8 = 0x63;
pub const set_uconfig_reg_indirect: u8 = 0x64;
pub const set_config_reg: u8 = 0x68;
pub const set_context_reg: u8 = 0x69;
pub const set_context_reg_index: u8 = 0x6a;
pub const set_sh_reg: u8 = 0x76;
pub const set_sh_reg_offset: u8 = 0x77;
pub const set_uconfig_reg: u8 = 0x79;
pub const set_uconfig_reg_index: u8 = 0x7a;
pub const load_const_ram: u8 = 0x80;
pub const write_const_ram: u8 = 0x81;
pub const dump_const_ram: u8 = 0x83;
pub const increment_ce_counter: u8 = 0x84;
pub const increment_de_counter: u8 = 0x85;
pub const wait_on_ce_counter: u8 = 0x86;
pub const set_sh_reg_index: u8 = 0x9b;
pub const set_context_reg_indirect: u8 = 0x9f;

/// Gen5 extensions carried in the otherwise ordinary `NOP` packet. The code
/// occupies header bits 2..7; bits 0 and 1 retain predicate/pipe meaning.
pub const custom = struct {
    pub const zero: u6 = 0x00;
    pub const draw_reset: u6 = 0x05;
    pub const wait_flip_done: u6 = 0x06;
    pub const dispatch_reset: u6 = 0x09;
    pub const wait_mem_32: u6 = 0x0a;
    pub const push_marker: u6 = 0x0b;
    pub const pop_marker: u6 = 0x0c;
    pub const sh_regs_indirect: u6 = 0x11;
    pub const context_regs_indirect: u6 = 0x12;
    pub const uconfig_regs_indirect: u6 = 0x13;
    pub const acquire_mem: u6 = 0x14;
    pub const write_data: u6 = 0x15;
    pub const wait_mem_64: u6 = 0x16;
    pub const flip: u6 = 0x17;
    pub const release_mem: u6 = 0x18;
    pub const dma_data: u6 = 0x19;
};

/// Returns the Gen5 extension selector of a custom NOP packet.
pub fn customCode(packet: Packet) ?u6 {
    if (packet.kind != .command or packet.opcode != nop) return null;
    return @truncate(packet.header >> 2);
}

pub fn customName(code: u6) ?[]const u8 {
    return switch (code) {
        custom.zero => null,
        custom.draw_reset => "R_DRAW_RESET",
        custom.wait_flip_done => "R_WAIT_FLIP_DONE",
        custom.dispatch_reset => "R_DISPATCH_RESET",
        custom.wait_mem_32 => "R_WAIT_MEM_32",
        custom.push_marker => "R_PUSH_MARKER",
        custom.pop_marker => "R_POP_MARKER",
        custom.sh_regs_indirect => "R_SH_REGS_INDIRECT",
        custom.context_regs_indirect => "R_CONTEXT_REGS_INDIRECT",
        custom.uconfig_regs_indirect => "R_UCONFIG_REGS_INDIRECT",
        custom.acquire_mem => "R_ACQUIRE_MEM",
        custom.write_data => "R_WRITE_DATA",
        custom.wait_mem_64 => "R_WAIT_MEM_64",
        custom.flip => "R_FLIP",
        custom.release_mem => "R_RELEASE_MEM",
        custom.dma_data => "R_DMA_DATA",
        else => null,
    };
}

pub fn opcodeName(opcode: u8) ?[]const u8 {
    return switch (opcode) {
        nop => "NOP",
        set_base => "SET_BASE",
        clear_state => "CLEAR_STATE",
        index_buffer_size => "INDEX_BUFFER_SIZE",
        dispatch_direct => "DISPATCH_DIRECT",
        dispatch_indirect => "DISPATCH_INDIRECT",
        atomic_mem => "ATOMIC_MEM",
        occlusion_query => "OCCLUSION_QUERY",
        set_predication => "SET_PREDICATION",
        reg_rmw => "REG_RMW",
        cond_exec => "COND_EXEC",
        pred_exec => "PRED_EXEC",
        draw_indirect => "DRAW_INDIRECT",
        draw_index_indirect => "DRAW_INDEX_INDIRECT",
        index_base => "INDEX_BASE",
        draw_index_2 => "DRAW_INDEX_2",
        context_control => "CONTEXT_CONTROL",
        index_type => "INDEX_TYPE",
        draw_indirect_multi => "DRAW_INDIRECT_MULTI",
        draw_index_auto => "DRAW_INDEX_AUTO",
        num_instances => "NUM_INSTANCES",
        draw_index_multi_auto => "DRAW_INDEX_MULTI_AUTO",
        indirect_buffer_const => "INDIRECT_BUFFER_CONST",
        strmout_buffer_update => "STRMOUT_BUFFER_UPDATE",
        draw_index_offset_2 => "DRAW_INDEX_OFFSET_2",
        draw_preamble => "DRAW_PREAMBLE",
        write_data => "WRITE_DATA",
        draw_index_indirect_multi => "DRAW_INDEX_INDIRECT_MULTI",
        mem_semaphore => "MEM_SEMAPHORE",
        copy_dw => "COPY_DW",
        wait_reg_mem => "WAIT_REG_MEM",
        indirect_buffer => "INDIRECT_BUFFER",
        copy_data => "COPY_DATA",
        cp_dma => "CP_DMA",
        pfp_sync_me => "PFP_SYNC_ME",
        surface_sync => "SURFACE_SYNC",
        cond_write => "COND_WRITE",
        event_write => "EVENT_WRITE",
        event_write_eop => "EVENT_WRITE_EOP",
        event_write_eos => "EVENT_WRITE_EOS",
        release_mem => "RELEASE_MEM",
        preamble_cntl => "PREAMBLE_CNTL",
        dma_data => "DMA_DATA",
        context_reg_rmw => "CONTEXT_REG_RMW",
        one_reg_write => "ONE_REG_WRITE",
        acquire_mem => "ACQUIRE_MEM",
        rewind => "REWIND",
        load_uconfig_reg => "LOAD_UCONFIG_REG",
        load_sh_reg => "LOAD_SH_REG",
        load_config_reg => "LOAD_CONFIG_REG",
        load_context_reg => "LOAD_CONTEXT_REG",
        set_sh_reg_indirect => "SET_SH_REG_INDIRECT",
        set_uconfig_reg_indirect => "SET_UCONFIG_REG_INDIRECT",
        set_config_reg => "SET_CONFIG_REG",
        set_context_reg => "SET_CONTEXT_REG",
        set_context_reg_index => "SET_CONTEXT_REG_INDEX",
        set_sh_reg => "SET_SH_REG",
        set_sh_reg_offset => "SET_SH_REG_OFFSET",
        set_uconfig_reg => "SET_UCONFIG_REG",
        set_uconfig_reg_index => "SET_UCONFIG_REG_INDEX",
        load_const_ram => "LOAD_CONST_RAM",
        write_const_ram => "WRITE_CONST_RAM",
        dump_const_ram => "DUMP_CONST_RAM",
        increment_ce_counter => "INCREMENT_CE_COUNTER",
        increment_de_counter => "INCREMENT_DE_COUNTER",
        wait_on_ce_counter => "WAIT_ON_CE_COUNTER",
        set_sh_reg_index => "SET_SH_REG_INDEX",
        set_context_reg_indirect => "SET_CONTEXT_REG_INDIRECT",
        else => null,
    };
}

/// Whether this command starts a draw.
///
/// Worth asking directly: a stream is mostly state, and the draws are where one
/// frame's structure becomes visible.
pub fn isDraw(opcode: u8) bool {
    return switch (opcode) {
        draw_indirect,
        draw_index_indirect,
        draw_index_2,
        draw_indirect_multi,
        draw_index_auto,
        draw_index_multi_auto,
        draw_index_offset_2,
        draw_index_indirect_multi,
        => true,
        else => false,
    };
}

/// Whether this command starts compute work.
pub fn isDispatch(opcode: u8) bool {
    return opcode == dispatch_direct or opcode == dispatch_indirect;
}

/// Whether this command reads draw counts from an argument buffer named by
/// `SET_BASE` rather than from the packet itself.
pub fn isIndirectDraw(opcode: u8) bool {
    return switch (opcode) {
        draw_indirect, draw_index_indirect, draw_indirect_multi, draw_index_indirect_multi => true,
        else => false,
    };
}

/// One non-indexed `DRAW_INDIRECT` argument record.
pub const DrawIndirectArgs = extern struct {
    vertex_count: u32 = 0,
    instance_count: u32 = 0,
    start_vertex: u32 = 0,
    start_instance: u32 = 0,
};

/// One indexed `DRAW_INDEX_INDIRECT` argument record.
pub const DrawIndexedIndirectArgs = extern struct {
    index_count: u32 = 0,
    instance_count: u32 = 0,
    start_index: u32 = 0,
    base_vertex: i32 = 0,
    start_instance: u32 = 0,
};

pub const draw_indirect_args_bytes: u32 = @sizeOf(DrawIndirectArgs);
pub const draw_indexed_indirect_args_bytes: u32 = @sizeOf(DrawIndexedIndirectArgs);
/// Hardware and titles can name many records; a host loop still has to stop.
pub const maximum_indirect_draw_count: u32 = 4096;

/// What an indirect draw packet names before any argument record is read.
pub const IndirectDrawSpec = struct {
    data_offset: u32 = 0,
    indexed: bool = false,
    count: u32 = 1,
    count_from_memory: bool = false,
    count_address: u64 = 0,
    stride: u32 = draw_indirect_args_bytes,
};

pub fn indirectDrawArgBytes(indexed: bool) u32 {
    return if (indexed) draw_indexed_indirect_args_bytes else draw_indirect_args_bytes;
}

pub fn indexElementBytes(encoded: u2) u64 {
    return switch (encoded) {
        0, 3 => 2,
        1 => 4,
        2 => 1,
    };
}

pub fn parseDrawIndirectArgs(bytes: *const [@sizeOf(DrawIndirectArgs)]u8) DrawIndirectArgs {
    return .{
        .vertex_count = std.mem.readInt(u32, bytes[0..4], .little),
        .instance_count = std.mem.readInt(u32, bytes[4..8], .little),
        .start_vertex = std.mem.readInt(u32, bytes[8..12], .little),
        .start_instance = std.mem.readInt(u32, bytes[12..16], .little),
    };
}

pub fn parseDrawIndexedIndirectArgs(
    bytes: *const [@sizeOf(DrawIndexedIndirectArgs)]u8,
) DrawIndexedIndirectArgs {
    return .{
        .index_count = std.mem.readInt(u32, bytes[0..4], .little),
        .instance_count = std.mem.readInt(u32, bytes[4..8], .little),
        .start_index = std.mem.readInt(u32, bytes[8..12], .little),
        .base_vertex = @bitCast(std.mem.readInt(u32, bytes[12..16], .little)),
        .start_instance = std.mem.readInt(u32, bytes[16..20], .little),
    };
}

/// Recovers the argument-buffer reference from a draw packet body.
///
/// Single draws occupy four body words: byte offset, two unused patch words,
/// and the initiator. Multi draws occupy nine: the same prefix, a count
/// selector, a max/count, a 64-bit count address, a stride, and the initiator.
pub fn decodeIndirectDrawSpec(packet: Packet) ?IndirectDrawSpec {
    const indexed = switch (packet.opcode) {
        draw_index_indirect, draw_index_indirect_multi => true,
        draw_indirect, draw_indirect_multi => false,
        else => return null,
    };
    const default_stride = indirectDrawArgBytes(indexed);
    if (packet.opcode == draw_indirect or packet.opcode == draw_index_indirect) {
        if (packet.body.len < 1) return null;
        return .{
            .data_offset = packet.body[0],
            .indexed = indexed,
            .count = 1,
            .count_from_memory = false,
            .count_address = 0,
            .stride = default_stride,
        };
    }
    if (packet.body.len < 9) return null;
    return .{
        .data_offset = packet.body[0],
        .indexed = indexed,
        .count = packet.body[4],
        .count_from_memory = (packet.body[3] >> 30) & 1 != 0,
        .count_address = (@as(u64, packet.body[6]) << 32) | packet.body[5],
        .stride = packet.body[7],
    };
}

// ---------------------------------------------------------------------------
// Registers

/// Which bank of the register file a write lands in.
///
/// The register commands carry an offset within a bank rather than an absolute
/// index, so the bank has to be recovered from the opcode before an offset
/// means anything. Two different banks have registers at offset zero.
pub const RegisterSpace = enum {
    config,
    context,
    /// Per-shader-stage state: where shader addresses and their user data go.
    shader,
    /// State shared across contexts.
    uconfig,

    /// First word of this bank in the register file.
    pub fn base(self: RegisterSpace) u32 {
        return switch (self) {
            .config => 0x2000,
            .shader => 0x2c00,
            .context => 0xa000,
            .uconfig => 0xc000,
        };
    }
};

/// The bank a register command writes to, if it is one.
pub fn registerSpaceOf(opcode: u8) ?RegisterSpace {
    return switch (opcode) {
        set_config_reg => .config,
        set_context_reg, set_context_reg_index => .context,
        set_sh_reg, set_sh_reg_index, set_sh_reg_offset => .shader,
        set_uconfig_reg, set_uconfig_reg_index => .uconfig,
        else => null,
    };
}

/// Register bank selected by a Gen5 indirect register-list packet.
pub fn indirectRegisterSpaceOf(opcode: u8) ?RegisterSpace {
    return switch (opcode) {
        set_context_reg_indirect => .context,
        set_sh_reg_indirect => .shader,
        set_uconfig_reg_indirect => .uconfig,
        else => null,
    };
}

/// The first register a `SET_*_REG` packet writes, as an absolute word index.
///
/// Null when the packet is not a register write or carries no offset word,
/// which is the same question a caller would otherwise have to ask twice.
pub fn firstRegister(packet: Packet) ?u32 {
    if (packet.kind != .command) return null;
    const space = registerSpaceOf(packet.opcode) orelse return null;
    if (packet.body.len == 0) return null;
    return space.base() + (packet.body[0] & 0xffff);
}

/// How many registers a `SET_*_REG` packet writes.
///
/// The first body word is the offset; the rest are values.
pub fn registerCount(packet: Packet) usize {
    if (registerSpaceOf(packet.opcode) == null) return 0;
    if (packet.body.len == 0) return 0;
    return packet.body.len - 1;
}

// ---------------------------------------------------------------------------

/// Writes one packet the way someone reading a capture would want it.
pub fn write(packet: Packet, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (packet.kind) {
        .filler => {
            try w.writeAll("PAD");
            return;
        },
        .register_write => {
            try w.print(
                "WRITE_REG base=0x{x:0>4} count={d}",
                .{ packet.base_register, packet.body.len },
            );
            return;
        },
        .reserved => unreachable, // The walker refuses to produce one.
        .command => {},
    }

    if (customCode(packet)) |code| {
        if (customName(code)) |named| {
            try w.writeAll(named);
        } else if (code == custom.zero) {
            try w.writeAll("NOP");
        } else {
            try w.print("NOP custom=0x{x:0>2}", .{code});
        }
    } else if (packet.name()) |named| {
        try w.writeAll(named);
    } else {
        try w.print("op=0x{x:0>2}", .{packet.opcode});
    }

    if (firstRegister(packet)) |first| {
        const space = registerSpaceOf(packet.opcode).?;
        try w.print(" {s}[0x{x:0>4}] x{d}", .{ @tagName(space), first, registerCount(packet) });
    } else {
        try w.print(" {d} dwords", .{packet.body.len});
    }

    if (packet.compute) try w.writeAll(" compute");
    if (packet.predicated) try w.writeAll(" predicated");
}

/// Writes a whole stream, one packet per line, stopping at the first problem.
///
/// The error is reported in the output rather than only returned, because the
/// point of dumping a stream is usually to find out where it stopped making
/// sense, and that position is the answer.
pub fn writeStream(stream: []const u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var walker = Walker.init(stream);
    while (true) {
        const offset = walker.index;
        const packet = walker.next() catch |err| {
            try w.print("{d:0>5}: <{s} at this word>\n", .{ offset, @errorName(err) });
            return;
        } orelse return;
        try w.print("{d:0>5}: ", .{offset});
        try write(packet, w);
        try w.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a command header the way an encoder would.
fn command(opcode: u8, body_words: u14) u32 {
    return (@as(u32, 3) << kind_shift) |
        (@as(u32, body_words - 1) << count_shift) |
        (@as(u32, opcode) << opcode_shift);
}

test "a command header unpacks into opcode and body length" {
    const stream = [_]u32{ command(draw_index_auto, 2), 3, 0 };
    var walker = Walker.init(&stream);

    const packet = (try walker.next()).?;
    try testing.expectEqual(Kind.command, packet.kind);
    try testing.expectEqual(draw_index_auto, packet.opcode);
    try testing.expectEqual(@as(usize, 2), packet.body.len);
    try testing.expectEqualStrings("DRAW_INDEX_AUTO", packet.name().?);
    try testing.expectEqual(@as(usize, 3), packet.wordCount());
    try testing.expect(try walker.next() == null);
}

test "a body is always at least one word" {
    // The count is stored biased by one, so a zero field means one word. A
    // decoder reading it literally would misplace every following packet.
    const stream = [_]u32{ command(pfp_sync_me, 1), 0 };
    var walker = Walker.init(&stream);
    try testing.expectEqual(@as(usize, 1), (try walker.next()).?.body.len);
}

test "padding carries nothing and does not consume what follows" {
    const stream = [_]u32{
        (@as(u32, 2) << kind_shift) | 0x3fff_ffff,
        command(nop, 1),
        0,
    };
    var walker = Walker.init(&stream);

    const pad = (try walker.next()).?;
    try testing.expectEqual(Kind.filler, pad.kind);
    try testing.expectEqual(@as(usize, 0), pad.body.len);
    // The count field is set in that header, and honouring it would swallow the
    // rest of the stream.
    try testing.expectEqual(nop, (try walker.next()).?.opcode);
}

test "a register-write packet reports its base and length" {
    const stream = [_]u32{ (@as(u32, 1) << count_shift) | 0x00c4, 7, 8 };
    var walker = Walker.init(&stream);
    const packet = (try walker.next()).?;
    try testing.expectEqual(Kind.register_write, packet.kind);
    try testing.expectEqual(@as(u16, 0xc4), packet.base_register);
    try testing.expectEqual(@as(usize, 2), packet.body.len);
}

test "a body running past the buffer is refused, not clipped" {
    // A stream is read out of guest memory, where a title's bug or a wrongly
    // resolved address can claim more than the buffer holds.
    const stream = [_]u32{ command(write_data, 8), 1, 2 };
    var walker = Walker.init(&stream);
    try testing.expectError(Error.Truncated, walker.next());
}

test "the unassigned packet type is reported rather than skipped" {
    // Meeting one means the stream is being read at the wrong offset, and
    // skipping ahead would produce confident nonsense from there on.
    const stream = [_]u32{@as(u32, 1) << kind_shift};
    var walker = Walker.init(&stream);
    try testing.expectError(Error.ReservedPacket, walker.next());
}

test "an empty stream ends immediately" {
    var walker = Walker.init(&[_]u32{});
    try testing.expect(try walker.next() == null);
    try testing.expectEqual(@as(usize, 0), walker.remaining());
}

test "consecutive packets are delimited by their own headers" {
    const stream = [_]u32{
        command(set_context_reg, 3), 0x0206, 0x1111,                      0x2222,
        command(num_instances, 1),   1,      command(draw_index_auto, 2), 6,
        0,
    };
    var walker = Walker.init(&stream);

    try testing.expectEqual(set_context_reg, (try walker.next()).?.opcode);
    try testing.expectEqual(num_instances, (try walker.next()).?.opcode);

    const draw = (try walker.next()).?;
    try testing.expect(isDraw(draw.opcode));
    try testing.expectEqual(@as(u32, 6), draw.body[0]);
    try testing.expect(try walker.next() == null);
}

test "the predicate and pipe flags are read from the header" {
    const stream = [_]u32{
        command(dispatch_direct, 3) | shader_type_bit | predicate_bit,
        1,
        1,
        1,
    };
    var walker = Walker.init(&stream);
    const packet = (try walker.next()).?;
    try testing.expect(packet.compute);
    try testing.expect(packet.predicated);
    try testing.expect(isDispatch(packet.opcode));
}

test "a register offset is resolved against the bank its opcode names" {
    // Two banks have a register at offset zero, so an offset means nothing
    // until the opcode says which file it indexes.
    const context_stream = [_]u32{ command(set_context_reg, 2), 0, 0x1234 };
    var context_walker = Walker.init(&context_stream);
    const context_packet = (try context_walker.next()).?;
    try testing.expectEqual(RegisterSpace.context, registerSpaceOf(context_packet.opcode).?);
    try testing.expectEqual(@as(u32, 0xa000), firstRegister(context_packet).?);
    try testing.expectEqual(@as(usize, 1), registerCount(context_packet));

    const shader_stream = [_]u32{ command(set_sh_reg, 3), 0, 0x1234, 0x5678 };
    var shader_walker = Walker.init(&shader_stream);
    const shader_packet = (try shader_walker.next()).?;
    try testing.expectEqual(@as(u32, 0x2c00), firstRegister(shader_packet).?);
    try testing.expectEqual(@as(usize, 2), registerCount(shader_packet));

    // A command that writes no registers has no register to report.
    const draw_stream = [_]u32{ command(draw_index_auto, 2), 3, 0 };
    var draw_walker = Walker.init(&draw_stream);
    try testing.expect(firstRegister((try draw_walker.next()).?) == null);
}

test "an undocumented opcode is reported by number, not invented" {
    const stream = [_]u32{ command(0xf3, 1), 0 };
    var walker = Walker.init(&stream);
    const packet = (try walker.next()).?;
    try testing.expect(packet.name() == null);

    var buffer: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try write(packet, &w);
    try testing.expectEqualStrings("op=0xf3 1 dwords", w.buffered());
}

test "a packet is written the way a capture is read" {
    var buffer: [128]u8 = undefined;

    var w = std.Io.Writer.fixed(&buffer);
    const registers = [_]u32{ command(set_sh_reg, 3), 0x000c, 0, 0 };
    var register_walker = Walker.init(&registers);
    try write((try register_walker.next()).?, &w);
    try testing.expectEqualStrings("SET_SH_REG shader[0x2c0c] x2", w.buffered());

    var draw_writer = std.Io.Writer.fixed(&buffer);
    const draw = [_]u32{ command(draw_index_auto, 2) | shader_type_bit, 3, 0 };
    var draw_walker = Walker.init(&draw);
    try write((try draw_walker.next()).?, &draw_writer);
    try testing.expectEqualStrings("DRAW_INDEX_AUTO 2 dwords compute", draw_writer.buffered());
}

test "Gen5 indirect registers and custom NOP commands keep their real names" {
    try testing.expectEqual(
        RegisterSpace.context,
        indirectRegisterSpaceOf(set_context_reg_indirect).?,
    );
    try testing.expectEqual(RegisterSpace.shader, indirectRegisterSpaceOf(set_sh_reg_indirect).?);
    try testing.expect(registerSpaceOf(set_context_reg_indirect) == null);

    const stream = [_]u32{
        command(nop, 7) | (@as(u32, custom.release_mem) << 2),
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    };
    var walker = Walker.init(&stream);
    const packet = (try walker.next()).?;
    try testing.expectEqual(custom.release_mem, customCode(packet).?);
    try testing.expectEqualStrings("R_RELEASE_MEM", packet.name().?);

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(packet, &writer);
    try testing.expectEqualStrings("R_RELEASE_MEM 7 dwords", writer.buffered());
}

test "a dumped stream names where it stopped making sense" {
    const stream = [_]u32{
        command(clear_state, 1), 0,
        command(cp_dma, 9),      1,
    };
    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try writeStream(&stream, &w);

    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "00000: CLEAR_STATE") != null);
    try testing.expect(std.mem.indexOf(u8, text, "00002: <Truncated at this word>") != null);
}

test "every named opcode round-trips through its own constant" {
    // The names exist to be trusted in a trace; a table entry pointing at the
    // wrong constant would misname a command everywhere it appears.
    try testing.expectEqualStrings("DRAW_INDEX_2", opcodeName(0x27).?);
    try testing.expectEqualStrings("SET_CONTEXT_REG", opcodeName(0x69).?);
    try testing.expectEqualStrings("SET_SH_REG", opcodeName(0x76).?);
    try testing.expectEqualStrings("SET_UCONFIG_REG", opcodeName(0x79).?);
    try testing.expectEqualStrings("SET_SH_REG_INDIRECT", opcodeName(0x63).?);
    try testing.expectEqualStrings("SET_CONTEXT_REG_INDIRECT", opcodeName(0x9f).?);
    try testing.expectEqualStrings("RELEASE_MEM", opcodeName(0x49).?);
    try testing.expectEqualStrings("INDIRECT_BUFFER", opcodeName(0x3f).?);
    try testing.expect(opcodeName(0x14) == null);
}

test "indirect draw packets recover their argument-buffer reference" {
    const single = [_]u32{ command(draw_indirect, 4), 0x40, 0, 0, 2 };
    var single_walker = Walker.init(&single);
    const single_spec = decodeIndirectDrawSpec((try single_walker.next()).?).?;
    try testing.expect(!single_spec.indexed);
    try testing.expectEqual(@as(u32, 0x40), single_spec.data_offset);
    try testing.expectEqual(@as(u32, 1), single_spec.count);
    try testing.expectEqual(draw_indirect_args_bytes, single_spec.stride);

    const indexed = [_]u32{ command(draw_index_indirect, 4), 0x80, 0, 0, 2 };
    var indexed_walker = Walker.init(&indexed);
    const indexed_spec = decodeIndirectDrawSpec((try indexed_walker.next()).?).?;
    try testing.expect(indexed_spec.indexed);
    try testing.expectEqual(draw_indexed_indirect_args_bytes, indexed_spec.stride);

    const multi = [_]u32{
        command(draw_index_indirect_multi, 9),
        0x20,
        0,
        0,
        1 << 30,
        8,
        0x1000,
        0,
        24,
        2,
    };
    var multi_walker = Walker.init(&multi);
    const multi_spec = decodeIndirectDrawSpec((try multi_walker.next()).?).?;
    try testing.expect(multi_spec.indexed);
    try testing.expect(multi_spec.count_from_memory);
    try testing.expectEqual(@as(u32, 0x20), multi_spec.data_offset);
    try testing.expectEqual(@as(u32, 8), multi_spec.count);
    try testing.expectEqual(@as(u64, 0x1000), multi_spec.count_address);
    try testing.expectEqual(@as(u32, 24), multi_spec.stride);
    try testing.expect(isIndirectDraw(draw_indirect_multi));
    try testing.expect(!isIndirectDraw(draw_index_2));
}

test "indirect draw argument records keep their field order" {
    var non_indexed: [@sizeOf(DrawIndirectArgs)]u8 = undefined;
    std.mem.writeInt(u32, non_indexed[0..4], 12, .little);
    std.mem.writeInt(u32, non_indexed[4..8], 3, .little);
    std.mem.writeInt(u32, non_indexed[8..12], 4, .little);
    std.mem.writeInt(u32, non_indexed[12..16], 7, .little);
    const draw = parseDrawIndirectArgs(&non_indexed);
    try testing.expectEqual(@as(u32, 12), draw.vertex_count);
    try testing.expectEqual(@as(u32, 3), draw.instance_count);
    try testing.expectEqual(@as(u32, 4), draw.start_vertex);
    try testing.expectEqual(@as(u32, 7), draw.start_instance);

    var indexed: [@sizeOf(DrawIndexedIndirectArgs)]u8 = undefined;
    std.mem.writeInt(u32, indexed[0..4], 9, .little);
    std.mem.writeInt(u32, indexed[4..8], 2, .little);
    std.mem.writeInt(u32, indexed[8..12], 5, .little);
    std.mem.writeInt(u32, indexed[12..16], @bitCast(@as(i32, -3)), .little);
    std.mem.writeInt(u32, indexed[16..20], 1, .little);
    const indexed_draw = parseDrawIndexedIndirectArgs(&indexed);
    try testing.expectEqual(@as(u32, 9), indexed_draw.index_count);
    try testing.expectEqual(@as(u32, 2), indexed_draw.instance_count);
    try testing.expectEqual(@as(u32, 5), indexed_draw.start_index);
    try testing.expectEqual(@as(i32, -3), indexed_draw.base_vertex);
    try testing.expectEqual(@as(u32, 1), indexed_draw.start_instance);
    try testing.expectEqual(@as(u64, 2), indexElementBytes(0));
    try testing.expectEqual(@as(u64, 4), indexElementBytes(1));
}
