# ASTRO BOT: RGB-only HDR attachment cost

Date: October 24, 2026. PPSA21564 v1.018, Vulkan, RTX 3070 Ti.

## Live investigation

The existing MIN_LOD build reached the crash-site controller tutorial. With
the player leaving the controls idle, the first interval presented 104 frames
in 30.0001897 seconds: **3.47 FPS**. A later interval was **2.73 FPS**; its
larger draw count makes it unsuitable as a paired comparison with the first.
Neither is the earlier opening-cinematic measurement of 10.90 FPS.

Warm shader compilation and cache misses were not the principal delay. GPU
timestamps, including a run that waited for every submission, repeatedly
identified approximately **155 ms** in a fullscreen RGB-only draw. The pixel
program at `0x5003e3a00` has only 14 guest instructions. The expensive instance
writes a 2432 x 1368 RGBA16F attachment at `0x53aa00000`; the other instance of
the same program is not equivalently expensive.

An isolated replay preserved the captured shaders, sampled image, geometry,
dimensions and blend state. The slow path remained with a constant fragment
shader or a simple vertex shader, but disappeared when the native color write
mask included alpha. This localized the cost to this attachment/write-mask
combination on the tested driver, rather than shader translation complexity.

## Exact implementation

The native workaround applies to NVIDIA, one single-sample RGBA16F color
attachment, a non-layered target, RGB-only writes, and an existing identity
alpha blend. It excludes programmable blending and RGB blend factors that
read destination alpha, including source-alpha saturation. Those factors
could otherwise observe temporarily changed exceptional alpha values during
overdraw. Unsupported configurations retain their existing implementation.

Simply promoting the native write mask is insufficient: the first native
test found that half-float positive infinity became the largest finite value.
The final path therefore saves alpha through a compatible RGBA16UI view,
executes the original draw with the full native write mask, then restores the
original alpha bits with integer image operations. Both extra dispatches stay
on the GPU. There is no framebuffer transfer to the CPU and no skipped effect.

Each render target owns its alpha buffer and immutable descriptor set.
Barriers order repeated saves/restores and color attachment access; resources
are retired with the existing submission timeline. Allocation failure falls
back to the original masked draw. Guest write masks, coverage proofs and
coherence tracking remain unchanged. The opt-out diagnostic export is
`full_mask_preserve_alpha`; the new path is enabled by default.

## Native validation and performance

- `vulkan-smoke --rgb-alpha-preserve`, with Vulkan validation enabled, passes
  all 65,536 half-float alpha bit patterns, including signed zeros, denormals,
  infinities and NaN payloads. Four source values and an odd-width 257 x 256
  target exercise partial compute workgroups. Original and optimized RGBA
  readbacks are byte-identical; all four optimized draws execute the new path.
- All eight `--retained-render-pass` configurations pass.
- The complete ReleaseSafe Vulkan unit suite passes **267/267** tests.
- `spirv-val --target-env vulkan1.2` accepts the embedded preservation shader.

For the captured 2432 x 1368 draw, seven warmed completed-draw measurements
give medians of **161.448 ms before** and **3.593 ms after**, including GPU
alpha preservation. The first pass, including pipeline setup, is excluded.
These are isolated draw measurements, **not whole-game FPS**. Guest captures
and shader binaries remain local diagnostic fixtures, not repository assets.

## Gameplay follow-up

The ReleaseSafe runner has been rebuilt, installed at
`zig-out/bin/game-run.exe`, and restarted successfully. Its SHA-256 is
`648914db2141fd8eae2fe44d88b9b21d0d6cd46f54f2b9a7278fcc4c6ba5221b`.
The optimized path executes in the title scene without allocation fallback
or a deferred shader memory fault. The title image is not a gameplay result.

A same-process title check toggled only the new path, with a four-second
settling period before each twenty-second sample:

| Path | Presented frames | Elapsed seconds | FPS |
|---|---:|---:|---:|
| Optimized A | 247 | 20.0002864 | 12.35 |
| Original RGB mask | 231 | 20.0003816 | 11.55 |
| Optimized B | 244 | 20.0003213 | 12.20 |

The optimized intervals together average **12.27 FPS**, about **6.3%** above
the intervening original-path sample. The title has different work from the
captured tutorial draw; this modest title gain is not a gameplay speedup.
Both deferred shader memory-fault flags stayed clear. The optimization was
restored to its default enabled state after the comparison.

A matched gameplay measurement is still required before claiming an overall
FPS gain or updating the compatibility table with a new performance result.
