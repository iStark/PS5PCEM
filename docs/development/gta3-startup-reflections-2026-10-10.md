# GTA III: movie completion, reflection publication and shader preparation

October 10–11, 2026 — **Grand Theft Auto III: The Definitive Edition**, PPSA03527
v1.007, Windows development build. This investigation follows a report that a
launch without a warm cache remained black, while a repeat launch worked.

The movie-player fix lets both startup movies finish and advance to the menu
without input. The renderer fixes remove the observed green reflection clear
from the opening mission. This is an opening-scene validation, not a claim that
all rendering defects or whole-game compatibility have been resolved.

![GTA III opening street and HUD after the reflection fixes](../images/gta3-startup-reflections-2026-10-10.png)

Actual installed-runner capture; no image correction applied.

## Startup

Unreal supplies an opaque `file://../../../...` movie URI together with its own
file callbacks. AvPlayer now permits callback-owned names when all four required
callbacks are present; host path validation still applies to a host-file
fallback. The decoder normalizes its output frame rate to the rate reported to
the guest, and the playback clock retains its final timestamp after EOF.

The remaining hang was an event-ordering problem: a natural STOP callback from
the decoder thread made the guest suspend its media polling before observing
EOF. Natural completion now publishes STOP when the presentation thread first
observes the terminal `IsActive` status. Explicit stop retains its immediate
notification. In the controlled no-input run, the first movie ended at 22.079
seconds after process start, the second began at 27.623 seconds and ended at
122.504 seconds; the menu then appeared automatically. Movie skipping was not
used for this startup observation.

An installed, signed development runner was also started with the real launcher's
**Launch game** button after both active emulator cache paths were cleared.
The manifest confirms `--app0`, the game path and `E:\PS5PCEM` working directory.
Both movies advanced without game input; the menu was captured 139 seconds
after the click. The old cache was renamed out of the active paths for this
check; the test did not clear the GPU vendor's global cache.

[Cold-launch menu capture](../images/gta3-cold-launcher-menu-2026-10-10.png).

## Green reflection correction

Three publication issues affected the same reflection cube:

- A sampled cube could observe only the most recently published face. The
  sampled slow path now publishes every compatible selected face and mip.
- An older GPU buffer clear covering the whole allocation could publish its
  remaining bytes after newer raster faces. Exact-base buffer producers now
  complete before the initial color backing snapshot is taken.
- The final storage-image clear, targeting face 5 at mip 7, could remain dirty
  while raster rendering started. Its eventual full-allocation publication
  invalidated the newer packed-tail faces. Pending storage-image producers at
  the allocation base now complete before that baseline too.

The last issue was reproduced in a native regression by leaving the final UAV
clear pending before rendering all faces. The old path returned green `10000`
in the final face; the corrected path preserves the newer pixels. The probe
covers six faces, eight mip levels, two content revisions, 4 KiB and 64 KiB
layouts, 8- and 64-entry target caches, sampled cubes and typed UINT consumers.

An actual-game composite capture after the fix contains no sentinel-green or
non-finite texels in any of the eight sampled reflection mips. The opening
cutscene, car, street lighting and playable street view no longer show the
observed green wash or neon-green reflections.

## Shader preparation and missing-resource diagnostics

Uniform branch analysis can now evaluate bounded scalar constant-buffer loads
in read-only shaders. Unknown or inaccessible inputs retain both branches;
buffer bounds are respected, and live inputs are read again for each draw.
Resource staging and SPIR-V translation consume the same specialized program.
This removes inactive resource references rather than suppressing diagnostics
or dropping draws. The validated graphics policy is enabled for GTA III; the
implementation is shared with other renderer profiles.

The analysis retains immutable variants and bounded scratch storage. Its CFG
states keep values and knownness rather than full resource provenance. Static
eligibility and read-only metadata are reused. Temporary evaluations reset only
their live register file and counters: disassembly showed that a struct literal
otherwise copied about 48 KiB of unused load-history storage for every visited
block. Cache hits still re-evaluate guest input; they do not assume that a
constant-buffer address implies unchanged content.

The uniform proof also reuses the scalar-step index from the resource plan,
skipping vector arithmetic that cannot change scalar state. Lane transfers,
scalar destinations, implicit EXEC writes and unknown instruction families
remain in the walk. Planned and full walks are compared for changing guards,
loop masks and inaccessible inputs.

Variant lookup compares a compact per-block rewrite key. A complete instruction
array is materialized only for a new variant, rather than copied and rewritten
again on every cache hit. The proof still reads current guest inputs before
selecting the cached variant.

Resident color, storage-mip and volume paths query the existing buffer overlap
index instead of walking every retained buffer for each texture. Candidate
collisions still undergo the same exact pending-write-span test; a published
prefix does not block reuse merely because an unrelated suffix is dirty.
The mip, volume, color-initialization and cube-publication Vulkan probes pass
with this indexed path.

In the tested opening scene, periodic reports record zero draw failures,
dispatch failures, unsupported compute programs and unresolved/null/rejected
storage bindings with graphics specialization enabled. Legitimate guest
predication and proven side-effect-free work retain their normal semantics.
This audit does not cover every shader used later in the game.
The complete startup log also contains one vertex-only draw rejected before
the first frame; that initialization case is still being investigated and is
not represented by the later opening-scene zero-error counters.

## Measurements and validation

Host: Ryzen 7 7700, RTX 3070 Ti 8 GiB, Windows, ReleaseFast, warmed pipelines.
Output is 1920×1080; internal resolution remains controlled by the game
(3264×1836 is the largest allocation reported in this scene). FPS is the actual
presented-frame counter delta over 30 unpaused seconds. Builds, CPU sampling,
GPU timestamp diagnostics and capture readbacks are excluded from intervals.

The game is in Performance mode with Classic Lighting enabled. Initial
all-effects-on testing recorded 5.77 FPS. Disabling Bloom alone recorded 5.87
FPS; disabling both Bloom and Motion Blur recorded 7.43 FPS. These settings
changes are separate from emulator optimizations. The next build, with compact
CFG states and static-analysis reuse, recorded 8.07 FPS at the opening street
position with both effects off. Time of day and background traffic change even
with a stationary player, so these runs are not a strict isolated A/B proof.

Subsequent opening-position samples recorded 7.37 FPS for the installed
cold-launch-tested build and 8.27 FPS after indexing the uniform scalar walk.
The 10 FPS target has not yet been demonstrated over a measurement interval.
An additional 7.10 FPS interval was excluded from the stationary comparison:
the user confirmed moving the player and camera during that sample. Later
buffer-index and compact variant-key changes have passed their listed tests;
a clean gameplay performance measurement for that combination is pending.

Validation includes the 261-test GPU suite, uniform-branch tests covering live
input changes and allocation failures, AvPlayer clock/presentation tests, and
native cube-publication, color-initialization and resident-mip probes. The
existing October 3 report remains a separate historical measurement.

Whole-game completion, long-session stability, save recovery and audio
correctness have not been established by this investigation.

## Remaining shadow defect

On October 11 the user reported that object shadows, including vehicle shadows,
move with the player, and that the player's shadow appears multiple times.
This observation is not yet isolated to a particular run or independently
reproduced. It remains open; the reflection-cube correction above does not
establish shadow correctness.
