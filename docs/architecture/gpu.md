# `gpu` — command streams

[← Documentation index](../README.md) · [Project status](../project-status.md)

[src/gpu/pm4.zig](../../src/gpu/pm4.zig) decodes what a title actually sends to the
graphics hardware. A PS5 title does not ask a graphics API to draw: it builds
packets in its own memory — state changes, register writes, draws, dispatches,
fences — and submits the buffer. Everything the GPU ever does arrives that way,
so this stream is the real interface to emulate, and it is the same stream
whichever layer hands it over. Replacing the graphics library and emulating the
kernel device both end up holding one of these buffers, so the decoder depends
on neither choice and on nothing else in the tree.

The decoder provides legibility: a buffer of opaque words becomes a sequence of
named commands with their bodies delimited. The next layer is now executable.
[`gpu.state`](../../src/gpu/state.zig) retains context, shader, user-config and config
registers across submissions, including zero-valued writes, plus the latest
synchronization, event and flip state. [`gpu.executor`](../../src/gpu/executor.zig)
applies direct, native Gen5 and legacy AGC indirect register lists,
`ACQUIRE_MEM`, `RELEASE_MEM`, 32/64-bit `WAIT_REG_MEM`, standard and AGC
`WRITE_DATA`, `EVENT_WRITE` and `SetFlip`. An unmet wait returns `blocked` and
its exact resume word; it never changes guest memory to manufacture progress.

`INDIRECT_BUFFER` is followed recursively in both its ordinary 4-dword and
conditional 14-dword forms. Chain packets end their parent stream, conditional
packets retain the branch selected before a wait, and ordinary packets return
to the next parent command. Guest ranges are read only through the backend;
unaligned/null targets, active cycles and nesting beyond sixteen stream frames
are rejected. A blocked child returns a fixed root-to-leaf continuation, so
resuming it does not replay draws, events or memory writes before the wait.

[`gpu.scheduler`](../../src/gpu/scheduler.zig) owns separate graphics and compute FIFO
queues. It copies each root DCB and recursively snapshots reachable ordinary or
conditional indirect buffers plus native and legacy indirect register lists.
The snapshot remains readable at the original guest addresses while all other
backend operations stay live. A blocked queue head therefore retains both its
exact continuation and the payload it will consume after resuming, even if AGC
recycles the caller's arena. Later work stays behind it; work on the other queue
can still run. Once a real `RELEASE_MEM` writes the awaited label, the scheduler
rechecks guest memory and resumes the exact nested stream position before
draining the rest of the FIFO. It never fabricates a fence value to break a
wait.

[`gpu.resources`](../../src/gpu/resources.zig) turns that lossless register state into
typed GFX10 resources at the draw/dispatch boundary. It decodes 128-bit buffer
and sampler descriptors, 256-bit image descriptors, stage-relative inline
user-SGPR data, all eight color targets and the depth/stencil target. The result
retains 48-bit addresses, unified formats, views and mip ranges, component
selection, PS5 swizzle modes, MSAA state and CMASK/FMASK/DCC/HTILE metadata.
Color-target state also retains the GFX10 linear-CMASK selector so the backend
can reject an unsupported metadata layout instead of applying a tiled equation
to it.
The same snapshot now decodes viewport transforms, viewport/screen scissor
intersection, cull/front-face/polygon state, per-target blend controls and color
control, so a renderer does not need to interpret raw context-register offsets.
It also reads which depth-clip convention the title selected, because the two
conventions disagree about what a position means rather than about how it is
drawn: a guest clipping Z to `-W..W` places the near plane where Vulkan, which
clips to `0..W`, places the middle of the scene.
Snapshots allocate nothing and do not duplicate mutable GPU state: partial PM4
writes remain in the register banks and are interpreted only when work consumes
them.

[`gpu.shaders`](../../src/gpu/shaders.zig) joins those values with relocated AGC
shader metadata. It decodes the direct-resource map, EUD/SRT sizes and all four
resource-class maps without allocating, then obtains the SRT root from the
metadata-declared `ShaderResourceTable` user-SGPR pair. It does not assume
`s0:s1`. The stage snapshot supports the complete 64-word GFX10 user-data
window and keeps an NGG export program separate from the GS bank that supplies
its user data. Every metadata and descriptor-table access goes through a
checked guest-memory reader; offsets beyond `srt_size_dw` are rejected before a
read. A renderer can iterate resolved read-only/read-write images, samplers and
constant buffers through the same typed descriptors used by inline resources.

The same snapshot resolves the direct fetch-shader and extended-user-data
pointers and captures embedded vertex-buffer/vertex-attribute tables as one
checked unit. Up to 32 input semantics retain their semantic index, hardware
VGPR mapping, element flags, raw AGC attribute format, byte offset, instance
rate and decoded 128-bit V# descriptor. Attribute lookup uses the semantic byte,
not the hardware-mapping byte; incomplete table pairs and indices outside the
supported domain are rejected before any guest read.

[`gpu.scalar_provenance`](../../src/gpu/scalar_provenance.zig) initializes physical
SGPRs from that immutable user-data snapshot (at `s8` for an NGG export
program), evaluates a bounded scalar shader prefix and performs checked SMEM
loads. Graphics evaluation can walk the shader-analysis cache's already decoded
instruction stream while keeping guest data loads live, avoiding a second
fetch/decode pass for every draw. Each known value carries its user-data,
immediate, program-counter and memory roots; each load records its exact guest
address, destination range and whether it stays inside the declared SRT.
Unknown instruction lengths, unresolved branches, inaccessible memory and
invalid 48-bit addresses stop the walk explicitly instead of inventing state.
Draw/dispatch diagnostics expose this load plan together with the direct and
vertex tables, ready for the shader translator to consume.

[`gpu.shader_analysis`](../../src/gpu/shader_analysis.zig) incrementally reads only
the guest words required by the RDNA2 decoder, including literals and MIMG NSA
words. When a relocated AGC header is available, decoding is bounded by its
exact `shader_size`, so large generated material shaders can exceed the
headerless 4,096-instruction safety ceiling without reading embedded metadata
or the next allocation as code. It owns the decoded program, validated CFG and
typed IR as one diagnostic snapshot. Live submission tracing reports words,
instructions, blocks, edges and opaque IR nodes, then attempts SPIR-V lowering
for vertex, pixel and compute stages and records either the module size or the
exact blocking semantic.

[`gpu.tiling`](../../src/gpu/tiling.zig) is the API-neutral bridge from those guest
resources to host staging memory. It implements the exact GFX10 address XORs
for linear, Standard 256 B/4 KiB/64 KiB, partially-resident 64 KiB, depth Z_X
and render-target R_X layouts. `TextureLayout` extends the original one-level
`Layout` without invalidating it: up to sixteen mips are placed smallest first,
small levels share the exact 4 KiB/64 KiB mip-tail positions, and 3D resources
use thick blocks plus depth block-slices. The Oberon 16-pipe/8-packer RB+
equations include array-slice and 2x/4x/8x MSAA sample bits for both color and
depth layouts. The same contract includes exact pipe-aligned GFX10 HTILE
pattern-21 addressing: one dword per 8×8 region in a 32 KiB, 1024×512-pixel
metadata block.

Every `SubresourceLayout` exposes one checked `sourceByteOffset` consumed by CPU
tile/detile, direct `MemoryReader` staging and the Vulkan compute detile pass.
First-use uploads of large 4-byte standard 256 B/4 KiB/64 KiB (and linear)
surfaces detile on the GPU; other families keep the CPU path. Its
pointer-free `ComputeDetileKey` plus 84-byte `ComputeDetileParams` carry block,
tail, pitch, slice, sample and 64-bit buffer-offset data with a stable all-u32
layout suitable for SPIR-V scalar constants. Buffer, image, BC-block,
color-target and depth-target adapters allocate nothing and reject overflow or
short ranges. Live draw diagnostics now report family, 3D block dimensions,
sample count, mip/tail boundary and complete guest allocation size.

The executor is deliberately independent of Vulkan and guest-memory ownership.
Its backend interface supplies checked reads/writes and optional callbacks for
barriers, releases, waits, events, flips, draws and dispatches. Tests use an
in-memory backend, live AGC submission uses the identity-mapped guest address
space, and the Vulkan renderer attaches through the same draw/dispatch boundary.

Three decisions are worth stating. Body length is stored biased by one, so there
is no way to encode an empty body and a decoder that assumed otherwise would
misplace every following packet. Bounds are enforced on every step, because a
stream is read out of guest memory where a title's bug — or an address this
emulator resolved wrongly — can claim more than the buffer holds; a body that
does not fit is reported, not clipped. And only opcodes with a documented
meaning are named: an invented name in a trace is worse than a number, since a
number invites you to look it up and a wrong name does not.

Register commands carry an offset within a bank rather than an absolute index,
so the bank is recovered from the opcode before the offset means anything — two
different banks have a register at offset zero. `pm4-dump` prints a capture one
packet per line with its word offset, and counts the draws and dispatches:

```
00000: CLEAR_STATE 1 dwords
00002: SET_CONTEXT_REG context[0xa206] x2
00006: SET_SH_REG shader[0x2c0c] x1
00009: NUM_INSTANCES 1 dwords
00011: DRAW_INDEX_AUTO 2 dwords
00014: R_RELEASE_MEM 7 dwords
00021: PAD
00022: WAIT_REG_MEM 5 dwords predicated
```

## Roadmap

The shared GFX10 staging contract covers mip tails, thick 3D blocks, Oberon RB+
MSAA addressing, and compute-detile constants. Compute submissions translate
the supported RDNA2 ALU/SMEM/MUBUF/DS and storage-image paths, specialize
bounded scalar prologs, bind guest buffers and independently typed 2D/3D images,
and copy device writes back to guest memory. Graphics draws
consume decoded color targets, viewport/scissor, cull/front-face, write-mask and
blend state, then execute guest vertex/fragment SPIR-V. Render-target images are
persistent across draws and are materialized back to guest memory only before a
CPU-visible synchronization point, a dependent texture upload, or `SetFlip`.

Supported 2D and 3D image/sampler descriptors feed fragment `image_sample`, and
2D descriptors feed compute `image_sample_lz`. AGC
vertex tables provide distinct position and texture-coordinate buffers even
when the shader reuses one V# SGPR, and vertex PARAM exports now supply the
fragment interpolation inputs. `ACQUIRE_MEM`, `RELEASE_MEM`, `WAIT_REG_MEM`,
`DMA_DATA`, `WRITE_DATA`, and `EVENT_WRITE` retain checked guest ordering.
`DMA_DATA` decodes source/destination selectors, cache policy, immediate-fill
and copy forms, and routes guest-memory transfers through the renderer
boundary. `SetFlip`
resolves its VideoOut slot and buffer index, selects the cached target with the
matching guest address, and publishes the frame through an API-neutral sink.

The remaining stages are:

1. Add remaining layer views, texture component swizzles, the remaining
   compressed DCC/FMASK states, HTILE Z-range/HiZ handling, and CMASK
   states coupled to FMASK. First-use sampled uploads now detile the T#
   mip range into a Vulkan image whose mip 0 is the view's base level.
2. Indirect drawing now executes. `SET_BASE` records the argument base,
   indirect dispatches already ran against it, and `DRAW_INDIRECT` /
   `DRAW_INDEX_INDIRECT` / the `*_MULTI` forms read the same argument records
   and issue host draws. Remaining graphics work is layers, metadata, and
   first-use cost.
3. Cover the remaining explicit-LOD operands and image operations seen in
   captures. `IMAGE_SAMPLE_D` now supplies SPIR-V Grad, 1D samples a height-1
   2D view, and DPP `quad_perm` shuffles inside the quad. Irreducible control
   flow and VCC/EXEC per-lane predicates lower through a dispatcher; the
   former Jurassic Park device loss was an invalid framebuffer pairing caused
   by a stale undersized depth attachment, not shader control flow. The
   alternate gradient-free image-sample encoding is already accepted.
4. Continue reducing first-use texture work and the per-draw submission cost
   for the remaining uncompressed layer and metadata paths, and validate state
   and resource invalidation against longer title captures.

The live path is now connected end to end: AGC DCB submission executes against
the Vulkan backend, VideoOut registration identifies the requested display
allocation, and CPU, EOP and PM4 flips reach the Win32 swapchain. This is a real
game-output window, but not yet a promise of a stable game video stream. A title
will only present after its shaders, target formats, tiling and resource usage
all fit the currently supported subsets. Diagnostic shader fallbacks remain
limited to bring-up paths and are reported when selected.

---
