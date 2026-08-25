# `memory` — guest address space

[← Documentation index](../README.md) · [Project status](../project-status.md)

Guest x86-64 code executes natively and contains absolute addresses. Relocating
the whole process to an arbitrary host allocation is therefore not an option: a
guest address must be the same numeric address in the host process.

[src/memory/root.zig](../../src/memory/root.zig) reserves the native layout before a
module is loaded. The documented inclusive ranges correspond to these half-open
intervals in the implementation:

| Area | Guest range | Size |
|---|---:|---:|
| System managed | `0x00_0004_0000 .. 0x07_FFFF_C000` | just under 32 GiB |
| System reserved | `0x08_0000_0000 .. 0x0F_C000_0000` | 31 GiB |
| Device | `0x0F_E000_0000 .. 0x0F_F000_0000` | 256 MiB |
| User (Windows/Linux) | `0x10_0000_0000 .. 0xFC_0000_0000` | 944 GiB |
| User (macOS) | `0x70_0000_0000 .. 0xFC_0000_0000` | 560 GiB |

These are reservations, not allocations of physical RAM. Pages are committed
in 16 KiB units only when `mapFixed` or `map` creates a guest mapping. `unmap`
decommits those pages while retaining the outer reservation, so the same guest
address cannot be taken by an unrelated host allocation between uses.

Direct memory is different from a private mapping: its physical offset has a
stable identity. [src/memory/backing_store.zig](../../src/memory/backing_store.zig)
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
address. Private and unaligned mappings retain 16 KiB placeholder/view
boundaries. Fully aligned direct-memory mappings use 64 KiB Windows section
views instead, matching the host allocation granularity and avoiding four
separate view/commit operations per group of guest pages. Views are restored
as placeholders and coalesced on unmap, while mapping metadata and protection
remain accurate at 16 KiB guest-page boundaries. A requested mapping that lands
in a host-owned hole fails explicitly. Linux uses
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
