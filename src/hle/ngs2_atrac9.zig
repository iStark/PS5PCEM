// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bounded, per-voice ATRAC9 decoding. Guest blocks remain borrowed; only one
//! compressed superframe and two PCM superframes are retained on the host.
const std = @import("std");
const codec = @import("ajm_codec.zig");
const pcm = @import("ngs2_pcm.zig");
const waveform = @import("ngs2_waveform.zig");
const unit: u64 = 1 << 32;

pub const Stream = struct {
    decoder: codec.Decoder,
    format: pcm.Format,
    superframe_samples: usize,
    input: []u8,
    window: []f32,
    rendered: std.ArrayList(f32) = .empty,
    blocks: std.ArrayList(pcm.Block) = .empty,
    cursor: pcm.Cursor = .{},
    byte_offset: usize = 0,
    input_used: usize = 0,
    window_start: usize = 0,
    window_end: usize = 0,
    remaining: u64 = 0,
    skip: u64 = 0,
    wave_first: ?usize = null,
    wave_repeat: u32 = 0,
    continuing: bool = false,
    pitch: f32 = 1,

    pub fn init(allocator: std.mem.Allocator, format: waveform.Format) !Stream {
        if (format.channels == 0 or format.channels > 8 or format.frame_offset != 0 or format.frame_margin != 0) return error.InvalidFormat;
        var decoder = try codec.Decoder.create(codec.codec_atrac9, 2 << 7);
        errdefer decoder.deinit();
        var config: [4]u8 = undefined;
        std.mem.writeInt(u32, &config, format.config_data, .big);
        if (decoder.initialize(&config).result != 0) return error.InvalidFormat;
        const info = decoder.codecInfo();
        if (info.channels != format.channels or info.sample_rate != format.sample_rate or info.superframe_size == 0) return error.InvalidFormat;
        const samples = info.frame_samples * info.frames_in_superframe;
        const input = try allocator.alloc(u8, info.superframe_size);
        errdefer allocator.free(input);
        const window = try allocator.alloc(f32, (samples + 2) * info.channels);
        return .{ .decoder = decoder, .format = .{ .channels = @intCast(info.channels), .rate = info.sample_rate, .float32 = true }, .superframe_samples = samples, .input = input, .window = window };
    }

    pub fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
        self.decoder.deinit();
        allocator.free(self.input);
        allocator.free(self.window);
        self.rendered.deinit(allocator);
        self.blocks.deinit(allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Stream) void {
        self.blocks.clearRetainingCapacity();
        self.cursor = .{};
        self.byte_offset = 0;
        self.input_used = 0;
        self.window_start = 0;
        self.window_end = 0;
        self.remaining = 0;
        self.skip = 0;
        self.wave_first = null;
        self.wave_repeat = 0;
        self.continuing = false;
        self.decoder.reset();
    }

    pub fn append(self: *Stream, allocator: std.mem.Allocator, blocks: []const pcm.Block, reset: bool, continuing: bool, data_only: bool) !void {
        if (blocks.len > pcm.max_blocks) return error.InvalidBlock;
        if (data_only and (reset or (self.remaining == 0 and self.cursor.block >= self.blocks.items.len))) return error.InvalidBlock;
        for (blocks) |block| {
            if (block.data.len == 0) return error.InvalidBlock;
            if (data_only) continue;
            if (block.frames == 0) return error.InvalidBlock;
            const frames = @as(u64, block.skip) + block.frames;
            const needed = ((frames + self.superframe_samples - 1) / self.superframe_samples) * self.input.len;
            if (needed > block.data.len and (!continuing or block.repeats != 0)) return error.InvalidBlock;
        }
        // Retain the start of a partially consumed waveform for its repeats.
        const consumed = if (reset) self.blocks.items.len else self.wave_first orelse self.cursor.block;
        const retained = self.blocks.items.len - consumed;
        if (retained + blocks.len > pcm.max_blocks) return error.InvalidBlock;
        try self.blocks.ensureTotalCapacity(allocator, retained + blocks.len);
        if (reset) self.clear() else if (consumed != 0) {
            std.mem.copyForwards(pcm.Block, self.blocks.items[0..retained], self.blocks.items[consumed..]);
            self.blocks.items.len = retained;
            self.cursor.block -= consumed;
            if (self.wave_first) |*first| first.* -= consumed;
        }
        for (blocks) |original| {
            var block = original;
            if (data_only) {
                block.frames = 0;
                block.skip = 0;
                block.repeats = 0;
            }
            self.blocks.appendAssumeCapacity(block);
        }
        self.continuing = continuing;
    }

    pub fn readAddress(self: *const Stream) u64 {
        return self.cursor.end_address;
    }

    pub fn finished(self: *const Stream) bool {
        return !self.continuing and self.remaining == 0 and self.wave_first == null and self.cursor.block >= self.blocks.items.len and self.window_start == self.window_end;
    }

    fn startWave(self: *Stream) !bool {
        if (self.cursor.block >= self.blocks.items.len) return false;
        const block = self.blocks.items[self.cursor.block];
        if (block.frames == 0) return error.InvalidBlock;
        self.wave_first = self.cursor.block;
        self.remaining = block.frames;
        self.skip = block.skip;
        self.byte_offset = 0;
        self.input_used = 0;
        self.decoder.reset();
        return true;
    }

    fn finishWave(self: *Stream) void {
        const first = self.wave_first.?;
        const start = self.blocks.items[first];
        const last = self.blocks.items[self.cursor.block];
        self.cursor.user_data = last.user_data;
        self.cursor.end_address = @intFromPtr(last.data.ptr) + last.data.len;
        if (start.repeats == std.math.maxInt(u32) or self.wave_repeat < start.repeats) {
            self.cursor.block = first;
            self.wave_repeat +|= 1;
        } else {
            self.cursor.block += 1;
            self.wave_repeat = 0;
        }
        self.wave_first = null;
        self.byte_offset = 0;
    }

    fn decodeMore(self: *Stream) !bool {
        if (self.remaining == 0 and !try self.startWave()) return false;
        while (self.input_used < self.input.len) {
            if (self.cursor.block >= self.blocks.items.len) {
                if (!self.continuing) return error.TruncatedStream;
                return false;
            }
            const block = self.blocks.items[self.cursor.block];
            if (self.byte_offset == block.data.len) {
                if (self.cursor.block + 1 >= self.blocks.items.len) {
                    if (!self.continuing) return error.TruncatedStream;
                    return false;
                }
                if (self.blocks.items[self.cursor.block + 1].frames != 0) return error.TruncatedStream;
                self.cursor.user_data = block.user_data;
                self.cursor.block += 1;
                self.byte_offset = 0;
                continue;
            }
            const count = @min(self.input.len - self.input_used, block.data.len - self.byte_offset);
            @memcpy(self.input[self.input_used..][0..count], block.data[self.byte_offset..][0..count]);
            self.input_used += count;
            self.byte_offset += count;
            self.cursor.decoded_bytes += count;
            self.cursor.end_address = @intFromPtr(block.data.ptr) + self.byte_offset;
        }
        const channels: usize = self.format.channels;
        const kept = self.window_end - self.window_start;
        std.mem.copyForwards(f32, self.window[0 .. kept * channels], self.window[self.window_start * channels .. self.window_end * channels]);
        self.window_start = 0;
        self.window_end = kept;
        const destination = self.window[kept * channels ..][0 .. self.superframe_samples * channels];
        const report = self.decoder.decode(self.input, std.mem.sliceAsBytes(destination));
        if (report.result != 0 or report.consumed != self.input.len or report.produced != destination.len * 4) return error.InvalidData;
        self.input_used = 0;
        const skipped: usize = @intCast(@min(self.skip, self.superframe_samples));
        self.skip -= skipped;
        const audible: usize = @intCast(@min(self.remaining, self.superframe_samples - skipped));
        self.remaining -= audible;
        std.mem.copyForwards(f32, destination[0 .. audible * channels], destination[skipped * channels ..][0 .. audible * channels]);
        self.window_end += audible;
        if (self.remaining == 0) self.finishWave();
        return true;
    }

    fn ensure(self: *Stream, frames: usize) !bool {
        while (self.window_end - self.window_start < frames) {
            if (!try self.decodeMore()) return false;
        }
        return true;
    }

    fn advance(self: *Stream) !void {
        while (self.cursor.phase >= unit) {
            if (!try self.ensure(1)) return;
            const frames = @min(self.cursor.phase >> 32, self.window_end - self.window_start);
            self.window_start += @intCast(frames);
            self.cursor.decoded_frames += frames;
            self.cursor.phase -= frames * unit;
        }
    }

    /// Decode/resample once per system grain, then reuse this PCM for every
    /// output bus. Decoder state is never rewound or consumed once per bus.
    pub fn render(self: *Stream, allocator: std.mem.Allocator, frames: usize, rate: u32) !void {
        if (frames > 4096 or rate == 0) return error.InvalidFormat;
        const channels: usize = self.format.channels;
        try self.rendered.resize(allocator, frames * channels);
        @memset(self.rendered.items, 0);
        if (self.pitch == 0) return;
        const numerator: u64 = @intFromFloat(@as(f64, @floatFromInt(self.format.rate)) * self.pitch * @as(f64, @floatFromInt(unit)));
        const step = numerator / rate;
        const remainder = numerator % rate;
        for (0..frames) |frame| {
            try self.advance();
            if (self.cursor.phase >= unit or !try self.ensure(1)) break;
            const has_next = try self.ensure(2);
            const current = self.window_start * channels;
            const next = if (has_next) current + channels else current;
            const fraction: f32 = @as(f32, @floatFromInt(self.cursor.phase)) / @as(f32, @floatFromInt(unit));
            for (0..channels) |channel| {
                const a = self.window[current + channel];
                const b = self.window[next + channel];
                self.rendered.items[frame * channels + channel] = a + (b - a) * fraction;
            }
            self.cursor.phase += step;
            self.cursor.rate_remainder += remainder;
            self.cursor.phase += self.cursor.rate_remainder / rate;
            self.cursor.rate_remainder %= rate;
        }
        try self.advance();
    }

    pub fn mix(self: *const Stream, output: []f32, output_channels: usize, gain: f32) void {
        const channels: usize = self.format.channels;
        const frames = @min(output.len / output_channels, self.rendered.items.len / channels);
        for (0..frames) |frame| for (0..@min(output_channels, 2)) |channel| {
            const sample = self.rendered.items[frame * channels + @min(channel, channels - 1)];
            if (std.math.isFinite(sample)) output[frame * output_channels + channel] += sample * gain;
        };
    }
};

fn encodedSilence() [256]u8 {
    const frames = [_][]const u8{
        &.{ 0x2c, 0xdc, 0x1e, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x67, 0x39, 0xce, 0x73, 0x9c, 0xf7, 0xbd, 0xef, 0x7b, 0xde, 0x93, 0x6d, 0x26, 0xda, 0x4d, 0xb4, 0xf1, 0xe3, 0xc7, 0x8f, 0x1d, 0x47, 0x51, 0xd4, 0x75, 0x00 },
        &.{ 0xa8, 0xd8, 0x1e, 0x80, 0x00, 0x00, 0x19, 0xce, 0x73, 0x9c, 0xe7, 0x3d, 0xef, 0x7b, 0xde, 0xf7, 0xa4, 0xdb, 0x49, 0xb6, 0x93, 0x6d, 0x3c, 0x78, 0xf1, 0xe3, 0xc7, 0x51, 0xd4, 0x75, 0x00 },
        &.{ 0xa4, 0xd4, 0x1e, 0x80, 0x00, 0x00, 0x33, 0x9c, 0xe7, 0x39, 0xce, 0x7b, 0xde, 0xf7, 0xbd, 0xef, 0x49, 0xb6, 0x93, 0x6d, 0x26, 0xda, 0x78, 0xf1, 0xe3, 0xc7, 0x8e, 0xa3, 0xa8 },
        &.{ 0xa0, 0xd0, 0x1e, 0x80, 0x00, 0x00, 0x67, 0x39, 0xce, 0x73, 0x9c, 0xf7, 0xbd, 0xef, 0x7b, 0xde, 0x93, 0x6d, 0x26, 0xda, 0x4d, 0xb4, 0xf1, 0xe3, 0xc7, 0x8f, 0x1d, 0x40 },
    };
    var data: [256]u8 = @splat(1);
    var at: usize = 0;
    for (frames) |frame| {
        @memcpy(data[at..][0..frame.len], frame);
        at += frame.len;
    }
    return data;
}

fn testStream() !Stream {
    return Stream.init(std.testing.allocator, .{ .waveform_type = 0x40, .channels = 1, .sample_rate = 48000, .config_data = 0xfe7007f0 });
}

test "ATRAC9 bounded streaming preserves skips repeats counters and rate across grains" {
    const data = encodedSilence();
    var stream = try testStream();
    defer stream.deinit(std.testing.allocator);
    try stream.append(std.testing.allocator, &.{.{ .data = &data, .skip = 13, .frames = 900, .repeats = 1, .user_data = 77 }}, false, false, false);
    for (0..8) |_| try stream.render(std.testing.allocator, 256, 48000);
    try std.testing.expect(stream.finished());
    try std.testing.expectEqual(@as(u64, 1800), stream.cursor.decoded_frames);
    try std.testing.expectEqual(@as(u64, 512), stream.cursor.decoded_bytes);
    try std.testing.expectEqual(@as(u64, 77), stream.cursor.user_data);
    try std.testing.expectEqual(@intFromPtr(&data) + data.len, stream.readAddress());
    try stream.append(std.testing.allocator, &.{.{ .data = &data, .frames = 1024 }}, true, false, false);
    try stream.render(std.testing.allocator, 1024, 96000);
    try std.testing.expectEqual(@as(u64, 512), stream.cursor.decoded_frames);
    try stream.render(std.testing.allocator, 1024, 96000);
    try std.testing.expect(stream.finished());
    try std.testing.expectEqual(@as(u64, 1024), stream.cursor.decoded_frames);
}

test "ATRAC9 compressed chunks can split a superframe and refill after starvation" {
    const data = encodedSilence();
    var stream = try testStream();
    defer stream.deinit(std.testing.allocator);
    try stream.append(std.testing.allocator, &.{.{ .data = data[0..17], .frames = 1024 }}, false, true, false);
    try stream.render(std.testing.allocator, 256, 48000);
    try std.testing.expectEqual(@as(u64, 0), stream.cursor.decoded_frames);
    try std.testing.expect(!stream.finished());
    try stream.append(std.testing.allocator, &.{.{ .data = data[17..], .frames = 0 }}, false, false, true);
    for (0..4) |_| try stream.render(std.testing.allocator, 256, 48000);
    try std.testing.expect(stream.finished());
    try std.testing.expectEqual(@as(u64, 1024), stream.cursor.decoded_frames);
    try std.testing.expectEqual(@as(u64, 256), stream.cursor.decoded_bytes);
}

test "ATRAC9 rejects invalid geometry and corrupt input without decoding unbounded data" {
    var stream = try testStream();
    defer stream.deinit(std.testing.allocator);
    const data = [_]u8{0} ** 256;
    try std.testing.expectError(error.InvalidBlock, stream.append(std.testing.allocator, &.{.{ .data = data[0..16], .frames = 1024 }}, false, false, false));
    try stream.append(std.testing.allocator, &.{.{ .data = &data, .frames = 1024 }}, false, false, false);
    try std.testing.expectError(error.InvalidData, stream.render(std.testing.allocator, 256, 48000));
}
