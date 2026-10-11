// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! NGS2 RIFF metadata, read by offsets without loading the audio payload.
const std = @import("std");
const codec = @import("ajm_codec.zig");

pub const Format = extern struct {
    waveform_type: u32 = 0,
    channels: u32 = 0,
    sample_rate: u32 = 0,
    config_data: u32 = 0,
    frame_offset: u32 = 0,
    frame_margin: u32 = 0,
};
pub const Block = extern struct {
    data_offset: usize = 0,
    data_size: usize = 0,
    repeats: u32 = 0,
    skip_samples: u32 = 0,
    samples: u32 = 0,
    reserved: u32 = 0,
    user_data: usize = 0,
};
pub const Info = extern struct {
    format: Format = .{},
    data_offset: u32 = 0,
    data_size: u32 = 0,
    loop_begin: u32 = 0,
    loop_end: u32 = 0,
    samples: u32 = 0,
    audio_unit_size: u32 = 0,
    audio_unit_samples: u32 = 0,
    audio_units_per_frame: u32 = 0,
    audio_frame_size: u32 = 0,
    audio_frame_samples: u32 = 0,
    delay_samples: u32 = 0,
    block_count: u32 = 0,
    blocks: [4]Block = @splat(.{}),
};
pub const Error = error{ InvalidData, InvalidFormat, UnknownFormat };

fn u16le(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}
fn u32le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn read(reader: anytype, offset: u64, bytes: []u8) Error!void {
    reader.read(offset, bytes) catch return error.InvalidData;
}

/// Reader supplies `read(offset, destination)`, with offsets relative to the
/// start of the RIFF. `length` is the available file/container extent.
pub fn parse(reader: anytype, length: u64) Error!Info {
    if (length < 12) return error.InvalidData;
    var header: [12]u8 = undefined;
    try read(reader, 0, &header);
    if (!std.mem.eql(u8, header[0..4], "RIFF") or !std.mem.eql(u8, header[8..12], "WAVE")) return error.UnknownFormat;
    const end = @as(u64, u32le(&header, 4)) + 8;
    if (end < 12 or end > length) return error.InvalidData;
    var fmt: [64]u8 = @splat(0);
    var fmt_size: usize = 0;
    var fact: [12]u8 = @splat(0);
    var fact_size: usize = 0;
    var sampler: [60]u8 = @splat(0);
    var sampler_size: u32 = 0;
    var info = Info{};
    var offset: u64 = 12;
    while (offset < end) {
        if (end - offset < 8) return error.InvalidData;
        var chunk: [8]u8 = undefined;
        try read(reader, offset, &chunk);
        const size = u32le(&chunk, 4);
        const payload = offset + 8;
        if (size > end - payload) return error.InvalidData;
        if (std.mem.eql(u8, chunk[0..4], "fmt ")) {
            fmt_size = @min(size, fmt.len);
            try read(reader, payload, fmt[0..fmt_size]);
        } else if (std.mem.eql(u8, chunk[0..4], "fact")) {
            fact_size = @min(size, fact.len);
            try read(reader, payload, fact[0..fact_size]);
        } else if (std.mem.eql(u8, chunk[0..4], "smpl")) {
            sampler_size = size;
            try read(reader, payload, sampler[0..@min(size, sampler.len)]);
        } else if (std.mem.eql(u8, chunk[0..4], "data")) {
            if (payload > std.math.maxInt(u32) or info.data_offset != 0) return error.InvalidData;
            info.data_offset = @intCast(payload);
            info.data_size = size;
        }
        offset = payload + size + (size & 1);
        if (offset > end) return error.InvalidData;
    }
    if (fmt_size < 16 or info.data_offset == 0) return error.InvalidData;
    info.format.channels = u16le(&fmt, 2);
    info.format.sample_rate = u32le(&fmt, 4);
    if (info.format.channels == 0 or info.format.channels > 8 or info.format.sample_rate == 0 or info.format.sample_rate > 192000) return error.InvalidFormat;
    const alignment = u16le(&fmt, 12);
    const bits = u16le(&fmt, 14);
    var tag = u16le(&fmt, 0);
    const atrac9_guid = [_]u8{ 0xd2, 0x42, 0xe1, 0x47, 0xba, 0x36, 0x8d, 0x4d, 0x88, 0xfc, 0x61, 0x65, 0x4f, 0x8c, 0x83, 0x6c };
    var skip: u32 = 0;
    if (tag == 0xfffe and fmt_size >= 52 and std.mem.eql(u8, fmt[24..40], &atrac9_guid)) {
        if (fact_size < 12) return error.InvalidFormat;
        var decoder = codec.Decoder.create(codec.codec_atrac9, 0) catch return error.InvalidFormat;
        defer decoder.deinit();
        if (decoder.initialize(fmt[44..48]).result != 0) return error.InvalidFormat;
        const geometry = decoder.codecInfo();
        if (geometry.channels != info.format.channels or geometry.sample_rate != info.format.sample_rate or geometry.superframe_size != alignment) return error.InvalidFormat;
        info.format.waveform_type = 0x40;
        info.format.config_data = std.mem.readInt(u32, fmt[44..48], .big);
        info.audio_frame_size = geometry.superframe_size;
        info.audio_frame_samples = geometry.frame_samples * geometry.frames_in_superframe;
        info.audio_units_per_frame = geometry.frames_in_superframe;
        info.audio_unit_size = geometry.superframe_size / geometry.frames_in_superframe;
        info.audio_unit_samples = geometry.frame_samples;
        info.samples = u32le(&fact, 0);
        info.delay_samples = u32le(&fact, 4);
        skip = u32le(&fact, 8);
        if (u16le(&fmt, 18) != info.audio_frame_samples) return error.InvalidFormat;
    } else {
        if (tag == 0xfffe and fmt_size >= 40) {
            const pcm_guid_tail = [_]u8{ 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 };
            if (!std.mem.eql(u8, fmt[26..40], &pcm_guid_tail)) return error.UnknownFormat;
            tag = u16le(&fmt, 24);
        }
        info.format.waveform_type = if (tag == 1 and bits == 16) 0x12 else if (tag == 3 and bits == 32) 0x18 else return error.UnknownFormat;
        if (alignment != info.format.channels * (bits / 8)) return error.InvalidFormat;
        info.audio_frame_size = alignment;
        info.audio_unit_size = alignment;
        info.audio_frame_samples = 1;
        info.audio_unit_samples = 1;
        info.audio_units_per_frame = 1;
        info.samples = info.data_size / alignment;
    }
    if (info.audio_frame_size == 0 or info.data_size % info.audio_frame_size != 0 or
        @as(u64, skip) + info.samples > @as(u64, info.data_size / info.audio_frame_size) * info.audio_frame_samples) return error.InvalidData;
    if (sampler_size != 0) {
        if (sampler_size < 36) return error.InvalidData;
        const count = u32le(&sampler, 28);
        if (count > (sampler_size - 36) / 24) return error.InvalidData;
        if (count != 0) {
            if (count != 1 or u32le(&sampler, 40) != 0 or u32le(&sampler, 52) != 0) return error.UnknownFormat;
            const begin = u32le(&sampler, 44);
            const loop_end = @as(u64, u32le(&sampler, 48)) + 1;
            const wave_end = @as(u64, skip) + info.samples;
            if (begin < skip or begin >= loop_end or loop_end > wave_end) return error.InvalidData;
            info.loop_begin = begin - skip;
            info.loop_end = @intCast(loop_end - skip);
            const plays = u32le(&sampler, 56);
            try addRange(&info, skip, begin - skip, 0);
            try addRange(&info, begin, @intCast(loop_end - begin), if (plays == 0) std.math.maxInt(u32) else plays - 1);
            try addRange(&info, loop_end, @intCast(wave_end - loop_end), 0);
            return info;
        }
    }
    try addRange(&info, skip, info.samples, 0);
    return info;
}

fn addRange(info: *Info, begin: u64, count: u32, repeats: u32) Error!void {
    if (count == 0) return;
    const preroll = if (info.format.waveform_type == 0x40) @min(begin, info.audio_unit_samples) else 0;
    const first = (begin - preroll) / info.audio_frame_samples;
    const skip = begin - first * info.audio_frame_samples;
    const frames = (skip + count + info.audio_frame_samples - 1) / info.audio_frame_samples;
    const offset = first * info.audio_frame_size;
    const size = frames * info.audio_frame_size;
    if (offset + size > info.data_size or info.block_count == info.blocks.len) return error.InvalidData;
    info.blocks[info.block_count] = .{ .data_offset = info.data_offset + @as(usize, @intCast(offset)), .data_size = @intCast(size), .skip_samples = @intCast(skip), .samples = count, .repeats = repeats };
    info.block_count += 1;
}

pub const MemoryReader = struct {
    bytes: []const u8,
    pub fn read(self: MemoryReader, offset: u64, output: []u8) Error!void {
        if (offset > self.bytes.len or output.len > self.bytes.len - offset) return error.InvalidData;
        @memcpy(output, self.bytes[@intCast(offset)..][0..output.len]);
    }
};

test "NGS2 waveform metadata reads PCM geometry and rejects truncated payloads" {
    var wave: [48]u8 = @splat(0);
    @memcpy(wave[0..4], "RIFF");
    std.mem.writeInt(u32, wave[4..8], 40, .little);
    @memcpy(wave[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, wave[16..20], 16, .little);
    std.mem.writeInt(u16, wave[20..22], 1, .little);
    std.mem.writeInt(u16, wave[22..24], 2, .little);
    std.mem.writeInt(u32, wave[24..28], 48000, .little);
    std.mem.writeInt(u16, wave[32..34], 4, .little);
    std.mem.writeInt(u16, wave[34..36], 16, .little);
    @memcpy(wave[36..40], "data");
    std.mem.writeInt(u32, wave[40..44], 4, .little);
    const info = try parse(MemoryReader{ .bytes = &wave }, wave.len);
    try std.testing.expectEqual(@as(u32, 0x12), info.format.waveform_type);
    try std.testing.expectEqual(@as(u32, 1), info.samples);
    try std.testing.expectEqual(@as(usize, 44), info.blocks[0].data_offset);
    try std.testing.expectError(error.InvalidData, parse(MemoryReader{ .bytes = wave[0..47] }, 47));
}

test "NGS2 waveform metadata describes ATRAC9 preroll loops without reading encoded audio" {
    var wave: [168]u8 = @splat(0);
    const payload_bytes = 2 * 768;
    @memcpy(wave[0..4], "RIFF");
    std.mem.writeInt(u32, wave[4..8], wave.len + payload_bytes - 8, .little);
    @memcpy(wave[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, wave[16..20], 52, .little);
    std.mem.writeInt(u16, wave[20..22], 0xfffe, .little);
    std.mem.writeInt(u16, wave[22..24], 2, .little);
    std.mem.writeInt(u32, wave[24..28], 48000, .little);
    std.mem.writeInt(u16, wave[32..34], 768, .little);
    std.mem.writeInt(u16, wave[36..38], 34, .little);
    std.mem.writeInt(u16, wave[38..40], 1024, .little);
    @memcpy(wave[44..60], &[_]u8{ 0xd2, 0x42, 0xe1, 0x47, 0xba, 0x36, 0x8d, 0x4d, 0x88, 0xfc, 0x61, 0x65, 0x4f, 0x8c, 0x83, 0x6c });
    std.mem.writeInt(u32, wave[64..68], 0xfe7417f0, .big);
    @memcpy(wave[72..76], "fact");
    std.mem.writeInt(u32, wave[76..80], 12, .little);
    std.mem.writeInt(u32, wave[80..84], 1500, .little);
    std.mem.writeInt(u32, wave[84..88], 256, .little);
    std.mem.writeInt(u32, wave[88..92], 256, .little);
    @memcpy(wave[92..96], "smpl");
    std.mem.writeInt(u32, wave[96..100], 60, .little);
    std.mem.writeInt(u32, wave[128..132], 1, .little);
    std.mem.writeInt(u32, wave[144..148], 256, .little);
    std.mem.writeInt(u32, wave[148..152], 1023, .little);
    @memcpy(wave[160..164], "data");
    std.mem.writeInt(u32, wave[164..168], payload_bytes, .little);
    // Reader exposes only the header. Attempting to fetch even one encoded
    // sample would fail, despite the advertised complete container length.
    const info = try parse(MemoryReader{ .bytes = &wave }, wave.len + payload_bytes);
    try std.testing.expectEqual(@as(u32, 0x40), info.format.waveform_type);
    try std.testing.expectEqual(@as(u32, 0xfe7417f0), info.format.config_data);
    try std.testing.expectEqual(@as(u32, 768), info.audio_frame_size);
    try std.testing.expectEqual(@as(u32, 1024), info.audio_frame_samples);
    try std.testing.expectEqual(@as(u32, 2), info.block_count);
    try std.testing.expectEqual(@as(u32, 768), info.loop_end);
    try std.testing.expectEqual(std.math.maxInt(u32), info.blocks[0].repeats);
    try std.testing.expectEqual(@as(u32, 256), info.blocks[0].skip_samples);
    try std.testing.expectEqual(@as(u32, 732), info.blocks[1].samples);
}
