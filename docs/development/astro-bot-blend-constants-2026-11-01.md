# ASTRO BOT: missing blend constants erase the sharp scene

Date: November 1, 2026. ASTRO BOT PPSA21564 v1.018, Vulkan development build.

## Diagnosis

The crash-site image is dark and strongly blurred while the tutorial overlay
remains sharp. A bounded renderer trace and individual pass captures isolate
the loss of scene detail after depth of field, at the bloom composite.

The depth-of-field composite at program `0x5007b1300` retains a sharp, finite
RGBA16F image of the ship and sand. Its captured destination before and after
the dispatch is recognizable. The later raster pass, vertex program
`0x5003e3000` and pixel program `0x5003e3a00`, writes RGB with blending enabled:

- Source factor: `ONE`.
- Destination factor: `CONSTANT_COLOR`.
- Captured `CB_BLEND_RGBA`: **(0.9, 0.9, 0.9, 1.0)**.
- Alpha writes are masked off.

The Vulkan backend decoded the blend-factor enum but never forwarded the
four constant registers. Its Vulkan pipeline therefore used the default zero
constant: the sharp destination contributed nothing, leaving the blurred
bloom source. This is a missing fixed-function state implementation, not
evidence that the depth-of-field shader should be disabled.

The relevant captures are local diagnostic files under `out/`, including
`storage-capture-94338-5007b1300-103*` and
`vertex-capture-94477-5003e3000*`. Raw game shader/texture data is not distributed.
Intermediate HDR previews use an explicit display transform for inspection;
they are not presented as screenshots of the game window.

## Implementation

The common render-state decoder now preserves the four context-register
values at offsets `0x105` through `0x108`. Vulkan records them with
[`vkCmdSetBlendConstants`](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdSetBlendConstants.html)
and enables the corresponding dynamic pipeline state.

The values are refreshed on reused draws and new command-buffer recordings.
They are excluded from the static pipeline cache key, so changing a blend
coefficient does not create another graphics pipeline. Component-swapped
attachments remap constant-color channels consistently with their exports;
conflicting requirements across MRT attachments report an unsupported state.
Constant-alpha factors retain the logical alpha value. Packed UNORM shader
blending keeps its existing explicit factor restrictions.

The fix is enabled by default and contains no game-address match or effect
bypass. An exported diagnostic switch permits a temporary same-process
comparison with the former zero-constant behavior. The local AnyPS5 blend
state implementation was inspected as a reference; this implementation uses
PS5PCEM's existing state decoder and dynamic-state/cache paths.

## Validation status

Unit coverage includes partial register updates, exact float bit patterns,
channel permutation, MRT conflicts, ignored MIN/MAX factors, pipeline-key
stability, and dynamic values copied into reused draws. The native
`--blend-constants` probe checks actual GPU results for constant/inverse color
and alpha factors, preservation of the destination scene, RGB-only writes,
and repeated pipeline/command-buffer reuse.

The unit suites pass **605/605 tests** (333 GPU and 272 Vulkan). The native
blend-constant probe passes on the RTX 3070 Ti with the validation layer
enabled. The existing RGB alpha-preservation probe also passes all 65,536
half-float alpha bit patterns, and the dynamic viewport/scissor probe passes
with both depth paths. Their logs contain no Vulkan validation error.

A fresh in-game comparison is pending. No visual fix or FPS improvement is
claimed from the native probe alone.

The complete ReleaseFast build passes **24/24 steps**, including both test
suites and the runner. The ordinary `zig-out/bin/game-run.exe` and its PDB
are updated. Runner SHA-256:
`c850752ba0d69e10009721304b46db23b8a9c93803ae1b3596d0764471ee3d7a`.
The new run reaches the title screen with the default fix enabled. The
pre-existing contained `WebApiJobWorker` fault at `0x8000148d0` still occurs
during startup; the main game continues. This change does not address that
separate fault or the 12 unresolved storage bindings in periodic profiles.
