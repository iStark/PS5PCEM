# ASTRO BOT native APR follow-up — October 29, 2026

Issue [#8](https://github.com/iStark/PS5PCEM/issues/8) remains open. This is a
diagnostic/compatibility follow-up, **not a confirmed fix for PPSA21567**.
The reporter's `fakelib/libSceAmpr.sprx` is not present in our local PPSA21564
v1.018 extraction.

## New evidence

The October 26 log shows `kind=0x10000`, a used length of `0x14`, one command,
capacity `0x400`, and five zero dwords. The previous patch counted each zero
dword as a NOP, resulting in five commands instead of the advertised one.
Accepting the whole zero range would still perform no asset read.

The native packed NOP uses the `0x5452000f` tag plus length/type bits, as seen
in [ampr_emu's packet writer](https://github.com/drakmor/ampr_emu/blob/cfa85df379f6eeeb165d7badf9b648e266fe77b7/src/ampr_emu_command_packing.cpp)
and AnyPS5's `AprCommandBuffer.hpp`. A zero-filled read-sized region does not
establish a different valid NOP encoding. Its missing file ID, destination
and length cannot be reconstructed from the reported header.

## Changes

- Removed the speculative zero-dword acceptance. Fully zero native streams
  now report `zero-filled native stream (no encoded commands)` at offset zero.
  They fail before any I/O or completion write. Correct tagged NOPs, including
  zero-valued payloads, continue to work.
- Added an explicit per-module firmware choice:
  `PS5_HLE_BUNDLED_MODULES=libSceAmpr.sprx`. It excludes only the named module
  under the top-level `fakelib` directory, using the existing HLE exports and
  actual file-reading implementation. Other drivers and `sce_module` files
  retain their existing routing. There is no default title-ID workaround.
- The setting accepts semicolon-separated `.prx`/`.sprx` basenames. Paths are
  rejected. Directory and archive discovery share the selection policy.
  Unknown imports still fail linking; no success stubs are added.

## Reporter retest

After pulling and rebuilding `main`, run this in PowerShell, using the local
path to PPSA21567:

```powershell
$env:PS5_HLE_BUNDLED_MODULES = 'libSceAmpr.sprx'
$env:PS5_TRACE = 'Ampr,Apr'
.\zig-out\bin\game-run.exe 'F:\Installations\Various Files\PPSA21567\PPSA21567-app\eboot.bin' 2>&1 | Tee-Object astro-apr-hle.log
```

The startup module list should no longer include `fakelib/libSceAmpr.sprx`.
Please report the furthest visible screen and attach the complete log,
including any unresolved imports or first failing AMPR call. Remove local
patches that force APR submission/waits to return success before testing.

To restore the normal module route, use
`Remove-Item Env:PS5_HLE_BUNDLED_MODULES`; remove `Env:PS5_TRACE` to disable
verbose tracing. No game files or saves need to be deleted.

## Validation scope

The reported zero stream is covered by a regression test with both the actual
count of one and a forged count of five. Neither may succeed. A valid tagged
NOP with four zero payload dwords followed by a real address write succeeds.
Focused checks pass: **10 native APR tests** and **3 shadow-module tests**.
The complete suites also pass: **730 HLE tests and 16 runtime tests**.
This demonstrates packet and module-selection behavior, not the reporter's
full game startup. The underlying reason the guest writer produced zeros
still requires its module or a further diagnostic run.

The rebuilt ReleaseSafe runner also passes a headless PPSA21564 v1.018 asset
loading check: `Resident Load end` and `LevelDocument Loaded: ui_pause_next
[pause_menu]` are reached, with no APR submission failure or duplicate-name
assertion. A separate `WebApiJobWorker` thread has a contained access violation
while loading continues; this check does not establish overall fault-free
execution. It exercises the existing HLE path because this local extraction
has no bundled AMPR module. The run was stopped; no new visual or FPS result
is claimed.
