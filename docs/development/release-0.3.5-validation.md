# Release 0.3.5 validation — October 16, 2026

The feature range is the 58 commits from `v0.3.4` through `0e6d2e9`.
Release preparation updates versions, adds Linux packaging and fixes writable
data paths for installed Linux applications/AppImages. It also corrects the
runner's Linux usage text and exposes launcher test/install checks.

## Builds and tests

- Zig 0.16.0, ReleaseFast, x86-64-v3 baseline: all three Windows application
  targets build, **16/16 steps**. Launcher and runner file/product versions
  are **0.3.5**; the extractor has no Windows version resource.
- Cross-built `x86_64-linux-gnu.2.31`: all three application targets build,
  **16/16 steps**. The runner retains its 2 TiB image base outside guest memory.
  ELF inspection finds no glibc requirement above the selected 2.31 baseline.
- Fresh Windows **1,263/1,263 tests pass**: 679 HLE, 308 GPU analysis,
  274 Vulkan and 2 launcher tests. The suite's expected diagnostic stderr
  does not represent failing tests; the build exits successfully.
- The Linux launcher test executable runs under Ubuntu 24.04 / WSL2:
  **9/9 pass**, covering shared release versions, settings, UTF-8, keyboard
  mappings, save parameters and presets.
- `zig fmt --check`, shell syntax and PowerShell parsing checks pass.

The broad RDNA2 suite's ten previously documented failures and reported leak
are not claimed fixed. Native graphics probes from the latest resource-walk
checkpoint remain historical evidence; release packaging does not constitute
another game benchmark or full playthrough.

## Linux distribution checks

- DEB, RPM, Pacman and AppImage contain the same three Linux ELF applications,
  desktop entry, icon, license, version and installation/release documentation.
- Packages are built on a Linux filesystem to retain **0755 directories and
  executables / 0644 documentation**. NTFS staging was rejected after archive
  inspection exposed excessively broad inherited permissions.
- The DEB installs successfully with `dpkg -i` in Ubuntu 24.04 / WSL2.
  `ps5pcem --version` prints 0.3.5. `--check-install` locates GTK and both
  companion executables and selects the user's XDG config/data paths instead
  of `/usr/lib/ps5pcem`.
- AppImage `--appimage-extract-and-run --version` and `--check-install` pass.
  A separate Xvfb launch stays alive for a bounded five-second startup check,
  without an unexpected GTK exit. No game or visual correctness claim follows
  from this process-liveness check.
- RPM/Pacman metadata and archive contents are inspected on Ubuntu. These are
  **not** install tests on Fedora or Arch Linux. Physical Linux GPU, controller,
  audio quality and title performance are not revalidated for this release.
- Official appimagetool download used for packaging, SHA-256:
  `95cbe7cce9717fce90c484e34052ee7c7f1d7635b33c12525b4776826a7d29b6`.

## Windows signing and publication safeguards

The launcher, runner and extractor are signed with the existing certificate
`50032C48F83F56327AB0C97B58C12A9696F92456`, subject
`CN=Artur Strazewicz, O=PS5PCEM`, and DigiCert SHA-256 timestamps. Signer and
timestamp presence are checked. The self-signed chain still reports
`UnknownError` on this host; no trust-store changes are made and no
Windows-trusted publisher status is claimed.

`scripts/package-release.ps1` signs the staged applications and Inno installer,
then hashes the portable ZIP, installer and four Linux packages.
`scripts/publish-release.ps1` requires all six artifacts, matching SHA-256
entries, timestamped Windows signatures and a clean main branch before tagging
and publishing. Linux packages are not Authenticode-signed.

Local build, test and packaging logs use the `.codex-release035-*` prefix.
The published checksums are the authority for downloadable package bytes.
Screenshots in the release notes are the existing dated ASTRO BOT, Raiden IV
and GTA III captures; their original scope and limitations are preserved.
