# Linux packages

PS5PCEM 0.3.5 includes a native x86-64 runner, GTK 3 launcher and PKG extractor.
The Linux port is experimental; Windows game results are not Linux compatibility
or performance claims.

## Requirements

- x86-64-v3 processor (AVX2, BMI2, FMA and FSGSBASE).
- Linux 5.11 or newer with FSGSBASE and Syscall User Dispatch available.
- glibc 2.31 or newer, GTK 3, X11/XWayland, Vulkan loader and a Vulkan 1.2 driver.
- PulseAudio or PipeWire's PulseAudio compatibility service for audio.
- `curl` for the launcher's release check.

The AppImage uses the same system GTK 3, X11, PulseAudio and Vulkan libraries;
it does not bundle a graphics driver or glibc. Install these runtime libraries
through your distribution first. It can run without FUSE using
`--appimage-extract-and-run`.

## Install and start

```sh
# Debian / Ubuntu
sudo apt install ./PS5PCEM-0.3.5-linux-x64.deb
# Fedora
sudo dnf install ./PS5PCEM-0.3.5-linux-x64.rpm
# Arch Linux (the .pacman file is a standard zstd-compressed package)
sudo pacman -U ./PS5PCEM-0.3.5-linux-x64.pacman
# AppImage
chmod +x PS5PCEM-0.3.5-linux-x64.AppImage
./PS5PCEM-0.3.5-linux-x64.AppImage
```

Installed packages add PS5PCEM to the desktop applications menu. The `ps5pcem`,
`game-run` and `pkgextractor` commands are available in PATH. Choose a decrypted
game directory in the launcher. For direct CLI runs, start `game-run` from a
writable working directory and pass an absolute path to `eboot.bin`.

Installed packages and AppImages store settings under
`${XDG_CONFIG_HOME:-$HOME/.config}/ps5pcem/ps5pcem.ini` and saves, logs and caches
under `${XDG_DATA_HOME:-$HOME/.local/share}/ps5pcem/`. Development builds retain
their existing writable application directory. `ps5pcem --version` reports the
release; `ps5pcem --check-install` checks GTK, companion executables and paths
without opening a window.

## Current limits

Keyboard input, X11 Vulkan presentation, native guest threads/fibers and
PulseAudio output are implemented. Native Sony HID/XInput controller input,
rumble and LightBar remain Windows features. Windows Media Foundation video
decoding has no equivalent Linux backend yet. Wayland requires XWayland;
there is no native Wayland presentation backend. The earlier Linux bring-up
reached the Jets 'n' Guns 2 mission screen under WSL2/lavapipe; it does not
establish native-driver game performance.

## Build and package

Use Zig 0.16.0:

```sh
zig build build-game-run build-launcher build-pkgextractor \
  -Dtarget=x86_64-linux-gnu.2.31 -Doptimize=ReleaseFast
scripts/package-linux.sh zig-out/bin dist /path/to/appimagetool-x86_64.AppImage
```

Packaging requires bash, binutils, FPM, dpkg-deb, rpmbuild, zstd, squashfs-tools
and the official AppImage appimagetool. The script retains its temporary
staging directory for inspection. Use a Linux filesystem for `TMPDIR` so
package permissions are preserved. Build the Linux packages before running
`scripts/package-release.ps1`; it includes them in the combined SHA256SUMS.
No firmware, games, keys, saves or shader
caches are packaged.
