// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Artur Strazewicz

//! Runs the host-only Vulkan compute/staging/readback probe.

const std = @import("std");
const vulkan = @import("vulkan");
const gpu = @import("gpu");

comptime {
    @import("host_memory.zig").exportRuntime();
}

const GuestMemory = struct {
    bytes: [131072]u8 = @splat(0),

    fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
        const self: *GuestMemory = @ptrCast(@alignCast(context.?));
        const start: usize = @intCast(address);
        if (start + destination.len > self.bytes.len) return false;
        @memcpy(destination, self.bytes[start..][0..destination.len]);
        return true;
    }

    fn write(context: ?*anyopaque, address: u64, source: []const u8) bool {
        const self: *GuestMemory = @ptrCast(@alignCast(context.?));
        const start: usize = @intCast(address);
        if (start + source.len > self.bytes.len) return false;
        @memcpy(self.bytes[start..][0..source.len], source);
        return true;
    }

    fn word(self: *GuestMemory, address: usize, value: u32) void {
        std.mem.writeInt(u32, self.bytes[address..][0..4], value, .little);
    }

    fn interface(self: *GuestMemory) vulkan.GuestMemory {
        return .{ .context = self, .read = read, .write = write };
    }
};

fn command(opcode: u8, body_words: u14) u32 {
    return (@as(u32, 3) << 30) |
        (@as(u32, body_words - 1) << 16) |
        (@as(u32, opcode) << 8);
}

fn customCommand(code: u6, body_words: u14) u32 {
    return command(gpu.pm4.nop, body_words) | (@as(u32, code) << 2);
}

const PresentProbe = struct {
    calls: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    center: [4]u8 = @splat(0),
    argument: i64 = 0,

    fn present(context: ?*anyopaque, frame: vulkan.PresentedFrame) bool {
        const self: *PresentProbe = @ptrCast(@alignCast(context.?));
        if (frame.pixels.len != @as(usize, frame.width) * frame.height * 4) return false;
        const center = (@as(usize, frame.height / 2) * frame.width + frame.width / 2) * 4;
        self.calls += 1;
        self.width = frame.width;
        self.height = frame.height;
        @memcpy(&self.center, frame.pixels[center..][0..4]);
        self.argument = frame.flip.argument;
        return true;
    }
};

fn vop1(opcode: u8, destination: u8, source: u9) u32 {
    return (@as(u32, 0x3f) << 25) |
        (@as(u32, destination) << 17) |
        (@as(u32, opcode) << 9) |
        source;
}

fn vop2(opcode: u8, destination: u8, source0: u8, source1: u8) u32 {
    return (@as(u32, opcode) << 25) |
        (@as(u32, destination) << 17) |
        (@as(u32, source1) << 9) |
        (256 + @as(u32, source0));
}

fn sop1(opcode: u8, destination: u8, source: u9) u32 {
    return 0xbe80_0000 | (@as(u32, destination) << 16) | (@as(u32, opcode) << 8) | source;
}

/// One indexed buffer access, encoded the way the hardware spells it.
///
/// The resource names its descriptor by the first scalar register divided by
/// four, and the scalar offset is the inline zero.
fn mubuf(opcode: u7, byte_offset: u12, data: u8, address: u8, resource: u8) [2]u32 {
    return .{
        0xe000_0000 | (@as(u32, opcode) << 18) | (1 << 13) | byte_offset,
        (0x80 << 24) | (@as(u32, resource / 4) << 16) | (@as(u32, data) << 8) | address,
    };
}

/// A fourteen-instruction indexed copy, run for its bounds and its mask.
///
/// Each lane copies the element its own index names, which is the shape of
/// nearly every compute kernel a title dispatches. What this establishes is the
/// two rules around that: a lane reading past the end of its source is given
/// zero, a lane writing past the end of its destination is ignored, and lanes
/// the execution mask has switched off do neither.
///
/// Written as encoded instructions rather than assembled from a source, because
/// what is under test is the path from those very words to a running pipeline —
/// an assembler in between would be one more thing that could be the reason it
/// worked.
fn runIndexedCopyKernel(
    allocator: std.mem.Allocator,
    renderer: *vulkan.Renderer,
    guest: *GuestMemory,
    backend: gpu.DcbBackend,
) !void {
    const program = 0x800;
    const source = 0x2000;
    const destination = 0x2100;
    const source_records = 4;
    const destination_records = 16;
    const guard = destination + destination_records * 4;
    const sentinel: u32 = 0xdead_beef;
    const enabled_lanes = 4;
    const dispatched_lanes = 16;

    var cursor: usize = program;
    const emit = struct {
        fn one(memory: *GuestMemory, at: *usize, value: u32) void {
            memory.word(at.*, value);
            at.* += 4;
        }
        fn pair(memory: *GuestMemory, at: *usize, values: [2]u32) void {
            one(memory, at, values[0]);
            one(memory, at, values[1]);
        }
    };

    emit.pair(guest, &cursor, .{ 0xf40c_0200, 125 << 25 }); //  1 s_load_dwordx8 s8:s15, s0:s1
    emit.one(guest, &cursor, 0xbf80_0000); //                    2 s_nop
    emit.one(guest, &cursor, sop1(0x04, 126, 128 + enabled_lanes * 4 - 1)); // 3 exec = lanes 0..3
    emit.one(guest, &cursor, 0xbf80_0000); //                    4 s_nop
    emit.pair(guest, &cursor, mubuf(0x0c, 0, 1, 0, 8)); //       5 v1 <- source[lane]
    emit.one(guest, &cursor, 0xbf80_0000); //                    6 s_nop
    emit.pair(guest, &cursor, mubuf(0x1c, 0, 1, 0, 12)); //      7 destination[lane] <- v1
    emit.one(guest, &cursor, 0xbf80_0000); //                    8 s_nop
    emit.pair(guest, &cursor, mubuf(0x0c, 16, 2, 0, 8)); //      9 v2 <- past the source's end
    emit.one(guest, &cursor, 0xbf80_0000); //                   10 s_nop
    emit.pair(guest, &cursor, mubuf(0x1c, 32, 2, 0, 12)); //    11 destination[8..] <- v2
    emit.pair(guest, &cursor, mubuf(0x1c, 64, 1, 0, 12)); //    12 past the destination's end
    emit.one(guest, &cursor, 0xbf80_0000); //                   13 s_nop
    emit.one(guest, &cursor, 0xbf81_0000); //                   14 s_endpgm

    const input = [_]u32{ 0x0a0b_0c0d, 0x1a1b_1c1d, 0x2a2b_2c2d, 0x3a3b_3c3d };
    for (input, 0..) |value, index| guest.word(source + index * 4, value);
    for (0..destination_records + 4) |index| guest.word(destination + index * 4, sentinel);

    const table = 0x900;
    const descriptors = [_][4]u32{
        .{ source, 4 << 16, source_records, 0 },
        .{ destination, 4 << 16, destination_records, 0 },
    };
    for (descriptors, 0..) |descriptor, slot| {
        for (descriptor, 0..) |value, index| guest.word(table + slot * 16 + index * 4, value);
    }

    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), program >> 8);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 2 << 1);
    try state.writeRegister(.shader, 0x207, dispatched_lanes);
    try state.writeRegister(.shader, 0x208, 1);
    try state.writeRegister(.shader, 0x209, 1);
    try state.writeRegister(.shader, compute.userDataBase(), table);
    try state.writeRegister(.shader, compute.userDataBase() + 1, 0);

    const stream = [_]u32{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 };
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    _ = executor.execute(&stream) catch |err| {
        // The renderer knows why it refused; the executor only knows that it
        // did, and "rejected" on its own names nothing that can be acted on.
        std.debug.print("indexed copy refused: {s} (renderer: {s})\n", .{
            @errorName(err),
            if (renderer.last_dispatch_error) |reason| @errorName(reason) else "none",
        });
        return err;
    };

    const read = struct {
        fn at(memory: *GuestMemory, address: usize) u32 {
            return std.mem.readInt(u32, memory.bytes[address..][0..4], .little);
        }
    };

    for (input, 0..) |expected, index| {
        if (read.at(guest, destination + index * 4) != expected) return error.IndexedCopyMismatch;
    }
    // Lanes the mask switched off wrote nothing, though their elements sit well
    // inside the destination.
    for (enabled_lanes..8) |index| {
        if (read.at(guest, destination + index * 4) != sentinel) return error.ExecutionMaskIgnored;
    }
    // Reads past the end of the source produced zero rather than whatever lies
    // beyond it.
    for (0..enabled_lanes) |index| {
        if (read.at(guest, destination + (8 + index) * 4) != 0) {
            return error.BufferBoundsReadMismatch;
        }
    }
    // Writes past the end of the destination were dropped.
    for (0..4) |index| {
        if (read.at(guest, guard + index * 4) != sentinel) return error.BufferBoundsWriteMismatch;
    }
}

fn imageDescriptorWords(address: u32, width: u32, height: u32) [8]u32 {
    const encoded = address >> 8;
    const width_minus_one = width - 1;
    return .{
        encoded,
        (@as(u32, 60) << 20) | ((width_minus_one & 3) << 30), // RGBA8_UINT
        (width_minus_one >> 2) | ((height - 1) << 14),
        0x0000_0fac | (@as(u32, 9) << 28), // identity dst_sel, linear 2D
        width - 1, // explicit pitch
        0,
        0,
        0,
    };
}

fn sampledImageDescriptorWords(address: u32, width: u32, height: u32) [8]u32 {
    var words = imageDescriptorWords(address, width, height);
    words[1] &= ~(@as(u32, 0xff) << 20);
    words[1] |= @as(u32, 56) << 20; // RGBA8_UNORM
    return words;
}

fn runStorageImageCopyKernel(
    allocator: std.mem.Allocator,
    renderer: *vulkan.Renderer,
    guest: *GuestMemory,
    backend: gpu.DcbBackend,
) !void {
    const program = 0x1800;
    const width = 4;
    const height = 4;
    var program_cursor: usize = program;
    for (0..height) |y| {
        for (0..width) |x| {
            guest.word(program_cursor, vop1(0x01, 0, @intCast(128 + x))); // v0 = x
            guest.word(program_cursor + 4, vop1(0x01, 1, @intCast(128 + y))); // v1 = y
            guest.word(program_cursor + 8, 0xf000_0f08); // image_load v4:v7, v[0:1], s[0:7]
            guest.word(program_cursor + 12, 0x0000_0400);
            guest.word(program_cursor + 16, 0xf020_0f0a); // image_store v4:v7, v0, s[8:15], NSA v1
            guest.word(program_cursor + 20, 0x0002_0400);
            guest.word(program_cursor + 24, 0x0000_0001);
            program_cursor += 28;
        }
    }
    guest.word(program_cursor, 0xbf81_0000);

    const source = 0x5000;
    const destination = 0x6000;
    const row_pitch_bytes = 256;
    const allocation_bytes = row_pitch_bytes * height;
    @memset(guest.bytes[source .. source + allocation_bytes], 0);
    @memset(guest.bytes[destination .. destination + allocation_bytes], 0);
    for (0..height) |y| {
        for (0..width * 4) |byte| {
            guest.bytes[source + y * row_pitch_bytes + byte] = @intCast(((y * width * 4 + byte) * 13 + 7) & 0xff);
        }
    }

    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), program >> 8);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    try state.writeRegister(.shader, 0x207, 1);
    try state.writeRegister(.shader, 0x208, 1);
    try state.writeRegister(.shader, 0x209, 1);
    const descriptors = [_][8]u32{
        imageDescriptorWords(source, width, height),
        imageDescriptorWords(destination, width, height),
    };
    for (descriptors, 0..) |descriptor, descriptor_index| {
        for (descriptor, 0..) |word, word_index| {
            try state.writeRegister(
                .shader,
                compute.userDataBase() + @as(u32, @intCast(descriptor_index * 8 + word_index)),
                word,
            );
        }
    }
    const stream = [_]u32{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 };
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    _ = executor.execute(&stream) catch |err| {
        std.debug.print("storage image copy refused: {s} (renderer: {s})\n", .{
            @errorName(err),
            if (renderer.last_dispatch_error) |reason| @errorName(reason) else "none",
        });
        return err;
    };
    // The synthetic stream has no RELEASE_MEM packet before the host reads
    // guest memory. Publish the resident storage-image result explicitly.
    try renderer.flushPendingGuestWrites();
    for (0..height) |y| {
        for (0..width * 4) |byte| {
            const source_byte = guest.bytes[source + y * row_pitch_bytes + byte];
            const destination_byte = guest.bytes[destination + y * row_pitch_bytes + byte];
            if (source_byte != destination_byte) {
                return error.StorageImageCopyMismatch;
            }
        }
    }
}

fn runComputeSampledImageKernel(
    allocator: std.mem.Allocator,
    renderer: *vulkan.Renderer,
    guest: *GuestMemory,
    backend: gpu.DcbBackend,
) !void {
    const program = 0x1c00;
    var cursor: usize = program;
    guest.word(cursor, vop1(0x01, 0, 255)); // v0 = 0.25
    guest.word(cursor + 4, 0x3e80_0000);
    cursor += 8;
    guest.word(cursor, vop1(0x01, 1, 255)); // v1 = 0.25
    guest.word(cursor + 4, 0x3e80_0000);
    cursor += 8;
    guest.word(cursor, 0xf09c_010a); // image_sample_lz dmask:x, dim:2d, one NSA dword
    guest.word(cursor + 4, 0x0040_0200); // v2, v0 + NSA, s[0:7], s[8:11]
    guest.word(cursor + 8, 0x0000_0001); // NSA coordinate 1 is v1
    cursor += 12;
    guest.word(cursor, 0xe070_0000); // buffer_store_dword v2, v0, s[12:15], 0
    guest.word(cursor + 4, 0x8003_0200);
    guest.word(cursor + 8, 0xbf81_0000);

    const width = 4;
    const height = 4;
    const source = 0x7000;
    const destination = 0x10000;
    const row_pitch_bytes = 256;
    const allocation_bytes = row_pitch_bytes * height;
    @memset(guest.bytes[source .. source + allocation_bytes], 0);
    @memset(guest.bytes[destination .. destination + 4], 0);
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = source + y * row_pitch_bytes + x * 4;
            guest.bytes[pixel] = 255;
            guest.bytes[pixel + 1] = @intCast(x * 17);
            guest.bytes[pixel + 2] = @intCast(y * 19);
            guest.bytes[pixel + 3] = 255;
        }
    }

    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), program >> 8);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    try state.writeRegister(.shader, 0x207, 1);
    try state.writeRegister(.shader, 0x208, 1);
    try state.writeRegister(.shader, 0x209, 1);
    const image = sampledImageDescriptorWords(source, width, height);
    for (image, 0..) |word, index| {
        try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    }
    for (0..4) |index| {
        try state.writeRegister(.shader, compute.userDataBase() + 8 + @as(u32, @intCast(index)), 0);
    }
    const output_descriptor = [_]u32{ destination, 4 << 16, 1, 0 };
    for (output_descriptor, 0..) |word, index| {
        try state.writeRegister(.shader, compute.userDataBase() + 12 + @as(u32, @intCast(index)), word);
    }

    const stream = [_]u32{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 };
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    _ = executor.execute(&stream) catch |err| {
        std.debug.print("compute sampled image refused: {s} (renderer: {s})\n", .{
            @errorName(err),
            if (renderer.last_dispatch_error) |reason| @errorName(reason) else "none",
        });
        return err;
    };
    const sampled = std.mem.readInt(u32, guest.bytes[destination..][0..4], .little);
    if (sampled != 0x3f80_0000) {
        std.debug.print("compute sampled image mismatch: got 0x{x:0>8}, want 0x3f800000\n", .{sampled});
        return error.ComputeSampledImageMismatch;
    }
}

fn runCompressedArrayCopyKernel(allocator: std.mem.Allocator, renderer: *vulkan.Renderer, guest: *GuestMemory, backend: gpu.DcbBackend, gather: bool) !void {
    const program: u32 = if (gather) 0x3000 else 0x2000;
    const table = 0x4000;
    const source = 0x8000;
    const destination = 0xa000;
    var input = sampledImageDescriptorWords(source, 4, 4);
    input[1] = (input[1] & ~(@as(u32, 0x1ff) << 20)) | (@as(u32, 169) << 20); // BC1_UNORM
    input[3] = (input[3] & 0x0fff_ffff) | (@as(u32, 13) << 28);
    input[4] = 1; // two layers
    var output = sampledImageDescriptorWords(destination, 4, 4);
    output[3] = (output[3] & 0x0fff_ffff) | (@as(u32, 13) << 28);
    output[4] = 1;
    const source_layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&input));
    const source_view = try source_layout.subresource(0, 0, 2);
    const output_layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&output));
    const output_view = try output_layout.subresource(0, 0, 2);
    @memset(guest.bytes[source .. source + 4096], 0);
    @memset(guest.bytes[destination .. destination + 4096], 0);
    guest.word(source, 0xf800); // red BC1 block on slice zero
    guest.word(source + @as(usize, @intCast(source_view.source_layer_bytes)), 0x07e0); // green on slice one
    for ([_][8]u32{ input, output }, 0..) |descriptor, index| {
        for (descriptor, 0..) |word, slot| guest.word(table + index * 32 + slot * 4, word);
    }
    for (0..4) |index| guest.word(table + 64 + index * 4, 0); // nearest sampler
    const marker = 0xc000;
    for ([_]u32{ marker, 4 << 16, 4, 0 }, 0..) |word, index| guest.word(table + 80 + index * 4, word);
    const fetch_code = [_]u32{
        0xf40c_0200, 125 << 25, // T# s8:s15 = compressed input
        0xf408_0600, (125 << 25) | 80, // V# s24:s27 = completion marker
        vop1(1, 0, 128), vop1(1, 1, 128), vop1(1, 2, 129), // texel (0,0,1)
        0xf000_0f28, 0x0002_0400, // array load v4:v7
        0xe070_0000, 0x8006_0500, // unconditional marker = green (1.0)
        0xf400_1a80, (125 << 25) | 64, // s_load_dword vcc_lo, output enabled
        0xbefe_04c1, // s_mov_b64 exec, -1
        0xbf8c_007f, // s_waitcnt
        0xbf07_6a80, // s_cmp_lg_u32 0, vcc_lo
        0xbf84_0004, // skip output descriptor setup AND store when disabled
        0xf40c_0200, (125 << 25) | 32, // same SGPRs now name the output
        0xf020_0f28, 0x0002_0400, // array store v4:v7
        0xbf81_0000,
    };
    const gather_code = [_]u32{
        0xf40c_0200, 125 << 25, // T# s8:s15 = compressed input
        0xf408_0400, (125 << 25) | 64, // S# s16:s19
        vop1(1, 0, 255), 0x3f00_0000, // normalized u = 0.5
        vop1(1, 1, 255), 0x3f00_0000, // normalized v = 0.5
        vop1(1, 2, 255), 0x3f80_0000, // array layer = 1.0
        0xf11c_0228, 0x0082_0400, // gather green from slice one into v4:v7
        0xf40c_0200, (125 << 25) | 32, // T# now names the output
        vop1(1, 0, 128), vop1(1, 1, 128), vop1(1, 2, 129), // integer texel (0,0,1)
        0xf020_0f28, 0x0002_0400, // store all four gathered values
        0xbf81_0000,
    };
    const code: []const u32 = if (gather) &gather_code else &fetch_code;
    for (code, 0..) |word, index| guest.word(program + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), program >> 8);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, compute.userDataBase(), table);
    try state.writeRegister(.shader, compute.userDataBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    try state.writeRegister(.shader, 0x207, 1);
    try state.writeRegister(.shader, 0x208, 1);
    try state.writeRegister(.shader, 0x209, 1);
    const stream = [_]u32{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 };
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    const result = destination + @as(usize, @intCast(output_view.source_layer_bytes));
    const expected: [4]u8 = if (gather) .{ 255, 255, 255, 255 } else .{ 0, 255, 0, 255 };
    const flags: []const u32 = if (gather) &.{0} else &.{ 0, 1, 0, 1 };
    for (flags, 0..) |enabled, index| {
        guest.word(table + 64, enabled);
        guest.word(marker, 0);
        _ = try executor.execute(&stream);
        try renderer.flushPendingGuestWrites();
        if (!gather) {
            try std.testing.expectEqual(@as(u32, 0x3f80_0000), std.mem.readInt(u32, guest.bytes[marker..][0..4], .little));
        }
        const pixel: []const u8 = if (!gather and index == 0) &.{ 0, 0, 0, 0 } else &expected;
        try std.testing.expectEqualSlices(u8, pixel, guest.bytes[result..][0..4]);
    }
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, guest.bytes[destination..][0..4]);
}

fn runFragmentStorageProbe(
    allocator: std.mem.Allocator,
    renderer: *vulkan.Renderer,
    guest: *GuestMemory,
    backend: gpu.DcbBackend,
    state: *gpu.State,
    color_address: usize,
) !void {
    const program = 0xd000;
    const destination = 0xe000;
    const extent = 64;
    var descriptor = sampledImageDescriptorWords(destination, extent, extent);
    descriptor[1] = (descriptor[1] & ~(@as(u32, 0x1ff) << 20)) | (23 << 20); // RG16_UNORM
    descriptor[3] = (descriptor[3] & 0x0fff_ffff) | (13 << 28);
    descriptor[4] = 1; // two array layers
    const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&descriptor));
    const view = try layout.subresource(0, 0, 2);
    const layer_bytes: usize = @intCast(view.source_layer_bytes);
    for (0..layer_bytes * 2 / 4) |index| guest.word(destination + index * 4, 0x2222_1111);
    const code = [_]u32{
        0xc801_0000, 0xc805_0100, // interpolated UV fallback = FragCoord / extent
        vop1(1, 5, 255),  0x4280_0000, // 64.0
        vop2(8, 2, 0, 5), vop2(8, 3, 1, 5),
        vop1(7, 2, 258), vop1(7, 3, 259), // integer texel coordinates
        vop1(1, 4, 129), // array slice 1
        vop1(1, 10, 8), vop1(1, 11, 9), // RG from live USER_DATA
        vop1(1, 6, 255), 0x3f00_0000, // left half: u < 0.5
        0xbe94_047e, // s_mov_b64 s20, exec
        0x7c22_0d00, // v_cmpx_lt_f32 v0, v6
        0xf020_0328, 0x0000_0a02, // image_store v10:v11, v2:v4, s0 dmask:rg array
        0xbefe_0414, // restore EXEC before the color export
        vop1(1, 12, 128),
        vop1(1, 13, 128),
        vop1(1, 14, 242),
        vop1(1, 15, 242),
        0xf800_080f, 0x0f0e_0d0c, // blue MRT0 on both halves
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(program + index * 4, word);
    const pixel = gpu.resources.ShaderStage.pixel;
    try state.writeRegister(.shader, pixel.programRegisterBase(), program >> 8);
    try state.writeRegister(.shader, pixel.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, pixel.userDataBase() - 1, 10 << 1);
    for (descriptor, 0..) |word, index| try state.writeRegister(.shader, pixel.userDataBase() + @as(u32, @intCast(index)), word);
    try state.writeRegister(.shader, pixel.userDataBase() + 9, 0x3f40_0000); // G = .75
    const stream = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 0 };
    var executor = gpu.DcbExecutor{ .state = state, .backend = backend, .allocator = allocator };
    // Queue two writers, then consume the resident result as both a storage
    // image and a sampled image, without first materializing it on the CPU.
    for ([_]bool{ false, true }) |sampled| {
        const final_red: u32 = if (sampled) 0x3e80_0000 else 0x3f40_0000;
        for ([_]u32{ 0x3f00_0000, final_red }) |red| {
            try state.writeRegister(.shader, pixel.userDataBase() + 8, red);
            _ = try executor.execute(&stream);
            if (renderer.last_draw_error != null) return error.FragmentStorageDrawFailed;
        }
        const consumer_program: u32 = if (sampled) 0xca00 else 0xc000;
        const buffer = 0x18000;
        const load_code = [_]u32{
            vop1(1, 0, 152), vop1(1, 1, 160), vop1(1, 2, 129), // (24,32,1)
            0xf000_0328, 0x0000_0400, // array image_load RG -> v4:v5
            0xe074_0000, 0x8002_0400, // buffer_store_dwordx2 -> V#s8
            0xbf81_0000,
        };
        const sample_code = [_]u32{
            vop1(1, 0, 255), @bitCast(@as(f32, 24.5 / 64.0)),
            vop1(1, 1, 255), @bitCast(@as(f32, 32.5 / 64.0)),
            vop1(1, 2, 242), // array slice 1.0
            0xf09c_0328, 0x0040_0400, // array image_sample_lz RG, S#s8
            0xe074_0000, 0x8003_0400, // buffer_store_dwordx2 -> V#s12
            0xbf81_0000,
        };
        const consumer_code: []const u32 = if (sampled) &sample_code else &load_code;
        for (consumer_code, 0..) |word, index| guest.word(consumer_program + index * 4, word);
        var consumer_state = gpu.State{};
        const compute = gpu.resources.ShaderStage.compute;
        try consumer_state.writeRegister(.shader, compute.programRegisterBase(), consumer_program >> 8);
        try consumer_state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try consumer_state.writeRegister(.shader, 0x213, (if (sampled) @as(u32, 16) else 12) << 1);
        for ([_]u32{ 0x207, 0x208, 0x209 }) |reg| try consumer_state.writeRegister(.shader, reg, 1);
        for (descriptor, 0..) |word, index| try consumer_state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        for (0..4) |index| try consumer_state.writeRegister(.shader, compute.userDataBase() + 8 + @as(u32, @intCast(index)), 0);
        const buffer_sgpr: u32 = if (sampled) 12 else 8;
        for ([_]u32{ buffer, 4 << 16, 2, 0 }, 0..) |word, index| {
            try consumer_state.writeRegister(.shader, compute.userDataBase() + buffer_sgpr + @as(u32, @intCast(index)), word);
        }
        guest.word(buffer, 0);
        guest.word(buffer + 4, 0);
        var consumer = gpu.DcbExecutor{ .state = &consumer_state, .backend = backend, .allocator = allocator };
        const translated_before = renderer.translated_dispatches;
        _ = try consumer.execute(&.{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 });
        if (renderer.translated_dispatches != translated_before + 1) {
            std.debug.print("fragment consumer did not execute on GPU: sampled={any} error={any}\n", .{ sampled, renderer.last_dispatch_error });
            return error.FragmentStorageConsumerSkipped;
        }
        var readback: [8]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(buffer, &readback);
        const red: f32 = @bitCast(std.mem.readInt(u32, readback[0..4], .little));
        const green: f32 = @bitCast(std.mem.readInt(u32, readback[4..8], .little));
        try std.testing.expectApproxEqAbs(@as(f32, @bitCast(final_red)), red, 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.75), green, 0.0001);
    }
    try renderer.flushPendingGuestWrites();
    for ([_]usize{ 24, 40 }) |x| {
        const offset = (32 * extent + x) * 4;
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, guest.bytes[color_address + offset ..][0..4]);
        try std.testing.expectEqual(@as(u32, 0x2222_1111), std.mem.readInt(u32, guest.bytes[destination + offset ..][0..4], .little));
        const written = guest.bytes[destination + layer_bytes + offset ..][0..4];
        if (x < 32) {
            for ([_]usize{ 0, 2 }) |component| {
                const value = std.mem.readInt(u16, written[component..][0..2], .little);
                const expected: u16 = if (component == 0) 16384 else 49151;
                try std.testing.expect(value >= expected - 1 and value <= expected + 1);
            }
        } else try std.testing.expectEqual(@as(u32, 0x2222_1111), std.mem.readInt(u32, written, .little));
    }
    std.debug.print("fragment storage passed: RG array slice, per-pixel EXEC, color export, queued reuse, storage/sample consumers and writeback\n", .{});
}

fn runInlineMetadataBufferProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    var memory = guest.interface();
    memory.shader_header = struct {
        fn header(_: ?*anyopaque, program: u64) ?u64 {
            return if (program == 0x100) 0x600 else null;
        }
    }.header;
    _ = renderer.dcbBackend(memory);
    // The captured scene layout has an SRT declaration of two words, with
    // its actual input V# at USER_DATA[6:9]. Resolving metadata offset 6 as an
    // SRT access used to abort this dispatch before its inline buffer read.
    guest.word(0x608, 0x700);
    guest.word(0x700, 0x740);
    guest.word(0x720, 0x750);
    guest.word(0x728, 2 << 16); // eud=0, srt=2
    guest.word(0x72c, 2); // two direct entries
    guest.word(0x734, 2); // two constant-buffer entries
    guest.word(0x740, 0x0000_ffff); // SRT pointer at USER_DATA[0]
    guest.word(0x750, 0x8006_7fff); // unused slot 0; buffer slot 1 offset 6
    const code = [_]u32{
        sop1(4, 12, 2), sop1(4, 14, 4), // output V# from USER_DATA[2:5]
        0xf420_0003, 125 << 25, // s_buffer_load_dword s0, s6:s9, 0
        vop1(1, 0, 0), // v0 = loaded scalar
        0xe070_0000, 0x8003_0000, // buffer_store_dword v0, s12:s15
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 10 << 1);
    const userdata = [_]u32{ 0x400, 0, 0x11000, 4 << 16, 1, 0x5204, 0x10000, 4 << 16, 1, 0x5204 };
    for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    for ([_]u32{ 0x1234_5678, 0xaabb_ccdd }) |expected| {
        guest.word(0x10000, expected);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        var result: [4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x11000, &result);
        try std.testing.expectEqual(expected, std.mem.readInt(u32, &result, .little));
    }
    std.debug.print("inline metadata buffer probe passed: USER_DATA buffer offsets are independent of SRT size\n", .{});
}

fn runVectorImageProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    var code: std.ArrayList(u32) = .empty;
    defer code.deinit(allocator);
    try code.appendSlice(allocator, &.{
        0xf40c_0400, 125 << 25, // first T# in s16:s23
        0xf408_0600, (125 << 25) | 64, // output V# in s24:s27
        0xf408_0300, (125 << 25) | 80, // sampler s12:s15
        0xbea0_047e, // save initial EXEC in s32:s33
        vop1(1, 1, 240), vop1(1, 2, 240), // normalized coordinates
    });
    for (0..8) |i| try code.append(allocator, vop1(1, @intCast(8 + i), @intCast(16 + i)));
    try code.appendSlice(allocator, &.{
        (0x3e << 25) | (0xd4 << 17) | 130, // v_cmpx_gt_u32 2, v0: first two lanes
        0xf40c_0400, (125 << 25) | 32, // second T# replaces s16:s23
    });
    for (0..8) |i| try code.append(allocator, vop1(1, @intCast(8 + i), @intCast(16 + i)));
    try code.appendSlice(allocator, &.{0xbefe_0420}); // restore EXEC
    const waterfall = code.items.len;
    for (0..8) |i| try code.append(allocator, vop1(2, @intCast(4 + i), @intCast(256 + 8 + i)));
    try code.append(allocator, 0xbeea_047e); // preserve remaining lanes in VCC
    for (0..8) |i| try code.append(allocator, (0x3e << 25) | (0xd2 << 17) | (@as(u32, @intCast(8 + i)) << 9) | @as(u32, @intCast(4 + i)));
    try code.appendSlice(allocator, &.{
        0xf09c_0108, 0x0061_1001, // sample red at LOD zero into v16, using T#s4/S#s12
        0x8afe_7e6a, // s_andn2_b64 exec, vcc, exec
    });
    const displacement: i16 = @intCast(@as(isize, @intCast(waterfall)) - @as(isize, @intCast(code.items.len + 1)));
    try code.append(allocator, 0xbf89_0000 | @as(u32, @as(u16, @bitCast(displacement))));
    try code.appendSlice(allocator, &.{
        0xbefe_0420, // restore EXEC for output
        0xe070_2000, 0x8006_1000, // indexed store v16, v0, V#s24
        0xbf81_0000,
    });
    for (code.items, 0..) |word, i| guest.word(0x100 + i * 4, word);
    for ([_]u32{ 0x8000, 0x9000 }, 0..) |address, i| {
        const image = sampledImageDescriptorWords(address, 1, 1);
        for (image, 0..) |word, j| guest.word(0x1000 + i * 32 + j * 4, word);
        guest.word(address, if (i == 0) 0xff00_00ff else 0xff00_0040);
    }
    for ([_]u32{ 0x3000, 4 << 16, 4, 0 }, 0..) |word, i| guest.word(0x1040 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 2 << 1);
    try state.writeRegister(.shader, compute.userDataBase(), 0x1000);
    try state.writeRegister(.shader, compute.userDataBase() + 1, 0);
    const result = try renderer.dispatchRdna2State(&state, .{ 4, 1, 1 }, .{ 1, 1, 1 });
    try std.testing.expect(result.spirv_words != 0);
    var pixels: [16]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x3000, &pixels);
    for (0..4) |i| {
        const actual: f32 = @bitCast(std.mem.readInt(u32, pixels[i * 4 ..][0..4], .little));
        const expected: f32 = if (i < 2) 64.0 / 255.0 else 1;
        std.debug.print("vector resource lane {d}: {d}\n", .{ i, actual });
        try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
    }
    try std.testing.expectEqual(@as(u64, 2), renderer.sampled_image_uploads);
    const saved_descriptors: [64]u8 = guest.bytes[0x1000..0x1040].*;
    @memset(guest.bytes[0x1000..0x1040], 0);
    _ = try renderer.dispatchRdna2State(&state, .{ 4, 1, 1 }, .{ 1, 1, 1 });
    try renderer.readbackGuestStorageBuffer(0x3000, &pixels);
    try std.testing.expect(std.mem.allEqual(u8, &pixels, 0));
    @memcpy(guest.bytes[0x1000..0x1040], &saved_descriptors);
    _ = try renderer.dispatchRdna2State(&state, .{ 4, 1, 1 }, .{ 1, 1, 1 });
    try renderer.readbackGuestStorageBuffer(0x3000, &pixels);
    for (0..4) |i| {
        const actual: f32 = @bitCast(std.mem.readInt(u32, pixels[i * 4 ..][0..4], .little));
        try std.testing.expectApproxEqAbs(@as(f32, if (i < 2) 64.0 / 255.0 else 1), actual, 0.00001);
    }
    try std.testing.expectEqual(@as(u64, 2), renderer.sampled_image_uploads);
    std.debug.print("vector image resources passed: masked descriptor tuples and readfirstlane waterfall\n", .{});
}

fn runScalarLoopProbe(allocator: std.mem.Allocator) !void {
    for (0..2) |case_index| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        const code = [_]u32{
            if (case_index == 0) 0xbe8c_047e else 0xbeff_0380, // save EXEC, or clear EXEC_HI only
            vop1(1, 1, 128),
            0xbe88_0380, // counter = 0
            0xbe89_0384, // limit = 4
            0xd746_0001, 129 | (128 << 9) | (257 << 18), // v1 += 1
            0x8108_8108, // counter += 1
            0xbf0a_0908, // counter < limit
            0xbf85_fffb, // loop to the vector increment
            0xe070_2000,
            0x8000_0100,
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        for (0..64) |index| guest.word(0x10000 + index * 4, 0x1234_5678);
        var state = gpu.State{};
        const stage = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, stage.programRegisterBase(), 1);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, 4 << 1);
        for ([_]u32{ 0x10000, 4 << 16, 64, 0 }, 0..) |word, index|
            try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(index)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        var output: [256]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &output);
        for (0..64) |lane| {
            const expected: u32 = if (case_index == 0 or lane < 32) 4 else 0x1234_5678;
            try std.testing.expectEqual(expected, std.mem.readInt(u32, output[lane * 4 ..][0..4], .little));
        }
    }
    std.debug.print("scalar loops passed: saved EXEC, high-half writes, four iterations and inactive lanes\n", .{});
}

fn runWholeQuadModeProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        sop1(3, 106, 255), 0x1234_5678, // preserve VCC low
        0xf400_0282, 125 << 25, // load s10 from input pointer s4:s5
        0xbeeb_090a, // captured s_wqm_b32 vcc_hi, s10
        (0x8000_0000 | (0x0a << 23) | (11 << 16) | (128 << 8) | 129), // s_cselect_b32 s11, 1, 0
        vop1(1, 1, 107),
        vop1(1, 2, 106),
        vop1(1, 3, 11),
        0xe07c_0000, 0x8000_0100, // buffer_store_dwordx3 v1:v3, V#s0
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const stage = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, stage.programRegisterBase(), 1);
    try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 6 << 1);
    for ([_]u32{ 0x10000, 0, 12, 0, 0x9000, 0 }, 0..) |word, index|
        try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(index)), word);
    for ([_][2]u32{ .{ 0x1020_4800, 0xf0f0_ff00 }, .{ 0, 0 }, .{ 0x8000_0001, 0xf000_000f } }) |test_case| {
        guest.word(0x9000, test_case[0]);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        var output: [12]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &output);
        try std.testing.expectEqual(test_case[1], std.mem.readInt(u32, output[0..4], .little));
        try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, output[4..8], .little));
        try std.testing.expectEqual(@as(u32, @intFromBool(test_case[0] != 0)), std.mem.readInt(u32, output[8..12], .little));
    }
    std.debug.print("whole quad mode passed: captured VCC high destination, preserved low word, SCC and changing input\n", .{});
}

fn runGatherLodProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 6, 18), vop1(1, 7, 16), vop1(1, 8, 17), vop1(1, 9, 19),
        0xf130_0108, 0x0040_0006, // gather_c_l: reference, x, y, lod
        0xe078_0000, 0x8003_0000, // output four floats through V#s12
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var image = sampledImageDescriptorWords(0x8000, 4, 4);
    image[3] |= (1 << 16) | (@as(u32, @intFromEnum(gpu.resources.TileMode.standard_4kb)) << 20);
    image[5] = 1 << 4;
    const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
    const red = [2][4]u8{ .{ 32, 224, 96, 192 }, .{ 224, 32, 192, 96 } };
    for (0..2) |level| {
        const view = try texture.subresource(@intCast(level), 0, 1);
        for (0..view.height) |y| for (0..view.width) |x| {
            const selected = if (level == 0 and x >= 1 and x <= 2 and y >= 1 and y <= 2)
                red[0][(y - 1) * 2 + x - 1]
            else if (level == 1) red[1][y * 2 + x] else 0;
            const offset: usize = @intCast(try view.sourceByteOffset(@intCast(x), @intCast(y), 0, 0));
            guest.word(0x8000 + offset, 0xff00_0000 | @as(u32, selected));
        };
    }
    var state = gpu.State{};
    const stage = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, stage.programRegisterBase(), 1);
    try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 20 << 1);
    var userdata: [20]u32 = @splat(0);
    @memcpy(userdata[0..8], &image);
    userdata[9] = 0xfff << 12;
    userdata[10] = (1 << 20) | (1 << 22) | (2 << 26); // linear sampler must still gather individual texels
    @memcpy(userdata[12..16], &[_]u32{ 0x6000, 0, 16, 0 });
    userdata[16] = @bitCast(@as(f32, 0.5));
    userdata[17] = @bitCast(@as(f32, 0.5));
    for (0..8) |comparison| {
        userdata[8] = @as(u32, @intCast(comparison)) << 12;
        for ([_]f32{ -1, 0, 0.6, 1, 9 }) |lod| {
            userdata[18] = @bitCast(@as(f32, 96.0 / 255.0));
            userdata[19] = @bitCast(lod);
            for (userdata, 0..) |word, index| try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(index)), word);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
            var output: [16]u8 = undefined;
            try renderer.readbackGuestStorageBuffer(0x6000, &output);
            const mip: usize = if (lod < 0.5) 0 else 1;
            for ([_]usize{ 2, 3, 1, 0 }, 0..) |texel, index| {
                const reference: f32 = 96.0 / 255.0;
                const depth = @as(f32, @floatFromInt(red[mip][texel])) / 255.0;
                const passes = switch (comparison) {
                    0 => false,
                    1 => reference < depth,
                    2 => reference == depth,
                    3 => reference <= depth,
                    4 => reference > depth,
                    5 => reference != depth,
                    6 => reference >= depth,
                    7 => true,
                    else => unreachable,
                };
                const actual: f32 = @bitCast(std.mem.readInt(u32, output[index * 4 ..][0..4], .little));
                try std.testing.expectEqual(@as(f32, if (passes) 1 else 0), actual);
            }
        }
    }
    var plain_code = code;
    plain_code[4] = 0xf110_0108; // gather_l: x, y, lod
    plain_code[5] = 0x0040_0007;
    for (plain_code, 0..) |word, index| guest.word(0x200 + index * 4, word);
    try state.writeRegister(.shader, stage.programRegisterBase(), 2);
    for ([_][3]f32{ .{ 0, 0, 16 }, .{ 1, 0, 16 }, .{ 0, 1, 16 }, .{ 1, 0, 0 }, .{ 0, 0.25, 16 }, .{ 1, 0, 0.75 } }) |test_case| {
        userdata[9] = @as(u32, @intFromFloat(test_case[1] * 256)) | (@as(u32, @min(4095, @as(u32, @intFromFloat(test_case[2] * 256)))) << 12);
        userdata[19] = @bitCast(test_case[0]);
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(index)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        var output: [16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x6000, &output);
        const mip: usize = if (std.math.clamp(test_case[0], test_case[1], test_case[2]) < 0.5) 0 else 1;
        for ([_]usize{ 2, 3, 1, 0 }, 0..) |texel, index| {
            const actual: f32 = @bitCast(std.mem.readInt(u32, output[index * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(red[mip][texel])) / 255.0, actual, 0.00001);
        }
    }
    std.debug.print("gather LOD passed: four texel order, two mips, sampler/view LOD bounds, linear filtering and all eight comparisons\n", .{});
}

fn runWave64Probe(allocator: std.mem.Allocator) !void {
    for ([_][3]u32{ .{ 64, 1, 1 }, .{ 4, 4, 4 } }) |local_size| try runWave64Case(allocator, local_size);
    std.debug.print("wave64 passed: lane 63, full masks, carry bits and uniform EXEC branches across workgroup shapes\n", .{});
}

fn runWave64Case(allocator: std.mem.Allocator, local_size: [3]u32) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    for (0..128) |lane| guest.word(0x10000 + lane * 4, @intCast(100 + lane));
    const code = [_]u32{
        0xd765_0000, 193 | (128 << 9),
        0xd766_0000,     193 | (256 << 9), // flatten LocalInvocationId
        vop1(1, 7, 256),
        0xd746_0000, 8 | (134 << 9) | (256 << 18), // separate two guest waves' buffers
        0xe030_2000, 0x8000_0100,
        0xd760_0008,   257 | (191 << 9), // READLANE from guest lane 63
        vop1(1, 2, 8),
        0x7d88_0ea8, // V_CMP_GT_U32 40, v7
        vop1(1, 3, 106),
        vop1(1, 4, 107),
        vop1(1, 6, 129),
        0x020a_0c80,
        0xe078_2000,
        0x8001_0200,
        0x500c_0c80, // ADDC selects this lane's carry bit from the complete VCC
        0xe070_2014,
        0x8001_0600,
        0x7da6_0ea3, // CMPX: only guest lanes 35..63 remain
        0xbf88_0001, // wave-wide EXECZ must keep every invocation together
        vop1(2, 10, 257),
        sop1(4, 126, 193),
        vop1(1, 2, 10),
        0xe070_2010,
        0x8001_0200,
        0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    const stage = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, stage.programRegisterBase(), 1);
    try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, (8 << 1) | (1 << 7));
    for ([_]u32{ 0x10000, 4 << 16, 128, 0, 0x11000, 24 << 16, 128, 0 }, 0..) |word, i|
        try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(i)), word);
    _ = try renderer.dispatchRdna2State(&state, local_size, .{ 2, 1, 1 });
    var output: [3072]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x11000, &output);
    for (0..128) |lane| {
        const base: u32 = @intCast((lane / 64) * 64);
        const expected = [_]u32{ 163 + base, 0xffff_ffff, 0xff, @intFromBool(lane % 64 < 40), 135 + base, if (lane % 64 < 40) 2 else 1 };
        for (expected, 0..) |word, component| {
            const actual = std.mem.readInt(u32, output[lane * 24 + component * 4 ..][0..4], .little);
            if (actual != word) std.debug.print("wave64 lane={d} component={d}: expected={d} actual={d}\n", .{ lane, component, word, actual });
            try std.testing.expectEqual(word, actual);
        }
    }
}

fn runDppProbe(allocator: std.mem.Allocator) !void {
    const controls = [_]u16{ 0x103, 0x113, 0x123, 0x140, 0x141, 0x1b };
    for (0..20) |case| {
        const permute = case == 12 or case == 13 or case >= 16;
        const exchange = case == 13 or case >= 18;
        const inactive = case >= 14;
        const fetch_inactive = inactive and case & 1 != 0;
        const control = if (inactive) 0x1b else controls[case % controls.len];
        const bounded = case < controls.len;
        const row_mask: u32 = if (bounded or permute or inactive) 15 else 5;
        const bank_mask: u32 = if (bounded or permute or inactive) 15 else 5;
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        for (0..64) |lane| guest.word(0x10000 + lane * 4, @intCast(100 + lane));
        const code = [_]u32{
            0xe030_2000,                                                                                                                                                                                                 0x8000_0100, // load v1, indexed V#s0
            vop1(1, 2, 255),                                                                                                                                                                                             0xdead_beef,
            sop1(3, 8, 255),                                                                                                                                                                                             0x8765_4321,
            sop1(3, 9, 255),                                                                                                                                                                                             0x0fed_cba9,
            sop1(3, 10, 255),                                                                                                                                                                                            0xaaaa_aaaa,
            sop1(3, 11, 255),                                                                                                                                                                                            0xaaaa_aaaa,
            if (inactive) sop1(4, 126, 10) else 0xbf80_0000,                                                                                                                                                             if (permute) (if (exchange) @as(u32, 0xd778_0002) else 0xd777_0002) | (@as(u32, @intFromBool(fetch_inactive)) << 11) else vop1(1, 2, 250),
            if (permute) 257 | (8 << 9) | (9 << 18) else 1 | (@as(u32, control) << 8) | (@as(u32, @intFromBool(fetch_inactive)) << 18) | (@as(u32, @intFromBool(bounded)) << 19) | (bank_mask << 24) | (row_mask << 28),
            sop1(4, 126, 193), // restore every lane before reading results
            0xe070_2000,
            0x8001_0200,
            0xbf81_0000,
        };
        for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
        var state = gpu.State{};
        const stage = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, stage.programRegisterBase(), 1);
        try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, 8 << 1);
        for ([_]u32{ 0x10000, 4 << 16, 64, 0, 0x11000, 4 << 16, 64, 0 }, 0..) |word, i|
            try state.writeRegister(.shader, stage.userDataBase() + @as(u32, @intCast(i)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        var output: [256]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x11000, &output);
        for (0..64) |lane| {
            const row: usize = lane & ~@as(usize, 15);
            const column = lane & 15;
            var source: ?usize = if (permute)
                (if (exchange) row ^ 16 else row) + ((column + 1) & 15)
            else switch (control) {
                0x103 => if (column < 13) lane + 3 else null,
                0x113 => if (column >= 3) lane - 3 else null,
                0x123 => row + ((column + 13) & 15),
                0x140 => row + (15 - column),
                0x141 => lane ^ 7,
                0x1b => (lane & ~@as(usize, 3)) + (3 - (lane & 3)),
                else => unreachable,
            };
            const enabled = (!inactive or lane & 1 != 0) and (row_mask >> @as(u5, @intCast(lane / 16))) & 1 != 0 and
                (bank_mask >> @as(u5, @intCast(column / 4))) & 1 != 0;
            if (!enabled) source = null;
            const expected: u32 = if (source) |index|
                (if (inactive and !fetch_inactive and index & 1 == 0) 0 else @intCast(100 + index))
            else if (bounded and enabled) 0 else 0xdead_beef;
            const actual = std.mem.readInt(u32, output[lane * 4 ..][0..4], .little);
            if (actual != expected) std.debug.print("DPP case={d} lane={d}: expected=0x{x} actual=0x{x}\n", .{ case, lane, expected, actual });
            try std.testing.expectEqual(expected, actual);
        }
    }
    std.debug.print("DPP passed: row shifts, rotation, swizzles, masks and both permutation selectors across 64 lanes\n", .{});
}

fn runSceneMaskProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const inputs = [_][2]u32{
        .{ 0, 0 },           .{ 0, 1 },           .{ 1, 0 },           .{ 0xabcd_0001, 0 },
        .{ 0x1234_ffff, 0 }, .{ 0x8000_0000, 0 }, .{ 0xffff_8000, 0 }, .{ 0xabcd_0000, 1 },
    };
    for (0..64) |lane| {
        guest.word(0x10000 + lane * 8, inputs[lane % inputs.len][0]);
        guest.word(0x10004 + lane * 8, inputs[lane % inputs.len][1]);
    }
    @memset(guest.bytes[0x11000..0x11400], 0xcc);
    const code = [_]u32{
        0xe034_2000, 0x8000_0200, // load v2:v3, indexed V#s0
        0x7dc4_0480, // v_cmp_eq_u64 0, v2:v3
        vop1(1, 5, 129),
        0x0208_0a80, // v_cndmask_b32 v4, 0, v5
        0xe070_2000,
        0x8001_0400,
        0x7d3d_00f9, 0x8606_0002, // v_cmpx_ge_i16 v2, 0 (SDWA)
        0xe06c_2007, 0x8001_0200, // high half of v2, crossing a dword at byte 7
        0xbefe_04c1, // restore EXEC
        vop1(1, 5, 106),
        0xe070_200c, 0x8001_0500, // CMPX must preserve the equality result in VCC
        0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    for ([_]u32{ 0x10000, 8 << 16, 64, 0, 0x11000, 16 << 16, 64, 0 }, 0..) |word, i|
        try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(i)), word);
    const report = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
    try std.testing.expect(report.spirv_words != 0);
    var output: [1024]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x11000, &output);
    for (0..64) |lane| {
        const input = inputs[lane % inputs.len];
        const equal = input[0] == 0 and input[1] == 0;
        var expected: [16]u8 = @splat(0xcc);
        std.mem.writeInt(u32, expected[0..4], @intFromBool(equal), .little);
        if (input[0] & 0x8000 == 0) std.mem.writeInt(u16, expected[7..9], @truncate(input[0] >> 16), .little);
        std.mem.writeInt(u32, expected[12..16], if (equal) 0xffff_ffff else 0, .little);
        try std.testing.expectEqualSlices(u8, &expected, output[lane * 16 ..][0..16]);
    }
    std.debug.print("scene masks passed: u64 equality, signed i16 CMPX, preserved VCC and masked high-half stores across 64 lanes\n", .{});
}

fn runStorageImageReuseProbe(allocator: std.mem.Allocator) !void {
    for ([_]usize{ 160, 320 }) |count| try runStorageImageReuseCase(allocator, count);
    std.debug.print("storage image reuse passed: 160 resident views and 320 queued writes under cache pressure\n", .{});
}

fn runStorageImageReuseCase(allocator: std.mem.Allocator, count: usize) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 128), vop1(1, 1, 128), vop1(1, 2, 16),
        0xf020_0108, 0x0000_0200, // image_store red v2 at v0/v1, T#s0
        0xf020_0108, 0x0002_0200, // image_store red v2 at v0/v1, T#s8
        0xbf81_0000,
    };
    for (code, 0..) |word, i| guest.word(0x100 + i * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 17 << 1);
    // Two images per dispatch exhaust the image cache before the command pool
    // can flush the batch on its own.
    for (0..count / 2) |pair| {
        for (0..2) |member| {
            const descriptor = imageDescriptorWords(@intCast(0x4000 + (pair * 2 + member) * 256), 1, 1);
            for (descriptor, 0..) |word, component| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(member * 8 + component)), word);
        }
        try state.writeRegister(.shader, compute.userDataBase() + 16, @intCast(42 + pair));
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    }
    // Earlier dirty views must remain on the GPU until a CPU consumer asks.
    try std.testing.expectEqual(@min(@as(usize, 256), count), renderer.storage_image_cache.items.len);
    if (count == 160) try std.testing.expect(std.mem.allEqual(u8, guest.bytes[0x4000..0xe000], 0));
    var pixel: [4]u8 = undefined;
    // Check every dispatch, including views evicted while later commands were
    // still being prepared. A capacity fallback must not silently drop writes.
    for (0..count) |i| {
        try std.testing.expect(backend.vtable.read(backend.context, 0x4000 + i * 256, &pixel));
        try std.testing.expectEqualSlices(u8, &.{ @intCast(42 + i / 2), 0, 0, 0 }, &pixel);
    }
    for (renderer.storage_image_cache.items) |cached| try std.testing.expectEqual(@as(usize, 0), cached.pin_count);
}

fn runResidentTargetReuseProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    const vertex = [_]u32{
        vop1(6, 1, 261), vop1(1, 2, 255),  0x3f80_0000,      vop2(4, 3, 1, 2),
        vop1(1, 4, 255), 0x3f40_0000,      vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
        vop1(1, 7, 255), 0xbfc0_0000,      vop2(8, 6, 6, 7), vop1(1, 8, 255),
        0x3f40_0000,     vop2(3, 6, 6, 8), vop1(1, 7, 128),  vop1(1, 8, 242),
        0xf800_08cf,     0x0807_0605,      0xbf81_0000,
    };
    const fragment = [_]u32{
        vop1(1, 0, 242), vop1(1, 1, 128), vop1(1, 2, 128), vop1(1, 3, 242),
        0xf800_080f,     0x0302_0100,     0xbf81_0000,
    };
    const sample = [_]u32{
        vop1(1, 4, 240), vop1(1, 5, 240), // sample the center of the old target
        0xf080_0f08, 0x0061_0004, // image_sample v0:v3, v4:v5, s4:s11, s12:s15
        0xf800_080f, 0x0302_0100,
        0xbf81_0000,
    };
    for (vertex, 0..) |word, i| guest.word(0x700 + i * 4, word);
    for (fragment, 0..) |word, i| guest.word(0x900 + i * 4, word);
    for (sample, 0..) |word, i| guest.word(0xa00 + i * 4, word);
    var state = gpu.State{};
    const pixel = gpu.resources.ShaderStage.pixel;
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase(), 7);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, pixel.programRegisterBase(), 9);
    try state.writeRegister(.shader, pixel.programRegisterBase() + 1, 0);
    const context = [_][2]u32{
        .{ 0x319, 0 }, .{ 0x31b, 0 },             .{ 0x31c, 10 << 2 },                 .{ 0x31d, 0 },
        .{ 0x390, 0 }, .{ 0x3b0, (7 << 14) | 7 }, .{ 0x3b8, 1 << 24 },                 .{ 0x08e, 0xf },
        .{ 0x00c, 0 }, .{ 0x00d, 8 | (8 << 16) }, .{ 0x094, 1 << 31 },                 .{ 0x095, 8 | (8 << 16) },
        .{ 0x1e0, 0 }, .{ 0x200, 0 },             .{ 0x202, (0xcc << 16) | (1 << 4) }, .{ 0x204, 0 },
        .{ 0x205, 0 },
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 4, 4, 4, 4, 1, 0 }, 0..) |value, i|
        try state.writeRegister(.context, 0x10f + @as(u32, @intCast(i)), @bitCast(value));
    const stream = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 0 };
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    // Fill the cache with independent attachments. The source becomes its oldest
    // entry, then the next draw samples it while allocating a new destination.
    for (0..64) |i| {
        try state.writeRegister(.context, 0x318, @intCast((0x2000 + i * 0x400) >> 8));
        _ = try executor.execute(&stream);
        if (renderer.last_draw_error) |err| return err;
    }
    try renderer.flushPendingGuestWrites();
    try std.testing.expectEqual(@as(usize, 64), renderer.render_targets.items.len);
    const original = renderer.render_targets.items[0].image.handle;
    const descriptors = [_]u32{ 0x20, (56 << 20) | (3 << 30), 1 | (7 << 14), 0x9000_0fac, 0, 0, 0, 0, 0, 0, 0, 0 };
    for (descriptors, 0..) |word, i|
        try state.writeRegister(.shader, pixel.userDataBase() + 4 + @as(u32, @intCast(i)), word);
    try state.writeRegister(.shader, pixel.programRegisterBase() + 3, 16 << 1);
    try state.writeRegister(.shader, pixel.programRegisterBase(), 0xa);
    for (64..68) |i| {
        const destination = 0x2000 + i * 0x400;
        try state.writeRegister(.context, 0x318, @intCast(destination >> 8));
        _ = try executor.execute(&stream);
        if (renderer.last_draw_error) |err| return err;
        var retained = false;
        for (renderer.render_targets.items) |target| {
            if (target.image.handle == original) retained = true;
            try std.testing.expectEqual(@as(usize, 0), target.pin_count);
        }
        try std.testing.expect(retained);
        try renderer.flushPendingGuestWrites();
        const center = destination + (4 * 8 + 4) * 4;
        try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, guest.bytes[center..][0..4]);
    }
    std.debug.print("resident target reuse passed: full cache, sampled source, GPU readback, released pins\n", .{});
}

fn runQueuedBufferReuseProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        0xe030_0000, 0x8002_0000, // buffer_load_dword v0, s8:s11
        0xe070_0000, 0x8003_0000, // buffer_store_dword v0, s12:s15
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 16);
    defer analysis.deinit(allocator);
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .local_size = .{ 1, 1, 1 },
        .storage_buffers = &.{
            .{ .resource_sgpr = 8, .descriptor_index = 0, .extent_bytes = 16 },
            .{ .resource_sgpr = 12, .descriptor_index = 1, .extent_bytes = 16 },
        },
    });
    defer module.deinit(allocator);
    for ([_]bool{ false, true }) |recycle| {
        const source = 0x1000;
        const destination = 0x1100;
        const replacement: usize = if (recycle) 0x1200 else source;
        guest.word(source, 0x1122_3344);
        guest.word(destination, 0);
        _ = try renderer.stageGuestStorageBufferAt(0, source, 16);
        _ = try renderer.stageGuestStorageBufferAt(1, destination, 16);
        // Keep the read queued, making early CPU overwrites deterministic.
        renderer.draw_batch_active = true;
        _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
        guest.word(replacement, 0xaabb_ccdd);
        _ = try renderer.stageGuestStorageBufferAt(0, replacement, 16);
        var result: [16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(destination, &result);
        renderer.draw_batch_active = false;
        const actual = std.mem.readInt(u32, result[0..4], .little);
        if (actual != 0x1122_3344) {
            std.debug.print("queued buffer read mismatch (recycle={any}): 0x{x}\n", .{ recycle, actual });
            return error.QueuedBufferInputOverwritten;
        }
    }
    // A cache hit can move an allocation to another descriptor slot. Rebinding
    // its former slot must not overwrite the input still bound at the new one.
    guest.word(0x1500, 0x1234_5678);
    guest.word(0x1600, 0xdead_beef);
    _ = try renderer.stageGuestStorageBufferAt(1, 0x1500, 16);
    _ = try renderer.stageGuestStorageBufferAt(0, 0x1500, 16);
    _ = try renderer.stageGuestStorageBufferAt(1, 0x1600, 16);
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    var rebound_result: [16]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x1600, &rebound_result);
    const rebound_value = std.mem.readInt(u32, rebound_result[0..4], .little);
    if (rebound_value != 0x1234_5678) {
        std.debug.print("descriptor migration lost its input: 0x{x}\n", .{rebound_value});
        return error.ReboundBufferInputOverwritten;
    }
    // Exhaust the allocation cache, then grow the destination. Neither the
    // old slot preference nor the LRU fallback may evict another live input.
    for (2..vulkan.backend.maximum_storage_descriptors) |slot| {
        const address = 0x4000 + slot * 16;
        guest.word(address, @intCast(slot));
        _ = try renderer.stageGuestStorageBufferAt(@intCast(slot), address, 16);
    }
    _ = try renderer.stageGuestStorageBufferAt(1, 0x1700, 64);
    _ = try renderer.dispatchSpirv(module.words, .{ 1, 1, 1 });
    var grown_result: [64]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x1700, &grown_result);
    if (std.mem.readInt(u32, grown_result[0..4], .little) != 0x1234_5678) {
        return error.LiveBufferEvicted;
    }
    for (2..vulkan.backend.maximum_storage_descriptors) |slot| {
        try renderer.readbackGuestStorageBuffer(0x4000 + slot * 16, &rebound_result);
        if (std.mem.readInt(u32, rebound_result[0..4], .little) != slot) return error.LiveBufferEvicted;
    }
    // Reusing a large allocation for a shorter guest range must also shrink
    // the descriptor range used by the shader's dynamic bounds checks.
    guest.word(0x1800 + 16, 0xdead_beef);
    _ = try renderer.stageGuestStorageBufferAt(0, 0x1800, 64);
    _ = try renderer.stageGuestStorageBufferAt(0, 0x1800, 16);
    guest.word(0x100, 0xe030_0010); // load one dword beyond the new range
    var bounds_analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, 16);
    defer bounds_analysis.deinit(allocator);
    var bounds_module = try bounds_analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .local_size = .{ 1, 1, 1 },
        .storage_buffers = &.{
            .{ .resource_sgpr = 8, .descriptor_index = 0, .extent_bytes = 16 },
            .{ .resource_sgpr = 12, .descriptor_index = 1, .extent_bytes = 64 },
        },
    });
    defer bounds_module.deinit(allocator);
    _ = try renderer.dispatchSpirv(bounds_module.words, .{ 1, 1, 1 });
    try renderer.readbackGuestStorageBuffer(0x1700, &grown_result);
    if (std.mem.readInt(u32, grown_result[0..4], .little) != 0) return error.RecycledBufferBoundsMismatch;
    std.debug.print("queued compute buffer reuse passed: exact range, recycling, descriptor migration, full cache, bounds\n", .{});

    // Scene kernels can exceed the old 4096-instruction headerless limit.
    // Drive the normal shader-analysis path and verify the work after it.
    const large_program = 0x8000;
    const large_source = 0x10000;
    const large_destination = 0x11000;
    for (0..4200) |index| guest.word(large_program + index * 4, 0xbf80_0000); // s_nop
    for (code, 0..) |word, index| guest.word(large_program + (4200 + index) * 4, word);
    guest.word(large_source, 0x1357_2468);
    guest.word(large_destination, 0);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), large_program >> 8);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    for ([_]u32{ 0x207, 0x208, 0x209 }) |reg| try state.writeRegister(.shader, reg, 1);
    const descriptors = [_]u32{ large_source, 4 << 16, 4, 0, large_destination, 4 << 16, 4, 0 };
    for (descriptors, 0..) |word, index| {
        try state.writeRegister(.shader, compute.userDataBase() + 8 + @as(u32, @intCast(index)), word);
    }
    const stream = [_]u32{ command(gpu.pm4.dispatch_direct, 4), 1, 1, 1, 0x41 };
    var executor = gpu.DcbExecutor{ .state = &state, .backend = renderer.dcbBackend(guest.interface()), .allocator = allocator };
    _ = try executor.execute(&stream);
    try renderer.readbackGuestStorageBuffer(large_destination, &rebound_result);
    if (std.mem.readInt(u32, rebound_result[0..4], .little) != 0x1357_2468) return error.LargeComputeShaderMismatch;
    std.debug.print("large headerless compute shader passed: 4203 instructions\n", .{});
}

fn runGdsAtomicProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        0xbefc_0300, // s_mov_b32 m0, s0 (base / size)
        vop1(1, 1, 1), // increment from s1
        vop1(1, 2, 4), // relative address from s4
        0xbefe_0402, // EXEC = s2:s3
        0xd802_0004, 0x0000_0102, // ds_add_u32 v2, v1 offset:4 gds
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 5 << 1);
    const cases = [_]struct { m0: u32 = 0x0100_000c, value: u32, mask: u64, address: u32 = 4, expected: u32 }{
        .{ .value = 2, .mask = 1, .expected = 6 },
        .{ .value = 3, .mask = @as(u64, 1) << 40, .expected = 15 },
        .{ .value = 99, .mask = 0, .expected = 15 },
        .{ .value = 99, .mask = 1, .address = 8, .expected = 15 }, // segment overflow
        .{ .value = 99, .mask = 1, .address = 0xffff_fffc, .expected = 15 }, // wrapping offset
        .{ .m0 = 0xfffc_0008, .value = 99, .mask = 1, .address = 0, .expected = 15 }, // physical overflow
        .{ .m0 = 0x0100_0000, .value = 99, .mask = 1, .expected = 15 }, // empty segment
    };
    for (cases) |case| {
        for ([_]u32{ case.m0, case.value, @truncate(case.mask), @truncate(case.mask >> 32), case.address }, 0..) |word, index| {
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        }
        const report = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 3, 1, 1 });
        try std.testing.expect(report.spirv_words != 0);
        for (0..renderer.gds_storage.items.len / 4) |index| {
            const expected: u32 = if (index == 0x108 / 4) case.expected else 0;
            try std.testing.expectEqual(expected, std.mem.readInt(u32, renderer.gds_storage.items[index * 4 ..][0..4], .little));
        }
    }
    const return_code = [_]u32{
        0xbefc_0300, vop1(1, 1, 1), vop1(1, 2, 4),
        0xd882_0004, 0x0300_0102, // ds_add_rtn_u32 v3, v2, v1 offset:4 gds
        0xe070_0000, 0x8002_0300, // buffer_store_dword v3, V#s8
        0xbf81_0000,
    };
    for (return_code, 0..) |word, index| guest.word(0x200 + index * 4, word);
    try state.writeRegister(.shader, compute.programRegisterBase(), 2);
    try state.writeRegister(.shader, 0x213, 12 << 1);
    for ([_]u32{ 0x0100_000c, 2, 0, 0, 4, 0, 0, 0, 0x18000, 4 << 16, 1, 0 }, 0..) |word, index| {
        try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    }
    const returned = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    try std.testing.expect(returned.spirv_words != 0);
    var previous: [4]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x18000, &previous);
    try std.testing.expectEqual(@as(u32, 15), std.mem.readInt(u32, &previous, .little));
    try std.testing.expectEqual(@as(u32, 17), std.mem.readInt(u32, renderer.gds_storage.items[0x108..][0..4], .little));
    const prefix_code = [_]u32{
        0xbefc_0300,
        0xd766_0003, 0x0001_0002, // mbcnt high(s2, 0)
        0xd765_0003, 0x0002_0601, // mbcnt low(s1, v3)
        0xe070_2000, 0x8001_0300, // save per-lane prefix
        0xbefe_0401, // EXEC = mask s1:s2
        0x7da4_0680, // CMPX EQ 0, v3 selects first active lane
        0xbe83_1001, // s_bcnt1_i32_b64 s3, s1:s2
        vop1(1, 4, 3),
        vop1(1, 5, 128),
        0xd802_0000,
        0x0000_0405,
        0xbf81_0000,
    };
    for (prefix_code, 0..) |word, index| guest.word(0x300 + index * 4, word);
    try state.writeRegister(.shader, compute.programRegisterBase(), 3);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    var prefix_total: u32 = 0;
    for ([_]u64{ 0xffff_ffff_ffff_ffff, 0xaaaa_aaaa_5555_5555, 0x8000_0000_0000_0000 }, 0..) |mask, case_index| {
        const destination: u32 = 0x19000 + @as(u32, @intCast(case_index)) * 0x1000;
        for ([_]u32{ 0x0120_0004, @truncate(mask), @truncate(mask >> 32), 0, destination, 4 << 16, 64, 0 }, 0..) |word, index| {
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        }
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        var prefixes: [256]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(destination, &prefixes);
        for (0..64) |lane| {
            const before = (@as(u64, 1) << @intCast(lane)) - 1;
            try std.testing.expectEqual(@as(u32, @popCount(mask & before)), std.mem.readInt(u32, prefixes[lane * 4 ..][0..4], .little));
        }
        prefix_total += @popCount(mask);
        try std.testing.expectEqual(prefix_total, std.mem.readInt(u32, renderer.gds_storage.items[0x120..][0..4], .little));
    }
    std.debug.print("GDS atomic passed: persistent counter, cross-workgroup updates, EXEC low/high, segment and physical bounds, returned value\n", .{});
}

fn runPackedBufferProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    guest.word(0x10000, 0x01ff_807f);
    guest.word(0x10004, 0x0000_0080);
    var code: std.ArrayList(u32) = .empty;
    defer code.deinit(allocator);
    for (0..6) |index| {
        try code.appendSlice(allocator, &.{
            vop1(1, 1, 255),                                                                            0xa5a5_1234,
            0xe000_0000 | (@as(u32, @intCast(0x20 + index)) << 18) | @as(u32, if (index < 4) 1 else 3),
            0x8000_0100, // D16 load from V#s0 to v1
            0xe070_0000 | @as(u32, @intCast(index * 4)), 0x8001_0100, // result to V#s4
        });
    }
    // An out-of-bounds half load zeros only the selected half.
    try code.appendSlice(allocator, &.{ vop1(1, 1, 255), 0xa5a5_1234, 0xe084_0010, 0x8000_0100, 0xe070_0018, 0x8001_0100, 0xbf81_0000 });
    for (code.items, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 8 << 1);
    for ([_]u32{ 0x10000, 0, 8, 0, 0x11000, 0, 256, 0 }, 0..) |word, index| {
        try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    }
    _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    var output: [256]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x11000, &output);
    const expected = [_]u32{ 0xa5a5_0080, 0x0080_1234, 0xa5a5_ff80, 0xff80_1234, 0xa5a5_8001, 0x8001_1234, 0x0000_1234 };
    for (expected, 0..) |value, index| try std.testing.expectEqual(value, std.mem.readInt(u32, output[index * 4 ..][0..4], .little));

    // CMPX compares only the low half, preserves VCC, and disables matching
    // lanes in both halves of a wave. A disabled lane retains its sentinel.
    const compare_code = [_]u32{
        vop1(1, 1, 255), 0xa5a5_1234,
        0x3606_009f, // v_and_b32 v3, 31, v0
        0x3806_06ff, 0x1234_0000, // v_or_b32 v3, high-half sentinel, v3
        0xbeea_04c1, // VCC = all ones
        0xbefe_04c1, // EXEC = all ones
        0x7d7a_0680, // v_cmpx_ne_u16 0, v3
        0xe070_2000, 0x8001_0100, // indexed store v1
        0xbefe_04c1, // restore EXEC
        vop1(1, 2, 106),
        0xe070_2100, 0x8001_0200, // indexed VCC sentinel in second half
        0xbf81_0000,
    };
    for (compare_code, 0..) |word, index| guest.word(0x300 + index * 4, word);
    // A second output avoids stale CPU data in the resident first buffer.
    for (0..128) |index| guest.word(0x12000 + index * 4, 0x1234_5678);
    try state.writeRegister(.shader, compute.programRegisterBase(), 3);
    try state.writeRegister(.shader, compute.userDataBase() + 4, 0x12000);
    try state.writeRegister(.shader, compute.userDataBase() + 5, 4 << 16);
    try state.writeRegister(.shader, compute.userDataBase() + 6, 128);
    _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
    var compared: [512]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x12000, &compared);
    for (0..64) |lane| {
        try std.testing.expectEqual(@as(u32, if (lane % 32 == 0) 0x1234_5678 else 0xa5a5_1234), std.mem.readInt(u32, compared[lane * 4 ..][0..4], .little));
        try std.testing.expectEqual(@as(u32, 0xffff_ffff), std.mem.readInt(u32, compared[256 + lane * 4 ..][0..4], .little));
    }
    const format_code = [_]u32{
        0xe20c_0000, 0x8000_0400, // format D16 xyzw -> v4:v5
        0xe074_0000, 0x8001_0400,
        0xe208_0000, 0x8000_0400, // xyz -> v4:v5
        0xe074_0008, 0x8001_0400,
        0xe204_0000, 0x8000_0400, // xy -> v4
        0xe070_0010, 0x8001_0400,
        0xe200_0000, 0x8000_0400, // x -> v4
        0xe070_0014, 0x8001_0400,
        0xbf81_0000,
    };
    for (format_code, 0..) |word, index| guest.word(0x500 + index * 4, word);
    guest.word(0x14000, 0xff00_ff00);
    try state.writeRegister(.shader, compute.programRegisterBase(), 5);
    const formats = [_]struct { format: u32, pair: u32 }{
        .{ .format = 56, .pair = 0x3c00_0000 }, // UNORM -> half floats
        .{ .format = 60, .pair = 0x00ff_0000 }, // UINT -> unsigned halfwords
        .{ .format = 61, .pair = 0xffff_0000 }, // SINT -> signed halfwords
    };
    for (formats, 0..) |case, case_index| {
        const destination: u32 = 0x15000 + @as(u32, @intCast(case_index)) * 0x1000;
        for ([_]u32{ 0x14000, 0, 4, (case.format << 12) | 4 | (5 << 3) | (6 << 6) | (7 << 9), destination, 0, 256, 0 }, 0..) |word, index| {
            try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        }
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        try renderer.readbackGuestStorageBuffer(destination, &output);
        for ([_]u32{ case.pair, case.pair, case.pair, 0, case.pair, 0 }, 0..) |value, index| {
            try std.testing.expectEqual(value, std.mem.readInt(u32, output[index * 4 ..][0..4], .little));
        }
    }
    const store_formats = [_]struct { format: u32, count: u32, width: u32 }{
        .{ .format = 13, .count = 1, .width = 2 },
        .{ .format = 29, .count = 2, .width = 2 },
        .{ .format = 74, .count = 3, .width = 4 },
        .{ .format = 71, .count = 4, .width = 2 },
        .{ .format = 77, .count = 4, .width = 4 },
    };
    for (store_formats, 0..) |case, case_index| {
        const program: u32 = 7 + @as(u32, @intCast(case_index));
        const destination: u32 = 0x18000 + @as(u32, @intCast(case_index)) * 0x1000;
        const stride = case.count * case.width;
        const store_code = [_]u32{
            vop1(1, 1, 255), 0xc000_3c00,
            vop1(1, 2, 255), 0x8000_3800,
            0x3606_009f,                               0x7d7a_0680, // disable lanes 0 and 32
            0xe200_2000 | ((0x83 + case.count) << 18), 0x8001_0100,
            0xbefe_04c1, // restore EXEC; an OOB store must preserve word zero
            vop1(1, 0, 192), // index 64
            0xe200_2000 | ((0x83 + case.count) << 18),
            0x8001_0100,
            0xbf81_0000,
        };
        for (store_code, 0..) |word, index| guest.word(program * 256 + index * 4, word);
        for (0..stride * 16) |index| guest.word(destination + index * 4, 0x1234_5678);
        try state.writeRegister(.shader, compute.programRegisterBase(), program);
        for ([_]u32{ destination, stride << 16, 64, (case.format << 12) | 4 | (5 << 3) | (6 << 6) | (7 << 9) }, 0..) |word, index| {
            try state.writeRegister(.shader, compute.userDataBase() + 4 + @as(u32, @intCast(index)), word);
        }
        _ = try renderer.dispatchRdna2State(&state, .{ 64, 1, 1 }, .{ 1, 1, 1 });
        var stored: [1024]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(destination, stored[0 .. stride * 64]);
        const half_values = [_]u16{ 0x3c00, 0xc000, 0x3800, 0x8000 };
        const float_values = [_]u32{ 0x3f80_0000, 0xc000_0000, 0x3f00_0000, 0x8000_0000 };
        for (0..64) |lane| {
            for (0..case.count) |component| {
                const offset = lane * stride + component * case.width;
                if (case.width == 2) {
                    const expected_half: u16 = if (lane % 32 == 0) (if (offset % 4 == 0) 0x5678 else 0x1234) else half_values[component];
                    try std.testing.expectEqual(expected_half, std.mem.readInt(u16, stored[offset..][0..2], .little));
                } else {
                    try std.testing.expectEqual(if (lane % 32 == 0) @as(u32, 0x1234_5678) else float_values[component], std.mem.readInt(u32, stored[offset..][0..4], .little));
                }
            }
        }
    }
    const class_code = [_]u32{
        0xe030_2000,     0x8000_1500,
        vop1(1, 1, 255), 0xa5a5_1234,
        0xbeea_04c1,     0xbefe_04c1,
        0x7d31_70f9, 0x8636_0015, // actual scene CMPX CLASS -abs(v21), negative finite/zero
        0xe070_2000, 0x8001_0100,
        0xbefe_04c1, vop1(1, 2, 106),
        0xe070_2040, 0x8001_0200,
        0xbf81_0000,
    };
    for (class_code, 0..) |word, index| guest.word(0xd00 + index * 4, word);
    const class_values = [_]u32{ 0, 0x8000_0000, 1, 0x8000_0001, 0x3f80_0000, 0xbf80_0000, 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0x7f80_0001 };
    for (class_values, 0..) |word, index| guest.word(0x1d000 + index * 4, word);
    for (0..32) |index| guest.word(0x1e000 + index * 4, 0x1234_5678);
    for ([_]u32{ 0x1d000, 4 << 16, class_values.len, 0, 0x1e000, 4 << 16, 32, 0 }, 0..) |word, index| {
        try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    }
    try state.writeRegister(.shader, compute.programRegisterBase(), 13);
    _ = try renderer.dispatchRdna2State(&state, .{ class_values.len, 1, 1 }, .{ 1, 1, 1 });
    var classified: [128]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x1e000, &classified);
    for (0..class_values.len) |lane| {
        try std.testing.expectEqual(@as(u32, if (lane < 6) 0xa5a5_1234 else 0x1234_5678), std.mem.readInt(u32, classified[lane * 4 ..][0..4], .little));
        try std.testing.expectEqual(@as(u32, 0xffff_ffff), std.mem.readInt(u32, classified[64 + lane * 4 ..][0..4], .little));
    }
    std.debug.print("packed buffer probe passed: D16 loads/stores, adjacent halfwords, bounds, half/float packing, CMPX U16 and CLASS F32\n", .{});
}

fn runIntegerColorProbe(allocator: std.mem.Allocator) !void {
    for (0..4) |case_index| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        var guest = GuestMemory{};
        const backend = renderer.dcbBackend(guest.interface());
        const vertex = [_]u32{
            vop1(6, 1, 261), vop1(1, 2, 255),  0x3f80_0000,      vop2(4, 3, 1, 2),
            vop1(1, 4, 255), 0x3f40_0000,      vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
            vop1(1, 7, 255), 0xbfc0_0000,      vop2(8, 6, 6, 7), vop1(1, 8, 255),
            0x3f40_0000,     vop2(3, 6, 6, 8), vop1(1, 7, 128),  vop1(1, 8, 242),
            0xf800_08cf,     0x0807_0605,      0xbf81_0000,
        };
        for (vertex, 0..) |word, index| guest.word(0x700 + index * 4, word);
        const signed = case_index % 2 != 0;
        const compressed = case_index >= 2;
        const raw: u32 = if (compressed) (if (signed) 0x1234_ff85 else 0x1234_fedc) else if (signed) @bitCast(@as(i32, -1234567)) else 0xff81_2345;
        const expected: u32 = if (compressed) (if (signed) @bitCast(@as(i32, -123)) else 0xfedc) else raw;
        const fragment = [_]u32{
            vop1(1, 0, 242), vop1(1, 1, 128), vop1(1, 2, 128), vop1(1, 3, 242),
            0xf800_000f,                                  0x0302_0100, // float MRT0 remains a different numeric type
            vop1(1, 4, 255),                              raw,
            if (compressed) 0xf800_0c13 else 0xf800_0811, 0x0404_0404,
            0xbf81_0000,
        };
        for (fragment, 0..) |word, index| guest.word(0x900 + index * 4, word);
        var state = gpu.State{};
        for ([_]gpu.resources.ShaderStage{ .vertex, .pixel }, [_]u32{ 7, 9 }) |stage, address| {
            try state.writeRegister(.shader, stage.programRegisterBase(), address);
            try state.writeRegister(.shader, stage.programRegisterBase() + 1, 0);
        }
        for (0..2) |slot| {
            const base: u32 = @intCast(0x318 + slot * 15);
            try state.writeRegister(.context, base, if (slot == 0) 0x20 else 0x80);
            try state.writeRegister(.context, base + 1, 7);
            try state.writeRegister(.context, base + 3, 0);
            try state.writeRegister(.context, base + 4, if (slot == 0) 10 << 2 else (4 << 2) | (@as(u32, if (signed) 5 else 4) << 8));
            try state.writeRegister(.context, base + 5, 0);
            try state.writeRegister(.context, 0x390 + @as(u32, @intCast(slot)), 0);
            try state.writeRegister(.context, 0x3b0 + @as(u32, @intCast(slot)), (63 << 14) | 63);
            try state.writeRegister(.context, 0x3b8 + @as(u32, @intCast(slot)), 1 << 24);
        }
        const context = [_][2]u32{
            .{ 0x08e, 0x1f },            .{ 0x00c, 0 }, .{ 0x00d, 64 | (64 << 16) }, .{ 0x094, 1 << 31 },
            .{ 0x095, 64 | (64 << 16) }, .{ 0x1e0, 0 }, .{ 0x200, 0 },               .{ 0x202, (0xcc << 16) | (1 << 4) },
            .{ 0x204, 0 },               .{ 0x205, 0 },
        };
        for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
        for ([_]f32{ 32, 32, 32, 32, 1, 0 }, 0..) |value, index| try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
        var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
        _ = try executor.execute(&.{ command(gpu.pm4.draw_index_auto, 2), 3, 0 });
        try renderer.flushPendingGuestWrites();
        const center = (32 * 64 + 32) * 4;
        try std.testing.expectEqual(expected, std.mem.readInt(u32, guest.bytes[0x8000 + center ..][0..4], .little));
        try std.testing.expectEqual(@as(u32, 0xff00_00ff), std.mem.readInt(u32, guest.bytes[0x2000 + center ..][0..4], .little));
    }
    std.debug.print("integer color exports passed: mixed float/integer MRTs, full 32-bit payloads and signed/unsigned packed halfwords\n", .{});
}

fn runShaderInterfaceProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    const vertex = [_]u32{
        (0x3e << 25) | (0xc2 << 17) | (5 << 9) | 128, // compare VertexIndex with zero
        0xbf86_0001,      vop1(1, 5, 128), // one branch rewrites the ABI VGPR before its Phi
        vop1(6, 1, 261),  vop1(1, 2, 255),
        0x3f80_0000,      vop2(4, 3, 1, 2),
        vop1(1, 4, 255),  0x3f40_0000,
        vop2(8, 5, 3, 4), vop2(8, 6, 3, 3),
        vop1(1, 7, 255),  0xbfc0_0000,
        vop2(8, 6, 6, 7), vop1(1, 8, 255),
        0x3f40_0000,      vop2(3, 6, 6, 8),
        vop1(1, 7, 128),  vop1(1, 8, 242),
        vop1(1, 10, 240), vop2(8, 9, 1, 10), // PARAM1 = VertexIndex * .5
        0xf800_021f, 0x0807_0a09, // PARAM1 = { VertexIndex * .5, .5, 0, 1 }
        0xf800_08cf, 0x0807_0605,
        0xbf81_0000,
    };
    for (vertex, 0..) |word, index| guest.word(0x700 + index * 4, word);
    var state = gpu.State{};
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase(), 7);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase() + 1, 0);
    const context = [_][2]u32{
        .{ 0x318, 0x20 },            .{ 0x319, 7 }, .{ 0x31b, 0 },               .{ 0x31c, 10 << 2 },
        .{ 0x31d, 0 },               .{ 0x390, 0 }, .{ 0x3b0, (63 << 14) | 63 }, .{ 0x3b8, 1 << 24 },
        .{ 0x08e, 0xf },             .{ 0x00c, 0 }, .{ 0x00d, 64 | (64 << 16) }, .{ 0x094, 1 << 31 },
        .{ 0x095, 64 | (64 << 16) }, .{ 0x1e0, 0 }, .{ 0x200, 0 },               .{ 0x202, (0xcc << 16) | (1 << 4) },
        .{ 0x204, 0 },               .{ 0x205, 0 },
        .{ 0x191, 1 }, .{ 0x192, 0x401 }, // smooth ATTR0 and flat ATTR1 both use PARAM1
    };
    for (context) |entry| try state.writeRegister(.context, entry[0], entry[1]);
    for ([_]f32{ 32, 32, 32, 32, 1, 0 }, 0..) |value, index|
        try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
    const stream = [_]u32{ command(gpu.pm4.draw_index_auto, 2), 3, 0 };
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    for (0..2) |pass| {
        const fragment = [_]u32{
            0xc800_0000 | (4 << 18), 0xc801_0001 | (4 << 18),
            0xc800_0400 | (5 << 18), 0xc801_0401 | (5 << 18),
            sop1(3, 6, 255),         0x3f80_0000,
            sop1(3, 7, 255),         0x3e80_0000,
            0xd761_0012, 6 | (128 << 9), // spill s6 to v18 lane 0
            0xd761_0012, 7 | (129 << 9), // spill s7 to v18 lane 1
            if (pass == 0) 0xbf80_0000 else vop1(1, 18, 240), // optional ordinary overwrite invalidates both
            0xd760_000a,
            (256 + 18) | (128 << 9),
            0xd760_000b,
            (256 + 18) | (129 << 9),
            vop1(1, 6, 10),
            vop1(1, 7, 11),
            0xf800_080f,
            0x0706_0504,
            0xbf81_0000,
        };
        const address: u32 = 0x900 + @as(u32, @intCast(pass)) * 0x100;
        for (fragment, 0..) |word, index| guest.word(address + index * 4, word);
        try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase(), address >> 8);
        _ = try executor.execute(&stream);
        try renderer.flushPendingGuestWrites();
        if (renderer.last_draw_error) |err| return err;
        const center = 0x2000 + (32 * 64 + 32) * 4;
        const pixel = guest.bytes[center..][0..4];
        std.debug.print("shader interface probe pass={d} center={any}\n", .{ pass, pixel.* });
        try std.testing.expect(pixel[0] >= 110 and pixel[0] <= 150);
        try std.testing.expectEqual(@as(u8, 0), pixel[1]);
        const expected_blue: i32 = if (pass == 0) 255 else 128;
        const expected_alpha: i32 = if (pass == 0) 64 else 128;
        try std.testing.expect(@abs(@as(i32, pixel[2]) - expected_blue) <= 1);
        try std.testing.expect(@abs(@as(i32, pixel[3]) - expected_alpha) <= 1);
    }
    // VSRC=2 selects P0; ATTRCHAN selects X/Y/Z/W independently. The title's
    // icon/font selector is ATTR3.X, while ATTR3.Z carries the SDF width.
    const flat_fragment = [_]u32{
        0xc802_0402 | (4 << 18),
        0xc802_0502 | (5 << 18),
        0xc802_0602 | (6 << 18),
        0xc802_0702 | (7 << 18),
        0xf800_080f,
        0x0706_0504,
        0xbf81_0000,
    };
    for (flat_fragment, 0..) |word, index| guest.word(0xb00 + index * 4, word);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase(), 0xb);
    _ = try executor.execute(&stream);
    try renderer.flushPendingGuestWrites();
    if (renderer.last_draw_error) |err| return err;
    const flat_pixel = guest.bytes[0x2000 + (32 * 64 + 32) * 4 ..][0..4];
    std.debug.print("P0 attribute channels center={any}\n", .{flat_pixel.*});
    try std.testing.expectEqual(@as(u8, 0), flat_pixel[0]);
    try std.testing.expect(@abs(@as(i32, flat_pixel[1]) - 128) <= 1);
    try std.testing.expectEqual(@as(u8, 0), flat_pixel[2]);
    try std.testing.expectEqual(@as(u8, 255), flat_pixel[3]);
    std.debug.print("shader interface probe passed: ABI Phi, smooth/flat aliases, lane spills and P0 attribute channels\n", .{});
}

fn runStreamedMipProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    const Memory = struct {
        guest: GuestMemory = .{},
        resident_end: u64 = 0,
        fn read(context: ?*anyopaque, address: u64, destination: []u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (address < 0x100000 and address + destination.len > self.resident_end) return false;
            return GuestMemory.read(&self.guest, address, destination);
        }
        fn write(context: ?*anyopaque, address: u64, source: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return GuestMemory.write(&self.guest, address, source);
        }
    };
    var memory = Memory{};
    const guest = &memory.guest;
    _ = renderer.dcbBackend(.{ .context = &memory, .read = Memory.read, .write = Memory.write });
    const code = [_]u32{
        vop1(1, 0, 255), 0x3e80_0000,
        vop1(1, 1, 255), 0x3e80_0000,
        0xf09c_010a,     0x0040_0200,
        1,               0xe070_0000,
        0x8003_0200,     0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var image = sampledImageDescriptorWords(0x12000, 256, 256);
    image[3] |= (2 << 12) | (8 << 16) | (@as(u32, @intFromEnum(gpu.resources.TileMode.standard_4kb)) << 20);
    image[5] = 8 << 4; // resource includes all nine mip levels
    const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
    const view = try texture.subresource(2, 0, 1);
    memory.resident_end = 0x12000 + view.required_source_bytes;
    try std.testing.expect(memory.resident_end < guest.bytes.len);
    try std.testing.expect(0x12000 + texture.required_source_bytes > guest.bytes.len);
    for (0..view.height) |y| for (0..view.width) |x| {
        guest.word(0x12000 + @as(usize, @intCast(try view.sourceByteOffset(@intCast(x), @intCast(y), 0, 0))), 0xff00_0040);
    };
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    var userdata: [16]u32 = @splat(0);
    @memcpy(userdata[0..8], &image);
    @memcpy(userdata[12..16], &[_]u32{ 0x10000, 4 << 16, 1, 0 });
    for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    var bytes: [4]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x10000, &bytes);
    const actual: f32 = @bitCast(std.mem.readInt(u32, &bytes, .little));
    try std.testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), actual, 0.00001);
    std.debug.print("streamed mip probe passed: absent high mips and visible base-level sampling\n", .{});
}

fn runBc4Probe(allocator: std.mem.Allocator) !void {
    for ([_]u16{ 175, 176 }) |format| {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        const Memory = struct {
            guest: GuestMemory = .{},
            fn read(context: ?*anyopaque, address: u64, bytes: []u8) bool {
                const self: *@This() = @ptrCast(@alignCast(context.?));
                if (address >= 0x12000 and address + bytes.len > 0x15000) return false;
                return GuestMemory.read(&self.guest, address, bytes);
            }
            fn write(context: ?*anyopaque, address: u64, bytes: []const u8) bool {
                const self: *@This() = @ptrCast(@alignCast(context.?));
                return GuestMemory.write(&self.guest, address, bytes);
            }
        };
        var memory = Memory{};
        const guest = &memory.guest;
        _ = renderer.dcbBackend(.{ .context = &memory, .read = Memory.read, .write = Memory.write });
        const code = [_]u32{
            vop1(1, 0, 255), 0x3e80_0000, vop1(1, 1, 255), 0x3e80_0000,
            0xf09c_010a,     0x0040_0200, 1,               0xe070_0000,
            0x8003_0200,     0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        var image = sampledImageDescriptorWords(0x12000, 128, 128);
        image[1] = (image[1] & ~@as(u32, 0x1ff00000)) | (@as(u32, format) << 20);
        image[3] |= (7 << 16) | (@as(u32, @intFromEnum(gpu.resources.TileMode.standard_4kb)) << 20);
        image[5] = 7 << 4;
        const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
        try std.testing.expectEqual(@as(u64, 0x3000), texture.required_source_bytes);
        for (0..texture.mip_levels) |level| {
            const view = try texture.subresource(@intCast(level), 0, 1);
            for (0..view.height) |y| for (0..view.width) |x| {
                const address = 0x12000 + @as(usize, @intCast(try view.sourceByteOffset(@intCast(x), @intCast(y), 0, 0)));
                guest.word(address, 64); // endpoints 64/0, all texels select endpoint 0
                guest.word(address + 4, 0);
            };
        }
        var state = gpu.State{};
        const compute = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, compute.programRegisterBase(), 1);
        try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, 16 << 1);
        var userdata: [16]u32 = @splat(0);
        @memcpy(userdata[0..8], &image);
        @memcpy(userdata[12..16], &[_]u32{ 0x10000, 4 << 16, 1, 0 });
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
        var bytes: [4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &bytes);
        const actual: f32 = @bitCast(std.mem.readInt(u32, &bytes, .little));
        // Allow one 16-bit normalized step in hardware BC endpoint conversion.
        try std.testing.expectApproxEqAbs(@as(f32, 64.0) / (if (format == 175) @as(f32, 255) else 127), actual, 1.0 / 32767.0);
    }
    std.debug.print("BC4 probe passed: eight-byte blocks, mip tails, UNORM and SNORM sampling\n", .{});
}

fn runArrayGradientProbe(allocator: std.mem.Allocator) !void {
    for ([_]u32{ 56, 24 }) |format| for (0..3) |first_layer| {
        try runArrayGradientCase(allocator, format, @intCast(first_layer));
    };
    std.debug.print("array gradients passed: coordinate ordering, rebased array views and RG16 SNORM sampling\n", .{});
}

fn runArrayGradientCase(allocator: std.mem.Allocator, format: u32, first_layer: u32) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{});
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    // GFX10 packs derivatives before the coordinate body. Distinct layers
    // make swapping the two payloads observably wrong even at mip zero.
    const inputs = [_]f32{ 0.25, 0, 0, 0.25, 0.25, 0.75, if (first_layer == 0) 1 else 0 };
    for (inputs, 0..) |value, index| {
        guest.word(0x100 + index * 8, vop1(1, @intCast(index), 255));
        guest.word(0x104 + index * 8, @bitCast(value));
    }
    const tail = [_]u32{ 0xf088_0128, 0x0040_0700, 0xe070_0000, 0x8003_0700, 0xbf81_0000 };
    for (tail, 0..) |word, index| guest.word(0x100 + inputs.len * 8 + index * 4, word);
    var descriptor = sampledImageDescriptorWords(0x12000, 4, 4);
    descriptor[1] = (descriptor[1] & ~@as(u32, 0x1ff0_0000)) | (format << 20);
    descriptor[3] = (descriptor[3] & 0x0fff_ffff) | 0xd000_0000;
    descriptor[4] = @max(first_layer, 1); // physical last layer, inclusive
    const texture = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&descriptor));
    for (0..descriptor[4] + 1) |layer| {
        const view = try texture.subresource(0, @intCast(layer), 1);
        for (0..4) |y| for (0..4) |x| {
            const offset = try view.sourceByteOffset(@intCast(x), @intCast(y), 0, 0);
            guest.word(0x12000 + @as(usize, @intCast(offset)), if (format == 24)
                (if (layer == 0) @as(u32, 0x4000_7fff) else 0x4000_c000)
            else if (layer == 0) 0xff00_00ff else 0xff00_0040);
        };
    }
    // A base-only view stages just its visible slices, even though the T#
    // still records the physical last slice. Vulkan copies must use that span.
    descriptor[4] |= first_layer << 16;
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 16 << 1);
    var userdata: [16]u32 = @splat(0);
    @memcpy(userdata[0..8], &descriptor);
    @memcpy(userdata[12..16], &[_]u32{ 0x10000, 4 << 16, 1, 0 });
    for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    var output: [4]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x10000, &output);
    const actual: f32 = @bitCast(std.mem.readInt(u32, &output, .little));
    const expected: f32 = if (format == 24) -16384.0 / 32767.0 else 64.0 / 255.0;
    try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
}

fn runScalarPointerProbe(allocator: std.mem.Allocator) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 4, 20), 0xb814_0008, // preserve group index, then multiply by pointer size
        0xf424_0004, 20 << 25, // s_buffer_load_dwordx2 s0, V#s8, s20
        0xf408_0100,                 (125 << 25) | 4, // s_load_dwordx4 s4, s0, 4
        vop1(1, 0, 4),               vop1(1, 1, 5),
        vop1(1, 2, 6),               vop1(1, 3, 7),
        mubuf(0x1e, 0, 0, 4, 12)[0], mubuf(0x1e, 0, 0, 4, 12)[1],
        0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var analysis = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x100, code.len);
    defer analysis.deinit(allocator);
    var module = try analysis.translateSpirv(allocator, .{
        .stage = .compute,
        .compute_inputs = .{ .workgroup_id_sgprs = .{ 20, null, null } },
        .storage_buffers = &.{
            .{ .resource_sgpr = 8, .descriptor_index = 0, .stride = 8 },
            .{ .resource_sgpr = 12, .descriptor_index = 1, .stride = 16 },
        },
        .scalar_memories = &.{
            .{ .resource_sgpr = 0, .instruction_pc = 16, .descriptor_index = 2 },
            .{ .resource_sgpr = 0, .instruction_pc = 16, .descriptor_index = 3 },
        },
    });
    defer module.deinit(allocator);
    const pointers = [_]u64{ 0x1fffffff0, 0x1fffffff8, 0x2fffffff0, 0x200000004, 0x100000000, 0 };
    const expected = [_][4]u32{
        .{ 11, 12, 13, 20 }, .{ 13, 20, 21, 22 }, .{ 0, 0, 0, 0 },
        .{ 22, 23, 0, 0 },   .{ 0, 0, 0, 0 },     .{ 0, 0, 0, 0 },
    };
    for (0..2) |pass| {
        const relocation = @as(u64, @intCast(pass)) << 36;
        for (pointers, 0..) |pointer, index| {
            const value = pointer + relocation;
            guest.word(0x10000 + index * 8, @truncate(value));
            guest.word(0x10004 + index * 8, @truncate(value >> 32));
        }
        for ([_]u64{ 0x1fffffff0, 0x200000000 }, 0..) |base, region| {
            const at = 0x12000 + region * 0x100;
            guest.word(at, @truncate(base + relocation));
            guest.word(at + 4, @truncate((base + relocation) >> 32));
            for (0..4) |word| guest.word(at + 8 + word * 4, @intCast(10 + region * 10 + word));
        }
        _ = try renderer.stageGuestStorageBufferAt(0, 0x10000, pointers.len * 8);
        _ = try renderer.stageGuestStorageBufferAt(1, 0x11000, pointers.len * 16);
        _ = try renderer.stageGuestStorageBufferAt(2, 0x12000, 24);
        _ = try renderer.stageGuestStorageBufferAt(3, 0x12100, 24);
        _ = try renderer.dispatchSpirv(module.words, .{ pointers.len, 1, 1 });
        var output: [pointers.len * 16]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x11000, &output);
        for (expected, 0..) |words, index| for (words, 0..) |word, component| {
            try std.testing.expectEqual(word, std.mem.readInt(u32, output[index * 16 + component * 4 ..][0..4], .little));
        };
    }
    // SOFFSET remains a real register even when it names a word of the V#.
    // The SSBO binding already represents V#'s base; s0 supplies byte offset 8.
    const overlapping_code = [_]u32{
        sop1(3, 0, 136),             0xf428_0100,     0,
        vop1(1, 0, 4),               vop1(1, 1, 5),   vop1(1, 2, 6),
        vop1(1, 3, 7),               vop1(1, 4, 128), mubuf(0x1e, 0, 0, 4, 12)[0],
        mubuf(0x1e, 0, 0, 4, 12)[1], 0xbf81_0000,
    };
    for (overlapping_code, 0..) |word, index| guest.word(0x200 + index * 4, word);
    var overlapping = try gpu.shader_analysis.decode(allocator, .{ .context = &guest, .read_fn = GuestMemory.read }, 0x200, overlapping_code.len);
    defer overlapping.deinit(allocator);
    var overlapping_module = try overlapping.translateSpirv(allocator, .{
        .stage = .compute,
        .storage_buffers = &.{
            .{ .resource_sgpr = 0, .descriptor_index = 0, .stride = 0 },
            .{ .resource_sgpr = 12, .descriptor_index = 1, .stride = 0 },
        },
    });
    defer overlapping_module.deinit(allocator);
    for (0..8) |index| guest.word(0x14000 + index * 4, @intCast(11 + index));
    _ = try renderer.stageGuestStorageBufferAt(0, 0x14000, 16);
    _ = try renderer.stageGuestStorageBufferAt(1, 0x15000, 16);
    _ = try renderer.dispatchSpirv(overlapping_module.words, .{ 1, 1, 1 });
    var overlapping_output: [16]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(0x15000, &overlapping_output);
    for ([_]u32{ 13, 14, 0, 0 }, 0..) |expected_word, index| {
        try std.testing.expectEqual(expected_word, std.mem.readInt(u32, overlapping_output[index * 4 ..][0..4], .little));
    }
    std.debug.print("scalar pointer loads passed: runtime pointers, split regions, 32-bit carry, bounds, overlapping SOFFSET and relocated bases\n", .{});
}

fn runNestedImageProbe(allocator: std.mem.Allocator) !void {
    try runNestedImageCase(allocator, false);
    try runNestedImageCase(allocator, true);
    std.debug.print("nested sampled images passed: record pointers, bounded lane selection, runtime T#/S# loads, null bounds and relocated object pages\n", .{});
}

fn runNestedImageCase(allocator: std.mem.Allocator, bounded: bool) !void {
    var renderer = try vulkan.Renderer.init(allocator, .{ .trace_resource_failures = true });
    defer renderer.deinit();
    var guest = GuestMemory{};
    _ = renderer.dcbBackend(guest.interface());
    const code = [_]u32{
        vop1(1, 0, 28), // workgroup index survives the scalar descriptor loads
        if (bounded) (0x1a << 25) | (12 << 17) | 144 else 0xbf80_0000, // v12 = group << 16
        if (bounded) (0x16 << 25) | (12 << 17) | (12 << 9) | 144 else 0xbf80_0000,
        if (bounded) sop1(4, 20, 126) else 0xbf80_0000, // save the lanes which received v12
        if (bounded) sop1(0x14, 106, 20) else 0xbf80_0000,
        if (bounded) 0xd760_001e else 0xbf80_0000,
        if (bounded) 268 | (106 << 9) else 0xbf80_0000, // s30 = first active lane of v12
        0x936a_ff00 | @as(u32, if (bounded) 30 else 28),
        592,
        0xf424_000c, 106 << 25, // pointer = s_buffer_load_dwordx2 s0, V#s24, vcc_lo
        0xf40c_0100, (125 << 25) | 64, // T#s4 = pointer + 64
        0xf408_0300,                 (125 << 25) | 96, // S#s12 = pointer + 96
        vop1(1, 1, 255),             0x3e80_0000,
        vop1(1, 2, 255),             0x3e80_0000,
        0xf09c_010a,                 0x0061_0301,
        2,                           mubuf(0x1c, 0, 3, 0, 16)[0],
        mubuf(0x1c, 0, 3, 0, 16)[1], 0xbf81_0000,
    };
    for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
    var state = gpu.State{};
    const compute = gpu.resources.ShaderStage.compute;
    try state.writeRegister(.shader, compute.programRegisterBase(), 1);
    try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, (28 << 1) | (1 << 7));
    var userdata: [28]u32 = @splat(0);
    @memcpy(userdata[16..20], &[_]u32{ 0x11000, 4 << 16, 3, 0 });
    @memcpy(userdata[24..28], &[_]u32{ 0x10000, 592 << 16, 2, 0 });
    for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
    for (0..2) |pass| {
        if (bounded) {
            // A valid but unreachable pointer in the next record field must
            // not contribute its different sampler through wrap enumeration.
            guest.word(0x10010, 0x16000);
            const decoy = sampledImageDescriptorWords(0x8000, 1, 1);
            for (decoy, 0..) |word, index| guest.word(0x16040 + index * 4, word);
            guest.word(0x16060, 1);
        }
        for (0..2) |object| {
            const address: u32 = @intCast(0x12000 + pass * 0x2000 + object * 0x1000);
            guest.word(0x10000 + object * 592, address);
            guest.word(0x10004 + object * 592, 0);
            const texture: u32 = @intCast(0x8000 + object * 0x1000);
            const descriptor = sampledImageDescriptorWords(texture, 1, 1);
            for (descriptor, 0..) |word, index| guest.word(address + 64 + index * 4, word);
            guest.word(texture, if (object == 0) 0xff00_00ff else 0xff00_0040);
        }
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 3, 1, 1 });
        var output: [12]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x11000, &output);
        for ([_]f32{ 1, 64.0 / 255.0, 0 }, 0..) |expected, index| {
            const actual: f32 = @bitCast(std.mem.readInt(u32, output[index * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
        }
    }
    try std.testing.expectEqual(@as(u64, 1), renderer.pipeline_cache_misses);
    try std.testing.expectEqual(@as(u64, 1), renderer.pipeline_cache_hits);
}

fn runTypedIndexProbe(allocator: std.mem.Allocator) !void {
    for (0..28) |case_index| {
        const format = ([_]u32{ 5, 6, 11, 12 })[case_index % 4];
        const mask_case = case_index / 4;
        const saved_after_fetch = mask_case == 1 or mask_case == 3;
        var renderer = try vulkan.Renderer.init(allocator, .{ .trace_resource_failures = true });
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        const code = [_]u32{
            vop1(1, 0, 28), vop1(1, 1, 128),
            if (mask_case == 4) sop1(0x24, 106, 128) else if (saved_after_fetch) 0xbf80_0000 else sop1(4, 106, 126), // preserve EXEC before fetching the index
            if (mask_case == 2) 0x7daa_0280 else 0xbf80_0000, // CMPX NE 0, v1 disables lanes
            if (mask_case == 2 or mask_case == 4) 0xbf88_0001 else 0xbf80_0000, // skip into the restore block
            0xbf80_0000,
            if (mask_case == 2 or mask_case == 4) sop1(4, 126, 106) else 0xbf80_0000,
            0xf000_0108, 0x0005_0f00, // image_load v15, (v0,v1), T#s20
            if (saved_after_fetch) sop1(0x24, 106, 128) else 0xbf80_0000, // s_and_saveexec_b64 vcc, 0
            if (mask_case == 3) 0xbf88_0001 else 0xbf80_0000,
            0xbf80_0000,
            if (saved_after_fetch) sop1(4, 126, 106) else 0xbf80_0000, // restore lanes after the conditional
            if (mask_case == 3) sop1(0x24, 32, 193) else 0xbf80_0000, // another snapshot in the restored block
            sop1(4, 28, if (mask_case == 3) 32 else 106),
            sop1(0x14, 30, 28),
            if (mask_case == 5) vop1(2, 31, 271) else if (mask_case == 6) 0xd760_006b else 0xd760_001f,
            if (mask_case == 5) 0xbf80_0000 else 271 | (30 << 9), // read the first active/saved lane's typed index
            if (mask_case == 6) 0x936b_ff6b else 0x936b_ff1f,
            440,
            0xf42c_0004,
            (107 << 25) | 32,
            vop1(1, 2, 255),
            0x3e80_0000,
            vop1(1, 3, 255),
            0x3e80_0000,
            0xf09c_010a,
            0x0080_0402,
            3,
            0xe070_2000,
            0x8003_0400,
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + index * 4, word);
        for (0..2) |index| {
            const address: u32 = @intCast(0x8000 + index * 0x1000);
            const descriptor = sampledImageDescriptorWords(address, 1, 1);
            for (descriptor, 0..) |word, component| guest.word(0x11000 + index * 440 + 32 + component * 4, word);
            guest.word(address, if (index == 0) 0xff00_00ff else 0xff00_0040);
        }
        // Ordinary float fields can decode as a syntactically valid T#. They
        // belong to another field, outside the typed index's possible loads.
        const decoy = [_]u32{ 0xc973c000, 0xc95ac000, 0xc82f0000, 0xc7960000, 0x3a7f8040, 0x3a7f8040, 0x3f7f8040, 0x80000000 };
        for (decoy, 0..) |word, index| guest.word(0x11000 + 96 + index * 4, word);
        var indices = sampledImageDescriptorWords(0xa000, 6, 1);
        indices[1] = (indices[1] & ~@as(u32, 0x1ff0_0000)) | (format << 20);
        const signed = format == 6 or format == 12;
        const bits: u5 = if (format <= 6) 8 else 16;
        const sign_bit = @as(u32, 1) << (bits - 1);
        const mask = (@as(u32, 1) << bits) - 1;
        const values = [_]u32{ 0, 1, 2, if (signed) sign_bit - 1 else mask, if (signed) sign_bit else mask - 1, mask };
        // Linear single-channel rows begin at the allocation base.
        for (values, 0..) |value, index| {
            const byte = 0xa000 + index * (bits / 8);
            if (bits == 8) guest.bytes[byte] = @intCast(value) else std.mem.writeInt(u16, guest.bytes[byte..][0..2], @intCast(value), .little);
        }
        var state = gpu.State{};
        const compute = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, compute.programRegisterBase(), 1);
        try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, (28 << 1) | (1 << 7));
        var userdata: [28]u32 = @splat(0);
        @memcpy(userdata[8..12], &[_]u32{ 0x11000, 440 << 16, 31, 0 });
        @memcpy(userdata[12..16], &[_]u32{ 0x10000, 4 << 16, 6, 0 });
        @memcpy(userdata[20..28], &indices);
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ 6, 1, 1 });
        var output: [24]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(0x10000, &output);
        for ([_]f32{ 1, 64.0 / 255.0, 0, 0, 0, 0 }, 0..) |expected, index| {
            const actual: f32 = @bitCast(std.mem.readInt(u32, output[index * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
        }
        try std.testing.expectEqual(@as(u64, 2), renderer.texture_cache_misses);
    }
    std.debug.print("typed index images passed: UINT/SINT byte and short indices, negative bounds and decoy fields\n", .{});
}

fn runIndirectImageProbe(allocator: std.mem.Allocator) !void {
    for (0..6) |case_index| {
        var renderer = try vulkan.Renderer.init(allocator, .{ .trace_resource_failures = true });
        defer renderer.deinit();
        if (!renderer.sampled_image_nonuniform_indexing) return error.NonuniformSampledImagesUnavailable;
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        const wrapping = case_index == 1;
        const guarded = case_index == 2 or case_index >= 4;
        const wide = case_index == 3;
        const offset_register: u32 = if (case_index >= 4) 106 + @as(u32, @intCast(case_index - 4)) else 20;
        if (wide and renderer.device_info.sampled_image_capacity < 128) {
            std.debug.print("128-texture case unavailable: device capacity={d}\n", .{renderer.device_info.sampled_image_capacity});
            continue;
        }
        const stride: u32 = if (guarded) 368 else if (wrapping) 48 else 32;
        const table: u32 = 0x11000 + @as(u32, @intCast(case_index)) * 0x1000;
        const output: u32 = 0x10000 + @as(u32, @intCast(case_index)) * 0x100;
        const code = [_]u32{
            0x8014_ff18,                               if (wrapping) 0xaaaa_aaab else 0, // workgroup X + wrapping selector
            if (guarded) 0xd761_0012 else 0xbf80_0000,
            if (guarded) 20 | (132 << 9) else 0xbf80_0000, // spill index into v18 lane 4
            if (guarded) 0xb614_0005 else 0xbf80_0000, // s_cmp_ge_u32 s20, 5
            if (guarded) 0xbf85_0012 else 0xbf80_0000, // reject large indices before multiplication
            if (guarded) 0xd760_0014 else 0xbf80_0000,
            if (guarded) (256 + 18) | (132 << 9) else 0xbf80_0000,
            0x9300_ff14 | (offset_register << 16), stride, // s_mul_i32 SOFFSET, s20, stride
            if (case_index == 5) 0x816a_ff6b else 0xbf80_0000, // low-half address arithmetic preserves the high-half table offset
            if (case_index == 5) 0x118 else 0xbf80_0000,
            0xf42c_0004, offset_register << 25, // s_buffer_load_dwordx8 s0, V#s8, SOFFSET
            vop1(1, 1, 24), // preserve workgroup index for output
            vop1(1, 2, 255),
            0x3e80_0000,
            vop1(1, 3, 255),
            0x3e80_0000,
            0xf09c_010a, 0x0080_0402, 3, // sample T#s0, S#s16, v2/v3 -> v4
            0xe070_2000, 0x8003_0401, // indexed store v4, v1, V#s12
            0xbf81_0000,
        };
        for (code, 0..) |word, index| guest.word(0x100 + case_index * 0x100 + index * 4, word);
        if (guarded) {
            // These are real descriptors in another material field. Full
            // 32-bit residue enumeration exceeds the image limit; the proven
            // guard must retain only the selected field of reachable records.
            for (0..70) |index| {
                const decoy = sampledImageDescriptorWords(0xa000 + @as(u32, @intCast(index)) * 256, 4, 4);
                for (decoy, 0..) |word, component| guest.word(table + index * stride + 32 + component * 4, word);
            }
        }
        const ordinary_addresses = [_]u32{ 0x8000, 0x9000, 0x8000 };
        // A linear guest row has 256-byte alignment. One texel per image
        // keeps the wide fixture's adjacent 256-byte allocations disjoint.
        const extent: u32 = if (wide) 1 else 4;
        for (0..if (wide) @as(usize, 128) else 3) |index| {
            const address = if (wide) 0x8000 + @as(u32, @intCast(index)) * 256 else ordinary_addresses[index];
            var image = sampledImageDescriptorWords(address, extent, extent);
            if (!wide and index == 2) image[3] = (image[3] & ~@as(u32, 7)) | 6; // same allocation, blue in red channel
            for (image, 0..) |word, component| guest.word(table + (if (wrapping) @as(usize, 16) else 0) + index * stride + component * 4, word);
            const layout = try gpu.TextureLayout.fromImage(try gpu.resources.decodeImageDescriptor(&image));
            const surface = try layout.base();
            for (0..extent) |y| for (0..extent) |x| {
                const pixel = address + @as(usize, @intCast(try surface.sourceByteOffset(@intCast(x), @intCast(y), 0, 0)));
                guest.word(pixel, if (wide) 0xff00_0000 | @as(u32, @intCast(index + 1)) else if (index != 1) 0xff80_00ff else 0xff00_0040);
            };
        }
        var state = gpu.State{};
        const compute = gpu.resources.ShaderStage.compute;
        try state.writeRegister(.shader, compute.programRegisterBase(), @intCast(case_index + 1));
        try state.writeRegister(.shader, compute.programRegisterBase() + 1, 0);
        try state.writeRegister(.shader, 0x213, (24 << 1) | (1 << 7));
        var userdata: [24]u32 = @splat(0);
        const groups: u32 = if (wide) 129 else 5;
        @memcpy(userdata[8..12], &[_]u32{ table, stride << 16, if (wide) 128 else if (guarded) 70 else 4, 0 });
        @memcpy(userdata[12..16], &[_]u32{ output, 4 << 16, groups, 0 });
        for (userdata, 0..) |word, index| try state.writeRegister(.shader, compute.userDataBase() + @as(u32, @intCast(index)), word);
        const result = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ groups, 1, 1 });
        try std.testing.expect(result.spirv_words != 0);
        var pixels: [129 * 4]u8 = undefined;
        try renderer.readbackGuestStorageBuffer(output, pixels[0 .. groups * 4]);
        const ordinary_expected = [_]f32{ 1, 64.0 / 255.0, 128.0 / 255.0, 0, 0 };
        for (0..groups) |index| {
            const expected: f32 = if (wide) (if (index < 128) @as(f32, @floatFromInt(index + 1)) / 255.0 else 0) else ordinary_expected[index];
            const actual: f32 = @bitCast(std.mem.readInt(u32, pixels[index * 4 ..][0..4], .little));
            try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
        }
        if (case_index == 0) {
            @memset(guest.bytes[table..][0 .. 4 * stride], 0);
            _ = try renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ groups, 1, 1 });
            try renderer.readbackGuestStorageBuffer(output, pixels[0 .. groups * 4]);
            try std.testing.expect(std.mem.allEqual(u8, pixels[0 .. groups * 4], 0));
            // A malformed nonzero T# is not proof that the resource is unbound.
            guest.word(table, 0xdead);
            try std.testing.expectError(error.UnsupportedSampledImage, renderer.dispatchRdna2State(&state, .{ 1, 1, 1 }, .{ groups, 1, 1 }));
        }
    }
    std.debug.print("indirect sampled images passed: runtime selection, aliases, bounds, wrapping, guarded SGPR/VCC offsets and 128 textures\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--host-readback")) {
        var renderer = try vulkan.Renderer.init(allocator, .{});
        defer renderer.deinit();
        const elapsed = try renderer.probeHostReadback();
        std.debug.print("host readback passed: four 64 MiB reads of GPU-written data verified, CPU reads={d} us\n", .{elapsed / 1000});
        return;
    }
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--depth-only") or std.mem.eql(u8, args[1], "--depth-bias"))) {
        var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
        defer renderer.deinit();
        renderer.graphics_probe_colored_pixels = 123;
        const biased = std.mem.eql(u8, args[1], "--depth-bias");
        const depth = try renderer.probeDepthOnlyDraws(biased);
        try std.testing.expectEqual(@as(f32, 1), depth[0]);
        try std.testing.expectEqual(@as(f32, if (biased) 0.4990234375 else 0), depth[1]);
        try std.testing.expectEqual(@as(u32, 123), renderer.graphics_probe_colored_pixels);
        std.debug.print("depth-only draws passed: bias={any}, depth={any}, retained attachment and no colour readback\n", .{ biased, depth });
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--scalar-loops")) {
        try runScalarLoopProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--quad-mode")) {
        try runWholeQuadModeProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--gather-lod")) {
        try runGatherLodProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--htile-clears")) {
        var renderer = try vulkan.Renderer.init(allocator, .{ .enable_timeline_scheduler = true });
        defer renderer.deinit();
        var guest = GuestMemory{};
        _ = renderer.dcbBackend(guest.interface());
        try renderer.probeHtileDepthClears();
        std.debug.print("HTILE clears passed: initial metadata, retained raster depth, repeated clears and partial/mixed guards\n", .{});
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--wave64")) {
        try runWave64Probe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--dpp")) {
        try runDppProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--scene-masks")) {
        try runSceneMaskProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--storage-reuse")) {
        try runStorageImageReuseProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--bc4")) {
        try runBc4Probe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--shader-interface")) {
        try runShaderInterfaceProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--streamed-mips")) {
        try runStreamedMipProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--indirect-images")) {
        try runIndirectImageProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--typed-indices")) {
        try runTypedIndexProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--scalar-pointers")) {
        try runScalarPointerProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--nested-images")) {
        try runNestedImageProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--integer-colors")) {
        try runIntegerColorProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--array-gradients")) {
        try runArrayGradientProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--vector-images")) {
        try runVectorImageProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--target-reuse")) {
        try runResidentTargetReuseProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--buffer-reuse")) {
        try runQueuedBufferReuseProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--inline-metadata")) {
        try runInlineMetadataBufferProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--gds")) {
        try runGdsAtomicProbe(allocator);
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--packed-buffer")) {
        try runPackedBufferProbe(allocator);
        return;
    }
    var renderer = try vulkan.Renderer.init(allocator, .{ .enable_graphics_probe = true });
    defer renderer.deinit();
    if (args.len == 3 and std.mem.eql(u8, args[1], "--probe-spv")) {
        const bytes = try std.Io.Dir.cwd().readFileAllocOptions(
            init.io,
            args[2],
            allocator,
            .limited(16 * 1024 * 1024),
            .of(u32),
            null,
        );
        if (bytes.len % @sizeOf(u32) != 0) return error.MisalignedSpirv;
        try renderer.probeComputeSpirv(std.mem.bytesAsSlice(u32, bytes));
        std.debug.print("compute SPIR-V pipeline compiled: {s} ({d} words)\n", .{
            args[2],
            bytes.len / @sizeOf(u32),
        });
        return;
    }
    var guest = GuestMemory{};
    const backend = renderer.dcbBackend(guest.interface());
    if (init.minimal.environ.containsUnempty(allocator, "PS5_IMAGE_SMOKE_ONLY") catch false) {
        try runStorageImageCopyKernel(allocator, &renderer, &guest, backend);
        try runComputeSampledImageKernel(allocator, &renderer, &guest, backend);
        try runCompressedArrayCopyKernel(allocator, &renderer, &guest, backend, false);
        try runCompressedArrayCopyKernel(allocator, &renderer, &guest, backend, true);
        std.debug.print(
            "images passed: storage copy, compute sample, compressed array fetch/gather, uniform output guard 0/1/0/1 with descriptor SGPR reuse\n",
            .{},
        );
        return;
    }
    const report = try renderer.smokeTest();

    const program_address = 0x100;
    guest.word(program_address, 0xf40c_0200); // s_load_dwordx8 s8:s15, s0:s1, 0
    guest.word(program_address + 4, 125 << 25);
    guest.word(program_address + 8, 0xe038_0000); // buffer_load_dwordx4 v0:v3, v0, s8:s11, 0
    guest.word(program_address + 12, 0x8002_0000);
    guest.word(program_address + 16, 0xe078_0000); // buffer_store_dwordx4 v0:v3, v0, s12:s15, 0
    guest.word(program_address + 20, 0x8003_0000);
    guest.word(program_address + 24, (@as(u32, 0x3f) << 25) | (@as(u32, 4) << 17) | (@as(u32, 1) << 9) | 255);
    guest.word(program_address + 28, 0x0000_00a5); // v_mov_b32 v4, 0xa5
    guest.word(program_address + 32, 0xe060_0010); // buffer_store_byte v4, offset:16
    guest.word(program_address + 36, 0x8003_0400);
    guest.word(program_address + 40, 0xe020_0010); // buffer_load_ubyte v5, offset:16
    guest.word(program_address + 44, 0x8003_0500);
    guest.word(program_address + 48, 0xe070_0014); // buffer_store_dword v5, offset:20
    guest.word(program_address + 52, 0x8003_0500);
    guest.word(program_address + 56, (@as(u32, 0x3f) << 25) | (@as(u32, 6) << 17) | (@as(u32, 1) << 9) | 255);
    guest.word(program_address + 60, 0xffff_ff80); // v_mov_b32 v6, -128
    guest.word(program_address + 64, 0xe060_0011); // buffer_store_byte v6, offset:17
    guest.word(program_address + 68, 0x8003_0600);
    guest.word(program_address + 72, 0xe024_0011); // buffer_load_sbyte v7, offset:17
    guest.word(program_address + 76, 0x8003_0700);
    guest.word(program_address + 80, 0xe070_0018); // buffer_store_dword v7, offset:24
    guest.word(program_address + 84, 0x8003_0700);
    guest.word(program_address + 88, (@as(u32, 0x3f) << 25) | (@as(u32, 8) << 17) | (@as(u32, 1) << 9) | 255);
    guest.word(program_address + 92, 0xffff_8001); // v_mov_b32 v8, -32767
    guest.word(program_address + 96, 0xe068_0012); // buffer_store_short v8, offset:18
    guest.word(program_address + 100, 0x8003_0800);
    guest.word(program_address + 104, 0xe02c_0012); // buffer_load_sshort v9, offset:18
    guest.word(program_address + 108, 0x8003_0900);
    guest.word(program_address + 112, 0xe070_001c); // buffer_store_dword v9, offset:28
    guest.word(program_address + 116, 0x8003_0900);
    guest.word(program_address + 120, (@as(u32, 0x3f) << 25) | (@as(u32, 10) << 17) | (@as(u32, 1) << 9) | 255);
    guest.word(program_address + 124, 2); // v_mov_b32 v10, index=2
    guest.word(program_address + 128, (@as(u32, 0x3f) << 25) | (@as(u32, 11) << 17) | (@as(u32, 1) << 9) | 255);
    guest.word(program_address + 132, 4); // v_mov_b32 v11, offset=4
    guest.word(program_address + 136, 0xe030_3000); // buffer_load_dword idxen offen v12, v[10:11], s8:s11
    guest.word(program_address + 140, 0x8002_0c0a);
    guest.word(program_address + 144, 0xe070_0020); // buffer_store_dword v12, offset:32
    guest.word(program_address + 148, 0x8003_0c00);
    guest.word(program_address + 152, 0xbf81_0000); // s_endpgm

    const first_storage_address = 0x1000;
    const second_storage_address = 0x1100;
    const storage_size = 64;
    @memset(guest.bytes[first_storage_address .. first_storage_address + storage_size], 0);
    @memset(guest.bytes[second_storage_address .. second_storage_address + storage_size], 0);
    const input_words = [_]u32{ 0x1122_3344, 0x5566_7788, 0x99aa_bbcc, 0xddee_ff00 };
    for (input_words, 0..) |word, index| guest.word(first_storage_address + index * 4, word);

    const descriptor_table = 0x300;
    const descriptors = [_][4]u32{
        .{ @intCast(first_storage_address), 4 << 16, storage_size / 4, 0 },
        .{ @intCast(second_storage_address), 4 << 16, storage_size / 4, 0 },
    };
    for (descriptors, 0..) |descriptor, descriptor_index| {
        for (descriptor, 0..) |word, word_index| {
            guest.word(descriptor_table + descriptor_index * 16 + word_index * 4, word);
        }
    }

    var state = gpu.State{};
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.programRegisterBase(), program_address >> 8);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, 0x213, 2 << 1);
    try state.writeRegister(.shader, 0x207, 1);
    try state.writeRegister(.shader, 0x208, 1);
    try state.writeRegister(.shader, 0x209, 1);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.userDataBase(), descriptor_table);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.userDataBase() + 1, 0);
    const stream = [_]u32{
        command(gpu.pm4.dispatch_direct, 4),
        1,
        1,
        1,
        0x41,
    };
    var executor = gpu.DcbExecutor{ .state = &state, .backend = backend, .allocator = allocator };
    _ = try executor.execute(&stream);
    _ = try executor.execute(&stream);
    if (renderer.translated_dispatches != 2 or renderer.pipeline_cache_misses != 1 or renderer.pipeline_cache_hits != 1) {
        return error.InvalidPipelineCacheResult;
    }

    for (input_words, 0..) |expected, index| {
        if (std.mem.readInt(u32, guest.bytes[second_storage_address + index * 4 ..][0..4], .little) != expected) {
            return error.TranslatedVectorWriteMismatch;
        }
    }
    const subword_results = [_]struct { offset: usize, expected: u32 }{
        .{ .offset = 20, .expected = 0x0000_00a5 },
        .{ .offset = 24, .expected = 0xffff_ff80 },
        .{ .offset = 28, .expected = 0xffff_8001 },
    };
    for (subword_results) |result| {
        if (std.mem.readInt(u32, guest.bytes[second_storage_address + result.offset ..][0..4], .little) != result.expected) {
            return error.TranslatedSubwordWriteMismatch;
        }
    }
    if (std.mem.readInt(u32, guest.bytes[second_storage_address + 32 ..][0..4], .little) != input_words[3]) {
        return error.TranslatedIndexedAddressMismatch;
    }
    var first_readback: [storage_size]u8 = undefined;
    var second_readback: [storage_size]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(first_storage_address, &first_readback);
    try renderer.readbackGuestStorageBuffer(second_storage_address, &second_readback);
    if (!std.mem.eql(u8, guest.bytes[first_storage_address .. first_storage_address + storage_size], &first_readback) or
        !std.mem.eql(u8, guest.bytes[second_storage_address .. second_storage_address + storage_size], &second_readback))
    {
        return error.StagedBufferMismatch;
    }

    const atomic_program_address = 0x200;
    guest.word(atomic_program_address, 0xf40c_0200); // s_load_dwordx8 s8:s15, s0:s1, 0
    guest.word(atomic_program_address + 4, 125 << 25);
    const atomic_steps = [_]struct { opcode: u32, value: u32 }{
        .{ .opcode = 0xe0c0_4000, .value = 5 }, // swap
        .{ .opcode = 0xe0c8_4000, .value = 2 }, // add -> 7
        .{ .opcode = 0xe0cc_4000, .value = 1 }, // sub -> 6
        .{ .opcode = 0xe0d4_4000, .value = 0xffff_fffd }, // smin -> -3
        .{ .opcode = 0xe0d8_4000, .value = 2 }, // umin -> 2
        .{ .opcode = 0xe0dc_4000, .value = 0xffff_fffc }, // smax -> 2
        .{ .opcode = 0xe0e0_4000, .value = 6 }, // umax -> 6
        .{ .opcode = 0xe0e4_4000, .value = 3 }, // and -> 2
        .{ .opcode = 0xe0e8_4000, .value = 8 }, // or -> 10
        .{ .opcode = 0xe0ec_4000, .value = 3 }, // xor -> 9, returns 10
    };
    var atomic_pc: usize = atomic_program_address + 8;
    for (atomic_steps) |step| {
        guest.word(atomic_pc, (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255); // v_mov_b32 v0, literal
        guest.word(atomic_pc + 4, step.value);
        guest.word(atomic_pc + 8, step.opcode);
        guest.word(atomic_pc + 12, 0x8002_0000);
        atomic_pc += 16;
    }
    guest.word(atomic_pc, 0xe070_0000); // buffer_store_dword v0, s12:s15
    guest.word(atomic_pc + 4, 0x8003_0000);
    guest.word(atomic_pc + 8, 0xbf81_0000);

    const atomic_storage_address = 0x1200;
    const atomic_return_address = 0x1300;
    const atomic_storage_size = 16;
    const atomic_initial = [_]u32{ 10, 20, 30, 40 };
    for (atomic_initial, 0..) |word, index| guest.word(atomic_storage_address + index * 4, word);
    @memset(guest.bytes[atomic_return_address .. atomic_return_address + atomic_storage_size], 0);

    const atomic_descriptor_table = 0x400;
    const add_thread_id: u32 = 1 << 23;
    const atomic_descriptors = [_][4]u32{
        .{ @intCast(atomic_storage_address), 4 << 16, atomic_storage_size / 4, add_thread_id },
        .{ @intCast(atomic_return_address), 4 << 16, atomic_storage_size / 4, add_thread_id },
    };
    for (atomic_descriptors, 0..) |descriptor, descriptor_index| {
        for (descriptor, 0..) |word, word_index| {
            guest.word(atomic_descriptor_table + descriptor_index * 16 + word_index * 4, word);
        }
    }

    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.programRegisterBase(), atomic_program_address >> 8);
    try state.writeRegister(.shader, 0x207, 4);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.userDataBase(), atomic_descriptor_table);
    _ = try executor.execute(&stream);
    _ = try executor.execute(&stream);
    if (renderer.translated_dispatches != 4 or renderer.pipeline_cache_misses != 2 or renderer.pipeline_cache_hits != 2) {
        return error.InvalidAtomicPipelineCacheResult;
    }
    for (atomic_initial, 0..) |_, index| {
        const atomic_value = std.mem.readInt(u32, guest.bytes[atomic_storage_address + index * 4 ..][0..4], .little);
        const returned_value = std.mem.readInt(u32, guest.bytes[atomic_return_address + index * 4 ..][0..4], .little);
        if (atomic_value != 9) return error.TranslatedAtomicWriteMismatch;
        if (returned_value != 10) return error.TranslatedAtomicReturnMismatch;
    }
    var atomic_readback: [atomic_storage_size]u8 = undefined;
    var return_readback: [atomic_storage_size]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(atomic_storage_address, &atomic_readback);
    try renderer.readbackGuestStorageBuffer(atomic_return_address, &return_readback);
    if (!std.mem.eql(u8, guest.bytes[atomic_storage_address .. atomic_storage_address + atomic_storage_size], &atomic_readback) or
        !std.mem.eql(u8, guest.bytes[atomic_return_address .. atomic_return_address + atomic_storage_size], &return_readback))
    {
        return error.AtomicStagedBufferMismatch;
    }

    const swizzle_program_address = 0x500;
    guest.word(swizzle_program_address, 0xf40c_0200); // s_load_dwordx8 s8:s15, s0:s1, 0
    guest.word(swizzle_program_address + 4, 125 << 25);
    guest.word(swizzle_program_address + 8, (@as(u32, 0x3f) << 25) | (@as(u32, 1) << 9) | 255);
    guest.word(swizzle_program_address + 12, 1); // v_mov_b32 v0, index 1
    guest.word(swizzle_program_address + 16, 0xe030_2004); // buffer_load_dword idxen v1, offset:4
    guest.word(swizzle_program_address + 20, 0x8002_0100);
    guest.word(swizzle_program_address + 24, 0xe070_2004); // buffer_store_dword idxen v1, offset:4
    guest.word(swizzle_program_address + 28, 0x8003_0100);
    guest.word(swizzle_program_address + 32, 0xe02c_0003); // buffer_load_sshort v2, offset:3
    guest.word(swizzle_program_address + 36, 0x8002_0200);
    guest.word(swizzle_program_address + 40, 0xe068_0003); // buffer_store_short v2, offset:3
    guest.word(swizzle_program_address + 44, 0x8003_0200);
    guest.word(swizzle_program_address + 48, 0xbf81_0000);

    const swizzle_input_address = 0x1400;
    const swizzle_output_address = 0x1500;
    const swizzle_storage_size = 64;
    const swizzle_marker: u32 = 0x1234_abcd;
    @memset(guest.bytes[swizzle_input_address .. swizzle_input_address + swizzle_storage_size], 0);
    @memset(guest.bytes[swizzle_output_address .. swizzle_output_address + swizzle_storage_size], 0);
    guest.bytes[swizzle_input_address + 3] = 0x80;
    guest.bytes[swizzle_input_address + 32] = 0xff;
    guest.word(swizzle_input_address + 36, swizzle_marker);

    const swizzle_descriptor_table = 0x600;
    const swizzled_stride_16: u32 = 0x8000_0000 | (16 << 16);
    const swizzle_descriptors = [_][4]u32{
        .{ @intCast(swizzle_input_address), swizzled_stride_16, swizzle_storage_size / 16, 0 },
        .{ @intCast(swizzle_output_address), swizzled_stride_16, swizzle_storage_size / 16, 0 },
    };
    for (swizzle_descriptors, 0..) |descriptor, descriptor_index| {
        for (descriptor, 0..) |word, word_index| {
            guest.word(swizzle_descriptor_table + descriptor_index * 16 + word_index * 4, word);
        }
    }

    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.programRegisterBase(), swizzle_program_address >> 8);
    try state.writeRegister(.shader, 0x207, 1);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.compute.userDataBase(), swizzle_descriptor_table);
    _ = try executor.execute(&stream);
    _ = try executor.execute(&stream);
    if (renderer.translated_dispatches != 6 or renderer.pipeline_cache_misses != 3 or renderer.pipeline_cache_hits != 3) {
        return error.InvalidSwizzlePipelineCacheResult;
    }
    if (guest.bytes[swizzle_output_address + 3] != 0x80 or
        guest.bytes[swizzle_output_address + 32] != 0xff)
    {
        return error.TranslatedCrossDwordShortMismatch;
    }
    if (std.mem.readInt(u32, guest.bytes[swizzle_output_address + 36 ..][0..4], .little) != swizzle_marker) {
        return error.TranslatedSwizzleAddressMismatch;
    }
    var swizzle_readback: [swizzle_storage_size]u8 = undefined;
    try renderer.readbackGuestStorageBuffer(swizzle_output_address, &swizzle_readback);
    if (!std.mem.eql(u8, guest.bytes[swizzle_output_address .. swizzle_output_address + swizzle_storage_size], &swizzle_readback)) {
        return error.SwizzleStagedBufferMismatch;
    }

    const draw_stream = [_]u32{
        command(gpu.pm4.draw_index_auto, 2),
        3,
        0,
    };
    const draw_result = try executor.execute(&draw_stream);
    if (draw_result.draws != 1 or renderer.draw_callbacks != 1 or renderer.translated_draws != 1) {
        return error.InvalidGraphicsProbeDrawResult;
    }
    if (renderer.graphics_probe_colored_pixels == 0 or renderer.last_draw_error != null) {
        return error.InvalidGraphicsProbeFrame;
    }

    const vertex_program_address = 0x700;
    var vertex_pc: usize = vertex_program_address;
    guest.word(vertex_pc, vop1(0x06, 1, 261)); // v_cvt_f32_u32 v1, v5 (Prospero VertexIndex)
    vertex_pc += 4;
    guest.word(vertex_pc, vop1(0x01, 2, 255)); // v_mov_b32 v2, 1.0
    guest.word(vertex_pc + 4, 0x3f80_0000);
    vertex_pc += 8;
    guest.word(vertex_pc, vop2(0x04, 3, 1, 2)); // v_sub_f32 v3, v1, v2
    vertex_pc += 4;
    guest.word(vertex_pc, vop1(0x01, 4, 255)); // v_mov_b32 v4, 0.75
    guest.word(vertex_pc + 4, 0x3f40_0000);
    vertex_pc += 8;
    guest.word(vertex_pc, vop2(0x08, 5, 3, 4)); // x = (index - 1) * 0.75
    vertex_pc += 4;
    guest.word(vertex_pc, vop2(0x08, 6, 3, 3)); // square(index - 1)
    vertex_pc += 4;
    guest.word(vertex_pc, vop1(0x01, 7, 255)); // v_mov_b32 v7, -1.5
    guest.word(vertex_pc + 4, 0xbfc0_0000);
    vertex_pc += 8;
    guest.word(vertex_pc, vop2(0x08, 6, 6, 7));
    vertex_pc += 4;
    guest.word(vertex_pc, vop1(0x01, 8, 255)); // v_mov_b32 v8, 0.75
    guest.word(vertex_pc + 4, 0x3f40_0000);
    vertex_pc += 8;
    guest.word(vertex_pc, vop2(0x03, 6, 6, 8)); // y = 0.75 - 1.5 * square
    vertex_pc += 4;
    guest.word(vertex_pc, vop1(0x01, 7, 255)); // v_mov_b32 v7, 0.0
    guest.word(vertex_pc + 4, 0);
    vertex_pc += 8;
    guest.word(vertex_pc, vop1(0x01, 8, 255)); // v_mov_b32 v8, 1.0
    guest.word(vertex_pc + 4, 0x3f80_0000);
    vertex_pc += 8;
    guest.word(vertex_pc, 0xf800_08cf); // exp pos0, v5, v6, v7, v8 done
    guest.word(vertex_pc + 4, 0x0807_0605);
    guest.word(vertex_pc + 8, 0xbf81_0000); // s_endpgm

    const fragment_program_address = 0x900;
    const fragment_colors = [_]u32{ 0x3f80_0000, 0x3e80_0000, 0x3dcc_cccd, 0x3f80_0000 };
    var fragment_pc: usize = fragment_program_address;
    for (fragment_colors, 0..) |color, register| {
        guest.word(fragment_pc, vop1(0x01, @intCast(register), 255));
        guest.word(fragment_pc + 4, color);
        fragment_pc += 8;
    }
    guest.word(fragment_pc, 0xf800_080f); // exp mrt0, v0, v1, v2, v3 done
    guest.word(fragment_pc + 4, 0x0302_0100);
    guest.word(fragment_pc + 8, 0xbf81_0000);

    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase(), vertex_program_address >> 8);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.vertex.programRegisterBase() + 1, 0);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase(), fragment_program_address >> 8);
    try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.programRegisterBase() + 1, 0);
    const color_target_address = 0x2000;
    @memset(guest.bytes[color_target_address .. color_target_address + vulkan.graphics_probe_width * vulkan.graphics_probe_height * 4], 0);
    try state.writeRegister(.context, 0x318, color_target_address >> 8);
    try state.writeRegister(.context, 0x319, vulkan.graphics_probe_width / 8 - 1);
    try state.writeRegister(.context, 0x31b, 0);
    try state.writeRegister(.context, 0x31c, 10 << 2); // COLOR_8_8_8_8, unorm, no compression
    try state.writeRegister(.context, 0x31d, 0);
    try state.writeRegister(.context, 0x390, 0);
    try state.writeRegister(.context, 0x3b0, ((vulkan.graphics_probe_width - 1) << 14) | (vulkan.graphics_probe_height - 1));
    try state.writeRegister(.context, 0x3b8, 1 << 24); // one layer, linear tile mode
    try state.writeRegister(.context, 0x08e, 0xf);
    try state.writeRegister(.context, 0x00c, 0);
    try state.writeRegister(.context, 0x00d, vulkan.graphics_probe_width | (vulkan.graphics_probe_height << 16));
    try state.writeRegister(.context, 0x094, 1 << 31);
    try state.writeRegister(.context, 0x095, vulkan.graphics_probe_width | (vulkan.graphics_probe_height << 16));
    const viewport = [_]f32{ 32, 32, 32, 32, 1, 0 };
    for (viewport, 0..) |value, index| {
        try state.writeRegister(.context, 0x10f + @as(u32, @intCast(index)), @bitCast(value));
    }
    try state.writeRegister(.context, 0x1e0, 0);
    try state.writeRegister(.context, 0x200, 0);
    try state.writeRegister(.context, 0x202, (0xcc << 16) | (1 << 4)); // normal color mode, copy ROP
    try state.writeRegister(.context, 0x204, 0);
    try state.writeRegister(.context, 0x205, 0);
    _ = try executor.execute(&draw_stream);
    _ = try executor.execute(&draw_stream);
    // Direct executor smoke streams have no RELEASE_MEM/flip boundary between
    // these draws and the host assertion. Materialize explicitly: production
    // command streams reach the same fence through their ordering packets.
    try renderer.flushPendingGuestWrites();
    if (renderer.draw_callbacks != 3 or renderer.translated_draws != 3 or renderer.guest_graphics_draws != 2) {
        return error.InvalidGuestGraphicsDrawResult;
    }
    if (renderer.graphics_pipeline_cache_misses != 2 or renderer.graphics_pipeline_cache_hits != 1) {
        return error.InvalidGraphicsPipelineCacheResult;
    }
    if (renderer.graphics_probe_colored_pixels == 0 or renderer.last_draw_error != null) {
        return error.InvalidGuestGraphicsFrame;
    }
    const target_center = color_target_address +
        (vulkan.graphics_probe_height / 2 * vulkan.graphics_probe_width + vulkan.graphics_probe_width / 2) * 4;
    const target_pixel = guest.bytes[target_center..][0..4];
    if (target_pixel[0] < 200 or target_pixel[1] < 40 or target_pixel[1] > 100 or
        target_pixel[2] > 80 or target_pixel[3] != 255)
    {
        std.debug.print(
            "guest color target mismatch: rgba=({d},{d},{d},{d})\n",
            .{ target_pixel[0], target_pixel[1], target_pixel[2], target_pixel[3] },
        );
        return error.InvalidGuestColorTargetWriteback;
    }

    const texture_address = 0x9000;
    const texture_width = 4;
    const texture_height = 4;
    const texture_pitch = 64;
    const texture_color = [4]u8{ 16, 220, 40, 255 };
    @memset(guest.bytes[texture_address .. texture_address + texture_pitch * texture_height * 4], 0);
    for (0..texture_height) |y| {
        for (0..texture_width) |x| {
            const offset = texture_address + (y * texture_pitch + x) * 4;
            @memcpy(guest.bytes[offset..][0..4], &texture_color);
        }
    }
    const encoded_texture_address = texture_address >> 8;
    const image_descriptor = [_]u32{
        encoded_texture_address,
        (56 << 20) | ((texture_width - 1) << 30),
        (texture_height - 1) << 14,
        0x9000_0fac, // 2D, linear, RGBA destination select
        texture_pitch - 1,
        0,
        0,
        0,
    };
    for (image_descriptor, 0..) |word, index| {
        try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.userDataBase() + @as(u32, @intCast(index)), word);
    }
    for (0..4) |index| {
        try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.userDataBase() + 8 + @as(u32, @intCast(index)), 0);
    }
    try state.writeRegister(.shader, gpu.resources.ShaderStage.pixel.userDataBase() - 1, 12 << 1);
    fragment_pc = fragment_program_address;
    guest.word(fragment_pc, vop1(0x01, 0, 255)); // u = 0.5
    guest.word(fragment_pc + 4, 0x3f00_0000);
    fragment_pc += 8;
    guest.word(fragment_pc, vop1(0x01, 1, 255)); // v = 0.5
    guest.word(fragment_pc + 4, 0x3f00_0000);
    fragment_pc += 8;
    guest.word(fragment_pc, 0xf080_0f08); // image_sample dim:2d dmask:xyzw
    guest.word(fragment_pc + 4, 0x0040_0200); // v2:v5, v0:v1, s0:s7, s8:s11
    fragment_pc += 8;
    guest.word(fragment_pc, 0xf800_080f); // exp mrt0, v2, v3, v4, v5 done
    guest.word(fragment_pc + 4, 0x0504_0302);
    guest.word(fragment_pc + 8, 0xbf81_0000);
    _ = try executor.execute(&draw_stream);
    try renderer.flushPendingGuestWrites();
    // The first two resident draws materialize as one latest-target writeback;
    // the textured draw adds the second. Per-draw synchronous submission used
    // to produce three redundant guest copies here.
    if (renderer.guest_graphics_draws != 3 or renderer.translated_draws != 4 or
        renderer.graphics_pipeline_cache_misses != 3 or renderer.guest_color_target_writes != 2 or
        renderer.sampled_image_uploads != 1)
    {
        return error.InvalidTexturedGraphicsDrawResult;
    }
    if (!std.mem.eql(u8, target_pixel, &texture_color)) return error.InvalidSampledTextureColor;

    var present_probe = PresentProbe{};
    renderer.setPresentationSink(.{ .context = &present_probe, .present = PresentProbe.present });
    const label_address = 0x7000;
    const sync_and_flip = [_]u32{
        customCommand(gpu.pm4.custom.acquire_mem, 7),
        0x8000_0001,
        0x20,
        0,
        0x10,
        0,
        3,
        0x388,
        customCommand(gpu.pm4.custom.write_data, 4),
        5,
        label_address,
        0,
        0x1122_3344,
        customCommand(gpu.pm4.custom.wait_mem_32, 6),
        label_address,
        0,
        0xffff_ffff,
        0x1122_3344,
        0x13,
        1,
        customCommand(gpu.pm4.custom.release_mem, 7),
        0x28 | (5 << 8),
        1 << 29,
        label_address + 0x10,
        0,
        0xaabb_ccdd,
        0,
        0,
        customCommand(gpu.pm4.custom.release_mem, 7),
        0x28 | (5 << 8),
        3 << 29,
        label_address + 0x18,
        0,
        0,
        0,
        0,
        command(gpu.pm4.event_write, 1),
        0x20,
        customCommand(gpu.pm4.custom.flip, 5),
        1,
        0,
        1,
        0x89ab_cdef,
        0x0123_4567,
    };
    const sync_result = try executor.execute(&sync_and_flip);
    if (sync_result.status != .complete or renderer.acquire_callbacks != 1 or
        renderer.write_data_callbacks != 1 or renderer.wait_callbacks != 1 or
        renderer.release_callbacks != 2 or renderer.event_callbacks != 1 or
        renderer.flip_callbacks != 1 or renderer.presented_frames != 1)
    {
        return error.InvalidVulkanSynchronizationCallbacks;
    }
    if (std.mem.readInt(u32, guest.bytes[label_address..][0..4], .little) != 0x1122_3344 or
        std.mem.readInt(u32, guest.bytes[label_address + 0x10 ..][0..4], .little) != 0xaabb_ccdd)
    {
        return error.InvalidVulkanLabelWrite;
    }
    if (std.mem.readInt(u64, guest.bytes[label_address + 0x18 ..][0..8], .little) == 0) {
        return error.InvalidVulkanTimestampWrite;
    }
    if (present_probe.calls != 1 or present_probe.width != vulkan.graphics_probe_width or
        present_probe.height != vulkan.graphics_probe_height or
        present_probe.argument != 0x0123_4567_89ab_cdef or
        !std.mem.eql(u8, &present_probe.center, target_pixel))
    {
        return error.InvalidPresentedFrame;
    }

    try runFragmentStorageProbe(allocator, &renderer, &guest, backend, &state, color_target_address);
    try runIndexedCopyKernel(allocator, &renderer, &guest, backend);
    try runStorageImageCopyKernel(allocator, &renderer, &guest, backend);

    try runQueuedBufferReuseProbe(allocator);

    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &output.interface;
    try writer.print(
        "Vulkan {d}.{d}.{d}: {s}\n" ++
            "device API {d}.{d}.{d}, queue family {d}, validation {s}\n" ++
            "headless smoke passed: {d} compute dispatch, {d} staging bytes copied and verified\n" ++
            "translated RDNA2 passed: {d} dispatches, pipelines {d}/{d} miss/hit, buffers {d}/{d} miss/hit\n" ++
            "graphics DCB probe passed: 1 diagnostic + {d} guest draws, pipelines {d}/{d} miss/hit\n" ++
            "guest RDNA2 frame passed: {d} colored pixels in {d}x{d} RGBA8 target\n" ++
            "sampled image passed: {d} guest texture upload\n" ++
            "storage image passed: 4x4 RGBA8_UINT load/store and guest writeback\n" ++
            "PM4 synchronization + SetFlip passed: {d} presented frame\n",
        .{
            vulkan.api.apiMajor(renderer.loader_api_version),
            vulkan.api.apiMinor(renderer.loader_api_version),
            vulkan.api.apiPatch(renderer.loader_api_version),
            renderer.device_info.name(),
            vulkan.api.apiMajor(renderer.device_info.api_version),
            vulkan.api.apiMinor(renderer.device_info.api_version),
            vulkan.api.apiPatch(renderer.device_info.api_version),
            report.queue_family_index,
            if (renderer.validation_enabled) "on" else "off",
            report.compute_dispatches,
            report.bytes_copied,
            renderer.translated_dispatches,
            renderer.pipeline_cache_misses,
            renderer.pipeline_cache_hits,
            renderer.buffer_cache_misses,
            renderer.buffer_cache_hits,
            renderer.guest_graphics_draws,
            renderer.graphics_pipeline_cache_misses,
            renderer.graphics_pipeline_cache_hits,
            renderer.graphics_probe_colored_pixels,
            vulkan.graphics_probe_width,
            vulkan.graphics_probe_height,
            renderer.sampled_image_uploads,
            renderer.presented_frames,
        },
    );
    try writer.flush();
}
