// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bounded scalar execution at a draw/dispatch boundary.
//!
//! The shader receives the exact USER_DATA snapshot captured from PM4. This
//! evaluator follows its straight scalar prolog, performs checked SMEM reads,
//! and records which roots contributed to every value. It deliberately stops
//! at an instruction family whose length/semantics are not known yet.

const std = @import("std");
const rdna2 = @import("rdna2");
const shaders = @import("shaders.zig");

pub const maximum_scalar_registers = 128;
pub const maximum_loads = 128;
pub const maximum_instructions = 4096;
const address_mask: u64 = 0x0000_ffff_ffff_ffff;

pub const Sources = packed struct(u8) {
    user_data: bool = false,
    immediate: bool = false,
    memory: bool = false,
    program_counter: bool = false,
    _reserved: u4 = 0,

    pub fn merge(a: Sources, b: Sources) Sources {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }
};

pub const ScalarValue = struct {
    known: bool = false,
    value: u32 = 0,
    sources: Sources = .{},
    producer_pc: u32 = 0,
};

pub const ScalarLoad = struct {
    pc: u32,
    address: u64,
    destination: u8,
    word_count: u8,
    buffer_descriptor: bool,
    from_srt: bool,
    base_sources: Sources,
    offset_sources: Sources,
};

pub const StopReason = enum {
    prefix_complete,
    end_program,
    branch,
    unknown_family,
    unsupported_instruction,
    inaccessible_code,
    inaccessible_memory,
    invalid_address,
    instruction_limit,
};

pub const Evaluation = struct {
    registers: [maximum_scalar_registers]ScalarValue = [_]ScalarValue{.{}} ** maximum_scalar_registers,
    loads: [maximum_loads]ScalarLoad = undefined,
    load_count: usize = 0,
    instruction_count: u32 = 0,
    stop_pc: u32 = 0,
    stop_reason: StopReason = .instruction_limit,

    pub fn register(self: *const Evaluation, index: u8) ?ScalarValue {
        const value = self.registers[index];
        return if (value.known) value else null;
    }

    pub fn loadSlice(self: *const Evaluation) []const ScalarLoad {
        return self.loads[0..self.load_count];
    }
};

pub fn evaluatePrefix(reader: shaders.MemoryReader, bindings: *const shaders.StageBindings) Evaluation {
    return evaluate(reader, bindings, null, false);
}

/// Evaluates scalar resource setup past lane-mask branches. EXEC/VCC branches
/// only decide whether active lanes reach a memory operation; the descriptor
/// used by lanes that do reach it is normally prepared on the fallthrough
/// path. Following that path recovers late V#/T# loads without changing the
/// strict prefix evaluator used for shader specialization.
pub fn evaluateResourceState(reader: shaders.MemoryReader, bindings: *const shaders.StageBindings) Evaluation {
    return evaluate(reader, bindings, null, true);
}

/// Recovers descriptor state immediately before one vector-memory instruction.
/// Compute kernels may reload the same T#/S# SGPRs for several resources, so a
/// final whole-program snapshot is not authoritative for an earlier sample.
pub fn evaluateResourceStateUntil(
    reader: shaders.MemoryReader,
    bindings: *const shaders.StageBindings,
    end_pc: u32,
) Evaluation {
    return evaluate(reader, bindings, end_pc, true);
}

/// Evaluates only the straight scalar region ending before `end_pc`. This is
/// the dispatch-specialization entry point: later scalar writes must not alter
/// descriptors captured for the first vector-memory instruction.
pub fn evaluatePrefixUntil(
    reader: shaders.MemoryReader,
    bindings: *const shaders.StageBindings,
    end_pc: u32,
) Evaluation {
    return evaluate(reader, bindings, end_pc, false);
}

fn evaluate(
    reader: shaders.MemoryReader,
    bindings: *const shaders.StageBindings,
    end_pc: ?u32,
    follow_lane_mask_fallthrough: bool,
) Evaluation {
    var result = Evaluation{};
    const scalar_base: usize = bindings.scalar_user_data_base;
    const available = @min(
        @as(usize, bindings.user_data_count),
        maximum_scalar_registers - scalar_base,
    );
    for (bindings.user_data[0..available], 0..) |word, index| {
        result.registers[scalar_base + index] = .{
            .known = true,
            .value = word,
            .sources = .{ .user_data = true },
        };
    }

    var scc: ?bool = null;
    var pc: u32 = 0;
    while (result.instruction_count < maximum_instructions) {
        result.stop_pc = pc;
        if (end_pc) |end| {
            if (pc >= end) {
                result.stop_reason = .prefix_complete;
                return result;
            }
        }
        var words = [_]u32{ 0, 0 };
        words[0] = reader.readU32(addProgramAddress(bindings.program_address, pc) orelse {
            result.stop_reason = .invalid_address;
            return result;
        }) catch {
            result.stop_reason = .inaccessible_code;
            return result;
        };

        // Decode may need a second word; unknown major families are skipped so a
        // later SMEM load of a V# still runs. Stopping the prolog at the first
        // unrecognised packet was producing MissingStorageDescriptor on every
        // resource the shader used after that point.
        var decoded: ?rdna2.Instruction = null;
        if (rdna2.decodeInstruction(pc, words[0..1], 0)) |inst| {
            decoded = inst;
        } else |err| switch (err) {
            error.MissingLiteralConstant, error.TruncatedInstruction => {
                words[1] = reader.readU32(addProgramAddress(bindings.program_address, pc + 4) orelse {
                    result.stop_reason = .invalid_address;
                    return result;
                }) catch {
                    result.stop_reason = .inaccessible_code;
                    return result;
                };
                if (rdna2.decodeInstruction(pc, &words, 0)) |inst| {
                    decoded = inst;
                } else |_| {
                    pc +%= if (words[0] & 0xc000_0000 == 0xc000_0000) @as(u32, 8) else 4;
                    result.instruction_count += 1;
                    continue;
                }
            },
            else => {
                // Unknown family, operand decode failures, etc. — skip rather
                // than abort the whole prolog before SMEM V# loads.
                pc +%= if (words[0] & 0xc000_0000 == 0xc000_0000) @as(u32, 8) else 4;
                result.instruction_count += 1;
                continue;
            },
        }
        const inst = decoded orelse {
            // Defensive: decode produced neither an instruction nor a handled
            // error. Advance one dword rather than spinning.
            pc +%= 4;
            result.instruction_count += 1;
            continue;
        };
        result.instruction_count += 1;

        if (inst.opcode == .unsupported) {
            // Skip unknown opcodes inside a known family; do not abort the prolog.
            invalidateDestination(&result, inst.dst, @max(inst.data_words, 1));
            pc +%= inst.word_count * 4;
            continue;
        }
        if (inst.family == .smem) {
            if (!executeSmem(&result, reader, bindings, inst)) {
                if (result.stop_reason == .instruction_limit) result.stop_reason = .inaccessible_memory;
                return result;
            }
        } else switch (inst.opcode) {
            .s_endpgm, .s_code_end => {
                result.stop_reason = .end_program;
                return result;
            },
            .s_setpc_b64 => {
                result.stop_reason = .branch;
                return result;
            },
            .s_branch,
            .s_cbranch_scc0,
            .s_cbranch_scc1,
            .s_cbranch_vccz,
            .s_cbranch_vccnz,
            .s_cbranch_execz,
            .s_cbranch_execnz,
            => {
                const taken = switch (inst.opcode) {
                    .s_branch => true,
                    .s_cbranch_scc0 => if (scc) |value| !value else null,
                    .s_cbranch_scc1 => scc,
                    else => null,
                };
                if (taken) |is_taken| {
                    pc = if (is_taken) inst.branch_target else pc + inst.word_count * 4;
                    continue;
                }
                if (follow_lane_mask_fallthrough and switch (inst.opcode) {
                    .s_cbranch_vccz, .s_cbranch_vccnz, .s_cbranch_execz, .s_cbranch_execnz => true,
                    else => false,
                }) {
                    pc +%= inst.word_count * 4;
                    continue;
                }
                result.stop_reason = .branch;
                return result;
            },
            .s_nop, .s_waitcnt, .s_barrier, .s_sleep, .s_sendmsg, .s_ttrace_data, .s_inst_prefetch => {},
            else => executeScalar(&result, bindings.program_address, inst, &scc),
        }
        pc +%= inst.word_count * 4;
    }

    result.stop_pc = pc;
    result.stop_reason = .instruction_limit;
    return result;
}

fn executeSmem(
    result: *Evaluation,
    reader: shaders.MemoryReader,
    bindings: *const shaders.StageBindings,
    inst: rdna2.Instruction,
) bool {
    const base_lo = source(result, inst.src0) orelse {
        invalidateDestination(result, inst.dst, inst.data_words);
        result.stop_reason = .invalid_address;
        return false;
    };
    if (inst.src0.kind != .sgpr or inst.src0.reg + 1 >= maximum_scalar_registers) {
        result.stop_reason = .invalid_address;
        return false;
    }
    const base_hi = result.registers[inst.src0.reg + 1];
    const offset = source(result, inst.src1) orelse {
        invalidateDestination(result, inst.dst, inst.data_words);
        result.stop_reason = .invalid_address;
        return false;
    };
    if (!base_hi.known) {
        invalidateDestination(result, inst.dst, inst.data_words);
        result.stop_reason = .invalid_address;
        return false;
    }

    const is_buffer_load = switch (inst.opcode) {
        .s_buffer_load_dword,
        .s_buffer_load_dwordx2,
        .s_buffer_load_dwordx4,
        .s_buffer_load_dwordx8,
        .s_buffer_load_dwordx16,
        => true,
        else => false,
    };
    if (!is_buffer_load and base_hi.value & 0xffff_0000 != 0) {
        invalidateDestination(result, inst.dst, inst.data_words);
        result.stop_reason = .invalid_address;
        return false;
    }
    const base = @as(u64, base_lo.value) | (@as(u64, base_hi.value & 0xffff) << 32);
    const displacement = @as(i64, inst.memory_offset) + @as(i64, offset.value);
    const unaligned_address = addSigned(base, displacement) orelse {
        invalidateDestination(result, inst.dst, inst.data_words);
        result.stop_reason = .invalid_address;
        return false;
    };
    // GFX10 scalar loads operate on dwords and ignore the low two address bits.
    const address = unaligned_address & ~@as(u64, 3);
    const load_bytes = @as(u64, inst.data_words) * 4;
    if (address > address_mask or load_bytes > address_mask - address + 1) {
        invalidateDestination(result, inst.dst, inst.data_words);
        result.stop_reason = .invalid_address;
        return false;
    }
    if (inst.dst.kind != .sgpr or @as(usize, inst.dst.reg) + inst.data_words > maximum_scalar_registers) {
        result.stop_reason = .invalid_address;
        return false;
    }

    var loaded: [16]u32 = undefined;
    for (loaded[0..inst.data_words], 0..) |*word, index| {
        word.* = reader.readU32(address + index * 4) catch {
            invalidateDestination(result, inst.dst, inst.data_words);
            result.stop_reason = .inaccessible_memory;
            return false;
        };
    }

    const base_sources = Sources.merge(base_lo.sources, base_hi.sources);
    const loaded_sources = Sources.merge(Sources.merge(base_sources, offset.sources), .{ .memory = true });
    for (loaded[0..inst.data_words], 0..) |word, index| {
        result.registers[inst.dst.reg + index] = .{
            .known = true,
            .value = word,
            .sources = loaded_sources,
            .producer_pc = inst.pc,
        };
    }
    if (result.load_count < maximum_loads) {
        result.loads[result.load_count] = .{
            .pc = inst.pc,
            .address = address,
            .destination = @intCast(inst.dst.reg),
            .word_count = inst.data_words,
            .buffer_descriptor = is_buffer_load,
            .from_srt = addressInsideSrt(bindings, address, inst.data_words),
            .base_sources = base_sources,
            .offset_sources = offset.sources,
        };
        result.load_count += 1;
    }
    return true;
}

fn executeScalar(result: *Evaluation, program_address: u64, inst: rdna2.Instruction, scc: *?bool) void {
    if (inst.opcode == .s_getpc_b64 and inst.dst.kind == .sgpr and inst.dst.reg + 1 < maximum_scalar_registers) {
        const address = program_address + inst.pc + 4;
        const sources = Sources{ .program_counter = true };
        result.registers[inst.dst.reg] = .{ .known = true, .value = @truncate(address), .sources = sources, .producer_pc = inst.pc };
        result.registers[inst.dst.reg + 1] = .{ .known = true, .value = @truncate(address >> 32), .sources = sources, .producer_pc = inst.pc };
        return;
    }

    if (isComparison(inst.opcode)) {
        const a = source(result, inst.src0) orelse {
            scc.* = null;
            return;
        };
        const b = source(result, inst.src1) orelse {
            scc.* = null;
            return;
        };
        scc.* = compare(inst.opcode, a.value, b.value);
        return;
    }

    const a = source(result, inst.src0) orelse {
        invalidateDestination(result, inst.dst, destinationWords(inst.opcode));
        return;
    };
    const b = if (inst.src_count >= 2) source(result, inst.src1) else null;
    const combined_sources = if (b) |value| Sources.merge(a.sources, value.sources) else a.sources;

    if (destinationWords(inst.opcode) == 2) {
        executeScalar64(result, inst, a, b, combined_sources);
        return;
    }
    const bv = if (b) |value| value.value else 0;
    const value: ?u32 = switch (inst.opcode) {
        .s_mov_b32, .s_movk_i32 => a.value,
        .s_not_b32 => ~a.value,
        .s_abs_i32 => absolute: {
            const signed: i32 = @bitCast(a.value);
            break :absolute if (signed < 0) (0 -% a.value) else a.value;
        },
        .s_brev_b32 => @bitReverse(a.value),
        .s_bcnt1_i32_b32 => @popCount(a.value),
        .s_ff1_i32_b32 => if (a.value == 0) 0xffff_ffff else @ctz(a.value),
        .s_add_u32 => add: {
            const sum = @addWithOverflow(a.value, bv);
            scc.* = sum[1] != 0;
            break :add sum[0];
        },
        .s_add_i32 => signed_add: {
            scc.* = null;
            break :signed_add a.value +% bv;
        },
        .s_sub_u32 => sub: {
            const difference = @subWithOverflow(a.value, bv);
            scc.* = difference[1] == 0;
            break :sub difference[0];
        },
        .s_sub_i32 => signed_sub: {
            scc.* = null;
            break :signed_sub a.value -% bv;
        },
        .s_addc_u32 => addc: {
            const carry: u32 = @intFromBool(scc.* orelse false);
            const first = @addWithOverflow(a.value, bv);
            const second = @addWithOverflow(first[0], carry);
            scc.* = first[1] != 0 or second[1] != 0;
            break :addc second[0];
        },
        .s_subb_u32 => subb: {
            const borrow: u32 = @intFromBool(!(scc.* orelse true));
            const first = @subWithOverflow(a.value, bv);
            const second = @subWithOverflow(first[0], borrow);
            scc.* = first[1] == 0 and second[1] == 0;
            break :subb second[0];
        },
        .s_and_b32 => a.value & bv,
        .s_or_b32 => a.value | bv,
        .s_xor_b32 => a.value ^ bv,
        .s_andn2_b32 => a.value & ~bv,
        .s_orn2_b32 => a.value | ~bv,
        .s_nand_b32 => ~(a.value & bv),
        .s_nor_b32 => ~(a.value | bv),
        .s_xnor_b32 => ~(a.value ^ bv),
        .s_lshl_b32 => a.value << @truncate(bv & 31),
        .s_lshr_b32 => a.value >> @truncate(bv & 31),
        .s_ashr_i32 => @bitCast(@as(i32, @bitCast(a.value)) >> @truncate(bv & 31)),
        .s_mul_i32, .s_mulk_i32 => a.value *% bv,
        .s_mul_hi_u32 => @truncate((@as(u64, a.value) * @as(u64, bv)) >> 32),
        .s_lshl1_add_u32 => (a.value << 1) +% bv,
        .s_lshl2_add_u32 => (a.value << 2) +% bv,
        .s_lshl3_add_u32 => (a.value << 3) +% bv,
        .s_lshl4_add_u32 => (a.value << 4) +% bv,
        .s_min_u32 => @min(a.value, bv),
        .s_max_u32 => @max(a.value, bv),
        .s_min_i32 => @bitCast(@min(@as(i32, @bitCast(a.value)), @as(i32, @bitCast(bv)))),
        .s_max_i32 => @bitCast(@max(@as(i32, @bitCast(a.value)), @as(i32, @bitCast(bv)))),
        else => null,
    };
    if (value) |known| write(result, inst.dst, known, combined_sources, inst.pc) else invalidateDestination(result, inst.dst, 1);
}

fn executeScalar64(result: *Evaluation, inst: rdna2.Instruction, a: ScalarValue, b: ?ScalarValue, sources: Sources) void {
    if (inst.src0.kind != .sgpr or inst.src0.reg + 1 >= maximum_scalar_registers or
        inst.dst.kind != .sgpr or inst.dst.reg + 1 >= maximum_scalar_registers)
    {
        invalidateDestination(result, inst.dst, 2);
        return;
    }
    const a_hi = result.registers[inst.src0.reg + 1];
    if (!a_hi.known) {
        invalidateDestination(result, inst.dst, 2);
        return;
    }
    var all_sources = Sources.merge(sources, a_hi.sources);
    const av = @as(u64, a.value) | (@as(u64, a_hi.value) << 32);
    var bv: u64 = 0;
    if (b) |low| {
        if (inst.src1.kind != .sgpr or inst.src1.reg + 1 >= maximum_scalar_registers) {
            invalidateDestination(result, inst.dst, 2);
            return;
        }
        const high = result.registers[inst.src1.reg + 1];
        if (!high.known) {
            invalidateDestination(result, inst.dst, 2);
            return;
        }
        bv = @as(u64, low.value) | (@as(u64, high.value) << 32);
        all_sources = Sources.merge(all_sources, high.sources);
    }
    const value: ?u64 = switch (inst.opcode) {
        .s_mov_b64 => av,
        .s_not_b64 => ~av,
        .s_and_b64 => av & bv,
        .s_or_b64 => av | bv,
        .s_xor_b64 => av ^ bv,
        .s_andn2_b64 => av & ~bv,
        .s_orn2_b64 => av | ~bv,
        .s_nand_b64 => ~(av & bv),
        .s_nor_b64 => ~(av | bv),
        .s_xnor_b64 => ~(av ^ bv),
        .s_lshl_b64 => av << @truncate(bv & 63),
        .s_lshr_b64 => av >> @truncate(bv & 63),
        else => null,
    };
    if (value) |known| {
        write(result, inst.dst, @truncate(known), all_sources, inst.pc);
        result.registers[inst.dst.reg + 1] = .{ .known = true, .value = @truncate(known >> 32), .sources = all_sources, .producer_pc = inst.pc };
    } else invalidateDestination(result, inst.dst, 2);
}

fn source(result: *const Evaluation, operand: rdna2.Operand) ?ScalarValue {
    return switch (operand.kind) {
        .sgpr => if (operand.reg < maximum_scalar_registers and result.registers[operand.reg].known) result.registers[operand.reg] else null,
        .integer_inline_constant, .float_inline_constant, .literal_constant => .{
            .known = true,
            .value = operand.value,
            .sources = .{ .immediate = true },
        },
        .null => .{ .known = true, .value = 0, .sources = .{ .immediate = true } },
        else => null,
    };
}

fn write(result: *Evaluation, destination: rdna2.Operand, value: u32, sources: Sources, pc: u32) void {
    if (destination.kind != .sgpr or destination.reg >= maximum_scalar_registers) return;
    result.registers[destination.reg] = .{ .known = true, .value = value, .sources = sources, .producer_pc = pc };
}

fn invalidateDestination(result: *Evaluation, destination: rdna2.Operand, count: u8) void {
    if (destination.kind != .sgpr or destination.reg >= maximum_scalar_registers) return;
    const end = @min(maximum_scalar_registers, @as(usize, destination.reg) + count);
    for (result.registers[destination.reg..end]) |*value| value.* = .{};
}

fn destinationWords(opcode: rdna2.Opcode) u8 {
    return switch (opcode) {
        .s_mov_b64,
        .s_not_b64,
        .s_wqm_b64,
        .s_cselect_b64,
        .s_and_b64,
        .s_or_b64,
        .s_xor_b64,
        .s_andn2_b64,
        .s_orn2_b64,
        .s_nand_b64,
        .s_nor_b64,
        .s_xnor_b64,
        .s_lshl_b64,
        .s_lshr_b64,
        .s_bfm_b64,
        .s_bfe_u64,
        .s_bitreplicate_b64_b32,
        => 2,
        else => 1,
    };
}

fn isComparison(opcode: rdna2.Opcode) bool {
    return switch (opcode) {
        .s_cmp_eq_i32, .s_cmp_lg_i32, .s_cmp_gt_i32, .s_cmp_ge_i32, .s_cmp_lt_i32, .s_cmp_le_i32, .s_cmp_eq_u32, .s_cmp_lg_u32, .s_cmp_gt_u32, .s_cmp_ge_u32, .s_cmp_lt_u32, .s_cmp_le_u32 => true,
        else => false,
    };
}

fn compare(opcode: rdna2.Opcode, a: u32, b: u32) bool {
    const ai: i32 = @bitCast(a);
    const bi: i32 = @bitCast(b);
    return switch (opcode) {
        .s_cmp_eq_i32, .s_cmp_eq_u32 => a == b,
        .s_cmp_lg_i32, .s_cmp_lg_u32 => a != b,
        .s_cmp_gt_i32 => ai > bi,
        .s_cmp_ge_i32 => ai >= bi,
        .s_cmp_lt_i32 => ai < bi,
        .s_cmp_le_i32 => ai <= bi,
        .s_cmp_gt_u32 => a > b,
        .s_cmp_ge_u32 => a >= b,
        .s_cmp_lt_u32 => a < b,
        .s_cmp_le_u32 => a <= b,
        else => false,
    };
}

fn addressInsideSrt(bindings: *const shaders.StageBindings, address: u64, words: u8) bool {
    const start = bindings.srt_address orelse return false;
    const metadata = bindings.metadata orelse return false;
    const size = @as(u64, metadata.shader_resource_table_size_words) * 4;
    const bytes = @as(u64, words) * 4;
    return address >= start and address - start <= size and bytes <= size - (address - start);
}

fn addProgramAddress(base: u64, pc: u32) ?u64 {
    return std.math.add(u64, base, pc) catch null;
}

fn addSigned(base: u64, offset: i64) ?u64 {
    if (offset >= 0) return std.math.add(u64, base, @intCast(offset)) catch null;
    return std.math.sub(u64, base, @intCast(-offset)) catch null;
}

// ---------------------------------------------------------------------------
// Tests

const TestMemory = struct {
    base: u64,
    bytes: []u8,

    fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
        const self: *TestMemory = @ptrCast(@alignCast(context.?));
        if (address < self.base) return false;
        const offset: usize = @intCast(address - self.base);
        if (offset > self.bytes.len or destination.len > self.bytes.len - offset) return false;
        @memcpy(destination, self.bytes[offset .. offset + destination.len]);
        return true;
    }

    fn reader(self: *TestMemory) shaders.MemoryReader {
        return .{ .context = self, .read_fn = read };
    }

    fn write(self: *TestMemory, address: u64, value: u32) void {
        const offset: usize = @intCast(address - self.base);
        std.mem.writeInt(u32, self.bytes[offset..][0..4], value, .little);
    }
};

fn testBindings(program: u64, srt: u64) shaders.StageBindings {
    var user_data = [_]u32{0} ** 64;
    user_data[0] = @truncate(srt);
    user_data[1] = @truncate(srt >> 32);
    return .{
        .stage = .vertex,
        .user_data_stage = .vertex,
        .program_address = program,
        .user_data_count = 2,
        .scalar_user_data_base = 0,
        .user_data = user_data,
        .metadata = .{
            .header_address = 0,
            .user_data_address = 0,
            .direct_offsets_address = 0,
            .resource_offsets_addresses = .{ 0, 0, 0, 0 },
            .extended_user_data_size_words = 0,
            .shader_resource_table_size_words = 32,
            .direct_resource_count = 0,
            .resource_counts = .{ 0, 0, 0, 0 },
            .input_semantics_address = 0,
            .input_semantics_count = 0,
        },
        .srt_address = srt,
        .direct_pointers = .{},
    };
}

test "scalar provenance follows an SRT pointer through ALU and SMEM" {
    var storage = [_]u8{0} ** 0x500;
    var memory = TestMemory{ .base = 0x1000, .bytes = &storage };
    const program: u64 = 0x1000;
    const srt: u64 = 0x1200;
    // s4 = s0 + 16; s5 = s1 + carry; load s8:s9 from s4:s5 + 8.
    memory.write(program + 0, 0x8004_9000);
    memory.write(program + 4, 0x8205_8001);
    memory.write(program + 8, 0xf404_0202);
    memory.write(program + 12, (125 << 25) | 8);
    memory.write(program + 16, 0xbf81_0000);
    memory.write(srt + 24, 0x1122_3344);
    memory.write(srt + 28, 0x5566_7788);

    const bindings = testBindings(program, srt);
    const result = evaluatePrefix(memory.reader(), &bindings);
    try std.testing.expectEqual(StopReason.end_program, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), result.load_count);
    try std.testing.expect(result.loads[0].from_srt);
    try std.testing.expect(result.loads[0].base_sources.user_data);
    try std.testing.expect(result.loads[0].base_sources.immediate);
    try std.testing.expectEqual(@as(u32, 0x1122_3344), result.register(8).?.value);
    try std.testing.expect(result.register(8).?.sources.memory);
    try std.testing.expect(result.register(8).?.sources.user_data);
}

test "NGG scalar user data starts at s8" {
    var storage = [_]u8{0} ** 0x20;
    var memory = TestMemory{ .base = 0x2000, .bytes = &storage };
    memory.write(0x2000, 0xbf81_0000);
    var bindings = testBindings(0x2000, 0x1234);
    bindings.scalar_user_data_base = 8;
    const result = evaluatePrefix(memory.reader(), &bindings);
    try std.testing.expect(result.register(0) == null);
    try std.testing.expectEqual(@as(u32, 0x1234), result.register(8).?.value);
}

test "bounded scalar prefix does not observe later shader writes" {
    var storage = [_]u8{0} ** 0x40;
    var memory = TestMemory{ .base = 0x3000, .bytes = &storage };
    memory.write(0x3000, 0xbe82_0381); // s_mov_b32 s2, 1
    memory.write(0x3004, 0xbe82_0382); // would overwrite s2 after the boundary
    memory.write(0x3008, 0xbf81_0000);
    const bindings = testBindings(0x3000, 0x1234);
    const result = evaluatePrefixUntil(memory.reader(), &bindings, 4);
    try std.testing.expectEqual(StopReason.prefix_complete, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), result.register(2).?.value);
    try std.testing.expectEqual(@as(u32, 4), result.stop_pc);
}

test "resource evaluation follows the active-lane branch path" {
    var storage = [_]u8{0} ** 0x40;
    var memory = TestMemory{ .base = 0x4000, .bytes = &storage };
    memory.write(0x4000, 0xbf88_0001); // s_cbranch_execz skips the resource setup
    memory.write(0x4004, 0xbe82_0381); // s_mov_b32 s2, 1
    memory.write(0x4008, 0xbf81_0000);
    const bindings = testBindings(0x4000, 0x1234);

    const strict = evaluatePrefix(memory.reader(), &bindings);
    try std.testing.expectEqual(StopReason.branch, strict.stop_reason);
    try std.testing.expect(strict.register(2) == null);

    const resources = evaluateResourceState(memory.reader(), &bindings);
    try std.testing.expectEqual(StopReason.end_program, resources.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), resources.register(2).?.value);
}
