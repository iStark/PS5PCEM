# AnyPS5 review: scalar buffers and split texture descriptors

October 14, 2026. Development build; reviewed local AnyPS5 revision
`c26982f63`. The user's reported **11 FPS in Yōtei is not independently
verified here**. Hardware, scene, settings and measurement method are unknown.
This work continues the ASTRO BOT comparison; it does not establish a new
Yōtei gameplay or completion result.

## Implemented and checked

RDNA2 S_BUFFER loads consume BASE, STRIDE and NUM_RECORDS. Vector format,
swizzle, type and ADD_TID fields are not operands of these scalar loads.
The host resource resolver now uses three descriptor words, including when
the fourth SGPR is unknown. The GPU path for runtime descriptors follows the
same rule. Vector accesses retain their own validation; address, extent,
partial-dword and checked-memory fault rules remain active.

This was identified while reviewing AnyPS5's
[unused scalar descriptor fields](https://github.com/boykopovar/AnyPS5/commit/aa2abf801bc4eaaba5ce6816b81c8f5a17157bcb)
and [reserved-field normalization](https://github.com/boykopovar/AnyPS5/commit/bfab566fe).
The independent Zig implementation follows
[AMD RDNA2 ISA, section 7.1](https://www.amd.com/content/dam/amd/en/documents/radeon-tech-docs/instruction-set-architectures/rdna2-shader-instruction-set-architecture.pdf).

Image descriptors can now be recovered from multiple scalar buffer loads of
one bounded record. Each part must have the same reaching index definition,
the same buffer descriptor and the expected contiguous byte offset. Immediate
additions must not wrap. Different indices, partial records, clobbered words
and unproven bounds retain the existing fallback. Invalid selected tuples
remain checked at execution time. This is a guarded implementation of the
pattern described in AnyPS5's
[split-record change for Yōtei shader 0x8000296000](https://github.com/boykopovar/AnyPS5/commit/55eefe9c5eb9a67a20183147aa68308c033192ca),
not a claim that every runtime table shape is supported.

Native tests execute both changes on the GPU. Scalar tests cover poisoned
unused fields, an unknown fourth SGPR, runtime offsets, byte/record extents
and incomplete final dwords. Checked-snapshot tests also retain missing-pointer
faults and overlapping-region selection. The split-record test alternates
red and blue textures, relocates the table, changes the colors, and verifies
every returned channel. It uses a 136-byte record, a 16-dword prefix load and
a second four-dword load at an added offset of 48.

## Other useful differences

| AnyPS5 change | Assessment for PS5PCEM |
| --- | --- |
| [Search regions under pending writes](https://github.com/boykopovar/AnyPS5/commit/1ce75da69a3ff735dae70e2fedf05d40f80961f2) | Our buffer overlap index and release projection already avoid broad scans in related paths. Further changes need measured call-site evidence. |
| [Retain immutable vertex layouts](https://github.com/boykopovar/AnyPS5/commit/c724c69324c5763d05da04b7c67cb7b87d5f4509) and [avoid cache churn](https://github.com/boykopovar/AnyPS5/commit/02e58e9936ca7703e9832cf18142c190129d9711) | Useful follow-up for static layout work; live addresses and descriptor checks must still run. No blanket vertex-layout port is claimed. |
| [Runtime image/sampler tables](https://github.com/boykopovar/AnyPS5/commit/d9e47d1e982a09ae3b013e5898fbb7175c6d9191) | PS5PCEM already has bounded table recovery and runtime descriptor lookup. The split-load case above was a concrete missing pattern. |
| [Table-loaded scalar calls](https://github.com/boykopovar/AnyPS5/commit/9c8fb780e8523bb5161b1cc42c54a0ce96f3e4e4) | Relevant to complex shader control flow. Existing PS5PCEM scalar-call support is not evidence that every indirect call shape is covered. |

## Measurements and limits

After the host scalar-descriptor fix, four command recording intervals were
compared in one warmed ASTRO BOT process. Each setting covers 660 frames across
eleven animation phases; builds, tests and profiling were stopped.

| Interval | Frames | Seconds | FPS |
| --- | ---: | ---: | ---: |
| 250 µs | 660 | 43.508 | 15.17 |
| 125 µs | 660 | 44.296 | 14.90 |
| 500 µs | 660 | 43.467 | 15.18 |
| 1000 µs | 660 | 44.070 | 14.98 |

The 250 µs default is unchanged: 500 µs does not establish a material gain.
The final build, including checked GPU reads and split records, measures
**14.97 FPS** over 660 warmed title frames (44.095 seconds) in a
separate process. This is not an A/B performance claim for the descriptor fixes.
**25 FPS is not reached.** Character control and later-scene rendering remain
unverified. The title still reports 12 unresolved storage-preparation bindings;
that counter alone does not prove that those instructions execute on the GPU.

![ASTRO BOT title after scalar descriptor fixes](../images/astro-bot-title-scalar-descriptors-2026-10-14.png)

Actual game-owned 3840×2160 scanout; host output remains 1920×1080.

## Validation

- **556/556 GPU and Vulkan tests pass**, including the new split-record proof.
- ReleaseFast game-run and native probe builds pass.
- Native scalar-buffer fields, scalar-buffer tables, unbound snapshots,
  split-image tables and workgroup image tables pass with Vulkan synchronization
  validation and no reported validation errors.
- The broader RDNA2 suite passes **285/295** tests. Its same ten failures and
  one reported test leak reproduce against clean source from `efe55a4` in an
  isolated baseline directory. These are recorded limitations, not a green
  full-suite result; no expectations were weakened to hide them.

Baseline/candidate failures:

- `GETPC SETPC continuation still exports position`
- `MUBUF glc controls atomic return-value writeback`
- `cross-dword short load and store lower as two byte accesses`
- `float transcendental VOP1 operations use explicit SPIR-V math`
- `fragment sample level zero accepts a packed texel offset before NSA coordinates`
- `merged NGG vertex prolog reaches its position export`
- `permlane mix and image resinfo lower`
- `three-coordinate image load follows a two-dimensional storage descriptor`
- `unmapped flat loads require an explicit zero fallback`
- `vertex PARAM export and fragment interpolation share a location`
