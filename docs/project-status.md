# Project status and compatibility

[← Documentation index](README.md) · [Project README](../README.md)

## Current status

- Native guest execution is available on Windows x86-64; inspection, decoding,
  and HLE components also build on Linux and macOS.
- Live VideoOut reaches a Vulkan swapchain, while host audio accepts decoded
  guest buffers at 48 kHz. SceAvPlayer uses FFmpeg for H.264/AAC media and
  returns synchronized NV12 video plus stereo PCM through the title's own
  allocation and file callbacks.
- Titles can save. A mounted slot becomes a writable `/savedata0`, so a game
  stores its progress through the ordinary file API and finds it again on the
  next run; the launcher groups every local slot by title ID.
- A native Windows launcher maintains a recent-game library with installed cover
  art, persists sound and input profiles, and starts `game-run` with controller,
  keyboard, or hybrid controls.
  Sony's own pads are read directly over HID, so a DualSense or DualShock 4
  works without a translation layer; the launcher reports which one it found and
  can drive its motors and light bar as a check.
- Guest vertex and pixel shaders can render sampled textures using AGC vertex
  tables, per-instruction V# mappings, `VertexIndex`, PARAM exports, and
  fragment interpolation.
- Three-dimensional scenes now reach the screen rather than only flat composited
  output. Merged NGG vertex programs translate, including fetch-shader
  continuations that end their attribute prolog with `S_SETPC_B64`. A bound
  depth allocation is a real attachment that later passes can also sample, and
  compute stages exchange typed 2D, array and 3D images between themselves.
  Fifty-six host formats are reachable, spanning the BC1–BC7 blocks, signed and
  unsigned integer and normalized channels, R16/RG16, half-float and
  `RGBA32_FLOAT`. Sampled T# views detile their mip range, including a non-zero
  base level; GPU compute detile covers 4/8/16-byte 2D and 3D standard/PRT
  surfaces, while RB+ and MSAA still fall back to the CPU. Bound stencil planes become packed depth+stencil
  attachments with the guest compare and update operations, and matching
  colour/depth sample counts 2/4/8 stay on the host image through a later
  resolve.
- Persistent render targets, large writable storage buffers, resident storage
  images, and bounded texture and pipeline caches keep frame resources on the
  GPU across draws and dispatches. Compute chains can pass typed 2D, array, and
  3D images directly to later sampled or storage bindings without an intervening
  guest-memory round trip. A bound depth allocation becomes a resident
  attachment and can be sampled by a later pass, so guest depth testing,
  depth writes, stencil test/write, and multi-sample depth reach the rasterizer.
- Vulkan work uses ordered batches and timeline-tagged lifetime tracking. The
  default compatibility profile waits for each submitted batch; the opt-in
  timeline scheduler allows multiple batches to remain in flight and waits
  only at a real readback, guest synchronization boundary, or exhausted
  reusable-resource ring.
- Compute and graphics shader-module/pipeline misses can run through an opt-in
  on-demand FIFO compiler worker. The worker is idle-free when the queue drains,
  serializes access to the shared Vulkan driver cache, and overlaps compilation
  with preparation of the emulator's bounded LRU cache entries.
- Guest image allocations share one range-based alias registry across colour
  and separate depth/stencil targets, storage images, and sampled textures. It
  can record the canonical writer and each representation's resident generation,
  chooses direct resolves only for identical storage signatures, and routes
  reinterpretations or partial overlaps through current guest memory.
- Vulkan image layout/access state is tracked per aspect, mip, and array layer.
  Color/depth attachments, sampled and storage images, transfers, resolves, and
  readbacks derive barriers from the preceding subresource use. Its opt-in
  optimization merges compatible aspects and removes redundant read-only barriers.
- Runtime shaders can pass through a common typed IR pipeline before SPIR-V:
  lowering records operands and memory metadata, validation builds basic blocks
  and reachability. The default live path emits from decoded instructions;
  `PS5_GPU_SHADER_IR=1` selects legalized IR and `PS5_GPU_SSA=1` additionally
  constructs phi/def-use state, folds constants, and runs iterative DCE.
- Long-running title execution uses a freeing, thread-safe allocator, and
  aligned Windows direct-memory ranges share 64 KiB section views. Temporary
  uploads/readbacks and 16 KiB guest pages therefore no longer accumulate as
  an ever-growing host commit charge.
- The opt-in GPU page tracker tracks 16 KiB guest pages by generation. Tracked
  writable pages are armed read-only; the first native CPU store is handled as
  an invalidation fault, restores the guest protection, and advances the page
  generation. Unchanged buffers and textures can therefore remain resident
  without hashing or uploading their complete payload every frame.
- Graphics and compute queues retain recursively referenced indirect command
  buffers and register lists, so an AGC arena can be recycled while a real
  `WAIT_REG_MEM` continuation remains blocked and later resumes in place.
- Windows guest-thread waits use an uncancelable address wait, and process
  exceptions are delivered at a safe point on the requested guest pthread with
  its own TLS and stack identity. Unity stop-the-world handshakes therefore no
  longer depend on a synthetic semaphore failure to make progress.
- Title plugins can be mapped explicitly before execution; later
  `sceKernelLoadStartModule` calls receive stable handles and
  `sceKernelDlsym` resolves readable export names inside the selected PRX.
- Unity plug-ins may also be mapped with deferred constructors, so
  `sceKernelLoadStartModule` can start them once with the title's real argument
  block instead of running them prematurely during graph initialization.
- Terminator 2D now reaches gameplay with the intended color balance, textured
  backgrounds, characters, and UI. Its publisher logo screens render exactly as
  on the console: the sprite batcher's solid fills are honored, so the logos sit
  on a clean black background instead of the sprite atlas. Direct render-target
  scanout, GPU-resident storage and bulk tiled-texture staging reduced warmed-up frames
  from roughly 208–240 ms to 22–65 ms in the current startup capture; first-use
  texture uploads remain scene-dependent.
- Jets 'n' Guns 2 now renders its animated 3840×2160 title screen, complete main
  menu, loading screen, and tutorial gameplay instead of a black framebuffer.
  The complete ordered final pass without an explicit color target is retained
  until VideoOut supplies the scanout target.
  Recovered graphics SGPR values and live storage-buffer bounds are supplied as
  runtime data, so changing sprite batches no longer generates dozens of new
  vertex pipelines per frame. After warm-up, pipeline misses fall to zero and
  the observed 53-draw startup frames take roughly 113–124 ms on the current
  RTX 3070 Ti test host, down from approximately 1–1.8 seconds before the
  specialization fix. Firmware-default mutex handling now distinguishes the
  CRT's nested `trylock` guard from a duplicated blocking slow-path lock, so the
  decoder/output threads no longer deadlock when `START GAME` joins them.
- Asterix & Obelix: Slap Them All! now completes its Unity and PSN plug-in
  bootstrap, creates AGC shaders from four-byte-aligned headers, and reaches
  repeated 1920×1080 VideoOut frames. Its ATL intro is decoded by SceAvPlayer
  into title-owned NV12 surfaces. Synchronous AGC completion now advances the
  driver's paired CPU retirement label, removing the Unity graphics worker's
  three-second watchdog spin on every frame. Resident fullscreen copies remain
  on the GPU, and the translated guest pixel shader converts the staged NV12
  planes directly into the Vulkan render target instead of expanding and
  transferring a full RGBA frame through host memory. Completion delivery uses
  one display interval instead of a fixed 250 ms delay and coalesces equivalent
  release edges while retaining retry semantics. On the current RTX 3070 Ti
  host, the observed 48-draw gameplay cadence fell from roughly 3.1 seconds,
  then 240–250 ms and 46–49 ms, to typically 28–31 ms per frame. Frame-scoped
  command-buffer batching cuts the same workload from 52 Vulkan submissions to
  13 ordered batches; 256 descriptor/scalar slots and a persistently mapped
  read-only upload ring retain every draw's state until its fence completes.
  The final Unity compositor also retains the guest negative-height viewport as
  scanout orientation, so the scene and UI are no longer vertically inverted.
  A 3,000-flip validation run remained submission-clean and reproduced the
  gameplay shown below.
- Cat Quest III now enters its 3840×2160 Unity graphics loop and presents the
  startup splash upright. Its identity compositor uses a non-indexed procedural
  full-screen triangle rather than the previously recognized six-index quad.
  The matched resident-copy path now accepts both one-instance forms while
  retaining the existing shader, resource, format, and full-extent checks, so
  the compositor's negative-height viewport reaches scanout without matching
  ordinary textured triangles. Startup save discovery also hides interrupted
  slots that contain only firmware metadata or empty staging files. A
  reproduced `path.txt`-only settings slot previously made the title fail on a
  missing `Data.dat` and wait forever after its 13-draw startup frame; it now
  completes the search without mounting that incomplete slot and continues
  presenting frames.
- Jurassic Park Classic Games Collection now resolves the observed Font,
  FontFt, JPEG, Pad, VideoOut, Posix, and AGC driver imports, completes its
  Unity bootstrap, and reaches a stable visible 3840×2160 intro frame. Both the
  original and extended SceAvPlayer ABIs open the title's MP4 assets through
  FFmpeg. The matched movie pass accepts either NV12 plane order, recovers the
  decoder's padded row pitch, scales the 1920×1080 source into the scanout
  target, and retains the last valid image while Unity changes clips instead of
  presenting a cleared decoder surface as solid green.
- That title now leaves its intro rather than sitting on it. Its splash and
  intro clips play in sequence — gate, loop, close — with sound, and it reaches
  its menu and holds it at interactive rates. What kept it on the intro was a
  presentation that never ended: the title takes only the pictures from a movie
  and mixes its own sound, so the audio stream was never read to its end and a
  player that waited for every stream to finish stayed active forever. A
  sampler the shader assembles in registers rather than loading, and the
  instructions that assemble it, are the rest of what the menu needed. The
  alternate `IMAGE_SAMPLE_A` encoding now follows the same gradient-free sample
  semantics instead of rejecting the fragment program. Fullscreen passes also
  discard a stale undersized depth attachment before framebuffer creation; this
  removes the NVIDIA device loss that appeared when the newly translated draw
  first ran. A regression run completed more than 1,200 flips and reproduced
  the illuminated gate scene without a failed submission. No gameplay
  compatibility is claimed yet.
- The Precinct now plays both observed intro movies with synchronized video and
  audio, leaves the movie pipeline, renders its complete 1920×1080 title scene,
  and reaches the `PLAY GAME` menu and readable `NEW GAME` confirmation. Natural
  scalar loops and terminal shader branches lower to structured SPIR-V, so the
  title's artwork and UI text no longer disappear. Fixed-function
  `EliminateFastClear`, `FmaskDecompress`, and `DccDecompress` packets preserve
  the canonical resident Vulkan image instead of executing their dummy pixel
  shader as an ordinary draw; this removes the full-screen white overwrite that
  previously hid the finished scene. Holding `Triangle` now starts `NEW GAME`;
  the cold world transition completes, reaches the `Cross` prompt, and renders
  the first observed in-engine gameplay scene. Initial shader and pipeline
  compilation remains slow, and broader gameplay has not yet been validated.
- Mighty Morphin Power Rangers: Rita's Rewind now resolves its Fiber, Pad,
  offline NP, AGC 1.1, and AGC driver imports, then sustains the title's real
  1920×1080 graphics and audio loop. Native Windows fibers preserve suspended
  guest execution across `sceFiberRun`, `sceFiberSwitch`, and
  `sceFiberReturnToThread`; `scePadGetHandle` exposes the system-associated
  primary controller even when the title does not call `scePadOpen`. Its guest
  shaders use the newly decoded `V_SAD_U32`, `V_MUL_HI_I32`, and
  `V_CVT_FLR_I32_F32`, so the animated publisher sequence, menu, and post-menu
  scene render through the title's indexed VS/PS, multi-target, and sampled-image
  passes instead of the diagnostic triangle or CRT static. A narrowly matched
  CRT-composite compatibility path scales the title's 480×270 RGBA8 scene to its
  1920×1080 target while leaving the remaining post-processing chain intact.
  The observed warmed intro frames take roughly 13–20 ms on the current RTX
  3070 Ti host, with smooth audio; the heavier post-menu scene is functional but
  remains a performance target.
- PS VR2 libraries currently expose only compatibility/no-device behavior.
  VR plugins can initialize far enough to load Unity assets, but headset
  rendering, tracking, controllers, and a host OpenXR bridge do not exist yet.
- Offline bootstrap coverage now includes a fully-installed PlayGo profile and
  language/to-do queries, mount-root-aware `/app0` paths, software PNG decoding,
  save-data mount/dialog lifecycles, POSIX semaphores and pthread barriers,
  local listener sockets, sign-in and player-review dialog state, GameUpdate
  request lifecycles, conservative offline NP handles, offline telemetry
  handles, and split AJM batch jobs.
- NGS2 now preserves system/rack/voice lifecycles, parses RIFF/WAVE geometry,
  applies play/pause/resume/stop/kill events, reports 32-bit voice-state flags,
  and paces silent render grains instead of spinning a host core. The legacy
  `libSceAudiodec` lifecycle also performs real ATRAC9, MP3, and MPEG-4 AAC
  decoding; NGS2 voice mixing is still incomplete.
- AGC resource registration now reports deterministic backing-memory
  requirements and retains owner handles instead of leaving output sizes
  uninitialized. This prevents otherwise valid titles from turning stack data
  into enormous direct-memory allocation requests during renderer startup.
- Unreal Engine titles can mount multi-gigabyte PAKs, initialize ICU, load
  cooked configuration and shader archives, and emit real AGC acquire, release,
  wait, event, DMA, indirect-register, draw and flip packets. Tetris Effect:
  Connected now completes a measured startup frame containing 595 guest draws
  and 63 compute dispatches without a shader-lowering, validation, fence, or GPU
  failure. Typed 2D/3D storage images,
  bounded LDS/DS workgroup memory, `image_load`/`image_store`, sampled-image
  LOD/bias/offset and gather forms, cube coordinates and sampling, scalar
  bitfield operations, `V_LDEXP_F32`, and vertex-stage image fetches cover the
  observed startup shaders. Read-only compressed compute `image_load` uses a
  sampled BC view because Vulkan cannot expose BC images as storage images.
  Vulkan color and sampled-image formats now also preserve `R16_UNORM`,
  `R16_UINT`, and `RGBA8_UINT` typing. AGC completions remain ordered until the
  guest interrupt thread acknowledges its retirement condition, preventing the
  event-before-node race that previously stopped rendering at a nondeterministic
  flip. An unattended measured run advanced through 49 VideoOut cycles, with
  most post-bootstrap cycles taking about 3.3–3.8 seconds on the current test
  host. The next observed `0xe060`-byte generated pixel shader is now decoded
  within its exact AGC `shader_size` instead of hitting the old 4,096-instruction
  limit. The particle scene below remains the latest verified visible result;
  this is not yet a menu or gameplay claim, and synchronous GPU work is still
  much slower than real time.

### Screenshot

![Terminator 2D gameplay rendered by PS5PCEM](images/live-gameplay.png)

*A live Terminator 2D gameplay frame produced by the current guest VS/PS,
sampled-texture, render-target, and Vulkan presentation paths. Texture alpha,
component swizzles, and sRGB sampling now preserve the title's intended color
balance.*

![Jets 'n' Guns 2 tutorial gameplay rendered by PS5PCEM](images/jets-n-guns-2.png)

*A live 3840×2160 Jets 'n' Guns 2 tutorial frame reached through `START GAME`
and the title's loading screen. The ship, HUD, layered level art, lighting, and
text are produced by the guest multi-draw, sampled-texture,
persistent-render-target, compute, and VideoOut paths.*

![Asterix & Obelix: Slap Them All! gameplay rendered by PS5PCEM](images/asterix-obelix-gameplay.png)

*A live 1920×1080 Asterix & Obelix: Slap Them All! gameplay frame captured at
flip 512. The scene, characters, HUD, and prompt come from the title's guest
draws. The final fullscreen compositor remains GPU-resident, while scanout
preserves the guest viewport's vertical orientation without a per-frame
host-memory round trip.*

![Mighty Morphin Power Rangers: Rita's Rewind intro rendered by PS5PCEM](images/ritas-rewind-intro.png)

*A live 1920×1080 Rita's Rewind publisher/title intro frame produced by the
guest indexed vertex, sampled fragment, render-target composition, and VideoOut
paths. The corresponding animation and audio remain smooth in the observed
run; this is an intro milestone rather than a gameplay claim.*

![Mighty Morphin Power Rangers: Rita's Rewind post-menu scene rendered by PS5PCEM](images/ritas-rewind-post-menu.png)

*Rita's Rewind after the title menu, rendered from the real 480×270 guest scene
target and carried through the 1920×1080 CRT/post-processing chain. The strict
CRT-composite compatibility path removes the former full-screen static while
preserving the title's pixel-art presentation.*

![The Precinct title menu rendered by PS5PCEM](images/precinct-title-menu.png)

*The Precinct's live 1920×1080 title menu and `NEW GAME` confirmation, composed
by the guest graphics and compute passes after both SceAvPlayer intro movies.
Structured shader control flow restores the UI text, while fixed-function DCC
decompression no longer executes its constant-white helper shader over the
completed scene. This capture predates the now-verified transition into the
first in-engine gameplay scene.*

![Jurassic Park Classic Games Collection intro rendered by PS5PCEM](images/jurassic-park-intro.png)

*A live Jurassic Park Classic Games Collection intro frame presented from the
title's 1920×1080 NV12 movie surface through its 3840×2160 VideoOut target. The
legacy SceAvPlayer path, padded decoder pitch, Y/UV conversion, render-target
selection, and Vulkan scanout all run in the observed title process. The same
scene is now reproduced after enabling the title's alternate image-sample
encoding and rejecting its stale 1×1 depth attachment; gameplay is not claimed.*

![Tetris Effect first guest-rendered particle frame](images/tetris-effect-first-render.png)

*The first recognizable Tetris Effect render produced by the title's startup
graph: 595 guest draws and 63 compute dispatches complete without a rejected
draw. This 1920×1080 `R11G11B10_FLOAT` intermediate is converted for display
because the registered 3840×2160 VideoOut target is still black. It is an early
particle-scene milestone, not a title-screen or gameplay claim.*

### Observed title milestones

These are development captures, not compatibility ratings. They describe the
furthest repeatable point reached with legally supplied local title content;
the repository contains none of that content.

| Title | Observed milestone | Current limit |
|---|---|---|
| **Terminator 2D: No Fate** | Reaches gameplay with correct color reproduction and clean title-provided backgrounds, characters, HUD elements, and textures; publisher logo screens and menus now match the console capture; warmed-up startup frames measure 22–65 ms on the current test host | First-use texture staging and the remaining compression metadata are incomplete |
| **Pistol Whip** | Maps the native PS VR2 plugin and Burst module, then starts loading Unity asset archives | Headset, tracking, controller, and host OpenXR support are intentionally deferred |
| **Propagation: Paradise Hotel** | Mounts the 8.8 GiB UE PAK, completes ICU/config bootstrap, opens the cooked Global shader archive, creates AGC shaders, and submits the first DCB | This milestone predates the new synchronization packet constructors and needs a fresh run; VR presentation still has no host headset bridge |
| **Tetris Effect: Connected** | Completes the Unreal bootstrap and a measured startup frame with 595 guest draws and 63 compute dispatches, including typed 2D/3D storage images, `64×64×64 RGBA16_FLOAT` volumes, layered post-process targets, `RGBA32_FLOAT` exposure surfaces, a `10_10_10_2_UNORM` lookup target, and the mixed image/LDS prepass. Ordered AGC completion acknowledgement removes the intermittent retirement race, and the latest unattended run advanced through 49 VideoOut cycles. Most post-bootstrap cycles measured about 3.3–3.8 seconds on the current RTX 3070 Ti host. The first generated `0xe060`-byte material pixel shader is now decoded within its exact AGC allocation instead of the old fixed instruction ceiling | The latest verified visible output is still the recognizable 1920×1080 HDR particle target shown above. The exact registered 3840×2160 VideoOut target remains black, so presentation falls back to a converted `R11G11B10_FLOAT` intermediate. NGG/fetch-shader continuations, exact layered rendering, final scanout aliasing/tonemapping, one oversized guest-buffer descriptor, and performance remain incomplete; neither a menu nor gameplay is claimed |
| **The Precinct** | Links the complete six-image guest graph, starts Unity plug-ins through `sceKernelLoadStartModule`, indexes its audio assets, and plays both observed intro movies as synchronized 3840×2160 NV12 video and 48 kHz stereo PCM. It renders the complete 1920×1080 title artwork, opens `PLAY GAME`, and displays the readable `NEW GAME` confirmation shown above. Holding `Triangle` enters the cold world load; an earlier guarded run reached the `Cross` prompt and produced the first verified in-engine gameplay image. Target-thread exception delivery completes Unity's stop-the-world handshake, resident typed storage images preserve its compute graph, and dynamic compute scalars prevent runtime SGPR values from generating a new Vulkan pipeline every frame. Its world-load frame measures 2.1 s where it measured 5.1 s, after descriptor recovery stopped replaying each kernel's prolog once per resource it names | The first world transition still takes several minutes on the current RTX 3070 Ti test host because first-use shader translation, NVIDIA pipeline compilation, synchronous submission, and resource staging remain expensive. The former title- and shader-signature-specific NVIDIA compiler guard has been removed in favor of the general shader path, so the transition needs a fresh end-to-end validation before current gameplay compatibility is claimed |
| **Jets 'n' Guns 2** | Resolves title content through `/app0`, completes AGC resource registration, and sustains the full graphics/compute/VideoOut loop. Targetless final passes are preserved through flip, while dynamic SGPR data and descriptor-sized buffer bounds keep streamed sprite batches on stable Vulkan pipelines. `START GAME` now passes the loading screen and reaches the recognizable 3840×2160 tutorial gameplay shown above; the unattended run remained live beyond flip 300. Firmware-default mutex compatibility preserves the CRT's recursive `trylock` guard without leaking recursion into the audio workers' blocking slow path | The cold transition into the first dense gameplay scene still takes roughly 30–40 seconds on the current RTX 3070 Ti host. Once loaded, observed 227–256-draw frames take about 0.6–1.6 seconds, dominated by synchronous Vulkan submission, resource staging, and first-use work; broad input and in-game audio compatibility still need longer validation |
| **Asterix & Obelix: Slap Them All!** | Maps the Unity/PSN plug-in graph, passes GameUpdate, trophy, entitlement, WebApi, and player-review bootstrap calls, accepts four-byte-aligned AGC shader headers, and reaches repeatable 1920×1080 gameplay. SceAvPlayer returns the ATL intro as correctly decoded NV12 frames; the translated guest pixel shader converts the staged planes on the GPU, resident fullscreen copies avoid the former GPU→CPU→GPU round trip, and synchronous AGC retirement removes the three-second Unity polling timeout. Equivalent completion edges are coalesced and paced by one display interval instead of the former fixed 250 ms delay. Frame-scoped command buffers, a 256-set descriptor/scalar ring and mapped read-only/index upload snapshots reduce the observed 48-draw workload from 52 Vulkan submissions to 13. Scanout orientation follows the final compositor's negative-height viewport, keeping gameplay and UI upright. The latest 3,000-flip run remained submission-clean and reproduced gameplay at typically 28–31 ms per frame on the current RTX 3070 Ti host | Gameplay is verified through the opening forest scene. The remaining submissions preserve actual guest ordering, compute-writeback and presentation boundaries. Roughly 751 KiB of storage upload and 192 KiB of storage readback per gameplay frame, broader input/audio coverage and longer play-session stability remain targets |
| **Cat Quest III** | Enters the Unity graphics loop and presents repeated 3840×2160 startup frames. The resident identity-compositor path recognizes the title's one-instance procedural full-screen triangle as well as the existing indexed-quad form, and carries its negative-height viewport into scanout, keeping the startup splash upright | Validation currently covers startup and splash presentation only; menu progression, gameplay, input, audio, and longer-run stability are not claimed |
| **Jurassic Park Classic Games Collection** | Resolves the observed firmware graph, enters Unity, opens the splash and intro MP4 assets through both SceAvPlayer ABIs, and presents the recognizable Jurassic gate intro shown above through the title's 3840×2160 VideoOut buffers. The matched NV12 path accepts UV/Y descriptor order, derives the 2048-byte decoder pitch from the plane layout, performs the observed 2× conversion, and rejects cleared all-zero surfaces during clip changes. It leaves the intro as well: the splash and intro clips play in sequence with sound, and the title reaches its menu and holds it at interactive rates. The alternate `IMAGE_SAMPLE_A` fragment encoding now translates and executes; a general attachment-extent check prevents stale 1×1 depth state from invalidating the 3840×2160 framebuffer. The latest regression run remained submission-clean beyond flip 1,200 and reproduced the illuminated gate scene | Gameplay is not claimed. Remaining shader operations, broader menu interaction, and a longer play-session regression still need validation |
| **Mighty Morphin Power Rangers: Rita's Rewind** | Resolves the observed Fiber, Pad, offline NP, AGC 1.1, and AGC driver imports, enters a stable 1920×1080 graphics/audio loop, and renders the animated publisher sequence, title menu, and post-menu scene shown above. Native cooperative fibers retain suspended guest stacks, `scePadGetHandle` supplies a readable primary controller, and exact `V_SAD_U32`, `V_MUL_HI_I32`, and `V_CVT_FLR_I32_F32` lowering removes the diagnostic shader fallback. Holding `Cross` advances through the title prompt, and the observed intro remains smooth at roughly 13–20 ms per frame on the current RTX 3070 Ti host | The exact guest CRT composite still produces static on the current host, so a strict shader-signature fallback performs the observed 4× RGBA8 scene scale before downstream post-processing. Dense post-menu frames can contain roughly 255 draws and currently take about 470 ms, dominated by repeated guest-buffer staging; broad gameplay and input compatibility are not claimed yet |
