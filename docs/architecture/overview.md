# Architecture and toolchain overview

[← Documentation index](../README.md) · [Project status](../project-status.md)

## Components

Eleven modules cover the independent subsystems and their end-to-end composition:

| Module | What it does |
|---|---|
| **`memory`** | Reserves fixed guest ranges, manages sparse mappings and permissions, and provides opt-in 16 KiB GPU-source page generations |
| **`rdna2`** | Decodes RDNA2 machine code and provides optional CFG/SSA optimization, legalization, and direct IR-to-SPIR-V emission |
| **`gpu`** | Decodes, snapshots, schedules, and executes the stateful part of submitted GPU command streams |
| **`vulkan`** | Owns the host Vulkan device and provides gated timeline scheduling, image-alias coherency, caches, and the renderer boundary |
| **`window`** | Owns the native host window and its platform message loop |
| **`input`** | Reads Sony pads over HID, falls back to XInput, polls the host keyboard, and applies launcher remapping profiles |
| **`loader`** | Reads, maps, and relocates bare ELF64 and decrypted PS5 SELF module images |
| **`hle`** | High-level emulation of guest firmware, files, saved games, memory, synchronization, media, network, and platform services |
| **`cpu`** | Dispatches guest execution and provides the Windows x86-64 native machine bridge |
| **`diag`** | Attributes guest addresses to modules and explains contained faults |
| **`runtime`** | Composes memory, loader, HLE, and the optional CPU execution path |

A build defaults to `ReleaseSafe` rather than `Debug`. An emulator interprets
guest instructions, translates guest shaders and converts guest pixels once per
frame, so an unoptimized build is not a slower version of the same program but
one that cannot keep up: converting a single movie frame costs six times more
under `Debug`, and a title's startup measured 7.7 seconds against 2.1. Safety
checks are kept, because everything here reads data the emulator did not
produce and a checked failure explains far more than undefined behaviour.
`-Doptimize=Debug` selects the unoptimized build when a debugger needs it, and
`-Doptimize=ReleaseFast` drops the checks for roughly another six per cent.

None of them depends on anything beyond the Zig standard library. The tooling
cross-compiles to Windows, Linux, and macOS. Direct guest execution currently
requires Windows x86-64; the other targets still build the inspection and HLE
layers but report the native bridge as unsupported.

The repository includes these command-line tools and hardware probes:

```sh
zig build run         -- shader.bin    # disassemble a shader
zig build module-info -- eboot.bin     # inspect a bare ELF or decrypted PS5 SELF
zig build module-info -- eboot.bin sce_module/libc.prx # include a guest provider
zig build module-info -- eboot.bin --names names.txt   # recover published names
zig build pm4-dump    -- capture.bin   # decode a captured GPU command stream
zig build graph-info  -- eboot.bin     # map and relocate the reachable PRX graph
zig build game-run    -- eboot.bin     # load, initialize, and enter the title
zig build game-run    -- --app0 full/game patched/eboot.bin # use full content with a patched executable
zig build build-launcher               # install only the native Windows launcher
zig build launcher                      # open the native Windows launcher
zig build vulkan-smoke                 # run the headless compute/graphics probe
zig build vulkan-smoke -- --probe-spv out/compute-0xADDRESS.spv # compile a saved compute module
zig build vulkan-window-smoke          # present a diagnostic frame through a Win32 swapchain
```

On Windows, `game-run` now creates a Vulkan VideoOut window by default and
attaches the live AGC command queues before entering guest code. Set
`PS5_HEADLESS=1` to keep loader/CPU diagnostics windowless. A missing Vulkan
loader, compatible presentation device, or host window is reported and the
title continues through the previous headless path.

`game-run` keeps command-line parsing in the process startup arena but gives
the runtime and renderer `std.heap.smp_allocator`. Unlike an arena, this
allocator returns superseded frame, staging, shader, and container allocations
when their normal `free` paths run; long asset-loading sessions therefore do
not retain every historical temporary buffer until process exit.

If the process bootstrap returns after handing work to guest pthreads,
`game-run` reports their names and entry points rather than treating the return
as an immediate process exit. The window and runtime remain alive while a
non-audio guest worker is still running; audio-only leftovers do not keep a
finished title open forever.

The recommended Windows entry point is `zig-out\bin\ps5pcem.exe` (or
`zig build launcher`). The launcher remembers up to eight recently selected
game directories, reads each title from `sce_sys/param.json`, and uses
`sce_sys/icon0.png` as its library cover. Hovering a card reveals a small remove
button which forgets only that library entry; installed content and saves are
never deleted. It also persists sound state,
FPS-counter preference, input mode, keyboard bindings, and interface language
in `ps5pcem.ini` next to the executable. English is the default; Russian,
German, and French are available from Settings. It looks for `eboot.bin` in the
selected directory and its common `decrypted` subdirectory, then starts the
sibling `game-run.exe` with the full content directory mounted as `/app0`.
`zig build launcher` installs only the launcher and `game-run` dependencies
before starting the installed executable; it does not rebuild unrelated tools.
The optional counter updates the measured guest flip rate once per second in
the Vulkan game-window title. Direct command-line runs can enable it with
`PS5_SHOW_FPS=1`.

Input profiles can use a controller, a remappable keyboard profile, or both at
once. A DualSense or DualShock 4 is read straight from HID over either USB or
Bluetooth and takes precedence; XInput remains the path for Xbox-compatible
pads and for anything presenting itself as one. WASD controls the left stick;
Alt plus the arrow keys controls the right stick. The launcher passes these preferences through
`PS5_INPUT_MODE`, `PS5_CONTROLLER_INDEX`, `PS5_KEYMAP`, `PS5_SHOW_FPS`, and
`PS5_AUDIO_DISABLED`, so direct CLI and automated runs keep their previous
behaviour unless those variables are set.

Saved games are kept at the emulator home in `savedata/<titleId>/<slot>/`, keyed
by the product code the title publishes about itself. That is deliberate: a
title's installation is read-only, can sit on removable media and is replaced
wholesale when it is patched, so a save must outlive all three, and keying by
the published identifier means two dumps of the same game share their saves
while two different games never do. The slot name comes from the guest, so it is
sanitized before it becomes a directory: separators, the drive colon and parent
links become underscores rather than being dropped, since dropping them would
let two distinct names collapse onto one and overwrite each other's saves. A
name that cannot be a directory at all falls back to a fixed one instead of
failing the mount, because losing the save is worse than putting it somewhere
predictable.

Development launchers under `zig-out/bin` resolve emulator home back to the
repository root, while a packaged launcher uses its own directory. Direct CLI
and launcher starts therefore share one save, log, and cache root. The Saves
page scans every title directory and groups the visible slots by title ID,
rather than appearing empty merely because a different library tile is selected.

A mount resolves the slot and points `/savedata0` at it; the title's own files
are then written through the ordinary file API. Mounting a slot that does not
exist reports it missing unless the title asked for one to be created, because a
title probing for a save it never wrote expects to be told so rather than handed
an empty one. Everything a title ships stays read-only; the save mount is the
one place writing is allowed. The block-shaped save API is backed by a separate
per-title blob under `sce_sdmemory`, loaded when the title reserves it and
written when the title asks for it to be synchronized.

Reading a save back matters as much as writing one. A title asks whether its
save exists before it opens it, and that question is answered by the metadata
path rather than by opening the file, so a save mount that resolved only opens
against its own root still reported every save missing. Jets 'n' Guns 2 showed
this exactly: it rewrote its profile from scratch on every run instead of
loading it, because each existence check said the file was not there. Listing
the slots a title has written is answered too, since a title does not know which
of its saves exist and has no other way to find out, and a mount reports whether
it opened an existing save or made a new one — always claiming the latter has a
title treat its own progress as absent.

XInput cannot enumerate Sony's controllers at all: it reports only
Xbox-compatible devices, so a pad plugged straight into the host is invisible to
it and appears connected only when a translation layer puts a virtual Xbox pad
in front of it. The input module therefore opens the device over HID and decodes
its reports. Both the DualSense (including the Edge revision) and the
DualShock 4 are covered, over USB and over Bluetooth: the fields are the same in
every form and only their offsets move, because Bluetooth prefixes the payload
and the DualSense carries its triggers ahead of the button bytes. The
directional pad arrives as one of eight compass positions rather than four
independent bits. Reads are overlapped and never block; a poll drains the
driver's queue and keeps the newest report, because the queue holds several
samples once a frame runs long and answering with the oldest would make the
sticks lag by however far behind the emulator had fallen.

The same path drives the pad. Output reports carry both motors and the light
bar, and over Bluetooth they are shifted along and end in a checksum the pad
verifies before acting, so a report built for the cable is ignored over the air.
The launcher's input page reports which pad it found and offers a one-second
test that runs both motors while sweeping the light bar through its colours; the
button mirrors the colour it is currently showing, so a pad that rumbles but
never lights up is visible without watching the hardware. The device is opened
shared and for writing where the host allows it, falling back to reading only
when another process already holds it for output.

Graphics bring-up runs can set `PS5_CAPTURE_FIRST_FRAME=1` to write the first
submitted guest draw to `out\first-frame.ppm`. `PS5_PROBE_FRAGMENT_COLOR=1`
replaces the guest fragment shader with a fixed-color diagnostic, and
`PS5_SKIP_COMPUTE=1` skips guest compute dispatches to shorten pipeline tests.
`PS5_COMPUTE_TRANSLATE_ONLY=1` goes further through resource recovery and SPIR-V
translation but stops before Vulkan pipeline creation and dispatch. It is useful
for separating translation/binding failures from GPU execution faults.
`PS5_DUMP_COMPUTE_SPIRV=1` saves newly translated compute modules under `out`,
where `vulkan-smoke --probe-spv` can compile one in a clean Vulkan session.
`PS5_VULKAN_PREFER_INTEGRATED=1` selects an integrated adapter ahead of a
discrete GPU on multi-adapter systems, which is useful for separating a
vendor-driver failure from guest shader translation.
`PS5_TRACE_GRAPHICS_FRAME=<flip>` performs an expensive readback and writes a
PPM after every draw of one selected frame; it is opt-in because a dense 4K
frame can otherwise transfer several GiB and appear to freeze the title. These
diagnostic switches deliberately change rendering or timing and are not
compatibility or correctness modes.

`PS5_CPU_WAIT_DIAGNOSTICS=1` restores the verbose repeated-wait, futex-churn,
and scheduler-watchdog reports used during CPU synchronization debugging. They
are disabled during normal play because several parked engine workers printing
to the same console can themselves introduce frame and audio stalls.

New GPU architecture paths are independently gated for title A/B testing. They
are disabled in ordinary `game-run` launches; the startup log prints every
effective value so a captured report is self-describing:

| Variable | Experimental path |
|---|---|
| `PS5_GPU_SHADER_IR=1` | typed RDNA2 IR as the executable SPIR-V input |
| `PS5_GPU_SSA=1` | SSA construction, constant folding, and shader DCE |
| `PS5_GPU_ASYNC_PIPELINES=1` | FIFO worker for first-use pipeline compilation |
| `PS5_GPU_CANONICAL_ALIASES=1` | shared generations and canonical writers for overlapping image caches |
| `PS5_GPU_DEPTH_TRANSFER=1` | single-sample guest depth/stencil import and writeback |
| `PS5_GPU_IMAGE_STATE_OPT=1` | read-only barrier elision and compatible aspect merging |
| `PS5_GPU_TIMELINE_SCHEDULER=1` | multiple in-flight submissions retired by timeline tick |
| `PS5_GPU_DEFER_STORAGE_WRITES=1` | GPU-authoritative small compute outputs until an exact CPU consumer |
| `PS5_GPU_PAGE_TRACKER=1` | 16 KiB guest-page generations backed by CPU write faults |
| `PS5_GPU_EXPERIMENTAL=1` | enables all nine paths together |

`PPSA25872` automatically enables the timeline scheduler and deferred small
storage writeback after measured title-specific A/B passes. Set
`PS5_GPU_SYNC_SUBMITS=1` and `PS5_GPU_EAGER_STORAGE_WRITES=1` to force the two
conservative paths when comparing performance or diagnosing a driver issue.

Enable only one variable when isolating a regression, then remove it before the
next run. For example:

```powershell
$env:PS5_CAPTURE_FIRST_FRAME = "1"
$env:PS5_GPU_SSA = "1"
.\zig-out\bin\game-run.exe "X:\path\to\title\eboot.bin"
Remove-Item Env:PS5_GPU_SSA
```

The compatibility run with none of these variables set is the required
baseline. A title-specific result is not promoted to the default until its
captured frame, steady-state frame time, target readback volume, and Vulkan
smoke result all match or improve on that baseline.

For a native optimized build, install Zig 0.16 and use a current Vulkan driver:

```powershell
zig build -Doptimize=ReleaseFast
.\zig-out\bin\game-run.exe "X:\path\to\decrypted-title\eboot.bin"
```

When the decrypted executable is stored separately from the installed content,
pass the content root through `--app0`:

```powershell
.\zig-out\bin\game-run.exe --app0 "X:\path\to\title" `
  "X:\path\to\title\decrypted\eboot.bin"
```

Some Unity titles load native plugins after startup rather than naming them in
the executable's dependency tables. Until live graph extension is available,
`PS5_PRELOAD` maps those PRXs during the safe dependency-first load phase. The
value is a semicolon-separated list of relative paths or unique basenames:

```powershell
$env:PS5_PRELOAD = "plugin-a.prx;plugin-b.prx"
.\zig-out\bin\game-run.exe --app0 "X:\path\to\title" `
  "X:\path\to\title\decrypted\eboot.bin"
```

Preloading does not emulate the device or service behind a plugin; it only
makes the module, its initializer, and its own exported symbols available to
the guest process.

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
