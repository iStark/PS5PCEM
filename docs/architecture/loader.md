# `loader` — guest module images

[← Documentation index](../README.md) · [Project status](../project-status.md)

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
one import means reading three things together. [src/loader/ids.zig](../../src/loader/ids.zig)
decodes the codes — a variable-length encoding, one to three characters by
magnitude, sharing the alphabet used by symbol identifiers.

Declarations are packed into a single 64-bit word: identifier in the top 16
bits, version below it, and a string table offset in the low 32.

## What is parsed

| | |
|---|---|
| [src/loader/self.zig](../../src/loader/self.zig) | PS5 SELF header, segment table, and decrypted-payload validation |
| [src/loader/elf.zig](../../src/loader/elf.zig) | Header and program headers, validation, segment lookup |
| [src/loader/dynamic.zig](../../src/loader/dynamic.zig) | Dynamic entries, module and library declarations, symbol names |
| [src/loader/ids.zig](../../src/loader/ids.zig) | Library and module code encoding |
| [src/loader/symbols.zig](../../src/loader/symbols.zig) | The dynamic symbol table |
| [src/loader/relocations.zig](../../src/loader/relocations.zig) | Relocation entries and their types |
| [src/loader/imports.zig](../../src/loader/imports.zig) | Walks all of the above into a list of imports |
| [src/loader/exports.zig](../../src/loader/exports.zig) | Owns the process-wide registry of mapped guest exports |
| [src/loader/linker.zig](../../src/loader/linker.zig) | Resolves symbols and writes RELA results |
| [src/loader/tls.zig](../../src/loader/tls.zig) | Owns `PT_TLS` templates, module IDs, and static Variant II layout |
| [src/loader/image_loader.zig](../../src/loader/image_loader.zig) | Maps segments, copies bytes, links, and finalizes protections |

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
