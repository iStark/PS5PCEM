# Minecraft Legends: linking, memory and startup rendering

**Follow-up, October 13:** the main menu and controllable opening tutorial are now verified after implementing file rename for the campaign database. Severe rendering defects remain. See the [gameplay report and capture](minecraft-legends-campaign-2026-10-13.md). The observations below retain the earlier startup checkpoint.

October 12, 2026. Development build, PPSA05510 v01.013.000, RTX 3070 Ti,
1920×1080 output, Speed preset. Game files were supplied locally.

## Verified progress

The title now links, draws its loading logo, plays the publisher and opening
movies, and displays a readable initial Settings screen. Keyboard Down input
moves the selection through language, subtitle and text-size controls to
Continue. The UI test was stopped by the maintainer before the transition from
Continue could be verified. The main menu and gameplay are **not yet verified**.

The observed startup run contains no guest fault or nonzero draw/dispatch gap
counters through the initial settings screen. This is limited startup coverage,
not proof of complete shader support or long-session stability. There was
concurrent compilation during parts of the run, so its window counters are not
reported as a performance benchmark. Audio output has nonzero PCM levels, but
listening quality has not been checked.

## Changes

- POSIX `mprotect` and `munmap` resolve the two original imports from
  `libcohtml.Prospero.prx`. They apply real guest mapping changes and return
  POSIX errors for invalid requests. Additional startup imports include
  descriptor-readiness events, filesystem synchronization and reachability.
  SSL connection/read/write exports explicitly report the existing offline
  error; they do not implement TLS or claim successful network operations.
- Windows placeholder handling tolerates adjacent recycled logical
  reservations. Releasing a physical subrange unmaps only the intersecting
  slices of its aliases, preserving both live neighbours. Physical pages are
  not recycled if native aliases could not be removed.
- System-managed direct-memory heaps use independent 16 KiB native views.
  This permits the guest allocator to recycle individual pages from an
  originally 64 KiB-aligned acquisition without revoking neighbouring live
  pages. Aligned device-window mappings retain their wider views.
- Explicit filled front/back polygon mode is accepted. The captured UI state
  used `POLY_MODE=1` with both face types set to fill; it was previously rejected
  on every draw. Visible line/point modes remain explicitly unsupported.
- Indexed draws publish GPU-written index data even when the index list starts
  inside a larger storage buffer. The captured copy shader correctly produced
  `[1, 2, 0, 0, 2, 3]` at buffer offset `0x74`, while CPU-side index staging read
  zeros. Explicit index consumers now flush the intersecting producer; generic
  command-label reads retain their narrower exact-base rule.
- Physical reservations remain sorted when holes are reused. First-fit and
  largest-free searches walk occupied intervals once instead of repeatedly
  rescanning the entire list. The live loading thread was sampled inside the
  old allocator while other workers waited for it. A focused ReleaseFast
  comparison with 8,192 occupied pages, eight further allocations and one
  largest-free query took 382,315 µs before and 70 µs after, with identical
  selected addresses and free-range results. This is an allocator microbenchmark,
  not a game-loading or FPS comparison. A full startup with this final search
  change remains to be repeated.

## Validation

- 651/651 HLE tests, including fragmented physical-memory placement against
  a page-map oracle, dense allocation/hole reuse and MemoryPool donation into
  a lower hole.
- 35/35 address-space tests, including a guest-page recycling reproduction
  that failed with `HostDecommitFailed` before the native-view change.
- 245/245 Vulkan tests, including explicit polygon fill validation.
- Native `vulkan-smoke --device-storage` probe: interior index publication,
  preserved dirty suffix, no redundant readback on a repeated read, and the
  existing device-storage checks pass.
- ReleaseFast runner build; formatting and whitespace checks.

The fixes are shared memory/rendering paths. They do not patch the game binary,
skip its startup code, or synthesize a menu.
