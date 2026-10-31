# Ghost of Yōtei: GLOBAL parameter-block recovery

Title: PPSA26344. Backend: Vulkan. Baseline: PS5PCEM 0.3.6 (`7c836bb`).

The ordinary startup run stalled at flip 1023. Compute program `0x80002d6700`
reported 2,469 unmapped snapshot words, with the first read at PC `0x9f0`
(`GLOBAL_LOAD_DWORDX4`, scalar base plus a vector offset and 236). Deferred
release publication then failed with `GuestMemoryReadFailed`; the command
queues stopped while audio continued. This was not a shader-compilation wait.

The shader uses the same entry scalar pointer for fixed-offset SMEM reads and
indexed GLOBAL reads of a small parameter block. SMEM values were prepared,
but the GLOBAL snapshot contained only the empty fault-reporting region.

The new preparation path identifies parameter roots from SMEM accesses
sharing an unchanged entry scalar pair with GLOBAL loads. It flushes previous
GPU writes and captures readable pages in a bounded 64 KiB window from each
root on every dispatch. This window is a staging limit, not a claimed guest
allocation size. It does not create guest mappings, zero-fill failed reads,
or skip the shader.
Unmapped pages split the snapshot; unknown roots and reads outside the
captured pages retain the checked fault path. The saved 1,974-instruction
shader yields a 772-byte parameter span.

An initial repeat exposed a boundary error before the first flip: program
`0x80003c8100` has indexed GLOBAL fields immediately after its last fixed SMEM
field. Capturing only the SMEM byte extent was insufficient. The page-based
revision passed that first failure, but the same kernel later failed at flip
758 when an indexed tail crossed the last SMEM page. Its AGC header declares
only two SRT words, so that field does not supply the dynamic table's extent.
The bounded-window revision covers the tail without guessing its contents or
committing memory; unreadable pages remain holes. It also reuses the existing
immutable scalar-definition cache: the local
100-query probe took 586,467 microseconds without that cache and 282
microseconds after warming it. These are CPU analysis timings, not game FPS.

Validation before the repeat run:

- The captured-shader metadata probe passes.
- All 164 focused metadata/provenance tests pass in ReleaseSafe, including
  pointer clobbers, branch joins, dynamic offsets and excessive extents.
- The GPU test build/run completes successfully.

The bounded-window repeat passes the earlier failures before the first flip
and at flip 758, and continues past the baseline's flip 1023. The original
faulting program is present in the repeat's translation cache. At flip 1179,
587,354 compute dispatches and 160,105 draws had translated without a reported
draw, dispatch, flip or synchronization failure. Captures show the Digital
Deluxe bonus notification and then a dark transition. Character control and
a sustained gameplay FPS improvement are **not yet verified**.

## Pipeline reuse follow-up

Loading still incurs substantial cold driver compilation. At flip 880,
211 compute-pipeline misses consumed 215,759 ms of a 221,403 ms frame. A cache
snapshot contained 487 translations for 389 program prefixes; one program
had 22 resource variants. These are loading costs, not steady gameplay FPS.

The next build keeps metadata descriptors at the high end of the storage
bank, separate from ordinary buffers allocated from its low end. Changing
candidate counts no longer automatically renumbers every later metadata
descriptor. Both allocation paths share occupancy and retain exhaustion
checks; no extra descriptor capacity is assumed.

Runtime buffer lookup candidates also retain one translation-key entry per
instruction site. The complete candidate list is still validated before a
cache hit. Only the first binding supplies generated code; the remaining
descriptor choices come from the live lookup table. Tests compare cached
SPIR-V byte-for-byte with fresh translation for changing candidate counts
and reject malformed secondary candidates.

- All 268 Vulkan backend tests pass, including sparse occupancy, interleaved
  allocation and full-bank exhaustion.
- All 317 RDNA2 tests pass in ReleaseSafe, including the candidate-count reuse
  and fresh-translation comparisons.
- Runtime validation of these two additional reuse changes is pending.

## Reviewed upstream contributions

Five commits from `kleinergoo7/PS5PCEM` were cherry-picked with authorship
preserved: `cf6daec`, `21f25a4`, `181d48c`, `13d7f01`, and `d717347`.
They add opt-in thread-name tracing, restore rejection of unsnapshotted
absolute FLAT reads, update shader assertions to the current lowering, and
use a wall-clock deadline for deferred APR tests. The resulting tree passes
all 316 RDNA2 tests in ReleaseSafe and all 25 APR tests in ReleaseFast.

`bc712a0` (commit reserved GPU memory on demand) is not included. A reserved
virtual range is not evidence that an arbitrary GPU read should create its
backing. The read hook is also used for speculative resource discovery;
automatically committing zero-filled pages there can conceal missing
mappings or bad descriptors. A per-access 512 MiB limit does not bound
cumulative commitment. This needs a demonstrated guest mapping/lazy-commit
contract and coverage of aliases, holes, context ownership and memory budgets
before it can become default behavior.
