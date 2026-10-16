# Controller vibration, 16 October 2026

`scePadSetVibration` previously validated its arguments and returned success
without sending either motor intensity to the host. The launcher's controller
self-test could already vibrate a Sony pad, but games did not use that path.
This development build connects ordinary game rumble to native controller
output. It does not add a new release or establish a game-specific milestone.

## Implementation

The HLE entry reads the two-byte large/small motor structure, validates the pad
handle and null pointer, and publishes the requested intensities. Controller,
hybrid and automatic input modes enable feedback; keyboard-only and scripted
modes do not drive a physical controller. Native Sony HID takes precedence,
with the configured XInput slot used otherwise. XInput maps each byte to the
full 16-bit intensity range by multiplying by 257.

A lazily started worker handles device discovery and output independently of
the guest call. Identical requests do not wake it or issue duplicate Sony
reports. It keeps only the newest requested state, including zero requests
received while a previous report is still in flight. An idle worker sleeps on
an event; active feedback periodically checks for controller reconnection.

HID input, the launcher self-test and feedback now share a mutex. Output bytes
and the `OVERLAPPED` structure stay in device-owned storage until completion.
Closing a device cancels outstanding input/output with `CancelIoEx` and waits
for completion before reusing that storage. Normal runtime reset and the
runner's contained guest-fault exit stop feedback; pad close also publishes a
zero request. Abrupt external process termination cannot guarantee a final
hardware report.

Motor-only updates preserve the light bar. DualSense Bluetooth output now uses
the sequence/tag header, payload offset and CRC layout checked against SDL's
PS5 HID implementation. USB and DualShock 4 output retain their respective
report layouts.

## Validation

- Full ReleaseFast HLE suite: **678/678 tests passed**.
- Final Debug input suite: **22 passed, 1 platform-specific test skipped,
  0 failed**. Coverage includes motor channels, mode gating, zero/reset,
  pending-output replacement, duplicate suppression, USB/Bluetooth packet
  fields, sequence tags and checksums.
- HLE tests verify the two-byte ABI, handle/null validation, forwarding,
  explicit stop, pad close and reset. Automated unit tests never drive a
  physical controller.
- A separate native probe used the connected Sony DualSense over **USB**. It
  exercised each motor separately, both together, explicit zero, and reset
  during active feedback. **Eight HID reports completed successfully**;
  **1,500 duplicate requests caused no additional reports**. The user
  independently confirmed feeling vibration and its stop.
- ReleaseFast runner and launcher builds: **13/13 build steps succeeded**.
  The installed `zig-out/bin/game-run.exe` and `ps5pcem.exe`, with matching
  PDB files, were updated and signed with the existing PS5PCEM certificate
  and a DigiCert timestamp. The runner's no-argument startup check passed.
  Windows reports `UnknownError` for the existing self-signed certificate
  chain; this is not a claim of a Windows-trusted signing identity.

This verifies the HLE forwarding and native output separately. It is not a
new gameplay run or an FPS measurement. Bluetooth, DualShock 4 and XInput
hardware were not physically tested in this pass.

## Remaining scope

This is ordinary two-channel rumble. Adaptive triggers, guest light-bar APIs,
and audio-driven DualSense haptics are still separate work. In particular, the
special ATRAC9 haptics layout still decodes to silence; a game using only that
path will not gain its full feedback from this change. Vibration-mode calls
retain their existing compatibility behavior.

## References inspected

Local implementations were consulted for the API structure, host routing and
output behavior; their controller backends were not copied wholesale:

- AnyPS5 `5d9dcc42d2ec5401aebd089028b8d4d7410a77b4`:
  `core/libs/prx/libScePad/Export.cpp`, `src/PadState.cpp` within that library,
  and `core/libs/prx/libSceVideoOut/src/PadInput.cpp`.
- KytyPS5 `3ff6606fcb6c1cae3aa46ef619f14b28efd3705d`:
  `src/libs/controller.cpp`, `src/libs/libPad.cpp`, and its bundled SDL3
  `src/joystick/hidapi/SDL_hidapi_ps5.c`.
- sharpemu `81bb204bd800813ff08219055b7855499182e31b`:
  `src/SharpEmu.Libs/Pad/PadExports.cs` and
  `src/SharpEmu.Libs/VideoOut/SdlHostWindow.cs`.

Microsoft documents the cross-thread cancellation and completion lifetime
requirements in [CancelIoEx](https://learn.microsoft.com/en-us/windows/win32/api/ioapiset/nf-ioapiset-cancelioex),
and the controller output API in
[XInputSetState](https://learn.microsoft.com/en-us/windows/win32/api/xinput/nf-xinput-xinputsetstate).
