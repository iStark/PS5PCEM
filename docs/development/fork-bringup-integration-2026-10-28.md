# Fork bring-up integration — October 28, 2026

Four commits from [kleinergoo7/PS5PCEM](https://github.com/kleinergoo7/PS5PCEM/commits/main/)
are integrated with their original history and author attribution. The fork and
our branch share `e6471d6`; our subsequent D3D12 work remains intact.

| Original commit | Contribution |
| --- | --- |
| [3709a75](https://github.com/kleinergoo7/PS5PCEM/commit/3709a75d4686a7b2eb1968444855151adcb9d408) | Vulkan readback branch and staging-content diagnostics |
| [cff7754](https://github.com/kleinergoo7/PS5PCEM/commit/cff7754df9c877098d3c54cc4e031557db07d880) | Sampled per-draw shader/program audit and additional pipeline state logging |
| [ab3102b](https://github.com/kleinergoo7/PS5PCEM/commit/ab3102b517588309679862757827bc8cc34869c0) | Opening nested diagnostic files under `/devlog/app` |
| [25b89a2](https://github.com/kleinergoo7/PS5PCEM/commit/25b89a2f0e78b7744b7c60867c3086853922e9e3) | Additional NP asynchronous-request and telemetry-statistics exports |

## Integration corrections

The periodic draw audit requires `PS5_TRACE_RESOURCE_FAILURES=1`. Normal runs
do not emit its up-to-20 draw records on every fifth flip. The readback
diagnostics distinguish transfers from early exits; they do not change which
draws execute or establish that a black-screen rendering problem is fixed.

Nested logs are written to `out/devlog`, with traversal, host drive/stream
syntax and Windows-special path components rejected. Dots inside ordinary
filenames remain valid. File creation, exclusive creation, opening an existing
file, append, truncation and read-only access use the existing writable-file
implementation. The established `/devlog/app/debug.log` redirection to
`out/guest-debug.log` is retained. This change covers file opening, not a full
new mount implementation for every filesystem operation.

Synchronous and asynchronous NP requests share one bounded, locked registry.
The duplicate `sceNpDeleteRequest` export is removed so deletion releases the
same object that creation allocated. IDs stay positive across counter wrap;
invalid/deleted IDs and pool exhaustion return NP errors. Polling completes
immediately with a signed-out operation result, rather than claiming a
successful PSN response. Aborting an already completed offline request still
checks its ID. Optional async worker parameters do not start a network worker.

`sceNpGetAccountLanguage2` uses **three** arguments: request ID, user ID and
output pointer. The contributed two-argument implementation could interpret
the user ID as a pointer and write to it. The corrected offline query reports
signed-out status without modifying the output. The existing local account
bootstrap state remains unchanged.

UDS memory statistics initialize all three 64-bit fields (24 bytes), rather
than only the first field. The offline telemetry sink allocates no pool and
reports zero usage.

The account-query ABI, NP error values and UDS layout were cross-checked
against local AnyPS5 `a3ac94774e70a3e1f408be10ea6af2e18a68eee4` and sharpemu
`299c907c627c97cc7980e5a6075cd79399ca3b11` sources. These references do not
establish complete firmware compatibility or PSN support.

## Validation and limits

Using Zig 0.16.0:

- **729/729 HLE tests pass in ReleaseSafe**, including request lifecycle,
  capacity/ID wrap, account-output preservation, guarded telemetry buffers,
  nested log file I/O and path rejection. An integration test resolves and
  calls the NP handlers through the complete firmware export database.
- **267/267 Vulkan tests pass in ReleaseFast**.
- `zig fmt --check` and `git diff --check` pass.

```text
zig build test-hle -Doptimize=ReleaseSafe -j2 --summary all
zig build test-vulkan -Doptimize=ReleaseFast -j2 --summary all
zig build build-game-run -Doptimize=ReleaseFast -j2 --summary all
```

No game run is part of this integration. Demon's Souls is unavailable locally;
its startup, graphics, gameplay and FPS remain unverified. No compatibility
grade or performance claim is changed by these commits.
