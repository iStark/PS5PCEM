// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! rdna2 — GFX10/RDNA2 shader decode, control flow and SPIR-V translation.

const std = @import("std");

pub const isa = @import("isa.zig");
pub const operand = @import("operand.zig");
pub const instruction = @import("instruction.zig");
pub const scalar_alu = @import("scalar_alu.zig");
pub const scalar_memory = @import("scalar_memory.zig");
pub const vector_alu = @import("vector_alu.zig");
pub const vector_memory = @import("vector_memory.zig");
pub const decoder = @import("decoder.zig");
pub const disasm = @import("disasm.zig");
pub const control_flow = @import("control_flow.zig");
pub const ir = @import("ir.zig");
pub const spirv = @import("spirv.zig");

pub const Family = isa.Family;
pub const Opcode = isa.Opcode;
pub const OperandKind = isa.OperandKind;
pub const Operand = operand.Operand;
pub const Instruction = instruction.Instruction;
pub const Program = instruction.Program;
pub const Error = instruction.Error;

pub const decodeProgram = decoder.decodeProgram;
pub const decodeInstruction = decoder.decodeInstruction;
pub const formatProgram = disasm.formatProgram;
pub const formatInstruction = disasm.formatInstruction;
pub const buildControlFlow = control_flow.build;
pub const lowerIr = ir.lower;
pub const translateIrSpirv = spirv.translateIr;
pub const translateIrBackendSpirv = spirv.translateBackend;
/// Compatibility name for the low-level decoded-instruction backend.
pub const translateSpirv = spirv.translate;

/// Complete runtime path for a transient decoded program: typed lowering,
/// validation, SSA optimization, legalization and SPIR-V emission.
pub fn translateProgramSpirv(
    allocator: std.mem.Allocator,
    program: *const Program,
    options: spirv.Options,
) spirv.Error!spirv.Module {
    var module = try ir.lower(allocator, program);
    defer module.deinit(allocator);
    return spirv.translateIr(allocator, &module, options);
}

test {
    // Pulls in the tests of every module in the package: `zig build test` only
    // walks files reachable from the root.
    _ = isa;
    _ = operand;
    _ = instruction;
    _ = scalar_alu;
    _ = scalar_memory;
    _ = vector_alu;
    _ = vector_memory;
    _ = decoder;
    _ = disasm;
    _ = control_flow;
    _ = ir;
    _ = spirv;
}
