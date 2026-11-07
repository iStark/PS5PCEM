# Trackmania first render — November 6, 2026

Trackmania Free Starter Access (`PPSA02195`, v01.026.000, EUR backport) now
links and reaches its render loop on the Linux/Vulkan build. This note records
what blocked it and which behaviours are established. It is a bring-up result,
not a compatibility or performance claim.

## Result

The title installs its data packs, creates a 2560x1440 swap chain and renders
continuously. A 15-second run completed 660 flips with no unresolved imports,
no guest faults and no NP callback failures.

## Blockers and fixes

| Blocker | Fix |
|---|---|
| Link failed on NGS2, Http2, TTS2, NetCtl and SSL imports | Registered the missing exports. NGS2 system lock/unlock validate the handle without holding the host mutex across guest calls, because every NGS2 entry point already serializes individually. |
| `sceNpRegisterStateCallbackA` discarded its callback and `sceNpCheckCallback` never delivered | Store one registration and deliver the signed-in state through the title's poll thread. The callback ABI is `(userId, state, userdata)`; passing only two arguments made the title dereference its missing user id. |
| JSON2 initializer refused diagnostic hooks and disabled networking | Accept the process-wide null-access, special-float, type-mismatch and `InitParameter` hooks. The emulator's JSON implementation never invokes them, but the CppWebApi bootstrap treats refusal as fatal. |
| Bundled AGC/AMPR compatibility drivers left the native APR command stream zero-filled, corrupting `PlugResource.Gbx` loading | Route Trackmania's bundled `fakelib/` shadows to HLE, where APR command buffers are tracked by construction. |

## Evidence used

- `PS5_TRACE_FAILURES=1` showed `sceKernelAprSubmitCommandBufferAndGetResult`
  rejecting zero-filled storage.
- `PS5_TRACE=Apr` showed the failing submits and the titles' APR file-size
  resolutions.
- The PS5 3.20 firmware database and the `drakmor/ampr_emu` source identified
  the bundled AMPR compatibility layer and its kernel-hook expectations.

## Limits

Verified on Linux with Vulkan only. Gameplay, audio, input, online services,
frame pacing and memory stability beyond the short run remain untested. No
Windows or D3D12 result is implied.

## Integration review — November 7, 2026

PRs [#14](https://github.com/iStark/PS5PCEM/pull/14) and
[#15](https://github.com/iStark/PS5PCEM/pull/15) by
[kleinergoo7](https://github.com/kleinergoo7) were reviewed together against
current `main`, preserving all six contributor commits. The second PR depends
on the first; its driver-routing exception applies only to `PPSA02195` and
retains the existing Demon's Souls exception.

Integration review added two corrections to the fixed libkernel handle lookup:
scope symbol resolution to the `libkernel` module (including its POSIX/Unity
libraries), and detach the database before Runtime teardown frees it. Regression
coverage checks same-name foreign exports, foreign-only names, detached lookup,
and NP callback arguments, recursive polling, and re-registration from within
the callback.

Windows validation with Zig 0.16.0, ReleaseFast:

- `PS5_INPUT_MODE=scripted zig build test-hle test-runtime`: **756/756 passed**
  (740 HLE and 16 Runtime). Scripted input excludes physical-controller state
  from neutral-pad assertions.
- `zig build build-game-run -Doptimize=ReleaseFast -j2`: **15/15 build steps
  succeeded**, and the standard `zig-out/bin/game-run.exe` was updated.

These are host-side integration checks, not a new Trackmania game run. The
Linux/Vulkan render evidence above comes from the contributor. Missing services
such as speech synthesis still report absence; these PRs do not implement PSN
or establish gameplay compatibility.
