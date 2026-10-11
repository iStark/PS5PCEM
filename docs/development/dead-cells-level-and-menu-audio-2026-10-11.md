# Dead Cells level lighting and menu audio — October 11, 2026

Continues the [NGS2 linking report](dead-cells-ngs2-2026-10-11.md). After
that change Dead Cells (PPSA15552 v01.005.000) reached gameplay, but the level
and the character were dark and the main menu was silent. Each problem was
traced to a separate emulator bug.

## Dark level

Dead Cells renders its scene at 642×362. It fills four RGBA8 G-buffer
targets, lights them, and composites the result into one scene target. It
then blurs the emissive target and adds it onto the scene in a full-screen
pass. That pass samples one texture and exports it unchanged, with blending
color `SRC_ALPHA`/`ONE` and alpha `ONE`/`ZERO`.

The Vulkan backend has a fast path for identity compositors: a full-screen
quad whose pixel shader samples one image and exports it is replaced by an
image copy. The emissive pass has exactly that shape, and the fast path did
not check blending. The emissive target is black except for glowing pixels.
Its RGB is zero and its alpha is one, so the copy overwrote the lit scene
with black. The 3840×2160 upscale that follows kept only the HUD.

A traced frame shows the step. Before the emissive pass the scene target
averages RGB 42/66/69. Afterwards every pixel's RGB is zero. With the fix the
same draw goes through the translated pipeline and the scene keeps its full
range (peak 255).

**Fix:** the copy fast path now runs only when the target slot's blending is
off or reduces to a plain replace (`ONE`/`ZERO`/`ADD` for color and alpha).
Every other pass-through draw is rendered normally, so blended composites keep
the existing scene.

## Silent main menu

The menu music has data; the emulator was not playing it. Dead Cells plays
it through a custom sampler rack (rack ID `0x4001`). It sends that rack's
voices the sampler's own voice parameters under the custom rack's prefix:
`0x40010000` for the waveform format and `0x40010001` for the waveform
blocks. The NGS2 voice handler accepted these parameters only with the
standard sampler prefix (`0x1000`). The voices therefore entered the playing
state without data, and the mixer rendered silence.

The waveform is 16-bit PCM, stereo, 44,100 Hz (type `0x12`), a format the
mixer already decodes. **Fix:** voices of rack `0x4001` now take the sampler's
format, block and pitch parameters.

During diagnosis, temporary instrumentation recorded the NGS2 mix (full scale
1.0). It was removed before the commit. Before the fix the menu mix was zero
throughout. After it, the menu mix peaks at about **0.12**. Gameplay
mixes 16 PCM voices at a peak of about **0.157**. This is a measurement of
the mixed signal; the music has not yet been confirmed by listening.

## Run

Development runner built from this change, after release 0.3.4; RTX 3070 Ti,
Speed preset, 1920×1080 output request. The runner's automatic Cross presses
started a game; there was no manual play.

- The Prisoners' Quarters level renders. The capture below shows the lit
  window with its light shaft, the character, the starting weapon, the
  tutorial prompt and the HUD.
- The window counter read **59.2–68.1 FPS** in the starting room. These are
  seven readings, including 62.5 FPS at the capture, not a timed median. The
  counter read about 4 FPS on the loading screen before the level.
- Draw and dispatch failure counters stayed at zero in all 101 periodic
  reports. Unlike the earlier run, no `image_sample` translation was rejected
  with `InvalidStorageBinding`.

![Dead Cells gameplay in the Prisoners' Quarters with the level, character and HUD rendered](../images/dead-cells-gameplay-2026-10-11.png)

## Validation

- A Vulkan backend test checks that a pass-through draw blended with
  `SRC_ALPHA`/`ONE` is not replaced by a copy, while replace blending and
  disabled blending still are.
- An NGS2 test creates a custom sampler rack and sets a 16-bit stereo format
  and one waveform block through the `0x4001` parameter IDs. It plays the
  voice and checks the rendered float samples.
- The full test suite passes 1602 of 1613 tests with one skipped. The ten
  failures are the long-standing SPIR-V tests and are unchanged.

## Limits

- Playability, combat, progression beyond the first room, saves and longer
  sessions are not established.
- Menu music is verified by mix levels only.
- The NGS2 mixer still accepts voice matrix levels without applying them, so
  `sceNgs2GeomApply` results do not yet change what is heard.
- `sceNgs2PanGetVolumeMatrix` still routes every input to the first output
  channel.
