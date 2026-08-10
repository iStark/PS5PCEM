// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Virtual WAV files from Unity FSB5 banks in `resources.resource`.
//!
//! The title probes `Media/Resources/audio/**.wav` paths missing from sparse
//! dumps. Clip names and resource offsets live in `resources.assets`; the
//! binary banks (PCM16 / Vorbis FSB5) live in `resources.resource`. Index the
//! name→offset map, open the matching FSB, and synthesise RIFF/WAVE on demand.
//! Loaded PCM is also queued for host mix-in so silent AudioOut buffers carry
//! real game samples while the title's mixer is still empty.

const std = @import("std");

/// Set to true to enable verbose per-frame audio debug logging.
const log_verbose_audio = false;

pub const Error = error{
    NotAvailable,
    OutOfMemory,
    IoFailed,
    Unsupported,
};

const maximum_clips = 4096;
const maximum_wav_bytes = 12 * 1024 * 1024;
const maximum_name = 96;
const host_mix_rate = 48_000;
const mix_ring_samples = host_mix_rate * 2 * 8; // ~8 s stereo float at 48 kHz

const ClipEntry = struct {
    name: [maximum_name]u8 = undefined,
    name_len: u8 = 0,
    resource_offset: u64 = 0,
    resource_size: u32 = 0,
};

const VirtualWav = struct {
    bytes: []u8,
    size: u64,
};

const PcmDecoded = struct {
    pcm: []u8,
    channels: u8,
    rate: u32,
};

var clips: [maximum_clips]ClipEntry = undefined;
var clip_count: usize = 0;
var indexed: bool = false;
var index_failed: bool = false;
var virtual_serves: std.atomic.Value(u64) = .init(0);

// ---------------------------------------------------------------------------
// Host mix ring: float32 interleaved stereo, written by virtual open, read by
// AudioOut when the title feeds silence.

var mix_lock: std.atomic.Mutex = .unlocked;
var mix_buf: [mix_ring_samples]f32 = [_]f32{0} ** mix_ring_samples;
var mix_write: usize = 0;
var mix_read: usize = 0;
var mix_count: usize = 0;

/// Host mix stays muted until the first VideoOut flip so SFX are not heard
/// seconds before the first picture (load-time open of 800+ clips used to
/// flood the ring and create a long A/V delay).
var mix_live: std.atomic.Value(bool) = .init(false);
var preseed_done: bool = false;
var mix_queue_opens: std.atomic.Value(u32) = .init(0);

fn mixLock() void {
    while (!mix_lock.tryLock()) std.atomic.spinLoopHint();
}

fn mixUnlock() void {
    mix_lock.unlock();
}

/// Samples currently sitting in the host mix ring (stereo float pairs × 2).
pub fn hostMixPendingSamples() usize {
    mixLock();
    defer mixUnlock();
    return mix_count;
}

fn pushStereoSampleLocked(left: f32, right: f32) void {
    if (mix_count + 2 > mix_ring_samples) return;
    mix_buf[mix_write] = left;
    mix_write = (mix_write + 1) % mix_ring_samples;
    mix_buf[mix_write] = right;
    mix_write = (mix_write + 1) % mix_ring_samples;
    mix_count += 2;
}

/// Call from VideoOut flip completion so host SFX start with the picture.
pub fn noteFirstPresent() void {
    const was = mix_live.swap(true, .monotonic);
    if (!was) {
        if (log_verbose_audio) std.debug.print("[audio_fs] host mix live (first present)\n", .{});
    }
}

pub fn isMixLive() bool {
    return mix_live.load(.monotonic);
}

fn pathLooksAttract(path: []const u8) bool {
    var buf: [512]u8 = undefined;
    if (path.len > buf.len) return false;
    for (path, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const lower = buf[0..path.len];
    return std.mem.indexOf(u8, lower, "attract") != null or
        std.mem.indexOf(u8, lower, "trailer") != null or
        std.mem.indexOf(u8, lower, "title") != null or
        std.mem.indexOf(u8, lower, "menu") != null or
        std.mem.indexOf(u8, lower, "music") != null or
        std.mem.indexOf(u8, lower, "bgm") != null;
}

fn nameLooksAttract(name: []const u8) bool {
    return pathLooksAttract(name);
}

fn pcm16StereoFrame(pcm: []const u8, channels: u8, frame: usize) [2]f32 {
    const ch: usize = channels;
    const frame_bytes = ch * 2;
    const offset = frame * frame_bytes;
    const left_i16 = std.mem.readInt(i16, pcm[offset..][0..2], .little);
    const right_i16 = if (channels == 1)
        left_i16
    else
        std.mem.readInt(i16, pcm[offset + 2 ..][0..2], .little);
    return .{
        @as(f32, @floatFromInt(left_i16)) / 32768.0,
        @as(f32, @floatFromInt(right_i16)) / 32768.0,
    };
}

/// Push mono/stereo PCM16 into the host mix ring (converted and resampled to
/// 48 kHz stereo float). A short edge envelope prevents a non-zero clip start
/// or truncated preview end from becoming an audible click.
///
/// Returns whether at least one frame was queued. Callers use this to avoid
/// counting clips rejected by the real-time backlog limit.
pub fn queuePcm16ForHostMix(pcm: []const u8, channels: u8, rate: u32) bool {
    if (!mix_live.load(.monotonic)) return false;
    if (pcm.len < 2 or channels == 0 or rate < 8_000 or rate > 192_000) return false;
    const ch: usize = channels;
    const frame_bytes = ch * 2;
    const frames_total = pcm.len / frame_bytes;
    if (frames_total == 0) return false;
    // At most ~0.75 s per enqueue — enough for a one-shot, not a full music bed.
    const source_frames = @min(frames_total, (@as(usize, rate) * 3) / 4);
    const output_frames_u64 = (@as(u64, source_frames) * host_mix_rate + rate / 2) / rate;
    const output_frames: usize = @intCast(@max(output_frames_u64, 1));
    const fade_frames = @min(@as(usize, host_mix_rate / 200), output_frames / 2); // 5 ms
    mixLock();
    defer mixUnlock();
    // Drop new material if the ring already holds >250 ms (keeps latency tight).
    if (mix_count > host_mix_rate / 2) return false;
    var queued_frames: usize = 0;
    for (0..output_frames) |output_frame| {
        if (mix_count + 2 > mix_ring_samples) break;
        const source_position = @as(u64, output_frame) * rate;
        const source_index: usize = @intCast(@min(source_position / host_mix_rate, source_frames - 1));
        const next_index = @min(source_index + 1, source_frames - 1);
        const fraction = @as(f32, @floatFromInt(source_position % host_mix_rate)) / host_mix_rate;
        const first = pcm16StereoFrame(pcm, channels, source_index);
        const second = pcm16StereoFrame(pcm, channels, next_index);
        var gain: f32 = 0.55;
        if (fade_frames != 0) {
            const fade_in = @min(@as(f32, 1), @as(f32, @floatFromInt(output_frame)) / @as(f32, @floatFromInt(fade_frames)));
            const remaining = output_frames - 1 - output_frame;
            const fade_out = @min(@as(f32, 1), @as(f32, @floatFromInt(remaining)) / @as(f32, @floatFromInt(fade_frames)));
            gain *= @min(fade_in, fade_out);
        }
        const left = (first[0] + (second[0] - first[0]) * fraction) * gain;
        const right = (first[1] + (second[1] - first[1]) * fraction) * gain;
        pushStereoSampleLocked(left, right);
        queued_frames += 1;
    }
    return queued_frames != 0;
}

/// Mix queued game samples into an AudioOut buffer (float32 interleaved).
/// Returns true if any non-zero sample was written.
pub fn mixIntoFloat32Buffer(out: []u8, channels: u8) bool {
    if (!mix_live.load(.monotonic)) return false;
    if (out.len < 4 or channels == 0) return false;
    const frames = out.len / (@as(usize, channels) * 4);
    mixLock();
    defer mixUnlock();
    if (mix_count < 2) return false;
    var wrote = false;
    var f: usize = 0;
    while (f < frames and mix_count >= 2) : (f += 1) {
        const left = mix_buf[mix_read];
        mix_read = (mix_read + 1) % mix_ring_samples;
        const right = mix_buf[mix_read];
        mix_read = (mix_read + 1) % mix_ring_samples;
        mix_count -= 2;
        if (left != 0 or right != 0) wrote = true;
        if (channels == 1) {
            const mono = (left + right) * 0.5;
            writeF32(out[f * 4 ..][0..4], mono);
        } else {
            writeF32(out[f * channels * 4 ..][0..4], left);
            writeF32(out[f * channels * 4 + 4 ..][0..4], right);
            // Zero extra channels if any.
            var c: u8 = 2;
            while (c < channels) : (c += 1) {
                writeF32(out[f * channels * 4 + @as(usize, c) * 4 ..][0..4], 0);
            }
        }
    }
    return wrote;
}

/// Mix into signed-16 AudioOut buffers.
pub fn mixIntoInt16Buffer(out: []u8, channels: u8) bool {
    if (!mix_live.load(.monotonic)) return false;
    if (out.len < 2 or channels == 0) return false;
    const frames = out.len / (@as(usize, channels) * 2);
    mixLock();
    defer mixUnlock();
    if (mix_count < 2) return false;
    var wrote = false;
    var f: usize = 0;
    while (f < frames and mix_count >= 2) : (f += 1) {
        const left = mix_buf[mix_read];
        mix_read = (mix_read + 1) % mix_ring_samples;
        const right = mix_buf[mix_read];
        mix_read = (mix_read + 1) % mix_ring_samples;
        mix_count -= 2;
        if (left != 0 or right != 0) wrote = true;
        if (channels == 1) {
            const mono: i16 = @intFromFloat(std.math.clamp((left + right) * 0.5, -1.0, 1.0) * 32767.0);
            std.mem.writeInt(i16, out[f * 2 ..][0..2], mono, .little);
        } else {
            const l: i16 = @intFromFloat(std.math.clamp(left, -1.0, 1.0) * 32767.0);
            const r: i16 = @intFromFloat(std.math.clamp(right, -1.0, 1.0) * 32767.0);
            std.mem.writeInt(i16, out[f * channels * 2 ..][0..2], l, .little);
            std.mem.writeInt(i16, out[f * channels * 2 + 2 ..][0..2], r, .little);
        }
    }
    return wrote;
}

fn writeF32(dest: []u8, value: f32) void {
    std.mem.writeInt(u32, dest[0..4], @bitCast(value), .little);
}

// ---------------------------------------------------------------------------

/// True when this path is a candidate for FSB-backed virtual WAV.
pub fn isVirtualAudioPath(relative: []const u8) bool {
    if (relative.len < 5) return false;
    if (!std.ascii.eqlIgnoreCase(relative[relative.len - 4 ..], ".wav")) return false;
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

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn basenameStem(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') start = i + 1;
    }
    const base = path[start..];
    if (base.len > 4 and std.ascii.eqlIgnoreCase(base[base.len - 4 ..], ".wav")) {
        return base[0 .. base.len - 4];
    }
    return base;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn isClipNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

fn looksLikeClipName(s: []const u8) bool {
    if (s.len < 2 or s.len > maximum_name) return false;
    // Reject pure digits / single letter noise.
    var alpha: usize = 0;
    for (s) |c| {
        if (!isClipNameChar(c)) return false;
        if (std.ascii.isAlphabetic(c)) alpha += 1;
    }
    return alpha >= 1;
}

fn addClip(name: []const u8, res_off: u64, res_size: u32) void {
    if (clip_count >= maximum_clips) return;
    if (res_size < 64 or res_off == 0) return;
    if (!looksLikeClipName(name)) return;
    for (clips[0..clip_count]) |c| {
        if (eqlIgnoreCase(c.name[0..c.name_len], name)) return;
    }
    var entry = ClipEntry{};
    entry.name_len = @intCast(name.len);
    @memcpy(entry.name[0..name.len], name);
    entry.resource_offset = res_off;
    entry.resource_size = res_size;
    clips[clip_count] = entry;
    clip_count += 1;
}

/// Parse `resources.assets` for AudioClip name → (offset,size) in resources.resource.
/// Unity stores StreamingResource: length-prefixed "resources.resource", then
/// u64 offset + u64 size. The AudioClip m_Name sits a short distance earlier
/// as another length-prefixed ASCII string.
fn indexFromAssets(root: std.Io.Dir, io: std.Io) void {
    const file = root.openFile(io, "Media/resources.assets", .{}) catch return;
    defer file.close(io);
    const file_len = file.length(io) catch return;
    const needle = "resources.resource";
    const chunk_size: usize = 4 * 1024 * 1024;
    // Keep a lookback window so names near chunk boundaries still resolve.
    const lookback: usize = 256;
    var buf: []u8 = std.heap.page_allocator.alloc(u8, chunk_size + lookback + needle.len) catch return;
    defer std.heap.page_allocator.free(buf);

    var pos: u64 = 0;
    var carry: usize = 0;
    while (pos < file_len and clip_count < maximum_clips) {
        const to_read: usize = @intCast(@min(chunk_size, file_len - pos));
        const n = file.readPositionalAll(io, buf[carry .. carry + to_read], pos) catch break;
        const total = carry + n;
        if (total < needle.len) break;
        var i: usize = if (carry > 0) @max(carry, lookback) - lookback else 0;
        while (i + needle.len <= total and clip_count < maximum_clips) : (i += 1) {
            if (!std.mem.eql(u8, buf[i .. i + needle.len], needle)) continue;
            if (i < 4) continue;
            const name_str_len = readU32(buf, i - 4);
            if (name_str_len != needle.len) continue;
            // After string: pad to 4-byte boundary, then u64 offset + u64 size.
            // Also try a few unaligned offsets if the pad guess is wrong.
            var res_off: u64 = 0;
            var res_size: u32 = 0;
            var found_nums = false;
            const base_after = i + needle.len;
            var pad: usize = 0;
            while (pad < 4) : (pad += 1) {
                const after = base_after + pad;
                if (after + 16 > total) break;
                const off = readU64(buf, after);
                const sz64 = readU64(buf, after + 8);
                if (sz64 < 64 or sz64 > 64 * 1024 * 1024) continue;
                if (off == 0 or off > 8 * 1024 * 1024 * 1024) continue;
                res_off = off;
                res_size = @intCast(sz64);
                found_nums = true;
                break;
            }
            if (!found_nums) continue;

            // Walk backward for the best length-prefixed clip name.
            // Prefer the nearest valid name within a reasonable field gap.
            var best_name: []const u8 = "";
            var best_gap: usize = std.math.maxInt(usize);
            if (i >= 12) {
                var back: usize = 4;
                while (back < 200 and i >= back + 4) : (back += 1) {
                    const name_start = i - back;
                    if (name_start < 4) break;
                    const len = readU32(buf, name_start - 4);
                    if (len < 2 or len > maximum_name) continue;
                    if (name_start + len > i - 4) continue;
                    const candidate = buf[name_start .. name_start + len];
                    if (!looksLikeClipName(candidate)) continue;
                    const gap = (i - 4) - (name_start + len);
                    // Unity AudioClip has several fields between m_Name and
                    // m_Resource (load type, channels, frequency, etc.).
                    if (gap < 4 or gap > 160) continue;
                    if (gap < best_gap) {
                        best_gap = gap;
                        best_name = candidate;
                    }
                }
            }
            if (best_name.len == 0) continue;
            addClip(best_name, res_off, res_size);
        }
        if (pos + n >= file_len) break;
        // Keep lookback tail for next chunk.
        const keep = @min(lookback, total);
        @memcpy(buf[0..keep], buf[total - keep .. total]);
        carry = keep;
        pos += n;
    }
}

/// Build name index from assets (preferred) then supplement with raw FSB scan
/// (name tables + anonymous PCM16/Vorbis banks).
pub fn ensureIndexed(root: std.Io.Dir, io: std.Io) void {
    if (indexed or index_failed) return;
    indexed = true;
    indexFromAssets(root, io);
    const named_from_assets = clip_count;
    std.debug.print(
        "[audio_fs] indexed {d} named clips from resources.assets\n",
        .{named_from_assets},
    );
    // Always merge raw FSB banks so PCM16/name-table entries not reachable via
    // the assets walk still map.
    indexRawFsb(root, io);
    if (clip_count == 0) {
        index_failed = true;
        return;
    }
    // Preseed is deferred until the first present (see noteFirstPresent +
    // maybePreseedAfterPresent) so audio does not lead the picture by seconds.
}

/// After the first flip, load a few attract/title PCM16 clips into the mix ring.
pub fn maybePreseedAfterPresent(root: std.Io.Dir, io: std.Io) void {
    if (preseed_done or !mix_live.load(.monotonic)) return;
    if (!indexed or clip_count == 0) ensureIndexed(root, io);
    if (clip_count == 0) return;
    preseed_done = true;

    const resource = root.openFile(io, "Media/resources.resource", .{}) catch return;
    defer resource.close(io);

    // Prefer clips whose names look like attract/title audio.
    var queued: u32 = 0;
    var pass: u8 = 0;
    while (pass < 2 and queued == 0) : (pass += 1) {
        var i: usize = 0;
        while (i < clip_count and queued == 0) : (i += 1) {
            const clip = clips[i];
            const nm = clip.name[0..clip.name_len];
            if (pass == 0 and !nameLooksAttract(nm)) continue;
            const decoded = parseFsbPcm16(
                resource,
                io,
                clip.resource_offset,
                clip.resource_size,
                std.heap.page_allocator,
            ) catch continue;
            defer std.heap.page_allocator.free(decoded.pcm);
            // ~0.6 s each so the ring stays near real-time.
            const max_bytes = @min(
                decoded.pcm.len,
                @as(usize, decoded.channels) * 2 * @divTrunc(decoded.rate * 3, 5),
            );
            if (queuePcm16ForHostMix(decoded.pcm[0..max_bytes], decoded.channels, decoded.rate)) {
                queued += 1;
                if (log_verbose_audio) std.debug.print(
                    "[audio_fs] preseed mix \"{s}\" {d} bytes ch={d} rate={d}\n",
                    .{ nm, max_bytes, decoded.channels, decoded.rate },
                );
            }
        }
    }
    if (queued > 0) {
        if (log_verbose_audio) std.debug.print("[audio_fs] host mix preseeded with {d} clips after first present\n", .{queued});
    }
}

fn indexRawFsb(root: std.Io.Dir, io: std.Io) void {
    const file = root.openFile(io, "Media/resources.resource", .{}) catch return;
    defer file.close(io);
    const file_len = file.length(io) catch return;
    // Chunked scan for "FSB5" — byte-stepping a ~500 MB resource is too slow.
    const chunk_size: usize = 4 * 1024 * 1024;
    const needle = "FSB5";
    var buf: []u8 = std.heap.page_allocator.alloc(u8, chunk_size + needle.len) catch return;
    defer std.heap.page_allocator.free(buf);

    var pos: u64 = 0;
    var anon: u32 = 0;
    var pcm_n: u32 = 0;
    var vorbis_n: u32 = 0;
    var header: [64]u8 = undefined;
    while (pos < file_len and clip_count < maximum_clips) {
        const to_read: usize = @intCast(@min(chunk_size, file_len - pos));
        const n = file.readPositionalAll(io, buf[0..to_read], pos) catch break;
        if (n < needle.len) break;
        var i: usize = 0;
        while (i + needle.len <= n and clip_count < maximum_clips) {
            if (!std.mem.eql(u8, buf[i .. i + needle.len], needle)) {
                i += 1;
                continue;
            }
            const offset = pos + i;
            const hn = file.readPositionalAll(io, &header, offset) catch break;
            if (hn < 60) break;
            const sample_hdr_size = readU32(&header, 12);
            const name_table_size = readU32(&header, 16);
            const data_size = readU32(&header, 20);
            const mode = readU32(&header, 24);
            const bank_end = offset + 60 + sample_hdr_size + name_table_size + data_size;
            if (data_size == 0 or bank_end > file_len or sample_hdr_size > 1024 * 1024) {
                i += 4;
                continue;
            }
            if ((mode == fsb_mode_pcm16 or mode == fsb_mode_vorbis) and data_size >= 64) {
                var entry = ClipEntry{};
                var named = false;
                if (name_table_size >= 4 and name_table_size < 4096) {
                    var name_buf: [256]u8 = undefined;
                    const nt_off = offset + 60 + sample_hdr_size;
                    const nt_read = @min(name_table_size, name_buf.len);
                    if (file.readPositionalAll(io, name_buf[0..nt_read], nt_off) catch 0 == nt_read) {
                        var s_off: usize = 4;
                        if (nt_read >= 4) {
                            const first = readU32(name_buf[0..], 0);
                            if (first < nt_read) s_off = first;
                        }
                        if (s_off < nt_read) {
                            const rest = name_buf[s_off..nt_read];
                            const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
                            const nm = rest[0..end];
                            if (looksLikeClipName(nm) and nm.len <= maximum_name) {
                                entry.name_len = @intCast(nm.len);
                                @memcpy(entry.name[0..nm.len], nm);
                                named = true;
                            }
                        }
                    }
                }
                if (!named) {
                    const label = std.fmt.bufPrint(&entry.name, "fsb_{d}", .{anon}) catch "fsb";
                    entry.name_len = @intCast(label.len);
                }
                entry.resource_offset = offset;
                entry.resource_size = @intCast(bank_end - offset);
                if (named) {
                    addClip(entry.name[0..entry.name_len], entry.resource_offset, entry.resource_size);
                } else if (clip_count < maximum_clips) {
                    clips[clip_count] = entry;
                    clip_count += 1;
                }
                anon += 1;
                if (mode == fsb_mode_pcm16) pcm_n += 1 else vorbis_n += 1;
            }
            // Skip past this bank inside the chunk when possible.
            if (bank_end > pos + i) {
                const skip = bank_end - (pos + i);
                if (skip < n - i) {
                    i += @intCast(skip);
                    continue;
                }
            }
            i += 4;
        }
        if (pos + n >= file_len) break;
        pos = pos + n - needle.len + 1;
    }
    std.debug.print(
        "[audio_fs] raw FSB scan total_clips={d} (pcm16_banks={d} vorbis_banks={d})\n",
        .{ clip_count, pcm_n, vorbis_n },
    );
}

fn findClip(stem: []const u8) ?ClipEntry {
    for (clips[0..clip_count]) |c| {
        if (eqlIgnoreCase(c.name[0..c.name_len], stem)) return c;
    }
    // Soft: suffix match (path ends with clip name).
    for (clips[0..clip_count]) |c| {
        const cn = c.name[0..c.name_len];
        if (stem.len >= cn.len and eqlIgnoreCase(stem[stem.len - cn.len ..], cn)) return c;
    }
    return null;
}

// FSB5 modes: 0=none, 1=PCM8, 2=PCM16, 3=PCM24, 4=PCM32, 5=PCMFLOAT, 6=GCADPCM,
// 7=IMAADPCM, 8=VAG, 9=HEVAG, 10=XMA, 11=MPEG, 12=CELT, 13=AT9, 14=XWMA, 15=Vorbis
const fsb_mode_pcm16: u32 = 2;
const fsb_mode_vorbis: u32 = 15;

fn parseFsbHeader(header: *const [64]u8) struct {
    sample_count: u32,
    sample_hdr_size: u32,
    name_table_size: u32,
    data_size: u32,
    mode: u32,
} {
    return .{
        .sample_count = readU32(header, 8),
        .sample_hdr_size = readU32(header, 12),
        .name_table_size = readU32(header, 16),
        .data_size = readU32(header, 20),
        .mode = readU32(header, 24),
    };
}

/// FSB5 stores the sample rate as a four-bit index in each sample header, not
/// in the bank flags at byte 28. The latter is commonly zero and previously
/// made every clip fall back to 48 kHz (including this title's 44.1 kHz PCM).
fn fsbFrequency(index: u4) ?u32 {
    return switch (index) {
        0 => 4_000,
        1 => 8_000,
        2 => 11_000,
        3 => 11_025,
        4 => 16_000,
        5 => 22_050,
        6 => 24_000,
        7 => 32_000,
        8 => 44_100,
        9 => 48_000,
        10 => 96_000,
        else => null,
    };
}

const FsbPcmSample = struct {
    rate: u32,
    channels: u8,
    data_offset: u64,
    frames: u64,
};

fn parseFsbPcmSample(sample_header: u64) ?FsbPcmSample {
    const frequency_index: u4 = @truncate(sample_header >> 1);
    return .{
        .rate = fsbFrequency(frequency_index) orelse return null,
        .channels = @intCast(((sample_header >> 5) & 1) + 1),
        .data_offset = ((sample_header >> 6) & 0x0fff_ffff) * 16,
        .frames = (sample_header >> 34) & 0x3fff_ffff,
    };
}

fn parseFsbPcm16(
    resource: std.Io.File,
    io: std.Io,
    bank_offset: u64,
    bank_size: u32,
    allocator: std.mem.Allocator,
) Error!PcmDecoded {
    var header: [68]u8 = undefined;
    const n = resource.readPositionalAll(io, &header, bank_offset) catch return Error.IoFailed;
    if (n < 60 or !std.mem.eql(u8, header[0..4], "FSB5")) return Error.Unsupported;
    const fixed_header: *const [64]u8 = @ptrCast(&header);
    const h = parseFsbHeader(fixed_header);
    if (h.mode != fsb_mode_pcm16) return Error.Unsupported;
    if (h.data_size < 64 or h.data_size > maximum_wav_bytes) return Error.Unsupported;
    // The fallback decoder currently exposes one WAV per one-sample FSB bank.
    // Multi-sample banks need their individual metadata chunks walked first.
    if (h.sample_count != 1 or h.sample_hdr_size < 8 or n < 68) return Error.Unsupported;
    const sample = parseFsbPcmSample(readU64(&header, 60)) orelse return Error.Unsupported;
    const decoded_bytes = std.math.mul(u64, sample.frames, @as(u64, sample.channels) * 2) catch return Error.Unsupported;
    if (sample.data_offset >= h.data_size) return Error.Unsupported;
    const available = @as(u64, h.data_size) - sample.data_offset;
    const pcm_size_u64 = @min(decoded_bytes, available);
    if (pcm_size_u64 < @as(u64, sample.channels) * 2 or pcm_size_u64 > maximum_wav_bytes) return Error.Unsupported;
    const fixed_data_off = bank_offset + 60 + h.sample_hdr_size + h.name_table_size;
    const data_off = fixed_data_off + sample.data_offset;
    if (bank_size != 0 and data_off + pcm_size_u64 > bank_offset + bank_size) return Error.Unsupported;
    const pcm_size: usize = @intCast(pcm_size_u64);
    const pcm = allocator.alloc(u8, pcm_size) catch return Error.OutOfMemory;
    errdefer allocator.free(pcm);
    const got = resource.readPositionalAll(io, pcm, data_off) catch {
        allocator.free(pcm);
        return Error.IoFailed;
    };
    if (got != pcm_size) {
        allocator.free(pcm);
        return Error.IoFailed;
    }
    return .{ .pcm = pcm, .channels = sample.channels, .rate = sample.rate };
}

/// FSB5 mode 15 (Vorbis) uses FMOD's private packet layout + setup CRC
/// codebooks — not a plain Ogg bitstream. Without those tables we cannot
/// recover PCM; reject so the caller falls back to a PCM16 bank.
fn parseFsbVorbis(
    resource: std.Io.File,
    io: std.Io,
    bank_offset: u64,
    bank_size: u32,
    allocator: std.mem.Allocator,
) Error!PcmDecoded {
    _ = resource;
    _ = io;
    _ = bank_offset;
    _ = bank_size;
    _ = allocator;
    return Error.Unsupported;
}

fn decodeFsbClip(
    resource: std.Io.File,
    io: std.Io,
    bank_offset: u64,
    bank_size: u32,
    allocator: std.mem.Allocator,
) Error!PcmDecoded {
    var header: [64]u8 = undefined;
    const n = resource.readPositionalAll(io, &header, bank_offset) catch return Error.IoFailed;
    if (n < 60 or !std.mem.eql(u8, header[0..4], "FSB5")) return Error.Unsupported;
    const mode = readU32(&header, 24);
    if (mode == fsb_mode_pcm16) {
        return parseFsbPcm16(resource, io, bank_offset, bank_size, allocator);
    }
    if (mode == fsb_mode_vorbis) {
        return parseFsbVorbis(resource, io, bank_offset, bank_size, allocator);
    }
    return Error.Unsupported;
}

fn buildWavFromPcm(pcm: []const u8, channels: u8, rate: u32, allocator: std.mem.Allocator) Error![]u8 {
    const total = 44 + pcm.len;
    const out = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    const ch: u16 = channels;
    const block_align: u16 = ch * 2;
    const byte_rate: u32 = rate * block_align;
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(total - 8), .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], ch, .little);
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], byte_rate, .little);
    std.mem.writeInt(u16, out[32..34], block_align, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], @intCast(pcm.len), .little);
    @memcpy(out[44..], pcm);
    return out;
}

/// Resolve a missing audio path to synthesised WAV bytes (caller frees).
pub fn resolveVirtualWav(
    relative_path: []const u8,
    root: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
) Error!VirtualWav {
    if (!isVirtualAudioPath(relative_path)) return Error.NotAvailable;
    ensureIndexed(root, io);
    if (clip_count == 0) return Error.NotAvailable;

    const stem = basenameStem(relative_path);
    const clip = findClip(stem) orelse {
        // Hash fallback among all clips so every path still maps somewhere.
        const h = std.hash.Wyhash.hash(0xA11D10, relative_path);
        const c = clips[h % clip_count];
        return buildFromClip(c, relative_path, root, io, allocator, true);
    };
    return buildFromClip(clip, relative_path, root, io, allocator, false);
}

fn buildSilentWav(allocator: std.mem.Allocator, frames: u32, channels: u8, rate: u32) Error![]u8 {
    const pcm_len = @as(usize, frames) * @as(usize, channels) * 2;
    const pcm = allocator.alloc(u8, pcm_len) catch return Error.OutOfMemory;
    defer allocator.free(pcm);
    @memset(pcm, 0);
    return buildWavFromPcm(pcm, channels, rate, allocator);
}

fn buildFromClip(
    clip: ClipEntry,
    relative_path: []const u8,
    root: std.Io.Dir,
    io: std.Io,
    allocator: std.mem.Allocator,
    hashed: bool,
) Error!VirtualWav {
    const n = virtual_serves.fetchAdd(1, .monotonic);
    // Bulk preload: after the first few opens, only fully decode attract/title
    // (and first hits). Other paths get a tiny silent WAV so File.Exists/open
    // succeed without decoding hundreds of multi-MB FSB banks on the load
    // thread (that was delaying first present by many seconds).
    const want_full = pathLooksAttract(relative_path) or (!hashed and n < 24);
    if (!want_full) {
        const wav = try buildSilentWav(allocator, 256, 2, 48_000);
        if (n < 40 or n % 200 == 0) {
            if (log_verbose_audio) std.debug.print(
                "[audio_fs] virtual wav #{d} \"{s}\" -> silent stub (fast open)\n",
                .{ n + 1, relative_path },
            );
        }
        return .{ .bytes = wav, .size = wav.len };
    }

    const resource = root.openFile(io, "Media/resources.resource", .{}) catch return Error.IoFailed;
    defer resource.close(io);

    var used = clip;
    const decoded = decodeFsbClip(resource, io, used.resource_offset, used.resource_size, allocator) catch blk: {
        // Vorbis / bad header: fall back to any PCM16 bank so the path still
        // resolves and host mix keeps receiving real samples.
        var j: usize = 0;
        while (j < clip_count) : (j += 1) {
            const alt = clips[j];
            if (alt.resource_offset == clip.resource_offset) continue;
            if (parseFsbPcm16(resource, io, alt.resource_offset, alt.resource_size, allocator)) |d| {
                used = alt;
                break :blk d;
            } else |_| continue;
        }
        return Error.Unsupported;
    };
    defer allocator.free(decoded.pcm);

    // Only feed the host mix for named attract/title opens after first present.
    if (mix_live.load(.monotonic) and !hashed and pathLooksAttract(relative_path)) {
        const nq = mix_queue_opens.fetchAdd(1, .monotonic);
        if (nq < 12) {
            _ = queuePcm16ForHostMix(decoded.pcm, decoded.channels, decoded.rate);
        }
    }

    const wav = try buildWavFromPcm(decoded.pcm, decoded.channels, decoded.rate, allocator);
    if (n < 16 or n % 100 == 0) {
        if (log_verbose_audio) std.debug.print(
            "[audio_fs] virtual wav #{d} \"{s}\" -> {s}{s} @0x{x} ({d} bytes)\n",
            .{
                n + 1,
                relative_path,
                used.name[0..used.name_len],
                if (hashed) " (hash)" else "",
                used.resource_offset,
                wav.len,
            },
        );
    }
    return .{ .bytes = wav, .size = wav.len };
}

pub fn virtualWavSize(relative_path: []const u8, root: std.Io.Dir, io: std.Io) ?u64 {
    if (!isVirtualAudioPath(relative_path)) return null;
    ensureIndexed(root, io);
    if (clip_count == 0) return null;
    const stem = basenameStem(relative_path);
    const clip = findClip(stem) orelse clips[std.hash.Wyhash.hash(0xA11D10, relative_path) % clip_count];
    // Approximate: FSB header ~100 + PCM ≈ resource_size, WAV = PCM+44.
    if (clip.resource_size > 200) return clip.resource_size; // good enough for File.Exists
    return 44 + 4096;
}

pub fn reset() void {
    clip_count = 0;
    indexed = false;
    index_failed = false;
    virtual_serves.store(0, .monotonic);
    mixLock();
    mix_write = 0;
    mix_read = 0;
    mix_count = 0;
    mixUnlock();
    mix_live.store(false, .monotonic);
    preseed_done = false;
    mix_queue_opens.store(0, .monotonic);
}

test "host fallback resamples 44.1 kHz PCM and never replays drained audio" {
    reset();
    defer reset();
    noteFirstPresent();

    // Ten milliseconds of non-zero stereo PCM at 44.1 kHz becomes exactly
    // 480 frames / 960 interleaved samples in the 48 kHz host ring.
    var pcm: [441 * 2]i16 = @splat(12_000);
    try std.testing.expect(queuePcm16ForHostMix(std.mem.sliceAsBytes(&pcm), 2, 44_100));
    try std.testing.expectEqual(@as(usize, 480 * 2), hostMixPendingSamples());

    var output: [480 * 2 * 4]u8 = @splat(0);
    try std.testing.expect(mixIntoFloat32Buffer(&output, 2));
    try std.testing.expectEqual(@as(usize, 0), hostMixPendingSamples());

    // The old loopback refilled the ring here and replayed the same fragment
    // forever, producing both the perceived echo and a click at every seam.
    @memset(&output, 0);
    try std.testing.expect(!mixIntoFloat32Buffer(&output, 2));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** output.len), &output);
}

test "FSB5 PCM sample word carries rate channels and decoded length" {
    // Captured from this title's attract_reload bank.
    const sample = parseFsbPcmSample(0x0002_4090_0000_0030).?;
    try std.testing.expectEqual(@as(u32, 44_100), sample.rate);
    try std.testing.expectEqual(@as(u8, 2), sample.channels);
    try std.testing.expectEqual(@as(u64, 0), sample.data_offset);
    try std.testing.expectEqual(@as(u64, 36_900), sample.frames);
}

test "host fallback envelope reaches silence at both clip boundaries" {
    reset();
    defer reset();
    noteFirstPresent();

    var pcm: [600 * 2]i16 = @splat(20_000);
    try std.testing.expect(queuePcm16ForHostMix(std.mem.sliceAsBytes(&pcm), 2, 48_000));
    var output: [600 * 2 * 4]u8 = undefined;
    try std.testing.expect(mixIntoFloat32Buffer(&output, 2));
    try std.testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(readU32(&output, 0))));
    try std.testing.expectEqual(@as(f32, 0), @as(f32, @bitCast(readU32(&output, output.len - 4))));
}
