# Goat Simulator 3: gameplay verification — October 13, 2026

PPSA04158 v01.000.000, development build `d5bb195`, RTX 3070 Ti,
1920×1080 requested output, Speed preset, Performance system preference,
keyboard input. Existing caches were retained. The game controls its internal
resolution; this run reports render targets up to 3200×1800.

## Verified gameplay and capture

**In-game · inverted image and low performance.** The introduction completes
and hands control to the goat at the farm. The compass, movement tutorial and
Goat Castle objective are visible. A keyboard W press moves the goat forward;
both the changed position and the guest's left-stick input are verified.
The emote wheel and pause menu also respond. Camera control was not verified:
Alt+Right opened the emote wheel during this check.

![Goat Simulator 3 controllable farm scene with goat, compass and Goat Castle objective, vertically inverted](../images/goat-simulator-3-gameplay-2026-10-13.jpg)

The capture is an unmodified game-window screenshot after movement, not the
preceding cart cinematic. The entire scene and HUD remain vertically inverted
after closing the pause menu. Menu transitions also show repeated subframes;
shading and character-material artifacts remain. No playable/completable grade
is assigned. Audio quality, save reload, multiplayer, later missions and
long-session stability were not verified.

With the goat stationary at this spot, **30 window-counter readings over
30.011 seconds measure 1.8 FPS median, 1.7–1.8 FPS range**. No build or test
process was launched during the sample. This is one local scene, not a
whole-game average or a comparison against a previous build.

At gameplay flip 3180, the profile reports 563 ms per frame, including
3116 draws/321 ms and 100 dispatches/70 ms, 292875 KiB of uploads and
112150 KiB of readbacks. The periodic gap counters still report 72 unresolved
storage bindings, even though draw/dispatch failures are zero in that frame.

## Startup and new-world creation

The full installation now contains `goat2/content/paks/goat2-ps5.pak`.
The earlier test only had the backport executable and modules. The existing
runner resolves the previously missing `sceVoiceQoSSetConnectionAttribute`
import (`KCGOxg8iX7s`, added in `399cc07`). VoiceQoS still reports offline;
this test selects **No** at the online-mode prompt and uses local single-player.
No new firmware implementation or game-specific patch was added for this run.

The main menu responds to keyboard Cross. Play → Start a New Save enters
world loading and writes nonempty player and world-save files. This verifies
file creation, not successful save reload or long-term persistence.

The initial menu is vertically inverted, with briefly repeated subframes
during transitions. The illustrated loading screen has the correct orientation.
Initial menu observations around 6 FPS are not a sustained gameplay benchmark.
The long new-world load eventually reaches the farm-cart introduction, about
12 minutes after process launch in this run. The farm initially renders upright;
opening and closing the pause menu also leaves the subsequent scene inverted.

## Rendering diagnostics

The log repeatedly rejects a `512×512×1024`, format-5, `color_3d` storage
image at `0x2032780000` as `UnsupportedStorageImage`; affected dispatches
are skipped. Periodic GPU-gap reports also contain 72 unresolved storage
bindings. Zero draw-failure counters do not establish complete or correct
rendering. These gaps remain open.

World preparation includes thousands of draws per frame and substantial
buffer/texture transfers. At flip 2280, the reported frame time is 644 ms:
3281 draws take 370 ms, 341 dispatches take 91 ms, uploads total 284812 KiB
and readbacks 113133 KiB. That frame has no pipeline-cache misses, so the
remaining cost is not solely first-use shader compilation. This is a loading
observation, not a benchmark of controllable gameplay.

The unchanged ReleaseFast runner has SHA-256
`184C9D96FB1B325637047652C359BC9C801DD5CC088A812FBBB4467289E844E4`.
No release package was produced.
