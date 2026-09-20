# COPY_DATA review

Review of `c72fd4a73a5b1679226b5aa0ce8331313edefec0`, September 20, 2026.

The registered DCB/ACB writers and 24-byte size queries are retained. The review
corrects two execution bugs and strengthens the tests of memory visibility.
Before that commit, COPY_DATA emitted a 16-byte NOP and its size query also
returned 16 bytes. The move to 24 bytes belongs to implementing the operation;
this pair did not previously underreport the size of its own NOP writer.

## Corrections

- **Decode PM4 selectors independently of engine selection.** The DCB writer
  already separates the guest selector into a hardware field and control bit
  30. Recombining them in the executor misclassified a memory source selected
  through PFP as GDS. Source and destination enums also differ: destination 5
  denotes memory, while source 5 denotes an immediate. The decoder now keeps
  these fields separate. The DCB and ACB guest ABIs are unchanged.
- **Read current data through the scheduler.** An ordinary backend read can
  return a retained command-allocation snapshot. COPY_DATA now uses an optional
  `read_live` callback, forwarded through `SnapshotBackend`, with the ordinary
  backend read as its fallback. It bypasses both snapshots and the synthetic
  values used to recover blocked waits. The existing Vulkan read/write callbacks
  retain their synchronization, cache invalidation, and metadata handling.

Selector definitions were checked against AMD PAL's public packet headers:
[ME](https://github.com/GPUOpen-Drivers/pal/blob/dev/src/core/hw/gfxip/gfx9/chip/gfx9_plus_merged_f32_me_pm4_packets.h),
[PFP](https://github.com/GPUOpen-Drivers/pal/blob/dev/src/core/hw/gfxip/gfx9/chip/gfx9_plus_merged_f32_pfp_pm4_packets.h), and
[MEC](https://github.com/GPUOpen-Drivers/pal/blob/dev/src/core/hw/gfxip/gfx9/chip/gfx9_plus_merged_f32_mec_pm4_packets.h).
Kyty's reconstructed compound selector mapping is not used as the hardware enum.

## Verification

- Two added tests failed before the correction: reading a changed source inside
  a retained command allocation, and memory copies with alternate engine and
  destination selections. Both pass after the correction.
- Additional coverage checks that synthetic wait values cannot become copied
  data, malformed/truncated packets and memory failures cannot modify the
  destination, and registered writers produce independently specified PM4 words.
- HLE: **461/461**. GPU: **208/208**. Full suite: **1263/1274 passed**, one skipped,
  ten failed. The ten `rdna2` SPIR-V failure names match the unmodified review
  baseline; that module also reports its existing test allocator leak.
- The Vulkan probe now dispatches real translated producer and consumer shaders.
  It asserts that the source still has old CPU bytes before COPY_DATA, then
  checks 4/8-byte copies, guard words, a cached destination consumed by a later
  shader, and a 64-bit immediate with different halves. It passes with timeline
  scheduling and deferred storage readback enabled.

Run the isolated probe with:

```powershell
zig build vulkan-smoke -Doptimize=ReleaseFast -- --copy-data
```

The build target now forwards arguments and installs only its own executable.
No COPY_DATA register, GDS, atomic-return, or clock-source implementation is
claimed. Unsupported selectors remain counted and diagnosed without copying.

## Menu and build results

Two fresh Big Helmet Heroes launches used `PS5_INPUT_MODE=controller`, the same
saved data and warm pipeline cache, and one process at a time. Both reached the
menu; actual-window captures and 80-frame sequences matched the maintained
reference in characters, scenery, colors, and lighting. Both processes were
explicitly stopped after checking the menu. No gameplay was entered.

After background compilation finished, the second run presented 87 frames in
24.97 seconds: **3.48 FPS**, with a median interval of **284.37 ms**. This short
sample does not establish a performance improvement. Neither launch emitted a
`[gpu copy]` diagnostic; operation coverage comes from the targeted tests and
the Vulkan probe.

`zig build build-game-run -Doptimize=ReleaseFast` passed. Tested executable SHA256:
`302ca8509bfdbb4c6db3bee628b24117245c82562aaa2c08f790b685ac8ec233`.
The subsequent standard-target build has SHA256
`91150971bf59a55ef8a357a34f5484685983e83803f6f2cbe8c44e6fd5a1834c`;
all its PE sections except `.buildid` are byte-identical to the tested executable.

Local artifacts (ignored by Git):

- `out/copy-reviewed-a-bhh/` and `out/copy-reviewed-b-bhh/`: launch manifests,
  source diffs, logs, window captures, and the second run's `fps.json`.
- `out/copy-c72-regression-before.log`, `out/copy-c72-fixed-tests.log`,
  `out/copy-c72-vulkan-probe.log`, and `out/copy-c72-game-build.log`.
- `out/copy-c72-binary-comparison.json`: executable and section hashes.

The original review submission reported a third menu launch fault at guest
`rip=0x800afca20`, reading `0xffffffffffffffff`. Absence of COPY_DATA diagnostics
does not establish that this crash is unrelated to the commit. Its cause remains
unresolved and it did not recur in these two launches. Successful launches cannot
prove that an intermittent crash is fixed.
