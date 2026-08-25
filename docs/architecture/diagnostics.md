# `diag` — explaining failures

[← Documentation index](../README.md) · [Project status](../project-status.md)

Bringing a title up produces addresses, and an address explains nothing on its
own: it depends on where modules happened to land, so the same failure reads
differently between runs. Worse, the most informative failures are exactly the
ones whose faulting address belongs to no module at all.

## Address attribution

[src/diag/symbolize.zig](../../src/diag/symbolize.zig) maps an address to the owning
module, the offset within it, and the nearest export at or below:

```
0x0000000801731565 libc.prx+0x35565 (Zb+hMspRR-o+0x25)
```

Titles ship no debug information, so an export is an anchor rather than an exact
function name — the real function may begin after it. Data exports are excluded
from anchoring, since a variable never appears in a call stack and would drag
attribution away from the code.

## Fault reports

[src/diag/fault.zig](../../src/diag/fault.zig) classifies a contained fault instead of
printing the raw exception. The case worth separating is a call through a
function pointer that was never filled in: its faulting address belongs to no
module and is therefore useless, but the return address the `call` just pushed
identifies the caller exactly.

```
guest fault: call through a null pointer
  kind        access_violation (execute)  code 0xc0000005
  rip         0x0000000000000000 <unmapped>
  called from 0x0000000801731565 libc.prx+0x35565 (Zb+hMspRR-o+0x25)
  stack scan
    0x0000000801714daa libc.prx+0x18daa (__cxa_throw+0x2aa)
    0x0000000801711e72 libc.prx+0x15e72 (_Throw_C_error+0xe2)
```

Reading guest memory during a fault report is guarded by a mapping check, so
reporting a failure cannot fault again and lose the report.

The stack listing is labelled a scan rather than a backtrace on purpose. Guest
code omits frame pointers in places, so a reliable unwind is unavailable;
keeping the stack words that land inside a loaded module recovers the call chain
in practice, at the cost of occasional stale entries.

## The title's own account

A title about to fail usually says why first, and it says it by passing a message
to something. The System V argument registers are where that message is at the
moment of the fault, so the report recovers text from the registers — following
one indirection, because a message is as often passed by reference as by value
and the register then holds the string object rather than its characters.

The filter is deliberately strict: a pointer into mapped memory nearly always
has a few printable bytes at it, and a report that offers noise as though it
were the title's words is worse than one that offers nothing. A run must be at
least eight characters, contain a letter, and end at a terminator or fill the
window — anything else merely began like text. A message longer than the window
is shown cut short, since the first lines are the ones that name the problem.

This turns a register dump into the title's explanation of what went wrong:

```
guest fault: the guest trapped on purpose, or ran what it may not
  text in registers
    [rax] "Could not allocate memory: System out of memory!
Trying to allocate: 8589934592B with 16 alignment. MemoryLabel: TempOverflow"
```

A general-protection fault is classified as a trap rather than as a memory
failure. It has no faulting address, and the host reports that absence as an
all-ones one; reading it as an address sends the reader hunting for a wild
pointer when the guest in fact executed a software interrupt on purpose, which
is how a title's own assertions stop it.

## Which of the title's code made a call

The call trace says which firmware calls a title made. It does not say which of
the title's own code made them, and once a call is seen to repeat thousands of
times that is the only question left. `PS5_STACK_AT=<entry point>[:<call
number>]` arms a one-shot snapshot of the guest stack at one call, printed with
the fault report and resolved against the loaded modules.

The snapshot is taken in the trace's entry hook, before firmware moves onto a
stack of its own — by the time an entry point's body runs, the guest stack is no
longer the one underfoot, and the caller is out of reach. It is anchored on a
local rather than on the frame address, because the frame pointer is omitted in
optimized builds and what it reports then is not the stack at all.

A call is named by entry point and occurrence rather than by position in the
trace, because a title runs on several threads: a call's position is decided
when it finishes, by which time other threads have taken numbers of their own,
so a position noted in one run does not name the same call in the next. How many
times a title has called one entry point is not subject to that.

## Firmware call trace

The failure a title reports is usually not where it went wrong. A firmware entry
point returns a plausible-looking error, the title's own runtime reacts to it,
and the process dies several frames later.

Guest code calls firmware directly through relocated jump slots, so there is no
single place to instrument. Instead [src/hle/trace.zig](../../src/hle/trace.zig)
generates a thunk per entry point at compile time, with the same signature, that
records the call and forwards it. Only the most recent calls are kept, in a
fixed ring: a title makes millions, and the last few dozen are what explain a
failure.

`PS5_TRACE=1` streams every call, while a comma-separated value limits output
to matching entry-point name fragments. `PS5_TRACE_FAILURES=1` is the practical
long-run mode: it suppresses successful calls and prints only completed signed
status failures. Trace thunks support firmware functions with up to twelve ABI
arguments.

```powershell
$env:PS5_TRACE = "sceAgcDcbSetFlip,sceKernelDlsym"
# or: $env:PS5_TRACE_FAILURES = "1"
```

```
  last 32 firmware calls (of 11412)
     11400 sceKernelAllocateMainDirectMemory(0x400000, 0x0, 0xc, ...) = 0x0
     11401 sceKernelMapDirectMemory(..., 0x400000, 0xf2, 0x10, 0x12500000, 0x0) = 0xffffffff8002000c  <- failure
     11412 sceKernelVirtualQuery(0x202500000, 0x0, ..., 0x48) = 0xffffffff8002000d  <- failure
```

Both failure conventions are marked when the entry point returns a **signed**
status: the `0x8002_00xx` kernel scheme and the POSIX `-1`. Zero is deliberately
not marked, since too many entry points return zero for success. Unsigned
returns — process-time counters, sizes, frequencies — are left unmarked even
when their bit pattern lands in the SCE error range. A few seconds of
nanoseconds is `0x80e0_2a88`; that is a legitimate counter, not a kernel error,
and labelling it `<- failure` sends bring-up after the wrong call.

This is what the tooling is for. The trace above says a title reserved a range,
allocated physical memory for it, failed to map the two together, and then wrote
to the range anyway — which is a far more useful statement than the address the
process eventually died at.

## Guest diagnostics

A runtime about to give up almost always explains itself first, through a write
to its own standard error. Guest writes to the standard streams now reach the
host directly, but the trace also retains the buffer address and length, so the
message survives even when the write itself fails:

```
  guest diagnostics
    [stderr] Terminating due to uncaught exception 'invalid argument: invalid
             argument' of type std::system_error
```

In the title's own words, which no amount of address attribution can supply.
That one line identified three separate defects at once: a synchronization
primitive that refused re-initialization, missing unwind tables that turned
every recoverable exception into a terminate, and the silenced write that hid
all of it.

---
