# PS5 emulation components

Building blocks for PlayStation 5 emulation, written in Zig. Five modules cover
the independent subsystems and their end-to-end composition:

| Module | What it does |
|---|---|
| **`memory`** | Reserves and manages the fixed, identity-mapped guest address space |
| **`rdna2`** | Decodes and disassembles RDNA2 shader machine code |
| **`loader`** | Reads, maps, and relocates guest ELF64 module images |
| **`hle`** | High-level emulation of the guest firmware: symbol resolution and firmware libraries |
| **`runtime`** | Wires memory, loader, and HLE into one loadable process runtime |

None of them depends on anything beyond the Zig standard library. The tooling
cross-compiles to Windows, Linux, and macOS; native guest execution itself is an
x86-64 feature because guest machine code is executed directly.

Two command-line tools come with them:

```sh
zig build run         -- shader.bin    # disassemble a shader
zig build module-info -- module.elf    # inspect a guest module
```

`module-info` is where the pieces meet. It reads a module, works out every
symbol the module imports, and checks each one against the firmware registry:

```
sample_module.elf
  type          sce_dynexec
  entry         0x1000
  module        sample_app v1.0

segments (2 loadable)
  0x000000001000 size 0x2000     r-x
  0x000000003000 size 0x1000     rw-

needed modules
  [B] libkernel v1.1

imported libraries
  [A] libkernel v1

imports (4)
  ok   rTXw65xmLIA  libkernel  jump_slot
  ok   pO96TwzOm5E  libkernel  jump_slot
  MISS 1jfXLRVzisc  libkernel  jump_slot
  MISS 6UgtwV+0zb4  libkernel  jump_slot

2/4 imports provided
1 relocations reference no symbol
```

The gap between what a module asks for and what exists is the work remaining
before it can run — a more honest measure than any aggregate progress figure.
A `~` instead of `ok` means the symbol matched on identifier alone, because the
module named a library the registry does not know; it may well be the wrong
implementation.

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

# `memory` — guest address space

Guest x86-64 code executes natively and contains absolute addresses. Relocating
the whole process to an arbitrary host allocation is therefore not an option: a
guest address must be the same numeric address in the host process.

[src/memory/root.zig](src/memory/root.zig) reserves the native layout before a
module is loaded. The documented inclusive ranges correspond to these half-open
intervals in the implementation:

| Area | Guest range | Size |
|---|---:|---:|
| System managed | `0x00_0004_0000 .. 0x07_FFFF_C000` | just under 32 GiB |
| System reserved | `0x08_0000_0000 .. 0x0F_C000_0000` | 31 GiB |
| User | `0x70_0000_0000 .. 0xFC_0000_0000` | 560 GiB |

These are reservations, not allocations of physical RAM. Pages are committed
in 16 KiB units only when `mapFixed` or `map` creates a guest mapping. `unmap`
decommits those pages while retaining the outer reservation, so the same guest
address cannot be taken by an unrelated host allocation between uses.

Windows has permanent low-address mappings, notably `KUSER_SHARED_DATA`, inside
the system-managed window. A single `VirtualAlloc` reservation would therefore
fail even though almost the whole window is free. Initialization scans with
`VirtualQuery` and reserves every free extent at its exact address. A requested
mapping that lands in a host-owned hole fails explicitly. Linux uses
`MAP_FIXED_NOREPLACE`; macOS uses a non-destructive fixed hint and rejects a
result returned at any other address. No path uses a `MAP_FIXED` operation that
could overwrite an unrelated host mapping.

The address-space API also owns the sorted mapping table. Loader segments,
private allocations, and direct-memory mappings all go through it, so overlap
checks and page protections cannot disagree between subsystems. Reads and writes
validate the complete range before dereferencing the identity-mapped pointer.

---

# `loader` — guest module images

Guest executables are ELF64 for x86-64, but with vendor extensions that make a
stock ELF reader useless: the object types sit outside the standard range and
are rejected outright, and the dynamic linking tables are not where a normal
loader looks for them.

Parsing remains read-only and non-owning: an `Image` borrows the caller's file
buffer. `loadImage` is the action boundary. It places `PT_LOAD` pages in a
`memory.AddressSpace`, copies file bytes, applies relocations through a supplied
symbol resolver, and installs final ELF page protections.

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
| [src/loader/symbols.zig](src/loader/symbols.zig) | The dynamic symbol table |
| [src/loader/relocations.zig](src/loader/relocations.zig) | Relocation entries and their types |
| [src/loader/imports.zig](src/loader/imports.zig) | Walks all of the above into a list of imports |
| [src/loader/linker.zig](src/loader/linker.zig) | Resolves symbols and writes RELA results |
| [src/loader/image_loader.zig](src/loader/image_loader.zig) | Maps segments, copies bytes, links, and finalizes protections |

Validation is deliberately strict — a module that fails these checks is not
something to load with best effort, since proceeding means interpreting whatever
follows as code. Malformed names are rejected rather than guessed at: a bare
identifier with no library code would otherwise resolve against an arbitrary
library.

## Collecting imports

`imports.collect` is where the tables come together. A relocation names a symbol
index; the symbol names a string; the string carries an identifier plus the two
codes; and the codes only mean anything against the module's own declarations.
Four structures have to be read to learn one fact.

Some distinctions the walk preserves, because they change what a caller must do:

- **Relocations without a symbol** — a `RELATIVE` entry adjusts an address by
  the load bias and imports nothing. Counted, not listed.
- **Symbols the module defines itself** — skipped; only undefined ones have to
  come from outside.
- **Imports whose codes match no declaration** — still reported, with the raw
  codes retained. Dropping them would hide why a module fails to load.
- **Malformed symbol names** — counted and stepped over. One bad entry should
  not make the rest of a module unreadable.

## Mapping and relocation

`loadImage` normalizes every load segment to 16 KiB pages. Overlapping boundary
pages are merged, all pages are staged read/write, and `filesz` bytes are copied
to the exact `load_bias + p_vaddr` address. Anonymous committed pages supply the
required zero-filled `memsz - filesz` tail. Relocations are applied before the
staging permissions are replaced with the union of the ELF flags for each page;
this permits writes into a future read-only GOT without leaving executable code
writable at run time.

The following x86-64 RELA forms are applied:

| Type | Computation |
|---|---|
| `R_X86_64_RELATIVE` | `load_bias + addend` |
| `R_X86_64_64` | resolved symbol address plus addend |
| `R_X86_64_GLOB_DAT` | resolved symbol address |
| `R_X86_64_JUMP_SLOT` | resolved callable address |

Defined symbols resolve inside the mapped module. Undefined symbols go through
the caller's `loader.Resolver`; unresolved strong symbols abort the load, while
unresolved weak symbols become zero. TLS relocations are rejected explicitly
until the runtime has a per-thread TLS module registry. Treating an ordinary
function address as a TLS offset would appear to load successfully and fail much
later, so it is not used as a fallback.

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

Off x86-64 that convention is not expressible at all, and guest code could not
run there anyway: guest binaries are x86-64 machine code executed natively, not
interpreted. Such builds fall back to the host default so the tooling still
compiles, and `abi.can_run_guest_code` records that nothing there is actually
callable from a guest.

## Implemented libraries

**`libkernel` — direct memory** ([src/hle/libs/kernel_memory.zig](src/hle/libs/kernel_memory.zig))

"Direct memory" is the guest's name for physical video memory. A title reserves
a physical range, then maps it into its address space; the two steps are
separate. Reservation bookkeeping covers placement, alignment, overlap
rejection, exhaustion, and release. `sceKernelMapDirectMemory` validates that
the complete physical range was reserved, translates CPU/GPU protection bits,
and either commits the exact `MAP_FIXED` address or performs an aligned first-fit
search in the user window. The resulting mapping carries its physical offset in
the central address-space table.

| Export | State |
|---|---|
| `sceKernelAllocateDirectMemory` | Implemented |
| `sceKernelReleaseDirectMemory` | Implemented |
| `sceKernelGetDirectMemorySize` | Implemented |
| `sceKernelMapDirectMemory` | Implemented for fixed and searched mappings |

The current direct-memory mapping is anonymous host memory tagged with its
physical offset. The common one-reservation/one-mapping startup path is usable;
mapping the same physical pages at several virtual addresses does not yet create
coherent aliases. That next step requires a shared section backing store
(`MapViewOfFile3` on Windows and `memfd`/`mmap` on Linux), without changing the
guest address-space API.

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

1. Shared-section backing for coherent direct-memory aliases.
2. Flexible-memory allocation, `mmap`/`munmap`, and memory-query exports.
3. A TLS module registry for `DTPMOD64`, `DTPOFF64`, and `TPOFF64` relocations.
4. Threading: the `pthread_*` and `scePthread*` families.
5. Event queues, on which most firmware asynchrony is built.

---

# `runtime` — end-to-end composition

[src/runtime/root.zig](src/runtime/root.zig) owns the dependency direction that
does not belong in any lower-level module. It creates one `memory.AddressSpace`,
connects it to libkernel, registers all HLE exports, and adapts `hle.Database` to
`loader.Resolver`. Exact library/module/version metadata is used first; the
identifier-only lookup remains the documented fallback for incomplete module
metadata.

```zig
const runtime = @import("runtime");

var emu = runtime.Runtime{};
try emu.init(allocator);
defer emu.deinit();

var module = try emu.loadModule(eboot_bytes, .{ .load_bias = 0 });
defer module.deinit();

std.debug.print("entry = 0x{x}\n", .{module.entry_point});
```

`Runtime.init` is intentionally in-place. Libkernel retains a pointer to the
address space, so returning a Runtime value from an initializer could move it
and leave that pointer dangling. Loaded modules must be destroyed before the
runtime; their `deinit` method decommits module pages but leaves the outer guest
windows owned until runtime teardown.

---

# License

Copyright (C) 2026 Artur Strazewicz

Licensed under the **GNU General Public License, version 3 or later**. The full
text is in [LICENSE](LICENSE).

What this means in practice, for anyone building on this:

- **Attribution is required.** Copyright notices and license headers must be
  preserved. Every source file carries an `SPDX-License-Identifier` line and a
  copyright line; those stay.
- **Derived work stays open.** If you distribute a modified version, or anything
  that incorporates this code, you must release its complete source under the
  same license. Shipping a binary built from modified sources without publishing
  those sources is not permitted.
- Changes must be marked as yours, so users can tell modified versions from the
  original.

There is no warranty; see sections 15 and 16 of the license.

## Legal note

This project emulates firmware interfaces. It ships no console firmware, no
system libraries, and no copyrighted material belonging to the hardware vendor,
and it neither circumvents nor assists in circumventing any protection measure.
It is intended for interoperability research and education. Supplying the
software a module needs in order to run is your responsibility, and whether you
may lawfully do so depends on where you are.
