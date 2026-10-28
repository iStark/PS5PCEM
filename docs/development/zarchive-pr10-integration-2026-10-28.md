# ZArchive and Demon's Souls bring-up integration — October 28, 2026

This integrates [PR #10](https://github.com/iStark/PS5PCEM/pull/10) by
kleinergoo7, preserving its ten commits and adding maintainer corrections.
The related [Demon's Souls report](https://github.com/iStark/PS5PCEM/issues/11)
is a bring-up investigation, not a gameplay or completion result. The
maintainer does not have PPSA01341 locally; no new game FPS is established.

## Contributor changes

- Read-only ZArchive (`.zar`) content streaming through the module loader and
  guest filesystem, with random access to 64 KiB raw/zstd blocks and a 4 MiB
  decompressed-block cache.
- Launcher discovery of a single archive in a selected directory. An
  extracted executable takes precedence. Multiple archives are ambiguous and
  are not selected automatically.
- Demon's Souls import mappings and a PPSA01341-only policy routing bundled
  `fakelib` shadow drivers to firmware HLE. Other titles retain their previous
  routing policy.
- AMPR `ClearBuffer` keeps the registered object available for subsequent
  `SetBuffer`; plain APR submission, untracked completion reclamation, and
  dynamically sized command-buffer registration.
- Offline NP title registration, unreadable guest instruction-pointer guards,
  and host-address overflow checks.
- Optional RenderDoc capture and Vulkan staging of the base level of
  supported multi-level 2D storage views.

## Maintainer corrections

Windows builds use `LoadLibraryA`/`GetProcAddress` and
`SetEnvironmentVariableA` for optional RenderDoc support. Zig 0.16's
`std.DynLib` and the POSIX `setenv` import cannot serve this Windows path.
The shared range parser rejects invalid or inverted flip ranges.

Capture now begins before scene commands and ends after presentation. A
single-frame range does not start and end at the same call site. The Vulkan
device argument is the instance's dispatch-table pointer, as required by
`RENDERDOC_DEVICEPOINTER_FROM_VKINSTANCE`; shutdown discards an unfinished
capture. Mock API tests cover single frames, inclusive ranges, rearming,
discard, and dispatch-pointer conversion. A real RenderDoc capture is not
part of this validation.

`sceFiberOptParamInitialize` initializes the fixed 128-byte opaque record;
its previous contents are not an input size. The regression checks both
nonzero and zeroed records and verifies adjacent memory is untouched.

Archive cache entries are invalidated before replacement: a truncated or
corrupt block cannot leave partially overwritten data addressable under the
old block's identity. Synthetic archive fixtures now lay out nested siblings
correctly. Tests cover nested paths, raw/zstd reads, malformed extents,
overlapping sections, and reading an evicted block again after a decode error.

Windows archive discovery no longer inserts a duplicate path separator and
reserves space for the terminating NUL. Linux save-title metadata follows
the same extracted-versus-archive precedence as executable selection. The
module-graph test accepts native path separators on both platforms.

## Usage and limits

```text
game-run game.zar
game-run --app0 game.zar eboot.bin
```

The archive must contain a supported decrypted executable and its content.
The reader does not decrypt retail packages. Guest writes to archive content
are rejected; saves continue to use the separate writable host mounts.
The directory-based FSB audio-bank indexing path is not available for archive
mounts. Archive performance and title compatibility still need real-game
comparisons; successful synthetic tests do not establish either.

For installed RenderDoc, set `PS5_RENDERDOC_FLIPS=2` or `1-3` before starting
the runner. Missing capture libraries disable the optional diagnostic with a
message; normal runs do not load RenderDoc.

The two unnamed `SceLibcV2AtomicWait` NIDs remain provisional non-blocking
bridges. They emit a one-time warning when called. Discarding a return value
does not prove that synchronization side effects are unnecessary. Actual
`libc.prx` call sites are needed before claiming a full implementation.
JPEG encoder imports resolve but return unavailable, including creation and
memory queries; they never report an initialized encoder that does not exist.
PRT aperture bookkeeping and the three unknown Agc import acceptors likewise
do not establish complete sparse-memory or Agc support.

## Verification

Validation uses Zig 0.16.0 with `ReleaseSafe`:

- Windows runner and native launcher build successfully.
- Linux x86-64/glibc 2.31 runner and GTK launcher cross-build successfully;
  runner startup/usage and launcher `--version` execute under Ubuntu WSL.
- The full Windows suite reports **1,921 passed, 1 skipped, 10 failed** out
  of 1,932 tests. HLE **722/722**, Vulkan **267/267**, runtime **15/15**,
  ZArchive **9/9**, RenderDoc **4/4**, and Windows launcher **3/3** pass.
- The standalone ZArchive **9/9** and RenderDoc **4/4** suites also pass
  when compiled for Linux and executed under WSL.
- `zig fmt --check` and `git diff --check` pass.

The existing RDNA2 suite has
ten failing tests and one reported leak on both the unmodified base
`9e08c8c7976e1b253bcb20684f21ea60e5db494c` and this integration. They are
tracked separately from the PR's Windows build and module-graph failures.

```text
zig build test -Doptimize=ReleaseSafe -j2 --summary all
zig build build-game-run build-launcher -Doptimize=ReleaseSafe -j2
zig build build-game-run build-launcher -Dtarget=x86_64-linux-gnu.2.31 -Doptimize=ReleaseSafe -j2
```
