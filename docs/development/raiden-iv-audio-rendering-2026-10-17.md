# Raiden IV: NGS2 audio and rendering costs, 17 October 2026

PPSA08832 v01.000.000 reaches the first OverKill level on the RTX 3070 Ti
development host. Output and the largest observed internal target are
1920×1080. This is an unreleased development build after v0.3.5.

The maintainer requested the **Playable · Completable** grade. This development
check covers the first level, death and continuation; it does **not** establish
a completed playthrough or long-session stability.

![Raiden IV first-level gameplay with the player ship, enemy formation, bullets and HUD](../images/raiden-iv-gameplay-2026-10-17.png)

The native renderer capture is frame 57280 of the third candidate, taken after
the timed interval. It shows active gameplay at a score of 14000, without a
pause or continue overlay. No generated imagery or replacement game assets
were used.

## Audio

The game allocates 1,024 sampler voices before requesting its master voice.
The previous global 1,024-voice pool could not accommodate that master, and the
game tore down the audio system. Voice storage is now allocated per active
rack, retaining each rack's own limit and reusing released voice entries.

NGS2 sampler voices can decode ATRAC9 through the existing codec implementation.
Compressed blocks remain borrowed; decoding retains a bounded superframe,
resampling window and current output grain. Preroll, finite/infinite repeats,
pitch, compressed chunk boundaries and data-only continuation are handled.
Each grain is decoded once and mixed into the output buses. In-memory RIFF
parsing now preserves the ATRAC9 configuration, as file parsing already did.

Nonzero decoded effect samples were observed, and the user confirmed audible
menu-button sounds. The user reports music only around death: **normal menu
and level background music remains incorrect**. The empty music stream requires
further investigation. This is a partial audio fix, not complete NGS2 support.

## Rendering

- Consecutive compatible draws retain their Vulkan render pass. Changes of
  framebuffer or render area, clears, uploads, transfers and compute commands
  close it. Programmable-blend feedback retains the separate-pass path.
- Typed sampled-image banks use update-after-bind only when the device feature
  and full stage, set and pool limits allow the existing descriptor capacity.
  Fence ownership is unchanged; in-flight slots are not overwritten. Devices
  with insufficient limits keep the previous path.
- A known uniform depth fill publishes its known value without rescanning the
  filled bytes. Arbitrary memory writes keep the checked path.
- Repeated identical register writes keep immutable snapshot banks. First
  writes of zero, changed values and register clears still invalidate them;
  the register-write statistic still counts every write.

No draw, dispatch or shader is intentionally omitted by these changes.
Checked gameplay profile frames report zero draw failures, dispatch failures,
unsupported compute operations and unresolved storage bindings.

## Measurements and remaining costs

Candidate 3, with retained passes and update-after-bind, produced **1,193 frames
in 30.013 seconds: 39.75 FPS**. One-second intervals range from **24.99 to
63.97 FPS**. This is a moving first-level interval; later heavier combat was
observed at approximately **18–22 FPS**. **Sustained 60 FPS is not achieved.**
Compilation, CPU sampling and frame capture were outside that timed interval.

Candidate 2 measured 750 frames in 30.013 seconds, or 24.99 FPS, in another
moving interval. Different scene phases prevent treating these two results as
a controlled before/after comparison. Candidate 3 does not yet contain the
identical-register snapshot change included in the final build.

Native CPU sampling shows the descriptor-bind hotspot substantially reduced;
command-state copies, scalar resource evaluation and buffer preparation remain.
A later heavy frame submits 1,530 draws in 51 ms, with about 37 ms in draw
processing and 2 ms in fence waits. Further work must address the CPU path as
well as GPU synchronization.

## Validation

The audio candidate passes 685 HLE tests; the snapshot change passes 309 GPU
tests; the renderer candidate passes 275 Vulkan tests, all in ReleaseFast.
The native retained-pass probe passes eight combinations of timeline mode,
retention and descriptor mode. Descriptor-reuse probes pass 14 cases across
the previous and update-after-bind paths. Vulkan synchronization validation
reports no errors in these probes. Raw depth-clear and multisample depth-pass
checks also pass.

ASTRO BOT was not launched during this Raiden investigation. Its previously
prepared October 16 changes and report are retained separately in the source
history.

## Installed build and publication checks

The final combined build passes **21/21 build steps and 1,269/1,269 tests**:
685 HLE, 309 GPU and 275 Vulkan tests. All five native probes above pass again
on the final build with synchronization validation, including the additional
guard against retaining a pass while an extra color attachment needs uploading.
The website passes 145 tests, TypeScript checking and lint.

`zig-out/bin/game-run.exe` and its matching PDB are updated. The executable is
signed with the existing PS5PCEM certificate and a DigiCert timestamp;
`osslsigncode verify` succeeds with the project's signer certificate and the
system timestamp trust store. Windows still reports the existing self-signed
root trust limitation. SHA-256:

- EXE: `0262487840EFAD36B0C8F2F33FA658FB615A65262F7CA2F9CF1619D700D63A2B`
- PDB: `4D935197F0A77AB799E3687CDB46B6425F4D1331E0C8A5ECF5CC61ADD0B16820`

The installed executable starts Raiden and produces frames. Further UI-driven
verification was stopped by the user's Escape key, so the published gameplay
capture and timed result remain those of candidate 3, as identified above.
No release tag is assigned and no final-build gameplay FPS claim is added.
