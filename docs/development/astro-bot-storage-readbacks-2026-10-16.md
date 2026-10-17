# ASTRO BOT: storage copies and queue discovery, 16 October 2026

This development build measures the animated title of PPSA21564 v1.018 on a
Ryzen 7 7700 and RTX 3070 Ti, with the existing shader cache. Output is requested
at 1920×1080; the game still supplies a 3840×2160 scanout and internal passes up
to 2432×1368. These measurements do not establish character-controlled gameplay
or correct cinematic rendering.

The final uninterrupted run measures **20.0671 FPS over 2,640 frames in
131.5587 seconds**, with 60-frame blocks at **18.3862–21.6769 FPS**. This reaches
a 20 FPS title-screen average in this run; it does not establish a 20 FPS
minimum or a gameplay result.

![ASTRO BOT animated title after storage-copy and queue-discovery changes](../images/astro-bot-title-storage-readbacks-2026-10-16.png)

The renderer capture was taken at frame 7616, after the measured interval
(frames 4320–6960), with the logo and button prompt visible.

## Change

When a retired GPU storage image has already been replaced in guest memory,
the renderer previously copied its backing allocation before detecting the
replacement and discarding the old GPU contents. It now checks the existing
full-overwrite texel digest directly through the checked guest-memory callback.
A changed digest avoids that temporary copy and follows the existing
invalidation path.

The optimization requires an unpinned image, a changed nonzero page generation,
a retained texel-coverage baseline and an available fingerprint. Pinned images,
strict backing checks and unavailable fingerprints retain the previous path.
Unchanged texels and padding-only writes still preserve the GPU output. All
owned texel bytes participate in the digest; no draw or shader is skipped.

## Paired measurement

The comparison alternates 60-frame blocks across all eleven phases of the
title animation, twice per setting. Both settings run in the same process.
Compilation, profiling and frame capture run outside the timed interval.

| Setting | Frames | FPS |
| --- | ---: | ---: |
| Previous copied observation | 1,320 | 19.5490 |
| Direct replacement check | 1,320 | 19.9919 |

This comparison shows a **2.27%** improvement and **26.125 MiB less host copying
per frame**. It does not attribute differences from older, separate runs to
this change.

An uninterrupted check of this first candidate measured **19.9002 FPS over
2,640 frames**, with 60-frame blocks at **17.8589–21.2935 FPS**. It remained
below the 20 FPS target.

Copy-participant comparisons measured **19.5397 / 19.9074 / 19.9630 FPS** for
one, two and four participants, respectively (660 frames each). Four remains
the default. A subsequent 250/500-microsecond command-age comparison measured
**19.9911 / 20.0562 FPS**, 1,320 frames each. That 0.3% difference is
inconclusive; the existing 250-microsecond default is retained.

## Queue discovery

SDK11 queue discovery now remembers rejected pointer candidates only within one
publication for one queue owner. Registers and overlapping stack windows often
contain the same unrelated pointers. A bounded 64-slot table compares exact
address tags; collisions retain checked reads, and successful queue reads are
never cached. Each publication starts with an empty table, so reused addresses
and new queues are checked again.

The paired comparison measures **20.0872 FPS without** and **20.1519 FPS with**
this change, 1,320 frames per setting. The 0.3% difference does not establish a
meaningful FPS gain by itself; fewer repeated probes are the confirmed benefit.
The enabled blocks avoid **154,075 probes**, or approximately **117 per frame**.

## Validation

The candidate passes **274 ReleaseFast Vulkan tests**. The native full-image
overwrite probe passes **64 configurations** with Vulkan synchronization
validation and no validation errors. The probe now also checks an unpinned CPU
replacement and the avoided-copy counter. Existing cases cover pinned
replacement, padding changes, unavailable tracking/fingerprints, coverage
fallback and immediate/batched commands.

The queue-discovery change passes **680 ReleaseFast HLE tests**, including
colliding pointer tags, live generation changes, different owners and a new
publication discovering a queue at a previously rejected address.

The sampled title logs still report **12 unresolved storage bindings per
frame**, with no draw failures, dispatch failures or unsupported compute
operations. Compiler workers are idle in the measured interval. Known
cinematic defects and character control remain unverified.

Local comparison logs are in `out/astro-oct16-preflight126-measure.log`;
build and native-probe logs use `.codex-astro16-preflight126-*`. These are local
diagnostic artifacts, not repository assets.

The later queue comparison and uninterrupted confirmation are retained in
`out/astro-oct16-queue129-measure.log` and
`out/astro-oct16-final129-measure.log`. The installed `zig-out/bin/game-run.exe`
and matching PDB use the final candidate. The executable is signed with the
existing PS5PCEM certificate and a DigiCert timestamp. This remains a development
build; no new release version is assigned. The website has a new history entry,
capture and performance text in all eight locales.

`osslsigncode verify` succeeds using the project's public signing certificate
and the system timestamp trust store. Windows still reports the existing
self-signed-chain trust limitation. The installed executable's SHA-256 is
`CBB6A17F81725B8012E40F04EFF0A432AE49262E1A3B48DFEEDC404397464F99`.
Website type checking and all **145 tests** pass.
