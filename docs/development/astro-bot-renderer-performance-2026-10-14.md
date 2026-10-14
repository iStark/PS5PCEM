# ASTRO BOT renderer performance checkpoint — October 14, 2026

PPSA21564 v1.018, development build, Ryzen 7 7700 and RTX 3070 Ti (8 GiB).
Output is 1920×1080; the game still controls its internal surface dimensions.
Existing shader caches were retained. The 25–30 FPS target is **not reached**.
Rendering defects remain, and controllable gameplay is not established.

## Measurements

The latest warmed title sequence measures approximately **9–10 FPS**. A
20-second interval presented 174 frames (8.70 FPS); subsequent paired
eight-second intervals with native GDS fills enabled measured 9.25–9.75 FPS.
The corresponding disabled intervals measured 8.87–9.37 FPS. Variation is
large enough that this is only a small, tentative improvement. A Windows
notification overlaid this title comparison; it is not a clean presentation
or visual-quality check.

An earlier candidate in the crowd scene presented 46 frames in 10 seconds
(**4.60 FPS**). Short subsequent samples were generally 4.5–4.75 FPS. Shared
register banks reduced copied snapshot bytes from about 4.3 GB to 1.4 GB per
four-second sample without establishing a substantial crowd FPS gain.
These are scene-specific observations, not a sustained gameplay minimum.

## Changes

- Recover soft texture-cache budgets gradually after temporary allocation
  pressure, rather than leaving the cache permanently reduced.
- Update changed storage-buffer chunks, reuse retired compatible native
  allocations, and retain bounded physical-alias publication windows.
- Extend native texture detiling and exact DCC clear handling; preserve
  depth/stencil content epochs and changed image layers.
- Cache proven resource walks and bound repeated scalar-resource analysis.
  Recover PC-relative scalar tables with checked carry propagation. In the
  observed title interval, preparation gaps fell from roughly 392 to 12;
  remaining dynamic BVH reads require runtime handling. This counter is not
  a count of dropped draws, and zero unsupported programs is not proof that
  all graphics are correct.
- Queue up to 64 ordered commands with immutable shared register banks.
  Writes copy changed banks while reads, borrowed data and synchronization
  retain the required ordering and lifetime boundaries.
- Fill immediate GDS ranges on the GPU while preserving CPU/GPU coherence,
  active bindings and unrelated deferred release ordering.
- Initialize matching full 2D color targets directly from resident storage
  images. Layout, format, ownership, pending writes and CPU replacements are
  checked; incompatible aliases retain the fallback. A subsequent title run
  measured 9.15 FPS over 20 seconds but recorded no uses of this exact-layout
  path. It is native-tested, with no demonstrated benefit in this scene.

The investigation compared local sharpemu commit
`2838b25806a3742814d8066a13aa70897adeeef5`, including its command queue and
resource-lifetime approaches. Its reported 55–58 FPS is not a matched local
benchmark and is not claimed for PS5PCEM.

## Validation and remaining work

- ReleaseFast game runner: 9/9 build steps passed.
- GPU Debug tests: 272/272 passed; Vulkan Debug tests: 256/256 passed.
- Native probes pass for GDS synchronization/atomics, buffer recycling,
  exact 2D storage-to-color initialization and layered volume rendering.
  Detiling and physical-alias checks were also exercised during this series.
- The full RDNA2 suite still has the same 10 failures and one leak observed
  in the baseline checkout; this checkpoint does not claim a clean full suite.

CPU resource preparation and synchronous GPU-to-CPU publication remain major
costs. Large writable buffers and storage-image aliases still trigger expensive
readbacks. Further work must remove those transfers without hiding writes,
discarding required shader work or reusing stale resources.

No new screenshot accompanies this performance checkpoint. The compatibility
page retains its explicitly dated October 13 cinematic capture; it is not
evidence of the appearance of this build.

## Follow-up: GDS snapshots and full image overwrites

Small GPU-written GDS counters can now be copied into independent retained
buffers and published in FIFO order when a guest read or completion needs
them. A later GDS reset cannot change an earlier snapshot. The eligibility
check uses actual image ranges, rather than treating every hole between the
first and last image as image memory. Fully overwritten ordinary storage
images can discard their old contents; partial writes, pinned images and
depth/stencil sources retain the existing publication path.

Standalone GDS fills and snapshots can also remain in an open command buffer
until the next consumer or submission boundary. This avoids immediately
submitting each tiny transfer and does not borrow a shader descriptor lease.
Native tests compare batched and immediate transfers, verify an old snapshot
after a newer fill, and check both CPU reads and explicit submission sealing.
CPU-authoritative values and fully retired GPU values use the direct read
path instead of creating another GPU copy. A native test checks the value,
the ready-read counter, and that the submission count does not increase.
If command recording fails before queueing, the unpublished snapshot is
removed safely. An injected `vkEndCommandBuffer` failure verifies cleanup
and a successful retry without leaving an unassigned completion tick.

Candidate 29 presented 193 frames in 20.001 seconds (**9.65 FPS**) after
warm-up. Three 12-second intervals per setting measured:

| Change | Enabled | Disabled |
| --- | --- | --- |
| Deferred GDS snapshots | 8.92–9.67 FPS | 9.25–9.58 FPS |
| Discard fully overwritten storage images | 9.17 FPS | 9.33–9.50 FPS |

Each enabled GDS interval performed roughly 1,600–1,740 snapshots. These
short animated-sequence comparisons establish that the path runs, not a
speedup: the enabled intervals were slightly slower on average. No gameplay
minimum or new visual-quality claim follows from these measurements.

Candidate 30, including standalone transfer batching and an earlier range
rejection before checking depth aliases, presented 191 frames in 20.000
seconds (**9.55 FPS**). It discarded 764 fully overwritten image contents
during that interval. Paired 12-second observations remained 8.83–9.58 FPS;
the sampled frame records contained roughly 247–282 draws and 88 dispatches.
This changing animation workload confounds a simple comparison of those
averages. Vulkan submissions remained approximately 80–81 per frame with
standalone GDS batching enabled or disabled in this scene.

A further comparison alternated all three changes in 22 blocks of 60 frames
across two approximately repeating animation cycles. Enabled: 660 frames in
72.566 seconds (**9.10 FPS**); disabled: 660 frames in 72.951 seconds
(**9.05 FPS**). That difference is too small to establish an FPS improvement.
The enabled run performed 9,900 snapshots and 2,640 image discards, but averaged
80.93 Vulkan submissions per frame versus 70.01 disabled. Subsequent work
therefore targets unnecessary snapshots when GDS is already CPU-readable,
rather than treating every asynchronous copy as an unconditional win.

Candidate 32, including the completed-GDS guard and recording-error cleanup,
presented 184 frames in 20.000 seconds (**9.20 FPS**, flips 1403–1587).
It recorded 2,760 snapshots, 740 full-image discards and no completed-GDS
fast-path hits. The new guard passes its native test but cannot explain any
FPS change in this interval. ReleaseFast runner/smoke builds passed 12/12;
the final Vulkan ReleaseSafe run passed 256/256 tests.

Tracing identified two render-target publications at the same guest address,
960×540 and 1920×1080, totaling 20,736,000 bytes per frame. The incompatible
views still require host publication and texture-layout conversion. This is
a remaining optimization target, not a reason to reuse an image solely by
address or skip its writes.
The live descriptor survey also confirms that the 960×540 R32 storage view
uses tile mode 24 while the R11G11B10 raster source uses mode 27. A mutable
format view alone would address different texels. Eliminating this transfer
requires a real layout conversion, not simply relaxing the alias checks.

Native validation covers 520 queued GDS producers, 270 independent snapshots
crossing the deferred FIFO capacity, intervening CPU byte writes, unrelated
release ordering, and images bracketing—but not overlapping—label memory.
Eight image-overwrite combinations exercise full/partial writes, pending/
retired GPU uses and enabled/disabled discard, including preservation of
untouched pixels on the next GPU write. Vulkan Debug remains 256/256 passed.
The targeted probes report no Vulkan validation errors. Depth probes retain
the existing unused-shader-output warnings.

The window-control helper was unavailable during these follow-up runs. No
fresh screenshot, crowd transition or character-control verification was
possible; the earlier 4.60 FPS crowd result remains a separate observation.
