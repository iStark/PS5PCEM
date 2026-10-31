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

The new preparation path derives a bounded block extent from SMEM accesses
sharing an unchanged entry scalar pair with GLOBAL loads. It flushes previous
GPU writes and captures real guest bytes on each dispatch. It does not create
guest mappings, zero-fill failed reads, or skip the shader. Unknown roots and
reads beyond the captured extent retain the checked fault path. The saved
1,974-instruction shader yields one 772-byte parameter region.

Validation before the repeat run:

- The captured-shader metadata probe passes.
- All 163 focused metadata/provenance tests pass in ReleaseSafe, including
  pointer clobbers, branch joins, dynamic offsets and excessive extents.
- The GPU test build/run completes successfully.

The repeat game run is pending. Reaching character control and a sustained
gameplay FPS improvement are **not yet verified** by this change.
