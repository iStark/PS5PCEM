// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! CPU execution of ACM partitioned convolution batches. The descriptor layout
//! is observed in FMOD's ACM backend: interleaved complex IR partitions of B
//! bins for a 2B transform, separate planar input/output and overlap buffers.
//! Only the observed zero-offset, float32/float16 spectrum layouts are accepted.
const std = @import("std");
pub const Error = error{ InvalidParameter, Unsupported, OutOfMemory };
pub const Check = *const fn (usize, usize) bool;
const allocator = std.heap.page_allocator;
const max_channels = 8;
const max_outputs = 32;
const max_block = 1024;
const magic: u64 = 0x314d43414d454350; // PCEMACM1, internal HLE command encoding

pub const BatchInfo = extern struct {
    buffer: ?[*]u8 = null,
    offset: usize = 0,
    size: usize = 0,
};
pub const Spectrum = extern struct { data: usize, offset: usize = 0 };
pub const Ir = extern struct {
    block_size: u32,
    partitions: u32,
    channels: u32,
    format: u32,
    reserved: u64 = 0,
    spectra: usize,
};
pub const Input = extern struct {
    block_size: u32,
    partitions: u32,
    channels: u32,
    format: u32,
    reserved: u64 = 0,
    spectra: usize,
    samples: usize,
};
pub const Output = extern struct {
    block_size: u32,
    channels: u32,
    overlap: usize,
    samples: usize,
};
const Header = extern struct { tag: u64 = magic, bytes: u32, count: u32, blocks: u32, shared_ir: u32, shared: usize };
const Pair = extern struct { other: usize, output: usize, gain: f32, padding: u32 = 0 };

fn checked(comptime T: type, address: usize, count: usize, check: Check) Error![]align(1) T {
    const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return error.InvalidParameter;
    if (address == 0 or !check(address, bytes)) return error.InvalidParameter;
    return @as([*]align(1) T, @ptrFromInt(address))[0..count];
}

// Stack arrays supplied to command builders need not survive until submission.
// Capture their pointer values and gains now, but read PCM only at batch start.
pub fn append(info_address: usize, blocks: u32, shared: usize, count: u32, others: usize, gains: usize, outputs: usize, shared_ir: bool, check: Check) Error!void {
    if (count == 0 or count > max_outputs or blocks == 0 or blocks > 64 or shared == 0) return error.InvalidParameter;
    const info = &(try checked(BatchInfo, info_address, 1, check))[0];
    const other = try checked(usize, others, count, check);
    const gain = try checked(f32, gains, count, check);
    const output = try checked(usize, outputs, count, check);
    const bytes = @sizeOf(Header) + @as(usize, count) * @sizeOf(Pair);
    if (info.buffer == null or info.offset > info.size or bytes > info.size - info.offset) return error.InvalidParameter;
    const buffer = try checked(u8, @intFromPtr(info.buffer.?), info.size, check);
    for (0..count) |i| if (other[i] == 0 or output[i] == 0 or !std.math.isFinite(gain[i])) return error.InvalidParameter;
    const header: Header = .{ .bytes = @intCast(bytes), .count = count, .blocks = blocks, .shared_ir = @intFromBool(shared_ir), .shared = shared };
    @memcpy(buffer[info.offset..][0..@sizeOf(Header)], std.mem.asBytes(&header));
    for (0..count) |i| {
        const pair: Pair = .{ .other = other[i], .output = output[i], .gain = gain[i] };
        @memcpy(buffer[info.offset + @sizeOf(Header) + i * @sizeOf(Pair) ..][0..@sizeOf(Pair)], std.mem.asBytes(&pair));
    }
    info.offset += bytes;
}

pub fn notification(info_address: usize, check: Check) Error!void {
    const info = &(try checked(BatchInfo, info_address, 1, check))[0];
    if (info.buffer == null or info.offset > info.size or @sizeOf(Header) > info.size - info.offset) return error.InvalidParameter;
    const buffer = try checked(u8, @intFromPtr(info.buffer.?), info.size, check);
    const header: Header = .{ .bytes = @sizeOf(Header), .count = 0, .blocks = 0, .shared_ir = 0, .shared = 0 };
    @memcpy(buffer[info.offset..][0..@sizeOf(Header)], std.mem.asBytes(&header));
    info.offset += @sizeOf(Header);
}

const State = struct {
    address: usize,
    input: Input,
    history: []f32,
    cursor: usize = 0,
    filled: usize = 0,
    fn matches(self: State, address: usize, input: Input) bool {
        return self.address == address and std.meta.eql(self.input, input);
    }
};

pub const Runtime = struct {
    states: std.ArrayList(State) = .empty,
    pub fn deinit(self: *Runtime) void {
        for (self.states.items) |state| allocator.free(state.history);
        self.states.deinit(allocator);
        self.* = .{};
    }
    fn stateFor(self: *Runtime, address: usize, input: Input) Error!*State {
        for (self.states.items) |*state| {
            if (state.matches(address, input)) return state;
            if (state.address == address) {
                allocator.free(state.history);
                state.* = .{ .address = 0, .input = input, .history = &.{} };
            }
        }
        const length = @as(usize, input.block_size) * input.partitions * input.channels * 2;
        var used: usize = 0;
        var vacant = false;
        for (self.states.items) |state| {
            used += state.history.len;
            vacant = vacant or state.address == 0;
        }
        if (length > 32 * 1024 * 1024 or used + length > 64 * 1024 * 1024 or (!vacant and self.states.items.len >= 128)) return error.OutOfMemory;
        const history = try allocator.alloc(f32, length);
        errdefer allocator.free(history);
        @memset(history, 0);
        for (self.states.items) |*state| if (state.address == 0) {
            state.* = .{ .address = address, .input = input, .history = history };
            return state;
        };
        try self.states.append(allocator, .{ .address = address, .input = input, .history = history });
        return &self.states.items[self.states.items.len - 1];
    }

    pub fn execute(self: *Runtime, commands: usize, bytes: usize, check: Check) Error!void {
        if (bytes == 0) return;
        if (bytes > 16 * 1024 * 1024) return error.InvalidParameter;
        const data = try checked(u8, commands, bytes, check);
        // Validate all record boundaries before doing work. Native ACM command
        // streams are not decoded by this HLE encoding and must not report success.
        var offset: usize = 0;
        while (offset < data.len) {
            const header = try readHeader(data[offset..]);
            offset += header.bytes;
        }
        offset = 0;
        while (offset < data.len) {
            const header = try readHeader(data[offset..]);
            const pairs: [*]align(1) const Pair = @ptrCast(data[offset + @sizeOf(Header) ..].ptr);
            if (header.count != 0) try self.run(header, pairs[0..header.count], check);
            offset += header.bytes;
        }
    }

    fn run(self: *Runtime, header: Header, pairs: []align(1) const Pair, check: Check) Error!void {
        var inputs: [max_outputs]Input = undefined;
        var irs: [max_outputs]Ir = undefined;
        var outputs: [max_outputs]Output = undefined;
        // Validate every destination before advancing any convolution history.
        for (pairs, 0..) |pair, i| {
            if (!std.math.isFinite(pair.gain)) return error.InvalidParameter;
            inputs[i] = (try checked(Input, if (header.shared_ir != 0) pair.other else header.shared, 1, check))[0];
            irs[i] = (try checked(Ir, if (header.shared_ir != 0) header.shared else pair.other, 1, check))[0];
            outputs[i] = (try checked(Output, pair.output, 1, check))[0];
            try validate(inputs[i], irs[i], outputs[i], header.blocks, check);
        }
        for (0..header.blocks) |block| {
            if (header.shared_ir == 0) {
                const state = try self.stateFor(header.shared, inputs[0]);
                try capture(state, block, check);
                for (pairs, 0..) |pair, i| try convolve(state, irs[i], outputs[i], pair.gain, block, check);
                advance(state);
            } else {
                for (pairs, 0..) |pair, i| {
                    var duplicate = false;
                    for (pairs[0..i]) |previous| duplicate = duplicate or previous.other == pair.other;
                    if (duplicate) continue;
                    const state = try self.stateFor(pair.other, inputs[i]);
                    try capture(state, block, check);
                    for (pairs, 0..) |destination, j| {
                        if (destination.other == pair.other) try convolve(state, irs[j], outputs[j], destination.gain, block, check);
                    }
                    advance(state);
                }
            }
        }
    }
};

fn readHeader(data: []const u8) Error!Header {
    if (data.len < @sizeOf(Header)) return error.InvalidParameter;
    const header = std.mem.bytesToValue(Header, data[0..@sizeOf(Header)]);
    if (header.tag != magic) return error.Unsupported;
    if (header.count > max_outputs or header.bytes != @sizeOf(Header) + header.count * @sizeOf(Pair) or header.bytes > data.len or header.blocks > 64 or header.shared_ir > 1) return error.InvalidParameter;
    if (header.count != 0 and header.blocks == 0) return error.InvalidParameter;
    return header;
}

fn validate(input: Input, ir: Ir, output: Output, blocks: usize, check: Check) Error!void {
    const b = input.block_size;
    if (b < 16 or b > max_block or !std.math.isPowerOfTwo(b) or ir.block_size != b or output.block_size != b or
        input.channels == 0 or input.channels > max_channels or ir.channels == 0 or ir.channels > max_channels or output.channels == 0 or output.channels > max_channels or
        input.partitions == 0 or input.partitions > 16384 or ir.partitions == 0 or ir.partitions > input.partitions) return error.InvalidParameter;
    if (input.format > 1 or ir.format > 1 or input.reserved != 0 or ir.reserved != 0 or
        (input.channels != 1 and input.channels != output.channels) or (ir.channels != 1 and ir.channels != output.channels)) return error.Unsupported;
    const pcm = try checked(usize, input.samples, input.channels, check);
    const out = try checked(usize, output.samples, output.channels, check);
    const overlap = try checked(usize, output.overlap, output.channels, check);
    const spectra = try checked(usize, ir.spectra, ir.channels, check);
    for (pcm) |p| _ = try checked(f32, p, @as(usize, b) * blocks, check);
    for (out) |p| _ = try checked(f32, p, @as(usize, b) * blocks, check);
    for (overlap) |p| _ = try checked(f32, p, b, check);
    for (spectra) |p| {
        const span = (try checked(Spectrum, p, 1, check))[0];
        if (span.offset != 0) return error.Unsupported;
        _ = try checked(u8, span.data, @as(usize, b) * ir.partitions * (if (ir.format == 0) @as(usize, 8) else 4), check);
    }
}

fn capture(state: *State, block: usize, check: Check) Error!void {
    const b: usize = state.input.block_size;
    const pcm = try checked(usize, state.input.samples, state.input.channels, check);
    var real: [max_block * 2]f32 = undefined;
    var imag: [max_block * 2]f32 = undefined;
    for (pcm, 0..) |address, channel| {
        const samples = try checked(f32, address + block * b * 4, b, check);
        @memcpy(real[0..b], samples);
        @memset(real[b .. 2 * b], 0);
        @memset(imag[0 .. 2 * b], 0);
        fft(real[0 .. 2 * b], imag[0 .. 2 * b], false);
        const start = (channel * state.input.partitions + state.cursor) * b * 2;
        @memcpy(state.history[start..][0..b], real[0..b]);
        @memcpy(state.history[start + b ..][0..b], imag[0..b]);
    }
    state.filled = @min(state.filled + 1, state.input.partitions);
}

fn advance(state: *State) void {
    state.cursor = (state.cursor + 1) % state.input.partitions;
}

fn convolve(state: *const State, ir: Ir, output: Output, gain: f32, block: usize, check: Check) Error!void {
    const b: usize = state.input.block_size;
    const ir_channels = try checked(usize, ir.spectra, ir.channels, check);
    const out_channels = try checked(usize, output.samples, output.channels, check);
    const tails = try checked(usize, output.overlap, output.channels, check);
    var real: [max_block * 2]f32 = undefined;
    var imag: [max_block * 2]f32 = undefined;
    for (out_channels, 0..) |address, channel| {
        @memset(real[0 .. 2 * b], 0);
        @memset(imag[0 .. 2 * b], 0);
        const input_channel = if (state.input.channels == 1) 0 else channel;
        const ir_channel = if (ir.channels == 1) 0 else channel;
        const span = (try checked(Spectrum, ir_channels[ir_channel], 1, check))[0];
        for (0..@min(state.filled, ir.partitions)) |part| {
            const ring = (state.cursor + state.input.partitions - part) % state.input.partitions;
            const start = (input_channel * state.input.partitions + ring) * b * 2;
            const xr = state.history[start..][0..b];
            const xi = state.history[start + b ..][0..b];
            if (ir.format == 0) {
                const h: [*]align(1) const f32 = @ptrFromInt(span.data + part * b * 8);
                accumulate(real[0..b], imag[0..b], xr, xi, h);
            } else {
                const h: [*]align(1) const f16 = @ptrFromInt(span.data + part * b * 4);
                accumulate(real[0..b], imag[0..b], xr, xi, h);
            }
        }
        // The observed ACM IR format omits the Nyquist bin; DC is real.
        imag[0] = 0;
        for (1..b) |k| {
            real[2 * b - k] = real[k];
            imag[2 * b - k] = -imag[k];
        }
        fft(real[0 .. 2 * b], imag[0 .. 2 * b], true);
        const samples = try checked(f32, address + block * b * 4, b, check);
        const tail = try checked(f32, tails[channel], b, check);
        for (0..b) |i| {
            samples[i] = (real[i] + tail[i]) * gain;
            tail[i] = real[b + i];
        }
    }
}

fn accumulate(real: []f32, imag: []f32, xr: []const f32, xi: []const f32, h: anytype) void {
    for (0..real.len) |k| {
        const hr: f32 = @floatCast(h[2 * k]);
        const hi: f32 = @floatCast(h[2 * k + 1]);
        real[k] += xr[k] * hr - xi[k] * hi;
        imag[k] += xr[k] * hi + xi[k] * hr;
    }
}

// Radix-2 transform; normalized inverse. No allocations or trigonometric calls
// in the butterfly loop. Block sizes are validated by the batch decoder.
fn fft(real: []f32, imag: []f32, inverse: bool) void {
    var j: usize = 0;
    for (1..real.len) |i| {
        var bit = real.len >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std.mem.swap(f32, &real[i], &real[j]);
            std.mem.swap(f32, &imag[i], &imag[j]);
        }
    }
    var size: usize = 2;
    while (size <= real.len) : (size *= 2) {
        const angle = (if (inverse) @as(f64, 2) else -2) * std.math.pi / @as(f64, @floatFromInt(size));
        const wr = @cos(angle);
        const wi = @sin(angle);
        var offset: usize = 0;
        while (offset < real.len) : (offset += size) {
            var ur: f64 = 1;
            var ui: f64 = 0;
            for (0..size / 2) |k| {
                const a = offset + k;
                const b = a + size / 2;
                const tr: f32 = @floatCast(ur * real[b] - ui * imag[b]);
                const ti: f32 = @floatCast(ur * imag[b] + ui * real[b]);
                real[b] = real[a] - tr;
                imag[b] = imag[a] - ti;
                real[a] += tr;
                imag[a] += ti;
                const next = ur * wr - ui * wi;
                ui = ur * wi + ui * wr;
                ur = next;
            }
        }
    }
    if (inverse) {
        const scale = 1 / @as(f32, @floatFromInt(real.len));
        for (real, imag) |*r, *i| {
            r.* *= scale;
            i.* *= scale;
        }
    }
}

fn testCheck(address: usize, size: usize) bool {
    return address != 0 and size < 1024 * 1024;
}

test "ACM convolution matches direct FIR across partition boundaries and ring wrap" {
    // Independent direct DFT builds the guest IR. Each [a,a] tap pair has zero
    // Nyquist energy, as required by the observed packed spectrum format.
    const b = 16;
    const parts = 3;
    var taps: [b * parts]f32 = @splat(0);
    taps[0] = 1;
    taps[1] = 1;
    taps[b - 2] = -0.25;
    taps[b - 1] = -0.25;
    taps[b + 4] = 0.5;
    taps[b + 5] = 0.5;
    taps[2 * b + 10] = 0.125;
    taps[2 * b + 11] = 0.125;
    var spectrum: [parts * b * 2]f32 = undefined;
    for (0..parts) |p| for (0..b) |k| {
        var re: f64 = 0;
        var im: f64 = 0;
        for (0..b) |n| {
            const angle = -2 * std.math.pi * @as(f64, @floatFromInt(k * n)) / (b * 2);
            re += taps[p * b + n] * @cos(angle);
            im += taps[p * b + n] * @sin(angle);
        }
        spectrum[(p * b + k) * 2] = @floatCast(re);
        spectrum[(p * b + k) * 2 + 1] = @floatCast(im);
    };
    var span: Spectrum = .{ .data = @intFromPtr(&spectrum) };
    var spans = [_]usize{@intFromPtr(&span)};
    var ir: Ir = .{ .block_size = b, .partitions = parts, .channels = 1, .format = 0, .spectra = @intFromPtr(&spans) };
    var samples: [b]f32 = @splat(0);
    var pcm = [_]usize{@intFromPtr(&samples)};
    var input: Input = .{ .block_size = b, .partitions = parts, .channels = 1, .format = 0, .spectra = 123, .samples = @intFromPtr(&pcm) };
    var result: [b]f32 = @splat(12345);
    var tail: [b]f32 = @splat(0);
    var outputs = [_]usize{@intFromPtr(&result)};
    var tails = [_]usize{@intFromPtr(&tail)};
    var output: Output = .{ .block_size = b, .channels = 1, .samples = @intFromPtr(&outputs), .overlap = @intFromPtr(&tails) };
    var irs = [_]usize{@intFromPtr(&ir)};
    var destinations = [_]usize{@intFromPtr(&output)};
    var gains = [_]f32{0.2};
    var commands: [256]u8 = undefined;
    var info: BatchInfo = .{ .buffer = &commands, .size = commands.len };
    try append(@intFromPtr(&info), 1, @intFromPtr(&input), 1, @intFromPtr(&irs), @intFromPtr(&gains), @intFromPtr(&destinations), false, testCheck);
    // Builders snapshot temporary arrays/gains; samples remain borrowed.
    irs[0] = 0;
    destinations[0] = 0;
    gains[0] = 900;
    var runtime: Runtime = .{};
    defer runtime.deinit();
    var signal: [b * 12]f32 = undefined;
    for (&signal, 0..) |*v, i| v.* = if (i < b * 4) @as(f32, @floatFromInt(@as(i32, @intCast(i % 11)) - 5)) / 10 else 0;
    for (0..12) |grain| {
        @memcpy(&samples, signal[grain * b ..][0..b]);
        try runtime.execute(@intFromPtr(&commands), info.offset, testCheck);
        for (result, 0..) |actual, i| {
            const n = grain * b + i;
            var expected: f32 = 0;
            for (0..@min(n + 1, taps.len)) |k| expected += signal[n - k] * taps[k] * 0.2;
            try std.testing.expectApproxEqAbs(expected, actual, 0.000002);
        }
    }
}

test "ACM refuses truncated unsupported and overflowing command batches" {
    var commands: [64]u8 = @splat(0);
    var runtime: Runtime = .{};
    defer runtime.deinit();
    try std.testing.expectError(error.InvalidParameter, runtime.execute(@intFromPtr(&commands), 5, testCheck));
    try std.testing.expectError(error.Unsupported, runtime.execute(@intFromPtr(&commands), commands.len, testCheck));
    var info: BatchInfo = .{ .buffer = &commands, .size = 16 };
    try std.testing.expectError(error.InvalidParameter, notification(@intFromPtr(&info), testCheck));
    try std.testing.expectEqual(@as(usize, 0), info.offset);
    info.size = commands.len;
    try notification(@intFromPtr(&info), testCheck);
    try runtime.execute(@intFromPtr(&commands), info.offset, testCheck);
    commands[8] = 255;
    try std.testing.expectError(error.InvalidParameter, runtime.execute(@intFromPtr(&commands), info.offset, testCheck));
}

test "ACM shared input fans out once with half spectra and independent overlap" {
    const b = 16;
    var spectrum: [b * 2]f16 = undefined;
    for (0..b) |k| {
        const angle = -2 * std.math.pi * @as(f64, @floatFromInt(k)) / (2 * b);
        spectrum[2 * k] = @floatCast(1 + @cos(angle));
        spectrum[2 * k + 1] = @floatCast(@sin(angle));
    }
    var span: Spectrum = .{ .data = @intFromPtr(&spectrum) };
    var spans = [_]usize{@intFromPtr(&span)};
    var ir: Ir = .{ .block_size = b, .partitions = 1, .channels = 1, .format = 1, .spectra = @intFromPtr(&spans) };
    var samples: [b * 2]f32 = @splat(0);
    samples[b - 1] = 1;
    var pcm = [_]usize{@intFromPtr(&samples)};
    var input: Input = .{ .block_size = b, .partitions = 1, .channels = 1, .format = 1, .spectra = 123, .samples = @intFromPtr(&pcm) };
    var result: [2][b * 2]f32 = @splat(@splat(12345));
    var tail: [2][b]f32 = @splat(@splat(0));
    var out_ptrs = [_]usize{ @intFromPtr(&result[0]), @intFromPtr(&result[1]) };
    var tail_ptrs = [_]usize{ @intFromPtr(&tail[0]), @intFromPtr(&tail[1]) };
    var output = [_]Output{
        .{ .block_size = b, .channels = 1, .samples = @intFromPtr(&out_ptrs[0]), .overlap = @intFromPtr(&tail_ptrs[0]) },
        .{ .block_size = b, .channels = 1, .samples = @intFromPtr(&out_ptrs[1]), .overlap = @intFromPtr(&tail_ptrs[1]) },
    };
    var irs = [_]usize{ @intFromPtr(&ir), @intFromPtr(&ir) };
    var destinations = [_]usize{ @intFromPtr(&output[0]), @intFromPtr(&output[1]) };
    var gains = [_]f32{ 0.5, 0.25 };
    var commands: [256]u8 = undefined;
    var info: BatchInfo = .{ .buffer = &commands, .size = commands.len };
    try append(@intFromPtr(&info), 2, @intFromPtr(&input), 2, @intFromPtr(&irs), @intFromPtr(&gains), @intFromPtr(&destinations), false, testCheck);
    var runtime: Runtime = .{};
    defer runtime.deinit();
    try runtime.execute(@intFromPtr(&commands), info.offset, testCheck);
    for (0..2) |ch| for (result[ch], 0..) |actual, i| {
        try std.testing.expectApproxEqAbs(if (i == b - 1 or i == b) gains[ch] else @as(f32, 0), actual, 0.0002);
    };
    try std.testing.expectEqual(@as(usize, 1), runtime.states.items.len);
    // The SharedIr builder must preserve independent input histories as well.
    @memset(&tail[0], 0);
    @memset(&tail[1], 0);
    var input2 = input;
    var inputs = [_]usize{ @intFromPtr(&input), @intFromPtr(&input2) };
    info.offset = 0;
    try append(@intFromPtr(&info), 2, @intFromPtr(&ir), 2, @intFromPtr(&inputs), @intFromPtr(&gains), @intFromPtr(&destinations), true, testCheck);
    runtime.deinit();
    try runtime.execute(@intFromPtr(&commands), info.offset, testCheck);
    for (0..2) |ch| for (result[ch], 0..) |actual, i| {
        try std.testing.expectApproxEqAbs(if (i == b - 1 or i == b) gains[ch] else @as(f32, 0), actual, 0.0002);
    };
    try std.testing.expectEqual(@as(usize, 2), runtime.states.items.len);
}
