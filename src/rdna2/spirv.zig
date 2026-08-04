// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Deterministic SPIR-V 1.5 writer for executable RDNA2 compute shaders.

const std = @import("std");
const isa = @import("isa.zig");
const operand = @import("operand.zig");
const instruction = @import("instruction.zig");
const control_flow = @import("control_flow.zig");

pub const Stage = enum(u32) {
    vertex = 0,
    fragment = 4,
    compute = 5,
};

/// Static association recovered at a dispatch boundary. GFX10 names a V#
/// descriptor by its first SGPR; Vulkan names the same resource by an element
/// in the storage-buffer descriptor array.
pub const StorageBufferBinding = struct {
    resource_sgpr: u32,
    descriptor_index: u32,
    stride: u32 = 0,
    swizzled: bool = false,
    index_stride: u8 = 0,
    add_thread_id: bool = false,
};

/// Scalar user data is captured by the API-neutral GPU state tracker. Supplying
/// it here lets address operands use the same values that the guest shader saw.
pub const ScalarRegister = struct {
    register: u32,
    value: u32,
};

pub const Options = struct {
    stage: Stage,
    local_size: [3]u32 = .{ 1, 1, 1 },
    storage_buffers: []const StorageBufferBinding = &.{},
    scalar_registers: []const ScalarRegister = &.{},
    descriptor_array_length: u32 = 64,
    /// Exclusive PC ending a straight scalar prolog evaluated against the
    /// captured dispatch state and checked guest memory.
    specialized_scalar_prefix_end: u32 = 0,
};

pub const Error = std.mem.Allocator.Error || control_flow.Error || error{
    UnsupportedOpcode,
    UnsupportedControlFlow,
    UnsupportedDestination,
    UndefinedRegister,
    InvalidStorageBinding,
    UnsupportedBufferAddressing,
};

pub const Module = struct {
    words: []u32,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
        self.* = undefined;
    }
};

const ValueType = enum { bits32, sint32, float32 };
const Value = struct { id: u32 = 0, value_type: ValueType = .bits32 };
const Constant = struct { value_type: ValueType, bits: u32, id: u32 };
const State = struct {
    registers: [384]Value = [_]Value{.{}} ** 384,
    scc: u32 = 0,
    valid: bool = false,
};

const BufferAddress = struct {
    binding: StorageBufferBinding,
    byte_offset: u32,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    annotations: std.ArrayList(u32) = .empty,
    declarations: std.ArrayList(u32) = .empty,
    body: std.ArrayList(u32) = .empty,
    constants: std.ArrayList(Constant) = .empty,
    registers: [384]Value = [_]Value{.{}} ** 384,
    next_id: u32 = 1,
    void_type: u32,
    function_type: u32,
    bits_type: u32,
    signed_type: u32,
    float_type: u32,
    bool_type: u32,
    main_function: u32,
    label: u32,
    storage_bindings: []const StorageBufferBinding,
    storage_array: u32 = 0,
    storage_word_pointer_type: u32 = 0,
    local_invocation_index: u32 = 0,
    specialized_scalar_registers: [128]bool = @splat(false),
    specialized_scalar_prefix_end: u32,
    scc: u32 = 0,

    fn init(allocator: std.mem.Allocator, options: Options) Error!Builder {
        var self = Builder{
            .allocator = allocator,
            .void_type = 0,
            .function_type = 0,
            .bits_type = 0,
            .signed_type = 0,
            .float_type = 0,
            .bool_type = 0,
            .main_function = 0,
            .label = 0,
            .storage_bindings = options.storage_buffers,
            .specialized_scalar_prefix_end = options.specialized_scalar_prefix_end,
        };
        errdefer self.deinit();
        self.void_type = self.id();
        self.function_type = self.id();
        self.bits_type = self.id();
        self.signed_type = self.id();
        self.float_type = self.id();
        self.bool_type = self.id();
        self.main_function = self.id();
        self.label = self.id();
        try self.emit(&self.declarations, 19, &.{self.void_type}); // OpTypeVoid
        try self.emit(&self.declarations, 33, &.{ self.function_type, self.void_type }); // OpTypeFunction
        try self.emit(&self.declarations, 21, &.{ self.bits_type, 32, 0 }); // OpTypeInt
        try self.emit(&self.declarations, 21, &.{ self.signed_type, 32, 1 }); // OpTypeInt
        try self.emit(&self.declarations, 22, &.{ self.float_type, 32 }); // OpTypeFloat
        try self.emit(&self.declarations, 20, &.{self.bool_type}); // OpTypeBool

        for (options.scalar_registers) |scalar| {
            if (scalar.register >= 128) return Error.InvalidStorageBinding;
            self.registers[scalar.register] = .{
                .id = try self.constant(.bits32, scalar.value),
                .value_type = .bits32,
            };
            self.specialized_scalar_registers[scalar.register] = true;
        }

        if (options.storage_buffers.len != 0) {
            if (options.stage != .compute or options.descriptor_array_length == 0) {
                return Error.InvalidStorageBinding;
            }
            for (options.storage_buffers, 0..) |binding, index| {
                if (binding.resource_sgpr >= 128 or
                    binding.descriptor_index >= options.descriptor_array_length or
                    binding.index_stride > 3)
                {
                    return Error.InvalidStorageBinding;
                }
                for (options.storage_buffers[0..index]) |previous| {
                    if (previous.resource_sgpr == binding.resource_sgpr) return Error.InvalidStorageBinding;
                }
            }

            const runtime_words = self.id();
            const storage_block = self.id();
            const descriptor_count = try self.constant(.bits32, options.descriptor_array_length);
            const descriptor_array = self.id();
            const storage_array_pointer = self.id();
            self.storage_word_pointer_type = self.id();
            self.storage_array = self.id();

            try self.emit(&self.annotations, 71, &.{ runtime_words, 6, 4 }); // ArrayStride 4
            try self.emit(&self.annotations, 72, &.{ storage_block, 0, 35, 0 }); // member Offset 0
            try self.emit(&self.annotations, 71, &.{ storage_block, 2 }); // Block
            try self.emit(&self.annotations, 71, &.{ self.storage_array, 34, 0 }); // DescriptorSet 0
            try self.emit(&self.annotations, 71, &.{ self.storage_array, 33, 0 }); // Binding 0
            try self.emit(&self.declarations, 29, &.{ runtime_words, self.bits_type }); // OpTypeRuntimeArray
            try self.emit(&self.declarations, 30, &.{ storage_block, runtime_words }); // OpTypeStruct
            try self.emit(&self.declarations, 28, &.{ descriptor_array, storage_block, descriptor_count }); // OpTypeArray
            try self.emit(&self.declarations, 32, &.{ storage_array_pointer, 12, descriptor_array }); // ptr StorageBuffer
            try self.emit(&self.declarations, 32, &.{ self.storage_word_pointer_type, 12, self.bits_type });
            try self.emit(&self.declarations, 59, &.{ storage_array_pointer, self.storage_array, 12 }); // OpVariable

            var needs_thread_id = false;
            for (options.storage_buffers) |binding| {
                needs_thread_id = needs_thread_id or binding.add_thread_id;
            }
            if (needs_thread_id) {
                const input_uint_pointer = self.id();
                self.local_invocation_index = self.id();
                try self.emit(&self.annotations, 71, &.{ self.local_invocation_index, 11, 29 }); // BuiltIn LocalInvocationIndex
                try self.emit(&self.declarations, 32, &.{ input_uint_pointer, 1, self.bits_type }); // ptr Input
                try self.emit(&self.declarations, 59, &.{ input_uint_pointer, self.local_invocation_index, 1 }); // OpVariable
            }
        }
        return self;
    }

    fn deinit(self: *Builder) void {
        self.annotations.deinit(self.allocator);
        self.declarations.deinit(self.allocator);
        self.body.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }

    fn id(self: *Builder) u32 {
        const result = self.next_id;
        self.next_id += 1;
        return result;
    }

    fn emit(self: *Builder, list: *std.ArrayList(u32), opcode: u16, args: []const u32) Error!void {
        try list.append(self.allocator, (@as(u32, @intCast(args.len + 1)) << 16) | opcode);
        try list.appendSlice(self.allocator, args);
    }

    fn typeId(self: *const Builder, value_type: ValueType) u32 {
        return switch (value_type) {
            .bits32 => self.bits_type,
            .sint32 => self.signed_type,
            .float32 => self.float_type,
        };
    }

    fn constant(self: *Builder, value_type: ValueType, bits: u32) Error!u32 {
        for (self.constants.items) |entry| {
            if (entry.value_type == value_type and entry.bits == bits) return entry.id;
        }
        const result = self.id();
        try self.emit(&self.declarations, 43, &.{ self.typeId(value_type), result, bits }); // OpConstant
        try self.constants.append(self.allocator, .{ .value_type = value_type, .bits = bits, .id = result });
        return result;
    }

    fn registerIndex(op: operand.Operand) ?usize {
        return switch (op.kind) {
            .sgpr => if (op.reg < 128) @intCast(op.reg) else null,
            .vgpr => if (op.reg < 256) @intCast(128 + op.reg) else null,
            else => null,
        };
    }

    fn convert(self: *Builder, value: Value, expected: ValueType) Error!u32 {
        if (value.value_type == expected) return value.id;
        const converted = self.id();
        try self.emit(&self.body, 124, &.{ self.typeId(expected), converted, value.id }); // OpBitcast
        return converted;
    }

    fn rawSource(self: *Builder, op: operand.Operand) Error!u32 {
        return switch (op.kind) {
            .integer_inline_constant, .literal_constant, .float_inline_constant => self.constant(.bits32, op.value),
            .null => self.constant(.bits32, 0),
            .sgpr, .vgpr => blk: {
                const index = registerIndex(op) orelse return Error.UndefinedRegister;
                const current = self.registers[index];
                if (current.id == 0) return Error.UndefinedRegister;
                break :blk try self.convert(current, .bits32);
            },
            else => Error.UndefinedRegister,
        };
    }

    fn source(self: *Builder, op: operand.Operand, expected: ValueType) Error!u32 {
        if (op.dpp) return Error.UnsupportedOpcode;
        var raw = try self.rawSource(op);
        if (op.sdwa_sel != 6) {
            const width: u32 = if (op.sdwa_sel < 4) 8 else if (op.sdwa_sel < 6) 16 else return Error.UnsupportedOpcode;
            const shift: u32 = if (op.sdwa_sel < 4)
                @as(u32, op.sdwa_sel) * 8
            else
                @as(u32, op.sdwa_sel - 4) * 16;
            if (shift != 0) {
                const shifted = self.id();
                try self.emit(&self.body, 194, &.{ self.bits_type, shifted, raw, try self.constant(.bits32, shift) });
                raw = shifted;
            }
            const masked = self.id();
            const mask = if (width == 8) @as(u32, 0xff) else 0xffff;
            try self.emit(&self.body, 199, &.{ self.bits_type, masked, raw, try self.constant(.bits32, mask) });
            raw = masked;
            if (op.sdwa_sext) {
                const left = self.id();
                const amount = 32 - width;
                try self.emit(&self.body, 196, &.{ self.bits_type, left, raw, try self.constant(.bits32, amount) });
                const signed = try self.convert(.{ .id = left, .value_type = .bits32 }, .sint32);
                const extended = self.id();
                try self.emit(&self.body, 195, &.{ self.signed_type, extended, signed, try self.constant(.sint32, amount) });
                raw = try self.convert(.{ .id = extended, .value_type = .sint32 }, .bits32);
            }
        }
        if (op.absolute or op.negate) {
            if (expected != .float32) return Error.UnsupportedOpcode;
            if (op.absolute) {
                const absolute = self.id();
                try self.emit(&self.body, 199, &.{ self.bits_type, absolute, raw, try self.constant(.bits32, 0x7fff_ffff) });
                raw = absolute;
            }
            if (op.negate) {
                const negated = self.id();
                try self.emit(&self.body, 198, &.{ self.bits_type, negated, raw, try self.constant(.bits32, 0x8000_0000) });
                raw = negated;
            }
        }
        return self.convert(.{ .id = raw, .value_type = .bits32 }, expected);
    }

    fn destination(self: *Builder, op: operand.Operand, value: Value) Error!void {
        if (op.sdwa_sel != 6 or op.sdwa_dst_unused != 0) return Error.UnsupportedDestination;
        const index = registerIndex(op) orelse return Error.UnsupportedDestination;
        self.registers[index] = .{
            .id = try self.convert(value, .bits32),
            .value_type = .bits32,
        };
    }

    fn unary(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType) Error!void {
        const source_id = try self.source(inst.src0, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(value_type), result, source_id });
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
    }

    fn binary(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType, reverse: bool) Error!void {
        const a = try self.source(if (reverse) inst.src1 else inst.src0, value_type);
        const b = try self.source(if (reverse) inst.src0 else inst.src1, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.typeId(value_type), result, a, b });
        try self.destination(inst.dst, .{ .id = result, .value_type = value_type });
    }

    fn comparison(self: *Builder, inst: instruction.Instruction, opcode: u16, value_type: ValueType) Error!void {
        const a = try self.source(inst.src0, value_type);
        const b = try self.source(inst.src1, value_type);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{ self.bool_type, result, a, b });
        self.scc = result;
    }

    fn storageBinding(self: *const Builder, resource_sgpr: u32) ?StorageBufferBinding {
        for (self.storage_bindings) |binding| {
            if (binding.resource_sgpr == resource_sgpr) return binding;
        }
        return null;
    }

    fn addBits(self: *Builder, a: u32, b: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 128, &.{ self.bits_type, result, a, b }); // OpIAdd
        return result;
    }

    fn consecutiveRegister(op: operand.Operand, delta: u32) Error!operand.Operand {
        if (op.kind != .vgpr or op.reg + delta >= 256) return Error.UnsupportedBufferAddressing;
        var result = op;
        result.reg += delta;
        return result;
    }

    fn multiplyBits(self: *Builder, a: u32, b: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 132, &.{ self.bits_type, result, a, b }); // OpIMul
        return result;
    }

    fn shiftRightBits(self: *Builder, value: u32, amount: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, result, value, try self.constant(.bits32, amount) });
        return result;
    }

    fn andBits(self: *Builder, value: u32, mask: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, result, value, try self.constant(.bits32, mask) });
        return result;
    }

    fn bufferAddressDelta(self: *Builder, inst: instruction.Instruction, extra_offset: u32) Error!BufferAddress {
        if (self.storage_array == 0 or inst.src1.kind != .sgpr) {
            return Error.UnsupportedBufferAddressing;
        }
        if (inst.memory_offset < 0) return Error.UnsupportedBufferAddressing;
        const binding = self.storageBinding(inst.src1.reg) orelse {
            return Error.InvalidStorageBinding;
        };

        var index = if (inst.index_enable)
            try self.source(inst.src0, .bits32)
        else
            try self.constant(.bits32, 0);
        if (binding.add_thread_id) {
            if (self.local_invocation_index == 0) return Error.UnsupportedBufferAddressing;
            const invocation = self.id();
            try self.emit(&self.body, 61, &.{ self.bits_type, invocation, self.local_invocation_index }); // OpLoad
            index = try self.addBits(index, try self.andBits(invocation, 63));
        }

        var offset = try self.constant(.bits32, @as(u32, @intCast(inst.memory_offset)) + extra_offset);
        if (inst.offset_enable) {
            const offset_operand = if (inst.index_enable) try consecutiveRegister(inst.src0, 1) else inst.src0;
            offset = try self.addBits(offset, try self.source(offset_operand, .bits32));
        }
        const stride = try self.constant(.bits32, binding.stride);
        var byte_offset = if (binding.swizzled and binding.stride != 0) blk: {
            const index_stride: u32 = @as(u32, 8) << @as(u5, @intCast(binding.index_stride));
            const index_msb = try self.shiftRightBits(index, @as(u32, binding.index_stride) + 3);
            const index_lsb = try self.andBits(index, index_stride - 1);
            const offset_msb = try self.andBits(offset, 0xffff_fffc);
            const offset_lsb = try self.andBits(offset, 3);
            const index_part = try self.multiplyBits(index_msb, stride);
            const msb = try self.multiplyBits(
                try self.addBits(index_part, offset_msb),
                try self.constant(.bits32, index_stride),
            );
            const lsb_index = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, lsb_index, index_lsb, try self.constant(.bits32, 2) }); // OpShiftLeftLogical
            break :blk try self.addBits(msb, try self.addBits(lsb_index, offset_lsb));
        } else try self.addBits(try self.multiplyBits(index, stride), offset);
        byte_offset = try self.addBits(byte_offset, try self.source(inst.src2, .bits32));
        return .{ .binding = binding, .byte_offset = byte_offset };
    }

    fn bufferAddress(self: *Builder, inst: instruction.Instruction) Error!BufferAddress {
        return self.bufferAddressDelta(inst, 0);
    }

    fn bufferWordPointer(self: *Builder, address: BufferAddress, delta: u32) Error!u32 {
        const word_index = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, word_index, address.byte_offset, try self.constant(.bits32, 2) }); // OpShiftRightLogical
        const indexed_word = if (delta == 0) word_index else try self.addBits(word_index, try self.constant(.bits32, delta));

        const pointer = self.id();
        try self.emit(&self.body, 65, &.{
            self.storage_word_pointer_type,
            pointer,
            self.storage_array,
            try self.constant(.bits32, address.binding.descriptor_index),
            try self.constant(.bits32, 0),
            indexed_word,
        }); // OpAccessChain descriptor, block member, dword
        return pointer;
    }

    fn loadBufferWord(self: *Builder, address: BufferAddress, delta: u32) Error!u32 {
        const result = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, result, try self.bufferWordPointer(address, delta) }); // OpLoad
        return result;
    }

    fn bufferLoadWords(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        var addresses: [4]BufferAddress = undefined;
        for (0..count) |index| {
            addresses[index] = try self.bufferAddressDelta(inst, @intCast(index * 4));
        }
        for (0..count) |index| {
            const result = try self.loadBufferWord(addresses[index], 0);
            try self.destination(try consecutiveRegister(inst.dst, @intCast(index)), .{ .id = result, .value_type = .bits32 });
        }
    }

    fn bufferStoreWords(self: *Builder, inst: instruction.Instruction, count: u8) Error!void {
        for (0..count) |index| {
            const value = try self.source(try consecutiveRegister(inst.dst, @intCast(index)), .bits32);
            const address = try self.bufferAddressDelta(inst, @intCast(index * 4));
            try self.emit(&self.body, 62, &.{ try self.bufferWordPointer(address, 0), value }); // OpStore
        }
    }

    fn bufferAtomic(self: *Builder, inst: instruction.Instruction, opcode: u16) Error!void {
        const value = try self.source(inst.dst, .bits32);
        const address = try self.bufferAddress(inst);
        const result = self.id();
        try self.emit(&self.body, opcode, &.{
            self.bits_type,
            result,
            try self.bufferWordPointer(address, 0),
            try self.constant(.bits32, 1), // ScopeDevice
            try self.constant(.bits32, 0), // MemorySemanticsNone
            value,
        });
        if (inst.globally_coherent) {
            try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
        }
        try self.emit(&self.body, 225, &.{
            try self.constant(.bits32, 1),
            try self.constant(.bits32, 0x48), // AcquireRelease | UniformMemory
        }); // OpMemoryBarrier
    }

    fn subwordShift(self: *Builder, byte_offset: u32) Error!u32 {
        const byte = try self.andBits(byte_offset, 3);
        const shift = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shift, byte, try self.constant(.bits32, 3) }); // OpShiftLeftLogical
        return shift;
    }

    fn loadBufferByte(self: *Builder, address: BufferAddress) Error!u32 {
        const word = try self.loadBufferWord(address, 0);
        const shifted = self.id();
        try self.emit(&self.body, 194, &.{ self.bits_type, shifted, word, try self.subwordShift(address.byte_offset) });
        return self.andBits(shifted, 0xff);
    }

    fn bufferLoadSubword(self: *Builder, inst: instruction.Instruction, width: u8, signed: bool) Error!void {
        const address = try self.bufferAddress(inst);
        var result = try self.loadBufferByte(address);
        if (width == 16) {
            const high_byte = try self.loadBufferByte(try self.bufferAddressDelta(inst, 1));
            const shifted_high = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, shifted_high, high_byte, try self.constant(.bits32, 8) });
            const combined = self.id();
            try self.emit(&self.body, 197, &.{ self.bits_type, combined, result, shifted_high }); // OpBitwiseOr
            result = combined;
        }
        if (signed) {
            const amount: u32 = 32 - width;
            const left = self.id();
            try self.emit(&self.body, 196, &.{ self.bits_type, left, result, try self.constant(.bits32, amount) });
            const as_signed = try self.convert(.{ .id = left, .value_type = .bits32 }, .sint32);
            const extended = self.id();
            try self.emit(&self.body, 195, &.{ self.signed_type, extended, as_signed, try self.constant(.sint32, amount) });
            result = try self.convert(.{ .id = extended, .value_type = .sint32 }, .bits32);
        }
        try self.destination(inst.dst, .{ .id = result, .value_type = .bits32 });
    }

    fn storeBufferByte(self: *Builder, address: BufferAddress, value: u32) Error!void {
        const pointer = try self.bufferWordPointer(address, 0);
        const current = self.id();
        try self.emit(&self.body, 61, &.{ self.bits_type, current, pointer });
        const shift = try self.subwordShift(address.byte_offset);
        const shifted_mask = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, shifted_mask, try self.constant(.bits32, 0xff), shift });
        const inverse_mask = self.id();
        try self.emit(&self.body, 200, &.{ self.bits_type, inverse_mask, shifted_mask }); // OpNot
        const preserved = self.id();
        try self.emit(&self.body, 199, &.{ self.bits_type, preserved, current, inverse_mask });
        const masked_value = try self.andBits(value, 0xff);
        const inserted = self.id();
        try self.emit(&self.body, 196, &.{ self.bits_type, inserted, masked_value, shift });
        const combined = self.id();
        try self.emit(&self.body, 197, &.{ self.bits_type, combined, preserved, inserted }); // OpBitwiseOr
        try self.emit(&self.body, 62, &.{ pointer, combined });
    }

    fn bufferStoreSubword(self: *Builder, inst: instruction.Instruction, width: u8) Error!void {
        const value = try self.source(inst.dst, .bits32);
        try self.storeBufferByte(try self.bufferAddress(inst), value);
        if (width == 16) {
            try self.storeBufferByte(
                try self.bufferAddressDelta(inst, 1),
                try self.shiftRightBits(value, 8),
            );
        }
    }

    fn specializedScalarDestination(self: *const Builder, inst: instruction.Instruction) bool {
        if (inst.pc >= self.specialized_scalar_prefix_end or inst.dst.kind != .sgpr or inst.dst.reg >= 128) return false;
        if (!self.specialized_scalar_registers[inst.dst.reg]) return false;
        return switch (inst.family) {
            .sop1, .sop2, .sopk, .smem => true,
            else => false,
        };
    }

    fn snapshot(self: *const Builder) State {
        return .{ .registers = self.registers, .scc = self.scc, .valid = true };
    }

    fn restore(self: *Builder, state: State) void {
        self.registers = state.registers;
        self.scc = state.scc;
    }

    fn lower(self: *Builder, inst: instruction.Instruction) Error!void {
        if (inst.dst.clamp or inst.dst.omod != 0) return Error.UnsupportedOpcode;
        if (self.specializedScalarDestination(inst)) return;
        switch (inst.opcode) {
            .s_nop, .s_waitcnt, .s_barrier, .v_nop, .s_endpgm => {},
            .s_branch, .s_cbranch_scc0, .s_cbranch_scc1, .s_cbranch_vccz, .s_cbranch_vccnz, .s_cbranch_execz, .s_cbranch_execnz => return Error.UnsupportedControlFlow,
            .s_mov_b32, .v_mov_b32 => try self.unary(inst, 83, .bits32), // OpCopyObject
            .s_add_u32, .s_add_i32, .v_add_nc_u32 => try self.binary(inst, 128, .bits32, false), // OpIAdd
            .s_sub_u32, .s_sub_i32, .v_sub_nc_u32 => try self.binary(inst, 130, .bits32, false), // OpISub
            .v_subrev_nc_u32 => try self.binary(inst, 130, .bits32, true),
            .v_add_f32 => try self.binary(inst, 129, .float32, false), // OpFAdd
            .v_sub_f32 => try self.binary(inst, 131, .float32, false), // OpFSub
            .v_subrev_f32 => try self.binary(inst, 131, .float32, true),
            .v_mul_f32 => try self.binary(inst, 133, .float32, false), // OpFMul
            .s_and_b32, .v_and_b32 => try self.binary(inst, 199, .bits32, false),
            .s_or_b32, .v_or_b32 => try self.binary(inst, 197, .bits32, false),
            .s_xor_b32, .v_xor_b32 => try self.binary(inst, 198, .bits32, false),
            .s_cmp_eq_i32, .s_cmp_eq_u32 => try self.comparison(inst, 170, .bits32), // OpIEqual
            .s_cmp_lg_i32, .s_cmp_lg_u32 => try self.comparison(inst, 171, .bits32), // OpINotEqual
            .s_cmp_gt_i32 => try self.comparison(inst, 173, .sint32),
            .s_cmp_ge_i32 => try self.comparison(inst, 175, .sint32),
            .s_cmp_lt_i32 => try self.comparison(inst, 177, .sint32),
            .s_cmp_le_i32 => try self.comparison(inst, 179, .sint32),
            .s_cmp_gt_u32 => try self.comparison(inst, 172, .bits32),
            .s_cmp_ge_u32 => try self.comparison(inst, 174, .bits32),
            .s_cmp_lt_u32 => try self.comparison(inst, 176, .bits32),
            .s_cmp_le_u32 => try self.comparison(inst, 178, .bits32),
            .buffer_load_ubyte => try self.bufferLoadSubword(inst, 8, false),
            .buffer_load_sbyte => try self.bufferLoadSubword(inst, 8, true),
            .buffer_load_ushort => try self.bufferLoadSubword(inst, 16, false),
            .buffer_load_sshort => try self.bufferLoadSubword(inst, 16, true),
            .buffer_load_dword => try self.bufferLoadWords(inst, 1),
            .buffer_load_dwordx2 => try self.bufferLoadWords(inst, 2),
            .buffer_load_dwordx3 => try self.bufferLoadWords(inst, 3),
            .buffer_load_dwordx4 => try self.bufferLoadWords(inst, 4),
            .buffer_store_byte => try self.bufferStoreSubword(inst, 8),
            .buffer_store_short => try self.bufferStoreSubword(inst, 16),
            .buffer_store_dword => try self.bufferStoreWords(inst, 1),
            .buffer_store_dwordx2 => try self.bufferStoreWords(inst, 2),
            .buffer_store_dwordx3 => try self.bufferStoreWords(inst, 3),
            .buffer_store_dwordx4 => try self.bufferStoreWords(inst, 4),
            .buffer_atomic_swap => try self.bufferAtomic(inst, 229), // OpAtomicExchange
            .buffer_atomic_add => try self.bufferAtomic(inst, 234), // OpAtomicIAdd
            .buffer_atomic_sub => try self.bufferAtomic(inst, 235), // OpAtomicISub
            .buffer_atomic_smin => try self.bufferAtomic(inst, 236), // OpAtomicSMin
            .buffer_atomic_umin => try self.bufferAtomic(inst, 237), // OpAtomicUMin
            .buffer_atomic_smax => try self.bufferAtomic(inst, 238), // OpAtomicSMax
            .buffer_atomic_umax => try self.bufferAtomic(inst, 239), // OpAtomicUMax
            .buffer_atomic_and => try self.bufferAtomic(inst, 240), // OpAtomicAnd
            .buffer_atomic_or => try self.bufferAtomic(inst, 241), // OpAtomicOr
            .buffer_atomic_xor => try self.bufferAtomic(inst, 242), // OpAtomicXor
            else => return Error.UnsupportedOpcode,
        }
    }
};

fn appendInstruction(allocator: std.mem.Allocator, words: *std.ArrayList(u32), opcode: u16, args: []const u32) Error!void {
    try words.append(allocator, (@as(u32, @intCast(args.len + 1)) << 16) | opcode);
    try words.appendSlice(allocator, args);
}

fn emitPhi(
    builder: *Builder,
    value_type: u32,
    values: []const Value,
    parents: []const u32,
) Error!u32 {
    std.debug.assert(values.len == parents.len and values.len >= 2);
    var args: std.ArrayList(u32) = .empty;
    defer args.deinit(builder.allocator);
    const result = builder.id();
    try args.append(builder.allocator, value_type);
    try args.append(builder.allocator, result);
    for (values, parents) |value, parent| {
        try args.append(builder.allocator, value.id);
        try args.append(builder.allocator, parent);
    }
    try builder.emit(&builder.body, 245, args.items); // OpPhi
    return result;
}

fn mergeState(
    builder: *Builder,
    graph: *const control_flow.Graph,
    states: []const State,
    labels: []const u32,
    block: u32,
) Error!State {
    if (block == 0) return .{ .valid = true };
    var predecessors: std.ArrayList(u32) = .empty;
    defer predecessors.deinit(builder.allocator);
    for (graph.edges.items) |edge| {
        if (edge.to != block) continue;
        if (edge.from >= block or !states[edge.from].valid) return Error.UnsupportedControlFlow;
        try predecessors.append(builder.allocator, edge.from);
    }
    if (predecessors.items.len == 0) return Error.UnsupportedControlFlow;
    if (predecessors.items.len == 1) return states[predecessors.items[0]];

    var merged = State{ .valid = true };
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(builder.allocator);
    var parents: std.ArrayList(u32) = .empty;
    defer parents.deinit(builder.allocator);

    for (0..merged.registers.len) |reg| {
        values.clearRetainingCapacity();
        parents.clearRetainingCapacity();
        var missing = false;
        var differs = false;
        var first = Value{};
        for (predecessors.items, 0..) |pred, index| {
            const value = states[pred].registers[reg];
            if (value.id == 0) missing = true;
            if (index == 0) first = value else if (value.id != first.id) differs = true;
            try values.append(builder.allocator, value);
            try parents.append(builder.allocator, labels[pred]);
        }
        if (missing) continue;
        merged.registers[reg] = if (!differs)
            first
        else
            .{ .id = try emitPhi(builder, builder.bits_type, values.items, parents.items), .value_type = .bits32 };
    }

    values.clearRetainingCapacity();
    parents.clearRetainingCapacity();
    var missing_scc = false;
    var different_scc = false;
    var first_scc: u32 = 0;
    for (predecessors.items, 0..) |pred, index| {
        const id = states[pred].scc;
        if (id == 0) missing_scc = true;
        if (index == 0) first_scc = id else if (id != first_scc) different_scc = true;
        try values.append(builder.allocator, .{ .id = id, .value_type = .bits32 });
        try parents.append(builder.allocator, labels[pred]);
    }
    if (!missing_scc) {
        merged.scc = if (!different_scc)
            first_scc
        else
            try emitPhi(builder, builder.bool_type, values.items, parents.items);
    }
    return merged;
}

fn translateStructured(builder: *Builder, program: *const instruction.Program, graph: *const control_flow.Graph) Error!void {
    if (graph.back_edge_count != 0) return Error.UnsupportedControlFlow;
    const labels = try builder.allocator.alloc(u32, graph.blocks.items.len);
    defer builder.allocator.free(labels);
    labels[0] = builder.label;
    for (labels[1..]) |*label| label.* = builder.id();
    const states = try builder.allocator.alloc(State, graph.blocks.items.len);
    defer builder.allocator.free(states);
    @memset(states, State{});

    for (graph.blocks.items) |block| {
        try builder.emit(&builder.body, 248, &.{labels[block.index]}); // OpLabel
        const incoming = try mergeState(builder, graph, states, labels, block.index);
        builder.restore(incoming);

        const first: usize = block.first_instruction;
        const end: usize = first + block.instruction_count;
        const last = program.instructions.items[end - 1];
        for (program.instructions.items[first..end]) |inst| {
            if (inst.opcode.isBranch() or inst.opcode == .s_endpgm or inst.opcode == .s_setpc_b64) continue;
            try builder.lower(inst);
        }
        states[block.index] = builder.snapshot();

        if (last.opcode == .s_endpgm) {
            try builder.emit(&builder.body, 253, &.{}); // OpReturn
        } else if (last.opcode == .s_branch) {
            const target = graph.blockForPc(last.branch_target) orelse return Error.UnsupportedControlFlow;
            try builder.emit(&builder.body, 249, &.{labels[target]}); // OpBranch
        } else if (last.opcode.isBranch()) {
            const selection = graph.selectionForHeader(block.index) orelse return Error.UnsupportedControlFlow;
            if (selection.condition != .scc or builder.scc == 0) return Error.UnsupportedControlFlow;
            var condition = builder.scc;
            if (!selection.branch_when) {
                const inverted = builder.id();
                try builder.emit(&builder.body, 168, &.{ builder.bool_type, inverted, condition }); // OpLogicalNot
                condition = inverted;
            }
            try builder.emit(&builder.body, 247, &.{ labels[selection.merge], 0 }); // OpSelectionMerge
            try builder.emit(&builder.body, 250, &.{
                condition,
                labels[selection.branch_successor],
                labels[selection.fallthrough_successor],
            });
        } else if (block.index + 1 < graph.blocks.items.len) {
            try builder.emit(&builder.body, 249, &.{labels[block.index + 1]});
        } else {
            return Error.UnsupportedControlFlow;
        }
    }
}

fn assemble(allocator: std.mem.Allocator, builder: *Builder, options: Options) Error!Module {
    var words: std.ArrayList(u32) = .empty;
    errdefer words.deinit(allocator);
    try words.appendSlice(allocator, &.{
        0x0723_0203,
        0x0001_0500,
        0x0050_4300,
        builder.next_id,
        0,
    });
    try appendInstruction(allocator, &words, 17, &.{1});
    try appendInstruction(allocator, &words, 14, &.{ 0, 1 });
    var entry_point: std.ArrayList(u32) = .empty;
    defer entry_point.deinit(allocator);
    try entry_point.appendSlice(allocator, &.{ @intFromEnum(options.stage), builder.main_function, 0x6e69_616d, 0 });
    if (builder.storage_array != 0) try entry_point.append(allocator, builder.storage_array);
    if (builder.local_invocation_index != 0) try entry_point.append(allocator, builder.local_invocation_index);
    try appendInstruction(allocator, &words, 15, entry_point.items);
    switch (options.stage) {
        .fragment => try appendInstruction(allocator, &words, 16, &.{ builder.main_function, 7 }),
        .compute => try appendInstruction(allocator, &words, 16, &.{ builder.main_function, 17, options.local_size[0], options.local_size[1], options.local_size[2] }),
        .vertex => {},
    }
    try words.appendSlice(allocator, builder.annotations.items);
    try words.appendSlice(allocator, builder.declarations.items);
    try appendInstruction(allocator, &words, 54, &.{ builder.void_type, builder.main_function, 0, builder.function_type });
    try words.appendSlice(allocator, builder.body.items);
    try appendInstruction(allocator, &words, 56, &.{});
    return .{ .words = try words.toOwnedSlice(allocator) };
}

/// Translates the executable ALU/SDWA subset and forward scalar selections.
/// The writer fails explicitly for operations or control-flow shapes whose
/// semantics are not implemented; it never emits a placeholder guest shader.
pub fn translate(allocator: std.mem.Allocator, program: *const instruction.Program, options: Options) Error!Module {
    var builder = try Builder.init(allocator, options);
    defer builder.deinit();
    var graph = try control_flow.build(allocator, program);
    defer graph.deinit(allocator);
    if (graph.blocks.items.len == 1) {
        try builder.emit(&builder.body, 248, &.{builder.label});
        for (program.instructions.items) |inst| try builder.lower(inst);
        try builder.emit(&builder.body, 253, &.{});
    } else {
        try translateStructured(&builder, program, &graph);
    }
    return assemble(allocator, &builder, options);
}

fn containsOpcode(words: []const u32, wanted: u16) bool {
    var index: usize = 5;
    while (index < words.len) {
        const first = words[index];
        if (@as(u16, @truncate(first)) == wanted) return true;
        const count = first >> 16;
        if (count == 0) return false;
        index += count;
    }
    return false;
}

fn countOpcode(words: []const u32, wanted: u16) usize {
    var count: usize = 0;
    var index: usize = 5;
    while (index < words.len) {
        const first = words[index];
        if (@as(u16, @truncate(first)) == wanted) count += 1;
        const word_count = first >> 16;
        if (word_count == 0) break;
        index += word_count;
    }
    return count;
}

fn firstInstructionOperand(words: []const u32, wanted: u16, operand_index: usize) ?u32 {
    var index: usize = 5;
    while (index < words.len) {
        const first = words[index];
        const count: usize = @intCast(first >> 16);
        if (@as(u16, @truncate(first)) == wanted and operand_index + 1 < count) {
            return words[index + operand_index + 1];
        }
        if (count == 0) return null;
        index += count;
    }
    return null;
}

test "straight-line vector ALU translates to a SPIR-V function" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255, // v_mov_b32 v0, literal
        0x3f80_0000,
        (@as(u32, 3) << 25) | (@as(u32, 1) << 17) | 256, // v_add_f32 v1, v0, v0
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute, .local_size = .{ 8, 1, 1 } });
    defer module.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0x0723_0203), module.words[0]);
    try std.testing.expectEqual(@as(u32, 0x0001_0500), module.words[1]);
    try std.testing.expect(containsOpcode(module.words, 129)); // OpFAdd
    try std.testing.expect(containsOpcode(module.words, 253)); // OpReturn
}

test "MUBUF dword load and store lower through a descriptor array" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe030_0000, // buffer_load_dword v0, v0, s4:s7, 0
        0x8001_0000,
        0xe070_0004, // buffer_store_dword v0, v0, s4:s7, 0 offset:4
        0x8001_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 4, .descriptor_index = 7 }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
        .descriptor_array_length = 8,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 29)); // OpTypeRuntimeArray
    try std.testing.expect(containsOpcode(module.words, 65)); // OpAccessChain
    try std.testing.expect(containsOpcode(module.words, 61)); // OpLoad
    try std.testing.expect(containsOpcode(module.words, 62)); // OpStore
}

test "resolved SMEM descriptor prolog specializes before MUBUF" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xf408_0200, // s_load_dwordx4 s8:s11, s0:s1, 0
        125 << 25,
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
        0x1122_3344,
        0xe070_0000, // buffer_store_dword v0, v0, s8:s11, 0
        0x8002_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 8, .descriptor_index = 0 }};
    const scalars = [_]ScalarRegister{
        .{ .register = 8, .value = 0x1000 },
        .{ .register = 9, .value = 0 },
        .{ .register = 10, .value = 64 },
        .{ .register = 11, .value = 0 },
    };
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
        .scalar_registers = &scalars,
        .specialized_scalar_prefix_end = 8,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 62)); // OpStore
}

test "vector and subword MUBUF operations lower explicitly" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe038_0000, // buffer_load_dwordx4 v0:v3, v0, s4:s7, 0
        0x8001_0000,
        0xe078_0010, // buffer_store_dwordx4 v0:v3, v0, s4:s7, offset:16
        0x8001_0000,
        0xe024_0001, // buffer_load_sbyte v4, v0, s4:s7, offset:1
        0x8001_0400,
        0xe068_0002, // buffer_store_short v4, v0, s4:s7, offset:2
        0x8001_0400,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 4, .descriptor_index = 2 }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 200)); // OpNot for subword RMW
    try std.testing.expect(containsOpcode(module.words, 195)); // signed extraction
}

test "MUBUF atomics and add_tid lower to explicit SPIR-V operations" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255, // v_mov_b32 v0, literal
        5,
        0xe0c0_0000, 0x8001_0000, // buffer_atomic_swap
        0xe0c8_0000, 0x8001_0000, // buffer_atomic_add
        0xe0cc_0000, 0x8001_0000, // buffer_atomic_sub
        0xe0d4_0000, 0x8001_0000, // buffer_atomic_smin
        0xe0d8_0000, 0x8001_0000, // buffer_atomic_umin
        0xe0dc_0000, 0x8001_0000, // buffer_atomic_smax
        0xe0e0_0000, 0x8001_0000, // buffer_atomic_umax
        0xe0e4_0000, 0x8001_0000, // buffer_atomic_and
        0xe0e8_0000, 0x8001_0000, // buffer_atomic_or
        0xe0ec_0000, 0x8001_0000, // buffer_atomic_xor
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{
        .resource_sgpr = 4,
        .descriptor_index = 0,
        .stride = 4,
        .add_thread_id = true,
    }};
    var module = try translate(std.testing.allocator, &program, .{
        .stage = .compute,
        .local_size = .{ 4, 1, 1 },
        .storage_buffers = &storage,
    });
    defer module.deinit(std.testing.allocator);

    try std.testing.expect(containsOpcode(module.words, 229)); // OpAtomicExchange
    inline for (234..243) |opcode| {
        try std.testing.expect(containsOpcode(module.words, opcode));
    }
    try std.testing.expect(containsOpcode(module.words, 225)); // OpMemoryBarrier
    try std.testing.expect(containsOpcode(module.words, 132)); // lane * descriptor stride
}

test "MUBUF glc controls atomic return-value writeback" {
    const decoder = @import("decoder.zig");
    const common_tail = [_]u32{
        0x8001_0000,
        0xe070_0000, // buffer_store_dword v0, v0, s8:s11, 0
        0x8002_0000,
        0xbf81_0000,
    };
    const storage = [_]StorageBufferBinding{
        .{ .resource_sgpr = 4, .descriptor_index = 0 },
        .{ .resource_sgpr = 8, .descriptor_index = 1 },
    };

    for ([_]bool{ false, true }) |glc| {
        const code = [_]u32{
            (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
            5,
            0xe0c8_0000 | if (glc) @as(u32, 1 << 14) else 0,
            common_tail[0],
            common_tail[1],
            common_tail[2],
            common_tail[3],
        };
        var program = try decoder.decodeProgram(std.testing.allocator, &code);
        defer program.deinit(std.testing.allocator);
        var module = try translate(std.testing.allocator, &program, .{
            .stage = .compute,
            .storage_buffers = &storage,
        });
        defer module.deinit(std.testing.allocator);

        const atomic_result = firstInstructionOperand(module.words, 234, 1).?;
        const stored_value = firstInstructionOperand(module.words, 62, 1).?;
        if (glc) {
            try std.testing.expectEqual(atomic_result, stored_value);
        } else {
            try std.testing.expect(atomic_result != stored_value);
        }
    }
}

test "cross-dword short load and store lower as two byte accesses" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xe02c_0003, // buffer_load_sshort at byte 3 crosses a dword
        0x8001_0000,
        0xe068_0007, // buffer_store_short at byte 7 crosses a dword
        0x8001_0000,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{ .resource_sgpr = 4, .descriptor_index = 0 }};
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute, .storage_buffers = &storage });
    defer module.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), countOpcode(module.words, 62)); // two byte stores
    try std.testing.expect(containsOpcode(module.words, 195)); // signed extension
}

test "swizzled V# addressing lowers index_stride permutation" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
        1, // v_mov_b32 v0, index 1
        0xe034_2004, // buffer_load_dwordx2 idxen offset:4
        0x8001_0100,
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    const storage = [_]StorageBufferBinding{.{
        .resource_sgpr = 4,
        .descriptor_index = 0,
        .stride = 16,
        .swizzled = true,
        .index_stride = 2,
    }};
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute, .storage_buffers = &storage });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(countOpcode(module.words, 132) >= 4); // index and swizzle products for both dwords
    try std.testing.expect(containsOpcode(module.words, 196)); // index_lsb << 2
}

test "unsupported shader semantics never produce placeholder SPIR-V" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{ 0xf404_0201, 0, 0xbf81_0000 };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectError(Error.UnsupportedOpcode, translate(std.testing.allocator, &program, .{ .stage = .compute }));
}

test "forward scalar selection lowers with a structured merge and register phi" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        0xbe80_0381, // s_mov_b32 s0, 1
        0xbe81_0381, // s_mov_b32 s1, 1
        0xbf06_0100, // s_cmp_eq_u32 s0, s1
        0xbf84_0002, // s_cbranch_scc0 -> pc 24
        0xbe82_0382, // s_mov_b32 s2, 2
        0xbf82_0001, // s_branch -> pc 28
        0xbe82_0383, // s_mov_b32 s2, 3
        0x8003_8102, // s_add_u32 s3, s2, 1
        0xbf81_0000, // s_endpgm
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 247)); // OpSelectionMerge
    try std.testing.expect(containsOpcode(module.words, 250)); // OpBranchConditional
    try std.testing.expect(containsOpcode(module.words, 245)); // OpPhi
}

test "back edges remain explicit until loop structuring is implemented" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{ 0xbf80_0000, 0xbf82_fffe, 0xbf81_0000 };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    try std.testing.expectError(
        Error.UnsupportedControlFlow,
        translate(std.testing.allocator, &program, .{ .stage = .compute }),
    );
}

test "full destination SDWA lowers source extraction before vector ALU" {
    const decoder = @import("decoder.zig");
    const code = [_]u32{
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255,
        0x3f80_0000,
        (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 17) | (@as(u32, 1) << 9) | 255,
        0x4000_0000,
        (@as(u32, 3) << 25) | (@as(u32, 2) << 17) | (@as(u32, 1) << 9) | 249,
        (@as(u32, 6) << 8) | (@as(u32, 4) << 16) | (@as(u32, 6) << 24),
        0xbf81_0000,
    };
    var program = try decoder.decodeProgram(std.testing.allocator, &code);
    defer program.deinit(std.testing.allocator);
    var module = try translate(std.testing.allocator, &program, .{ .stage = .compute });
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(containsOpcode(module.words, 199)); // OpBitwiseAnd
    try std.testing.expect(containsOpcode(module.words, 129)); // OpFAdd
}
