# Controller output over Bluetooth and the XInput fallback, 16 October 2026

The [first vibration pass](controller-vibration-2026-10-16.md) was physically
confirmed only on a wired DualSense. This follow-up reviews the DualShock 4
and XInput paths that could not be tried on hardware. SDL's HIDAPI drivers and
the Windows hidapi backend were used as references. The review found defects
that affect Sony pads on Bluetooth, plus one routing gap. It is a development
build and does not add a release.

## Findings

- **The transport was guessed from the first input report.** A DualShock 4 on
  Bluetooth sends report id 1, the same id as on the cable, until it receives
  its first output report. SDL's PS4 driver therefore detects Bluetooth by a
  serial-number feature read that fails over the air, not by the report. The
  old code classified such a pad as USB and sent it the cable report `0x05`
  instead of the Bluetooth report `0x11` that SDL sends.
- **Windows pads input reports to the longest declared size.** SDL's PS5 driver
  accepts the compact DualSense report at either 10 or 78 bytes for this
  reason. The old rule of "64 bytes or more means USB" therefore also
  misclassified a DualSense on Bluetooth in compact mode.
- **Windows expects a HID write at the declared output length.** hidapi's
  Windows backend states this and zero-pads every shorter report to
  `OutputReportByteLength` before `WriteFile`. Its Bluetooth workaround for
  Windows 7 applies to devices declaring more than 512 bytes, so Bluetooth
  lengths well above 78 bytes are expected. The fixed 32-, 48- and 78-byte
  writes only match a descriptor that declares exactly that size, as the
  wired DualSense does.
- **Reads used a fixed 256-byte buffer.** hidapi sizes every read by
  `InputReportByteLength` instead. A Bluetooth input report longer than the
  fixed buffer would not fit in it.
- **A refused write closed the device.** Input then disappeared until the next
  rediscovery, 240 polls later, and the next rumble repeated the cycle.
- **An undrivable Sony pad dropped all feedback.** If another program held the
  pad's output, input still came from HID but the rumble went nowhere. The
  XInput pad such a program usually presents was never tried.

The XInput path itself is correct and is unchanged. It drives the same
`PS5_CONTROLLER_INDEX` slot that input reads. The large motor maps to the
left, low-frequency motor and the small motor to the right one. Each byte is
scaled by 257 to the full 16-bit range.

## Changes

- When the pad is opened, `HidD_GetPreparsedData` and `HidP_GetCaps` give the
  declared input and output report lengths. A declared output report of 78
  bytes or more means Bluetooth. The cable descriptors stop at 32 bytes for a
  DualShock 4 and 48 bytes for a DualSense. A device whose lengths cannot be
  read is not opened.
- Each read asks for exactly `InputReportByteLength` bytes, as hidapi does.
  The buffer holds 1,024 bytes.
- Each output report is zero-padded to `OutputReportByteLength`. The Bluetooth
  checksum still covers only the 78-byte report, as in SDL.
- A refused or short write disables output for that device, but the device
  stays open for input. A real disconnect is still detected by the read side.
- The feedback worker drives a Sony pad only when it is writable. Otherwise
  the rumble goes to the configured XInput slot.

The DualSense Bluetooth header introduced in the first pass is unchanged. It
matches SDL3 as bundled with KytyPS5: a sequence and tag byte, then `0x10`,
then the payload. The older SDL2 copies in AnyPS5 and KytyPS5 use the previous
two-byte header.

## Validation

- Debug input suite: **23 passed, 1 platform-specific test skipped,
  0 failed**. New tests check the transport chosen from the declared output
  length, and that a padded Bluetooth report keeps its bytes and checksum
  with a zero tail.
- ReleaseFast HLE suite: **678/678 tests passed**.
- `zig build check` compiled every module, including the launcher.
- A read-only query of the connected DualSense over **USB** reported
  **64-byte input and 48-byte output reports**. The 48-byte output matches the
  cable report already sent, so this pad's output bytes are unchanged.
- A read-only native probe polled that pad 300 times through the new read path.
  **299 polls returned a parsed report**, with transport USB and output
  available. The probe sent no output report.
- One early filtered run of the pad tests failed the assertion that a freshly
  opened pad reports a centred stick. Eleven reruns passed. The test reads the
  attached controller, whose sticks rested at 127 and 130 in the probe. This
  is a property of the test environment, not of this change.
- The installed runner and launcher in `zig-out/bin` were not rebuilt in
  this pass.

DualShock 4 on USB or Bluetooth, DualSense on Bluetooth and XInput controllers
were not physically tested in this pass. Their output reports are now built
and sized the way SDL and hidapi send them, but no hardware confirmed it.

## Remaining scope

- A DualSense on Bluetooth that has not yet received an output report still
  sends the compact report. Input parsing still separates the two layouts by
  length, which Windows padding defeats. The transport is now known when the
  pad is opened, so parsing can use it instead. That change was not made
  because the wired pad cannot exercise it.
- Audio-driven DualSense haptics remain unimplemented. AnyPS5 offers one
  approach. When no DualSense audio device is present, it reduces the two
  vibration channels of the pad audio port to their RMS energy per audio grain.
  It ignores levels below 0.01 and doubles the rest into the two motor bytes,
  as `AudioOut2RumbleFromPadFrames` in
  `core/libs/prx/libSceAudioOut/src/AudioOut2PadMix.cpp`. That would give
  ordinary rumble to games that only use the haptics port.
- Adaptive triggers and guest light-bar APIs are unchanged.

## References inspected

- AnyPS5 `5d9dcc42d2ec5401aebd089028b8d4d7410a77b4`: bundled SDL2
  `src/joystick/hidapi/SDL_hidapi_ps4.c`, `SDL_hidapi_ps5.c` and
  `src/hidapi/windows/hid.c`; `core/libs/prx/libSceAudioOut/src/AudioOut2PadMix.cpp`
  and `AudioOut2Context.cpp`.
- KytyPS5 `3ff6606fcb6c1cae3aa46ef619f14b28efd3705d`: bundled SDL3
  `src/joystick/hidapi/SDL_hidapi_ps5.c`.

Microsoft documents the capability query in
[HidP_GetCaps](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/hidpi/nf-hidpi-hidp_getcaps).
