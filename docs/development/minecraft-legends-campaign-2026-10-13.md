# Minecraft Legends: campaign verification — October 13, 2026

PPSA05510 v01.013.000, development build, RTX 3070 Ti, 1920×1080 output,
Speed preset, keyboard input. Existing game and shader caches were retained.

## Verified gameplay and capture

**In-game · severe rendering defects.** After the rename implementation, a
fresh run reaches the opening tutorial with the mounted hero, health hearts
and movement/jump instructions. W moves the hero forward; D turns and moves
the mount to the right. The capture below is from this controllable scene,
after those inputs, rather than from the preceding cinematic.

![Minecraft Legends tutorial with a mounted hero, health hearts, severe color corruption, black regions and missing text](../images/minecraft-legends-gameplay-2026-10-13.jpg)

Colors and lighting are severely corrupted, large black regions cover part of
the scene, and menu/tutorial/subtitle glyphs disappear. Earlier startup in the
same run logs sampled/storage image `GuestMemoryReadFailed` errors. Later zero
GPU-gap counters do not establish correct rendering. The capture documents
progress into gameplay, not a playable/completable grade or fixed graphics.
No sustained FPS benchmark, audio-quality check, save reload, complete tutorial
or completed playthrough was performed.

The repeat logs successful `sceKernelRename` calls and creates the LevelDB
`CURRENT`, manifest and log files. The prior `_renameFile()` world-load failure
does not recur before the captured tutorial. This run also includes the final
sorted physical-allocation search from the previous startup investigation.

ReleaseFast `game-run.exe` build succeeded. SHA-256:
`184C9D96FB1B325637047652C359BC9C801DD5CC088A812FBBB4467289E844E4`.
This local test binary is unsigned. No release package was produced.

## From settings to the campaign

The continued October 12 startup run passes initial settings, the title screen,
the optional account-link prompt (skipped), hero selection and the main menu.
Campaign → New Game → Fabled starts the world load. Some letters disappear
from the menus, and later texture staging reports `GuestMemoryReadFailed`.
The earlier zero-gap observation was limited to initial settings.

The first campaign attempt fails with “There was a problem loading this world”.
The title's log identifies its LevelDB temporary-file rename as the blocker:

```text
Failed _renameFile() for file: /savedata0/minecraftWorlds/Flatland@/db/000001.dbtmp
Failed to open LevelDB!
```

## Save-file rename implementation

`rename` and `sceKernelRename` previously returned unsupported errors. Both now
use the mounted filesystem's native rename operation, including replacement of
an existing destination. No delete-and-copy fallback is used. Open descriptors
keep referring to their original file objects and retain their positions.
Renaming is restricted to a single writable guest mount; installed title data,
mount roots and cross-mount moves are rejected. Missing parents are not created.
The kernel and POSIX entry points report the corresponding status or errno.

The **653/653 HLE tests pass**, including a database-style temporary-file
publication over an existing CURRENT file, reads through both old open handles,
same-name rename, a failed publication preserving its destination, directory
rename, missing parents, null pointers and mount-boundary errors.

See the [startup investigation](minecraft-legends-startup-2026-10-12.md) for
the preceding memory, polygon-fill and GPU-written index fixes.
