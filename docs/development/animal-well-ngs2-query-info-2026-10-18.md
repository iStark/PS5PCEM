# Animal Well: missing NGS2 voice query — October 18, 2026

[Issue #7](https://github.com/iStark/PS5PCEM/issues/7) reports that Animal Well
(PPSA22520, v01.000.011) stops at the linker with unresolved NID
`9eic4AmjGVI` from `libSceNgs2`. The NID is `sceNgs2VoiceQueryInfo`.

## Implementation

The HLE registry now exports the function under its derived NID, with an
identifier assertion to catch spelling errors. The `0x4001` channel query
returns the eight-byte `{ num_channels, reserved }` record. Its value comes
from the selected voice, and the reserved word is zero.

Unconfigured voices report zero channels. Sampler and custom-sampler setup,
decoded waveform metadata, and submixer/mastering/reverb/custom-submixer
setup supply the configured channel count. Invalid PCM setup is checked
before replacing a working voice. Mixer setup bookkeeping does not implement
the remaining graph routing or audio effects.

The query checks the record identifier, exact output size, writable memory
range and live voice handle. It supports unaligned output and does not touch
adjacent bytes. Unsupported records return an error rather than success with
an invented layout. Null-output and size errors use the PS5 values verified
in the reference; invalid handles and inaccessible memory use the existing
HLE error conventions.

The ABI, record layout and channel semantics were cross-checked against
AnyPS5 at `81cb8633944e092c0964ee0ad095fe393af85919`:
[voice query](https://github.com/boykopovar/AnyPS5/blob/81cb8633944e092c0964ee0ad095fe393af85919/core/libs/prx/libSceNgs2.native/src/Voice.cpp),
[types](https://github.com/boykopovar/AnyPS5/blob/81cb8633944e092c0964ee0ad095fe393af85919/core/libs/prx/libSceNgs2.native/include/Ngs2Types.hpp)
and [tests](https://github.com/boykopovar/AnyPS5/blob/81cb8633944e092c0964ee0ad095fe393af85919/core/libs/prx/libSceNgs2.native/tests/Ngs2Render.cpp).

## Validation and limits

- `zig build test-hle -Doptimize=ReleaseSafe -Dtest-filter=NGS2 --summary all`:
  **19/19 tests passed**.
- `zig build test-hle -Doptimize=ReleaseSafe --summary all`:
  **689/689 tests passed**.
- `zig build build-game-run -Doptimize=ReleaseSafe --summary all`:
  **15/15 build steps succeeded**. The installed Windows runner starts and
  prints its usage when invoked without a title (expected exit code 1).
- `zig-out/bin/game-run.exe` was signed with the existing Artur Strazewicz /
  PS5PCEM certificate and a DigiCert timestamp. Windows identifies the signer
  and timestamp; the local certificate chain remains untrusted, as with the
  existing project certificate. The signed file's SHA-256 is
  `461eac69331560d3585364b6f869d578d6860d69e6c2cf7f6195dd8780b8f621`.

The regression test resolves the exact library/module/NID from the HLE
registry and calls the registered guest-ABI entry point. Coverage includes
mono, stereo, six- and eight-channel configuration, independent voices,
invalid setup, destroyed handles, reused voice slots, unknown records,
incorrect sizes, unaligned output, canaries, address overflow, read-only
pages and an output range crossing into a read-only page.

No local Animal Well installation was available for an end-to-end run;
the maintainer confirmed that the issue reporter will verify startup.
The missing import and query behavior are covered by tests; this report
does not establish that Animal Well reaches its menu or gameplay, has
working audio, or has no subsequent blockers.
