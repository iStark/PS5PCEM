# CPU resource preparation workers, 2026-09-25

Historical first implementation and measurements. The subsequent shared-queue
and adaptive admission changes are described in
[adaptive-cpu-workers-2026-09-25.md](adaptive-cpu-workers-2026-09-25.md).

This follow-up adds a graphics resource-preparation pool separate from the
existing graphics/compute command processors and pipeline compiler. It is
generic renderer code, with no title-specific eligibility checks.

## Work and ownership

`PS5_GPU_RESOURCE_WORKERS` selects zero, one or two helpers (default two).
The pixel and vertex stages have independent worker slots and scratch pools.
Shaders with fewer than 256 indexed scalar steps stay on the owner thread.
For sampled stages, the normal sampled checkpoint walk captures the bytes it
actually reads. A helper then calculates the full scalar state and storage
checkpoints while the owner resolves and stages textures. Stages without
samples can offload storage checkpoints after the normal scalar evaluation.

Workers receive immutable instructions, copied stage bindings and draw-local
memory snapshots. They never access live guest memory or Vulkan. The owner
validates bytes through the normal memory reader before consuming a result,
including any required publication of GPU-written metadata. Missing reads,
inconsistent captures, changed bytes and worker errors retain live serial
preparation. Instruction identity and binding identity must match. Workers
join before draw-local bindings or shader plans are released, including early
returns. Their scratch allocation and teardown are independent of the renderer
allocator. Small jobs and thread creation failures remain synchronous.

This moves scalar/resource-state calculation; buffer/image allocation,
descriptor writes, command recording, submission and GPU completion remain on
the owner thread. Compute resource staging is unchanged. It does not distribute
the whole renderer across all CPU cores or remove required GPU waits.

## Rejected first implementation

The first build captured the full scalar walk early, then ran both checkpoint
walks on helpers with a 64-step threshold. It performed unnecessary validation
and queued jobs too small to amortize their handoff cost. In the Jets 'n' Guns 2
menu, the same executable measured 28 ms median frames with helpers versus
27 ms with helpers disabled. CPU draw work was 13 versus 11 ms. The animated
menu uses about 79 draws per sampled frame; this is a menu comparison, not a
gameplay FPS claim. The helper really ran, but more active threads did not make
the frame faster.

The revised implementation captures the already-required walk at its ordinary
location, moves subsequent calculations to the helper, and leaves small work
inline. The initial result is preserved in
`out/resource-workers-20260925/comparison-initial.json`; raw logs, thread/GPU
samples and screenshots are in the neighboring run folders.

## Validation

Unit coverage compares serial and worker checkpoint/register output across
branches and changed inputs, asserts guest reads remain on the owner thread,
rejects changed or incomplete snapshots, and exercises active-job reuse,
disabled/small-job fallbacks and shutdown with pending work.

The `vulkan-smoke --resource-workers` probe compares expected pixels with zero
and two helpers, changes textures and scalar constants, and checks reused
T#/S#/V# register lifetimes. It also exercises fragment storage writes and
attachment feedback before returning. The unrelated later `IndexedCopyMismatch`
failure was observed in both the ordinary broad smoke mode of the first build
and its forced-worker broad run; the dedicated resource probe stops after its own
graphics checks. This does not claim that the entire native smoke suite passes.

The revised source passes 995 selected memory/GPU/Vulkan/HLE/CPU tests
(`tests3.log`). The dedicated native probe passes (`probe/workers-final.log`),
as do formatting and diff checks. The ReleaseFast runner was built at 19:32:17
local time, SHA-256
`E36940FDA06C715E2C265407CFDED3DD7C2D25031C3E715936DABFE4A4954213`.

In the first Quake II gameplay check, flip 3900 reports 3693 completed jobs and
7386 consumed results, with zero fallbacks. One pixel-stage helper is active;
the vertex stages in that scene stay below the threshold. Cumulative worker
time is 409 ms and owner wait time is 303 ms, roughly 0.111 ms and 0.082 ms per
job respectively. These are wall-time counters, not a measured whole-frame
speedup. The owner still does most of the frame's work. Captures show lit
weapons/hands and NPCs. Other games, including Yotei, need runtime validation;
this change does not establish a stable 120 FPS minimum.

## Final live comparison

Quake II was run with two helpers and with helpers disabled using the same
final executable, for approximately three minutes each. No automated input,
builds, tests or thread-suspension sampling ran during these measurements.
The table uses periodic frames 3000–9000 with no pipeline misses and groups
them by actual graphics draws, rather than PM4 draw packets.

| Helpers / draw group | Samples | Median actual draws | Frame | CPU draw work |
| --- | ---: | ---: | ---: | ---: |
| 0 / 0–199 | 33 | 76 | 12 ms | 6 ms |
| 2 / 0–199 | 62 | 49 | 10 ms | 4 ms |
| 0 / 200–399 | 21 | 310 | 22 ms | 11 ms |
| 2 / 200–399 | 11 | 309 | 19 ms | 10 ms |
| 0 / 400–599 | 19 | 519 | 30 ms | 16 ms |
| 2 / 400–599 | 13 | 485 | 26 ms | 14 ms |
| 0 / 600–899 | 6 | 675 | 36 ms | 19 ms |
| 2 / 600–899 | 7 | 621 | 34 ms | 18 ms |
| 0 / 900–1299 | 5 | 992 | 48 ms | 28 ms |
| 2 / 900–1299 | 3 | 978 | 39 ms | 20 ms |

The demo contents, sample counts, uploads and GPU clocks differ between runs.
These are not identical-frame benchmarks, and the table does not establish
that the new worker caused the entire frame-time difference. The measured
helper workload is small relative to total frame time. Required completion
waits and the owner's resource staging remain major costs.

Jets 'n' Guns 2 was then restarted with the final build and two configured
helpers. Its menu shaders stay below the revised threshold, so no preparation
jobs are launched there. Across 41 periodic samples at flips 600–3000, median
frame time is 27 ms and CPU draw work is 11 ms, matching the earlier disabled
control's 27/11 ms and removing the first implementation's 28/13 ms penalty.
This verifies the small-job fallback; it is not a Jets gameplay speedup.
The final menu capture is `jets-final2/client-194030.png`; the Quake gameplay
capture is `quake-final2/client-193319.png`. No host-panic, contained-fault,
rejected-packet or device-loss markers were found in these final run logs.
Jets is left running on the fresh executable for manual gameplay testing.
