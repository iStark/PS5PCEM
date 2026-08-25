# `cpu` — guest dispatcher

[← Documentation index](../README.md) · [Project status](../project-status.md)

[src/cpu/root.zig](../../src/cpu/root.zig) is the scheduling half of CPU execution. It
spawns one host worker per guest pthread, associates it with the HLE pthread
identity, carries the ready FS/TCB/DTV context and guest stack into each entry,
and completes the HLE thread only after guest execution has left that context.
Join, detach, yield, sleep, nested guest callbacks, natural-return TLS
destructors, and `scePthreadExit` propagation all use this path.

Waits use the Zig I/O futex abstraction. Wake events retain their object
sequence and cardinality, so a signal that lands between an HLE unlock and the
worker actually parking is consumed exactly once. Broadcasts remain visible to
every waiter that observed an older sequence. If the fixed key/event history is
ever saturated, the dispatcher deliberately over-wakes and lets HLE recheck the
object instead of risking a dropped wake and process deadlock.
Plain timed sleeps are separate from that object-wake epoch. On Windows they use
a private non-alertable `NtDelayExecution` deadline, so unrelated mutex/condition
wakes or a pending I/O cancellation cannot turn an audio render worker into a
full-core spin loop.

Machine execution is represented by `cpu.Bridge`. Its request includes the
entry point, six System V AMD64 integer arguments, thread identity, guest stack,
optional pre-call RSP, and complete TLS context. This boundary is intentionally
strict: POSIX hosts commonly use FS for their own TLS, while Windows x86-64
keeps the TEB under GS and leaves FS available to guest code.

`cpu.NativeBridge` implements the first direct backend for Windows x86-64. It
checks the operating system's `PF_RDWRFSGSBASE_AVAILABLE` capability before use,
validates that entry points are executable and stacks/TLS are mapped, preserves
the Win64 nonvolatile GPR and XMM registers plus MXCSR and x87 control state,
switches to the mapped guest stack, installs the guest FS base, and calls the
entry with the System V AMD64 convention. Nested guest callbacks reuse the active
guest stack below the HLE frames. A synchronous `scePthreadExit` takes a native
escape path which discards those guest frames and restores host FS/state before
the dispatcher observes `error.Interrupted`.

## Windows does not keep a guest thread pointer

Installing the FS base is not enough, because Windows does not preserve a
user-written one across a context switch. After a guest thread sleeps or blocks,
`rdfsbase` reads zero again — measured on Windows 11, a one-millisecond sleep
loses it *every single time*, and a blocking call loses it occasionally. Guest
code follows the System V convention and keeps its thread-local storage in FS, so
the first FS-relative access after the thread is rescheduled reads a near-zero
address and faults. Nothing in the guest is wrong: the host dropped a register
the guest is entitled to rely on.

This is not a condition that can be prevented, since being descheduled is
asynchronous, so it is repaired instead. The vectored handler recognises a fault
in the first page on a thread whose FS base has gone to zero, puts the base back,
and retries the instruction. Before this, a title died at whichever thread-local
access happened to follow its first sleep, which is why its crash address moved
between runs.

A genuine null dereference is not swallowed by the repair. Restoring the base
does not make that instruction succeed: it faults again, the handler sees a base
that is no longer zero, declines, and the fault is reported normally. The cost of
being wrong is one extra trip through the handler. `cpu.fs_base_restorations`
counts the repairs, because how often the host is losing state the guest depends
on is worth knowing rather than hiding.

The Windows backend also owns a first-priority vectored exception handler for
active guest execution. It claims access violations and illegal instructions
only when the faulting RIP lies inside one of the fixed guest windows; host and
HLE faults continue through the normal Windows search. A claimed fault snapshots
all general-purpose registers, access type and target address, redirects the
saved Windows context to the assembly escape path, restores host FS/register
state, and returns `error.GuestFault`. `NativeBridge.lastFault` and
`Runtime.lastNativeFault` expose that diagnostic record without reading guest
memory from inside the exception handler.

Before an illegal instruction becomes a fault record, an allocation-free
compatibility decoder tries the AMD instructions emitted for the PS5's Zen 2
CPU. `MONITORX` and `MWAITX` advance as completed wait operations, while the
immediate register forms of SSE4a `EXTRQ` and `INSERTQ` update the saved XMM
state according to AMD's six-bit length/index rules. Returning from VEH then
resumes at the following guest instruction. Unknown opcodes retain the normal
`error.GuestFault` path.

First-page null-object compatibility recovery decodes the ModRM base through
ordinary REX and VEX2/VEX3 prefixes. This covers scalar `vmovss`/`vmovsd` field
accesses generated by Unity without treating an arbitrary unmapped address as a
recoverable null object.

The bridge intentionally does not force a context change in another host
thread. Shutdown marks such an execution interrupted and observes it when guest
code returns; suspending a worker inside HLE could abandon host locks. Windows
fault containment and the first AMD compatibility handlers are now present,
but mixed guest/HLE frames do not yet have an unwind-safe import transition and
unrecognized illegal instructions still stop execution. Arbitrary `eboot.bin`
execution is therefore not safe yet. Linux and macOS need a different
FS/HLE-transition strategy because their host TLS rules differ.

GPU command submission and host audio output are functional during title
bootstrap. The live path can translate guest vertex/pixel shaders, fetch AGC
vertex attributes, sample title textures, and present multi-draw frames, though
render-state and surface-format coverage remains incomplete.

## Roadmap

1. Introduce import transition stubs with Windows unwind metadata, host-stack
   recovery, diagnostics, and platform TLS restoration.
2. Extend resumable instruction compatibility to SHA-NI and other missing Zen 2
   features when title traces demonstrate a host capability gap.
3. Add a POSIX native bridge with explicit host-TLS restoration around HLE.

---
