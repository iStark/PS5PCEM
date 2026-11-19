# OXIDE Room 104: D3D12 black scanout, November 19, 2026

Title: **PPSA07653 v01.000.000**, installed at
`D:\PPSA07653-app0-oxide-room`. Development work after the DCC/NGG checkpoint.

## Symptom

The game launches under DirectX 12, produces audio and GPU work, and presents
frames at about 0.3 FPS, but the window and exported scanouts are entirely
black. The same title renders correctly under Vulkan.

## Diagnosis

Profile instrumentation added to `d3d12.backend` correlated VideoOut buffers
with render targets and sampled images. For every flip, the registered display
buffers alternate between two addresses. Both stay all-zero (not even opaque
black) in guest memory.

* The final composite draw targets the registered display buffer: 3840x2160,
  RGBA8, one indexed six-vertex quad, no blending, five sampled images. Its
  complete output is zero words out of 8,294,400.
* Its sampled sources contain data, including a 3840x2160 RGBA16_FLOAT scene
  image and several small constant textures.
* Render-target censuses show 1920x1080 RGBA8 and RGBA16_FLOAT targets with
  100% non-black pixels, while all 3840x2160 render targets are completely
  black. The failure is therefore concentrated in the 4K raster/writeback
  path, not in the overall command submission or shader translation.
* The final pixel shader's output depends on an interpolated constant whose
  vertex source is a vertex texture fetch; the exact reason the 4K pass
  collapses to zero remains under investigation.

Vulkan already contains a completed-frame fallback for titles whose VideoOut
slot is never actually rendered into. D3D12 had no equivalent and simply
presented the untouched buffer, which is indistinguishable from a game that
rendered black.

## Change

`d3d12.backend` now keeps the most recent, visibly non-black full-size color
target in a bounded snapshot. Pixels are copied at writeback time so later
draws cannot overwrite the cached frame. At presentation, if the registered
scanout has no visible RGB content and a recent cached target exists, that
target is presented instead. RGBA16_FLOAT snapshots are converted to RGBA8.
The size of the presented image follows the cached target, so a 1080p target
is scaled by the window. The path is inert for games that render their own
scanout normally.

## Validation and limits

* Portable D3D12 unit tests still pass (57/57).
* A 100-second live run now presents a non-black image instead of an all-zero
  one (all 2,073,600 pixels of the 1920x1080 capture are non-zero), and the
  fallback log confirms the substituted target on every recorded flip.
* The substituted frame is a 1920x1080 dithered gray loading/clear image in
  the observed runs, **not** the finished scene. The game is still very early
  in startup at the measured 0.3 FPS, and the 4K raster path remains broken.
  This change is a workaround for the black VideoOut slot, not a claim that
  menu, gameplay, or full rendering correctness has been established.
* No Vulkan fallback, draw skipping, or title-specific branch is used.
