# PS5PCEM documentation

This directory contains the detailed user, compatibility, architecture, and
release documentation. The repository [README](../README.md) stays intentionally
short and visual; implementation details live here.

## Start here

| Document | Purpose |
|---|---|
| [Building and command-line usage](getting-started.md) | Build PS5PCEM, run its tools, package Windows releases, or integrate the RDNA2 module |
| [Project status and compatibility](project-status.md) | See the development captures and the measured milestone reached in each observed title |
| [Implementation status](implementation-status.md) | Read what the emulator can do, subsystem by subsystem |
| [Latest release notes](release-notes/v0.3.0-alpha.3.md) | See the changes and requirements for the current prototype |
| [License and legal note](legal.md) | Understand GPL obligations, dependency licensing, and project scope |

## Architecture

| Subsystem | Document |
|---|---|
| Module map, developer tools, launcher/runtime behavior, and build profiles | [Architecture and toolchain overview](architecture/overview.md) |
| RDNA2 instruction decoding, typed IR, CFG/SSA, and SPIR-V | [`rdna2`](architecture/rdna2.md) |
| AGC/PM4 command streams, retained state, scheduling, and execution | [`gpu`](architecture/gpu.md) |
| Host device, resources, synchronization, caches, and presentation | [`vulkan`](architecture/vulkan.md) |
| Fixed guest ranges, sparse mappings, protection, and page tracking | [`memory`](architecture/memory.md) |
| ELF64/SELF parsing, imports, mapping, relocation, and TLS | [`loader`](architecture/loader.md) |
| Firmware interfaces, files, media, savedata, networking, and synchronization | [`hle`](architecture/hle.md) |
| Native x86-64 dispatch, stacks, TLS, and Windows exception handling | [`cpu`](architecture/cpu.md) |
| Address attribution, call tracing, and contained fault reports | [`diag`](architecture/diagnostics.md) |
| End-to-end composition of memory, loader, HLE, CPU, and process startup | [`runtime`](architecture/runtime.md) |

## Releases and media

- [Release notes](release-notes/)
- [Screenshots and captures](images/)
- [GitHub releases](https://github.com/iStark/PS5PCEM/releases)

## Project boundaries

PS5PCEM is experimental and incomplete. Compatibility milestones describe only
the furthest repeatable point observed with legally supplied local content; they
are not general compatibility ratings. No games, firmware, keys, system
libraries, or console software are distributed by this repository.
