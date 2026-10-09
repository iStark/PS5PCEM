# Jets 'n' Guns 2 audio streams — October 9, 2026

The reported crackling and delayed/intermittent sound reproduced in PPSA17163
with the signed 0.3.4 runner, despite smooth rendering in the mission menu.
Music and effects were competing for one host output device. A development
build now keeps independent host streams for concurrent legacy AudioOut ports.
This fix is newer than the published 0.3.4 release.

## Cause and change

The title submits NGS2 effects as 256-frame, 48 kHz, eight-channel float PCM
on port 1 and MP3 music as 256-frame, 48 kHz, stereo signed-16 PCM on port 2.
The old route selector repeatedly closed one output and opened the other.
`sceAudioOutOutputs` could force a handoff despite the earlier routing
hysteresis; buffers from the other active port were discarded. The baseline
log reached at least 128 handoffs and reported `DeviceUnavailable` during
playback. The release 0.3.2 mitigation did not cover this path.

Each legacy output now owns a persistent host stream, PCM allocation and lock.
Windows mixes concurrent streams, including their different source formats.
Batch output validates the entire batch before submitting all non-null ports.
Port generations reject a stale submission after its handle is closed and
reused. Closing one stream leaves the other stream's queue and PCM intact.
AudioOut2 retains its existing mixer and has separate PCM storage.

A second defect affected recovery after an underrun: staged PCM wrapped at
the 32-header reserve instead of the smaller active queue. Recovery could
submit stale or unfilled slots. It now preserves order within the active ring.
The default pre-roll remains eight 256-frame buffers at 48 kHz (42.7 ms);
the existing bounded adaptive reserve can grow to 32 buffers. This is a queue
budget, not a measured end-to-end speaker latency.

## Live verification

Recordings captured the Windows speaker loopback at 48 kHz stereo on the
MAJOR V endpoint. They did not use the microphone. A silent block means that
every sample in a 10 ms block has absolute magnitude below 0.00001.

| Sample | Duration | Silent 10 ms blocks | Longest silent run |
| --- | ---: | ---: | ---: |
| 0.3.4 mission menu | 20 s | 1,845 / 2,000 (92.25%) | 650 ms |
| Fixed mission menu | 20 s | 0 / 2,000 | 0 ms |
| Installed signed runner, settled mission menu, keyboard input | 30 s | 3 / 3,000 (0.1%) | 30 ms |
| Fixed Pirate Base combat, first repeat, seconds 2–15 | 13 s | 0 / 1,300 | 0 ms |
| Fixed Pirate Base combat, second repeat, seconds 2–15 | 13 s | 0 / 1,300 | 0 ms |

The two combat recordings lasted 30 seconds each. The active combat intervals
above exclude the subsequent player death and `MISSION FAILED` screen. Whole
recordings contain silence at transitions and on the failed-mission screen;
they are not evidence of uninterrupted sound throughout all 30 seconds.
The earlier exploratory gameplay capture also included short pauses and was
not used as a clean combat sample. Startup/transition underruns remain visible
in the log; absence of silent blocks does not rule out every short click.

The final installed-runner sample used keyboard-only input to disable the
default bring-up confirmation pulses, and began after the loading screen.
The mission map remained on screen. One 30 ms silent interval remains in that
30-second recording; its origin is not established. This is a substantial
reduction of the repeated 580–650 ms baseline dropouts, not a claim that every
audio artifact or the total output latency has been resolved.

Music and effects opened as separate streams. No route-handoff or playback
failure messages appeared in the fixed run. Guest song cleanup and subsequent
reopening still occur during scene/retry transitions. Active combat window
readouts in seconds 5–14 were 35.7–42.0 FPS and 38.3–45.8 FPS in the two
repeats. These are sampled UI counters, not a controlled before/after FPS
benchmark or evidence of a rendering speedup.

![Pirate Base combat during the second audio retest](../images/jets-audio-combat-2026-10-09.png)

The capture is an unedited game-window screenshot. The existing maintainer
playthrough status is retained; this retest covers the mission menu and short
Pirate Base combat, not another complete playthrough.

## Automated checks

- Full ReleaseSafe HLE suite: **596/596 passed**.
- Standalone audio-device suite: **13/13 passed**.
- Recovery coverage sweeps all cursors at active depths 8, 12, 16, 20, 24, 28
  and 32, checking sample order against sentinel PCM slots.
- A real Windows device test opens two streams, verifies private PCM storage,
  closes one stream, and continues queueing the other beyond its capacity.
- ReleaseFast game runner builds successfully.

Raw logs and private loopback recordings are retained locally under
`out/jets-audio-20261009/`; game music is not included in the repository.

## Installed development build

`zig-out/bin/game-run.exe` and its matching PDB were replaced after the tests.
The previous signed runner is preserved in the local investigation directory.
The replacement is signed with the existing Artur Strazewicz / PS5PCEM
certificate and a DigiCert timestamp. Signer and timestamp were checked;
Windows still reports the existing untrusted-root chain status. No trust-store
settings were changed. Published 0.3.4 release assets were not replaced.

Installed EXE SHA-256:
`1EA8C1C9A716C8B21E2679BD48BA265A6EF515FD0137E714A7497756E15A3D2A`.
