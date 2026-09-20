# AGC task: COPY_DATA from exports to execution

Implemented in `c72fd4a` and corrected during [Codex review](agc-copy-data-review.md).
The scope below records the original task; the review contains current results
and remaining limitations.

## Objective

Replace the NOP implementations of `sceAgcDcbCopyData` and `sceAgcAcbCopyData` with actual data copies. Implement the complete path: NID registration, guest ABI, matching writers and size queries, PM4 decoding, and execution that respects GPU write ordering.

This is a correctness and compatibility task. Do not assume an FPS improvement: an earlier short trace of the Big Helmet Heroes menu contained no calls to these exports. Titles can also construct packets directly.

## Exports and implementation locations

| Export | NID | Current implementation |
| --- | --- | --- |
| `sceAgcDcbCopyData` | `1rZSWUv1IRc` | `agc.writeCommand`, NOP |
| `sceAgcAcbCopyData` | `qzMN2XKGA4k` | `agc.writeCommand`, NOP |
| `sceAgcDcbCopyDataGetSize` | `b5u0Jzm8TF8` | Generic 16-byte size query |
| `sceAgcAcbCopyDataGetSize` | `CbQh3DKMSno` | Generic 16-byte size query |

The writers are registered in `src/hle/libs/bootstrap_services.zig`; the size queries are in `src/hle/libs/agc_table.zig`. `COPY_DATA` is already declared as opcode `0x40` in `src/gpu/pm4.zig`, but `src/gpu/executor.zig` does not execute it.

Use the local `E:\Emul-ps5\KytyPS5` checkout for comparison:

- `src/libs/agc.cpp`: `AgcDcbCopyData`, `AgcAcbCopyData`, and their size queries.
- `src/graphics/guest_gpu/command_processor/pm4Handlers.cpp`: `CpOpCopyData`.

Kyty is an independent reconstruction. Check its choices against our packet formats, guest callers, and available AMD documentation.

## Implementation

1. **Verify the DCB and ACB ABIs separately.** Kyty's DCB writer encodes `src >> 1` and `dst >> 1`, placing the low bit of `src` in control bit 30. Its ACB writer encodes the selectors directly. Do not route both exports to one guest handler without accounting for this difference. Check stack arguments and `callconv(abi.guest)`.
2. **Change each writer and GetSize together.** COPY_DATA occupies 6 DWORDs / 24 bytes: header, control, source low/high, and destination low/high. Preserve the meanings of cache policy, item size, write confirmation, and engine selector. Remove generic registrations that would shadow the implementations. Verify resolution through the complete `hle.registerAll` path.
3. **Implement verified 32-bit and 64-bit memory-to-memory and immediate-to-memory operations.** Establish the exact selector mapping. Invalid addresses or packets and unsupported register/GDS/clock variants need clear diagnostics. Do not report an operation that was not executed as a successful copy.
4. **Preserve ordering and memory visibility.** COPY_DATA must observe preceding GPU writes and make its result available to dependent subsequent commands. Reading a stale submission snapshot as the source is incorrect. Destination writes must update or invalidate affected resource caches.
5. **Choose the backend path to satisfy these requirements.** Forward any new callback through the scheduler and define behavior for backends without that callback. First inspect the existing `read`, `read_wait`, `write`, `write_data`, and `dma_data` paths to preserve synchronization and error handling.
6. **Check 64-bit immediate values separately.** The existing CPU fallback for DMA fill repeats a 32-bit pattern, so it cannot represent a value whose halves differ. Kyty also leaves this case unsupported; copying its handler does not complete the task.

Keep new predication modes, library registration reordering, tiling changes, and unrelated renderer optimizations out of this change. Do not disable working commands to make a test pass.

## Validation

- Call exports resolved through `hle.registerAll`, rather than invoking handlers directly; verify that NIDs are not shadowed.
- Verify that each writer uses exactly the announced 24 bytes, preserves guard words, and handles insufficient space and the grow callback correctly.
- Check DCB and ACB bitfields against independently specified expected packets, including the upper address halves.
- Check 32-bit and 64-bit memory and immediate copies. Use different upper and lower halves for 64-bit values and verify that adjacent bytes remain unchanged.
- Update the source with a preceding command and consume the result with a subsequent command. Include a test that distinguishes a stale snapshot from live memory.
- Ensure unsupported selectors and truncated packets cannot cause unintended writes.
- Verify a GPU-produced source and subsequent use of the result through the real Vulkan backend; add a small headless probe if needed.
- Check predicated COPY_DATA: a predicate that skips the copy must leave its destination unchanged.

Run the targeted tests, the full `zig build test` suite, and the release build:

```powershell
zig build build-game-run -Doptimize=ReleaseFast
```

Distinguish new failures from the known SPIR-V failures in `rdna2` and report the exact results.

## Menu verification

Run two fresh Big Helmet Heroes sessions, with only one game process at a time. Disable automatic input by selecting an explicit input mode:

```powershell
Set-Location E:\PS5PCEM
if (Get-Process -Name game-run -ErrorAction SilentlyContinue) {
    throw "Close the previous game instance first"
}
$env:PS5_INPUT_MODE = "controller"
$env:PS5_SHOW_FPS = "1"
.\zig-out\bin\game-run.exe "E:\[PS5] Big Helmet Heroes (2025) (PPSA19943)\eboot.bin"
```

Test the menu only; do not select Continue or New Game. Compare screenshots of the actual game window with `docs/images/big-helmet-heroes-menu.png`, checking colors, lighting, and object visibility. Measure FPS without detailed tracing. Close the process after each run.

Record the commit, executable SHA256, launch conditions, test results, and artifacts. Submit a separate commit for Codex review before pushing. If the menu does not exercise COPY_DATA, say so explicitly: correct menu rendering shows no observed regression, while targeted tests and the Vulkan probe establish that the new operation works.
