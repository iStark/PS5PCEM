# ASTRO BOT: conditional sampler recovery — November 1, 2026

Follow-up to the [packed-copy measurements](astro-bot-linear-copies-2026-11-01.md).
The title is PPSA21564 v01.018.000, tested on Vulkan with the internal 1080p
profile and a Ryzen 7 7700 / RTX 3070 Ti.

## Failure and evidence

The crash-site profiles report one rejected draw with `UnsupportedSampledImage`.
Its pixel program is `0x500a38f00`, with `image_sample` at byte offset `0x854`.
Image recovery succeeds, but sampler `s0:s3` has two reaching definitions:
an SRT load at `+0x500` and a conditional replacement at `+0x510`. The decision
comes from a scalar comparison of a constant-buffer word. Static origin
analysis correctly refuses to pretend these are a single writer.

A private post-failure capture contains distinct sampler records. The ordinary
resolver returns false on that capture; the new branch-aware replay recovers
`00007000 00fff000 0a503f00 00000000`. The snapshot was read from the running
process after the log entry, not atomically at the draw. It proves the recovery
case, not the visual result or the exact state of the original rejected draw.
Game shader and memory blobs are not distributed with this report.

## Implementation

The Vulkan sampler path first uses the existing static resolver. On failure,
it can prove SCC comparisons from actual scalar producers and current checked
memory reads. Only branches whose alternatives can reach the requested
resource are considered. Outer guards are retained; this does not skip draws
or declare resource instructions inactive.

The temporary graph belongs to one recovery. It never enters the persistent
definition cache, and branch proof does not borrow a representative snapshot's
intermediate loop values. Unknown, clobbered or wave-dependent conditions
remain unresolved. The fallback also refuses programs with stores, atomics
or GDS accesses: without an alias proof, their own writes could invalidate
the host-side predicate snapshot. Bounds on graph size, scalar recursion and work remain
explicit. The diagnostic `uniform_resource_branch_recovery` switch permits
same-process comparison; the normal setting is enabled.

## Validation so far

- The complete ReleaseFast runner build passes **21/21 steps and 603/603 tests**
  (332 GPU and 271 Vulkan).
- Synthetic checks cover both SCC branch polarities, changing predicates and
  sampler contents, direct and constant-buffer predicate loads, unavailable
  memory, unknown/clobbered SCC, wave-dependent control, outer guards,
  loop-carried values, memory-writing shaders and persistent-cache isolation.
- Offline replay of the privately captured shader and resource inputs changes
  sampler recovery from failure to success.
- The new runner reaches the normal title screen. Recent title profiles report
  zero failed draws/dispatches and the existing 12 unresolved storage bindings.
  Returning to the crash site requires menu confirmation; live validation of
  the sampler fix is pending. No corrected gameplay image or FPS gain is
  claimed from the replay alone.

The runner SHA-256 is
`99671a3abe94a881b4d078ef6434e4bd8464279f6c0eef1c80f22b83396fbb99`.
An initial compiler running beside the game was deliberately stopped below
2 GiB of host commit headroom. After recording the four copy intervals and
closing that owned test run, the complete build finished successfully.
The ordinary `zig-out/bin/game-run.exe` and its PDB are updated to that build.

One separate 30-second opening-cinematic interval in the preceding runner
measured 247 flips/presents in 30.000479 seconds, **8.23 FPS**. This moving
sequence is not comparable with the stationary crash-site gameplay results.
