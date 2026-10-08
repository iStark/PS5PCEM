# MIMG BY2/BY4 and PCK2/PCK4 loads — October 9, 2026

PS5PCEM now decodes and executes the measured 2D subset of `IMAGE_LOAD_BY2`,
`IMAGE_LOAD_BY4`, `IMAGE_LOAD_PCK2`, `IMAGE_LOAD_PCK4`, and their explicit-mip
variants. This is shared shader/backend support; it does not depend on a game
ID or a particular shader hash. No game compatibility or FPS improvement is
claimed from this implementation alone.

## Behavior

BY loads return consecutive texels in separate VGPRs, with channels ordered
within each texel. PCK loads pack the raw component bits into one 32-bit VGPR,
starting with the first texel in the least significant bits. Signed components
are truncated to their storage width for packing; UNORM components are
reconstructed with round-to-even conversion.

The first texel is aligned down to a group of two or four in X. Bounds use
the original, unaligned X: the entire group must fit before alignment, Y must
be in range, and the requested mip must exist. An invalid group zeros every
result VGPR while preserving unrelated destination registers. Invalid guest
coordinates and mip levels are replaced with safe fetch operands before
Vulkan access. NSA coordinates, overlapping address/destination VGPRs, and
the ordinary guest EXEC mask are retained.

| Load | DMASK | Supported formats |
|---|---|---|
| BY2 / MIP BY2 | `0x3` | R8 UNORM/SNORM/UINT/SINT; R16 UNORM/SNORM/UINT/SINT/FLOAT |
| BY2 / MIP BY2 | `0xf` | RG8 UNORM/SNORM/UINT/SINT |
| BY4 / MIP BY4 | `0xf` | R8 UNORM/SNORM/UINT/SINT |
| PCK2 / MIP PCK2 | `0x1` | R8, R16, RG8 UNORM/UINT/SINT |
| PCK4 / MIP PCK4 | `0x1` | R8 UNORM/UINT/SINT |

The backend supplies the exact native format to translation. Separate UINT
and SINT sampled-image descriptor banks keep integer fetch results typed
correctly alongside the existing floating-point and comparison banks.
Descriptor layout, pool sizing and device limits account for both new banks.
Translation and resource keys distinguish formats, and the compute path stages
the sampled mip chain instead of binding only one storage-image level.
R16 SNORM also gains its missing native sampled-view format.

## Validation

The reproducible native probe is:

```powershell
zig build vulkan-smoke -Doptimize=ReleaseSafe -- --mimg-multi-texel
```

It runs guest MIMG kernels through the production decoder, resource discovery,
texture layout/upload, translator and Vulkan dispatch, then checks guest buffer
readback against a CPU oracle. The matrix covers all eight load encodings,
13 native formats, two mips, unaligned X, row/column/mip bounds, negative-looking
unsigned coordinates, normalization endpoints, sign extension, channel order,
untouched destination words and inactive EXEC lanes. Integer and packed results
compare exactly;
normalized floating-point BY results use a `0.000002` absolute tolerance.

- The RTX 3070 Ti probe passes **174 dispatches and 178,176 checked result
  words** with the Khronos validation layer enabled.
- All **18 focused MIMG tests** pass, including decoder rejection checks and
  translation in compute, vertex and fragment stages.
- All **231 Vulkan module tests** pass, including format-sensitive cache reuse.
- Native regression probes cover resident mip-chain updates, dynamic image
  descriptor waterfalls and integer color attachments.
- The full RDNA2 suite passes **263/273**. An isolated export of parent commit
  `2e895514909e2e700c0fe83df4c7868b3d991ab9` passes **259/269** with the same
  ten failing tests and the same leak in an existing failing FLAT-load test.
  The four new tests pass; the full suite is not reported as green.
- The final ReleaseFast runner builds successfully (9/9 steps). The installed
  `zig-out/bin/game-run.exe` and matching PDB are updated; the previous pair is
  backed up in the evidence directory. The runner is signed with the existing
  project certificate and a DigiCert timestamp. Windows still reports the
  existing certificate's untrusted root; no trust-store changes were made.
  Installed SHA-256:
  `0a0c924a1fe8b83762dae734dec46fcc610602f03929de0396bde1afc30f7a9c`.

Repeat the focused MIMG checks and the complete Vulkan module suite with:

```powershell
zig build test-rdna2 -Dtest-filter=MIMG -Doptimize=ReleaseSafe
zig build test-vulkan -Doptimize=ReleaseSafe
```

Build/test logs and baseline comparison evidence are retained locally in
`out/mimg-multi-20261009/` and adjacent `out/mimg-multi-*-20261009.log` files.

## Reference and remaining limits

The behavioral reference is the hardware-measured test matrix in the local
AnyPS5 checkout at `04477932167b27525d8c37e69bb9eb7a50048fe4`, particularly its
[BY correction](https://github.com/boykopovar/AnyPS5/commit/d5a3a4321cda8a84b25322015e26fc66cbffab7f)
and [PCK implementation](https://github.com/boykopovar/AnyPS5/commit/57d4be33bbab9f39396de4581f1ed39749c46a6d).
The earlier BY full-width interpretation is deliberately not used. PS5PCEM's
implementation uses its own decoder, SPIR-V builder and resource/cache paths.
This work executes the reference semantics on the host GPU; it does not add
a new console-hardware measurement.

Supported descriptors are full-width, direct, identity-swizzled 2D color
images with A16 and D16 clear. Other dimensions, indirect descriptor tables,
different DMASK combinations and unmeasured format combinations are rejected.
BY/PCK **stores remain unsupported**, with a specific diagnostic. Packed
SNORM/FLOAT and wider texel formats are not approximated. Live game captures,
performance gains and fixes to particular scenes require separate runs.
