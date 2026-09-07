# Ghost of Yotei startup investigation

Verified with PPSA26344 and the RTX 3070 Ti on 2026-09-06.

## Menu progress on 2026-09-07

The depth/stencil HTILE fix is confirmed in the game. The three bonus notices
clear without retaining rectangles from earlier windows. The brightness
screen renders its wolf, smoky background, text, slider and Cross icon. The
difficulty and experience selection screens also render their labels,
arrows and selection indicators. This does not yet establish the complete
title menu or its animated scene.

The material at `0x8000273400 + 0x1a6c` loads T# descriptors from a table of
1,332 records, each containing three different views. Its unbounded 32-bit
index multiplication can wrap, so conservative enumeration includes all
3,996 descriptors. The former 512-candidate ceiling rejected this material.
The physical image limit is now at most 4,096, bounded by all applicable
native per-stage/per-set limits for the four image banks. PC-specific
mappings have a separate 16,384-entry ceiling.

Sets of at least 64 candidates use an uploaded hash table. The shader probes
until it finds an exact eight-word match, an empty entry or the longest host
insertion chain. Unmatched descriptors retain the existing zero-result
behavior; all descriptor-array accesses use a valid slot. This avoids
generating thousands of comparisons for every sample. Static texture views
share the renderer's resident sampler cache, and the texture cache can retain
two complete maximum-size binding sets.

The 4,096-view GPU regression verifies compute and fragment lookup, different
channel views of the same allocation, reversed table contents, out-of-range
indices and a single shared sampler. Its procedural vertex stage exposed a
separate bug: an empty vertex-buffer list caused a valid single PARAM export
to be replaced by synthetic UVs. Parameter pairing now survives that path;
only the explicit missing-export/video cases select a replacement VS.
The GPU regression passes with SDK 1.4.357.0 validation, and recovery of the
captured material now returns all 3,996 descriptors. Live scene validation
of the large-table and FLAT changes is still pending.

The compute shader at `0x8000316900 + 0x26c` reads six compressed image
descriptors through a scalar counter. Checkpoints correctly invalidate the
changing address, but resource recovery previously treated the table as
unresolved. A bounded zero-based unit recurrence now supplies the candidate
range, including page-spanning SMEM loads. Runtime pointer mappings take
precedence over scalar snapshots so each iteration reads its own descriptor.
Loop headers expanded by guarded memory operations use the structured
dispatcher to keep their back edges valid.

The six-image GPU regression checks every result, table relocation, a page
boundary and a null descriptor. It passes SDK validation, along with scalar
loops/pointers, nested and large image tables, scene FLAT snapshots and the
full headless smoke suite. Analysis of the captured game shader independently
recovers the six-entry bound. Live confirmation of this change is pending.

Two further refusals were reproduced from a running game. The visibility
kernel `0x8000333c00` loads object pointers from 592-byte records, but the
checkpoint at its texture operation no longer contains the original table
V#. Recovery now follows that descriptor's producer at the pointer load.
The captured 244-record table resolves to six objects sharing one depth
texture. The nested-image GPU regression additionally overwrites the table's
SGPR window before sampling and verifies both relocated object tables.

The kernel `0x800037f200` assembles a sampler with `S_BFM_B64` inside a branch
the scalar walk cannot visit. Resource recovery now reconstructs 32/64-bit
bitfield masks from their inputs. Both captured kernels execute one workgroup
with SDK validation and isolated output writes (120,863 and 60,215 SPIR-V
words respectively). These replays verify execution coverage, not complete
scene correctness. The pointer/table, typed-index, large-image, FLAT and full
smoke regressions pass; live integration remains to be checked.

The loading graph also fills all 256 storage-image cache slots while using
only about 752 MiB of its 1,280 MiB byte budget. Many entries hold tiny mip
levels. The count ceiling is now 1,024, with the byte budget and pin/retirement
rules unchanged. The GPU regression retains 320 dirty images without early
guest writeback, then checks all 1,152 writes across eviction pressure. It and
the full smoke suite pass SDK validation. The effect on live frame time has
not yet been measured.

The volume-combination kernels at `0x80003fd600` and `0x8000402100`
use a different loop: the signed comparison precedes the body and its limit
is loaded from root+264. Recovery now proves a zero initial counter, unit
increments and a required true comparison on both entry and every recurrence.
The limit is recovered at that comparison through its reaching definitions;
only a positive, nonwrapping bounded range can become a scalar pointer table.
Shift-and-add coefficient addresses are captured alongside the T# arrays.

All 79 index-analysis tests pass, including rejected counter clobbers,
negative initialization, nonunit increments and a bypassed guard. The SDK
GPU regression varies the memory-loaded limit between 3, 1 and 6, relocates
the texture table, reads distinct coefficients from another page and verifies
the untouched output tail. The existing six-image loop and full smoke also
pass without validation errors. This is regression coverage; integration of
the volume kernels into the game's final scene is still unverified.

A steady menu-transition profile also finds repeated `0xAA` initialization of
2,342,632-byte compute and 2,232,336-byte graphics preparation objects in
ReleaseSafe. Renderer-local pools now retain up to four of each CPU object.
Each preparation resets its counts, slot masks, addresses and fault state;
array elements outside the active prefixes remain unused. Recycling happens
only after the existing image/view/sampler ownership releases. Active loans
remain distinct and renderer teardown frees the pools.

The focused reset/ownership test and SDK storage-reuse, large compute/fragment
tables, scene FLAT and full smoke suites pass. This removes repeated setup
allocation and initialization; the change's live FPS benefit is not yet
measured. Large texture staging, readback and first-use driver compilation
remain separate costs.

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

## Streamed scene resources and AGC shader interfaces

The longer run with the lane-prefix fix resolves 6,042 resource requests and
reaches loader state 40. Its next CPU fault is in the register-table consumer
at `0x1650cc4`: the first entry contains a host return address from an
uninitialized stack array. NID `dbOlWdppb4o` is the interpolant-mapping helper,
not an extension of primitive state. It now initializes all 32
`SPI_PS_INPUT_CNTL` pairs and matches PS input semantics against GS exports,
including defaults, flat/custom shading and packed half attributes. The
captured failing pair has six matched semantics, with input 5 flat shaded.

A ReleaseSafe run also exposes byte-packed shader headers (for example,
`0x801e975691`). Shader creation, program-register patching and fusion read
these fields without native alignment assumptions. Regression tests cover
the captured semantic pattern, unmatched/default inputs and odd-address
headers with odd-address register tables.

Sampled textures loaded from an indexed scalar-buffer descriptor table can
now bind a bounded set of candidate views. The translated shader compares
all eight runtime T# words and selects the matching Vulkan descriptor, with
the required nonuniform indexing capabilities and decorations. Aliases with
different channel mappings remain distinct. Null/out-of-bounds selections
return zero. Candidate enumeration includes 32-bit multiplication wrap;
unbounded tables and nested pointer-driven image/sampler tables still refuse.

Texture uploads now read the selected mip range rather than requiring every
resource mip to be committed. Smallest-first mip placement preserves the
full resource layer stride; array views copy their selected blocks across
uncommitted gaps. Missing bytes inside a selected mip still fail. The game
previously refused a 4096-square BC3 view at base mip 1 even though its
approximately 5.6 MiB resident prefix was mapped, because it also read the
uncommitted 16 MiB mip 0.

The indirect-image and streamed-mip GPU probes and the full Vulkan smoke pass
on the RTX 3070 Ti with SDK 1.4.357.0 validation and synchronization validation,
without VUID or synchronization errors. All 28 tiling tests and the targeted
AGC tests pass. The new game run passes the packed-header failure and continues
through state 23. Passing state 40 and rendering the menu remain unconfirmed.

## Scene shader validation and scalar spills

The streamed run reaches state 29, then loses the Vulkan device. Newly reached
vertex programs contain unsigned `OpPhi` results with signed ABI input values;
the vertex/instance IDs now enter the register file as unsigned bits. Some
fragment programs consume the same PARAM export through both smooth and flat
attributes. Paired translation assigns each PS attribute a unique Vulkan
location and replicates the corresponding VS export to those locations.

Uniform SGPR spills in `v18` are represented by independent private lane slots.
Ordinary VGPR writes invalidate those slots, and unknown reads keep the subgroup
fallback. Resource analysis also restores known spilled pointer halves before
subsequent scalar loads, forgetting slots after unknown writes or unresolved
loop overwrites. This does not implement general wave64 communication on a
smaller host subgroup.

The shader-header registry previously filled its fixed 8,192-entry table and
silently discarded later scene headers. It now grows dynamically; a regression
test checks all 12,000 mappings, replacement, nearby-entry lookup and reset.

The interface GPU probe checks ABI control-flow merges, smooth/flat aliases,
independent spills and their invalidation. It and the full smoke pass with SDK
1.4.357.0 validation. All 26 scalar-provenance tests pass. The actual game emits
128 valid SPIR-V modules in its next run. A later trace establishes that
`VK_ERROR_DEVICE_LOST` precedes the buffer-lifetime and command-resubmission
validation errors. The timeline query then reports `UINT64_MAX`; treating it
as completion incorrectly retires resources. Device loss is now latched, and
completion values beyond the last submitted tick are rejected. The original
GPU fault still requires investigation.

## Material tables and the end of scene loading

Waiting for each command buffer from frame 675 passes the former device-loss
point at flip 683. This diagnostic run resolves 6,045 APR requests, reaches
loader state 40, clears the loader object and starts producing nonzero audio
PCM. It stops at compute program `0x801f225d00` with `ResourceOutsideSrt`.
No Vulkan validation errors occur during this run; its captured window is
still black. Serial completion changes timing and batching, so this does not
establish the cause of the original GPU fault or confirm a rendered menu.

The captured program and its metadata show that sharp offsets refer to the
logical USER_DATA bank: offsets below 32 select captured hardware registers,
and larger offsets select `(offset - 32) * 4` in extended user data. The SRT
size does not bound those descriptors. The metadata size bit distinguishes
four-word buffers/samplers from eight-word images. Resolution now follows
that layout and checks the corresponding register or EUD bounds. Compute
staging also avoids an eager scan of unused constant-buffer metadata.

Scene material program `0x80002e6d00` guards its record index below 255, spills
it into a VGPR lane, then multiplies the restored index by 368. Resource
analysis follows the guarded value through the spill and CFG before narrowing
candidate descriptor offsets. Ambiguous definitions, bypass paths and
unproven bounds retain the full 32-bit wrapping interpretation. The sampled
descriptor bank grows independently of the storage-buffer bank, up to 512
textures within the Vulkan device limits, with 4,096 instruction mappings.
These per-pass tables are heap allocated: keeping the expanded tables on the
HLE stack overflows it during the first graphics draw in the real game, even
though standalone GPU probes have enough stack space.

BC4 formats 175/176 previously used 16-byte blocks instead of eight-byte
blocks. Both tiling and upload sizing now use eight bytes. The captured
2816-square single-mip allocation requires `0x3c8000` bytes; a 2048-square
12-mip allocation requires `0x2ab000`, matching the game's resident ranges.

The inline-buffer, 128-texture indirect sampling, BC4 UNORM/SNORM, shader
interface and full Vulkan probes pass on the RTX 3070 Ti with SDK 1.4.357.0
validation and synchronization validation, without VUID or synchronization
errors. Metadata and tiling tests cover register/EUD bounds and the captured
BC4 allocation sizes. These checks do not replace the next full game run.

`PS5_TRACE_RESOURCE_FAILURES=1` enables NV GPU fault checkpoints when supported.
`PS5_TRACE_GPU_COMPLETION_FROM_FRAME=N` additionally waits after each command
buffer starting at frame N; it is an expensive diagnostic, disabled by default.
Nested pointer-driven image/sampler tables require runtime pointer loads;
the initial scalar-only specialization cannot resolve them.

A descriptor ownership regression test reproduces reuse after an intermediate
flush in the same pass: the old tick is complete, but a later draw still queues
another use of that set. Queuing now restores its pending reservation. The test
previously selected and cleared the old set; it now selects a free set and
preserves the queued draw's scalar data. The buffer-reuse and full Vulkan probes
also pass with SDK validation. Its relationship to the game device loss is not
yet established.

The next material refusals use VCC_LO/VCC_HI for scalar-buffer byte offsets.
Candidate lookup previously accepted only ordinary SGPR offsets. Translation
also incorrectly applied its reserved MUBUF offset fallback to SMEM, replacing
VCC offsets with zero. Both paths now retain the computed VCC word. GPU probes
cover guarded offsets in ordinary SGPRs and both VCC halves, with distinct
texture selection and out-of-bounds results. Before the fix, the VCC probe
first refused the resource and then, after binding alone was corrected, read
the first texture for every index. The complete fix and full smoke pass with
SDK validation. The captured material shader's 16 guarded multiplications
all retain the proven exclusive bound of 255.

The next asynchronous run completes all 6,045 resource requests, reaches
loader state 40 and clears the loader. It passes the former metadata failure,
but four later compute submissions stop their queues (three
`MemoryReadFailed`, one `UnknownInstructionFamily`). The window remains black.
Four newly reached pixel modules also fail SPIR-V validation because 2D-array
gradients incorrectly include a third component for the layer. Gradients now
exclude that component, as required by the SPIR-V image operands specification.

Compute program `0x8000333c00` loads object pointers from 592-byte records,
then reads T#/S# fields through those pointers. Resource preparation now
discovers those image candidates and snapshots readable object pages into
storage buffers with runtime guest-address headers. Pointer-form SMEM uses
both address halves, carries byte offsets across 32 bits, checks each word
against the captured regions, and returns zero outside them. Addresses stay
in buffer data so relocation does not create another pipeline. Discovery is
bounded by storage capacity and currently requires candidate samplers to agree;
this is not general GPU virtual-address translation.

The nested-image GPU probe verifies different textures, null/OOB pointers and
relocated object pages with a pipeline cache hit. A separate scalar probe
checks loads split across the 4-GiB boundary. Both, the six indirect-image
cases and the full Vulkan smoke pass with SDK validation. A regression test
checks the array-gradient operand dimensions. Full game verification of these
changes is still in progress; menu rendering is not confirmed.

The post-load G-buffer passes mix float outputs with an R32_UINT attachment.
Fragment export declarations and writes now follow each target's numeric
type, preserving raw 32-bit integer payloads and unpacking compressed integer
exports as signed/unsigned halfwords. Storage-only fragment programs no longer
declare an unwritten color output. A four-case GPU probe verifies mixed MRTs,
integer bit patterns which would be NaNs as floats, and signed/unsigned packed
exports through guest-memory readback. It, the shader-interface probe and the
full smoke pass SDK validation without output-type warnings.

The first live nested-pointer attempt still refuses `0x8000333c00`: unbounded
32-bit residue enumeration admits pointers from neighbouring fields, including
texture data that happens to decode as another T#/S# pair. Its actual index
comes from a vector logical shift by 16, selected with FF1 of a saved EXEC mask.
Bounds analysis now proves that the waterfall loop only removes lanes from
the mask which received that vector write. Mask restores/OR, separate writes
to either scalar half and ambiguous vector definitions reject the proof.
The resulting exclusive bound 65,536 rules out multiply overflow and limits
the captured six-record table to its six pointer fields. Replaying the capture
with readable decoy memory fails before this bound and resolves one shared
texture/sampler afterwards. The GPU nested probe also excludes a valid decoy
pointer with a different sampler; existing wrapping and guarded tables pass.

The following material refusal at `0x80002e6d00:0x1e98` uses a VCC_HI
table offset while separately computing another address in VCC_LO. Candidate
analysis now distinguishes those 32-bit scalar writes from vector condition
masks and 64-bit scalar writes. The captured table resolves 51 image candidates
at record offset 128; the high-half GPU probe preserves selection after an
independent low-half add.

GFX10 sample operands follow ISA section 8.2.5: optional offset, bias,
comparison reference and derivatives precede the coordinate body; explicit
LOD follows it. Sample/gather translation now uses that order. Array-only
compute shaders also create their two-component derivative type explicitly:
otherwise a shader with no ordinary 2D binding can emit type ID zero. The GPU
array-gradient probe verifies that the intended array layer is sampled from
distinct derivative/coordinate values. It, streamed-mip sampling, integer MRTs
and the full smoke pass SDK validation.

The repeated scene samples at `0x50bdbb0000` use GFX10 format 24
(RG16_SNORM). Sampled views now use Vulkan's matching normalized signed format,
which was already supported by storage-image and tiling paths. The array
gradient probe additionally verifies a negative RG16_SNORM value by GPU
readback with SDK validation enabled.

Post-load resource recovery also follows the actual reaching definition of
each scalar word through pointer loads, buffer loads and scalar moves. The
captured `0x801f108000` shader reused s4:s5, but its old V# fallback still
treated entry values `0x20, 0x5204` as an address, reading
`0x5204000002a8`. Recovery now follows s0 -> s32 -> s4 instead. Entry words
are accepted only when no shader writer reaches the use; mixed paths and
unknown clobbers remain unresolved. Real inaccessible producers still report
read failures. CPU tests cover nested loads, partial buffer bounds, SGPR-base
mapping and divergent writes; full, indirect, nested and scalar-pointer GPU
probes pass SDK validation.

The pointer run reached loader state 40 before a diagnostic itself panicked:
an indirect candidate in the captured 440-byte record table had format 149
and unnamed tile mode 25. Calling `@tagName` on that non-exhaustive enum
aborted the process before the refusal could be printed. All Vulkan tile-mode
diagnostics now format unknown values numerically, with all 32 encodings
tested. Host panics additionally retain their failing return address when a
guest-created thread has no unwindable host stack. A complete menu render is
still unconfirmed.

The 440-byte material table at `0x801f98cb00:0x1424` now uses the integer
range of its upstream image fetch. The waterfall mask is saved through VCC
before the fetch; analysis verifies that EXEC is unchanged up to that write
and that subsequent iterations only remove lanes. R8/R16 UINT and SINT
formats bound the selected index. Negative signed indices are excluded only
when their wrapped byte addresses provably remain outside the table.
Replaying the saved 31-record table with the R8_SINT source descriptor from
the live scene reduces 274 candidates to nine distinct textures at field
offset 32, stride 440. A GPU probe with unrelated float fields reproduces the
format-149 refusal before the fix and passes all four integer formats after
it, including negative and out-of-range indices. Existing nested and
indirect texture probes remain valid under the SDK layer.

A subsequent validation run stopped at flip 742 with a lost Vulkan device.
The timeline query returned success with `UINT64_MAX`; that defensive path
now reports the queue's fault checkpoints as well. The last unfinished
command carried pixel program `0x800040fb00`, a short texture copy whose
SPIR-V validates. Immediately before it, the full render-target cache
retired a 1024-square attachment during destination preparation.

Resident sampled and storage bindings now pin their color targets until the
draw or dispatch has been recorded. Attachments and intermediate resize
sources use the same protection; submitted commands retain deferred Vulkan
destruction. A baseline GPU setup reproduces eviction of a prepared source
without executing a draw through the invalid descriptor. The new
`vulkan-smoke --target-reuse` probe fills all 64 cache entries, samples the
oldest into four new destinations, verifies red GPU readback and checks
that every preparation pin is released. It passes SDK validation alongside
the existing buffer-reuse, typed-index and full smoke probes. The next game
run passed flip 742 and continued loading more than 5,400 scene resources
without that device loss. Its output still shows a loading indicator on a
black background; the menu has not yet been verified.

The two recurring resource failures in `0x800037f200` have been reproduced
from captured shader code, USER_DATA and resource tables. At PC `0x66c`,
eight-word T# tuples travel through masked VGPR copies before a waterfall
selects them. Resource recovery now follows complete correlated tuples.
Ordinary VGPR writes preserve inactive lanes: a four-lane GPU probe selects
two distinct textures and fails with the former unmasked writes. At PC
`0x970`, unreachable NOP blocks left by branch specialization no longer
contribute spurious reaching definitions.

CPU scalar buffer loads now enforce per-dword V# bounds, matching runtime
loads. Scalar resource recovery rechecks SMEM instead of accepting a matching
but unchecked snapshot. SOFFSET remains a real register even when it overlaps
V#; only NULL disables the offset. Captured replay now resolves both texture
uses, and the GPU scalar-pointer probe checks overlapping SOFFSET and partial
out-of-bounds loads. Vector, nested, typed-index, integer-color, array-gradient,
target-reuse, buffer-reuse and full Vulkan smoke checks pass under SDK validation.
Module tests retain the same nine RDNA2 failures and one executor failure as
the previous commit; the changed resource-analysis tests pass.

Another recurring compute refusal, `0x80001fd400:0x28a8`, references an empty
lighting texture table. Exhaustive table recovery now distinguishes a proven
all-zero source from an unresolved or malformed descriptor. Null samples
produce zero without allocating an image or requiring a sampler. Captured
replay and GPU tests cover empty tables, restoration of real textures and
rejection of malformed nonzero descriptors.

The cache-pinning game run completed 6,042 resources and left loader state 40.
It then refused `0x801eb8de00` and lost the GPU in `0x80001fd400` at flip 912.
Live memory inspection explains the decoder refusal: AGC's low-32-bit alias
lookup redirected shader address `0x801eb96240` to command arena
`0x201eb96240`, returning PM4 word `0xc00e1000` instead of instruction
`0x4130bb96`. Address resolution now checks the complete readable guest VA
before using a compact command-arena alias. A regression test recreates the
collision with two actual mapped pages: the old implementation reads PM4 as
shader code; the fix preserves both reads and writes, while reserved compact
label addresses still resolve correctly. The next full run must also
validate the remaining GPU fault and menu output.

Additional scene material shaders save EXEC with `S_AND_SAVEEXEC_B64` after
their integer image fetch, then restore the saved lanes for a waterfall.
Index analysis now recognizes that pre-narrowing mask. A saved mask taken
before a narrowing fetch remains insufficient. Eight GPU cases cover both
mask-save forms with R8/R16 UINT/SINT inputs. Replaying `0x801f6d5100:0x2c4`
with its captured SMEM values and material table reduces 274 candidates to
nine, excluding unrelated float fields that decode as format 149.

Later loading passes churn the 128-entry storage-image cache while using
only 700–880 MiB of its 1,280 MiB byte budget. CPU sampling attributes much
of the frame time to dirty-image readback, tiling and repeated uploads.
The entry ceiling is now 256, with the same byte budget. When earlier queued
commands pin every eviction candidate, the cache submits and retires that
work before retrying; pins held by the command being prepared remain intact.
The storage-reuse GPU probe retains 160 dirty views and checks all 320 writes
in a larger batch. The previous eviction logic drops writes with
`StorageImageCapacityExceeded` even with the increased entry ceiling.

Three scene compute shaders (`0x8000196500`, `0x80001c0d00` and
`0x80001abb00`) were skipped at their first `V_CMP_EQ_U64`. Their captured
instruction streams also require `V_CMPX_GE_I16` and
`BUFFER_STORE_SHORT_D16_HI`. All three operations now decode and lower;
the store participates in buffer-write tracking and EXEC masking. Captured
replay decodes all 7,768, 7,587 and 7,673 instructions respectively. A 64-lane
GPU probe verifies full-width equality, signed halfword comparison, unchanged
VCC and high-half stores that cross a dword boundary while preserving nearby
bytes and inactive lanes. Decoder tests and packed-buffer/full Vulkan smoke
checks pass under SDK validation.

The next live run reached all 6,042 resources without the AGC address-alias
decode refusal. Its 62 captured material refusals require tracking restored
EXEC across conditional blocks, including snapshots made by SAVEEXEC before
the fetch, READFIRSTLANE and an index held in VCC_HI. Index analysis now proves
the selected lanes received the typed image value before applying its bounds.
It still rejects snapshots which include lanes absent from the fetch. Replay
of all 62 complete captures recovers 9–31 valid textures per field instead of
274 candidates containing unrelated format-149 data. Twenty-eight GPU cases
cover the mask and index-register variants with signed/unsigned R8/R16 inputs;
the index-analysis module and its imported tests pass (72 tests).

The live run still loses the GPU in lighting compute `0x80001fd400` at flip
912 after loading finishes. A separate replay reconstructs its real shader
header, user data and resources; a single workgroup completes, while the
full `1 x 64 x 36` dispatch remains under investigation. Menu output is not
yet verified.

The standalone lighting replay exposed `VUID-vkCmdCopyBufferToImage-pRegions-00171`
for base-only views of texture `0x509e780000`. Detiling produced one visible
layer (1 MiB), but upload commands copied two or three physical layers because
they reused the descriptor's last-slice extent. Uploads now use the staged
view's layer count. The array-gradient GPU probe covers first slices 0, 1 and 2
in RGBA8 and RG16 SNORM; its previous version produces four validation errors,
while the fix preserves the sampled values without those errors. An offline
replay of the complete `1 x 64 x 36` lighting dispatch also completes with clean
SDK validation. Its captured CPU backing data does not reproduce every dirty
resident image from the live frame, so a full game run remains necessary.

Lighting also uses DPP row reductions and PERMLANE permutations. DPP row shifts
previously shuffled in the opposite direction, row rotation did not wrap at
16 lanes, and absolute subgroup indices became invalid for guest lanes 32–63
on a 32-lane host. PERMLANE used a single selector nibble instead of the nibble
for each destination column. These now follow the RDNA2 ISA, including DPP
row/bank write masks, boundary preservation/zeroing and inactive-source fetch
control. Twenty GPU cases check all four guest rows and both halves of the
64-bit permutation selector; the old left-shift case returns 100 instead of
103 in lane zero. The corrected full lighting replay completes with clean SDK
validation.

A further GPU probe confirmed that READLANE 63 returned lane 31's value on the
RTX 3070 Ti. Compute programs which read the upper half of a single 64-thread
workgroup now exchange values through workgroup scratch and retain complete
64-bit comparison/EXEC masks. Scalar EXECZ branches test the whole mask, while
conditional selection and arithmetic carry use the current lane's bit. This
keeps workgroup barriers converged even when only lanes 35–63 are active.
The GPU probe checks two independent groups in both `64 x 1 x 1` and `4 x 4 x 4`
shapes; the complete captured lighting dispatch also finishes with clean SDK
validation (387,667 SPIR-V words). The path is restricted to one guest wave per
workgroup and excludes GDS kernels; other wave configurations still need work.
Focused lane tests retain the pre-existing image-resinfo and DS-addtid failures.

The next full run loads all 6,042 startup resources in about 30 minutes and
continues beyond the former lighting device-loss point. Direct framebuffer
capture at flip 932 shows the Digital Deluxe Bonus notice, with readable text
and an incorrect cross-button glyph. Windows PrintWindow captures were black
and did not represent the Vulkan image. The menu behind the notice remains
unverified. Three scene compute programs refuse nested FLAT addressing.
Their captured dispatch flags are 56: the first collision branch is disabled.
Uniform branch specialization now evaluates `S_BITCMP0/1_B32` and 32-bit
logical operations, including SCC and unknown-operand invalidation. Captured
replays remove 15 of 38 FLAT reads in each program without missing memory;
23 real pointer reads remain and are not replaced by zero. All 68 scalar
provenance/module tests and the 62 captured material resource cases pass.

Pruning can leave compute loops that only read EXEC, without a full-mask
destination. Mutable loop lowering still tests that saved mask, so it needs
lane identity. Inference now accounts for EXEC sources, high-half writes and
implicit SAVEEXEC writes. Without it, a GPU probe silently takes the linear
fallback and returns 1 instead of 4 iterations. The corrected probe returns 4
and preserves inactive upper lanes, with clean SDK validation; the two wave64
workgroup shapes also pass. Strict CPU translation covers all three EXEC forms.

The later scene run with wave64 and scalar bit-guard specialization reaches
the Digital Deluxe Bonus notice again. Warm frames around flips 940–947 take
35–37 seconds; shader compilation is no longer the dominant cost. A main
thread sample attributes 53% of samples to checked guest reads while scanning
mesh indices and another 32% to reading discarded compatibility colour images
after depth-only draws. Those shadow passes read back up to 64 MiB per draw.

Index-range validation now reads bounded 4 KiB blocks, skips draws with no
VertexIndex mappings and checks address overflow before access. CPU tests
cover UINT16/UINT32 block boundaries, signed base vertices, unreadable tails
and empty mappings; 4,097 UINT16 indices require three checked reads.
Depth-only passes retain their depth writes and generations without allocating,
copying or scanning a host colour buffer. The SDK depth probe verifies a
triangle's depth, preservation across a second draw and no colour readback;
the complete Vulkan smoke also passes with clean SDK validation. Live frame
timing with these changes is about 16–18 seconds around the same notice,
down from 35–37 seconds. Draw time falls from about 22 to 4 seconds; compute
resource preparation dominates the remaining frame. This run predates the
permission lookup and compute driver-cache changes below.

Checked memory permissions now start with a binary search in the ordered
mapping table, then visit only the adjacent mappings covered by the request.
All nine memory tests pass, including a byte-level permission oracle over
gaps and boundaries. A controlled ReleaseSafe benchmark with 16,384 mappings
and 32,768 reads near the end of the table drops from 310,264 to 479 us. This
measures the lookup alone, not game frame rate.

Real compute pipeline creation now uses the persisted driver cache. Its
compile job previously passed a null cache in both synchronous and worker
modes, so only graphics pipelines benefited from the saved data. The cache
uses Vulkan's default internal synchronization. The full SDK smoke passes
with an initially empty cache; the standalone compiler-failure probe retains
its intentional cache bypass.

The frame-948 trace stopped in the diagnostic vertex dumper: it requested nine
words from an eight-word checked reader. The dumper now respects that bound.
That incomplete capture includes numerous rejected shadow draws before the
notice's UI passes, so it cannot establish the cross glyph's cause.

A subsequent warm-thread sample spends roughly 40% of samples in the scalar
subresource address function during texture tile/detile copies. Volumes,
mip tails and MSAA copies now cache the local X swizzle contribution and
compute the remaining coordinates once per block row. Element-sized copies
also avoid a variable-length memcpy for every pixel. All 29 tiling tests and
the complete SDK Vulkan smoke pass; scalar-address comparisons cover volume
families, all supported element sizes, mip tails, partial blocks, array
offsets, MSAA samples, untouched padding and short-buffer errors.

A controlled ReleaseSafe benchmark of four tile/detile round trips changes
from 34.3 to 2.4 ms for a 1 MiB volume, 642.0 to 39.9 ms for a 16 MiB volume,
and 735.7 to 41.7 ms for a 16 MiB MSAA image. Output hashes agree. These are
copy timings, not whole-game FPS; a complete live frame still needs measuring.

A partial late-frame trace identifies the cross as a six-vertex font draw
(`VS 0x80003f0e00`, `PS 0x80003dc300`), using the icon atlas rather than the
loading-spinner material. Its packed flags export icon selection in PARAM3.X
and SDF width in PARAM3.Z. `V_INTERP_MOV_F32` incorrectly read its VSRC selector
as the channel, so P0 (selector 2) always loaded Z, including the icon selector.
Translation and graphics interface component discovery now use ATTRCHAN.
The [AMD RDNA 2 ISA](https://docs.amd.com/v/u/en-US/rdna2-shader-instruction-set-architecture)
defines these as separate fields. A decoded P0 GPU probe previously produced
RGBA `{0,0,0,0}` and now produces the expected `{0,127,0,255}`; existing
smooth/flat interface checks and the full Vulkan smoke pass with clean SDK
validation. Live verification of the notice is still pending. After confirming
the old notice with Cross, the captured framebuffer remained black while the
scene continued submitting frames.

The next notice eventually appears (`Gift of the Northern Star Unlocked`),
confirming that the first black interval was also a slow UI transition. This
does not establish the menu background. Captured shadow draws use polygon
offset format `0x1e9` (D32 float, -23), zero clamp and equal front/back bias.
These settings now map to Vulkan depth bias, with the hardware slope divided
by 16 and the constant preserved. Other depth representations, nonzero clamp
and unequal face settings remain rejected. CPU tests exercise both captured
raster modes and three slope values. The SDK GPU probe shifts depth 0.5 to
0.4990234375, retains it across a second draw and avoids colour readback;
the ordinary depth probe and complete Vulkan smoke also pass. This change
still needs validation in the title's scene.

The run with swizzle caching, permission lookup and corrected flat channels
loads all 6,042 resources in 20m13s. The fully visible Digital Deluxe notice
now has the correct complete X glyph. Warm full frames take 13–14 seconds
versus 16–18 seconds previously; an earlier 10.6-second transition frame has
less work and is not the steady-state result. CPU samples now concentrate on
memory copying/clearing and storage-image cache eviction. The 2D-only swizzle
axis experiment did not improve render-target copy timings and was not kept.

The RTX 3070 Ti exposes uncached coherent host memory at type 3 (`0x6`) and
cached coherent memory at type 4 (`0xe`). Buffer allocation previously took
the first compatible type, including for GPU readback. Host-visible transfer
destinations now prefer HOST_CACHED while retaining every required property;
upload-only buffers and devices without a compatible cached type keep their
existing selection. This follows the [Vulkan memory property contract](https://docs.vulkan.org/refpages/latest/refpages/source/VkMemoryPropertyFlagBits.html).
CPU selection tests cover supported-type masks, coherence, device-local
requirements and fallback. Four verified 64 MiB reads of GPU-written data
drop from 508,056 to 21,382 us under SDK validation. This is a readback
benchmark; the additional whole-frame gain is still unmeasured.

Resident compute buffers also need this preference: their CPU readback maps
the storage allocation directly, so they do not carry TRANSFER_DST usage.
Both initial allocation and growth now explicitly prefer HOST_CACHED with
the same required coherent/visible flags and fallback. Write-only storage
upload arenas retain the default policy. Selection tests cover this path;
queued compute readback, descriptor migration, cache recycling and growth,
and the complete Vulkan smoke pass under SDK validation.

Sampling the cached-memory run still finds substantial time in the host
`memset`. Disassembly shows eight separate byte stores per loop in Zig
0.16's fallback; sampled callers include allocation/free poisoning (`0xaa`)
of 23–67 MiB staging and render-target buffers. The Windows x86-64 runner
and Vulkan smoke now supply the C memset symbol with REP STOSB. This retains
ReleaseSafe poisoning and checks, requires no optional CPU instruction set,
and avoids a compiler-generated recursive memset call. Other targets retain
their existing runtime implementation. Tests cover all lengths 0–512 at 64
alignments, signed/truncated fill values, return pointers, null/zero length,
and a 4 MiB fill with sentinel bytes on both sides. Sixteen 64 MiB host fills improve from 117,636 to
34,599 us with the same output hash; the complete SDK Vulkan smoke passes.
This is an isolated memory benchmark, not a measured whole-frame multiplier.

The live runner now reaches the bonus notice with cached transfer/compute
memory and the faster host fill. CPU sampling confirms that calls use the
REP STOSB implementation; the fallback symbol remaining in the binary is not
the sampled fill path. The corrected complete Cross glyph remains visible.
Ten-frame samples around the bonus notice give:

| Build | All 6,042 resource resolutions | Median frame time | FPS over the sample |
| --- | --- | --- | --- |
| `748f6fd`, before cached readback | 20m13s | 13,614 ms | 0.073 |
| `b258af6`, cached transfer and resident storage buffers | 15m45s | 11,242 ms | 0.089 |
| `c237830`, also accelerated host fill | 12m06s | 9,151 ms | 0.108 |

The samples are flips 932–941, 919–928 and 921–930 respectively. Animated
draw counts vary between runs; these are observed scene timings, not a
deterministic replay benchmark. The cached builds also support the captured
D32 depth bias. A ten-second sample of the cached-buffer run uses 11.94% of
the 16 logical CPUs; GPU utilization in two readings is 22–27%, with about
5.1 GiB of GPU memory in use. Frames still upload roughly 1.9 GiB and read
back 1.6 GiB, so host resource preparation remains the major limitation.
Confirmation starts closing the Digital Deluxe notice. Complete title-menu
background rendering is not established by these performance results.

Continuing the same `c237830` run reaches `Gift of the Northern Star Unlocked`
at flip 1001 and `Pre-order Bonus` at flip 1051. Keyboard confirmation is
verified by pad diagnostics (`0x4000` followed by release); pressing before
the notice finishes appearing can be ignored, so confirmation is retried on
the settled notice. All three bonus windows can be dismissed. By flip 1103
the following composite is a dark grey surface with black rectangular UI
artifacts, not a recognizable complete title menu. The deferred UI anchor
is null in this run, so that particular presenter fallback is not retaining
the old notice. Resolving the remaining scene/composite failures is still
required; passing the bonus windows does not establish the 3D background.

The later capture reaches the brightness setup screen, with its instruction,
slider and Cross visible over black rectangular artifacts. A remaining compute
refusal at `0x8000345d00 + 0xb14` is `S_WQM_B32` (`beeb090a`). The decoder,
scalar resource evaluator and SPIR-V translation now expand active four-bit
groups into a single destination word and update SCC, as specified by the
[RDNA 2 ISA](https://docs.amd.com/v/u/en-US/rdna2-shader-instruction-set-architecture).
CPU checks and an SDK GPU probe cover zero and nonzero masks, the captured
VCC high destination, preservation of VCC low, SCC and changing inputs.
The complete SDK smoke also passes. This removes an instruction-level refusal;
its effect on the title scene remains to be verified in the updated runner.

The UI uses reversed depth at `0x505a820000`. A partial trace at flip 934
captures the preceding packed compute fill: all 655,360 bytes of its HTILE
allocation at `0x5060b30000` are zero. DB_DEPTH_SIZE_XY and DB_HTILE_SURFACE
remain at reset, while the recovered depth extent is 3840x2160. The old
metadata expander rejects the missing pipe-alignment state, and resident
depth previously retained earlier UI rectangles across these compute clears.

Complete, uniform depth-only HTILE fills now clear matching resident Vulkan
depth images, including the formatted compute fast path, DMA and direct GPU
writes. Newly created depth attachments also recognize a complete uniform
metadata clear. This narrow case does not depend on individual metadata
swizzle addresses; partial, mixed, stencil and mip/array cases are excluded.
An SDK probe verifies initial metadata, raster depth retained across draws,
repeated zero/one clears, the captured compute kernel, DMA, and partial/mixed
guards. The complete smoke and D32 bias probe pass with clean validation.
The updated title run must establish whether this removes the UI artifacts.

The next live capture showed why the initial resident-clear path did not run:
the UI binds D32 and S8 allocations together, despite disabling stencil in
HTILE. Depth-only metadata clears now accept that packed host attachment,
transition both aspects together and preserve initialized stencil contents.
First use initializes stencil from its clear value, matching ordinary depth
attachment preparation. The SDK probe now exercises both D32 and D32+S8 and
checks that repeated CPU, compute and DMA depth clears retain a distinct
stencil sentinel. It and the complete smoke pass with clean validation.
Live validation of this correction is pending.

The corrected packed-depth path now runs in the title: logs show repeated
zero clears of depth `0x505a820000`, using HTILE `0x5060b30000` at 3840x2160.
The following run finishes all 6042 initial resource resolves and displays
the first bonus notice. Transition and background validation remain pending.

The three visibility kernels at `0x8000196500`, `0x80001c0d00` and
`0x80001abb00` now have a bounded absolute-memory path. Their captured
instruction sites identify a root pointer table, object headers and the
168-byte records described by each header's V#. The backend snapshots these
complete ranges, retaining the guest addresses in SSBO headers. The shader
performs the original pointer arithmetic and reads; an unmapped active read
increments a checked fault counter and fails the dispatch explicitly.
Unrelated shaders retain the existing refusal. Writes, scratch and subword
FLAT operations are outside this snapshot path.

SDK probes cover scalar and vector address forms, signed offsets, overlapping
address/destination registers, unaligned reads, 4-GiB carries, relocation,
exact region bounds and fault counts. An integration probe uses the captured
three-level walk and verifies changed record addresses, count rejection and
unmapped-read rejection. Existing scalar-pointer and complete smoke probes
also pass. Isolated replays use captured state/pages plus read-only access to
the live process for remaining resources, with writes confined to the replay.
This establishes execution coverage, not a synchronized scene replay or a
rendered menu. Live integration and background output remain pending.

The first replay exposed an independent resource-analysis bug: checkpoints
inside a skipped branch inherited SGPR values from another path. In the
64-thread kernel this invented writable V# `0x8000000001`, instead of the
two 600-byte buffers named at root+112 and root+128. Checkpoints now record
only instructions actually visited by the scalar walk; skipped sites remain
unknown for reaching-definition recovery. Backward visits are captured and
loop-varying values are invalidated. Eight focused tests pass. All three
replays then complete with the corrected resource bindings, zero FLAT faults
and clean SDK validation. Scalar pointers, indirect sampled images and the
complete GPU smoke also pass.

The refusals at `0x800033db00 + 0x10cc` and `0x8000227600 + 0xa64`
encode `IMAGE_GATHER4_C_L`, not a level-zero gather. The first captured
instruction uses NSA addresses for reference, X, Y and the computed LOD.
Explicit-LOD gather forms now retain that last operand. Translation queries
the selected mip's extent, samples its four texel centers in gather order,
and applies the sampler's depth comparison to each result. This permits
comparison gathers through the ordinary scalar colour views used by compute.
Point sampling prevents filtering within/between mip levels, including with
fractional sampler LOD bounds. Sampler comparison and LOD limits accompany
direct and indirect graphics/compute bindings.

Eight focused decode/translation checks pass. The SDK GPU probe verifies two
distinct mip patterns, all eight comparison functions, ordinary gathers,
fractional/integer sampler limits, view bounds and a guest linear sampler.
The full smoke and compressed array fetch/gather suite pass with clean
validation. Live scene validation of these newly accepted kernels is pending.

The first cached-memory relaunch stopped before video or Vulkan rendering:
the main thread was suspended in `reportGuestThreadContext(1)`, called by
`drainQuietBuilderArenas` from that same guest thread's suspend point. The
recorded slot-1 thread ID matched the suspended main thread (18820).
Diagnostics now skip their calling thread instead of suspending it before
their own ResumeThread call. The direct self-sampling regression test returns
successfully; this was a diagnostic deadlock, separate from readback memory.

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

Audible game audio remains unverified. Early ATRAC9 input matches the title's
`silence_5sec.at9` asset and correctly decodes to zero PCM; the later run that
finishes scene loading also produces nonzero PCM.
