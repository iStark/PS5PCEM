# Asterix & Obelix MSAA depth/stencil performance — October 9, 2026

The shared MSAA depth/stencil fix raises the stationary opening-forest median
from **46.45 to 162.20 FPS** on the RTX 3070 Ti test host. These are 30-second
window-counter samples at 1920×1080 guest output, Speed preset and warm caches;
they are not a minimum for the entire game. PPSA08576's baseline executable
is the signed development build from commit `e14bc95`, SHA-256
`4942355A00DCFB90E8B297632458235D17EB38FE301F5AD40365EF2B56483823`.

## Cause

A live one-frame trace identifies four depth/stencil-only draws against a
1920×1080 attachment with two samples per pixel. The compatibility colour
descriptor used to derive their pipeline state incorrectly specified one
sample. The renderer consequently rejected the actual depth/stencil attachment
as mismatched and entered the transient colour-probe path.

Each of those draws created a private RGBA surface, submitted and waited for
GPU work, copied the surface to host memory, scanned its pixels and destroyed
the temporary resources. Four 1920×1080 RGBA readbacks amount to **31.64 MiB per
frame**, although these diagnostic copies were not included in the normal
render-target readback counter. The rejected stencil attachment also meant the
draws did not update the masks needed by later passes.

The baseline's 10-second CPU sample finds the graphics thread in GPU waits,
`readMapped`/`memcpyFast`, `drawGraphicsShadersWithModules` and allocation/free
calls. Other sampled guest workers mostly wait. Twenty periodic frame samples
from flips 51,540–52,680 have medians of 21.5 ms per frame, 17 ms inside draw
callbacks, 4.56 ms of fence waits and 18 submissions. They use about 48 draws
and one dispatch; the warm shader/pipeline caches are not the bottleneck.

## Change

Depth-only compatibility state now retains the depth attachment's sample
count. The persistent depth-only path supports matching MSAA attachments and
keeps their depth/stencil data resident between draws. Its render pass and
pipeline use the same sample count. The legacy compatibility path also creates
matching MSAA surfaces, preserving the diagnostic comparison mode.

MSAA colour attachments no longer request storage-image usage: this backend
does not enable `shaderStorageImageMultisample`. Single-sample attachments keep
that usage. The validation rule is documented in the
[Vulkan image creation requirements](https://docs.vulkan.org/spec/latest/chapters/resources.html#VUID-VkImageCreateInfo-usage-00968).

The change is selected by attachment state, with no game-ID exception, lower
resolution, disabled stencil test or skipped guest draw.

## Validation

- **233/233 ReleaseSafe Vulkan unit tests pass**, including 1×/2×/4×/8×
  compatibility-state sample counts.
- The new `vulkan-smoke --multisample-depth-pass` probe passes for 2× and 4×,
  with both persistent and legacy paths. It writes depth/stencil, issues an
  empty draw, then verifies matching and mismatching stencil references in a
  colour consumer. The colour result is resolved before reading it back;
  multisampled depth is never copied directly to a buffer.
- Khronos validation is enabled for that probe. No validation errors remain.
  The persistent path emits the expected warning about the diagnostic fragment
  shader's unused colour output in a subpass without colour attachments.
- The existing `--depth-pass-cache` probe passes for both paths, covering
  indexed draws, retained depth/stencil, upload-ring exhaustion, empty draws
  and a smaller render area.

## Live comparison

Each interval contains 30 one-second window-counter readings. The character
stands at the initial position in the forest, with the same 1765×993 client
window, 1920×1080 internal attachment size and game settings. Compilation and
the intrusive CPU sampler run outside the FPS measurements.

| Run | Median FPS | Mean FPS | Counter range |
|---|---:|---:|---:|
| Baseline | 46.45 | 45.67 | 27.8–48.8 |
| Fixed, first interval | 156.50 | 148.68 | 0.5–167.0 |
| Fixed, warmed repeat | 162.20 | 162.02 | 153.1–166.4 |

The first fixed interval starts with a 0.5 FPS counter at scene entry;
the table retains that reading. The warmed repeat avoids that transition.
These are sampled UI counters, not exact presentation totals or 1% lows.

Twenty periodic profile samples in the warmed fixed scene (flips
52,320–53,460) give the following medians:

| Per-frame metric | Baseline | Fixed |
|---|---:|---:|
| Frame time | 21.5 ms | 6 ms |
| Draw callbacks | 17 ms | 2 ms |
| Fence waits | 4.557 ms | 0.332 ms |
| Queue submissions | 18 | 14 |
| Draws / dispatches | 48 / 1 | 48 / 1 |

The steady frame reports no draw/dispatch failures or unresolved storage
bindings. Shader and pipeline caches are warm, with no texture uploads or
allocation churn in the sampled frame. The remaining work includes ordinary
draw submission, guest execution and a 192 KiB compute-buffer readback; this
change does not remove required transfers.

Moving right, jumping and attacking reach the first Roman encounter; a hit
increments the score. The forest, sprites and HUD remain visible, and the
green HUD gauges now use the retained stencil masks. This retest covers the
opening level only. It does not establish a new complete playthrough, exact
audio quality or a stable frame rate across later levels.

A separate post-movement counter sample includes the character's death and
the mission-failed overlay. It is excluded from the matched scene comparison
and is not reported as a combat benchmark.

![Opening forest after the MSAA depth/stencil fix](../images/asterix-msaa-depth-fix-2026-10-09.png)

*Unedited game-window capture after the stationary retest. The title counter
reads 161.8 FPS; the table above reports complete sampled intervals.*

## Installed build

`zig-out/bin/game-run.exe` and its matching PDB were rebuilt in ReleaseFast
and installed at 23:31 on October 9. Executable SHA-256:
`9F5F63B082A19FC5E7705461736A33ADDBF25A4FE1F043B91F36694E4617EC67`.
The executable is signed with the existing Artur Strazewicz / PS5PCEM
certificate and a DigiCert timestamp. The local Windows verification still
reports the existing untrusted-root chain condition; trust settings are
unchanged. This is a development build after 0.3.4.

Local measurement artifacts are under `out/asterix-performance-20261009/`:
`baseline-fps.json`, `fixed-fps.json`, `fixed-warm-fps.json`,
`baseline-profile.json`, `fixed-profile.json`, `cpu-profile.log`,
`multisample-final.log`, `depth-cache-probe.log` and `verification.json`.
