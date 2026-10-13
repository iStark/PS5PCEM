# Yōtei renderer follow-up, October 13

This investigation targets the transition from loading and the introductory
scenes to controllable gameplay. The changes below are shared renderer paths,
not replacements for particular game shaders. The measured tree/settings
interval presents 38 frames in 30.001 seconds (1.27 FPS). Character control and
a repeatable frame-rate gain remain unverified. Runs are stopped at the user's
request; bright tree streaks, later rendering defects, expensive first-use
compilation and the earlier traversal stall remain open.

## Reference review

The local AnyPS5 checkout is `4bb2c7f39`, reviewed against the earlier
`04477932167b27525d8c37e69bb9eb7a50048fe4` audit. Its reported shader coverage
counts recognized opcode names: the local progress collector reports 1,166 of
1,166, but this does not establish complete execution semantics or game
compatibility. Explicit image-store, multisample and depth-view limitations
remain in its implementation and development notes.

Useful areas include per-range CPU write stamps, changed-slice depth copies,
clip/cull exports, and pipeline preparation. Its BDA span-load compiler
workaround in `8c04efcfb` applies to a different generated memory-access shape;
it is not a reason to indiscriminately mark our shader helpers `DontInline`.

The local SharpEmu checkout is `2838b25806a3742814d8066a13aa70897adeeef5`.
Its new rendering throughput work includes redundant Vulkan state suppression,
ordered render work and buffer write tracking. The earlier Yōtei/Tsushima
rendering commit `c7bbb09` was reverted by `3f84f59`; it is not treated as a
finished implementation to transplant. The changes here are original Zig
implementations, informed by the reference behavior and verified independently.

## Implemented changes

- Direct vertex and tessellation-evaluation raster paths can emit an extra
  clip distance for an all-zero position. Positive and negative zero are
  recognized; ordinary positions retain a zero clip distance. This is enabled
  only when the device exposes `shaderClipDistance`. Generated rectangle
  geometry remains excluded until its interface propagates this output.
- Graphics pipeline binds, viewport, scissor, depth bias and stencil references
  are recorded only when changed within a command-buffer recording. The cache
  resets when recording begins, including when Vulkan recycles the same handle.
  Per-frame `gpu state` diagnostics count emitted and avoided commands.
- Depth/storage transfers support D32 bits viewed as R32_UINT and native D16
  viewed as R16_UNORM or R16_UINT, in addition to D32/R32_SFLOAT and S8/R8_UINT.
  Transfers stay on the GPU and preserve attachment bits in both directions.
  Widened D16 attachments using a D24/S8 host format are deliberately excluded
  from the raw 16-bit transfer path.
- Sampled array refreshes remember each copied layer's render-target write
  serial. Updating one producer no longer copies unchanged dirty producers
  again. CPU generation changes, ambiguous overlapping producers and an
  already prepared descriptor batch retain the existing rejection checks.
- Host-side scalar descriptor reads intersect pending small GPU producers with
  the existing buffer overlap index. Exact overlap and dirty checks remain in
  place, as does publication order. Hash collisions cannot establish an alias.
  Disabling indexed queries retains the earlier pending-producer scan.

## Native validation

ReleaseSafe native Vulkan checks on the RTX 3070 Ti:

- `--zero-position-clip`: unchanged ordinary triangle pixels, clipping with an
  all-zero or mixed-sign-zero dormant vertex, and restored valid geometry.
- `--dynamic-depth-stencil`: signed and zero depth bias, independent front/back
  stencil references, reversed winding and pipeline reuse, with and without
  persistent depth. Validation reports unused fragment-output warnings for
  depth-only targets, but no validation errors.
- `--depth-storage`: both D32 color formats and both D16 color formats load the
  current plane, observe repeated clears, and write back to the attachment.
  S8 remains independently coherent and guest plane bytes remain unpublished.
- `--sampled-array-refresh`: both submission modes preserve the untouched CPU
  slice and a green GPU slice while another GPU slice changes red to blue.
  Two refreshes copy three layers rather than four, without texture upload or
  CPU readback. Rechecking unchanged producers issues no further layer copies.
- `--deferred-shader-metadata`: GPU-written interior descriptors feed both
  compute and graphics consumers correctly in all four eager/deferred and
  indexed/linear combinations. The contents of 64 other small producers also
  match after publication. In the deferred case, indexed discovery inspects
  one candidate versus 763 with the earlier scan. These are probe counts, not
  a claim of a proportional game speedup. Vulkan validation reports no errors.

The depth and array checks pass with `VK_LAYER_KHRONOS_validation` enabled.
The focused RDNA2 vertex-system-value tests also pass (2/2).

## Baseline and candidate runs

The baseline used the previously installed runner, SHA-256
`184c9d96fb1b325637047652c359bc9c801dd5cc088a812fbbb4467289e844e4`,
running `F:\PPSA26344\eboot.bin` with 1920×1080 output, Speed mode and the
Performance game preference. Internal rendering remains game-controlled.

It reached the bonus notifications, wolf brightness screen, burning-tree
difficulty selection and Standard experience selection. The transition after
the tree showed large block artifacts; the tree had bright vertical streaks
and alternating dark/bright frames. This run was stopped to install the first
candidate. Character control was not verified.

First-use compilation remains expensive: frame 690 records a single compute
pipeline miss taking 22,849 ms. A native thread snapshot shows the rendering
thread waiting for compute compilation, with compiler workers executing in
NVIDIA driver modules. The background queue eventually completed 852/852 jobs
without failure. Frame 1188 took 91,276 ms, including 37,713 ms of graphics and
45,351 ms of compute pipeline compilation; frame 1189 took 49,913 ms, including
46,961 ms of compute compilation. Later recurring frame costs include hundreds
of MiB of uploads and over 100 MiB of readbacks.

The first candidate installed at `zig-out/bin/game-run.exe` had SHA-256
`042B14D65175852D9FB400E78128086FBD3B9814711EA8A2AE2A2ACE94804A99`.
It includes the first four changes above. This candidate reached the wolf
brightness screen, difficulty selection and the transition after the tree.
At frame 1200 it avoids 1,335 dynamic state commands and 258 pipeline
binds. That frame takes 696 ms, with no new pipeline misses, but still uploads
about 456 MiB and reads back about 177 MiB. This is a different scene/time
sample and is not an A/B speed comparison with the baseline.

These are diagnostic observations during loading and build work, not a
controlled gameplay FPS comparison. Zero reported draw/dispatch failures do
not prove all resources or shader semantics are correct; unresolved-resource
counters remain nonzero and require examination in the actual scene.

## Follow-up: shader size and the post-tree stall

The metadata index and sampled-array rejection counters were built in separate
candidates before the next integrated runner. The array counters distinguish
CPU-page changes, pending batches, overlapping buffers/storage/depth images,
producer state and layout mismatches without relaxing coherence checks. Two
2048×2048 ten-layer color arrays account for recurring 80 MiB uploads each;
the reason their resident refresh path rejects reuse is still being measured.

Large snapshot-based shaders now share a bounded address lookup function when
they reference at least 16 memory regions. It retains last-matching-region
selection, overflow checks and nonuniform descriptor indexing. The helper owns
its header loads and does not reference IDs from the caller's function.
Smaller tables retain the existing inline path. A translation option preserves
the inline version for native comparisons.

ReleaseSafe Vulkan validation passes for `--flat-pointers`,
`--unbound-snapshots` and `--bvh-intersections`. The expanded probes compare
inline and shared lookups with 16 regions, including divergent lanes,
overlapping ranges, unaligned loads, pointer relocation, 4 GiB carry, short
buffers and exact missing-memory fault counts.

Retranslating a captured 8,959-instruction shader with 29 regions reproduces the
old module byte for byte. The shared version reduces SPIR-V from 4,790,284 to
3,385,564 bytes (29.3%) and passes `spirv-val --target-env vulkan1.3`.
Standalone cold pipeline creation took 65,779 ms for the shared version and
72,670 ms for the inline version in an initial pair. The inline measurement
overlapped a runner build, so this is not a controlled compiler speed comparison
or a gameplay FPS result. An earlier concurrent game/probe attempt was stopped
because of memory pressure and contributes no timing result.

The first candidate eventually stopped advancing at flip 1558. The immediate
cause was dispatcher exhaustion in compute program `0x8000173b00`: 1,024
unfinished invocations after 65,536 scheduled block visits, with a configured
budget of 4,096 per wave. Its captured control-flow graph has 876 blocks; the
reported block 546 lies in a BVH traversal loop. This set the renderer's fault
flag and caused subsequent release/wait packets to fail with
`GuestMemoryReadFailed`. Both device timelines had retired and both submission
queues were empty while the CPU waited for label 14 to reach 952 (it remained
951). This later pause was no longer shader compilation. The bounded guard
remains enabled; traversal correctness and the required budget need a replay
with actual dispatch inputs. Character control remains unverified.

The integrated candidate installed for the next run has SHA-256
`3BEC20C8D988D9B71F3A47BA0020F181351423ADACB052FF35454C57314A6466`.
It includes the metadata index, array rejection counters and shared snapshot
lookup. It again reaches the wolf brightness screen and burning tree. Early
array refresh rejections are attributed to pending completed-frame writebacks,
not missing page-generation proof. A follow-up accepts
only readbacks whose exact content generation still exists in the matching GPU
target. CPU publication remains pending and unidentified copies still reject.
The native array probe passes with both timeline modes under Vulkan validation:
it materializes a changed layer, rejects missing or mismatched version proof,
and then copies the exact resident version without another texture upload or
readback. This follow-up is not yet included in the installed runner above.

With diagnostic capture enabled for `0x8000173b00`, the next integrated run
completed eight captured invocations through flip 1088 without a flat-memory
or dispatcher fault. Capture forces readback synchronization, so this does not
establish that the earlier stall is fixed. Inputs, outputs, scalar values and
SPIR-V were retained locally for isolated replay.

The first replay attempt exposed an incomplete diagnostic fixture: ordinary
buffer/FLAT captures omit pointer-form SMEM snapshots and spilled LDS. A gap in
descriptor indices was incorrectly assumed to be LDS by the local replay
script. That replay is not valid evidence for traversal correctness or a larger
iteration budget. The renderer capture now records the scalar snapshots,
spilled LDS and exact descriptor ranges explicitly; the script rejects legacy
incomplete fixtures. The guard remains unchanged.

Flip 1087 took 461,204 ms: 566 graphics pipeline misses accounted for 309,960 ms
and 88 compute misses for 123,493 ms. It completed 5,657 draws and 5,375
dispatches, uploaded about 4.37 GiB and read back about 1.17 GiB. One draw was
rejected with `GuestMemoryReadFailed`; no dispatch failure was reported in that
frame. The visible transition went from the close tree view to black. This
first-use frame is not a steady-state FPS measurement.

The run was stopped during the next frame when Windows commit headroom fell
to roughly 1 GiB. The materialized-array follow-up passed its ReleaseSafe
native probe again with `VK_LAYER_KHRONOS_validation`, for both timeline
settings, without reported validation errors. CPU-flipped or alpha-rewritten
readbacks do not receive resident-version proof.

The subsequent integrated runner installed at `zig-out/bin/game-run.exe` has
SHA-256 `94273BDB9ABFCE0E0D9E5AEEB2AF9C3EFB690D0057942FD295A0A1E5105ABE14`.
It includes materialized-array reuse and complete auxiliary compute-buffer
capture. A fresh visible run began at 14:15 local time on October 13; the
transition was investigated, but character control was not reached.

This run measured 38 presented frames in 30.001 seconds (1.27 FPS) during the
tree/settings sequence. Per-layer sampled-array refreshes are exercised in the
game: flip 1440 refreshes four layers, but still uploads 484 MiB and reads back
178 MiB. This is an observed workload, not a controlled speedup claim.

The complete capture records 15 dispatches across flips 1611–1615, with no
reported traversal or missing-memory faults. The run was stopped deliberately
when Windows commit headroom fell below 1 GiB. Two isolated replays (1611/354
and 1615/343) reproduce all 26 and 25 bound buffers respectively byte for byte,
including pointer-form SMEM, spilled LDS and the zero fault record. This
validates those fixtures; capture synchronization can still hide the original
stall. The dispatcher guard has not been relaxed.

## Host-memory follow-up

A further run began at 14:31 with smaller diagnostic cache limits. A 1 GiB
sampled-image limit caused approximately 4,900 evictions and 2 GiB of uploads
per frame, lowering the bonus-screen rate to about 0.3 FPS. Restoring that
process's sampled limit to 2 GiB returned the displayed rate to roughly
1.3–1.5 FPS. The smaller sampled limit is not a recommended default. Storage
images remained at 1536 MiB, compute translations at 512 MiB, graphics
translations at 256 MiB, and compiler concurrency at one for this run.

Read-only cache accounting at flip 768 found 837,711,872 bytes retained by the
16 completed-frame pixel allocations, for only 166,830,080 bytes of current
pixels. A follow-up allocates replacement frames precisely and releases excess
capacity in the slot being overwritten when aggregate capacity exceeds a
512 MiB soft budget and that slot has more than 16 MiB of spare capacity.
It does not evict pending peer frames, force publication, or copy old pixels
into storage that the readback replaces. Allocation failure preserves the old
frame. The targeted ReleaseSafe Vulkan unit tests pass (2/2), including pending
peer preservation and allocation-failure recovery. Its live memory and FPS
effect has not been measured.

Loading also contains batches of guest-memory mappings taking 650–935 ms on
the host. Existing 64 KiB view granularity deliberately avoids a documented
Cat Quest III regression with wider section views; it is not being loosened
based solely on Yōtei's loading time.

The final diagnostic run was stopped deliberately at 14:46 local time as
Windows commit headroom again fell below 1 GiB. It reached the wolf brightness
screen and tree settings and captured another 15 dispatches without a reported
traversal fault. This does not resolve the earlier stall: capture adds explicit
synchronization, and no controllable gameplay was established. Smaller cache
limits were local diagnostic settings; normal game defaults are unchanged.

## Published checkpoint

The final ReleaseFast runner and matching PDB are installed in `zig-out/bin`.
Runner SHA-256:
`A543449039D98B75FE92AF04BB2B9E049E5B7C1BEB651757FA74D5DEE8861087`.
The integrated build passes all nine build steps and includes the completed-frame
capacity change. The ReleaseSafe native probe build also passes. Its final
`--sampled-array-refresh` check passes in both timeline modes with
`VK_LAYER_KHRONOS_validation`, without reported validation errors, after the
capacity change. The focused capacity unit tests pass 2/2 and all modified Zig
sources pass `zig fmt --check`.

No further game was launched after the request to stop. The final memory change
has build, unit and native integration coverage, but no new in-game measurement.
The website's dated development entry and current overview are updated in all
eight languages; this checkpoint is not assigned a release version.
