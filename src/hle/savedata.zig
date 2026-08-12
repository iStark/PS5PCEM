// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Where a title's saved games live on the host.
//!
//! A title addresses its saves through a mount point it asks the firmware for,
//! never through a host path, and it expects what it wrote to still be there
//! the next time it runs. That means two things this module owns: a stable
//! place on disk keyed by the title, and a slot name supplied by the guest that
//! must never be allowed to name anything outside it.
//!
//! The layout follows the console's own: one directory per title, one per save
//! slot inside it, and the slot's descriptive parameters under `sce_sys` beside
//! the title's own files. Keeping the shape recognizable means a save copied off
//! a console, or off another emulator using the same convention, lands where a
//! title looks for it.

const std = @import("std");

/// The longest slot name a title can ask for. The firmware fixes this at
/// thirty-two bytes including the terminator, and a longer request is a
/// malformed one rather than something to truncate silently.
pub const maximum_slot_name = 32;

/// Substituted for a slot name that cannot be used as a directory. A guest is
/// free to send an empty or hostile name, and refusing the mount outright would
/// lose the save; putting it somewhere predictable does not.
pub const fallback_slot_name = "default";

pub const maximum_path = 1024;

/// Descriptive parameters a title attaches to a slot.
///
/// These are what a save browser shows. They belong to the slot rather than to
/// the files inside it, because a title sets them through the save API and
/// never writes them itself.
pub const Parameters = struct {
    title: []const u8 = "",
    subtitle: []const u8 = "",
    detail: []const u8 = "",
    user_parameter: u32 = 0,
};

/// Whether a byte can stand in a host path segment.
///
/// The set is deliberately narrow. A slot name arrives from the guest, and the
/// separators, the drive colon and the parent link are exactly what would let
/// it escape the title's own directory.
fn isUsableInName(byte: u8) bool {
    return switch (byte) {
        '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0 => false,
        else => byte >= 0x20,
    };
}

/// Copies a guest-supplied name into something safe to use as a directory.
///
/// Unusable bytes become underscores rather than being dropped, so two distinct
/// names cannot collapse onto one another and have their saves overwrite.
pub fn sanitizeName(name: []const u8, storage: []u8) []const u8 {
    var length: usize = 0;
    for (name) |byte| {
        if (byte == 0) break;
        if (length == storage.len) break;
        storage[length] = if (isUsableInName(byte)) byte else '_';
        length += 1;
    }
    // A name of nothing but spaces or dots is not a usable directory on
    // Windows, and trailing ones are silently stripped by the filesystem.
    while (length > 0 and (storage[length - 1] == ' ' or storage[length - 1] == '.')) length -= 1;
    var start: usize = 0;
    while (start < length and storage[start] == ' ') start += 1;
    if (start == length) return fallback_slot_name;
    return storage[start..length];
}

/// Reads a fixed-width name out of guest memory, stopping at its terminator.
pub fn boundedName(bytes: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..end];
}

/// Joins the parts of a save path with the host separator.
///
/// Returns null rather than a truncated path: a shortened path names a
/// different directory, and creating one silently would scatter a title's
/// saves across two places.
pub fn joinPath(storage: []u8, parts: []const []const u8) ?[]const u8 {
    var length: usize = 0;
    for (parts, 0..) |part, index| {
        if (part.len == 0) continue;
        if (index != 0 and length != 0) {
            if (length == storage.len) return null;
            storage[length] = std.fs.path.sep;
            length += 1;
        }
        if (length + part.len > storage.len) return null;
        @memcpy(storage[length..][0..part.len], part);
        length += part.len;
    }
    return if (length == 0) null else storage[0..length];
}

/// The directory holding every slot of one title.
pub fn titlePath(storage: []u8, root: []const u8, title_id: []const u8) ?[]const u8 {
    var identifier: [maximum_slot_name]u8 = undefined;
    const safe = sanitizeName(title_id, &identifier);
    return joinPath(storage, &.{ root, safe });
}

/// One save slot of one title.
pub fn slotPath(
    storage: []u8,
    root: []const u8,
    title_id: []const u8,
    slot: []const u8,
) ?[]const u8 {
    var identifier: [maximum_slot_name]u8 = undefined;
    const safe_title = sanitizeName(title_id, &identifier);
    var slot_storage: [maximum_slot_name]u8 = undefined;
    const safe_slot = sanitizeName(slot, &slot_storage);
    return joinPath(storage, &.{ root, safe_title, safe_slot });
}

/// The directory a slot's descriptive parameters and icon live in.
pub const metadata_directory = "sce_sys";
pub const parameter_file = "param.txt";
pub const icon_file = "icon0.png";

/// The blob behind the memory-backed save API.
///
/// It is one buffer per title rather than per slot: the API has no slot to
/// name, and a title that uses it expects the same bytes back whichever save it
/// later mounts.
pub const memory_directory = "sce_sdmemory";
pub const memory_file = "memory.dat";

/// Serializes slot parameters.
///
/// A line-oriented form rather than a structured one: the values are short
/// strings a title chose, the file is written far more often than it is read,
/// and a half-written line stays recognizable where a truncated structured
/// document would not parse at all.
pub fn encodeParameters(storage: []u8, parameters: Parameters) ?[]const u8 {
    var length: usize = 0;
    if (!appendRecord(storage, &length, "title", singleLine(parameters.title))) return null;
    if (!appendRecord(storage, &length, "subtitle", singleLine(parameters.subtitle))) return null;
    if (!appendRecord(storage, &length, "detail", singleLine(parameters.detail))) return null;
    var number: [16]u8 = undefined;
    const digits = std.fmt.bufPrint(&number, "{d}", .{parameters.user_parameter}) catch return null;
    if (!appendRecord(storage, &length, "user", digits)) return null;
    return storage[0..length];
}

fn appendRecord(storage: []u8, length: *usize, key: []const u8, value: []const u8) bool {
    for ([_][]const u8{ key, "=", value, "\n" }) |piece| {
        if (length.* + piece.len > storage.len) return false;
        @memcpy(storage[length.*..][0..piece.len], piece);
        length.* += piece.len;
    }
    return true;
}

/// Newlines would split one value across two records, so they are folded away
/// before the value is written rather than escaped.
fn singleLine(value: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, value, "\r\n") orelse return value;
    return value[0..end];
}

/// Reads back what `encodeParameters` wrote. Unknown keys are ignored so an
/// older build can still read a file a newer one produced.
pub fn decodeParameters(text: []const u8) Parameters {
    var parameters = Parameters{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        // A file written on one host and read on another keeps its line ends.
        var line = raw;
        while (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..separator];
        const value = line[separator + 1 ..];
        if (std.mem.eql(u8, key, "title")) parameters.title = value;
        if (std.mem.eql(u8, key, "subtitle")) parameters.subtitle = value;
        if (std.mem.eql(u8, key, "detail")) parameters.detail = value;
        if (std.mem.eql(u8, key, "user")) {
            parameters.user_parameter = std.fmt.parseInt(u32, value, 10) catch 0;
        }
    }
    return parameters;
}


/// Where a title's identity is recorded in its own installation.
pub const title_parameter_path = "sce_sys/param.json";

/// Pulls a string field out of the title's parameter document.
///
/// A whole JSON parser is not warranted here: the two values wanted are
/// top-level strings in a file the title ships and never rewrites, and scanning
/// for the key avoids pulling a document model and an allocator into a path
/// that runs once at startup. A key that is absent or not a string yields
/// nothing rather than a guess.
pub fn findJsonString(document: []const u8, key: []const u8, storage: []u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < document.len) {
        const quote = std.mem.indexOfScalarPos(u8, document, cursor, '"') orelse return null;
        const key_end = std.mem.indexOfScalarPos(u8, document, quote + 1, '"') orelse return null;
        const found = document[quote + 1 .. key_end];
        cursor = key_end + 1;
        if (!std.mem.eql(u8, found, key)) continue;

        // Only a string value is accepted; a number or an object under this key
        // means the document is not shaped the way this expects.
        var value = key_end + 1;
        while (value < document.len and (document[value] == ' ' or document[value] == '\t')) value += 1;
        if (value >= document.len or document[value] != ':') continue;
        value += 1;
        while (value < document.len and
            (document[value] == ' ' or document[value] == '\t' or
                document[value] == '\r' or document[value] == '\n')) value += 1;
        if (value >= document.len or document[value] != '"') continue;
        const text_end = std.mem.indexOfScalarPos(u8, document, value + 1, '"') orelse return null;
        const text = document[value + 1 .. text_end];
        if (text.len > storage.len) return null;
        @memcpy(storage[0..text.len], text);
        return storage[0..text.len];
    }
    return null;
}

/// The identity a title publishes about itself.
pub const Identity = struct {
    /// The product code saves are keyed by, such as `PPSA25872`.
    title_id: []const u8,
    /// The name to show a player, which is not always the directory name.
    title_name: []const u8,
};

test "a hostile slot name cannot leave the title directory" {
    var storage: [maximum_slot_name]u8 = undefined;
    try std.testing.expectEqualStrings(".._.._etc", sanitizeName("../../etc", &storage));
    try std.testing.expectEqualStrings("C_boot", sanitizeName("C:boot", &storage));
    try std.testing.expectEqualStrings("a_b", sanitizeName("a\\b", &storage));
}

test "a name that cannot be a directory falls back rather than being lost" {
    var storage: [maximum_slot_name]u8 = undefined;
    try std.testing.expectEqualStrings(fallback_slot_name, sanitizeName("", &storage));
    try std.testing.expectEqualStrings(fallback_slot_name, sanitizeName("   ", &storage));
    // Windows strips trailing dots and spaces, which would make two distinct
    // names open the same directory.
    try std.testing.expectEqualStrings("save", sanitizeName("save. ", &storage));
}

test "distinct names stay distinct after sanitizing" {
    var first: [maximum_slot_name]u8 = undefined;
    var second: [maximum_slot_name]u8 = undefined;
    const left = sanitizeName("slot/one", &first);
    const right = sanitizeName("slot|one", &second);
    // Both characters are unusable, but replacing rather than dropping keeps
    // the two names apart so neither save overwrites the other.
    try std.testing.expectEqualStrings("slot_one", left);
    try std.testing.expectEqualStrings("slot_one", right);
    const different = sanitizeName("slotone", &first);
    try std.testing.expect(!std.mem.eql(u8, different, right));
}

test "a guest name stops at its terminator" {
    try std.testing.expectEqualStrings("SAVE00", boundedName("SAVE00\x00\x00garbage"));
    try std.testing.expectEqualStrings("SAVE00", boundedName("SAVE00"));
}

test "slot paths nest the title and the slot under the root" {
    var storage: [maximum_path]u8 = undefined;
    const path = slotPath(&storage, "saves", "PPSA25872", "SAVE00") orelse
        return error.TestFailed;
    const separator = std.fs.path.sep_str;
    try std.testing.expectEqualStrings(
        "saves" ++ separator ++ "PPSA25872" ++ separator ++ "SAVE00",
        path,
    );
}

test "a path that would not fit is refused rather than truncated" {
    var storage: [8]u8 = undefined;
    // A shortened path names a different directory, so producing one would
    // scatter a title's saves instead of failing the mount.
    try std.testing.expect(slotPath(&storage, "saves", "PPSA25872", "SAVE00") == null);
}

test "parameters survive a round trip" {
    var storage: [512]u8 = undefined;
    const encoded = encodeParameters(&storage, .{
        .title = "Chapter 3",
        .subtitle = "The Bridge",
        .detail = "62% complete",
        .user_parameter = 7,
    }) orelse return error.TestFailed;

    const decoded = decodeParameters(encoded);
    try std.testing.expectEqualStrings("Chapter 3", decoded.title);
    try std.testing.expectEqualStrings("The Bridge", decoded.subtitle);
    try std.testing.expectEqualStrings("62% complete", decoded.detail);
    try std.testing.expectEqual(@as(u32, 7), decoded.user_parameter);
}

test "a newline inside a value cannot forge a second record" {
    var storage: [512]u8 = undefined;
    const encoded = encodeParameters(&storage, .{
        .title = "Chapter 3\nuser=99",
        .subtitle = "kept",
    }) orelse return error.TestFailed;
    const decoded = decodeParameters(encoded);
    try std.testing.expectEqualStrings("Chapter 3", decoded.title);
    try std.testing.expectEqualStrings("kept", decoded.subtitle);
    try std.testing.expectEqual(@as(u32, 0), decoded.user_parameter);
}

test "missing keys keep their defaults" {
    const decoded = decodeParameters("title=Only\nunknown=ignored\n");
    try std.testing.expectEqualStrings("Only", decoded.title);
    try std.testing.expectEqualStrings("", decoded.detail);
    try std.testing.expectEqual(@as(u32, 0), decoded.user_parameter);
}

test "a title identifier is read out of its parameter document" {
    const document =
        \\{
        \\  "applicationCategoryType": 0,
        \\  "titleId": "PPSA25872",
        \\  "contentId": "EP4060-PPSA25872_00-T2DNFMAINGAMEPS5"
        \\}
    ;
    var storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings("PPSA25872", findJsonString(document, "titleId", &storage).?);
    try std.testing.expect(findJsonString(document, "missing", &storage) == null);
}

test "a non-string value under the wanted key is not mistaken for one" {
    var storage: [64]u8 = undefined;
    // The number must not be read, and the search must carry on to the real
    // string that follows.
    const document =
        \\{ "titleId": 12345, "other": "x", "titleId": "PPSA00001" }
    ;
    try std.testing.expectEqualStrings("PPSA00001", findJsonString(document, "titleId", &storage).?);
}

test "a value too long for the caller's storage is refused" {
    var storage: [4]u8 = undefined;
    try std.testing.expect(findJsonString("{\"titleId\": \"PPSA25872\"}", "titleId", &storage) == null);
}
