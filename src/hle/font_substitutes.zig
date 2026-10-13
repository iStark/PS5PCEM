// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Freely licensed stand-ins for font files a title ships without.
//!
//! Some dumps lack fonts the title's own data still names: ASTRO BOT's
//! `font_settings.xml` lists Futura, ShinGo, Heisei Maru Gothic and Mohr faces
//! that are absent from its package, and the title asserts as soon as it fails
//! to resolve the first one. Those faces are commercial and cannot be shipped.
//! A missing font file under a title mount is therefore answered with a Noto
//! face (SIL OFL 1.1) of the closest weight and script. The text is legible in
//! a different typeface; nothing claims the original font is present, and a
//! title that ships the file always gets its own.

const std = @import("std");

pub const Substitute = struct {
    /// The bundled face, for the log line that announces the substitution.
    name: []const u8,
    bytes: []const u8,
};

const latin_light = Substitute{ .name = "Noto Sans Light", .bytes = @embedFile("fonts/NotoSans-Light.ttf") };
const latin_light_italic = Substitute{ .name = "Noto Sans Light Italic", .bytes = @embedFile("fonts/NotoSans-LightItalic.ttf") };
const latin_regular = Substitute{ .name = "Noto Sans Regular", .bytes = @embedFile("fonts/NotoSans-Regular.ttf") };
const latin_medium = Substitute{ .name = "Noto Sans Medium", .bytes = @embedFile("fonts/NotoSans-Medium.ttf") };
const latin_bold = Substitute{ .name = "Noto Sans Bold", .bytes = @embedFile("fonts/NotoSans-Bold.ttf") };
const latin_black = Substitute{ .name = "Noto Sans Black", .bytes = @embedFile("fonts/NotoSans-Black.ttf") };
const japanese_medium = Substitute{ .name = "Noto Sans JP Medium", .bytes = @embedFile("fonts/NotoSansJP-Medium.otf") };
const japanese_black = Substitute{ .name = "Noto Sans JP Black", .bytes = @embedFile("fonts/NotoSansJP-Black.otf") };

const Weight = enum { light, regular, medium, bold, black };

/// Whether `path` names a TrueType or OpenType file (or collection).
pub fn isFontPath(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    for ([_][]const u8{ ".otf", ".ttf", ".ttc", ".otc" }) |candidate| {
        if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
    }
    return false;
}

/// The stand-in for a missing font file at `path`, or null if it is not one.
pub fn forPath(path: []const u8) ?Substitute {
    if (!isFontPath(path)) return null;
    var storage: [256]u8 = undefined;
    const base = std.fs.path.basename(path);
    const stem = base[0 .. base.len - std.fs.path.extension(base).len];
    if (stem.len == 0 or stem.len > storage.len) return latin_regular;
    const name = std.ascii.lowerString(&storage, stem);

    const weight = weightOf(name);
    if (isJapanese(name)) return if (@intFromEnum(weight) >= @intFromEnum(Weight.bold)) japanese_black else japanese_medium;
    if (isItalic(name)) return latin_light_italic;
    return switch (weight) {
        .light => latin_light,
        .regular => latin_regular,
        .medium => latin_medium,
        .bold => latin_bold,
        .black => latin_black,
    };
}

fn contains(name: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, name, part) != null;
}

/// Japanese gothic and rounded faces by family name. Their Latin glyphs are
/// in the Japanese stand-in too, so a misjudged family still renders text.
fn isJapanese(name: []const u8) bool {
    for ([_][]const u8{ "shingo", "marugo", "heisei", "gothic", "mincho", "hiragino", "kozuka", "jp" }) |family| {
        if (contains(name, family)) return true;
    }
    return false;
}

/// Weight from the style part of the name, after the family. Abbreviations
/// such as `Bd`, `Blk` and `XBd` are matched as whole style words.
fn weightOf(name: []const u8) Weight {
    const style = if (std.mem.lastIndexOfAny(u8, name, "-_ ")) |cut| name[cut + 1 ..] else name;
    for ([_][]const u8{ "black", "blk", "heavy", "xbd", "extrabold", "ultra" }) |word| {
        if (contains(style, word)) return .black;
    }
    for ([_][]const u8{ "bold", "semibold", "demi" }) |word| {
        if (contains(style, word)) return if (std.mem.eql(u8, word, "bold") and !contains(style, "semi")) .bold else .medium;
    }
    if (std.mem.eql(u8, style, "bd")) return .bold;
    if (contains(style, "medium") or std.mem.eql(u8, style, "md")) return .medium;
    for ([_][]const u8{ "light", "thin", "lt" }) |word| {
        if (contains(style, word)) return .light;
    }
    return .regular;
}

/// `Italic`, `Oblique`, or a style ending in `It` such as Mohr's `LightIt`.
fn isItalic(name: []const u8) bool {
    if (contains(name, "italic") or contains(name, "oblique")) return true;
    const style = if (std.mem.lastIndexOfAny(u8, name, "-_ ")) |cut| name[cut + 1 ..] else return false;
    return std.mem.endsWith(u8, style, "it");
}

test "missing title fonts map to the closest bundled weight and script" {
    const expect = std.testing.expectEqualStrings;
    try expect("Noto Sans JP Black", forPath("/app0/data/common/font/SIE-ShinGoPr6N-Heavy.otf").?.name);
    try expect("Noto Sans JP Medium", forPath("/app0/data/common/font/HeiseiMaruGo.TTF").?.name);
    try expect("Noto Sans Bold", forPath("data/common/font/FuturaNowText-Bd.otf").?.name);
    try expect("Noto Sans Black", forPath("data/common/font/FuturaNowText-Blk.otf").?.name);
    try expect("Noto Sans Regular", forPath("data/common/font/FuturaStd-Book.otf").?.name);
    try expect("Noto Sans Light", forPath("data/common/font/FuturaStd-Light.otf").?.name);
    try expect("Noto Sans Medium", forPath("data/common/font/FuturaStd-Medium.otf").?.name);
    try expect("Noto Sans Light Italic", forPath("data/common/font/Mohr-LightIt.otf").?.name);
    try expect("Noto Sans Light", forPath("data/common/font/FuturaStd-CondensedLight.otf").?.name);
    try std.testing.expect(forPath("/app0/data/common/font_settings.xml") == null);
    try std.testing.expect(forPath("/app0/eboot.bin") == null);
}

test "every bundled stand-in is a TrueType or OpenType file" {
    for ([_]Substitute{ latin_light, latin_light_italic, latin_regular, latin_medium, latin_bold, latin_black, japanese_medium, japanese_black }) |face| {
        const tag = face.bytes[0..4];
        try std.testing.expect(std.mem.eql(u8, tag, &.{ 0, 1, 0, 0 }) or std.mem.eql(u8, tag, "OTTO"));
    }
}
