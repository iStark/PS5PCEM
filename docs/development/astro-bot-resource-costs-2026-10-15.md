# ASTRO BOT: resource preparation and scheduling, 15 October 2026

These measurements cover the animated title screen in PPSA21564 v1.018, not
character-controlled gameplay. The host output is 1920×1080; the game still
produces a 3840×2160 source image. No draws or shader instructions are removed
to obtain the results below. The latest uninterrupted confirmation measured **18.0451 FPS over 2,640 frames
in 146.2998 seconds**. The 60-frame blocks ranged from **16.9454 to 19.5886 FPS**.
This reaches an 18 FPS title-screen average in this run; it does not establish
an 18 FPS minimum or a gameplay result. The 25–30 FPS goal remains unmet.

![ASTRO BOT animated title screen after resource and wait optimizations](../images/astro-bot-title-resource-costs-2026-10-15.png)

## Controlled comparisons

Each mode runs eleven 60-frame blocks in the same process, covering every
phase of the title animation. FPS is total frames divided by total elapsed
time. Compilation, profiling and image capture finish outside timed blocks.
Results from separate processes must not be added as independent percentage gains.

| Change | Control FPS | Enabled FPS | Result |
| --- | ---: | ---: | --- |
| Progress-aware AGC SuspendPoint (95) | 16.3222 | 16.6890 | +2.25%; retained |
| Reuse validated uniform CPU publications (96) | 16.4208 | 16.5963 | +1.07%; retained |
| Command age: 125 / 250 / 500 / 1000 microseconds (98) | — | 16.1645 / 16.6779 / 16.7207 / 16.7180 | Keep existing 250; differences too small |
| Disable command-age flushing (98) | 16.6779 | 15.6091 | Rejected |
| SDK11 queue/stack reads (99, mode 1) | 16.5234 | 16.5432 | Fewer checked reads; FPS difference inconclusive |
| Decoded interpreter specialization (99, mode 2) | 16.5234 | 16.3211 | Rejected and removed |
| Queue reads and interpreter specialization together (99, mode 3) | 16.5234 | 16.5808 | No sustained gain established |
| Watched-range fingerprint cache (100) | 17.5225 | 17.4684 | Repeated hashing reduced; no FPS gain established |
| Indexed scalar loops and pointer-based instruction checks (101) | 16.6844 | 16.9276 | +1.46% in this comparison |
| Watched readback guard only / both changes (101) | 16.6844 | 16.8198 / 16.9136 | Guard had zero eligible bytes; no benefit attributed to it |
| Reuse armed GPU pages (102, mode 1) | 17.0495 | 17.4463 | +2.33% |
| Disjoint checkpoint copies (102, mode 2) | 17.0495 | 17.0932 | Difference inconclusive alone |
| Armed pages and disjoint checkpoint copies (102, mode 3) | 17.0495 | 17.5990 | +3.22% in this comparison |
| Copy participants: 2 / 3 / 4 (103) | — | 17.3714 / 17.4484 / 17.4735 | Keep existing four participants |
| Fine watched-range guards (104) | 17.9240 | 17.9630 | Difference inconclusive; 3,133,982 page checks avoided |
| Exact-key scalar query front caches (105) | 17.5626 | 17.6379 | +0.43%; small difference |
| Initial mapped/storage upload coverage (106) | 17.7278 | 17.6248 | Zero eligible bytes; no improvement established |
| Complete upload path / readback path / both (107) | 17.3571 | 17.5398 / 17.5810 / 17.6827 | Both +1.88% in this comparison |
| Initialize only uniform-proof visitation markers (108) | 17.6041 | 17.5936 | No FPS gain; 770,457,600 bytes of clearing avoided |
| Exact-input uniform-proof transcript cache (109) | 17.4692 | 17.5483 | Zero reuse hits; experiment removed |
| Read packed linear image layers as contiguous spans (110) | 17.7976 | 17.9898 | +1.08%; 8 MiB batched per frame |
| Wider static-query front cache / lean scalar scratch / both (112) | 17.5022 | 17.6369 / 17.5776 / 17.6716 | Both +0.97%; sustained confirmation below 18 FPS |
| Counter-assisted timeline polling (113) | 17.7787 | 18.0212 | +1.36%; retained |
| Honor Windows timer requests only / with counter polling (113) | 17.7787 | 17.8564 / 17.9937 | No separate gain established; system policy restored |

## Retained changes and validation

AGC SuspendPoint yields when command processing has advanced since the
thread's preceding suspension point. Accepted, resumed and retired submissions
establish progress. Repeated blocked waits and idle calls keep the existing
sleep. The enabled comparison recorded 659 progress yields and no idle sleeps,
against 658 forced sleeps in the control. Register-WAIT diagnostics also stop
treating register offsets as guest memory addresses.

Uniform CPU publication reuses a full-page certificate only while the watched
page's generation and repeated 32-bit value match. Changed data is still written;
partial writes do not certify a full page. CPU writes, remapping and other GPU
publications invalidate the certificate. This avoided 12,362,465,280 comparison
bytes over 660 frames. Candidate 96 passed 1,240 HLE/GPU/Vulkan tests, 39 memory
tests and native color-alias, packed-clear and worker probes.

SDK11 queue discovery reads bounded stack windows through one checked mapping
lease, with individual-word fallback at mapping boundaries. Discovered queues
retain their validation. Candidate 99 reused 337,920 stack words in 2,640 windows.
Its interpreter-specialization experiment was slower and was removed after the
1,242-test suite and differential tests passed.

The 256-entry fingerprint cache keys exact address, length and a nonzero
already-watched generation for ranges of at least 64 KiB. Untracked memory
uses the original callback; a generation change during hashing prevents
insertion; attaching new guest memory clears the cache. Candidate 100 avoided
12,056,985,600 hash bytes over 660 frames without an established FPS gain.
All 1,242 tests and native texel-hash, overwrite and color-alias probes passed.

Indexed scalar-loop checks are used only while no saved vector lanes require
dense instruction visits. Readback guards compare generations before and after
copying, after GPU completion, with hashing fallback. Candidate 101 passed
567 GPU/Vulkan tests, Debug comparisons and native storage/overwrite probes.

Armed-page reuse runs under the existing locks and requires pages to remain
armed/read-only. CPU writes, unmapping and protection changes invalidate it.
Candidate 102 avoided 16,443,316 repeated page registrations over 660 frames.
Checkpoint copies use memcpy only after proving non-overlap; self/overlapping
copies keep their previous path. All 1,245 tests, 40 memory tests, focused Debug
checks and native worker/coherence probes passed.

Fine watched-range guards add 256 KiB epochs under the existing 2 MiB guards.
Only an exact range with a matching epoch is reused. Collisions add misses;
epoch wrap clears both tables and cached results. Candidate 104 passed 42 memory
tests, focused Debug checks and 677 HLE tests. Its 1,320-frame confirmation was
17.9164 FPS, so its small comparison difference is not treated as a proven gain.

Scalar query front caches retain immutable writer facts, including ambiguous
results, and compare complete keys. They do not retain guest values. Backing-map
capacity and allocation-failure fallback semantics remain intact. Candidate 105
passed 569 GPU/Vulkan tests; its confirmation measured 17.9531 FPS over 1,320 frames.

The initial transfer change (106) missed the hot sampled-image upload branch.
A separate profile identified it; candidate 107 covers sampled and storage
uploads, mapped writes and CPU readbacks. Transfers of at least 2 MiB use the
existing joined copy helper; its existing parallel-worker threshold remains
4 MiB. GPU waits and mapping lifetimes are unchanged. The combined 660-frame
sample handled 8,273,633,280 upload bytes and 2,737,152,000 readback bytes.
All 270 Vulkan tests and native GPU transfers passed, including 2 MiB boundaries,
4,147,200-byte and 8 MiB copies, unaligned offsets and guards. Its confirmation
was 17.4943 FPS, below the target.

Uniform branch proof states initialize their visitation marker before capture
initializes knownness, SCC and every known value. Candidate 108 removes about
1.1 MiB of unused value clearing per frame. Poisoned/reused scratch comparisons
cover joins, loops and failed reads; all 570 GPU/Vulkan tests passed. Its
1,320-frame confirmation measured 17.6716 FPS, without a separate FPS gain.

Candidate 109 recorded and revalidated complete uniform-proof input transcripts.
All 572 GPU/Vulkan tests, focused Debug checks and native null-image/image-loop
probes passed, but the title recorded zero reuse hits. The cache was removed.

Packed linear image layers now use one checked read per layer. Base offsets,
slice stride and row padding are preserved. A reader unable to lease the entire
span falls back to the original rows. Candidate 110 batched 5,536,481,280 bytes
over 660 frames without fallback. Its confirmation was 17.7081 FPS over 1,320
frames. All 571 GPU/Vulkan tests, guarded/failing-read Debug checks and native
sampled-scratch/array-refresh probes passed.

Candidate 112 compares the wider static-query front cache (111) and lean
scalar scratch initialization separately. Complete-key collision checks remain.
Machine-code inspection found whole-struct defaults clearing 20 KiB of unused
lane-spill and branch arrays per walk. Explicit marker initialization removes
those clears while retaining initialization before any record is read.
The enabled sample avoided 8,145,940,480 clearing bytes over 660 frames. All 572
GPU/Vulkan tests, poisoned-scratch Debug checks and native image-loop/worker
probes passed with synchronization validation. The 2,640-frame confirmation
measured 17.9182 FPS over 147.3358 seconds, with 60-frame blocks at 16.2473–19.6443.

Raw measurements, confirmation JSON and build/native logs are retained locally
under `out/astro-oct15-*` and `.codex-astro15-*`; they are diagnostic artifacts,
not repository assets. Independent process results are not cumulative speedups.

## Final confirmation and installed runner

Candidate 113 uses the timeline counter as a readiness hint during bounded
polling. A successful hint still performs the real Vulkan semaphore wait;
errors propagate and the existing time/iteration bounds retain a blocking
fallback. This follows the distinction between
[querying the counter](https://docs.vulkan.org/refpages/latest/refpages/source/vkGetSemaphoreCounterValue.html)
and [waiting for the semaphore](https://docs.vulkan.org/refpages/latest/refpages/source/vkWaitSemaphores.html).
All **573 GPU/Vulkan tests**, four filtered Debug tests, and native host-transfer
and resource-worker probes passed with synchronization validation.

The four-way comparison ran 660 frames per mode. The new polling path alone
measured 18.0212 FPS against 17.7787 FPS for the previous wait loop. It completed
66 waits inside the polling interval; remaining waits kept the normal fallback.
The separate Windows timer-policy experiment did not establish an improvement.
The process's original policy was restored before confirmation; no timer-policy
change was added to the runner.

The uninterrupted **2,640-frame confirmation measured 18.0451 FPS** over
146.2998 seconds. These are presented title frames with retained caches,
1920×1080 host output and a game-controlled 3840×2160 source, on a Ryzen 7 7700
and RTX 3070 Ti. Compilation, native tests, captures and CPU profiling were
outside the timed interval. The screenshot was captured during warm-up.

The final log still reports **12 unresolved storage bindings per frame**, with
zero draw failures, dispatch failures and unsupported compute operations in
the sampled title intervals. Cinematic rendering defects and character control
remain unverified in this run. A clean title capture does not resolve those
limitations or establish that all shaders work.

The runner installed for this report and its PDB contained candidate 113. The executable
was signed with the existing PS5PCEM certificate and a DigiCert timestamp.
The local self-signed chain reports `UnknownError`; the expected signer and
timestamp are present. No new release number was assigned.

The [16 October follow-up](astro-bot-resource-walks-2026-10-16.md) records the
subsequent resource-walk changes and replacement local runner.

## Local reference review

The review used AnyPS5 at `c26982f63`, KytyPS5 at `9e41d832`, and sharpemu's
`2838b25806a3742814d8066a13aa70897adeeef5`. Their FPS claims are not PS5PCEM results.

AnyPS5's `1ce75da69` narrows searches to overlapping pending writes; corresponding
PS5PCEM paths already use overlap indexes. Its `26f033109` retains evaluable
branch expressions, while PS5PCEM uses a decoded instruction index. KytyPS5's
`e998f21e` reuses EXEC proof contexts across predicate graphs, which does not map
directly onto this evaluator.

sharpemu's address-rebase cache is relevant to per-draw constant arenas, but
safe reuse here must preserve changed shader values and every memory dependency.
Its command queue also waits at frame boundaries to prevent guest descriptor
and ring writes racing render recording. Repeated graphics-state suppression
and exact buffer-readback windows already exist in PS5PCEM.

AnyPS5's Windows timing code also explicitly preserves timer-resolution requests
when its window is occluded. PS5PCEM's existing audio device requests a 1 ms
period. The separate process-policy comparison above used the documented
[Windows timer policy](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation),
restored it afterward, and does not justify porting the setting as a performance
default. AnyPS5's optional worker-priority boost is disabled by default in the
reviewed tree; no realtime/high-priority process setting was adopted here.
