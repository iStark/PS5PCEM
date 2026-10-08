# Release 0.3.4 validation — October 9, 2026

Source features are the twelve commits after `v0.3.3`, ending at `6804e96`.
Release preparation updates version metadata and documentation; it does not
add another renderer or firmware change.

## Build and tests

- Windows x86-64, Zig 0.16.0, ReleaseFast: all three application targets build
  successfully, **16/16 steps**. Both launcher and runner Windows file/product
  versions are **0.3.4**. The extractor has no Windows version resource.
- Fresh ReleaseSafe HLE run: **594/594 passed**, including fonts, MemoryPool,
  PNG/RTC and AMPR counters.
- The immediately preceding scalar-call checkpoint passes **259/259
  GPU-analysis** and **232/232 Vulkan** tests. RDNA2 passes **271/281** with the
  same ten baseline failures and one reported leak. Native shader-probe
  results and scope are in the linked release notes; they are not game FPS
  measurements.

## Launcher regression check

The actual ReleaseFast launcher and runner were copied into an isolated
portable-style directory containing spaces and Cyrillic characters, outside
`zig-out\bin`. The launcher was started with `C:\Windows` as its working
directory. Its ordinary Launch game handler was invoked using a window
message, with Jurassic Park's real `eboot.bin` selected in isolated settings.

The launcher successfully created the sibling `game-run.exe` with the expected
quoted game and `--app0` arguments. Reading the child process's Windows
process parameters confirmed its working directory was the application
directory, including the trailing separator, rather than `ps5pcem.exe` or the
launcher's inherited directory. The check stopped only its own child and
launcher after verification. It checks process creation and directory handling,
not game rendering or completion.

Local evidence is retained under `out/release-0.3.4/`, with adjacent build and
HLE logs. Release packaging uses `scripts/package-release.ps1`, with the
existing certificate `50032C48F83F56327AB0C97B58C12A9696F92456` and DigiCert
timestamp service. The certificate's root remains untrusted on this machine;
no trust-store changes are part of the release.

The release's Jurassic Park screenshot is the October 8 first-level capture
from the font-atlas fix, already recorded in the compatibility history.
No fresh title-wide performance or full-playthrough claim is made here.
