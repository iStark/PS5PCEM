# Big Helmet Heroes — DirectX 12 startup progress, November 5, 2026

PPSA19943, content version 01.000.400. Windows, NVIDIA RTX 3070 Ti,
native DirectX 12, ReleaseFast development build after v0.3.6.

**Two startup blockers are fixed; the game still stops before the menu.**
This run does not change the earlier Vulkan compatibility result.

## Implemented and observed

The previous runner rejected the first compute dispatch with
`SampledAndStorageImagesNotImplemented`. Its shader writes a 1×1×1 R32_UINT
3D image. The backend now executes single-mip `IMAGE_LOAD` / `IMAGE_STORE`
operations on native D3D12 typed UAVs, including 2D, array and 3D images.
The shared guest layout code detiles inputs and retiles completed GPU output,
preserving other mip levels and padding. Buffer/image write aliases and
unsupported image operations still reject explicitly.

The next run passed that dispatch, then rejected the game's
`0x8100000022000000` RGB10A2 SDR scanout. This format and its BGR counterpart
now convert to RGBA8 for presentation and capture. PQ/HDR scanout remains
unsupported. Uncompressed RGB10A2 UNORM and R11G11B10 float render targets
also retain their native packed encodings through drawing and readback.

The final run presents its first **3840×2160** frame successfully. The capture
is entirely black: it is an initial blank scanout, not a rendered menu. The
game still chooses a 4K scanout with the runner configured for 1920×1080 output;
no internal-resolution patch was applied.

## Remaining stop

The first color draw now reaches attachment validation and stops with
`UnsupportedRenderTargetLayout`. Its target is RGB10A2, single-sample,
64KB render-target tiled, with **CMASK fast clear enabled**. The D3D12 backend
does not yet resolve this metadata. The unfinished CMASK work was removed
when the maintainer requested this checkpoint; that rejection remains intact.

There is no skipped-draw mode, fabricated completion, or Vulkan fallback.
Main-menu rendering, gameplay, audio quality, completion, stability and FPS
were not established in this DirectX test. No performance gain is claimed.

## Validation

- **50/50 portable D3D12 tests**, plus **3/3 Windows launcher tests**, pass.
- The complete native D3D12 hardware probe passes on the RTX 3070 Ti.
- New compute-image probes check 18 uint/UNORM/float copy dispatches across
  2D, array and volume images, including changed inputs with cached shaders.
- Fifteen PM4 compute cases compare complete guest memory after selected-mip
  writes in linear, depth-tiled and color-tiled layouts.
- Twelve packed-target cases verify RGB10A2/R11G11B10 output across six guest
  layouts, preserving untouched bytes; RGB10A2 output also checks SDR conversion.
- Existing stencil, HTILE, MRT, texture, resource lifetime and grouped-draw
  probes pass. The Windows D3D12 debug layer was not enabled.
- `zig-out/bin/game-run.exe` was rebuilt and used for the final run.
- The isolated test profile did not use the user's saves. The process exited
  on the explicit unsupported-target rejection and is no longer running.

Runner SHA-256:
`e100bd18e070615caba55f1aa6db5d7caf23684cc4a879df366572b8cdc6f635`.

The same checkpoint replaces Boosty with the official
[PS5PCEM Znosin channel](https://znosin.com/c/ps5pcem) in both launchers and
removes the obsolete Boosty text from all twelve translations. Windows and
Linux launchers were rebuilt; all **10 Linux launcher tests** pass under WSL.
