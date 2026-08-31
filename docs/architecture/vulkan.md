# `vulkan` — host renderer foundation

[← Documentation index](../README.md) · [Project status](../project-status.md)

[`vulkan.Renderer`](../../src/vulkan/backend.zig) loads the platform Vulkan loader at
runtime, so building and testing the emulator does not require Vulkan SDK
headers or a link-time loader library. Initialization requires Vulkan 1.2 — the
minimum core version that accepts the translator's SPIR-V 1.5 modules — and
prefers a discrete device with one queue family supporting both graphics and
compute. Validation is requested for debug builds when
`VK_LAYER_KHRONOS_validation` is installed and otherwise disabled cleanly.

The renderer owns instance/device lifetime, the selected queue, a transient
command pool with reusable frame command buffers and one lifetime timeline semaphore,
host/device memory-type selection, one descriptor layout with 64 storage
buffers, separate 64-entry 2D and 3D combined sampled-image arrays, typed
storage images, a 256-set descriptor/scalar ring, a persistently mapped 128 MiB
read-only/index upload arena, its pool, persistent guest render targets, and
image/view/sampler/render-pass/framebuffer creation. It also owns bounded
LRU compute and graphics-pipeline caches plus a 1,024-entry sampled-image LRU.
When `PS5_GPU_ASYNC_PIPELINES=1`, first-use compute and graphics pipelines are created by
[`vulkan.pipeline_compiler`](../../src/vulkan/pipeline_compiler.zig), an on-demand
single-worker FIFO which serializes the shared driver cache and falls back to a
correct inline drain if the host cannot create a thread. The Vulkan-driver
cache is persisted as
`vulkan_pipeline_cache.bin` between runs; invalid, unreadable, or oversized
cache data simply falls back to an empty driver cache, so it can only affect
startup compilation time, never correctness.
`stageGuestStorageBuffer` keys coherent allocations by exact guest address and
size, with 64 slots and a 128 MiB per-range cap. Large writable ranges remain
GPU-authoritative across descriptor-slot rebinding; a real guest consumer reads
back only the requested prefix, while eviction materializes the complete dirty
range. Small buffers retain eager visibility. This removes the former
multi-megabyte upload/readback cycle from every dispatch while keeping cache and
descriptor-set growth bounded.

Guest-memory cache identity is generation-based when the embedding enables
`PS5_GPU_PAGE_TRACKER=1`. The first GPU observation then arms each writable
16 KiB guest page as
host-read-only. A native guest write fault or checked HLE write restores its
logical protection and advances the page generation, so a stable buffer or
texture reuses its resident Vulkan copy without a complete byte hash. Uploads
verify the generation again after copying; a range modified concurrently is
accepted only as a snapshot and is not cached as current.
When page tracking is unavailable, dynamic 1024×1024 single-channel Unity font
atlases retain full-payload hashing instead of the normal bounded texture
probe. This lets glyph uploads at unchanged guest addresses invalidate their
sampled-image cache entries without weakening the bounded path for large game
textures.

Graphics draws record until a real guest ordering packet, compute/readback
dependency, or VideoOut flip closes the batch. Each draw binds
an immutable descriptor set and scalar slice; read-only guest buffers and index
data receive aligned snapshots in the mapped frame arena. Vulkan objects used
by recorded commands carry the batch's retirement tick. A submit signals the
timeline semaphore once for every command-buffer prefix in that batch.
Compatibility mode immediately waits for the submitted tick;
`PS5_GPU_TIMELINE_SCHEDULER=1` instead reuses command buffers, descriptor sets,
storage-image leases, and deferred objects only after their owning tick has
completed, waiting for the oldest tick when a bounded ring fills.

`dcbBackend` adapts checked guest reads and writes plus synchronization,
draw/dispatch and flip callbacks to [`gpu.executor`](../../src/gpu/executor.zig)
without adding a Vulkan dependency to the command processor. A direct compute
packet resolves `COMPUTE_PGM`, reads
`COMPUTE_NUM_THREAD_X/Y/Z`, incrementally decodes guest code, and emits SPIR-V
1.5 from decoded instructions. `PS5_GPU_SHADER_IR=1` routes emission through
typed validation/legalization; `PS5_GPU_SSA=1` additionally enables SSA. The
backend then creates or reuses its compute pipeline, binds the active storage set and
dispatches the packet's XYZ group counts. Errors remain
visible in diagnostics, but missing compute state and selected resource or
translation gaps skip only that dispatch instead of stopping the complete
command queue. Before general translation, exact compact AGC UAV-clear kernels
execute directly against checked guest memory. They cover `R8_UINT`, `R32_UINT`,
`RGBA8_UNORM`, `RGBA8_UINT`, `RGBA16_FLOAT`, and dual `RGBA32_FLOAT` targets,
apply the inverse descriptor storage swizzle, and use the render-target/depth
tiling layout for each written texel. A separately matched bounds-checked upload
kernel copies `R8_UINT` buffers into `RGBA8_UINT` 3D images and `R16_UINT`
buffers into `R16_UINT` 3D images; linear volumes use aligned rows and
consecutive depth slices through the same texture-layout contract. General
single-sample 2D/3D `image_load`/`image_store` dispatches now stage each T# through
the same texture-layout contract, bind up to eight independently typed Vulkan
storage images, accept consecutive or NSA coordinate VGPRs, and retile writable
results into guest memory after completion.
An exact packed `RGBA8` V# clear shape operates directly on an already resident
color attachment, avoiding a full-frame storage-buffer transfer and stale
aliased image contents.
Mip, array, MSAA, compressed and partial-mask store forms remain explicit
unsupported work rather than taking a narrow fast path. Draw callbacks count
work by default. When both vertex and pixel
program registers are present,
`DRAW_INDEX_AUTO` decodes both guest programs, resolves AGC vertex resources,
lowers matching PARAM/VINTRP stage interfaces, creates or reuses a pipeline
keyed by SPIR-V and decoded graphics state, and records a Vulkan draw into the
active guest color target. Existing target bytes are detiled only when a target
first enters the cache; later draws reuse its Vulkan image. The image is tiled
back before a matching sampled-image upload or display read, at `SetFlip`, and
at CPU-visible PM4 synchronization points. This preserves guest-visible ordering
while avoiding a full-frame readback after every draw. A half-bound graphics
program fails explicitly.

[`vulkan.image_alias`](../../src/vulkan/image_alias.zig) is the common coherency
registry for colour targets, depth targets, storage images, and uploaded sampled
images. Every cached representation has a stable token, guest byte range,
storage signature, required generation, resident generation, and canonical
authority. Writes advance a monotonic generation across all overlapping ranges,
not only exact base-address matches. Compatible equal-range storage can resolve
directly; format reinterpretations and partial overlaps publish the dirty
authority and rebuild from guest memory. Canonical writer selection requires
`PS5_GPU_CANONICAL_ALIASES=1`; compatibility mode materializes all overlapping
dirty writers. Depth and stencil allocations receive
separate alias tokens even when Vulkan packs them into one attachment.

[`vulkan.image_state`](../../src/vulkan/image_state.zig) tracks layout, access mask,
pipeline stages, aspect, mip, and layer for every persistent host image. Barrier
planning is transactional: an undersized output buffer cannot partially commit
state. Repeated read-only use in one layout is free, while read/write and
write/write reuse preserves a Vulkan memory dependency even without a layout
change. Barrier elision and aspect merging require
`PS5_GPU_IMAGE_STATE_OPT=1`; compatibility mode retains conservative hazards.
Persistent colour/depth targets, sampled textures, and storage images all use
this path; swapchain and short-lived diagnostic images retain their local
presentation barriers.

Recovered vertex and fragment SGPR values are read from the mapped scalar buffer
at draw time instead of becoming SPIR-V constants. Storage-buffer shaders query
the descriptor's live word count with `OpArrayLength`, so changing streamed
addresses, values, or batch extents does not create a new shader module or
graphics-pipeline key. Indexed draws retain `INDEX_BASE`, buffer size and index
type; `DRAW_INDEX_OFFSET_2` uploads the exact 16- or 32-bit guest index range.
`enable_graphics_probe` retains the fixed-shader diagnostic only for draws with
no guest graphics programs. Compute dispatch captures scalar user data,
optionally resolves
the AGC header through the embedding callback, maps every declared
constant-buffer table entry, and associates each executable MUBUF resource SGPR
with the matching descriptor-array element. Before translation,
`scalar_provenance` executes the straight scalar prefix and checked SMEM reads;
resolved SGPRs specialize that prefix out of SPIR-V while unresolved values
still fail explicitly. The executable memory subset covers signed/unsigned
byte and short, MUBUF dword x1/x2/x3/x4 and SMEM dword up to x16, plus V# stride-based `idxen` and `offen`.
It also covers V# `add_tid` addressing and 32-bit MUBUF exchange, add/subtract,
signed/unsigned min/max and bitwise atomics. A `glc` atomic writes the old value
back to its source VGPR, and atomic target ranges participate in the same DCB
readback as stores. Swizzled descriptors use V# `index_stride` to permute each
dword address, while short loads/stores are split into byte operations so they
remain correct across both linear and swizzle-separated dword boundaries.
Dynamically unresolved SMEM and images remain explicit unsupported semantics.
For the supported fragment subset, inline 2D/3D image and sampler descriptors are
decoded from user SGPRs. Compute sampling also recovers descriptors from the
exact preceding scalar loads or the dispatch SRT after SGPR reuse. Both paths
detile into a sampled Vulkan image, transition it to shader-read layout, and bind
it through dimension-specific combined-image bindings. Cache identity includes
the guest payload hash; rewriting the same address replaces its stale image,
while descriptor SGPR addresses are excluded from scalar specialization to
avoid recompiling a pipeline for every streamed texture. Non-linear surfaces are
read once into a checked contiguous allocation and detiled in host memory,
avoiding one guest callback per texel for large streamed textures. Legacy
detiling walks macro-block rows and reuses their local offset table instead of
recomputing checked coordinates for every texel. Thick render-target volumes use
the shared 3D texture layout and upload all depth slices into a Vulkan 3D image.
MIMG lowering supports normalized two-coordinate 2D and three-coordinate 3D
sampling, explicit level-zero samples with packed offsets, the observed
four-result gather, and vertex/fragment 2D texel fetches. Compute
`image_sample_lz` retains explicit LOD 0 and NSA coordinates. Array/cube
dimensions, mip chains, compare-gather variants, and the remaining sampling
operands remain incomplete.

With `PS5_GPU_TIMELINE_SCHEDULER=1`, draw and dispatch batches continue
asynchronously until a PM4 synchronization, readback, cache-reuse, or
presentation dependency needs their timeline tick. Compatibility mode waits
after each ordered batch.
`ACQUIRE_MEM`, `RELEASE_MEM`, `WRITE_DATA`, and events consequently wait for
ordered submitted work without a device-idle drain or materializing unrelated
render targets and storage buffers. Exact-address consumers publish only the
resource range they actually need, while image reconstruction additionally
publishes dirty partial-range aliases. The executor remains responsible
for deciding whether `WAIT_REG_MEM` is satisfied and preserving its
continuation. `RELEASE_MEM` immediate 32/64-bit values and clock/counter
selections publish their exact-width result only after Vulkan work completes;
reserved data selections are rejected. Completed render targets are retained by
guest address. `SetFlip` resolves its registered VideoOut slot and sends the
matching address and dimensions to the presentation path; diagnostic captures
can still request a CPU-visible linear frame explicitly.

Compact `[gpu frame]` diagnostics report frame time, draw/dispatch/submit counts,
fence wait time, categorized upload/readback volume, GPU-resident storage,
draw/dispatch/materialization time, render-target hits, and current buffer and
texture cache sizes. Progress captures include selected later flips rather
than only the first presented image, which makes missing textures and frame-state
regressions visible during title bring-up.

When initialized with a native Win32 handle, the renderer enables
`VK_KHR_surface`, `VK_KHR_win32_surface` and `VK_KHR_swapchain`, selects a queue
that can present to that surface, and creates an RGBA8/BGRA8 FIFO swapchain. The
presentation path keeps one persistent upload buffer and acquire fence for the
swapchain lifetime. It aspect-fits the guest RGBA8 frame with nearest-neighbour
scaling. A resident render target is blitted directly to the acquired swapchain
image without a guest-memory round trip; CPU-visible frames retain the persistent
upload fallback. Both paths perform the required transfer/present layout
transitions and call `vkQueuePresentKHR`. Bursts collapse to the latest pending
frame; if no image is immediately available, that stale frame is dropped rather
than stalling guest execution on the display refresh rate.
The window owns its Win32 message loop on a dedicated host thread so a flip from
any guest pthread can use the serialized GPU submission boundary safely.

`vulkan-smoke` is an explicit hardware test rather than part of `zig build test`,
so machines without a Vulkan runtime can still build and test every module. The
probe creates a valid compute shader module and pipeline, dispatches it, copies
known words from coherent host staging through a device-local storage buffer
into coherent readback memory, inserts the required host/transfer barriers,
waits on the submitted timeline tick and compares every byte. It then submits
synthetic RDNA2 programs through the real DCB executor. The first program's
`s_load_dwordx8` fetches two V# descriptors from a guest table,
`buffer_load/store_dwordx4`
copies four dwords between descriptor-array elements, subword operations verify
unsigned and signed extension plus byte/short RMW, and a non-zero
`idxen+offen` access uses the decoded V# stride. A second four-invocation
program uses `add_tid` to select one dword per lane, runs all ten supported
`buffer_atomic_* glc` operations, and stores the final returned old value
through another add-thread-id descriptor. A third program checks swizzled load
and store addresses, including an indexed dword at physical byte 36 and a
logical short whose two bytes land at physical bytes 3 and 32. All programs run
twice, checking guest-visible writeback plus allocation and pipeline miss/hit
paths. Finally, the fixed diagnostic draw first proves the render-target path.
Synthetic vertex and fragment RDNA2 programs are then written into guest memory:
the vertex shader converts the DCB-provided vertex index, calculates three
positions and exports `POS0`; fragment variants export an MRT0 color or sample a
4×4 guest texture. Three guest draws pass through the real decoder/translator,
decoded graphics state and exact pipeline cache, render into a 64×64 guest RGBA8
target, validate its tiled writeback, execute the PM4 synchronization packets and
verify that `SetFlip` delivers the completed frame to a presentation sink.

The final image probes run an RDNA2 `image_load`/NSA `image_store` copy over a
4×4 `RGBA8_UINT` surface, including the guest's 256-byte linear row pitch,
Vulkan storage-image transitions, and guest-visible readback. A second compute
kernel samples a 4×4 `RGBA8_UNORM` texture with `image_sample_lz`, explicit LOD 0
and an NSA Y coordinate, then verifies the returned float. They can be isolated
while diagnosing image support with `PS5_IMAGE_SMOKE_ONLY=1`.

```sh
zig build vulkan-smoke
```

Run only the storage and sampled compute image probes from PowerShell:

```powershell
$env:PS5_IMAGE_SMOKE_ONLY='1'; zig build vulkan-smoke
```

```text
Vulkan 1.4.357: NVIDIA GeForce RTX 3070 Ti
device API 1.4.329, queue family 0, validation off
headless smoke passed: 1 compute dispatch, 64 staging bytes copied and verified
translated RDNA2 passed: 8 dispatches, pipelines 5/3 miss/hit, buffers 8/6 miss/hit
graphics DCB probe passed: 1 diagnostic + 3 guest draws, pipelines 3/1 miss/hit
guest RDNA2 frame passed: 1152 colored pixels in 64x64 RGBA8 target
sampled image passed: 1 guest texture upload
storage image passed: 4x4 RGBA8_UINT load/store and guest writeback
PM4 synchronization + SetFlip passed: 1 presented frame
```

The isolated image command above passes both the NSA storage writeback and
compute sampled-image checks on the current Vulkan test host. The complete
probe also passes its translated compute, guest graphics, render-target
writeback, sampled/storage image, PM4 synchronization, and `SetFlip` coverage.

The explicit window probe exercises the same swapchain sink used by live
VideoOut and keeps a generated frame visible for two seconds:

```sh
zig build vulkan-window-smoke
```

```text
Win32 Vulkan presentation passed: NVIDIA GeForce RTX 3070 Ti, 320x180 guest frame -> 960x540 swapchain
```

---
