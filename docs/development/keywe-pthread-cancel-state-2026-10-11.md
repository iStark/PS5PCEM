# KeyWe startup — October 11, 2026

Title: PPSA02210, content version 01.000.000. Development build.

**October 30 follow-up:** save-slot creation and reload now work, and the opening
tutorial renders. The maintainer confirms **Playable · Completable**. See the
[current report and captures](keywe-save-slots-2026-10-30.md); the observations
below describe the earlier October 11 build.

## Missing import

Unity's `Media/Modules/Il2CppUserAssemblies.prx` requested
`lZzFeSxPl08` from `libScePosix`. This is `pthread_setcancelstate`, confirmed
against the local KytyPS5 export table and PS5PCEM's NID hash. The guest call
sites disable cancellation with state 1 and save the previous value, then
restore that value with a null output pointer.

The implementation follows the state transition and argument rules in
[FreeBSD's thread cancellation implementation](https://github.com/freebsd/freebsd-src/blob/main/lib/libthr/thread/thr_cancel.c).
The local KytyPS5 and AnyPS5 trees provided additional reference points.
No title-specific bypass or successful no-op import was added.

## Implementation and validation

Each guest pthread starts with cancellation enabled and owns its own state.
`pthread_setcancelstate` accepts enabled (0) and disabled (1), returns the old
value through optional guest storage, and preserves the state on invalid
arguments or unwritable output. The guest write goes through address-space
validation and write notification. The export is registered in both
`libkernel` and `libScePosix`; `scePthreadSetcancelstate` shares the operation
with kernel-style error results.

This implements cancellation-state management, **not cancellation delivery**.
`pthread_cancel` and `scePthreadCancel` continue to report unsupported; the
runtime does not accept a request it cannot deliver. There can therefore be
no pending cancellation to act on when cancellation is re-enabled.

All **629 HLE tests pass** in ReleaseSafe with `PS5_INPUT_MODE=scripted` to
isolate them from physical controller input. New coverage checks old-state
round trips, independent guest threads on the same host thread, enabled
defaults, null output, invalid state, protected output, unchanged state after
failure, and both export-library registrations. An initial unrestricted run
passed 628 tests but failed an existing neutral-stick assertion (129 instead
of 128); the isolated rerun passed without changing input code.

## The next dependency: Audio3d

With Unity's import resolved, the loader then reported seven missing
`libSceAudio3d` functions in `eboot.bin`: initialize, terminate, port open,
port close, object reserve, object attributes and port flush. This was a
second link blocker, not a successful game launch.

KytyPS5 and AnyPS5 provide port-lifetime references but do not supply this
title's object-PCM playback. The public shadPS4
[ABI declarations](https://github.com/shadps4-emu/shadPS4/blob/main/src/core/libraries/audio3d/audio3d.h)
and [implementation](https://github.com/shadps4-emu/shadPS4/blob/main/src/core/libraries/audio3d/audio3d.cpp)
were additional references for layouts and flush behavior. **PS4 attribute
numbers cannot be copied directly:** the PS5 executable writes position
attribute **3** (12 bytes) and gain attribute **5** (float 1.0) at
`eboot.bin:0x163c3d8..0x163c476`; PCM remains attribute **1**, with a 24-byte
descriptor. Its mixer submits separate planar float channels and then flushes.

The new implementation owns those PCM samples in bounded per-object queues,
validates complete attribute batches before committing them, and mixes all
objects in a quantum together into stereo. Position controls an equal-power
left/right approximation; gain is applied before final saturation. S16 and
float PCM are supported. Nonfinite samples become silence. Ports have separate
host devices and flush ordering; metadata locks are released before playback
waits. Runtime reset and port close release the queues and host devices.

This is **partial Audio3d support**, not console-equivalent spatial audio.
HRTF, room acoustics, bed writes, extra attributes and explicit advance/push
APIs remain unsupported. Open accepts the observed buffer mode 2 and two-bed
configuration; other modes fail explicitly. Six additional tests cover port
capacity/lifetime, owned planar PCM, simultaneous stereo mixing, gain, invalid
batch rollback, bounded FIFO queues, close/reopen cleanup, NaN/Inf and
saturation, plus all seven import registrations.

## Runtime result and remaining blocker

The final ReleaseFast runner passes linking on **two launches**. The first
uses scripted Cross input, renders the Stonewheat & Sons and Sold Out screens,
and reaches the `SAVE SLOT` panel with `Select` and `Delete` prompts. Its
captured slot cards are empty against a black background. After automatic
confirmation, the image turns black while frame submissions continue.
A second launch with keyboard-only input also passes the logos and reaches
a black screen without any automatic button presses. The cause of the black
image is **not yet established or fixed**; gameplay is not verified.

The first run has **26** periodic GPU-gap reports, the repeat **32**; all six
counters are zero in each report. Neither records a guest fault or a missing
sampled-image diagnostic. These counters do not establish correct rendering:
the black output is still visible. Both tests were stopped after inspection.

The save-slot screenshot reads **8.1 FPS** on RTX 3070 Ti with 1920×1080 output
and a reported largest internal target of 1920×1080. This is a single window
counter reading, **not a timed benchmark or a gameplay performance result**.
Later black-output frames are roughly 122–126 ms, with about 1,610 draws,
50 native dispatches and 1,020 emulated dispatches per frame. These are useful
diagnostics, but rendering performance cannot be judged as playable while the
image is missing.

The live run opens the existing 48 kHz stereo float AudioOut stream, **not the
new Audio3d object stream**. Audio3d import resolution and unit behavior are
verified; its audible playback in this title is not. Audio quality, manual
navigation, saves, completion and long-session stability remain unverified.

![KeyWe save-slot selection with empty panels and a black background](../images/keywe-save-slots-2026-10-11.jpg)

Validation: all **635 HLE tests pass**, `zig fmt --check` and
`git diff --check` pass, and `build-game-run -Doptimize=ReleaseFast` succeeds.
The installed `zig-out/bin/game-run.exe` contains both changes. This local
development binary is unsigned; the earlier signing attempt was rejected by
automatic approval with `blocked by policy`, and no alternative signing path
was attempted.

Runner SHA-256:
`798263b7e66f498cf9d14de6b93a352030e0c44cca3bdc7d34601c5db5297287`.
