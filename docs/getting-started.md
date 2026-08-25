# Building and command-line usage

[← Documentation index](README.md) · [Project README](../README.md)

For the complete executable/tool map and the native launcher behavior, see the
[architecture and toolchain overview](architecture/overview.md).

## Building

Requires Zig 0.16.

```sh
zig build test                 # run the test suite
zig build check                # compile every module without running tests
zig build                      # build zig-out/bin/rdna2-disasm
zig build run -- shader.bin    # build and run
```

Cross-compilation needs no additional toolchain — Zig ships its own:

```sh
zig build -Dtarget=x86_64-linux-gnu  -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-macos      -Doptimize=ReleaseFast
zig build -Dtarget=aarch64-macos     -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows    -Doptimize=ReleaseFast
```

Windows release packages use Inno Setup 6. A local unsigned package may be
built for verification, but the publishing script rejects it:

```powershell
# Local packaging test only
.\scripts\package-release.ps1 -AllowUnsigned

# Public package: signs both applications and the installer with SHA-256
.\scripts\package-release.ps1 -CertificateThumbprint "YOUR_CODE_SIGNING_CERT_THUMBPRINT"

# Push main/tag and create the GitHub prerelease from the verified artifacts
.\scripts\publish-release.ps1
```

The portable archive and installer contain only `ps5pcem.exe`, `game-run.exe`,
documentation, licensing, version, and branding files. Generated settings,
caches, and savedata are intentionally not packaged.

## Usage

The input is a raw shader binary: a sequence of little-endian 32-bit words, with
no container or header.

```sh
rdna2-disasm shader.bin
rdna2-disasm --cfg shader.bin
rdna2-disasm --check-fragment shader.bin
rdna2-disasm --write-fragment shader.bin module.spv
```

`--cfg` prints control-flow statistics and back edges. `--check-fragment`
requires a fully structured fragment translation, while `--write-fragment`
writes that SPIR-V module for an external validator or driver reproducer.

```
0x00000000: s_mov_b32 s0, s1
0x00000004: s_mov_b32 s1, 0x0000002a
0x0000000c: s_add_u32 s2, s10, s0
0x00000010: s_cmp_eq_u32 scc, s10, 0
0x00000014: s_cbranch_scc0 0x0000001c
0x00000018: s_endpgm
0x0000001c: s_endpgm
```

Three details in that output are worth pointing out, because they are where a
naive decoder goes wrong:

- The instruction at `0x04` takes a 32-bit literal from the following word, so
  the next instruction starts at `0x0c`, not `0x08`.
- The second operand of the comparison prints as `0`. It is not a register but
  an inline constant: source code 128 encodes the integer zero.
- The `s_endpgm` at `0x18` does not end the program. The branch above it targets
  `0x1c`, so the code after it is reachable and decoding continues.

Unimplemented opcodes are reported in place, with the raw words retained:

```
0x00000000: unsupported family=SOP1 opcode=0x02 raw=[0xbe800200] reason=SOP1 opcode is not implemented
```

## Using it as a library

`build.zig` exposes the decoder as a module named `rdna2`, independent of the
CLI:

```zig
const rdna2 = @import("rdna2");

var program = try rdna2.decodeProgram(allocator, code);
defer program.deinit(allocator);

var cfg = try rdna2.buildControlFlow(allocator, &program);
defer cfg.deinit(allocator);

var shader = try rdna2.translateSpirv(allocator, &program, .{
    .stage = .compute,
    .local_size = .{ 8, 8, 1 },
});
defer shader.deinit(allocator);

for (program.instructions.items) |inst| {
    if (inst.opcode.isBranch()) {
        std.debug.print("branch at 0x{x} -> 0x{x}\n", .{ inst.pc, inst.branch_target });
    }
}
```

`decodeInstruction` decodes a single instruction if you want to drive the walk
yourself; `formatInstruction` and `formatProgram` write text to any
`std.Io.Writer`.

## Layout

| File | Contents |
|---|---|
| [src/rdna2/isa.zig](../src/rdna2/isa.zig) | Families, opcodes, operand kinds |
| [src/rdna2/operand.zig](../src/rdna2/operand.zig) | Operand and inline-constant decoding |
| [src/rdna2/instruction.zig](../src/rdna2/instruction.zig) | Instruction representation, literal fetching |
| [src/rdna2/scalar_alu.zig](../src/rdna2/scalar_alu.zig) | SOP family decoders, comptime opcode tables |
| [src/rdna2/scalar_memory.zig](../src/rdna2/scalar_memory.zig) | GFX10 SMEM load decoding and offsets |
| [src/rdna2/vector_alu.zig](../src/rdna2/vector_alu.zig) | VOP1/2/3/3P/C and interpolation decoding |
| [src/rdna2/vector_memory.zig](../src/rdna2/vector_memory.zig) | Buffer, typed, flat, LDS, image and export decoding |
| [src/rdna2/decoder.zig](../src/rdna2/decoder.zig) | Dispatch, parsing a program to `s_endpgm` |
| [src/rdna2/control_flow.zig](../src/rdna2/control_flow.zig) | Basic blocks and validated CFG edges |
| [src/rdna2/ir.zig](../src/rdna2/ir.zig) | Typed nodes, CFG validation, reachability, optimization, and backend legalization |
| [src/rdna2/spirv.zig](../src/rdna2/spirv.zig) | Deterministic SPIR-V 1.5 module writer |
| [src/rdna2/disasm.zig](../src/rdna2/disasm.zig) | Textual output |
| [src/main.zig](../src/main.zig) | Command-line front end |
