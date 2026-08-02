//! RDNA2 instruction set, limited to what the scalar (SOP*) families need.
//!
//! `Opcode` variant names match assembler mnemonics, so `@tagName` replaces the
//! opcode-to-string lookup table that a hand-written decoder normally carries as
//! a several-hundred-line switch.

/// Instruction encoding format.
pub const Family = enum {
    unknown,
    sop1,
    sop2,
    sopk,
    sopc,
    sopp,

    pub fn name(self: Family) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            inline else => |f| comptime up(@tagName(f)),
        };
    }

    /// sop1 -> "SOP1": family names are conventionally printed upper case.
    fn up(comptime s: []const u8) []const u8 {
        comptime var buf: [s.len]u8 = undefined;
        inline for (s, 0..) |c, i| {
            buf[i] = if (c >= 'a' and c <= 'z') c - ('a' - 'A') else c;
        }
        const frozen = buf;
        return &frozen;
    }
};

/// What an operand field actually encodes.
pub const OperandKind = enum {
    unknown,
    sgpr,
    vgpr,
    integer_inline_constant,
    float_inline_constant,
    literal_constant,
    vcc_lo,
    vcc_hi,
    vcc_z,
    exec_lo,
    exec_hi,
    exec_z,
    scc,
    m0,
    /// `null` is a Zig keyword, so the variant name is escaped.
    /// `@tagName` still yields "null".
    @"null",
    pops_exiting_wave_id,
};

/// Opcodes of the RDNA2 scalar families.
pub const Opcode = enum {
    unknown,
    /// Recognized as belonging to a family, but not implemented.
    unsupported,

    // SOP1
    s_mov_b32,
    s_mov_b64,
    s_not_b32,
    s_not_b64,
    s_wqm_b64,
    s_brev_b32,
    s_bcnt1_i32_b32,
    s_bcnt1_i32_b64,
    s_ff1_i32_b32,
    s_flbit_i32_b64,
    s_bitset0_b32,
    s_bitset1_b32,
    s_getpc_b64,
    s_setpc_b64,
    s_and_saveexec_b32,
    s_and_saveexec_b64,
    s_orn2_saveexec_b64,
    s_andn1_saveexec_b32,
    s_andn1_saveexec_b64,
    s_abs_i32,
    s_bitreplicate_b64_b32,

    // SOP2
    s_add_u32,
    s_sub_u32,
    s_add_i32,
    s_sub_i32,
    s_addc_u32,
    s_subb_u32,
    s_min_i32,
    s_min_u32,
    s_max_i32,
    s_max_u32,
    s_cselect_b32,
    s_cselect_b64,
    s_and_b32,
    s_and_b64,
    s_or_b32,
    s_or_b64,
    s_xor_b32,
    s_xor_b64,
    s_andn2_b32,
    s_andn2_b64,
    s_orn2_b32,
    s_orn2_b64,
    s_nand_b32,
    s_nand_b64,
    s_nor_b32,
    s_nor_b64,
    s_xnor_b32,
    s_xnor_b64,
    s_lshl_b32,
    s_lshl_b64,
    s_lshr_b32,
    s_lshr_b64,
    s_ashr_i32,
    s_bfm_b32,
    s_bfm_b64,
    s_mul_i32,
    s_bfe_u32,
    s_bfe_u64,
    s_lshl1_add_u32,
    s_lshl2_add_u32,
    s_lshl3_add_u32,
    s_lshl4_add_u32,
    s_pack_ll_b32_b16,
    s_pack_lh_b32_b16,
    s_pack_hh_b32_b16,
    s_mul_hi_u32,

    // SOPC / SOPK
    s_cmp_eq_i32,
    s_cmp_lg_i32,
    s_cmp_gt_i32,
    s_cmp_ge_i32,
    s_cmp_lt_i32,
    s_cmp_le_i32,
    s_cmp_eq_u32,
    s_cmp_lg_u32,
    s_cmp_gt_u32,
    s_cmp_ge_u32,
    s_cmp_lt_u32,
    s_cmp_le_u32,
    s_cmp_lg_u64,
    s_bitcmp0_b32,
    s_bitcmp1_b32,
    s_movk_i32,
    s_mulk_i32,
    s_setreg_b32,
    s_waitcnt,

    // SOPP
    s_nop,
    s_endpgm,
    s_branch,
    s_cbranch_scc0,
    s_cbranch_scc1,
    s_cbranch_vccz,
    s_cbranch_vccnz,
    s_cbranch_execz,
    s_cbranch_execnz,
    s_barrier,
    s_sleep,
    s_sendmsg,
    s_ttrace_data,
    s_inst_prefetch,

    /// Assembler mnemonic. Identical to the variant name, so no table is needed.
    pub fn mnemonic(self: Opcode) []const u8 {
        return @tagName(self);
    }

    /// Control-transfer instructions, used to collect branch targets.
    pub fn isBranch(self: Opcode) bool {
        return switch (self) {
            .s_branch,
            .s_cbranch_scc0,
            .s_cbranch_scc1,
            .s_cbranch_vccz,
            .s_cbranch_vccnz,
            .s_cbranch_execz,
            .s_cbranch_execnz,
            => true,
            else => false,
        };
    }
};

test "mnemonic is derived from the variant name" {
    const std = @import("std");
    try std.testing.expectEqualStrings("s_mov_b32", Opcode.s_mov_b32.mnemonic());
    try std.testing.expectEqualStrings("s_bitreplicate_b64_b32", Opcode.s_bitreplicate_b64_b32.mnemonic());
    try std.testing.expectEqualStrings("s_cbranch_execnz", Opcode.s_cbranch_execnz.mnemonic());
}

test "family names print upper case" {
    const std = @import("std");
    try std.testing.expectEqualStrings("SOP1", Family.sop1.name());
    try std.testing.expectEqualStrings("SOPP", Family.sopp.name());
    try std.testing.expectEqualStrings("unknown", Family.unknown.name());
}

test "branches are recognized" {
    const std = @import("std");
    try std.testing.expect(Opcode.s_branch.isBranch());
    try std.testing.expect(Opcode.s_cbranch_vccz.isBranch());
    try std.testing.expect(!Opcode.s_endpgm.isBranch());
    try std.testing.expect(!Opcode.s_mov_b32.isBranch());
}
