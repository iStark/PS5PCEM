//! Numeric IDs (NIDs) that identify exported firmware symbols.
//!
//! Guest modules do not import functions by name. Each import is an 11-character
//! identifier derived from the symbol name, and the dynamic linker resolves
//! those identifiers against the implementations the emulator provides.
//!
//! The derivation is a SHA-1 over the symbol name followed by a fixed salt; the
//! first eight bytes of the digest, read little-endian, are then re-encoded in a
//! base64 variant with a non-standard alphabet.
//!
//! Being able to compute this locally means an implementation can be registered
//! under a readable name and checked against the identifier the guest actually
//! asks for, instead of carrying opaque string constants that nothing verifies.

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;

/// Fixed salt appended to the symbol name before hashing.
const salt = [_]u8{
    0x51, 0x8D, 0x64, 0xA6, 0x35, 0xDE, 0xD8, 0xC1,
    0xE6, 0xB0, 0x39, 0xB1, 0xC3, 0xE5, 0x52, 0x30,
};

/// Alphabet of the base64 variant. Note the trailing `+-`, which differs from
/// both standard and URL-safe base64.
const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-";

/// Encoded identifiers are always exactly this long.
pub const encoded_len = 11;

pub const Encoded = [encoded_len]u8;

pub const DecodeError = error{
    /// The text was not exactly `encoded_len` characters.
    BadLength,
    /// The text contained a character outside the alphabet.
    BadCharacter,
};

/// Hashes a symbol name into its raw 64-bit identifier.
pub fn hash(name: []const u8) u64 {
    var h = Sha1.init(.{});
    h.update(name);
    h.update(&salt);

    var digest: [Sha1.digest_length]u8 = undefined;
    h.final(&digest);

    return std.mem.readInt(u64, digest[0..8], .little);
}

/// Encodes a raw identifier as its 11-character text form.
///
/// The first ten characters take six bits each, consuming bits 63..4. The last
/// character carries the remaining four bits, shifted up so they occupy the
/// high end of the final six-bit group.
pub fn encode(value: u64) Encoded {
    var out: Encoded = undefined;
    for (&out, 0..) |*c, i| {
        const index: u6 = if (i < 10)
            @truncate(value >> @intCast(58 - i * 6))
        else
            @truncate((value & 0xf) << 2);
        c.* = alphabet[index];
    }
    return out;
}

/// Computes the text form of a symbol name directly.
pub fn fromName(name: []const u8) Encoded {
    return encode(hash(name));
}

/// Reverses `encode`.
///
/// Not every 11-character string round-trips: the last character only carries
/// four meaningful bits, so its low two bits are dropped.
pub fn decode(text: []const u8) DecodeError!u64 {
    if (text.len != encoded_len) return DecodeError.BadLength;

    var value: u64 = 0;
    for (text, 0..) |c, i| {
        const index = std.mem.indexOfScalar(u8, alphabet, c) orelse
            return DecodeError.BadCharacter;
        if (i < 10) {
            value |= @as(u64, @intCast(index)) << @intCast(58 - i * 6);
        } else {
            value |= @as(u64, @intCast(index)) >> 2;
        }
    }
    return value;
}

/// Whether a symbol name hashes to the given text identifier.
pub fn matches(name: []const u8, text: []const u8) bool {
    if (text.len != encoded_len) return false;
    return std.mem.eql(u8, &fromName(name), text);
}

/// Name/identifier pairs taken from published firmware symbol listings. They
/// pin the algorithm: a change that breaks any of these breaks symbol
/// resolution for every guest module.
const known_pairs = [_]struct { []const u8, []const u8 }{
    .{ "pthread_mutex_lock", "7H0iTOciTLo" },
    .{ "pthread_mutex_unlock", "2Z+PpY6CaJg" },
    .{ "pthread_detach", "+U1R4WtXvoc" },
    .{ "pthread_yield", "B5GmVDKwpn0" },
    .{ "pthread_key_delete", "6BpEZuDT7YI" },
    .{ "pthread_getspecific", "0-KXaS70xy4" },
    .{ "pthread_cond_signal", "2MOy+rUfuhQ" },
    .{ "pthread_cond_timedwait", "27bAgiJmOh0" },
    .{ "pthread_rwlock_destroy", "1471ajPzxh0" },
    .{ "pthread_attr_setstacksize", "2Q0z6rnBrTE" },
    .{ "pthread_attr_getstacksize", "0qOtCR-ZHck" },
    .{ "sem_getvalue", "Bq+LRV-N6Hk" },
    .{ "stat", "E6ao34wPw+U" },
    .{ "getpagesize", "k+AXqu2-eBc" },
    .{ "clock_gettime", "lLMT9vJAck0" },
    .{ "sceCoredumpRegisterCoredumpHandler", "8zLSfEfW5AU" },
    .{ "sceCoredumpUnregisterCoredumpHandler", "fFkhOgztiCA" },
    .{ "sceKernelAllocateDirectMemory", "rTXw65xmLIA" },
    .{ "sceKernelReleaseDirectMemory", "MBuItvba6z8" },
    .{ "sceKernelCheckedReleaseDirectMemory", "hwVSPCmp5tM" },
    .{ "sceKernelMapDirectMemory", "L-Q3LEjIbgA" },
    .{ "sceKernelGetDirectMemorySize", "pO96TwzOm5E" },
    // Firmware exports both POSIX and camel-case spellings of the same
    // operation, and they are distinct symbols with distinct identifiers.
    .{ "scePthreadOnce", "14bOACANTBo" },
};

test "known symbol names hash to their published identifiers" {
    for (known_pairs) |pair| {
        const name, const expected = pair;
        try std.testing.expectEqualStrings(expected, &fromName(name));
    }
}

test "encoded identifiers are always 11 characters" {
    try std.testing.expectEqual(@as(usize, 11), fromName("").len);
    try std.testing.expectEqual(@as(usize, 11), fromName("a" ** 200).len);
}

test "matches accepts the right name and rejects others" {
    try std.testing.expect(matches("pthread_mutex_lock", "7H0iTOciTLo"));
    try std.testing.expect(!matches("pthread_mutex_unlock", "7H0iTOciTLo"));
    // A wrong length can never match.
    try std.testing.expect(!matches("pthread_mutex_lock", "7H0iTOciTL"));
}

test "decode reverses encode for the bits that survive" {
    for (known_pairs) |pair| {
        const name, const text = pair;
        // The final character drops two bits, so compare everything above them.
        try std.testing.expectEqual(hash(name) >> 2, (try decode(text)) >> 2);
    }
}

test "decode rejects malformed text" {
    try std.testing.expectError(DecodeError.BadLength, decode("short"));
    try std.testing.expectError(DecodeError.BadCharacter, decode("7H0iTOciTL!"));
}
