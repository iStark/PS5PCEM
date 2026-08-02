// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! rdna2 — a disassembler for RDNA2 scalar instructions.
//!
//! Implements the SOP1/SOP2/SOPK/SOPC/SOPP families; the vector and memory
//! families are rejected with an explicit error for now.

pub const isa = @import("isa.zig");
pub const operand = @import("operand.zig");
pub const instruction = @import("instruction.zig");
pub const scalar_alu = @import("scalar_alu.zig");
pub const decoder = @import("decoder.zig");
pub const disasm = @import("disasm.zig");

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

test {
    // Pulls in the tests of every module in the package: `zig build test` only
    // walks files reachable from the root.
    _ = isa;
    _ = operand;
    _ = instruction;
    _ = scalar_alu;
    _ = decoder;
    _ = disasm;
}
