// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Bounded NGS2 PCM block playback. Blocks borrow the guest's samples until
//! their reported read cursor passes them; only descriptors are allocated.
const std = @import("std");
const unit: u64 = 1 << 32;
pub const max_blocks = 256;

pub const Format = struct {
    channels: u8,
    rate: u32,
    float32: bool,

    pub fn frameBytes(self: Format) usize {
        return @as(usize, self.channels) * @as(usize, if (self.float32) 4 else 2);
    }
};

pub const Block = struct {
    data: []const u8,
    skip: u32 = 0,
    frames: u32,
    repeats: u32 = 0,
    user_data: u64 = 0,
};

pub const Cursor = struct {
    block: usize = 0,
    phase: u64 = 0,
    rate_remainder: u64 = 0,
    repeat: u32 = 0,
    decoded_frames: u64 = 0,
    decoded_bytes: u64 = 0,
    end_address: u64 = 0,
    user_data: u64 = 0,
};

pub const Stream = struct {
    format: Format,
    blocks: std.ArrayList(Block) = .empty,
    cursor: Cursor = .{},
    continuing: bool = false,
    pitch: f32 = 1,

    pub fn deinit(self: *Stream, allocator: std.mem.Allocator) void {
        self.blocks.deinit(allocator);
        self.blocks = .empty;
        self.cursor = .{};
    }

    pub fn clear(self: *Stream) void {
        self.blocks.clearRetainingCapacity();
        self.cursor = .{};
    }

    pub fn validate(self: *const Stream, block: Block) bool {
        if (self.format.channels == 0 or self.format.channels > 8 or self.format.rate == 0 or block.frames == 0) return false;
        const bytes = (@as(u64, block.skip) + block.frames) * self.format.frameBytes();
        return bytes <= block.data.len;
    }

    pub fn append(self: *Stream, allocator: std.mem.Allocator, blocks: []const Block, reset: bool, continuing: bool) !void {
        for (blocks) |block| if (!self.validate(block)) return error.InvalidBlock;
        const retained = if (reset) 0 else self.blocks.items.len - self.cursor.block;
        if (blocks.len > max_blocks - retained) return error.TooManyBlocks;
        // Validate and reserve before changing the live queue.
        try self.blocks.ensureTotalCapacity(allocator, retained + blocks.len);
        if (reset) {
            self.clear();
        } else if (self.cursor.block != 0) {
            std.mem.copyForwards(Block, self.blocks.items[0..retained], self.blocks.items[self.cursor.block..]);
            self.blocks.items.len = retained;
            self.cursor.block = 0;
        }
        self.blocks.appendSliceAssumeCapacity(blocks);
        self.continuing = continuing;
    }

    pub fn finished(self: *const Stream) bool {
        return !self.continuing and self.cursor.block >= self.blocks.items.len;
    }

    pub fn readAddress(self: *const Stream) u64 {
        if (self.cursor.block >= self.blocks.items.len) return self.cursor.end_address;
        const block = self.blocks.items[self.cursor.block];
        return @intFromPtr(block.data.ptr) + (@as(u64, block.skip) + (self.cursor.phase >> 32)) * self.format.frameBytes();
    }

    fn sample(self: *const Stream, block: Block, frame: usize, channel: usize) f32 {
        const source_channel = @min(channel, self.format.channels - 1);
        const offset = (frame + block.skip) * self.format.frameBytes() + source_channel * @as(usize, if (self.format.float32) 4 else 2);
        if (self.format.float32) {
            const value: f32 = @bitCast(std.mem.readInt(u32, block.data[offset..][0..4], .little));
            return if (std.math.isFinite(value)) std.math.clamp(value, -1, 1) else 0;
        }
        return @as(f32, @floatFromInt(std.mem.readInt(i16, block.data[offset..][0..2], .little))) / 32768.0;
    }

    fn nextSample(self: *const Stream, cursor: Cursor, channel: usize) f32 {
        const block = self.blocks.items[cursor.block];
        const frame: usize = @intCast(cursor.phase >> 32);
        if (frame + 1 < block.frames) return self.sample(block, frame + 1, channel);
        if (block.repeats == std.math.maxInt(u32) or cursor.repeat < block.repeats) return self.sample(block, 0, channel);
        if (cursor.block + 1 < self.blocks.items.len) return self.sample(self.blocks.items[cursor.block + 1], 0, channel);
        return self.sample(block, frame, channel);
    }

    fn advance(self: *const Stream, cursor: *Cursor, step: u64) void {
        var phase = cursor.phase + step;
        var old_frame = cursor.phase >> 32;
        while (cursor.block < self.blocks.items.len) {
            const block = self.blocks.items[cursor.block];
            const end = @as(u64, block.frames) * unit;
            const consumed = @min(phase >> 32, block.frames) - old_frame;
            cursor.decoded_frames +|= consumed;
            cursor.decoded_bytes +|= consumed * self.format.frameBytes();
            cursor.user_data = block.user_data;
            if (phase < end) {
                cursor.phase = phase;
                return;
            }
            phase -= end;
            old_frame = 0;
            cursor.end_address = @intFromPtr(block.data.ptr) + (@as(u64, block.skip) + block.frames) * self.format.frameBytes();
            if (block.repeats == std.math.maxInt(u32) or cursor.repeat < block.repeats) {
                cursor.repeat +|= 1;
            } else {
                cursor.block += 1;
                cursor.repeat = 0;
            }
        }
        // An empty streaming queue does not advance through unavailable data.
        cursor.phase = 0;
    }

    pub fn mix(self: *Stream, output: []f32, channels: usize, rate: u32, gain: f32, commit: bool) void {
        if (channels == 0 or rate == 0 or self.format.channels == 0) return;
        var cursor = self.cursor;
        const numerator: u64 = @intFromFloat(@round(@as(f64, @floatFromInt(self.format.rate)) * self.pitch * @as(f64, @floatFromInt(unit))));
        const step = numerator / rate;
        const remainder = numerator % rate;
        for (0..output.len / channels) |frame| {
            if (cursor.block >= self.blocks.items.len) break;
            const block = self.blocks.items[cursor.block];
            const source_frame: usize = @intCast(cursor.phase >> 32);
            const fraction: f32 = @floatCast(@as(f64, @floatFromInt(cursor.phase & (unit - 1))) / @as(f64, @floatFromInt(unit)));
            for (0..@min(channels, 2)) |channel| {
                const current = self.sample(block, source_frame, channel);
                const next = self.nextSample(cursor, channel);
                output[frame * channels + channel] += (current + (next - current) * fraction) * gain;
            }
            cursor.rate_remainder += remainder;
            self.advance(&cursor, step + cursor.rate_remainder / rate);
            cursor.rate_remainder %= rate;
        }
        if (commit) self.cursor = cursor;
    }
};

test "PCM streaming resamples across blocks and render calls without losing the read cursor" {
    var pcm: [441 * 4]u8 = undefined;
    for (0..441) |frame| {
        std.mem.writeInt(i16, pcm[frame * 4 ..][0..2], @intCast(frame * 32), .little);
        std.mem.writeInt(i16, pcm[frame * 4 + 2 ..][0..2], -@as(i16, @intCast(frame * 32)), .little);
    }
    var stream = Stream{ .format = .{ .channels = 2, .rate = 44100, .float32 = false } };
    defer stream.deinit(std.testing.allocator);
    try stream.append(std.testing.allocator, &.{ .{ .data = pcm[0..800], .frames = 200 }, .{ .data = pcm[800..], .frames = 241, .user_data = 123 } }, false, false);
    for (0..3) |grain| {
        var output: [160 * 2]f32 = @splat(0);
        stream.mix(&output, 2, 48000, 1, true);
        for (0..160) |frame| {
            const expected: f32 = @floatCast(@min(@as(f64, @floatFromInt(grain * 160 + frame)) * 44100 / 48000, 440) / 1024);
            try std.testing.expectApproxEqAbs(expected, output[frame * 2], 0.00001);
            try std.testing.expectApproxEqAbs(-expected, output[frame * 2 + 1], 0.00001);
        }
    }
    try std.testing.expect(stream.finished());
    try std.testing.expectEqual(@as(u64, 441), stream.cursor.decoded_frames);
    try std.testing.expectEqual(@as(u64, pcm.len), stream.cursor.decoded_bytes);
    try std.testing.expectEqual(@intFromPtr(&pcm) + pcm.len, stream.readAddress());
}

test "PCM block repeats skips and streaming refill preserve samples and reject malformed geometry" {
    const pcm = [_]u8{ 0, 0, 0, 0x20, 0, 0x40 };
    var stream = Stream{ .format = .{ .channels = 1, .rate = 48000, .float32 = false } };
    defer stream.deinit(std.testing.allocator);
    try stream.append(std.testing.allocator, &.{.{ .data = &pcm, .skip = 1, .frames = 2, .repeats = 1 }}, false, true);
    var output: [5]f32 = @splat(0);
    stream.mix(&output, 1, 48000, 1, false);
    try std.testing.expectEqual(@as(u64, 0), stream.cursor.decoded_frames);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.5, 0.25, 0.5, 0 }, &output);
    @memset(&output, 0);
    stream.mix(&output, 1, 48000, 1, true);
    try std.testing.expect(!stream.finished());
    try stream.append(std.testing.allocator, &.{.{ .data = &pcm, .skip = 1, .frames = 2 }}, false, false);
    try std.testing.expectError(error.InvalidBlock, stream.append(std.testing.allocator, &.{.{ .data = &pcm, .skip = 2, .frames = 2 }}, true, false));
    @memset(&output, 0);
    stream.mix(&output, 1, 48000, 1, true);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.5, 0, 0, 0 }, &output);
    try std.testing.expect(stream.finished());
}

test "PCM float streams preserve channel polarity and sanitize non-finite samples" {
    const values = [_]f32{ 0.25, -0.5, std.math.nan(f32), std.math.inf(f32), 2, -2 };
    var data: [values.len * 4]u8 = undefined;
    for (values, 0..) |value, index| std.mem.writeInt(u32, data[index * 4 ..][0..4], @bitCast(value), .little);
    var stream = Stream{ .format = .{ .channels = 2, .rate = 48000, .float32 = true } };
    defer stream.deinit(std.testing.allocator);
    try stream.append(std.testing.allocator, &.{.{ .data = &data, .frames = 3 }}, false, false);
    var output: [6]f32 = @splat(0);
    stream.mix(&output, 2, 48000, 1, true);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, -0.5, 0, 0, 1, -1 }, &output);
}
