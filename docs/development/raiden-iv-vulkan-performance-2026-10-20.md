# Raiden IV Vulkan performance investigation, 20 October 2026

PPSA08832 v01.000.000, OverKill / Solo P1 / Normal / Stage 1-1, Vulkan,
1920×1080 output and internal target, RTX 3070 Ti. These are development
changes after v0.3.5. **Stable 60 FPS in gameplay has not been established.**

## Measurement

The controlled runs use the runner's `scripted` input mode, which excludes
physical keyboard/controller input. Timing starts at the opening carrier
scene and counts presented guest frames. Compilation, CPU stack sampling and
native GPU probes are excluded from timed runs. The shader cache is warm.

| Configuration | Opening, 180 frames | First 1,800 gameplay frames |
| --- | ---: | ---: |
| Initial three changes disabled, parallel commands, draw reuse enabled | 48.60 FPS | 43.94 FPS |
| Initial three changes enabled, parallel commands, draw reuse enabled | 49.05 FPS | Not measured completely |
| Initial three changes enabled, serial commands, draw reuse enabled | 50.99 FPS | 46.33 FPS |
| Initial three changes enabled, serial commands, draw reuse disabled | 53.55 FPS | 48.52 FPS |
| Refined snapshot index and adaptive/content-aware capture, serial commands | 57.62 FPS | 52.23 FPS |
| Above plus vector comparison of uniform publications | 60.31 FPS | 53.94 FPS |
| Above plus snapshot bounds rejection and short fixed-size guest copies | 59.55 FPS | 53.49 FPS |
| Batched metadata and shared vertex capture | 63.12 FPS | 55.60 FPS |
| Above with a 1 ms command submission age | 64.97 FPS | 59.87 FPS |
| Above with a 250 µs command submission age | 64.05 FPS | 59.44 FPS |
| Unused vertex seeding removed, sparse resource scratch reset, 1 ms submission age | 66.73 FPS | 61.13 FPS |
| Conservative dependency masks on uncaptured draws | 68.50 FPS | 62.49 FPS |
| Same executable with conservative masks disabled | 66.00 FPS | 61.10 FPS |
| Recycled checkpoint capacity, batched translation keys and empty buffer-index fast path | 70.93 FPS | 65.93 FPS |
| Mapping-aware uniform publication certificates and large-clear watches | 76.53 FPS | 70.67 FPS |
| Same executable without arming additional large-clear watches | 75.55 FPS | 70.28 FPS |
| Vector-only buffer loads retained on GPU | 78.85 FPS | 71.86 FPS |
| Same executable with GPU-only load optimization disabled | 76.29 FPS | 69.12 FPS |
| GPU-only loads with a 4 ms submission age | 78.01 FPS | 70.98 FPS |
| Forward load cursor and direct scalar moves | 76.90 FPS | 72.28 FPS |
| Initial parameterized walk cache | 77.82 FPS | 73.49 FPS |
| Same executable with parameterized cache disabled | 77.76 FPS | 72.04 FPS |
| Refined 32/64-bit proof and vector-resource parameterization | 78.16 FPS | 73.19 FPS |
| Same executable with a 256-entry / 128 MiB walk cache | 77.02 FPS | 68.46 FPS |
| Same executable with draw reuse disabled | 80.23 FPS | 72.86 FPS |
| Same executable with direct scalar moves disabled | 79.52 FPS | 72.80 FPS |
| Batched vertex tables, narrower snapshot search and lazy replay/diagnostic work | 85.24 FPS | 79.09 FPS |
| Linear resource interpreter and cheaper walk-cache key checks | 87.77 FPS | 80.52 FPS |
| Same executable with the linear interpreter disabled | 85.32 FPS | 77.13 FPS |
| Retain byte-validated read-only uploads across submissions | 89.25 FPS | 82.02 FPS |
| Same executable with cross-submission retention disabled | 82.65 FPS | 79.73 FPS |
| Pointer-recovery scratch bounded by actual load PCs | 88.79 FPS | 82.77 FPS |
| Same executable with bounded pointer scratch disabled | 87.04 FPS | 78.68 FPS |
| Vector occupancy search and sorted submission ranges | 89.42 FPS | 84.36 FPS |
| Same executable with sorted submission lookup disabled | 90.11 FPS | 81.51 FPS |
| Reuse unchanged scalar buffer mappings and isolate cold shader decoding | 92.62 FPS | 82.62 FPS |
| Same executable with scalar descriptor reuse disabled | 85.24 FPS | 83.52 FPS |
| Scalar descriptor reuse enabled, 2 ms submission age | 94.52 FPS | 84.30 FPS |
| Validated walk-cache hints and 4,096-entry transient-upload cache, 1 ms submission age | 96.00 FPS | 86.59 FPS |

The opening samples all render 761 draws per frame. The longer routes have
different bullet/enemy counts because scripted fire uses wall-clock pulses,
so their averages are indicative, not exact frame-for-frame A/B comparisons.
The initial configuration falls to roughly 27–37 FPS in the heavier wave.
The vector-publication run still falls to approximately 36–43 FPS in its
heavier wave. The 1 ms submission run still falls to approximately 36–49 FPS
in its heavier wave. The opening average reaching 60 does not establish
stable 60.

A pause-screen A/B trial was discarded: Raiden caches the background and
renders only a small overlay while paused. Its several-hundred-FPS result
does not measure the gameplay renderer. A separate intervened-with run was
also excluded. One later measurement stopped early when the gameplay draw
count dropped below an overly conservative cutoff; only its complete
opening interval is reported above.

## Changes

- Read-only uploads of up to 4 KiB can reuse an immutable upload-ring slice
  after comparing every current input byte against a CPU snapshot. Address
  equality alone is insufficient. Ring recycling and spill retirement
  invalidate the cache. A cache hit also pins the ring for the current draw.
  The latest candidate retains ring-only snapshots across command submission
  and descriptor reset; spill retirement clears hints so a pinned full ring
  cannot force an indefinite sequence of temporary allocations.
- Resource-walk cache entries can recycle their allocations, including a
  smaller checkpoint list or a different sampled/resource split.
  Identity, captured dependencies, scalar results and instruction checkpoints
  are replaced together; all live-input validation remains in place. Memory
  budgets account for the full retained allocation, not just the current view.
- Submission snapshots use an address-region index for containment queries.
  Overlapping ranges retain the earliest captured version. Empty or
  GPU-generated indirect streams retain their existing live-refresh rules.
  A subsequent refinement replaces the general-purpose key hash and retains
  a linear scan for small snapshot collections.
- Draw replay capture becomes adaptive after repeated misses. It periodically
  probes for a reusable sequence and immediately resumes normal capture after
  a hit. A declined capture takes full resource preparation.
- Resource-walk admission includes captured contents as well as bindings.
  Constantly changing data at a recycled address no longer fills the cache
  just because its address repeats. Admitted hits still validate actual bytes.
- Raiden's Vulkan default uses serial command preparation; the existing
  `PS5_GPU_PARALLEL_COMMANDS` override remains available. DirectX is unaffected
  by this title-specific default.
- Uniform 32-bit GPU publications compare the complete destination against
  the known repeated value with vector loads, without reading a second large
  staging buffer. Ordinary publications and unaligned ranges retain their
  byte comparison.
- Adjacent AGC metadata fields use one checked read, reducing a successful
  header capture from 15 callbacks to four. Readers that reject the combined
  span fall back to the original field reads and validation order.
- The metadata measurement shared the vertex table between seeding and resource
  preparation. Further inspection found that seeding only changes final SGPRs,
  whereas resource preparation consumes load history and instruction-local
  checkpoints. That unused copy, instruction scan and extra vertex-table capture
  have now been removed and remeasured.
- Recycled resource scratch clears previously occupied or writable slots;
  untouched slots retain their initialized state. The reuse test checks
  read-only and writable slots, write origins, extents and range metadata.
- Raiden submits completed command batches after 1 ms, allowing GPU execution
  to overlap CPU preparation. A 250 µs comparison did not improve the result.
- Tracked write invalidation precedes alias publication or restoration of
  native write permission, preventing epoch readers from accepting the old
  generation while bytes are already writable or changing.
- Uncaptured draws use a conservative full USER_DATA dependency mask. They
  retain every scalar instruction, memory read and producer value.
- Normalized translation-key slices reserve storage once per slice instead
  of once per scalar or resource binding. Their canonical bytes stay identical.
- Index-range publication retains image/release handling but avoids a buffer
  overlap query when the buffer cache is empty.
- Uniform publication certificates include mapping identity as well as page
  generation. Creating, writing and removing a physical alias can no longer
  leave an old uniform-value certificate valid. Raiden's Vulkan profile also
  watches large uniform destinations; unsupported watches retain byte checking.
  A same-executable comparison shows only a small additional benefit from
  arming these watches, within the variability of the longer route.
- Raiden's read-only Vulkan draws can leave proven vector-only constant-buffer
  loads on the GPU. A conservative suffix analysis excludes resource/control
  consumers, loops, indirect calls, lane transfers and uncertain instructions.
  The shader still performs the original load; host discovery marks its result
  unknown and binds the live buffer instead of making a scalar specialization.
  This is enabled only for the tested Raiden Vulkan profile.
- Straight-line proofs distinguish register lifetimes separated by definite
  overwrites; conditional programs keep the conservative union. Read-modify-
  write operands remain dependencies. The walk cache may parameterize only
  untouched entry words which no host operation consumes. Replayed evaluations
  and checkpoints receive the current values; unvisited checkpoints stay
  unknown. All other bindings and captured bytes are still validated.

None of these changes lowers resolution or skips a requested draw, shader or
dispatch. They do not address the separately documented background-music issue.

## Validation and remaining work

The refined implementation passes **316 GPU tests and 260 Vulkan unit tests**.
The initial upload changes also passed native transient-storage and upload
rollover probes, including changed input, unaligned ranges, queued work and
spill retirement with both supported synchronization/mapping modes.

The refined executable passed its native transient-storage and upload rollover
reruns. The subsequent uniform-publication implementation passes all **44
memory tests**, including every-byte mutations across unaligned vector
boundaries, and the GPU suite again.

The remaining sampled CPU costs include scalar resource
interpretation, guest-memory reads, resource preparation and publication of
uniform buffer clears. GPU completion waits remain measurable as well.

A cache of short shader reads under existing memory watches was tested and
removed: Raiden's relevant ranges were untracked, yielding zero hits and
57.09 / 51.75 FPS versus 59.55 / 53.49 FPS with that cache disabled in the
same executable. Re-reading untracked memory is required.

The metadata candidate also passed native transient storage, upload rollover,
bounded vertex fetch and graphics descriptor reuse probes. Its first
1,800 frames reported no draw, dispatch,
unsupported compute or unresolved/rejected storage gaps.

Unused seeding removal and sparse scratch reset passed the same four native
Vulkan probes. Their combined run averaged 61.13 FPS over 1,800 frames, but
heavier intervals still measured around 35–52 FPS. This remains short of stable
60 FPS.

A second short-read cache experiment actively armed native write watches and
validated physical aliases and mapping identity. Despite approximately 91% hits,
it measured only 63.71 / 57.56 FPS versus 66.73 / 61.13 FPS without it. The
cache and its extra callbacks were removed. Its initial inline allocation also
overflowed the smoke executable's stack; a separate lazy allocation passed the
native probes before the performance comparison.

Conservative dependency masks passed the four native Vulkan probes and
averaged 68.50 / 62.49 FPS. Disabling only this change in the same executable
gave 66.00 / 61.10 FPS. The enabled run still fell to approximately 39 FPS in
the heavier wave, so stable 60 FPS remains unverified.

The subsequent allocation/key candidate passes **317 GPU tests** and all
**22 cache-related RDNA2 tests**. The full RDNA2 suite reports 304 passes and
10 failures; all ten also reproduce in an isolated copy of unmodified commit
`363949a` (303 passes and the same ten failures). These are existing translator
test failures, not new failures caused by the key changes. Native transient
storage, upload rollover, bounded vertex fetch and graphics descriptor reuse
probes subsequently passed. Gameplay measured
70.93 / 65.93 FPS; heavy-wave intervals still fell below 60.

The uniform publication changes pass all **45 memory tests**, including a
native write fault and physical-alias creation/write/removal. The enabled
gameplay run avoided comparison of approximately 75,938 MiB over 1,800 frames
and averaged 76.53 / 70.67 FPS. Disabling the additional watches in the same
executable gave 75.55 / 70.28 FPS. Heavy intervals still fell to approximately
40–57 FPS. All reported draw, dispatch, unsupported-compute and unresolved,
null or rejected storage counters stayed zero. Stable 60 FPS remains unmet.

The vector-only load candidate passes **318 GPU tests and 260 Vulkan tests**.
A native probe compares every rendered pixel between CPU
specialization and live GPU loads, with changed input and partially out-of-range
loads. Both paths match. The gameplay comparison records 1,461,872 deferred
host loads over 1,800 frames and 71.86 FPS versus 69.12 with the optimization
disabled in the same executable. The heavy scene still drops below 60 FPS.
A 4 ms submission age gives 70.98 FPS; parallel command preparation gives
66.68 FPS. The 1 ms serial profile is retained.

The forward load cursor and direct scalar-move path pass **319 GPU tests**,
including differential checks for overlapping register pairs, unknown values,
constant widening, provenance and SCC. The native pixel comparison also passes.
The first run gives 76.90 / 72.28 FPS, without a clear improvement in the
opening scene. The direct-move path still needs an isolated comparison.

The parameterized-walk implementation passes **321 GPU and 260 Vulkan tests**.
Its native pixel probe exercises actual walk-cache hits while moving the source
buffer, changing colors, shrinking the readable range and reusing scalar
registers after a definite overwrite. The output matches a full host walk.
Transient-storage, upload rollover, bounded vertex fetch and descriptor reuse
probes also pass.

The initial parameterized cache measured 77.82 / 73.49 FPS versus
77.76 / 72.04 FPS with it disabled. A heavy interval still reached only
44.15 FPS. Inspection of the captured vertex program found two conservative
restrictions: ordinary 32-bit scalar reads also pinned the next register, and
vector-buffer descriptor inputs prevented parameterization despite being
rebound at their own checkpoints. The refined proof distinguishes 32/64-bit
reads and permits these untouched descriptor inputs only with the full
dependency mask. All four constant-buffer loads in this vertex program then
qualify, including its 16-word matrix load. The expanded native probe also
uses MUBUF to produce the red output component and passes pixel comparison
with cache hits, changed addresses, changed contents and shortened buffers.

The refined proof deferred 5,462,891 host buffer loads over 1,800 frames.
Approximately half the scalar walks still missed the cache. Live inspection
after the timed route identified changing vertex-buffer table pointers as actual input differences;
these cannot be ignored without validating the data reached through them.
Increasing the cache to 256 entries barely improved its hit rate and reduced
performance to 68.46 FPS, with a heavy interval near 40 FPS. The default remains
64 entries / 32 MiB. Neither disabling draw reuse nor disabling the scalar-move
fast path established an improvement over the complete route.

The next candidate batches vertex-table reads, falling back to per-entry reads
when a span crosses inaccessible memory. Submission snapshot queries exclude
regions too small to contain their endpoints. Draws with neither a replay
candidate nor an admitted capture omit unused reuse hashes. Shader diagnostics
reserve their large scalar-history stack frame only for a new traced shader.
These changes preserve full rendering and current-data validation.

This candidate passes **321 GPU tests and 260 Vulkan tests**, and the five
native probes above pass. It measures 85.24 FPS in the
opening and 79.09 FPS over 1,800 frames. The heaviest interval still reaches
only 47.04 FPS. The route includes deaths and animated Continue overlays;
these continue rendering the underlying level and are included in the result.
The high score screen reached afterward is not part of the timed sample.

A separate diagnostic run starts sampling 960 frames into the level, excluding
profiling from FPS measurements. Its captured vertex shader is `0x41b100`
(188 decoded instructions, 19 checkpoints and seven host reads). An isolated
resource-walk benchmark on those exact inputs measures approximately 2.3 µs
per walk. Forcing source-operand lookup to inline does not improve it and was
reverted. A sequential interpreter for proven straight-line programs reduces
the same-executable comparison from approximately 2.55 to 2.04 µs per walk.
This is an interpreter microbenchmark, not an FPS claim. Branches, indirect
calls, lane transfers, incomplete programs and short instruction budgets retain
the original walker. Differential checks cover failed reads, deferred GPU
loads, complete register states, checkpoint contents, load history and limits.

The linear-interpreter candidate passes **322 GPU tests** and the native
vector-only-load, bounded-fetch and descriptor-reuse probes.
The initial concurrent build's test runner timed out; a direct run and a
separate `test-gpu` invocation both passed all 322 tests, and the standalone
runner build succeeded. Gameplay measures 87.77 / 80.52 FPS, versus
85.32 / 77.13 FPS with only the linear interpreter disabled. Heavy intervals
remain approximately 48–51 FPS; stable 60 FPS is still unmet. Reported draw
and dispatch failures and unresolved/null/rejected storage counters remain zero.

The retained-upload candidate passes a native Vulkan probe with timeline
scheduling both enabled and disabled. It verifies identical GPU reads across
submission/reset boundaries, a cache hit pinning an exhausted ring, spill
retirement and overwriting the old ring bytes before taking a fresh snapshot.
Both retained and non-retained modes produce the same output.

The runner and smoke builds both succeeded. Native upload-rollover,
descriptor-reuse and vector-only-buffer-load probes also passed. The retained
run measures 89.25 / 82.02 FPS; disabling retention gives 82.65 / 79.73 FPS.
The retained heavy intervals still reach only approximately 49–52 FPS.
A separate diagnostic run identifies repeated clearing of an 8 KiB bitmap
in pointer recovery even for short programs. The next candidate bounds this
scratch by actual non-buffer scalar loads, retaining the existing PC/prefix
limits and exact analysis identity.

The bounded-scratch candidate passes **323 GPU tests** and the native
vector-only-buffer-load, bounded-vertex-fetch and descriptor-reuse probes.
Both runner and smoke builds succeeded. Gameplay measures 88.79 / 82.77 FPS,
versus 87.04 / 78.68 with only the bitmap bound disabled. The most demanding
measured interval remains 50.54 FPS (1,404 draws in its final profiled frame).

The next candidate uses byte-vector occupancy checks to search only populated
buffer slots, preserving exact address/size matching and the lowest matching
descriptor. Its differential and resource-pool reset checks pass as part of
**261 Vulkan tests**. Submission capture also prepares a sorted range view for
execution; prefix-end bounds reject unrelated ranges, and queries encountering
more than 16 overlapping candidates fall back to the existing region index.
Both paths retain the earliest containing snapshot, including empty reads at
endpoints, and a later insertion invalidates the sorted view by count.

This candidate passes all **323 GPU tests**, including both snapshot indexes,
and four native probes (transient storage, vector-only loads, bounded vertex
fetches and descriptor reuse). Both builds succeeded. It measures
89.42 / 84.36 FPS, versus 90.11 / 81.51 with only sorted lookup disabled.
The heaviest interval is 52.27 FPS, so stable 60 FPS is still not established.
All reported gap counters remain zero in both runs and both bounded-scratch runs.

The next candidate reuses an already-installed unqualified scalar-buffer
mapping within one read-only operation. Every descriptor word at the current
instruction must be known and unchanged, and vertex attribute substitutions
are excluded. Offset evaluation remains in the GPU shader. It also moves
shader decoding's large temporary stack frame off validated analysis-cache
hits. The candidate passes **262 Vulkan tests**. The extended pixel probe
installs the same descriptor twice, shrinks its record count before a third
load, then moves/recolors the buffer across cached walks. CPU specialization
and GPU loads match pixel for pixel, with actual descriptor and walk-cache
hits. Its initial cache-hit assertion needed a third repeated configuration
because admission intentionally requires two observations.

The shared native-probe helper now explicitly requests the Vulkan validation
layer in ReleaseFast builds; it previously inherited the Debug-only default.
Vector-only loads, transient storage, bounded vertex fetches and graphics
descriptor reuse all pass with the log confirming the layer is enabled.
The gameplay runner already contains the same production changes; subsequent
edits affect only the standalone probe and its diagnostics. Gameplay measures
92.62 / 82.62 FPS, versus 85.24 / 83.52 with scalar descriptor reuse disabled.
The different enemy/bullet counts prevent treating the route average as an
isolated speedup. The heavier intervals remain approximately 48–53 FPS.
A 2 ms submission age measures 94.52 / 84.30 FPS, with a minimum measured
interval of 48.68 FPS. The production default remains 1 ms.

A separate diagnostic capture of the heavy scene still identifies scalar
interpretation, resource preparation and guest-memory validation as substantial
CPU costs. The next candidate adds a fully validated index hint for cached
resource walks and tests a larger transient-upload cache. Neither change may
reuse an entry based on its address or index alone. Resizing the upload cache
invalidates all retained entries.

This candidate passes **324 GPU tests and 263 Vulkan tests**, plus the four
native probes above with validation enabled. Both runner and smoke builds pass.
The 4,096-entry run measures **96.00 FPS over the opening 180 frames** and
**86.59 FPS over 1,800 frames / 20.7867 seconds**. Its lowest 60-frame interval
is **50.58 FPS**; all 283 periodic GPU-gap reports are zero. This is a warm-cache
scripted route including deaths and animated Continue overlays, not a minimum
FPS guarantee or a complete playthrough. The maintainer reports acceptable
performance and requests these settings as defaults.

The runner now automatically selects the complete measured profile for
**PPSA08832 on Vulkan**: serial command processing, a **1 ms** command submission
age, GPU execution of proven vector-only scalar-buffer loads, mapping-aware
large-clear watches when GPU page tracking is enabled, and a **4,096-entry**
byte-validated transient-upload cache. Shared renderer optimizations are enabled
by default. Other titles retain the 512-entry active upload table. Ordinary CLI
and launcher launches need no diagnostic script or environment settings;
explicit command-processing overrides still take precedence.

The final runner and smoke builds pass all 18 build steps. The expanded native
transient-storage probe also passes at both 512 and 4,096 entries, with timeline
scheduling disabled/enabled and validation active. A fresh Vulkan launch with
all `PS5_GPU_*` environment overrides removed confirms the 20 expected runtime
parameters through read-only inspection; no process-memory flag writes are
used. That verification launch is stopped afterward.

The local Windows runner is Authenticode-signed with the existing PS5PCEM
certificate and a DigiCert timestamp. Its self-signed root retains the existing
Windows trust-chain warning; this does not claim public certificate trust.
