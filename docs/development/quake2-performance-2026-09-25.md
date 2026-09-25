# Quake II performance investigation, September 25, 2026

Quake II PPSA09477 v1.003, Windows, Ryzen 7 7700, RTX 3070 Ti 8 GiB.
The working tree starts at `eeb17d05bd8e072c474ca10473a936ba57ea221e`.
All native runs use ReleaseFast and controller input without automatic presses.
The game is stopped for builds and tests. Captures and per-run source patches,
executable hashes, environment settings and logs are under
`out/q2-fix-20260925/` (local, not committed).

## Findings and changes

1. The `eeb17d` change made buffer fingerprints available unconditionally.
   Repeated multi-megabyte hashes cost 123–288 ms in the first four sampled
   gameplay frames. Buffer content caching now honors its own option while
   image freshness can still use the guest fingerprint callback.
2. An old storage-image content hash is not evidence that native guest CPU
   writes left the image unchanged. Reuse now requires an actual freshness
   check; reliable page generations retain their fast path.
3. AGC release notifications must be registered before calling a backend
   callback which can complete inline. Reservations now precede callbacks;
   synchronous and rejected reservations are removed, and capacity exhaustion
   cannot silently drop a completion notification.
4. Command-processor waits can project queued immediate 64-bit releases just
   like 32-bit releases, without prematurely publishing the label to the CPU.
   Overlapping release order, half-word reads and unsupported timestamp cases
   retain explicit handling.
5. Full resident RG16F and RGBA8_SNORM clears now use exact GPU encodings.
   Quake previously read back two 1920x1080 targets before overwriting and
   uploading them again: 15.82 MiB in each direction per sampled frame.
   Partial allocations, incompatible metadata/MSAA and exceptional encodings
   keep the raw fallback. Resource tracing now counts actual transfers.
6. SubmitFlip pacing credits time already spent rendering rather than always
   adding another 16.667 ms to a slow frame. Late frames do not create a
   catch-up burst.
7. Native page tracking rejected a delayed write fault after another writer
   had already restored page access. It now retries that case only when both
   the guest mapping and the current host page permit writes. Protection
   violations remain failures.
8. A full retained buffer cache preferred the old descriptor-slot owner over
   its true least-recently-used entry. That evicted hot vertex data while cold
   constants occupied other entries. Retained caches now use LRU selection.
   Buffer page observations are memoized against the native write epoch;
   range, provider, epoch changes and racing writes invalidate the memo.
9. Formatted vertex reads can name an entire multi-megabyte arena while a draw
   consumes only a small prefix. A conservative shader analysis follows MOV
   and CNDMASK to bounded vertex/instance inputs, including EXEC coverage and
   control flow. Draw-dependent limits are never cached with shader proofs.
   Unknown arithmetic, modified operands, stores, inlined fetch programs with
   a different CFG, tessellation and unproven/OOB ranges keep the original
   descriptor. GPU-written index data is published before measuring its range.
   Exact per-draw prefixes regressed performance by multiplying cache entries:
   the `bounded-device` run uploaded 550–1156 MiB in sampled frames. The revised
   policy uses 64 KiB buckets and requires at least a 16-fold range reduction,
   keeping ordinary static arenas on their shared full backing. The revised
   run uploads about 5–22 MiB in the initial gameplay samples.
10. CPU sampling found repeated copies of roughly 50 KiB scalar-evaluation
    structures, including unused load-history entries, during resource setup.
    Evaluators now write into caller-owned storage, reset only live metadata
    and registers, and copy only populated load records when a second state
    is required. Checkpoint preparation borrows reusable scratch storage;
    nested preparations have separate allocations. Decoded instructions are
    visited by reference. Guest memory is still read afresh on every walk.
11. `sceKernelAvailableDirectMemorySize` scanned the whole physical pool in
    16 KiB steps. One gameplay reporting window spent 2.178 s across 61 calls;
    later individual calls cost about 33 ms. Both free-space queries and
    first-fit reservations now skip occupied intervals rather than stepping
    over every page. Reservation order need not be sorted. Searches preserve
    alignment and first-fit/tie ordering, clip incomplete final pages and
    reject overflowing windows. An exhaustive eight-page bitmap comparison
    covers fragmentation, unsorted reservations and varying search windows.

## Measurements

The table uses the first 13 periodic gameplay samples with at least 40 draws.
These are **not identical-frame benchmarks**: demo timing and scene contents
vary, especially after changing presentation pacing. HLE FPS is estimated
over the adjacent reporting windows, not from the fastest window title.

| Build/run | Median frame | Median draws | Median buffer upload | Median fence wait | HLE window FPS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Released 0.3.2 | 143 ms | 150 | 343.7 MiB | 34.125 ms | 6.527 |
| Unfixed eeb HEAD | 355 ms | 149 | 534.2 MiB | 90.346 ms | 2.524 |
| Correctness/cache fixes | 132 ms | 149 | 338.8 MiB | 28.640 ms | 6.849 |
| GPU clears + release projection (`final`) | 106 ms | 149 | 394.0 MiB | 16.766 ms | 8.212 |
| Tracking + fixed LRU/epoch memo | 76 ms | 155 | 134.0 MiB | 12.500 ms | 12.371 |
| Same, 512 MiB device buffers | 99 ms | 175 | 98.2 MiB | 11.419 ms | 11.096 |
| Same, bucketed vertex bounds | 57 ms | 146 | 12.7 MiB | 5.429 ms | 15.739 |
| Same, scalar scratch / default title profile | 60 ms | 152 | 13.9 MiB | 9.837 ms | 14.723 |
| Same, interval-based direct memory searches | 57 ms | 152 | 12.8 MiB | 8.942 ms | 17.520 |

The targeted render-target uploads/readbacks are zero after the clear fix.
Page reuse removes repeated static-world copies; bucketed vertex bounds reduce
model uploads. High FPS in lighter scenes does not establish a stable minimum.
The scalar-scratch run reduces median checkpoint time from 5.574 to 3.545 ms
at a similar number of walked instructions (75,179 versus 75,493). It does
**not** demonstrate a whole-frame FPS gain: median fence waits increased and
NVIDIA clock telemetry varies substantially across the runs. For example,
the latter run frequently reports P5 with 810 MHz memory, whereas earlier
samples include P0 with 9,500 MHz memory. No driver power setting was changed.
The final `interval-default` run reaches gameplay with no automatic input and
no GPU tuning variables. Free-memory queries no longer appear among the 12
most expensive HLE calls in its sampled windows. The first 90 seconds and
initial 13-frame comparison precede native thread sampling, so sampling pauses
do not contaminate those measurements. Captures still show the level, weapon
and enemies. No contained guest faults, host panics or rejected GPU packets
were found in that initial gameplay log.

The final executable was built at 12:43 local time; its SHA-256 is
`44121A9E8327089E2F090EF50C5EC9384D2DFF82D2F1AEC74CACA7E5057AD397`.
The later CPU sample still finds scalar execution, stack probes, copies and
resource setup on the main rendering thread. These and GPU synchronization
remain optimization targets. Samples outside the executable were not resolved
to individual driver/guest functions. Stable 22 FPS in every scene and
120 FPS have **not** been demonstrated.

## Quake defaults

The PPSA09477 title profile enables page tracking, retained storage buffers,
bounded vertex fetches and a 512 MiB device-buffer budget. A normal `game-run`
launch selects these defaults without extra environment variables. Other title
profiles retain their existing defaults. Each option can be overridden with
`PS5_GPU_PAGE_TRACKER`, `PS5_GPU_RETAIN_STORAGE_BUFFERS`,
`PS5_GPU_BOUND_VERTEX_FETCHES` or `PS5_GPU_DEVICE_STORAGE_MIB`; `0` disables
the respective feature. Page-tracker parsing now honors an explicit `0`.

## Validation and limitations

- 984 selected memory/GPU/Vulkan/HLE/CPU tests pass. One earlier run hit the
  existing pad neutral-state test with a physical axis value of 127 instead of
  128; the subsequent run and keyboard-mode verification passed.
- The HLE test process falls from 25 s to 691 ms after interval-based direct
  memory searches (518 previous tests, 520 including the new boundary and
  bitmap-model tests). This is a test-suite measurement, not gameplay FPS.
- Real Vulkan probes pass: storage CPU reuse, buffer content cache, retained
  buffer/view coherence, packed clears and internal release retirement.
- The new bounded-vertex GPU probe compares full and shortened SSBO views
  pixel-for-pixel, with vertex/instance selection and changing base instances.
  Both paths render visible geometry and produce identical images, including
  after the scalar-scratch refactor.
- The tracked gameplay runs after the fault fix did not repeat the contained
  write fault. Captures show a lit world, weapon and NPCs.
- The `workers4` run deliberately traces frame 240. Its forced readbacks make
  that frame and adjacent timing windows unsuitable for performance claims.
- Four copy participants alone did not fix the heavy-scene cost. Moving
  retained buffers to VRAM alone did not establish stable 22 FPS either.
- The entire RDNA2 suite and other games have not been rerun for this change.
  Vulkan probes and conservative fallbacks reduce risk; they do not establish
  universal game compatibility or stable 120 FPS.

## Review of the four optimization commits

- `5b12a1a375fa9145ebc55fb7ea19fc83ce45a083`: resource-key prefilters and
  deduplication are useful; reuse based only on a valid old image hash is not
  safe with native CPU writes and is corrected here.
- `b396357d84e35a2a7d8fe1561a91daabaa528e69`: adds scalar step indexing and
  result caching. The index is useful; the result cache was expensive in this
  workload.
- `73b68a407de3598b928266e6bfddcd97146f3b54`: removes that result cache while
  retaining indexing. Earlier Quake checkpoint measurements improved about
  13%; this does not mean a 13% whole-game FPS improvement.
- `eeb17d05bd8e072c474ca10473a936ba57ea221e`: asynchronous 64-bit releases can
  remove waits, but unconditional buffer fingerprinting regressed this title,
  and inline completion exposed an AGC observer-registration race. Both paths
  are corrected and covered by tests here.
