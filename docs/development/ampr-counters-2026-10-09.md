# AMPR counters — October 9, 2026

AMPR counter commands now execute instead of recording no-ops or writing zero.
The ordinary `sceAmprCommandBufferWriteCounterOnCompletion` and
`sceAmprCommandBufferWaitOnCounter` exports also have separate short ABI
adapters: their arguments previously used the extended `_04_00` signatures.
That could interpret unspecified guest registers as access modes or operands.

## Implemented behavior

- 128 process-local 32-bit counters, cleared at runtime reset. Selected byte
  and halfword operations preserve adjacent fields. Aligned adjacent pairs
  support 64-bit operations and coherent snapshots under the same lock.
- Store, OR, AND with complement, XOR, and wrapping addition, evaluated when
  the recorded command executes. Recording alone has no counter side effects.
- Equality, inequality, unsigned ordering, signed ordering, and wrapping
  sequence comparisons at the selected field width. Extended waits apply the
  requested mask to both the current value and the reference.
- Single-counter reads zero-extend to 64 bits. Pair reads place the lower
  counter in bits 0–31 and the next in bits 32–63. Time reads use the existing
  nanosecond `sceKernelGetProcessTimeCounter` clock at execution time.
- Counter read destinations are aligned, checked for write permission again
  at execution, and reported to guest-memory write tracking before publication.
- Counter size-query exports have matching argument lists and validation.
  The existing emulator-private 32-byte packet size is retained.

APR still completes immediately when all operations can run. On an unsatisfied
counter wait it retains a private command snapshot and starts a bounded worker,
then returns a submission ID. A later submission on the same guest thread can
therefore release the dependency. The worker resumes at the wait, without
repeating earlier operations, and preserves ordering before subsequent
readbacks and completion events. `sceKernelAprWaitCommandBuffer` consumes the
completion or reports its deferred error. There is no timeout that silently
turns an unsatisfied dependency into success.

At most 64 submissions are outstanding, matching the existing table bound;
only blocked submissions allocate snapshots and workers. Exhaustion is checked
before executing side effects. Runtime teardown cancels and joins the workers
before detaching guest memory. Resetting a recording buffer does not change an
already submitted snapshot.

## Validation

- The full ReleaseSafe HLE suite passes **594/594** tests.
- 22 focused AMPR tests pass in ReleaseSafe, including calls through the actual
  import IDs and System V guest ABI, with extended arguments passed on the stack.
- Tests cover field preservation, arithmetic overflow, masks, signed and
  wrapping comparisons, timestamps, invalid arguments and read-only output,
  deferred errors, submission exhaustion, and cancellation on reset.
- A same-thread producer releases an earlier blocked submission after the
  original buffer has been reset and reused; its completion event sees the
  expected pair value.
- Four concurrent producers perform 4,000 pair additions while snapshots check
  that the halves never disagree; the final value includes every increment.
- The ReleaseFast runner builds successfully (9/9 build steps). The installed
  `zig-out/bin/game-run.exe` is signed with the existing project certificate
  and a DigiCert timestamp. Its SHA-256 is
  `20ed9985a9b6b6dfcbcb9698a6fb5411cd7cec162bc5e313e9ad00d7fa571c77`.
- An installed-runner GTA III startup check reaches the readable Rockstar
  Policies & Terms screen. The captured trace includes over 9,000 completed
  file-read calls and over 350 completed AMPR event writes, with no matched
  AMPR error or guest fault. No counter API calls appear on this startup path:
  the counter behavior is validated by the tests, not inferred from this screen.
  This check makes no gameplay or FPS improvement claim.

Local build/test logs, the previous runner backup, signing metadata, startup
trace and capture are retained in `out/ampr-counters-20261009/` and the adjacent
`out/ampr-counters-*-20261009.log` files. The startup harness intentionally
limits its owned process to 180 seconds; termination at that limit is not a
spontaneous game crash.

## Reference review and limits

The local AnyPS5 checkout was updated during this work to
`04477932167b27525d8c37e69bb9eb7a50048fe4`. Its
[`libSceAmpr` exports](https://github.com/boykopovar/AnyPS5/blob/04477932167b27525d8c37e69bb9eb7a50048fe4/core/libs/prx/libSceAmpr/Export.cpp),
APR counter implementation and guest tests supplied comparison points for the
short/extended ABIs, field encoding and operations. KytyPS5's local counter
functions still record no-ops/zero writes. The implementation here uses
PS5PCEM's command records, memory validation and runtime lifecycle.

This is software counter emulation, not a claim of cycle-accurate accelerator
hardware behavior. Hardware queue priorities, device timing, cache flush costs,
and system counter banks are not modeled. The supported pair interface requires
an even first counter in the 0–127 bank; unsupported indices/modes return an
error. Start/completion flags are validated and respect map-scope restrictions;
within the synchronous file/map execution path, counter commands execute in
recorded order. `WaitOnAddress` remains a separate placeholder.

The AnyPS5 update also includes hardware-checked MIMG BY2/BY4 and PCK2/PCK4
loads, packed horizontal gather fixes, shader-call work and write-watch coverage
tracking. These are useful candidates for a separate renderer comparison;
none is claimed as a graphics fix or FPS improvement in this counter change.
PS5PCEM's current MIMG opcode table does not handle these BY2/BY4 and PCK2/PCK4
load encodings, making their decoder and execution tests a concrete follow-up.
Its new AMPR completion-event filter correction already matches PS5PCEM's
existing AMPR event filter.
