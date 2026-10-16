#!/usr/bin/env bash
# Package already-built Linux x86-64 binaries; never includes games or caches.
set -euo pipefail
umask 022
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=$(tr -d '\r\n' < "$repo/VERSION")
if [[ $# != 3 ]]; then
    echo "Usage: $0 BINARY_DIR OUTPUT_DIR APPIMAGETOOL" >&2
    exit 2
fi
binary_dir=$(realpath "$1")
mkdir -p -- "$2"
output=$(realpath "$2")
appimagetool=$(realpath "$3")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
stage=$(mktemp -d "${TMPDIR:-/tmp}/ps5pcem-$version.XXXXXXXX")
# Keep the staging directory for inspection; the caller owns its lifecycle.
root="$stage/root"
mkdir -p "$root"
chmod 755 "$root"
if [[ $(stat -c %a "$root") != 755 ]]; then
    echo 'Use a Linux filesystem for TMPDIR: package staging must preserve POSIX permissions.' >&2
    exit 1
fi
install -d "$root/usr/lib/ps5pcem" "$root/usr/bin" \
    "$root/usr/share/applications" "$root/usr/share/icons/hicolor/256x256/apps" \
    "$root/usr/share/doc/ps5pcem"
for name in ps5pcem game-run pkgextractor; do
    [[ $(od -An -tx1 -N4 "$binary_dir/$name" | tr -d ' \n') == 7f454c46 ]] || { echo "Not ELF: $name" >&2; exit 1; }
    install -m755 "$binary_dir/$name" "$root/usr/lib/ps5pcem/$name"
    strip --strip-debug "$root/usr/lib/ps5pcem/$name"
    ln -s "../lib/ps5pcem/$name" "$root/usr/bin/$name"
done
install -m644 "$repo/packaging/linux/ps5pcem.desktop" "$root/usr/share/applications/"
install -m644 "$repo/assets/branding/ps5pcem-icon-256.png" "$root/usr/share/icons/hicolor/256x256/apps/ps5pcem.png"
install -m644 "$repo/README.md" "$repo/LICENSE" "$repo/VERSION" \
    "$repo/docs/release-notes/v$version.md" "$repo/docs/linux.md" "$root/usr/share/doc/ps5pcem/"
# Corresponding source is available from the immutable release tag on GitHub.
common=(-f -s dir -C "$root" -n ps5pcem -v "$version" --iteration 1 --architecture x86_64 \
    --maintainer 'Artur Strazewicz <truestark@gmail.com>' --license GPL-3.0-or-later \
    --url https://github.com/iStark/PS5PCEM \
    --description 'Experimental PlayStation 5 emulator with a native GTK 3 launcher. Requires an x86-64-v3 CPU, Linux 5.11 or newer and a Vulkan 1.2 graphics driver. No game content included.')
fpm "${common[@]}" -t deb --deb-no-default-config-files --deb-compression xz \
    -d 'libc6 (>= 2.31)' -d libgtk-3-0 -d libx11-6 -d libvulkan1 -d libpulse0 -d curl \
    -p "$output/PS5PCEM-$version-linux-x64.deb" .
fpm "${common[@]}" -t rpm --rpm-compression xz \
    -d 'glibc >= 2.31' -d gtk3 -d libX11 -d vulkan-loader -d pulseaudio-libs -d curl \
    -p "$output/PS5PCEM-$version-linux-x64.rpm" .
fpm "${common[@]}" -t pacman --pacman-compression zstd \
    -d glibc -d gtk3 -d libx11 -d vulkan-icd-loader -d libpulse -d curl \
    -p "$output/PS5PCEM-$version-linux-x64.pacman" .
appdir="$stage/PS5PCEM.AppDir"
mkdir -p "$appdir"
cp -a "$root/usr" "$appdir/"
install -m755 "$repo/packaging/linux/AppRun" "$appdir/AppRun"
cp "$repo/packaging/linux/ps5pcem.desktop" "$appdir/ps5pcem.desktop"
cp "$repo/assets/branding/ps5pcem-icon-256.png" "$appdir/ps5pcem.png"
ARCH=x86_64 "$appimagetool" --appimage-extract-and-run --no-appstream "$appdir" "$output/PS5PCEM-$version-linux-x64.AppImage"
printf 'Staging directory: %s\n' "$stage"
sha256sum "$output/PS5PCEM-$version-linux-x64."{deb,rpm,pacman,AppImage}
