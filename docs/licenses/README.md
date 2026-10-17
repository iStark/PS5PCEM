# Bundled dependency notices

The Windows runner links the following dependencies. These files reproduce the
upstream notices from the source versions pinned in `build.zig.zon`.

| Dependency | Pinned source | Notices |
|---|---|---|
| LibAtrac9 | `shadps4-emu/ext-LibAtrac9`, commit `946e05a9212976626a9f5e52f29c0a7202871f29` | [MIT license](LibAtrac9-LICENSE.txt) |
| minimp3 | `lieff/minimp3`, commit `7b590fdcfa5a79c033e76eacc05d0c3e4c79f536` | [CC0 text](minimp3-LICENSE.txt) |
| FAAD2 | `knik0/faad2`, version `2.11.2` | [GPL text](FAAD2-COPYING.txt), [upstream README and copyright notices](FAAD2-README.txt) |
| Opus | `xiph/opus`, version `1.5.2` | [BSD license](Opus-COPYING.txt), [upstream licensing note](Opus-LICENSE_PLEASE_READ.txt) |
| FreeType | `freetype/freetype`, version `2.14.3` | [FreeType License](FreeType-FTL.txt) |
| Noto Sans (Regular, Light, Light Italic, Medium, Bold, Black) | `notofonts/noto-fonts`, commit `ffebf8c1ee449e544955a7e813c54f9b73848eac` | [SIL Open Font License 1.1 and copyright notice](NotoSans-OFL.txt) |
| Noto Sans JP (Medium, Black) | `notofonts/noto-cjk`, commit `f8d157532fbfaeda587e826d4cd5b21a49186f7c` | [SIL Open Font License 1.1 and copyright notice](NotoSansCJK-OFL.txt) |
| SPIRV-Cross (Windows D3D12 backend) | `KhronosGroup/SPIRV-Cross`, commit `a0fba56c34a6700f1724bf9b751da5b488a3775c` (`vulkan-sdk-1.4.341.0`) | [Apache-2.0 license and copyright notices](SPIRV-Cross-LICENSE.txt) |

Portions of this software are copyright © 2026 The FreeType Project
(https://freetype.org). All rights reserved.

The unmodified Noto fonts are embedded as substitutes for system-font
requests and for font files a title's dump lacks. Their sources, checksums and
scope are recorded in [the font asset notes](../../src/hle/fonts/README.md).

PS5PCEM's own license is provided in the package's root `LICENSE` file.
