# GPU submission and Yotei performance work, 24 September 2026

This change adds CPU command processors, reduces unnecessary Vulkan waits and
resource copying, and fixes several shader and cache correctness problems.
It does **not** establish 1 FPS or stable late-scene gameplay in Ghost of Yotei.
The last measured tree scene presented 22 ordinary frames in 30.00049 seconds
(0.7333 FPS). Vertical artifacts remained. The subsequent loading sequence
encountered `DeviceLost`; the final defaults retain the legacy Yotei culling
fallback and disable experimental branch-loop lowering.

## Command execution and synchronization

- Two persistent CPU workers interpret graphics and compute PM4, retaining up
  to four owned draw/dispatch snapshots per worker. The submission owner keeps
  all Vulkan and live-memory callbacks ordered. Rejection discards speculative
  work and restores the rejected draw's state. Worker shutdown and backend
  replacement drain outstanding work.
- Immutable command/register snapshots allow preparation ahead of execution;
  GPU-generated indirect streams and synchronization reads remain live and
  ordered. Indirect register lists are copied in blocks rather than one pair
  per callback. Large CPU tile conversions share a bounded copy pool.
- Timeline retirement avoids waiting for unrelated resident buffers. Shader
  fault records can be checked when their submission retires, preserving a
  sticky failure and ordering with subsequent observable work.
- Optional deferred internal releases use a bounded FIFO. Public HLE
  completion drains it before exposing driver labels or interrupts. Releases
  requiring stronger visibility retain the synchronous path.
- Upload-ring slices and optional queued host-buffer replacement preserve
  previous GPU readers while preparing new data. Detile descriptors retire by
  their exact submission tick, preventing premature slot reuse.

These are CPU command processors around one ordered Vulkan owner, not separate
host graphics/compute Vulkan queues. The public HLE execution lock remains.
The native Yotei samples had zero paired graphics/compute batches: preparation
overlapped backend work, but those submissions did not supply two simultaneous
queue heads. This limitation is not a demonstrated native speedup.

## Resources, caches and shaders

- Index active storage buffers and image hazard cells; avoid repeated full
  cache scans. Read-only resident storage images retain GENERAL usage while
  writable aliases preserve producer/consumer barriers.
- Retain bounded storage-buffer ranges, resize oversized recycled allocations,
  collect old clean storage images, and publish dirty contents before reclaiming
  memory. Add configurable sampled-image and translation-cache budgets.
- Share identical immutable graphics shader words. Use dynamic Vulkan viewport
  and scissor state so compatible pipeline variants reuse compilation.
- Cache shader side-effect analysis during fullscreen video; keep compute and
  later scene analyses from being evicted by covered graphics draws.
- Specialize GPU detiling for a bounded set of layouts with a generic fallback.
  Uniform whole-buffer clears can use a correctly ordered Vulkan fill.
- Preserve defined register values at partial CFG joins. Scalarize private
  fragment DS spill slots only after proving their constant addresses across
  the complete CFG.
- Recognize a narrowly proven packed-index fragment minimum reduction and
  replace its fixed READLANE 31/63 combination on 32-lane hosts with subgroup
  unsigned minimum. The recognition includes the real material shader's
  intervening scalar wait and rejects incoming edges and live temporaries.
- Use fragment quad broadcasts for constant-source DPP quad permutations when
  supported. This preserves neighboring helper values used for gradients at
  triangle edges. Other permutations and stages keep their established path.
- Preserve the numeric storage-image class for the observed two-channel 8-bit
  format. Keep sampled-image sRGB behavior separate from storage access.
- Fix opt-in page-tracker query caching: native writes invalidate memoized
  generations through an epoch; unprotected writable pages cannot supply a
  trusted generation until rearmed. Unmapping advances the epoch too.

The quad distinction follows the Vulkan rules for
[quad operations and helper invocations](https://github.khronos.org/Vulkan-Site/spec/latest/chapters/shaders.html)
and the constant/uniform source-index requirement of
[OpGroupNonUniformQuadBroadcast](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html#OpGroupNonUniformQuadBroadcast).

## Defaults and experiments

| Setting | Default / status |
|---|---|
| `PS5_GPU_PARALLEL_COMMANDS` | Enabled in game-run; `0` restores serial decoding |
| Async pipeline compilation / compiler workers | Existing defaults remain enabled / 2 |
| Timeline-based deferred shader fault checks | Enabled with the timeline scheduler |
| CPU copy participants | 4 for Yotei, 1 for other titles; configurable |
| Sampled-image budget | 2048 MiB; configurable from 128 to 8192 MiB |
| Yotei compute / graphics translation limits | 1024 / 512 MiB; other titles 256 / 256 MiB |
| Internal release deferral | Opt-in with `PS5_GPU_DEFER_INTERNAL_RELEASES=1` |
| Queued host storage uploads | Opt-in with `PS5_GPU_QUEUED_HOST_UPLOADS=1` |
| Retained storage-buffer ranges | Opt-in with `PS5_GPU_RETAIN_STORAGE_BUFFERS=1` |
| Device storage, device detile input, nonlocal sampled images | Disabled by default |
| Resident mip-chain assembly | Diagnostic option, disabled |
| Branch-loop lowering | Diagnostic option, disabled; exact block budget retained |
| Original Yotei visibility / GDS culling shaders | Diagnostic options, disabled |
| Guest page tracker | Remains opt-in; native and physical-alias limitations remain |
| GPU timestamps | Disabled; command-buffer spans can overlap and are not exclusive shader times |

Yotei's original GDS culling shader produces depth-filtered packed coordinates.
The legacy CPU fallback produces dense linear indices. Isolated reference
checks validate the GPU algorithm, but its native late-scene stability has not
been established. The fallback is now limited by an exact shader hash as well
as the dispatch shape to avoid substituting unrelated shaders.

## Validation

All builds and tests were run with the native game process closed.

- Memory suite: **20/20**, including HLE/native writes, repeated stores after
  the watch fires, rearming and unmapping.
- Complete GPU, Vulkan and HLE unit suites: passed.
- RDNA2: **251/261**. The ten failures and the reported leak match the recorded
  baseline; no new failures were introduced. The complete suite is not green.
- **24 headless GPU probes**, with Khronos and synchronization validation:
  fragment quad broadcasts, fragment minimum, branch loops, private spills,
  parallel commands, internal releases, deferred FLAT and sampled faults,
  queued/specialized detiling, dynamic viewport/scissor, timestamps, packed
  clears, storage reuse and CPU changes, sampled-storage refresh, descriptor
  reuse, buffer/target coherence, buffer reuse, queued device uploads, buffer
  renaming, device storage, storage sRGB and partial register merges. All passed
  without validation errors.
- The fragment minimum probe covers 60 cases: known minima, different lane
  orders, optional waits, loop-carried inputs and primitive edges. Quad probes
  check four source selectors against three analytic gradients.
- Earlier isolated captured GDS checks covered empty/mixed depth, restored EXEC
  and output offsets, including packed coordinate sets and untouched tails.

The installed executable is rebuilt using `zig build build-game-run -j1`.
The executable and diagnostic archives are generated artifacts, not committed
game content. Architecture details are in
[Command processors](../architecture/command-processors.md).

## Native findings and remaining work

The matching cached material shader in the last native run contained one UMin
reduction and no remaining constant Shuffle 31/63 reads. This verifies that
the reduction correction reached the real shader; it did not remove the tree
artifacts or improve its measured FPS.

At the tree, roughly 5,000 requested texture addresses usually corresponded to
only about eight new uploads. Later loading behaved differently: approximately
6,500 misses/evictions and about 3 GiB of texture uploads per frame showed cache
thrashing. The last two logged frames took 35.95 and 32.89 seconds, with roughly
8 seconds spent waiting for GPU completion. The device was then lost at a
release boundary. A later rejected dispatch names where the error was observed,
not necessarily the command that caused it.

The last native run used the material-minimum correction but preceded the final
quad/page-query changes and restoration of the culling default. It cannot be
used as a native stability test of the final executable. Earlier late-scene
failures occurred both with and without experimental loop lowering, so that
experiment is not a proven cause. The final GPU probes validate small controlled
workloads; they do not establish whole-game compatibility.

Next investigation should isolate the command preceding device loss using
completion tracing/checkpoints, measure late-scene residency and eviction rather
than texture counts alone, and compare the original culling algorithms against
the legacy substitutions. Moving public HLE submission off the caller requires
owned retirement metadata and completion tickets; removing its lock alone is
not sufficient. The 1 FPS late-3D target remains open.
