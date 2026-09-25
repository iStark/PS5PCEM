# Guest game preset preference

`game-run` accepts `PS5_GAME_PRESET=default|performance`. The default remains
the previous zero-valued system preference. `performance` returns priority 1
through `sceUserServiceGetGamePresets`. This setting is independent of
`PS5_PERFORMANCE_MODE=speed|graphics` (host emulation choices) and
`PS5_OUTPUT_RESOLUTION` (reported output class).

```powershell
$env:PS5_GAME_PRESET = 'performance'
$env:PS5_OUTPUT_RESOLUTION = '1080'
$env:PS5_INPUT_MODE = 'hybrid'
.\zig-out\bin\game-run.exe 'F:\PPSA26344\eboot.bin'
```

The runner prints the selected preference. The first successful guest query
logs its requested size, the supported size, and the priority actually returned.
No preference forces a title to honor it or supersedes its saved settings.
It is not a 1080p render-target limit. Unknown named/numeric preferences fall
back to the game default with a warning. Unverified priority encodings and a
system-level Balanced mode are not exposed.

The launcher defaults to **1080p**, **Speed**, and the enabled **Performance**
switch. The switch persists as `launcher.game_performance`; turning it off
requests the game default. Existing saved output-resolution choices are kept.
The current local launcher configuration already selected 1080p. The UI offers
1080p, 1440p, 4K and 8K; no sub-1080p output mode is currently exposed.

The service fills at most the caller's stated extent and the known 40-byte
layout, leaving unknown extension fields untouched. Size zero retains the
legacy full-layout behavior. Nonzero extents shorter than the size field are
rejected. Preferences survive service termination/reinitialization but reset
between runtime instances.

## Evidence from the local Yotei executable

For PPSA26344, build `1003.1141`, static analysis of the decrypted image found:

- The call at ELF-relative `0xa87cf7` requests 48 bytes. The following code
  checks the priority field at offset 12 against 1, storing internal mode 2
  when equal and mode 0 otherwise.
- Graphics initialization at `0xccf8a2` copies this system preference only
  when the requested graphics mode is unset (`-1`). Existing game settings
  can therefore take precedence.
- A 16-entry resolution table at `0x19aa610` ranges from 3840x2160 to
  1920x1080 in 128-pixel width increments. The selected table entry is used
  during resource setup at `0xcd05a0`; the presence of the table does not mean
  all entries are simultaneously rendered or allocated.
- The display resource dimensions are explicitly assigned 3840x2160 by the
  game in initialization and display updates, independently of the HD output
  status. A performance preference alone cannot promise all resources <=1080p.

These addresses are diagnostic evidence for this executable only; they are
not patches, hooks, or title-specific logic in the emulator.

## Validation

The filtered HLE suite passed 7/7 tests in ReleaseSafe. It covers preference
delivery, service reinitialization, runtime reset, short and extended caller
buffers, untouched sentinel bytes, invalid users/pointers/sizes, and rejecting
unverified preference values. Native runner and launcher ReleaseFast builds
both succeeded. These checks completed before starting the game.

The launcher's English settings page was visually inspected. The new switch
was toggled off/on; the INI records `game_performance=1` and
`output_resolution=1080`. UI text was added for all eight supported languages.

Built binaries:

- `zig-out/bin/game-run.exe`, 2026-09-26 01:57:43 local,
  SHA-256 `D98B20A96920F81A0D7677C0C38205345E9920AB88FB6680E8272F5E8B59F5D9`.
- `zig-out/bin/ps5pcem.exe`,
  SHA-256 `11DE950EC3155C903F60ED75B0B74BC9F96CDD92BC58C8E0A494D39C3FA31893`.

## Native experiment

Artifacts are in `out/game-presets-20260926/`. Both launches use 1080p,
host Speed, guest Performance, and hybrid input. Both started without synthetic
presses. After explicit user authorization, four individual Cross presses in
the second run dismissed three bonus notices and the brightness screen.
Input stopped when the 3D scene appeared; `input.jsonl` records the presses.

The title queried the service with size 48 and received supported size 40,
priority 1. Read-only inspection confirmed system/requested/selected game mode
2. During loading, the selected resource size moved through 1920x1080 to
2304x1296 (table index 12). Display resources stayed 3840x2160. The API is
therefore being consumed, but it does not enforce a hard 1080p limit.

The first process (PID 15196) ended with an unhandled host access violation
at module-relative `0x3c9e1d`, symbolized to `insertionIndexIn` through
`AddressSpace.isReadable` and `isGuestRangeAccessible`. It was not deliberately
closed. Its cause and relationship to the preference are unestablished.

The second process (PID 2996), started at 02:03:22, passed that loading point.
At 02:08 it was still loading with mode 2 and 2304x1296 resources. Recent
targets include 2304x1296, 1152x648 and the 3840x2160 output. Cached resources
also include previous sizes; these snapshots do not show sixteen complete
scenes being rendered at once. Individual cold graphics pipeline builds took
3–4 seconds, so these startup frames cannot establish a warmed FPS improvement.
No game memory or executable data was patched during the experiment.

At 02:19 the second run reached the 3D tree scene. Its system and requested
modes remained 2, while its selected mode switched between 0 and 2. Mode 0
was observed with 3328x1872 resources and mode 2 with 1920x1080 resources.
The available-mode list was `[0, 2, 3]`. The selector at `0xcd1a30` can replace
the requested mode's low flags with 4 when an internal counter or predicate
is active. This explains why the API preference does not force the selected
mode; the gameplay meaning of that internal override has not been established.
The resolution override remained unset (`0xffffffff`).

The initial 3D transition was still cold: flip 1089 took 122,115 ms with 596
new graphics pipelines (82,507 ms reported build time) and 92 new compute
pipelines. Live compiler completion and command counters advanced during the
long pauses. These measurements do not establish a steady-state FPS gain.
The approximately 0.9 FPS seen on startup screens is not a gameplay benchmark.

By 02:25:53 the scene had advanced to several characters in a lit interior.
The user-requested, unmodified client capture is saved as
[`docs/images/yotei-character-scene.png`](../images/yotei-character-scene.png).
Startup navigation is complete; the game was left running without further
synthetic input. This capture establishes progress beyond the tree scene,
not visual correctness or responsive player control.

FPS improvement remains unproven. Later flips 1091–1095 took 12.26, 15.43,
17.39, 38.12 and 17.96 seconds. Pipeline misses were still present in this
changing scene, and resource churn was substantial: flip 1095 evicted 5,593
sampled textures and uploaded about 2.34 GiB of texture data. It reported
8.07 seconds in graphics resource preparation, 5.04 seconds in fence waits,
and 2.34 seconds in graphics pipeline builds; these timers overlap. At 02:25
the selected mode was again 0, with recent 3328x1872 targets and a 4K display
resource. The API and launcher integration work, but a sustained 1080p render
limit and a warmed, comparable gameplay FPS gain have not been achieved.

Next investigation should distinguish the title's internal mode override from
its system preference and measure texture retention/upload churn in the same
scene. Avoid extrapolating from startup-screen FPS or forcing every Vulkan
resource to a display-sized allocation.
