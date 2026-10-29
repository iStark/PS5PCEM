# ASTRO BOT: native APR asset loading — October 20, 2026

**October 29 update:** the latest report disproves the counted-zero-word
assumption below. The native buffer contains 20 zero bytes for one announced
command. Zero storage is no longer accepted as NOPs. A selective HLE comparison
is available; **PPSA21567 startup is still unconfirmed**. See the
[follow-up and retest instructions](astro-native-apr-followup-2026-10-29.md).

Follow-up to [issue #8](https://github.com/iStark/PS5PCEM/issues/8) and the
[AMPR kernel import fix](astro-ampr-kernel-imports-2026-10-20.md).
The reporter confirmed that PPSA21567 now links, but provided a log in which
`RoomLoad_ATQT` stops while loading object definitions.

## Evidence and scope

The assertion reports an empty duplicate name for `ui_wipe_transitions_1` and
`hero_respawn_icon_01`. The recorded hash, `0x811c9dc5`, is the FNV-1a initial
value for an empty string. Memory at `r13` starts with
`\0i_wipe_transitions_1`. The instruction at the reported fault is `cd 41`
(`int 0x41`), the title's assertion trap. Rendering continues after the loading
thread terminates; this log does not establish a Vulkan deadlock.

The local PPSA21564 v1.018 files contain two complete, distinct names. Its
headless loading path, using PS5PCEM's HLE AMPR implementation, already passed
this stage before this change. It does not contain the reporter's
`fakelib/libSceAmpr.sprx`, so this is not a reproduction of the entire reported
failure.

A separate, reproducible compatibility defect was found: kernel APR
submission accepted only objects recorded in the host HLE registry. A guest
AMPR module constructs a native 24-byte header and packed command stream
without entering that registry. A regression test submitting such a stream
failed before the change. This is a plausible cause of the missing resource
data, but the reporter's exact build still needs a retest.

## Changes

- Unregistered APR objects are decoded from native command-buffer headers.
  Registered HLE objects retain their existing recording path.
- Full reads, gather/scatter variants, and cursor reset load real title files
  through the existing positional I/O implementation. Packet fields retain
  48-bit destinations, 40-bit offsets, and the size-minus-one representation.
- Native map-begin/end and AMM packets use the existing memory mapper.
  Address/counter waits, counter updates, address writes, and event
  publication use the same submission lifecycle as HLE operations.
  Execution is ordered: completion writes/events cannot overtake earlier
  reads. Blocked submissions own decoded commands and survive guest buffer
  reuse.
- A snapshot is fully decoded before executing any command. Truncated
  packets, inconsistent counts, invalid cursors, unknown opcodes and
  unsupported sparse mappings are rejected. Failures report packet offsets.
- APR failures set guest errno as well as returning the SCE error code.
  The title's negative-return wrapper reconstructs errors from `__error()`;
  stale zero errno must not turn a rejected submission into success.
- Read destinations are checked for logical/host writability, retaining
  support for GPU-watched guest pages.

This does not implement all APR hardware scheduling or every packet variant.
Priority scheduling is unchanged. Unsupported commands fail explicitly.
It does not disable the title's duplicate-definition assertion or fabricate
resource contents.

## Verification

- The regression test loads both distinct asset names through native packets
  without an HLE constructor or registry entry.
- 14 APR-focused tests pass in ReleaseSafe. Coverage includes compressed
  reads, malformed tails without side effects, deferred snapshot ownership,
  actual mapping followed by file I/O, counters/events, error offsets/errno,
  large packet fields, and the previous GPU-watched destination test.
- All 23 AMPR-focused tests and 11 AMM-focused tests pass in ReleaseSafe.
- Standalone packet-module verification passes all 5 tests.
- The final ReleaseFast runner build passes all 15 build steps. A controlled
  headless PPSA21564 v1.018 launch reaches `Resident Load end` and
  `LevelDocument Loaded: ui_pause_next [pause_menu]` without a duplicate-name
  assertion, `GuestFault`, or APR submission error. The run is stopped.
  This exercises the existing HLE path; it is neither a visual gameplay check
  nor confirmation for the reporter's native module.

`zig-out/bin/game-run.exe` is rebuilt and signed with the existing PS5PCEM
certificate `50032C48F83F56327AB0C97B58C12A9696F92456` and a DigiCert SHA-256
timestamp. The signer and timestamp are verified. The host retains its
existing self-signed-root trust status; no trust-store changes are made.
Signed SHA-256:

`3DAB6870872369A535B23730F497E3D5EDEF768A7099FB6233584E71D837B5B4`

## Follow-up: zero first dword — October 23, 2026

With d959b86, the reporter's PPSA21567 build stops at the first submission:

```text
[apr] invalid native packet cb=0x300aa78a0 offset=0x0 header=0x0
[apr] submit failed cb=0x300aa78a0 offset=0x0: InvalidCommandBuffer
ASSERT: D:\asobi\6.0\source\engine\app\Module\System\AprFile.cpp:84
Apr submitCommandBufferAndGetResult failed : 0x80020016
```

The 24-byte header passed every check: a non-zero, dword-aligned byte count
within capacity, a positive command count and a readable stream. Only the
first stream dword is zero. The reporter later forced
`sceKernelAprWaitCommandBuffer` to succeed and describes the title as
clearing "the APR initialization gates", which suggests an early, nearly
empty submission. The attached log is no longer downloadable, so the header
values and following words are unknown.

What was ruled out, from the reporter's earlier log and public references:

- The earlier log loads `fakelib\libSceAmpr.sprx` (with
  `fakelib\libScePlayGo.sprx`). Its unresolved imports, the kernel AMM writers
  and indirect-buffer submissions, are used both by the retail library and by
  the [ampr_emu](https://github.com/drakmor/ampr_emu) replacement that some
  backports ship. Either records the same packed format into the same
  24-byte header, so the analysis below applies to both.
- No known packed form starts with a zero dword. ampr_emu's NOP writes
  `0x5452000F | ((n - 1) << 8)` and leaves the payload unwritten; markers use
  the same tag. Its decoder, like ours, rejects a zero opcode.
- The kernel AMM writers already write the packet when `dst` is non-null and
  report only the size when it is null, which is how libSceAmpr measures and
  then records a command.
- The eboot binds to the guest module, not to our HLE libSceAmpr: both export
  `libSceAmpr` version 1, and an exact guest export takes precedence. Our HLE
  header layout therefore cannot be mixed into these objects.

Kyty measures `nop(0)` as one dword although no reference encodes it (ampr_emu
writes no bytes for it). A library that reserves and counts such a dword
without writing it would produce exactly this stream. Native streams now accept a zero dword as a
one-dword no-op, but only when counting it that way reproduces the header's
command count; uncounted zero padding, a stream that was never written and
all other unknown forms are still rejected before any command runs. The
first acceptance in a process is logged. Every rejection now prints the
header fields (kind, bytes, commands, capacity, storage) and the first eight
stream dwords, so a further report identifies the actual form.

This is **not confirmed on the reporter's build**. The real encoding of the
reserved dword is unknown, and the black screen reported with the wait
bypass may have other causes.

- A new regression test covers a counted zero dword followed by a write, the
  same stream with an uncounted zero (rejected at the final count, without
  side effects), and a submission holding only the no-op.
- 15 APR, 23 AMPR and 11 AMM tests pass; the complete HLE suite passes
  709 tests.

## Reference

Native packet layouts were cross-checked against the GPL-3.0
[ampr_emu decoder](https://github.com/drakmor/ampr_emu/blob/cfa85df379f6eeeb165d7badf9b648e266fe77b7/src/ampr_emu_command_packing.cpp).
PS5PCEM uses its own filesystem, address space, counters, and submission
tracking.
