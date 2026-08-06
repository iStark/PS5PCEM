// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Virtual WAV files backed by FSB5 banks inside Unity `resources.resource`.
//!
//! This title probes hundreds of loose paths under `Media/Resources/audio/**.wav`
//! that are absent from sparse dumps. The same dump still carries ~900 FSB5
//! banks (PCM16 / Vorbis) in `Media/resources.resource`. When a guest open/stat
//! of such a `.wav` misses the host file, map the path onto a bank and serve a
//! synthesised RIFF/WAVE so AudioOut receives real game samples instead of
//! silence.
//!
//! Mapping is by path hash (stable across runs). Exact name→bank pairing is not
//! recovered yet (FSB name tables are empty); the goal is audible game content
//! rather than perfect one-to-one SFX identity.

const std = @import("std");

pub const Error = error{
    NotAvailable,
    OutOfMemory,
    IoFailed,
    Unsupported,
};

const maximum_banks = 2048;
const maximum_wav_bytes = 8 * 1024 * 1024;

const FsbBank = struct {
    file_offset: u64,
    data_offset: u64,
    data_size: u32,
    frequency: u32,
    channels: u8,
    /// 2 = PCM16 in FSB5 mode enum.
    mode: u32,
};

var banks: [maximum_banks]FsbBank = undefined;
var bank_count: usize = 0;
var indexed: bool = false;
var index_failed: bool = false;
var virtual_serves: std.atomic.Value(u64) = .init(0);

fn pathHash(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0xA11D10, path);
}

/// True when this path is a candidate for FSB-backed virtual WAV.
pub fn isVirtualAudioPath(relative: []const u8) bool {
    if (relative.len < 5) return false;
    if (!std.ascii.eqlIgnoreCase(relative[relative.len - 4 ..], ".wav")) return false;
    // Media/Resources/audio/... (any slash style)
    var lower_buf: [512]u8 = undefined;
    if (relative.len > lower_buf.len) return false;
    for (relative, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lower = lower_buf[0..relative.len];
    return std.mem.indexOf(u8, lower, "resources/audio/") != null or
        std.mem.indexOf(u8, lower, "resources\\audio\\") != null;
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

/// Scan `Media/resources.resource` for FSB5 PCM16 banks once.
pub fn ensureIndexed(root: std.Io.Dir, io: std.Io) void {
    if (indexed or index_failed) return;
    indexed = true;

    const file = root.openFile(io, "Media/resources.resource", .{}) catch {
        index_failed = true;
        std.debug.print("[audio_fs] Media/resources.resource missing — no FSB index\n", .{});
        return;
    };
    defer file.close(io);

    const file_len = file.length(io) catch {
        index_failed = true;
        return;
    };

    var offset: u64 = 0;
    var header: [64]u8 = undefined;
    while (offset + 60 < file_len and bank_count < maximum_banks) {
        const n = file.readPositionalAll(io, &header, offset) catch break;
        if (n < 60) break;
        if (!std.mem.eql(u8, header[0..4], "FSB5")) {
            offset += 1;
            continue;
        }
        const num_samples = readU32(&header, 8);
        const sample_hdr_size = readU32(&header, 12);
        const name_table_size = readU32(&header, 16);
        const data_size = readU32(&header, 20);
        const mode = readU32(&header, 24);
        const data_off = offset + 60 + sample_hdr_size + name_table_size;
        if (data_size == 0 or data_off + data_size > file_len) {
            offset += 4;
            continue;
        }
        // Prefer PCM16 (mode 2). Skip empty / unsupported.
        if (mode == 2 and num_samples >= 1 and data_size >= 64) {
            // Frequency/channels are packed in the variable sample header; use
            // conservative defaults that match this title's AudioOut (48 kHz).
            const channels: u8 = if (data_size % 4 == 0) 2 else 1;
            banks[bank_count] = .{
                .file_offset = offset,
                .data_offset = data_off,
                .data_size = data_size,
                .frequency = 48_000,
                .channels = channels,
                .mode = mode,
            };
            bank_count += 1;
        }
        // Jump past this bank's payload to keep the scan linear-time.
        offset = data_off + data_size;
    }
    std.debug.print(
        "[audio_fs] indexed {d} PCM16 FSB5 banks in resources.resource\n",
        .{bank_count},
    );
    if (bank_count == 0) index_failed = true;
}

fn bankForPath(path: []const u8) ?FsbBank {
    if (bank_count == 0) return null;
    const h = pathHash(path);
    return banks[h % bank_count];
}

fn buildWav(bank: FsbBank, root: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator) Error![]u8 {
    if (bank.data_size > maximum_wav_bytes - 44) return Error.Unsupported;
    const file = root.openFile(io, "Media/resources.resource", .{}) catch return Error.IoFailed;
    defer file.close(io);

    const pcm_len = bank.data_size;
    const total = 44 + pcm_len;
    const out = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    errdefer allocator.free(out);

    // RIFF/WAVE header (PCM 16-bit).
    const channels: u16 = bank.channels;
    const rate: u32 = bank.frequency;
    const block_align: u16 = channels * 2;
    const byte_rate: u32 = rate * block_align;
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(total - 8), .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little); // PCM chunk size
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM format
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], byte_rate, .little);
    std.mem.writeInt(u16, out[32..34], block_align, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little); // bits
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], pcm_len, .little);

    const got = file.readPositionalAll(io, out[44..], bank.data_offset) catch {
        allocator.free(out);
        return Error.IoFailed;
    };
    if (got != pcm_len) {
        allocator.free(out);
        return Error.IoFailed;
    }
    return out;
}

/// Resolve a missing audio path to synthesised WAV bytes.
/// Caller owns `bytes` and must free with `page_allocator` on close.
pub fn resolveVirtualWav(
    relative_path: []const u8,
    root: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) Error!struct { bytes: []u8, size: u64 } {
    if (!isVirtualAudioPath(relative_path)) return Error.NotAvailable;
    ensureIndexed(root, io);
    if (bank_count == 0) return Error.NotAvailable;

    const bank = bankForPath(relative_path) orelse return Error.NotAvailable;
    const bytes = try buildWav(bank, root, io, allocator);
    const n = virtual_serves.fetchAdd(1, .monotonic);
    if (n < 12 or n % 100 == 0) {
        std.debug.print(
            "[audio_fs] virtual wav #{d} \"{s}\" -> FSB@0x{x} ({d} bytes, {d}ch)\n",
            .{ n + 1, relative_path, bank.file_offset, bytes.len, bank.channels },
        );
    }
    return .{ .bytes = bytes, .size = bytes.len };
}

pub fn virtualWavSize(relative_path: []const u8, root: std.Io.Dir, io: std.Io) ?u64 {
    if (!isVirtualAudioPath(relative_path)) return null;
    ensureIndexed(root, io);
    if (bank_count == 0) return null;
    const bank = bankForPath(relative_path) orelse return null;
    return 44 + @as(u64, bank.data_size);
}

pub fn reset() void {
    bank_count = 0;
    indexed = false;
    index_failed = false;
    virtual_serves.store(0, .monotonic);
}
