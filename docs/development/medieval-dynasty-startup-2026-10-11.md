# Medieval Dynasty startup — October 11, 2026

Title: PPSA07933, content version **01.413.001**. This tests the existing
development runner without implementation changes.

## Observed result

The runner passes linking and engine initialization. The loading artwork
shows a campfire in a snowy forest. The main menu then appears with New Game,
Load Game, Settings and Credits. **The menu background, logo and option text
are vertically inverted.** The published capture preserves this defect;
it has not been rotated or otherwise corrected.

Scripted Cross remains active, but the run stays in the main menu throughout
the measured interval. No level is entered. This observation does not establish
the cause of the input behavior or prove that manual navigation cannot work.

## Method and measurement

RTX 3070 Ti; Speed preset, Performance system-game preference, output
1920×1080. The reported largest internal target is also **1920×1080**.
Existing caches are retained. `PS5_INPUT_MODE=scripted`, FPS display and
Pad diagnostics are enabled.

Thirty one-second window-counter readings over **29.763 seconds** give a
**32.3 FPS median**, range **28.8–33.2 FPS** in the main menu. This is not a
gameplay benchmark, a minimum across the game, or a before/after comparison.
The saved menu capture reads 30.3 FPS, before the timed interval.

Of **50** periodic GPU-gap reports, **38** have **72 unresolved storage
bindings**. Draw failures, dispatch failures, unsupported compute and
null/rejected storage counters are zero. No guest fault or missing
sampled-image diagnostic was recorded. The relation between these unresolved
bindings and the inversion has not been established.

Late menu frames take 29–30 ms, with 45 draws, 21 dispatches and roughly
9–11 ms of fence waits. Audio output has nonzero PCM peaks, but its audible
quality is unverified. Manual navigation, gameplay, saves, completion and
long-session stability remain untested. The test process was stopped afterward.

![Medieval Dynasty main menu with vertically inverted artwork and text](../images/medieval-dynasty-menu-2026-10-11.jpg)

Runner SHA-256:
`798263b7e66f498cf9d14de6b93a352030e0c44cca3bdc7d34601c5db5297287`.
