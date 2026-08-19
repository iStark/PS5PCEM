// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Stateful host decoders behind the guest AJM job ABI.
//!
//! ATRAC9 is decoded by the pinned MIT LibAtrac9 dependency. MP3 is decoded by
//! minimp3 (CC0). MPEG-4 AAC uses FAAD2 and Opus uses libopus. This file owns
//! codec state and byte accounting; the guest-facing library only validates
//! handles and marshals sparse buffers.

const std = @import("std");

const c = @cImport({
    @cDefine("NEAACDECAPI", "");
    @cDefine("FAAD2_VERSION", "2.11.2");
    @cInclude("libatrac9.h");
    @cInclude("minimp3.h");
    @cInclude("neaacdec.h");
    @cInclude("opus.h");
});

pub const codec_mp3: u32 = 0;
pub const codec_atrac9: u32 = 1;
pub const codec_m4aac: u32 = 2;
pub const codec_opus: u32 = 24;

pub const aac_config_adts: u32 = 1;
pub const aac_config_raw: u32 = 2;
pub const aac_config_saf: u32 = 3;

const aac_sbr_flag: u64 = 1 << 32;
const aac_nondelay_flag: u64 = 1 << 33;

const opus_default_frame_samples: u32 = 960;
const opus_maximum_frame_samples: u32 = 5760;

pub const result_not_initialized: i32 = 0x0000_0001;
pub const result_invalid_data: i32 = 0x0000_0002;
pub const result_invalid_parameter: i32 = 0x0000_0004;
pub const result_partial_input: i32 = 0x0000_0008;
pub const result_not_enough_room: i32 = 0x0000_0010;
pub const result_unsupported_flag: i32 = 0x0000_0080;
pub const result_codec_fatal: i32 = @bitCast(@as(u32, 0xc000_0000));

const maximum_input_bytes = 64 * 1024 * 1024;
const maximum_frame_pcm_bytes = 64 * 1024;

pub const Report = struct {
    result: i32 = 0,
    internal_result: i32 = 0,
    consumed: usize = 0,
    produced: usize = 0,
    total_samples: u64 = 0,
    frames: u32 = 0,
};

pub const CodecInfo = struct {
    channels: u32 = 0,
    sample_rate: u32 = 0,
    bitrate: u32 = 0,
    frame_samples: u32 = 0,
    superframe_size: u32 = 0,
    frames_in_superframe: u32 = 0,
    next_frame_size: u32 = 0,
    mp3_header: u32 = 0,
    heaac: u32 = 0,
    frames_per_packet: u32 = 0,
};

pub fn isSupported(codec: u32) bool {
    return switch (codec) {
        codec_mp3, codec_atrac9, codec_m4aac, codec_opus => true,
        else => false,
    };
}

pub fn codecName(codec: u32) []const u8 {
    return switch (codec) {
        codec_mp3 => "mp3",
        codec_atrac9 => "atrac9",
        codec_m4aac => "aac",
        codec_opus => "opus",
        else => "unknown",
    };
}

const SampleEncoding = enum(u2) {
    signed16 = 0,
    signed32 = 1,
    float32 = 2,
};

pub const Error = error{
    OutOfMemory,
    UnsupportedCodec,
};

pub const Decoder = struct {
    codec: u32 = codec_mp3,
    flags: u64 = 0,
    encoding: SampleEncoding = .signed16,

    at9_handle: ?*anyopaque = null,
    at9_initialized: bool = false,
    at9_config: [4]u8 = @splat(0),
    at9_info: c.Atrac9CodecInfo = undefined,
    at9_frame_in_superframe: u32 = 0,
    at9_superframe_remaining: u32 = 0,

    mp3_state: c.mp3dec_t = undefined,
    mp3_channels: u32 = 0,
    mp3_sample_rate: u32 = 0,
    mp3_bitrate: u32 = 0,
    mp3_header: u32 = 0,
    mp3_frame_samples: u32 = 0,

    aac_handle: ?*anyopaque = null,
    aac_opened: bool = false,
    aac_config: u32 = aac_config_adts,
    aac_freq_index: u32 = 3,
    aac_skip_frames: u32 = 0,
    aac_channels: u32 = 0,
    aac_sample_rate: u32 = 0,
    aac_bitrate: u32 = 0,
    aac_frame_samples: u32 = 0,
    aac_heaac: u32 = 0,

    opus_decoder: ?*c.OpusDecoder = null,
    opus_channels: u32 = 0,
    opus_sample_rate: u32 = 0,
    opus_mapping_family: u32 = 0,
    opus_frames_per_packet: u32 = 1,
    opus_initialized: bool = false,

    gapless_total: u64 = 0,
    gapless_remaining: u64 = 0,
    gapless_skip: u32 = 0,
    gapless_skip_remaining: u32 = 0,
    total_samples: u64 = 0,

    pub fn create(codec: u32, flags: u64) Error!Decoder {
        const raw_encoding: u3 = @truncate(flags >> 7);
        const encoding: SampleEncoding = switch (raw_encoding) {
            0 => .signed16,
            1 => .signed32,
            2 => .float32,
            else => return Error.UnsupportedCodec,
        };
        if (!isSupported(codec)) return Error.UnsupportedCodec;
        var self = Decoder{ .codec = codec, .flags = flags, .encoding = encoding };
        switch (codec) {
            codec_atrac9 => {
                self.at9_handle = c.Atrac9GetHandle() orelse return Error.OutOfMemory;
            },
            codec_mp3 => c.mp3dec_init(&self.mp3_state),
            codec_m4aac => {
                self.aac_channels = flagChannelCount(flags);
                self.aac_sample_rate = 48_000;
            },
            codec_opus => {
                self.opus_channels = flagChannelCount(flags);
                self.opus_sample_rate = 48_000;
            },
            else => return Error.UnsupportedCodec,
        }
        return self;
    }

    pub fn deinit(self: *Decoder) void {
        if (self.at9_handle) |handle| c.Atrac9ReleaseHandle(handle);
        self.at9_handle = null;
        self.at9_initialized = false;
        self.closeAac();
        self.destroyOpus();
    }

    pub fn reset(self: *Decoder) void {
        self.total_samples = 0;
        self.gapless_remaining = self.gapless_total;
        self.gapless_skip_remaining = self.gapless_skip;
        switch (self.codec) {
            codec_atrac9 => {
                self.at9_frame_in_superframe = 0;
                self.at9_superframe_remaining = 0;
                if (self.at9_initialized) {
                    const config = self.at9_config;
                    _ = self.initializeAtrac9(&config);
                }
            },
            codec_mp3 => {
                c.mp3dec_init(&self.mp3_state);
                self.mp3_channels = 0;
                self.mp3_sample_rate = 0;
                self.mp3_bitrate = 0;
                self.mp3_header = 0;
                self.mp3_frame_samples = 0;
            },
            codec_m4aac => {
                self.closeAac();
                self.aac_skip_frames = if (self.flags & aac_nondelay_flag != 0) 0 else 2;
                self.aac_bitrate = 0;
                self.aac_frame_samples = 0;
                self.aac_heaac = 0;
            },
            codec_opus => {
                self.opus_frames_per_packet = 1;
            },
            else => {},
        }
    }

    pub fn initialize(self: *Decoder, parameters: []const u8) Report {
        self.reset();
        return switch (self.codec) {
            codec_atrac9 => self.initializeAtrac9(parameters),
            codec_mp3 => .{},
            codec_m4aac => self.initializeAac(parameters),
            codec_opus => self.initializeOpus(parameters),
            else => .{ .result = result_unsupported_flag },
        };
    }

    fn initializeAtrac9(self: *Decoder, parameters: []const u8) Report {
        if (parameters.len < self.at9_config.len) return .{ .result = result_invalid_parameter };
        const handle = self.at9_handle orelse return .{ .result = result_not_initialized };
        @memcpy(&self.at9_config, parameters[0..self.at9_config.len]);
        const status = c.Atrac9InitDecoder(handle, @ptrCast(&self.at9_config));
        if (status != 0) {
            self.at9_initialized = false;
            return .{ .result = result_codec_fatal, .internal_result = @intCast(status) };
        }
        const info_status = c.Atrac9GetCodecInfo(handle, &self.at9_info);
        if (info_status != 0 or
            self.at9_info.channels <= 0 or self.at9_info.channels > 8 or
            self.at9_info.frameSamples <= 0 or self.at9_info.frameSamples > 2048 or
            self.at9_info.superframeSize <= 0 or self.at9_info.framesInSuperframe <= 0)
        {
            self.at9_initialized = false;
            return .{ .result = result_codec_fatal, .internal_result = @intCast(info_status) };
        }
        self.at9_initialized = true;
        self.at9_frame_in_superframe = 0;
        self.at9_superframe_remaining = @intCast(self.at9_info.superframeSize);
        return .{};
    }

    pub fn setGapless(self: *Decoder, total_samples: u32, skip_samples: u16) void {
        self.gapless_total = total_samples;
        self.gapless_remaining = total_samples;
        self.gapless_skip = skip_samples;
        self.gapless_skip_remaining = skip_samples;
        self.total_samples = 0;
    }

    pub fn decode(self: *Decoder, input: []const u8, output: []u8) Report {
        const bounded_input = input[0..@min(input.len, maximum_input_bytes)];
        var report = switch (self.codec) {
            codec_atrac9 => self.decodeAtrac9(bounded_input, output),
            codec_mp3 => self.decodeMp3(bounded_input, output),
            codec_m4aac => self.decodeAac(bounded_input, output),
            codec_opus => self.decodeOpus(bounded_input, output),
            else => Report{ .result = result_unsupported_flag },
        };
        report.total_samples = self.total_samples;
        return report;
    }

    pub fn codecInfo(self: *const Decoder) CodecInfo {
        return switch (self.codec) {
            codec_atrac9 => if (self.at9_initialized) .{
                .channels = @intCast(self.at9_info.channels),
                .sample_rate = @intCast(self.at9_info.samplingRate),
                .bitrate = @intCast(@divTrunc(
                    @as(i64, self.at9_info.samplingRate) * self.at9_info.superframeSize * 8,
                    @as(i64, self.at9_info.framesInSuperframe) * self.at9_info.frameSamples,
                )),
                .frame_samples = @intCast(self.at9_info.frameSamples),
                .superframe_size = @intCast(self.at9_info.superframeSize),
                .frames_in_superframe = @intCast(self.at9_info.framesInSuperframe),
                .next_frame_size = self.at9_superframe_remaining,
            } else .{},
            codec_mp3 => .{
                .channels = self.mp3_channels,
                .sample_rate = self.mp3_sample_rate,
                .bitrate = self.mp3_bitrate,
                .frame_samples = self.mp3_frame_samples,
                .mp3_header = self.mp3_header,
            },
            codec_m4aac => .{
                .channels = self.aac_channels,
                .sample_rate = self.aac_sample_rate,
                .bitrate = self.aac_bitrate,
                .frame_samples = self.aac_frame_samples,
                .heaac = self.aac_heaac,
            },
            codec_opus => .{
                .channels = self.opus_channels,
                .sample_rate = self.opus_sample_rate,
                .frame_samples = opus_default_frame_samples,
                .frames_per_packet = self.opus_frames_per_packet,
            },
            else => .{},
        };
    }

    fn sampleBytes(self: *const Decoder) usize {
        return switch (self.encoding) {
            .signed16 => 2,
            .signed32, .float32 => 4,
        };
    }

    fn selectedFrames(self: *const Decoder, frame_samples: u32) struct { skip: u32, count: u32 } {
        const skip = @min(frame_samples, self.gapless_skip_remaining);
        var count = frame_samples - skip;
        if (self.gapless_total != 0) count = @intCast(@min(@as(u64, count), self.gapless_remaining));
        return .{ .skip = skip, .count = count };
    }

    fn commitFrames(self: *Decoder, selection: anytype) void {
        self.gapless_skip_remaining -= selection.skip;
        if (self.gapless_total != 0) self.gapless_remaining -= selection.count;
        self.total_samples +%= selection.count;
    }

    fn decodeAtrac9(self: *Decoder, input: []const u8, output: []u8) Report {
        var report = Report{};
        if (((self.flags >> 32) & 1) != 0 and input.len >= 12 and std.mem.eql(u8, input[0..4], "RIFF")) {
            const riff = parseAtrac9Riff(input) orelse return .{ .result = result_invalid_data };
            const initialized = self.initializeAtrac9(&riff.config);
            if (initialized.result != 0) return initialized;
            self.setGapless(riff.total_samples, riff.skip_samples);
            report.consumed = riff.data_offset;
        }
        if (!self.at9_initialized) return .{ .result = result_not_initialized };
        const handle = self.at9_handle orelse return .{ .result = result_not_initialized };
        const channels: usize = @intCast(self.at9_info.channels);
        const frame_samples: u32 = @intCast(self.at9_info.frameSamples);
        const sample_bytes = self.sampleBytes();
        const full_pcm_bytes = @as(usize, frame_samples) * channels * sample_bytes;
        if (full_pcm_bytes > maximum_frame_pcm_bytes) return .{ .result = result_codec_fatal };

        var pcm: [maximum_frame_pcm_bytes]u8 align(16) = undefined;
        while (report.consumed < input.len) {
            const input_left = input.len - report.consumed;
            if (input_left < self.at9_superframe_remaining) {
                report.result |= result_partial_input;
                break;
            }
            const selected = self.selectedFrames(frame_samples);
            const selected_bytes = @as(usize, selected.count) * channels * sample_bytes;
            if (selected_bytes > output.len - report.produced) {
                report.result |= result_not_enough_room;
                break;
            }

            var used: c_int = 0;
            const encoded = input[report.consumed..];
            const encoded_len: c_int = @intCast(@min(encoded.len, @as(usize, std.math.maxInt(c_int))));
            const no_interleave: c_int = if (((self.flags >> 32) & (1 << 8)) != 0) 1 else 0;
            const status = switch (self.encoding) {
                .signed16 => c.Atrac9Decode(handle, encoded.ptr, encoded_len, @ptrCast(&pcm), &used, no_interleave),
                .signed32 => c.Atrac9DecodeS32(handle, encoded.ptr, encoded_len, @ptrCast(&pcm), &used, no_interleave),
                .float32 => c.Atrac9DecodeF32(handle, encoded.ptr, encoded_len, @ptrCast(&pcm), &used, no_interleave),
            };
            if (status != 0 or used <= 0 or used > self.at9_superframe_remaining) {
                report.result |= result_codec_fatal;
                report.internal_result = @intCast(status);
                break;
            }

            const used_bytes: u32 = @intCast(used);
            report.consumed += used_bytes;
            self.at9_superframe_remaining -= used_bytes;
            self.at9_frame_in_superframe += 1;
            report.frames += 1;

            if (selected.count != 0) {
                if (no_interleave == 0) {
                    const start = @as(usize, selected.skip) * channels * sample_bytes;
                    @memcpy(output[report.produced..][0..selected_bytes], pcm[start..][0..selected_bytes]);
                } else {
                    const plane_bytes = @as(usize, frame_samples) * sample_bytes;
                    const kept_plane_bytes = @as(usize, selected.count) * sample_bytes;
                    for (0..channels) |channel| {
                        const source = channel * plane_bytes + @as(usize, selected.skip) * sample_bytes;
                        const destination = report.produced + channel * kept_plane_bytes;
                        @memcpy(output[destination..][0..kept_plane_bytes], pcm[source..][0..kept_plane_bytes]);
                    }
                }
                report.produced += selected_bytes;
            }
            self.commitFrames(selected);

            if (self.at9_frame_in_superframe == self.at9_info.framesInSuperframe) {
                if (report.consumed + self.at9_superframe_remaining > input.len) {
                    report.result |= result_partial_input;
                    break;
                }
                report.consumed += self.at9_superframe_remaining;
                self.at9_superframe_remaining = @intCast(self.at9_info.superframeSize);
                self.at9_frame_in_superframe = 0;
            }
        }
        return report;
    }

    fn decodeMp3(self: *Decoder, input: []const u8, output: []u8) Report {
        var report = Report{};
        var pcm: [c.MINIMP3_MAX_SAMPLES_PER_FRAME]c.mp3d_sample_t align(16) = undefined;
        while (report.consumed < input.len) {
            // Decode against a copy first. If the guest output is too short the
            // job must be retryable without advancing the MP3 bit reservoir.
            var next_state = self.mp3_state;
            var frame_info: c.mp3dec_frame_info_t = undefined;
            const encoded = input[report.consumed..];
            const encoded_len: c_int = @intCast(@min(encoded.len, @as(usize, std.math.maxInt(c_int))));
            const samples = c.mp3dec_decode_frame(&next_state, encoded.ptr, encoded_len, &pcm, &frame_info);
            if (frame_info.frame_bytes <= 0) {
                report.result |= result_partial_input;
                break;
            }
            const consumed: usize = @intCast(frame_info.frame_bytes);
            if (consumed > encoded.len) {
                report.result |= result_invalid_data;
                break;
            }
            if (samples <= 0) {
                self.mp3_state = next_state;
                report.consumed += consumed;
                continue;
            }
            if (frame_info.channels <= 0 or frame_info.channels > 2) {
                report.result |= result_invalid_data;
                break;
            }

            const channels: usize = @intCast(frame_info.channels);
            const frame_samples: u32 = @intCast(samples);
            const selected = self.selectedFrames(frame_samples);
            const selected_values = @as(usize, selected.count) * channels;
            const selected_bytes = selected_values * self.sampleBytes();
            if (selected_bytes > output.len - report.produced) {
                report.result |= result_not_enough_room;
                break;
            }
            self.mp3_state = next_state;
            report.consumed += consumed;
            const source_start = @as(usize, selected.skip) * channels;
            self.writeMp3Samples(pcm[source_start..][0..selected_values], output[report.produced..][0..selected_bytes]);
            report.produced += selected_bytes;
            report.frames += 1;
            self.commitFrames(selected);
            self.mp3_channels = @intCast(frame_info.channels);
            self.mp3_sample_rate = @intCast(frame_info.hz);
            self.mp3_bitrate = @as(u32, @intCast(frame_info.bitrate_kbps)) * 1000;
            self.mp3_frame_samples = frame_samples;
            const header_offset: usize = @intCast(@max(frame_info.frame_offset, 0));
            if (header_offset + 4 <= encoded.len) self.mp3_header = std.mem.readInt(u32, encoded[header_offset..][0..4], .little);
        }
        return report;
    }

    fn flagChannelCount(flags: u64) u32 {
        const count: u32 = @truncate(flags & 0x7f);
        return if (count == 0) 2 else @min(count, 8);
    }

    fn closeAac(self: *Decoder) void {
        if (self.aac_handle) |handle| c.NeAACDecClose(handle);
        self.aac_handle = null;
        self.aac_opened = false;
    }

    fn destroyOpus(self: *Decoder) void {
        if (self.opus_decoder) |decoder| c.opus_decoder_destroy(decoder);
        self.opus_decoder = null;
        self.opus_initialized = false;
    }

    fn aacRates() [12]u32 {
        return .{ 96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000 };
    }

    fn initializeAac(self: *Decoder, parameters: []const u8) Report {
        if (parameters.len < 8) return .{ .result = result_invalid_parameter };
        const config = std.mem.readInt(u32, parameters[0..4], .little);
        const freq_index = std.mem.readInt(u32, parameters[4..8], .little);
        if (config < aac_config_adts or config > aac_config_saf) return .{ .result = result_invalid_parameter };
        if (config == aac_config_raw and freq_index > 11) return .{ .result = result_invalid_parameter };

        self.closeAac();
        const handle = c.NeAACDecOpen() orelse return .{ .result = result_codec_fatal };
        self.aac_handle = handle;
        if (c.NeAACDecGetCurrentConfiguration(handle)) |cfg| {
            cfg.*.outputFormat = switch (self.encoding) {
                .signed16 => c.FAAD_FMT_16BIT,
                .signed32 => c.FAAD_FMT_32BIT,
                .float32 => c.FAAD_FMT_FLOAT,
            };
            cfg.*.dontUpSampleImplicitSBR = if (self.flags & aac_sbr_flag != 0) 0 else 1;
            _ = c.NeAACDecSetConfiguration(handle, cfg);
        }

        self.aac_config = config;
        self.aac_freq_index = freq_index;
        self.aac_skip_frames = if (self.flags & aac_nondelay_flag != 0) 0 else 2;
        if (config == aac_config_raw) {
            const rates = aacRates();
            const channel_config: u32 = @min(self.aac_channels, 7);
            var extra = [_]u8{
                @truncate((@as(u32, 2) << 3) | (freq_index >> 1)),
                @truncate(((freq_index & 1) << 7) | (channel_config << 3)),
            };
            var sample_rate: c_ulong = 0;
            var channels: u8 = 0;
            const status = c.NeAACDecInit2(handle, &extra, extra.len, &sample_rate, &channels);
            if (status != 0) {
                self.closeAac();
                return .{ .result = result_codec_fatal, .internal_result = status };
            }
            self.aac_opened = true;
            if (channels != 0) self.aac_channels = channels;
            if (sample_rate != 0) self.aac_sample_rate = @intCast(sample_rate) else self.aac_sample_rate = rates[freq_index];
        } else {
            self.aac_sample_rate = aacRates()[@min(freq_index, 11)];
        }
        return .{};
    }

    fn ensureAacOpened(self: *Decoder, input: []const u8) Report {
        if (self.aac_opened) return .{};
        const handle = self.aac_handle orelse return .{ .result = result_not_initialized };
        if (input.len == 0) return .{ .result = result_partial_input };
        var sample_rate: c_ulong = 0;
        var channels: u8 = 0;
        const consumed = c.NeAACDecInit(handle, @ptrCast(@constCast(input.ptr)), @intCast(input.len), &sample_rate, &channels);
        if (consumed < 0) return .{ .result = result_codec_fatal, .internal_result = consumed };
        self.aac_opened = true;
        if (channels != 0) self.aac_channels = channels;
        if (sample_rate != 0) self.aac_sample_rate = @intCast(sample_rate);
        return .{ .consumed = @intCast(consumed) };
    }

    fn decodeAac(self: *Decoder, input: []const u8, output: []u8) Report {
        var report = Report{};
        if (self.aac_handle == null) return .{ .result = result_not_initialized };
        const opened = self.ensureAacOpened(input);
        if (opened.result != 0) return opened;
        report.consumed = opened.consumed;
        const handle = self.aac_handle orelse return .{ .result = result_not_initialized };

        while (report.consumed < input.len) {
            var frame_info: c.NeAACDecFrameInfo = std.mem.zeroes(c.NeAACDecFrameInfo);
            const remain = input[report.consumed..];
            const decoded = c.NeAACDecDecode(
                handle,
                &frame_info,
                @ptrCast(@constCast(remain.ptr)),
                @intCast(remain.len),
            );
            if (frame_info.@"error" != 0) {
                report.result |= result_invalid_data;
                report.internal_result = frame_info.@"error";
                break;
            }
            if (frame_info.bytesconsumed == 0) {
                report.result |= result_partial_input;
                break;
            }
            report.consumed += frame_info.bytesconsumed;
            if (decoded == null or frame_info.samples == 0 or frame_info.channels == 0) continue;
            if (self.aac_skip_frames != 0) {
                self.aac_skip_frames -= 1;
                continue;
            }

            const channels: u32 = frame_info.channels;
            const frame_samples: u32 = @intCast(frame_info.samples / channels);
            self.aac_channels = channels;
            if (frame_info.samplerate != 0) self.aac_sample_rate = frame_info.samplerate;
            self.aac_frame_samples = frame_samples;
            self.aac_heaac = if (frame_info.sbr != 0 or frame_info.ps != 0) 1 else 0;
            if (frame_info.samplerate != 0 and frame_samples != 0) {
                const bits = remain.len * 8;
                self.aac_bitrate = @intCast(@divTrunc(bits * frame_info.samplerate, frame_samples));
            }

            const pcm: [*]const u8 = @ptrCast(decoded);
            const pcm_bytes = pcm[0 .. @as(usize, frame_info.samples) * self.sampleBytes()];
            const selected = self.selectedFrames(frame_samples);
            const selected_bytes = @as(usize, selected.count) * channels * self.sampleBytes();
            if (selected_bytes > output.len - report.produced) {
                report.result |= result_not_enough_room;
                break;
            }
            if (selected.count != 0) {
                const start = @as(usize, selected.skip) * channels * self.sampleBytes();
                @memcpy(output[report.produced..][0..selected_bytes], pcm_bytes[start..][0..selected_bytes]);
                report.produced += selected_bytes;
            }
            report.frames += 1;
            self.commitFrames(selected);
        }
        return report;
    }

    fn initializeOpus(self: *Decoder, parameters: []const u8) Report {
        if (parameters.len < 12) return .{ .result = result_invalid_parameter };
        const channels = std.mem.readInt(u32, parameters[0..4], .little);
        const sample_rate = std.mem.readInt(u32, parameters[4..8], .little);
        const mapping_family = std.mem.readInt(u32, parameters[8..12], .little);
        if (channels == 0 or channels > 8 or sample_rate == 0) return .{ .result = result_invalid_parameter };
        if (mapping_family != 0 and channels > 2) return .{ .result = result_invalid_parameter };

        self.destroyOpus();
        var status: c_int = 0;
        const decoder = c.opus_decoder_create(@intCast(sample_rate), @intCast(channels), &status);
        if (decoder == null or status != c.OPUS_OK) {
            return .{ .result = result_codec_fatal, .internal_result = status };
        }
        self.opus_decoder = decoder;
        self.opus_channels = channels;
        self.opus_sample_rate = sample_rate;
        self.opus_mapping_family = mapping_family;
        self.opus_frames_per_packet = 1;
        self.opus_initialized = true;
        return .{};
    }

    fn decodeOpus(self: *Decoder, input: []const u8, output: []u8) Report {
        if (!self.opus_initialized) return .{ .result = result_not_initialized };
        const decoder = self.opus_decoder orelse return .{ .result = result_not_initialized };
        if (input.len == 0) return .{ .result = result_partial_input };
        if (input.len > std.math.maxInt(c_int)) return .{ .result = result_invalid_parameter };

        var pcm: [opus_maximum_frame_samples * 8]i16 align(16) = undefined;
        const max_samples: c_int = @intCast(pcm.len / self.opus_channels);
        const decoded = c.opus_decode(
            decoder,
            input.ptr,
            @intCast(input.len),
            &pcm,
            max_samples,
            0,
        );
        if (decoded < 0) return .{ .result = result_invalid_data, .internal_result = decoded };

        const frame_samples: u32 = @intCast(decoded);
        const selected = self.selectedFrames(frame_samples);
        const selected_values = @as(usize, selected.count) * self.opus_channels;
        const selected_bytes = selected_values * self.sampleBytes();
        if (selected_bytes > output.len) return .{
            .result = result_not_enough_room,
            .consumed = input.len,
            .frames = 1,
        };

        const source_start = @as(usize, selected.skip) * self.opus_channels;
        self.writePcm16(pcm[source_start..][0..selected_values], output[0..selected_bytes]);
        self.commitFrames(selected);
        self.opus_frames_per_packet = 1;
        return .{
            .consumed = input.len,
            .produced = selected_bytes,
            .frames = 1,
        };
    }

    fn writePcm16(self: *const Decoder, samples: []const i16, output: []u8) void {
        switch (self.encoding) {
            .signed16 => @memcpy(output, std.mem.sliceAsBytes(samples)),
            .signed32 => for (samples, 0..) |sample, index| {
                const expanded: i32 = @as(i32, sample) * 65_536;
                std.mem.writeInt(i32, output[index * 4 ..][0..4], expanded, .little);
            },
            .float32 => for (samples, 0..) |sample, index| {
                const value = @as(f32, @floatFromInt(sample)) / 32768.0;
                std.mem.writeInt(u32, output[index * 4 ..][0..4], @bitCast(value), .little);
            },
        }
    }

    fn writeMp3Samples(self: *const Decoder, samples: []const c.mp3d_sample_t, output: []u8) void {
        switch (self.encoding) {
            .signed16 => @memcpy(output, std.mem.sliceAsBytes(samples)),
            .signed32 => for (samples, 0..) |sample, index| {
                const expanded: i32 = @as(i32, sample) * 65_536;
                std.mem.writeInt(i32, output[index * 4 ..][0..4], expanded, .little);
            },
            .float32 => for (samples, 0..) |sample, index| {
                const value = @as(f32, @floatFromInt(sample)) / 32768.0;
                std.mem.writeInt(u32, output[index * 4 ..][0..4], @bitCast(value), .little);
            },
        }
    }
};

const Atrac9Riff = struct {
    config: [4]u8,
    data_offset: usize,
    total_samples: u32 = 0,
    skip_samples: u16 = 0,
};

fn parseAtrac9Riff(bytes: []const u8) ?Atrac9Riff {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return null;
    var result: ?Atrac9Riff = null;
    var total_samples: u32 = 0;
    var skip_samples: u16 = 0;
    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const tag = bytes[offset..][0..4];
        const chunk_size: usize = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const data = offset + 8;
        if (chunk_size > bytes.len - data) return null;
        if (std.mem.eql(u8, tag, "fmt ") and chunk_size >= 48) {
            var config: [4]u8 = undefined;
            @memcpy(&config, bytes[data + 44 ..][0..4]);
            result = .{ .config = config, .data_offset = 0 };
        } else if (std.mem.eql(u8, tag, "fact") and chunk_size >= 8) {
            total_samples = std.mem.readInt(u32, bytes[data..][0..4], .little);
            skip_samples = @intCast(@min(std.mem.readInt(u32, bytes[data + 4 ..][0..4], .little), std.math.maxInt(u16)));
        } else if (std.mem.eql(u8, tag, "data")) {
            var parsed = result orelse return null;
            parsed.data_offset = data;
            parsed.total_samples = total_samples;
            parsed.skip_samples = skip_samples;
            return parsed;
        }
        offset = data + chunk_size + (chunk_size & 1);
    }
    return null;
}

test "ATRAC9 initialization exposes the configured stream geometry" {
    // 48 kHz, coupled stereo, 96-byte frame, one frame per superframe.
    const config_word: u32 = (@as(u32, 0xfe) << 24) |
        (@as(u32, 7) << 20) |
        (@as(u32, 2) << 17) |
        (@as(u32, 95) << 5);
    var config: [4]u8 = undefined;
    std.mem.writeInt(u32, &config, config_word, .big);

    var decoder = try Decoder.create(codec_atrac9, 1);
    defer decoder.deinit();
    const initialized = decoder.initialize(&config);
    try std.testing.expectEqual(@as(i32, 0), initialized.result);
    const info = decoder.codecInfo();
    try std.testing.expectEqual(@as(u32, 2), info.channels);
    try std.testing.expectEqual(@as(u32, 48_000), info.sample_rate);
    try std.testing.expectEqual(@as(u32, 96), info.superframe_size);
    try std.testing.expectEqual(@as(u32, 256), info.frame_samples);
}

test "ATRAC9 invalid frame returns a codec error without writing PCM" {
    const config_word: u32 = (@as(u32, 0xfe) << 24) |
        (@as(u32, 7) << 20) |
        (@as(u32, 2) << 17) |
        (@as(u32, 95) << 5);
    var config: [4]u8 = undefined;
    std.mem.writeInt(u32, &config, config_word, .big);
    var decoder = try Decoder.create(codec_atrac9, 1);
    defer decoder.deinit();
    try std.testing.expectEqual(@as(i32, 0), decoder.initialize(&config).result);

    const invalid_frame = [_]u8{0} ** 96;
    var output: [256 * 2 * 2]u8 = @splat(0xa5);
    const report = decoder.decode(&invalid_frame, &output);
    try std.testing.expectEqual(result_codec_fatal, report.result);
    try std.testing.expectEqual(@as(usize, 0), report.consumed);
    try std.testing.expectEqual(@as(usize, 0), report.produced);
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xa5));
}

test "ATRAC9 RIFF stream initializes from its fmt chunk" {
    const config_word: u32 = (@as(u32, 0xfe) << 24) |
        (@as(u32, 7) << 20) |
        (@as(u32, 2) << 17) |
        (@as(u32, 95) << 5);
    var riff: [80]u8 = @splat(0);
    @memcpy(riff[0..4], "RIFF");
    std.mem.writeInt(u32, riff[4..8], riff.len - 8, .little);
    @memcpy(riff[8..12], "WAVE");
    @memcpy(riff[12..16], "fmt ");
    std.mem.writeInt(u32, riff[16..20], 52, .little);
    std.mem.writeInt(u16, riff[20..22], 0xfffe, .little);
    var config: [4]u8 = undefined;
    std.mem.writeInt(u32, &config, config_word, .big);
    @memcpy(riff[64..68], &config);
    @memcpy(riff[72..76], "data");
    std.mem.writeInt(u32, riff[76..80], 0, .little);

    // Codec flag bit 0 lives at bit 32 of the instance flags.
    var decoder = try Decoder.create(codec_atrac9, (@as(u64, 1) << 32) | 1);
    defer decoder.deinit();
    const report = decoder.decode(&riff, &.{});
    try std.testing.expectEqual(@as(i32, 0), report.result);
    try std.testing.expectEqual(@as(usize, riff.len), report.consumed);
    try std.testing.expectEqual(@as(u32, 48_000), decoder.codecInfo().sample_rate);
}

test "MP3 decoder produces PCM and reports actual byte counts" {
    // A syntactically valid MPEG-1 Layer III 128 kb/s frame. Zero main data
    // decodes to silence but still exercises the real bitstream decoder.
    var frame: [417]u8 = @splat(0);
    frame[0..4].* = .{ 0xff, 0xfb, 0x90, 0x64 };
    var output: [c.MINIMP3_MAX_SAMPLES_PER_FRAME * 2]u8 = undefined;
    var decoder = try Decoder.create(codec_mp3, 1);
    defer decoder.deinit();
    const report = decoder.decode(&frame, &output);
    try std.testing.expectEqual(@as(i32, 0), report.result);
    try std.testing.expectEqual(@as(usize, frame.len), report.consumed);
    try std.testing.expect(report.produced != 0);
    try std.testing.expectEqual(@as(u32, 1), report.frames);
    try std.testing.expectEqual(@as(u32, 44_100), decoder.codecInfo().sample_rate);
}

test "mono MP3 accepts an exact one-frame output buffer" {
    var frame: [417]u8 = @splat(0);
    frame[0..4].* = .{ 0xff, 0xfb, 0x90, 0xc0 };
    var output: [1152 * 2]u8 = undefined;
    var decoder = try Decoder.create(codec_mp3, 1);
    defer decoder.deinit();
    const report = decoder.decode(&frame, &output);
    try std.testing.expectEqual(@as(i32, 0), report.result);
    try std.testing.expectEqual(@as(usize, output.len), report.produced);
    try std.testing.expectEqual(@as(u32, 1), decoder.codecInfo().channels);
}

test "unknown AJM codecs stay unsupported" {
    try std.testing.expectError(Error.UnsupportedCodec, Decoder.create(3, 1));
    try std.testing.expectError(Error.UnsupportedCodec, Decoder.create(14, 1));
    try std.testing.expect(isSupported(codec_m4aac));
    try std.testing.expect(isSupported(codec_opus));
}

test "MPEG-4 AAC ADTS decodes a real stereo frame" {
    const adts = [_]u8{
        0xff, 0xf1, 0x4c, 0x80, 0x03, 0xdf, 0xfc, 0xde, 0x02, 0x00, 0x4c, 0x61, 0x76, 0x63, 0x36,
        0x32, 0x2e, 0x32, 0x38, 0x2e, 0x31, 0x30, 0x31, 0x00, 0x42, 0x20, 0x08, 0xc1, 0x18, 0x38,
        0xff, 0xf1, 0x4c, 0x80, 0x01, 0xbf, 0xfc, 0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c, 0xff, 0xf1,
        0x4c, 0x80, 0x01, 0xbf, 0xfc, 0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c, 0xff, 0xf1, 0x4c, 0x80,
        0x01, 0xbf, 0xfc, 0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c,
    };
    var parameters: [8]u8 = undefined;
    std.mem.writeInt(u32, parameters[0..4], aac_config_adts, .little);
    std.mem.writeInt(u32, parameters[4..8], 3, .little);

    var decoder = try Decoder.create(codec_m4aac, 2 | (0 << 7));
    defer decoder.deinit();
    try std.testing.expectEqual(@as(i32, 0), decoder.initialize(&parameters).result);

    var output: [8 * 1024]u8 = undefined;
    const report = decoder.decode(&adts, &output);
    try std.testing.expectEqual(@as(i32, 0), report.result);
    try std.testing.expect(report.consumed != 0);
    try std.testing.expect(report.produced != 0);
    try std.testing.expectEqual(@as(u32, 2), decoder.codecInfo().channels);
    try std.testing.expectEqual(@as(u32, 48_000), decoder.codecInfo().sample_rate);
}

test "Opus initialize and decode a concealed packet" {
    var parameters: [12]u8 = undefined;
    std.mem.writeInt(u32, parameters[0..4], 2, .little);
    std.mem.writeInt(u32, parameters[4..8], 48_000, .little);
    std.mem.writeInt(u32, parameters[8..12], 0, .little);

    var decoder = try Decoder.create(codec_opus, 2);
    defer decoder.deinit();
    try std.testing.expectEqual(@as(i32, 0), decoder.initialize(&parameters).result);

    const packet = [_]u8{0xfc};
    var output: [960 * 2 * 2]u8 = undefined;
    const report = decoder.decode(&packet, &output);
    try std.testing.expectEqual(@as(i32, 0), report.result);
    try std.testing.expectEqual(@as(usize, packet.len), report.consumed);
    try std.testing.expectEqual(@as(usize, output.len), report.produced);
    try std.testing.expectEqual(@as(u32, 1), report.frames);
    try std.testing.expectEqual(@as(u32, 2), decoder.codecInfo().channels);
    try std.testing.expectEqual(@as(u32, 48_000), decoder.codecInfo().sample_rate);
}
