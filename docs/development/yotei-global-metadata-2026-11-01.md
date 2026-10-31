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

The new preparation path derives a bounded parameter span from SMEM accesses
sharing an unchanged entry scalar pair with GLOBAL loads. It flushes previous
GPU writes and captures the containing readable pages on each dispatch. It
does not create guest mappings, zero-fill failed reads, or skip the shader.
Unmapped pages split the snapshot; unknown roots and reads outside the
captured pages retain the checked fault path. The saved 1,974-instruction
shader yields a 772-byte parameter span.

An initial repeat exposed a boundary error before the first flip: program
`0x80003c8100` has indexed GLOBAL fields immediately after its last fixed SMEM
field. Capturing only the SMEM byte extent was insufficient. The page-based
revision addresses this without guessing array contents or committing memory.
It also reuses the existing immutable scalar-definition cache: the local
100-query probe took 586,467 microseconds without that cache and 282
microseconds after warming it. These are CPU analysis timings, not game FPS.

Validation before the repeat run:

- The captured-shader metadata probe passes.
- All 164 focused metadata/provenance tests pass in ReleaseSafe, including
  pointer clobbers, branch joins, dynamic offsets and excessive extents.
- The GPU test build/run completes successfully.

The repeat game run is pending. Reaching character control and a sustained
gameplay FPS improvement are **not yet verified** by this change.

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
