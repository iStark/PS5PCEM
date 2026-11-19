# OXIDE Room 104: DCC fixed clears and NGG exporter elision

Title: **PPSA07653 v01.000.000**, installed at
`D:\PPSA07653-app0-oxide-room`. DirectX 12 work after the November 7
checkpoint.

## DCC fixed clears on wider render targets

The first postprocess blended draw targets a 3840x2160 RGBA16_FLOAT color
attachment with DCC enabled. It previously stopped with
`CompressedColorTargetNotImplemented`: the metadata used a fixed clear code
(`0x40`, `0x80` or `0xc0`), while the D3D12 fast-clear expansion only encoded
those codes for byte-per-channel UNORM layouts.

`surfaces.Dcc` now encodes the fixed clears for every native render-target
layout admitted by `colorFormat`:

- R8_UNORM,
- RGBA8 UNORM/SRGB,
- RGB10A2_UNORM,
- R11G11B10_FLOAT,
- RG16_FLOAT,
- RGBA16_FLOAT.

Each format uses its own all-zeros/all-ones pattern; half-float clears use
`0x3c00`, not an all-bits-set pattern, and the packed formats use their real
channel widths. The clear code is decoded as alpha/color bits, not as a single
"all channels" flag.

Code `0x20` now reconstructs up to eight texel bytes from both
`CB_COLOR*_CLEAR_WORD0` and `CLEAR_WORD1`. Sampled views still carry no clear
words and continue to reject code `0x20`. Clear codes or layouts without an
exact encoding fail closed.

Validation: the portable D3D12 suite passes **57 tests**, including expanded
coverage for RGBA16F fixed clears, both clear words, RGB10A2 and R11G11B10
packed ones, and rejection of missing/unknown encodings.

## OXIDE merged NGG exporter

After the DCC draw passed, the title presented its first 3840x2160 frame and
stopped at:

```text
[d3d12] draw rejected: GeometryAmplificationNotImplemented
op=0x2d body={4,2} stages=0x2030 gs_mode=0x0 primitive=6
```

The draw has a populated GS bank at `0x20092c0000`. D3D12 previously accepted
only the verified GTA III triangle-copy digest. The OXIDE GS is a different
1704-byte UE4 primitive-compaction exporter:

- it allocates LDS, reads the three seven-word ES records, compacts them, and
  exports at most the same three vertices;
- it contains no guest-memory stores, atomics, image writes or stream output;
- its only effects are the export and allocation messages, so ignoring it
  cannot change later buffer/image state.

Vulkan already routes this draw through the export shader and never executes
the GS (`graphicsVertexStage` prefers `.vertex`, then `.export_shader`, then
`.geometry`). The D3D12 backend now recognizes this exact exporter digest
(`8b4a8c6b8f501514cbb0e1d5edb36e0ef211fda57e1a20182b055c1625a3bd3a`) and uses
the same ES-only routing. The native input assembler and the guest ES export
recovery replace the GS compaction. This is a verified per-digest exception,
not general geometry-shader support: every other GS still fails closed, and
`docs/architecture/d3d12.md` continues to list NGG culling and geometry
amplification as unsupported.

## Live status

The rebuilt ReleaseFast runner passes the DCC draw and the NGG rejection. It
presents frames, starts AGC/audio work, and remains responsive in a window
titled `PS5PCEM - DirectX 12 (experimental) guest output`. The observed rate
is about **0.3 FPS** during startup. A window capture taken at that point was
black, so menu/gameplay rendering has **not** been verified yet; the title may
still be in a loading screen. No Vulkan fallback or draw skipping is used.

Next work is visual verification of the menu and gameplay, and triage of any
remaining explicit D3D12 rejection. The GS elision is only safe for exporters
with no memory side effects; future variants need their own semantic proof.
