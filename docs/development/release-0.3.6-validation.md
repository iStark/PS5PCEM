# Release 0.3.6 validation — October 30, 2026

Feature range: the **71 commits** after `v0.3.5` through `4112eea`, including
merged contributor history. Release preparation updates version metadata,
release/download documentation and packaging. It does not add a new game
benchmark or repeat the maintainer's completed playthroughs.

## Builds and tests

- Zig **0.16.0**, ReleaseFast, **x86-64-v3** CPU baseline.
- Windows launcher, runner, extractor and pinned DXC runtime: **22/22 build
  steps pass**. Launcher and runner PE file/product versions are **0.3.6**.
- Linux `x86_64-linux-gnu.2.31` launcher, runner, extractor and launcher tests:
  **20/20 build steps pass**. The runner's image base remains 2 TiB. Dynamic
  symbols require at most glibc 2.29 (runner) / 2.28 (launcher), below the 2.31
  build baseline; the extractor has no dynamic glibc imports.
- Fresh ReleaseSafe Windows suites: **1,406/1,406 tests pass** — 734 HLE,
  326 GPU analysis, 267 Vulkan, 48 D3D12, 16 runtime, 12 ZArchive and 3 launcher.
- The cross-built Linux launcher suite runs under Ubuntu / WSL2:
  **10/10 tests pass**, including saved settings, UTF-8 and FPS-limit values.
- Native D3D12 hardware probes pass on the RTX 3070 Ti, including resource
  formats, depth/stencil, mixed MRT, arrays/mips, retained resources and
  command groups. Deliberately invalid shader inputs produce expected errors.
- The native Vulkan alpha-preservation check passes all **65,536 half-float
  alpha bit patterns**, with four source values and byte-identical RGBA output.

The broad RDNA2 suite's previously documented ten failures and leak are not
claimed fixed. That suite was not rerun as part of this packaging checkpoint.
The successful focused suites above are the release verification scope.

## Linux packages

DEB, RPM, Pacman and AppImage contain matching stripped ELF payloads for the
three applications, desktop/icon files, license and version/release guides.
Archive comparison verifies matching binaries and 0755 executable modes;
there are no world-writable regular files. Staging uses a Linux filesystem.

The DEB upgrades 0.3.5 to **0.3.6-1** successfully in Ubuntu / WSL2.
`ps5pcem --version` and `--check-install` pass and select the user's XDG
configuration/data directories. AppImage extraction/run passes the same
checks. Its GTK launcher stays alive during a bounded five-second Xvfb check.
RPM/Pacman metadata and contents are verified; this is not a Fedora or Arch
installation test. No physical Linux GPU, audio, controller or game FPS claim
follows from these packaging checks.

Official AppImage appimagetool used for packaging, SHA-256:
`793fca0ce4bcc309dc65d3f66669f58e3755643e4dadbe03932e7b436128494f`.

## Windows packaging and signatures

The launcher, runner, extractor and Inno installer use the existing
`CN=Artur Strazewicz, O=PS5PCEM` code-signing certificate:
`50032C48F83F56327AB0C97B58C12A9696F92456`.
All four carry SHA-256 Authenticode signatures and timestamps. Verification
uses the project signer as the explicit trust anchor and the system timestamp
CA store. This does not install trust roots or claim public publisher trust;
the self-signed certificate can still cause Windows/SmartScreen warnings.

The portable ZIP and installer include matching `dxcompiler.dll` / `dxil.dll`
and Microsoft's three license notices. Those vendor files retain their
original bytes and signatures. Portable application payloads are compared
with the signed staging files; Inno builds the installer from that same stage.
The installed `innoextract` 1.9 does not support this Inno format, so an
independent installer extraction/install check is not claimed. Games, keys,
saves, caches, local settings and debug PDBs are excluded.

`SHA256SUMS.txt` covers all six downloadable packages. The publishing script
checks their digests and Windows signature/timestamp presence before creating
the release. Download metadata on the website comes from the published GitHub
release; historical run dates and measured FPS remain unchanged.

Build and validation logs are retained locally under
`C:\PS5PCEM-builds\release-036`. The published checksum file is the authority
for the downloadable bytes.
