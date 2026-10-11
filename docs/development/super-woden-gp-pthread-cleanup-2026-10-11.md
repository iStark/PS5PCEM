# Super Woden GP startup — October 11, 2026

Title: PPSA07211, content version 01.000.003. Development build.

## Missing imports

Unity's `Media/Modules/Il2CppUserAssemblies.prx` could not link because two
`libkernel` exports were missing:

| NID | Function |
|---|---|
| `1xvtUVx1-Sg` | `__pthread_cleanup_push_imp` |
| `iWsFlYMf3Kw` | `__pthread_cleanup_pop_imp` |

The names were verified with PS5PCEM's NID hashing algorithm. The module's call
sites pass a callback, its argument and stack storage to push, followed by
`pop(1)` after the guarded work. This agrees with the
[FreeBSD cleanup ABI](https://github.com/freebsd/freebsd-src/blob/main/lib/libthr/thread/thr_clean.c)
and its [caller-owned buffer declaration](https://github.com/freebsd/freebsd-src/blob/main/include/pthread.h).
The locally available KytyPS5, AnyPS5 and SharpEmu trees did not contain these
exports; no game-specific patch or no-op import was added.

## Implementation and validation

Each guest pthread owns its own cleanup-list head. Push writes the linked-list
prefix into guest-supplied storage and preserves the reserved tail. Pop removes
the latest entry before optionally invoking its callback through the existing
guest execution bridge. This permits nested pthread calls and cleanup
registration from a handler without holding the thread-manager lock.
`pthread_exit` runs the remaining handlers in reverse registration order before
TLS-key destructors. Caller storage is never freed or replaced by a host
allocation. Asynchronous thread cancellation remains unsupported.

- All **627 HLE tests pass** in ReleaseSafe.
- New tests cover thread isolation, LIFO ordering, `pop(0)`, nonzero execution,
  guest argument/identity forwarding, preservation of surrounding storage,
  reentrant callbacks, and cleanup-before-TLS-before-exit ordering.
- Export tests verify both NIDs are registered in `libkernel`.
- `zig fmt --check`, `git diff --check`, and the ReleaseFast runner build pass.

## Runtime result

Two launches pass linking and Unity initialization and render the developer
and Unity splash screens, followed by language selection. No missing import,
guest fault or cleanup callback failure was recorded in these checks.
The language screen has visibly incorrect flag colors. Startup success does
not establish rendering correctness, race gameplay, audio quality, saves or
long-session stability.

A third launch uses the runner's existing scripted Cross and rapid-Down input
profile to pass language selection and reach the main world-map menu. The saved
frame shows **71.8 FPS** on the RTX 3070 Ti, with 1920×1080 output and reported
largest internal target. This is a single window-counter observation, not a
timed benchmark or a race performance result. All **164** periodic GPU-gap
reports in this run have zero counters; no guest fault or cleanup failure was
recorded. Nevertheless, multiple map labels and icons are vertically inverted,
and the language-screen flag colors are incorrect. Zero gap counters therefore
do not imply correct graphics. Manual navigation was not validated: short key
presses from the UI tool did not appear in Pad diagnostics. All three test
processes were stopped after recording the result.

![Super Woden GP map menu with remaining inverted labels](../images/super-woden-gp-menu-2026-10-11.jpg)

The installed `zig-out/bin/game-run.exe` contains this implementation. An
automatic approval check rejected the signing command with `blocked by policy`
and no detailed reason, so this local development binary is **not signed**.

Runner SHA-256:
`3277923010ea0733dbd70ef058588eb029762c936d6e81040623b963bf42dd74`.
