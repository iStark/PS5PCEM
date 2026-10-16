# Game-controlled LightBar, 16 October 2026

`scePadSetLightBar` and `scePadResetLightBar` previously returned success without
changing the controller. They now reach the native Sony output path used by
the launcher test and ordinary game vibration.

## Behavior

The setter accepts the four-byte RGB/reserved structure, validates the handle
and null pointer, and forwards all three color bytes unchanged. The reserved
byte does not affect the color. Black is a valid request to turn the RGB light
off. Reset selects the primary-player host default **RGB (0, 64, 255)**, matching
AnyPS5's reset policy. This is an emulator default, not a measured PS5 firmware
color or a restoration of another application's previous setting.

Color and motor state share one atomic snapshot and a single output worker.
Each setter changes only its own fields. A color update therefore retains
active rumble, a rumble update retains color, and completing an older HID write
cannot erase a newer request. Duplicate snapshots do not produce more Sony
reports. Light-only packets leave the motor/audio-haptics enable bits clear.
Pad close stops motors and restores the default color if the game controlled
it; runtime shutdown does the same before closing the device.

Controller, hybrid and automatic input modes enable host feedback. Keyboard
and scripted modes do not drive the physical LightBar. XInput controllers
retain ordinary rumble but have no RGB API in this backend. Unsupported output
hardware does not make the guest pad call fail.

## Bluetooth LightBar initialization

DualSense can ignore RGB during its Bluetooth connection animation. Following
the bundled SDL implementation, the HID path waits for the enhanced input
packet's connection timer to reach 10,200,000 ticks, sends a separate LED-reset
report, waits for its completion, and then applies the latest RGB value. A
3.5-second host-time fallback covers missing enhanced timer reports. Motor
commands continue during this setup without repeating unchanged output.

USB DualSense and DualShock 4 use their existing RGB fields and report layouts.
This change does not implement player indicator LEDs, the microphone LED,
adaptive triggers or audio-driven haptics.

## Validation

- Full ReleaseFast HLE suite on the combined code: **679/679 tests passed**.
- Debug input suite after integration with the concurrent Bluetooth output
  changes: **29 passed, 1 platform-specific test skipped, 0 failed**. Tests
  cover RGB bytes and enable flags over USB/Bluetooth, black, reset ordering,
  independent motor/color updates, concurrent producers, queued replacement,
  duplicate suppression, and output padding.
- HLE coverage checks the four-byte ABI, ignored reserved byte, invalid
  handles/null, unchanged motor intensities, black, default reset, pad close
  and runtime reset. Unit tests do not write to physical controllers.
- A native probe on the connected **DualSense USB** completed **11 HID
  reports**: red, green, blue, black, interleaved color and rumble, explicit
  reset, pad-close output and worker shutdown. **2,000 identical color
  requests produced no extra reports**. Light-only updates did not enable
  the motors; shutdown restored the blue default and zero motor intensity.
  The probe checks Windows write completion and the applied report state;
  it cannot read the physical LED color back from the controller.
- On the longer repeat, the user visually confirmed **red, green and blue**
  on the physical controller.
- ReleaseFast runner and launcher builds completed **13/13 steps**. Both
  executables were signed with the existing PS5PCEM certificate and a DigiCert
  timestamp. Windows reports `UnknownError` for that self-signed certificate
  chain; this does not establish a Windows-trusted signing identity.
  The installed `zig-out/bin/game-run.exe` and `ps5pcem.exe`, with matching
  PDB files, were updated. Installed hashes match the signed build artifacts,
  and the runner's no-argument startup check passed.

Bluetooth and DualShock 4 hardware were not physically tested in this pass.
No game-specific run or FPS measurement is claimed here.

## Reference comparison

- AnyPS5 `5d9dcc42d2ec5401aebd089028b8d4d7410a77b4`: `libScePad/Export.cpp`
  forwards RGB; `PadState.cpp` retains it alongside motors;
  `libSceVideoOut/src/PadInput.cpp` uses SDL LED output and resets to (0, 64, 255).
- KytyPS5 `3ff6606fcb6c1cae3aa46ef619f14b28efd3705d`:
  `src/libs/controller.cpp` uses a four-byte RGB/reserved structure and
  `SDL_SetGamepadLED`. Its `PadResetLightBar` still only validates the handle.
- sharpemu `81bb204bd800813ff08219055b7855499182e31b`:
  `PadExports.cs` reads four bytes and forwards RGB through the host interface;
  `SdlHostWindow.cs` applies the LED color and uses a dimmer (0, 0, 64) reset.
- KytyPS5's bundled SDL3 `src/joystick/hidapi/SDL_hidapi_ps5.c` documents the
  connection timer, separate LED-reset/color enable bits and Bluetooth order.

PS5PCEM retains its native Windows HID backend; these references inform the
API and protocol behavior rather than introducing an SDL controller dependency.
