# Parallel command processors

`game-run` enables two persistent CPU command processors by default: one for
the graphics queue and one for the compute queue. Set
`PS5_GPU_PARALLEL_COMMANDS=0` to use the serial scheduler. Library users opt in
with `QueueScheduler.parallel_commands`.

Each processor runs the existing PM4 interpreter against its queue's register
state. It can prepare up to four draw/dispatch snapshots ahead of the backend.
Each snapshot owns the complete register state and packet payload; later
register writes and indirect-buffer reuse cannot change an outstanding draw.
Snapshot allocations are reused across submissions.
Indirect register lists are read in blocks of at most 256 pairs. A backend
that cannot read the block falls back to the original per-pair reads and
preserves the valid prefix before a memory fault.

Workers copy retained command and register snapshots directly under a short
lock shared with mirrored label writes. GPU-generated command streams and live
memory still take the ordered owner path. The submission owner executes all
renderer callbacks, including live memory reads, writes, rendering, completion
notifications and flips. Calls remain FIFO within
each guest queue. Memory and synchronization operations wait for their own
callback, so indirect commands produced by a preceding dispatch are read after
that producer. A rejected command suppresses subsequent callbacks from the same
execution. All outstanding callbacks drain before submission storage is freed.
On a rejected draw, the queue restores that draw's register snapshot instead
of retaining speculative register updates from later commands.

The workers sleep between jobs. Both queue heads can advance together when
available; otherwise one processor overlaps decoding with the owner's backend
work. This does not introduce a second Vulkan queue or concurrent access to the
renderer. Public HLE submission and backend lifetime changes retain their
existing execution lock. Detaching the backend or resetting the scheduler joins
idle workers before releasing their resources. A worker startup failure falls
back to serial execution before starting either job.

Large CPU tile/detile transforms also share the existing bounded copy pool
(`PS5_GPU_COPY_WORKERS`, default four participants including the caller for
Yotei, one for other titles).
Independent macro-block rows are partitioned across the helpers; clipped
blocks, array base slices and padding retain their original addressing.
Small images, linear copies, nested calls and unavailable workers run inline.
Each transform joins before its source or destination can be reused.

During fullscreen video, a separate 16 MiB/4096-entry cache remembers whether
a covered graphics shader has non-raster effects. It validates the complete
original code on every lookup, including modifications beyond the first page.
It retains only code and an effect flag, so hidden graphics draws no longer
evict the full decoded analyses needed by compute work under the movie.
The full analysis cache retains at most 2048 programs; the later scene exceeded
the old 1024-entry limit and repeatedly rebuilt resource checkpoints.
Graphics pipeline variants share identical immutable shader words, comparing
all words before sharing and retaining ownership across pipeline eviction.
Viewport and scissor are core Vulkan dynamic state, recorded for every draw.
The pipeline cache normalizes those values and render-area extent; attachment
formats, sample count, depth/stencil, blending and the other static state remain
in the key. Changing output size or clipping therefore reuses a compatible
pipeline without retaining the preceding draw's viewport. The GPU
`--dynamic-viewport-scissor` probe checks complete pixel output across clipping,
translation and Y inversion, extent reuse, and static-state separation.
Yotei's lazy translation limits are 1024 MiB for compute and 512 MiB for graphics;
other titles retain 256 MiB each. `PS5_GPU_COMPUTE_TRANSLATION_CACHE_MIB` and
`PS5_GPU_GRAPHICS_TRANSLATION_CACHE_MIB` override these limits.
Translation caches also admit up to 4096 entries within those byte budgets;
the former 1024-entry ceiling evicted late-scene graphics translations even
while their byte budget still had room.

A live decoder alone no longer marks video as covering the scene. The override
expires after two flips without a new decoded picture, allowing gameplay to
render while the title retains a prebuffered decoder.

Command-processor reads publish the addressed GPU output when necessary instead
of waiting for all submitted work. Reads of CPU-authored memory leave unrelated
GPU commands queued. Deferred shader fault checks, release notifications,
resource reuse and actual readback retain their required completion checks.
In timeline mode, CPU writes and `WRITE_DATA` also keep unrelated work queued:
older shaders retain their owned input snapshots, while overlapping dirty storage
is published before a partial write. Imported guest allocations retain the
conservative completion wait because their readers share the CPU allocation.
Compatibility mode and end-of-pipe releases retain their completion behavior.
The experimental `PS5_GPU_DEFER_INTERNAL_RELEASES=1` queue delays noninterrupting
32-bit labels and sampled counters until a consumer reads their range or the
HLE submission completes. Its bounded FIFO preserves overlapping CP writes,
and publication failure withholds the driver's completion notification. Small
dirty compute buffers, imported memory, GCR flushes, 64-bit retirement labels
and interrupting releases retain synchronous publication. Library callers must
invoke `DcbBackend.drain_releases` before reporting submission completion when
enabling `Options.defer_internal_releases`. The mode is disabled by default.
Storage descriptors remember their cache indices when bound. Submission marks
those buffers' timeline use directly, preserving reads as well as writes without
scanning every retained buffer against every descriptor on each command.
The buffer reuse probe checks both immediate label writes and replacement of a
queued shader's input, verifying that the earlier shader reads its original bytes.
The runner also checks FLAT and sampled-image fault records at those timeline
boundaries. Compact records are copied into per-descriptor storage before the
upload ring can be reused; a completed fault remains an error, and reads of GPU
outputs and release boundaries still observe it. Reads of unrelated CPU-owned
memory leave diagnostic copies queued. Library users opt in through
`Options.defer_shader_fault_checks`. The `--deferred-flat-faults` and
`--deferred-sampled-faults` probes cover GPU-written clean/failing records,
descriptor reuse, spilled source buffers and persistent/nonpersistent mappings.

Detile descriptors retire by their exact timeline tick. The direct upload path
keeps the detiled result in device memory until its image copy completes; the
diagnostic CPU path retains a host-visible output buffer. The experimental
`PS5_GPU_DEVICE_DETILE_INPUT=1` copies tiled input into device memory before
the shader gathers from it. It is disabled by default: the extra copy was
slower in the small-texture probe and did not improve native menu frame time.
Image layout and
hazard tracking indexes images by handle, visiting only the requested image's
mip/layer cells while preserving the existing barrier rules.
The compute detiler caches up to 64 pipelines specialized for the known block
family, element size and block dimensions. Image extents, pitches, selected
slices and mip-tail offsets remain dynamic. A full cache falls back to the
generic shader without evicting in-flight variants. `--specialized-detile`
compares every texel against CPU detiling across 24 layouts, including volume
textures, mip tails and rebased array slices; `--queued-detile` covers descriptor
reuse and host/device inputs for both implementations.
Resident storage images sampled or bound read-only retain GENERAL layout with
read access. Aliases are combined before a draw/dispatch: any writable binding
preserves the write hazard regardless of descriptor order. The optional image
state optimization can then omit repeated read-to-read barriers while retaining
producer/consumer dependencies.

Storage image uploads use fresh ring slices during descriptor batches instead
of waiting to overwrite a fixed transfer buffer. GPU barriers order the image
update; the fixed buffer remains available for depth bridges and readback.
The storage reuse probe checks 64 queued updates, spill retirement and ring
wrap, including that early updates do not force submission.

`PS5_GPU_QUEUED_HOST_UPLOADS=1` additionally copies fresh slices into busy
host-visible storage buffers on the GPU. Transfer barriers preserve earlier
readers and order the replacement before later shaders; the persistent backing
and its content fingerprint still describe the same bytes. Imported guest
pages are excluded. This is opt-in pending native performance validation,
because avoiding a CPU wait adds a GPU buffer copy. The queued-upload probe
checks both backing types with changed contents, descriptor snapshots, large
and small ranges, and ring spills.

`PS5_GPU_RETAIN_STORAGE_BUFFERS=1` retains buffer ranges across descriptor-slot
changes. The runner enables retention when page tracking or buffer-content
caching is enabled. `PS5_GPU_STORAGE_BUFFER_CACHE_ENTRIES` bounds the number
of ranges (default 2048, configurable from 64 to 4096), independently of the
shader's descriptor count. `PS5_GPU_STORAGE_BUFFER_CACHE_MIB` bounds their
backings (default 4096 MiB). Allocations grow with observed demand; these limits
do not reserve their full capacity. The address index covers the maximum entry
count. `[gpu buffer cache]` reports hits, misses and evictions per sampled frame.
Recycling a large backing for
a much smaller range creates a suitably sized replacement; old GPU readers
keep their original backing until retirement. Otherwise a four-byte range can
retain a multi-megabyte allocation and prematurely fill the cache budget.
Storage images fingerprint clean native backing before copying it, and compare
the selected view's texels before uploading changes confined to padding or
other mip levels.
When the experimental device-storage budget is enabled,
`PS5_GPU_DEVICE_STORAGE_MIN_KIB` (runner default 256) keeps small metadata and
frequently read-back labels host-visible. The device-storage budget defaults to
512 MiB for Quake II and zero for other profiles. Recycling a large device
allocation for a smaller range observes the same threshold.

`PS5_GPU_REUSE_GRAPHICS_RESOURCES` enables consecutive read-only draw reuse
when a guest page-tracking epoch is available. The runner defaults it to the
page-tracker setting for any title. Pipeline state, shader bindings, input
controls and the memory epoch must still match. Resource preparation records
its actual shader-memory reads, including descriptor and AGC attribute metadata.
Adjacent snapshot checks share checked memory reads. Small upload-ring sources
are fingerprinted in ordinary CPU scratch memory before copying those exact
bytes to Vulkan. Reuse fingerprints current guest bytes without reading the
possibly write-combined upload mapping. Scratch storage grows to at most 256 KiB.
This does not add write protection to hot
CPU constant pages. Incomplete or inconsistent read transcripts, GPU writes,
temporary image leases and shader fault checks use normal resource preparation.
Already armed page watches are covered by the epoch check instead of another
byte comparison. AGC metadata conservatively pins USER_DATA for scalar-only
reuse, including optional direct pointers and inline descriptor mappings.
Mesh and lookup indexing retain their extent-boundary decisions. Shortened
vertex buffers may be reused only when the current vertex and instance bounds
fit the captured limits; current index contents are checked again.
Draw-dependent rectangle completion stays on normal preparation.
Scalar-only reuse patches entry USER_DATA in a new descriptor slot and updates
its resource descriptors in one Vulkan call. Guest completion labels and
interrupts retain their existing synchronization requirements.

Clean old storage images are collected before descriptor preparation. On a
device-memory allocation failure, old unpinned storage images are published
to guest memory and retired before shrinking the sampled texture cache. Dirty
data is never discarded, and objects already prepared for use remain pinned.
Sampled texture retention has an independent 16384-entry limit and a 2 GiB
default byte budget, configurable with `PS5_GPU_SAMPLED_IMAGE_CACHE_MIB`.
`PS5_GPU_NONLOCAL_SAMPLED_IMAGES=1` is an experiment that places new sampled
snapshots in a compatible non-device-local heap once their device cache reaches
`PS5_GPU_SAMPLED_DEVICE_CACHE_MIB` (default 3072). It preserves the optimal image
layout and format; attachments and storage images keep their existing placement.
The total sampled budget accepts up to 8192 MiB; for example, 6144 retains a
larger combined set while targeting 3072 MiB in device memory. An unavailable
or exhausted nonlocal heap falls back to device memory. Allocation-pressure
recovery retires textures from the exhausted heap, preserving prepared images
and retaining timeline protection. The mode is off by default; its native FPS
benefit is not established.

The opt-in `PS5_GPU_ASSEMBLE_MIPS=1` path copies separately produced storage
levels into a sampled mip chain. Its cache keys include source content epochs
and the actual image format. Read-only rebinding does not invalidate the chain,
but another write in the same frame does. Views preserve channel swizzles;
CPU changes and conflicting dirty buffer/attachment aliases use the existing
publication path. Sources stay pinned while allocation recovery runs.

The GPU tests cover both scheduler modes, retained indirect streams, live
labels, cross-queue release/wait, originating backend identity, bounded
lookahead, immutable snapshots, owner-thread callbacks and rejection recovery.
The Vulkan `--parallel-commands` probe compares 96 translated dispatches per
mode, including changing bindings, a blocked graphics consumer, compute release
and GPU-produced `COPY_DATA` sources. `--buffer-reuse` checks that an unrelated
CPU memory read does not flush queued GPU work.

Native frame-rate improvements must be measured separately from these
correctness checks; parallel decoding does not remove rendering work or guest
dependencies.

An exact uniform whole-buffer AGC clear can use `vkCmdFillBuffer` when a dirty
resident buffer already owns the allocation. It updates that backing in queue
order with transfer barriers and the usual timeline retirement and metadata
publication. Partial ranges, different component values and incompatible typed
descriptors retain the general shader path. `--packed-half-clears` checks queued
typed producers followed by uniform fills, alongside attachment clear cases.

Fragment DS spill allocations are scalarized only when control-flow analysis
proves every address constant and every access is a private ADDTID spill/fill.
The proof joins M0 values across branches and back edges. Dynamic addresses,
conflicting joins and other DS aliases keep the general private-array path.
Scalar slots retain undefined-before-write behavior and EXEC-masked stores.
The `--private-spills` GPU probe compares the complete image against the array
implementation, including loop-carried values and separate sparse offsets.

Experimental lowering can avoid a whole-shader block dispatcher for natural
loops with nested forward conditions when a CFG proof finds disjoint, single-entry loop intervals
with a single latch, one exit and properly nested selections. A synthetic loop
header allows guarded guest operations in the body; separate merge labels
preserve shared guest joins, breaks and continues. Nested or crossing loops,
indirect jumps and unsupported exits keep the previous lowering paths.
`--branch-loops` compares complete GPU images against the dispatcher for both
conditional and unconditional latches. The new path retains the dispatcher's
exact guest-block visit budget, including observable writes before exhaustion;
proving a loop's structure alone cannot prove its termination with guest data.
This path is disabled by default: the late Yotei scene produced `DeviceLost`
with the block budget intact. A subsequent run also failed with this path
disabled, so the failure has not been isolated to loop lowering. Small GPU
probes do not establish native stability; the established dispatcher remains
the production path.
The diagnostic `fragment_branch_loops` switch enables it for native fragment
translation comparisons. Its value participates in the translation cache key.

The diagnostic `yotei_gds_culling_gpu=true` selects Yotei's original GPU tile
culling shader, which filters HTILE depth intervals and appends packed X/Y
coordinates. Isolated reference checks cover empty, mixed, restored EXEC and
offset tile regions. Native late-scene stability remains unresolved, so the
legacy conservative CPU path stays enabled by default. Its replacement is now
gated by an exact shader hash in addition to its dispatch shape. The legacy
path fills dense linear indices; it does not reproduce depth-filtered packed
coordinates, and can therefore produce excess or incorrect downstream work.

On a host with 32-lane subgroups, a recognized fragment packed-index waterfall
uses subgroup unsigned minimum instead of reading fixed lanes 31 and 63.
The proof requires the DPP row reduction, cross-row combine, paired scalar
reads, scalar minimum and immediate overwrite of the half-minimum temporaries
and SCC. Incoming control-flow edges inside that window reject the rewrite.
A single intervening `s_waitcnt` before the scalar minimum is allowed because
it has no register side effects; the native large material shader uses this
variant. Any other intervening instruction rejects the rewrite.
The reduction uses the original values before any potentially undefined
shuffle from an inactive invocation. Other VGPR prefix values remain intact.
The renderer queries subgroup size and fragment Arithmetic support before
enabling this translation option; it is not general wave64 emulation.
`--fragment-minimum` checks uniform and varying values, triangle edges, the
optional scalar wait and loop-carried inputs.

Fragment constant-source DPP quad permutations (`0x00`, `0x55`, `0xaa`, `0xff`)
use `OpGroupNonUniformQuadBroadcast` when the device supports fragment subgroup
Quad operations. General subgroup shuffles may exclude helper invocations;
quad broadcasts preserve the neighboring fragment values needed for explicit
texture gradients at primitive edges. The source selector is constant, as
required by the SPIR-V operation. Other permutations and stages retain their
previous translation. `--fragment-quad-broadcasts` checks all four selectors
against three analytic gradients over a triangle, including its edges.

The opt-in guest page tracker exposes a write epoch so sampled-generation
queries are not reused after a native CPU store in the same frame. A writable
page whose watch has already fired returns no trusted generation until rearmed;
subsequent stores to that unprotected page need not fault. Mapping invalidation
also advances the epoch. A provider without an epoch callback is queried on
each use. This does not enable page tracking by default or add physical-alias
tracking; native validation of this mode remains outstanding.

The diagnostic `PS5_GPU_TIMESTAMPS=1` (`gpu_timestamp_profiling`) switch records a pair of Vulkan
timestamps per command-buffer slot. Results are read only when the normal
timeline permits slot reuse, without adding a fence or requesting query waits.
`gpu_timestamp_min_us` filters the log (default 1000 microseconds). Each report
names the guest programs and recording caller. Spans measure top-to-bottom GPU
latency and can overlap; summing them is not an exclusive frame-time profile.
The mode is disabled by default. `--gpu-timestamps` checks slot reuse, cancelled
recording and disabling instrumentation while preserving rendered pixels.
