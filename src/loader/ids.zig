//! Library and module identifiers used inside a guest module.
//!
//! A module's dynamic tables declare the libraries and modules it imports from,
//! each with a small numeric identifier. Import symbols then refer to those
//! declarations by identifier rather than by name, so the same short encoding
//! appears both in the dynamic declarations and in symbol names.
//!
//! The encoding is the same base64 variant used for symbol identifiers, but
//! variable length: one to three characters depending on magnitude. That is why
//! a symbol name looks like `rTXw65xmLIA#A#A` rather than carrying full names.

const std = @import("std");

/// Shared with symbol identifier encoding.
const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-";

/// Identifiers never exceed three characters, since they encode a `u16`.
pub const max_len = 3;

/// An encoded identifier, stored inline.
pub const Id = struct {
    bytes: [max_len]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Id, other: []const u8) bool {
        return std.mem.eql(u8, self.slice(), other);
    }
};

pub const DecodeError = error{
    /// Empty, or longer than three characters.
    BadLength,
    /// Contained a character outside the alphabet.
    BadCharacter,
};

/// Encodes a numeric identifier.
///
/// The length is chosen by magnitude, not padded to a fixed width, so `0`
/// encodes as `"A"` rather than `"AAA"`.
pub fn encode(value: u16) Id {
    var id = Id{};
    if (value < 0x40) {
        id.bytes[0] = alphabet[@as(u6, @truncate(value))];
        id.len = 1;
    } else if (value < 0x1000) {
        id.bytes[0] = alphabet[@as(u6, @truncate(value >> 6))];
        id.bytes[1] = alphabet[@as(u6, @truncate(value))];
        id.len = 2;
    } else {
        id.bytes[0] = alphabet[@as(u6, @truncate(value >> 12))];
        id.bytes[1] = alphabet[@as(u6, @truncate(value >> 6))];
        id.bytes[2] = alphabet[@as(u6, @truncate(value))];
        id.len = 3;
    }
    return id;
}

/// Decodes an identifier back to its numeric form.
pub fn decode(text: []const u8) DecodeError!u16 {
    if (text.len == 0 or text.len > max_len) return DecodeError.BadLength;

    var value: u16 = 0;
    for (text) |c| {
        const index = std.mem.indexOfScalar(u8, alphabet, c) orelse
            return DecodeError.BadCharacter;
        value = (value << 6) | @as(u16, @intCast(index));
    }
    return value;
}

test "identifiers use the shortest form that fits" {
    try std.testing.expectEqualStrings("A", encode(0).slice());
    try std.testing.expectEqualStrings("B", encode(1).slice());
    // Last single-character value.
    try std.testing.expectEqualStrings("-", encode(0x3f).slice());
    // First that needs two.
    try std.testing.expectEqualStrings("BA", encode(0x40).slice());
    // First that needs three.
    try std.testing.expectEqualStrings("BAA", encode(0x1000).slice());
    // Three characters carry 18 bits but a `u16` only fills 16, so the leading
    // character tops out at 0xf ('P') rather than 0x3f ('-').
    try std.testing.expectEqualStrings("P--", encode(0xffff).slice());
}

test "encode and decode round-trip across the whole range" {
    var value: u32 = 0;
    while (value <= 0xffff) : (value += 1) {
        const narrowed: u16 = @intCast(value);
        const id = encode(narrowed);
        try std.testing.expectEqual(narrowed, try decode(id.slice()));
    }
}

test "decode rejects malformed identifiers" {
    try std.testing.expectError(DecodeError.BadLength, decode(""));
    try std.testing.expectError(DecodeError.BadLength, decode("ABCD"));
    try std.testing.expectError(DecodeError.BadCharacter, decode("A#"));
}
