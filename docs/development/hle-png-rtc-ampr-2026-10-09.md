# PNG encoding, RTC and AMPR export coverage — 9 October 2026

This update implements the 18 missing exports identified in the local KytyPS5
comparison: four PNG encoder functions, eleven RTC functions, and three AMPR
command-size queries. It does not establish a new gameplay or performance
milestone.

## PNG encoding

`libScePngEnc` now provides `scePngEncQueryMemorySize`, `scePngEncCreate`,
`scePngEncEncode`, and `scePngEncDelete`. The caller owns the 16-byte context;
deleting it invalidates the handle without freeing caller memory.

The encoder accepts pitched R8G8B8A8 and B8G8R8A8 input and writes 8-bit RGB or
RGBA PNGs. It respects the permitted filter mask, choosing among Sub, Up,
Average and Paeth per row, or using None when the mask is zero. Levels 1–9 use
Zig's DEFLATE compressor; level 0 emits stored blocks. PNG chunks carry CRC32
checksums and the zlib stream carries Adler32. No GPU or additional codec
dependency is needed.

Validation covers handle lifetime, dimensions, pitch, input/output bounds,
filter count, color format, and compression level. Output writes respect guest
CPU permissions and notify GPU page tracking. Compression completes into
bounded temporary storage before publishing the PNG: a short output buffer
returns the encoder's overflow error, clears the output-info counts, and
leaves the destination bytes unchanged. A buffer exactly the final file size
is accepted. Filtered input is limited to 512 MiB, matching the existing PNG
decoder's resource bound. Palette, grayscale, 16-bit and interlaced output are
not provided by this encoder.

## RTC

New exports are `sceRtcCheckValid`, `sceRtcGetCurrentClock`,
`sceRtcGetDaysInMonth`, `sceRtcGetWin32FileTime`, `sceRtcSetWin32FileTime`, and
`sceRtcTickAdd{Ticks,Microseconds,Seconds,Minutes,Hours,Weeks}`.

Calendar validation reports the first invalid field and handles Gregorian
leap-year rules. FILETIME uses 100 ns units since 1601; conversion to the
microsecond RTC clock truncates the final sub-microsecond digit. Dates before
1601 return zero FILETIME, matching the reviewed reference. Explicit clock
offsets are in signed minutes. Existing local/UTC convenience conversions
retain their current UTC-based behavior; this change does not add host DST
conversion.

Tick arithmetic uses wide intermediates, supports negative increments and
in-place results, and rejects underflow/overflow without changing the output.
`TickAddDays` shares that path. Calendar conversion rejects ticks outside
years 1–9999 before narrowing the year to `u16`. The `INVALID_VALUE` code is
corrected to `0x80B50003`.

## AMPR

The following exports now return the 32-byte size of their existing command
records, using the completion API's actual argument signatures:

- `sceAmprMeasureCommandSizeWriteAddressFromTimeCounterOnCompletion`
- `sceAmprMeasureCommandSizeWriteAddressFromCounterOnCompletion`
- `sceAmprMeasureCommandSizeWriteAddressFromCounterPairOnCompletion`

This completes those missing registrations. Hardware counters are still
incomplete: their existing completion commands encode zero-valued writes,
and counter wait/write operations retain their previous placeholder behavior.
This update does not claim to implement the complete AMPR counter engine.

The subsequent [AMPR counter implementation](ampr-counters-2026-10-09.md)
replaces these counter placeholders and corrects the short counter ABIs;
the test results below describe the earlier export-coverage change.

## Validation and references

The full Windows x86-64 `ReleaseSafe` HLE suite passes **583/583** tests. Focused
runs pass **5/5 PNG**, **8/8 RTC**, and **11/11 AMPR** tests. PNG round trips cover
280 combinations of RGB/RGBA output, RGBA/BGRA input, filter masks, and levels
0–9. Additional checks cover exact output capacity, overflow, invalid pointers,
read-only destinations, leap centuries, FILETIME epochs and precision, wide
tick rejection, signed arithmetic, explicit clock offsets, and AMPR measured
sizes versus emitted records through registered guest ABI functions.

A separate harness resolves all 18 additions and generates 16 PNG fixtures
through registered guest entry points. Pillow independently verifies and
decodes each file, reproducing every source pixel. Python zlib and CRC32
checks validate the compressed data and chunk checksums. Fixtures include
257-by-129 images and 20,000-pixel-wide stored rows spanning multiple DEFLATE
blocks; all **16/16** pass.

The `ReleaseFast` runner build completes **9/9** steps. The installed
`zig-out/bin/game-run.exe` is updated and signed with the existing PS5PCEM
certificate and a DigiCert timestamp. A startup smoke check returns the
expected `FileNotFound` for a deliberately absent guest executable.

ABI layouts, export identifiers, and baseline behavior were checked against
KytyPS5 `79a91ecfafea899e25dc0df0df6ffb55a8f3cc58`, in
`src/libs/libPngEnc.cpp`, `libRtc.cpp`, and `libAmpr.cpp`. The local AnyPS5
`core/libs/prx/libSceRtc/Export.cpp` also corroborates the RTC error values and
epoch constants. Implementations use PS5PCEM's existing memory, symbol, and
command-stream infrastructure.
