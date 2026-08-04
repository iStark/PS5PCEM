# PS5 emulation components

Building blocks for PlayStation 5 emulation, written in Zig. Eight modules cover
the independent subsystems and their end-to-end composition:

| Module | What it does |
|---|---|
| **`memory`** | Reserves and manages the fixed, identity-mapped guest address space |
| **`rdna2`** | Decodes and disassembles RDNA2 shader machine code |
| **`gpu`** | Decodes the command stream a title submits to the graphics hardware |
| **`loader`** | Reads, maps, and relocates bare ELF64 and decrypted PS5 SELF module images |
| **`hle`** | High-level emulation of the guest firmware: symbol resolution and firmware libraries |
| **`cpu`** | Dispatches guest execution and provides the Windows x86-64 native machine bridge |
| **`diag`** | Attributes guest addresses to modules and explains contained faults |
| **`runtime`** | Composes memory, loader, HLE, and the optional CPU execution path |

None of them depends on anything beyond the Zig standard library. The tooling
cross-compiles to Windows, Linux, and macOS. Direct guest execution currently
requires Windows x86-64; the other targets still build the inspection and HLE
layers but report the native bridge as unsupported.

Five command-line tools come with them:

```sh
zig build run         -- shader.bin    # disassemble a shader
zig build module-info -- eboot.bin     # inspect a bare ELF or decrypted PS5 SELF
zig build module-info -- eboot.bin sce_module/libc.prx # include a guest provider
zig build module-info -- eboot.bin --names names.txt   # recover published names
zig build pm4-dump    -- capture.bin   # decode a captured GPU command stream
zig build graph-info  -- eboot.bin     # map and relocate the reachable PRX graph
zig build game-run    -- eboot.bin     # load, initialize, and enter the title
zig build game-run    -- --app0 full/game patched/eboot.bin # use full content with a patched executable
```

`module-info` is where the pieces meet. It reads a module, works out every
symbol the module imports, and checks each one against the firmware registry
plus any guest PRX providers passed after it:

```
sample_module.elf
  container     bare_elf
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

exports (0)

imports (4)
  ok   rTXw65xmLIA  libkernel  func  jump_slot
  ok   pO96TwzOm5E  libkernel  func  jump_slot
  MISS 1jfXLRVzisc  libkernel  func  jump_slot
  MISS 6UgtwV+0zb4  libkernel  func  jump_slot

2/4 imports provided
1 relocations reference no symbol
```

The gap between what a module asks for and what exists is the work remaining
before it can run — a more honest measure than any aggregate progress figure.
A `~` instead of `ok` means the symbol matched on identifier alone, because the
module named a library the registry does not know; it may well be the wrong
implementation.

A missing import is only actionable once it has a name, and an identifier is a
hash that cannot be turned back into one. `--names <list>` takes a file of
candidate names, one per line, hashes each, and prints the name of every import
one of them accounts for:

```
  MISS HgX7+AORI58  libkernel  func  jump_slot  sceKernelAioSubmitReadCommands
  MISS 2SKEx6bSq-4  libkernel  func  jump_slot  sceKernelBatchMap
```

The list is supplied rather than built in: which names exist is not something
this project knows. Feeding a large one costs nothing in confidence, because a
name that hashes correctly is evidence on its own and a wrong guess never
matches.

`graph-info` performs the stricter check: it uses the runtime's real fixed
address space, recursively discovers adjacent PRX files, publishes their guest
exports, and applies every relocation without executing guest code. If a strong
import stops a module, the diagnostic includes the module path, NID, library,
and symbol type. This separates a linkage gap from a later initializer or CPU
fault.

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

# `gpu` — command streams

[src/gpu/pm4.zig](src/gpu/pm4.zig) decodes what a title actually sends to the
graphics hardware. A PS5 title does not ask a graphics API to draw: it builds
packets in its own memory — state changes, register writes, draws, dispatches,
fences — and submits the buffer. Everything the GPU ever does arrives that way,
so this stream is the real interface to emulate, and it is the same stream
whichever layer hands it over. Replacing the graphics library and emulating the
kernel device both end up holding one of these buffers, so the decoder depends
on neither choice and on nothing else in the tree.

Nothing is executed. What the decoder provides is legibility: a buffer of opaque
words becomes a sequence of named commands with their bodies delimited, which is
the specification an implementation has to satisfy and can be checked against a
real capture long before anything renders.

Three decisions are worth stating. Body length is stored biased by one, so there
is no way to encode an empty body and a decoder that assumed otherwise would
misplace every following packet. Bounds are enforced on every step, because a
stream is read out of guest memory where a title's bug — or an address this
emulator resolved wrongly — can claim more than the buffer holds; a body that
does not fit is reported, not clipped. And only opcodes with a documented
meaning are named: an invented name in a trace is worse than a number, since a
number invites you to look it up and a wrong name does not.

Register commands carry an offset within a bank rather than an absolute index,
so the bank is recovered from the opcode before the offset means anything — two
different banks have a register at offset zero. `pm4-dump` prints a capture one
packet per line with its word offset, and counts the draws and dispatches:

```
00000: CLEAR_STATE 1 dwords
00002: SET_CONTEXT_REG context[0xa206] x2
00006: SET_SH_REG shader[0x2c0c] x1
00009: NUM_INSTANCES 1 dwords
00011: DRAW_INDEX_AUTO 2 dwords
00014: RELEASE_MEM 6 dwords
00021: PAD
00022: WAIT_REG_MEM 5 dwords predicated
```

## Roadmap

1. Apply context, shader and user-config register writes to persistent GPU state.
2. Execute the synchronization, memory-write and flip packets already present
   in the first captured title DCB.
3. Follow `INDIRECT_BUFFER` into the stream it chains to.
4. Feed the resulting state and draw/dispatch events into a Vulkan executor.

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
| Device | `0x0F_E000_0000 .. 0x0F_F000_0000` | 256 MiB |
| User | `0x70_0000_0000 .. 0xFC_0000_0000` | 560 GiB |

These are reservations, not allocations of physical RAM. Pages are committed
in 16 KiB units only when `mapFixed` or `map` creates a guest mapping. `unmap`
decommits those pages while retaining the outer reservation, so the same guest
address cannot be taken by an unrelated host allocation between uses.

Direct memory is different from a private mapping: its physical offset has a
stable identity. [src/memory/backing_store.zig](src/memory/backing_store.zig)
provides one sparse shared object for the pool, and mappings of the same offset
are coherent aliases. Writing through one guest virtual address is immediately
visible through every other address mapped to those physical pages. The pool's
capacity remains virtual; mapped pages consume backing/commit resources, and
physical working-set pages are faulted on first touch.

Direct and flexible memory are cut from one supply of a little under 13.5 GiB,
which is what the console leaves a title after the system takes its share, so
the direct pool is what remains once the flexible budget is set aside. Reporting
the two independently would promise more memory than the console has, and a
title sizes its allocators from both answers during startup — which is exactly
when it would budget for memory that was never going to exist.

Windows has permanent low-address mappings, notably `KUSER_SHARED_DATA`, inside
the system-managed window. A single `VirtualAlloc` reservation would therefore
fail even though almost the whole window is free. Initialization scans with
`VirtualQuery` and reserves every free extent as a placeholder at its exact
address. Placeholders are split into 16 KiB units before use, replaced by
private pages or section views, and restored and coalesced on unmap. This keeps
partial protection and unmap operations page-accurate. A requested mapping that
lands in a host-owned hole fails explicitly. Linux uses
`MAP_FIXED_NOREPLACE`; macOS uses a non-destructive fixed hint and rejects a
result returned at any other address. No path uses a `MAP_FIXED` operation that
could overwrite an unrelated host mapping.

The shared direct-memory backend is a page-file section with `SEC_RESERVE` on
Windows, a sparse `memfd` on Linux, and an immediately unlinked POSIX shared
memory object on macOS. Section/file views replace only ranges already owned by
the address space. Teardown restores the reservation before closing the backing
object.

The address-space API also owns the sorted mapping table. Loader segments,
private allocations, direct-memory mappings, flexible-memory mappings, and
metadata-only virtual reservations all go through it, so overlap checks, page
protections, names, and memory queries cannot disagree between subsystems.
Partial protection, metadata, and unmap operations split table entries at exact
16 KiB boundaries. Reads and writes validate the complete committed range
before dereferencing the identity-mapped pointer.

---

# `loader` — guest module images

Guest executables are ELF64 for x86-64, but with vendor extensions that make a
stock ELF reader useless: the object types sit outside the standard range and
are rejected outright, and dynamic linking tables use two SDK-dependent
layouts. Titles normally wrap those ELF structures in a PS5 SELF container.

Parsing remains read-only and non-owning: an `Image` borrows the caller's file
buffer. Bare ELF and decrypted/fake-signed PS5 SELF inputs share the same public
API. `loadImage` is the action boundary. It places `PT_LOAD` pages in a
`memory.AddressSpace`, copies file bytes, applies relocations through a supplied
symbol resolver, and installs final ELF page protections.

## Why the format needs its own reader

**SELF offsets are not ELF offsets.** The ELF header and program-header table
sit near the start of a SELF, while each program payload has a separate physical
container offset. The loader resolves every logical `p_offset` through the SELF
segment table. Newer images can also append `PT_SCE_DYNLIBDATA` directly after
the final stored payload while omitting logical NOTE and alignment bytes.
Encrypted or compressed segments are rejected explicitly; this component does
not contain keys or a decompressor.

**Two dynamic-table layouts coexist.** Older modules keep strings, symbols, and
relocations in an unmapped `PT_SCE_DYNLIBDATA` segment and use `DT_SCE_*` offsets
within it. Newer PS5 modules use standard `DT_STRTAB`, `DT_SYMTAB`, `DT_RELA`,
and `DT_JMPREL` virtual addresses inside mapped load segments. `DynamicInfo`
records which addressing mode was found and exposes one checked table-access API
to import discovery, relocation, and TLS export collection.

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
| [src/loader/self.zig](src/loader/self.zig) | PS5 SELF header, segment table, and decrypted-payload validation |
| [src/loader/elf.zig](src/loader/elf.zig) | Header and program headers, validation, segment lookup |
| [src/loader/dynamic.zig](src/loader/dynamic.zig) | Dynamic entries, module and library declarations, symbol names |
| [src/loader/ids.zig](src/loader/ids.zig) | Library and module code encoding |
| [src/loader/symbols.zig](src/loader/symbols.zig) | The dynamic symbol table |
| [src/loader/relocations.zig](src/loader/relocations.zig) | Relocation entries and their types |
| [src/loader/imports.zig](src/loader/imports.zig) | Walks all of the above into a list of imports |
| [src/loader/exports.zig](src/loader/exports.zig) | Owns the process-wide registry of mapped guest exports |
| [src/loader/linker.zig](src/loader/linker.zig) | Resolves symbols and writes RELA results |
| [src/loader/tls.zig](src/loader/tls.zig) | Owns `PT_TLS` templates, module IDs, and static Variant II layout |
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
required zero-filled `memsz - filesz` tail. Its `prepareImage` and `linkImage`
halves expose the same operation in two phases: a process can map every PRX and
publish all ordinary and TLS exports before applying any cross-module
relocation. This supports mutual dependencies without load-order guesses.
Relocations are applied before staging permissions are replaced with the union
of the ELF flags for each page, so a future read-only GOT remains writable only
during linking.

The following x86-64 RELA forms are applied:

| Type | Computation |
|---|---|
| `R_X86_64_RELATIVE` | `load_bias + addend` |
| `R_X86_64_64` | resolved symbol address plus addend |
| `R_X86_64_GLOB_DAT` | resolved symbol address |
| `R_X86_64_JUMP_SLOT` | resolved callable address |
| `R_X86_64_DTPMOD64` | TLS ID of the module defining the symbol |
| `R_X86_64_DTPOFF64` | module-relative TLS symbol offset plus addend |
| `R_X86_64_TPOFF64` | module-relative offset minus its static thread-pointer offset |

Defined symbols resolve inside the mapped module. Undefined symbols go through
the caller's `loader.Resolver`; unresolved strong symbols abort the load, while
unresolved weak symbols become zero. TLS imports use a separate resolver path:
an ordinary function address is never accepted as a TLS offset.

The ordinary guest registry copies each global/weak export's NID, library,
version, module, type, and relocated address. Resolution prefers the complete
key and retains an identifier-only fallback for incomplete metadata. Unloading
an image removes all of its exports before its pages disappear.

Every image with a non-empty `PT_TLS` segment receives a stable, non-zero module
ID. The process registry copies its initialized `tdata`, records the zero-filled
`tbss` extent, and lays modules out below the thread pointer according to AMD64
TLS Variant II. The layout preserves both module alignment and the ELF
`p_vaddr` alignment bias. Unloading removes the template and exports but does
not renumber modules or repack surviving offsets, because relocation results
already written into memory must remain valid.

Thread creation snapshots the registry under one lock, then allocates an
identity-mapped per-thread region in the guest user window. At least 128 KiB of
prefix space below the thread pointer holds the static Variant II blocks,
zero-filling each module's complete `memsz` before overlaying its `tdata`. The
TCB contains the self pointer at `FS:0`, the DTV pointer at `FS:8`, the pthread
handle at `FS:0x10`, the stack canary used by guest runtimes, and libc's errno
slot at `FS:0x80`. The DTV records the registry generation, maximum module ID,
and the address of every static block. `__tls_get_addr` resolves its module and
offset pair through that same per-thread DTV.

Startup metadata is retained after relocation instead of being discarded with
the parsed dynamic table. `MappedImage` publishes the mapped `PT_SCE_PROCPARAM`
range plus ordered `DT_PREINIT_ARRAY`, `DT_INIT`, and `DT_INIT_ARRAY` functions.
Array entries are read only after relocations and final page protections are in
place, and every non-sentinel target must resolve to executable guest memory.
Preinitializers are accepted only from an executable; `DT_INIT` precedes its
`DT_INIT_ARRAY` entries for the same image.

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

## Firmware runs on a host stack

A guest calls firmware directly, so firmware executes on the calling guest
thread's stack — one megabyte, typically, because that is what the title asked
for. Host code needs far more: opening a file reserves a path buffer of tens of
kilobytes, and a compiler allocates a function's whole frame on entry, before
any branch can return early. A firmware call can therefore overrun the guest
stack *without ever reaching the code that needed the room*.

That was not a theory. Replacing one entry point's body with `return -1` left
the title running; restoring a single call into a function that merely *contains*
a path to `openFile` killed it, and raising the guest stack to eight megabytes
made the same code work again.

The overrun also lands outside every guest mapping, so the guest fault handler
declines it and the process dies with nothing to explain why.

[src/hle/host_stack.zig](src/hle/host_stack.zig) therefore switches to a
per-thread host stack for the duration of every call. Arguments travel through
memory rather than registers, which keeps the assembly to a single function that
knows nothing about any signature — it takes a context pointer and a target and
returns nothing, so floating-point and aggregate returns need no special
handling. Nested firmware calls stay on the stack the outer one established.

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

**`libkernel` — virtual and direct memory** ([src/hle/libs/kernel_memory.zig](src/hle/libs/kernel_memory.zig))

"Direct memory" is the guest's name for physical video memory. A title reserves
a physical range, then maps it into its address space; the two steps are
separate. Reservation bookkeeping covers placement, alignment, overlap
rejection, exhaustion, and release. `sceKernelMapDirectMemory` validates that
the complete physical range was reserved, translates CPU/GPU protection bits,
and either commits the exact `MAP_FIXED` address or performs an aligned first-fit
search in the user window. The resulting mapping carries its physical offset in
the central address-space table and maps the runtime's sparse shared backing
store. Multiple virtual mappings of one physical range are coherent. Releasing
a physical reservation while one of its mappings remains live returns `EBUSY`.

Two behaviours here follow from how titles actually use the API rather than from
what the calls appear to mean in isolation.

A fixed mapping into a range the title reserved earlier **commits inside the
reservation** instead of releasing it first. A title reserves a window once and
fills it in pieces, so releasing would give up its claim on everything not yet
mapped. It is also the only way that works: the host placeholder covering a
reservation has to be split for the sub-range, and releasing part of it tries to
coalesce with neighbouring free space that belongs to a different placeholder.

Physical memory is **released in whatever shape the title asks for**, not only
in the shape it was allocated. Titles routinely allocate in one arrangement and
hand memory back in another, so a release can cover part of a reservation, carve
a hole out of its middle, or span several. What the release does not cover stays
reserved. A range covering nothing reserved is still an error: it means the
title believes it owns memory it does not.

Flexible memory uses the same address-space table without inventing a second
allocator. The runtime exposes the platform-default 4 GiB budget, derives the
available amount from live `.flexible` mappings, and searches the
system-managed window from `0x02_0000_0000` before falling back to the user
window. Fixed mappings, no-overwrite mappings, encoded alignment requests,
partial unmaps, and zero-filled reuse are covered by the same lifecycle rules.

**`libkernel` — module loading** ([src/hle/modules.zig](src/hle/modules.zig))

A title does not reach all of its own code through the dynamic tables. Some
modules it loads itself, by path, at the point it needs them. Everything
adjacent to the executable is already mapped and relocated before guest code
runs, so `sceKernelLoadStartModule` resolves the request to what exists and
returns its handle. Loading again would produce a second copy with its own
relocations and duplicate the state the title expects to be shared.

Path matching ignores separator style and case. The case part is not
defensiveness: this title asks for `Il2CppUserAssemblies.prx` while shipping
`Il2cppUserAssemblies.prx`, so an exact match would refuse a module the title
installed itself. The relative path is tried before the bare file name, so two
modules sharing a name stay distinguishable.

Virtual reservations occupy guest addresses without committing host pages.
`sceKernelReserveVirtualRange` can create either a fixed or first-fit
reservation, and a later fixed flexible mapping consumes it. Memory queries use
the guest's 72-byte `VirtualQueryInfo` ABI, report half-open ranges, preserve
the original guest protection bits, and support both containing and next-range
lookups. Protection changes and names are applied to exact subranges, splitting
mapping metadata where required.

| Export | State |
|---|---|
| `sceKernelAllocateDirectMemory` | Implemented |
| `sceKernelReleaseDirectMemory` | Implemented |
| `sceKernelGetDirectMemorySize` | Implemented |
| `sceKernelMapDirectMemory` | Implemented for fixed and searched mappings |
| `sceKernelMapFlexibleMemory` | Implemented for fixed and searched mappings |
| `sceKernelMapNamedFlexibleMemory` | Implemented, including alignment and names |
| `sceKernelMunmap` | Implemented, including partial mappings |
| `sceKernelVirtualQuery` | Implemented for containing and next-range queries |
| `sceKernelQueryMemoryProtection` | Implemented |
| `sceKernelAvailableFlexibleMemorySize` | Implemented |
| `sceKernelConfiguredFlexibleMemorySize` | Implemented |
| `sceKernelMprotect` | Implemented |
| `sceKernelSetVirtualRangeName` | Implemented |
| `sceKernelReserveVirtualRange` | Implemented for fixed and searched reservations |

**`libkernel` — pthread bootstrap and TLS** ([src/hle/libs/kernel_threading.zig](src/hle/libs/kernel_threading.zig))

Guest pthread and attribute handles are stable opaque pointers, matching the
firmware ABI used by both reference emulators. The manager owns their lifecycle,
copies attributes at creation, creates one TLS/TCB/DTV mapping per thread, and
reclaims it after join or detached completion. The initial process thread uses
the same path through `Runtime.prepareInitialThread`, so it does not receive a
special TLS layout.

The implemented lifecycle surface includes `create`, `join`, `detach`, `self`,
`equal`, `exit`, `yield`, `once`, and `sceKernelUsleep`, with both
`scePthread*` and POSIX spellings where the firmware exports both. Attributes
cover copy/get, stack address and size, guard size, detach state, affinity,
inherit-sched, scheduling parameters and policy, and solo scheduling. POSIX TLS
keys store values per guest thread and run guest destructors for up to the four
standard passes. POSIX wrappers return plain positive errno values; sce entry
points return kernel statuses.

Thread execution is connected through an explicit backend adapter. Every start
request contains the entry point, argument, pthread identity, scheduling hints,
a mapped guest stack with a no-access guard, and a ready `ThreadContext`
containing the guest `fs_base`. HLE code never replaces a host segment register.
The `cpu` dispatcher consumes this contract and calls its machine bridge only
across guest instruction execution. Until a dispatcher is attached, creation,
positive-duration sleep, and guest callbacks from `once` report `ENOSYS`.
`scePthreadExit` runs key destructors itself and, because its ABI returns `void`,
continues thread exit if a destructor callback fails.

**`libkernel` — pthread synchronization** ([src/hle/libs/kernel_sync.zig](src/hle/libs/kernel_sync.zig))

Mutexes, condition variables, and reader/writer locks use stable opaque guest
handles backed by host-owned records. Null static initializers are materialized
lazily. Mutexes track ownership, recursive depth, type, protocol metadata, and
timed/try operations. Condition waits atomically publish themselves and release
the associated mutex, then always reacquire it before returning, including after
a timeout. Reader/writer locks retain per-thread reader ownership and prefer a
queued writer over new readers so writers cannot be starved indefinitely.

Blocking is scheduler-neutral. Every object has a monotonic sequence number;
the backend receives the number observed before parking and can therefore avoid
a lost wakeup when a signal races with the unlock-to-wait transition. Wake
requests carry the same object key, the new sequence, and either one or all as
the waiter limit. Timed waits accept relative microseconds for sce entry points
and clock-tagged absolute nanosecond deadlines for POSIX entry points. The CPU
dispatcher provides the production wait/wake path; the HLE-only fallback yields
solely so isolated unit tests can exercise state transitions.

**System-libc bootstrap ABI** ([src/hle/libs/kernel_runtime.zig](src/hle/libs/kernel_runtime.zig))

The genuine `libc.prx` is now the provider for its 2,922 exports instead of a
parallel HLE libc. Its 120 lower-level imports resolve through a focused
libkernel bridge plus `libSceLibcInternalExt` and `libSceSysmodule`. Data imports
such as `__stack_chk_guard` and `__progname` are registered as storage addresses,
not function stubs. Runtime hooks provide per-thread errno/TLS, clocks, sleep,
process parameters, sanitizer opt-out records, and rtld callbacks. Operations
whose backing subsystem is not implemented yet return `ENOSYS` or `ENOENT`
instead of reporting false success.

The Unity support PRXs also receive the small `libkernel_unity`, `libScePosix`,
RTC, system-parameter, app-content, and network-control bootstrap surface they
need to relocate. This is linkage coverage, not a claim that filesystems,
networking, event flags, or semaphores are complete.

**Title bootstrap services** ([src/hle/libs/system_service.zig](src/hle/libs/system_service.zig),
[src/hle/libs/user_service.zig](src/hle/libs/user_service.zig),
[src/hle/libs/pad.zig](src/hle/libs/pad.zig))

The runtime exposes one stable signed-in user and one neutral connected local
controller. User login is delivered once through the service event API; later
polls report `NO_EVENT`. System preferences, safe-area and HDR defaults, the
notice-screen flag, and music-player suppression retain coherent state. System
UI actions that cannot exist without a shell return `UNAVAILABLE`.

Kernel user-edge event queues retain registrations and pending event payloads,
and their waits use the same sequence-aware dispatcher contract as pthread
synchronization. Main direct-memory allocation, named direct mappings, stack
queries, and live pthread scheduling metadata are also exposed. APR entry points
are linkable but return `ENOSYS` until the runtime owns an accelerator backend;
they never fabricate successful I/O.

**Offline network, dialogs, and headless audio**
([src/hle/libs/network.zig](src/hle/libs/network.zig),
[src/hle/libs/dialogs.zig](src/hle/libs/dialogs.zig),
[src/hle/libs/audio.zig](src/hle/libs/audio.zig))

Net, SSL, HTTP/HTTP2, and NP Web API preserve their normal context and request
lifecycles without opening host sockets. Local URI parsing remains available,
while DNS and peer traffic return deterministic offline errors. NetCtl reports
a disconnected interface. Common, message, web-browser, and IME dialogs finish
immediately with coherent headless results instead of blocking on unavailable
UI.

AudioOut, AudioIn, and AudioOut2 expose paced ports and queues. AJM accepts the
title's batch lifecycle and emits zeroed PCM so audio setup cannot deadlock the
process. It is a compatibility decoder, not ATRAC9/MP3 decoding. The additional
early-bootstrap
surface in [src/hle/libs/bootstrap_services.zig](src/hle/libs/bootstrap_services.zig)
provides headless VideoOut/AvPlayer state and conservative platform/GPU command
stubs solely to reach native title initialization; it does not render frames.

**Sound output** ([src/hle/audio_device.zig](src/hle/audio_device.zig))

A title hands over one buffer of samples at a time and expects the call to take
about as long as the sound lasts, because that is how it keeps time with audio.
That wait now comes from a host device making room for the next buffer rather
than from a sleep, so the clock is the real one and the samples are heard
instead of discarded. Three buffers stay in flight: one is not enough, because
the device runs dry between finishing a buffer and the title handing over the
next, which is audible as a click every buffer.

One port is audible, because there is one pair of speakers. A title opens a main
output port and often others besides; letting each claim the device would
interleave unrelated streams. The rest keep the silent path, which is what they
had before.

Failure to open a device is never reported to the title. Having no sound card,
being denied access to one, or being refused a format are facts about the host,
not about the title, so the caller falls back to sleeping and behaves exactly as
it did before. The same applies to a device that stops working mid-run: losing
sound is not a reason to stop a title. Output is Windows-only for now; elsewhere
the ports are silent and correctly paced.

**Asynchronous file reads** ([src/hle/libs/kernel_aio.zig](src/hle/libs/kernel_aio.zig))

A title hands over a batch of read requests and receives an identifier; later it
asks whether that batch is done and collects the results. Engines that stream
assets do all of their loading this way, so a title built on one cannot read a
single file without it.

The reads happen where the batch is submitted, so a batch is always finished by
the time anyone asks. That is a legal outcome of the interface rather than a
shortcut around it — a caller has to cope with a request that completed at once,
because a fast device does exactly that — and the alternative, a thread pool of
our own, would invent an ordering between requests that a title could come to
depend on before there is any real device to justify it.

Writes are accepted as batches and then reported, request by request, as having
failed, with the same refusal the filesystem gives a direct write. A title told
its save was written when it was not carries on and loses it somewhere further
along, where nothing points back here. A batch naming nowhere to put an outcome
is refused before any of it runs, since finding out halfway would leave some
requests done and the caller unable to learn which.

**Title content and devices** ([src/hle/filesystem.zig](src/hle/filesystem.zig),
[src/hle/libs/kernel_files.zig](src/hle/libs/kernel_files.zig),
[src/hle/libs/kernel_ioctl.zig](src/hle/libs/kernel_ioctl.zig))

A title sees the directory holding its executable as `/app0`, and nothing above
it: a path that escapes the mount is refused rather than resolved against the
host, because on hardware a title cannot reach there either. The mount is
read-only, and anything that would modify it is refused rather than ignored, so
a title never proceeds believing its data was stored. Each descriptor carries
its own position and reads positionally, so two descriptors on one file cannot
disturb each other, and a descriptor closed during a read cannot have a reused
slot's position corrupted afterwards.

Device nodes share that namespace because that is how a title reaches them, but
they are answered here rather than from the host, which has no such devices.
`/dev/gc` is the graphics core and `/dev/dipsw` the console's mode switches.
A device is not a file: it needs no mount, since whether a game directory
happens to be attached has nothing to do with whether hardware exists; reading
or seeking one reports `ENODEV` rather than an empty file; and `stat` describes
it as the character device it is.

Control requests are decoded rather than passed through as opaque numbers. A
request code is a packed record — direction, payload length, device group and
command number — so a trace reads as `/dev/gc 0x81 #46 inout 4 bytes` instead of
`0xc004812e`, followed by the bytes that actually travelled inward. That
decoding is the specification any future implementation has to satisfy, and it
is what a real driver's requests are now recorded as.

What a shipped `libSceAgcDriver` asks for is documented in
[src/hle/libs/kernel_ioctl.zig](src/hle/libs/kernel_ioctl.zig): which request
comes first, what answering it unlocks, and — for the one whose payload looks
like a request but is not — why. It was obtained by running the driver against
this layer and reading its own diagnostics, then confirming each reading against
its machine code. Neither reference emulator records any of it, because both
reimplement the graphics API and never reach a device node.

Mode-switch reads are answered as clear, which is the state of a retail console
and not an invented value; only the byte count the request itself declares is
written, through a pointer checked against the guest address space, and only up
to a bound. The two recovered graphics discovery requests are answered exactly.
Other graphics requests are refused with `ENOTTY`: queue registration hands
back handles and addresses the driver will later dereference, so false success
would replace an actionable error with delayed corruption.

The shipped driver also relies on addresses that look like hints but are part
of its ABI. Its 2 MiB direct-memory pool remains at `0xfe0000000`, the small
`/dev/gc` aperture remains at `0xfe0200000`, and the AGC firmware-services table
therefore lands at the required `0xfe0040000`. Relocating either range makes the
backported library stop with its own fatal FS-table diagnostic.

**Services this machine does not have** ([src/hle/libs/services.zig](src/hle/libs/services.zig))

A large title links against a great deal it will run without: an online account
system, a headset, a store, a voice channel, an accelerator. A missing import
stops a module linking at all, so until each is answered the title cannot start
far enough to reach the parts that do work.

Every answer here says the facility is unavailable rather than that the call
succeeded, and that distinction is the point. A title told its request succeeded
goes looking for a result nothing produced — a session to join, a headset pose,
a file the accelerator was to have fetched — and fails somewhere with nothing
pointing back. A title told the facility is absent takes the path it already has
for a console with no network, no peripheral and no entitlement: a path its own
authors wrote and tested.

The refusal is the kernel's own "not implemented", which sits outside every
service library's numbering. Each library numbers its errors in a space of its
own, and a code invented inside one of those could be mistaken for a documented
outcome and acted upon; this one cannot be.

Library and module names are recorded separately, because they routinely differ
— a library whose name ends in a version digit usually lives in a module without
one. Binding under the wrong module leaves an import that matches on identifier
alone, which the loader rightly refuses: a bare identifier is no evidence that
this is the implementation the caller meant.

**Graphics command construction** ([src/hle/libs/agc.zig](src/hle/libs/agc.zig))

A title does not ask the graphics library to draw. It asks it to *write*: each
entry point appends one command to a buffer the title owns, and the buffer is
handed over later in a single submission. What these have to get right is
therefore not rendering but bookkeeping — how much room a command takes, and
that the buffer stays a walkable sequence of commands afterwards.

Unimplemented constructors write a correctly formed no-operation of the size
the real command would have taken, which is not the same as filling the space
with zeroes. Zeroes decode as a register write of one word and desynchronise the
rest of the stream. `Dispatch`, `DrawIndex`, and `SetNumInstances` now write
their real PM4 packets, with a valid no-operation filling the unused part of
each fixed 16-word AGC slot. Shader constructors validate their AGC headers,
relocate internal pointers and program addresses, and apply the recovered
program-register pairs. Everything after them remains walkable through
[`gpu.pm4`](src/gpu/pm4.zig), while measured and consumed sizes stay identical.

Patch entry points are accepted and change nothing: they edit a field of a
command already written, usually an address unknown when it was built, and
editing a no-operation is harmless. Frame capture, submission validation and
shader debugging report themselves off, which is the retail answer and the one
that stops a title waiting for a capture nobody will take. Resource
registration is refused, because it hands back names and addresses a title
keeps and later follows.

**GPU submission** ([src/hle/libs/agc_submit.zig](src/hle/libs/agc_submit.zig))

The submission entry points are where a title hands its GPU work over, and by
the time a call arrives every draw, state change and fence of a frame is already
sitting in the buffer. Intercepting it therefore yields a complete description
of a frame without modelling any of the calls that built it. Each submitted
range is checked against the guest address space and then decoded through
[`gpu.pm4`](src/gpu/pm4.zig), so a trace shows what was asked for rather than an
address and a length. In a batch, a null entry is skipped rather than ending the
batch, since the arrays are indexed in parallel and stopping early would drop
every buffer after a hole the title left deliberately.

Submissions are accepted rather than refused, which is the opposite of the
choice made for the graphics device, and the difference is what a caller does
with the answer. A refused device request is one whose reply the driver stores
and dereferences, so false success crashes it. A submission returns only a
status and the title is not blocked on it, so reporting failure would abort a
frame the title had already fully described — and lose the description with it.

The current title reaches two submissions of 480 and 544 dwords. The decoder
walks 35 and 39 packets respectively and observes one draw plus three dispatches
in each, which is the first stable execution boundary for the GPU state tracker.

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

1. Apply the submitted PM4 register and synchronization packets to internal GPU
   state through an executor interface.
2. Implement APR/AMPR file resolution and reads for titles whose patched
   executable reaches streaming before graphics submission.
3. Recover `/dev/gc` queue-registration outputs for the shipped driver path.

---

# `cpu` — guest dispatcher

[src/cpu/root.zig](src/cpu/root.zig) is the scheduling half of CPU execution. It
spawns one host worker per guest pthread, associates it with the HLE pthread
identity, carries the ready FS/TCB/DTV context and guest stack into each entry,
and completes the HLE thread only after guest execution has left that context.
Join, detach, yield, sleep, nested guest callbacks, natural-return TLS
destructors, and `scePthreadExit` propagation all use this path.

Waits use the Zig I/O futex abstraction. Wake events retain their object
sequence and cardinality, so a signal that lands between an HLE unlock and the
worker actually parking is consumed exactly once. Broadcasts remain visible to
every waiter that observed an older sequence. If the fixed key/event history is
ever saturated, the dispatcher deliberately over-wakes and lets HLE recheck the
object instead of risking a dropped wake and process deadlock.

Machine execution is represented by `cpu.Bridge`. Its request includes the
entry point, six System V AMD64 integer arguments, thread identity, guest stack,
optional pre-call RSP, and complete TLS context. This boundary is intentionally
strict: POSIX hosts commonly use FS for their own TLS, while Windows x86-64
keeps the TEB under GS and leaves FS available to guest code. Kyty and SharpEmu
make the same separation, although their patch/trampoline machinery differs.

`cpu.NativeBridge` implements the first direct backend for Windows x86-64. It
checks the operating system's `PF_RDWRFSGSBASE_AVAILABLE` capability before use,
validates that entry points are executable and stacks/TLS are mapped, preserves
the Win64 nonvolatile GPR and XMM registers plus MXCSR and x87 control state,
switches to the mapped guest stack, installs the guest FS base, and calls the
entry with the System V AMD64 convention. Nested guest callbacks reuse the active
guest stack below the HLE frames. A synchronous `scePthreadExit` takes a native
escape path which discards those guest frames and restores host FS/state before
the dispatcher observes `error.Interrupted`.

## Windows does not keep a guest thread pointer

Installing the FS base is not enough, because Windows does not preserve a
user-written one across a context switch. After a guest thread sleeps or blocks,
`rdfsbase` reads zero again — measured on Windows 11, a one-millisecond sleep
loses it *every single time*, and a blocking call loses it occasionally. Guest
code follows the System V convention and keeps its thread-local storage in FS, so
the first FS-relative access after the thread is rescheduled reads a near-zero
address and faults. Nothing in the guest is wrong: the host dropped a register
the guest is entitled to rely on.

This is not a condition that can be prevented, since being descheduled is
asynchronous, so it is repaired instead. The vectored handler recognises a fault
in the first page on a thread whose FS base has gone to zero, puts the base back,
and retries the instruction. Before this, a title died at whichever thread-local
access happened to follow its first sleep, which is why its crash address moved
between runs.

A genuine null dereference is not swallowed by the repair. Restoring the base
does not make that instruction succeed: it faults again, the handler sees a base
that is no longer zero, declines, and the fault is reported normally. The cost of
being wrong is one extra trip through the handler. `cpu.fs_base_restorations`
counts the repairs, because how often the host is losing state the guest depends
on is worth knowing rather than hiding.

The Windows backend also owns a first-priority vectored exception handler for
active guest execution. It claims access violations and illegal instructions
only when the faulting RIP lies inside one of the fixed guest windows; host and
HLE faults continue through the normal Windows search. A claimed fault snapshots
all general-purpose registers, access type and target address, redirects the
saved Windows context to the assembly escape path, restores host FS/register
state, and returns `error.GuestFault`. `NativeBridge.lastFault` and
`Runtime.lastNativeFault` expose that diagnostic record without reading guest
memory from inside the exception handler.

Before an illegal instruction becomes a fault record, an allocation-free
compatibility decoder tries the AMD instructions emitted for the PS5's Zen 2
CPU. `MONITORX` and `MWAITX` advance as completed wait operations, while the
immediate register forms of SSE4a `EXTRQ` and `INSERTQ` update the saved XMM
state according to AMD's six-bit length/index rules. Returning from VEH then
resumes at the following guest instruction. Unknown opcodes retain the normal
`error.GuestFault` path.

The bridge intentionally does not force a context change in another host
thread. Shutdown marks such an execution interrupted and observes it when guest
code returns; suspending a worker inside HLE could abandon host locks. Windows
fault containment and the first AMD compatibility handlers are now present,
but mixed guest/HLE frames do not yet have an unwind-safe import transition and
unrecognized illegal instructions still stop execution. Arbitrary `eboot.bin`
execution is therefore not safe yet. Linux and macOS need a different
FS/HLE-transition strategy because their host TLS rules differ. GPU submission
and host audio output consequently remain beyond the current title bootstrap.

## Roadmap

1. Introduce import transition stubs with Windows unwind metadata, host-stack
   recovery, diagnostics, and platform TLS restoration.
2. Extend resumable instruction compatibility to SHA-NI and other missing Zen 2
   features when title traces demonstrate a host capability gap.
3. Add a POSIX native bridge with explicit host-TLS restoration around HLE.

---

# `diag` — explaining failures

Bringing a title up produces addresses, and an address explains nothing on its
own: it depends on where modules happened to land, so the same failure reads
differently between runs. Worse, the most informative failures are exactly the
ones whose faulting address belongs to no module at all.

## Address attribution

[src/diag/symbolize.zig](src/diag/symbolize.zig) maps an address to the owning
module, the offset within it, and the nearest export at or below:

```
0x0000000801731565 libc.prx+0x35565 (Zb+hMspRR-o+0x25)
```

Titles ship no debug information, so an export is an anchor rather than an exact
function name — the real function may begin after it. Data exports are excluded
from anchoring, since a variable never appears in a call stack and would drag
attribution away from the code.

## Fault reports

[src/diag/fault.zig](src/diag/fault.zig) classifies a contained fault instead of
printing the raw exception. The case worth separating is a call through a
function pointer that was never filled in: its faulting address belongs to no
module and is therefore useless, but the return address the `call` just pushed
identifies the caller exactly.

```
guest fault: call through a null pointer
  kind        access_violation (execute)  code 0xc0000005
  rip         0x0000000000000000 <unmapped>
  called from 0x0000000801731565 libc.prx+0x35565 (Zb+hMspRR-o+0x25)
  stack scan
    0x0000000801714daa libc.prx+0x18daa (__cxa_throw+0x2aa)
    0x0000000801711e72 libc.prx+0x15e72 (_Throw_C_error+0xe2)
```

Reading guest memory during a fault report is guarded by a mapping check, so
reporting a failure cannot fault again and lose the report.

The stack listing is labelled a scan rather than a backtrace on purpose. Guest
code omits frame pointers in places, so a reliable unwind is unavailable;
keeping the stack words that land inside a loaded module recovers the call chain
in practice, at the cost of occasional stale entries.

## The title's own account

A title about to fail usually says why first, and it says it by passing a message
to something. The System V argument registers are where that message is at the
moment of the fault, so the report recovers text from the registers — following
one indirection, because a message is as often passed by reference as by value
and the register then holds the string object rather than its characters.

The filter is deliberately strict: a pointer into mapped memory nearly always
has a few printable bytes at it, and a report that offers noise as though it
were the title's words is worse than one that offers nothing. A run must be at
least eight characters, contain a letter, and end at a terminator or fill the
window — anything else merely began like text. A message longer than the window
is shown cut short, since the first lines are the ones that name the problem.

This turns a register dump into the title's explanation of what went wrong:

```
guest fault: the guest trapped on purpose, or ran what it may not
  text in registers
    [rax] "Could not allocate memory: System out of memory!
Trying to allocate: 8589934592B with 16 alignment. MemoryLabel: TempOverflow"
```

A general-protection fault is classified as a trap rather than as a memory
failure. It has no faulting address, and the host reports that absence as an
all-ones one; reading it as an address sends the reader hunting for a wild
pointer when the guest in fact executed a software interrupt on purpose, which
is how a title's own assertions stop it.

## Which of the title's code made a call

The call trace says which firmware calls a title made. It does not say which of
the title's own code made them, and once a call is seen to repeat thousands of
times that is the only question left. `PS5_STACK_AT=<entry point>[:<call
number>]` arms a one-shot snapshot of the guest stack at one call, printed with
the fault report and resolved against the loaded modules.

The snapshot is taken in the trace's entry hook, before firmware moves onto a
stack of its own — by the time an entry point's body runs, the guest stack is no
longer the one underfoot, and the caller is out of reach. It is anchored on a
local rather than on the frame address, because the frame pointer is omitted in
optimized builds and what it reports then is not the stack at all.

A call is named by entry point and occurrence rather than by position in the
trace, because a title runs on several threads: a call's position is decided
when it finishes, by which time other threads have taken numbers of their own,
so a position noted in one run does not name the same call in the next. How many
times a title has called one entry point is not subject to that.

## Firmware call trace

The failure a title reports is usually not where it went wrong. A firmware entry
point returns a plausible-looking error, the title's own runtime reacts to it,
and the process dies several frames later.

Guest code calls firmware directly through relocated jump slots, so there is no
single place to instrument. Instead [src/hle/trace.zig](src/hle/trace.zig)
generates a thunk per entry point at compile time, with the same signature, that
records the call and forwards it. Only the most recent calls are kept, in a
fixed ring: a title makes millions, and the last few dozen are what explain a
failure.

```
  last 32 firmware calls (of 11412)
     11400 sceKernelAllocateMainDirectMemory(0x400000, 0x0, 0xc, ...) = 0x0
     11401 sceKernelMapDirectMemory(..., 0x400000, 0xf2, 0x10, 0x12500000, 0x0) = 0xffffffff8002000c  <- failure
     11412 sceKernelVirtualQuery(0x202500000, 0x0, ..., 0x48) = 0xffffffff8002000d  <- failure
```

Both failure conventions are marked: the `0x8002_00xx` kernel scheme and the
POSIX `-1`. Zero is deliberately not marked, since too many entry points return
zero for success.

This is what the tooling is for. The trace above says a title reserved a range,
allocated physical memory for it, failed to map the two together, and then wrote
to the range anyway — which is a far more useful statement than the address the
process eventually died at.

## Guest diagnostics

A runtime about to give up almost always explains itself first, through a write
to its own standard error. Guest writes to the standard streams now reach the
host directly, but the trace also retains the buffer address and length, so the
message survives even when the write itself fails:

```
  guest diagnostics
    [stderr] Terminating due to uncaught exception 'invalid argument: invalid
             argument' of type std::system_error
```

In the title's own words, which no amount of address attribution can supply.
That one line identified three separate defects at once: a synchronization
primitive that refused re-initialization, missing unwind tables that turned
every recoverable exception into a terminate, and the silenced write that hid
all of it.

---

# `runtime` — end-to-end composition

[src/runtime/root.zig](src/runtime/root.zig) owns the dependency direction that
does not belong in any lower-level module. It creates one `memory.AddressSpace`
with the sparse direct-memory backing store, connects it to libkernel, registers
all HLE exports, owns the process TLS and guest-export registries, and adapts all
three sources to `loader.Resolver`. Exact library/module/version metadata is used
first; identifier-only lookup remains the documented fallback for incomplete
module metadata. [src/runtime/module_graph.zig](src/runtime/module_graph.zig)
recursively indexes adjacent `.prx`/`.sprx` files, follows both `DT_NEEDED` and
PS5 needed-module declarations, maps the complete reachable graph, and only then
relocates it. Missing files remain firmware/HLE dependencies. The resulting
module list is already in dependency-first initializer order. Optional graph
diagnostics report every unresolved strong import in the node that stops
linking; the `graph-info` tool enables them by default.

`game-run` continues from that verified graph, initializes the native CPU
bridge and enters the title while reporting contained guest faults with the
active initializer, registers, stack words, and relocation context. Its
`--app0 <directory>` option lets a sparse patched executable use the complete
content tree from another directory. Position-dependent executables which
access the PS5 null/low-address window still need address translation or
instruction fixups on Windows, where those pages cannot be identity-mapped.

```zig
const runtime = @import("runtime");

var emu = runtime.Runtime{};
try emu.init(allocator);
defer emu.deinit();

var graph = try emu.loadModuleGraph(io, "game/eboot.bin", .{});
defer graph.deinit();

try emu.enableNativeCpuDispatcher(io);

const initial = try emu.prepareInitialThread("main");
defer emu.releaseInitialThread(initial.handle) catch {};

const result = try emu.dispatchProcess(initial, graph.executable(), .{
    .modules = graph.modules(),
    .entry = .{
        .image_name = "eboot.bin",
        .arguments = &.{"--safe"},
    },
});
std.debug.print("process returned 0x{x}\n", .{result});
```

`enableNativeCpuDispatcher` currently succeeds only on Windows x86-64 with
user-mode FS-base instructions enabled. `dispatchProcess` follows the startup
order executable preinit → dependency-first module init → executable init, with
per-image guards preventing a second initializer run. It then uses
[src/runtime/process.zig](src/runtime/process.zig) to place the PS5 0x20-byte
entry parameter structure and up to three inline `argv` pointers at the top of
the prepared guest stack. The structure address is passed in RDI, the optional
exit handler in RSI, and the native bridge enters with the corresponding AMD64
stack alignment.

`Runtime.init` is intentionally in-place. Libkernel retains a pointer to the
address space, so returning a Runtime value from an initializer could move it
and leave that pointer dangling. Loaded modules or graphs must be destroyed
before the runtime; their `deinit` methods unregister guest/TLS exports and
decommit module pages while leaving the outer guest windows owned until runtime
teardown.

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
