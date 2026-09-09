# Ghost of Yotei startup investigation

Observed with PPSA26344 and the RTX 3070 Ti; individual build results are dated below.

## Live labels inside retained command buffers on 2026-09-10

A scheduler regression reproduces another synchronization problem: a producer
writes a label embedded in a submitted indirect buffer, but the waiting queue
continues reading zero from its immutable command snapshot. The previous
implementation completes only the producer, leaving the consumer blocked.

`WAIT_REG_MEM` now has a separate backend read path. The scheduler forwards
that read to live memory while retaining the submitted commands and register
lists. Both 32-bit and 64-bit cases resume after the real producer write and
still execute the original command when the guest has recycled its source
bytes. Updating the snapshot alone cannot satisfy the wait. All 28 executor
and scheduler tests pass, including retained branches, queue ordering and
existing guarded recovery. This does not yet remove the HLE layer's older
forced-wait fallback for other unmet dependencies.
The 36 focused HLE tests also pass. The default Vulkan smoke and the
GPU-produced indirect-dispatch/GDS probe pass SDK synchronization validation
without VUID or synchronization-hazard reports.

## Overlapping command-buffer views on 2026-09-10

The first native flip reports the four-dword builder at `0x201160c0d4` as
orphaned even though the submitted 57-dword root at `0x201160c000` covers it.
Later quiet periods consequently replay that root's indirect tail. The ledger
only updated the first arena containing the submission's starting address;
it missed command-buffer views starting inside the submitted range.

Execution accounting now updates every overlapping view, retaining pending
suffixes and excluding adjacent ranges. A regression case covers the captured
57-dword layout and a subsequent partial extension. Thirty-six focused HLE
tests pass, including command-prefix guards, retained submissions and the
completion-table checks. Native performance with this accounting change is
being checked; no frame-rate gain is claimed from the unit test alone.

## Zero-initialized completion tables on 2026-09-10

The complete write/patch path restores intro playback. In the subsequent
native run the loading spinner appears, but progress stops at flip 914:
the main thread polls queue `0x38`'s generation 901 at `0x2000000060`, which
still contains 900, while both host command queues are empty. The shared
label-page cache remains zero. Its old discovery rule requires successor
indices in unused slots; those slots now contain zero. The next submission's
packet-local release value differs from its queue generation, so the fallback
cannot select the driver's completion slot.

Two distinct validated queue owners can now establish the shared page through
completed releases matching their generations. Their submissions must lie
inside their respective command ranges, their CPU label slots must be
different, and the memory values must confirm both completed hardware writes
and plausible preceding CPU generations. Repeated observations of one owner,
conflicting pages, unwritten releases and mismatched ranges do not establish
the page. Discovery does not change guest labels. Once established, the page
is retained until reset, including when later releases point into temporary
command arenas. Twenty-one focused HLE tests pass; native continuation past
flip 914 is being rechecked. The new native run confirms the expected shared
page `0x2000000000` during initial queue submission.

## ACB counter transfers and synchronization on 2026-09-10

The adjacent HLE audit confirms calls to placeholder ACB DMA, memory-write,
acquire, wait and event constructors, plus DCB `WRITE_DATA`. In particular,
the scene requests immediate GDS clears and GDS-to-memory counter copies.
Ignoring those operations prevents indirect dispatch arguments from reflecting
the GPU's current results.

These exports now emit the corresponding command packets. ACB wrappers retain
their distinct argument layouts; ACB `WRITE_DATA` converts its hardware
destination to the DCB selector format. Both variants copy the payload at
construction time, including address-zero packets whose payload is consumed
after a later destination patch. Acquire, DMA and write size queries match
their packets.

Seventeen HLE tests pass. The new integration case blocks on a guest label,
publishes copied data and the label through both write constructors, resumes
the waiting stream and verifies its DMA result. It also covers disabled address
increment and construction at address zero followed by a destination patch
and execution at an address above 4 GiB. Invalid packet patches preserve the
command. The first native run exposed the separate
`sceAgcWriteDataPatchSetAddressOrOffset` placeholder: the executor rejected
unpatched writes at address zero and stopped before the intro. That export
now installs both destination words while retaining the header, control and
copied data. Native startup is being rechecked with the complete path.
The Vulkan indirect-dispatch
probe additionally transfers GPU-produced arguments through GDS, destroys the
memory copy, restores it from GDS and verifies the resulting work and zero-count
case with SDK synchronization validation. Live scene validation remains pending.

## Indirect compute command construction on 2026-09-10

A filtered live HLE trace records both `sceAgcDcbDispatchIndirect` and
`sceAgcAcbDispatchIndirect` during scene rendering. Both exports still pointed
to the generic 16-dword NOP constructor, explaining why the command traces
contained no indirect compute dispatches despite the populated tile lists.

The DCB constructor now emits the three-dword offset form of
`DISPATCH_INDIRECT`; ACB emits the four-dword absolute-address form. The size
queries match the commands, and the existing `SET_BASE` path retains the
compute argument base. Constructor tests cover the address, offset, modifier,
cursor and packet boundaries. The `--indirect-dispatch` Vulkan probe checks
GPU-produced dimensions that remain deferred in a resident buffer, both
address forms, a nonzero base offset, changing group counts and zero work.
It and the default smoke pass SDK synchronization validation. The new live
render graph remains to be checked; the same HLE audit also found placeholder
ACB DMA, write and synchronization calls that require separate work.

The decoder also recognizes both RDNA 2 BVH intersection forms, including
their nonconsecutive address registers and A16 operand widths. Twelve MIMG
tests pass. This is operand decoding only; ray intersection execution remains
unsupported.

## Separate stencil operation values on 2026-09-09

The live material draws use `STENCIL_REPLACE_OP` with an always-pass stencil
test, a zero test reference and operation values including `0x80` and `0xa0`.
The host selected Vulkan REPLACE but kept the test reference, so these writes
produced zero. The frame-904 material classifier consequently sees an entirely
zero S8 plane at `0x5004850000`.

Reference selection now uses the operation value where Vulkan's shared
reference can preserve the guest comparison and any REPLACE_TEST writes.
Masked comparisons retain their comparison bits; incompatible overlapping
test/operation values still require a separate implementation. The expanded
`--stencil-only-ui` GPU probe fails on the previous backend and passes with
distinct operation/test values, masked EQUAL and LESS, front/back state and a
subsequent stencil-tested color draw. The existing clipped UI checks and default
smoke also pass SDK synchronization validation. Live lighting with this change
remains incomplete. A subsequent native frame captures 1,394 stencil texels
containing `0x80`, confirming that the operation value now reaches the material
classifier instead of being replaced with zero.

## Signed traversal-stack comparisons on 2026-09-09

The ray traversal shader at `0x8000173b00` also contains an unsupported
`V_CMPX_LT_I16` at PC `0x15d8`, comparing `v60.w1` against `s52.w1` through
SDWA. Decoding now preserves this signed comparison and lowers it through
the existing EXEC-only compare path. The `--scene-masks` GPU probe uses the
captured instruction encoding with positive/negative limits and opposite-sign
low halves. It verifies both wave halves, inactive lanes, untouched output
bytes and preserved VCC. The decoder test and default smoke also pass, with
clean SDK synchronization validation. The separate BVH intersection opcode
still requires implementation; this change alone does not execute the ray
traversal shader or establish complete lighting.

## Runtime buffer tables on 2026-09-09

The material classifier at `0x80003cb200` selects one of five V# descriptors
through `V_READFIRSTLANE` and a pointer-form scalar load at PC `0x50c`. Resource
preparation recovered its fixed buffers but omitted the selected output lists;
the store at `0x530` consequently had no host binding. Bounded constant
selections now retain every reaching lane value, and compatible V# tables
receive candidate bindings selected by all four live descriptor words.
Non-uniform storage-buffer indexing is enabled only when the device supports
the corresponding Vulkan feature. Each selected buffer retains its own bounds.

The frame-1263 classifier replay preserves captured inputs and initializes
only the five newly supported output lists to zero. It now produces all 24,335
nonzero coordinates of the 208x117 tile grid, with no missing, duplicate or
out-of-range coordinates. Coordinate zero is indistinguishable from unused
zero-initialized padding. The earlier renderer leaves all five lists empty.
The `--buffer-tables` GPU probe checks selected reads/writes, VCC_HI offsets,
unequal buffer bounds, untouched neighbours and relocated descriptors. It and
the default smoke pass SDK synchronization validation; all 16 index-bound
tests pass. Complete live lighting and menu composition remain unverified.

The subsequent live frame 904 binds all five classifier output buffers, and
later guest-memory snapshots contain their GPU-written coordinates. HDR inputs
remain finite but the displayed background is still too dark; this establishes
live buffer-table integration, not complete lighting. The same run preserves
the Digital Deluxe, Northern Star and pre-order notices and their Cross input.

## Avoiding repeated driver-cache writes on 2026-09-09

The intro's frame 128 spends 2,814 ms in presentation while persisting a roughly
1 GiB driver cache, despite compiling no new pipelines. Periodic persistence now
skips unchanged generations. Successful graphics, compute and detiling pipeline
creation updates an atomic generation; a save records the generation it sampled
so concurrent compilation still schedules a later save. The bounded file limit
also increases from 1 to 2 GiB: the subsequent scene reports 1,055 MiB and the
former limit discards every new snapshot.

The `--pipeline-cache` GPU regression fails on the former implementation because
an unchanged periodic snapshot rewrites the file. It now preserves the timestamp
and verifies that later compilation produces a new snapshot. This probe and the
default Vulkan smoke pass SDK synchronization validation. The capacity change
addresses repeated-launch compilation; it does not establish a steady-frame FPS
gain or complete scene rendering.

The live run subsequently persists a 1,057 MiB driver cache successfully.
A cold scene frame spends 121,600 ms compiling 199 compute pipelines; this is
first-use compilation and is not a steady-frame FPS measurement.

## Signed normalized color attachments on 2026-09-09

After the experience selection, frame 1317 rejects five draws into the
256x256 target at `0x50bdb70000`: color format 5, number type 1. The renderer
already supports sampling RG16_SNORM, but its color attachment mapping omitted
this format. It now creates an R16G16_SNORM attachment for these draws.

The normalized-color GPU probe switches the same resident target between
UNORM and SNORM and verifies distinct positive and negative exports. It fails
before this correction and passes afterward, alongside the default Vulkan
smoke with SDK synchronization validation. Live scene verification is pending.

## Repeated HDR metadata clears on 2026-09-09

The frame-1242 trace clears the HDR attachment's DCC key at `0x508be3e000`
before the material passes, without rewriting the color allocation at
`0x505ab20000`. Initial attachment staging interprets that key, but subsequent
metadata writes left the resident image unchanged. Complete, uniform fixed-color
DCC writes now clear supported resident color attachments on the GPU and publish
a new image generation. Partial, mixed, compressed and comp-to-single keys retain
their separate handling.

The `--dcc-metadata-clear` GPU regression fails on the former implementation:
it retains half-float `0x3400` where the metadata requests zero. The correction
passes five repeated RGBA16F clears, direct PM4 writes, DMA fills, and checks
that partial/mixed/uncompressed metadata preserves existing pixels. This suite,
the RG16F comp-to-single suite and the default Vulkan smoke pass SDK
synchronization validation. In the subsequent live frame-904 capture, all
6,230,016 pre-sky HDR texels are finite; the earlier frame-1242 capture contained
4,475,397 red-channel NaNs. These are different scene frames, not a matched
performance comparison. The live run preserves the intros, rotating spinner,
three bonus notices, brightness, difficulty and experience selection. The
complete scene still lacks lighting.

## Ordering a 64-lane wave's LDS accesses on 2026-09-09

After the LDS width/address fixes, the live exposure volume stays within
`-8.53125..15.0859375` instead of reaching thousands. Frame 926 still exposes
439 incorrect components in the X filter, confined to columns 28 through 35.
Its single 64-lane guest wave reads neighbouring LDS values across the boundary
between NVIDIA's independently scheduled 32-lane subgroups. A buffer-load-free
exchange probe did not reproduce the race; the captured image-fed filter did.

Straight-line compute blocks containing one complete 64-lane guest wave now
synchronize workgroup memory between LDS instructions. The single-block condition
keeps these barriers outside divergent guest control flow. Wave32, larger
workgroups and branching kernels retain their existing synchronization paths.
This follows Vulkan's explicit [workgroup memory synchronization requirements](https://docs.vulkan.org/spec/latest/appendices/memorymodel.html).

With the same captured input, all 262,144 output components of the X filter now
agree with an independent CPU convolution within one half-float ULP, including
the former cross-half seam. The `--lds-wave-memory` GPU probe exchanges B64
values after buffer loads across 64 workgroups, changes all inputs eight times,
and checks a wave32 control with an explicit barrier. The former implementation
fails; the corrected implementation passes this probe, the paired/address-alias
LDS suite and the default GPU smoke under SDK synchronization validation. All
16 focused LDS CPU tests pass. Complete live menu composition remains pending.

## Paired 64-bit LDS accesses on 2026-09-09

The exposure-grid filter at `0x80003f6100` reads neighbouring pairs with
`DS_READ2_B64`. The decoder incorrectly scaled their offsets as 32-bit words,
and translation transferred only two of the four destination words. Paired
64-bit reads and writes now use eight-byte offset units and transfer both
words of each value; their stride-64 forms use 512-byte offset units.

The `--paired-lds64` GPU regression compares paired accesses with independent
single-value accesses in both directions, using unequal offsets and four
distinct words. The previous implementation fails; the corrected implementation
passes ordinary and stride-64 cases under Vulkan SDK synchronization validation.
It also verifies 64 independent ADDTID lanes with an M0 base and instruction
offset: those instructions now request lane identity even without explicit EXEC
access. All 16 focused LDS tests and the default GPU smoke pass. Live exposure
and complete-menu validation remain in progress.

The same filter reads two 32-bit words into `v12:v13` using the original `v12`
as its address at PC `0xec`. Publishing the first result before computing the
second address redirected that second read. Contiguous and paired LDS reads
now load every word before writing any destination register. Fourteen GPU cases
cover first/interior address overlap for paired B32/B64 and contiguous
B64/B96/B128 reads, including both stride-64 forms. The previous code fails on
the first paired B32 case; the correction passes these cases, the existing LDS
suite and the default GPU smoke with clean SDK synchronization validation.

The filter's coherent frame-936 capture was replayed on the RTX 3070 Ti and
compared against a separate CPU nine-tap convolution of its captured RG16F
input. Out of 131,072 output texels, 27,044 exceed one half-float ULP before
either LDS correction, 16,994 after the paired-width/offset correction alone,
and zero after retaining the original address as well. The final replay also
passes SDK synchronization validation. Its input still contains large moment /
weight ratios: the preceding X filter at `0x80003fb200` has the same address
overlap at PC `0xbc`, so the complete live exposure chain still needs validation.

## Retaining dense lighting constants on 2026-09-09

The dense environment shader at `0x80001fd400` completes its CPU resource walk
in 3,901 instructions, but needs 250 distinct scalar-load observations. The
128-entry observation table silently omitted its later coefficients. Its
bounded capacity is now 512, including the corresponding dynamic scalar buffers.
Increasing the instruction budget alone from 16,384 to 262,144 produces identical
outputs and does not fix the missing constants.

A coherent capture retains the prepared GPU images and buffers, current CPU
parameters and complete sampled allocations. Replaying it with all 250 loads
fills both formerly empty RGB volumes at `0x50a3e9b000` and `0x50a479b000`:
each contains 2,359,296 nonzero, finite texels. The complete volume dispatch
passes Vulkan SDK synchronization validation. Supplying its corrected outputs
to the captured main-lighting dispatch increases nonzero HDR RGB pixels from
474,564 to 3,811,361. This verifies propagation into scene geometry; it does
not yet establish a complete live title menu.

The main-lighting shader itself retains all 99 scalar loads. Its outputs match
byte for byte at dispatcher budgets 256, 512, 1,024 and 2,048, so its default
budget remains unchanged. Diagnostic scans beyond empty texture allocations now
run only with verbose logging; those reads never contributed image data.

The `--distinct-scalar-loads` GPU regression checks 320 distinct loads into a
reused SGPR across 64 lanes, changes every input value, and verifies reuse of
the same pipeline. The former backend fails at load 128; the corrected backend
passes this probe, repeated-load loops, sampled-write refresh and the default
compute/graphics smoke under SDK synchronization validation.

## Storage writes invalidate sampled snapshots on 2026-09-09

With canonical image aliases disabled, sampled-cache keys omitted resident
storage-image sequences. A compute write through another format or extent could
leave a previously uploaded sampled view unchanged: the early cache hit bypassed
publication, and sparse CPU probes could also miss the modified texels after
publication. The cache key now includes the storage sequence at the allocation
base, including already-published writes.

The GPU regression samples a 64x64 RGBA8_UNORM view, writes the same allocation
as 128x32 R32_UINT, then samples again. It checks every RGBA component for pending
and explicitly published writes, changes the sampler, and verifies that repeated
unchanged reads do not upload again. The previous backend fails; the corrected
backend passes SDK synchronization validation. Yotei reuses the observed
`0x500e870000` and `0x500f870000` allocations with differing sampled/storage
extents. Their role in the missing background still requires live verification.

The same regression also fails when the producer writes a deferred 256 KiB raw
buffer instead of an image. Buffer sequences now participate in sampled-cache
keys in both alias modes. Pending/published writes, changed samplers and repeated
reads pass for both producer types under SDK synchronization validation.

## Repeated velocity clears and scene bounds on 2026-09-09

After the three bonus notices, brightness, difficulty and experience selection,
the scene retained large radial streaks. The camera-reprojection shader produces
small velocities in an isolated replay with its captured matrix and depth data.
The live velocity attachment instead retains the same large values across frames.
AGC clears it with one RG16F texel per 256-byte block and a uniform `0x10` DCC
key. Updating only the buffer leaves the already resident attachment unchanged.
The matching complete clear now updates that RG16F attachment on the GPU,
including the NaN sentinel consumed by the camera-reprojection pass.

The regression probe fails with the previous clear path and passes with the
fix. It renders between repeated clears and checks every pixel for finite,
NaN and infinite values. SDK synchronization validation reports no errors.
Live scene verification is still required; this is not a complete-menu claim.

The later scene-bounds kernel at `0x800018b800` uses the existing scene-object
layout with different pointer registers. Its root/header/168-byte-record walk
now receives the same bounded FLAT snapshots as visibility. Both instruction
variants pass relocated-record, count-bound and unmapped-read checks under
SDK synchronization validation.

## Completing the multiple-scattering pass on 2026-09-09

Shader `0x80003a9b00` integrates a 16x32 angular grid. The default 16,384-step
CPU resource walk stops inside those loops, leaving its later coefficients
unrecovered. The default GPU dispatcher budget also ends before the output
stores. Its validated instruction/dispatch shape now receives a 65,536-step
resource budget and 1,024 dispatcher visits; other shaders retain their defaults.

The captured first five atmosphere passes were replayed with the complete
tiled allocations retained between stages: 4 MiB for each RGBA16F volume and
2 MiB for each RG16F volume, including padding. The multiple-scattering outputs
are populated and finite. All four affected images match byte for byte at
1,024 and 2,048 dispatcher visits, while 512 leaves its new outputs empty.
The production replay passes SDK synchronization validation. All 76 scalar,
binding and resource tests pass, including budget exhaustion, recovered late
loads/checkpoints and changed data in a 5,000-iteration resource walk.

The rebuilt runner confirms populated outputs through all five live scattering
orders. At frame 778, the lunar lookup textures contain 1,024/1,024 and
8,192/8,192 nonzero texels, and the volume-lighting pass also produces RGB
data. The solar lookups remain empty with the sun below the horizon. This
establishes propagation into later lighting passes; complete scene composition
is still being investigated.

## Atmosphere arithmetic on 2026-09-09

The analytic atmosphere producer exposed two general translation errors.
`V_SIN_F32` and `V_COS_F32` take turns, but were passed directly to GLSL's
radian operations. They now reduce the turn value before multiplying by
2 pi, with exact quadrant results, signed zero and finite large inputs.
`V_CNDMASK_B32` input ABS/NEG modifiers were also applied as integer arithmetic;
they now operate on the floating-point sign bit while retaining the selected
payload's exact bits. Both semantics are specified in the
[AMD RDNA2 ISA reference](https://docs.amd.com/api/khub/documents/Et~wpu9g~Ffl7d9q0QZ~Og/content),
sections 12.7 and 12.8.

In the captured analytic dispatch, the two scattering outputs previously
contained 174,835 and 173,235 infinite half-float components. With both fixes,
all four producer images have no NaNs or infinities. This is intermediate
resource validation; the complete live menu remains under investigation.

The GPU trigonometry probe checks positive/negative fractional turns, exact
quadrants, signed zero, large finite inputs, NaN/Inf and refreshed input through
the same pipeline. The selection probe checks 128 combinations of source,
ABS/NEG and zero/NaN/integer payloads. Both, the existing SDWA cases and the
default smoke pass SDK synchronization validation.

## Predicated compute image reads on 2026-09-09

The first-frame atmosphere conversion shader `0x80003fa600` reads two resident
32x128x32 images inside a `CMPX` branch. Translation incorrectly treated the
per-invocation EXEC predicate as a reason to use graphics sampled-image bindings.
The compute dispatch has storage bindings, so both reads silently became zero.

Compute image reads now retain their storage bindings under predicated EXEC.
An isolated replay of the captured producer and converter in one renderer
changes both final scattering tables from all zero to populated images. The
new `--image-exec` GPU probe verifies a 64-lane conditional copy, its complementary
clear branch and changed input through reused image views. It, the captured
atmosphere chain and the default smoke pass SDK synchronization validation.
The analytic producer still generates some nonfinite values; full live scene
validation continues.

## First-frame atmosphere initialization on 2026-09-09

A diagnostic run with startup suppression and covered-scene elision disabled
exposes a persistent atmosphere calculation in the first frame, before the
video decoder starts. Its 32x128x32 tables at `0x50c92e0000`, `0x50c96e0000`,
`0x50c98e0000` and `0x50c9ce0000` are consumed by the later sky and volume passes.
The default 32-frame compute suppression discarded their entire producer chain.
Two tables become nonzero in the diagnostic run; their derived sky textures
contain 5,536 nonzero texels at frame 935, versus zero with startup suppression.
The scene still lacks its normal background.

The first-frame atmosphere shader `0x800038a300` exposes a second failure.
Repeated invariant SMEM loads exhaust the scalar evaluator's 128 load records,
so constants read after its 50-sample loop never reach translation. Identical
load observations now share one record; changed values, addresses and provenance
remain distinct. The captured dispatch uses 61 scalar values instead of 258 and
recovers its post-loop coefficients. All 33 scalar-provenance tests pass. The GPU
scalar-loop probe checks 200 repeated reads followed by a distinct load, changing
parameters and the completed iteration count across 64 invocations; it passes
SDK synchronization validation, as do the scalar-pointer probe and default smoke.

That atmosphere program also exceeds the default 256-block dispatcher budget.
Its identified instruction/dispatch shape now receives 512 visits. Captured
replays at 512 and 1,024 produce byte-identical outputs and pass synchronization
validation. Some intermediate values remain nonfinite, so this establishes
resource recovery and loop coverage, not physically correct atmosphere output.

Normal startup no longer suppresses the first 32 compute frames. The explicit
diagnostic override remains available, and fullscreen video prioritization still
starts when a decoder becomes active. The combined live build executes the
entire first-frame chain and retains the populated analytic outputs. Its
conversion outputs exposed the predicated image-read defect described above.

## Depth-only extents and scalar uploads on 2026-09-09

A live shadow pass binds uncompressed depth at `0x5031be0000` with
`DB_DEPTH_SIZE_XY = 0`, a 1024x1024 viewport/scissor, depth testing and writing
enabled, and no color outputs. The renderer retained a 1x1 attachment because
extent recovery previously required HTILE. The same reset size also appears
on half-resolution depth targets used later in scene composition.

Extent recovery now accepts active uncompressed depth-only writers. A stale
uncompressed depth binding alongside active color outputs remains subject to
the undersized-attachment guard used by UI draws. Read-only and disabled-write
bindings also retain that guard.

The new GPU probe exposed a second defect: the temporary graphics path used
for depth-only draws neither uploaded dynamic graphics scalars nor bound the
descriptor set when scalars were its only resources. It now does both, matching
the persistent color-target path. The probe alternates a vertex scalar between
two depths and reads the attachment through compute at its center and four
corners, with viewport and scissor-only extent recovery. It passes SDK
synchronization validation, as do the default smoke and UI attachment probes.
Both extent guard unit tests pass. The live run confirms 1024x1024 shadow depth
and 1920x1080/1664x936 intermediate depth instead of 1x1, with the spinner and
bonus notice preserved. Its scene background remains incomplete.

## Fragment position inputs on 2026-09-09

The low-resolution lighting filters `0x80003e5900` and `0x80003db900` read
screen position directly from entry VGPRs. A live state capture records
`SPI_PS_INPUT_ADDR = SPI_PS_INPUT_ENA = 0x302`: one interpolation pair occupies
`v0:v1`, followed by pixel X/Y in `v2:v3`. The translator previously initialized
these position registers to zero, making screen-space samples use the origin.

Fragment translation now initializes enabled position inputs from Vulkan
`FragCoord`, including depth and reciprocal W. Register allocation follows
INPUT_ADDR independently of INPUT_ENA, retaining disabled interpolation and
position slots. The register fields are documented in AMD's
[RDNA2 register definitions](https://github.com/torvalds/linux/blob/v6.14/drivers/gpu/drm/amd/include/asic_reg/gc/gc_10_3_0_sh_mask.h);
[LLVM's PS input allocation](https://github.com/llvm/llvm-project/blob/llvmorg-20.1.0/llvm/lib/Target/AMDGPU/SIISelLowering.cpp)
also distinguishes allocated inputs from enabled ones.

The `--fragment-position` GPU probe checks all pixels of a covering triangle
across 20 cases: allocation holes, disabled position components, shader/pipeline
reuse, both viewport signs, both clip-depth conventions and inputs surviving
a loop. It also overwrites X under a divergent execution mask, then verifies
both the updated and retained coordinates after the branches merge. Entry
position values retain the integer bit representation used by register snapshots;
otherwise a live filter produces an invalid mixed-type `OpPhi` and faults inside
the NVIDIA shader compiler. The extended probe and complete default smoke pass
SDK synchronization validation. The existing fullscreen orientation probe also
passes. In the subsequent live scene, both formerly empty filter outputs contain
nonzero RGB texels (38,257 after the second filter at frame 935). All three bonus
notices and the complete brightness screen remain visible. The HDR scene still
contains mostly darkness and fire before the later transparent composite, so
this correction alone does not restore the background.

## Native environment-volume execution on 2026-09-09

A captured dispatch of `0x8000253100` now stages, translates and executes on
NVIDIA without validation errors in an isolated replay. Starting with empty
output allocations exposes a separate limit: the default dispatcher budget
stops the captured 64-slice calculation after slice 27. A budget of 2,048 block
visits reaches slice 63. Single-group, 64-group, 2,240-group and the exact
`1x64x36` dispatch pass SDK synchronization validation.

The renderer now runs this identified guest kernel with the larger bounded
budget. Its former neutral-color volume replacement is removed. Other kernels
retain the existing default. A GPU regression checks early termination with a
small budget, a complete 512-iteration loop and reuse of the earlier pipeline;
that probe and the default smoke pass validation. These checks establish
execution and coverage, not correct final lighting: two captured RGB outputs
remain zero, and a complete live scene check is still required.

The dense scene switches to a second volume program, `0x80001fd400`, with
4,384 instructions and five outputs. It uses the same `1x64x36` dispatch and
`4x4x4` local size. A captured replay with initially empty outputs reaches only
scattered pixels through slice 16 under the default budget. The same workload
with 2,048 visits fills all 36,864 texels in every slice of `0x50a599b000` and
calculates the visibility volume through slice 63. The full dispatch passes
SDK synchronization validation. Three RGB outputs remain zero in this replay;
their inputs include live resources outside the captured parameter pages, so
this is a coverage check rather than a synchronized lighting reference.

Both program shapes now receive the bounded volume budget. The first live
build with native startup-volume execution preserves the spinner and bonus
notice, but its scene compositor still contains mostly darkness and partial
fire. Live validation of the second program's increased budget is pending.

## Indirect command tail chains on 2026-09-09

The comparison-destination build still produces a black trunk and records
`IndirectBufferTooDeep` during the first dense scene submission. The executor
treated every `INDIRECT_BUFFER` as a nested call, including packets with CHAIN
set. CHAIN now replaces the current indirect stream in a loop; only actual
calls consume the bounded return stack. Wait continuations retain both the
parent's selected entry and the current chain target, so conditional branches
remain selected and completed links are not replayed after a wait.

Submission snapshots follow the same tail jumps and stop at the end of a
chained parent. All 45 executor/scheduler tests pass, including a 150-link
chain, repeated waits, conditional branch retention, recycled source commands,
cycles and the unchanged bound on genuine nesting. The unreadable-range test
now derives its address from the fixture's actual memory size. The live run
passes dense scene loading without `IndirectBufferTooDeep` and preserves all
three bonus notices. Its frame-1030 composite still has a black trunk and
partial fire; normal scene composition is not yet achieved.

## Explicit VOP3 comparison destinations on 2026-09-09

The depth-storage trace now records 3,811,120 nonzero depth texels from
`0x80003d6000`, but the final trunk remains black. Inspecting the material-list
classifier `0x80003cb200` exposes another missing producer: its instruction
`d4e4001c 00010018` compares a 64-bit mask into `s28:s29`, then scalar mask
arithmetic consumes that pair. The decoder previously redirected every VOP3
comparison to VCC, leaving the encoded destination unwritten.

VOP3 comparisons now decode their scalar destination from VDST. VOPC retains
its implicit VCC destination and CMPX retains EXEC. Explicit comparison
destinations are also exercised by the
[LLVM AMDGPU comparison tests](https://github.com/llvm/llvm-project/blob/llvmorg-20.1.0/llvm/test/CodeGen/AMDGPU/llvm.amdgcn.icmp.w64.ll).

All 39 vector decoder tests pass. The GPU mask suite checks 120 combinations
of SDWA, VOP3 and 64-bit saved-mask comparisons, explicit SGPR/VCC destinations,
empty/full/complementary EXEC and 64/512 invocations. The previous decoder fails
the saved-mask case, rejecting a lane that should execute. The corrected suite
and full default smoke pass SDK synchronization validation. The broader RDNA2
unit suite still has the same ten failures reproduced against the previous
decoder; this change adds no failures there. The live run preserves the bonus
notices and nonzero depth, but its captured final trunk remains black.

## Independent depth/stencil attachment planes on 2026-09-09

The live depth-storage build preserves the movie, loading spinner and first
bonus notice. Its cache confirms two 3328x1872 attachments sharing D32 address
`0x5002870000` with different S8 addresses, `0x5004850000` and `0x505f350000`.
Previously, changing that pairing selected an independent Vulkan image and
lost the current contents of the shared plane.

Attachment acquisition now inherits each shared plane from the most recently
used compatible resident attachment. A new packed image initializes its other
plane separately; existing unrelated depth/stencil contents remain intact.
Copies stay on the GPU and require matching format, extent, samples and guest
subresource. Storage snapshots observe the resulting generation change.

The depth-storage GPU probe now also alternates three depth/stencil pairings,
changes each plane independently and checks both new and reused attachments.
With inheritance disabled it reads zero instead of depth 0.25. The corrected
probe and full default smoke pass SDK synchronization validation without
validation errors. Complete live scene verification remains pending.

## Depth/stencil storage hand-off on 2026-09-09

The vertex-entry correction restores colored bark in the live material target.
All three bonuses and the full brightness screen remain visible, followed by
difficulty selection. The final scene still has a black trunk. A capture of
`0x8000243500` confirms that the silhouette is already black in its HDR output,
before temporal reconstruction or display composition.

Storage-image preparation previously recognized resident color attachments but
not depth/stencil attachments. With the default CPU depth transfers disabled,
`IMAGE_LOAD` could read an old zero-filled color copy of a newly rasterized D32
or S8 plane. Sampled-image preparation could then reuse that stale copy too.

Exact single-sample D32/R32_FLOAT and S8/R8_UINT views now exchange their payload
with the resident attachment through ordered GPU buffer copies. A snapshot
tracks the source image and write generation, is refreshed after a later depth
write, and stays resident across repeated consumers. Compute stores return to
the corresponding attachment aspect before subsequent rasterization. Guest
writeback remains deferred until an explicit CPU consumer.

The `--depth-storage` regression reads both planes twice across two clears,
checks that guest allocations remain untouched, and verifies compute writes
through attachment readback. Without the new hand-off it reads zero instead of
depth 0.25. The corrected path and full default smoke pass SDK synchronization
validation. Full live scene verification with this correction is pending.

## Vertex entry registers and attribute recovery on 2026-09-09

Comparing the material traces before and after graphics scalar retention
isolates a regression in tree program `0x806ee0be00`: its main color output
disappears while the depth silhouette remains. AGC attribute recovery pairs
buffer descriptors with the registers used by later MUBUF instructions, then
incorrectly installs those descriptors as initial SGPR values. This overwrites
merged NGG inputs, including `s3`'s active-wave counts and user-data pointers.
The former broad scalar-range deletion hid this unrelated initialization bug.

Attribute descriptors now seed only the CPU evaluation used to prepare buffer
resources. The shader retains its actual entry ABI and recovered SMEM loads at
their producer PCs. This preserves the compositor's scalar-lifetime correction
without discarding all constants that happen to reuse V# register numbers.

The GPU regression supplies AGC vertex metadata, reads the merged wave-count
input before loading a descriptor into the same SGPRs, and rejects the triangle
if that entry value changed. It fails against the previous backend and passes
with this correction, together with the full default smoke under SDK
synchronization validation. An offline replay using captured shader
headers and matching prepass/material state restores colored bark; complete
live scene verification is pending.

The replay also exposed duplicate `SubgroupLocalInvocationId` input declarations
when graphics lane identity and DPP/permlane shared a shader. They now reuse one
input. Identity DPP operations in both graphics stages exercise this in the GPU
probe, with no `VUID-StandaloneSpirv-OpEntryPoint-09658` validation error.

## Half-register writes and temporal resolve on 2026-09-09

The captured temporal upscaler `0x1d85d00` exposes several independent
half-register errors. SDWA destinations previously overwrote the complete
VGPR, losing packed A16 coordinates and adjacent color/filter values. The
destination path now implements byte/word selection with zero padding, sign
extension or preservation. Ordinary single-result F16 operations also retain
the other half, including a native exponent or multiply after a high-half
SDWA write. EXEC-disabled lanes retain their original complete register.

VOP3A now decodes input half selectors and the destination half for supported
F16 results. F16 input modifiers operate on the floating value; inline float
constants use their half-precision representation. MIN3/MAX3/MED3 consume all
three inputs, and MIX shares the same half-input conversion. These follow the
[RDNA2 instruction semantics](https://docs.amd.com/v/u/en-US/rdna2-shader-instruction-set-architecture).

The `--sdwa` GPU probe checks 39 numeric cases, including packed coordinates,
all destination modes, high-half selection, native writes, modifiers and
inactive lanes. It and the 13 packed-float cases pass the complete Vulkan
smoke under SDK synchronization validation; 29 focused VOP tests also pass.
An offline replay of the unmodified captured upscaler uses a constant
16x16 HDR input `(0.25, 0.5, 1)`. Before the final preservation correction its
center output is approximately `(4100, 8192, 16384)`. It now returns
`(0.250244, 0.499756, 0.999512)`, with RGB output at all 256 pixels in both
color targets and no validation errors.

The rebuilt live run preserves all three bonus notices and the complete
brightness screen (wolf, slider and Cross). Ordinary Cross confirmation then
reaches difficulty selection and Standard experience selection over a rendered
tree and orange fire. This is the final scanout image, not an intermediate
buffer substituted for presentation. The trunk is still a black silhouette,
so complete scene rendering remains unresolved. Frame 1010 has nonzero temporal
upscale, HDR resolve and composition, while its main material color attachment
is zero. After confirming Standard, the game proceeds into further scene work;
that transition is substantially slower than the preceding warm UI frames.

## Normalized fragment exports on 2026-09-09

The tree material programs export a mixture of FP16 color, UINT32 data and
UNORM16 normal components. Their `SPI_SHADER_COL_FORMAT` is `0x44514`.
Translation previously unpacked every compressed floating-output export as
FP16, misinterpreting normalized integers. The packed payload now follows the
per-target export selector, independently of the attachment storage format.
UNORM16 and SNORM16 use their normalized unpack operations; existing FP16 and
integer output handling is retained. The selector is part of the translation
cache key. Register selector values follow the
[AMD shader color-format definitions](https://www.amd.com/content/dam/amd/en/documents/radeon-tech-docs/programmer-references/CIK_3D_registers_v2.pdf).

The mixed-MRT GPU probe checks FP16, UINT32, UNORM16 and SNORM16 output through
guest-memory readback. It passes SDK synchronization validation, as does the
default smoke run. Live scene verification is pending; this correction alone
does not explain the still-empty material color attachment.

## Material selection and attachment reads on 2026-09-09

A fresh run of `0ac4a2e` displays the loading indicator and Digital Deluxe
Bonus, then accepts Cross and displays Gift of the Northern Star. A trace of
frame 1005 identifies two remaining draw refusals in the streamed scene.

Pixel program `0x8000273400` samples a 136-byte material table at `0x23b4`.
Its index comes from a texture gather, with a conditional selection replacing
only some lanes. Requiring one vector definition loses the integer texture's
bound. The resulting wrapped-offset scan treats ordinary float fields as T#
descriptors, including a false 1D-array address `0x3e4ccccd00`. Index recovery
now merges the possible producers, retaining earlier values in inactive lanes.
It remains unbounded if any path reaches an uninitialized value or the mask
proof is incomplete. The captured shader resolves to its gather and conditional
selection producers. GPU cases cover conditional replacement, skipped branches,
signed/unsigned byte and short indices, and descriptor-like decoy fields.

The decal passes also prepare the same `IMAGE_LOAD` as both a sampled fetch
and a storage image. Translation chooses the exact sampled mapping, but the
unused storage alias rejects the draw when it overlaps a color attachment.
Resource preparation now follows that translation choice. Sampled feedback
recognition includes every active color attachment, including secondary MRTs.
Writes retain their existing storage-image handling.

A queued-draw regression additionally exposed stale sampled snapshots with
canonical alias tracking disabled: three additions of 0.25 returned only 0.25.
Completed-frame generations advanced only during readback, so the texture cache
could accept its old copy before publishing the pending attachment write.
Sample generations now also include the resident attachment sequence. The same
regression returns 0.75 after three queued draws. The full Vulkan smoke,
descriptor-reuse, typed-index and selected-index probes pass SDK synchronization
validation; the index-analysis suite passes 88 tests.

The rebuilt runner reaches Digital Deluxe Bonus with readable text and its
Cross glyph. Frame 1006 accepts the material and decal passes; the run records
no `UnsupportedSampledImage` or `UnsupportedStorageImage` refusal. Its G-buffer
contains the textured tree, and the later HDR input contains orange highlights,
while final composition remains black behind the notice.

This also exposes an obsolete empty-scene HDR workaround. Program
`0x8000405d00` samples the intermediate lighting/upscale result, not the original
G-buffer. Checking that input for raster exports cannot establish an empty
scene. The workaround substituted constant HDR and a fixed-size RG16F plane,
including when dynamic resolution used different dimensions. The normal
translated resolve and the game's clears are now restored. The captured
compositor uses that RG16F plane for UV displacement; its previous description
as exposure was incorrect. The full
Vulkan smoke passes synchronization validation after removing the workaround;
fresh live verification of complete title-menu composition is still pending.

The native resolve run preserves all three bonus notices and the brightness
screen, including the wolf, slider and Cross glyph. In frame 1002, however,
the temporal upscaler reads an older 3840x2160 target at `0x505ab20000`
(slot 27), while the latest raster output occupies its 3328x1872 view
(slot 34). All three upscale outputs and the following HDR resolve are zero.
Storage-image binding now selects the newest compatible resident target; if
only an older, larger target covers the requested extent, its overlap is
refreshed from the latest view on the GPU. A regression queues a red 32x32
raster output after a blue 64x64 view of the same allocation. Both 32x32 and
64x64 storage consumers read the new red pixels under synchronization validation.

Upscaler program `0x1d85d00` also uses A16 integer addressing at `0x100`,
packing X/Y into the low/high halves of one VGPR. Image loads, stores and
atomics now unpack integer A16 coordinates rather than treating adjacent
VGPRs as independent 32-bit coordinates. A 4x4 GPU copy probe poisons that
adjacent register and checks every resulting texel. The full Vulkan smoke
passes synchronization validation with both fixes. Floating-point sampler
A16 and packed D16 image data remain outside this change.

Frame 1006 of the A16/DRS runner confirms that the upscaler now reads the
latest 3328x1872 target (slot 34). Its final color output remains zero. The
captured upscaler also contains VOP3P MIX instructions, including `0x81c`,
which were incorrectly translated as ordinary F32 FMA. Packed F16 add,
multiply, FMA, min and max ignored half selectors and applied integer negation
to the packed word. Translation now follows the
[RDNA2 VOP3P semantics](https://docs.amd.com/v/u/en-US/rdna2-shader-instruction-set-architecture):
MIX selects input precision and halves, applies ABS before NEG, and packed
operations select and negate each input half separately. Floating inline
constants use the RDNA2 low-half F16 encoding. The packed FMA uses a fused
operation. The same MIX source handling corrects the F16-result variants.

The new `--packed-floats` GPU probe has 13 numeric cases, also included in
the default smoke. An isolated build with the preceding translator fails
the first case (`0xc4803200` instead of `0x40d00000`, or 6.5). The corrected
translator passes every case and the full Vulkan smoke under SDK
synchronization validation. The live run preserves all three bonus notices,
brightness and difficulty selection. Frame 1172 contains nonzero temporal
upscale and HDR resolve output, but compositor `0x80003b7100` still exports
black RGB before the interface is drawn.

The compositor exposes a separate scalar-lifetime bug: graphics resource
preparation deletes every scalar seed in a T#, S# or V# register range.
The shader later reuses those ranges for color matrices, viewport limits and
other arithmetic. Losing even part of a recovered wide load makes translation
fall back to zero for the entire load. Graphics preparation now retains each
load with its producer PC, including initial user data. Dynamic scalar uploads
already exclude the values from translation cache keys, so changing guest
addresses does not require deleting these register lifetimes.

A GPU regression samples a texture and reads a buffer, then reuses all three
descriptor register ranges for color parameters. Two draws return the expected
RGBA values `{32,127,191,255}` and `{96,127,191,255}` with no additional pipeline
miss on the second draw, even when both its color parameters and guest texture
address change. The full Vulkan smoke passes SDK synchronization
validation. Complete live menu composition with this fix is still pending.

After brightness, compute programs `0x801fdfb600` and `0x801fe03600` also
reject the sampler at `0x8e4`. They construct it inside an EXEC-guarded branch:
`s_bfm_b64 s16,12,44`, `s_lshl_b32 s18,5,24` and a zero `s19`.
The definition resolver already recovers the mask, but its shift handling
depends on a scalar snapshot that does not visit this branch. It now evaluates
32-bit logical and arithmetic shifts from their reaching operands, masking
the shift count to five bits and keeping unknown inputs unresolved. All 94
resource/provenance tests pass. Recovery on the captured scene shader produces
the expected sampler `{0,0x00fff000,0x05000000,0}` without a scalar snapshot.

## Driver pipeline cache and buffer-wait experiment on 2026-09-09

The driver pipeline cache now accepts and saves up to 1 GiB, using the same
bound on both paths. The preceding 256 MiB limit silently discarded every save
once the cache grew beyond it. Oversized saves now report their actual size and
limit; successful saves above 256 MiB also report their size. This addresses
repeat-launch compilation, not steady-state frame rendering. In the preceding
run, two scene-loading frames spent 134.2 and 111.0 seconds compiling compute
pipelines while the persisted file remained below the old cap.
The ReleaseFast runner builds successfully; full Vulkan smoke runs both before
and after saving the probe cache pass SDK 1.4.357.0 synchronization validation
without warnings or errors. A large scene-cache reload is still to be measured.

The subsequent material-fix run saves a 297,579,316-byte scene cache at flip
1024, exceeding the previous limit. The following launch accepts and persists
that cache. Heavy scene-transition compilation still occurs on the following
launch; accepting the larger cache does not establish its elimination or a
steady-state FPS improvement.

A separate experiment tracked each persistent buffer's last GPU use and
replaced whole-queue host waits with allocation-specific waits. It included
GPU dependencies for overlapping uses, deferred backing-allocation retirement,
and separate upload/readback controls. CPU lifetime tests and Vulkan probes
passed, but live frame times did not improve, so the experiment was removed.
The normal renderer retains its preceding buffer synchronization behavior.

The same-process ReleaseFast comparison waits for eight frames with stable
draw/dispatch counts after loading and pipeline compilation. Each mode records
12 frames and discards the first two; two additional warm-up frames separate
the scoped modes. Four copy workers, 128 color targets, 2,560 MiB storage images
and 512 MiB compute translations remain fixed. No builds, probes or captures
run during the measured intervals.

| Experimental wait policy | Measured flips | Median frame | Derived FPS | Buffer synchronization | Uploads/frame |
| --- | --- | --- | --- | --- | --- |
| Whole queue, before | 997–1006 | 3,524 ms | 0.284 | 916.5 ms | 1,312.4 MiB |
| Scoped uploads | 1013–1022 | 3,551.5 ms | 0.282 | 913.7 ms | 1,308.2 MiB |
| Scoped readbacks | 1029–1038 | 3,792.5 ms | 0.264 | 394.9 ms | 1,092.0 MiB |
| Both scoped | 1045–1054 | 3,651.5 ms | 0.274 | 323.1 ms | 1,056.0 MiB |
| Whole queue, after | 1058–1067 | 3,366.5 ms | 0.297 | 822.6 ms | 1,308.6 MiB |

Draw medians stay at 289–292 and dispatch medians at 1,176–1,197. Compute
pipeline compilation and storage-image eviction medians are zero. Reducing
buffer synchronization and uploads does not establish a frame-rate gain:
work and waits elsewhere in the frame still determine the final interval.
These measurements do not establish complete title-menu rendering.

## Resource checkpoint preparation on 2026-09-09

Retained decoded shaders now own the sorted resource and sampled-image
checkpoint locations used during scalar recovery. Code replacement and shader
eviction release those lists with their analysis. Dispatch-local uniform
specializations start without the parent's plan; preparation also checks the
exact instruction allocation before borrowing a list. An unavailable plan
falls back to collecting locations from the current instructions.

A renderer-local pool retains at most two scalar snapshot arrays, each bounded
to 32 MiB. Preparations borrow distinct arrays until completion, including
nested calls and error cleanup. Oversized arrays remain transient. Every call
still resets its snapshots and executes the original scalar evaluator using
current USER_DATA and guest memory. No register values, memory reads or branch
decisions are reused. The same preparation serves compute resources, graphics
texture bindings and Yotei's existing environment/HDR fallbacks.

`[gpu checkpoints]` reports preparation microseconds, calls, list builds and
snapshot allocations for a profiled frame. Preparation time includes the
scalar walk and overlaps the existing draw/compute resource counters; these
timings must not be added together. The pool's diagnostic switch selects the
preceding fresh-list/fresh-allocation behavior for comparisons.

Ten checkpoint tests pass in ReleaseSafe and ReleaseFast, covering changing
memory, skipped blocks, backward visits, loop ambiguity, read failures, nested
leases and allocation-failure cleanup. The analysis ownership test also checks
moves, replacement code and alternating uniform specializations. Full Vulkan,
indirect-image, scalar-pointer and uniform-limit image-loop probes pass SDK
1.4.357.0 synchronization validation without warnings or errors.

A same-process ReleaseFast comparison waits for eight frames with stable draw
and dispatch counts after scene loading and pipeline compilation. Each interval
records 12 frames and discards the first two; two additional frames warm reuse
before the enabled interval. Four copy workers, persistent scalar definitions,
128 color targets, 2,560 MiB storage images and 512 MiB compute translations
remain fixed. Build-cache cleanup finishes before measurement; no compilers,
captures or Vulkan probes run during the timed intervals.

| Checkpoint reuse | Measured flips | Median frame | Derived FPS | Checkpoint preparation | List builds/frame | Snapshot allocations/frame |
| --- | --- | --- | --- | --- | --- | --- |
| Off, before | 936–945 | 3,874 ms | 0.258 | 168.719 ms | 2,703.5 | 2,134.5 |
| On | 952–961 | 3,980.5 ms | 0.251 | 151.372 ms | 335 | 0 |
| Off, after | 965–974 | 4,070.5 ms | 0.246 | 175.4245 ms | 2,712.5 | 2,143 |

Checkpoint preparation improves by 10.3–13.7%, saving approximately 17–24 ms
per frame. Remaining list builds include dispatch-local specializations, which
cannot reuse the immutable parent plan. The final pool retains arrays for 955
and 641 snapshots, and reuse is restored to enabled after the comparison.

This experiment **does not establish an overall FPS improvement**. The enabled
frame median falls between the controls, while fence waits rise from 1.23 to
1.27 to 1.35 seconds. Workload medians are 287–288.5 draws and 1,164–1,173
dispatches; compute pipeline compilation and storage-image eviction stay zero.
Uploads remain near 1,416–1,417 MiB and readback near 535 MiB per frame. Available
physical memory varies from 1.2 to 3.7 GiB on the Ryzen 7 7700 / RTX 3070 Ti /
32 GiB host. The measured benefit is less repeated CPU work and allocation;
these live-scene timings do not establish complete title-menu rendering.

## Compute translation retention on 2026-09-09

Yotei now uses a lazy 512 MiB compute translation cache; other titles and the
renderer API retain 256 MiB. `PS5_GPU_COMPUTE_TRANSLATION_CACHE_MIB` overrides
the runner budget, clamped to 64–1024 MiB. Invalid values use the title default.
The startup GPU flags report the selected limit as `compute_translation_mib`.
The budget counts retained serialized keys and generated SPIR-V, not total
process memory or VRAM. Nothing is preallocated. Exact key comparisons,
runtime scalar bindings, LRU eviction and the separate 1,024-entry ceiling
retain their existing behavior.

The later scene exceeds the preceding 256 MiB limit and repeatedly translates
the same compute variants. A same-process ReleaseFast experiment changes only
the host cache budget. Persistent scalar definitions, four copy workers,
128 color targets and the 2,560 MiB storage-image budget remain enabled.
Each interval records 12 frames and discards the first two. Expanded budgets
warm for eight frames; the final 512 MiB confirmation warms for three.
After lowering the limit, measurement waits for a normal cache miss to evict
entries until retained bytes are within 256 MiB. No compilers, GPU probes or
captures run during timing.

| Compute cache budget | Measured flips | Median frame | Derived FPS | Compute translation | Translation misses/frame | Retained cache |
| --- | --- | --- | --- | --- | --- | --- |
| 768 MiB, before | 1350–1359 | 5,542.5 ms | 0.180 | 154.5 ms | 8 | 281 MiB |
| 256 MiB, control | 1364–1373 | 6,152 ms | 0.163 | 875 ms | 286 | 255 MiB |
| 768 MiB, after | 1386–1395 | 5,407 ms | 0.185 | 149 ms | 8 | 282 MiB |
| 512 MiB, confirmation | 1403–1412 | 5,290.5 ms | 0.189 | 142 ms | 8 | 282 MiB |

The surrounding expanded-cache intervals improve FPS by 11.0–13.8% over the
control. The final 512 MiB interval is 16.3% faster, with the same retained
working set and miss count as 768 MiB. Compute translation falls by about
83%; the measured scene does not benefit from retaining more than 512 MiB.
Draw medians are 544–547 and dispatch medians 1,017–1,017.5. Compute resource
preparation stays near 1.46–1.49 seconds, readback near 541 MiB, and fence waits
near 1.05–1.11 seconds. Compute pipeline compilation and storage-image eviction
remain zero. Available physical memory is approximately 2.8–3.3 GiB on the
Ryzen 7 7700 / RTX 3070 Ti / 32 GiB host.

Both translation-cache CPU tests pass in ReleaseSafe. Existing full Vulkan,
indirect-image and scalar-pointer probes pass with the new renderer option
set to 512 MiB and SDK 1.4.357.0 synchronization validation enabled, without
validation warnings or errors. The rebuilt ReleaseFast runner starts Yotei
with `compute_translation_mib=512` and continues decoding/presenting the intro.

These are live animated-scene intervals, not a deterministic replay or an
additional multiplier to apply to earlier benchmarks. An earlier 256/512/256
comparison crossed a scene transition and is excluded from the FPS claim.
One draw allocation failed earlier in that run while host memory was tighter;
this cache-budget change does not establish a fix for allocation failures.
Complete title-menu rendering remains unverified.

## Persistent scalar definitions on 2026-09-08

The retained decoded shader now owns a second-level scalar definition cache.
The existing 64-entry batch still handles repeated words within one recovery;
its misses can reuse up to 4,096 exact instruction-index/register queries
across descriptors, draws, dispatches and frames. Graph reachability is also
retained. Entries grow lazily; reaching the limit or failing an allocation
falls back to the same conservative solver. Ambiguous results remain cached
as ambiguous, with no substitution of entry register values.

The cache belongs to the immutable instruction and control-flow allocations,
not their movable enclosing struct or a guest program address. Existing code
word validation replaces and destroys it when guest code changes, and shader
LRU eviction releases it. Uniform branch specialization remains dispatch-local
and cannot borrow the original graph's definitions. Resource recovery checks
the instruction/CFG identity before using a retained cache. Guest memory,
USER_DATA and scalar snapshots are still read anew, with the same errors,
read order and 512-step recovery budget.

All 92 scalar-resource CPU tests pass in ReleaseSafe and ReleaseFast. Coverage
compares uncached, batch-only, cold persistent and warm persistent recovery;
it includes graph joins/loops, ambiguity, changing nested pointers, read
failures, exhausted budgets, cache capacity and allocation failure. A separate
ownership test checks moved analyses, replacement code at the same address,
and alternating uniform specializations. SDK 1.4.357.0 synchronization
validation passes the full Vulkan smoke, indirect image selection, scalar
pointers, uniform-limit image loops and image/array/guard probes.

The first live off/on/off comparison crosses a scene transition: enabled
flips 937–940 execute 1,403–1,464 dispatches instead of roughly 1,135, and
compute translation rises from about 65 ms to 537–801 ms. It is not used to
claim a whole-frame improvement. Timing is repeated later in the same process,
with batch memoization enabled, 128 color targets, the 2,560 MiB storage-image
budget and four copy workers unchanged. Each interval measures 12 frames and
discards the first two; no compilers, probes or captures run during timing.

| Persistent definitions | Measured flips | Median frame | Derived FPS | Compute resource preparation | Compute translation |
| --- | --- | --- | --- | --- | --- |
| Off, before | 1092–1101 | 5,398.5 ms | 0.185 | 1,587.5 ms | 702 ms |
| On | 1105–1114 | 4,602.5 ms | 0.217 | 1,149 ms | 685.5 ms |
| Off, after | 1118–1127 | 4,995 ms | 0.200 | 1,554.5 ms | 675 ms |

The enabled interval is 8.5% faster in FPS than the following control, and
17.3% faster than the preceding control. Resource preparation falls 26–28%.
The later control has similar draw time and fence waits to the enabled run,
so its 8.5% comparison is the more conservative whole-frame result. GPU waits
are higher in the first control; the full difference must not be attributed
to definition lookup alone. Enabled recovery serves 931,508 persistent hits
with no misses over its 12-frame interval, including the discarded frames.

Workload medians are 296–302 draws and 1,160.5–1,166.5 dispatches, with about
1,572.5 MiB uploaded and 530.5 MiB read back per frame. Storage-image eviction
and compute pipeline compilation remain zero. Available host RAM ranges from
about 2.3 to 2.6 GiB. These are live-scene timings on the same Ryzen 7 7700 /
RTX 3070 Ti host, not a deterministic replay or a multiplier for other games.
The diagnostic switch is restored to enabled after both comparisons.

Separate GPU captures show textured tree geometry at flip 1024 (3328x1872,
persistent cache disabled) and the brightness screen at flip 1088 (3840x2160,
enabled), including the wolf, instruction, slider and Cross. These are different
guest stages, not a pixel-equivalent before/after pair or evidence that the
cache caused rendering progress. Complete title-menu rendering remains
unverified.

## Resource preparation caches on 2026-09-08

Uniform descriptor recovery now shares control-flow reachability and up to
64 scalar reaching-definition results within one `Resolver.words` call.
Complete instruction-position/register keys are checked on every hit;
collisions replace entries, and ambiguous definitions remain ambiguous.
The batch borrows immutable instructions and a CFG only for that recovery.
The next call resets it, including after a read error. USER_DATA, scalar
snapshots and guest memory values are never cached. Memory reads and the
512-step recovery budget retain the preceding behavior.

Yotei's storage-image retention budget is now 2,560 MiB, allocated lazily;
other titles and the renderer API keep 1,280 MiB. The runner override
`PS5_GPU_STORAGE_IMAGE_CACHE_MIB` accepts 128–4096. This counts logical image
transfer bytes, not total RAM or VRAM: each cached view also owns a device
image. The 1,024-view ceiling remains separate, and the byte budget remains
soft while the current dispatch pins all remaining entries. Eviction still
publishes dirty GPU results before destroying a view.
`[gpu storage images]` reports the budget and budget/count-driven evictions
for each profiled frame; `[gpu frame]` retains the actual cache size.

All 90 CPU tests pass in ReleaseSafe and ReleaseFast. Coverage compares
batched and uncached definitions through joins, loops, clobbers, disconnected
blocks and cache collisions. Nested descriptor recovery checks equal memory
read counts and remaining budgets, changed input data and read failures.
The Vulkan storage-reuse probe covers both count and byte pressure while
writes remain queued. It, indirect-image selection and full smoke pass SDK
1.4.357.0 synchronization validation.

A same-process ReleaseFast comparison alternates descriptor memoization
off/on/off, with the storage-image budget fixed at 1,280 MiB and the color-target
limit at 128. Each interval measures 12 frames and discards the first two.
There are no captures, compilers or smoke probes during the timed intervals.

| Descriptor memoization | Measured flips | Median frame | Derived FPS | Compute resource preparation |
| --- | --- | --- | --- | --- |
| Off, before | 951–960 | 5,872.5 ms | 0.170 | 2,607 ms |
| On | 964–973 | 4,787.5 ms | 0.209 | 1,601.5 ms |
| Off, after | 977–986 | 5,721.5 ms | 0.175 | 2,608.5 ms |

Against the pooled control median of 5,788.5 ms, memoization improves observed
FPS by 20.9%; compute resource preparation drops 38.6%. The enabled interval
records 1,603,640 cached queries and 959,161 misses, a 62.6% hit rate. Those
counters span the whole diagnostic interval, including discarded frames.
Draw medians remain 287.5–290 and dispatch medians 1,150–1,152. Buffer uploads
stay near 1,177 MiB and non-color readback near 811 MiB per frame. Available
physical memory ranges from 2.5 to 3.2 GiB. This is a scene-specific comparison
on the Ryzen 7 7700 / RTX 3070 Ti host, not an estimate for every title.

The following storage-image comparison keeps memoization enabled. After
raising the budget, eight frames warm the cache before another 12-frame
interval; again the first two measured frames are discarded.

| Storage-image budget | Measured flips | Median frame | Derived FPS | Compute resource preparation | Evictions/frame | Texture upload | Non-color readback |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1,280 MiB, before | 1028–1037 | 4,407 ms | 0.227 | 1,303 ms | 75 | 380.2 MiB | 568.2 MiB |
| 2,560 MiB | 1050–1059 | 4,046.5 ms | 0.247 | 1,044 ms | 0 | 147.2 MiB | 397.9 MiB |
| 1,280 MiB, after | 1125–1134 | 4,044 ms | 0.247 | 1,162.5 ms | 48 | 212.7 MiB | 461.7 MiB |

The first comparison is 8.9% faster, but the final control has essentially
the same frame time as the enlarged cache. This experiment therefore **does
not establish a sustained additional FPS improvement** from the image budget.
The measured benefit is lower transfer traffic, no evictions, and 10–20% less
compute resource preparation. These percentages must not be added to the
descriptor result. Shrinking the live budget only takes effect on the next
allocation miss; the final interval waits until retained bytes are below
1,280 MiB. No frames with the old resident working set above that limit are
used as the final control.

The live budget increase retains 445 views and 1,412 MiB of logical transfer
data, versus medians of 264.5 views/1,268.5 MiB before and 277 views/1,260 MiB
after. These are measurements after scene loading; retained memory during a
fresh launch can differ. Available physical memory ranges from 2.9 to 5.2 GiB,
and workload/host variation limits conclusions about total frame time.

The actual presented 3840×2160 Digital Deluxe Bonus captures at flips 1024
(old budget, memoization off) and 1088 (larger budget, memoization on) are
pixel-identical. Captures occur outside timed intervals. Complete menu and
background rendering remains unverified.

## Retaining the color-attachment working set on 2026-09-08

The 64-entry color-target cache repeatedly evicts attachments still used by
Yotei's heavy scene. Each eviction can publish GPU-authored pixels to guest
memory, destroy the Vulkan objects, and require another upload on reuse.
Yotei now uses a lazy 128-entry limit. Other titles and the renderer API retain
64 by default. `PS5_GPU_RENDER_TARGETS=64` selects the preceding limit; the
runner accepts 64–256. Allocation matching, LRU selection, prepared-resource
pins, video protection and writeback before eviction retain their existing
behavior. Raising the limit does not allocate all slots in advance.

`[gpu targets]` reports the occupied slots, limit and logical size of retained
host-visible transfer buffers. `transfer_mib` excludes the separate device
images, driver allocation padding and other caches; it is not total VRAM use.

A ReleaseFast run on the Ryzen 7 7700 / RTX 3070 Ti / 32 GiB host compared 64
with 128 in the same process after scene loading and compilation. Each interval
contains 12 frames, discarding the first two. After raising the live limit,
eight additional frames warm the cache before the second interval. Captures,
compilers and smoke probes are disabled during both measured intervals.

| Color-target limit | Measured flips | Median frame | Derived FPS | Target misses/frame | Target upload | Target readback | Target materialization |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 64 | 1028–1037 | 5,453 ms | 0.183 | 53.5 | 450.1 MiB | 486.7 MiB | 457.5 ms |
| 128 | 1050–1059 | 5,180 ms | 0.193 | 0.5 | 91.7 MiB | 145.7 MiB | 101 ms |

The observed FPS improvement is 5.3%. This is a single before/after comparison,
not a universal speedup: dispatch medians are 1,060.5/1,061.5 and draw medians
280/282, while buffer and texture traffic varies. The direct benefit is the
reduction in attachment churn and transfers. The cache retains a median of
81 entries after growth, with transfer buffers increasing from 603 to 653 MiB.
Available physical memory ranges from 2.5 to 2.8 GiB during the intervals.

The expanded `--target-reuse` Vulkan probe exercises both limits, verifies a
second frame reuses every attachment (including slots beyond 64), then exceeds
capacity while sampling the oldest source. Pixel readback, released pins and
queued transfer-buffer reseeding are checked. This probe and full smoke pass
SDK 1.4.357.0 synchronization validation without warnings or errors.

The actual presented 3840×2160 Digital Deluxe Bonus captures at flips 1024
and 1088 are pixel-identical. Capture is disabled again after the comparison.

Compute resource preparation still takes a median 2.60 seconds in the enlarged
cache interval, and fence waits take 1.08 seconds. These measurements overlap
other frame counters and must not be added as independent costs. Complete
menu/background rendering remains unverified.

## Parallel buffer fingerprints on 2026-09-08

Yotei now enables content-based storage-buffer reuse by default. Unchanged
buffers retain their existing host-visible Vulkan allocation; changed buffers
still wait for preceding readers and upload a new snapshot. The native callback
resolves the complete guest range, including CPU aliases, before hashing it.
GPU writes and readbacks continue to invalidate the saved fingerprint.
Other titles retain the previous default. `PS5_GPU_BUFFER_CONTENT_CACHE=0`
disables reuse, and `=1` enables it explicitly.

Ranges of at least 4 MiB use four fixed contiguous partitions, each hashed in
full with Wyhash. Their ordered hashes and the total length form the final
digest. Smaller ranges retain a single Wyhash. Both the source callback and
the copied snapshot use the same algorithm. The existing copy helpers perform
the work synchronously, with at most four participants and no retained source
copies. `PS5_GPU_COPY_WORKERS` controls copies and fingerprints. Busy or
unavailable helpers fall back to the same partitioned digest on the caller;
alignment and worker count cannot alter the result.

`[gpu buffers]` reports `content_reused_kib` and `fingerprint_ms` per frame,
separating bytes bound through content reuse from the cost of checking them.
Repeated bindings can exceed the net reduction in uploads; compare `upload_kib`
for that reduction. These counters do not measure PCIe bus traffic.

CPU tests pass in ReleaseSafe and ReleaseFast, covering partition boundaries,
unaligned and relocated ranges, all worker counts, restart, unavailable helpers,
and simultaneous copy/hash calls. The Vulkan content-cache probe uses a buffer
larger than 4 MiB, changes worker counts, and verifies native writes, GPU writes,
unchanged reuse and callback fallback. It also leaves a reader queued, checks
that unchanged reuse keeps it queued, and verifies that a later CPU change
preserves the old reader's result. This probe, queued-buffer reuse, parallel
copies and full smoke pass SDK 1.4.357.0 synchronization validation.

On the Ryzen 7 7700, an isolated probe hashes 1 GiB per interval, cycling through
a 128 MiB source allocation. It alternates the preceding serial Wyhash and
1/2/4/2/1 participants over three passes. The game and compilers are stopped.
Median elapsed times compare the preceding algorithm with four participants:

| Buffer size | Serial Wyhash before | Parallel fingerprint | Speedup of fingerprinting |
| --- | --- | --- | --- |
| 4 MiB | 33.36 ms | 21.08 ms | 1.58× |
| 16 MiB | 32.64 ms | 19.14 ms | 1.71× |
| 64 MiB | 33.48 ms | 19.52 ms | 1.72× |
| 128 MiB | 37.11 ms | 19.06 ms | 1.95× |

These are CPU fingerprint timings, not FPS multipliers.

The ReleaseFast game run then compared content reuse on/off/on in one process,
with four participants throughout and page tracking disabled. Each interval
contains ten frames; the first two are discarded. No builds, smoke tests or
GPU captures run during these intervals:

| Content reuse | Flips | Median frame | Derived FPS | Buffer uploads | Buffer preparation | Fingerprinting |
| --- | --- | --- | --- | --- | --- | --- |
| On, initially | 964–971 | 5,923 ms | 0.169 | 1.20 GiB | 418.5 ms | 143.5 ms |
| Off | 974–981 | 6,065.5 ms | 0.165 | 7.38 GiB | 653 ms | 0 ms |
| On, repeated | 984–991 | 6,121 ms | 0.163 | 1.23 GiB | 446 ms | 157 ms |

Buffer uploads fall roughly sixfold and preparation improves by 32–36%.
Overall FPS varies from 2.4% faster to 0.9% slower against the intervening
control, so this comparison **does not establish a sustained FPS improvement**.
Medians stay near 287–288 draws and 1,118 compute dispatches; texture uploads
range from 707 to 720 MiB per frame. Available physical memory ranges from
1.1 to 1.4 GiB. Other resource preparation and synchronization still dominate
the frame, and the isolated fingerprint speedup must not be presented as a
whole-game speedup.

The actual presented 3840×2160 Digital Deluxe Bonus capture at flip 960 matches
the preceding build's flip-1088 capture pixel for pixel. Capture is disabled
before timing. The first heavy scene frame separately spends about 126 seconds
compiling 201 compute pipelines; that transition is outside the comparison.
Complete menu/background rendering remains unverified.

## Keeping the compute translation working set on 2026-09-08

The 64 MiB compute SPIR-V cache repeatedly evicted translations still needed by
the current scene. At flips 1127–1129 it held only 37–43 entries, and successive
frames added 231–233 misses even though the Vulkan compute pipelines were warm.
Raising the compute cache's lazy limit to 256 MiB retained roughly 214–221 MiB of
translations after warmup and reduced repeated translation to near zero misses.
The separate graphics translation budget remains 64 MiB. Cache keys still
compare code, decoded instructions and translation options in full, excluding
only scalar values supplied through the existing dynamic binding.

`[gpu shaders]` now reports `cxlat=hits/misses/MiB`: translation lookups for that
frame followed by the retained compute cache size. This distinguishes repeated
CPU translation from Vulkan pipeline compilation, whose counters remain `cpso`.

On the Ryzen 7 7700 / RTX 3070 Ti / 32 GiB host, a same-process 64/256/64 MiB
comparison measured ten frames per interval and discarded the first two:

| Compute cache limit | Measured flips | Median frame | Derived FPS | Median compute translation | Retained cache |
| --- | --- | --- | --- | --- | --- |
| 64 MiB, before | 1303–1310 | 7,480 ms | 0.134 | 530 ms | 63.4 MiB |
| 256 MiB | 1313–1320 | 6,793.5 ms | 0.147 | 62 ms | 214.2 MiB |
| 64 MiB, after | 1323–1330 | 7,227.5 ms | 0.138 | 531.5 ms | 58.9 MiB |

The larger cache improved FPS by 6–10% against the surrounding intervals, or
8.4% against their pooled median of 7,365.5 ms. Workload medians remained close:
289–291 draws, 1,203–1,204 dispatches, and about 9.1 GiB uploaded per frame.
Resource preparation and fence waits still varied, so the overall FPS result
is a scene-specific observation. The roughly 468 ms reduction in translation
time is the directly measured benefit; the remaining transfer and resource work
still dominates these very slow frames.

This diagnostic changed only the live host cache budget. Shrinking the budget
does not evict on a hit, so one completed cache lookup hash was invalidated to
trigger the ordinary miss/LRU eviction path; retained bytes were checked after
each interval. Guest code and shader output were unchanged. No builds, smoke
tests or frame captures ran during the timed intervals. A separate GPU capture
of the Digital Deluxe Bonus screen matched the preceding transfer-buffer build
pixel for pixel. This does not establish complete menu or background rendering.

The CPU cache tests compare cached and fresh modules across changed dynamic
values, literals, bindings, wave modes and buffer bounds. Full Vulkan smoke and
image probes pass with SDK 1.4.357.0 synchronization validation, including the
uniform output guard sequence 0/1/0/1 with reused descriptor registers.

## Reusing color-target transfer memory on 2026-09-08

Initial color attachments now stage their pixels directly into their existing
coherent transfer buffer. The buffer supports uploads as well as readback, so
initialization no longer allocates a separate Vulkan upload buffer and a linear
CPU copy. Tiled input borrows the bounded image scratch pool. The attachment
cache and its memory limit stay the same.

Previously drawn attachments wait for queued work before reusing their transfer
memory. Fresh allocations need no such wait. Prepared attachments remain pinned
through recording, including multiple render targets. Clear metadata, tiling,
guest reads and image transitions still follow the existing paths.

The resident-target probe fills the attachment cache, samples its oldest entry
while allocating new outputs, and reseeds an attachment with an earlier draw
still queued. It compares every pixel against the transient-upload path,
including untouched background pixels. Full smoke, mixed float/integer MRT and
image-scratch probes also pass with the SDK 1.4.357.0 validation layer loaded and
synchronization validation enabled.

The ReleaseFast runner was measured on the Ryzen 7 7700 / RTX 3070 Ti, with four
copy participants, page tracking and content hashing disabled, and frame capture
disabled during timing. Each interval contains ten frames; the first two are
excluded. The diagnostic `Renderer.reuse_color_target_transfer` switch changes
only the upload path; image scratch pooling stays enabled in both modes.

| Upload path | Flips | Median frame | Graphics setup | Draws / dispatches | Texture uploads |
| --- | --- | --- | --- | --- | --- |
| Resident, initially | 971–978 | 6,601.5 ms | 620 ms | 288.5 / 1,204 | 717,976 KiB |
| Transient | 981–988 | 6,924.5 ms | 890.5 ms | 289 / 1,203 | 727,960 KiB |
| Resident again | 991–998 | 6,080 ms | 651.5 ms | 286 / 1,204 | 318,312 KiB |
| Transient, repeated | 1032–1039 | 6,949 ms | 870 ms | 289 / 1,203.5 | 717,976 KiB |
| Resident, repeated | 1042–1049 | 6,096 ms | 659.5 ms | 286.5 / 1,204.5 | 316,165.5 KiB |

The first two intervals have comparable resource traffic and indicate about
4.9% more FPS: 0.144 to 0.151 FPS. Graphics setup drops by roughly 30%. Subsequent
resident intervals also upload substantially fewer textures, so their larger
total-frame improvement is **not** attributed entirely to this change. Available
physical memory at interval boundaries ranges from about 1.7 to 2.5 GiB. This
measurement does not establish a speedup for other titles or all Yotei scenes.

The presented 3840×2160 Digital Deluxe Bonus frame matches the preceding build's
capture byte for byte, including its text and Cross. This verifies the visible
UI checkpoint, not complete menu/background rendering. One earlier transition
frame still spends about 106 seconds compiling compute pipelines; initial shader
compilation remains a separate limit.

## Parallel guest-memory copies on 2026-09-08

Large AGC guest-memory reads and writes can now split their copies between the
calling thread and up to three persistent helpers. Helpers sleep between jobs;
the callback waits for every partition before returning. Address validation,
write notification and guest label publication retain their ordering. Ranges
below 4 MiB, concurrent/reentrant callers and unavailable helpers use the serial
path. Partitions preserve unaligned outer boundaries and meet on destination
cache-line boundaries. Runtime reset joins and destroys the helpers.

`PS5_GPU_COPY_WORKERS=1` selects serial copies; `2` or `4` includes the calling
thread in that limit. The runner defaults to four participants for Yotei and
one for other titles. This setting changes CPU copying only.

On the Ryzen 7 7700, the following isolated medians copy a total of 1 GiB per
batch, alternating 1/2/4/2/1 participants across three passes. The game and
compiler are stopped during this measurement. All copied bytes match.

| Buffer size | One participant | Two participants | Four participants |
| --- | --- | --- | --- |
| 4 MiB | 16.63 ms | 11.51 ms | 7.79 ms |
| 16 MiB | 38.13 ms | 20.96 ms | 14.24 ms |
| 64 MiB | 67.55 ms | 55.95 ms | 54.89 ms |
| 128 MiB | 78.02 ms | 62.63 ms | 57.64 ms |

These are copy timings, not FPS multipliers. CPU tests exercise unaligned
boundaries, concurrent callers, restart and unavailable-worker fallback. The
Vulkan probe uploads and reads back 16 MiB buffers with 1/2/4 participants,
native updates and partial GPU writes, checking every resulting byte. It and
the full smoke, queued-buffer reuse, content-cache and image-scratch probes pass
with the Vulkan SDK validation layer enabled.

A same-process comparison after scene compilation alternates only the copy
participant limit. Each interval spans ten frames; the first two transition
frames are excluded from these medians. Buffer-content hashing and page
tracking stay disabled, and the earlier image scratch/tiling changes stay active.

| Participants | Flips | Frame time | Buffer preparation | Draws / compute dispatches |
| --- | --- | --- | --- | --- |
| 4 initially | 974–981 | 7,240.5 ms | 766.5 ms | 291 / 1,163 |
| 1 | 984–991 | 7,497 ms | 1,040 ms | 289 / 1,163 |
| 4 again | 994–1001 | 7,228 ms | 790 ms | 289.5 / 1,163.5 |

The four-participant intervals give about 3.5–3.7% more FPS on this workload:
approximately 0.133 to 0.138 FPS. Available physical memory at interval boundaries
ranges from 1.2 to 2.3 GiB. This does not establish a comparable improvement in
other scenes or loading time. One preceding transition frame spends about
150 seconds compiling compute pipelines; that cost is outside this copy
optimization and outside the steady-frame comparison.

The actual presented GPU frame at flip 1088 retains the Digital Deluxe Bonus
text and Cross. Capture runs after the comparison and is disabled again
afterwards. Complete menu rendering remains unverified.

## Temporary image memory and swizzle locality on 2026-09-08

Synchronous image staging and writeback now borrow temporary CPU buffers from
a bounded pool. At most two buffers of up to 64 MiB are retained. Active leases
are removed from the pool, so nested preparation uses distinct storage; small
and oversized requests keep the ordinary allocation path. Pooling covers storage
image staging, render-target materialization/writeback, storage-buffer readback
and the existing empty-scene HDR fallback. It does not cache guest contents or
weaken CPU/GPU visibility rules.

Storage-image writeback also tiles directly from the completed, cached host
transfer mapping. This removes a full intermediate linear allocation and copy.
The GPU copy still completes before CPU access; the mapping is released before
calling the guest write callback. Guest padding is preserved.

CPU tile/detile now finish each macro block before advancing. The X and Y swizzle
contributions are computed once, and macro/slice XOR once per block. This avoids
repeated address calculations and revisiting tiled cache lines across the entire
surface. The independent scalar addressing path is unchanged.

The pool's lifetime/budget tests and all 72 tiling/dependency tests pass, including
comparison with scalar addresses across mips, slices, padding, volumes and MSAA.
A new GPU probe alternates pooled/unpooled staging and different linear/RB+
extents, checking every byte outside a partial GPU write and retrying a failed
guest write. The full Vulkan smoke, storage/target/buffer reuse, stencil UI,
HTILE clears, streamed mips, BC4, array gradients and fullscreen orientation
also pass with SDK validation enabled.

A same-process pool comparison on the first Digital Deluxe Bonus screen gives
the following medians, excluding two transition frames per interval. The image
readback change is active throughout; buffer-content hashing and page tracking
are disabled. The macro-block locality change is tested separately below.

| Temporary pool | Flips | Frame time | Draws / compute dispatches |
| --- | --- | --- | --- |
| Enabled initially | 920–927 | 8,114 ms | 284 / 1,107.5 |
| Disabled | 930–937 | 8,943.5 ms | 287.5 / 1,106.5 |
| Enabled again | 940–947 | 8,041.5 ms | 287 / 1,106.5 |

This is about a 10–11% FPS improvement from pooling on this workload. Across the
complete ten-frame intervals, the process records 13.4 / 23.4 / 14.5 million
page faults respectively; these Windows counters include faults handled in
memory. Available physical memory ranges from about 1.5 to 3.0 GiB at interval
boundaries. No guest confirmation or dispatch skipping was added. GPU frame
960 retains the bonus text and Cross; complete menu rendering remains unverified.

An isolated CPU test that allocates, fills, copies and hashes 32 pairs of 4K
temporary buffers takes 473–523 ms without pooling and 238–256 ms with it, with
identical checksums. These are operation timings, separate from the game FPS.

With the game and compiler stopped, alternating the old and new tiling routines
twice gives these medians across six batches per variant. Each batch processes
eight 3840×2160 surfaces; output checksums and scalar-reference comparisons
match. CPU conversion time falls by 15–29%. The combined changes have not yet
been timed together in a steady gameplay interval.

| Bytes per pixel | Tile before / after | Detile before / after |
| --- | --- | --- |
| 4 | 60.5 / 48.5 ms | 71.5 / 51 ms |
| 8 | 106.5 / 90 ms | 126 / 89.5 ms |

## Buffer and descriptor preparation on 2026-09-08

Large material tables now deduplicate recovered image descriptors through a
bounded hash set and find prepared graphics views through a reusable hash map.
Both retain insertion order and compare complete descriptors on collisions;
instruction mappings, sampler state and view dimensions keep their existing
semantics. Reading one T# uses one checked range read, retaining zero-fill at
the buffer boundary. This removes quadratic scans and repeated address lookups
without reducing the number of guest draws or dispatches.

With `PS5_GPU_BUFFER_CONTENT_CACHE=1`, untracked storage buffers of at least
64 KiB can reuse their persistent upload when a full-range content fingerprint
matches. At this stage the option was disabled by default. The native memory callback reads
the complete resolved range, so writes through another CPU alias are visible.
Changed buffers retain the existing synchronization and upload path, and the
cache records the bytes actually copied. GPU writes and readbacks invalidate
the fingerprint. Missing callbacks and smaller buffers retain their previous
path; page tracking remains opt-in. Descriptor reads also retain a word-wise
fallback for readers that cannot resolve adjacent mappings in one operation.
A focused CPU test covers this fallback, unaligned addresses, truncated bounds
and inaccessible memory.

The GPU regression covers unchanged reuse, native writes both inside and outside
the currently fetched word, GPU overwrites and fallback when fingerprinting is
unavailable. It, the complete Vulkan smoke, 4352-view indirect-image test,
descriptor reuse, selected indices, workgroup tables, unsupported-texture
continuation and buffer reuse pass with the SDK validation layer enabled.

The live Ryzen 7 7700 / RTX 3070 Ti run completes the intros and animated loading
indicator and displays the first Digital Deluxe Bonus notice, including text
and Cross, in the captured GPU frame at flip 960. A same-process comparison
then disables and restores only the fingerprint callback. No guest inputs,
manual acknowledgements or rendering skips were added. Transition frames are
excluded from these medians:

| Buffer content cache | Flips | Frame time | Buffer upload | Draws / compute dispatches |
| --- | --- | --- | --- | --- |
| Enabled initially | 955–964 | 7,906 ms | 1.19 GiB | 288.5 / 1,137 |
| Disabled | 967–978 | 8,428.5 ms | 7.55 GiB | 287 / 1,137.5 |
| Enabled again | 981–992 | 9,629 ms | 1.19 GiB | 288 / 1,137 |

The roughly 6.3-fold reduction in buffer upload is repeatable; an FPS gain is
not established by this comparison. Subsequent system counters show only
778 MiB available physical memory on the 32 GB machine, about 60.9 GB committed
against a 62.4 GB limit, and active page reads. Memory pressure and changing
execution costs limit conclusions from the timing windows. Therefore full-range
fingerprinting remains opt-in. These measurements precede the final adjacent-
mapping read fallback and the runner's default-off wiring, which have separate
CPU/GPU and build validation.

CPU samples still include substantial copies, texture tiling/detiling, allocation
churn and GPU waits. Fence waits alone have medians near one second per frame.
Keeping compatible render/compute image consumers on resident GPU resources
remains a larger optimization target. Neither tenfold acceleration nor complete
title-menu rendering has been established by this work.

## Scene counter correction on 2026-09-08

The newer renderer's startup crash was reproduced after streamed scene loading.
A hardware watchpoint caught a negative count entering the guest's shared object
list at `0x1177c8b`. The producer was recovered from retained PM4 submissions:
compute program `0x801f76b600` narrows EXEC to a single lane before adding a wave
count to its output header at offset 32. Integer buffer atomics ignored EXEC,
allowing inactive invocations to add unrelated values retained in their VGPRs.

An isolated replay of the captured dispatch reproduced a counter of
`3,085,515,644`. Applying the execution mask and descriptor bounds produces
`380` on the same saved inputs. Replay writes remain in a separate memory copy.
Float buffer min/max now use the same guards and a compare-exchange loop;
separate atomic loads and stores could lose concurrent bounds updates. The
typed IR also recognizes these float operations as memory accesses, preserving
the data preparation that its optimizer previously removed.

GPU regression coverage includes 144 masked integer/float cases across both
translation paths, wave32/wave64, high lanes, empty EXEC, out-of-range addresses
and returned values, plus three concurrent RMW cases. These tests, the complete
Vulkan smoke and the existing mask, scene-pointer, storage-reuse and stencil UI
probes pass SDK validation. The counter-corrected diagnostic run passes the former
crash point, continues submitting the scene graph with valid object counts, and displays all
three bonus notices, the complete brightness screen, Change Difficulty and
Select an Experience. Text, navigation arrows, the slider and Cross glyphs are
visible, and confirmation advances these screens. Complete title-menu background
rendering remains unverified; after Standard, the run enters another black
transition with very slow frame progress.

Graphics sampling also reused a T#/S# register pair across an entire shader.
Captured pixel program `0x8000296000` samples an array through s28/s44 at
`0x12d0` and `0x1370`, then reloads s28 and gathers a 2D texture at `0x1880`.
Reusing the first array binding rejected the gather with `InvalidStorageBinding`.
Graphics bindings now retain their instruction PC; physical descriptors are
shared only when the complete image, sampler and view dimension match. A GPU
pixel test checks both 2D/array-to-2D transitions and reuse of an unchanged
descriptor. The existing orientation, stencil UI, array-gradient, indirect-image
and complete smoke probes pass. Applying the instruction-PC correction to the
already loaded diagnostic process removes this refusal; a CPU readback of its
intermediate colour target contains a textured tree. The final 3D background
still does not appear, and this diagnostic run is not full-scene validation of
the newly built executable.

The next scene also rejects `IMAGE_GET_LOD` at `0x78`: graphics resource
preparation omitted LOD queries entirely, although translation requires a
sampled-image binding. Queries now use the same instruction-specific descriptor
and scalar checkpoints. Query-only GPU shaders verify clamped and unclamped LOD
from known texture/viewport gradients, including the title's second-component
`dmask=2` form. The descriptor-reuse probe passes with clean SDK validation.

The compute program at `0x800033db00` was skipped because eight writes use
`BUFFER_STORE_FORMAT_D16_HI_X`, including `0xe09c6000` at `0x14e4`. Its GFX10
encoding is defined in the [LLVM buffer instruction table](https://github.com/llvm/llvm-project/blob/main/llvm/lib/Target/AMDGPU/BUFInstructions.td).
The decoder, resource analysis and translator now support this upper-half form
through the existing formatted D16 store path. GPU tests cover signed, unsigned
and float 16/32-bit destinations, inactive low/high lanes, adjacent halfwords and
out-of-range stores. The captured program no longer contains undecoded
instructions. The fresh installed runner retains its translated module and a
successfully created Vulkan compute pipeline, where the previous runner skipped
the shader. Its contribution to the final scene image remains to be checked.

That newly enabled kernel exposed another resource-planning gap. Its texture
table contains seven 440-byte records; `WorkGroupId.x >> 4` selects a record in a
112-group dispatch. Without the dispatch bound, resource recovery conservatively
enumerated 32-bit multiplication wrap residues at eight-byte intervals. Ordinary
fields between descriptors then appeared as additional textures, sometimes with
impossible extents and an unsupported tile mode. Compute bindings now retain the
dispatch dimensions and system SGPR assignments. Reaching-definition analysis
propagates those entry bounds through scalar copies and logical right shifts,
allowing this table to enumerate only the seven reachable records. Overwritten
or ambiguous SGPR definitions retain the conservative fallback. A GPU test checks
per-group colours from a 440-byte table containing unreachable descriptor-like
fields; the index-analysis regression suite also passes.

The unsupported tile mode previously returned `BackendRejected`, discarding the
ACB before its trailing release. The public call accepted the buffer but reported
it incomplete, leaving the CPU waiting for a generation that would never arrive.
This was an aborted command buffer, not a blocked GPU wait that later resumed.
Texture-layout rejection now follows the existing unsupported-image policy:
skip the affected dispatch and continue through subsequent packets. A Vulkan
regression reproduces the old abort and verifies the trailing 64-bit release,
untouched output of the skipped pass, and successful following compute work.
Genuine Vulkan device and submission errors retain their failure path.

The intermediate installed run reached the first bonus notice normally, then
hit these ACB aborts. Five manual generation acknowledgements were used to resume
diagnostic observation; they did not execute discarded commands and do not count
as normal-run validation. The corrected runner was rebuilt and installed for a
fresh run without debugger code patches or manual acknowledgements. This run
completes the intros, displays the animated loading indicator, and passes all
three bonus notices through ordinary Cross confirmation. A long black transition
after the third notice eventually reaches brightness calibration at flip 1152:
the wolf, instruction, slider and Cross glyph are all visible in the presented
GPU frame. Intermediate targets contain tree geometry, but the complete title
menu remains unverified.

A hardware breakpoint then identified the next `UnsupportedSampledImage`:
pixel program `0x8000273400` exhausts all 4096 physical slots while preparing
the sample at `0x1a6c`. Its 1332-record, 96-byte table contains 3996 distinct
texture descriptors, in addition to hundreds of views used earlier in the same
shader. The graphics table had 4461 instruction mappings at the refusal. The
per-shader image ceiling is now 8192, still capped by the device's descriptor
limits; cross-draw texture retention remains 8192 entries. The enlarged GPU
regression verifies 4352 mixed 2D/3D views in compute and fragment stages,
relocated tables, aliased views and out-of-range indices. It and the complete
smoke, descriptor-reuse, workgroup-table and command-continuation probes pass
SDK validation. This removes the tested capacity restriction; its effect on
the complete title scene still requires a fresh game run.

Compute translations now have a separate bounded cache, preserving the graphics
cache's budget. On comparable loading frames 860–890, median frame time changed
from 3,337 ms to 2,513 ms, and compute translation from 285 ms to 20 ms. The runs
had 65 median draws and 258/265 dispatches respectively. These are loading
measurements; initial driver compilation and the later scene remain much slower.
An opt-in page-tracking experiment in the loaded process reduces repeated buffer
uploads from roughly 15 GiB to 1–1.5 GiB per scene frame. Later UI frames still
take roughly 6–9 seconds. Page tracking remains opt-in, and these changing scene
workloads do not establish a controlled FPS comparison.

The persisted driver cache had also reached 67,107,307 bytes, just below its
64 MiB cap. Larger live caches were silently excluded from subsequent saves.
The persistence limit is now 256 MiB, retaining a bound on file reads and
temporary allocations while allowing streamed-scene pipelines to survive
relaunches. This does not remove the cost of compiling a shader for the first
time. One fresh scene frame compiled 207 compute pipelines in about 210 seconds.
A real GPU persistence probe saves and reloads a 67,136,709-byte cache, above the
former limit, with clean SDK validation. The fresh game run also persists a
107,199,910-byte driver cache during the bonus sequence and grows to
125,246,127 bytes on the brightness screen.

## Release progress on 2026-09-08

Since `v0.3.0-alpha.3`, development has advanced from intro playback into streamed
scene loading, the animated loading indicator, three bonus notices, brightness
calibration and parts of the 3D scene/interface. The maintainer reports visible
trees in the background and audible menu music. These partial scene observations
do not establish a complete title menu or gameplay.

The full bonus/brightness sequence was captured on reference build `796a484`, as
detailed below. A bounded check of `4f58738` completed the intro and continued into
scene loading at flip 690 without a contained guest fault or submission refusal.
It did not repeat the entire UI sequence. This distinction also applies to the
`0.3.0-alpha.4` runner, whose subsequent change is Windows version metadata.
The older 1.5–1.6-second post-intro baseline at the end of this document predates
scene loading and is not a current full-menu performance measurement.

## Menu progress on 2026-09-07

Live validation of `a7e7ae1` reached the animated loading indicator (captured
at flips 801 and 833), but terminated with a guest write fault before the
bonus notices. It did not reproduce the old culling-pointer or VCC_HI
translation faults. The title menu and brightness screen are **not verified
on this build**. The installed executable was restored to the previously
tested `796a484` runtime for UI comparison; a separate build isolates the
per-invocation high-mask write without changing the remaining fixes.
The `796a484` control run verified the animated loading indicator (flip 837),
Digital Deluxe Bonus (955), Gift of the Northern Star (1000), Pre-order
Bonus (1058), and brightness calibration (1149). The notices have readable
text and Cross glyphs; brightness includes the wolf image, instruction,
slider and confirmation glyph. This does not verify the UI on the newer
renderer: its previous live run crashed before the notices. That reference
session was subsequently closed for Cat Quest III orientation testing; the
installed executable now includes the newer renderer and the Cat compositor
fix. The reference executable and PDB are preserved as
`zig-out/bin/game-run-pre-cat-orientation.*` for Yotei comparisons. The newer
build has not been verified through this UI sequence. Full title-menu
rendering remains unverified.

The Jurassic Park startup fix preserves explicit color disable and DX clipping,
and still recovers reset depth extents for Yotei's active HTILE-backed surfaces.
Pixel-readback probes verify retained depth comparisons and repeated metadata
clears. The installed build played Yotei's intro and continued into scene
loading in a bounded live check, with the Sucker Punch logo captured at flip
512. This does not extend verification to the bonus/brightness sequence or
the full title menu. The previous Cat build is preserved separately as
`zig-out/bin/game-run-pre-jurassic.*`.

The reference resolved its roughly 6,042 resources in about 18 minutes;
initial scene frames then spent 267 and 162 seconds preparing dispatches.
A sampled long pause was inside the NVIDIA driver. Later UI frames took
roughly 5-10 seconds, making fades and input gates slow in wall-clock time.
The game accepted explicit confirmation input. The test helper initially
missed the second notice because its image matching included too much
shared layout; manual confirmation advanced it, and title-only matching
with vertical tolerance corrected the helper.

D16 buffer loads now permit an undefined destination VGPR, choosing zero
for its untouched half while preserving any previous definition. This
addresses the logged `buffer_load_short_d16` rejection at PC `0xc74` writing
v109; only v0-v63 had received the translator's initial zero values. Six GPU
cases initialize v64, v65, v109, v127, v128 and v255 through complementary
byte/short loads. The old translator rejects the first fresh register; the
corrected translator passes, including preservation, sign extension and
out-of-bounds cases. Scene pointers, wave32, wave64, SAVEEXEC, indexed images
and full Vulkan regressions also pass SDK validation. Live verification
of the affected game shader remains pending.

Indexed material recovery now recognizes scalar loads and shifts using either
VCC word. The captured particle shader `0x80003bdb00` loads its material index
into VCC_HI at PC `0x54c`, shifts it into VCC_LO at `0x558`, then samples the
global table at `0x588`. The previous SGPR-only checks rejected this chain.
Six GPU cases cover ordinary SGPR, VCC_LO and VCC_HI indices with wrapping
and non-wrapping record offsets: the old backend rejects the VCC cases;
the corrected backend passes all six. Selected, typed, indirect, nested,
vector, uniform-loop, 4096-view and full Vulkan regressions pass SDK
validation. This correction still needs live particle-rendering verification.

Typed material indices now retain their bounds through vector moves and
conditional selections, including all four components of integer gathers.
Every vector source must have been initialized for all lanes active at its
consumer; restoring lanes outside the fetch mask rejects the proof. Scalar
resource recovery also reconstructs wrapping MUL/MULK offsets after register
reuse, and sampled views now support R16_SINT alongside the existing integer
formats. On the captured terrain table, `0x8000296000` PC `0x1ebc` previously
enumerated 229 candidates, including 62 false 1D-array descriptors. Recovering
the R8_UINT gather range changes the scan from 8-byte windows to the actual
136-byte records and yields 84 2D textures. The table was captured at failure;
missing source-resource allocations were read from the still-running process.
GPU selection/gather tests reproduce the old `UnsupportedSampledImage` and
pass after the fix. Typed, indirect, indexed, nested, vector, uniform-loop,
4096-view and full Vulkan regressions pass, together with the index-bound
and scalar-resource CPU suites. This texture fix has not yet been validated
in a complete game frame.

Compute dispatches now pass `CS_W32_EN` from the PM4 initiator to translation.
Wave32 comparison/carry destinations write one word, preserving adjacent
SGPRs; EXEC indexing, lane operations and add-thread-id addressing use 32
lanes. This removes the `UnsupportedBufferAddressing` rejection for explicit
`VCC_HI` comparison destinations in live programs `0x8000345d00` and
`0x80002d6700`, whose captured initiator is `0x8041`. The GPU regression uses
the PM4 callback with 32/64/512 invocations, odd SGPR destinations and
opposing EXEC halves: it fails on the previous translator and passes with
the dispatch mode. SAVEEXEC, wave64, wide masks, carry, scene pointers,
packed buffers, DPP, GDS, indexed images and full Vulkan smoke also pass SDK
validation. Complete game rendering remains unverified.

SAVEEXEC now applies negation to the operand specified by the ISA:
`ANDN1` computes `~source & EXEC`, while `ORN2` computes `source | ~EXEC`.
The previous lowering reversed both operands. In the captured culling shader
`0x80001abb00`, the ANDN1 at PC `0x7f8` could consequently activate lanes
outside the current branch and overwrite the pointer VGPRs later read at
PC `0x9bc`. A 50-case GPU probe fails before the correction and passes after
it, checking both operand orders, saved masks, source/destination overlap,
and the low-word-only SCC for 32-bit SAVEEXEC. Wave64, wide masks, carry,
packed-buffer and scene-pointer regressions also pass SDK validation.
The live pointer fault still requires a new runtime verification.

Material texture indices can now resolve a second, global descriptor table.
The recovery follows SMEM definitions at the relevant instructions, enumerates
the bounded set of reachable source words (including 32-bit multiplication
wrap), then deduplicates the shifted global descriptor offsets. Both buffers
retain per-word out-of-bounds zeroing. The captured `0x800034f300` particle
shader resolves 190 textures (189 2D and one 3D) at nine sample sites; the old
recovery returns no candidates for PC `0x494`. GPU checks cover over 50,000
source windows, wrapping multiplication and shifts, exact aliases, volume
slices, and an out-of-bounds material index resolving global entry zero.
Indirect, nested, vector, typed-index, uniform-loop, 4096-view and full Vulkan
regressions pass. Live particle rendering still requires the new runtime.

Wave64 per-invocation comparison and carry masks now update both scalar words.
Previously only the low word changed, so saved EXEC and 64-bit mask arithmetic
could reuse stale upper-half bits. A GPU probe using SDWA comparisons,
`S_AND_SAVEEXEC_B64` and complementary EXEC masks fails on the old code:
lane 32 retains its sentinel instead of executing the false branch. All 20
64/512-invocation cases pass after updating the pair, along with carry,
wave64, packed-buffer, scene-pointer and full Vulkan regressions.
The pair update alone did not remove the live `0x80001abb00` fault at
PC `0x9bc`. That shader uses a wave64 workgroup and contains the incorrect
ANDN1 lowering described above. A later wave32 dispatch also exposed the
need to limit comparison destinations to one scalar word in wave32 mode.

Runtime sampled-image tables can now select between 2D and 3D Vulkan views
at one instruction. Each view kind has its own exact descriptor lookup;
unmatched results are zeroed before combining them. Coordinates survive
overlapping result registers, and sampling remains outside divergent branches
so fragment implicit LOD is valid. GPU probes cover a two-slice volume,
4096 mixed views, relocation, aliases and null bounds. The previous translator
rejects the mixed table with `InvalidStorageBinding`; the corrected compute
and fragment paths pass SDK validation. This supplies view selection for the
indexed particle-table recovery above.

VOP3B `V_ADD_CO_U32`, `V_SUB_CO_U32` and `V_SUBREV_CO_U32` now
decode their scalar carry destination and export unsigned carry/borrow.
They previously performed ordinary integer arithmetic, leaving stale VCC
bits for the following ADDC. Live culling faults in `0x8000196500`,
`0x80001abb00` and `0x80001c0d00` consequently included record addresses
with high word `0x21` instead of `0x20`. A controlled scene-pointer GPU
probe reproduces the error on the previous translator: it reads
`0x100012000` instead of `0x12000`. The corrected translator reads both
relocated records and still rejects an intentionally out-of-bounds read.
The arithmetic probe checks all three operations with VCC and SGPR
destinations, overlapping operands, partial EXEC, and 64/512 invocations.
Wave64, FLAT and full Vulkan smoke checks pass with SDK validation.
The effect on the complete game frame still requires runtime verification.

Material recovery now rejects reserved image-resource bit 94 and destination
selectors 2/3, as specified by RDNA2 ISA section 8.2.6. The quad material
`0x80003a6b00` scans a 96-record table with stride 388; its unbounded 32-bit
offset multiplication also reaches overlapping word-aligned windows. Ordinary
float constants in those windows previously decoded as 1D-array and cube
textures, causing complete material draws to be rejected. The captured table
now resolves 25 valid 2D textures at each of its five sample sites. All 25
images and 125 mappings stage successfully on the RTX 3070 Ti with SDK
validation. A GPU regression includes malformed array/cube-looking constants
alongside valid textures and checks the selected texels and null bounds.
This verifies material preparation; the complete menu frame still needs a
fresh game run with the fix.

FLAT snapshot diagnostics now retain the first failed instruction PC, absolute
address and component, in addition to the total missing-word count. An atomic
claim prevents multiple invocations from overwriting the first record; the
record is outside the captured payload and synchronized before host readback.
The pointer and scene probes verify the address, relocation, concurrent faults
and rejection of a read beyond the captured object records. A current capture
of `0x8000196500` completes without faults, so earlier loading-time faults
should not be assumed to explain every later missing object.

The ReleaseFast run with pooled preparation objects completes the intro and
continues loading. Comparable early loading frames (600/616) take 906/1008 ms
versus 1123/1139 ms in the previous ReleaseSafe run. This is an early loading
comparison, not a measurement of the complete menu. First-use shader
compilation still causes much longer isolated frames.

The same Digital Deluxe notice subsequently gives a median of 8,872 ms
(0.113 FPS, 15 frames at flips 945–959) versus 11,526 ms (0.087 FPS,
19 comparable frames at flips 952–970) in the earlier ReleaseSafe run.
Both samples contain 210–225 draws and 410–440 compute dispatches; initial
compilation frames are excluded. This is about 30% higher throughput, still
far from interactive speed. The measured process includes the preparation
pools, storage residency and GDS/volume fixes, but predates the additional
CPU indices and FLAT-header hoisting below. The installed ReleaseFast binary
includes those later optimizations; their total in-game effect is unmeasured.

Resource reaching-definition queries now index outgoing control-flow edges
for graphs with at least 32 blocks, avoiding a complete edge scan per visited
block. Tiny graphs keep the direct scan. Unordered edges, duplicate edges,
cycles and disconnected blocks retain their reachability; oversized edge
lists use the scan fallback. All 80 analysis tests and the SDK nested-image,
uniform-loop and full smoke probes pass. A 10,000-query microbenchmark on
captured 105-/59-block shaders falls from 46.9/12.2 ms to 3.0/2.0 ms. These
figures describe that CPU query alone; its live FPS impact remains unmeasured.

Sampled-view cache hits also use address buckets instead of three complete
resident-cache scans. Candidate traversal retains the original order and all
view, sampler, content and generation checks. Removing or appending a view
invalidates the index; it is rebuilt lazily from the surviving entries. The
index occupies 24 KiB for the 8,192-entry cache. A synthetic 50,800-lookup
benchmark over 6,350 records takes 62.1 ms with the scan and 0.085 ms with the
index, including its initial build; this is not a whole-frame benchmark.
Collision/removal tests and the SDK 4,096-view, streamed-mip and full smoke
probes pass. The vector-image probe additionally replaces two cached texels
through the DCB write boundary, checks every lane and verifies subsequent
reuse without another upload. Live timing of this index remains pending.

FLAT snapshot base/length loads now live in the shader entry block. Every
read site and loop iteration shares those immutable header values, while
the fault counter and payload reads remain live. A synthetic module with
32 four-word reads and 33 regions shrinks from 1,695,411 to 987,132 words
(42%). This measures generated code size, not driver compilation time.
SDK probes retain signed/unaligned reads, 4-GiB carries, relocation, exact
bounds and fault counts; a repeated-read loop additionally checks entry-block
dominance and per-iteration faults. The captured scene-shape and full smoke
probes pass. Live driver-time and FPS effects remain unmeasured.

The depth/stencil HTILE fix is confirmed in the game. The three bonus notices
clear without retaining rectangles from earlier windows. The brightness
screen renders its wolf, smoky background, text, slider and Cross icon. The
difficulty and experience selection screens also render their labels,
arrows and selection indicators. This does not yet establish the complete
title menu or its animated scene.

The material at `0x8000273400 + 0x1a6c` loads T# descriptors from a table of
1,332 records, each containing three different views. Its unbounded 32-bit
index multiplication can wrap, so conservative enumeration includes all
3,996 descriptors. The former 512-candidate ceiling rejected this material.
The physical image limit is now at most 4,096, bounded by all applicable
native per-stage/per-set limits for the four image banks. PC-specific
mappings have a separate 16,384-entry ceiling.

Sets of at least 64 candidates use an uploaded hash table. The shader probes
until it finds an exact eight-word match, an empty entry or the longest host
insertion chain. Unmatched descriptors retain the existing zero-result
behavior; all descriptor-array accesses use a valid slot. This avoids
generating thousands of comparisons for every sample. Static texture views
share the renderer's resident sampler cache, and the texture cache can retain
two complete maximum-size binding sets.

The 4,096-view GPU regression verifies compute and fragment lookup, different
channel views of the same allocation, reversed table contents, out-of-range
indices and a single shared sampler. Its procedural vertex stage exposed a
separate bug: an empty vertex-buffer list caused a valid single PARAM export
to be replaced by synthetic UVs. Parameter pairing now survives that path;
only the explicit missing-export/video cases select a replacement VS.
The GPU regression passes with SDK 1.4.357.0 validation, and recovery of the
captured material now returns all 3,996 descriptors. Live scene validation
of the large-table and FLAT changes is still pending.

The compute shader at `0x8000316900 + 0x26c` reads six compressed image
descriptors through a scalar counter. Checkpoints correctly invalidate the
changing address, but resource recovery previously treated the table as
unresolved. A bounded zero-based unit recurrence now supplies the candidate
range, including page-spanning SMEM loads. Runtime pointer mappings take
precedence over scalar snapshots so each iteration reads its own descriptor.
Loop headers expanded by guarded memory operations use the structured
dispatcher to keep their back edges valid.

The six-image GPU regression checks every result, table relocation, a page
boundary and a null descriptor. It passes SDK validation, along with scalar
loops/pointers, nested and large image tables, scene FLAT snapshots and the
full headless smoke suite. Analysis of the captured game shader independently
recovers the six-entry bound. Live confirmation of this change is pending.

Two further refusals were reproduced from a running game. The visibility
kernel `0x8000333c00` loads object pointers from 592-byte records, but the
checkpoint at its texture operation no longer contains the original table
V#. Recovery now follows that descriptor's producer at the pointer load.
The captured 244-record table resolves to six objects sharing one depth
texture. The nested-image GPU regression additionally overwrites the table's
SGPR window before sampling and verifies both relocated object tables.

The kernel `0x800037f200` assembles a sampler with `S_BFM_B64` inside a branch
the scalar walk cannot visit. Resource recovery now reconstructs 32/64-bit
bitfield masks from their inputs. Both captured kernels execute one workgroup
with SDK validation and isolated output writes (120,863 and 60,215 SPIR-V
words respectively). These replays verify execution coverage, not complete
scene correctness. The pointer/table, typed-index, large-image, FLAT and full
smoke regressions pass; live integration remains to be checked.

The loading graph also fills all 256 storage-image cache slots while using
only about 752 MiB of its 1,280 MiB byte budget. Many entries hold tiny mip
levels. The count ceiling is now 1,024, with the byte budget and pin/retirement
rules unchanged. The GPU regression retains 320 dirty images without early
guest writeback, then checks all 1,152 writes across eviction pressure. It and
the full smoke suite pass SDK validation. The effect on live frame time has
not yet been measured.

The volume-combination kernels at `0x80003fd600` and `0x8000402100`
use a different loop: the signed comparison precedes the body and its limit
is loaded from root+264. Recovery now proves a zero initial counter, unit
increments and a required true comparison on both entry and every recurrence.
The limit is recovered at that comparison through its reaching definitions;
only a positive, nonwrapping bounded range can become a scalar pointer table.
Shift-and-add coefficient addresses are captured alongside the T# arrays.

All 79 index-analysis tests pass, including rejected counter clobbers,
negative initialization, nonunit increments and a bypassed guard. The SDK
GPU regression varies the memory-loaded limit between 3, 1 and 6, relocates
the texture table, reads distinct coefficients from another page and verifies
the untouched output tail. The existing six-image loop and full smoke also
pass without validation errors. This is regression coverage; integration of
the volume kernels into the game's final scene is still unverified.

A steady menu-transition profile also finds repeated `0xAA` initialization of
2,342,632-byte compute and 2,232,336-byte graphics preparation objects in
ReleaseSafe. Renderer-local pools now retain up to four of each CPU object.
Each preparation resets its counts, slot masks, addresses and fault state;
array elements outside the active prefixes remain unused. Recycling happens
only after the existing image/view/sampler ownership releases. Active loans
remain distinct and renderer teardown frees the pools.

The focused reset/ownership test and SDK storage-reuse, large compute/fragment
tables, scene FLAT and full smoke suites pass. This removes repeated setup
allocation and initialization; the change's live FPS benefit is not yet
measured. Large texture staging, readback and first-use driver compilation
remain separate costs.

Kernel `0x8000403f00` was rejected at its ordinary `DS_READ_B32 GDS`:
word reads/writes still called the LDS-only address helper. DS word and paired
accesses now select the existing M0-bounded GDS storage path when GDS is set.
Each component checks both the segment and physical 64 KiB range, wrapping
offsets are rejected, and writes retain the EXEC predicate.

The GPU regression writes and reads in separate dispatches, verifies persistent
word pairs, low/high EXEC, a partial pair at the segment boundary, wrapping
addresses and physical/empty-segment bounds. Atomic GDS, LDS translation and
full smoke regressions pass. The captured game kernel also runs against
controlled buffers: counter 77 produces counts `[2, 2, 1, 0]` and offsets
`[0, 32, 64, 80]` in a 1,338-word SPIR-V module, with clean SDK validation.
This verifies the shader's argument-generation path; its live scene output
still requires the next game run.

## Reproduce

```powershell
zig build build-game-run -Doptimize=ReleaseFast
.\zig-out\bin\game-run.exe "F:\PPSA26344\eboot.bin"
```

The intro decodes 582 pictures. Media Foundation reports a frame interval of
33,366,666 ns; normal movie render frames measure approximately 30–32 ms.
Vulkan SDK 1.4.357.0 validation completed an 85-second run, including the
transition out of the movie, without VUID reports.

## Resource catalog transition

Guest breakpoints identified a filesystem blocker after the intro. The startup
task advances through states 3 (movie), 7 and 8, then queues the scene loader.
That loader immediately moves from state 1 to terminal state 42: its catalog
is empty, so it rejects `game.sprig` before requesting the scene resources.

The catalog reader stats `cache_ps5/load_menu_catalog.log` (11,954 bytes),
combines `st_mtim` into nanoseconds and compares it against its cached value.
The filesystem previously returned zero timestamps, matching the initial zero
cache value and skipping the first read. `stat` and `fstat` now preserve host
access, modification and status-change times, including fractional seconds.
The filesystem test suite passes all 39 tests.

With timestamps fixed, the catalog contains three entries and the loader
reaches state 9, then starts the shared resource packages, including
`core_common_subcore.core_d0_ui.sprig.xpps` and
`core_common_subcore.core_b1_fx.sprig.xpps`. The APR worker also requests fire
textures. This exposed a second blocker: the fixed 256-entry APR ID table
rejected subsequent paths with `FileTableFull`.

APR IDs now use a growing table and a case-insensitive path index. The separate
64-descriptor cache remains bounded. All seven APR tests pass, including
resolving and reading 600 files, retaining earlier IDs across table growth and
resetting the table between processes.

The combined loading fixes advance the loader to state 24 and resolve more
than 560 unique files, including notification UI and title-stamp textures.
This exposed a separate Vulkan buffer-cache failure when the new scene
started submitting its compute work, investigated below.

Two GPU correctness fixes accompany the loading changes:

- Conservative image tracking now combines matching depth/stencil aspect
  barriers. The device does not enable `separateDepthStencilLayouts`, so
  splitting these barriers caused validation error `image-03320`. All five
  image-state tests pass, including the conservative-mode regression.
- Compute staging waits for prior readers before overwriting a clean cached
  buffer, including when page tracking is off. `gpu_dirty` only describes
  writes and cannot establish that a buffer is no longer being read.
  `vulkan-smoke --buffer-reuse` queues an actual GPU copy before changing its
  input. Without the fix it reads the replacement value `0xaabbccdd`; with
  the fix it retains `0x11223344`, for both exact-address reuse and recycling.

The full Vulkan smoke probe initially failed at `InvalidGuestGraphicsFrame`,
also with the compute-buffer fix removed. Its synthetic graphics setup had
color mode disabled and read VertexIndex from `v0`, while the Prospero graphics
path supplies it in `v5`. Correcting both fixture settings restores the test.
The full probe now passes, including 1,152 colored pixels in the guest target,
texture sampling, storage-image writes, PM4 synchronization and presentation.
The separate buffer-reuse and array-image probes also pass on the RTX 3070 Ti.
Both the full and array-image probes also pass with the SDK 1.4.357.0
Khronos validation layer loaded, without VUID reports. The machine's layer
registry still points to an old `C:\VulkanSDK` location; the test temporarily
registered the supplied `E:\VulkanSDK` manifest and restored the registry
afterward.

## Compute descriptor lifetime and bounds

With `PS5_DUMP_COMPUTE_SPIRV=1` and `PS5_GPU_SYNC_SUBMITS=1`, each diagnostic
compute completion flushes and waits for that dispatch. The device loss
followed the second `0x80003e9600` dispatch, a 129-instruction sorting kernel
with one 64-lane workgroup. Its emitted SPIR-V passes SDK validation, and
isolated replays with synthetic inputs complete. Capturing the actual
dispatch exposed a missing input allocation before the shader even ran.

A cache hit can bind an existing allocation at a different descriptor slot
without changing its original slot preference in the allocation cache.
Rebinding that original slot then recycled the allocation still bound as
another input of the current dispatch. Waiting for previous submissions
cannot protect bindings for work that has not yet been recorded.

The renderer now tracks storage-buffer bindings in the current descriptor
batch. Both slot-based recycling and LRU eviction exclude allocations still
bound at another slot. A fresh descriptor batch clears these pins; existing
timeline retirement and overwrite waits protect previous submissions.

Recycled allocations also publish the requested guest range as their Vulkan
descriptor range. Publishing the backing allocation's larger capacity made
`OpArrayLength` bounds checks accept stale bytes outside the guest range.

The GPU buffer-reuse probe now covers descriptor migration, all 64 cache
entries being bound while one slot grows, and a 64-byte allocation reused
for a 16-byte input. Before the fixes, migration reads `0xdeadbeef` instead
of `0x12345678`, and the out-of-bounds load reads stale data instead of zero.
All five scenarios pass after the fixes.

A normal launch with these fixes passed the former device-loss point and
reached loader state 29 with 964 unique APR files. The next stall was on the
CPU: the main thread waited for jobs at `0xdd2942`, while the compute-event
thread spun at `0x11565a2`, expecting generation 38 at `0x20000001e0` after
only 37 compute completions.

The log records an EOP carrying a frame number into `0x2000000200`, followed
by notification of compute registration `0x52`. Routing notifications only
to their originating queue fixes the generic release fan-out, but did not
resolve this particular stall: the release was part of a compute submission.
Its packet counter and its queue's retirement generation are independent.
The retirement bridge rejected a completed queue generation of 57 because
the packet contained frame number 720. Once the shared label table and queue
owner are validated, retirement now uses the queue's own generation without
ordering it against the packet's counter. Initial table discovery still
requires matching counters; queue identity and monotonic retirement checks
remain enforced.

Release notifications carry the originating submission's event identifier
separately from the packet payload. Graphics uses identifier zero; named
compute submissions retain the owner supplied to `SubmitAcb`. The scheduler
retains each submission's backend context across waits and queue resumes.
Regression coverage includes delivery isolation, preservation of context
after a blocked wait, and retiring queue generation 57 while preserving the
packet label's independent value of 720.

## Array texture processing

The scene also reaches a compute kernel at `0x80002c4500` that reads BC
texture arrays and later reuses the same descriptor SGPRs for storage-image
outputs. Array `IMAGE_LOAD` now supports both storage reads and sampled
fetches. A compressed read is resolved at its instruction PC, independently
of later stores through the same SGPRs. An exact sampled mapping takes
precedence over a generic storage mapping from a later instruction.

The Vulkan image probe copies the green second layer of a two-layer BC1
texture into an RGBA8 storage array after replacing its descriptor in the
same SGPRs. It verifies the green output and untouched first layer, alongside
the existing storage-copy and compute-sampling probes.

Array `IMAGE_GATHER4_LZ`, reached by scene kernel `0x80002e1b00`, now
preserves the layer coordinate in fragment gathers and the existing compute
fallback using four explicit level-zero samples. The GPU probe gathers the
green channel from layer one and checks all four values. The five gather
translator tests pass; the compute fallback remains an approximation of the
hardware gather footprint and filtering.

Resource-state evaluation also continues past unavailable scalar loads,
invalidating their destinations and allowing independent later descriptor
loads to recover. Strict prefix evaluation still stops on the failed load.
SMEM pointers and 64-bit moves can use the VCC register pair, and resource
checkpoints support up to 16,384 instructions. All 56 scalar-provenance and
imported tests pass, including stale-register invalidation, descriptor
recovery, a late checkpoint after 4,200 NOPs and a pointer moved into VCC.

A live replay of `0x80002c4500` exposed a further problem: three nested
lane-dependent loops repeatedly execute the scalar descriptor load at
`0x908`. Because the scalar evaluator cannot advance their VGPR counters,
it reaches its instruction limit and never observes the later output T#.
For a backward unconditional branch whose loop has a forward EXEC/VCC exit,
resource evaluation now retains one iteration's checkpoints, invalidates
loop-carried scalar destinations and continues beyond the back edge. Known
scalar-controlled loops retain their normal evaluation. The added regression
checks nested loops, unknown state at their exit, a fresh descriptor after
the loops and a scalar loop that must still execute all three iterations.

With the captured live SRT at `0x2014ae96b0`, evaluation previously stopped
at the 16,384-instruction limit near `0x9a0`. It now reaches program end at
`0x2d6c` after 1,855 instructions and 80 scalar loads. The store at `0x14d8`
correctly resolves an RGBA16F array at `0x50cb3d0000`, matching the actual
descriptor at SRT offset 484, instead of an earlier BC7 input. The output
enable flag at SRT offset 472 is one in this capture.

The nested-loop regression and imported tests pass all 57 cases. Full and
array-image Vulkan probes also pass with the SDK validation layer, without
VUID reports. In-game, the loader reaches state 32 after about 4.5 minutes.
Some variants of `0x80002c4500` still reject the store at `0x14d8`: a second
live SRT at `0x2011ad1cb0` has its output-enable flag set to zero. Evaluation
correctly skips the output-descriptor loads, but resource staging still
visits the inactive store and falls back to an earlier BC7 input. The uniform
output-guard fix below carries proven reachability into resource binding and
translation; treating compressed formats as writable images would not
address this case.

The final seven-minute launch reaches flip 703 and about 1,900 resolved
resources without device loss, instruction-limit rejection or a stopped
queue. Late scene frames contain 38 draws and hundreds of dispatches, taking
about eight seconds each. The captured window is still black; menu rendering
and scene performance remain unfinished.

The image-load translator tests pass seven of eight cases. The remaining
`three-coordinate image load follows a two-dimensional storage descriptor`
assertion also fails against the unmodified `54e9c70` source (expected one
SPIR-V type instruction, found two).

With the retirement fix, the game progresses past the job wait and reaches
114 draws, including indexed geometry, at flip 678. Resource loading continues
to 968 unique files. The next stopped ACB contains a valid 4,291-instruction
shader at `0x8052d9d500`; the old headerless decode limit of 4,096 rejected it
before the command stream reached its completion label. The headerless limit
is now 16,384 instructions. Registered shaders retain their exact allocation
bounds. The buffer probe exercises the normal dispatch path with 4,200 NOPs
followed by a load, store and program end, and checks the resulting GPU copy.

A 12-minute run with the lifetime, retirement and shader-size fixes reaches
flip 782 without device loss or an aborted ACB. The scene loader advances
from state 29 with 32 pending requests to state 32 with no pending requests,
and resolves about 1,900 resources, including terrain, vegetation and
building meshes. Late frames issue 38 draws and hundreds of dispatches at
roughly 3–5 seconds per frame. Captured final output is still black; this is
loading and command-execution progress, not a rendered-menu result. This
run preceded the scalar-recovery and array-gather changes above.

The subsequent run with scalar-load recovery and array gathers reaches flip
813 and loader state 35, resolving about 2,780 resources in 12.6 minutes.
It remains free of device loss and queue aborts, but the window is still
black. This capture preceded the nested-loop recovery change. Other observed
gaps include unresolved image descriptors and an array image store with
two enabled channels at PC `0x344`.

A final normal launch still decodes all 582 intro pictures at the original
33.37 ms cadence. Synchronous shader diagnostics are kept opt-in.

## Uniform output guards

Compute dispatch now proves block-local scalar guards from the current
USER_DATA snapshot and checked scalar loads before staging resources. A
control-flow dataflow pass excludes entry registers written on any incoming
path, including loop backedges. Unknown ALU results, unreadable flags and
unresolved indirect control flow cannot prove a branch. A later register
overwrite with no return path does not invalidate an earlier guard.

Proven branches and unreachable instructions are specialized in an owned,
dispatch-local analysis shared by resource staging and SPIR-V translation.
The decoded shader cache remains reusable when a flag changes. Unknown wave
branches retain both successors; alternate entries into a guarded region
prevent its removal.

The captured `0x80002c4500` shader now removes the store at `0x14d8` when
SRT+472 is zero and retains it when the flag is one, despite the later reuse
of s0 at `0x2bb8`. The Vulkan array-copy probe exercises flags `0, 1, 0, 1`
with the same shader and reused T# registers. A separate unconditional buffer
write proves each dispatch executes; disabled stores preserve the output,
and enabled stores copy the green texel from the compressed array input.

All 59 scalar-provenance and imported unit tests pass. Full Vulkan, buffer
reuse and array-image probes pass on the RTX 3070 Ti with SDK 1.4.357.0's
validation layer loaded, without VUID reports.

The game completes its intro at the original cadence and no longer reports
the inactive `0x14d8` store failure. This launch spends several minutes in
loader state 29 with 32 pending requests, then completes the batch and reaches
state 32 after about nine minutes. Both inspected SDK queue generations have
matching CPU completion labels during that delay. Scene frames reach 55 draw
attempts and hundreds of dispatches, but still take roughly 7–9 seconds and
produce a black window. The final capture at flip 779, after twelve minutes,
remains in state 32; no device loss or aborted queue was observed.

The remaining array-store failures are in **fragment** programs, not an
unsupported two-channel compute store. For example, `0x8038783800` contains an
`image_store` at `0x344` with dmask 3, followed by the color path. The translator
rejects image stores outside compute; graphics translation also does not pass
storage-image mappings, and their descriptor-layout bindings are visible only
to compute. This requires a graphics storage-image implementation (including
lane predicates and resource lifetime), not merely accepting the opcode.

## Fragment storage-image outputs

Fragment translation now receives the prepared storage-image bindings and
emits typed `OpImageWrite` for 2D, 3D and array images. Storage descriptors
are visible to the fragment stage, and draws bind them even when the pixel
shader has no sampled textures or storage buffers. Image stores in both
compute and fragment stages obey the current EXEC predicate.

Graphics keeps its combined vertex/pixel sampled-image table while staging
storage resources. Successful draws publish image writes to the resident
cache and alias tracker. Explicit image dependencies cover repeated writes,
storage reads and later sampling, including GENERAL-to-GENERAL transitions.
Simultaneous color-attachment/storage feedback remains unsupported.

Each prepared storage or sampled binding now owns a separate cache pin.
Retiring an older submission cannot unpin a resource held by the current
pass. Releases also wait for submitted work when the pending command list
is empty; CPU image publishers release their temporary upload pin.

The Vulkan probe writes RG16_UNORM into layer 1 of a two-layer image from a
pixel shader. CMPX enables only the left half; EXEC restoration allows blue
color export on both halves. Consecutive draws reuse the image with different
USER_DATA values, then compute consumers verify the resident result through
both array `image_load` and `image_sample_lz`, before CPU image writeback.
The untouched layer and disabled pixels retain their sentinel values.

Full Vulkan and image-only probes pass on the RTX 3070 Ti with SDK 1.4.357.0's
validation library loaded and synchronization validation enabled, without
VUID or synchronization errors. The cache-retirement regression and all six
image-store translator tests pass.

The game capture now includes a valid fragment SPIR-V module for the original
`0x8038783800` program: its two-channel array store at `0x344` becomes a
predicated `OpImageWrite` to an `Rg8` storage array. Captured variants of this
path also pass SDK `spirv-val --target-env vulkan1.2`.

The final 12-minute run resolves about 2,800 resources and reaches loader
state 35, with no device loss or aborted queue. It reaches 111 draw attempts
in one frame; the last recorded frame is flip 740, with 51 draws and 264
dispatches in 8.47 seconds. All 11 captured fragment programs containing
image writes pass SPIR-V validation. The inspected window at the state-32
transition is still black; a complete menu rendering is not confirmed.

Another observed failure is compute program `0x80003e2c00`, a 134-instruction
shader with an 8x8 local size. Its GDS `ds_add_u32` at `0x2bc` is rejected as
`UnsupportedBufferAddressing`: the generic DS atomic path still requires
workgroup memory. Unresolved image descriptors also remain in other compute
programs. These are separate gaps from fragment storage-image translation.

## Compute resource guards and lane-prefix decoding

Uniform branch pruning now propagates known scalar values through the CFG,
retaining a value at a join only when every incoming path agrees. Unrelated
vector instructions no longer discard loaded uniform flags. Zero-count loops
can therefore skip unbound image operations without rejecting the dispatch.
The separate resource walk can leave a loop with an unresolved scalar exit,
invalidate its scalar writes and recover independent descriptors after it.
`PS5_TRACE_RESOURCE_FAILURES=1` records the instruction, USER_DATA and known
scalar producers when resource staging fails.

Compute DS atomics now support indexed GDS segments and return the old value
for return-form operations. The new GPU probe checks persistent updates across
workgroups, both halves of EXEC, segment/physical bounds and returned values.

The decoder and translator also support byte/short D16 loads, formatted D16
loads and unsigned 16-bit CMPX. Formatted D16 stores currently support identity
channel selection with 16/32-bit float or integer components; other store
conversions remain explicitly unsupported. Byte accesses use the containing
aligned word for bounds checks. Atomic byte masks prevent adjacent halfword
stores by different lanes from losing each other's updates.

A subsequent allocation trace identified a separate decoder error: native
VOP3 opcodes `0x365`/`0x366` are RDNA2 `V_MBCNT_LO/HI_U32_B32`, not the float
minimum/maximum operations assigned these numbers on newer architectures.
See AMD's [RDNA2 ISA reference, section 12.12](https://docs.amd.com/api/khub/documents/Et~wpu9g~Ffl7d9q0QZ~Og/content).
The translator now counts all low-half mask bits for lanes 32–63 and avoids
out-of-range shifts. A GPU probe checks every lane's prefix and uses the
result to select exactly one GDS counter update, including a mask whose only
active lane is 63.

Before this correction, repeated runs exhausted the game's fixed graphics
pool (`0x5000000000..0x50d3400000`) while allocating model output buffers at
`0x114dfc6`. A later allocation at `0x11545dc` returned null and the guest
faulted in `memset`. The trace distinguishes this guest-pool exhaustion from
host Vulkan allocation failure; no pool-size override was added.

GDS/prefix, packed-buffer and full Vulkan probes pass on the RTX 3070 Ti with
SDK 1.4.357.0 validation and synchronization validation enabled. The scalar
tests (24) and native-VOP3 decoder tests (6) pass. The older DS addtid translator
test still fails with `UnsupportedBufferAddressing` on the unchanged baseline.
With the lane-prefix correction, the game passes the old null-allocation
failure, reaches loader state 35 and resolves over 2300 resources. About
112 MiB remains in the graphics pool at the state-32 transition. Indexed draw
uploads now occur, but the inspected state-32 window is still black.

The next observed decoder refusal, `V_CMPX_CLASS_F32` at `0x64d8` in compute
program `0x8052d9d500`, is also implemented. Its original SDWA instruction is
tested on the GPU with positive/negative finite values, zero, subnormals,
infinities and NaNs, including source modifiers and preservation of VCC.
Dynamic descriptor selection in `0x8000333c00` remains unresolved. A complete
menu rendering has not yet been confirmed.

## Streamed scene resources and AGC shader interfaces

The longer run with the lane-prefix fix resolves 6,042 resource requests and
reaches loader state 40. Its next CPU fault is in the register-table consumer
at `0x1650cc4`: the first entry contains a host return address from an
uninitialized stack array. NID `dbOlWdppb4o` is the interpolant-mapping helper,
not an extension of primitive state. It now initializes all 32
`SPI_PS_INPUT_CNTL` pairs and matches PS input semantics against GS exports,
including defaults, flat/custom shading and packed half attributes. The
captured failing pair has six matched semantics, with input 5 flat shaded.

A ReleaseSafe run also exposes byte-packed shader headers (for example,
`0x801e975691`). Shader creation, program-register patching and fusion read
these fields without native alignment assumptions. Regression tests cover
the captured semantic pattern, unmatched/default inputs and odd-address
headers with odd-address register tables.

Sampled textures loaded from an indexed scalar-buffer descriptor table can
now bind a bounded set of candidate views. The translated shader compares
all eight runtime T# words and selects the matching Vulkan descriptor, with
the required nonuniform indexing capabilities and decorations. Aliases with
different channel mappings remain distinct. Null/out-of-bounds selections
return zero. Candidate enumeration includes 32-bit multiplication wrap;
unbounded tables and nested pointer-driven image/sampler tables still refuse.

Texture uploads now read the selected mip range rather than requiring every
resource mip to be committed. Smallest-first mip placement preserves the
full resource layer stride; array views copy their selected blocks across
uncommitted gaps. Missing bytes inside a selected mip still fail. The game
previously refused a 4096-square BC3 view at base mip 1 even though its
approximately 5.6 MiB resident prefix was mapped, because it also read the
uncommitted 16 MiB mip 0.

The indirect-image and streamed-mip GPU probes and the full Vulkan smoke pass
on the RTX 3070 Ti with SDK 1.4.357.0 validation and synchronization validation,
without VUID or synchronization errors. All 28 tiling tests and the targeted
AGC tests pass. The new game run passes the packed-header failure and continues
through state 23. Passing state 40 and rendering the menu remain unconfirmed.

## Scene shader validation and scalar spills

The streamed run reaches state 29, then loses the Vulkan device. Newly reached
vertex programs contain unsigned `OpPhi` results with signed ABI input values;
the vertex/instance IDs now enter the register file as unsigned bits. Some
fragment programs consume the same PARAM export through both smooth and flat
attributes. Paired translation assigns each PS attribute a unique Vulkan
location and replicates the corresponding VS export to those locations.

Uniform SGPR spills in `v18` are represented by independent private lane slots.
Ordinary VGPR writes invalidate those slots, and unknown reads keep the subgroup
fallback. Resource analysis also restores known spilled pointer halves before
subsequent scalar loads, forgetting slots after unknown writes or unresolved
loop overwrites. This does not implement general wave64 communication on a
smaller host subgroup.

The shader-header registry previously filled its fixed 8,192-entry table and
silently discarded later scene headers. It now grows dynamically; a regression
test checks all 12,000 mappings, replacement, nearby-entry lookup and reset.

The interface GPU probe checks ABI control-flow merges, smooth/flat aliases,
independent spills and their invalidation. It and the full smoke pass with SDK
1.4.357.0 validation. All 26 scalar-provenance tests pass. The actual game emits
128 valid SPIR-V modules in its next run. A later trace establishes that
`VK_ERROR_DEVICE_LOST` precedes the buffer-lifetime and command-resubmission
validation errors. The timeline query then reports `UINT64_MAX`; treating it
as completion incorrectly retires resources. Device loss is now latched, and
completion values beyond the last submitted tick are rejected. The original
GPU fault still requires investigation.

## Material tables and the end of scene loading

Waiting for each command buffer from frame 675 passes the former device-loss
point at flip 683. This diagnostic run resolves 6,045 APR requests, reaches
loader state 40, clears the loader object and starts producing nonzero audio
PCM. It stops at compute program `0x801f225d00` with `ResourceOutsideSrt`.
No Vulkan validation errors occur during this run; its captured window is
still black. Serial completion changes timing and batching, so this does not
establish the cause of the original GPU fault or confirm a rendered menu.

The captured program and its metadata show that sharp offsets refer to the
logical USER_DATA bank: offsets below 32 select captured hardware registers,
and larger offsets select `(offset - 32) * 4` in extended user data. The SRT
size does not bound those descriptors. The metadata size bit distinguishes
four-word buffers/samplers from eight-word images. Resolution now follows
that layout and checks the corresponding register or EUD bounds. Compute
staging also avoids an eager scan of unused constant-buffer metadata.

Scene material program `0x80002e6d00` guards its record index below 255, spills
it into a VGPR lane, then multiplies the restored index by 368. Resource
analysis follows the guarded value through the spill and CFG before narrowing
candidate descriptor offsets. Ambiguous definitions, bypass paths and
unproven bounds retain the full 32-bit wrapping interpretation. The sampled
descriptor bank grows independently of the storage-buffer bank, up to 512
textures within the Vulkan device limits, with 4,096 instruction mappings.
These per-pass tables are heap allocated: keeping the expanded tables on the
HLE stack overflows it during the first graphics draw in the real game, even
though standalone GPU probes have enough stack space.

BC4 formats 175/176 previously used 16-byte blocks instead of eight-byte
blocks. Both tiling and upload sizing now use eight bytes. The captured
2816-square single-mip allocation requires `0x3c8000` bytes; a 2048-square
12-mip allocation requires `0x2ab000`, matching the game's resident ranges.

The inline-buffer, 128-texture indirect sampling, BC4 UNORM/SNORM, shader
interface and full Vulkan probes pass on the RTX 3070 Ti with SDK 1.4.357.0
validation and synchronization validation, without VUID or synchronization
errors. Metadata and tiling tests cover register/EUD bounds and the captured
BC4 allocation sizes. These checks do not replace the next full game run.

`PS5_TRACE_RESOURCE_FAILURES=1` enables NV GPU fault checkpoints when supported.
`PS5_TRACE_GPU_COMPLETION_FROM_FRAME=N` additionally waits after each command
buffer starting at frame N; it is an expensive diagnostic, disabled by default.
Nested pointer-driven image/sampler tables require runtime pointer loads;
the initial scalar-only specialization cannot resolve them.

A descriptor ownership regression test reproduces reuse after an intermediate
flush in the same pass: the old tick is complete, but a later draw still queues
another use of that set. Queuing now restores its pending reservation. The test
previously selected and cleared the old set; it now selects a free set and
preserves the queued draw's scalar data. The buffer-reuse and full Vulkan probes
also pass with SDK validation. Its relationship to the game device loss is not
yet established.

The next material refusals use VCC_LO/VCC_HI for scalar-buffer byte offsets.
Candidate lookup previously accepted only ordinary SGPR offsets. Translation
also incorrectly applied its reserved MUBUF offset fallback to SMEM, replacing
VCC offsets with zero. Both paths now retain the computed VCC word. GPU probes
cover guarded offsets in ordinary SGPRs and both VCC halves, with distinct
texture selection and out-of-bounds results. Before the fix, the VCC probe
first refused the resource and then, after binding alone was corrected, read
the first texture for every index. The complete fix and full smoke pass with
SDK validation. The captured material shader's 16 guarded multiplications
all retain the proven exclusive bound of 255.

The next asynchronous run completes all 6,045 resource requests, reaches
loader state 40 and clears the loader. It passes the former metadata failure,
but four later compute submissions stop their queues (three
`MemoryReadFailed`, one `UnknownInstructionFamily`). The window remains black.
Four newly reached pixel modules also fail SPIR-V validation because 2D-array
gradients incorrectly include a third component for the layer. Gradients now
exclude that component, as required by the SPIR-V image operands specification.

Compute program `0x8000333c00` loads object pointers from 592-byte records,
then reads T#/S# fields through those pointers. Resource preparation now
discovers those image candidates and snapshots readable object pages into
storage buffers with runtime guest-address headers. Pointer-form SMEM uses
both address halves, carries byte offsets across 32 bits, checks each word
against the captured regions, and returns zero outside them. Addresses stay
in buffer data so relocation does not create another pipeline. Discovery is
bounded by storage capacity and currently requires candidate samplers to agree;
this is not general GPU virtual-address translation.

The nested-image GPU probe verifies different textures, null/OOB pointers and
relocated object pages with a pipeline cache hit. A separate scalar probe
checks loads split across the 4-GiB boundary. Both, the six indirect-image
cases and the full Vulkan smoke pass with SDK validation. A regression test
checks the array-gradient operand dimensions. Full game verification of these
changes is still in progress; menu rendering is not confirmed.

The post-load G-buffer passes mix float outputs with an R32_UINT attachment.
Fragment export declarations and writes now follow each target's numeric
type, preserving raw 32-bit integer payloads and unpacking compressed integer
exports as signed/unsigned halfwords. Storage-only fragment programs no longer
declare an unwritten color output. A four-case GPU probe verifies mixed MRTs,
integer bit patterns which would be NaNs as floats, and signed/unsigned packed
exports through guest-memory readback. It, the shader-interface probe and the
full smoke pass SDK validation without output-type warnings.

The first live nested-pointer attempt still refuses `0x8000333c00`: unbounded
32-bit residue enumeration admits pointers from neighbouring fields, including
texture data that happens to decode as another T#/S# pair. Its actual index
comes from a vector logical shift by 16, selected with FF1 of a saved EXEC mask.
Bounds analysis now proves that the waterfall loop only removes lanes from
the mask which received that vector write. Mask restores/OR, separate writes
to either scalar half and ambiguous vector definitions reject the proof.
The resulting exclusive bound 65,536 rules out multiply overflow and limits
the captured six-record table to its six pointer fields. Replaying the capture
with readable decoy memory fails before this bound and resolves one shared
texture/sampler afterwards. The GPU nested probe also excludes a valid decoy
pointer with a different sampler; existing wrapping and guarded tables pass.

The following material refusal at `0x80002e6d00:0x1e98` uses a VCC_HI
table offset while separately computing another address in VCC_LO. Candidate
analysis now distinguishes those 32-bit scalar writes from vector condition
masks and 64-bit scalar writes. The captured table resolves 51 image candidates
at record offset 128; the high-half GPU probe preserves selection after an
independent low-half add.

GFX10 sample operands follow ISA section 8.2.5: optional offset, bias,
comparison reference and derivatives precede the coordinate body; explicit
LOD follows it. Sample/gather translation now uses that order. Array-only
compute shaders also create their two-component derivative type explicitly:
otherwise a shader with no ordinary 2D binding can emit type ID zero. The GPU
array-gradient probe verifies that the intended array layer is sampled from
distinct derivative/coordinate values. It, streamed-mip sampling, integer MRTs
and the full smoke pass SDK validation.

The repeated scene samples at `0x50bdbb0000` use GFX10 format 24
(RG16_SNORM). Sampled views now use Vulkan's matching normalized signed format,
which was already supported by storage-image and tiling paths. The array
gradient probe additionally verifies a negative RG16_SNORM value by GPU
readback with SDK validation enabled.

Post-load resource recovery also follows the actual reaching definition of
each scalar word through pointer loads, buffer loads and scalar moves. The
captured `0x801f108000` shader reused s4:s5, but its old V# fallback still
treated entry values `0x20, 0x5204` as an address, reading
`0x5204000002a8`. Recovery now follows s0 -> s32 -> s4 instead. Entry words
are accepted only when no shader writer reaches the use; mixed paths and
unknown clobbers remain unresolved. Real inaccessible producers still report
read failures. CPU tests cover nested loads, partial buffer bounds, SGPR-base
mapping and divergent writes; full, indirect, nested and scalar-pointer GPU
probes pass SDK validation.

The pointer run reached loader state 40 before a diagnostic itself panicked:
an indirect candidate in the captured 440-byte record table had format 149
and unnamed tile mode 25. Calling `@tagName` on that non-exhaustive enum
aborted the process before the refusal could be printed. All Vulkan tile-mode
diagnostics now format unknown values numerically, with all 32 encodings
tested. Host panics additionally retain their failing return address when a
guest-created thread has no unwindable host stack. A complete menu render is
still unconfirmed.

The 440-byte material table at `0x801f98cb00:0x1424` now uses the integer
range of its upstream image fetch. The waterfall mask is saved through VCC
before the fetch; analysis verifies that EXEC is unchanged up to that write
and that subsequent iterations only remove lanes. R8/R16 UINT and SINT
formats bound the selected index. Negative signed indices are excluded only
when their wrapped byte addresses provably remain outside the table.
Replaying the saved 31-record table with the R8_SINT source descriptor from
the live scene reduces 274 candidates to nine distinct textures at field
offset 32, stride 440. A GPU probe with unrelated float fields reproduces the
format-149 refusal before the fix and passes all four integer formats after
it, including negative and out-of-range indices. Existing nested and
indirect texture probes remain valid under the SDK layer.

A subsequent validation run stopped at flip 742 with a lost Vulkan device.
The timeline query returned success with `UINT64_MAX`; that defensive path
now reports the queue's fault checkpoints as well. The last unfinished
command carried pixel program `0x800040fb00`, a short texture copy whose
SPIR-V validates. Immediately before it, the full render-target cache
retired a 1024-square attachment during destination preparation.

Resident sampled and storage bindings now pin their color targets until the
draw or dispatch has been recorded. Attachments and intermediate resize
sources use the same protection; submitted commands retain deferred Vulkan
destruction. A baseline GPU setup reproduces eviction of a prepared source
without executing a draw through the invalid descriptor. The new
`vulkan-smoke --target-reuse` probe fills all 64 cache entries, samples the
oldest into four new destinations, verifies red GPU readback and checks
that every preparation pin is released. It passes SDK validation alongside
the existing buffer-reuse, typed-index and full smoke probes. The next game
run passed flip 742 and continued loading more than 5,400 scene resources
without that device loss. Its output still shows a loading indicator on a
black background; the menu has not yet been verified.

The two recurring resource failures in `0x800037f200` have been reproduced
from captured shader code, USER_DATA and resource tables. At PC `0x66c`,
eight-word T# tuples travel through masked VGPR copies before a waterfall
selects them. Resource recovery now follows complete correlated tuples.
Ordinary VGPR writes preserve inactive lanes: a four-lane GPU probe selects
two distinct textures and fails with the former unmasked writes. At PC
`0x970`, unreachable NOP blocks left by branch specialization no longer
contribute spurious reaching definitions.

CPU scalar buffer loads now enforce per-dword V# bounds, matching runtime
loads. Scalar resource recovery rechecks SMEM instead of accepting a matching
but unchecked snapshot. SOFFSET remains a real register even when it overlaps
V#; only NULL disables the offset. Captured replay now resolves both texture
uses, and the GPU scalar-pointer probe checks overlapping SOFFSET and partial
out-of-bounds loads. Vector, nested, typed-index, integer-color, array-gradient,
target-reuse, buffer-reuse and full Vulkan smoke checks pass under SDK validation.
Module tests retain the same nine RDNA2 failures and one executor failure as
the previous commit; the changed resource-analysis tests pass.

Another recurring compute refusal, `0x80001fd400:0x28a8`, references an empty
lighting texture table. Exhaustive table recovery now distinguishes a proven
all-zero source from an unresolved or malformed descriptor. Null samples
produce zero without allocating an image or requiring a sampler. Captured
replay and GPU tests cover empty tables, restoration of real textures and
rejection of malformed nonzero descriptors.

The cache-pinning game run completed 6,042 resources and left loader state 40.
It then refused `0x801eb8de00` and lost the GPU in `0x80001fd400` at flip 912.
Live memory inspection explains the decoder refusal: AGC's low-32-bit alias
lookup redirected shader address `0x801eb96240` to command arena
`0x201eb96240`, returning PM4 word `0xc00e1000` instead of instruction
`0x4130bb96`. Address resolution now checks the complete readable guest VA
before using a compact command-arena alias. A regression test recreates the
collision with two actual mapped pages: the old implementation reads PM4 as
shader code; the fix preserves both reads and writes, while reserved compact
label addresses still resolve correctly. The next full run must also
validate the remaining GPU fault and menu output.

Additional scene material shaders save EXEC with `S_AND_SAVEEXEC_B64` after
their integer image fetch, then restore the saved lanes for a waterfall.
Index analysis now recognizes that pre-narrowing mask. A saved mask taken
before a narrowing fetch remains insufficient. Eight GPU cases cover both
mask-save forms with R8/R16 UINT/SINT inputs. Replaying `0x801f6d5100:0x2c4`
with its captured SMEM values and material table reduces 274 candidates to
nine, excluding unrelated float fields that decode as format 149.

Later loading passes churn the 128-entry storage-image cache while using
only 700–880 MiB of its 1,280 MiB byte budget. CPU sampling attributes much
of the frame time to dirty-image readback, tiling and repeated uploads.
The entry ceiling is now 256, with the same byte budget. When earlier queued
commands pin every eviction candidate, the cache submits and retires that
work before retrying; pins held by the command being prepared remain intact.
The storage-reuse GPU probe retains 160 dirty views and checks all 320 writes
in a larger batch. The previous eviction logic drops writes with
`StorageImageCapacityExceeded` even with the increased entry ceiling.

Three scene compute shaders (`0x8000196500`, `0x80001c0d00` and
`0x80001abb00`) were skipped at their first `V_CMP_EQ_U64`. Their captured
instruction streams also require `V_CMPX_GE_I16` and
`BUFFER_STORE_SHORT_D16_HI`. All three operations now decode and lower;
the store participates in buffer-write tracking and EXEC masking. Captured
replay decodes all 7,768, 7,587 and 7,673 instructions respectively. A 64-lane
GPU probe verifies full-width equality, signed halfword comparison, unchanged
VCC and high-half stores that cross a dword boundary while preserving nearby
bytes and inactive lanes. Decoder tests and packed-buffer/full Vulkan smoke
checks pass under SDK validation.

The next live run reached all 6,042 resources without the AGC address-alias
decode refusal. Its 62 captured material refusals require tracking restored
EXEC across conditional blocks, including snapshots made by SAVEEXEC before
the fetch, READFIRSTLANE and an index held in VCC_HI. Index analysis now proves
the selected lanes received the typed image value before applying its bounds.
It still rejects snapshots which include lanes absent from the fetch. Replay
of all 62 complete captures recovers 9–31 valid textures per field instead of
274 candidates containing unrelated format-149 data. Twenty-eight GPU cases
cover the mask and index-register variants with signed/unsigned R8/R16 inputs;
the index-analysis module and its imported tests pass (72 tests).

The live run still loses the GPU in lighting compute `0x80001fd400` at flip
912 after loading finishes. A separate replay reconstructs its real shader
header, user data and resources; a single workgroup completes, while the
full `1 x 64 x 36` dispatch remains under investigation. Menu output is not
yet verified.

The standalone lighting replay exposed `VUID-vkCmdCopyBufferToImage-pRegions-00171`
for base-only views of texture `0x509e780000`. Detiling produced one visible
layer (1 MiB), but upload commands copied two or three physical layers because
they reused the descriptor's last-slice extent. Uploads now use the staged
view's layer count. The array-gradient GPU probe covers first slices 0, 1 and 2
in RGBA8 and RG16 SNORM; its previous version produces four validation errors,
while the fix preserves the sampled values without those errors. An offline
replay of the complete `1 x 64 x 36` lighting dispatch also completes with clean
SDK validation. Its captured CPU backing data does not reproduce every dirty
resident image from the live frame, so a full game run remains necessary.

Lighting also uses DPP row reductions and PERMLANE permutations. DPP row shifts
previously shuffled in the opposite direction, row rotation did not wrap at
16 lanes, and absolute subgroup indices became invalid for guest lanes 32–63
on a 32-lane host. PERMLANE used a single selector nibble instead of the nibble
for each destination column. These now follow the RDNA2 ISA, including DPP
row/bank write masks, boundary preservation/zeroing and inactive-source fetch
control. Twenty GPU cases check all four guest rows and both halves of the
64-bit permutation selector; the old left-shift case returns 100 instead of
103 in lane zero. The corrected full lighting replay completes with clean SDK
validation.

A further GPU probe confirmed that READLANE 63 returned lane 31's value on the
RTX 3070 Ti. Compute programs which read the upper half of a single 64-thread
workgroup now exchange values through workgroup scratch and retain complete
64-bit comparison/EXEC masks. Scalar EXECZ branches test the whole mask, while
conditional selection and arithmetic carry use the current lane's bit. This
keeps workgroup barriers converged even when only lanes 35–63 are active.
The GPU probe checks two independent groups in both `64 x 1 x 1` and `4 x 4 x 4`
shapes; the complete captured lighting dispatch also finishes with clean SDK
validation (387,667 SPIR-V words). The path is restricted to one guest wave per
workgroup and excludes GDS kernels; other wave configurations still need work.
Focused lane tests retain the pre-existing image-resinfo and DS-addtid failures.

The next full run loads all 6,042 startup resources in about 30 minutes and
continues beyond the former lighting device-loss point. Direct framebuffer
capture at flip 932 shows the Digital Deluxe Bonus notice, with readable text
and an incorrect cross-button glyph. Windows PrintWindow captures were black
and did not represent the Vulkan image. The menu behind the notice remains
unverified. Three scene compute programs refuse nested FLAT addressing.
Their captured dispatch flags are 56: the first collision branch is disabled.
Uniform branch specialization now evaluates `S_BITCMP0/1_B32` and 32-bit
logical operations, including SCC and unknown-operand invalidation. Captured
replays remove 15 of 38 FLAT reads in each program without missing memory;
23 real pointer reads remain and are not replaced by zero. All 68 scalar
provenance/module tests and the 62 captured material resource cases pass.

Pruning can leave compute loops that only read EXEC, without a full-mask
destination. Mutable loop lowering still tests that saved mask, so it needs
lane identity. Inference now accounts for EXEC sources, high-half writes and
implicit SAVEEXEC writes. Without it, a GPU probe silently takes the linear
fallback and returns 1 instead of 4 iterations. The corrected probe returns 4
and preserves inactive upper lanes, with clean SDK validation; the two wave64
workgroup shapes also pass. Strict CPU translation covers all three EXEC forms.

The later scene run with wave64 and scalar bit-guard specialization reaches
the Digital Deluxe Bonus notice again. Warm frames around flips 940–947 take
35–37 seconds; shader compilation is no longer the dominant cost. A main
thread sample attributes 53% of samples to checked guest reads while scanning
mesh indices and another 32% to reading discarded compatibility colour images
after depth-only draws. Those shadow passes read back up to 64 MiB per draw.

Index-range validation now reads bounded 4 KiB blocks, skips draws with no
VertexIndex mappings and checks address overflow before access. CPU tests
cover UINT16/UINT32 block boundaries, signed base vertices, unreadable tails
and empty mappings; 4,097 UINT16 indices require three checked reads.
Depth-only passes retain their depth writes and generations without allocating,
copying or scanning a host colour buffer. The SDK depth probe verifies a
triangle's depth, preservation across a second draw and no colour readback;
the complete Vulkan smoke also passes with clean SDK validation. Live frame
timing with these changes is about 16–18 seconds around the same notice,
down from 35–37 seconds. Draw time falls from about 22 to 4 seconds; compute
resource preparation dominates the remaining frame. This run predates the
permission lookup and compute driver-cache changes below.

Checked memory permissions now start with a binary search in the ordered
mapping table, then visit only the adjacent mappings covered by the request.
All nine memory tests pass, including a byte-level permission oracle over
gaps and boundaries. A controlled ReleaseSafe benchmark with 16,384 mappings
and 32,768 reads near the end of the table drops from 310,264 to 479 us. This
measures the lookup alone, not game frame rate.

Real compute pipeline creation now uses the persisted driver cache. Its
compile job previously passed a null cache in both synchronous and worker
modes, so only graphics pipelines benefited from the saved data. The cache
uses Vulkan's default internal synchronization. The full SDK smoke passes
with an initially empty cache; the standalone compiler-failure probe retains
its intentional cache bypass.

The frame-948 trace stopped in the diagnostic vertex dumper: it requested nine
words from an eight-word checked reader. The dumper now respects that bound.
That incomplete capture includes numerous rejected shadow draws before the
notice's UI passes, so it cannot establish the cross glyph's cause.

A subsequent warm-thread sample spends roughly 40% of samples in the scalar
subresource address function during texture tile/detile copies. Volumes,
mip tails and MSAA copies now cache the local X swizzle contribution and
compute the remaining coordinates once per block row. Element-sized copies
also avoid a variable-length memcpy for every pixel. All 29 tiling tests and
the complete SDK Vulkan smoke pass; scalar-address comparisons cover volume
families, all supported element sizes, mip tails, partial blocks, array
offsets, MSAA samples, untouched padding and short-buffer errors.

A controlled ReleaseSafe benchmark of four tile/detile round trips changes
from 34.3 to 2.4 ms for a 1 MiB volume, 642.0 to 39.9 ms for a 16 MiB volume,
and 735.7 to 41.7 ms for a 16 MiB MSAA image. Output hashes agree. These are
copy timings, not whole-game FPS; a complete live frame still needs measuring.

A partial late-frame trace identifies the cross as a six-vertex font draw
(`VS 0x80003f0e00`, `PS 0x80003dc300`), using the icon atlas rather than the
loading-spinner material. Its packed flags export icon selection in PARAM3.X
and SDF width in PARAM3.Z. `V_INTERP_MOV_F32` incorrectly read its VSRC selector
as the channel, so P0 (selector 2) always loaded Z, including the icon selector.
Translation and graphics interface component discovery now use ATTRCHAN.
The [AMD RDNA 2 ISA](https://docs.amd.com/v/u/en-US/rdna2-shader-instruction-set-architecture)
defines these as separate fields. A decoded P0 GPU probe previously produced
RGBA `{0,0,0,0}` and now produces the expected `{0,127,0,255}`; existing
smooth/flat interface checks and the full Vulkan smoke pass with clean SDK
validation. Live verification of the notice is still pending. After confirming
the old notice with Cross, the captured framebuffer remained black while the
scene continued submitting frames.

The next notice eventually appears (`Gift of the Northern Star Unlocked`),
confirming that the first black interval was also a slow UI transition. This
does not establish the menu background. Captured shadow draws use polygon
offset format `0x1e9` (D32 float, -23), zero clamp and equal front/back bias.
These settings now map to Vulkan depth bias, with the hardware slope divided
by 16 and the constant preserved. Other depth representations, nonzero clamp
and unequal face settings remain rejected. CPU tests exercise both captured
raster modes and three slope values. The SDK GPU probe shifts depth 0.5 to
0.4990234375, retains it across a second draw and avoids colour readback;
the ordinary depth probe and complete Vulkan smoke also pass. This change
still needs validation in the title's scene.

The run with swizzle caching, permission lookup and corrected flat channels
loads all 6,042 resources in 20m13s. The fully visible Digital Deluxe notice
now has the correct complete X glyph. Warm full frames take 13–14 seconds
versus 16–18 seconds previously; an earlier 10.6-second transition frame has
less work and is not the steady-state result. CPU samples now concentrate on
memory copying/clearing and storage-image cache eviction. The 2D-only swizzle
axis experiment did not improve render-target copy timings and was not kept.

The RTX 3070 Ti exposes uncached coherent host memory at type 3 (`0x6`) and
cached coherent memory at type 4 (`0xe`). Buffer allocation previously took
the first compatible type, including for GPU readback. Host-visible transfer
destinations now prefer HOST_CACHED while retaining every required property;
upload-only buffers and devices without a compatible cached type keep their
existing selection. This follows the [Vulkan memory property contract](https://docs.vulkan.org/refpages/latest/refpages/source/VkMemoryPropertyFlagBits.html).
CPU selection tests cover supported-type masks, coherence, device-local
requirements and fallback. Four verified 64 MiB reads of GPU-written data
drop from 508,056 to 21,382 us under SDK validation. This is a readback
benchmark; the additional whole-frame gain is still unmeasured.

Resident compute buffers also need this preference: their CPU readback maps
the storage allocation directly, so they do not carry TRANSFER_DST usage.
Both initial allocation and growth now explicitly prefer HOST_CACHED with
the same required coherent/visible flags and fallback. Write-only storage
upload arenas retain the default policy. Selection tests cover this path;
queued compute readback, descriptor migration, cache recycling and growth,
and the complete Vulkan smoke pass under SDK validation.

Sampling the cached-memory run still finds substantial time in the host
`memset`. Disassembly shows eight separate byte stores per loop in Zig
0.16's fallback; sampled callers include allocation/free poisoning (`0xaa`)
of 23–67 MiB staging and render-target buffers. The Windows x86-64 runner
and Vulkan smoke now supply the C memset symbol with REP STOSB. This retains
ReleaseSafe poisoning and checks, requires no optional CPU instruction set,
and avoids a compiler-generated recursive memset call. Other targets retain
their existing runtime implementation. Tests cover all lengths 0–512 at 64
alignments, signed/truncated fill values, return pointers, null/zero length,
and a 4 MiB fill with sentinel bytes on both sides. Sixteen 64 MiB host fills improve from 117,636 to
34,599 us with the same output hash; the complete SDK Vulkan smoke passes.
This is an isolated memory benchmark, not a measured whole-frame multiplier.

The live runner now reaches the bonus notice with cached transfer/compute
memory and the faster host fill. CPU sampling confirms that calls use the
REP STOSB implementation; the fallback symbol remaining in the binary is not
the sampled fill path. The corrected complete Cross glyph remains visible.
Ten-frame samples around the bonus notice give:

| Build | All 6,042 resource resolutions | Median frame time | FPS over the sample |
| --- | --- | --- | --- |
| `748f6fd`, before cached readback | 20m13s | 13,614 ms | 0.073 |
| `b258af6`, cached transfer and resident storage buffers | 15m45s | 11,242 ms | 0.089 |
| `c237830`, also accelerated host fill | 12m06s | 9,151 ms | 0.108 |

The samples are flips 932–941, 919–928 and 921–930 respectively. Animated
draw counts vary between runs; these are observed scene timings, not a
deterministic replay benchmark. The cached builds also support the captured
D32 depth bias. A ten-second sample of the cached-buffer run uses 11.94% of
the 16 logical CPUs; GPU utilization in two readings is 22–27%, with about
5.1 GiB of GPU memory in use. Frames still upload roughly 1.9 GiB and read
back 1.6 GiB, so host resource preparation remains the major limitation.
Confirmation starts closing the Digital Deluxe notice. Complete title-menu
background rendering is not established by these performance results.

Continuing the same `c237830` run reaches `Gift of the Northern Star Unlocked`
at flip 1001 and `Pre-order Bonus` at flip 1051. Keyboard confirmation is
verified by pad diagnostics (`0x4000` followed by release); pressing before
the notice finishes appearing can be ignored, so confirmation is retried on
the settled notice. All three bonus windows can be dismissed. By flip 1103
the following composite is a dark grey surface with black rectangular UI
artifacts, not a recognizable complete title menu. The deferred UI anchor
is null in this run, so that particular presenter fallback is not retaining
the old notice. Resolving the remaining scene/composite failures is still
required; passing the bonus windows does not establish the 3D background.

The later capture reaches the brightness setup screen, with its instruction,
slider and Cross visible over black rectangular artifacts. A remaining compute
refusal at `0x8000345d00 + 0xb14` is `S_WQM_B32` (`beeb090a`). The decoder,
scalar resource evaluator and SPIR-V translation now expand active four-bit
groups into a single destination word and update SCC, as specified by the
[RDNA 2 ISA](https://docs.amd.com/v/u/en-US/rdna2-shader-instruction-set-architecture).
CPU checks and an SDK GPU probe cover zero and nonzero masks, the captured
VCC high destination, preservation of VCC low, SCC and changing inputs.
The complete SDK smoke also passes. This removes an instruction-level refusal;
its effect on the title scene remains to be verified in the updated runner.

The UI uses reversed depth at `0x505a820000`. A partial trace at flip 934
captures the preceding packed compute fill: all 655,360 bytes of its HTILE
allocation at `0x5060b30000` are zero. DB_DEPTH_SIZE_XY and DB_HTILE_SURFACE
remain at reset, while the recovered depth extent is 3840x2160. The old
metadata expander rejects the missing pipe-alignment state, and resident
depth previously retained earlier UI rectangles across these compute clears.

Complete, uniform depth-only HTILE fills now clear matching resident Vulkan
depth images, including the formatted compute fast path, DMA and direct GPU
writes. Newly created depth attachments also recognize a complete uniform
metadata clear. This narrow case does not depend on individual metadata
swizzle addresses; partial, mixed, stencil and mip/array cases are excluded.
An SDK probe verifies initial metadata, raster depth retained across draws,
repeated zero/one clears, the captured compute kernel, DMA, and partial/mixed
guards. The complete smoke and D32 bias probe pass with clean validation.
The updated title run must establish whether this removes the UI artifacts.

The next live capture showed why the initial resident-clear path did not run:
the UI binds D32 and S8 allocations together, despite disabling stencil in
HTILE. Depth-only metadata clears now accept that packed host attachment,
transition both aspects together and preserve initialized stencil contents.
First use initializes stencil from its clear value, matching ordinary depth
attachment preparation. The SDK probe now exercises both D32 and D32+S8 and
checks that repeated CPU, compute and DMA depth clears retain a distinct
stencil sentinel. It and the complete smoke pass with clean validation.
Live validation of this correction is pending.

The corrected packed-depth path now runs in the title: logs show repeated
zero clears of depth `0x505a820000`, using HTILE `0x5060b30000` at 3840x2160.
The following run finishes all 6042 initial resource resolves and displays
the first bonus notice. Transition and background validation remain pending.

The three visibility kernels at `0x8000196500`, `0x80001c0d00` and
`0x80001abb00` now have a bounded absolute-memory path. Their captured
instruction sites identify a root pointer table, object headers and the
168-byte records described by each header's V#. The backend snapshots these
complete ranges, retaining the guest addresses in SSBO headers. The shader
performs the original pointer arithmetic and reads; an unmapped active read
increments a checked fault counter and fails the dispatch explicitly.
Unrelated shaders retain the existing refusal. Writes, scratch and subword
FLAT operations are outside this snapshot path.

SDK probes cover scalar and vector address forms, signed offsets, overlapping
address/destination registers, unaligned reads, 4-GiB carries, relocation,
exact region bounds and fault counts. An integration probe uses the captured
three-level walk and verifies changed record addresses, count rejection and
unmapped-read rejection. Existing scalar-pointer and complete smoke probes
also pass. Isolated replays use captured state/pages plus read-only access to
the live process for remaining resources, with writes confined to the replay.
This establishes execution coverage, not a synchronized scene replay or a
rendered menu. Live integration and background output remain pending.

The first replay exposed an independent resource-analysis bug: checkpoints
inside a skipped branch inherited SGPR values from another path. In the
64-thread kernel this invented writable V# `0x8000000001`, instead of the
two 600-byte buffers named at root+112 and root+128. Checkpoints now record
only instructions actually visited by the scalar walk; skipped sites remain
unknown for reaching-definition recovery. Backward visits are captured and
loop-varying values are invalidated. Eight focused tests pass. All three
replays then complete with the corrected resource bindings, zero FLAT faults
and clean SDK validation. Scalar pointers, indirect sampled images and the
complete GPU smoke also pass.

The refusals at `0x800033db00 + 0x10cc` and `0x8000227600 + 0xa64`
encode `IMAGE_GATHER4_C_L`, not a level-zero gather. The first captured
instruction uses NSA addresses for reference, X, Y and the computed LOD.
Explicit-LOD gather forms now retain that last operand. Translation queries
the selected mip's extent, samples its four texel centers in gather order,
and applies the sampler's depth comparison to each result. This permits
comparison gathers through the ordinary scalar colour views used by compute.
Point sampling prevents filtering within/between mip levels, including with
fractional sampler LOD bounds. Sampler comparison and LOD limits accompany
direct and indirect graphics/compute bindings.

Eight focused decode/translation checks pass. The SDK GPU probe verifies two
distinct mip patterns, all eight comparison functions, ordinary gathers,
fractional/integer sampler limits, view bounds and a guest linear sampler.
The full smoke and compressed array fetch/gather suite pass with clean
validation. Live scene validation of these newly accepted kernels is pending.

The first cached-memory relaunch stopped before video or Vulkan rendering:
the main thread was suspended in `reportGuestThreadContext(1)`, called by
`drainQuietBuilderArenas` from that same guest thread's suspend point. The
recorded slot-1 thread ID matched the suspended main thread (18820).
Diagnostics now skip their calling thread instead of suspending it before
their own ResumeThread call. The direct self-sampling regression test returns
successfully; this was a diagnostic deadlock, separate from readback memory.

## Baseline before the timestamp fix

A five-minute run continues rendering after the movie, at approximately
1.5–1.6 seconds per frame. The guest clears its active movie-controller
pointer, and the renderer resumes the full graph. This is not a decoder
deadlock.

An opt-in trace at flip 600 contains 27 draws and 137 executed compute
dispatches. The captured targets contain clears and post-processing output;
no recognizable menu text or title artwork is present. The final compositor
targets are black. No indexed mesh draws were observed in this frame.

APR resolves the shader archive, English localization, `pulse.sprig`, initial
sound resources and `v_splash_america.bsf`. The observed run never resolves
`ghost_title.xpps`, `ghost_title_0_0_0.xpps` or the common UI resource package.
The next investigation should establish why the guest has not requested the
title scene before changing its rendering passes.

The game also opens an error dialog before the movie with code `0x8002004e`
(unimplemented function). Several network-service stubs return this code;
the exact originating call and its effect on the transition are not yet
established. Error-dialog requests now retain their code and user ID in the
log before the headless implementation acknowledges them.

## Targeted diagnostics

Use `PS5_TRACE=Apr,Ampr,Dialog,PlayGo` to inspect loading and platform state.
`PS5_TRACE_GRAPHICS_FRAME=600` captures one frame's passes under `out`.
Both are expensive diagnostics and should be cleared for timing runs.

Enabling `PS5_GPU_CANONICAL_ALIASES` and `PS5_GPU_DEPTH_TRANSFER` together did
not restore the menu and increased measured frame time to roughly 1.9 seconds.
These remain disabled by default.

Audible game audio remains unverified. Early ATRAC9 input matches the title's
`silence_5sec.at9` asset and correctly decodes to zero PCM; the later run that
finishes scene loading also produces nonzero PCM.
