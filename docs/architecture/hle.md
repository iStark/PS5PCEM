# `hle` — firmware emulation

[← Documentation index](../README.md) · [Project status](../project-status.md)

Guest binaries do not ship the firmware they call into. Every import is a numeric
identifier, and the runtime is expected to supply an implementation. This module
provides that machinery and the firmware libraries built on top of it.

## Symbol identifiers

An import is an 11-character identifier derived from the export name: SHA-1 over
the name plus a fixed salt, with the first eight bytes of the digest re-encoded
in a base64 variant. [src/hle/nid.zig](../../src/hle/nid.zig) computes it.

Computing identifiers rather than hard-coding them is what makes the rest safe.
An implementation is registered under a readable name and can assert the
identifier it is expected to produce:

```zig
.{
    .name = "sceKernelAllocateDirectMemory",
    .function = abi.erase(&sceKernelAllocateDirectMemory),
    .expect_id = "rTXw65xmLIA",
}
```

A misspelled name now fails at registration. With opaque string constants it
would instead surface much later, as an import the guest cannot resolve, with
nothing to point at the cause.

The implementation is pinned by tests against published name/identifier pairs;
breaking it would break symbol resolution for every guest module.

## Symbol registry

[src/hle/symbols.zig](../../src/hle/symbols.zig) is what the dynamic linker resolves
against. A lookup is keyed on the identifier *together with* the library and
module it was requested from, plus their versions — the same identifier can be
exported by more than one library. A fallback lookup by identifier alone exists
for imports that carry no usable metadata; it is ambiguous by construction and
documented as a last resort.

## Firmware runs on a host stack

A guest calls firmware directly, so firmware executes on the calling guest
thread's stack — one megabyte, typically, because that is what the title asked
for. Host code needs far more: opening a file reserves a path buffer of tens of
kilobytes, and a compiler allocates a function's whole frame on entry, before
any branch can return early. A firmware call can therefore overrun the guest
stack *without ever reaching the code that needed the room*.

That was not a theory. Replacing one entry point's body with `return -1` left
the title running; restoring a single call into a function that merely *contains*
a path to `openFile` killed it, and raising the guest stack to eight megabytes
made the same code work again.

The overrun also lands outside every guest mapping, so the guest fault handler
declines it and the process dies with nothing to explain why.

[src/hle/host_stack.zig](../../src/hle/host_stack.zig) therefore switches to a
per-thread host stack for the duration of every call. Arguments travel through
memory rather than registers, which keeps the assembly to a single function that
knows nothing about any signature — it takes a context pointer and a target and
returns nothing, so floating-point and aggregate returns need no special
handling. Nested firmware calls stay on the stack the outer one established.

## Calling convention

Guest code is compiled for the System V AMD64 ABI. On Linux and macOS that is
also the host convention; on Windows the host uses Microsoft x64, which passes
different registers and reserves shadow space.

Every guest-callable function is therefore declared `callconv(abi.guest)`.
Omitting it on Windows still compiles — it just reads arguments from the wrong
registers, surfacing later as nonsensical parameter values. Routing the decision
through [src/hle/abi.zig](../../src/hle/abi.zig) keeps it in one place.

Off x86-64 that convention is not expressible at all, and guest code could not
run there anyway: guest binaries are x86-64 machine code executed natively, not
interpreted. Such builds fall back to the host default so the tooling still
compiles, and `abi.can_run_guest_code` records that nothing there is actually
callable from a guest.

## Implemented libraries

**`libkernel` — virtual and direct memory** ([src/hle/libs/kernel_memory.zig](../../src/hle/libs/kernel_memory.zig))

"Direct memory" is the guest's name for physical video memory. A title reserves
a physical range, then maps it into its address space; the two steps are
separate. Reservation bookkeeping covers placement, alignment, overlap
rejection, exhaustion, and release. `sceKernelMapDirectMemory` validates that
the complete physical range was reserved, translates CPU/GPU protection bits,
and either commits the exact `MAP_FIXED` address or performs an aligned first-fit
search in the user window. The resulting mapping carries its physical offset in
the central address-space table and maps the runtime's sparse shared backing
store. Multiple virtual mappings of one physical range are coherent. Releasing
a physical reservation while one of its mappings remains live returns `EBUSY`.

Two behaviours here follow from how titles actually use the API rather than from
what the calls appear to mean in isolation.

A fixed mapping into a range the title reserved earlier **commits inside the
reservation** instead of releasing it first. A title reserves a window once and
fills it in pieces, so releasing would give up its claim on everything not yet
mapped. It is also the only way that works: the host placeholder covering a
reservation has to be split for the sub-range, and releasing part of it tries to
coalesce with neighbouring free space that belongs to a different placeholder.

Physical memory is **released in whatever shape the title asks for**, not only
in the shape it was allocated. Titles routinely allocate in one arrangement and
hand memory back in another, so a release can cover part of a reservation, carve
a hole out of its middle, or span several. What the release does not cover stays
reserved. A range covering nothing reserved is still an error: it means the
title believes it owns memory it does not.

Flexible memory uses the same address-space table without inventing a second
allocator. The runtime exposes the platform-default 4 GiB budget, derives the
available amount from live `.flexible` mappings, and searches the
system-managed window from `0x02_0000_0000` before falling back to the user
window. Fixed mappings, no-overwrite mappings, encoded alignment requests,
partial unmaps, and zero-filled reuse are covered by the same lifecycle rules.

**`libkernel` — module loading** ([src/hle/modules.zig](../../src/hle/modules.zig))

A title does not reach all of its own code through the dynamic tables. Some
modules it loads itself, by path, at the point it needs them. The runtime maps
the reachable dependency graph plus any modules requested through
`PS5_PRELOAD` before guest code runs. `sceKernelLoadStartModule` then resolves a
request to that published set and returns a stable handle. Loading the same PRX
again would produce a second copy with its own relocations and duplicate state
the title expects to be shared.

Each published module retains the registration ID of its own guest exports.
`sceKernelDlsym` hashes the readable name supplied by the title and searches
only the module selected by the handle, including function, object, and
untyped exports. This prevents two Unity plugins that publish the same callback
name from aliasing each other. Truly on-demand mapping is still future work;
an unlisted late module returns `ENOENT` rather than being loaded while guest
threads are active.

Path matching ignores separator style and case. The case part is not
defensiveness: this title asks for `Il2CppUserAssemblies.prx` while shipping
`Il2cppUserAssemblies.prx`, so an exact match would refuse a module the title
installed itself. The relative path is tried before the bare file name, so two
modules sharing a name stay distinguishable.

Virtual reservations occupy guest addresses without committing host pages.
`sceKernelReserveVirtualRange` can create either a fixed or first-fit
reservation, and a later fixed flexible mapping consumes it. Memory queries use
the guest's 72-byte `VirtualQueryInfo` ABI, report half-open ranges, preserve
the original guest protection bits, and support both containing and next-range
lookups. Protection changes and names are applied to exact subranges, splitting
mapping metadata where required.

Large reservations use the system-managed window when their requested size
cannot fit below the ordinary user range; a usable hint is retained and an
aligned fallback is searched when necessary. Range validation now distinguishes
metadata-only reservations from committed readable or writable pages before an
HLE implementation dereferences a pointer. Windows CRT allocations passed by
guest libraries are accepted only after `VirtualQuery` confirms that the full
host range is committed with the required permission, preventing a reserved
placeholder from reaching a host `memcpy`.

| Export | State |
|---|---|
| `sceKernelAllocateDirectMemory` | Implemented |
| `sceKernelReleaseDirectMemory` | Implemented |
| `sceKernelGetDirectMemorySize` | Implemented |
| `sceKernelMapDirectMemory` | Implemented for fixed and searched mappings |
| `sceKernelMapFlexibleMemory` | Implemented for fixed and searched mappings |
| `sceKernelMapNamedFlexibleMemory` | Implemented, including alignment and names |
| `sceKernelMunmap` | Implemented, including partial mappings |
| `sceKernelVirtualQuery` | Implemented for containing and next-range queries |
| `sceKernelQueryMemoryProtection` | Implemented |
| `sceKernelAvailableFlexibleMemorySize` | Implemented |
| `sceKernelConfiguredFlexibleMemorySize` | Implemented |
| `sceKernelMprotect` | Implemented |
| `sceKernelSetVirtualRangeName` | Implemented |
| `sceKernelReserveVirtualRange` | Implemented for fixed and searched reservations |

**`libkernel` — pthread bootstrap and TLS** ([src/hle/libs/kernel_threading.zig](../../src/hle/libs/kernel_threading.zig))

Guest pthread and attribute handles are stable opaque pointers, matching the
firmware ABI. The manager owns their lifecycle,
copies attributes at creation, creates one TLS/TCB/DTV mapping per thread, and
reclaims it after join or detached completion. The initial process thread uses
the same path through `Runtime.prepareInitialThread`, so it does not receive a
special TLS layout.

The implemented lifecycle surface includes `create`, `join`, `detach`, `self`,
`equal`, `exit`, `yield`, `once`, and `sceKernelUsleep`, with both
`scePthread*` and POSIX spellings where the firmware exports both. Attributes
cover copy/get, stack address and size, guard size, detach state, affinity,
inherit-sched, scheduling parameters and policy, and solo scheduling. POSIX TLS
keys store values per guest thread and run guest destructors for up to the four
standard passes. POSIX wrappers return plain positive errno values; sce entry
points return kernel statuses.

Thread execution is connected through an explicit backend adapter. Every start
request contains the entry point, argument, pthread identity, scheduling hints,
a mapped guest stack with a no-access guard, and a ready `ThreadContext`
containing the guest `fs_base`. HLE code never replaces a host segment register.
The `cpu` dispatcher consumes this contract and calls its machine bridge only
across guest instruction execution. Until a dispatcher is attached, creation,
positive-duration sleep, and guest callbacks from `once` report `ENOSYS`.
`scePthreadExit` runs key destructors itself and, because its ABI returns `void`,
continues thread exit if a destructor callback fails.

**`libkernel` — pthread synchronization** ([src/hle/libs/kernel_sync.zig](../../src/hle/libs/kernel_sync.zig))

Mutexes, condition variables, reader/writer locks, and reusable pthread
barriers use stable opaque guest handles backed by host-owned records. Null
and adaptive static initializers are materialized lazily with their ABI type.
Firmware-default mutexes preserve the recursive nesting used by Gen5 CRT static
guards, while explicitly error-checking/adaptive mutexes remain strict. Mutexes
track ownership, recursive depth, type, origin, protocol metadata, and timed/try
operations. A condition wait can adopt an otherwise uncontended mutex acquired
entirely by the guest fast path, then atomically publishes itself and releases
that mutex before always reacquiring it on return, including after a timeout.
Reader/writer locks
retain per-thread reader ownership and prefer a queued writer over new readers
so writers cannot be starved indefinitely. Barriers retain their generation
across reuse, wake every participant at the threshold, and return the console's
`PTHREAD_BARRIER_SERIAL_THREAD` result to exactly one participant.

Blocking is scheduler-neutral. Every object has a monotonic sequence number;
the backend receives the number observed before parking and can therefore avoid
a lost wakeup when a signal races with the unlock-to-wait transition. Wake
requests carry the same object key, the new sequence, and either one or all as
the waiter limit. Timed waits accept relative microseconds for sce entry points
and clock-tagged absolute nanosecond deadlines for POSIX entry points. The CPU
dispatcher provides the production wait/wake path; the HLE-only fallback yields
solely so isolated unit tests can exercise state transitions.

**System-libc bootstrap ABI** ([src/hle/libs/kernel_runtime.zig](../../src/hle/libs/kernel_runtime.zig))

The genuine `libc.prx` is now the provider for its 2,922 exports instead of a
parallel HLE libc. Its 120 lower-level imports resolve through a focused
libkernel bridge plus `libSceLibcInternalExt` and `libSceSysmodule`. Data imports
such as `__stack_chk_guard` and `__progname` are registered as storage addresses,
not function stubs. Runtime hooks provide per-thread errno/TLS, clocks, sleep,
process parameters, process `argc`/`argv`, sized empty sanitizer callback
tables, and rtld callbacks. `libSceLibcInternalExt` also keeps the fixed-capacity
per-thread LIFO used by `__cxa_thread_atexit` and invokes registered guest
destructors through the current-thread callback bridge during forced TLS and
process-exit finalization.
Only anomalously long synchronous host GPU execution is excluded from the
emulated process clock while an AGC submit is active. The first 100 ms of every
submit remains visible to the guest, so ordinary multi-submit frames advance
game clocks normally; excess host translation/readback latency is hidden to
avoid false engine watchdogs on work that would be asynchronous on the console.
Owner-aware `__cxa_guard_acquire`, `release`, and `abort` handling prevents a
recursive static initializer from deadlocking the guest while preserving the
one-initializer contract. Operations whose backing subsystem is not implemented
yet return `ENOSYS` or `ENOENT` instead of reporting false success.

The Unity support PRXs also receive the small `libkernel_unity`, `libScePosix`,
RTC, system-parameter, app-content, and network-control bootstrap surface they
need to relocate. App-content temporary storage is answered by
`sceAppContentTemporaryDataMount2`, which fills a zero-terminated `/temp0`
mount point rather than returning `ENOSYS` with an untouched buffer — Unity's
temporary-file layer builds paths from that string, so leaving it uninitialised
looks like an unrelated null dereference later. This is still bootstrap
coverage, not a claim that filesystems, networking, event flags, or semaphores
are complete. POSIX `sem_init`/wait/post/destroy use the fixed kernel semaphore
store, `inet_ntop` formats IPv4/IPv6 addresses locally, and a bounded virtual
listener socket covers bind/listen/accept/name, options, select and send without
exposing the host network. Peer traffic still reports the offline state, and
`ftruncate` preserves the read-only filesystem policy. The semaphore store has
room for 1,024 entries because Unity Baselib can create more than 64 before its
first frame.

**Title bootstrap services** ([src/hle/libs/system_service.zig](../../src/hle/libs/system_service.zig),
[src/hle/libs/user_service.zig](../../src/hle/libs/user_service.zig),
[src/hle/libs/pad.zig](../../src/hle/libs/pad.zig))

The runtime exposes one stable signed-in user and one neutral connected local
controller. User login is delivered once through the service event API; later
polls report `NO_EVENT`. System preferences, safe-area and HDR defaults, the
notice-screen flag, and music-player suppression retain coherent state. System
UI actions that cannot exist without a shell return `UNAVAILABLE`.

The primary pad can be acquired through either `scePadOpen` or the
system-associated `scePadGetHandle` path. The latter is required by titles that
never explicitly open their login user's controller before polling it. Offline
NP state and reachability callback registration succeeds without fabricating a
state transition; no callback is delivered while the stable offline profile is
unchanged.

**`libSceFiber` — cooperative guest execution** ([src/hle/libs/fiber.zig](../../src/hle/libs/fiber.zig))

On Windows x86-64, each initialized guest fiber is backed by a native Windows
fiber. `sceFiberRun`, `sceFiberSwitch`, and `sceFiberReturnToThread` therefore
preserve the suspended guest registers, mixed guest/HLE call frames, stack, and
resume point instead of treating a switch as a successful no-op. The public
128-byte `SceFiber` record retains its ABI signatures, state, entry argument,
name, and caller-provided context range, while Windows owns the guarded host
stack required for safe native switching. `sceFiberGetSelf`, finalization,
cross-thread ownership checks, and runtime reset are implemented; this backend
is intentionally limited to the Windows native-execution target.

**`libSceUlt` — user-level threads** ([src/hle/libs/ult.zig](../../src/hle/libs/ult.zig))

`sceUltInitialize` and `sceUltFinalize` succeed so a title's job system can
start. Runtimes, waiting-queue and queue-data pools, mutexes, semaphores, and
queues keep host-side state keyed by the firmware objects the title allocated.
ULTs are started through the existing pthread path. Work-area size queries
return the aligned byte counts those creates expect.

Kernel user-edge event queues retain registrations and pending event payloads,
and their waits use the same sequence-aware dispatcher contract as pthread
synchronization. VideoOut filter `-13` and graphics filter `-14` use that same
queue implementation, preserving each registration's identifier and user data.
Main direct-memory allocation, named direct mappings, stack queries, and live
pthread scheduling metadata are also exposed. `sceKernelBatchMap` applies
checked direct/flexible map, unmap, and protection batches with the 32-byte PS5
entry layout used by Unreal Engine. RTC entry points provide coherent UTC/local
clocks, tick conversion, resolution, leap-year, and day-of-week results.

The APR/AMPR path now owns a read-only file registry and complete command-buffer
lifecycle: it resolves guest paths to stable IDs and sizes, records reads with
their 64-bit file offsets, continues a recorded file through gather/scatter
commands that reuse the next destination or offset, records map begin/end,
wait-on-address/counter, write-address/counter, and marker/nop packets at their
measured sizes, maps and unmaps AMM ranges into reserved guest VA on submit,
publishes write-address values on submit, submits reads
synchronously into checked guest memory, permits the short read expected at EOF,
and delivers completion through the registered AMPR event queue. A failed path resolution writes the ABI-defined
sentinels (`id = 0xffffffff`, `size = 0`, and the failing index), allowing an
engine to take its loose-file fallback without treating uninitialized memory as
a multi-gigabyte allocation. Malformed headers, oversized transfers and invalid
IDs are rejected rather than reported as successful I/O. The implementation is
in [src/hle/apr.zig](../../src/hle/apr.zig) and the guest ABI wrappers remain in
[src/hle/libs/kernel_runtime.zig](../../src/hle/libs/kernel_runtime.zig) and
[src/hle/libs/bootstrap_services.zig](../../src/hle/libs/bootstrap_services.zig).

PlayGo presents the already dumped `/app0` tree as one fully installed base
chunk. Initialize/open/close state, locus, ETA, progress, prefetch and install
speed use checked guest buffers and reject invalid handles or chunk IDs.
Language-mask and to-do-list queries describe the same already-installed local
package. This lets an offline title mount complete local content without
pretending a download service or remote entitlement exists.

SaveData exposes transaction-resource creation, persistent writable `/savedata0`
mounts, slot search, prepare/commit/unmount calls, and the immediate headless
dialog lifecycle. Camera2 consistently reports no attached camera, while Universal
Data System contexts, handles, events, and property calls form an offline
telemetry sink. RTC conversion also includes `sceRtcGetTime_t`.

**Offline network, dialogs, and headless audio**
([src/hle/libs/network.zig](../../src/hle/libs/network.zig),
[src/hle/libs/dialogs.zig](../../src/hle/libs/dialogs.zig),
[src/hle/libs/audio.zig](../../src/hle/libs/audio.zig))

Net, SSL, HTTP/HTTP2, and NP Web API preserve their normal context and request
lifecycles without opening host sockets. Local URI parsing, byte-order helpers,
the virtual listener described above, and current RTC/network ticks remain
available, while DNS and peer traffic return deterministic offline errors.
NetCtl reports a disconnected interface. Common, message, web-browser, IME,
and sign-in dialogs finish immediately with coherent headless results instead
of blocking on unavailable UI. The software `libScePngDec` implementation
parses PNG metadata and decodes non-interlaced grayscale, palette, RGB, and
RGBA images into checked guest RGBA/BGRA buffers, including scanline filters
and palette transparency. Adam7 input is recognized but not decoded yet.

AudioOut, AudioIn, and AudioOut2 expose paced ports, queues, speaker metadata,
`sceAudioOut2PortGetState` connected-primary reports, and atomic multi-port
`sceAudioOutOutputs` batches. A batch validates all ports but submits and paces
its one host-audible quantum only once; silent controller and auxiliary ports no
longer multiply the duration of the call. The WinMM device pre-rolls real PCM,
uses a one-millisecond host timer period, and re-primes after an underrun with a
short de-click fade. The ordinary reserve starts at 42 ms and grows in four-buffer
steps, up to about 170 ms, only when the running title actually starves the host
device. The measured `PPSA25872` profile starts at 128 ms because its mixer
producer can pause for roughly 100–120 ms during startup and scene work, without
imposing that initial latency on other titles. NGS2 supplies stable
system/rack/voice handles with checked parent lifetimes, parses ordinary
RIFF/WAVE geometry, walks bounded linked voice-parameter lists, applies
play/pause/resume/stop/kill events on render, reports exact 32-bit state flags,
and preserves a neutral pan matrix. Each silent float32 render grain is paced at
48 kHz, preventing a title's software-DSP worker from becoming a host busy loop;
actual NGS2 voice synthesis and mixing remain incomplete. AJM owns state per
codec instance and performs real ATRAC9 (`codec 1`) and MP3 (`codec 0`) decoding
for contiguous and split-buffer jobs. Initialize, codec-info, gapless, stream
byte counts, decoded-frame counts, and total sample sidebands are preserved.
ATRAC9 output supports signed 16-bit, signed 32-bit, float, and planar layouts.
MPEG-4 AAC (`codec 2`) decodes ADTS, raw, and SAF jobs through FAAD2, and Opus
(`codec 24`) decodes packets through libopus; unknown AJM codecs are still
rejected instead of being reported as successful silent PCM. The legacy
`libSceAudiodec` path implements library init/term, checked decoder
create/delete/reset, codec metadata, and real ATRAC9, MP3, and MPEG-4 AAC
decode through the shared codec backend. FSB-backed fallback
previews are resampled to the 48 kHz host mix, use short de-click envelopes,
and drain once. Direct fallback mixing is disabled by default because replaying
a clip beside the title's real AudioOut/AJM mix is heard as echo; it remains
available explicitly with `PS5_AUDIO_FALLBACK_MIX=1`.

[src/hle/libs/av_player.zig](../../src/hle/libs/av_player.zig) implements the
SceAvPlayer lifecycle, callback-based file input and title-owned allocations.
FFmpeg probes and decodes container media into source-resolution NV12 video and
interleaved signed 16-bit, 48 kHz stereo PCM. Video and audio have independent
locks and buffered decoder processes, playback timestamps share one monotonic
clock, pause/seek/loop/end-of-stream state is retained, and the software-decoder
ABI reports aligned pitch, allocation height, and visible crop consistently.
Both extended and legacy stream-info calls are available; current-time,
normal-speed trick mode, stream disable, and bounded media-clock advancement
cover the older Unity middleware used by Asterix without letting a long host
shader stall skip its complete intro movie.

A presentation also ends when its clock passes the duration of its source, not
only when every stream has been read to exhaustion. A stream reports its own
end when the title reads it that far, and a title is free to read one stream
and ignore the other — playing a movie for its pictures while its own mixer
owns the sound is ordinary. Waiting for both leaves such a player active for
as long as the process runs, and a title that advances when playback stops
never advances; Jurassic Park sat on its intro for exactly this reason, with
its clock ninety seconds past a three-second clip. The duration comes from the
source itself, so the answer does not depend on which streams were read. It
cannot cut a slow playback short either: while a stream is still delivering,
the reported position is bounded by the frames actually handed over, and the
clock only runs free once a stream has genuinely ended. Looping sources and
sources of unknown length are left alone.

The additional early-bootstrap surface in
[src/hle/libs/bootstrap_services.zig](../../src/hle/libs/bootstrap_services.zig)
provides conservative platform/GPU command stubs for native title
initialization. VideoOut is no longer only a headless counter: it retains
up to sixteen registered display allocations and four attribute groups,
publishes the contiguous sixteen-label ABI used by the driver, accepts the
blank `-1` flip used during startup, and delivers completed flips through the
VideoOut event-queue filter with the caller's user data. Register, change and
unregister operations are validated; CPU and EOP flips pass through the live
DCB backend, and a normal flip becomes complete only after the presentation
callback accepts the frame.

**Sound output** ([src/hle/audio_device.zig](../../src/hle/audio_device.zig))

A title hands over one buffer of samples at a time and expects the call to take
about as long as the sound lasts, because that is how it keeps time with audio.
That wait now comes from a host device making room for the next buffer rather
than from a sleep, so the clock is the real one and the samples are heard
instead of discarded. Eight buffers stay in flight: one is not enough, because
the device runs dry between finishing a buffer and the title handing over the
next. At the common 256-frame/48 kHz configuration this provides about 43 ms
of scheduling margin, enough to absorb ordinary Windows jitter and short shader
compilation stalls. Actual underruns are reported separately from device
failures, and access to the single host device is serialized across guest audio
threads.

One port is audible, because there is one pair of speakers. A title opens a main
output port and often others besides; letting each claim the device would
interleave unrelated streams. The rest keep the silent path, which is what they
had before.

Failure to open a device is never reported to the title. Having no sound card,
being denied access to one, or being refused a format are facts about the host,
not about the title, so the caller falls back to sleeping and behaves exactly as
it did before. The same applies to a device that stops working mid-run: losing
sound is not a reason to stop a title. Output is Windows-only for now; elsewhere
the ports are silent and correctly paced.

**Asynchronous file reads** ([src/hle/libs/kernel_aio.zig](../../src/hle/libs/kernel_aio.zig))

A title hands over a batch of read requests and receives an identifier; later it
asks whether that batch is done and collects the results. Engines that stream
assets do all of their loading this way, so a title built on one cannot read a
single file without it.

The reads happen where the batch is submitted, so a batch is always finished by
the time anyone asks. That is a legal outcome of the interface rather than a
shortcut around it — a caller has to cope with a request that completed at once,
because a fast device does exactly that — and the alternative, a thread pool of
our own, would invent an ordering between requests that a title could come to
depend on before there is any real device to justify it.

Writes are accepted as batches and then reported, request by request, as having
failed, with the same refusal the filesystem gives a direct write. A title told
its save was written when it was not carries on and loses it somewhere further
along, where nothing points back here. A batch naming nowhere to put an outcome
is refused before any of it runs, since finding out halfway would leave some
requests done and the caller unable to learn which.

**Title content and devices** ([src/hle/filesystem.zig](../../src/hle/filesystem.zig),
[src/hle/libs/kernel_files.zig](../../src/hle/libs/kernel_files.zig),
[src/hle/libs/kernel_ioctl.zig](../../src/hle/libs/kernel_ioctl.zig))

A title sees the directory holding its executable as `/app0`, and nothing above
it: a path that escapes the mount is refused rather than resolved against the
host, because on hardware a title cannot reach there either. The mount is
read-only, and anything that would modify it is refused rather than ignored, so
a title never proceeds believing its data was stored. Each descriptor carries
its own position and reads positionally, so two descriptors on one file cannot
disturb each other, and a descriptor closed during a read cannot have a reused
slot's position corrupted afterwards.

The mount roots themselves (`/app0`, `/hostapp`, and `/host`) stat as existing
directories. This matters independently of child lookup: managed runtimes often
verify every parent before opening a known file, and must not see a missing
`/app0` beside a successfully resolved `/app0/content.txt`.

Directories are first-class descriptors rather than failed file opens.
`sceKernelGetdents` and `sceKernelGetdirentries` emit fixed 512-byte PS5/BSD
records with stable names and types, which lets cooked engines enumerate their
content and configuration trees through the same confined `/app0` mount.

Device nodes share that namespace because that is how a title reaches them, but
they are answered here rather than from the host, which has no such devices.
`/dev/gc` is the graphics core and `/dev/dipsw` the console's mode switches.
A device is not a file: it needs no mount, since whether a game directory
happens to be attached has nothing to do with whether hardware exists; reading
or seeking one reports `ENODEV` rather than an empty file; and `stat` describes
it as the character device it is.

Control requests are decoded rather than passed through as opaque numbers. A
request code is a packed record — direction, payload length, device group and
command number — so a trace reads as `/dev/gc 0x81 #46 inout 4 bytes` instead of
`0xc004812e`, followed by the bytes that actually travelled inward. That
decoding is the specification any future implementation has to satisfy, and it
is what a real driver's requests are now recorded as.

What a shipped `libSceAgcDriver` asks for is documented in
[src/hle/libs/kernel_ioctl.zig](../../src/hle/libs/kernel_ioctl.zig): which request
comes first, what answering it unlocks, and — for the one whose payload looks
like a request but is not — why. It was obtained by running the driver against
this layer and reading its own diagnostics, then confirming each reading against
its machine code.

Mode-switch reads are answered as clear, which is the state of a retail console
and not an invented value; only the byte count the request itself declares is
written, through a pointer checked against the guest address space, and only up
to a bound. The device state in
[src/hle/graphics_device.zig](../../src/hle/graphics_device.zig) now retains trap
resources, compute and graphics modes, suspend queries, and the full matrix of
56 queues requested by the shipped driver. Each 64-byte queue registration is
validated by engine, family, index, ID, alignment, aperture and completion page
before the resulting queue state is published. Command `#40` now validates and
retains the tessellation-factor ring's 256-byte-aligned address and dword-sized
byte count. Command `#42` retains the two 16-bit HS offchip parameters in the
argument order recovered from the wrapper. Their exact 16-byte and 4-byte
payloads were confirmed against both the shipped driver's machine code and this
title's live requests. No unknown `/dev/gc` command remains in the observed
startup sequence; any unverified request is still refused with `ENOTTY`.

The shipped driver also relies on addresses that look like hints but are part
of its ABI. Its 2 MiB direct-memory pool remains at `0xfe0000000`, the small
`/dev/gc` aperture remains at `0xfe0200000`, and the AGC firmware-services table
therefore lands at the required `0xfe0040000`. Relocating either range makes the
backported library stop with its own fatal FS-table diagnostic.

**Services this machine does not have** ([src/hle/libs/services.zig](../../src/hle/libs/services.zig))

A large title links against a great deal it will run without: an online account
system, a headset, a store, a voice channel, an accelerator. A missing import
stops a module linking at all, so until each is answered the title cannot start
far enough to reach the parts that do work.

Every answer here says the facility is unavailable rather than that the call
succeeded, and that distinction is the point. A title told its request succeeded
goes looking for a result nothing produced — a session to join, a headset pose,
a file the accelerator was to have fetched — and fails somewhere with nothing
pointing back. A title told the facility is absent takes the path it already has
for a console with no network, no peripheral and no entitlement: a path its own
authors wrote and tested.

The refusal is the kernel's own "not implemented", which sits outside every
service library's numbering. Each library numbers its errors in a space of its
own, and a code invented inside one of those could be mistaken for a documented
outcome and acted upon; this one cannot be.

Library and module names are recorded separately, because they routinely differ
— a library whose name ends in a version digit usually lives in a module without
one. Binding under the wrong module leaves an import that matches on identifier
alone, which the loader rightly refuses: a bare identifier is no evidence that
this is the implementation the caller meant.

**Graphics command construction** ([src/hle/libs/agc.zig](../../src/hle/libs/agc.zig))

A title does not ask the graphics library to draw. It asks it to *write*: each
entry point appends one command to a buffer the title owns, and the buffer is
handed over later in a single submission. What these have to get right is
therefore not rendering but bookkeeping — how much room a command takes, and
that the buffer stays a walkable sequence of commands afterwards.

Unimplemented constructors write a correctly formed no-operation of the size
the real command would have taken, which is not the same as filling the space
with zeroes. Zeroes decode as a register write of one word and desynchronise the
rest of the stream. `Dispatch`, indexed and auto-indexed draws, instance state,
release/wait/event/acquire, DMA, and `SetFlip` now write real typed PM4 packets.
`SetCx/Sh/UcRegistersIndirect` emits the native Gen5
`0x9f`/`0x63`/`0x64` packets, and `SetShRegisterRangeDirect` emits an exact-size
`SET_SH_REG` packet with a matching size query, including the title's 16-word
user-data ranges. Fixed-slot commands keep a valid no-operation in their unused
tail. Shader constructors validate their AGC headers, relocate internal
pointers and program addresses, and apply the recovered program-register pairs.
Everything remains walkable through [`gpu.pm4`](../../src/gpu/pm4.zig).

`sceAgcGetRegisterDefaults2` and its internal variant expose the complete Gen5
version-10 primary/internal pointer tables instead of an all-zero placeholder.
This matters before command decoding: titles use those tables to construct the
state lists that contain color-target, viewport, shader and user-config
registers. Direct SH/UC list constructors now coalesce consecutive entries into
real register packets. Index-buffer address/count/size and indexed-offset draws
also emit typed packets whose state is retained through submission.

Patch entry points for implemented wait, release, DMA and indirect-register
commands validate the existing opcode and update its address or register count
in place; data-packet payload lookup returns the real writable body. Remaining
placeholder packets still accept harmless patches. Frame capture, submission
validation and shader debugging report themselves off, which is the retail
answer and the one that stops a title waiting for a capture nobody will take.
Resource-registration setup reports checked backing-memory requirements,
initializes the caller-owned store, exposes the maximum name length, and
allocates stable owner handles. Typed resource registration is accepted because
submission consumes the resource addresses directly; enumeration and name/type
lookup remain unimplemented, so no host-side resource database is claimed.

**GPU submission** ([src/hle/libs/agc_submit.zig](../../src/hle/libs/agc_submit.zig))

The submission entry points are where a title hands its GPU work over, and by
the time a call arrives every draw, state change and fence of a frame is already
sitting in the buffer. Intercepting it therefore yields a complete description
of a frame without modelling any of the calls that built it. Each submitted
range is checked against the guest address space and then decoded through
[`gpu.pm4`](../../src/gpu/pm4.zig), so a trace shows what was asked for rather than an
address and a length. In a batch, a null entry is skipped rather than ending the
batch, since the arrays are indexed in parallel and stopping early would drop
every buffer after a hole the title left deliberately.

The same submission enters persistent graphics/compute queues through
[`gpu.scheduler`](../../src/gpu/scheduler.zig) and
[`gpu.DcbExecutor`](../../src/gpu/executor.zig). Register state therefore survives
between buffers; label writes reach checked guest memory; acquire, release,
wait, event and flip packets become typed state. A blocked head retains its own
root DCB plus recursive snapshots of referenced command/register data and the
complete root/indirect resume path while later submissions on that queue remain
FIFO-ordered. The other queue continues, and a real release label makes the
scheduler recheck and resume the blocked stream without replaying earlier side
effects or forcing memory to a satisfying value.

The title's shipped driver uses three consecutive `/dev/gc` operations for this
path. Command `#49` has an exact 72-byte preamble layout and reports completion
through the word at byte 64. Command `#50` has a 24-byte queue-list layout whose
entries are packed 16-byte indirect-buffer descriptors; command `#51` commits
the queue through an 8-byte payload. All three result sentinels are cleared only
after their checked operation is accepted. A `#50` descriptor names the whole
reserved ring allocation rather than only its producer prefix, so the executor
stops at the driver's exact `0xffff1000` uncommitted-tail marker. Other malformed
packets are not clipped or reinterpreted as that marker.

The AGC driver's event-queue API now registers and deletes graphics filter
`-14`, decodes event type and context ID from the fields used by that filter,
and retains the caller's user data. A graphics completion is published under ID
zero; a compute completion uses its queue owner as both ID and context. Release
edges collected while a DCB is executing enter an asynchronous FIFO only after
the complete scheduler pass returns. Repeated release contexts in one pass are
coalesced because one interrupt-handler scan retires every completed ring node.
If equivalent work completes while its edge is still pending, the FIFO rearms
that entry instead of appending an unbounded duplicate. It retains the edge
until `AgcInterruptThread` signals a retirement condition and retries an event
consumed before the guest published its matching ring node. The initial and
retry windows are one 16 ms display interval rather than the former 250 ms
delay. The completion worker and host ticker share a serialized drain path, so
concurrent pumps cannot deliver or remove the same head twice. A command buffer
that remains blocked on `WAIT_REG_MEM` is deliberately not signalled early;
tracking the originating owner across a later cross-queue resume remains a
future extension.

Successful `sceAgcCreateShader` calls also retain the association between each
published GPU program address and its relocated AGC header. At draw/dispatch
time the backend can therefore capture the active stage's metadata, hardware
user-data window and exact SRT root, then resolve guest descriptors through the
same checked memory interface as indirect DCBs. Live tracing reports each
unique shader once, including its selected NGG user-data bank, scalar-prefix
stop reason and SMEM provenance, direct fetch/EUD pointers, embedded vertex
layout, four resource counts and the first resolved descriptor of each class.

Submissions are accepted rather than refused, which is the opposite of the
choice made for the graphics device, and the difference is what a caller does
with the answer. A refused device request is one whose reply the driver stores
and dereferences, so false success crashes it. A submission returns only a
status and the title is not blocked on it, so reporting failure would abort a
frame the title had already fully described — and lose the description with it.

An earlier bootstrap capture reached two submissions of 466 and 530 dwords. With
its real register constructors restored, the decoder walks 38 and 42 packets
respectively and observes one draw plus three dispatches in each. Those early
bootstrap draws do not bind a color or depth target, but their context, shader
and user-config lists reach the persistent tracker and the typed draw-state
callback without an invalid packet or a stopped queue.

### Live title bring-up (current)

On Windows, `game-run` with a full content tree attaches a Vulkan VideoOut
window, loads the reachable module graph, and feeds submitted DCBs into the
scheduler and Vulkan backend. Observed startup work now includes:

- GDS initialization and several compute dispatches (including buffer-copy
  shapes) that complete successfully when V# descriptors resolve. Exact compact
  typed image-clear kernels also update tiled guest render-target/depth memory
  without entering the incomplete general MIMG translator. The observed bounded
  buffer-to-volume kernel uploads both 1×1×1 and 16×16×16 3D images.
- Guest VS/PS translation for common RDNA2 ALU, per-vertex MUBUF fetches,
  PARAM/VINTRP interfaces, sampling, and color export. The renderer uses exact
  instruction-PC mappings when one shader SGPR addresses multiple attributes.
- AGC vertex-buffer entries supply their resolved address, stride, byte offset,
  and `VertexIndex` addressing. A diagnostic triangle is used only when guest
  vertex resources or translation remain unavailable.
- Persistent color targets accumulate multi-draw output on the GPU and defer
  detile/readback until an exact guest-memory consumer requires it. VideoOut can
  blit an exact resident target directly into the swapchain.
- A strict fragment-instruction and resource-shape matcher recognizes the
  observed Rita's Rewind CRT composite only when its two signed high multiplies,
  floor conversion, five samples, completed MRT0 export, two image bindings,
  six indices, and exact 4× RGBA8 geometry all agree. That bounded path performs
  a nearest-neighbour scene scale and then returns to the normal guest
  post-processing chain; unrelated shaders continue through Vulkan unchanged.
- Large writable guest storage buffers remain GPU-authoritative in bounded
  coherent allocations across dispatches. Small synchronization payloads and
  explicitly consumed prefixes are still published immediately, preserving the
  guest-visible ordering contract.
- Sampled images use a 32-entry content-aware LRU, and both the graphics- and
  compute-pipeline caches recycle their least-recently-used entry instead of
  dropping later work after reaching their fixed capacity. Colour attachments now recycle on the same
  terms. Refusing them once the bound was reached froze the cache on whichever
  allocations it happened to see first, so a scene working through more
  attachments than the bound had its later draws dropped and never recovered:
  Rita's Rewind reached gameplay issuing over five hundred draws a frame of
  which eighteen still found a target. A recycled attachment owes its contents
  to the guest, so it is published before it goes away and a later sample or
  flip still reads what was drawn into it.
- Scalar values a shader reads at runtime no longer become part of it. Both the
  graphics and compute paths bind them, so a title that changes a transform or a
  tint between draws reuses one pipeline instead of generating another: the
  observed Terminator 2D scene holds five graphics pipelines where it once
  accumulated thousands, and the driver's own on-disk cache becomes useful
  because the same module is presented again rather than a new one.
- Local and global data share are carried further, including the append and
  thread-id-relative `DS` operations, alongside the added `V_CVT_OFF_F32_I4` and
  the further `image_load`, `image_store` and `image_sample` forms observed in
  captures.
- A resource a shader assembles rather than loads is now recovered. A 64-bit
  scalar operation is free to name a constant, and each class of constant
  widens differently: an integer inline constant carries its sign into the
  upper word, a literal occupies only the lower one, and a float inline
  constant denotes the double it names rather than the single its encoding
  holds. Treating every constant source as unknown lost whole descriptors,
  because a sampler built from immediates in registers is made entirely of
  operations of that shape. `S_BFM_B64`, `S_BFE_U64`, `S_BITREPLICATE_B64_B32`
  and `S_WQM_B64` are evaluated rather than declared and skipped, and
  `S_BFM_B64`, `S_LSHL_B64` and `S_LSHR_B64` translate.
- `V_CVT_F32_UBYTE0` through `3` translate. Vertex colours and other
  normalized attributes arrive packed four to a dword and this is how a shader
  takes them apart; all four selectors belong together, since a program that
  unpacks a colour uses every one of them and supporting some translated
  none of them.
- `SET_BASE` is decoded, so the base an indirect draw or dispatch measures its
  arguments from is known. Indirect dispatches and the four indirect draw
  packets execute against that base: counts, instance ranges, and index
  starts are read from the argument records, and a multi packet issues each
  record in order.
- `vulkan-smoke --probe-spv` reports what the translator produced for a given
  program, which is how a module the host compiler rejects is separated from one
  the translator built wrongly.
- A rejected flip names the error that rejected it, and a refused queue
  submission records the result the driver returned. A flip that fails stops
  the command queue, so everything failing afterwards fails because of it; the
  executor that reports the stop only sees that the backend said no, which
  makes a lost device indistinguishable from a missing frame.
- Compact per-frame profiling replaces high-frequency default logging; verbose
  resource probes remain opt-in through `log_verbose_gpu`. A second profile line
  reports pipeline and shader-analysis cache behaviour alongside the time spent
  in scalar provenance, SPIR-V translation, and sampled-resource preparation.
- A rectangle list is completed into the rectangle it describes. The primitive
  hands the hardware three corners and expects the fourth to follow from them,
  which no vertex program can supply: the missing corner is a function of the
  other vertices and a vertex program sees only its own. A generated geometry
  stage is handed the whole primitive, so it emits the fourth corner and
  completes every varying by the rule that completes the position. The stage is
  built only for the draws that need it and carried in the pipeline key, and it
  is validated as SPIR-V rather than trusted: the first attempt was accepted by
  the driver and quietly produced nothing, because a float subtraction had been
  written with the integer opcode. Its effect on the observed titles has not
  been demonstrated — the diagonal half-image it was written for survives it —
  so it stands as correct handling of the primitive rather than as a fix for
  that.
- Content capture, disc mapping, content export, batched audio convolution and
  the packet builder for a hardware block this host lacks are all answered.
  Which answer each gets follows one rule: a call that sets a subsystem up or
  states a policy succeeds, because there is no result to go looking for; a
  call that would produce a result reports the real negative state where there
  is one — a streaming session that is not attached, content that is on the
  drive rather than behind a disc — and otherwise reports itself unavailable,
  because a batch that never completes would leave a title waiting forever for
  a result it was told to expect.
- A connection status is cleared across the whole block a title hands over.
  Filling only its first word left the rest holding whatever the memory held
  before, and a field read from there reads as a session detail rather than as
  the leftover it is.
- The text-entry library is answered in full: the session form beside the
  dialog form, the parameter block a title blanks before filling it in, the
  text, caret and geometry it sets on its own field, the keyboard mode, and
  both ways of asking what the panel covers. Nothing is presented, because
  there is nobody here to type, so a title receives what it would receive from
  a keyboard left alone rather than a refusal it cannot act on. What a title
  hands over describing its own display is accepted rather than rejected: that
  display is its own and is not wrong.
- The on-screen keyboard reports the screen it covers, which is none of it.
  A title asks for the panel size to lay its own text field out around the
  keyboard; this dialog never presents one, because it completes as soon as it
  is opened and there is nobody here to type. Naming a plausible-looking panel
  would push the title's interface aside to make room for a keyboard that never
  appears, so the answer matches the dialog's actual behaviour. That completes
  the library: every entry point six of the observed titles import is answered.
- `sce::Json` parses and holds documents instead of answering nothing. Every
  entry point in that library used to report an absence or an empty success, so
  a title reading its own configuration received a document with no members
  however well formed the text was. The entry points are C++ member functions,
  each receiving the title's own object as its first argument, and that object
  is left untouched: writing into it would mean assuming a layout that cannot
  be verified from here. Each live object is identified by its address and the
  document it stands for is held on this side, which is why construction, copy
  construction, assignment and destruction are honoured rather than accepted
  and ignored — a copy that did nothing would leave two names for one document
  and free it twice. The grammar is the standard's, down to `\u` escapes and
  the surrogate pairs carrying anything above the basic plane, and text the
  grammar rejects is refused rather than half read.
- `sceRtcParseRFC3339` and `sceRtcFormatRFC3339` convert between RTC ticks and
  the date-and-time strings save metadata and network services exchange. The
  grammar is fixed by the standard, so the parser accepts exactly what the
  standard allows and refuses the rest rather than guessing: a malformed date
  is an error, not an approximate instant. A zone offset moves the instant and
  not the reading, so a tick is always UTC however the text was written.
- A colour target is the memory it occupies, not every register describing how
  that memory is read. A title routinely binds one allocation twice — a
  different channel swap, a forced destination alpha, a pitch left implied
  rather than stated — and giving each binding its own host image handed one
  guest allocation two of them. The frame then split across the pair: what the
  scene pass drew was invisible to the pass that presented it, which reads as a
  black screen with a command stream that looks perfectly healthy behind it.
  Registers that change interpretation without changing storage no longer make
  a different target, while the host format and every field that changes the
  bytes still do.
- A mutex released with waiters queued is handed to one of them rather than
  thrown open to whoever asks next. Releasing it and letting everyone race
  again lets the thread that just released it win, because it is the one still
  running, so a thread that locks and unlocks in a loop holds the mutex in
  practice however long a waiter has been queued. One title left its main
  thread parked there nine hundred times in a run while a worker cycled the
  same lock.
- A vertex program that assumes the `-W..W` depth range keeps its geometry.
  Vulkan clips Z to `0..W`, so a position exported for the other convention has
  everything in front of the halfway point clipped away and everything behind it
  compressed — the near half of a scene simply missing rather than misplaced.
  The clip-space selector in `PA_CL_CLIP_CNTL` says which convention a title
  chose, and a program that chose the wider one now has its exported depth
  mapped into Vulkan's range instead of being taken literally.
- A kernel no longer pays for its own prolog once per resource it names. A
  descriptor is recovered by replaying the scalar program up to the instruction
  that uses it, and replaying it from guest memory re-read and re-decoded every
  earlier instruction every time, so a kernel naming seventy resources walked
  its prolog seventy times — and a frame running a hundred and forty of those
  dispatches paid it again for each. Replaying the already decoded program
  instead took the observed Precinct world-load frame from 2145 ms of compute
  resource preparation to 518 ms, and the frame itself from 5.1 s to 2.1 s.
- The frame profile reports texture-cache hits, misses and evictions beside the
  render-target ones. A cache at its capacity looks identical to a cache that
  fits until the hit rate is visible: the same title was suspected of thrashing
  its texture cache and turned out to miss three times in a frame of a hundred
  and thirty-four lookups, so the capacity that looked too small was left alone.
- Playing a movie no longer costs more than decoding it. Three separate habits
  were paying for the same pixels several times over: the nearest conversion ran
  once per destination pixel although neighbouring destination pixels take the
  same source pixel, the frame was magnified on the host and every copy was then
  sent across the bus, and each frame allocated and returned tens of megabytes of
  host and device memory to do it. Now each source pixel is converted once, the
  GPU performs the magnification — for a whole-number ratio its blit selects
  exactly the pixel the host loop selected — and the working buffers are
  retained. On the observed 1920×1080 movie filling a 3840×2160 target this took
  a frame from 233 ms to 15 ms, and the transfer from 32 MiB to 8 MiB.
- Decoded shader programs are held across draws instead of being walked out of
  guest memory and lowered to IR for every one, and a sampled source is content
  probed at most once per frame rather than once per draw that binds it. On a
  50-draw Terminator 2D frame those two, with a pipeline cache large enough to
  hold the title's variant set, took draw time from 167 ms to 80 ms.
- `InvalidPitch` rejections are averted by clamping decoded target pitch,
  enabling Vulkan presentation and successful `sceVideoOutSubmitEopFlip`
  completions.
- AGC `CreateShader` / `FuseShaderHalves` are taken from HLE even when a guest
  `libSceAgc` PRX is loaded, so program→header mappings stay available to the
  live GPU path. Gs/Hs front halves are accepted without a PGM pair; fuse
  patches the export (ES/LS) program to front code and keeps the front header
  for user-data / attribute-table lookup. Draws that resolve a vertex buffer
  table seed attribute V#s and run the guest export program.
- Later progress captures show title-provided logos, HUD elements, characters,
  and scene textures rather than only the initial presentation surface.
  Compression metadata and some layouts can still produce visible corruption.
- A vertex program is translated as what it is on this generation: the ES half
  of a merged NGG wave. Its vertex id arrives in V5 and its instance id in V8,
  which is what the usual `v_cndmask v0, v8, v5, s8` prolog selects between;
  seeding only the attribute-fetch VGPR left both at zero, so a program that
  computes its position from V5 placed every vertex at the same corner. The
  hardware SGPRs describing the wave are not user data and scalar provenance
  never resolves them, so they read as zero rather than rejecting the shader —
  the GS_ALLOC_REQ payload and the execution masks derived from them are
  dropped anyway, because Vulkan runs one invocation per vertex and does its
  own primitive assembly. Primitive exports are skipped for the same reason.
- Pixel-shader constants recovered from a resolved `s_buffer_load` are used as
  written, including zeros. A sprite batcher fills solid rectangles by scaling
  the sampled texel by zero and biasing the colour in, so substituting an
  identity scale for a real zero replaced the fill with the raw sprite atlas.
  The identity default now applies only to registers the scalar evaluator could
  not resolve at all.
- Colour targets that enable DCC no longer seed their resident attachment from
  the base allocation. That allocation holds compressed blocks, not texels; a
  uniform DCC key means the hardware returns the fast-clear colour, so the
  attachment starts at that colour instead of at whatever the raw bytes decode
  to. Uncompressed and mixed keys keep the staged path.
- Single-sample CMASK-only colour targets now use Oberon's exact GFX10 RB+
  `64KB_Z_X` nibble address equation. Fast-cleared (`0`) and expanded (`F`) 8×8 blocks
  can coexist in one surface: only cleared blocks take `CB_COLOR_CLEAR_WORD0`,
  while expanded blocks retain their base texels. A uniform clear avoids
  staging the base allocation entirely. Guest writes that overlap resident
  CMASK invalidate the attachment after preserving prior draws, and host
  writeback marks materialized blocks expanded so stale metadata cannot clear
  them again. MSAA/FMASK-linked CMASK states remain outside this path.
- Pipe-aligned HTILE depth targets now use Oberon's exact GFX10 RB+ pattern-21
  dword address equation, including array-slice XOR and 1×/2×/4×/8× layouts.
  Exact depth-only (`0`/`0xfffffff0`) and depth+stencil
  (`0x000000f0`/`0xfffc00f0`) fast-clear words materialize their 0.0/1.0 depth
  and zero stencil values into every sample of the swizzled base allocation,
  then become full-range expanded words. Mixed ordinary Z-range words retain
  their authoritative base texels. Overlapping guest HTILE writes invalidate
  the bounded resolve cache, and dependent CPU/texture reads resolve again.
  General HiZ range interpretation remains separate follow-up work.
- A bound depth allocation now becomes a resident Vulkan attachment, so guest
  depth testing and depth writes take effect instead of being dropped. The
  stored precision selects the attachment format exactly — `Z_16` becomes
  `D16_UNORM` and `Z_32_FLOAT` becomes `D32_SFLOAT` — and a precision with no
  counterpart is refused rather than rounded to a nearby one, because silently
  changing depth precision changes which fragments a title keeps. The guest
  compare selector and Vulkan's compare operation enumerate the same eight
  functions in the same order, so the field transfers unchanged. Depth is
  attached only when the title both binds a usable allocation and asks for the
  test, the write, or a clear; a render pass and framebuffer pair the colour and
  depth attachments and are rebuilt only when the depth allocation changes.
  A stale depth allocation smaller than the colour target is ignored because
  Vulkan requires every attachment to cover the framebuffer extent; this keeps
  fullscreen colour and UI passes valid when a title leaves 1×1 DB state bound. The
  With `PS5_GPU_DEPTH_TRANSFER=1`, single-sample `Z_16`/`Z_32_FLOAT` and optional S8 planes are detiled and
  imported on first use. `D24_UNORM_S8` expands guest Z16 to the host depth
  aspect without losing its normalized endpoints; depth and stencil copy as
  separate Vulkan aspects. An explicit guest clear still supersedes imported
  contents, while an unsupported MSAA import retains the safe first-use clear.
  A later pass that samples the same allocation is bound to the resident
  attachment rather than to a staged copy, so a depth-of-field or fog pass reads
  what the geometry actually wrote; the sampled view uses the single-channel
  format matching the stored precision. Dirty single-sample depth and stencil
  are copied to a host-visible transfer buffer and tiled back only at a guest
  visibility or eviction boundary. A bound S8 plane becomes a packed
  depth+stencil attachment, and a matching multi-sample colour target keeps the
  same sample count through resolve; multisample depth import/readback remains
  follow-up work.
- `SetFlip` and equeue delivery use VideoOut filter `-13`; flip status fills
  process-time fields and event data retains the guest flip argument.
- Indexed draws can emit AGC `SetIndexSize` as a real `INDEX_TYPE` packet, and
  deleting a vblank event now removes the corresponding VideoOut queue
  registration instead of returning placeholder success.
- SceAvPlayer now consumes media through the guest's file callbacks, invokes
  FFmpeg for container/H.264/AAC decoding, and returns double-buffered NV12 plus
  PCM from title-owned allocations. The Precinct plays both observed intro
  movies with synchronized sound; its guest YUV shader converts the 4K planes
  and the normal VideoOut path presents the movies. A PS5-compatible 16-byte
  timezone result from `sceKernelConvertLocaltimeToUtc` then lets Unity leave
  its post-video clock loop. The title's natural scalar loops and conditional
  paths with two terminal arms lower as structured SPIR-V, restoring its title
  art and menu text. `CB_COLOR_CONTROL` modes 2, 5, and 6 are consumed as
  fixed-function metadata operations instead of ordinary colour draws; because
  resident Vulkan attachments are already expanded, preserving the image is
  the correct host operation and prevents the DCC helper's constant-white
  export from erasing the scene before its compute copy. The title now reaches
  the repeatable `PLAY GAME` menu and `NEW GAME` confirmation shown above.
  Holding `Triangle` begins the world transition; target-pthread exception
  delivery and uncancelable Windows waits let Unity finish its stop-the-world
  synchronization instead of escaping through a fabricated semaphore error.
  Resident storage-image caching keeps the scene's compute products on the GPU,
  while expanded signed, integer, normalized, half-float, array, 3D, depth, LDS,
  and GDS bindings cover the newly observed kernels. Compute SGPR values now
  arrive through a dynamic scalar buffer, so changing runtime constants reuse
  the same SPIR-V module and Vulkan pipeline. An earlier bounded workaround for
  one NVIDIA compiler failure produced the first in-engine gameplay capture,
  but that title- and shader-signature-specific guard is no longer part of the
  general path. A fresh unguarded cold run is therefore required before the
  gameplay milestone is considered current; the transition remains measured in
  minutes.
- Asterix & Obelix exercises the corresponding 1920×1080 Unity movie path.
  Exact shader-shape matching handles its full-surface compute copies and
  indexed fullscreen sample blits without compiling large general pipelines;
  the planar NV12 pass converts the title-owned luma/chroma allocations into a
  persistent RGBA target, and the observed color resolve preserves the result
  through the final VideoOut copies. These paths validate dimensions, formats,
  descriptors, dispatch geometry, and instruction shape before taking the fast
  path; unmatched work continues through normal shader translation. The matched
  final compositor also carries its negative-height viewport into scanout
  metadata. Vulkan presents that resident attachment with the corresponding
  vertical orientation, and diagnostic materialization applies the same row
  order, keeping both the live window and captured gameplay upright.
- Cat Quest III emits the same identity sample compositor as a non-indexed,
  three-vertex procedural full-screen triangle. The geometry matcher accepts
  that one-instance form alongside the six-index quad; the existing exact
  fragment-shader, resource, format, and full-extent checks still gate the
  resident-copy fast path. Its negative-height viewport therefore reaches the
  scanout-orientation metadata, fixing the vertically inverted startup splash
  without treating ordinary textured triangles as full-surface copies. Save
  directory enumeration now requires at least one byte of title-owned payload
  outside `sce_sys`. This restores the transaction visibility expected from
  the platform when a prior run was interrupted after creating metadata and an
  empty file, rather than advertising that partial directory as a loadable
  slot and leaving Unity's asynchronous `FileOps` flow without a completion
  callback.
- The writable `/devlog/app/debug.log` console path is redirected to
  `out/guest-debug.log` without making `/app0` writable. Unity diagnostics can
  therefore survive startup failures while title content retains its read-only
  mount policy.

Near-null object probes in managed code
(`cmp [obj+disp], 0` with `obj == null`) are stepped past so the title can take
its null branch instead of dying after the first flip; the process now survives
past that historical crash site. Non-compare field accesses use a bounded
synthetic object recovery path; its instruction decoder now recognizes both
ordinary REX and two-/three-byte VEX memory forms used by generated Unity
floating-point setters. In the current 1920×1080 startup capture, warmed-up
frames dropped from roughly 208–240 ms to 22–65 ms: steady transfer volume fell
from about 18 MiB upload plus 26 MiB readback to about 0.9 MiB each. A first-use
64 MiB tiled texture frame fell from roughly 6.5 seconds to 0.66 seconds by
replacing per-texel guest reads with one checked bulk read. Larger scene changes
still incur first-use texture and pipeline work.

A PS VR2 Unity bring-up now maps both its native VR plugin and generated Burst
module, resolves their callbacks by module-scoped `sceKernelDlsym`, survives the
plugin's initial configuration setters, and begins loading `unity_builtin_extra`,
`sharedassets0`, `level0`, and `resources.assets`. It does not reach VR frame
submission: HMD, tracker, and VR-controller calls intentionally report no
device, and there is no host headset integration. VR compatibility is therefore
deferred until the non-VR graphics and synchronization paths are stable.

An Unreal Engine PS VR2 bring-up now reserves the larger PS5 user address
window, initializes the real system libc in inferred guest-import dependency
order, maps memory in batches, enumerates content, mounts its 8.8 GiB PAK through
APR/AMPR, and passes ICU initialization. It loads cooked configuration and the
Global shader archive, creates AGC shader objects, and submits its initial DCB.
The acquire/release/wait/event/DMA constructors that were no-operations at that
milestone now emit executable packets, so this title needs a fresh compatibility
run before its next boundary can be stated. Host VR presentation remains absent.

Jets 'n' Guns 2 constructs almost all graphics state through native
`SET_CONTEXT_REG_INDIRECT`. Its former black frame was caused upstream of that
decoder: the placeholder `sceAgcGetRegisterDefaults2` result left the guest
without the complete register templates used to build color-target state. With
the exact Gen5 version-10 defaults exposed, the title emits the required state;
the renderer then retains all targetless draws in order until VideoOut identifies
the 3840×2160 scanout allocation. Recovered graphics scalars and live descriptor
bounds are runtime data, so warmed 53-draw frames reuse the same Vulkan pipelines
and render the title screen, main menu, loading screen, and tutorial gameplay
shown above.

The former `START GAME` freeze was a synchronization deadlock. A
firmware-default mutex was treated as fully recursive for a Gen5 CRT guard, but
the same compatibility rule let `AudioOutBgM` accumulate more than a thousand
blocking self-locks. `AudioDecBgM` then waited for that mutex while
`AudioOutBgM` waited for it at a two-party barrier and the main thread joined the
output worker. Default recursive `trylock` depth is now retained only for the CRT
guard; a duplicated blocking slow-path lock is coalesced into its existing
ownership. The unattended input path subsequently passed `START GAME`, displayed
the loading frame, entered the tutorial, and continued beyond flip 300.

The first dense gameplay scene remains a performance boundary rather than a
deadlock. A cold transition currently spends roughly 30–40 seconds compiling and
submitting its first large batch on the RTX 3070 Ti test host; later observed
227–256-draw frames take approximately 0.6–1.6 seconds. A previously hard-coded
per-draw trace made this substantially worse by reading back about 6.7 GiB from
one 4K frame. That capture is now disabled during normal execution and available
only through `PS5_TRACE_GRAPHICS_FRAME`.

Tetris Effect: Connected exercises the same expanded Unreal path without a VR
plugin. It now reaches the first recognizable particle scene through the real
guest render graph. In the measured startup frame, all 595 draws and 63 compute
dispatches complete without a rejected draw, shader-lowering failure,
validation error, fence failure, or GPU fault. Ordered AGC completion delivery
now retains each release edge until the guest interrupt thread acknowledges its
retirement condition, including the event-before-ring-node race. The latest
unattended run advances through 49 VideoOut cycles instead of stopping at a
nondeterministic early flip. The renderer retains targetless final passes until
VideoOut supplies the registered display geometry, treats an all-ones screen
scissor as the unset sentinel, and preserves resident targets across the
3840×2160 post-processing chain.

The startup workload exercises typed clears and copies for `R8_UINT`,
`R16_UINT`, `R32_UINT`, `RGBA8_UNORM`, `RGBA8_UINT`, `RGBA16_UNORM`,
`RGBA16_FLOAT`, and `RGBA32_FLOAT`; mixed 2D/3D sampled and storage images;
`64×64×64` post-process volumes; and bounded LDS with DS paired, subword,
atomic, and barrier operations. Scalar `S_BFM_B32`, `S_BFE_U32`, and
`S_BFE_U64`, vector `V_LDEXP_F32`, explicit sample LOD/bias, level-zero offset
sampling, cube coordinates, four-result gathers, and vertex-stage `image_load`
cover the newly observed shader forms. Read-only BC compute loads use sampled
views because Vulkan cannot bind block-compressed formats as storage images.
The complete 176-instruction image/LDS prepass and the 2,401-instruction
compositor both translate to accepted SPIR-V rather than falling back or being
discarded. Generated shaders larger than the headerless 4,096-instruction
safety ceiling are decoded within the exact `shader_size` recorded by their AGC
allocation, stopping before embedded metadata or the following allocation.

The color path now maps native `R11G11B10_FLOAT`, `RGBA16_FLOAT`,
`RGBA32_FLOAT`, and standard-order `10_10_10_2_UNORM` attachments. Small array
targets use their requested base slice as a documented approximation until
layered Vulkan rendering is exposed; this keeps the observed luminance, bloom,
and exposure passes alive without pretending that all slices were rendered.
DCC fast clears preserve native texel widths, and packed `R11G11B10_FLOAT`
readback is converted to RGBA8 for diagnostic presentation.

The registered 3840×2160 VideoOut allocation is still opaque black at the
second flip. The screenshot above therefore comes from the newest visible
1920×1080 `R11G11B10_FLOAT` intermediate, not from the final scanout. NGG
fetch-shader programs that end their attribute prolog with `S_SETPC_B64` now
continue: PC-relative `S_GETPC_B64`/`S_ADD` jumps are CFG edges, and an AGC
fetch shader inlines at a non-`s6` SETPC while `s[6:7]` remains the hardware
exporter. The main remaining correctness work is exact layered rendering and
the final scanout alias/tonemap path. One oversized guest-buffer descriptor
also remains unresolved. Performance is still not interactive, but the old 471-second
startup-frame measurement no longer describes the current renderer: most
post-bootstrap cycles in the latest run take about 3.3–3.8 seconds on the test
RTX 3070 Ti, with occasional heavier cycles around 6.6 seconds. Synchronous GPU
work, resource staging, and submission count remain the dominant optimization
targets. A 512 GiB sparse guest reservation can still fail if the Windows
process layout leaves no suitable virtual-address hole. The particle scene is
the latest verified visible result; neither the menu nor gameplay is claimed.

## Error codes

Two numbering schemes coexist in the guest ABI, and mixing them up is a common
source of confusion. Kernel entry points return `0` or a negative status of the
form `0x8002_00xx`, where the low byte is a POSIX error number. POSIX entry
points follow C library conventions instead. [src/hle/errno.zig](../../src/hle/errno.zig)
models both and converts between them.

Note that internal APIs use Zig error sets, and translation to guest status
codes happens at the entry point. Keeping them apart stops a raw guest status
from leaking into host code where nothing would check it.

## Roadmap

1. Complete the remaining AGC command constructors, especially indirect indexed
   draws, and retain submission ownership across cross-queue asynchronous waits.
2. Extend general storage-image lowering to mip, array, MSAA, partial-mask,
   depth/stencil, atomic, and compressed-surface forms; retain exact UAV fast
   paths only where they reduce synchronous startup work without changing
   semantics.
3. Extend image sampling and storage to the remaining layer, array, MSAA,
   partial-mask, atomic, and compressed-surface forms, and cover the remaining
   indirect descriptor variants that still leave the deferred compositor with
   incomplete inputs. NGG fetch-shader `S_SETPC_B64` continuations and the
   sampled T# mip range now lower.
4. Move the remaining first-use texture conversion and synchronous compute work
   off the frame-critical path without changing guest-visible synchronization.
5. Keep the guest process in a stable long-running flip/submit loop and close
   remaining HLE or wait-loop gaps as they appear.
6. Add real HMD/tracker/controller state and a host VR bridge only after the
   ordinary VideoOut path is stable enough to support it.

---
