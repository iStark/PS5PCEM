# Font assets

Every file here is an unmodified, freely licensed Noto font. None is a console
firmware font or a font from any title.

`NotoSans-Regular.ttf` is the fallback for firmware system-font requests. It
covers Latin, Greek and Cyrillic; it does not substitute every system font or
provide CJK coverage. Games can supply their own TrueType/OpenType fonts through
`sceFontOpenFontMemory`.

The other faces answer font files a title's data names but its dump lacks
(see `font_substitutes.zig`). ASTRO BOT, for example, asks for Futura, ShinGo,
Heisei Maru Gothic and Mohr faces that are commercial and absent from its
package; it asserts when the first lookup fails. The closest Noto weight is
served instead, so text renders in a different typeface rather than not at all.

| File | Source | SHA-256 |
| --- | --- | --- |
| `NotoSans-Regular.ttf` | [notofonts/noto-fonts](https://github.com/notofonts/noto-fonts/blob/ffebf8c1ee449e544955a7e813c54f9b73848eac/hinted/ttf/NotoSans/NotoSans-Regular.ttf) | `b85c38ecea8a7cfb39c24e395a4007474fa5a4fc864f6ee33309eb4948d232d5` |
| `NotoSans-Light.ttf` | same commit, `hinted/ttf/NotoSans/` | `74ffdd438f2ae232371ceb00444dae93e2590d263a4ff4c5e2c8385aa8012fdb` |
| `NotoSans-LightItalic.ttf` | same commit, `hinted/ttf/NotoSans/` | `701297fd68809f0834632aa93a5ec3e16e072aa6cbe153fdb0a827422ecc94da` |
| `NotoSans-Medium.ttf` | same commit, `hinted/ttf/NotoSans/` | `7bbe267354704c6ad18bde24b1dbc756c8e4380ca1c3f3c25c45ec5c4471510b` |
| `NotoSans-Bold.ttf` | same commit, `hinted/ttf/NotoSans/` | `c976e4b1b99edc88775377fcc21692ca4bfa46b6d6ca6522bfda505b28ff9d6a` |
| `NotoSans-Black.ttf` | same commit, `hinted/ttf/NotoSans/` | `2ea74ab862678045678cd0843e12fa17e100e7ad10b20f220fea6bb7b0ae88a5` |
| `NotoSansJP-Medium.otf` | [notofonts/noto-cjk](https://github.com/notofonts/noto-cjk/blob/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/SubsetOTF/JP/NotoSansJP-Medium.otf) | `f396a3b57256e4515be9cb41f7aac54766d654890082a9f1b5c2451b5c093d8a` |
| `NotoSansJP-Black.otf` | same commit, `Sans/SubsetOTF/JP/` | `3aa30b0956510f4205f759ab3079a5b658310ebcda2577f290466ea51c948819` |

Licenses: [Noto Sans, SIL OFL 1.1](../../../docs/licenses/NotoSans-OFL.txt);
[Noto Sans CJK, SIL OFL 1.1](../../../docs/licenses/NotoSansCJK-OFL.txt).

FreeType 2.14.3 is fetched with a pinned content hash in `build.zig.zon` and
statically linked. `ps5pcem_ft_modules.h` selects TrueType, CFF, SFNT and their
support modules. GPOS pair kerning is enabled. No external font DLL or host font
installation is required. See the [FreeType license](../../../docs/licenses/FreeType-FTL.txt).
