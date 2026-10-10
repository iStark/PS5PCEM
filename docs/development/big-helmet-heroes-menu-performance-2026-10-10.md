# Big Helmet Heroes: menu performance and resource coherence

October 10, 2026 development checkpoint, PPSA19943 v01.000.400.

The stationary main menu improves from **4.9 FPS** on the previously installed
runner to **9.4 FPS** on the final validation candidate. **The requested stable
15 FPS is not achieved.** This checkpoint preserves the work at the maintainer's
request; it does not upgrade the game's compatibility grade.

![Menu with characters, labels and dense orange grass](../images/big-helmet-heroes-menu-performance-2026-10-10.png)

## Measurement

AMD Ryzen 7 7700, NVIDIA RTX 3070 Ti, Windows, 1080p output request, Speed preset,
Performance game preference and normal audio. Internal resolution remains
game-controlled; the menu binds targets up to **2848 × 1600**. Shader caches are
warmed. Builds and native GPU tests are stopped during measurements.

| Run | Window-counter median | Observed range | Interval |
|---|---:|---:|---|
| Previously installed runner | 4.9 FPS | 4.7–5.1 FPS | 45 one-second samples in the stationary menu |
| Final validation candidate | 9.4 FPS | 9.0–9.5 FPS | 45 one-second samples, after 120 seconds of process uptime |
| Signed installed runner, default GPU settings | 9.4 FPS | 7.4–9.8 FPS | 45 one-second samples, after 120 seconds of process uptime |

All 45 candidate samples are below 15 FPS. These are samples of the window's
rolling counter, not per-frame percentiles or a gameplay minimum. The capture
is taken separately and its instantaneous counter is not the benchmark result.
Intermediate candidates reached 9.6 FPS; the final candidate includes the
stricter sparse-readback snapshot validity check and cached volume snapshots.
The installed repeat uses the same backend with the measured defaults built
into the normal launch, without GPU environment overrides or live edits.
Its window was covered by another desktop application at the final capture;
this is a default-launch check, not a controlled foreground comparison.
All 45 installed-run samples are also below 15 FPS. The published image is
the separately inspected candidate capture, not the occluded desktop capture.

Seven periodic profiles within the candidate interval have median values of
112 ms reported frame work, 90 GPU submissions, 20.21 ms fence waits,
84,494 KiB uploaded and 38,589 KiB read back per frame. Render-target readback
alone remains 24,918 KiB. Transfers, resource preparation and synchronization
remain the next performance targets; individual cost reductions do not imply
an equal FPS increase.

## Changes

- Preserve unconsumed buffer write ranges after partial publication. Track the
  highest executed write for eligible large DWORD, typed and subword stores
  using private GPU counters; inactive and out-of-bounds lanes do not extend
  the range. Copy only proven pending spans after completion, preserving CPU
  tails and gaps. Unsupported or ambiguous writers retain the full fallback.
- Keep compatible layered render targets and 3D sampled/storage views on the
  GPU. Validate their native layout, formats, generations and aliases before
  copying, and reuse bounded sampled volume snapshots while the source is
  unchanged. Batch disjoint mip publications sharing one backing allocation.
- Parallelize large volume conversions and changed-page publication, with
  completion joined before exposing guest-visible results. Reuse equal backing
  proofs only for compatible views and arm CPU page watches before checking.
- Avoid redundant intermediate host copies, diagnostic texel scans and page
  queries. Recognize strictly bounded constant fills and preserve live GPU
  attachments across emulated fills. Retire deferred releases and query
  counters without adding an unconditional wait per packet.
- Use four copy participants, image-state tracking, synchronous command
  decoding and a 1 ms asynchronous recording-age bound for PPSA19943. The bound
  submits existing work; it does not omit draws or change guest timing.
  `PS5_GPU_COMMAND_BATCH_US=0` restores unlimited recording age for comparison.

Shared correctness changes apply beyond this title; the measured scheduling
defaults are selected for PPSA19943. No game executable or asset is patched.

## Rendering checks and limits

During the candidate measurement, all seven reports show zero draw failures,
dispatch failures, unsupported compute programs and unresolved/null/rejected
storage resources. This establishes no recorded failures in that interval,
**not universal shader coverage or freedom from visual bugs**.

An intermediate overwrite-discard optimization removed orange grass despite
zero failure counters. Repeated same-process comparisons isolated it to
discarding cached storage images that held a live stencil snapshot. That
storage-image discard path is excluded from this checkpoint. Dense grass,
character models, lighting and menu labels are visible again in cold and warm
captures; valid buffer and color-target discard paths remain enabled.

Native Vulkan checks cover layered volume copies and reuse, tracked DWORD and
subword writes, empty EXEC masks, exact CPU-tail preservation, constant fills,
depth/stencil storage, mip-tail padding and CPU replacement. The automated
GPU, shader translation and Vulkan suites are also run for this checkpoint:
Vulkan **240/240** and GPU **260/260** pass. The shader suite reports
**271/281**, with the same ten failing tests and failed-expectation allocation
leak reproduced on the unchanged parent commit `1bd3675` in an isolated
checkout. Those existing failures are not presented as passing validation.
Native layered-volume and tracked-buffer-write probes pass on the final
backend. Website type checking and all 44 localization/compatibility-data
tests pass. Three targeted HLE publication tests pass as well, including
unaligned endpoints, page-watch preservation and joined worker completion.

The local `zig-out/bin/game-run.exe` and matching PDB are rebuilt. The runner
is signed with the existing Artur Strazewicz / PS5PCEM certificate and a
DigiCert timestamp. Its SHA-256 is
`4523a4a1e4814f7d6974f1fe945ce074d071d04e4f504191813080fe7b0a9b3f`.
The certificate is self-signed; the host still reports an untrusted root.
This checkpoint updates source and the local runner, not a GitHub release asset.

This session tests the menu. Tutorial measurements from September 29 remain
historical; gameplay, save recovery, completion and long-session stability are
not newly verified. The original local saves are preserved. Public release
0.3.4 predates these changes.
