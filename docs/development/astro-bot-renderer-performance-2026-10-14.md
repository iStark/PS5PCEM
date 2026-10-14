# ASTRO BOT renderer performance checkpoint — October 14, 2026

PPSA21564 v1.018, development build, Ryzen 7 7700 and RTX 3070 Ti (8 GiB).
Output is 1920×1080; the game still controls its internal surface dimensions.
Existing shader caches were retained. The 25–30 FPS target is **not reached**.
Rendering defects remain, and controllable gameplay is not established.

## Follow-up: entry scalar reads (October 15)

Balanced title comparison: **14.92 versus 15.02 FPS**, with approximately 411
buffer preparations avoided per frame. No FPS improvement is established and
25 FPS remains unmet. [Implementation, reference review, capture and validation](astro-bot-entry-scalars-2026-10-15.md).

## Follow-up: AnyPS5 descriptor review

The new warmed title run measures **14.97 FPS** over 660 frames. Scalar
buffer reads now ignore unused vector fields on both host and GPU paths, and
bounded texture records can span multiple scalar loads. The command-interval
comparison retains the 250 µs default. The 25 FPS target and character control
remain unverified. [Implementation, source review, capture, measurements and
test limitations](anyps5-descriptor-review-2026-10-14.md).

## Follow-up: avoid unusable draw capture

The balanced title comparison measures **15.33 versus 15.22 FPS**, with 660
frames per setting across eleven animation phases in one warmed process.
This is a small difference, not evidence that the 25 FPS target is close.
The renderer stops copying and hashing replay data once the existing reuse
rules already prove that a draw cannot be replayed. Image ownership, unsafe
primitive shapes, incomplete reads and specialization retain their previous
rejection rules. Upload bytes and GPU lifetime rules are unchanged.

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| Previous capture behavior | 660 | 43.359 | 15.22 |
| Avoid unusable capture | 660 | 43.045 | 15.33 |
| 512-entry / 128 MiB cache experiment | 660 | 43.860 | 15.05 |
| 64-entry / 32 MiB cache, unchanged default | 660 | 42.384 | 15.57 |

The cache experiment runs separately, after 660 warm-up frames for each limit.
The larger cache retains about 78 MiB rather than 8 MiB, but measures worse
despite slightly more hits. The default remains 64 entries / 32 MiB. Runtime
limits are bounded, and shrinking releases retired entries before further use.

Validation: **553/553 GPU/Vulkan tests**, ReleaseFast build, native transient
storage tests with both timeline modes, and resource-worker/replay probes with
Vulkan synchronization validation. No validation errors were reported. Tests
cover inactive or incomplete capture and GPU reads of all uploaded bytes.

A separate 20-second CPU stack sample still places substantial work in resource
preparation, scalar evaluation, descriptor reads and readback synchronization.
Profiling, builds and tests did not run during the FPS comparison. Results from
separate processes are not release-to-release performance claims.

![ASTRO BOT title after draw capture optimization](../images/astro-bot-title-draw-capture-2026-10-14.png)

Actual game-owned 3840×2160 scanout; host output is 1920×1080. **25 FPS is not reached; gameplay and character control remain unverified.**

## Follow-up: storage ownership and scalar loop budgets

The latest balanced title comparison measures **14.48 FPS**, versus
**14.26 FPS** with the conservative maximum-gap loop-budget proof.
Each setting covers 660 frames distributed across eleven animation phases in
one warmed process. These are title-screen measurements; **25 FPS is not
reached and character control remains unverified**.

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| Conservative maximum-gap loop budget | 660 | 46.280 | 14.26 |
| Exact dense-path instruction budget | 660 | 45.586 | 14.48 |

The scalar interpreter counts vector instructions skipped by its index,
including gaps entered through branches. Only an executed END establishes a
complete dense-path count. Results are shared only within the original dense
instruction budget. Malformed targets saturate the proof; manual or incomplete
proofs retain the conservative bound. The tests accept a 43-instruction loop
at budget 43 and reject it at 42. Cache entries and declined plans distinguish
both proof modes.

Storage images can transfer between incompatible native layouts on the GPU.
The retained tiled backing preserves bytes that become padding in the new view.
Exact allocation ownership, CPU replacement checks, queued uses and overlapping
writers remain part of the decision. Retired views replaced by the CPU no longer
block an otherwise valid transfer. ASTRO BOT uses this path twice per title frame.

Full-image overwrite proofs now cover rectangular workgroups and sampled inputs.
They reject input/output aliases, partial dispatches, masked stores, unknown
coordinates and EXEC changes. Full texel coverage does not cover native padding:
an existing GPU layout transfer therefore takes priority over discarding an
upload when it preserves unpublished bytes. The final path avoids five extra
initial uploads per title frame while retaining both GPU layout conversions.

The separate layout comparison measured:

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| GPU layout conversion, prior overwrite proof | 660 | 44.484 | 14.84 |
| Rectangular overwrite proof before layout transfer | 660 | 45.221 | 14.59 |
| Preserve GPU layout before full overwrite | 660 | 44.571 | 14.81 |
| Same, with draw-resource reuse disabled experimentally | 660 | 43.792 | 15.07 |

The layout ordering avoids the extra CPU round trip introduced by the
initial overwrite experiment, but this comparison does not establish another
material FPS gain. Disabling draw-resource reuse measured a small improvement
in this title; it remains an experiment, not a global default change.
Measurements from separate processes are not release-to-release speed claims.

Descriptor-read capture now searches only potentially overlapping ranges through
a sorted index. Exact duplicates, conflicting overlapping bytes, capacity limits,
reused snapshots and runtime mode changes preserve the original fallback behavior.

Validation: **551/551 GPU/Vulkan tests**, **12/12 ReleaseFast build steps**, and
native scalar-loop, scalar-call, resource-worker, storage-layout and rectangular
overwrite probes with Vulkan synchronization validation. Native layout checks
cover CPU replacement before/after conversion, padding edits, reverse conversion,
partial-overlap fallback, stale retired views and preparation without executing
the promised store. Rectangular checks compare every texel and row-padding byte
with aliased inputs and incomplete dispatches. No validation errors were reported
by these probes; later-scene graphics correctness remains unverified.

![ASTRO BOT title screen after storage ownership changes](../images/astro-bot-title-storage-layouts-2026-10-14.png)

This is an actual capture of the game-owned 3840×2160 scanout. Host output remains
1920×1080. Builds, tests and native probes run outside the FPS comparisons.

## Follow-up: static shader analysis and narrow layouts

The latest balanced title comparison measures **14.25 FPS**, versus
**14.19 FPS** with call-presence and NGG-export analysis reuse disabled.
Every setting below covers 660 frames distributed across eleven animation
phases in the same warmed process. Separate comparisons are not release-to-release
speed claims. These measurements cover the title screen, not character control.
The latest difference is only about 0.5% and does not establish a material FPS gain.

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| Repeated call/NGG analysis | 660 | 46.517 | 14.19 |
| Deferred and retained call-presence analysis | 660 | 46.315 | 14.25 |
| Also retain NGG export inference | 660 | 46.300 | 14.25 |

Static call discovery is deferred until the indirect-jump limit makes it
relevant. Translation reuses call presence only for an exact immutable program.
The NGG cache includes the immutable plan identity, mapped PARAM components and
layered ABI; every draw receives independent output storage. Reconstructed
programs and missing plans retain the original analysis.

The earlier buffer-query change advances through overlap bitsets once and
uses the same index for projected release checks. It retains exact overlap,
live dirty-state checks, cache order and independent iterators:

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| Original overlap iteration and release scan | 660 | 49.844 | 13.24 |
| Sequential overlap iteration | 660 | 49.206 | 13.41 |
| Also index projected release checks | 660 | 48.752 | 13.54 |

GPU layout transforms now cover 8- and 16-bit texels, including odd byte
offsets, odd row widths, mip tails and thick 3D layouts. Disjoint atomic masks
preserve neighboring bytes during narrow writes. The native probes compare
87 detile layouts and 285 inverse/round-trip views against the CPU implementation,
with Vulkan synchronization validation. Storage coherence tests also cover
CPU replacement, padding writes and switching the upload mode.

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| Previous narrow-format fallback | 660 | 46.796 | 14.10 |
| Narrow GPU transforms available | 660 | 46.734 | 14.12 |
| Also enable GPU storage uploads | 660 | 47.484 | 13.90 |

There was no meaningful title gain from narrow-format support in this
sample. GPU storage uploads remain disabled by default because they were slower.
The layout support is retained for compatibility and other workloads.

Bounded semaphore polling uses real `vkWaitSemaphores` calls with timeout zero,
then falls back to a blocking wait. Errors are returned immediately; both time
and iteration limits prevent an unbounded spin. The selected 50-microsecond
budget produced a small improvement in this comparison:

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| Blocking wait | 660 | 46.843 | 14.09 |
| Poll for up to 20 microseconds | 660 | 46.619 | 14.16 |
| Poll for up to 50 microseconds | 660 | 46.215 | 14.28 |
| Poll for up to 100 microseconds | 660 | 46.813 | 14.10 |

The corresponding process CPU totals were 71.281, 68.000, 67.625 and
72.469 CPU-seconds per 660 frames. These totals include all game-run threads;
they are not GPU timings. Polling follows the Vulkan
[semaphore wait contract](https://docs.vulkan.org/refpages/latest/refpages/source/vkWaitSemaphores.html).

Validation: **548/548 GPU/Vulkan tests**, **12/12 ReleaseFast build steps**,
and native scalar-call, resource-worker, distinct-scalar and loop probes.
The general native smoke suite also passes without validation errors after fixing
its manual descriptor-state reset to discard unconsumed staged writes, as the
normal runner already does.
Earlier native checks in this checkpoint also cover deferred/internal release
queues, buffer publication and storage-image coherence. No synchronization
validation errors were reported by these probes.

The title still reports twelve unresolved scalar-buffer resource bindings in
four compute shaders. This counts preparation gaps, not proven executed missing
accesses. No draw/dispatch failures or unsupported compute programs were counted
in the sampled title frames. These observations do not establish correctness
in later scenes.

![ASTRO BOT title screen after static shader analysis changes](../images/astro-bot-title-static-analysis-2026-10-14.png)

This is an actual renderer capture of the game-owned 3840×2160 scanout;
host output remains 1920×1080. Builds, tests, profiling and capture ran outside
FPS comparisons. **25 FPS is not reached; character control and later-scene
correctness remain unverified.**

## Follow-up: scalar analysis and queued completion

The latest warmed title comparison measures **13.79 FPS**, versus
**13.43 FPS** with the three new scalar-analysis optimizations disabled.
Each setting covers 660 frames, distributed across the same eleven animation
phases. These are title-screen results, not gameplay results.

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| Previous scalar analysis | 660 | 49.145 | 13.43 |
| Stop dependency collection after saturation | 660 | 48.457 | 13.62 |
| Also index scalar-value merges | 660 | 48.085 | 13.73 |
| Also retain immutable graphics interfaces | 660 | 47.856 | 13.79 |

The dependency optimization stops collecting an already-complete bit mask;
scalar execution and memory reads still run. Indexed merges preserve the first
matching SGPR/producer-PC pair, duplicate handling, ordering and full-capacity
updates. Graphics interfaces are reused only for the exact immutable instruction
allocation; modified programs retain the ordinary analysis.

Earlier changes in this checkpoint reduce completion scans to dirty buffer
slots, queue already-satisfied waits in FIFO order, and use the x86 string-copy
engine for large disjoint host transfers. The same-build completion-index
comparison inspected 255,024 candidates instead of 1,975,222,272. Its disabled
diagnostic path also constructs a selection bitset, so its timing is not a
direct comparison with the previous released implementation.

The separate wait/copy comparison measured:

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| Synchronous satisfied waits, ordinary copies | 660 | 53.527 | 12.33 |
| Queued satisfied waits | 660 | 52.408 | 12.59 |
| Queued waits and large string copies | 660 | 51.394 | 12.84 |

GPU color-to-storage conversion can now preserve a producer beginning before
the destination. It validates CPU baselines and publishes only the outer
prefix, retaining a GPU backing cropped to the destination. Producers extending
past both ends still use the checked fallback. This path had **zero hits** in
its title comparison (13.41 versus 13.31 FPS); no title gain is attributed to it.

Validation: **542/542 GPU/Vulkan tests** and **12/12 ReleaseFast build steps**.
Native probes cover queued/blocked waits and rejection ordering, GPU/CPU
publication, prefix and partial image writes, descriptor batching, scalar loops,
scalar calls, distinct scalar loads, resource workers and draw-upload rollover.
The 64 full-image overwrite configurations also pass. Vulkan synchronization
validation reports no errors in these probes. This is not a claim that all
rendering defects are fixed.

![ASTRO BOT title screen after scalar-analysis optimizations](../images/astro-bot-title-scalar-merges-2026-10-14.png)

The screenshot is an actual renderer capture of the game-owned 3840×2160
scanout; host output remains 1920×1080. Builds, tests, profiling and capture ran
outside the FPS comparisons. **25 FPS is not reached; character control and
later-scene correctness remain unverified.**

## Follow-up: bounded recording and storage proofs

ASTRO BOT now limits CPU command recording to **250 microseconds** before an
asynchronous submission, keeping the GPU occupied while the next resources are
prepared. The balanced warmed title comparison measured **12.43 FPS versus
11.69 FPS**, 660 frames per setting (53.076 versus 56.475 seconds), an
observed **6.4%** improvement. No commands or completion events are
omitted. Other titles retain their existing recording-budget defaults.

A second comparison keeps that budget enabled and tests exact storage baselines:

| Setting | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| Previous storage path | 660 | 52.842 | 12.49 |
| Avoid redundant whole-allocation hashes | 660 | 52.793 | 12.50 |
| Hash optimization and interior raster producers | 660 | 52.595 | 12.55 |

These small differences do **not** establish another FPS improvement. The hash
path demonstrably avoids **26.125 MiB of redundant hashing per title frame**,
while retaining exact texel checks. A texel-only proof cannot validate padding
or another mip. Raster producers starting inside a destination allocation can
now use the existing GPU layout conversion while preserving uncovered bytes;
that path has **zero hits in this title comparison**, so it cannot explain its
FPS. Producers starting before the destination still use the checked fallback.

RELEASE_MEM timestamps now use the graphics reference clock's **100 MHz** rate,
instead of raw CPU cycles. Optional calibrated Vulkan queries and queued EOP
events preserve GPU position and FIFO notification order. They remain disabled
by default: unrestricted batching regressed, and at the same 250-microsecond
budget native queries measured **12.40 FPS**, versus
**12.43 FPS** for the CPU-clock path. The clock mapping follows [Vulkan's
calibrated timestamp domains](https://github.khronos.org/Vulkan-Site/features/latest/features/proposals/VK_EXT_calibrated_timestamps.html).

Validation: **537/537 GPU/Vulkan tests**, **64 full-image overwrite
configurations** with six phases each, and native color/storage layout checks
with and without descriptor batching. Checks cover CPU texel replacement,
padding changes, unavailable fingerprints, aborted initialization, interior
producers and preserved outer bytes. Native release validation covers
**902 queries and 900 ordered EOP events**, pool rollover, failed writes,
blocked waits and submission sealing. Internal-release, deferred-output,
covered-raster and GDS probes also pass without Vulkan validation errors.
ReleaseFast runner/smoke builds pass 12/12 steps.

![ASTRO BOT title screen captured after bounded recording and storage changes](../images/astro-bot-title-bounded-recording-2026-10-14.png)

The capture comes from the renderer's actual 3840×2160 game-owned scanout;
host output remains 1920×1080. It verifies title imagery and text. It does not
verify character control or the later cinematic. The **25 FPS target remains
unmet**, and earlier rendering defects remain unresolved. Compilation,
profiling and image capture were outside every FPS comparison.

## Follow-up: compact scalar checkpoints and uploads

Resource checkpoints now copy 12-byte register records instead of 24-byte
records. The evaluator keeps USER_DATA dependency masks in a separate array,
including both halves of 64-bit operands. This also fixes a previously lost
high-word dependency. The checkpoint array shrinks from 3,072 to 1,536 bytes.
The 1,320-frame warmed title observation measured **11.62 FPS** in 113.568
seconds; this is a separate run, not a controlled speedup claim.

Scalar uploads now write the exact translated specialization prefixes. No
shader index can refer to the unused tail, so clearing the whole 66 KiB slot
per draw or dispatch is unnecessary. Native probes initialize the ring with
nonzero poison and validate changing compute inputs, loops, masked lanes,
fragment pixels and serial/worker/shared resource preparation. All 535
GPU/Vulkan tests pass, including the corrected worker-mode probe.

The balanced upload comparison measured **11.79 FPS without tail clearing**
versus **11.69 FPS with clearing** (660 frames per setting, 55.971 versus
56.465 seconds). The observed difference is only **0.9%**. The changes do not
establish a sustained gameplay minimum or fix all rendering defects. No fresh
screenshot or character-control check was available; **25 FPS is not reached**.

## Follow-up: CPU overwrite baselines

Candidates 52–53 replace a full-image overwrite's retained CPU copy with a
digest of its exact native texel spans. Padding stays outside that proof.
When the embedding exposes checked guest fingerprints, the renderer computes
the digest directly from guest memory and also avoids the intermediate read.
Unavailable fingerprints or coverage retain the snapshot path. Aborted
preparation invalidates the uninitialized image; digest-only images keep the
ordinary CPU-replacement guard when publishing mip chains.

Native synchronization validation passes 32 configurations covering immediate
and batched commands, tracking enabled/disabled, unavailable fingerprints,
coverage-budget fallback, newer CPU texels, padding and abandoned preparation.
Covered raster initialization and resident mip-chain probes also pass. Both
ReleaseFast builds succeed. No fresh capture or visual/control verification
was available.

The balanced candidate 52 comparison measured 660 frames in 59.002 seconds
(**11.19 FPS**) with digest baselines, versus 60.927 seconds (**10.83 FPS**)
with retained copies, approximately **3.3% faster**. Candidate 53 measured
660 frames in 57.354 seconds (**11.51 FPS**) using direct guest fingerprints,
versus 58.100 seconds (**11.36 FPS**) using a temporary snapshot. The latter
observed difference is only **1.3%**, so it is not a strong sustained-FPS claim.
Each enabled step eliminates a **26.125 MiB CPU copy per title frame**; this
is separate from the already avoided GPU upload and raster readback.

The subsequent descriptor survey found almost no identical complete resource
snapshots after normalizing the moving table address. For example, the main
material program had 271 distinct snapshots in 271 sampled input variants.
Rebasing the table address alone would therefore not solve the remaining
preparation cost. These observations concern the warmed title animation;
the 25 FPS objective and controllable gameplay remain unverified.

## Follow-up: relative vector moves

Candidate 51 implements M0-indexed source, destination and combined VGPR moves,
including the split-offset encoding. The previous source-relative lowering
ignored M0. Indirect reads and writes now participate in register liveness,
loop state, lane-mask provenance and resource analysis. A bounded scalar proof
narrows all 51 relative moves in the captured material shader to eight possible
registers each; unknown offsets retain checked access to the complete register
file. The analysis is informed by SharpEmu's GPL-compatible implementation.

The native probe passes 128 GPU dispatches covering wave32/wave64, masked lanes,
dynamic offsets, overlapping registers, high registers and loops. GPU/Vulkan
unit tests pass 534/534; the focused RDNA2 suite passes 10/10. The full RDNA2
suite retains its ten previously recorded failures (282/292 pass).

A warmed title sample measured 220 frames in 20.000 seconds (11.00 FPS).
The subsequent 1,320-frame observation across two animation cycles measured
**10.85 FPS**, without new draw/dispatch failures in the log. This is comparable
to candidate 50, not an established speedup. No new screenshot or visual/control
verification was possible because window automation remained unavailable.
The 25 FPS target is still unmet. Profiling identifies repeated CPU baseline
copies, resource evaluation and synchronous buffer/image publication as
remaining costs.

## Follow-up: proven full compute-image stores

A conservative shader analysis now proves rectangular output coverage from
workgroup coordinates and every local invocation. It rejects unknown address
maths, control flow, execution-mask changes, partial components and overlapping
input resources. The original shader still runs; only the upload of old output
pixels can be omitted. CPU replacement checks and untouched padding remain
protected, and abandoned preparation cannot leave an uninitialized cache hit.

Candidate 48 passes 532 GPU/Vulkan unit tests. Native immediate and batched
probes cover complete output, padding-only CPU changes, newer CPU texel writes,
cache reuse and abandoned preparation, without synchronization-validation
errors. Balanced title samples measured **9.45 FPS enabled versus 9.36 FPS
disabled**, 660 frames per setting across the same 11 animation phases.
The path omitted one **25.38 MiB** initialization upload per frame. The observed
FPS difference is small; it does not establish a sustained gameplay minimum,
and the 25 FPS objective remains unmet.

Candidate 49 also omits publication of an older raster image when its entire
native backing lies inside the proven output texels. The old GPU producer stays
available until the replacement dispatch commits; failed preparation invalidates
only the prepared storage image. Native tests verify full coverage, abandoned
dispatches, a producer extending beyond the output, row-padding holes and newer
CPU writes, with immediate and batched commands. Partial coverage retains the
normal readback. Both native overwrite suites pass synchronization validation.
Its warmed title interval measured **9.65 FPS**. Balanced 660-frame samples
measured **9.64 FPS enabled versus 9.67 FPS disabled**, with **zero old raster
publications omitted**. The observed raster producers have DCC enabled, which
the first coverage predicate conservatively excluded. These samples establish
no game speedup from skipping old raster publication.

Candidate 50 retains the same full-coverage proof for DCC-enabled raster
sources. Ordinary publication does not publish DCC metadata; CMASK/FMASK,
multisampling, partial coverage and padding holes still use the normal path.
The added native DCC-flag case verifies unchanged metadata and correct pixels
with immediate and batched submissions under Vulkan synchronization validation.

The balanced title comparison now skips **one old raster publication per frame**:
660 frames in 60.293 seconds (**10.95 FPS**) with the change, versus 660 in
68.202 seconds (**9.68 FPS**) without it, approximately **13.1% faster**.
Both settings retain candidate 48's 25.38 MiB/frame upload reduction. Raster
publications fall from two to one per frame. This result covers the warmed
animated title scene, not the crowd scene or a gameplay minimum. The 25 FPS
target remains unmet. No new screenshot or character-control verification
was possible while window automation was unavailable.

## Follow-up: native image layout transfers

Native GPU retiling now uses the same address equations as detiling. Byte-for-byte
probes cover 165 views, including 16-bit texels, packed halfword writes, odd
extents, arrays, volume slices, mip tails and unchanged allocation padding.
Color-to-storage conversion can combine contained overlapping raster producers
in content-write order. A retained native backing preserves pixels outside the
storage view; an interior-address consumer also publishes that backing.

Native composition tests pass with immediate and batched commands, including
opposite producer orders, CPU allocation replacement and interior-address reads.
Vulkan synchronization validation reports no hazards in these probes. This is
not evidence that every game image interpretation is supported.

Candidate 38's warmed title interval presented 187 frames in 20.0004 seconds
(**9.35 FPS**). It performed **zero layout conversions in that interval**.
Tracing found another raster producer extending outside the destination's
allocation, which correctly retains the fallback. Thus this implementation has
no demonstrated speed benefit in the measured title scene. The 25 FPS objective
remains unmet; no new visual-quality or gameplay claim accompanies these probes.

Candidate 43 additionally handles a raster producer that starts inside the
storage allocation and extends past its end. It retains the complete native
backing and publishes the outer bytes before transferring ownership. Tests
verify preservation of that tail, subsequent CPU edits, rejection of another
outer GPU writer, and CPU replacement during the transfer. Immediate and
batched cases pass synchronization validation. A 20-second title interval
measured 9.65 FPS; the balanced 660-frame comparisons measured **9.60 FPS with
the path enabled and 9.60 FPS disabled**. Neither interval used the conversion
path. The passing memory tests therefore do not establish a game speedup.

## Follow-up: bounded buffer readback prefetch

A native-tested comparison path can copy recently requested buffer prefixes
before the next CPU consumer arrives. It records the content epoch, exact sparse
coverage and GPU completion tick; later writes invalidate the snapshot. Per-frame
transfer limits and temporary suppression of repeatedly unused copies bound the
extra work. Tests cover queued and immediate commands, partial publication, CPU
edits to a published prefix, a newer GPU writer, and a raw read spanning gaps
that the prefetch did not copy. Vulkan synchronization validation passes.

Candidate 39's initial 20-second title interval measured 9.70 FPS. A subsequent
comparison alternated 22 blocks of 60 frames, covering each of the 11 animation
phases once per setting: enabled **9.65 FPS**, disabled **9.78 FPS**, 660 frames
per setting. The extra transfers did not improve this scene. The switch
`prefetch_storage_readbacks` therefore remains **disabled by default**.

Candidate 46 also publishes exact interior buffer spans instead of always
downloading the prefix before them. Published holes remain excluded from later
GPU publication, preserving CPU edits. If the fixed range list cannot represent
another hole, publication falls back to the prefix before making any changes.
Native probes cover unaligned reads, sparse ranges, overlapping newer writers
and both immediate and batched transfers. Vulkan Debug tests pass 259/259.
Balanced title observations measured **9.46 FPS enabled versus 9.37 FPS disabled**,
but recorded **zero uses** of the new path in either interval. This difference
does not establish a benefit from exact interior publication in this scene.

Candidate 47 retains a valid prefetched mirror when several buffer outputs
retire together. Previously that completion batch recorded a duplicate copy.
Native tests verify zero additional transfer bytes for two covered mirrors,
and the required replacement transfer for a partial mirror or a newer GPU
writer. Preparing a mirror still does not publish guest bytes prematurely.
Both immediate and batched tests pass Vulkan synchronization validation.
The initial title interval measured **9.55 FPS**. Balanced 660-frame samples
measured **9.50 FPS enabled versus 9.55 FPS disabled**. Of 3,300 prefetched
copies, 1,980 were consumed and 1,320 were invalidated before use. Completion
reuse avoids duplicate transfers, but the remaining speculative work still
does not improve this scene; prefetch remains disabled by default.

## Follow-up: storage image uploads and native publication

Three GPU-detile candidates were slower than the CPU path in balanced title
comparisons. Each setting covered 660 presented frames across the same 11
animation phases, alternating 60-frame blocks:

| Candidate | GPU detile enabled | GPU detile disabled |
| --- | ---: | ---: |
| 40: temporary upload and layout buffers | 8.75 FPS | 9.55 FPS |
| 41: reusable device buffers and upload-ring slices | 9.07 FPS | 9.56 FPS |
| 42: native texel comparisons and GPU-retiled publication | 9.42 FPS | 9.55 FPS |

Buffer reuse reduced the regression, but did not establish a speed improvement.
A separate CPU profile still found repeated texel detiling during replacement
checks, allocation copies, and synchronous buffer/image readbacks.

Candidate 42 compares exact native texel spans against a bounded CPU
baseline. Padding changes can retain the image without uploading it again.
Storage-image publication can also retile on the GPU, then copy only the
covered texel spans into a current guest-memory snapshot. Native tests verify
queued independent uploads, exact output bytes, padding-only edits, CPU texel
replacement, baseline retirement, and CPU writes during the GPU wait. Both
immediate and batched cases pass Vulkan synchronization validation. These
checks establish memory behavior, not visual quality or controllable gameplay.
Candidate 42's first 20-second interval measured 9.40 FPS. Its balanced
comparison reduced the regression but still did not beat the CPU path, so
`gpu_storage_detile` and `gpu_storage_retile` remain **disabled by default**.

Candidate 45 tested native-order texel digests independently of GPU uploads.
Coverage omits padding, and each digest is paired with its linear baseline so
replacing that baseline invalidates the proof. The same native tests exercise
CPU uploads, padding-only changes, first/last texel edits, stale-proof fallback
and CPU writes during publication. A GPU-to-CPU upload transition also now
releases the previous native snapshot instead of retaining an obsolete guard.
The first title interval measured 9.50 FPS; balanced comparisons measured
**9.46 FPS enabled versus 9.52 FPS disabled**, 660 frames per setting.
`native_storage_texel_hashing` therefore remains **disabled by default**.

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
