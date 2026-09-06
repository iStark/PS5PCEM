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
visits the inactive store and falls back to an earlier BC7 input. The uniform
output-guard fix below carries proven reachability into resource binding and
translation; treating compressed formats as writable images would not
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

## Uniform output guards

Compute dispatch now proves block-local scalar guards from the current
USER_DATA snapshot and checked scalar loads before staging resources. A
control-flow dataflow pass excludes entry registers written on any incoming
path, including loop backedges. Unknown ALU results, unreadable flags and
unresolved indirect control flow cannot prove a branch. A later register
overwrite with no return path does not invalidate an earlier guard.

Proven branches and unreachable instructions are specialized in an owned,
dispatch-local analysis shared by resource staging and SPIR-V translation.
The decoded shader cache remains reusable when a flag changes. Unknown wave
branches retain both successors; alternate entries into a guarded region
prevent its removal.

The captured `0x80002c4500` shader now removes the store at `0x14d8` when
SRT+472 is zero and retains it when the flag is one, despite the later reuse
of s0 at `0x2bb8`. The Vulkan array-copy probe exercises flags `0, 1, 0, 1`
with the same shader and reused T# registers. A separate unconditional buffer
write proves each dispatch executes; disabled stores preserve the output,
and enabled stores copy the green texel from the compressed array input.

All 59 scalar-provenance and imported unit tests pass. Full Vulkan, buffer
reuse and array-image probes pass on the RTX 3070 Ti with SDK 1.4.357.0's
validation layer loaded, without VUID reports.

The game completes its intro at the original cadence and no longer reports
the inactive `0x14d8` store failure. This launch spends several minutes in
loader state 29 with 32 pending requests, then completes the batch and reaches
state 32 after about nine minutes. Both inspected SDK queue generations have
matching CPU completion labels during that delay. Scene frames reach 55 draw
attempts and hundreds of dispatches, but still take roughly 7–9 seconds and
produce a black window. The final capture at flip 779, after twelve minutes,
remains in state 32; no device loss or aborted queue was observed.

The remaining array-store failures are in **fragment** programs, not an
unsupported two-channel compute store. For example, `0x8038783800` contains an
`image_store` at `0x344` with dmask 3, followed by the color path. The translator
rejects image stores outside compute; graphics translation also does not pass
storage-image mappings, and their descriptor-layout bindings are visible only
to compute. This requires a graphics storage-image implementation (including
lane predicates and resource lifetime), not merely accepting the opcode.

## Fragment storage-image outputs

Fragment translation now receives the prepared storage-image bindings and
emits typed `OpImageWrite` for 2D, 3D and array images. Storage descriptors
are visible to the fragment stage, and draws bind them even when the pixel
shader has no sampled textures or storage buffers. Image stores in both
compute and fragment stages obey the current EXEC predicate.

Graphics keeps its combined vertex/pixel sampled-image table while staging
storage resources. Successful draws publish image writes to the resident
cache and alias tracker. Explicit image dependencies cover repeated writes,
storage reads and later sampling, including GENERAL-to-GENERAL transitions.
Simultaneous color-attachment/storage feedback remains unsupported.

Each prepared storage or sampled binding now owns a separate cache pin.
Retiring an older submission cannot unpin a resource held by the current
pass. Releases also wait for submitted work when the pending command list
is empty; CPU image publishers release their temporary upload pin.

The Vulkan probe writes RG16_UNORM into layer 1 of a two-layer image from a
pixel shader. CMPX enables only the left half; EXEC restoration allows blue
color export on both halves. Consecutive draws reuse the image with different
USER_DATA values, then compute consumers verify the resident result through
both array `image_load` and `image_sample_lz`, before CPU image writeback.
The untouched layer and disabled pixels retain their sentinel values.

Full Vulkan and image-only probes pass on the RTX 3070 Ti with SDK 1.4.357.0's
validation library loaded and synchronization validation enabled, without
VUID or synchronization errors. The cache-retirement regression and all six
image-store translator tests pass.

The game capture now includes a valid fragment SPIR-V module for the original
`0x8038783800` program: its two-channel array store at `0x344` becomes a
predicated `OpImageWrite` to an `Rg8` storage array. Captured variants of this
path also pass SDK `spirv-val --target-env vulkan1.2`.

The final 12-minute run resolves about 2,800 resources and reaches loader
state 35, with no device loss or aborted queue. It reaches 111 draw attempts
in one frame; the last recorded frame is flip 740, with 51 draws and 264
dispatches in 8.47 seconds. All 11 captured fragment programs containing
image writes pass SPIR-V validation. The inspected window at the state-32
transition is still black; a complete menu rendering is not confirmed.

Another observed failure is compute program `0x80003e2c00`, a 134-instruction
shader with an 8x8 local size. Its GDS `ds_add_u32` at `0x2bc` is rejected as
`UnsupportedBufferAddressing`: the generic DS atomic path still requires
workgroup memory. Unresolved image descriptors also remain in other compute
programs. These are separate gaps from fragment storage-image translation.

## Compute resource guards and lane-prefix decoding

Uniform branch pruning now propagates known scalar values through the CFG,
retaining a value at a join only when every incoming path agrees. Unrelated
vector instructions no longer discard loaded uniform flags. Zero-count loops
can therefore skip unbound image operations without rejecting the dispatch.
The separate resource walk can leave a loop with an unresolved scalar exit,
invalidate its scalar writes and recover independent descriptors after it.
`PS5_TRACE_RESOURCE_FAILURES=1` records the instruction, USER_DATA and known
scalar producers when resource staging fails.

Compute DS atomics now support indexed GDS segments and return the old value
for return-form operations. The new GPU probe checks persistent updates across
workgroups, both halves of EXEC, segment/physical bounds and returned values.

The decoder and translator also support byte/short D16 loads, formatted D16
loads and unsigned 16-bit CMPX. Formatted D16 stores currently support identity
channel selection with 16/32-bit float or integer components; other store
conversions remain explicitly unsupported. Byte accesses use the containing
aligned word for bounds checks. Atomic byte masks prevent adjacent halfword
stores by different lanes from losing each other's updates.

A subsequent allocation trace identified a separate decoder error: native
VOP3 opcodes `0x365`/`0x366` are RDNA2 `V_MBCNT_LO/HI_U32_B32`, not the float
minimum/maximum operations assigned these numbers on newer architectures.
See AMD's [RDNA2 ISA reference, section 12.12](https://docs.amd.com/api/khub/documents/Et~wpu9g~Ffl7d9q0QZ~Og/content).
The translator now counts all low-half mask bits for lanes 32–63 and avoids
out-of-range shifts. A GPU probe checks every lane's prefix and uses the
result to select exactly one GDS counter update, including a mask whose only
active lane is 63.

Before this correction, repeated runs exhausted the game's fixed graphics
pool (`0x5000000000..0x50d3400000`) while allocating model output buffers at
`0x114dfc6`. A later allocation at `0x11545dc` returned null and the guest
faulted in `memset`. The trace distinguishes this guest-pool exhaustion from
host Vulkan allocation failure; no pool-size override was added.

GDS/prefix, packed-buffer and full Vulkan probes pass on the RTX 3070 Ti with
SDK 1.4.357.0 validation and synchronization validation enabled. The scalar
tests (24) and native-VOP3 decoder tests (6) pass. The older DS addtid translator
test still fails with `UnsupportedBufferAddressing` on the unchanged baseline.
With the lane-prefix correction, the game passes the old null-allocation
failure, reaches loader state 35 and resolves over 2300 resources. About
112 MiB remains in the graphics pool at the state-32 transition. Indexed draw
uploads now occur, but the inspected state-32 window is still black.

The next observed decoder refusal, `V_CMPX_CLASS_F32` at `0x64d8` in compute
program `0x8052d9d500`, is also implemented. Its original SDWA instruction is
tested on the GPU with positive/negative finite values, zero, subnormals,
infinities and NaNs, including source modifiers and preservation of VCC.
Dynamic descriptor selection in `0x8000333c00` remains unresolved. A complete
menu rendering has not yet been confirmed.

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
