# ASTRO BOT: preserve computed HDR contents across DCC initialization

Date: November 1, 2026. PPSA21564 v01.018.000, Vulkan development build.

## Live follow-up to the blend-constant correction

The [blend-constant implementation](astro-bot-blend-constants-2026-11-01.md)
passes native GPU tests, but its first live crash-site check still shows the
dark, blurred world behind a sharp tutorial overlay. It is necessary for
the bloom equation and is not sufficient to fix the image by itself.

A new capture confirms that the bloom draw now receives **(0.9, 0.9, 0.9, 1)**.
Nevertheless, its RGBA16F output has zero alpha and only the blurred source.
The preceding depth-of-field composite contains a sharp image with alpha one.
The raster attachment is uninitialized at this hand-off: an old zero DCC
clear is applied again, erasing the computed destination before blending.

Private diagnostic captures include compute program `0x5007b1300` at flip
44477 and bloom programs `0x5003e3000` / `0x5003e3a00` at flip 44189.
The source and destination use address `0x53aa00000`, a 2432×1368 RGBA16F
view, with metadata at `0x570854000`. A later bounded frame trace confirms
the compute-to-raster publication path. These addresses identify evidence;
the implementation contains no game-address checks or shader replacements.

## Implementation and scope

A committed compute image records the tracked generation of its DCC
metadata. Raster initialization may retain those expanded pixels only when
the complete image layout, allocation, metadata range, guest contents and
tracked generation still agree. The proof survives publication into guest
memory and therefore covers both native GPU copies and the ordinary upload
path. CPU replacement, a new upload or retirement invalidates the proof.

A later metadata write revokes it even if the same zero bytes are written
again. Unavailable write tracking, pending buffer writers and dispatches
that explicitly write the metadata keep the existing conservative path.
Unknown store preparation also declines this proof. DCC clearing remains
enabled; no post-processing effect is disabled.

## Validation

Native GPU checks cover unpublished and published HDR output, a repeated
zero clear, a different fixed-color clear, CPU pixel replacement, missing
tracking, an unrelated CPU write, explicit metadata stores and incomplete
store preparation, with native hand-off both enabled and disabled. All
**18 native GPU cases pass**. An initial CPU-replacement failure exposed a
stale observation; invalidating it when storage contents are replaced is
part of the final fix.

The full ReleaseFast runner and smoke build pass **606 tests** (333 GPU and
273 Vulkan). The native blend-constant, storage-to-color initialization,
DCC metadata-clear and DCC single-texel-clear regressions also pass.
The runner SHA-256 is
`2d3b34f1ce20c1c0529a1f245a3285369cc2b7ffa758cd144bc0180cfda2c276`.
The live comparison is pending, so no corrected gameplay image or FPS gain
is claimed yet.

The preceding blend-only run measured **259 flips/presents in 30.000321 s,
8.63 FPS**, in the moving space introduction. This is not a gameplay benchmark.
That run was deliberately terminated by the diagnostic memory guard after
three samples below 768 MiB of host commit headroom during compilation;
the stop is not attributed to a new game crash. Builds and subsequent game
runs are kept sequential.
