# PS5 emulation components

Building blocks for PlayStation 5 emulation, written in Zig. Two independent
modules, each usable on its own:

| Module | What it does |
|---|---|
| **`rdna2`** | Decodes and disassembles RDNA2 shader machine code |
| **`loader`** | Reads guest module images: ELF64 and the dynamic linking tables |
| **`hle`** | High-level emulation of the guest firmware: symbol resolution and firmware libraries |

None of them depends on anything beyond the Zig standard library, and all
cross-compile to Windows, Linux, and macOS from any of them.

---

# `rdna2` — shader decoder

RDNA2 is the GPU architecture behind the PlayStation 5. Its shaders ship as raw
GPU machine code rather than as a portable intermediate representation, so any
tool that inspects, recompiles, or validates them has to start by decoding that
machine code.

## Status

Early, and deliberately narrow in scope.

**Implemented:** the scalar families — `SOP1`, `SOP2`, `SOPK`, `SOPC`, `SOPP`.
That covers scalar ALU operations, comparisons, immediate forms, and the whole
of control flow (branches, `s_endpgm`, `s_waitcnt`, barriers).

**Not implemented:** the vector and memory families — `VOP1`, `VOP2`, `VOP3`,
`VOP3P`, `VOPC`, `VINTRP`, `SMEM`, `MUBUF`, `MTBUF`, `FLAT`, `DS`, `MIMG`,
`EXP`. These are rejected with `error.UnknownInstructionFamily`.

Rejecting them is a deliberate choice rather than an oversight. RDNA2
instructions are variable length, and the length of an instruction is only known
once its family is decoded. Skipping an unrecognized instruction would mean
guessing how many words to advance, and a single wrong guess silently
desynchronizes the parse of everything that follows. Failing loudly at the first
unknown family keeps every result the decoder does produce trustworthy.

Within an implemented family the tradeoff is reversed: an unrecognized opcode
yields an `unsupported` instruction with a diagnostic instead of an error,
because the encoding still tells us the length unambiguously, so the parse can
safely continue.

## Building

Requires Zig 0.16.

```sh
zig build test                 # run the test suite
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

## Usage

The input is a raw shader binary: a sequence of little-endian 32-bit words, with
no container or header.

```sh
rdna2-disasm shader.bin
```

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
| [src/rdna2/isa.zig](src/rdna2/isa.zig) | Families, opcodes, operand kinds |
| [src/rdna2/operand.zig](src/rdna2/operand.zig) | Operand and inline-constant decoding |
| [src/rdna2/instruction.zig](src/rdna2/instruction.zig) | Instruction representation, literal fetching |
| [src/rdna2/scalar_alu.zig](src/rdna2/scalar_alu.zig) | SOP family decoders, comptime opcode tables |
| [src/rdna2/decoder.zig](src/rdna2/decoder.zig) | Dispatch, parsing a program to `s_endpgm` |
| [src/rdna2/disasm.zig](src/rdna2/disasm.zig) | Textual output |
| [src/main.zig](src/main.zig) | Command-line front end |

## Design notes

**Opcode tables are expanded at compile time.** `buildTable` in
[src/rdna2/scalar_alu.zig](src/rdna2/scalar_alu.zig) turns a declarative list of
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

1. Validate the decoder against a reference corpus of shader binaries and
   compare output line by line.
2. `VOP1`/`VOP2`/`VOP3` — the vector ALU, the bulk of any real shader.
3. `SMEM` and `MUBUF`/`MTBUF` — descriptor and buffer access.
4. Basic-block reconstruction from the branch targets the decoder already
   collects.

---

# `loader` — guest module images

Guest executables are ELF64 for x86-64, but with vendor extensions that make a
stock ELF reader useless: the object types sit outside the standard range and
are rejected outright, and the dynamic linking tables are not where a normal
loader looks for them.

Everything here is read-only and non-owning. Parsing answers what is *in* the
file; placing segments needs a guest address space and resolving imports needs
the firmware registry, so neither happens at this layer.

## Why the format needs its own reader

**The dynamic tables are not mapped.** In a conventional ELF, the string table
and symbol table live inside loaded segments and the dynamic entries point at
them by virtual address. Here they sit in a separate `PT_SCE_DYNLIBDATA`
segment, and the pointer-valued entries are offsets into *that* segment. Tags
that would carry an address get vendor replacements in the `0x6100_00xx` range
for exactly this reason.

**Imports do not name what they need.** A symbol name looks like:

```
rTXw65xmLIA#A#A
└─────────┘ │ │
 identifier │ └── module code
            └──── library code
```

The two short codes are meaningless on their own. They refer to library and
module declarations carried in the same module's dynamic tables, so resolving
one import means reading three things together. [src/loader/ids.zig](src/loader/ids.zig)
decodes the codes — a variable-length encoding, one to three characters by
magnitude, sharing the alphabet used by symbol identifiers.

Declarations are packed into a single 64-bit word: identifier in the top 16
bits, version below it, and a string table offset in the low 32.

## What is parsed

| | |
|---|---|
| [src/loader/elf.zig](src/loader/elf.zig) | Header and program headers, validation, segment lookup |
| [src/loader/dynamic.zig](src/loader/dynamic.zig) | Dynamic entries, module and library declarations, symbol names |
| [src/loader/ids.zig](src/loader/ids.zig) | Library and module code encoding |

Validation is deliberately strict — a module that fails these checks is not
something to load with best effort, since proceeding means interpreting whatever
follows as code. Malformed names are rejected rather than guessed at: a bare
identifier with no library code would otherwise resolve against an arbitrary
library.

## Not yet implemented

Relocations and the symbol table itself are located but not walked, so nothing
is resolved yet. That is the next step, and it is what connects this module to
the firmware registry below.

---

# `hle` — firmware emulation

Guest binaries do not ship the firmware they call into. Every import is a numeric
identifier, and the runtime is expected to supply an implementation. This module
provides that machinery and the firmware libraries built on top of it.

## Symbol identifiers

An import is an 11-character identifier derived from the export name: SHA-1 over
the name plus a fixed salt, with the first eight bytes of the digest re-encoded
in a base64 variant. [src/hle/nid.zig](src/hle/nid.zig) computes it.

Computing identifiers rather than hard-coding them is what makes the rest safe.
An implementation is registered under a readable name and can assert the
identifier it is expected to produce:

```zig
.{
    .name = "sceKernelAllocateDirectMemory",
    .function = abi.erase(&sceKernelAllocateDirectMemory),
    .expect_id = "rTXw65xmLIA",
}
```

A misspelled name now fails at registration. With opaque string constants it
would instead surface much later, as an import the guest cannot resolve, with
nothing to point at the cause.

The implementation is pinned by tests against published name/identifier pairs;
breaking it would break symbol resolution for every guest module.

## Symbol registry

[src/hle/symbols.zig](src/hle/symbols.zig) is what the dynamic linker resolves
against. A lookup is keyed on the identifier *together with* the library and
module it was requested from, plus their versions — the same identifier can be
exported by more than one library. A fallback lookup by identifier alone exists
for imports that carry no usable metadata; it is ambiguous by construction and
documented as a last resort.

## Calling convention

Guest code is compiled for the System V AMD64 ABI. On Linux and macOS that is
also the host convention; on Windows the host uses Microsoft x64, which passes
different registers and reserves shadow space.

Every guest-callable function is therefore declared `callconv(abi.guest)`.
Omitting it on Windows still compiles — it just reads arguments from the wrong
registers, surfacing later as nonsensical parameter values. Routing the decision
through [src/hle/abi.zig](src/hle/abi.zig) keeps it in one place.

## Implemented libraries

**`libkernel` — direct memory** ([src/hle/libs/kernel_memory.zig](src/hle/libs/kernel_memory.zig))

"Direct memory" is the guest's name for physical video memory. A title reserves
a physical range, then maps it into its address space; the two steps are
separate. The reservation bookkeeping is implemented — placement, alignment,
overlap rejection, exhaustion, release. Mapping needs the guest address space,
which does not exist yet, so `sceKernelMapDirectMemory` validates the
reservation and then reports that the operation is unimplemented rather than
pretending to succeed.

| Export | State |
|---|---|
| `sceKernelAllocateDirectMemory` | Implemented |
| `sceKernelReleaseDirectMemory` | Implemented |
| `sceKernelGetDirectMemorySize` | Implemented |
| `sceKernelMapDirectMemory` | Validates, then reports unimplemented |

## Error codes

Two numbering schemes coexist in the guest ABI, and mixing them up is a common
source of confusion. Kernel entry points return `0` or a negative status of the
form `0x8002_00xx`, where the low byte is a POSIX error number. POSIX entry
points follow C library conventions instead. [src/hle/errno.zig](src/hle/errno.zig)
models both and converts between them.

Note that internal APIs use Zig error sets, and translation to guest status
codes happens at the entry point. Keeping them apart stops a raw guest status
from leaking into host code where nothing would check it.

## Roadmap

1. Walk the symbol and relocation tables the loader locates, and resolve real
   imports against this registry.
2. Virtual memory: `sceKernelMapDirectMemory` and the flexible-memory calls,
   which need a guest address space.
3. Threading: the `pthread_*` and `scePthread*` families.
4. Event queues, on which most firmware asynchrony is built.
