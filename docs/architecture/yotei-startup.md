# Ghost of Yotei startup investigation

Verified with PPSA26344 and the RTX 3070 Ti on 2026-09-06.

## Reproduce

```powershell
zig build build-game-run -Doptimize=ReleaseFast
.\zig-out\bin\game-run.exe "F:\PPSA26344\eboot.bin"
```

The intro decodes 582 pictures. Media Foundation reports a frame interval of
33,366,666 ns; normal movie render frames measure approximately 30–32 ms.
Vulkan SDK 1.4.357.0 validation completed an 85-second run, including the
transition out of the movie, without VUID reports.

## Resource catalog transition

Guest breakpoints identified a filesystem blocker after the intro. The startup
task advances through states 3 (movie), 7 and 8, then queues the scene loader.
That loader immediately moves from state 1 to terminal state 42: its catalog
is empty, so it rejects `game.sprig` before requesting the scene resources.

The catalog reader stats `cache_ps5/load_menu_catalog.log` (11,954 bytes),
combines `st_mtim` into nanoseconds and compares it against its cached value.
The filesystem previously returned zero timestamps, matching the initial zero
cache value and skipping the first read. `stat` and `fstat` now preserve host
access, modification and status-change times, including fractional seconds.
The filesystem test suite passes all 39 tests.

With timestamps fixed, the catalog contains three entries and the loader
reaches state 9, then starts the shared resource packages, including
`core_common_subcore.core_d0_ui.sprig.xpps` and
`core_common_subcore.core_b1_fx.sprig.xpps`. The APR worker also requests fire
textures. This exposed a second blocker: the fixed 256-entry APR ID table
rejected subsequent paths with `FileTableFull`.

APR IDs now use a growing table and a case-insensitive path index. The separate
64-descriptor cache remains bounded. All seven APR tests pass, including
resolving and reading 600 files, retaining earlier IDs across table growth and
resetting the table between processes.

The combined loading fixes advance the loader to state 24 and resolve more
than 560 unique files, including notification UI and title-stamp textures.
This exposed a separate Vulkan buffer-cache failure when the new scene
started submitting its compute work, investigated below.

Two GPU correctness fixes accompany the loading changes:

- Conservative image tracking now combines matching depth/stencil aspect
  barriers. The device does not enable `separateDepthStencilLayouts`, so
  splitting these barriers caused validation error `image-03320`. All five
  image-state tests pass, including the conservative-mode regression.
- Compute staging waits for prior readers before overwriting a clean cached
  buffer, including when page tracking is off. `gpu_dirty` only describes
  writes and cannot establish that a buffer is no longer being read.
  `vulkan-smoke --buffer-reuse` queues an actual GPU copy before changing its
  input. Without the fix it reads the replacement value `0xaabbccdd`; with
  the fix it retains `0x11223344`, for both exact-address reuse and recycling.

The full Vulkan smoke probe initially failed at `InvalidGuestGraphicsFrame`,
also with the compute-buffer fix removed. Its synthetic graphics setup had
color mode disabled and read VertexIndex from `v0`, while the Prospero graphics
path supplies it in `v5`. Correcting both fixture settings restores the test.
The full probe now passes, including 1,152 colored pixels in the guest target,
texture sampling, storage-image writes, PM4 synchronization and presentation.
The separate buffer-reuse and array-image probes also pass on the RTX 3070 Ti.
Both the full and array-image probes also pass with the SDK 1.4.357.0
Khronos validation layer loaded, without VUID reports. The machine's layer
registry still points to an old `C:\VulkanSDK` location; the test temporarily
registered the supplied `E:\VulkanSDK` manifest and restored the registry
afterward.

## Compute descriptor lifetime and bounds

With `PS5_DUMP_COMPUTE_SPIRV=1` and `PS5_GPU_SYNC_SUBMITS=1`, each diagnostic
compute completion flushes and waits for that dispatch. The device loss
followed the second `0x80003e9600` dispatch, a 129-instruction sorting kernel
with one 64-lane workgroup. Its emitted SPIR-V passes SDK validation, and
isolated replays with synthetic inputs complete. Capturing the actual
dispatch exposed a missing input allocation before the shader even ran.

A cache hit can bind an existing allocation at a different descriptor slot
without changing its original slot preference in the allocation cache.
Rebinding that original slot then recycled the allocation still bound as
another input of the current dispatch. Waiting for previous submissions
cannot protect bindings for work that has not yet been recorded.

The renderer now tracks storage-buffer bindings in the current descriptor
batch. Both slot-based recycling and LRU eviction exclude allocations still
bound at another slot. A fresh descriptor batch clears these pins; existing
timeline retirement and overwrite waits protect previous submissions.

Recycled allocations also publish the requested guest range as their Vulkan
descriptor range. Publishing the backing allocation's larger capacity made
`OpArrayLength` bounds checks accept stale bytes outside the guest range.

The GPU buffer-reuse probe now covers descriptor migration, all 64 cache
entries being bound while one slot grows, and a 64-byte allocation reused
for a 16-byte input. Before the fixes, migration reads `0xdeadbeef` instead
of `0x12345678`, and the out-of-bounds load reads stale data instead of zero.
All five scenarios pass after the fixes.

A normal launch with these fixes passed the former device-loss point and
reached loader state 29 with 964 unique APR files. The next stall was on the
CPU: the main thread waited for jobs at `0xdd2942`, while the compute-event
thread spun at `0x11565a2`, expecting generation 38 at `0x20000001e0` after
only 37 compute completions.

The log records an EOP carrying a frame number into `0x2000000200`, followed
by notification of compute registration `0x52`. Routing notifications only
to their originating queue fixes the generic release fan-out, but did not
resolve this particular stall: the release was part of a compute submission.
Its packet counter and its queue's retirement generation are independent.
The retirement bridge rejected a completed queue generation of 57 because
the packet contained frame number 720. Once the shared label table and queue
owner are validated, retirement now uses the queue's own generation without
ordering it against the packet's counter. Initial table discovery still
requires matching counters; queue identity and monotonic retirement checks
remain enforced.

Release notifications carry the originating submission's event identifier
separately from the packet payload. Graphics uses identifier zero; named
compute submissions retain the owner supplied to `SubmitAcb`. The scheduler
retains each submission's backend context across waits and queue resumes.
Regression coverage includes delivery isolation, preservation of context
after a blocked wait, and retiring queue generation 57 while preserving the
packet label's independent value of 720.

## Array texture processing

The scene also reaches a compute kernel at `0x80002c4500` that reads BC
texture arrays and later reuses the same descriptor SGPRs for storage-image
outputs. Array `IMAGE_LOAD` now supports both storage reads and sampled
fetches. A compressed read is resolved at its instruction PC, independently
of later stores through the same SGPRs. An exact sampled mapping takes
precedence over a generic storage mapping from a later instruction.

The Vulkan image probe copies the green second layer of a two-layer BC1
texture into an RGBA8 storage array after replacing its descriptor in the
same SGPRs. It verifies the green output and untouched first layer, alongside
the existing storage-copy and compute-sampling probes.

Array `IMAGE_GATHER4_LZ`, reached by scene kernel `0x80002e1b00`, now
preserves the layer coordinate in fragment gathers and the existing compute
fallback using four explicit level-zero samples. The GPU probe gathers the
green channel from layer one and checks all four values. The five gather
translator tests pass; the compute fallback remains an approximation of the
hardware gather footprint and filtering.

Resource-state evaluation also continues past unavailable scalar loads,
invalidating their destinations and allowing independent later descriptor
loads to recover. Strict prefix evaluation still stops on the failed load.
SMEM pointers and 64-bit moves can use the VCC register pair, and resource
checkpoints support up to 16,384 instructions. All 56 scalar-provenance and
imported tests pass, including stale-register invalidation, descriptor
recovery, a late checkpoint after 4,200 NOPs and a pointer moved into VCC.

A live replay of `0x80002c4500` exposed a further problem: three nested
lane-dependent loops repeatedly execute the scalar descriptor load at
`0x908`. Because the scalar evaluator cannot advance their VGPR counters,
it reaches its instruction limit and never observes the later output T#.
For a backward unconditional branch whose loop has a forward EXEC/VCC exit,
resource evaluation now retains one iteration's checkpoints, invalidates
loop-carried scalar destinations and continues beyond the back edge. Known
scalar-controlled loops retain their normal evaluation. The added regression
checks nested loops, unknown state at their exit, a fresh descriptor after
the loops and a scalar loop that must still execute all three iterations.

With the captured live SRT at `0x2014ae96b0`, evaluation previously stopped
at the 16,384-instruction limit near `0x9a0`. It now reaches program end at
`0x2d6c` after 1,855 instructions and 80 scalar loads. The store at `0x14d8`
correctly resolves an RGBA16F array at `0x50cb3d0000`, matching the actual
descriptor at SRT offset 484, instead of an earlier BC7 input. The output
enable flag at SRT offset 472 is one in this capture.

The nested-loop regression and imported tests pass all 57 cases. Full and
array-image Vulkan probes also pass with the SDK validation layer, without
VUID reports. In-game, the loader reaches state 32 after about 4.5 minutes.
Some variants of `0x80002c4500` still reject the store at `0x14d8`: a second
live SRT at `0x2011ad1cb0` has its output-enable flag set to zero. Evaluation
correctly skips the output-descriptor loads, but resource staging still
visits the inactive store and falls back to an earlier BC7 input. The next
step is to carry proven uniform branch reachability into resource binding
and translation; treating compressed formats as writable images would not
address this case.

The final seven-minute launch reaches flip 703 and about 1,900 resolved
resources without device loss, instruction-limit rejection or a stopped
queue. Late scene frames contain 38 draws and hundreds of dispatches, taking
about eight seconds each. The captured window is still black; menu rendering
and scene performance remain unfinished.

The image-load translator tests pass seven of eight cases. The remaining
`three-coordinate image load follows a two-dimensional storage descriptor`
assertion also fails against the unmodified `54e9c70` source (expected one
SPIR-V type instruction, found two).

With the retirement fix, the game progresses past the job wait and reaches
114 draws, including indexed geometry, at flip 678. Resource loading continues
to 968 unique files. The next stopped ACB contains a valid 4,291-instruction
shader at `0x8052d9d500`; the old headerless decode limit of 4,096 rejected it
before the command stream reached its completion label. The headerless limit
is now 16,384 instructions. Registered shaders retain their exact allocation
bounds. The buffer probe exercises the normal dispatch path with 4,200 NOPs
followed by a load, store and program end, and checks the resulting GPU copy.

A 12-minute run with the lifetime, retirement and shader-size fixes reaches
flip 782 without device loss or an aborted ACB. The scene loader advances
from state 29 with 32 pending requests to state 32 with no pending requests,
and resolves about 1,900 resources, including terrain, vegetation and
building meshes. Late frames issue 38 draws and hundreds of dispatches at
roughly 3–5 seconds per frame. Captured final output is still black; this is
loading and command-execution progress, not a rendered-menu result. This
run preceded the scalar-recovery and array-gather changes above.

The subsequent run with scalar-load recovery and array gathers reaches flip
813 and loader state 35, resolving about 2,780 resources in 12.6 minutes.
It remains free of device loss and queue aborts, but the window is still
black. This capture preceded the nested-loop recovery change. Other observed
gaps include unresolved image descriptors and an array image store with
two enabled channels at PC `0x344`.

A final normal launch still decodes all 582 intro pictures at the original
33.37 ms cadence. Synchronous shader diagnostics are kept opt-in.

## Baseline before the timestamp fix

A five-minute run continues rendering after the movie, at approximately
1.5–1.6 seconds per frame. The guest clears its active movie-controller
pointer, and the renderer resumes the full graph. This is not a decoder
deadlock.

An opt-in trace at flip 600 contains 27 draws and 137 executed compute
dispatches. The captured targets contain clears and post-processing output;
no recognizable menu text or title artwork is present. The final compositor
targets are black. No indexed mesh draws were observed in this frame.

APR resolves the shader archive, English localization, `pulse.sprig`, initial
sound resources and `v_splash_america.bsf`. The observed run never resolves
`ghost_title.xpps`, `ghost_title_0_0_0.xpps` or the common UI resource package.
The next investigation should establish why the guest has not requested the
title scene before changing its rendering passes.

The game also opens an error dialog before the movie with code `0x8002004e`
(unimplemented function). Several network-service stubs return this code;
the exact originating call and its effect on the transition are not yet
established. Error-dialog requests now retain their code and user ID in the
log before the headless implementation acknowledges them.

## Targeted diagnostics

Use `PS5_TRACE=Apr,Ampr,Dialog,PlayGo` to inspect loading and platform state.
`PS5_TRACE_GRAPHICS_FRAME=600` captures one frame's passes under `out`.
Both are expensive diagnostics and should be cleared for timing runs.

Enabling `PS5_GPU_CANONICAL_ALIASES` and `PS5_GPU_DEPTH_TRANSFER` together did
not restore the menu and increased measured frame time to roughly 1.9 seconds.
These remain disabled by default.

Audible game audio remains unverified. Observed ATRAC9 input matches the
title's `silence_5sec.at9` asset and correctly decodes to zero PCM.
