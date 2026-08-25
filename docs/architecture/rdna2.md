# `rdna2` — shader decoder

[← Documentation index](../README.md) · [Project status](../project-status.md)

RDNA2 is the GPU architecture behind the PlayStation 5. Its shaders ship as raw
GPU machine code rather than as a portable intermediate representation, so any
tool that inspects, recompiles, or validates them has to start by decoding that
machine code.

## Status

The frontend now recognizes every major GFX10 shader family used by the PS5:
the scalar `SOP1`, `SOP2`, `SOPK`, `SOPC`, `SOPP` and `SMEM` encodings, vector
`VOP1`, `VOP2`, `VOP3`, `VOP3P`, `VOPC` and `VINTRP`, buffer/typed-buffer
`MUBUF` and `MTBUF`, `FLAT`, `DS`, image `MIMG`, and `EXP`. Their architectural
one/two-word bodies, optional literals and MIMG NSA address words are retained,
so a real shader stream stays synchronized even when an individual opcode has
not been lowered yet.

Known scalar ALU/load operations and the common vector ALU, compare, buffer,
flat, LDS, image/sample and export opcodes have named operands and transfer
metadata. An unrecognized opcode inside a known family yields an `unsupported`
instruction with its family, numeric opcode, exact raw words and reason. SDWA
and DPP extension words now retain scalar-bank selection, byte/word selectors,
sign extension, source/output modifiers, DPP lane control and row/bank masks.

`control_flow.zig` splits decoded programs at direct branch targets and
terminators, validates that every direct target begins an instruction and emits
typed branch/fallthrough edges with SCC/VCC/EXEC predicate domains. It discovers
forward selection merges, derives a dominator hierarchy for nested and shared
merge regions, and records backward edges separately. `ir.zig` now owns the
runtime program passed to a backend instead of serving only as a side analysis.
Its explicit typed, validated, optimized, and legalized stages retain ALU,
memory, image, interpolation, export, synchronization, source operands, branch
targets, side effects, and memory-access metadata. IR validation builds its own
basic-block successor graph and reachability report; the current conservative
optimizer removes only non-leader scalar/vector NOPs, preserving every PC and
branch destination needed by control-flow emission. Compute, fragment, and
ordinary or fetch-inlined vertex programs all reach the SPIR-V backend through
this IR boundary. The SPIR-V 1.5 writer translates 32-bit move,
integer/bitwise/floating-point ALU, SDWA extraction, and the supported DPP/VOP3
modifiers. The native VOP3 table includes unsigned sum-of-absolute-differences
(`V_SAD_U32`), lowered exactly as `abs(src0 - src1) + src2`; Rita's Rewind uses
it in the address/index arithmetic of its vertex shaders. Signed high-word
multiplication (`V_MUL_HI_I32`) uses the exact two's-complement correction over
the unsigned 64-bit product, and `V_CVT_FLR_I32_F32` applies GLSL `Floor` before
the signed conversion. `V_LDEXP_F32` maps to GLSL `Ldexp`, while `S_BFM_B32`,
`S_BFE_U32`, and paired `S_BFE_U64` preserve the scalar field widths and packed
offsets used by Tetris Effect. Rita's Rewind exercises the former operations in
its CRT fragment shader. Acyclic scalar
selections become structured
`OpSelectionMerge`/`OpBranchConditional` regions and register values crossing
their joins use hierarchical `OpPhi` state merging. The Tetris Effect
compositor exercises this path with 2,401 instructions, 131 basic blocks, and
76 selections. Natural loops lower with `OpLoopMerge`. Irreducible cycles and
other unstructured graphs become a block-index dispatcher (`OpLoopMerge` plus
`OpSwitch`) that preserves VCC/EXEC per-lane predicates instead of skipping
branches. The linear diagnostic pass remains only when even that shape cannot
be represented.

Executable MUBUF lowering covers byte/short/dword scalar and vector transfers
plus the ten common 32-bit buffer atomics; `glc` atomics preserve their returned
old value in the guest VGPR. A binding may select a different staged V# at each
instruction PC, retain the resolved SOFFSET, and use Vulkan `VertexIndex` for
per-vertex fetches even when one guest SGPR is reused by several attributes.
Compute V# recovery follows late `s_load_dwordxN` and nested
`s_buffer_load_dwordxN` producers across EXEC/VCC bounds branches. The producer
immediately preceding a memory instruction takes priority over the dispatch
snapshot, because guest shaders routinely reuse dimension SGPRs before loading
the real descriptor into them.

Compute LDS is declared as bounded SPIR-V Workgroup memory using the size encoded
by `COMPUTE_PGM_RSRC2`. Lowering covers 32/64/96/128-bit DS reads and writes,
paired `read2`/`write2` byte addressing (including `st64` scaling), signed and
unsigned byte/short reads, the common 32-bit integer/bitwise atomics,
`s_barrier`, and `v_readfirstlane_b32`. General 2D `image_load` and full-mask
`image_store` use independent typed storage-image bindings, so one shader can
mix `R8_UINT`, `R16_UINT`, `R32_UINT`, `R11G11B10_FLOAT`, `RGBA8_UNORM`,
`RGBA8_UINT`, `RGBA16_FLOAT`, and `RGBA32_FLOAT` without optional
read/write-without-format device features. Both consecutive and NSA coordinate
VGPR encodings are accepted for 2D and 3D loads/stores, and the observed
single-slice 2D-array store uses the same typed path. A read-only BC image load
is fetched through a sampled descriptor because Vulkan does not permit block-
compressed storage images. General multi-layer arrays, mip, MSAA, partial-mask
store, and image-atomic forms remain explicit future work.

Graphics modules connect vertex `EXP POS0` to `BuiltIn Position`, vertex
`PARAM0..31` exports to Vulkan locations, fragment VINTRP instructions to the
matching inputs, and fragment `EXP MRT0..7` to colour locations 0..7. Hardware
CB slot *n* is Vulkan colour attachment *n*; unused slots stay unused rather
than compacting the locations. Hardware-only
M0 setup and EXEC restoration from unavailable pixel-prolog SGPRs are tolerated
without inventing guest data. Fragment EXEC/VCC predicates use the subgroup
local invocation index rather than a compute-only builtin. The current MIMG
path lowers normalized 2D/3D/cube `image_sample`, explicit LOD and bias,
level-zero samples with packed offsets, and the observed four-result
`image_gather4` form through dimension-specific combined sampled-image
descriptor arrays. The alternate opcodes 0x80 above the gradient forms retain
the same operand layout; in particular `IMAGE_SAMPLE_A` is accepted as the
gradient-free `IMAGE_SAMPLE` alias used by Jurassic Park. Vertex and fragment
`image_load` use an explicit-LOD texel
fetch when the guest supplies integer 2D coordinates. Compute programs
additionally support the observed `image_sample_lz` forms with explicit LOD 0,
including NSA coordinates and per-instruction recovery of reused T#/S# SGPRs.
Sampled-image staging detiles 2D surfaces and thick 3D volumes, including
`R32_FLOAT`, `RGBA16_UNORM`, `RGBA8_UNORM`, `RGBA8_UINT`, `R16_UNORM`,
`R16_UINT`, `R11G11B10_FLOAT`, `RGBA16_FLOAT`, `RGBA32_FLOAT`, and
`10_10_10_2_UNORM`, into matching Vulkan formats. Resource dimension and depth
are part of the cache key so 2D/3D aliases cannot reuse an incompatible image
view.
Compressed/masked exports, non-trivial image operands,
and the remaining graphics system VGPRs are still incomplete.

## Design notes

**Opcode tables are expanded at compile time.** `buildTable` in
[src/rdna2/scalar_alu.zig](../../src/rdna2/scalar_alu.zig) turns a declarative list of
`{encoding, opcode}` pairs into a direct-index array, so a lookup is one indexed
load. The same pass rejects duplicate encodings and out-of-range entries as
compile errors, which means a mistake in a table cannot reach a test — it stops
the build. The conventional alternative, scanning a list of pairs at runtime,
costs up to 46 comparisons per instruction for `SOP2` alone.

**Mnemonics are not stored twice.** `Opcode` variant names are the assembler
mnemonics, so `mnemonic()` is `@tagName`. A hand-written decoder usually carries
a parallel several-hundred-line switch that has to be kept in sync with the enum
by hand.

**Errors are typed.** An invalid encoding returns a specific error
(`UnsupportedScalarSource`, `MissingLiteralConstant`, `MissingEndProgram`, …)
rather than a boolean paired with an out-parameter string.

**No allocation on the instruction path.** `decodeInstruction` and everything
below it are allocation-free; the operand list is returned by value. Only
`decodeProgram` allocates, to hold the instruction vector and the branch-target
set.

## Roadmap

1. Validate family/opcode fields against a captured shader corpus and finish
   DPP subgroup lowering, VOP3 modifiers plus the remaining opcode tables.
2. Extend SSA legalization from the current 32-bit scalar/vector core to packed
   16/64-bit values and make more implicit VCC/EXEC effects explicit without
   weakening the conservative tuple dependencies used by memory/image ops.
3. Extend image lowering to array/mip/MSAA, partial-mask store, compare-gather,
   and image-atomic forms; finish the remaining DS operations, masked/multiple
   exports, and system VGPRs against captured resource and stage metadata.

---
