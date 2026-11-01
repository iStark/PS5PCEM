// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Optional, executable-specific patches of the loader's private file buffer.
//! No game file is written. All identity and byte guards pass before any edit.

const std = @import("std");
const elf = @import("elf.zig");

pub const Mode = enum {
    auto,
    off,
    astro_bot_1080p,

    pub fn parse(text: []const u8) error{InvalidGamePatchMode}!Mode {
        const value = std.mem.trim(u8, text, " \t\r\n");
        if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(value, "off")) return .off;
        if (std.ascii.eqlIgnoreCase(value, "astro-bot-1080p")) return .astro_bot_1080p;
        return error.InvalidGamePatchMode;
    }
};

pub const Profile = enum { astro_bot_1080p };
pub const Result = enum { not_requested, applied, unsupported_executable };

pub fn select(mode: Mode, title_id: []const u8, output_height: u32) error{UnsupportedPatchTitle}!?Profile {
    if (mode == .off) return null;
    const supported = std.ascii.eqlIgnoreCase(title_id, "PPSA21564");
    if (mode == .astro_bot_1080p) {
        if (!supported) return error.UnsupportedPatchTitle;
        return .astro_bot_1080p;
    }
    return if (supported and output_height == 1080) .astro_bot_1080p else null;
}

const Guard = struct {
    address: u64,
    before: []const u8,
    after: ?[]const u8 = null,
};

// Resolution selector and all three setter/table copies from the ASTRO BOT
// 01.018 profiles in iska0702/DLSSKytyPS5, _Patches/PPSA21567.json.
// Independently verified against PPSA21564 01.018.000 below. Mode zero already
// means 1920x1080, so only the selector changes; every dimension remains guarded.
// The unrelated GI, timing, physics and DLSS/FSR options are not part of this patch.
const astro_guards = [_]Guard{
    .{ .address = 0xc62a97, .before = "\x8b\x83\xf0\x23\x00\x00", .after = "\xb8\x00\x00\x00\x00\x90" },
    .{ .address = 0x7405d3d, .before = "\xc7\x07\x80\x07\x00\x00" },
    .{ .address = 0x7405d43, .before = "\xc7\x06\x38\x04\x00\x00" },
    .{ .address = 0x7405dd8, .before = "\xc7\x07\x80\x07\x00\x00" },
    .{ .address = 0x7405dde, .before = "\xc7\x06\x38\x04\x00\x00" },
    .{ .address = 0x739e99d, .before = "\xc7\x07\x80\x07\x00\x00" },
    .{ .address = 0x739e9a3, .before = "\xc7\x06\x38\x04\x00\x00" },
    .{ .address = 0x8484994, .before = "\x80\x07\x00\x00" },
    .{ .address = 0x8484980, .before = "\x38\x04\x00\x00" },
    .{ .address = 0x8714510, .before = "\x80\x07\x00\x00" },
    .{ .address = 0x8714524, .before = "\x38\x04\x00\x00" },
    .{ .address = 0x87f1e40, .before = "\x80\x07\x00\x00" },
    .{ .address = 0x87f1e54, .before = "\x38\x04\x00\x00" },
};

pub fn apply(profile: Profile, bytes: []u8) !Result {
    const expected = switch (profile) {
        .astro_bot_1080p => "aaef7a00968bebdeae17c0ee874cc0a9dbadf412c833cb1a9e1428c0ddc24aaa",
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected)) return .unsupported_executable;
    const image = try elf.parse(bytes);
    try applyGuards(bytes, image, &astro_guards);
    return .applied;
}

fn applyGuards(bytes: []u8, image: elf.Image, guards: []const Guard) !void {
    if (image.bytes.ptr != bytes.ptr or image.bytes.len != bytes.len) return error.InvalidPatchBuffer;
    // Retain the resolved file offsets so no fallible operation occurs after
    // the first write. SELF physical offsets differ from ELF virtual addresses.
    var offsets: [astro_guards.len]usize = undefined;
    if (guards.len > offsets.len) return error.TooManyPatchGuards;
    for (guards, 0..) |guard, i| {
        if (guard.before.len == 0) return error.EmptyPatchGuard;
        if (guard.after) |after| {
            if (after.len != guard.before.len) return error.PatchSizeMismatch;
        }
        const original = try image.virtualRange(guard.address, guard.before.len);
        if (!std.mem.eql(u8, original, guard.before)) return error.PatchByteMismatch;
        offsets[i] = @intFromPtr(original.ptr) - @intFromPtr(bytes.ptr);
        for (guards[0..i], offsets[0..i]) |previous, offset| {
            if (offsets[i] < offset + previous.before.len and offset < offsets[i] + guard.before.len)
                return error.OverlappingPatchGuards;
        }
    }
    for (guards, offsets[0..guards.len]) |guard, offset| {
        if (guard.after) |after| @memcpy(bytes[offset..][0..after.len], after);
    }
}

test "game patches select only the requested title and display mode" {
    try std.testing.expectEqual(Profile.astro_bot_1080p, (try select(.auto, "PPSA21564", 1080)).?);
    try std.testing.expectEqual(@as(?Profile, null), try select(.auto, "PPSA26344", 1080));
    try std.testing.expectEqual(@as(?Profile, null), try select(.auto, "PPSA21567", 1080));
    try std.testing.expectEqual(@as(?Profile, null), try select(.auto, "PPSA21564", 2160));
    try std.testing.expectEqual(@as(?Profile, null), try select(.off, "PPSA21564", 1080));
    try std.testing.expectEqual(Profile.astro_bot_1080p, (try select(.astro_bot_1080p, "PPSA21564", 2160)).?);
    try std.testing.expectError(error.UnsupportedPatchTitle, select(.astro_bot_1080p, "PPSA26344", 1080));
    try std.testing.expectEqual(Mode.off, try Mode.parse("off"));
    try std.testing.expectEqual(Mode.auto, try Mode.parse(""));
    try std.testing.expectEqual(Mode.astro_bot_1080p, try Mode.parse("astro-bot-1080p"));
    try std.testing.expectError(error.InvalidGamePatchMode, Mode.parse("1080p"));
}

test "game patches reject an unknown executable without changing bytes" {
    var bytes = [_]u8{0xaa} ** 64;
    const before = bytes;
    try std.testing.expectEqual(Result.unsupported_executable, try apply(.astro_bot_1080p, &bytes));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
}

test "game patches validate every guard before writing virtual ranges" {
    var bytes = [_]u8{0} ** 128;
    @memcpy(bytes[80..84], "abcd");
    const headers = [_]elf.ProgramHeader{.{
        .type = 1,
        .flags = 5,
        .offset = 80,
        .vaddr = 0x1000,
        .paddr = 0,
        .filesz = 4,
        .memsz = 8,
        .@"align" = 1,
    }};
    const image = elf.Image{ .bytes = &bytes, .header = std.mem.zeroes(elf.Header), .program_headers = &headers };
    const before = bytes;
    try std.testing.expectError(error.PatchByteMismatch, applyGuards(&bytes, image, &.{
        .{ .address = 0x1000, .before = "ab", .after = "12" },
        .{ .address = 0x1002, .before = "xx" },
    }));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
    try std.testing.expectError(error.MalformedHeader, applyGuards(&bytes, image, &.{
        .{ .address = 0x1000, .before = "ab", .after = "12" },
        .{ .address = 0x1004, .before = "\x00" },
    }));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
    try std.testing.expectError(error.OverlappingPatchGuards, applyGuards(&bytes, image, &.{
        .{ .address = 0x1000, .before = "ab", .after = "12" },
        .{ .address = 0x1001, .before = "bc" },
    }));
    try std.testing.expectEqualSlices(u8, &before, &bytes);
    try applyGuards(&bytes, image, &.{
        .{ .address = 0x1000, .before = "ab", .after = "12" },
        .{ .address = 0x1002, .before = "cd" },
    });
    try std.testing.expectEqualStrings("12cd", bytes[80..84]);
    try std.testing.expectEqualSlices(u8, before[0..80], bytes[0..80]);
    try std.testing.expectEqualSlices(u8, before[84..], bytes[84..]);
}

test "game patches translate SELF virtual addresses to physical payloads" {
    const self = @import("self.zig");
    var bytes = [_]u8{0} ** 256;
    @memcpy(bytes[192..196], "abcd");
    const headers = [_]elf.ProgramHeader{.{
        .type = 1,
        .flags = 5,
        .offset = 0x8000,
        .vaddr = 0x4000,
        .paddr = 0,
        .filesz = 4,
        .memsz = 4,
        .@"align" = 1,
    }};
    const segments = [_]self.Segment{.{ .type = 0x800, .offset = 192, .compressed_size = 4, .decompressed_size = 4 }};
    const image = elf.Image{
        .bytes = &bytes,
        .header = std.mem.zeroes(elf.Header),
        .program_headers = &headers,
        .self_layout = .{ .header = std.mem.zeroes(self.Header), .segments = &segments, .elf_offset = 64 },
    };
    const before = bytes;
    try applyGuards(&bytes, image, &.{.{ .address = 0x4001, .before = "bc", .after = "12" }});
    try std.testing.expectEqualStrings("a12d", bytes[192..196]);
    try std.testing.expectEqualSlices(u8, before[0..192], bytes[0..192]);
    try std.testing.expectEqualSlices(u8, before[196..], bytes[196..]);
}
