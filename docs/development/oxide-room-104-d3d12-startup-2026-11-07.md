# OXIDE Room 104: native D3D12 startup, November 7, 2026

Title: **PPSA07653 v01.000.000**, installed at
`D:\PPSA07653-app0-oxide-room`. Development work after v0.3.6.

## Reproduced stops

The original DirectX run stopped on the first depth/stencil metadata expansion
with `MissingAttachment`. The utility vertex program included unsigned float
conversion, logical right shift and MAD operations which were absent from the
side-effect-free utility proof. Those operations now pass the proof; shader
stores, discard and system interrupt messages remain excluded. The game passes
both its 1×1 and 3840×2160 HTILE expansions.

The next stop was `UnboundedControlFlowNotImplemented` in a 474-word compute
shader with 23 control-flow blocks and two back edges. Native compute now
accepts proven forward-only dispatcher flow and executes cyclic dispatchers
with an isolated completion-status UAV. The 65,536-block-visit limit is checked
after the GPU fence. Exhaustion withholds all buffer, image and persistent GDS
writebacks and reports `ShaderLoopBudgetExceeded`.

The following run passed that shader and reached `IMAGE_GATHER4` at PC `0xc8`
in another compute program, previously rejected as
`ComputeImageOperationNotImplemented`. Compute sampled textures now share the
existing graphics texture/sampler upload path, with separate binding tables
alongside writable buffer/image UAVs. Native R32_FLOAT sampling preserves depth
values. Unsupported metadata and overlapping sampled/writable guest allocations
continue to stop explicitly.

The next descriptor was a 2048×2048 R16_FLOAT allocation sampled at mip 3.
Sampled views now rebase native dimensions and uploads to their selected base
mip. Reading one mip while writing a distinct mip is permitted only when the
allocation layout matches completely; an overlapping view remains rejected.

The next live run passed the entire downsample submission and stopped on an
`IMAGE_STORE` into a 64×64×64 RGBA16_FLOAT volume with DCC enabled. Full,
single-mip RGBA8/RGBA16_FLOAT storage and sampled views now resolve uniform DCC
fast-clear/comp-to-single keys. Partial stores preserve the other logical
texels and publish uncompressed keys only after GPU completion. Mixed keys,
unknown compression codes and metadata aliases remain rejected. Key encoding,
alpha placement and 256-byte comp-to-single blocks were cross-checked with
local AnyPS5 `DccMetadata.cpp` at `e0caf1360035286bd22b9f2a3030e97b880ffb28`;
this is a bounded native implementation, not a fallback to raw compressed bytes.

The following run passed the volume and reached the first postprocess draw.
It used a 1920×1080 target in slot 0 while five stale 3840×2160 G-buffer
attachments remained bound with zero channel-write masks. Native attachment
validation now removes trailing slots with no effective exported/writable
channels before comparing extents or staging their bytes. Active attachments
remain subject to the original extent, format and alias checks.

That draw then exposed a sampled RGB10A2_UNORM G-buffer with DCC. Native
sampled-image validation, upload footprints and descriptor mapping now include
DXGI R10G10B10A2_UNORM. Uniform DCC materialization encodes the 10/10/10/2
channels at their actual widths; it does not treat the packed texel as RGBA8.

After passing RGB10A2 sampling, the game selected a 3840×2160 R8_UNORM
postprocess target with DCC. R8 is now supported as a native render target,
including byte-sized upload/readback rows, effective red-channel writes,
uniform fixed/register/comp-to-single clears and uncompressed key publication.

## Validation

- Native GPU suite passes on an NVIDIA GeForce RTX 3070 Ti, including the
  existing graphics, storage-image, stencil, MRT and resource-cache probes.
- Utility-clear regressions verify complete depth/stencil materialization and
  preserved color bytes, with negative fragment-discard and buffer-store cases.
- Compute dispatcher probes verify four forward branch paths and six finite
  loops, with exact 64-lane output and complete guest-memory comparisons.
- Exhausted compute probes preserve all original buffer/image/GDS bytes;
  repeated cached runs reset their private status correctly.
- Native and PM4 R32_FLOAT gathers return the expected four texels in order,
  observe changed input and write matching buffer and image outputs. A sampled
  image aliased by a writable guest buffer is rejected without modifying memory.
- A tiled R16_FLOAT mip-3 gather writes mip 4 of the same allocation and matches
  a complete memory reference, preserving other mips and padding. The equivalent
  overlapping-mip dispatch is rejected. All **51 D3D12 unit tests pass**.
- The shared translator's status tests pass. Its new compute option is opt-in;
  Vulkan keeps its existing execution path.
- Twelve native DCC volume cases cover sampling before a partial store, both
  alpha positions, all four fixed clear codes, plain and comp-to-single data,
  complete backing/key comparison and rejection of unknown or mixed keys.
- Native MRT probes retain exact slot-0 output with seven stale, mismatched
  higher attachments masked by either target or shader masks. Enabling a
  mismatched slot still rejects the draw without changing guest memory.
- Twelve RGB10A2 native sampling cases check normalized channel values, both
  alpha positions, fixed-clear/comp-to-single/uncompressed keys, and complete
  source/metadata preservation.
- Fourteen R8 render-target cases compare complete guest backing and metadata
  for seven DCC states with red writes enabled and masked out.

## Live verification

The final normal-path run passes the utility, loop, mip-sampling, DCC-volume,
masked-attachment, RGB10A2 and R8 stops. It then rejects a blended draw into a
3840×2160 RGBA16_FLOAT color attachment with DCC enabled:
`UnsupportedRenderTargetLayout`. DCC for this raster attachment is not yet
implemented; the new sampled/storage DCC paths do not cover it.

**The title is not yet working on DirectX 12.** Menu, gameplay and FPS remain
unverified. The only presented scanout is black, so no menu/gameplay screenshot
is published. The final test process exited at the explicit backend rejection;
no test game remains running. This is a checked development checkpoint.

`zig-out/bin/game-run.exe` was rebuilt in ReleaseFast and installed normally.
Runner SHA-256:
`fdc931ae737788a611b0464ce1217e910839096457e7505ea52165fe835f0f3c`.

The existing title profile supplies Unreal's `-noraytracing` option virtually;
installed game files and saves are not changed. Testing uses an isolated working
directory. No unsupported draws or dispatches are deliberately skipped and no
Vulkan fallback is used.
