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
  checked; incompatible aliases retain the fallback. This final addition
  passes native probes but has **not yet been measured in the live game**.

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
